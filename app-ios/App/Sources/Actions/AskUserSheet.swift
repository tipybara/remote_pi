import RemotePiProtocol
import SwiftUI

// ============================================================================
// `ask_user` modal — spec 08 §8.13.
//
// The chat screen owns one `AskUserModel`, feeds it inbound frames, and
// attaches the modal:
//
//     @State private var askUser = AskUserModel()
//     ...
//     .askUserModal(askUser)
//     .task(id: session) {
//         askUser.bind(to: actions, session: session)
//         for await request in app.extensionUIRequests(for: session) {
//             askUser.receive(request)
//         }
//     }
//
// It is a `fullScreenCover`, not a sheet: in Flutter it is a full-screen modal
// layered above the chat `Scaffold` in a `Stack` and it is purely reactive —
// it leaves the tree when the pending request clears. A `.sheet` would let the
// user swipe it away, and a swipe that merely hides the modal leaves pi-ask
// blocked on the desktop until its 10-minute TTL expires.
// ============================================================================

extension View {
    /// Presents the `ask_user` modal whenever `model` holds an open request.
    func askUserModal(_ model: AskUserModel) -> some View {
        modifier(AskUserModalPresenter(model: model))
    }
}

private struct AskUserModalPresenter: ViewModifier {
    let model: AskUserModel

    func body(content: Content) -> some View {
        content.fullScreenCover(
            isPresented: Binding(
                get: { model.form != nil },
                set: { isPresented in
                    // Any dismissal that is not our own `clear()` must send
                    // the cancel frame (§8.13: "a dismissal must send the
                    // cancel frame, never just disappear"). `cancel()` is a
                    // no-op once the form is gone, so the close button — which
                    // cancels and then clears — cannot double-send.
                    if !isPresented { Task { await model.cancel() } }
                }
            )
        ) {
            AskUserModalContent(model: model)
        }
    }
}

private struct AskUserModalContent: View {
    let model: AskUserModel
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().overlay(theme.colors.border)
            content(for: model.form)
            footer
        }
        .background(theme.colors.bg)
        // Question ids repeat across flows ("goal" is the canonical one), so a
        // replaced request must get fresh view state as well as a fresh form —
        // this is the Flutter `ValueKey(uiRequest.id)` in SwiftUI form.
        .id(model.form?.request.id ?? "")
        .onDisappear { model.deactivate() }
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                Task { await model.cancel() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.colors.muted)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.isSubmitting)
            .accessibilityLabel("Cancel")

            Text(model.form?.title ?? "")
                .font(theme.type.mono(14, weight: .semibold))
                .foregroundStyle(theme.colors.text)
                .lineLimit(2)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(minHeight: AppMetrics.chatBarHeight)
    }

    @ViewBuilder
    private func content(for form: AskForm?) -> some View {
        if let form {
            ScrollView {
                if form.isRich {
                    richBody(form)
                } else {
                    degradedBody(form)
                }
            }
            .scrollDismissesKeyboard(.interactively)
        } else {
            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if let note = model.footerNote {
                Text(noteText(note))
                    .font(theme.type.mono(12))
                    .foregroundStyle(noteColor(note))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                SecondaryButton(title: "Cancel", isEnabled: !model.isSubmitting) {
                    Task { await model.cancel() }
                }
                if model.isSubmitting {
                    // The filled button carries the spinner in place of its
                    // label, so the row does not change width mid-submit.
                    PrimaryButton(title: "Submit", isEnabled: false, isBusy: true) {}
                } else {
                    PrimaryButton(title: "Submit", isEnabled: model.isSubmitEnabled) {
                        Task { await model.submit() }
                    }
                }
            }
        }
        .padding(.horizontal, AppMetrics.sheetGutter)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theme.colors.border)
                .frame(height: AppMetrics.hairline)
        }
    }

    private func noteText(_ note: AskUserModel.FooterNote) -> String {
        switch note {
        case .error(let message), .awaiting(let message): message
        }
    }

    private func noteColor(_ note: AskUserModel.FooterNote) -> Color {
        switch note {
        case .error: theme.colors.error
        case .awaiting: theme.colors.muted2
        }
    }

    // MARK: - Rich (pi-ask) body

    private func richBody(_ form: AskForm) -> some View {
        LazyVStack(alignment: .leading, spacing: 24) {
            ForEach(form.questions, id: \.id) { question in
                questionBlock(form, question)
            }
        }
        .padding(.horizontal, AppMetrics.sheetGutter)
        .padding(.top, 8)
        .padding(.bottom, 24)
    }

    private func questionBlock(_ form: AskForm, _ question: AskQuestion) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(question.prompt)
                    .font(theme.type.mono(14, weight: .medium))
                    .foregroundStyle(theme.colors.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                // `required` is advisory in pi-ask and never blocks submission
                // (§8.13, `:279-286`). It is a hint, not a validation gate —
                // enforcing it would deadlock a flow whose required question
                // the user cannot answer.
                if question.required { tag("required", color: theme.colors.accent) }
                if form.isMulti(question) { tag("multi", color: theme.colors.muted) }
            }
            if !question.label.isEmpty, question.label != question.prompt {
                Text(question.label)
                    .font(theme.type.mono(11))
                    .foregroundStyle(theme.colors.muted)
                    .padding(.top, 2)
            }
            VStack(spacing: 8) {
                ForEach(question.options, id: \.value) { option in
                    optionCard(form, question, option)
                }
            }
            .padding(.top, 12)

            TextField(
                "Type your own…",
                text: customBinding(question),
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(theme.type.mono(12.5))
            .lineLimit(1...4)
            .padding(12)
            .background(theme.colors.inputFill)
            .overlay(
                RoundedRectangle(cornerRadius: AppMetrics.radiusPill, style: .continuous)
                    .strokeBorder(theme.colors.border, lineWidth: AppMetrics.hairline)
            )
            .clipShape(RoundedRectangle(cornerRadius: AppMetrics.radiusPill, style: .continuous))
            .disabled(model.isSubmitting)
            .padding(.top, question.options.isEmpty ? 0 : 8)
        }
    }

    private func optionCard(
        _ form: AskForm,
        _ question: AskQuestion,
        _ option: AskOption
    ) -> some View {
        let isSelected = form.isSelected(question, value: option.value)
        let isMulti = form.isMulti(question)
        return Button {
            model.toggle(question, value: option.value)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: glyph(isMulti: isMulti, isSelected: isSelected))
                        .font(.system(size: 17))
                        .foregroundStyle(isSelected ? theme.colors.accent : theme.colors.muted)
                    Text(option.label)
                        .font(theme.type.mono(13, weight: .semibold))
                        .foregroundStyle(theme.colors.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                if let description = option.description, !description.isEmpty {
                    Text(description)
                        .font(theme.type.mono(11.5))
                        .foregroundStyle(theme.colors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        // Indented to clear the checkbox/radio glyph, matching
                        // the Flutter 30pt inset.
                        .padding(.leading, 30)
                        .padding(.top, 4)
                }
                if question.type == .preview,
                   let preview = option.preview, !preview.isEmpty {
                    Text(preview)
                        .font(theme.type.mono(12))
                        .foregroundStyle(theme.colors.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(theme.colors.codeBg)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(theme.colors.border, lineWidth: AppMetrics.hairline)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(isSelected ? theme.colors.accent.opacity(0.10) : theme.colors.surface)
            .overlay(
                RoundedRectangle(cornerRadius: AppMetrics.radiusPill, style: .continuous)
                    .strokeBorder(
                        isSelected ? theme.colors.accent : theme.colors.border,
                        lineWidth: isSelected ? 1.6 : AppMetrics.hairline
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: AppMetrics.radiusPill, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isSubmitting)
        .accessibilityLabel(option.label)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func glyph(isMulti: Bool, isSelected: Bool) -> String {
        if isMulti { return isSelected ? "checkmark.square.fill" : "square" }
        return isSelected ? "largecircle.fill.circle" : "circle"
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(theme.type.mono(10))
            .foregroundStyle(color)
    }

    // MARK: - Degraded (plain SDK) body

    @ViewBuilder
    private func degradedBody(_ form: AskForm) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if !form.degradedMessage.isEmpty {
                Text(form.degradedMessage)
                    .font(theme.type.mono(13))
                    .foregroundStyle(theme.colors.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch form.method {
            case .select:
                VStack(spacing: 8) {
                    // `request.options` carries **labels**, and the degraded
                    // reply must echo the label back — the bridge maps it to a
                    // value through its per-request table. Sending a value here
                    // lands the answer as free-form text, silently.
                    // Keyed by position: `options` is a plain string array and
                    // two options can legitimately carry the same label.
                    ForEach(Array(form.request.options.enumerated()), id: \.offset) { _, option in
                        degradedOption(form, option)
                    }
                }
            case .input, .editor:
                TextField(
                    form.request.placeholder ?? "",
                    text: textBinding(),
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .font(theme.type.mono(12.5))
                .lineLimit(5...5)
                .padding(12)
                .background(theme.colors.inputFill)
                .overlay(
                    RoundedRectangle(cornerRadius: AppMetrics.radiusPill, style: .continuous)
                        .strokeBorder(theme.colors.border, lineWidth: AppMetrics.hairline)
                )
                .clipShape(
                    RoundedRectangle(cornerRadius: AppMetrics.radiusPill, style: .continuous)
                )
                .disabled(model.isSubmitting)
            case .confirm:
                Text("Please confirm.")
                    .font(theme.type.mono(14, weight: .medium))
                    .foregroundStyle(theme.colors.text)
            default:
                // `notify` never opens this modal — `AskUserModel.receive`
                // consumes it. The lead paragraph above already rendered the
                // message if this ever becomes reachable.
                EmptyView()
            }
        }
        .padding(AppMetrics.sheetGutter)
    }

    private func degradedOption(_ form: AskForm, _ option: String) -> some View {
        let isSelected = form.singleValue == option
        return Button {
            model.setSingleValue(option)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(isSelected ? theme.colors.accent : theme.colors.muted)
                Text(option)
                    .font(theme.type.mono(13))
                    .foregroundStyle(theme.colors.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? theme.colors.accent.opacity(0.10) : theme.colors.surface)
            .overlay(
                RoundedRectangle(cornerRadius: AppMetrics.radiusPill, style: .continuous)
                    .strokeBorder(
                        isSelected ? theme.colors.accent : theme.colors.border,
                        lineWidth: isSelected ? 1.6 : AppMetrics.hairline
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: AppMetrics.radiusPill, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isSubmitting)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Bindings
    //
    // Text fields write through the model rather than binding to the form
    // directly, so the "no edits while submitting" guard lives in one place.

    private func customBinding(_ question: AskQuestion) -> Binding<String> {
        Binding(
            get: { model.form?.custom(for: question) ?? "" },
            set: { model.setCustom($0, for: question) }
        )
    }

    private func textBinding() -> Binding<String> {
        Binding(
            get: { model.form?.text ?? "" },
            set: { model.setText($0) }
        )
    }
}
