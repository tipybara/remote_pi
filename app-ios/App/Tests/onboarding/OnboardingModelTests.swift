import XCTest

@testable import RemotePi

/// A stub ``OnboardingBackend``. The model is exercised without `AppModel`,
/// `UserDefaults` or a camera — which is the reason the protocol exists.
@MainActor
final class StubOnboardingBackend: OnboardingBackend {
    var communityRelayURL = "https://relay.example.test"
    var camera: CameraAvailability = .available
    /// `nil` = the next pair attempt succeeds; a string = it fails with that.
    var pairFailure: String?

    private(set) var persisted: [String?] = []
    private(set) var pairPayloads: [String] = []
    private(set) var cameraQueries = 0

    func persistRelayOverride(_ url: String?) {
        persisted.append(url)
    }

    func pair(payload: String) async -> String? {
        pairPayloads.append(payload)
        return pairFailure
    }

    func cameraAvailability() async -> CameraAvailability {
        cameraQueries += 1
        return camera
    }
}

@MainActor
final class OnboardingModelTests: XCTestCase {

    private func makeModel() -> (OnboardingModel, StubOnboardingBackend) {
        let backend = StubOnboardingBackend()
        return (OnboardingModel(backend: backend), backend)
    }

    // MARK: - Relay persistence

    func testCommunityChoicePersistsNoOverride() {
        let (model, backend) = makeModel()
        model.next()                       // welcome -> relay
        XCTAssertTrue(backend.persisted.isEmpty)
        model.next()                       // relay -> pair
        XCTAssertEqual(backend.persisted.count, 1)
        XCTAssertNil(backend.persisted[0])
        XCTAssertEqual(model.step, .pair)
    }

    func testCustomURLIsPersistedVerbatim() {
        let (model, backend) = makeModel()
        model.next()
        model.setRelayChoice(.custom)
        model.customRelayURL = "https://my-relay.example"
        model.next()
        XCTAssertEqual(backend.persisted, ["https://my-relay.example"])
    }

    /// Empty means "use the default" — it persists a cleared override, not an
    /// empty string.
    func testEmptyCustomURLPersistsAClearedOverride() {
        let (model, backend) = makeModel()
        model.next()
        model.setRelayChoice(.custom)
        model.next()
        XCTAssertEqual(backend.persisted.count, 1)
        XCTAssertNil(backend.persisted[0])
    }

    func testInvalidURLDoesNotAdvanceAndDoesNotPersist() {
        let (model, backend) = makeModel()
        model.next()
        model.setRelayChoice(.custom)
        model.customRelayURL = "wss://my-relay.example"
        model.next()
        XCTAssertEqual(model.step, .relay)
        XCTAssertTrue(backend.persisted.isEmpty)
        XCTAssertEqual(model.flow.customRelayError, RelayURL.invalidSchemeMessage)
        XCTAssertFalse(model.canContinueFromRelay)
    }

    // MARK: - Camera

    func testPrepareCameraArmsTheScanner() async {
        let (model, _) = makeModel()
        await model.prepareCamera()
        XCTAssertEqual(model.pairing.phase, .scanning)
    }

    func testPrepareCameraFallsBackToThePastePath() async {
        let (model, backend) = makeModel()
        backend.camera = .unavailable(reason: "no camera")
        await model.prepareCamera()
        XCTAssertEqual(model.pairing.phase, .idle)
        XCTAssertEqual(model.pairing.cameraIssue, "no camera")
        XCTAssertTrue(model.pairing.showsPasteButton)
    }

    /// The pair step's `.task` can run twice (scene re-activation). Re-prompting
    /// mid-attempt would both re-ask for permission and reset the phase.
    func testPrepareCameraIsANoOpOnceSomethingIsInFlight() async {
        let (model, backend) = makeModel()
        await model.prepareCamera()
        _ = model.pairing
        await model.submit(payload: "remotepi://pair?a=1")
        let queries = backend.cameraQueries
        await model.prepareCamera()
        XCTAssertEqual(backend.cameraQueries, queries)
    }

    // MARK: - Pairing

    func testSuccessfulPairCompletesTheWizardExactlyOnce() async {
        let (model, _) = makeModel()
        await model.prepareCamera()
        await model.submit(payload: "remotepi://pair?a=1")
        XCTAssertEqual(model.pairing.phase, .paired)
        XCTAssertTrue(model.isComplete)

        // `PairingPaired` was re-emitted on nickname-apply in Flutter and fired
        // the completion twice. `isComplete` latches, so a second submit cannot.
        await model.submit(payload: "remotepi://pair?a=1")
        XCTAssertTrue(model.isComplete)
    }

    /// The disarm rule, end to end: the camera and the paste sheet cannot both
    /// pair the same QR.
    func testConcurrentSubmitsOnlyRunOnePairAttempt() async {
        let (model, backend) = makeModel()
        await model.prepareCamera()
        async let first: Void = model.submit(payload: "remotepi://pair?a=1")
        async let second: Void = model.submit(payload: "remotepi://pair?a=1")
        _ = await (first, second)
        XCTAssertEqual(backend.pairPayloads.count, 1)
    }

    func testFailedPairShowsTheMessageAndDoesNotComplete() async {
        let (model, backend) = makeModel()
        backend.pairFailure = "Relay unreachable."
        await model.prepareCamera()
        await model.submit(payload: "remotepi://pair?a=1")
        XCTAssertEqual(model.pairing.phase, .failed(message: "Relay unreachable.", canRetry: true))
        XCTAssertFalse(model.isComplete)
        XCTAssertFalse(model.pairing.showsPasteButton)
    }

    func testRetryAfterAFailureReArmsAndCanSucceed() async {
        let (model, backend) = makeModel()
        backend.pairFailure = "Relay unreachable."
        await model.prepareCamera()
        await model.submit(payload: "remotepi://pair?a=1")
        model.retryPairing()
        XCTAssertEqual(model.pairing.phase, .scanning)

        backend.pairFailure = nil
        await model.submit(payload: "remotepi://pair?a=2")
        XCTAssertTrue(model.isComplete)
        XCTAssertEqual(backend.pairPayloads.count, 2)
    }

    func testBlankPayloadIsIgnored() async {
        let (model, backend) = makeModel()
        await model.prepareCamera()
        await model.submit(payload: "   \n ")
        XCTAssertTrue(backend.pairPayloads.isEmpty)
        XCTAssertEqual(model.pairing.phase, .scanning)
    }

    func testPayloadIsTrimmedBeforePairing() async {
        let (model, backend) = makeModel()
        await model.prepareCamera()
        await model.submit(payload: "  remotepi://pair?a=1\n")
        XCTAssertEqual(backend.pairPayloads, ["remotepi://pair?a=1"])
    }

    /// Accepting a payload closes the paste sheet, so pairing progress shows in
    /// the viewfinder slot instead of behind a modal.
    func testSubmitClosesThePasteSheet() async {
        let (model, _) = makeModel()
        await model.prepareCamera()
        model.isPasteSheetPresented = true
        await model.submit(payload: "remotepi://pair?a=1")
        XCTAssertFalse(model.isPasteSheetPresented)
    }

    // MARK: - Skip

    /// `Scan later` finishes the wizard with zero peers on purpose: Home's
    /// first-pair empty state is the intended landing.
    func testSkipCompletesWithoutPairing() {
        let (model, backend) = makeModel()
        model.skipPairing()
        XCTAssertTrue(model.isComplete)
        XCTAssertTrue(backend.pairPayloads.isEmpty)
    }
}
