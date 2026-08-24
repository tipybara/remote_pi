import Foundation
import RemotePiProtocol
import XCTest

@testable import RemotePiTransport

/// The constants and the two watchdogs.
final class TimingTests: XCTestCase {
    /// The ladder, verbatim from both shipped implementations:
    /// `const _kBackoff = [1, 2, 5, 10, 30]` clamped at the last rung
    /// (`connection_manager.dart:77-80`), and the same list in milliseconds at
    /// `pi-extension/src/index.ts:1160`.
    ///
    /// **No jitter.** Both ends of the product agree on the exact schedule;
    /// "improving" it here desynchronizes a fleet reconnecting after a relay
    /// restart from what the operator expects.
    func testBackoffLadderMatchesBothClients() {
        let timing = TransportTiming()
        XCTAssertEqual(timing.backoffDelay(forAttempt: 0), .seconds(1))
        XCTAssertEqual(timing.backoffDelay(forAttempt: 1), .seconds(2))
        XCTAssertEqual(timing.backoffDelay(forAttempt: 2), .seconds(5))
        XCTAssertEqual(timing.backoffDelay(forAttempt: 3), .seconds(10))
        XCTAssertEqual(timing.backoffDelay(forAttempt: 4), .seconds(30))
        XCTAssertEqual(timing.backoffDelay(forAttempt: 5), .seconds(30), "clamped, forever")
        XCTAssertEqual(timing.backoffDelay(forAttempt: 99), .seconds(30))
        XCTAssertEqual(timing.backoffDelay(forAttempt: -1), .seconds(1))
    }

    /// The rest of the constant table (spec 03 §9).
    func testConstantsMatchTheShippedImplementations() {
        let timing = TransportTiming()
        XCTAssertEqual(timing.helloDeadline, .seconds(5))       // HELLO_TIMEOUT_MS
        XCTAssertEqual(timing.challengeTimeout, .seconds(5))    // relay_client.ts AUTH_TIMEOUT_MS
        XCTAssertEqual(timing.handshakeTimeout, .seconds(10))   // dependencies.dart:249
        XCTAssertEqual(timing.socketPingInterval, .seconds(20)) // ws_transport.dart:61
        XCTAssertEqual(timing.innerPingInterval, .seconds(25))  // connection_manager.dart:1246
        XCTAssertEqual(timing.missedPingsBeforeRoomOffline, 3)  // :1268-1272 (the header comment says 2 and is wrong)
        XCTAssertEqual(timing.livenessTimeout, .seconds(70))    // relay_client.ts:17
        XCTAssertEqual(timing.livenessCheckInterval, .seconds(20))
        XCTAssertEqual(timing.stuckOfflineWatchdogInterval, .seconds(15))
    }

    /// 70 s ≈ 2.8 missed relay Pings (the relay pings every 25 s), so a
    /// healthy connection can never be this quiet.
    func testInboundStalenessDeadline() {
        let timing = TransportTiming()
        let start = ContinuousClock.now
        XCTAssertFalse(timing.isInboundStale(lastInboundAt: start, now: start + .seconds(69)))
        XCTAssertFalse(timing.isInboundStale(lastInboundAt: start, now: start + .seconds(70)))
        XCTAssertTrue(timing.isInboundStale(lastInboundAt: start, now: start + .seconds(71)))
    }

    /// A half-open socket — NAT drop, laptop sleep, cellular handoff — never
    /// delivers a close, so nothing else will ever end this connection. The
    /// Flutter client has no equivalent watchdog and can sit "online but dead"
    /// indefinitely; the Pi does (`relay_client.ts:220-235`) and iOS is more
    /// exposed than either.
    func testSilentSocketIsTornDownByTheLivenessWatchdog() async throws {
        let timing = TransportTiming(
            challengeTimeout: .milliseconds(300),
            handshakeTimeout: .milliseconds(500),
            // Long enough that no Pong refreshes the clock during the test.
            socketPingInterval: .seconds(30),
            livenessTimeout: .milliseconds(80),
            livenessCheckInterval: .milliseconds(10)
        )
        let (transport, socket, _) = try await Fixture.connectedTransport(timing: timing)
        let recorder = EventRecorder(transport.events)

        await expectEventually {
            await recorder.snapshot().contains { if case .disconnected = $0 { return true }; return false }
        }
        XCTAssertTrue(socket.closed)
    }

    /// The other half, and the reason the client Ping exists at all:
    /// `URLSessionWebSocketTask` never surfaces the relay's inbound Pings, so
    /// an idle-but-healthy socket looks silent. Our own Ping coming back is
    /// what keeps the watchdog honest — without it the watchdog would drop a
    /// perfectly good connection every 70 s whenever nobody is chatting.
    func testAnsweredPingsKeepASilentSocketAlive() async throws {
        let timing = TransportTiming(
            challengeTimeout: .milliseconds(300),
            handshakeTimeout: .milliseconds(500),
            socketPingInterval: .milliseconds(10),
            livenessTimeout: .milliseconds(80),
            livenessCheckInterval: .milliseconds(10)
        )
        let (transport, socket, _) = try await Fixture.connectedTransport(timing: timing)
        defer { Task { await transport.disconnect() } }
        let recorder = EventRecorder(transport.events)

        try await Task.sleep(for: .milliseconds(250))
        XCTAssertGreaterThan(socket.pingCount, 2)
        XCTAssertFalse(socket.closed)
        let events = await recorder.snapshot()
        expectFalse(
            events.contains { if case .disconnected = $0 { return true }; return false },
            "an idle socket whose pings are answered must not be reconnected"
        )
    }

    /// `disconnect()` is idempotent and finishes the stream exactly once.
    func testDisconnectIsIdempotent() async throws {
        let (transport, socket, _) = try await Fixture.connectedTransport()
        let recorder = EventRecorder(transport.events)

        await transport.disconnect()
        await transport.disconnect()

        await expectEventually { await recorder.count() >= 1 }
        try await Task.sleep(for: .milliseconds(50))
        let disconnects = await recorder.snapshot().filter {
            if case .disconnected = $0 { return true }
            return false
        }
        XCTAssertEqual(disconnects.count, 1)
        XCTAssertTrue(socket.closed)
    }
}
