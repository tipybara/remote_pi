import Foundation
import Observation
import RemotePiProtocol
import RemotePiStore
import SwiftUI

// ============================================================================
// The chat transcript (spec 08 §8.1 body mapping, §8.4 list, §8.5 rows).
//
// Ported from `app/lib/ui/chat/chat_page.dart` (`_buildBody`, `_MessageList`).
//
// This file owns the *body* of the chat only. The top bar is
// `ChatTopBar.swift`, the revoked banner `RevokedBanner.swift`, and the
// composer belongs to another screen agent — §8.3 is explicit that the offline
// / Pi-gone / presence-off banners were deleted on purpose, so the transcript
// has no connection chrome of its own: the status pill says it once.
// ============================================================================

// MARK: - Items

/// One row of the rendered transcript.
///
/// Identity is the pair `(role, msgID)`, never the index (§8.4): when the
/// streaming row appears or disappears every other index shifts by one, and a
/// list keyed by position briefly paints the wrong message in a slot.
/// `MessageRow.id` is already `MessageIdentity`, which is the pair — an id
/// alone collides, because an assistant row is stored under the *user*
/// message's id (`in_reply_to`).
enum TranscriptItem: Identifiable, Hashable, Sendable {
    case message(MessageRow)
    case streaming(StreamingDraft)

    var id: String {
        switch self {
        case .message(let row): "\(row.role.rawValue):\(row.msgID)"
        // One stable key for the whole turn, exactly like
        // `ValueKey('streaming')`. It must NOT include the buffer: a key that
        // changes with the text is a new row every frame.
        case .streaming: "streaming"
        }
    }
}

/// What the body renders (§8.1).
///
/// `ChatConnecting` from the Dart is deliberately absent: `_compose` returns
/// `ChatReady(messages: [])` while bootstrapping and there is no connecting
/// spinner, so entering a chat never flickers a full-screen state swap.
enum ChatBodyState: Equatable, Sendable {
    /// Opened without a peer — e.g. the pairing was revoked while the user was
    /// here. Renders **without** an action button: the chat is not the place
    /// to pair.
    case noPeer
    /// Bootstrap failed outright. Offers `Re-pair`.
    case fatal(String)
    /// Ready, nothing to show.
    case empty
    case ready
}

// MARK: - Model

/// The transcript's presentation logic, with no SwiftUI in it.
///
/// ## How it is fed
///
/// Deliberately dependency-free: it takes values, it does not reach for
/// `AppModel`. The chat screen owns the subscriptions (`ChatScreenModel`
/// streams `[MessageRow]` out of the store) and pushes them in here. That
/// keeps every rule below testable without a host app, and keeps this file out
/// of the way of the screen agent that owns `ChatScreen.swift`.
///
/// ```swift
/// transcript.apply(messages: rows)
/// transcript.hideToolCalls = app.preferences.hideToolCalls
/// transcript.hasPeer = app.hasPeer
/// ```
@MainActor
@Observable
final class ChatTranscriptModel {
    /// Persisted rows, oldest first — the order `SQLiteSessionStore` yields.
    private(set) var messages: [MessageRow] = []

    /// The live buffer, when a turn is streaming. See ``StreamingDraft`` for
    /// why this is not simply the last assistant row.
    private(set) var streaming: StreamingDraft?

    /// `Preferences.hideToolCalls`. Presentation-only: the events stay in the
    /// store, so flipping this back shows the history that was always there.
    var hideToolCalls: Bool = false

    /// `false` only after bootstrap finished without a paired machine.
    /// Defaults to `true` so a chat opened from Home never flashes "No active
    /// device" before the peer list loads.
    var hasPeer: Bool = true

    /// Set for `ChatFatalError`. `nil` in every ordinary failure — a dropped
    /// socket is not fatal, it is the status pill's job.
    var fatalError: String?

    /// Wall clock used to age out pending user rows. Injected rather than read
    /// inline so "not delivered" is testable without waiting 15 seconds.
    private(set) var now: Int64 = SQLiteSessionStore.nowMilliseconds()

    init() {}

    // MARK: Inputs

    func apply(messages: [MessageRow]) {
        self.messages = messages
        // A new batch is a good moment to re-age pending rows; the view also
        // ticks the clock while any row is pending.
        now = SQLiteSessionStore.nowMilliseconds()
    }

    func apply(streaming draft: StreamingDraft?) {
        streaming = draft
    }

    func refreshClock(now: Int64 = SQLiteSessionStore.nowMilliseconds()) {
        self.now = now
    }

    // MARK: Derived

    var items: [TranscriptItem] {
        Self.build(messages: messages, streaming: streaming, hideToolCalls: hideToolCalls)
    }

    var state: ChatBodyState {
        // Order matters: a fatal error wins over everything, and "no device"
        // wins over a cached transcript — the rows are stale by definition
        // once the pairing is gone.
        if let fatalError, !fatalError.isEmpty { return .fatal(fatalError) }
        if !hasPeer { return .noPeer }
        return items.isEmpty ? .empty : .ready
    }

    /// `true` while any user row is still waiting for its echo. The view uses
    /// it to run a 1 Hz clock *only* when one is needed — a transcript with
    /// nothing pending must not re-render on a timer.
    var hasPendingRows: Bool {
        messages.contains { $0.role == .user && $0.pending }
    }

    /// The lifecycle badge for one user row.
    func status(for row: MessageRow) -> UserBubbleStatus {
        UserBubbleStatus.resolve(
            pending: row.pending,
            steering: row.steering,
            ts: row.ts,
            now: now
        )
    }

    /// The whole list transform, pure and static so it can be tested directly.
    ///
    /// Two rules that are easy to get wrong:
    ///
    /// 1. `hideToolCalls` drops `.tool` rows **only**. It is a view filter; a
    ///    tool row is still in the store and still counts as history.
    /// 2. While a draft is live, the persisted assistant row it is
    ///    accumulating into is dropped. This client's ingest writes every
    ///    `agent_chunk` straight into the store (`ChatIngest.apply`), so
    ///    without this the same tokens render twice — once in the assistant
    ///    bubble and once in the streaming bubble.
    nonisolated static func build(
        messages: [MessageRow],
        streaming: StreamingDraft?,
        hideToolCalls: Bool
    ) -> [TranscriptItem] {
        var items: [TranscriptItem] = []
        items.reserveCapacity(messages.count + 1)

        for row in messages {
            if hideToolCalls, row.role == .tool { continue }
            if let streaming,
               let inReplyTo = streaming.inReplyTo,
               row.role == .assistant,
               row.msgID == inReplyTo {
                continue
            }
            items.append(.message(row))
        }

        if let streaming { items.append(.streaming(streaming)) }
        return items
    }
}

// MARK: - View

struct ChatTranscriptView: View {
    @Bindable var model: ChatTranscriptModel
    /// `Re-pair` from the fatal state (§8.1). The route belongs to the shell,
    /// so it arrives as a closure rather than being pushed from here.
    var onRePair: () -> Void = {}
    /// Resolves attachment bytes for an image row. `nil` renders a placeholder
    /// chip — see the report: `AppModel` exposes no blob accessor yet.
    var imageProvider: ((AttachmentRef) -> Data?)?

    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            switch model.state {
            case .noPeer:
                // No action button, on purpose (`chat_page.dart:371-378`).
                centered(
                    EmptyStateView(
                        systemImage: "message",
                        title: "No active device"
                    )
                )
            case .fatal(let message):
                centered(
                    EmptyStateView(
                        systemImage: "exclamationmark.circle",
                        title: message,
                        action: {
                            SecondaryButton(title: "Re-pair", action: onRePair)
                                .frame(maxWidth: 200)
                        }
                    )
                )
            case .empty:
                centered(
                    EmptyStateView(
                        systemImage: "terminal",
                        title: "Nothing here"
                    )
                )
            case .ready:
                transcript
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.colors.bg)
        // Age pending rows into "not delivered" without a timer that runs for
        // the whole session. `.task(id:)` restarts when the flag flips and
        // SwiftUI cancels it when the view goes away.
        .task(id: model.hasPendingRows) {
            guard model.hasPendingRows else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                model.refreshClock()
            }
        }
    }

    private func centered(_ content: some View) -> some View {
        VStack {
            Spacer(minLength: 0)
            content
            Spacer(minLength: 0)
        }
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(model.items) { item in
                    row(for: item)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, AppMetrics.sheetGutter)
            .padding(.top, 18)
            .padding(.bottom, 12)
        }
        // The native equivalent of Flutter's `reverse: true` viewport: the
        // scroll starts at the bottom and *stays* pinned there as content
        // arrives. `.sizeChanges` is the load-bearing half — without it the
        // view only starts at the bottom and streaming walks off-screen.
        //
        // Do NOT add a `ScrollViewReader` + `scrollTo` on every rebuild: that
        // is the `animateTo`-per-frame the Dart removed, and it fights this
        // anchor into flicker and runaway scroll during streaming (§8.4).
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder
    private func row(for item: TranscriptItem) -> some View {
        switch item {
        case .streaming(let draft):
            StreamingBubble(draft: draft)
        case .message(let row):
            switch row.role {
            case .user:
                UserBubble(
                    row: row,
                    status: model.status(for: row),
                    imageProvider: imageProvider
                )
            case .assistant:
                AssistantBubble(text: row.text)
            case .tool:
                if let tool = row.tool {
                    ToolCard(payload: tool)
                } else {
                    // A tool row with no payload is a store inconsistency, not
                    // a state to design for — render the bare name rather than
                    // dropping the row silently.
                    AssistantBubble(text: row.text)
                }
            case .compaction:
                CompactionBubble(summary: row.text, tokensBefore: row.tokensBefore)
            case .divider:
                SessionDividerRow(label: row.text.isEmpty ? "New Pi session" : row.text)
            }
        }
    }
}
