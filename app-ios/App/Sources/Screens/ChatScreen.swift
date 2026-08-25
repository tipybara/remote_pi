import Observation
import RemotePiProtocol
import RemotePiSession
import RemotePiStore
import SwiftUI

// ============================================================================
// The chat screen (spec 08 §8) — the composition point for everything in
// `Chat/` and `Actions/`.
//
// This file owns no presentation logic. Each piece below is a tested unit that
// was written against a seam rather than against `AppModel`, and the only job
// here is to hand each one its inputs and route its callbacks:
//
//   ChatTopBar          §8.2   title / device / status pill
//   RevokedBanner       §8.3   the ONE banner the chat keeps
//   ChatTranscriptView  §8.4-6 the list, the bubbles, the tool cards
//   ComposerBar         §8.7-10 field, steer, voice, images
//   QuickActionsSheet   §8.11  compact / new context / model / thinking
//   askUserModal        §8.13  the pi-ask fullScreenCover
//
// Two structural rules that must survive any edit here:
//
//   * the transcript is anchored at the bottom by `ChatTranscriptView` itself.
//     Do NOT add a `ScrollViewReader` + `scrollTo` here: that is the
//     `animateTo`-per-frame the Dart removed, and it fights the anchor into
//     flicker and runaway scroll during streaming (§8.4);
//   * every chat-scoped sheet carries `.dismissOnSessionChange(selection)`.
//     On tablet the detail pane can swap underneath an open sheet, leaving it
//     hovering over a different session (§11.2).
// ============================================================================

struct ChatScreen: View {
    /// `(PeerID, RoomID)` — the only thing this screen is allowed to be
    /// identified by. The title arrives separately, as a hint.
    let session: SessionKey

    @Environment(AppModel.self) private var app
    @Environment(AppNavigator.self) private var navigator
    @Environment(SessionSelection.self) private var selection
    @Environment(\.theme) private var theme
    @Environment(\.layoutClass) private var layout

    @State private var model = ChatScreenModel()
    @State private var showsQuickActions = false

    var body: some View {
        VStack(spacing: 0) {
            ChatTopBar(
                model: model.topBar,
                // The tablet's detail pane has nothing to go back to — the
                // master column is already on screen (`app_router.dart:437`).
                showsBack: layout == .compact,
                onBack: { navigator.pop() },
                onInfo: nil
            )

            if model.pairingRevoked {
                RevokedBanner(
                    device: model.topBar.deviceLabel,
                    onRePair: { navigator.openPairing() }
                )
            }

            ChatTranscriptView(
                model: model.transcript,
                onRePair: { navigator.openPairing() }
            )

            if let composer = model.composer {
                ComposerBar(
                    model: composer,
                    gate: model.gate,
                    onOpenQuickActions: { showsQuickActions = true }
                )
            }
        }
        .background(theme.colors.bg)
        // The bar is the title, so the navigation chrome must not paint a
        // second one on top of it.
        .toolbar(.hidden, for: .navigationBar)
        // `session` is passed in rather than read from the model, so a
        // mis-keyed push cannot silently show another session's transcript.
        .task(id: session) { await model.follow(session, hints: selection.current) }
        .screenModel(model)
        .sheet(isPresented: $showsQuickActions) {
            QuickActionsSheet(session: session)
                .dismissOnSessionChange(selection)
        }
        .askUserModal(model.askUser)
    }
}

/// Everything the chat screen subscribes to, in one place.
///
/// Follows the pattern in `Shell/ScreenModel.swift`: no dependencies in
/// `init`, `bind(to:)` is idempotent, one subscription task per stream all
/// recorded in `subs`, and `deactivate()` is the only cancellation point.
///
/// It is also the chat's ``ComposerHost``: the composer talks to this, and
/// this talks to `AppModel`. That indirection is what keeps every composer
/// rule testable without a socket.
@MainActor
@Observable
final class ChatScreenModel: ScreenModel, ComposerHost {
    let topBar = ChatTopBarModel()
    let transcript = ChatTranscriptModel()
    let askUser = AskUserModel()

    /// Built on `bind(to:)` because `ComposerModel.live(host:)` needs `self`,
    /// which is not available in a property initialiser.
    private(set) var composer: ComposerModel?

    /// The pairing for this machine is gone. Drives the banner and locks the
    /// composer.
    private(set) var pairingRevoked = false

    /// The Pi said `bye`; the string is why. Cleared when the room comes back
    /// live, because a `bye` from a previous connection is not a fact about
    /// this one.
    private(set) var peerOfflineReason: String?

    private var app: AppModel?
    private var actions: AppModelSessionActions?
    private var session: SessionKey?
    private let subs = ScreenSubscriptions()

    init() {}

    func bind(to app: AppModel) {
        guard self.app == nil else { return }
        self.app = app
        let actions = AppModelSessionActions(app: app)
        self.actions = actions
        composer = ComposerModel.live(host: self)
    }

    /// Point the model at a session. Idempotent for the same key.
    ///
    /// The shell gives the chat `.id(sessionKey)`, so a different session is a
    /// different view identity and therefore a different model; the re-subscribe
    /// here is belt-and-braces. If you find yourself relying on it, check that
    /// the `.id` is still there.
    func follow(_ session: SessionKey, hints: SessionSelection.Selected?) async {
        guard self.session != session else {
            applyHints(hints)
            return
        }
        self.session = session
        // Everything below is per-session state. Carrying any of it across a
        // switch is how a chat ends up showing another session's turn.
        transcript.apply(messages: [])
        transcript.apply(streaming: nil)
        transcript.fatalError = nil
        peerOfflineReason = nil
        composer?.resetForSessionChange()
        askUser.clear()
        applyHints(hints)

        subs.cancelAll()
        if let app, let actions {
            askUser.bind(to: actions, session: session)
            // `SessionOpener` already opened this session — it has to, because
            // spec 08 §7.8 puts `openChat` *before* `selection.select` so the
            // tablet's detail pane reads an already-updated pointer. Re-opening
            // here would fire a second `session_sync` per tap.
            //
            // The guard rather than no call at all: a chat reached without the
            // opener (a future deep link, a restored pointer) must still sync,
            // and this is the belt-and-braces half of the same rule that keeps
            // `follow` re-subscribing on a changed key.
            if app.openedSession?.key != session {
                await app.openChat(session)
            }
        }
        subscribe()
    }

    func activate() async {
        subscribe()
    }

    func deactivate() {
        subs.cancelAll()
        composer?.deactivate()
        askUser.deactivate()
    }

    // MARK: Gate

    /// What the composer is allowed to do right now (spec 08 §8.7).
    var gate: ComposerGate {
        guard let app, let session else { return ComposerGate() }
        return ComposerGate(
            isReady: app.phase == .ready,
            isOffline: !app.isRelayConnected,
            pairingRevoked: pairingRevoked,
            peerOfflineReason: peerOfflineReason,
            // The relay says the room is not live. Distinct from `isOffline`,
            // which is about our own socket.
            presenceOffline: app.isRelayConnected && !app.isLive(session),
            isWorking: app.isTurnInFlight(session),
            cancelTargetID: app.cancelTarget(for: session)
        )
    }

    // MARK: ComposerHost

    func composerSend(text: String, image: ComposerImage?, steer: Bool) async {
        guard let app, let session else { return }
        await app.send(text, to: session, image: image, steer: steer)
    }

    func composerCancel(targetID: String) async {
        guard let app, let session else { return }
        await app.post(
            .cancel(Cancel(id: "cancel_\(UUID().uuidString.lowercased())", targetID: targetID)),
            to: session
        )
    }

    // MARK: QueuedMessageSink

    func queuedMessageSet(id: String, text: String) async {
        guard let app, let session else { return }
        await app.post(.queuedMessageSet(QueuedMessageSet(id: id, text: text)), to: session)
    }

    func queuedMessageClear(targetID: String?) async {
        guard let app, let session else { return }
        // `targetID == nil` clears the WHOLE queue — the wire's meaning for an
        // omitted `target_id`, which is not the same as an empty string
        // (spec §13.11). `QueuedMessageClear` leaves a `nil` off the wire.
        await app.post(
            .queuedMessageClear(
                QueuedMessageClear(
                    id: "qclear_\(UUID().uuidString.lowercased())",
                    targetID: targetID
                )
            ),
            to: session
        )
    }

    // MARK: Subscriptions

    private func subscribe() {
        guard !subs.isActive, let app, let session else { return }

        // Persisted rows.
        subs.start { [weak self] in
            let stream = await app.messages(for: session)
            for await rows in stream {
                guard let self, !Task.isCancelled else { return }
                self.transcript.apply(messages: rows)
                // The third title fallback (§8.2). Recomputed rather than
                // stored so a cleared transcript drops it again.
                self.topBar.firstUserMessage = rows.first { $0.role == .user }?.text
            }
        }

        // `ask_user` — frames `ChatIngest` deliberately drops, because they
        // are not transcript rows.
        subs.start { [weak self] in
            for await request in app.extensionUIRequests(for: session) {
                guard let self, !Task.isCancelled else { return }
                self.askUser.receive(request)
            }
        }

        // Everything derived from `AppModel`'s observable state: the relay
        // snapshot, the streaming draft, the peer list, preferences.
        subs.start { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refreshDerived()
                // One frame's worth of coalescing. `@Observable` has no
                // multi-property stream, and polling at display cadence is
                // cheaper here than eight `withObservationTracking` loops that
                // each re-arm on every touch of `AppModel`.
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Fold `AppModel`'s current state into the three view models.
    private func refreshDerived() {
        guard let app, let session else { return }

        let peer = app.peer(session.peer)
        pairingRevoked = peer == nil && !app.peers.isEmpty

        topBar.peer = peer
        topBar.meta = app.snapshot.room(session)
        topBar.connectionResolved = app.connection != .idle && app.connection != .connecting
        topBar.isRelayConnected = app.isRelayConnected
        topBar.isRoomLive = app.isLive(session)
        // The chat MAY OR in its own optimistic signal — unlike Home (§7.6.1)
        // — because this flag is scoped to the open session and is dropped on
        // a session switch, so it cannot strand a dot on a tile.
        topBar.isWorking = app.isTurnInFlight(session)

        peerOfflineReason = app.peerOfflineReason(for: session)
        if let queued = app.queuedState(for: session) {
            composer?.queued.apply(queued)
        }
        transcript.hideToolCalls = app.preferences.hideToolCalls
        transcript.hasPeer = peer != nil
        transcript.apply(streaming: app.streamingDraft(for: session))
    }

    private func applyHints(_ hints: SessionSelection.Selected?) {
        guard let hints else { return }
        topBar.hints = ChatTopBarModel.Hints(
            title: hints.title,
            device: hints.device,
            online: hints.online
        )
    }
}
