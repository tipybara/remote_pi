import Foundation
import RemotePiProtocol
import XCTest

@testable import RemotePi

/// The pi-ask answer rules (spec 08 §8.13). Every one of these is a rule the
/// spec flags as a trap, and each is a pure function of ``AskForm``.
final class AskFormTests: XCTestCase {

    // MARK: - Rich: response construction

    /// pi-ask forbids combining a selected value with custom text on a
    /// non-multi question, so custom text wins and `values` goes out empty
    /// (§8.13, `:170`).
    func testCustomTextBeatsSelectionOnSingleQuestion() {
        let question = Fixture.question("goal", options: [Fixture.option("a"), Fixture.option("b")])
        var form = AskForm(request: Fixture.richRequest(questions: [question]))
        form.toggle(question, value: "a")
        form.setCustom("  something else  ", for: question)

        guard case .answer(_, _, let answers)? = form.response().ask else {
            return XCTFail("expected an answer envelope")
        }
        XCTAssertEqual(answers["goal"]?.values, [])
        XCTAssertEqual(answers["goal"]?.customText, "something else")
    }

    /// A multi question may carry both.
    func testMultiQuestionKeepsValuesAndCustomText() {
        let question = Fixture.question(
            "goal", type: .multi,
            options: [Fixture.option("a"), Fixture.option("b")])
        var form = AskForm(request: Fixture.richRequest(questions: [question]))
        form.toggle(question, value: "a")
        form.toggle(question, value: "b")
        form.setCustom("and this", for: question)

        guard case .answer(_, _, let answers)? = form.response().ask else {
            return XCTFail("expected an answer envelope")
        }
        XCTAssertEqual(answers["goal"]?.values, ["a", "b"])
        XCTAssertEqual(answers["goal"]?.customText, "and this")
    }

    /// Questions with neither a selection nor custom text are omitted
    /// entirely — pi-ask reads presence, and `{}` is a typed empty answer.
    func testUnansweredQuestionsAreOmitted() {
        let answered = Fixture.question("a", options: [Fixture.option("x")])
        let skipped = Fixture.question("b", options: [Fixture.option("y")])
        var form = AskForm(request: Fixture.richRequest(questions: [answered, skipped]))
        form.toggle(answered, value: "x")
        // Whitespace-only custom text is not an answer either.
        form.setCustom("   ", for: skipped)

        guard case .answer(_, _, let answers)? = form.response().ask else {
            return XCTFail("expected an answer envelope")
        }
        XCTAssertEqual(Set(answers.keys), ["a"])
    }

    /// Multi-select values ship in the order the options are declared.
    ///
    /// The Dart sheet submits `Set.toList()`, so its order depends on the hash
    /// seed. Deliberately not reproduced: pi-ask echoes the order into the
    /// prompt, and a non-deterministic answer is a non-reproducible run.
    func testMultiSelectionIsOrderedByOptionDeclaration() {
        let question = Fixture.question(
            "goal", type: .multi,
            options: [
                Fixture.option("first"), Fixture.option("second"), Fixture.option("third"),
            ])
        var form = AskForm(request: Fixture.richRequest(questions: [question]))
        form.toggle(question, value: "third")
        form.toggle(question, value: "first")
        form.toggle(question, value: "second")

        guard case .answer(_, _, let answers)? = form.response().ask else {
            return XCTFail("expected an answer envelope")
        }
        XCTAssertEqual(answers["goal"]?.values, ["first", "second", "third"])
    }

    /// A rich submit sends the envelope **alone** — no `value`, no
    /// `confirmed`, no `cancelled` (`types.ts:164-173`).
    func testRichSubmitSendsEnvelopeAlone() throws {
        let question = Fixture.question("goal", options: [Fixture.option("a")])
        var form = AskForm(request: Fixture.richRequest(id: "flow-9", questions: [question]))
        form.toggle(question, value: "a")

        let response = form.response()
        XCTAssertNil(response.value)
        XCTAssertNil(response.confirmed)
        XCTAssertFalse(response.cancelled)
        XCTAssertEqual(response.id, "flow-9")

        let json = try XCTUnwrap(
            String(data: WireJSON.encode(response), encoding: .utf8))
        XCTAssertFalse(json.contains("\"cancelled\""))
        XCTAssertTrue(json.contains("\"flow_id\":\"flow-9\""))
        XCTAssertTrue(json.contains("\"kind\":\"answer\""))
        // camelCase inside the answer, snake_case around it. The asymmetry is
        // real — it mirrors pi-ask.
        XCTAssertTrue(json.contains("\"values\""))
    }

    // MARK: - Rich: selection semantics

    /// `presentedType` overrides `type` (§8.13, `:101-103`): a question the
    /// flow presented as multi must accept several answers even when its
    /// declared type says single.
    func testPresentedTypeOverridesDeclaredType() {
        let question = Fixture.question(
            "goal", type: .single, presentedType: .multi,
            options: [Fixture.option("a"), Fixture.option("b")])
        var form = AskForm(request: Fixture.richRequest(questions: [question]))
        XCTAssertTrue(form.isMulti(question))

        form.toggle(question, value: "a")
        form.toggle(question, value: "b")
        XCTAssertTrue(form.isSelected(question, value: "a"))
        XCTAssertTrue(form.isSelected(question, value: "b"))
    }

    func testSingleSelectionReplacesRatherThanAccumulates() {
        let question = Fixture.question(
            "goal", options: [Fixture.option("a"), Fixture.option("b")])
        var form = AskForm(request: Fixture.richRequest(questions: [question]))
        form.toggle(question, value: "a")
        form.toggle(question, value: "b")
        XCTAssertFalse(form.isSelected(question, value: "a"))
        XCTAssertTrue(form.isSelected(question, value: "b"))
        // Re-tapping the chosen option keeps it chosen: pi-ask has no "no
        // answer" value, and deselecting would look like a broken radio.
        form.toggle(question, value: "b")
        XCTAssertTrue(form.isSelected(question, value: "b"))
    }

    func testMultiSelectionTogglesOff() {
        let question = Fixture.question("goal", type: .multi, options: [Fixture.option("a")])
        var form = AskForm(request: Fixture.richRequest(questions: [question]))
        form.toggle(question, value: "a")
        form.toggle(question, value: "a")
        XCTAssertFalse(form.isSelected(question, value: "a"))
    }

    // MARK: - Submit enablement

    func testRichCanSubmitNeedsOneAnsweredQuestion() {
        let a = Fixture.question("a", options: [Fixture.option("x")])
        let b = Fixture.question("b", options: [Fixture.option("y")])
        var form = AskForm(request: Fixture.richRequest(questions: [a, b]))
        XCTAssertFalse(form.canSubmit)
        form.toggle(b, value: "y")
        XCTAssertTrue(form.canSubmit)
    }

    func testRichCanSubmitOnCustomTextAlone() {
        let question = Fixture.question("a", options: [Fixture.option("x")])
        var form = AskForm(request: Fixture.richRequest(questions: [question]))
        form.setCustom("  ", for: question)
        XCTAssertFalse(form.canSubmit, "whitespace is not an answer")
        form.setCustom("free text", for: question)
        XCTAssertTrue(form.canSubmit)
    }

    /// `required` is advisory in pi-ask and must never block submission
    /// (§8.13, `:279-286`).
    func testRequiredDoesNotBlockSubmission() {
        let required = Fixture.question("must", required: true, options: [Fixture.option("x")])
        let optional = Fixture.question("may", options: [Fixture.option("y")])
        var form = AskForm(request: Fixture.richRequest(questions: [required, optional]))
        form.toggle(optional, value: "y")
        XCTAssertTrue(form.canSubmit)
    }

    // MARK: - Degraded mode

    func testDegradedSelectNeedsAValueAndEchoesTheLabel() {
        var form = AskForm(
            request: Fixture.degradedRequest(method: .select, options: ["Rewrite", "Keep"]))
        XCTAssertFalse(form.isRich)
        XCTAssertFalse(form.canSubmit)
        form.singleValue = "Rewrite"
        XCTAssertTrue(form.canSubmit)

        let response = form.response()
        // The **label**, not a value: the bridge maps it back through its
        // per-request table. Sending a value lands the answer as free text.
        XCTAssertEqual(response.value, "Rewrite")
        XCTAssertNil(response.ask)
    }

    func testDegradedInputTrimsForEnablementButNotForTheAnswer() {
        var form = AskForm(request: Fixture.degradedRequest(method: .input))
        form.text = "   "
        XCTAssertFalse(form.canSubmit)
        form.text = "  hello\n"
        XCTAssertTrue(form.canSubmit)
        // Trailing whitespace in an editor answer is content.
        XCTAssertEqual(form.response().value, "  hello\n")
    }

    func testDegradedConfirmIsAlwaysSubmittable() {
        let form = AskForm(request: Fixture.degradedRequest(method: .confirm))
        XCTAssertTrue(form.canSubmit)
        XCTAssertEqual(form.response().confirmed, true)
        XCTAssertNil(form.response().value)
    }

    func testDegradedNotifyIsNeverSubmittable() {
        let form = AskForm(request: Fixture.degradedRequest(method: .notify))
        XCTAssertFalse(form.canSubmit)
    }

    /// An unrecognised method renders (and answers) as `select` rather than
    /// being dropped — a modal with the wrong affordance is recoverable, a
    /// dropped ask blocks the Pi for the bridge's 10-minute TTL.
    func testUnknownMethodDegradesToSelect() {
        var form = AskForm(
            request: Fixture.degradedRequest(
                method: ExtensionUIMethod(rawValue: "carousel"), options: ["A"]))
        XCTAssertEqual(form.method, .select)
        form.singleValue = "A"
        XCTAssertEqual(form.response().value, "A")
    }

    /// `prefill` is the editor's seed text. The Flutter sheet never reads it,
    /// so a Pi-supplied draft is lost there; seeding it is a deliberate fix.
    func testEditorSeedsPrefill() {
        let form = AskForm(
            request: Fixture.degradedRequest(method: .editor, prefill: "draft body"))
        XCTAssertEqual(form.text, "draft body")
        XCTAssertTrue(form.canSubmit)
    }

    // MARK: - Cancel

    /// A rich cancel sends **both** discriminators so it still routes through
    /// a middlebox that only understands the flat shape.
    func testRichCancelSendsBothDiscriminators() throws {
        let form = AskForm(
            request: Fixture.richRequest(id: "flow-3", questions: [Fixture.question("a")]))
        let response = form.cancelResponse()
        XCTAssertTrue(response.cancelled)
        XCTAssertEqual(response.ask?.flowID, "flow-3")

        let json = try XCTUnwrap(String(data: WireJSON.encode(response), encoding: .utf8))
        XCTAssertTrue(json.contains("\"cancelled\":true"))
        XCTAssertTrue(json.contains("\"kind\":\"cancel\""))
        // A cancel carries flow_id and kind only — `answers: {}` would route
        // the frame down the bridge's answer path.
        XCTAssertFalse(json.contains("\"answers\""))
    }

    func testDegradedCancelHasNoEnvelope() {
        let form = AskForm(request: Fixture.degradedRequest(method: .input))
        let response = form.cancelResponse()
        XCTAssertTrue(response.cancelled)
        XCTAssertNil(response.ask)
    }

    // MARK: - Title

    func testTitleFallsBackThroughRequestThenAskThenLiteral() {
        XCTAssertEqual(
            AskForm(request: Fixture.richRequest(title: "Pick one", questions: [])).title,
            "Pick one")

        let askTitled = ExtensionUIRequest(
            id: "f", method: .select,
            ask: AskEnrichment(flowID: "f", title: "Flow title", questions: []))
        XCTAssertEqual(AskForm(request: askTitled).title, "Flow title")

        XCTAssertEqual(
            AskForm(request: Fixture.degradedRequest(method: .select)).title,
            "Clarification needed")
    }
}
