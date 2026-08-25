import SwiftUI

/// Step 2 — relay configuration (spec 08 §5.4, `relay_step.dart`).
///
/// Card order is load-bearing: **self-hosted first**, carrying the
/// `recommended` badge. The relay sees plaintext (see `PROTOCOL.md`), so
/// recommending the one the user controls is the product's honest position, not
/// a layout accident. Do not reorder these to put the convenient option first.
struct RelayStepView: View {
    @Bindable var model: OnboardingModel

    @Environment(\.theme) private var theme
    @FocusState private var urlFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Choose a relay")
                        .font(theme.type.mono(16, weight: .semibold))
                        .foregroundStyle(theme.colors.text)
                        .padding(.top, 24)
                        .padding(.bottom, 6)
                    Text("Where the app and your PC meet.")
                        .font(theme.type.mono(11))
                        .foregroundStyle(theme.colors.muted)
                        .padding(.bottom, 24)

                    customCard
                        .padding(.bottom, 12)
                    communityCard
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, AppMetrics.gutter)
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)

            HStack(spacing: 12) {
                SecondaryButton(title: "Back", action: model.back)
                    .frame(width: 96)
                PrimaryButton(
                    title: "Continue",
                    isEnabled: model.canContinueFromRelay
                ) {
                    urlFocused = false
                    model.next()
                }
            }
            .padding(.horizontal, AppMetrics.gutter)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Cards

    private var customCard: some View {
        RelayCard(
            title: "Use my own server",
            description: "Self-hosted. Best privacy.",
            badge: "recommended",
            footer: nil,
            isSelected: model.flow.relayChoice == .custom,
            onTap: { model.setRelayChoice(.custom) }
        ) {
            // Revealed only while the card is selected, matching
            // `relay_step.dart:299-348`.
            if model.flow.relayChoice == .custom {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("https://my-relay.com", text: $model.customRelayURL)
                        .font(theme.type.mono(12))
                        .foregroundStyle(theme.colors.text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .submitLabel(.continue)
                        .focused($urlFocused)
                        .onSubmit {
                            // The keyboard's Continue can fire with an invalid
                            // URL; `OnboardingFlow.advance()` re-validates and
                            // refuses, which is why that check is not dead code.
                            model.next()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(theme.colors.inputFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(
                                    model.flow.customRelayError != nil
                                        ? theme.colors.error
                                        : (urlFocused ? theme.colors.accent : theme.colors.border),
                                    lineWidth: AppMetrics.hairline
                                )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .accessibilityLabel("Relay URL")

                    if let error = model.flow.customRelayError {
                        Text(error)
                            .font(theme.type.mono(10))
                            .foregroundStyle(theme.colors.error)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        // Empty is not an error — it means "use the default".
                        // Saying so beats a blank field the user is unsure about.
                        Text("Leave empty to use the community relay.")
                            .font(theme.type.mono(10))
                            .foregroundStyle(theme.colors.muted)
                    }
                }
                .padding(.top, 12)
                .padding(.leading, 26)
            }
        }
    }

    private var communityCard: some View {
        RelayCard(
            title: "Community relay",
            description: "Hosted by us. Quick to start.",
            badge: nil,
            footer: model.communityRelayURL,
            isSelected: model.flow.relayChoice == .community,
            onTap: { model.setRelayChoice(.community) }
        ) {
            EmptyView()
        }
    }
}

/// One radio card. Shared by both options so the selected border (1.5pt accent)
/// and the unselected one (1pt border) cannot drift apart.
struct RelayCard<Extra: View>: View {
    let title: String
    let description: String
    let badge: String?
    let footer: String?
    let isSelected: Bool
    let onTap: () -> Void
    @ViewBuilder var extra: () -> Extra

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "smallcircle.filled.circle" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected ? theme.colors.accent : theme.colors.muted)
                    .accessibilityHidden(true)
                Text(title)
                    .font(theme.type.mono(13, weight: .semibold))
                    .foregroundStyle(theme.colors.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let badge {
                    Text(badge)
                        .font(theme.type.mono(9, weight: .semibold))
                        .foregroundStyle(theme.colors.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(
                            theme.colors.accent.opacity(0.15),
                            in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                        )
                }
            }
            Text(description)
                .font(theme.type.mono(11))
                .foregroundStyle(theme.colors.muted)
                .lineSpacing(4)
                .padding(.top, 8)
                .padding(.leading, 26)
            if let footer {
                Text(footer)
                    .font(theme.type.mono(10))
                    .foregroundStyle(theme.colors.muted)
                    .padding(.top, 6)
                    .padding(.leading, 26)
            }
            extra()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(theme.colors.bg)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    isSelected ? theme.colors.accent : theme.colors.border,
                    lineWidth: isSelected ? 1.5 : AppMetrics.hairline
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        // A `Button` wrapper would swallow taps meant for the URL field inside
        // `extra`. A tap gesture on the card leaves the field interactive.
        .onTapGesture(perform: onTap)
        .animation(.easeInOut(duration: 0.12), value: isSelected)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
