import Foundation
import XCTest

@testable import RemotePiProtocol

/// Smoke tests over the cross-module vocabulary. Not coverage — these pin the
/// handful of rules that have actually broken in production before.
final class SeamTests: XCTestCase {
    /// 32 bytes of 0xFB — the fixture `relay/src/identity.rs` uses, chosen
    /// because it produces `+` and `/` in standard Base64 and `-` and `_` in
    /// URL-safe, so the two spellings are visibly different.
    private let keyBytes = Data(repeating: 0xFB, count: 32)
    private let standardKey = "+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/s="
    private let urlSafeKey = "-_v7-_v7-_v7-_v7-_v7-_v7-_v7-_v7-_v7-_v7-_s"

    func testAllFourBase64SpellingsParseToTheSameKey() throws {
        let spellings = [
            standardKey,
            String(standardKey.dropLast()),  // standard, unpadded
            urlSafeKey + "=",  // url-safe, padded
            urlSafeKey,
        ]
        for spelling in spellings {
            let peer = try XCTUnwrap(PeerID(base64: spelling), "failed on \(spelling)")
            XCTAssertEqual(peer.rawValue, keyBytes)
            XCTAssertEqual(peer.wireValue, standardKey)
            XCTAssertEqual(peer.urlSafeValue, urlSafeKey)
        }
    }

    func testMixedAlphabetIsRejected() {
        // The relay refuses this; so must we, or we would send it a key it
        // will not accept and get a silent close.
        XCTAssertNil(PeerID(base64: standardKey.replacingOccurrences(of: "+", with: "-")))
    }

    func testWrongLengthAndGarbageAreRejected() {
        XCTAssertNil(PeerID(base64: Data(repeating: 7, count: 31).base64EncodedString()))
        XCTAssertNil(PeerID(base64: standardKey + "garbage"))
        XCTAssertNil(PeerID(base64: standardKey + "\n"))
        XCTAssertNil(PeerID(base64: ""))
    }

    func testCodableAlwaysEncodesTheWireSpelling() throws {
        // A key that entered from a QR code must not leak its URL-safe form
        // onto the wire.
        let peer = try XCTUnwrap(PeerID(base64: urlSafeKey))
        let encoder = JSONEncoder()
        // `JSONEncoder` escapes `/` as `\/` unless told otherwise. That is legal
        // JSON and `serde_json` parses it, so it is harmless in a frame — but it
        // is NOT harmless in `MeshBlob.canonicalBytes()`, where the bytes are
        // signed and the Rust side does not escape. Hence the explicit option
        // here and the hand-rolled serializer there.
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let encoded = try encoder.encode(peer)
        XCTAssertEqual(String(data: encoded, encoding: .utf8), "\"\(standardKey)\"")

        let round = try JSONDecoder().decode(PeerID.self, from: try JSONEncoder().encode(peer))
        XCTAssertEqual(round, peer, "the escaped form must still round-trip")
    }

    func testEnvelopeDefaultsMissingRoomToMain() throws {
        let json = #"{"peer":"\#(standardKey)","ct":"AAA="}"#
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(json.utf8))
        XCTAssertEqual(envelope.room, .main)
    }

    func testEnvelopeSizeEstimateMatchesTheRelayArithmetic() {
        let peer = PeerID(rawValue: keyBytes)!
        let envelope = Envelope(peer: peer, room: .main, ct: String(repeating: "A", count: 8))
        XCTAssertEqual(envelope.relayEstimatedPayloadBytes, 6)  // 8 * 3 / 4
        XCTAssertFalse(envelope.exceedsRelayLimit())
        XCTAssertTrue(envelope.exceedsRelayLimit(4))
    }

    func testNameRevGateIsStrictlyGreater() {
        let patch = RoomMetaPatch(name: .set("renamed"), nameRev: 100)
        XCTAssertTrue(patch.nameAccepted(over: 99))
        XCTAssertFalse(patch.nameAccepted(over: 100), "equal revision is a replay")
        XCTAssertFalse(patch.nameAccepted(over: 101))
        XCTAssertTrue(patch.nameAccepted(over: nil), "no stored revision → trust")

        let revOnly = RoomMetaPatch(nameRev: 100)
        XCTAssertFalse(revOnly.nameAccepted(over: nil), "a revision alone is not a rename")
        XCTAssertTrue(revOnly.isEmpty)
    }

    func testPatchDistinguishesAbsentFromExplicitNull() {
        var meta = RoomMeta(roomID: RoomID("r"), model: "sonnet", thinking: "high")

        RoomMetaPatch(model: .absent).apply(to: &meta)
        XCTAssertEqual(meta.model, "sonnet", "absent must preserve")

        RoomMetaPatch(model: .clear).apply(to: &meta)
        XCTAssertNil(meta.model, "explicit null must clear")
        XCTAssertEqual(meta.thinking, "high", "a model patch must not touch thinking")
    }

    func testWorkingHasNoNullState() {
        var meta = RoomMeta(roomID: RoomID("r"), working: true)
        RoomMetaPatch().apply(to: &meta)
        XCTAssertTrue(meta.working, "absent working preserves")
        RoomMetaPatch(working: false).apply(to: &meta)
        XCTAssertFalse(meta.working)
    }

    func testRoomAnnouncedParsesFlatAndNested() throws {
        let flat: [String: Any] = [
            "type": "room_announced",
            "peer": standardKey,
            "room_id": "019ffb64-aaaa-7bbb-8ccc-ddddeeeeffff",
            "session_id": "019ffb64-aaaa-7bbb-8ccc-ddddeeeeffff",
            "workspace_path": "/Users/x/proj",
            "name": "backend",
            "name_rev": 1_780_000_000_000,
            "working": false,
            "started_at": 1_780_000_000_123,
        ]
        guard case .roomAnnounced(_, let meta)? = ControlFrame.parse(flat) else {
            return XCTFail("flat announcement did not parse")
        }
        XCTAssertEqual(meta.sessionID?.rawValue, meta.roomID.rawValue)
        XCTAssertTrue(meta.hasStableIdentity)
        XCTAssertEqual(meta.nameRev, 1_780_000_000_000)

        let nested: [String: Any] = [
            "type": "room_announced",
            "peer": standardKey,
            "room_id": "abc123def456",
            "meta": ["cwd": "/Users/x/legacy", "working": true],
            "started_at": 1,
        ]
        guard case .roomAnnounced(_, let legacy)? = ControlFrame.parse(nested) else {
            return XCTFail("nested announcement did not parse")
        }
        XCTAssertFalse(legacy.hasStableIdentity, "no session_id → legacy room")
        XCTAssertEqual(legacy.effectiveWorkspacePath, "/Users/x/legacy")
        XCTAssertTrue(legacy.working)
    }

    func testControlRoomIsNeverAChatTile() {
        let meta = RoomMeta(roomID: .control, role: RoomRole.control.rawValue)
        XCTAssertTrue(meta.isControlRoom)
        XCTAssertFalse(RoomID.control.hasSessionIDShape, "ctrl must not look like a session id")
        XCTAssertTrue(RoomID("019ffb64-aaaa-7bbb-8ccc-ddddeeeeffff").hasSessionIDShape)
    }

    func testTransportErrorParses() {
        let json: [String: Any] = [
            "type": "transport_error",
            "reason": "offline",
            "peer": standardKey,
            "room_id": "019ffb64",
        ]
        guard case .transportError(_, let room, let reason)? = ControlFrame.parse(json) else {
            return XCTFail("transport_error did not parse")
        }
        XCTAssertEqual(room.rawValue, "019ffb64")
        XCTAssertEqual(reason, "offline")
    }

    func testUnknownControlFrameIsDroppedNotThrown() {
        XCTAssertNil(ControlFrame.parse(["type": "something_from_a_newer_relay"]))
    }

    func testMutatingControlActionsCarryAnIdempotencyKey() throws {
        let action = ControlAction.createSession(
            id: RequestID("rpc-1"),
            idempotencyKey: IdempotencyKey("idem-1"),
            workspace: WorkspaceID("ws_abc123"),
            displayName: nil
        )
        let object = action.jsonObject
        XCTAssertEqual(object["type"] as? String, "create_session")
        XCTAssertEqual(object["idempotency_key"] as? String, "idem-1")
        XCTAssertEqual(object["background"] as? Bool, true)
        XCTAssertNil(object["display_name"], "absent, not empty string")
    }

    func testControlReplyParses() throws {
        let json: [String: Any] = [
            "type": "action_ok",
            "in_reply_to": "rpc-1",
            "action": "create_session",
            "session_id": "019ffb64",
            "workspace_id": "ws_abc123",
        ]
        guard case .ok(let success)? = ControlReply.parse(json) else {
            return XCTFail("action_ok did not parse")
        }
        XCTAssertEqual(success.inReplyTo.rawValue, "rpc-1")
        XCTAssertEqual(success.action, "create_session")
        XCTAssertEqual(success.session?.rawValue, "019ffb64")
        XCTAssertEqual(success.workspace?.rawValue, "ws_abc123")
    }

    func testMeshCanonicalBytesAreSortedCompactAndOmitNilNickname() throws {
        let owner = try XCTUnwrap(PeerID(rawValue: keyBytes))
        let blob = MeshBlob(
            version: 7,
            issuedAt: 1_780_000_000_000,
            ownerPk: owner,
            members: [
                MeshMember(
                    remoteEpk: owner,
                    relayURL: "wss://relay.example",
                    pairedAt: "2026-05-22T00:00:00Z",
                    nickname: nil
                )
            ]
        )
        let text = try XCTUnwrap(String(data: blob.canonicalBytes(), encoding: .utf8))
        XCTAssertEqual(
            text,
            "{\"issued_at\":1780000000000,"
                + "\"members\":[{\"paired_at\":\"2026-05-22T00:00:00Z\","
                + "\"relay_url\":\"wss://relay.example\","
                + "\"remote_epk\":\"\(standardKey)\"}],"
                + "\"owner_pk\":\"\(standardKey)\","
                + "\"version\":7}"
        )
        XCTAssertFalse(text.contains("nickname"), "a nil nickname is absent, not null")
        XCTAssertFalse(text.contains(" "), "canonical form carries no whitespace")

        let round = try MeshBlob.parse(blob.canonicalBytes())
        XCTAssertEqual(round, blob)
    }

    func testSessionKeyIsFilesystemSafe() throws {
        let peer = try XCTUnwrap(PeerID(rawValue: keyBytes))
        let key = SessionKey(peer: peer, room: RoomID("019ffb64"))
        XCTAssertFalse(key.storageKey.contains("/"), "standard base64 would embed a path separator")
    }
}
