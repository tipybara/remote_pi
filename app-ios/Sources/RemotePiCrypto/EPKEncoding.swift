import Foundation
import RemotePiProtocol

/// String-level Base64 coercion for peer keys, mirroring
/// `app/lib/data/transport/epk_encoding.dart` **exactly**.
///
/// ## Prefer ``PeerID``
///
/// New code should carry 32 raw bytes (``PeerID``) and pick a spelling at the
/// boundary (``PeerID/wireValue`` outbound, ``PeerID/urlSafeValue`` for QR and
/// storage keys). That removes the question entirely and is what
/// spec 62-03 §7 T1 recommends.
///
/// This type exists for the surfaces where a key is unavoidably a *string* of
/// unknown provenance and dropping it would be worse than carrying it:
///
/// - a legacy `PeerRecord` / room-cache key migrated from the Flutter app,
///   whose spelling is "whatever the QR happened to contain";
/// - a `peers[]` list echoed back from the relay;
/// - anything read out of an old preference blob.
///
/// ## Why the Dart semantics, and not stricter ones
///
/// The Dart helpers deliberately **return unparseable input unchanged** — the
/// header comment says "so we never silently drop a bad-looking peer id". They
/// are also **idempotent**: an already-standard key survives ``toStandardB64``
/// untouched, and an already-url-safe key survives ``toAppEPK`` untouched.
/// Both properties are relied on by call sites that normalize repeatedly (the
/// Flutter `ConnectionManager` normalizes on every inbound control frame).
///
/// ## Divergence from ``Base64/decodeTolerant(_:)`` — deliberate
///
/// `RemotePiProtocol.Base64.decodeTolerant` mirrors the **relay's**
/// `decode_ed25519_public_key` (`relay/src/identity.rs:14-30`), which *rejects*
/// a string mixing `+/` with `-_`. The Dart normalizer does not: Dart's Base64
/// decoder accepts both alphabets and any mix of them, so `toStandardB64`
/// turns a mixed spelling into a clean standard one.
///
/// Keeping that leniency here is the *safer* of the two behaviours, and it is
/// load-bearing: the relay rejects a mixed `hello.pubkey` outright and does no
/// normalization at all on the envelope `peer` field
/// (`relay/src/peers/registry.rs:254` looks the raw string up in a `HashMap`).
/// So a mixed-alphabet key that reaches the wire un-normalized is a silent
/// routing miss — `transport_error: offline` with nothing explaining it — while
/// a mixed key normalized here routes correctly. Refusing to normalize would
/// convert a recoverable mess into an unrecoverable one.
public enum EPKEncoding {
    /// Converts an epk (possibly url-safe, possibly unpadded, possibly mixed)
    /// to **standard Base64 with padding** — the only spelling the relay's
    /// registry matches.
    ///
    /// Idempotent. Unparseable input is returned unchanged.
    ///
    /// Apply to everything transport-bound: `hello.pubkey`,
    /// ``Envelope/peer``, `subscribe_presence` / `subscribe_rooms` /
    /// `presence_check` / `rooms_check` `peers[]`, and
    /// `mesh_versions.members[].remote_epk`.
    ///
    /// Mirrors `toStandardB64` (`epk_encoding.dart:24-36`).
    public static func toStandardB64(_ encoded: String) -> String {
        // Dart short-circuits empty before touching the codec. Preserved so
        // "" maps to "" rather than to the empty-Data encoding (also ""), and
        // so the two implementations agree even if one of them changes.
        if encoded.isEmpty { return encoded }
        guard let bytes = decodeLenient(encoded) else { return encoded }
        return bytes.base64EncodedString()
    }

    /// Converts an epk reported by the relay (standard Base64) into the
    /// **url-safe, unpadded** spelling this app uses for storage keys and QR
    /// payloads.
    ///
    /// Idempotent. Unparseable input is returned unchanged.
    ///
    /// Mirrors `toAppEpk` (`epk_encoding.dart:41-59`), including the padding
    /// strip: the QR carries 43 unpadded characters, and a stored key with a
    /// trailing `=` would not match one built from a scanned QR. The two
    /// spellings are **not** interchangeable as dictionary keys — that is the
    /// bug this whole module exists to contain.
    public static func toAppEPK(_ encoded: String) -> String {
        if encoded.isEmpty { return encoded }
        guard let bytes = decodeLenient(encoded) else { return encoded }
        return bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decodes standard **or** url-safe Base64, padded or unpadded, with the
    /// same acceptance set as Dart's `base64Url.decode(pad(s))`.
    ///
    /// Returns `nil` where Dart throws `FormatException`. Verified against
    /// `dart:convert` case by case:
    ///
    /// | Input | Dart | here |
    /// |---|---|---|
    /// | url-safe unpadded, 43 chars | 32 bytes | 32 bytes |
    /// | standard padded, 44 chars | 32 bytes | 32 bytes |
    /// | **mixed** `-/v7+_v7…` | 32 bytes | 32 bytes |
    /// | `"not base64 at all !!"` | throws | `nil` |
    /// | length % 4 == 1 | throws | `nil` |
    /// | trailing newline / space | throws | `nil` |
    /// | non-canonical trailing bits | throws | `nil` |
    ///
    /// **Trap.** That last row is why this does not simply call
    /// `Data(base64Encoded:)` and stop. Foundation's decoder *accepts* a final
    /// symbol whose unused low bits are non-zero — `…yyQF=` decodes to the same
    /// 32 bytes as `…yyQE=` — whereas Dart's decoder and Rust's `base64`
    /// engine both reject it (`relay/src/identity.rs` has a dedicated test,
    /// `canonical_public_key_rejects_noncanonical_trailing_bits`). Without the
    /// canonicality re-check below we would accept a key spelling the relay
    /// refuses, "normalize" it into a *different* string than the sender used,
    /// and hand it to a registry lookup that compares raw strings. The
    /// symptoms would be a `hello` the relay closes without a word, or a
    /// permanently offline peer.
    public static func decodeLenient(_ encoded: String) -> Data? {
        if encoded.isEmpty { return nil }

        // Both alphabets, and any mix of them — Dart's decoder maps `-`/`+` to
        // 62 and `_`/`/` to 63 from a single table with no cross-alphabet
        // check. See the type doc for why the leniency is kept.
        var normalized = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        // Dart: `pad = (4 - s.length % 4) % 4`. An input that already carries
        // the wrong amount of padding stays wrong and fails below — which is
        // what both reference implementations do.
        let remainder = normalized.count % 4
        if remainder != 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }

        guard let decoded = Data(base64Encoded: normalized, options: []) else {
            return nil
        }
        // Canonicality gate — see the doc comment. Re-encoding is exact here
        // because `normalized` is standard-alphabet and padded by construction.
        guard decoded.base64EncodedString() == normalized else { return nil }
        return decoded
    }
}
