import RemotePiProtocol
import SwiftUI

/// One row of the Home list (spec 08 §7.6, `session_tile.dart:11-117`).
///
/// Avatar → title block → presence dot. The selected state paints a 3pt left
/// `accent` bar plus a 6% accent fill and trims the left inset from 18 to 15,
/// so the content does **not** shift when a row becomes selected.
///
/// The subtitle is **always exactly one line**. That is a layout invariant, not
/// a style choice: switching the grouping moves the folder/machine label onto
/// the tile, and if that wrapped, every row on screen would change height and
/// the whole list would jump — the exact failure plan 61 is about.
struct SessionTileView: View {
    let row: HomeRow
    let presence: PresenceLevel
    let isSelected: Bool
    let open: () -> Void
    let showMenu: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: open) {
            HStack(spacing: 14) {
                Avatar(title: row.title)
                titleBlock
                Spacer(minLength: 8)
                PresenceDot(level: presence)
            }
            .padding(.leading, isSelected ? 15 : 18)
            .padding(.trailing, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .leading) {
                ZStack(alignment: .leading) {
                    isSelected ? theme.colors.accent.opacity(0.06) : Color.clear
                    if isSelected {
                        theme.colors.accent.frame(width: AppMetrics.selectionBar)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Simultaneous rather than `.onLongPressGesture`, which would swallow
        // the tap on some devices; the Button keeps its native highlight and
        // its accessibility traits either way.
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45).onEnded { _ in showMenu() }
        )
        .accessibilityAction(named: "Session options", showMenu)
        .accessibilityElement(children: .combine)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.title)
                .font(theme.type.sans(15, weight: .medium))
                .foregroundStyle(theme.colors.text)
                .lineLimit(1)
                .truncationMode(.tail)
            subtitle
        }
    }

    /// One line, built as a single `Text` so the two halves share a truncation
    /// budget instead of each reserving its own.
    @ViewBuilder
    private var subtitle: some View {
        let detail = detailText
        Group {
            if let context = row.contextLabel, !context.isEmpty {
                Text(context).foregroundStyle(theme.colors.muted)
                    + Text("  ·  ").foregroundStyle(theme.colors.muted)
                    + detail
            } else {
                detail
            }
        }
        .font(theme.type.mono(12))
        .lineLimit(1)
        .truncationMode(.tail)
    }

    private var detailText: Text {
        switch row.detail {
        case .model(let name):
            Text(name).foregroundStyle(theme.colors.accent)
        case .lastPaired(let when):
            Text(when).foregroundStyle(theme.colors.muted)
        }
    }
}
