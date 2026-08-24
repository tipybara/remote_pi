import Foundation
import XCTest

@testable import RemotePiProtocol
@testable import RemotePiSession

/// Wiring: subscriptions, the inbound demux, selection, and persistence.
final class SessionCoordinatorTests: XCTestCase {
    private func makeCoordinator(
        _ transport: FakeTransport,
        store: FakeStore = FakeStore()
    ) -> SessionCoordinator {
        SessionCoordinator(
            transport: transport,
            store: store,
            controlTimeout: .seconds(5),
            roomWaitBudget: .milliseconds(50)
        )
    }

    /// All four frames, in order, with the peer spelled **standard Base64 with
    /// padding**. Every entry of `peers` is used as a raw HashMap key by the
    /// relay with no normalization: a url-safe entry produces a subscription
    /// that never fires — silently, forever, with zero diagnostics (spec 02 T1).
    ///
    /// The order matters because `subscribe_presence` backfills a `peer_online`
    /// while `subscribe_rooms` sends no snapshot at all; the checks are what
    /// close that gap.
    func testStartSendsAllFourSubscriptionFrames() async throws {
        let transport = FakeTransport()
        let coordinator = makeCoordinator(transport)
        try await coordinator.start(watching: [machineKey])

        let frames = try transport.controlFrames.map { try jsonObject($0.encoded()) }
        XCTAssertEqual(
            frames.map { $0["type"] as? String },
            ["subscribe_presence", "subscribe_rooms", "presence_check", "rooms_check"]
        )
        for frame in frames {
            XCTAssertEqual(frame["peers"] as? [String], [machineKey.wireValue])
            let peers = try XCTUnwrap(frame["peers"] as? [String])
            XCTAssertFalse(peers[0].contains("-"), "url-safe entries never match the registry")
            XCTAssertFalse(peers[0].contains("_"))
        }
        await coordinator.stop()
    }

    /// Watching nobody is a legitimate state (no pairings yet). The subscribes
    /// still go out — an empty array is how you unsubscribe from everything —
    /// but the checks would be pointless.
    func testStartWithNoPeersSendsOnlyTheSubscribes() async throws {
        let transport = FakeTransport()
        let coordinator = makeCoordinator(transport)
        try await coordinator.start(watching: [])

        let types = try transport.controlFrames.map { try jsonObject($0.encoded())["type"] as? String }
        XCTAssertEqual(types, ["subscribe_presence", "subscribe_rooms"])
        await coordinator.stop()
    }

    /// T11 — the relay clears **room** subscriptions on every connection close
    /// but keeps presence subscriptions until the peer's last connection drops.
    /// Skipping the re-subscribe leaves a permanently dead UI on a perfectly
    /// healthy socket, so `connected` re-sends both.
    func testReconnectResubscribes() async throws {
        let transport = FakeTransport()
        let coordinator = makeCoordinator(transport)
        try await coordinator.start(watching: [machineKey])
        XCTAssertEqual(transport.controlFrames.count, 4)

        transport.emit(.connected(peer: machineKey))
        await waitUntil { transport.controlFrames.count == 8 }

        let types = try transport.controlFrames.suffix(4).map {
            try jsonObject($0.encoded())["type"] as? String
        }
        XCTAssertEqual(
            types,
            ["subscribe_presence", "subscribe_rooms", "presence_check", "rooms_check"]
        )
        await coordinator.stop()
    }

    /// Cached rooms render before the relay says anything — and for a machine
    /// that is offline, where it never will.
    func testStartSeedsRoomsFromTheStore() async throws {
        let transport = FakeTransport()
        let store = FakeStore(
            rooms: [machineKey: [RoomMeta(roomID: RoomID("cached"), name: "yesterday")]]
        )
        let coordinator = makeCoordinator(transport, store: store)
        try await coordinator.start(watching: [machineKey])

        let rooms = await coordinator.rooms(for: machineKey)
        XCTAssertEqual(rooms.map(\.roomID.rawValue), ["cached"])
        let live = await coordinator.registry.isLive(
            SessionKey(peer: machineKey, room: RoomID("cached"))
        )
        XCTAssertFalse(live, "a room restored from disk has not announced itself on this socket")
        await coordinator.stop()
    }

    func testRoomFramesArePersisted() async throws {
        let transport = FakeTransport()
        let store = FakeStore()
        let coordinator = makeCoordinator(transport, store: store)
        try await coordinator.start(watching: [machineKey])

        transport.emit(
            .control(
                try controlFrame(
                    """
                    { "type": "room_announced", "peer": "\(machineKey.wireValue)",
                      "room_id": "r1", "name": "backend", "working": false, "started_at": 1 }
                    """
                )
            )
        )
        await waitUntil { store.savedRooms[machineKey]?.isEmpty == false }
        XCTAssertEqual(store.savedRooms[machineKey]?.first?.name, "backend")
        await coordinator.stop()
    }

    // MARK: - Inbound demux

    /// Every payload leaves the coordinator tagged with the **sender's**
    /// `(peer, room)` — the relay rewrites both header fields on the way
    /// through, so an inbound envelope answers "who sent this, from which of
    /// their rooms". Without that tag a singleton store bleeds one session's
    /// `agent_chunk`s into another's transcript.
    func testInboundEnvelopesAreTaggedWithTheSendersSessionKey() async throws {
        let transport = FakeTransport()
        let coordinator = makeCoordinator(transport)
        try await coordinator.start(watching: [machineKey])

        let received = Collector()
        let stream = await coordinator.messages
        let consumer = Task {
            for await message in stream { await received.append(message) }
        }

        transport.deliverInner(
            from: machineKey,
            room: RoomID("sess-a"),
            json: #"{"type":"agent_chunk","in_reply_to":"m1","delta":"hello"}"#
        )
        transport.deliverInner(
            from: machineKey,
            room: RoomID("sess-b"),
            json: #"{"type":"agent_chunk","in_reply_to":"m2","delta":"other"}"#
        )

        await waitUntil { await received.count == 2 }
        let rooms = await received.rooms
        XCTAssertEqual(rooms, [RoomID("sess-a"), RoomID("sess-b")])
        consumer.cancel()
        await coordinator.stop()
    }

    /// A `ctrl` envelope nobody claimed must never reach a transcript: the
    /// control room has no `session_id`, so a message box for it is a phantom
    /// session (spec 09 T10).
    func testUnclaimedControlRoomEnvelopesNeverReachTheMessageStream() async throws {
        let transport = FakeTransport()
        let coordinator = makeCoordinator(transport)
        try await coordinator.start(watching: [machineKey])

        let received = Collector()
        let stream = await coordinator.messages
        let consumer = Task {
            for await message in stream { await received.append(message) }
        }

        transport.deliverInner(
            from: machineKey,
            room: .control,
            json: #"{"type":"action_ok","in_reply_to":"nobody-is-waiting","action":"session_list"}"#
        )
        transport.deliverInner(
            from: machineKey,
            room: RoomID("sess-a"),
            json: #"{"type":"agent_message","in_reply_to":"m1","text":"hi"}"#
        )

        await waitUntil { await received.count == 1 }
        let rooms = await received.rooms
        XCTAssertEqual(rooms, [RoomID("sess-a")])
        consumer.cancel()
        await coordinator.stop()
    }

    // MARK: - Selection

    /// Selecting the control plane would open a chat that answers nothing.
    func testSelectingTheControlRoomIsRefused() async throws {
        let coordinator = makeCoordinator(FakeTransport())
        do {
            try await coordinator.select(SessionKey(peer: machineKey, room: .control))
            XCTFail("expected the control room to be refused")
        } catch {
            XCTAssertEqual(error as? SessionSelectionError, .controlRoomIsNotASession)
        }
    }

    /// The full key is restored. Restoring only the peer and defaulting the
    /// room to `main` is what reopened the wrong chat after a cold start.
    func testSelectionRoundTripsThroughTheStore() async throws {
        let store = FakeStore()
        let coordinator = makeCoordinator(FakeTransport(), store: store)
        let key = SessionKey(peer: machineKey, room: RoomID("sess-a"))
        try await coordinator.select(key)
        XCTAssertEqual(store.savedSelection, key)

        let restored = SessionCoordinator(transport: FakeTransport(), store: store)
        let recovered = await restored.restoreSelection()
        XCTAssertEqual(recovered, key)
    }

    /// A stored `ctrl` selection can only come from a bug elsewhere, but
    /// honouring it would drop the user into the control plane.
    func testStoredControlRoomSelectionIsIgnored() async throws {
        let store = FakeStore(selected: SessionKey(peer: machineKey, room: .control))
        let coordinator = makeCoordinator(FakeTransport(), store: store)
        let recovered = await coordinator.restoreSelection()
        XCTAssertNil(recovered)
    }

    /// Discovery must not move the pointer. A room announced after the user
    /// picked a session — including the `ctrl` room, which the Flutter client's
    /// un-role-guarded "adopt the first announced room" heuristic would latch
    /// onto — leaves the selection alone.
    func testAnnouncementsDoNotMoveTheSelection() async throws {
        let transport = FakeTransport()
        let coordinator = makeCoordinator(transport)
        try await coordinator.start(watching: [machineKey])
        let chosen = SessionKey(peer: machineKey, room: RoomID("sess-a"))
        try await coordinator.select(chosen)

        for room in ["ctrl", "sess-z"] {
            transport.emit(
                .control(
                    try controlFrame(
                        """
                        { "type": "room_announced", "peer": "\(machineKey.wireValue)",
                          "room_id": "\(room)", "working": false, "started_at": 1 }
                        """
                    )
                )
            )
        }
        await waitUntil {
            let rooms = await coordinator.rooms(for: machineKey)
            return rooms.count == 1
        }
        let selection = await coordinator.selectedSession()
        XCTAssertEqual(selection, chosen)
        await coordinator.stop()
    }

    // MARK: - Sending

    /// Renaming from Home addresses the session's own room and must not move
    /// the open conversation. And the `rev` is the one last read off the wire —
    /// never minted here: revisions belong to the Pi, which seeds them from its
    /// wall clock so they keep rising across restarts.
    func testRenameAddressesTheSessionsOwnRoomAndEchoesTheLastSeenRev() async throws {
        let transport = FakeTransport()
        let coordinator = makeCoordinator(transport)
        try await coordinator.start(watching: [machineKey])

        transport.emit(
            .control(
                try controlFrame(
                    """
                    { "type": "room_announced", "peer": "\(machineKey.wireValue)",
                      "room_id": "sess-a", "session_id": "sess-a",
                      "name": "old", "name_rev": 1780000000000,
                      "working": false, "started_at": 1 }
                    """
                )
            )
        )
        await waitUntil {
            let rooms = await coordinator.rooms(for: machineKey)
            return rooms.count == 1
        }

        let open = SessionKey(peer: machineKey, room: RoomID("sess-open"))
        try await coordinator.select(open)

        let target = SessionKey(peer: machineKey, room: RoomID("sess-a"))
        try await coordinator.renameSession(target, to: "backend")

        let envelope = try XCTUnwrap(transport.envelopes.last)
        XCTAssertEqual(envelope.room, RoomID("sess-a"))
        let inner = try jsonObject(try XCTUnwrap(Data(base64Encoded: envelope.ct)))
        XCTAssertEqual(inner["type"] as? String, "session_rename")
        XCTAssertEqual(inner["session_id"] as? String, "sess-a")
        XCTAssertEqual(inner["display_name"] as? String, "backend")
        XCTAssertEqual(inner["rev"] as? Int64, 1_780_000_000_000)

        let selection = await coordinator.selectedSession()
        XCTAssertEqual(selection, open, "renaming must not relocate the open chat")
        await coordinator.stop()
    }

    /// An oversized envelope is dropped by the relay in **total silence** — no
    /// `transport_error`, no close, no ack. The local check is the only way the
    /// user ever learns, and it reproduces the relay's own arithmetic on the
    /// Base64 string so the two agree exactly at the boundary (spec 02 T8).
    func testOversizedPayloadIsRefusedLocally() async throws {
        let transport = FakeTransport()
        let coordinator = makeCoordinator(transport)
        // 4 MiB decoded ⇒ well past `ct.len() * 3 / 4 > 4194304`.
        let huge = Data(repeating: 0x41, count: 5 * 1024 * 1024)
        do {
            try await coordinator.send(huge, to: SessionKey(peer: machineKey, room: RoomID("s")))
            XCTFail("expected the oversized payload to be refused")
        } catch let error as RelayTransportError {
            guard case .payloadTooLarge = error else {
                return XCTFail("expected payloadTooLarge, got \(error)")
            }
        }
        XCTAssertTrue(transport.envelopes.isEmpty)
    }

    /// Envelopes never carry a top-level `type`: the relay checks for one
    /// *before* envelope parsing, and any envelope with a string `type` is
    /// treated as a control frame, matches no arm and is dropped with no error
    /// to the sender (spec 02 T7). The inner message's `type` lives inside
    /// `ct`, where the relay cannot see it.
    func testOutboundEnvelopeHasNoTopLevelType() async throws {
        let transport = FakeTransport()
        let coordinator = makeCoordinator(transport)
        try await coordinator.send(
            Data(#"{"type":"user_message","id":"m1","text":"hi"}"#.utf8),
            to: SessionKey(peer: machineKey, room: RoomID("sess-a"))
        )
        let envelope = try XCTUnwrap(transport.envelopes.first)
        let encoded = try JSONEncoder().encode(envelope)
        let wire = try jsonObject(encoded)
        XCTAssertEqual(Set(wire.keys), ["peer", "room", "ct"])
        XCTAssertEqual(wire["peer"] as? String, machineKey.wireValue)
        XCTAssertEqual(wire["room"] as? String, "sess-a")
    }
}

/// Actor-isolated sink so the consumer task and the assertions do not race.
private actor Collector {
    private var messages: [InboundMessage] = []
    func append(_ message: InboundMessage) { messages.append(message) }
    var count: Int { messages.count }
    var rooms: [RoomID] { messages.map(\.session.room) }
}
