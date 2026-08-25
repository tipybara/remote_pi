import AVFoundation
import XCTest

@testable import RemotePi

/// The gate's copy is the whole screen (spec 08 §4), so it is pinned verbatim
/// against `sync_required_page.dart:169-180`. A well-meaning reword here is a
/// user following instructions that do not match iOS Settings.
final class SyncRequirementsTests: XCTestCase {

    func testIOSRequirementsAreVerbatimAndInOrder() {
        let steps = SyncRequirements.ios
        XCTAssertEqual(steps.count, 2)

        XCTAssertEqual(steps[0].number, 1)
        XCTAssertEqual(steps[0].title, "Sign in to iCloud")
        XCTAssertEqual(steps[0].path, "Settings › [your name]")
        XCTAssertEqual(
            steps[0].note,
            "If you see \"Sign in to your iPhone\" at the top, tap it."
        )

        XCTAssertEqual(steps[1].number, 2)
        XCTAssertEqual(steps[1].title, "Turn on iCloud Keychain")
        XCTAssertEqual(
            steps[1].path,
            "Settings › [your name] › iCloud › Passwords and Keychain"
        )
        XCTAssertEqual(steps[1].note, "Toggle \"Sync this iPhone\" on.")
    }

    func testNumbersAreTheDisplayedOrderNotArrayIndices() {
        for (index, step) in SyncRequirements.ios.enumerated() {
            XCTAssertEqual(step.number, index + 1)
            XCTAssertEqual(step.id, step.number)
        }
    }

    /// `›` is silent in VoiceOver, which turns a breadcrumb into one run-on
    /// phrase. These steps are the only actionable content on the screen.
    func testSpokenPathExpandsTheBreadcrumb() {
        XCTAssertEqual(
            SyncRequirements.ios[1].spokenPath,
            "Settings, then [your name], then iCloud, then Passwords and Keychain"
        )
    }

    func testWhyCopyIsVerbatim() {
        XCTAssertEqual(
            SyncRequirements.why,
            "Remote Pi keeps your Ed25519 owner key in iCloud Keychain so "
                + "you can switch iPhones or pair your iPad without scanning "
                + "a new QR."
        )
    }
}

/// The camera decision table (spec 08 §5.5's `PairingIdle` body).
final class CameraPermissionTests: XCTestCase {

    /// The device check comes first on purpose: a simulator reports
    /// `.authorized` and has no back camera, and "authorized" there would put a
    /// black rectangle on screen with no way forward.
    func testNoCaptureDeviceBeatsAuthorized() {
        XCTAssertEqual(
            CameraPermission.decide(status: .authorized, hasCaptureDevice: false),
            .unavailable(reason: CameraPermission.noDeviceReason)
        )
    }

    func testAuthorizedWithADeviceIsAvailable() {
        XCTAssertEqual(
            CameraPermission.decide(status: .authorized, hasCaptureDevice: true),
            .available
        )
    }

    func testDeniedAndRestrictedExplainThemselvesDifferently() {
        XCTAssertEqual(
            CameraPermission.decide(status: .denied, hasCaptureDevice: true),
            .unavailable(reason: CameraPermission.deniedReason)
        )
        XCTAssertEqual(
            CameraPermission.decide(status: .restricted, hasCaptureDevice: true),
            .unavailable(reason: CameraPermission.restrictedReason)
        )
    }

    /// `resolve()` prompts before deciding, so `.notDetermined` reaching
    /// `decide` means the prompt was declined or never shown.
    func testNotDeterminedIsTreatedAsUnavailable() {
        XCTAssertEqual(
            CameraPermission.decide(status: .notDetermined, hasCaptureDevice: true),
            .unavailable(reason: CameraPermission.deniedReason)
        )
    }

    /// Every unavailable reason has to end at the paste path; otherwise the
    /// screen is a dead end.
    func testEveryUnavailableReasonPointsAtThePastePath() {
        for reason in [
            CameraPermission.noDeviceReason,
            CameraPermission.deniedReason,
            CameraPermission.restrictedReason,
        ] {
            XCTAssertTrue(
                reason.lowercased().contains("paste"),
                "reason must offer the paste fallback: \(reason)"
            )
        }
    }
}
