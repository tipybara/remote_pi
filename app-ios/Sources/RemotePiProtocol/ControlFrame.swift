import Foundation

// MARK: - Inbound

/// A frame the **relay itself** produces, as opposed to an ``Envelope`` it
/// merely forwards.
///
/// ## How to tell them apart on the socket
///
/// The relay's own rule, which a client must mirror exactly: a frame with a
/// top-level `type` key is a control frame; a frame with `peer` **and** `ct` is
/// an envelope. Check the envelope shape first — `room_announced` and friends
/// also carry a `peer`, and misrouting one into the envelope path is a silent
/// data loss.
///
/// ## Forward compatibility
///
/// ``parse(_:)`` returns `nil` for a `type` this build does not know. Dropping
/// an unknown control frame is correct; throwing is not, because the relay is
/// deployed independently of the client and will grow frames this build has
/// never heard of.
public enum ControlFrame: Hashable, Sendable {
    /// `{"type":"challenge","nonce":"<base64 std, 32 bytes>"}` — step 2 of the
    /// handshake. The nonce is signed **raw**: sign the 32 decoded bytes, not
    /// the Base64 text.
    case challenge(nonce: Data)

    /// A subscribed peer transitioned offline → online.
    ///
    /// Fires only on a **real transition**: a second connection from a peer
    /// that already had one produces nothing. Also pushed as a backfill right
    /// after `subscribe_presence` for peers that are already up, so a client
    /// does not need `presence_check` to learn the current state.
    case peerOnline(peer: PeerID)

    /// A subscribed peer's last connection went away. `sinceTs` is the relay's
    /// wall clock in milliseconds.
    case peerOffline(peer: PeerID, sinceTs: Int64)

    /// Answer to `presence_check`.
    ///
    /// The relay suppresses a reply identical to the previous one on the same
    /// connection, so **absence of a `presence` frame means "unchanged"**, not
    /// "lost". A client that treats silence as failure will flap.
    case presence(states: [PeerPresence])

    /// A peer opened a room. Fires once per `(peer, room)` lifecycle — on the
    /// **first** connection at that room, not on every reconnect.
    ///
    /// Carries the full ``RoomMeta`` flattened to the top level.
    case roomAnnounced(peer: PeerID, meta: RoomMeta)

    /// A peer's last connection at a room went away.
    case roomEnded(peer: PeerID, room: RoomID, sinceTs: Int64)

    /// Answer to `rooms_check`, and the snapshot pushed after
    /// `subscribe_rooms`. Deduplicated per `(connection, peer)` the same way
    /// ``presence`` is.
    case rooms(peer: PeerID, rooms: [RoomMeta])

    /// A room's metadata changed (plan 18/28/32 + plan 61 Phase 1 renames).
    ///
    /// **The `meta` here is a patch, not a snapshot** — apply it with
    /// ``RoomMetaPatch/apply(to:)`` rather than replacing the cached room.
    /// The relay always includes `working`, includes `name`/`name_rev`
    /// whenever the room has a label at all, and omits `model`/`thinking` when
    /// they are null. A `name` in this frame is therefore *not* proof of a
    /// rename: it is also how the relay re-syncs a device whose stale rename it
    /// just rejected. Re-run the revision gate locally.
    case roomMetaUpdated(peer: PeerID, room: RoomID, patch: RoomMetaPatch)

    /// The relay could not deliver an ``Envelope`` (plan 61 Phase 3).
    ///
    /// Before this existed, App↔Pi delivery failed **silently**: the optimistic
    /// bubble sat there until a ~20s no-echo timer swept it, with no way to
    /// tell "the Pi is gone" from "the Pi is slow".
    ///
    /// Scoped to a destination, **not to a message**. The outer envelope
    /// carries no message id and `ct` is opaque, so the relay cannot name the
    /// frame that failed nor synthesize an inner error body. On receipt: fail
    /// everything outstanding for that `(peer, room)` and mark the room offline
    /// immediately. `reason` is `"offline"` today; treat any other value as a
    /// generic failure rather than ignoring the frame.
    case transportError(peer: PeerID, room: RoomID, reason: String)

    /// One entry of a ``ControlFrame/presence(states:)`` snapshot.
    public struct PeerPresence: Hashable, Sendable {
        public let peer: PeerID
        public let online: Bool
        /// Milliseconds since epoch of the last transition. `nil` when the
        /// relay has never seen the peer.
        public let sinceTs: Int64?

        public init(peer: PeerID, online: Bool, sinceTs: Int64?) {
            self.peer = peer
            self.online = online
            self.sinceTs = sinceTs
        }
    }

    /// Parses one relay frame. Returns `nil` for an unknown or malformed
    /// `type`, and for a frame whose required fields do not parse.
    ///
    /// Takes a `JSONSerialization` dictionary rather than going through
    /// `Codable` on purpose: `room_announced` arrives flat *or* nested under
    /// `meta` depending on the relay build, and ``RoomMetaPatch`` needs to see
    /// key presence to distinguish absent from explicitly-null.
    public static func parse(_ json: [String: Any]) -> ControlFrame? {
        guard let type = json["type"] as? String else { return nil }

        func peerID(_ key: String = "peer") -> PeerID? {
            (json[key] as? String).flatMap(PeerID.init(base64:))
        }
        func timestamp(_ key: String) -> Int64 {
            (json[key] as? NSNumber)?.int64Value ?? 0
        }

        switch type {
        case "challenge":
            guard let nonce = (json["nonce"] as? String).flatMap(Base64.decodeTolerant) else {
                return nil
            }
            return .challenge(nonce: nonce)

        case "peer_online":
            guard let peer = peerID() else { return nil }
            return .peerOnline(peer: peer)

        case "peer_offline":
            guard let peer = peerID() else { return nil }
            return .peerOffline(peer: peer, sinceTs: timestamp("since_ts"))

        case "presence":
            let raw = json["states"] as? [[String: Any]] ?? []
            let states: [PeerPresence] = raw.compactMap { entry in
                guard let peer = (entry["peer"] as? String).flatMap(PeerID.init(base64:)) else {
                    return nil
                }
                return PeerPresence(
                    peer: peer,
                    online: entry["online"] as? Bool ?? false,
                    sinceTs: (entry["since_ts"] as? NSNumber)?.int64Value
                )
            }
            return .presence(states: states)

        case "room_announced":
            guard let peer = peerID(), let meta = RoomMeta.parseAnnouncement(json) else {
                return nil
            }
            return .roomAnnounced(peer: peer, meta: meta)

        case "room_ended":
            guard let peer = peerID(), let room = json["room_id"] as? String else { return nil }
            return .roomEnded(peer: peer, room: RoomID(room), sinceTs: timestamp("since_ts"))

        case "rooms":
            guard let peer = peerID() else { return nil }
            let raw = json["rooms"] as? [[String: Any]] ?? []
            return .rooms(peer: peer, rooms: raw.compactMap(RoomMeta.parseAnnouncement))

        case "room_meta_updated":
            guard let peer = peerID(), let room = json["room_id"] as? String else { return nil }
            let meta = json["meta"] as? [String: Any] ?? [:]
            return .roomMetaUpdated(
                peer: peer,
                room: RoomID(room),
                patch: RoomMetaPatch(metaJSONObject: meta)
            )

        case "transport_error":
            guard let peer = peerID() else { return nil }
            // `room_id` is always present in practice; the relay's own default
            // for a legacy envelope is `main`, so match it rather than dropping
            // an error frame we can still act on.
            let room = RoomID((json["room_id"] as? String) ?? RoomID.main.rawValue)
            return .transportError(
                peer: peer,
                room: room,
                reason: (json["reason"] as? String) ?? "unknown"
            )

        default:
            return nil
        }
    }
}

extension RoomMeta {
    /// Reads a ``RoomMeta`` out of a `room_announced` frame or a `rooms` entry.
    ///
    /// Handles both layouts seen in the wild:
    /// - **flat** — the relay serializes `RoomMeta` and stamps `type`/`peer`
    ///   onto the same object (current behaviour);
    /// - **nested** — a relay that forwards the Pi's `hello.room_meta` verbatim
    ///   puts the fields under `meta`.
    ///
    /// Flat wins where both are present.
    public static func parseAnnouncement(_ json: [String: Any]) -> RoomMeta? {
        guard let roomID = json["room_id"] as? String else { return nil }
        let nested = json["meta"] as? [String: Any] ?? [:]

        func string(_ key: String) -> String? {
            (json[key] as? String) ?? (nested[key] as? String)
        }
        func number(_ key: String) -> Int64? {
            ((json[key] as? NSNumber) ?? (nested[key] as? NSNumber))?.int64Value
        }
        func boolean(_ key: String) -> Bool? {
            (json[key] as? Bool) ?? (nested[key] as? Bool)
        }

        let cwd = string("cwd")
        return RoomMeta(
            roomID: RoomID(roomID),
            sessionID: string("session_id").map { SessionID($0) },
            // Legacy publishers only send `cwd`, and it holds the same
            // canonical path — fall back rather than leaving Home's
            // Device → Workspace → Session grouping blind.
            workspacePath: string("workspace_path") ?? cwd,
            name: string("name"),
            nameRev: number("name_rev"),
            role: string("role"),
            cwd: cwd,
            model: string("model"),
            thinking: string("thinking"),
            working: boolean("working") ?? false,
            startedAt: number("started_at") ?? 0
        )
    }
}

// MARK: - Outbound

/// A frame this client sends **to the relay**, as opposed to through it.
///
/// Every one of these carries a top-level `type`, which is what makes the
/// relay handle it instead of forwarding it. An ``Envelope`` must never carry
/// one.
public enum ClientControlFrame: Hashable, Sendable {
    /// Step 1 of the handshake. Must be the first frame on the socket and must
    /// arrive within 5 seconds (`HELLO_TIMEOUT_MS`) or the relay closes.
    ///
    /// - `pubkey`: this device's Ed25519 public key.
    /// - `room`: the room this connection registers under. A phone announces
    ///   itself on ``RoomID/main``; a Pi announces one room per session.
    /// - `meta`: published only by a Pi. A client sends `nil`.
    case hello(pubkey: PeerID, room: RoomID, meta: RoomMeta?)

    /// Step 3 of the handshake: Ed25519 signature over the **raw 32 nonce
    /// bytes** from ``ControlFrame/challenge(nonce:)``.
    case auth(signature: Data)

    /// Replace this connection's presence subscription list. An empty list
    /// unsubscribes from everything.
    case subscribePresence(peers: [PeerID])
    case unsubscribePresence(peers: [PeerID])

    /// Request a ``ControlFrame/presence(states:)`` snapshot. Remember the
    /// relay suppresses a reply identical to the last one on this connection.
    case presenceCheck(peers: [PeerID])

    /// Replace this connection's room subscription list. Room announcements
    /// (`room_announced` / `room_ended` / `room_meta_updated`) only arrive for
    /// subscribed peers.
    case subscribeRooms(peers: [PeerID])
    case unsubscribeRooms(peers: [PeerID])

    /// Request a ``ControlFrame/rooms(peer:rooms:)`` snapshot per peer.
    case roomsCheck(peers: [PeerID])

    /// Patch a room's metadata.
    ///
    /// The relay applies this to `(this connection's peer, room)` — so a client
    /// can only patch **its own** rooms, never a Pi's. Omitting `room` targets
    /// the room this connection registered under.
    case roomMetaUpdate(room: RoomID?, patch: RoomMetaPatch)

    /// The JSON object to serialize.
    public var jsonObject: [String: Any] {
        switch self {
        case .hello(let pubkey, let room, let meta):
            var object: [String: Any] = [
                "type": "hello",
                // Standard Base64 with padding. The relay tolerates other
                // spellings but canonicalizes to this one, and every `peer`
                // string it hands back is in this form.
                "pubkey": pubkey.wireValue,
                "room_id": room.rawValue,
            ]
            if let meta, let encoded = try? JSONEncoder().encode(meta),
               let dictionary = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any] {
                object["room_meta"] = dictionary
            }
            return object

        case .auth(let signature):
            return ["type": "auth", "sig": Base64.encodeStandard(signature)]

        case .subscribePresence(let peers):
            return frame("subscribe_presence", peers)
        case .unsubscribePresence(let peers):
            return frame("unsubscribe_presence", peers)
        case .presenceCheck(let peers):
            return frame("presence_check", peers)
        case .subscribeRooms(let peers):
            return frame("subscribe_rooms", peers)
        case .unsubscribeRooms(let peers):
            return frame("unsubscribe_rooms", peers)
        case .roomsCheck(let peers):
            return frame("rooms_check", peers)

        case .roomMetaUpdate(let room, let patch):
            var object: [String: Any] = [
                "type": "room_meta_update",
                "meta": patch.metaJSONObject,
            ]
            if let room { object["room_id"] = room.rawValue }
            return object
        }
    }

    private func frame(_ type: String, _ peers: [PeerID]) -> [String: Any] {
        ["type": type, "peers": peers.map(\.wireValue)]
    }

    /// UTF-8 JSON bytes ready for the socket. One frame per WebSocket message
    /// — the relay reads JSONL, never a batched array.
    public func encoded() throws -> Data {
        try JSONSerialization.data(withJSONObject: jsonObject, options: [])
    }
}
