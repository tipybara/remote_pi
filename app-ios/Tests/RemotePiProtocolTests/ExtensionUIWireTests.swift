import Foundation
import XCTest

@testable import RemotePiProtocol

/// The plan-57 `ask_user` bridge, pinned against
/// `pi-extension/src/extension_ui_bridge.test.ts` (which asserts on the exact
/// objects the bridge emits and accepts) and spec 01 §6.
final class ExtensionUIWireTests: XCTestCase {

    private func decode(_ line: String) throws -> ExtensionUIRequest {
        let message = try XCTUnwrap(ServerMessage.decodeLossy(line))
        guard case .extensionUIRequest(let payload) = message else {
            throw XCTSkip("not an extension_ui_request: \(message.typeName)")
        }
        return payload
    }

    // MARK: - inbound request

    /// The `select` request the bridge builds from a one-question pi-ask flow.
    ///
    /// Pinned to `extension_ui_bridge.test.ts` → "translates a pi-ask `started`
    /// event into one extension_ui_request", which asserts
    /// `id == "tool:tc_1"`, `options == ["Alpha", "Beta"]`,
    /// `ask.questions[0].options.map(o => o.value) == ["a", "b"]` and that the
    /// second option's `description` survives.
    func testSelectRequestWithAskEnvelope() throws {
        let request = try decode(
            #"""
            {"type":"extension_ui_request","id":"tool:tc_1","method":"select",
             "title":"Direction","options":["Alpha","Beta"],
             "ask":{"flow_id":"tool:tc_1","tool_call_id":"tc_1","source":"tool",
                    "title":"Direction",
                    "questions":[{"id":"goal","label":"Direction","prompt":"Which way?",
                                  "type":"single","required":true,
                                  "options":[{"value":"a","label":"Alpha"},
                                             {"value":"b","label":"Beta",
                                              "description":"second choice"}]}]}}
            """#)

        XCTAssertEqual(request.id, "tool:tc_1", "the frame id IS the pi-ask flow id")
        XCTAssertEqual(request.method, .select)
        XCTAssertEqual(request.options, ["Alpha", "Beta"])

        let ask = try XCTUnwrap(request.ask)
        XCTAssertEqual(ask.flowID, "tool:tc_1")
        XCTAssertEqual(ask.toolCallID, "tc_1")
        XCTAssertEqual(ask.source, "tool")
        XCTAssertEqual(ask.questions.count, 1)
        XCTAssertEqual(ask.questions[0].options.map(\.value), ["a", "b"])
        XCTAssertEqual(ask.questions[0].options[1].description, "second choice")

        // Trap T6: the flat array carries LABELS, the envelope carries VALUES.
        // Sending a value where a label is expected silently becomes a
        // free-form `customText` answer instead of a selection.
        XCTAssertEqual(request.options, ask.questions[0].options.map(\.label))
    }

    /// **Trap T7.** `presentedType` / `requestedType` are camelCase *on
    /// purpose* — inside `ask` the schema mirrors pi-ask verbatim while
    /// frame-level keys stay snake_case. A blanket `.convertFromSnakeCase`
    /// decoding strategy nulls both out, and a `multi` question then renders as
    /// a single-select that can only ever submit one answer.
    func testCamelCaseAskKeysSurvive() throws {
        let request = try decode(
            #"""
            {"type":"extension_ui_request","id":"f1","method":"select","title":"t",
             "options":["A"],
             "ask":{"flow_id":"f1","tool_call_id":null,"source":"tool","title":null,
                    "questions":[{"id":"q1","label":"L","prompt":"P","type":"single",
                                  "required":true,"presentedType":"multi",
                                  "requestedType":"multi","options":[]}]}}
            """#)
        let question = try XCTUnwrap(request.ask?.questions.first)
        XCTAssertEqual(question.presentedType, .multi)
        XCTAssertEqual(question.requestedType, .multi)
        XCTAssertTrue(
            question.allowsMultipleSelection,
            "presentedType overrides type when deciding the affordance")
    }

    /// `tool_call_id` and `title` are the **only** inner fields that arrive as
    /// an explicit JSON `null` (`types.ts:66,69`). A decoder that treats `null`
    /// as a type error loses the whole prompt.
    func testExplicitNullsInsideAskDecodeAsAbsent() throws {
        let request = try decode(
            #"""
            {"type":"extension_ui_request","id":"f1","method":"input","title":"t",
             "ask":{"flow_id":"f1","tool_call_id":null,"source":"answer:again",
                    "title":null,"questions":[]}}
            """#)
        let ask = try XCTUnwrap(request.ask)
        XCTAssertNil(ask.toolCallID)
        XCTAssertNil(ask.title)
        XCTAssertEqual(ask.source, "answer:again")
    }

    /// Pinned to `extension_ui_bridge.test.ts` → "broadcasts a warning notify
    /// on a submit-result error", which asserts the frame is
    /// `{type, id: flowId, method: "notify", notify_type: "warning", message}`.
    ///
    /// The `warning` is what distinguishes "your submit bounced, retry" from
    /// the `completed` dismiss — and the two must not be conflated, or a
    /// rejected answer silently closes the modal.
    func testWarningNotifyKeepsTheModalOpen() throws {
        let request = try decode(
            #"""
            {"type":"extension_ui_request","id":"tool:tc_1","method":"notify",
             "notify_type":"warning","message":"Unknown option value."}
            """#)
        XCTAssertEqual(request.method, .notify)
        XCTAssertEqual(request.notifyType, .warning)
        XCTAssertFalse(request.isDismissNotify)
    }

    /// The `completed` broadcast: same shape, **no** `notify_type`.
    func testPlainNotifyDismissesTheModal() throws {
        let request = try decode(
            #"""
            {"type":"extension_ui_request","id":"tool:tc_1","method":"notify",
             "message":"Clarification resolved."}
            """#)
        XCTAssertTrue(request.isDismissNotify)
        XCTAssertNil(request.notifyType)
    }

    /// Pinned to `extension_ui_bridge.test.ts` → "maps a label-only response
    /// back to the option value (degraded client)": a question with **no**
    /// options degrades to `method: "input"` with the prompt as placeholder.
    func testOptionlessQuestionDegradesToInput() throws {
        let request = try decode(
            #"""
            {"type":"extension_ui_request","id":"y","method":"input",
             "placeholder":"Describe the goal",
             "ask":{"flow_id":"y","tool_call_id":null,"source":"tool","title":null,
                    "questions":[{"id":"q","label":"Describe the goal",
                                  "prompt":"Describe the goal","type":"single",
                                  "required":false,"options":[]}]}}
            """#)
        XCTAssertEqual(request.method, .input)
        XCTAssertEqual(request.placeholder, "Describe the goal")
        XCTAssertTrue(try XCTUnwrap(request.ask).questions[0].options.isEmpty)
    }

    /// An unknown `method` renders as `select` rather than being dropped
    /// (`protocol.dart:1911`): a modal with the wrong affordance is
    /// recoverable, a dropped ask blocks the Pi until its 10-minute TTL.
    /// The raw value still survives, so the frame round-trips unchanged.
    func testUnknownMethodRendersAsSelectButKeepsItsWireValue() throws {
        let line = #"{"type":"extension_ui_request","id":"f1","method":"hologram","title":"t"}"#
        let request = try decode(line)
        XCTAssertEqual(request.renderableMethod, .select)
        XCTAssertEqual(request.method.rawValue, "hologram")
        XCTAssertFalse(request.method.isKnown)
        try WireFixtures.assertEncodes(ServerMessage.extensionUIRequest(request), to: line)
    }

    // MARK: - outbound response

    /// The **bare rich answer** — envelope only, no `value`/`confirmed`/
    /// `cancelled`. Pinned to `extension_ui_bridge.test.ts` → "forwards a BARE
    /// rich answer (no value/confirmed/cancelled) to pi-ask", which submits
    /// exactly `{flow_id, kind:"answer", mode:"submit", answers:{goal:{values:["a"]}}}`.
    func testRichSubmitSendsTheEnvelopeAlone() throws {
        let response = ClientMessage.extensionUIResponse(
            .submit(flowID: "tool:tc_1", answers: ["goal": AskAnswer(values: ["a"])]))
        try WireFixtures.assertEncodes(
            response,
            to: #"""
                {"type":"extension_ui_response","id":"tool:tc_1",
                 "ask":{"flow_id":"tool:tc_1","kind":"answer","mode":"submit",
                        "answers":{"goal":{"values":["a"]}}}}
                """#)

        let encoded = try WireFixtures.encoded(response)
        XCTAssertNil(encoded["value"])
        XCTAssertNil(encoded["confirmed"])
        XCTAssertNil(
            encoded["cancelled"],
            "`cancelled: false` is not a legal value — the wire type is the literal true")
    }

    /// Pinned to `extension_ui_bridge.test.ts` → "forwards a cancel as
    /// { kind: 'cancel' }". The Flutter sheet sends both discriminators; the
    /// bridge accepts either.
    func testCancelSendsBothDiscriminators() throws {
        try WireFixtures.assertEncodes(
            ClientMessage.extensionUIResponse(.cancel(flowID: "tool:tc_1")),
            to: #"""
                {"type":"extension_ui_response","id":"tool:tc_1","cancelled":true,
                 "ask":{"flow_id":"tool:tc_1","kind":"cancel"}}
                """#)
    }

    /// A cancel envelope must not carry `answers` — the bridge routes on
    /// `ask.kind` first, but an `answers` key on a cancel is a shape neither
    /// side declares.
    func testCancelEnvelopeCarriesNoAnswers() throws {
        let encoded = try WireFixtures.encoded(
            ClientMessage.extensionUIResponse(.cancel(flowID: "f1")))
        let ask = try XCTUnwrap(encoded["ask"] as? [String: Any])
        XCTAssertNil(ask["answers"])
        XCTAssertNil(ask["mode"])
    }

    /// The degraded path: `value` carries the option's **label**, which the
    /// bridge maps back to a value (`extension_ui_bridge.ts:246`). Pinned to
    /// "maps a label-only response back to the option value (degraded client)".
    func testDegradedResponseSendsTheLabel() throws {
        try WireFixtures.assertEncodes(
            ClientMessage.extensionUIResponse(ExtensionUIResponse(id: "y", value: "ship it")),
            to: #"{"type":"extension_ui_response","id":"y","value":"ship it"}"#)
    }

    /// The `confirm` shape.
    func testConfirmResponse() throws {
        try WireFixtures.assertEncodes(
            ClientMessage.extensionUIResponse(ExtensionUIResponse(id: "f1", confirmed: true)),
            to: #"{"type":"extension_ui_response","id":"f1","confirmed":true}"#)
    }

    /// `AskAnswerWire` omit-empty (`protocol.dart:1943-1950`): an answer with
    /// nothing in it serializes to `{}`. pi-ask reads presence, so an explicit
    /// `"customText": ""` would be a *typed empty answer* rather than an
    /// unanswered question.
    func testEmptyAnswerPartsAreOmitted() throws {
        let response = ExtensionUIResponse.submit(
            flowID: "f1",
            answers: [
                "empty": AskAnswer(),
                "full": AskAnswer(
                    values: ["a"], customText: "note me", note: "why",
                    optionNotes: ["a": "because"]),
                "blankStrings": AskAnswer(customText: "", note: ""),
            ])
        let encoded = try WireFixtures.encoded(response)
        let ask = try XCTUnwrap(encoded["ask"] as? [String: Any])
        let answers = try XCTUnwrap(ask["answers"] as? [String: Any])

        XCTAssertEqual(try XCTUnwrap(answers["empty"] as? [String: Any]).count, 0)
        XCTAssertEqual(try XCTUnwrap(answers["blankStrings"] as? [String: Any]).count, 0)

        let full = try XCTUnwrap(answers["full"] as? [String: Any])
        XCTAssertEqual(full["values"] as? [String], ["a"])
        XCTAssertEqual(full["customText"] as? String, "note me")
        XCTAssertEqual(full["note"] as? String, "why")
        XCTAssertEqual(full["optionNotes"] as? [String: String], ["a": "because"])
        XCTAssertTrue(AskAnswer().isEmpty)
    }

    /// `mode` stays a raw `String?` for forward-compat and is omitted when nil.
    func testModeIsOptionalAndOpen() throws {
        let encoded = try WireFixtures.encoded(
            ExtensionUIResponse.submit(flowID: "f1", answers: [:], mode: nil))
        let ask = try XCTUnwrap(encoded["ask"] as? [String: Any])
        XCTAssertNil(ask["mode"])

        let elaborate = try WireFixtures.encoded(
            ExtensionUIResponse.submit(flowID: "f1", answers: [:], mode: "elaborate"))
        let elaborateAsk = try XCTUnwrap(elaborate["ask"] as? [String: Any])
        XCTAssertEqual(elaborateAsk["mode"] as? String, "elaborate")
    }

    /// A response with an `ask` envelope alongside `value` — the shape the
    /// bridge test's "forwards a rich answer back to pi-ask as a single submit"
    /// case sends — must round-trip both.
    func testValuePlusEnvelopeRoundTrips() throws {
        let line = #"""
            {"type":"extension_ui_response","id":"tool:tc_1","value":"Alpha",
             "ask":{"flow_id":"tool:tc_1","kind":"answer","mode":"submit",
                    "answers":{"goal":{"values":["a"]}}}}
            """#
        let message = try WireJSON.decode(ClientMessage.self, from: line)
        guard case .extensionUIResponse(let payload) = message else {
            return XCTFail("not extension_ui_response")
        }
        XCTAssertEqual(payload.value, "Alpha")
        guard case .answer(let flowID, let mode, let answers)? = payload.ask else {
            return XCTFail("not an answer envelope")
        }
        XCTAssertEqual(flowID, "tool:tc_1")
        XCTAssertEqual(mode, "submit")
        XCTAssertEqual(answers["goal"]?.values, ["a"])
        try WireFixtures.assertEncodes(message, to: line)
    }
}
