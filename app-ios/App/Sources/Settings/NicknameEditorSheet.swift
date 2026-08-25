import RemotePiProtocol
import SwiftUI

/// Edit or clear a machine's local nickname (spec 08 §10, `nickname_editor.dart`).
///
/// ## The trap this sheet encodes
///
/// It has **three** outcomes, not two, and the difference is absent vs empty:
///
/// | Action | Result |
/// |---|---|
/// | Save with text | nickname = that text |
/// | Remove nickname / Save while blank | nickname = `nil` (falls back to the session name) |
/// | Cancel / swipe down | **no write at all** |
///
/// Collapsing "cancel" and "cleared" into one empty string is how a dismissed
/// sheet silently wipes a nickname. Every dismissal path here routes through
/// `onCancel`, and only the two buttons write.
struct NicknameEditorSheet: View {
    let record: PeerRecord
    @Binding var draft: String
    let onSave: () async -> Void
    let onCancel: () -> Void

    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool

    private var defaultName: String {
        // What the row would show with no nickname — that is what "Default:"
        // means to the user, not the raw session name which may be absent.
        if let sessionName = record.sessionName, !sessionName.isEmpty { return sessionName }
        return record.peer.shortDescription
    }

    private var hasCurrent: Bool {
        guard let nickname = record.nickname else { return false }
        return !nickname.isEmpty
    }

    var body: some View {
        SheetScaffold(
            title: "Nickname",
            subtitle: "Local only — the Mac is not notified."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Nickname", text: $draft)
                    .font(theme.type.sans(15))
                    .foregroundStyle(theme.colors.text)
                    .focused($focused)
                    .submitLabel(.done)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .onSubmit { Task { await onSave() } }
                    // 40 characters, matching the Dart `maxLength`. Enforced on
                    // input rather than at save so the counter cannot lie.
                    .onChange(of: draft) { _, now in
                        if now.count > 40 { draft = String(now.prefix(40)) }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                    .background(theme.colors.inputFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(theme.colors.border, lineWidth: AppMetrics.hairline)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                HStack {
                    Text("Default: \(defaultName)")
                        .font(theme.type.mono(11))
                        .foregroundStyle(theme.colors.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text("\(draft.count)/40")
                        .font(theme.type.mono(11))
                        .foregroundStyle(theme.colors.muted)
                        .monospacedDigit()
                }

                if hasCurrent {
                    Button {
                        // "Remove" is Save-with-empty, not a separate write
                        // path: one commit method means one place where the
                        // absent-vs-empty rule is applied.
                        draft = ""
                        Task { await onSave() }
                    } label: {
                        Label("Remove nickname", systemImage: "trash")
                            .font(theme.type.mono(12))
                            .foregroundStyle(theme.colors.error)
                    }
                    .buttonStyle(.plain)
                }

                HStack(spacing: 10) {
                    SecondaryButton(title: "Cancel", action: onCancel)
                    PrimaryButton(title: "Save") { Task { await onSave() } }
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, AppMetrics.sheetGutter)
            .padding(.bottom, 20)
        }
        .task { focused = true }
    }
}
