import Foundation
import RemotePiProtocol

/// One App↔Pi frame, already routed to the session it belongs to.
public struct InboundMessage: Sendable {
    /// The **sender's** `(peer, room)`. The relay rewrites both header fields
    /// on the way through, so an inbound envelope answers "who sent this, from
    /// which of their rooms" — which is exactly the demux key.
    public let session: SessionKey
    /// The decoded inner JSON bytes.
    public let payload: Data

    public init(session: SessionKey, payload: Data) {
        self.session = session
        self.payload = payload
    }
}

/// Live state for one paired machine: which rooms it has, which one is
/// addressed, and the App↔Pi conversation on that room.
///
/// ## The rules this type exists to enforce
///
/// - **Key by ``SessionKey``.** Never by display name, never by workspace
///   path, never by index in a list. Every "the sessions jump around" bug came
///   from breaking this.
/// - **A rename is a metadata patch.** It never re-keys a room, never restarts
///   a connection, never opens a second tile. Apply
///   ``RoomMetaPatch/nameAccepted(over:)`` before touching a label — the relay
///   re-broadcasts the *current* name when it rejects a stale patch, so an
///   inbound name is not proof of a rename.
/// - **Never derive a room id.** After ``ControlAction/createSession(id:idempotencyKey:workspace:displayName:)``
///   returns `action_ok`, wait for the matching
///   ``ControlFrame/roomAnnounced(peer:meta:)`` before opening anything
///   (plan 61, D8).
/// - **Hide the control room.** A room whose ``RoomMeta/isControlRoom`` is
///   true is never a chat tile — and its envelopes must bypass the
///   "drop frames from a room other than the active one" demux, since its
///   replies arrive while some unrelated chat is open.
/// - **`started_at` is not an ordering key.** It changes on every reconnect.
public actor SessionCoordinator {
    private let transport: any RelayTransport
    private let store: any SessionStore
    private let roomWaitBudget: Duration

    /// The room/presence cache. Public so a view model can subscribe to
    /// ``RoomRegistry/updates()`` directly instead of polling this actor.
    public let registry: RoomRegistry

    /// The machine control plane.
    public let control: MachineControlClient

    private var watched: [PeerID] = []
    private var selected: SessionKey?

    private var eventTask: Task<Void, Never>?
    private var eventLoopRunning = false

    private let inbox: AsyncStream<InboundMessage>
    private let inboxContinuation: AsyncStream<InboundMessage>.Continuation

    public init(transport: any RelayTransport, store: any SessionStore) {
        self.init(transport: transport, store: store, controlTimeout: .seconds(45))
    }

    /// - Parameters:
    ///   - controlTimeout: budget for one control RPC. 45 s, not the chat
    ///     default of 15 s: the supervisor forks `pi`, which loads settings and
    ///     an extension before it answers.
    ///   - roomWaitBudget: budget for step 2 of create — waiting for the new
    ///     session's room to announce itself. A *separate* 45 s; the two are
    ///     sequential, not shared.
    public init(
        transport: any RelayTransport,
        store: any SessionStore,
        controlTimeout: Duration = .seconds(45),
        roomWaitBudget: Duration = .seconds(45),
        registry: RoomRegistry = RoomRegistry()
    ) {
        self.transport = transport
        self.store = store
        self.registry = registry
        self.control = MachineControlClient(transport: transport, timeout: controlTimeout)
        self.roomWaitBudget = roomWaitBudget
        let stream = AsyncStream<InboundMessage>.makeStream()
        self.inbox = stream.stream
        self.inboxContinuation = stream.continuation
    }

    // MARK: - Lifecycle

    /// Subscribes to room and presence updates for `peers` and begins
    /// consuming ``RelayTransport/events``.
    ///
    /// Must be re-run after every reconnect: subscriptions live on the
    /// connection, not on the peer. The asymmetry is the trap — the relay
    /// clears **room** subscriptions on every connection close but keeps
    /// **presence** subscriptions until the peer's last connection drops. Skip
    /// the re-subscribe and you get no `room_announced`, no `room_ended` and no
    /// `room_meta_updated` at all: a permanently dead UI on a perfectly healthy
    /// socket (spec 02 T11).
    public func start(watching peers: [PeerID]) async throws {
        watched = peers
        startEventLoopIfNeeded()

        // Render from disk before the relay says anything — and for a machine
        // that is offline, where it never will. Seeded rooms are not live.
        for peer in peers {
            if let cached = try? await store.loadRooms(for: peer) {
                await registry.seed(cached, for: peer)
            }
        }

        try await subscribe(peers)
    }

    private func subscribe(_ peers: [PeerID]) async throws {
        // All four together, in this order. `subscribe_presence` backfills a
        // `peer_online` for peers already up; `subscribe_rooms` sends **no**
        // snapshot at all, which is why the checks follow.
        try await transport.send(.subscribePresence(peers: peers))
        try await transport.send(.subscribeRooms(peers: peers))
        guard !peers.isEmpty else { return }
        // The checks are hints, not RPCs: the relay suppresses a reply that is
        // byte-identical to the previous one on this connection, so a second
        // check with nothing changed in between answers *nothing*. Never await
        // one (spec 02 T4).
        try await transport.send(.presenceCheck(peers: peers))
        try await transport.send(.roomsCheck(peers: peers))
    }

    private func startEventLoopIfNeeded() {
        guard !eventLoopRunning else { return }
        eventLoopRunning = true
        // `events` is one stream per connection, so this re-reads the property
        // on each (re)start rather than caching it.
        let events = transport.events
        eventTask = Task { [weak self] in
            for await event in events {
                await self?.handle(event)
            }
            await self?.eventLoopEnded()
        }
    }

    private func eventLoopEnded() {
        eventLoopRunning = false
        eventTask = nil
    }

    deinit {
        // Otherwise a consumer of `messages` is suspended forever on a stream
        // whose producer no longer exists.
        inboxContinuation.finish()
    }

    /// Stops consuming events. Does not close the socket.
    public func stop() {
        eventTask?.cancel()
        eventTask = nil
        eventLoopRunning = false
    }

    // MARK: - Events

    private func handle(_ event: TransportEvent) async {
        switch event {
        case .connected:
            // Re-establish subscriptions on every fresh registration, not just
            // on the first. See `start(watching:)`.
            try? await subscribe(watched)

        case .control(let frame):
            await apply(frame)

        case .envelope(let envelope):
            await route(envelope)

        case .disconnected:
            // The live set is what the relay last told us. With no socket
            // there is no fresh signal about any room, and a stale set makes
            // every previously-live room flash green the moment the socket
            // returns — including rooms whose Pi exited during the outage.
            await registry.clearLiveness()
            // The connection that would have carried the replies is gone; a
            // silent hang is the worse failure.
            await control.failAll()
        }
    }

    private func apply(_ frame: ControlFrame) async {
        // The relay names a *destination* in `transport_error`, not a message,
        // so a failure for `(machine, "ctrl")` fails every control RPC in
        // flight for that machine. Without this the caller waits out the whole
        // 45 s budget for a gateway the relay already said is not there.
        if case .transportError(let peer, let room, let reason) = frame, room.isControl {
            await control.gatewayUnreachable(peer, reason: reason)
        }

        let changed = await registry.apply(frame)
        guard changed else { return }

        // Persist only the peers whose catalogue can have moved. Room frames
        // name their peer; presence frames do not touch the catalogue.
        switch frame {
        case .roomAnnounced(let peer, _),
             .rooms(let peer, _),
             .roomEnded(let peer, _, _),
             .roomMetaUpdated(let peer, _, _),
             .transportError(let peer, _, _):
            await persistRooms(for: peer)
        case .challenge, .peerOnline, .peerOffline, .presence:
            break
        }
    }

    private func persistRooms(for peer: PeerID) async {
        let rooms = await registry.allRooms(for: peer)
        try? await store.saveRooms(rooms, for: peer)
    }

    private func route(_ envelope: Envelope) async {
        guard let payload = envelope.payload else { return }

        // Offer it to the control plane first and correlate purely by
        // `in_reply_to`. The gateway addresses its replies to `room: "ctrl"`
        // while the relay routes on an exact `(peer, room)` registration, so
        // which socket a reply lands on is a machine-side detail. Claiming by
        // id works either way (spec 09 T1).
        if await control.deliver(payload) { return }

        // A `ctrl` envelope nobody claimed is not a conversation: it must never
        // reach a transcript, or the control room grows a phantom message box.
        if envelope.room.isControl { return }

        // Every payload leaves here tagged with the sender's `SessionKey`, so
        // there is no singleton "current session" for one room's `agent_chunk`s
        // to bleed into another's transcript. That bleed is exactly what the
        // Flutter client's active-room drop exists to prevent
        // (`ws_transport.dart`); tagging is the stronger form of the same rule,
        // and it also keeps a background session's history complete.
        let key = SessionKey(peer: envelope.peer, room: envelope.room)
        inboxContinuation.yield(InboundMessage(session: key, payload: payload))
    }

    /// Inbound App↔Pi frames, tagged with the session that sent them.
    ///
    /// One consumer. The buffer is unbounded on purpose: these frames are
    /// transcript content, and silently dropping the oldest would tear a hole
    /// in a conversation that no later re-sync repairs. Attach a consumer
    /// before `start(watching:)` and keep it attached.
    public var messages: AsyncStream<InboundMessage> { inbox }

    // MARK: - Rooms

    /// The rooms currently known for a machine, control room excluded.
    public func rooms(for peer: PeerID) async -> [RoomMeta] {
        await registry.rooms(for: peer)
    }

    /// The Device → Workspace → Session hierarchy for the given pairings.
    public func catalog(
        peers: [PeerRecord],
        filter: SessionFilter = .all
    ) async -> [DeviceGroup] {
        SessionCatalog.build(peers: peers, snapshot: await registry.snapshot(), filter: filter)
    }

    // MARK: - Selection

    /// Points the coordinator at a session. Pins it: discovery must not move
    /// the pointer to some other room just because this one is not up yet.
    ///
    /// Note what this does **not** do: adopt a freshly announced room as the
    /// active one. The Flutter client has exactly that heuristic and it is not
    /// role-guarded, so a machine whose only announced room is `ctrl` can
    /// silently relocate the user's conversation onto the control plane
    /// (spec 09 §2).
    public func select(_ session: SessionKey) async throws {
        guard !session.room.isControl else {
            throw SessionSelectionError.controlRoomIsNotASession
        }
        selected = session
        try? await store.saveSelectedSession(session)
    }

    public func selectedSession() -> SessionKey? { selected }

    /// Restores the last selection from disk.
    ///
    /// Restores the full ``SessionKey``. Restoring only the peer and defaulting
    /// the room to `main` is what reopened the wrong chat after a cold start.
    @discardableResult
    public func restoreSelection() async -> SessionKey? {
        guard let stored = try? await store.loadSelectedSession() else { return nil }
        // A stored `ctrl` selection can only come from a bug elsewhere, but it
        // would put the user in a chat that answers nothing — drop it.
        guard !stored.room.isControl else { return nil }
        selected = stored
        return stored
    }

    // MARK: - Sending

    /// Sends an inner frame to a specific room **without** moving the current
    /// selection — Home renames a session that is usually not the open chat.
    public func send(_ payload: Data, to session: SessionKey) async throws {
        let envelope = Envelope(peer: session.peer, room: session.room, payload: payload)
        // The relay drops an oversized envelope in total silence: no
        // `transport_error`, no close, no ack. Checking here — against the
        // relay's own `ct.len() * 3 / 4` arithmetic on the Base64 string, not
        // the real decoded size — is the only way the user ever learns
        // (spec 02 T8).
        guard !envelope.exceedsRelayLimit() else {
            throw RelayTransportError.payloadTooLarge(
                estimatedBytes: envelope.relayEstimatedPayloadBytes
            )
        }
        try await transport.send(envelope)
    }

    // MARK: - Control plane

    /// Issues a machine control-plane action against ``RoomID/control`` and
    /// awaits its ``ControlReply``.
    ///
    /// The caller owns the ``IdempotencyKey``: mint it once per user intent and
    /// pass the same one to every retry, or the deduplication the machine
    /// performs is worthless.
    public func perform(_ action: ControlAction, on machine: PeerID) async throws -> ControlReply {
        try await control.perform(action, on: machine).reply
    }

    /// The folders `machine` will accept a session in.
    public func listWorkspaces(on machine: PeerID) async throws -> [RemoteWorkspace] {
        try await control.listWorkspaces(on: machine)
    }

    /// The full create sequence: `create_session`, then wait for the room.
    ///
    /// **`action_ok` means "spawn requested", not "the room is up."** The reply
    /// lands as soon as the catalogue entry exists and `startWorkspace` has
    /// been *called*; the room appears later, when the forked `pi` boots its
    /// extension and sends `hello` with `room_id = REMOTE_PI_SESSION_ID`.
    /// Opening a chat before then addresses a room the relay does not know and
    /// the first message is dropped.
    ///
    /// The session id comes from the machine and only from the machine. Never
    /// derive it: a client that computes `sha256(realpath(cwd))[:12]` produces
    /// a value the post-plan-61 Pi never announces, and re-keys on rename.
    public func createSession(_ intent: CreateSessionIntent) async throws -> CreateSessionOutcome {
        let action = ControlAction.createSession(
            id: ControlRequestID.mint(),
            // Reused verbatim for every retry of this intent — that is the
            // whole contract. `id` is fresh per attempt; the key is not.
            idempotencyKey: intent.idempotencyKey,
            workspace: intent.workspace,
            displayName: intent.displayName
        )

        let result = try await control.perform(action, on: intent.machine)
        switch result.reply {
        case .error(_, _, let message):
            return .failed(message: message)

        case .ok(let success):
            guard let sessionID = success.session else {
                // The gateway always returns `session_id` on success, on the
                // replay path too. A reply without one is a protocol violation,
                // not an empty id to hand the UI.
                throw ControlPlaneError.malformedReply("create_session reply carried no session_id")
            }
            // `room_id == session_id` from plan 61 Phase 1 — but the room is
            // *observed*, never assumed: the key below is only used to watch
            // for the announcement the machine will make.
            let key = SessionKey(peer: intent.machine, room: sessionID.roomID)
            let online = await registry.waitForRoom(key, timeout: roomWaitBudget)
            return online ? .online(sessionID) : .acceptedNotYetOnline(sessionID)
        }
    }

    /// Renames a session **through its own chat room**, which is the only path
    /// that updates `room_meta.name` / `name_rev` on the relay and therefore
    /// the only one every other device sees.
    ///
    /// The `ctrl` room has a `session_rename` too, and it is a different thing:
    /// it writes the machine's `sessions.json` only, ignores `rev` entirely,
    /// and never publishes to the relay. Use that one only to relabel a
    /// catalogued session that is not running (no chat room exists to send to),
    /// and expect the two labels to diverge — nothing reconciles them
    /// (spec 09 §4.5, T7).
    ///
    /// `rev` must be the ``RoomMeta/nameRev`` last read off the wire. Never
    /// mint one: revisions are the Pi's to mint, seeded from its wall clock and
    /// forced strictly increasing so they survive a restart.
    public func renameSession(_ session: SessionKey, to displayName: String) async throws {
        let room = await registry.room(session)
        // `room_id == session_id` post-plan-61, but the Pi's chat handler
        // validates that `session_id` names *this* session before renaming, and
        // a legacy room's id is a `sha256(cwd[,name])` digest that would fail
        // that check. Prefer the published id and fall back to the room id.
        let target = room?.sessionID ?? SessionID(session.room.rawValue)
        let action = ControlAction.sessionRename(
            id: ControlRequestID.mint(),
            session: target,
            displayName: displayName,
            rev: room?.nameRev
        )
        // Addressed at the session's own room, and deliberately not through
        // `select`: renaming from Home must not relocate the open conversation.
        try await send(action.encoded(), to: session)
    }
}

/// Why a selection was refused.
public enum SessionSelectionError: Error, Hashable, Sendable {
    /// The machine control plane is not a conversation. Selecting it would
    /// open a chat that answers nothing and create a message box for a room
    /// that has no session id.
    case controlRoomIsNotASession
}
