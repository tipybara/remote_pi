import Foundation
import Observation
import RemotePiProtocol
import RemotePiSession

// ============================================================================
// The seam between Home and the composition root.
//
// `HomeScreenModel` talks to this, never to `AppModel` directly. Two reasons,
// and only one of them is testing:
//
// 1. **The model is testable without SwiftUI, without SQLite and without a
//    socket.** A fake conforms to this protocol in a dozen lines, which is
//    what lets the ordering, grouping, filter and rename rules — the rules
//    plan 61 exists for — be asserted rather than eyeballed in a simulator.
//
// 2. **It names, in one place, everything Home needs from the app.** Three of
//    the methods below are not implemented on `AppModel` yet (they need the
//    private `SessionCoordinator` / `SQLiteSessionStore` it owns). They are
//    declared here with an honest "unavailable" default so the UI degrades
//    into a real, reachable state instead of pretending, and so wiring them
//    up later is an edit to `AppModel` and to nothing else. See
//    ``HomeBackendUnavailable``.
// ============================================================================

/// Everything Home reads from and asks of the app.
@MainActor
protocol HomeBackend: AnyObject, Observable {
    // MARK: Read model

    /// `true` while the composition root is still starting up (spec 08 §7.1's
    /// `HomeLoading`).
    var isBooting: Bool { get }

    /// Paired machines. Home shows its first-pair empty state when empty.
    var homePeers: [PeerRecord] { get }

    /// The relay's view of rooms, liveness and presence.
    var homeSnapshot: RegistrySnapshot { get }

    /// The app↔relay socket. A property of the **socket**, not of any room.
    var isRelayConnected: Bool { get }

    /// Persisted preferences — Home reads and writes `homeGrouping` here.
    var preferences: AppPreferences { get }

    /// Machines that can be asked to start a session right now. Only the
    /// currently connected peer can ever qualify (spec 08 §7.9).
    var machinesAcceptingSessions: [PeerRecord] { get }

    /// Gated liveness: relay connected **and** the room announced.
    func isLive(_ session: SessionKey) -> Bool

    /// The relay's per-room `working` flag.
    func isWorking(_ session: SessionKey) -> Bool

    /// The presence ladder for one session, priority already applied.
    func presence(of session: SessionKey) -> PresenceLevel

    /// The pairing record for a machine.
    func peer(_ peer: PeerID) -> PeerRecord?

    // MARK: Actions

    /// Opens a session: persists the pointer, retargets the socket, requests a
    /// sync. Must be awaited **before** the selection is moved (spec 08 §7.8).
    func openSession(_ row: SessionRow) async

    /// Writes the label into this device's own cache, optimistically.
    ///
    /// Returns `false` when the build cannot do it, so the caller can pick
    /// honest copy instead of claiming a rename that did not happen.
    /// `nil` clears the label — a local-only affordance, because there is no
    /// "unset the name" on the wire (spec 08 §7.7).
    @discardableResult
    func setLocalSessionName(_ session: SessionKey, to name: String?) async -> Bool

    /// Sends `session_rename` through the session's own chat room — the only
    /// path that updates `room_meta.name`/`name_rev` on the relay and is
    /// therefore seen by every other device.
    ///
    /// Returns `nil` on success, or a human-readable reason. A **rejected**
    /// `name_rev` is not a failure: the relay re-broadcasts the winning name
    /// and the label converges (spec 08 §13.12).
    func renameSession(_ session: SessionKey, to displayName: String) async -> String?

    /// Evicts a session from this device's cache only. Nothing is sent to the
    /// Pi; if the session comes back online it reappears (spec 08 §7.7).
    /// Returns `nil` on success, or a reason.
    func deleteCachedSession(_ session: SessionKey) async -> String?

    /// `workspace_list` on the machine's `ctrl` room. An **empty list is a
    /// legitimate answer** — it means nothing is registered yet.
    func listWorkspaces(on machine: PeerID) async throws -> [RemoteWorkspace]

    /// `create_session`, awaiting only `action_ok`.
    ///
    /// Split from the wait on purpose: `action_ok` means "spawn requested",
    /// not "the room is up" (spec 08 §13.10), and the two stages have
    /// different progress copy the user needs to see.
    func requestSession(_ intent: CreateSessionIntent) async throws -> SessionID

    /// Waits for the relay to announce the new room. `false` means "created,
    /// not online yet" — never "failed" (spec 08 §7.9, §13.10).
    func waitForSession(_ session: SessionKey, timeout: Duration) async -> Bool

    /// Re-poll presence and rooms for every known peer (pull-to-refresh).
    func refreshLiveness() async
}

/// Raised by a `HomeBackend` method the current build cannot perform.
///
/// This is not an error state the *protocol* can produce — it is the
/// placeholder for a capability the composition root has not been given yet.
/// It exists so the affected surface renders a clear message rather than a
/// spinner that never resolves.
struct HomeBackendUnavailable: LocalizedError, Hashable {
    let capability: String

    var errorDescription: String? {
        "\(capability) is not available in this build yet."
    }
}


/// Fakes that predate `refreshLiveness()` keep compiling; a refresh they do
/// not model is a no-op, which is also the honest behaviour for a fake with no
/// socket.
extension HomeBackend {
    func refreshLiveness() async {}
}
