import Foundation
import XCTest

@testable import RemotePiProtocol
@testable import RemotePiStore

/// The session catalogue is the cache of what the relay published. It has to
/// survive a relaunch in the relay's own shape, so Home renders offline.
final class RoomCataloguePersistenceTests: XCTestCase {

    /// One entry of a relay `rooms` snapshot, in the exact shape
    /// `relay/src/rooms.rs` serializes (declaration order; `skip_serializing_if
    /// = "Option::is_none"` on every optional; `working` and `started_at`
    /// always present). Quoted in `RoomMeta`'s own doc comment.
    static let relayRoomJSON = """
        { "room_id": "019ffb64-3c11-7a2e-9f00-6d2a1b3c4d5e",
          "session_id": "019ffb64-3c11-7a2e-9f00-6d2a1b3c4d5e",
          "workspace_path": "/Users/x/proj", "name": "backend",
          "name_rev": 1780000000000, "cwd": "/Users/x/proj",
          "model": "claude-sonnet-4.5", "thinking": "high",
          "working": false, "started_at": 1780000000123 }
        """

    private var root: URL!
    private var store: SQLiteSessionStore!
    private let peer = PeerID(base64: "v_7-_f78-_r5-Pf29fTz8vHw7-7t7Ovq6ejn5uXk4-I")!

    override func setUp() async throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rp-store-\(UUID().uuidString)", isDirectory: true)
        store = try SQLiteSessionStore(root: root)
    }

    override func tearDown() async throws {
        store = nil
        try? FileManager.default.removeItem(at: root)
    }

    /// The single cached session, unwrapped. A helper rather than an inline
    /// `XCTUnwrap(try await …)`, which does not compile: XCTest's autoclosures
    /// are not async.
    private func currentSummary() async throws -> SessionSummary {
        let all = try await store.summaries()
        return try XCTUnwrap(all.first)
    }

    private func decodedRelayRoom() throws -> RoomMeta {
        try JSONDecoder().decode(RoomMeta.self, from: Data(Self.relayRoomJSON.utf8))
    }

    /// Everything durable survives the round trip; `working` and `started_at`
    /// deliberately do **not**.
    func testRelayRoomSurvivesARelaunch() async throws {
        let meta = try decodedRelayRoom()
        try await store.saveRooms([meta], for: peer)

        // A second store over the same directory is what a relaunch looks like.
        let reopened = try SQLiteSessionStore(root: root)
        let cached = try await reopened.loadRooms(for: peer)
        XCTAssertEqual(cached.count, 1)
        let room = try XCTUnwrap(cached.first)

        XCTAssertEqual(room.roomID, meta.roomID)
        XCTAssertEqual(room.sessionID, meta.sessionID)
        XCTAssertEqual(room.workspacePath, "/Users/x/proj")
        XCTAssertEqual(room.cwd, "/Users/x/proj")
        XCTAssertEqual(room.name, "backend")
        XCTAssertEqual(room.nameRev, 1_780_000_000_000)
        XCTAssertEqual(room.model, "claude-sonnet-4.5")
        XCTAssertEqual(room.thinking, "high")
        XCTAssertNil(room.role)

        // `started_at` is the relay registration instant and changes on every
        // reconnect (PROTOCOL.md:221); `working` is live turn state. Persisting
        // either would repaint stale state at launch — the exact reason the
        // Hive `runtime` box was wiped at boot.
        XCTAssertEqual(room.startedAt, 0)
        XCTAssertFalse(room.working)

        // The re-encoded room is byte-comparable with the relay's own shape,
        // modulo those two live fields: no nulls, no invented keys.
        let encoded = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(room)
        ) as? [String: Any]
        var expected = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(Self.relayRoomJSON.utf8)) as? [String: Any]
        )
        expected["started_at"] = 0
        XCTAssertEqual(encoded as NSDictionary?, expected as NSDictionary)
    }

    /// `PROTOCOL.md:215-219` / `relay/src/peers/registry.rs`: a name applies
    /// only when its revision is **strictly greater**. Equal loses.
    func testRenameGateIsStrictlyGreater() async throws {
        let meta = try decodedRelayRoom()
        try await store.saveRooms([meta], for: peer)
        let key = SessionKey(peer: peer, room: meta.roomID)

        var stale = meta
        stale.name = "older label"
        stale.nameRev = 1_779_999_999_999
        try await store.saveRooms([stale], for: peer)
        var summary = try await currentSummary()
        XCTAssertEqual(summary.displayName, "backend", "a lower revision must lose")

        var equal = meta
        equal.name = "same-rev label"
        equal.nameRev = 1_780_000_000_000
        try await store.saveRooms([equal], for: peer)
        summary = try await currentSummary()
        XCTAssertEqual(summary.displayName, "backend", "an EQUAL revision must lose too")

        var newer = meta
        newer.name = "renamed"
        newer.nameRev = 1_780_000_000_001
        try await store.saveRooms([newer], for: peer)
        summary = try await currentSummary()
        XCTAssertEqual(summary.displayName, "renamed")
        XCTAssertEqual(summary.nameRev, 1_780_000_000_001)

        // And the same gate on the patch path, from a `room_meta_updated`
        // `meta` object with absent-vs-null preserved.
        let rejected = RoomMetaPatch(metaJSONObject: [
            "name": "rolled back", "name_rev": NSNumber(value: 1_780_000_000_000),
        ])
        let staleWasApplied = try await store.applyRoomMetaPatch(rejected, for: key)
        XCTAssertFalse(staleWasApplied)
        let displayName = try await store.summaries().first?.displayName
        XCTAssertEqual(displayName, "renamed")

        let accepted = RoomMetaPatch(metaJSONObject: [
            "name": "final", "name_rev": NSNumber(value: 1_780_000_000_002),
        ])
        let newerWasApplied = try await store.applyRoomMetaPatch(accepted, for: key)
        XCTAssertTrue(newerWasApplied)
        let displayName2 = try await store.summaries().first?.displayName
        XCTAssertEqual(displayName2, "final")
    }

    /// Trap T4 / `PROTOCOL.md:212-213`: absent preserves, explicit null clears.
    func testPatchDistinguishesAbsentFromNull() async throws {
        let meta = try decodedRelayRoom()
        try await store.saveRooms([meta], for: peer)
        let key = SessionKey(peer: peer, room: meta.roomID)

        // A model-only update must not erase the thinking level.
        try await store.applyRoomMetaPatch(
            RoomMetaPatch(metaJSONObject: ["model": "claude-opus-4.1"]), for: key
        )
        var summary = try await currentSummary()
        XCTAssertEqual(summary.model, "claude-opus-4.1")
        XCTAssertEqual(summary.thinking, "high", "an absent key preserves")

        // An explicit null clears it.
        try await store.applyRoomMetaPatch(
            RoomMetaPatch(metaJSONObject: ["thinking": NSNull()]), for: key
        )
        summary = try await currentSummary()
        XCTAssertNil(summary.thinking, "an explicit null clears")
        XCTAssertEqual(summary.model, "claude-opus-4.1")
    }

    /// A rename is a metadata patch. `room_id == session_id` from plan 61 on, so
    /// nothing about the transcript may move.
    func testRenameLeavesTheTranscriptUntouched() async throws {
        let meta = try decodedRelayRoom()
        try await store.saveRooms([meta], for: peer)
        let key = SessionKey(peer: peer, room: meta.roomID)
        _ = try await store.appendPendingUserMessage(id: "cli_1", text: "hello", ts: 10, for: key)

        try await store.applyRoomMetaPatch(
            RoomMetaPatch(metaJSONObject: ["name": "brand new", "name_rev": NSNumber(value: 1_780_000_000_009)]),
            for: key
        )

        let rows = try await store.rows(for: key)
        XCTAssertEqual(rows.map(\.msgID), ["cli_1"])
        XCTAssertEqual(rows.map(\.seq), [0], "a rename must not re-key a row")
        let sessionCount = try await store.summaries().count
        XCTAssertEqual(sessionCount, 1, "a rename must not fork the session")
    }

    /// The relay lists only rooms that are currently registered. A sleeping Mac
    /// publishes none, and "not listed" must not mean "delete Home".
    func testRoomsMissingFromASnapshotAreKept() async throws {
        let first = try decodedRelayRoom()
        let second = RoomMeta(roomID: RoomID("019ffb64-aaaa-7a2e-9f00-6d2a1b3c4d5e"), name: "other")
        try await store.saveRooms([first, second], for: peer)
        let sessionCount = try await store.summaries().count
        XCTAssertEqual(sessionCount, 2)

        try await store.saveRooms([first], for: peer)
        let afterPartialSnapshot = try await store.summaries().count
        XCTAssertEqual(
            afterPartialSnapshot, 2,
            "an offline room is absent from `rooms`, not gone"
        )
    }
}
