import Foundation
import RemotePiProtocol
import XCTest

@testable import RemotePiCrypto

/// Loader for `Tests/Fixtures/wire/*.json`. See the copy in
/// `RemotePiProtocolTests/WireConformanceTests.swift` for why this is
/// filesystem-based rather than a SwiftPM resource, and why it is duplicated
/// per target (test targets are separate modules and share no code).
enum CapturedWire {
    static let directory: URL =
        URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)
        .appendingPathComponent("wire", isDirectory: true)

    static func object(
        _ name: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> [String: Any] {
        let data = try Data(contentsOf: directory.appendingPathComponent("\(name).json"))
        let wrapper = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any], file: file, line: line)
        let raw = try XCTUnwrap(wrapper["raw"] as? String, file: file, line: line)
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
            file: file, line: line)
    }
}

/// The handshake, verified against a real exchange rather than against
/// ourselves.
///
/// `hello_app.json`, `challenge.json` and `auth.json` are the three frames of
/// **one** connection, captured in order off a live relay: the app's Ed25519
/// key, the relay's 32 random bytes, and the signature Node's
/// `crypto.sign(null, nonce, sk)` produced over them. Verifying that triple
/// with CryptoKit is a cross-implementation vector — it fails if either side's
/// idea of "what is signed" drifts.
final class WireConformanceTests: XCTestCase {

    private func handshake() throws -> (peer: PeerID, nonceB64: String, sig: String) {
        let pubkey = try XCTUnwrap(CapturedWire.object("hello_app")["pubkey"] as? String)
        return (
            peer: try XCTUnwrap(PeerID(base64: pubkey)),
            nonceB64: try XCTUnwrap(CapturedWire.object("challenge")["nonce"] as? String),
            sig: try XCTUnwrap(CapturedWire.object("auth")["sig"] as? String)
        )
    }

    /// The relay's nonce is 32 bytes, standard Base64, padded.
    func testCapturedChallengeNonceDecodes() throws {
        let nonce = try RelayAuth.decodeChallengeNonce(handshake().nonceB64)
        XCTAssertEqual(nonce.count, RelayAuth.nonceByteCount)
        XCTAssertEqual(nonce.count, 32)
    }

    /// The captured `auth.sig` verifies against the captured nonce and the
    /// captured `hello.pubkey`. Node signed it; CryptoKit accepts it.
    func testCapturedHandshakeVerifies() throws {
        let (peer, nonceB64, sig) = try handshake()
        let nonce = try RelayAuth.decodeChallengeNonce(nonceB64)
        XCTAssertTrue(
            RelayAuth.isValidChallengeSignature(sig, nonce: nonce, peer: peer),
            "the relay accepted this exchange; we must too")
    }

    /// The single most common way to get this wrong: signing the Base64 TEXT
    /// of the nonce instead of the bytes it denotes. The frame looks perfect
    /// and the relay answers with a bare socket close.
    func testSigningTheBase64TextWouldNotVerify() throws {
        let (peer, nonceB64, sig) = try handshake()
        XCTAssertFalse(
            RelayAuth.isValidChallengeSignature(sig, nonce: Data(nonceB64.utf8), peer: peer),
            "the message is the 32 raw bytes, never the 44-character string")
    }

    /// `verify_auth` decodes `sig` with the STANDARD engine only — no
    /// url-safe alphabet, no missing padding. A helper that "helpfully"
    /// url-safes the signature produces a frame the relay rejects in silence.
    func testUrlSafeSignatureIsRejectedExactlyAsTheRelayRejectsIt() throws {
        let (peer, nonceB64, sig) = try handshake()
        let nonce = try RelayAuth.decodeChallengeNonce(nonceB64)
        let urlSafe =
            sig
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        guard urlSafe != sig else {
            throw XCTSkip("this run's signature happens to contain no + or /")
        }
        XCTAssertFalse(RelayAuth.isValidChallengeSignature(urlSafe, nonce: nonce, peer: peer))
        XCTAssertTrue(RelayAuth.isValidChallengeSignature(sig, nonce: nonce, peer: peer))
    }

    /// A signature of any length other than 64 is `AuthError::InvalidSig` on
    /// the relay, so it must be a local failure here too.
    func testTruncatedSignatureIsRejected() throws {
        let (peer, nonceB64, sig) = try handshake()
        let nonce = try RelayAuth.decodeChallengeNonce(nonceB64)
        let bytes = try XCTUnwrap(Data(base64Encoded: sig))
        XCTAssertEqual(bytes.count, RelayAuth.signatureByteCount)
        XCTAssertFalse(
            RelayAuth.isValidChallengeSignature(
                bytes.dropLast().base64EncodedString(), nonce: nonce, peer: peer))
    }

    /// A nonce of the wrong length is refused before it can be signed, rather
    /// than producing a signature the relay will reject without saying why.
    func testShortNonceIsRefusedLocally() throws {
        let short = Data(repeating: 0x41, count: 31).base64EncodedString()
        XCTAssertThrowsError(try RelayAuth.decodeChallengeNonce(short)) { error in
            XCTAssertEqual(error as? RelayAuthError, .unexpectedNonceLength(31))
        }
    }

    // MARK: EPK spelling

    /// Every `peer` the relay emitted in the capture is already in the
    /// spelling `toStandardB64` produces, and the url-safe conversion is a
    /// faithful round trip.
    func testCapturedPeerStringsRoundTripThroughEPKEncoding() throws {
        for name in ["room_announced", "peer_online", "peer_offline", "transport_error"] {
            let peer = try XCTUnwrap(CapturedWire.object(name)["peer"] as? String)
            XCTAssertEqual(EPKEncoding.toStandardB64(peer), peer, "\(name): already canonical")
            let appEPK = EPKEncoding.toAppEPK(peer)
            XCTAssertFalse(appEPK.contains("+"), "\(name)")
            XCTAssertFalse(appEPK.contains("/"), "\(name)")
            XCTAssertFalse(appEPK.contains("="), "\(name)")
            XCTAssertEqual(EPKEncoding.toStandardB64(appEPK), peer, "\(name): round trip")
            XCTAssertEqual(EPKEncoding.toAppEPK(appEPK), appEPK, "\(name): idempotent")
        }
    }

    /// The QR's `epk` and the relay's `peer` are the same key in two
    /// spellings. Converting one into the other is the only safe comparison —
    /// this is the bug `epk_encoding.dart`'s header enumerates.
    func testQRKeyAndRelayKeyAreTheSameKey() throws {
        let data = try Data(
            contentsOf: CapturedWire.directory.appendingPathComponent("pairing_qr.json"))
        let record = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let urlSafe = try XCTUnwrap(record["epk_url_safe"] as? String)
        let standard = try XCTUnwrap(record["peer_standard"] as? String)

        XCTAssertNotEqual(urlSafe, standard)
        XCTAssertEqual(EPKEncoding.toStandardB64(urlSafe), standard)
        XCTAssertEqual(EPKEncoding.toAppEPK(standard), urlSafe)
        XCTAssertEqual(EPKEncoding.decodeLenient(urlSafe), EPKEncoding.decodeLenient(standard))
        XCTAssertEqual(EPKEncoding.decodeLenient(standard)?.count, 32)
        XCTAssertEqual(PeerID(base64: urlSafe), PeerID(base64: standard))
    }
}
