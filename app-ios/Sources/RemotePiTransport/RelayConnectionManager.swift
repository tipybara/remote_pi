import Foundation
import RemotePiProtocol

/// Owns the relay connection across its whole life: backoff, subscription
/// replay, the two heartbeats, and the volatile "which rooms are up right now"
/// set.
///
/// Reproduces `app/lib/data/transport/connection_manager.dart`. That file's
/// header is a list of bugs whose fixes look redundant and are not; the ones
/// carried over here are marked at the code that implements them.
///
/// ## What this deliberately does *not* own
///
/// The **room catalogue** — the tiles Home renders, greyed, while the machine
/// is offline. That list survives a disconnect and a cold start, so it belongs
/// to the store, not to a connection. What lives here is only the set the
/// relay says is live *right now*, because that set is worthless the moment
/// the socket dies.
public actor RelayConnectionManager {
    // MARK: Types

    public enum Status: Sendable, Hashable {
        /// No peer selected yet, or explicitly stopped.
        case idle
        case connecting
        case online
        /// Waiting out the backoff. `attempt` is 0-based: attempt 0 waits 1 s.
        case retrying(attempt: Int, delay: Duration)
        /// `canRetry: false` is terminal — nothing schedules out of it.
        case offline(reason: String, canRetry: Bool)
    }

    public enum Event: Sendable {
        case status(Status)
        /// An App↔Pi frame that survived the room demux. `peer` and `room`
        /// name the **sender**.
        case envelope(Envelope)
        case control(ControlFrame)
        /// The live-room set for one peer changed — including being emptied by
        /// a disconnect.
        case liveRoomsChanged(peer: PeerID, live: Set<RoomID>)
    }

    // MARK: Stored state

    public nonisolated let events: AsyncStream<Event>
    private nonisolated let continuation: AsyncStream<Event>.Continuation

    private let channelFactory: WebSocketChannelFactory
    private let timing: TransportTiming

    private var relayURL: URL?
    private var signer: (any Signer)?
    private var remotePeer: PeerID?

    private var transport: RelayWebSocketTransport?
    private var pumpTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?

    private var status: Status = .idle
    private var connectInFlight = false

    /// Bumped on every connect attempt.
    ///
    /// The Flutter manager guards the same thing with
    /// `identical(currentChannel, closingChannel)`: when a retry
    /// authenticates, the relay drops the *previous* socket, and that close
    /// arrives late. Without the guard it re-enters the "connection lost" path
    /// and starts a self-sustaining retry storm that survives every reconnect.
    private var generation = 0

    /// Internal rather than private only so the tests can watch them: both
    /// counters are reset by side effects several layers away from where they
    /// are incremented, and that wiring is exactly what regressed before.
    private(set) var retryAttempt = 0
    private(set) var missedPings = 0
    private var pingCounter = 0

    private var subscribedPeers: [PeerID] = []

    private var activeRoom: RoomID = .main
    private var activeRoomOwner: PeerID?
    private var activeRoomPinned = false

    /// Which rooms the relay says are up **right now**, per peer. Cleared on
    /// every disconnect — see ``clearLiveRooms()``.
    private var liveRooms: [PeerID: Set<RoomID>] = [:]

    public init(
        channelFactory: @escaping WebSocketChannelFactory = URLSessionWebSocketChannel.factory,
        timing: TransportTiming = TransportTiming()
    ) {
        self.channelFactory = channelFactory
        self.timing = timing
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        self.events = stream
        self.continuation = continuation
    }

    // MARK: - Lifecycle

    /// Points the manager at a machine and connects.
    ///
    /// `preferredRoom` is the **last-opened hint** from the stored pairing —
    /// never identity. It seeds the active room only when the destination
    /// machine actually changed; reconnecting to the same Mac leaves the
    /// pointer exactly where the user left it, which is what stopped the chat
    /// jumping to another workspace after backgrounding.
    public func start(
        relayURL: URL,
        signer: any Signer,
        remotePeer: PeerID,
        preferredRoom: RoomID? = nil
    ) async {
        self.relayURL = relayURL
        self.signer = signer
        self.remotePeer = remotePeer

        if activeRoomOwner != remotePeer {
            activeRoom = preferredRoom ?? .main
            activeRoomOwner = remotePeer
            activeRoomPinned = false
        }
        retryAttempt = 0
        startStuckOfflineWatchdog()
        await connect()
    }

    /// Disconnects and stops retrying. Terminal until ``start(relayURL:signer:remotePeer:preferredRoom:)``
    /// is called again.
    public func stop() async {
        // Bump first. Closing the transport makes it emit `.disconnected`,
        // and the pump would read that as "the socket dropped" and schedule a
        // retry — reconnecting a connection the caller just asked us to stop.
        // The generation guard is what tells a deliberate teardown apart from
        // a real drop.
        generation += 1
        cancelRetry()
        cancelPing()
        await teardownTransport()
        clearLiveRooms()
        emit(.idle)
    }

    private func connect() async {
        guard let relayURL, let signer, remotePeer != nil else { return }
        guard !connectInFlight else { return }
        connectInFlight = true
        defer { connectInFlight = false }

        cancelRetry()
        cancelPing()
        // Tear the old transport down *before* opening a new one, and cancel
        // its event pump with it. The relay kills the previous socket as soon
        // as the new one authenticates; if the old pump were still attached,
        // that close would re-enter the retry path and the ladder would feed
        // itself.
        await teardownTransport()
        clearLiveRooms()

        emit(.connecting)

        generation += 1
        let attemptGeneration = generation
        let socket = RelayWebSocketTransport(channelFactory: channelFactory, timing: timing)
        transport = socket
        startPump(for: socket, generation: attemptGeneration)

        do {
            try await socket.connect(to: relayURL, as: signer)
        } catch {
            guard attemptGeneration == generation else { return }
            scheduleRetry(reason: "\(error)")
            return
        }
        guard attemptGeneration == generation else { return }

        // Push the room pointer down BEFORE reporting online: a fresh
        // transport defaults to `main`, and the very first send after connect
        // must already carry the right destination — otherwise it lands in the
        // phone's own room and the Pi never sees it.
        await socket.setActiveRoom(activeRoom)

        emit(.online)
        await replaySubscriptions()
        startInnerPing()
    }

    private func startPump(for socket: RelayWebSocketTransport, generation attemptGeneration: Int) {
        pumpTask = Task { [weak self] in
            for await event in socket.events {
                await self?.handle(event, generation: attemptGeneration)
            }
        }
    }

    private func teardownTransport() async {
        pumpTask?.cancel()
        pumpTask = nil
        if let transport {
            await transport.disconnect()
        }
        transport = nil
    }

    // MARK: - Inbound

    private func handle(_ event: TransportEvent, generation attemptGeneration: Int) async {
        // A stale generation is the close of a socket we already replaced.
        guard attemptGeneration == generation else { return }

        switch event {
        case .connected:
            break  // `connect()` owns the online transition.

        case .envelope(let envelope):
            // Real Pi traffic — and *only* Pi traffic — resets both counters.
            //
            // Resetting on a successful connect instead pinned the ladder at
            // 1 s forever: with the Pi down, the socket to the relay keeps
            // authenticating perfectly well. Control frames are no better as a
            // signal, for the same reason — presence and room snapshots keep
            // flowing from the relay while the agent is dead.
            missedPings = 0
            retryAttempt = 0
            continuation.yield(.envelope(envelope))

        case .control(let frame):
            apply(frame)
            continuation.yield(.control(frame))

        case .disconnected(let error):
            // The live set is now a lie: we have no fresh signal about any
            // room. Nothing renders green during the outage anyway
            // (``isRoomLive(_:of:)`` is gated on `online`), but a set that
            // survived would flip every room green the instant the socket came
            // back — before the relay's snapshot lands — including rooms whose
            // Pi exited during the outage.
            clearLiveRooms()
            cancelPing()
            scheduleRetry(reason: error.map { "\($0)" } ?? "closed")
        }
    }

    private func apply(_ frame: ControlFrame) {
        switch frame {
        case .roomAnnounced(let peer, let meta):
            insertLiveRoom(meta.roomID, of: peer)

        case .roomEnded(let peer, let room, _):
            // "The process is gone", not "the session was deleted". Post-plan-61
            // a rename never produces this frame, so the tile stays; only the
            // live flag drops.
            removeLiveRoom(room, of: peer)

        case .rooms(let peer, let rooms):
            // The authoritative live set for that peer. An empty array means
            // "every room is dead", not "no information" — replace wholesale.
            let live = Set(rooms.map(\.roomID))
            if liveRooms[peer] != live {
                if live.isEmpty { liveRooms.removeValue(forKey: peer) } else { liveRooms[peer] = live }
                continuation.yield(.liveRoomsChanged(peer: peer, live: live))
            }

        case .transportError(let peer, let room, _):
            // Scoped to a destination, never to a message: the outer envelope
            // carries no id and `ct` is opaque, so the relay cannot say which
            // frame failed. Drop the room's live flag now so outstanding sends
            // can be failed immediately instead of waiting out a ~20 s
            // no-echo timer. The next `room_announced` puts it back.
            removeLiveRoom(room, of: peer)

        case .challenge, .peerOnline, .peerOffline, .presence, .roomMetaUpdated:
            // Presence and metadata are the session layer's business; the
            // frames are forwarded untouched on `events`.
            break
        }
    }

    // MARK: - Subscriptions

    /// Replaces the subscription set and asks for a snapshot.
    ///
    /// All four frames go out together because the relay is asymmetric:
    /// `subscribe_presence` backfills a `peer_online` for everyone already up,
    /// but `subscribe_rooms` sends **nothing** back. Without the two `_check`
    /// frames a client that subscribes after boot sits with an empty room list
    /// until the next cold start.
    public func subscribe(to peers: [PeerID]) async {
        subscribedPeers = peers
        guard let socket = transport else { return }
        try? await socket.send(.subscribePresence(peers: peers))
        try? await socket.send(.subscribeRooms(peers: peers))
        guard !peers.isEmpty else { return }
        try? await socket.send(.presenceCheck(peers: peers))
        try? await socket.send(.roomsCheck(peers: peers))
    }

    /// Re-sends the cached subscription after every (re)connect.
    ///
    /// **Mandatory, not an optimization.** The relay clears *room*
    /// subscriptions on every connection close (`peer.rs:465`), so a
    /// reconnect without this produces no `room_announced`, no `room_ended`
    /// and no `room_meta_updated` — a permanently dead UI on a perfectly
    /// healthy socket. Presence subscriptions outlive a single connection
    /// (they are dropped only when the peer fully offlines), but re-sending is
    /// idempotent and cheap, so both go.
    ///
    /// The order is the shipped one (`connection_manager.dart:1171-1179`) and
    /// differs from ``subscribe(to:)``: subscribe/check are interleaved per
    /// family rather than grouped.
    private func replaySubscriptions() async {
        guard !subscribedPeers.isEmpty, let socket = transport else { return }
        try? await socket.send(.subscribePresence(peers: subscribedPeers))
        try? await socket.send(.presenceCheck(peers: subscribedPeers))
        try? await socket.send(.subscribeRooms(peers: subscribedPeers))
        try? await socket.send(.roomsCheck(peers: subscribedPeers))
    }

    // MARK: - Room targeting

    /// Points the conversation at `room`.
    ///
    /// `pinned` records that this came from an explicit choice — a user tap or
    /// a restored preference — as opposed to a discovery hint. It is set
    /// **before** the no-op check on purpose: re-tapping the room you are
    /// already in still upgrades a tentative pointer to a user choice.
    public func setActiveRoom(_ room: RoomID, owner: PeerID, pinned: Bool = true) async {
        if pinned { activeRoomPinned = true }
        activeRoomOwner = owner
        guard room != activeRoom else { return }
        activeRoom = room
        await transport?.setActiveRoom(room)
    }

    /// Adopts a discovered room, but only over an unpinned pointer whose
    /// current target the relay does not report as live.
    @discardableResult
    public func adoptDiscoveredRoom(_ room: RoomID, owner: PeerID) async -> Bool {
        guard !activeRoomPinned else { return false }
        guard activeRoomOwner == owner else { return false }
        guard !(liveRooms[owner]?.contains(activeRoom) ?? false) else { return false }
        activeRoom = room
        await transport?.setActiveRoom(room)
        return true
    }

    public func currentActiveRoom() -> RoomID { activeRoom }
    public func currentStatus() -> Status { status }

    /// `false` whenever the connection is not online, whatever the cache says.
    ///
    /// The gate is the reason clearing the cache on disconnect is safe *and*
    /// the reason it is still necessary: nothing renders green during the
    /// outage because of this check, but the stale set would light everything
    /// up in the gap between "socket back" and "snapshot arrived".
    public func isRoomLive(_ room: RoomID, of peer: PeerID) -> Bool {
        guard status == .online else { return false }
        return liveRooms[peer]?.contains(room) ?? false
    }

    public func liveRooms(of peer: PeerID) -> Set<RoomID> {
        guard status == .online else { return [] }
        return liveRooms[peer] ?? []
    }

    // MARK: - Sending

    /// Addresses one payload at a specific room **without moving the active
    /// room** — machine-control RPCs (`ctrl`) and renames from Home.
    public func send(_ payload: Data, to peer: PeerID, room: RoomID) async throws {
        guard let socket = transport else { throw RelayTransportError.notConnected }
        try await socket.sendToRoom(payload, peer: peer, room: room)
    }

    public func send(_ frame: ClientControlFrame) async throws {
        guard let socket = transport else { throw RelayTransportError.notConnected }
        try await socket.send(frame)
    }

    /// Addresses one payload at the conversation the user has open.
    public func sendToActiveRoom(_ payload: Data) async throws {
        guard let socket = transport, let peer = remotePeer else {
            throw RelayTransportError.notConnected
        }
        try await socket.sendToActiveRoom(payload, peer: peer)
    }

    // MARK: - Retry ladder

    private func scheduleRetry(reason: String) {
        cancelRetry()
        let delay = timing.backoffDelay(forAttempt: retryAttempt)
        emit(.retrying(attempt: retryAttempt, delay: delay))
        retryTask = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            if Task.isCancelled { return }
            await self?.retryFired()
        }
    }

    private func retryFired() async {
        retryTask = nil
        // Incremented when the timer fires, immediately before the attempt —
        // so the first retry after a drop always waits the first rung (1 s)
        // and the ladder only climbs on repeated failure.
        retryAttempt += 1
        await connect()
    }

    private func cancelRetry() {
        retryTask?.cancel()
        retryTask = nil
    }

    /// Belt-and-braces sweep: we *should* be reconnecting, but nothing is
    /// scheduled and no attempt is in flight. Cheap, and it has caught dropped
    /// retry chains in production.
    private func startStuckOfflineWatchdog() {
        guard watchdogTask == nil else { return }
        let interval = timing.stuckOfflineWatchdogInterval
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                await self?.sweepStuckOffline()
            }
        }
    }

    private func sweepStuckOffline() {
        guard remotePeer != nil else { return }
        guard status != .online else { return }
        if case .offline(_, canRetry: false) = status { return }
        if case .idle = status { return }
        guard !connectInFlight, retryTask == nil else { return }
        scheduleRetry(reason: "stuck offline")
    }

    // MARK: - Inner ping (Pi liveness, not socket liveness)

    private func startInnerPing() {
        cancelPing()
        let interval = timing.innerPingInterval
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                await self?.pingTick()
            }
        }
    }

    private func pingTick() async {
        guard status == .online, let socket = transport, let peer = remotePeer else { return }

        // Incremented unconditionally, *before* the send: an answer resets it
        // on the inbound path. Ordering matters — counting after the send
        // would let a reply that arrives inside the same tick be credited to
        // the wrong probe.
        missedPings += 1
        if missedPings == timing.missedPingsBeforeRoomOffline {
            markActiveRoomOffline()
            // Deliberately no early return. Pings keep firing and the counter
            // keeps climbing, so this fires exactly once per outage; when the
            // Pi comes back, any inbound frame resets the counter and
            // `room_announced` puts the room back in the live set.
        }

        pingCounter += 1
        let payload = Data(#"{"type":"ping","id":"ping_\#(pingCounter)"}"#.utf8)
        do {
            try await socket.sendToRoom(payload, peer: peer, room: activeRoom)
        } catch {
            // A *send* failure is socket loss, not Pi silence. Two different
            // failures, two different responses: this one tears the connection
            // down, missed pings do not.
            cancelPing()
            clearLiveRooms()
            scheduleRetry(reason: "ping send failed: \(error)")
        }
    }

    /// Marks only the room the user is looking at as offline, and leaves the
    /// socket alone.
    ///
    /// Tearing the WS down on Pi silence is what produced the permanent
    /// `room_already_open` deadlock: the relay frees its registry slot only
    /// when its own send errors, which on a half-open TCP takes minutes, so
    /// every reconnect during that window was rejected and the app sat
    /// offline. Presence and the other rooms keep flowing here.
    private func markActiveRoomOffline() {
        guard let peer = remotePeer else { return }
        removeLiveRoom(activeRoom, of: peer)
    }

    private func cancelPing() {
        pingTask?.cancel()
        pingTask = nil
        missedPings = 0
    }

    // MARK: - Live-room bookkeeping

    private func insertLiveRoom(_ room: RoomID, of peer: PeerID) {
        var live = liveRooms[peer] ?? []
        guard live.insert(room).inserted else { return }
        liveRooms[peer] = live
        continuation.yield(.liveRoomsChanged(peer: peer, live: live))
    }

    private func removeLiveRoom(_ room: RoomID, of peer: PeerID) {
        guard var live = liveRooms[peer], live.remove(room) != nil else { return }
        if live.isEmpty { liveRooms.removeValue(forKey: peer) } else { liveRooms[peer] = live }
        continuation.yield(.liveRoomsChanged(peer: peer, live: live))
    }

    private func clearLiveRooms() {
        guard !liveRooms.isEmpty else { return }
        let peers = Array(liveRooms.keys)
        liveRooms.removeAll()
        for peer in peers {
            continuation.yield(.liveRoomsChanged(peer: peer, live: []))
        }
    }

    // MARK: - Status

    private func emit(_ next: Status) {
        status = next
        continuation.yield(.status(next))
    }
}
