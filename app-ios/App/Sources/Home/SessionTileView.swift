import RemotePiProtocol
import SwiftUI

/// One row of the Home list (spec 08 §7.6) — HIG edition.
///
/// Avatar → title block → presence dot, as a standard List row: system text
/// styles so Dynamic Type works, default row insets, no custom selection
/// painting (the List row background carries that, see `HomeScreen.tile`).
/// The long-press menu moved to a real `.contextMenu` and the actions to
/// `.swipeActions`, both attached by the screen — this view is content only.
///
/// The subtitle is **always exactly one line**. That is a layout invariant,
/// not a style choice: switching the grouping moves the folder/machine label
/// onto the tile, and if that wrapped, every row on screen would change height
/// and the whole list would jump — the exact failure plan 61 is about.
struct SessionTileView: View {
    let row: HomeRow
    let presence: PresenceLevel
    let open: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Avatar(title: row.title)
                titleBlock
                Spacer(minLength: 8)
                PresenceDot(level: presence)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.title)
                .font(.body.weight(.medium))
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
        .font(.footnote)
        .lineLimit(1)
        .truncationMode(.tail)
    }

    private var detailText: Text {
        switch row.detail {
        // The model name is code-ish content; monospaced is information here
        // (it reads as an identifier), not branding.
        case .model(let name):
            Text(name).font(.footnote.monospaced()).foregroundStyle(theme.colors.accent)
        case .lastPaired(let when):
            Text(when).foregroundStyle(theme.colors.muted)
        }
    }
}
