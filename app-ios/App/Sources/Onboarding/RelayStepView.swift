import SwiftUI

/// Step 2 — server configuration (spec 08 §5.4), HIG edition.
///
/// Single-server framing (redesigned 2026-08-26): the app dials ONE server,
/// and this build ships pointed at the release server. The step therefore
/// defaults to "nothing to decide" — the default row is pre-selected with its
/// address visible — and the custom URL lives behind a disclosure. Expanding
/// the disclosure IS choosing `.custom`; collapsing it returns to the default.
/// The two-radio-cards layout this replaces made the server look like an open
/// question every user had to answer.
///
/// The honesty note survives the redesign in the disclosure's footer: the
/// relay sees message plaintext (`PROTOCOL.md`), so self-hosting is a real
/// privacy decision, not an aesthetic one.
struct RelayStepView: View {
    @Bindable var model: OnboardingModel

    @Environment(\.theme) private var theme
    @FocusState private var urlFocused: Bool

    private var usesCustom: Binding<Bool> {
        Binding(
            get: { model.flow.relayChoice == .custom },
            set: { expanded in
                model.setRelayChoice(expanded ? .custom : .community)
                if expanded { urlFocused = true }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    defaultServerRow
                    DisclosureGroup("Use My Own Server", isExpanded: usesCustom) {
                        customField
                    }
                } header: {
                    Text("Server")
                } footer: {
                    footer
                }
                .listRowBackground(theme.colors.surface)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .scrollBounceBehavior(.basedOnSize)

            HStack(spacing: 12) {
                Button("Back", action: model.back)
                    .buttonStyle(.bordered)
                Button("Continue") {
                    urlFocused = false
                    model.next()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canContinueFromRelay)
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, AppMetrics.gutter)
            .padding(.vertical, 12)
        }
        .navigationTitle("Server")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var defaultServerRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Remote Pi Server")
                Text(model.communityRelayURL)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if model.flow.relayChoice == .community {
                Image(systemName: "checkmark")
                    .foregroundStyle(theme.colors.accent)
                    .fontWeight(.semibold)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.setRelayChoice(.community) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(model.flow.relayChoice == .community ? .isSelected : [])
    }

    @ViewBuilder
    private var customField: some View {
        TextField("https://my-relay.example.com", text: $model.customRelayURL)
            .font(.callout.monospaced())
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .textContentType(.URL)
            .submitLabel(.continue)
            .focused($urlFocused)
            .onSubmit {
                // The keyboard's Continue can fire with an invalid URL;
                // `OnboardingFlow.advance()` re-validates and refuses, which
                // is why that check is not dead code.
                model.next()
            }

        if let error = model.flow.customRelayError {
            Text(error)
                .font(.footnote)
                .foregroundStyle(theme.colors.error)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if model.flow.relayChoice == .custom {
            // Empty is not an error — it means "use the default". Saying so
            // beats a blank field the user is unsure about.
            Text(
                "The server relays traffic between this device and your Mac and can "
                    + "read message contents — running your own gives you full control. "
                    + "Leave the field empty to use the default."
            )
        } else {
            Text("The app connects through a single server. You can change it later in Settings.")
        }
    }
}
