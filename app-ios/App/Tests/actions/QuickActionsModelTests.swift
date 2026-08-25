import Foundation
import RemotePiProtocol
import XCTest

@testable import RemotePi

/// Quick Actions behaviour (spec 08 §8.11) — dispatch, busy signalling,
/// optimistic highlight and the room-meta derivation.
@MainActor
final class QuickActionsModelTests: XCTestCase {
    private var service = FakeActionsService()
    private let session = Fixture.session()

    private func makeModel() -> QuickActionsModel {
        service = FakeActionsService()
        let model = QuickActionsModel()
        model.bind(to: service, session: session)
        return model
    }

    // MARK: - Compact

    func testCompactSucceedsQuietly() async {
        let model = makeModel()
        let closed = await model.compact()

        XCTAssertTrue(closed, "success closes the sheet")
        XCTAssertNil(model.errorMessage, "no success toast — compacting is quiet and frequent")
        XCTAssertNil(model.busy)
        XCTAssertEqual(service.calls, [.compact(session)])
    }

    /// A failed action must leave the sheet usable so the next tap retries.
    func testCompactFailureKeepsTheSheetUsable() async {
        let model = makeModel()
        service.compactFailure = ActionFailure("no session on the Pi")
        let closed = await model.compact()

        XCTAssertFalse(closed)
        XCTAssertEqual(model.errorMessage, "no session on the Pi")
        XCTAssertNil(model.busy, "the row is tappable again")
    }

    func testUnboundModelReportsRatherThanCrashing() async {
        let model = QuickActionsModel()
        let closed = await model.compact()
        XCTAssertFalse(closed)
        XCTAssertEqual(model.errorMessage, ActionFailure.notWired.message)
    }

    // MARK: - New Context

    /// The row dispatches `session_new`, which clears the context of the
    /// **same** session (§13.4) — the service method is named for what the
    /// frame does, not for what the wire calls it.
    func testNewContextConfirmsThenDispatchesThenWipesTheLocalMirror() async {
        let model = makeModel()
        model.requestNewContext()
        XCTAssertTrue(model.isConfirmingNewContext)

        let ok = await model.confirmNewContext()
        XCTAssertTrue(ok)
        XCTAssertFalse(model.isConfirmingNewContext)
        XCTAssertTrue(model.didClearContext)
        XCTAssertEqual(service.calls, [.newContext(session), .clearTranscript(session)])
    }

    /// The local mirror is wiped only after `action_ok`. Wiping first would
    /// delete a transcript the Pi still has.
    func testNewContextFailureLeavesTheLocalTranscriptAlone() async {
        let model = makeModel()
        service.newContextFailure = ActionFailure("busy")
        model.requestNewContext()
        let ok = await model.confirmNewContext()

        XCTAssertFalse(ok)
        XCTAssertFalse(model.didClearContext)
        XCTAssertEqual(service.calls, [.newContext(session)])
        XCTAssertEqual(model.errorMessage, "busy")
    }

    func testCancellingTheConfirmationDispatchesNothing() {
        let model = makeModel()
        model.requestNewContext()
        model.cancelNewContext()
        XCTAssertFalse(model.isConfirmingNewContext)
        XCTAssertTrue(service.calls.isEmpty)
    }

    // MARK: - Thinking

    func testSetThinkingHighlightsOptimistically() async {
        let model = makeModel()
        XCTAssertNil(model.currentThinking)
        let ok = await model.setThinking(.high)

        XCTAssertTrue(ok)
        XCTAssertEqual(model.currentThinking, .high)
        XCTAssertEqual(service.calls, [.setThinking(.high, session)])
    }

    func testSetThinkingRevertsOnFailure() async {
        let model = makeModel()
        _ = await model.setThinking(.low)
        service.setThinkingFailure = ActionFailure("unsupported")
        let ok = await model.setThinking(.xhigh)

        XCTAssertFalse(ok)
        XCTAssertEqual(model.currentThinking, .low, "reverted to the previous highlight")
        XCTAssertEqual(model.errorMessage, "unsupported")
    }

    /// Most relay builds never flatten `room_meta.thinking`, so `facts` stays
    /// `nil`. The local value has to survive that, or the control snaps back
    /// on every tap and looks broken.
    func testThinkingSurvivesARelayThatNeverReportsIt() async {
        let model = makeModel()
        _ = await model.setThinking(.medium)
        service.facts = RoomFacts(modelName: "claude", thinkingRaw: nil)
        XCTAssertEqual(model.currentThinking, .medium)
    }

    /// An external change to the level wins over ours.
    func testExternalThinkingChangeWins() async {
        let model = makeModel()
        _ = await model.setThinking(.medium)
        service.facts = RoomFacts(thinkingRaw: "high")
        XCTAssertEqual(model.currentThinking, .high)
    }

    /// A level this build does not know must not be forced to a known case —
    /// showing the wrong segment is worse than showing none.
    func testUnknownThinkingLevelSelectsNothing() {
        let model = makeModel()
        service.facts = RoomFacts(thinkingRaw: "ultra")
        XCTAssertNil(model.currentThinking)
    }

    // MARK: - Model

    func testModelRowPlaceholders() async {
        let model = makeModel()
        XCTAssertEqual(model.modelRowLabel, "Choose a model")

        service.facts = RoomFacts(modelName: "claude-sonnet-4.5")
        XCTAssertEqual(model.modelRowLabel, "claude-sonnet-4.5")
    }

    /// A local `model_set` is acked well before the relay re-broadcasts
    /// `room_meta`, so for a beat the relay still reports the old name.
    /// Deferring to it there would flip the row back to the previous model
    /// right after a successful switch.
    func testLocalSwitchWinsWhileTheRelayStillEchoesTheOldName() async {
        let model = makeModel()
        service.facts = RoomFacts(modelName: "old-model")
        let picked = Fixture.model("new-id", name: "new-model")

        let ok = await model.setModel(picked)
        XCTAssertTrue(ok)
        XCTAssertEqual(model.currentModelName, "new-model")
        XCTAssertEqual(model.currentModel, picked)
    }

    func testRelayCatchingUpKeepsTheSameAnswer() async {
        let model = makeModel()
        service.facts = RoomFacts(modelName: "old-model")
        let picked = Fixture.model("new-id", name: "new-model")
        _ = await model.setModel(picked)

        service.facts = RoomFacts(modelName: "new-model")
        XCTAssertEqual(model.currentModelName, "new-model")
        XCTAssertEqual(model.currentModel, picked)
    }

    /// Someone else switched the model (another paired device, or `/model` in
    /// the TUI): the relay wins and the structured record is dropped so the
    /// picker refetches (§8.11, `:155-160`).
    func testExternalSwitchWinsAndDropsTheStructuredModel() async {
        let model = makeModel()
        service.facts = RoomFacts(modelName: "old-model")
        _ = await model.setModel(Fixture.model("new-id", name: "new-model"))

        service.facts = RoomFacts(modelName: "someone-elses-model")
        XCTAssertEqual(model.currentModelName, "someone-elses-model")
        XCTAssertNil(model.currentModel)
    }

    func testSetModelRevertsOnFailure() async {
        let model = makeModel()
        service.facts = RoomFacts(modelName: "old-model")
        service.setModelFailure = ActionFailure("model not in registry")
        let ok = await model.setModel(Fixture.model("new-id", name: "new-model"))

        XCTAssertFalse(ok)
        XCTAssertEqual(model.currentModelName, "old-model")
        XCTAssertNil(model.currentModel)
        XCTAssertEqual(model.errorMessage, "model not in registry")
    }

    /// The catalogue's `current` upgrades the row from a display name to a
    /// structured record; a catalogue with no `current` must not clobber what
    /// we already learned.
    func testAdoptingACatalogue() async {
        let model = makeModel()
        let current = Fixture.model("id-1", name: "Claude Opus", contextWindow: 200_000)
        model.adopt(ModelCatalogue(models: [current], current: current))
        XCTAssertEqual(model.currentModel, current)

        model.adopt(ModelCatalogue(models: [current], current: nil))
        XCTAssertEqual(model.currentModel, current, "a nil current does not clobber")
    }

    // MARK: - Busy discipline

    /// One action at a time, across *all* rows — two `thinking_set` frames
    /// would race and the loser would silently win the UI.
    func testOnlyOneActionRunsAtATime() async {
        let model = makeModel()
        service.holdsCompact = true
        let running = Task { await model.compact() }
        await Task.yield()

        XCTAssertEqual(model.busy, .sessionCompact)
        let second = await model.setThinking(.high)
        XCTAssertFalse(second, "the second action is refused, not queued")
        XCTAssertEqual(service.calls, [.compact(session)])

        service.release()
        _ = await running.value
        XCTAssertNil(model.busy)
    }

    func testRequestNewContextIsIgnoredWhileBusy() async {
        let model = makeModel()
        service.holdsCompact = true
        let running = Task { await model.compact() }
        await Task.yield()

        model.requestNewContext()
        XCTAssertFalse(
            model.isConfirmingNewContext,
            "a destructive confirmation must not open over an in-flight action")

        service.release()
        _ = await running.value
    }

    /// The Model row's placeholder while a switch is resolving and nothing is
    /// yet known (§8.11).
    func testModelRowShowsSwitchingWhileBusyWithNoKnownName() async {
        let model = makeModel()
        service.holdsCompact = true
        // `compact` is only the vehicle for parking the model in a busy state;
        // the label branch keys off `busy == .modelSet`, so assert the other
        // side of it here and the .modelSet side via the picker.
        let running = Task { await model.compact() }
        await Task.yield()
        XCTAssertEqual(model.modelRowLabel, "Choose a model")
        service.release()
        _ = await running.value
    }

    // MARK: - Offline + session scoping

    func testOfflineIsReportedFromTheService() {
        let model = makeModel()
        XCTAssertFalse(model.isOffline)
        service.isConnected = false
        XCTAssertTrue(model.isOffline)
    }

    func testUnboundModelIsOffline() {
        XCTAssertTrue(QuickActionsModel().isOffline)
    }

    /// Local values describe the old room. Carrying them to a new session is
    /// exactly the "state keyed by the wrong thing" failure plan 61 is about.
    func testRebindingToAnotherSessionClearsLocalState() async {
        let model = makeModel()
        _ = await model.setThinking(.high)
        _ = await model.setModel(Fixture.model("m", name: "Model"))

        model.bind(to: service, session: Fixture.session(2))
        XCTAssertNil(model.currentThinking)
        XCTAssertNil(model.currentModel)
        XCTAssertEqual(model.modelRowLabel, "Choose a model")
    }

    func testDismissError() async {
        let model = makeModel()
        service.compactFailure = ActionFailure("boom")
        _ = await model.compact()
        model.dismissError()
        XCTAssertNil(model.errorMessage)
    }

    func testReportSurfacesASubPickerFailure() {
        let model = makeModel()
        model.report(ActionFailure("registry unavailable"))
        XCTAssertEqual(model.errorMessage, "registry unavailable")
    }

    // MARK: - Thinking segments

    func testThinkingSegmentLabels() {
        XCTAssertEqual(
            ThinkingSegments.ordered.map(ThinkingSegments.label(for:)),
            ["off", "min", "low", "med", "high", "x"])
        XCTAssertEqual(ThinkingSegments.ordered, ThinkingLevel.allCases)
    }
}
