import Foundation
import XCTest

@testable import RemotePiPairing
@testable import RemotePiProtocol

/// The whole handshake against a transport that replays exactly what the
/// pi-extension and the relay put on the wire.
final class PairingFlowTests: XCTestCase {
    private let relayURL = URL(string: "https://relay-rp1.jacobmoura.work")!
    private let qrString =
        "remotepi://pair?t=Zm9vYmFyYmF6cXV4MTIzNA"
        + "&epk=1sbg3nsX4kRTBmM3XZ_hs4mAujHmbcm7CjfPGkDgpTQ"
        + "&n=remote_pi&rm=019ffb64-3c21-7a55-9b0e-2f7d1c4a88e1"

    private func makeSystem(
        http: FakeMeshHTTP = FakeMeshHTTP(),
        timeout: Duration = .seconds(5)
    ) async -> (
        FakeRelayTransport, PairingCoordinator, PeerDirectory, InMemorySessionStore,
        OwnerIdentityBridge, MeshPublisher
    ) {
        let store = InMemorySessionStore()
        let directory = PeerDirectory(store: store)
        let bridge = OwnerIdentityBridge(store: InMemoryOwnerIdentityStore(), wipe: directory)
        _ = await bridge.boot()
        let publisher = MeshPublisher(
            client: MeshClient(baseURL: relayURL, http: http),
            directory: directory,
            bridge: bridge,
            now: { 1_780_000_000_000 }
        )
        let transport = FakeRelayTransport()
        let coordinator = PairingCoordinator(
            transport: transport,
            keyStore: OwnerKeyStore(bridge: bridge),
            directory: directory,
            publisher: publisher,
            http: http,
            timeout: timeout,
            makeRequestID: { "019ffb64-3c21-7a55-9b0e-2f7d1c4a88e1" },
            now: { Date(timeIntervalSince1970: 1_780_000_000) }
        )
        return (transport, coordinator, directory, store, bridge, publisher)
    }

    private func pairOkJSON(inReplyTo: String) -> [String: Any] {
        piPairOkJSON(inReplyTo: inReplyTo)
    }
}

/// The Pi's reply as `index.ts:2019-2042` builds it. Free function so the
/// `@Sendable` responder closures below do not have to capture the test case.
func piPairOkJSON(inReplyTo: String) -> [String: Any] {
    [
            "type": "pair_ok",
            "in_reply_to": inReplyTo,
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
}

extension PairingFlowTests {
    func testHappyPath() async throws {
        let http = FakeMeshHTTP([
            // The publisher learns the current version before its first write.
            .text(404, "not_found"),
            .json(200, ["version": 1, "updated_at": 1_780_000_000_123]),
        ])
        let (transport, coordinator, _, store, bridge, _) = await makeSystem(http: http)
        let qr = try XCTUnwrap(PairingQRPayload.parse(qrString))

        transport.onEnvelope = { envelope in
            let inner =
                try! JSONSerialization.jsonObject(with: envelope.payload!) as! [String: Any]
            // The Pi answers with no `room` at all (`index.ts:1964-1967`); the
            // relay stamps in the sender's registered room.
            transport.deliverInner(
                piPairOkJSON(inReplyTo: inner["id"] as! String),
                from: qr.peer,
                room: RoomID("019ffb64-1111-7a55-9b0e-2f7d1c4a88e1")
            )
        }

        let outcome = try await coordinator.pairDetailed(
            with: qr,
            relayURL: relayURL,
            deviceName: "iPhone"
        )

        // The envelope we sent.
        let sent = try XCTUnwrap(transport.sentEnvelopes.first)
        XCTAssertEqual(sent.peer, qr.peer)
        XCTAssertEqual(
            sent.room.rawValue,
            "019ffb64-3c21-7a55-9b0e-2f7d1c4a88e1",
            "the pair_request must be addressed to the QR's `rm`; `main` is a "
                + "room only the phone lives in and the relay's lookup is exact"
        )
        XCTAssertEqual(
            String(data: sent.payload!, encoding: .utf8),
            #"{"device_name":"iPhone","id":"019ffb64-3c21-7a55-9b0e-2f7d1c4a88e1","token":"Zm9vYmFyYmF6cXV4MTIzNA","type":"pair_request"}"#
        )
        XCTAssertEqual(sent.ct, Base64.encodeStandard(sent.payload!))

        // We authenticated as the long-lived Owner key, not an ephemeral one.
        let owner = try await bridge.requireIdentity()
        XCTAssertEqual(transport.connectedAs, owner.peerID)

        // The record.
        XCTAssertEqual(outcome.peer.peer, qr.peer)
        XCTAssertEqual(outcome.peer.sessionName, "remote_pi")
        XCTAssertEqual(outcome.peer.hostname, "jacobs-mbp.local")
        XCTAssertEqual(outcome.peer.harnessName, "Pi coding agent")
        XCTAssertEqual(outcome.peer.harnessVersion, "0.9.3")
        XCTAssertEqual(outcome.peer.relayURL, relayURL.absoluteString)
        XCTAssertEqual(outcome.hostnameHint, "jacobs-mbp.local")
        XCTAssertEqual(
            outcome.peer.lastOpenedRoom?.rawValue,
            "019ffb64-1111-7a55-9b0e-2f7d1c4a88e1"
        )

        // And the plan-61 room identity, cached from the very first frame.
        let cached = try await store.loadRooms(for: qr.peer)
        XCTAssertEqual(cached.count, 1)
        XCTAssertEqual(cached.first?.sessionID?.rawValue, "019ffb64-1111-7a55-9b0e-2f7d1c4a88e1")
        XCTAssertEqual(cached.first?.workspacePath, "/Users/jacob/Projects/remote_pi")

        // The membership went out, with the machine key in standard base64.
        let post = try XCTUnwrap(http.requests.last)
        XCTAssertEqual(post.httpMethod, "POST")
        let body =
            try JSONSerialization.jsonObject(with: post.httpBody!) as! [String: Any]
        let blob = try MeshBlob.parse(Base64.decodeTolerant(body["blob"] as! String)!)
        XCTAssertEqual(blob.members.map(\.remoteEpk), [qr.peer])
        let canonical = String(data: try blob.canonicalBytes(), encoding: .utf8)!
        XCTAssertTrue(
            canonical.contains("\"remote_epk\":\"\(qr.peer.wireValue)\""),
            "a url-safe spelling here reads to the Pi as \"I am not listed\" "
                + "and it self-revokes 60s later"
        )
    }

    /// Trap T4. A stale `rm` produces a `transport_error` control frame, not a
    /// `pair_error` — and it must surface within one RTT rather than sitting
    /// out the 30 s pairing timeout.
    func testStaleRoomSurfacesTransportErrorImmediately() async throws {
        let (transport, coordinator, _, _, _, _) = await makeSystem(timeout: .seconds(600))
        let qr = try XCTUnwrap(PairingQRPayload.parse(qrString))

        transport.onEnvelope = { envelope in
            // Verbatim from `relay/src/handlers/peer.rs:428-440`.
            transport.deliverControl([
                "type": "transport_error",
                "reason": "offline",
                "peer": envelope.peer.wireValue,
                "room_id": envelope.room.rawValue,
            ])
        }

        do {
            _ = try await coordinator.pairDetailed(
                with: qr, relayURL: relayURL, deviceName: "iPhone"
            )
            XCTFail("expected transportOffline")
        } catch let failure as PairFailure {
            guard case .transportOffline(let peer, let room, let reason) = failure else {
                return XCTFail("expected transportOffline, got \(failure)")
            }
            XCTAssertEqual(peer, qr.peer)
            XCTAssertEqual(room.rawValue, "019ffb64-3c21-7a55-9b0e-2f7d1c4a88e1")
            XCTAssertEqual(reason, "offline")
        }
    }

    func testPairErrorIsSurfacedWithItsCode() async throws {
        let (transport, coordinator, _, store, _, _) = await makeSystem()
        let qr = try XCTUnwrap(PairingQRPayload.parse(qrString))

        transport.onEnvelope = { envelope in
            let inner =
                try! JSONSerialization.jsonObject(with: envelope.payload!) as! [String: Any]
            transport.deliverInner(
                [
                    "type": "pair_error",
                    "in_reply_to": inner["id"] as! String,
                    "code": "token_consumed",
                    "message": "Token already consumed by another pair_request.",
                ],
                from: qr.peer,
                room: RoomID("019ffb64-1111-7a55-9b0e-2f7d1c4a88e1")
            )
        }

        do {
            _ = try await coordinator.pairDetailed(
                with: qr, relayURL: relayURL, deviceName: "iPhone"
            )
            XCTFail("expected a wire failure")
        } catch PairFailure.wire(let code, let message) {
            XCTAssertEqual(code, .tokenConsumed)
            XCTAssertEqual(message, "Token already consumed by another pair_request.")
        }
        let peers = try await store.loadPeers()
        XCTAssertTrue(peers.isEmpty, "a failed pairing must not persist a peer")
    }

    /// Trap T8. The socket's inbound queue is not filtered by sender, and
    /// `in_reply_to` is the Flutter client's only guard.
    func testIgnoresFramesFromOtherPeersAndOtherRequests() async throws {
        let (transport, coordinator, _, _, _, _) = await makeSystem()
        let qr = try XCTUnwrap(PairingQRPayload.parse(qrString))
        let impostor = Fixture.key(9)

        transport.onEnvelope = { envelope in
            let inner =
                try! JSONSerialization.jsonObject(with: envelope.payload!) as! [String: Any]
            let id = inner["id"] as! String
            // A pair_ok for our id, from the wrong machine.
            transport.deliverInner(
                piPairOkJSON(inReplyTo: id), from: impostor, room: .main
            )
            // A pair_ok from the right machine, answering somebody else.
            transport.deliverInner(
                piPairOkJSON(inReplyTo: "some-other-request"), from: qr.peer, room: .main
            )
            // Ordinary chat traffic.
            transport.deliverInner(
                ["type": "agent_chunk", "text": "hello"], from: qr.peer, room: .main
            )
            // The real one.
            transport.deliverInner(piPairOkJSON(inReplyTo: id), from: qr.peer, room: .main)
        }

        let outcome = try await coordinator.pairDetailed(
            with: qr, relayURL: relayURL, deviceName: "iPhone"
        )
        XCTAssertEqual(outcome.peer.peer, qr.peer)
    }

    func testLegacyRelayMismatchIsRefusedBeforeConnecting() async throws {
        let (transport, coordinator, _, _, _, _) = await makeSystem()
        let qr = try XCTUnwrap(
            PairingQRPayload.parse(qrString + "&r=wss%3A%2F%2Fother-relay.example")
        )
        do {
            _ = try await coordinator.pairDetailed(
                with: qr, relayURL: relayURL, deviceName: "iPhone"
            )
            XCTFail("expected relayMismatch")
        } catch PairFailure.relayMismatch(let fromQR, let configured) {
            XCTAssertEqual(fromQR, "wss://other-relay.example")
            XCTAssertEqual(configured, relayURL.absoluteString)
        }
        XCTAssertNil(transport.connectedTo, "we must not open a socket first")
    }

    func testLegacyRelayMatchingInWSFormIsAccepted() async throws {
        // Settings holds `https://…`, an old QR holds `wss://…`. Same relay.
        let (transport, coordinator, _, _, _, _) = await makeSystem()
        let qr = try XCTUnwrap(
            PairingQRPayload.parse(qrString + "&r=wss%3A%2F%2Frelay-rp1.jacobmoura.work")
        )
        transport.onEnvelope = { envelope in
            let inner =
                try! JSONSerialization.jsonObject(with: envelope.payload!) as! [String: Any]
            transport.deliverInner(
                piPairOkJSON(inReplyTo: inner["id"] as! String), from: qr.peer, room: .main
            )
        }
        let outcome = try await coordinator.pairDetailed(
            with: qr, relayURL: relayURL, deviceName: "iPhone"
        )
        XCTAssertEqual(
            outcome.peer.relayURL, "wss://relay-rp1.jacobmoura.work",
            "the record keeps whichever relay the pairing actually happened on"
        )
    }

    func testTimesOutWhenThePiNeverAnswers() async throws {
        let (_, coordinator, _, _, _, _) = await makeSystem(timeout: .milliseconds(50))
        let qr = try XCTUnwrap(PairingQRPayload.parse(qrString))
        do {
            _ = try await coordinator.pairDetailed(
                with: qr, relayURL: relayURL, deviceName: "iPhone"
            )
            XCTFail("expected timedOut")
        } catch PairFailure.timedOut {
            // Expected. There is no "is the token still valid?" probe — the
            // client only learns a token expired by sending.
        }
    }

    func testUnknownPeerMeansRevokedNotFailedPairing() async throws {
        let (transport, coordinator, _, _, _, _) = await makeSystem()
        let qr = try XCTUnwrap(PairingQRPayload.parse(qrString))
        transport.onEnvelope = { _ in
            transport.deliverInner(
                [
                    "type": "error", "code": "unknown_peer",
                    "message": "Peer not paired — re-scan QR",
                ],
                from: qr.peer,
                room: .main
            )
        }
        do {
            _ = try await coordinator.pairDetailed(
                with: qr, relayURL: relayURL, deviceName: "iPhone"
            )
            XCTFail("expected unknownPeer")
        } catch PairFailure.unknownPeer(let message) {
            XCTAssertEqual(message, "Peer not paired — re-scan QR")
        }
    }
}
