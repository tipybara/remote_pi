import Foundation
import RemotePiProtocol

// ============================================================================
// The pairing screen's state vocabulary (spec 08 §6.1).
//
// This file — and every other file in `Pairing/` whose name does not end in
// `+AppModel` or contain a SwiftUI `View` — imports neither SwiftUI nor
// `AppModel`. That is deliberate: the whole state machine is compilable and
// testable on its own (see `App/Tests/pairing/`), which is the only way the
// rules in §6.3–§6.5 get exercised without a simulator and a live Mac.
// ============================================================================

/// What one successful pairing left behind, as the screen needs it.
///
/// Deliberately *not* `PairingOutcome`: the screen needs a machine id (to write
/// a nickname against) and the hostname hint (to pre-fill the sheet), and
/// nothing else. Carrying the whole `pair_ok` here would invite a screen to
/// start reading `room_id` and re-deriving identity, which is what plan 61
/// exists to stop.
struct PairedMachine: Equatable, Sendable {
    /// The machine's Ed25519 key as 32 raw bytes. `PeerID` has no Base64
    /// spelling to normalise (spec 08 §13.1) — that is why it is the key.
    let peer: PeerID

    /// `pair_ok.hostname`, e.g. "Mac do Jacob". `nil` on a legacy Pi, in which
    /// case the nickname sheet falls back to the literal "Pi" (§6.4).
    let hostnameHint: String?

    /// The label the user picked in the post-pair sheet, once they have.
    ///
    /// The Flutter `PairingPaired.==` compares only `(remoteEpk, hostnameHint)`
    /// so that re-emitting the state after `applyNickname` reads as "the same
    /// pairing". We keep the synthesised `==` — including `nickname` — and use
    /// an explicit one-shot guard (`PairingFlowModel.didStartPostPairFlow`)
    /// instead. A type whose `==` silently ignores a stored property is a trap
    /// for the next reader; a boolean named after what it guards is not.
    var nickname: String?
}

/// The screen's state (`pairing_state.dart`).
///
/// `idle` exists only because §5.5's onboarding step renders an empty body for
/// it before the camera is armed; the standalone `/pair` screen starts at
/// ``scanning``, exactly as `PairingViewModel`'s initial state does.
enum PairingFlowState: Equatable, Sendable {
    case idle
    case scanning
    /// A QR was accepted and `pair_request` is in flight. `sessionName` comes
    /// from the QR's `n`, not from the Pi — it is the only label available
    /// before `pair_ok` lands, and it is display-only.
    case connecting(sessionName: String)
    case paired(PairedMachine)
    case failed(message: String, canRetry: Bool)

    /// `true` while a QR may be handed in.
    ///
    /// Mirrors `pairing_viewmodel.dart:48` (`if (state is PairingConnecting) return`)
    /// but widened: once we are `paired` or `failed` the camera is stopped and
    /// a late frame from the capture pipeline must not restart a pairing.
    var acceptsSubmission: Bool {
        switch self {
        case .idle, .scanning: true
        case .connecting, .paired, .failed: false
        }
    }

    /// Whether the "Can't scan? Paste code instead" affordance is on screen.
    /// §5.5: shown "only while `Scanning`/`Idle`".
    var showsPasteEntryPoint: Bool {
        switch self {
        case .idle, .scanning: true
        case .connecting, .paired, .failed: false
        }
    }

    var connectingSessionName: String? {
        if case .connecting(let name) = self { return name }
        return nil
    }

    var pairedMachine: PairedMachine? {
        if case .paired(let machine) = self { return machine }
        return nil
    }
}

/// Where a raw payload came from. The two sources must not be handled
/// identically — see ``PairingFlowModel/submit(_:from:)``.
enum PairingSubmissionSource: Equatable, Sendable {
    /// A frame off the camera. Garbage is common (a wifi QR, a URL on a
    /// poster) and must be dropped in silence so scanning continues.
    case camera
    /// The paste sheet. The user typed exactly one thing on purpose; dropping
    /// it in silence closes the sheet and does nothing, which on a device with
    /// no camera is the entire screen failing to respond.
    case paste
}

/// Whether the camera can be used at all (spec: "the empty, error and offline
/// states are the ones users actually hit").
///
/// Four states, because they need four different bodies: a spinner, a
/// viewfinder, a "you said no, here is how to change that" panel, and a
/// "there is no camera here" panel. The last one is not hypothetical — it is
/// every run on the Simulator, which is how this screen is tested.
enum CameraGate: Equatable, Sendable {
    /// Not asked yet. Renders as the viewfinder's placeholder, never as an
    /// error: a permission prompt is about to cover the screen anyway.
    case undetermined
    case ready
    /// Denied by the user, or blocked by a parental/MDM restriction. Both
    /// resolve the same way — Settings — so they share a case and differ only
    /// in copy.
    case denied(restricted: Bool)
    /// No usable capture device. The Simulator, and a device whose camera the
    /// system refused to hand over.
    case unavailable(reason: String)

    var showsViewfinder: Bool { self == .ready }

    /// `true` when the only way forward is the paste sheet, so the screen
    /// promotes it from a text button to the primary action.
    var requiresPasteFallback: Bool {
        switch self {
        case .ready, .undetermined: false
        case .denied, .unavailable: true
        }
    }
}

/// Asks for, and reports, camera authorisation.
///
/// A protocol so the model can be driven in a test process that has no
/// AVFoundation session and no TCC prompt. The real implementation is
/// `AVCameraGatekeeper` in `PairingFlowModel+AppModel.swift`.
protocol CameraGatekeeper: Sendable {
    /// The gate as it stands, without prompting.
    func currentGate() async -> CameraGate
    /// Prompts if and only if authorisation is still undetermined.
    func requestAccess() async -> CameraGate
}
