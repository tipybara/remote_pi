import XCTest

@testable import RemotePi

/// The wizard's pure state machine (spec 08 §5.2–§5.4), pinned against
/// `onboarding_viewmodel.dart` and `relay_step.dart:31-36`.
final class OnboardingFlowTests: XCTestCase {

    // MARK: - Navigation

    func testStartsOnWelcomeWithCommunityRelay() {
        let flow = OnboardingFlow()
        XCTAssertEqual(flow.step, .welcome)
        XCTAssertEqual(flow.relayChoice, .community)
        XCTAssertEqual(flow.customRelayURL, "")
        XCTAssertNil(flow.customRelayError)
    }

    func testWelcomeAdvancesWithoutPersistingAnything() {
        var flow = OnboardingFlow()
        XCTAssertEqual(flow.advance(), .moved(to: .relay, persistRelay: nil))
        XCTAssertEqual(flow.step, .relay)
    }

    func testBackFromWelcomeIsANoOp() {
        var flow = OnboardingFlow()
        flow.back()
        XCTAssertEqual(flow.step, .welcome)
    }

    func testBackWalksPairToRelayToWelcome() {
        var flow = OnboardingFlow()
        _ = flow.advance()
        _ = flow.advance()
        XCTAssertEqual(flow.step, .pair)
        flow.back()
        XCTAssertEqual(flow.step, .relay)
        flow.back()
        XCTAssertEqual(flow.step, .welcome)
    }

    /// `next()` from the pair step is explicitly a no-op — pairing finishes
    /// through the pair callback, never through Continue.
    func testAdvanceFromPairIsIgnored() {
        var flow = OnboardingFlow()
        _ = flow.advance()
        _ = flow.advance()
        XCTAssertEqual(flow.advance(), .ignored)
        XCTAssertEqual(flow.step, .pair)
    }

    // MARK: - Continue-enabled predicate

    func testCommunityAlwaysAllowsContinue() {
        var flow = OnboardingFlow()
        flow.setCustomRelayURL("nonsense")
        flow.setRelayChoice(.community)
        XCTAssertTrue(flow.canContinueFromRelay)
    }

    /// Empty means "use the default" — it is a valid choice, not a blocked form.
    func testCustomWithEmptyURLAllowsContinue() {
        var flow = OnboardingFlow()
        flow.setRelayChoice(.custom)
        XCTAssertTrue(flow.canContinueFromRelay)
    }

    func testCustomWithInvalidURLBlocksContinue() {
        var flow = OnboardingFlow()
        flow.setRelayChoice(.custom)
        flow.setCustomRelayURL("wss://relay.example.com")
        XCTAssertFalse(flow.canContinueFromRelay)
    }

    func testCustomWithValidURLAllowsContinue() {
        var flow = OnboardingFlow()
        flow.setRelayChoice(.custom)
        flow.setCustomRelayURL("https://relay.example.com")
        XCTAssertTrue(flow.canContinueFromRelay)
    }

    // MARK: - Inline validation

    func testValidationRunsOnEveryKeystroke() {
        var flow = OnboardingFlow()
        flow.setRelayChoice(.custom)
        flow.setCustomRelayURL("h")
        XCTAssertEqual(flow.customRelayError, RelayURL.invalidGenericMessage)
        flow.setCustomRelayURL("https://relay.example.com")
        XCTAssertNil(flow.customRelayError)
    }

    /// Deleting back to empty is not an error: the user is still typing, and
    /// empty is a legal choice.
    func testClearingTheFieldClearsTheError() {
        var flow = OnboardingFlow()
        flow.setRelayChoice(.custom)
        flow.setCustomRelayURL("ws://x")
        XCTAssertNotNil(flow.customRelayError)
        flow.setCustomRelayURL("")
        XCTAssertNil(flow.customRelayError)
    }

    /// Switching the radio clears the error but keeps the typed text
    /// (`onboarding_viewmodel.dart:70-74`).
    func testSwitchingChoiceClearsErrorButKeepsTheURL() {
        var flow = OnboardingFlow()
        flow.setRelayChoice(.custom)
        flow.setCustomRelayURL("nope")
        XCTAssertNotNil(flow.customRelayError)
        flow.setRelayChoice(.community)
        XCTAssertNil(flow.customRelayError)
        XCTAssertEqual(flow.customRelayURL, "nope")
        flow.setRelayChoice(.custom)
        XCTAssertEqual(flow.customRelayURL, "nope")
        XCTAssertFalse(flow.canContinueFromRelay)
    }

    // MARK: - What step 2 persists

    func testCommunityPersistsNoOverride() {
        var flow = OnboardingFlow()
        _ = flow.advance()
        XCTAssertEqual(flow.advance(), .moved(to: .pair, persistRelay: .clearOverride))
    }

    func testEmptyCustomPersistsNoOverride() {
        var flow = OnboardingFlow()
        _ = flow.advance()
        flow.setRelayChoice(.custom)
        XCTAssertEqual(flow.advance(), .moved(to: .pair, persistRelay: .clearOverride))
    }

    func testValidCustomPersistsTheOverride() {
        var flow = OnboardingFlow()
        _ = flow.advance()
        flow.setRelayChoice(.custom)
        flow.setCustomRelayURL("https://relay.example.com")
        XCTAssertEqual(
            flow.advance(),
            .moved(to: .pair, persistRelay: .override("https://relay.example.com"))
        )
    }

    /// The keyboard's "Continue" can fire the action while the button itself is
    /// disabled, so `advance()` re-validates rather than trusting the caller.
    func testAdvanceRejectsAnInvalidCustomURLAndSetsTheError() {
        var flow = OnboardingFlow()
        _ = flow.advance()
        flow.setRelayChoice(.custom)
        flow.setCustomRelayURL("wss://relay.example.com")
        XCTAssertEqual(flow.advance(), .rejected)
        XCTAssertEqual(flow.step, .relay)
        XCTAssertEqual(flow.customRelayError, RelayURL.invalidSchemeMessage)
    }

    /// The error survives a round trip through the other radio and re-appears
    /// on Continue — it is not silently forgotten.
    func testErrorReappearsOnContinueAfterSwitchingAway() {
        var flow = OnboardingFlow()
        _ = flow.advance()
        flow.setRelayChoice(.custom)
        flow.setCustomRelayURL("wss://relay.example.com")
        flow.setRelayChoice(.community)
        flow.setRelayChoice(.custom)
        XCTAssertNil(flow.customRelayError)
        XCTAssertEqual(flow.advance(), .rejected)
        XCTAssertEqual(flow.customRelayError, RelayURL.invalidSchemeMessage)
    }
}
