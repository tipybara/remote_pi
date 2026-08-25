import Foundation
import SwiftUI

// ============================================================================
// The live buffer (spec 08 §8.5, `streaming_bubble.dart`).
//
// A streaming turn is **not a message**: it is a buffer that grows, and it is
// rendered by its own row with its own stable identity so the framework never
// re-matches it against a persisted row (§8.4).
// ============================================================================

/// The assistant's in-flight answer.
///
/// ## The duplicate trap this type exists to make visible
///
/// The Flutter client keeps the streaming buffer entirely outside the message
/// list. This client's ingest does the opposite: `ChatIngest.apply` upserts an
/// **assistant row** on every `agent_chunk`, keyed by `in_reply_to`, so the
/// growing text is already in the store and already in `[MessageRow]`.
///
/// That means a naive "append a streaming row at the end" would paint the same
/// tokens twice. ``ChatTranscriptModel`` therefore suppresses the persisted
/// assistant row whose `msgID` equals ``inReplyTo`` while a draft is live —
/// which is why ``inReplyTo`` is on this type at all, and why it must be set
/// by whoever feeds the draft in.
struct StreamingDraft: Hashable, Sendable {
    /// Everything received for this turn so far. May be empty: a turn that has
    /// started but produced no token yet is a bare blinking cursor, which is
    /// the "the agent is thinking" signal.
    var buffer: String
    /// The user message id this answer replies to — the key of the persisted
    /// assistant row that must not also render.
    var inReplyTo: String?

    init(buffer: String = "", inReplyTo: String? = nil) {
        self.buffer = buffer
        self.inReplyTo = inReplyTo
    }

    var hasText: Bool { !buffer.isEmpty }
}

/// Partial Markdown + a blinking cursor on its own line below.
///
/// Inline-beside-the-text placement was rejected in the Dart and is not
/// reintroduced here: with wrapped text the cursor floats toward the middle of
/// the last line.
struct StreamingBubble: View {
    let draft: StreamingDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if draft.hasText {
                // Not selectable: the content changes every frame and a
                // selection would clear itself mid-gesture.
                AgentMarkdown(draft.buffer, selectable: false)
            }
            BlinkingCursor()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(draft.hasText ? draft.buffer : "Agent is responding")
    }
}

/// A 7×14 caret that blinks on a 1000 ms cycle, visible for the first half —
/// the same shape and duty cycle as `_BlinkingCursor`.
///
/// Driven by `TimelineView`, not an `AnimationController` + `@State`: there is
/// no timer to invalidate, nothing to leak when the row disappears mid-turn,
/// and it stops on its own when the view is off-screen.
struct BlinkingCursor: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                // A blinking block is exactly the kind of flashing the setting
                // exists to stop; a steady caret carries the same meaning.
                caret(visible: true)
            } else {
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    caret(visible: Self.isVisible(at: context.date))
                }
            }
        }
        .padding(.leading, 3)
        .padding(.bottom, 1)
        .accessibilityHidden(true)
    }

    private func caret(visible: Bool) -> some View {
        Rectangle()
            .fill(visible ? theme.colors.accent : Color.clear)
            .frame(width: 7, height: 14)
    }

    /// On for the first half of each second — pure, so the phase is testable
    /// and does not depend on when the view happened to mount.
    static func isVisible(at date: Date, period: TimeInterval = 1) -> Bool {
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
        return phase < period / 2
    }
}
