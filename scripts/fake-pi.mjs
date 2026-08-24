#!/usr/bin/env node
/**
 * fake-pi.mjs — a protocol-faithful stand-in for `pi-extension`, for driving
 * the mobile app against a local relay with REAL data and no coding agent.
 *
 * It is NOT a mock of the app's transport: it speaks the actual wire protocol
 * documented in `PROTOCOL.md` against a real `relay` process — Ed25519
 * challenge-response, `hello` with the plan-61 `room_meta`, opaque outer
 * envelopes, `pair_request`/`pair_ok`, chat frames, and `room_meta_update`
 * patches. Anything it gets wrong shows up as a relay/app failure, which is
 * the point: it is a conformance harness, not a fixture.
 *
 * What it deliberately does NOT do (and why):
 *   - No `mesh_versions` self-revoke polling. That is the machine hardening a
 *     revoked Owner out; a throwaway harness has nothing to protect.
 *   - No real process spawn behind `create_session`. The control room answers
 *     by minting a catalogue entry and opening a room for it, which is exactly
 *     what the app observes (`action_ok` then `room_announced`).
 *
 * Usage
 *   node scripts/fake-pi.mjs --relay ws://localhost:3777 \
 *     --session "/Users/x/proj/api:api-server" \
 *     --session "/Users/x/proj/api:api-worker" \
 *     --session "/Users/x/proj/web:web"
 *
 * Options
 *   --relay <url>        ws://, wss://, http:// or https:// (converted). Default ws://localhost:3777
 *   --session <path:name>  Repeatable. `path` is the workspace dir, `name` the label.
 *   --identity <file>    Ed25519 keypair store. Default ~/.remote-pi-fake/identity.json
 *   --state <file>       Session catalogue. Default alongside --identity as sessions.json
 *   --hostname <name>    Reported in pair_ok. Default os.hostname()
 *   --ttl <seconds>      Pairing-token lifetime. Default 600 (the real Pi uses 60)
 *   --no-ctrl            Do not open the supervisor `ctrl` control room
 *   --verbose            Log every inbound frame
 *
 * The pairing QR PAYLOAD is printed as text — paste it into the app's
 * "Paste pairing code" sheet. No camera needed.
 *
 * stdin commands (one per line), for driving a demo:
 *   list                    show sessions, ids, names, name_rev
 *   qr [n]                  issue a fresh token and print the payload for session n (default 0)
 *   rename <n> <name>       Pi-side rename (metadata patch, same as `/remote-pi rename`)
 *   working <n> on|off      toggle the room's `working` flag
 *   say <n> <text>          push an unprompted agent_message into session n
 *   stop <n>                drop that room's relay connection (the session goes offline)
 *   start <n>               bring a stopped room back up on the SAME session id
 *   quit
 */

import { createPrivateKey, generateKeyPairSync, randomBytes, randomUUID, sign as edSign } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { hostname as osHostname, homedir } from "node:os";
import { dirname, basename, join } from "node:path";
import { createInterface } from "node:readline";

// ── Reserved ids from the real implementation ────────────────────────────────
// `pi-extension/src/protocol/control_wire.ts`
const CONTROL_ROOM_ID = "ctrl";
const CONTROL_ROOM_ROLE = "control";

// ── CLI ──────────────────────────────────────────────────────────────────────

function parseArgs(argv) {
  const opts = {
    relay: "ws://localhost:3777",
    sessions: [],
    identity: join(homedir(), ".remote-pi-fake", "identity.json"),
    hostname: osHostname(),
    ttlMs: 600_000,
    ctrl: true,
    verbose: false,
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const next = () => {
      const v = argv[++i];
      if (v === undefined) throw new Error(`${a} requires a value`);
      return v;
    };
    switch (a) {
      case "--relay": opts.relay = next(); break;
      case "--session": opts.sessions.push(next()); break;
      case "--identity": opts.identity = next(); break;
      case "--state": opts.state = next(); break;
      case "--hostname": opts.hostname = next(); break;
      case "--ttl": opts.ttlMs = Math.max(1, Number(next())) * 1000; break;
      case "--no-ctrl": opts.ctrl = false; break;
      case "--ctrl": opts.ctrl = true; break;
      case "--verbose": case "-v": opts.verbose = true; break;
      case "--help": case "-h": opts.help = true; break;
      default: throw new Error(`unknown option: ${a}`);
    }
  }
  return opts;
}

/** `--session "/path/to/dir:label"` — the LAST colon splits, so Windows-ish or
 *  colon-bearing labels still work as long as the path has none. */
function parseSessionSpec(spec) {
  const idx = spec.lastIndexOf(":");
  if (idx <= 0) {
    // No label given — fall back to the folder basename, like the real Pi does.
    return { path: spec, name: basename(spec) || spec };
  }
  const path = spec.slice(0, idx);
  const name = spec.slice(idx + 1) || basename(path);
  return { path, name };
}

// ── Identity (Ed25519, persisted so re-runs keep the same peer id) ───────────

function loadOrCreateIdentity(file) {
  if (existsSync(file)) {
    const raw = JSON.parse(readFileSync(file, "utf8"));
    if (typeof raw.d === "string" && typeof raw.x === "string") return raw;
    throw new Error(`identity file ${file} is malformed (expected JWK d/x)`);
  }
  const { privateKey } = generateKeyPairSync("ed25519");
  const jwk = privateKey.export({ format: "jwk" }); // { kty, crv, x, d } base64url
  const saved = { kty: "OKP", crv: "Ed25519", d: jwk.d, x: jwk.x };
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(file, JSON.stringify(saved, null, 2) + "\n", { mode: 0o600 });
  return saved;
}

function privateKeyFrom(jwk) {
  return createPrivateKey({ key: { ...jwk, kty: "OKP", crv: "Ed25519" }, format: "jwk" });
}

// ── Session catalogue (the harness's `~/.pi/remote/sessions.json`) ───────────
//
// A real machine mints the session id in its catalogue and the child adopts it
// (plan 61 Phase 3), so a supervisor restart re-attaches to the SAME rooms
// instead of orphaning every tile on the phone. Persisting the id here keeps
// that property: restart the harness and the app's sessions stay the same
// sessions, renames included.

function loadCatalogue(file) {
  try { return JSON.parse(readFileSync(file, "utf8")); } catch { return {}; }
}

function saveCatalogue(file, cat) {
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(file, JSON.stringify(cat, null, 2) + "\n");
}

// ── Encoding helpers ─────────────────────────────────────────────────────────
//
// PROTOCOL.md: "Nas fronteiras do protocolo, Pi-key e Owner-key usam Base64
// RFC 4648 padrão, com padding." The relay derives every peer id as
// `B64.encode(vk.to_bytes())` (standard) regardless of what `hello` carried,
// so the hello pubkey is sent standard. The QR carries base64URL because the
// app parses it with `base64Url.decode` (`app/lib/pairing/qr_scanner.dart`).

const b64 = (buf) => Buffer.from(buf).toString("base64");
const b64url = (buf) => Buffer.from(buf).toString("base64url");
const encodeInner = (obj) => Buffer.from(JSON.stringify(obj)).toString("base64");
const decodeInner = (ct) => JSON.parse(Buffer.from(ct, "base64").toString("utf8"));

function toWsUrl(url) {
  if (url.startsWith("https://")) return "wss://" + url.slice(8);
  if (url.startsWith("http://")) return "ws://" + url.slice(7);
  return url;
}

/** `sha256(realpath(cwd))[:8]` — the daemon id the real machine uses as
 *  `workspace_id` (plan 61 Phase 3 deviation, `daemon/sessions.ts`). */
function workspaceIdFor(path) {
  return createHash("sha256").update(path).digest("hex").slice(0, 8);
}

// ── Pairing token (mirrors pi-extension/src/pairing/qr.ts QRSession) ─────────

class QRSession {
  #active = null;
  issue(ttlMs) {
    const token = randomBytes(16).toString("base64url");
    this.#active = { token, expiresAt: Date.now() + ttlMs, consumed: false };
    return this.#active;
  }
  /** "ok" | "expired" | "consumed" | "unknown" — same states the real one returns. */
  consume(token) {
    if (!this.#active || this.#active.token !== token) return "unknown";
    if (this.#active.consumed) return "consumed";
    if (Date.now() > this.#active.expiresAt) return "expired";
    this.#active.consumed = true;
    return "ok";
  }
}

// ── One relay connection = one room ──────────────────────────────────────────

class Room {
  /**
   * @param {FakePi} pi
   * @param {{roomId: string, meta: object}} spec
   */
  constructor(pi, spec) {
    this.pi = pi;
    this.roomId = spec.roomId;
    this.meta = spec.meta;
    this.ws = null;
    this.ready = false;
  }

  get label() { return `${this.roomId.slice(0, 8)}/${this.meta.name}`; }

  connect() {
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(this.pi.relayUrl);
      this.ws = ws;
      let authed = false;

      const fail = (e) => { if (!authed) reject(e instanceof Error ? e : new Error(String(e))); };

      ws.addEventListener("error", (ev) => fail(ev.message ?? "websocket error"));
      ws.addEventListener("close", () => {
        this.ready = false;
        this.pi.log(`[${this.label}] relay connection closed`);
        fail("closed before auth");
      });

      ws.addEventListener("open", () => {
        // hello carries room_id + the full plan-61 room_meta. The relay stores
        // these opaquely and re-emits them as room_announced / rooms.
        ws.send(JSON.stringify({
          type: "hello",
          pubkey: this.pi.pubkeyStandard,
          room_id: this.roomId,
          room_meta: this.meta,
        }));
      });

      ws.addEventListener("message", (ev) => {
        const text = typeof ev.data === "string" ? ev.data : String(ev.data);
        for (const line of text.split("\n")) {
          const trimmed = line.trim();
          if (!trimmed) continue;
          if (!authed) {
            let frame;
            try { frame = JSON.parse(trimmed); } catch { return reject(new Error(`auth: not JSON: ${trimmed}`)); }
            if (frame.type !== "challenge" || typeof frame.nonce !== "string") {
              return reject(new Error(`auth: expected challenge, got ${trimmed}`));
            }
            // The relay verifies the signature over the RAW nonce bytes
            // (relay/src/auth/challenge.rs::verify_auth → vk.verify(nonce,…)),
            // NOT over the base64 text. Signature goes back standard base64.
            const nonce = Buffer.from(frame.nonce, "base64");
            const sig = edSign(null, nonce, this.pi.privateKey);
            ws.send(JSON.stringify({ type: "auth", sig: b64(sig) }));
            authed = true;
            this.ready = true;
            // The relay sends no "ok" — it just starts routing.
            resolve(this);
            continue;
          }
          this.#onFrame(trimmed);
        }
      });
    });
  }

  #onFrame(line) {
    let frame;
    try { frame = JSON.parse(line); } catch { return; }
    if (this.pi.verbose) this.pi.log(`[${this.label}] ← ${line.slice(0, 400)}`);

    if (typeof frame.type === "string") {
      // Relay control frame addressed at us (transport_error, presence, …).
      if (frame.type === "transport_error") {
        this.pi.log(`[${this.label}] transport_error reason=${frame.reason} peer=…${String(frame.peer).slice(-8)} room=${frame.room_id}`);
      }
      return;
    }
    if (typeof frame.peer !== "string" || typeof frame.ct !== "string") return;

    let inner;
    try { inner = decodeInner(frame.ct); } catch { return; }
    if (!inner || typeof inner.type !== "string") return;
    this.pi.handleInner(this, frame.peer, inner);
  }

  /** Server→app inner message, wrapped in the opaque outer envelope. */
  send(peer, msg) {
    if (!this.ws || this.ws.readyState !== 1) return;
    this.ws.send(JSON.stringify({ peer, ct: encodeInner(msg) }));
    if (this.pi.verbose) this.pi.log(`[${this.label}] → ${JSON.stringify(msg).slice(0, 300)}`);
  }

  /** Relay control frame (not routed to the app peer). */
  sendControl(frame) {
    if (!this.ws || this.ws.readyState !== 1) return;
    this.ws.send(JSON.stringify(frame));
    if (this.pi.verbose) this.pi.log(`[${this.label}] ⇑ ${JSON.stringify(frame).slice(0, 300)}`);
  }

  /** Publish a display-name change as a metadata patch — never a re-register.
   *  This is the plan-61 rule the harness exists to exercise: the room id does
   *  not move, so the app must keep its tile and its message box. */
  publishName(name) {
    if (this.meta.name === name) return this.meta.name_rev;
    const rev = this.pi.nextNameRev();
    this.meta.name = name;
    this.meta.name_rev = rev;
    this.sendControl({
      type: "room_meta_update",
      room_id: this.roomId,
      meta: { name, name_rev: rev },
    });
    this.pi.persist(this);
    return rev;
  }

  setWorking(working) {
    this.meta.working = working;
    this.sendControl({ type: "room_meta_update", room_id: this.roomId, meta: { working } });
  }
}

// ── The fake machine ─────────────────────────────────────────────────────────

class FakePi {
  constructor(opts) {
    this.opts = opts;
    this.relayUrl = toWsUrl(opts.relay);
    this.verbose = opts.verbose;
    this.hostname = opts.hostname;

    const jwk = loadOrCreateIdentity(opts.identity);
    this.privateKey = privateKeyFrom(jwk);
    const pubBytes = Buffer.from(jwk.x, "base64url");
    this.pubkeyStandard = b64(pubBytes);   // hello / relay peer id
    this.pubkeyUrl = b64url(pubBytes);     // QR payload

    this.catalogueFile = opts.state ?? join(dirname(opts.identity), "sessions.json");
    this.catalogue = loadCatalogue(this.catalogueFile);

    this.qr = new QRSession();
    this.rooms = [];        // chat rooms, in creation order
    this.control = null;    // the `ctrl` room, if enabled
    this.pairedPeers = new Set();
    this.startedAt = Date.now();
    this._nameRev = 0;
    this._idempotency = new Map(); // key → recorded reply payload
    this.workspaces = new Map();   // workspace_id → { path, display_name }
  }

  log(...args) { console.log(...args); }

  nextNameRev() {
    const now = Date.now();
    this._nameRev = now > this._nameRev ? now : this._nameRev + 1;
    return this._nameRev;
  }

  registerWorkspace(path) {
    const id = workspaceIdFor(path);
    if (!this.workspaces.has(id)) {
      this.workspaces.set(id, { path, display_name: basename(path) || path });
    }
    return id;
  }

  /** `catalogueKey` is the stable handle for a `--session` spec: the id and the
   *  current label are looked up under it so a restart re-opens the SAME room.
   *  Sessions minted at runtime (`create_session`) pass their own id and are
   *  filed under it directly. */
  makeRoom({ path, name, sessionId, catalogueKey }) {
    const key = catalogueKey ?? `${path}::${name}`;
    const entry = this.catalogue[key] ?? {};
    const id = sessionId ?? entry.session_id ?? randomUUID();
    this.registerWorkspace(path);
    const meta = {
      // plan 61: the room IS the session, and the identity fields ride along.
      name: entry.name ?? name,
      cwd: path,
      session_id: id,
      workspace_path: path,
      name_rev: entry.name_rev ?? this.nextNameRev(),
      model: "claude-sonnet-4.5",
      thinking: "medium",
      working: false,
    };
    if (typeof meta.name_rev === "number" && meta.name_rev > this._nameRev) {
      this._nameRev = meta.name_rev;
    }
    const room = new Room(this, { roomId: id, meta });
    room.catalogueKey = key;
    room.history = [];
    this.rooms.push(room);
    this.persist(room);
    return room;
  }

  persist(room) {
    this.catalogue[room.catalogueKey] = {
      session_id: room.meta.session_id,
      workspace_path: room.meta.workspace_path,
      name: room.meta.name,
      name_rev: room.meta.name_rev,
    };
    saveCatalogue(this.catalogueFile, this.catalogue);
  }

  makeControlRoom() {
    const room = new Room(this, {
      roomId: CONTROL_ROOM_ID,
      meta: {
        name: `${this.hostname} control`,
        cwd: homedir(),
        role: CONTROL_ROOM_ROLE,
        working: false,
      },
    });
    room.history = [];
    this.control = room;
    return room;
  }

  qrPayload(room) {
    const { token } = this.qr.issue(this.opts.ttlMs);
    const params = new URLSearchParams({
      t: token,
      epk: this.pubkeyUrl,
      n: room.meta.name.slice(0, 80),
    });
    params.set("rm", room.roomId);
    return `remotepi://pair?${params.toString()}`;
  }

  // ── Inner-message routing ─────────────────────────────────────────────────

  handleInner(room, peer, inner) {
    const isControl = room === this.control;
    if (inner.type !== "pair_request" && !this.pairedPeers.has(peer)) {
      // Mirrors the real auto-listener: a peer we never paired with (or one
      // that was revoked) gets told to re-scan rather than silently ignored.
      // Peers survive a restart of the app but not of this harness, so a
      // reconnecting app is re-admitted here on sight of any known frame.
      this.pairedPeers.add(peer);
      this.log(`[${room.label}] re-admitting peer …${peer.slice(-8)} (harness has no peers.json)`);
    }

    if (isControl) return this.#handleControl(room, peer, inner);

    switch (inner.type) {
      case "pair_request": return this.#handlePairRequest(room, peer, inner);
      case "user_message": return this.#handleUserMessage(room, peer, inner);
      case "session_sync": return this.#handleSessionSync(room, peer, inner);
      case "ping":
        return room.send(peer, { type: "pong", in_reply_to: inner.id });
      case "session_rename": return this.#handleRename(room, peer, inner);
      case "list_models": return this.#handleListModels(room, peer, inner);
      case "session_new": {
        room.history = [];
        return room.send(peer, { type: "action_ok", in_reply_to: inner.id, action: "session_new" });
      }
      case "session_compact": {
        room.send(peer, { type: "action_ok", in_reply_to: inner.id, action: "session_compact" });
        return room.send(peer, {
          type: "compaction",
          summary: "Context compacted by the fake Pi harness.",
          tokens_before: 41_200,
          ts: Date.now(),
        });
      }
      case "model_set": {
        room.meta.model = inner.model_id;
        room.sendControl({ type: "room_meta_update", room_id: room.roomId, meta: { model: inner.model_id } });
        return room.send(peer, { type: "action_ok", in_reply_to: inner.id, action: "model_set" });
      }
      case "thinking_set": {
        room.meta.thinking = inner.level;
        room.sendControl({ type: "room_meta_update", room_id: room.roomId, meta: { thinking: inner.level } });
        return room.send(peer, { type: "action_ok", in_reply_to: inner.id, action: "thinking_set" });
      }
      case "cancel":
        return room.send(peer, { type: "cancelled", in_reply_to: inner.id, target_id: inner.target_id });
      default:
        this.log(`[${room.label}] unhandled inner type: ${inner.type}`);
    }
  }

  #handlePairRequest(room, peer, inner) {
    const status = this.qr.consume(inner.token);
    if (status !== "ok") {
      const code = status === "expired" ? "token_expired"
        : status === "consumed" ? "token_consumed"
        : "token_unknown";
      this.log(`[${room.label}] pair_request REJECTED (${code}) from …${peer.slice(-8)}`);
      return room.send(peer, {
        type: "pair_error",
        in_reply_to: inner.id,
        code,
        message: `fake-pi: ${code}. Run \`qr\` for a fresh payload.`,
      });
    }
    this.pairedPeers.add(peer);
    this.log(`[${room.label}] PAIRED with "${inner.device_name}" (…${peer.slice(-8)})`);
    room.send(peer, {
      type: "pair_ok",
      in_reply_to: inner.id,
      session_name: room.meta.name,
      session_started_at: this.startedAt,
      room_id: room.roomId,
      // plan 61 — the app keys by session from its very first frame.
      session_id: room.meta.session_id,
      workspace_path: room.meta.workspace_path,
      display_name: room.meta.name,
      name_rev: room.meta.name_rev,
      harness: { name: "fake-pi harness", version: "0.0.0" },
      hostname: this.hostname,
    });
  }

  #handleUserMessage(room, peer, inner) {
    const ts = Date.now();
    room.history.push({ ts, type: "user_input", id: inner.id, text: inner.text });
    // Echo first: the app renders the user bubble from the Pi's echo, not from
    // its own optimistic copy (plan/24 source-of-truth model).
    room.send(peer, { type: "user_message", id: inner.id, text: inner.text });
    room.setWorking(true);

    const reply = this.#composeReply(room, inner.text);
    const chunks = reply.match(/.{1,48}(\s|$)/g) ?? [reply];
    let i = 0;
    const pump = () => {
      if (i < chunks.length) {
        room.send(peer, { type: "agent_chunk", in_reply_to: inner.id, delta: chunks[i++] });
        return setTimeout(pump, 60);
      }
      room.send(peer, {
        type: "agent_done",
        in_reply_to: inner.id,
        usage: { input_tokens: 120 + inner.text.length, output_tokens: reply.length },
      });
      room.history.push({ ts: Date.now(), type: "agent_message", in_reply_to: inner.id, text: reply });
      room.setWorking(false);
    };
    setTimeout(pump, 200);
  }

  #composeReply(room, text) {
    return [
      `[fake-pi] session "${room.meta.name}" in ${room.meta.workspace_path}`,
      `session_id=${room.meta.session_id}`,
      `You said: ${text}`,
      `No model is running — this harness echoes so the chat is not empty.`,
    ].join("\n");
  }

  #handleSessionSync(room, peer, inner) {
    const limit = typeof inner.limit === "number" ? inner.limit : room.history.length;
    const events = room.history.slice(-limit);
    room.send(peer, {
      type: "session_history",
      in_reply_to: inner.id,
      session_started_at: this.startedAt,
      events,
      eos: true,
      truncated: events.length < room.history.length,
    });
  }

  #handleRename(room, peer, inner) {
    const requested = typeof inner.display_name === "string" ? inner.display_name.trim() : "";
    const fail = (error) => room.send(peer, {
      type: "action_error", in_reply_to: inner.id, action: "session_rename", error,
    });
    if (!requested) return fail("display_name must be a non-empty string");
    if (inner.session_id && inner.session_id !== room.meta.session_id) {
      return fail("session_id does not match this session");
    }
    // Optimistic concurrency, same rule as pi-extension/src/index.ts:4160.
    if (typeof inner.rev === "number" && typeof room.meta.name_rev === "number"
        && inner.rev < room.meta.name_rev) {
      return fail("stale name revision — this session was renamed elsewhere");
    }
    const rev = room.publishName(requested);
    this.log(`[${room.label}] RENAMED → "${requested}" (name_rev=${rev}, room_id UNCHANGED)`);
    room.send(peer, { type: "action_ok", in_reply_to: inner.id, action: "session_rename" });
  }

  #handleListModels(room, peer, inner) {
    const models = [
      { id: "claude-sonnet-4.5", name: "Claude Sonnet 4.5", provider: "anthropic", reasoning: true, context_window: 200000, vision: true },
      { id: "claude-opus-4.7", name: "Claude Opus 4.7", provider: "anthropic", reasoning: true, context_window: 200000, vision: true },
      { id: "gpt-5.4", name: "GPT-5.4", provider: "openai", reasoning: true, context_window: 400000, vision: true },
    ];
    room.send(peer, {
      type: "models_list",
      in_reply_to: inner.id,
      models,
      current: models.find((m) => m.id === room.meta.model) ?? models[0],
    });
  }

  // ── Machine control plane (`ctrl` room) ───────────────────────────────────

  #handleControl(room, peer, inner) {
    const ok = (action, data = {}) => room.send(peer, { type: "action_ok", in_reply_to: inner.id, action, ...data });
    const err = (action, error) => room.send(peer, { type: "action_error", in_reply_to: inner.id, action, error });
    const MUTATING = new Set(["create_session", "session_start", "session_stop"]);

    if (MUTATING.has(inner.type) && typeof inner.idempotency_key !== "string") {
      // Refused, not defaulted: a per-attempt default deduplicates nothing.
      return err(inner.type, "idempotency_key must be a non-empty string");
    }
    const replay = MUTATING.has(inner.type) ? this._idempotency.get(inner.idempotency_key) : undefined;
    if (replay) {
      this.log(`[ctrl] idempotent replay of ${inner.type} (${inner.idempotency_key})`);
      return ok(inner.type, replay);
    }

    switch (inner.type) {
      case "workspace_list": {
        const workspaces = [...this.workspaces.entries()].map(([workspace_id, w]) => ({
          workspace_id, path: w.path, display_name: w.display_name,
        }));
        return ok("workspace_list", { workspaces });
      }
      case "session_list": {
        const sessions = this.rooms
          .filter((r) => !inner.workspace_id || workspaceIdFor(r.meta.workspace_path) === inner.workspace_id)
          .map((r) => ({
            session_id: r.meta.session_id,
            workspace_id: workspaceIdFor(r.meta.workspace_path),
            display_name: r.meta.name,
            name_rev: r.meta.name_rev,
            status: r.ready ? "running" : "stopped",
          }));
        return ok("session_list", { sessions });
      }
      case "create_session": {
        const ws = this.workspaces.get(inner.workspace_id);
        if (!ws) return err("create_session", `unknown workspace_id: ${inner.workspace_id}`);
        const sessionId = randomUUID();
        const name = inner.display_name || `${ws.display_name}-${sessionId.slice(0, 4)}`;
        const payload = { session_id: sessionId };
        this._idempotency.set(inner.idempotency_key, payload);
        // action_ok means "spawn requested", not "room is up" — the app waits
        // for room_announced. Open the room slightly after the ack so the app
        // exercises that ordering rather than racing it.
        ok("create_session", payload);
        const child = this.makeRoom({ path: ws.path, name, sessionId });
        setTimeout(() => {
          child.connect().then(
            () => this.log(`[ctrl] spawned session "${name}" (${sessionId})`),
            (e) => this.log(`[ctrl] spawn failed: ${e.message}`),
          );
        }, 400);
        return;
      }
      case "session_start":
      case "session_stop": {
        const target = this.rooms.find((r) => r.meta.session_id === inner.session_id);
        if (!target) return err(inner.type, `unknown session_id: ${inner.session_id}`);
        const payload = { session_id: inner.session_id };
        this._idempotency.set(inner.idempotency_key, payload);
        if (inner.type === "session_stop") target.ws?.close();
        else if (!target.ready) void target.connect().catch(() => {});
        return ok(inner.type, payload);
      }
      case "session_rename": {
        const target = this.rooms.find((r) => r.meta.session_id === inner.session_id);
        if (!target) return err("session_rename", `unknown session_id: ${inner.session_id}`);
        if (typeof inner.rev === "number" && inner.rev < target.meta.name_rev) {
          return err("session_rename", "stale name revision");
        }
        target.publishName(String(inner.display_name).trim());
        return ok("session_rename");
      }
      default:
        this.log(`[ctrl] unhandled control action: ${inner.type}`);
    }
  }
}

// ── main ─────────────────────────────────────────────────────────────────────

async function main() {
  let opts;
  try {
    opts = parseArgs(process.argv.slice(2));
  } catch (e) {
    console.error(`fake-pi: ${e.message}`);
    process.exit(2);
  }
  if (opts.help) {
    console.log(readFileSync(new URL(import.meta.url), "utf8").split("*/")[0].replace(/^\/\*\*?/, ""));
    return;
  }
  if (opts.sessions.length === 0) {
    console.error("fake-pi: at least one --session \"<path>:<name>\" is required");
    process.exit(2);
  }

  const pi = new FakePi(opts);
  console.log(`fake-pi: relay      ${pi.relayUrl}`);
  console.log(`fake-pi: identity   ${opts.identity}`);
  console.log(`fake-pi: pi-key     ${pi.pubkeyStandard}`);
  console.log(`fake-pi: hostname   ${pi.hostname}`);

  for (const spec of opts.sessions) {
    const { path, name } = parseSessionSpec(spec);
    pi.makeRoom({ path, name });
  }
  if (opts.ctrl) pi.makeControlRoom();

  const all = opts.ctrl ? [...pi.rooms, pi.control] : [...pi.rooms];
  for (const room of all) {
    await room.connect();
    console.log(`fake-pi: room up   ${room.roomId}  ${room.meta.role === CONTROL_ROOM_ROLE ? "(control)" : room.meta.name}`);
  }

  console.log("\n── sessions ─────────────────────────────────────────────");
  pi.rooms.forEach((r, i) => {
    console.log(`  [${i}] ${r.meta.name}\n      session_id=${r.meta.session_id}\n      workspace=${r.meta.workspace_path}`);
  });

  const payload = pi.qrPayload(pi.rooms[0]);
  console.log("\n── PAIRING PAYLOAD (paste into the app's \"Paste pairing code\" sheet) ──\n");
  console.log(payload);
  console.log(`\n(valid ${Math.round(opts.ttlMs / 1000)}s — type \`qr\` for a fresh one)\n`);

  const rl = createInterface({ input: process.stdin });
  rl.on("line", (line) => {
    const [cmd, ...rest] = line.trim().split(/\s+/);
    const room = (n) => pi.rooms[Number(n ?? 0)];
    switch (cmd) {
      case "": return;
      case "list":
        return pi.rooms.forEach((r, i) => console.log(
          `[${i}] ${r.meta.name}  room_id=${r.roomId}  name_rev=${r.meta.name_rev}  working=${r.meta.working}`,
        ));
      case "qr": {
        const r = room(rest[0]);
        if (!r) return console.log("no such session");
        return console.log(pi.qrPayload(r));
      }
      case "rename": {
        const r = room(rest[0]);
        if (!r) return console.log("no such session");
        const name = rest.slice(1).join(" ");
        if (!name) return console.log("usage: rename <n> <name>");
        return console.log(`renamed to "${name}" (name_rev=${r.publishName(name)})`);
      }
      case "working": {
        const r = room(rest[0]);
        if (!r) return console.log("no such session");
        return r.setWorking(rest[1] === "on");
      }
      case "say": {
        const r = room(rest[0]);
        if (!r) return console.log("no such session");
        const text = rest.slice(1).join(" ");
        const id = randomUUID();
        for (const peer of pi.pairedPeers) {
          r.send(peer, { type: "agent_message", in_reply_to: id, text });
        }
        r.history.push({ ts: Date.now(), type: "agent_message", in_reply_to: id, text });
        return;
      }
      case "stop": {
        const r = room(rest[0]);
        if (!r) return console.log("no such session");
        r.ws?.close();
        return console.log(`stopped ${r.meta.name} — the relay will emit room_ended, and any App→Pi frame for ${r.roomId} now answers transport_error: offline`);
      }
      case "start": {
        const r = room(rest[0]);
        if (!r) return console.log("no such session");
        if (r.ready) return console.log("already up");
        return void r.connect().then(
          () => console.log(`restarted ${r.meta.name} on the same session id ${r.roomId}`),
          (e) => console.log(`restart failed: ${e.message}`),
        );
      }
      case "quit": case "exit":
        return process.exit(0);
      default:
        console.log("commands: list | qr [n] | rename <n> <name> | working <n> on|off | say <n> <text> | stop <n> | start <n> | quit");
    }
  });
}

main().catch((e) => {
  console.error("fake-pi: fatal:", e);
  process.exit(1);
});
