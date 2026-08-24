import Foundation
import XCTest

@testable import RemotePiProtocol

/// App → Pi encoders, pinned against the JSON the Dart client actually emits
/// (`app/lib/protocol/protocol.dart` `toJson`) and against the archived
/// contract fixtures in `.orchestration/contracts/fixtures/*.jsonl`.
///
/// A test that only round-trips this encoder through this decoder proves
/// nothing; every assertion below names the producer it is pinned to.
final class ClientMessageWireTests: XCTestCase {

    // MARK: - user_message

    /// Fixture: `.orchestration/contracts/fixtures/user_message.jsonl`.
    func testUserMessageOmitsBothOptionalKeysWhenUnset() throws {
        let message = ClientMessage.userMessage(
            UserMessage(
                id: "018f9c2a-7b1e-7000-9a3b-1c2d3e4f5a6e",
                text: "por que o token expira antes da hora?"
            ))
        try WireFixtures.assertEncodes(
            message,
            to: #"""
                {"type":"user_message","id":"018f9c2a-7b1e-7000-9a3b-1c2d3e4f5a6e",
                 "text":"por que o token expira antes da hora?"}
                """#,
            "protocol.dart:637-645 writes streaming_behavior and images only when set"
        )
    }

    /// An empty image list must not become `"images": []`.
    ///
    /// `protocol.dart:643` guards on `images != null && images!.isNotEmpty`.
    /// A Pi that sees `images: []` builds an SDK message with an empty content
    /// array rather than a plain text block.
    func testUserMessageDropsAnEmptyImageArray() throws {
        let message = ClientMessage.userMessage(
            UserMessage(id: "cli_1", text: "hi", images: []))
        let encoded = try WireFixtures.encoded(message)
        XCTAssertNil(encoded["images"])
    }

    /// Spec 01 §3.2. `data` is bare base64 with **no** `data:` URI prefix, and
    /// the key is `mime`, not `mimeType` — the Pi remaps it on the way to the
    /// SDK (`index.ts:711-720`).
    func testUserMessageWithSteerAndImage() throws {
        let message = ClientMessage.userMessage(
            UserMessage(
                id: "cli_019f",
                text: "run the tests",
                streamingBehavior: .steer,
                images: [WireImage(data: "/9j/4AAQ", mime: "image/jpeg")]
            ))
        try WireFixtures.assertEncodes(
            message,
            to: #"""
                {"type":"user_message","id":"cli_019f","text":"run the tests",
                 "streaming_behavior":"steer",
                 "images":[{"data":"/9j/4AAQ","mime":"image/jpeg"}]}
                """#
        )
    }

    /// The open-union structs must code as bare strings.
    ///
    /// A `RawRepresentable` struct gets memberwise `Codable` synthesis unless
    /// told otherwise, which would put `"streaming_behavior":{"rawValue":"steer"}`
    /// on the wire — legal JSON, accepted by nobody, and invisible because
    /// encoding never fails.
    func testOpenUnionsCodeAsBareStrings() throws {
        let encoded = try WireFixtures.encoded(
            ClientMessage.userMessage(
                UserMessage(id: "x", text: "", streamingBehavior: .steer)))
        XCTAssertEqual(encoded["streaming_behavior"] as? String, "steer")
    }

    // MARK: - queued messages

    /// Pinned to `app/test/protocol_test.dart` → "encodes targeted clear".
    func testQueuedMessageClearOmitsTargetIDWhenClearingEverything() throws {
        try WireFixtures.assertEncodes(
            ClientMessage.queuedMessageClear(QueuedMessageClear(id: "req1", targetID: "q1")),
            to: #"{"type":"queued_message_clear","id":"req1","target_id":"q1"}"#)
        try WireFixtures.assertEncodes(
            ClientMessage.queuedMessageClear(QueuedMessageClear(id: "req2")),
            to: #"{"type":"queued_message_clear","id":"req2"}"#,
            "an omitted target_id clears the WHOLE queue (index.ts:4037)")
    }

    func testQueuedMessageSet() throws {
        try WireFixtures.assertEncodes(
            ClientMessage.queuedMessageSet(QueuedMessageSet(id: "cli_2", text: "then push")),
            to: #"{"type":"queued_message_set","id":"cli_2","text":"then push"}"#)
    }

    // MARK: - simple frames

    /// Fixtures: `cancel.jsonl`, `ping.jsonl`, `session_sync.jsonl`,
    /// `pair_request.jsonl`.
    func testSimpleFramesMatchTheArchivedFixtures() throws {
        try WireFixtures.assertEncodes(
            ClientMessage.cancel(
                Cancel(
                    id: "018f9c2d-7b1e-7000-9a3b-1c2d3e4f5a72",
                    targetID: "018f9c2a-7b1e-7000-9a3b-1c2d3e4f5a6e")),
            to: #"""
                {"type":"cancel","id":"018f9c2d-7b1e-7000-9a3b-1c2d3e4f5a72",
                 "target_id":"018f9c2a-7b1e-7000-9a3b-1c2d3e4f5a6e"}
                """#)

        try WireFixtures.assertEncodes(
            ClientMessage.ping(id: "018f9c2e-7b1e-7000-9a3b-1c2d3e4f5a73"),
            to: #"{"type":"ping","id":"018f9c2e-7b1e-7000-9a3b-1c2d3e4f5a73"}"#)

        try WireFixtures.assertEncodes(
            ClientMessage.sessionSync(
                SessionSync(id: "018f9c5a-0000-7000-9a3b-1c2d3e4f5c01", limit: 30)),
            to: #"{"type":"session_sync","id":"018f9c5a-0000-7000-9a3b-1c2d3e4f5c01","limit":30}"#)

        try WireFixtures.assertEncodes(
            ClientMessage.sessionSync(SessionSync(id: "cli_9")),
            to: #"{"type":"session_sync","id":"cli_9"}"#,
            "the Flutter client omits limit entirely (sync_service.dart:381)")

        try WireFixtures.assertEncodes(
            ClientMessage.pairRequest(
                PairRequest(
                    id: "018f9c3a-0000-7000-9a3b-1c2d3e4f5a01",
                    token: "qBcD3fG4h5J6k7L8m9N0pQ",
                    deviceName: "iPhone do Jacob")),
            to: #"""
                {"type":"pair_request","id":"018f9c3a-0000-7000-9a3b-1c2d3e4f5a01",
                 "token":"qBcD3fG4h5J6k7L8m9N0pQ","device_name":"iPhone do Jacob"}
                """#)
    }

    /// Fixture: `approve_tool.jsonl`.
    ///
    /// The frame must still *decode* — a captured log or a fixture from the
    /// Flutter app contains them — but nothing in this client should ever build
    /// one: the Pi drops it silently and never replies (`index.ts:4100-4104`),
    /// so awaiting an answer hangs forever.
    func testApproveToolDecodesEvenThoughItIsNeverSent() throws {
        let line =
            #"{"type":"approve_tool","id":"018f9c2c-7b1e-7000-9a3b-1c2d3e4f5a70","tool_call_id":"tc_018f9c2b","decision":"deny"}"#
        let message = try WireJSON.decode(ClientMessage.self, from: line)
        guard case .approveTool(let payload) = message else {
            return XCTFail("approve_tool did not decode")
        }
        XCTAssertEqual(payload.toolCallID, "tc_018f9c2b")
        XCTAssertEqual(payload.decision, .deny)
        try WireFixtures.assertEncodes(message, to: line)
    }

    // MARK: - typed session actions

    func testTypedActionsMatchTheDartEncoders() throws {
        try WireFixtures.assertEncodes(
            ClientMessage.sessionNew(id: "act_1"),
            to: #"{"type":"session_new","id":"act_1"}"#)
        try WireFixtures.assertEncodes(
            ClientMessage.sessionCompact(id: "act_2"),
            to: #"{"type":"session_compact","id":"act_2"}"#)
        try WireFixtures.assertEncodes(
            ClientMessage.listModels(id: "act_3"),
            to: #"{"type":"list_models","id":"act_3"}"#)
        try WireFixtures.assertEncodes(
            ClientMessage.modelSet(
                ModelSet(id: "act_4", provider: "anthropic", modelID: "claude-opus-4-7")),
            to: #"""
                {"type":"model_set","id":"act_4","provider":"anthropic",
                 "model_id":"claude-opus-4-7"}
                """#)
        try WireFixtures.assertEncodes(
            ClientMessage.thinkingSet(ThinkingSet(id: "act_5", level: .xhigh)),
            to: #"{"type":"thinking_set","id":"act_5","level":"xhigh"}"#)
    }

    /// Spec 01 §4.3. `rev` is the revision this device last **saw**, and both
    /// `session_id` and `rev` are optional on the wire but always sent.
    func testSessionRenameCarriesSessionIDAndRev() throws {
        try WireFixtures.assertEncodes(
            ClientMessage.sessionRename(
                SessionRename(
                    id: "act_6",
                    displayName: "backend",
                    sessionID: SessionID("019ffb64-1c3e-7a91-b0d2-6f2a1c9e77aa"),
                    rev: 1_780_000_000_000)),
            to: #"""
                {"type":"session_rename","id":"act_6","display_name":"backend",
                 "session_id":"019ffb64-1c3e-7a91-b0d2-6f2a1c9e77aa","rev":1780000000000}
                """#)

        let bare = try WireFixtures.encoded(
            ClientMessage.sessionRename(SessionRename(id: "act_7", displayName: "x")))
        XCTAssertNil(bare["session_id"])
        XCTAssertNil(bare["rev"], "absent, never null — the Pi's gate reads presence")
    }

    /// `rev` must survive as a JSON integer. Epoch-ms revisions round-trip
    /// exactly through a `Double`, but re-encode as `1.78e+12`, and the Pi
    /// compares them with `<` against its own integer clock.
    func testNameRevStaysAnInteger() throws {
        let encoded = try WireJSON.encode(
            ClientMessage.sessionRename(
                SessionRename(id: "a", displayName: "n", rev: 1_780_000_000_001)))
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertTrue(text.contains("\"rev\":1780000000001"), text)
    }

    // MARK: - machine control plane (room `ctrl`)

    /// Spec 01 §5 / `protocol.dart:961-989`. `background: true` is always
    /// written; `display_name` is omitted rather than sent empty.
    func testCreateSessionAlwaysWritesBackgroundTrue() throws {
        try WireFixtures.assertEncodes(
            ClientMessage.control(
                .createSession(
                    id: RequestID("ctl_1"),
                    idempotencyKey: IdempotencyKey("idem-1"),
                    workspace: WorkspaceID("a1b2c3d4"),
                    displayName: "backend")),
            to: #"""
                {"type":"create_session","id":"ctl_1","idempotency_key":"idem-1",
                 "workspace_id":"a1b2c3d4","display_name":"backend","background":true}
                """#)

        let unnamed = try WireFixtures.encoded(
            ClientMessage.control(
                .createSession(
                    id: RequestID("ctl_2"),
                    idempotencyKey: IdempotencyKey("idem-2"),
                    workspace: WorkspaceID("a1b2c3d4"),
                    displayName: nil)))
        XCTAssertNil(unnamed["display_name"])
        XCTAssertEqual(unnamed["background"] as? Bool, true)
    }

    func testSessionStartStopAndListShapes() throws {
        try WireFixtures.assertEncodes(
            ClientMessage.control(
                .sessionStart(
                    id: RequestID("ctl_3"),
                    session: SessionID("019ffb64"),
                    idempotencyKey: IdempotencyKey("idem-3"))),
            to: #"""
                {"type":"session_start","id":"ctl_3","session_id":"019ffb64",
                 "idempotency_key":"idem-3"}
                """#)
        try WireFixtures.assertEncodes(
            ClientMessage.control(
                .sessionStop(
                    id: RequestID("ctl_4"),
                    session: SessionID("019ffb64"),
                    idempotencyKey: IdempotencyKey("idem-4"))),
            to: #"""
                {"type":"session_stop","id":"ctl_4","session_id":"019ffb64",
                 "idempotency_key":"idem-4"}
                """#)
        try WireFixtures.assertEncodes(
            ClientMessage.control(.workspaceList(id: RequestID("ctl_5"))),
            to: #"{"type":"workspace_list","id":"ctl_5"}"#)
        try WireFixtures.assertEncodes(
            ClientMessage.control(.sessionList(id: RequestID("ctl_6"), workspace: nil)),
            to: #"{"type":"session_list","id":"ctl_6"}"#,
            "an absent filter must not become workspace_id: \"\"")
        try WireFixtures.assertEncodes(
            ClientMessage.control(
                .sessionList(id: RequestID("ctl_7"), workspace: WorkspaceID("a1b2c3d4"))),
            to: #"{"type":"session_list","id":"ctl_7","workspace_id":"a1b2c3d4"}"#)
    }

    /// `control_wire.ts:107-113`: an explicit `background: false` is a parse
    /// **error**, not something to coerce to `true`. Reproduced here so this
    /// client cannot construct a frame the gateway will reject and then be
    /// surprised by the `action_error`.
    func testCreateSessionWithExplicitBackgroundFalseIsRefused() {
        let frame = #"""
            {"type":"create_session","id":"ctl_1","idempotency_key":"k",
             "workspace_id":"w","background":false}
            """#
        XCTAssertThrowsError(try WireJSON.decode(ControlAction.self, from: frame))
    }

    /// `control_wire.ts:88`: a mutating action with no `idempotency_key` is
    /// refused rather than defaulted. A per-attempt default deduplicates
    /// nothing — a phone retrying over a flaky link would spawn a process per
    /// attempt.
    func testMutatingControlActionsRequireAnIdempotencyKey() {
        for type in ["create_session", "session_start", "session_stop"] {
            let frame = #"{"type":"\#(type)","id":"ctl_1","workspace_id":"w","session_id":"s"}"#
            XCTAssertThrowsError(
                try WireJSON.decode(ControlAction.self, from: frame),
                "\(type) accepted a frame with no idempotency_key")
        }
    }

    /// `control_wire.ts:62-66`: `id` is trimmed and must be non-empty.
    func testWhitespaceOnlyRequestIDIsRefused() {
        XCTAssertThrowsError(
            try WireJSON.decode(
                ControlAction.self, from: #"{"type":"workspace_list","id":"   "}"#))
    }

    // MARK: - forward compatibility

    func testUnknownClientTypeDecodesInsteadOfThrowing() throws {
        let line = #"{"type":"something_new","id":"x","extra":{"a":1}}"#
        let message = try WireJSON.decode(ClientMessage.self, from: line)
        guard case .unknown(let type, _) = message else {
            return XCTFail("expected .unknown, got \(message)")
        }
        XCTAssertEqual(type, "something_new")
        try WireFixtures.assertEncodes(message, to: line, "an unknown frame survives verbatim")
    }

    // MARK: - envelope integration

    /// The full outbound path: inner JSON → standard base64 → `{peer, room, ct}`.
    ///
    /// URL-safe base64 in `ct` would survive (the Pi's `Buffer.from(ct,
    /// "base64")` is lenient), but URL-safe in `peer` is a `transport_error:
    /// offline` against a Pi that is perfectly online — the relay uses that
    /// string as a raw HashMap key with no normalization
    /// (`registry.rs:254`).
    func testEnvelopeCarriesStandardBase64AndNoTypeKey() throws {
        let envelope = try Envelope(
            peer: WireFixtures.peer,
            room: RoomID("019ffb64-1c3e-7a91-b0d2-6f2a1c9e77aa"),
            message: .ping(id: "ping_7"))

        let wire = try WireFixtures.encoded(envelope)
        XCTAssertEqual(wire["peer"] as? String, WireFixtures.peerKeyStandard)
        XCTAssertEqual(wire["room"] as? String, "019ffb64-1c3e-7a91-b0d2-6f2a1c9e77aa")
        XCTAssertNil(
            wire["type"],
            "a top-level `type` makes the relay treat the envelope as a control frame "
                + "and drop it with no error to the sender (peer.rs:211)")

        // Compared as parsed objects, not as text: key order is not part of
        // the wire contract (see `WireFixtures`), and `JSONEncoder` does not
        // emit a keyed container in insertion order. What matters is that the
        // inner frame carries exactly `type` and `id` and nothing else.
        let inner = try XCTUnwrap(envelope.payload)
        XCTAssertEqual(
            try XCTUnwrap(JSONSerialization.jsonObject(with: inner) as? NSDictionary),
            try WireFixtures.object(#"{"type":"ping","id":"ping_7"}"#))
    }

    /// A control action always addresses ``RoomID/control``.
    func testControlEnvelopeTargetsTheCtrlRoom() throws {
        let envelope = try Envelope(
            peer: WireFixtures.peer, action: .workspaceList(id: RequestID("ctl_1")))
        XCTAssertEqual(envelope.room, .control)
        XCTAssertFalse(
            RoomID.control.hasSessionIDShape,
            "`ctrl` must be unable to collide with a session-derived room id")
    }
}
