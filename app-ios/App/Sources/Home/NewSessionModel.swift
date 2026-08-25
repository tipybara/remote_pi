import Foundation
import Observation
import RemotePiProtocol
import RemotePiSession

// ============================================================================
// New Session (spec 08 §7.9) — plan 61 Phase 3.
//
// The point of the whole phase: before it, creating a session required already
// having one, because discovery ran Pi → `room_announced` → app. A Mac with no
// interactive Pi open was simply unreachable. The supervisor's `ctrl` room is
// always up, so the phone can now ask.
//
// Two constraints are surfaced rather than hidden:
//
//   * Only ALREADY-REGISTERED folders are offered. There is no free-text path
//     field, because a path on the wire plus the daemon's `--approve` would be
//     user-level RCE (plan 61 D5).
//   * `action_ok` means "spawn requested", not "the room is up" (§13.10). The
//     sheet waits for the relay to announce the room before handing back a
//     session, and a timeout is reported as "created, not online yet" — never
//     as a failure, and never as a reason to retry with a new key.
// ============================================================================

/// The sheet's body, as one value.
enum NewSessionPhase: Hashable, Sendable {
    /// More than one reachable machine; the user picks.
    case pickMachine
    /// `workspace_list` in flight.
    case loadingWorkspaces
    /// Folders listed; the user picks one.
    case pickWorkspace
    /// `create_session` and/or the room wait in flight.
    case creating
    /// No machine is reachable at all (spec 08 §7.9, `plugZap`).
    case noMachine
    /// The machine answered with an empty catalogue (spec 08 §7.9, `folderX`).
    /// An empty list is a legitimate answer, not an error.
    case noWorkspaces
    /// The room came up. The sheet closes and Home opens it.
    case created(SessionKey)
}

@MainActor
@Observable
final class NewSessionModel {
    // MARK: State

    private(set) var machine: PeerRecord?
    private(set) var workspaces: [RemoteWorkspace]?
    private(set) var isLoading = false
    private(set) var isCreating = false
    /// A failure, or the honest "created but not online yet" notice. Not fatal:
    /// the picker stays usable underneath.
    private(set) var errorText: String?
    /// Which of the two create stages is running (spec 08 §7.9 step 5).
    private(set) var progressText: String?
    private(set) var created: SessionKey?

    /// Machines that can be asked right now. Read live rather than snapshotted
    /// at init, so a socket that drops while the sheet is open collapses the
    /// picker into ``NewSessionPhase/noMachine`` instead of offering a machine
    /// that will time out.
    var machines: [PeerRecord] { backend.machinesAcceptingSessions }

    var phase: NewSessionPhase {
        if let created { return .created(created) }
        if isCreating { return .creating }
        guard machine != nil else {
            return machines.isEmpty ? .noMachine : .pickMachine
        }
        if isLoading { return .loadingWorkspaces }
        guard let workspaces else { return .loadingWorkspaces }
        return workspaces.isEmpty ? .noWorkspaces : .pickWorkspace
    }

    // MARK: Idempotency

    /// One key per **target**, minted on first use and reused for every retry
    /// of that target (spec 08 §13.9).
    ///
    /// ## Deliberate divergence from `new_session_sheet.dart:47`
    ///
    /// The Flutter sheet mints a single key in `initState` and reuses it for
    /// *any* folder the user taps. That is correct for the case the rule was
    /// written for — tapping Create twice on the same folder must not spawn two
    /// processes, because the machine keeps the key for ≥24h and replays the
    /// original outcome, *including the original error*, so a retry loop cannot
    /// become a spawn loop.
    ///
    /// It is wrong for the case where the user taps folder A, gets an error,
    /// and then taps folder B: the machine sees a key it has already answered
    /// and replays A's outcome, so B silently never starts.
    ///
    /// Keying the mint by `(machine, workspace)` keeps the guarantee the rule
    /// exists for and drops the collision. What it must never become is a key
    /// *derived* from the target — a hash of `workspace_id` would pin the
    /// outcome for 24h and make the second "New session in this folder"
    /// silently replay the first session's id. These are minted random and
    /// merely *remembered* per target, which is a different thing.
    @ObservationIgnored private var keys: [Target: IdempotencyKey] = [:]

    private struct Target: Hashable {
        let machine: PeerID
        let workspace: WorkspaceID
    }

    // MARK: Wiring

    @ObservationIgnored private let backend: any HomeBackend
    @ObservationIgnored private let roomWaitBudget: Duration

    init(backend: any HomeBackend, roomWaitBudget: Duration = .seconds(45)) {
        self.backend = backend
        self.roomWaitBudget = roomWaitBudget
    }

    // MARK: Flow

    /// Called once when the sheet appears.
    ///
    /// A single reachable machine is auto-selected: a one-option picker is
    /// noise, and it is the overwhelmingly common case (spec 08 §7.9 step 1).
    func start() async {
        guard machine == nil, !isCreating else { return }
        let reachable = machines
        guard reachable.count == 1, let only = reachable.first else { return }
        await select(only)
    }

    func select(_ record: PeerRecord) async {
        guard !isCreating else { return }
        machine = record
        await loadWorkspaces()
    }

    /// Back to the machine list. Clears the folder list so a stale catalogue
    /// from the previous machine cannot be tapped.
    func clearMachine() {
        guard !isCreating else { return }
        machine = nil
        workspaces = nil
        errorText = nil
    }

    func loadWorkspaces() async {
        guard let machine, !isLoading else { return }
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        do {
            workspaces = try await backend.listWorkspaces(on: machine.peer)
        } catch {
            // Keep `workspaces` nil rather than `[]`: "we could not ask" is not
            // "this machine has no folders", and the two want different copy.
            workspaces = nil
            errorText = Self.describe(error)
        }
    }

    /// Ask the machine to spawn a background session in `workspace`.
    func create(in workspace: RemoteWorkspace) async {
        guard let machine, !isCreating else { return }
        isCreating = true
        errorText = nil
        defer {
            isCreating = false
            progressText = nil
        }

        let label = Self.label(for: machine)
        progressText = "Asking \(label) to start a session…"

        let intent = CreateSessionIntent(
            machine: machine.peer,
            workspace: workspace.workspaceID,
            displayName: workspace.displayName,
            idempotencyKey: key(machine: machine.peer, workspace: workspace.workspaceID)
        )

        let sessionID: SessionID
        do {
            sessionID = try await backend.requestSession(intent)
        } catch let failure as ControlActionFailure {
            errorText = failure.message
            return
        } catch {
            errorText = Self.describe(error)
            return
        }

        // `room_id == session_id` post plan-61 Phase 1 — but the room is
        // OBSERVED, never assumed. This key exists only to watch for the
        // announcement the machine will make; nothing opens until it lands
        // (plan 61 D8, spec 08 §13.10).
        let key = SessionKey(peer: machine.peer, room: sessionID.roomID)
        progressText = "Waiting for the session to come online…"

        guard await backend.waitForSession(key, timeout: roomWaitBudget) else {
            // Honest wording: the spawn WAS accepted, we just stopped waiting.
            // Retrying here with a fresh key is the one thing that must not
            // happen — a second `create_session` in a workspace whose daemon is
            // already up mints a catalogue entry whose room never appears.
            errorText = "Session created, but it has not come online yet. "
                + "It will appear in the list when it does."
            return
        }
        created = key
    }

    func dismissError() { errorText = nil }

    // MARK: Labels

    /// nickname → session name captured at pair time → short key
    /// (`_machineLabel`, spec 08 §7.9).
    static func label(for record: PeerRecord) -> String {
        if let nickname = record.nickname, !nickname.isEmpty { return nickname }
        if let sessionName = record.sessionName, !sessionName.isEmpty { return sessionName }
        return record.peer.shortDescription
    }

    // MARK: Internals

    private func key(machine: PeerID, workspace: WorkspaceID) -> IdempotencyKey {
        let target = Target(machine: machine, workspace: workspace)
        if let existing = keys[target] { return existing }
        let minted = IdempotencyKey.generate()
        keys[target] = minted
        return minted
    }

    private static func describe(_ error: any Error) -> String {
        if let failure = error as? ControlActionFailure { return failure.message }
        if let unavailable = error as? HomeBackendUnavailable {
            return unavailable.localizedDescription
        }
        switch error as? ControlPlaneError {
        case .timeout:
            // A frame from a peer that is not in the machine's `peers.json` is
            // dropped in silence — no `action_error`, no close. So a visibly
            // online machine that times out is most likely an authorization
            // problem, and "retry" would be the wrong advice (spec 09 §3).
            return "That Mac did not answer. If it is online, it may no longer "
                + "accept commands from this phone — try pairing again."
        case .offline:
            return "The connection to the relay dropped."
        case .gatewayUnreachable(let reason):
            return "That Mac is not accepting commands right now (\(reason))."
        case .malformedReply(let detail):
            return "That Mac sent an answer this app could not read (\(detail))."
        case nil:
            return error.localizedDescription
        }
    }
}
