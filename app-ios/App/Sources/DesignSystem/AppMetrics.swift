import CoreGraphics

/// Geometry constants that appear in more than one screen of spec 08.
///
/// Not a general spacing scale — this is deliberately a short list of the
/// values the spec names by number, so two screens cannot round the same
/// measurement differently. One-off geometry stays inline in the screen that
/// owns it.
enum AppMetrics {
    // Radii
    /// Filter-tab track and pill segments (spec 08 §7.3).
    static let radiusPill: CGFloat = 10
    /// Message bubbles, cards (§8.5).
    static let radiusBubble: CGFloat = 12
    /// Bottom sheets pushed from the chat (§8.11).
    static let radiusSheetSmall: CGFloat = 16
    /// Bottom sheets pushed from pairing / Home (§6.4).
    static let radiusSheet: CGFloat = 20
    /// QR viewfinder frame (§6.2).
    static let radiusViewfinder: CGFloat = 24

    // Hairlines and bars
    /// Divider / border thickness. 1pt, not `1 / displayScale`: the Flutter
    /// design draws a visible 1pt hairline and a sub-pixel one disappears
    /// against `bg` in dark mode.
    static let hairline: CGFloat = 1
    /// Left bar on a selected session tile (§7.6).
    static let selectionBar: CGFloat = 3

    // Named sizes from the spec
    /// Presence dot diameter (§7.6.1).
    static let presenceDot: CGFloat = 10
    /// Chat top bar height (§8.2). Fixed, not a `NavigationBar`.
    static let chatBarHeight: CGFloat = 56
    /// Master column width in the tablet split (§11.1).
    static let masterColumnWidth: CGFloat = 360
    /// Max width of the centered onboarding column (§5.1).
    static let onboardingMaxWidth: CGFloat = 460
    /// Max width of a user bubble (§8.5).
    static let userBubbleMaxWidth: CGFloat = 300

    // Standard insets
    /// Horizontal inset of list rows and section headers.
    static let gutter: CGFloat = 20
    /// Horizontal inset inside sheets and the composer.
    static let sheetGutter: CGFloat = 16
}
