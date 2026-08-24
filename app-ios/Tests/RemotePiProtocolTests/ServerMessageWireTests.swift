import Foundation
import XCTest

@testable import RemotePiProtocol

/// Pi → app decoders, pinned against the archived contract fixtures
/// (`.orchestration/contracts/fixtures/*.jsonl` — the exact lines the Dart
/// suite replays in `app/test/protocol_test.dart`) and against the payloads
/// documented in `plan/62-specs/01-wire-messages.md`.
final class ServerMessageWireTests: XCTestCase {

    private func decode(_ line: String, file: StaticString = #filePath, line lineNo: UInt = #line)
        throws -> ServerMessage
    {
        try XCTUnwrap(ServerMessage.decodeLossy(line), "did not decode", file: file, line: lineNo)
    }

    // MARK: - streaming a turn

    /// Fixture: `agent_stream.jsonl`, all three lines.
    func testAgentStream() throws {
        let chunk = try decode(
            #"{"type":"agent_chunk","in_reply_to":"018f9c2a-7b1e-7000-9a3b-1c2d3e4f5a6e","delta":"Vou olhar o "}"#
        )
        guard case .agentChunk(let payload) = chunk else { return XCTFail("not agent_chunk") }
        XCTAssertEqual(payload.inReplyTo, "018f9c2a-7b1e-7000-9a3b-1c2d3e4f5a6e")
        XCTAssertEqual(payload.delta, "Vou olhar o ")

        let done = try decode(
            #"{"type":"agent_done","in_reply_to":"018f9c2a-7b1e-7000-9a3b-1c2d3e4f5a6e","usage":{"input_tokens":120,"output_tokens":340}}"#
        )
        guard case .agentDone(let finished) = done else { return XCTFail("not agent_done") }
        XCTAssertEqual(finished.usage, Usage(inputTokens: 120, outputTokens: 340))
    }

    /// `agent_done.usage` is optional — and in fact the **live path never sends
    /// it** (`index.ts:2282`). Pinned to `app/test/protocol_test.dart`
    /// → "usage is optional".
    func testAgentDoneWithoutUsage() throws {
        let done = try decode(#"{"type":"agent_done","in_reply_to":"x"}"#)
        guard case .agentDone(let payload) = done else { return XCTFail("not agent_done") }
        XCTAssertNil(payload.usage)
    }

    /// Fixture: `agent_message.jsonl`.
    func testAgentMessageWithUsage() throws {
        let message = try decode(
            #"{"type":"agent_message","in_reply_to":"018f9c2a-7b1e-7000-9a3b-1c2d3e4f5a6e","text":"O token expira em 1h por segurança. Veja `auth/middleware.ts:42`.","usage":{"input_tokens":120,"output_tokens":340}}"#
        )
        guard case .agentMessage(let payload) = message else {
            return XCTFail("not agent_message")
        }
        XCTAssertTrue(payload.text.hasPrefix("O token expira"))
        XCTAssertEqual(payload.usage?.outputTokens, 340)
    }

    // MARK: - user echo vs TUI mirror

    /// Fixtures: `user_message.jsonl` and `user_input.jsonl`.
    ///
    /// Both map to one payload — but which wire type carried it decides whether
    /// a local optimistic bubble gets reconciled (`user_message`, the echo of
    /// something this device sent) or a fresh row is appended (`user_input`,
    /// text typed at the Mac's terminal).
    func testUserMessageEchoAndUserInputMirrorAreDistinguishable() throws {
        let echo = try decode(
            #"{"type":"user_message","id":"018f9c2a-7b1e-7000-9a3b-1c2d3e4f5a6e","text":"por que o token expira antes da hora?"}"#
        )
        guard case .userInput(let echoed) = echo else { return XCTFail("not user_message") }
        XCTAssertTrue(echoed.isEcho)
        XCTAssertEqual(echoed.id, "018f9c2a-7b1e-7000-9a3b-1c2d3e4f5a6e")

        let mirror = try decode(
            #"{"type":"user_input","id":"local_018f9c4a-0000-7000-9a3b-1c2d3e4f5b01","text":"listar arquivos modificados"}"#
        )
        guard case .userInput(let mirrored) = mirror else { return XCTFail("not user_input") }
        XCTAssertFalse(mirrored.isEcho)
        XCTAssertEqual(mirror.typeName, "user_input", "the wire type must round-trip")
        XCTAssertEqual(echo.typeName, "user_message")
    }

    /// The echo carries `streaming_behavior: "steer"` the sender never wrote,
    /// when the Pi inferred a steer server-side (`index.ts:722-732`).
    func testEchoMayCarryASteerTheSenderNeverSet() throws {
        let echo = try decode(
            #"{"type":"user_message","id":"cli_1","text":"also fix the lint","streaming_behavior":"steer"}"#
        )
        guard case .userInput(let payload) = echo else { return XCTFail("not user_message") }
        XCTAssertEqual(payload.streamingBehavior, .steer)
    }

    // MARK: - tools

    /// Fixture: `tool_request.jsonl`.
    func testToolRequestKeepsFreeFormArgs() throws {
        let message = try decode(
            #"{"type":"tool_request","tool_call_id":"tc_018f9c2b","tool":"Bash","args":{"command":"rm -rf node_modules"}}"#
        )
        guard case .toolRequest(let payload) = message else { return XCTFail("not tool_request") }
        XCTAssertEqual(payload.toolCallID, "tc_018f9c2b")
        XCTAssertEqual(payload.tool, "Bash")
        XCTAssertEqual(payload.args?["command"]?.stringValue, "rm -rf node_modules")
        XCTAssertNil(payload.editHunks, "no hunks on a Bash call")
    }

    /// Fixture: `tool_result.jsonl`, both lines.
    ///
    /// The first carries an **object** result. The live Pi stringifies
    /// everything (`_stringifyToolResult`), but the archived contract does not,
    /// and a decoder typed `String?` would drop the payload outright — hence
    /// ``AnyJSON``. `result` and `error` are mutually exclusive.
    func testToolResultAcceptsBothAnObjectResultAndAnError() throws {
        let ok = try decode(
            #"{"type":"tool_result","tool_call_id":"tc_018f9c2c","result":{"stdout":"removed 1247 files","exit_code":0}}"#
        )
        guard case .toolResult(let success) = ok else { return XCTFail("not tool_result") }
        XCTAssertEqual(success.result?["exit_code"]?.intValue, 0)
        XCTAssertNil(success.resultText, "an object result has no string form")
        XCTAssertFalse(success.isFailure)

        let bad = try decode(
            #"{"type":"tool_result","tool_call_id":"tc_018f9c2d","error":"command timed out after 60s"}"#
        )
        guard case .toolResult(let failure) = bad else { return XCTFail("not tool_result") }
        XCTAssertNil(failure.result)
        XCTAssertTrue(failure.isFailure)
        XCTAssertEqual(failure.error, "command timed out after 60s")
    }

    /// The undocumented `edit` enrichment (`index.ts:4389-4431`), which the
    /// chat renders as a diff card. camelCase line numbers — a
    /// `.convertFromSnakeCase` decoder would null every one of them out.
    func testEditToolHunksDecode() throws {
        let message = try decode(
            #"""
            {"type":"tool_request","tool_call_id":"tc_1","tool":"edit",
             "args":{"path":"src/index.ts","hunks":[{"lines":[
               {"kind":"context","oldLine":11,"newLine":11,"text":"const a = 1;"},
               {"kind":"remove","oldLine":12,"text":"const b = 2;"},
               {"kind":"add","newLine":12,"text":"const b = 3;"},
               {"kind":"ellipsis"}]}]}}
            """#
        )
        guard case .toolRequest(let payload) = message else { return XCTFail("not tool_request") }
        let hunks = try XCTUnwrap(payload.editHunks)
        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(hunks[0].lines.count, 4)
        XCTAssertEqual(hunks[0].lines[0].oldLine, 11)
        XCTAssertEqual(hunks[0].lines[1].kind, .remove)
        XCTAssertEqual(hunks[0].lines[3].kind, .ellipsis)
        XCTAssertNil(hunks[0].lines[3].text, "an ellipsis carries no text")
    }

    // MARK: - errors and lifecycle

    /// Fixture: `error.jsonl`, all three lines. The second and third have **no**
    /// `in_reply_to` — it is optional (`index.ts:2271-2273`).
    func testErrorFrames() throws {
        let correlated = try decode(
            #"{"type":"error","in_reply_to":"018f9c2a-7b1e-7000-9a3b-1c2d3e4f5a6e","code":"tool_approval_required","message":"tool_call tc_018f9c2b ainda aguarda approve_tool"}"#
        )
        guard case .error(let first) = correlated else { return XCTFail("not error") }
        XCTAssertEqual(first.code, .toolApprovalRequired)
        XCTAssertEqual(first.inReplyTo, "018f9c2a-7b1e-7000-9a3b-1c2d3e4f5a6e")

        for line in [
            #"{"type":"error","code":"invalid_message","message":"missing required field 'id' in user_message"}"#,
            #"{"type":"error","code":"too_large","message":"ct payload exceeds 1 MiB limit"}"#,
        ] {
            guard case .error(let payload) = try decode(line) else {
                return XCTFail("not error: \(line)")
            }
            XCTAssertNil(payload.inReplyTo)
        }
    }

    /// `error.code` is an open union: the Pi emits `provider_error`, which
    /// `types.ts:241-251` never declares. A closed enum would throw here and
    /// take the socket read loop with it.
    func testUndeclaredErrorCodeStillDecodes() throws {
        guard
            case .error(let payload) = try decode(
                #"{"type":"error","code":"provider_error","message":"upstream 529"}"#)
        else { return XCTFail("not error") }
        XCTAssertEqual(payload.code, .providerError)
        XCTAssertFalse(payload.code.indicatesRevokedPairing)
    }

    /// The "pairing was revoked" special case the Flutter client keys on with a
    /// substring match (`sync_service.dart:625-630`).
    func testUnknownPeerCodeIsRecognisedAsARevokedPairing() throws {
        guard
            case .error(let payload) = try decode(
                #"{"type":"error","code":"unknown_peer","message":"não pareado"}"#)
        else { return XCTFail("not error") }
        XCTAssertTrue(payload.code.indicatesRevokedPairing)
    }

    /// Fixtures: `cancelled.jsonl`, `pong.jsonl`, `bye.jsonl`.
    func testCancelledPongAndBye() throws {
        guard
            case .cancelled(let cancelled) = try decode(
                #"{"type":"cancelled","in_reply_to":"018f9c2d-7b1e-7000-9a3b-1c2d3e4f5a72","target_id":"018f9c2a-7b1e-7000-9a3b-1c2d3e4f5a6e"}"#
            )
        else { return XCTFail("not cancelled") }
        XCTAssertEqual(cancelled.targetID, "018f9c2a-7b1e-7000-9a3b-1c2d3e4f5a6e")

        guard
            case .pong(let inReplyTo) = try decode(
                #"{"type":"pong","in_reply_to":"018f9c2e-7b1e-7000-9a3b-1c2d3e4f5a73"}"#)
        else { return XCTFail("not pong") }
        XCTAssertEqual(inReplyTo, "018f9c2e-7b1e-7000-9a3b-1c2d3e4f5a73")

        guard case .bye(let reason) = try decode(#"{"type":"bye","reason":"peer_stop"}"#) else {
            return XCTFail("not bye")
        }
        XCTAssertEqual(reason, .peerStop)
    }

    // MARK: - queued messages

    /// Pinned to `app/test/protocol_test.dart` → "parses plural items and
    /// legacy fallback".
    func testQueuedMessageStatePluralAndLegacyFallback() throws {
        guard
            case .queuedMessageState(let plural) = try decode(
                #"""
                {"type":"queued_message_state","items":[
                  {"id":"q1","text":"next","editable":true,"created_at":123}]}
                """#)
        else { return XCTFail("not queued_message_state") }
        XCTAssertEqual(plural.items.count, 1)
        XCTAssertEqual(plural.items[0].id, "q1")
        XCTAssertEqual(plural.items[0].createdAt, 123)

        guard
            case .queuedMessageState(let legacy) = try decode(
                #"{"type":"queued_message_state","id":"old","text":"legacy"}"#)
        else { return XCTFail("not queued_message_state") }
        XCTAssertEqual(legacy.items.count, 1)
        XCTAssertEqual(legacy.items[0].text, "legacy")
        XCTAssertTrue(legacy.items[0].editable, "editable defaults to true")
    }

    /// An **empty** `items` array must win over the legacy mirror.
    ///
    /// It is the "the queue is now empty" signal (`index.ts:912` omits the
    /// legacy keys entirely once the queue drains). Falling through to the
    /// `{id, text}` branch on an empty array would leave a drained item on
    /// screen with no way to clear it.
    func testEmptyItemsArrayMeansEmptyQueue() throws {
        guard
            case .queuedMessageState(let state) = try decode(
                #"{"type":"queued_message_state","items":[]}"#)
        else { return XCTFail("not queued_message_state") }
        XCTAssertTrue(state.items.isEmpty)
    }

    /// The Flutter client drops items whose text is empty
    /// (`protocol.dart:1371`); rendering them produces blank queue rows.
    func testEmptyTextItemsAreDropped() throws {
        guard
            case .queuedMessageState(let state) = try decode(
                #"{"type":"queued_message_state","items":[{"id":"a","text":""},{"id":"b","text":"real"}]}"#
            )
        else { return XCTFail("not queued_message_state") }
        XCTAssertEqual(state.items.map(\.id), ["b"])
    }

    /// Pinned to `app/test/protocol_test.dart` → "parses steer consumed clear
    /// signal".
    func testSteerConsumed() throws {
        guard case .steerConsumed(let id) = try decode(#"{"type":"steer_consumed","id":"s1"}"#)
        else { return XCTFail("not steer_consumed") }
        XCTAssertEqual(id, "s1")
    }

    // MARK: - pairing

    /// Fixture: `pair_ok.jsonl` — a **pre-plan-61** Pi. No `session_id`, so the
    /// room id is *not* stable across renames; no `harness`, no `hostname`.
    func testLegacyPairOk() throws {
        guard
            case .pairOk(let payload) = try decode(
                #"{"type":"pair_ok","in_reply_to":"018f9c3a-0000-7000-9a3b-1c2d3e4f5a01","session_name":"remote_pi · feature/protocol","session_started_at":1716234500000,"room_id":"aB12CD34eF56"}"#
            )
        else { return XCTFail("not pair_ok") }
        XCTAssertEqual(payload.roomID, RoomID("aB12CD34eF56"))
        XCTAssertFalse(payload.roomIDWasOmitted)
        XCTAssertFalse(payload.hasStableIdentity, "no session_id → legacy digest room")
        XCTAssertNil(payload.harness)
        XCTAssertEqual(payload.sessionStartedAt, 1_716_234_500_000)
    }

    /// Spec 01 §7.9 — the post-plan-61 frame. The Flutter client parses only
    /// six of these keys and silently drops `session_id`, `workspace_path`,
    /// `display_name` and `name_rev`; the wire wins, so all four must land.
    func testFullPairOkKeepsTheFourFieldsFlutterDrops() throws {
        guard
            case .pairOk(let payload) = try decode(
                #"""
                {"type":"pair_ok","in_reply_to":"req-1",
                 "session_name":"remote_pi","session_started_at":1780000000000,
                 "room_id":"019ffb64-1c3e-7a91-b0d2-6f2a1c9e77aa",
                 "session_id":"019ffb64-1c3e-7a91-b0d2-6f2a1c9e77aa",
                 "workspace_path":"/Users/x/proj","display_name":"remote_pi",
                 "name_rev":1780000000000,
                 "harness":{"name":"Pi coding agent","version":"0.9.3"},
                 "hostname":"jacobs-mac"}
                """#)
        else { return XCTFail("not pair_ok") }
        XCTAssertEqual(payload.sessionID, SessionID("019ffb64-1c3e-7a91-b0d2-6f2a1c9e77aa"))
        XCTAssertEqual(payload.workspacePath, "/Users/x/proj")
        XCTAssertEqual(payload.displayName, "remote_pi")
        XCTAssertEqual(payload.nameRev, 1_780_000_000_000)
        XCTAssertEqual(payload.harness, PiHarness(name: "Pi coding agent", version: "0.9.3"))
        XCTAssertEqual(payload.hostname, "jacobs-mac")
        XCTAssertTrue(payload.hasStableIdentity)
    }

    /// "Pi said main" and "Pi omitted room_id" must stay distinguishable: only
    /// the second may fall back to the QR code's room hint
    /// (`pair_request_flow.dart:127-135`).
    func testOmittedRoomIDIsDistinguishableFromAnExplicitMain() throws {
        guard
            case .pairOk(let omitted) = try decode(
                #"{"type":"pair_ok","in_reply_to":"r","session_name":"s","session_started_at":0}"#)
        else { return XCTFail("not pair_ok") }
        XCTAssertEqual(omitted.roomID, .main)
        XCTAssertTrue(omitted.roomIDWasOmitted)

        guard
            case .pairOk(let explicit) = try decode(
                #"{"type":"pair_ok","in_reply_to":"r","session_name":"s","session_started_at":0,"room_id":"main"}"#
            )
        else { return XCTFail("not pair_ok") }
        XCTAssertEqual(explicit.roomID, .main)
        XCTAssertFalse(explicit.roomIDWasOmitted)
    }

    /// Fixture: `pair_error.jsonl`.
    func testPairError() throws {
        guard
            case .pairError(let payload) = try decode(
                #"{"type":"pair_error","in_reply_to":"018f9c3a-0000-7000-9a3b-1c2d3e4f5a02","code":"token_expired","message":"Token efêmero expirou. Gere um novo QR com /remote-pi pair."}"#
            )
        else { return XCTFail("not pair_error") }
        XCTAssertEqual(payload.code, .tokenExpired)
    }

    // MARK: - action replies

    /// Spec 01 §4.2. A chat action's ack carries nothing beyond ok/error.
    func testChatActionAcks() throws {
        guard
            case .actionOk(let ok) = try decode(
                #"{"type":"action_ok","in_reply_to":"act_1","action":"session_compact"}"#)
        else { return XCTFail("not action_ok") }
        XCTAssertEqual(ok.action, .sessionCompact)
        XCTAssertFalse(ok.isReplay)

        guard
            case .actionError(let failed) = try decode(
                #"{"type":"action_error","in_reply_to":"act_2","action":"model_set","error":"no auth configured for this model"}"#
            )
        else { return XCTFail("not action_error") }
        XCTAssertEqual(failed.action, .modelSet)
        XCTAssertEqual(failed.error, "no auth configured for this model")
    }

    /// The `action` field carries values from **two** producers on one socket.
    /// An unknown one must not silently become `session_compact`, which is what
    /// the Flutter enum's fallback does (`protocol.dart:1663`).
    func testUnknownActionNameDoesNotMasqueradeAsACompaction() throws {
        guard
            case .actionOk(let ok) = try decode(
                #"{"type":"action_ok","in_reply_to":"a","action":"session_fork"}"#)
        else { return XCTFail("not action_ok") }
        XCTAssertNotEqual(ok.action, .sessionCompact)
        XCTAssertFalse(ok.action.isKnown)
        XCTAssertEqual(ok.action.rawValue, "session_fork")
    }

    /// Spec 01 §5.1 — the machine-control `action_ok` payloads, the only
    /// replies that carry data. Kept as the raw frame so a new control field
    /// needs no new type here.
    func testControlActionOkPayloadsSurvive() throws {
        let message = try decode(
            #"""
            {"type":"action_ok","in_reply_to":"ctl_1","action":"session_list",
             "sessions":[{"session_id":"019ffb64","workspace_id":"a1b2c3d4",
                          "display_name":"backend","mode":"background",
                          "desired":"running","created_at":1780000000000,"running":true}]}
            """#)
        guard case .actionOk(let ok) = message else { return XCTFail("not action_ok") }
        XCTAssertEqual(ok.action, .sessionList)

        // The typed view, via the control-plane parser.
        let json = try XCTUnwrap(ok.raw.jsonObject as? [String: Any])
        guard case .ok(let success)? = ControlReply.parse(json) else {
            return XCTFail("ControlReply did not parse the same frame")
        }
        XCTAssertEqual(success.sessions.count, 1)
        XCTAssertEqual(success.sessions[0].desired, .running)
        XCTAssertEqual(success.sessions[0].mode, .background)
        XCTAssertTrue(success.sessions[0].running)
        XCTAssertEqual(success.sessions[0].createdAt, 1_780_000_000_000)
    }

    /// A replayed idempotent success carries **only** `{session_id, replayed}`
    /// (`gateway.ts:311-314`) — `path` and `display_name` do not survive a
    /// retry, so a caller must need nothing but the session id.
    func testReplayedActionOkIsRecognisable() throws {
        guard
            case .actionOk(let ok) = try decode(
                #"{"type":"action_ok","in_reply_to":"ctl_9","action":"create_session","session_id":"019ffb64","replayed":true}"#
            )
        else { return XCTFail("not action_ok") }
        XCTAssertTrue(ok.isReplay)
        XCTAssertNil(ok.raw["path"])
        XCTAssertNil(ok.raw["display_name"])
    }

    /// Spec 01 §4.4.
    func testModelsList() throws {
        guard
            case .modelsList(let payload) = try decode(
                #"""
                {"type":"models_list","in_reply_to":"act_1",
                 "models":[{"id":"claude-opus-4-7","name":"Claude Opus 4.7",
                            "provider":"anthropic","reasoning":true,
                            "context_window":200000,"vision":true}],
                 "current":{"id":"claude-opus-4-7","name":"Claude Opus 4.7",
                            "provider":"anthropic","reasoning":true,
                            "context_window":200000,"vision":true}}
                """#)
        else { return XCTFail("not models_list") }
        XCTAssertEqual(payload.models.count, 1)
        XCTAssertEqual(payload.models[0].contextWindow, 200_000)
        XCTAssertTrue(payload.models[0].vision)
        XCTAssertEqual(payload.current?.id, "claude-opus-4-7")
    }

    /// `current` absent is honest: the Pi could not resolve the live model
    /// (`handlers.ts:297` passes `undefined`, which `JSON.stringify` drops).
    /// The three flags each default rather than throwing.
    func testModelsListWithoutCurrentAndWithoutFlags() throws {
        guard
            case .modelsList(let payload) = try decode(
                #"{"type":"models_list","in_reply_to":"a","models":[{"id":"m","name":"M","provider":"p"}]}"#
            )
        else { return XCTFail("not models_list") }
        XCTAssertNil(payload.current)
        XCTAssertFalse(payload.models[0].reasoning)
        XCTAssertEqual(payload.models[0].contextWindow, 0)
        XCTAssertFalse(payload.models[0].vision)
    }

    /// `list_models` reports a broken registry as `error`, **not**
    /// `action_error` (`handlers.ts:299-306`). A pending-request table that
    /// only inspects the action replies waits out its whole 15 s timeout and
    /// reports "timed out" instead of the real message — the hole the Flutter
    /// `ActionsRepository` still has. Matching on `inReplyTo` closes it.
    func testErrorFrameIsCorrelatableToAPendingAction() throws {
        let message = try decode(
            #"{"type":"error","in_reply_to":"act_42","code":"internal_error","message":"model registry unavailable"}"#
        )
        XCTAssertEqual(message.inReplyTo, "act_42")
    }

    // MARK: - compaction

    /// Live shape (`index.ts:2346`) carries all three fields.
    func testLiveCompaction() throws {
        guard
            case .compaction(let payload) = try decode(
                #"{"type":"compaction","summary":"resumo","tokens_before":31000,"ts":1780000000000}"#
            )
        else { return XCTFail("not compaction") }
        XCTAssertEqual(payload.tokensBefore, 31000)
        XCTAssertEqual(payload.ts, 1_780_000_000_000)
    }

    /// TypeScript declares `summary` and `tokens_before` required; the Flutter
    /// parser tolerates both missing and the history variant genuinely omits
    /// `ts`. The lenient reading wins — a throw here would cost a system
    /// bubble over a field nothing renders.
    func testCompactionToleratesEveryFieldMissing() throws {
        guard case .compaction(let payload) = try decode(#"{"type":"compaction"}"#) else {
            return XCTFail("not compaction")
        }
        XCTAssertEqual(payload.summary, "")
        XCTAssertNil(payload.tokensBefore)
        XCTAssertNil(payload.ts)
    }

    // MARK: - forward compatibility (Trap T1)

    /// An unrecognised `type` must **not** throw out of the read loop.
    ///
    /// The Dart parser throws `UnsupportedTypeException` and the channel
    /// catches it (`peer_channel.dart:122-128`); an iOS decoder that let the
    /// throw escape would kill the connection on the first field a newer Pi
    /// adds. Pinned to `app/test/protocol_test.dart` → "thrown for unknown
    /// type" / "thrown for null type", inverted: the frame survives instead.
    func testUnknownServerTypeBecomesUnknownRatherThanThrowing() throws {
        guard case .unknown(let type, let raw) = try decode(#"{"type":"future_type","x":1}"#)
        else { return XCTFail("expected .unknown") }
        XCTAssertEqual(type, "future_type")
        XCTAssertEqual(raw["x"]?.intValue, 1)
    }

    func testFrameWithNoTypeAtAllStillDecodes() throws {
        guard case .unknown(let type, _) = try decode(#"{"data":1}"#) else {
            return XCTFail("expected .unknown")
        }
        XCTAssertEqual(type, "")
    }

    func testNonJSONReturnsNilInsteadOfThrowing() {
        XCTAssertNil(ServerMessage.decodeLossy("not json"))
    }

    // MARK: - integer fidelity

    /// Epoch-ms timestamps must not degrade to `1.78e+12` on a re-encode.
    ///
    /// They survive a `Double` exactly, so the value would still compare equal
    /// — but the *rendering* changes, which matters for a packet dump and for
    /// any fixture-based comparison, and `Int64` is what both peers write.
    func testTimestampsStayIntegersThroughARoundTrip() throws {
        let message = try decode(
            #"{"type":"compaction","summary":"s","tokens_before":31000,"ts":1780000000000}"#)
        let text = try XCTUnwrap(String(data: WireJSON.encode(message), encoding: .utf8))
        XCTAssertTrue(text.contains("\"ts\":1780000000000"), text)
    }
}
