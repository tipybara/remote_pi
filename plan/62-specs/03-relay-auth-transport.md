# 62-03 — Relay connection lifecycle + auth (implementation spec)

**Audience:** the native iOS client that replaces `app/lib/**`.
**Ground truth:** `relay/src/**` (Rust), `pi-extension/src/**` (Node/TS),
`app/lib/**` (Dart). This document describes the **post-plan-61** protocol only.
Every claim carries a `file:line`.

Scope: WebSocket handshake (hello / challenge / auth), failure modes, the
client-side connection lifecycle (`ConnectionManager`), inbound demux, room
targeting, and what happens to cached live-room state on disconnect.

Out of scope (other specs): inner App↔Pi message catalogue, pairing
(`pair_request` / `pair_ok`), `mesh_versions` HTTP, machine-control RPC bodies.

---

## 0. Vocabulary used below

| Term | Meaning | Authority |
|---|---|---|
| `peer_id` / `epk` | Ed25519 public key, 32 bytes, **standard Base64 with padding** as the relay stores it | `relay/src/handlers/peer.rs:80` |
| `room_id` | Transport sub-channel of a peer. Post-plan-61 a chat room's id **is** the Pi `session_id`; the supervisor's is the literal `"ctrl"` | `PROTOCOL.md:29`, `pi-extension/src/protocol/control_wire.ts:19` |
| Registry key | `(peer_id, room_id)` — a `HashMap` key over **raw strings** | `relay/src/peers/registry.rs:15` |
| Outer envelope | `{peer, room, ct}` — the relay never parses `ct` | `relay/src/protocol/outer.rs:12-19` |
| Control frame | Any JSON with a top-level `"type"`; consumed/produced by the relay itself, never routed to a peer | `relay/src/handlers/peer.rs:211` |

**Transport endpoint.** The WebSocket is the relay's **root path**:
`GET /` upgrades (`relay/src/lib.rs:59`). `/health` is a plain 200 (`:60`).
There is no subprotocol, no query string, no HTTP auth header — all admission
is the in-band challenge-response below.

**URL scheme.** The client stores the relay as `https://…` and converts at the
socket boundary: `https→wss`, `http→ws`, `ws(s)` passes through
(`app/lib/data/transport/relay_config.dart:52-56`). Default relay
`https://relay-rp1.jacobmoura.work` (`:25`).

---

## 1. The handshake

Three JSON text frames. Every frame is **one WebSocket Text message**
containing exactly one JSON object. The relay reads them as JSONL lines but
never depends on a trailing newline (`relay/src/auth/challenge.rs:69` comment).

```
client                                    relay
  │  1. {"type":"hello", …}  ───────────────►     (must arrive ≤ 5000 ms)
  │                          ◄─────────────── 2. {"type":"challenge","nonce":…}
  │  3. {"type":"auth","sig":…}  ──────────►     (verify; no ack on success)
  │                                              register(peer_id, room_meta)
  ▼  ═══════════ routing loop, both directions ══════════
```

### 1.1 `hello` (client → relay)

```jsonc
{
  "type":    "hello",
  "pubkey":  "iCyFyu+3H0y9dQ0y7c0k7Yc0m9hK1p0oQ7q0mQ9Kx1o=",  // REQUIRED
  "room_id": "019ffb64-6f7a-7c31-9b2e-4f3a2b1c0d9e",           // optional, default "main"
  "room_meta": { … }                                            // optional, Pi-side only
}
```

* **`type`** and **`pubkey`** are the only fields the auth parser reads
  (`relay/src/auth/challenge.rs:17-20`, `:55-66`). Anything else in the object
  is ignored **at auth time** and re-parsed later (§1.5) — meaning **`room_id`
  and `room_meta` are NOT covered by the signature.**
* **`pubkey`** must decode to exactly 32 bytes. The decoder is lenient
  (`relay/src/identity.rs:14-30`): standard or URL-safe alphabet, padded or
  unpadded — but it **rejects a string that mixes `+`/`/` with `-`/`_`**
  (`:15-19`). See Trap T1.
* **`room_id`** absent ⇒ the relay uses `"main"`
  (`relay/src/handlers/peer.rs:87-91`). The Dart app always sends the literal
  `"main"` (`app/lib/data/transport/ws_transport.dart:163-167`); a Pi sends its
  session id; the supervisor gateway sends `"ctrl"`
  (`pi-extension/src/daemon/gateway.ts:113-125`).
* **`room_meta`** is Pi-side only. The phone client **must not send it** — the
  Dart client sends none (`ws_transport.dart:163-167`), and publishing meta from
  the phone would make the phone's `main` room show up as a session tile on
  other devices.

#### `room_meta` fields the relay actually reads

Only these keys are extracted (`relay/src/handlers/peer.rs:92-139`); anything
else in the object is silently discarded and will **not** be re-broadcast.

| Key | Type | Absent ⇒ | Line |
|---|---|---|---|
| `name` | string | `null` | `:93-96` |
| `cwd` | string | `null` | `:97-100` |
| `model` | string | `null` | `:101-104` |
| `thinking` | string | `null` | `:105-108` |
| `working` | bool | **`false`** (not null) | `:109-112` |
| `session_id` | string | `null` | `:119-122` |
| `workspace_path` | string | **falls back to `cwd`** | `:123-130` |
| `name_rev` | i64 | `null` | `:131-133` |
| `role` | string | `null` | `:136-139` |

`started_at` is **minted by the relay** at register time
(`:140-143`) — epoch ms. It changes on every reconnect and is never an identity
or ordering key (`PROTOCOL.md:221-222`).

Plan-61 note: `session_id`'s **presence**, not its value, is the signal that the
room id is stable (`PROTOCOL.md:98-100`, `relay/src/rooms.rs:10-17`). The
pi-extension only sets it when `roomId === piSessionId`
(`pi-extension/src/index.ts:2886-2887`). The supervisor gateway sets **no**
`session_id` at all (`daemon/gateway.ts:114-125`) — the `ctrl` room is
identified by `role`, not by a session.

### 1.2 `challenge` (relay → client)

```jsonc
{ "type": "challenge", "nonce": "3rJ2…44 chars…=" }
```

* 32 cryptographically-random bytes (`relay/src/auth/challenge.rs:46-51`).
* Encoded with the **STANDARD, padded** engine (`:4` imports
  `general_purpose::STANDARD`; `:49`). 32 bytes ⇒ 44 chars ending in one `=`.
* No other server frame precedes it. A `{"type":"error", …}` is **never**
  emitted by this relay — see Trap T7.

### 1.3 `auth` (client → relay)

```jsonc
{ "type": "auth", "sig": "0i5v…88 chars…=" }
```

**The signed bytes are the 32 raw nonce bytes and nothing else.**

```
sig = Ed25519_sign(sk, base64_decode(challenge.nonce))
```

Verified at `relay/src/auth/challenge.rs:76-89`: `B64.decode(&sig_b64)` →
`try_into::<[u8;64]>()` → `vk.verify(nonce, &sig)` where `nonce: &[u8;32]` is
the raw array. There is:

* **no** domain-separation prefix or context string,
* **no** hashing of the nonce before signing (plain Ed25519 over the 32 bytes),
* **no** inclusion of `pubkey`, `room_id`, timestamp, or relay URL,
* **no** re-encoding — you do **not** sign the base64 *string*.

Both reference clients do exactly this:
`app/lib/data/transport/ws_transport.dart:174-181` (`_b64Decode(nonce)` then
`Ed25519().sign(nonce, …)`), `pi-extension/src/transport/relay_client.ts:264-269`
(`Buffer.from(nonce,"base64")` then `ed25519Sign`).

**`sig` must be STANDARD Base64.** `verify_auth` decodes with the `STANDARD`
engine only (`challenge.rs:4`, `:82`) — unlike `pubkey`, there is **no URL-safe
fallback and no unpadded fallback** here. See Trap T2.

### 1.4 Success has no acknowledgement

The relay sends nothing on success — it registers the connection and enters the
routing loop (`relay/src/handlers/peer.rs:74-186`). The pi-extension documents
this explicitly and resolves `connect()` right after writing `auth`
(`relay_client.ts:272-273`). The Dart client sets `authDone = true` immediately
after `sink.add` (`ws_transport.dart:182`).

**Consequence for Swift:** "connected" is an optimistic state. The first
evidence auth actually succeeded is either an inbound frame or the absence of a
close within a beat. Treat a close arriving within ~1 s of sending `auth` as an
auth failure, not as a network blip, or the backoff ladder will spin.

### 1.5 What the relay does after `auth` verifies

1. `peer_id = STANDARD_base64(vk.to_bytes())` — **always standard, always
   padded**, regardless of how `pubkey` was spelled in the hello
   (`peer.rs:80`).
2. Re-parses `hello_text` as generic JSON to pull `room_id` + `room_meta`
   (`peer.rs:84-157`). A malformed hello body at this point degrades to
   `Value::Null` (`:86` `unwrap_or`) ⇒ room `"main"`, all meta `None`.
3. `registry.register(peer_id, room_meta, tx)` (`peer.rs:170`), which may emit
   `room_announced` (first conn at this `(peer, room)`) and `peer_online`
   (peer went 0 → N conns) to subscribers
   (`relay/src/peers/registry.rs:106-136`).
4. Starts a 25 s WS-Ping heartbeat, first tick at +25 s
   (`peer.rs:181-184`, `:456-460`).

### 1.6 Failure modes — exhaustive

| # | Condition | Relay behaviour | Wire evidence to the client |
|---|---|---|---|
| F1 | No frame within 5000 ms of upgrade | `return` — socket dropped | close, no frame (`peer.rs:39-48`, `challenge.rs:12`) |
| F2 | First frame is Binary / Ping / Close | same as F1 (the match only accepts `Message::Text`) | close, no frame (`peer.rs:43-47`) |
| F3 | First frame is not valid JSON, or not `type:"hello"` | `warn` + `return` | close, no frame (`peer.rs:50-55`) |
| F4 | `pubkey` mixes `+/` and `-_`, is not base64, or ≠ 32 bytes | `AuthError::InvalidPubkey` → `return` | close, no frame (`identity.rs:14-30`) |
| F5 | Second client frame is not Text | `return` | close, no frame (`peer.rs:69-72`) |
| F6 | Second frame is not `type:"auth"` | `AuthError::UnexpectedMsg` | **`Message::Close(None)`** then drop (`peer.rs:74-78`) |
| F7 | `sig` not standard-b64, ≠ 64 bytes, or verify fails | `AuthError::InvalidSig` | **`Message::Close(None)`** (`peer.rs:74-78`) |
| F8 | Post-auth frame is invalid JSON | `warn` + **continue** — connection survives | nothing (`peer.rs:202-208`) |
| F9 | Post-auth frame has an unknown top-level `type` | `warn` + drop the frame | nothing (`peer.rs:369-375`) |
| F10 | Outer envelope with `ct` estimated > `RELAY_MAX_CT_MIB` (default 4 MiB) | `warn` + drop | nothing (`outer.rs:67-73`, `:29`) |
| F11 | Outer envelope whose `(peer, room)` has no live conn | forward returns false | **`transport_error` control frame** (`peer.rs:401-440`) |

**There is no error frame in the entire auth path.** Every auth-time failure is
an unadorned socket close. The Swift client must map "closed before the first
inbound frame" onto its own error taxonomy; it can never learn *why* from the
relay.

Client-side timeouts to reproduce:

| Timeout | Value | Source |
|---|---|---|
| Whole connect + handshake (phone) | **10 s** | `app/lib/config/dependencies.dart:249` |
| Wait for the `challenge` frame (Pi) | **5 s** | `pi-extension/src/transport/relay_client.ts:6` |

---

## 2. Post-auth frame taxonomy (how to demux inbound)

The relay multiplexes two disjoint frame families on one socket. Discriminate
**structurally, in this order** — this is what
`app/lib/data/transport/ws_transport.dart:89-135` does:

1. Object has **both** `peer` **and** `ct` ⇒ **outer envelope** (`:92`).
2. Otherwise object has a top-level `type` ⇒ **control frame** (`:125`).
3. Otherwise ⇒ drop silently (`:134-135`).

Note the ordering matters and is *not* "check `type` first": a control frame
never carries `ct`, and an envelope never carries `type`, but checking `peer`+`ct`
first is the shipped behaviour and is cheaper.

### 2.1 Outer envelope (bidirectional)

Outbound (client → relay), `ws_transport.dart:213-219`:

```jsonc
{ "peer": "<destination peer_id, STANDARD b64 + padding>",
  "room": "<destination room_id>",
  "ct":   "<STANDARD b64 of the inner JSON's UTF-8 bytes>" }
```

Inbound: the relay **rewrites both addressing fields before delivery**
(`relay/src/handlers/peer.rs:392-396`):

* `peer` ← the **sender's** authenticated `peer_id`
* `room` ← the **sender's own** `room_id` (the one from *its* hello) — **not**
  the `room` the sender wrote in the envelope
* `ct` ← passed through byte-for-byte, never parsed

So on the phone: outbound `peer` = the Mac's Pi-key, `room` = the target
session; inbound `peer` = the Mac's Pi-key, `room` = the session that answered.

`room` is **always present** on the wire in both directions. Serde gives it a
default of `"main"` when a legacy sender omits it (`outer.rs:16-17`), and
`OuterEnvelope` has no `skip_serializing_if`, so the rewritten frame the relay
emits always carries it (`:12-19`).

Size ceiling: `ct.len() * 3 / 4 > max_ct_bytes` is rejected; default 4 MiB, env
override `RELAY_MAX_CT_MIB` (`outer.rs:22-29`, `:67-73`). The check is on the
*estimate*, not a real decode.

### 2.2 Control frames — client → relay

All shapes from `app/lib/protocol/protocol.dart:157-185`; handled at
`relay/src/handlers/peer.rs:222-376`.

```jsonc
{ "type": "subscribe_presence",   "peers": ["<epk>", …] }   // replaces the whole list
{ "type": "unsubscribe_presence", "peers": ["<epk>", …] }
{ "type": "presence_check",       "peers": ["<epk>", …] }
{ "type": "subscribe_rooms",      "peers": ["<epk>", …] }
{ "type": "unsubscribe_rooms",    "peers": ["<epk>", …] }
{ "type": "rooms_check",          "peers": ["<epk>", …] }
{ "type": "room_meta_update", "room_id": "<room>", "meta": { … } }   // Pi-side only
```

* `subscribe_*` **replaces** the subscriber's entire watch list; an empty array
  unsubscribes everything (`relay/src/rooms.rs:130-149`,
  `relay/src/presence.rs:34-…`).
* `subscribe_presence` triggers an immediate `peer_online` backfill for every
  listed peer that is already online (`peer.rs:229`,
  `registry.rs:145-152`) — so the client does not strictly need
  `presence_check` after subscribing, but the Dart client sends both anyway
  (`connection_manager.dart:337-350`).
* `peers` entries **must be standard-b64 epks**. The relay does no
  normalisation on this path — `PresenceManager`/`RoomManager` index by the raw
  string (`presence.rs:8-13`). Trap T1.
* The phone **must not** send `room_meta_update`. It is the Pi's channel for
  publishing `model` / `thinking` / `working` / renamed `name`
  (`pi-extension/src/index.ts:340`, `:366-369`, `:383`). A rename initiated
  from the phone goes as an **inner** `session_rename` to the Pi, which then
  emits the patch (`PROTOCOL.md:347`).

### 2.3 Control frames — relay → client

```jsonc
{ "type": "peer_online",  "peer": "<epk>" }                                  // registry.rs:128
{ "type": "peer_offline", "peer": "<epk>", "since_ts": 1780000000000 }       // registry.rs:202-206
{ "type": "presence", "states": [ { "peer": "<epk>", "online": true, "since_ts": null } ] }  // peer.rs:238-242
{ "type": "rooms", "peer": "<epk>", "rooms": [ <RoomMeta>, … ] }             // peer.rs:268-272
{ "type": "room_announced", "peer": "<epk>", <RoomMeta fields flattened> }   // registry.rs:110-114
{ "type": "room_ended", "peer": "<epk>", "room_id": "<room>", "since_ts": … }// registry.rs:186-191
{ "type": "room_meta_updated", "peer": "<epk>", "room_id": "<room>",
  "meta": { "model": …, "thinking": …, "working": bool, "name": …, "name_rev": … } }  // registry.rs:376-382
{ "type": "transport_error", "reason": "offline",
  "peer": "<destination epk>", "room_id": "<destination room>" }             // peer.rs:430-436
```

**`RoomMeta` serialised shape** (`relay/src/rooms.rs:8-62`) — every nullable
field carries `skip_serializing_if = "Option::is_none"`, so **absent means
null**; `working` has no skip and is **always present**:

```jsonc
{
  "room_id":        "019ffb64-6f7a-7c31-9b2e-4f3a2b1c0d9e",
  "session_id":     "019ffb64-6f7a-7c31-9b2e-4f3a2b1c0d9e",   // omitted on legacy Pi
  "workspace_path": "/Users/x/proj",
  "name":           "backend",
  "name_rev":       1780000000000,
  "role":           "control",            // ONLY on the supervisor's ctrl room
  "cwd":            "/Users/x/proj",
  "model":          "claude-sonnet-4.5",
  "thinking":       "high",
  "working":        false,                // ALWAYS present
  "started_at":     1780000000123         // relay-minted, changes every reconnect
}
```

`presence.states[].since_ts` is `Option<i64>` **without** a skip attribute
(`relay/src/presence.rs:21-26`), so it is serialised as explicit `null` when the
peer is online. `peer_offline.since_ts` is always a number.

---

## 3. Client lifecycle to reproduce in Swift

Reference: `app/lib/data/transport/connection_manager.dart` (the whole file is
the contract; specific lines below).

### 3.1 State machine

```
noPeer ──connect()──► connecting ──ok──► online
                          │                 │
                       failure       WS close / send-error
                          │                 │
                          └────► retrying ◄─┘
                                    │  (backoff timer fires)
                                    └──► connecting …
       offline(canRetry:false) is a terminal state; nothing schedules out of it.
```

Statuses: `StatusNoPeer`, `StatusConnecting`, `StatusOnline(channel)`,
`StatusRetrying(nextRetry, attempt)`, `StatusOffline(reason, canRetry)`
(`connection_manager.dart:46-72`).

### 3.2 Reconnect backoff schedule — exact

```dart
const _kBackoff = [1, 2, 5, 10, 30];                       // seconds
Duration _backoffFor(int a) => Duration(seconds: _kBackoff[a.clamp(0, 4)]);
```
`connection_manager.dart:77-80`.

* **Deterministic, no jitter, no randomisation.** Ladder: 1 s, 2 s, 5 s, 10 s,
  then 30 s forever.
* `_retryAttempt` increments **when the timer fires**, immediately before
  `_connect` (`:1237-1243`), so the *first* retry after a drop always waits 1 s.
* `_retryAttempt` is reset **only** when real inbound traffic arrives on the
  channel (`_watchChannel`'s onData, `:1181-1196`) — **not** on a successful
  connect. This is deliberate (`:20-25` header comment, patch "B"): with the Pi
  down, the WS to the relay keeps authenticating fine, and resetting on connect
  success pinned the ladder at 1 s forever.
* The pi-extension uses the **same ladder** in ms
  (`pi-extension/src/index.ts:1160`: `[1_000, 2_000, 5_000, 10_000, 30_000]`,
  clamped at `:1557-1559`). Both sides agree — reproduce it verbatim.

### 3.3 Two independent keepalives — do not conflate them

| Layer | Who sends | Cadence | Purpose | Source |
|---|---|---|---|---|
| RFC 6455 WS Ping | **relay → client** | 25 s, first tick at +25 s | keeps NAT/LB alive; client's stack auto-Pongs | `relay/src/handlers/peer.rs:181-184`, `:456-460` |
| RFC 6455 WS Ping | **client → relay** | 20 s (Dart `pingInterval`) | app↔relay TCP liveness; surfaces a dead socket as close | `ws_transport.dart:59-62` |
| Inner protocol `ping`/`pong` | client → **Pi** (through the envelope) | 25 s | **Pi** liveness, not socket liveness | `connection_manager.dart:1245-1287` |

The relay **ignores client Pings and Pongs entirely** — it neither answers nor
records them (`peer.rs:195-197`: `Message::Ping(_) | Message::Pong(_) => continue`).
Axum's WS layer auto-Pongs at the protocol level below that. So a client can
never use a relay Pong as a liveness signal; the pi-extension says so at
`relay_client.ts:164-167`.

### 3.4 Ping cadence and missed-ping handling (inner ping)

`connection_manager.dart:1245-1287`:

* `Timer.periodic(25 s)`.
* Each tick: `if (_status is! StatusOnline) return;` then `_missedPings++`
  **before** sending — the increment is unconditional and precedes the send.
* `if (_missedPings == 3) _markActiveRoomOffline();` — **no `return`**. Pings
  keep firing; the counter keeps climbing (so this fires exactly once per
  outage, at the 3rd miss ≈ 75 s of Pi silence).
* Then `await ch.send(Ping(id: 'ping_<n>'))`. If the **send throws**:
  `_cancelPing(); _onChannelLost(peer, ch);` — a send failure is treated as WS
  loss, not as Pi loss.
* Any inbound `ServerMessage` (not just `Pong`) resets `_missedPings = 0`
  **and** `_retryAttempt = 0` (`:1181-1196`).
* `_cancelPing()` also zeroes `_missedPings` (`:1307-1311`).

Inner ping/pong wire shape:
`{"type":"ping","id":"ping_7"}` → `{"type":"pong","in_reply_to":"ping_7"}`
(`app/lib/protocol/protocol.dart:706-711`, `:1220-1226`;
`pi-extension/src/index.ts:4105-4106`).

**Missed pings do NOT tear down the WS.** They mark the *active room* offline
locally (`_markActiveRoomOffline`, `:1289-1301`, which removes only
`_activeRoomId` from `_liveRoomIds[activeEpk]`) and leave the socket up so
presence and other rooms keep flowing. The header comment at `:1252-1266`
records why: tearing down the WS on Pi silence produced a permanent
`room_already_open` deadlock, because the relay only frees its slot when its own
`sink.send` errors — which can take minutes on a half-open TCP.

> **Documentation-vs-code disagreement.** The file header says "Two consecutive
> misses (~50 s) → retrying" (`connection_manager.dart:16-17`). The code uses
> **three** misses and does **not** go to retrying (`:1268-1272`). **The code
> wins.** Implement 3 misses → mark active room offline, WS untouched.

### 3.5 Liveness watchdogs

Two distinct watchdogs exist; a Swift client needs both.

**(a) Stuck-offline watchdog (phone).** `Timer.periodic(15 s)`
(`connection_manager.dart:195-207`). Fires `_scheduleRetry(peer)` when **all**
of: an active peer exists, status is not `StatusOnline`, no connect in flight,
and no retry timer is pending. Pure belt-and-braces against a dropped retry
chain.

**(b) Inbound-silence watchdog (Pi side; the phone has no equivalent).**
`pi-extension/src/transport/relay_client.ts:17-18`, `:220-235`:

```ts
const LIVENESS_TIMEOUT_MS = 70_000;   // ~2.8 missed relay pings
const LIVENESS_CHECK_MS   = 20_000;   // poll interval
```

Every inbound event refreshes `lastActivityAt`: `message` (`:156-157`), `ping`
(`:168`), and `pong` (`:169`). If `now - lastActivityAt > 70 s`, it calls
`ws.terminate()`, whose synthetic `close` drives the owner's reconnect
(`:222-227`). The rationale (`:8-15`) is the half-open case: NAT drop / laptop
sleep / Cloudflare reaping without a close frame, which otherwise leaves a
daemon "online but dead" forever.

**Recommendation for iOS:** implement (b) as well as (a). The phone is *more*
exposed to half-open sockets than a Mac daemon (cellular handoff, backgrounding).
`URLSessionWebSocketTask` will not tell you the socket died. Since the relay
pings every 25 s (§3.3), a 70 s inbound-silence deadline is directly
transplantable — count *any* inbound activity, including Pongs the URLSession
layer surfaces.

### 3.6 Subscription replay on every (re)connect

After each successful connect, `_replaySubscriptions()` sends four frames in
this order (`connection_manager.dart:1171-1179`):

```
subscribe_presence(epks)
presence_check(epks)
subscribe_rooms(epks)
rooms_check(epks)
```

`epks` is the cached list from the last `subscribeToPeers`, already normalised
to standard b64 (`:337-350`). If the list is empty the whole replay is skipped
(`:1172`). This is mandatory: the relay's subscription graph is **per
connection-lifetime** — `rooms.unsubscribe_all(&peer_id)` runs on disconnect
(`relay/src/handlers/peer.rs:465`), and `presence.unsubscribe_all` runs when the
peer fully offlines (`registry.rs:213`).

Relay-side dedup you will observe: `presence_check` and `rooms_check` replies
are suppressed when byte-identical to the previous reply **on the same
connection** (`peer.rs:172-176`, `:247-255`, `:277-281`). A fresh connection has
an empty dedup cache, so the first reply after every reconnect always arrives.

### 3.7 Connection teardown ordering

`_teardownActive` / `_connect` both perform, in order
(`connection_manager.dart:487-506`, `:535-542`):

1. cancel retry timer, 2. cancel ping timer (zeroes `_missedPings`),
3. cancel the in-flight connect token, 4. cancel the channel subscription,
5. cancel the control subscription, 6. close the old channel, 7. `_clearLiveRooms()`.

**Cancelling the old channel's subscription before opening a new one is
load-bearing.** The old socket's `onDone` (the relay killing the previous WS
when a new one authenticates) would otherwise re-enter `_onChannelLost` and
start a self-sustaining retry storm (`:19-23`, patch "A"). `_onChannelLost` has
a second guard: it ignores the event unless the closing channel is
`identical` to the currently-online one (`:1201-1207`).

---

## 4. Inbound room demux (and the plan-61 `ctrl` exemption)

`app/lib/data/transport/ws_transport.dart:92-123`:

```dart
if (frame.containsKey('peer') && frame.containsKey('ct')) {
  final bytes = _b64Decode(frame['ct'] as String);
  final senderRoom = frame['room'] as String?;
  if (senderRoom != null &&
      senderRoom != transport._activeRoom &&
      senderRoom != kControlRoomId) {         // ← plan 61 Phase 3 exemption
    return;                                    // DROPPED (room-mismatch)
  }
  transport._queue.add(bytes);
  return;
}
```

Rules, restated:

1. `room` is the **sender's** room (relay-rewritten, §2.1).
2. A payload whose sender room differs from `_activeRoom` is **discarded at the
   transport layer** — it never reaches the message decoder. Reason: the app's
   `SessionRepository` is a singleton, so `agent_chunk`s from a session the user
   just left would bleed into the one they are viewing (`:95-101`).
3. **Exemption:** `room == "ctrl"` always passes (`:102-110`). The control room
   is not a chat — it only ever emits `action_ok` / `action_error` for
   workspace/session RPCs, so it cannot pollute conversation state. Without the
   exemption every gateway reply would be dropped, since the active room is
   whichever chat is open.
4. `kControlRoomId == 'ctrl'` (`app/lib/protocol/protocol.dart:933`) and
   `CONTROL_ROOM_ID = "ctrl"` (`pi-extension/src/protocol/control_wire.ts:19`).
   It is a **reserved literal**, deliberately shorter than 12 chars and not a
   UUID so it can never collide with a chat room
   (`pi-extension/src/protocol/control_wire.test.ts:16-18`).
5. The legacy branch (`senderRoom == null` routes unconditionally) is
   unreachable against this relay, which always serialises `room` (§2.1). Keep
   it anyway for tolerance.

Control frames are **not** subject to this demux — they carry no `room` and
route by `peer` (`:124-133`).

---

## 5. Room targeting: per-connection vs per-send

Two distinct mechanisms. Both write the same `room` field; only the lifetime
differs.

### 5.1 Per-connection: `setActiveRoom` / `send`

`ws_transport.dart:197-219`:

```dart
String _activeRoom = 'main';                 // default when nothing is known
void setActiveRoom(String room) { … _activeRoom = room; }
Future<void> send(Uint8List data) async {
  _ws.sink.add(jsonEncode({'peer': _peerPubkey, 'room': _activeRoom,
                           'ct': base64.encode(data)}));
}
```

`_activeRoom` also gates inbound (§4), so it is genuinely the connection's
"current conversation".

The manager owns a **pointer trio** that decides what `_activeRoom` becomes
(`connection_manager.dart:145-160`):

| Field | Meaning |
|---|---|
| `_activeRoomId` | the room every outbound envelope is addressed to |
| `_activeRoomOwner` | the **standard-b64 epk** the pointer belongs to |
| `_activeRoomPinned` | the pointer came from an explicit choice (user tap, or the restored `epk:roomId` preference) |

Rules the Swift client must reproduce:

* **Reseed only on a destination change.** `_connect` reseeds
  (`_activeRoomId ← peer.roomId ?? 'main'`, unpin) **only when
  `_activeRoomOwner != toStandardB64(peer.remoteEpk)`**
  (`:564-570`). A reconnect to the *same* Mac leaves the pointer intact. This is
  what stopped "the chat jumps to another cwd after backgrounding".
* **Push down before going online.** `_propagateActiveRoom(_activeRoomId, ch)`
  runs *before* `_emit(StatusOnline(ch))` (`:583-585`), because the factory
  builds a fresh transport whose `_activeRoom` defaults to `'main'`. The very
  first send after connect must already carry the right room.
* **Pinned wins over discovery.** `switchRoom(roomId, {epk})` sets
  `_activeRoomPinned = true` **before** its no-op guard (`:270-277`) — re-tapping
  the room you are already in still upgrades a tentative hint to a user choice.
* **Discovery re-points only an unpinned, dead pointer.**
  `_maybeAdoptLegacyRoom` (`:1133-1162`) bails if pinned, and bails if the relay
  currently reports `_activeRoomId` as live. It fires on `room_announced` and on
  a non-empty `rooms` snapshot (`:640`, `:869-871`).
* `PeerRecord.roomId` is a **last-opened hint**, never identity (plan-61 Phase
  0, `plan/61-stable-session-identity.md`). It is consulted only in the reseed
  branch.

### 5.2 Per-send: `sendToRoom`

`ws_transport.dart:229-235`:

```dart
Future<void> sendToRoom(Uint8List data, String room) async {
  _ws.sink.add(jsonEncode({'peer': _peerPubkey, 'room': room,
                           'ct': base64.encode(data)}));
}
```

Identical wire shape; **`_activeRoom` is untouched**. Introduced in plan 61
Phase 2 precisely because renaming a session from Home targets whichever session
the user long-pressed — usually *not* the one they are chatting in — and
re-pointing `setActiveRoom` to deliver it would silently move the user's
conversation (`:221-228`).

Current callers:

| Caller | Target room | Source |
|---|---|---|
| `MachineControlRepository._rpc` | `kControlRoomId` (`"ctrl"`) | `app/lib/data/control/machine_control_repository.dart:116` |
| `ActionsRepository.renameSession` | the renamed session's `roomId` | `app/lib/data/actions/actions_repository.dart:328`, `:371-375` |

**Swift guidance.** Model this as one method with an explicit destination and a
separate `setActiveRoom`; do not let "send" implicitly mean "and switch". Note
Trap T5 before wiring `sendToRoom` to anything but `ctrl`.

---

## 6. Cached live-room state across a disconnect

Two caches with deliberately different lifetimes
(`connection_manager.dart:113-118`):

| Cache | Contents | Survives disconnect? |
|---|---|---|
| `_roomsByPeer: Map<epk, List<RoomInfo>>` | the canonical room **list** (cached + announced) | **Yes** — these are the grey tiles the user can still open to read history |
| `_liveRoomIds: Map<epk, Set<String>>` | which rooms the relay says are up **right now** | **No — cleared on every disconnect** |

`_clearLiveRooms()` (`:1226-1230`) empties `_liveRoomIds` wholesale and schedules
a rooms emit. It is called from:

* `_onChannelLost` (`:1220`) — WS died,
* `_teardownActive` (`:503`) — deliberate disconnect / peer switch.

**Why clearing is required** (`:1208-1219`): `isRoomLive` is already gated on
`StatusOnline` (`:957-961`), so nothing renders green *during* the outage. But if
the stale set survived, then at the instant the WS came back — **before** the
relay's `rooms` snapshot landed — every previously-live room flipped green
again, including ones whose Pi had exited during the outage. Clearing makes the
reconnect honest: green only once the relay says so.

Related gates to reproduce:

* `isRoomLive(epk, roomId)` returns `false` whenever status ≠ online, regardless
  of cache (`:957-961`).
* `isRoomWorking(epk, roomId)` — same gate (`:975-983`).
* `_emit` re-emits the rooms snapshot whenever status crosses the online
  boundary in either direction (`:1313-1326`), so the UI re-evaluates dot colour
  without waiting for a relay push.
* On `transport_error`, the room is removed from `_liveRoomIds` **immediately**
  and the error is republished on `transportErrors` so the chat writer can fail
  outstanding sends now instead of waiting out the ~20 s no-echo timer
  (`:802-820`). The next `room_announced` puts it back.

`RoomInfo` (the persisted/cached room record) must carry `sessionId`,
`workspacePath`, `nameRev`, and `role` across a cold start
(`connection_manager.dart:1035-1050`, `:1064-1092`). Dropping `nameRev` at boot
would let a stale rename patch landing right after launch be accepted (no stored
revision to compare against) and revert a label the user already changed
(`:1040-1044`).

---

## 7. Traps

These are the parts that have caused recurring bugs. They matter more than the
happy path.

### T1 — Base64 variant is field-specific, and the registry key is a raw string

| Field | Accepted on input | Emitted by relay |
|---|---|---|
| `hello.pubkey` | standard **or** URL-safe, padded **or** unpadded — but **never mixed** (`identity.rs:14-30`) | n/a |
| `auth.sig` | **STANDARD, padded only** (`challenge.rs:4`, `:82`) | n/a |
| `challenge.nonce` | n/a | STANDARD, padded (`challenge.rs:49`) |
| envelope `peer` | **raw string compare** against `peer_id` | STANDARD, padded (`peer.rs:80`) |
| envelope `ct` | any (never decoded by relay) | pass-through |
| `subscribe_*.peers[]` | **raw string compare** | n/a |
| every relay-reported `peer` | n/a | STANDARD, padded |

The killer: `peer_id` is *always* re-derived as `STANDARD.encode(vk.to_bytes())`
(`peer.rs:80`), and the routing table is `HashMap<(String, String), …>`
(`registry.rs:15`) queried with `env.peer` **verbatim** (`peer.rs:388`, `:401`).
So a lenient `hello.pubkey` does **not** buy you a lenient `peer` field: send a
URL-safe `peer` and the lookup misses, you get `transport_error: offline`, and
nothing else tells you why. Same for `subscribe_presence.peers` (silent: you
just never get pushes).

The Dart app carries a whole module for this (`epk_encoding.dart`) because
storage/QR use base64url while the wire uses standard: `toStandardB64` on
everything transport-bound (`:24-36`), `toAppEpk` on everything inbound
(`:41-59`). Note `toAppEpk` **strips padding** (`:46`) — so the app's internal
key form is url-safe-unpadded and the wire form is standard-padded, and they are
*not* interchangeable as dictionary keys.

**Swift recommendation:** do not model an epk as `String`. Use a
`PeerKey` value type wrapping the 32 raw bytes, with `var wireForm: String`
(standard+padding) as the *only* way to serialise it and a lenient
`init?(anyBase64:)` mirroring `identity.rs`. Make every dictionary key
`PeerKey`, never a string. This trap has broken presence, room subscriptions,
and envelope routing on separate occasions.

### T2 — `sig` has no URL-safe fallback, `pubkey` does

Easy to get wrong if you write one base64 helper for the whole handshake. A
64-byte Ed25519 signature almost always contains `+` or `/`, so a URL-safe
encoder produces a string `verify_auth` rejects (`challenge.rs:82`) and you get
an unexplained close (F7). Swift's `Data.base64EncodedString()` is standard and
padded by default — correct here; the danger is a custom "safe base64" helper
being reused.

### T3 — `"ctrl"` must never be treated as a hashed/derived id

`room_id = "ctrl"` is a reserved literal (`control_wire.ts:19`), asserted in
tests to be **shorter than 12 characters and not to match the 12-char digest
pattern** (`control_wire.test.ts:16-18`). Any client code that assumes a room id
is a UUID or a 12-char base64url digest — a validator, a parser, a length
check — will reject the control room and break machine control entirely. It is
also the **only** value exempt from the inbound demux (§4).

The other half: `role: "control"` (`CONTROL_ROOM_ROLE`, `control_wire.ts:22`) is
what keeps the gateway out of the chat list (`RoomInfo.isControlRoom`,
`app/lib/protocol/protocol.dart:258`). A client that filters only by
`room_id == "ctrl"` and not by `role` will render a machine as a dead chat tile
if the gateway ever moves; one that filters only by `role` is fine. Filter by
`role`.

### T4 — `name_rev` omitted bypasses the monotonic gate completely

`relay/src/peers/registry.rs:306-311`:

```rust
let name_accepted = match (patch.name.as_ref(), patch.name_rev, stored_rev) {
    (None, _, _) => false,
    (Some(_), Some(incoming), Some(stored)) => incoming > stored,
    (Some(_), _, _) => true,        // ← name with NO name_rev always wins
};
```

A `room_meta_update` carrying `name` but no `name_rev` is accepted
unconditionally — even over a room that already holds a newer revision — and
does not update `name_rev` (`:326-328` only writes it when present). So one
rev-less patch can undo the entire anti-rollback scheme for that room.
The app's client-side gate has the same shape
(`connection_manager.dart:775-783`: `nameRev == null || stored == null ||
nameRev > stored`). **Always send `name_rev` with every `name` patch**, as the
pi-extension does (`index.ts:366-369`).

Second, subtler half: `RoomMetaPatch::is_empty` deliberately **ignores
`name_rev`** (`relay/src/rooms.rs:100-105`), so `meta: {"name_rev": 5}` alone is
a no-op with **no broadcast** — you cannot bump a revision without also setting
a name.

Third: a **rejected** stale patch still triggers a broadcast carrying the
**current** name and rev (`registry.rs:366-375`). That is the resync mechanism —
the device that sent the stale patch learns the truth. Do not treat an unchanged
`room_meta_updated` as a no-op to be ignored; feed it through the same merge.

Where `name_rev` comes from: `_nextNameRev()` is `Date.now()`, monotonised by
`+1` on collision (`pi-extension/src/index.ts:283-287`). It is an epoch-ms
value in an i64 — model it as `Int64`, not `Int32`, and never as a `Date`.

### T5 — `sendToRoom` to a non-`ctrl` room: the reply is dropped by your own demux

`ActionsRepository.renameSession` sends `session_rename` to an arbitrary
`roomId` (`actions_repository.dart:328`), and the Pi answers `action_ok` from
**that** room. But the inbound demux exempts only `"ctrl"`
(`ws_transport.dart:108-110`), so when the renamed session is not the active
room the `action_ok` is discarded and the RPC hits its 15 s timeout
(`actions_repository.dart:156`). The UI still converges, but through a different
path — the relay's `room_meta_updated` broadcast (§2.3) — so the bug shows up as
a spurious failure toast, not as a wrong name.

**Do not copy this shape blindly.** For iOS, the correct fix is to demux on the
*inner* payload's routing (or to exempt any room with an outstanding RPC), not
to widen the exemption list to "everything", which would reintroduce the
chunk-bleed the demux exists to prevent (`ws_transport.dart:95-101`).

### T6 — `room_meta_updated`: relay says "replace wholesale", app merges. **The app wins.**

The relay's contract comment (`registry.rs:276-282`) states the broadcast
carries the **full post-patch state** of the mutable fields and that
"subscribers replace their cached `meta` wholesale instead of merging
field-by-field"; nullable fields still `None` after the patch are **omitted**.

The Dart client does the opposite: it uses `meta.containsKey(...)` to build
`hasModel` / `hasThinking` / `hasName` and **preserves** the cached value when
the key is absent (`app/lib/protocol/protocol.dart:88-113`,
`connection_manager.dart:757-776`).

These disagree exactly when the relay clears a field to null. **Follow the app.**
Rationale: the only producer of `room_meta_update` is the pi-extension, and it
never sends an explicit null — it emits `{model}` (`index.ts:340`),
`{name, name_rev}` (`:366-369`), or `{working}` (`:383`). Under wholesale-replace
semantics a `{working}` patch would clear the cached `model` and `thinking` on
every turn boundary, which is visibly wrong. The merge behaviour is the shipped,
correct one; the relay comment is aspirational.

Concretely, for `room_meta_updated` implement:

* key **absent** ⇒ preserve cached value;
* key present with `null` ⇒ set to null (nullable fields only);
* `working` ⇒ always present in the broadcast, plain bool, no null state
  (`registry.rs:360-365`, `rooms.rs:56-60`).

### T7 — `room_already_open` is dead code; there is no error frame

`pi-extension/src/transport/relay_client.ts:79-89`, `:253-259` handle a
`{"type":"error","code":"room_already_open"}` frame and surface a specific
message (`index.ts:2917-2922`). **This relay never emits it** — `grep` finds the
string only in the pi-extension and in a Dart comment
(`connection_manager.dart:1255`). Since plan 23 Wave 2C the registry explicitly
allows **N simultaneous connections at the same `(peer_id, room_id)`**
(`registry.rs:18-31`), each authenticated independently; a forward fans out to
all of them minus the sender (`registry.rs:246-268`).

**Do not implement a `room_already_open` path in Swift.** But *do* implement the
consequence: a second device of the same Owner on the same room is legal and
expected, and the relay **skips the sender's own connection** when forwarding
(`peer.rs:399-406` passes `conn_id`) so your own outbound never echoes back to
you — while your *other* device does see it.

### T8 — the pre-auth window drops frames

`ws_transport.dart:76-88`: while `authDone == false`, **every** inbound frame is
funnelled into a single `Completer`. A second pre-auth frame calls
`complete()` on an already-completed completer, which throws, is swallowed by
the `catch`, and the frame is **lost**. There is a real `await` between
receiving the challenge and setting `authDone = true` (the
`await Ed25519().sign(...)` at `:177`), so the window is not theoretical.

Against today's relay nothing is pushed in that window (the routing loop starts
only after `register`, and backfills are triggered by your own later
`subscribe_presence`). But it is fragile. **In Swift, buffer post-challenge
frames into the normal inbound path instead of discarding them** — a queue, not
a one-shot promise.

### T9 — `started_at` is relay-minted and changes every reconnect

`peer.rs:140-143`. Never use it as an identity, a sort key, or a
"session started" timestamp shown to the user
(`PROTOCOL.md:221-222`). The Dart `RoomInfo.==` includes it
(`protocol.dart:347-361`), which is why the manager's dedup compares whole
`RoomInfo` values and re-emits on every reconnect — acceptable there, a hazard
if you key a SwiftUI `ForEach` by anything containing it.

### T10 — `room_announced` is flat; `room_meta_updated` is nested

`room_announced` is `serde_json::to_value(&room_meta)` with `type` and `peer`
**injected into the same object** (`registry.rs:110-114`) — so `room_id`,
`session_id`, `name`, `name_rev`, `role`, `working`, `started_at` are all
**top-level**. `rooms` snapshot items are the same flat `RoomMeta`
(`peer.rs:268-272`). But `room_meta_updated` nests everything under `"meta"`
(`registry.rs:376-382`).

The Dart parser dual-reads top-level **and** `meta.*` on `room_announced` for
forward-compat with a relay that forwards the Pi's `room_meta` verbatim
(`protocol.dart:29-64`). Mirror that tolerance; do not assume one shape.

### T11 — envelope size is checked as an *estimate*, before decode

`ct.len() * 3 / 4 > max_ct_bytes` (`outer.rs:69-70`). A frame that fails is
dropped with only a `warn` — **no `transport_error`, no close, nothing on the
wire** (`peer.rs:381-384`). The historical symptom was the app stuck on
"sending…" forever for images (`outer.rs:24-28`). Enforce the same ceiling
client-side (4 MiB decoded default) and fail the send locally rather than
discovering it by silence.

### T12 — `working: false` is the cleared state; there is no null

`RoomMeta.working` is a non-`Option` bool, always serialised
(`rooms.rs:56-60`), defaulted to `false` when the hello omits it
(`peer.rs:109-112`). `RoomMetaPatch.working` is a single `Option<bool>`: absent
= leave alone, present = set (`rooms.rs:76-79`). Modelling it as `Bool?` where
`nil` means "off" will make a model-only patch flip the working dot.

---

## 8. Suggested Swift shapes

Types only — no implementation.

```swift
// ── Identity ────────────────────────────────────────────────────────────────
/// 32 raw Ed25519 public-key bytes. The ONLY thing allowed as a dictionary key.
struct PeerKey: Hashable, Sendable {
    let raw: Data                       // exactly 32 bytes
    init?(anyBase64: String)            // mirrors relay/src/identity.rs:14-30
    var wireForm: String                // STANDARD + padding — the only serialisation
}

/// A room id is an opaque string. NEVER validate its shape (Trap T3).
struct RoomID: Hashable, RawRepresentable, Codable, Sendable {
    let rawValue: String
    static let control = RoomID(rawValue: "ctrl")
    static let main    = RoomID(rawValue: "main")
}

// ── Handshake ───────────────────────────────────────────────────────────────
struct Hello: Encodable {
    let type = "hello"
    let pubkey: String                  // peerKey.wireForm
    let roomID: RoomID?                 // omit → relay uses "main"
    let roomMeta: RoomMeta?             // phone: always nil
    enum CodingKeys: String, CodingKey { case type, pubkey, roomID = "room_id", roomMeta = "room_meta" }
}
struct Challenge: Decodable { let type: String; let nonce: String }   // nonce: STANDARD b64, 32 B
struct Auth: Encodable { let type = "auth"; let sig: String }         // STANDARD b64 of 64 B

// ── Envelope ────────────────────────────────────────────────────────────────
struct OuterEnvelope: Codable {
    let peer: String                    // outbound: destination.wireForm; inbound: sender
    let room: String                    // outbound: destination room; inbound: SENDER's room
    let ct:   String                    // STANDARD b64 of inner JSON UTF-8
}

// ── Control frames ──────────────────────────────────────────────────────────
enum ControlInbound: Decodable {        // decode by the "type" discriminator
    case peerOnline(peer: String)
    case peerOffline(peer: String, sinceTs: Int64)
    case presence(states: [PeerPresence])                       // since_ts is EXPLICIT null when online
    case roomAnnounced(peer: String, meta: RoomMeta)            // FLAT (Trap T10)
    case roomEnded(peer: String, roomID: RoomID, sinceTs: Int64)
    case rooms(peer: String, rooms: [RoomMeta])                 // FLAT
    case roomMetaUpdated(peer: String, roomID: RoomID, patch: RoomMetaPatch)  // NESTED under "meta"
    case transportError(peer: String, roomID: RoomID, reason: String)
    case unknown                        // forward-compat: never throw on an unknown type
}

/// Absent-vs-null must survive decoding (Trap T6). Do NOT use plain `String?`.
enum FieldPatch<T: Codable>: Codable { case absent, null, value(T) }
struct RoomMetaPatch: Decodable {
    var model:    FieldPatch<String> = .absent
    var thinking: FieldPatch<String> = .absent
    var name:     FieldPatch<String> = .absent
    var nameRev:  Int64?             // epoch-ms; Int64, never Int32 or Date (Trap T4)
    var working:  Bool?              // nil = absent; there is no null state (Trap T12)
}

struct RoomMeta: Codable, Equatable {
    let roomID: RoomID
    var sessionID: String?           // presence == "post-plan-61 stable id"
    var workspacePath: String?       // relay falls back to cwd
    var name: String?
    var nameRev: Int64?
    var role: String?                // "control" ⇒ machine gateway, not a chat
    var cwd: String?
    var model: String?
    var thinking: String?
    var working: Bool                // always present, defaults false
    var startedAt: Int64             // relay-minted; NEVER a key (Trap T9)
    var isControlRoom: Bool { role == "control" }
}
```

**Codable strategy.** Do **not** use `.convertFromSnakeCase`: `room_id` → `roomID`
does not round-trip (`.convertToSnakeCase` yields `room_id` only by luck of the
acronym rules, and `nameRev` → `name_rev` while `sessionID` → `session_id`
depends on the exact acronym heuristic). Declare explicit `CodingKeys` on every
type. For `RoomMetaPatch`, implement `init(from:)` against a
`KeyedDecodingContainer` and use `contains(key)` + `decodeNil(forKey:)` to
produce the three-way `FieldPatch` — that pair is the exact analogue of the
Dart `containsKey` checks at `protocol.dart:91-95`.

**Concurrency.** Model the manager as an `actor` holding
`activeRoom: (id: RoomID, owner: PeerKey, pinned: Bool)`, `roomsByPeer:
[PeerKey: [RoomID: RoomMeta]]`, and `liveRoomIDs: [PeerKey: Set<RoomID>]`, and
expose status/rooms/transport-errors as `AsyncStream`s. Coalesce room and
presence emissions with the same 50 ms debounce the Dart manager uses
(`connection_manager.dart:180`, default 50 ms at `:184`) — the relay is a firehose
during multi-device reconnects.

---

## 9. Constant reference (copy these exactly)

| Constant | Value | Source |
|---|---|---|
| WS path | `/` | `relay/src/lib.rs:59` |
| Hello timeout (server) | 5000 ms | `relay/src/auth/challenge.rs:12` |
| Challenge nonce | 32 bytes, STANDARD b64 padded | `challenge.rs:46-51` |
| Signature | Ed25519 over the 32 raw nonce bytes, STANDARD b64 padded | `challenge.rs:76-89` |
| Relay → client WS Ping | every 25 s, first at +25 s | `relay/src/handlers/peer.rs:181-184` |
| Client → relay WS Ping | every 20 s | `app/lib/data/transport/ws_transport.dart:61` |
| Inner `ping` to the Pi | every 25 s | `connection_manager.dart:1246` |
| Missed inner pings → mark active room offline | **3** (WS stays up) | `connection_manager.dart:1268-1272` |
| Reconnect backoff | 1, 2, 5, 10, 30 s (clamped, no jitter) | `connection_manager.dart:77-80`; `pi-extension/src/index.ts:1160` |
| Stuck-offline watchdog | every 15 s | `connection_manager.dart:197` |
| Inbound-silence watchdog (Pi) | 70 s deadline, 20 s poll | `relay_client.ts:17-18` |
| Connect + handshake timeout (phone) | 10 s | `app/lib/config/dependencies.dart:249` |
| Challenge wait timeout (Pi) | 5 s | `relay_client.ts:6` |
| Chat action RPC timeout | 15 s | `actions_repository.dart:156` |
| Machine-control RPC timeout | 45 s | `machine_control_repository.dart:61` |
| Outer envelope ceiling | 4 MiB decoded, env `RELAY_MAX_CT_MIB` | `relay/src/protocol/outer.rs:22-29` |
| Control room id / role | `"ctrl"` / `"control"` | `pi-extension/src/protocol/control_wire.ts:19`, `:22` |
| Default room id | `"main"` | `relay/src/protocol/outer.rs:8-10`; `peer.rs:90` |
| Default relay URL | `https://relay-rp1.jacobmoura.work` | `app/lib/data/transport/relay_config.dart:25` |

---

## 10. Open questions (not determinable from the code)

1. **No auth-success acknowledgement.** Nothing distinguishes "auth accepted,
   idle" from "auth rejected, close in flight" until a frame or a close arrives.
   The 1-second heuristic in §1.4 is my recommendation, not a protocol
   guarantee. If the relay is ever changed, an explicit `{"type":"ready"}` would
   remove the ambiguity — worth raising before the Swift client ships.
2. **`transport_error` reason vocabulary.** Only `"offline"` is ever emitted
   (`peer.rs:432`). The Dart parser defaults an absent reason to `"unknown"` and
   an absent `room_id` to `"main"` (`protocol.dart:86-90`), implying more values
   were anticipated. No enumeration exists in any implementation.
3. **Rate limits / backpressure.** `mpsc::unbounded_channel` (`peer.rs:169`)
   means the relay never applies backpressure and there is no documented
   per-connection frame-rate or byte-rate limit beyond the 4 MiB per-envelope
   cap. Whether the deployment sits behind Cloudflare limits is not visible in
   this repo.
4. **Half-open detection on the phone.** The Dart client has **no**
   inbound-silence watchdog — only the Pi does. Whether the 20 s
   `IOWebSocketChannel.pingInterval` alone has been sufficient in production is
   not answerable from the code; §3.5 recommends adding the Pi's 70 s watchdog
   on iOS regardless.
5. **Trap T5 (`sendToRoom` reply drop) — never fixed.** I found no code path
   that delivers a non-`ctrl`, non-active-room `action_ok` to the app. It may be
   a known-accepted timeout or an unreported bug; the intended behaviour is not
   recorded in `plan/61-stable-session-identity.md` or `PROTOCOL.md`.
