import Foundation
import RemotePiProtocol

// MARK: - Errors

/// Why a control-plane RPC did not produce a reply.
///
/// Note what is *not* here: "permission denied". A frame from a peer that is
/// not in the machine's `peers.json` is dropped in silence — no `action_error`,
/// no close, nothing — so an unpaired or revoked phone is indistinguishable
/// from a slow one. When the machine is visibly online and an RPC times out,
/// the most likely cause is authorization: say "this Mac no longer accepts
/// commands from this phone — re-pair", not "retry" (spec 09 §3).
public enum ControlPlaneError: Error, Hashable, Sendable {
    /// No reply within the budget. See the note above before writing the copy.
    case timeout
    /// The socket dropped while the RPC was in flight.
    case offline
    /// The relay answered `transport_error` for `(machine, "ctrl")`: the
    /// supervisor gateway is not registered, so nothing on that machine is
    /// listening. Fail immediately rather than burning the full 45 s — the
    /// Flutter control repository does not listen for this and hangs
    /// (spec 09 T6).
    case gatewayUnreachable(reason: String)
    /// The reply arrived but was not `action_ok` / `action_error`, or a
    /// mandatory field was missing.
    case malformedReply(String)
}

// MARK: - Result

/// A control reply plus the two fields the shared ``ControlReply`` shape does
/// not model.
public struct ControlRPCResult: Hashable, Sendable {
    public let reply: ControlReply

    /// `true` when the machine replayed a previous outcome for this
    /// idempotency key instead of executing.
    ///
    /// **A replayed `action_ok` is a smaller object**: first execution returns
    /// `session_id`, `workspace_id`, `display_name` and `path`; a replay
    /// returns `session_id` and `replayed: true` and nothing else. A decoder
    /// that requires `workspace_id` throws on exactly the retry path it exists
    /// to support (spec 09 T4).
    public let replayed: Bool

    /// `path` from a first-execution `create_session` reply. Absent on replays.
    public let path: String?

    public init(reply: ControlReply, replayed: Bool, path: String?) {
        self.reply = reply
        self.replayed = replayed
        self.path = path
    }
}

// MARK: - Intent

/// One user intent to create a session, carrying its own idempotency key.
///
/// The key lives **here**, in a value that outlives the retry loop, rather than
/// at the call site — mint it when the user opens the sheet and reuse it for
/// every Create tap and every reconnect retry.
///
/// The two failure modes are opposite and both silent:
/// - re-minting per attempt spawns a process per attempt;
/// - deriving the key from a value (`workspace_id`, `session_id`,
///   `display_name`, the rpc id, or any hash of them) pins the outcome for 24 h,
///   so the second "New session in this folder" silently replays the first
///   session's id (spec 09 §5.7, T3).
///
/// Hence: a fresh random UUID, minted once, never derived.
public struct CreateSessionIntent: Hashable, Sendable {
    public let machine: PeerID
    public let workspace: WorkspaceID
    public let displayName: String?
    public let idempotencyKey: IdempotencyKey

    /// Mints a new intent. Call once per user gesture.
    public init(machine: PeerID, workspace: WorkspaceID, displayName: String? = nil) {
        self.init(
            machine: machine,
            workspace: workspace,
            displayName: displayName,
            idempotencyKey: .generate()
        )
    }

    /// Rebuilds an intent with a key that already exists — restoring a pending
    /// create across an app relaunch, for instance. Never call this with a key
    /// derived from anything.
    public init(
        machine: PeerID,
        workspace: WorkspaceID,
        displayName: String?,
        idempotencyKey: IdempotencyKey
    ) {
        self.machine = machine
        self.workspace = workspace
        self.displayName = displayName
        self.idempotencyKey = idempotencyKey
    }
}

/// The outcome of the two-step create.
public enum CreateSessionOutcome: Hashable, Sendable {
    /// `action_ok` **and** the room announced itself.
    case online(SessionID)
    /// `action_ok`, but the room did not come up inside the budget.
    ///
    /// This is **not** a failure. The session exists in the machine's
    /// catalogue; the forked `pi` may still be loading. Say "created, not
    /// online yet", keep the row, and do not retry with a new key — a second
    /// `create_session` in a workspace whose daemon is already up mints a
    /// catalogue entry whose room will never appear (spec 09 T5).
    case acceptedNotYetOnline(SessionID)
    /// `action_error`. `message` is human-readable text with no code; do not
    /// pattern-match it beyond the documented `unknown workspace: ` /
    /// `unknown session: ` prefixes.
    case failed(message: String)
}

// MARK: - Client

/// Request ids for this plane.
public enum ControlRequestID {
    /// `ctl_<uuid>`.
    ///
    /// Chat `action_ok`s ride the same two frame types on the same socket, so
    /// request ids must be unique across the whole client, not just within this
    /// type — the prefix makes a collision visible in a log instead of silently
    /// resolving somebody else's promise. Also whitespace-free on purpose: the
    /// gateway trims `id` before echoing it on the happy path but echoes the
    /// **raw** id on the parse-error path, so an id with whitespace correlates
    /// on exactly one of the two branches (spec 09 T9).
    public static func mint() -> RequestID {
        RequestID("ctl_\(UUID().uuidString.lowercased())")
    }
}

/// Talks to a machine's supervisor gateway over the reserved `ctrl` room.
///
/// Every other client type addresses a *session*. This one addresses the
/// **machine**: the room that exists whether or not any chat process is up.
///
/// ## Correlation
///
/// Purely by `in_reply_to`. Never by room — the gateway addresses its replies
/// to `room: "ctrl"` while the relay routes on an exact `(peer, room)`
/// registration, so whether a reply lands on the `"ctrl"` socket or the
/// `"main"` one depends on a machine-side detail that is expected to change.
/// Correlating by id works for both, which is what makes this
/// forward-compatible with the fix (spec 09 T1).
public actor MachineControlClient {
    private let transport: any RelayTransport
    private let timeout: Duration

    private struct Pending {
        let machine: PeerID
        let continuation: CheckedContinuation<ControlRPCResult, any Error>
        let timeoutTask: Task<Void, Never>
    }
    private var pending: [RequestID: Pending] = [:]

    /// - Parameter timeout: 45 s by default, deliberately longer than a chat
    ///   action's 15 s: the supervisor has to fork `pi`, which loads settings
    ///   and an extension before it can answer. A shared 15 s constant times
    ///   out a healthy cold start on a loaded machine.
    public init(transport: any RelayTransport, timeout: Duration = .seconds(45)) {
        self.transport = transport
        self.timeout = timeout
    }

    // MARK: Sending

    /// Sends one action to `machine`'s `ctrl` room and awaits its reply.
    public func perform(
        _ action: ControlAction,
        on machine: PeerID
    ) async throws -> ControlRPCResult {
        let id = action.id
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = Pending(
                machine: machine,
                continuation: continuation,
                timeoutTask: makeTimeoutTask(for: id)
            )
            // Registered *before* the send so a reply that arrives while
            // `send` is still awaiting cannot find an empty table.
            Task { await self.transmit(action, to: machine, id: id) }
        }
    }

    private func transmit(_ action: ControlAction, to machine: PeerID, id: RequestID) async {
        do {
            let envelope = Envelope(
                peer: machine,
                // Explicit: the relay defaults a missing `room` to "main",
                // which would deliver a spawn request into the chat room.
                room: .control,
                payload: try action.encoded()
            )
            try await transport.send(envelope)
        } catch {
            fail(id, with: error)
        }
    }

    private func makeTimeoutTask(for id: RequestID) -> Task<Void, Never> {
        // Read out of `self` first: referencing `timeout` inside the task body
        // would capture the actor strongly and keep it alive for the whole
        // budget after the last caller let go.
        let budget = timeout
        return Task { [weak self] in
            try? await Task.sleep(for: budget)
            await self?.fail(id, with: ControlPlaneError.timeout)
        }
    }

    // MARK: Receiving

    /// Offers an inner frame decoded from an inbound envelope.
    ///
    /// Returns `true` when this client claimed it. A frame whose `in_reply_to`
    /// is not one of ours is left alone — the same `action_ok` / `action_error`
    /// shapes carry chat replies.
    @discardableResult
    public func deliver(_ payload: Data) -> Bool {
        guard
            let object = try? JSONSerialization.jsonObject(with: payload),
            let json = object as? [String: Any],
            let reply = ControlReply.parse(json),
            let waiting = pending[reply.inReplyTo]
        else { return false }

        pending[reply.inReplyTo] = nil
        waiting.timeoutTask.cancel()
        waiting.continuation.resume(
            returning: ControlRPCResult(
                reply: reply,
                replayed: json["replayed"] as? Bool ?? false,
                path: json["path"] as? String
            )
        )
        return true
    }

    /// The relay could not deliver to `(machine, "ctrl")`.
    ///
    /// Scoped to a destination rather than to a message — the outer envelope
    /// carries no id — so everything outstanding for that machine fails.
    public func gatewayUnreachable(_ machine: PeerID, reason: String) {
        let doomed = pending.filter { $0.value.machine == machine }.map(\.key)
        for id in doomed {
            fail(id, with: ControlPlaneError.gatewayUnreachable(reason: reason))
        }
    }

    /// The socket went away. Fails everything in flight: the connection that
    /// would have carried the replies is gone, and a silent hang is the worse
    /// failure.
    public func failAll(_ error: any Error = ControlPlaneError.offline) {
        // Snapshot the keys: `fail` mutates `pending`, and iterating the live
        // `keys` view while it changes is undefined.
        for id in Array(pending.keys) { fail(id, with: error) }
    }

    private func fail(_ id: RequestID, with error: any Error) {
        guard let waiting = pending.removeValue(forKey: id) else { return }
        waiting.timeoutTask.cancel()
        waiting.continuation.resume(throwing: error)
    }

    // MARK: Convenience

    /// `workspace_list` — the folders this machine will accept a session in.
    ///
    /// An empty list is a legitimate answer, not an error: it means nothing is
    /// registered yet, and the correct copy is "run `remote-pi create <folder>`
    /// on that Mac". There is deliberately no remote "register this path" —
    /// a path on the wire plus the daemon's `--approve` would be user-level RCE.
    public func listWorkspaces(on machine: PeerID) async throws -> [RemoteWorkspace] {
        let result = try await perform(.workspaceList(id: ControlRequestID.mint()), on: machine)
        switch result.reply {
        case .ok(let success): return success.workspaces
        case .error(_, _, let message): throw ControlActionFailure(message: message)
        }
    }

    /// `session_list` — the machine's catalogue, optionally filtered.
    ///
    /// `running` on each entry is a per-**workspace** fact (one daemon per
    /// cwd), so every session sharing a folder reports the same value. It is
    /// not per-session liveness: for that, ask the registry whether the room
    /// `room_id == session_id` is live.
    public func listSessions(
        on machine: PeerID,
        workspace: WorkspaceID? = nil
    ) async throws -> [RemoteSession] {
        let result = try await perform(
            .sessionList(id: ControlRequestID.mint(), workspace: workspace),
            on: machine
        )
        switch result.reply {
        case .ok(let success): return success.sessions
        case .error(_, _, let message): throw ControlActionFailure(message: message)
        }
    }
}

/// An `action_error` from the machine, carried as a Swift error.
public struct ControlActionFailure: Error, Hashable, Sendable {
    public let message: String
    public init(message: String) { self.message = message }
}
