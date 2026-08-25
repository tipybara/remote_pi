import SwiftUI

/// Phone-shaped or tablet-shaped (spec 08 §1.2, §11.1).
///
/// ## The rule, and why it is not `width >= 600`
///
/// The Flutter client keys off
/// `MediaQuery.sizeOf(context).shortestSide >= 600` — **`shortestSide`, not
/// `width`** — deliberately. Width alone confuses device class with
/// orientation: a phone in landscape has `width >= 600` and used to be
/// misclassified as a tablet, which put a 360pt master column and a chat side
/// by side on a 390pt-tall screen. `shortestSide` is rotation-invariant, and
/// it still collapses correctly under iPadOS Split View / Slide Over, because
/// `MediaQuery` measures the *window* the app was given, not the physical
/// device.
///
/// The SwiftUI equivalent is the size-class pair, not a raw measurement:
///
/// | Device / state | horizontal | vertical | Here |
/// |---|---|---|---|
/// | iPhone, portrait | compact | regular | ``compact`` |
/// | iPhone, landscape | compact | compact | ``compact`` |
/// | iPhone Pro Max / Plus, landscape | **regular** | compact | ``compact`` |
/// | iPad, any orientation | regular | regular | ``split`` |
/// | iPad, narrow Split View | compact | regular | ``compact`` |
///
/// Row 3 is the whole reason this type exists: a large phone in landscape
/// reports a *regular* horizontal size class, so `horizontalSizeClass ==
/// .regular` alone reintroduces exactly the bug `shortestSide` was chosen to
/// avoid. Requiring **both** classes to be regular is the size-class spelling
/// of "shortestSide >= 600" — a phone in landscape stays a phone.
enum LayoutClass: Hashable, Sendable {
    /// One column, `NavigationStack`, chat is a push.
    case compact
    /// Two columns, chat is the detail pane, selection drives it.
    case split

    static func resolve(
        horizontal: UserInterfaceSizeClass?,
        vertical: UserInterfaceSizeClass?
    ) -> LayoutClass {
        (horizontal == .regular && vertical == .regular) ? .split : .compact
    }
}

/// Reads the current layout class from the environment.
///
/// ```swift
/// @Environment(\.layoutClass) private var layout
/// ```
///
/// Injected by `RootShell`, so a nested view sees the shell's decision rather
/// than re-deriving it from its own (possibly different) size classes — a
/// sheet, for instance, can report classes that do not match the window.
private struct LayoutClassKey: EnvironmentKey {
    static let defaultValue = LayoutClass.compact
}

extension EnvironmentValues {
    var layoutClass: LayoutClass {
        get { self[LayoutClassKey.self] }
        set { self[LayoutClassKey.self] = newValue }
    }
}
