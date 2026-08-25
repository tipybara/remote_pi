import Foundation
import Observation
import RemotePiProtocol
import SwiftUI

/// Every user preference that survives process death (spec 08 §12.1).
///
/// Backed by `UserDefaults`, written through on `didSet`, and `@Observable` so
/// a screen that reads `app.preferences.themeMode` re-renders when Settings
/// changes it — no notification, no manual refresh.
///
/// ## What does NOT belong here
///
/// * The **selected session pointer**. It is persisted by the Kit
///   (`SQLiteSessionStore.saveSelectedSession`) as a real `SessionKey`, next
///   to the data it points at. Storing a `"<epk>:<roomId>"` string in defaults
///   is how the Flutter client ended up restoring only half of it
///   (spec 08 §2.3) — both halves or neither.
/// * The **Owner key** (Keychain) and **peer records** (the store).
/// * `HomeFilter`. It survives *within* a run and is deliberately not
///   persisted; it lives on `AppModel.filter`.
///
/// ## Adding a preference
///
/// One `didSet` write, one key constant, a decode that cannot fail. Every
/// getter must map an unknown/legacy stored value to a safe default — a bad
/// string in defaults must never brick the app (that is why `AppFontScale
/// .named` and `HomeGrouping(wire:)` exist).
@MainActor
@Observable
final class AppPreferences {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.themeMode = AppThemeMode(rawValue: defaults.string(forKey: Keys.themeMode) ?? "")
            ?? .system
        self.fontScale = AppFontScale.named(defaults.string(forKey: Keys.fontScale))
        self.hideToolCalls = defaults.bool(forKey: Keys.hideToolCalls)
        self.homeGrouping = HomeGrouping(wire: defaults.string(forKey: Keys.homeGrouping))
        self.onboardingCompleted = defaults.bool(forKey: Keys.onboardingCompleted)
    }

    /// System / Light / Dark (spec 08 §9.2).
    var themeMode: AppThemeMode {
        didSet { defaults.set(themeMode.rawValue, forKey: Keys.themeMode) }
    }

    /// In-app text size. See the rationale in `AppTypography.swift`.
    var fontScale: AppFontScale {
        didSet { defaults.set(fontScale.rawValue, forKey: Keys.fontScale) }
    }

    /// Filters `ToolEvent` rows out of the chat. **Presentation only** — the
    /// events stay in the store, so toggling it back shows the history
    /// (spec 08 §8.1).
    var hideToolCalls: Bool {
        didSet { defaults.set(hideToolCalls, forKey: Keys.hideToolCalls) }
    }

    /// Home's grouping. Persisted by its stable wire string and read *before*
    /// the first list build, so the layout does not snap back for one frame on
    /// cold start (spec 08 §7.4).
    var homeGrouping: HomeGrouping {
        didSet { defaults.set(homeGrouping.wire, forKey: Keys.homeGrouping) }
    }

    /// `true` once the wizard has been finished **or skipped**, and also
    /// force-set at boot when peers already exist — a user who paired in a
    /// pre-onboarding build must not be sent through it (spec 08 §1.1 step 7).
    ///
    /// Reset to `false` when the last pairing is revoked: revoke means start
    /// fresh (spec 08 §9.3).
    var onboardingCompleted: Bool {
        didSet { defaults.set(onboardingCompleted, forKey: Keys.onboardingCompleted) }
    }

    private enum Keys {
        static let themeMode = "prefs.theme_mode"
        static let fontScale = "prefs.font_scale"
        static let hideToolCalls = "prefs.hide_tool_calls"
        static let homeGrouping = "prefs.home_grouping"
        static let onboardingCompleted = "prefs.onboarding_completed"
    }
}

/// How Home nests its rows (spec 08 §7.4).
///
/// The raw value is the **wire string** the Flutter client persists, so the
/// two apps can read each other's preference if they ever share a backup.
/// `init(wire:)` falls back to ``workspace`` for anything unrecognised.
enum HomeGrouping: String, CaseIterable, Codable, Sendable {
    /// Peer header + workspace header. The default.
    case workspace
    /// Peer header only.
    case device
    /// Flat list, no headers.
    case none

    init(wire: String?) {
        self = HomeGrouping(rawValue: wire ?? "") ?? .workspace
    }

    var wire: String { rawValue }

    /// Menu label (spec 08 §7.4).
    var label: String {
        switch self {
        case .workspace: "Device / folder"
        case .device: "Device only"
        case .none: "No grouping"
        }
    }

    /// What the *suppressed* header would have said, handed to the tile so
    /// dropping a header never drops attribution (`_contextLabelFor`,
    /// `home_page.dart:403-416`).
    ///
    /// ```
    /// workspace -> nil
    /// device    -> "<folder>"
    /// none      -> "<device>"  or  "<device> / <folder>"
    /// ```
    func contextLabel(device: String, folder: String) -> String? {
        switch self {
        case .workspace:
            return nil
        case .device:
            return folder.isEmpty ? nil : folder
        case .none:
            if folder.isEmpty { return device.isEmpty ? nil : device }
            return device.isEmpty ? folder : "\(device) / \(folder)"
        }
    }
}
