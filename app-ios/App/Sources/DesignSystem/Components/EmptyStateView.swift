import SwiftUI

/// Every "there is nothing here" screen and every per-tab empty slot
/// (spec 08 §7.1, §7.3, §8.1, §9.3).
///
/// Deliberately **not** `ContentUnavailableView`: that one paints with system
/// materials and the system font, which reads as a different app next to the
/// mono chrome, and it cannot be dimmed the way the "lonely" state needs.
///
/// The copy strings live in the screens, not here — they are per-screen
/// product text quoted verbatim from the spec, and centralising them would
/// just make the spec harder to diff against the code.
struct EmptyStateView<Action: View>: View {
    /// SF Symbol name. Pick the closest match to the Lucide glyph the spec
    /// names; the symbol is decorative and is hidden from VoiceOver.
    let systemImage: String
    let title: String
    var message: String?
    /// `0.35` for Home's "lonely" moon (spec 08 §7.1), `1` everywhere else.
    var iconOpacity: Double = 1
    @ViewBuilder var action: () -> Action

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(theme.colors.muted)
                .opacity(iconOpacity)
                .accessibilityHidden(true)
            Text(title)
                .font(theme.type.mono(14, weight: .semibold))
                .foregroundStyle(theme.colors.text)
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(theme.type.mono(12))
                    .foregroundStyle(theme.colors.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            action()
                .padding(.top, 4)
        }
        .padding(.horizontal, AppMetrics.gutter)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}

extension EmptyStateView where Action == EmptyView {
    init(
        systemImage: String,
        title: String,
        message: String? = nil,
        iconOpacity: Double = 1
    ) {
        self.init(
            systemImage: systemImage,
            title: title,
            message: message,
            iconOpacity: iconOpacity,
            action: { EmptyView() }
        )
    }
}

/// The app's one filled button. Here rather than in each screen so "primary
/// action" looks the same in onboarding, Home's empty state and the sync gate.
///
/// Disabled state paints `border` as the fill (not a system grey), matching
/// `relay_step.dart`'s continue button.
struct PrimaryButton: View {
    let title: String
    var isEnabled: Bool = true
    var isBusy: Bool = false
    let action: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(theme.colors.onAccent)
                }
                Text(title)
                    .font(theme.type.mono(13, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, 18)
            .background(isEnabled ? theme.colors.accent : theme.colors.border)
            .foregroundStyle(isEnabled ? theme.colors.onAccent : theme.colors.muted)
            // Terminal redesign: rectangles, not pills. 6pt keeps it from
            // reading as a web widget while staying unmistakably a slab.
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isBusy)
    }
}

/// The app's outlined/secondary button (`Back`, `Scan later`, `Retry`).
struct SecondaryButton: View {
    let title: String
    var isEnabled: Bool = true
    let action: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(theme.type.mono(13, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .padding(.horizontal, 18)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(theme.colors.border, lineWidth: AppMetrics.hairline)
                )
                .foregroundStyle(isEnabled ? theme.colors.text : theme.colors.muted)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}
