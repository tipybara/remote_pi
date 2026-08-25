import Foundation
import RemotePiPairing
import RemotePiProtocol
import Testing
@testable import RemotePi

@MainActor
@Suite("Pairing flow — submit path (spec 08 §6.3, §5.5)")
struct PairingFlowSubmitTests {
    @Test("The initial state is scanning with an armed camera")
    func initialState() {
        let (model, _) = makeModel()
        #expect(model.state == .scanning)
        #expect(model.isScannerArmed)
        #expect(model.state.showsPasteEntryPoint)
    }

    @Test("A camera frame that is not a pairing QR is ignored and the camera keeps scanning")
    func cameraGarbageKeepsScanning() async {
        let (model, backend) = makeModel()
        await model.submit("https://example.com/not-a-pairing-code", from: .camera)

        #expect(model.state == .scanning)
        // The bug we are NOT reproducing: `pair_step.dart:52-58` disarms the
        // scanner before the payload is validated, so one stray QR in frame
        // freezes the camera for good.
        #expect(model.isScannerArmed)
        #expect(backend.pairedPayloads.isEmpty)
    }

    @Test("A paste that is not a pairing code says so instead of silently doing nothing")
    func pasteGarbageSurfacesAnError() async {
        let (model, backend) = makeModel()
        await model.submit("hello", from: .paste)

        #expect(model.state == .failed(message: PairingErrorCopy.unrecognizedPaste, canRetry: true))
        #expect(backend.pairedPayloads.isEmpty)
    }

    @Test("A valid QR pairs, disarms the scanner and opens the nickname sheet")
    func happyPath() async {
        let (model, backend) = makeModel()
        backend.pairResult = .success(PairingFixtures.machine())

        await model.submit(PairingFixtures.qr(), from: .camera)

        #expect(model.state == .paired(PairingFixtures.machine()))
        #expect(!model.isScannerArmed)
        #expect(model.isNicknameSheetPresented)
        // §6.4: the field hints with `pair_ok.hostname`.
        #expect(model.nicknamePlaceholder == "studio.local")
        #expect(backend.pairedPayloads.count == 1)
        #expect(backend.pairedPayloads[0].peer == PairingFixtures.machineKey)
        #expect(backend.pairedPayloads[0].sessionName == "remote_pi · main")
    }

    @Test("Connecting carries the QR's session name before pair_ok arrives")
    func connectingShowsSessionName() async {
        let (model, backend) = makeModel()
        backend.pairResult = .success(PairingFixtures.machine())
        backend.holdPairing()

        let submission = Task { await model.submit(PairingFixtures.qr(name: "my project"), from: .camera) }
        // Let the model reach its first suspension point.
        await Task.yield()
        await Task.yield()

        #expect(model.state == .connecting(sessionName: "my project"))
        #expect(!model.state.showsPasteEntryPoint)
        #expect(!model.isScannerArmed)

        backend.releasePairing()
        await submission.value
        #expect(model.state.pairedMachine != nil)
    }

    @Test("A second payload arriving while a pairing is in flight is dropped")
    func secondSubmissionIgnored() async {
        let (model, backend) = makeModel()
        backend.pairResult = .success(PairingFixtures.machine())
        backend.holdPairing()

        let first = Task { await model.submit(PairingFixtures.qr(), from: .camera) }
        await Task.yield()
        await Task.yield()

        await model.submit(PairingFixtures.qr(peer: PairingFixtures.otherMachineKey), from: .camera)
        await model.submit(PairingFixtures.qr(peer: PairingFixtures.otherMachineKey), from: .paste)

        backend.releasePairing()
        await first.value

        #expect(backend.pairedPayloads.count == 1)
        #expect(backend.pairedPayloads[0].peer == PairingFixtures.machineKey)
    }

    @Test("Nothing is submitted once the flow has paired")
    func lateFrameAfterPairingIgnored() async {
        let (model, backend) = makeModel()
        backend.pairResult = .success(PairingFixtures.machine())
        await model.submit(PairingFixtures.qr(), from: .camera)

        await model.submit(PairingFixtures.qr(), from: .camera)
        #expect(backend.pairedPayloads.count == 1)
    }

    @Test("deactivate disarms, so a capture callback in flight cannot start a pairing")
    func deactivateDisarms() async {
        let (model, backend) = makeModel()
        model.deactivate()
        await model.submit(PairingFixtures.qr(), from: .camera)
        #expect(backend.pairedPayloads.isEmpty)
    }
}

@MainActor
@Suite("Pairing flow — failures (spec 08 §6.3)")
struct PairingFlowFailureTests {
    private func failing(with error: any Error) async -> PairingFlowModel {
        let (model, backend) = makeModel()
        backend.pairResult = .failure(error)
        await model.submit(PairingFixtures.qr(), from: .camera)
        return model
    }

    @Test("A pair_error code maps to its verbatim copy")
    func wireCodeCopy() async {
        let model = await failing(
            with: PairFailure.wire(code: .tokenExpired, message: "token expired")
        )
        #expect(model.state == .failed(message: PairingErrorCopy.tokenExpired, canRetry: true))
        // The error body replaces the scanner, so the paste hint is not drawn
        // over it — the error view offers its own paste route instead.
        #expect(!model.state.showsPasteEntryPoint)
    }

    @Test("A timeout maps to the pair_timeout copy even though it is not a wire code")
    func timeoutCopy() async {
        let model = await failing(with: PairFailure.timedOut)
        #expect(model.state == .failed(message: PairingErrorCopy.timedOut, canRetry: true))
    }

    @Test("A relay-less backend failure still produces a screen that says something")
    func backendStringFailure() async {
        let model = await failing(with: PairingBackendError.reported("relay refused the handshake"))
        #expect(model.state == .failed(message: "relay refused the handshake", canRetry: true))
    }

    @Test("A silent backend no-op is still an error, not a stuck spinner")
    func silentBackendFailure() async {
        let model = await failing(with: PairingBackendError.pairedMachineMissing)
        #expect(model.state == .failed(message: "Pairing didn't complete — try again", canRetry: true))
    }

    @Test("Retry returns to a live scanner")
    func retryRearms() async {
        let (model, backend) = makeModel()
        backend.pairResult = .failure(PairFailure.timedOut)
        await model.submit(PairingFixtures.qr(), from: .camera)

        model.retry()
        #expect(model.state == .scanning)
        #expect(model.isScannerArmed)

        // …and a retry genuinely pairs, rather than being swallowed by a stale
        // one-shot guard.
        backend.pairResult = .success(PairingFixtures.machine())
        await model.submit(PairingFixtures.qr(), from: .camera)
        #expect(model.state.pairedMachine != nil)
        #expect(model.isNicknameSheetPresented)
    }
}

@MainActor
@Suite("Pairing flow — post-pair nickname (spec 08 §6.4)")
struct PairingFlowNicknameTests {
    private func paired(
        hostnameHint: String? = "studio.local"
    ) async -> (PairingFlowModel, FakePairingBackend) {
        let (model, backend) = makeModel()
        backend.pairResult = .success(PairingFixtures.machine(hostnameHint: hostnameHint))
        await model.submit(PairingFixtures.qr(), from: .camera)
        return (model, backend)
    }

    @Test("Save persists the typed label and finishes")
    func savePersists() async {
        let (model, backend) = await paired()
        await model.completePostPair(with: "Studio Mac")

        #expect(backend.nicknames.count == 1)
        #expect(backend.nicknames[0].name == "Studio Mac")
        #expect(backend.nicknames[0].peer == PairingFixtures.machineKey)
        #expect(model.state.pairedMachine?.nickname == "Studio Mac")
        #expect(model.didFinish)
        #expect(!model.isNicknameSheetPresented)
    }

    @Test("Skip persists the placeholder — a drag-dismiss persists nothing")
    func skipVersusDrag() async {
        // Skip: the sheet returns the placeholder, which IS written.
        let (skipped, skipBackend) = await paired()
        await skipped.completePostPair(with: NicknameDraft.skip(placeholder: skipped.nicknamePlaceholder))
        #expect(skipBackend.nicknames.map(\.name) == ["studio.local"])
        #expect(skipped.didFinish)

        // Drag: the sheet returns nil, and nothing is written. This asymmetry
        // is the contract, not an oversight (§6.4).
        let (dragged, dragBackend) = await paired()
        await dragged.completePostPair(with: nil)
        #expect(dragBackend.nicknames.isEmpty)
        #expect(dragged.state.pairedMachine?.nickname == nil)
        #expect(dragged.didFinish)
    }

    @Test("A whitespace-only result is treated as no nickname")
    func whitespaceIsNotALabel() async {
        let (model, backend) = await paired()
        await model.completePostPair(with: "   \n ")
        #expect(backend.nicknames.isEmpty)
        #expect(model.didFinish)
    }

    @Test("The nickname sheet opens exactly once, even though the paired state re-emits")
    func sheetOpensOnce() async {
        let (model, _) = await paired()
        #expect(model.isNicknameSheetPresented)

        // `completePostPair` re-assigns `.paired(machine)` with the nickname
        // attached — Flutter's `applyNickname` re-emit. An unguarded observer
        // re-opens the sheet here (§6.4).
        await model.completePostPair(with: "Studio Mac")
        #expect(!model.isNicknameSheetPresented)
    }

    @Test("A failed nickname write does not strand the user on the pairing screen")
    func nicknameWriteFailureStillFinishes() async {
        let (model, backend) = await paired()
        backend.nicknameError = PairingBackendError.reported("SQLITE_BUSY")
        await model.completePostPair(with: "Studio Mac")
        #expect(model.didFinish)
        #expect(model.state.pairedMachine != nil)
    }

    @Test("A legacy Pi with no hostname falls back to the literal Pi")
    func legacyPiPlaceholder() async {
        let (model, backend) = await paired(hostnameHint: nil)
        #expect(model.nicknamePlaceholder == "Pi")
        await model.completePostPair(with: NicknameDraft.skip(placeholder: model.nicknamePlaceholder))
        #expect(backend.nicknames.map(\.name) == ["Pi"])
    }
}

@MainActor
@Suite("Pairing flow — paste sheet and the camera gate (spec 08 §6.5)")
struct PairingFlowCameraTests {
    @Test("The paste sheet routes into the same submit path as a scan")
    func pasteSheetSubmits() async {
        let (model, backend) = makeModel(camera: .unavailable(reason: "no camera"))
        backend.pairResult = .success(PairingFixtures.machine())

        model.openPasteSheet()
        #expect(model.isPasteSheetPresented)

        await model.submitPasted(PairingFixtures.qr())
        #expect(!model.isPasteSheetPresented)
        #expect(backend.pairedPayloads.count == 1)
        #expect(model.state.pairedMachine != nil)
    }

    @Test("The paste sheet cannot be opened on top of a pairing in flight")
    func pasteSheetRefusedWhileConnecting() async {
        let (model, backend) = makeModel()
        backend.pairResult = .success(PairingFixtures.machine())
        backend.holdPairing()

        let submission = Task { await model.submit(PairingFixtures.qr(), from: .camera) }
        await Task.yield()
        await Task.yield()

        model.openPasteSheet()
        #expect(!model.isPasteSheetPresented)

        backend.releasePairing()
        await submission.value
    }

    @Test("An undetermined camera prompts exactly once")
    func promptsOnce() async {
        let model = PairingFlowModel()
        let gate = FakeCameraGatekeeper(initial: .undetermined, granted: .ready)
        model.bind(backend: FakePairingBackend(), gatekeeper: gate)

        await model.activate()
        await model.activate()

        #expect(model.camera == .ready)
        #expect(await gate.requestCount == 1)
    }

    @Test("A denied camera is never re-prompted, and demands the paste fallback")
    func deniedNeverReprompts() async {
        let model = PairingFlowModel()
        let gate = FakeCameraGatekeeper(initial: .denied(restricted: false))
        model.bind(backend: FakePairingBackend(), gatekeeper: gate)

        await model.activate()

        #expect(model.camera == .denied(restricted: false))
        #expect(await gate.requestCount == 0)
        #expect(model.camera.requiresPasteFallback)
        #expect(!model.camera.showsViewfinder)
    }

    @Test("A device with no camera reports unavailable, not denied")
    func simulatorIsUnavailableNotDenied() async {
        let model = PairingFlowModel()
        // What `AVCameraGatekeeper` produces on the Simulator: it checks device
        // availability BEFORE authorisation, so the user is never told to fix a
        // Settings toggle for a camera that does not exist.
        let gate = FakeCameraGatekeeper(initial: .unavailable(reason: "no camera"))
        model.bind(backend: FakePairingBackend(), gatekeeper: gate)

        await model.activate()
        #expect(model.camera == .unavailable(reason: "no camera"))
        #expect(model.camera.requiresPasteFallback)
        #expect(await gate.requestCount == 0)
    }

    @Test("Scan later finishes without pairing")
    func abandon() {
        let (model, backend) = makeModel()
        model.abandon()
        #expect(model.didFinish)
        #expect(!model.isScannerArmed)
        #expect(backend.pairedPayloads.isEmpty)
    }

    @Test("acknowledgeFinish lets a host screen re-arm the finish signal")
    func acknowledgeFinish() {
        let (model, _) = makeModel()
        model.abandon()
        #expect(model.didFinish)
        model.acknowledgeFinish()
        #expect(!model.didFinish)
    }
}
