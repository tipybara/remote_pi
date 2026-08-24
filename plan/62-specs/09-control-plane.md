# 09 — Machine control plane (`ctrl` room), plan 61 Phase 3

**Spec status:** implementation-ready for a native iOS client.
**Protocol baseline:** post plan 61 (Phases 0–4 landed 2026-08-24).
**Ground truth:** `pi-extension/src/` (Node/TS), `relay/src/` (Rust),
`app/lib/` (Flutter). Where they disagree, this doc says so and picks a winner.

Everything below is grounded in code with `file:line` references. Nothing here
asks you to change any of the three reference implementations.

---

## 0. What this plane is for

Before plan 61 Phase 3, session discovery ran **Pi → `room_announced` → app**.
No child process meant no relay room, and no room meant the phone had nobody to
ask. *You needed a Pi to create a Pi*
(`pi-extension/src/daemon/gateway.ts:30-37`,
`app/lib/data/control/machine_control_repository.dart:12-22`).

Phase 3 gives every machine a **resident gateway**: the supervisor
(`pi-supervisord`) holds one permanent relay room, reserved id `"ctrl"`, using
**the machine's existing Pi-key** — never a second identity
(`pi-extension/src/daemon/gateway.ts:41-45`, `PROTOCOL.md:46-49`).

The control plane is an **RPC channel**, not a conversation. It answers six
actions and emits nothing spontaneously.

---

## 1. Layering — how a control frame reaches the machine

A control frame is an ordinary App↔Pi outer envelope addressed at room `ctrl`.
Nothing about the transport is special.

```jsonc
// client → relay (one JSON text frame on the authenticated WebSocket)
{ "peer": "<machine Pi-key, standard base64 WITH padding>",
  "room": "ctrl",
  "ct":   "<standard base64 of the UTF-8 inner JSON>" }
```

- The relay never parses `ct` (`relay/src/protocol/outer.rs:57-74`). It only
  measures `ct.len() * 3 / 4` against `RELAY_MAX_CT_MIB` (default 4 MiB,
  `relay/src/protocol/outer.rs:29`).
- `ct` is **base64 of plaintext JSON, not ciphertext** (`PROTOCOL.md:162-163`,
  `pi-extension/src/transport/peer_channel.ts:12-14`).
- `room` is optional on the wire and defaults to `"main"`
  (`relay/src/protocol/outer.rs:15-17`). For control frames it must be present
  and exactly `"ctrl"`.
- Before delivering, the relay **rewrites** `peer` to the authenticated sender
  and `room` to the *sender's registered room* (`relay/src/handlers/peer.rs:390-396`).
  So the gateway's replies arrive at the client with `"room": "ctrl"` and
  `"peer": "<machine Pi-key>"`.

Routing is an **exact `(peer_id, room_id)` map lookup**
(`relay/src/peers/registry.rs:246-257`). A miss is answered with a
`transport_error` control frame to the sender
(`relay/src/handlers/peer.rs:429-436`) — see §9 Traps T1 and T2, which are the
two places this bites.

---

## 2. The reserved room

| Constant | Value | Source |
|---|---|---|
| `CONTROL_ROOM_ID` | `"ctrl"` | `pi-extension/src/protocol/control_wire.ts:19` |
| `CONTROL_ROOM_ROLE` | `"control"` | `pi-extension/src/protocol/control_wire.ts:22` |
| Flutter mirror | `kControlRoomId = 'ctrl'` | `app/lib/protocol/protocol.dart:933` |

`"ctrl"` is reserved and collision-free by construction: chat rooms are either
12-char base64url digests (legacy `roomIdFor(cwd,name)`) or UUIDs
(`session_id`), and `"ctrl"` is neither
(`pi-extension/src/protocol/control_wire.ts:16-18`).

### The gateway's `hello`

`Gateway.start()` connects with (`pi-extension/src/daemon/gateway.ts:113-123`):

```jsonc
{ "type": "hello",
  "pubkey": "<Pi-key, base64>",
  "room_id": "ctrl",
  "room_meta": {
    "role": "control",
    "name": "machine control",
    "cwd": "<realpath(process.cwd()) of the supervisor>",
    "workspace_path": "<same value>"
  } }
```

Note what is **absent**: no `session_id`, no `name_rev`, no `model`, no
`thinking`, no `working`. The relay fills `working: false` and `started_at`
itself (`relay/src/handlers/peer.rs:109-112`, `:139-142`).

### What the client sees on discovery

After `{"type":"subscribe_rooms","peers":[...]}`
(`app/lib/protocol/protocol.dart:172-175`), the relay pushes `room_announced`
for the first connection at each room and a `rooms` snapshot on
`rooms_check`/subscribe. Fields absent in `RoomMeta` are **omitted**, not null
(`#[serde(skip_serializing_if = "Option::is_none")]`, `relay/src/rooms.rs:8-62`):

```jsonc
{ "type": "room_announced",
  "peer": "<machine Pi-key, standard base64>",
  "room_id": "ctrl",
  "role": "control",
  "name": "machine control",
  "cwd": "/Users/x",
  "workspace_path": "/Users/x",
  "working": false,
  "started_at": 1780000000000 }
```

### Why the client must never render it as a chat

It is a control plane, not a conversation: it only ever emits `action_ok` /
`action_error` for RPCs. Rendering it as a session tile offers the user a chat
that answers nothing — the Flutter client filters it out of Home at the last
possible moment (`app/lib/ui/home/states/home_state.dart:265-271`,
predicate `RoomInfo.isControlRoom => role == 'control'`,
`app/lib/protocol/protocol.dart:256-258`).

**Rule for iOS.** Cache the `ctrl` room like any other (you need to know whether
the machine's control plane is up), but exclude it from:

- the session list / any chat surface,
- session counts and "device has N sessions" badges,
- message storage (never create a message box for `ctrl`),
- selection restore (never let `ctrl` become the selected session),
- "adopt the first announced room as the active room" heuristics — the Flutter
  client has exactly such a heuristic (`_maybeAdoptLegacyRoom`,
  `app/lib/data/transport/connection_manager.dart:720-726`) and it is **not**
  role-guarded. Do not copy that.

Filter predicate to implement: `role == "control" || roomId == "ctrl"`. Belt and
braces — a pre-Phase-3 relay that forwards the Pi's `room_meta` verbatim can
nest `role` under `meta`, which is why the Flutter parser reads both the flat
and the nested position (`app/lib/protocol/protocol.dart:64`).

### Liveness

`ctrl` gets `room_announced` / `room_ended` like any room. `room_ended` for
`ctrl` (supervisor stopped, relay restarted) means **the machine can no longer
be asked to create sessions** — the New Session entry point should go
unavailable, not silently fail 45 seconds later.

---

## 3. Authorization — Owner-only

`Gateway.onLine` checks the sender **before parsing the action**
(`pi-extension/src/daemon/gateway.ts:169-179`):

1. `outer.peer` must be a non-empty string and `outer.ct` non-empty, else the
   frame is dropped with no reply (`:165-167`).
2. `this.owners.has(peer)` — a **raw string set membership test** against
   `remote_epk` values read from `peers.json` (`:150-157`).
3. On a miss, the allow-list is re-read once (a device that paired seconds ago
   is legitimate) and re-tested.
4. Still a miss → `log.warn` and **silent drop**. No `action_error`, no
   `pair_error`, nothing. The client sees only a timeout.

Why the raw string compare is safe: the relay canonicalizes the sender id to
**standard base64 with padding** — `peer_id = B64.encode(vk.to_bytes())`
(`relay/src/handlers/peer.rs:80`) — and pairing stores exactly that value
(`addPeer({ remote_epk: appPeerId })`, `pi-extension/src/index.ts:1993-1997`;
the field is documented as "preserved exactly",
`pi-extension/src/pairing/storage.ts:447`). The client's `hello.pubkey` may be
url-safe or unpadded — `decode_ed25519_public_key` accepts both
(`relay/src/identity.rs:14-30`) — because the relay re-encodes it anyway.

The gateway also runs `SelfRevoke` on its own (`gateway.ts:126-138`): a gateway
that does not poll membership keeps its spawn capability after the user revokes
the pairing, which is a backdoor (`PROTOCOL.md:406-411`). Revocation clears the
Owner from `peers.json`, and the next control frame is dropped as unpaired.

**Rule for iOS.** There is no "permission denied" answer on this plane. A
control RPC that times out with the machine visibly online is most likely an
authorization drop (revoked or never paired), not a slow machine. Surface it as
"this Mac no longer accepts commands from this phone — re-pair", not "retry".

---

## 4. Inner frames — the six actions

All six ride inside `ct`. The gateway decodes with
`Buffer.from(ct,"base64").toString("utf8")` then `JSON.parse`
(`gateway.ts:181-186`); a decode failure is a silent drop.

Validation is `parseControlAction`
(`pi-extension/src/protocol/control_wire.ts:81-140`). Its contract:

- non-object frame → `ControlParseError("frame must be an object")`
- non-string `type` → `ControlParseError("type must be a string")`
- **unknown `type` → returns `null` → silently ignored** (forward-compat,
  `:86`, `:206`). You will never learn that a typo'd action name was dropped.
- `id` must be a non-empty string after `trim()` (`str()`, `:62-67`)
- for `create_session` / `session_start` / `session_stop`, `idempotency_key`
  must be a non-empty trimmed string (`MUTATING`, `:33-37`, `:89`)
- every string field is **trimmed** before use

On a `ControlParseError` the gateway replies **only if** the raw inner object
has both a string `id` and a string `type` (`gateway.ts:191-205`); otherwise the
caller waits forever.

### 4.1 `workspace_list` — read-only, no key

```jsonc
// →
{ "type": "workspace_list", "id": "ctl_019ffb64-1c2f-7a01-9f00-3a5e2b6c1d40" }

// ← action_ok
{ "type": "action_ok",
  "in_reply_to": "ctl_019ffb64-1c2f-7a01-9f00-3a5e2b6c1d40",
  "action": "workspace_list",
  "workspaces": [
    { "workspace_id": "a1b2c3d4", "path": "/Users/x/proj", "display_name": "proj" }
  ] }
```

`workspaces` is `listWorkspaces()` (`pi-extension/src/daemon/sessions.ts:128-135`):

| Field | Type | Meaning |
|---|---|---|
| `workspace_id` | string, **8 lowercase hex chars** | `daemonIdForCwd(cwd)` = `sha256(realpath(cwd)).hex[:8]` (`pi-extension/src/daemon/id.ts:27-34`) — derived, never persisted |
| `path` | string | canonical `realpath` of the folder |
| `display_name` | string | label override from `~/.pi/remote/workspaces.json`, else the registry name, else the folder-derived default |

All three are always present in the reply. The Flutter parser nonetheless
defaults `path` and `display_name` to `""`/`path`
(`app/lib/protocol/protocol.dart:1043-1047`) — mirror that leniency.

The list is exactly the machine's **registered daemon folders**. There is no
remote "register this path": a path on the wire plus the daemon's `--approve`
would be user-level RCE (D5/D6; `control_wire.ts:4-9`, `gateway.ts:46-49`).
Empty list is a legitimate answer — the correct UI copy is "run
`remote-pi create <folder>` on that Mac"
(`app/lib/ui/home/widgets/new_session_sheet.dart:211-217`).

**`workspace_id` is machine-local.** Two Macs can and do produce the same 8-hex
id for the same path. Key it as `(machinePiKey, workspaceId)` — never alone.

### 4.2 `session_list` — read-only, no key

```jsonc
// →
{ "type": "session_list", "id": "<rpc>", "workspace_id": "a1b2c3d4" }   // workspace_id optional

// ← action_ok
{ "type": "action_ok", "in_reply_to": "<rpc>", "action": "session_list",
  "sessions": [
    { "session_id": "3f1c…-uuid",
      "workspace_id": "a1b2c3d4",
      "display_name": "proj",
      "mode": "background",
      "desired": "running",
      "created_at": 1780000000000,
      "running": true }
  ] }
```

Entry shape = `SessionEntry` (`pi-extension/src/daemon/sessions.ts:61-76`) plus
`running` spliced in by the gateway (`gateway.ts:231-237`).

- `mode`: `"interactive" | "background"`. Anything else in the file loads as
  `"background"` (`sessions.ts:162`).
- `desired`: `"running" | "stopped"` — the **operator's intent**, persisted, and
  what a supervisor restart honours (`sessions.ts:66-75`,
  `supervisor.ts:627-646`). Anything but the literal `"stopped"` loads as
  `"running"` (`sessions.ts:163`).
- `created_at`: epoch ms, `0` when the persisted value was not a number.
- `running`: **`isWorkspaceRunning(s.workspace_id)` — a per-WORKSPACE fact, not
  per-session** (`gateway.ts:233-234`). Since there is exactly one daemon per
  cwd (D9, `daemon/id.ts:21-25`), every session sharing a workspace reports the
  same `running`. Do not render it as "this session is alive"; the authoritative
  per-session liveness signal is the relay's live-room set for
  `room_id == session_id`.

`workspace_id` absent/empty/whitespace → all sessions
(`control_wire.ts:94-99`). An explicit `null` is treated as absent, not as an
error.

The Flutter client declares `SessionList` (`app/lib/protocol/protocol.dart:948`)
but **never sends it**. It is unexercised by any shipped client — treat this
reply shape as the least battle-tested part of the plane.

### 4.3 `create_session` — mutating, key REQUIRED

```jsonc
// →
{ "type": "create_session",
  "id": "<rpc>",
  "idempotency_key": "019ffb64-2a10-7c33-8e21-9b0f7c2d4a55",
  "workspace_id": "a1b2c3d4",
  "display_name": "backend",     // optional
  "background": true }           // optional, but ONLY the literal true

// ← action_ok (first execution)
{ "type": "action_ok", "in_reply_to": "<rpc>", "action": "create_session",
  "session_id": "8b4f9c2e-...-uuid",
  "workspace_id": "a1b2c3d4",
  "display_name": "backend",
  "path": "/Users/x/proj" }

// ← action_ok (REPLAY of the same idempotency_key — reduced payload!)
{ "type": "action_ok", "in_reply_to": "<rpc2>", "action": "create_session",
  "session_id": "8b4f9c2e-...-uuid",
  "replayed": true }

// ← action_error
{ "type": "action_error", "in_reply_to": "<rpc>", "action": "create_session",
  "error": "unknown workspace: a1b2c3d4" }
```

Field rules (`control_wire.ts:100-119`, `gateway.ts:239-258`,
`sessions.ts:237-259`):

| Field | Required | Absent | Explicit `null` | Notes |
|---|---|---|---|---|
| `id` | yes | parse error (no reply unless raw `id`+`type` are strings) | parse error | trimmed; echoed as `in_reply_to` |
| `idempotency_key` | yes | `action_error "idempotency_key must be a non-empty string"` | same | trimmed |
| `workspace_id` | yes | `action_error "workspace_id must be a non-empty string"` | same | must already be registered |
| `display_name` | no | machine falls back to the workspace label, then to `workspace_id` | **treated as absent** (no error) | empty/whitespace also treated as absent |
| `background` | no | fine — v1 is background-only anyway | **rejected** | any value other than the JSON literal `true` → `ControlParseError("only background sessions can be created remotely")` |

`session_id` is minted by the **machine** with `crypto.randomUUID()` (122 random
bits) *before any process exists*, so the phone has something concrete to wait
on (`sessions.ts:230-259`, `PROTOCOL.md:126-129`). The child adopts it through
the `REMOTE_PI_SESSION_ID` env var (`supervisor.ts:689`), and that injected id
**wins over the SDK's own session id** (`pi-extension/src/index.ts:257-272`) so
`room_id == session_id` holds end to end.

### 4.4 `session_start` / `session_stop` — mutating, key REQUIRED

```jsonc
{ "type": "session_start", "id": "<rpc>",
  "session_id": "8b4f9c2e-…", "idempotency_key": "<uuid>" }

// ← action_ok (first execution)
{ "type": "action_ok", "in_reply_to": "<rpc>", "action": "session_start",
  "session_id": "8b4f9c2e-…", "workspace_id": "a1b2c3d4" }

// ← action_ok (replay) — again reduced
{ "type": "action_ok", "in_reply_to": "<rpc>", "action": "session_start",
  "session_id": "8b4f9c2e-…", "replayed": true }

// ← action_error
{ "type": "action_error", "in_reply_to": "<rpc>", "action": "session_start",
  "error": "unknown session: 8b4f9c2e-…" }
```

Semantics (`gateway.ts:260-279`):

- `session_start`: `setDesiredState(id, "running")` **then** start the daemon
  owning that session's workspace. Already-running is success and does **not**
  spawn a second process (`supervisor.ts:174-185`).
- `session_stop`: persists `desired: "stopped"` **before** stopping, so a
  supervisor restart inside that window does not resurrect the session
  (`gateway.ts:272-277`). Stopping is per-**workspace**: it stops the daemon,
  which takes down every session of that cwd.
- `session_stop` on an already-stopped workspace is a no-op success
  (`supervisor.ts:186-194`).
- Both are refused with `unknown session: …` when the id is not in
  `sessions.json` — including for a perfectly live session the machine never
  catalogued (a daemon started locally by `remote-pi start`, not through this
  plane). §9 T8.

Neither is ever sent by the Flutter client (`SessionStart`/`SessionStop` exist
at `app/lib/protocol/protocol.dart:994-1031` and have no callers).

### 4.5 `session_rename` — mutating in effect, NO key, and NOT the rename you want

```jsonc
{ "type": "session_rename", "id": "<rpc>",
  "session_id": "8b4f9c2e-…", "display_name": "backend", "rev": 1780000000001 }

// ← action_ok
{ "type": "action_ok", "in_reply_to": "<rpc>", "action": "session_rename",
  "session_id": "8b4f9c2e-…", "display_name": "backend" }

// ← action_error
{ "type": "action_error", "in_reply_to": "<rpc>", "action": "session_rename",
  "error": "unknown session: 8b4f9c2e-…" }
```

**There are two different `session_rename` handlers and they behave
differently.**

| | Chat room (`room_id == session_id`) | Control room (`ctrl`) |
|---|---|---|
| Handler | `pi-extension/src/index.ts:4128-4183` | `pi-extension/src/daemon/gateway.ts:281-290` |
| Honours `rev` | **yes** — refuses with `"stale name revision — this session was renamed elsewhere"` when `rev < current name_rev` (`index.ts:4154-4172`) | **no** — `parseControlAction` accepts and returns `rev` (`control_wire.ts:135-136`) and `dispatch` never reads it |
| Validates `session_id` targets this session | yes (`index.ts:4141-4153`) | n/a (looks the id up in the catalogue) |
| Publishes the new name to the relay | yes — `room_meta_update` with a fresh monotonic `name_rev` (`index.ts:_renameAgent`, `_nextNameRev` at `index.ts:276-286`) | **no** — writes `~/.pi/remote/sessions.json` only (`sessions.ts:276-287`) |
| Idempotency key | n/a | **not required** (not in `MUTATING`) |
| `action_ok` payload | none | `{session_id, display_name}` |

**Winner: the chat-room handler.** Rename a session by sending
`session_rename` to that session's own room (`room_id == session_id`) with the
`rev` you last saw, exactly as the Flutter client does
(`app/lib/data/actions/actions_repository.dart:315-330`, addressed with
`room: roomId`). It is the only path that updates `room_meta.name` /
`name_rev` on the relay, which is what every other device sees.

Use the `ctrl` variant only to relabel a **catalogued but not-running** session
(no chat room exists to send to). Expect the two labels to diverge: nothing
syncs `sessions.json` back into `room_meta`, and nothing syncs `room_meta` into
`sessions.json`. §9 T7.

### 4.6 Reply frames — exact shapes

```ts
// pi-extension/src/protocol/control_wire.ts:153-172
{ "type": "action_ok",    "in_reply_to": string, "action": ControlActionName, ...payload }
{ "type": "action_error", "in_reply_to": string, "action": ControlActionName, "error": string }
```

- `action` echoes the request's `type` verbatim.
- The whole `action_ok` object is the payload — there is no `data` wrapper. The
  Flutter client keeps the raw map for exactly this reason
  (`app/lib/protocol/protocol.dart:1640-1650`,
  `ActionOk.data = j`), so `data['session_id']` reads a **top-level** field.
- Correlate strictly by `in_reply_to`. Chat `action_ok`s use the same two frame
  types on the same socket, so request ids must be unique across the whole
  client, not just within the control repository. Flutter mints
  `'ctl_' + uuid7()` (`machine_control_repository.dart:107`).
- `error` is a **human-readable string with no code**. Do not pattern-match it
  for control flow beyond the documented prefixes (`unknown workspace: `,
  `unknown session: `); it also carries arbitrary `Error.message` text from
  spawn failures (`gateway.ts:326-327`).

---

## 5. Idempotency contract

Source: `gateway.ts:294-331` + `sessions.ts:46-47`, `:78-86`, `:199-228`.

1. **Which actions require a key.** `create_session`, `session_start`,
   `session_stop` — the `MUTATING` set (`control_wire.ts:33-37`).
   `workspace_list`, `session_list`, `session_rename` neither require nor
   consult one; sending a key with them is ignored, not an error.
2. **A missing key is refused, never defaulted.** "A default per attempt
   deduplicates nothing" (`control_wire.ts:73-77`, `PROTOCOL.md:263-265`). The
   answer is `action_error` with
   `"idempotency_key must be a non-empty string"`.
3. **Mint once per user INTENT, reuse across every retry.** The Flutter sheet
   mints the key when the sheet *opens* and reuses it for every Create tap and
   every reconnect retry
   (`app/lib/ui/home/widgets/new_session_sheet.dart:46-47`, `:100-105`;
   contract restated at `machine_control_repository.dart:32-35`). Minting per
   attempt gets you a process per attempt.
4. **A replayed key returns the ORIGINAL outcome — including the original
   error.** `lookupIdempotency` hit with `error` set → `action_error` with the
   same text; hit with `session_id` → `action_ok` carrying
   `{session_id, replayed: true}` and **nothing else** (`gateway.ts:308-315`).
   This is deliberate: a permanent failure must not become a spawn loop
   (`gateway.ts:296-301`).
   Corollary: after an `action_error`, retrying **with the same key** can never
   succeed for 24 h. Retrying with a **new** key is a new intent and may spawn.
   Both are correct in different situations; the client must decide which one a
   given user gesture means. Recommended: same key for transport-level retries
   (timeout, offline, reconnect); new key only when the user explicitly asks
   again after seeing the error.
5. **TTL.** `IDEMPOTENCY_TTL_MS = 24 h` (`sessions.ts:47`), pruned on every
   write (`sessions.ts:180-188`). An expired key behaves as never-seen and will
   execute again.
6. **The key namespace is global across action types.** The ledger is a flat
   `Record<key, {session_id?, error?, at}>` (`sessions.ts:88-91`). Reusing one
   key for a `session_stop` after a `session_start` replays the *start's*
   outcome. One key = one intent = one action.
7. **Values that must NEVER be used as a key:** `workspace_id`, `session_id`,
   `display_name`, `path`, the rpc `id`, or any hash of them. A stable key
   pins the outcome for 24 h — e.g. keying `create_session` by `workspace_id`
   makes the second "New session in this folder" silently replay the first
   session's id, and keying `session_start` by `session_id` makes a restart
   after a crash a no-op replay. Use a fresh random UUID per intent.
8. **Keys are trimmed** (`str()`), so `" k "` and `"k"` are the same key.
9. **Recording is not atomic with the work.** `lookupIdempotency` → `work()` →
   `recordIdempotency` are three separate file reads/writes with no lock
   (`gateway.ts:302-330`). Two in-flight requests with the same key can both
   miss the ledger and both execute; a crash between spawn and record loses the
   record entirely. Do not pipeline two attempts of the same intent — retry only
   after the previous attempt has resolved (reply, timeout, or socket loss).

---

## 6. `action_ok` means "spawn requested", not "the room is up"

This is the single most important behavioural rule on this plane
(`PROTOCOL.md:267-270`, plan 61 D8, `new_session_sheet.dart:23-24`,
`home_viewmodel.dart:369-373`).

`create_session` returns as soon as the catalogue entry exists and
`startWorkspace` has been *called*. The relay room comes into existence later —
when the forked `pi` boots its extension, connects to the relay and sends
`hello` with `room_id = REMOTE_PI_SESSION_ID`.

### Required client sequence

```
1. key = UUID()                                   // once per user intent
2. send create_session{id, key, workspace_id, display_name?, background:true} → ctrl
3. await action_ok
     → sessionId = ok["session_id"]               // ALWAYS from the machine
4. if isRoomLive(machinePiKey, sessionId) → done  // already announced (race)
5. else await room_announced / rooms snapshot where
        peer == machinePiKey && room_id == sessionId
        (budget ≈ 45 s)
6. timeout → "created, not online yet" — NOT "failed". Never delete the session.
```

Flutter's implementation: `waitForSessionOnline`
(`home_viewmodel.dart:394-427`) checks `isRoomLive` first, then listens to the
rooms stream until the id appears; the sheet shows
"Waiting for the session to come online…" and on timeout says
"Session created, but it has not come online yet"
(`new_session_sheet.dart:117-133`).

### Timeouts

`MachineControlRepository` uses **45 s** for the RPC itself, deliberately longer
than the 15 s chat-action default, because the supervisor must fork `pi`, which
loads settings and an extension before it answers
(`machine_control_repository.dart:56-62`). Then a further 45 s budget for the
room. Do not use one shared 15 s constant.

### The client must never precompute a room id

Pre-Phase-1 the id was `sha256(realpath(cwd))[:12]` or
`sha256(realpath(cwd) + NUL + name)[:12]` (`PROTOCOL.md:61-64`). Any client that
still derives it will (a) compute a value the post-61 Pi never announces and
(b) re-key on rename. `session_id` comes from the machine only: from
`action_ok.session_id`, from `session_list`, or from `room_meta.session_id`. The
Flutter contract states this twice
(`machine_control_repository.dart:38-41`, `home_viewmodel.dart:368-371`).

The **presence** of `room_meta.session_id` — not its value — is the signal that
a room is session-keyed rather than legacy (`PROTOCOL.md:98-100`,
`app/lib/protocol/protocol.dart:230-236`). The `ctrl` room has no `session_id`
and never will; that is fine, it is not a session.

---

## 7. Where the three implementations disagree

**D1 — reply routing: gateway hardcodes `room:"ctrl"`, relay routes by exact
`(peer, room)`, the app registers only `"main"`. The relay wins; the gateway is
wrong.**

- Gateway replies with `relay.send(JSON.stringify({ peer, room: CONTROL_ROOM_ID, ct }))`
  (`gateway.ts:212-221`) → destination key `(ownerKey, "ctrl")`.
- The relay forwards on an exact key lookup and does not fall back
  (`relay/src/peers/registry.rs:253-257`).
- The Flutter app registers exactly one room per connection and always sends
  `"room_id": "main"` in its `hello`
  (`app/lib/data/transport/ws_transport.dart:160-167`).
- The chat Pi, by contrast, **omits** `room` on its outbound envelopes
  (`pi-extension/src/transport/peer_channel.ts:63-69`), so it lands on the
  default `"main"` (`relay/src/protocol/outer.rs:15-17`) — which is why chat
  replies arrive and control replies, on this reading, do not.
- No test covers it: `gateway.test.ts` stubs the relay entirely
  (`pi-extension/src/daemon/gateway.test.ts:33-67`), and `relay/tests/` has no
  control-room case. Plan 61 lists real-device verification as still open
  (`plan/61-stable-session-identity.md:262-267`).

  See §9 T1 for what an iOS client should do about it.

**D2 — `session_rename` has two incompatible implementations** (§4.5). Winner:
the chat-room handler in `index.ts`; the `ctrl` variant is catalogue-only and
silently ignores `rev`.

**D3 — `workspace_id` is not a UUID.** Plan 61's model table says
"`workspace_id = UUID registered on that machine`"
(`plan/61-stable-session-identity.md:42`); the implementation uses the derived
8-hex daemon id, with the reasoning recorded in
`pi-extension/src/daemon/sessions.ts:21-31` and the deviation acknowledged at
`plan/61-stable-session-identity.md:233-237`. **The code wins**: treat
`workspace_id` as an opaque, machine-local, 8-char lowercase hex string.

**D4 — Flutter declares control messages it never sends.** `SessionList`,
`SessionStart`, `SessionStop` (`app/lib/protocol/protocol.dart:948-1030`) have
no call sites. The pi-extension implements all three. iOS may use them; just
know no shipped client has.

**D5 — `RoomInfo.fromJson` requires `started_at`** (`protocol.dart:280` and `:49`,
non-null cast) while the announce parser also hard-casts `peer` and `room_id`.
The relay always sends all three (`relay/src/rooms.rs:61`), so this is safe
against the reference relay only. Prefer optional decoding on iOS.

---

## 8. Suggested Swift shapes

Do not derive `CodingKeys` from a global snake_case strategy and then fight the
exceptions — the wire mixes `in_reply_to` with payload keys. Explicit
`CodingKeys` per type is clearer.

```swift
enum ControlAction: String, Codable {
    case workspaceList  = "workspace_list"
    case sessionList    = "session_list"
    case createSession  = "create_session"
    case sessionStart   = "session_start"
    case sessionStop    = "session_stop"
    case sessionRename  = "session_rename"

    var requiresIdempotencyKey: Bool {
        switch self {
        case .createSession, .sessionStart, .sessionStop: return true
        default: return false
        }
    }
}

enum ControlRoom {
    static let id   = "ctrl"       // reserved; never a session id
    static let role = "control"
}

/// One user intent. The key lives here, not at the call site, so a retry
/// cannot accidentally mint a new one.
struct CreateSessionIntent {
    let machine: PiKey                 // standard-base64 Pi-key
    let workspaceID: String            // 8 hex chars, machine-local
    let displayName: String?
    let idempotencyKey = UUID().uuidString   // minted ONCE, never derived
}

struct RemoteWorkspace: Decodable, Hashable {
    let workspaceID: String
    let path: String
    let displayName: String
    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id", path, displayName = "display_name"
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        workspaceID = try c.decode(String.self, forKey: .workspaceID)
        path        = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? path
    }
}

struct RemoteSession: Decodable {
    let sessionID: String
    let workspaceID: String
    let displayName: String
    let mode: Mode            // .interactive / .background, default .background
    let desired: Desired      // .running / .stopped, default .running
    let createdAt: Int        // epoch ms, default 0
    let running: Bool         // per-WORKSPACE, not per-session
    enum Mode: String, Decodable { case interactive, background }
    enum Desired: String, Decodable { case running, stopped }
}

/// action_ok has no payload envelope: everything is top level.
struct ActionOK {
    let inReplyTo: String
    let action: String                    // keep the RAW string; unknown != error
    let raw: [String: Any]                // read session_id / workspaces / sessions here
    var replayed: Bool { raw["replayed"] as? Bool ?? false }
}

enum ControlReply { case ok(ActionOK), error(inReplyTo: String, action: String, message: String) }

/// The two-step create. Step 2 is not optional.
enum CreateOutcome {
    case online(sessionID: String)              // action_ok + room_announced
    case acceptedNotYetOnline(sessionID: String) // action_ok, room wait timed out
    case failed(message: String)                 // action_error
}
```

Decoding notes:

- `mode`, `desired` — decode leniently: anything unrecognised maps to
  `.background` / `.running`, matching the machine's own loader
  (`sessions.ts:162-163`).
- Keep `action` as a raw `String` alongside the enum. The Flutter client
  deliberately preserves the raw wire value so a future action is not dropped
  (`app/lib/protocol/protocol.dart:1638-1640`).
- `ActionOK.raw` as `[String: Any]` (or a `JSONValue` enum) beats one struct per
  action: new control actions add fields without a protocol change
  (`protocol.dart:1644-1650`).

---

## 9. Traps

**T1 — The gateway addresses its reply to room `"ctrl"`, but the relay delivers
only to an exact `(peer, room)` registration.**
If your client registers `hello.room_id = "main"` (what Flutter does,
`ws_transport.dart:166`), the key `(ownerKey, "ctrl")` does not exist
(`registry.rs:253-257`) and **every control reply is dropped**, with the relay
answering the *gateway* a `transport_error` it ignores. Symptom: every control
RPC times out at 45 s while the machine looks perfectly online and its
`workspace_list` clearly ran.
Client-side mitigations, in order of preference:
1. Hold a **second authenticated WebSocket whose `hello.room_id` is `"ctrl"`**
   and use it for the control plane. Registration is per-connection
   (`registry.rs:82-101`); the Owner key may hold N connections at N keys. The
   relay rewrites the inbound envelope's `room` to the *sender's* room, so
   frames still arrive tagged `"room": "ctrl"`.
2. Or accept replies on whichever socket delivers them and correlate purely by
   `in_reply_to`, so a machine that is later fixed to omit `room` (landing on
   `"main"`) also works.
Implement 1 **and** 2: they compose, and 2 is what makes you forward-compatible
with the fix. Never key your pending-RPC table by room.

**T2 — Base64 variants, in three separate places.**
- The outer `peer` field must be **standard base64 with padding** to match the
  registry key, because the relay canonicalizes ids with
  `B64.encode(vk.to_bytes())` (`relay/src/handlers/peer.rs:80`). A base64url
  Pi-key from a QR payload (`pi-extension/src/pairing/qr.ts:81`) will miss and
  come back as `transport_error: offline`. The Flutter fix is
  `toStandardB64` (`app/lib/data/transport/epk_encoding.dart:24-36`) — read the
  file header before touching this; the bug has recurred at least three times.
- `hello.pubkey` may be either variant (`relay/src/identity.rs:14-30`) — but
  send the standard padded form anyway so logs and the Owner allow-list line up.
- `ct` must be **standard** base64 both ways. Node's `Buffer.from(ct,"base64")`
  is lenient and also accepts url-safe input, so a url-safe bug will work
  against the Pi and then break against a stricter peer. Swift's
  `Data(base64Encoded:)` is **strict**: it rejects `-`/`_` and rejects missing
  padding. Normalize on the way in the way the Flutter client does
  (`ws_transport.dart:302-310`: pad to a multiple of 4, try standard, then
  url-safe) and always emit standard-with-padding on the way out.

**T3 — Idempotency: a key that is a value, not a nonce, is a 24 h landmine.**
Never key by `workspace_id` / `session_id` / `display_name` (§5.7). And never
re-mint on retry (§5.3). The two failure modes are opposite and both silent: a
reused-value key silently replays a stale outcome; a re-minted key silently
spawns a second process. Store the key in the *intent* object that survives the
retry loop, exactly as the Flutter sheet stores it in the sheet's state
(`new_session_sheet.dart:46-47`).

**T4 — `action_ok` on a replay is a *smaller* object.**
First execution returns `session_id, workspace_id, display_name, path`; a replay
returns only `session_id` plus `replayed: true` (`gateway.ts:308-315`). A
decoder that requires `workspace_id` or `path` will throw on exactly the retry
path it exists to support. Make everything except `session_id` optional.

**T5 — A second `create_session` in a workspace that is already running returns
a session id whose room will never appear.**
`startWorkspace` early-returns when the daemon for that cwd is already up
(`supervisor.ts:177-183`), so no new process is spawned and the live child keeps
its original `REMOTE_PI_SESSION_ID`. The catalogue nevertheless holds a fresh
entry, `action_ok` hands you its id, and step 5 of §6 waits forever. Worse, that
early return also does `this.sessionIds.set(workspaceId, sessionId)`
(`supervisor.ts:180`), so after the next restart the child adopts the **new** id
and the original room id disappears — orphaning the existing conversation, the
very failure plan 61 exists to prevent (same-cwd multi-session is explicitly out
of scope, D9). Client rule: before offering "New session" in a workspace, check
whether any live room already maps to that `workspace_path`; if so, offer "open
the existing session" instead. If you do create anyway, treat the room-wait
timeout as expected and do not retry with a new key.

**T6 — Silent drops. Four of them, all indistinguishable from a slow machine.**
| Cause | Code |
|---|---|
| sender not in `peers.json` (unpaired / revoked) | `gateway.ts:171-179` |
| `ct` not valid base64/JSON | `gateway.ts:181-186` |
| unknown `type` (typo, newer action) | `control_wire.ts:86`, `gateway.ts:206` |
| parse error where the raw frame's `id` or `type` is not a string | `gateway.ts:191-205` |
Always send a non-empty string `id` and a `type` from the known set, or you can
lose even the error. And note the relay's `transport_error` for room `ctrl`
means the gateway is *down*, which the Flutter control repository does **not**
listen for — it hangs the whole 45 s
(`machine_control_repository.dart:67-79` subscribes to status and messages only,
while the signal is available at `connection_manager.dart:247-249`). On iOS,
fail pending control RPCs immediately on
`transport_error{peer: machine, room_id: "ctrl"}`.

**T7 — Two labels for one session, no reconciliation.**
`sessions.json.display_name` (set by `ctrl` `session_rename`) and
`room_meta.name` + `name_rev` (set by chat-room `session_rename`) are separate
stores that never sync (§4.5). Render the live room's `name` when the room is
up, the catalogue's `display_name` when it is not, and expect them to differ.
Also: `name_rev` is minted from the wall clock (`index.ts:276-286`) and the
relay applies a name patch only when the revision is **strictly greater**
(`relay/src/peers/registry.rs:295-310`); a rejected patch still re-broadcasts
the winning name, which is what resyncs a stale device
(`PROTOCOL.md:215-219`). Never send a `rev` you did not read from the wire.

**T8 — `unknown session` is not the same as "no such session".**
`session_start` / `session_stop` / `ctrl`-`session_rename` resolve ids **only**
against `~/.pi/remote/sessions.json` (`gateway.ts:262`, `:272`, `:282`). A
session that exists and is happily chatting, but was started locally
(`remote-pi start`) rather than through this plane, has no catalogue entry and
is unstoppable from the phone. Do not conclude the session is gone; the
authoritative existence signal is the relay's room set.

**T9 — Trimming changes what comes back.**
`str()` trims `id`, `workspace_id`, `session_id`, `display_name` and
`idempotency_key` (`control_wire.ts:62-67`). `in_reply_to` echoes the **trimmed**
`id` on the normal path (`gateway.ts:208-209` uses `action.id`) but the **raw**
`id` on the parse-error path (`gateway.ts:192`, `:199`). If your ids can contain
whitespace, correlation will mysteriously fail on exactly one branch. Use
opaque, whitespace-free ids (`ctl_<uuid>`).

**T10 — Do not let the `ctrl` room leak into session state.**
It has no `session_id`, so any code path that assumes "announced room ⇒ session"
will create a phantom session, a phantom message box, or a phantom selection.
Filter on `role == "control" || roomId == "ctrl"` at the boundary where rooms
become sessions — not in each UI widget (§2).

**T11 — `background: false` is an error, not a preference.**
`{"background": false}` and `{"background": 0}` and `{"background": "true"}` all
produce `action_error "only background sessions can be created remotely"`
(`control_wire.ts:110-117`). Send `true` or omit the field.

**T12 — `started_at` changes on every reconnect.**
It is stamped by the relay at registration (`relay/src/handlers/peer.rs:139-142`,
`PROTOCOL.md:221-223`). Never use it as an id, a sort key, or a
"session created at" timestamp — `created_at` from `session_list` is the real
creation time.

---

## 10. What I could not determine from the code

1. **Whether control replies actually reach the Flutter app today.** Static
   reading says no (§7 D1) — gateway `room:"ctrl"` vs an app registered at
   `"main"` — but nothing exercises it: `gateway.test.ts` stubs the relay, the
   relay integration tests have no control-room case, and plan 61 lists
   real-device verification as still open
   (`plan/61-stable-session-identity.md:262-267`). Verify against a live relay
   before choosing between the two mitigations in T1.
2. **Whether a second WebSocket registered at `(ownerKey, "ctrl")` has side
   effects.** It will emit a `room_announced` for the Owner peer to anyone
   subscribed to that peer's rooms (`registry.rs:103-118`); no shipped component
   subscribes to the Owner's rooms, but I did not test it.
3. **Behaviour of `session_start` when the catalogue entry's workspace was
   removed from `daemons.json`.** `findSession` succeeds, then
   `startWorkspace` throws `unknown workspace: …` (`supervisor.ts:175-176`),
   which is recorded as the idempotency outcome — so the key is burned for 24 h
   on a condition the user can fix in seconds. Not verified end to end.
4. **Concurrency semantics of the JSON stores** under two supervisors or a
   supervisor plus a CLI writing `sessions.json` — the writes are plain
   `writeFileSync` with no lock (`sessions.ts:107-110`).
5. **Whether any relay in deployment predates `role` in `RoomMeta`.** The
   Flutter parser reads `role` both flat and nested (`protocol.dart:64`),
   implying such a relay exists or existed; I could not confirm which versions.
