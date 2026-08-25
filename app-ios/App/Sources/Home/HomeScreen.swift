import RemotePiProtocol
import RemotePiSession
import SwiftUI

// ============================================================================
// Home (spec 08 §7) — the plan-61 centerpiece.
//
// Behaviour lives in `HomeScreenModel`; this file is layout, chrome and the
// presentation plumbing for four modals. The invariants that must survive any
// future rewrite of this file:
//
//   * rows are keyed by `HomeRow.id` (== `SessionKey.storageKey`) — never by
//     index, name, cwd or `started_at`;
//   * ordering comes from `SessionCatalog` and is never re-applied here;
//   * tapping a row goes through `SessionOpener`, which owns the ordering of
//     open → select → push;
//   * the filter and the grouping live on the model, so they survive every
//     data re-emit (spec 08 §12.2).
//
// Not ported, on purpose: the Android update banner (spec 08 §7.10). The App
// Store handles updates; the Flutter layout reserves a zero-height slot there
// and so does this one, by simply not having one.
// ============================================================================

struct HomeScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(AppNavigator.self) private var navigator
    @Environment(SessionSelection.self) private var selection
    @Environment(\.layoutClass) private var layout
    @Environment(\.theme) private var theme

    @State private var model = HomeScreenModel()

    /// `1` expanded → `0` collapsed. Drives the title cross-fade.
    @State private var titleProgress: CGFloat = 1

    // One state per modal. `HomeRow` is `Identifiable` on the session key, so
    // `.sheet(item:)` re-presents correctly if the row underneath changes.
    @State private var menuRow: HomeRow?
    @State private var pendingMenuAction: MenuAction?
    @State private var renameRow: HomeRow?
    @State private var renameText = ""
    @State private var deleteRow: HomeRow?
    @State private var newSession: NewSessionModel?

    private enum MenuAction { case rename(HomeRow), delete(HomeRow) }

    var body: some View {
        let content = model.content
        return scroll(content)
            .background(theme.colors.bg)
            .safeAreaInset(edge: .top, spacing: 0) {
                HomeCompactBar(progress: titleProgress) { actions }
            }
            // Our own 56pt bar *is* the title bar; leaving the system one on
            // would stack two of them (spec 08 §7.2's "two app bars" note).
            .toolbar(.hidden, for: .navigationBar)
            .overlay(alignment: .bottom) { bannerOverlay }
            .sheet(item: $menuRow, onDismiss: runPendingMenuAction) { row in
                SessionMenuSheet(
                    row: row,
                    canDelete: model.canDelete(row.key),
                    deleteSupported: Self.cachedDeleteSupported,
                    rename: { pendingMenuAction = .rename(row); menuRow = nil },
                    delete: { pendingMenuAction = .delete(row); menuRow = nil }
                )
                .presentationDetents([.height(220)])
                .presentationDragIndicator(.visible)
            }
            .sheet(item: $newSession) { sheet in
                NewSessionSheet(model: sheet) { key in
                    Task { await openCreated(key) }
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .alert("Rename session", isPresented: renameBinding, presenting: renameRow) { row in
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
            .alert("Delete session?", isPresented: deleteBinding, presenting: deleteRow) { row in
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

    // MARK: Scroll body

    private func scroll(_ content: HomeContent) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                HomeLargeTitle(progress: titleProgress, status: model.relayStatus)

                // Tabs are hidden in both zero states — there is nothing to
                // filter, and an all-zero pill next to "Nothing here…" reads
                // as a bug (spec 08 §7.1).
                if showsTabs(content.phase) {
                    tabsRow(content.counts)
                }

                switch content.phase {
                case .loading:
                    loading
                case .noPeer:
                    noPeer
                case .lonely:
                    lonely
                case .filterEmpty(let filter):
                    filterEmpty(filter)
                case .list:
                    list(content.sections)
                }
            }
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            // `contentInsets.top` is the safe area our pinned bar sits in, so
            // subtracting it makes 0 mean "scrolled to the very top" on every
            // device.
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, offset in
            titleProgress = HomeTitleMetrics.progress(scrollOffset: offset)
        }
    }

    private func showsTabs(_ phase: HomePhase) -> Bool {
        switch phase {
        case .loading, .noPeer, .lonely: false
        case .filterEmpty, .list: true
        }
    }

    // MARK: Chrome

    @ViewBuilder
    private var actions: some View {
        // Hidden rather than disabled: the control frame rides the active
        // WebSocket, so an unreachable Mac genuinely cannot be asked
        // (spec 08 §7.2).
        if model.canCreateSession {
            Button {
                newSession = model.makeNewSessionModel()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(theme.colors.muted2)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New session")
        }

        Button {
            navigator.openSettings(layout: layout)
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 17))
                .foregroundStyle(theme.colors.muted2)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")
    }

    private func tabsRow(_ counts: HomeSessionCounts) -> some View {
        HStack(spacing: 4) {
            FilterTabs(
                tabs: SessionFilter.ordered,
                label: \.label,
                count: counts.count(for:),
                selection: Binding(get: { model.filter }, set: { model.filter = $0 })
            )
            groupingMenu
        }
        .padding(.horizontal, AppMetrics.gutter)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    /// A menu rather than a Settings row: this is a layout knob the user flips
    /// while **looking at** the list, and the effect is only judgeable in place
    /// (spec 08 §7.4).
    private var groupingMenu: some View {
        Menu {
            Picker(
                "Group sessions by…",
                selection: Binding(get: { model.grouping }, set: { model.grouping = $0 })
            ) {
                ForEach(HomeGrouping.allCases, id: \.self) { grouping in
                    Text(grouping.label).tag(grouping)
                }
            }
        } label: {
            Image(systemName: "list.bullet.indent")
                .font(.system(size: 17))
                .foregroundStyle(theme.colors.muted2)
                .frame(width: 36, height: 36)
        }
        .accessibilityLabel("Group sessions by")
    }

    // MARK: List

    @ViewBuilder
    private func list(_ sections: [HomeDeviceSection]) -> some View {
        ForEach(sections) { device in
            if model.grouping != .none {
                SectionHeader(title: device.title, style: .device)
                    .id(device.id)
            }
            ForEach(device.workspaces) { workspace in
                if model.grouping == .workspace {
                    SectionHeader(
                        title: workspace.title,
                        subtitle: workspace.pathLine,
                        style: .workspace,
                        count: workspace.rows.count
                    )
                    .id(workspace.id)
                }
                ForEach(workspace.rows) { row in
                    tile(row)
                    Divider().overlay(theme.colors.border)
                }
            }
        }
    }

    private func tile(_ row: HomeRow) -> some View {
        SessionTileView(
            row: row,
            presence: model.presence(of: row.key),
            // Only in two-pane mode: on phone the list is covered by the
            // pushed chat, so a persistent highlight would be meaningless
            // (spec 08 §11.2).
            isSelected: layout == .split && selection.matches(row.key),
            open: { Task { await open(row.key) } },
            showMenu: { menuRow = row }
        )
        // The identity rule, in SwiftUI form. Without it the framework matches
        // elements by POSITION, and a list that reorders hands index 2's
        // element — with its scroll offset and in-flight animation — to a
        // different session (spec 08 §7.5).
        .id(row.id)
    }

    // MARK: Empty states

    private var loading: some View {
        HStack {
            Spacer()
            ProgressView().tint(theme.colors.accent)
            Spacer()
        }
        .padding(.top, 80)
    }

    private var noPeer: some View {
        EmptyStateView(
            systemImage: "qrcode.viewfinder",
            title: "No pairings yet",
            message: "Scan a QR from your Mac to start."
        ) {
            PrimaryButton(title: "Scan QR") { navigator.openPairing() }
                .frame(maxWidth: 220)
        }
        .padding(.top, 40)
    }

    private var lonely: some View {
        EmptyStateView(
            systemImage: "moon",
            title: "Nothing here…",
            message: "When a paired Pi opens a session, it shows up here.",
            iconOpacity: 0.35
        )
        .padding(.top, 40)
    }

    /// Rendered **below** the still-visible tabs, so the user can switch back
    /// (spec 08 §7.3). The copy varies per tab so it reads as a filter, not as
    /// a dead end.
    private func filterEmpty(_ filter: SessionFilter) -> some View {
        let copy: (String, String) = switch filter {
        case .online:
            ("No sessions online", "Live sessions appear here when a paired Pi is active.")
        case .offline:
            ("No offline sessions", "Sessions you've seen before that aren't live show up here.")
        case .all:
            ("Nothing here…", "When a paired Pi opens a session, it shows up here.")
        }
        return EmptyStateView(
            systemImage: "moon",
            title: copy.0,
            message: copy.1,
            iconOpacity: 0.35
        )
        .padding(.top, 24)
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
                .overlay(
                    RoundedRectangle(cornerRadius: AppMetrics.radiusBubble, style: .continuous)
                        .strokeBorder(theme.colors.border, lineWidth: AppMetrics.hairline)
                )
                .clipShape(RoundedRectangle(cornerRadius: AppMetrics.radiusBubble, style: .continuous))
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

    private func runPendingMenuAction() {
        guard let action = pendingMenuAction else { return }
        pendingMenuAction = nil
        switch action {
        case .rename(let row):
            renameText = row.currentName ?? ""
            renameRow = row
        case .delete(let row):
            deleteRow = row
        }
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
    /// deliberately only clears liveness). Until it does, the menu row is shown
    /// disabled with a reason rather than shown-and-failing.
    private static let cachedDeleteSupported = false
}

extension NewSessionModel: Identifiable {
    /// Identity is the presentation, not the machine: the sheet must not be
    /// torn down and rebuilt when the user picks a different Mac, or its
    /// idempotency keys would be re-minted (spec 08 §13.9).
    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
}
