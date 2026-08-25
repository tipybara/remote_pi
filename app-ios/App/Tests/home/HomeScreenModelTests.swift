import Foundation
import RemotePiProtocol
import RemotePiSession
import XCTest
@testable import RemotePi

/// `HomeScreenModel` — phases, relay status, the filter's purity, the presence
/// ladder and the rename/delete flows (spec 08 §7.1–§7.3, §7.6.1, §7.7).
@MainActor
final class HomeScreenModelTests: XCTestCase {
    private func makeModel(
        _ configure: (FakeHomeBackend) -> Void = { _ in }
    ) -> (HomeScreenModel, FakeHomeBackend) {
        let backend = FakeHomeBackend()
        configure(backend)
        let model = HomeScreenModel()
        model.bind(backend: backend, clock: { Date(timeIntervalSince1970: 1_800_000_000) })
        return (model, backend)
    }

    // MARK: Phases

    func testLoadingWhileBooting() {
        let (model, _) = makeModel { $0.isBooting = true }
        XCTAssertEqual(model.content.phase, .loading)
    }

    func testNoPeerPhase() {
        let (model, _) = makeModel()
        XCTAssertEqual(model.content.phase, .noPeer)
    }

    /// Paired but zero announced rooms: the dimmed moon, and the tabs are
    /// hidden — there is nothing to filter (spec 08 §7.1).
    func testLonelyPhaseWhenNoRoomsAtAll() {
        let (model, _) = makeModel { $0.homePeers = [pairing(macA)] }
        XCTAssertEqual(model.content.phase, .lonely)
        XCTAssertEqual(model.content.counts.all, 0)
    }

    /// A peer whose only room is `ctrl` contributes nothing, so Home is lonely
    /// rather than showing a chat that answers nothing (spec 08 §13.5).
    func testControlOnlyMachineIsStillLonely() {
        let (model, _) = makeModel { backend in
            backend.homePeers = [pairing(macA)]
            backend.install([meta("ctrl", role: "control")], on: macA, live: ["ctrl"])
        }
        XCTAssertEqual(model.content.phase, .lonely)
    }

    /// Sessions exist but none match the tab: tabs stay, per-tab copy shows
    /// (spec 08 §7.3).
    func testFilterEmptyPhase() {
        let (model, _) = makeModel { backend in
            backend.homePeers = [pairing(macA)]
            backend.install([meta("r1", workspace: "/w")], on: macA, live: [])
        }
        XCTAssertEqual(model.filter, .online, "spec default is the Online tab")
        XCTAssertEqual(model.content.phase, .filterEmpty(.online))
        XCTAssertEqual(model.content.counts.all, 1)
    }

    func testListPhase() {
        let (model, _) = makeModel { backend in
            backend.homePeers = [pairing(macA)]
            backend.install([meta("r1", workspace: "/w")], on: macA, live: ["r1"])
        }
        XCTAssertEqual(model.content.phase, .list)
        XCTAssertEqual(model.content.sections.flatMap { $0.rows }.count, 1)
    }

    // MARK: Filter purity

    /// Changing the tab must not touch the backend at all — no reload, no
    /// refetch, no regroup (spec 08 §7.3). And the counts stay independent of
    /// the selection.
    func testFilterIsAPureView() {
        let (model, backend) = makeModel { backend in
            backend.homePeers = [pairing(macA)]
            backend.install(
                [meta("r1", workspace: "/w"), meta("r2", workspace: "/w")],
                on: macA,
                live: ["r1"]
            )
        }
        for filter in SessionFilter.ordered {
            model.filter = filter
            let content = model.content
            XCTAssertEqual(content.counts.all, 2)
            XCTAssertEqual(content.counts.online, 1)
            XCTAssertEqual(content.counts.offline, 1)
        }
        XCTAssertEqual(backend.workspaceCalls, 0)
        XCTAssertTrue(backend.opened.isEmpty)

        model.filter = .offline
        XCTAssertEqual(model.content.sections.flatMap { $0.rows.map { $0.key.room.rawValue } }, ["r2"])
    }

    /// The filter is user state and must survive a data re-emit — resetting it
    /// on every reload was the "sessions jumping" bug (spec 08 §12.2).
    func testFilterSurvivesADataReEmit() {
        let (model, backend) = makeModel { backend in
            backend.homePeers = [pairing(macA)]
            backend.install([meta("r1", workspace: "/w")], on: macA, live: ["r1"])
        }
        model.filter = .all
        backend.install(
            [meta("r1", workspace: "/w"), meta("r2", workspace: "/w")],
            on: macA,
            live: ["r1"]
        )
        XCTAssertEqual(model.filter, .all)
        XCTAssertEqual(model.content.sections.flatMap { $0.rows }.count, 2)
    }

    // MARK: Grouping persistence

    func testGroupingSeedsFromPreferencesAndWritesBack() async {
        let (model, backend) = makeModel()
        backend.preferences.homeGrouping = .device
        await model.activate()
        XCTAssertEqual(model.grouping, .device, "read before the first list build")

        model.grouping = .none
        XCTAssertEqual(backend.preferences.homeGrouping, .none)
    }

    // MARK: Relay status (§7.2)

    func testRelayStatus() {
        let (model, backend) = makeModel()
        backend.isRelayConnected = true
        XCTAssertEqual(model.relayStatus, .connected)

        backend.isRelayConnected = false
        XCTAssertEqual(
            model.relayStatus,
            .awaitingPairing,
            "with no peer the socket was never opened — that is not a fault"
        )

        backend.homePeers = [pairing(macA)]
        XCTAssertEqual(model.relayStatus, .offline)
    }

    // MARK: Presence and the socket gate (§7.6.1)

    /// When the socket is down nothing is Online, the counts agree, and every
    /// dot reads amber rather than a stale green.
    func testSocketLossMakesEverythingReconnecting() {
        let (model, backend) = makeModel { backend in
            backend.homePeers = [pairing(macA)]
            backend.install([meta("r1", workspace: "/w")], on: macA, live: ["r1"])
        }
        XCTAssertEqual(model.presence(of: key(macA, "r1")), .live)

        backend.isRelayConnected = false
        XCTAssertEqual(model.presence(of: key(macA, "r1")), .reconnecting)
        XCTAssertFalse(model.isLive(key(macA, "r1")))

        model.filter = .online
        XCTAssertEqual(model.content.counts.online, 0)
        XCTAssertEqual(model.content.counts.offline, 1)
    }

    /// `working` outranks everything, including a down socket.
    func testWorkingOutranksReconnecting() {
        let (model, _) = makeModel { backend in
            backend.homePeers = [pairing(macA)]
            backend.install([meta("r1", workspace: "/w", working: true)], on: macA, live: ["r1"])
        }
        XCTAssertEqual(model.presence(of: key(macA, "r1")), .working)
    }

    // MARK: New session gate (§7.2, §7.9)

    func testCanCreateSessionFollowsReachableMachines() {
        let (model, backend) = makeModel()
        XCTAssertFalse(model.canCreateSession)
        backend.machinesAcceptingSessions = [pairing(macA)]
        XCTAssertTrue(model.canCreateSession)
    }

    // MARK: Opening (§7.8)

    func testOpenResolvesTheRowFromTheUnfilteredCatalog() async {
        let (model, backend) = makeModel { backend in
            backend.homePeers = [pairing(macA)]
            backend.install([meta("r1", workspace: "/w")], on: macA, live: [])
        }
        // The Online tab hides this row, but a caller holding its key must
        // still resolve it — the row lookup is not filtered.
        model.filter = .online
        let row = try? XCTUnwrap(model.row(for: key(macA, "r1")))
        XCTAssertEqual(row?.key, key(macA, "r1"))

        await model.open(row!)
        XCTAssertEqual(backend.opened, [key(macA, "r1")])
    }

    /// There is no `'main'` fallback in this client: a key the relay has not
    /// announced resolves to nothing rather than to an invented room
    /// (spec 08 §13.6).
    func testUnknownKeyResolvesToNothing() {
        let (model, _) = makeModel { backend in
            backend.homePeers = [pairing(macA)]
            backend.install([meta("r1", workspace: "/w")], on: macA)
        }
        XCTAssertNil(model.row(for: key(macA, "main")))
    }

    // MARK: Rename (§7.7)

    func testRenameWritesLocallyThenSendsWhenLive() async {
        let (model, backend) = makeModel { backend in
            backend.homePeers = [pairing(macA)]
            backend.install([meta("r1", workspace: "/w")], on: macA, live: ["r1"])
        }
        await model.rename(key(macA, "r1"), to: "  backend  ")

        XCTAssertEqual(backend.localNames.count, 1)
        XCTAssertEqual(backend.localNames.first?.1, "backend", "trimmed before anything else")
        XCTAssertEqual(backend.renames.first?.1, "backend")
        XCTAssertNil(model.banner, "a successful rename says nothing")
    }

    /// Clearing the label is a local-only affordance — there is no "unset the
    /// name" on the wire, so nothing is sent and nothing is reported.
    func testRenameToEmptyIsLocalOnlyAndSilent() async {
        let (model, backend) = makeModel { backend in
            backend.homePeers = [pairing(macA)]
            backend.install([meta("r1", workspace: "/w")], on: macA, live: ["r1"])
        }
        await model.rename(key(macA, "r1"), to: "   ")

        XCTAssertEqual(backend.localNames.first?.1, nil)
        XCTAssertTrue(backend.renames.isEmpty)
        XCTAssertNil(model.banner)
    }

    func testRenameOfflineReportsLocalOnly() async {
        let (model, backend) = makeModel { backend in
            backend.homePeers = [pairing(macA)]
            backend.install([meta("r1", workspace: "/w")], on: macA, live: [])
        }
        await model.rename(key(macA, "r1"), to: "backend")

        XCTAssertTrue(backend.renames.isEmpty, "an offline session cannot be told")
        XCTAssertEqual(model.banner?.text, "Session is offline — renamed on this device only.")
    }

    /// When even the local write is unavailable the copy must not claim a
    /// rename that did not happen.
    func testRenameOfflineWithoutLocalWriteIsHonest() async {
        let (model, _) = makeModel { backend in
            backend.homePeers = [pairing(macA)]
            backend.localRenameSupported = false
            backend.install([meta("r1", workspace: "/w")], on: macA, live: [])
        }
        await model.rename(key(macA, "r1"), to: "backend")
        XCTAssertEqual(
            model.banner?.text,
            "Session is offline — bring it back online to rename it."
        )
    }

    func testRenameFailureIsSurfaced() async {
        let (model, _) = makeModel { backend in
            backend.homePeers = [pairing(macA)]
            backend.renameFailure = "unknown session: r1"
            backend.install([meta("r1", workspace: "/w")], on: macA, live: ["r1"])
        }
        await model.rename(key(macA, "r1"), to: "backend")
        XCTAssertEqual(model.banner?.text, "unknown session: r1")

        model.dismissBanner()
        XCTAssertNil(model.banner)
    }

    // MARK: Delete (§7.7)

    func testDeleteOnlyWhenOffline() async {
        let (model, backend) = makeModel { backend in
            backend.homePeers = [pairing(macA)]
            backend.install([meta("r1", workspace: "/w")], on: macA, live: ["r1"])
        }
        XCTAssertFalse(model.canDelete(key(macA, "r1")))

        // Even if the menu were stale, the model re-checks: the room can come
        // back between opening the sheet and confirming the dialog.
        await model.delete(key(macA, "r1"))
        XCTAssertTrue(backend.deletes.isEmpty)
        XCTAssertNotNil(model.banner)

        backend.install([meta("r1", workspace: "/w")], on: macA, live: [])
        XCTAssertTrue(model.canDelete(key(macA, "r1")))
        await model.delete(key(macA, "r1"))
        XCTAssertEqual(backend.deletes, [key(macA, "r1")])
    }

    func testDeleteFailureIsSurfaced() async {
        let (model, _) = makeModel { backend in
            backend.homePeers = [pairing(macA)]
            backend.deleteFailure = "nope"
            backend.install([meta("r1", workspace: "/w")], on: macA, live: [])
        }
        await model.delete(key(macA, "r1"))
        XCTAssertEqual(model.banner?.text, "nope")
    }
}
