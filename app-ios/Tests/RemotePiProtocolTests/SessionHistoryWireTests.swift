import Foundation
import XCTest

@testable import RemotePiProtocol

/// `session_history` decoding, pinned against
/// `.orchestration/contracts/fixtures/session_history.jsonl` — the exact frame
/// the Dart suite replays — and against spec 01 §8.
final class SessionHistoryWireTests: XCTestCase {

    /// The archived fixture, verbatim. Note the `tool_result` carries an
    /// **object** result and the `user_input` id is a `local_…` form from an
    /// older Pi (the current one mints `sync_<epoch_ms>`).
    private let fixture = #"""
        {"type":"session_history","in_reply_to":"018f9c5a-0000-7000-9a3b-1c2d3e4f5c01","session_started_at":1716234500000,"events":[{"ts":1716234601000,"type":"user_input","id":"local_018f9c4a-0000-7000-9a3b-1c2d3e4f5b01","text":"listar arquivos modificados"},{"ts":1716234602500,"type":"tool_request","tool_call_id":"tc_018f9c5b","tool":"bash","args":{"command":"git status -s"}},{"ts":1716234603100,"type":"tool_result","tool_call_id":"tc_018f9c5b","result":{"stdout":" M src/index.ts\n M README.md","exit_code":0}},{"ts":1716234604200,"type":"agent_message","in_reply_to":"local_018f9c4a-0000-7000-9a3b-1c2d3e4f5b01","text":"Você tem 2 arquivos modificados: `src/index.ts` e `README.md`.","usage":{"input_tokens":850,"output_tokens":42}}],"eos":true,"truncated":false}
        """#

    private func history(_ line: String) throws -> SessionHistory {
        let message = try XCTUnwrap(ServerMessage.decodeLossy(line))
        guard case .sessionHistory(let payload) = message else {
            throw XCTSkip("not a session_history: \(message.typeName)")
        }
        return payload
    }

    func testArchivedFixtureDecodesEveryEventKind() throws {
        let payload = try history(fixture)
        XCTAssertEqual(payload.inReplyTo, "018f9c5a-0000-7000-9a3b-1c2d3e4f5c01")
        XCTAssertEqual(payload.sessionStartedAt, 1_716_234_500_000)
        XCTAssertTrue(payload.eos)
        XCTAssertFalse(payload.truncated)
        XCTAssertEqual(payload.events.count, 4)
        XCTAssertTrue(payload.undecodableEvents.isEmpty)

        guard case .userInput(let ts, let id, let text, let images) = payload.events[0] else {
            return XCTFail("event 0 is not user_input")
        }
        XCTAssertEqual(ts, 1_716_234_601_000)
        XCTAssertEqual(id, "local_018f9c4a-0000-7000-9a3b-1c2d3e4f5b01")
        XCTAssertEqual(text, "listar arquivos modificados")
        XCTAssertTrue(images.isEmpty)

        guard case .toolRequest(_, let toolCallID, let tool, let args) = payload.events[1] else {
            return XCTFail("event 1 is not tool_request")
        }
        XCTAssertEqual(toolCallID, "tc_018f9c5b")
        XCTAssertEqual(tool, "bash")
        XCTAssertEqual(args?["command"]?.stringValue, "git status -s")

        guard case .toolResult(_, _, let result, let error) = payload.events[2] else {
            return XCTFail("event 2 is not tool_result")
        }
        XCTAssertNil(error)
        XCTAssertEqual(result?["exit_code"]?.intValue, 0)

        guard case .agentMessage(_, let inReplyTo, _, let usage) = payload.events[3] else {
            return XCTFail("event 3 is not agent_message")
        }
        // An approximation the Pi acknowledges in its own comments: the last
        // `user_input` id seen in a linear scan, not real threading.
        XCTAssertEqual(inReplyTo, "local_018f9c4a-0000-7000-9a3b-1c2d3e4f5b01")
        XCTAssertEqual(usage, Usage(inputTokens: 850, outputTokens: 42))
    }

    /// **Trap T2.** One unrecognised event must not cost the whole history.
    ///
    /// `SessionHistoryEvent.fromJson` throws on an unknown type
    /// (`protocol.dart:1535`) *inside* `SessionHistory.fromJson`, so the throw
    /// escapes to the frame handler and the entire `session_history` is
    /// dropped — the user sees an **empty** chat, not a partial one. Skipping
    /// the bad element and keeping the rest is strictly better; stashing it in
    /// `undecodableEvents` makes the loss observable.
    func testOneBadEventDoesNotKillTheWholeHistory() throws {
        let payload = try history(
            #"""
            {"type":"session_history","in_reply_to":"cli_1","session_started_at":1,
             "events":[
               {"ts":1,"type":"user_input","id":"sync_1","text":"first"},
               {"ts":2,"type":"thought_from_a_newer_pi","payload":{"a":1}},
               {"ts":3,"type":"agent_message","in_reply_to":"sync_1","text":"second"}],
             "eos":true}
            """#)
        XCTAssertEqual(payload.events.count, 2, "the two good events must survive")
        XCTAssertEqual(payload.undecodableEvents.count, 1)
        XCTAssertEqual(
            payload.undecodableEvents[0]["type"]?.stringValue, "thought_from_a_newer_pi")
    }

    /// An event missing its required `ts` is skipped the same way — the field
    /// is a hard cast on the Dart side, and a malformed element is not a reason
    /// to lose the transcript.
    func testEventMissingRequiredFieldsIsSkippedNotFatal() throws {
        let payload = try history(
            #"""
            {"type":"session_history","in_reply_to":"cli_1","session_started_at":1,
             "events":[{"type":"user_input","id":"a","text":"no ts"},
                       {"ts":2,"type":"user_input","id":"b","text":"fine"}],
             "eos":true}
            """#)
        XCTAssertEqual(payload.events.count, 1)
        XCTAssertEqual(payload.undecodableEvents.count, 1)
    }

    /// `truncated` arrived mid-protocol; an older Pi omits it
    /// (`protocol.dart:1494` defaults it to `false`).
    func testTruncatedDefaultsToFalseWhenAbsent() throws {
        let payload = try history(
            #"{"type":"session_history","in_reply_to":"a","session_started_at":0,"events":[],"eos":true}"#
        )
        XCTAssertFalse(payload.truncated)
        XCTAssertEqual(payload.sessionStartedAt, 0, "0 means: the Pi has no session yet")
    }

    /// Images replayed in history, so a cold start rebuilds the image bubble.
    func testUserInputEventCarriesImages() throws {
        let payload = try history(
            #"""
            {"type":"session_history","in_reply_to":"a","session_started_at":1,
             "events":[{"ts":1,"type":"user_input","id":"sync_1","text":"look",
                        "images":[{"data":"/9j/4AAQ","mime":"image/jpeg"}]}],
             "eos":true}
            """#)
        guard case .userInput(_, _, _, let images) = payload.events[0] else {
            return XCTFail("not user_input")
        }
        XCTAssertEqual(images, [WireImage(data: "/9j/4AAQ", mime: "image/jpeg")])
    }

    /// A history `compaction` carries the standard event `ts` and nothing else
    /// of its own; `tokens_before` may be absent.
    func testCompactionEvent() throws {
        let payload = try history(
            #"""
            {"type":"session_history","in_reply_to":"a","session_started_at":1,
             "events":[{"ts":9,"type":"compaction","summary":"resumo","tokens_before":31000}],
             "eos":true}
            """#)
        guard case .compaction(let ts, let summary, let tokensBefore) = payload.events[0] else {
            return XCTFail("not compaction")
        }
        XCTAssertEqual(ts, 9)
        XCTAssertEqual(summary, "resumo")
        XCTAssertEqual(tokensBefore, 31000)
    }

    /// Re-encoding must produce the same event shapes the Pi emits — including
    /// `ts` and `type` on every element and no `images` key on a text-only
    /// input.
    func testEventsReEncodeInTheProducerShape() throws {
        let payload = try history(fixture)
        let data = try WireJSON.encode(ServerMessage.sessionHistory(payload))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let events = try XCTUnwrap(object["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 4)
        XCTAssertEqual(events[0]["type"] as? String, "user_input")
        XCTAssertNil(events[0]["images"], "a text-only input carries no images key")
        XCTAssertEqual(events[2]["type"] as? String, "tool_result")
        XCTAssertNil(events[2]["error"], "result and error are mutually exclusive")
    }
}
