import SwiftUI

// ============================================================================
// The large collapsing title (spec 08 §7.2).
//
// Built by hand rather than with `.navigationTitle` + `.large`, for the same
// reason the Flutter version renders inside `flexibleSpace` instead of using
// `SliverAppBar.title`: the expanded form is a **two-line block** — a 32pt
// brand word plus a live relay-status line — and the system large title has no
// room for a subtitle. Layering our own on top of the system one produced the
// "two app bars" overlap the Dart comment records.
//
// The geometry is the Dart's, exactly: 124pt expanded, 56pt collapsed, and a
// manual cross-fade on `t = (maxH - 56) / (124 - 56)`. Here `maxH` is derived
// from the scroll offset instead of a `LayoutBuilder`, which is the same
// number by a different route.
// ============================================================================

enum HomeTitleMetrics {
    static let expanded: CGFloat = 124
    static let collapsed: CGFloat = 56
    /// How far the list scrolls before the title is fully collapsed.
    static var travel: CGFloat { expanded - collapsed }

    /// `1` fully expanded, `0` fully collapsed.
    static func progress(scrollOffset: CGFloat) -> CGFloat {
        guard travel > 0 else { return 0 }
        return min(max(1 - scrollOffset / travel, 0), 1)
    }
}

/// The pinned 56pt bar: compact title + actions + the divider that appears
/// only once collapsed.
struct HomeCompactBar<Actions: View>: View {
    /// `1` expanded → `0` collapsed.
    let progress: CGFloat
    @ViewBuilder var actions: () -> Actions

    @Environment(\.theme) private var theme

    var body: some View {
        ZStack(alignment: .bottom) {
            HStack(spacing: 4) {
                Text("Remote Pi")
                    .font(theme.type.brand(16, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(theme.colors.text)
                    .opacity(1 - progress)
                    // Collapsed-only, so it must not steal VoiceOver focus
                    // from the expanded copy sitting right below it.
                    .accessibilityHidden(progress > 0.5)
                Spacer(minLength: 8)
                actions()
            }
            .padding(.horizontal, AppMetrics.gutter)
            .frame(height: HomeTitleMetrics.collapsed)

            Rectangle()
                .fill(theme.colors.border)
                .frame(height: AppMetrics.hairline)
                .opacity(1 - progress)
        }
        .background(theme.colors.bg)
    }
}

/// The expanded block that scrolls away: 32pt brand word + the relay line.
struct HomeLargeTitle: View {
    let progress: CGFloat
    let status: HomeRelayStatus

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Remote Pi")
                .font(theme.type.brand(32, weight: .bold))
                .tracking(-0.5)
                .foregroundStyle(theme.colors.text)
            RelayStatusLine(status: status)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppMetrics.gutter)
        .padding(.bottom, 8)
        .frame(height: HomeTitleMetrics.travel, alignment: .bottom)
        .opacity(progress)
        .accessibilityHidden(progress < 0.5)
    }
}

/// `● Relay · <status>` (spec 08 §7.2).
///
/// Reflects the **app→relay** socket, not any Pi's presence, so the user
/// always knows whether the app itself is reachable.
struct RelayStatusLine: View {
    let status: HomeRelayStatus

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
                .padding(.trailing, 2)
            Text("Relay").foregroundStyle(theme.colors.text)
            Text("·").foregroundStyle(theme.colors.muted)
            Text(status.label).foregroundStyle(labelColor)
        }
        .font(theme.type.mono(13))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Relay \(status.label)")
    }

    private var dotColor: Color {
        switch status {
        case .connected: theme.colors.success
        // Neutral, not amber: with no peer the socket was never opened, so
        // "not connected" is not a fault (spec 08 §7.2).
        case .awaitingPairing: theme.colors.muted
        case .offline: theme.colors.warning
        }
    }

    private var labelColor: Color {
        switch status {
        case .connected, .awaitingPairing: theme.colors.muted
        case .offline: theme.colors.warning
        }
    }
}
