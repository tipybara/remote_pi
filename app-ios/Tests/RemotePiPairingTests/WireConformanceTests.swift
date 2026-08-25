import Foundation
import RemotePiProtocol
import XCTest

@testable import RemotePiPairing

/// Loader for the captured wire. See the copy in
/// `RemotePiProtocolTests/WireConformanceTests.swift` for the rationale.
enum CapturedWire {
    static let directory: URL =
        URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)
        .appendingPathComponent("wire", isDirectory: true)

    private static func wrapper(
        _ name: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> [String: Any] {
        let data = try Data(contentsOf: directory.appendingPathComponent("\(name).json"))
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any], file: file, line: line)
    }

    static func innerRaw(
        _ name: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> String {
        try XCTUnwrap(wrapper(name, file: file, line: line)["inner_raw"] as? String,
            "fixture \(name) is not an envelope", file: file, line: line)
    }

    static func inner(
        _ name: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> [String: Any] {
        try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(innerRaw(name).utf8)) as? [String: Any],
            file: file, line: line)
    }

    static func object(
        _ name: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> [String: Any] {
        let raw = try XCTUnwrap(wrapper(name, file: file, line: line)["raw"] as? String,
            file: file, line: line)
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
            file: file, line: line)
    }

    /// `pairing_qr.json` is not a wire frame — it is the QR text plus both
    /// spellings of the Pi key, recorded side by side.
    static func pairingQR(file: StaticString = #filePath, line: UInt = #line) throws
        -> (payload: String, urlSafe: String, standard: String)
    {
        let data = try Data(contentsOf: directory.appendingPathComponent("pairing_qr.json"))
        let record = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any], file: file, line: line)
        return (
            payload: try XCTUnwrap(record["payload"] as? String, file: file, line: line),
            urlSafe: try XCTUnwrap(record["epk_url_safe"] as? String, file: file, line: line),
            standard: try XCTUnwrap(record["peer_standard"] as? String, file: file, line: line)
        )
    }
}

/// Pairing conformance, pinned against a real `remotepi://pair` payload and
/// the frames a real pairing exchange produced.
final class WireConformanceTests: XCTestCase {

    // MARK: The QR

    /// The QR spells the Pi key url-safe and unpadded; the relay spells the
    /// same key standard and padded. Parsing must land on the bytes so nothing
    /// downstream can compare the two strings.
    ///
    /// Four prior regressions in the Dart client came from exactly this
    /// (`app/lib/data/transport/epk_encoding.dart`).
    func testQRPayloadParsesAndTheKeyRoundTripsToStandard() throws {
        let (payload, urlSafe, standard) = try CapturedWire.pairingQR()
        XCTAssertTrue(payload.hasPrefix("remotepi://pair?"))

        let parsed = try XCTUnwrap(PairingQRPayload.parse(payload))
        XCTAssertEqual(parsed.peer.wireValue, standard, "outbound spelling is standard, padded")
        XCTAssertEqual(parsed.peer.urlSafeValue, urlSafe, "storage spelling is url-safe, unpadded")
        XCTAssertNotEqual(urlSafe, standard, "the capture must exercise a key that differs")

        // A key parsed from the QR must be usable as an envelope destination
        // without any further conversion — the relay looks the raw string up
        // in a `HashMap` and does not normalize.
        let envelope = Envelope(peer: parsed.peer, room: parsed.room ?? .main, ct: "e30=")
        let encoded = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(envelope)) as? [String: Any]
        XCTAssertEqual(encoded?["peer"] as? String, standard)
    }

    /// The token is carried through **verbatim**. The Pi compares with `!==`
    /// against the string it issued, so re-encoding it — padding it,
    /// converting alphabets, round-tripping through `Data` — yields
    /// `token_unknown`, which reads like a stale QR.
    func testTokenIsCarriedVerbatim() throws {
        let (payload, _, _) = try CapturedWire.pairingQR()
        let parsed = try XCTUnwrap(PairingQRPayload.parse(payload))
        let request = try CapturedWire.inner("inner_pair_request")

        XCTAssertEqual(parsed.token, request["token"] as? String)
        XCTAssertEqual(parsed.tokenBytes?.count, 16)
        // The harness mints it with `randomBytes(16).toString("base64url")`,
        // so it is 22 unpadded url-safe characters.
        XCTAssertEqual(parsed.token.count, 22)
        XCTAssertFalse(parsed.token.contains("="))
        XCTAssertNotEqual(
            parsed.token, parsed.tokenBytes?.base64EncodedString(),
            "re-encoding would change the string the Pi compares against")
    }

    /// `rm` carries the Pi's live room, and the `pair_request` envelope must be
    /// addressed there. Since plan 61 it is a session UUID, not the
    /// 12-character digest the producer's doc comment still describes — so it
    /// must be treated as opaque.
    func testQRRoomIsTheLiveSessionRoom() throws {
        let (payload, _, _) = try CapturedWire.pairingQR()
        let parsed = try XCTUnwrap(PairingQRPayload.parse(payload))
        let room = try XCTUnwrap(parsed.room)
        XCTAssertEqual(room.rawValue.count, 36, "a session UUID, not a 12-char digest")
        XCTAssertEqual(
            room.rawValue, try CapturedWire.object("envelope_app_to_pi")["room"] as? String,
            "the pair_request and the chat both address the same room")
        XCTAssertEqual(room.rawValue, try CapturedWire.inner("inner_pair_ok")["room_id"] as? String)
    }

    // MARK: The exchange

    /// `inner_pair_request.json` — the frame this client must produce.
    func testPairRequestEncodesExactly() throws {
        let expected = try CapturedWire.inner("inner_pair_request")
        let request = PairRequest(
            id: try XCTUnwrap(expected["id"] as? String),
            token: try XCTUnwrap(expected["token"] as? String),
            deviceName: try XCTUnwrap(expected["device_name"] as? String)
        )
        let message = ClientMessage.pairRequest(request)
        let encoded = try JSONSerialization.jsonObject(with: try WireJSON.encode(message))
        XCTAssertEqual(encoded as? NSDictionary, expected as NSDictionary)
        XCTAssertEqual(Set(expected.keys), ["type", "id", "token", "device_name"])
    }

    /// `inner_pair_ok.json` — classified, and every plan-61 identity field
    /// read. The Flutter client drops four of these; this one must not.
    func testPairOkClassifiesAndSeedsTheRoomCache() throws {
        let json = try CapturedWire.inner("inner_pair_ok")
        guard case .pairOk(let ok) = InnerPairFrame.classify(
            Data(try CapturedWire.innerRaw("inner_pair_ok").utf8))
        else { return XCTFail("not pair_ok") }

        XCTAssertEqual(ok.roomID.rawValue, json["room_id"] as? String)
        XCTAssertFalse(ok.roomIDWasOmitted)
        XCTAssertEqual(ok.resolvedRoom(qrRoom: RoomID("ignored")), ok.roomID,
            "an explicit room_id wins over the QR hint")

        let meta = ok.roomMeta(qrRoom: nil)
        XCTAssertEqual(meta.roomID.rawValue, json["room_id"] as? String)
        XCTAssertEqual(meta.sessionID?.rawValue, json["session_id"] as? String)
        XCTAssertEqual(meta.workspacePath, json["workspace_path"] as? String)
        XCTAssertEqual(meta.name, json["display_name"] as? String)
        XCTAssertEqual(meta.nameRev, (json["name_rev"] as? NSNumber)?.int64Value)
        XCTAssertTrue(meta.hasStableIdentity, "keyed by session from the very first frame")
        XCTAssertFalse(meta.working)
        XCTAssertEqual(meta.startedAt, 0, "room started_at is the RELAY's clock, not the Pi's")
        XCTAssertEqual(ok.knownSessionStartedAt, (json["session_started_at"] as? NSNumber)?.int64Value)

        // The seed must agree with what the relay went on to announce for the
        // same room.
        let announced = try CapturedWire.object("room_announced")
        XCTAssertEqual(meta.roomID.rawValue, announced["room_id"] as? String)
        XCTAssertEqual(meta.sessionID?.rawValue, announced["session_id"] as? String)
        XCTAssertEqual(meta.workspacePath, announced["workspace_path"] as? String)
        XCTAssertEqual(meta.nameRev, (announced["name_rev"] as? NSNumber)?.int64Value)
    }

    /// `inner_pair_error.json` — the same token replayed. Consumed on first
    /// use, so a retry after a lost `pair_ok` fails rather than pairing twice.
    func testPairErrorClassifies() throws {
        let json = try CapturedWire.inner("inner_pair_error")
        guard case .pairError(let error) = InnerPairFrame.classify(
            Data(try CapturedWire.innerRaw("inner_pair_error").utf8))
        else { return XCTFail("not pair_error") }
        XCTAssertEqual(error.code.rawValue, json["code"] as? String)
        XCTAssertEqual(error.code.rawValue, "token_consumed")
        XCTAssertEqual(error.message, json["message"] as? String)
        XCTAssertEqual(error.inReplyTo, json["in_reply_to"] as? String)
    }

    /// The pairing inbound queue is unfiltered: ordinary chat traffic lands on
    /// it too, and must classify as ``InnerPairFrame/other(type:)`` rather than
    /// failing the pairing.
    func testChatTrafficDuringPairingIsNotAFailure() throws {
        for (name, type) in [
            ("inner_agent_chunk", "agent_chunk"),
            ("inner_models_list", "models_list"),
            ("inner_pong", "pong"),
        ] {
            guard case .other(let classified) = InnerPairFrame.classify(
                Data(try CapturedWire.innerRaw(name).utf8))
            else { return XCTFail("\(name) should classify as .other") }
            XCTAssertEqual(classified, type, name)
        }
        // Undecodable is `.other(nil)`, never a throw.
        guard case .other(let none) = InnerPairFrame.classify(Data("not json".utf8)) else {
            return XCTFail("undecodable should classify as .other")
        }
        XCTAssertNil(none)
    }
}
