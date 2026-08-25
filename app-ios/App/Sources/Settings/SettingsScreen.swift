import RemotePiProtocol
import SwiftUI

// ============================================================================
// Settings — spec 08 §9, HIG edition (redesigned 2026-08-26).
//
// A standard inset-grouped Form with three sections: Server, Appearance,
// Paired Devices. Three deliberate framing decisions:
//
//   * **One server.** The section is singular by construction — an address
//     field, a footer stating what the app is dialling, and a reset row that
//     appears only while an override is active. Nothing here can grow into a
//     server list.
//   * System text styles and default row chrome throughout, so Dynamic Type
//     and dark mode come from the OS. Monospace survives only where the
//     content is an identifier (the URL, key fingerprints in PeerRow).
//   * Text size is still deliberately absent — spec 08 §9.2: a native app
//     honours the per-app Text Size in Settings → Accessibility instead of
//     shipping a second knob that multiplies against it.
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
            serverSection
            appearanceSection
            devicesSection
        }
        .listStyle(.insetGrouped)
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

    // MARK: - Server (§9.1, single-server framing)

    /// `true` while the field is dialling something other than the built-in
    /// release server. Drives the reset row's visibility.
    private var isOverridden: Bool {
        model.effectiveRelayURL != AppModel.defaultRelayURL
    }

    @ViewBuilder
    private var serverSection: some View {
        Section {
            HStack {
                TextField("Server address", text: $model.relayDraft, prompt: Text(AppModel.defaultRelayURL))
                    .font(.callout.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.done)
                    .onChange(of: model.relayDraft) { model.relayDraftEdited() }
                    .onSubmit { Task { await model.saveRelayURL() } }
                    .disabled(model.isSavingRelay)
                if model.isSavingRelay {
                    ProgressView()
                }
            }

            if isOverridden {
                Button("Reset to Default Server") {
                    Task { await model.useDefaultRelay() }
                }
                .disabled(model.isSavingRelay)
            }
        } header: {
            Text("Server")
        } footer: {
            serverFooter
        }
    }

    /// One line that always states what the app is actually dialling — which
    /// is not necessarily what is in the field above. Errors and the transient
    /// "updated" confirmation take the same slot: a footer is where iOS puts
    /// per-section status, and stacking three message areas reads as three
    /// problems.
    @ViewBuilder
    private var serverFooter: some View {
        if let error = model.relayError {
            Text(error).foregroundStyle(theme.colors.error)
        } else if let banner = model.banner, banner.kind == .info {
            Text(banner.text).foregroundStyle(theme.colors.success)
        } else if isOverridden {
            Text("Connected to a custom server: \(model.effectiveRelayURL). The app uses one server at a time.")
        } else {
            Text("Connected to the Remote Pi server. Enter an address above only if you run your own relay.")
        }
    }

    // MARK: - Appearance (§9.2)

    @ViewBuilder
    private var appearanceSection: some View {
        @Bindable var preferences = app.preferences

        Section("Appearance") {
            Picker("Theme", selection: $preferences.themeMode) {
                ForEach(AppThemeMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }

            Toggle(isOn: $preferences.hideToolCalls) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hide Tool Calls")
                    Text("Only show your messages and the replies.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }

        // ── Text size: deliberately absent ─────────────────────────────────
        // Flutter had a 4-way segmented control here because the Dart app
        // hardcodes font sizes and cannot read iOS's per-app Text Size
        // (issue #114). This screen now uses system text styles, so the OS
        // control in Settings → Accessibility → Per-App Settings works — and
        // a second in-app knob would multiply against it, producing sizes
        // neither one asked for (spec 08 §9.2).
    }

    // MARK: - Paired devices (§9.3)

    @ViewBuilder
    private var devicesSection: some View {
        Section {
            switch model.pairings {
            case .loading:
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .padding(.vertical, 16)

            case .empty:
                ContentUnavailableView {
                    Label("No Pairings Yet", systemImage: "laptopcomputer.and.iphone")
                } description: {
                    Text("Pair a Mac to control its sessions from this device.")
                }
                .padding(.vertical, -8)

            case .list(let records):
                // `id: \.peer` — the 32 raw key bytes. Never the index, never
                // the nickname: both change under the user (plan 61).
                ForEach(records, id: \.peer) { record in
                    PeerRow(
                        record: record,
                        isRevoking: model.revoking == record.peer,
                        onEditNickname: { model.beginNicknameEdit(record) },
                        onRevoke: { model.requestRevoke(record) }
                    )
                }
            }

            Button {
                navigator.openPairing()
            } label: {
                Label("Pair New Mac…", systemImage: "qrcode.viewfinder")
            }
        } header: {
            Text("Paired Devices")
        } footer: {
            // Deliberately rendered for every pairings state: the case that
            // matters most is "you just revoked your LAST pairing and the
            // relay did not hear about it", where the list above is empty.
            if let banner = model.banner, banner.kind != .info {
                Text(banner.text)
                    .foregroundStyle(banner.kind == .error ? theme.colors.error : theme.colors.warning)
            }
        }
    }

    // MARK: - Plumbing

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
}
