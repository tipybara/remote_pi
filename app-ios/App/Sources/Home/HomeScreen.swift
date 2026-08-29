import RemotePiProtocol
import RemotePiSession
import SwiftUI

// ============================================================================
// Home (spec 08 §7) — the plan-61 centerpiece.
//
// Two design passes, both alive in this file:
//
// 2026-08-29 — terminal skin. The phone is a terminal into your Mac, so Home
// reads like a session list in one: plain edge-to-edge list on the app
// background, rows are `❯ title` prompt lines, device headers are `# hostname`
// comment lines, paths abbreviate `$HOME` to `~`. The skin changes NOTHING
// structural: every pattern below from the HIG pass (swipe actions, context
// menus, pull-to-refresh, toolbar menu, Dynamic Type) survives untouched.
//
// 2026-08-26 — HIG skeleton, on three user requirements:
//
//   1. ONE server. The app dials a single relay; nothing on this screen may
//      suggest a server list. The relay is chrome-invisible while healthy —
//      status appears only when it is *bad* (a thin banner), which is the
//      system-app pattern (Mail/Messages reserve no chrome for "everything is
//      fine").
//   2. Density. The hand-built 124pt collapsing "Remote Pi" brand block is
//      gone (HomeTitleBar.swift with it). The system navigation bar renders an
//      inline "Sessions" title; the filter pills row is folded into a toolbar
//      menu. First session row now starts ~150pt higher.
//   3. HIG. System `List` (inset-grouped) instead of a custom ScrollView;
//      swipe actions and a context menu instead of the long-press sheet
//      (SessionMenuSheet.swift deleted); pull-to-refresh; system text styles
//      so Dynamic Type works; SF Symbols with standard weights.
//
// The invariants that must survive any future rewrite of this file are
// unchanged from the previous design:
//
//   * rows are keyed by `HomeRow.id` (== `SessionKey.storageKey`) — never by
//     index, name, cwd or `started_at`;
//   * ordering comes from `SessionCatalog` and is never re-applied here;
//   * tapping a row goes through `SessionOpener`, which owns the ordering of
//     open → select → push;
//   * the filter and the grouping live on the model, so they survive every
//     data re-emit (spec 08 §12.2).
//
// Pull-to-refresh exists because it finally CAN: the relay used to suppress a
// `rooms_check` reply identical to the previous one, so a manual refresh was
// theatre. review/62-audit-state-sync.md D2 made polls always answer.
// ============================================================================

struct HomeScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(AppNavigator.self) private var navigator
    @Environment(SessionSelection.self) private var selection
    @Environment(\.layoutClass) private var layout
    @Environment(\.theme) private var theme

    @State private var model = HomeScreenModel()

    @State private var renameRow: HomeRow?
    @State private var renameText = ""
    @State private var deleteRow: HomeRow?
    @State private var newSession: NewSessionModel?

    var body: some View {
        let content = model.content
        return phaseBody(content)
            // Keep the capitalized title for the BACK button of pushed
            // screens and for VoiceOver; the visible bar text is the mono
            // lowercase principal item below.
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .safeAreaInset(edge: .top, spacing: 0) { offlineBanner }
            .overlay(alignment: .bottom) { bannerOverlay }
            .sheet(item: $newSession) { sheet in
                NewSessionSheet(model: sheet) { key in
                    Task { await openCreated(key) }
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .alert("Rename Session", isPresented: renameBinding, presenting: renameRow) { row in
                TextField(row.hintName, text: $renameText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                // Cancel returns nothing and is a no-op; Save sends the trimmed
                // text, which may be empty — an empty name is a local-only
                // clear (spec 08 §7.7).
                Button("Cancel", role: .cancel) { renameRow = nil }
                Button("Save") {
                    let text = renameText
                    renameRow = nil
                    Task { await model.rename(row.key, to: text) }
                }
            }
            .alert("Delete Session?", isPresented: deleteBinding, presenting: deleteRow) { row in
                Button("Cancel", role: .cancel) { deleteRow = nil }
                Button("Delete", role: .destructive) {
                    deleteRow = nil
                    Task { await model.delete(row.key) }
                }
            } message: { _ in
                Text(
                    "Removes locally only. If the session comes back online on the Pi, "
                        + "it reappears in the list."
                )
            }
            .screenModel(model)
    }

    // MARK: Phases

    @ViewBuilder
    private func phaseBody(_ content: HomeContent) -> some View {
        switch content.phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .noPeer:
            // The design system's mono empty state, not
            // `ContentUnavailableView` — the system component paints with the
            // system font and reads as a different app inside the terminal
            // chrome (see EmptyStateView.swift's header).
            centered {
                EmptyStateView(
                    systemImage: "qrcode.viewfinder",
                    title: "No Pairings Yet",
                    message: "Scan a QR code from your Mac to start."
                ) {
                    PrimaryButton(title: "Scan QR") { navigator.openPairing() }
                        .frame(maxWidth: 240)
                }
            }

        case .lonely:
            centered {
                EmptyStateView(
                    systemImage: "moon",
                    title: "No Sessions",
                    message: "When a paired Pi opens a session, it shows up here.",
                    iconOpacity: 0.35
                )
            }

        case .filterEmpty(let filter):
            // The pills row is gone, so the escape hatch that used to be "the
            // tabs stay visible" (spec 08 §7.3) is a button instead.
            centered {
                EmptyStateView(
                    systemImage: "line.3.horizontal.decrease.circle",
                    title: filterEmptyTitle(filter),
                    message: filterEmptyMessage(filter)
                ) {
                    SecondaryButton(title: "Show All Sessions") { model.filter = .all }
                        .frame(maxWidth: 240)
                }
            }

        case .list:
            sessionList(content.sections)
        }
    }

    /// Empty states fill the phase body, vertically centered like the
    /// system component they replaced.
    private func centered(@ViewBuilder _ content: () -> some View) -> some View {
        ScrollView {
            content()
                .frame(maxWidth: .infinity)
                .containerRelativeFrame(.vertical) { length, _ in length }
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func filterEmptyTitle(_ filter: SessionFilter) -> String {
        switch filter {
        case .online: "No Sessions Online"
        case .offline: "No Offline Sessions"
        case .all: "No Sessions"
        }
    }

    private func filterEmptyMessage(_ filter: SessionFilter) -> String {
        switch filter {
        case .online: "Live sessions appear here when a paired Pi is active."
        case .offline: "Sessions you've seen before that aren't live show up here."
        case .all: "When a paired Pi opens a session, it shows up here."
        }
    }

    // MARK: List

    private func sessionList(_ sections: [HomeDeviceSection]) -> some View {
        List {
            ForEach(sections) { device in
                Section {
                    ForEach(device.workspaces) { workspace in
                        if model.grouping == .workspace {
                            WorkspaceHeaderRow(workspace: workspace)
                                .listRowBackground(theme.colors.bg)
                        }
                        ForEach(workspace.rows) { row in
                            tile(row)
                        }
                    }
                } header: {
                    // With grouping off the rows carry their own context label
                    // (spec 08 §7.4) — an empty header would just add air.
                    if model.grouping != .none {
                        // A comment line, because that is what a hostname
                        // above a block of sessions is.
                        Text("# " + device.title)
                            .font(theme.type.mono(11, weight: .semibold))
                            .foregroundStyle(theme.colors.muted)
                            .textCase(nil)
                    }
                }
            }
        }
        // Plain and edge-to-edge on the app ground: a terminal has one
        // surface, not floating cards.
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { await model.refresh() }
    }

    private func tile(_ row: HomeRow) -> some View {
        // Only in two-pane mode: on phone the list is covered by the pushed
        // chat, so a persistent highlight would be meaningless (spec 08 §11.2).
        let isSelected = layout == .split && selection.matches(row.key)
        return SessionTileView(
            row: row,
            presence: model.presence(of: row.key),
            open: { Task { await open(row.key) } }
        )
        .listRowBackground(isSelected ? theme.colors.accent.opacity(0.12) : theme.colors.bg)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // Delete leads (rightmost) per HIG; it stays visible-but-refused
            // when unsupported so the affordance is discoverable.
            if HomeScreen.cachedDeleteSupported {
                Button(role: .destructive) {
                    deleteRow = row
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(!model.canDelete(row.key))
            }
            Button {
                beginRename(row)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(.orange)
        }
        .contextMenu {
            Button {
                beginRename(row)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            if HomeScreen.cachedDeleteSupported {
                Button(role: .destructive) {
                    deleteRow = row
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(!model.canDelete(row.key))
            }
        }
        // The identity rule, in SwiftUI form. Without it the framework matches
        // elements by POSITION, and a list that reorders hands index 2's
        // element — with its scroll offset and in-flight animation — to a
        // different session (spec 08 §7.5).
        .id(row.id)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Text("sessions")
                .font(theme.type.mono(15, weight: .semibold))
                .foregroundStyle(theme.colors.text)
                .accessibilityHidden(true) // navigationTitle already says it
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            // Hidden rather than disabled: the control frame rides the active
            // WebSocket, so an unreachable Mac genuinely cannot be asked
            // (spec 08 §7.2).
            if model.canCreateSession {
                Button {
                    newSession = model.makeNewSessionModel()
                } label: {
                    Label("New Session", systemImage: "plus")
                }
            }

            filterMenu

            Button {
                navigator.openSettings(layout: layout)
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
        }
    }

    /// Filter + grouping share one menu — the Mail pattern. The icon fills in
    /// when a filter is active so a filtered-empty list is explainable at a
    /// glance from the bar alone.
    private var filterMenu: some View {
        Menu {
            Picker(
                "Filter",
                selection: Binding(get: { model.filter }, set: { model.filter = $0 })
            ) {
                ForEach(SessionFilter.ordered, id: \.self) { filter in
                    Text("\(filter.label) (\(model.content.counts.count(for: filter)))")
                        .tag(filter)
                }
            }
            Divider()
            Picker(
                "Group By",
                selection: Binding(get: { model.grouping }, set: { model.grouping = $0 })
            ) {
                ForEach(HomeGrouping.allCases, id: \.self) { grouping in
                    Text(grouping.label).tag(grouping)
                }
            }
        } label: {
            Label(
                "Filter",
                systemImage: model.filter == .all
                    ? "line.3.horizontal.decrease.circle"
                    : "line.3.horizontal.decrease.circle.fill"
            )
        }
    }

    // MARK: Relay status

    /// Chrome only when something is WRONG. `.connected` renders nothing;
    /// `.awaitingPairing` renders nothing (the no-peer empty state already
    /// says it, and amber chrome over "scan a QR to start" reads as a fault
    /// that isn't one — spec 08 §7.2).
    @ViewBuilder
    private var offlineBanner: some View {
        if model.relayStatus == .offline {
            Label("relay unreachable — reconnecting…", systemImage: "wifi.exclamationmark")
                .font(theme.type.mono(11.5))
                .foregroundStyle(theme.colors.warning)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(.bar)
                .overlay(alignment: .bottom) {
                    Divider()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityLabel("Relay unreachable, reconnecting")
        }
    }

    // MARK: Banner

    /// The `SnackBar` equivalent (spec 08 §7.7): a rename or delete that did
    /// not land says so, instead of looking identical to one that did.
    @ViewBuilder
    private var bannerOverlay: some View {
        if let banner = model.banner {
            Text(banner.text)
                .font(theme.type.mono(12))
                .foregroundStyle(theme.colors.text)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.colors.surface)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(theme.colors.border, lineWidth: AppMetrics.hairline)
                )
                .padding(.horizontal, AppMetrics.gutter)
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onTapGesture { model.dismissBanner() }
                .task(id: banner.id) {
                    try? await Task.sleep(for: .seconds(4))
                    guard !Task.isCancelled else { return }
                    model.dismissBanner()
                }
                .accessibilityAddTraits(.isStaticText)
        }
    }

    // MARK: Actions

    private func beginRename(_ row: HomeRow) {
        renameText = row.currentName ?? ""
        renameRow = row
    }

    /// Spec 08 §7.8, in this exact order. `SessionOpener` owns steps 2 and 3.
    private func open(_ key: SessionKey) async {
        guard let row = model.row(for: key) else { return }
        await SessionOpener(
            app: app,
            selection: selection,
            navigator: navigator,
            layout: layout
        ).open(row)
    }

    /// Home resolves the freshly-announced room from the live snapshot rather
    /// than synthesising one — the app must never derive a room id itself
    /// (spec 08 §13.10, plan 61 D8). If it is not there yet, do nothing: the
    /// row appears in the list on its own when the relay announces it.
    private func openCreated(_ key: SessionKey) async {
        await open(key)
    }

    // MARK: Bindings

    private var renameBinding: Binding<Bool> {
        Binding(get: { renameRow != nil }, set: { if !$0 { renameRow = nil } })
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { deleteRow != nil }, set: { if !$0 { deleteRow = nil } })
    }

    /// Whether this build can evict a cached session at all.
    ///
    /// Local eviction needs both a store delete and a way to drop the room from
    /// `RoomRegistry`, and the registry has no such API today (`room_ended`
    /// deliberately only clears liveness). Until it does, the actions are
    /// hidden entirely — a swipe action that always refuses is worse than none.
    private static let cachedDeleteSupported = false
}

/// The workspace sub-header, as a row inside the device's card: folder glyph,
/// folder name, dimmed head-truncated path, session count. Not tappable — the
/// workspace is a grouping key, never an identity (plan 61).
private struct WorkspaceHeaderRow: View {
    let workspace: HomeWorkspaceSection

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(theme.type.mono(11))
                .foregroundStyle(theme.colors.muted)
            Text(workspace.title)
                .font(theme.type.mono(12, weight: .semibold))
                .foregroundStyle(theme.colors.muted2)
                .lineLimit(1)
            if let path = workspace.pathLine {
                // The model already head-truncates; if the row is still too
                // narrow, keep cutting from the head — the tail is the part
                // that disambiguates. Tail-truncating here produced a path
                // with an ellipsis at BOTH ends.
                Text(path)
                    .font(theme.type.mono(11))
                    .foregroundStyle(theme.colors.muted)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 4)
            Text("\(workspace.rows.count)")
                .font(theme.type.mono(11))
                .foregroundStyle(theme.colors.muted)
                .monospacedDigit()
        }
        .listRowSeparator(.hidden, edges: .top)
        .accessibilityElement(children: .combine)
    }
}

extension NewSessionModel: Identifiable {
    /// Identity is the presentation, not the machine: the sheet must not be
    /// torn down and rebuilt when the user picks a different Mac, or its
    /// idempotency keys would be re-minted (spec 08 §13.9).
    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
}
