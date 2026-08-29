import Foundation
import Observation
import RemotePiProtocol
import SwiftUI

// ============================================================================
// Queued follow-ups — spec 08 §8.8.
//
// **Queue and steer are two different mechanisms and this file only owns one
// of them.** Sending while a turn is in flight is a STEER: an immediate
// `user_message` carrying `streaming_behavior: "steer"` (see `Composer.swift`).
// A queued message is something else — a follow-up parked on the Pi, drained
// into a real turn after the current one ends. The composer never creates one:
// queued items appear here because the Pi broadcast them (another paired
// device, or the TUI), and the composer's job is to show them, let the user
// pull one back for editing, and let the user drop one.
//
// ``QueuedMessagesModel/queue(text:)`` exists because the wire supports it and
// the integration layer may want it; nothing in the composer calls it, which
// matches `input_bar.dart` (it takes an `onSetQueued` it never invokes).
//
// `queued_message_state` is a **full replacement** of the queue, not a delta.
// Applying it as a merge leaves drained items on screen forever.
// ============================================================================

/// The two frames this model needs to put on the wire. Narrow on purpose: the
/// queue is testable without a chat, a socket or an `AppModel`.
@MainActor
protocol QueuedMessageSink: AnyObject {
    /// `queued_message_set {id, text}`. `id` is the id the message will carry
    /// once it is drained into a real turn, so it is minted like a
    /// `user_message` id — see ``newQueuedMessageID()``.
    func queuedMessageSet(id: String, text: String) async
    /// `queued_message_clear`. `targetID == nil` clears the WHOLE queue —
    /// that is the wire's meaning for an omitted `target_id`, and it is not
    /// the same as an empty string, which matches nothing (spec §13.11).
    func queuedMessageClear(targetID: String?) async
}

/// Mints the id a queued message will carry when it becomes a turn.
///
/// Minted once per *intent* — when the user commits the follow-up — and reused
/// by the matching clear. A fresh id per attempt would leave orphaned items on
/// the Pi that no clear can ever address (the same failure mode spec §13.9
/// describes for idempotency keys on the control plane).
func newQueuedMessageID() -> String {
    "cli_\(UUID().uuidString.lowercased())"
}

@MainActor
@Observable
final class QueuedMessagesModel {
    private(set) var items: [QueuedMessageItem] = []

    private let sink: any QueuedMessageSink

    init(sink: any QueuedMessageSink) {
        self.sink = sink
    }

    var isEmpty: Bool { items.isEmpty }

    /// Adopt a `queued_message_state`. Wholesale replacement, empty text
    /// dropped.
    ///
    /// The Kit's decoder already drops empty-text items on the way in; this
    /// repeats the filter because `apply` is also reachable from a locally
    /// constructed state, and a blank queue row is a visible bug either way.
    func apply(_ state: QueuedMessageState) {
        items = state.items.filter { !$0.text.isEmpty }
    }

    /// Park a follow-up. Optimistic: the row appears immediately and the Pi's
    /// next `queued_message_state` replaces it.
    ///
    /// A text that trims to empty is refused rather than sent: the Pi routes an
    /// empty `queued_message_set` to a delete, and a caller that means "delete"
    /// should say so with ``clear(id:)``.
    @discardableResult
    func queue(text: String) async -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let id = newQueuedMessageID()
        items.append(
            QueuedMessageItem(
                id: id,
                text: trimmed,
                editable: true,
                createdAt: Int64(Date().timeIntervalSince1970 * 1000)
            )
        )
        await sink.queuedMessageSet(id: id, text: trimmed)
        return id
    }

    /// Pull an editable item back for editing: clear it on the Pi and hand the
    /// text to the caller. Non-editable items are inert and return `nil`.
    func take(_ item: QueuedMessageItem) async -> String? {
        guard item.editable else { return nil }
        let text = item.text
        await clear(id: item.id)
        return text
    }

    /// The "✕" on one row.
    func clear(id: String) async {
        items.removeAll { $0.id == id }
        await sink.queuedMessageClear(targetID: id)
    }

    /// Drop everything the Pi has parked.
    func clearAll() async {
        items = []
        await sink.queuedMessageClear(targetID: nil)
    }

    /// Session switch or a `session_new`. Local only — it does not tell the Pi
    /// to drop anything, because the queue belongs to the session we are
    /// leaving, not to the one we are entering.
    func reset() {
        items = []
    }
}

// MARK: - View

/// One queued follow-up, rendered above the composer row (spec §8.8).
///
/// Tapping an editable item pulls it back into the field; the ✕ just drops it.
/// A non-editable item is inert — no tap target, no ✕ — because the Pi has
/// already committed it and a clear would race the drain.
struct QueuedMessagePreview: View {
    let item: QueuedMessageItem
    let onEdit: () -> Void
    let onClear: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "bubble.left")
                .font(.system(size: 13))
                .foregroundStyle(theme.colors.accent)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.editable ? "Queued. Tap to edit." : "Queued follow-up.")
                    .font(theme.type.mono(11, weight: .bold))
                    .foregroundStyle(theme.colors.accent)
                Text(item.text)
                    .font(theme.type.mono(12))
                    .lineSpacing(2)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .foregroundStyle(theme.colors.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if item.editable {
                Button(action: onClear) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.colors.muted2)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear queued message")
                .accessibilityIdentifier("input-bar-clear-queued")
            }
        }
        .padding(EdgeInsets(top: 9, leading: 12, bottom: 9, trailing: 8))
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(theme.colors.accent.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(theme.colors.accent.opacity(0.35), lineWidth: AppMetrics.hairline)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            guard item.editable else { return }
            onEdit()
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 10)
        .accessibilityIdentifier("input-bar-queued-preview")
    }
}
