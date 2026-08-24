import RemotePiProtocol
import RemotePiSession
import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var pairingCode = ""
    @State private var showPairSheet = false
    @State private var path: [SessionRow] = []
    @State private var renaming: SessionRow?
    @State private var renameDraft = ""

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                switch model.phase {
                case .booting:
                    ProgressView("Starting…")
                case .failed(let message):
                    ContentUnavailableView(
                        "Could not start",
                        systemImage: "exclamationmark.triangle",
                        description: Text(message)
                    )
                case .ready:
                    sessionList
                }
            }
            .navigationTitle("Remote Pi")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    connectionLabel
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showPairSheet = true
                    } label: {
                        Image(systemName: "qrcode")
                    }
                    .accessibilityLabel("Pair")
                }
            }
            .sheet(isPresented: $showPairSheet) {
                PairSheet(code: $pairingCode) {
                    showPairSheet = false
                    Task { await model.pair(pasted: pairingCode) }
                }
            }
            .navigationDestination(for: SessionRow.self) { session in
                ChatView(session: session)
            }
            .onChange(of: model.openedSession?.id) {
                if let opened = model.openedSession, path.last?.id != opened.id {
                    path = [opened]
                }
            }
            .alert(
                "Rename",
                isPresented: Binding(
                    get: { renaming != nil },
                    set: { if !$0 { renaming = nil } }
                )
            ) {
                TextField("Name", text: $renameDraft)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Save") {
                    if let session = renaming {
                        Task { await model.rename(session.key, to: renameDraft) }
                    }
                    renaming = nil
                }
            }
        }
    }

    @ViewBuilder
    private var sessionList: some View {
        if model.peers.isEmpty {
            ContentUnavailableView(
                "No pairings yet",
                systemImage: "macbook.and.iphone",
                description: Text("Paste a pairing code from your Mac to start.")
            )
            .safeAreaInset(edge: .bottom) { relayBar }
        } else {
            List {
                if let lastError = model.lastError {
                    Section {
                        Text(lastError)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
                ForEach(model.catalog) { device in
                    Section {
                        ForEach(device.workspaces) { workspace in
                            if !workspace.path.isEmpty {
                                Text(workspaceHeader(workspace))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 0, trailing: 20))
                                    .listRowSeparator(.hidden)
                            }
                            ForEach(workspace.sessions) { session in
                                sessionRow(session)
                            }
                        }
                    } header: {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(device.presence.isOnline ? Color.green : Color.secondary)
                                .frame(width: 8, height: 8)
                            Text(deviceTitle(device))
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { relayBar }
        }
    }

    private var connectionLabel: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(connectionColor)
                .frame(width: 8, height: 8)
            Text(connectionText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var relayBar: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 8) {
            if let lastError = model.lastError, model.peers.isEmpty {
                Text(lastError)
                    .foregroundStyle(.red)
                    .font(.footnote)
            }
            HStack {
                TextField("Relay URL", text: $model.relayURLText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.footnote.monospaced())
                Button("Connect") {
                    Task { await model.connect() }
                }
                .disabled(model.connection == .connecting)
            }
            Text("Owner …\(model.ownerShort) · \(model.keyStoreSource)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func sessionRow(_ session: SessionRow) -> some View {
        NavigationLink(value: session) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayName)
                        .foregroundStyle(.primary)
                    if let modelName = session.meta.model, !modelName.isEmpty {
                        Text(modelName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Circle()
                    .fill(session.isLive ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Rename") {
                renameDraft = session.displayName
                renaming = session
            }
        }
        .contextMenu {
            Button("Rename") {
                renameDraft = session.displayName
                renaming = session
            }
        }
    }

    private func deviceTitle(_ device: DeviceGroup) -> String {
        if let hostname = device.record?.hostname, !hostname.isEmpty {
            return hostname
        }
        return device.displayName
    }

    private func workspaceHeader(_ workspace: WorkspaceGroup) -> String {
        "\(workspace.displayName) (\(workspace.sessions.count))"
    }

    private var connectionColor: Color {
        switch model.connection {
        case .online: .green
        case .connecting, .retrying: .orange
        case .offline: .red
        case .idle: .secondary
        }
    }

    private var connectionText: String {
        switch model.connection {
        case .online: "Relay"
        case .connecting: "Connecting"
        case .retrying(let attempt): "Retry \(attempt + 1)"
        case .offline: "Offline"
        case .idle: "Idle"
        }
    }
}

private struct PairSheet: View {
    @Binding var code: String
    var onPair: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("remotepi://pair?…", text: $code, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(4...8)
                        .font(.footnote.monospaced())
                } footer: {
                    Text("The simulator has no camera. Paste a remotepi://pair payload from the Mac extension.")
                }
            }
            .navigationTitle("Paste pairing code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Pair", action: onPair)
                        .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
