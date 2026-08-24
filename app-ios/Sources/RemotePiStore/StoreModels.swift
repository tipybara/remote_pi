import Foundation
import RemotePiProtocol

// MARK: - Roles

/// Who produced a persisted row.
///
/// Mirrors Dart's `MsgRole` (`app/lib/data/local/records/message_record.dart:6`)
/// **plus** one local-only case. The four wire spellings must stay exactly
/// `user` / `assistant` / `tool` / `compaction`: they are what `role.name`
/// writes into the Hive rows an existing install holds, and what any transcript
/// export has to say.
public enum MessageRole: String, Hashable, Sendable, Codable, CaseIterable {
    case user
    case assistant
    case tool
    case compaction
    /// Local-only marker: "the Pi restarted here; everything above came from an
    /// earlier process". Trap T1 rule 3 — the alternative was deleting the
    /// history above the boundary, which is what the Flutter client does today.
    /// Never sent, never received, and has no Dart representation.
    case divider

    /// Read fallback matching Dart's
    /// `orElse: () => MsgRole.assistant` (`message_record.dart:85-88`).
    public init(wire: String?) {
        self = MessageRole(rawValue: wire ?? "") ?? .assistant
    }
}

/// Lifecycle of a tool call.
///
/// Spellings from `app/lib/domain/session_state.dart:168`; the read fallback is
/// `.completed`, matching `message_record.dart:180-183`.
public enum ToolStatus: String, Hashable, Sendable, Codable, CaseIterable {
    case pending
    case allowed
    case denied
    case expired
    case completed
    case failed

    public init(wire: String?) {
        self = ToolStatus(rawValue: wire ?? "") ?? .completed
    }
}

// MARK: - Identity

/// The real identity of a persisted row: **role and id together**.
///
/// Trap T5. `id` alone is not unique — `agent_message` is keyed by
/// `in_reply_to`, which *is* the user message's id, so a user row and an
/// assistant row routinely collide on `id`. Dart spells this
/// `'${role.name}:$id'` (`sync_service.dart:856`); here it is a type so it
/// cannot be passed where a bare id is expected.
public struct MessageIdentity: Hashable, Sendable {
    public let role: MessageRole
    public let msgID: String

    public init(role: MessageRole, msgID: String) {
        self.role = role
        self.msgID = msgID
    }
}

// MARK: - Tool payload

/// A `tool_request` + `tool_result` pair collapsed into one row.
public struct ToolPayload: Hashable, Sendable {
    public var toolCallID: String
    public var tool: String
    /// Raw JSON bytes, opaque. Spec §4.4: parsing these into typed Swift would
    /// invent a contract that does not exist and would fail on unknown tools.
    public var argsJSON: Data?
    public var status: ToolStatus
    public var resultJSON: Data?
    public var error: String?

    public init(
        toolCallID: String,
        tool: String,
        argsJSON: Data? = nil,
        status: ToolStatus = .pending,
        resultJSON: Data? = nil,
        error: String? = nil
    ) {
        self.toolCallID = toolCallID
        self.tool = tool
        self.argsJSON = argsJSON
        self.status = status
        self.resultJSON = resultJSON
        self.error = error
    }
}

// MARK: - Attachments

/// A reference to image bytes held **outside** the row (Trap T8).
public struct AttachmentRef: Hashable, Sendable {
    /// `image/jpeg`, `image/png`, … — the wire `mime`.
    public var mime: String
    /// Hex SHA-256 of the stored file. Content addressing means a history
    /// replay that echoes the same image back costs zero extra bytes.
    public var sha256Hex: String
    public var byteLength: Int
    /// `false` when the wire string was not decodable base64 and the file holds
    /// it verbatim. See `attachment.canonical` in ``Schema``.
    public var canonical: Bool

    public init(mime: String, sha256Hex: String, byteLength: Int, canonical: Bool = true) {
        self.mime = mime
        self.sha256Hex = sha256Hex
        self.byteLength = byteLength
        self.canonical = canonical
    }

    /// Filename inside the blob directory. Content-addressed, so two sessions
    /// sharing an image share the file.
    public var fileName: String { "\(sha256Hex).bin" }
}

// MARK: - Message row

/// One persisted transcript row.
public struct MessageRow: Hashable, Sendable, Identifiable {
    /// Append position within the session. **Not identity** (Trap T6): nothing
    /// outside the message table may reference it — no bookmarks, no scroll
    /// anchors, no notification payloads.
    public var seq: Int64
    public var role: MessageRole
    public var msgID: String
    public var text: String
    /// Epoch **milliseconds**. Never a `Date` in the codec (spec §4.4).
    public var ts: Int64
    /// Optimistic: written locally, not yet echoed by the Pi.
    public var pending: Bool
    /// Local-only hint: sent while the Pi was busy.
    public var steering: Bool
    /// Compaction rows only.
    public var tokensBefore: Int64?
    /// Assistant rows: the user message this answers.
    public var inReplyTo: String?
    public var tool: ToolPayload?
    public var attachments: [AttachmentRef]

    public var id: MessageIdentity { MessageIdentity(role: role, msgID: msgID) }

    public init(
        seq: Int64 = -1,
        role: MessageRole,
        msgID: String,
        text: String = "",
        ts: Int64,
        pending: Bool = false,
        steering: Bool = false,
        tokensBefore: Int64? = nil,
        inReplyTo: String? = nil,
        tool: ToolPayload? = nil,
        attachments: [AttachmentRef] = []
    ) {
        self.seq = seq
        self.role = role
        self.msgID = msgID
        self.text = text
        self.ts = ts
        self.pending = pending
        self.steering = steering
        self.tokensBefore = tokensBefore
        self.inReplyTo = inReplyTo
        self.tool = tool
        self.attachments = attachments
    }
}

// MARK: - Session summary

/// What Home needs about one session without opening its transcript.
///
/// Replaces the Hive `sessions_index` box, which was write-only in production
/// (spec §1.5) — the useful half (preview + timestamp, so Home renders offline)
/// survives, `display_name`'s dead twin does not.
public struct SessionSummary: Hashable, Sendable, Identifiable {
    public var key: SessionKey
    public var sessionID: SessionID?
    public var workspaceID: WorkspaceID?
    public var workspacePath: String?
    public var cwd: String?
    public var displayName: String?
    /// Monotonic revision of ``displayName``. A rename applies only when the
    /// incoming revision is **strictly greater** (`PROTOCOL.md:215-219`).
    public var nameRev: Int64?
    public var role: String?
    public var mode: String?
    public var model: String?
    public var thinking: String?
    public var sessionStartedAt: Int64?
    public var lastMessageAt: Int64?
    public var lastMessagePreview: String?
    /// `true` when this row has no live pairing behind it any more (Trap T11):
    /// the conversation is kept, but Settings can show its size and offer to
    /// delete it.
    public var orphaned: Bool

    public var id: String { key.storageKey }

    /// Never a chat tile, never a message store (Trap T10).
    public var isControlRoom: Bool {
        role == RoomRole.control.rawValue || key.room.isControl
    }

    public init(
        key: SessionKey,
        sessionID: SessionID? = nil,
        workspaceID: WorkspaceID? = nil,
        workspacePath: String? = nil,
        cwd: String? = nil,
        displayName: String? = nil,
        nameRev: Int64? = nil,
        role: String? = nil,
        mode: String? = nil,
        model: String? = nil,
        thinking: String? = nil,
        sessionStartedAt: Int64? = nil,
        lastMessageAt: Int64? = nil,
        lastMessagePreview: String? = nil,
        orphaned: Bool = false
    ) {
        self.key = key
        self.sessionID = sessionID
        self.workspaceID = workspaceID
        self.workspacePath = workspacePath
        self.cwd = cwd
        self.displayName = displayName
        self.nameRev = nameRev
        self.role = role
        self.mode = mode
        self.model = model
        self.thinking = thinking
        self.sessionStartedAt = sessionStartedAt
        self.lastMessageAt = lastMessageAt
        self.lastMessagePreview = lastMessagePreview
        self.orphaned = orphaned
    }

    /// Rebuilds the cached ``RoomMeta`` for an offline Home.
    ///
    /// `working` and `startedAt` come back at their defaults **on purpose**:
    /// neither is persisted (spec §4.3). `started_at` changes on every
    /// reconnect (`PROTOCOL.md:221`) and a persisted `working: true` would show
    /// a phantom spinner for a turn that finished while the app was dead — the
    /// exact reason Hive wiped its `runtime` box at boot.
    public var cachedRoomMeta: RoomMeta {
        RoomMeta(
            roomID: key.room,
            sessionID: sessionID,
            workspacePath: workspacePath,
            name: displayName,
            nameRev: nameRev,
            role: role,
            cwd: cwd,
            model: model,
            thinking: thinking,
            working: false,
            startedAt: 0
        )
    }
}

// MARK: - Volatile runtime

/// Connection + presence for one session.
///
/// **Never persisted.** The Hive `runtime` box existed only so the chat screen
/// could observe connection state through the same reactive path as messages,
/// and it was `clear()`ed at every boot (`boxes.dart:75`) precisely because a
/// stale `online` row is observed for one frame otherwise. Here it lives in the
/// actor's memory, which gives the wipe for free — a relaunch starts at
/// `.connecting` / `.unknown` because there is nothing to read.
///
/// The JSON helpers exist only so the spellings stay pinned to the Dart record
/// (`runtime_record.dart:5-40`); nothing writes them to disk.
public struct RuntimeState: Hashable, Sendable {
    public enum Connection: String, Hashable, Sendable, CaseIterable {
        case connecting, online, offline, retrying
    }

    public enum Presence: String, Hashable, Sendable, CaseIterable {
        case alive, stale, unknown
    }

    public var connection: Connection
    public var presence: Presence

    public init(connection: Connection = .connecting, presence: Presence = .unknown) {
        self.connection = connection
        self.presence = presence
    }

    /// Both keys are always present, matching `RuntimeRecord.toJson`.
    public var jsonObject: [String: Any] {
        ["connection": connection.rawValue, "presence": presence.rawValue]
    }

    /// Read fallbacks are `connecting` / `unknown` (`runtime_record.dart:32-39`).
    public init(jsonObject object: [String: Any]) {
        self.init(
            connection: Connection(rawValue: object["connection"] as? String ?? "") ?? .connecting,
            presence: Presence(rawValue: object["presence"] as? String ?? "") ?? .unknown
        )
    }
}

// MARK: - Errors

extension StoreError {
    /// A transcript was requested for the machine control room.
    ///
    /// Trap T10: `ctrl` is a perfectly valid `(epk, room)` pair and would
    /// happily key a message table. It carries `action_ok` / `action_error` RPC
    /// only. The Flutter client has no such guard — the invariant is structural
    /// there (only the chat screen calls `activate`), which is one refactor away
    /// from being violated.
    public static func controlRoom(_ key: SessionKey) -> StoreError {
        .rejected("\(key.description) is the machine control room; it has no transcript")
    }
}
