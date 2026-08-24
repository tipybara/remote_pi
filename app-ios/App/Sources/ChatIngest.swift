import Foundation
import RemotePiProtocol
import RemotePiStore

/// Turns inbound App↔Pi frames into store writes.
///
/// Lives in the app target because the library store is UI-free and the
/// coordinator only forwards raw payloads. Streaming drafts stay here: an
/// `agent_chunk` is not a row until it has been accumulated.
enum ChatIngest {
    static func historyEntries(from events: [SessionHistoryEvent]) -> [HistoryEntry] {
        events.compactMap { event in
            switch event {
            case .userInput(let ts, let id, let text, let images):
                return HistoryEntry(
                    row: MessageRow(role: .user, msgID: id, text: text, ts: ts),
                    images: images
                )
            case .agentMessage(let ts, let inReplyTo, let text, _):
                return HistoryEntry(
                    row: MessageRow(
                        role: .assistant,
                        msgID: inReplyTo,
                        text: text,
                        ts: ts,
                        inReplyTo: inReplyTo
                    )
                )
            case .toolRequest(let ts, let toolCallID, let tool, let args):
                return HistoryEntry(
                    row: MessageRow(
                        role: .tool,
                        msgID: toolCallID,
                        text: tool,
                        ts: ts,
                        tool: ToolPayload(
                            toolCallID: toolCallID,
                            tool: tool,
                            argsJSON: args.flatMap { try? WireJSON.encode($0) },
                            status: .pending
                        )
                    )
                )
            case .toolResult(let ts, let toolCallID, let result, let error):
                return HistoryEntry(
                    row: MessageRow(
                        role: .tool,
                        msgID: toolCallID,
                        text: error ?? "",
                        ts: ts,
                        tool: ToolPayload(
                            toolCallID: toolCallID,
                            tool: "unknown",
                            status: error == nil ? .completed : .failed,
                            resultJSON: result.flatMap { try? WireJSON.encode($0) },
                            error: error
                        )
                    )
                )
            case .compaction(let ts, let summary, let tokensBefore):
                return HistoryEntry(
                    row: MessageRow(
                        role: .compaction,
                        msgID: "compaction_\(ts)",
                        text: summary,
                        ts: ts,
                        tokensBefore: tokensBefore.map(Int64.init)
                    )
                )
            }
        }
    }

    static func apply(
        _ message: ServerMessage,
        session: SessionKey,
        store: SQLiteSessionStore,
        drafts: inout [String: String]
    ) async throws {
        switch message {
        case .userInput(let payload):
            let confirmed = try await store.confirmUserEcho(id: payload.id, for: session)
            if !confirmed {
                _ = try await store.upsert(
                    HistoryEntry(
                        row: MessageRow(
                            role: .user,
                            msgID: payload.id,
                            text: payload.text,
                            ts: SQLiteSessionStore.nowMilliseconds()
                        ),
                        images: payload.images
                    ),
                    for: session
                )
            }

        case .agentChunk(let chunk):
            drafts[chunk.inReplyTo, default: ""] += chunk.delta
            _ = try await store.upsert(
                HistoryEntry(
                    row: MessageRow(
                        role: .assistant,
                        msgID: chunk.inReplyTo,
                        text: drafts[chunk.inReplyTo] ?? chunk.delta,
                        ts: SQLiteSessionStore.nowMilliseconds(),
                        inReplyTo: chunk.inReplyTo
                    )
                ),
                for: session
            )

        case .agentDone(let done):
            drafts[done.inReplyTo] = nil

        case .agentMessage(let payload):
            drafts[payload.inReplyTo] = nil
            _ = try await store.upsert(
                HistoryEntry(
                    row: MessageRow(
                        role: .assistant,
                        msgID: payload.inReplyTo,
                        text: payload.text,
                        ts: SQLiteSessionStore.nowMilliseconds(),
                        inReplyTo: payload.inReplyTo
                    )
                ),
                for: session,
                insertOnly: true
            )

        case .sessionHistory(let history):
            _ = try await store.applyHistory(
                historyEntries(from: history.events),
                sessionStartedAt: history.sessionStartedAt,
                eos: history.eos,
                for: session
            )

        case .toolRequest(let payload):
            _ = try await store.upsert(
                HistoryEntry(
                    row: MessageRow(
                        role: .tool,
                        msgID: payload.toolCallID,
                        text: payload.tool,
                        ts: SQLiteSessionStore.nowMilliseconds(),
                        tool: ToolPayload(
                            toolCallID: payload.toolCallID,
                            tool: payload.tool,
                            argsJSON: payload.args.flatMap { try? WireJSON.encode($0) },
                            status: .pending
                        )
                    )
                ),
                for: session
            )

        case .toolResult(let payload):
            try await store.updateTool(
                toolCallID: payload.toolCallID,
                status: payload.error == nil ? .completed : .failed,
                result: payload.result.map { .set((try? WireJSON.encode($0)) ?? Data()) } ?? .absent,
                error: payload.error.map { .set($0) } ?? .absent,
                for: session
            )

        case .compaction(let payload):
            _ = try await store.upsert(
                HistoryEntry(
                    row: MessageRow(
                        role: .compaction,
                        msgID: "compaction_\(SQLiteSessionStore.nowMilliseconds())",
                        text: payload.summary,
                        ts: SQLiteSessionStore.nowMilliseconds(),
                        tokensBefore: payload.tokensBefore.map(Int64.init)
                    )
                ),
                for: session,
                insertOnly: true
            )

        case .error, .cancelled, .pong, .bye, .queuedMessageState, .steerConsumed,
             .pairOk, .pairError, .actionOk, .actionError, .modelsList,
             .extensionUIRequest, .unknown:
            break
        }
    }
}
