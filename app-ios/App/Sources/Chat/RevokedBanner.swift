import SwiftUI

// ============================================================================
// Revoked banner (spec 08 §8.3) — `chat_page.dart:659-699`.
//
// This is the **only** banner the chat keeps. Plain offline / Pi-gone /
// presence-off banners were deliberately removed: the status pill in the top
// bar already says all three, and stacking them pushed the transcript down for
// information the user had already read. If you are about to add a second
// banner here, that decision is the thing to reopen first.
// ============================================================================

/// Full-width red strip under the top bar: the Mac dropped this pairing, and
/// nothing the user types will arrive until they pair again.
struct RevokedBanner: View {
    /// The device that revoked, when known — "Pairing revoked by <device>".
    var device: String?
    var onRePair: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "link.badge.plus")
                .symbolRenderingMode(.monochrome)
                .rotationEffect(.degrees(45))
                .font(.system(size: 13, weight: .semibold))
            Text(message)
                .font(theme.type.sans(12, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onRePair) {
                Text("Re-pair")
                    .font(theme.type.sans(12, weight: .semibold))
                    .underline()
            }
            .buttonStyle(.plain)
        }
        // `bg` as the foreground on an `error` fill, rather than a literal
        // white: it is the one token guaranteed to contrast with `error` in
        // both palettes, and a raw `Color.white` on the light theme's #C42026
        // would be the only hardcoded color in the app.
        .foregroundStyle(theme.colors.bg)
        .padding(.horizontal, AppMetrics.sheetGutter)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.colors.error)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message)
    }

    var message: String {
        if let device, !device.isEmpty {
            return "Pairing revoked by \(device) — re-pair to continue"
        }
        // The Dart hardcodes "Mac"; this client knows the device label from
        // the same record the top bar uses, and falls back to the generic form
        // only when it does not.
        return "Pairing revoked — re-pair to continue"
    }
}
