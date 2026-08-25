import Foundation
import Observation
import RemotePiProtocol
import RemotePiSession

// MARK: - Screen states

/// What Home's body shows (spec 08 §7.1, §7.3).
enum HomePhase: Hashable, Sendable {
    /// The composition root is still booting. Centered spinner, no tabs.
    case loading
    /// No pairing yet. First-pair empty state with a Scan QR button. The tabs
    /// are hidden — there is nothing to filter.
    case noPeer
    /// Paired, but the relay has announced zero chat rooms on any machine.
    /// The dimmed "Nothing here…" moon. **Tabs hidden** (spec 08 §7.1).
    case lonely
    /// Sessions exist, but none match this tab. Tabs stay visible so the user
    /// can switch back; the per-tab copy explains it is a filter, not a dead
    /// end (spec 08 §7.3).
    case filterEmpty(SessionFilter)
    /// The grouped list.
    case list
}

/// The subtitle under the large title (spec 08 §7.2).
enum HomeRelayStatus: Hashable, Sendable {
    case connected
    /// No peer is paired, so the WebSocket was never opened — its URL embeds
    /// the destination peer's pubkey. "Not connected" is not a fault here, and
    /// showing the alarming amber "Offline" for it is wrong.
    case awaitingPairing
    case offline

    var label: String {
        switch self {
        case .connected: "Connected"
        case .awaitingPairing: "Awaiting pairing"
        case .offline: "Offline"
        }
    }
}

/// One computed read of the whole list.
///
/// Bundled into a single value on purpose: `phase`, `counts` and `sections`
/// all derive from the same catalog traversal, and returning them separately
/// would rebuild it three times per render *and* let them disagree for a frame
/// if one of them were read before a mutation and another after.
struct HomeContent: Hashable, Sendable {
    var phase: HomePhase = .loading
    var counts = HomeSessionCounts()
    var sections: [HomeDeviceSection] = []
}

/// A transient message from an action (rename refused, delete failed).
///
/// Carries an id so a second identical message still re-presents — the Flutter
/// `SnackBar` behaves that way and a user who taps Save twice needs to see the
/// second answer.
struct HomeBanner: Identifiable, Hashable, Sendable {
    let id: UUID
    let text: String

    init(_ text: String) {
        self.id = UUID()
        self.text = text
    }
}

// MARK: - Model

/// Home's behaviour. The View below it only lays things out.
///
/// ## Why almost everything here is computed
///
/// The list is a **pure function** of `(peers, snapshot, isRelayConnected,
/// filter, grouping)`. Caching it into a stored property would mean a
/// subscription to keep it fresh, a cancellation path for that subscription,
/// and a window where the cache disagrees with `AppModel`. Because `AppModel`
/// is `@Observable`, reading it from a computed property gives SwiftUI the
/// exact dependency set for free — and gives a test a synchronous read with no
/// stream to pump.
///
/// So this model has **no long-lived tasks at all**, and `deactivate()` has
/// nothing to cancel. That is not a shortcut around the `ScreenModel` pattern;
/// it is the pattern's best case (see rule 1 in `Shell/ScreenModel.swift`:
/// one-shots are `async` methods the view awaits).
///
/// ## What is stored, and why
///
/// `filter` and `grouping` are **user state**. They must survive every
/// presence / rooms / peers re-emit — resetting the filter on each reload was
/// the "sessions jumping" bug (spec 08 §12.2). Storing them on a model whose
/// lifetime is the screen's is what guarantees that.
@MainActor
@Observable
final class HomeScreenModel {
    // MARK: User state

    /// The presence tab. A **pure view filter**: changing it never reloads,
    /// refetches or regroups. Defaults to `.online` (spec 08 §7.1).
    var filter: SessionFilter = .online

    /// Which headers to render. Persisted through ``AppPreferences`` by its
    /// stable wire string, and seeded from there in ``activate()`` so the
    /// layout does not snap back for a frame on cold start (spec 08 §7.4).
    var grouping: HomeGrouping = .workspace {
        didSet {
            guard oldValue != grouping else { return }
            backend?.preferences.homeGrouping = grouping
        }
    }

    /// The last action result worth telling the user about.
    private(set) var banner: HomeBanner?

    /// `true` while a rename or delete is in flight, so the menu can disable
    /// itself rather than let a double-tap send twice.
    private(set) var isBusy = false

    // MARK: Wiring

    // NOT `@ObservationIgnored`, and that is load-bearing.
    //
    // Every derived value on this model (`content`, `relayStatus`,
    // `canCreateSession`) starts with `guard let backend else { return <empty
    // state> }`. On the very first render `backend` is still nil, so that
    // guard returns before touching a single observable property of
    // `AppModel` — which means SwiftUI records **no** dependency at all.
    //
    // `bind(backend:)` then runs from `.task`, after that first render. If the
    // assignment is not itself observable, nothing ever invalidates the view:
    // Home stays on its spinner with "Relay · Offline" forever, on a fully
    // connected app, because the empty state it painted once is the only state
    // it will ever paint.
    //
    // Tracking the assignment closes the loop: the view re-reads `content`,
    // this time reaches through `backend` into `AppModel`, and from then on
    // Observation follows `phase` / `peers` / `snapshot` normally.
    private var backend: (any HomeBackend)?
    /// Injectable clock, so "Last paired: 3m ago" is assertable.
    @ObservationIgnored private var clock: @Sendable () -> Date = { Date() }

    init() {}

    /// Idempotent, per the `ScreenModel` contract.
    func bind(backend: any HomeBackend, clock: (@Sendable () -> Date)? = nil) {
        guard self.backend == nil else { return }
        self.backend = backend
        if let clock { self.clock = clock }
    }

    /// Seeds the persisted grouping. No subscriptions to start — see the type
    /// doc.
    func activate() async {
        guard let backend else { return }
        let stored = backend.preferences.homeGrouping
        if grouping != stored { grouping = stored }
    }

    /// Nothing to cancel. Kept so the `ScreenModel` lifecycle stays uniform
    /// and so a future subscription has an obvious home.
    func deactivate() {}

    // MARK: Derived read model

    /// The list, its counts and its phase, from one traversal.
    var content: HomeContent {
        guard let backend else { return HomeContent(phase: .loading) }
        if backend.isBooting { return HomeContent(phase: .loading) }
        guard !backend.homePeers.isEmpty else { return HomeContent(phase: .noPeer) }

        // Always `.all`. The tab filter is applied below against the *gated*
        // liveness (`relay connected && announced`), which `SessionCatalog`
        // cannot see — it only knows the registry snapshot. Passing the filter
        // down there would list rooms as Online while the socket is down.
        let devices = SessionCatalog.build(
            peers: backend.homePeers,
            snapshot: backend.homeSnapshot,
            filter: .all
        )
        let counts = HomeListBuilder.counts(devices: devices) { backend.isLive($0) }
        guard counts.all > 0 else { return HomeContent(phase: .lonely, counts: counts) }

        let sections = HomeListBuilder.sections(
            devices: devices,
            grouping: grouping,
            isVisible: { [filter] key in
                switch filter {
                case .all: true
                case .online: backend.isLive(key)
                case .offline: !backend.isLive(key)
                }
            },
            now: clock()
        )
        return HomeContent(
            phase: sections.isEmpty ? .filterEmpty(filter) : .list,
            counts: counts,
            sections: sections
        )
    }

    var relayStatus: HomeRelayStatus {
        guard let backend else { return .offline }
        if backend.isRelayConnected { return .connected }
        return backend.homePeers.isEmpty ? .awaitingPairing : .offline
    }

    /// Whether the `+` renders at all. **Hidden, not disabled**: the control
    /// frame rides the active WebSocket, so an unreachable Mac genuinely
    /// cannot be asked (spec 08 §7.2).
    var canCreateSession: Bool {
        !(backend?.machinesAcceptingSessions.isEmpty ?? true)
    }

    func presence(of session: SessionKey) -> PresenceLevel {
        backend?.presence(of: session) ?? .offline
    }

    func isLive(_ session: SessionKey) -> Bool {
        backend?.isLive(session) ?? false
    }

    /// The `SessionRow` behind a key, resolved from the **unfiltered** catalog.
    ///
    /// Never synthesised: a row the Pi is not listening on drops its frames and
    /// reads as a ghost (spec 08 §13.10, §13.6 — there is no `'main'` fallback
    /// in this client).
    func row(for key: SessionKey) -> SessionRow? {
        guard let backend else { return nil }
        return SessionCatalog.sessions(
            for: key.peer,
            snapshot: backend.homeSnapshot,
            filter: .all
        )
        .first { $0.key == key }
    }

    /// Whether the long-press menu's Delete item is tappable (spec 08 §7.7).
    func canDelete(_ session: SessionKey) -> Bool { !isLive(session) }

    // MARK: Actions

    /// Step 1 of opening a session (spec 08 §7.8). The view does steps 2 and 3
    /// through `SessionOpener`, which owns that ordering.
    func open(_ row: SessionRow) async {
        await backend?.openSession(row)
    }

    /// The rename dialog's Save (spec 08 §7.7, `home_viewmodel.dart:292-331`).
    ///
    /// Order matters and is the Flutter order:
    /// 1. write the label locally, optimistically — the relay's authoritative
    ///    broadcast overwrites it moments later, and this keeps the tile
    ///    responsive;
    /// 2. an empty name is a **local-only clear**. There is no "unset the
    ///    name" on the wire, so nothing is sent and nothing is reported;
    /// 3. an offline session cannot be told, so say so;
    /// 4. otherwise send `session_rename` and surface any `action_error`.
    func rename(_ session: SessionKey, to raw: String) async {
        guard let backend, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let wroteLocally = await backend.setLocalSessionName(
            session,
            to: trimmed.isEmpty ? nil : trimmed
        )

        guard !trimmed.isEmpty else {
            // Clearing is local-only by design. If even the local write is
            // unavailable there is genuinely nothing to report as done.
            if !wroteLocally {
                banner = HomeBanner("Clearing a session's name isn't available in this build yet.")
            }
            return
        }

        guard backend.isLive(session) else {
            // Spec copy assumes the local write landed. When it did not, say
            // the true thing instead of claiming a rename that did not happen.
            banner = HomeBanner(
                wroteLocally
                    ? "Session is offline — renamed on this device only."
                    : "Session is offline — bring it back online to rename it."
            )
            return
        }

        if let failure = await backend.renameSession(session, to: trimmed) {
            banner = HomeBanner(failure)
        }
    }

    /// The delete confirmation's Delete (spec 08 §7.7). A **local cache
    /// eviction only** — nothing is sent to the Pi, and the session reappears
    /// if it comes back online.
    func delete(_ session: SessionKey) async {
        guard let backend, !isBusy else { return }
        // Re-check rather than trust the menu: the room can go live between
        // opening the sheet and confirming the dialog.
        guard !backend.isLive(session) else {
            banner = HomeBanner("That session came back online — it can only be removed while offline.")
            return
        }
        isBusy = true
        defer { isBusy = false }
        if let failure = await backend.deleteCachedSession(session) {
            banner = HomeBanner(failure)
        }
    }

    func dismissBanner() { banner = nil }

    /// Builds the New Session sheet's model, sharing this screen's backend.
    ///
    /// Built here rather than in the view's `body` so its idempotency keys are
    /// minted exactly once per presentation (spec 08 §13.9).
    func makeNewSessionModel() -> NewSessionModel? {
        guard let backend else { return nil }
        return NewSessionModel(backend: backend)
    }
}
