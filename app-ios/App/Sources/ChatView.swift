import RemotePiProtocol
import RemotePiSession
import RemotePiStore
import SwiftUI

struct ChatView: View {
    @Environment(AppModel.self) private var model
    let session: SessionRow
    @State private var draft = ""
    @State private var rows: [MessageRow] = []

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(rows) { row in
                            bubble(row)
                                .id(row.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: rows.count) {
                    if let last = rows.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            composer
        }
        .navigationTitle(session.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await model.openChat(session)
            let stream = await model.messages(for: session.key)
            for await next in stream {
                rows = next
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...6)
            Button {
                let text = draft
                draft = ""
                Task { await model.send(text, to: session.key) }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private func bubble(_ row: MessageRow) -> some View {
        switch row.role {
        case .user:
            HStack {
                Spacer(minLength: 48)
                Text(row.text)
                    .padding(10)
                    .background(row.pending ? Color.accentColor.opacity(0.45) : Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        case .assistant:
            HStack {
                Text(row.text)
                    .padding(10)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                Spacer(minLength: 48)
            }
        case .tool:
            Label(row.tool?.tool ?? row.text, systemImage: "wrench.and.screwdriver")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        case .compaction:
            Text(row.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        case .divider:
            Divider()
        }
    }
}
