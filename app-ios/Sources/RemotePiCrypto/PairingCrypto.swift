import Foundation
import RemotePiProtocol

/// The cryptography of pairing — which is almost entirely *not* in the pairing
/// frames.
///
/// ## `pair_request` carries no signature. Do not add one.
///
/// `PROTOCOL.md:325` and `plan/04-pairing.md` describe "an Owner-signed
/// `pair_request`" and an ephemeral App-key. **No implementation does that**
/// (spec 62-04 §12 D1). The wire type has exactly four fields
/// (`pi-extension/src/protocol/types.ts:176`,
/// `app/lib/protocol/protocol.dart:713-729`):
///
/// ```json
/// { "type": "pair_request", "id": "<uuid>", "token": "<the QR's t, verbatim>",
///   "device_name": "iPhone" }
/// ```
///
/// no `sig`, no `owner_pk`, no timestamp. Authenticity comes from somewhere
/// else entirely: the Owner key authenticated the **WebSocket** through
/// ``RelayAuth``, and the relay rewrites `outer.peer` to the sender's
/// authenticated peer id before the Pi sees the frame
/// (`relay/src/handlers/peer.rs:392-396`). The Pi reads the Owner identity
/// from that rewritten field (`pi-extension/src/index.ts:1894`) and trusts the
/// relay for it. So the pairing signature *is* the challenge signature, made
/// with the same long-lived Owner key the steady-state connection uses — there
/// is no ephemeral App-key in this fork, whatever `PROTOCOL.md:41` says.
///
/// A native client that *requires* a `pair_request` signature would never
/// pair, and one that *adds* an extra field would merely be ignored. Build
/// neither.
///
/// ## The second Owner signature is real, and it is the mesh blob
///
/// Pairing is not durable until the phone republishes the signed membership
/// blob: the pi-extension and the supervisor gateway poll `GET /mesh/<hash>`
/// and **self-revoke** when their own Pi-key is not listed
/// (spec 62-04 §10, `PROTOCOL.md:305-307`). That is what the rest of this file
/// is for.
public enum PairingCrypto {
    /// The `<hash>` in `/mesh/<hash>`: lowercase hex SHA-256 of the **32 raw
    /// Owner-key bytes**.
    ///
    /// **Trap.** Hashing the Base64 *text* of the key — either spelling —
    /// produces a well-formed URL that the relay answers with an *empty*
    /// membership rather than an error. The phone would then believe it has
    /// published, every paired Mac would keep polling the real slot, find
    /// itself absent, and self-revoke. Silent, delayed, and total.
    /// `app/lib/data/mesh/mesh_client.dart:135-143` hashes
    /// `base64Decode(ownerPk)` for this reason.
    public static func meshPathHash(for owner: PeerID) -> String {
        sha256Hex(owner.rawValue)
    }

    /// Signs a membership blob with the Owner key and packages the wire
    /// envelope.
    ///
    /// The signature covers ``MeshBlob/canonicalBytes()`` — the exact bytes,
    /// not the structure. The relay does **not** canonicalize before verifying
    /// (`relay/src/mesh/verify.rs`: "verifies the signature against exactly the
    /// bytes received"), so the envelope must carry the very bytes that were
    /// signed. That is why this returns `blob` and `sig` together and never
    /// re-serializes the blob afterwards: a second serialization pass is a
    /// chance to emit different bytes, and the failure mode is a bare
    /// "signature invalid" with nothing to point at.
    ///
    /// `blob` and `sig` are **standard** Base64 with padding — the relay
    /// decodes both with the `STANDARD` engine only
    /// (`relay/src/mesh/verify.rs:75-85`).
    ///
    /// The blob's `owner_pk` must be the signer's own key; a blob signed by
    /// anyone else verifies against the embedded key and would be accepted by
    /// the relay while being useless to every Mac polling *our* hash slot.
    public static func signMeshBlob(_ blob: MeshBlob, using signer: any Signer) throws
        -> MeshEnvelope
    {
        guard blob.ownerPk == signer.publicKey else {
            throw MeshSignatureError.ownerMismatch(
                expected: signer.publicKey, found: blob.ownerPk)
        }
        let bytes = try blob.canonicalBytes()
        let signature = try signer.signature(for: bytes)
        return MeshEnvelope(blobData: bytes, signature: signature)
    }

    /// Verifies a fetched envelope locally and returns the parsed blob.
    ///
    /// Two checks, and the second is the one that is easy to forget:
    ///
    /// 1. the signature verifies against the `owner_pk` **embedded in the
    ///    blob** — that is the only key that can have signed it;
    /// 2. that embedded key is the one whose hash we queried
    ///    (`expectedOwner`). Without this a malicious or confused relay could
    ///    serve a valid-but-different-owner blob at our hash slot and we would
    ///    happily accept its member list. `pi-extension/src/mesh/verify.ts:17-23`
    ///    carries the same warning in prose; here it is a parameter so the
    ///    caller has to say something.
    ///
    /// Pass `expectedOwner: nil` only when the caller genuinely does not know
    /// the owner yet (there is no such caller today).
    @discardableResult
    public static func verifyMeshEnvelope(
        _ envelope: MeshEnvelope,
        expectedOwner: PeerID?
    ) throws -> MeshBlob {
        guard let blobData = envelope.blobData else {
            throw MeshSignatureError.malformedEnvelope("blob is not base64")
        }
        guard let signature = envelope.signatureData else {
            throw MeshSignatureError.malformedEnvelope("sig is not base64")
        }
        guard signature.count == RelayAuth.signatureByteCount else {
            throw MeshSignatureError.malformedEnvelope(
                "sig is \(signature.count) bytes, expected 64")
        }
        // Parse before verifying purely to learn `owner_pk`; the verification
        // below runs against the raw received bytes, never against anything
        // re-serialized from the parse.
        let blob = try MeshBlob.parse(blobData)
        guard verifyEd25519(signature: signature, of: blobData, by: blob.ownerPk) else {
            throw MeshBlobError.badSignature
        }
        if let expectedOwner, expectedOwner != blob.ownerPk {
            throw MeshSignatureError.ownerMismatch(expected: expectedOwner, found: blob.ownerPk)
        }
        return blob
    }
}

public enum MeshSignatureError: Error, Sendable, Hashable {
    /// The blob's `owner_pk` is not the key we expected — either we tried to
    /// sign someone else's membership, or the relay served a blob belonging to
    /// a different Owner at our hash slot.
    case ownerMismatch(expected: PeerID, found: PeerID)
    case malformedEnvelope(String)
}
