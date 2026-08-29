import SwiftUI

/// Semantic color tokens for the whole app — the SINGLE source of truth.
///
/// Originally ported 1:1 from `app/lib/ui/core/themes/app_colors.dart`; the
/// 2026-08-29 terminal redesign deliberately DIVERGED from the Flutter values
/// (this client owns its own visual identity now). The token *names* still
/// match the Dart so anyone reading both clients can map them.
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

    /// Dark palette — the product's default look (redesigned 2026-08-29).
    ///
    /// A phosphor terminal, tuned rather than cosplayed: near-black ground
    /// (true #000 makes hairlines invisible on OLED), a green prompt accent,
    /// and semantic colors lifted from the GitHub-dark family because they are
    /// the most battle-tested "status colors on a dark code surface" set in
    /// existence. No scanlines, no glow — type and color do the talking.
    static let dark = AppColors(
        bg: Color(hex: 0x0A0D10),
        surface: Color(hex: 0x11161C),
        border: Color(hex: 0x232C36),
        text: Color(hex: 0xC9D4E3),
        muted: Color(hex: 0x596B7E),
        muted2: Color(hex: 0x8494A7),
        accent: Color(hex: 0x39D353),
        onAccent: Color(hex: 0x0A0D10),
        highlight: Color(hex: 0x79C0FF),
        success: Color(hex: 0x39D353),
        error: Color(hex: 0xF85149),
        warning: Color(hex: 0xE3B341),
        working: Color(hex: 0x39C5CF),
        codeBg: Color(hex: 0x0D1218),
        userBubble: Color(hex: 0x11161C),
        modelBadgeBg: Color(hex: 0x141B22),
        modelBadgeBorder: Color(hex: 0x232C36),
        denyBorder: Color(hex: 0x372E31),
        inputFill: Color(hex: 0x0E1319),
        monoText: Color(hex: 0xC9D4E3)
    )

    /// Light palette — a paper terminal: warm off-white ground, ink text,
    /// green ink accent. Every foreground re-tuned for WCAG-AA on the paper
    /// tone (the dark theme's phosphor values wash out here).
    static let light = AppColors(
        bg: Color(hex: 0xFAF9F5),
        surface: Color(hex: 0xF1EFE8),
        border: Color(hex: 0xDCD8CC),
        text: Color(hex: 0x24292F),
        muted: Color(hex: 0x6E7B70),
        muted2: Color(hex: 0x57606A),
        accent: Color(hex: 0x1A7F37),
        onAccent: Color(hex: 0xFAF9F5),
        highlight: Color(hex: 0x0969DA),
        success: Color(hex: 0x1A7F37),
        error: Color(hex: 0xCF222E),
        warning: Color(hex: 0x9A6700),
        working: Color(hex: 0x1B7C8C),
        codeBg: Color(hex: 0xF1EFE8),
        userBubble: Color(hex: 0xF1EFE8),
        modelBadgeBg: Color(hex: 0xECE9E0),
        modelBadgeBorder: Color(hex: 0xDCD8CC),
        denyBorder: Color(hex: 0xE0C9BE),
        inputFill: Color(hex: 0xF3F1EA),
        monoText: Color(hex: 0x24292F)
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
