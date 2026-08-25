import SwiftUI

/// The post-pair nickname sheet (spec 08 §6.4, `nickname_sheet.dart`).
///
/// ## How the return contract survives SwiftUI
///
/// The Flutter sheet is a `showModalBottomSheet<String>` and its result is the
/// value passed to `Navigator.pop`. SwiftUI sheets return nothing, so the
/// result is written into ``result`` **before** dismissing and read by the
/// presenter's `onDismiss`. That is what keeps all four exits distinguishable:
/// a drag never runs any of this code, so `result` is still `nil`, which is
/// precisely the "treat as skip, persist nothing" case.
///
/// Do not "simplify" this into an `onSubmit` closure called at dismiss time —
/// a drag would then have no way to report itself, and Skip and drag would
/// collapse into one behaviour. They are not one behaviour: Skip persists the
/// hostname as the nickname, a drag persists nothing.
struct NicknameSheet: View {
    /// `pair_ok.hostname`, already resolved through
    /// ``NicknameDraft/placeholder(defaultName:)``. Also what Skip returns.
    let placeholder: String
    @Binding var result: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var typed = ""
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        SheetScaffold(
            title: "Name this PC",
            subtitle: "Pick a label so this Mac is easy to spot in your list. You can change it later from the home screen."
        ) {
            VStack(alignment: .leading, spacing: 18) {
                TextField(placeholder, text: $typed)
                    .font(theme.type.mono(14))
                    .foregroundStyle(theme.colors.text)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($isFieldFocused)
                    .onSubmit(save)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .background(theme.colors.inputFill)
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
                    .accessibilityLabel("Name for this machine")

                HStack(spacing: 12) {
                    SecondaryButton(title: "Skip", action: skip)
                    PrimaryButton(title: "Save", action: save)
                }
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
            // Autofocused, matching the Flutter field. A tiny delay because a
            // sheet that focuses a field during its presentation transition
            // gets the keyboard animation interleaved with the sheet's and
            // lands with a visibly wrong content inset.
            try? await Task.sleep(for: .milliseconds(350))
            isFieldFocused = true
        }
    }

    private func save() {
        result = NicknameDraft.save(typed: typed, placeholder: placeholder)
        dismiss()
    }

    private func skip() {
        result = NicknameDraft.skip(placeholder: placeholder)
        dismiss()
    }
}
