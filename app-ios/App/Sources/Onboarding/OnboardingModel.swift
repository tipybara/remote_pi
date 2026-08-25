import Observation

/// Why the camera cannot be used, or that it can.
enum CameraAvailability: Equatable, Sendable {
    case available
    /// Reason copy shown in place of the viewfinder. Every case must leave the
    /// paste path reachable — this is the state every simulator is in, and it
    /// is how the app is exercised end to end today.
    case unavailable(reason: String)
}

/// Everything the wizard needs from the outside world.
///
/// The point of this protocol is that ``OnboardingModel`` never mentions
/// `AppModel`, `UserDefaults`, or `AVFoundation`: the state machine is
/// exercised against a stub, and the one adapter that does touch `AppModel`
/// (``AppModelOnboardingBackend``) has no branching left in it to get wrong.
@MainActor
protocol OnboardingBackend: AnyObject {
    /// Printed on the community card so the user sees the host they are
    /// agreeing to (spec 08 §5.4).
    var communityRelayURL: String { get }

    /// `nil` clears the override ("use the default"), a value sets it.
    func persistRelayOverride(_ url: String?)

    /// Runs one pairing attempt. Returns `nil` on success, or the user-facing
    /// failure message.
    func pair(payload: String) async -> String?

    /// Asks (and, if undetermined, prompts) for camera access.
    func cameraAvailability() async -> CameraAvailability
}

/// The 3-step onboarding wizard (spec 08 §5).
///
/// Holds two pure values — ``OnboardingFlow`` for the pages and the relay form,
/// ``PairPhaseMachine`` for step 3 — and does nothing else except perform the
/// side effects those values ask for. Both are tested directly; this class is
/// the wiring.
@MainActor
@Observable
final class OnboardingModel: ScreenModel {

    // MARK: - Observable state

    private(set) var flow = OnboardingFlow()
    private(set) var pairing = PairPhaseMachine()
    /// Flips exactly once, when the wizard is finished **or skipped**. The view
    /// watches it and calls the shell's `finish`, which is what sets
    /// `onboardingCompleted` and re-resolves the boot phase — the model must
    /// not write that preference itself or it would be written twice.
    private(set) var isComplete = false
    /// The camera-less fallback sheet. On the model rather than the view so a
    /// successful submit can close it.
    var isPasteSheetPresented = false

    private var backend: (any OnboardingBackend)?

    // MARK: - Lifecycle (see `ScreenModel.swift`)

    init() {}

    /// Test seam: inject a stub backend. `bind(to:)` will not overwrite it.
    init(backend: any OnboardingBackend) {
        self.backend = backend
    }

    func bind(to app: AppModel) {
        guard backend == nil else { return }
        backend = AppModelOnboardingBackend(app)
    }

    /// No streams to follow — the wizard is driven entirely by taps and by one
    /// awaited pairing attempt.
    func activate() async {}
    func deactivate() {}

    // MARK: - Derived, for the view

    var step: OnboardingStep { flow.step }
    var communityRelayURL: String { backend?.communityRelayURL ?? RelayURL.communityDefault }
    var canContinueFromRelay: Bool { flow.canContinueFromRelay }

    /// Two-way binding for the URL field. Written through
    /// ``OnboardingFlow/setCustomRelayURL(_:)`` so validation runs on every
    /// keystroke, exactly as `onboarding_viewmodel.dart:76-85` does.
    ///
    /// The Flutter version rebuilds a `TextEditingController` inside `build`
    /// and force-moves the caret to the end on every rebuild
    /// (`relay_step.dart:311-316`) — which loses any selection and makes
    /// editing the middle of a URL impossible. A `Binding` has no such
    /// problem; do not reintroduce one by re-seeding the field from state.
    var customRelayURL: String {
        get { flow.customRelayURL }
        set { flow.setCustomRelayURL(newValue) }
    }

    // MARK: - Steps 1 & 2

    func setRelayChoice(_ choice: RelayChoice) {
        flow.setRelayChoice(choice)
    }

    /// `Get started` / `Continue`.
    func next() {
        switch flow.advance() {
        case .moved(_, let write):
            switch write {
            case nil:
                break
            case .clearOverride?:
                backend?.persistRelayOverride(nil)
            case .override(let url)?:
                backend?.persistRelayOverride(url)
            }
        case .rejected, .ignored:
            // `.rejected` already put the message on `flow.customRelayError`.
            break
        }
    }

    func back() {
        flow.back()
    }

    // MARK: - Step 3

    /// Called from the pair step's `.task`. Arms the camera, or records why it
    /// cannot be armed and leaves the paste path as the way forward.
    func prepareCamera() async {
        guard let backend else { return }
        // Do not re-prompt once the user has already got somewhere: coming back
        // from a failed attempt goes through `retryPairing()`.
        guard pairing.phase == .idle else { return }
        switch await backend.cameraAvailability() {
        case .available:
            pairing.armCamera()
        case .unavailable(let reason):
            pairing.disableCamera(reason: reason)
        }
    }

    /// The single submit path for **both** the camera and the paste sheet
    /// (spec 08 §5.5).
    ///
    /// `beginSubmit()` moves the phase to `.connecting` synchronously, before
    /// the first `await`. That is the disarm: a second payload arriving from the
    /// other source in the same run loop is rejected instead of starting a
    /// second pair attempt against the same QR.
    func submit(payload: String) async {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard pairing.beginSubmit() else { return }
        isPasteSheetPresented = false
        guard let backend else {
            pairing.fail(message: "Not ready to pair yet.")
            return
        }
        if let failure = await backend.pair(payload: trimmed) {
            pairing.fail(message: failure)
        } else {
            // One await, one decision, no observer. The Flutter page had to
            // compare against `_lastObserved` because `PairingPaired` is
            // re-emitted when a nickname is applied and an unguarded observer
            // fired `onPaired` twice (spec 08 §5.5). There is no stream here,
            // so the double-fire is structurally impossible.
            pairing.succeed()
            completePairing()
        }
    }

    /// `Try again` on a failed attempt. Re-arms the camera when there is one.
    func retryPairing() {
        pairing.retry()
    }

    /// `Scan later`. Onboarding is marked done so the wizard does not loop, but
    /// no peer exists — Home shows its first-pair empty state, which is the
    /// intended landing, not a dead end (`onboarding_viewmodel.dart:103-107`).
    func skipPairing() {
        completePairing()
    }

    private func completePairing() {
        guard !isComplete else { return }
        isComplete = true
    }
}

/// The only file in the wizard that knows `AppModel` exists.
@MainActor
final class AppModelOnboardingBackend: OnboardingBackend {
    private let app: AppModel

    init(_ app: AppModel) {
        self.app = app
    }

    var communityRelayURL: String { RelayURL.communityDefault }

    /// `AppModel.relayURLText` is a non-optional `String` that writes through to
    /// `UserDefaults`, so "clear the override" is spelled "write the default".
    /// The distinction the Dart keeps (`null` vs a URL) is preserved one layer
    /// up, in ``OnboardingFlow/RelayWrite``.
    func persistRelayOverride(_ url: String?) {
        app.relayURLText = url ?? RelayURL.communityDefault
    }

    /// Success is judged by **a peer appearing in the store**, not by
    /// `lastError` being nil.
    ///
    /// `AppModel.pair` loads the peers and only then starts the managed
    /// session; a relay hiccup in that second half sets `lastError` while the
    /// pairing itself has already been persisted. Reporting that as a failure
    /// would send the user back to the QR for a pairing that already exists.
    /// Connection health is Home's job to show, not the wizard's.
    func pair(payload: String) async -> String? {
        let before = app.peers.count
        await app.pair(pasted: payload)
        if app.peers.count > before { return nil }
        return app.lastError ?? "Pairing failed. Check the code and try again."
    }

    func cameraAvailability() async -> CameraAvailability {
        await CameraPermission.resolve()
    }
}
