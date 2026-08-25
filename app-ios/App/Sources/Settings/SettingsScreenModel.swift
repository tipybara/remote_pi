import Foundation
import Observation
import RemotePiProtocol

/// All of Settings' behaviour (spec 08 §9, `settings_viewmodel.dart`).
///
/// Deliberately knows nothing about SwiftUI and nothing about `AppModel`: it
/// talks to ``SettingsHost``. That is what makes the revoke *ordering* — the
/// only genuinely dangerous thing on this screen — assertable in a plain test
/// with a recording fake. `SettingsScreenModel+AppModel.swift` is the ~60-line
/// file that adapts the real app to the protocol.
///
/// ## The three sections
///
/// * **RELAY** — an override field with inline validation, `Save`, and
///   `Use default Relay`. Saving reconnects carrying **both halves** of the
///   session pointer.
/// * **DISPLAY** — theme and "hide tool calls". The Flutter text-size control
///   is intentionally absent; see ``SettingsScreen`` for why.
/// * **PAIRINGS** — loading / empty / list, nickname edit, swipe-to-revoke.
@MainActor
@Observable
final class SettingsScreenModel {

    // MARK: - State

    /// The PAIRINGS section (`SettingsLoading` / `SettingsNoPeer` /
    /// `SettingsList`, spec 08 §9.3). Kept as one enum rather than
    /// `[PeerRecord]` + `isLoading` so "loaded and empty" and "not loaded yet"
    /// cannot be confused — they render completely different things.
    enum Pairings: Equatable {
        case loading
        case empty
        case list([PeerRecord])

        var records: [PeerRecord] {
            if case .list(let records) = self { return records }
            return []
        }
    }

    /// A transient message under the relay field / pairings list.
    struct Banner: Equatable, Sendable {
        enum Kind: Sendable { case info, warning, error }
        let text: String
        let kind: Kind
    }

    private(set) var pairings: Pairings = .loading

    /// The relay text field. A plain `var` so the view binds `$model.relayDraft`
    /// — a `TextEditingController` equivalent is not needed, and holding the
    /// text in the view is what made the Flutter version need `initState` to
    /// seed it.
    var relayDraft: String = ""

    /// Inline `errorText` under the field. Cleared on every edit so a stale
    /// rejection does not sit under a URL the user already fixed.
    private(set) var relayError: String?

    /// `Current: <effectiveRelayUrl>` helper text. This is what the app is
    /// dialling **now**, which is not necessarily what is in the field.
    private(set) var effectiveRelayURL: String = ""

    private(set) var isSavingRelay = false

    /// "Relay updated" (2 s), or a warning after a partial revoke.
    private(set) var banner: Banner?

    /// Non-`nil` while the confirm dialog is up. Cancelling clears it and
    /// changes nothing — the SwiftUI equivalent of `confirmDismiss` returning
    /// `false` and snapping the row back (spec 08 §10).
    private(set) var revokeCandidate: PeerRecord?

    /// The machine currently being revoked, so its row can show progress and
    /// a second swipe cannot start a concurrent revoke.
    private(set) var revoking: PeerID?

    /// Non-`nil` while the nickname sheet is up.
    private(set) var nicknameCandidate: PeerRecord?
    /// The sheet's text field. Seeded from the existing nickname; empty means
    /// "no nickname", which is a *different* outcome from cancelling.
    var nicknameDraft: String = ""

    // MARK: - Wiring

    private var host: (any SettingsHost)?
    private var isTracking = false

    init() {}

    /// Idempotent, per the ``ScreenModel`` contract.
    func bind(host: any SettingsHost) {
        guard self.host == nil else { return }
        self.host = host
        relayDraft = host.relayURL
        effectiveRelayURL = host.relayURL
    }

    func activate() async {
        guard let host else { return }
        isTracking = true
        // Settings is reachable while a pair flow is in flight (Home → pair,
        // Settings → "Add new pairing" → back), so the list has to be live and
        // not a one-shot read like the Dart `_load()`.
        _ = try? await host.reloadPeers()
        applyPeers()
        trackPeers()
    }

    func deactivate() {
        // Ends the observation chain started by `trackPeers()`: the next
        // `onChange` fires, sees `isTracking == false`, and does not re-arm.
        //
        // The host is deliberately NOT dropped. `.onDisappear` also fires when
        // this screen is merely covered (a pushed `/pair`, the nickname sheet
        // on some iOS versions), and an in-flight `revoke` that found a `nil`
        // host would abandon the sequence half-done — deleted locally, never
        // published. Losing the subscription is recoverable; losing the host
        // mid-revoke is not.
        isTracking = false
    }

    /// Re-arms `withObservationTracking` after every change.
    ///
    /// `withObservationTracking` fires its `onChange` exactly once, so the
    /// only way to keep watching is to call it again. The short-lived `Task`
    /// here is the hop from the (nonisolated, synchronous) `onChange` back to
    /// the MainActor — it is a one-shot, not a `for await` loop, and the chain
    /// terminates the moment `deactivate()` flips `isTracking`.
    private func trackPeers() {
        guard isTracking, let host else { return }
        withObservationTracking {
            _ = host.peers
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isTracking else { return }
                self.applyPeers()
                self.trackPeers()
            }
        }
    }

    /// Re-derives the PAIRINGS state from the host. Internal so tests can
    /// drive it without an observation round trip.
    func applyPeers() {
        guard let host else { return }
        apply(host.peers)
        effectiveRelayURL = host.relayURL
    }

    private func apply(_ records: [PeerRecord]) {
        pairings = records.isEmpty ? .empty : .list(Self.ordered(records))
    }

    // MARK: - RELAY (spec 08 §9.1)

    /// Clears the inline error. Call from the field's `onChange` so a
    /// rejection does not outlive the text that caused it.
    func relayDraftEdited() {
        relayError = nil
    }

    /// Stuffs the default into the field and saves it, exactly like the Dart
    /// `Use default Relay` button — the field is updated *and* committed, so
    /// the user never ends up looking at a default they did not actually save.
    func useDefaultRelay() async {
        relayDraft = RelayURLPolicy.defaultRelayURL
        await saveRelayURL()
    }

    func saveRelayURL() async {
        guard let host, !isSavingRelay else { return }
        if let message = RelayURLPolicy.validationMessage(for: relayDraft) {
            relayError = message
            banner = nil
            return
        }
        relayError = nil
        isSavingRelay = true
        defer { isSavingRelay = false }

        let url = RelayURLPolicy.normalized(relayDraft)
        relayDraft = url
        host.setRelayURL(url)
        effectiveRelayURL = url

        // disconnect → reconnect, never a bare reconnect: the old socket is
        // still authenticated against the previous relay and its retry timer
        // would keep dialling it.
        await host.disconnect()
        // Plan-61 Phase 0 — `reconnect()` restores BOTH halves of the pointer.
        // Carrying only the peer drops the user onto the machine's fallback
        // room, i.e. a different chat than the one they were reading.
        await host.reconnect()
        show(Banner(text: "Relay updated", kind: .info))
    }

    // MARK: - PAIRINGS: nickname (spec 08 §10)

    func beginNicknameEdit(_ record: PeerRecord) {
        nicknameCandidate = record
        nicknameDraft = record.nickname ?? ""
    }

    /// Dismiss with no write. The Dart sheet returns `null` here; the
    /// absent-vs-empty distinction below is the whole trap.
    func cancelNicknameEdit() {
        nicknameCandidate = nil
        nicknameDraft = ""
    }

    /// Commits ``nicknameDraft``. A blank draft **clears** the nickname
    /// (the sheet's "Remove nickname" button routes here too) — that is the
    /// `''` return the Dart maps to `null` before saving. Cancelling is
    /// ``cancelNicknameEdit()`` and writes nothing.
    func commitNicknameEdit() async {
        guard let host, var record = nicknameCandidate else { return }
        let trimmed = nicknameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.isEmpty ? nil : trimmed
        nicknameCandidate = nil
        nicknameDraft = ""
        guard record.nickname != normalized else { return }
        record.nickname = normalized
        do {
            try await host.savePeer(record)
            try await host.reloadPeers()
            applyPeers()
        } catch {
            show(Banner(text: "Could not save the nickname: \(error.localizedDescription)",
                        kind: .error))
        }
    }

    // MARK: - PAIRINGS: revoke (spec 08 §9.3 — the ordering matters)

    func requestRevoke(_ record: PeerRecord) {
        guard revoking == nil else { return }
        revokeCandidate = record
    }

    /// The dialog's Cancel. Nothing is deleted and the row stays — the
    /// `confirmDismiss` → `false` behaviour, which in SwiftUI is free because
    /// a `.swipeActions` button never removes the row itself.
    func cancelRevoke() {
        revokeCandidate = nil
    }

    func confirmRevoke() async {
        guard let record = revokeCandidate else { return }
        revokeCandidate = nil
        await revoke(record.peer)
    }

    /// The seven steps of `settings_viewmodel.dart:95-140`, in order. Every
    /// line of this is load-bearing; the comments say which bug each prevents.
    func revoke(_ peer: PeerID) async {
        guard let host, revoking == nil else { return }
        revoking = peer
        defer { revoking = nil }

        // 1. Snapshot BEFORE anything mutates — after the delete there is no
        //    way to tell whether the socket was pointed at this machine.
        let wasActive = host.activePeer == peer

        // 2. Clear the pointer when it names the machine being revoked. Keyed
        //    on the pointer's `peer`, never on a device label: the label is
        //    editable and two machines can share one.
        if host.selectedSession?.peer == peer {
            await host.clearSelectedSession()
        }

        // 3. SILENT delete. The republishing `delete` would fire the hook,
        //    whose publish is refused by the empty-membership safety net for
        //    the last-peer case — leaving the relay listing a machine this
        //    device has already forgotten, which the next pull resurrects.
        do {
            try await host.deletePeerSilent(peer)
        } catch {
            show(Banner(text: "Could not revoke: \(error.localizedDescription)", kind: .error))
            return
        }

        let remaining = (try? await host.reloadPeers()) ?? []
        apply(remaining)

        // 4. The only `allowEmpty` opt-out in the app, and it is computed from
        //    what actually remains — never hard-coded. `allowEmpty: true` with
        //    a non-empty local list revokes every machine the Owner has.
        let publish = await host.publishMembership(allowEmpty: remaining.isEmpty)

        // 5. Drop the revoked key from the relay's presence push before any
        //    re-dial, so the new socket never subscribes to it.
        await host.subscribe(to: remaining.map(\.peer))

        // 6. Only tear the socket down if it was talking to this machine.
        if wasActive {
            await host.disconnect()
            if let fallback = Self.fallback(among: remaining) {
                // Peer half only: the room half belonged to the machine that
                // was just revoked.
                await host.selectPeerWithoutRoom(fallback.peer)
                await host.reconnect()
            }
        }

        // 7. Revoke means start fresh — the next resolve lands on onboarding.
        if remaining.isEmpty {
            host.onboardingCompleted = false
            host.reevaluateBootPhase()
        }

        switch publish {
        case .published:
            banner = nil
        case .deferred(let reason):
            // The local pairing IS gone; this is a warning, never a failure.
            // Surfacing it matters because until the blob lands the Mac keeps
            // believing it is paired (it self-revokes on its next 60 s poll
            // only once it sees a fresh blob without its key).
            show(Banner(
                text: "Revoked on this device. The relay was not updated (\(reason)) — "
                    + "it will republish when you reconnect.",
                kind: .warning
            ))
        }
    }

    // MARK: - Ordering

    /// `pairedAt`, then the peer's wire spelling as a tiebreak.
    ///
    /// The Dart renders `listPeers()` straight from an unordered map read, so
    /// the Settings list reorders itself between runs; boot and Home already
    /// use this rule (`settings_viewmodel.dart:120-127`). Applying it to the
    /// list too is a deliberate divergence — a stable list is not a feature
    /// worth an inconsistency.
    ///
    /// Sorting on `pairedAt` is safe: it is stamped once at pair time and is
    /// never re-stamped, unlike `started_at` (spec 08 §13.7).
    static func ordered(_ records: [PeerRecord]) -> [PeerRecord] {
        records.sorted { lhs, rhs in
            if lhs.pairedAt != rhs.pairedAt { return lhs.pairedAt < rhs.pairedAt }
            return lhs.peer.wireValue < rhs.peer.wireValue
        }
    }

    /// Which machine to fall back to when the revoked one was driving the
    /// socket. Deterministic by construction — see ``ordered(_:)``.
    static func fallback(among records: [PeerRecord]) -> PeerRecord? {
        ordered(records).first
    }

    // MARK: - Banner

    private func show(_ banner: Banner) {
        self.banner = banner
        guard banner.kind == .info else { return }
        // 2 s, matching the Dart snackbar. Warnings and errors stay until the
        // next action replaces them: "the relay did not hear about your
        // revoke" is not something to flash for two seconds.
        // The one `Task { }` in this model, and the exception is deliberate:
        // it is a one-shot timer, not a `for await` loop, it holds `self`
        // weakly, and it writes only if the banner it scheduled is still the
        // one on screen. There is nothing to leak and nothing to cancel. The
        // alternative — awaiting it from the view — would keep the Save button
        // spinning for two seconds.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.banner == banner else { return }
            self.banner = nil
        }
    }
}
