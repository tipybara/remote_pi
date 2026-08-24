import Foundation

/// One replayed event inside a ``SessionHistory``.
///
/// Every event carries `ts` (epoch milliseconds) plus a `type`.
public enum SessionHistoryEvent: Hashable, Sendable {
    /// A user turn. **Its `id` is `sync_<epoch_ms>`, not the live
    /// `cli_<uuid7>`** (`index.ts:4617`) — a re-sync renumbers every user
    /// message. See ``SessionHistory`` for what that costs.
    case userInput(ts: Int64, id: String, text: String, images: [WireImage])
    case toolRequest(ts: Int64, toolCallID: String, tool: String, args: AnyJSON?)
    case toolResult(ts: Int64, toolCallID: String, result: AnyJSON?, error: String?)
    /// `inReplyTo` here is the **last** `user_input` id seen in a linear scan —
    /// an approximation the Pi acknowledges in its own comments
    /// (`index.ts:4594-4597`). Do not build strict threading on it.
    case agentMessage(ts: Int64, inReplyTo: String, text: String, usage: Usage?)
    /// A context compaction marker. Carries no `ts` field of its own beyond the
    /// standard event `ts`, and `tokens_before` defaults to `0` when the SDK
    /// did not supply one.
    case compaction(ts: Int64, summary: String, tokensBefore: Int?)

    public var ts: Int64 {
        switch self {
        case .userInput(let ts, _, _, _),
            .toolRequest(let ts, _, _, _),
            .toolResult(let ts, _, _, _),
            .agentMessage(let ts, _, _, _),
            .compaction(let ts, _, _):
            return ts
        }
    }

    public var typeName: String {
        switch self {
        case .userInput: return "user_input"
        case .toolRequest: return "tool_request"
        case .toolResult: return "tool_result"
        case .agentMessage: return "agent_message"
        case .compaction: return "compaction"
        }
    }
}

extension SessionHistoryEvent: Codable {
    private enum Key: String, CodingKey {
        case ts, type, id, text, images, tool, args, result, error, summary
        case toolCallID = "tool_call_id"
        case inReplyTo = "in_reply_to"
        case tokensBefore = "tokens_before"
        case usage
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        let ts = try container.decode(Int64.self, forKey: .ts)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "user_input":
            self = .userInput(
                ts: ts,
                id: try container.decode(String.self, forKey: .id),
                text: try container.decode(String.self, forKey: .text),
                images: try container.decodeIfPresent([WireImage].self, forKey: .images) ?? []
            )
        case "tool_request":
            self = .toolRequest(
                ts: ts,
                toolCallID: try container.decode(String.self, forKey: .toolCallID),
                tool: try container.decode(String.self, forKey: .tool),
                args: try container.decodeIfPresent(AnyJSON.self, forKey: .args)
            )
        case "tool_result":
            self = .toolResult(
                ts: ts,
                toolCallID: try container.decode(String.self, forKey: .toolCallID),
                result: try container.decodeIfPresent(AnyJSON.self, forKey: .result),
                error: try container.decodeIfPresent(String.self, forKey: .error)
            )
        case "agent_message":
            self = .agentMessage(
                ts: ts,
                inReplyTo: try container.decode(String.self, forKey: .inReplyTo),
                text: try container.decode(String.self, forKey: .text),
                usage: try container.decodeIfPresent(Usage.self, forKey: .usage)
            )
        case "compaction":
            self = .compaction(
                ts: ts,
                summary: try container.decodeIfPresent(String.self, forKey: .summary) ?? "",
                tokensBefore: try container.decodeIfPresent(Int.self, forKey: .tokensBefore)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "unknown session_history event type: \(type)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(ts, forKey: .ts)
        try container.encode(typeName, forKey: .type)
        switch self {
        case .userInput(_, let id, let text, let images):
            try container.encode(id, forKey: .id)
            try container.encode(text, forKey: .text)
            if !images.isEmpty { try container.encode(images, forKey: .images) }
        case .toolRequest(_, let toolCallID, let tool, let args):
            try container.encode(toolCallID, forKey: .toolCallID)
            try container.encode(tool, forKey: .tool)
            try container.encodeIfPresent(args, forKey: .args)
        case .toolResult(_, let toolCallID, let result, let error):
            try container.encode(toolCallID, forKey: .toolCallID)
            try container.encodeIfPresent(result, forKey: .result)
            try container.encodeIfPresent(error, forKey: .error)
        case .agentMessage(_, let inReplyTo, let text, let usage):
            try container.encode(inReplyTo, forKey: .inReplyTo)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(usage, forKey: .usage)
        case .compaction(_, let summary, let tokensBefore):
            try container.encode(summary, forKey: .summary)
            try container.encodeIfPresent(tokensBefore, forKey: .tokensBefore)
        }
    }
}

/// `session_history` — the reply to a `session_sync`.
///
/// ## It is a replacement, not a delta
///
/// There is no `since_ts` negotiation. Rebuild the transcript from this frame;
/// do not merge it into what is already there.
///
/// ## `sessionStartedAt` is the restart detector
///
/// A changed value means the Pi restarted and the local cache must be
/// **replaced** rather than appended to. `0` means "no session yet" — which is
/// also what a Pi with no bound session answers, together with `events: []`
/// and `eos: true`.
///
/// ## Message ids are not stable across a re-sync
///
/// Live user messages are `cli_<uuid7>`; the same messages come back here as
/// `sync_<epoch_ms>`. Any store keyed by message id must be rebuilt from
/// history rather than merged, and a pending optimistic row must be matched by
/// **id-absence**, not id-equality. (Two user messages persisted in the same
/// millisecond also collide on `sync_<ts>` — an upstream flaw, not something a
/// client can fix.)
public struct SessionHistory: Hashable, Sendable, Codable {
    public var inReplyTo: String
    /// Epoch milliseconds. `0` = no session yet.
    public var sessionStartedAt: Int64
    public var events: [SessionHistoryEvent]
    /// The current Pi always sends a single batch with `eos: true`
    /// (`index.ts:4335-4342`). Implement the accumulate-until-`eos` loop
    /// anyway — it costs nothing and the Dart comment describing batching is
    /// aspirational rather than wrong.
    public var eos: Bool
    /// `true` when there were more events than the effective limit and the
    /// **oldest** were dropped. Log it; there is no UI affordance by design.
    public var truncated: Bool
    /// Events the decoder could not understand, kept as raw JSON.
    ///
    /// This is the whole reason the events array is decoded leniently: the
    /// Flutter parser throws on an unknown event type *inside*
    /// `SessionHistory.fromJson`, the throw escapes to the frame handler, and
    /// the **entire history frame is dropped**. The user sees an empty chat
    /// rather than a partial one. Skipping the one bad event and keeping the
    /// rest is strictly better, and stashing it here means the drop is
    /// observable instead of silent.
    public var undecodableEvents: [AnyJSON]

    public init(
        inReplyTo: String,
        sessionStartedAt: Int64,
        events: [SessionHistoryEvent],
        eos: Bool,
        truncated: Bool = false,
        undecodableEvents: [AnyJSON] = []
    ) {
        self.inReplyTo = inReplyTo
        self.sessionStartedAt = sessionStartedAt
        self.events = events
        self.eos = eos
        self.truncated = truncated
        self.undecodableEvents = undecodableEvents
    }

    public enum CodingKeys: String, CodingKey {
        case events, eos, truncated
        case inReplyTo = "in_reply_to"
        case sessionStartedAt = "session_started_at"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inReplyTo = try container.decode(String.self, forKey: .inReplyTo)
        sessionStartedAt = try container.decode(Int64.self, forKey: .sessionStartedAt)
        eos = try container.decode(Bool.self, forKey: .eos)
        // Tolerated absent — the field arrived mid-protocol and an older Pi
        // omits it.
        truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false

        // Decode each element to `AnyJSON` FIRST, then try to interpret it.
        // A failed `decode` inside an unkeyed container does not advance the
        // container's cursor in Swift, so the obvious "try, catch, continue"
        // loop spins forever or desynchronises. Going through `AnyJSON` always
        // consumes exactly one element.
        let raw = try container.decode([AnyJSON].self, forKey: .events)
        var decoded: [SessionHistoryEvent] = []
        var skipped: [AnyJSON] = []
        let elementDecoder = WireJSON.makeDecoder()
        for element in raw {
            guard let data = try? JSONSerialization.data(withJSONObject: element.jsonObject),
                let event = try? elementDecoder.decode(SessionHistoryEvent.self, from: data)
            else {
                skipped.append(element)
                continue
            }
            decoded.append(event)
        }
        events = decoded
        undecodableEvents = skipped
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(inReplyTo, forKey: .inReplyTo)
        try container.encode(sessionStartedAt, forKey: .sessionStartedAt)
        try container.encode(events, forKey: .events)
        try container.encode(eos, forKey: .eos)
        try container.encode(truncated, forKey: .truncated)
    }
}
