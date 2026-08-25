import SwiftUI

/// The two list headers of the Home hierarchy (spec 08 §7.5), plus the
/// uppercase section labels in Settings.
///
/// One component with a `style`, rather than three, because they differ only
/// in weight and inset and the difference must stay proportional if the font
/// scale changes.
///
/// **Nothing here is tappable.** A workspace is a grouping key, not an entity
/// (plan 61): there is no workspace detail screen to navigate to.
struct SectionHeader: View {
    enum Style: Sendable {
        /// The machine (`PeerSectionHeader`): 11pt mono, uppercased,
        /// `letterSpacing: 1`, muted. Also used for Settings' `RELAY` /
        /// `DISPLAY` / `PAIRINGS` labels.
        case device
        /// The folder (`WorkspaceSectionHeader`): 12pt mono w600 in `muted2`,
        /// with a folder glyph and an optional dimmed path line beneath.
        case workspace
    }

    let title: String
    var subtitle: String?
    var style: Style = .device
    /// Rendered flush right. `nil` hides it — do not pass `0`, an empty group
    /// should not have a header at all (spec 08 §7.5: "an emptied workspace or
    /// device leaves no dangling header").
    var count: Int?

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if style == .workspace {
                Image(systemName: "folder")
                    .font(theme.type.mono(11))
                    .foregroundStyle(theme.colors.muted)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(style == .device ? title.uppercased() : title)
                    .font(titleFont)
                    .tracking(style == .device ? 1 : 0)
                    .foregroundStyle(style == .device ? theme.colors.muted : theme.colors.muted2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(theme.type.mono(10))
                        .foregroundStyle(theme.colors.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            if let count {
                Text("\(count)")
                    .font(theme.type.mono(11))
                    .foregroundStyle(theme.colors.muted)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, AppMetrics.gutter)
        .padding(.top, style == .device ? 18 : 10)
        .padding(.bottom, style == .device ? 6 : 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var titleFont: Font {
        switch style {
        case .device: theme.type.mono(11, weight: .semibold)
        case .workspace: theme.type.mono(12, weight: .semibold)
        }
    }
}

/// Shorten a path from the **front**, keeping the tail.
///
/// Ported from `workspace_section_header.dart:33-38`. The tail is the part
/// that disambiguates (`…/proj/api` says more than `/Users/jacob/pr…`), so a
/// plain tail-truncating ellipsis cuts the wrong end.
///
/// The budget is a character count, which is exact only because the path is
/// drawn in a monospaced face — see the substitution note in
/// `AppTypography.swift`. Do not reuse this helper on proportional text.
///
/// (The Dart version records a real bug this replaced: doing it with an RTL
/// text direction reordered the leading `/` to the visual end, because `/` is
/// direction-neutral. Truncate explicitly; never flip the direction.)
func headTruncatedPath(_ path: String, budget: Int = 42) -> String {
    guard path.count > budget, budget > 1 else { return path }
    return "…" + String(path.suffix(budget - 1))
}
