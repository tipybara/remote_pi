import Foundation
import RemotePiProtocol
import XCTest

@testable import RemotePiTransport

/// Loader for the captured wire. See the copy in
/// `RemotePiProtocolTests/WireConformanceTests.swift` for the rationale.
enum CapturedWire {
    static let fixtures: URL =
        URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)

    static var directory: URL { fixtures.appendingPathComponent("wire", isDirectory: true) }

    /// The exact frame text of one fixture.
    static func raw(
        _ name: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> String {
        let data = try Data(contentsOf: directory.appendingPathComponent("\(name).json"))
        let wrapper = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any], file: file, line: line)
        return try XCTUnwrap(wrapper["raw"] as? String, file: file, line: line)
    }

    static func object(
        _ name: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> [String: Any] {
        try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(raw(name).utf8)) as? [String: Any],
            file: file, line: line)
    }

    /// One line of the full ordered capture.
    struct TranscriptFrame {
        let seq: Int
        /// `"<peer>/<room>"` of the connection this crossed, e.g. `"app/main"`.
        let label: String
        /// `"c2s"` (peer → relay) or `"s2c"` (relay → peer).
        let direction: String
        let text: String
    }

    /// Every frame recorded during the capture, in order.
    static func transcript(file: StaticString = #filePath, line: UInt = #line) throws
        -> [TranscriptFrame]
    {
        let text = try String(
            contentsOf: fixtures.appendingPathComponent("transcript.jsonl"), encoding: .utf8)
        return try text.split(separator: "\n").map { entry in
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(entry.utf8)) as? [String: Any],
                file: file, line: line)
            return TranscriptFrame(
                seq: (object["seq"] as? NSNumber)?.intValue ?? -1,
                label: object["label"] as? String ?? "",
                direction: object["dir"] as? String ?? "",
                text: object["text"] as? String ?? ""
            )
        }
    }
}

/// Transport-level conformance: the envelope/control discriminator and the
/// inbound room demux, replayed against the real capture.
final class WireConformanceTests: XCTestCase {

    // MARK: The discriminator

    /// **Every single frame the app received during the capture must
    /// classify.** Not one may fall through to ``RelayFrame/unknown``.
    ///
    /// This is the assertion the 395 encoder-vs-decoder tests could not make:
    /// it replays what a real relay actually sent, in order, including frames
    /// nobody wrote a fixture for.
    func testEveryInboundFrameInTheCaptureClassifies() throws {
        let inbound = try CapturedWire.transcript().filter {
            $0.direction == "s2c" && $0.label.hasPrefix("app/")
        }
        XCTAssertGreaterThan(inbound.count, 40, "the capture looks truncated")

        var envelopes = 0
        var controls = 0
        for frame in inbound {
            switch RelayFrame.classify(frame.text) {
            case .envelope: envelopes += 1
            case .control: controls += 1
            case .unknown:
                XCTFail("seq \(frame.seq) did not classify: \(frame.text.prefix(200))")
            }
        }
        XCTAssertGreaterThan(envelopes, 0)
        XCTAssertGreaterThan(controls, 0)
    }

    /// The discriminator is `peer` **and** `ct` together, not `peer` alone:
    /// `room_announced`, `room_ended`, `peer_online`, `peer_offline`,
    /// `transport_error` and `rooms` all carry a top-level `peer` too.
    func testControlFramesCarryingPeerAreNotMistakenForEnvelopes() throws {
        for name in [
            "room_announced", "room_ended", "peer_online", "peer_offline", "transport_error",
            "rooms_snapshot", "room_meta_updated_name",
        ] {
            XCTAssertNotNil(
                try CapturedWire.object(name)["peer"], "\(name) should carry a peer")
            guard case .control = RelayFrame.classify(try CapturedWire.raw(name)) else {
                return XCTFail("\(name) classified as something other than a control frame")
            }
        }
    }

    /// An envelope never carries `type`; a control frame never carries `ct`.
    func testEnvelopesClassifyAsEnvelopes() throws {
        for name in ["envelope_app_to_pi", "envelope_pi_to_app_rewritten"] {
            let json = try CapturedWire.object(name)
            XCTAssertNil(json["type"], "\(name)")
            guard case .envelope(let envelope) = RelayFrame.classify(try CapturedWire.raw(name))
            else { return XCTFail("\(name) did not classify as an envelope") }
            XCTAssertEqual(envelope.peer.wireValue, json["peer"] as? String)
            XCTAssertEqual(envelope.room.rawValue, json["room"] as? String)
        }
        for name in ["challenge", "presence_offline", "rooms_empty"] {
            XCTAssertNil(try CapturedWire.object(name)["ct"], "\(name)")
        }
    }

    /// The captured `room` key is always present — the relay serialises
    /// `OuterEnvelope` with no `skip_serializing_if`. ``ParsedFrame`` still
    /// tracks the absent case for a pre-plan-17 relay, so pin both.
    func testDeclaredRoomIsPresentOnEveryCapturedEnvelope() throws {
        for frame in try CapturedWire.transcript() where frame.direction == "s2c" {
            guard let parsed = ParsedFrame(frame.text), case .envelope = parsed.frame else {
                continue
            }
            XCTAssertNotNil(parsed.declaredRoom, "seq \(frame.seq): the relay omitted `room`")
        }
        // Legacy tolerance: no `room` key at all still parses, and routes
        // unconditionally.
        let legacy = ParsedFrame(#"{"peer":"\#(try samplePeer())","ct":"e30="}"#)
        XCTAssertNil(legacy?.declaredRoom)
        if case .envelope(let envelope) = legacy?.frame {
            XCTAssertEqual(envelope.room, .main, "the relay's own default")
        } else {
            XCTFail("legacy envelope did not classify")
        }
    }

    private func samplePeer() throws -> String {
        try XCTUnwrap(CapturedWire.object("room_announced")["peer"] as? String)
    }

    // MARK: Inbound room demux

    /// The demux, exercised with the real room ids from the capture.
    func testRoomDemuxAgainstTheCapturedRooms() throws {
        let chat = RoomID(
            try XCTUnwrap(CapturedWire.object("room_announced")["room_id"] as? String))
        let otherChat = RoomID(
            try XCTUnwrap(CapturedWire.object("room_ended")["room_id"] as? String))
        XCTAssertNotEqual(chat, otherChat, "the capture must contain two distinct chat rooms")

        XCTAssertTrue(shouldDeliverEnvelope(senderRoom: chat, activeRoom: chat))
        XCTAssertFalse(
            shouldDeliverEnvelope(senderRoom: otherChat, activeRoom: chat),
            "a chunk from a session the user left must not bleed into the open one")
        XCTAssertTrue(
            shouldDeliverEnvelope(senderRoom: .control, activeRoom: chat),
            "the machine gateway is exempt — without this, every control reply is dropped")
        XCTAssertTrue(
            shouldDeliverEnvelope(senderRoom: nil, activeRoom: chat),
            "a legacy sender with no `room` routes unconditionally")
    }

    /// **Empirical evidence for spec 09 D1 / T1.**
    ///
    /// The real `pi-extension` gateway writes `room: "ctrl"` on its reply — its
    /// OWN room — while the outer `room` names the DESTINATION's room. The app
    /// registers only `main`, so the relay finds no `(app, "ctrl")` key and
    /// answers the *gateway* with `transport_error`, which the gateway
    /// discards. Every control RPC then times out with the machine looking
    /// perfectly online.
    ///
    /// Spec 09 §7 D1 derived this by reading the three implementations and
    /// noted "no test covers it". These two fixtures are that exchange,
    /// captured off a live relay.
    ///
    /// The client-side consequence, which this suite cannot assert because the
    /// capability does not exist yet: a native client must hold a **second**
    /// authenticated socket whose `hello.room_id` is `"ctrl"`
    /// (spec 09 §9 T1 mitigation 1). ``RelayWebSocketTransport`` currently
    /// registers `main` only.
    func testGatewayRepliesAreAddressedToItsOwnRoomAndBounce() throws {
        let reply = try CapturedWire.object("control_reply_envelope_as_gateway_writes_it")
        XCTAssertEqual(
            reply["room"] as? String, RoomID.control.rawValue,
            "the gateway names its own room as the destination")

        let bounce = try CapturedWire.object("transport_error_gateway_reply_bounced")
        XCTAssertEqual(bounce["type"] as? String, "transport_error")
        XCTAssertEqual(bounce["reason"] as? String, "offline")
        XCTAssertEqual(bounce["room_id"] as? String, RoomID.control.rawValue)
        XCTAssertEqual(
            bounce["peer"] as? String, reply["peer"] as? String,
            "the relay reports the destination it could not reach: the app's own key")

        // The app registered `main`, which is what makes the lookup miss.
        XCTAssertEqual(try CapturedWire.object("hello_app")["room_id"] as? String, "main")
        XCTAssertEqual(
            try CapturedWire.object("hello_app")["pubkey"] as? String, bounce["peer"] as? String)

        // Correlating by `in_reply_to` rather than by room is what makes a
        // client survive the eventual fix (spec 09 T1 mitigation 2).
        XCTAssertNotNil(bounce["peer"])
    }

    // MARK: Envelope size

    /// The relay measures the Base64 STRING, not the decoded bytes. A local
    /// pre-flight that measured the real payload would disagree at the
    /// boundary and let a frame through that the relay drops in silence.
    func testSizeCeilingUsesTheRelaysOwnArithmetic() throws {
        guard case .envelope(let envelope) = RelayFrame.classify(
            try CapturedWire.raw("envelope_app_to_pi"))
        else { return XCTFail("not an envelope") }

        XCTAssertEqual(envelope.relayEstimatedPayloadBytes, envelope.ct.utf8.count * 3 / 4)
        XCTAssertFalse(envelope.exceedsRelayLimit())

        // The boundary itself, with the relay's integer division.
        let atLimit = Envelope(
            peer: envelope.peer, room: envelope.room,
            ct: String(repeating: "A", count: (Envelope.maxDecodedPayloadBytes * 4) / 3))
        XCTAssertFalse(atLimit.exceedsRelayLimit())
        let overLimit = Envelope(
            peer: envelope.peer, room: envelope.room,
            ct: String(repeating: "A", count: (Envelope.maxDecodedPayloadBytes * 4) / 3 + 4))
        XCTAssertTrue(overLimit.exceedsRelayLimit())
    }
}
