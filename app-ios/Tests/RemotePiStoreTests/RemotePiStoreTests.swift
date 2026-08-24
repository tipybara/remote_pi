import Foundation
import XCTest

@testable import RemotePiProtocol
@testable import RemotePiStore

/// The seam-level invariant, kept where the scaffold put it. The rest of the
/// suite lives in `StoreKeyingTests` (the `(epk, session_id)` scope and the
/// control room), `HiveRecordCompatTests` (the persisted record shapes),
/// `RoomCataloguePersistenceTests` (the relay's `RoomMeta` and the `name_rev`
/// gate — including "a rename touches no transcript") and
/// `StoreBehaviourTests` (the write model).
final class RemotePiStoreTests: XCTestCase {
    func testStorageKeyPairsMachineAndRoom() throws {
        let a = try XCTUnwrap(PeerID(rawValue: Data(repeating: 0x01, count: 32)))
        let b = try XCTUnwrap(PeerID(rawValue: Data(repeating: 0x02, count: 32)))
        let room = RoomID("019ffb64")
        XCTAssertNotEqual(
            SessionKey(peer: a, room: room).storageKey,
            SessionKey(peer: b, room: room).storageKey
        )
    }
}
