import SwiftUI

/// The 3-step wizard (spec 08 §5).
///
/// Reached only as a whole-app phase from `RootShell` — never pushed, never
/// presented. `finish` is called on **finish or skip**; the shell owns what
/// happens next (`BootCoordinator.completeOnboarding()`).
struct OnboardingScreen: View {
    /// Called on finish **or skip**. The shell owns where that goes.
    let finish: () -> Void

    @State private var model = OnboardingModel()
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            theme.colors.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                StepIndicator(step: model.step)
                steps
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: AppMetrics.onboardingMaxWidth)
        }
        // Matches `animateToPage(220ms, easeInOut)` (`onboarding_page.dart:26-36`).
        .animation(.easeInOut(duration: 0.22), value: model.step)
        .onChange(of: model.isComplete) { _, done in
            // `isComplete` latches, so this fires once. The Flutter page needed
            // a post-frame callback and a `_lastObserved` comparison to get the
            // same guarantee (spec 08 §5.5).
            if done { finish() }
        }
        .screenModel(model)
    }

    /// A `switch`, not a `TabView(.page)`.
    ///
    /// Two reasons. Swiping between steps is **disabled** in the original
    /// (`physics: NeverScrollableScrollPhysics`, `onboarding_page.dart:68`) and
    /// a paged `TabView` would hand it back. And a `TabView` builds every page
    /// up front, which would start the camera while the user is still reading
    /// the welcome text.
    @ViewBuilder
    private var steps: some View {
        switch model.step {
        case .welcome:
            WelcomeStepView(onNext: model.next)
                .transition(Self.stepTransition)
        case .relay:
            RelayStepView(model: model)
                .transition(Self.stepTransition)
        case .pair:
            PairStepView(model: model)
                .transition(Self.stepTransition)
        }
    }

    /// Directionally fixed: the page always slides in from the trailing edge.
    /// `Back` therefore animates the same way `Continue` does, which is what
    /// the Flutter `animateToPage` produced too — it drives the controller, not
    /// a direction-aware transition.
    private static let stepTransition = AnyTransition.asymmetric(
        insertion: .move(edge: .trailing).combined(with: .opacity),
        removal: .move(edge: .leading).combined(with: .opacity)
    )
}

/// One 3pt bar per step, full width, 4pt gaps; bars at index ≤ the current step
/// are `accent`, the rest `border` (`onboarding_page.dart:100-129`).
struct StepIndicator: View {
    let step: OnboardingStep

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { each in
                Capsule()
                    .fill(each.rawValue <= step.rawValue ? theme.colors.accent : theme.colors.border)
                    .frame(height: 3)
            }
        }
        .padding(.horizontal, AppMetrics.gutter)
        .padding(.top, 16)
        .padding(.bottom, 8)
        .animation(.easeInOut(duration: 0.22), value: step)
        // One element: "Step 2 of 3" is the whole meaning, and three unlabelled
        // bars are three unlabelled images to VoiceOver.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step.rawValue + 1) of \(OnboardingStep.allCases.count)")
    }
}
