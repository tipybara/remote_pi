/**
 * Integration tests: extension default export + pair_request flow + reconnect.
 *
 * Post plano 06: no Noise XX. Pairing is `pair_request → pair_ok|pair_error`
 * over an opaque outer envelope whose `ct` is base64(JSON.stringify(inner)).
 */
import { describe, expect, test, vi, beforeEach, afterEach } from "vitest";
import { EventEmitter } from "node:events";
import { createHash } from "node:crypto";
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { roomIdFor, roomIdForCwd } from "./rooms.js";
import { getCapabilities, setCapabilities } from "@earendil-works/pi-tui";
import type { ExtensionAPI, ExtensionFactory } from "@earendil-works/pi-coding-agent";

const _convertToPngMock = vi.hoisted(() => vi.fn(async () => null));

// ── Mock RelayClient ──────────────────────────────────────────────────────────

const relayRef: { current: MockRelay | null } = { current: null };
const relayInstances: MockRelay[] = [];
// Tests can swap this to inject failing connects across all future instances.
// Receives the `options` arg so tests can assert what was passed in.
let _defaultConnectImpl: (opts?: unknown) => Promise<void> = async () => undefined;

class MockRelay extends EventEmitter {
  static OPEN = 1;
  readyState = MockRelay.OPEN;
  connect     = vi.fn().mockImplementation((opts?: unknown) => _defaultConnectImpl(opts));
  send        = vi.fn();
  sendControl = vi.fn();
  close       = vi.fn(() => { this.readyState = 3; });
  isOpen      = vi.fn(() => this.readyState === MockRelay.OPEN);
  constructor() { super(); relayRef.current = this; relayInstances.push(this); }
}

class MockRoomAlreadyOpenError extends Error {
  constructor(public readonly roomId: string | undefined) {
    super(`room ${roomId} already open`);
    this.name = "RoomAlreadyOpenError";
  }
}

vi.mock("./transport/relay_client.js", () => ({
  RelayClient: MockRelay,
  RoomAlreadyOpenError: MockRoomAlreadyOpenError,
}));

// ── Mock storage ──────────────────────────────────────────────────────────────

type StoredPeer = { name: string; remote_epk: string; paired_at: string };
const _knownPeers: StoredPeer[] = [];
const _addedPeers: StoredPeer[] = [];
const _removedPeers: string[] = [];
let _ownerMembershipEnabled = false;

vi.mock("./pairing/storage.js", async (importOriginal) => {
  const orig = await importOriginal<typeof import("./pairing/storage.js")>();
  return {
    ...orig,
    getOrCreateEd25519Keypair: vi.fn().mockResolvedValue({
      publicKey: new Uint8Array(32),
      secretKey: new Uint8Array(32),
    }),
    listPeers: vi.fn().mockImplementation(async () => [..._knownPeers]),
    // Hermetic: derive signed-membership Owners from in-memory peers rather
    // than reading this machine's real pairing storage or network endpoint.
    listOwnerPubkeys: vi.fn().mockImplementation(
      async () => _ownerMembershipEnabled
        ? [...new Set((_knownPeers as unknown[]).map((peer) => {
          if (!peer || typeof peer !== "object") return peer;
          return (peer as { remote_epk?: unknown }).remote_epk;
        }))]
        : [],
    ),
    addPeer: vi.fn().mockImplementation(async (p: StoredPeer) => {
      _addedPeers.push(p);
      const index = _knownPeers.findIndex((peer) => peer.remote_epk === p.remote_epk);
      if (index >= 0) _knownPeers[index] = p;
      else _knownPeers.push(p);
    }),
    snapshotOwnerPubkeys: vi.fn().mockImplementation(async () => {
      if (!_ownerMembershipEnabled) {
        throw new Error("strict Owner snapshot unavailable in this test");
      }
      return [...new Set((_knownPeers as unknown[]).map((peer) => {
        if (!peer || typeof peer !== "object") return peer;
        return (peer as { remote_epk?: unknown }).remote_epk;
      }))].map((rawOwnerPubkey) => ({ rawOwnerPubkey, token: rawOwnerPubkey }));
    }),
    conditionalRemovePeer: vi.fn().mockImplementation(async (
      epk: string,
      _expectedToken: unknown,
      canCommit?: () => boolean,
    ) => {
      if (canCommit && !canCommit()) return { outcome: "no_authority" };
      const before = _knownPeers.length;
      const filtered = _knownPeers.filter((peer) => peer.remote_epk !== epk);
      if (filtered.length === before) return { outcome: "not_found" };
      _knownPeers.length = 0;
      _knownPeers.push(...filtered);
      _removedPeers.push(epk);
      return { outcome: "removed", nextToken: epk };
    }),
    removePeer: vi.fn().mockImplementation(async (epk: string) => {
      const before = _knownPeers.length;
      const filtered = (_knownPeers as unknown[]).filter((peer) => {
        if (!peer || typeof peer !== "object") return true;
        return (peer as { remote_epk?: unknown }).remote_epk !== epk;
      }) as StoredPeer[];
      _knownPeers.length = 0;
      _knownPeers.push(...filtered);
      if (filtered.length !== before) {
        _removedPeers.push(epk);
        return true;
      }
      return false;
    }),
  };
});

// ── Mock config (no real fs writes) ───────────────────────────────────────────

let _savedRelayUrl: string | null = null;
const _setRelayCalls: string[] = [];

vi.mock("./config.js", async (importOriginal) => {
  const orig = await importOriginal<typeof import("./config.js")>();
  return {
    ...orig,
    loadConfig: vi.fn().mockImplementation(() => ({
      ...(_savedRelayUrl ? { relay: _savedRelayUrl } : {}),
    })),
    saveConfig: vi.fn().mockImplementation((patch: { relay?: string }) => {
      _setRelayCalls.push(patch.relay ?? "");
      if (patch.relay !== undefined) _savedRelayUrl = patch.relay;
    }),
    resolveRelayUrl: vi.fn().mockImplementation(() => {
      const env = process.env["REMOTE_PI_RELAY"];
      if (env && env.length > 0) return { url: orig.toHttpUrl(env), source: "env" as const };
      if (_savedRelayUrl && _savedRelayUrl.length > 0) {
        return { url: orig.toHttpUrl(_savedRelayUrl), source: "config" as const };
      }
      return { url: orig.toHttpUrl(orig.kDefaultRelayUrl), source: "default" as const };
    }),
    // isValidRelayUrl + isWebSocketScheme + kDefaultRelayUrl + toHttpUrl
    // + toWebSocketUrl come from orig (...spread).
  };
});

// ── Mock qrSession.consumeToken control ───────────────────────────────────────

let _tokenStatus: "ok" | "expired" | "consumed" | "unknown" = "ok";
const _consumeCalls: string[] = [];

vi.mock("./pairing/qr.js", async (importOriginal) => {
  const orig = await importOriginal<typeof import("./pairing/qr.js")>();
  return {
    ...orig,
    displayQR: vi.fn(),  // suppress side effects (terminal spawn) in tests
    qrSession: {
      issueToken: vi.fn().mockReturnValue({
        token: "test-token",
        expiresAt: Date.now() + 60_000,
      }),
      consumeToken: vi.fn().mockImplementation((token: string) => {
        _consumeCalls.push(token);
        return _tokenStatus;
      }),
      clear: vi.fn(),
      generateToken: vi.fn().mockReturnValue("test-token"),
    },
  };
});

vi.mock("@earendil-works/pi-coding-agent", async (importOriginal) => {
  const orig = await importOriginal<typeof import("@earendil-works/pi-coding-agent")>();
  return { ...orig, convertToPng: _convertToPngMock };
});

interface CapturedSelfRevokeOptions {
  onRevoke?: (rawOwnerPubkey: string, canonicalOwnerPubkey: string) => void | Promise<void>;
  onAuthoritativeOwners?: (canonicalOwnerPubkeys: readonly string[]) => void | Promise<void>;
}

const selfRevokeHarness = vi.hoisted(() => ({
  options: [] as CapturedSelfRevokeOptions[],
}));

vi.mock("./mesh/self_revoke.js", async (importOriginal) => {
  const original = await importOriginal<typeof import("./mesh/self_revoke.js")>();
  class CapturingSelfRevoke extends original.SelfRevoke {
    constructor(options: ConstructorParameters<typeof original.SelfRevoke>[0]) {
      super(options);
      selfRevokeHarness.options.push(options);
    }
  }
  return { ...original, SelfRevoke: CapturingSelfRevoke };
});

// Import AFTER mocks
const indexModule = await import("./index.js");
const {
  default: extension,
  _getState,
  _getRoomIdForTest,
  _getPiSessionIdForTest,
  _resetPiSessionIdForTest,
  _onPeerDisconnect,
  routeClientMessage,
  _mapAgentMessagesToEvents,
  _setMessageBufferForTest,
  _setSessionStartedAtForTest,
  _hasPendingReconnect,
  _getMessageBufferForTest,
  _setCurrentModelForTest,
  _setPiForTest,
  _emitRelayStateForTest,
  _refreshFooterForTest,
  _getCurrentTurnIdForTest,
  _getPendingSteerIdsForTest,
  _connectForTest,
  _startRelayForTest,
  _getCachedPublicKeyForTest,
  _hasActivePeerForTest,
  _getActivePeerCountForTest,
  _checkSelfRevokeForTest,
  _restartSupervisorCommand,
  _setDisposedForTest,
  _resetAutoInitedForTest,
  _setAutoInitedForTest,
  _handleControl,
  _routeClientMessageFrom,
  CTRL_PREFIX,
} = indexModule;

// ── Helpers ───────────────────────────────────────────────────────────────────

function makeMockPi(): { pi: ExtensionAPI; registeredCommands: string[]; registeredTools: string[] } {
  const registeredCommands: string[] = [];
  const registeredTools: string[] = [];
  const pi = {
    on: () => undefined,
    registerCommand(name: string, _opts: unknown) { registeredCommands.push(name); },
    registerTool(tool: { name?: string }) { if (tool.name) registeredTools.push(tool.name); }, registerShortcut: () => undefined,
    registerFlag: () => undefined, getFlag: () => undefined,
    registerMessageRenderer: () => undefined,
    sendMessage: () => undefined, sendUserMessage: () => undefined,
  } as unknown as ExtensionAPI;
  return { pi, registeredCommands, registeredTools };
}

function makeMockCtx(cwd = "/home/user/projects/remote_pi") {
  return { ui: { notify: vi.fn() }, cwd, abort: vi.fn() };
}

function deferred<T>(): {
  promise: Promise<T>;
  resolve(value: T): void;
  reject(reason?: unknown): void;
} {
  let resolve!: (value: T) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((res, rej) => { resolve = res; reject = rej; });
  return { promise, resolve, reject };
}

type CmdHandler = (args: string, ctx: ReturnType<typeof makeMockCtx>) => Promise<void>;

function captureHandler(commandName: string): CmdHandler {
  let captured: CmdHandler | undefined;
  const pi = {
    on: () => undefined,
    registerCommand(name: string, opts: { handler: CmdHandler }) {
      if (name === commandName) captured = opts.handler;
    },
    registerTool: () => undefined, registerShortcut: () => undefined,
    registerFlag: () => undefined, getFlag: () => undefined,
    registerMessageRenderer: () => undefined,
    sendMessage: () => undefined, sendUserMessage: () => undefined,
  } as unknown as ExtensionAPI;
  (extension as ExtensionFactory)(pi);
  if (!captured) throw new Error(`command "${commandName}" not registered`);
  return captured;
}

function makeInnerLine(peer: string, inner: object): string {
  const ct = Buffer.from(JSON.stringify(inner)).toString("base64");
  return JSON.stringify({ peer, ct });
}

function decodeSentCt(raw: string): { peer: string; inner: { type: string; [k: string]: unknown } } {
  const outer = JSON.parse(raw) as { peer: string; ct: string };
  const inner = JSON.parse(Buffer.from(outer.ct, "base64").toString("utf8")) as {
    type: string;
    [k: string]: unknown;
  };
  return { peer: outer.peer, inner };
}

const OWNER_PUBLIC_FIXTURE = Buffer.from(
  "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
  "hex",
);
const OTHER_OWNER_PUBLIC_FIXTURE = Buffer.from(
  "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c",
  "hex",
);
const OWNER_STANDARD_FIXTURE = OWNER_PUBLIC_FIXTURE.toString("base64");
const OWNER_URL_SAFE_FIXTURE = OWNER_PUBLIC_FIXTURE.toString("base64url");
const OTHER_OWNER_STANDARD_FIXTURE = OTHER_OWNER_PUBLIC_FIXTURE.toString("base64");

// ── Registration tests ────────────────────────────────────────────────────────

describe("extension default export", () => {
  test("is an ExtensionFactory function", () => {
    expect(typeof extension).toBe("function");
  });

  test("registers the user-facing commands (post plan/26 W3: + install/uninstall)", () => {
    const { pi, registeredCommands } = makeMockPi();
    (extension as ExtensionFactory)(pi);
    // Local session (plan/25)
    expect(registeredCommands).toContain("remote-pi");
    expect(registeredCommands).toContain("remote-pi setup");
    expect(registeredCommands).toContain("remote-pi status");
    expect(registeredCommands).toContain("remote-pi stop");
    expect(registeredCommands).toContain("remote-pi pair");
    expect(registeredCommands).toContain("remote-pi devices");
    expect(registeredCommands).toContain("remote-pi revoke");
    expect(registeredCommands).toContain("remote-pi set-relay");
    // Daemon registry (plan/26 W1)
    expect(registeredCommands).toContain("remote-pi create");
    expect(registeredCommands).toContain("remote-pi remove");
    // Fleet ops (plan/26 W2) — use `daemon` prefix to avoid clashing with
    // /remote-pi stop (local) since both have very different semantics.
    expect(registeredCommands).toContain("remote-pi daemons");
    expect(registeredCommands).toContain("remote-pi daemon start");
    expect(registeredCommands).toContain("remote-pi daemon stop");
    expect(registeredCommands).toContain("remote-pi daemon restart");
    expect(registeredCommands).toContain("remote-pi daemon status");
    expect(registeredCommands).toContain("remote-pi daemon send");
    // Service install (plan/26 W3) — systemd / launchd
    expect(registeredCommands).toContain("remote-pi install");
    expect(registeredCommands).toContain("remote-pi uninstall");
    expect(registeredCommands).not.toContain("remote-pi peers");
  });

  test("restart-supervisor maps to the right OS command sequence per platform", () => {
    expect(_restartSupervisorCommand("darwin", 501)).toEqual([
      { cmd: "launchctl", args: ["kickstart", "-k", "gui/501/dev.remotepi.supervisord"] },
    ]);
    expect(_restartSupervisorCommand("linux", 1000)).toEqual([
      { cmd: "systemctl", args: ["--user", "restart", "remote-pi-supervisord.service"] },
    ]);
    // Windows (plan/40): End (ignorable) then Run, via Task Scheduler.
    expect(_restartSupervisorCommand("win32", 0)).toEqual([
      { cmd: "schtasks", args: ["/End", "/TN", "RemotePiSupervisor"], ignoreFailure: true },
      { cmd: "schtasks", args: ["/Run", "/TN", "RemotePiSupervisor"] },
    ]);
    // Truly unsupported platform → null (caller exits non-zero).
    expect(_restartSupervisorCommand("aix", 0)).toBeNull();
  });

  test("no deprecated or removed commands leak back into the surface", () => {
    const { pi, registeredCommands } = makeMockPi();
    (extension as ExtensionFactory)(pi);
    expect(registeredCommands).toHaveLength(22);
    // `relay` is back as ONE command with verbs (start/stop/status/url), not the
    // five separate registrations plan/19 trimmed — the README documents it and
    // without it every `/remote-pi relay …` silently reprinted the status panel.
    expect(registeredCommands).toContain("remote-pi relay");
    expect(registeredCommands).toContain("remote-pi config");
    for (const removed of [
      "remote-pi join", "remote-pi leave", "remote-pi sessions",
      "remote-pi relay start", "remote-pi relay stop",
      "remote-pi relay status", "remote-pi relay url",
      "remote-pi start", "remote-pi list", "remote-pi add-relay",
      "remote-pi peers",
    ]) {
      expect(registeredCommands).not.toContain(removed);
    }
  });

  test("does not register local agent-mesh tools", () => {
    const { pi, registeredTools } = makeMockPi();
    (extension as ExtensionFactory)(pi);
    expect(registeredTools).not.toContain("list_peers");
    expect(registeredTools).not.toContain("agent_send");
    expect(registeredTools).not.toContain("agent_request");
  });

  // README documents `/remote-pi rename <new>` but the verb had been dropped
  // from the TUI dispatcher (only the Cockpit `rename:` control path worked).
  // Re-adding it aligns the implementation with the documented surface.
  test("/remote-pi rename is registered and dispatches to _renameAgent", async () => {
    const rename = captureHandler("remote-pi rename");
    expect(typeof rename).toBe("function");
    // Empty arg → _renameAgent no-ops (same contract as the control channel).
    await expect(rename("", makeMockCtx())).resolves.toBeUndefined();
  });
});

// ── State machine + pair_request flow ─────────────────────────────────────────

describe("state machine + pair_request flow", () => {
  beforeEach(async () => {
    vi.clearAllMocks();
    _knownPeers.length = 0;
    _addedPeers.length = 0;
    _removedPeers.length = 0;
    _consumeCalls.length = 0;
    _tokenStatus = "ok";
    relayRef.current = null;
    // Restore default consumeToken behavior — earlier tests can override it.
    const qr = await import("./pairing/qr.js");
    (qr.qrSession.consumeToken as unknown as ReturnType<typeof vi.fn>).mockImplementation(
      (token: string) => {
        _consumeCalls.push(token);
        return _tokenStatus;
      },
    );
    // Force idle via stop
    const stop = captureHandler("remote-pi stop");
    await stop("", makeMockCtx());
  });

  test("start: idle → started", async () => {
    captureHandler("remote-pi");
    await _connectForTest(makeMockCtx());
    expect(_getState()).toBe("started");
  });

  test("pair without start → warning, state stays idle", async () => {
    expect(_getState()).toBe("idle");
    // Isolated empty cwd so `localConfigExists` is deterministically false on
    // every OS. The old fake path (`/home/user/...`) is non-writable on macOS
    // (config never exists → first-time path) but writable on Windows (a config
    // could exist → wrong auto-bootstrap path, slow real-socket work).
    const cwd = mkdtempSync(join(tmpdir(), "pi-ext-cwd-"));
    const pair = captureHandler("remote-pi pair");
    const ctx = makeMockCtx(cwd);
    await pair("", ctx);
    expect(ctx.ui.notify).toHaveBeenCalledWith(expect.stringContaining("Run /remote-pi"), "warning");
    expect(_getState()).toBe("idle");
    rmSync(cwd, { recursive: true, force: true });
  });

  test("valid pair_request → pair_ok + state paired + peer persisted", async () => {
    _tokenStatus = "ok";
    const APP_PEER_ID = "valid-app-peer-base64";

    captureHandler("remote-pi");
    await _connectForTest(makeMockCtx());
    expect(_getState()).toBe("started");

    relayRef.current!.emit("message", makeInnerLine(APP_PEER_ID, {
      type: "pair_request",
      id: "req-1",
      token: "test-token",
      device_name: "iPhone do Jacob",
    }));

    await vi.waitFor(() => expect(_getState()).toBe("paired"), { timeout: 2000 });

    // pair_ok must have been sent back to the app peer
    const sent = relayRef.current!.send.mock.calls.map((c) => c[0] as string);
    const pairOks = sent.map(decodeSentCt).filter((d) => d.inner.type === "pair_ok");
    expect(pairOks).toHaveLength(1);
    expect(pairOks[0]!.peer).toBe(APP_PEER_ID);
    expect(pairOks[0]!.inner).toMatchObject({
      type: "pair_ok",
      in_reply_to: "req-1",
    });

    // Plan/27 Wave A: pair_ok carries harness + hostname so the app can
    // render a meaningful device row. Both are required in every NEW
    // pairing emitted by this code path (wire type still has them
    // optional for backward-compat with older Pi builds).
    const inner = pairOks[0]!.inner as {
      harness?: { name: string; version: string };
      hostname?: string;
    };
    expect(inner.harness).toBeDefined();
    expect(inner.harness!.name).toBe("Pi coding agent");
    expect(typeof inner.harness!.version).toBe("string");
    expect(inner.harness!.version.length).toBeGreaterThan(0);
    expect(typeof inner.hostname).toBe("string");
    expect(inner.hostname!.length).toBeGreaterThan(0);

    // Peer must have been persisted
    expect(_addedPeers).toHaveLength(1);
    expect(_addedPeers[0]).toMatchObject({
      name: "iPhone do Jacob",
      remote_epk: APP_PEER_ID,
    });
  });

  test("expired token → pair_error{token_expired} + state stays started", async () => {
    _tokenStatus = "expired";
    const APP_PEER_ID = "stale-token-peer";

    captureHandler("remote-pi");
    await _connectForTest(makeMockCtx());

    relayRef.current!.emit("message", makeInnerLine(APP_PEER_ID, {
      type: "pair_request",
      id: "req-x",
      token: "test-token",
      device_name: "iPhone",
    }));

    await new Promise((r) => setTimeout(r, 50));

    expect(_getState()).toBe("started");
    expect(_addedPeers).toHaveLength(0);

    const sent = relayRef.current!.send.mock.calls.map((c) => c[0] as string);
    const errs = sent.map(decodeSentCt).filter((d) => d.inner.type === "pair_error");
    expect(errs).toHaveLength(1);
    expect(errs[0]!.inner).toMatchObject({
      type: "pair_error",
      in_reply_to: "req-x",
      code: "token_expired",
    });
  });

  test("consumed token → pair_error{token_consumed} on second pair_request", async () => {
    // First call returns ok (consumes); second returns consumed.
    let calls = 0;
    _tokenStatus = "ok";
    // override consumeToken to return ok once, then consumed
    const qr = await import("./pairing/qr.js");
    (qr.qrSession.consumeToken as unknown as ReturnType<typeof vi.fn>).mockImplementation(
      () => {
        calls += 1;
        return calls === 1 ? "ok" : "consumed";
      },
    );

    const APP_PEER_A = "peer-a";
    const APP_PEER_B = "peer-b";

    captureHandler("remote-pi");
    await _connectForTest(makeMockCtx());

    // First pair_request from peer A → ok
    relayRef.current!.emit("message", makeInnerLine(APP_PEER_A, {
      type: "pair_request", id: "req-a", token: "test-token", device_name: "Phone A",
    }));
    await vi.waitFor(() => expect(_getState()).toBe("paired"), { timeout: 2000 });

    // Disconnect so we're back in started state for the second attempt
    _onPeerDisconnect();
    expect(_getState()).toBe("started");

    // Second pair_request from peer B with same token → consumed
    relayRef.current!.emit("message", makeInnerLine(APP_PEER_B, {
      type: "pair_request", id: "req-b", token: "test-token", device_name: "Phone B",
    }));
    await new Promise((r) => setTimeout(r, 50));

    expect(_getState()).toBe("started");  // didn't transition
    const sent = relayRef.current!.send.mock.calls.map((c) => c[0] as string);
    const errs = sent.map(decodeSentCt).filter((d) =>
      d.inner.type === "pair_error" && d.inner["in_reply_to"] === "req-b",
    );
    expect(errs).toHaveLength(1);
    expect(errs[0]!.inner).toMatchObject({ code: "token_consumed" });
  });

  test("paired peer ignores subsequent pair_request (idempotent)", async () => {
    _tokenStatus = "ok";
    const APP_PEER_ID = "already-paired";

    captureHandler("remote-pi");
    await _connectForTest(makeMockCtx());

    // First pair_request → paired
    relayRef.current!.emit("message", makeInnerLine(APP_PEER_ID, {
      type: "pair_request", id: "req-1", token: "test-token", device_name: "Phone",
    }));
    await vi.waitFor(() => expect(_getState()).toBe("paired"), { timeout: 2000 });

    const sendsBefore = relayRef.current!.send.mock.calls.length;

    // Second pair_request from same peer while paired → routed through
    // PlainPeerChannel.onMessage → routeClientMessage which ignores it.
    relayRef.current!.emit("message", makeInnerLine(APP_PEER_ID, {
      type: "pair_request", id: "req-2", token: "test-token", device_name: "Phone",
    }));
    await new Promise((r) => setTimeout(r, 50));

    expect(_getState()).toBe("paired");
    // No additional outbound messages from this second pair_request
    expect(relayRef.current!.send.mock.calls.length).toBe(sendsBefore);
  });

  test("known peer reconnect: any non-pair message from peers.json → paired", async () => {
    const APP_PEER_ID = OWNER_STANDARD_FIXTURE;
    _knownPeers.push({
      name: "Known App",
      remote_epk: APP_PEER_ID,
      paired_at: new Date().toISOString(),
    });

    captureHandler("remote-pi");
    await _connectForTest(makeMockCtx());
    expect(_getState()).toBe("started");

    relayRef.current!.emit("message", makeInnerLine(APP_PEER_ID, {
      type: "ping", id: "ping-reconnect",
    }));

    await vi.waitFor(() => expect(_getState()).toBe("paired"), { timeout: 2000 });
  });

  test("unknown peer non-pair message → state stays started, no peer added", async () => {
    captureHandler("remote-pi");
    await _connectForTest(makeMockCtx());

    relayRef.current!.emit("message", makeInnerLine("unknown-peer", {
      type: "ping", id: "ping-x",
    }));
    await new Promise((r) => setTimeout(r, 50));

    expect(_getState()).toBe("started");
    expect(_addedPeers).toHaveLength(0);
  });

  test("unknown peer + user_message → relay receives error{unknown_peer}", async () => {
    captureHandler("remote-pi");
    await _connectForTest(makeMockCtx());

    relayRef.current!.emit("message", makeInnerLine("revoked-peer", {
      type: "user_message", id: "msg-x", text: "are you there",
    }));
    await new Promise((r) => setTimeout(r, 50));

    expect(_getState()).toBe("started");
    const sent = relayRef.current!.send.mock.calls.map((c) => c[0] as string);
    const errors = sent.map(decodeSentCt).filter((d) =>
      d.inner.type === "error" && d.inner["code"] === "unknown_peer",
    );
    expect(errors).toHaveLength(1);
    expect(errors[0]!.peer).toBe("revoked-peer");
    expect(errors[0]!.inner).toMatchObject({
      type: "error",
      code: "unknown_peer",
    });
  });

  test("unknown peer + pair_request → NOT replied with error{unknown_peer}", async () => {
    // Pair_request is the legitimate path for unknown peers — handler must
    // respond with pair_ok or pair_error, never with the generic
    // error{unknown_peer}. Use token_unknown to keep peer unknown afterwards.
    _tokenStatus = "unknown";
    captureHandler("remote-pi");
    await _connectForTest(makeMockCtx());

    relayRef.current!.emit("message", makeInnerLine("stranger", {
      type: "pair_request", id: "req-stranger", token: "test-token", device_name: "Stranger",
    }));
    await new Promise((r) => setTimeout(r, 50));

    const sent = relayRef.current!.send.mock.calls.map((c) => c[0] as string);
    const unknownPeerErrs = sent.map(decodeSentCt).filter((d) =>
      d.inner.type === "error" && d.inner["code"] === "unknown_peer",
    );
    expect(unknownPeerErrs).toHaveLength(0);

    // Sanity: a pair_error{token_unknown} should have been sent instead.
    const pairErrs = sent.map(decodeSentCt).filter((d) => d.inner.type === "pair_error");
    expect(pairErrs).toHaveLength(1);
    expect(pairErrs[0]!.inner).toMatchObject({ code: "token_unknown" });
  });

  test("_onPeerDisconnect: paired → started, listener re-installed", async () => {
    _tokenStatus = "ok";
    const APP_PEER_ID = OWNER_STANDARD_FIXTURE;

    captureHandler("remote-pi");
    await _connectForTest(makeMockCtx());

    relayRef.current!.emit("message", makeInnerLine(APP_PEER_ID, {
      type: "pair_request", id: "req-1", token: "test-token", device_name: "Phone",
    }));
    await vi.waitFor(() => expect(_getState()).toBe("paired"), { timeout: 2000 });

    _onPeerDisconnect();
    expect(_getState()).toBe("started");

    // Reconnect via a ping (known peer now) → paired again
    relayRef.current!.emit("message", makeInnerLine(APP_PEER_ID, {
      type: "ping", id: "ping-reconnect",
    }));
    await vi.waitFor(() => expect(_getState()).toBe("paired"), { timeout: 2000 });
  });
});

// ── Fixture roundtrip ─────────────────────────────────────────────────────────

describe("contract fixtures: pair_*", () => {
  const fixtureDir = fileURLToPath(
    new URL("../../.orchestration/contracts/fixtures", import.meta.url),
  );

  test("pair_request.jsonl parses into ClientMessage shape", () => {
    const lines = readFileSync(`${fixtureDir}/pair_request.jsonl`, "utf8")
      .split("\n").filter(Boolean);
    expect(lines.length).toBeGreaterThan(0);
    for (const line of lines) {
      const obj = JSON.parse(line) as { type: string; id: string; token: string; device_name: string };
      expect(obj.type).toBe("pair_request");
      expect(typeof obj.id).toBe("string");
      expect(typeof obj.token).toBe("string");
      expect(typeof obj.device_name).toBe("string");
    }
  });

  test("pair_ok.jsonl parses into ServerMessage shape", () => {
    const lines = readFileSync(`${fixtureDir}/pair_ok.jsonl`, "utf8")
      .split("\n").filter(Boolean);
    expect(lines.length).toBeGreaterThan(0);
    for (const line of lines) {
      const obj = JSON.parse(line) as { type: string; in_reply_to: string; session_name: string };
      expect(obj.type).toBe("pair_ok");
      expect(typeof obj.in_reply_to).toBe("string");
      expect(typeof obj.session_name).toBe("string");
    }
  });

  test("pair_error.jsonl parses with valid code", () => {
    const lines = readFileSync(`${fixtureDir}/pair_error.jsonl`, "utf8")
      .split("\n").filter(Boolean);
    expect(lines.length).toBeGreaterThan(0);
    const validCodes = new Set(["token_expired", "token_consumed", "token_unknown", "internal_error"]);
    for (const line of lines) {
      const obj = JSON.parse(line) as { type: string; in_reply_to: string; code: string; message: string };
      expect(obj.type).toBe("pair_error");
      expect(validCodes.has(obj.code)).toBe(true);
    }
  });

  test("all 31 fixture files present", () => {
    const files = readdirSync(fixtureDir).filter((f) => f.endsWith(".jsonl"));
    expect(files).toHaveLength(31);
  });
});

// ── /remote-pi revoke <shortid> ───────────────────────────────────────────────

describe("/remote-pi revoke", () => {
  beforeEach(async () => {
    vi.clearAllMocks();
    _knownPeers.length = 0;
    _addedPeers.length = 0;
    _removedPeers.length = 0;
    _consumeCalls.length = 0;
    _tokenStatus = "ok";
    relayRef.current = null;
    const qr = await import("./pairing/qr.js");
    (qr.qrSession.consumeToken as unknown as ReturnType<typeof vi.fn>).mockImplementation(
      (token: string) => {
        _consumeCalls.push(token);
        return _tokenStatus;
      },
    );
    const stop = captureHandler("remote-pi stop");
    await stop("", makeMockCtx());
  });

  test("empty arg → usage warning", async () => {
    _knownPeers.push({ name: "Phone", remote_epk: "abcd1234efghIJKL", paired_at: "now" });

    const revoke = captureHandler("remote-pi revoke");
    const ctx = makeMockCtx();
    await revoke("", ctx);

    expect(ctx.ui.notify).toHaveBeenCalledWith(
      expect.stringContaining("Usage: /remote-pi revoke"),
      "warning",
    );
    expect(_removedPeers).toHaveLength(0);
  });

  test("idle (relay off) → refuses instead of a silent peers.json edit", async () => {
    _knownPeers.push({ name: "Phone", remote_epk: "aaaa1111zzzz", paired_at: "now" });

    // beforeEach stopped the relay; an isolated empty cwd guarantees no local
    // config on every OS, so revoke bails (mirrors pair) rather than editing
    // the file offline. (Fresh tmpdir — see the "pair without start" test.)
    const cwd = mkdtempSync(join(tmpdir(), "pi-ext-cwd-"));
    const revoke = captureHandler("remote-pi revoke");
    const ctx = makeMockCtx(cwd);
    await revoke("aaaa1111", ctx);

    expect(_removedPeers).toHaveLength(0);
    expect(_knownPeers).toHaveLength(1);
    expect(ctx.ui.notify).toHaveBeenCalledWith(
      expect.stringContaining("First-time setup needed"),
      "warning",
    );
    rmSync(cwd, { recursive: true, force: true });
  });

  test("valid shortid → peer removed + success notify", async () => {
    _knownPeers.push({ name: "Phone A", remote_epk: OWNER_STANDARD_FIXTURE, paired_at: "now" });
    _knownPeers.push({ name: "Phone B", remote_epk: OTHER_OWNER_STANDARD_FIXTURE, paired_at: "now" });

    // Revoke now requires the relay (mirrors pair) — bring it up first.
    captureHandler("remote-pi");
    await _connectForTest(makeMockCtx());

    const revoke = captureHandler("remote-pi revoke");
    const ctx = makeMockCtx();
    await revoke(OWNER_STANDARD_FIXTURE.slice(0, 8), ctx);

    expect(_removedPeers).toEqual([OWNER_STANDARD_FIXTURE]);
    expect(_knownPeers.map((p) => p.name)).toEqual(["Phone B"]);
    expect(ctx.ui.notify).toHaveBeenCalledWith(
      expect.stringContaining("Revoked: Phone A"),
      "info",
    );
  });

  test("unknown shortid → no peer matching warning, peers untouched", async () => {
    _knownPeers.push({ name: "Phone", remote_epk: "cccc3333", paired_at: "now" });

    captureHandler("remote-pi");
    await _connectForTest(makeMockCtx());

    const revoke = captureHandler("remote-pi revoke");
    const ctx = makeMockCtx();
    await revoke("ffffffff", ctx);

    expect(ctx.ui.notify).toHaveBeenCalledWith(
      expect.stringContaining("No peer matching that shortid"),
      "warning",
    );
    expect(_removedPeers).toHaveLength(0);
    expect(_knownPeers).toHaveLength(1);
  });

  test("ambiguous shortid (>1 match) → ambiguity warning, peers untouched", async () => {
    _knownPeers.push({ name: "A", remote_epk: "abcd1111-invalid", paired_at: "now" });
    _knownPeers.push({ name: "B", remote_epk: "abcd2222-invalid", paired_at: "now" });

    captureHandler("remote-pi");
    await _connectForTest(makeMockCtx());

    const revoke = captureHandler("remote-pi revoke");
    const ctx = makeMockCtx();
    await revoke("abcd", ctx);

    expect(ctx.ui.notify).toHaveBeenCalledWith(
      expect.stringContaining("Ambiguous shortid"),
      "warning",
    );
    expect(_removedPeers).toHaveLength(0);
    expect(_knownPeers).toHaveLength(2);
  });

  test("revoke of currently-attached owner → channel removed, relay stays started", async () => {
    // Multi-channel (W2D): revoking the only attached owner removes their
    // channel from _activePeers but leaves the relay up. Pre-W2D this went
    // all the way back to `idle` via _goIdle; that's no longer the case.
    _tokenStatus = "ok";
    const ACTIVE_PEER = OWNER_STANDARD_FIXTURE;

    captureHandler("remote-pi");
    await _connectForTest(makeMockCtx());

    relayRef.current!.emit("message", JSON.stringify({
      peer: ACTIVE_PEER,
      ct: Buffer.from(JSON.stringify({
        type: "pair_request", id: "req-1", token: "test-token", device_name: "Active Phone",
      })).toString("base64"),
    }));
    await vi.waitFor(() => expect(_getState()).toBe("paired"), { timeout: 2000 });

    const revoke = captureHandler("remote-pi revoke");
    const ctx = makeMockCtx();
    await revoke(OWNER_STANDARD_FIXTURE.slice(0, 8), ctx);

    // Channel torn down, but relay still listening for new pairings.
    expect(_hasActivePeerForTest(ACTIVE_PEER)).toBe(false);
    expect(_getState()).toBe("started");
    expect(_removedPeers).toEqual([ACTIVE_PEER]);
    expect(_knownPeers).toHaveLength(0);
    expect(ctx.ui.notify).toHaveBeenCalledWith(
      expect.stringContaining("Revoked: Active Phone"),
      "info",
    );
  });

  test("URL-safe raw records revoke exactly one record and detach by canonical identity", async () => {
    const malformedRawOwner = "malformed-owner/+not-a-public-key";
    _knownPeers.push(
      { name: "URL-safe Owner", remote_epk: OWNER_URL_SAFE_FIXTURE, paired_at: "now" },
      { name: "Malformed", remote_epk: malformedRawOwner, paired_at: "now" },
      { name: "Other Owner", remote_epk: OTHER_OWNER_STANDARD_FIXTURE, paired_at: "now" },
    );

    await _connectForTest(makeMockCtx());
    relayRef.current!.emit("message", makeInnerLine(OWNER_STANDARD_FIXTURE, {
      type: "ping", id: "url-safe-owner",
    }));
    relayRef.current!.emit("message", makeInnerLine(OTHER_OWNER_STANDARD_FIXTURE, {
      type: "ping", id: "other-owner",
    }));
    await vi.waitFor(() => expect(_getActivePeerCountForTest()).toBe(2));

    const revoke = captureHandler("remote-pi revoke");
    await revoke(OWNER_URL_SAFE_FIXTURE, makeMockCtx());
    expect(_removedPeers).toEqual([OWNER_URL_SAFE_FIXTURE]);
    expect(_hasActivePeerForTest(OWNER_STANDARD_FIXTURE)).toBe(false);
    expect(_hasActivePeerForTest(OTHER_OWNER_STANDARD_FIXTURE)).toBe(true);

    await revoke(malformedRawOwner, makeMockCtx());
    expect(_removedPeers).toEqual([OWNER_URL_SAFE_FIXTURE, malformedRawOwner]);
    expect(_hasActivePeerForTest(OTHER_OWNER_STANDARD_FIXTURE)).toBe(true);
  });

  test("strict Owner snapshot detaches and reports only the absent active Owner", async () => {
    _ownerMembershipEnabled = true;
    _knownPeers.push(
      { name: "URL-safe Owner", remote_epk: OWNER_URL_SAFE_FIXTURE, paired_at: "now" },
      { name: "Other Owner", remote_epk: OTHER_OWNER_STANDARD_FIXTURE, paired_at: "now" },
    );
    const sendMessage = vi.fn();
    const fetchMock = vi.fn(async () => ({ status: 404, json: async () => ({}) } as Response));
    vi.stubGlobal("fetch", fetchMock);

    try {
      captureHandler("remote-pi");
      _setPiForTest({ sendMessage, sendUserMessage: () => undefined });
      await _connectForTest(makeMockCtx());
      expect(fetchMock).toHaveBeenCalledTimes(2);

      relayRef.current!.emit("message", makeInnerLine(OWNER_STANDARD_FIXTURE, {
        type: "ping", id: "absent-owner-active",
      }));
      relayRef.current!.emit("message", makeInnerLine(OTHER_OWNER_STANDARD_FIXTURE, {
        type: "ping", id: "surviving-owner-active",
      }));
      await vi.waitFor(() => expect(_getActivePeerCountForTest()).toBe(2));

      _knownPeers.splice(_knownPeers.findIndex(
        (peer) => peer.remote_epk === OWNER_URL_SAFE_FIXTURE,
      ), 1);
      await _checkSelfRevokeForTest();

      expect(_hasActivePeerForTest(OWNER_STANDARD_FIXTURE)).toBe(false);
      expect(_hasActivePeerForTest(OTHER_OWNER_STANDARD_FIXTURE)).toBe(true);
      const reports = sendMessage.mock.calls
        .map(([message]) => message as { customType?: string; content?: string })
        .filter((message) => message.customType === "remote-pi:mesh-revoked");
      expect(reports).toHaveLength(1);
      expect(reports[0]?.content).toContain(
        createHash("sha256").update(OWNER_PUBLIC_FIXTURE).digest("hex").slice(0, 8),
      );
    } finally {
      _ownerMembershipEnabled = false;
      vi.unstubAllGlobals();
    }
  });

  test("devices listing marks online/offline per attached channel", async () => {
    _tokenStatus = "ok";
    const ACTIVE_PEER = OWNER_STANDARD_FIXTURE;
    _knownPeers.push({ name: "Idle Peer", remote_epk: OTHER_OWNER_STANDARD_FIXTURE, paired_at: "now" });

    await _connectForTest(makeMockCtx());

    relayRef.current!.emit("message", JSON.stringify({
      peer: ACTIVE_PEER,
      ct: Buffer.from(JSON.stringify({
        type: "pair_request", id: "req-1", token: "test-token", device_name: "Active Phone",
      })).toString("base64"),
    }));
    await vi.waitFor(() => expect(_getState()).toBe("paired"), { timeout: 2000 });

    const devices = captureHandler("remote-pi devices");
    const ctx = makeMockCtx();
    await devices("", ctx);

    const text = (ctx.ui.notify.mock.calls[0]![0]) as string;
    // The attached owner shows online; the un-attached one shows offline.
    expect(text).toContain(`${OWNER_STANDARD_FIXTURE.slice(0, 8)} — Active Phone 🟢 online`);
    expect(text).toContain(`${OTHER_OWNER_STANDARD_FIXTURE.slice(0, 8)} — Idle Peer ⚪ offline`);
  });
});

// Removed obsolete _state_isIdle helper — tests now check _getState() or
// _hasActivePeerForTest directly. Kept the void below to anchor the new
// `_getActivePeerCountForTest` import so it isn't flagged as unused even
// when only some tests in this file consume it.
void _getActivePeerCountForTest;

// ── user_input mirroring (local terminal / RPC) ───────────────────────────────

type AnyEvent = { type: string; [k: string]: unknown };
type EventHandler = (event: AnyEvent) => unknown;

function captureEventHandler(eventName: string): EventHandler {
  let captured: EventHandler | undefined;
  const pi = {
    on(e: string, h: EventHandler) { if (e === eventName) captured = h; },
    registerCommand: () => undefined,
    registerTool: () => undefined, registerShortcut: () => undefined,
    registerFlag: () => undefined, getFlag: () => undefined,
    registerMessageRenderer: () => undefined,
    sendMessage: () => undefined, sendUserMessage: () => undefined,
  } as unknown as ExtensionAPI;
  (extension as ExtensionFactory)(pi);
  if (!captured) throw new Error(`event "${eventName}" handler not registered`);
  return captured;
}

function captureEventHarness(): {
  handler: (eventName: string) => EventHandler;
  emitBus: (channel: string, data: unknown) => void;
  busListenerCount: (channel: string) => number;
} {
  const handlers = new Map<string, EventHandler>();
  const busHandlers = new Map<string, Array<(data: unknown) => void>>();
  const pi = {
    on(e: string, h: EventHandler) { handlers.set(e, h); },
    events: {
      emit(channel: string, data: unknown) {
        for (const h of busHandlers.get(channel) ?? []) h(data);
      },
      on(channel: string, h: (data: unknown) => void) {
        const list = busHandlers.get(channel) ?? [];
        list.push(h);
        busHandlers.set(channel, list);
        return () => {
          const current = busHandlers.get(channel) ?? [];
          busHandlers.set(channel, current.filter((item) => item !== h));
        };
      },
    },
    registerCommand: () => undefined,
    registerTool: () => undefined, registerShortcut: () => undefined,
    registerFlag: () => undefined, getFlag: () => undefined,
    registerMessageRenderer: () => undefined,
    sendMessage: () => undefined, sendUserMessage: () => undefined,
  } as unknown as ExtensionAPI;
  (extension as ExtensionFactory)(pi);
  return {
    handler(eventName: string) {
      const h = handlers.get(eventName);
      if (!h) throw new Error(`event "${eventName}" handler not registered`);
      return h;
    },
    emitBus(channel: string, data: unknown) {
      (pi.events as unknown as { emit: (channel: string, data: unknown) => void }).emit(channel, data);
    },
    busListenerCount(channel: string) {
      return busHandlers.get(channel)?.length ?? 0;
    },
  };
}

function captureMessageRenderer(): {
  getRenderer(): (message: { details?: unknown }, options: unknown, theme: unknown) => unknown;
} {
  let renderer: ((message: { details?: unknown }, options: unknown, theme: unknown) => unknown) | undefined;
  const pi = {
    on() { /* no-op */ },
    registerCommand: () => undefined,
    registerTool: () => undefined, registerShortcut: () => undefined,
    registerFlag: () => undefined, getFlag: () => undefined,
    registerMessageRenderer(type: string, callback: unknown) {
      if (type === "remote-pi:received-image") {
        renderer = callback as (message: { details?: unknown }, options: unknown, theme: unknown) => unknown;
      }
    },
    sendMessage: () => undefined,
    sendUserMessage: () => undefined,
  } as unknown as ExtensionAPI;
  (extension as ExtensionFactory)(pi);
  if (!renderer) throw new Error("custom image renderer not registered");
  return {
    getRenderer(): (message: { details?: unknown }, options: unknown, theme: unknown) => unknown {
      if (!renderer) throw new Error("custom image renderer not registered");
      return renderer;
    },
  };
}

async function _pairForTest(appPeerId: string): Promise<void> {
  captureHandler("remote-pi");
  await _connectForTest(makeMockCtx());
  relayRef.current!.emit("message", JSON.stringify({
    peer: appPeerId,
    ct: Buffer.from(JSON.stringify({
      type: "pair_request", id: "req-1", token: "test-token", device_name: "Phone",
    })).toString("base64"),
  }));
  await vi.waitFor(() => expect(_getState()).toBe("paired"), { timeout: 2000 });
}

/** Adds a second pair_request from a new peer to an already-running Pi.
 *  Used by multi-channel tests to verify the catch-22 is gone. */
async function _pairAdditionalForTest(appPeerId: string, deviceName: string): Promise<void> {
  relayRef.current!.emit("message", JSON.stringify({
    peer: appPeerId,
    ct: Buffer.from(JSON.stringify({
      type: "pair_request", id: `req-${appPeerId.slice(0, 6)}`, token: "test-token", device_name: deviceName,
    })).toString("base64"),
  }));
  await vi.waitFor(
    () => expect(_hasActivePeerForTest(appPeerId)).toBe(true),
    { timeout: 2000 },
  );
}

async function _pairForTestWithCtx(
  appPeerId: string,
  connectCtx: { ui: { notify: ReturnType<typeof vi.fn> }; cwd?: string; abort?: ReturnType<typeof vi.fn> },
): Promise<void> {
  captureHandler("remote-pi");
  await _connectForTest(connectCtx);
  relayRef.current!.emit("message", JSON.stringify({
    peer: appPeerId,
    ct: Buffer.from(JSON.stringify({
      type: "pair_request", id: "req-1", token: "test-token", device_name: "Phone",
    })).toString("base64"),
  }));
  await vi.waitFor(() => expect(_getState()).toBe("paired"), { timeout: 2000 });
}

// ── Multi-channel (plan/24 W2D) ──────────────────────────────────────────────
//
// These tests pin down the new contract: N owners can be connected at the
// same time; broadcast events (agent_chunk, tool_*) fan out; per-request
// replies (session_history, cancelled, pong) go back only to the sender;
// revoking or disconnecting one owner doesn't affect the others.

describe("multi-channel broadcast (W2D)", () => {
  beforeEach(async () => {
    vi.clearAllMocks();
    _knownPeers.length = 0;
    _addedPeers.length = 0;
    _removedPeers.length = 0;
    _consumeCalls.length = 0;
    _setRelayCalls.length = 0;
    _savedRelayUrl = null;
    _tokenStatus = "ok";
    relayRef.current = null;
    relayInstances.length = 0;
    _defaultConnectImpl = async () => undefined;
    const qr = await import("./pairing/qr.js");
    (qr.qrSession.consumeToken as unknown as ReturnType<typeof vi.fn>).mockImplementation(
      (token: string) => { _consumeCalls.push(token); return _tokenStatus; },
    );
    const stop = captureHandler("remote-pi stop");
    await stop("", makeMockCtx());
  });

  test("two owners pair simultaneously → both attach (catch-22 fixed)", async () => {
    await _pairForTest("ownerA__1234567890");
    await _pairAdditionalForTest("ownerB__abcdefghij", "Android");
    expect(_getActivePeerCountForTest()).toBe(2);
    expect(_hasActivePeerForTest("ownerA__1234567890")).toBe(true);
    expect(_hasActivePeerForTest("ownerB__abcdefghij")).toBe(true);
  });

  test("/remote-pi pair without config (idle, first-time) → warns + no QR", async () => {
    // Isolated empty cwd → no local config on every OS, so we expect the
    // focused first-time message instead of an auto-bootstrap. (Fresh tmpdir —
    // see the "pair without start" test for the cross-platform rationale.)
    expect(_getState()).toBe("idle");
    const cwd = mkdtempSync(join(tmpdir(), "pi-ext-cwd-"));
    const pair = captureHandler("remote-pi pair");
    const ctx = makeMockCtx(cwd);
    await pair("", ctx);

    const calls = ctx.ui.notify.mock.calls.map((c) => c[0] as string);
    expect(calls.some((m) => m.includes("First-time setup needed"))).toBe(true);
    expect(calls.every((m) => !m.includes("QR ready"))).toBe(true);
    rmSync(cwd, { recursive: true, force: true });
  });

  test("/remote-pi pair generates QR even when an owner is already attached", async () => {
    await _pairForTest("ownerA__1234567890");
    expect(_getActivePeerCountForTest()).toBe(1);

    // QR generation must succeed (no "Already paired" rejection).
    const pair = captureHandler("remote-pi pair");
    const ctx = makeMockCtx();
    await pair("", ctx);

    // Should have notified about a QR being ready, not warned about
    // an existing pairing.
    const calls = ctx.ui.notify.mock.calls.map((c) => c[0] as string);
    expect(calls.some((m) => m.includes("QR ready"))).toBe(true);
    expect(calls.every((m) => !m.includes("Already paired"))).toBe(true);
  });

  test("agent_chunk broadcasts to every attached owner", async () => {
    await _pairForTest("ownerA__1234567890");
    await _pairAdditionalForTest("ownerB__abcdefghij", "Android");

    // Trigger an agent_chunk via the SDK message_update hook. The captured
    // handlers expect `AnyEvent`; cast since we control the test payload.
    const onUpdate = captureEventHandler("message_update");
    const onInput = captureEventHandler("input");
    // Seed _currentTurnId by simulating a terminal input first.
    onInput({ source: "terminal", text: "hello" } as unknown as Parameters<typeof onInput>[0]);
    const sendsBefore = relayRef.current!.send.mock.calls.length;
    onUpdate({ assistantMessageEvent: { type: "text_delta", delta: "hi" } } as unknown as Parameters<typeof onUpdate>[0]);

    const sent = relayRef.current!.send.mock.calls.slice(sendsBefore)
      .map((c) => c[0] as string).map(decodeSentCt);
    const chunks = sent.filter((d) => d.inner.type === "agent_chunk");
    // One for each attached owner.
    expect(chunks).toHaveLength(2);
    const recipients = new Set(chunks.map((d) => d.peer));
    expect(recipients).toEqual(new Set(["ownerA__1234567890", "ownerB__abcdefghij"]));
  });

  test("session_sync from owner A → session_history reply only to A", async () => {
    await _pairForTest("ownerA__1234567890");
    await _pairAdditionalForTest("ownerB__abcdefghij", "Android");
    const sendsBefore = relayRef.current!.send.mock.calls.length;

    // Owner A asks for history.
    relayRef.current!.emit("message", JSON.stringify({
      peer: "ownerA__1234567890",
      ct: Buffer.from(JSON.stringify({
        type: "session_sync", id: "sync-1", limit: 50,
      })).toString("base64"),
    }));
    // Let the handler run.
    await new Promise<void>((r) => setImmediate(r));

    const sent = relayRef.current!.send.mock.calls.slice(sendsBefore)
      .map((c) => c[0] as string).map(decodeSentCt);
    const histories = sent.filter((d) => d.inner.type === "session_history");
    expect(histories).toHaveLength(1);
    expect(histories[0]!.peer).toBe("ownerA__1234567890");
  });

  test("revoke of owner A → A's channel closed, B keeps running", async () => {
    await _pairForTest(OWNER_STANDARD_FIXTURE);
    await _pairAdditionalForTest(OTHER_OWNER_STANDARD_FIXTURE, "Android");

    const revoke = captureHandler("remote-pi revoke");
    await revoke(OWNER_STANDARD_FIXTURE.slice(0, 8), makeMockCtx());

    expect(_hasActivePeerForTest(OWNER_STANDARD_FIXTURE)).toBe(false);
    expect(_hasActivePeerForTest(OTHER_OWNER_STANDARD_FIXTURE)).toBe(true);
    expect(_getState()).toBe("paired");  // derived: at least one owner still on
  });

  // ── Source-of-truth rebroadcast (plan/24 W2D fix) ──────────────────────────
  //
  // When app A sends a user_message, the Pi must echo it to every
  // _activePeers entry (A included) after the SDK accepts the handoff.
  // App side renders from the echo, not from local optimistic state — keeps
  // every paired device's session view bit-identical.

  test("user_message from A → rebroadcast reaches both A and B (with id preserved)", async () => {
    await _pairForTest("ownerA__1234567890");
    await _pairAdditionalForTest("ownerB__abcdefghij", "Android");
    const sendsBefore = relayRef.current!.send.mock.calls.length;

    // Owner A sends user_message with a stable id.
    relayRef.current!.emit("message", JSON.stringify({
      peer: "ownerA__1234567890",
      ct: Buffer.from(JSON.stringify({
        type: "user_message", id: "msg-123", text: "oi",
      })).toString("base64"),
    }));
    // Flush microtasks so the route handler runs.
    await new Promise<void>((r) => setImmediate(r));

    const sent = relayRef.current!.send.mock.calls.slice(sendsBefore)
      .map((c) => c[0] as string).map(decodeSentCt);
    const echoes = sent.filter((d) => d.inner.type === "user_message");
    expect(echoes).toHaveLength(2);
    // id must be the sender's verbatim — Pi must not re-generate.
    for (const e of echoes) {
      expect(e.inner).toMatchObject({ type: "user_message", id: "msg-123", text: "oi" });
    }
    // Both owners received the echo (sender included).
    const recipients = new Set(echoes.map((d) => d.peer));
    expect(recipients).toEqual(new Set(["ownerA__1234567890", "ownerB__abcdefghij"]));
  });

  test("queued_message_set while working broadcasts editable queue and targeted clear", async () => {
    await _pairForTest("ownerA__1234567890");
    await _pairAdditionalForTest("ownerB__abcdefghij", "Android");
    const harness = captureEventHarness();
    const onInput = harness.handler("input");
    onInput({ type: "input", text: "primary", source: "interactive" });
    await new Promise<void>((r) => setImmediate(r));

    const sendUserMessage = vi.fn();
    _setPiForTest({ sendUserMessage, sendMessage: () => undefined });
    const sendsBefore = relayRef.current!.send.mock.calls.length;

    relayRef.current!.emit("message", JSON.stringify({
      peer: "ownerA__1234567890",
      ct: Buffer.from(JSON.stringify({
        type: "queued_message_set", id: "q1", text: " next ",
      })).toString("base64"),
    }));
    await new Promise<void>((r) => setImmediate(r));

    expect(sendUserMessage).not.toHaveBeenCalled();
    let sent = relayRef.current!.send.mock.calls.slice(sendsBefore)
      .map((c) => c[0] as string).map(decodeSentCt);
    const states = sent.filter((d) => d.inner.type === "queued_message_state");
    expect(states).toHaveLength(2);
    expect(new Set(states.map((d) => d.peer))).toEqual(new Set(["ownerA__1234567890", "ownerB__abcdefghij"]));
    for (const state of states) {
      expect(state.inner).toMatchObject({
        type: "queued_message_state",
        id: "q1",
        text: "next",
        items: [expect.objectContaining({ id: "q1", text: "next", editable: true })],
      });
    }

    const syncBefore = relayRef.current!.send.mock.calls.length;
    relayRef.current!.emit("message", JSON.stringify({
      peer: "ownerA__1234567890",
      ct: Buffer.from(JSON.stringify({ type: "session_sync", id: "sync-q", limit: 50 })).toString("base64"),
    }));
    await new Promise<void>((r) => setImmediate(r));
    sent = relayRef.current!.send.mock.calls.slice(syncBefore)
      .map((c) => c[0] as string).map(decodeSentCt);
    expect(sent[0]?.inner.type).toBe("queued_message_state");
    expect(sent[1]?.inner.type).toBe("session_history");

    const clearBefore = relayRef.current!.send.mock.calls.length;
    relayRef.current!.emit("message", JSON.stringify({
      peer: "ownerA__1234567890",
      ct: Buffer.from(JSON.stringify({
        type: "queued_message_clear", id: "clear-q", target_id: "q1",
      })).toString("base64"),
    }));
    await new Promise<void>((r) => setImmediate(r));
    sent = relayRef.current!.send.mock.calls.slice(clearBefore)
      .map((c) => c[0] as string).map(decodeSentCt);
    expect(sent.filter((d) => d.inner.type === "queued_message_state").every((d) => (
      Array.isArray(d.inner.items) && d.inner.items.length === 0
    ))).toBe(true);
  });

  test("queued_message_set while idle drains immediately as a normal user turn", async () => {
    await _pairForTest("ownerA__1234567890");
    await _pairAdditionalForTest("ownerB__abcdefghij", "Android");
    const sendUserMessage = vi.fn();
    _setPiForTest({ sendUserMessage, sendMessage: () => undefined });
    const sendsBefore = relayRef.current!.send.mock.calls.length;

    relayRef.current!.emit("message", JSON.stringify({
      peer: "ownerA__1234567890",
      ct: Buffer.from(JSON.stringify({
        type: "queued_message_set", id: "q-idle", text: "after this",
      })).toString("base64"),
    }));
    await new Promise<void>((r) => setImmediate(r));

    expect(sendUserMessage).toHaveBeenCalledWith("after this", { deliverAs: "steer" });
    expect(_getCurrentTurnIdForTest()).toBe("q-idle");
    const sent = relayRef.current!.send.mock.calls.slice(sendsBefore)
      .map((c) => c[0] as string).map(decodeSentCt);
    const lastState = sent.filter((d) => d.inner.type === "queued_message_state").at(-1);
    expect(lastState?.inner.items).toEqual([]);
    const echoes = sent.filter((d) => d.inner.type === "user_message");
    expect(echoes).toHaveLength(2);
    for (const echo of echoes) {
      expect(echo.inner).toMatchObject({ type: "user_message", id: "q-idle", text: "after this" });
      expect(echo.inner).not.toHaveProperty("streaming_behavior");
    }
  });

  test("queued drain waits for both agent_end and turn_end regardless of ordering", async () => {
    await _pairForTest("ownerA__1234567890");
    const harness = captureEventHarness();
    const sendUserMessage = vi.fn();
    _setPiForTest({ sendUserMessage, sendMessage: () => undefined });

    harness.handler("input")({ type: "input", text: "primary", source: "interactive" });
    harness.handler("turn_start")({ type: "turn_start", turnIndex: 0, timestamp: 0 });
    await new Promise<void>((r) => setImmediate(r));
    const sendsBeforeA = relayRef.current!.send.mock.calls.length;
    relayRef.current!.emit("message", JSON.stringify({
      peer: "ownerA__1234567890",
      ct: Buffer.from(JSON.stringify({ type: "queued_message_set", id: "q-order-a", text: "after A" })).toString("base64"),
    }));
    await new Promise<void>((r) => setImmediate(r));
    expect(sendUserMessage).not.toHaveBeenCalledWith("after A", undefined);

    harness.handler("agent_end")({ type: "agent_end" });
    expect(sendUserMessage).not.toHaveBeenCalledWith("after A", { deliverAs: "steer" });
    harness.handler("turn_end")({ type: "turn_end", turnIndex: 0, timestamp: 0 });
    expect(sendUserMessage).toHaveBeenCalledWith("after A", { deliverAs: "steer" });
    const statesA = relayRef.current!.send.mock.calls.slice(sendsBeforeA)
      .map((c) => c[0] as string).map(decodeSentCt)
      .filter((d) => d.inner.type === "queued_message_state");
    expect(statesA.at(-1)?.inner.items).toEqual([]);

    sendUserMessage.mockClear();
    harness.handler("input")({ type: "input", text: "primary 2", source: "interactive" });
    harness.handler("turn_start")({ type: "turn_start", turnIndex: 1, timestamp: 1 });
    await new Promise<void>((r) => setImmediate(r));
    const sendsBeforeB = relayRef.current!.send.mock.calls.length;
    relayRef.current!.emit("message", JSON.stringify({
      peer: "ownerA__1234567890",
      ct: Buffer.from(JSON.stringify({ type: "queued_message_set", id: "q-order-b", text: "after B" })).toString("base64"),
    }));
    await new Promise<void>((r) => setImmediate(r));
    harness.handler("turn_end")({ type: "turn_end", turnIndex: 1, timestamp: 1 });
    expect(sendUserMessage).not.toHaveBeenCalledWith("after B", { deliverAs: "steer" });
    harness.handler("agent_end")({ type: "agent_end" });
    expect(sendUserMessage).toHaveBeenCalledWith("after B", { deliverAs: "steer" });
    const statesB = relayRef.current!.send.mock.calls.slice(sendsBeforeB)
      .map((c) => c[0] as string).map(decodeSentCt)
      .filter((d) => d.inner.type === "queued_message_state");
    expect(statesB.at(-1)?.inner.items).toEqual([]);
  });

  test("queued drain restores item on synchronous sendUserMessage rejection", async () => {
    await _pairForTest("ownerA__1234567890");
    _setPiForTest({
      sendUserMessage: vi.fn(() => { throw new Error("queue rejected"); }),
      sendMessage: () => undefined,
    });
    const sendsBefore = relayRef.current!.send.mock.calls.length;

    relayRef.current!.emit("message", JSON.stringify({
      peer: "ownerA__1234567890",
      ct: Buffer.from(JSON.stringify({
        type: "queued_message_set", id: "q-fail", text: "after fail",
      })).toString("base64"),
    }));
    await new Promise<void>((r) => setImmediate(r));

    const sent = relayRef.current!.send.mock.calls.slice(sendsBefore)
      .map((c) => c[0] as string).map(decodeSentCt);
    expect(sent.some((d) => d.inner.type === "user_message" && d.inner.id === "q-fail")).toBe(false);
    expect(sent.find((d) => d.inner.type === "error")?.inner).toMatchObject({
      type: "error",
      code: "internal_error",
      in_reply_to: "q-fail",
    });
    const lastState = sent.filter((d) => d.inner.type === "queued_message_state").at(-1);
    expect(lastState?.inner).toMatchObject({
      type: "queued_message_state",
      id: "q-fail",
      text: "after fail",
      items: [expect.objectContaining({ id: "q-fail", text: "after fail" })],
    });
  });

  test("plan/30: user_message with an image → save preview + send metadata-only custom message", async () => {
    await _pairForTest("ownerA__1234567890");
    // Override _pi with a spy to capture the multimodal content sent to the SDK.
    const sentToAgent: unknown[] = [];
    const sentMessages: Array<[unknown, ...unknown[]]> = [];
    const timeline: string[] = [];
    const messageId = "msg with spaces/and##symbols";
    _setPiForTest({
      sendUserMessage: (c: unknown) => { timeline.push("agent"); sentToAgent.push(c); },
      sendMessage: (...messageArgs) => { timeline.push("preview"); sentMessages.push(messageArgs); },
    });
    const sendsBefore = relayRef.current!.send.mock.calls.length;

    relayRef.current!.emit("message", JSON.stringify({
      peer: "ownerA__1234567890",
      ct: Buffer.from(JSON.stringify({
        type: "user_message",
        id: messageId,
        text: "what is this?",
        images: [{ data: "QUJD", mime: "image/png" }],
      })).toString("base64"),
    }));
    await new Promise<void>((r) => setImmediate(r));

    // Preview is appended before SDK handoff so it cannot steer this turn.
    expect(timeline).toEqual(["preview", "agent"]);
    expect(sentToAgent).toHaveLength(1);
    expect(sentToAgent[0]).toEqual([
      { type: "image", data: "QUJD", mimeType: "image/png" },
      { type: "text", text: "what is this?" },
    ]);

    const previewCall = sentMessages.find((message) => {
      const current = message[0] as { customType?: unknown };
      return current.customType === "remote-pi:received-image";
    });
    const preview = previewCall?.[0] as { content?: string; display?: boolean; details?: { messageId?: string; mime?: string; path?: string; size?: number; index?: number; text?: string; error?: string; reason?: string } } | undefined;
    expect(preview).toBeDefined();
    expect(previewCall?.[1]).toBeUndefined();
    expect(preview?.content).toBe("");
    expect(preview?.display).toBe(true);
    expect(preview?.details).toMatchObject({
      messageId,
      index: 0,
      mime: "image/png",
      size: 3,
      text: "what is this?",
    });
    expect(preview?.details).not.toHaveProperty("data");
    expect(preview?.details?.error).toBeUndefined();
    expect(preview?.details?.reason).toBeUndefined();

    const expectedBasename = "msg-with-spaces-and-symbols-0.png";
    expect(preview?.details?.path).toContain(tmpdir());
    expect(preview?.details?.path).toContain("pi-app-");
    expect(readFileSync(preview!.details!.path!, "utf8")).toBe("ABC");
    expect(basename(preview?.details?.path ?? "")).toBe(expectedBasename);
    if (preview?.details?.path && process.platform !== "win32") {
      const st = statSync(preview.details.path);
      expect(st.mode & 0o777).toBe(0o600);
      const stDir = statSync(dirname(preview.details.path));
      expect(stDir.mode & 0o777).toBe(0o700);
    }

    // The echo carries `images` so other owners render the bubble.
    const sent = relayRef.current!.send.mock.calls.slice(sendsBefore)
      .map((c) => c[0] as string).map(decodeSentCt);
    const echo = sent.find((d) => d.inner.type === "user_message");
    expect(echo?.inner).toMatchObject({
      type: "user_message", id: messageId, text: "what is this?",
      images: [{ data: "QUJD", mime: "image/png" }],
    });
  });

  test("JPEG user_message generates optional private PNG preview when converter is available", async () => {
    _convertToPngMock.mockResolvedValueOnce({ data: "iVBORw0KGgo=", mimeType: "image/png" });

    await _pairForTest("ownerA__1234567890");
    const sentMessages: Array<[unknown, ...unknown[]]> = [];
    _setPiForTest({
      sendUserMessage: () => undefined,
      sendMessage: (...messageArgs) => { sentMessages.push(messageArgs); },
    });

    relayRef.current!.emit("message", JSON.stringify({
      peer: "ownerA__1234567890",
      ct: Buffer.from(JSON.stringify({
        type: "user_message",
        id: "jpeg-msg",
        text: "jpeg caption",
        images: [{ data: "QUJD", mime: "image/jpeg" }],
      })).toString("base64"),
    }));
    await new Promise<void>((r) => setImmediate(r));

    const previewCall = sentMessages.find((message) => {
      const current = message[0] as { customType?: unknown };
      return current.customType === "remote-pi:received-image";
    });
    const preview = previewCall?.[0] as { details?: { path?: string; previewPath?: string } } | undefined;
    const previewPath = preview?.details?.previewPath;
    expect(preview?.details?.path).toContain("jpeg-msg-0.jpg");
    expect(previewPath).toContain("jpeg-msg-0.preview.png");
    expect(readFileSync(previewPath!)).toEqual(Buffer.from("89504e470d0a1a0a", "hex"));
    if (process.platform !== "win32") {
      expect(statSync(previewPath!).mode & 0o777).toBe(0o600);
    }
  });

  test("converted preview output over 10 MiB falls back to saved original only", async () => {
    _convertToPngMock.mockResolvedValueOnce({
      data: Buffer.alloc(10 * 1024 * 1024 + 1).toString("base64"),
      mimeType: "image/png",
    });

    await _pairForTest("ownerA__1234567890");
    const sentMessages: Array<[unknown, ...unknown[]]> = [];
    _setPiForTest({
      sendUserMessage: () => undefined,
      sendMessage: (...messageArgs) => { sentMessages.push(messageArgs); },
    });

    relayRef.current!.emit("message", JSON.stringify({
      peer: "ownerA__1234567890",
      ct: Buffer.from(JSON.stringify({
        type: "user_message",
        id: "jpeg-big-preview",
        text: "jpeg caption",
        images: [{ data: "QUJD", mime: "image/jpeg" }],
      })).toString("base64"),
    }));
    await new Promise<void>((r) => setImmediate(r));

    const previewCall = sentMessages.find((message) => {
      const current = message[0] as { customType?: unknown };
      return current.customType === "remote-pi:received-image";
    });
    const preview = previewCall?.[0] as { details?: { path?: string; previewPath?: string } } | undefined;
    expect(preview?.details?.path).toContain("jpeg-big-preview-0.jpg");
    expect(preview?.details?.previewPath).toBeUndefined();
  });

  test("active image steering defers local preview until agent_end", async () => {
    await _pairForTest("ownerA__1234567890");
    const onInput = captureEventHandler("input");
    const onAgentEnd = captureEventHandler("agent_end");
    onInput({ type: "input", text: "already running", source: "interactive" });

    const sentToAgent: unknown[] = [];
    const sentMessages: Array<[unknown, ...unknown[]]> = [];
    _setPiForTest({
      sendUserMessage: (content: unknown) => { sentToAgent.push(content); },
      sendMessage: (...messageArgs) => { sentMessages.push(messageArgs); },
    });

    relayRef.current!.emit("message", JSON.stringify({
      peer: "ownerA__1234567890",
      ct: Buffer.from(JSON.stringify({
        type: "user_message",
        id: "steer-image",
        text: "extra photo",
        streaming_behavior: "steer",
        images: [{ data: "QUJD", mime: "image/png" }],
      })).toString("base64"),
    }));
    await new Promise<void>((r) => setImmediate(r));

    expect(sentToAgent).toHaveLength(1);
    expect(sentMessages).toHaveLength(0);

    onAgentEnd({ type: "agent_end", messages: [] });
    expect(sentMessages).toHaveLength(1);
    expect((sentMessages[0][0] as { customType?: unknown }).customType).toBe("remote-pi:received-image");
  });

  test("slow idle JPEG conversion defers preview if another turn starts first", async () => {
    let resolveConversion: ((value: { data: string; mimeType: string }) => void) | undefined;
    _convertToPngMock.mockReturnValueOnce(new Promise((resolve) => {
      resolveConversion = resolve;
    }));

    await _pairForTest("ownerA__1234567890");
    const onInput = captureEventHandler("input");
    const onAgentEnd = captureEventHandler("agent_end");
    const sentMessages: Array<[unknown, ...unknown[]]> = [];
    _setPiForTest({
      sendUserMessage: () => undefined,
      sendMessage: (...messageArgs) => { sentMessages.push(messageArgs); },
    });

    relayRef.current!.emit("message", JSON.stringify({
      peer: "ownerA__1234567890",
      ct: Buffer.from(JSON.stringify({
        type: "user_message",
        id: "slow-jpeg",
        text: "slow photo",
        images: [{ data: "QUJD", mime: "image/jpeg" }],
      })).toString("base64"),
    }));
    await vi.waitFor(() => expect(_convertToPngMock).toHaveBeenCalled());

    onInput({ type: "input", text: "overtaking local turn", source: "interactive" });
    resolveConversion?.({ data: "iVBORw0KGgo=", mimeType: "image/png" });
    await new Promise<void>((r) => setImmediate(r));

    expect(sentMessages).toHaveLength(0);

    onAgentEnd({ type: "agent_end", messages: [] });
    expect(sentMessages).toHaveLength(1);
    expect((sentMessages[0][0] as { customType?: unknown }).customType).toBe("remote-pi:received-image");
  });

  test("received-image preview messages are filtered out of provider and compaction context", () => {
    const previewMessage = { role: "custom", customType: "remote-pi:received-image", content: "", display: true, details: { path: "/tmp/photo.png" } };
    const keepCustom = { role: "custom", customType: "other-ext:visible", content: "keep", display: true };
    const keepUser = { role: "user", content: "hello" };

    const onContext = captureEventHandler("context");
    const result = onContext({
      type: "context",
      messages: [keepCustom, previewMessage, keepUser],
    }) as { messages?: unknown[] };
    expect(result.messages).toEqual([keepCustom, keepUser]);

    const onBeforeCompact = captureEventHandler("session_before_compact");
    const preparation = {
      messagesToSummarize: [previewMessage, keepUser],
      turnPrefixMessages: [keepCustom, previewMessage],
    };
    onBeforeCompact({
      type: "session_before_compact",
      preparation,
      branchEntries: [],
      reason: "manual",
      willRetry: false,
      signal: new AbortController().signal,
    });
    expect(preparation.messagesToSummarize).toEqual([keepUser]);
    expect(preparation.turnPrefixMessages).toEqual([keepCustom]);
  });

  test("pure-data (display:false) remote-pi events are filtered out of provider and compaction context", () => {
    // Issue #105: display:false only hides from the TUI; the entry still enters
    // the LLM context, so relay flaps / name collisions were replayed to the
    // model on every call.
    const relayState = { role: "custom", customType: "remote-pi:relay-state", content: "Relay connected", display: false };
    const nameAssigned = { role: "custom", customType: "remote-pi:name-assigned", content: "Session name assigned", display: false };
    const paired = { role: "custom", customType: "remote-pi:paired", content: "Paired with Phone", display: false };
    const keepCustom = { role: "custom", customType: "other-ext:visible", content: "keep", display: true };
    const keepForeign = { role: "custom", customType: "other-ext:data", content: "keep", display: false };
    const keepUser = { role: "user", content: "hello" };

    const onContext = captureEventHandler("context");
    const result = onContext({
      type: "context",
      messages: [relayState, keepCustom, nameAssigned, keepForeign, paired, keepUser],
    }) as { messages?: unknown[] };
    expect(result.messages).toEqual([keepCustom, keepForeign, keepUser]);

    const onBeforeCompact = captureEventHandler("session_before_compact");
    const preparation = {
      messagesToSummarize: [relayState, keepUser],
      turnPrefixMessages: [paired, keepCustom],
    };
    onBeforeCompact({
      type: "session_before_compact",
      preparation,
      branchEntries: [],
      reason: "manual",
      willRetry: false,
      signal: new AbortController().signal,
    });
    expect(preparation.messagesToSummarize).toEqual([keepUser]);
    expect(preparation.turnPrefixMessages).toEqual([keepCustom]);
  });

  test("registers and uses remote-pi image renderer with Saved fallback", () => {
    const { getRenderer } = captureMessageRenderer();
    const theme = {
      fg: (token: string, text: string) => `${token}:${text}`,
      bg: (token: string, text: string) => `${token}:${text}`,
    };
    const dir = mkdtempSync(join(tmpdir(), "pi-ext-render-missing-"));
    const message = {
      customType: "remote-pi:received-image",
      content: "",
      display: true,
      details: {
        messageId: "msg-missing",
        index: 2,
        path: join(dir, "missing.png"),
        mime: "image/png",
        size: 123,
        error: "missing file",
        reason: "not present on disk",
      },
    };
    const renderer = getRenderer();
    const component = renderer(message, { expanded: false }, theme);
    const rendered = (component as { render: (width: number) => string[] }).render(120).join("\n");
    expect(rendered).toContain("📷 Photo from Android (msg-missing #2)");
    expect(rendered).toContain("Saved: ");
    expect(rendered).toContain(message.details.path);
    expect(rendered).toContain("Error: missing file");
    rmSync(dir, { recursive: true, force: true });
  });

  test("renders JPEG inline when previewPath points to generated PNG", () => {
    const { getRenderer } = captureMessageRenderer();
    const theme = {
      fg: (token: string, text: string) => `${token}:${text}`,
      bg: (token: string, text: string) => `${token}:${text}`,
    };
    const dir = mkdtempSync(join(tmpdir(), "pi-ext-render-jpeg-preview-"));
    const imagePath = join(dir, "photo.jpg");
    const previewPath = join(dir, "photo.preview.png");

    writeFileSync(imagePath, Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x46, 0x49, 0x46]));
    writeFileSync(previewPath, Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]));

    const prevCaps = getCapabilities();
    const message = {
      customType: "remote-pi:received-image",
      content: "",
      display: true,
      details: {
        messageId: "msg-jpeg-preview",
        index: 2,
        path: imagePath,
        previewPath,
        mime: "image/jpeg",
        size: 10,
      },
    };
    setCapabilities({ ...prevCaps, images: "kitty" as const });

    try {
      const renderer = getRenderer();
      const component = renderer(message, { expanded: false }, theme);
      const renderedLines = (component as { render: (width: number) => string[] }).render(120);
      const rendered = renderedLines.join("\n");
      const imageLineIndex = renderedLines.findIndex((line) => line.includes("\x1b_G"));
      expect(rendered).toContain("📷 Photo from Android (msg-jpeg-preview #2)");
      expect(imageLineIndex).toBeGreaterThanOrEqual(0);
      expect(renderedLines.slice(imageLineIndex + 1).some((line) => line === "")).toBe(true);
      expect(rendered).toContain(imagePath);
    } finally {
      setCapabilities(prevCaps);
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("plan/30: user_message without images → no `images` key on the echo (text path unchanged)", async () => {
    await _pairForTest("ownerA__1234567890");
    const sendUserMessage = vi.fn();
    _setPiForTest({
      sendUserMessage,
      sendMessage: () => undefined,
    });
    const sendsBefore = relayRef.current!.send.mock.calls.length;
    relayRef.current!.emit("message", JSON.stringify({
      peer: "ownerA__1234567890",
      ct: Buffer.from(JSON.stringify({
        type: "user_message", id: "msg-txt", text: "hi",
      })).toString("base64"),
    }));
    await new Promise<void>((r) => setImmediate(r));
    expect(sendUserMessage).toHaveBeenCalledWith("hi", { deliverAs: "steer" });
    const sent = relayRef.current!.send.mock.calls.slice(sendsBefore)
      .map((c) => c[0] as string).map(decodeSentCt);
    const echo = sent.find((d) => d.inner.type === "user_message");
    expect(echo?.inner).toMatchObject({ type: "user_message", id: "msg-txt", text: "hi" });
    expect(echo?.inner).not.toHaveProperty("images");
    expect(echo?.inner).not.toHaveProperty("streaming_behavior");
  });

  test(
    "plan/43: active steering calls sendUserMessage(deliverAs='steer')",
    async () => {
      await _pairForTest("ownerA__1234567890");
      const onInput = captureEventHandler("input");
      onInput({ type: "input", text: "primary", source: "interactive" });
      await new Promise<void>((r) => setImmediate(r));

      const sendUserMessage = vi.fn();
      _setPiForTest({
        sendUserMessage,
        sendMessage: () => undefined,
      });
      const sendsBefore = relayRef.current!.send.mock.calls.length;

      relayRef.current!.emit("message", JSON.stringify({
        peer: "ownerA__1234567890",
        ct: Buffer.from(JSON.stringify({
          type: "user_message",
          id: "msg-steer",
          text: "refine this",
          streaming_behavior: "steer",
        })).toString("base64"),
      }));
      await new Promise<void>((r) => setImmediate(r));

      expect(sendUserMessage).toHaveBeenCalledTimes(1);
      expect(sendUserMessage).toHaveBeenCalledWith("refine this", { deliverAs: "steer" });
      const sent = relayRef.current!.send.mock.calls.slice(sendsBefore)
        .map((c) => c[0] as string).map(decodeSentCt);
      const echo = sent.find((d) => d.inner.type === "user_message");
      expect(echo?.inner).toMatchObject({
        type: "user_message",
        id: "msg-steer",
        text: "refine this",
        streaming_behavior: "steer",
      });
    },
  );

  test("plan/43: persisted user message clears the oldest pending steer", async () => {
    await _pairForTest("ownerA__1234567890");
    const sendUserMessage = vi.fn();
    _setPiForTest({
      sendUserMessage,
      sendMessage: () => undefined,
    });
    const onMessageEnd = captureEventHandler("message_end");
    const sendsBefore = relayRef.current!.send.mock.calls.length;

    relayRef.current!.emit("message", JSON.stringify({
      peer: "ownerA__1234567890",
      ct: Buffer.from(JSON.stringify({
        type: "user_message",
        id: "msg-steer-end-consumed",
        text: "consume this persisted steer",
        streaming_behavior: "steer",
      })).toString("base64"),
    }));
    await new Promise<void>((r) => setImmediate(r));
    expect(_getPendingSteerIdsForTest("consume this persisted steer")).toEqual(["msg-steer-end-consumed"]);

    onMessageEnd({
      type: "message_end",
      message: {
        role: "user",
        content: [{ type: "text", text: "consume this persisted steer" }],
        timestamp: Date.now(),
      },
    });
    await new Promise<void>((r) => setImmediate(r));
    expect(_getPendingSteerIdsForTest("consume this persisted steer")).toEqual([]);

    const sent = relayRef.current!.send.mock.calls.slice(sendsBefore)
      .map((c) => c[0] as string).map(decodeSentCt);
    expect(sent.some((d) => (
      d.inner.type === "steer_consumed" && d.inner.id === "msg-steer-end-consumed"
    ))).toBe(true);
  });

  test("plan/43: started user message clears the oldest pending steer", async () => {
    await _pairForTest("ownerA__1234567890");
    const sendUserMessage = vi.fn();
    _setPiForTest({
      sendUserMessage,
      sendMessage: () => undefined,
    });
    const onMessageStart = captureEventHandler("message_start");
    const sendsBefore = relayRef.current!.send.mock.calls.length;

    relayRef.current!.emit("message", JSON.stringify({
      peer: "ownerA__1234567890",
      ct: Buffer.from(JSON.stringify({
        type: "user_message",
        id: "msg-steer-consumed",
        text: "consume this exact steer",
        streaming_behavior: "steer",
      })).toString("base64"),
    }));
    await new Promise<void>((r) => setImmediate(r));
    expect(_getPendingSteerIdsForTest("consume this exact steer")).toEqual(["msg-steer-consumed"]);

    onMessageStart({
      type: "message_start",
      message: {
        role: "user",
        content: [{ type: "text", text: "SDK-rendered text differed" }],
        timestamp: Date.now(),
      },
    });
    await new Promise<void>((r) => setImmediate(r));
    expect(_getPendingSteerIdsForTest("consume this exact steer")).toEqual([]);
    expect(_getActivePeerCountForTest()).toBe(1);

    const sent = relayRef.current!.send.mock.calls.slice(sendsBefore)
      .map((c) => c[0] as string).map(decodeSentCt);
    expect(sent.some((d) => (
      d.inner.type === "steer_consumed" && d.inner.id === "msg-steer-consumed"
    ))).toBe(true);
  });

  test("plan/43: message_start plus message_end consumes one steer only", async () => {
    await _pairForTest("ownerA__1234567890");
    _setPiForTest({
      sendUserMessage: vi.fn(),
      sendMessage: () => undefined,
    });
    const onMessageStart = captureEventHandler("message_start");
    const onMessageEnd = captureEventHandler("message_end");
    const sendsBefore = relayRef.current!.send.mock.calls.length;

    for (const [id, text] of [["steer-1", "1"], ["steer-2", "2"]]) {
      relayRef.current!.emit("message", JSON.stringify({
        peer: "ownerA__1234567890",
        ct: Buffer.from(JSON.stringify({
          type: "user_message",
          id,
          text,
          streaming_behavior: "steer",
        })).toString("base64"),
      }));
    }
    await new Promise<void>((r) => setImmediate(r));

    const event = {
      type: "message_start",
      message: {
        role: "user",
        content: [{ type: "text", text: "1" }],
        timestamp: Date.now(),
      },
    };
    onMessageStart(event);
    onMessageEnd({ ...event, type: "message_end" });
    await new Promise<void>((r) => setImmediate(r));

    expect(_getPendingSteerIdsForTest("1")).toEqual([]);
    expect(_getPendingSteerIdsForTest("2")).toEqual(["steer-2"]);
    const consumed = relayRef.current!.send.mock.calls.slice(sendsBefore)
      .map((c) => c[0] as string)
      .map(decodeSentCt)
      .filter((d) => d.inner.type === "steer_consumed");
    expect(consumed.map((d) => (d.inner as { id: string }).id)).toEqual(["steer-1"]);
  });

  test("plan/43: steering without a known turn id still reaches SDK as steer", async () => {
    await _pairForTest("ownerA__1234567890");
    expect(_getCurrentTurnIdForTest()).toBeNull();
    const sendUserMessage = vi.fn();
    _setPiForTest({
      sendUserMessage,
      sendMessage: () => undefined,
    });
    const sendsBefore = relayRef.current!.send.mock.calls.length;

    relayRef.current!.emit("message", JSON.stringify({
      peer: "ownerA__1234567890",
      ct: Buffer.from(JSON.stringify({
        type: "user_message",
        id: "msg-stale-steer",
        text: "refine while stale",
        streaming_behavior: "steer",
      })).toString("base64"),
    }));
    await new Promise<void>((r) => setImmediate(r));

    expect(sendUserMessage).toHaveBeenCalledTimes(1);
    expect(sendUserMessage).toHaveBeenCalledWith("refine while stale", { deliverAs: "steer" });
    expect(_getCurrentTurnIdForTest()).toBe("msg-stale-steer");
    const sent = relayRef.current!.send.mock.calls.slice(sendsBefore)
      .map((c) => c[0] as string).map(decodeSentCt);
    const echo = sent.find((d) => d.inner.type === "user_message");
    expect(echo?.inner).toMatchObject({
      type: "user_message",
      id: "msg-stale-steer",
      text: "refine while stale",
      streaming_behavior: "steer",
    });
  });

  test("plan/43: busy app message without wire behavior is defensively steered", async () => {
    await _pairForTest("ownerA__1234567890");
    const onTurnStart = captureEventHandler("turn_start");
    onTurnStart({ type: "turn_start", turnIndex: 0, timestamp: 0 });
    expect(_getCurrentTurnIdForTest()).toBeNull();
    const sendUserMessage = vi.fn();
    _setPiForTest({
      sendUserMessage,
      sendMessage: () => undefined,
    });
    const sendsBefore = relayRef.current!.send.mock.calls.length;

    relayRef.current!.emit("message", JSON.stringify({
      peer: "ownerA__1234567890",
      ct: Buffer.from(JSON.stringify({
        type: "user_message",
        id: "msg-busy-no-mode",
        text: "late correction",
      })).toString("base64"),
    }));
    await new Promise<void>((r) => setImmediate(r));

    expect(sendUserMessage).toHaveBeenCalledTimes(1);
    expect(sendUserMessage).toHaveBeenCalledWith("late correction", { deliverAs: "steer" });
    expect(_getCurrentTurnIdForTest()).toBe("msg-busy-no-mode");
    const sent = relayRef.current!.send.mock.calls.slice(sendsBefore)
      .map((c) => c[0] as string).map(decodeSentCt);
    const echo = sent.find((d) => d.inner.type === "user_message");
    expect(echo?.inner).toMatchObject({
      type: "user_message",
      id: "msg-busy-no-mode",
      text: "late correction",
      streaming_behavior: "steer",
    });
  });

  test("plan/43: steering sendUserMessage throw returns correlated error and no echo", async () => {
    await _pairForTest("ownerA__1234567890");
    const onInput = captureEventHandler("input");
    onInput({ type: "input", text: "primary", source: "interactive" });
    await new Promise<void>((r) => setImmediate(r));
    const priorTurn = _getCurrentTurnIdForTest();
    expect(priorTurn).toMatch(/^local_/);

    _setPiForTest({
      sendUserMessage: vi.fn(() => { throw new Error("steer rejected"); }),
      sendMessage: () => undefined,
    });
    const sendsBefore = relayRef.current!.send.mock.calls.length;

    relayRef.current!.emit("message", JSON.stringify({
      peer: "ownerA__1234567890",
      ct: Buffer.from(JSON.stringify({
        type: "user_message",
        id: "msg-steer-fail",
        text: "bad steer",
        streaming_behavior: "steer",
      })).toString("base64"),
    }));
    await new Promise<void>((r) => setImmediate(r));

    expect(_getCurrentTurnIdForTest()).toBe(priorTurn);
    const sent = relayRef.current!.send.mock.calls.slice(sendsBefore)
      .map((c) => c[0] as string).map(decodeSentCt);
    expect(sent.some((d) => d.inner.type === "user_message" && d.inner.id === "msg-steer-fail")).toBe(false);
    const error = sent.find((d) => d.inner.type === "error");
    expect(error?.inner).toMatchObject({
      type: "error",
      in_reply_to: "msg-steer-fail",
      code: "internal_error",
    });
    expect((error?.inner as { message?: string } | undefined)?.message).toContain("steer rejected");
  });

  test("plan/43: steering does not overwrite current turn id", async () => {
    await _pairForTest("ownerA__1234567890");
    // Seed by terminal input (local user turn) so _currentTurnId exists.
    const onInput = captureEventHandler("input");
    onInput({ type: "input", text: "primary", source: "interactive" });

    // Wait for async input handler effects.
    await new Promise<void>((r) => setImmediate(r));
    expect(_getCurrentTurnIdForTest()).toMatch(/^local_/);
    const priorTurn = _getCurrentTurnIdForTest();
    expect(priorTurn).toBeTruthy();

    _setPiForTest({
      sendUserMessage: () => undefined,
      sendMessage: () => undefined,
    });

    relayRef.current!.emit("message", JSON.stringify({
      peer: "ownerA__1234567890",
      ct: Buffer.from(JSON.stringify({
        type: "user_message",
        id: "msg-steer",
        text: "steer this",
        streaming_behavior: "steer",
      })).toString("base64"),
    }));
    await new Promise<void>((r) => setImmediate(r));

    expect(_getCurrentTurnIdForTest()).toBe(priorTurn);
  });

  test("plan/32: session_compact → broadcasts compaction, working=false, buffers a marker", async () => {
    await _pairForTest("ownerA__1234567890");
    _setMessageBufferForTest([]);
    const onCompact = captureEventHandler("session_compact");
    const sendsBefore = relayRef.current!.send.mock.calls.length;
    const ctrlBefore = relayRef.current!.sendControl.mock.calls.length;

    onCompact({
      type: "session_compact",
      compactionEntry: {
        type: "compaction", summary: "compacted 10 turns", tokensBefore: 12345,
        firstKeptEntryId: "e1", timestamp: "2026-05-31T00:00:00Z",
      },
      fromExtension: false,
    });

    // (1) compaction broadcast reaches the owner
    const sent = relayRef.current!.send.mock.calls.slice(sendsBefore)
      .map((c) => c[0] as string).map(decodeSentCt);
    const compaction = sent.find((d) => d.inner.type === "compaction");
    expect(compaction?.inner).toMatchObject({
      type: "compaction", summary: "compacted 10 turns", tokens_before: 12345,
    });

    // (3) working=false via room_meta_update
    const ctrls = relayRef.current!.sendControl.mock.calls.slice(ctrlBefore)
      .map((c) => c[0] as { type: string; meta?: { working?: boolean } })
      .filter((f) => f.type === "room_meta_update");
    expect(ctrls.some((f) => f.meta?.working === false)).toBe(true);

    // (2) a compaction marker landed in _messageBuffer (survives session_sync)
    const buf = _getMessageBufferForTest() as Array<{ role?: string; content?: unknown; tokensBefore?: number }>;
    expect(buf.some((m) =>
      m.role === "compaction" && m.content === "compacted 10 turns" && m.tokensBefore === 12345,
    )).toBe(true);
  });

  test("provider error (assistant stopReason:error) → forwards `error` to owners (was silent)", async () => {
    await _pairForTest("ownerA__1234567890");
    const onMsgEnd = captureEventHandler("message_end");
    const sendsBefore = relayRef.current!.send.mock.calls.length;

    onMsgEnd({
      type: "message_end",
      message: {
        role: "assistant", stopReason: "error",
        errorMessage: "Provider finish_reason: error", content: [],
      },
    });

    const sent = relayRef.current!.send.mock.calls.slice(sendsBefore)
      .map((c) => c[0] as string).map(decodeSentCt);
    const err = sent.find((d) => d.inner.type === "error");
    expect(err?.inner).toMatchObject({
      type: "error", code: "provider_error", message: "Provider finish_reason: error",
    });
  });

  test("normal assistant turn (stopReason:stop) → no error forwarded", async () => {
    await _pairForTest("ownerA__1234567890");
    const onMsgEnd = captureEventHandler("message_end");
    const sendsBefore = relayRef.current!.send.mock.calls.length;

    onMsgEnd({
      type: "message_end",
      message: { role: "assistant", stopReason: "stop", content: [{ type: "text", text: "done" }] },
    });

    const sent = relayRef.current!.send.mock.calls.slice(sendsBefore)
      .map((c) => c[0] as string).map(decodeSentCt);
    expect(sent.some((d) => d.inner.type === "error")).toBe(false);
  });

  test("rebroadcast happens BEFORE the agent processes the message", async () => {
    // We can't observe SDK ordering directly with the standard mockPi, but
    // we can verify the echo fires synchronously after the inner is
    // received — i.e., it's queued onto `relay.send` before any async
    // SDK work resolves. The test asserts at least the order in
    // `relay.send.mock.calls`: user_message echoes precede any reply
    // generated downstream (none expected here since SDK is mocked).
    await _pairForTest("ownerA__1234567890");
    const sendsBefore = relayRef.current!.send.mock.calls.length;

    relayRef.current!.emit("message", JSON.stringify({
      peer: "ownerA__1234567890",
      ct: Buffer.from(JSON.stringify({
        type: "user_message", id: "msg-order-1", text: "order check",
      })).toString("base64"),
    }));
    await new Promise<void>((r) => setImmediate(r));

    const sent = relayRef.current!.send.mock.calls.slice(sendsBefore)
      .map((c) => c[0] as string).map(decodeSentCt);
    // First outbound after the user_message arrives must be the echo.
    expect(sent[0]?.inner).toMatchObject({
      type: "user_message", id: "msg-order-1", text: "order check",
    });
  });

  test("user_message lands in _messageBuffer → session_sync returns it as user_input", async () => {
    // The SDK side normally pushes role="user" entries to the buffer on
    // its `message_end` event. We simulate that effect with the test
    // helper so we can verify session_sync replays correctly.
    await _pairForTest("ownerA__1234567890");

    // Simulate the SDK persisting the user turn.
    _setMessageBufferForTest([
      { role: "user", content: "oi", timestamp: 1700000000000 },
    ]);
    _setSessionStartedAtForTest(1699999999000);

    const sendsBefore = relayRef.current!.send.mock.calls.length;
    relayRef.current!.emit("message", JSON.stringify({
      peer: "ownerA__1234567890",
      ct: Buffer.from(JSON.stringify({
        type: "session_sync", id: "sync-buffer-1", limit: 50,
      })).toString("base64"),
    }));
    await new Promise<void>((r) => setImmediate(r));

    const sent = relayRef.current!.send.mock.calls.slice(sendsBefore)
      .map((c) => c[0] as string).map(decodeSentCt);
    const histories = sent.filter((d) => d.inner.type === "session_history");
    expect(histories).toHaveLength(1);
    const events = (histories[0]!.inner as unknown as { events: unknown[] }).events;
    expect(events).toEqual(expect.arrayContaining([
      expect.objectContaining({ type: "user_input", text: "oi" }),
    ]));
  });
});

describe("user_input mirroring", () => {
  beforeEach(async () => {
    vi.clearAllMocks();
    _knownPeers.length = 0;
    _addedPeers.length = 0;
    _removedPeers.length = 0;
    _consumeCalls.length = 0;
    _setRelayCalls.length = 0;
    _savedRelayUrl = null;
    _tokenStatus = "ok";
    relayRef.current = null;
    const qr = await import("./pairing/qr.js");
    (qr.qrSession.consumeToken as unknown as ReturnType<typeof vi.fn>).mockImplementation(
      (token: string) => {
        _consumeCalls.push(token);
        return _tokenStatus;
      },
    );
    const stop = captureHandler("remote-pi stop");
    await stop("", makeMockCtx());
  });

  test("interactive input → user_input emitted + _currentTurnId set", async () => {
    await _pairForTest("peer-A");
    const sendsBefore = relayRef.current!.send.mock.calls.length;

    const onInput = captureEventHandler("input");
    onInput({ type: "input", text: "listar arquivos", source: "interactive" });

    const sent = relayRef.current!.send.mock.calls.slice(sendsBefore).map((c) => c[0] as string);
    const userInputs = sent.map(decodeSentCt).filter((d) => d.inner.type === "user_input");
    expect(userInputs).toHaveLength(1);
    expect(userInputs[0]!.peer).toBe("peer-A");
    expect(userInputs[0]!.inner).toMatchObject({ type: "user_input", text: "listar arquivos" });
    expect(typeof userInputs[0]!.inner["id"]).toBe("string");
    expect((userInputs[0]!.inner["id"] as string).startsWith("local_")).toBe(true);
  });

  test("extension input → NO user_input emitted (routeClientMessage already handles app turns)", async () => {
    await _pairForTest("peer-B");
    const sendsBefore = relayRef.current!.send.mock.calls.length;

    const onInput = captureEventHandler("input");
    onInput({ type: "input", text: "via app", source: "extension" });

    const sent = relayRef.current!.send.mock.calls.slice(sendsBefore).map((c) => c[0] as string);
    const userInputs = sent.map(decodeSentCt).filter((d) => d.inner.type === "user_input");
    expect(userInputs).toHaveLength(0);
  });

  test("rpc input → user_input emitted (same as interactive)", async () => {
    await _pairForTest("peer-C");
    const sendsBefore = relayRef.current!.send.mock.calls.length;

    const onInput = captureEventHandler("input");
    onInput({ type: "input", text: "remoto via RPC", source: "rpc" });

    const sent = relayRef.current!.send.mock.calls.slice(sendsBefore).map((c) => c[0] as string);
    const userInputs = sent.map(decodeSentCt).filter((d) => d.inner.type === "user_input");
    expect(userInputs).toHaveLength(1);
    expect(userInputs[0]!.inner).toMatchObject({ type: "user_input", text: "remoto via RPC" });
  });

  test("subsequent agent_chunk reuses turnId set by local input", async () => {
    await _pairForTest("peer-D");

    const onInput = captureEventHandler("input");
    onInput({ type: "input", text: "ola", source: "interactive" });

    const sentInputs = relayRef.current!.send.mock.calls.map((c) => c[0] as string);
    const userInputs = sentInputs.map(decodeSentCt).filter((d) => d.inner.type === "user_input");
    const turnId = userInputs[0]!.inner["id"] as string;

    const onMsgUpdate = captureEventHandler("message_update");
    onMsgUpdate({
      type: "message_update",
      message: {},
      assistantMessageEvent: { type: "text_delta", contentIndex: 0, delta: "hi", partial: {} },
    });

    const allSent = relayRef.current!.send.mock.calls.map((c) => c[0] as string);
    const chunks = allSent.map(decodeSentCt).filter((d) => d.inner.type === "agent_chunk");
    expect(chunks).toHaveLength(1);
    expect(chunks[0]!.inner).toMatchObject({
      type: "agent_chunk",
      in_reply_to: turnId,
      delta: "hi",
    });
  });
});

// ── tool visibility (tool_execution_start → tool_request) ─────────────────────

describe("tool visibility", () => {
  beforeEach(async () => {
    vi.clearAllMocks();
    _knownPeers.length = 0;
    _addedPeers.length = 0;
    _removedPeers.length = 0;
    _consumeCalls.length = 0;
    _setRelayCalls.length = 0;
    _savedRelayUrl = null;
    _tokenStatus = "ok";
    relayRef.current = null;
    const qr = await import("./pairing/qr.js");
    (qr.qrSession.consumeToken as unknown as ReturnType<typeof vi.fn>).mockImplementation(
      (token: string) => {
        _consumeCalls.push(token);
        return _tokenStatus;
      },
    );
    const stop = captureHandler("remote-pi stop");
    await stop("", makeMockCtx());
  });

  test("tool_execution_start → tool_request emitted via channel", async () => {
    await _pairForTest("peer-tool");
    const sendsBefore = relayRef.current!.send.mock.calls.length;

    const onToolStart = captureEventHandler("tool_execution_start");
    onToolStart({
      type: "tool_execution_start",
      toolCallId: "tc_1",
      toolName: "bash",
      args: { command: "ls" },
    });

    const sent = relayRef.current!.send.mock.calls.slice(sendsBefore).map((c) => c[0] as string);
    const requests = sent.map(decodeSentCt).filter((d) => d.inner.type === "tool_request");
    expect(requests).toHaveLength(1);
    expect(requests[0]!.peer).toBe("peer-tool");
    expect(requests[0]!.inner).toMatchObject({
      type: "tool_request",
      tool_call_id: "tc_1",
      tool: "bash",
      args: { command: "ls" },
    });
  });

  test("tool_execution_start enriches edit args with numbered context hunks", async () => {
    await _pairForTest("peer-edit");
    const cwd = mkdtempSync(join(tmpdir(), "remote-pi-edit-"));
    const file = join(cwd, "sample.dart");
    writeFileSync(
      file,
      [
        "line 1",
        "line 2",
        "line 3",
        "line 4",
        "line 5",
        "  tool: 'Edit',",
        "  args: {",
        "    'file_path': 'x',",
        "  },",
        "line 10",
      ].join("\n"),
    );
    const sendsBefore = relayRef.current!.send.mock.calls.length;

    try {
      const onToolStart = captureEventHandler("tool_execution_start");
      onToolStart({
        type: "tool_execution_start",
        toolCallId: "tc_edit",
        toolName: "edit",
        args: {
          path: file,
          edits: [
            {
              oldText: "  tool: 'Edit',\n  args: {\n    'file_path': 'x',",
              newText: "  tool: 'edit',\n  args: {\n    'path': 'x',",
            },
          ],
        },
      });

      const requests = relayRef.current!.send.mock.calls
        .slice(sendsBefore)
        .map((c) => c[0] as string)
        .map(decodeSentCt)
        .filter((d) => d.inner.type === "tool_request");
      const args = requests[0]!.inner.args as {
        hunks: Array<{ lines: Array<{ kind: string; oldLine?: number; newLine?: number; text?: string }> }>;
      };
      expect(args.hunks[0]!.lines).toEqual(
        expect.arrayContaining([
          { kind: "context", oldLine: 5, newLine: 5, text: "line 5" },
          { kind: "remove", oldLine: 6, text: "  tool: 'Edit'," },
          { kind: "add", newLine: 6, text: "  tool: 'edit'," },
          { kind: "context", oldLine: 9, newLine: 9, text: "  }," },
        ]),
      );
    } finally {
      rmSync(cwd, { recursive: true, force: true });
    }
  });


  test("tool_execution_start keeps unchanged edit lines as context", async () => {
    await _pairForTest("peer-edit-context");
    const cwd = mkdtempSync(join(tmpdir(), "remote-pi-edit-context-"));
    const file = join(cwd, "README.md");
    writeFileSync(
      file,
      [
        "<p align=\"center\">",
        "  Control your Pi from your phone.",
        "  Pair with a one-time QR code.",
        "</p>",
      ].join("\n"),
    );
    const sendsBefore = relayRef.current!.send.mock.calls.length;

    try {
      const onToolStart = captureEventHandler("tool_execution_start");
      onToolStart({
        type: "tool_execution_start",
        toolCallId: "tc_edit_context",
        toolName: "edit",
        args: {
          path: file,
          edits: [
            {
              oldText: "  Pair with a one-time QR code.",
              newText: "  Pair with a one-time QR code.\n  Test note: edit preview smoke test.",
            },
          ],
        },
      });

      const requests = relayRef.current!.send.mock.calls
        .slice(sendsBefore)
        .map((c) => c[0] as string)
        .map(decodeSentCt)
        .filter((d) => d.inner.type === "tool_request");
      const args = requests[0]!.inner.args as {
        hunks: Array<{ lines: Array<{ kind: string; oldLine?: number; newLine?: number; text?: string }> }>;
      };
      expect(args.hunks[0]!.lines).toEqual(
        expect.arrayContaining([
          { kind: "context", oldLine: 3, newLine: 3, text: "  Pair with a one-time QR code." },
          { kind: "add", newLine: 4, text: "  Test note: edit preview smoke test." },
          { kind: "context", oldLine: 4, newLine: 5, text: "</p>" },
        ]),
      );
      expect(args.hunks[0]!.lines).not.toEqual(
        expect.arrayContaining([
          { kind: "remove", oldLine: 3, text: "  Pair with a one-time QR code." },
        ]),
      );
    } finally {
      rmSync(cwd, { recursive: true, force: true });
    }
  });

  test("tool_execution_start ignored when _peerChannel is null (idle state)", () => {
    expect(_getState()).toBe("idle");

    const onToolStart = captureEventHandler("tool_execution_start");
    onToolStart({
      type: "tool_execution_start",
      toolCallId: "tc_idle",
      toolName: "bash",
      args: { command: "ls" },
    });

    // Relay was never instantiated in idle state (no start happened)
    expect(relayRef.current).toBeNull();
  });

  test("start → end pair emits tool_request then tool_result (no gate)", async () => {
    await _pairForTest("peer-pair");

    const onToolStart = captureEventHandler("tool_execution_start");
    const onToolEnd = captureEventHandler("tool_execution_end");

    onToolStart({
      type: "tool_execution_start",
      toolCallId: "tc_2",
      toolName: "Read",
      args: { file_path: "/tmp/x" },
    });
    onToolEnd({
      type: "tool_execution_end",
      toolCallId: "tc_2",
      toolName: "Read",
      result: { content: "hello" },
      isError: false,
    });

    const sent = relayRef.current!.send.mock.calls.map((c) => c[0] as string).map(decodeSentCt);
    const requests = sent.filter((d) => d.inner.type === "tool_request");
    const results = sent.filter((d) => d.inner.type === "tool_result");
    expect(requests).toHaveLength(1);
    expect(results).toHaveLength(1);
    expect(results[0]!.inner).toMatchObject({
      type: "tool_result",
      tool_call_id: "tc_2",
    });
  });

  test("tool_result stringifies content-array/object (no [object Object]) and == re-sync", async () => {
    await _pairForTest("peer-tr");
    const onToolEnd = captureEventHandler("tool_execution_end");
    const sendsBefore = relayRef.current!.send.mock.calls.length;

    // success: content-array result → joined text (was "[object Object]").
    onToolEnd({
      type: "tool_execution_end", toolCallId: "tc_ok", toolName: "Read",
      result: [{ type: "text", text: "file contents" }], isError: false,
    });
    // error: content-array → text (was "[object Object]").
    onToolEnd({
      type: "tool_execution_end", toolCallId: "tc_err", toolName: "Bash",
      result: [{ type: "text", text: "command failed: boom" }], isError: true,
    });
    // plain object → readable JSON (was "[object Object]").
    onToolEnd({
      type: "tool_execution_end", toolCallId: "tc_obj", toolName: "X",
      result: { code: 1, msg: "nope" }, isError: true,
    });

    const sent = relayRef.current!.send.mock.calls.slice(sendsBefore)
      .map((c) => c[0] as string).map(decodeSentCt)
      .filter((d) => d.inner.type === "tool_result");
    const ok = sent.find((d) => d.inner.tool_call_id === "tc_ok");
    const err = sent.find((d) => d.inner.tool_call_id === "tc_err");
    const obj = sent.find((d) => d.inner.tool_call_id === "tc_obj");

    expect(ok?.inner.result).toBe("file contents");
    expect(err?.inner.error).toBe("command failed: boom");
    expect(obj?.inner.error).toBe(JSON.stringify({ code: 1, msg: "nope" }));
    expect(JSON.stringify(sent)).not.toContain("[object Object]");

    // live == re-sync: the history mapper yields identical text for the same tool.
    const histOk = _mapAgentMessagesToEvents([
      { role: "toolResult", toolCallId: "tc_ok", content: [{ type: "text", text: "file contents" }], timestamp: 1 },
    ])[0] as { result?: string };
    const histErr = _mapAgentMessagesToEvents([
      { role: "toolResult", toolCallId: "tc_err", isError: true, content: [{ type: "text", text: "command failed: boom" }], timestamp: 1 },
    ])[0] as { error?: string };
    expect(histOk.result).toBe(ok?.inner.result);
    expect(histErr.error).toBe(err?.inner.error);
  });

  test("tool_result unwraps the live { content:[…], details } wrapper (== re-sync)", async () => {
    await _pairForTest("peer-tr2");
    const onToolEnd = captureEventHandler("tool_execution_end");
    const sendsBefore = relayRef.current!.send.mock.calls.length;

    // Live: event.result is the WRAPPER object, NOT a bare content-array.
    onToolEnd({
      type: "tool_execution_end", toolCallId: "tc_w", toolName: "run_command",
      result: { content: [{ type: "text", text: "ping: cannot resolve host" }], details: {} },
      isError: true,
    });

    const sent = relayRef.current!.send.mock.calls.slice(sendsBefore)
      .map((c) => c[0] as string).map(decodeSentCt)
      .filter((d) => d.inner.type === "tool_result");
    const w = sent.find((d) => d.inner.tool_call_id === "tc_w");
    // unwrapped to the clean text — no braces / JSON wrapper / "[object Object]".
    expect(w?.inner.error).toBe("ping: cannot resolve host");
    expect(JSON.stringify(sent)).not.toContain("\"content\"");

    // live == re-sync: history (m.content = bare content-array) gives same text.
    const hist = _mapAgentMessagesToEvents([
      { role: "toolResult", toolCallId: "tc_w", isError: true, content: [{ type: "text", text: "ping: cannot resolve host" }], timestamp: 1 },
    ])[0] as { error?: string };
    expect(hist.error).toBe(w?.inner.error);
  });
});

// ── /remote-pi set-relay + /remote-pi config ──────────────────────────────────

describe("/remote-pi set-relay + config", () => {
  beforeEach(async () => {
    vi.clearAllMocks();
    _savedRelayUrl = null;
    _setRelayCalls.length = 0;
    delete process.env["REMOTE_PI_RELAY"];
    relayRef.current = null;
    const stop = captureHandler("remote-pi stop");
    await stop("", makeMockCtx());
  });

  test("set-relay empty arg → usage warning, nothing saved", async () => {
    const setRelay = captureHandler("remote-pi set-relay");
    const ctx = makeMockCtx();
    await setRelay("", ctx);

    expect(ctx.ui.notify).toHaveBeenCalledWith(
      expect.stringContaining("Usage: /remote-pi set-relay"),
      "warning",
    );
    expect(_setRelayCalls).toHaveLength(0);
  });

  test("set-relay stores http:// as-is (canonical scheme)", async () => {
    const setRelay = captureHandler("remote-pi set-relay");
    const ctx = makeMockCtx();
    await setRelay("http://foo:3000", ctx);

    expect(_setRelayCalls).toEqual(["http://foo:3000"]);
    expect(ctx.ui.notify).toHaveBeenCalledWith(
      expect.stringContaining("http://foo:3000"),
      "info",
    );
  });

  test("set-relay stores https:// as-is (canonical scheme)", async () => {
    const setRelay = captureHandler("remote-pi set-relay");
    const ctx = makeMockCtx();
    await setRelay("https://relay.example.tld", ctx);

    expect(_setRelayCalls).toEqual(["https://relay.example.tld"]);
    expect(ctx.ui.notify).toHaveBeenCalledWith(
      expect.stringContaining("https://relay.example.tld"),
      "info",
    );
  });

  test("set-relay rejects ws:// scheme with conversion hint", async () => {
    const setRelay = captureHandler("remote-pi set-relay");
    const ctx = makeMockCtx();
    await setRelay("ws://foo:3000", ctx);

    expect(ctx.ui.notify).toHaveBeenCalledWith(
      expect.stringContaining("Use http:// or https://"),
      "error",
    );
    expect(_setRelayCalls).toHaveLength(0);
  });

  test("set-relay rejects wss:// scheme with conversion hint", async () => {
    const setRelay = captureHandler("remote-pi set-relay");
    const ctx = makeMockCtx();
    await setRelay("wss://relay.example.tld", ctx);

    expect(ctx.ui.notify).toHaveBeenCalledWith(
      expect.stringContaining("Use http:// or https://"),
      "error",
    );
    expect(_setRelayCalls).toHaveLength(0);
  });

  test("set-relay rejects malformed URL", async () => {
    const setRelay = captureHandler("remote-pi set-relay");
    const ctx = makeMockCtx();
    await setRelay("not a url at all", ctx);

    expect(ctx.ui.notify).toHaveBeenCalledWith(
      expect.stringContaining("Invalid URL"),
      "error",
    );
    expect(_setRelayCalls).toHaveLength(0);
  });

  test("set-relay persists http:// URL via saveConfig (canonical form)", async () => {
    const setRelay = captureHandler("remote-pi set-relay");
    const ctx = makeMockCtx();
    await setRelay("http://192.168.1.10:3000", ctx);

    expect(_setRelayCalls).toEqual(["http://192.168.1.10:3000"]);
    expect(ctx.ui.notify).toHaveBeenCalledWith(
      expect.stringContaining("Relay set to http://192.168.1.10:3000"),
      "info",
    );
  });

  // Issue #119: `relay url` / `relay stop` were documented in the README but
  // had no handler — every `relay …` fell through to the status panel, so a
  // user following the README silently stayed on the community relay.
  test("relay url persists the URL through the same writer as set-relay", async () => {
    const relay = captureHandler("remote-pi relay");
    const ctx = makeMockCtx();
    await relay("url http://192.168.1.20:3000", ctx);

    expect(_setRelayCalls).toEqual(["http://192.168.1.20:3000"]);
    expect(ctx.ui.notify).toHaveBeenCalledWith(
      expect.stringContaining("Relay set to http://192.168.1.20:3000"),
      "info",
    );
  });

  test("relay url rejects ws:// like set-relay does", async () => {
    const relay = captureHandler("remote-pi relay");
    const ctx = makeMockCtx();
    await relay("url ws://foo:3000", ctx);

    expect(_setRelayCalls).toHaveLength(0);
    expect(ctx.ui.notify).toHaveBeenCalledWith(
      expect.stringContaining("Use http:// or https://"),
      "error",
    );
  });

  test("relay stop on an idle relay reports it instead of silently reprinting status", async () => {
    const relay = captureHandler("remote-pi relay");
    const ctx = makeMockCtx();
    await relay("stop", ctx);

    expect(ctx.ui.notify).toHaveBeenCalledWith(
      expect.stringContaining("already disconnected"),
      "info",
    );
  });

  test("relay with an unknown verb prints usage", async () => {
    const relay = captureHandler("remote-pi relay");
    const ctx = makeMockCtx();
    await relay("frobnicate", ctx);

    expect(ctx.ui.notify).toHaveBeenCalledWith(
      expect.stringContaining("Usage: /remote-pi relay"),
      "warning",
    );
  });

  test("resolveRelayUrl: env > config > default (all canonicalized to http(s)://)", async () => {
    const cfg = await import("./config.js");
    const { resolveRelayUrl, kDefaultRelayUrl, toHttpUrl } = cfg;

    // 1) Nothing set → default (canonical form is http(s)://)
    expect(resolveRelayUrl()).toEqual({ url: toHttpUrl(kDefaultRelayUrl), source: "default" });

    // 2) Config set, no env → config. Legacy ws:// in config gets coerced
    // back to canonical http(s):// by resolveRelayUrl.
    _savedRelayUrl = "ws://config.test";
    expect(resolveRelayUrl()).toEqual({ url: "http://config.test", source: "config" });

    // 3) Env set → env wins over config. Same defensive coercion.
    process.env["REMOTE_PI_RELAY"] = "wss://env.test";
    expect(resolveRelayUrl()).toEqual({ url: "https://env.test", source: "env" });
    delete process.env["REMOTE_PI_RELAY"];
  });

  test("/remote-pi status shows the saved URL after set-relay", async () => {
    const setRelay = captureHandler("remote-pi set-relay");
    await setRelay("http://10.0.0.5:4000", makeMockCtx());

    const status = captureHandler("remote-pi status");
    const ctx = makeMockCtx();
    await status("", ctx);

    const text = (ctx.ui.notify.mock.calls[0]![0]) as string;
    expect(text).toContain("http://10.0.0.5:4000");
    expect(text).not.toContain("Local mesh");
    expect(text).not.toContain("peer count");
  });

  test("/remote-pi status shows the default URL when nothing set", async () => {
    const status = captureHandler("remote-pi status");
    const ctx = makeMockCtx();
    await status("", ctx);

    const text = (ctx.ui.notify.mock.calls[0]![0]) as string;
    expect(text).toContain("https://relay-rp1.jacobmoura.work");
  });

  test("/remote-pi status reflects env override (canonicalized to https://)", async () => {
    // Env var with wss:// is coerced back to https:// by resolveRelayUrl.
    process.env["REMOTE_PI_RELAY"] = "wss://from-env.test";
    const status = captureHandler("remote-pi status");
    const ctx = makeMockCtx();
    await status("", ctx);

    const text = (ctx.ui.notify.mock.calls[0]![0]) as string;
    expect(text).toContain("https://from-env.test");
    delete process.env["REMOTE_PI_RELAY"];
  });

  test("saved URL is used by _cmdStart on next connect (http:// stored as-is)", async () => {
    const setRelay = captureHandler("remote-pi set-relay");
    await setRelay("http://10.0.0.5:4000", makeMockCtx());

    captureHandler("remote-pi");
    const ctx = makeMockCtx();
    await _connectForTest(ctx);

    expect(_getState()).toBe("started");
    // The "Connecting to relay <url>" notify shows the canonical http(s)://
    // form. Transport converts to ws(s):// internally before opening WS.
    expect(ctx.ui.notify).toHaveBeenCalledWith(
      expect.stringContaining("http://10.0.0.5:4000"),
      "info",
    );
    expect(ctx.ui.notify).toHaveBeenCalledWith(
      expect.stringContaining("source: config"),
      "info",
    );
  });
});

describe("routeClientMessage cancel handling", () => {
  beforeEach(async () => {
    vi.clearAllMocks();
    _knownPeers.length = 0;
    _addedPeers.length = 0;
    _removedPeers.length = 0;
    _consumeCalls.length = 0;
    _setRelayCalls.length = 0;
    _savedRelayUrl = null;
    _tokenStatus = "ok";
    relayRef.current = null;
    relayInstances.length = 0;
    _defaultConnectImpl = async () => undefined;
    const qr = await import("./pairing/qr.js");
    (qr.qrSession.consumeToken as unknown as ReturnType<typeof vi.fn>).mockImplementation(
      (token: string) => {
        _consumeCalls.push(token);
        return _tokenStatus;
      },
    );
    const stop = captureHandler("remote-pi stop");
    await stop("", { ui: { notify: vi.fn() }, cwd: "/tmp/remote-pi-cancel-reset" } as ReturnType<typeof makeMockCtx>);
  });

  test("cancel uses freshest session_start ctx and ignores stale _lastCtx abort", async () => {
    const staleAbort = vi.fn();
    const freshAbort = vi.fn();

    await _pairForTestWithCtx("owner-cancel-1", {
      ui: { notify: vi.fn() },
      cwd: "/tmp/remote-pi-cancel-stale",
    });

    const status = captureHandler("remote-pi status");
    await status("", {
      ui: { notify: vi.fn() },
      cwd: "/tmp/remote-pi-cancel-stale",
      abort: staleAbort,
    });

    const onSessionStart = captureEventHandler("session_start");
    onSessionStart({ type: "session_start" }, { abort: freshAbort, compact: vi.fn() } as unknown as {
      abort: ReturnType<typeof vi.fn>;
      compact: ReturnType<typeof vi.fn>;
    });

    const sendsBefore = relayRef.current!.send.mock.calls.length;
    relayRef.current!.emit("message", JSON.stringify({
      peer: "owner-cancel-1",
      ct: Buffer.from(JSON.stringify({
        type: "cancel", id: "cancel-stale", target_id: "msg-stale",
      })).toString("base64"),
    }));

    await new Promise<void>((r) => setImmediate(r));

    const sent = relayRef.current!.send.mock.calls
      .slice(sendsBefore)
      .map((c) => c[0] as string)
      .map(decodeSentCt)
      .filter((d) => d.peer === "owner-cancel-1");
    const cancelled = sent.filter((d) => d.inner.type === "cancelled");
    expect(cancelled).toHaveLength(1);
    expect(cancelled[0]!.inner).toMatchObject({
      type: "cancelled",
      in_reply_to: "cancel-stale",
      target_id: "msg-stale",
    });
    expect(staleAbort).not.toHaveBeenCalled();
    expect(freshAbort).toHaveBeenCalledTimes(1);
  });

  test("owner reconnect after session replacement does not throw on stale _lastCtx.ui (#55)", async () => {
    // Regression: _refreshFooter/_attachOwner used captured _lastCtx.ui; after
    // session replacement the SDK ui getter throws via assertActive and the
    // uncaught exception killed the whole pi process on peer reconnect.
    const freshNotify = vi.fn();
    const freshSetStatus = vi.fn();
    const freshSetTitle = vi.fn();

    const owner = OWNER_STANDARD_FIXTURE;
    await _pairForTestWithCtx(owner, {
      ui: { notify: vi.fn(), setStatus: vi.fn(), setTitle: vi.fn() },
      cwd: "/tmp/remote-pi-stale-ui",
    });

    // Plant a command ctx whose ui GETTER throws (real SDK stale-ctx behaviour).
    // The status handler assigns _lastCtx = ctx before touching ui.
    const status = captureHandler("remote-pi status");
    const staleCtx = {
      cwd: "/tmp/remote-pi-stale-ui",
      get ui() {
        throw new Error("This extension ctx is stale after session replacement or reload.");
      },
    };
    await expect(status("", staleCtx as ReturnType<typeof makeMockCtx>)).rejects.toThrow(/stale/);

    // Rebind the always-fresh session_start ctx (module-reuse path after /new).
    const onSessionStart = captureEventHandler("session_start");
    onSessionStart({ type: "session_start" }, {
      abort: vi.fn(),
      compact: vi.fn(),
      ui: { notify: freshNotify, setStatus: freshSetStatus, setTitle: freshSetTitle },
    } as unknown as {
      abort: ReturnType<typeof vi.fn>;
      compact: ReturnType<typeof vi.fn>;
      ui: { notify: ReturnType<typeof vi.fn>; setStatus: ReturnType<typeof vi.fn>; setTitle: ReturnType<typeof vi.fn> };
    });

    // Drop the owner, then reconnect via the known-peer auto-listener path
    // (the exact stack in the bug: onMsg → _attachOwner → _refreshFooter).
    _onPeerDisconnect(owner);
    expect(_hasActivePeerForTest(owner)).toBe(false);

    relayRef.current!.emit("message", JSON.stringify({
      peer: owner,
      ct: Buffer.from(JSON.stringify({ type: "ping", id: "ping-stale-ui" })).toString("base64"),
    }));
    await new Promise<void>((r) => setImmediate(r));

    expect(_hasActivePeerForTest(owner)).toBe(true);
    // Footer refresh preferred the fresh session_start ui, not the throwing one.
    expect(freshSetStatus).toHaveBeenCalled();
    expect(freshNotify).toHaveBeenCalled();
  });

  test("_emitRelayState never throws when pi.sendMessage is dead after reload", () => {
    // Regression: session_shutdown /relay callbacks used a live-looking `_pi`
    // whose sendMessage throws "Extension runtime not initialized" after /reload.
    const sendMessage = vi.fn(() => {
      throw new Error("Extension runtime not initialized");
    });
    _setPiForTest({ sendMessage });
    _setDisposedForTest(false);
    expect(() => _emitRelayStateForTest(true)).not.toThrow();
    expect(sendMessage).toHaveBeenCalled();
  });

  test("session_shutdown drops _pi so late _emitRelayState is a no-op", async () => {
    const sendMessage = vi.fn(() => {
      throw new Error("Extension runtime not initialized");
    });
    _setPiForTest({ sendMessage });

    const onShutdown = captureEventHandler("session_shutdown");
    await onShutdown({ type: "session_shutdown" }, {} as never);

    sendMessage.mockClear();
    expect(() => _emitRelayStateForTest(true)).not.toThrow();
    // Binding cleared + disposed: must not touch the dead ExtensionAPI.
    expect(sendMessage).not.toHaveBeenCalled();

    // Re-arm for subsequent tests in this shared module.
    _setDisposedForTest(false);
    _setPiForTest({ sendMessage: vi.fn() });
    _resetAutoInitedForTest();
  });

  test("footer refresh clears legacy slots without publishing peer roster", () => {
    const setStatus = vi.fn();
    const setTitle = vi.fn();
    const setWidget = vi.fn();
    _refreshFooterForTest({ ui: { setStatus, setTitle, setWidget } });
    expect(setStatus).toHaveBeenCalledWith("remote-pi:agent-name", undefined);
    expect(setStatus).toHaveBeenCalledWith("remote-pi:session", undefined);
    expect(setWidget).not.toHaveBeenCalled();
  });

  test("cancel is handled before the strict pi binding guard", async () => {
    const freshAbort = vi.fn();

    await _pairForTestWithCtx("owner-cancel-nopi", {
      ui: { notify: vi.fn() },
      cwd: "/tmp/remote-pi-cancel-nopi",
    });

    const onSessionStart = captureEventHandler("session_start");
    onSessionStart({ type: "session_start" }, { abort: freshAbort, compact: vi.fn() } as unknown as {
      abort: ReturnType<typeof vi.fn>;
      compact: ReturnType<typeof vi.fn>;
    });
    _setPiForTest(null);

    const sendsBefore = relayRef.current!.send.mock.calls.length;
    relayRef.current!.emit("message", JSON.stringify({
      peer: "owner-cancel-nopi",
      ct: Buffer.from(JSON.stringify({
        type: "cancel", id: "cancel-nopi", target_id: "msg-nopi",
      })).toString("base64"),
    }));

    await new Promise<void>((r) => setImmediate(r));

    const sent = relayRef.current!.send.mock.calls
      .slice(sendsBefore)
      .map((c) => c[0] as string)
      .map(decodeSentCt)
      .filter((d) => d.peer === "owner-cancel-nopi");
    const cancelled = sent.filter((d) => d.inner.type === "cancelled");
    expect(cancelled).toHaveLength(1);
    expect(cancelled[0]!.inner).toMatchObject({
      type: "cancelled",
      in_reply_to: "cancel-nopi",
      target_id: "msg-nopi",
    });
    expect(freshAbort).toHaveBeenCalledTimes(1);
  });

  test("cancel with no real abort context returns error and does not send cancelled", async () => {
    await _pairForTestWithCtx("owner-cancel-2", {
      ui: { notify: vi.fn() },
      cwd: "/tmp/remote-pi-cancel-nonreal",
      // Intentionally omit abort: the router must not claim success.
    } as unknown as { ui: { notify: ReturnType<typeof vi.fn> }; cwd: string });

    const onSessionStart = captureEventHandler("session_start");
    onSessionStart({ type: "session_start" }, { compact: vi.fn() } as unknown as {
      compact: ReturnType<typeof vi.fn>;
    });

    const sendsBefore = relayRef.current!.send.mock.calls.length;
    relayRef.current!.emit("message", JSON.stringify({
      peer: "owner-cancel-2",
      ct: Buffer.from(JSON.stringify({
        type: "cancel", id: "cancel-nonreal", target_id: "msg-nonreal",
      })).toString("base64"),
    }));

    await new Promise<void>((r) => setImmediate(r));

    const sent = relayRef.current!.send.mock.calls
      .slice(sendsBefore)
      .map((c) => c[0] as string)
      .map(decodeSentCt)
      .filter((d) => d.peer === "owner-cancel-2");
    const errors = sent.filter((d) => d.inner.type === "error");
    const cancelled = sent.filter((d) => d.inner.type === "cancelled");
    expect(errors).toHaveLength(1);
    expect(errors[0]!.inner).toMatchObject({
      type: "error",
      in_reply_to: "cancel-nonreal",
      code: "internal_error",
    });
    expect(cancelled).toHaveLength(0);
  });

  test("abort throw sends error, and the router still handles a later ping", async () => {
    const aborting = vi.fn(() => { throw new Error("abort boom"); });

    await _pairForTestWithCtx("owner-cancel-3", {
      ui: { notify: vi.fn() },
      cwd: "/tmp/remote-pi-cancel-throw",
      abort: aborting,
    });

    const onSessionStart = captureEventHandler("session_start");
    onSessionStart({ type: "session_start" }, { abort: aborting, compact: vi.fn() } as unknown as {
      abort: ReturnType<typeof vi.fn>;
      compact: ReturnType<typeof vi.fn>;
    });

    const sendsBefore = relayRef.current!.send.mock.calls.length;
    relayRef.current!.emit("message", JSON.stringify({
      peer: "owner-cancel-3",
      ct: Buffer.from(JSON.stringify({
        type: "cancel", id: "cancel-throw", target_id: "msg-throw",
      })).toString("base64"),
    }));

    await new Promise<void>((r) => setImmediate(r));

    relayRef.current!.emit("message", JSON.stringify({
      peer: "owner-cancel-3",
      ct: Buffer.from(JSON.stringify({ type: "ping", id: "ping-after-cancel" })).toString("base64"),
    }));
    await new Promise<void>((r) => setImmediate(r));

    const sent = relayRef.current!.send.mock.calls
      .slice(sendsBefore)
      .map((c) => c[0] as string)
      .map(decodeSentCt)
      .filter((d) => d.peer === "owner-cancel-3");

    const errors = sent.filter((d) => d.inner.type === "error");
    const pongs = sent.filter((d) => d.inner.type === "pong");

    expect(aborting).toHaveBeenCalledTimes(1);
    expect(errors).toHaveLength(1);
    expect(errors[0]!.inner).toMatchObject({
      type: "error",
      in_reply_to: "cancel-throw",
      code: "internal_error",
    });
    expect(pongs).toHaveLength(1);
    expect(pongs[0]!.inner).toMatchObject({ type: "pong", in_reply_to: "ping-after-cancel" });
  });
});

// ── QR no longer carries `r` (relay URL) ──────────────────────────────────────

describe("QR payload (no r field, with rm)", () => {
  test("buildQRUri produces URI with t + epk + n (no r)", async () => {
    const { buildQRUri } = await import("./pairing/qr.js");
    const epk = Buffer.alloc(32, 0x42);
    const uri = buildQRUri("token-abc", epk, "feature/x");
    expect(uri.startsWith("remotepi://pair?")).toBe(true);
    const url = new URL(uri.replace("remotepi:", "https:"));
    expect(url.searchParams.get("t")).toBe("token-abc");
    expect(url.searchParams.get("epk")).toBeTruthy();
    expect(url.searchParams.get("n")).toBe("feature/x");
    expect(url.searchParams.get("r")).toBeNull();   // ← key assertion: no relay URL
    expect(uri).not.toContain("r=");
  });

  test("buildQRUri includes rm=<12-char roomId> when provided", async () => {
    const { buildQRUri } = await import("./pairing/qr.js");
    const epk = Buffer.alloc(32, 0x42);
    const uri = buildQRUri("token-abc", epk, "feature/x", "aB12CD34eF56");
    const url = new URL(uri.replace("remotepi:", "https:"));
    expect(url.searchParams.get("rm")).toBe("aB12CD34eF56");
    expect(url.searchParams.get("rm")).toMatch(/^[A-Za-z0-9_-]{12}$/);
  });

  test("buildQRUri without roomId omits rm field (backward-compat)", async () => {
    const { buildQRUri } = await import("./pairing/qr.js");
    const epk = Buffer.alloc(32, 0x42);
    const uri = buildQRUri("token-abc", epk, "feature/x");
    const url = new URL(uri.replace("remotepi:", "https:"));
    expect(url.searchParams.get("rm")).toBeNull();
  });
});

// ── rooms: _cmdStart sends roomId/roomMeta; PeerChannel includes room ────────

describe("rooms wiring", () => {
  beforeEach(async () => {
    vi.clearAllMocks();
    _knownPeers.length = 0;
    _addedPeers.length = 0;
    _removedPeers.length = 0;
    _consumeCalls.length = 0;
    _setRelayCalls.length = 0;
    _savedRelayUrl = null;
    _tokenStatus = "ok";
    relayRef.current = null;
    relayInstances.length = 0;
    _defaultConnectImpl = async () => undefined;
    delete process.env["REMOTE_PI_RELAY"];
    const qr = await import("./pairing/qr.js");
    (qr.qrSession.consumeToken as unknown as ReturnType<typeof vi.fn>).mockImplementation(
      (token: string) => {
        _consumeCalls.push(token);
        return _tokenStatus;
      },
    );
    const stop = captureHandler("remote-pi stop");
    await stop("", makeMockCtx());
  });

  test("_cmdStart calls relay.connect with roomId and roomMeta derived from cwd", async () => {
    const capturedOpts: unknown[] = [];
    _defaultConnectImpl = async (opts?: unknown) => {
      capturedOpts.push(opts);
    };

    captureHandler("remote-pi");
    await _connectForTest(makeMockCtx("/tmp/remote-pi-test-room"));

    expect(capturedOpts).toHaveLength(1);
    const opts = capturedOpts[0] as { roomId?: string; roomMeta?: { name: string; cwd: string } };
    expect(opts.roomId).toBeTruthy();
    expect(opts.roomId).toMatch(/^[A-Za-z0-9_-]{12}$/);
    expect(opts.roomMeta?.cwd).toBe("/tmp/remote-pi-test-room");
    expect(opts.roomMeta?.name).toContain("remote-pi-test-room");
  });

  test("_cmdStart with different cwds uses different roomIds", async () => {
    const capturedOpts: Array<{ roomId?: string }> = [];
    _defaultConnectImpl = async (opts?: unknown) => {
      capturedOpts.push(opts as { roomId?: string });
    };

    captureHandler("remote-pi");
    await _connectForTest(makeMockCtx("/tmp/remote-pi-A"));

    const stop = captureHandler("remote-pi stop");
    await stop("", makeMockCtx());

    await _connectForTest(makeMockCtx("/tmp/remote-pi-B"));

    expect(capturedOpts).toHaveLength(2);
    expect(capturedOpts[0]!.roomId).not.toBe(capturedOpts[1]!.roomId);
  });

  test("RoomAlreadyOpenError closes its initial Relay candidate before reporting", async () => {
    _defaultConnectImpl = async () => {
      throw new MockRoomAlreadyOpenError("AbCdEfGhIjKl");
    };

    captureHandler("remote-pi");
    const ctx = makeMockCtx("/tmp/remote-pi-dup");
    await _connectForTest(ctx);

    expect(ctx.ui.notify).toHaveBeenCalledWith(
      expect.stringMatching(/Relay room .* already open .*\/name/),
      "error",
    );
    expect(relayRef.current?.close).toHaveBeenCalledTimes(1);
    expect(_getState()).toBe("idle");
  });

  test("generic initial Relay failure closes its candidate before reporting", async () => {
    const failure = new Error("initial Relay failed");
    _defaultConnectImpl = async () => { throw failure; };

    captureHandler("remote-pi");
    const ctx = makeMockCtx("/tmp/remote-pi-initial-failure");
    await _connectForTest(ctx);

    expect(ctx.ui.notify).toHaveBeenCalledWith(
      expect.stringContaining(failure.message),
      "error",
    );
    expect(relayRef.current?.close).toHaveBeenCalledTimes(1);
    expect(_getState()).toBe("idle");
  });

  test("PeerChannel outer envelope omits `room` field (defensive, until W1.A/C ready)", async () => {
    captureHandler("remote-pi");
    await _connectForTest(makeMockCtx("/tmp/remote-pi-room-test"));

    relayRef.current!.emit("message", JSON.stringify({
      peer: "peer-room-test",
      ct: Buffer.from(JSON.stringify({
        type: "pair_request", id: "req-1", token: "test-token", device_name: "Phone",
      })).toString("base64"),
    }));
    await vi.waitFor(() => expect(_getState()).toBe("paired"), { timeout: 2000 });

    // Trigger a channel-sent frame via ping (post-pair).
    relayRef.current!.emit("message", JSON.stringify({
      peer: "peer-room-test",
      ct: Buffer.from(JSON.stringify({ type: "ping", id: "p1" })).toString("base64"),
    }));
    await new Promise((r) => setTimeout(r, 30));

    const sent = relayRef.current!.send.mock.calls.map((c) => c[0] as string);
    const allFrames = sent.map((line) => JSON.parse(line) as { peer: string; room?: string; ct: string });
    const channelFrames = allFrames.filter((o) => o.peer === "peer-room-test");
    expect(channelFrames.length).toBeGreaterThan(0);
    // Defensive: no frame should carry `room` until downstream is ready.
    for (const f of channelFrames) {
      expect(f.room).toBeUndefined();
    }
  });
});

// ── session_sync (catch-up replay) ────────────────────────────────────────────

describe("session sync", () => {
  beforeEach(async () => {
    vi.clearAllMocks();
    _knownPeers.length = 0;
    _addedPeers.length = 0;
    _removedPeers.length = 0;
    _consumeCalls.length = 0;
    _setRelayCalls.length = 0;
    _savedRelayUrl = null;
    _tokenStatus = "ok";
    relayRef.current = null;
    const qr = await import("./pairing/qr.js");
    (qr.qrSession.consumeToken as unknown as ReturnType<typeof vi.fn>).mockImplementation(
      (token: string) => {
        _consumeCalls.push(token);
        return _tokenStatus;
      },
    );
    const stop = captureHandler("remote-pi stop");
    await stop("", makeMockCtx());
    _setMessageBufferForTest([]);
    _setSessionStartedAtForTest(null);
  });

  test("session_sync with no active session → empty history + eos:true + truncated:false", async () => {
    await _pairForTest("peer-ss-1");
    _setMessageBufferForTest([]);
    _setSessionStartedAtForTest(null); // simulate edge: paired but no session

    const sendsBefore = relayRef.current!.send.mock.calls.length;
    routeClientMessage(
      { type: "session_sync", id: "req-1" },
      { abort: () => undefined },
    );

    const sent = relayRef.current!.send.mock.calls.slice(sendsBefore).map((c) => c[0] as string);
    const histories = sent.map(decodeSentCt).filter((d) => d.inner.type === "session_history");
    expect(histories).toHaveLength(1);
    expect(histories[0]!.inner).toMatchObject({
      type: "session_history",
      in_reply_to: "req-1",
      events: [],
      eos: true,
      truncated: false,
    });
  });

  test("no limit in request → server uses env default (30)", async () => {
    delete process.env["REMOTE_PI_SYNC_LIMIT"];
    await _pairForTest("peer-ss-mirror-1");

    const sessionTs = 1_700_000_000_000;
    _setSessionStartedAtForTest(sessionTs);
    // 5 events: under default 30 → truncated:false
    _setMessageBufferForTest([
      { role: "user", content: "a", timestamp: sessionTs + 1 },
      { role: "assistant", content: [{ type: "text", text: "A" }], timestamp: sessionTs + 2 },
      { role: "user", content: "b", timestamp: sessionTs + 3 },
      { role: "assistant", content: [{ type: "text", text: "B" }], timestamp: sessionTs + 4 },
      { role: "user", content: "c", timestamp: sessionTs + 5 },
    ]);

    const sendsBefore = relayRef.current!.send.mock.calls.length;
    routeClientMessage(
      { type: "session_sync", id: "req-2" },
      { abort: () => undefined },
    );

    const sent = relayRef.current!.send.mock.calls.slice(sendsBefore).map((c) => c[0] as string);
    const h = sent.map(decodeSentCt).find((d) => d.inner.type === "session_history")!;
    const events = h.inner["events"] as unknown[];
    expect(events.length).toBe(5);
    expect(h.inner["truncated"]).toBe(false);
    expect(h.inner["eos"]).toBe(true);
  });

  test("client limit < env → server respects client limit + truncated true if overflow", async () => {
    delete process.env["REMOTE_PI_SYNC_LIMIT"];  // default 30
    await _pairForTest("peer-ss-mirror-2");

    const ts = 1_700_000_000_000;
    _setSessionStartedAtForTest(ts);
    // 10 events; client asks for 3
    const messages = Array.from({ length: 10 }, (_, i) => ({
      role: i % 2 === 0 ? "user" : "assistant",
      content: i % 2 === 0 ? `m${i}` : [{ type: "text", text: `m${i}` }],
      timestamp: ts + i,
    } as { role: string; content: unknown; timestamp: number }));
    _setMessageBufferForTest(messages);

    const sendsBefore = relayRef.current!.send.mock.calls.length;
    routeClientMessage(
      { type: "session_sync", id: "req-3", limit: 3 },
      { abort: () => undefined },
    );

    const sent = relayRef.current!.send.mock.calls.slice(sendsBefore).map((c) => c[0] as string);
    const h = sent.map(decodeSentCt).find((d) => d.inner.type === "session_history")!;
    const events = h.inner["events"] as Array<{ ts: number }>;
    expect(events.length).toBe(3);
    // Last 3 (latest ts)
    expect(events[0]!.ts).toBe(ts + 7);
    expect(events[2]!.ts).toBe(ts + 9);
    expect(h.inner["truncated"]).toBe(true);
  });

  test("client limit > env → server clamps to env", async () => {
    process.env["REMOTE_PI_SYNC_LIMIT"] = "5";
    await _pairForTest("peer-ss-mirror-3");

    const ts = 1_700_000_000_000;
    _setSessionStartedAtForTest(ts);
    // 10 events; client asks for 100; server cap is 5
    const messages = Array.from({ length: 10 }, (_, i) => ({
      role: "user",
      content: `m${i}`,
      timestamp: ts + i,
    } as { role: string; content: unknown; timestamp: number }));
    _setMessageBufferForTest(messages);

    const sendsBefore = relayRef.current!.send.mock.calls.length;
    routeClientMessage(
      { type: "session_sync", id: "req-4", limit: 100 },
      { abort: () => undefined },
    );

    const sent = relayRef.current!.send.mock.calls.slice(sendsBefore).map((c) => c[0] as string);
    const h = sent.map(decodeSentCt).find((d) => d.inner.type === "session_history")!;
    const events = h.inner["events"] as Array<{ ts: number }>;
    expect(events.length).toBe(5);
    expect(events[0]!.ts).toBe(ts + 5);  // last 5 of 10
    expect(events[4]!.ts).toBe(ts + 9);
    expect(h.inner["truncated"]).toBe(true);

    delete process.env["REMOTE_PI_SYNC_LIMIT"];
  });

  test("buffer with 5 events → returns 5, truncated:false", async () => {
    delete process.env["REMOTE_PI_SYNC_LIMIT"];
    await _pairForTest("peer-ss-mirror-4");

    const ts = 1_700_000_000_000;
    _setSessionStartedAtForTest(ts);
    _setMessageBufferForTest(
      Array.from({ length: 5 }, (_, i) => ({
        role: "user",
        content: `m${i}`,
        timestamp: ts + i,
      } as { role: string; content: unknown; timestamp: number })),
    );

    const sendsBefore = relayRef.current!.send.mock.calls.length;
    routeClientMessage(
      { type: "session_sync", id: "req-5" },
      { abort: () => undefined },
    );

    const h = (relayRef.current!.send.mock.calls.slice(sendsBefore).map((c) => c[0] as string))
      .map(decodeSentCt)
      .find((d) => d.inner.type === "session_history")!;
    expect((h.inner["events"] as unknown[]).length).toBe(5);
    expect(h.inner["truncated"]).toBe(false);
  });

  test("buffer with 50 events + env=30 → returns 30, truncated:true", async () => {
    delete process.env["REMOTE_PI_SYNC_LIMIT"];  // default 30
    await _pairForTest("peer-ss-mirror-5");

    const ts = 1_700_000_000_000;
    _setSessionStartedAtForTest(ts);
    _setMessageBufferForTest(
      Array.from({ length: 50 }, (_, i) => ({
        role: "user",
        content: `m${i}`,
        timestamp: ts + i,
      } as { role: string; content: unknown; timestamp: number })),
    );

    const sendsBefore = relayRef.current!.send.mock.calls.length;
    routeClientMessage(
      { type: "session_sync", id: "req-6" },
      { abort: () => undefined },
    );

    const h = (relayRef.current!.send.mock.calls.slice(sendsBefore).map((c) => c[0] as string))
      .map(decodeSentCt)
      .find((d) => d.inner.type === "session_history")!;
    const events = h.inner["events"] as Array<{ ts: number }>;
    expect(events.length).toBe(30);
    expect(events[0]!.ts).toBe(ts + 20);   // last 30 of 50 (indices 20..49)
    expect(events[29]!.ts).toBe(ts + 49);
    expect(h.inner["truncated"]).toBe(true);
  });

  test("REMOTE_PI_SYNC_LIMIT=10 → server respects env override", async () => {
    process.env["REMOTE_PI_SYNC_LIMIT"] = "10";
    await _pairForTest("peer-ss-mirror-6");

    const ts = 1_700_000_000_000;
    _setSessionStartedAtForTest(ts);
    _setMessageBufferForTest(
      Array.from({ length: 25 }, (_, i) => ({
        role: "user",
        content: `m${i}`,
        timestamp: ts + i,
      } as { role: string; content: unknown; timestamp: number })),
    );

    const sendsBefore = relayRef.current!.send.mock.calls.length;
    routeClientMessage(
      { type: "session_sync", id: "req-7" },
      { abort: () => undefined },
    );

    const h = (relayRef.current!.send.mock.calls.slice(sendsBefore).map((c) => c[0] as string))
      .map(decodeSentCt)
      .find((d) => d.inner.type === "session_history")!;
    expect((h.inner["events"] as unknown[]).length).toBe(10);
    expect(h.inner["truncated"]).toBe(true);

    delete process.env["REMOTE_PI_SYNC_LIMIT"];
  });

  test("mapping: assistant with TextContent + ToolCall → 2 events", () => {
    const ts = 1_700_000_000_000;
    const events = _mapAgentMessagesToEvents([
      { role: "user", content: "do this", timestamp: ts },
      {
        role: "assistant",
        content: [
          { type: "text", text: "running bash" },
          { type: "toolCall", id: "tc_1", name: "bash", arguments: { command: "ls" } },
        ],
        timestamp: ts + 100,
        usage: { input: 50, output: 12 },
      },
    ]);

    // user_input + agent_message + tool_request
    expect(events).toHaveLength(3);
    expect(events[0]).toMatchObject({ ts, type: "user_input", text: "do this" });
    expect(events[1]).toMatchObject({
      ts: ts + 100,
      type: "agent_message",
      text: "running bash",
      usage: { input_tokens: 50, output_tokens: 12 },
    });
    expect(events[2]).toMatchObject({
      ts: ts + 100,
      type: "tool_request",
      tool_call_id: "tc_1",
      tool: "bash",
      args: { command: "ls" },
    });
    // agent_message in_reply_to should point at the prior user_input id
    expect((events[1] as { in_reply_to: string }).in_reply_to).toBe(`sync_${ts}`);
  });

  test("mapping (plan/30 re-sync): user [image, text] → user_input keeps images", () => {
    const ts = 1_700_000_000_000;
    const events = _mapAgentMessagesToEvents([
      {
        role: "user",
        content: [
          { type: "image", data: "QUJD", mimeType: "image/jpeg" },
          { type: "text", text: "what is this?" },
        ],
        timestamp: ts,
      },
    ]);
    expect(events).toHaveLength(1);
    expect(events[0]).toMatchObject({
      ts,
      type: "user_input",
      text: "what is this?",
      images: [{ data: "QUJD", mime: "image/jpeg" }],
    });
  });

  test("mapping: text-only user message → no `images` key (path unchanged)", () => {
    const events = _mapAgentMessagesToEvents([
      { role: "user", content: "just text", timestamp: 1 },
    ]);
    expect(events).toHaveLength(1);
    expect(events[0]).toMatchObject({ type: "user_input", text: "just text" });
    expect(events[0]).not.toHaveProperty("images");
  });

  test("mapping (plan/32): compaction marker → compaction event (history re-sync)", () => {
    const events = _mapAgentMessagesToEvents([
      { role: "user", content: "hi", timestamp: 1 },
      { role: "compaction", content: "summarised 10 turns", timestamp: 1700, tokensBefore: 12345 },
    ]);
    expect(events).toHaveLength(2);
    expect(events[1]).toMatchObject({
      ts: 1700,
      type: "compaction",
      summary: "summarised 10 turns",
      tokens_before: 12345,
    });
  });

  test("pair_ok carries session_started_at = _sessionStartedAt", async () => {
    const beforePair = Date.now();
    await _pairForTest("peer-ss-5");
    const afterPair = Date.now();

    const sent = relayRef.current!.send.mock.calls.map((c) => c[0] as string);
    const pairOks = sent.map(decodeSentCt).filter((d) => d.inner.type === "pair_ok");
    expect(pairOks).toHaveLength(1);
    const tsField = pairOks[0]!.inner["session_started_at"] as number;
    expect(typeof tsField).toBe("number");
    expect(tsField).toBeGreaterThanOrEqual(beforePair);
    expect(tsField).toBeLessThanOrEqual(afterPair);
  });

  test("pair_ok carries room_id so the app can address subsequent inners", async () => {
    await _pairForTest("peer-ss-room");

    const sent = relayRef.current!.send.mock.calls.map((c) => c[0] as string);
    const pairOks = sent.map(decodeSentCt).filter((d) => d.inner.type === "pair_ok");
    expect(pairOks).toHaveLength(1);
    const roomId = pairOks[0]!.inner["room_id"] as unknown;
    expect(typeof roomId).toBe("string");
    expect(roomId as string).toMatch(/^[A-Za-z0-9_-]{12}$/);
  });
});

// ── explicit bye on stop / revoke-active ──────────────────────────────────────

describe("bye on teardown", () => {
  beforeEach(async () => {
    vi.clearAllMocks();
    _knownPeers.length = 0;
    _addedPeers.length = 0;
    _removedPeers.length = 0;
    _consumeCalls.length = 0;
    _setRelayCalls.length = 0;
    _savedRelayUrl = null;
    _tokenStatus = "ok";
    relayRef.current = null;
    const qr = await import("./pairing/qr.js");
    (qr.qrSession.consumeToken as unknown as ReturnType<typeof vi.fn>).mockImplementation(
      (token: string) => {
        _consumeCalls.push(token);
        return _tokenStatus;
      },
    );
    const stop = captureHandler("remote-pi stop");
    await stop("", makeMockCtx());
  });

  test("paired + /remote-pi stop → channel.send sees bye{peer_stop} BEFORE detach", async () => {
    await _pairForTest("peer-bye-1");
    const sendsBefore = relayRef.current!.send.mock.calls.length;

    const stop = captureHandler("remote-pi stop");
    await stop("", makeMockCtx());

    const sent = relayRef.current!.send.mock.calls.slice(sendsBefore).map((c) => c[0] as string);
    const decoded = sent.map(decodeSentCt);
    const byeIdx = decoded.findIndex((d) => d.inner.type === "bye");
    expect(byeIdx).toBeGreaterThanOrEqual(0);
    expect(decoded[byeIdx]!.inner).toMatchObject({ type: "bye", reason: "peer_stop" });
    expect(decoded[byeIdx]!.peer).toBe("peer-bye-1");
    // After the bye, no more sends to that peer (channel detached)
    const afterBye = decoded.slice(byeIdx + 1);
    expect(afterBye).toHaveLength(0);
    expect(_getState()).toBe("idle");
  });

  test("started (no peer paired) + /remote-pi stop → no bye sent (channel is null)", async () => {
    captureHandler("remote-pi");
    await _connectForTest(makeMockCtx());
    expect(_getState()).toBe("started");
    const sendsBefore = relayRef.current!.send.mock.calls.length;

    const stop = captureHandler("remote-pi stop");
    await stop("", makeMockCtx());

    const sent = relayRef.current!.send.mock.calls.slice(sendsBefore).map((c) => c[0] as string);
    const byes = sent.map(decodeSentCt).filter((d) => d.inner.type === "bye");
    expect(byes).toHaveLength(0);
    expect(_getState()).toBe("idle");
  });

  test("revoke of attached owner → channel sees bye{session_replaced}, relay stays started", async () => {
    _tokenStatus = "ok";
    const ACTIVE = OWNER_STANDARD_FIXTURE;
    // Attach the peer so it lives in _activePeers
    await _pairForTest(ACTIVE);
    const sendsBefore = relayRef.current!.send.mock.calls.length;

    const revoke = captureHandler("remote-pi revoke");
    await revoke(OWNER_STANDARD_FIXTURE.slice(0, 8), makeMockCtx());

    const sent = relayRef.current!.send.mock.calls.slice(sendsBefore).map((c) => c[0] as string);
    const byes = sent.map(decodeSentCt).filter((d) => d.inner.type === "bye");
    expect(byes).toHaveLength(1);
    expect(byes[0]!.inner).toMatchObject({ type: "bye", reason: "session_replaced" });
    // Multi-channel (W2D): only this owner's channel is closed; the relay
    // stays up, ready for new pairings. Pre-W2D this dropped to idle.
    expect(_hasActivePeerForTest(ACTIVE)).toBe(false);
    expect(_getState()).toBe("started");
  });
});

// ── session_shutdown teardown (cockpit double-conn fix) ────────────────────────

describe("session shutdown and relay reconnect", () => {
  beforeEach(async () => {
    vi.clearAllMocks();
    _knownPeers.length = 0;
    relayRef.current = null;
    relayInstances.length = 0;
    _defaultConnectImpl = async () => undefined;
    _setDisposedForTest(false);
    const stop = captureHandler("remote-pi stop");
    await stop("", makeMockCtx());
  });

  test("session_shutdown closes Relay and leaves process idle", async () => {
    await _connectForTest(makeMockCtx());
    const relay = relayRef.current!;
    const shutdown = captureEventHandler("session_shutdown");

    await shutdown({ type: "session_shutdown", reason: "resume" });

    expect(relay.close).toHaveBeenCalledTimes(1);
    expect(_getState()).toBe("idle");
  });

  test("session replacement restarts Relay without reviving outgoing candidate", async () => {
    const firstConnect = deferred<void>();
    let attempts = 0;
    _defaultConnectImpl = () => (++attempts === 1 ? firstConnect.promise : Promise.resolve());
    process.env["REMOTE_PI_DIRECT_CONFIG"] = JSON.stringify({
      agent_name: "replacement",
      auto_start_relay: true,
    });
    _setAutoInitedForTest(true);
    const cwd = `/tmp/remote-pi-replacement-${process.pid}-${Date.now()}`;
    const root = captureHandler("remote-pi");
    const outgoing = root("", makeMockCtx(cwd));
    await vi.waitFor(() => expect(relayInstances).toHaveLength(1));
    const outgoingRelay = relayInstances[0]!;

    const shutdown = captureEventHandler("session_shutdown");
    await shutdown({ type: "session_shutdown", reason: "resume" });
    const sessionStart = captureEventHandler("session_start");
    sessionStart({ type: "session_start" }, makeMockCtx(cwd));
    firstConnect.resolve(undefined);
    await outgoing;

    await vi.waitFor(() => {
      expect(relayInstances).toHaveLength(2);
      expect(_getState()).toBe("started");
    });
    expect(outgoingRelay.close).toHaveBeenCalledTimes(1);
    delete process.env["REMOTE_PI_DIRECT_CONFIG"];
    _setAutoInitedForTest(false);
  });

  test("idle replacement stays idle when auto_start_relay is false", async () => {
    const cwd = `/tmp/remote-pi-idle-replacement-${process.pid}-${Date.now()}`;
    process.env["REMOTE_PI_DIRECT_CONFIG"] = JSON.stringify({
      agent_name: "idle-replacement",
      auto_start_relay: false,
    });
    const shutdown = captureEventHandler("session_shutdown");
    await shutdown({ type: "session_shutdown", reason: "resume" });
    const sessionStart = captureEventHandler("session_start");
    sessionStart({ type: "session_start" }, makeMockCtx(cwd));
    await new Promise<void>((resolve) => setImmediate(resolve));

    expect(relayInstances).toHaveLength(0);
    expect(_getState()).toBe("idle");
    delete process.env["REMOTE_PI_DIRECT_CONFIG"];
  });

  test("unexpected Relay close reconnects after backoff", async () => {
    vi.useFakeTimers();
    try {
      await _connectForTest(makeMockCtx());
      relayInstances[0]!.emit("close");
      expect(_hasPendingReconnect()).toBe(true);
      expect(_getState()).toBe("started");

      await vi.advanceTimersByTimeAsync(1_000);

      expect(relayInstances).toHaveLength(2);
      expect(_hasPendingReconnect()).toBe(false);
      expect(_getState()).toBe("started");
    } finally {
      vi.useRealTimers();
    }
  });

  test("stop cancels scheduled reconnect", async () => {
    vi.useFakeTimers();
    try {
      await _connectForTest(makeMockCtx());
      relayInstances[0]!.emit("close");
      const stop = captureHandler("remote-pi stop");
      await stop("", makeMockCtx());

      await vi.advanceTimersByTimeAsync(60_000);

      expect(relayInstances).toHaveLength(1);
      expect(_hasPendingReconnect()).toBe(false);
      expect(_getState()).toBe("idle");
    } finally {
      vi.useRealTimers();
    }
  });
});

describe("remote-pi:name-assigned event", () => {
  beforeEach(async () => {
    vi.clearAllMocks();
    _knownPeers.length = 0;
    _addedPeers.length = 0;
    _removedPeers.length = 0;
    _consumeCalls.length = 0;
    _setRelayCalls.length = 0;
    _savedRelayUrl = null;
    _tokenStatus = "ok";
    relayRef.current = null;
    relayInstances.length = 0;
    _defaultConnectImpl = async () => undefined;
    _setDisposedForTest(false);
    const stop = captureHandler("remote-pi stop");
    await stop("", makeMockCtx());
  });

  test("direct Relay start emits current session name for Cockpit", async () => {
    const sendMessage = vi.fn();
    const spyPi = {
      on: () => undefined, registerCommand: () => undefined,
      registerTool: () => undefined, registerShortcut: () => undefined,
      registerFlag: () => undefined, getFlag: () => undefined,
      registerMessageRenderer: () => undefined,
      sendMessage, sendUserMessage: () => undefined,
    } as unknown as ExtensionAPI;
    captureHandler("remote-pi");
    _setPiForTest(spyPi);

    const ctx = makeMockCtx(
      `/tmp/remote-pi-name-assigned-${process.pid}-${Date.now()}`,
    );
    await _connectForTest(ctx);
    expect(_getState()).toBe("started");

    const ev = sendMessage.mock.calls
      .map((c) => c[0] as { customType?: string; display?: boolean; details?: Record<string, unknown> })
      .find((m) => m?.customType === "remote-pi:name-assigned");
    expect(ev).toBeDefined();
    expect(ev!.display).toBe(false);
    expect(ev!.details).toMatchObject({ changed: false });
    expect(typeof ev!.details!["requested"]).toBe("string");
    expect(ev!.details!["assigned"]).toBe(ev!.details!["requested"]);
  });
});

describe("relay control channel + relay-state event", () => {
  function makeSpyPi(sendMessage: ReturnType<typeof vi.fn>) {
    let sessionName = "pi-extension";
    return {
      on: () => undefined, registerCommand: () => undefined,
      registerTool: () => undefined, registerShortcut: () => undefined,
      registerFlag: () => undefined, getFlag: () => undefined,
      registerMessageRenderer: () => undefined,
      getSessionName: () => sessionName,
      setSessionName: (name: string) => { sessionName = name; },
      sendMessage, sendUserMessage: () => undefined,
    } as unknown as ExtensionAPI;
  }
  const lastRelayState = (sendMessage: ReturnType<typeof vi.fn>) =>
    sendMessage.mock.calls
      .map((c) => c[0] as { customType?: string; display?: boolean; details?: Record<string, unknown> })
      .reverse()
      .find((m) => m?.customType === "remote-pi:relay-state");

  beforeEach(async () => {
    vi.clearAllMocks();
    _knownPeers.length = 0;
    _consumeCalls.length = 0;
    _setRelayCalls.length = 0;
    _savedRelayUrl = null;
    _tokenStatus = "ok";
    relayRef.current = null;
    relayInstances.length = 0;
    _defaultConnectImpl = async () => undefined;
    _setDisposedForTest(false);
    const stop = captureHandler("remote-pi stop");
    await stop("", makeMockCtx());
  });

  // Transparency: a CTRL_PREFIX-tagged input is swallowed by the `input` hook
  // so it never reaches the LLM or the transcript — the path the Cockpit button
  // uses to toggle the relay without a visible turn.
  test("input hook swallows a CTRL_PREFIX control message (action:handled)", () => {
    const input = captureEventHandler("input");
    const result = input({ type: "input", text: `${CTRL_PREFIX}relay:status`, source: "rpc" });
    expect(result).toEqual({ action: "handled" });
  });

  test("a normal (non-control) input is NOT swallowed", () => {
    const input = captureEventHandler("input");
    const result = input({ type: "input", text: "hello world", source: "rpc" });
    expect(result).toBeUndefined();
  });

  test("relay:status emits remote-pi:relay-state 'disconnected' while idle", async () => {
    const sendMessage = vi.fn();
    captureHandler("remote-pi");
    _setPiForTest(makeSpyPi(sendMessage));
    expect(_getState()).toBe("idle");

    await _handleControl("relay:status");

    const ev = lastRelayState(sendMessage);
    expect(ev).toBeDefined();
    expect(ev!.display).toBe(false);
    expect(ev!.details).toMatchObject({ status: "disconnected", connected: false });
  });

  test("relay:on → relay up + 'connected'; relay:off → relay down + 'disconnected'", async () => {
    const sendMessage = vi.fn();
    captureHandler("remote-pi");
    _setPiForTest(makeSpyPi(sendMessage));

    await _handleControl("relay:on");
    expect(_getState()).toBe("started");
    expect(lastRelayState(sendMessage)!.details).toMatchObject({ status: "connected", connected: true });

    sendMessage.mockClear();
    await _handleControl("relay:off");
    expect(_getState()).toBe("idle");
    expect(lastRelayState(sendMessage)!.details).toMatchObject({ status: "disconnected", connected: false });
  });

  test("relay:toggle flips idle → started → idle", async () => {
    captureHandler("remote-pi");
    _setPiForTest(makeSpyPi(vi.fn()));
    expect(_getState()).toBe("idle");
    await _handleControl("relay:toggle");
    expect(_getState()).toBe("started");
    await _handleControl("relay:toggle");
    expect(_getState()).toBe("idle");
  });

  // Plan 61 Phase 1 — a rename is METADATA. This test used to assert the
  // opposite ("restarts Relay room"): the room id was `roomIdFor(cwd, name)`,
  // so publishing a rename meant closing the WS and re-registering under a new
  // id. The app saw `room_ended` + a brand-new tile, the Hive box holding the
  // conversation was orphaned under the dead id, and any streaming turn on the
  // socket died with it. `room_id == session_id` now, so nothing moves.
  test("rename:<name> patches room_meta and does NOT cycle the Relay room", async () => {
    const sendMessage = vi.fn();
    captureHandler("remote-pi");
    _setPiForTest(makeSpyPi(sendMessage));
    await _connectForTest(makeMockCtx());
    expect(_getState()).toBe("started");
    const firstRelay = relayRef.current!;

    sendMessage.mockClear();
    firstRelay.sendControl.mockClear();
    await _handleControl("rename:Renamed");

    expect(firstRelay.close).not.toHaveBeenCalled();
    expect(relayInstances).toHaveLength(1);
    expect(relayRef.current).toBe(firstRelay);
    expect(_getState()).toBe("started");

    const patch = firstRelay.sendControl.mock.calls
      .map((c) => c[0] as { type: string; room_id?: string; meta?: { name?: string; name_rev?: number } })
      .reverse()
      .find((f) => f?.type === "room_meta_update" && f.meta?.name !== undefined);
    expect(patch).toBeDefined();
    expect(patch!.meta!.name).toBe("Renamed");
    expect(typeof patch!.meta!.name_rev).toBe("number");
    expect(patch!.room_id).toBe(_getRoomIdForTest());

    // Cockpit is told the new effective name via remote-pi:name-assigned.
    const ev = sendMessage.mock.calls
      .map((c) => c[0] as { customType?: string; display?: boolean; details?: Record<string, unknown> })
      .reverse()
      .find((m) => m?.customType === "remote-pi:name-assigned");
    expect(ev).toBeDefined();
    expect(ev!.display).toBe(false);
    expect(ev!.details).toMatchObject({ requested: "Renamed", assigned: "Renamed", changed: false });

    const stop = captureHandler("remote-pi stop");
    await stop("", makeMockCtx());
  });

  // The revision has to keep climbing, otherwise the relay (which only accepts
  // a strictly-newer `name_rev`) would reject the second rename and the label
  // would stick on the first one.
  test("successive renames carry strictly increasing name_rev", async () => {
    captureHandler("remote-pi");
    _setPiForTest(makeSpyPi(vi.fn()));
    await _connectForTest(makeMockCtx());
    const relay = relayRef.current!;
    relay.sendControl.mockClear();

    await _handleControl("rename:One");
    await _handleControl("rename:Two");

    const revs = relay.sendControl.mock.calls
      .map((c) => c[0] as { type: string; meta?: { name?: string; name_rev?: number } })
      .filter((f) => f?.type === "room_meta_update" && f.meta?.name !== undefined)
      .map((f) => f.meta!.name_rev!);
    expect(revs.length).toBeGreaterThanOrEqual(2);
    expect(revs[revs.length - 1]!).toBeGreaterThan(revs[revs.length - 2]!);

    const stop = captureHandler("remote-pi stop");
    await stop("", makeMockCtx());
  });

  test("empty rename is a no-op", async () => {
    captureHandler("remote-pi");
    _setPiForTest(makeSpyPi(vi.fn()));
    await expect(_handleControl("rename:")).resolves.toBeUndefined();
  });
});

// ── print/-p mode never auto-starts the relay (issue #44) ────────────────────
describe("session_start auto-init skips relay in print/-p mode (#44)", () => {
  const savedArgv = process.argv;
  beforeEach(async () => {
    vi.clearAllMocks();
    _knownPeers.length = 0;
    _consumeCalls.length = 0;
    relayRef.current = null;
    relayInstances.length = 0;
    _defaultConnectImpl = async () => undefined;
    _setDisposedForTest(false);
    _resetAutoInitedForTest();
    const stop = captureHandler("remote-pi stop");
    await stop("", makeMockCtx());
    _resetAutoInitedForTest();
  });
  afterEach(() => {
    process.argv = savedArgv;
    delete process.env["REMOTE_PI_DIRECT_CONFIG"];
  });

  // A one-shot `pi -p "..."` prints its answer and must exit. Auto-starting the
  // relay opens a WS that is never `.unref()`'d, so the process would hang.
  test("`pi -p` does not start Relay", async () => {
    process.env["REMOTE_PI_DIRECT_CONFIG"] = JSON.stringify({
      agent_name: "PrintAgent",
      auto_start_relay: true,
    });
    process.argv = ["node", "pi", "-p", "Say hello in one word."];
    const onSessionStart = captureEventHandler("session_start");
    _resetAutoInitedForTest();
    onSessionStart({ type: "session_start" }, makeMockCtx("/home/user/projects/rp-print"));
    await new Promise<void>((r) => setTimeout(r, 20));

    expect(_getState()).toBe("idle");
    expect(relayInstances).toHaveLength(0);
  });

  // Guard the negative: a normal interactive session_start (no -p/--print) still
  // auto-starts exactly as before, so the fix doesn't disable auto-init at large.
  test("interactive session_start auto-starts Relay when enabled", async () => {
    process.env["REMOTE_PI_DIRECT_CONFIG"] = JSON.stringify({
      agent_name: "InteractiveAgent",
      auto_start_relay: true,
    });
    process.argv = ["node", "pi"];
    const onSessionStart = captureEventHandler("session_start");
    _resetAutoInitedForTest();
    onSessionStart({ type: "session_start" }, makeMockCtx("/home/user/projects/rp-interactive"));
    await new Promise<void>((r) => setTimeout(r, 20));

    expect(_getState()).toBe("started");
    expect(relayInstances).toHaveLength(1);
  });

  test("auto_start_relay false gates automatic startup only; /remote-pi starts directly", async () => {
    process.env["REMOTE_PI_DIRECT_CONFIG"] = JSON.stringify({
      agent_name: "ManualAgent",
      auto_start_relay: false,
    });
    process.argv = ["node", "pi"];
    const cwd = "/home/user/projects/rp-manual";
    const onSessionStart = captureEventHandler("session_start");
    _resetAutoInitedForTest();
    onSessionStart({ type: "session_start" }, makeMockCtx(cwd));
    await new Promise<void>((r) => setTimeout(r, 20));
    expect(relayInstances).toHaveLength(0);

    const root = captureHandler("remote-pi");
    await root("", makeMockCtx(cwd));

    expect(relayInstances).toHaveLength(1);
    expect(_getState()).toBe("started");
  });

  test("manual startup creates no local agent socket", async () => {
    const cwd = mkdtempSync(join(tmpdir(), "remote-pi-no-mesh-socket-"));
    process.env["REMOTE_PI_DIRECT_CONFIG"] = JSON.stringify({
      agent_name: "NoSocket",
      auto_start_relay: false,
    });
    const root = captureHandler("remote-pi");

    await root("", makeMockCtx(cwd));

    const entries = readdirSync(cwd, { recursive: true }).map(String);
    expect(entries.some((entry) => entry.endsWith(".sock"))).toBe(false);
    expect(entries.some((entry) => entry.includes("broker"))).toBe(false);
    expect(_getState()).toBe("started");
    rmSync(cwd, { recursive: true, force: true });
  });
});

// ── cumulative message buffer (post-fix 15) ───────────────────────────────────

describe("cumulative buffer", () => {
  beforeEach(async () => {
    vi.clearAllMocks();
    _knownPeers.length = 0;
    _addedPeers.length = 0;
    _removedPeers.length = 0;
    _consumeCalls.length = 0;
    _setRelayCalls.length = 0;
    _savedRelayUrl = null;
    _tokenStatus = "ok";
    relayRef.current = null;
    relayInstances.length = 0;
    _defaultConnectImpl = async () => undefined;
    const qr = await import("./pairing/qr.js");
    (qr.qrSession.consumeToken as unknown as ReturnType<typeof vi.fn>).mockImplementation(
      (token: string) => {
        _consumeCalls.push(token);
        return _tokenStatus;
      },
    );
    const stop = captureHandler("remote-pi stop");
    await stop("", makeMockCtx());
    _setMessageBufferForTest([]);
    _setSessionStartedAtForTest(null);
  });

  test("3 turns via message_end → session_sync returns 6 events (no overwrite)", async () => {
    await _pairForTest("peer-mt");
    const onMsgEnd = captureEventHandler("message_end");
    const baseTs = 1_700_000_000_000;

    for (let i = 0; i < 3; i++) {
      const turnTs = baseTs + i * 10_000;
      onMsgEnd({
        type: "message_end",
        message: {
          role: "user",
          content: [{ type: "text", text: `prompt ${i + 1}` }],
          timestamp: turnTs + 100,
        },
      });
      onMsgEnd({
        type: "message_end",
        message: {
          role: "assistant",
          content: [{ type: "text", text: `reply ${i + 1}` }],
          timestamp: turnTs + 200,
          usage: { input: 10, output: 5 },
        },
      });
    }

    expect(_getMessageBufferForTest()).toHaveLength(6);

    const sessionTs = baseTs;
    _setSessionStartedAtForTest(sessionTs);
    const sendsBefore = relayRef.current!.send.mock.calls.length;
    routeClientMessage(
      { type: "session_sync", id: "mt-1" },
      { abort: () => undefined },
    );

    const sent = relayRef.current!.send.mock.calls.slice(sendsBefore).map((c) => c[0] as string);
    const histories = sent.map(decodeSentCt).filter((d) => d.inner.type === "session_history");
    expect(histories).toHaveLength(1);
    const events = histories[0]!.inner["events"] as Array<{ type: string; text?: string }>;
    expect(events).toHaveLength(6);
    expect(events.map((e) => e.type)).toEqual([
      "user_input", "agent_message",
      "user_input", "agent_message",
      "user_input", "agent_message",
    ]);
    expect(events[0]!.text).toBe("prompt 1");
    expect(events[2]!.text).toBe("prompt 2");
    expect(events[4]!.text).toBe("prompt 3");
  });

  test("mixed sources (extension + interactive) all land in buffer ordered by ts", async () => {
    await _pairForTest("peer-mix");
    const onInput = captureEventHandler("input");
    const onMsgEnd = captureEventHandler("message_end");
    const baseTs = 1_700_100_000_000;

    // Turn A — via extension (app)
    onInput({ type: "input", text: "from app", source: "extension" });
    onMsgEnd({ type: "message_end", message: { role: "user", content: "from app", timestamp: baseTs + 1000 } });
    onMsgEnd({ type: "message_end", message: { role: "assistant", content: [{ type: "text", text: "reply A" }], timestamp: baseTs + 2000 } });

    // Turn B — via interactive (terminal)
    onInput({ type: "input", text: "from term 1", source: "interactive" });
    onMsgEnd({ type: "message_end", message: { role: "user", content: "from term 1", timestamp: baseTs + 3000 } });
    onMsgEnd({ type: "message_end", message: { role: "assistant", content: [{ type: "text", text: "reply B" }], timestamp: baseTs + 4000 } });

    // Turn C — via interactive (terminal)
    onInput({ type: "input", text: "from term 2", source: "interactive" });
    onMsgEnd({ type: "message_end", message: { role: "user", content: "from term 2", timestamp: baseTs + 5000 } });
    onMsgEnd({ type: "message_end", message: { role: "assistant", content: [{ type: "text", text: "reply C" }], timestamp: baseTs + 6000 } });

    expect(_getMessageBufferForTest()).toHaveLength(6);

    _setSessionStartedAtForTest(baseTs);
    const sendsBefore = relayRef.current!.send.mock.calls.length;
    routeClientMessage(
      { type: "session_sync", id: "mix-1" },
      { abort: () => undefined },
    );

    const sent = relayRef.current!.send.mock.calls.slice(sendsBefore).map((c) => c[0] as string);
    const histories = sent.map(decodeSentCt).filter((d) => d.inner.type === "session_history");
    const events = histories[0]!.inner["events"] as Array<{ ts: number; type: string; text?: string }>;
    expect(events).toHaveLength(6);
    // Strictly ascending ts
    for (let i = 1; i < events.length; i++) {
      expect(events[i]!.ts).toBeGreaterThan(events[i - 1]!.ts);
    }
    const userTexts = events.filter((e) => e.type === "user_input").map((e) => e.text);
    expect(userTexts).toEqual(["from app", "from term 1", "from term 2"]);
  });

  test("toolCall + toolResult in same turn → tool_request + tool_result events", async () => {
    await _pairForTest("peer-tools");
    const onMsgEnd = captureEventHandler("message_end");
    const ts = 1_700_200_000_000;

    // user prompt
    onMsgEnd({ type: "message_end", message: { role: "user", content: "do bash", timestamp: ts } });
    // assistant message that contains a tool call block
    onMsgEnd({
      type: "message_end",
      message: {
        role: "assistant",
        content: [
          { type: "text", text: "running" },
          { type: "toolCall", id: "tc_1", name: "bash", arguments: { command: "ls" } },
        ],
        timestamp: ts + 100,
      },
    });
    // tool result message
    onMsgEnd({
      type: "message_end",
      message: {
        role: "toolResult",
        toolCallId: "tc_1",
        toolName: "bash",
        content: [{ type: "text", text: "file1\nfile2" }],
        isError: false,
        timestamp: ts + 200,
      },
    });

    expect(_getMessageBufferForTest()).toHaveLength(3);

    _setSessionStartedAtForTest(ts);
    const sendsBefore = relayRef.current!.send.mock.calls.length;
    routeClientMessage(
      { type: "session_sync", id: "t-1" },
      { abort: () => undefined },
    );

    const sent = relayRef.current!.send.mock.calls.slice(sendsBefore).map((c) => c[0] as string);
    const events = (
      sent.map(decodeSentCt).find((d) => d.inner.type === "session_history")!.inner["events"]
    ) as Array<{ type: string; tool_call_id?: string }>;
    const types = events.map((e) => e.type);
    expect(types).toEqual(["user_input", "agent_message", "tool_request", "tool_result"]);
    expect(events[2]!.tool_call_id).toBe("tc_1");
    expect(events[3]!.tool_call_id).toBe("tc_1");
  });

  test("_cmdStart preserves buffer across stop/start cycle (Pi session outlives relay)", async () => {
    // Simulates: user runs /remote-pi start, exchanges messages, /remote-pi
    // stop, types in terminal (message_end fires while idle), /remote-pi
    // start again. The terminal turns must NOT be wiped by the second start.
    _setMessageBufferForTest([
      { role: "user", content: "old", timestamp: 1 },
      { role: "assistant", content: [{ type: "text", text: "old" }], timestamp: 2 },
    ]);
    expect(_getMessageBufferForTest()).toHaveLength(2);

    captureHandler("remote-pi");
    await _connectForTest(makeMockCtx());

    expect(_getMessageBufferForTest()).toHaveLength(2);  // PRESERVED
  });

  test("_goIdle preserves buffer + sessionStartedAt across /remote-pi stop", async () => {
    captureHandler("remote-pi");
    await _connectForTest(makeMockCtx());

    const onMsgEnd = captureEventHandler("message_end");
    onMsgEnd({ type: "message_end", message: { role: "user", content: "x", timestamp: 100 } });
    onMsgEnd({ type: "message_end", message: { role: "assistant", content: [{ type: "text", text: "y" }], timestamp: 200 } });
    expect(_getMessageBufferForTest()).toHaveLength(2);

    const stop = captureHandler("remote-pi stop");
    await stop("", makeMockCtx());
    expect(_getState()).toBe("idle");
    expect(_getMessageBufferForTest()).toHaveLength(2);  // PRESERVED across stop

    // Simulate terminal turn during idle window
    onMsgEnd({ type: "message_end", message: { role: "user", content: "terminal", timestamp: 300 } });
    onMsgEnd({ type: "message_end", message: { role: "assistant", content: [{ type: "text", text: "terminal reply" }], timestamp: 400 } });
    expect(_getMessageBufferForTest()).toHaveLength(4);

    // Start again → buffer still has all 4
    await _connectForTest(makeMockCtx());
    expect(_getMessageBufferForTest()).toHaveLength(4);
  });

  test("_onRelayClose preserves buffer (regression — buffer must survive reconnect)", async () => {
    vi.useFakeTimers();
    try {
      captureHandler("remote-pi");
      await _connectForTest(makeMockCtx());

      const onMsgEnd = captureEventHandler("message_end");
      onMsgEnd({ type: "message_end", message: { role: "user", content: "x", timestamp: 100 } });
      onMsgEnd({ type: "message_end", message: { role: "assistant", content: [{ type: "text", text: "y" }], timestamp: 200 } });
      expect(_getMessageBufferForTest()).toHaveLength(2);

      // Force relay close → _onRelayClose path
      relayInstances[0]!.emit("close");
      // Don't even wait for reconnect — just verify buffer survives the close
      expect(_getMessageBufferForTest()).toHaveLength(2);

      // After reconnect, still preserved
      await vi.advanceTimersByTimeAsync(1_000);
      expect(_getMessageBufferForTest()).toHaveLength(2);
    } finally {
      vi.useRealTimers();
    }
  });
});

// ── model meta in room_meta + model_select hook ──────────────────────────────

describe("model meta", () => {
  beforeEach(async () => {
    vi.clearAllMocks();
    _knownPeers.length = 0;
    _addedPeers.length = 0;
    _removedPeers.length = 0;
    _consumeCalls.length = 0;
    _setRelayCalls.length = 0;
    _savedRelayUrl = null;
    _tokenStatus = "ok";
    relayRef.current = null;
    relayInstances.length = 0;
    _defaultConnectImpl = async () => undefined;
    delete process.env["REMOTE_PI_RELAY"];
    _setCurrentModelForTest(undefined);
    const qr = await import("./pairing/qr.js");
    (qr.qrSession.consumeToken as unknown as ReturnType<typeof vi.fn>).mockImplementation(
      (token: string) => {
        _consumeCalls.push(token);
        return _tokenStatus;
      },
    );
    const stop = captureHandler("remote-pi stop");
    await stop("", makeMockCtx());
  });

  test("hello carries `model` in room_meta when ctx.model is set", async () => {
    const capturedOpts: Array<{ roomMeta?: { model?: string; name?: string; cwd?: string } }> = [];
    _defaultConnectImpl = async (opts?: unknown) => {
      capturedOpts.push(opts as { roomMeta?: { model?: string; name?: string; cwd?: string } });
    };

    captureHandler("remote-pi");
    const ctx = {
      ui: { notify: vi.fn() },
      cwd: "/tmp/remote-pi-model-test",
      abort: vi.fn(),
      model: { id: "claude-sonnet-4-5", name: "claude-sonnet-4.5" },
    } as unknown as ReturnType<typeof makeMockCtx>;
    await _connectForTest(ctx);

    expect(capturedOpts).toHaveLength(1);
    expect(capturedOpts[0]!.roomMeta?.model).toBe("claude-sonnet-4.5");
    expect(capturedOpts[0]!.roomMeta?.name).toBeTruthy();
    expect(capturedOpts[0]!.roomMeta?.cwd).toBe("/tmp/remote-pi-model-test");
  });

  test("hello carries `model` from getModel() when ctx.model is absent (daemon path)", async () => {
    const capturedOpts: Array<{ roomMeta?: { model?: string } }> = [];
    _defaultConnectImpl = async (opts?: unknown) => {
      capturedOpts.push(opts as { roomMeta?: { model?: string } });
    };

    captureHandler("remote-pi");
    // A headless daemon never fires model_select and has no `ctx.model`, but
    // its session resolved a default model that getModel() exposes — the fix
    // seeds room_meta from there so the app no longer shows "unknown".
    const ctx = {
      ui: { notify: vi.fn() },
      cwd: "/tmp/remote-pi-daemon-model",
      abort: vi.fn(),
      getModel: () => ({ id: "claude-opus-4-8", name: "claude-opus-4.8" }),
    } as unknown as ReturnType<typeof makeMockCtx>;
    await _connectForTest(ctx);

    expect(capturedOpts).toHaveLength(1);
    expect(capturedOpts[0]!.roomMeta?.model).toBe("claude-opus-4.8");
  });

  test("hello omits `model` when ctx has none AND no default is configured", async () => {
    // Isolate from the machine's global settings (PI_CODING_AGENT_DIR → a
    // non-existent dir) so the settings fallback finds no default model; the
    // /tmp cwd has no project .pi/settings.json either.
    const prevAgentDir = process.env["PI_CODING_AGENT_DIR"];
    process.env["PI_CODING_AGENT_DIR"] = "/tmp/pi-no-such-agent-dir-omit";
    try {
      const capturedOpts: Array<{ roomMeta?: { model?: string } }> = [];
      _defaultConnectImpl = async (opts?: unknown) => {
        capturedOpts.push(opts as { roomMeta?: { model?: string } });
      };

      captureHandler("remote-pi");
      await _connectForTest(makeMockCtx("/tmp/remote-pi-no-model"));

      expect(capturedOpts).toHaveLength(1);
      expect(capturedOpts[0]!.roomMeta?.model).toBeUndefined();
    } finally {
      if (prevAgentDir === undefined) delete process.env["PI_CODING_AGENT_DIR"];
      else process.env["PI_CODING_AGENT_DIR"] = prevAgentDir;
    }
  });

  test("hello carries `model` from configured default settings (idle daemon path)", async () => {
    // A headless daemon has no ctx.model/getModel at connect (the SDK resolves
    // the session model lazily at the first turn). The fix reads the configured
    // default from <cwd>/.pi/settings.json — the model the daemon WILL use.
    const cwd = mkdtempSync(join(tmpdir(), "pi-daemon-cfg-"));
    mkdirSync(join(cwd, ".pi"), { recursive: true });
    writeFileSync(
      join(cwd, ".pi", "settings.json"),
      JSON.stringify({ defaultProvider: "acme", defaultModel: "acme-model-zzz" }),
    );
    const prevAgentDir = process.env["PI_CODING_AGENT_DIR"];
    process.env["PI_CODING_AGENT_DIR"] = "/tmp/pi-no-such-agent-dir-daemon";
    try {
      const capturedOpts: Array<{ roomMeta?: { model?: string } }> = [];
      _defaultConnectImpl = async (opts?: unknown) => {
        capturedOpts.push(opts as { roomMeta?: { model?: string } });
      };

      captureHandler("remote-pi");
      await _connectForTest(makeMockCtx(cwd));  // ctx has no model/getModel

      expect(capturedOpts).toHaveLength(1);
      // The test registry won't know "acme-model-zzz" → falls back to the id.
      expect(capturedOpts[0]!.roomMeta?.model).toBe("acme-model-zzz");
    } finally {
      if (prevAgentDir === undefined) delete process.env["PI_CODING_AGENT_DIR"];
      else process.env["PI_CODING_AGENT_DIR"] = prevAgentDir;
      rmSync(cwd, { recursive: true, force: true });
    }
  });

  test("relay room_meta name exactly matches the Pi session name", async () => {
    const capturedOpts: Array<{ roomMeta?: { name?: string } }> = [];
    _defaultConnectImpl = async (opts?: unknown) => {
      capturedOpts.push(opts as { roomMeta?: { name?: string } });
    };

    captureHandler("remote-pi");
    _setPiForTest({
      getSessionName: () => "dotfiles-019ffb64",
      getThinkingLevel: () => "high",
    });
    await _connectForTest(makeMockCtx("/tmp/mesh-config-must-not-be-the-display-name"));

    expect(capturedOpts).toHaveLength(1);
    expect(capturedOpts[0]!.roomMeta?.name).toBe("dotfiles-019ffb64");
  });

  // Plan 61 Phase 1 — a Pi-side rename (`/name`, which surfaces as
  // `session_info_changed`) publishes the new label as a patch. It used to
  // REOPEN the relay under a name-derived room id; the stale-ctx scaffolding
  // below is what that reopen kept tripping over. Now there is no reopen at
  // all, and the stale ctx is simply never touched.
  test("session_info_changed patches the name without reopening the relay or touching a stale session ctx", async () => {
    const capturedOpts: Array<{ roomMeta?: { name?: string } }> = [];
    _defaultConnectImpl = async (opts?: unknown) => {
      capturedOpts.push(opts as { roomMeta?: { name?: string } });
    };
    const onSessionStart = captureEventHandler("session_start");
    const onSessionInfoChanged = captureEventHandler("session_info_changed");
    const cwd = "/tmp/remote-pi-session-rename";
    let sessionName = "before-019ffb64";
    _setPiForTest({
      getSessionName: () => sessionName,
      getThinkingLevel: () => "high",
    });
    await _connectForTest(makeMockCtx(cwd));
    const relay = relayRef.current!;
    relay.sendControl.mockClear();

    const liveCtx = makeMockCtx(cwd);
    let stale = false;
    const sessionCtx = {
      get ui() {
        if (stale) throw new Error("stale session ui");
        return liveCtx.ui;
      },
      get cwd() {
        if (stale) throw new Error("stale session cwd");
        return cwd;
      },
      get sessionManager() {
        if (stale) throw new Error("stale session manager");
        return undefined;
      },
    };
    onSessionStart({ type: "session_start", reason: "resume" }, sessionCtx);
    stale = true;

    sessionName = "after-019ffb64";
    onSessionInfoChanged({ type: "session_info_changed", name: sessionName });

    await vi.waitFor(() => {
      const patch = relay.sendControl.mock.calls
        .map((c) => c[0] as { type: string; meta?: { name?: string } })
        .find((f) => f?.type === "room_meta_update" && f.meta?.name === "after-019ffb64");
      expect(patch).toBeDefined();
    });
    expect(capturedOpts).toHaveLength(1);
    expect(relayInstances).toHaveLength(1);
    expect(_getState()).toBe("started");
  });

  test("pi.on('model_select') fires room_meta_update via relay.sendControl", async () => {
    captureHandler("remote-pi");
    await _connectForTest(makeMockCtx("/tmp/remote-pi-model-switch"));

    const onModelSelect = captureEventHandler("model_select");
    onModelSelect({
      type: "model_select",
      model: { id: "gpt-4o-2024-08-06", name: "gpt-4o" },
    });

    const sendControlCalls = relayRef.current!.sendControl.mock.calls.map((c) => c[0] as {
      type: string;
      room_id?: string;
      meta?: { model?: string };
    });
    const updates = sendControlCalls.filter((f) => f.type === "room_meta_update");
    expect(updates).toHaveLength(1);
    expect(updates[0]!.meta?.model).toBe("gpt-4o");
    expect(updates[0]!.room_id).toMatch(/^[A-Za-z0-9_-]{12}$/);
  });

  test("plan/32: pi.on('turn_start') publishes working=true via room_meta_update", async () => {
    captureHandler("remote-pi");
    await _connectForTest(makeMockCtx("/tmp/remote-pi-working-on"));

    const onTurnStart = captureEventHandler("turn_start");
    onTurnStart({ type: "turn_start", turnIndex: 0, timestamp: 0 });

    const updates = relayRef.current!.sendControl.mock.calls
      .map((c) => c[0] as { type: string; room_id?: string; meta?: { working?: boolean } })
      .filter((f) => f.type === "room_meta_update");
    expect(updates).toHaveLength(1);
    expect(updates[0]!.meta?.working).toBe(true);
    expect(updates[0]!.room_id).toMatch(/^[A-Za-z0-9_-]{12}$/);
  });

  test("plan/32: pi.on('turn_end') publishes working=false via room_meta_update", async () => {
    captureHandler("remote-pi");
    await _connectForTest(makeMockCtx("/tmp/remote-pi-working-off"));

    const onTurnEnd = captureEventHandler("turn_end");
    onTurnEnd({ type: "turn_end", turnIndex: 0 });

    const updates = relayRef.current!.sendControl.mock.calls
      .map((c) => c[0] as { type: string; meta?: { working?: boolean } })
      .filter((f) => f.type === "room_meta_update");
    expect(updates).toHaveLength(1);
    expect(updates[0]!.meta?.working).toBe(false);
  });

  test("plan/32: pi.on('session_before_compact') publishes working=true", async () => {
    captureHandler("remote-pi");
    await _connectForTest(makeMockCtx("/tmp/remote-pi-compact-working"));

    const onBefore = captureEventHandler("session_before_compact");
    onBefore({ type: "session_before_compact" });

    const updates = relayRef.current!.sendControl.mock.calls
      .map((c) => c[0] as { type: string; meta?: { working?: boolean } })
      .filter((f) => f.type === "room_meta_update");
    expect(updates).toHaveLength(1);
    expect(updates[0]!.meta?.working).toBe(true);
  });

  test("model_select with no model.name falls back to model.id", async () => {
    captureHandler("remote-pi");
    await _connectForTest(makeMockCtx("/tmp/remote-pi-model-fallback"));

    const onModelSelect = captureEventHandler("model_select");
    onModelSelect({
      type: "model_select",
      model: { id: "internal-fallback-id" },  // no name
    });

    const updates = relayRef.current!.sendControl.mock.calls
      .map((c) => c[0] as { type: string; meta?: { model?: string } })
      .filter((f) => f.type === "room_meta_update");
    expect(updates).toHaveLength(1);
    expect(updates[0]!.meta?.model).toBe("internal-fallback-id");
  });

  test("model_select with no model (undefined) is silently ignored", async () => {
    captureHandler("remote-pi");
    await _connectForTest(makeMockCtx("/tmp/remote-pi-model-noop"));

    const sendControlBefore = relayRef.current!.sendControl.mock.calls.length;
    const onModelSelect = captureEventHandler("model_select");
    onModelSelect({ type: "model_select" });  // event arrived but model field missing

    expect(relayRef.current!.sendControl.mock.calls.length).toBe(sendControlBefore);
  });

  test("reconnect replays the same room_id + room_meta from _cmdStart (no phantom 'legacy session')", async () => {
    vi.useFakeTimers();
    try {
      const capturedOpts: Array<{ roomId?: string; roomMeta?: { name?: string; cwd?: string; model?: string } }> = [];
      _defaultConnectImpl = async (opts?: unknown) => {
        capturedOpts.push(opts as typeof capturedOpts[number]);
      };

      captureHandler("remote-pi");
      const ctx = {
        ui: { notify: vi.fn() },
        cwd: "/tmp/remote-pi-reconnect-room",
        abort: vi.fn(),
        model: { id: "claude-sonnet-4-5", name: "claude-sonnet-4.5" },
      } as unknown as ReturnType<typeof makeMockCtx>;
      await _connectForTest(ctx);

      expect(capturedOpts).toHaveLength(1);
      const initialRoomId = capturedOpts[0]!.roomId!;
      expect(capturedOpts[0]!.roomMeta?.model).toBe("claude-sonnet-4.5");

      // Drop relay → reconnect path fires
      relayInstances[0]!.emit("close");
      await vi.advanceTimersByTimeAsync(1_000);

      // Second connect call must carry the same roomId + roomMeta (CRITICAL:
      // without this fix the reconnect issued a bare hello and the relay
      // bucketed it as a default-room peer.)
      expect(capturedOpts).toHaveLength(2);
      expect(capturedOpts[1]!.roomId).toBe(initialRoomId);
      expect(capturedOpts[1]!.roomMeta?.cwd).toBe("/tmp/remote-pi-reconnect-room");
      expect(capturedOpts[1]!.roomMeta?.model).toBe("claude-sonnet-4.5");
    } finally {
      vi.useRealTimers();
    }
  });

  test("reconnect after model_select carries the updated model in room_meta", async () => {
    vi.useFakeTimers();
    try {
      const capturedOpts: Array<{ roomMeta?: { model?: string } }> = [];
      _defaultConnectImpl = async (opts?: unknown) => {
        capturedOpts.push(opts as { roomMeta?: { model?: string } });
      };

      captureHandler("remote-pi");
      const ctx = {
        ui: { notify: vi.fn() },
        cwd: "/tmp/remote-pi-reconnect-model",
        abort: vi.fn(),
        model: { id: "claude-sonnet-4-5", name: "claude-sonnet-4.5" },
      } as unknown as ReturnType<typeof makeMockCtx>;
      await _connectForTest(ctx);

      // User switches model
      const onModelSelect = captureEventHandler("model_select");
      onModelSelect({
        type: "model_select",
        model: { id: "gpt-4o-2024-08-06", name: "gpt-4o" },
      });

      // Relay drops → reconnect uses the NEW model in its hello
      relayInstances[0]!.emit("close");
      await vi.advanceTimersByTimeAsync(1_000);

      expect(capturedOpts).toHaveLength(2);
      expect(capturedOpts[0]!.roomMeta?.model).toBe("claude-sonnet-4.5");  // initial
      expect(capturedOpts[1]!.roomMeta?.model).toBe("gpt-4o");             // post-switch
    } finally {
      vi.useRealTimers();
    }
  });
});

// ── plan 61 Phase 1 — stable session identity ────────────────────────────────
//
// `room_id` used to be `sha256(cwd[,name])`, so the transport key was a
// function of an editable label. Phase 1 makes it the Pi session UUID: renames
// become metadata and two sessions in one folder are distinct for free.
describe("plan 61 Phase 1 — room_id is the Pi session id", () => {
  const sessionId = "019ffb64-7c21-7a3f-9d2e-4b1c8a0f6e5d";

  beforeEach(async () => {
    vi.clearAllMocks();
    _knownPeers.length = 0;
    relayRef.current = null;
    relayInstances.length = 0;
    _defaultConnectImpl = async () => undefined;
    _setDisposedForTest(false);
    _resetPiSessionIdForTest();
    const stop = captureHandler("remote-pi stop");
    await stop("", makeMockCtx());
  });

  afterEach(async () => {
    // The latch is module state; leaking it would silently re-key the relay
    // room of every later test that expects the legacy cwd-derived id.
    _resetPiSessionIdForTest();
    const stop = captureHandler("remote-pi stop");
    await stop("", makeMockCtx());
  });

  function sessionCtx(cwd: string, id: string | undefined) {
    return {
      ...makeMockCtx(cwd),
      sessionManager: { getSessionId: () => id },
    };
  }

  /** Minimal ExtensionAPI stub with a mutable session name (local copy — the
   *  one in the relay-control describe is scoped to that block). */
  function stubPi() {
    let sessionName = "pi-extension";
    return {
      on: () => undefined, registerCommand: () => undefined,
      registerTool: () => undefined, registerShortcut: () => undefined,
      registerFlag: () => undefined, getFlag: () => undefined,
      registerMessageRenderer: () => undefined,
      getSessionName: () => sessionName,
      setSessionName: (name: string) => { sessionName = name; },
      sendMessage: vi.fn(), sendUserMessage: () => undefined,
    } as unknown as ExtensionAPI;
  }

  test("hello registers under the session id and publishes the session identity", async () => {
    const capturedOpts: Array<{ roomId?: string; roomMeta?: Record<string, unknown> }> = [];
    _defaultConnectImpl = async (opts?: unknown) => {
      capturedOpts.push(opts as { roomId?: string; roomMeta?: Record<string, unknown> });
    };
    const cwd = mkdtempSync(join(tmpdir(), "remote-pi-p61-"));
    const onSessionStart = captureEventHandler("session_start");
    captureHandler("remote-pi");
    _setPiForTest(stubPi());

    onSessionStart({ type: "session_start", reason: "startup" }, sessionCtx(cwd, sessionId));
    expect(_getPiSessionIdForTest()).toBe(sessionId);

    await _connectForTest(makeMockCtx(cwd));

    expect(capturedOpts).toHaveLength(1);
    expect(capturedOpts[0]!.roomId).toBe(sessionId);
    expect(capturedOpts[0]!.roomMeta).toMatchObject({
      session_id: sessionId,
      // realpath — macOS /tmp is a symlink to /private/tmp, and Phase 2 groups
      // by this value, so both spellings must collapse to one workspace.
      workspace_path: realpathSync(cwd),
    });
    expect(typeof capturedOpts[0]!.roomMeta!["name_rev"]).toBe("number");
    expect(_getRoomIdForTest()).toBe(sessionId);
  });

  test("with no resolvable session id it falls back to the legacy cwd room and does NOT claim a session_id", async () => {
    const capturedOpts: Array<{ roomId?: string; roomMeta?: Record<string, unknown> }> = [];
    _defaultConnectImpl = async (opts?: unknown) => {
      capturedOpts.push(opts as { roomId?: string; roomMeta?: Record<string, unknown> });
    };
    const cwd = mkdtempSync(join(tmpdir(), "remote-pi-p61-legacy-"));
    const onSessionStart = captureEventHandler("session_start");
    captureHandler("remote-pi");
    _setPiForTest(stubPi());
    // Models an SDK that exposes no session id at all. Firing session_start
    // explicitly also re-binds `_lastEventCtx`, which the resolver consults as
    // a fallback — otherwise a ctx left behind by an earlier test would still
    // hand us an id.
    onSessionStart({ type: "session_start", reason: "startup" }, sessionCtx(cwd, undefined));
    expect(_getPiSessionIdForTest()).toBeNull();

    await _connectForTest(makeMockCtx(cwd));

    // Exactly the legacy derivation, name axis included — `stubPi` reports
    // "pi-extension", which is not this tmpdir's default agent name, so the
    // fallback must be the NAME-scoped id, not the bare cwd one.
    expect(capturedOpts[0]!.roomId).toBe(roomIdFor(cwd, "pi-extension"));
    expect(capturedOpts[0]!.roomId).not.toBe(roomIdForCwd(cwd));
    expect(capturedOpts[0]!.roomMeta).not.toHaveProperty("session_id");
    // The workspace key is still published — Phase 2 grouping must work for a
    // legacy room too.
    expect(capturedOpts[0]!.roomMeta!["workspace_path"]).toBe(realpathSync(cwd));
  });

  test("INVARIANT: a rename leaves room_id untouched (no room_ended / new tile)", async () => {
    const cwd = mkdtempSync(join(tmpdir(), "remote-pi-p61-rename-"));
    const onSessionStart = captureEventHandler("session_start");
    captureHandler("remote-pi");
    _setPiForTest(stubPi());
    onSessionStart({ type: "session_start", reason: "startup" }, sessionCtx(cwd, sessionId));
    await _connectForTest(makeMockCtx(cwd));

    const before = _getRoomIdForTest();
    const relay = relayRef.current!;
    await _handleControl("rename:Something Else");

    expect(_getRoomIdForTest()).toBe(before);
    expect(_getRoomIdForTest()).toBe(sessionId);
    expect(relay.close).not.toHaveBeenCalled();
    expect(relayInstances).toHaveLength(1);
  });

  test("a session replacement re-keys the room to the NEW session id", async () => {
    const capturedOpts: Array<{ roomId?: string }> = [];
    _defaultConnectImpl = async (opts?: unknown) => {
      capturedOpts.push(opts as { roomId?: string });
    };
    const cwd = mkdtempSync(join(tmpdir(), "remote-pi-p61-replace-"));
    const onSessionStart = captureEventHandler("session_start");
    captureHandler("remote-pi");
    _setPiForTest(stubPi());

    onSessionStart({ type: "session_start", reason: "startup" }, sessionCtx(cwd, sessionId));
    await _connectForTest(makeMockCtx(cwd));
    expect(capturedOpts[0]!.roomId).toBe(sessionId);

    // `/new` → a genuinely different session deserves a different room.
    const second = "019ffb64-9999-7a3f-9d2e-4b1c8a0f6e5d";
    const stop = captureHandler("remote-pi stop");
    await stop("", makeMockCtx(cwd));
    onSessionStart({ type: "session_start", reason: "new" }, sessionCtx(cwd, second));
    await _connectForTest(makeMockCtx(cwd));

    expect(capturedOpts[1]!.roomId).toBe(second);
  });
});

// ── plan 61 Phase 2 — app-driven rename over the wire ───────────────────────
//
// The Home long-press rename was app-LOCAL: it wrote into the phone's own
// cache, so a second device of the same Owner kept the old label and the Pi
// never learned the new one. `session_rename` makes it authoritative.
describe("plan 61 Phase 2 — session_rename", () => {
  const sessionId = "019ffb64-7c21-7a3f-9d2e-4b1c8a0f6e5d";

  beforeEach(async () => {
    vi.clearAllMocks();
    _knownPeers.length = 0;
    relayRef.current = null;
    relayInstances.length = 0;
    _defaultConnectImpl = async () => undefined;
    _setDisposedForTest(false);
    _resetPiSessionIdForTest();
    const stop = captureHandler("remote-pi stop");
    await stop("", makeMockCtx());
  });

  afterEach(async () => {
    _resetPiSessionIdForTest();
    const stop = captureHandler("remote-pi stop");
    await stop("", makeMockCtx());
  });

  function renamePatches() {
    return relayRef.current!.sendControl.mock.calls
      .map((c) => c[0] as { type: string; meta?: { name?: string; name_rev?: number } })
      .filter((f) => f?.type === "room_meta_update" && f.meta?.name !== undefined);
  }

  function actionReplies(sendsBefore: number) {
    return relayRef.current!.send.mock.calls
      .slice(sendsBefore)
      .map((c) => decodeSentCt(c[0] as string).inner)
      .filter((i) => i.type === "action_ok" || i.type === "action_error");
  }

  test("applies the new name, patches room_meta, and acks", async () => {
    await _pairForTest("peer-rename-1");
    const before = relayRef.current!.send.mock.calls.length;
    relayRef.current!.sendControl.mockClear();

    routeClientMessage(
      { type: "session_rename", id: "rpc-1", display_name: "  Refactor auth  " },
      { abort: () => undefined },
    );
    await vi.waitFor(() => expect(actionReplies(before)).toHaveLength(1));

    expect(actionReplies(before)[0]).toMatchObject({
      type: "action_ok",
      in_reply_to: "rpc-1",
      action: "session_rename",
    });
    const patches = renamePatches();
    expect(patches).toHaveLength(1);
    // Whitespace is trimmed — the label is what the user sees.
    expect(patches[0]!.meta!.name).toBe("Refactor auth");
    expect(typeof patches[0]!.meta!.name_rev).toBe("number");
    // The room id is untouched: that is the Phase 1 invariant this builds on.
    expect(relayInstances).toHaveLength(1);
    expect(relayRef.current!.close).not.toHaveBeenCalled();
  });

  test("an empty / whitespace-only name is refused", async () => {
    await _pairForTest("peer-rename-2");
    const before = relayRef.current!.send.mock.calls.length;
    relayRef.current!.sendControl.mockClear();

    routeClientMessage(
      { type: "session_rename", id: "rpc-2", display_name: "   " },
      { abort: () => undefined },
    );
    await vi.waitFor(() => expect(actionReplies(before)).toHaveLength(1));

    expect(actionReplies(before)[0]).toMatchObject({
      type: "action_error",
      in_reply_to: "rpc-2",
      action: "session_rename",
    });
    expect(renamePatches()).toHaveLength(0);
  });

  test("a frame addressed to a DIFFERENT session is refused, not misapplied", async () => {
    // Models the race: the app sends a rename while the Pi replaces its
    // session. Applying it would relabel a session the user never touched.
    const onSessionStart = captureEventHandler("session_start");
    onSessionStart(
      { type: "session_start", reason: "startup" },
      { ...makeMockCtx(), sessionManager: { getSessionId: () => sessionId } },
    );
    await _pairForTest("peer-rename-3");
    const before = relayRef.current!.send.mock.calls.length;
    relayRef.current!.sendControl.mockClear();

    routeClientMessage(
      {
        type: "session_rename",
        id: "rpc-3",
        display_name: "Wrong target",
        session_id: "019ffb64-dead-7a3f-9d2e-4b1c8a0f6e5d",
      },
      { abort: () => undefined },
    );
    await vi.waitFor(() => expect(actionReplies(before)).toHaveLength(1));

    expect(actionReplies(before)[0]!.type).toBe("action_error");
    expect(renamePatches()).toHaveLength(0);
  });

  test("a stale rev loses the two-device race instead of clobbering", async () => {
    await _pairForTest("peer-rename-4");
    relayRef.current!.sendControl.mockClear();

    // Device A renames → the Pi mints a fresh (large, clock-seeded) revision.
    routeClientMessage(
      { type: "session_rename", id: "rpc-4a", display_name: "From A" },
      { abort: () => undefined },
    );
    await vi.waitFor(() => expect(renamePatches()).toHaveLength(1));
    const mintedRev = renamePatches()[0]!.meta!.name_rev!;

    // Device B was still showing the pre-rename label and sends its own with
    // the older revision it last saw.
    const before = relayRef.current!.send.mock.calls.length;
    routeClientMessage(
      {
        type: "session_rename",
        id: "rpc-4b",
        display_name: "From B",
        rev: mintedRev - 1,
      },
      { abort: () => undefined },
    );
    await vi.waitFor(() => expect(actionReplies(before)).toHaveLength(1));

    expect(actionReplies(before)[0]!.type).toBe("action_error");
    expect(renamePatches()).toHaveLength(1);
    expect(renamePatches()[0]!.meta!.name).toBe("From A");
  });

  test("a rev equal to the current one still wins (only OLDER is stale)", async () => {
    await _pairForTest("peer-rename-5");
    relayRef.current!.sendControl.mockClear();

    routeClientMessage(
      { type: "session_rename", id: "rpc-5a", display_name: "First" },
      { abort: () => undefined },
    );
    await vi.waitFor(() => expect(renamePatches()).toHaveLength(1));
    const rev = renamePatches()[0]!.meta!.name_rev!;

    routeClientMessage(
      { type: "session_rename", id: "rpc-5b", display_name: "Second", rev },
      { abort: () => undefined },
    );
    await vi.waitFor(() => expect(renamePatches()).toHaveLength(2));
    expect(renamePatches()[1]!.meta!.name).toBe("Second");
    expect(renamePatches()[1]!.meta!.name_rev!).toBeGreaterThan(rev);
  });
});
