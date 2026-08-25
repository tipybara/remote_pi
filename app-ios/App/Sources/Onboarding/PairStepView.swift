import SwiftUI

/// Step 3 — pair (spec 08 §5.5, `pair_step.dart`).
///
/// The wizard's only screen with a live device resource. Two rules govern it:
///
/// * the camera runs **only** in `.scanning`, and
/// * every payload — camera or paste — goes through
///   ``OnboardingModel/submit(payload:)``, which disarms before it awaits.
struct PairStepView: View {
    @Bindable var model: OnboardingModel

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Connect to your device")
                .font(theme.type.mono(16, weight: .semibold))
                .foregroundStyle(theme.colors.text)
                .padding(.top, 24)
                .padding(.bottom, 12)

            Text("On your computer (Mac, Linux, or Windows), open Pi and run:")
                .font(theme.type.mono(11))
                .foregroundStyle(theme.colors.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 6)

            Text(verbatim: "/remote-pi pair")
                .font(theme.type.mono(13))
                .foregroundStyle(theme.colors.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.colors.bg)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(theme.colors.border, lineWidth: AppMetrics.hairline)
                )
                .textSelection(.enabled)
                .padding(.bottom, 12)

            Text("Scan the QR code that appears:")
                .font(theme.type.mono(11))
                .foregroundStyle(theme.colors.muted)
                .padding(.bottom, 12)

            viewfinder
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.bottom, 12)

            if model.pairing.showsPasteButton {
                Button {
                    model.isPasteSheetPresented = true
                } label: {
                    Label("Can't scan? Paste code instead", systemImage: "doc.on.clipboard")
                        .font(theme.type.mono(12))
                        .foregroundStyle(theme.colors.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 12) {
                SecondaryButton(title: "Back", action: model.back)
                    .frame(width: 96)
                Spacer(minLength: 0)
                Button(action: model.skipPairing) {
                    Text("Scan later")
                        .font(theme.type.mono(13, weight: .medium))
                        .foregroundStyle(theme.colors.accent)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .padding(.horizontal, AppMetrics.gutter)
        .task {
            // Asks for camera access when — and only when — this step appears.
            // Prompting on launch, or on step 1, trains the user to deny it.
            await model.prepareCamera()
        }
        .sheet(isPresented: $model.isPasteSheetPresented) {
            OnboardingPasteSheet { raw in
                await model.submit(payload: raw)
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Body states (spec 08 §5.5 table)

    @ViewBuilder
    private var viewfinder: some View {
        switch model.pairing.phase {
        case .scanning:
            ZStack {
                // The §6.2 scanner, shared with the pairing screen. This step
                // used to carry its own smaller `QRViewfinder`; its header said
                // to replace it with this one once it landed, and it has.
                QRScannerView(isArmed: true) { code in
                    Task { await model.submit(payload: code) }
                }
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(theme.colors.accent, lineWidth: 2)
            }
            .accessibilityElement()
            .accessibilityLabel("Camera viewfinder. Point it at the QR code shown in your terminal.")

        case .connecting:
            StatusOverlay(systemImage: "arrow.triangle.2.circlepath", message: "Pairing…", isBusy: true)

        case .failed(let message, let canRetry):
            StatusOverlay(systemImage: "exclamationmark.circle", message: message) {
                if canRetry {
                    PrimaryButton(title: "Try again", action: model.retryPairing)
                        .frame(maxWidth: 200)
                }
            }

        case .paired:
            StatusOverlay(systemImage: "checkmark.circle", message: "Paired!")

        case .idle:
            // `PairingIdle` renders nothing in Flutter (`pair_step.dart:239`).
            // Here it is also the camera-less state — every simulator, every
            // denied permission — so it explains itself instead of showing an
            // empty rectangle the user cannot act on.
            if let issue = model.pairing.cameraIssue {
                StatusOverlay(systemImage: "camera.badge.ellipsis", message: issue)
            } else {
                Color.clear
            }
        }
    }
}

/// The non-camera bodies of the viewfinder slot (`pair_step.dart:243-300`).
struct StatusOverlay<Action: View>: View {
    let systemImage: String
    let message: String
    var isBusy: Bool = false
    @ViewBuilder var action: () -> Action

    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            theme.colors.bg
            VStack(spacing: 12) {
                if isBusy {
                    ProgressView()
                        .controlSize(.large)
                        .tint(theme.colors.accent)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(theme.colors.accent)
                        .accessibilityHidden(true)
                }
                Text(message)
                    .font(theme.type.mono(12))
                    .foregroundStyle(theme.colors.text)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 28)
                action()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(theme.colors.border, lineWidth: AppMetrics.hairline)
        )
    }
}

extension StatusOverlay where Action == EmptyView {
    init(systemImage: String, message: String, isBusy: Bool = false) {
        self.init(systemImage: systemImage, message: message, isBusy: isBusy, action: { EmptyView() })
    }
}

/// The camera-less way in (spec 08 §6.5): paste the raw `remotepi://pair?…`
/// payload. Submit is disabled while the trimmed text is empty, and submitting
/// routes into the same path a camera scan takes.
///
/// Named for onboarding because the pairing screen (spec 08 §6.5) owns its own
/// copy of this sheet; when the two are reconciled, one should delete the other.
struct OnboardingPasteSheet: View {
    let submit: (String) async -> Void

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var isSubmitting = false
    @FocusState private var focused: Bool

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        SheetScaffold(
            title: "Paste pairing code",
            subtitle: "Copy the remotepi://pair line printed under the QR code.",
            trailing: { SheetCloseButton { dismiss() } }
        ) {
            VStack(alignment: .leading, spacing: 12) {
                TextField("remotepi://pair?…", text: $text, axis: .vertical)
                    .font(theme.type.mono(12))
                    .foregroundStyle(theme.colors.text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .lineLimit(4...8)
                    .focused($focused)
                    .padding(10)
                    .background(theme.colors.inputFill)
                    .clipShape(
                        RoundedRectangle(cornerRadius: AppMetrics.radiusBubble, style: .continuous)
                    )

                PrimaryButton(
                    title: "Pair",
                    isEnabled: !trimmed.isEmpty,
                    isBusy: isSubmitting
                ) {
                    guard !isSubmitting else { return }
                    Task {
                        isSubmitting = true
                        // The model closes this sheet itself once the payload is
                        // accepted, so the pairing progress is visible in the
                        // viewfinder slot rather than behind a modal.
                        await submit(trimmed)
                        isSubmitting = false
                    }
                }
            }
            .padding(.horizontal, AppMetrics.sheetGutter)
            .padding(.bottom, 24)
        }
        .task { focused = true }
    }
}
