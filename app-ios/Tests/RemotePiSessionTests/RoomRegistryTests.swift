import Foundation
import XCTest

@testable import RemotePiProtocol
@testable import RemotePiSession

/// Every payload here is copied from a spec or from the reference
/// implementations' own tests, not invented — the point of this target is byte
/// compatibility with a relay we cannot change.
///
/// Note the shape of the assertions: every `await` is hoisted into a local
/// before the `XCTAssert…`. The assertion helpers take a non-async autoclosure,
/// so an inline `await` does not compile.
final class RoomRegistryTests: XCTestCase {
    private let sessionRoom = RoomID("019ffb64-1c3e-7a91-b0d2-6f2a1c9e77aa")

    private func key(_ room: RoomID, _ peer: PeerID = machineKey) -> SessionKey {
        SessionKey(peer: peer, room: room)
    }

    /// Announce helper — always through the JSON text, never by building a
    /// `RoomMeta` directly, so the decoder stays under test.
    @discardableResult
    private func announce(
        _ registry: RoomRegistry,
        peer: PeerID = machineKey,
        _ fields: String
    ) async throws -> Bool {
        let frame = try controlFrame(
            """
            { "type": "room_announced", "peer": "\(peer.wireValue)", \(fields) }
            """
        )
        return await registry.apply(frame)
    }

    // MARK: - room_announced

    /// Pinned against spec 02 §3.5 — the exact frame `relay/src/peers/registry.rs`
    /// builds, with `RoomMeta` flattened to the top level and `type` + `peer`
    /// injected. There is no `meta` sub-object on this frame.
    func testRoomAnnouncedFlatFrame() async throws {
        let frame = try controlFrame(
            """
            { "type": "room_announced",
              "peer": "\(machineKey.wireValue)",
              "room_id": "019ffb64-1c3e-7a91-b0d2-6f2a1c9e77aa",
              "session_id": "019ffb64-1c3e-7a91-b0d2-6f2a1c9e77aa",
              "workspace_path": "/Users/x/proj",
              "name": "backend",
              "name_rev": 1780000000000,
              "cwd": "/Users/x/proj",
              "model": "claude-sonnet-4.5",
              "thinking": "high",
              "working": false,
              "started_at": 1780000000456 }
            """
        )

        let registry = RoomRegistry()
        let changed = await registry.apply(frame)
        XCTAssertTrue(changed)

        let rooms = await registry.rooms(for: machineKey)
        XCTAssertEqual(rooms.count, 1)
        let room = try XCTUnwrap(rooms.first)
        XCTAssertEqual(room.roomID, sessionRoom)
        XCTAssertEqual(room.sessionID, SessionID("019ffb64-1c3e-7a91-b0d2-6f2a1c9e77aa"))
        XCTAssertEqual(room.workspacePath, "/Users/x/proj")
        XCTAssertEqual(room.name, "backend")
        XCTAssertEqual(room.nameRev, 1_780_000_000_000)
        XCTAssertEqual(room.model, "claude-sonnet-4.5")
        XCTAssertEqual(room.thinking, "high")
        XCTAssertFalse(room.working)
        XCTAssertEqual(room.startedAt, 1_780_000_000_456)
        // The presence of `session_id`, not its value, is what says this room
        // survives a rename.
        XCTAssertTrue(room.hasStableIdentity)

        let live = await registry.isLive(key(sessionRoom))
        XCTAssertTrue(live)
    }

    /// A re-announce is a re-registration, not a rename or a reset. The relay
    /// re-stamps `started_at` every time, and a build that omits a nullable
    /// field means "null" — which the consumer contract reads as *preserve*.
    func testReAnnouncePreservesFieldsTheFrameOmits() async throws {
        let registry = RoomRegistry()
        try await announce(
            registry,
            """
            "room_id": "r1", "session_id": "r1",
            "workspace_path": "/w/api", "cwd": "/w/api",
            "model": "claude-sonnet-4.5", "thinking": "high",
            "name": "api", "name_rev": 100,
            "working": false, "started_at": 1
            """
        )
        // Reconnect: a leaner announce that has not re-reported the model or
        // the session id.
        try await announce(registry, "\"room_id\": \"r1\", \"working\": true, \"started_at\": 999")

        let room = try unwrap(await registry.room(key(RoomID("r1"))))
        XCTAssertEqual(
            room.sessionID,
            SessionID("r1"),
            "dropping session_id makes a live session look legacy"
        )
        XCTAssertEqual(room.workspacePath, "/w/api", "and loses its workspace row")
        XCTAssertEqual(room.model, "claude-sonnet-4.5")
        XCTAssertEqual(room.thinking, "high")
        XCTAssertEqual(room.name, "api")
        XCTAssertEqual(room.nameRev, 100)
        // `working` is always serialized by the relay, so it is authoritative.
        XCTAssertTrue(room.working)
        // `started_at` is taken verbatim — and used for nothing.
        XCTAssertEqual(room.startedAt, 999)
    }

    /// The relay re-broadcasts announcements aggressively. A no-op push must
    /// not churn the UI.
    func testDuplicateAnnounceReportsNoChange() async throws {
        let registry = RoomRegistry()
        let first = try await announce(
            registry,
            "\"room_id\": \"r1\", \"working\": false, \"started_at\": 1"
        )
        let second = try await announce(
            registry,
            "\"room_id\": \"r1\", \"working\": false, \"started_at\": 1"
        )
        XCTAssertTrue(first)
        XCTAssertFalse(second)
    }

    // MARK: - ctrl

    /// Pinned against spec 09 §2 — what the supervisor gateway's room looks
    /// like on the wire. Note the absences: no `session_id`, no `name_rev`, no
    /// `model`, no `thinking`.
    func testControlRoomIsNeverAChatRoom() async throws {
        let registry = RoomRegistry()
        try await announce(
            registry,
            """
            "room_id": "ctrl",
            "role": "control",
            "name": "machine control",
            "cwd": "/Users/x",
            "workspace_path": "/Users/x",
            "working": false,
            "started_at": 1780000000000
            """
        )

        let chatRooms = await registry.rooms(for: machineKey)
        XCTAssertTrue(chatRooms.isEmpty, "ctrl must never become a tile")
        let allRooms = await registry.allRooms(for: machineKey)
        XCTAssertEqual(allRooms.count, 1, "but it is still cached — its liveness gates New Session")

        let gatewayUp = await registry.controlPlaneIsUp(machineKey)
        XCTAssertTrue(gatewayUp)

        let snapshot = await registry.snapshot()
        XCTAssertTrue(snapshot.chatRooms(for: machineKey).isEmpty)
        XCTAssertTrue(snapshot.controlPlaneIsUp(machineKey))
        XCTAssertTrue(SessionCatalog.sessions(for: machineKey, snapshot: snapshot).isEmpty)
    }

    /// Belt and braces: a relay that forwards the Pi's `room_meta` verbatim
    /// nests `role` under `meta`, which is why the Flutter parser reads both
    /// positions. And a room id of `ctrl` is disqualifying on its own.
    func testControlRoomDetectedFromNestedRoleAndFromRoomID() async throws {
        let registry = RoomRegistry()
        try await announce(
            registry,
            """
            "room_id": "ctrl", "started_at": 1, "working": false,
            "meta": { "role": "control", "name": "machine control" }
            """
        )
        let room = try unwrap(await registry.room(key(.control)))
        XCTAssertEqual(room.role, "control")
        XCTAssertTrue(room.isControlRoom)
        let chatRooms = await registry.rooms(for: machineKey)
        XCTAssertTrue(chatRooms.isEmpty)
    }

    // MARK: - room_ended

    /// Pinned against spec 02 §3.6. Post-plan-61 a rename never emits this, so
    /// it genuinely means "process gone" — but the row survives, greyed, with
    /// its history readable.
    func testRoomEndedClearsLivenessButKeepsTheRoom() async throws {
        let registry = RoomRegistry()
        try await announce(
            registry,
            """
            "room_id": "019ffb64-1c3e-7a91-b0d2-6f2a1c9e77aa",
            "name": "backend", "working": false, "started_at": 1
            """
        )
        let changed = await registry.apply(
            try controlFrame(
                """
                { "type": "room_ended", "peer": "\(machineKey.wireValue)",
                  "room_id": "019ffb64-1c3e-7a91-b0d2-6f2a1c9e77aa",
                  "since_ts": 1780000000999 }
                """
            )
        )
        XCTAssertTrue(changed)

        let live = await registry.isLive(key(sessionRoom))
        XCTAssertFalse(live)
        let rooms = await registry.rooms(for: machineKey)
        XCTAssertEqual(rooms.count, 1, "the tile must survive")
        XCTAssertEqual(rooms.first?.name, "backend")
    }

    // MARK: - rooms snapshot

    /// `rooms` is the authoritative live set for that peer: a room absent from
    /// the array has no live connection. It is *not* authoritative for the
    /// catalogue — the row stays so its history is still reachable.
    func testRoomsSnapshotIsAuthoritativeForLivenessOnly() async throws {
        let registry = RoomRegistry()
        for id in ["r1", "r2"] {
            try await announce(
                registry,
                "\"room_id\": \"\(id)\", \"working\": false, \"started_at\": 1"
            )
        }

        _ = await registry.apply(
            try controlFrame(
                """
                { "type": "rooms", "peer": "\(machineKey.wireValue)",
                  "rooms": [ { "room_id": "r1", "name": "one", "cwd": "/one",
                               "working": true, "started_at": 1000 } ] }
                """
            )
        )

        let r1Live = await registry.isLive(key(RoomID("r1")))
        let r2Live = await registry.isLive(key(RoomID("r2")))
        XCTAssertTrue(r1Live)
        XCTAssertFalse(r2Live)
        let rooms = await registry.rooms(for: machineKey)
        XCTAssertEqual(rooms.count, 2)
        let r1 = try unwrap(await registry.room(key(RoomID("r1"))))
        XCTAssertTrue(r1.working)
    }

    /// An unknown peer answers `"rooms": []`. That means "all rooms dead", not
    /// "no information" — so the empty array must still overwrite the live set.
    func testEmptyRoomsSnapshotKillsEverything() async throws {
        let registry = RoomRegistry()
        try await announce(registry, "\"room_id\": \"r1\", \"working\": false, \"started_at\": 1")
        _ = await registry.apply(
            try controlFrame(
                """
                { "type": "rooms", "peer": "\(machineKey.wireValue)", "rooms": [] }
                """
            )
        )
        let live = await registry.isLive(key(RoomID("r1")))
        XCTAssertFalse(live)
        let rooms = await registry.rooms(for: machineKey)
        XCTAssertEqual(rooms.count, 1)
    }

    // MARK: - room_meta_updated

    /// Pinned against spec 02 §3.7 — the relay's post-patch snapshot of the
    /// five mutable fields.
    func testRoomMetaUpdatedAppliesTheFiveMutableFields() async throws {
        let registry = RoomRegistry()
        try await announce(
            registry,
            "\"room_id\": \"r1\", \"cwd\": \"/w\", \"working\": false, \"started_at\": 1"
        )
        let changed = await registry.apply(
            try controlFrame(
                """
                { "type": "room_meta_updated", "peer": "\(machineKey.wireValue)",
                  "room_id": "r1",
                  "meta": { "model": "claude-sonnet-4.5", "thinking": "high",
                            "working": true, "name": "backend",
                            "name_rev": 1780000000001 } }
                """
            )
        )
        XCTAssertTrue(changed)

        let room = try unwrap(await registry.room(key(RoomID("r1"))))
        XCTAssertEqual(room.model, "claude-sonnet-4.5")
        XCTAssertEqual(room.thinking, "high")
        XCTAssertTrue(room.working)
        XCTAssertEqual(room.name, "backend")
        XCTAssertEqual(room.nameRev, 1_780_000_000_001)
        // A metadata patch never re-keys the room and never touches a field the
        // frame cannot carry.
        XCTAssertEqual(room.cwd, "/w")
        let rooms = await registry.rooms(for: machineKey)
        XCTAssertEqual(rooms.count, 1)
    }

    /// T5 — a `working`-only ping is most of the traffic on this frame. Reading
    /// its absent keys as "clear" would wipe the model badge twice per turn.
    func testWorkingOnlyUpdatePreservesModelAndThinkingAndName() async throws {
        let registry = RoomRegistry()
        try await announce(
            registry,
            """
            "room_id": "r1", "model": "claude-sonnet-4.5", "thinking": "high",
            "name": "backend", "name_rev": 10, "working": false, "started_at": 1
            """
        )
        _ = await registry.apply(
            try controlFrame(
                """
                { "type": "room_meta_updated", "peer": "\(machineKey.wireValue)",
                  "room_id": "r1", "meta": { "working": true } }
                """
            )
        )

        let room = try unwrap(await registry.room(key(RoomID("r1"))))
        XCTAssertTrue(room.working)
        XCTAssertEqual(room.model, "claude-sonnet-4.5")
        XCTAssertEqual(room.thinking, "high")
        XCTAssertEqual(room.name, "backend")
    }

    /// Explicit `null` is the one thing that *does* clear — the distinction
    /// `decodeIfPresent` cannot express (spec 02 T6).
    func testExplicitNullClearsWhereAbsenceWouldPreserve() async throws {
        let registry = RoomRegistry()
        try await announce(
            registry,
            """
            "room_id": "r1", "model": "claude-sonnet-4.5", "thinking": "high",
            "working": false, "started_at": 1
            """
        )
        _ = await registry.apply(
            try controlFrame(
                """
                { "type": "room_meta_updated", "peer": "\(machineKey.wireValue)",
                  "room_id": "r1", "meta": { "model": null } }
                """
            )
        )

        let room = try unwrap(await registry.room(key(RoomID("r1"))))
        XCTAssertNil(room.model)
        XCTAssertEqual(room.thinking, "high")
    }

    /// The `name_rev` gate, truth table from spec 02 §4. **Equal is rejected** —
    /// the case a `>=` gets wrong, and how a second Owner device replaying its
    /// last patch drags the label backwards.
    func testNameRevGateRejectsEqualAndOlderRevisions() async throws {
        let registry = RoomRegistry()
        try await announce(
            registry,
            """
            "room_id": "r1", "name": "backend", "name_rev": 100,
            "working": false, "started_at": 1
            """
        )

        func rename(_ name: String, rev: Int64) async throws -> Bool {
            let frame = try controlFrame(
                """
                { "type": "room_meta_updated", "peer": "\(machineKey.wireValue)",
                  "room_id": "r1", "meta": { "name": "\(name)", "name_rev": \(rev) } }
                """
            )
            return await registry.apply(frame)
        }

        let older = try await rename("older", rev: 99)
        XCTAssertFalse(older)
        var room = try unwrap(await registry.room(key(RoomID("r1"))))
        XCTAssertEqual(room.name, "backend")

        // Equal loses. A *rejected* patch still re-broadcasts the winning name,
        // which is the resync mechanism — so this frame arrives in normal
        // operation and must not be mistaken for a rename.
        let equal = try await rename("backend", rev: 100)
        XCTAssertFalse(equal)
        room = try unwrap(await registry.room(key(RoomID("r1"))))
        XCTAssertEqual(room.name, "backend")

        let newer = try await rename("frontend", rev: 101)
        XCTAssertTrue(newer)
        room = try unwrap(await registry.room(key(RoomID("r1"))))
        XCTAssertEqual(room.name, "frontend")
        XCTAssertEqual(room.nameRev, 101)
    }

    /// Either side omitting a revision means "take it on trust" — an older Pi
    /// does not version its labels at all.
    func testNameWithoutRevisionIsTrusted() async throws {
        let registry = RoomRegistry()
        try await announce(
            registry,
            """
            "room_id": "r1", "name": "backend", "name_rev": 100,
            "working": false, "started_at": 1
            """
        )
        let changed = await registry.apply(
            try controlFrame(
                """
                { "type": "room_meta_updated", "peer": "\(machineKey.wireValue)",
                  "room_id": "r1", "meta": { "name": "legacy" } }
                """
            )
        )
        XCTAssertTrue(changed)
        let room = try unwrap(await registry.room(key(RoomID("r1"))))
        XCTAssertEqual(room.name, "legacy")
        // Accepting a rev-less name leaves the stored revision untouched, so an
        // old rev can still lose to it later. Mirrors `registry.rs`.
        XCTAssertEqual(room.nameRev, 100)
    }

    /// A rename keeps the same `SessionKey`: no re-key, no second tile, no lost
    /// transcript. This is the whole of plan 61.
    func testRenameKeepsTheSameSessionKey() async throws {
        let registry = RoomRegistry()
        try await announce(
            registry,
            """
            "room_id": "019ffb64-1c3e-7a91-b0d2-6f2a1c9e77aa",
            "session_id": "019ffb64-1c3e-7a91-b0d2-6f2a1c9e77aa",
            "name": "old", "name_rev": 1, "working": false, "started_at": 1
            """
        )
        _ = await registry.apply(
            try controlFrame(
                """
                { "type": "room_meta_updated", "peer": "\(machineKey.wireValue)",
                  "room_id": "019ffb64-1c3e-7a91-b0d2-6f2a1c9e77aa",
                  "meta": { "name": "new", "name_rev": 2 } }
                """
            )
        )

        let rooms = await registry.rooms(for: machineKey)
        XCTAssertEqual(rooms.count, 1)
        XCTAssertEqual(rooms.first?.roomID, sessionRoom)
        XCTAssertEqual(rooms.first?.name, "new")
        let live = await registry.isLive(key(sessionRoom))
        XCTAssertTrue(live)
    }

    /// A patch for a room we have never seen would create a room with no
    /// session id, no workspace and no role — a phantom that can never become
    /// a session.
    func testPatchForUnknownRoomIsDropped() async throws {
        let registry = RoomRegistry()
        let changed = await registry.apply(
            try controlFrame(
                """
                { "type": "room_meta_updated", "peer": "\(machineKey.wireValue)",
                  "room_id": "ghost", "meta": { "working": true } }
                """
            )
        )
        XCTAssertFalse(changed)
        let rooms = await registry.rooms(for: machineKey)
        XCTAssertTrue(rooms.isEmpty)
    }

    // MARK: - transport_error

    /// Pinned against spec 02 §3.8 and `app/test/data/control/machine_control_test.dart`
    /// ("the relay reporting an undeliverable destination marks that room
    /// offline immediately"). The tile survives as a grey row.
    func testTransportErrorMarksTheRoomDeadButKeepsIt() async throws {
        let registry = RoomRegistry()
        try await announce(
            registry,
            "\"room_id\": \"sess-1\", \"working\": false, \"started_at\": 1"
        )
        let changed = await registry.apply(
            try controlFrame(
                """
                { "type": "transport_error", "reason": "offline",
                  "peer": "\(machineKey.wireValue)", "room_id": "sess-1" }
                """
            )
        )
        XCTAssertTrue(changed)
        let live = await registry.isLive(key(RoomID("sess-1")))
        XCTAssertFalse(live)
        let rooms = await registry.rooms(for: machineKey)
        XCTAssertEqual(rooms.count, 1)
    }

    /// Same Dart test: an error for a room we do not know is harmless.
    func testTransportErrorForUnknownRoomIsHarmless() async throws {
        let registry = RoomRegistry()
        let changed = await registry.apply(
            try controlFrame(
                """
                { "type": "transport_error", "reason": "offline",
                  "peer": "\(machineKey.wireValue)", "room_id": "ghost" }
                """
            )
        )
        XCTAssertFalse(changed)
        let rooms = await registry.rooms(for: machineKey)
        XCTAssertTrue(rooms.isEmpty)
    }

    // MARK: - presence

    /// The `subscribe_presence` backfill re-emits `peer_online` unconditionally
    /// for peers already up, so duplicates are normal traffic.
    func testDuplicatePeerOnlineIsNotAChange() async throws {
        let registry = RoomRegistry()
        let frame = try controlFrame(
            """
            { "type": "peer_online", "peer": "\(machineKey.wireValue)" }
            """
        )
        let first = await registry.apply(frame)
        let second = await registry.apply(frame)
        XCTAssertTrue(first)
        XCTAssertFalse(second)
        let state = await registry.presence(of: machineKey)
        XCTAssertTrue(state.isOnline)
    }

    /// Pinned against spec 02 §3.3: `since_ts` is an always-present key, null
    /// for an online peer, and the array carries one entry per requested peer.
    func testPresenceSnapshot() async throws {
        let registry = RoomRegistry()
        _ = await registry.apply(
            try controlFrame(
                """
                { "type": "presence", "states": [
                    { "peer": "\(machineKey.wireValue)", "online": true, "since_ts": null },
                    { "peer": "\(otherMachineKey.wireValue)", "online": false,
                      "since_ts": 1780000000123 } ] }
                """
            )
        )
        let first = await registry.presence(of: machineKey)
        let second = await registry.presence(of: otherMachineKey)
        XCTAssertEqual(first, .online(sinceTs: nil))
        XCTAssertEqual(second, .offline(sinceTs: 1_780_000_000_123))
    }

    // MARK: - liveness lifecycle

    /// Losing the socket makes the live set stale. Keeping it flashes every
    /// previously-live room green the instant the socket returns, including
    /// rooms whose Pi exited during the outage.
    func testClearLivenessKeepsTheCatalogue() async throws {
        let registry = RoomRegistry()
        try await announce(registry, "\"room_id\": \"r1\", \"working\": false, \"started_at\": 1")
        let cleared = await registry.clearLiveness()
        XCTAssertTrue(cleared)
        let live = await registry.isLive(key(RoomID("r1")))
        XCTAssertFalse(live)
        let rooms = await registry.rooms(for: machineKey)
        XCTAssertEqual(rooms.count, 1)
    }

    /// Rooms restored from disk are catalogue entries, not live ones: nothing
    /// has announced them on this connection.
    func testSeededRoomsAreNotLive() async throws {
        let registry = RoomRegistry()
        await registry.seed([RoomMeta(roomID: RoomID("r1"), name: "cached")], for: machineKey)
        let rooms = await registry.rooms(for: machineKey)
        XCTAssertEqual(rooms.count, 1)
        let live = await registry.isLive(key(RoomID("r1")))
        XCTAssertFalse(live)
    }

    // MARK: - waiting

    func testWaitForRoomResolvesOnAnnounce() async throws {
        let registry = RoomRegistry()
        let target = key(RoomID("new"))
        let waiting = Task { await registry.waitForRoom(target, timeout: .seconds(5)) }
        // Let the waiter install itself before the frame lands.
        try await Task.sleep(for: .milliseconds(20))
        try await announce(registry, "\"room_id\": \"new\", \"working\": false, \"started_at\": 1")
        let result = await waiting.value
        XCTAssertTrue(result)
    }

    func testWaitForRoomTimesOutWithoutAnnounce() async {
        let registry = RoomRegistry()
        let online = await registry.waitForRoom(key(RoomID("never")), timeout: .milliseconds(30))
        XCTAssertFalse(online)
    }

    func testWaitForRoomReturnsImmediatelyWhenAlreadyLive() async throws {
        let registry = RoomRegistry()
        try await announce(registry, "\"room_id\": \"up\", \"working\": false, \"started_at\": 1")
        // Zero budget: only the fast path can satisfy this.
        let online = await registry.waitForRoom(key(RoomID("up")), timeout: .zero)
        XCTAssertTrue(online)
    }

    // MARK: - keying

    /// `room_id` is unique per machine only. Two Macs announcing the same id
    /// must stay two rows.
    func testSameRoomIDOnTwoMachinesDoesNotCollide() async throws {
        let registry = RoomRegistry()
        for peer in [machineKey, otherMachineKey] {
            try await announce(
                registry,
                peer: peer,
                """
                "room_id": "shared", "name": "\(peer.shortDescription)",
                "working": false, "started_at": 1
                """
            )
        }
        let mine = await registry.rooms(for: machineKey)
        let theirs = await registry.rooms(for: otherMachineKey)
        XCTAssertEqual(mine.count, 1)
        XCTAssertEqual(theirs.count, 1)
        XCTAssertNotEqual(mine.first?.name, theirs.first?.name)
    }

    /// The relay canonicalizes every peer id to standard Base64 with padding,
    /// but a key that entered from a QR code is url-safe and unpadded. Both
    /// spellings must land on one row — the recurring bug documented in
    /// `app/lib/data/transport/epk_encoding.dart`.
    func testURLSafeAndStandardSpellingsAreTheSamePeer() async throws {
        let registry = RoomRegistry()
        try await announce(registry, "\"room_id\": \"r1\", \"working\": false, \"started_at\": 1")
        let fromQR = try XCTUnwrap(PeerID(base64: machineKey.urlSafeValue))
        XCTAssertEqual(fromQR, machineKey)
        let rooms = await registry.rooms(for: fromQR)
        XCTAssertEqual(rooms.count, 1)
    }
}
