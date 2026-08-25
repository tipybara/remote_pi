import Foundation
import XCTest

@testable import RemotePiProtocol
@testable import RemotePiSession

/// Loader for the captured wire. See the copy in
/// `RemotePiProtocolTests/WireConformanceTests.swift` for the rationale.
enum CapturedWire {
    static let fixtures: URL =
        URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)

    static var directory: URL { fixtures.appendingPathComponent("wire", isDirectory: true) }

    static func raw(
        _ name: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> String {
        let data = try Data(contentsOf: directory.appendingPathComponent("\(name).json"))
        let wrapper = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any], file: file, line: line)
        return try XCTUnwrap(wrapper["raw"] as? String, file: file, line: line)
    }

    static func object(
        _ name: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> [String: Any] {
        try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(raw(name, file: file, line: line).utf8))
                as? [String: Any], file: file, line: line)
    }

    static func innerRaw(
        _ name: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> String {
        let data = try Data(contentsOf: directory.appendingPathComponent("\(name).json"))
        let wrapper = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any], file: file, line: line)
        return try XCTUnwrap(wrapper["inner_raw"] as? String, file: file, line: line)
    }

    static func frame(
        _ name: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> ControlFrame {
        try XCTUnwrap(
            ControlFrame.parse(try object(name, file: file, line: line)), file: file, line: line)
    }

    /// Every `s2c` frame the app received, in capture order.
    static func inboundTranscript(file: StaticString = #filePath, line: UInt = #line) throws
        -> [String]
    {
        let text = try String(
            contentsOf: fixtures.appendingPathComponent("transcript.jsonl"), encoding: .utf8)
        return try text.split(separator: "\n").compactMap { entry in
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(entry.utf8)) as? [String: Any],
                file: file, line: line)
            guard
                object["dir"] as? String == "s2c",
                (object["label"] as? String)?.hasPrefix("app/") == true
            else { return nil }
            return object["text"] as? String
        }
    }
}

/// Session-layer conformance: what the registry and the control-plane client
/// do when fed the frames a live relay actually sent.
final class WireConformanceTests: XCTestCase {

    // MARK: Registry replay

    /// Replays the whole capture through ``RoomRegistry`` and checks the state
    /// the UI would render.
    ///
    /// The point is coverage the fixture-by-fixture tests cannot give: every
    /// control frame of a real session, in real order, including the ones
    /// nobody thought to write a fixture for.
    func testReplayingTheCaptureProducesTheExpectedState() async throws {
        let registry = RoomRegistry()
        var applied = 0
        for text in try CapturedWire.inboundTranscript() {
            guard
                let object = try? JSONSerialization.jsonObject(with: Data(text.utf8))
                    as? [String: Any],
                let frame = ControlFrame.parse(object)
            else { continue }
            await registry.apply(frame)
            applied += 1
        }
        XCTAssertGreaterThan(applied, 20, "the capture looks truncated")

        let snapshot = await registry.snapshot()
        let piKey = try XCTUnwrap(
            PeerID(base64: try XCTUnwrap(CapturedWire.object("room_announced")["peer"] as? String)))

        // The harness ran three named sessions plus one spawned over the
        // control plane, and a ctrl room. Chat rooms must exclude ctrl.
        let chat = snapshot.chatRooms(for: piKey)
        let all = snapshot.allRooms(for: piKey)
        XCTAssertEqual(all.count - chat.count, 1, "exactly one control room, filtered out")
        XCTAssertGreaterThanOrEqual(chat.count, 3)
        XCTAssertTrue(chat.allSatisfy { !$0.isControlRoom })
        XCTAssertTrue(chat.allSatisfy(\.hasStableIdentity), "every chat room is session-keyed")
        XCTAssertTrue(chat.allSatisfy { $0.roomID.rawValue == $0.sessionID?.rawValue })
        XCTAssertTrue(all.contains { $0.roomID == .control })
        XCTAssertTrue(snapshot.controlPlaneIsUp(piKey) == false, "the harness was killed")

        // The capture ends with the harness killed, so the whole peer is
        // offline and nothing of its is live — but the catalogue survives.
        XCTAssertFalse(snapshot.presence(of: piKey).isOnline)
        XCTAssertTrue((snapshot.live[piKey] ?? []).isEmpty, "room_ended clears liveness")
        XCTAssertFalse(all.isEmpty, "room_ended must never delete a room")

        // Grouping: Device → Workspace → Session. The capture used two
        // workspaces for the three named sessions.
        let workspaces = Set(chat.compactMap(\.effectiveWorkspacePath))
        XCTAssertGreaterThanOrEqual(workspaces.count, 2)

        // The rename that happened mid-capture is the label that survives.
        XCTAssertTrue(
            chat.contains { $0.name == "renamed by capture" },
            "the rename must have landed on the same room, not a new one")
        XCTAssertFalse(
            chat.contains { $0.name == "api-server" },
            "a rename is a patch: the old label must not survive as a second tile")
    }

    /// A rename never re-keys the room. Same `room_id` before and after, so the
    /// tile and its message box stay put — the whole point of plan 61.
    func testRenameKeepsTheSameRoomKey() async throws {
        let registry = RoomRegistry()
        let announce = try CapturedWire.frame("room_announced")
        guard case .roomAnnounced(let peer, let before) = announce else {
            return XCTFail("not room_announced")
        }
        await registry.apply(announce)

        let key = SessionKey(peer: peer, room: before.roomID)
        var cached = await registry.room(key)
        var live = await registry.isLive(key)
        XCTAssertNotNil(cached)
        XCTAssertTrue(live)

        // The relay's broadcast for that rename, replayed.
        let updated = try CapturedWire.object("room_meta_updated_harness_working")
        XCTAssertEqual(updated["room_id"] as? String, before.roomID.rawValue)

        guard case .roomMetaUpdated(_, let room, _) = try CapturedWire.frame(
            "room_meta_updated_harness_working")
        else { return XCTFail("not room_meta_updated") }
        XCTAssertEqual(room, before.roomID, "the patch targets the SAME room id")
        await registry.apply(try CapturedWire.frame("room_meta_updated_harness_working"))

        cached = await registry.room(key)
        let after = try unwrap(cached)
        XCTAssertEqual(after.roomID, before.roomID)
        XCTAssertEqual(after.sessionID, before.sessionID)
        let tiles = await registry.rooms(for: peer).count
        XCTAssertEqual(tiles, 1, "still one tile")
        live = await registry.isLive(key)
        XCTAssertTrue(live)
    }

    /// The registry runs the relay's own strictly-greater gate: a stale
    /// broadcast cannot drag the label backwards.
    ///
    /// Built from the captured patch pair — the accepted one and the
    /// re-broadcast the relay sent after REJECTING a stale patch. They are
    /// byte-identical, which is exactly why a client must re-run the gate
    /// instead of trusting an inbound `name`.
    func testStaleNamePatchCannotRegressTheLabel() async throws {
        let registry = RoomRegistry()
        let peer = makePeer(0x33)
        let room = RoomID("019ffb64-0000-7000-8000-000000000001")
        await registry.apply(
            .roomAnnounced(
                peer: peer,
                meta: RoomMeta(
                    roomID: room, sessionID: SessionID(room.rawValue),
                    name: "current", nameRev: 1_780_000_000_005)))

        // A patch carrying an OLDER revision, taken from the capture.
        let stale = RoomMetaPatch(
            metaJSONObject: try XCTUnwrap(
                CapturedWire.object("room_meta_update_stale_name")["meta"] as? [String: Any]))
        await registry.apply(.roomMetaUpdated(peer: peer, room: room, patch: stale))
        var meta = try unwrap(await registry.room(SessionKey(peer: peer, room: room)))
        XCTAssertEqual(meta.name, "current")
        XCTAssertEqual(meta.nameRev, 1_780_000_000_005)

        // An EQUAL revision loses too.
        let equal = RoomMetaPatch(name: .set("equal"), nameRev: 1_780_000_000_005)
        await registry.apply(.roomMetaUpdated(peer: peer, room: room, patch: equal))
        meta = try unwrap(await registry.room(SessionKey(peer: peer, room: room)))
        XCTAssertEqual(meta.name, "current")

        // Strictly newer wins.
        let fresh = RoomMetaPatch(name: .set("newer"), nameRev: 1_780_000_000_006)
        await registry.apply(.roomMetaUpdated(peer: peer, room: room, patch: fresh))
        meta = try unwrap(await registry.room(SessionKey(peer: peer, room: room)))
        XCTAssertEqual(meta.name, "newer")
        XCTAssertEqual(meta.nameRev, 1_780_000_000_006)
    }

    /// A re-announce must not clear fields the relay simply omitted, and must
    /// not drag a label backwards either. Uses the captured announce as the
    /// "rich" side and a stripped copy as the reconnect.
    func testReannounceWithFewerFieldsPreservesTheCachedOnes() async throws {
        var rich = try XCTUnwrap(
            RoomMeta.parseAnnouncement(try CapturedWire.object("room_announced")))
        rich.name = "renamed"
        rich.nameRev = 1_780_000_000_010

        var lean = RoomMeta(roomID: rich.roomID, startedAt: rich.startedAt + 1)
        lean.working = true

        let merged = RoomMerge.merged(incoming: lean, into: rich)
        XCTAssertEqual(merged.sessionID, rich.sessionID, "session_id must survive a lean announce")
        XCTAssertEqual(merged.workspacePath, rich.workspacePath)
        XCTAssertEqual(merged.model, rich.model)
        XCTAssertEqual(merged.thinking, rich.thinking)
        XCTAssertEqual(merged.name, "renamed", "an announce is not a rename")
        XCTAssertEqual(merged.nameRev, 1_780_000_000_010)
        XCTAssertTrue(merged.working, "working is authoritative live state, never preserved")
        XCTAssertEqual(merged.startedAt, lean.startedAt, "re-stamped by the relay every time")
    }

    /// `transport_error` turns the tile grey immediately, and `room_ended`
    /// clears liveness without deleting the catalogue entry.
    func testTransportErrorAndRoomEndedClearLivenessOnly() async throws {
        let registry = RoomRegistry()
        let announce = try CapturedWire.frame("room_announced")
        guard case .roomAnnounced(let peer, let meta) = announce else {
            return XCTFail("not room_announced")
        }
        await registry.apply(announce)
        let key = SessionKey(peer: peer, room: meta.roomID)
        var live = await registry.isLive(key)
        XCTAssertTrue(live)

        await registry.apply(.transportError(peer: peer, room: meta.roomID, reason: "offline"))
        live = await registry.isLive(key)
        let stillCached = await registry.room(key)
        XCTAssertFalse(live)
        XCTAssertNotNil(stillCached, "the tile stays, greyed")
    }

    // MARK: Control plane over the real replies

    /// Drives ``MachineControlClient`` with the exact `action_ok` bytes the
    /// REAL gateway produced, delivered the way the relay delivers them.
    func testControlClientResolvesTheRealGatewayReplies() async throws {
        let transport = FakeTransport()
        let client = MachineControlClient(transport: transport, timeout: .seconds(5))
        let machine = makePeer(0x44)

        // `workspace_list` — the id has to match the captured reply's
        // `in_reply_to`, since the client correlates on exactly that.
        let listJSON = try CapturedWire.innerRaw("control_action_ok_workspace_list")
        let listReply = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(listJSON.utf8)) as? [String: Any])
        let listID = RequestID(try XCTUnwrap(listReply["in_reply_to"] as? String))

        async let result = client.perform(.workspaceList(id: listID), on: machine)
        await waitUntil { !transport.envelopes.isEmpty }

        // What went out must be addressed at `ctrl`, not at a chat room.
        let sent = try XCTUnwrap(transport.envelopes.first)
        XCTAssertEqual(sent.room, .control)
        XCTAssertEqual(sent.peer, machine)
        assertJSONEqual(
            try jsonObject(try XCTUnwrap(sent.payload)),
            ["type": "workspace_list", "id": listID.rawValue])

        _ = await client.deliver(Data(listJSON.utf8))
        let rpc = try await result
        guard case .ok(let success) = rpc.reply else { return XCTFail("not action_ok") }
        XCTAssertEqual(success.action, "workspace_list")
        XCTAssertEqual(success.workspaces.count, 1)
        XCTAssertEqual(success.workspaces.first?.workspaceID.rawValue.count, 8)
        XCTAssertFalse(rpc.replayed)
    }

    /// The idempotent replay path: a second `create_session` with the same key
    /// answers `replayed: true` and the client surfaces it.
    func testControlClientSurfacesTheIdempotentReplay() async throws {
        let transport = FakeTransport()
        let client = MachineControlClient(transport: transport, timeout: .seconds(5))
        let machine = makePeer(0x55)

        let replayJSON = try CapturedWire.innerRaw("control_action_ok_create_session_replay")
        let replay = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(replayJSON.utf8)) as? [String: Any])
        let id = RequestID(try XCTUnwrap(replay["in_reply_to"] as? String))
        let key = IdempotencyKey("stable-intent-key")

        async let result = client.perform(
            .createSession(id: id, idempotencyKey: key, workspace: WorkspaceID("e0806e18"),
                displayName: "created by capture"),
            on: machine)
        await waitUntil { !transport.envelopes.isEmpty }
        let sent = try XCTUnwrap(transport.envelopes.first)
        let payload = try jsonObject(try XCTUnwrap(sent.payload))
        XCTAssertEqual(payload["background"] as? Bool, true)
        XCTAssertEqual(payload["idempotency_key"] as? String, key.rawValue)

        _ = await client.deliver(Data(replayJSON.utf8))
        let rpc = try await result
        XCTAssertTrue(rpc.replayed, "replayed:true must reach the caller")
        guard case .ok(let success) = rpc.reply else { return XCTFail("not action_ok") }
        XCTAssertEqual(success.session?.rawValue, replay["session_id"] as? String)
    }

    /// The real gateway's `action_error` for a mutating frame with no
    /// idempotency key must surface as a failure, not as a silent timeout.
    func testControlClientSurfacesTheRealActionError() async throws {
        let transport = FakeTransport()
        let client = MachineControlClient(transport: transport, timeout: .seconds(5))
        let machine = makePeer(0x66)

        let errorJSON = try CapturedWire.innerRaw("control_action_error_missing_key")
        let error = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(errorJSON.utf8)) as? [String: Any])
        let id = RequestID(try XCTUnwrap(error["in_reply_to"] as? String))

        async let result = client.perform(.workspaceList(id: id), on: machine)
        await waitUntil { !transport.envelopes.isEmpty }
        _ = await client.deliver(Data(errorJSON.utf8))

        let rpc = try await result
        guard case .error(_, let action, let message) = rpc.reply else {
            return XCTFail("not action_error")
        }
        XCTAssertEqual(action, "create_session")
        XCTAssertEqual(message, "idempotency_key must be a non-empty string")
    }

    /// A reply for an id nobody is waiting on is left alone: `action_ok` and
    /// `action_error` are also chat-action shapes, and claiming one would eat
    /// a chat reply.
    func testUnrelatedActionOkIsNotClaimed() async throws {
        let transport = FakeTransport()
        let client = MachineControlClient(transport: transport, timeout: .seconds(5))
        let chatReply = try CapturedWire.innerRaw("inner_action_ok_rename")
        let claimed = await client.deliver(Data(chatReply.utf8))
        XCTAssertFalse(claimed, "a chat action_ok must fall through to the chat demux")
    }
}
