import RemotePiProtocol
import SwiftUI

/// One row of the Home list — terminal edition (2026-08-29).
///
/// `❯ title` over a one-line detail, with a square presence LED trailing. The
/// initial-letter avatar is gone: a terminal session list identifies rows by
/// their prompt, and the 40pt circle was the single largest consumer of row
/// height. The prompt glyph carries the presence *color* as reinforcement,
/// but the LED remains the canonical indicator (and the VoiceOver label lives
/// there) — color on the glyph is decoration, never the only signal.
///
/// The detail line is **always exactly one line**. Layout invariant, not
/// style: switching the grouping moves the folder/machine label onto the
/// row, and if that wrapped, every row on screen would change height and the
/// whole list would jump — the exact failure plan 61 is about.
struct SessionTileView: View {
    let row: HomeRow
    let presence: PresenceLevel
    let open: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("❯")
                    .font(theme.type.mono(15, weight: .bold))
                    .foregroundStyle(promptColor)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(row.title)
                        .font(theme.type.mono(15, weight: .semibold))
                        .foregroundStyle(theme.colors.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    detailLine
                }

                Spacer(minLength: 8)

                PresenceDot(level: presence, diameter: 8)
                    // Optically align the LED with the title baseline row
                    // rather than the HStack's text baseline (a square has
                    // no baseline of its own).
                    .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 4 }
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    /// The prompt echoes the presence color; offline stays muted so a dead
    /// session's row visibly recedes.
    private var promptColor: Color {
        switch presence {
        case .working: theme.colors.working
        case .reconnecting: theme.colors.warning
        case .live: theme.colors.accent
        case .offline: theme.colors.muted
        }
    }

    /// One line, one `Text`, so the halves share a truncation budget.
    @ViewBuilder
    private var detailLine: some View {
        let detail = detailText
        Group {
            if let context = row.contextLabel, !context.isEmpty {
                Text(context).foregroundStyle(theme.colors.muted)
                    + Text("  ").foregroundStyle(theme.colors.muted)
                    + detail
            } else {
                detail
            }
        }
        .font(theme.type.mono(11.5))
        .lineLimit(1)
        .truncationMode(.tail)
    }

    private var detailText: Text {
        switch row.detail {
        case .model(let name):
            Text(name).foregroundStyle(theme.colors.muted2)
        case .lastPaired(let when):
            Text(when).foregroundStyle(theme.colors.muted)
        }
    }
}
