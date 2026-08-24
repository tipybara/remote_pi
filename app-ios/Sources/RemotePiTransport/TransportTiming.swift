import Foundation

/// Every timing constant the relay connection depends on, in one place.
///
/// The defaults are copied from the shipped implementations, not chosen. Each
/// one carries its source; changing a value without changing the peer that
/// enforces it is how the connection ends up flapping.
///
/// Injectable so tests can run the loops in milliseconds.
public struct TransportTiming: Sendable, Hashable {
    /// The relay closes the socket if no `hello` arrives this soon after the
    /// upgrade — without sending anything (`HELLO_TIMEOUT_MS`,
    /// `relay/src/auth/challenge.rs:12`). We send `hello` immediately, so this
    /// is documentation more than a budget.
    public var helloDeadline: Duration

    /// How long to wait for the `challenge` frame. The Pi uses 5 s
    /// (`AUTH_TIMEOUT_MS`, `pi-extension/src/transport/relay_client.ts:6`).
    public var challengeTimeout: Duration

    /// Whole connect + handshake budget. The Flutter client uses 10 s
    /// (`app/lib/config/dependencies.dart:249`).
    public var handshakeTimeout: Duration

    /// How long after sending `auth` a socket close still counts as
    /// "signature rejected" rather than "network blip".
    ///
    /// The relay **never acknowledges a successful auth** — it just starts
    /// routing (`relay/src/handlers/peer.rs:74-186`,
    /// `relay_client.ts:272-273`). Every auth failure is an unadorned
    /// `Message::Close(None)`. So a close arriving immediately after `auth` is
    /// the only evidence a client ever gets, and mapping it onto a plain
    /// socket drop makes the backoff ladder spin on a permanently bad key.
    /// One second is a heuristic, not a protocol guarantee (spec 03 §10.1).
    public var authGracePeriod: Duration

    /// Client → relay RFC 6455 Ping cadence.
    ///
    /// `IOWebSocketChannel.pingInterval` is 20 s in the Flutter client
    /// (`ws_transport.dart:59-62`). It keeps NAT and corporate proxies from
    /// reaping an idle socket, and surfaces a dead socket as a close. The
    /// relay deliberately **ignores** client Pings and Pongs
    /// (`peer.rs:195-197`), so a Pong is never a liveness signal — do not try
    /// to read one.
    public var socketPingInterval: Duration

    /// Inner protocol `ping` → the **Pi**, through the envelope.
    ///
    /// A different layer from ``socketPingInterval``: this measures whether
    /// the agent on the other end is alive, not whether the socket is
    /// (`connection_manager.dart:1246`).
    public var innerPingInterval: Duration

    /// Consecutive unanswered inner pings before the active room is marked
    /// offline locally. **The socket is left alone.**
    ///
    /// Three (`connection_manager.dart:1268-1272`) — note the file's own
    /// header comment says two, and is wrong; the code wins. Tearing the WS
    /// down on Pi silence is what produced the permanent `room_already_open`
    /// deadlock, because the relay frees its slot only when its own send
    /// errors, which on a half-open TCP takes minutes.
    public var missedPingsBeforeRoomOffline: Int

    /// Total inbound silence after which the socket is presumed half-open.
    ///
    /// 70 s ≈ 2.8 missed relay Pings (`relay_client.ts:17`). The relay pings
    /// every 25 s, so a healthy connection can never be this quiet. This is
    /// the watchdog the Flutter client does **not** have and iOS needs more:
    /// cellular handoff and backgrounding produce half-open sockets that never
    /// deliver a close, leaving the app "online but dead" forever.
    public var livenessTimeout: Duration

    /// How often the liveness watchdog looks (`relay_client.ts:18`).
    public var livenessCheckInterval: Duration

    /// Belt-and-braces sweep for a dropped retry chain
    /// (`connection_manager.dart:195-207`).
    public var stuckOfflineWatchdogInterval: Duration

    /// Reconnect ladder. **Deterministic, no jitter.**
    ///
    /// `[1, 2, 5, 10, 30]` seconds, clamped at the last entry
    /// (`connection_manager.dart:77-80`), and the pi-extension uses the same
    /// ladder in milliseconds (`pi-extension/src/index.ts:1160`). Both ends of
    /// the product agree; reproduce it verbatim rather than "improving" it
    /// with jitter, or a relay restart stops staggering the way the operator
    /// expects.
    public var backoffLadder: [Duration]

    public init(
        helloDeadline: Duration = .seconds(5),
        challengeTimeout: Duration = .seconds(5),
        handshakeTimeout: Duration = .seconds(10),
        authGracePeriod: Duration = .seconds(1),
        socketPingInterval: Duration = .seconds(20),
        innerPingInterval: Duration = .seconds(25),
        missedPingsBeforeRoomOffline: Int = 3,
        livenessTimeout: Duration = .seconds(70),
        livenessCheckInterval: Duration = .seconds(20),
        stuckOfflineWatchdogInterval: Duration = .seconds(15),
        backoffLadder: [Duration] = [
            .seconds(1), .seconds(2), .seconds(5), .seconds(10), .seconds(30),
        ]
    ) {
        self.helloDeadline = helloDeadline
        self.challengeTimeout = challengeTimeout
        self.handshakeTimeout = handshakeTimeout
        self.authGracePeriod = authGracePeriod
        self.socketPingInterval = socketPingInterval
        self.innerPingInterval = innerPingInterval
        self.missedPingsBeforeRoomOffline = missedPingsBeforeRoomOffline
        self.livenessTimeout = livenessTimeout
        self.livenessCheckInterval = livenessCheckInterval
        self.stuckOfflineWatchdogInterval = stuckOfflineWatchdogInterval
        self.backoffLadder = backoffLadder
    }

    /// Delay before retry number `attempt` (0-based), clamped at the last rung.
    ///
    /// `attempt` is the count of retries already made, so the **first** retry
    /// after a drop passes `0` and waits 1 s — matching
    /// `_backoffFor(_retryAttempt)` with `_retryAttempt` incremented only when
    /// the timer fires (`connection_manager.dart:1237-1243`).
    public func backoffDelay(forAttempt attempt: Int) -> Duration {
        guard let last = backoffLadder.last else { return .seconds(1) }
        if attempt <= 0 { return backoffLadder[0] }
        if attempt >= backoffLadder.count { return last }
        return backoffLadder[attempt]
    }

    /// `true` when nothing has arrived for longer than ``livenessTimeout``.
    ///
    /// Pure so the deadline can be tested without waiting 70 seconds.
    /// "Anything" means anything: an envelope, a control frame, even a frame
    /// this build drops as unknown.
    ///
    /// One platform difference from the Pi, and it is the reason
    /// ``socketPingInterval`` is not optional here. The Pi refreshes its clock
    /// on the relay's inbound WS Ping (`relay_client.ts:168`) because the `ws`
    /// package surfaces a `ping` event. `URLSessionWebSocketTask` surfaces
    /// **no** inbound control frames at all — a relay that pings every 25 s
    /// but sends no text looks perfectly silent to us, and this watchdog would
    /// reconnect a healthy idle socket every 70 s. So the implementation
    /// refreshes the clock on its **own** Ping being answered
    /// (`sendPing`'s pong handler), which is strictly better evidence anyway:
    /// it proves a full round trip rather than one direction.
    public func isInboundStale(
        lastInboundAt: ContinuousClock.Instant,
        now: ContinuousClock.Instant
    ) -> Bool {
        now - lastInboundAt > livenessTimeout
    }
}
