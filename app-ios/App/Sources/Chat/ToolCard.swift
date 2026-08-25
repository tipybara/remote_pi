import Foundation
import RemotePiProtocol
import RemotePiStore
import SwiftUI

// ============================================================================
// Tool cards (spec 08 §8.6) — ported from
// `app/lib/ui/chat/widgets/tool_request_card.dart`.
//
// ## Why there are no Allow / Deny buttons
//
// This is the one place where the brief handed to this screen ("tool approval
// cards are interactive and their decision goes on the wire") disagrees with
// every source of truth, so the disagreement is settled here in writing:
//
//   * spec 08 §8.6: "**Purely informational.** … Do not build approval
//     buttons for iOS v1.";
//   * `tool_request_card.dart:6-17`: the pi-extension emits `tool_request`
//     *after* the SDK has already accepted the tool, so the buttons could only
//     blink for a few hundred milliseconds before `tool_result` arrived;
//   * `RemotePiProtocol.ApproveTool`: "**do not send this.** … the Pi drops it
//     on the floor and never replies … Awaiting a reply hangs forever."
//
// A decision therefore cannot go on the wire today — there is no receiver. The
// `onDecide` seam below is kept for the day the Pi re-adds a real approval
// pause, exactly as the Dart keeps it, and is deliberately not rendered.
// ============================================================================

/// Everything a tool card paints, derived from the stored payload.
///
/// A plain value with no SwiftUI in it, so the formatting rules — which are
/// the part with edge cases — are unit-testable without a host app.
struct ToolCardPresentation: Equatable, Sendable {
    /// Which semantic color token drives the whole card. An enum rather than a
    /// `Color` so this type stays theme-free and testable.
    enum Tone: Equatable, Sendable {
        case accent
        case success
        case error
        case muted
    }

    struct DiffLine: Equatable, Sendable, Identifiable {
        enum Kind: Equatable, Sendable {
            case context
            case add
            case remove
        }

        let kind: Kind
        let text: String
        /// Position within the rendered diff — the only stable id available,
        /// since two identical context lines are genuinely indistinguishable.
        let id: Int
    }

    let tone: Tone
    /// Uppercased tool name, e.g. `BASH`.
    let title: String
    /// `RUNNING` / `DONE` / `FAILED` / `DENIED` / `EXPIRED`.
    let statusLabel: String
    /// `⏳ Running…`, `✓ Done`, `✗ <error>` …
    let outcome: String
    /// Only the inert states dim; `done`/`failed` stay at full opacity so
    /// their green/red reads (`tool_request_card.dart:42-45`).
    let dimmed: Bool
    /// The `$ ` line: the command, the edited path, or `key=value` pairs.
    let command: String
    /// Rendered diff for an `edit` that shipped `hunks`. Empty otherwise.
    let diff: [DiffLine]

    static func make(_ payload: ToolPayload) -> ToolCardPresentation {
        let args = decodeArgs(payload.argsJSON)
        let edit = editDisplay(tool: payload.tool, args: args)
        return ToolCardPresentation(
            tone: tone(for: payload.status),
            title: payload.tool.uppercased(),
            statusLabel: statusLabel(for: payload.status),
            outcome: outcome(status: payload.status, error: payload.error),
            dimmed: payload.status == .denied || payload.status == .expired,
            command: edit?.command ?? formatArgs(tool: payload.tool, args: args),
            diff: edit?.lines ?? []
        )
    }

    // MARK: Status mapping (§8.6 table)

    static func tone(for status: ToolStatus) -> Tone {
        switch status {
        case .pending, .allowed: .accent
        case .completed: .success
        case .failed: .error
        case .denied, .expired: .muted
        }
    }

    static func statusLabel(for status: ToolStatus) -> String {
        switch status {
        case .pending, .allowed: "RUNNING"
        case .completed: "DONE"
        case .failed: "FAILED"
        case .denied: "DENIED"
        case .expired: "EXPIRED"
        }
    }

    static func outcome(status: ToolStatus, error: String?) -> String {
        switch status {
        case .pending, .allowed: "⏳ Running…"
        case .completed: "✓ Done"
        case .failed: "✗ \(error ?? "Failed")"
        case .denied: "✗ \(error ?? "Denied")"
        case .expired: "✗ Expired"
        }
    }

    // MARK: Argument formatting (`tool_request_card.dart:176-225`)

    /// `argsJSON` is opaque bytes on purpose (`StoreModels.ToolPayload`):
    /// typing it would invent a contract that does not exist and would break on
    /// the first unknown tool. So it is decoded loosely, here, at render time.
    static func decodeArgs(_ data: Data?) -> Any? {
        guard let data, !data.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    static func formatArgs(tool: String, args: Any?) -> String {
        guard let args else { return "" }
        guard let map = args as? [String: Any] else {
            return String(describing: args)
        }
        switch tool.lowercased() {
        case "bash":
            return map["command"] as? String ?? ""
        case "edit", "write":
            return "\(tool.lowercased()) \(stringArg(map, keys: ["file_path", "path"]))"
        default:
            // Sorted, unlike the Dart, which walks Dart's insertion-ordered
            // map. `JSONSerialization` hands back an unordered dictionary, so
            // without a sort the same call renders its arguments in a
            // different order on every redraw.
            return map.keys.sorted()
                .map { "\($0)=\(scalar(map[$0]))" }
                .joined(separator: " ")
        }
    }

    private static func scalar(_ value: Any?) -> String {
        switch value {
        case let text as String: text
        case let number as NSNumber: number.stringValue
        case is NSNull, .none: "null"
        case let other: String(describing: other)
        }
    }

    private static func stringArg(_ map: [String: Any], keys: [String]) -> String {
        for key in keys {
            if let value = map[key] as? String { return value }
        }
        return ""
    }

    private struct EditDisplay {
        let command: String
        let lines: [DiffLine]
    }

    private static func editDisplay(tool: String, args: Any?) -> EditDisplay? {
        guard tool.lowercased() == "edit", let map = args as? [String: Any] else { return nil }
        guard let hunks = map["hunks"] as? [Any] else { return nil }

        var lines: [DiffLine] = []
        func append(_ kind: DiffLine.Kind, _ text: String) {
            lines.append(DiffLine(kind: kind, text: text, id: lines.count))
        }

        for hunk in hunks {
            guard let hunk = hunk as? [String: Any],
                  let rawLines = hunk["lines"] as? [Any]
            else { continue }
            // A separator between hunks, never before the first one.
            if !lines.isEmpty { append(.context, "      ...") }
            for rawLine in rawLines {
                guard let rawLine = rawLine as? [String: Any] else { continue }
                let kind = rawLine["kind"] as? String
                switch kind {
                case "context": append(.context, diffLineText(rawLine))
                case "remove": append(.remove, diffLineText(rawLine))
                case "add": append(.add, diffLineText(rawLine))
                case "ellipsis": append(.context, "      ...")
                default: continue
                }
            }
        }

        guard !lines.isEmpty else { return nil }
        return EditDisplay(
            command: "edit \(stringArg(map, keys: ["file_path", "path"]))",
            lines: lines
        )
    }

    /// `"<sign> <line number padded to 3> <text>"`.
    private static func diffLineText(_ rawLine: [String: Any]) -> String {
        let sign: String
        switch rawLine["kind"] as? String {
        case "remove": sign = "-"
        case "add": sign = "+"
        default: sign = " "
        }
        let number: String
        if let value = rawLine["oldLine"] ?? rawLine["newLine"], let int = asInt(value) {
            number = String(repeating: " ", count: max(0, 3 - String(int).count)) + String(int)
        } else {
            number = "   "
        }
        return "\(sign) \(number) \(rawLine["text"] as? String ?? "")"
    }

    private static func asInt(_ value: Any) -> Int? {
        switch value {
        case let int as Int: int
        case let number as NSNumber: number.intValue
        default: nil
        }
    }
}

// MARK: - View

struct ToolCard: View {
    let payload: ToolPayload
    /// Forward-compat seam, unused — see the file header. Kept so the day the
    /// Pi restores a real approval pause, the call site already exists.
    var onDecide: ((String, ApproveDecision) -> Void)?

    @Environment(\.theme) private var theme

    var body: some View {
        let card = ToolCardPresentation.make(payload)
        let color = color(for: card.tone)

        VStack(alignment: .leading, spacing: 0) {
            header(card, color: color)
                .padding(.bottom, 10)
            codeBlock(card)
                .padding(.bottom, 8)
            Text(card.outcome)
                .font(theme.type.mono(12))
                .foregroundStyle(color)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppMetrics.radiusBubble, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppMetrics.radiusBubble, style: .continuous)
                .strokeBorder(color, lineWidth: AppMetrics.hairline)
        }
        // The Dart draws a 20pt blurred glow at 13% of the status color; a
        // SwiftUI shadow is the same effect and costs nothing offscreen.
        .shadow(color: color.opacity(0.13), radius: 10)
        .opacity(card.dimmed ? 0.65 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(card.title) \(card.statusLabel)")
    }

    private func header(_ card: ToolCardPresentation, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(color)
            Text(card.title)
                .font(theme.type.mono(11.5))
                .foregroundStyle(color)
                .tracking(0.6)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(card.statusLabel)
                .font(theme.type.mono(10))
                .foregroundStyle(color)
                .tracking(0.4)
        }
    }

    private func codeBlock(_ card: ToolCardPresentation) -> some View {
        // Horizontal scroll, like `CodeBlock`: a long `bash` command must not
        // make the transcript itself scroll sideways.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 0) {
                Text("$ ")
                    .font(theme.type.body)
                    .foregroundStyle(theme.colors.muted)
                VStack(alignment: .leading, spacing: 0) {
                    Text(card.command)
                        .font(theme.type.body)
                        .foregroundStyle(theme.colors.monoText)
                    ForEach(card.diff) { line in
                        Text(line.text)
                            .font(theme.type.body)
                            .foregroundStyle(color(for: line.kind))
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.colors.codeBg)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(theme.colors.border, lineWidth: AppMetrics.hairline)
        }
    }

    private func color(for tone: ToolCardPresentation.Tone) -> Color {
        switch tone {
        case .accent: theme.colors.accent
        case .success: theme.colors.success
        case .error: theme.colors.error
        case .muted: theme.colors.muted
        }
    }

    private func color(for kind: ToolCardPresentation.DiffLine.Kind) -> Color {
        switch kind {
        case .context: theme.colors.text
        case .add: theme.colors.success
        case .remove: theme.colors.error
        }
    }
}
