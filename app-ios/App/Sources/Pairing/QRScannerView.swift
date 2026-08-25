@preconcurrency import AVFoundation
import SwiftUI
import UIKit

/// The live QR viewfinder (spec 08 §6.2).
///
/// ## Why `AVCaptureMetadataOutput` and not Vision
///
/// `AVCaptureMetadataOutput` with `metadataObjectTypes = [.qr]` is the QR
/// detector that ships *inside* the capture pipeline: it runs on the capture
/// queue, is hardware-accelerated, and hands back a decoded `String`. Doing the
/// same job with Vision means adding `AVCaptureVideoDataOutput`, retaining
/// every `CMSampleBuffer`, and running a `VNDetectBarcodesRequest` per frame —
/// strictly more CPU, more code, and more objects crossing isolation
/// boundaries, for an identical result. Vision earns its place when you need
/// barcodes out of a *still image* (a screenshot from the photo library); it
/// does not earn it here. No third-party dependency either way — that is the
/// constraint this satisfies.
///
/// ## Concurrency
///
/// `AVCaptureSession.startRunning()` blocks — Apple's own documentation says
/// not to call it on the main thread — so it runs on a private serial queue.
/// AVFoundation predates `Sendable` and none of its capture types are
/// annotated, which is exactly the situation `@preconcurrency import` exists
/// for: it tells the compiler this module has not been audited, rather than
/// asserting a safety property with `@unchecked Sendable`. The safety argument
/// is real and narrow: the session is created and configured on the main actor
/// inside ``QRPreviewView``, and after that the only cross-thread traffic is
/// `startRunning`/`stopRunning` on one serial queue — both documented as
/// thread-safe — and metadata callbacks on a second queue that touch nothing
/// but a local `String`.
struct QRScannerView: UIViewRepresentable {
    /// Mirrors `PairingFlowModel.isScannerArmed`. `false` stops the capture
    /// session, which is the §5.5 disarm made visible: the preview freezes the
    /// instant a payload is accepted, so the user is not staring at a live
    /// camera that is ignoring them.
    let isArmed: Bool

    /// Delivered on the main actor, at most once per armed period.
    let onScan: (String) -> Void

    func makeUIView(context: Context) -> QRPreviewView {
        let view = QRPreviewView()
        view.onScan = onScan
        view.configure()
        return view
    }

    func updateUIView(_ uiView: QRPreviewView, context: Context) {
        uiView.onScan = onScan
        uiView.setArmed(isArmed)
    }

    static func dismantleUIView(_ uiView: QRPreviewView, coordinator: ()) {
        // The screen can be popped mid-scan. Without this the session keeps
        // running (and the camera indicator keeps burning) until ARC gets
        // around to the view.
        uiView.tearDown()
    }
}

/// A `UIView` whose backing layer *is* the preview layer.
///
/// Using `layerClass` rather than adding a sublayer means UIKit creates the
/// `AVCaptureVideoPreviewLayer` on the main thread as part of normal view
/// setup, and resizes it for us — no `layoutSubviews` frame bookkeeping, and no
/// layer handed across an isolation boundary.
final class QRPreviewView: UIView, AVCaptureMetadataOutputObjectsDelegate {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var onScan: ((String) -> Void)?

    private let session = AVCaptureSession()
    private let metadataOutput = AVCaptureMetadataOutput()
    private let sessionQueue = DispatchQueue(label: "work.jacobmoura.remotepi.qr.session")
    private let metadataQueue = DispatchQueue(label: "work.jacobmoura.remotepi.qr.metadata")

    private var isConfigured = false
    private var isArmed = true

    private var previewLayer: AVCaptureVideoPreviewLayer {
        // Safe by construction: `layerClass` above guarantees the type.
        layer as! AVCaptureVideoPreviewLayer
    }

    // MARK: - Setup

    func configure() {
        guard !isConfigured else { return }
        isConfigured = true

        backgroundColor = .black
        previewLayer.videoGravity = .resizeAspectFill

        session.beginConfiguration()
        session.sessionPreset = .high

        guard
            let device = AVCaptureDevice.default(for: .video),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input),
            session.canAddOutput(metadataOutput)
        else {
            // No camera, or the system refused it. The screen already renders
            // the `CameraGate` panel in that case; this view just stays black
            // instead of crashing on a force-unwrap.
            session.commitConfiguration()
            return
        }

        session.addInput(input)
        session.addOutput(metadataOutput)
        metadataOutput.setMetadataObjectsDelegate(self, queue: metadataQueue)
        // Set AFTER `addOutput`: the available types are empty until the output
        // is attached to a session, and assigning an unsupported type raises.
        metadataOutput.metadataObjectTypes = [.qr]
        session.commitConfiguration()

        previewLayer.session = session
        start()
    }

    func setArmed(_ armed: Bool) {
        guard isConfigured, armed != isArmed else { return }
        isArmed = armed
        if armed { start() } else { stop() }
    }

    func tearDown() {
        isArmed = false
        onScan = nil
        stop()
    }

    private func start() {
        sessionQueue.async { [session] in
            guard !session.isRunning else { return }
            session.startRunning()
        }
    }

    private func stop() {
        sessionQueue.async { [session] in
            guard session.isRunning else { return }
            session.stopRunning()
        }
    }

    // MARK: - AVCaptureMetadataOutputObjectsDelegate

    /// Called on ``metadataQueue``, several times a second while a QR is in
    /// frame. Only a `String` leaves this method.
    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        let value = metadataObjects
            .lazy
            .compactMap { $0 as? AVMetadataMachineReadableCodeObject }
            .compactMap(\.stringValue)
            .first { !$0.isEmpty }
        guard let value else { return }

        Task { @MainActor [weak self] in
            guard let self, self.isArmed else { return }
            // Do not disarm here. `PairingFlowModel.submit` decides whether
            // this payload is even ours — a wifi QR that wanders through frame
            // must leave the camera running (§6.3: "null -> silently ignore").
            self.onScan?(value)
        }
    }
}
