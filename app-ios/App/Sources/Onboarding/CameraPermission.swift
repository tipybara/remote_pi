import AVFoundation

/// Camera gating for the pair step's viewfinder.
///
/// Split from the model so the decision table is one pure function that can be
/// read (and tested) without a device, and so the model never imports
/// AVFoundation.
enum CameraPermission {

    // MARK: - Copy
    //
    // Every one of these ends by pointing at the paste path. A user who cannot
    // use the camera must never be looking at a dead screen — the QR payload is
    // plain text and pasting it is a first-class way to pair, not a workaround.

    static let noDeviceReason =
        "This device has no camera. Use \"Paste code instead\" below."
    static let deniedReason =
        "Camera access is off. Turn it on in Settings › Remote Pi › Camera, "
        + "or paste the code instead."
    static let restrictedReason =
        "Camera access is restricted on this device. Paste the code instead."

    /// The pure decision. `status` is the AVFoundation authorization status
    /// **after** any prompt has been answered.
    static func decide(
        status: AVAuthorizationStatus,
        hasCaptureDevice: Bool
    ) -> CameraAvailability {
        // Order matters: a simulator reports `.authorized` and still has no
        // back camera, so the device check has to come first or the viewfinder
        // renders as a black rectangle with no explanation.
        guard hasCaptureDevice else { return .unavailable(reason: noDeviceReason) }
        switch status {
        case .authorized: return .available
        case .denied: return .unavailable(reason: deniedReason)
        case .restricted: return .unavailable(reason: restrictedReason)
        case .notDetermined: return .unavailable(reason: deniedReason)
        @unknown default: return .unavailable(reason: deniedReason)
        }
    }

    /// Queries, prompting once if the user has not been asked yet.
    static func resolve() async -> CameraAvailability {
        let hasDevice = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .back
        ) != nil
        var status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined, hasDevice {
            // Prompt only when there is a camera to authorise; asking on a
            // device that has none burns the one-shot prompt for nothing.
            _ = await AVCaptureDevice.requestAccess(for: .video)
            status = AVCaptureDevice.authorizationStatus(for: .video)
        }
        return decide(status: status, hasCaptureDevice: hasDevice)
    }
}
