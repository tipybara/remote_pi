import Foundation
import RemotePiProtocol

/// The user's in-progress answers to one `extension_ui_request`, and the rules
/// that turn them into an `extension_ui_response` (spec 08 §8.13).
///
/// A plain value type: no `@Observable`, no service, no clock. Every rule the
/// spec flags as a trap — custom text beating a selection, empty answers being
/// omitted, `presentedType` overriding `type` — is a pure function of this
/// struct, which is what makes them testable one at a time.
struct AskForm: Equatable, Sendable {
    /// The request being answered. Held whole so ``response()`` can address
    /// the reply with the request's own `id`.
    let request: ExtensionUIRequest

    // MARK: Rich (pi-ask) state

    /// question id → chosen option **values** (not labels — §Kit `AskOption`).
    private(set) var selections: [String: Set<String>] = [:]
    /// question id → free-text entry ("Type your own…").
    var customText: [String: String] = [:]

    // MARK: Degraded (plain SDK) state

    /// The chosen option for a degraded `select`. This one **is** a label:
    /// `request.options` carries labels, and the bridge maps the label back to
    /// a value through its per-request table. Sending a value here lands the
    /// answer as free-form text instead of a selection, silently.
    var singleValue: String?
    /// The text for a degraded `input` / `editor`.
    var text: String = ""

    init(request: ExtensionUIRequest) {
        self.request = request
        // `prefill` is documented as the editor's seed text but the Flutter
        // sheet never reads it, so a Pi-supplied draft is dropped there. Seed
        // it here: losing the agent's starting text is a real (if quiet) data
        // loss, and nothing in §8.13 asks for it to be discarded.
        if let prefill = request.prefill,
           request.renderableMethod == .editor || request.renderableMethod == .input {
            text = prefill
        }
    }

    // MARK: - Shape

    var ask: AskEnrichment? { request.ask }

    /// Rich when the pi-ask enrichment is present, degraded otherwise
    /// (§8.13 "Two rendering modes").
    var isRich: Bool { request.ask != nil }

    var questions: [AskQuestion] { request.ask?.questions ?? [] }

    /// What the modal renders. Unknown methods degrade to `select` rather than
    /// being dropped — see `ExtensionUIRequest.renderableMethod`.
    var method: ExtensionUIMethod { request.renderableMethod }

    var title: String {
        if let title = request.title, !title.isEmpty { return title }
        if let askTitle = request.ask?.title, !askTitle.isEmpty { return askTitle }
        return "Clarification needed"
    }

    /// The degraded body's lead paragraph.
    var degradedMessage: String {
        request.message ?? request.title ?? ""
    }

    /// Multi-select when **either** `type` or `presentedType` says so
    /// (§8.13, `:101-103`). `presentedType` is what the flow actually
    /// presented after a live toggle, so honouring only `type` shows radio
    /// buttons for a question the user is allowed to answer with several.
    func isMulti(_ question: AskQuestion) -> Bool {
        question.allowsMultipleSelection
    }

    func isSelected(_ question: AskQuestion, value: String) -> Bool {
        selections[question.id]?.contains(value) ?? false
    }

    func custom(for question: AskQuestion) -> String {
        customText[question.id] ?? ""
    }

    // MARK: - Mutation

    mutating func toggle(_ question: AskQuestion, value: String) {
        var chosen = selections[question.id] ?? []
        if isMulti(question) {
            if chosen.contains(value) {
                chosen.remove(value)
            } else {
                chosen.insert(value)
            }
        } else {
            // Single-select replaces rather than accumulates. Re-tapping the
            // chosen option keeps it chosen — pi-ask has no "no answer" value
            // and deselecting would look like a broken radio.
            chosen = [value]
        }
        selections[question.id] = chosen
    }

    mutating func setCustom(_ value: String, for question: AskQuestion) {
        customText[question.id] = value
    }

    // MARK: - Submit enablement (§8.13 `_canSubmit`)

    var canSubmit: Bool {
        if isRich {
            // Rich: **any** question answered is enough. `required` on a
            // pi-ask question is advisory and never blocks submission
            // (`:279-286`) — enforcing it here would deadlock a flow whose
            // required question the user genuinely cannot answer.
            return questions.contains { question in
                !(selections[question.id]?.isEmpty ?? true)
                    || !custom(for: question).trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty
            }
        }
        switch method {
        case .select:
            return singleValue != nil
        case .input, .editor:
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .confirm:
            return true
        default:
            // `notify` never opens this modal (the inbox consumes it), so this
            // is defensive. Answering a notify is noise on the wire: no flow
            // matches it and the bridge drops the reply.
            return false
        }
    }

    // MARK: - Response construction (§8.13 `_buildResponse`)

    func response() -> ExtensionUIResponse {
        if let ask {
            var answers: [String: AskAnswer] = [:]
            for question in questions {
                if let answer = answer(for: question) {
                    answers[question.id] = answer
                }
            }
            // A rich submit sends the envelope **alone** — no `value`, no
            // `confirmed`, no `cancelled`. The bridge routes on `ask.kind`
            // before it reads any of them.
            return ExtensionUIResponse(
                id: request.id,
                ask: .answer(flowID: ask.flowID, mode: "submit", answers: answers)
            )
        }
        switch method {
        case .select:
            return ExtensionUIResponse(id: request.id, value: singleValue ?? "")
        case .input, .editor:
            // Deliberately NOT trimmed: `canSubmit` trims to decide whether
            // there is an answer, but the answer itself is the user's text.
            // Trailing newlines in an editor answer are content.
            return ExtensionUIResponse(id: request.id, value: text)
        case .confirm:
            return ExtensionUIResponse(id: request.id, confirmed: true)
        default:
            return cancelResponse()
        }
    }

    /// One question's answer, or `nil` when it carries nothing.
    ///
    /// Questions with neither a selection nor custom text are **omitted from
    /// `answers` entirely** rather than submitted as `{}`: pi-ask reads
    /// presence, so an empty answer object is a *typed empty answer* and not
    /// an unanswered question.
    private func answer(for question: AskQuestion) -> AskAnswer? {
        let custom = custom(for: question).trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = orderedSelection(for: question)
        let multi = isMulti(question)

        // pi-ask forbids combining a selected value with custom text on a
        // non-multi question, so custom text wins (§8.13, `:170`).
        let values = multi ? chosen : (custom.isEmpty ? chosen : [])
        let customValue = custom.isEmpty ? nil : custom
        if values.isEmpty && customValue == nil { return nil }
        return AskAnswer(values: values, customText: customValue)
    }

    /// Selected values in the order their options are declared.
    ///
    /// The Dart sheet stores selections in a `Set` and submits
    /// `set.toList()`, so a multi-select answer's order is whatever the hash
    /// seed produced that launch. Not reproducing that: pi-ask echoes the
    /// order back into the prompt, and a non-deterministic answer is a
    /// non-reproducible run.
    private func orderedSelection(for question: AskQuestion) -> [String] {
        guard let chosen = selections[question.id], !chosen.isEmpty else { return [] }
        var ordered = question.options.map(\.value).filter { chosen.contains($0) }
        // Anything selected that is not in `options` (a value the flow added
        // after the question was rendered) still ships, sorted so it is at
        // least deterministic.
        let known = Set(question.options.map(\.value))
        ordered.append(contentsOf: chosen.subtracting(known).sorted())
        return ordered
    }

    /// A cancel.
    ///
    /// For a rich request both discriminators go out — the flat `cancelled`
    /// and `ask.kind == "cancel"` — so the cancel still routes if a middlebox
    /// understands only the flat shape. A degraded request has no flow
    /// envelope to send, matching the Flutter sheet (`:144-153`).
    func cancelResponse() -> ExtensionUIResponse {
        if let ask {
            return ExtensionUIResponse(
                id: request.id, cancelled: true, ask: .cancel(flowID: ask.flowID))
        }
        return ExtensionUIResponse(id: request.id, cancelled: true)
    }
}
