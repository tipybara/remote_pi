import XCTest

@testable import RemotePi

/// Step 3's body state (spec 08 §5.5). The rules under test are the two that
/// were bugs in the Flutter original: the camera and the paste sheet must not
/// both submit the same QR, and the "paired" transition must happen once.
final class PairPhaseMachineTests: XCTestCase {

    func testStartsIdleWithThePastePathAvailable() {
        let machine = PairPhaseMachine()
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertTrue(machine.showsPasteButton)
        XCTAssertFalse(machine.isCameraRunning)
        XCTAssertNil(machine.cameraIssue)
    }

    func testArmingTheCameraStartsScanning() {
        var machine = PairPhaseMachine()
        machine.armCamera()
        XCTAssertEqual(machine.phase, .scanning)
        XCTAssertTrue(machine.isCameraRunning)
        XCTAssertTrue(machine.showsPasteButton)
    }

    /// Every simulator lands here, and so does a denied permission. The paste
    /// path must stay reachable or the app is unusable.
    func testDisablingTheCameraKeepsThePastePathAndRecordsWhy() {
        var machine = PairPhaseMachine()
        machine.disableCamera(reason: "no camera")
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertFalse(machine.isCameraRunning)
        XCTAssertTrue(machine.showsPasteButton)
        XCTAssertEqual(machine.cameraIssue, "no camera")
    }

    // MARK: - The disarm rule

    /// The whole point: the second submitter is refused, synchronously, before
    /// anything awaits.
    func testSecondSubmitIsRefusedWhileConnecting() {
        var machine = PairPhaseMachine()
        machine.armCamera()
        XCTAssertTrue(machine.beginSubmit())
        XCTAssertEqual(machine.phase, .connecting)
        XCTAssertFalse(machine.beginSubmit())
    }

    func testPasteCanSubmitFromIdleWhenThereIsNoCamera() {
        var machine = PairPhaseMachine()
        machine.disableCamera(reason: "no camera")
        XCTAssertTrue(machine.beginSubmit())
        XCTAssertEqual(machine.phase, .connecting)
    }

    func testSubmitIsRefusedOncePaired() {
        var machine = PairPhaseMachine()
        machine.armCamera()
        _ = machine.beginSubmit()
        machine.succeed()
        XCTAssertEqual(machine.phase, .paired)
        XCTAssertFalse(machine.beginSubmit())
        XCTAssertFalse(machine.showsPasteButton)
    }

    /// A failed attempt must not leave a live submit path open either — the
    /// user has to press `Try again`, which is what re-arms the camera.
    func testSubmitIsRefusedWhileShowingAFailure() {
        var machine = PairPhaseMachine()
        machine.armCamera()
        _ = machine.beginSubmit()
        machine.fail(message: "nope")
        XCTAssertFalse(machine.beginSubmit())
        XCTAssertFalse(machine.showsPasteButton)
    }

    // MARK: - Retry

    func testRetryReArmsTheCameraWhenThereIsOne() {
        var machine = PairPhaseMachine()
        machine.armCamera()
        _ = machine.beginSubmit()
        machine.fail(message: "nope")
        machine.retry()
        XCTAssertEqual(machine.phase, .scanning)
        XCTAssertTrue(machine.isCameraRunning)
    }

    /// Retrying on a device with no camera goes back to idle — where the paste
    /// button is — not to a viewfinder that cannot render.
    func testRetryFallsBackToIdleWhenTheCameraIsUnusable() {
        var machine = PairPhaseMachine()
        machine.disableCamera(reason: "no camera")
        _ = machine.beginSubmit()
        machine.fail(message: "nope")
        machine.retry()
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertTrue(machine.showsPasteButton)
    }

    func testRetryDoesNothingWhenNotFailed() {
        var machine = PairPhaseMachine()
        machine.armCamera()
        _ = machine.beginSubmit()
        machine.retry()
        XCTAssertEqual(machine.phase, .connecting)
    }

    /// `armCamera()` must not walk backwards out of a live attempt — the pair
    /// step's `.task` can run again on a scene re-activation.
    func testArmingDoesNotInterruptAnAttemptInFlight() {
        var machine = PairPhaseMachine()
        machine.armCamera()
        _ = machine.beginSubmit()
        machine.armCamera()
        XCTAssertEqual(machine.phase, .connecting)
    }
}
