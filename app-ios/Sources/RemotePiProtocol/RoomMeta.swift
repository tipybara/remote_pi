import Foundation

/// What the relay knows about one room, as published in `hello.room_meta` and
/// re-emitted in `room_announced` and `rooms`.
///
/// The relay stores these fields and never interprets them, with one
/// exception: it enforces the ``nameRev`` ordering rule on a name patch. See
/// ``RoomMetaPatch``.
///
/// ## Serialization shape
///
/// The relay serializes `RoomMeta` **flat** (`relay/src/rooms.rs`), skipping
/// every `nil` optional and always emitting `working` and `started_at`. So a
/// `rooms` snapshot entry looks like:
///
/// ```jsonc
/// { "room_id": "019ffb64-…", "session_id": "019ffb64-…",
///   "workspace_path": "/Users/x/proj", "name": "backend",
///   "name_rev": 1780000000000, "cwd": "/Users/x/proj",
///   "model": "claude-sonnet-4.5", "thinking": "high",
///   "working": false, "started_at": 1780000000123 }
/// ```
///
/// A `room_announced` frame carries the same keys hoisted to the **top level**
/// alongside `type` and `peer`. A relay that forwards the Pi's `room_meta`
/// verbatim instead nests them under `meta` — the Flutter client reads both,
/// and so should this one (``ControlFrame`` does).
public struct RoomMeta: Hashable, Sendable, Codable {
    /// The transport key. Equal to ``sessionID`` from plan 61 Phase 1 on.
    public var roomID: RoomID

    /// The authoritative Pi session UUID (plan 61 Phase 1).
    ///
    /// **Its presence, not its value, is the signal.** A room that carries it
    /// is stable across renames; a room without it comes from a pre-plan-61 Pi
    /// whose id is `sha256(cwd[,name])` and *will* still change on `/name`.
    /// Absent on a legacy Pi, and absent when the session id was not yet
    /// resolvable at the moment the room opened.
    public var sessionID: SessionID?

    /// Canonical `realpath(cwd)` of this session's workspace (plan 61 Phase 1).
    ///
    /// What Home groups by (Device → Workspace → Session). Symlinks are already
    /// resolved Pi-side, so two spellings of one directory collapse to one row.
    /// When absent, fall back to ``cwd``, which holds the same value on a
    /// legacy Pi — the relay itself applies that fallback when building the
    /// room from a `hello`.
    public var workspacePath: String?

    /// The editable label. **Metadata, never identity** (plan 61, D2).
    ///
    /// Never a storage key, never a sort key, never part of a room id. `nil`
    /// means "no label published"; the UI falls back to the workspace basename.
    public var name: String?

    /// Monotonic revision of ``name``, minted Pi-side from the wall clock so it
    /// keeps rising across restarts.
    ///
    /// A name update is applied only when its revision is **strictly greater**
    /// than the one already held — see ``RoomMetaPatch/nameAccepted(over:)``.
    /// `nil` means the publisher does not version its label, in which case the
    /// update is taken on trust.
    public var nameRev: Int64?

    /// `"control"` for the machine gateway's `ctrl` room, absent for a chat
    /// room (plan 61 Phase 3). See ``RoomRole``.
    public var role: String?

    /// Legacy working-directory field. Same value as ``workspacePath`` on a
    /// current Pi; the only one a pre-plan-61 Pi publishes.
    public var cwd: String?

    /// Display id of the model this session runs (`"claude-sonnet-4.5"`).
    /// `nil` = not reported yet.
    public var model: String?

    /// Current thinking level as an opaque wire string. Parse with
    /// ``ThinkingLevel/init(wire:)``; keep the raw string when it does not
    /// parse, since the relay never interprets it and a future Pi may add a
    /// level this build does not know.
    public var thinking: String?

    /// `true` while an agent turn is in flight.
    ///
    /// A plain bool: `false` **is** the off state, so there is no "clear to
    /// null" for it. Always present in relay output; defaults to `false` until
    /// the Pi reports otherwise.
    public var working: Bool

    /// When the relay registered this room, in milliseconds since epoch.
    ///
    /// **Changes on every reconnect.** Never a key, never a sort criterion,
    /// never a heuristic for "which session is newer".
    public var startedAt: Int64

    public init(
        roomID: RoomID,
        sessionID: SessionID? = nil,
        workspacePath: String? = nil,
        name: String? = nil,
        nameRev: Int64? = nil,
        role: String? = nil,
        cwd: String? = nil,
        model: String? = nil,
        thinking: String? = nil,
        working: Bool = false,
        startedAt: Int64 = 0
    ) {
        self.roomID = roomID
        self.sessionID = sessionID
        self.workspacePath = workspacePath
        self.name = name
        self.nameRev = nameRev
        self.role = role
        self.cwd = cwd
        self.model = model
        self.thinking = thinking
        self.working = working
        self.startedAt = startedAt
    }

    /// `true` when this is the machine control plane rather than a
    /// conversation. Such a room must not appear as a chat tile, and its
    /// envelopes must bypass the active-room demux.
    public var isControlRoom: Bool {
        role == RoomRole.control.rawValue || roomID.isControl
    }

    /// `true` when this room's id is stable across renames — i.e. the Pi
    /// published a ``sessionID``. A `false` here means a `/name` will still
    /// produce `room_ended` + a new tile.
    public var hasStableIdentity: Bool { sessionID != nil }

    /// The workspace key to group by, with the documented legacy fallback.
    public var effectiveWorkspacePath: String? { workspacePath ?? cwd }

    public enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case sessionID = "session_id"
        case workspacePath = "workspace_path"
        case name
        case nameRev = "name_rev"
        case role
        case cwd
        case model
        case thinking
        case working
        case startedAt = "started_at"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        roomID = try container.decode(RoomID.self, forKey: .roomID)
        sessionID = try container.decodeIfPresent(SessionID.self, forKey: .sessionID)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        nameRev = try container.decodeIfPresent(Int64.self, forKey: .nameRev)
        role = try container.decodeIfPresent(String.self, forKey: .role)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        // Legacy rooms publish only `cwd`; it holds the same canonical path,
        // so fall back to it rather than leaving the grouping blind. Matches
        // what the relay does when it builds a room from a legacy `hello`.
        workspacePath =
            try container.decodeIfPresent(String.self, forKey: .workspacePath) ?? cwd
        model = try container.decodeIfPresent(String.self, forKey: .model)
        thinking = try container.decodeIfPresent(String.self, forKey: .thinking)
        working = try container.decodeIfPresent(Bool.self, forKey: .working) ?? false
        startedAt = try container.decodeIfPresent(Int64.self, forKey: .startedAt) ?? 0
    }

    /// Encodes in the relay's own shape: `nil` optionals omitted entirely,
    /// `working` and `started_at` always present.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(roomID, forKey: .roomID)
        try container.encodeIfPresent(sessionID, forKey: .sessionID)
        try container.encodeIfPresent(workspacePath, forKey: .workspacePath)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(nameRev, forKey: .nameRev)
        try container.encodeIfPresent(role, forKey: .role)
        try container.encodeIfPresent(cwd, forKey: .cwd)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(thinking, forKey: .thinking)
        try container.encode(working, forKey: .working)
        try container.encode(startedAt, forKey: .startedAt)
    }
}

// MARK: - Role

/// Value of ``RoomMeta/role``.
public enum RoomRole: String, Hashable, Sendable, Codable {
    /// The machine gateway's `ctrl` room (plan 61, D4). Never a chat.
    case control
}

// MARK: - Patch

/// Three-state field used by merge patches: absent / explicit null / value.
///
/// JSON Merge Patch semantics, which is what `room_meta_update` implements:
/// a key **missing** from `meta` leaves the current value alone, an explicit
/// `null` clears it, and a value sets it. Swift's `String??` expresses the same
/// thing but reads terribly at the call site and collapses under
/// `encodeIfPresent`, so this exists instead.
public enum PatchField<Value: Hashable & Sendable>: Hashable, Sendable {
    /// Key absent from the patch — leave the current value untouched.
    case absent
    /// Key present with an explicit `null` — clear the field.
    case clear
    /// Key present with a value — set it.
    case set(Value)

    /// `true` when the patch carries this key at all (`clear` or `set`).
    public var isPresent: Bool {
        if case .absent = self { return false }
        return true
    }

    /// Applies the patch to a current value.
    public func applied(to current: Value?) -> Value? {
        switch self {
        case .absent: return current
        case .clear: return nil
        case .set(let value): return value
        }
    }
}

/// A partial update to a room's metadata: the `meta` object of a
/// `room_meta_update` (client → relay) and of a `room_meta_updated`
/// (relay → subscribers).
///
/// ## Patch semantics — the part that is easy to get wrong
///
/// - **Absent key = preserve.** Not "clear". A model-only update must not
///   erase the thinking level.
/// - **Explicit `null` = clear**, for the nullable string fields.
/// - **`working` has no null state.** It is a plain bool: absent means
///   preserve, `false` means idle. Modelled as `Bool?` where `nil` is absent.
/// - **`name_rev` alone is not a patch.** The relay's `is_empty()` ignores it,
///   so a revision with no name broadcasts nothing.
///
/// ## The `name_rev` gate
///
/// The relay applies a name patch only when the incoming revision is
/// **strictly greater** than the stored one; equal is rejected too. If either
/// side omits a revision, the patch is accepted on trust. Without this, a
/// second device of the same Owner reconnecting and replaying the last patch
/// it saw would drag the label back to an older value.
///
/// A **rejected patch still triggers a broadcast of the current name** — that
/// re-broadcast is how the device that sent the stale patch re-syncs. So an
/// inbound `room_meta_updated` carrying `name` is *not* evidence of a rename:
/// run the same gate locally before touching the label.
public struct RoomMetaPatch: Hashable, Sendable {
    public var model: PatchField<String>
    public var thinking: PatchField<String>
    /// `nil` = key absent (preserve). There is no "clear to null".
    public var working: Bool?
    public var name: PatchField<String>
    /// Revision accompanying ``name``. Carries no state on its own.
    public var nameRev: Int64?

    public init(
        model: PatchField<String> = .absent,
        thinking: PatchField<String> = .absent,
        working: Bool? = nil,
        name: PatchField<String> = .absent,
        nameRev: Int64? = nil
    ) {
        self.model = model
        self.thinking = thinking
        self.working = working
        self.name = name
        self.nameRev = nameRev
    }

    /// `true` when the patch would change nothing and should not be sent.
    ///
    /// Mirrors the relay's `RoomMetaPatch::is_empty`, including the rule that
    /// `name_rev` on its own does not count.
    public var isEmpty: Bool {
        !model.isPresent && !thinking.isPresent && working == nil && !name.isPresent
    }

    /// Whether the ``name`` half of this patch wins over a stored revision.
    ///
    /// Reproduces `relay/src/peers/registry.rs` exactly:
    /// - no name in the patch → never accepted;
    /// - both revisions present → accepted only when strictly greater;
    /// - either revision missing → accepted.
    public func nameAccepted(over storedRev: Int64?) -> Bool {
        guard name.isPresent else { return false }
        guard let incoming = nameRev, let stored = storedRev else { return true }
        return incoming > stored
    }

    /// Applies this patch to `meta` in place, honouring the revision gate.
    public func apply(to meta: inout RoomMeta) {
        meta.model = model.applied(to: meta.model)
        meta.thinking = thinking.applied(to: meta.thinking)
        if let working { meta.working = working }
        if nameAccepted(over: meta.nameRev) {
            meta.name = name.applied(to: meta.name)
            if let nameRev { meta.nameRev = nameRev }
        }
    }

    /// The `meta` JSON object this patch serializes to.
    ///
    /// Absent fields are omitted; ``PatchField/clear`` becomes `NSNull`, which
    /// `JSONSerialization` writes as `null`. Built as a dictionary rather than
    /// through `Codable` because the absent-vs-null distinction is exactly what
    /// `encodeIfPresent` cannot express.
    public var metaJSONObject: [String: Any] {
        var object: [String: Any] = [:]
        func put(_ key: String, _ field: PatchField<String>) {
            switch field {
            case .absent: break
            case .clear: object[key] = NSNull()
            case .set(let value): object[key] = value
            }
        }
        put("model", model)
        put("thinking", thinking)
        put("name", name)
        if let working { object["working"] = working }
        if let nameRev { object["name_rev"] = nameRev }
        return object
    }

    /// Parses the `meta` object of an inbound `room_meta_updated`.
    ///
    /// Presence of a key is read from the dictionary, so
    /// "absent" and "explicitly null" stay distinguishable — which is the whole
    /// reason this type exists.
    public init(metaJSONObject object: [String: Any]) {
        func read(_ key: String) -> PatchField<String> {
            guard let raw = object[key] else { return .absent }
            if raw is NSNull { return .clear }
            if let string = raw as? String { return .set(string) }
            return .absent
        }
        self.init(
            model: read("model"),
            thinking: read("thinking"),
            working: object["working"] as? Bool,
            name: read("name"),
            nameRev: (object["name_rev"] as? NSNumber)?.int64Value
        )
    }
}

// MARK: - Thinking

/// Reasoning effort levels the Pi accepts (`thinking_set.level`, and the
/// `thinking` string in ``RoomMeta``).
///
/// Not every model honours every level — `xhigh` in particular is only
/// meaningful for some families, and the SDK falls back to a neighbour rather
/// than failing. The relay treats the value as an opaque string, so an unknown
/// level from a newer Pi must not be dropped: keep the raw string and render
/// it, rather than forcing it to a known case.
public enum ThinkingLevel: String, Hashable, Sendable, Codable, CaseIterable {
    case off
    case minimal
    case low
    case medium
    case high
    case xhigh

    /// Parses the wire spelling, returning `nil` for a level this build does
    /// not know.
    public init?(wire: String) {
        self.init(rawValue: wire)
    }

    /// The wire spelling.
    public var wire: String { rawValue }
}
