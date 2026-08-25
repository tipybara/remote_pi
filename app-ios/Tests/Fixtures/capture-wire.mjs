#!/usr/bin/env node
/**
 * capture-wire.mjs — record the ACTUAL bytes on the App ↔ relay ↔ Pi wire.
 *
 * Everything under `wire/` is produced by this script. Nothing in it is
 * hand-written: each fixture is the exact UTF-8 text of one WebSocket frame as
 * it crossed a transparent logging proxy sitting between the peers and a REAL
 * `relay` process.
 *
 * ## What is real, and what is only stimulus
 *
 * | Source | What it produces |
 * |---|---|
 * | `relay/` (a live `cargo run` on :3777) | `challenge`, the REWRITTEN outer envelope, `room_announced`, `room_ended`, `rooms`, `room_meta_updated`, `presence`, `peer_online`, `peer_offline`, `transport_error` |
 * | `pi-extension/src/daemon/gateway.ts` (the real Gateway, via `capture-gateway.mts`) | the `ctrl` room's `hello`, and every control-plane `action_ok` / `action_error` |
 * | `scripts/fake-pi.mjs` (unmodified) | a Pi's chat-room `hello` with the full plan-61 `room_meta`, `room_meta_update`, `pair_ok`, the chat stream, `action_ok`/`action_error` for `session_rename` |
 * | this script's own clients | the APP side (`hello`, `auth`, subscriptions, envelopes) and a synthetic Pi used only to *stimulate* the relay's merge-patch gate |
 *
 * The synthetic Pi matters for one thing the other two cannot do: send a
 * DELIBERATELY STALE `name_rev`, and send an explicit `null`. What gets pinned
 * from those exchanges is the relay's reply, not the stimulus.
 *
 * ## Reproduce
 *
 *   cd /Users/yang/workspace/remote_pi/relay && cargo run          # :3777
 *   cd /Users/yang/workspace/remote_pi
 *   node app-ios/Tests/Fixtures/capture-wire.mjs
 *
 * Options
 *   --relay <ws url>   upstream relay. Default ws://127.0.0.1:3777
 *   --port <n>         port the logging proxy listens on. Default 3877
 *   --out <dir>        fixture directory. Default <this dir>/wire
 *   --keep             leave the throwaway HOME behind for inspection
 *
 * It never touches `~/.pi/remote` or `~/.remote-pi-fake`: every child runs with
 * `HOME` pointed at a fresh temp directory.
 */

import { spawn } from "node:child_process";
import {
  createPrivateKey,
  generateKeyPairSync,
  randomUUID,
  sign as edSign,
} from "node:crypto";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, "..", "..", "..");
const PI_EXT = join(REPO, "pi-extension");

// `ws` is only needed for the proxy's SERVER half — node's global WebSocket is
// client-only. Borrowed from pi-extension's install rather than adding a
// dependency anywhere.
const wsModule = await import(pathToFileURL(join(PI_EXT, "node_modules", "ws", "index.js")).href);
const WebSocketImpl = wsModule.default;
const WebSocketServer = WebSocketImpl.Server;

// ── CLI ──────────────────────────────────────────────────────────────────────

const opts = {
  relay: "ws://127.0.0.1:3777",
  port: 3877,
  out: join(HERE, "wire"),
  keep: false,
};
for (let i = 2; i < process.argv.length; i++) {
  const a = process.argv[i];
  if (a === "--relay") opts.relay = process.argv[++i];
  else if (a === "--port") opts.port = Number(process.argv[++i]);
  else if (a === "--out") opts.out = process.argv[++i];
  else if (a === "--keep") opts.keep = true;
  else throw new Error(`unknown option: ${a}`);
}

const CAPTURED_AT = new Date().toISOString();
const PROXY_URL = `ws://127.0.0.1:${opts.port}`;

// ── Encoding ─────────────────────────────────────────────────────────────────

const b64 = (buf) => Buffer.from(buf).toString("base64");
const encodeInner = (obj) => Buffer.from(JSON.stringify(obj)).toString("base64");
const decodeInner = (ct) => JSON.parse(Buffer.from(ct, "base64").toString("utf8"));

function newIdentity() {
  const { privateKey } = generateKeyPairSync("ed25519");
  const jwk = privateKey.export({ format: "jwk" });
  const publicKey = Buffer.from(jwk.x, "base64url");
  return {
    jwk: { kty: "OKP", crv: "Ed25519", x: jwk.x, d: jwk.d },
    privateKey,
    publicKey,
    pubkeyStandard: b64(publicKey),
  };
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ── Transcript ───────────────────────────────────────────────────────────────

class Recorder {
  constructor() {
    this.frames = [];
    this.t0 = Date.now();
    /** standard-base64 pubkey → friendly label. */
    this.names = new Map();
  }

  label(pubkey, name) {
    this.names.set(pubkey, name);
  }

  /** Names a proxied connection the moment its `hello` goes by. */
  identify(text) {
    try {
      const frame = JSON.parse(text);
      if (frame?.type !== "hello") return null;
      const who = this.names.get(frame.pubkey) ?? `unknown(${String(frame.pubkey).slice(-8)})`;
      return `${who}/${frame.room_id ?? "main"}`;
    } catch {
      return null;
    }
  }

  push(entry) {
    this.frames.push({ seq: this.frames.length, ms: Date.now() - this.t0, ...entry });
  }

  /** Frames matching `pred`, oldest first. */
  find(pred) {
    return this.frames.filter(pred);
  }

  /** The first match, or throws — a missing frame is a broken capture, not an
   *  empty fixture. */
  one(name, pred) {
    const hit = this.frames.find(pred);
    if (!hit) throw new Error(`capture is missing a frame for fixture "${name}"`);
    return hit;
  }
}

const rec = new Recorder();

/** Predicate helpers over recorded frames. */
const isJSON = (f) => {
  try {
    f._json ??= JSON.parse(f.text);
    return true;
  } catch {
    return false;
  }
};
const typed = (type, extra = () => true) => (f) =>
  isJSON(f) && f._json.type === type && extra(f._json, f);
const envelope = (extra = () => true) => (f) => {
  if (!isJSON(f)) return false;
  const j = f._json;
  if (typeof j.peer !== "string" || typeof j.ct !== "string" || j.type !== undefined) return false;
  let inner;
  try {
    inner = decodeInner(j.ct);
  } catch {
    return false;
  }
  f._inner = inner;
  return extra(inner, j, f);
};
const innerType = (type, extra = () => true) =>
  envelope((inner, outer, f) => inner?.type === type && extra(inner, outer, f));

// ── Logging proxy ────────────────────────────────────────────────────────────

function startProxy() {
  const server = new WebSocketServer({ host: "127.0.0.1", port: opts.port });
  let n = 0;
  server.on("connection", (down) => {
    const conn = `c${++n}`;
    let label = conn;
    const up = new WebSocketImpl(opts.relay);
    const pending = [];

    up.on("open", () => {
      // Buffers MUST be re-sent with the original text/binary flag: `ws`
      // defaults a Buffer to a binary frame, and the relay drops
      // `Message::Binary` without a word — which looks exactly like a hung
      // handshake.
      for (const [data, isBinary] of pending) up.send(data, { binary: isBinary });
      pending.length = 0;
    });
    down.on("message", (data, isBinary) => {
      if (!isBinary) {
        const text = data.toString();
        label = rec.identify(text) ?? label;
        rec.push({ conn, label, dir: "c2s", text });
      }
      if (up.readyState === 1) up.send(data, { binary: isBinary });
      else pending.push([data, isBinary]);
    });
    up.on("message", (data, isBinary) => {
      if (!isBinary) rec.push({ conn, label, dir: "s2c", text: data.toString() });
      if (down.readyState === 1) down.send(data, { binary: isBinary });
    });

    const bye = () => {
      try { up.close(); } catch { /* already gone */ }
      try { down.close(); } catch { /* already gone */ }
    };
    down.on("close", bye);
    up.on("close", bye);
    down.on("error", bye);
    up.on("error", bye);
  });
  return new Promise((res) => server.on("listening", () => res(server)));
}

// ── A relay peer (used for the app and for the synthetic Pi) ─────────────────

class RelayPeer {
  constructor({ identity, roomID, roomMeta, name }) {
    this.identity = identity;
    this.roomID = roomID;
    this.roomMeta = roomMeta;
    this.name = name;
    this.control = [];
    this.inner = [];
    this.waiters = [];
  }

  get peerID() {
    return this.identity.pubkeyStandard;
  }

  connect() {
    return new Promise((res, rej) => {
      const ws = new WebSocketImpl(PROXY_URL);
      this.ws = ws;
      let authed = false;
      const timer = setTimeout(() => rej(new Error(`${this.name}: auth timed out`)), 10_000);

      ws.on("open", () => {
        const hello = { type: "hello", pubkey: this.peerID, room_id: this.roomID };
        // A phone publishes no room_meta; a Pi publishes the full plan-61 set.
        if (this.roomMeta) hello.room_meta = this.roomMeta;
        ws.send(JSON.stringify(hello));
      });

      ws.on("message", (data) => {
        const text = data.toString();
        if (!authed) {
          const frame = JSON.parse(text);
          if (frame.type !== "challenge") return rej(new Error(`expected challenge, got ${text}`));
          // Signed over the RAW nonce bytes, never over the base64 text
          // (`relay/src/auth/challenge.rs::verify_auth`).
          const sig = edSign(null, Buffer.from(frame.nonce, "base64"), this.identity.privateKey);
          ws.send(JSON.stringify({ type: "auth", sig: b64(sig) }));
          authed = true;
          clearTimeout(timer);
          // The relay acknowledges nothing; it just starts routing.
          setTimeout(() => res(this), 150);
          return;
        }
        this.#dispatch(text);
      });

      ws.on("error", (e) => rej(e));
    });
  }

  #dispatch(text) {
    let frame;
    try { frame = JSON.parse(text); } catch { return; }
    if (typeof frame.type === "string") {
      this.control.push(frame);
      this.#wake();
      return;
    }
    if (typeof frame.peer !== "string" || typeof frame.ct !== "string") return;
    let inner;
    try { inner = decodeInner(frame.ct); } catch { return; }
    this.inner.push({ outer: frame, inner });
    this.#wake();
  }

  #wake() {
    for (const w of [...this.waiters]) {
      if (w.check()) this.waiters.splice(this.waiters.indexOf(w), 1);
    }
  }

  send(frame) {
    this.ws.send(JSON.stringify(frame));
  }

  sendEnvelope(peer, room, inner) {
    this.ws.send(JSON.stringify({ peer, room, ct: encodeInner(inner) }));
  }

  #wait(list, pred, what, ms) {
    return new Promise((res, rej) => {
      const check = () => {
        const hit = list.find(pred);
        if (hit) { clearTimeout(timer); res(hit); return true; }
        return false;
      };
      const timer = setTimeout(() => rej(new Error(`${this.name}: timed out waiting for ${what}`)), ms);
      const waiter = { check };
      if (check()) return;
      this.waiters.push(waiter);
    });
  }

  waitControl(pred, what, ms = 10_000) {
    return this.#wait(this.control, pred, what, ms);
  }

  waitInner(pred, what, ms = 15_000) {
    return this.#wait(this.inner, ({ inner }) => pred(inner), what, ms);
  }

  close() {
    try { this.ws.close(); } catch { /* already gone */ }
  }
}

// ── Children ─────────────────────────────────────────────────────────────────

function spawnLogged(name, cmd, args, env, cwd) {
  const child = spawn(cmd, args, {
    cwd,
    env: { ...process.env, ...env },
    stdio: ["pipe", "pipe", "pipe"],
  });
  child.stdout.setEncoding("utf8");
  child.stderr.setEncoding("utf8");
  child._lines = [];
  child._waiters = [];
  const feed = (chunk) => {
    for (const line of chunk.split("\n")) {
      if (!line.trim()) continue;
      child._lines.push(line);
      for (const w of [...child._waiters]) {
        if (w.pred(line)) {
          child._waiters.splice(child._waiters.indexOf(w), 1);
          w.res(line);
        }
      }
    }
  };
  child.stdout.on("data", feed);
  child.stderr.on("data", (c) => process.stderr.write(`[${name}] ${c}`));
  child.waitLine = (pred, what, ms = 20_000) =>
    new Promise((res, rej) => {
      const hit = child._lines.find(pred);
      if (hit) return res(hit);
      const timer = setTimeout(() => rej(new Error(`${name}: timed out waiting for ${what}`)), ms);
      child._waiters.push({ pred, res: (l) => { clearTimeout(timer); res(l); } });
    });
  return child;
}

// ── Fixture writing ──────────────────────────────────────────────────────────

const fixtures = [];

/**
 * One fixture file. `raw` is the exact frame text; the tests parse THAT.
 * `frame` is the same bytes parsed, for human review only — nothing reads it.
 */
function fixture(name, frame, note) {
  const body = {
    _fixture: name,
    _captured_at: CAPTURED_AT,
    _produced_by: "app-ios/Tests/Fixtures/capture-wire.mjs against a live relay on :3777",
    _note: note,
    direction: `${frame.label} ${frame.dir === "c2s" ? "→ relay" : "← relay"}`,
    raw: frame.text,
    frame: JSON.parse(frame.text),
  };
  if (body.frame.ct !== undefined) {
    body.inner_raw = Buffer.from(body.frame.ct, "base64").toString("utf8");
    body.inner = JSON.parse(body.inner_raw);
  }
  writeFileSync(join(opts.out, `${name}.json`), JSON.stringify(body, null, 2) + "\n");
  fixtures.push({ name, note, direction: body.direction });
}

// ── Main ─────────────────────────────────────────────────────────────────────

const home = mkdtempSync(join(tmpdir(), "remotepi-capture-"));
const children = [];

async function main() {
  mkdirSync(opts.out, { recursive: true });

  const app = newIdentity();
  const fakePi = newIdentity();
  const gatewayKey = newIdentity();
  const patchPi = newIdentity();

  rec.label(app.pubkeyStandard, "app");
  rec.label(fakePi.pubkeyStandard, "fake-pi");
  rec.label(gatewayKey.pubkeyStandard, "gateway");
  rec.label(patchPi.pubkeyStandard, "patch-pi");

  // Throwaway machine home for the real gateway.
  const gwHome = join(home, "gateway");
  mkdirSync(join(gwHome, ".pi", "remote"), { recursive: true });
  writeFileSync(
    join(gwHome, ".pi", "remote", "identity.json"),
    JSON.stringify({
      pk: gatewayKey.pubkeyStandard,
      sk: Buffer.from(gatewayKey.jwk.d, "base64url").toString("base64"),
    }),
  );
  // The gateway is Owner-only: the app has to be in peers.json or every frame
  // is dropped before it reaches the action decoder.
  writeFileSync(
    join(gwHome, ".pi", "remote", "peers.json"),
    JSON.stringify({
      peers: [{ remote_epk: app.pubkeyStandard, name: "capture-app", paired_at: CAPTURED_AT }],
    }),
  );

  const server = await startProxy();
  console.log(`proxy    ${PROXY_URL} → ${opts.relay}`);
  console.log(`home     ${home}`);

  // ── The app, first, so it is subscribed before anything registers ─────────
  const appPeer = new RelayPeer({ identity: app, roomID: "main", name: "app" });
  await appPeer.connect();
  console.log("app      authenticated");

  const watched = [fakePi.pubkeyStandard, gatewayKey.pubkeyStandard, patchPi.pubkeyStandard];
  appPeer.send({ type: "subscribe_presence", peers: watched });
  appPeer.send({ type: "subscribe_rooms", peers: watched });
  appPeer.send({ type: "presence_check", peers: watched });
  appPeer.send({ type: "rooms_check", peers: [fakePi.pubkeyStandard] });
  await appPeer.waitControl((f) => f.type === "presence", "presence snapshot");
  await appPeer.waitControl((f) => f.type === "rooms", "empty rooms snapshot");

  // ── fake-pi: three sessions across two workspaces, plus its ctrl room ─────
  const piHome = join(home, "fake-pi");
  mkdirSync(piHome, { recursive: true });
  writeFileSync(join(piHome, "identity.json"), JSON.stringify(fakePi.jwk, null, 2));
  const wsA = join(home, "proj", "api");
  const wsB = join(home, "proj", "web");
  mkdirSync(wsA, { recursive: true });
  mkdirSync(wsB, { recursive: true });

  const pi = spawnLogged(
    "fake-pi",
    process.execPath,
    [
      join(REPO, "scripts", "fake-pi.mjs"),
      "--relay", PROXY_URL,
      "--session", `${wsA}:api-server`,
      "--session", `${wsA}:api-worker`,
      "--session", `${wsB}:web`,
      "--identity", join(piHome, "identity.json"),
      "--state", join(piHome, "sessions.json"),
      "--hostname", "capture-machine",
    ],
    { HOME: piHome },
    REPO,
  );
  children.push(pi);
  const qrLine = await pi.waitLine((l) => l.startsWith("remotepi://pair?"), "the QR payload");
  console.log("fake-pi  up");

  // ── The real pi-extension gateway ────────────────────────────────────────
  const gw = spawnLogged(
    "gateway",
    join(PI_EXT, "node_modules", ".bin", "tsx"),
    [join(HERE, "capture-gateway.mts")],
    {
      HOME: gwHome,
      REMOTE_PI_HOME: gwHome,
      REMOTE_PI_RELAY: `http://127.0.0.1:${opts.port}`,
      CAPTURE_WORKSPACE: join(gwHome, "workspace"),
      CAPTURE_PI_EXT: PI_EXT,
    },
    PI_EXT,
  );
  children.push(gw);
  const readyLine = await gw.waitLine((l) => l.startsWith("GATEWAY_READY"), "GATEWAY_READY", 60_000);
  const gwInfo = JSON.parse(readyLine.slice("GATEWAY_READY ".length));
  console.log("gateway  up");

  // Give the relay time to fan out every room_announced.
  await appPeer.waitControl(
    (f) => f.type === "room_announced" && f.peer === gatewayKey.pubkeyStandard,
    "the gateway's room_announced",
  );
  await sleep(300);

  // A populated snapshot for both peers.
  appPeer.send({ type: "rooms_check", peers: [fakePi.pubkeyStandard, gatewayKey.pubkeyStandard] });
  await appPeer.waitControl(
    (f) => f.type === "rooms" && f.peer === fakePi.pubkeyStandard && f.rooms.length > 0,
    "a populated rooms snapshot",
  );

  // ── Pairing ───────────────────────────────────────────────────────────────
  const qr = new URL(qrLine);
  const token = qr.searchParams.get("t");
  const pairRoom = qr.searchParams.get("rm");
  const qrEPK = qr.searchParams.get("epk"); // url-safe, unpadded — the trap
  const pairID = randomUUID();
  appPeer.sendEnvelope(fakePi.pubkeyStandard, pairRoom, {
    type: "pair_request",
    id: pairID,
    token,
    device_name: "Capture iPhone",
  });
  await appPeer.waitInner((i) => i.type === "pair_ok" && i.in_reply_to === pairID, "pair_ok");
  console.log("app      paired");

  // A second pair_request with the now-consumed token → pair_error.
  const staleePairID = randomUUID();
  appPeer.sendEnvelope(fakePi.pubkeyStandard, pairRoom, {
    type: "pair_request",
    id: staleePairID,
    token,
    device_name: "Capture iPhone",
  });
  await appPeer.waitInner((i) => i.type === "pair_error", "pair_error");

  // ── Chat turn ─────────────────────────────────────────────────────────────
  const turnID = randomUUID();
  appPeer.sendEnvelope(fakePi.pubkeyStandard, pairRoom, {
    type: "user_message",
    id: turnID,
    text: "wire conformance capture — hello from the app",
  });
  await appPeer.waitInner((i) => i.type === "agent_done" && i.in_reply_to === turnID, "agent_done");

  // ── Chat-room actions against fake-pi ────────────────────────────────────
  const listID = randomUUID();
  appPeer.sendEnvelope(fakePi.pubkeyStandard, pairRoom, { type: "list_models", id: listID });
  await appPeer.waitInner((i) => i.type === "models_list", "models_list");

  const syncID = randomUUID();
  appPeer.sendEnvelope(fakePi.pubkeyStandard, pairRoom, { type: "session_sync", id: syncID, limit: 20 });
  await appPeer.waitInner((i) => i.type === "session_history", "session_history");

  const pingID = randomUUID();
  appPeer.sendEnvelope(fakePi.pubkeyStandard, pairRoom, { type: "ping", id: pingID });
  await appPeer.waitInner((i) => i.type === "pong", "pong");

  // The room's current name_rev, read off the last room_announced.
  const announced = appPeer.control
    .filter((f) => f.type === "room_announced" && f.room_id === pairRoom)
    .at(-1);
  const currentRev = announced.name_rev;

  const renameID = randomUUID();
  appPeer.sendEnvelope(fakePi.pubkeyStandard, pairRoom, {
    type: "session_rename",
    id: renameID,
    session_id: announced.session_id,
    display_name: "renamed by capture",
    rev: currentRev,
  });
  await appPeer.waitInner(
    (i) => i.type === "action_ok" && i.in_reply_to === renameID,
    "action_ok for session_rename",
  );
  await appPeer.waitControl(
    (f) => f.type === "room_meta_updated" && f.room_id === pairRoom && f.meta?.name === "renamed by capture",
    "room_meta_updated carrying the new name",
  );

  // A rename carrying a revision the Pi has already passed → action_error.
  const staleRenameID = randomUUID();
  appPeer.sendEnvelope(fakePi.pubkeyStandard, pairRoom, {
    type: "session_rename",
    id: staleRenameID,
    session_id: announced.session_id,
    display_name: "should not stick",
    rev: currentRev - 1000,
  });
  await appPeer.waitInner(
    (i) => i.type === "action_error" && i.in_reply_to === staleRenameID,
    "action_error for a stale rename",
  );

  // ── Control plane, against the REAL gateway ──────────────────────────────
  //
  // FINDING (see README): `Gateway.reply()` addresses its answer at
  // `room: CONTROL_ROOM_ID` — its OWN room — while the outer envelope's `room`
  // means the DESTINATION's room. The app registers on `main`, so the relay
  // finds no `(app, "ctrl")` connection and answers the GATEWAY with
  // `transport_error`. Prove it first, with only the `main` connection open.
  appPeer.sendEnvelope(gatewayKey.pubkeyStandard, "ctrl", {
    type: "workspace_list",
    id: randomUUID(),
  });
  await sleep(1_200);
  const undeliverable = rec.frames.some(
    (f) => f.dir === "s2c" && f.label === "gateway/ctrl" && f.text.includes('"transport_error"'),
  );
  if (!undeliverable) {
    throw new Error("expected the gateway's reply to bounce; did gateway.ts change?");
  }
  console.log("app      gateway reply bounced (transport_error) — finding reproduced");

  // Work around it INSIDE THE HARNESS so the real payloads can still be
  // captured: open a second connection for the same app key, registered at
  // `ctrl`, which is the address the gateway insists on writing. Requests keep
  // going out on `main`, exactly as the app sends them.
  const appCtrl = new RelayPeer({ identity: app, roomID: "ctrl", name: "app-ctrl" });
  await appCtrl.connect();

  const ctrl = async (inner, what, pred) => {
    appPeer.sendEnvelope(gatewayKey.pubkeyStandard, "ctrl", inner);
    return appCtrl.waitInner(pred ?? ((i) => i.in_reply_to === inner.id), what);
  };

  await ctrl({ type: "workspace_list", id: randomUUID() }, "workspace_list action_ok");
  await ctrl({ type: "session_list", id: randomUUID() }, "session_list action_ok");

  const createKey = randomUUID();
  const createID = randomUUID();
  await ctrl(
    {
      type: "create_session",
      id: createID,
      idempotency_key: createKey,
      workspace_id: gwInfo.workspace.workspace_id,
      display_name: "created by capture",
      background: true,
    },
    "create_session action_ok",
  );
  // Same key, new rpc id: the machine replays the original outcome.
  await ctrl(
    {
      type: "create_session",
      id: randomUUID(),
      idempotency_key: createKey,
      workspace_id: gwInfo.workspace.workspace_id,
      display_name: "created by capture",
      background: true,
    },
    "create_session idempotent replay",
  );
  // No idempotency_key on a mutating action → refused, not defaulted.
  await ctrl(
    { type: "create_session", id: randomUUID(), workspace_id: gwInfo.workspace.workspace_id },
    "create_session action_error (missing idempotency_key)",
  );
  await ctrl(
    {
      type: "session_rename",
      id: randomUUID(),
      session_id: gwInfo.seeded_session_id,
      display_name: "seeded, renamed",
      rev: 1,
    },
    "session_rename action_ok from the gateway",
  );
  await ctrl(
    {
      type: "session_stop",
      id: randomUUID(),
      session_id: "no-such-session",
      idempotency_key: randomUUID(),
    },
    "session_stop action_error",
  );
  console.log("app      control plane exercised");

  // ── fake-pi's control room: action_ok BEFORE room_announced ──────────────
  const spawnID = randomUUID();
  appPeer.sendEnvelope(fakePi.pubkeyStandard, "ctrl", { type: "workspace_list", id: spawnID });
  const wsReply = await appPeer.waitInner(
    (i) => i.in_reply_to === spawnID,
    "fake-pi workspace_list",
  );
  const harnessWorkspace = wsReply.inner.workspaces[0].workspace_id;
  const createID2 = randomUUID();
  appPeer.sendEnvelope(fakePi.pubkeyStandard, "ctrl", {
    type: "create_session",
    id: createID2,
    idempotency_key: randomUUID(),
    workspace_id: harnessWorkspace,
    display_name: "spawned-by-capture",
    background: true,
  });
  const spawned = await appPeer.waitInner((i) => i.in_reply_to === createID2, "create_session ack");
  await appPeer.waitControl(
    (f) => f.type === "room_announced" && f.room_id === spawned.inner.session_id,
    "room_announced for the spawned session",
  );

  // ── Merge-patch semantics, stimulated by a synthetic Pi ──────────────────
  //
  // What is pinned here is the RELAY's reply. fake-pi never sends a stale
  // revision or an explicit null, and modifying it is out of bounds.
  const patchRoom = randomUUID();
  const patchPeer = new RelayPeer({
    identity: patchPi,
    roomID: patchRoom,
    name: "patch-pi",
    roomMeta: {
      name: "patch-target",
      cwd: wsB,
      session_id: patchRoom,
      workspace_path: wsB,
      name_rev: 1_780_000_000_000,
      model: "claude-sonnet-4.5",
      thinking: "medium",
      working: false,
    },
  });
  await patchPeer.connect();
  await appPeer.waitControl(
    (f) => f.type === "room_announced" && f.room_id === patchRoom,
    "room_announced for the patch target",
  );

  const patch = async (meta, what, pred) => {
    patchPeer.send({ type: "room_meta_update", room_id: patchRoom, meta });
    return appPeer.waitControl(
      (f) => f.type === "room_meta_updated" && f.room_id === patchRoom && pred(f.meta),
      what,
    );
  };

  // 1. working only — model, thinking and name must survive untouched.
  await patch({ working: true }, "room_meta_updated after a working-only patch", (m) => m.working === true);
  // 2. explicit null clears the nullable string; `working` stays as set above.
  await patch({ model: null }, "room_meta_updated after clearing model", (m) => m.model === undefined);
  // 3. a strictly newer revision wins.
  await patch(
    { name: "patched name", name_rev: 1_780_000_000_001 },
    "room_meta_updated after an accepted rename",
    (m) => m.name === "patched name",
  );
  // 4. an EQUAL revision is rejected (strictly-greater, not >=) — and the relay
  //    still re-broadcasts the current name, which is how the sender re-syncs.
  patchPeer.send({
    type: "room_meta_update",
    room_id: patchRoom,
    meta: { name: "equal-rev must lose", name_rev: 1_780_000_000_001 },
  });
  await sleep(400);
  // 5. a strictly older revision is rejected the same way.
  patchPeer.send({
    type: "room_meta_update",
    room_id: patchRoom,
    meta: { name: "stale must lose", name_rev: 1_700_000_000_000 },
  });
  await sleep(400);
  console.log("app      merge-patch cases captured");

  // ── room_ended + transport_error ─────────────────────────────────────────
  pi.stdin.write("stop 1\n");
  const ended = await appPeer.waitControl(
    (f) => f.type === "room_ended" && f.peer === fakePi.pubkeyStandard,
    "room_ended",
  );
  await sleep(200);
  // An envelope addressed at a room with no live connection.
  appPeer.sendEnvelope(fakePi.pubkeyStandard, ended.room_id, {
    type: "user_message",
    id: randomUUID(),
    text: "nobody is home",
  });
  await appPeer.waitControl((f) => f.type === "transport_error", "transport_error");

  // ── peer_offline: take the whole peer down ───────────────────────────────
  patchPeer.close();
  pi.kill("SIGKILL");
  await appPeer.waitControl(
    (f) => f.type === "peer_offline" && f.peer === fakePi.pubkeyStandard,
    "peer_offline",
  );
  console.log("app      lifecycle captured");

  // A presence snapshot AFTER a peer has been seen: since_ts is populated now,
  // where the first snapshot of the run had it null.
  appPeer.send({ type: "presence_check", peers: watched });
  await appPeer.waitControl(
    (f) => f.type === "presence" && f.states.some((s) => s.since_ts !== null),
    "a presence snapshot with since_ts",
  );

  gw.kill("SIGTERM");
  await sleep(500);
  appCtrl.close();
  appPeer.close();
  server.close();

  // ── Emit ──────────────────────────────────────────────────────────────────
  writeFixtures({
    qrLine,
    qrEPK,
    piKey: fakePi.pubkeyStandard,
    appKey: app.pubkeyStandard,
    gwKey: gatewayKey.pubkeyStandard,
    pairRoom,
    patchRoom,
  });
}

function writeFixtures(ctx) {
  const c2s = (p) => (f) => f.dir === "c2s" && p(f);
  const s2c = (p) => (f) => f.dir === "s2c" && p(f);

  // ── handshake ─────────────────────────────────────────────────────────────
  fixture(
    "hello_app",
    rec.one("hello_app", c2s(typed("hello", (j) => j.pubkey === ctx.appKey))),
    "The app's hello. room_id is always \"main\" and no room_meta is published.",
  );
  fixture(
    "hello_pi_session",
    rec.one(
      "hello_pi_session",
      c2s(typed("hello", (j) => j.pubkey === ctx.piKey && j.room_meta?.session_id)),
    ),
    "scripts/fake-pi.mjs opening a chat room: the full post-plan-61 room_meta.",
  );
  fixture(
    "hello_pi_control",
    rec.one(
      "hello_pi_control",
      c2s(typed("hello", (j) => j.pubkey === ctx.gwKey && j.room_id === "ctrl")),
    ),
    "The REAL pi-extension Gateway (daemon/gateway.ts) opening its ctrl room. Note the ABSENT session_id and name_rev: a control room has no session identity.",
  );
  fixture(
    "hello_harness_control",
    rec.one(
      "hello_harness_control",
      c2s(typed("hello", (j) => j.pubkey === ctx.piKey && j.room_id === "ctrl")),
    ),
    "scripts/fake-pi.mjs's control room. Same shape, and it omits workspace_path where the real gateway sends it.",
  );
  // challenge + auth are pinned to the APP's connection specifically, so the
  // three frames form one verifiable handshake: hello_app.pubkey signs
  // challenge.nonce to produce auth.sig.
  const appMain = (p) => (f) => f.label === "app/main" && p(f);
  fixture(
    "challenge",
    rec.one("challenge", appMain(s2c(typed("challenge")))),
    "Relay step 2, on the app's own connection. 32 random bytes, standard base64.",
  );
  fixture(
    "auth",
    rec.one("auth", appMain(c2s(typed("auth")))),
    "Ed25519 signature over the RAW decoded nonce bytes of challenge.json, standard base64. Verifiable against hello_app.pubkey.",
  );

  // ── relay control frames ─────────────────────────────────────────────────
  fixture(
    "room_announced",
    rec.one("room_announced", s2c(typed("room_announced", (j) => j.session_id && j.name_rev))),
    "Relay-built. RoomMeta serialised FLAT with type+peer stamped on top.",
  );
  fixture(
    "room_announced_control",
    rec.one("room_announced_control", s2c(typed("room_announced", (j) => j.role === "control"))),
    "The gateway's ctrl room as the relay announces it. Note role and the absent session_id.",
  );
  fixture("room_ended", rec.one("room_ended", s2c(typed("room_ended"))), "Last connection at a room went away.");
  fixture(
    "rooms_empty",
    rec.one("rooms_empty", s2c(typed("rooms", (j) => j.rooms.length === 0))),
    "rooms_check answered before the Pi registered anything.",
  );
  fixture(
    "rooms_snapshot",
    rec.one("rooms_snapshot", s2c(typed("rooms", (j) => j.rooms.length > 1))),
    "A populated rooms_check snapshot: one RoomMeta per distinct room.",
  );
  fixture(
    "presence_offline",
    rec.one(
      "presence_offline",
      s2c(typed("presence", (j) => j.states.every((s) => s.since_ts === null))),
    ),
    "presence_check for peers the relay has never seen: online false, since_ts NULL (present, not omitted).",
  );
  fixture(
    "presence_with_since_ts",
    rec.one(
      "presence_with_since_ts",
      s2c(typed("presence", (j) => j.states.some((s) => s.since_ts !== null))),
    ),
    "presence_check after a peer has disconnected: since_ts is the epoch-ms of the transition.",
  );
  fixture(
    "peer_online",
    rec.one("peer_online", s2c(typed("peer_online"))),
    "A real offline → online transition. Carries no timestamp.",
  );
  fixture("peer_offline", rec.one("peer_offline", s2c(typed("peer_offline"))), "Whole peer gone; since_ts in ms.");
  fixture(
    "transport_error",
    rec.one("transport_error", (f) => f.dir === "s2c" && f.label === "app/main" && typed("transport_error")(f)),
    "Envelope addressed at a (peer, room) with no live connection.",
  );
  fixture(
    "transport_error_gateway_reply_bounced",
    rec.one("transport_error_gateway_reply_bounced", (f) => f.dir === "s2c" && f.label === "gateway/ctrl" && typed("transport_error")(f)),
    "FINDING: the same frame, sent to the GATEWAY. pi-extension/src/daemon/gateway.ts reply() writes room: CONTROL_ROOM_ID on its answer, but the outer room means the DESTINATION's room and the app registers on main. Every control-plane answer from the real machine bounces.",
  );
  fixture(
    "control_reply_envelope_as_gateway_writes_it",
    rec.one("control_reply_envelope_as_gateway_writes_it", (f) => f.dir === "c2s" && f.label === "gateway/ctrl" && envelope()(f)),
    "The offending envelope, verbatim: room is \"ctrl\", the gateway's own room, not the app's.",
  );

  // ── app → relay control frames ───────────────────────────────────────────
  fixture("subscribe_rooms", rec.one("subscribe_rooms", c2s(typed("subscribe_rooms"))), "App-built.");
  fixture("subscribe_presence", rec.one("subscribe_presence", c2s(typed("subscribe_presence"))), "App-built.");
  fixture("rooms_check", rec.one("rooms_check", c2s(typed("rooms_check"))), "App-built.");
  fixture("presence_check", rec.one("presence_check", c2s(typed("presence_check"))), "App-built.");

  // ── merge patch ───────────────────────────────────────────────────────────
  fixture(
    "room_meta_update_name",
    rec.one(
      "room_meta_update_name",
      c2s(typed("room_meta_update", (j) => typeof j.meta?.name === "string" && j.meta?.name_rev)),
    ),
    "Pi → relay name patch with its revision. A rename is a patch, never a re-register.",
  );
  const patched = (extra) => (j) => j.room_id === ctx.patchRoom && extra(j);
  fixture(
    "room_meta_update_working",
    rec.one(
      "room_meta_update_working",
      c2s(typed("room_meta_update", patched((j) => Object.keys(j.meta).length === 1 && j.meta.working === true))),
    ),
    "Pi → relay working-only patch. Every other field must be left alone.",
  );
  fixture(
    "room_meta_update_clear_model",
    rec.one(
      "room_meta_update_clear_model",
      c2s(typed("room_meta_update", patched((j) => "model" in j.meta && j.meta.model === null))),
    ),
    "Pi → relay patch clearing a nullable string with an explicit null.",
  );
  fixture(
    "room_meta_updated_name",
    rec.one("room_meta_updated_name", s2c(typed("room_meta_updated", patched((j) => j.meta?.name === "patched name")))),
    "Relay broadcast after an ACCEPTED name patch (strictly newer name_rev).",
  );
  fixture(
    "room_meta_updated_working",
    rec.one(
      "room_meta_updated_working",
      s2c(typed("room_meta_updated", patched((j) => j.meta?.working === true && j.meta?.model))),
    ),
    "Relay broadcast after a working-only patch: the post-patch FULL state. model, thinking, name and name_rev were NOT in the patch and are all still there.",
  );
  fixture(
    "room_meta_updated_model_cleared",
    rec.one(
      "room_meta_updated_model_cleared",
      s2c(typed("room_meta_updated", patched((j) => !("model" in j.meta) && j.meta.thinking))),
    ),
    "Relay broadcast after an explicit null: model is OMITTED, not null.",
  );
  fixture(
    "room_meta_updated_harness_working",
    rec.one(
      "room_meta_updated_harness_working",
      s2c(typed("room_meta_updated", (j) => j.room_id === ctx.pairRoom && j.meta?.working === true)),
    ),
    "The same shape from scripts/fake-pi.mjs when a turn starts.",
  );
  const rejected = rec.find(
    s2c(typed("room_meta_updated", patched((j) => j.meta?.name === "patched name" && j.meta?.name_rev === 1780000000001))),
  );
  if (rejected.length < 2) throw new Error("expected a re-broadcast after a rejected name patch");
  fixture(
    "room_meta_updated_stale_rejected",
    rejected.at(-1),
    "Relay broadcast after a REJECTED name patch: the CURRENT name is re-sent, which is how the stale sender re-syncs. Compare with room_meta_update_stale_name.",
  );
  fixture(
    "room_meta_update_stale_name",
    rec.one("room_meta_update_stale_name", c2s(typed("room_meta_update", (j) => j.meta?.name === "stale must lose"))),
    "The stale patch the relay rejected. Its name never reaches a subscriber.",
  );
  fixture(
    "room_meta_update_equal_rev",
    rec.one("room_meta_update_equal_rev", c2s(typed("room_meta_update", (j) => j.meta?.name === "equal-rev must lose"))),
    "An EQUAL name_rev. Rejected too: the gate is strictly-greater.",
  );

  // ── envelopes ─────────────────────────────────────────────────────────────
  fixture(
    "envelope_app_to_pi",
    rec.one("envelope_app_to_pi", c2s(innerType("user_message"))),
    "As the APP writes it: peer = destination, room = the destination's room.",
  );
  fixture(
    "envelope_pi_to_app_rewritten",
    rec.one("envelope_pi_to_app_rewritten", s2c(innerType("user_message"))),
    "The SAME turn coming back, after the relay rewrote peer to the sender and room to the SENDER's room. Same field names, opposite meaning.",
  );

  // ── inner frames ──────────────────────────────────────────────────────────
  const inner = (name, type, note, extra) =>
    fixture(name, rec.one(name, innerType(type, extra ?? (() => true))), note);

  inner("inner_pair_request", "pair_request", "App → Pi, on the pairing transport.");
  inner("inner_pair_ok", "pair_ok", "fake-pi's reply, with the plan-61 identity fields.");
  inner("inner_pair_error", "pair_error", "The same token replayed: consumed on first use.");
  inner("inner_user_message_echo", "user_message", "The Pi's ECHO of the app's turn — the app renders from this, not from its optimistic copy.", (i, o, f) => f.dir === "s2c");
  inner("inner_agent_chunk", "agent_chunk", "One streaming delta.");
  inner("inner_agent_done", "agent_done", "End of turn, with usage.");
  inner("inner_models_list", "models_list", "Reply to list_models.");
  inner("inner_session_history", "session_history", "Reply to session_sync.");
  inner("inner_pong", "pong", "Reply to a Pi-liveness ping.");
  inner("inner_session_rename", "session_rename", "App → Pi. rev is the revision the device last SAW.");
  inner(
    "inner_action_ok_rename",
    "action_ok",
    "fake-pi's action_ok for session_rename.",
    (i) => i.action === "session_rename" && i.session_id === undefined,
  );
  inner(
    "inner_action_error_rename",
    "action_error",
    "A rename carrying a revision older than the Pi's.",
    (i) => i.action === "session_rename",
  );

  // ── control plane (real gateway) ─────────────────────────────────────────
  inner(
    "control_workspace_list",
    "workspace_list",
    "App → gateway. No paths on the wire, so this takes no arguments.",
    (i, o, f) => f.dir === "c2s",
  );
  inner(
    "control_action_ok_workspace_list",
    "action_ok",
    "REAL gateway (daemon/gateway.ts + daemon/sessions.ts): WorkspaceView entries.",
    (i) => i.action === "workspace_list",
  );
  inner(
    "control_action_ok_session_list",
    "action_ok",
    "REAL gateway: SessionEntry entries plus the live `running` flag. Note mode/desired/created_at, which the fake-pi harness does NOT send.",
    (i) => i.action === "session_list",
  );
  inner(
    "control_create_session",
    "create_session",
    "App → gateway. background is always true; idempotency_key is minted once per user intent.",
    (i, o, f) => f.dir === "c2s" && i.idempotency_key,
  );
  inner(
    "control_action_ok_create_session",
    "action_ok",
    "REAL gateway: the first serve of an idempotency key.",
    (i) => i.action === "create_session" && i.session_id && i.replayed === undefined,
  );
  inner(
    "control_action_ok_create_session_replay",
    "action_ok",
    "REAL gateway: the SAME key replayed. Carries replayed:true and drops the other fields.",
    (i) => i.action === "create_session" && i.replayed === true,
  );
  inner(
    "control_action_error_missing_key",
    "action_error",
    "REAL gateway: a mutating action with no idempotency_key is refused, not defaulted.",
    (i) => i.action === "create_session",
  );
  inner(
    "control_action_ok_session_rename",
    "action_ok",
    "REAL gateway: session_rename needs no idempotency key.",
    (i) => i.action === "session_rename" && i.session_id !== undefined,
  );
  inner(
    "control_action_error_unknown_session",
    "action_error",
    "REAL gateway: session_stop against an id it has never catalogued.",
    (i) => i.action === "session_stop",
  );

  // ── the QR spelling ───────────────────────────────────────────────────────
  writeFileSync(
    join(opts.out, "pairing_qr.json"),
    JSON.stringify(
      {
        _fixture: "pairing_qr",
        _captured_at: CAPTURED_AT,
        _produced_by: "scripts/fake-pi.mjs qrPayload(), mirroring pi-extension/src/pairing/qr.ts",
        _note:
          "epk is URL-SAFE and UNPADDED here, while every relay surface spells the same key with the STANDARD alphabet and padding. A PeerID parsed from this must encode back to peer_standard, never to epk.",
        payload: ctx.qrLine,
        epk_url_safe: ctx.qrEPK,
        peer_standard: ctx.piKey,
      },
      null,
      2,
    ) + "\n",
  );
  fixtures.push({ name: "pairing_qr", note: "QR epk (url-safe) vs the relay's standard spelling." });

  // ── transcript ────────────────────────────────────────────────────────────
  writeFileSync(
    join(opts.out, "..", "transcript.jsonl"),
    rec.frames.map((f) => JSON.stringify({ seq: f.seq, ms: f.ms, conn: f.conn, label: f.label, dir: f.dir, text: f.text })).join("\n") + "\n",
  );

  console.log(`\nwrote ${fixtures.length} fixtures to ${opts.out}`);
  console.log(`wrote ${rec.frames.length} frames to ${join(opts.out, "..", "transcript.jsonl")}`);
}

try {
  await main();
} catch (e) {
  // A partial transcript is the only way to debug a capture that died
  // half-way, so always leave one behind.
  mkdirSync(opts.out, { recursive: true });
  writeFileSync(
    join(opts.out, "..", "transcript.jsonl"),
    rec.frames.map((f) => JSON.stringify(f)).join("\n") + "\n",
  );
  console.error(`capture failed after ${rec.frames.length} frames: ${e.message}`);
  throw e;
} finally {
  for (const c of children) {
    try { c.kill("SIGKILL"); } catch { /* already gone */ }
  }
  if (!opts.keep) rmSync(home, { recursive: true, force: true });
  else console.log(`kept ${home}`);
}
process.exit(0);
