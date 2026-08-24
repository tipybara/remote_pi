import Foundation

// MARK: - Payloads

/// `pair_ok` — pairing succeeded.
///
/// ## The Flutter client drops four of these fields; do not copy that
///
/// `PairOk.fromJson` (`protocol.dart:1297-1317`) parses only `in_reply_to`,
/// `session_name`, `session_started_at`, `room_id`, `harness` and `hostname`.
/// The Pi *emits* `session_id`, `workspace_path`, `display_name` and
/// `name_rev` (`index.ts:2033-2036`) and `PeerRecord` even has fields for
/// them — they are simply never read. The wire wins: parsing them here is what
/// lets a new pairing be keyed by session from the very first frame, which is
/// the stated intent of plan 61.
public struct PairOk: Hashable, Sendable, Codable {
    public var inReplyTo: String
    /// Historical label (`"remote_pi · feature/x"`). **Not identity.**
    public var sessionName: String
    /// Epoch milliseconds. `0` means "unknown" — a legacy Pi omits it, and the
    /// restart-detection branch must be skipped rather than treating `0` as a
    /// real timestamp.
    public var sessionStartedAt: Int64
    /// The room this pairing confirmed on.
    public var roomID: RoomID
    /// **Present only from a plan-61 Pi.** Its presence, not its value, is the
    /// signal that this room id is stable across renames.
    public var sessionID: SessionID?
    /// Canonical `realpath(cwd)`.
    public var workspacePath: String?
    /// The session's editable label, mirroring `room_meta.name`.
    public var displayName: String?
    /// Revision of ``displayName``, for the strictly-greater gate.
    public var nameRev: Int64?
    public var harness: PiHarness?
    /// `os.hostname()` of the Mac — how two paired machines that share a
    /// nickname stay distinguishable.
    public var hostname: String?
    /// `true` when the frame carried no `room_id` at all.
    ///
    /// ``roomID`` falls back to ``RoomID/main`` in that case, which makes the
    /// two situations indistinguishable from the parsed value alone — and they
    /// are not the same: only an **omitted** `room_id` should fall back to the
    /// QR code's room hint. A Pi that explicitly said `"main"` means `"main"`.
    public var roomIDWasOmitted: Bool

    public init(
        inReplyTo: String,
        sessionName: String,
        sessionStartedAt: Int64,
        roomID: RoomID,
        sessionID: SessionID? = nil,
        workspacePath: String? = nil,
        displayName: String? = nil,
        nameRev: Int64? = nil,
        harness: PiHarness? = nil,
        hostname: String? = nil,
        roomIDWasOmitted: Bool = false
    ) {
        self.inReplyTo = inReplyTo
        self.sessionName = sessionName
        self.sessionStartedAt = sessionStartedAt
        self.roomID = roomID
        self.sessionID = sessionID
        self.workspacePath = workspacePath
        self.displayName = displayName
        self.nameRev = nameRev
        self.harness = harness
        self.hostname = hostname
        self.roomIDWasOmitted = roomIDWasOmitted
    }

    public enum CodingKeys: String, CodingKey {
        case harness, hostname
        case inReplyTo = "in_reply_to"
        case sessionName = "session_name"
        case sessionStartedAt = "session_started_at"
        case roomID = "room_id"
        case sessionID = "session_id"
        case workspacePath = "workspace_path"
        case displayName = "display_name"
        case nameRev = "name_rev"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inReplyTo = try container.decode(String.self, forKey: .inReplyTo)
        sessionName = try container.decode(String.self, forKey: .sessionName)
        // A non-numeric or absent value means "unknown", not zero-the-instant.
        sessionStartedAt =
            try container.decodeIfPresent(Int64.self, forKey: .sessionStartedAt) ?? 0
        let announcedRoom = try container.decodeIfPresent(RoomID.self, forKey: .roomID)
        roomID = announcedRoom ?? .main
        roomIDWasOmitted = announcedRoom == nil
        sessionID = try container.decodeIfPresent(SessionID.self, forKey: .sessionID)
        workspacePath = try container.decodeIfPresent(String.self, forKey: .workspacePath)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        nameRev = try container.decodeIfPresent(Int64.self, forKey: .nameRev)
        harness = try container.decodeIfPresent(PiHarness.self, forKey: .harness)
        let rawHostname = try container.decodeIfPresent(String.self, forKey: .hostname)
        // An empty hostname is worse than none: it renders as a blank device
        // subtitle instead of falling back to the nickname.
        hostname = (rawHostname?.isEmpty ?? true) ? nil : rawHostname
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(inReplyTo, forKey: .inReplyTo)
        try container.encode(sessionName, forKey: .sessionName)
        try container.encode(sessionStartedAt, forKey: .sessionStartedAt)
        if !roomIDWasOmitted { try container.encode(roomID, forKey: .roomID) }
        try container.encodeIfPresent(sessionID, forKey: .sessionID)
        try container.encodeIfPresent(workspacePath, forKey: .workspacePath)
        try container.encodeIfPresent(displayName, forKey: .displayName)
        try container.encodeIfPresent(nameRev, forKey: .nameRev)
        try container.encodeIfPresent(harness, forKey: .harness)
        try container.encodeIfPresent(hostname, forKey: .hostname)
    }

    /// `true` when this pairing can be keyed by session id from the start.
    public var hasStableIdentity: Bool { sessionID != nil }
}

/// `pair_error` — pairing refused. All three fields are required.
public struct PairError: Hashable, Sendable, Codable {
    public var inReplyTo: String
    public var code: PairErrorCode
    public var message: String

    public init(inReplyTo: String, code: PairErrorCode, message: String) {
        self.inReplyTo = inReplyTo
        self.code = code
        self.message = message
    }

    public enum CodingKeys: String, CodingKey {
        case code, message
        case inReplyTo = "in_reply_to"
    }
}

/// A user turn arriving from the Pi.
///
/// **Two wire types, one payload.** `type: "user_message"` is the Pi echoing a
/// message an app sent, broadcast to *every* attached owner including the
/// sender; `type: "user_input"` mirrors text typed in the desktop TUI. The
/// Flutter client collapses both into one class, and so does this — but
/// ``isEcho`` keeps the distinction, because it decides whether a local
/// optimistic bubble should be reconciled or a new row appended.
///
/// The echo is the source of truth: a locally-composed bubble stays `pending`
/// until its echo arrives, with a ~20 s reaper for the case where it never
/// does.
public struct UserInput: Hashable, Sendable, Codable {
    /// Preserved verbatim from the sender — the dedup key.
    public var id: String
    public var text: String
    public var streamingBehavior: StreamingBehavior?
    public var images: [WireImage]
    /// `true` when the frame said `user_message` (an echo), `false` for
    /// `user_input` (a TUI mirror). `user_input` is declared without `images`.
    public var isEcho: Bool

    public init(
        id: String,
        text: String,
        streamingBehavior: StreamingBehavior? = nil,
        images: [WireImage] = [],
        isEcho: Bool = true
    ) {
        self.id = id
        self.text = text
        self.streamingBehavior = streamingBehavior
        self.images = images
        self.isEcho = isEcho
    }

    /// The product sends at most one image and every consumer reads only the
    /// first.
    public var firstImage: WireImage? { images.first }

    public enum CodingKeys: String, CodingKey {
        case id, text, images
        case streamingBehavior = "streaming_behavior"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        streamingBehavior = try container.decodeIfPresent(
            StreamingBehavior.self, forKey: .streamingBehavior)
        images = try container.decodeIfPresent([WireImage].self, forKey: .images) ?? []
        // The discriminant lives on the frame, not in this container.
        // `ServerMessage` re-stamps it after decoding; `true` is the common
        // case and the safe default for a standalone decode.
        isEcho = true
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(text, forKey: .text)
        try container.encodeIfPresent(streamingBehavior, forKey: .streamingBehavior)
        if !images.isEmpty { try container.encode(images, forKey: .images) }
    }
}

/// `queued_message_state` — a **full replacement** of the queue, broadcast to
/// every attached owner.
public struct QueuedMessageState: Hashable, Sendable, Codable {
    public var items: [QueuedMessageItem]

    public init(items: [QueuedMessageItem] = []) {
        self.items = items
    }

    public enum CodingKeys: String, CodingKey {
        case items, id, text
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Prefer `items` whenever it is an array — **including an empty one**.
        // An empty `items` is the "queue is now empty" signal; falling through
        // to the legacy `{id, text}` mirror there would leave a drained item
        // on screen forever.
        if let items = try container.decodeIfPresent([QueuedMessageItem].self, forKey: .items) {
            // Items whose text is empty are dropped: the Pi's legacy mirror can
            // carry one, and rendering it produces a blank queue row.
            self.items = items.filter { !$0.text.isEmpty }
            return
        }
        // Legacy top-level mirror of `items[0]`, omitted entirely when the
        // queue is empty (`index.ts:912`).
        let id = try container.decodeIfPresent(String.self, forKey: .id)
        let text = try container.decodeIfPresent(String.self, forKey: .text)
        guard let id, let text, !text.isEmpty else {
            self.items = []
            return
        }
        self.items = [QueuedMessageItem(id: id, text: text, editable: true, createdAt: 0)]
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(items, forKey: .items)
        // The legacy mirror is emitted only when the queue is non-empty, which
        // is what the Pi does.
        if let first = items.first {
            try container.encode(first.id, forKey: .id)
            try container.encode(first.text, forKey: .text)
        }
    }
}

/// `agent_chunk` — one streamed delta.
///
/// `in_reply_to` is the Pi's current turn id, normally the id of the
/// `user_message` that started the turn. For a turn started in the desktop TUI
/// it can be a `sync_<ts>` id — or absent, in which case the Pi drops the
/// chunks entirely rather than sending them unattributed (`index.ts:2211`).
public struct AgentChunk: Hashable, Sendable, Codable {
    public var inReplyTo: String
    public var delta: String

    public init(inReplyTo: String, delta: String) {
        self.inReplyTo = inReplyTo
        self.delta = delta
    }

    public enum CodingKeys: String, CodingKey {
        case delta
        case inReplyTo = "in_reply_to"
    }
}

/// `agent_done` — the turn finished.
///
/// ``usage`` is declared optional and **the live path never sends it**
/// (`index.ts:2282`). Token accounting only ever appears on `agent_message`
/// events inside a `session_history`.
public struct AgentDone: Hashable, Sendable, Codable {
    public var inReplyTo: String
    public var usage: Usage?

    public init(inReplyTo: String, usage: Usage? = nil) {
        self.inReplyTo = inReplyTo
        self.usage = usage
    }

    public enum CodingKeys: String, CodingKey {
        case usage
        case inReplyTo = "in_reply_to"
    }
}

/// `agent_message` — a consolidated assistant reply.
///
/// Primarily a `session_history` event type; when it arrives standalone treat
/// it as the final assistant message for that `in_reply_to`.
public struct AgentMessage: Hashable, Sendable, Codable {
    public var inReplyTo: String
    public var text: String
    public var usage: Usage?

    public init(inReplyTo: String, text: String, usage: Usage? = nil) {
        self.inReplyTo = inReplyTo
        self.text = text
        self.usage = usage
    }

    public enum CodingKeys: String, CodingKey {
        case text, usage
        case inReplyTo = "in_reply_to"
    }
}

/// `compaction` — the context was compacted.
///
/// TypeScript declares `summary` and `tokens_before` required; the Flutter
/// parser tolerates both missing, and the history variant genuinely omits the
/// standalone `ts`. The lenient reading wins: a decoder that throws here loses
/// a system bubble over a field nobody renders.
///
/// The `working: true/false` bracketing around a compaction arrives as
/// `room_meta_update` **control** patches, not as inner frames.
public struct Compaction: Hashable, Sendable, Codable {
    public var summary: String
    public var tokensBefore: Int?
    /// Epoch milliseconds. Present on the live frame, absent on the
    /// history event (which carries the standard event `ts` instead).
    public var ts: Int64?

    public init(summary: String, tokensBefore: Int? = nil, ts: Int64? = nil) {
        self.summary = summary
        self.tokensBefore = tokensBefore
        self.ts = ts
    }

    public enum CodingKeys: String, CodingKey {
        case summary, ts
        case tokensBefore = "tokens_before"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        tokensBefore = try container.decodeIfPresent(Int.self, forKey: .tokensBefore)
        ts = try container.decodeIfPresent(Int64.self, forKey: .ts)
    }
}

/// `tool_request` — the agent is about to run a tool.
///
/// No `in_reply_to`: correlation is by ``toolCallID``.
public struct ToolRequest: Hashable, Sendable, Codable {
    public var toolCallID: String
    public var tool: String
    /// Free-form. `Record<string, unknown>` on the wire.
    public var args: AnyJSON?

    public init(toolCallID: String, tool: String, args: AnyJSON? = nil) {
        self.toolCallID = toolCallID
        self.tool = tool
        self.args = args
    }

    public enum CodingKeys: String, CodingKey {
        case tool, args
        case toolCallID = "tool_call_id"
    }

    /// The synthetic diff the Pi injects for `edit` tools.
    ///
    /// Undocumented in every `.d.ts` and genuinely load-bearing: the Pi reads
    /// the target file, rebuilds the hunks around each edit and hangs them on
    /// `args.hunks` (`index.ts:4395-4431`), which is what a diff card renders
    /// from. `nil` means the Pi could not read the file — show the raw args.
    public var editHunks: [DiffHunk]? {
        guard let raw = args?["hunks"], case .array = raw,
            let data = try? JSONSerialization.data(withJSONObject: raw.jsonObject),
            let hunks = try? WireJSON.makeDecoder().decode([DiffHunk].self, from: data)
        else { return nil }
        return hunks
    }
}

/// `tool_result` — the tool finished.
///
/// ``result`` and ``error`` are **mutually exclusive**: exactly one is present
/// (`index.ts:2239-2241`), and the presence of `error` is what marks a failure.
public struct ToolResult: Hashable, Sendable, Codable {
    public var toolCallID: String
    /// Typed `unknown` in TS and `dynamic` in Dart, but the live producer and
    /// the history mapper both run it through `_stringifyToolResult`
    /// (`index.ts:2238`, `index.ts:4662`) so that live output matches re-sync
    /// output byte for byte. Kept as ``AnyJSON`` because the archived contract
    /// fixtures do carry objects — do not JSON-parse ``resultText``
    /// speculatively.
    public var result: AnyJSON?
    public var error: String?

    public init(toolCallID: String, result: AnyJSON? = nil, error: String? = nil) {
        self.toolCallID = toolCallID
        self.result = result
        self.error = error
    }

    /// The result when it is the string the current Pi always produces.
    public var resultText: String? { result?.stringValue }

    public var isFailure: Bool { error != nil }

    public enum CodingKeys: String, CodingKey {
        case result, error
        case toolCallID = "tool_call_id"
    }
}

/// `error` — something failed.
public struct ErrorFrame: Hashable, Sendable, Codable {
    /// **Optional.** Absent when the failure is not tied to a request
    /// (`index.ts:2271-2273`).
    public var inReplyTo: String?
    public var code: ErrorCode
    public var message: String

    public init(inReplyTo: String? = nil, code: ErrorCode, message: String) {
        self.inReplyTo = inReplyTo
        self.code = code
        self.message = message
    }

    public enum CodingKeys: String, CodingKey {
        case code, message
        case inReplyTo = "in_reply_to"
    }
}

/// `cancelled` — the success ack for a `cancel`. Carries no `error`.
public struct Cancelled: Hashable, Sendable, Codable {
    public var inReplyTo: String
    public var targetID: String

    public init(inReplyTo: String, targetID: String) {
        self.inReplyTo = inReplyTo
        self.targetID = targetID
    }

    public enum CodingKeys: String, CodingKey {
        case inReplyTo = "in_reply_to"
        case targetID = "target_id"
    }
}

/// `action_ok` — a typed action succeeded.
///
/// Chat actions carry nothing beyond the ack. Only the machine-control replies
/// add fields, so the whole frame is kept in ``raw``: a new control action can
/// grow a payload without a new type here.
///
/// **`action_ok` for `create_session` / `session_start` means "spawn
/// requested", not "the room is live."** Wait for the
/// ``ControlFrame/roomAnnounced(peer:meta:)`` carrying that session id before
/// opening a chat, and never derive a room id locally.
public struct ActionOk: Hashable, Sendable, Codable {
    public var inReplyTo: String
    public var action: ActionName
    /// The entire frame, so control-plane payloads survive without a bespoke
    /// type per action. Parse the typed view with ``ControlReply/parse(_:)``.
    public var raw: AnyJSON

    public init(inReplyTo: String, action: ActionName, raw: AnyJSON = .object([:])) {
        self.inReplyTo = inReplyTo
        self.action = action
        self.raw = raw
    }

    /// `true` when the machine replayed a previously-recorded outcome for this
    /// idempotency key.
    ///
    /// A replayed success carries **only** `{session_id, replayed: true}`
    /// (`gateway.ts:311-314`) — `path` and `display_name` do not survive a
    /// retry. Design the caller to need only the session id.
    public var isReplay: Bool { raw["replayed"]?.boolValue == true }

    public enum CodingKeys: String, CodingKey {
        case action
        case inReplyTo = "in_reply_to"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inReplyTo = try container.decode(String.self, forKey: .inReplyTo)
        action = try container.decodeIfPresent(ActionName.self, forKey: .action)
            ?? ActionName(rawValue: "")
        raw = try AnyJSON(from: decoder)
    }

    public func encode(to encoder: any Encoder) throws {
        // `raw` already contains `in_reply_to` and `action` when it came off
        // the wire, so re-encoding it reproduces the original frame. Encoding
        // the two typed fields separately as well would duplicate keys.
        if case .object(let object) = raw, !object.isEmpty {
            try raw.encode(to: encoder)
            return
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(inReplyTo, forKey: .inReplyTo)
        try container.encode(action, forKey: .action)
    }
}

/// `action_error` — a typed action failed.
public struct ActionErrorFrame: Hashable, Sendable, Codable {
    public var inReplyTo: String
    public var action: ActionName
    public var error: String

    public init(inReplyTo: String, action: ActionName, error: String) {
        self.inReplyTo = inReplyTo
        self.action = action
        self.error = error
    }

    public enum CodingKeys: String, CodingKey {
        case action, error
        case inReplyTo = "in_reply_to"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inReplyTo = try container.decode(String.self, forKey: .inReplyTo)
        action = try container.decodeIfPresent(ActionName.self, forKey: .action)
            ?? ActionName(rawValue: "")
        error = try container.decodeIfPresent(String.self, forKey: .error) ?? ""
    }
}

/// `models_list` — the reply to `list_models`.
///
/// ``current`` is optional and its absence is **honest**: the Pi could not
/// resolve the live model (`handlers.ts:297`). Fall back to the cached
/// `room_meta.model` string rather than showing nothing.
public struct ModelsList: Hashable, Sendable, Codable {
    public var inReplyTo: String
    public var models: [WireModel]
    public var current: WireModel?

    public init(inReplyTo: String, models: [WireModel], current: WireModel? = nil) {
        self.inReplyTo = inReplyTo
        self.models = models
        self.current = current
    }

    public enum CodingKeys: String, CodingKey {
        case models, current
        case inReplyTo = "in_reply_to"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inReplyTo = try container.decode(String.self, forKey: .inReplyTo)
        models = try container.decodeIfPresent([WireModel].self, forKey: .models) ?? []
        current = try container.decodeIfPresent(WireModel.self, forKey: .current)
    }
}

// MARK: - ServerMessage

/// Every inner frame a Pi (or the machine gateway) sends this client.
///
/// ## Unknown types are not fatal
///
/// The relay and the Pi are deployed independently of the app, so the Pi *will*
/// eventually send a frame this build has never heard of. It decodes to
/// ``unknown(type:raw:)``. Throwing instead would take the socket read loop
/// with it, which is the failure this case exists to prevent — and it costs
/// nothing, since the Flutter client already synthesises an
/// `unsupported_type` error for the same situation and keeps reading.
public enum ServerMessage: Hashable, Sendable {
    case pairOk(PairOk)
    case pairError(PairError)
    /// Covers **both** `user_message` (an echo) and `user_input` (a TUI
    /// mirror); ``UserInput/isEcho`` says which.
    case userInput(UserInput)
    case queuedMessageState(QueuedMessageState)
    /// The steering message with this id was absorbed into the running turn —
    /// clear the "steering…" affordance.
    case steerConsumed(id: String)
    case agentChunk(AgentChunk)
    case agentDone(AgentDone)
    case agentMessage(AgentMessage)
    case compaction(Compaction)
    case toolRequest(ToolRequest)
    case toolResult(ToolResult)
    case error(ErrorFrame)
    case cancelled(Cancelled)
    case pong(inReplyTo: String)
    /// The Pi is going away. Terminal: stop the retry loop and surface a
    /// banner; reconnection is a user action.
    case bye(reason: ByeReason)
    case sessionHistory(SessionHistory)
    case actionOk(ActionOk)
    case actionError(ActionErrorFrame)
    case modelsList(ModelsList)
    case extensionUIRequest(ExtensionUIRequest)
    /// A frame type this build does not know, preserved verbatim.
    case unknown(type: String, raw: AnyJSON)

    public var typeName: String {
        switch self {
        case .pairOk: return "pair_ok"
        case .pairError: return "pair_error"
        case .userInput(let payload): return payload.isEcho ? "user_message" : "user_input"
        case .queuedMessageState: return "queued_message_state"
        case .steerConsumed: return "steer_consumed"
        case .agentChunk: return "agent_chunk"
        case .agentDone: return "agent_done"
        case .agentMessage: return "agent_message"
        case .compaction: return "compaction"
        case .toolRequest: return "tool_request"
        case .toolResult: return "tool_result"
        case .error: return "error"
        case .cancelled: return "cancelled"
        case .pong: return "pong"
        case .bye: return "bye"
        case .sessionHistory: return "session_history"
        case .actionOk: return "action_ok"
        case .actionError: return "action_error"
        case .modelsList: return "models_list"
        case .extensionUIRequest: return "extension_ui_request"
        case .unknown(let type, _): return type
        }
    }

    /// The request id this frame answers, where it answers one.
    ///
    /// Note ``error(_:)`` is included. `list_models` reports a registry failure
    /// as an `error`, not an `action_error` (`handlers.ts:299-306`), so a
    /// pending-request table that only consults `action_ok`/`action_error`
    /// waits out its full timeout and reports "timed out" instead of the real
    /// message. Match on this property and that hole closes.
    public var inReplyTo: String? {
        switch self {
        case .pairOk(let payload): return payload.inReplyTo
        case .pairError(let payload): return payload.inReplyTo
        case .agentChunk(let payload): return payload.inReplyTo
        case .agentDone(let payload): return payload.inReplyTo
        case .agentMessage(let payload): return payload.inReplyTo
        case .error(let payload): return payload.inReplyTo
        case .cancelled(let payload): return payload.inReplyTo
        case .pong(let inReplyTo): return inReplyTo
        case .sessionHistory(let payload): return payload.inReplyTo
        case .actionOk(let payload): return payload.inReplyTo
        case .actionError(let payload): return payload.inReplyTo
        case .modelsList(let payload): return payload.inReplyTo
        case .userInput, .queuedMessageState, .steerConsumed, .compaction, .toolRequest,
            .toolResult, .bye, .extensionUIRequest, .unknown:
            return nil
        }
    }
}

extension ServerMessage: Codable {
    private enum TypeKey: String, CodingKey {
        case type, id, reason
        case inReplyTo = "in_reply_to"
    }

    public init(from decoder: any Decoder) throws {
        let shallow = try decoder.container(keyedBy: TypeKey.self)
        // A frame with no `type` at all is not a known frame; the Flutter
        // parser throws `UnsupportedTypeException("")` for it, which the
        // channel converts into an `unsupported_type` error. Same outcome, no
        // throw.
        let type = try shallow.decodeIfPresent(String.self, forKey: .type) ?? ""
        switch type {
        case "pair_ok": self = .pairOk(try PairOk(from: decoder))
        case "pair_error": self = .pairError(try PairError(from: decoder))
        case "user_message", "user_input":
            var payload = try UserInput(from: decoder)
            payload.isEcho = (type == "user_message")
            self = .userInput(payload)
        case "queued_message_state":
            self = .queuedMessageState(try QueuedMessageState(from: decoder))
        case "steer_consumed":
            self = .steerConsumed(id: try shallow.decode(String.self, forKey: .id))
        case "agent_chunk": self = .agentChunk(try AgentChunk(from: decoder))
        case "agent_done": self = .agentDone(try AgentDone(from: decoder))
        case "agent_message": self = .agentMessage(try AgentMessage(from: decoder))
        case "compaction": self = .compaction(try Compaction(from: decoder))
        case "tool_request": self = .toolRequest(try ToolRequest(from: decoder))
        case "tool_result": self = .toolResult(try ToolResult(from: decoder))
        case "error": self = .error(try ErrorFrame(from: decoder))
        case "cancelled": self = .cancelled(try Cancelled(from: decoder))
        case "pong": self = .pong(inReplyTo: try shallow.decode(String.self, forKey: .inReplyTo))
        case "bye":
            self = .bye(
                reason: try shallow.decodeIfPresent(ByeReason.self, forKey: .reason)
                    ?? ByeReason(rawValue: ""))
        case "session_history": self = .sessionHistory(try SessionHistory(from: decoder))
        case "action_ok": self = .actionOk(try ActionOk(from: decoder))
        case "action_error": self = .actionError(try ActionErrorFrame(from: decoder))
        case "models_list": self = .modelsList(try ModelsList(from: decoder))
        case "extension_ui_request":
            self = .extensionUIRequest(try ExtensionUIRequest(from: decoder))
        default:
            self = .unknown(type: type, raw: try AnyJSON(from: decoder))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .unknown(_, let raw):
            try raw.encode(to: encoder)
            return
        case .actionOk(let payload):
            if case .object(let object) = payload.raw, !object.isEmpty {
                // Decoded from the wire: `raw` IS the original frame, `type`
                // and all. Re-encoding it preserves control-plane fields this
                // build has no typed slot for.
                try payload.raw.encode(to: encoder)
            } else {
                // Constructed in code, so nothing wrote `type` for us.
                var shallow = encoder.container(keyedBy: TypeKey.self)
                try shallow.encode("action_ok", forKey: .type)
                try payload.encode(to: encoder)
            }
            return
        default:
            break
        }

        var shallow = encoder.container(keyedBy: TypeKey.self)
        try shallow.encode(typeName, forKey: .type)

        switch self {
        case .pairOk(let payload): try payload.encode(to: encoder)
        case .pairError(let payload): try payload.encode(to: encoder)
        case .userInput(let payload): try payload.encode(to: encoder)
        case .queuedMessageState(let payload): try payload.encode(to: encoder)
        case .agentChunk(let payload): try payload.encode(to: encoder)
        case .agentDone(let payload): try payload.encode(to: encoder)
        case .agentMessage(let payload): try payload.encode(to: encoder)
        case .compaction(let payload): try payload.encode(to: encoder)
        case .toolRequest(let payload): try payload.encode(to: encoder)
        case .toolResult(let payload): try payload.encode(to: encoder)
        case .error(let payload): try payload.encode(to: encoder)
        case .cancelled(let payload): try payload.encode(to: encoder)
        case .sessionHistory(let payload): try payload.encode(to: encoder)
        case .actionError(let payload): try payload.encode(to: encoder)
        case .modelsList(let payload): try payload.encode(to: encoder)
        case .extensionUIRequest(let payload): try payload.encode(to: encoder)
        case .steerConsumed(let id): try shallow.encode(id, forKey: .id)
        case .pong(let inReplyTo): try shallow.encode(inReplyTo, forKey: .inReplyTo)
        case .bye(let reason): try shallow.encode(reason, forKey: .reason)
        case .actionOk, .unknown: break  // handled above
        }
    }
}

extension ServerMessage {
    /// Decodes one inner frame, returning `nil` for JSON this build cannot make
    /// sense of at all.
    ///
    /// This is the read-loop entry point, and it never throws on purpose.
    /// The Flutter channel behaves the same way — an `UnsupportedTypeException`
    /// becomes a synthetic `unsupported_type` error and any other decode
    /// failure drops the frame (`peer_channel.dart:122-133`) — because the
    /// alternative is that one malformed frame ends the session.
    public static func decodeLossy(_ data: Data) -> ServerMessage? {
        try? WireJSON.decode(ServerMessage.self, from: data)
    }

    public static func decodeLossy(_ text: String) -> ServerMessage? {
        decodeLossy(Data(text.utf8))
    }
}
