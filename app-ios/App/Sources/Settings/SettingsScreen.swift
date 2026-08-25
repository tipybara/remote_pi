import RemotePiProtocol
import SwiftUI

// ============================================================================
// Settings — spec 08 §9. Ported from `settings_page.dart` / `settings_sheet.dart`.
//
// ONE page with two presentations, selected by `isEmbedded`:
//   phone  → pushed (`AppRoute.settings`), the stack's own back button;
//   tablet → a 92 %-height sheet (`AppNavigator.settingsSheet`), leading `x`.
// Do not fork this into two screens; the detents live on the presenter
// (`RootShell`), not here.
//
// Behaviour lives in `SettingsScreenModel`. This file is layout only — if you
// find yourself writing an `if` about *what should happen*, it belongs there.
// ============================================================================

struct SettingsScreen: View {
    /// `true` when presented as the tablet sheet.
    let isEmbedded: Bool

    @Environment(AppModel.self) private var app
    @Environment(AppNavigator.self) private var navigator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @State private var model = SettingsScreenModel()

    var body: some View {
        List {
            relaySection
            displaySection
            pairingsSection
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(theme.colors.bg)
        .environment(\.defaultMinListRowHeight, 0)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isEmbedded {
                ToolbarItem(placement: .topBarTrailing) {
                    SheetCloseButton { dismiss() }
                }
            }
        }
        .sheet(isPresented: nicknameSheetBinding) {
            // Deliberately NOT `.dismissOnSessionChange(_:)`: that modifier is
            // for chat-scoped sheets. This one is scoped to a *machine* and
            // must survive the detail pane swapping underneath it.
            if let record = model.nicknameCandidate {
                NicknameEditorSheet(
                    record: record,
                    draft: $model.nicknameDraft,
                    onSave: { await model.commitNicknameEdit() },
                    onCancel: { model.cancelNicknameEdit() }
                )
                .presentationDetents([.height(330)])
            }
        }
        .confirmationDialog(
            revokeTitle,
            isPresented: revokeDialogBinding,
            titleVisibility: .visible
        ) {
            Button("Revoke", role: .destructive) {
                Task { await model.confirmRevoke() }
            }
            // Cancel changes nothing and the row stays put — the SwiftUI
            // equivalent of `confirmDismiss` returning `false` (spec 08 §10).
            Button("Cancel", role: .cancel) { model.cancelRevoke() }
        } message: {
            Text("You'll need to pair again from the PC or Mac to reconnect.")
        }
        .screenModel(model)
    }

    // MARK: - RELAY (§9.1)

    @ViewBuilder
    private var relaySection: some View {
        row {
            SectionHeader(title: "Relay", style: .device)
        }
        row {
            VStack(alignment: .leading, spacing: 10) {
                TextField("https://my-relay.example.com", text: $model.relayDraft)
                    .font(theme.type.mono(13))
                    .foregroundStyle(theme.colors.text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                    .background(theme.colors.inputFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(
                                model.relayError == nil
                                    ? theme.colors.border
                                    : theme.colors.error,
                                lineWidth: AppMetrics.hairline
                            )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .onChange(of: model.relayDraft) { model.relayDraftEdited() }
                    .onSubmit { Task { await model.saveRelayURL() } }
                    .disabled(model.isSavingRelay)

                if let error = model.relayError {
                    Text(error)
                        .font(theme.type.mono(10))
                        .foregroundStyle(theme.colors.error)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    // "what you are dialling now", which is not necessarily
                    // what is in the field above.
                    Text("Current: \(model.effectiveRelayURL)")
                        .font(theme.type.mono(10))
                        .foregroundStyle(theme.colors.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack(spacing: 12) {
                    PrimaryButton(
                        title: "Save",
                        isEnabled: !model.isSavingRelay,
                        isBusy: model.isSavingRelay
                    ) {
                        Task { await model.saveRelayURL() }
                    }
                    .frame(maxWidth: 140)

                    Button {
                        Task { await model.useDefaultRelay() }
                    } label: {
                        Text("Use default Relay")
                            .font(theme.type.mono(13))
                            .foregroundStyle(theme.colors.accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isSavingRelay)

                    Spacer(minLength: 0)
                }

                // Only the transient "Relay updated" confirmation belongs
                // here. A revoke warning is about the pairings list and is
                // rendered down there — showing it in both places reads as two
                // separate problems.
                if let banner = model.banner, banner.kind == .info {
                    BannerLabel(banner: banner)
                }
            }
            .padding(.horizontal, AppMetrics.gutter)
            .padding(.top, 4)
            .padding(.bottom, 14)
        }
        divider
    }

    // MARK: - DISPLAY (§9.2)

    @ViewBuilder
    private var displaySection: some View {
        @Bindable var preferences = app.preferences

        row {
            SectionHeader(title: "Display", style: .device)
        }
        row {
            VStack(alignment: .leading, spacing: 10) {
                Text("Theme")
                    .font(theme.type.sansBody)
                    .foregroundStyle(theme.colors.text)
                Picker("Theme", selection: $preferences.themeMode) {
                    ForEach(AppThemeMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.horizontal, AppMetrics.gutter)
            .padding(.vertical, 4)
        }

        // ── Text size: deliberately absent ─────────────────────────────────
        //
        // Flutter had a 4-way Small/Default/Large/XL segmented control here
        // because the Dart app hardcodes every font size and Flutter cannot
        // read iOS's per-app Text Size, so the OS accessibility setting did
        // nothing (issue #114). Spec 08 §9.2 says a native client should drop
        // the control and honour Dynamic Type instead — a native app gets the
        // per-app Text Size slider in Settings → Accessibility → Display &
        // Text Size → Per-App Settings for free, and a second in-app knob
        // multiplied against it produces sizes neither one asked for.
        //
        // ⚠️ The other half of that trade is NOT done here: `AppTypography`
        // still returns fixed `Font.system(size:)` values, so nothing scales
        // yet. Wiring it is one line in `AppTypography.mono/sans/brand`
        // (`.custom(_, size:relativeTo:)`, or `UIFontMetrics.default
        // .scaledValue(for:)`), and it belongs to whoever owns the design
        // system — not to a screen. Until then `AppPreferences.fontScale`
        // keeps whatever value it was last given and has no UI.
        // ───────────────────────────────────────────────────────────────────

        row {
            Toggle(isOn: $preferences.hideToolCalls) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hide tool calls in chat")
                        .font(theme.type.sansBody)
                        .foregroundStyle(theme.colors.text)
                    Text("Only show your messages and the assistant replies.")
                        .font(theme.type.sans(12))
                        .foregroundStyle(theme.colors.muted)
                }
            }
            .tint(theme.colors.accent)
            .padding(.horizontal, AppMetrics.gutter)
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
        divider
    }

    // MARK: - PAIRINGS (§9.3)

    @ViewBuilder
    private var pairingsSection: some View {
        row {
            SectionHeader(
                title: "Pairings",
                style: .device,
                count: pairingCount
            )
        }

        switch model.pairings {
        case .loading:
            row {
                ProgressView()
                    .tint(theme.colors.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
            }
        case .empty:
            row {
                EmptyStateView(
                    systemImage: "laptopcomputer.and.iphone",
                    title: "No pairings yet",
                    message: "Tap + to pair a new Mac."
                ) {
                    PrimaryButton(title: "Scan QR") { navigator.openPairing() }
                        .frame(maxWidth: 220)
                }
            }
        case .list(let records):
            // `id: \.peer` — the 32 raw key bytes. Never the index, never the
            // nickname: both change under the user (plan 61, spec 08 §2.1).
            ForEach(records, id: \.peer) { record in
                PeerRow(
                    record: record,
                    isRevoking: model.revoking == record.peer,
                    onEditNickname: { model.beginNicknameEdit(record) },
                    onRevoke: { model.requestRevoke(record) }
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(theme.colors.bg)
                .listRowSeparator(.hidden)
            }
        }

        // Deliberately outside the `switch`: the case that matters most is
        // "you just revoked your LAST pairing and the relay did not hear about
        // it", where `pairings` is `.empty`. Scoping this to `.list` would hide
        // the warning exactly when it is load-bearing.
        if let banner = model.banner, banner.kind != .info {
            row {
                BannerLabel(banner: banner)
                    .padding(.horizontal, AppMetrics.gutter)
                    .padding(.top, 10)
            }
        }

        row {
            SecondaryButton(title: "Add new pairing") { navigator.openPairing() }
                .padding(.horizontal, AppMetrics.gutter)
                .padding(.top, 12)
                .padding(.bottom, 24)
        }
    }

    // MARK: - Plumbing

    /// A count only when there is something to count — `SectionHeader` treats
    /// `0` as "draw a zero", and an empty section should not have one.
    private var pairingCount: Int? {
        let count = model.pairings.records.count
        return count == 0 ? nil : count
    }

    /// Swipe-down / tap-outside must be a *cancel*, not a silent write — the
    /// nickname sheet's three outcomes (save / clear / cancel) are the
    /// absent-vs-empty trap in spec 08 §10.
    private var nicknameSheetBinding: Binding<Bool> {
        Binding(
            get: { model.nicknameCandidate != nil },
            set: { if !$0 { model.cancelNicknameEdit() } }
        )
    }

    private var revokeTitle: String {
        guard let candidate = model.revokeCandidate else { return "Revoke pairing?" }
        return "Revoke \"\(candidate.sessionName ?? candidate.displayLabel)\"?"
    }

    /// `confirmationDialog` wants a `Binding<Bool>`; the model owns the real
    /// state (a `PeerRecord?`), so the false-write routes back through
    /// `cancelRevoke()` and nothing else can clear it.
    private var revokeDialogBinding: Binding<Bool> {
        Binding(
            get: { model.revokeCandidate != nil },
            set: { if !$0 { model.cancelRevoke() } }
        )
    }

    @ViewBuilder
    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .listRowInsets(EdgeInsets())
            .listRowBackground(theme.colors.bg)
            .listRowSeparator(.hidden)
    }

    private var divider: some View {
        row {
            Rectangle()
                .fill(theme.colors.border)
                .frame(height: AppMetrics.hairline)
                .padding(.top, 8)
        }
    }
}

/// The inline "Relay updated" / "the relay was not updated" line.
private struct BannerLabel: View {
    let banner: SettingsScreenModel.Banner
    @Environment(\.theme) private var theme

    var body: some View {
        Text(banner.text)
            .font(theme.type.mono(11))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isStaticText)
    }

    private var color: Color {
        switch banner.kind {
        case .info: theme.colors.success
        case .warning: theme.colors.warning
        case .error: theme.colors.error
        }
    }
}
