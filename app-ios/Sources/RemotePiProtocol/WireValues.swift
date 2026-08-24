import Foundation

/// An open string union on the wire: a `RawRepresentable` struct that codes as
/// a **bare JSON string**, not as `{"rawValue": …}`.
///
/// Swift synthesizes `Codable` from `RawValue` only for `enum`s. A struct gets
/// the memberwise synthesis instead, which would put `{"rawValue":"steer"}` on
/// the wire — accepted by nobody, and silent, because encoding never fails.
/// Every conformer below therefore takes this single-value implementation.
public protocol WireStringValue: RawRepresentable, Codable, Hashable, Sendable
where RawValue == String {}

extension WireStringValue {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = Self(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "unrepresentable value: \(raw)")
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - Open string unions
//
// Several wire fields are declared as closed unions in TypeScript but are
// produced by code that already emits values outside the declaration (`error.code`
// emits `provider_error`, which `types.ts` never lists) or are explicitly open
// (`ErrorCode = KnownErrorCode | (string & {})`).
//
// Each one below is a `RawRepresentable` struct with named constants rather
// than a Swift `enum`. That is deliberate:
//
//   * a closed `enum` throws on a value a newer Pi adds, and a throw out of the
//     socket read loop kills the connection (spec 01, Trap T1);
//   * an `enum` + `.unknown(String)` case works, but the Flutter client shows
//     what the *other* mistake costs: `ActionOk.action` falls back to
//     `.sessionCompact` on an unrecognised wire value while keeping the raw
//     string alongside, so a `switch` that forgets to consult the raw string
//     silently treats an unknown action as a compaction ack
//     (`app/lib/protocol/protocol.dart:1663`, spec 01 §10 row 9).
//
// A `RawRepresentable` struct has no wrong default to fall into: comparing
// against `.sessionCompact` is only ever true when the wire actually said
// `session_compact`.

/// Steering behaviour on a `user_message`.
///
/// ``steer`` is the only value either side declares today. Note the Pi *adds*
/// it to the echo of a message that arrived without it, when the room was
/// already `working` (`index.ts:4055`, `index.ts:722-732`) — so the echo does
/// not necessarily mirror what was sent.
public struct StreamingBehavior: WireStringValue {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let steer = StreamingBehavior(rawValue: "steer")
}

/// Why the Pi is closing the channel. Terminal: stop the retry loop, surface a
/// banner, reconnect manually.
public struct ByeReason: WireStringValue {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let peerStop = ByeReason(rawValue: "peer_stop")
    public static let sessionReplaced = ByeReason(rawValue: "session_replaced")
    public static let shutdown = ByeReason(rawValue: "shutdown")
}

/// `error.code`. Explicitly an open union on the wire.
public struct ErrorCode: WireStringValue {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let toolApprovalRequired = ErrorCode(rawValue: "tool_approval_required")
    public static let invalidMessage = ErrorCode(rawValue: "invalid_message")
    public static let unsupportedType = ErrorCode(rawValue: "unsupported_type")
    public static let tooLarge = ErrorCode(rawValue: "too_large")
    public static let rateLimited = ErrorCode(rawValue: "rate_limited")
    public static let timeout = ErrorCode(rawValue: "timeout")
    public static let internalError = ErrorCode(rawValue: "internal_error")
    /// Emitted by `index.ts:2272` but absent from the declared union.
    public static let providerError = ErrorCode(rawValue: "provider_error")

    /// `true` when this error means the Mac no longer knows us and the pairing
    /// must be redone.
    ///
    /// Matched as a **substring**, not an equality, because the Flutter client
    /// does (`sync_service.dart:625`) and no emitter for the bare code exists
    /// in this repo — the observed shape wraps it in a longer message code.
    public var indicatesRevokedPairing: Bool {
        rawValue.contains("unknown_peer")
    }
}

/// `pair_error.code`.
public struct PairErrorCode: WireStringValue {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let tokenExpired = PairErrorCode(rawValue: "token_expired")
    public static let tokenConsumed = PairErrorCode(rawValue: "token_consumed")
    public static let tokenUnknown = PairErrorCode(rawValue: "token_unknown")
    public static let internalError = PairErrorCode(rawValue: "internal_error")
}

/// The `action` field echoed on `action_ok` / `action_error`.
///
/// Ten values, not five. Two *different* producers answer with this field —
/// the chat Pi (`types.ts:393-398`, five names) and the machine supervisor
/// gateway (`control_wire.ts:22-30`, six names, one overlapping) — and a client
/// sees replies from both on one socket. The Flutter client's merged enum is
/// the only complete inventory (`protocol.dart:758-786`).
public struct ActionName: WireStringValue {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    // Chat actions — answered by the Pi bound to a session room.
    public static let sessionNew = ActionName(rawValue: "session_new")
    public static let sessionCompact = ActionName(rawValue: "session_compact")
    public static let modelSet = ActionName(rawValue: "model_set")
    public static let thinkingSet = ActionName(rawValue: "thinking_set")
    /// Answered by **both** producers: the chat Pi renames its own session, the
    /// gateway renames a catalogued one.
    public static let sessionRename = ActionName(rawValue: "session_rename")

    // Machine control plane — answered by the supervisor gateway at `ctrl`.
    public static let workspaceList = ActionName(rawValue: "workspace_list")
    public static let sessionList = ActionName(rawValue: "session_list")
    public static let createSession = ActionName(rawValue: "create_session")
    public static let sessionStart = ActionName(rawValue: "session_start")
    public static let sessionStop = ActionName(rawValue: "session_stop")

    public static let allKnown: Set<ActionName> = [
        .sessionNew, .sessionCompact, .modelSet, .thinkingSet, .sessionRename,
        .workspaceList, .sessionList, .createSession, .sessionStart, .sessionStop,
    ]

    public var isKnown: Bool { Self.allKnown.contains(self) }

    /// `true` when this action is answered by the machine gateway rather than
    /// by a chat Pi — i.e. it must be addressed at ``RoomID/control``.
    public var isMachineControl: Bool {
        switch self {
        case .workspaceList, .sessionList, .createSession, .sessionStart, .sessionStop:
            return true
        default:
            return false
        }
    }
}

/// `approve_tool.decision`.
///
/// Present for forward compatibility only — there is no approval gate in this
/// fork. See ``ApproveTool``.
public struct ApproveDecision: WireStringValue {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let allow = ApproveDecision(rawValue: "allow")
    public static let deny = ApproveDecision(rawValue: "deny")
}

// MARK: - Token usage

/// Token accounting for one turn.
///
/// **Not** delivered on the live path: `agent_done` never carries it
/// (`index.ts:2282` emits the frame with no `usage`). It appears only on
/// `agent_message` events replayed inside a `session_history`. A live token
/// meter built on `agent_done.usage` reads zero forever.
public struct Usage: Hashable, Sendable, Codable {
    public var inputTokens: Int
    public var outputTokens: Int

    public init(inputTokens: Int, outputTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    public enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}

// MARK: - Models

/// One row of the model picker, as the Pi publishes it.
///
/// `id`, `name` and `provider` are hard-required — the Flutter parser casts
/// them without a fallback, so a frame missing one is a bug on the Pi, not
/// something to paper over. The three flags carry defaults because a Pi that
/// cannot resolve them omits them rather than guessing.
public struct WireModel: Hashable, Sendable, Codable {
    public var id: String
    public var name: String
    public var provider: String
    /// Whether the model exposes a thinking surface — gates the thinking
    /// picker.
    public var reasoning: Bool
    /// Context window in tokens. `0` means "the Pi did not say".
    public var contextWindow: Int
    /// Whether the model accepts image input — gates the attach button.
    public var vision: Bool

    public init(
        id: String,
        name: String,
        provider: String,
        reasoning: Bool = false,
        contextWindow: Int = 0,
        vision: Bool = false
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.reasoning = reasoning
        self.contextWindow = contextWindow
        self.vision = vision
    }

    public enum CodingKeys: String, CodingKey {
        case id, name, provider, reasoning, vision
        case contextWindow = "context_window"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        provider = try container.decode(String.self, forKey: .provider)
        reasoning = try container.decodeIfPresent(Bool.self, forKey: .reasoning) ?? false
        contextWindow = try container.decodeIfPresent(Int.self, forKey: .contextWindow) ?? 0
        vision = try container.decodeIfPresent(Bool.self, forKey: .vision) ?? false
    }
}

// MARK: - Harness

/// Which coding agent is driving the paired Mac (`pair_ok.harness`).
public struct PiHarness: Hashable, Sendable, Codable {
    public var name: String
    public var version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }

    /// What the UI shows when `pair_ok` omitted `harness` — matches the
    /// Flutter fallback exactly so two devices render the same subtitle.
    public static let unknown = PiHarness(name: "Pi coding agent", version: "—")

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? Self.unknown.name
        version =
            try container.decodeIfPresent(String.self, forKey: .version) ?? Self.unknown.version
    }
}

// MARK: - Queued messages

/// One message waiting to be drained into the next turn.
public struct QueuedMessageItem: Hashable, Sendable, Codable, Identifiable {
    /// The id the message will carry **when it is drained into a real turn**
    /// (`index.ts:992`), so it is minted as if it were a `user_message` id.
    public var id: String
    public var text: String
    public var editable: Bool
    /// Epoch milliseconds. `0` when the Pi did not stamp one — which is what
    /// the legacy top-level `{id, text}` mirror decodes to.
    public var createdAt: Int64

    public init(id: String, text: String, editable: Bool = true, createdAt: Int64 = 0) {
        self.id = id
        self.text = text
        self.editable = editable
        self.createdAt = createdAt
    }

    public enum CodingKeys: String, CodingKey {
        case id, text, editable
        case createdAt = "created_at"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        editable = try container.decodeIfPresent(Bool.self, forKey: .editable) ?? true
        createdAt = try container.decodeIfPresent(Int64.self, forKey: .createdAt) ?? 0
    }
}

// MARK: - Tool-call diff enrichment

/// One line of the synthetic diff the Pi injects into `tool_request.args` when
/// the tool is `edit` (case-insensitively).
///
/// **This is real and load-bearing and appears in no `.d.ts`.** The Pi reads
/// the file off disk, reconstructs the hunks around each edit, and hangs them
/// on `args.hunks` (`index.ts:4395-4431`); the Flutter chat renders them as a
/// diff card. The key is absent when the Pi could not read the file — that is
/// the "show the raw args instead" signal, not an error.
public struct DiffLine: Hashable, Sendable, Codable {
    public struct Kind: WireStringValue {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        public static let context = Kind(rawValue: "context")
        public static let remove = Kind(rawValue: "remove")
        public static let add = Kind(rawValue: "add")
        /// A gap marker between hunks. Carries no `text` and no line numbers.
        public static let ellipsis = Kind(rawValue: "ellipsis")
    }

    public var kind: Kind
    public var oldLine: Int?
    public var newLine: Int?
    public var text: String?

    public init(kind: Kind, oldLine: Int? = nil, newLine: Int? = nil, text: String? = nil) {
        self.kind = kind
        self.oldLine = oldLine
        self.newLine = newLine
        self.text = text
    }

    // camelCase on the wire. The diff payload mirrors the Pi's internal
    // `DiffLine` type verbatim rather than the protocol's snake_case
    // convention — a blanket `.convertFromSnakeCase` decoder would map
    // `oldLine` to `oldline` and null out every line number.
    public enum CodingKeys: String, CodingKey {
        case kind, oldLine, newLine, text
    }
}

/// A contiguous run of ``DiffLine``s.
public struct DiffHunk: Hashable, Sendable, Codable {
    public var lines: [DiffLine]

    public init(lines: [DiffLine]) { self.lines = lines }
}
