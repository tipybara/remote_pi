import Foundation
import XCTest

@testable import RemotePiCrypto
@testable import RemotePiPairing
@testable import RemotePiProtocol

/// Golden vectors for the membership blob.
///
/// The canonical string and the signature below were produced **outside this
/// package**, by Node's `crypto` over the same key-ordering rules
/// `app/lib/data/mesh/mesh_blob.dart:132-147` implements (`SplayTreeMap` at
/// both levels + `jsonEncode`) — the same runtime the pi-extension verifies
/// with. Asserting our encoder against our decoder would prove nothing; this
/// pins us to what the other implementations actually emit and accept.
final class MeshWireTests: XCTestCase {
    // seed = (i*7 + 1) & 0xff for i in 0..<32
    private let ownerSeedHex = "01080f161d242b323940474e555c636a71787f868d949ba2a9b0b7bec5ccd3da"
    private let ownerPkB64 = "5AMJmM/VrRcjwWn5VqoLnrhhm1mSvWEsKvQo68efjfA="
    private let epkAStandard = "AgcMERYbICUqLzQ5PkNITVJXXGFma3B1en+EiY6TmJ0="
    private let epkAURLSafe = "AgcMERYbICUqLzQ5PkNITVJXXGFma3B1en-EiY6TmJ0"
    private let epkBStandard = "Aw4ZJC86RVBbZnF8h5KdqLO+ydTf6vUACxYhLDdCTVg="

    private let canonical =
        #"{"issued_at":1780000000000,"members":[{"nickname":"Mac do trabalho","paired_at":"2026-05-22T10:30:00.000Z","relay_url":"https://relay-rp1.jacobmoura.work","remote_epk":"AgcMERYbICUqLzQ5PkNITVJXXGFma3B1en+EiY6TmJ0="},{"paired_at":"2026-06-01T08:00:00.000Z","relay_url":"https://relay-rp1.jacobmoura.work","remote_epk":"Aw4ZJC86RVBbZnF8h5KdqLO+ydTf6vUACxYhLDdCTVg="}],"owner_pk":"5AMJmM/VrRcjwWn5VqoLnrhhm1mSvWEsKvQo68efjfA=","version":7}"#

    private let signatureB64 =
        "d/oO2Btgvr/Ci1ygfdrPFVz4WBQnAIeNeO2SFKHdfaPXGjBD/hHtlXigTikzLE2FpjZLhK/ifbP26VAxzkTAAg=="

    private let ownerPkHash =
        "d3c05ab2093cb2205b52f71c54e2c8d4394504e66149c0e81d859bbc387f6ca6"

    private func goldenBlob() throws -> MeshBlob {
        MeshBlob(
            version: 7,
            issuedAt: 1_780_000_000_000,
            ownerPk: try XCTUnwrap(PeerID(base64: ownerPkB64)),
            members: [
                MeshMember(
                    remoteEpk: try XCTUnwrap(PeerID(base64: epkAStandard)),
                    relayURL: "https://relay-rp1.jacobmoura.work",
                    pairedAt: "2026-05-22T10:30:00.000Z",
                    nickname: "Mac do trabalho"
                ),
                MeshMember(
                    remoteEpk: try XCTUnwrap(PeerID(base64: epkBStandard)),
                    relayURL: "https://relay-rp1.jacobmoura.work",
                    pairedAt: "2026-06-01T08:00:00.000Z"
                ),
            ]
        )
    }

    func testCanonicalBytesMatchTheOtherImplementations() throws {
        let bytes = try goldenBlob().canonicalBytes()
        XCTAssertEqual(String(data: bytes, encoding: .utf8), canonical)
        // Trap T2, both halves: `JSONEncoder` would write `https:\/\/…` and
        // every `relay_url` has two slashes in it, and even `.sortedKeys`
        // leaves the escaping table up to Foundation.
        XCTAssertFalse(canonical.contains(#"\/"#))
        // The nickname-less member omits the key entirely — it is never `null`.
        XCTAssertEqual(canonical.components(separatedBy: "\"nickname\"").count - 1, 1)
        // No *structural* whitespace: compact separators, no trailing
        // newline. (A space inside a string value is content — the fixture's
        // nickname has two.) Same assertion as
        // `app/test/data/mesh/mesh_blob_test.dart:112-114`, scoped to a blob
        // whose values contain none.
        let plain = MeshBlob(
            version: 1,
            issuedAt: 1,
            ownerPk: try XCTUnwrap(PeerID(base64: ownerPkB64)),
            members: [
                MeshMember(
                    remoteEpk: try XCTUnwrap(PeerID(base64: epkAStandard)),
                    relayURL: "https://r",
                    pairedAt: "t",
                    nickname: "casa"
                )
            ]
        )
        for byte in try plain.canonicalBytes() {
            XCTAssertFalse([0x20, 0x09, 0x0A].contains(byte))
        }
    }

    func testSignatureIsByteIdenticalToTheReferenceImplementation() throws {
        let seed = try XCTUnwrap(Data(hexString: ownerSeedHex))
        let signer = try Ed25519Signer(seed: seed)
        XCTAssertEqual(signer.publicKey.wireValue, ownerPkB64)

        let bytes = try goldenBlob().canonicalBytes()

        // The load-bearing direction: a signature produced **elsewhere** over
        // that implementation's canonical bytes verifies against the bytes we
        // rebuilt. If our canonicalization drifted by one byte — a `\/`, a
        // reordered key, a url-safe epk — this fails, which is precisely the
        // failure the relay reports as a bare `403 sig_invalid` with nothing
        // to point at.
        //
        // It has to be this direction: CryptoKit's Ed25519 signing is
        // randomized (hedged nonce), so our own signature bytes differ run to
        // run and cannot be compared to a fixture.
        let pinned = try XCTUnwrap(Base64.decodeTolerant(signatureB64))
        XCTAssertTrue(
            verifyEd25519(signature: pinned, of: bytes, by: signer.publicKey),
            "canonical bytes disagree with the reference implementation"
        )
        // And our own signature verifies, so the relay would accept it.
        let ours = try signer.signature(for: bytes)
        XCTAssertTrue(verifyEd25519(signature: ours, of: bytes, by: signer.publicKey))
        // One flipped byte anywhere in the canonical form breaks it — the
        // reason canonicalization is a producer discipline and not a nicety.
        var tampered = bytes
        tampered[tampered.startIndex] = 0x20
        XCTAssertFalse(verifyEd25519(signature: pinned, of: tampered, by: signer.publicKey))
    }

    func testParseAcceptsTheGoldenBytes() throws {
        let parsed = try MeshBlob.parse(Data(canonical.utf8))
        XCTAssertEqual(parsed, try goldenBlob())
    }

    func testEnvelopeIsBase64StandardBothWays() throws {
        let bytes = try goldenBlob().canonicalBytes()
        let signature = try XCTUnwrap(Base64.decodeTolerant(signatureB64))
        let envelope = MeshEnvelope(blobData: bytes, signature: signature)
        XCTAssertEqual(envelope.sig, signatureB64)
        XCTAssertEqual(envelope.blobData, bytes)
        let json = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(envelope)
        ) as! [String: Any]
        XCTAssertEqual(Set(json.keys), ["blob", "sig"])
    }

    func testOwnerHashIsOverKeyBytesNotBase64Text() throws {
        let owner = try XCTUnwrap(PeerID(base64: ownerPkB64))
        XCTAssertEqual(meshPathHash(for: owner), ownerPkHash)
        // Trap T4: hashing the Base64 text gives a valid-looking 64-hex string
        // that 403s on POST and 404s on GET forever.
        XCTAssertNotEqual(sha256Hex(Data(ownerPkB64.utf8)), ownerPkHash)
        // `relay/src/mesh/verify.rs:186-193` sanity vector.
        XCTAssertEqual(
            sha256Hex(Data()),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    /// Trap T1/T11. The QR hands over a url-safe unpadded key; the blob must
    /// carry the standard padded spelling, because the pi-extension compares
    /// `members[].remote_epk` against its own key formatted as standard base64
    /// and a mismatch reads as "I am not listed" → self-revoke.
    func testURLSafeKeyNormalizesToStandardInTheBlob() throws {
        let fromQR = try XCTUnwrap(PeerID(base64: epkAURLSafe))
        XCTAssertEqual(fromQR.wireValue, epkAStandard)
        let blob = MeshBlob(
            version: 1,
            issuedAt: 1,
            ownerPk: try XCTUnwrap(PeerID(base64: ownerPkB64)),
            members: [
                MeshMember(remoteEpk: fromQR, relayURL: "https://r", pairedAt: "t")
            ]
        )
        let text = String(data: try blob.canonicalBytes(), encoding: .utf8)!
        XCTAssertTrue(text.contains("\"remote_epk\":\"\(epkAStandard)\""))
    }

    // MARK: - HTTP

    func testMeshURLShape() throws {
        let owner = try XCTUnwrap(PeerID(base64: ownerPkB64))
        XCTAssertEqual(
            MeshClient.meshURL(base: URL(string: "https://relay.example")!, owner: owner)?
                .absoluteString,
            "https://relay.example/mesh/\(ownerPkHash)"
        )
        // Trailing slashes are stripped — a `//mesh/` path does not route.
        XCTAssertEqual(
            MeshClient.meshURL(base: URL(string: "https://relay.example//")!, owner: owner)?
                .absoluteString,
            "https://relay.example/mesh/\(ownerPkHash)"
        )
    }

    func testConflictBodyCarriesTheCurrentVersion() {
        // `handler.rs:37-40` formats exactly this.
        XCTAssertEqual(MeshClient.parseConflictVersion("stale_version (current=12)"), 12)
        XCTAssertNil(MeshClient.parseConflictVersion("payload_too_large"))
    }

    func testPublishStatusMapping() async throws {
        let owner = try XCTUnwrap(PeerID(base64: ownerPkB64))
        let envelope = MeshEnvelope(blob: "AA==", sig: "AA==")
        let cases: [(FakeMeshHTTP.Response, MeshPublishResult)] = [
            (
                .json(200, ["version": 8, "updated_at": 1_780_000_000_123]),
                .ok(version: 8, updatedAt: 1_780_000_000_123)
            ),
            // 4xx bodies are text/plain (trap T13) — decoding them as JSON
            // throws away the only useful thing they carry.
            (.text(400, "invalid json: expected value"), .badRequest("invalid json: expected value")),
            (.text(403, "sig_invalid"), .forbidden("sig_invalid")),
            (.text(409, "stale_version (current=12)"), .conflict(current: 12)),
            (.text(413, "payload_too_large"), .tooLarge),
        ]
        for (response, expected) in cases {
            let http = FakeMeshHTTP([response])
            let client = MeshClient(baseURL: URL(string: "https://relay.example")!, http: http)
            let result = await client.publish(owner: owner, envelope: envelope)
            XCTAssertEqual(result, expected)
            XCTAssertEqual(
                http.requests.first?.value(forHTTPHeaderField: "Content-Type"),
                "application/json"
            )
        }
    }

    func testFetchStatusMapping() async throws {
        let owner = try XCTUnwrap(PeerID(base64: ownerPkB64))
        let http = FakeMeshHTTP([
            .json(
                200,
                [
                    "blob": "eyJ4IjoxfQ==", "sig": "AA==", "version": 7,
                    "updated_at": 1_780_000_000_123,
                ]
            ),
            // 304 has an EMPTY body — decoding it is a bug, and `since` is
            // compared with `<=` so `since == current` lands here.
            .text(304, ""),
            .text(404, "not_found"),
        ])
        let client = MeshClient(baseURL: URL(string: "https://relay.example")!, http: http)

        guard case .ok(let envelope, let version, let updatedAt) = await client.fetch(owner: owner)
        else { return XCTFail("expected ok") }
        XCTAssertEqual(envelope.blob, "eyJ4IjoxfQ==")
        XCTAssertEqual(version, 7)
        XCTAssertEqual(updatedAt, 1_780_000_000_123)

        guard case .notModified = await client.fetch(owner: owner, since: 7) else {
            return XCTFail("expected notModified")
        }
        XCTAssertTrue(
            http.requests[1].url!.absoluteString.hasSuffix("?since=7"),
            "the watermark rides as a bare integer query parameter"
        )

        guard case .notFound = await client.fetch(owner: owner) else {
            return XCTFail("expected notFound")
        }
    }
}

extension Data {
    /// Test helper — hex is only ever used for fixtures and for the mesh path.
    init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
