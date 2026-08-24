import Foundation
import RemotePiProtocol
import XCTest

@testable import RemotePiTransport

/// The outer envelope, both directions, and the inbound room demux.
final class EnvelopeWireTests: XCTestCase {
    // MARK: Outbound

    /// Pinned against `ws_transport.dart:213-219` / `:229-235`:
    ///
    /// ```dart
    /// _ws.sink.add(jsonEncode({
    ///   'peer': _peerPubkey, 'room': room, 'ct': base64.encode(data),
    /// }));
    /// ```
    ///
    /// and against `relay/src/protocol/outer.rs:12-19`, which deserializes
    /// exactly `{peer, room?, ct}`.
    func testOutboundEnvelopeShape() async throws {
        let (transport, socket, _) = try await Fixture.connectedTransport()
        defer { Task { await transport.disconnect() } }

        let payload = Data(#"{"type":"user_message","id":"m1","text":"oi"}"#.utf8)
        try await transport.sendToRoom(payload, peer: Fixture.piKey, room: RoomID("019ffb64-1c3e-7a91-b0d2-6f2a1c9e77aa"))

        let sent = try XCTUnwrap(socket.sentObjects.last)
        XCTAssertEqual(Set(sent.keys), ["peer", "room", "ct"])
        XCTAssertEqual(sent["peer"] as? String, Fixture.piKeyWire)
        XCTAssertEqual(sent["room"] as? String, "019ffb64-1c3e-7a91-b0d2-6f2a1c9e77aa")
        XCTAssertEqual(sent["ct"] as? String, payload.base64EncodedString())
        // T7: a top-level `type` is consumed by the relay's control-frame
        // branch, matches no arm, and is dropped with no error to the sender.
        XCTAssertNil(sent["type"])
    }

    /// T1 — `Envelope.peer` is compared as a **raw string** against the
    /// relay's `peer_id` (`registry.rs:15`, `peer.rs:388`). A url-safe
    /// spelling misses the map and comes back as `transport_error: offline`
    /// even though the Pi is online. The key here is parsed from the url-safe
    /// unpadded form a QR code carries, and must still go out standard+padded.
    func testPeerIsAlwaysStandardBase64EvenWhenParsedFromQRSpelling() async throws {
        let (transport, socket, _) = try await Fixture.connectedTransport()
        defer { Task { await transport.disconnect() } }

        let urlSafe = Fixture.piKey.urlSafeValue
        XCTAssertNotEqual(urlSafe, Fixture.piKeyWire, "fixture must actually differ in the two spellings")
        let fromQR = try XCTUnwrap(PeerID(base64: urlSafe))

        try await transport.sendToRoom(Data("{}".utf8), peer: fromQR, room: .control)
        let sent = try XCTUnwrap(socket.sentObjects.last)
        XCTAssertEqual(sent["peer"] as? String, Fixture.piKeyWire)
    }

    /// `sendToRoom` must not move the active room (plan 61 Phase 2). This is
    /// the whole reason it exists: a rename from Home targets the session the
    /// user long-pressed, and a control RPC targets `ctrl` — repointing the
    /// active room to deliver either would relocate the conversation.
    func testSendToRoomDoesNotMoveTheActiveRoom() async throws {
        let (transport, socket, _) = try await Fixture.connectedTransport()
        defer { Task { await transport.disconnect() } }

        let chat = RoomID("019ffb64-1c3e-7a91-b0d2-6f2a1c9e77aa")
        await transport.setActiveRoom(chat)

        try await transport.sendToRoom(Data("{}".utf8), peer: Fixture.piKey, room: .control)
        XCTAssertEqual(socket.sentObjects.last?["room"] as? String, "ctrl")
        expectEqual(await transport.currentActiveRoom(), chat)

        try await transport.sendToActiveRoom(Data("{}".utf8), peer: Fixture.piKey)
        XCTAssertEqual(socket.sentObjects.last?["room"] as? String, chat.rawValue)
    }

    /// T11/T8 — the relay estimates size as `ct.len() * 3 / 4` on the Base64
    /// **string**, before decoding, and drops an oversized frame with only a
    /// `warn`: no `transport_error`, no close, nothing. That silence is the
    /// original "app stuck at sending… forever" bug.
    ///
    /// Both vectors are the relay's own tests (`outer.rs:100-116`):
    /// 12 MiB of `A` → ~9 MiB estimated → rejected; 3 MiB of `A` → ~2.25 MiB
    /// → accepted under the 4 MiB default.
    func testEnforcesTheRelayCeilingWithTheRelaysOwnArithmetic() async throws {
        let (transport, socket, _) = try await Fixture.connectedTransport()
        defer { Task { await transport.disconnect() } }

        let tooBig = Envelope(peer: Fixture.piKey, room: .main, ct: String(repeating: "A", count: 12 * 1024 * 1024))
        XCTAssertEqual(tooBig.relayEstimatedPayloadBytes, 9 * 1024 * 1024)
        do {
            try await transport.send(tooBig)
            XCTFail("must be refused locally rather than dropped silently by the relay")
        } catch let error as RelayTransportError {
            guard case .payloadTooLarge(let estimate) = error else {
                return XCTFail("expected payloadTooLarge, got \(error)")
            }
            XCTAssertEqual(estimate, 9 * 1024 * 1024)
        }

        let sentBefore = socket.sent.count
        let bigButLegal = Envelope(peer: Fixture.piKey, room: .main, ct: String(repeating: "A", count: 3 * 1024 * 1024))
        try await transport.send(bigButLegal)
        XCTAssertEqual(socket.sent.count, sentBefore + 1, "≈2.25 MiB passes under the 4 MiB default")
    }

    func testSendBeforeConnectFails() async throws {
        let transport = RelayWebSocketTransport(channelFactory: { _ in FakeWebSocketChannel() })
        do {
            try await transport.send(Envelope(peer: Fixture.piKey, room: .main, payload: Data()))
            XCTFail("must not send before the handshake")
        } catch let error as RelayTransportError {
            guard case .notConnected = error else { return XCTFail("got \(error)") }
        }
    }

    // MARK: Inbound

    /// Inbound `peer` and `room` are the **sender's**, not the destination's:
    /// the relay rewrites both on forward (`peer.rs:385-406`).
    func testInboundEnvelopeCarriesTheSenderAddress() async throws {
        let room = RoomID("019ffb64-1c3e-7a91-b0d2-6f2a1c9e77aa")
        let (transport, socket, _) = try await Fixture.connectedTransport()
        defer { Task { await transport.disconnect() } }
        await transport.setActiveRoom(room)
        let recorder = EventRecorder(transport.events)

        let inner = Data(#"{"type":"agent_chunk","in_reply_to":"m1","delta":"oi"}"#.utf8)
        socket.push(#"{"peer":"\#(Fixture.piKeyWire)","room":"\#(room.rawValue)","ct":"\#(inner.base64EncodedString())"}"#)

        await expectEventually {
            await recorder.snapshot().contains { if case .envelope = $0 { return true }; return false }
        }
        // `.connected` is still buffered in the stream ahead of it — the
        // recorder attaches after the handshake, and an `AsyncStream` holds
        // what nobody has consumed yet.
        let inbound = await recorder.snapshot().compactMap { event -> Envelope? in
            if case .envelope(let envelope) = event { return envelope }
            return nil
        }
        let envelope = try XCTUnwrap(inbound.first)
        XCTAssertEqual(envelope.peer, Fixture.piKey)
        XCTAssertEqual(envelope.room, room)
        XCTAssertEqual(envelope.payload, inner)
    }

    /// The demux, end to end. Pinned against `ws_transport.dart:92-123`.
    ///
    /// Three frames: one from the active room (kept), one from another
    /// session (dropped — otherwise its `agent_chunk`s bleed into the chat the
    /// user is reading), and one from `ctrl` (kept — plan 61 Phase 3, without
    /// which every machine-control reply vanishes).
    func testInboundDemuxKeepsActiveRoomAndCtrlAndDropsTheRest() async throws {
        let active = RoomID("019ffb64-1c3e-7a91-b0d2-6f2a1c9e77aa")
        let other = RoomID("019ffb64-9999-7c31-9b2e-4f3a2b1c0d9e")
        let (transport, socket, _) = try await Fixture.connectedTransport()
        defer { Task { await transport.disconnect() } }
        await transport.setActiveRoom(active)
        let recorder = EventRecorder(transport.events)

        func envelope(from room: String, marker: String) -> String {
            let ct = Data(marker.utf8).base64EncodedString()
            return #"{"peer":"\#(Fixture.piKeyWire)","room":"\#(room)","ct":"\#(ct)"}"#
        }
        socket.push(envelope(from: active.rawValue, marker: "keep-active"))
        socket.push(envelope(from: other.rawValue, marker: "drop-me"))
        socket.push(envelope(from: "ctrl", marker: "keep-ctrl"))

        await expectEventually { await transport.currentStatistics().deliveredEnvelopes == 2 }
        let statistics = await transport.currentStatistics()
        XCTAssertEqual(statistics.deliveredEnvelopes, 2)
        XCTAssertEqual(statistics.droppedByRoomDemux, 1)

        let payloads = await recorder.snapshot().compactMap { event -> String? in
            guard case .envelope(let envelope) = event, let data = envelope.payload else { return nil }
            return String(data: data, encoding: .utf8)
        }
        XCTAssertEqual(payloads, ["keep-active", "keep-ctrl"])
    }

    /// The pure rule, including the branch the current relay can never
    /// exercise: `OuterEnvelope` has no `skip_serializing_if`, so `room` is
    /// always on the wire. A sender that omits it is pre-plan-17 and is routed
    /// unconditionally.
    func testDemuxRule() {
        let active = RoomID("session-a")
        XCTAssertTrue(shouldDeliverEnvelope(senderRoom: active, activeRoom: active))
        XCTAssertFalse(shouldDeliverEnvelope(senderRoom: RoomID("session-b"), activeRoom: active))
        XCTAssertTrue(shouldDeliverEnvelope(senderRoom: .control, activeRoom: active))
        XCTAssertTrue(shouldDeliverEnvelope(senderRoom: nil, activeRoom: active))
        // `ctrl` is a reserved literal, not a derived id: four characters,
        // neither a UUID nor a 12-char digest. A client that length-checks or
        // shape-validates room ids breaks machine control entirely.
        XCTAssertFalse(RoomID.control.hasSessionIDShape)
    }

    /// Live pairing (2026-08-25): the phone hellos at `main`, the Pi answers
    /// `pair_ok` from the QR's `rm` (a session UUID). That mismatch is this
    /// rule. PairingCoordinator must `setActiveRoom` to `rm` before send, or
    /// the Mac enrols us and the phone sits on the 30 s timeout.
    func testPairOkFromQRRoomIsDroppedWhileActiveRoomIsMain() {
        let qrRoom = RoomID("b380520c-667e-4ae9-a52e-25d853a9a6be")
        XCTAssertFalse(shouldDeliverEnvelope(senderRoom: qrRoom, activeRoom: .main))
        XCTAssertTrue(shouldDeliverEnvelope(senderRoom: qrRoom, activeRoom: qrRoom))
    }

    /// Relay test vector `parses_minimal_envelope` (`outer.rs:81-88`), with a
    /// real key substituted for its placeholder `"abc"`: an absent `room`
    /// decodes to `"main"`.
    func testAbsentRoomDecodesToMainAndStillRoutes() throws {
        let text = #"{"peer":"\#(Fixture.piKeyWire)","ct":"AAA="}"#
        let parsed = try XCTUnwrap(ParsedFrame(text))
        guard case .envelope(let envelope) = parsed.frame else { return XCTFail("expected envelope") }
        XCTAssertEqual(envelope.room, .main)
        XCTAssertNil(parsed.declaredRoom, "the KEY was absent — that is what the legacy branch keys off")
        XCTAssertTrue(shouldDeliverEnvelope(senderRoom: parsed.declaredRoom, activeRoom: RoomID("anything")))
    }

    /// Relay test vector `parses_envelope_with_room` (`outer.rs:90-95`) —
    /// a legacy 12-character digest room id, which must parse like any other.
    func testLegacyDigestRoomID() throws {
        let text = #"{"peer":"\#(Fixture.piKeyWire)","room":"aB12CD34eF56","ct":"AAA="}"#
        let parsed = try XCTUnwrap(ParsedFrame(text))
        XCTAssertEqual(parsed.declaredRoom, RoomID("aB12CD34eF56"))
    }

    /// Envelope before control: `room_announced`, `rooms`, `peer_online` and
    /// `transport_error` all carry a top-level `peer`.
    func testEnvelopeIsClassifiedBeforeControl() throws {
        guard case .envelope = RelayFrame.classify(#"{"peer":"\#(Fixture.piKeyWire)","room":"r","ct":"e30="}"#)
        else { return XCTFail("envelope misclassified") }
        guard case .control = RelayFrame.classify(#"{"type":"peer_online","peer":"\#(Fixture.piKeyWire)"}"#)
        else { return XCTFail("control frame misclassified") }
        guard case .unknown = RelayFrame.classify("not json") else {
            return XCTFail("garbage must classify as unknown, not crash")
        }
    }
}
