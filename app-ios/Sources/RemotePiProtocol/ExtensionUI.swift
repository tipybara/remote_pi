import Foundation

// MARK: - Method

/// Which UI the Pi is asking for.
///
/// The bridge only ever produces `select`, `input` and `notify` today
/// (`extension_ui_bridge.ts:303-338` plus three `notify` broadcasts).
/// `confirm` and `editor` are declared for the generic SDK contract; implement
/// them, expect never to see one.
public struct ExtensionUIMethod: WireStringValue {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let select = ExtensionUIMethod(rawValue: "select")
    public static let confirm = ExtensionUIMethod(rawValue: "confirm")
    public static let input = ExtensionUIMethod(rawValue: "input")
    public static let editor = ExtensionUIMethod(rawValue: "editor")
    /// Fire-and-forget. **Never answer a `notify` with an
    /// ``ExtensionUIResponse``** — no flow matches it, so the bridge drops the
    /// reply; it is simply noise on the wire.
    public static let notify = ExtensionUIMethod(rawValue: "notify")

    public static let allKnown: Set<ExtensionUIMethod> = [
        .select, .confirm, .input, .editor, .notify,
    ]

    public var isKnown: Bool { Self.allKnown.contains(self) }
}

/// `notify_type`. Present only on `notify`.
public struct ExtensionUINotifyType: WireStringValue {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let info = ExtensionUINotifyType(rawValue: "info")
    /// A submit was rejected, or the bridge's 10-minute flow TTL expired.
    /// **Keep the modal open** and show a retry hint.
    public static let warning = ExtensionUINotifyType(rawValue: "warning")
    public static let error = ExtensionUINotifyType(rawValue: "error")
}

/// Shape of one pi-ask question.
public struct AskQuestionType: WireStringValue {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let single = AskQuestionType(rawValue: "single")
    public static let multi = AskQuestionType(rawValue: "multi")
    /// Options carry a preview pane.
    public static let preview = AskQuestionType(rawValue: "preview")
}

// MARK: - Ask enrichment (inbound)

/// One selectable option inside an ``AskQuestion``.
///
/// ``value`` is what a rich answer submits; ``label`` is what the flat
/// `options: [String]` array on the request carries and what a *degraded*
/// answer must send back. Confusing the two is silent: send a `value` where a
/// label was expected and the bridge finds no matching option, so the answer
/// lands as free-form `customText` instead of a selection.
public struct AskOption: Hashable, Sendable, Codable {
    public var value: String
    public var label: String
    public var description: String?
    /// Content for the preview pane, on `preview` questions.
    public var preview: String?
    /// The option accepts a free-form entry alongside the choice.
    public var freeform: Bool

    public init(
        value: String,
        label: String,
        description: String? = nil,
        preview: String? = nil,
        freeform: Bool = false
    ) {
        self.value = value
        self.label = label
        self.description = description
        self.preview = preview
        self.freeform = freeform
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Each falls back to the other: pi-ask flows built by hand sometimes
        // carry only one, and rendering an option with an empty caption is
        // worse than rendering its value.
        let rawValue = try container.decodeIfPresent(String.self, forKey: .value)
        let rawLabel = try container.decodeIfPresent(String.self, forKey: .label)
        value = rawValue ?? rawLabel ?? ""
        label = rawLabel ?? value
        description = try container.decodeIfPresent(String.self, forKey: .description)
        preview = try container.decodeIfPresent(String.self, forKey: .preview)
        freeform = try container.decodeIfPresent(Bool.self, forKey: .freeform) ?? false
    }
}

/// One question of a pi-ask flow.
///
/// Note the casing: `presentedType` and `requestedType` are **camelCase on the
/// wire**, unlike every frame-level key. Inside the `ask` envelope the schema
/// mirrors pi-ask verbatim so the bridge can forward it without a remap.
public struct AskQuestion: Hashable, Sendable, Codable {
    public var id: String
    public var label: String
    public var prompt: String
    public var type: AskQuestionType
    public var required: Bool
    /// The type actually presented after a live toggle or policy. When this
    /// says `multi`, render multi **even if** ``type`` says `single`.
    public var presentedType: AskQuestionType?
    /// The type the model originally asked for.
    public var requestedType: AskQuestionType?
    /// May be **empty** — a pure-text question. The bridge degrades such a
    /// request to `method: "input"`.
    public var options: [AskOption]

    public init(
        id: String,
        label: String,
        prompt: String,
        type: AskQuestionType = .single,
        required: Bool = false,
        presentedType: AskQuestionType? = nil,
        requestedType: AskQuestionType? = nil,
        options: [AskOption] = []
    ) {
        self.id = id
        self.label = label
        self.prompt = prompt
        self.type = type
        self.required = required
        self.presentedType = presentedType
        self.requestedType = requestedType
        self.options = options
    }

    /// Whether the UI should let the user pick more than one option.
    public var allowsMultipleSelection: Bool {
        type == .multi || presentedType == .multi
    }

    public enum CodingKeys: String, CodingKey {
        case id, label, prompt, type, required, options
        // Deliberately NOT snake_case. See the type doc.
        case presentedType
        case requestedType
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? prompt
        type = try container.decodeIfPresent(AskQuestionType.self, forKey: .type) ?? .single
        required = try container.decodeIfPresent(Bool.self, forKey: .required) ?? false
        presentedType = try container.decodeIfPresent(
            AskQuestionType.self, forKey: .presentedType)
        requestedType = try container.decodeIfPresent(
            AskQuestionType.self, forKey: .requestedType)
        options = try container.decodeIfPresent([AskOption].self, forKey: .options) ?? []
    }
}

/// The optional pi-ask envelope on an ``ExtensionUIRequest``.
///
/// One flow maps to **one** request carrying every question, and the client
/// submits **one** response with every answer — pi-ask resolves a flow in a
/// single submit.
public struct AskEnrichment: Hashable, Sendable, Codable {
    public var flowID: String
    /// `string | null` on the wire — one of only two inner fields that ever
    /// arrives as an explicit `null` (`types.ts:66`,
    /// `extension_ui_bridge.ts:309`). `nil` here covers both spellings, which
    /// is correct: nothing distinguishes them semantically.
    public var toolCallID: String?
    /// `"tool" | "answer" | "answer:again" | "ask:replay"` observed. Open.
    public var source: String
    /// The other `string | null` field.
    public var title: String?
    public var questions: [AskQuestion]

    public init(
        flowID: String,
        toolCallID: String? = nil,
        source: String = "tool",
        title: String? = nil,
        questions: [AskQuestion] = []
    ) {
        self.flowID = flowID
        self.toolCallID = toolCallID
        self.source = source
        self.title = title
        self.questions = questions
    }

    public enum CodingKeys: String, CodingKey {
        case source, title, questions
        case flowID = "flow_id"
        case toolCallID = "tool_call_id"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        flowID = try container.decodeIfPresent(String.self, forKey: .flowID) ?? ""
        toolCallID = try container.decodeIfPresent(String.self, forKey: .toolCallID)
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? "tool"
        title = try container.decodeIfPresent(String.self, forKey: .title)
        questions = try container.decodeIfPresent([AskQuestion].self, forKey: .questions) ?? []
    }
}

// MARK: - Request

/// `extension_ui_request` — the Pi asking the user something (plan 57).
///
/// ## `id` is the flow id
///
/// The bridge reuses the pi-ask flow id as the frame id
/// (`extension_ui_bridge.ts:318-334`), and that is precisely what makes the
/// degraded response path — a client that ignores `ask` and replies with a bare
/// `value` — routable back to the right flow.
///
/// ## What `notify` means
///
/// | shape | meaning |
/// |---|---|
/// | id matches an open request, no `notifyType`, message `"Clarification resolved."` | the flow finished elsewhere → **dismiss the modal** |
/// | id matches an open request, `notifyType == .warning` | submit rejected, or the bridge's 10-minute TTL expired → **keep the modal open**, offer a retry |
/// | id matches nothing | ignore |
public struct ExtensionUIRequest: Hashable, Sendable, Codable {
    /// The pi-ask flow id.
    public var id: String
    public var method: ExtensionUIMethod
    public var title: String?
    /// `confirm` body, and the `notify` text.
    public var message: String?
    /// `input` hint.
    public var placeholder: String?
    /// `editor` seed text.
    public var prefill: String?
    /// `select` choices — **labels, not values**. The values live in
    /// `ask.questions[].options[].value`.
    public var options: [String]
    public var notifyType: ExtensionUINotifyType?
    /// Present when the prompt came from a pi-ask flow. When it is here,
    /// render from ``AskEnrichment/questions`` rather than from ``options``.
    public var ask: AskEnrichment?

    public init(
        id: String,
        method: ExtensionUIMethod,
        title: String? = nil,
        message: String? = nil,
        placeholder: String? = nil,
        prefill: String? = nil,
        options: [String] = [],
        notifyType: ExtensionUINotifyType? = nil,
        ask: AskEnrichment? = nil
    ) {
        self.id = id
        self.method = method
        self.title = title
        self.message = message
        self.placeholder = placeholder
        self.prefill = prefill
        self.options = options
        self.notifyType = notifyType
        self.ask = ask
    }

    public enum CodingKeys: String, CodingKey {
        case id, method, title, message, placeholder, prefill, options, ask
        case notifyType = "notify_type"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        // The raw method is preserved even when unrecognised; the "render it as
        // a select" fallback lives in ``renderableMethod``, so a newer Pi's
        // method survives a round-trip instead of being rewritten to `select`
        // on the way back out.
        method = try container.decodeIfPresent(ExtensionUIMethod.self, forKey: .method) ?? .select
        title = try container.decodeIfPresent(String.self, forKey: .title)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        placeholder = try container.decodeIfPresent(String.self, forKey: .placeholder)
        prefill = try container.decodeIfPresent(String.self, forKey: .prefill)
        // `options` is declared `string[]`, but the Dart parser coerces every
        // element with `.toString()`. Mirror that leniency: a single non-string
        // element must not cost the user the whole prompt.
        options = (try container.decodeIfPresent([AnyJSON].self, forKey: .options) ?? [])
            .compactMap { element in
                switch element {
                case .string(let value): return value
                case .int(let value): return String(value)
                case .double(let value): return String(value)
                case .bool(let value): return String(value)
                default: return nil
                }
            }
        notifyType = try container.decodeIfPresent(
            ExtensionUINotifyType.self, forKey: .notifyType)
        ask = try container.decodeIfPresent(AskEnrichment.self, forKey: .ask)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(method, forKey: .method)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(message, forKey: .message)
        try container.encodeIfPresent(placeholder, forKey: .placeholder)
        try container.encodeIfPresent(prefill, forKey: .prefill)
        if !options.isEmpty { try container.encode(options, forKey: .options) }
        try container.encodeIfPresent(notifyType, forKey: .notifyType)
        try container.encodeIfPresent(ask, forKey: .ask)
    }

    /// What the UI should actually render.
    ///
    /// An unrecognised method degrades to ``ExtensionUIMethod/select`` rather
    /// than being dropped, which is what the Flutter client does
    /// (`protocol.dart:1911`): a modal with the wrong affordance is
    /// recoverable, while a dropped ask leaves the Pi blocked until the
    /// bridge's 10-minute TTL expires. ``method`` keeps the wire value.
    public var renderableMethod: ExtensionUIMethod {
        method.isKnown ? method : .select
    }

    /// `true` when this frame dismisses an open modal rather than opening one.
    ///
    /// A `notify` with no ``notifyType`` is the "the flow was resolved
    /// somewhere else" signal; a `warning` is the "your submit bounced, try
    /// again" signal and must **not** dismiss.
    public var isDismissNotify: Bool {
        method == .notify && notifyType == nil
    }
}

// MARK: - Response

/// One question's answered parts, in pi-ask's own schema.
///
/// Every key here is **camelCase** — the envelope mirrors pi-ask verbatim so
/// the bridge can forward it to the submit event without a remap pass.
///
/// ## Omit-empty is a contract, not a style choice
///
/// `values`, `customText`, `note` and `optionNotes` are each dropped when
/// empty, so an answer with nothing in it serializes to `{}`. pi-ask reads
/// presence, and an explicit `"customText": ""` is a *typed empty answer*
/// rather than an unanswered question.
public struct AskAnswer: Hashable, Sendable, Codable {
    public var values: [String]
    public var customText: String?
    public var note: String?
    public var optionNotes: [String: String]

    public init(
        values: [String] = [],
        customText: String? = nil,
        note: String? = nil,
        optionNotes: [String: String] = [:]
    ) {
        self.values = values
        self.customText = customText
        self.note = note
        self.optionNotes = optionNotes
    }

    /// `true` when this answer carries nothing. The Flutter sheet skips such
    /// questions entirely rather than submitting `{}`.
    public var isEmpty: Bool {
        values.isEmpty && (customText?.isEmpty ?? true) && (note?.isEmpty ?? true)
            && optionNotes.isEmpty
    }

    public enum CodingKeys: String, CodingKey {
        case values, customText, note, optionNotes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        values = try container.decodeIfPresent([String].self, forKey: .values) ?? []
        customText = try container.decodeIfPresent(String.self, forKey: .customText)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        optionNotes =
            try container.decodeIfPresent([String: String].self, forKey: .optionNotes) ?? [:]
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if !values.isEmpty { try container.encode(values, forKey: .values) }
        if let customText, !customText.isEmpty {
            try container.encode(customText, forKey: .customText)
        }
        if let note, !note.isEmpty { try container.encode(note, forKey: .note) }
        if !optionNotes.isEmpty { try container.encode(optionNotes, forKey: .optionNotes) }
    }
}

/// The `ask` envelope on an ``ExtensionUIResponse``.
///
/// The bridge routes on ``kind`` **before** it reads any of
/// `value`/`confirmed`/`cancelled` (`extension_ui_bridge.ts:209-234`), which is
/// why a rich submit may — and does — send the envelope alone.
public enum AskResponse: Hashable, Sendable, Codable {
    /// A structured answer. `mode` is `"submit"` or `"elaborate"`; kept as a
    /// raw `String?` for forward compatibility, and omitted when `nil`.
    case answer(flowID: String, mode: String?, answers: [String: AskAnswer])
    case cancel(flowID: String)

    public var flowID: String {
        switch self {
        case .answer(let flowID, _, _), .cancel(let flowID): return flowID
        }
    }

    public enum CodingKeys: String, CodingKey {
        case kind, mode, answers
        case flowID = "flow_id"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let flowID = try container.decodeIfPresent(String.self, forKey: .flowID) ?? ""
        if try container.decodeIfPresent(String.self, forKey: .kind) == "cancel" {
            self = .cancel(flowID: flowID)
        } else {
            self = .answer(
                flowID: flowID,
                mode: try container.decodeIfPresent(String.self, forKey: .mode),
                answers: try container.decodeIfPresent(
                    [String: AskAnswer].self, forKey: .answers) ?? [:]
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .cancel(let flowID):
            // A cancel carries flow_id and kind only — no `answers: {}`, which
            // the bridge would otherwise route down the answer path.
            try container.encode(flowID, forKey: .flowID)
            try container.encode("cancel", forKey: .kind)
        case .answer(let flowID, let mode, let answers):
            try container.encode(flowID, forKey: .flowID)
            try container.encode("answer", forKey: .kind)
            try container.encodeIfPresent(mode, forKey: .mode)
            try container.encode(answers, forKey: .answers)
        }
    }
}

/// `extension_ui_response` — the user's answer.
///
/// Four legal shapes, distinguished by which optional fields are present:
///
/// ```jsonc
/// {"type":"extension_ui_response","id":"<flow>","value":"Rewrite"}     // degraded select
/// {"type":"extension_ui_response","id":"<flow>","confirmed":true}      // confirm
/// {"type":"extension_ui_response","id":"<flow>","cancelled":true}      // cancel
/// {"type":"extension_ui_response","id":"<flow>","ask":{…}}             // rich submit
/// ```
///
/// **A rich submit sends the envelope alone** — no `value`, no `confirmed`, no
/// `cancelled` (`types.ts:164-173`).
///
/// There is **no reply**. The Pi routes the frame to the bridge and returns
/// (`index.ts:4020-4023`); confirmation arrives later as a `notify`. Arm a
/// ~25 s backstop, as the Flutter sheet does, or a lost frame leaves the modal
/// up forever.
public struct ExtensionUIResponse: Hashable, Sendable, Codable {
    /// The **flow id** — the `id` of the request being answered, not a fresh
    /// request id. Nothing correlates a reply to this frame.
    public var id: String
    /// The degraded-path answer: the option's **label**, not its value.
    public var value: String?
    public var confirmed: Bool?
    public var cancelled: Bool
    public var ask: AskResponse?

    public init(
        id: String,
        value: String? = nil,
        confirmed: Bool? = nil,
        cancelled: Bool = false,
        ask: AskResponse? = nil
    ) {
        self.id = id
        self.value = value
        self.confirmed = confirmed
        self.cancelled = cancelled
        self.ask = ask
    }

    /// The rich submit: envelope only.
    public static func submit(
        flowID: String,
        answers: [String: AskAnswer],
        mode: String? = "submit"
    ) -> ExtensionUIResponse {
        ExtensionUIResponse(
            id: flowID, ask: .answer(flowID: flowID, mode: mode, answers: answers))
    }

    /// A cancel. Sends **both** discriminators, matching the Flutter sheet: the
    /// bridge accepts either the flat `cancelled` or `ask.kind == "cancel"`,
    /// and sending both means the cancel still routes if the envelope is
    /// dropped by a middlebox that only understands the flat shape.
    public static func cancel(flowID: String) -> ExtensionUIResponse {
        ExtensionUIResponse(id: flowID, cancelled: true, ask: .cancel(flowID: flowID))
    }

    public enum CodingKeys: String, CodingKey {
        case id, value, confirmed, cancelled, ask
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        value = try container.decodeIfPresent(String.self, forKey: .value)
        confirmed = try container.decodeIfPresent(Bool.self, forKey: .confirmed)
        cancelled = try container.decodeIfPresent(Bool.self, forKey: .cancelled) ?? false
        ask = try container.decodeIfPresent(AskResponse.self, forKey: .ask)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        // `cancelled: false` is never written. The wire type is the literal
        // `true`, and a client that sends `false` is asserting a discriminator
        // it does not mean.
        if cancelled { try container.encode(true, forKey: .cancelled) }
        try container.encodeIfPresent(value, forKey: .value)
        try container.encodeIfPresent(confirmed, forKey: .confirmed)
        try container.encodeIfPresent(ask, forKey: .ask)
    }
}
