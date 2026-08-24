import Foundation

// MARK: - Payloads

/// `pair_request` — the one frame sent before a channel exists, on the
/// throwaway pairing transport.
///
/// All three fields are required. `token` is the one-shot secret from the QR
/// code; it is consumed on first use, so a retry after a `pair_ok` is lost
/// fails with `token_consumed` rather than pairing twice.
public struct PairRequest: Hashable, Sendable, Codable {
    public var id: String
    public var token: String
    public var deviceName: String

    public init(id: String, token: String, deviceName: String) {
        self.id = id
        self.token = token
        self.deviceName = deviceName
    }

    public enum CodingKeys: String, CodingKey {
        case id, token
        case deviceName = "device_name"
    }
}

/// `user_message` — a turn of conversation.
public struct UserMessage: Hashable, Sendable, Codable {
    public var id: String
    /// May be `""` when the message carries only images.
    public var text: String
    /// Omitted when `nil`.
    ///
    /// Leaving it off is not the same as "not steering": the Pi infers a steer
    /// server-side when the room is already `working` (`index.ts:4055`), and
    /// the echo comes back carrying `streaming_behavior: "steer"` that the
    /// client never sent. Do not diff the echo against what was sent.
    public var streamingBehavior: StreamingBehavior?
    /// Omitted **entirely** when empty, never sent as `[]`.
    ///
    /// The wire is a list to mirror the SDK's content-block array, but the
    /// product sends at most one and the Pi's history replay only ever
    /// reconstructs the first.
    public var images: [WireImage]?

    public init(
        id: String,
        text: String,
        streamingBehavior: StreamingBehavior? = nil,
        images: [WireImage]? = nil
    ) {
        self.id = id
        self.text = text
        self.streamingBehavior = streamingBehavior
        // An empty array would serialize as `"images": []`, which no producer
        // on this wire emits; normalise it away at the boundary so the encoder
        // does not have to special-case it.
        self.images = (images?.isEmpty ?? true) ? nil : images
    }

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
        let decoded = try container.decodeIfPresent([WireImage].self, forKey: .images)
        images = (decoded?.isEmpty ?? true) ? nil : decoded
    }
}

/// `queued_message_set` — park a message for the next turn.
///
/// Text only: images ride solely on an immediate `user_message`, and the drain
/// path builds the real turn with no `images` key at all (`index.ts:993`).
///
/// **A `text` that trims to empty is a delete**, not a set — the Pi routes it
/// to `_clearQueuedItems(msg.id)` (`index.ts:4028-4032`). Callers that want a
/// delete should say so with ``QueuedMessageClear`` instead of relying on that.
public struct QueuedMessageSet: Hashable, Sendable, Codable {
    /// The id the message will carry once drained into a real turn — mint it
    /// exactly as a ``UserMessage`` id.
    public var id: String
    public var text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

/// `queued_message_clear` — drop one queued message, or all of them.
public struct QueuedMessageClear: Hashable, Sendable, Codable {
    public var id: String
    /// **Omitted clears the whole queue** (`index.ts:4037`). Not the same as
    /// an empty string, which would match no item and clear nothing.
    public var targetID: String?

    public init(id: String, targetID: String? = nil) {
        self.id = id
        self.targetID = targetID
    }

    public enum CodingKeys: String, CodingKey {
        case id
        case targetID = "target_id"
    }
}

/// `approve_tool` — **do not send this.**
///
/// Declared in both protocol files and still emitted by the Flutter app, but
/// the Pi drops it on the floor and never replies ("Approval gate was removed
/// (plano 10.2 revisado)", `index.ts:4100-4104`). Awaiting a reply hangs
/// forever. Kept in the type system so a frame arriving from some other client
/// decodes rather than throwing, and so the removal stays documented.
public struct ApproveTool: Hashable, Sendable, Codable {
    public var id: String
    public var toolCallID: String
    public var decision: ApproveDecision

    public init(id: String, toolCallID: String, decision: ApproveDecision) {
        self.id = id
        self.toolCallID = toolCallID
        self.decision = decision
    }

    public enum CodingKeys: String, CodingKey {
        case id, decision
        case toolCallID = "tool_call_id"
    }
}

/// `cancel` — abort the turn `targetID` started.
///
/// Handled **before** the Pi's "is a session bound?" guard (`index.ts:3997`
/// vs `4024`), so it works even on a half-initialised Pi. Answered with
/// `cancelled` on success, or an `error` with `code: "internal_error"` and
/// `"No active Pi context to abort"` when there was no live turn — note that
/// is an ``ServerMessage/error(_:)``, not an `action_error`.
public struct Cancel: Hashable, Sendable, Codable {
    public var id: String
    /// The `id` of the `user_message` that started the turn.
    public var targetID: String

    public init(id: String, targetID: String) {
        self.id = id
        self.targetID = targetID
    }

    public enum CodingKeys: String, CodingKey {
        case id
        case targetID = "target_id"
    }
}

/// `session_sync` — ask for the current state of the session.
///
/// The reply is a **full replacement** of local state, in three parts:
/// `queued_message_state`, then `session_history`, then zero or more
/// `extension_ui_request` frames replaying unanswered ask flows. There is no
/// delta negotiation and no `since_ts`.
public struct SessionSync: Hashable, Sendable, Codable {
    public var id: String
    /// Clamped server-side to `min(requested, REMOTE_PI_SYNC_LIMIT ?? 30)`.
    /// Asking for more than the ceiling yields the ceiling, not an error. The
    /// Flutter client omits it entirely.
    public var limit: Int?

    public init(id: String, limit: Int? = nil) {
        self.id = id
        self.limit = limit
    }
}

/// `session_rename` addressed at a **chat** session's own room.
///
/// The gateway-addressed twin is ``ControlAction/sessionRename(id:session:displayName:rev:)``;
/// the two serialize identically, and this one exists because the chat path
/// may legitimately not know a session id (a pre-plan-61 Pi never published
/// one) while the control path always does.
///
/// ## Two things that will bite
///
/// 1. **`rev` is the revision you last SAW**, read off
///    ``RoomMeta/nameRev``, never one you minted. The Pi mints the new
///    revision itself (`_nextNameRev`, `index.ts:283-287`). Sending
///    `currentRev + 1` passes the Pi's strictly-less check today but leaves
///    this device out of step with the relay's own gate, and it loses the next
///    race.
/// 2. **The frame must be addressed at the target session's room without
///    moving the connection's active room.** Renaming from a list view with a
///    "switch room then send" primitive drags the user's open chat to a
///    different session.
///
/// A rename to the name the Pi already holds returns `action_ok` and emits **no
/// patch and no revision bump** (`index.ts:360`). Do not read `action_ok` as
/// "a newer revision now exists".
public struct SessionRename: Hashable, Sendable, Codable {
    public var id: String
    /// Trimmed Pi-side. Whitespace-only is refused with
    /// `"display_name must be a non-empty string"`.
    public var displayName: String
    /// Which session this rename targets. Optional on the wire, but **always
    /// send it**: without it a frame that raced a `/new` or a session
    /// replacement renames whatever session happens to be current now.
    public var sessionID: SessionID?
    /// The ``RoomMeta/nameRev`` this device last saw. Optional on the wire,
    /// but always send it.
    public var rev: Int64?

    public init(
        id: String,
        displayName: String,
        sessionID: SessionID? = nil,
        rev: Int64? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.sessionID = sessionID
        self.rev = rev
    }

    public enum CodingKeys: String, CodingKey {
        case id, rev
        case displayName = "display_name"
        case sessionID = "session_id"
    }
}

/// `model_set` — switch the session's model.
///
/// Both fields are required. Every failure mode comes back as `action_error`
/// with a human-readable string: no registry, model not in registry, no auth
/// configured (`actions/handlers.ts:243-274`).
public struct ModelSet: Hashable, Sendable, Codable {
    public var id: String
    public var provider: String
    public var modelID: String

    public init(id: String, provider: String, modelID: String) {
        self.id = id
        self.provider = provider
        self.modelID = modelID
    }

    public enum CodingKeys: String, CodingKey {
        case id, provider
        case modelID = "model_id"
    }
}

/// `thinking_set` — change reasoning effort.
///
/// The Pi does not validate the level; it forwards to the SDK, and any throw
/// becomes `action_error`. `xhigh` is honoured only by some model families and
/// the SDK falls back silently for the rest.
public struct ThinkingSet: Hashable, Sendable, Codable {
    public var id: String
    public var level: ThinkingLevel

    public init(id: String, level: ThinkingLevel) {
        self.id = id
        self.level = level
    }
}

// MARK: - ClientMessage

/// Every inner frame this client sends to a Pi or to the machine gateway.
///
/// ## Shape
///
/// An externally-tagged union with a **flat** payload: `type` sits in the same
/// object as the fields, not wrapping them. Swift's synthesized `Codable`
/// cannot express that, so each case decodes its payload from the *same*
/// decoder after peeking at `type`.
///
/// ## Where each case is addressed
///
/// - ``pairRequest(_:)`` — the pairing transport, before a channel exists.
/// - ``control(_:)`` — ``RoomID/control`` on the machine's peer.
/// - everything else — the session's own room (`room == session_id`).
public enum ClientMessage: Hashable, Sendable {
    case pairRequest(PairRequest)
    case userMessage(UserMessage)
    case queuedMessageSet(QueuedMessageSet)
    case queuedMessageClear(QueuedMessageClear)
    /// Never send this. See ``ApproveTool``.
    case approveTool(ApproveTool)
    case cancel(Cancel)
    /// A **Pi**-liveness probe, not a WebSocket keep-alive — the socket layer
    /// has RFC 6455 ping/pong for that. Send every 25 s and mark the room
    /// offline locally after 3 unanswered, **without** closing the socket: the
    /// old tear-down-on-3-misses policy produced permanent `room_already_open`
    /// lockouts.
    case ping(id: String)
    case sessionSync(SessionSync)
    /// Clears the session's **context**. It does *not* create a session — the
    /// UI label is "New Context". Creating one is
    /// ``ControlAction/createSession(id:idempotencyKey:workspace:displayName:)``.
    case sessionNew(id: String)
    case sessionCompact(id: String)
    case sessionRename(SessionRename)
    case modelSet(ModelSet)
    case thinkingSet(ThinkingSet)
    /// Answered by `models_list` — **or by `error`**, never by `action_error`
    /// (`handlers.ts:299-306`). A client demultiplexing only on
    /// `models_list | action_error` waits out its whole timeout on a broken
    /// registry, which is exactly the hole the Flutter `ActionsRepository`
    /// still has. Match `error.in_reply_to` against the pending map too.
    case listModels(id: String)
    /// Fire-and-forget: the Pi routes it to the ask bridge and returns without
    /// a reply. Confirmation arrives asynchronously as an
    /// ``ExtensionUIRequest`` with `method: "notify"`.
    case extensionUIResponse(ExtensionUIResponse)
    /// A machine-control action, addressed at ``RoomID/control``.
    case control(ControlAction)
    /// A frame this build does not know, preserved verbatim.
    ///
    /// Only reachable by *decoding* — nothing constructs one to send. It exists
    /// so replaying a captured log or a fixture from a newer client does not
    /// throw.
    case unknown(type: String, raw: AnyJSON)

    /// The wire `type`.
    public var typeName: String {
        switch self {
        case .pairRequest: return "pair_request"
        case .userMessage: return "user_message"
        case .queuedMessageSet: return "queued_message_set"
        case .queuedMessageClear: return "queued_message_clear"
        case .approveTool: return "approve_tool"
        case .cancel: return "cancel"
        case .ping: return "ping"
        case .sessionSync: return "session_sync"
        case .sessionNew: return "session_new"
        case .sessionCompact: return "session_compact"
        case .sessionRename: return "session_rename"
        case .modelSet: return "model_set"
        case .thinkingSet: return "thinking_set"
        case .listModels: return "list_models"
        case .extensionUIResponse: return "extension_ui_response"
        case .control(let action): return action.name
        case .unknown(let type, _): return type
        }
    }

    /// The correlation id the reply will echo in `in_reply_to`.
    ///
    /// `nil` for ``extensionUIResponse(_:)``, whose `id` is a *flow* id and is
    /// never answered, and for ``unknown(type:raw:)``.
    public var requestID: String? {
        switch self {
        case .pairRequest(let payload): return payload.id
        case .userMessage(let payload): return payload.id
        case .queuedMessageSet(let payload): return payload.id
        case .queuedMessageClear(let payload): return payload.id
        case .approveTool(let payload): return payload.id
        case .cancel(let payload): return payload.id
        case .ping(let id), .sessionNew(let id), .sessionCompact(let id),
            .listModels(let id):
            return id
        case .sessionSync(let payload): return payload.id
        case .sessionRename(let payload): return payload.id
        case .modelSet(let payload): return payload.id
        case .thinkingSet(let payload): return payload.id
        case .control(let action): return action.id.rawValue
        case .extensionUIResponse, .unknown: return nil
        }
    }
}

extension ClientMessage: Codable {
    private enum TypeKey: String, CodingKey { case type, id }

    public init(from decoder: any Decoder) throws {
        let shallow = try decoder.container(keyedBy: TypeKey.self)
        let type = try shallow.decode(String.self, forKey: .type)
        switch type {
        case "pair_request": self = .pairRequest(try PairRequest(from: decoder))
        case "user_message": self = .userMessage(try UserMessage(from: decoder))
        case "queued_message_set": self = .queuedMessageSet(try QueuedMessageSet(from: decoder))
        case "queued_message_clear":
            self = .queuedMessageClear(try QueuedMessageClear(from: decoder))
        case "approve_tool": self = .approveTool(try ApproveTool(from: decoder))
        case "cancel": self = .cancel(try Cancel(from: decoder))
        case "ping": self = .ping(id: try shallow.decode(String.self, forKey: .id))
        case "session_sync": self = .sessionSync(try SessionSync(from: decoder))
        case "session_new": self = .sessionNew(id: try shallow.decode(String.self, forKey: .id))
        case "session_compact":
            self = .sessionCompact(id: try shallow.decode(String.self, forKey: .id))
        case "session_rename": self = .sessionRename(try SessionRename(from: decoder))
        case "model_set": self = .modelSet(try ModelSet(from: decoder))
        case "thinking_set": self = .thinkingSet(try ThinkingSet(from: decoder))
        case "list_models":
            self = .listModels(id: try shallow.decode(String.self, forKey: .id))
        case "extension_ui_response":
            self = .extensionUIResponse(try ExtensionUIResponse(from: decoder))
        case "workspace_list", "session_list", "create_session", "session_start", "session_stop":
            self = .control(try ControlAction(from: decoder))
        default:
            self = .unknown(type: type, raw: try AnyJSON(from: decoder))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        // These two write their own `type` and take their own container. Handle
        // them BEFORE `container(keyedBy:)` below: taking a keyed container and
        // then a single-value container from one encoder is a runtime trap.
        switch self {
        case .unknown(_, let raw):
            try raw.encode(to: encoder)
            return
        case .control(let action):
            try action.encode(to: encoder)
            return
        default:
            break
        }

        // Every other case writes `type` itself: the payload structs are also
        // used standalone (persisted, logged, fixture-compared), so the
        // discriminant cannot live inside them.
        var shallow = encoder.container(keyedBy: TypeKey.self)
        try shallow.encode(typeName, forKey: .type)

        switch self {
        case .pairRequest(let payload): try payload.encode(to: encoder)
        case .userMessage(let payload): try payload.encode(to: encoder)
        case .queuedMessageSet(let payload): try payload.encode(to: encoder)
        case .queuedMessageClear(let payload): try payload.encode(to: encoder)
        case .approveTool(let payload): try payload.encode(to: encoder)
        case .cancel(let payload): try payload.encode(to: encoder)
        case .sessionSync(let payload): try payload.encode(to: encoder)
        case .sessionRename(let payload): try payload.encode(to: encoder)
        case .modelSet(let payload): try payload.encode(to: encoder)
        case .thinkingSet(let payload): try payload.encode(to: encoder)
        case .extensionUIResponse(let payload): try payload.encode(to: encoder)
        case .ping(let id), .sessionNew(let id), .sessionCompact(let id), .listModels(let id):
            try shallow.encode(id, forKey: .id)
        case .control, .unknown:
            break  // handled above
        }
    }
}

// MARK: - ControlAction wire coding

extension ControlAction: Codable {
    private enum Key: String, CodingKey {
        case type, id, rev
        case workspaceID = "workspace_id"
        case sessionID = "session_id"
        case idempotencyKey = "idempotency_key"
        case displayName = "display_name"
        case background
    }

    /// Mirrors `parseControlAction` (`control_wire.ts:82-140`), including its
    /// strictness — this is the only remote-reachable surface that can spawn a
    /// process, so an under-specified frame throws rather than being defaulted.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        let type = try container.decode(String.self, forKey: .type)

        // `id` is trimmed and must be non-empty. The gateway rejects a blank
        // one instead of answering, which would leave the caller hanging.
        let rawID = try container.decode(String.self, forKey: .id)
        let trimmedID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .id, in: container,
                debugDescription: "id must be a non-empty string")
        }
        let id = RequestID(trimmedID)

        func idempotencyKey() throws -> IdempotencyKey {
            let raw = try container.decode(String.self, forKey: .idempotencyKey)
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .idempotencyKey, in: container,
                    debugDescription: "idempotency_key must be a non-empty string")
            }
            return IdempotencyKey(trimmed)
        }
        func trimmed(_ key: Key) throws -> String? {
            guard let raw = try container.decodeIfPresent(String.self, forKey: key) else {
                return nil
            }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }

        switch type {
        case "workspace_list":
            self = .workspaceList(id: id)
        case "session_list":
            self = .sessionList(
                id: id, workspace: try trimmed(.workspaceID).map { WorkspaceID($0) })
        case "create_session":
            // An explicit `background: false` is REFUSED, not coerced: v1 only
            // spawns background sessions, and quietly handing back something
            // else would leave a client believing it had an interactive one.
            if let background = try container.decodeIfPresent(Bool.self, forKey: .background),
                background != true
            {
                throw DecodingError.dataCorruptedError(
                    forKey: .background, in: container,
                    debugDescription: "only background sessions can be created remotely")
            }
            guard let workspace = try trimmed(.workspaceID) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .workspaceID, in: container,
                    debugDescription: "workspace_id must be a non-empty string")
            }
            self = .createSession(
                id: id,
                idempotencyKey: try idempotencyKey(),
                workspace: WorkspaceID(workspace),
                displayName: try trimmed(.displayName)
            )
        case "session_start", "session_stop":
            guard let session = try trimmed(.sessionID) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .sessionID, in: container,
                    debugDescription: "session_id must be a non-empty string")
            }
            let key = try idempotencyKey()
            self =
                type == "session_start"
                ? .sessionStart(id: id, session: SessionID(session), idempotencyKey: key)
                : .sessionStop(id: id, session: SessionID(session), idempotencyKey: key)
        case "session_rename":
            guard let session = try trimmed(.sessionID),
                let displayName = try trimmed(.displayName)
            else {
                throw DecodingError.dataCorruptedError(
                    forKey: .displayName, in: container,
                    debugDescription: "session_rename needs session_id and display_name")
            }
            self = .sessionRename(
                id: id,
                session: SessionID(session),
                displayName: displayName,
                rev: try container.decodeIfPresent(Int64.self, forKey: .rev)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "not a control action: \(type)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        // Delegating to `jsonObject` keeps exactly one definition of the
        // outbound shape. Duplicating it here is how the `background: true`
        // constant or the omit-vs-empty-string rules drift apart.
        var container = encoder.container(keyedBy: Key.self)
        let object = jsonObject
        try container.encode(name, forKey: .type)
        try container.encode(id.rawValue, forKey: .id)
        if let value = object["workspace_id"] as? String {
            try container.encode(value, forKey: .workspaceID)
        }
        if let value = object["session_id"] as? String {
            try container.encode(value, forKey: .sessionID)
        }
        if let value = object["idempotency_key"] as? String {
            try container.encode(value, forKey: .idempotencyKey)
        }
        if let value = object["display_name"] as? String {
            try container.encode(value, forKey: .displayName)
        }
        if let value = object["background"] as? Bool {
            try container.encode(value, forKey: .background)
        }
        if let value = object["rev"] as? Int64 {
            try container.encode(value, forKey: .rev)
        }
    }
}
