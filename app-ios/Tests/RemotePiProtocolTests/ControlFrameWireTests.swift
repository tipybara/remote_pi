import Foundation
import XCTest

@testable import RemotePiProtocol

/// Relay control frames and `RoomMeta` merge-patching, pinned against
/// `plan/62-specs/02-relay-control-frames.md` (written from `relay/src/**`,
/// which is the authority) and the archived fixtures in
/// `.orchestration/contracts/fixtures/`.
///
/// The fixtures' `peer` strings are short placeholders — `"RU9rXbR2dEVwM1AyZTM="`
/// decodes to 14 bytes — and ``PeerID`` refuses them, correctly: the relay
/// derives its registry key from a real 32-byte verifying key and nothing
/// shorter can ever match one. Each test below keeps the fixture's structure
/// and substitutes ``WireFixtures/peerKeyStandard``.
final class ControlFrameWireTests: XCTestCase {

    private var key: String { WireFixtures.peerKeyStandard }

    private func parse(_ text: String) throws -> ControlFrame? {
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        return ControlFrame.parse(object)
    }

    // MARK: - presence

    /// Fixture: `peer_online.jsonl`. No `since_ts` on this frame.
    func testPeerOnline() throws {
        guard case .peerOnline(let peer)? = try parse(#"{"type":"peer_online","peer":"\#(key)"}"#)
        else { return XCTFail("not peer_online") }
        XCTAssertEqual(peer.wireValue, key)
    }

    /// Fixture: `peer_offline.jsonl`. `since_ts` is epoch **milliseconds** and
    /// is always present here.
    func testPeerOffline() throws {
        guard
            case .peerOffline(_, let sinceTs)? = try parse(
                #"{"type":"peer_offline","peer":"\#(key)","since_ts":1716234500000}"#)
        else { return XCTFail("not peer_offline") }
        XCTAssertEqual(sinceTs, 1_716_234_500_000)
    }

    /// Fixture: `presence.jsonl`.
    ///
    /// `PeerPresence` has no `skip_serializing_if` in Rust
    /// (`presence.rs:104-108`), so `since_ts` is an **always-present key**,
    /// explicitly `null` while the peer is online. It is also non-null only for
    /// a peer the relay watched disconnect since its own process start — the
    /// map is in-memory, so a restart empties it.
    func testPresenceSnapshotKeepsOrderAndNullSinceTs() throws {
        let other = Data(repeating: 0x11, count: 32).base64EncodedString()
        guard
            case .presence(let states)? = try parse(
                #"""
                {"type":"presence","states":[
                  {"peer":"\#(key)","online":true,"since_ts":null},
                  {"peer":"\#(other)","online":false,"since_ts":1716234500000}]}
                """#)
        else { return XCTFail("not presence") }
        XCTAssertEqual(states.count, 2)
        XCTAssertEqual(states[0].peer.wireValue, key, "request order is preserved")
        XCTAssertTrue(states[0].online)
        XCTAssertNil(states[0].sinceTs)
        XCTAssertFalse(states[1].online)
        XCTAssertEqual(states[1].sinceTs, 1_716_234_500_000)
    }

    // MARK: - rooms

    /// Fixture: `rooms.jsonl`, two legacy rooms (12-char digest ids, `cwd` but
    /// no `workspace_path`, no `session_id`).
    ///
    /// A `rooms` array is the **authoritative live set** for that peer: a room
    /// missing from it has no live connection. An unknown peer answers `[]`,
    /// which means "everything is dead", not "no information".
    func testRoomsSnapshot() throws {
        guard
            case .rooms(_, let rooms)? = try parse(
                #"""
                {"type":"rooms","peer":"\#(key)","rooms":[
                  {"room_id":"aB12CD34eF56","name":"remote_pi · feature/protocol",
                   "cwd":"/Users/jacob/Projects/remote_pi","started_at":1716234500000},
                  {"room_id":"xY78ZW90vU12","name":"projeto-b · main",
                   "cwd":"/Users/jacob/Projects/projeto-b","started_at":1716234700000}]}
                """#)
        else { return XCTFail("not rooms") }
        XCTAssertEqual(rooms.count, 2)
        XCTAssertFalse(rooms[0].hasStableIdentity, "no session_id → pre-plan-61 Pi")
        XCTAssertEqual(
            rooms[0].effectiveWorkspacePath, "/Users/jacob/Projects/remote_pi",
            "workspace_path falls back to cwd, exactly as the relay does on hello")
        XCTAssertFalse(rooms[0].working, "working defaults to false, never null")
    }

    /// Spec 02 §3.5 — the post-plan-61 `room_announced`, flat at the top level
    /// with no `meta` sub-object.
    func testRoomAnnouncedFlatPostPlan61() throws {
        guard
            case .roomAnnounced(let peer, let meta)? = try parse(
                #"""
                {"type":"room_announced","peer":"\#(key)",
                 "room_id":"019ffb64-1c3e-7a91-b0d2-6f2a1c9e77aa",
                 "session_id":"019ffb64-1c3e-7a91-b0d2-6f2a1c9e77aa",
                 "workspace_path":"/Users/x/proj","name":"backend",
                 "name_rev":1780000000000,"cwd":"/Users/x/proj",
                 "model":"claude-sonnet-4.5","thinking":"high",
                 "working":false,"started_at":1780000000456}
                """#)
        else { return XCTFail("not room_announced") }
        XCTAssertEqual(peer.wireValue, key)
        XCTAssertEqual(meta.sessionID?.rawValue, meta.roomID.rawValue)
        XCTAssertTrue(meta.hasStableIdentity)
        XCTAssertEqual(meta.model, "claude-sonnet-4.5")
        XCTAssertEqual(meta.thinking, "high")
        XCTAssertEqual(ThinkingLevel(wire: try XCTUnwrap(meta.thinking)), .high)
        XCTAssertEqual(meta.nameRev, 1_780_000_000_000)
        XCTAssertEqual(meta.startedAt, 1_780_000_000_456)
        XCTAssertFalse(meta.isControlRoom)
    }

    /// The gateway's permanent room. `role == "control"` is the marker; the
    /// room must never render as a chat tile and its envelopes must bypass the
    /// active-room demux, or every gateway reply is discarded as a mismatch.
    func testControlRoomAnnouncement() throws {
        guard
            case .roomAnnounced(_, let meta)? = try parse(
                #"""
                {"type":"room_announced","peer":"\#(key)","room_id":"ctrl","role":"control",
                 "working":false,"started_at":1}
                """#)
        else { return XCTFail("not room_announced") }
        XCTAssertTrue(meta.isControlRoom)
    }

    /// Fixture: `room_ended.jsonl`.
    ///
    /// Post-plan-61 a rename never produces this frame, so `room_ended` really
    /// does mean "the process is gone" — but the session row stays, greyed.
    /// Deleting the transcript here is the bug the Flutter client avoids.
    func testRoomEnded() throws {
        guard
            case .roomEnded(_, let room, let sinceTs)? = try parse(
                #"{"type":"room_ended","peer":"\#(key)","room_id":"aB12CD34eF56","since_ts":1716234600000}"#
            )
        else { return XCTFail("not room_ended") }
        XCTAssertEqual(room, RoomID("aB12CD34eF56"))
        XCTAssertEqual(sinceTs, 1_716_234_600_000)
    }

    // MARK: - room_meta_updated and the patch contract

    /// Fixture: `room_meta_updated.jsonl` — a model-only patch.
    ///
    /// **Absent means preserve.** The relay's broadcast is a post-patch
    /// snapshot of the five mutable fields, and it omits any that is currently
    /// null (`registry.rs:354-359`). Reading an absent key as "clear" wipes the
    /// model badge on every `working`-only ping.
    func testModelOnlyPatchPreservesEverythingElse() throws {
        guard
            case .roomMetaUpdated(_, let room, let patch)? = try parse(
                #"""
                {"type":"room_meta_updated","peer":"\#(key)","room_id":"aB12CD34eF56",
                 "meta":{"model":"claude-sonnet-4.5"}}
                """#)
        else { return XCTFail("not room_meta_updated") }
        XCTAssertEqual(room, RoomID("aB12CD34eF56"))

        var meta = RoomMeta(
            roomID: RoomID("aB12CD34eF56"), name: "backend", nameRev: 5,
            model: "claude-opus-4", thinking: "high", working: true)
        patch.apply(to: &meta)
        XCTAssertEqual(meta.model, "claude-sonnet-4.5")
        XCTAssertEqual(meta.thinking, "high", "absent thinking preserves")
        XCTAssertEqual(meta.name, "backend", "absent name preserves")
        XCTAssertEqual(meta.nameRev, 5)
        XCTAssertTrue(meta.working, "absent working preserves")
    }

    /// An explicit `null` clears, and `working: null` does **not**.
    ///
    /// The relay reads `working` with `and_then(as_bool)` (`peer.rs:314-316`),
    /// which collapses null and absent into "no change" — `false` is the off
    /// state, so the field has no null. Treating `working: null` as `false`
    /// would show every busy room as idle.
    func testExplicitNullClearsExceptForWorking() throws {
        guard
            case .roomMetaUpdated(_, _, let patch)? = try parse(
                #"""
                {"type":"room_meta_updated","peer":"\#(key)","room_id":"r",
                 "meta":{"model":null,"thinking":null,"working":null}}
                """#)
        else { return XCTFail("not room_meta_updated") }

        var meta = RoomMeta(
            roomID: RoomID("r"), model: "claude-opus-4", thinking: "high", working: true)
        patch.apply(to: &meta)
        XCTAssertNil(meta.model)
        XCTAssertNil(meta.thinking)
        XCTAssertTrue(meta.working, "working: null is preserve, not false")
    }

    /// `working: false` is a real value, not an absence.
    func testWorkingFalseIsApplied() throws {
        guard
            case .roomMetaUpdated(_, _, let patch)? = try parse(
                #"{"type":"room_meta_updated","peer":"\#(key)","room_id":"r","meta":{"working":false}}"#
            )
        else { return XCTFail("not room_meta_updated") }
        var meta = RoomMeta(roomID: RoomID("r"), working: true)
        patch.apply(to: &meta)
        XCTAssertFalse(meta.working)
        XCTAssertFalse(patch.isEmpty)
    }

    /// The full `name_rev` truth table from spec 02 §4 / `registry.rs:306-311`.
    func testNameRevGateTruthTable() {
        // | has name | patch rev | stored rev | accepted |
        XCTAssertFalse(
            RoomMetaPatch(nameRev: 999).nameAccepted(over: 1),
            "no name in the patch → never accepted, and a lone name_rev never broadcasts")
        XCTAssertTrue(
            RoomMetaPatch(name: .set("a")).nameAccepted(over: 100),
            "patch omits a rev → trusted")
        XCTAssertTrue(
            RoomMetaPatch(name: .set("a"), nameRev: 100).nameAccepted(over: nil),
            "no stored rev → the first rev seen wins")
        XCTAssertFalse(
            RoomMetaPatch(name: .set("a"), nameRev: 100).nameAccepted(over: 100),
            "EQUAL is rejected — this is what stops a reconnecting second device "
                + "from replaying the last patch it saw")
        XCTAssertFalse(RoomMetaPatch(name: .set("a"), nameRev: 99).nameAccepted(over: 100))
        XCTAssertTrue(RoomMetaPatch(name: .set("a"), nameRev: 101).nameAccepted(over: 100))
    }

    /// A losing name patch must leave the cached label **and** revision alone.
    ///
    /// A rejected patch still triggers a broadcast carrying the *winning* name
    /// (that re-broadcast is the resync mechanism), so an inbound `name` is not
    /// evidence of a rename. Skipping this gate locally lets a second Owner
    /// device drag the label backwards.
    func testStaleNamePatchChangesNothing() {
        var meta = RoomMeta(roomID: RoomID("r"), name: "backend", nameRev: 200)
        RoomMetaPatch(name: .set("old-name"), nameRev: 199).apply(to: &meta)
        XCTAssertEqual(meta.name, "backend")
        XCTAssertEqual(meta.nameRev, 200)
    }

    /// `name_rev` is written only when the name is accepted **and** the patch
    /// supplied one (`registry.rs:322-329`); accepting a rev-less name leaves
    /// the stored revision untouched.
    func testAcceptingARevlessNameLeavesTheStoredRevAlone() {
        var meta = RoomMeta(roomID: RoomID("r"), name: "old", nameRev: 42)
        RoomMetaPatch(name: .set("new")).apply(to: &meta)
        XCTAssertEqual(meta.name, "new")
        XCTAssertEqual(meta.nameRev, 42)
    }

    /// `RoomMetaPatch::is_empty` ignores `name_rev` (`rooms.rs:100-105`), so a
    /// revision on its own must not be sent — the relay would suppress the
    /// broadcast anyway.
    func testRevisionAloneIsNotAPatch() {
        XCTAssertTrue(RoomMetaPatch(nameRev: 1).isEmpty)
        XCTAssertFalse(RoomMetaPatch(name: .set("x")).isEmpty)
        XCTAssertFalse(RoomMetaPatch(working: false).isEmpty)
        XCTAssertFalse(RoomMetaPatch(model: .clear).isEmpty, "a clear is content")
    }

    // MARK: - transport_error

    /// Spec 02 §3.8. `peer` and `room_id` echo the **destination you
    /// addressed**, and the frame is scoped to that destination rather than to
    /// a message — the outer envelope has no message id and `ct` is opaque, so
    /// the relay cannot name what failed. Fail everything outstanding for that
    /// `(peer, room)`.
    func testTransportError() throws {
        guard
            case .transportError(let peer, let room, let reason)? = try parse(
                #"""
                {"type":"transport_error","reason":"offline","peer":"\#(key)",
                 "room_id":"019ffb64-1c3e-7a91-b0d2-6f2a1c9e77aa"}
                """#)
        else { return XCTFail("not transport_error") }
        XCTAssertEqual(peer.wireValue, key)
        XCTAssertEqual(room, RoomID("019ffb64-1c3e-7a91-b0d2-6f2a1c9e77aa"))
        XCTAssertEqual(reason, "offline")
    }

    // MARK: - outbound frames

    /// Fixtures: `subscribe_presence.jsonl`, `subscribe_rooms.jsonl`,
    /// `presence_check.jsonl`, `rooms_check.jsonl`,
    /// `unsubscribe_presence.jsonl`, `unsubscribe_rooms.jsonl`.
    ///
    /// Every entry of `peers` is a **raw HashMap key** against the relay's
    /// registry (`presence.rs:46-52`, `rooms.rs:139-145`) — no normalization
    /// happens outside `hello.pubkey`. A URL-safe spelling here produces a
    /// subscription that never fires: silently, forever, with no diagnostic.
    func testSubscribeFramesUseStandardPaddedBase64() throws {
        let peer = WireFixtures.peer
        let frames: [(ClientControlFrame, String)] = [
            (.subscribePresence(peers: [peer]), "subscribe_presence"),
            (.unsubscribePresence(peers: [peer]), "unsubscribe_presence"),
            (.presenceCheck(peers: [peer]), "presence_check"),
            (.subscribeRooms(peers: [peer]), "subscribe_rooms"),
            (.unsubscribeRooms(peers: [peer]), "unsubscribe_rooms"),
            (.roomsCheck(peers: [peer]), "rooms_check"),
        ]
        for (frame, type) in frames {
            let object = frame.jsonObject
            XCTAssertEqual(object["type"] as? String, type)
            XCTAssertEqual(
                object["peers"] as? [String], [key],
                "\(type) must carry the standard, padded spelling")
        }
    }

    /// `hello.room_meta` is serialized in the relay's own shape: `nil`
    /// optionals **omitted**, `working` and `started_at` always present.
    func testHelloRoomMetaShape() throws {
        let meta = RoomMeta(
            roomID: RoomID("019ffb64"), sessionID: SessionID("019ffb64"),
            workspacePath: "/Users/x/proj", name: "backend", nameRev: 7,
            working: true, startedAt: 1)
        let frame = ClientControlFrame.hello(
            pubkey: WireFixtures.peer, room: RoomID("019ffb64"), meta: meta)
        let object = frame.jsonObject

        XCTAssertEqual(object["type"] as? String, "hello")
        XCTAssertEqual(object["pubkey"] as? String, key)
        XCTAssertEqual(object["room_id"] as? String, "019ffb64")

        let roomMeta = try XCTUnwrap(object["room_meta"] as? [String: Any])
        XCTAssertEqual(roomMeta["session_id"] as? String, "019ffb64")
        XCTAssertEqual(roomMeta["name_rev"] as? Int, 7)
        XCTAssertEqual(roomMeta["working"] as? Bool, true)
        XCTAssertNotNil(roomMeta["started_at"], "started_at is never skipped")
        XCTAssertNil(roomMeta["model"], "a nil optional is omitted, never null")
        XCTAssertNil(roomMeta["role"])
        XCTAssertNil(roomMeta["cwd"])
    }

    /// The `auth` signature is standard base64 over the **raw** nonce bytes.
    func testAuthFrame() {
        let object = ClientControlFrame.auth(signature: Data([0xDE, 0xAD, 0xBE, 0xEF])).jsonObject
        XCTAssertEqual(object["type"] as? String, "auth")
        XCTAssertEqual(object["sig"] as? String, "3q2+7w==")
    }

    /// The challenge nonce arrives base64-encoded and must be signed **raw** —
    /// signing the text is the classic way to produce a valid-looking `auth`
    /// that fails verification.
    func testChallengeNonceDecodesToRawBytes() throws {
        let nonceBytes = Data(repeating: 0xAB, count: 32)
        guard
            case .challenge(let nonce)? = try parse(
                #"{"type":"challenge","nonce":"\#(nonceBytes.base64EncodedString())"}"#)
        else { return XCTFail("not challenge") }
        XCTAssertEqual(nonce, nonceBytes)
    }

    // MARK: - forward compatibility

    func testUnknownControlFrameIsDropped() throws {
        XCTAssertNil(try parse(#"{"type":"quantum_presence","peer":"\#(key)"}"#))
    }

    /// An envelope is not a control frame and must not be routed as one: the
    /// relay decides purely on the presence of a top-level string `type`
    /// (`peer.rs:202-211`).
    func testEnvelopeShapeIsNotAControlFrame() throws {
        XCTAssertNil(try parse(#"{"peer":"\#(key)","room":"main","ct":"e30="}"#))
    }
}
