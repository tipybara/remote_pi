import RemotePiProtocol
import SwiftUI

/// The one root view. Owns the boot gate, the layout split, the navigator and
/// the selection, and injects all of them into the environment.
///
/// Everything a screen needs is read from the environment:
///
/// ```swift
/// @Environment(AppModel.self) private var app
/// @Environment(AppNavigator.self) private var navigator
/// @Environment(SessionSelection.self) private var selection
/// @Environment(\.theme) private var theme
/// @Environment(\.layoutClass) private var layout
/// ```
///
/// A screen must not construct any of them.
struct RootShell: View {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var horizontal
    @Environment(\.verticalSizeClass) private var vertical

    @State private var boot = BootCoordinator()
    @State private var navigator = AppNavigator()
    @State private var selection = SessionSelection()

    private var layout: LayoutClass {
        .resolve(horizontal: horizontal, vertical: vertical)
    }

    var body: some View {
        phaseBody
            .environment(navigator)
            .environment(selection)
            .environment(\.layoutClass, layout)
            .remotePiTheme(
                mode: app.preferences.themeMode,
                fontScale: app.preferences.fontScale
            )
            .task {
                boot.bind(to: app)
                await boot.start()
            }
    }

    /// The redirect table from spec 08 §1.1. These are whole-app states, not
    /// stack entries — see `AppRoute.swift`.
    @ViewBuilder
    private var phaseBody: some View {
        switch boot.phase {
        case .booting:
            BootSplashScreen()
        case .syncRequired(let reason):
            // Sticky. Nothing else may be presented over or instead of this
            // until `recheckIdentity()` reports something other than
            // "cannot sync" (spec 08 §4).
            SyncRequiredScreen(reason: reason) {
                await boot.recheckIdentity()
            }
        case .onboarding:
            OnboardingScreen {
                boot.completeOnboarding()
            }
        case .failed(let message):
            BootFailureScreen(message: message) {
                await boot.recheckIdentity()
            }
        case .home:
            homeShell
        }
    }

    @ViewBuilder
    private var homeShell: some View {
        switch layout {
        case .compact:
            CompactShell()
        case .split:
            SplitShell()
        }
    }
}

/// Phone (and any window narrow enough to be phone-shaped): one column, native
/// back and edge-swipe, chat pushed on top of Home (spec 08 §1.2).
private struct CompactShell: View {
    @Environment(AppNavigator.self) private var navigator
    @Environment(SessionSelection.self) private var selection

    var body: some View {
        @Bindable var navigator = navigator
        NavigationStack(path: $navigator.path) {
            HomeScreen()
                .navigationDestination(for: AppRoute.self) { route in
                    destination(route)
                }
        }
    }

    @ViewBuilder
    private func destination(_ route: AppRoute) -> some View {
        switch route {
        case .chat(let key):
            // `.id` on the session key: pushing a different session gives the
            // screen a new identity, so its `@State` model and its `.task` are
            // rebuilt instead of re-subscribed (see rule 4 in
            // `ScreenModel.swift`).
            ChatScreen(session: key)
                .id(key.storageKey)
        case .pair:
            PairingScreen()
        case .settings:
            SettingsScreen(isEmbedded: false)
        }
    }
}

/// Tablet: a fixed master column and a detail pane driven by
/// ``SessionSelection`` — no navigation happens when a row is tapped
/// (spec 08 §1.2, §11.1).
///
/// ## Divergences from the Flutter shell, on purpose
///
/// * The Flutter version hand-rolls the split (`Row` + a 1pt `VerticalDivider`
///   + `Expanded`) and then has to undo its own safe-area damage with
///   `MediaQuery.removePadding(removeRight:)` on the master and
///   `removeLeft:` on the detail — otherwise, on a notched device in
///   landscape, each pane reads the *full screen* insets and pads the edge
///   facing the divider, producing a phantom gutter. `NavigationSplitView`
///   insets each column against the window it actually occupies, so that
///   entire fix is unnecessary here. Do not re-add it.
/// * `isZeroState` (no peers, or no visible sessions) collapses the Flutter
///   split to a single pane. Here the sidebar simply fills the window when
///   there is nothing to show a detail for, which is what
///   `.navigationSplitViewStyle(.balanced)` plus a placeholder detail gives —
///   with no extra state to keep in sync and no single→split flash on the
///   common cold-start path.
private struct SplitShell: View {
    @Environment(AppNavigator.self) private var navigator
    @Environment(SessionSelection.self) private var selection

    var body: some View {
        @Bindable var navigator = navigator
        NavigationSplitView {
            HomeScreen()
                .navigationSplitViewColumnWidth(AppMetrics.masterColumnWidth)
        } detail: {
            NavigationStack(path: $navigator.path) {
                detailRoot
                    .navigationDestination(for: AppRoute.self) { route in
                        switch route {
                        case .chat(let key):
                            ChatScreen(session: key).id(key.storageKey)
                        case .pair:
                            PairingScreen()
                        case .settings:
                            SettingsScreen(isEmbedded: false)
                        }
                    }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $navigator.settingsSheet) {
            // Its own stack so the embedded page keeps a title bar and a close
            // button; detents belong to this call site, never to the sheet's
            // content (see `SheetScaffold`).
            NavigationStack {
                SettingsScreen(isEmbedded: true)
            }
            .presentationDetents([.fraction(0.92)])
            .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private var detailRoot: some View {
        if let selected = selection.current {
            // Keying on the session makes switching sessions tear down the old
            // chat model and build a fresh one, instead of mutating a live one
            // under an in-flight stream (spec 08 §11.2).
            ChatScreen(session: selected.key)
                .id(selected.key.storageKey)
        } else {
            DetailPlaceholder()
        }
    }
}

/// `/boot` — a centered 24×24 spinner in `accent`, stroke 2. No text, no logo
/// (spec 08 §3).
struct BootSplashScreen: View {
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            theme.colors.bg.ignoresSafeArea()
            ProgressView()
                .controlSize(.regular)
                .tint(theme.colors.accent)
        }
    }
}

/// Boot threw for a reason that is not "iCloud is off". Deliberately separate
/// from the sync gate so the copy never blames the wrong thing.
struct BootFailureScreen: View {
    let message: String
    let retry: () async -> Void

    @Environment(\.theme) private var theme
    @State private var isRetrying = false

    var body: some View {
        ZStack {
            theme.colors.bg.ignoresSafeArea()
            EmptyStateView(
                systemImage: "exclamationmark.triangle",
                title: "Could not start",
                message: message
            ) {
                PrimaryButton(title: "Try again", isBusy: isRetrying) {
                    Task {
                        isRetrying = true
                        await retry()
                        isRetrying = false
                    }
                }
                .frame(maxWidth: 240)
            }
        }
    }
}

/// The tablet detail pane with nothing selected (spec 08 §11.2).
struct DetailPlaceholder: View {
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            theme.colors.bg.ignoresSafeArea()
            EmptyStateView(
                systemImage: "bubble.left.and.bubble.right",
                title: "Select a session",
                message: "Pick a session on the left to open its chat.",
                iconOpacity: 0.4
            )
        }
    }
}
