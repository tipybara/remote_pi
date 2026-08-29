import SwiftUI

/// How the user wants the app to look. Persisted by its `rawValue`
/// (`prefs.theme_mode` in the Flutter client — same three names).
enum AppThemeMode: String, CaseIterable, Codable, Sendable {
    case system
    case light
    case dark

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// What to hand `.preferredColorScheme`. `nil` for ``system`` so the OS
    /// keeps control (and so the status bar and sheets follow it too).
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// The resolved design system for one render pass: a palette plus the font
/// builder, already carrying the user's text-size choice.
///
/// Read it, never build it:
///
/// ```swift
/// struct SomeRow: View {
///     @Environment(\.theme) private var theme
///     var body: some View {
///         Text("hello")
///             .font(theme.type.mono(13, weight: .medium))
///             .foregroundStyle(theme.colors.text)
///     }
/// }
/// ```
struct AppTheme: Equatable, Sendable {
    let colors: AppColors
    let type: AppTypography

    /// The default the environment falls back to when a view is rendered
    /// outside ``RemotePiThemeModifier`` — a preview, a test host. Dark,
    /// because that is the product's default look, and a wrong-but-legible
    /// preview beats a crash or an invisible one.
    static let dark = AppTheme(colors: .dark, type: AppTypography())
    static let light = AppTheme(colors: .light, type: AppTypography())

    /// Resolve the palette for a mode against the *system* scheme.
    ///
    /// `system` is the only mode that consults `colorScheme`; the other two
    /// are absolute, which is why the modifier also pins
    /// `preferredColorScheme` — otherwise the app would paint a dark palette
    /// while UIKit-provided chrome (keyboard, share sheet) stayed light.
    static func resolve(
        mode: AppThemeMode,
        systemScheme: ColorScheme,
        fontScale: AppFontScale
    ) -> AppTheme {
        let scheme: ColorScheme = switch mode {
        case .system: systemScheme
        case .light: .light
        case .dark: .dark
        }
        return AppTheme(
            colors: scheme == .dark ? .dark : .light,
            type: AppTypography(scale: fontScale.factor)
        )
    }
}

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue = AppTheme.dark
}

extension EnvironmentValues {
    /// The design system. Injected once, at the root, by
    /// ``View/remotePiTheme(mode:fontScale:)``.
    var theme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}

/// Installs the palette + typography for the whole tree and paints the
/// background, so no screen has to remember `.background(theme.colors.bg)` on
/// its outermost container.
private struct RemotePiThemeModifier: ViewModifier {
    let mode: AppThemeMode
    let fontScale: AppFontScale
    @Environment(\.colorScheme) private var systemScheme

    func body(content: Content) -> some View {
        let theme = AppTheme.resolve(
            mode: mode,
            systemScheme: systemScheme,
            fontScale: fontScale
        )
        return content
            .environment(\.theme, theme)
            .tint(theme.colors.accent)
            .foregroundStyle(theme.colors.text)
            // Terminal redesign: every *system*-font surface — Settings forms,
            // navigation titles, alerts' SwiftUI content, ContentUnavailable
            // fallbacks — renders monospaced too, so screens built from stock
            // components don't read as a different app. Views that set an
            // explicit `theme.type` font are unaffected.
            .fontDesign(.monospaced)
            .background(theme.colors.bg.ignoresSafeArea())
            .preferredColorScheme(mode.preferredColorScheme)
    }
}

extension View {
    /// Root-only. Applied once by `RootShell`; a screen must not re-apply it.
    func remotePiTheme(mode: AppThemeMode, fontScale: AppFontScale) -> some View {
        modifier(RemotePiThemeModifier(mode: mode, fontScale: fontScale))
    }

    /// Preview/testing helper: pin a specific palette without a preference
    /// store. Never call this from app code.
    func remotePiTheme(_ theme: AppTheme) -> some View {
        environment(\.theme, theme)
            .tint(theme.colors.accent)
            .foregroundStyle(theme.colors.text)
            .fontDesign(.monospaced)
            .background(theme.colors.bg.ignoresSafeArea())
    }
}
