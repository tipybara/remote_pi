import Foundation
import Observation
import RemotePiProtocol
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif
#if canImport(PhotosUI)
import PhotosUI
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif

// ============================================================================
// Image attachment — spec 08 §8.10.
//
// One image, compressed on device, carried INLINE as standard base64 on the
// `user_message`. Nothing is uploaded out of band, so nothing here talks to a
// URL.
//
// Two traps the spec calls out by name:
//
// * `visionSupported` is **tri-state**. `nil` means "the model catalogue has
//   not told us yet" and must NOT gate the attach button; only a known `false`
//   greys it out. Gating on `nil` makes the paperclip dead on every cold start
//   and on every offline chat (`attachment_state.dart:16`).
//
// * The wire wants **standard** base64 with no `data:` prefix, and the whole
//   `images` key is omitted when empty — never `[]`, never `null` (spec §13.1,
//   §13.11). ``ComposerImage/wire`` and `UserMessage.init` between them make
//   that structural rather than a rule someone has to remember.
// ============================================================================

// MARK: - Value

/// A picked, compressed image held in memory until it rides a `user_message`.
///
/// Bytes are raw so the composer preview renders them without a decode of a
/// base64 string; base64 happens once, at the wire boundary.
struct ComposerImage: Equatable, Sendable {
    let data: Data
    let mime: String

    init(data: Data, mime: String = "image/jpeg") {
        self.data = data
        self.mime = mime
    }

    /// STANDARD base64 (`+/`, padded), no `data:` prefix. Base64URL here is
    /// the recurring bug of spec §13.1 — the Pi feeds this straight into an
    /// SDK image block and a URL-safe alphabet decodes to garbage.
    var wire: WireImage {
        WireImage(data: data.base64EncodedString(), mime: mime)
    }
}

enum AttachmentState: Equatable, Sendable {
    case empty
    /// A pick is in flight — the system sheet is up, or we are compressing.
    case picking
    case attached(ComposerImage)
}

enum AttachSource: Equatable, Sendable, Identifiable {
    case camera
    case gallery

    var id: Self { self }

    var label: String {
        switch self {
        case .camera: "Camera"
        case .gallery: "Photo Library"
        }
    }

    var symbol: String {
        switch self {
        case .camera: "camera"
        case .gallery: "photo"
        }
    }
}

/// One-shot hints for the host to surface (spec §8.10).
enum AttachHint: Equatable, Sendable {
    case cameraPermissionDenied
    case pickFailed
}

/// Thrown by a picker when the camera permission is off, so the model can tell
/// "denied" from "the pick failed" and show the Settings deep link.
struct ImagePermissionDenied: Error {}

// MARK: - Picker seam

@MainActor
protocol ImagePicking: AnyObject {
    /// Present the source and return the compressed image, or `nil` when the
    /// user cancelled. Throws ``ImagePermissionDenied`` or any failure.
    func pick(from source: AttachSource) async throws -> ComposerImage?
}

// MARK: - Compression policy

/// Longest side ≤ 1568px, JPEG q80, with an iterative ceiling.
///
/// Split out from the platform encoder so the loop — the part with an actual
/// bug surface — is unit-testable. The ceiling practically never fires; when
/// it does, it must terminate, which is what `maxExtraPasses` guarantees.
struct ImageCompressionPolicy: Equatable, Sendable {
    var maxSide = 1568
    var quality = 80
    var ceilingBytes = 1500 * 1024
    var maxExtraPasses = 3

    /// Runs the passes against an encoder that takes `(longest side, quality)`.
    /// Returns the last encoding produced — deliberately, not a failure: an
    /// image slightly over the ceiling is better than no attachment at all.
    func compress(using encode: (Int, Int) throws -> Data) rethrows -> Data {
        var side = maxSide
        var quality = self.quality
        var bytes = try encode(side, quality)
        var pass = 0
        while bytes.count > ceilingBytes, pass < maxExtraPasses {
            pass += 1
            quality = min(max(quality - 15, 35), 100)
            side = Int((Double(side) * 0.85).rounded())
            bytes = try encode(side, quality)
        }
        return bytes
    }
}

// MARK: - Model

@MainActor
@Observable
final class AttachmentModel {
    private(set) var state: AttachmentState = .empty

    /// Whether the active model accepts images. `nil` = not yet known.
    ///
    /// Fed from the model catalogue the quick-actions picker already fetches,
    /// re-resolved on every room-meta emit. Left `nil` when the catalogue is
    /// unavailable — see the file header.
    private(set) var visionSupported: Bool?

    var onHint: (@MainActor (AttachHint) -> Void)?

    /// Decoded once, at attach time. Recomputing it in a view body would
    /// re-decode the JPEG on every composer re-render — and the composer
    /// re-renders on every keystroke.
    private(set) var preview: Image?

    private let picker: any ImagePicking

    init(picker: any ImagePicking) {
        self.picker = picker
    }

    var hasImage: Bool {
        if case .attached = state { return true }
        return false
    }

    var isPicking: Bool { state == .picking }

    /// Gate the attach affordance only when we *know* the model is text-only.
    var attachBlockedByVision: Bool { visionSupported == false }

    var attached: ComposerImage? {
        if case .attached(let image) = state { return image }
        return nil
    }

    func applyVision(_ supported: Bool?) {
        guard supported != visionSupported else { return }
        visionSupported = supported
    }

    func pick(from source: AttachSource) async {
        guard state != .picking else { return }
        state = .picking
        do {
            guard let image = try await picker.pick(from: source) else {
                state = .empty  // cancelled
                return
            }
            preview = Self.decode(image)
            state = .attached(image)
        } catch is ImagePermissionDenied {
            state = .empty
            onHint?(.cameraPermissionDenied)
        } catch {
            state = .empty
            onHint?(.pickFailed)
        }
    }

    /// The "✕" on the preview.
    func removeImage() {
        guard hasImage else { return }
        state = .empty
        preview = nil
    }

    /// Hand the image to the send path and reset. Returns `nil` when nothing
    /// is attached, which is what makes an empty-caption send invalid.
    ///
    /// Reading and clearing in one call is deliberate: two calls would let a
    /// double-tapped send button ship the same image twice.
    func takeImageForSend() -> ComposerImage? {
        guard case .attached(let image) = state else { return nil }
        state = .empty
        preview = nil
        return image
    }

    /// Session switch: an image picked for one chat must never follow the user
    /// into another one.
    func reset() {
        state = .empty
        preview = nil
    }

    private static func decode(_ image: ComposerImage) -> Image? {
        #if canImport(UIKit)
        return UIImage(data: image.data).map(Image.init(uiImage:))
        #elseif canImport(AppKit)
        return NSImage(data: image.data).map(Image.init(nsImage:))
        #else
        return nil
        #endif
    }
}

// MARK: - Live picker

#if os(iOS)

/// Presents `UIImagePickerController` (camera) or `PHPickerViewController`
/// (library) over the key window and compresses the result.
///
/// UIKit lives here, in the adapter, and nowhere near ``AttachmentModel``.
@MainActor
final class SystemImagePicker: NSObject, ImagePicking {
    private var continuation: CheckedContinuation<ComposerImage?, Error>?
    private let policy = ImageCompressionPolicy()

    func pick(from source: AttachSource) async throws -> ComposerImage? {
        // Ask before presenting, exactly as the voice path does: a controller
        // that triggers its own prompt gives us no way to tell "denied" from
        // "cancelled", and the two need different copy.
        if source == .camera {
            try await requireCameraAccess()
        }
        guard let presenter = Self.topViewController() else { return nil }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            switch source {
            case .camera:
                let controller = UIImagePickerController()
                controller.sourceType = .camera
                controller.delegate = self
                presenter.present(controller, animated: true)
            case .gallery:
                var config = PHPickerConfiguration()
                config.filter = .images
                config.selectionLimit = 1
                let controller = PHPickerViewController(configuration: config)
                controller.delegate = self
                presenter.present(controller, animated: true)
            }
        }
    }

    private func requireCameraAccess() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                throw ImagePermissionDenied()
            }
        default:
            throw ImagePermissionDenied()
        }
    }

    fileprivate func finish(with image: UIImage?) {
        let continuation = self.continuation
        self.continuation = nil
        guard let continuation else { return }
        guard let image else {
            continuation.resume(returning: nil)
            return
        }
        do {
            let data = try policy.compress { side, quality in
                guard let encoded = Self.encode(image, maxSide: side, quality: quality) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                return encoded
            }
            continuation.resume(returning: ComposerImage(data: data, mime: "image/jpeg"))
        } catch {
            continuation.resume(throwing: error)
        }
    }

    fileprivate func fail(_ error: Error) {
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(throwing: error)
    }

    private static func encode(_ image: UIImage, maxSide: Int, quality: Int) -> Data? {
        let longest = max(image.size.width, image.size.height)
        let scale = longest > CGFloat(maxSide) ? CGFloat(maxSide) / longest : 1
        let target = CGSize(
            width: (image.size.width * scale).rounded(),
            height: (image.size.height * scale).rounded()
        )
        let renderer = UIGraphicsImageRenderer(size: target)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: CGFloat(quality) / 100)
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}

extension SystemImagePicker: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    func imagePickerController(
        _ picker: UIImagePickerController,
        didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
        picker.dismiss(animated: true)
        finish(with: info[.originalImage] as? UIImage)
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
        finish(with: nil)
    }
}

extension SystemImagePicker: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider,
              provider.canLoadObject(ofClass: UIImage.self)
        else {
            finish(with: nil)
            return
        }
        // `[weak self]` on the OUTER closure as well: this one escapes into
        // the provider, so without it the picker is kept alive until the load
        // finishes and the inner `[weak self]` never observes a release.
        provider.loadObject(ofClass: UIImage.self) { [weak self] object, error in
            // The provider calls back off the main actor and hands us a
            // non-Sendable UIImage; hop with the pixels, not with the callback.
            let image = object as? UIImage
            Task { @MainActor [weak self] in
                if let error, image == nil {
                    self?.fail(error)
                } else {
                    self?.finish(with: image)
                }
            }
        }
    }
}

#endif

/// The picker used where there is no photo stack (the macOS unit-test host):
/// every pick reads as a cancel.
@MainActor
final class UnavailableImagePicker: ImagePicking {
    init() {}
    func pick(from source: AttachSource) async throws -> ComposerImage? { nil }
}

@MainActor
func makeSystemImagePicker() -> any ImagePicking {
    #if os(iOS)
    SystemImagePicker()
    #else
    UnavailableImagePicker()
    #endif
}

// MARK: - Views

/// The attach sheet: exactly two rows (spec §8.10).
///
/// The caller is responsible for `.dismissOnSessionChange(selection)` — the
/// modifier belongs to the presenter, not to the content, and forgetting it
/// leaves this sheet hovering over a different chat on tablet (§11.2).
struct AttachSheet: View {
    let onPick: (AttachSource) -> Void

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(theme.colors.border)
                .frame(width: 36, height: 4)
                .padding(.top, 12)
                .padding(.bottom, 12)
            ForEach([AttachSource.camera, .gallery]) { source in
                Button {
                    dismiss()
                    onPick(source)
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: source.symbol)
                            .font(.system(size: 20))
                            .foregroundStyle(theme.colors.accent)
                            .frame(width: 24)
                        Text(source.label)
                            .font(theme.type.mono(14))
                            .foregroundStyle(theme.colors.text)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("attach-\(source == .camera ? "camera" : "gallery")")
            }
            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity)
        .background(theme.colors.bg)
    }
}

/// The composer's image preview: a 72pt thumbnail with an "✕" to discard
/// before sending. No tap, no zoom — the same deliberate omission as
/// `ImageBubble` (spec §8.5, plan 30 decision #7).
struct AttachmentPreview: View {
    let image: Image?
    let onRemove: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    // A decode failure renders a placeholder rather than
                    // throwing away the attachment — the bytes are still valid
                    // on the wire even when UIImage will not draw them.
                    Image(systemName: "photo")
                        .font(.system(size: 24))
                        .foregroundStyle(theme.colors.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(theme.colors.codeBg)
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(theme.colors.text)
                    .padding(5)
                    .background(Circle().fill(Color.black.opacity(0.75)))
                    .overlay(Circle().stroke(theme.colors.border, lineWidth: AppMetrics.hairline))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove attached image")
            .accessibilityIdentifier("attach-remove")
            .offset(x: 6, y: -6)
        }
        .frame(width: 84, height: 84, alignment: .topLeading)
        .padding(.leading, 4)
        .padding(.bottom, 10)
        .accessibilityIdentifier("attach-preview")
    }
}
