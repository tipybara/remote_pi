import RemotePiProtocol
import SwiftUI

/// The New Session sheet (spec 08 §7.9).
///
/// All behaviour lives in ``NewSessionModel``; this file is layout and copy.
/// The model is handed in already built, because its idempotency keys must be
/// minted per presentation, not per render (spec 08 §13.9).
struct NewSessionSheet: View {
    let model: NewSessionModel
    /// Called with the session the machine actually brought online. Home
    /// resolves the announced room from the live snapshot and opens it; it
    /// never synthesises one (spec 08 §13.10).
    let onCreated: (SessionKey) -> Void

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetScaffold(title: "New session", subtitle: headerSubtitle) {
            VStack(alignment: .leading, spacing: 0) {
                body(for: model.phase)
                if let progress = model.progressText { progressRow(progress) }
                if let error = model.errorText { errorRow(error) }
            }
            .padding(.bottom, 12)
        }
        .task { await model.start() }
        .onChange(of: model.created) { _, created in
            guard let created else { return }
            onCreated(created)
            dismiss()
        }
    }

    /// The selected machine, shown as an uppercase label once the picker has
    /// collapsed — so the user can still see which Mac they are spending.
    private var headerSubtitle: String? {
        guard let machine = model.machine else { return nil }
        return NewSessionModel.label(for: machine).uppercased()
    }

    @ViewBuilder
    private func body(for phase: NewSessionPhase) -> some View {
        switch phase {
        case .noMachine:
            message(
                icon: "bolt.horizontal.circle",
                text: "Connect to a paired Mac first — the machine that will run "
                    + "the session has to be reachable."
            )

        case .pickMachine:
            ForEach(model.machines, id: \.peer) { machine in
                pickerRow(
                    icon: "desktopcomputer",
                    title: NewSessionModel.label(for: machine),
                    detail: machine.hostname,
                    isEnabled: true
                ) {
                    Task { await model.select(machine) }
                }
            }

        case .loadingWorkspaces, .creating:
            HStack {
                Spacer()
                ProgressView().tint(theme.colors.accent)
                Spacer()
            }
            .padding(.vertical, 24)

        case .noWorkspaces:
            message(
                icon: "folder.badge.questionmark",
                // Verbatim from the spec: the constraint is deliberate, so the
                // copy names the exact command that lifts it. There is no
                // remote "register this path" — a path on the wire plus the
                // daemon's `--approve` would be user-level RCE.
                text: "This machine has no registered folders yet. Run "
                    + "`remote-pi create <folder>` on it — only registered folders "
                    + "can be started remotely."
            )

        case .pickWorkspace:
            workspaceList

        case .created:
            EmptyView()
        }
    }

    @ViewBuilder
    private var workspaceList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.workspaces ?? [], id: \.workspaceID) { workspace in
                    pickerRow(
                        icon: "folder",
                        title: workspace.displayName,
                        detail: workspace.path,
                        isEnabled: !model.isCreating
                    ) {
                        Task { await model.create(in: workspace) }
                    }
                }
            }
        }
        .frame(maxHeight: 320)
    }

    private func pickerRow(
        icon: String,
        title: String,
        detail: String?,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(isEnabled ? theme.colors.accent : theme.colors.muted)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(theme.type.sans(15))
                        .foregroundStyle(isEnabled ? theme.colors.text : theme.colors.muted)
                        .lineLimit(1)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(theme.type.mono(11))
                            .foregroundStyle(theme.colors.muted)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, AppMetrics.sheetGutter)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    private func progressRow(_ text: String) -> some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small).tint(theme.colors.accent)
            Text(text)
                .font(theme.type.mono(12))
                .foregroundStyle(theme.colors.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, AppMetrics.sheetGutter)
        .padding(.vertical, 8)
    }

    private func errorRow(_ text: String) -> some View {
        Text(text)
            .font(theme.type.mono(12))
            .foregroundStyle(theme.colors.error)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, AppMetrics.sheetGutter)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    private func message(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(theme.colors.muted)
            Text(text)
                .font(theme.type.mono(12))
                .foregroundStyle(theme.colors.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, AppMetrics.sheetGutter)
        .padding(.top, 12)
        .padding(.bottom, 24)
    }
}
