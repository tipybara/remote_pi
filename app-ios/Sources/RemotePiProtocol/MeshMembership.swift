import Foundation

/// One machine in the Owner's signed membership list.
public struct MeshMember: Hashable, Sendable {
    /// The machine's Pi-key.
    public var remoteEpk: PeerID
    /// Relay the pairing happened on.
    public var relayURL: String
    /// ISO-8601.
    public var pairedAt: String
    /// User label. **Omitted from the JSON when nil** — never written as
    /// `null`, because the relay's Rust type skips a `None` and any spelling
    /// difference changes the signed bytes.
    public var nickname: String?

    public init(remoteEpk: PeerID, relayURL: String, pairedAt: String, nickname: String? = nil) {
        self.remoteEpk = remoteEpk
        self.relayURL = relayURL
        self.pairedAt = pairedAt
        self.nickname = nickname
    }
}

/// The Owner-signed membership blob — the only thing the relay's SQLite stores,
/// and the only surviving piece of the deleted "mesh" vocabulary.
///
/// It is how a phone proves authority to pair and to revoke: a machine polls
/// `GET /mesh/<hash>`, verifies the signature locally, and **self-revokes**
/// (exits gracefully, gateway included) when its own Pi-key is no longer in
/// ``members``.
///
/// ## Canonical bytes — the part that breaks silently
///
/// The signature covers a byte sequence, not a structure. Three implementations
/// must produce that sequence identically (this client, the relay's
/// `mesh/verify.rs`, the pi-extension's self-revoke client), and a mismatch
/// shows up only as "signature invalid" with nothing to point at. The rules:
///
/// - **Keys sorted lexicographically at every level**, including inside each
///   member object (`nickname`, `paired_at`, `relay_url`, `remote_epk`).
/// - **No whitespace.** Compact separators, no trailing newline.
/// - **`owner_pk` and `remote_epk` in standard Base64 with padding.**
/// - **Absent keys, not null keys**, for an omitted `nickname`.
/// - **Member order is preserved as given** — it is *not* sorted. Two
///   memberships with the same members in a different order are different
///   bytes and different signatures. Sort before constructing if you want
///   stable output.
///
/// ``canonicalBytes()`` is the single place that decides this; when in doubt,
/// compare its output byte-for-byte with the other implementations rather than
/// comparing parsed structures.
///
/// ## Anti-rollback
///
/// ``version`` is strictly monotonic. The relay rejects `new <= current` with
/// HTTP 409, and last-writer-wins settles genuine conflicts. The in-process
/// floor resets when a process restarts — persistence of the floor across
/// restarts is *not* implemented, and the protocol doc says so.
public struct MeshBlob: Hashable, Sendable {
    /// Strictly positive and strictly increasing per publish.
    public var version: Int
    /// Milliseconds since epoch, UTC.
    public var issuedAt: Int64
    /// The Owner's Ed25519 public key. Serialized as standard Base64.
    public var ownerPk: PeerID
    /// Paired machines, in the order they will be serialized.
    public var members: [MeshMember]

    public init(version: Int, issuedAt: Int64, ownerPk: PeerID, members: [MeshMember] = []) {
        self.version = version
        self.issuedAt = issuedAt
        self.ownerPk = ownerPk
        self.members = members
    }

    /// The exact bytes that get signed and verified. See the canonicalization
    /// rules on the type.
    public func canonicalBytes() throws -> Data {
        var out = "{"
        out += "\"issued_at\":\(issuedAt),"
        out += "\"members\":["
        out += members.map { member in
            var fields: [String] = []
            // Lexicographic: nickname < paired_at < relay_url < remote_epk.
            if let nickname = member.nickname {
                fields.append("\"nickname\":\(Self.jsonString(nickname))")
            }
            fields.append("\"paired_at\":\(Self.jsonString(member.pairedAt))")
            fields.append("\"relay_url\":\(Self.jsonString(member.relayURL))")
            fields.append("\"remote_epk\":\(Self.jsonString(member.remoteEpk.wireValue))")
            return "{" + fields.joined(separator: ",") + "}"
        }.joined(separator: ",")
        out += "],"
        out += "\"owner_pk\":\(Self.jsonString(ownerPk.wireValue)),"
        out += "\"version\":\(version)"
        out += "}"
        guard let data = out.data(using: .utf8) else {
            throw MeshBlobError.notUTF8
        }
        return data
    }

    /// Parses canonical (or merely valid) blob bytes. Key order is not
    /// enforced when reading — canonicalization is a rule for *producing*.
    public static func parse(_ data: Data) throws -> MeshBlob {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MeshBlobError.malformed("root must be a JSON object")
        }
        guard let version = (object["version"] as? NSNumber)?.intValue, version > 0 else {
            throw MeshBlobError.malformed("version must be a positive integer")
        }
        guard let issuedAt = (object["issued_at"] as? NSNumber)?.int64Value else {
            throw MeshBlobError.malformed("issued_at must be an integer")
        }
        guard let ownerPk = (object["owner_pk"] as? String).flatMap(PeerID.init(base64:)) else {
            throw MeshBlobError.malformed("owner_pk must be a 32-byte key in base64")
        }
        let rawMembers = object["members"] as? [[String: Any]] ?? []
        let members: [MeshMember] = try rawMembers.map { element in
            guard
                let epk = (element["remote_epk"] as? String).flatMap(PeerID.init(base64:)),
                let relayURL = element["relay_url"] as? String,
                let pairedAt = element["paired_at"] as? String
            else {
                throw MeshBlobError.malformed("member is missing required fields")
            }
            return MeshMember(
                remoteEpk: epk,
                relayURL: relayURL,
                pairedAt: pairedAt,
                nickname: element["nickname"] as? String
            )
        }
        return MeshBlob(version: version, issuedAt: issuedAt, ownerPk: ownerPk, members: members)
    }

    private static func jsonString(_ value: String) -> String {
        // Round-trip through JSONSerialization so escaping matches what every
        // other implementation's serializer produces for the same string.
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: [value],
                options: [.withoutEscapingSlashes]
            ),
            let array = String(data: data, encoding: .utf8)
        else {
            return "\"\""
        }
        return String(array.dropFirst().dropLast())
    }
}

public enum MeshBlobError: Error, Sendable, Hashable {
    case malformed(String)
    case notUTF8
    /// The signature did not verify, or the embedded `owner_pk` was not the
    /// key we expected to have signed it.
    case badSignature
}

/// Wire and storage form of a signed membership:
/// `{ "blob": "<base64 of the canonical bytes>", "sig": "<base64 Ed25519>" }`.
///
/// - `POST /mesh/<hash>` publishes a new version; the relay verifies the
///   signature and the version monotonicity.
/// - `GET /mesh/<hash>` returns the latest; the client re-verifies locally
///   rather than trusting the relay.
/// - `hash` is the **lowercase hex SHA-256 of the 32 raw Owner-key bytes** —
///   of the key, not of its Base64 text.
public struct MeshEnvelope: Hashable, Sendable, Codable {
    /// Base64 (standard) of ``MeshBlob/canonicalBytes()``.
    public var blob: String
    /// Base64 (standard) of the 64-byte Ed25519 signature over those bytes.
    public var sig: String

    public init(blob: String, sig: String) {
        self.blob = blob
        self.sig = sig
    }

    public init(blobData: Data, signature: Data) {
        self.blob = Base64.encodeStandard(blobData)
        self.sig = Base64.encodeStandard(signature)
    }

    public var blobData: Data? { Base64.decodeTolerant(blob) }
    public var signatureData: Data? { Base64.decodeTolerant(sig) }
}
