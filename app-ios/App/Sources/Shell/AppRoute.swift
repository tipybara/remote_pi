import Observation
import RemotePiProtocol
import SwiftUI

/// The route table (spec 08 §1, `app_router.dart:212-405`).
///
/// | Flutter path | Here |
/// |---|---|
/// | `/boot`, `/sync-required`, `/onboarding` | `BootCoordinator.Phase` — root states, not stack entries |
/// | `/home` | the stack root / the sidebar column |
/// | `/chat` | ``AppRoute/chat(_:)`` pushed on compact; the detail column on regular |
/// | `/pair` | ``AppRoute/pair`` — a full-screen push in both classes |
/// | `/settings` | ``AppRoute/settings`` pushed on compact; a sheet on regular (spec 08 §9) |
/// | `/session` (detail branch) | no equivalent — SwiftUI's split view *is* the branch |
///
/// The three boot routes are deliberately **not** cases here. They are
/// mutually exclusive whole-app states with a sticky redirect, and modelling
/// them as pushable routes is what lets something push `/home` on top of the
/// sync gate.
///
/// A route carries a ``SessionKey`` — never a title, never an index. Pushing
/// `.chat(key)` twice with the same key is the same destination; SwiftUI's
/// `Hashable` path does the right thing because `SessionKey` hashes on the
/// peer's raw bytes plus the room id.
enum AppRoute: Hashable, Sendable {
    /// The chat for one session. Compact only — on regular the chat is the
    /// detail column and is driven by ``SessionSelection``, not by the path.
    case chat(SessionKey)
    /// QR pairing. Reachable from Home's empty state, Settings, and the
    /// chat's revoked banner.
    case pair
    /// Settings. On regular width, present ``AppNavigator/settingsSheet``
    /// instead of pushing this.
    case settings
}

/// Owns the navigation stack. Injected into the environment by `RootShell`.
///
/// ## Why an object rather than `@State var path` in the shell
///
/// Three screens push `/pair` (Home's empty state, Settings, the chat's
/// revoked banner) and two of them can be inside the *detail* column on
/// tablet, where a local `@State` path would push the chat's own stack and
/// bury the pairing flow in a 360pt-wide pane. One navigator, read from the
/// environment, means "go pair" means the same thing everywhere.
@MainActor
@Observable
final class AppNavigator {
    /// The compact-width stack. Empty == Home.
    var path: [AppRoute] = []

    /// Regular-width Settings presentation (spec 08 §9: tablet shows the same
    /// page as a 92%-height sheet).
    var settingsSheet = false

    /// Push, refusing an exact duplicate of the top entry so a double-tap
    /// cannot stack two identical chats.
    func push(_ route: AppRoute) {
        guard path.last != route else { return }
        path.append(route)
    }

    func pop() {
        guard !path.isEmpty else { return }
        path.removeLast()
    }

    func popToRoot() {
        path.removeAll()
    }

    /// Settings: a push on phone, a sheet on tablet.
    func openSettings(layout: LayoutClass) {
        switch layout {
        case .compact: push(.settings)
        case .split: settingsSheet = true
        }
    }

    /// Pairing is a full-screen push in both layouts — it owns the camera and
    /// must not share the screen with a chat.
    func openPairing() {
        settingsSheet = false
        push(.pair)
    }
}
