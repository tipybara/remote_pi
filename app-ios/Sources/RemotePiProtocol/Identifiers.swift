import Foundation

// MARK: - SessionID

/// The authoritative identity of one Pi session (plan 61, D1).
///
/// Minted either by the Pi SDK (UUIDv7) or by the machine supervisor
/// (`crypto.randomUUID()`), and **never derived by the client**. The app must
/// not compute a session id, guess one, or reuse a display name as one: after
/// `create_session` it waits for `action_ok` and then for the matching
/// ``ControlFrame/roomAnnounced`` before it opens anything (plan 61, D8).
///
/// From plan 61 Phase 1 on, `room_id == session_id`. They stay separate types
/// because that equality is a *fact about the current generation of Pi*, not a
/// law: a pre-Phase-1 Pi still keys its room by `sha256(cwd[,name])`, and the
/// signal that a room is stable across renames is the **presence** of
/// `session_id` in its metadata, never its value.
public struct SessionID: Hashable, Sendable, Codable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// The room this session speaks on, per plan 61 Phase 1.
    ///
    /// Correct only for a Pi that published a `session_id`; for a legacy room
    /// the two differ and the app must use the announced ``RoomID``.
    public var roomID: RoomID { RoomID(rawValue) }
}

extension SessionID: CustomStringConvertible {
    public var description: String { rawValue }
}

// MARK: - WorkspaceID

/// A directory registered on one machine as a place sessions may run.
///
/// **Deviation from the plan text, deliberate** (plan 61 Phase 3): this is the
/// daemon id — `sha256(realpath(cwd))[..8]` — not a fresh UUID. In v1 a
/// workspace *is* a registered daemon folder, which already has a stable
/// machine-local id that every `daemon start/stop` path speaks; a parallel
/// UUID would be a second id space plus a mapping to keep in sync. Recorded in
/// `pi-extension/src/daemon/sessions.ts`.
///
/// Machine-scoped, like ``RoomID``: only meaningful together with the
/// ``PeerID`` of the machine that published it.
public struct WorkspaceID: Hashable, Sendable, Codable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension WorkspaceID: CustomStringConvertible {
    public var description: String { rawValue }
}

// MARK: - RoomID

/// The relay's routing sub-channel for a peer: the `room` field of an
/// ``Envelope`` and the `room_id` of every room control frame.
///
/// ## Scope
///
/// A room id means something **only inside one machine**, because every layer
/// that keys by it already carries that machine's ``PeerID`` alongside — the
/// relay registry keys `(peer_id, room_id)`, and so does every client cache.
/// Two machines emitting the same id is therefore harmless. The invariant that
/// does matter, and that any new cache in this client must respect:
/// **never key persistent state by a room id alone.** Pair it with the peer.
///
/// ## Generations
///
/// - **Session-keyed** (plan 61 Phase 1, current): the id *is* the
///   ``SessionID``. Renaming cannot re-key it.
/// - **Legacy digest**: first 12 characters of
///   `base64url(sha256(realpath(cwd)[ + NUL + name]))`. Still announced by a
///   pre-plan-61 Pi, and still re-keyed by `/name` — which is exactly the bug
///   plan 61 removed. Tolerate it; do not produce it.
/// - **Reserved**: ``RoomID/control`` (`"ctrl"`), the machine gateway, and
///   ``RoomID/main``, the room this client announces itself on in `hello`.
public struct RoomID: Hashable, Sendable, Codable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// The machine gateway's permanent room (plan 61 Phase 3, D4).
    ///
    /// Reserved: four characters, so it can be neither a 12-character legacy
    /// digest nor a session id (which the Pi requires to be 8–64 characters of
    /// `[A-Za-z0-9_-]`). A room with this id — or with
    /// ``RoomMeta/role`` == ``RoomRole/control`` — must **never** be rendered
    /// as a chat tile, and must be exempt from the "drop envelopes from a room
    /// other than the active one" demux, since its replies arrive while the
    /// user has some unrelated chat open.
    public static let control = RoomID("ctrl")

    /// The room a client registers itself on in `hello`.
    ///
    /// The relay defaults a missing `room` on an inbound envelope to `"main"`
    /// (`relay/src/protocol/outer.rs`), so this is also the fallback
    /// destination for a `pair_request` from a QR code that carried no `rm`.
    public static let main = RoomID("main")

    /// `true` for the machine control plane's reserved room.
    public var isControl: Bool { self == .control }

    /// `true` when the id has the shape a Pi will accept as a session-derived
    /// room: 8–64 characters of `[A-Za-z0-9_-]`
    /// (`roomIdForSession` in `pi-extension/src/rooms.ts`).
    ///
    /// Shape only. It says nothing about which generation produced the id — a
    /// legacy 12-character digest passes too. Use the presence of
    /// ``RoomMeta/sessionID`` for that question.
    public var hasSessionIDShape: Bool {
        guard (8...64).contains(rawValue.count) else { return false }
        return rawValue.allSatisfy { character in
            character.isASCII
                && (character.isLetter || character.isNumber || character == "_" || character == "-")
        }
    }
}

extension RoomID: CustomStringConvertible {
    public var description: String { rawValue }
}

// MARK: - Composite keys

/// The only safe key for anything persisted or cached per session:
/// the machine **and** the room.
///
/// A room id alone is machine-scoped, so using it by itself lets two paired
/// Macs collide in one cache. The Flutter client spells this key several
/// different ways (`<epk>:<roomId>`, `<epk>|<roomId>`, `msgs_<epk>__<roomId>`)
/// after normalising the epk; here there is one type and one normalisation,
/// because ``PeerID`` has no spelling to get wrong.
public struct SessionKey: Hashable, Sendable {
    public let peer: PeerID
    public let room: RoomID

    public init(peer: PeerID, room: RoomID) {
        self.peer = peer
        self.room = room
    }

    /// Stable string form for storage filenames and dictionary keys.
    ///
    /// Uses the URL-safe peer spelling so the value is filesystem-safe (the
    /// standard alphabet contains `/`). Stable across launches for a given
    /// key — safe to persist.
    public var storageKey: String { "\(peer.urlSafeValue)__\(room.rawValue)" }
}

extension SessionKey: CustomStringConvertible {
    public var description: String { "\(peer.shortDescription)|\(room.rawValue)" }
}

// MARK: - Request ids

/// Correlation id for a request/response pair (`id` → `in_reply_to`).
///
/// Every ``ClientFrame`` that expects an answer carries one; the reply echoes
/// it in `in_reply_to`. Opaque to the relay and to the Pi.
public struct RequestID: Hashable, Sendable, Codable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    /// Mints a fresh id. Uses a lowercase UUID string, matching what the
    /// Flutter client and the Pi both emit.
    public static func generate() -> RequestID {
        RequestID(UUID().uuidString.lowercased())
    }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension RequestID: CustomStringConvertible {
    public var description: String { rawValue }
}

/// Deduplication key for a mutating control-plane action.
///
/// **Required** on `create_session`, `session_start` and `session_stop`; the
/// gateway rejects a mutating frame that omits it rather than defaulting one
/// (`pi-extension/src/protocol/control_wire.ts`).
///
/// It must be **stable across retries of the same user intent** — the machine
/// keeps it for ≥24h and replays the original outcome, including the original
/// error, so that a retry loop cannot become a spawn loop. Minting a fresh key
/// per attempt defeats the entire mechanism: generate once when the user taps,
/// then reuse it for every resend of that tap.
public struct IdempotencyKey: Hashable, Sendable, Codable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    /// Mints a key for one new user intent. Call this **once** per intent.
    public static func generate() -> IdempotencyKey {
        IdempotencyKey(UUID().uuidString.lowercased())
    }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
