import Foundation
import XCTest

@testable import RemotePiPairing
@testable import RemotePiProtocol

/// The republish rule, and the two places it must not fire.
final class PeerDirectoryTests: XCTestCase {
    private func record(_ peer: PeerID) -> PeerRecord {
        PeerRecord(peer: peer, relayURL: "https://r", pairedAt: "2026-05-22T10:30:00.000Z")
    }

    func testSaveAndDeleteFireTheHook() async throws {
        let directory = PeerDirectory(store: InMemorySessionStore())
        let seen = Recorder()
        await directory.setMutationHook { mutation in await seen.append(mutation) }

        try await directory.save(record(Fixture.key(2)))
        try await directory.delete(Fixture.key(2))

        let mutations = await seen.mutations
        XCTAssertEqual(mutations.count, 2)
    }

    /// Trap T7. Applying a blob fetched from the relay writes peers too. If
    /// those writes fired the hook you get `pull → apply → publish → …`
    /// forever — and worse, a publish that observes the half-applied storage
    /// state ships `members: []` and revokes every machine the user owns.
    func testSilentVariantsDoNotFireTheHook() async throws {
        let directory = PeerDirectory(store: InMemorySessionStore())
        let seen = Recorder()
        await directory.setMutationHook { mutation in await seen.append(mutation) }

        try await directory.saveSilent(record(Fixture.key(2)))
        try await directory.deleteSilent(Fixture.key(2))

        let mutations = await seen.mutations
        XCTAssertTrue(mutations.isEmpty)
    }

    func testDeletingAPeerDropsItsCachedRooms() async throws {
        let store = InMemorySessionStore()
        let directory = PeerDirectory(store: store)
        let peer = Fixture.key(2)
        try await directory.save(record(peer))
        try await directory.upsertRoom(RoomMeta(roomID: RoomID("s-1")), for: peer)
        try await directory.upsertRoom(RoomMeta(roomID: RoomID("s-2")), for: peer)
        // Upsert is keyed by room id — a second announcement of the same room
        // replaces it rather than accumulating duplicates.
        try await directory.upsertRoom(
            RoomMeta(roomID: RoomID("s-1"), name: "renamed"), for: peer)
        var rooms = try await store.loadRooms(for: peer)
        XCTAssertEqual(rooms.count, 2)
        XCTAssertEqual(rooms.first?.name, "renamed")

        try await directory.delete(peer)
        rooms = try await store.loadRooms(for: peer)
        XCTAssertTrue(rooms.isEmpty, "a room cache without its pairing is unreachable state")
    }

    /// The Owner-swap wipe is silent by construction: publishing anything
    /// during it would sign the outgoing Owner's membership with the incoming
    /// Owner's key.
    func testWipeIsSilent() async throws {
        let store = InMemorySessionStore(peers: [record(Fixture.key(2)), record(Fixture.key(3))])
        let directory = PeerDirectory(store: store)
        let seen = Recorder()
        await directory.setMutationHook { mutation in await seen.append(mutation) }

        await directory.wipeAllPairings()

        let peers = try await store.loadPeers()
        XCTAssertTrue(peers.isEmpty)
        let mutations = await seen.mutations
        XCTAssertTrue(mutations.isEmpty)
    }
}

actor Recorder {
    private(set) var mutations: [PeerMutation] = []
    func append(_ mutation: PeerMutation) { mutations.append(mutation) }
}
