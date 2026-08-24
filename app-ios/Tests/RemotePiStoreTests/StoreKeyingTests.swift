import Foundation
import XCTest

@testable import RemotePiProtocol
@testable import RemotePiStore

/// The one rule: everything session-scoped is keyed by `(epk, session_id)`.
final class StoreKeyingTests: XCTestCase {

    /// The exact fixture pair from `app/test/data/local/boxes_test.dart` —
    /// "same 32 bytes in the two encodings the app juggles".
    static let urlSafeEPK = "v_7-_f78-_r5-Pf29fTz8vHw7-7t7Ovq6ejn5uXk4-I"
    static let standardEPK = "v/7+/f78+/r5+Pf29fTz8vHw7+7t7Ovq6ejn5uXk4+I="

    private var root: URL!
    private var store: SQLiteSessionStore!

    override func setUp() async throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rp-store-\(UUID().uuidString)", isDirectory: true)
        store = try SQLiteSessionStore(root: root)
    }

    override func tearDown() async throws {
        store = nil
        try? FileManager.default.removeItem(at: root)
    }

    func testFixtureSanityTheEncodingsReallyDiffer() throws {
        XCTAssertNotEqual(Self.urlSafeEPK, Self.standardEPK)
        let a = try XCTUnwrap(PeerID(base64: Self.urlSafeEPK))
        let b = try XCTUnwrap(PeerID(base64: Self.standardEPK))
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.wireValue, Self.standardEPK)
        XCTAssertEqual(a.urlSafeValue, Self.urlSafeEPK)
    }

    /// Trap T2 — the bug plan 61 Fase 0 fixed: "the raw `<epk>:<roomId>` form
    /// let the SAME session own two index rows — one per encoding". Storing the
    /// key as 32 raw bytes makes that unrepresentable.
    func testBothEpkSpellingsAddressOneSession() async throws {
        let urlSafe = try XCTUnwrap(PeerID(base64: Self.urlSafeEPK))
        let standard = try XCTUnwrap(PeerID(base64: Self.standardEPK))
        let room = RoomID("019ffb64-3c11-7a2e-9f00-6d2a1b3c4d5e")

        _ = try await store.appendPendingUserMessage(
            id: "cli_1", text: "hello", ts: 1_780_000_000_000,
            for: SessionKey(peer: urlSafe, room: room)
        )
        _ = try await store.appendPendingUserMessage(
            id: "cli_2", text: "again", ts: 1_780_000_000_001,
            for: SessionKey(peer: standard, room: room)
        )

        let summaries = try await store.summaries()
        XCTAssertEqual(summaries.count, 1, "one session, not one per epk spelling")
        let rows = try await store.rows(for: SessionKey(peer: urlSafe, room: room))
        XCTAssertEqual(rows.map(\.msgID), ["cli_1", "cli_2"])
    }

    /// Two machines may legitimately announce the same room id
    /// (`rooms.ts:92-120`). Their transcripts must not merge.
    func testTwoMachinesSharingARoomIdStaySeparate() async throws {
        let a = try XCTUnwrap(PeerID(rawValue: Data(repeating: 0x01, count: 32)))
        let b = try XCTUnwrap(PeerID(rawValue: Data(repeating: 0x02, count: 32)))
        let room = RoomID("019ffb64")

        XCTAssertNotEqual(
            SessionKey(peer: a, room: room).storageKey,
            SessionKey(peer: b, room: room).storageKey
        )
        _ = try await store.appendPendingUserMessage(id: "m1", text: "on A", ts: 1, for: SessionKey(peer: a, room: room))
        _ = try await store.appendPendingUserMessage(id: "m1", text: "on B", ts: 2, for: SessionKey(peer: b, room: room))

        let onA = try await store.rows(for: SessionKey(peer: a, room: room))
        let onB = try await store.rows(for: SessionKey(peer: b, room: room))
        XCTAssertEqual(onA.map(\.text), ["on A"])
        XCTAssertEqual(onB.map(\.text), ["on B"])
    }

    /// Trap T7 — Hive lowercases box names, so `msgs_<epk>__<roomid>` is
    /// case-folded on disk. base64url and UUIDs are case-sensitive alphabets; a
    /// native store must not fold.
    func testRoomIdsAreCaseSensitive() async throws {
        let peer = try XCTUnwrap(PeerID(base64: Self.urlSafeEPK))
        let lower = SessionKey(peer: peer, room: RoomID("019ffb64-abc"))
        let upper = SessionKey(peer: peer, room: RoomID("019FFB64-ABC"))

        _ = try await store.appendPendingUserMessage(id: "x", text: "lower", ts: 1, for: lower)
        _ = try await store.appendPendingUserMessage(id: "x", text: "UPPER", ts: 2, for: upper)

        let texts = try await store.rows(for: lower).map(\.text)
        XCTAssertEqual(texts, ["lower"])
        let texts2 = try await store.rows(for: upper).map(\.text)
        XCTAssertEqual(texts2, ["UPPER"])
    }

    /// Trap T3 — the storage key uses the url-safe spelling because the
    /// standard alphabet contains `/`, and the `|`-separated standard-base64
    /// form (`home_state.dart:88`) is a widget key that must never reach disk.
    func testStorageKeyIsFilesystemSafe() throws {
        let peer = try XCTUnwrap(PeerID(base64: Self.standardEPK))
        let key = SessionKey(peer: peer, room: RoomID("main")).storageKey
        XCTAssertFalse(key.contains("/"))
        XCTAssertFalse(key.contains("+"))
        XCTAssertFalse(key.contains("="))
        XCTAssertFalse(key.contains("|"))
        XCTAssertTrue(key.hasPrefix(Self.urlSafeEPK))
    }

    /// Trap T10 — `ctrl` is a valid `(epk, room)` pair and would happily key a
    /// transcript. It carries `action_ok`/`action_error` RPC only.
    func testControlRoomRefusesATranscript() async throws {
        let peer = try XCTUnwrap(PeerID(base64: Self.urlSafeEPK))
        let ctrl = SessionKey(peer: peer, room: .control)
        do {
            _ = try await store.appendPendingUserMessage(id: "x", text: "hi", ts: 1, for: ctrl)
            XCTFail("the control room must never get a message store")
        } catch let error as StoreError {
            XCTAssertEqual(error, StoreError.controlRoom(ctrl))
        }
    }

    /// …and so does a room the machine tagged `role: "control"`, whatever its id.
    func testRoomTaggedControlRefusesATranscript() async throws {
        let peer = try XCTUnwrap(PeerID(base64: Self.urlSafeEPK))
        let odd = RoomID("019ffb64-3c11-7a2e-9f00-6d2a1b3c4d5e")
        try await store.saveRooms(
            [RoomMeta(roomID: odd, role: RoomRole.control.rawValue)],
            for: peer
        )
        do {
            _ = try await store.appendPendingUserMessage(
                id: "x", text: "hi", ts: 1, for: SessionKey(peer: peer, room: odd)
            )
            XCTFail("a role=control room must never get a message store")
        } catch is StoreError {
            // expected
        }
    }
}
