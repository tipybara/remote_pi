import SwiftUI

// MARK: - Font substitutions (documented, deliberate, dependency-free)
//
// The Flutter client pulls two families:
//
//   `kMonoFamily = 'Courier'`  — app_typography.dart:12, the platform mono
//                                fallback, with a note saying "bundle a real
//                                font here to swap it".
//   `GoogleFonts.inter(...)`   — the brand wordmark ("Remote Pi"), fetched at
//                                runtime by the google_fonts package.
//
// This client ships **no font files and no font dependency**. Substitutions:
//
//   Courier → `Font.Design.monospaced` (SF Mono / New York Mono).
//       SF Mono is metrically tighter and far more legible at 10–13pt than
//       Courier, which is what the Dart comment wanted anyway. Same fixed
//       advance width, so the character budgets copied from the Dart
//       (`_truncate(28)`, `headTruncatedPath(42)`, `_truncateModel(24)`) stay
//       exact.
//
//   Inter → `Font.Design.default` (SF Pro) at `.bold`.
//       Inter is an SF-Pro-shaped neo-grotesque; at wordmark sizes (24–32pt,
//       w700) the two are near-indistinguishable, and downloading a webfont
//       at launch to render four glyphs is not a trade this app should make.
//       The brand face is still funnelled through ONE call — `theme.type
//       .brand(_:)` — so bundling a real Inter later is a one-line change.
//
// If the product later insists on Inter proper: add `Inter-*.ttf` to
// `App/Resources`, list it under `UIAppFonts` in `project.yml`, and change
// `AppTypography.brand` to `Font.custom("Inter", size:)`. Nothing else moves.

/// User-selectable text size (ported from `app_font_scale.dart`).
///
/// ## Why this exists at all
///
/// The design hardcodes point sizes everywhere (12.5pt mono body, 11pt
/// captions, 32pt title), so Dynamic Type does not reach them. Rather than
/// scatter `.dynamicTypeSize` clamps, the scale multiplies every size that
/// goes through ``AppTypography`` — which is every size in the app, because
/// screens are forbidden from calling `Font.system` directly.
///
/// A native client *could* drop this and use real Dynamic Type text styles;
/// that would be a redesign of every fixed size in spec 08, so it is not this
/// plan's decision to make. See the report's "not decided" list.
enum AppFontScale: String, CaseIterable, Codable, Sendable {
    case small
    case standard
    case large
    case extraLarge

    /// Short label for the Settings segmented control.
    var label: String {
        switch self {
        case .small: "Small"
        case .standard: "Default"
        case .large: "Large"
        case .extraLarge: "XL"
        }
    }

    /// Multiplier applied to every text size in the app.
    var factor: CGFloat {
        switch self {
        case .small: 0.9
        case .standard: 1.0
        case .large: 1.15
        case .extraLarge: 1.3
        }
    }

    /// Parse a persisted value. Unknown / legacy / missing → ``standard``, so a
    /// bad stored string can never leave the app with unreadable text.
    static func named(_ raw: String?) -> AppFontScale {
        guard let raw, let value = AppFontScale(rawValue: raw) else { return .standard }
        return value
    }
}

/// Every font the app is allowed to build.
///
/// ## Rule for screen agents
///
/// **Never call `Font.system(...)`, `.font(.body)`, or `Font.custom(...)`.**
/// Call `theme.type.mono(13, weight: .medium)` (or one of the named presets).
/// That is what makes ``AppFontScale`` reach the one-off sizes — which are the
/// majority of the chat — instead of only the three base styles.
struct AppTypography: Equatable, Sendable {
    /// Multiplier from ``AppFontScale``. Baked in here rather than applied as
    /// an environment `TextScaler` because SwiftUI has no equivalent that
    /// touches an explicit `.system(size:)`.
    let scale: CGFloat

    init(scale: CGFloat = 1) {
        self.scale = scale
    }

    // MARK: Families

    /// Monospace at an explicit size — chat text, terminal chrome, paths,
    /// nearly all UI copy (the product's "coding agent" identity).
    func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size * scale, weight: weight, design: .monospaced)
    }

    /// Proportional body text. Rare: only where mono would be genuinely worse
    /// (long prose paragraphs in onboarding / empty states).
    func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size * scale, weight: weight, design: .default)
    }

    /// The brand wordmark — "Remote Pi", and nothing else. Never substitute
    /// ``mono(_:weight:)`` for it and never use it for ordinary titles.
    func brand(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size * scale, weight: weight, design: .default)
    }

    // MARK: Named presets (the Dart `AppTypography` triple)

    /// `mono` — 12.5pt. Chat body, code.
    var body: Font { mono(12.5) }
    /// `monoSmall` — 11pt. Captions, metadata, section headers.
    var caption: Font { mono(11) }
    /// `sansBody` — 14pt.
    var sansBody: Font { sans(14) }
}
