import Foundation
import XCTest

@testable import RemotePiProtocol
@testable import RemotePiStore

/// Wire-compat for the persisted record shapes.
///
/// Every payload here is copied verbatim out of ground truth — spec
/// `plan/62-specs/07-local-storage.md` §1.4 / §1.5 / §1.6, which quotes what
/// Dart's `MessageRecord.toJson`, `SessionIndexRecord.toJson` and
/// `RuntimeRecord.toJson` actually write — or out of
/// `app/test/data/local/*_test.dart`. Decoding-then-re-encoding our own output
/// would prove nothing; these assert against JSON the Dart side produced.
final class HiveRecordCompatTests: XCTestCase {

    private func object(_ json: String) throws -> [String: Any] {
        let data = Data(json.utf8)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    // MARK: - MessageRecord

    /// spec 07 §1.4, "Wire shape of a confirmed user row with an image".
    func testConfirmedUserRowWithImageRoundTripsByteForByte() throws {
        let json = """
            {
              "id": "cli_019ffb64-3c11-7a2e-9f00-6d2a1b3c4d5e",
              "seq": 12,
              "role": "user",
              "text": "run the tests",
              "image": { "data": "/9j/4AAQSkZJRgABAQ", "mime": "image/jpeg" },
              "ts": 1780000000123,
              "pending": false
            }
            """
        let source = try object(json)
        let record = try XCTUnwrap(HiveMessageRecord(jsonObject: source))

        XCTAssertEqual(record.id, "cli_019ffb64-3c11-7a2e-9f00-6d2a1b3c4d5e")
        XCTAssertEqual(record.seq, 12)
        XCTAssertEqual(record.role, .user)
        XCTAssertEqual(record.text, "run the tests")
        XCTAssertEqual(record.image?.mime, "image/jpeg")
        // Epoch MILLISECONDS, as an integer. Never a Date in the codec.
        XCTAssertEqual(record.ts, 1_780_000_000_123)
        XCTAssertFalse(record.pending)
        XCTAssertFalse(record.steering)

        XCTAssertEqual(record.jsonObject as NSDictionary, source as NSDictionary)
    }

    /// spec 07 §1.4, "A steering row still in flight".
    ///
    /// `steering` is written **only when true**, and `pending` is written even
    /// when false. A codec that normalises both to "always present" reads
    /// identically on the Dart side but emits JSON no Dart writer produced.
    func testSteeringPendingRowKeepsOmissionRules() throws {
        let json = """
            { "id": "cli_x", "seq": 13, "role": "user", "text": "actually, skip lint",
              "ts": 1780000000456, "pending": true, "steering": true }
            """
        let source = try object(json)
        let record = try XCTUnwrap(HiveMessageRecord(jsonObject: source))
        XCTAssertTrue(record.pending)
        XCTAssertTrue(record.steering)
        XCTAssertEqual(record.jsonObject as NSDictionary, source as NSDictionary)

        var quiet = record
        quiet.steering = false
        quiet.pending = false
        let encoded = quiet.jsonObject
        XCTAssertNil(encoded["steering"], "steering is emitted only when true")
        XCTAssertNotNil(encoded["pending"], "pending is emitted even when false")
        XCTAssertNil(encoded["image"])
        XCTAssertNil(encoded["tool"])
        XCTAssertNil(encoded["tokens_before"])
    }

    /// spec 07 §1.4, "A tool row".
    ///
    /// The nested `tool` object emits **explicit nulls** while the parent omits
    /// absent keys. That asymmetry is the actual contract.
    func testToolRowEmitsExplicitNullsInsideToolOnly() throws {
        let json = """
            {
              "id": "toolu_01ABC",
              "seq": 14,
              "role": "tool",
              "text": "",
              "tool": {
                "tool_call_id": "toolu_01ABC",
                "tool": "bash",
                "args": { "command": "pnpm test" },
                "status": "completed",
                "result": "42 passed",
                "error": null
              },
              "ts": 1780000000789,
              "pending": false
            }
            """
        let source = try object(json)
        let record = try XCTUnwrap(HiveMessageRecord(jsonObject: source))
        XCTAssertEqual(record.role, .tool)
        XCTAssertEqual(record.tool?.tool, "bash")
        XCTAssertEqual(record.tool?.status, .completed)
        // `args` stays raw JSON bytes: parsing it into typed Swift would invent
        // a contract that does not exist for an unknown tool.
        let args = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(record.tool?.argsJSON)) as? [String: Any]
        )
        XCTAssertEqual(args["command"] as? String, "pnpm test")
        // `result` is a bare string here — the Pi's `_stringifyToolResult`
        // returns text, so the codec has to allow a top-level JSON fragment.
        XCTAssertEqual(record.tool?.resultJSON, Data("\"42 passed\"".utf8))
        XCTAssertNil(record.tool?.error)

        XCTAssertEqual(record.jsonObject as NSDictionary, source as NSDictionary)

        let encodedTool = try XCTUnwrap(record.jsonObject["tool"] as? [String: Any])
        XCTAssertTrue(encodedTool["error"] is NSNull, "tool.error is an explicit null, not an omission")
        XCTAssertEqual(encodedTool.count, 6, "all six tool keys are always written")
    }

    /// spec 07 §1.4, "A compaction system row".
    func testCompactionRowCarriesTokensBefore() throws {
        let json = """
            { "id": "compaction_1780000009999", "seq": 15, "role": "compaction",
              "text": "Recapped the refactor of rooms.ts", "ts": 1780000009999,
              "pending": false, "tokens_before": 48213 }
            """
        let source = try object(json)
        let record = try XCTUnwrap(HiveMessageRecord(jsonObject: source))
        XCTAssertEqual(record.role, .compaction)
        XCTAssertEqual(record.tokensBefore, 48213)
        XCTAssertEqual(record.jsonObject as NSDictionary, source as NSDictionary)
    }

    /// `message_record.dart:85-88`, `:89`, `:180-183`.
    func testReadFallbacksMatchDart() throws {
        let source = try object(
            """
            { "id": "x", "seq": 0, "role": "sorcerer", "ts": 1,
              "tool": { "tool_call_id": "t", "status": "levitating" } }
            """
        )
        let record = try XCTUnwrap(HiveMessageRecord(jsonObject: source))
        XCTAssertEqual(record.role, .assistant, "unknown role falls back to assistant")
        XCTAssertEqual(record.text, "", "absent text reads as empty, not null")
        XCTAssertFalse(record.pending)
        XCTAssertEqual(record.tool?.status, .completed, "unknown tool status falls back to completed")
        XCTAssertEqual(record.tool?.tool, "unknown", "absent tool name falls back to 'unknown'")
    }

    /// Dart throws on a record with no `id` / `seq` / `ts`; we refuse it.
    func testRecordWithoutRequiredFieldsIsRefused() throws {
        XCTAssertNil(HiveMessageRecord(jsonObject: try object(#"{"seq":0,"ts":1}"#)))
        XCTAssertNil(HiveMessageRecord(jsonObject: try object(#"{"id":"x","ts":1}"#)))
        XCTAssertNil(HiveMessageRecord(jsonObject: try object(#"{"id":"x","seq":0}"#)))
    }

    /// A local-only divider has no Dart counterpart and must not be encoded as
    /// some other role.
    func testDividerRowHasNoHiveRepresentation() {
        let row = MessageRow(seq: 3, role: .divider, msgID: "boundary_1", ts: 1)
        XCTAssertNil(HiveMessageRecord(row: row))
    }

    // MARK: - SessionIndexRecord

    /// spec 07 §1.5 — all seven keys, with explicit nulls, and the exact epk
    /// fixture `app/test/data/local/boxes_test.dart` uses.
    func testSessionIndexRecordEmitsAllSevenKeys() throws {
        let json = """
            {
              "epk": "v_7-_f78-_r5-Pf29fTz8vHw7-7t7Ovq6ejn5uXk4-I",
              "room_id": "019ffb64-3c11-7a2e-9f00-6d2a1b3c4d5e",
              "display_name": "",
              "status": "working",
              "last_message_at": 1780000000123,
              "last_message_preview": "run the tests",
              "session_started_at": 1780000000000
            }
            """
        let source = try object(json)
        let record = try XCTUnwrap(HiveSessionIndexRecord(jsonObject: source))
        XCTAssertEqual(record.status, .working)
        XCTAssertEqual(record.lastMessagePreview, "run the tests")
        XCTAssertEqual(record.jsonObject as NSDictionary, source as NSDictionary)

        // The Hive box key for that row — `boxes.dart:110-111`, url-safe epk and
        // a `:` separator. Quoted in the spec as the key of this exact record.
        XCTAssertEqual(
            record.hiveKey,
            "v_7-_f78-_r5-Pf29fTz8vHw7-7t7Ovq6ejn5uXk4-I:019ffb64-3c11-7a2e-9f00-6d2a1b3c4d5e"
        )
    }

    /// Trap T2 / plan 61 Fase 0: the same key in the standard alphabet must
    /// produce the same row, not a second one.
    func testSessionIndexRecordCollapsesBothEpkSpellings() throws {
        let urlSafe = "v_7-_f78-_r5-Pf29fTz8vHw7-7t7Ovq6ejn5uXk4-I"
        let standard = "v/7+/f78+/r5+Pf29fTz8vHw7+7t7Ovq6ejn5uXk4+I="

        let a = try XCTUnwrap(
            HiveSessionIndexRecord(jsonObject: ["epk": urlSafe, "room_id": "r1", "status": "idle"])
        )
        let b = try XCTUnwrap(
            HiveSessionIndexRecord(jsonObject: ["epk": standard, "room_id": "r1", "status": "idle"])
        )
        XCTAssertEqual(a.peer, b.peer)
        XCTAssertEqual(a.hiveKey, b.hiveKey)
        // …and the key we write back is always the url-safe spelling, so a
        // standard-base64 epk that arrives from a legacy row cannot mint a
        // second index row for the same session.
        XCTAssertEqual(b.jsonObject["epk"] as? String, urlSafe)
    }

    // MARK: - RuntimeRecord

    /// spec 07 §1.6 — both keys always present; fallbacks `connecting` /
    /// `unknown` (`runtime_record.dart:32-39`).
    func testRuntimeStateMatchesDartSpellings() throws {
        let source = try object(#"{ "connection": "online", "presence": "alive" }"#)
        let state = RuntimeState(jsonObject: source)
        XCTAssertEqual(state.connection, .online)
        XCTAssertEqual(state.presence, .alive)
        XCTAssertEqual(state.jsonObject as NSDictionary, source as NSDictionary)

        let empty = RuntimeState(jsonObject: [:])
        XCTAssertEqual(empty.connection, .connecting)
        XCTAssertEqual(empty.presence, .unknown)

        XCTAssertEqual(
            Set(RuntimeState.Connection.allCases.map(\.rawValue)),
            ["connecting", "online", "offline", "retrying"]
        )
        XCTAssertEqual(
            Set(RuntimeState.Presence.allCases.map(\.rawValue)),
            ["alive", "stale", "unknown"]
        )
    }

    /// The four persisted role spellings and the six tool statuses are what
    /// `role.name` / `status.name` write. A rename here silently orphans rows.
    func testEnumSpellingsArePinned() {
        XCTAssertEqual(
            MessageRole.allCases.map(\.rawValue),
            ["user", "assistant", "tool", "compaction", "divider"]
        )
        XCTAssertEqual(
            ToolStatus.allCases.map(\.rawValue),
            ["pending", "allowed", "denied", "expired", "completed", "failed"]
        )
    }
}
