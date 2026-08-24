import Foundation
import XCTest

@testable import RemotePiPairing
@testable import RemotePiProtocol

/// Byte-level agreement with `pi-extension/src/index.ts:1857-2060` and
/// `app/lib/pairing/pair_request_flow.dart`.
///
/// The frame types themselves live in `RemotePiProtocol`; what is pinned here
/// is what *pairing* does with them — the exact request bytes, and the
/// absent-vs-explicit rules that decide which room the client will address for
/// the rest of the pairing's life.
final class PairFrameWireTests: XCTestCase {
    private func decodePairOk(_ json: [String: Any]) throws -> PairOk {
        let data = try JSONSerialization.data(withJSONObject: json)
        guard case .pairOk(let ok) = try JSONDecoder().decode(ServerMessage.self, from: data)
        else { throw XCTSkip("not a pair_ok") }
        return ok
    }

    // MARK: - pair_request

    func testPairRequestIsExactlyFourFields() throws {
        let request = PairRequest(
            id: "019ffb64-3c21-7a55-9b0e-2f7d1c4a88e1",
            token: "Zm9vYmFyYmF6cXV4MTIzNA",
            deviceName: "iPhone"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(ClientMessage.pairRequest(request))
        XCTAssertEqual(
            String(data: bytes, encoding: .utf8),
            #"{"device_name":"iPhone","id":"019ffb64-3c21-7a55-9b0e-2f7d1c4a88e1","token":"Zm9vYmFyYmF6cXV4MTIzNA","type":"pair_request"}"#
        )

        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        )
        // D1: `PROTOCOL.md:325` describes an Owner-signed pair_request. The
        // wire type has never carried a signature — authenticity comes from
        // the relay challenge on the same socket, and from the Pi reading
        // `outer.peer` as the relay rewrote it. A client that waited for the
        // Pi to verify a `sig` here would wait forever.
        XCTAssertEqual(Set(object.keys), ["type", "id", "token", "device_name"])
    }

    func testTokenIsEchoedVerbatimNotReEncoded() throws {
        // `qr.ts:46` compares with `!==`. Padding the base64url token, or
        // round-tripping it through Data, produces `token_unknown` — which
        // looks exactly like a stale QR and sends the user off to generate a
        // new one that will fail the same way.
        let qr = try XCTUnwrap(
            PairingQRPayload.parse(
                "remotepi://pair?t=Zm9vYmFyYmF6cXV4MTIzNA"
                    + "&epk=1sbg3nsX4kRTBmM3XZ_hs4mAujHmbcm7CjfPGkDgpTQ&n=remote_pi"
            )
        )
        let bytes = try JSONEncoder().encode(
            ClientMessage.pairRequest(
                PairRequest(id: "x", token: qr.token, deviceName: "iPhone")
            )
        )
        let object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        XCTAssertEqual(object["token"] as? String, "Zm9vYmFyYmF6cXV4MTIzNA")
    }

    // MARK: - pair_ok

    /// The full plan-61 reply from spec 62/04 §7, field for field.
    private let pairOkJSON: [String: Any] = [
        "type": "pair_ok",
        "in_reply_to": "019ffb64-3c21-7a55-9b0e-2f7d1c4a88e1",
        "session_name": "remote_pi",
        "session_started_at": 1_780_000_000_000,
        "room_id": "019ffb64-1111-7a55-9b0e-2f7d1c4a88e1",
        "session_id": "019ffb64-1111-7a55-9b0e-2f7d1c4a88e1",
        "workspace_path": "/Users/jacob/Projects/remote_pi",
        "display_name": "remote_pi",
        "name_rev": 1_780_000_000_000,
        "harness": ["name": "Pi coding agent", "version": "0.9.3"],
        "hostname": "jacobs-mbp.local",
    ]

    /// D2: the Flutter `PairOk` drops `session_id`, `workspace_path`,
    /// `display_name` and `name_rev` and recovers them from a later
    /// `room_announced`. A native client keys by session from the first frame.
    func testPairOkSeedsTheRoomCache() throws {
        let ok = try decodePairOk(pairOkJSON)
        let meta = ok.roomMeta(qrRoom: RoomID("stale-room-from-the-qr"))
        XCTAssertEqual(meta.roomID.rawValue, "019ffb64-1111-7a55-9b0e-2f7d1c4a88e1")
        XCTAssertEqual(meta.sessionID?.rawValue, "019ffb64-1111-7a55-9b0e-2f7d1c4a88e1")
        XCTAssertTrue(meta.hasStableIdentity)
        XCTAssertEqual(meta.workspacePath, "/Users/jacob/Projects/remote_pi")
        XCTAssertEqual(meta.nameRev, 1_780_000_000_000)
        XCTAssertEqual(meta.name, "remote_pi")
        // Not carried by pair_ok, and `started_at` in room meta is the relay's
        // registration instant — a different clock from `session_started_at`.
        XCTAssertEqual(meta.startedAt, 0)
        XCTAssertFalse(meta.working)
        XCTAssertEqual(ok.knownSessionStartedAt, 1_780_000_000_000)
    }

    /// The legacy reply the Flutter suite still exercises
    /// (`app/test/pairing/pair_request_flow_test.dart:100-108`): three fields,
    /// no room.
    func testLegacyPairOkWithoutRoomFallsBackToTheQRRoom() throws {
        let ok = try decodePairOk([
            "type": "pair_ok", "in_reply_to": "abc", "session_name": "Pi",
        ])
        XCTAssertTrue(ok.roomIDWasOmitted, "absent must stay distinguishable from \"main\"")
        XCTAssertNil(ok.sessionID, "no session_id ⇒ legacy room, keyed by room_id")
        XCTAssertNil(ok.knownSessionStartedAt)
        // Trap T5, precedence spelled out: pair_ok → qr.rm → main.
        XCTAssertEqual(ok.resolvedRoom(qrRoom: RoomID("room-from-qr")).rawValue, "room-from-qr")
        XCTAssertEqual(ok.resolvedRoom(qrRoom: nil), .main)
    }

    func testPiSayingMainIsNotTheSameAsPiSayingNothing() throws {
        let explicit = try decodePairOk([
            "type": "pair_ok", "in_reply_to": "abc", "session_name": "Pi", "room_id": "main",
        ])
        XCTAssertFalse(explicit.roomIDWasOmitted)
        XCTAssertEqual(
            explicit.resolvedRoom(qrRoom: RoomID("room-from-qr")),
            .main,
            "an explicit `main` wins over the QR's room"
        )
    }

    func testLegacyZeroStartedAtIsUnknown() throws {
        let ok = try decodePairOk([
            "type": "pair_ok", "in_reply_to": "a", "session_name": "Pi",
            "session_started_at": 0,
        ])
        // Trap T10: 0 is the legacy sentinel, not the epoch.
        XCTAssertNil(ok.knownSessionStartedAt)
    }

    func testExplicitNullReadsAsAbsent() throws {
        // The Pi cannot emit this (`...(cond ? {k:v} : {})`), but if one ever
        // did, absent is the only reading that keeps `session_id`'s
        // presence-is-the-signal rule intact.
        let ok = try decodePairOk([
            "type": "pair_ok", "in_reply_to": "a", "session_name": "Pi",
            "session_id": NSNull(), "room_id": NSNull(), "name_rev": NSNull(),
        ])
        XCTAssertNil(ok.sessionID)
        XCTAssertTrue(ok.roomIDWasOmitted)
        XCTAssertNil(ok.nameRev)
    }

    // MARK: - classification

    func testClassifyRoutesEveryInnerFrameAPairingCanSee() throws {
        func classify(_ object: [String: Any]) -> InnerPairFrame {
            InnerPairFrame.classify(try! JSONSerialization.data(withJSONObject: object))
        }
        guard case .pairOk = classify(pairOkJSON) else {
            return XCTFail("pair_ok should classify as pair_ok")
        }

        // The four codes and their exact messages from `index.ts:1968-1985`.
        let errors: [(String, String)] = [
            (
                "token_expired",
                "Ephemeral token expired. Generate a new QR with /remote-pi pair."
            ),
            ("token_consumed", "Token already consumed by another pair_request."),
            ("token_unknown", "Token was not issued by this Pi."),
            ("internal_error", "Failed to persist peer: Error: EACCES"),
            // The code set is open — a fifth value must parse, not crash.
            ("rate_limited", "slow down"),
        ]
        for (code, message) in errors {
            guard
                case .pairError(let frame) = classify([
                    "type": "pair_error", "in_reply_to": "019ffb64-…", "code": code,
                    "message": message,
                ])
            else { return XCTFail("\(code) should classify as pair_error") }
            XCTAssertEqual(frame.code.rawValue, code)
            XCTAssertEqual(frame.message, message)
        }

        // `index.ts:1919-1927` — an unpaired peer talking to the Pi. Not a
        // pairing failure: it is the only positive confirmation the protocol
        // gives that a revoke landed.
        guard
            case .unknownPeer(let message) = classify([
                "type": "error", "code": "unknown_peer",
                "message": "Peer not paired — re-scan QR",
            ])
        else { return XCTFail("unknown_peer should classify") }
        XCTAssertEqual(message, "Peer not paired — re-scan QR")

        // Trap T8: the inbound queue is unfiltered, so chat traffic and
        // garbage both arrive mid-pairing and neither may throw.
        guard case .other(let type) = classify(["type": "agent_chunk", "in_reply_to": "z", "delta": "hi"])
        else { return XCTFail("chat traffic should classify as other") }
        XCTAssertEqual(type, "agent_chunk")
        guard case .other(nil) = InnerPairFrame.classify(Data("not json".utf8)) else {
            return XCTFail("undecodable payload should classify as other(nil)")
        }
    }
}
