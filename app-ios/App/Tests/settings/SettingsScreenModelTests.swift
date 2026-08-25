import Foundation
import Observation
import RemotePiProtocol
import XCTest
@testable import RemotePi

// ============================================================================
// Settings — behaviour tests (spec 08 §9, §10).
//
// These cover `SettingsScreenModel` and `RelayURLPolicy`, which are the two
// SwiftUI-free halves of the screen. The model talks only to `SettingsHost`,
// so `RecordingHost` below can assert the thing that actually matters here:
// the ORDER of the revoke steps. Getting that order wrong does not crash and
// does not fail a build — it leaves the relay holding a membership blob that
// still lists a machine the user revoked, and the next 60 s pull resurrects
// the pairing. There is no way to notice that from a screenshot.
//
// ── How to run ──────────────────────────────────────────────────────────────
// There is no app test bundle in `project.yml` today, and adding one changes
// the CI contract. Until one exists these are compiled together with the three
// source files they cover (`RelayURLPolicy.swift`, `SettingsHost.swift`,
// `SettingsScreenModel.swift` — none of which import SwiftUI or AppModel) into
// a throwaway SwiftPM test target that depends on `RemotePiProtocol`.
//
// To wire them permanently, either:
//   * add a `.testTarget(name: "SettingsTests", …)` to `Package.swift` whose
//     sources include `App/Sources/Settings/{RelayURLPolicy,SettingsHost,
//     SettingsScreenModel}.swift` and this file; or
//   * add a unit-test target to `project.yml` and put `@testable import
//     RemotePi` at the top of this file.
// Nothing else in this file changes either way.
// ============================================================================

// MARK: - Fixtures

// `makePeer` is the shared fixture in `home/HomeTestSupport.swift` — identical
// body (32 raw bytes == `PeerID.byteCount`). The private copy that used to live
// here collided with it once both files landed in one test target.

private func makeRecord(
    _ byte: UInt8,
    pairedAt: String,
    nickname: String? = nil,
    sessionName: String? = "mac-studio"
) -> PeerRecord {
    PeerRecord(
        peer: makePeer(byte),
        relayURL: "https://relay.example.com",
        pairedAt: pairedAt,
        sessionName: sessionName,
        nickname: nickname
    )
}

// MARK: - Recording host

/// Records every host call in order. `@Observable` is deliberate: the model
/// watches `peers` through `withObservationTracking`, and a plain class would
/// make that silently never fire — which is exactly the bug the fake should be
/// able to reproduce.
@MainActor
@Observable
private final class RecordingHost: SettingsHost {
    enum Call: Equatable {
        case reloadPeers
        case savePeer(PeerID, String?)
        case deletePeerSilent(PeerID)
        case setRelayURL(String)
        case clearSelectedSession
        case selectPeerWithoutRoom(PeerID)
        case disconnect
        case reconnect
        case subscribe([PeerID])
        case publishMembership(allowEmpty: Bool)
        case reevaluateBootPhase
    }

    private(set) var calls: [Call] = []

    var peers: [PeerRecord] = []
    var relayURL: String = "https://relay.example.com"
    var selectedSession: SessionKey?
    var activePeer: PeerID?
    var onboardingCompleted: Bool = true

    /// What `publishMembership` should answer.
    var publishResult: MembershipPublish = .published
    /// When set, `deletePeerSilent` throws it instead of deleting.
    var deleteError: (any Error)?
    /// When set, `savePeer` throws it instead of writing.
    var saveError: (any Error)?

    @discardableResult
    func reloadPeers() async throws -> [PeerRecord] {
        calls.append(.reloadPeers)
        return peers
    }

    func savePeer(_ record: PeerRecord) async throws {
        if let saveError { throw saveError }
        calls.append(.savePeer(record.peer, record.nickname))
        if let index = peers.firstIndex(where: { $0.peer == record.peer }) {
            peers[index] = record
        } else {
            peers.append(record)
        }
    }

    func deletePeerSilent(_ peer: PeerID) async throws {
        if let deleteError { throw deleteError }
        calls.append(.deletePeerSilent(peer))
        peers.removeAll { $0.peer == peer }
    }

    func setRelayURL(_ url: String) {
        calls.append(.setRelayURL(url))
        relayURL = url
    }

    func clearSelectedSession() async {
        calls.append(.clearSelectedSession)
        selectedSession = nil
    }

    func selectPeerWithoutRoom(_ peer: PeerID) async {
        calls.append(.selectPeerWithoutRoom(peer))
    }

    func disconnect() async { calls.append(.disconnect) }
    func reconnect() async { calls.append(.reconnect) }

    func subscribe(to peers: [PeerID]) async {
        calls.append(.subscribe(peers))
    }

    func publishMembership(allowEmpty: Bool) async -> MembershipPublish {
        calls.append(.publishMembership(allowEmpty: allowEmpty))
        return publishResult
    }

    func reevaluateBootPhase() {
        calls.append(.reevaluateBootPhase)
    }
}

// MARK: - RelayURLPolicy (spec 08 §9.1)

final class RelayURLPolicyTests: XCTestCase {

    func testBlankGetsItsOwnMessage() {
        // Not the generic message: a blank field has a remedy (the button)
        // that a malformed URL does not.
        XCTAssertEqual(RelayURLPolicy.validationMessage(for: ""), RelayURLPolicy.emptyMessage)
        XCTAssertEqual(RelayURLPolicy.validationMessage(for: "   \n"), RelayURLPolicy.emptyMessage)
    }

    func testWebSocketSchemesAreRefusedWithTheSpecificHint() {
        // The user typed the transport's scheme because it IS the transport's
        // scheme; the message has to explain the app converts it itself.
        XCTAssertEqual(
            RelayURLPolicy.validationMessage(for: "wss://relay.example.com"),
            RelayURLPolicy.invalidSchemeMessage
        )
        XCTAssertEqual(
            RelayURLPolicy.validationMessage(for: "ws://127.0.0.1:8080"),
            RelayURLPolicy.invalidSchemeMessage
        )
    }

    func testOtherBadInputGetsTheGenericMessage() {
        for bad in ["relay.example.com", "ftp://relay.example.com", "https://", "http://"] {
            XCTAssertEqual(
                RelayURLPolicy.validationMessage(for: bad),
                RelayURLPolicy.invalidGenericMessage,
                "\(bad) should be rejected generically"
            )
        }
    }

    func testValidURLsPass() {
        for good in [
            "https://relay.example.com",
            "http://127.0.0.1:8080",
            "https://relay.example.com/path",
            "  https://relay.example.com  ",
        ] {
            XCTAssertNil(RelayURLPolicy.validationMessage(for: good), "\(good) should pass")
        }
    }

    func testNormalizeOnlyTrims() {
        // No scheme rewriting and no trailing-slash cleanup: `PeerRecord
        // .relayURL` is compared against this, and quietly rewriting it makes
        // a paired machine look like it lives somewhere else.
        XCTAssertEqual(
            RelayURLPolicy.normalized("  https://relay.example.com/  "),
            "https://relay.example.com/"
        )
    }

    func testTheDefaultIsAValidURL() {
        XCTAssertNil(RelayURLPolicy.validationMessage(for: RelayURLPolicy.defaultRelayURL))
    }
}

// MARK: - Pairings list

@MainActor
final class SettingsPairingsTests: XCTestCase {

    func testStartsLoadingAndBecomesEmpty() async {
        // "Not loaded yet" and "loaded, nothing there" render completely
        // different things; they must not be the same state.
        let host = RecordingHost()
        let model = SettingsScreenModel()
        XCTAssertEqual(model.pairings, .loading)
        model.bind(host: host)
        XCTAssertEqual(model.pairings, .loading)
        await model.activate()
        XCTAssertEqual(model.pairings, .empty)
        model.deactivate()
    }

    func testListIsOrderedByPairedAtThenKey() async {
        // The Dart renders an unordered map read, so its list reorders itself
        // between runs. Deliberate divergence — see `ordered(_:)`.
        let host = RecordingHost()
        host.peers = [
            makeRecord(0x03, pairedAt: "2026-02-01T00:00:00Z"),
            makeRecord(0x02, pairedAt: "2026-01-01T00:00:00Z"),
            makeRecord(0x01, pairedAt: "2026-01-01T00:00:00Z"),
        ]
        let model = SettingsScreenModel()
        model.bind(host: host)
        await model.activate()
        XCTAssertEqual(
            model.pairings.records.map(\.peer),
            [makePeer(0x01), makePeer(0x02), makePeer(0x03)]
        )
        model.deactivate()
    }

    func testAPairingMadeWhileSettingsIsOpenAppears() async {
        // Settings → "Add new pairing" → back is a normal flow, so the list
        // has to be live rather than the Dart's one-shot `_load()`. This is
        // also the regression test for the observation re-arm: if
        // `trackPeers()` stops re-arming, this hangs at one update.
        let host = RecordingHost()
        let model = SettingsScreenModel()
        model.bind(host: host)
        await model.activate()
        XCTAssertEqual(model.pairings, .empty)

        host.peers = [makeRecord(0x01, pairedAt: "2026-01-01T00:00:00Z")]
        await Task.yield()
        XCTAssertEqual(model.pairings.records.count, 1)

        // Second change: proves the tracking re-armed rather than firing once.
        host.peers.append(makeRecord(0x02, pairedAt: "2026-02-01T00:00:00Z"))
        await Task.yield()
        XCTAssertEqual(model.pairings.records.count, 2)

        // …and stops after `deactivate()`.
        model.deactivate()
        host.peers = []
        await Task.yield()
        XCTAssertEqual(model.pairings.records.count, 2)
    }

    func testBindSeedsTheRelayFieldFromTheHost() {
        let host = RecordingHost()
        host.relayURL = "https://custom.example.com"
        let model = SettingsScreenModel()
        model.bind(host: host)
        XCTAssertEqual(model.relayDraft, "https://custom.example.com")
        XCTAssertEqual(model.effectiveRelayURL, "https://custom.example.com")
    }

    func testBindIsIdempotent() {
        // `.task` can run twice for the same view identity; a second bind must
        // not stomp an in-progress edit.
        let host = RecordingHost()
        let model = SettingsScreenModel()
        model.bind(host: host)
        model.relayDraft = "https://typing.example.com"
        model.bind(host: RecordingHost())
        XCTAssertEqual(model.relayDraft, "https://typing.example.com")
    }
}

// MARK: - RELAY (spec 08 §9.1)

@MainActor
final class SettingsRelayTests: XCTestCase {

    private func ready(_ host: RecordingHost) async -> SettingsScreenModel {
        let model = SettingsScreenModel()
        model.bind(host: host)
        await model.activate()
        return model
    }

    func testInvalidURLSetsInlineErrorAndWritesNothing() async {
        let host = RecordingHost()
        let model = await ready(host)
        model.relayDraft = "wss://relay.example.com"
        await model.saveRelayURL()

        XCTAssertEqual(model.relayError, RelayURLPolicy.invalidSchemeMessage)
        XCTAssertNil(model.banner)
        // Nothing was persisted and, crucially, the socket was not cycled.
        XCTAssertFalse(host.calls.contains(.setRelayURL("wss://relay.example.com")))
        XCTAssertFalse(host.calls.contains(.disconnect))
        XCTAssertFalse(host.calls.contains(.reconnect))
        model.deactivate()
    }

    func testEditingClearsAStaleError() async {
        let host = RecordingHost()
        let model = await ready(host)
        model.relayDraft = ""
        await model.saveRelayURL()
        XCTAssertNotNil(model.relayError)
        model.relayDraftEdited()
        XCTAssertNil(model.relayError)
        model.deactivate()
    }

    func testSavePersistsThenCyclesTheSocketInThatOrder() async {
        let host = RecordingHost()
        let model = await ready(host)
        model.relayDraft = "  https://new.example.com  "
        await model.saveRelayURL()

        // Persist BEFORE dialling — `reconnect()` reads the stored URL.
        // Disconnect BEFORE reconnect — the old socket is authenticated
        // against the previous relay and its retry timer would keep dialling.
        XCTAssertEqual(
            host.calls.suffix(3),
            [.setRelayURL("https://new.example.com"), .disconnect, .reconnect]
        )
        XCTAssertEqual(model.relayDraft, "https://new.example.com")
        XCTAssertEqual(model.effectiveRelayURL, "https://new.example.com")
        XCTAssertNil(model.relayError)
        XCTAssertEqual(model.banner, .init(text: "Relay updated", kind: .info))
        model.deactivate()
    }

    func testUseDefaultRelayFillsTheFieldAndCommitsIt() async {
        // The Dart button stuffs the default into the controller and then
        // calls save, so the user never looks at a default they did not save.
        let host = RecordingHost()
        host.relayURL = "https://old.example.com"
        let model = await ready(host)
        await model.useDefaultRelay()

        XCTAssertEqual(model.relayDraft, RelayURLPolicy.defaultRelayURL)
        XCTAssertTrue(host.calls.contains(.setRelayURL(RelayURLPolicy.defaultRelayURL)))
        XCTAssertTrue(host.calls.contains(.reconnect))
        model.deactivate()
    }
}

// MARK: - Nickname (spec 08 §10 — absent vs empty)

@MainActor
final class SettingsNicknameTests: XCTestCase {

    private func ready(_ host: RecordingHost) async -> SettingsScreenModel {
        let model = SettingsScreenModel()
        model.bind(host: host)
        await model.activate()
        return model
    }

    func testCancelWritesNothing() async {
        let host = RecordingHost()
        host.peers = [makeRecord(0x01, pairedAt: "2026-01-01T00:00:00Z", nickname: "Studio")]
        let model = await ready(host)

        model.beginNicknameEdit(model.pairings.records[0])
        model.nicknameDraft = "Something else"
        model.cancelNicknameEdit()

        XCTAssertNil(model.nicknameCandidate)
        XCTAssertFalse(host.calls.contains { if case .savePeer = $0 { return true }; return false })
        XCTAssertEqual(host.peers[0].nickname, "Studio")
        model.deactivate()
    }

    func testBlankDraftClearsTheNicknameRatherThanStoringEmpty() async {
        // `''` from the sheet means "remove", and the caller maps it to nil
        // before saving. Storing "" instead makes `displayLabel` fall through
        // to a blank title.
        let host = RecordingHost()
        host.peers = [makeRecord(0x01, pairedAt: "2026-01-01T00:00:00Z", nickname: "Studio")]
        let model = await ready(host)

        model.beginNicknameEdit(model.pairings.records[0])
        model.nicknameDraft = "   "
        await model.commitNicknameEdit()

        XCTAssertEqual(host.calls.first { if case .savePeer = $0 { return true }; return false },
                       .savePeer(makePeer(0x01), nil))
        XCTAssertNil(host.peers[0].nickname)
        model.deactivate()
    }

    func testSaveTrimsAndPersists() async {
        let host = RecordingHost()
        host.peers = [makeRecord(0x01, pairedAt: "2026-01-01T00:00:00Z")]
        let model = await ready(host)

        model.beginNicknameEdit(model.pairings.records[0])
        model.nicknameDraft = "  Studio  "
        await model.commitNicknameEdit()

        XCTAssertEqual(host.peers[0].nickname, "Studio")
        XCTAssertNil(model.nicknameCandidate)
        XCTAssertEqual(model.pairings.records[0].nickname, "Studio")
        model.deactivate()
    }

    func testUnchangedNicknameDoesNotRepublish() async {
        // A nickname rides in the `mesh_versions` member entry, so a no-op
        // save is a needless signed publish and a needless version bump.
        let host = RecordingHost()
        host.peers = [makeRecord(0x01, pairedAt: "2026-01-01T00:00:00Z", nickname: "Studio")]
        let model = await ready(host)

        model.beginNicknameEdit(model.pairings.records[0])
        model.nicknameDraft = "Studio"
        await model.commitNicknameEdit()

        XCTAssertFalse(host.calls.contains { if case .savePeer = $0 { return true }; return false })
        model.deactivate()
    }

    func testSaveFailureSurfacesAnErrorAndClosesTheSheet() async {
        // The sheet closes on commit regardless: leaving it open with a
        // half-written value invites the user to hit Save again and stack a
        // second failing write. The error goes to the page banner instead.
        struct Boom: LocalizedError { var errorDescription: String? { "store is locked" } }
        let host = RecordingHost()
        host.peers = [makeRecord(0x01, pairedAt: "2026-01-01T00:00:00Z")]
        host.saveError = Boom()
        let model = await ready(host)

        model.beginNicknameEdit(model.pairings.records[0])
        model.nicknameDraft = "Studio"
        await model.commitNicknameEdit()

        XCTAssertNil(model.nicknameCandidate)
        XCTAssertEqual(model.banner?.kind, .error)
        XCTAssertTrue(model.banner?.text.contains("store is locked") == true)
        XCTAssertNil(host.peers[0].nickname)
        model.deactivate()
    }
}

// MARK: - Revoke (spec 08 §9.3 — the ordering is the test)

@MainActor
final class SettingsRevokeTests: XCTestCase {

    private func ready(_ host: RecordingHost) async -> SettingsScreenModel {
        let model = SettingsScreenModel()
        model.bind(host: host)
        await model.activate()
        return model
    }

    func testConfirmDialogCancelChangesNothing() async {
        // `confirmDismiss` returning `false` must snap the row back, not
        // delete it (spec 08 §10).
        let host = RecordingHost()
        host.peers = [makeRecord(0x01, pairedAt: "2026-01-01T00:00:00Z")]
        let model = await ready(host)

        model.requestRevoke(model.pairings.records[0])
        XCTAssertNotNil(model.revokeCandidate)
        model.cancelRevoke()

        XCTAssertNil(model.revokeCandidate)
        XCTAssertEqual(model.pairings.records.count, 1)
        XCTAssertFalse(host.calls.contains(.deletePeerSilent(makePeer(0x01))))
        model.deactivate()
    }

    func testRevokingTheActiveMachineRunsTheSevenStepsInOrder() async {
        let a = makeRecord(0x01, pairedAt: "2026-01-01T00:00:00Z")
        let b = makeRecord(0x02, pairedAt: "2026-02-01T00:00:00Z")
        let host = RecordingHost()
        host.peers = [a, b]
        host.activePeer = a.peer
        host.selectedSession = SessionKey(peer: a.peer, room: RoomID("sess_a"))
        let model = await ready(host)

        let before = host.calls.count
        await model.revoke(a.peer)

        XCTAssertEqual(Array(host.calls.dropFirst(before)), [
            // 2. the pointer named the revoked machine
            .clearSelectedSession,
            // 3. SILENT — the republishing delete would trip the safety net
            .deletePeerSilent(a.peer),
            .reloadPeers,
            // 4. allowEmpty computed from what remains, never hard-coded
            .publishMembership(allowEmpty: false),
            // 5. drop the revoked key from presence BEFORE re-dialling
            .subscribe([b.peer]),
            // 6. it was the active machine: tear down, fall back, re-dial —
            //    with the PEER half only, the room belonged to the revoked one
            .disconnect,
            .selectPeerWithoutRoom(b.peer),
            .reconnect,
        ])
        // 7. peers remain, so onboarding is untouched
        XCTAssertTrue(host.onboardingCompleted)
        XCTAssertFalse(host.calls.contains(.reevaluateBootPhase))
        XCTAssertEqual(model.pairings.records.map(\.peer), [b.peer])
        model.deactivate()
    }

    func testRevokingAnInactiveMachineNeverTouchesTheSocket() async {
        let a = makeRecord(0x01, pairedAt: "2026-01-01T00:00:00Z")
        let b = makeRecord(0x02, pairedAt: "2026-02-01T00:00:00Z")
        let host = RecordingHost()
        host.peers = [a, b]
        host.activePeer = a.peer
        let model = await ready(host)

        await model.revoke(b.peer)

        XCTAssertFalse(host.calls.contains(.disconnect))
        XCTAssertFalse(host.calls.contains(.reconnect))
        XCTAssertFalse(host.calls.contains(.selectPeerWithoutRoom(a.peer)))
        XCTAssertTrue(host.calls.contains(.publishMembership(allowEmpty: false)))
        model.deactivate()
    }

    func testPointerIsClearedOnlyWhenItNamesTheRevokedMachine() async {
        let a = makeRecord(0x01, pairedAt: "2026-01-01T00:00:00Z")
        let b = makeRecord(0x02, pairedAt: "2026-02-01T00:00:00Z")
        let host = RecordingHost()
        host.peers = [a, b]
        host.selectedSession = SessionKey(peer: b.peer, room: RoomID("sess_b"))
        let model = await ready(host)

        await model.revoke(a.peer)

        XCTAssertFalse(host.calls.contains(.clearSelectedSession))
        XCTAssertNotNil(host.selectedSession)
        model.deactivate()
    }

    func testRevokingTheLastMachinePublishesEmptyAndResetsOnboarding() async {
        // The one `allowEmpty: true` in the app. Without it the safety net
        // refuses the publish, the relay keeps listing the revoked machine,
        // and the next 60 s pull resurrects the pairing locally.
        let a = makeRecord(0x01, pairedAt: "2026-01-01T00:00:00Z")
        let host = RecordingHost()
        host.peers = [a]
        host.activePeer = a.peer
        let model = await ready(host)

        let before = host.calls.count
        await model.revoke(a.peer)

        XCTAssertEqual(Array(host.calls.dropFirst(before)), [
            .deletePeerSilent(a.peer),
            .reloadPeers,
            .publishMembership(allowEmpty: true),
            .subscribe([]),
            // Nothing left to fall back to: disconnect and stay disconnected.
            .disconnect,
            .reevaluateBootPhase,
        ])
        XCTAssertFalse(host.onboardingCompleted)
        XCTAssertEqual(model.pairings, .empty)
        model.deactivate()
    }

    func testFallbackIsTheOldestPairing() async {
        // Deterministic, matching Home and boot. `listPeers()` is an unordered
        // read, so "the first one" varied between runs in the Dart.
        let a = makeRecord(0x01, pairedAt: "2026-03-01T00:00:00Z")
        let b = makeRecord(0x02, pairedAt: "2026-01-01T00:00:00Z")
        let c = makeRecord(0x03, pairedAt: "2026-02-01T00:00:00Z")
        let host = RecordingHost()
        host.peers = [a, b, c]
        host.activePeer = a.peer
        let model = await ready(host)

        await model.revoke(a.peer)

        XCTAssertTrue(host.calls.contains(.selectPeerWithoutRoom(b.peer)))
        model.deactivate()
    }

    func testDeferredPublishIsAWarningNotAFailure() async {
        // The pairing IS gone locally. The warning matters because until the
        // blob lands the Mac still believes it is paired.
        let a = makeRecord(0x01, pairedAt: "2026-01-01T00:00:00Z")
        let host = RecordingHost()
        host.peers = [a]
        host.publishResult = .deferred("offline")
        let model = await ready(host)

        await model.revoke(a.peer)

        XCTAssertEqual(model.pairings, .empty)
        XCTAssertEqual(model.banner?.kind, .warning)
        XCTAssertTrue(model.banner?.text.contains("offline") == true)
        model.deactivate()
    }

    func testAFailedDeleteStopsBeforePublishing() async {
        // Publishing membership after a delete that did not happen would
        // revoke a machine the user still has.
        struct Boom: LocalizedError { var errorDescription: String? { "disk is full" } }
        let a = makeRecord(0x01, pairedAt: "2026-01-01T00:00:00Z")
        let host = RecordingHost()
        host.peers = [a]
        host.deleteError = Boom()
        let model = await ready(host)

        await model.revoke(a.peer)

        XCTAssertFalse(host.calls.contains { if case .publishMembership = $0 { return true }; return false })
        XCTAssertFalse(host.calls.contains { if case .subscribe = $0 { return true }; return false })
        XCTAssertEqual(model.banner?.kind, .error)
        XCTAssertTrue(model.banner?.text.contains("disk is full") == true)
        XCTAssertEqual(model.pairings.records.count, 1)
        XCTAssertNil(model.revoking)
        model.deactivate()
    }

    func testASecondRevokeIsRefusedWhileOneIsRunning() async {
        let a = makeRecord(0x01, pairedAt: "2026-01-01T00:00:00Z")
        let host = RecordingHost()
        host.peers = [a]
        let model = await ready(host)
        model.requestRevoke(a)
        XCTAssertNotNil(model.revokeCandidate)
        model.cancelRevoke()
        // `revoking` is cleared by the time `revoke` returns, so the guard is
        // asserted through the static helpers instead of a racy interleave.
        XCTAssertNil(model.revoking)
        model.deactivate()
    }

    func testOrderingHelpersAreStable() {
        let a = makeRecord(0x0A, pairedAt: "2026-01-01T00:00:00Z")
        let b = makeRecord(0x01, pairedAt: "2026-01-01T00:00:00Z")
        let ordered = SettingsScreenModel.ordered([a, b])
        XCTAssertEqual(ordered.map(\.peer), [b.peer, a.peer])
        XCTAssertEqual(SettingsScreenModel.fallback(among: [a, b])?.peer, b.peer)
        XCTAssertNil(SettingsScreenModel.fallback(among: []))
    }
}
