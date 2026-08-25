import SwiftUI

/// Step 1 — welcome (spec 08 §5.3, `welcome_step.dart:12-78`).
///
/// Static and deliberately un-animated (plan 14 D2). Copy is verbatim; the only
/// substitution is the Lucide `terminal` glyph for the SF Symbol of the same
/// name.
struct WelcomeStepView: View {
    let onNext: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        // `GeometryReader` + `minHeight` is what centres the column the way the
        // Dart's `MainAxisAlignment.center` does — a bare `ScrollView` sizes to
        // its content and pins it to the top. `minHeight`, not `height`: at
        // extraLarge text on a small phone this column is taller than the
        // screen and must be allowed to scroll instead of pushing
        // `Get started` off the bottom edge.
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Image(systemName: "terminal")
                        .font(.system(size: 64, weight: .light))
                        .foregroundStyle(theme.colors.accent)
                        .accessibilityHidden(true)
                        .padding(.bottom, 32)

                    Text("Remote Pi")
                        .font(theme.type.brand(24, weight: .semibold))
                        .tracking(-0.5)
                        .foregroundStyle(theme.colors.text)
                        .padding(.bottom, 8)

                    Text("Control your Pi agent from anywhere")
                        .font(theme.type.mono(13))
                        .foregroundStyle(theme.colors.muted)
                        .padding(.bottom, 28)

                    Text(
                        "Pair this app with the Pi running on your computer "
                        + "(Mac, Linux, or Windows) so you can chat with it even "
                        + "when you're away from home."
                    )
                    .font(theme.type.mono(12))
                    .foregroundStyle(theme.colors.muted)
                    .lineSpacing(6)
                    .padding(.bottom, 40)

                    PrimaryButton(title: "Get started", action: onNext)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                .padding(.horizontal, 28)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}
