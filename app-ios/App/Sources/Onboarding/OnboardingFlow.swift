import Foundation

/// Which of the three wizard pages is showing (spec 08 §5.2).
///
/// `Int` raw values because the step indicator paints "bar index ≤ current"
/// and that comparison needs an order, not a name.
enum OnboardingStep: Int, CaseIterable, Equatable, Sendable {
    case welcome = 0
    case relay = 1
    case pair = 2
}

/// Which relay the user picked on step 2 (spec 08 §5.4).
enum RelayChoice: Equatable, Sendable {
    /// The bundled community relay. Persists "no override".
    case community
    /// Self-hosted. Carries the `recommended` badge and reveals the URL field.
    case custom
}

/// The pure part of the wizard: step position, the relay form, and what
/// `Continue` is allowed to do. No SwiftUI, no `AppModel`, no I/O — the side
/// effects (persisting the relay URL, pairing, finishing) are returned as
/// values for ``OnboardingModel`` to carry out.
///
/// Ported from `onboarding_viewmodel.dart` + `states/onboarding_state.dart`.
struct OnboardingFlow: Equatable, Sendable {
    private(set) var step: OnboardingStep = .welcome
    private(set) var relayChoice: RelayChoice = .community
    private(set) var customRelayURL: String = ""
    /// Inline `errorText` under the URL field. Recomputed on every keystroke.
    private(set) var customRelayError: String?

    init() {}

    // MARK: - Step 2 form

    /// Radio tap. Clears the inline error but **keeps the typed URL**
    /// (`onboarding_viewmodel.dart:70-74`).
    ///
    /// Consequence worth knowing: type garbage, switch to community, switch
    /// back — the field still holds the garbage and shows no error until the
    /// next keystroke or the next `Continue`. That is the Flutter behaviour and
    /// it is the right one: an error under a field the user is not currently
    /// looking at is noise.
    mutating func setRelayChoice(_ choice: RelayChoice) {
        relayChoice = choice
        customRelayError = nil
    }

    /// Every keystroke (`onboarding_viewmodel.dart:76-85`). An **empty** field
    /// is not an error — empty means "use the default", so the user deleting
    /// what they typed must not be shouted at.
    mutating func setCustomRelayURL(_ url: String) {
        customRelayURL = url
        customRelayError = url.isEmpty ? nil : RelayURL.validationMessage(url)
    }

    /// `Continue`-enabled predicate (`relay_step.dart:31-36`).
    ///
    /// ```
    /// community                     -> enabled
    /// custom && empty               -> enabled   (empty == "use the default")
    /// custom && non-empty           -> enabled iff valid
    /// ```
    var canContinueFromRelay: Bool {
        switch relayChoice {
        case .community: return true
        case .custom:
            if customRelayURL.isEmpty { return true }
            return RelayURL.isValid(customRelayURL)
        }
    }

    /// What step 2 should persist as the relay override.
    ///
    /// `nil` is the Dart `prefs.setRelayUrl(null)` — "no override, fall back to
    /// the default". Kept as an `Optional` rather than pre-substituting the
    /// default so the caller can tell "the user chose the default" from "the
    /// user typed the default's URL by hand"; today they resolve the same, but
    /// collapsing them here would make a future per-user default impossible.
    var relayOverrideToPersist: String? {
        guard relayChoice == .custom, !customRelayURL.isEmpty else { return nil }
        return customRelayURL
    }

    // MARK: - Navigation

    /// The relay-override write step 2 asks its caller to perform.
    ///
    /// Two cases rather than `String?` so "no write required" (leaving step 1)
    /// is not spelled the same as "write an empty override" — a `String??` here
    /// is exactly the kind of thing that reads correctly and behaves wrongly.
    enum RelayWrite: Equatable, Sendable {
        /// The user chose the community relay, or left the custom field empty.
        /// Persist "no override" — resolution falls back to the default.
        case clearOverride
        /// Persist this validated URL as the override.
        case override(String)
    }

    /// What ``advance()`` decided.
    enum Advance: Equatable, Sendable {
        /// Moved to `step`. `persistRelay` is non-`nil` only when leaving the
        /// relay step, and the caller must perform that write.
        case moved(to: OnboardingStep, persistRelay: RelayWrite?)
        /// Stayed put because the relay URL is invalid; the inline error is now
        /// set on the flow.
        case rejected
        /// `next()` from the pair step is a no-op — pairing finishes through
        /// ``OnboardingModel/completePairing()``, never through Continue
        /// (`onboarding_viewmodel.dart:44-46`).
        case ignored
    }

    /// `next()` (`onboarding_viewmodel.dart:19-47`).
    ///
    /// Re-validates on the way out even though the button is already disabled
    /// for an invalid URL: the button's predicate and the error message come
    /// from two different functions, and a keyboard "Go" can fire the action
    /// without the button ever being tapped.
    mutating func advance() -> Advance {
        switch step {
        case .welcome:
            step = .relay
            return .moved(to: .relay, persistRelay: nil)
        case .relay:
            if relayChoice == .custom, !customRelayURL.isEmpty {
                if let reason = RelayURL.validationMessage(customRelayURL) {
                    customRelayError = reason
                    return .rejected
                }
            }
            let write: RelayWrite = relayOverrideToPersist.map(RelayWrite.override) ?? .clearOverride
            customRelayError = nil
            step = .pair
            return .moved(to: .pair, persistRelay: write)
        case .pair:
            return .ignored
        }
    }

    /// `back()` (`onboarding_viewmodel.dart:49-60`). Welcome has no back.
    mutating func back() {
        switch step {
        case .welcome: return
        case .relay: step = .welcome
        case .pair: step = .relay
        }
    }
}

/// The pair step's body state (spec 08 §5.5).
///
/// Separate from ``OnboardingFlow`` because it is driven by an async pairing
/// attempt rather than by button taps, and because the pairing screen proper
/// (spec 08 §6) has the same five states — keeping the transition rules in one
/// testable value means the two screens cannot disagree about when the camera
/// is armed.
struct PairPhaseMachine: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        /// Nothing armed. Reached before the camera is authorised, when the
        /// device has no camera at all (every simulator), and when the user
        /// denied access. The paste path is the app's only way forward here,
        /// so it must stay visible.
        case idle
        /// Live camera + accent frame.
        case scanning
        /// A payload was accepted and is in flight ("Pairing…").
        case connecting
        /// Pairing failed. `canRetry` re-arms the scanner.
        case failed(message: String, canRetry: Bool)
        /// "Paired!" — terminal. The wizard finishes from here.
        case paired
    }

    private(set) var phase: Phase = .idle
    /// Set when the camera is unusable, so the UI can explain *why* the
    /// viewfinder is missing instead of showing an empty rectangle.
    private(set) var cameraIssue: String?

    init() {}

    /// `state is PairingScanning || state is PairingIdle` (`pair_step.dart:131`).
    var showsPasteButton: Bool {
        switch phase {
        case .idle, .scanning: return true
        case .connecting, .failed, .paired: return false
        }
    }

    /// Only `.scanning` runs the capture session. `.idle` deliberately does
    /// not: an idle camera that is still decoding could submit a QR while the
    /// paste sheet is open.
    var isCameraRunning: Bool { phase == .scanning }

    mutating func armCamera() {
        cameraIssue = nil
        if phase == .idle || phase.isFailure { phase = .scanning }
    }

    /// Camera missing / denied / restricted. Falls back to the paste path.
    mutating func disableCamera(reason: String) {
        cameraIssue = reason
        if phase == .scanning || phase == .idle { phase = .idle }
    }

    /// The **disarm-before-submit** rule (spec 08 §5.5, `pair_step.dart:52-58`).
    ///
    /// Returns `false` when the payload must be dropped. Moving to
    /// `.connecting` *synchronously, before any `await`*, is what makes the
    /// camera and the paste sheet unable to submit the same QR twice: the
    /// second caller sees a phase that is no longer accepting.
    mutating func beginSubmit() -> Bool {
        guard phase == .idle || phase == .scanning else { return false }
        phase = .connecting
        return true
    }

    mutating func succeed() { phase = .paired }

    mutating func fail(message: String, canRetry: Bool = true) {
        phase = .failed(message: message, canRetry: canRetry)
    }

    /// `Try again` (`pair_step.dart:225-230`). Re-arms the scanner.
    mutating func retry() {
        guard phase.isFailure else { return }
        phase = cameraIssue == nil ? .scanning : .idle
    }
}

extension PairPhaseMachine.Phase {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
