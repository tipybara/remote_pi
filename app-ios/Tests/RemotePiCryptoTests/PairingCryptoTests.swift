import Foundation
import XCTest

@testable import RemotePiCrypto
@testable import RemotePiProtocol

/// The membership blob — the only signature in the pairing flow other than the
/// relay challenge, and the one that decides whether a pairing survives.
///
/// Pinned against bytes from the pi-extension's `@noble/ed25519` and node's
/// `createHash("sha256")`, because the consumers of this signature are
/// `relay/src/mesh/verify.rs` (`verify_strict` over exactly the received
/// bytes) and `pi-extension/src/mesh/verify.ts`.
final class PairingCryptoTests: XCTestCase {

    private func nobleSigner() throws -> Ed25519Signer {
        try Ed25519Signer(seed: WireVectors.data(hex: WireVectors.nobleSeedHex))
    }

    private func exampleBlob(owner: PeerID) throws -> MeshBlob {
        MeshBlob(
            version: 8,
            issuedAt: 1_780_000_000_000,
            ownerPk: owner,
            members: [
                MeshMember(
                    remoteEpk: try XCTUnwrap(PeerID(base64: WireVectors.piOneStandard)),
                    relayURL: "https://relay.remotepi.dev",
                    pairedAt: "2026-08-25T12:34:56.789Z",
                    nickname: "casa"
                )
            ]
        )
    }

    /// The canonical bytes are the contract. The relay does not canonicalize
    /// before verifying — it checks the signature against exactly what
    /// arrived — so if this string is wrong, every publish fails with an
    /// opaque "signature verification failed".
    ///
    /// The expected value is the worked example from spec 62-04 §10 with the
    /// fixture keys substituted, and it was produced by `JSON.stringify` on
    /// the Node side rather than by any Swift encoder.
    func testCanonicalBytesMatchTheSpecExample() throws {
        let signer = try nobleSigner()
        let blob = try exampleBlob(owner: signer.publicKey)
        let bytes = try blob.canonicalBytes()

        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), WireVectors.meshCanonicalJSON)
        // Slashes unescaped: `JSONEncoder` would emit `https:\/\/…`, which is
        // valid JSON, different bytes, and a signature nothing accepts.
        XCTAssertTrue(WireVectors.meshCanonicalJSON.contains("https://relay.remotepi.dev"))
    }

    /// A blob published by this client is one the Pi and the relay accept: the
    /// `blob` field is byte-identical to the reference bytes, and the `sig`
    /// verifies against them.
    ///
    /// The signature is *not* compared to `@noble`'s — CryptoKit hedges its
    /// Ed25519 nonce, so the two implementations sign the same bytes into
    /// different (both valid) signatures. `blob` equality is the assertion
    /// that carries the weight anyway: it is the canonicalization that
    /// silently breaks, not the arithmetic.
    func testSignMeshBlobProducesAVerifiableEnvelopeOverTheReferenceBytes() throws {
        let signer = try nobleSigner()
        let envelope = try PairingCrypto.signMeshBlob(
            exampleBlob(owner: signer.publicKey), using: signer)

        XCTAssertEqual(
            envelope.blob,
            Data(WireVectors.meshCanonicalJSON.utf8).base64EncodedString(),
            "the envelope must carry the bytes that were signed, re-encoded once"
        )
        XCTAssertNoThrow(
            try PairingCrypto.verifyMeshEnvelope(envelope, expectedOwner: signer.publicKey))

        // The reference signature over the same bytes verifies too — proof
        // that both sides signed the same canonical form.
        let reference = MeshEnvelope(blob: envelope.blob, sig: WireVectors.meshSigStandard)
        XCTAssertNoThrow(
            try PairingCrypto.verifyMeshEnvelope(reference, expectedOwner: signer.publicKey))

        // Both wire fields are standard Base64: `relay/src/mesh/verify.rs`
        // decodes them with the STANDARD engine only.
        XCTAssertFalse(envelope.sig.contains("-"))
        XCTAssertFalse(envelope.sig.contains("_"))
        XCTAssertFalse(envelope.blob.contains("-"))
        XCTAssertFalse(envelope.blob.contains("_"))
    }

    /// A blob fetched back verifies against the `owner_pk` inside it, and the
    /// caller's expectation about who that owner is has to be checked
    /// separately — otherwise a relay serving someone else's valid blob at our
    /// hash slot would be believed.
    func testVerifyMeshEnvelopeAcceptsAForeignSignedEnvelope() throws {
        let signer = try nobleSigner()
        let envelope = MeshEnvelope(
            blob: Data(WireVectors.meshCanonicalJSON.utf8).base64EncodedString(),
            sig: WireVectors.meshSigStandard
        )

        let blob = try PairingCrypto.verifyMeshEnvelope(envelope, expectedOwner: signer.publicKey)
        XCTAssertEqual(blob.version, 8)
        XCTAssertEqual(blob.issuedAt, 1_780_000_000_000)
        XCTAssertEqual(blob.ownerPk, signer.publicKey)
        XCTAssertEqual(blob.members.count, 1)
        XCTAssertEqual(blob.members[0].remoteEpk.wireValue, WireVectors.piOneStandard)
        XCTAssertEqual(blob.members[0].nickname, "casa")
    }

    func testVerifyMeshEnvelopeRejectsATamperedBlob() throws {
        let signer = try nobleSigner()
        let tampered = WireVectors.meshCanonicalJSON.replacingOccurrences(
            of: "\"version\":8", with: "\"version\":9")
        let envelope = MeshEnvelope(
            blob: Data(tampered.utf8).base64EncodedString(),
            sig: WireVectors.meshSigStandard
        )
        XCTAssertThrowsError(
            try PairingCrypto.verifyMeshEnvelope(envelope, expectedOwner: signer.publicKey)
        ) { error in
            XCTAssertEqual(error as? MeshBlobError, .badSignature)
        }
    }

    /// A validly-signed blob belonging to a *different* Owner must be refused
    /// when we asked for ours. `pi-extension/src/mesh/verify.ts:17-23` warns
    /// about exactly this; here it is enforced rather than documented.
    func testVerifyMeshEnvelopeRejectsAnUnexpectedOwner() throws {
        let stranger = try Ed25519Signer()
        let envelope = MeshEnvelope(
            blob: Data(WireVectors.meshCanonicalJSON.utf8).base64EncodedString(),
            sig: WireVectors.meshSigStandard
        )
        XCTAssertThrowsError(
            try PairingCrypto.verifyMeshEnvelope(envelope, expectedOwner: stranger.publicKey))
    }

    /// Signing someone else's membership would produce an envelope the relay
    /// accepts (the embedded key verifies) and every Mac ignores.
    func testSignMeshBlobRefusesToSignAnotherOwnersBlob() throws {
        let signer = try nobleSigner()
        let stranger = try Ed25519Signer()
        XCTAssertThrowsError(
            try PairingCrypto.signMeshBlob(exampleBlob(owner: stranger.publicKey), using: signer))
    }

    /// `/mesh/<hash>` is the digest of the **raw key bytes**. Hashing either
    /// Base64 spelling produces a URL the relay answers with an empty
    /// membership instead of an error — a silent, total self-revoke of every
    /// paired Mac.
    func testMeshPathHashIsTheDigestOfTheRawKeyBytes() throws {
        let owner = try XCTUnwrap(PeerID(base64: WireVectors.noblePubkeyStandard))
        XCTAssertEqual(PairingCrypto.meshPathHash(for: owner), WireVectors.meshPathHashHex)

        XCTAssertNotEqual(
            PairingCrypto.meshPathHash(for: owner),
            sha256Hex(Data(WireVectors.noblePubkeyStandard.utf8)),
            "hashing the Base64 text is the bug this pins"
        )
        XCTAssertNotEqual(
            PairingCrypto.meshPathHash(for: owner),
            sha256Hex(Data(WireVectors.noblePubkeyURLSafe.utf8))
        )
    }

    /// `nickname` is **omitted**, never `null`, when absent — the relay's Rust
    /// type skips a `None` and any spelling difference changes the signed
    /// bytes. Pinned as a byte comparison because that is the only thing that
    /// matters here.
    func testNicknameIsOmittedNotNulled() throws {
        let signer = try nobleSigner()
        var blob = try exampleBlob(owner: signer.publicKey)
        blob.members[0].nickname = nil

        let json = String(decoding: try blob.canonicalBytes(), as: UTF8.self)
        XCTAssertFalse(json.contains("nickname"))
        XCTAssertTrue(json.contains("{\"paired_at\":"))
    }
}
