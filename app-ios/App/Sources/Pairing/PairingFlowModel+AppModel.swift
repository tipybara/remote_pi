import AVFoundation
import Foundation
import RemotePiPairing
import RemotePiProtocol
import RemotePiStore
import SwiftUI

// ============================================================================
// The app-target half of the pairing screen: `ScreenModel` conformance, the
// real backend, the real camera gate. Everything here needs `AppModel` or a
// system framework, which is exactly why it is not in `PairingFlowModel.swift`.
// ============================================================================

extension PairingFlowModel: ScreenModel {
    func bind(to app: AppModel) {
        bind(backend: AppModelPairingBackend(app: app), gatekeeper: AVCameraGatekeeper())
    }
}

/// Drives a pairing through `AppModel`, which owns the store, the key store,
/// the peer directory and the live socket — none of which a screen may touch.
///
/// ## What this adapter is working around
///
/// `AppModel.pair(pasted:)` returns `Void` and reports failure by assigning
/// `lastError`, so the typed `PairFailure` that `PairingCoordinator` threw is
/// gone by the time we could read it. That is why ``PairingBackendError`` and
/// the string round-trip below exist.
///
/// The fix is one method on `AppModel` (requested in this task's report):
///
/// ```swift
/// func pairDetailed(_ payload: PairingQRPayload) async throws -> PairingOutcome
/// ```
///
/// rethrowing `PairFailure` unchanged. When it lands, ``pair(with:raw:)``
/// becomes three lines and §6.3's copy table starts working for the wire codes
/// as well as for the local failures — with no change to `PairingFlowModel`,
/// ``PairingErrorCopy``, or any view.
@MainActor
final class AppModelPairingBackend: PairingBackend {
    private let app: AppModel

    init(app: AppModel) {
        self.app = app
    }

    func pair(with payload: PairingQRPayload, raw: String) async throws -> PairedMachine {
        // Clear first so a stale error from an earlier screen cannot be read
        // back as this pairing's failure. `AppModel.pair` also clears it, but
        // only *after* its own parse step, and we would rather not depend on
        // the ordering inside a method we do not own.
        app.lastError = nil

        // The handshake itself: `AppModel.pair` builds a `PairingCoordinator`
        // with the app's key store, peer directory and mesh publisher and runs
        // `pairDetailed`. Nothing about `pair_request`/`pair_ok` is reproduced
        // here — see `Sources/RemotePiPairing/PairingCoordinator.swift`.
        await app.pair(pasted: raw)

        if let message = app.lastError {
            throw PairingBackendError.reported(message)
        }

        // Identity check, not a convenience lookup: `AppModel.pair` reloads the
        // whole peer list, and taking `peers.first` would happily return some
        // *other* machine that was already paired. The QR's `PeerID` is 32 raw
        // bytes, so this comparison has no Base64 spelling to get wrong
        // (spec 08 §13.1).
        guard let record = app.peers.first(where: { $0.peer == payload.peer }) else {
            throw PairingBackendError.pairedMachineMissing
        }

        return PairedMachine(
            peer: record.peer,
            // `pair_ok.hostname`, persisted onto the record by the coordinator.
            hostnameHint: record.hostname,
            nickname: record.nickname
        )
    }

    func applyNickname(_ nickname: String, to peer: PeerID) async throws {
        await app.setNickname(nickname, for: peer)
    }
}

/// (`PeerNicknameWriter` lived here. It opened a *second* `SQLiteSessionStore`
/// handle because `AppModel` owned its store privately and exposed no way to
/// update a `PeerRecord`, which meant the write landed in the database but
/// `AppModel`'s in-memory `peers` kept the old label until the next launch —
/// Home showed the hostname rather than the nickname for the rest of the
/// session. `AppModel.setNickname(_:for:)` replaced it; see
/// `AppModel+Screens.swift`.)

/// The real camera gate.
///
/// Device availability is checked **before** authorisation, because the two
/// answers are not independent: the Simulator reports `.notDetermined` and then
/// denies the request, which would render as "you declined the camera" on a
/// machine that has no camera to decline. Users of that screen would be told to
/// go fix a Settings toggle that does not exist.
struct AVCameraGatekeeper: CameraGatekeeper {
    func currentGate() async -> CameraGate {
        guard Self.hasCaptureDevice else {
            return .unavailable(reason: "This device has no camera available to Remote Pi.")
        }
        return Self.gate(for: AVCaptureDevice.authorizationStatus(for: .video))
    }

    func requestAccess() async -> CameraGate {
        guard Self.hasCaptureDevice else {
            return .unavailable(reason: "This device has no camera available to Remote Pi.")
        }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined else {
            return await currentGate()
        }
        // Prompts exactly once per install; the answer is remembered by the
        // system, which is why `PairingFlowModel.activate` never asks twice.
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        return granted ? .ready : .denied(restricted: false)
    }

    private static var hasCaptureDevice: Bool {
        // Front and back, any modern camera type: an iPad's only usable camera
        // for this is the front one, and a QR held up to it works fine.
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInDualCamera, .builtInTripleCamera],
            mediaType: .video,
            position: .unspecified
        )
        return !discovery.devices.isEmpty
    }

    private static func gate(for status: AVAuthorizationStatus) -> CameraGate {
        switch status {
        case .authorized: .ready
        case .notDetermined: .undetermined
        case .denied: .denied(restricted: false)
        // Parental controls or an MDM profile. The user cannot grant it from
        // Settings, so the copy must not tell them to try.
        case .restricted: .denied(restricted: true)
        @unknown default: .denied(restricted: false)
        }
    }
}
