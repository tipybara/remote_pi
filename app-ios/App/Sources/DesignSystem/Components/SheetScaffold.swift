import SwiftUI

/// The chrome every bottom sheet in the app shares: rounded top, grabber,
/// title/subtitle block, optional trailing dismiss, themed background.
///
/// Sheets that use it: nickname (§6.4), paste-QR (§6.5), long-press session
/// menu (§7.7), New Session (§7.9), attach (§8.10), quick actions (§8.11),
/// model picker (§8.12), Settings-on-tablet (§9).
///
/// ## Two rules that are easy to get wrong
///
/// 1. **Detents belong to the presenter, not to the content.** Put
///    `.presentationDetents` / `.presentationDragIndicator` on the
///    `.sheet { }` call site. This scaffold only draws; if it also declared
///    detents they would fight the caller's.
///
/// 2. **A chat-scoped sheet must dismiss when the session changes**
///    (spec 08 §11.2, `DismissOnSessionChange`). On tablet the detail pane can
///    swap under an open sheet, leaving it hovering over a different session —
///    and a sub-picker (model list) stacked above it. Use
///    ``SwiftUI/View/dismissOnSessionChange(_:)`` on any sheet opened from the
///    chat. It is not in this scaffold because Home's sheets must *not* do it.
struct SheetScaffold<Content: View, Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(theme.type.mono(15, weight: .semibold))
                        .foregroundStyle(theme.colors.text)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(theme.type.mono(11.5))
                            .foregroundStyle(theme.colors.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                trailing()
            }
            .padding(.horizontal, AppMetrics.sheetGutter)
            .padding(.top, 18)
            .padding(.bottom, 14)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.colors.bg)
        .presentationBackground(theme.colors.bg)
        .presentationCornerRadius(AppMetrics.radiusSheet)
    }
}

extension SheetScaffold where Trailing == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(title: title, subtitle: subtitle, trailing: { EmptyView() }, content: content)
    }
}

/// A small circular `x` for a sheet's trailing slot (Settings-as-sheet uses a
/// 22pt one, spec 08 §9).
struct SheetCloseButton: View {
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.colors.muted)
                .frame(width: 28, height: 28)
                .background(theme.colors.surface, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
    }
}
