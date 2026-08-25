import Foundation
import RemotePiProtocol
import RemotePiStore
import XCTest

@testable import RemotePi

/// Spec 08 §8.1 (body states), §8.4 (list + keys), §8.5 (lifecycle badge).
///
/// Everything here runs against ``ChatTranscriptModel`` — no SwiftUI, no host
/// app, no store: the model takes values and derives rows, which is the whole
/// reason it takes values.
final class ChatTranscriptModelTests: XCTestCase {

    // MARK: Fixtures

    private func user(
        _ id: String,
        _ text: String = "hi",
        ts: Int64 = 1_000,
        pending: Bool = false,
        steering: Bool = false
    ) -> MessageRow {
        MessageRow(
            role: .user,
            msgID: id,
            text: text,
            ts: ts,
            pending: pending,
            steering: steering
        )
    }

    private func assistant(_ inReplyTo: String, _ text: String = "there") -> MessageRow {
        MessageRow(role: .assistant, msgID: inReplyTo, text: text, ts: 2_000, inReplyTo: inReplyTo)
    }

    private func tool(_ id: String) -> MessageRow {
        MessageRow(
            role: .tool,
            msgID: id,
            text: "bash",
            ts: 3_000,
            tool: ToolPayload(toolCallID: id, tool: "bash")
        )
    }

    // MARK: §8.4 — keys

    /// Trap T5 in list form: an assistant row is stored under the *user*
    /// message's id, so both rows exist with `msgID == "m1"`. If the list keyed
    /// by id alone they would collapse into one row.
    func testUserAndAssistantSharingAnIdAreTwoDistinctItems() {
        let items = ChatTranscriptModel.build(
            messages: [user("m1"), assistant("m1")],
            streaming: nil,
            hideToolCalls: false
        )
        XCTAssertEqual(items.map(\.id), ["user:m1", "assistant:m1"])
    }

    /// §8.4: the streaming row's key must be constant. A key that changed with
    /// the buffer would be a brand-new row on every token.
    func testStreamingItemKeyIsStableAsTheBufferGrows() {
        let short = ChatTranscriptModel.build(
            messages: [],
            streaming: StreamingDraft(buffer: "He"),
            hideToolCalls: false
        )
        let long = ChatTranscriptModel.build(
            messages: [],
            streaming: StreamingDraft(buffer: "Hello there"),
            hideToolCalls: false
        )
        XCTAssertEqual(short.map(\.id), ["streaming"])
        XCTAssertEqual(long.map(\.id), ["streaming"])
    }

    // MARK: The double-render trap

    /// `ChatIngest` upserts an assistant row on every `agent_chunk`, so the
    /// streaming text is already in `messages`. Rendering both would paint the
    /// same tokens twice.
    func testLiveDraftSuppressesThePersistedAssistantRowItIsAccumulating() {
        let items = ChatTranscriptModel.build(
            messages: [user("m1"), assistant("m1", "partial")],
            streaming: StreamingDraft(buffer: "partial…", inReplyTo: "m1"),
            hideToolCalls: false
        )
        XCTAssertEqual(items.map(\.id), ["user:m1", "streaming"])
    }

    /// A draft with no `in_reply_to` (the Pi has not told us which turn it
    /// answers) must not suppress an unrelated assistant row.
    func testDraftWithoutInReplyToSuppressesNothing() {
        let items = ChatTranscriptModel.build(
            messages: [assistant("m1")],
            streaming: StreamingDraft(buffer: "x"),
            hideToolCalls: false
        )
        XCTAssertEqual(items.map(\.id), ["assistant:m1", "streaming"])
    }

    func testDraftOnlySuppressesTheMatchingTurn() {
        let items = ChatTranscriptModel.build(
            messages: [assistant("m1"), assistant("m2")],
            streaming: StreamingDraft(buffer: "x", inReplyTo: "m2"),
            hideToolCalls: false
        )
        XCTAssertEqual(items.map(\.id), ["assistant:m1", "streaming"])
    }

    // MARK: §8.1 — hideToolCalls

    func testHideToolCallsDropsOnlyToolRows() {
        let messages = [user("m1"), tool("t1"), assistant("m1"), MessageRow(
            role: .compaction,
            msgID: "c1",
            text: "recap",
            ts: 4_000
        )]
        let hidden = ChatTranscriptModel.build(
            messages: messages,
            streaming: nil,
            hideToolCalls: true
        )
        XCTAssertEqual(hidden.map(\.id), ["user:m1", "assistant:m1", "compaction:c1"])

        let shown = ChatTranscriptModel.build(
            messages: messages,
            streaming: nil,
            hideToolCalls: false
        )
        XCTAssertEqual(shown.count, 4)
    }

    // MARK: §8.1 — body states

    @MainActor
    func testStatePriorityIsFatalThenNoPeerThenEmpty() {
        let model = ChatTranscriptModel()
        XCTAssertEqual(model.state, .empty)

        model.apply(messages: [user("m1")])
        XCTAssertEqual(model.state, .ready)

        // A revoked pairing beats a cached transcript: those rows are stale by
        // definition once the machine is gone.
        model.hasPeer = false
        XCTAssertEqual(model.state, .noPeer)

        model.fatalError = "boom"
        XCTAssertEqual(model.state, .fatal("boom"))
    }

    /// A turn that started before any row was persisted still has something to
    /// render — the empty state must not win over a live cursor.
    @MainActor
    func testStreamingAloneIsReadyNotEmpty() {
        let model = ChatTranscriptModel()
        model.apply(streaming: StreamingDraft())
        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.items.map(\.id), ["streaming"])
    }

    /// Hiding tool calls can empty a transcript that only ever held tool rows.
    /// That is the "Nothing here" state, not a broken list.
    @MainActor
    func testHidingToolCallsCanProduceTheEmptyState() {
        let model = ChatTranscriptModel()
        model.apply(messages: [tool("t1")])
        model.hideToolCalls = true
        XCTAssertEqual(model.state, .empty)
    }

    // MARK: §8.5 — user lifecycle badge

    @MainActor
    func testPendingRowAgesIntoNotDelivered() {
        let model = ChatTranscriptModel()
        let row = user("m1", ts: 1_000, pending: true)
        model.apply(messages: [row])

        model.refreshClock(now: 1_000 + 14_999)
        XCTAssertEqual(model.status(for: row), .pending)

        model.refreshClock(now: 1_000 + 15_000)
        XCTAssertEqual(model.status(for: row), .failed)
    }

    @MainActor
    func testConfirmedRowNeverShowsABadgeHoweverOldItIs() {
        let model = ChatTranscriptModel()
        let row = user("m1", ts: 1_000)
        model.apply(messages: [row])
        model.refreshClock(now: 1_000_000_000)
        XCTAssertEqual(model.status(for: row), .confirmed)
    }

    func testSteeringOutranksSendingButNotNotDelivered() {
        XCTAssertEqual(
            UserBubbleStatus.resolve(pending: true, steering: true, ts: 0, now: 0),
            .steering
        )
        XCTAssertEqual(
            UserBubbleStatus.resolve(pending: true, steering: true, ts: 0, now: 15_000),
            .failed
        )
        XCTAssertEqual(
            UserBubbleStatus.resolve(pending: false, steering: true, ts: 0, now: 99_000),
            .confirmed
        )
    }

    @MainActor
    func testHasPendingRowsDrivesTheClockOnlyWhenNeeded() {
        let model = ChatTranscriptModel()
        model.apply(messages: [user("m1")])
        XCTAssertFalse(model.hasPendingRows)

        model.apply(messages: [user("m1", pending: true)])
        XCTAssertTrue(model.hasPendingRows)
    }

    // MARK: Blinking cursor phase

    func testCursorBlinksOnForTheFirstHalfOfEachSecond() {
        let epoch = Date(timeIntervalSinceReferenceDate: 0)
        XCTAssertTrue(BlinkingCursor.isVisible(at: epoch))
        XCTAssertTrue(BlinkingCursor.isVisible(at: epoch.addingTimeInterval(0.4)))
        XCTAssertFalse(BlinkingCursor.isVisible(at: epoch.addingTimeInterval(0.5)))
        XCTAssertFalse(BlinkingCursor.isVisible(at: epoch.addingTimeInterval(0.9)))
        XCTAssertTrue(BlinkingCursor.isVisible(at: epoch.addingTimeInterval(1.0)))
    }

    // MARK: §8.3 — revoked banner copy

    func testRevokedBannerNamesTheDeviceWhenItKnowsIt() {
        XCTAssertEqual(
            RevokedBanner(device: "Studio", onRePair: {}).message,
            "Pairing revoked by Studio — re-pair to continue"
        )
        XCTAssertEqual(
            RevokedBanner(device: nil, onRePair: {}).message,
            "Pairing revoked — re-pair to continue"
        )
    }
}
