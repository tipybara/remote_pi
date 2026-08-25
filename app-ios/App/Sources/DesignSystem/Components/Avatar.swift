import SwiftUI

/// The initial-letter circle on a session tile (spec 08 §7.6,
/// `session_tile.dart:277-299`).
///
/// First **grapheme** of the title, uppercased — grapheme, not `String.first`
/// scalar, so an emoji or a combining accent renders as one character instead
/// of a mangled half. `?` when the title is empty or whitespace.
///
/// Display only. The letter comes from a label the user can edit, so nothing
/// downstream may key off it.
struct Avatar: View {
    let title: String
    var diameter: CGFloat = AppMetrics.avatar

    @Environment(\.theme) private var theme

    var body: some View {
        Circle()
            .fill(theme.colors.surface)
            .overlay(Circle().strokeBorder(theme.colors.border, lineWidth: AppMetrics.hairline))
            .overlay(
                Text(Self.initial(of: title))
                    .font(theme.type.mono(diameter * 0.4, weight: .semibold))
                    .foregroundStyle(theme.colors.accent)
            )
            .frame(width: diameter, height: diameter)
            .accessibilityHidden(true)
    }

    /// Exposed so a screen can render the same letter somewhere else (a sheet
    /// header, say) without duplicating the grapheme rule.
    static func initial(of name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "?" }
        return String(first).uppercased()
    }
}
