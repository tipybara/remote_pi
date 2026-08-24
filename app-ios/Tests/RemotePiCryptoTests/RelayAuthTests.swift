import Foundation
import XCTest

@testable import RemotePiCrypto
@testable import RemotePiProtocol

/// The handshake's one cryptographic step, pinned against a `challenge` /
/// `auth` pair generated outside Swift.
///
/// The relay never tells a client why auth failed — every failure in the path
/// is an unadorned socket close (spec 62-03 §1.6). So these assertions are the
/// only feedback loop that exists before a real relay is involved.
final class RelayAuthTests: XCTestCase {

    private func nobleSigner() throws -> Ed25519Signer {
        try Ed25519Signer(seed: WireVectors.data(hex: WireVectors.nobleSeedHex))
    }

    /// Full frame-to-frame vector: given the relay's `challenge.nonce` string,
    /// the `auth.sig` we emit must pass the relay's `verify_auth`, and the
    /// `sig` the pi-extension's Ed25519 emitted for the same key and nonce
    /// must pass it too. Anything that changes the signed bytes — a prefix, a
    /// hash, signing the Base64 text — breaks both halves.
    ///
    /// Equality against the reference `sig` is *not* asserted: CryptoKit
    /// hedges its Ed25519 nonce and never reproduces deterministic RFC 8032
    /// bytes (`Ed25519VectorTests.testCryptoKitSignaturesAreHedgedNotDeterministic`).
    /// "The relay accepts it" is the property that matters and the only one
    /// that is stable.
    func testAuthSigPassesTheRelaysVerifier() throws {
        let signer = try nobleSigner()
        let nonce = try RelayAuth.decodeChallengeNonce(WireVectors.nobleNonceStandard)

        let sig = try RelayAuth.signature(
            forChallengeNonce: WireVectors.nobleNonceStandard,
            using: signer
        )
        XCTAssertTrue(
            RelayAuth.isValidChallengeSignature(sig, nonce: nonce, peer: signer.publicKey))

        XCTAssertTrue(
            RelayAuth.isValidChallengeSignature(
                WireVectors.nobleAuthSigStandard, nonce: nonce, peer: signer.publicKey),
            "the pi-extension's own signature over this nonce must verify"
        )
        XCTAssertTrue(
            RelayAuth.isValidChallengeSignature(
                WireVectors.cryptoKitSigVerifiedByNoble, nonce: nonce, peer: signer.publicKey),
            "the signature @noble accepted out-of-band must still verify"
        )

        // A different key's signature over the same nonce is refused — the
        // whole point of the challenge.
        let stranger = try Ed25519Signer()
        XCTAssertFalse(
            RelayAuth.isValidChallengeSignature(sig, nonce: nonce, peer: stranger.publicKey))
    }

    /// `verify_auth` decodes `sig` with the `STANDARD` engine and does
    /// `try_into::<[u8; 64]>()` (`challenge.rs:82-85`), so the frame must be
    /// standard Base64 **with** padding and exactly 64 bytes.
    func testSigIsStandardBase64WithPadding() throws {
        let signer = try nobleSigner()
        let sig = try RelayAuth.signature(
            forChallengeNonce: WireVectors.nobleNonceStandard,
            using: signer
        )
        XCTAssertEqual(sig.count, 88)
        XCTAssertTrue(sig.hasSuffix("=="))
        XCTAssertFalse(sig.contains("-"))
        XCTAssertFalse(sig.contains("_"))
        XCTAssertEqual(Data(base64Encoded: sig, options: [])?.count, 64)
    }

    /// Trap T2 in executable form: a url-safe `sig` is a valid encoding of a
    /// valid signature and the relay still rejects it, because that field has
    /// no url-safe fallback (unlike `hello.pubkey`, which has one). The
    /// failure on the wire is `AuthError::InvalidSig` → close, with nothing to
    /// distinguish it from a wrong key.
    func testURLSafeOrUnpaddedSignatureSpellingsAreRejected() throws {
        let signer = try nobleSigner()
        let nonce = try RelayAuth.decodeChallengeNonce(WireVectors.nobleNonceStandard)
        let standard = WireVectors.nobleAuthSigStandard

        XCTAssertTrue(
            RelayAuth.isValidChallengeSignature(standard, nonce: nonce, peer: signer.publicKey))

        let urlSafe =
            standard
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertNotEqual(urlSafe, standard, "fixture must actually differ")
        XCTAssertFalse(
            RelayAuth.isValidChallengeSignature(urlSafe, nonce: nonce, peer: signer.publicKey))

        let unpadded = String(standard.dropLast(2))
        XCTAssertFalse(
            RelayAuth.isValidChallengeSignature(unpadded, nonce: nonce, peer: signer.publicKey))
    }

    /// The classic failure: signing the nonce's Base64 *text* instead of the
    /// bytes it denotes. The frame is well-formed, the signature is valid over
    /// *something*, and the relay closes the socket without a word.
    func testSigningTheBase64TextInsteadOfTheBytesDoesNotVerify() throws {
        let signer = try nobleSigner()
        let nonce = try RelayAuth.decodeChallengeNonce(WireVectors.nobleNonceStandard)

        let wrong = try signer.signature(for: Data(WireVectors.nobleNonceStandard.utf8))
        XCTAssertFalse(
            RelayAuth.isValidChallengeSignature(
                wrong.base64EncodedString(), nonce: nonce, peer: signer.publicKey)
        )
    }

    /// No domain separation, no hashing, no framing: the signed message is the
    /// 32 nonce bytes and nothing else (`vk.verify(nonce, &sig)`).
    func testNoDomainSeparationIsApplied() throws {
        let signer = try nobleSigner()
        let nonce = try RelayAuth.decodeChallengeNonce(WireVectors.nobleNonceStandard)

        let sig = try XCTUnwrap(Data(base64Encoded: WireVectors.nobleAuthSigStandard))
        XCTAssertTrue(verifyEd25519(signature: sig, of: nonce, by: signer.publicKey))

        for prefix in ["remotepi:", "RemotePi relay auth", "\u{00}"] {
            XCTAssertFalse(
                verifyEd25519(
                    signature: sig, of: Data(prefix.utf8) + nonce, by: signer.publicKey),
                "a \(prefix) prefix must not verify"
            )
        }
    }

    // MARK: - nonce decoding

    /// The relay's nonce is `STANDARD.encode(32 random bytes)` — always 44
    /// characters ending in one `=`.
    func testDecodesTheRelaysNonceSpelling() throws {
        let nonce = try RelayAuth.decodeChallengeNonce(WireVectors.nobleNonceStandard)
        XCTAssertEqual(nonce.count, 32)
        XCTAssertEqual(WireVectors.nobleNonceStandard.count, 44)
    }

    /// `ws_transport.dart:302-310` pads defensively and falls back to the
    /// url-safe alphabet. No relay emits either shape, but the tolerance is
    /// free and a truncated frame is worth surviving.
    func testNonceDecodingToleratesUnpaddedAndURLSafeSpellings() throws {
        let canonical = try RelayAuth.decodeChallengeNonce(WireVectors.nobleNonceStandard)

        let unpadded = String(WireVectors.nobleNonceStandard.dropLast())
        XCTAssertEqual(try RelayAuth.decodeChallengeNonce(unpadded), canonical)

        // A nonce whose Base64 actually exercises `+` and `/` — this one
        // (32 × 0xfb) is the relay's own identity-test fixture, so its
        // url-safe spelling is a real alternative encoding rather than the
        // same string with the padding removed.
        XCTAssertEqual(
            try RelayAuth.decodeChallengeNonce(WireVectors.relayKeyURLSafe),
            Data(repeating: 0xfb, count: 32)
        )
        XCTAssertEqual(
            try RelayAuth.decodeChallengeNonce(WireVectors.relayKeyURLSafeNoPad),
            try RelayAuth.decodeChallengeNonce(WireVectors.relayKeyStandard)
        )
    }

    /// A nonce of any other length cannot be what the relay will verify
    /// against — `verify_auth` takes a `&[u8; 32]`. Failing locally beats
    /// sending a signature that can only be rejected in silence.
    func testRejectsANonceThatIsNotThirtyTwoBytes() throws {
        let signer = try nobleSigner()
        let short = Data(repeating: 9, count: 16).base64EncodedString()

        XCTAssertThrowsError(try RelayAuth.decodeChallengeNonce(short)) { error in
            XCTAssertEqual(error as? RelayAuthError, .unexpectedNonceLength(16))
        }
        XCTAssertThrowsError(
            try RelayAuth.signature(forNonceBytes: Data(repeating: 9, count: 16), using: signer))
        XCTAssertThrowsError(try RelayAuth.decodeChallengeNonce("not base64 at all !!")) { error in
            XCTAssertEqual(error as? RelayAuthError, .malformedNonce("not base64 at all !!"))
        }
    }

    /// The `hello.pubkey` the same handshake sends is the standard, padded
    /// spelling — `peer_id = STANDARD_base64(vk.to_bytes())` regardless of
    /// what we sent, so sending anything else guarantees our own `peer` field
    /// will not match the registry key the relay filed us under.
    func testHelloPubkeySpellingMatchesTheRegistryKey() throws {
        let signer = try nobleSigner()
        XCTAssertEqual(signer.publicKey.wireValue, WireVectors.noblePubkeyStandard)
        XCTAssertEqual(
            EPKEncoding.toStandardB64(signer.publicKey.urlSafeValue),
            signer.publicKey.wireValue
        )
    }
}
