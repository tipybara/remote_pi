import SwiftUI

/// The four presence states a session can be in, in **priority order**
/// (spec 08 §7.6.1, `session_tile.dart:131-143`).
///
/// The ordering is the contract, not a detail: a session that is working while
/// the socket is down must read `working`, and a session that is live while
/// the socket is down must read `reconnecting` — because when the app↔relay
/// WebSocket is gone we have no fresh signal about *any* room, so "live" is a
/// stale claim.
enum PresenceLevel: Int, Comparable, CaseIterable, Sendable {
    /// Cached / not announced. Grey.
    case offline = 0
    /// The relay announced this room live. Green.
    case live = 1
    /// The app↔relay socket is down. Amber. Outranks ``live`` on purpose.
    case reconnecting = 2
    /// The agent is mid-turn **in this room**. Blue. Outranks everything.
    case working = 3

    static func < (lhs: PresenceLevel, rhs: PresenceLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// The one place the priority ladder is written down.
    ///
    /// - Parameters:
    ///   - isWorking: the relay's per-room `meta.working` for **this** room.
    ///     Do not OR this with a local "I just sent something" flag at the
    ///     Home level: the relay fans `working` out to every subscribed room,
    ///     so a session that finishes while you are looking at another chat
    ///     still turns its own dot off (spec 08 §7.6.1).
    ///   - isReconnecting: `!appModel.isRelayConnected` — a property of the
    ///     socket, not of the room.
    ///   - isLive: the relay announced this room live, and the connection
    ///     status is `online` (the live set is cleared on socket loss, so a
    ///     stale `true` cannot survive a flap).
    static func resolve(isWorking: Bool, isReconnecting: Bool, isLive: Bool) -> PresenceLevel {
        if isWorking { return .working }
        if isReconnecting { return .reconnecting }
        if isLive { return .live }
        return .offline
    }
}

/// A 10×10 presence indicator. The only way to draw one.
///
/// ```swift
/// PresenceDot(isWorking: row.isWorking, isReconnecting: !app.isRelayConnected, isLive: row.isLive)
/// ```
struct PresenceDot: View {
    let level: PresenceLevel
    var diameter: CGFloat = AppMetrics.presenceDot

    @Environment(\.theme) private var theme

    init(level: PresenceLevel, diameter: CGFloat = AppMetrics.presenceDot) {
        self.level = level
        self.diameter = diameter
    }

    /// Convenience taking the three raw signals, so a caller cannot get the
    /// priority order wrong by writing its own `if` ladder.
    init(
        isWorking: Bool,
        isReconnecting: Bool,
        isLive: Bool,
        diameter: CGFloat = AppMetrics.presenceDot
    ) {
        self.level = .resolve(isWorking: isWorking, isReconnecting: isReconnecting, isLive: isLive)
        self.diameter = diameter
    }

    var body: some View {
        // Terminal redesign: a square LED, not a circle — the status
        // indicator of hardware panels and tmux status lines. 2pt radius so
        // it reads as an object rather than a pixel error. `working` blinks,
        // exactly like the chat's streaming cursor: both mean "the machine
        // is doing something right now".
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(color)
            .frame(width: diameter, height: diameter)
            .modifier(BlinkWhenWorking(active: level == .working))
            .accessibilityLabel(accessibilityLabel)
    }

    private var color: Color {
        switch level {
        case .working: theme.colors.working
        case .reconnecting: theme.colors.warning
        case .live: theme.colors.success
        case .offline: theme.colors.muted
        }
    }

    /// VoiceOver reads the state; the dot is otherwise a color-only signal,
    /// which is exactly the thing an accessibility audit fails on.
    private var accessibilityLabel: String {
        switch level {
        case .working: "working"
        case .reconnecting: "reconnecting"
        case .live: "online"
        case .offline: "offline"
        }
    }
}


/// The `working` blink. One shared cadence with `BlinkingCursor` (0.9s) so
/// the two "machine is busy" signals in the app pulse together, not against
/// each other. Respects Reduce Motion by holding steady.
private struct BlinkWhenWorking: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    func body(content: Content) -> some View {
        content
            .opacity(active && dimmed ? 0.25 : 1)
            .task(id: active) {
                guard active, !reduceMotion else { dimmed = false; return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(450))
                    withAnimation(.easeInOut(duration: 0.2)) { dimmed.toggle() }
                }
            }
    }
}
