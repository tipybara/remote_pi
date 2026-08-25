import SwiftUI

/// `/pair` — the QR pairing screen (spec 08 §6).
///
/// Full-bleed camera behind a 268×268 rounded viewfinder with corner brackets,
/// the hint at the bottom, and the paste sheet one tap away. Presented as a
/// full-screen push in both size classes: it owns the camera and must not share
/// the screen with a chat (`AppNavigator.openPairing`).
///
/// The body is a `switch` over ``PairingFlowState`` and ``CameraGate`` and
/// nothing else — every decision above it belongs to ``PairingFlowModel``.
struct PairingFlowScreen: View {
    /// What to do when the flow finishes. `/pair` pops to Home; onboarding
    /// step 3 advances its own page instead (§5.5), which is why this is a
    /// closure rather than a `navigator` call inside the body.
    var onFinish: () -> Void

    @State private var model = PairingFlowModel()
    @State private var nicknameResult: String?
    @State private var pastedPayload: String?

    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            // Black rather than `colors.bg`: this screen is mostly video, and
            // a themed backdrop showing through the letterboxing of a
            // `resizeAspectFill` preview reads as a rendering glitch.
            Color.black.ignoresSafeArea()
            body(for: model.state)
        }
        .navigationTitle("Pair device")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $model.isPasteSheetPresented, onDismiss: submitPastedIfAny) {
            PasteQRSheet(submitted: $pastedPayload)
                // Sized to the content rather than `.medium`: the sheet is a
                // title, a 3-line field and two buttons, and a half-screen
                // detent puts the Pair button under the keyboard.
                .presentationDetents([.height(420), .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $model.isNicknameSheetPresented, onDismiss: completePostPair) {
            NicknameSheet(placeholder: model.nicknamePlaceholder, result: $nicknameResult)
                .presentationDetents([.height(340)])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: model.didFinish) { _, finished in
            guard finished else { return }
            model.acknowledgeFinish()
            onFinish()
        }
        .screenModel(model)
    }

    // MARK: - Bodies

    @ViewBuilder
    private func body(for state: PairingFlowState) -> some View {
        switch state {
        case .idle, .scanning, .connecting:
            // The camera gate wins over the scanning body: there is no point
            // drawing a viewfinder over a camera that will never produce a
            // frame. `connecting` is exempt — it renders the same darkened
            // frame either way, and on a camera-less device that is the only
            // progress indicator the paste path has.
            if model.camera.requiresPasteFallback, state.connectingSessionName == nil {
                cameraBlockedBody
            } else {
                scannerBody(isConnecting: state.connectingSessionName)
            }

        case .paired:
            // A brief spinner between `pair_ok` and the nickname sheet's
            // presentation animation, matching `pairing_page.dart:105-107`.
            ProgressView()
                .controlSize(.large)
                .tint(theme.colors.accent)

        case .failed(let message, let canRetry):
            errorBody(message: message, canRetry: canRetry)
        }
    }

    /// §6.2. `isConnecting` carries the session name from the QR's `n`.
    private func scannerBody(isConnecting sessionName: String?) -> some View {
        let connecting = sessionName != nil

        return ZStack(alignment: .bottom) {
            if !connecting, model.camera.showsViewfinder {
                QRScannerView(isArmed: model.isScannerArmed) { raw in
                    Task { await model.submit(raw, from: .camera) }
                }
                .ignoresSafeArea()
            }

            viewfinder(connecting: connecting)

            // White, not a theme token: this text sits on live video, where
            // the theme's `text` colour would be invisible half the time.
            Text(
                connecting
                    ? "Connecting to \(sessionName ?? "")…"
                    : "Point camera at the QR shown in your Mac terminal"
            )
            .font(theme.type.sans(14))
            .foregroundStyle(Color.white.opacity(0.7))
            .multilineTextAlignment(.center)
            .shadow(radius: 6)
            .padding(.horizontal, 24)
            .padding(.bottom, connecting ? 48 : 110)

            if !connecting {
                pasteEntryButton
                    .padding(.horizontal, 32)
                    .padding(.bottom, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The 268×268 frame, radius 24, with corner brackets (§6.2).
    private func viewfinder(connecting: Bool) -> some View {
        RoundedRectangle(cornerRadius: AppMetrics.radiusViewfinder, style: .continuous)
            .fill(connecting ? Color.black.opacity(0.55) : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: AppMetrics.radiusViewfinder, style: .continuous)
                    .strokeBorder(theme.colors.border, lineWidth: AppMetrics.hairline)
            )
            .overlay {
                if connecting {
                    ProgressView().controlSize(.large).tint(theme.colors.accent)
                } else {
                    // Drawn INSIDE the frame's bounds. The Flutter version
                    // positions its four brackets with `Alignment(±0.7, ±0.4)`
                    // against the whole Stack, so they drift away from the
                    // 268pt frame on every screen size that is not the one it
                    // was eyeballed on. A Shape in the frame's own coordinate
                    // space cannot drift.
                    ViewfinderBrackets()
                        .stroke(
                            theme.colors.accent,
                            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                        )
                        .padding(6)
                }
            }
            .frame(width: 268, height: 268)
            .frame(maxHeight: .infinity)
            .accessibilityHidden(true)
    }

    private var pasteEntryButton: some View {
        Button {
            model.openPasteSheet()
        } label: {
            Label("Can't scan? Paste code instead", systemImage: "doc.on.clipboard")
                .font(theme.type.sans(13, weight: .medium))
                .foregroundStyle(theme.colors.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.black.opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(theme.colors.accent, lineWidth: AppMetrics.hairline)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// Camera denied, restricted, or absent.
    ///
    /// Not in the spec, because Flutter's `MobileScanner` renders its own
    /// (untranslated, un-themed) error text. It is unavoidable here: this is
    /// the state every Simulator run lands in, and "the empty, error and
    /// offline states are the ones users actually hit".
    private var cameraBlockedBody: some View {
        VStack(spacing: 20) {
            EmptyStateView(
                systemImage: cameraBlockedIcon,
                title: cameraBlockedTitle,
                message: cameraBlockedMessage
            )
            VStack(spacing: 10) {
                // Promoted to the primary action: with no camera it is not a
                // fallback, it is the only way to pair.
                PrimaryButton(title: "Paste code instead") { model.openPasteSheet() }
                if case .denied(let restricted) = model.camera, !restricted {
                    SecondaryButton(title: "Open Settings", action: openSystemSettings)
                }
            }
            .frame(maxWidth: AppMetrics.onboardingMaxWidth)
            .padding(.horizontal, AppMetrics.gutter)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.colors.bg)
    }

    private var cameraBlockedIcon: String {
        if case .denied = model.camera { return "video.slash" }
        return "camera.metering.unknown"
    }

    private var cameraBlockedTitle: String {
        switch model.camera {
        case .denied(let restricted):
            restricted ? "Camera is restricted" : "Camera access is off"
        default:
            "No camera available"
        }
    }

    private var cameraBlockedMessage: String {
        switch model.camera {
        case .denied(let restricted):
            restricted
                ? "A profile or Screen Time restriction blocks the camera on this device. You can still pair by pasting the code your Mac printed."
                : "Remote Pi needs the camera to read the pairing QR. Turn it on in Settings, or paste the code your Mac printed next to the QR."
        case .unavailable(let reason):
            "\(reason) Paste the code your Mac printed next to the QR instead."
        case .ready, .undetermined:
            ""
        }
    }

    private func errorBody(message: String, canRetry: Bool) -> some View {
        VStack(spacing: 20) {
            EmptyStateView(
                systemImage: "exclamationmark.circle",
                title: "Pairing failed",
                message: message
            )
            VStack(spacing: 10) {
                if canRetry {
                    PrimaryButton(title: "Try again") { model.retry() }
                }
                // Always available: on a camera-less device "Try again" only
                // returns to a viewfinder that cannot help.
                SecondaryButton(title: "Paste code instead") {
                    model.retry()
                    model.openPasteSheet()
                }
            }
            .frame(maxWidth: AppMetrics.onboardingMaxWidth)
            .padding(.horizontal, AppMetrics.gutter)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.colors.bg)
    }

    // MARK: - Sheet results

    private func submitPastedIfAny() {
        guard let raw = pastedPayload else { return }
        pastedPayload = nil
        Task { await model.submitPasted(raw) }
    }

    private func completePostPair() {
        let result = nicknameResult
        nicknameResult = nil
        Task { await model.completePostPair(with: result) }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

/// Four corner brackets, drawn in the viewfinder's own coordinate space.
struct ViewfinderBrackets: Shape {
    /// Arm length of each `L`.
    var arm: CGFloat = 34
    /// Must track the frame's corner radius or the brackets cut the curve.
    var corner: CGFloat = AppMetrics.radiusViewfinder

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let arm = min(self.arm, min(rect.width, rect.height) / 2 - corner)

        // Top-left
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + corner + arm))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + corner))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + corner, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + corner + arm, y: rect.minY))

        // Top-right
        path.move(to: CGPoint(x: rect.maxX - corner - arm, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - corner, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + corner),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + corner + arm))

        // Bottom-right
        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - corner - arm))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - corner))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - corner, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - corner - arm, y: rect.maxY))

        // Bottom-left
        path.move(to: CGPoint(x: rect.minX + corner + arm, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + corner, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - corner),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - corner - arm))

        return path
    }
}
