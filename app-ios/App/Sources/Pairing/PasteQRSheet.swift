import SwiftUI

/// The paste-QR sheet (spec 08 §6.5, `paste_qr_sheet.dart`).
///
/// **This is not a fallback in practice — it is the primary path.** The
/// Simulator has no camera, so every end-to-end exercise of pairing on a
/// development machine goes through this sheet. It has to be complete on its
/// own: reachable from the scanner, reachable when the camera is denied,
/// reachable when there is no camera at all, and it has to say something when
/// what was pasted is not a pairing code.
///
/// Same result-binding contract as ``NicknameSheet``: the raw text is written
/// to ``submitted`` and the presenter's `onDismiss` routes it into the one
/// submit path. A drag-dismiss leaves it `nil` and nothing happens, which is
/// the correct reading of "the user changed their mind".
struct PasteQRSheet: View {
    @Binding var submitted: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var text = ""
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        SheetScaffold(
            title: "Paste pairing code",
            subtitle: "Can't scan the QR? Paste the text from your Mac terminal below. It starts with remotepi://pair?…"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                TextField("remotepi://pair?t=…", text: $text, axis: .vertical)
                    .font(theme.type.mono(12))
                    .foregroundStyle(theme.colors.text)
                    // A pairing URI is case-sensitive Base64url. Autocapitalize
                    // or autocorrect it and the token stops matching the one
                    // the Pi issued — which comes back as `token_unknown` and
                    // reads exactly like a stale QR (see `PairingQRPayload`).
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .lineLimit(3...6)
                    .focused($isFieldFocused)
                    .padding(12)
                    .background(theme.colors.surface)
                    .clipShape(
                        RoundedRectangle(cornerRadius: AppMetrics.radiusBubble, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: AppMetrics.radiusBubble, style: .continuous)
                            .strokeBorder(
                                isFieldFocused ? theme.colors.accent : theme.colors.border,
                                lineWidth: AppMetrics.hairline
                            )
                    )
                    .accessibilityLabel("Pairing code")

                // `PasteButton`, not a plain button reading `UIPasteboard`:
                // since iOS 16 an unprompted pasteboard read raises the system
                // "Allow Paste?" alert, so the Flutter design's one-tap paste
                // would become two taps and one scary dialog. `PasteButton`
                // carries its own authorisation.
                PasteButton(payloadType: String.self) { strings in
                    guard let pasted = strings.first(where: { !$0.isEmpty }) else { return }
                    // The handler is not main-actor isolated.
                    Task { @MainActor in text = PasteDraft.normalized(pasted) }
                }
                .buttonBorderShape(.roundedRectangle(radius: AppMetrics.radiusPill))
                .tint(theme.colors.surface)
                .labelStyle(.titleAndIcon)

                PrimaryButton(
                    title: "Pair",
                    // §6.5: disabled while the trimmed text is empty. Trimmed,
                    // because a pasted line from a terminal usually arrives
                    // with a newline attached.
                    isEnabled: PasteDraft.canSubmit(text),
                    action: submit
                )
            }
            .padding(.horizontal, AppMetrics.sheetGutter)
            .padding(.bottom, 24)
        }
        // A `SheetScaffold` hugs its content, and a hugging view inside a
        // fixed-height detent gets CENTRED, which leaves a dead band above the
        // title. Pin it to the top instead, where the keyboard cannot push it
        // off the sheet.
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.colors.bg)
        .task {
            try? await Task.sleep(for: .milliseconds(350))
            isFieldFocused = true
        }
    }

    private func submit() {
        guard PasteDraft.canSubmit(text) else { return }
        submitted = PasteDraft.normalized(text)
        dismiss()
    }
}
