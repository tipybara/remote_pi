import RemotePiProtocol
import SwiftUI

// ============================================================================
// Quick Actions sheet — spec 08 §8.11.
//
// Present it from the chat's ⚙ button:
//
//     .sheet(isPresented: $showsQuickActions) {
//         QuickActionsSheet(session: session)
//     }
//
// Everything else — the model picker sub-sheet, the New Context confirmation,
// dismissing when the tablet's selected session changes — is inside. The chat
// screen owns one boolean.
// ============================================================================

struct QuickActionsSheet: View {
    let session: SessionKey

    @Environment(AppModel.self) private var app
    @Environment(SessionSelection.self) private var selection
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var model = QuickActionsModel()
    @State private var showsModelPicker = false

    var body: some View {
        SheetScaffold(title: "Quick actions") {
            VStack(spacing: 0) {
                if model.isOffline { offlineNote }
                if let message = model.errorMessage { errorNote(message) }

                divider
                compactRow
                divider
                newContextRow
                divider
                modelRow
                divider
                thinkingRow
            }
            .padding(.bottom, 18)
        }
        // §8.11: chat sheets use the 16pt corner, not the 20pt one Home and
        // pairing use. Applied here rather than in `SheetScaffold`, which is
        // shared with those screens.
        .presentationCornerRadius(AppMetrics.radiusSheetSmall)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        // The detail pane can swap under an open sheet on tablet (§11.2).
        .dismissOnSessionChange(selection)
        .task { model.bind(to: AppModelSessionActions(app: app), session: session) }
        .onChange(of: model.didClearContext) { _, cleared in
            // The context is gone and the transcript is empty; there is
            // nothing left on this sheet to look at.
            if cleared { dismiss() }
        }
        .alert(
            "Clear this session's context?",
            isPresented: Binding(
                get: { model.isConfirmingNewContext },
                set: { if !$0 { model.cancelNewContext() } }
            )
        ) {
            Button("Cancel", role: .cancel) { model.cancelNewContext() }
            Button("Clear context", role: .destructive) {
                Task { await model.confirmNewContext() }
            }
        } message: {
            // Spec §8.11 quotes the Flutter copy ("Start a new session?"), but
            // §13.4 rules that the plan-61 wording wins on iOS — the frame
            // clears this session's context and keeps its `session_id`.
            // Calling it a new session here would contradict Home's `+`, which
            // really does create one.
            Text(
                "This clears the Pi-side conversation history for this session. "
                + "The current thread cannot be resumed. The session itself stays open."
            )
        }
        .sheet(isPresented: $showsModelPicker) {
            ModelPickerSheet(session: session, quickActions: model)
        }
    }

    // MARK: - Rows

    private var compactRow: some View {
        ActionRow(
            systemImage: "arrow.down.right.and.arrow.up.left",
            label: "Compact context",
            subtitle: "Summarize old turns to free room.",
            isBusy: model.isBusy(.sessionCompact),
            isEnabled: !model.isAnyActionRunning
        ) {
            Task {
                // Success closes the sheet with no toast: compacting is quiet
                // and frequent (§8.11). Failure leaves the sheet up with the
                // message inline so the next tap retries.
                if await model.compact() { dismiss() }
            }
        }
    }

    private var newContextRow: some View {
        ActionRow(
            systemImage: "sparkles",
            // "New Context", not "New session": `session_new` wipes this
            // session's context in the same process and keeps its id
            // (§13.4). The genuinely-new-session flow is Home's `+`.
            label: "New Context",
            subtitle: "Clears the conversation on the Pi.",
            isBusy: model.isBusy(.sessionNew),
            isEnabled: !model.isAnyActionRunning
        ) {
            model.requestNewContext()
        }
    }

    private var modelRow: some View {
        Button {
            showsModelPicker = true
        } label: {
            HStack(spacing: 14) {
                rowIcon("memorychip")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Model")
                        .font(theme.type.mono(11))
                        .foregroundStyle(theme.colors.muted)
                    Text(model.modelRowLabel)
                        .font(theme.type.mono(13))
                        .foregroundStyle(theme.colors.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if model.isBusy(.modelSet) {
                    busySpinner
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.colors.muted)
                }
            }
            .padding(.horizontal, AppMetrics.gutter)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isAnyActionRunning)
        .accessibilityLabel("Model, \(model.modelRowLabel)")
    }

    private var thinkingRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                rowIcon("brain")
                Text("Thinking")
                    .font(theme.type.mono(11))
                    .foregroundStyle(theme.colors.muted)
                Spacer(minLength: 0)
                if model.isBusy(.thinkingSet) { busySpinner }
            }
            ThinkingSegmentedControl(
                current: model.currentThinking,
                isEnabled: !model.isAnyActionRunning
            ) { level in
                Task { await model.setThinking(level) }
            }
        }
        .padding(.horizontal, AppMetrics.gutter)
        .padding(.vertical, 14)
    }

    // MARK: - Chrome

    private var offlineNote: some View {
        note(
            text: "Not connected — actions will fail until the link to Pi is back.",
            color: theme.colors.warning
        )
    }

    private func errorNote(_ message: String) -> some View {
        note(text: message, color: theme.colors.error)
            .onTapGesture { model.dismissError() }
    }

    private func note(text: String, color: Color) -> some View {
        Text(text)
            .font(theme.type.mono(11))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AppMetrics.gutter)
            .padding(.bottom, 12)
    }

    private var divider: some View {
        Rectangle()
            .fill(theme.colors.border)
            .frame(height: AppMetrics.hairline)
    }

    private func rowIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 16))
            .foregroundStyle(theme.colors.accent)
            .frame(width: 18)
    }

    private var busySpinner: some View {
        ProgressView()
            .controlSize(.small)
            .tint(theme.colors.accent)
            .frame(width: 14, height: 14)
    }
}

// MARK: - Row

/// Rows 1 and 2: icon, label, subtitle, and a 14pt spinner that replaces the
/// trailing affordance while the action is in flight.
private struct ActionRow: View {
    let systemImage: String
    let label: String
    let subtitle: String
    let isBusy: Bool
    let isEnabled: Bool
    let action: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 16))
                    .foregroundStyle(theme.colors.accent)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(theme.type.mono(13))
                        .foregroundStyle(theme.colors.text)
                    Text(subtitle)
                        .font(theme.type.mono(11))
                        .foregroundStyle(theme.colors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(theme.colors.accent)
                        .frame(width: 14, height: 14)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AppMetrics.gutter)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.55)
        .accessibilityLabel("\(label). \(subtitle)")
    }
}

// MARK: - Thinking segments

/// The 6-way control (§8.11, `:514-558`). Selection tints `accent @ 15%`.
///
/// Not `Picker(.segmented)`: it cannot render a "nothing selected" state, and
/// nothing selected is the honest rendering for a Pi that has not published a
/// thinking level.
struct ThinkingSegmentedControl: View {
    let current: ThinkingLevel?
    let isEnabled: Bool
    let onPick: (ThinkingLevel) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(ThinkingSegments.ordered.enumerated()), id: \.element) { index, level in
                if index > 0 {
                    Rectangle()
                        .fill(theme.colors.border)
                        .frame(width: AppMetrics.hairline)
                }
                segment(level)
            }
        }
        .frame(height: 32)
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(theme.colors.border, lineWidth: AppMetrics.hairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func segment(_ level: ThinkingLevel) -> some View {
        let isSelected = current == level
        return Button {
            onPick(level)
        } label: {
            Text(ThinkingSegments.label(for: level))
                .font(theme.type.mono(11))
                .foregroundStyle(foreground(isSelected: isSelected))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(isSelected ? theme.colors.accent.opacity(0.15) : .clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .animation(.easeOut(duration: 0.12), value: isSelected)
        .accessibilityLabel(ThinkingSegments.accessibilityLabel(for: level))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func foreground(isSelected: Bool) -> Color {
        if !isEnabled { return theme.colors.muted.opacity(0.5) }
        return isSelected ? theme.colors.accent : theme.colors.text
    }
}
