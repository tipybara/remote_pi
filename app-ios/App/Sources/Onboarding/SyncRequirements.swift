import Foundation

/// One numbered card on the Sync Required gate (spec 08 §4).
struct SyncRequirement: Identifiable, Equatable, Sendable {
    /// 1-based, and the *displayed* number. Not an array index — the order is
    /// the instruction order and the user is going to follow it literally.
    let number: Int
    let title: String
    /// The Settings breadcrumb, using `›` exactly as the Dart does.
    let path: String
    let note: String?

    var id: Int { number }

    /// VoiceOver reads `›` as nothing at all, which turns
    /// "Settings › [your name] › iCloud" into one run-on phrase. The steps are
    /// the entire content of this screen, so they get a spoken form.
    var spokenPath: String {
        path
            .replacingOccurrences(of: "\n", with: ", ")
            .replacingOccurrences(of: " › ", with: ", then ")
    }
}

/// The iOS requirement list, verbatim from `sync_required_page.dart:169-180`
/// and pinned by spec 08 §4.
///
/// The Android list is deliberately not ported: this target is iOS-only, and a
/// dead Block Store branch would be copy nobody proofreads.
enum SyncRequirements {
    static let ios: [SyncRequirement] = [
        SyncRequirement(
            number: 1,
            title: "Sign in to iCloud",
            path: "Settings › [your name]",
            note: "If you see \"Sign in to your iPhone\" at the top, tap it."
        ),
        SyncRequirement(
            number: 2,
            title: "Turn on iCloud Keychain",
            path: "Settings › [your name] › iCloud › Passwords and Keychain",
            note: "Toggle \"Sync this iPhone\" on."
        ),
    ]

    /// The "why" paragraph (`sync_required_page.dart:41-44`).
    static let why =
        "Remote Pi keeps your Ed25519 owner key in iCloud Keychain so "
        + "you can switch iPhones or pair your iPad without scanning "
        + "a new QR."

    static let title = "Sync required"
    static let listLabel = "To enable, on this device:"
    static let checkAgain = "Check again"

    /// Shown after a `Check again` that changed nothing.
    ///
    /// Not in the Flutter original, which silently does nothing and leaves the
    /// user tapping a button that looks broken. This gate is the only thing
    /// between the user and an app that cannot start, so "I checked, it is
    /// still off" has to be sayable.
    static let stillUnavailable =
        "Still not available. Finish the steps above, then check again."
}
