import Foundation
import RemotePiProtocol

/// What changed about the set of paired machines.
public enum PeerMutation: Hashable, Sendable {
    case saved(PeerRecord)
    case deleted(PeerID)
}

/// The paired-machine list, with the republish rule attached.
///
/// Membership is not durable until the phone republishes the signed blob —
/// a machine that does not see its own key in a fresh `mesh_versions`
/// **self-revokes** on its next 60 s poll. So every mutation has to be able to
/// trigger a publish, and a few very specific ones must *not*.
///
/// ## Why the `…Silent` variants exist (trap T7)
///
/// Applying a blob fetched from the relay writes peers too. If those writes
/// fired the publish hook you would get `pull → apply → save → publish → …`
/// forever, and worse: a publish that observes the **intermediate** storage
/// state — possibly empty — ships `members: []` and revokes every machine the
/// user owns. That is a bug that reached the field. The apply path therefore
/// uses the silent writes, and this is modelled as an explicit scope rather
/// than as a debounce, because a debounce would only make the race rarer.
public actor PeerDirectory: PairingWipe {
    private let store: any SessionStore
    private var hook: (@Sendable (PeerMutation) async -> Void)?

    public init(store: any SessionStore) {
        self.store = store
    }

    /// Installs the republish hook. Fire-and-forget by contract: a publish
    /// failure is retry-later, never a failed save.
    public func setMutationHook(_ hook: (@Sendable (PeerMutation) async -> Void)?) {
        self.hook = hook
    }

    public func peers() async throws -> [PeerRecord] {
        try await store.loadPeers()
    }

    public func peer(_ id: PeerID) async throws -> PeerRecord? {
        try await store.loadPeers().first { $0.peer == id }
    }

    /// Saves and republishes.
    public func save(_ record: PeerRecord) async throws {
        try await store.savePeer(record)
        await hook?(.saved(record))
    }

    /// Saves without republishing — the apply-a-fetched-blob path.
    public func saveSilent(_ record: PeerRecord) async throws {
        try await store.savePeer(record)
    }

    /// Deletes and republishes.
    ///
    /// Revoking the **last** peer must not come through here: the hook's
    /// default publish would be refused by the empty-membership safety net,
    /// leaving the relay holding a blob that still lists the revoked machine —
    /// and the next pull would resurrect it locally. Use ``deleteSilent(_:)``
    /// and then publish with `allowEmpty` computed from what actually remains
    /// (`settings_viewmodel.dart:95-112`).
    public func delete(_ id: PeerID) async throws {
        try await store.deletePeer(id)
        // The room cache is per-machine and meaningless without the pairing.
        try await store.saveRooms([], for: id)
        await hook?(.deleted(id))
    }

    public func deleteSilent(_ id: PeerID) async throws {
        try await store.deletePeer(id)
        try await store.saveRooms([], for: id)
    }

    public func saveRooms(_ rooms: [RoomMeta], for peer: PeerID) async throws {
        try await store.saveRooms(rooms, for: peer)
    }

    public func rooms(for peer: PeerID) async throws -> [RoomMeta] {
        try await store.loadRooms(for: peer)
    }

    /// Merges one room into the machine's cache, keyed by ``RoomID``.
    ///
    /// Used to seed the cache from `pair_ok`, which is the only frame that
    /// carries the session identity before the first `room_announced`.
    public func upsertRoom(_ room: RoomMeta, for peer: PeerID) async throws {
        var rooms = try await store.loadRooms(for: peer)
        if let index = rooms.firstIndex(where: { $0.roomID == room.roomID }) {
            rooms[index] = room
        } else {
            rooms.append(room)
        }
        try await store.saveRooms(rooms, for: peer)
    }

    // MARK: - PairingWipe

    /// Drops every pairing and every cached room. Silent by construction: an
    /// Owner swap must not publish anything under either key.
    public func wipeAllPairings() async {
        guard let existing = try? await store.loadPeers() else { return }
        for record in existing {
            try? await store.deletePeer(record.peer)
            try? await store.saveRooms([], for: record.peer)
        }
    }
}
