import Foundation
import RemotePiCrypto
import RemotePiProtocol

// RemotePiPairing — how a phone comes to be trusted by a Mac, and stays
// trusted.
//
// The parts, in the order they run:
//
//   PairingQRPayload            parses `remotepi://pair?…` (scan or paste)
//   PairingCoordinator          pair_request → pair_ok, over the relay socket
//   PeerDirectory               the paired machines, with the republish rule
//   OwnerIdentity/…Bridge       the Owner key, its iCloud slot, the boot gate
//   MeshClient/MeshPublisher    the signed membership blob the Pis poll
//
// Two facts drive most of the design here and are easy to lose:
//
//  1. **Authority is the membership blob, not the pairing.** A Mac that stops
//     finding its own key in a freshly signed `mesh_versions` detaches the
//     Owner and drops its control-room allow-list on its next 60 s poll. So
//     pairing owes a publish, an Owner-key change owes a wipe, and publishing
//     `members: []` by accident revokes every machine the user owns.
//
//  2. **One long-lived Owner key does everything.** It authenticates the
//     WebSocket, it identifies the phone to the Pi (via the relay's `peer`
//     rewrite), and it signs the blob. There is no ephemeral pairing key in
//     this fork, however many docs still describe one.

/// Path component for the mesh endpoints: lowercase hex SHA-256 of the **32
/// raw Owner-key bytes**, not of their Base64 text.
///
/// Hashing the Base64 string produces a 64-hex value that looks perfectly
/// valid, and yields `403 owner_pk_hash mismatch` on POST and `404` on GET
/// forever — the relay re-derives the hash from the key it verified and
/// compares (`handler.rs:74-78`).
public func meshPathHash(for owner: PeerID) -> String {
    RemotePiCrypto.sha256Hex(owner.rawValue)
}

/// Marker thrown by a scaffolded body. See `RemotePiCrypto.ScaffoldError`.
public typealias ScaffoldError = RemotePiCrypto.ScaffoldError
