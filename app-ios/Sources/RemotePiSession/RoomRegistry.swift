import Foundation
import RemotePiProtocol

// MARK: - Presence

/// What the relay last said about a machine's connectivity.
///
/// Three states, not two: "we have never asked / never been told" is different
/// from "the relay says it is down". A UI that collapses them shows every
/// paired Mac as offline for the first few hundred milliseconds after launch.
public enum PresenceState: Hashable, Sendable {
    case unknown
    /// `peer_online`, or a `presence` entry with `online: true`. `sinceTs` is
    /// always `nil` in practice — `peer_online` carries no timestamp and the
    /// relay explicitly nulls `since_ts` for an online peer — but it is
    /// modelled because the wire field exists on the snapshot shape.
    case online(sinceTs: Int64?)
    /// `peer_offline`, or a `presence` entry with `online: false`. `sinceTs` is
    /// `nil` for a peer the relay has never seen disconnect since its own
    /// process start (the map is in-memory only).
    case offline(sinceTs: Int64?)

    public var isOnline: Bool {
        if case .online = self { return true }
        return false
    }
}

// MARK: - Snapshot

/// An immutable read of ``RoomRegistry`` — what the UI renders from.
///
/// Deliberately a value type: it crosses out of the actor, so it must not be a
/// window onto mutable state.
public struct RegistrySnapshot: Hashable, Sendable {
    /// Every room known for a machine, **including** the `ctrl` room, ordered
    /// by ``RoomID`` — a stable, non-editable value.
    ///
    /// Never ordered by `name` (the user edits it, and the row would jump
    /// under their finger) and never by `started_at` (the relay re-stamps it
    /// on every reconnect — spec 02 T3).
    public var rooms: [PeerID: [RoomMeta]]

    /// Which rooms the relay currently reports as having a live connection.
    /// A room in ``rooms`` but not here is a grey tile whose history is still
    /// readable.
    public var live: [PeerID: Set<RoomID>]

    public var presence: [PeerID: PresenceState]

    public init(
        rooms: [PeerID: [RoomMeta]] = [:],
        live: [PeerID: Set<RoomID>] = [:],
        presence: [PeerID: PresenceState] = [:]
    ) {
        self.rooms = rooms
        self.live = live
        self.presence = presence
    }

    /// Chat rooms for a machine — the control room filtered out.
    ///
    /// The `ctrl` room must never become a tile, a session count, a message
    /// box or a restored selection. Filtering here, at the one boundary where
    /// rooms become sessions, is the whole point: the Flutter client filters in
    /// the Home widget and still has an un-role-guarded "adopt the first
    /// announced room" heuristic elsewhere that can latch onto `ctrl`
    /// (spec 09 §2, T10).
    public func chatRooms(for peer: PeerID) -> [RoomMeta] {
        (rooms[peer] ?? []).filter { !$0.isControlRoom }
    }

    /// Every room including the control room. Use this only when you actually
    /// mean "the transport-level room set".
    public func allRooms(for peer: PeerID) -> [RoomMeta] {
        rooms[peer] ?? []
    }

    public func room(_ key: SessionKey) -> RoomMeta? {
        rooms[key.peer]?.first { $0.roomID == key.room }
    }

    public func isLive(_ key: SessionKey) -> Bool {
        live[key.peer]?.contains(key.room) ?? false
    }

    public func presence(of peer: PeerID) -> PresenceState {
        presence[peer] ?? .unknown
    }

    /// `true` when the machine's supervisor gateway is up, i.e. the machine can
    /// be asked to create/start/stop sessions.
    ///
    /// Gate the "New session" entry point on this. Without it the user taps
    /// Create and waits out the full 45 s RPC timeout for a machine whose
    /// gateway is not running (spec 09 §2 "Liveness").
    public func controlPlaneIsUp(_ peer: PeerID) -> Bool {
        isLive(SessionKey(peer: peer, room: .control))
    }
}

// MARK: - Merge

/// The preserve rules for folding an announced/snapshotted ``RoomMeta`` into
/// what is already cached.
public enum RoomMerge {
    /// Folds `incoming` (from `room_announced` or a `rooms` entry) into
    /// `cached`.
    ///
    /// Every `nil` on `incoming` means **preserve**, never **clear**, because
    /// the relay omits null fields entirely
    /// (`skip_serializing_if = "Option::is_none"`) — so `nil` is
    /// indistinguishable from "this relay build does not send that field".
    /// Treating it as a clear would drop `session_id` from a known session and
    /// make it look legacy again (losing its workspace row), and would wipe the
    /// model badge on every reconnect.
    ///
    /// Two fields do *not* follow that rule, on purpose:
    ///
    /// - `working` is a non-nullable bool on the relay side and is always
    ///   serialized, so the incoming value is authoritative live state. A
    ///   preserve here would leave a spinner running after the turn ended.
    /// - `started_at` is always present and is re-stamped by the relay at every
    ///   registration, so it is taken verbatim and used for nothing but
    ///   display.
    ///
    /// `name` goes through the same strictly-greater `name_rev` gate the relay
    /// applies. An announce is a re-registration, not a rename: a Pi that
    /// reconnects while another device has already published a newer label must
    /// not drag it backwards.
    public static func merged(incoming: RoomMeta, into cached: RoomMeta?) -> RoomMeta {
        guard let cached else { return incoming }

        var result = incoming
        result.sessionID = incoming.sessionID ?? cached.sessionID
        result.workspacePath = incoming.workspacePath ?? cached.workspacePath
        result.cwd = incoming.cwd ?? cached.cwd
        result.role = incoming.role ?? cached.role
        result.model = incoming.model ?? cached.model
        result.thinking = incoming.thinking ?? cached.thinking

        // Start from the cached label, then let the shared gate decide. Written
        // as a patch so there is exactly one implementation of the rule in the
        // client — `RoomMetaPatch.nameAccepted(over:)` — matching
        // `relay/src/peers/registry.rs`.
        result.name = cached.name
        result.nameRev = cached.nameRev
        let patch = RoomMetaPatch(
            name: incoming.name.map { PatchField.set($0) } ?? .absent,
            nameRev: incoming.nameRev
        )
        patch.apply(to: &result)
        return result
    }
}

// MARK: - Registry

/// The session/room registry the UI reads.
///
/// Holds, per machine: every room ever seen, which of them are live right now,
/// and the machine's presence. Feed it ``ControlFrame`` values as they arrive;
/// read ``snapshot()`` or subscribe to ``updates()``.
///
/// ## Invariants
///
/// - **Everything is keyed by `(PeerID, RoomID)`.** A `room_id` is unique per
///   machine only, so a cache keyed by room id alone is a cross-machine
///   collision waiting to happen (spec 02 T2).
/// - **`room_ended` never deletes a room.** It clears liveness. The tile stays,
///   greyed, with its history readable — and post-plan-61 a rename never emits
///   `room_ended` at all, so the frame genuinely means "process gone"
///   (spec 02 T9).
/// - **A `rooms` snapshot is authoritative for liveness**, additive for the
///   catalogue: rooms missing from it are dead, not forgotten.
public actor RoomRegistry {
    private var roomsByPeer: [PeerID: [RoomID: RoomMeta]] = [:]
    private var liveByPeer: [PeerID: Set<RoomID>] = [:]
    private var presenceByPeer: [PeerID: PresenceState] = [:]

    private var subscribers: [UUID: AsyncStream<RegistrySnapshot>.Continuation] = [:]

    private struct RoomWaiter {
        let key: SessionKey
        let continuation: CheckedContinuation<Bool, Never>
        let timeout: Task<Void, Never>
    }
    private var waiters: [UUID: RoomWaiter] = [:]

    public init() {}

    // MARK: Reads

    public func snapshot() -> RegistrySnapshot {
        RegistrySnapshot(
            rooms: roomsByPeer.mapValues { sorted($0) },
            live: liveByPeer,
            presence: presenceByPeer
        )
    }

    /// Chat rooms for a machine, control room excluded, ordered by room id.
    public func rooms(for peer: PeerID) -> [RoomMeta] {
        sorted(roomsByPeer[peer] ?? [:]).filter { !$0.isControlRoom }
    }

    public func allRooms(for peer: PeerID) -> [RoomMeta] {
        sorted(roomsByPeer[peer] ?? [:])
    }

    public func room(_ key: SessionKey) -> RoomMeta? {
        roomsByPeer[key.peer]?[key.room]
    }

    public func isLive(_ key: SessionKey) -> Bool {
        liveByPeer[key.peer]?.contains(key.room) ?? false
    }

    public func controlPlaneIsUp(_ peer: PeerID) -> Bool {
        isLive(SessionKey(peer: peer, room: .control))
    }

    public func presence(of peer: PeerID) -> PresenceState {
        presenceByPeer[peer] ?? .unknown
    }

    /// A stream of snapshots. Yields the current one immediately so a late
    /// subscriber does not render empty until the next frame arrives.
    public func updates() -> AsyncStream<RegistrySnapshot> {
        AsyncStream { continuation in
            let id = UUID()
            continuation.yield(snapshot())
            subscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(id) }
            }
        }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    // MARK: Writes

    /// Seeds the catalogue from persistent storage.
    ///
    /// Seeded rooms are **not** live: nothing has announced them on this
    /// connection yet. Rendering them as live would show a green dot for a Pi
    /// that exited while the phone was in the user's pocket.
    public func seed(_ rooms: [RoomMeta], for peer: PeerID) {
        guard !rooms.isEmpty else { return }
        var table = roomsByPeer[peer] ?? [:]
        for room in rooms {
            table[room.roomID] = RoomMerge.merged(incoming: room, into: table[room.roomID])
        }
        roomsByPeer[peer] = table
        publish()
    }

    /// Applies one relay control frame. Returns `true` when the visible state
    /// actually changed.
    ///
    /// The return value is not decoration: the relay re-pushes `peer_online`,
    /// `presence` and `rooms` aggressively (every reconnect of every device,
    /// every Pi restart, and as a keep-alive). Emitting a snapshot for a
    /// no-op push rebuilds the whole Home list each time and keeps the phone
    /// warm for nothing.
    @discardableResult
    public func apply(_ frame: ControlFrame) -> Bool {
        let changed: Bool
        switch frame {
        case .challenge:
            // Handshake business; the transport consumes it. Never reaches a
            // registry in practice, but matching on it beats a default that
            // would swallow a future frame silently.
            changed = false

        case .peerOnline(let peer):
            changed = setPresence(.online(sinceTs: nil), for: peer)

        case .peerOffline(let peer, let sinceTs):
            changed = setPresence(.offline(sinceTs: sinceTs), for: peer)

        case .presence(let states):
            var dirty = false
            for state in states {
                let next: PresenceState =
                    state.online
                    ? .online(sinceTs: state.sinceTs)
                    : .offline(sinceTs: state.sinceTs)
                if setPresence(next, for: state.peer) { dirty = true }
            }
            changed = dirty

        case .roomAnnounced(let peer, let meta):
            changed = announce(meta, for: peer)

        case .rooms(let peer, let rooms):
            changed = applySnapshot(rooms, for: peer)

        case .roomEnded(let peer, let room, _):
            changed = markDead(room, for: peer)

        case .roomMetaUpdated(let peer, let room, let patch):
            changed = applyPatch(patch, to: room, for: peer)

        case .transportError(let peer, let room, _):
            // Trust it. The relay is the only party that knows whether a
            // `(peer, room)` has a live connection, so this turns the tile grey
            // NOW instead of after the ~20 s no-echo timer. The next
            // `room_announced` puts it back.
            //
            // The frame names a *destination*, not a message: the outer
            // envelope carries no id and `ct` is opaque, so nothing here can
            // tell which send failed. Callers with outstanding work for that
            // room must fail all of it — see `MachineControlClient`.
            changed = markDead(room, for: peer)
        }

        if changed { publish() }
        return changed
    }

    /// Clears every live set, keeping the room catalogue.
    ///
    /// Call this when the socket drops. The live set is what the relay last
    /// said, and a dropped socket means there is no fresh signal about *any*
    /// room. Keeping it across an outage makes every previously-live room flash
    /// green the instant the socket returns — before the relay's `rooms`
    /// snapshot lands — including rooms whose Pi exited during the outage.
    @discardableResult
    public func clearLiveness() -> Bool {
        guard !liveByPeer.isEmpty else { return false }
        liveByPeer.removeAll()
        publish()
        return true
    }

    // MARK: Waiting

    /// Suspends until `key` is live, or until `timeout` elapses.
    ///
    /// This is step 5 of the create-session sequence. `action_ok` only means
    /// "spawn requested": the room appears later, when the forked `pi` boots
    /// its extension and sends `hello`. A `false` here means "created, not
    /// online yet" — never "failed", and never a reason to delete the session
    /// (spec 09 §6).
    public func waitForRoom(_ key: SessionKey, timeout: Duration = .seconds(45)) async -> Bool {
        if isLive(key) { return true }
        let id = UUID()
        // Created before the continuation is installed, but it cannot fire
        // early: `resolve` is actor-isolated and the actor stays busy until
        // `withCheckedContinuation`'s body has run and suspended.
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.resolve(id, with: false)
        }
        return await withCheckedContinuation { continuation in
            waiters[id] = RoomWaiter(key: key, continuation: continuation, timeout: timeoutTask)
        }
    }

    private func resolve(_ id: UUID, with value: Bool) {
        // Removing first is what makes double-resume impossible when the room
        // comes up in the same instant the timeout fires.
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.timeout.cancel()
        waiter.continuation.resume(returning: value)
    }

    // MARK: Frame handlers

    private func setPresence(_ state: PresenceState, for peer: PeerID) -> Bool {
        guard presenceByPeer[peer] != state else { return false }
        presenceByPeer[peer] = state
        return true
    }

    private func announce(_ meta: RoomMeta, for peer: PeerID) -> Bool {
        var table = roomsByPeer[peer] ?? [:]
        let merged = RoomMerge.merged(incoming: meta, into: table[meta.roomID])
        let wasLive = liveByPeer[peer]?.contains(meta.roomID) ?? false
        let identical = table[meta.roomID] == merged
        if identical && wasLive { return false }

        table[meta.roomID] = merged
        roomsByPeer[peer] = table
        liveByPeer[peer, default: []].insert(meta.roomID)
        return true
    }

    private func applySnapshot(_ rooms: [RoomMeta], for peer: PeerID) -> Bool {
        var table = roomsByPeer[peer] ?? [:]
        for room in rooms {
            table[room.roomID] = RoomMerge.merged(incoming: room, into: table[room.roomID])
        }
        // The snapshot is the authoritative live set for this peer: a room
        // absent from it has no live connection. An *unknown* peer answers
        // `"rooms": []`, which means "all rooms dead", not "no information" —
        // so an empty array must still overwrite the live set.
        let nextLive = Set(rooms.map(\.roomID))
        let liveChanged = (liveByPeer[peer] ?? []) != nextLive
        let listChanged = table != (roomsByPeer[peer] ?? [:])
        guard liveChanged || listChanged else { return false }

        roomsByPeer[peer] = table
        liveByPeer[peer] = nextLive
        return true
    }

    private func markDead(_ room: RoomID, for peer: PeerID) -> Bool {
        guard var live = liveByPeer[peer], live.remove(room) != nil else { return false }
        if live.isEmpty {
            liveByPeer[peer] = nil
        } else {
            liveByPeer[peer] = live
        }
        return true
    }

    private func applyPatch(_ patch: RoomMetaPatch, to room: RoomID, for peer: PeerID) -> Bool {
        // A patch for a room we have never seen is dropped rather than used to
        // invent one: the frame carries only the five mutable fields, so the
        // room it would create would have no `session_id`, no workspace and no
        // role — a phantom tile that can never become a real session.
        guard var current = roomsByPeer[peer]?[room] else { return false }
        let before = current
        patch.apply(to: &current)
        guard current != before else { return false }
        roomsByPeer[peer]?[room] = current
        return true
    }

    // MARK: Fan-out

    private func publish() {
        let current = snapshot()
        for continuation in subscribers.values {
            continuation.yield(current)
        }
        for (id, waiter) in waiters where isLive(waiter.key) {
            resolve(id, with: true)
        }
    }

    private func sorted(_ table: [RoomID: RoomMeta]) -> [RoomMeta] {
        table.values.sorted { $0.roomID.rawValue < $1.roomID.rawValue }
    }
}
