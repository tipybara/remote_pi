import Foundation
import RemotePiProtocol
import RemotePiSession
import XCTest
@testable import RemotePi

/// `HomeListBuilder` — ordering, identity, grouping and the one-line subtitle
/// (spec 08 §7.4, §7.5, §7.6).
@MainActor
final class HomeListTests: XCTestCase {
    private func devices(
        peers: [PeerRecord],
        snapshot: RegistrySnapshot
    ) -> [DeviceGroup] {
        SessionCatalog.build(peers: peers, snapshot: snapshot, filter: .all)
    }

    // MARK: Ordering

    /// Ordering must come from immutable values only. `name` is editable and
    /// `started_at` is re-stamped on every reconnect, so neither may move a row.
    func testOrderIgnoresNameAndStartedAt() {
        var snapshot = RegistrySnapshot()
        snapshot.rooms[macA] = [
            meta("aaa", workspace: "/w", name: "zzz last alphabetically", startedAt: 9_000),
            meta("bbb", workspace: "/w", name: "aaa first alphabetically", startedAt: 1),
        ]
        let sections = HomeListBuilder.sections(
            devices: devices(peers: [pairing(macA)], snapshot: snapshot),
            grouping: .workspace,
            isVisible: { _ in true }
        )
        XCTAssertEqual(
            sections.first?.workspaces.first?.rows.map { $0.key.room.rawValue },
            ["aaa", "bbb"],
            "rows must stay in room-id order regardless of name or started_at"
        )
    }

    /// Devices come out in `pairedAt` order, tie-broken by the key — never by
    /// the nickname the user can edit.
    func testDeviceOrderIsPairedAtNotNickname() {
        var snapshot = RegistrySnapshot()
        snapshot.rooms[macA] = [meta("a1", workspace: "/w")]
        snapshot.rooms[macB] = [meta("b1", workspace: "/w")]
        let sections = HomeListBuilder.sections(
            devices: devices(
                peers: [
                    pairing(macB, pairedAt: "2026-02-01T00:00:00Z", nickname: "aaa"),
                    pairing(macA, pairedAt: "2026-01-01T00:00:00Z", nickname: "zzz"),
                ],
                snapshot: snapshot
            ),
            grouping: .workspace,
            isVisible: { _ in true }
        )
        XCTAssertEqual(sections.map(\.title), ["zzz", "aaa"])
    }

    /// Workspaces sort by `path`, not by the folder label the header shows.
    func testWorkspaceOrderIsPath() {
        var snapshot = RegistrySnapshot()
        snapshot.rooms[macA] = [
            meta("r1", workspace: "/z/alpha"),
            meta("r2", workspace: "/a/zulu"),
        ]
        let sections = HomeListBuilder.sections(
            devices: devices(peers: [pairing(macA)], snapshot: snapshot),
            grouping: .workspace,
            isVisible: { _ in true }
        )
        XCTAssertEqual(sections.first?.workspaces.map(\.path), ["/a/zulu", "/z/alpha"])
        XCTAssertEqual(sections.first?.workspaces.map(\.title), ["zulu", "alpha"])
    }

    // MARK: Identity

    func testRowIDIsTheSessionKey() {
        var snapshot = RegistrySnapshot()
        snapshot.rooms[macA] = [meta("room-1", workspace: "/w")]
        let sections = HomeListBuilder.sections(
            devices: devices(peers: [pairing(macA)], snapshot: snapshot),
            grouping: .workspace,
            isVisible: { _ in true }
        )
        let row = sections.first!.workspaces.first!.rows.first!
        XCTAssertEqual(row.id, key(macA, "room-1").storageKey)
        XCTAssertEqual(row.key, key(macA, "room-1"))
    }

    /// A room id is unique per machine only, so two Macs sharing one must not
    /// collide in any id the list builds (spec 08 §2.2).
    func testHeaderAndRowIDsAreMachineScoped() {
        var snapshot = RegistrySnapshot()
        snapshot.rooms[macA] = [meta("same", workspace: "/w")]
        snapshot.rooms[macB] = [meta("same", workspace: "/w")]
        let sections = HomeListBuilder.sections(
            devices: devices(
                peers: [pairing(macA), pairing(macB, pairedAt: "2026-02-01T00:00:00Z")],
                snapshot: snapshot
            ),
            grouping: .workspace,
            isVisible: { _ in true }
        )
        let rowIDs = sections.flatMap { $0.rows.map(\.id) }
        let workspaceIDs = sections.flatMap { $0.workspaces.map(\.id) }
        XCTAssertEqual(Set(rowIDs).count, 2)
        XCTAssertEqual(Set(workspaceIDs).count, 2)
        XCTAssertEqual(Set(sections.map(\.id)).count, 2)
    }

    // MARK: Filtering and empty groups

    /// An emptied workspace — and a device left with no workspace — must leave
    /// no dangling header (spec 08 §7.5).
    func testFilteringDropsEmptyHeaders() {
        var snapshot = RegistrySnapshot()
        snapshot.rooms[macA] = [meta("live", workspace: "/w1"), meta("dead", workspace: "/w2")]
        snapshot.live[macA] = [RoomID("live")]
        snapshot.rooms[macB] = [meta("b-dead", workspace: "/w3")]

        let all = devices(
            peers: [pairing(macA), pairing(macB, pairedAt: "2026-02-01T00:00:00Z")],
            snapshot: snapshot
        )
        let online = HomeListBuilder.sections(
            devices: all,
            grouping: .workspace,
            isVisible: { snapshot.isLive($0) }
        )
        XCTAssertEqual(online.count, 1, "macB has no live session and must not render a header")
        XCTAssertEqual(online.first?.workspaces.map(\.path), ["/w1"])
    }

    /// The `ctrl` room is a control plane, not a conversation, and must never
    /// become a tile (spec 08 §13.5).
    func testControlRoomNeverBecomesARow() {
        var snapshot = RegistrySnapshot()
        snapshot.rooms[macA] = [
            meta("ctrl", workspace: "/home", name: "machine control", role: "control"),
            meta("chat", workspace: "/w"),
        ]
        let sections = HomeListBuilder.sections(
            devices: devices(peers: [pairing(macA)], snapshot: snapshot),
            grouping: .none,
            isVisible: { _ in true }
        )
        XCTAssertEqual(sections.flatMap { $0.rows.map { $0.key.room.rawValue } }, ["chat"])
    }

    /// Path-less sessions collapse into one "Unknown folder" group rather than
    /// getting a header each (spec 08 §7.5).
    func testPathlessSessionsShareOneGroup() {
        var snapshot = RegistrySnapshot()
        snapshot.rooms[macA] = [meta("r1"), meta("r2")]
        let sections = HomeListBuilder.sections(
            devices: devices(peers: [pairing(macA)], snapshot: snapshot),
            grouping: .workspace,
            isVisible: { _ in true }
        )
        XCTAssertEqual(sections.first?.workspaces.count, 1)
        XCTAssertEqual(sections.first?.workspaces.first?.title, "Unknown folder")
        XCTAssertEqual(sections.first?.workspaces.first?.rows.count, 2)
    }

    // MARK: Context labels

    /// Dropping a header must not drop attribution (spec 08 §7.4).
    func testContextLabelPerGrouping() {
        var snapshot = RegistrySnapshot()
        snapshot.rooms[macA] = [meta("r1", workspace: "/Users/me/proj")]
        let catalog = devices(peers: [pairing(macA, nickname: "Studio")], snapshot: snapshot)

        func label(_ grouping: HomeGrouping) -> String? {
            HomeListBuilder.sections(devices: catalog, grouping: grouping, isVisible: { _ in true })
                .first?.rows.first?.contextLabel
        }

        XCTAssertNil(label(.workspace), "both headers are on screen — nothing to add")
        XCTAssertEqual(label(.device), "proj")
        XCTAssertEqual(label(.none), "Studio / proj")
    }

    /// With no folder to name, `device` grouping adds nothing and `none` falls
    /// back to the machine alone.
    func testContextLabelWithoutAFolder() {
        var snapshot = RegistrySnapshot()
        snapshot.rooms[macA] = [meta("r1")]
        let catalog = devices(peers: [pairing(macA, nickname: "Studio")], snapshot: snapshot)

        XCTAssertNil(
            HomeListBuilder.sections(devices: catalog, grouping: .device, isVisible: { _ in true })
                .first?.rows.first?.contextLabel
        )
        XCTAssertEqual(
            HomeListBuilder.sections(devices: catalog, grouping: .none, isVisible: { _ in true })
                .first?.rows.first?.contextLabel,
            "Studio"
        )
    }

    /// Switching grouping must change only the context label — never the row
    /// set, never the order, never anything the row is keyed by.
    func testGroupingDoesNotChangeRowsOrOrder() {
        var snapshot = RegistrySnapshot()
        snapshot.rooms[macA] = [
            meta("r1", workspace: "/a"),
            meta("r2", workspace: "/b"),
            meta("r3", workspace: "/a"),
        ]
        let catalog = devices(peers: [pairing(macA)], snapshot: snapshot)

        let ids = HomeGrouping.allCases.map { grouping in
            HomeListBuilder.sections(devices: catalog, grouping: grouping, isVisible: { _ in true })
                .flatMap { $0.rows.map(\.id) }
        }
        XCTAssertEqual(ids[0], ids[1])
        XCTAssertEqual(ids[1], ids[2])
        XCTAssertEqual(ids[0].count, 3)
    }

    // MARK: Titles and subtitles

    func testTitlePreference() {
        var snapshot = RegistrySnapshot()
        snapshot.rooms[macA] = [
            meta("r1", workspace: "/Users/me/api", name: "backend"),
            meta("r2", workspace: "/Users/me/web"),
            meta("r3"),
        ]
        let sections = HomeListBuilder.sections(
            devices: devices(
                peers: [pairing(macA, nickname: "Studio")],
                snapshot: snapshot
            ),
            grouping: .workspace,
            isVisible: { _ in true }
        )
        let titles = Dictionary(
            uniqueKeysWithValues: sections.flatMap { $0.rows }.map { ($0.key.room.rawValue, $0.title) }
        )
        XCTAssertEqual(titles["r1"], "backend", "published name wins")
        XCTAssertEqual(titles["r2"], "web", "cwd basename is next")
        XCTAssertEqual(titles["r3"], "Studio", "then the device nickname")
    }

    func testModelSubtitleIsTruncatedAt24() {
        XCTAssertEqual(HomeListBuilder.truncateModel("claude-sonnet-4.5"), "claude-sonnet-4.5")
        let long = "claude-opus-4-1-20250805-thinking"
        let cut = HomeListBuilder.truncateModel(long)
        XCTAssertEqual(cut, "claude-opus-4-1-20250…")
        XCTAssertEqual(cut.count, 22)
    }

    /// Model present → accent model line. Model absent → the "Last paired"
    /// line, so the row keeps a stable height either way.
    func testDetailFallsBackToLastPaired() {
        var snapshot = RegistrySnapshot()
        snapshot.rooms[macA] = [
            meta("r1", workspace: "/w", model: "claude-sonnet-4.5"),
            meta("r2", workspace: "/w"),
        ]
        let now = ISO8601DateFormatter().date(from: "2026-01-01T00:05:00Z")!
        let rows = HomeListBuilder.sections(
            devices: devices(
                peers: [pairing(macA, pairedAt: "2026-01-01T00:00:00Z")],
                snapshot: snapshot
            ),
            grouping: .workspace,
            isVisible: { _ in true },
            now: now
        ).flatMap { $0.rows }

        XCTAssertEqual(rows[0].detail, .model("claude-sonnet-4.5"))
        XCTAssertEqual(rows[1].detail, .lastPaired("Last paired: 5m ago"))
    }

    /// The rename dialog's prefill and placeholder (spec 08 §7.7).
    func testRenameFieldSeeds() {
        var snapshot = RegistrySnapshot()
        snapshot.rooms[macA] = [
            meta("r1", cwd: "/Users/me/api", name: "backend"),
            meta("r2", cwd: "/Users/me/web"),
            meta("r3"),
        ]
        // Keyed by room id, never by position: workspaces sort by path, so
        // the path-less room comes first here — which is exactly why a test
        // must not index into the list either.
        let rows = Dictionary(
            uniqueKeysWithValues: HomeListBuilder.sections(
                devices: devices(peers: [pairing(macA)], snapshot: snapshot),
                grouping: .none,
                isVisible: { _ in true }
            ).flatMap { $0.rows }.map { ($0.key.room.rawValue, $0) }
        )

        XCTAssertEqual(rows["r1"]?.currentName, "backend")
        XCTAssertEqual(rows["r1"]?.hintName, "/Users/me/api")
        XCTAssertNil(rows["r2"]?.currentName)
        XCTAssertEqual(rows["r2"]?.hintName, "/Users/me/web")
        XCTAssertEqual(rows["r3"]?.hintName, "Session")
    }

    // MARK: Workspace header path line

    func testPathLineOnlyWhenItAddsInformation() {
        XCTAssertNil(HomeListBuilder.pathLine(path: "", title: "Unknown folder"))
        XCTAssertNil(HomeListBuilder.pathLine(path: "proj", title: "proj"))
        XCTAssertEqual(
            HomeListBuilder.pathLine(path: "/Users/me/proj", title: "proj"),
            "/Users/me/proj"
        )
        // Long paths are truncated from the FRONT — the tail disambiguates.
        let long = "/Users/someone/with/a/very/long/path/that/keeps/going/api"
        let line = HomeListBuilder.pathLine(path: long, title: "api")!
        XCTAssertTrue(line.hasPrefix("…"))
        XCTAssertTrue(line.hasSuffix("api"))
        XCTAssertEqual(line.count, 42)
    }

    // MARK: Counts

    func testCountsArePerTabAndIndependent() {
        var snapshot = RegistrySnapshot()
        snapshot.rooms[macA] = [
            meta("r1", workspace: "/w"),
            meta("r2", workspace: "/w"),
            meta("r3", workspace: "/w"),
        ]
        snapshot.live[macA] = [RoomID("r1")]
        let counts = HomeListBuilder.counts(
            devices: devices(peers: [pairing(macA)], snapshot: snapshot),
            isLive: { snapshot.isLive($0) }
        )
        XCTAssertEqual(counts.all, 3)
        XCTAssertEqual(counts.online, 1)
        XCTAssertEqual(counts.offline, 2)
        XCTAssertEqual(counts.count(for: .online), 1)
    }
}
