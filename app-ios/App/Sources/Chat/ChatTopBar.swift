import Foundation
import Observation
import RemotePiProtocol
import RemotePiSession
import RemotePiStore
import SwiftUI

// ============================================================================
// The chat's fixed 56pt top bar (spec 08 §8.2) — ported from
// `chat_page.dart:145-260`.
//
// It is a `Container`, not an `AppBar`, in the Dart and it is a plain `HStack`
// here for the same reason: it carries two lines plus a status pill, and every
// piece of it must be paintable from frame 1 out of the hints Home already
// had, so entering a chat never flashes a wrong device or "reconnecting…".
// ============================================================================

/// Title / device / status resolution for the chat bar.
///
/// Pure derivation over plain inputs — no `AppModel`, no SwiftUI — so every
/// fallback chain below is unit-testable.
@MainActor
@Observable
final class ChatTopBarModel {
    /// What Home knew when it opened the chat (`SessionSelection.Selected`).
    ///
    /// These are **seeds, not state**: they paint frame 1 and are outranked by
    /// every resolved value. Without them the bar renders "Remote Pi", "—" and
    /// a grey dot for the few hundred ms before the registry answers, which is
    /// exactly the flash §8.2 was written to kill.
    struct Hints: Equatable, Sendable {
        var title: String?
        var device: String?
        /// Home's live flag for this room. Trusted until
        /// ``connectionResolved`` flips.
        var online: Bool

        init(title: String? = nil, device: String? = nil, online: Bool = false) {
            self.title = title
            self.device = device
            self.online = online
        }
    }

    var hints: Hints

    /// The relay's room metadata for this session, once announced. Never
    /// synthesised: a room the Pi is not listening on has no metadata, and
    /// inventing some would read as a live session (§13.10).
    var meta: RoomMeta?

    /// The pairing record for this machine, once loaded.
    var peer: PeerRecord?

    /// First user message in the transcript — the third title fallback.
    var firstUserMessage: String?

    /// `false` until the app has read a real runtime record for this room.
    /// While it is `false` the pill trusts ``Hints/online`` (§8.2).
    var connectionResolved: Bool = false

    /// The app↔relay socket. A property of the socket, not of the room.
    var isRelayConnected: Bool = false

    /// The relay announced *this* room live.
    var isRoomLive: Bool = false

    /// `relayRoomWorking(epk, roomId) || localOptimisticSignals`. The chat may
    /// OR in its own "I just sent something" signal — unlike Home, which must
    /// not (§7.6.1) — because this flag is scoped to the open session and is
    /// reset on a session switch.
    var isWorking: Bool = false

    init(hints: Hints = Hints()) {
        self.hints = hints
    }

    // MARK: Title (§8.2, `_roomDisplayName`)

    /// `room.name` → cwd basename → first user message (32 chars) → the nav
    /// hint → `"Remote Pi"`, truncated to 28 characters.
    var title: String {
        Self.truncate(resolvedTitle, 28)
    }

    var resolvedTitle: String {
        if let name = meta?.name, !name.isEmpty { return name }
        if let directory = meta?.cwd ?? meta?.workspacePath {
            let basename = directory.split(separator: "/").last.map(String.init) ?? ""
            if !basename.isEmpty { return basename }
        }
        if let inferred = Self.inferredTitle(from: firstUserMessage) { return inferred }
        // Deliberate deviation from `_inferSessionName` (`chat_page.dart:556`):
        // the Dart returns the literal "Remote Pi" as soon as the transcript is
        // non-empty, so a session whose first rows are assistant-only loses the
        // hint Home passed. Falling through to the hint is strictly better and
        // changes nothing when a user message exists.
        if let hint = hints.title, !hint.isEmpty { return hint }
        return "Remote Pi"
    }

    /// First 32 characters of the first user message, whitespace collapsed.
    ///
    /// The collapse is not in the Dart: `Text` with `TextOverflow.ellipsis`
    /// swallows a newline anyway, and a raw `\n` in a mono one-liner otherwise
    /// shows up as a run of spaces.
    static func inferredTitle(from message: String?) -> String? {
        guard let message else { return nil }
        let collapsed = message
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(32))
    }

    // MARK: Device (§8.2, `_peerDisplayName`)

    /// `peer.nickname` → `peer.sessionName` → short key, falling back to the
    /// **device** hint (never the title hint) while the record loads, then
    /// `"—"`. Truncated to 24 characters.
    var deviceLabel: String {
        Self.truncate(resolvedDeviceLabel, 24)
    }

    var resolvedDeviceLabel: String {
        guard let peer else {
            if let hint = hints.device, !hint.isEmpty { return hint }
            return "—"
        }
        return peer.displayLabel
    }

    // MARK: Status pill (§8.2)

    /// The four-state pill, priority `working > reconnecting > online > offline`.
    ///
    /// Reuses ``PresenceLevel/resolve(isWorking:isReconnecting:isLive:)`` — the
    /// one place that ladder is written down — so the pill and Home's dot can
    /// never disagree about what a session is doing.
    var status: PresenceLevel {
        .resolve(
            isWorking: isWorking,
            isReconnecting: connectionResolved && !isRelayConnected,
            isLive: isOnline
        )
    }

    /// `connectionResolved ? isRoomLive : hints.online`. The seeded half is
    /// the whole point of §8.2: until a real runtime record has been read, the
    /// bar shows what Home showed.
    var isOnline: Bool {
        connectionResolved ? isRoomLive : hints.online
    }

    var statusLabel: String {
        Self.label(for: status)
    }

    static func label(for level: PresenceLevel) -> String {
        switch level {
        case .working: "working…"
        case .reconnecting: "reconnecting…"
        case .live: "online"
        case .offline: "offline"
        }
    }

    /// `s.length <= max ? s : s[0..<max-1] + "…"` — the Dart `_truncate`.
    /// Character counts are safe to copy across because both clients render
    /// this bar in a fixed-advance face.
    static func truncate(_ value: String, _ max: Int) -> String {
        guard value.count > max, max > 0 else { return value }
        return String(value.prefix(max - 1)) + "…"
    }
}

// MARK: - View

struct ChatTopBar: View {
    @Bindable var model: ChatTopBarModel
    /// Phone pushes the chat, so it gets a chevron; the tablet detail pane
    /// passes `false` and gets a 16pt spacer (`app_router.dart:437`).
    var showsBack: Bool = true
    var onBack: () -> Void = {}
    /// Session info (§8.14) — owned by another agent. The button is always
    /// rendered regardless (see below); when this is `nil` it is disabled
    /// rather than absent, so the bar's geometry never changes.
    var onInfo: (() -> Void)?

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            if showsBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(theme.colors.text)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
            } else {
                Spacer().frame(width: 16)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(model.title)
                    .font(theme.type.mono(13, weight: .medium))
                    .tracking(-0.2)
                    .foregroundStyle(theme.colors.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 6) {
                    Text(model.deviceLabel)
                        .font(theme.type.mono(10))
                        .foregroundStyle(theme.colors.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(-1)
                    statusPill
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            // ALWAYS rendered, never gated on the async peer record: gating it
            // made the button pop in on load and shift the whole bar
            // (`chat_page.dart:242-257`). Disabled is a state; absent is a
            // layout change.
            Button {
                onInfo?()
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(theme.colors.muted2)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .disabled(onInfo == nil)
            .accessibilityLabel("Session info")
        }
        .padding(.horizontal, 4)
        .frame(height: AppMetrics.chatBarHeight)
        .background(theme.colors.bg)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.colors.border)
                .frame(height: AppMetrics.hairline)
        }
    }

    private var statusPill: some View {
        HStack(spacing: 4) {
            PresenceDot(level: model.status, diameter: 7)
            Text(model.statusLabel)
                .font(theme.type.mono(10))
                .foregroundStyle(statusColor)
                .lineLimit(1)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.statusLabel)
    }

    /// `PresenceDot` keeps its own color mapping private, so the pill's label
    /// repeats it here. Four lines of duplication rather than an edit to the
    /// design system, which this agent does not own — if a third caller ever
    /// needs it, promote it to a `PresenceLevel.color(_:)` there.
    private var statusColor: Color {
        switch model.status {
        case .working: theme.colors.working
        case .reconnecting: theme.colors.warning
        case .live: theme.colors.success
        case .offline: theme.colors.muted
        }
    }
}
