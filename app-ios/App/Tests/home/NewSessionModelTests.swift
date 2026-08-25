import Foundation
import RemotePiProtocol
import RemotePiSession
import XCTest
@testable import RemotePi

/// `NewSessionModel` — spec 08 §7.9, and the two traps it exists to avoid:
/// idempotency keys (§13.9) and `action_ok` ≠ "the room is up" (§13.10).
@MainActor
final class NewSessionModelTests: XCTestCase {
    private func makeModel(
        _ configure: (FakeHomeBackend) -> Void = { _ in }
    ) -> (NewSessionModel, FakeHomeBackend) {
        let backend = FakeHomeBackend()
        configure(backend)
        return (NewSessionModel(backend: backend, roomWaitBudget: .milliseconds(1)), backend)
    }

    // MARK: Phases

    func testNoReachableMachine() async {
        let (model, _) = makeModel()
        await model.start()
        XCTAssertEqual(model.phase, .noMachine)
    }

    /// A one-option picker is noise, so a single reachable machine is
    /// auto-selected and its folders loaded (spec 08 §7.9 step 1).
    func testSingleMachineIsAutoSelected() async {
        let (model, backend) = makeModel { backend in
            backend.machinesAcceptingSessions = [pairing(macA, nickname: "Studio")]
            backend.workspacesResult = .success([workspace("ws_1", path: "/Users/me/api")])
        }
        await model.start()
        XCTAssertEqual(model.machine?.peer, macA)
        XCTAssertEqual(backend.workspaceCalls, 1)
        XCTAssertEqual(model.phase, .pickWorkspace)
    }

    func testTwoMachinesShowThePicker() async {
        let (model, backend) = makeModel { backend in
            backend.machinesAcceptingSessions = [pairing(macA), pairing(macB)]
        }
        await model.start()
        XCTAssertEqual(model.phase, .pickMachine)
        XCTAssertEqual(backend.workspaceCalls, 0)

        await model.select(pairing(macB))
        XCTAssertEqual(backend.workspaceCalls, 1)
    }

    /// An empty list is a legitimate answer, not an error: nothing is
    /// registered yet, and the copy names the command that fixes it.
    func testEmptyWorkspaceListIsItsOwnState() async {
        let (model, _) = makeModel { backend in
            backend.machinesAcceptingSessions = [pairing(macA)]
            backend.workspacesResult = .success([])
        }
        await model.start()
        XCTAssertEqual(model.phase, .noWorkspaces)
        XCTAssertNil(model.errorText, "an empty catalogue is not a failure")
    }

    /// "We could not ask" is not "this machine has no folders": the folder list
    /// stays `nil` so the two do not render the same.
    func testWorkspaceListFailureKeepsTheListUnknown() async {
        let (model, _) = makeModel { backend in
            backend.machinesAcceptingSessions = [pairing(macA)]
            backend.workspacesResult = .failure(ControlActionFailure(message: "boom"))
        }
        await model.start()
        XCTAssertEqual(model.errorText, "boom")
        XCTAssertNotEqual(model.phase, .noWorkspaces)
    }

    /// A control-plane timeout on a visibly-online machine is most likely an
    /// authorization problem — an unpaired phone is dropped in silence — so the
    /// copy must not just say "retry" (spec 09 §3).
    func testTimeoutCopyPointsAtPairing() async {
        let (model, _) = makeModel { backend in
            backend.machinesAcceptingSessions = [pairing(macA)]
            backend.workspacesResult = .failure(ControlPlaneError.timeout)
        }
        await model.start()
        XCTAssertEqual(
            model.errorText,
            "That Mac did not answer. If it is online, it may no longer accept "
                + "commands from this phone — try pairing again."
        )
    }

    // MARK: Create

    func testCreateWaitsForTheRoomBeforeReporting() async {
        let (model, backend) = makeModel { backend in
            backend.machinesAcceptingSessions = [pairing(macA)]
            backend.workspacesResult = .success([workspace("ws_1", path: "/Users/me/api")])
            backend.requestResult = .success(SessionID("019ffb64-aaaa"))
            backend.waitResult = true
        }
        await model.start()
        await model.create(in: workspace("ws_1", path: "/Users/me/api"))

        XCTAssertEqual(backend.waits, [key(macA, "019ffb64-aaaa")], "room_id == session_id")
        XCTAssertEqual(model.created, key(macA, "019ffb64-aaaa"))
        XCTAssertEqual(model.phase, .created(key(macA, "019ffb64-aaaa")))
        XCTAssertNil(model.errorText)
    }

    /// `action_ok` means "spawn requested". A room that has not come up is
    /// **not** a failure and must not read like one (spec 08 §13.10).
    func testRoomThatDoesNotComeUpIsNotAFailure() async {
        let (model, _) = makeModel { backend in
            backend.machinesAcceptingSessions = [pairing(macA)]
            backend.workspacesResult = .success([workspace("ws_1", path: "/w")])
            backend.requestResult = .success(SessionID("s1"))
            backend.waitResult = false
        }
        await model.start()
        await model.create(in: workspace("ws_1", path: "/w"))

        XCTAssertNil(model.created, "nothing is opened until the relay announces the room")
        XCTAssertEqual(
            model.errorText,
            "Session created, but it has not come online yet. "
                + "It will appear in the list when it does."
        )
    }

    func testActionErrorIsSurfacedVerbatim() async {
        let (model, backend) = makeModel { backend in
            backend.machinesAcceptingSessions = [pairing(macA)]
            backend.workspacesResult = .success([workspace("ws_1", path: "/w")])
            backend.requestResult = .failure(ControlActionFailure(message: "unknown workspace: ws_1"))
        }
        await model.start()
        await model.create(in: workspace("ws_1", path: "/w"))

        XCTAssertEqual(model.errorText, "unknown workspace: ws_1")
        XCTAssertTrue(backend.waits.isEmpty, "never wait for a room that was never requested")
        XCTAssertNil(model.created)
    }

    // MARK: Idempotency (§13.9)

    /// Retrying the SAME target reuses the key, so the machine replays the
    /// original outcome instead of spawning a second process.
    func testRetryOfTheSameTargetReusesTheKey() async {
        let ws = workspace("ws_1", path: "/w")
        let (model, backend) = makeModel { backend in
            backend.machinesAcceptingSessions = [pairing(macA)]
            backend.workspacesResult = .success([ws])
            backend.requestResult = .failure(ControlActionFailure(message: "transient"))
        }
        await model.start()
        await model.create(in: ws)
        await model.create(in: ws)
        await model.create(in: ws)

        XCTAssertEqual(backend.requests.count, 3)
        XCTAssertEqual(Set(backend.requests.map(\.idempotencyKey)).count, 1)
    }

    /// A DIFFERENT folder gets a different key. The Flutter sheet mints one key
    /// per sheet and would replay folder A's outcome for folder B, which is a
    /// bug this client deliberately does not reproduce — the ≥24h replay
    /// guarantee for a retried intent is untouched.
    func testADifferentFolderGetsItsOwnKey() async {
        let first = workspace("ws_1", path: "/a")
        let second = workspace("ws_2", path: "/b")
        let (model, backend) = makeModel { backend in
            backend.machinesAcceptingSessions = [pairing(macA)]
            backend.workspacesResult = .success([first, second])
            backend.requestResult = .failure(ControlActionFailure(message: "transient"))
        }
        await model.start()
        await model.create(in: first)
        await model.create(in: second)

        XCTAssertEqual(Set(backend.requests.map(\.idempotencyKey)).count, 2)
    }

    /// The key must be minted random, never derived from the target — a hash
    /// of `workspace_id` would pin the outcome for 24h and make the *second*
    /// "New session in this folder" replay the first session's id.
    func testKeysAreNotDerivedFromTheTarget() async {
        let ws = workspace("ws_1", path: "/a")
        func keyForFreshModel() async -> IdempotencyKey {
            let (model, backend) = makeModel { backend in
                backend.machinesAcceptingSessions = [pairing(macA)]
                backend.workspacesResult = .success([ws])
                backend.requestResult = .failure(ControlActionFailure(message: "x"))
            }
            await model.start()
            await model.create(in: ws)
            return backend.requests[0].idempotencyKey
        }
        let a = await keyForFreshModel()
        let b = await keyForFreshModel()
        XCTAssertNotEqual(a, b, "a new intent is a new key")
    }

    /// The display name rides along so the new session gets a useful label
    /// immediately; `background` is always true on the wire (v1 is
    /// background-only), which the Kit's action encoder owns.
    func testIntentCarriesTheWorkspaceLabel() async {
        let ws = workspace("ws_1", path: "/Users/me/api", name: "api")
        let (model, backend) = makeModel { backend in
            backend.machinesAcceptingSessions = [pairing(macA)]
            backend.workspacesResult = .success([ws])
            backend.requestResult = .success(SessionID("s1"))
        }
        await model.start()
        await model.create(in: ws)

        XCTAssertEqual(backend.requests.first?.workspace, WorkspaceID("ws_1"))
        XCTAssertEqual(backend.requests.first?.displayName, "api")
        XCTAssertEqual(backend.requests.first?.machine, macA)
    }

    // MARK: Machine label

    func testMachineLabelPreference() {
        XCTAssertEqual(NewSessionModel.label(for: pairing(macA, nickname: "Studio")), "Studio")
        XCTAssertEqual(NewSessionModel.label(for: pairing(macA, sessionName: "Mac mini")), "Mac mini")
        XCTAssertEqual(
            NewSessionModel.label(for: pairing(macA, sessionName: nil)),
            macA.shortDescription
        )
    }
}
