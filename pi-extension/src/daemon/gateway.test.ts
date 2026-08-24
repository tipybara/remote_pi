import { EventEmitter } from "node:events";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";

// ── mocks ───────────────────────────────────────────────────────────────────
//
// The gateway authenticates with the MACHINE's Ed25519 key and reads the Owner
// allow-list from the same storage the chat sessions use. Both are keyring /
// filesystem bound, so they are stubbed here; what matters for these tests is
// the authorization decision, not how the key is stored.

const owners: string[] = [];

vi.mock("../pairing/storage.js", () => ({
  getOrCreateEd25519Keypair: async () => ({
    publicKey: new Uint8Array(32),
    secretKey: new Uint8Array(64),
  }),
  listPeers: async () => owners.map((remote_epk) => ({ remote_epk, name: "phone", paired_at: "" })),
  conditionalRemovePeer: async () => ({ removed: false }),
  snapshotOwnerPubkeys: async () => [],
}));

const { Gateway } = await import("./gateway.js");
const { CONTROL_ROOM_ID, CONTROL_ROOM_ROLE } = await import("../protocol/control_wire.js");
const { addDaemon } = await import("./registry.js");
const { createSession, findSession, listSessions } = await import("./sessions.js");

// ── fake relay ──────────────────────────────────────────────────────────────

class FakeRelay extends EventEmitter {
  connectOpts: unknown = null;
  readonly sent: string[] = [];
  closed = false;

  async connect(opts?: unknown): Promise<void> {
    this.connectOpts = opts;
  }

  send(line: string): void {
    this.sent.push(line);
  }

  close(): void {
    this.closed = true;
  }

  /** Deliver an inner frame as if it arrived from `peer` through the relay. */
  deliver(peer: string, inner: unknown): void {
    this.emit(
      "message",
      JSON.stringify({
        peer,
        room: CONTROL_ROOM_ID,
        ct: Buffer.from(JSON.stringify(inner)).toString("base64"),
      }),
    );
  }

  /** Decoded replies, newest last. */
  replies(): Array<Record<string, unknown>> {
    return this.sent.map((line) => {
      const outer = JSON.parse(line) as { ct: string };
      return JSON.parse(Buffer.from(outer.ct, "base64").toString("utf8")) as Record<string, unknown>;
    });
  }
}

// ── host stub ───────────────────────────────────────────────────────────────

function makeHost() {
  const started: Array<{ workspaceId: string; sessionId: string }> = [];
  const stopped: string[] = [];
  const running = new Set<string>();
  let failNext: string | null = null;
  return {
    started,
    stopped,
    running,
    failWith(msg: string) { failNext = msg; },
    host: {
      startWorkspace: async (workspaceId: string, sessionId: string) => {
        if (failNext) { const m = failNext; failNext = null; throw new Error(m); }
        started.push({ workspaceId, sessionId });
        running.add(workspaceId);
      },
      stopWorkspace: async (workspaceId: string) => {
        stopped.push(workspaceId);
        running.delete(workspaceId);
      },
      isWorkspaceRunning: (workspaceId: string) => running.has(workspaceId),
    },
  };
}

const OWNER = "owner-epk-1";
let home: string;
const savedHome = process.env["REMOTE_PI_HOME"];
let relay: FakeRelay;
let clock = 1_000;

async function startGateway(hostBundle: ReturnType<typeof makeHost>) {
  relay = new FakeRelay();
  const gw = new Gateway({
    host: hostBundle.host,
    relayFactory: () => relay as never,
    now: () => clock,
    selfRevoke: false,
  });
  await gw.start();
  return gw;
}

function registerWorkspace(): { id: string; cwd: string } {
  const dir = mkdtempSync(join(tmpdir(), "gw-ws-"));
  const { id, cwd } = addDaemon(dir);
  return { id, cwd };
}

beforeEach(() => {
  home = mkdtempSync(join(tmpdir(), "pi-gw-"));
  process.env["REMOTE_PI_HOME"] = home;
  owners.length = 0;
  owners.push(OWNER);
  clock = 1_000;
});

afterEach(() => {
  if (savedHome === undefined) delete process.env["REMOTE_PI_HOME"];
  else process.env["REMOTE_PI_HOME"] = savedHome;
});

describe("Gateway — plan 61 Phase 3", () => {
  test("opens the reserved control room and marks it as NOT a chat", async () => {
    const h = makeHost();
    const gw = await startGateway(h);

    const opts = relay.connectOpts as { roomId: string; roomMeta: Record<string, unknown> };
    expect(opts.roomId).toBe(CONTROL_ROOM_ID);
    // Without `role`, the app would render the gateway as a session tile that
    // answers nothing.
    expect(opts.roomMeta["role"]).toBe(CONTROL_ROOM_ROLE);

    await gw.stop();
    expect(relay.closed).toBe(true);
  });

  test("a frame from a NON-Owner peer is dropped, with no reply at all", async () => {
    // Silence is deliberate: replying would confirm the machine exists to an
    // unpaired sender.
    const h = makeHost();
    const gw = await startGateway(h);

    relay.deliver("stranger", { type: "workspace_list", id: "r1" });
    await Promise.resolve();

    expect(relay.replies()).toEqual([]);
    await gw.stop();
  });

  test("a revoked Owner loses access — the allow-list is re-read, not cached forever", async () => {
    const h = makeHost();
    const gw = await startGateway(h);

    relay.deliver(OWNER, { type: "workspace_list", id: "r1" });
    await vi.waitFor(() => expect(relay.replies()).toHaveLength(1));

    // Revoke: the peer disappears from storage.
    owners.length = 0;
    await gw.refreshOwners();
    relay.deliver(OWNER, { type: "workspace_list", id: "r2" });
    await Promise.resolve();
    await Promise.resolve();

    expect(relay.replies()).toHaveLength(1);
    await gw.stop();
  });

  test("workspace_list returns the registered folders", async () => {
    const ws = registerWorkspace();
    const h = makeHost();
    const gw = await startGateway(h);

    relay.deliver(OWNER, { type: "workspace_list", id: "r1" });
    await vi.waitFor(() => expect(relay.replies()).toHaveLength(1));

    const reply = relay.replies()[0]!;
    expect(reply["type"]).toBe("action_ok");
    expect(reply["in_reply_to"]).toBe("r1");
    expect(reply["workspaces"]).toEqual([
      expect.objectContaining({ workspace_id: ws.id, path: ws.cwd }),
    ]);
    await gw.stop();
  });

  test("create_session mints a session and starts its workspace", async () => {
    const ws = registerWorkspace();
    const h = makeHost();
    const gw = await startGateway(h);

    relay.deliver(OWNER, {
      type: "create_session",
      id: "r1",
      idempotency_key: "key-1",
      workspace_id: ws.id,
      display_name: "Nightly",
    });
    await vi.waitFor(() => expect(relay.replies()).toHaveLength(1));

    const reply = relay.replies()[0]!;
    expect(reply["type"]).toBe("action_ok");
    const sessionId = reply["session_id"] as string;
    expect(sessionId).toBeTruthy();
    expect(reply["path"]).toBe(ws.cwd);

    // The child adopts the id the machine minted, so `room_id == session_id`
    // holds for a session the phone created before any process existed.
    expect(h.started).toEqual([{ workspaceId: ws.id, sessionId }]);
    expect(findSession(sessionId)?.display_name).toBe("Nightly");

    await gw.stop();
  });

  test("replaying the SAME idempotency key does not spawn twice", async () => {
    const ws = registerWorkspace();
    const h = makeHost();
    const gw = await startGateway(h);

    const frame = {
      type: "create_session",
      id: "r1",
      idempotency_key: "key-dup",
      workspace_id: ws.id,
    };
    relay.deliver(OWNER, frame);
    await vi.waitFor(() => expect(relay.replies()).toHaveLength(1));
    const first = relay.replies()[0]!["session_id"];

    // Same key, new rpc id — the phone retrying after a dropped reply.
    relay.deliver(OWNER, { ...frame, id: "r2" });
    await vi.waitFor(() => expect(relay.replies()).toHaveLength(2));

    expect(h.started).toHaveLength(1);
    expect(listSessions()).toHaveLength(1);
    const replay = relay.replies()[1]!;
    expect(replay["type"]).toBe("action_ok");
    expect(replay["session_id"]).toBe(first);
    expect(replay["replayed"]).toBe(true);

    await gw.stop();
  });

  test("a FAILED create is remembered — retrying the key replays the error", async () => {
    const h = makeHost();
    const gw = await startGateway(h);

    const frame = {
      type: "create_session",
      id: "r1",
      idempotency_key: "key-bad",
      workspace_id: "not-registered",
    };
    relay.deliver(OWNER, frame);
    await vi.waitFor(() => expect(relay.replies()).toHaveLength(1));
    expect(relay.replies()[0]!["type"]).toBe("action_error");

    relay.deliver(OWNER, { ...frame, id: "r2" });
    await vi.waitFor(() => expect(relay.replies()).toHaveLength(2));
    expect(relay.replies()[1]!["type"]).toBe("action_error");
    expect(h.started).toHaveLength(0);

    await gw.stop();
  });

  test("create_session refuses a workspace that is not registered", async () => {
    const h = makeHost();
    const gw = await startGateway(h);

    relay.deliver(OWNER, {
      type: "create_session", id: "r1", idempotency_key: "k", workspace_id: "/etc",
    });
    await vi.waitFor(() => expect(relay.replies()).toHaveLength(1));

    expect(relay.replies()[0]).toMatchObject({
      type: "action_error",
      action: "create_session",
    });
    expect(h.started).toHaveLength(0);
    await gw.stop();
  });

  test("session_stop persists the intent so a restart cannot resurrect it", async () => {
    const ws = registerWorkspace();
    const h = makeHost();
    const gw = await startGateway(h);
    const session = createSession({ workspaceId: ws.id, now: clock });
    h.running.add(ws.id);

    relay.deliver(OWNER, {
      type: "session_stop", id: "r1", session_id: session.session_id, idempotency_key: "k-stop",
    });
    await vi.waitFor(() => expect(relay.replies()).toHaveLength(1));

    expect(relay.replies()[0]!["type"]).toBe("action_ok");
    expect(h.stopped).toEqual([ws.id]);
    expect(findSession(session.session_id)?.desired).toBe("stopped");

    await gw.stop();
  });

  test("session_start flips the intent back to running", async () => {
    const ws = registerWorkspace();
    const h = makeHost();
    const gw = await startGateway(h);
    const session = createSession({ workspaceId: ws.id, now: clock });

    relay.deliver(OWNER, {
      type: "session_start", id: "r1", session_id: session.session_id, idempotency_key: "k-start",
    });
    await vi.waitFor(() => expect(relay.replies()).toHaveLength(1));

    expect(h.started).toEqual([
      { workspaceId: ws.id, sessionId: session.session_id },
    ]);
    expect(findSession(session.session_id)?.desired).toBe("running");
    await gw.stop();
  });

  test("session_list reports live state alongside the catalogue", async () => {
    const ws = registerWorkspace();
    const h = makeHost();
    const gw = await startGateway(h);
    const session = createSession({ workspaceId: ws.id, now: clock });
    h.running.add(ws.id);

    relay.deliver(OWNER, { type: "session_list", id: "r1" });
    await vi.waitFor(() => expect(relay.replies()).toHaveLength(1));

    const sessions = relay.replies()[0]!["sessions"] as Array<Record<string, unknown>>;
    expect(sessions).toHaveLength(1);
    expect(sessions[0]!["session_id"]).toBe(session.session_id);
    expect(sessions[0]!["running"]).toBe(true);
    await gw.stop();
  });

  test("a malformed but addressable frame gets an error, not silence", async () => {
    // Otherwise the caller waits out its timeout for a reply that never comes.
    const h = makeHost();
    const gw = await startGateway(h);

    relay.deliver(OWNER, { type: "create_session", id: "r1", workspace_id: "w" });
    await vi.waitFor(() => expect(relay.replies()).toHaveLength(1));

    expect(relay.replies()[0]).toMatchObject({
      type: "action_error",
      in_reply_to: "r1",
    });
    expect(String(relay.replies()[0]!["error"])).toMatch(/idempotency_key/);
    await gw.stop();
  });

  test("an unknown action type is ignored silently (forward-compat)", async () => {
    const h = makeHost();
    const gw = await startGateway(h);

    relay.deliver(OWNER, { type: "quantum_teleport", id: "r1" });
    await Promise.resolve();
    await Promise.resolve();

    expect(relay.replies()).toEqual([]);
    await gw.stop();
  });
});
