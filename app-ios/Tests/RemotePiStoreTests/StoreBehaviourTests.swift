import Foundation
import XCTest

@testable import RemotePiProtocol
@testable import RemotePiStore

/// The write model: optimistic send, the reap, history reconciliation,
/// attachments, streams and durability.
final class StoreBehaviourTests: XCTestCase {

    private var root: URL!
    private var store: SQLiteSessionStore!
    private let peer = PeerID(base64: "v_7-_f78-_r5-Pf29fTz8vHw7-7t7Ovq6ejn5uXk4-I")!
    private var key: SessionKey { SessionKey(peer: peer, room: RoomID("019ffb64-3c11-7a2e-9f00-6d2a1b3c4d5e")) }

    override func setUp() async throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rp-store-\(UUID().uuidString)", isDirectory: true)
        store = try SQLiteSessionStore(root: root)
    }

    override func tearDown() async throws {
        store = nil
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Optimistic send and the reap

    func testPendingRowIsWrittenBeforeAnythingElse() async throws {
        let row = try await store.appendPendingUserMessage(
            id: "cli_1", text: "run the tests", ts: 1_780_000_000_000, for: key
        )
        XCTAssertTrue(row.pending)
        XCTAssertEqual(row.seq, 0, "seq is dense from 0")
        // Durable *now*, not at the next checkpoint: the app can be suspended
        // between the write and the socket send (spec §2.3).
        let reopened = try SQLiteSessionStore(root: root)
        let texts = try await reopened.rows(for: key).map(\.text)
        XCTAssertEqual(texts, ["run the tests"])
    }

    /// The window is measured from the row's `ts`, not from when a timer was
    /// armed — that is what makes it survive process death
    /// (`sync_service.dart:248-255`, `:876`).
    func testReapDeletesStalePendingRowsSilently() async throws {
        let now: Int64 = 1_780_000_100_000
        _ = try await store.appendPendingUserMessage(id: "old", text: "stale", ts: now - 21_000, for: key)
        _ = try await store.appendPendingUserMessage(id: "fresh", text: "recent", ts: now - 1_000, for: key)

        let deadlines = try await store.pendingDeadlines(for: key)
        XCTAssertEqual(deadlines.map(\.id), ["old", "fresh"])
        XCTAssertEqual(deadlines.first?.deadlineMilliseconds, now - 21_000 + 20_000)

        let reaped = try await store.reapExpiredPending(for: key, now: now)
        XCTAssertEqual(reaped, ["old"])
        let rows = try await store.rows(for: key)
        // Deleted, not marked: `UserMsgStatus.failed` is never produced, and a
        // failed bubble the user cannot retry is worse than a vanished one.
        XCTAssertEqual(rows.map(\.msgID), ["fresh"])
        XCTAssertTrue(rows.allSatisfy { $0.role != .divider })
    }

    /// `transport_error` (PROTOCOL.md:176-187) carries no message id — the outer
    /// envelope has none — so it can only clear the whole pending set.
    func testTransportErrorClearsEveryPendingRowForTheRoom() async throws {
        _ = try await store.appendPendingUserMessage(id: "a", text: "one", ts: 1, for: key)
        _ = try await store.appendPendingUserMessage(id: "b", text: "two", ts: 2, for: key)
        _ = try await store.upsert(
            HistoryEntry(row: MessageRow(role: .assistant, msgID: "agent_1", text: "answer", ts: 3)),
            for: key
        )
        let reaped = try await store.reapAllPending(for: key)
        XCTAssertEqual(Set(reaped), ["a", "b"])
        let ids = try await store.rows(for: key).map(\.msgID)
        XCTAssertEqual(ids, ["agent_1"])
    }

    /// The echo confirms in place; the local copy of text/image wins
    /// (`sync_service.dart:502-547`).
    func testEchoConfirmsWithoutOverwritingLocalText() async throws {
        _ = try await store.appendPendingUserMessage(id: "cli_1", text: "typed here", ts: 10, for: key)
        let confirmed = try await store.confirmUserEcho(id: "cli_1", for: key)
        XCTAssertTrue(confirmed)
        let firstRow = try await store.rows(for: key).first
        let row = try XCTUnwrap(firstRow)
        XCTAssertFalse(row.pending)
        XCTAssertEqual(row.text, "typed here")

        // A foreign echo — typed in the Mac's terminal — has no local row, and
        // the caller is told so it can insert one with the receive time.
        let confirmed2 = try await store.confirmUserEcho(id: "from_mac", for: key)
        XCTAssertFalse(confirmed2)
    }

    /// `cancelled` deletes **pending** rows with that id only.
    func testRemovePendingSparesAConfirmedRowWithTheSameId() async throws {
        _ = try await store.appendPendingUserMessage(id: "same", text: "pending one", ts: 1, for: key)
        _ = try await store.upsert(
            HistoryEntry(row: MessageRow(role: .assistant, msgID: "same", text: "confirmed one", ts: 2)),
            for: key
        )
        try await store.removePending(id: "same", for: key)
        let texts = try await store.rows(for: key).map(\.text)
        XCTAssertEqual(texts, ["confirmed one"])
    }

    /// Trap T5: `(role, id)` is the identity. A user row and the assistant row
    /// answering it share an id — `agent_message` persists under `in_reply_to`.
    func testUserAndAssistantRowsCanShareAnId() async throws {
        _ = try await store.appendPendingUserMessage(id: "cli_1", text: "question", ts: 1, for: key)
        _ = try await store.upsert(
            HistoryEntry(
                row: MessageRow(role: .assistant, msgID: "cli_1", text: "answer", ts: 2, inReplyTo: "cli_1")
            ),
            for: key
        )
        let rows = try await store.rows(for: key)
        XCTAssertEqual(rows.count, 2, "keying by id alone would have collapsed these")
        XCTAssertEqual(rows.map(\.role), [.user, .assistant])
    }

    /// Trap T4: `result` and `error` are patches, so a retried tool can clear
    /// its error. Dart's `copyWith` writes `error ?? this.error` and cannot.
    func testToolUpdateCanActuallyClearAnError() async throws {
        let tool = ToolPayload(
            toolCallID: "toolu_01ABC", tool: "bash",
            argsJSON: Data(#"{"command":"pnpm test"}"#.utf8),
            status: .failed, error: "exit 1"
        )
        _ = try await store.upsert(
            HistoryEntry(row: MessageRow(role: .tool, msgID: "toolu_01ABC", ts: 1, tool: tool)),
            for: key
        )
        try await store.updateTool(
            toolCallID: "toolu_01ABC",
            status: .completed,
            result: .set(Data(#""42 passed""#.utf8)),
            error: .clear,
            for: key
        )
        let firstRow = try await store.rows(for: key).first
        let row = try XCTUnwrap(firstRow)
        XCTAssertEqual(row.tool?.status, .completed)
        XCTAssertNil(row.tool?.error)
        XCTAssertEqual(row.tool?.resultJSON, Data(#""42 passed""#.utf8))
        // An absent patch preserves: args were never in the update.
        XCTAssertEqual(row.tool?.argsJSON, Data(#"{"command":"pnpm test"}"#.utf8))
    }

    // MARK: - History reconciliation (Trap T1 / T5)

    /// The history replay mints **fresh ids** for everything
    /// (`index.ts:4617` — `sync_${ts}`), so identity matching sees every row as
    /// new. Positional alignment is what keeps the transcript from doubling.
    func testHistoryReplayWithFreshIdsDoesNotDuplicateRows() async throws {
        _ = try await store.appendPendingUserMessage(id: "cli_1", text: "run the tests", ts: 100, for: key)
        try await store.confirmUserEcho(id: "cli_1", for: key)
        _ = try await store.upsert(
            HistoryEntry(
                row: MessageRow(role: .assistant, msgID: "agent_ab", text: "on it", ts: 101, inReplyTo: "cli_1")
            ),
            for: key
        )

        // What `_mapAgentMessagesToEvents` produces for the same two messages.
        let replay = [
            HistoryEntry(row: MessageRow(role: .user, msgID: "sync_100", text: "run the tests", ts: 100)),
            HistoryEntry(
                row: MessageRow(role: .assistant, msgID: "sync_100", text: "on it", ts: 101, inReplyTo: "sync_100")
            ),
        ]
        let outcome = try await store.applyHistory(replay, sessionStartedAt: 90, for: key)
        XCTAssertTrue(outcome.applied)
        XCTAssertEqual(outcome.inserted, 0, "the same two messages must not become four")

        let rows = try await store.rows(for: key)
        XCTAssertEqual(rows.map(\.text), ["run the tests", "on it"])
        XCTAssertEqual(rows.map(\.msgID), ["cli_1", "agent_ab"], "local ids are kept, not re-keyed")
    }

    /// Trap T1, the headline: the Pi answers with at most 30 events, so a
    /// truncate-to-payload apply reduces a 40-row conversation to 30.
    func testAWindowOverTheTailKeepsOlderHistory() async throws {
        for index in 0..<40 {
            _ = try await store.upsert(
                HistoryEntry(
                    row: MessageRow(role: .user, msgID: "cli_\(index)", text: "line \(index)", ts: Int64(index))
                ),
                for: key
            )
        }
        let window = (10..<40).map { index in
            HistoryEntry(
                row: MessageRow(role: .user, msgID: "sync_\(index)", text: "line \(index)", ts: Int64(index))
            )
        }
        let outcome = try await store.applyHistory(window, sessionStartedAt: 1, for: key)
        XCTAssertEqual(outcome.inserted, 0)
        let rows = try await store.rows(for: key)
        XCTAssertEqual(rows.count, 40, "rows older than the window are not the Pi's to delete")
        XCTAssertEqual(rows.first?.text, "line 0")
    }

    /// The catastrophic case: a Pi that just restarted answers `session_sync`
    /// with `events: []` and a *new* `session_started_at`. Dart computes
    /// `desired = []` and deletes the entire local conversation.
    func testEmptyHistoryAfterAPiRestartDeletesNothing() async throws {
        _ = try await store.upsert(
            HistoryEntry(row: MessageRow(role: .user, msgID: "cli_1", text: "precious", ts: 1)),
            for: key
        )
        try await store.applyHistory([], sessionStartedAt: 1_000, for: key)

        let outcome = try await store.applyHistory([], sessionStartedAt: 2_000, for: key)
        XCTAssertTrue(outcome.applied)
        let texts = try await store.rows(for: key).map(\.text)
        XCTAssertEqual(texts, ["precious"])
        XCTAssertEqual(outcome.inserted, 0)
    }

    /// A restart with new content keeps the old rows and marks the boundary
    /// instead (Trap T1 rule 3).
    func testPiRestartInsertsABoundaryRowAndKeepsHistory() async throws {
        _ = try await store.upsert(
            HistoryEntry(row: MessageRow(role: .user, msgID: "cli_1", text: "before", ts: 1)),
            for: key
        )
        try await store.applyHistory([], sessionStartedAt: 1_000, for: key)

        let outcome = try await store.applyHistory(
            [HistoryEntry(row: MessageRow(role: .user, msgID: "sync_2", text: "after", ts: 2))],
            sessionStartedAt: 2_000,
            for: key
        )
        XCTAssertTrue(outcome.restartDetected)
        let rows = try await store.rows(for: key)
        XCTAssertEqual(rows.map(\.role), [.user, .divider, .user])
        XCTAssertEqual(rows.map(\.text), ["before", "", "after"])
        XCTAssertEqual(rows[1].msgID, "boundary_2000")

        // Insert-only: a second sync for the same restart must not stack
        // dividers.
        try await store.applyHistory(
            [HistoryEntry(row: MessageRow(role: .user, msgID: "sync_2", text: "after", ts: 2))],
            sessionStartedAt: 2_000,
            for: key
        )
        let rowCount = try await store.rows(for: key).count
        XCTAssertEqual(rowCount, 3)
    }

    /// An idle reconnect must write nothing and emit nothing — the "embaralha e
    /// some" flicker was ~2N writes per reconnect (`sync_service.dart:714-723`).
    func testIdenticalResyncIsAZeroWriteNoOp() async throws {
        let entries = [
            HistoryEntry(row: MessageRow(role: .user, msgID: "sync_1", text: "hi", ts: 1)),
            HistoryEntry(row: MessageRow(role: .assistant, msgID: "sync_1", text: "hello", ts: 2, inReplyTo: "sync_1")),
        ]
        _ = try await store.applyHistory(entries, sessionStartedAt: 500, for: key)
        let second = try await store.applyHistory(entries, sessionStartedAt: 500, for: key)
        XCTAssertEqual(second.inserted, 0)
        XCTAssertEqual(second.updated, 0, "an identical window must produce zero writes")
    }

    /// Trap T9 — batches are staged until `eos: true`. The pi-extension never
    /// batches, but the doc says it may, and a half-applied window would
    /// interleave into the transcript.
    func testHistoryIsBufferedUntilEndOfStream() async throws {
        let first = try await store.applyHistory(
            [HistoryEntry(row: MessageRow(role: .user, msgID: "sync_1", text: "part one", ts: 1))],
            sessionStartedAt: 10, eos: false, for: key
        )
        XCTAssertFalse(first.applied)
        let rowsEmpty = try await store.rows(for: key).isEmpty
        XCTAssertTrue(rowsEmpty)

        let last = try await store.applyHistory(
            [HistoryEntry(row: MessageRow(role: .assistant, msgID: "sync_1", text: "part two", ts: 2))],
            sessionStartedAt: 10, eos: true, for: key
        )
        XCTAssertTrue(last.applied)
        let texts = try await store.rows(for: key).map(\.text)
        XCTAssertEqual(texts, ["part one", "part two"])
    }

    /// An un-echoed pending row survives the sync and ends up below it.
    func testUnEchoedPendingRowIsPreservedAndMovedToTheTail() async throws {
        _ = try await store.upsert(
            HistoryEntry(row: MessageRow(role: .user, msgID: "cli_old", text: "older", ts: 1)),
            for: key
        )
        _ = try await store.appendPendingUserMessage(id: "cli_new", text: "just typed", ts: 9, for: key)

        try await store.applyHistory(
            [
                HistoryEntry(row: MessageRow(role: .user, msgID: "sync_1", text: "older", ts: 1)),
                HistoryEntry(row: MessageRow(role: .assistant, msgID: "sync_1", text: "an answer", ts: 2)),
            ],
            sessionStartedAt: 1, for: key
        )
        let rows = try await store.rows(for: key)
        XCTAssertEqual(rows.map(\.text), ["older", "an answer", "just typed"])
        XCTAssertTrue(try XCTUnwrap(rows.last).pending)
    }

    /// …and when the window *does* contain its echo (under a different id), the
    /// pending row is confirmed rather than duplicated.
    func testPendingRowEchoedUnderANewIdIsConfirmedNotDuplicated() async throws {
        _ = try await store.appendPendingUserMessage(id: "cli_new", text: "run it", ts: 9, for: key)
        try await store.applyHistory(
            [HistoryEntry(row: MessageRow(role: .user, msgID: "sync_9", text: "run it", ts: 9))],
            sessionStartedAt: 1, for: key
        )
        let rows = try await store.rows(for: key)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.msgID, "cli_new")
        XCTAssertFalse(try XCTUnwrap(rows.first).pending)
    }

    // MARK: - Attachments

    /// Trap T8 — image bytes live outside the row, content-addressed, and the
    /// wire spelling round-trips exactly. `QUJD` is the fixture
    /// `app/test/data/local/records_test.dart` uses (base64 of "ABC").
    func testImageBytesAreStoredOutOfTheRow() async throws {
        _ = try await store.appendPendingUserMessage(
            id: "cli_1", text: "look", images: [WireImage(data: "QUJD", mime: "image/jpeg")],
            ts: 1, for: key
        )
        let firstRow = try await store.rows(for: key).first
        let row = try XCTUnwrap(firstRow)
        let attachment = try XCTUnwrap(row.attachments.first)
        XCTAssertEqual(attachment.mime, "image/jpeg")
        XCTAssertEqual(attachment.byteLength, 3)
        XCTAssertTrue(attachment.canonical)

        let blob = root.appendingPathComponent("blobs").appendingPathComponent(attachment.fileName)
        XCTAssertEqual(try Data(contentsOf: blob), Data("ABC".utf8))

        let rebuilt = await store.wireImage(for: attachment)
        let restored = try XCTUnwrap(rebuilt)
        XCTAssertEqual(restored.data, "QUJD", "the base64 must come back byte-identical")
        XCTAssertEqual(restored.mime, "image/jpeg")
    }

    /// A bare image previews as `📷 Image` (`sync_service.dart:1162-1165`).
    func testPreviewMatchesDart() async throws {
        XCTAssertEqual(SQLiteSessionStore.preview(text: "", hasImage: true), "📷 Image")
        XCTAssertNil(SQLiteSessionStore.preview(text: "   ", hasImage: false))
        let long = String(repeating: "x", count: 200)
        XCTAssertEqual(SQLiteSessionStore.preview(text: long, hasImage: false)?.count, 81)

        _ = try await store.appendPendingUserMessage(id: "cli_1", text: "run the tests", ts: 42, for: key)
        let sessions = try await store.summaries()
        let summary = try XCTUnwrap(sessions.first)
        XCTAssertEqual(summary.lastMessagePreview, "run the tests")
        XCTAssertEqual(summary.lastMessageAt, 42)
    }

    // MARK: - Streams

    func testMessagesStreamEmitsTheSnapshotThenEveryChange() async throws {
        let stream = await store.messagesStream(for: key)
        var iterator = stream.makeAsyncIterator()

        let first = await iterator.next()
        XCTAssertEqual(first?.count, 0, "a subscriber sees the current snapshot immediately")

        _ = try await store.appendPendingUserMessage(id: "cli_1", text: "hello", ts: 1, for: key)
        let second = await iterator.next()
        XCTAssertEqual(second?.map(\.text), ["hello"])

        try await store.confirmUserEcho(id: "cli_1", for: key)
        let third = await iterator.next()
        XCTAssertEqual(third?.first?.pending, false)
    }

    func testRuntimeIsVolatileAndObservable() async throws {
        let stream = await store.runtimeStream(for: key)
        var iterator = stream.makeAsyncIterator()
        let atSubscribe = await iterator.next()
        XCTAssertEqual(atSubscribe, RuntimeState(connection: .connecting, presence: .unknown))

        await store.setRuntime(RuntimeState(connection: .online, presence: .alive), for: key)
        let afterChange = await iterator.next()
        XCTAssertEqual(afterChange, RuntimeState(connection: .online, presence: .alive))

        // A relaunch must not report a stale `online` (`boxes.dart:72-76`).
        let reopened = try SQLiteSessionStore(root: root)
        let afterRelaunch = await reopened.runtime(for: key)
        XCTAssertEqual(afterRelaunch, RuntimeState())
    }

    // MARK: - Durability, unpairing, selection

    func testTranscriptsSurviveUnpairingAndAreEnumerable() async throws {
        try await store.savePeer(
            PeerRecord(peer: peer, relayURL: "wss://relay.example", pairedAt: "2026-08-24T10:00:00Z")
        )
        _ = try await store.appendPendingUserMessage(id: "cli_1", text: "keep me", ts: 1, for: key)

        try await store.deletePeer(peer)
        let peersEmpty = try await store.loadPeers().isEmpty
        XCTAssertTrue(peersEmpty)
        let keptAfterUnpair = try await store.rows(for: key).map(\.text)
        XCTAssertEqual(
            keptAfterUnpair, ["keep me"],
            "unpairing must not delete conversations (boxes.dart:35-38)"
        )
        let orphans = try await store.orphanedSessions()
        XCTAssertEqual(orphans.map(\.key), [key])
        XCTAssertTrue(try XCTUnwrap(orphans.first).orphaned)

        // …but Settings can still offer the explicit purge.
        try await store.purgePeer(peer)
        let rowsEmpty = try await store.rows(for: key).isEmpty
        XCTAssertTrue(rowsEmpty)
        let sessionsEmpty = try await store.summaries().isEmpty
        XCTAssertTrue(sessionsEmpty)
    }

    func testPeerRecordRoundTripsEveryField() async throws {
        let record = PeerRecord(
            peer: peer,
            relayURL: "wss://relay.example",
            pairedAt: "2026-08-24T10:00:00.123Z",
            sessionName: "backend",
            nickname: "Studio Mac",
            hostname: "studio.local",
            harnessName: "claude-code",
            harnessVersion: "2.1.0",
            lastOpenedRoom: RoomID("019ffb64-3c11-7a2e-9f00-6d2a1b3c4d5e")
        )
        try await store.savePeer(record)
        let reopened = try SQLiteSessionStore(root: root)
        let peers = try await reopened.loadPeers()
        XCTAssertEqual(peers, [record])
    }

    /// Restoring the peer and defaulting the room to `main` is what reopened the
    /// wrong chat after a cold start (plan 61 Phase 0).
    func testSelectedSessionIsRestoredInFull() async throws {
        try await store.saveSelectedSession(key)
        let reopened = try SQLiteSessionStore(root: root)
        let selected = try await reopened.loadSelectedSession()
        XCTAssertEqual(selected, key)

        try await store.saveSelectedSession(nil)
        let selected2 = try await store.loadSelectedSession()
        XCTAssertNil(selected2)
    }

    /// A tail read must not materialise the whole transcript (Trap T8).
    func testLoadMessagesReturnsTheTailOldestFirst() async throws {
        for index in 0..<10 {
            _ = try await store.upsert(
                HistoryEntry(row: MessageRow(role: .user, msgID: "m\(index)", text: "line \(index)", ts: Int64(index))),
                for: key
            )
        }
        let tail = try await store.loadMessages(for: key, limit: 3)
        XCTAssertEqual(tail.map(\.text), ["line 7", "line 8", "line 9"])
        XCTAssertEqual(tail.map(\.role), [.user, .user, .user])
    }

    /// `session_new` is the only thing that empties a transcript, and the seq
    /// space restarts dense from 0.
    func testDeleteMessagesResetsTheSeqSpace() async throws {
        _ = try await store.appendPendingUserMessage(id: "cli_1", text: "gone", ts: 1, for: key)
        try await store.deleteMessages(for: key)
        let rowsEmpty = try await store.rows(for: key).isEmpty
        XCTAssertTrue(rowsEmpty)
        let fresh = try await store.appendPendingUserMessage(id: "cli_2", text: "new", ts: 2, for: key)
        XCTAssertEqual(fresh.seq, 0)
    }

    func testCheckpointLeavesTheStoreReadable() async throws {
        _ = try await store.appendPendingUserMessage(id: "cli_1", text: "survives", ts: 1, for: key)
        await store.checkpoint()
        let texts = try await store.rows(for: key).map(\.text)
        XCTAssertEqual(texts, ["survives"])
        let reopened = try SQLiteSessionStore(root: root)
        let texts2 = try await reopened.rows(for: key).map(\.text)
        XCTAssertEqual(texts2, ["survives"])
    }
}
