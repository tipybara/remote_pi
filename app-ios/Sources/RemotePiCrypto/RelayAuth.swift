import Foundation
import RemotePiProtocol

/// The relay's challenge-response, as bytes.
///
/// ```text
/// client                                    relay
///   │  {"type":"hello","pubkey":…}  ──────►      (≤ 5000 ms after upgrade)
///   │                               ◄────── {"type":"challenge","nonce":…}
///   │  {"type":"auth","sig":…}      ──────►      (verify; NO ack on success)
/// ```
///
/// `RemotePiTransport` owns the socket and the frames; this type owns the one
/// step that has to be byte-exact against `relay/src/auth/challenge.rs`.
///
/// ## What is signed
///
/// ```text
/// sig = Ed25519_sign(owner_sk, base64_decode(challenge.nonce))
/// ```
///
/// The message is the **32 raw nonce bytes and nothing else**
/// (`challenge.rs:76-89`: `vk.verify(nonce /* &[u8;32] */, &sig)`). There is
/// no domain-separation prefix, no length framing, no hashing by the caller,
/// and the `pubkey` / `room_id` / relay URL are **not** covered. Both
/// reference clients do exactly this — `ws_transport.dart:174-181` and
/// `pi-extension/src/transport/relay_client.ts:264-269`.
///
/// The single most common way to get this wrong is signing the Base64
/// *string* instead of the bytes it denotes. The frame looks perfect on the
/// wire and the relay answers with a bare socket close, because **there is no
/// error frame anywhere in the auth path** (spec 62-03 §1.6): every failure
/// from "your pubkey is malformed" to "your signature is wrong" is an
/// unadorned close, and success is silent too. A client can never learn why.
public enum RelayAuth {
    /// The relay's nonce is a fixed-size array on the Rust side, not a slice.
    public static let nonceByteCount = 32
    /// Ed25519 signature length. `verify_auth` does `try_into::<[u8;64]>()`
    /// and any other length is `AuthError::InvalidSig`.
    public static let signatureByteCount = 64

    /// Decodes the `nonce` of an inbound `challenge` frame.
    ///
    /// The wire value is always **standard Base64 with padding** — the relay
    /// encodes 32 random bytes with `general_purpose::STANDARD`
    /// (`challenge.rs:46-51`), so it is always exactly 44 characters ending in
    /// one `=`. The decode is nonetheless padding- and alphabet-tolerant, the
    /// same defensive choice `ws_transport.dart:302-310` makes (standard
    /// first, url-safe as a fallback).
    ///
    /// The length check is not defensive padding: it is the earliest place a
    /// garbled challenge can be turned into a diagnosable local error instead
    /// of a signature the relay will reject in silence.
    public static func decodeChallengeNonce(_ encoded: String) throws -> Data {
        guard let nonce = EPKEncoding.decodeLenient(encoded) else {
            throw RelayAuthError.malformedNonce(encoded)
        }
        guard nonce.count == nonceByteCount else {
            throw RelayAuthError.unexpectedNonceLength(nonce.count)
        }
        return nonce
    }

    /// Produces the `sig` value for the `auth` frame from an inbound
    /// `challenge` nonce.
    ///
    /// Returns **standard Base64, padded** — 88 characters ending in `==` for
    /// a 64-byte signature.
    public static func signature(forChallengeNonce encoded: String, using signer: any Signer) throws
        -> String
    {
        try signature(forNonceBytes: decodeChallengeNonce(encoded), using: signer)
    }

    /// Signs already-decoded nonce bytes.
    ///
    /// **Trap (spec 62-03 T2).** The returned string must be standard Base64:
    /// `verify_auth` decodes `sig` with the `STANDARD` engine *only*
    /// (`challenge.rs:4`, `:82`) — unlike `pubkey`, there is no url-safe
    /// fallback and no unpadded fallback on this field. A 64-byte signature
    /// almost always contains `+` or `/`, so routing it through a "safe
    /// base64" helper yields a frame the relay rejects with `AuthError::
    /// InvalidSig` and closes on, with no error frame to explain it.
    /// `Data.base64EncodedString()` is standard and padded, which is exactly
    /// right — the danger is a well-meaning helper being reused here.
    public static func signature(forNonceBytes nonce: Data, using signer: any Signer) throws
        -> String
    {
        guard nonce.count == nonceByteCount else {
            throw RelayAuthError.unexpectedNonceLength(nonce.count)
        }
        // Raw bytes. Never `Data(encoded.utf8)`.
        let signature = try signer.signature(for: nonce)
        return signature.base64EncodedString()
    }

    /// The relay's own acceptance test, reimplemented so we can prove locally
    /// that a frame we are about to send would pass.
    ///
    /// Mirrors `verify_auth` (`challenge.rs:76-89`) including its strictness:
    /// **standard Base64 only** (a url-safe `sig` fails here exactly as it
    /// fails there) and **exactly 64 bytes**.
    ///
    /// Not used on the connection path — the relay never asks us to verify
    /// anything — but it is what the test suite and the e2e harness assert
    /// against, and it documents the acceptance set in executable form.
    public static func isValidChallengeSignature(
        _ sigBase64: String,
        nonce: Data,
        peer: PeerID
    ) -> Bool {
        // Deliberately NOT `EPKEncoding.decodeLenient`: the relay's STANDARD
        // engine refuses `-`/`_` and refuses missing padding on this field.
        // Being lenient here would make a signature look acceptable locally
        // and be rejected on the wire — the one outcome a self-check must not
        // produce.
        guard
            let signature = Data(base64Encoded: sigBase64, options: []),
            signature.count == signatureByteCount,
            nonce.count == nonceByteCount
        else { return false }
        return verifyEd25519(signature: signature, of: nonce, by: peer)
    }
}

public enum RelayAuthError: Error, Sendable, Hashable {
    /// `challenge.nonce` was not decodable Base64.
    case malformedNonce(String)
    /// `challenge.nonce` decoded to something other than 32 bytes. The relay
    /// verifies against a `[u8; 32]`, so signing anything else cannot succeed.
    case unexpectedNonceLength(Int)
}
