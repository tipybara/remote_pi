import SwiftUI

/// The segmented pill with per-segment counts (spec 08 §7.3,
/// `home_filter_tabs.dart:12-101`).
///
/// A `surface` track with 3pt inner padding and a 10pt radius; each segment is
/// equal width; the selected one is filled `accent` with `onAccent` text and
/// slides in over 150ms `easeOut`.
///
/// Generic on purpose — it knows nothing about `SessionFilter`. Home passes
/// its own tab enum and its own count function, which keeps the two rules
/// that matter *in Home*:
///
/// * the counts are **per tab and independent of the selection** — the Online
///   count does not become the list length when Online is selected;
/// * selecting a tab is a **pure view filter**. It must never trigger a
///   reload, a refetch, or a regroup (§7.3), and it must survive a data
///   re-emit (§12.2 — resetting it on every `_load` was the "sessions
///   jumping" bug).
///
/// Not `Picker(.segmented)`: that control cannot carry a count per segment,
/// and its colors come from UIKit's tint pipeline rather than our palette.
struct FilterTabs<Tab: Hashable>: View {
    let tabs: [Tab]
    let label: (Tab) -> String
    let count: (Tab) -> Int
    @Binding var selection: Tab

    @Environment(\.theme) private var theme
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs, id: \.self) { tab in
                segment(tab)
            }
        }
        .padding(3)
        .background(theme.colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppMetrics.radiusPill, style: .continuous))
    }

    private func segment(_ tab: Tab) -> some View {
        let isSelected = tab == selection
        return Button {
            guard !isSelected else { return }
            withAnimation(.easeOut(duration: 0.15)) { selection = tab }
        } label: {
            HStack(spacing: 5) {
                Text(label(tab))
                Text("\(count(tab))")
                    .monospacedDigit()
                    .opacity(isSelected ? 0.75 : 0.6)
            }
            .font(theme.type.mono(11, weight: isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? theme.colors.onAccent : theme.colors.muted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: AppMetrics.radiusPill - 3, style: .continuous)
                        .fill(theme.colors.accent)
                        .matchedGeometryEffect(id: "selected", in: pill)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
