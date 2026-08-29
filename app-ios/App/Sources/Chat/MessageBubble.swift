import Foundation
import RemotePiProtocol
import RemotePiStore
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// ============================================================================
// Bubbles (spec 08 §8.5) + the Markdown renderer the assistant and the
// streaming bubble share (`agent_markdown.dart`).
//
// Ported from `app/lib/ui/chat/widgets/message_bubble.dart` and
// `image_bubble.dart`. Four row kinds render here:
//
//   user       right-aligned card, capped at 300pt, with a lifecycle badge
//   assistant  NO bubble chrome — full content width Markdown
//   compaction centered 360pt card
//   divider    local-only "the Pi restarted here" rule (no Dart twin)
//
// Tool rows are `ToolCard.swift`; the live buffer is `StreamingBubble.swift`.
// ============================================================================

// MARK: - User bubble

/// The lifecycle stage a user row is rendered in (§8.5).
///
/// **Why this is computed and not read off the row.** The Dart client carries
/// an explicit `UserMsgStatus.failed`; the Swift store has no such column —
/// `SQLiteSessionStore.reapExpiredPending` *deletes* a pending row 20 s after
/// it was written. So `failed` here means "still `pending`, and older than the
/// Pi's echo deadline". The state is genuinely reachable: a row written just
/// before the app was killed is still `pending` on the next launch and nothing
/// reaps it until the next send, which is exactly the case the badge exists
/// for ("not delivered", spec §8.5).
enum UserBubbleStatus: Hashable, Sendable {
    case confirmed
    case pending
    case steering
    case failed

    /// The Pi is expected to echo a `user_message` back within ~15 s
    /// (`chat_page.dart` / spec §8.5). Kept below the store's 20 s reap so the
    /// badge is visible before the row disappears.
    static let echoDeadlineMilliseconds: Int64 = 15_000

    /// Priority is `failed > steering > pending`, matching the Dart branch
    /// order (`message_bubble.dart:69-104`): a steering message that never
    /// landed must still read "not delivered".
    static func resolve(
        pending: Bool,
        steering: Bool,
        ts: Int64,
        now: Int64,
        deadline: Int64 = echoDeadlineMilliseconds
    ) -> UserBubbleStatus {
        guard pending else { return .confirmed }
        if now - ts >= deadline { return .failed }
        if steering { return .steering }
        return .pending
    }
}

/// Terminal redesign (2026-08-29): the user's message is a **prompt line**,
/// not a chat bubble. `❯ text` in the accent green, left-aligned and full
/// width — the transcript reads like a terminal scrollback: what you typed at
/// the prompt, then what the machine printed. The right-aligned card this
/// replaces was the one element that made the screen read as iMessage.
///
/// The lifecycle survives as color + badge instead of card chrome: pending
/// dims the line, failed turns the prompt glyph red and keeps the
/// "not delivered" badge (now leading, under the line it describes).
struct UserBubble: View {
    let row: MessageRow
    var status: UserBubbleStatus = .confirmed
    /// Resolves attachment bytes. `nil` (the default) renders a compact
    /// "image" chip instead of a thumbnail — see ``AttachmentThumbnail``.
    var imageProvider: ((AttachmentRef) -> Data?)?

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            promptLine
                .opacity(status == .pending || status == .steering ? 0.6 : 1)
            badge
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var glyphColor: Color {
        status == .failed ? theme.colors.error : theme.colors.accent
    }

    @ViewBuilder
    private var promptLine: some View {
        // Baseline-aligned HStack rather than one concatenated Text, so a
        // wrapped message hang-indents under its own first character instead
        // of under the glyph — exactly how a shell continuation line sits.
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("❯")
                .font(theme.type.mono(13, weight: .bold))
                .foregroundStyle(glyphColor)
                .accessibilityHidden(true)
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if let attachment = row.attachments.first {
            // Plan 30 decision #7: no tap, no zoom, no full-screen. The
            // thumbnail is the whole feature.
            AttachmentThumbnail(
                ref: attachment,
                caption: row.text,
                isFailed: status == .failed,
                provider: imageProvider
            )
            .frame(maxWidth: AppMetrics.userBubbleMaxWidth, alignment: .leading)
        } else {
            Text(row.text)
                .font(theme.type.mono(13))
                .foregroundStyle(theme.colors.text)
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var badge: some View {
        switch status {
        case .confirmed:
            EmptyView()
        case .pending, .steering:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                    .tint(theme.colors.muted)
                Text(status == .steering ? "steering…" : "sending…")
                    .font(theme.type.mono(11))
                    .foregroundStyle(theme.colors.muted)
            }
            .padding(.leading, 18)
        case .failed:
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.colors.error)
                Text("not delivered")
                    .font(theme.type.mono(11))
                    .foregroundStyle(theme.colors.error)
            }
            .padding(.leading, 18)
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Assistant bubble

/// No bubble chrome at all (§8.5): full content width Markdown, selectable.
/// The list already pads the gutter, so this spans it edge to edge.
struct AssistantBubble: View {
    let text: String

    var body: some View {
        AgentMarkdown(text, selectable: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Compaction bubble

struct CompactionBubble: View {
    let summary: String
    var tokensBefore: Int64?

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.colors.success)
                Text("Context compacted")
                    .font(theme.type.mono(12, weight: .semibold))
                    .foregroundStyle(theme.colors.text)
                Spacer(minLength: 8)
                if let tokensBefore {
                    Text("~\(tokensBefore) tokens")
                        .font(theme.type.mono(11))
                        .foregroundStyle(theme.colors.muted)
                }
            }
            if !summary.isEmpty {
                Text(summary)
                    .font(theme.type.mono(12))
                    .foregroundStyle(theme.colors.muted2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 360)
        .background(theme.colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(theme.colors.border, lineWidth: AppMetrics.hairline)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - Session divider

/// `MessageRole.divider` — local-only, no Dart equivalent (see
/// `StoreModels.swift`). The Flutter client *deletes* everything above a Pi
/// restart; the store here keeps it and marks the boundary, so this row is the
/// only thing telling the reader why the context above is not in the agent's
/// head any more.
struct SessionDividerRow: View {
    var label: String = "New Pi session"

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            rule
            Text(label)
                .font(theme.type.mono(10))
                .foregroundStyle(theme.colors.muted)
                .fixedSize()
            rule
        }
        .accessibilityElement(children: .combine)
    }

    private var rule: some View {
        Rectangle()
            .fill(theme.colors.border)
            .frame(height: AppMetrics.hairline)
    }
}

// MARK: - Attachment thumbnail

/// The image half of a user bubble (§8.5, `image_bubble.dart`).
///
/// The bytes are decoded **once**, in `.task(id:)`, not per frame: the Dart
/// widget does the same in `initState`/`didUpdateWidget` because decoding a
/// base64 payload on every scroll frame drops the list to single digits. A
/// decode failure paints a placeholder rather than throwing.
struct AttachmentThumbnail: View {
    let ref: AttachmentRef
    var caption: String = ""
    var isFailed: Bool = false
    var provider: ((AttachmentRef) -> Data?)?

    @Environment(\.theme) private var theme
    @State private var decoded: Image?
    @State private var didAttemptDecode = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
            if !caption.isEmpty {
                Text(caption)
                    .font(theme.type.mono(13))
                    .foregroundStyle(theme.colors.text)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(theme.colors.userBubble)
        .clipShape(RoundedRectangle(cornerRadius: AppMetrics.radiusBubble, style: .continuous))
        .overlay {
            if isFailed {
                RoundedRectangle(cornerRadius: AppMetrics.radiusBubble, style: .continuous)
                    .strokeBorder(theme.colors.error, lineWidth: AppMetrics.hairline)
            }
        }
        // Keyed by the content hash: the same image in two rows decodes once
        // per row and never re-decodes on a redraw.
        .task(id: ref.sha256Hex) { decode() }
    }

    @ViewBuilder
    private var content: some View {
        if let decoded {
            decoded
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: 220)
                .clipped()
        } else if didAttemptDecode {
            placeholder(systemImage: "photo.badge.exclamationmark", label: "image unavailable")
        } else {
            placeholder(systemImage: "photo", label: "\(ref.byteLength) bytes")
        }
    }

    private func placeholder(systemImage: String, label: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .light))
            Text(label)
                .font(theme.type.mono(10))
        }
        .foregroundStyle(theme.colors.muted)
        .frame(maxWidth: .infinity, minHeight: 120)
        .background(theme.colors.codeBg)
    }

    private func decode() {
        guard decoded == nil, let provider else {
            didAttemptDecode = provider != nil
            return
        }
        didAttemptDecode = true
        guard let data = provider(ref) else { return }
        decoded = Image.fromEncoded(data)
    }
}

extension Image {
    /// Decodes JPEG/PNG bytes into a SwiftUI `Image`, or `nil`.
    ///
    /// The platform branch exists so this file also compiles for a macOS test
    /// host; the app itself only ever takes the UIKit path.
    static func fromEncoded(_ data: Data) -> Image? {
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        return Image(uiImage: image)
        #elseif canImport(AppKit)
        guard let image = NSImage(data: data) else { return nil }
        return Image(nsImage: image)
        #else
        return nil
        #endif
    }
}

// MARK: - Markdown

/// One block of an agent message.
///
/// The parse is deliberately shallow and **tolerant of unterminated syntax**:
/// it is what drives the streaming bubble, where the last fence is open by
/// definition (`agent_markdown.dart`: "tolerant of partial markdown so it can
/// also drive the live streaming bubble").
enum MarkdownBlock: Hashable, Sendable, Identifiable {
    /// Inline-markdown source for one paragraph (soft line breaks kept).
    case paragraph(String)
    case heading(level: Int, text: String)
    /// `marker` is the rendered bullet ("•") or the ordered label ("1.").
    case listItem(marker: String, text: String)
    case quote(String)
    /// `closed == false` for a fence the stream has not finished yet.
    case code(language: String, code: String, closed: Bool)
    case rule

    var id: String {
        switch self {
        case .paragraph(let text): "p:\(text.hashValue)"
        case .heading(let level, let text): "h\(level):\(text.hashValue)"
        case .listItem(let marker, let text): "li:\(marker):\(text.hashValue)"
        case .quote(let text): "q:\(text.hashValue)"
        case .code(let language, let code, _): "c:\(language):\(code.hashValue)"
        case .rule: "hr"
        }
    }
}

/// Block-level Markdown split, done by hand.
///
/// **Why not `AttributedString(markdown:interpretedSyntax: .full)`.** That
/// parser does produce block structure, but only as `presentationIntent`
/// attributes on one flat string — turning those back into stacked views,
/// scrollable code blocks and a copy button is more work than this split, and
/// it hard-fails on the unterminated fences streaming produces every frame.
/// Inline syntax (`**bold**`, `` `code` ``, links) still goes through
/// `AttributedString`, which is where that parser is genuinely good.
///
/// No third-party Markdown library: that is a standing constraint of this
/// client, not a preference.
enum MarkdownParser {
    static func blocks(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []

        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n")
            paragraph.removeAll()
            let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { blocks.append(.paragraph(trimmed)) }
        }

        var lines = source.components(separatedBy: "\n")[...]
        while let line = lines.first {
            lines = lines.dropFirst()
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let fence = FenceInfo(trimmed) {
                flushParagraph()
                var body: [String] = []
                var closed = false
                while let next = lines.first {
                    lines = lines.dropFirst()
                    let candidate = next.trimmingCharacters(in: .whitespaces)
                    if candidate.hasPrefix(fence.marker), FenceInfo(candidate)?.language.isEmpty == true {
                        closed = true
                        break
                    }
                    body.append(next)
                }
                blocks.append(
                    .code(
                        language: fence.language,
                        code: body.joined(separator: "\n"),
                        closed: closed
                    )
                )
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            if isThematicBreak(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                continue
            }

            if let heading = headingLevel(trimmed) {
                flushParagraph()
                let text = String(trimmed.dropFirst(heading))
                    .trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: heading, text: text))
                continue
            }

            if let item = listItem(trimmed) {
                flushParagraph()
                blocks.append(.listItem(marker: item.marker, text: item.text))
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                blocks.append(
                    .quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                )
                continue
            }

            paragraph.append(line)
        }
        flushParagraph()
        return blocks
    }

    private struct FenceInfo {
        let marker: String
        let language: String

        init?(_ trimmed: String) {
            for marker in ["```", "~~~"] where trimmed.hasPrefix(marker) {
                self.marker = marker
                self.language = String(trimmed.dropFirst(marker.count))
                    .trimmingCharacters(in: .whitespaces)
                return
            }
            return nil
        }
    }

    private static func headingLevel(_ trimmed: String) -> Int? {
        var level = 0
        for character in trimmed {
            if character == "#" { level += 1 } else { break }
        }
        guard (1...6).contains(level) else { return nil }
        // "#hashtag" is not a heading — ATX requires a space after the run.
        let rest = trimmed.dropFirst(level)
        guard rest.isEmpty || rest.hasPrefix(" ") else { return nil }
        return level
    }

    private static func listItem(_ trimmed: String) -> (marker: String, text: String)? {
        for bullet in ["- ", "* ", "+ "] where trimmed.hasPrefix(bullet) {
            return ("•", String(trimmed.dropFirst(bullet.count)))
        }
        // `1. `, `12) ` …
        let digits = trimmed.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = trimmed.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return ("\(digits).", String(rest.dropFirst(2)))
    }

    private static func isThematicBreak(_ trimmed: String) -> Bool {
        guard trimmed.count >= 3 else { return false }
        for character in ["-", "*", "_"] where trimmed.allSatisfy({ String($0) == character }) {
            return true
        }
        return false
    }

    /// Inline formatting for one block's source.
    ///
    /// `.returnPartiallyParsedIfPossible` is not optional here: a half-typed
    /// `[link](` arrives on every other streaming frame, and the throwing
    /// initializer would blank the bubble.
    static func inline(_ source: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: source, options: options) else {
            return AttributedString(source)
        }
        return parsed
    }
}

/// Renders an agent message (or a partial one) as themed Markdown.
struct AgentMarkdown: View {
    let source: String
    /// Off for the streaming bubble: selection on content that changes every
    /// frame fights the gesture and clears itself (`agent_markdown.dart:24`).
    var selectable: Bool = false

    @Environment(\.theme) private var theme

    init(_ source: String, selectable: Bool = false) {
        self.source = source
        self.selectable = selectable
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(MarkdownParser.blocks(source)) { block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(enabled: selectable)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            styledText(text)
                .font(theme.type.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .heading(let level, let text):
            styledText(text)
                .font(theme.type.mono(headingSize(level), weight: .semibold))
                .foregroundStyle(theme.colors.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
        case .listItem(let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .font(theme.type.body)
                    .foregroundStyle(theme.colors.muted)
                styledText(text)
                    .font(theme.type.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 4)
        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                Rectangle()
                    .fill(theme.colors.border)
                    .frame(width: 2)
                styledText(text)
                    .font(theme.type.body)
                    .foregroundStyle(theme.colors.muted2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let language, let code, _):
            CodeBlock(language: language, code: code)
        case .rule:
            Rectangle()
                .fill(theme.colors.border)
                .frame(height: AppMetrics.hairline)
        }
    }

    /// Inline runs marked as `code` get the highlight color and the code
    /// background — the one thing `AttributedString` will not do for us.
    private func styledText(_ source: String) -> Text {
        var attributed = MarkdownParser.inline(source)
        let codeRanges = attributed.runs.compactMap { run in
            run.inlinePresentationIntent?.contains(.code) == true ? run.range : nil
        }
        for range in codeRanges {
            attributed[range].foregroundColor = theme.colors.highlight
            attributed[range].backgroundColor = theme.colors.codeBg
        }
        return Text(attributed)
            .foregroundColor(theme.colors.monoText)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 17
        case 2: 15.5
        case 3: 14
        default: 13
        }
    }
}

extension View {
    /// `textSelection(.enabled)` and `textSelection(.disabled)` are two
    /// *different* types, so `selectable ? .enabled : .disabled` does not type
    /// check. This is the branch that does.
    @ViewBuilder
    func textSelection(enabled: Bool) -> some View {
        if enabled {
            textSelection(.enabled)
        } else {
            textSelection(.disabled)
        }
    }
}

/// A fenced code block: language caption, copy button, horizontal scroll.
///
/// The scroll container is not optional — an 80-column line of code in a
/// 390pt-wide phone otherwise forces the whole transcript to scroll sideways.
struct CodeBlock: View {
    let language: String
    let code: String

    @Environment(\.theme) private var theme
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(theme.type.mono(10))
                    .foregroundStyle(theme.colors.muted)
                Spacer(minLength: 8)
                Button {
                    copy()
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 13))
                        .foregroundStyle(copied ? theme.colors.success : theme.colors.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copied ? "Copied" : "Copy code")
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(theme.type.body)
                    .foregroundStyle(theme.colors.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.colors.codeBg)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(theme.colors.border, lineWidth: AppMetrics.hairline)
        }
    }

    private func copy() {
        #if canImport(UIKit)
        UIPasteboard.general.string = code
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        #endif
        copied = true
        // 1.5 s, same as the Dart copy button. A detached `Task` would outlive
        // the view; this one is cancelled with it.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            copied = false
        }
    }
}
