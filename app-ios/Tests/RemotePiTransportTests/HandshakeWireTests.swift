import Foundation
import RemotePiCrypto
import RemotePiProtocol
import XCTest

@testable import RemotePiTransport

/// The three handshake frames, pinned against the two shipped clients and the
/// Rust verifier.
///
/// Every failure in this path is an unadorned socket close — the relay has no
/// error frame at all — so a mistake here is undebuggable from the wire. These
/// tests are the only place the shapes get checked.
final class HandshakeWireTests: XCTestCase {
    // MARK: hello

    /// Pinned against `app/lib/data/transport/ws_transport.dart:163-167`:
    ///
    /// ```dart
    /// ws.sink.add(jsonEncode({
    ///   'type': 'hello',
    ///   'pubkey': base64.encode(pub.bytes),
    ///   'room_id': 'main',
    /// }));
    /// ```
    func testHelloMatchesTheFlutterClientExactly() async throws {
        let (transport, socket, signer) = try await Fixture.connectedTransport()
        defer { Task { await transport.disconnect() } }

        let hello = try XCTUnwrap(socket.sentObjects.first)
        XCTAssertEqual(hello["type"] as? String, "hello")
        XCTAssertEqual(hello["room_id"] as? String, "main")
        XCTAssertEqual(hello["pubkey"] as? String, signer.publicKey.rawValue.base64EncodedString())
        // A phone that publishes `room_meta` makes its own `main` room show up
        // as a session tile on every other paired device.
        XCTAssertNil(hello["room_meta"])
        XCTAssertEqual(Set(hello.keys), ["type", "pubkey", "room_id"])
    }

    /// `pubkey` is standard Base64 with padding.
    ///
    /// `relay/src/identity.rs:14-30` would in fact accept url-safe here — but
    /// `peer_id` is re-derived as `STANDARD.encode(vk.to_bytes())`
    /// (`peer.rs:80`) and every routing table is keyed by that raw string, so
    /// sending anything else buys nothing and invites the habit that breaks
    /// `Envelope.peer` and `subscribe_*.peers[]`, where there is no leniency.
    func testHelloPubkeyIsStandardBase64WithPadding() async throws {
        let (transport, socket, _) = try await Fixture.connectedTransport()
        defer { Task { await transport.disconnect() } }

        let pubkey = try XCTUnwrap(socket.sentObjects.first?["pubkey"] as? String)
        XCTAssertFalse(pubkey.contains("-"))
        XCTAssertFalse(pubkey.contains("_"))
        XCTAssertTrue(pubkey.hasSuffix("="), "32 bytes of Base64 is 44 chars ending in one '='")
        XCTAssertEqual(pubkey.count, 44)
    }

    // MARK: auth

    /// The signed bytes are the **raw 32 nonce bytes**.
    ///
    /// `relay/src/auth/challenge.rs:76-89`: `vk.verify(nonce, &sig)` where
    /// `nonce: &[u8;32]` is the decoded array. No domain separator, no
    /// pre-hash, no re-encoding. Signing the Base64 *text* instead produces a
    /// perfectly well-formed frame that fails verification, and the relay
    /// answers with a bare close — the single most expensive way to get this
    /// wrong.
    func testAuthSignsRawNonceBytesAndNotTheBase64Text() async throws {
        let (transport, socket, signer) = try await Fixture.connectedTransport()
        defer { Task { await transport.disconnect() } }

        let auth = try XCTUnwrap(socket.sentObjects.last)
        XCTAssertEqual(auth["type"] as? String, "auth")
        XCTAssertEqual(Set(auth.keys), ["type", "sig"])

        let sigText = try XCTUnwrap(auth["sig"] as? String)
        let signature = try XCTUnwrap(Data(base64Encoded: sigText))
        XCTAssertEqual(signature.count, 64, "try_into::<[u8;64]>() rejects any other length")

        XCTAssertTrue(
            verifyEd25519(signature: signature, of: Fixture.nonceBytes, by: signer.publicKey),
            "signature must verify over the decoded nonce"
        )
        XCTAssertFalse(
            verifyEd25519(
                signature: signature,
                of: Data(Fixture.nonceBase64.utf8),
                by: signer.publicKey
            ),
            "signing the base64 STRING is the classic failure and must not accidentally pass"
        )
    }

    /// `sig` is decoded with the STANDARD engine **only**
    /// (`challenge.rs:4`, `:82`) — no url-safe fallback, no unpadded fallback,
    /// unlike `pubkey`. A 64-byte signature almost always contains `+` or `/`,
    /// so a "safe base64" helper reused across the handshake fails every time.
    func testAuthSignatureUsesStandardAlphabet() async throws {
        let (transport, socket, _) = try await Fixture.connectedTransport()
        defer { Task { await transport.disconnect() } }

        let sig = try XCTUnwrap(socket.sentObjects.last?["sig"] as? String)
        XCTAssertFalse(sig.contains("-"), "url-safe alphabet is rejected by verify_auth")
        XCTAssertFalse(sig.contains("_"), "url-safe alphabet is rejected by verify_auth")
        XCTAssertTrue(sig.hasSuffix("="), "64 bytes is 88 chars ending in '='")

        // And the encoder itself must emit `+` / `/` rather than translating
        // them, for a signature whose bytes force both symbols.
        let forcing = Data([0xFB, 0xFF, 0xBE] + Array(repeating: UInt8(0), count: 61))
        let frame = ClientControlFrame.auth(signature: forcing).jsonObject
        let text = try XCTUnwrap(frame["sig"] as? String)
        XCTAssertTrue(text.contains("+") || text.contains("/"))
    }

    // MARK: challenge

    /// The relay's nonce is 32 bytes in STANDARD padded Base64
    /// (`gen_nonce`, `challenge.rs:46-51`) — 44 characters.
    func testChallengeNonceShapeMatchesGenNonce() {
        XCTAssertEqual(Fixture.nonceBase64.count, 44)
        XCTAssertTrue(Fixture.nonceBase64.hasSuffix("="))
        guard case .control(.challenge(let nonce)) = RelayFrame.classify(Fixture.challengeFrame) else {
            return XCTFail("challenge must classify as a control frame")
        }
        XCTAssertEqual(nonce, Fixture.nonceBytes)
    }

    /// Success has no acknowledgement: the relay registers the connection and
    /// starts routing (`peer.rs:74-186`). Both reference clients resolve
    /// `connect()` the instant `auth` is written.
    func testConnectCompletesWithNoAuthAcknowledgement() async throws {
        let (transport, socket, signer) = try await Fixture.connectedTransport()
        defer { Task { await transport.disconnect() } }

        XCTAssertEqual(socket.sent.count, 2, "exactly hello + auth; nothing waits for an ack")

        // The transport is usable immediately: nothing waits for an ack.
        try await transport.send(Envelope(peer: Fixture.piKey, room: .main, payload: Data("{}".utf8)))
        XCTAssertEqual(socket.sent.count, 3)

        let recorder = EventRecorder(transport.events)
        try await Task.sleep(for: .milliseconds(30))
        let events = await recorder.snapshot()
        expectFalse(
            events.contains { if case .disconnected = $0 { return true }; return false },
            "silence after `auth` means success, not rejection"
        )
        _ = signer
    }

    func testRejectsAFirstFrameThatIsNotAChallenge() async throws {
        let socket = FakeWebSocketChannel()
        // This relay never emits `{"type":"error"}` — `room_already_open` is
        // dead code in the pi-extension (spec 03 T7). Anything but a challenge
        // is a protocol break.
        socket.replyToHello(with: [#"{"type":"error","code":"room_already_open"}"#])
        let transport = RelayWebSocketTransport(
            channelFactory: { _ in socket },
            timing: Fixture.fastTiming
        )
        let signer = try Fixture.signer()

        do {
            try await transport.connect(to: Fixture.relayURL, as: signer)
            XCTFail("must not authenticate")
        } catch let error as RelayTransportError {
            guard case .handshakeFailed = error else {
                return XCTFail("expected handshakeFailed, got \(error)")
            }
        }
    }

    func testHandshakeTimesOutWhenNoChallengeArrives() async throws {
        let socket = FakeWebSocketChannel()  // never answers the hello
        let transport = RelayWebSocketTransport(
            channelFactory: { _ in socket },
            timing: Fixture.fastTiming
        )
        do {
            try await transport.connect(to: Fixture.relayURL, as: try Fixture.signer())
            XCTFail("must time out")
        } catch let error as RelayTransportError {
            guard case .handshakeTimeout = error else {
                return XCTFail("expected handshakeTimeout, got \(error)")
            }
        }
    }

    /// T8 — the pre-auth window must not drop frames.
    ///
    /// The Flutter client funnels it into one `Completer`; a second frame
    /// there calls `complete()` twice, throws into a swallowing `catch`, and
    /// is lost (`ws_transport.dart:76-88`). Nothing arrives in that window
    /// against today's relay, but a queue costs nothing.
    func testFramesArrivingBeforeAuthCompletesAreDelivered() async throws {
        let peerOnline = #"{"type":"peer_online","peer":"\#(Fixture.piKeyWire)"}"#
        let socket = FakeWebSocketChannel()
        socket.replyToHello(with: [Fixture.challengeFrame, peerOnline])
        let transport = RelayWebSocketTransport(channelFactory: { _ in socket })
        let recorder = EventRecorder(transport.events)

        try await transport.connect(to: Fixture.relayURL, as: try Fixture.signer())
        defer { Task { await transport.disconnect() } }

        await expectEventually { await recorder.count() >= 2 }
        let events = await recorder.snapshot()
        guard case .connected = events[0] else { return XCTFail("first event is `connected`") }
        guard case .control(.peerOnline(let peer)) = events[1] else {
            return XCTFail("the pre-auth frame must survive, got \(events[1])")
        }
        XCTAssertEqual(peer, Fixture.piKey)
    }

    /// Same thing, but the two frames arrive coalesced in one Text message.
    /// The wire is documented as JSONL and the Pi splits on newlines
    /// (`relay_client.ts:152-155`).
    func testCoalescedJSONLFrameIsSplit() async throws {
        let peerOnline = #"{"type":"peer_online","peer":"\#(Fixture.piKeyWire)"}"#
        let socket = FakeWebSocketChannel()
        socket.replyToHello(with: ["\(Fixture.challengeFrame)\n\(peerOnline)\n"])
        let transport = RelayWebSocketTransport(channelFactory: { _ in socket })
        let recorder = EventRecorder(transport.events)

        try await transport.connect(to: Fixture.relayURL, as: try Fixture.signer())
        defer { Task { await transport.disconnect() } }

        await expectEventually { await recorder.count() >= 2 }
        guard case .control(.peerOnline) = (await recorder.snapshot())[1] else {
            return XCTFail("second line of the batch must be parsed")
        }
    }

    /// §1.4 — the relay never acks a successful auth and answers a bad
    /// signature with a bare `Message::Close(None)`. A close landing within a
    /// beat of `auth` is therefore a rejection, and reporting it as a plain
    /// socket drop makes the ladder spin forever on a key the relay will never
    /// accept.
    func testCloseImmediatelyAfterAuthIsReportedAsHandshakeFailure() async throws {
        let socket = FakeWebSocketChannel()
        socket.replyToHello(with: [Fixture.challengeFrame])
        let timing = TransportTiming(authGracePeriod: .seconds(5))
        let transport = RelayWebSocketTransport(channelFactory: { _ in socket }, timing: timing)
        let recorder = EventRecorder(transport.events)

        try await transport.connect(to: Fixture.relayURL, as: try Fixture.signer())
        socket.closeFromServer()

        await expectEventually {
            await recorder.snapshot().contains { if case .disconnected = $0 { return true }; return false }
        }
        let disconnect = await recorder.snapshot().compactMap { event -> RelayTransportError? in
            if case .disconnected(let error) = event { return error }
            return nil
        }.first
        guard case .handshakeFailed = try XCTUnwrap(disconnect) else {
            return XCTFail("expected handshakeFailed, got \(String(describing: disconnect))")
        }
    }

    // MARK: URL normalization

    /// The client stores `https://…` and converts at the socket boundary
    /// (`relay_config.dart:52-56`). Default relay is
    /// `https://relay-rp1.jacobmoura.work` — the WS path is the root `/`
    /// (`relay/src/lib.rs:59`), so no path is appended.
    func testRelayURLNormalization() throws {
        XCTAssertEqual(
            try relayWebSocketURL(from: URL(string: "https://relay-rp1.jacobmoura.work")!).absoluteString,
            "wss://relay-rp1.jacobmoura.work"
        )
        XCTAssertEqual(
            try relayWebSocketURL(from: URL(string: "http://localhost:8080")!).absoluteString,
            "ws://localhost:8080"
        )
        XCTAssertEqual(
            try relayWebSocketURL(from: URL(string: "ws://localhost:8080")!).absoluteString,
            "ws://localhost:8080"
        )
        XCTAssertThrowsError(try relayWebSocketURL(from: URL(string: "ftp://relay.example")!))
    }
}
