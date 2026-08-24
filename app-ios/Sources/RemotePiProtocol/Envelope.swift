import Foundation

/// The outer App↔Pi frame — the only frame shape the relay routes.
///
/// ```jsonc
/// { "peer": "<standard base64 Ed25519 pubkey of the destination>",
///   "room": "<room_id>",
///   "ct":   "<standard base64 of the inner JSON>" }
/// ```
///
/// ## `ct` is not ciphertext
///
/// It is Base64 of **plaintext JSON**. The name is historical. The relay never
/// decodes it, but it *could*: there is no end-to-end encryption in this
/// product and the protocol doc says so out loud. Do not write copy that
/// claims otherwise.
///
/// ## What the relay rewrites
///
/// On delivery the relay replaces `peer` with the authenticated **sender** and
/// `room` with the **sender's** room, leaving `ct` untouched
/// (`relay/src/handlers/peer.rs`). So an inbound envelope answers "who sent
/// this, from which of their rooms", while an outbound one says "who should
/// get this, in which of *their* rooms". Same field names, opposite meaning —
/// this is a routine source of confusion when reading a packet dump.
///
/// ## Routing a frame with no `type`
///
/// The relay decides between "control frame" and "envelope" purely by whether
/// the JSON has a top-level `type` key. An envelope must therefore **never**
/// carry one. Conversely, a client reading the socket must check for
/// `peer` + `ct` before attempting to parse a control frame.
///
/// ## Size ceiling
///
/// The relay rejects an envelope whose *estimated decoded* `ct` exceeds
/// ``Envelope/maxDecodedPayloadBytes`` (4 MiB by default, `RELAY_MAX_CT_MIB`
/// on the server). The estimate is `ct.count * 3 / 4` on the Base64 string —
/// not on the real byte count — so use ``Envelope/relayEstimatedPayloadBytes``
/// when checking locally, or an image just under the limit can still be
/// dropped. Images ride a double Base64 (inner `data`, outer `ct`), roughly
/// 1.78× the raw JPEG.
public struct Envelope: Hashable, Sendable, Codable {
    /// Outbound: the destination peer. Inbound: the authenticated sender.
    public let peer: PeerID

    /// Outbound: the destination's room. Inbound: the sender's room.
    ///
    /// The relay defaults a missing `room` to ``RoomID/main``; this client
    /// always writes it explicitly.
    public let room: RoomID

    /// Base64 (standard, padded) of the inner JSON payload.
    public let ct: String

    public init(peer: PeerID, room: RoomID, ct: String) {
        self.peer = peer
        self.room = room
        self.ct = ct
    }

    /// Wraps already-serialized inner JSON.
    public init(peer: PeerID, room: RoomID, payload: Data) {
        self.init(peer: peer, room: room, ct: Base64.encodeStandard(payload))
    }

    /// The inner JSON bytes, or `nil` when `ct` is not decodable Base64.
    ///
    /// Accepts either Base64 alphabet on the way in. A Pi emits standard
    /// Base64 (`Buffer.toString("base64")`), but tolerance here costs nothing
    /// and this is precisely the class of mismatch that has bitten before.
    public var payload: Data? {
        Base64.decodeTolerant(ct)
    }

    /// Default relay ceiling on the decoded payload: 4 MiB.
    ///
    /// Server-side default of `RELAY_MAX_CT_MIB`. It was 1 MiB historically,
    /// which silently dropped any image over ~768 KB and left the app stuck on
    /// "sending…" forever — a self-hosted relay may still be configured low,
    /// so treat a send that produces no echo and no
    /// ``ControlFrame/transportError`` as possibly-too-large.
    public static let maxDecodedPayloadBytes = 4 * 1024 * 1024

    /// The size the **relay** will attribute to this envelope.
    ///
    /// Deliberately reproduces the relay's own arithmetic
    /// (`ct.len() * 3 / 4`, integer division, on the Base64 *string*) rather
    /// than measuring the real decoded bytes, so a local pre-flight check and
    /// the server's check agree exactly at the boundary.
    public var relayEstimatedPayloadBytes: Int {
        ct.utf8.count * 3 / 4
    }

    /// `true` when the relay would reject this envelope as too large.
    public func exceedsRelayLimit(_ limit: Int = Envelope.maxDecodedPayloadBytes) -> Bool {
        relayEstimatedPayloadBytes > limit
    }

    private enum CodingKeys: String, CodingKey {
        case peer, room, ct
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        peer = try container.decode(PeerID.self, forKey: .peer)
        // Absent `room` means `main` — the relay's own default for legacy
        // frames (`default_room()` in `relay/src/protocol/outer.rs`).
        room = try container.decodeIfPresent(RoomID.self, forKey: .room) ?? .main
        ct = try container.decode(String.self, forKey: .ct)
    }
}
