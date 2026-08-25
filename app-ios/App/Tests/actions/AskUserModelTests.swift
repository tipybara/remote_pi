import Foundation
import RemotePiProtocol
import XCTest

@testable import RemotePi

/// Inbound routing and the submit lifecycle (spec 08 §8.13).
@MainActor
final class AskUserModelTests: XCTestCase {
    private var service = FakeActionsService()
    private let session = Fixture.session()

    private func makeModel() -> AskUserModel {
        service = FakeActionsService()
        let model = AskUserModel()
        model.bind(to: service, session: session)
        model.backstopDelay = .milliseconds(20)
        return model
    }

    // MARK: - Inbound routing

    func testNonNotifyOpensTheModal() {
        let model = makeModel()
        model.receive(Fixture.degradedRequest(method: .select, options: ["A"]))
        XCTAssertEqual(model.form?.request.id, "flow-1")
    }

    /// A `notify` for the open flow with `warning` / `error` keeps the modal
    /// up and offers a retry — closing it would strand the flow on the desktop.
    func testWarningNotifyKeepsTheModalAndShowsTheMessage() {
        let model = makeModel()
        model.receive(Fixture.degradedRequest(method: .select, options: ["A"]))
        model.receive(Fixture.notify(id: "flow-1", type: .warning, message: "invalid_answer"))

        XCTAssertNotNil(model.form)
        XCTAssertEqual(model.errorMessage, "invalid_answer")
        XCTAssertFalse(model.isSubmitting)
    }

    func testWarningNotifyWithoutAMessageFallsBackToTheStockCopy() {
        let model = makeModel()
        model.receive(Fixture.degradedRequest(method: .select, options: ["A"]))
        model.receive(Fixture.notify(id: "flow-1", type: .error))
        XCTAssertEqual(model.errorMessage, "Answer was not accepted.")
    }

    func testDismissNotifyClosesTheModal() {
        let model = makeModel()
        model.receive(Fixture.degradedRequest(method: .select, options: ["A"]))
        model.receive(Fixture.notify(id: "flow-1", message: "Clarification resolved."))
        XCTAssertNil(model.form)
        XCTAssertNil(model.errorMessage)
    }

    /// `info` is not a rejection: the flow finished elsewhere, so the modal
    /// closes. `ExtensionUIRequest.isDismissNotify` treats only an *absent*
    /// `notify_type` as a dismiss, which is why this is not written in terms
    /// of that helper.
    func testInfoNotifyAlsoClosesTheModal() {
        let model = makeModel()
        model.receive(Fixture.degradedRequest(method: .select, options: ["A"]))
        model.receive(Fixture.notify(id: "flow-1", type: .info))
        XCTAssertNil(model.form)
    }

    func testUnmatchedNotifyIsIgnored() {
        let model = makeModel()
        model.receive(Fixture.degradedRequest(method: .select, options: ["A"]))
        model.receive(Fixture.notify(id: "some-other-flow", type: .warning, message: "boom"))
        XCTAssertEqual(model.form?.request.id, "flow-1")
        XCTAssertNil(model.errorMessage)
    }

    func testUnmatchedNotifyWithNothingOpenDoesNotOpenAModal() {
        let model = makeModel()
        model.receive(Fixture.notify(id: "stand-alone", message: "FYI"))
        XCTAssertNil(model.form)
    }

    /// Question ids repeat across flows, so a replacement must not inherit the
    /// previous flow's answers.
    func testReplacingTheRequestResetsTheForm() {
        let model = makeModel()
        let question = Fixture.question("goal", options: [Fixture.option("a")])
        model.receive(Fixture.richRequest(id: "flow-1", questions: [question]))
        model.toggle(question, value: "a")
        XCTAssertTrue(model.canSubmit)

        model.receive(Fixture.richRequest(id: "flow-2", questions: [question]))
        XCTAssertEqual(model.form?.request.id, "flow-2")
        XCTAssertFalse(model.canSubmit)
    }

    // MARK: - Submit lifecycle

    /// The modal does **not** close on send: pi-ask can reject an answer
    /// without emitting `completed`, and closing would leave the flow blocked
    /// on the desktop with no way back.
    func testSubmitDoesNotCloseTheModal() async {
        let model = makeModel()
        model.receive(Fixture.degradedRequest(method: .confirm))
        await model.submit()

        XCTAssertNotNil(model.form)
        XCTAssertTrue(model.isSubmitting)
        guard case .respond(let response, let key)? = service.calls.last else {
            return XCTFail("expected a respond call")
        }
        XCTAssertEqual(response.confirmed, true)
        XCTAssertEqual(key, session)
    }

    /// A send that never left the device fails now rather than spinning out
    /// the full 25 s backstop.
    func testUnsentResponseFailsImmediately() async {
        let model = makeModel()
        service.respondSucceeds = false
        model.receive(Fixture.degradedRequest(method: .confirm))
        await model.submit()

        XCTAssertFalse(model.isSubmitting)
        XCTAssertEqual(model.errorMessage, "Not connected — check the link to Pi and retry.")
        XCTAssertNotNil(model.form, "the flow is still open; the user can retry")
    }

    func testBackstopStopsTheSpinnerAndShowsTheHint() async {
        let model = makeModel()
        model.receive(Fixture.degradedRequest(method: .confirm))
        await model.submit()
        XCTAssertTrue(model.isSubmitting)

        model.backstopElapsed()
        XCTAssertFalse(model.isSubmitting)
        XCTAssertTrue(model.showsAwaitHint)
        XCTAssertEqual(
            model.footerNote, .awaiting("No response from Pi yet — retry or cancel."))
    }

    func testBackstopDoesNothingOnceTheSubmitResolved() {
        let model = makeModel()
        model.receive(Fixture.degradedRequest(method: .confirm))
        model.reject("nope")
        model.backstopElapsed()
        XCTAssertFalse(model.showsAwaitHint)
        XCTAssertEqual(model.footerNote, .error("nope"))
    }

    /// The Flutter `didUpdateWidget` trap: clearing the previous error at the
    /// start of a retry must not lower the spinner. Here the clear and the
    /// raise are the same statement, so a retry always spins.
    func testRetryAfterRejectionClearsTheMessageAndSpinsAgain() async {
        let model = makeModel()
        model.receive(Fixture.degradedRequest(method: .confirm))
        await model.submit()
        model.receive(Fixture.notify(id: "flow-1", type: .warning, message: "invalid_answer"))
        XCTAssertFalse(model.isSubmitting)

        await model.submit()
        XCTAssertTrue(model.isSubmitting)
        XCTAssertNil(model.errorMessage)
    }

    func testSubmitIsIgnoredWhileOneIsInFlight() async {
        let model = makeModel()
        model.receive(Fixture.degradedRequest(method: .confirm))
        await model.submit()
        await model.submit()
        XCTAssertEqual(service.calls.count, 1, "no double submit")
    }

    func testSubmitIsIgnoredWhenNothingIsAnswerable() async {
        let model = makeModel()
        model.receive(Fixture.degradedRequest(method: .select, options: ["A"]))
        await model.submit()
        XCTAssertTrue(service.calls.isEmpty)
    }

    // MARK: - Cancel

    /// A dismissal must send the cancel frame, never just disappear.
    func testCancelSendsTheFrameAndClosesTheModal() async {
        let model = makeModel()
        model.receive(Fixture.richRequest(id: "flow-7", questions: [Fixture.question("a")]))
        await model.cancel()

        XCTAssertNil(model.form)
        guard case .respond(let response, _)? = service.calls.last else {
            return XCTFail("expected a respond call")
        }
        XCTAssertTrue(response.cancelled)
        XCTAssertEqual(response.ask?.flowID, "flow-7")
    }

    func testCancelWithNothingOpenIsANoOp() async {
        let model = makeModel()
        await model.cancel()
        XCTAssertTrue(service.calls.isEmpty)
    }

    /// The presenter's dismiss binding calls `cancel()` after `clear()` has
    /// already run; that must not put a second frame on the wire.
    func testCancelAfterClearDoesNotDoubleSend() async {
        let model = makeModel()
        model.receive(Fixture.degradedRequest(method: .confirm))
        model.clear()
        await model.cancel()
        XCTAssertTrue(service.calls.isEmpty)
    }

    // MARK: - Session scoping

    /// A modal must never hover over a different session's transcript
    /// (spec 08 §11.2).
    func testRebindingToAnotherSessionDropsTheFlow() {
        let model = makeModel()
        model.receive(Fixture.degradedRequest(method: .confirm))
        model.bind(to: service, session: Fixture.session(2))
        XCTAssertNil(model.form)
    }

    func testRebindingToTheSameSessionKeepsTheFlow() {
        let model = makeModel()
        model.receive(Fixture.degradedRequest(method: .confirm))
        model.bind(to: service, session: session)
        XCTAssertNotNil(model.form)
    }

    // MARK: - Editing guards

    func testEditsAreIgnoredWhileSubmitting() async {
        let model = makeModel()
        let question = Fixture.question("goal", options: [Fixture.option("a"), Fixture.option("b")])
        model.receive(Fixture.richRequest(questions: [question]))
        model.toggle(question, value: "a")
        await model.submit()

        model.toggle(question, value: "b")
        XCTAssertTrue(model.form?.isSelected(question, value: "a") ?? false)
        XCTAssertFalse(model.form?.isSelected(question, value: "b") ?? true)
    }

    // MARK: - Backstop timer

    /// The injected delay actually drives ``AskUserModel/backstopElapsed()``.
    func testBackstopTimerFires() async throws {
        let model = makeModel()
        model.receive(Fixture.degradedRequest(method: .confirm))
        await model.submit()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(model.showsAwaitHint)
        XCTAssertFalse(model.isSubmitting)
    }

    func testDeactivateCancelsTheBackstop() async throws {
        let model = makeModel()
        model.receive(Fixture.degradedRequest(method: .confirm))
        await model.submit()
        model.deactivate()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(model.showsAwaitHint)
    }
}
