import Foundation
import RemotePiCrypto
import RemotePiProtocol
import XCTest

@testable import RemotePiTransport

/// Hands out one fresh fake socket per connect attempt, the way a real
/// reconnect gets a new `URLSessionWebSocketTask`.
final class FakeSocketFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var created: [FakeWebSocketChannel] = []

    var channels: [FakeWebSocketChannel] {
        lock.lock(); defer { lock.unlock() }
        return created
    }

    var latest: FakeWebSocketChannel? { channels.last }

    func make(_ url: URL) -> any WebSocketChannel {
        let socket = FakeWebSocketChannel()
        socket.replyToHello(with: [Fixture.challengeFrame])
        lock.lock()
        created.append(socket)
        lock.unlock()
        return socket
    }

    var factory: WebSocketChannelFactory { { url in self.make(url) } }
}

/// File-scope so the polling closures — which are `@Sendable` — can read it
/// without capturing the (non-Sendable) `XCTestCase`.
private let activeRoom = RoomID("019ffb64-1c3e-7a91-b0d2-6f2a1c9e77aa")

final class ConnectionManagerTests: XCTestCase {

    private func startedManager(
        timing: TransportTiming = Fixture.fastTiming
    ) async throws -> (RelayConnectionManager, FakeSocketFactory) {
        let sockets = FakeSocketFactory()
        let manager = RelayConnectionManager(channelFactory: sockets.factory, timing: timing)
        await manager.start(
            relayURL: Fixture.relayURL,
            signer: try Fixture.signer(),
            remotePeer: Fixture.piKey,
            preferredRoom: activeRoom
        )
        return (manager, sockets)
    }

    // MARK: Subscriptions

    /// `subscribeToPeers` sends all four frames — grouped by family
    /// (`connection_manager.dart:338-350`).
    ///
    /// All four, because the relay is asymmetric: `subscribe_presence`
    /// backfills a `peer_online` for everyone already up, `subscribe_rooms`
    /// answers with **nothing**. Skipping the checks left Home with an empty
    /// session list until the next cold start.
    func testSubscribeSendsAllFourFrames() async throws {
        let (manager, sockets) = try await startedManager()
        defer { Task { await manager.stop() } }

        await manager.subscribe(to: [Fixture.piKey])
        let types = try XCTUnwrap(sockets.latest).sentObjects.compactMap { $0["type"] as? String }
        XCTAssertEqual(
            types,
            ["hello", "auth", "subscribe_presence", "subscribe_rooms", "presence_check", "rooms_check"]
        )
    }

    /// An empty peer list still replaces the subscription (that is how you
    /// unsubscribe from everything) but must not ask for a snapshot of
    /// nothing.
    func testEmptyPeerListSkipsTheChecks() async throws {
        let (manager, sockets) = try await startedManager()
        defer { Task { await manager.stop() } }

        await manager.subscribe(to: [])
        let types = try XCTUnwrap(sockets.latest).sentObjects.compactMap { $0["type"] as? String }
        XCTAssertEqual(types, ["hello", "auth", "subscribe_presence", "subscribe_rooms"])
    }

    /// The replay after every reconnect, in the shipped order
    /// (`connection_manager.dart:1171-1179`) — note it interleaves
    /// subscribe/check per family, unlike the initial subscribe.
    ///
    /// **Mandatory, not an optimization.** `rooms.unsubscribe_all(&peer_id)`
    /// runs on every connection close (`peer.rs:465`), so a reconnect without
    /// this yields no `room_announced`, no `room_ended` and no
    /// `room_meta_updated` — a permanently dead UI on a healthy socket.
    func testSubscriptionsAreReplayedOnEveryReconnect() async throws {
        let (manager, sockets) = try await startedManager()
        defer { Task { await manager.stop() } }

        await manager.subscribe(to: [Fixture.piKey])
        XCTAssertEqual(sockets.channels.count, 1)

        sockets.latest?.closeFromServer()
        await expectEventually { sockets.channels.count == 2 }

        let reconnected = try XCTUnwrap(sockets.latest)
        await expectEventually { reconnected.sentObjects.count >= 6 }
        let types = reconnected.sentObjects.compactMap { $0["type"] as? String }
        XCTAssertEqual(
            types,
            ["hello", "auth", "subscribe_presence", "presence_check", "subscribe_rooms", "rooms_check"]
        )
        let peers = reconnected.sentObjects(ofType: "subscribe_rooms").first?["peers"] as? [String]
        XCTAssertEqual(peers, [Fixture.piKeyWire])
    }

    // MARK: Live rooms

    /// The `rooms` snapshot is the authoritative live set for that peer.
    func testRoomsSnapshotDrivesTheLiveSet() async throws {
        let (manager, sockets) = try await startedManager()
        defer { Task { await manager.stop() } }

        try XCTUnwrap(sockets.latest).push("""
            {"type":"rooms","peer":"\(Fixture.piKeyWire)","rooms":[\
            {"room_id":"\(activeRoom.rawValue)","working":false,"started_at":1780000000456}]}
            """)
        await expectEventually { await manager.isRoomLive(activeRoom, of: Fixture.piKey) }
    }

    /// Clearing on disconnect is the fix for a specific visual bug: the stale
    /// set survived the outage, so the instant the socket came back — **before**
    /// the relay's snapshot landed — every previously-live room flipped green
    /// again, including ones whose Pi had exited meanwhile.
    ///
    /// The status gate alone is not enough: it hides the staleness *during*
    /// the outage, not in the gap right after reconnect.
    func testLiveRoomsAreClearedOnDisconnect() async throws {
        // A ladder long enough that the manager stays in `retrying` while we
        // assert, instead of racing us back online.
        var timing = Fixture.fastTiming
        timing.backoffLadder = [.seconds(30)]
        let (manager, sockets) = try await startedManager(timing: timing)
        defer { Task { await manager.stop() } }

        let socket = try XCTUnwrap(sockets.latest)
        socket.push("""
            {"type":"rooms","peer":"\(Fixture.piKeyWire)","rooms":[\
            {"room_id":"\(activeRoom.rawValue)","working":false,"started_at":1}]}
            """)
        await expectEventually { await manager.isRoomLive(activeRoom, of: Fixture.piKey) }

        socket.closeFromServer()
        await expectEventually {
            if case .retrying = await manager.currentStatus() { return true }
            return false
        }
        expectTrue(await manager.liveRooms(of: Fixture.piKey).isEmpty)
        expectFalse(await manager.isRoomLive(activeRoom, of: Fixture.piKey))
    }

    /// `transport_error` drops the room from the live set immediately, so the
    /// chat writer can fail outstanding sends now instead of waiting out the
    /// ~20 s no-echo timer. The next `room_announced` puts it back.
    func testTransportErrorRemovesTheRoomFromTheLiveSet() async throws {
        let (manager, sockets) = try await startedManager()
        defer { Task { await manager.stop() } }
        let socket = try XCTUnwrap(sockets.latest)

        socket.push("""
            {"type":"room_announced","peer":"\(Fixture.piKeyWire)","room_id":"\(activeRoom.rawValue)",\
            "working":false,"started_at":1}
            """)
        await expectEventually { await manager.isRoomLive(activeRoom, of: Fixture.piKey) }

        socket.push("""
            {"type":"transport_error","reason":"offline","peer":"\(Fixture.piKeyWire)",\
            "room_id":"\(activeRoom.rawValue)"}
            """)
        await expectEventually { await !manager.isRoomLive(activeRoom, of: Fixture.piKey) }
    }

    /// `room_ended` means "the process is gone" — the live flag drops, and the
    /// tile survives elsewhere. It is never a rename post-plan-61.
    func testRoomEndedOnlyClearsTheLiveFlag() async throws {
        let (manager, sockets) = try await startedManager()
        defer { Task { await manager.stop() } }
        let socket = try XCTUnwrap(sockets.latest)

        socket.push("""
            {"type":"room_announced","peer":"\(Fixture.piKeyWire)","room_id":"\(activeRoom.rawValue)",\
            "working":false,"started_at":1}
            """)
        await expectEventually { await manager.isRoomLive(activeRoom, of: Fixture.piKey) }

        socket.push("""
            {"type":"room_ended","peer":"\(Fixture.piKeyWire)","room_id":"\(activeRoom.rawValue)",\
            "since_ts":1780000000999}
            """)
        await expectEventually { await !manager.isRoomLive(activeRoom, of: Fixture.piKey) }
    }

    // MARK: Inner ping

    /// The inner ping is a **Pi**-liveness probe, and its wire shape is
    /// `{"type":"ping","id":"ping_<n>"}`
    /// (`app/lib/protocol/protocol.dart:706-711`; the Pi answers
    /// `{"type":"pong","in_reply_to":…}` at `index.ts:4105`). It rides the
    /// envelope like any other message, addressed at the active room.
    func testInnerPingWireShape() async throws {
        let (manager, sockets) = try await startedManager()
        defer { Task { await manager.stop() } }
        let socket = try XCTUnwrap(sockets.latest)

        await expectEventually { socket.sentObjects.contains { $0["ct"] != nil } }
        let envelope = try XCTUnwrap(socket.sentObjects.first { $0["ct"] != nil })
        XCTAssertEqual(envelope["room"] as? String, activeRoom.rawValue)
        XCTAssertEqual(envelope["peer"] as? String, Fixture.piKeyWire)

        let inner = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(envelope["ct"] as? String)))
        XCTAssertEqual(String(data: inner, encoding: .utf8), #"{"type":"ping","id":"ping_1"}"#)
    }

    /// Three missed pings mark **only the active room** offline and leave the
    /// socket up.
    ///
    /// The file header of `connection_manager.dart` says two misses and
    /// "→ retrying"; the code says three and leaves the WS alone
    /// (`:1268-1272`). The code wins, and the reason is recorded at `:1252`:
    /// tearing the WS down on Pi silence produced a permanent
    /// `room_already_open` deadlock, because the relay frees its slot only
    /// when its own send errors — minutes, on a half-open TCP.
    func testThreeMissedPingsMarkTheRoomOfflineWithoutDroppingTheSocket() async throws {
        let (manager, sockets) = try await startedManager()
        defer { Task { await manager.stop() } }
        let socket = try XCTUnwrap(sockets.latest)

        socket.push("""
            {"type":"room_announced","peer":"\(Fixture.piKeyWire)","room_id":"\(activeRoom.rawValue)",\
            "working":false,"started_at":1}
            """)
        await expectEventually { await manager.isRoomLive(activeRoom, of: Fixture.piKey) }

        await expectEventually { await manager.missedPings >= 3 }
        expectFalse(await manager.isRoomLive(activeRoom, of: Fixture.piKey))
        expectEqual(await manager.currentStatus(), .online, "the socket must stay up")
        XCTAssertFalse(socket.closed)
    }

    /// Plan 62 state-sync audit — the missed-ping mark is REVERSIBLE by the
    /// next inbound envelope.
    ///
    /// It used to be permanent: the recovery the pingTick comment promised
    /// ("room_announced puts the room back") cannot happen for a Pi whose
    /// socket never dropped — that frame only fires on a room's FIRST
    /// connection — and the relay suppressed identical `rooms_check` replies,
    /// so the poll channel was starved too. The tile stayed grey until the Pi
    /// process itself restarted.
    func testInboundEnvelopeRevivesALocallyMarkedRoom() async throws {
        let (manager, sockets) = try await startedManager()
        defer { Task { await manager.stop() } }
        let socket = try XCTUnwrap(sockets.latest)

        socket.push("""
            {"type":"room_announced","peer":"\(Fixture.piKeyWire)","room_id":"\(activeRoom.rawValue)",\
            "working":false,"started_at":1}
            """)
        await expectEventually { await manager.isRoomLive(activeRoom, of: Fixture.piKey) }

        // Pi goes silent → our local guess marks it offline.
        await expectEventually { await manager.missedPings >= 3 }
        expectFalse(await manager.isRoomLive(activeRoom, of: Fixture.piKey))

        // The Pi answers again. No room_announced will ever come (its socket
        // never dropped), so THIS is the only recovery signal that exists.
        let pong = Data(#"{"type":"pong","in_reply_to":"ping_9"}"#.utf8).base64EncodedString()
        socket.push(#"{"peer":"\#(Fixture.piKeyWire)","room":"\#(activeRoom.rawValue)","ct":"\#(pong)"}"#)

        await expectEventually { await manager.isRoomLive(activeRoom, of: Fixture.piKey) }
    }

    /// The relay's `room_ended` is a verdict, not a guess — a straggler
    /// envelope (e.g. a Pong queued before the death) must not overturn it.
    /// Only OUR OWN missed-ping mark is reversible from the inbound path.
    func testRoomEndedIsNotOverturnedByAStragglerEnvelope() async throws {
        let (manager, sockets) = try await startedManager()
        defer { Task { await manager.stop() } }
        let socket = try XCTUnwrap(sockets.latest)

        socket.push("""
            {"type":"room_announced","peer":"\(Fixture.piKeyWire)","room_id":"\(activeRoom.rawValue)",\
            "working":false,"started_at":1}
            """)
        await expectEventually { await manager.isRoomLive(activeRoom, of: Fixture.piKey) }

        // We guessed offline first; then the relay CONFIRMED the death.
        await expectEventually { await manager.missedPings >= 3 }
        socket.push("""
            {"type":"room_ended","peer":"\(Fixture.piKeyWire)","room_id":"\(activeRoom.rawValue)",\
            "since_ts":2}
            """)
        await expectEventually { !(await manager.isRoomLive(activeRoom, of: Fixture.piKey)) }

        let pong = Data(#"{"type":"pong","in_reply_to":"ping_9"}"#.utf8).base64EncodedString()
        socket.push(#"{"peer":"\#(Fixture.piKeyWire)","room":"\#(activeRoom.rawValue)","ct":"\#(pong)"}"#)

        // Give the pump a beat, then assert the verdict held.
        try await Task.sleep(for: .milliseconds(120))
        expectFalse(await manager.isRoomLive(activeRoom, of: Fixture.piKey))
    }

    /// Any inbound **envelope** resets the miss counter and the backoff rung.
    ///
    /// Envelopes only, and that is deliberate (`connection_manager.dart:20-25`,
    /// patch "B"): with the Pi down the socket to the relay keeps
    /// authenticating perfectly, so resetting on connect success — or on a
    /// control frame, which the relay keeps sending regardless — pinned the
    /// ladder at 1 s forever.
    func testInboundEnvelopeResetsTheMissCounter() async throws {
        let (manager, sockets) = try await startedManager()
        defer { Task { await manager.stop() } }
        let socket = try XCTUnwrap(sockets.latest)

        await expectEventually { await manager.missedPings >= 2 }

        // A control frame is not evidence the Pi is alive.
        socket.push(#"{"type":"peer_online","peer":"\#(Fixture.piKeyWire)"}"#)
        expectGreaterThan(await manager.missedPings, 0)

        let pong = Data(#"{"type":"pong","in_reply_to":"ping_1"}"#.utf8).base64EncodedString()
        socket.push(#"{"peer":"\#(Fixture.piKeyWire)","room":"\#(activeRoom.rawValue)","ct":"\#(pong)"}"#)
        await expectEventually { await manager.missedPings == 0 }
    }

    // MARK: Room pointer

    /// A reconnect to the **same** machine must not move the pointer: the
    /// stored `roomId` is a last-opened hint, and re-seeding from it on every
    /// reconnect is what made the chat jump to another workspace after
    /// backgrounding (plan 61 Phase 0).
    func testReconnectingToTheSameMachineKeepsTheActiveRoom() async throws {
        let (manager, sockets) = try await startedManager()
        defer { Task { await manager.stop() } }

        let chosen = RoomID("019ffb64-2222-7c31-9b2e-4f3a2b1c0d9e")
        await manager.setActiveRoom(chosen, owner: Fixture.piKey)
        expectEqual(await manager.currentActiveRoom(), chosen)

        sockets.latest?.closeFromServer()
        await expectEventually { sockets.channels.count == 2 }
        await expectEventually { await manager.currentStatus() == .online }
        expectEqual(await manager.currentActiveRoom(), chosen)
    }

    /// The pointer must reach the socket **before** the manager reports
    /// online: a fresh transport defaults to `main`, so the first send after a
    /// reconnect would otherwise be addressed at the phone's own room and the
    /// Pi would never see it.
    func testActiveRoomIsPushedDownBeforeGoingOnline() async throws {
        let (manager, sockets) = try await startedManager()
        defer { Task { await manager.stop() } }

        let chosen = RoomID("019ffb64-3333-7c31-9b2e-4f3a2b1c0d9e")
        await manager.setActiveRoom(chosen, owner: Fixture.piKey)
        sockets.latest?.closeFromServer()
        await expectEventually { sockets.channels.count == 2 }
        await expectEventually { await manager.currentStatus() == .online }

        try await manager.sendToActiveRoom(Data("{}".utf8))
        let reconnected = try XCTUnwrap(sockets.latest)
        let envelope = try XCTUnwrap(reconnected.sentObjects.last)
        XCTAssertEqual(envelope["room"] as? String, chosen.rawValue)
    }

    /// A control RPC goes to `ctrl` and leaves the conversation where it is.
    func testManagerSendToRoomDoesNotMoveTheActiveRoom() async throws {
        let (manager, sockets) = try await startedManager()
        defer { Task { await manager.stop() } }

        try await manager.send(Data(#"{"type":"action","action":"workspace_list"}"#.utf8),
                               to: Fixture.piKey, room: .control)
        XCTAssertEqual(sockets.latest?.sentObjects.last?["room"] as? String, "ctrl")
        expectEqual(await manager.currentActiveRoom(), activeRoom)
    }

    // MARK: Status

    func testStatusReachesOnlineAndReturnsToRetryingOnDrop() async throws {
        var timing = Fixture.fastTiming
        timing.backoffLadder = [.seconds(30)]
        let (manager, sockets) = try await startedManager(timing: timing)
        defer { Task { await manager.stop() } }

        expectEqual(await manager.currentStatus(), .online)
        sockets.latest?.closeFromServer()
        await expectEventually {
            if case .retrying(let attempt, _) = await manager.currentStatus() { return attempt == 0 }
            return false
        }
        // The first retry after a drop always waits the first rung: the
        // attempt counter is incremented when the timer fires, not when it is
        // scheduled (`connection_manager.dart:1237-1243`).
        expectEqual(await manager.retryAttempt, 0)
    }
}

extension ConnectionManagerTests {
    /// `stop()` must actually stop.
    ///
    /// Closing the transport makes it emit `.disconnected`, which is
    /// indistinguishable from a real drop unless the manager marks the
    /// teardown as deliberate — otherwise the retry ladder resurrects a
    /// connection the caller just tore down.
    func testStopDoesNotReconnect() async throws {
        var timing = Fixture.fastTiming
        timing.backoffLadder = [.milliseconds(10)]
        let (manager, sockets) = try await startedManager(timing: timing)

        await manager.stop()
        expectEqual(await manager.currentStatus(), .idle)

        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(sockets.channels.count, 1, "no new socket may be opened after stop()")
        expectEqual(await manager.currentStatus(), .idle)
    }
}
