import Foundation
import XCTest

@testable import RemotePiProtocol
@testable import RemotePiSession

/// The machine control plane. Outbound frames are asserted against the exact
/// JSON `pi-extension/src/daemon/gateway.test.ts` and
/// `app/test/data/control/machine_control_test.dart` exercise; inbound replies
/// are the exact objects `pi-extension/src/protocol/control_wire.ts`'s
/// `actionOk` / `actionError` produce.
final class MachineControlTests: XCTestCase {
    private let workspace = WorkspaceID("a1b2c3d4")

    // MARK: - Outbound frames

    /// Pinned against `machine_control_test.dart`
    /// ("create_session sends the caller-supplied idempotency key VERBATIM"):
    /// `type`, `idempotency_key`, `workspace_id`, `display_name`,
    /// `background: true`, and **no** way to smuggle a path.
    func testCreateSessionFrameBytes() throws {
        let action = ControlAction.createSession(
            id: RequestID("ctl_1"),
            idempotencyKey: IdempotencyKey("stable-key"),
            workspace: WorkspaceID("w1"),
            displayName: "Nightly"
        )
        let frame = try jsonObject(action.encoded())
        assertJSONEqual(
            frame,
            [
                "type": "create_session",
                "id": "ctl_1",
                "idempotency_key": "stable-key",
                "workspace_id": "w1",
                "display_name": "Nightly",
                "background": true,
            ]
        )
        // Rule 1 of this plane: no paths on the wire. A path plus the daemon's
        // `--approve` would be user-level RCE.
        XCTAssertNil(frame["cwd"])
        XCTAssertNil(frame["path"])
    }

    /// `background` is written as the JSON literal `true` and nothing else:
    /// `false`, `0` and `"true"` all produce
    /// `action_error "only background sessions can be created remotely"`
    /// (spec 09 T11). Omitting `display_name` must omit the key, not send null —
    /// the gateway trims strings and treats empty as absent, but a `null` there
    /// is a different code path.
    func testCreateSessionWithoutDisplayName() throws {
        let action = ControlAction.createSession(
            id: RequestID("ctl_1"),
            idempotencyKey: IdempotencyKey("k"),
            workspace: workspace,
            displayName: nil
        )
        let frame = try jsonObject(action.encoded())
        XCTAssertFalse(frame.keys.contains("display_name"))
        XCTAssertEqual(frame["background"] as? Bool, true)
    }

    /// Pinned against `gateway.test.ts` ("workspace_list returns the registered
    /// folders"): the read-only actions carry `type` + `id` and no key.
    func testWorkspaceListFrameBytes() throws {
        let frame = try jsonObject(ControlAction.workspaceList(id: RequestID("r1")).encoded())
        assertJSONEqual(frame, ["type": "workspace_list", "id": "r1"])
    }

    /// An absent `workspace_id` means "all sessions". Sending `""` would read
    /// as a filter for a workspace named "" — hence omission, not empty string.
    func testSessionListFilterIsOmittedWhenAbsent() throws {
        let unfiltered = try jsonObject(
            ControlAction.sessionList(id: RequestID("r1"), workspace: nil).encoded()
        )
        assertJSONEqual(unfiltered, ["type": "session_list", "id": "r1"])

        let filtered = try jsonObject(
            ControlAction.sessionList(id: RequestID("r1"), workspace: workspace).encoded()
        )
        assertJSONEqual(
            filtered,
            ["type": "session_list", "id": "r1", "workspace_id": "a1b2c3d4"]
        )
    }

    /// Pinned against `gateway.test.ts` ("session_stop persists the intent…" /
    /// "session_start flips the intent back to running").
    func testSessionStartAndStopFrameBytes() throws {
        let start = try jsonObject(
            ControlAction.sessionStart(
                id: RequestID("r1"),
                session: SessionID("8b4f9c2e"),
                idempotencyKey: IdempotencyKey("k-start")
            ).encoded()
        )
        assertJSONEqual(
            start,
            [
                "type": "session_start", "id": "r1",
                "session_id": "8b4f9c2e", "idempotency_key": "k-start",
            ]
        )

        let stop = try jsonObject(
            ControlAction.sessionStop(
                id: RequestID("r1"),
                session: SessionID("8b4f9c2e"),
                idempotencyKey: IdempotencyKey("k-stop")
            ).encoded()
        )
        assertJSONEqual(
            stop,
            [
                "type": "session_stop", "id": "r1",
                "session_id": "8b4f9c2e", "idempotency_key": "k-stop",
            ]
        )
    }

    /// `session_rename` is **not** in the gateway's `MUTATING` set: it neither
    /// requires nor consults an idempotency key. Sending one would be ignored,
    /// but writing one here would invite a caller to reuse a create key and
    /// burn it for 24 h.
    func testSessionRenameCarriesRevAndNoIdempotencyKey() throws {
        let frame = try jsonObject(
            ControlAction.sessionRename(
                id: RequestID("r1"),
                session: SessionID("8b4f9c2e"),
                displayName: "backend",
                rev: 1_780_000_000_001
            ).encoded()
        )
        assertJSONEqual(
            frame,
            [
                "type": "session_rename", "id": "r1",
                "session_id": "8b4f9c2e", "display_name": "backend",
                "rev": 1_780_000_000_001,
            ]
        )
        XCTAssertNil(frame["idempotency_key"])
    }

    /// The rpc id must be opaque and whitespace-free: the gateway echoes the
    /// **trimmed** id on the normal path but the **raw** id on the parse-error
    /// path, so an id with whitespace correlates on exactly one branch
    /// (spec 09 T9).
    func testMintedRequestIDsArePrefixedAndWhitespaceFree() {
        let id = ControlRequestID.mint().rawValue
        XCTAssertTrue(id.hasPrefix("ctl_"))
        XCTAssertEqual(id, id.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertNotEqual(id, ControlRequestID.mint().rawValue)
    }

    // MARK: - Envelope addressing

    /// The frame must ride an envelope addressed at `room: "ctrl"` with the
    /// machine's key in **standard Base64 with padding** — the relay's registry
    /// is a raw string map, so a url-safe key from a QR payload misses and
    /// comes back `transport_error: offline` (spec 09 T2). `ct` is standard
    /// Base64 of plaintext JSON, which is what Node's
    /// `Buffer.from(ct, "base64")` reads.
    func testControlActionIsAddressedAtTheCtrlRoomWithAStandardBase64Peer() async throws {
        let transport = FakeTransport()
        let client = MachineControlClient(transport: transport, timeout: .milliseconds(50))

        _ = try? await client.perform(
            .workspaceList(id: RequestID("ctl_1")),
            on: machineKey
        )

        let envelope = try XCTUnwrap(transport.envelopes.first)
        XCTAssertEqual(envelope.room, .control)
        XCTAssertEqual(envelope.peer, machineKey)
        XCTAssertEqual(envelope.ct, envelope.ct.filter { !"-_".contains($0) })
        let inner = try jsonObject(try XCTUnwrap(Data(base64Encoded: envelope.ct)))
        assertJSONEqual(inner, ["type": "workspace_list", "id": "ctl_1"])
    }

    // MARK: - Replies

    /// Pinned against `gateway.test.ts` ("workspace_list returns the registered
    /// folders") and spec 09 §4.1. The whole `action_ok` object *is* the
    /// payload — there is no `data` wrapper.
    func testWorkspaceListReply() async throws {
        let transport = FakeTransport()
        let client = MachineControlClient(transport: transport, timeout: .seconds(5))

        async let pending = client.listWorkspaces(on: machineKey)
        await waitUntil { transport.envelopes.count == 1 }
        let sent = try jsonObject(try XCTUnwrap(Data(base64Encoded: transport.envelopes[0].ct)))
        let rpcID = try XCTUnwrap(sent["id"] as? String)

        let claimed = await client.deliver(
            Data(
                """
                { "type": "action_ok",
                  "in_reply_to": "\(rpcID)",
                  "action": "workspace_list",
                  "workspaces": [
                    { "workspace_id": "a1b2c3d4", "path": "/Users/x/proj",
                      "display_name": "proj" } ] }
                """.utf8
            )
        )
        XCTAssertTrue(claimed)

        let workspaces = try await pending
        XCTAssertEqual(workspaces.count, 1)
        XCTAssertEqual(workspaces[0].workspaceID, WorkspaceID("a1b2c3d4"))
        XCTAssertEqual(workspaces[0].path, "/Users/x/proj")
        XCTAssertEqual(workspaces[0].displayName, "proj")
    }

    /// Pinned against spec 09 §4.2 and `gateway.test.ts`
    /// ("session_list reports live state alongside the catalogue").
    func testSessionListReply() async throws {
        let transport = FakeTransport()
        let client = MachineControlClient(transport: transport, timeout: .seconds(5))

        async let pending = client.listSessions(on: machineKey)
        await waitUntil { transport.envelopes.count == 1 }
        let sent = try jsonObject(try XCTUnwrap(Data(base64Encoded: transport.envelopes[0].ct)))
        let rpcID = try XCTUnwrap(sent["id"] as? String)

        _ = await client.deliver(
            Data(
                """
                { "type": "action_ok", "in_reply_to": "\(rpcID)", "action": "session_list",
                  "sessions": [
                    { "session_id": "3f1c-uuid", "workspace_id": "a1b2c3d4",
                      "display_name": "proj", "mode": "background",
                      "desired": "running", "created_at": 1780000000000,
                      "running": true } ] }
                """.utf8
            )
        )

        let sessions = try await pending
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].sessionID, SessionID("3f1c-uuid"))
        XCTAssertEqual(sessions[0].mode, .background)
        XCTAssertEqual(sessions[0].desired, .running)
        XCTAssertEqual(sessions[0].createdAt, 1_780_000_000_000)
        // `running` is a per-WORKSPACE fact (one daemon per cwd), not
        // per-session liveness. The authoritative per-session signal is the
        // relay's live-room set.
        XCTAssertTrue(sessions[0].running)
    }

    /// A reply is correlated purely by `in_reply_to`, never by the room it
    /// arrived on. The gateway hardcodes `room: "ctrl"` while the relay routes
    /// on an exact `(peer, room)` registration, so a machine that is later
    /// fixed to omit `room` lands on `"main"` — both must work (spec 09 T1).
    func testReplyIsClaimedRegardlessOfSourceRoom() async throws {
        let transport = FakeTransport()
        let store = FakeStore()
        let coordinator = SessionCoordinator(
            transport: transport,
            store: store,
            controlTimeout: .seconds(5)
        )
        try await coordinator.start(watching: [machineKey])

        async let pending = coordinator.listWorkspaces(on: machineKey)
        await waitUntil { transport.envelopes.count == 1 }
        let sent = try jsonObject(try XCTUnwrap(Data(base64Encoded: transport.envelopes[0].ct)))
        let rpcID = try XCTUnwrap(sent["id"] as? String)

        transport.deliverInner(
            from: machineKey,
            room: .main,  // the "fixed gateway" spelling
            json: """
                { "type": "action_ok", "in_reply_to": "\(rpcID)",
                  "action": "workspace_list", "workspaces": [] }
                """
        )

        let workspaces = try await pending
        XCTAssertTrue(workspaces.isEmpty, "an empty list is a legitimate answer, not an error")
        await coordinator.stop()
    }

    /// Pinned against `gateway.test.ts`
    /// ("create_session refuses a workspace that is not registered").
    func testActionErrorSurfacesTheMachinesReason() async throws {
        let transport = FakeTransport()
        let client = MachineControlClient(transport: transport, timeout: .seconds(5))

        let action = ControlAction.createSession(
            id: ControlRequestID.mint(),
            idempotencyKey: IdempotencyKey("k"),
            workspace: WorkspaceID("nope"),
            displayName: nil
        )
        async let pending = client.perform(action, on: machineKey)
        await waitUntil { transport.envelopes.count == 1 }

        _ = await client.deliver(
            Data(
                """
                { "type": "action_error", "in_reply_to": "\(action.id.rawValue)",
                  "action": "create_session", "error": "unknown workspace: nope" }
                """.utf8
            )
        )

        let result = try await pending
        guard case .error(_, let name, let message) = result.reply else {
            return XCTFail("expected action_error")
        }
        XCTAssertEqual(name, "create_session")
        XCTAssertEqual(message, "unknown workspace: nope")
    }

    /// T4 — pinned against `gateway.test.ts` ("replaying the SAME idempotency
    /// key does not spawn twice"), whose second reply is exactly
    /// `{type, in_reply_to, action, session_id, replayed: true}`. A decoder
    /// that requires `workspace_id` or `path` throws on precisely the retry
    /// path it exists to support.
    func testReplayedCreateReplyIsASmallerObject() async throws {
        let transport = FakeTransport()
        let client = MachineControlClient(transport: transport, timeout: .seconds(5))

        let action = ControlAction.createSession(
            id: ControlRequestID.mint(),
            idempotencyKey: IdempotencyKey("key-dup"),
            workspace: workspace,
            displayName: nil
        )
        async let pending = client.perform(action, on: machineKey)
        await waitUntil { transport.envelopes.count == 1 }

        _ = await client.deliver(
            Data(
                """
                { "type": "action_ok", "in_reply_to": "\(action.id.rawValue)",
                  "action": "create_session",
                  "session_id": "8b4f9c2e-uuid", "replayed": true }
                """.utf8
            )
        )

        let result = try await pending
        XCTAssertTrue(result.replayed)
        XCTAssertNil(result.path)
        guard case .ok(let success) = result.reply else { return XCTFail("expected action_ok") }
        XCTAssertEqual(success.session, SessionID("8b4f9c2e-uuid"))
        XCTAssertNil(success.workspace)
    }

    /// The first execution carries the fuller payload, `path` included.
    func testFirstCreateReplyCarriesPathAndWorkspace() async throws {
        let transport = FakeTransport()
        let client = MachineControlClient(transport: transport, timeout: .seconds(5))

        let action = ControlAction.createSession(
            id: ControlRequestID.mint(),
            idempotencyKey: IdempotencyKey("key-1"),
            workspace: workspace,
            displayName: "backend"
        )
        async let pending = client.perform(action, on: machineKey)
        await waitUntil { transport.envelopes.count == 1 }

        _ = await client.deliver(
            Data(
                """
                { "type": "action_ok", "in_reply_to": "\(action.id.rawValue)",
                  "action": "create_session",
                  "session_id": "8b4f9c2e-uuid", "workspace_id": "a1b2c3d4",
                  "display_name": "backend", "path": "/Users/x/proj" }
                """.utf8
            )
        )

        let result = try await pending
        XCTAssertFalse(result.replayed)
        XCTAssertEqual(result.path, "/Users/x/proj")
        guard case .ok(let success) = result.reply else { return XCTFail("expected action_ok") }
        XCTAssertEqual(success.workspace, workspace)
        XCTAssertEqual(success.displayName, "backend")
    }

    /// A frame whose `in_reply_to` is not ours belongs to the chat plane, which
    /// uses the same two shapes on the same socket.
    func testForeignReplyIsNotClaimed() async {
        let transport = FakeTransport()
        let client = MachineControlClient(transport: transport, timeout: .seconds(5))
        let claimed = await client.deliver(
            Data(
                """
                { "type": "action_ok", "in_reply_to": "someone-elses", "action": "thinking_set" }
                """.utf8
            )
        )
        XCTAssertFalse(claimed)
    }

    // MARK: - Failure modes

    func testUnansweredRPCTimesOut() async {
        let transport = FakeTransport()
        let client = MachineControlClient(transport: transport, timeout: .milliseconds(40))
        do {
            _ = try await client.perform(.workspaceList(id: ControlRequestID.mint()), on: machineKey)
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? ControlPlaneError, .timeout)
        }
    }

    /// T6 — `transport_error` for `(machine, "ctrl")` says the gateway is not
    /// registered. Failing now beats hanging for the whole 45 s budget, which
    /// is what the Flutter control repository does.
    func testTransportErrorOnCtrlFailsPendingRPCsImmediately() async throws {
        let transport = FakeTransport()
        let store = FakeStore()
        let coordinator = SessionCoordinator(
            transport: transport,
            store: store,
            // Long enough that a hang would fail the test by timing out the
            // XCTest run rather than by resolving.
            controlTimeout: .seconds(30)
        )
        try await coordinator.start(watching: [machineKey])

        let action = ControlAction.workspaceList(id: ControlRequestID.mint())
        async let pending: ControlReply = coordinator.perform(action, on: machineKey)
        await waitUntil { transport.envelopes.count == 1 }

        let frame = try controlFrame(
            """
            { "type": "transport_error", "reason": "offline",
              "peer": "\(machineKey.wireValue)", "room_id": "ctrl" }
            """
        )
        transport.emit(.control(frame))

        do {
            _ = try await pending
            XCTFail("expected the RPC to fail")
        } catch {
            XCTAssertEqual(
                error as? ControlPlaneError,
                .gatewayUnreachable(reason: "offline")
            )
        }
        await coordinator.stop()
    }

    /// Losing the socket must fail everything in flight — a silent hang is the
    /// worse failure.
    func testDisconnectFailsEverythingInFlight() async throws {
        let transport = FakeTransport()
        let store = FakeStore()
        let coordinator = SessionCoordinator(
            transport: transport,
            store: store,
            controlTimeout: .seconds(30)
        )
        try await coordinator.start(watching: [machineKey])

        async let pending: ControlReply = coordinator.perform(
            .workspaceList(id: ControlRequestID.mint()),
            on: machineKey
        )
        await waitUntil { transport.envelopes.count == 1 }
        transport.emit(.disconnected(error: nil))

        do {
            _ = try await pending
            XCTFail("expected the RPC to fail")
        } catch {
            XCTAssertEqual(error as? ControlPlaneError, .offline)
        }
        await coordinator.stop()
    }

    // MARK: - The two-step create

    /// Spec 09 §6 — `action_ok` means "spawn requested", not "the room is up".
    /// The session id comes from the machine; the room is *observed*.
    func testCreateSessionWaitsForRoomAnnounced() async throws {
        let transport = FakeTransport()
        let coordinator = SessionCoordinator(
            transport: transport,
            store: FakeStore(),
            controlTimeout: .seconds(5),
            roomWaitBudget: .seconds(5)
        )
        try await coordinator.start(watching: [machineKey])

        let intent = CreateSessionIntent(
            machine: machineKey,
            workspace: workspace,
            displayName: "backend"
        )
        async let outcome = coordinator.createSession(intent)
        await waitUntil { transport.envelopes.count == 1 }

        let sent = try jsonObject(try XCTUnwrap(Data(base64Encoded: transport.envelopes[0].ct)))
        let rpcID = try XCTUnwrap(sent["id"] as? String)
        XCTAssertEqual(sent["idempotency_key"] as? String, intent.idempotencyKey.rawValue)

        transport.deliverInner(
            from: machineKey,
            room: .control,
            json: """
                { "type": "action_ok", "in_reply_to": "\(rpcID)", "action": "create_session",
                  "session_id": "8b4f9c2e-uuid", "workspace_id": "a1b2c3d4",
                  "display_name": "backend", "path": "/Users/x/proj" }
                """
        )

        // The room only exists once the forked `pi` boots its extension and
        // says hello. Until then the create is accepted but not open-able.
        try await Task.sleep(for: .milliseconds(30))
        transport.emit(
            .control(
                try controlFrame(
                    """
                    { "type": "room_announced", "peer": "\(machineKey.wireValue)",
                      "room_id": "8b4f9c2e-uuid", "session_id": "8b4f9c2e-uuid",
                      "workspace_path": "/Users/x/proj", "name": "backend",
                      "working": false, "started_at": 1780000000456 }
                    """
                )
            )
        )

        let result = try await outcome
        XCTAssertEqual(result, .online(SessionID("8b4f9c2e-uuid")))
        await coordinator.stop()
    }

    /// A room that never comes up is "created, not online yet" — **not**
    /// failed. Never delete the session, and do not retry with a new key: a
    /// second `create_session` in a workspace whose daemon is already up mints
    /// a catalogue entry whose room will never appear (spec 09 T5).
    func testCreateSessionReportsAcceptedWhenTheRoomNeverComesUp() async throws {
        let transport = FakeTransport()
        let coordinator = SessionCoordinator(
            transport: transport,
            store: FakeStore(),
            controlTimeout: .seconds(5),
            roomWaitBudget: .milliseconds(40)
        )
        try await coordinator.start(watching: [machineKey])

        let intent = CreateSessionIntent(machine: machineKey, workspace: workspace)
        async let outcome = coordinator.createSession(intent)
        await waitUntil { transport.envelopes.count == 1 }
        let sent = try jsonObject(try XCTUnwrap(Data(base64Encoded: transport.envelopes[0].ct)))
        let rpcID = try XCTUnwrap(sent["id"] as? String)

        transport.deliverInner(
            from: machineKey,
            room: .control,
            json: """
                { "type": "action_ok", "in_reply_to": "\(rpcID)", "action": "create_session",
                  "session_id": "never-boots" }
                """
        )

        let result = try await outcome
        XCTAssertEqual(result, .acceptedNotYetOnline(SessionID("never-boots")))
        await coordinator.stop()
    }

    /// An `action_error` is a failure with the machine's own words, and the
    /// room wait must not even start.
    func testCreateSessionFailsOnActionError() async throws {
        let transport = FakeTransport()
        let coordinator = SessionCoordinator(
            transport: transport,
            store: FakeStore(),
            controlTimeout: .seconds(5),
            // Long: if this budget were consulted the test would hang, proving
            // the error path short-circuits it.
            roomWaitBudget: .seconds(30)
        )
        try await coordinator.start(watching: [machineKey])

        async let outcome = coordinator.createSession(
            CreateSessionIntent(machine: machineKey, workspace: WorkspaceID("nope"))
        )
        await waitUntil { transport.envelopes.count == 1 }
        let sent = try jsonObject(try XCTUnwrap(Data(base64Encoded: transport.envelopes[0].ct)))
        let rpcID = try XCTUnwrap(sent["id"] as? String)

        transport.deliverInner(
            from: machineKey,
            room: .control,
            json: """
                { "type": "action_error", "in_reply_to": "\(rpcID)", "action": "create_session",
                  "error": "unknown workspace: nope" }
                """
        )

        let result = try await outcome
        XCTAssertEqual(result, .failed(message: "unknown workspace: nope"))
        await coordinator.stop()
    }

    /// The intent owns the key: two attempts of the same intent send the same
    /// `idempotency_key` with different rpc ids. Re-minting per attempt is what
    /// gets you a process per attempt.
    func testRetryingAnIntentReusesTheIdempotencyKey() async throws {
        let transport = FakeTransport()
        let coordinator = SessionCoordinator(
            transport: transport,
            store: FakeStore(),
            controlTimeout: .milliseconds(40),
            roomWaitBudget: .milliseconds(10)
        )
        try await coordinator.start(watching: [machineKey])

        let intent = CreateSessionIntent(machine: machineKey, workspace: workspace)
        _ = try? await coordinator.createSession(intent)  // times out, unanswered
        _ = try? await coordinator.createSession(intent)  // the retry

        XCTAssertEqual(transport.envelopes.count, 2)
        let first = try jsonObject(try XCTUnwrap(Data(base64Encoded: transport.envelopes[0].ct)))
        let second = try jsonObject(try XCTUnwrap(Data(base64Encoded: transport.envelopes[1].ct)))
        XCTAssertEqual(
            first["idempotency_key"] as? String,
            second["idempotency_key"] as? String
        )
        XCTAssertNotEqual(first["id"] as? String, second["id"] as? String)
        await coordinator.stop()
    }

    /// Two *different* intents must never share a key: the machine's ledger is
    /// flat across action types, so a shared key replays the first outcome.
    func testDistinctIntentsMintDistinctKeys() {
        let a = CreateSessionIntent(machine: machineKey, workspace: workspace)
        let b = CreateSessionIntent(machine: machineKey, workspace: workspace)
        XCTAssertNotEqual(a.idempotencyKey, b.idempotencyKey)
        // And the key is a nonce, not a value: nothing about the intent is
        // recoverable from it.
        XCTAssertFalse(a.idempotencyKey.rawValue.contains(workspace.rawValue))
    }
}
