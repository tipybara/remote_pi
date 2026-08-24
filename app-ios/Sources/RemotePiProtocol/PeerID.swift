import Foundation

/// A peer identity on the relay: the raw 32 bytes of an Ed25519 public key.
///
/// ## Why this is a type and not a `String`
///
/// The same key is spelled two different ways in this product, and every
/// recurring routing bug in the Flutter client came from mixing them up
/// (see `app/lib/data/transport/epk_encoding.dart`, whose header comment is
/// a list of the times this broke):
///
/// | Surface | Spelling |
/// |---|---|
/// | Relay registry, `hello.pubkey`, `Envelope.peer`, every control frame | **standard** Base64, RFC 4648 §4 (`+` `/`), **with** `=` padding |
/// | QR payload (`remotepi://pair?epk=…`), Flutter's `PairingStorage` keys | **URL-safe** Base64, RFC 4648 §5 (`-` `_`), **no** padding |
/// | `mesh_versions` blob (`owner_pk`, `members[].remote_epk`) | **standard** Base64, with padding |
///
/// Storing the *bytes* removes the question. Two `PeerID`s are equal when the
/// keys are equal, regardless of how either arrived. Serialization picks a
/// spelling explicitly at the boundary — ``wireValue`` outbound to the relay,
/// ``urlSafeValue`` for a QR or a local storage key.
///
/// ## Invariant
///
/// `PeerID` always holds exactly 32 bytes. There is no representation of a
/// malformed key: parsing is failable, and a failure is surfaced rather than
/// passed along. (The Dart helper returns malformed input unchanged "so we
/// never silently drop a bad-looking peer id"; the Swift equivalent of that
/// courtesy is ``init(lenient:)``, which is explicitly named so a caller
/// cannot reach it by accident.)
///
/// ## Accepted input
///
/// ``init(base64:)`` mirrors the relay's `decode_ed25519_public_key`
/// (`relay/src/identity.rs`) exactly, because the relay is the thing that will
/// reject us:
///
/// - standard and URL-safe alphabets, padded or unpadded — all four accepted;
/// - **mixed** alphabets (`+` together with `_`) — rejected;
/// - trailing garbage, extra padding, interior padding, leading/trailing
///   whitespace or newlines — rejected;
/// - anything that does not decode to exactly 32 bytes — rejected.
///
/// Non-canonical trailing bits (the last Base64 symbol encoding bits that the
/// 32-byte length cannot use) are rejected too: `Data(base64Encoded:)` is
/// strict about them on Apple platforms, which happens to match the Rust side.
public struct PeerID: Hashable, Sendable {
    /// Length of an Ed25519 public key, in bytes. Not configurable.
    public static let byteCount = 32

    /// The raw public key. Always ``byteCount`` bytes.
    public let rawValue: Data

    /// Wraps raw key bytes. Fails unless there are exactly ``byteCount``.
    public init?(rawValue: Data) {
        guard rawValue.count == Self.byteCount else { return nil }
        self.rawValue = rawValue
    }

    /// Parses either Base64 spelling into a key. See the type doc for exactly
    /// what is accepted and what is refused.
    public init?(base64 encoded: String) {
        guard let data = Base64.decodeEd25519Key(encoded) else { return nil }
        self.rawValue = data
    }

    /// Last-resort parse for input from an untrusted or legacy surface where
    /// dropping the value would be worse than carrying a suspect one.
    ///
    /// Returns `nil` exactly when ``init(base64:)`` does — it exists to make
    /// the *call site* say out loud that it tolerated something odd, not to
    /// widen what parses. Use it when logging the rejection matters.
    public static func lenient(_ encoded: String) -> PeerID? {
        PeerID(base64: encoded)
    }

    /// Standard Base64 **with** padding — the spelling the relay stores in its
    /// registry and echoes back in `peer` fields. Use this for `hello.pubkey`,
    /// ``Envelope/peer``, `subscribe_rooms`/`subscribe_presence` peer lists,
    /// and the `mesh_versions` blob.
    public var wireValue: String {
        rawValue.base64EncodedString()
    }

    /// URL-safe Base64, **unpadded** — the spelling in the QR payload and in
    /// on-device storage keys. Never send this to the relay: it is accepted by
    /// the relay's own decoder, but it will *not* match the `peer` strings the
    /// relay sends back, and comparing the two spellings as strings is the
    /// original bug.
    public var urlSafeValue: String {
        rawValue.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Short suffix for logs, matching the relay's own `peer_short`
    /// (last 8 characters of the standard Base64 form).
    public var shortDescription: String {
        String(wireValue.suffix(8))
    }
}

extension PeerID: CustomStringConvertible {
    /// Deliberately the short form: a full key in a log line is noise, and
    /// printing the wire form invites string comparison.
    public var description: String { "PeerID(…\(shortDescription))" }
}

extension PeerID: Codable {
    /// Decodes from either spelling; encodes to ``wireValue``.
    ///
    /// This asymmetry is the point. Anything that round-trips a `PeerID`
    /// through `Codable` — a control frame, a persisted record — comes back
    /// out in the spelling the relay uses, so a value that entered from a QR
    /// code cannot leak its URL-safe form onto the wire.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let encoded = try container.decode(String.self)
        guard let parsed = PeerID(base64: encoded) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "not a 32-byte Ed25519 key in base64: \(encoded)"
            )
        }
        self = parsed
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}

/// Base64 helpers shared by the protocol types.
///
/// Kept here rather than in `RemotePiCrypto` on purpose: the encoding rules
/// are part of the *wire contract*, and the wire contract is this module.
public enum Base64 {
    /// Decodes an Ed25519 public key from any of the four Base64 spellings,
    /// applying the relay's rules (`relay/src/identity.rs`).
    ///
    /// Returns `nil` for mixed alphabets, malformed padding, trailing data,
    /// or a decoded length other than 32.
    public static func decodeEd25519Key(_ encoded: String) -> Data? {
        guard let data = decodeTolerant(encoded), data.count == PeerID.byteCount else {
            return nil
        }
        return data
    }

    /// Decodes standard or URL-safe Base64, padded or unpadded.
    ///
    /// Rejects a string that mixes the two alphabets, and rejects anything
    /// `Data(base64Encoded:)` will not take with strict options — that covers
    /// whitespace, interior/extra padding and trailing garbage, all of which
    /// the relay also refuses.
    public static func decodeTolerant(_ encoded: String) -> Data? {
        if encoded.isEmpty { return nil }
        let hasStandardChars = encoded.contains(where: { $0 == "+" || $0 == "/" })
        let hasURLSafeChars = encoded.contains(where: { $0 == "-" || $0 == "_" })
        if hasStandardChars && hasURLSafeChars { return nil }

        var normalized = encoded
        if hasURLSafeChars {
            normalized = normalized
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
        }
        // Re-pad to a multiple of four. An input that already carries the
        // wrong amount of padding stays wrong and fails below, which is what
        // we want.
        let remainder = normalized.count % 4
        if remainder != 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: normalized, options: [])
    }

    /// Standard Base64 with padding — the outer envelope's `ct` spelling and
    /// the `mesh_versions` `blob`/`sig` spelling.
    public static func encodeStandard(_ data: Data) -> String {
        data.base64EncodedString()
    }
}
