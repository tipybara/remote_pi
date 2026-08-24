import Foundation
import XCTest

@testable import RemotePiProtocol
@testable import RemotePiSession

/// The Device → Workspace → Session hierarchy (plan 61 Phase 2), and the
/// ordering rules that keep rows from moving under the user's finger.
final class SessionCatalogTests: XCTestCase {
    private func meta(
        _ room: String,
        workspace: String? = nil,
        name: String? = nil,
        startedAt: Int64 = 0
    ) -> RoomMeta {
        RoomMeta(
            roomID: RoomID(room),
            sessionID: SessionID(room),
            workspacePath: workspace,
            name: name,
            working: false,
            startedAt: startedAt
        )
    }

    private func snapshot(
        _ rooms: [PeerID: [RoomMeta]],
        live: [PeerID: Set<RoomID>] = [:]
    ) -> RegistrySnapshot {
        RegistrySnapshot(
            // The registry always hands out rooms sorted by id; mirror that so
            // the catalog is tested on the input it really gets.
            rooms: rooms.mapValues { $0.sorted { $0.roomID.rawValue < $1.roomID.rawValue } },
            live: live
        )
    }

    /// Order comes from immutable values only: devices by `pairedAt`,
    /// workspaces by path, sessions by room id.
    func testGroupingAndOrdering() {
        let rooms: [PeerID: [RoomMeta]] = [
            machineKey: [
                meta("s-b", workspace: "/w/api", name: "zebra"),
                meta("s-a", workspace: "/w/api", name: "alpha"),
                meta("s-c", workspace: "/w/app"),
            ]
        ]
        let devices = SessionCatalog.build(
            peers: [pairing(machineKey, pairedAt: "2026-01-01T00:00:00Z")],
            snapshot: snapshot(rooms)
        )

        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].workspaces.map(\.path), ["/w/api", "/w/app"])
        // Sorted by room id, NOT by the display name — renaming "zebra" to
        // "aaa" must not move the row.
        XCTAssertEqual(devices[0].workspaces[0].sessions.map(\.key.room.rawValue), ["s-a", "s-b"])
        XCTAssertEqual(devices[0].workspaces[0].displayName, "api")
    }

    /// `started_at` is re-stamped by the relay at every registration, so a
    /// flaky network would reorder the list under the user's finger. Sorting by
    /// it is the "as sessões pulam" bug class plan 61 exists to kill.
    func testOrderIgnoresStartedAt() {
        let rooms: [PeerID: [RoomMeta]] = [
            machineKey: [
                meta("s-a", workspace: "/w", startedAt: 9_999_999),
                meta("s-b", workspace: "/w", startedAt: 1),
            ]
        ]
        let devices = SessionCatalog.build(
            peers: [pairing(machineKey, pairedAt: "2026-01-01T00:00:00Z")],
            snapshot: snapshot(rooms)
        )
        XCTAssertEqual(devices[0].sessions.map(\.key.room.rawValue), ["s-a", "s-b"])
    }

    func testDevicesOrderedByPairedAtThenKey() {
        let rooms: [PeerID: [RoomMeta]] = [
            machineKey: [meta("s1", workspace: "/w")],
            otherMachineKey: [meta("s1", workspace: "/w")],
        ]
        let devices = SessionCatalog.build(
            peers: [
                pairing(otherMachineKey, pairedAt: "2026-02-01T00:00:00Z"),
                pairing(machineKey, pairedAt: "2026-01-01T00:00:00Z"),
            ],
            snapshot: snapshot(rooms)
        )
        XCTAssertEqual(devices.map(\.peer), [machineKey, otherMachineKey])
    }

    /// The `ctrl` room is filtered at the one boundary where rooms become
    /// sessions, so no widget downstream has to remember (spec 09 T10).
    func testControlRoomNeverBecomesASession() {
        let ctrl = RoomMeta(
            roomID: .control,
            workspacePath: "/Users/x",
            name: "machine control",
            role: "control",
            cwd: "/Users/x",
            working: false,
            startedAt: 1_780_000_000_000
        )
        let devices = SessionCatalog.build(
            peers: [pairing(machineKey, pairedAt: "2026-01-01T00:00:00Z")],
            snapshot: snapshot(
                [machineKey: [ctrl, meta("s1", workspace: "/w/api")]],
                live: [machineKey: [.control, RoomID("s1")]]
            )
        )
        XCTAssertEqual(devices[0].sessions.map(\.key.room), [RoomID("s1")])
        // …and it must not create a workspace header for the supervisor's cwd.
        XCTAssertEqual(devices[0].workspaces.map(\.path), ["/w/api"])
    }

    /// A device whose only room is `ctrl` has zero sessions, so it must not
    /// leave a bare header behind.
    func testDeviceWithOnlyControlRoomIsDropped() {
        let ctrl = RoomMeta(roomID: .control, role: "control", working: false, startedAt: 1)
        let devices = SessionCatalog.build(
            peers: [pairing(machineKey, pairedAt: "2026-01-01T00:00:00Z")],
            snapshot: snapshot([machineKey: [ctrl]], live: [machineKey: [.control]])
        )
        XCTAssertTrue(devices.isEmpty)
    }

    func testFilterSplitsLiveFromCached() {
        let rooms: [PeerID: [RoomMeta]] = [
            machineKey: [meta("live", workspace: "/w"), meta("dead", workspace: "/w")]
        ]
        let snap = snapshot(rooms, live: [machineKey: [RoomID("live")]])
        let peers = [pairing(machineKey, pairedAt: "2026-01-01T00:00:00Z")]

        let online = SessionCatalog.build(peers: peers, snapshot: snap, filter: .online)
        XCTAssertEqual(online[0].sessions.map(\.key.room.rawValue), ["live"])

        let offline = SessionCatalog.build(peers: peers, snapshot: snap, filter: .offline)
        XCTAssertEqual(offline[0].sessions.map(\.key.room.rawValue), ["dead"])

        let all = SessionCatalog.build(peers: peers, snapshot: snap, filter: .all)
        XCTAssertEqual(all[0].sessions.count, 2)
    }

    /// A workspace left with no visible session must not survive the filter as
    /// an empty header.
    func testEmptyWorkspacesAreDropped() {
        let rooms: [PeerID: [RoomMeta]] = [
            machineKey: [meta("live", workspace: "/w/a"), meta("dead", workspace: "/w/b")]
        ]
        let devices = SessionCatalog.build(
            peers: [pairing(machineKey, pairedAt: "2026-01-01T00:00:00Z")],
            snapshot: snapshot(rooms, live: [machineKey: [RoomID("live")]]),
            filter: .online
        )
        XCTAssertEqual(devices[0].workspaces.map(\.path), ["/w/a"])
    }

    /// A pre-plan-61 Pi publishes only `cwd`; it holds the same canonical path,
    /// so it must group with sessions that publish `workspace_path`.
    func testLegacyRoomGroupsByCwd() {
        let legacy = RoomMeta(roomID: RoomID("old"), cwd: "/w/api", working: false, startedAt: 1)
        let devices = SessionCatalog.build(
            peers: [pairing(machineKey, pairedAt: "2026-01-01T00:00:00Z")],
            snapshot: snapshot([machineKey: [legacy, meta("new", workspace: "/w/api")]])
        )
        XCTAssertEqual(devices[0].workspaces.count, 1)
        XCTAssertEqual(devices[0].workspaces[0].sessions.count, 2)
    }

    /// Sessions with no directory at all collapse into one "unknown" group
    /// rather than inventing a header each.
    func testRoomsWithoutAPathCollapseIntoOneGroup() {
        let devices = SessionCatalog.build(
            peers: [pairing(machineKey, pairedAt: "2026-01-01T00:00:00Z")],
            snapshot: snapshot([machineKey: [meta("a"), meta("b")]])
        )
        XCTAssertEqual(devices[0].workspaces.count, 1)
        XCTAssertEqual(devices[0].workspaces[0].path, "")
        XCTAssertEqual(devices[0].workspaces[0].displayName, "Unknown folder")
    }

    /// Identity is the `SessionKey`, so a row for the same session compares
    /// equal across a `working` flip and a `started_at` re-stamp — but two
    /// machines that happen to announce the same room id stay distinct.
    func testRowIdentityIsTheSessionKey() {
        let base = meta("s1", workspace: "/w", name: "one")
        var churned = base
        churned.working = true
        churned.startedAt = 99

        let key = SessionKey(peer: machineKey, room: RoomID("s1"))
        XCTAssertEqual(
            SessionRow(key: key, meta: base, isLive: true).id,
            SessionRow(key: key, meta: churned, isLive: true).id
        )
        let otherKey = SessionKey(peer: otherMachineKey, room: RoomID("s1"))
        XCTAssertNotEqual(
            SessionRow(key: key, meta: base, isLive: true).id,
            SessionRow(key: otherKey, meta: base, isLive: true).id
        )
    }

    /// Label preference: published name → workspace basename → room id. All
    /// display, never identity.
    func testRowDisplayNameFallbacks() {
        let key = SessionKey(peer: machineKey, room: RoomID("s1"))
        XCTAssertEqual(
            SessionRow(key: key, meta: meta("s1", workspace: "/w/api", name: "backend"), isLive: true)
                .displayName,
            "backend"
        )
        XCTAssertEqual(
            SessionRow(key: key, meta: meta("s1", workspace: "/w/api"), isLive: true).displayName,
            "api"
        )
        XCTAssertEqual(
            SessionRow(key: key, meta: meta("s1"), isLive: true).displayName,
            "s1"
        )
    }
}
