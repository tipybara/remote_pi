import Foundation
import RemotePiProtocol
import XCTest

@testable import RemotePiTransport

/// Every control frame the relay can put on this socket, fed in as the exact
/// JSON `serde_json::json!` produces, and every control frame this client is
/// allowed to send back.
final class ControlFrameWireTests: XCTestCase {
    private let key = Fixture.piKeyWire

    // MARK: Inbound

    /// `registry.rs:128` / `:148` — no `since_ts` on this one.
    func testPeerOnline() {
        guard case .control(.peerOnline(let peer)) =
            RelayFrame.classify(#"{"type":"peer_online","peer":"\#(key)"}"#)
        else { return XCTFail("peer_online") }
        XCTAssertEqual(peer, Fixture.piKey)
    }

    /// `registry.rs:202-206` — epoch **milliseconds**, always present. It is
    /// an i64: a 2026 timestamp already overflows Int32.
    func testPeerOffline() {
        guard case .control(.peerOffline(let peer, let sinceTs)) =
            RelayFrame.classify(#"{"type":"peer_offline","peer":"\#(key)","since_ts":1780000000123}"#)
        else { return XCTFail("peer_offline") }
        XCTAssertEqual(peer, Fixture.piKey)
        XCTAssertEqual(sinceTs, 1_780_000_000_123)
    }

    /// `peer.rs:238-242` + `presence.rs:21-26`. `PeerPresence` has no
    /// `skip_serializing_if`, so `since_ts` is an **explicit null** when the
    /// peer is online — not an absent key.
    func testPresenceSnapshotWithExplicitNullSinceTs() {
        let json = """
            {"type":"presence","states":[\
            {"peer":"\(key)","online":true,"since_ts":null},\
            {"peer":"\(PeerID(rawValue: Data(repeating: 0x01, count: 32))!.wireValue)","online":false,"since_ts":1780000000123}]}
            """
        guard case .control(.presence(let states)) = RelayFrame.classify(json) else {
            return XCTFail("presence")
        }
        XCTAssertEqual(states.count, 2, "one entry per requested peer, order preserved")
        XCTAssertTrue(states[0].online)
        XCTAssertNil(states[0].sinceTs)
        XCTAssertFalse(states[1].online)
        XCTAssertEqual(states[1].sinceTs, 1_780_000_000_123)
    }

    /// T10 — `room_announced` is `serde_json::to_value(&room_meta)` with
    /// `type` and `peer` stamped onto the **same object**
    /// (`registry.rs:110-114`), so every `RoomMeta` field is top-level. The
    /// full post-plan-61 field set, from spec 02 §3.5.
    func testRoomAnnouncedIsFlat() {
        let json = """
            {"type":"room_announced","peer":"\(key)",\
            "room_id":"019ffb64-6f7a-7c31-9b2e-4f3a2b1c0d9e",\
            "session_id":"019ffb64-6f7a-7c31-9b2e-4f3a2b1c0d9e",\
            "workspace_path":"/Users/x/proj","name":"backend","name_rev":1780000000000,\
            "cwd":"/Users/x/proj","model":"claude-sonnet-4.5","thinking":"high",\
            "working":false,"started_at":1780000000456}
            """
        guard case .control(.roomAnnounced(let peer, let meta)) = RelayFrame.classify(json) else {
            return XCTFail("room_announced")
        }
        XCTAssertEqual(peer, Fixture.piKey)
        XCTAssertEqual(meta.roomID, RoomID("019ffb64-6f7a-7c31-9b2e-4f3a2b1c0d9e"))
        XCTAssertEqual(meta.sessionID, SessionID("019ffb64-6f7a-7c31-9b2e-4f3a2b1c0d9e"))
        XCTAssertEqual(meta.workspacePath, "/Users/x/proj")
        XCTAssertEqual(meta.name, "backend")
        XCTAssertEqual(meta.nameRev, 1_780_000_000_000)
        XCTAssertEqual(meta.model, "claude-sonnet-4.5")
        XCTAssertEqual(meta.thinking, "high")
        XCTAssertFalse(meta.working)
        XCTAssertEqual(meta.startedAt, 1_780_000_000_456)
        XCTAssertTrue(meta.hasStableIdentity, "session_id present ⇒ the room id survives a rename")
        XCTAssertFalse(meta.isControlRoom)
    }

    /// The supervisor gateway: `role: "control"`, room id the reserved literal
    /// `"ctrl"`, and **no** `session_id` at all (`daemon/gateway.ts:114-125`).
    /// Filter by `role`, not by the id (spec 03 T3).
    func testControlRoomAnnouncement() {
        let json = """
            {"type":"room_announced","peer":"\(key)","room_id":"ctrl","role":"control",\
            "working":false,"started_at":1780000000456}
            """
        guard case .control(.roomAnnounced(_, let meta)) = RelayFrame.classify(json) else {
            return XCTFail("room_announced")
        }
        XCTAssertTrue(meta.isControlRoom)
        XCTAssertNil(meta.sessionID)
        XCTAssertFalse(meta.hasStableIdentity)
    }

    /// A pre-plan-61 Pi: 12-char digest room id, no `session_id`, no
    /// `workspace_path` — `cwd` has to stand in for it, which is the same
    /// fallback the relay applies when it builds the room (`peer.rs:123-130`).
    func testLegacyAnnouncementFallsBackToCwd() {
        let json = """
            {"type":"room_announced","peer":"\(key)","room_id":"aB12CD34eF56",\
            "name":"work","cwd":"/Users/jacob/projects/app","working":false,"started_at":1700000000000}
            """
        guard case .control(.roomAnnounced(_, let meta)) = RelayFrame.classify(json) else {
            return XCTFail("room_announced")
        }
        XCTAssertNil(meta.sessionID)
        XCTAssertEqual(meta.workspacePath, "/Users/jacob/projects/app")
        XCTAssertEqual(meta.effectiveWorkspacePath, "/Users/jacob/projects/app")
    }

    /// `registry.rs:186-192`. Means "the process is gone", never "delete the
    /// session": post-plan-61 a rename does not emit this at all.
    func testRoomEnded() {
        guard case .control(.roomEnded(let peer, let room, let sinceTs)) = RelayFrame.classify(
            #"{"type":"room_ended","peer":"\#(key)","room_id":"019ffb64-…","since_ts":1780000000999}"#
        ) else { return XCTFail("room_ended") }
        XCTAssertEqual(peer, Fixture.piKey)
        XCTAssertEqual(room, RoomID("019ffb64-…"))
        XCTAssertEqual(sinceTs, 1_780_000_000_999)
    }

    /// `peer.rs:265-287` — one frame per requested peer, a flat array of full
    /// `RoomMeta`. Vectors adapted from `app/test/protocol/rooms_protocol_test.dart`.
    func testRoomsSnapshot() {
        let json = """
            {"type":"rooms","peer":"\(key)","rooms":[\
            {"room_id":"r1","name":"one","cwd":"/one","working":false,"started_at":1000},\
            {"room_id":"r2","working":true,"started_at":2000}]}
            """
        guard case .control(.rooms(let peer, let rooms)) = RelayFrame.classify(json) else {
            return XCTFail("rooms")
        }
        XCTAssertEqual(peer, Fixture.piKey)
        XCTAssertEqual(rooms.count, 2)
        XCTAssertEqual(rooms[0].name, "one")
        XCTAssertEqual(rooms[0].cwd, "/one")
        XCTAssertNil(rooms[1].name)
        XCTAssertTrue(rooms[1].working)
    }

    /// An unknown peer answers `"rooms": []` — "every room is dead", not "no
    /// information".
    func testEmptyRoomsSnapshotParses() {
        guard case .control(.rooms(_, let rooms)) =
            RelayFrame.classify(#"{"type":"rooms","peer":"\#(key)","rooms":[]}"#)
        else { return XCTFail("rooms") }
        XCTAssertTrue(rooms.isEmpty)
    }

    /// T10's other half — `room_meta_updated` **nests** under `meta`
    /// (`registry.rs:376-382`), unlike `room_announced`. T6/T12: an absent key
    /// preserves, and `working` is always present with no null state.
    func testRoomMetaUpdatedIsNestedAndPatchShaped() {
        let json = """
            {"type":"room_meta_updated","peer":"\(key)","room_id":"019ffb64-…",\
            "meta":{"working":true}}
            """
        guard case .control(.roomMetaUpdated(let peer, let room, let patch)) =
            RelayFrame.classify(json)
        else { return XCTFail("room_meta_updated") }
        XCTAssertEqual(peer, Fixture.piKey)
        XCTAssertEqual(room, RoomID("019ffb64-…"))
        XCTAssertEqual(patch.working, true)
        // The turn-boundary `working` patch is the most common frame on this
        // socket. Reading its absent `model` as "clear" would wipe the model
        // badge on every single turn.
        XCTAssertFalse(patch.model.isPresent)
        XCTAssertFalse(patch.thinking.isPresent)
        XCTAssertFalse(patch.name.isPresent)
    }

    /// `peer.rs:414-439`. `peer` / `room_id` are the destination **you
    /// addressed**, echoed back — scoped to a destination, never to a message,
    /// because the envelope carries no id and `ct` is opaque.
    func testTransportError() {
        guard case .control(.transportError(let peer, let room, let reason)) = RelayFrame.classify(
            #"{"type":"transport_error","reason":"offline","peer":"\#(key)","room_id":"019ffb64-…"}"#
        ) else { return XCTFail("transport_error") }
        XCTAssertEqual(peer, Fixture.piKey)
        XCTAssertEqual(room, RoomID("019ffb64-…"))
        XCTAssertEqual(reason, "offline", "the only value this path emits — but keep it a String")
    }

    /// The relay ships independently of this client and will grow frame types
    /// this build has never heard of. Dropping is correct; throwing is not.
    func testUnknownControlFrameIsDroppedNotThrown() async throws {
        let (transport, socket, _) = try await Fixture.connectedTransport()
        defer { Task { await transport.disconnect() } }

        socket.push(#"{"type":"quantum_entangled","peer":"\#(key)"}"#)
        socket.push("}{ not json")
        socket.push(#"{"type":"peer_online","peer":"\#(key)"}"#)

        await expectEventually { await transport.currentStatistics().deliveredControlFrames == 1 }
        let statistics = await transport.currentStatistics()
        XCTAssertEqual(statistics.droppedUnknown, 1)
        XCTAssertEqual(statistics.droppedMalformed, 1)
        XCTAssertFalse(socket.closed, "a frame we cannot read must never take the socket down")
    }

    // MARK: Outbound

    /// `{type, peers: [String]}` for all six
    /// (`app/lib/protocol/protocol.dart:157-185`, `peer.rs:212-220`).
    ///
    /// T1 again, and this one fails **silently**: `peers[]` entries are raw
    /// HashMap keys (`presence.rs:46-52`, `rooms.rs:139-145`), so a url-safe
    /// entry produces a subscription that simply never fires — forever, with
    /// no diagnostics anywhere.
    func testSubscriptionFramesUseStandardBase64Peers() throws {
        let fromQR = try XCTUnwrap(PeerID(base64: Fixture.piKey.urlSafeValue))
        let frames: [(ClientControlFrame, String)] = [
            (.subscribePresence(peers: [fromQR]), "subscribe_presence"),
            (.unsubscribePresence(peers: [fromQR]), "unsubscribe_presence"),
            (.presenceCheck(peers: [fromQR]), "presence_check"),
            (.subscribeRooms(peers: [fromQR]), "subscribe_rooms"),
            (.unsubscribeRooms(peers: [fromQR]), "unsubscribe_rooms"),
            (.roomsCheck(peers: [fromQR]), "rooms_check"),
        ]
        for (frame, type) in frames {
            let object = frame.jsonObject
            XCTAssertEqual(object["type"] as? String, type)
            XCTAssertEqual(object["peers"] as? [String], [Fixture.piKeyWire])
            XCTAssertEqual(Set(object.keys), ["type", "peers"])
        }
    }
}
