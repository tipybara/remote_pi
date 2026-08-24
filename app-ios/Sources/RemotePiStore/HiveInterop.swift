import Foundation
import RemotePiProtocol

// The JSON shapes the Flutter client writes into Hive
// (`app/lib/data/local/records/*.dart`).
//
// Spec 07 §4.6 says do **not** migrate the Hive files — the native client
// re-syncs from the Pi. So why are these here?
//
// 1. They are the *definition* of a persisted row: field names, casing, which
//    keys are omitted vs written as explicit `null`, and the read fallbacks.
//    Pinning them in a codec with tests keeps the native row model honest
//    against the shipped one, which is what a transcript export or a support
//    dump has to speak.
// 2. Trap T4 lives here: the parent record **omits** absent fields while the
//    nested `tool` object writes explicit `null`s. Any codec that "cleans up"
//    that inconsistency stops round-tripping.
//
// Nothing in this file touches the database. It is a pure value codec.

// MARK: - Tool event

/// `ToolEventData.toJson` (`message_record.dart:167-174`).
///
/// **Every one of the six keys is always emitted, including nulls.** That is
/// the opposite of the parent record's rule and it is not an accident worth
/// "fixing": `ToolEventData.fromJson` reads `j['args']` and `j['result']`
/// untyped, so an absent key and a null key are indistinguishable there, and
/// the writer picked "always present".
public struct HiveToolEvent: Hashable, Sendable {
    public var toolCallID: String
    public var tool: String
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

    public init(payload: ToolPayload) {
        self.init(
            toolCallID: payload.toolCallID,
            tool: payload.tool,
            argsJSON: payload.argsJSON,
            status: payload.status,
            resultJSON: payload.resultJSON,
            error: payload.error
        )
    }

    public var payload: ToolPayload {
        ToolPayload(
            toolCallID: toolCallID,
            tool: tool,
            argsJSON: argsJSON,
            status: status,
            resultJSON: resultJSON,
            error: error
        )
    }

    public var jsonObject: [String: Any] {
        [
            "tool_call_id": toolCallID,
            "tool": tool,
            "args": JSONFragment.value(from: argsJSON) ?? NSNull(),
            "status": status.rawValue,
            "result": JSONFragment.value(from: resultJSON) ?? NSNull(),
            "error": error ?? NSNull(),
        ]
    }

    public init?(jsonObject object: [String: Any]) {
        guard let toolCallID = object["tool_call_id"] as? String else { return nil }
        self.init(
            toolCallID: toolCallID,
            // `(j['tool'] as String?) ?? 'unknown'` — message_record.dart:169.
            tool: object["tool"] as? String ?? "unknown",
            argsJSON: JSONFragment.data(from: object["args"]),
            status: ToolStatus(wire: object["status"] as? String),
            resultJSON: JSONFragment.data(from: object["result"]),
            error: object["error"] as? String
        )
    }
}

// MARK: - Message record

/// `MessageRecord.toJson` (`message_record.dart:66-78`).
///
/// | key | written when |
/// |---|---|
/// | `id`, `seq`, `role`, `text`, `ts`, `pending` | always |
/// | `image` | only when non-nil |
/// | `tool` | only when non-nil |
/// | `steering` | only when **true** |
/// | `tokens_before` | only when non-nil |
///
/// `pending` is in the always-list even when `false`; `steering` is not. A
/// codec that emits `"steering": false` produces JSON the Dart side reads
/// identically but that no Dart writer ever produced — which is enough to fail
/// a byte-comparison against a real file.
public struct HiveMessageRecord: Hashable, Sendable {
    public var id: String
    public var seq: Int64
    public var role: MessageRole
    public var text: String
    public var image: WireImage?
    public var tool: HiveToolEvent?
    /// Epoch **milliseconds** (`ts: ts.millisecondsSinceEpoch`).
    public var ts: Int64
    public var pending: Bool
    public var steering: Bool
    public var tokensBefore: Int64?

    public init(
        id: String,
        seq: Int64,
        role: MessageRole,
        text: String = "",
        image: WireImage? = nil,
        tool: HiveToolEvent? = nil,
        ts: Int64,
        pending: Bool = false,
        steering: Bool = false,
        tokensBefore: Int64? = nil
    ) {
        self.id = id
        self.seq = seq
        self.role = role
        self.text = text
        self.image = image
        self.tool = tool
        self.ts = ts
        self.pending = pending
        self.steering = steering
        self.tokensBefore = tokensBefore
    }

    /// Builds the Dart-shaped record for a native row.
    ///
    /// The image has to be passed in: a ``MessageRow`` holds an
    /// ``AttachmentRef``, not bytes (Trap T8), so only the store can produce
    /// the base64 the Dart record inlines.
    ///
    /// Returns `nil` for ``MessageRole/divider``, which is local-only and has
    /// no Dart counterpart — encoding it as some other role would put a row on
    /// an export that no Pi ever sent.
    public init?(row: MessageRow, image: WireImage? = nil) {
        guard row.role != .divider else { return nil }
        self.init(
            id: row.msgID,
            seq: row.seq,
            role: row.role,
            text: row.text,
            image: image,
            tool: row.tool.map(HiveToolEvent.init(payload:)),
            ts: row.ts,
            pending: row.pending,
            steering: row.steering,
            tokensBefore: row.tokensBefore
        )
    }

    /// The native row. `inReplyTo` and attachments are **not** recoverable from
    /// a Hive record: Dart stores an assistant row's `in_reply_to` *as* the id
    /// (Trap T5) and inlines the image bytes.
    public var row: MessageRow {
        MessageRow(
            seq: seq,
            role: role,
            msgID: id,
            text: text,
            ts: ts,
            pending: pending,
            steering: steering,
            tokensBefore: tokensBefore,
            inReplyTo: nil,
            tool: tool?.payload,
            attachments: []
        )
    }

    public var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "id": id,
            "seq": seq,
            "role": role.rawValue,
            "text": text,
            "ts": ts,
            "pending": pending,
        ]
        if let image { object["image"] = ["data": image.data, "mime": image.mime] }
        if let tool { object["tool"] = tool.jsonObject }
        if steering { object["steering"] = true }
        if let tokensBefore { object["tokens_before"] = tokensBefore }
        return object
    }

    /// `MessageRecord.fromJson` (`message_record.dart:80-103`), fallbacks and all.
    ///
    /// Returns `nil` only where Dart *throws*: a missing `id`, `seq` or `ts`.
    /// Everything else has a documented default, and inventing one for the
    /// three required fields would put a row with an empty id into the dedupe
    /// index, where it would swallow the next row that also has no id.
    public init?(jsonObject object: [String: Any]) {
        guard
            let id = object["id"] as? String,
            let seq = (object["seq"] as? NSNumber)?.int64Value,
            let ts = (object["ts"] as? NSNumber)?.int64Value
        else { return nil }

        var image: WireImage?
        if let raw = object["image"] as? [String: Any],
            let data = raw["data"] as? String,
            let mime = raw["mime"] as? String
        {
            image = WireImage(data: data, mime: mime)
        }

        var tool: HiveToolEvent?
        if let raw = object["tool"] as? [String: Any] {
            tool = HiveToolEvent(jsonObject: raw)
        }

        self.init(
            id: id,
            seq: seq,
            role: MessageRole(wire: object["role"] as? String),
            text: object["text"] as? String ?? "",
            image: image,
            tool: tool,
            ts: ts,
            pending: object["pending"] as? Bool ?? false,
            steering: object["steering"] as? Bool ?? false,
            tokensBefore: (object["tokens_before"] as? NSNumber)?.int64Value
        )
    }
}

// MARK: - Session index record

/// `SessionIndexRecord.toJson` (`session_index_record.dart:44-52`).
///
/// All seven keys, **with explicit `null`s** — the opposite of the message
/// record's omit-when-absent rule.
///
/// The native store does not keep a `status` column: the relay's
/// `room_meta.working` is the single source of truth for working-state
/// (`home_viewmodel.dart:75`), and the Hive box that held this was write-only
/// in production anyway (spec §1.5). The field survives here so the shape stays
/// pinned; ``SessionSummary`` is what the app actually reads.
public struct HiveSessionIndexRecord: Hashable, Sendable {
    public enum Activity: String, Hashable, Sendable { case idle, working }

    /// Dart writes the epk string it was handed. We always write
    /// ``PeerID/urlSafeValue`` — Trap T3: `SessionIndexRecord.key` builds
    /// `'$epk:$roomId'` from the record's *raw* field while the row is stored
    /// under the *normalized* key, so a standard-base64 epk in this field makes
    /// the record disagree with its own box key. Storing bytes and encoding
    /// once removes the divergence.
    public var peer: PeerID
    public var room: RoomID
    public var displayName: String?
    public var status: Activity
    public var lastMessageAt: Int64?
    public var lastMessagePreview: String?
    public var sessionStartedAt: Int64?

    public init(
        peer: PeerID,
        room: RoomID,
        displayName: String? = nil,
        status: Activity = .idle,
        lastMessageAt: Int64? = nil,
        lastMessagePreview: String? = nil,
        sessionStartedAt: Int64? = nil
    ) {
        self.peer = peer
        self.room = room
        self.displayName = displayName
        self.status = status
        self.lastMessageAt = lastMessageAt
        self.lastMessagePreview = lastMessagePreview
        self.sessionStartedAt = sessionStartedAt
    }

    public init(summary: SessionSummary, status: Activity = .idle) {
        self.init(
            peer: summary.key.peer,
            room: summary.key.room,
            displayName: summary.displayName,
            status: status,
            lastMessageAt: summary.lastMessageAt,
            lastMessagePreview: summary.lastMessagePreview,
            sessionStartedAt: summary.sessionStartedAt
        )
    }

    /// The Hive box key for this row: `<toAppEpk(epk)>:<roomId>`
    /// (`boxes.dart:110-111`). url-safe, unpadded, `:` separator.
    ///
    /// Note this is **not** ``SessionKey/storageKey``, which uses `__` because
    /// it also names files. The `|` + standard-base64 spelling that
    /// `home_state.dart:88` uses is an in-memory widget key and must never
    /// reach disk (Trap T3).
    public var hiveKey: String { "\(peer.urlSafeValue):\(room.rawValue)" }

    public var jsonObject: [String: Any] {
        [
            "epk": peer.urlSafeValue,
            "room_id": room.rawValue,
            "display_name": displayName ?? NSNull(),
            "status": status.rawValue,
            "last_message_at": lastMessageAt ?? NSNull(),
            "last_message_preview": lastMessagePreview ?? NSNull(),
            "session_started_at": sessionStartedAt ?? NSNull(),
        ]
    }

    public init?(jsonObject object: [String: Any]) {
        guard
            let epk = object["epk"] as? String,
            // Accepts either alphabet: a legacy row may hold the standard
            // spelling, which is exactly the two-rows-per-session bug plan 61
            // Fase 0 fixed. Decoding to bytes collapses both spellings to one.
            let peer = PeerID(base64: epk),
            let room = object["room_id"] as? String
        else { return nil }
        self.init(
            peer: peer,
            room: RoomID(room),
            displayName: object["display_name"] as? String,
            status: Activity(rawValue: object["status"] as? String ?? "") ?? .idle,
            lastMessageAt: (object["last_message_at"] as? NSNumber)?.int64Value,
            lastMessagePreview: object["last_message_preview"] as? String,
            sessionStartedAt: (object["session_started_at"] as? NSNumber)?.int64Value
        )
    }
}

// MARK: - Raw JSON sub-trees

/// Moves opaque JSON sub-trees (`tool.args`, `tool.result`) between raw bytes
/// and Foundation values without ever giving them a Swift type.
enum JSONFragment {
    /// Serializes a Foundation value back to bytes. `NSNull` and `nil` both
    /// become `nil` — a stored `null` is indistinguishable from an absent
    /// value on the Dart side and must not become the 4 bytes `null`.
    static func data(from value: Any?) -> Data? {
        guard let value, !(value is NSNull) else { return nil }
        // `.fragmentsAllowed`: `args` is usually an object, but `result` is
        // frequently a bare string or number (`_stringifyToolResult` in the Pi
        // returns text), and JSONSerialization refuses a top-level scalar
        // without this flag.
        return try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
    }

    static func value(from data: Data?) -> Any? {
        guard let data, !data.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
}
