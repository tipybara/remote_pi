import SwiftUI

/// Semantic color tokens for the whole app — the SINGLE source of truth.
///
/// Ported 1:1 from `app/lib/ui/core/themes/app_colors.dart` (both palettes).
/// Every hex below is the Flutter value; do not "improve" one here without
/// changing it there, or the two clients drift.
///
/// ## How a screen uses this
///
/// ```swift
/// @Environment(\.theme) private var theme
/// ...
/// .foregroundStyle(theme.colors.muted)
/// .background(theme.colors.surface)
/// ```
///
/// A screen must never write `Color(red:…)`, `Color(hex:)` or a stock
/// `Color.blue`. If a color you need is missing, add a *named token* here with
/// both a dark and a light value — that is the only way to keep the light
/// theme honest, because a hardcoded hex is invisible until someone flips the
/// switch.
///
/// ## Two palettes, not one with `.opacity`
///
/// The light palette is not a computed inversion. `muted`, `accent` and
/// `highlight` are re-tuned for WCAG-AA on white (the dark-theme mid-grays are
/// washed out there), so deriving them at runtime would quietly lose that.
struct AppColors: Equatable, Sendable {
    /// App background (scaffold).
    let bg: Color
    /// Slightly raised surface (cards, sheets, the filter-tab track).
    let surface: Color
    /// Hairline borders / dividers.
    let border: Color
    /// Primary foreground text.
    let text: Color
    /// Secondary / de-emphasized text.
    let muted: Color
    /// Tertiary text — slightly more prominent than ``muted``.
    let muted2: Color
    /// Brand accent (links, active states, primary buttons).
    let accent: Color
    /// Foreground painted on top of ``accent``.
    let onAccent: Color
    /// Code / file paths inside agent messages.
    let highlight: Color
    /// Success state (✓ tool results, `online` presence).
    let success: Color
    /// Error / destructive state.
    let error: Color
    /// Warning state (relay offline / `reconnecting…`).
    let warning: Color
    /// "Working" — a session mid-turn. Deliberately a *different* blue from
    /// ``accent``: a tile can be selected and working at the same time.
    let working: Color
    /// Background of inline / block code.
    let codeBg: Color
    /// User chat bubble background.
    let userBubble: Color
    /// Model badge background.
    let modelBadgeBg: Color
    /// Model badge border.
    let modelBadgeBorder: Color
    /// Border for a denied tool-call card.
    let denyBorder: Color
    /// Text-field fill.
    let inputFill: Color
    /// Resting color of monospace body text. Not `text`: the Flutter theme
    /// uses a slightly dimmed `0xFFE6E6E6` in dark so long transcripts do not
    /// glare (`AppTypography.fromColors(monoColor:)`).
    let monoText: Color

    /// Dark palette — the product's default look.
    static let dark = AppColors(
        bg: Color(hex: 0x000000),
        surface: Color(hex: 0x0A0A0A),
        border: Color(hex: 0x1A1A1A),
        text: Color(hex: 0xFFFFFF),
        muted: Color(hex: 0x6B6B6B),
        muted2: Color(hex: 0x8A8A8A),
        accent: Color(hex: 0x00D4FF),
        onAccent: Color(hex: 0x000000),
        highlight: Color(hex: 0x9FE6FF),
        success: Color(hex: 0x6CD28A),
        error: Color(hex: 0xE5484D),
        warning: Color(hex: 0xFFB300),
        working: Color(hex: 0x3FA9F5),
        codeBg: Color(hex: 0x050505),
        userBubble: Color(hex: 0x1A1A1A),
        modelBadgeBg: Color(hex: 0x161616),
        modelBadgeBorder: Color(hex: 0x1F1F1F),
        denyBorder: Color(hex: 0x2A2A2A),
        inputFill: Color(hex: 0x0E0E0E),
        monoText: Color(hex: 0xE6E6E6)
    )

    /// Light palette — foreground tints tuned for AA contrast on white.
    static let light = AppColors(
        bg: Color(hex: 0xFFFFFF),
        surface: Color(hex: 0xF4F4F5),
        border: Color(hex: 0xDADADD),
        text: Color(hex: 0x0A0A0A),
        muted: Color(hex: 0x565656),
        muted2: Color(hex: 0x424242),
        accent: Color(hex: 0x0077A3),
        onAccent: Color(hex: 0xFFFFFF),
        highlight: Color(hex: 0x005F82),
        success: Color(hex: 0x1E7A41),
        error: Color(hex: 0xC42026),
        warning: Color(hex: 0x9A6300),
        working: Color(hex: 0x1A6CB0),
        codeBg: Color(hex: 0xF0F0F0),
        userBubble: Color(hex: 0xEAEAEC),
        modelBadgeBg: Color(hex: 0xEDEDEF),
        modelBadgeBorder: Color(hex: 0xD7D7DA),
        denyBorder: Color(hex: 0xC9C9CD),
        inputFill: Color(hex: 0xF0F0F2),
        monoText: Color(hex: 0x1A1A1A)
    )
}

extension Color {
    /// `0xRRGGBB`, opaque. Internal on purpose: only the palettes above may
    /// call it. A screen that reaches for a raw hex has found a missing token.
    fileprivate init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
