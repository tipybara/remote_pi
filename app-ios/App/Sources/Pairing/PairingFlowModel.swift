import Foundation
import Observation
import RemotePiPairing
import RemotePiProtocol

/// The pairing screen's brain (spec 08 §6, and §5.5 when embedded in
/// onboarding step 3).
///
/// Imports no SwiftUI and no `AppModel` — see the header of
/// `PairingFlowState.swift`. `ScreenModel` conformance and the real backend
/// live in `PairingFlowModel+AppModel.swift`; everything below runs in a plain
/// test process.
///
/// ## The three traps this type exists to hold
///
/// 1. **One submit path.** The camera and the paste sheet both call
///    ``submit(_:from:)``. There is no second entry point, so there is no
///    second place to forget the disarm.
/// 2. **Disarm before the await, not before the parse.** `pair_step.dart:52-58`
///    stops the scanner *before* handing the payload to the view model, which
///    is right — but it does it before the payload has been validated, so a
///    stray wifi QR in frame kills the camera permanently. We disarm between
///    the two: after the payload is known good, before anything suspends.
/// 3. **The paired state is entered once.** `PairingPaired` is re-emitted when
///    the nickname is applied (`pairing_viewmodel.dart:116-124`); an unguarded
///    observer opens the nickname sheet twice. ``didStartPostPairFlow`` is that
///    guard, and it is reset only by ``retry()``.
@MainActor
@Observable
final class PairingFlowModel {
    // MARK: - Read model

    private(set) var state: PairingFlowState = .scanning
    private(set) var camera: CameraGate = .undetermined

    /// Whether a payload may still be handed in from the capture pipeline.
    ///
    /// Separate from ``PairingFlowState/acceptsSubmission`` on purpose: the
    /// state says "the flow is in a phase that could accept one", this says
    /// "this particular scan attempt has not already been spent". Both must be
    /// true. Collapsing them loses the window between "payload accepted" and
    /// "state actually changed", which is exactly where a second camera frame
    /// lands.
    private(set) var isScannerArmed = true

    /// Drives `.sheet(isPresented:)` for the paste sheet. Writable because
    /// SwiftUI needs a binding for the swipe-to-dismiss gesture.
    var isPasteSheetPresented = false

    /// Drives `.sheet(isPresented:)` for the post-pair nickname sheet.
    var isNicknameSheetPresented = false

    /// The nickname field's hint, and what Skip resolves to (§6.4).
    private(set) var nicknamePlaceholder = NicknameDraft.fallback

    /// Set once the whole flow is done and the screen should leave.
    ///
    /// A flag rather than a direct `navigator.popToRoot()` because this type
    /// knows nothing about navigation, and because onboarding step 3 consumes
    /// the same signal to advance its own page instead (§5.5).
    private(set) var didFinish = false

    // MARK: - Dependencies

    private var backend: (any PairingBackend)?
    private var gatekeeper: (any CameraGatekeeper)?

    /// §6.4's one-shot guard. See the type doc.
    private var didStartPostPairFlow = false

    // MARK: - Lifecycle

    init() {}

    /// Idempotent, per the `ScreenModel` contract: `.task` can run more than
    /// once for one view identity.
    func bind(backend: any PairingBackend, gatekeeper: any CameraGatekeeper) {
        guard self.backend == nil else { return }
        self.backend = backend
        self.gatekeeper = gatekeeper
    }

    /// Resolves the camera gate, prompting if authorisation is undetermined.
    ///
    /// Prompting from `activate()` matches the Flutter screen, where mounting
    /// `MobileScanner` triggers the TCC dialog. The alternative — a "Allow
    /// camera" button that then prompts — is a second tap for the 95% case and
    /// is not what the spec describes.
    ///
    /// Re-entrant: once the gate is resolved to anything but
    /// ``CameraGate/undetermined`` this returns immediately, so a scene
    /// re-activation does not re-prompt.
    func activate() async {
        guard let gatekeeper else { return }
        if camera != .undetermined { return }
        let current = await gatekeeper.currentGate()
        camera = current == .undetermined ? await gatekeeper.requestAccess() : current
    }

    func deactivate() {
        // Nothing long-lived to cancel: this screen has no streams. The camera
        // is owned by the view (it must be, the capture session is tied to a
        // layer) and is torn down by `QRScannerView.dismantleUIView`.
        //
        // Disarming here anyway means a payload cannot arrive from a capture
        // callback that fires while the screen is on its way out.
        isScannerArmed = false
    }

    // MARK: - Actions

    /// The **only** way a payload enters the flow (`_submitRaw`, §5.5).
    ///
    /// Order is load-bearing:
    ///
    /// 1. reject if this scan attempt is spent, or the flow is past scanning;
    /// 2. parse — an unparseable payload is handled per ``source`` and, for the
    ///    camera, leaves the scanner armed so it keeps looking;
    /// 3. disarm, so nothing else can submit;
    /// 4. enter `connecting` **before** the first `await`, so the viewfinder is
    ///    already showing "Connecting to …" while the socket opens.
    func submit(_ raw: String, from source: PairingSubmissionSource) async {
        guard isScannerArmed, state.acceptsSubmission else { return }

        guard let payload = PairingQRPayload.parse(raw) else {
            switch source {
            case .camera:
                // Silently ignore and keep scanning — a viewfinder pointed at
                // the world sees plenty of QRs that are not ours
                // (`qr_scanner.dart:45`). Note the scanner is NOT disarmed:
                // this is where Flutter's `_submitRaw` stops the camera for a
                // payload it then discards.
                return
            case .paste:
                // The paste path has no "keep looking". Dropping this in
                // silence is the entire screen failing to respond on a device
                // with no camera, which is every Simulator run.
                state = .failed(message: PairingErrorCopy.unrecognizedPaste, canRetry: true)
            }
            return
        }

        isScannerArmed = false
        state = .connecting(sessionName: payload.sessionName)

        guard let backend else {
            state = .failed(
                message: PairingBackendError.pairedMachineMissing.userMessage,
                canRetry: true
            )
            return
        }

        do {
            let machine = try await backend.pair(with: payload, raw: raw)
            state = .paired(machine)
            beginPostPairFlow(hostnameHint: machine.hostnameHint)
        } catch {
            state = .failed(
                message: PairingErrorCopy.message(for: error),
                canRetry: PairingErrorCopy.canRetry(after: error)
            )
        }
    }

    /// "Try again" from the error view (`pair_step.dart:225-230`): back to
    /// scanning, camera re-armed.
    func retry() {
        state = .scanning
        isScannerArmed = true
        // Reset the one-shot too. A second pairing attempt in the same screen
        // presentation is a second pairing and gets its own nickname sheet.
        didStartPostPairFlow = false
    }

    /// Opens the paste sheet. Refused while a pairing is in flight so the
    /// sheet cannot submit a second QR on top of the first.
    func openPasteSheet() {
        guard state.showsPasteEntryPoint else { return }
        isPasteSheetPresented = true
    }

    /// The paste sheet closed with text. Routes into the same path as a scan.
    func submitPasted(_ raw: String) async {
        isPasteSheetPresented = false
        await submit(raw, from: .paste)
    }

    /// Called from the nickname sheet's `onDismiss` with whatever the sheet
    /// produced (§6.4): a label from Save/Skip, or `nil` from a drag.
    ///
    /// A write failure is swallowed on purpose. The machine is already in the
    /// Mac's `peers.json` and the chat works; refusing to leave the pairing
    /// screen over a cosmetic label would strand the user on a screen whose
    /// only remaining action is to pair again.
    func completePostPair(with sheetResult: String?) async {
        isNicknameSheetPresented = false
        defer { didFinish = true }

        guard let nickname = NicknameDraft.resolve(sheetResult: sheetResult),
              var machine = state.pairedMachine
        else { return }

        try? await backend?.applyNickname(nickname, to: machine.peer)
        machine.nickname = nickname
        state = .paired(machine)
    }

    /// "Scan later" / the onboarding step's skip. Leaves zero peers; Home shows
    /// its first-pair empty state (§5.5).
    func abandon() {
        isScannerArmed = false
        didFinish = true
    }

    /// Lets a host screen consume ``didFinish`` and re-arm the model, rather
    /// than relying on the view being torn down. Onboarding step 3 needs this;
    /// `/pair` does not, because it pops.
    func acknowledgeFinish() {
        didFinish = false
    }

    // MARK: - Internals

    private func beginPostPairFlow(hostnameHint: String?) {
        // §6.4: fired once, guarded, because `PairingPaired` re-emits.
        guard !didStartPostPairFlow else { return }
        didStartPostPairFlow = true
        nicknamePlaceholder = NicknameDraft.placeholder(defaultName: hostnameHint)
        isNicknameSheetPresented = true
    }
}
