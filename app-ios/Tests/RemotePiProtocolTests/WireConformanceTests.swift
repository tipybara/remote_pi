import Foundation
import XCTest

@testable import RemotePiProtocol

// MARK: - Fixture loading

/// Loader for `Tests/Fixtures/wire/*.json` — frames recorded off a live relay
/// by `Tests/Fixtures/capture-wire.mjs`.
///
/// ## Why the filesystem and not `Bundle.module`
///
/// Resource bundling needs a `resources:` clause in `Package.swift`, and this
/// suite is not allowed to touch that file. `#filePath` is absolute and points
/// into the checkout, which is where `swift test` runs from, so the fixtures
/// are reachable without declaring anything.
///
/// ## What is compared, and what is not
///
/// Every assertion below reads ``Fixture/raw`` — the exact UTF-8 text that
/// crossed the wire — and never the pretty-printed `frame` copy in the same
/// file. Key ORDER is deliberately not pinned: `serde_json` emits its
/// `BTreeMap` order (alphabetical), `JSON.stringify` emits insertion order and
/// `JSONEncoder` emits its own, and all three are the same JSON. What is
/// pinned is which keys exist, which are absent, and the value **and JSON
/// type** of each.
enum CapturedWire {
    static let directory: URL =
        URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // RemotePiProtocolTests
        .deletingLastPathComponent()  // Tests
        .appendingPathComponent("Fixtures", isDirectory: true)
        .appendingPathComponent("wire", isDirectory: true)

    struct Fixture {
        /// The exact frame text as captured.
        let raw: String
        /// For an outer envelope: the decoded `ct`, as text.
        let innerRaw: String?

        var data: Data { Data(raw.utf8) }
        var innerData: Data? { innerRaw.map { Data($0.utf8) } }
    }

    static func load(
        _ name: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> Fixture {
        let url = directory.appendingPathComponent("\(name).json")
        let data = try Data(contentsOf: url)
        let wrapper = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "fixture \(name) is not a JSON object", file: file, line: line)
        return Fixture(
            raw: try XCTUnwrap(wrapper["raw"] as? String, file: file, line: line),
            innerRaw: wrapper["inner_raw"] as? String
        )
    }

    /// The captured frame, parsed.
    static func object(
        _ name: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> [String: Any] {
        let raw = try load(name, file: file, line: line).raw
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
            file: file, line: line)
    }

    /// The captured envelope's decoded inner frame, parsed.
    static func inner(
        _ name: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> [String: Any] {
        let fixture = try load(name, file: file, line: line)
        let raw = try XCTUnwrap(
            fixture.innerRaw, "fixture \(name) is not an envelope", file: file, line: line)
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
            file: file, line: line)
    }

    static func innerData(
        _ name: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> Data {
        let fixture = try load(name, file: file, line: line)
        return try XCTUnwrap(
            fixture.innerData, "fixture \(name) is not an envelope", file: file, line: line)
    }
}

// MARK: - Structural JSON comparison

/// Deep equality that distinguishes a JSON `true` from a JSON `1`.
///
/// `NSDictionary`'s own `isEqual:` bridges `__NSCFBoolean` and `__NSCFNumber`
/// together, so a `working` that degraded from a bool into a number would slip
/// through it. `working` is exactly the field where that matters — the relay
/// declares it a non-nullable bool and clients branch on it — so the check is
/// explicit here.
func assertWireEqual(
    _ actual: Any?,
    _ expected: Any?,
    _ path: String = "$",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    func isBoolean(_ value: Any) -> Bool {
        CFGetTypeID(value as AnyObject) == CFBooleanGetTypeID()
    }

    switch (actual, expected) {
    case (nil, nil):
        return
    case (let a?, let e?):
        if a is NSNull || e is NSNull {
            XCTAssertTrue(
                a is NSNull && e is NSNull, "\(path): null on one side only", file: file, line: line)
            return
        }
        if let aDict = a as? [String: Any], let eDict = e as? [String: Any] {
            XCTAssertEqual(
                Set(aDict.keys), Set(eDict.keys),
                "\(path): key sets differ (extra: \(Set(aDict.keys).subtracting(eDict.keys)), "
                    + "missing: \(Set(eDict.keys).subtracting(aDict.keys)))",
                file: file, line: line)
            for key in Set(aDict.keys).intersection(eDict.keys) {
                assertWireEqual(aDict[key], eDict[key], "\(path).\(key)", file: file, line: line)
            }
            return
        }
        if let aArray = a as? [Any], let eArray = e as? [Any] {
            XCTAssertEqual(aArray.count, eArray.count, "\(path): array length", file: file, line: line)
            for (index, pair) in zip(aArray, eArray).enumerated() {
                assertWireEqual(pair.0, pair.1, "\(path)[\(index)]", file: file, line: line)
            }
            return
        }
        XCTAssertEqual(
            isBoolean(a), isBoolean(e),
            "\(path): bool/number mismatch (\(a) vs \(e))", file: file, line: line)
        if let aString = a as? String, let eString = e as? String {
            XCTAssertEqual(aString, eString, "\(path)", file: file, line: line)
            return
        }
        if let aNumber = a as? NSNumber, let eNumber = e as? NSNumber {
            XCTAssertEqual(aNumber, eNumber, "\(path)", file: file, line: line)
            return
        }
        XCTFail("\(path): incomparable values \(a) vs \(e)", file: file, line: line)
    case (nil, _):
        XCTFail("\(path): missing", file: file, line: line)
    case (_, nil):
        XCTFail("\(path): unexpected", file: file, line: line)
    }
}

/// Re-encodes `value` through the production encoder and parses the result.
func reencoded(
    _ value: some Encodable, file: StaticString = #filePath, line: UInt = #line
) throws -> [String: Any] {
    let data = try WireJSON.encode(value)
    return try XCTUnwrap(
        try JSONSerialization.jsonObject(with: data) as? [String: Any], file: file, line: line)
}

// MARK: - Tests

/// Wire conformance for `RemotePiProtocol`, pinned frame-by-frame against
/// `Tests/Fixtures/wire/`, which was recorded off a **live** `relay`, the
/// **real** `pi-extension` machine gateway, and the unmodified
/// `scripts/fake-pi.mjs`. See `Tests/Fixtures/README.md` for how to reproduce
/// the capture and which component produced each frame.
final class WireConformanceTests: XCTestCase {

    private func control(
        _ name: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> ControlFrame {
        try XCTUnwrap(
            ControlFrame.parse(try CapturedWire.object(name, file: file, line: line)),
            "\(name) did not parse as a control frame", file: file, line: line)
    }

    // MARK: Handshake

    /// `challenge.json` — relay → app, `relay/src/auth/challenge.rs`.
    func testChallengeCarriesThirtyTwoRawBytes() throws {
        guard case .challenge(let nonce) = try control("challenge") else {
            return XCTFail("not a challenge")
        }
        XCTAssertEqual(nonce.count, 32)
        // The relay always spells the nonce with the standard alphabet and
        // padding, so a 32-byte nonce is 44 characters ending in `=`.
        let raw = try CapturedWire.object("challenge")["nonce"] as? String
        XCTAssertEqual(raw?.count, 44)
        XCTAssertEqual(raw?.hasSuffix("="), true)
        XCTAssertFalse(raw?.contains("-") ?? true)
        XCTAssertFalse(raw?.contains("_") ?? true)
    }

    /// `hello_app.json` — the frame this client must produce byte-for-byte.
    func testAppHelloEncodesExactly() throws {
        let expected = try CapturedWire.object("hello_app")
        let peer = try XCTUnwrap(PeerID(base64: expected["pubkey"] as! String))
        let frame = ClientControlFrame.hello(pubkey: peer, room: .main, meta: nil)
        assertWireEqual(frame.jsonObject, expected)
        // No `room_meta`: only a Pi publishes one.
        XCTAssertNil(frame.jsonObject["room_meta"])
        XCTAssertEqual(expected["room_id"] as? String, "main")
    }

    /// `auth.json` — standard Base64, padded, 64 bytes.
    func testAuthSignatureSpelling() throws {
        let sig = try XCTUnwrap(CapturedWire.object("auth")["sig"] as? String)
        XCTAssertEqual(sig.count, 88)
        XCTAssertTrue(sig.hasSuffix("=="))
        XCTAssertEqual(Data(base64Encoded: sig, options: [])?.count, 64)
        let rebuilt = ClientControlFrame.auth(signature: Data(base64Encoded: sig)!)
        assertWireEqual(rebuilt.jsonObject, try CapturedWire.object("auth"))
    }

    /// `hello_pi_session.json` — a Pi's `room_meta` carries no `room_id` of its
    /// own; the sibling `room_id` field is the room. Documented here because
    /// ``RoomMeta`` cannot be decoded from that object alone, and the next
    /// person to try will want to know why.
    func testPiHelloRoomMetaHasNoRoomID() throws {
        let hello = try CapturedWire.object("hello_pi_session")
        let meta = try XCTUnwrap(hello["room_meta"] as? [String: Any])
        XCTAssertNil(meta["room_id"])
        XCTAssertNil(meta["started_at"], "started_at is stamped by the relay, never by the Pi")
        XCTAssertEqual(meta["session_id"] as? String, hello["room_id"] as? String)
        // The full post-plan-61 set.
        XCTAssertEqual(
            Set(meta.keys),
            [
                "name", "cwd", "session_id", "workspace_path", "name_rev", "model", "thinking",
                "working",
            ])
    }

    /// `hello_pi_control.json` — the REAL gateway. A control room publishes no
    /// session identity at all, which is what makes
    /// ``RoomMeta/hasStableIdentity`` false for it.
    func testGatewayHelloPublishesRoleAndNoSession() throws {
        let meta = try XCTUnwrap(
            CapturedWire.object("hello_pi_control")["room_meta"] as? [String: Any])
        XCTAssertEqual(meta["role"] as? String, RoomRole.control.rawValue)
        XCTAssertNil(meta["session_id"])
        XCTAssertNil(meta["name_rev"])
        XCTAssertEqual(
            try CapturedWire.object("hello_pi_control")["room_id"] as? String,
            RoomID.control.rawValue)
    }

    // MARK: room_announced / rooms

    /// `room_announced.json` — the relay serialises ``RoomMeta`` FLAT and
    /// stamps `type` + `peer` onto the same object.
    func testRoomAnnouncedDecodesEveryField() throws {
        let json = try CapturedWire.object("room_announced")
        guard case .roomAnnounced(let peer, let meta) = try control("room_announced") else {
            return XCTFail("not room_announced")
        }
        XCTAssertEqual(peer.wireValue, json["peer"] as? String)
        XCTAssertEqual(meta.roomID.rawValue, json["room_id"] as? String)
        XCTAssertEqual(meta.sessionID?.rawValue, json["session_id"] as? String)
        XCTAssertEqual(meta.roomID.rawValue, meta.sessionID?.rawValue, "plan 61: room_id == session_id")
        XCTAssertTrue(meta.hasStableIdentity)
        XCTAssertFalse(meta.isControlRoom)
        XCTAssertEqual(meta.name, json["name"] as? String)
        XCTAssertEqual(meta.nameRev, (json["name_rev"] as? NSNumber)?.int64Value)
        XCTAssertEqual(meta.workspacePath, json["workspace_path"] as? String)
        XCTAssertEqual(meta.cwd, json["cwd"] as? String)
        XCTAssertEqual(meta.model, json["model"] as? String)
        XCTAssertEqual(meta.thinking, json["thinking"] as? String)
        XCTAssertEqual(ThinkingLevel(wire: meta.thinking ?? ""), .medium)
        XCTAssertEqual(meta.working, json["working"] as? Bool)
        XCTAssertEqual(meta.startedAt, (json["started_at"] as? NSNumber)?.int64Value)
        XCTAssertNil(meta.role)
    }

    /// Round-trip: what the relay announced must re-encode to the same object,
    /// minus the two keys the relay stamps on (`type`, `peer`). This is the
    /// "would the relay accept what we produce" half.
    func testRoomMetaReencodesToTheRelayShape() throws {
        for name in ["room_announced", "room_announced_control"] {
            var expected = try CapturedWire.object(name)
            expected.removeValue(forKey: "type")
            expected.removeValue(forKey: "peer")
            let meta = try XCTUnwrap(RoomMeta.parseAnnouncement(try CapturedWire.object(name)))
            assertWireEqual(try reencoded(meta), expected, "$(\(name))")
        }
    }

    /// `room_announced_control.json` — `role: "control"` and the reserved id.
    func testControlRoomAnnouncement() throws {
        guard case .roomAnnounced(_, let meta) = try control("room_announced_control") else {
            return XCTFail("not room_announced")
        }
        XCTAssertEqual(meta.role, "control")
        XCTAssertEqual(meta.roomID, .control)
        XCTAssertTrue(meta.isControlRoom)
        XCTAssertFalse(meta.hasStableIdentity, "a control room has no session_id")
        XCTAssertNil(meta.model)
        XCTAssertNil(meta.thinking)
        XCTAssertFalse(meta.roomID.hasSessionIDShape, "\"ctrl\" is four characters, deliberately")
    }

    /// `rooms_snapshot.json` — every entry is a bare serialised ``RoomMeta``,
    /// so `Codable` alone must round-trip it.
    func testRoomsSnapshotEntriesRoundTripThroughCodable() throws {
        let json = try CapturedWire.object("rooms_snapshot")
        let entries = try XCTUnwrap(json["rooms"] as? [[String: Any]])
        XCTAssertGreaterThan(entries.count, 1)

        guard case .rooms(let peer, let rooms) = try control("rooms_snapshot") else {
            return XCTFail("not rooms")
        }
        XCTAssertEqual(peer.wireValue, json["peer"] as? String)
        XCTAssertEqual(rooms.count, entries.count)

        for entry in entries {
            let data = try JSONSerialization.data(withJSONObject: entry)
            let meta = try WireJSON.decode(RoomMeta.self, from: data)
            assertWireEqual(try reencoded(meta), entry, "$.rooms[\(meta.roomID.rawValue)]")
        }
        // Exactly one control room in the snapshot, and it must be filterable.
        XCTAssertEqual(rooms.filter(\.isControlRoom).count, 1)
    }

    /// `rooms_empty.json` — a snapshot for a peer that has registered nothing
    /// is `rooms: []`, not an omitted key.
    func testEmptyRoomsSnapshot() throws {
        guard case .rooms(_, let rooms) = try control("rooms_empty") else {
            return XCTFail("not rooms")
        }
        XCTAssertTrue(rooms.isEmpty)
        XCTAssertNotNil(try CapturedWire.object("rooms_empty")["rooms"] as? [Any])
    }

    /// `room_ended.json`.
    func testRoomEnded() throws {
        let json = try CapturedWire.object("room_ended")
        guard case .roomEnded(let peer, let room, let sinceTs) = try control("room_ended") else {
            return XCTFail("not room_ended")
        }
        XCTAssertEqual(peer.wireValue, json["peer"] as? String)
        XCTAssertEqual(room.rawValue, json["room_id"] as? String)
        XCTAssertEqual(sinceTs, (json["since_ts"] as? NSNumber)?.int64Value)
        XCTAssertGreaterThan(sinceTs, 1_700_000_000_000)
    }

    // MARK: presence

    /// `peer_online.json` — no timestamp on this one, by design.
    func testPeerOnlineCarriesNoTimestamp() throws {
        let json = try CapturedWire.object("peer_online")
        XCTAssertEqual(Set(json.keys), ["type", "peer"])
        guard case .peerOnline(let peer) = try control("peer_online") else {
            return XCTFail("not peer_online")
        }
        XCTAssertEqual(peer.wireValue, json["peer"] as? String)
    }

    /// `peer_offline.json`.
    func testPeerOffline() throws {
        let json = try CapturedWire.object("peer_offline")
        guard case .peerOffline(let peer, let sinceTs) = try control("peer_offline") else {
            return XCTFail("not peer_offline")
        }
        XCTAssertEqual(peer.wireValue, json["peer"] as? String)
        XCTAssertEqual(sinceTs, (json["since_ts"] as? NSNumber)?.int64Value)
    }

    /// `presence_offline.json` — `since_ts` is present as an explicit `null`
    /// for a peer the relay has never seen, not omitted. A decoder that
    /// required a number here would drop the whole snapshot.
    func testPresenceExplicitNullSinceTs() throws {
        let json = try CapturedWire.object("presence_offline")
        let states = try XCTUnwrap(json["states"] as? [[String: Any]])
        XCTAssertTrue(states.allSatisfy { $0["since_ts"] is NSNull })

        guard case .presence(let parsed) = try control("presence_offline") else {
            return XCTFail("not presence")
        }
        XCTAssertEqual(parsed.count, states.count)
        XCTAssertTrue(parsed.allSatisfy { !$0.online && $0.sinceTs == nil })
    }

    /// `presence_with_since_ts.json` — after a real transition the same field
    /// carries a number, and an online peer can still have `null`.
    func testPresenceMixedSinceTs() throws {
        guard case .presence(let parsed) = try control("presence_with_since_ts") else {
            return XCTFail("not presence")
        }
        XCTAssertTrue(parsed.contains { !$0.online && $0.sinceTs != nil })
        XCTAssertTrue(parsed.contains { $0.online })
    }

    // MARK: transport_error

    /// `transport_error.json` — scoped to a destination, never to a message.
    func testTransportError() throws {
        let json = try CapturedWire.object("transport_error")
        XCTAssertEqual(Set(json.keys), ["type", "reason", "peer", "room_id"])
        guard case .transportError(let peer, let room, let reason) = try control("transport_error")
        else { return XCTFail("not transport_error") }
        XCTAssertEqual(peer.wireValue, json["peer"] as? String)
        XCTAssertEqual(room.rawValue, json["room_id"] as? String)
        XCTAssertEqual(reason, "offline")
    }

    // MARK: The merge patch — absent vs null vs set

    /// `room_meta_update_working.json` — a Pi patching one field.
    ///
    /// Everything not named must come back ``PatchField/absent``. A decoder
    /// that collapsed absent into "clear" would erase the model badge on every
    /// turn, since a turn starts with exactly this frame.
    func testWorkingOnlyPatchLeavesEverythingElseAbsent() throws {
        let meta = try XCTUnwrap(
            CapturedWire.object("room_meta_update_working")["meta"] as? [String: Any])
        XCTAssertEqual(Set(meta.keys), ["working"])

        let patch = RoomMetaPatch(metaJSONObject: meta)
        XCTAssertEqual(patch.working, true)
        XCTAssertEqual(patch.model, .absent)
        XCTAssertEqual(patch.thinking, .absent)
        XCTAssertEqual(patch.name, .absent)
        XCTAssertNil(patch.nameRev)
        XCTAssertFalse(patch.isEmpty)
        assertWireEqual(patch.metaJSONObject, meta)
    }

    /// `room_meta_update_clear_model.json` — an explicit `null`.
    ///
    /// This is the case `encodeIfPresent` cannot express, which is why
    /// ``PatchField`` exists at all.
    func testExplicitNullIsClearNotAbsent() throws {
        let meta = try XCTUnwrap(
            CapturedWire.object("room_meta_update_clear_model")["meta"] as? [String: Any])
        XCTAssertTrue(meta["model"] is NSNull, "the capture must carry a real JSON null")

        let patch = RoomMetaPatch(metaJSONObject: meta)
        XCTAssertEqual(patch.model, .clear)
        XCTAssertNotEqual(patch.model, .absent)
        XCTAssertTrue(patch.model.isPresent)
        XCTAssertEqual(patch.thinking, .absent)
        XCTAssertNil(patch.working)

        // .clear must survive a round trip as `null`, not vanish.
        assertWireEqual(patch.metaJSONObject, meta)
        XCTAssertTrue(patch.metaJSONObject["model"] is NSNull)

        // And applying it clears, where .absent would preserve.
        var room = RoomMeta(roomID: RoomID("r"), model: "claude-sonnet-4.5", thinking: "medium")
        patch.apply(to: &room)
        XCTAssertNil(room.model)
        XCTAssertEqual(room.thinking, "medium", "an absent key preserves")
    }

    /// `room_meta_updated_working.json` — the relay's broadcast after that
    /// one-field patch carries the **post-patch full state**, so every field
    /// the patch omitted is still there.
    func testBroadcastAfterPartialPatchCarriesFullState() throws {
        let meta = try XCTUnwrap(
            CapturedWire.object("room_meta_updated_working")["meta"] as? [String: Any])
        XCTAssertEqual(Set(meta.keys), ["model", "thinking", "working", "name", "name_rev"])
        XCTAssertEqual(meta["working"] as? Bool, true)
        XCTAssertEqual(meta["model"] as? String, "claude-sonnet-4.5")
        XCTAssertEqual(meta["name"] as? String, "patch-target")

        guard case .roomMetaUpdated(_, _, let patch) = try control("room_meta_updated_working")
        else { return XCTFail("not room_meta_updated") }
        XCTAssertEqual(patch.model, .set("claude-sonnet-4.5"))
        XCTAssertEqual(patch.thinking, .set("medium"))
        XCTAssertEqual(patch.working, true)
        XCTAssertEqual(patch.name, .set("patch-target"))
        XCTAssertEqual(patch.nameRev, 1_780_000_000_000)
    }

    /// `room_meta_updated_model_cleared.json` — after an explicit null the
    /// relay **omits** `model` from the broadcast rather than sending `null`.
    ///
    /// So the inbound broadcast cannot express "clear": a subscriber has to
    /// treat it as a full snapshot of the mutable fields, which is exactly what
    /// `relay/src/peers/registry.rs::update_room_meta` documents.
    func testClearedFieldIsOmittedFromTheBroadcast() throws {
        let meta = try XCTUnwrap(
            CapturedWire.object("room_meta_updated_model_cleared")["meta"] as? [String: Any])
        XCTAssertNil(meta["model"])
        XCTAssertFalse(meta.keys.contains("model"))
        XCTAssertNotNil(meta["thinking"], "the field that was NOT patched survives")

        guard case .roomMetaUpdated(_, _, let patch)
            = try control("room_meta_updated_model_cleared")
        else { return XCTFail("not room_meta_updated") }
        XCTAssertEqual(patch.model, .absent)
        XCTAssertEqual(patch.thinking, .set("medium"))
    }

    // MARK: The name_rev gate

    /// The relay applies a name patch only when the incoming revision is
    /// **strictly greater**. All three captured stimuli, checked against what
    /// the relay actually did with them.
    func testNameRevGateMatchesTheRelay() throws {
        let stored: Int64 = 1_780_000_000_000

        // Accepted: strictly newer.
        let fresh = RoomMetaPatch(
            metaJSONObject: try XCTUnwrap(
                CapturedWire.object("room_meta_updated_name")["meta"] as? [String: Any]))
        XCTAssertEqual(fresh.nameRev, 1_780_000_000_001)
        XCTAssertTrue(fresh.nameAccepted(over: stored))

        // Rejected: EQUAL is not enough.
        let equal = RoomMetaPatch(
            metaJSONObject: try XCTUnwrap(
                CapturedWire.object("room_meta_update_equal_rev")["meta"] as? [String: Any]))
        XCTAssertEqual(equal.nameRev, 1_780_000_000_001)
        XCTAssertFalse(
            equal.nameAccepted(over: 1_780_000_000_001),
            "the relay's rule is `incoming > stored`, not `>=`")

        // Rejected: older.
        let stale = RoomMetaPatch(
            metaJSONObject: try XCTUnwrap(
                CapturedWire.object("room_meta_update_stale_name")["meta"] as? [String: Any]))
        XCTAssertEqual(stale.name, .set("stale must lose"))
        XCTAssertFalse(stale.nameAccepted(over: 1_780_000_000_001))

        // Accepted on trust when either side omits a revision.
        XCTAssertTrue(RoomMetaPatch(name: .set("x")).nameAccepted(over: stored))
        XCTAssertTrue(RoomMetaPatch(name: .set("x"), nameRev: 1).nameAccepted(over: nil))
        // A revision with no name is never a rename.
        XCTAssertFalse(RoomMetaPatch(nameRev: .max).nameAccepted(over: stored))
        XCTAssertTrue(RoomMetaPatch(nameRev: .max).isEmpty, "name_rev alone is not a patch")
    }

    /// A rejected name patch STILL produces a broadcast, and that broadcast
    /// carries the room's **current** name — which is how the device that sent
    /// the stale patch re-syncs.
    ///
    /// Proof from the capture: `room_meta_updated_stale_rejected.json` is the
    /// frame the relay sent right after `room_meta_update_stale_name.json`,
    /// and it carries the name from the ACCEPTED patch, not the stale one.
    func testRejectedPatchStillBroadcastsTheCurrentName() throws {
        let rejectedStimulus = try XCTUnwrap(
            CapturedWire.object("room_meta_update_stale_name")["meta"] as? [String: Any])
        let broadcast = try XCTUnwrap(
            CapturedWire.object("room_meta_updated_stale_rejected")["meta"] as? [String: Any])

        XCTAssertEqual(rejectedStimulus["name"] as? String, "stale must lose")
        XCTAssertEqual(broadcast["name"] as? String, "patched name")
        XCTAssertEqual((broadcast["name_rev"] as? NSNumber)?.int64Value, 1_780_000_000_001)

        // Byte-identical to the accepted broadcast: an inbound `name` is not
        // evidence of a rename. Re-run the gate locally.
        assertWireEqual(
            broadcast,
            try XCTUnwrap(CapturedWire.object("room_meta_updated_name")["meta"] as? [String: Any]))

        var room = RoomMeta(roomID: RoomID("r"), name: "patched name", nameRev: 1_780_000_000_001)
        guard case .roomMetaUpdated(_, _, let patch)
            = try control("room_meta_updated_stale_rejected")
        else { return XCTFail("not room_meta_updated") }
        patch.apply(to: &room)
        XCTAssertEqual(room.name, "patched name")
        XCTAssertEqual(room.nameRev, 1_780_000_000_001)
    }

    /// `room_meta_update_name.json` — the frame a Pi sends for a rename, and
    /// the one this client must be able to produce for its own rooms.
    func testRoomMetaUpdateEncodesLikeAPi() throws {
        let expected = try CapturedWire.object("room_meta_update_name")
        let meta = try XCTUnwrap(expected["meta"] as? [String: Any])
        let frame = ClientControlFrame.roomMetaUpdate(
            room: RoomID(expected["room_id"] as! String),
            patch: RoomMetaPatch(
                name: .set(meta["name"] as! String),
                nameRev: (meta["name_rev"] as! NSNumber).int64Value)
        )
        assertWireEqual(frame.jsonObject, expected)
    }

    // MARK: Subscriptions

    func testSubscriptionFramesEncodeExactly() throws {
        for (fixture, build) in [
            ("subscribe_rooms", ClientControlFrame.subscribeRooms),
            ("subscribe_presence", ClientControlFrame.subscribePresence),
            ("rooms_check", ClientControlFrame.roomsCheck),
            ("presence_check", ClientControlFrame.presenceCheck),
        ] as [(String, ([PeerID]) -> ClientControlFrame)] {
            let expected = try CapturedWire.object(fixture)
            let peers = try XCTUnwrap(expected["peers"] as? [String]).map {
                PeerID(base64: $0)!
            }
            assertWireEqual(build(peers).jsonObject, expected, "$(\(fixture))")
        }
    }

    // MARK: Envelopes

    /// `envelope_app_to_pi.json` — outbound: `peer` is the destination and
    /// `room` is the destination's room.
    func testOutboundEnvelopeRoundTrips() throws {
        let expected = try CapturedWire.object("envelope_app_to_pi")
        let fixture = try CapturedWire.load("envelope_app_to_pi")
        let envelope = try WireJSON.decode(Envelope.self, from: fixture.data)

        XCTAssertEqual(envelope.peer.wireValue, expected["peer"] as? String)
        XCTAssertEqual(envelope.room.rawValue, expected["room"] as? String)
        XCTAssertEqual(envelope.ct, expected["ct"] as? String)
        XCTAssertNil(expected["type"], "an envelope must never carry a top-level type")
        assertWireEqual(try reencoded(envelope), expected)

        // The `ct` is Base64 of plaintext JSON — decodable, and it round-trips.
        let inner = try XCTUnwrap(envelope.payload)
        XCTAssertEqual(String(decoding: inner, as: UTF8.self), fixture.innerRaw)
        XCTAssertEqual(Envelope(peer: envelope.peer, room: envelope.room, payload: inner), envelope)
    }

    /// `envelope_pi_to_app_rewritten.json` — the SAME `ct`, after the relay
    /// rewrote both addressing fields to describe the sender.
    func testRelayRewritesPeerAndRoomOnDelivery() throws {
        let outbound = try CapturedWire.object("envelope_app_to_pi")
        let inbound = try CapturedWire.object("envelope_pi_to_app_rewritten")

        XCTAssertNotEqual(inbound["peer"] as? String, outbound["peer"] as? String)
        XCTAssertEqual(
            inbound["room"] as? String, "main",
            "the sender's room — the app registered on main")
        XCTAssertNotEqual(inbound["room"] as? String, outbound["room"] as? String)

        // The relay never touches `ct`: the echoed turn carries the app's own
        // message id straight back.
        let sent = try CapturedWire.inner("envelope_app_to_pi")
        let echoed = try CapturedWire.inner("envelope_pi_to_app_rewritten")
        XCTAssertEqual(sent["id"] as? String, echoed["id"] as? String)
        XCTAssertEqual(sent["text"] as? String, echoed["text"] as? String)
    }

    /// The relay's own size arithmetic, reproduced on a real captured `ct`.
    func testRelaySizeEstimateMatchesTheRelaysArithmetic() throws {
        let fixture = try CapturedWire.load("envelope_app_to_pi")
        let envelope = try WireJSON.decode(Envelope.self, from: fixture.data)
        XCTAssertEqual(envelope.relayEstimatedPayloadBytes, envelope.ct.utf8.count * 3 / 4)
        XCTAssertFalse(envelope.exceedsRelayLimit())
        XCTAssertEqual(Envelope.maxDecodedPayloadBytes, 4 * 1024 * 1024)
    }

    // MARK: Inner frames, Pi → app

    func testPairOkCarriesThePlan61Identity() throws {
        let json = try CapturedWire.inner("inner_pair_ok")
        let message = try XCTUnwrap(
            ServerMessage.decodeLossy(try CapturedWire.innerData("inner_pair_ok")))
        guard case .pairOk(let ok) = message else { return XCTFail("not pair_ok") }

        XCTAssertEqual(ok.inReplyTo, json["in_reply_to"] as? String)
        XCTAssertEqual(ok.roomID.rawValue, json["room_id"] as? String)
        XCTAssertFalse(ok.roomIDWasOmitted)
        XCTAssertEqual(ok.sessionID?.rawValue, json["session_id"] as? String)
        XCTAssertEqual(ok.roomID.rawValue, ok.sessionID?.rawValue)
        XCTAssertEqual(ok.workspacePath, json["workspace_path"] as? String)
        XCTAssertEqual(ok.displayName, json["display_name"] as? String)
        XCTAssertEqual(ok.nameRev, (json["name_rev"] as? NSNumber)?.int64Value)
        XCTAssertEqual(ok.sessionName, json["session_name"] as? String)
        XCTAssertEqual(ok.sessionStartedAt, (json["session_started_at"] as? NSNumber)?.int64Value)
        XCTAssertEqual(ok.hostname, json["hostname"] as? String)
        XCTAssertEqual(ok.harness?.name, "fake-pi harness")
    }

    func testPairErrorDecodes() throws {
        guard case .pairError(let error) = try XCTUnwrap(
            ServerMessage.decodeLossy(try CapturedWire.innerData("inner_pair_error")))
        else { return XCTFail("not pair_error") }
        XCTAssertEqual(error.code.rawValue, "token_consumed")
        XCTAssertFalse(error.message.isEmpty)
    }

    /// `user_message` from the Pi is the ECHO; `user_input` is the desktop TUI.
    /// Both decode into ``UserInput``, distinguished by ``UserInput/isEcho``.
    func testUserMessageEchoIsFlaggedAsAnEcho() throws {
        let json = try CapturedWire.inner("inner_user_message_echo")
        XCTAssertEqual(json["type"] as? String, "user_message")
        guard case .userInput(let payload) = try XCTUnwrap(
            ServerMessage.decodeLossy(try CapturedWire.innerData("inner_user_message_echo")))
        else { return XCTFail("not user_message") }
        XCTAssertTrue(payload.isEcho)
        XCTAssertEqual(payload.id, json["id"] as? String)
        XCTAssertEqual(payload.text, json["text"] as? String)
        XCTAssertNil(json["images"], "images are omitted entirely, never sent as []")
    }

    func testAgentStreamDecodes() throws {
        guard case .agentChunk(let chunk) = try XCTUnwrap(
            ServerMessage.decodeLossy(try CapturedWire.innerData("inner_agent_chunk")))
        else { return XCTFail("not agent_chunk") }
        let chunkJSON = try CapturedWire.inner("inner_agent_chunk")
        XCTAssertEqual(chunk.inReplyTo, chunkJSON["in_reply_to"] as? String)
        XCTAssertEqual(chunk.delta, chunkJSON["delta"] as? String)

        guard case .agentDone(let done) = try XCTUnwrap(
            ServerMessage.decodeLossy(try CapturedWire.innerData("inner_agent_done")))
        else { return XCTFail("not agent_done") }
        let doneJSON = try CapturedWire.inner("inner_agent_done")
        XCTAssertEqual(done.inReplyTo, doneJSON["in_reply_to"] as? String)
        let usage = try XCTUnwrap(doneJSON["usage"] as? [String: Any])
        XCTAssertEqual(done.usage?.inputTokens, (usage["input_tokens"] as? NSNumber)?.intValue)
        XCTAssertEqual(done.usage?.outputTokens, (usage["output_tokens"] as? NSNumber)?.intValue)

        // Same correlation id across the whole turn.
        XCTAssertEqual(chunk.inReplyTo, done.inReplyTo)
    }

    func testModelsListDecodes() throws {
        guard case .modelsList(let list) = try XCTUnwrap(
            ServerMessage.decodeLossy(try CapturedWire.innerData("inner_models_list")))
        else { return XCTFail("not models_list") }
        let json = try CapturedWire.inner("inner_models_list")
        let models = try XCTUnwrap(json["models"] as? [[String: Any]])
        XCTAssertEqual(list.models.count, models.count)
        XCTAssertEqual(list.models.first?.id, models.first?["id"] as? String)
        XCTAssertEqual(list.models.first?.contextWindow, 200_000)
        XCTAssertTrue(list.models.first?.reasoning ?? false)
        XCTAssertEqual(list.current?.id, (json["current"] as? [String: Any])?["id"] as? String)
    }

    func testSessionHistoryDecodesEveryEvent() throws {
        guard case .sessionHistory(let history) = try XCTUnwrap(
            ServerMessage.decodeLossy(try CapturedWire.innerData("inner_session_history")))
        else { return XCTFail("not session_history") }
        let json = try CapturedWire.inner("inner_session_history")
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])

        XCTAssertEqual(history.events.count, events.count)
        XCTAssertTrue(history.undecodableEvents.isEmpty, "nothing in the capture should be dropped")
        XCTAssertTrue(history.eos)
        XCTAssertFalse(history.truncated)
        XCTAssertEqual(history.sessionStartedAt, (json["session_started_at"] as? NSNumber)?.int64Value)

        guard case .userInput(_, let id, let text, let images) = history.events[0] else {
            return XCTFail("first event is not user_input")
        }
        XCTAssertEqual(id, events[0]["id"] as? String)
        XCTAssertEqual(text, events[0]["text"] as? String)
        XCTAssertTrue(images.isEmpty)
        guard case .agentMessage(_, let inReplyTo, _, _) = history.events[1] else {
            return XCTFail("second event is not agent_message")
        }
        XCTAssertEqual(inReplyTo, events[1]["in_reply_to"] as? String)
    }

    func testPongDecodes() throws {
        guard case .pong(let inReplyTo) = try XCTUnwrap(
            ServerMessage.decodeLossy(try CapturedWire.innerData("inner_pong")))
        else { return XCTFail("not pong") }
        XCTAssertEqual(inReplyTo, try CapturedWire.inner("inner_pong")["in_reply_to"] as? String)
    }

    func testChatActionRepliesDecode() throws {
        guard case .actionOk(let ok) = try XCTUnwrap(
            ServerMessage.decodeLossy(try CapturedWire.innerData("inner_action_ok_rename")))
        else { return XCTFail("not action_ok") }
        XCTAssertEqual(ok.action.rawValue, "session_rename")
        XCTAssertFalse(ok.isReplay)

        guard case .actionError(let error) = try XCTUnwrap(
            ServerMessage.decodeLossy(try CapturedWire.innerData("inner_action_error_rename")))
        else { return XCTFail("not action_error") }
        XCTAssertEqual(error.action.rawValue, "session_rename")
        XCTAssertTrue(error.error.contains("stale name revision"))
    }

    // MARK: Inner frames, app → Pi

    /// Every app-authored inner frame in the capture must re-encode to exactly
    /// what was on the wire.
    func testClientFramesReencodeExactly() throws {
        for name in ["inner_pair_request", "inner_session_rename", "control_workspace_list"] {
            let expected = try CapturedWire.inner(name)
            let message = try WireJSON.decode(
                ClientMessage.self, from: try CapturedWire.innerData(name))
            assertWireEqual(try reencoded(message), expected, "$(\(name))")
        }

        // The user turn, taken out of its captured envelope.
        let turn = try CapturedWire.inner("envelope_app_to_pi")
        let message = try WireJSON.decode(
            ClientMessage.self, from: try CapturedWire.innerData("envelope_app_to_pi"))
        guard case .userMessage(let user) = message else { return XCTFail("not user_message") }
        XCTAssertNil(user.images)
        XCTAssertNil(user.streamingBehavior)
        assertWireEqual(try reencoded(message), turn)
    }

    /// `inner_session_rename.json` — `rev` is the revision the device last
    /// SAW, and it must equal the `name_rev` the room was announced with.
    func testSessionRenameCarriesTheObservedRevision() throws {
        let json = try CapturedWire.inner("inner_session_rename")
        guard case .sessionRename(let rename) = try WireJSON.decode(
            ClientMessage.self, from: try CapturedWire.innerData("inner_session_rename"))
        else { return XCTFail("not session_rename") }

        XCTAssertEqual(rename.displayName, json["display_name"] as? String)
        XCTAssertEqual(rename.sessionID?.rawValue, json["session_id"] as? String)
        XCTAssertEqual(rename.rev, (json["rev"] as? NSNumber)?.int64Value)

        let announced = try CapturedWire.object("room_announced")
        XCTAssertEqual(rename.rev, (announced["name_rev"] as? NSNumber)?.int64Value)
        XCTAssertEqual(rename.sessionID?.rawValue, announced["session_id"] as? String)
    }

    // MARK: Control plane — pinned against the REAL gateway

    func testControlActionsReencodeExactly() throws {
        for name in ["control_workspace_list", "control_create_session"] {
            let expected = try CapturedWire.inner(name)
            let action = try JSONDecoder().decode(
                ControlAction.self, from: try CapturedWire.innerData(name))
            assertWireEqual(action.jsonObject, expected, "$(\(name))")
            assertWireEqual(
                try JSONSerialization.jsonObject(with: try action.encoded()), expected,
                "$(\(name)) via Codable")
        }
    }

    /// `control_create_session.json` — background is always `true`, and the
    /// idempotency key rides along.
    func testCreateSessionShape() throws {
        let json = try CapturedWire.inner("control_create_session")
        XCTAssertEqual(json["background"] as? Bool, true)
        let action = try JSONDecoder().decode(
            ControlAction.self, from: try CapturedWire.innerData("control_create_session"))
        guard case .createSession(_, let key, let workspace, let displayName) = action else {
            return XCTFail("not create_session")
        }
        XCTAssertEqual(key.rawValue, json["idempotency_key"] as? String)
        XCTAssertEqual(workspace.rawValue, json["workspace_id"] as? String)
        XCTAssertEqual(displayName, json["display_name"] as? String)

        // An explicit `background: false` is refused, not coerced — mirroring
        // `parseControlAction` in `control_wire.ts`.
        var refused = json
        refused["background"] = false
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ControlAction.self,
                from: try JSONSerialization.data(withJSONObject: refused)))
    }

    /// `control_action_ok_workspace_list.json` — produced by the REAL
    /// `daemon/sessions.ts::listWorkspaces`.
    func testWorkspaceListReplyMatchesTheMachine() throws {
        let json = try CapturedWire.inner("control_action_ok_workspace_list")
        guard case .ok(let success) = try XCTUnwrap(ControlReply.parse(json)) else {
            return XCTFail("not action_ok")
        }
        XCTAssertEqual(success.action, "workspace_list")
        let raw = try XCTUnwrap(json["workspaces"] as? [[String: Any]])
        XCTAssertEqual(success.workspaces.count, raw.count)
        let workspace = try XCTUnwrap(success.workspaces.first)
        XCTAssertEqual(workspace.workspaceID.rawValue, raw[0]["workspace_id"] as? String)
        XCTAssertEqual(workspace.path, raw[0]["path"] as? String)
        XCTAssertEqual(workspace.displayName, raw[0]["display_name"] as? String)
        // The daemon id, not a UUID: sha256(realpath)[..8].
        XCTAssertEqual(workspace.workspaceID.rawValue.count, 8)
    }

    /// `control_action_ok_session_list.json` — produced by the REAL gateway,
    /// whose `SessionEntry` carries `mode` / `desired` / `created_at` and gets
    /// a live `running` flag stapled on. `scripts/fake-pi.mjs` answers with a
    /// simpler shape (`status`, `name_rev`), which is why this fixture comes
    /// from the machine and not from the harness.
    func testSessionListReplyMatchesTheMachine() throws {
        let json = try CapturedWire.inner("control_action_ok_session_list")
        guard case .ok(let success) = try XCTUnwrap(ControlReply.parse(json)) else {
            return XCTFail("not action_ok")
        }
        let raw = try XCTUnwrap(json["sessions"] as? [[String: Any]])
        XCTAssertEqual(
            Set(raw[0].keys),
            [
                "session_id", "workspace_id", "display_name", "mode", "desired", "created_at",
                "running",
            ])
        XCTAssertEqual(success.sessions.count, raw.count)
        let session = try XCTUnwrap(success.sessions.first)
        XCTAssertEqual(session.sessionID.rawValue, raw[0]["session_id"] as? String)
        XCTAssertEqual(session.workspaceID.rawValue, raw[0]["workspace_id"] as? String)
        XCTAssertEqual(session.displayName, "seeded-session")
        XCTAssertEqual(session.mode, .background)
        XCTAssertEqual(session.desired, .running)
        XCTAssertTrue(session.running)
        XCTAssertEqual(session.createdAt, 1_780_000_000_000)
    }

    /// The harness's simpler `session_list` must still decode — a client that
    /// required `mode`/`desired` would fail against it.
    func testSessionListToleratesTheHarnessShape() throws {
        let harness: [String: Any] = [
            "session_id": "s-1", "workspace_id": "w-1", "display_name": "api",
            "name_rev": 1_780_000_000_000, "status": "running",
        ]
        let session = try JSONDecoder().decode(
            RemoteSession.self, from: try JSONSerialization.data(withJSONObject: harness))
        XCTAssertEqual(session.sessionID.rawValue, "s-1")
        XCTAssertEqual(session.mode, .background)
        XCTAssertEqual(session.desired, .running)
        XCTAssertFalse(session.running, "absent `running` means not-known-running")
        XCTAssertEqual(session.createdAt, 0)
    }

    /// `control_action_ok_create_session.json` and its replay.
    ///
    /// A replay carries `replayed: true` and drops every other field except
    /// `session_id` — so a client that read `display_name` off the reply gets
    /// nothing on the retry path.
    func testCreateSessionReplyAndItsIdempotentReplay() throws {
        let first = try CapturedWire.inner("control_action_ok_create_session")
        guard case .ok(let ok) = try XCTUnwrap(ControlReply.parse(first)) else {
            return XCTFail("not action_ok")
        }
        XCTAssertEqual(ok.action, "create_session")
        XCTAssertEqual(ok.session?.rawValue, first["session_id"] as? String)
        XCTAssertEqual(ok.workspace?.rawValue, first["workspace_id"] as? String)
        XCTAssertEqual(ok.displayName, "created by capture")
        XCTAssertNil(first["replayed"])
        // The gateway also returns `path`, which `ControlSuccess` does not
        // model; `MachineControlClient.ControlRPCResult` is where it lands.
        XCTAssertNotNil(first["path"] as? String)

        let replay = try CapturedWire.inner("control_action_ok_create_session_replay")
        XCTAssertEqual(replay["replayed"] as? Bool, true)
        XCTAssertNil(replay["display_name"])
        XCTAssertNil(replay["workspace_id"])
        XCTAssertEqual(replay["session_id"] as? String, first["session_id"] as? String)

        guard case .ok(let replayed) = try XCTUnwrap(ControlReply.parse(replay)) else {
            return XCTFail("not action_ok")
        }
        XCTAssertEqual(replayed.session, ok.session, "same intent, same session")
        XCTAssertNil(replayed.displayName)

        // Correlation ids differ: the replay answers a different rpc.
        XCTAssertNotEqual(replayed.inReplyTo, ok.inReplyTo)
    }

    /// The gateway refuses a mutating action with no idempotency key rather
    /// than defaulting one, and the Swift decoder refuses the same frame.
    func testMutatingActionWithoutIdempotencyKeyIsRefusedOnBothSides() throws {
        let json = try CapturedWire.inner("control_action_error_missing_key")
        guard case .error(_, let action, let message) = try XCTUnwrap(ControlReply.parse(json))
        else { return XCTFail("not action_error") }
        XCTAssertEqual(action, "create_session")
        XCTAssertEqual(message, "idempotency_key must be a non-empty string")

        var stimulus = try CapturedWire.inner("control_create_session")
        stimulus.removeValue(forKey: "idempotency_key")
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ControlAction.self,
                from: try JSONSerialization.data(withJSONObject: stimulus)),
            "the Swift decoder must refuse it too")
    }

    func testControlErrorsParse() throws {
        let json = try CapturedWire.inner("control_action_error_unknown_session")
        guard case .error(_, let action, let message) = try XCTUnwrap(ControlReply.parse(json))
        else { return XCTFail("not action_error") }
        XCTAssertEqual(action, "session_stop")
        XCTAssertTrue(message.contains("unknown session"))
    }

    /// `control_action_ok_session_rename.json` — the gateway's rename reply
    /// carries a `session_id`; the harness's chat-room reply does not. Both
    /// must parse.
    func testGatewayRenameReply() throws {
        let json = try CapturedWire.inner("control_action_ok_session_rename")
        guard case .ok(let ok) = try XCTUnwrap(ControlReply.parse(json)) else {
            return XCTFail("not action_ok")
        }
        XCTAssertEqual(ok.action, "session_rename")
        XCTAssertNotNil(ok.session)
        XCTAssertEqual(ok.displayName, "seeded, renamed")
    }

    // MARK: PeerID spelling — the four prior regressions

    /// `pairing_qr.json` records both spellings of the SAME key: url-safe and
    /// unpadded in the QR, standard and padded everywhere the relay looks.
    ///
    /// A `PeerID` sourced from the QR must serialise to the standard form.
    /// Comparing the two spellings as strings is the original bug
    /// (`app/lib/data/transport/epk_encoding.dart`).
    func testQRKeyEncodesToTheStandardWireSpelling() throws {
        let data = try Data(
            contentsOf: CapturedWire.directory.appendingPathComponent("pairing_qr.json"))
        let record = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let urlSafe = try XCTUnwrap(record["epk_url_safe"] as? String)
        let standard = try XCTUnwrap(record["peer_standard"] as? String)

        XCTAssertNotEqual(urlSafe, standard, "the capture must exercise a key that differs")
        XCTAssertFalse(urlSafe.contains("="))
        XCTAssertEqual(urlSafe.count, 43)
        XCTAssertEqual(standard.count, 44)

        let fromQR = try XCTUnwrap(PeerID(base64: urlSafe))
        let fromRelay = try XCTUnwrap(PeerID(base64: standard))
        XCTAssertEqual(fromQR, fromRelay, "same key, two spellings")
        XCTAssertEqual(fromQR.wireValue, standard)
        XCTAssertEqual(fromRelay.urlSafeValue, urlSafe)

        // Codable is asymmetric on purpose: in from either, out as standard.
        let encoded = try JSONEncoder().encode(fromQR)
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "\"\(standard)\"")

        // And the same key must survive being put into a real frame.
        let envelope = Envelope(peer: fromQR, room: .main, ct: "AAA=")
        let object = try reencoded(envelope)
        XCTAssertEqual(object["peer"] as? String, standard)
    }

    /// Every `peer` string the relay emitted in this capture is standard
    /// Base64, padded — never url-safe.
    func testEveryRelayPeerStringIsStandardBase64() throws {
        for name in [
            "room_announced", "room_ended", "peer_online", "peer_offline", "transport_error",
            "rooms_snapshot", "room_meta_updated_name",
        ] {
            let peer = try XCTUnwrap(
                CapturedWire.object(name)["peer"] as? String, "\(name) has no peer")
            XCTAssertTrue(peer.hasSuffix("="), "\(name): unpadded peer")
            XCTAssertFalse(peer.contains("-"), "\(name): url-safe peer")
            XCTAssertFalse(peer.contains("_"), "\(name): url-safe peer")
            let parsed = try XCTUnwrap(PeerID(base64: peer), "\(name): unparseable peer")
            XCTAssertEqual(parsed.wireValue, peer, "\(name): re-encoding changed the spelling")
        }
    }

    /// A key spelled with both alphabets at once is refused, matching
    /// `relay/src/identity.rs`. Built from a real captured key so the bytes are
    /// a genuine Ed25519 point rather than filler.
    func testMixedAlphabetKeyIsRefused() throws {
        // Any captured key that happens to contain both alphabet-specific
        // characters. Scanning several makes the test deterministic across
        // re-captures instead of depending on one run's random key.
        var candidates: [String] = []
        for name in [
            "room_announced", "peer_online", "peer_offline", "transport_error",
            "room_meta_updated_name", "hello_app", "hello_pi_control",
        ] {
            let json = try CapturedWire.object(name)
            candidates.append(contentsOf: [json["peer"] as? String, json["pubkey"] as? String]
                .compactMap { $0 })
        }
        guard let standard = candidates.first(where: { $0.contains("+") && $0.contains("/") })
        else {
            throw XCTSkip("no captured key in this run contains both + and /")
        }
        // `+` swapped for its url-safe twin while `/` stays standard.
        let mixed = standard.replacingOccurrences(of: "+", with: "-")
        XCTAssertNil(PeerID(base64: mixed), "a mixed-alphabet key must not parse")
        // Either pure spelling is fine.
        XCTAssertNotNil(PeerID(base64: standard))
        XCTAssertNotNil(
            PeerID(
                base64: standard
                    .replacingOccurrences(of: "+", with: "-")
                    .replacingOccurrences(of: "/", with: "_")))
    }
}
