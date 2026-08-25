import SwiftUI

/// The long-press menu (spec 08 §7.7, `home_page.dart:462-516`).
///
/// Two rows. Delete is enabled only while the room is **offline**: deleting is
/// a local cache eviction, and evicting a live room would just have it
/// re-announced a moment later, which reads as the delete silently failing.
/// When it is live the row is greyed and says why, rather than disappearing —
/// a control that vanishes teaches the user nothing.
struct SessionMenuSheet: View {
    let row: HomeRow
    let canDelete: Bool
    /// `false` when this build cannot evict a cached session at all. Kept
    /// separate from ``canDelete`` so the copy can say which of the two
    /// reasons applies.
    let deleteSupported: Bool
    let rename: () -> Void
    let delete: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetScaffold(title: row.title, subtitle: subtitle) {
            VStack(spacing: 0) {
                menuRow(
                    icon: "pencil",
                    tint: theme.colors.accent,
                    title: "Rename session",
                    isEnabled: true,
                    action: rename
                )
                Divider().overlay(theme.colors.border)
                menuRow(
                    icon: "trash",
                    tint: deleteEnabled ? theme.colors.error : theme.colors.muted,
                    title: "Delete session (local only)",
                    detail: deleteEnabled ? nil : deleteDisabledReason,
                    isEnabled: deleteEnabled,
                    action: delete
                )
            }
            .padding(.bottom, 12)
        }
    }

    private var deleteEnabled: Bool { canDelete && deleteSupported }

    private var deleteDisabledReason: String {
        canDelete
            ? "Not available in this build yet"
            : "Only available when the room is offline"
    }

    private var subtitle: String? {
        row.contextLabel ?? nil
    }

    private func menuRow(
        icon: String,
        tint: Color,
        title: String,
        detail: String? = nil,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(theme.type.sans(15))
                        .foregroundStyle(isEnabled ? theme.colors.text : theme.colors.muted)
                    if let detail {
                        Text(detail)
                            .font(theme.type.mono(11))
                            .foregroundStyle(theme.colors.muted)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, AppMetrics.sheetGutter)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}
