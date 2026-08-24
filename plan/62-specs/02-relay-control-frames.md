# Spec 02 — Relay control frames + outer envelope

**Audience:** the native iOS client. Everything here must be byte-compatible with
`relay/src/**` (Rust, the authority) and `pi-extension/src/**` (Node, the peer on
the other end). Post-plan-61 shape only.

**Ground truth read for this spec**

| File | What it decides |
|---|---|
| `relay/src/protocol/outer.rs` | envelope struct, `room` default, `ct` ceiling |
| `relay/src/handlers/peer.rs` | the WS state machine, control-frame demux, rewrite-on-forward, `transport_error` |
| `relay/src/peers/registry.rs` | `room_announced` / `room_ended` / `peer_online` / `peer_offline` / `rooms` payloads, `name_rev` gate, `room_meta_updated` payload |
| `relay/src/rooms.rs` | `RoomMeta` / `RoomMetaPatch` field set + serialization rules |
| `relay/src/presence.rs` | `presence` snapshot payload |
| `relay/src/identity.rs` | which base64 variants are accepted where |
| `app/lib/protocol/protocol.dart` | `ControlInbound` — the reference *consumer* |
| `pi-extension/src/transport/relay_client.ts` | the reference *producer* of `hello.room_meta` and `room_meta_update` |

Nothing in this spec is negotiable by the client: the relay is a fixed binary.
Where the Dart and TS implementations disagree with Rust, **Rust wins** and the
divergence is flagged.

---

## 0. Connection lifecycle (context you need before the frames)

One WebSocket = one `(peer_id, room_id)` registration.

```
client                                   relay
  │  {"type":"hello","pubkey":…,          │   ≤ 5 s (HELLO_TIMEOUT_MS,
  │   "room_id":…,"room_meta":{…}}   ───► │    auth/challenge.rs:12)
  │                                       │
  │  ◄─── {"type":"challenge","nonce":…}  │   nonce = 32 random bytes,
  │                                       │   STANDARD base64 (challenge.rs:46-51)
  │  {"type":"auth","sig":…}         ───► │   Ed25519 over the RAW 32 nonce bytes
  │                                       │
  │  (no "ok" frame — routing just starts) │   relay_client.ts:271-273
```

- The relay derives `peer_id = STANDARD_base64(verifying_key.to_bytes())`
  (`handlers/peer.rs:80`). Whatever variant you put in `hello.pubkey` is
  normalized (`identity.rs:14-30` accepts standard/url-safe, padded/unpadded,
  but **rejects mixed alphabets**). Your own identity on the wire is therefore
  always standard-with-padding regardless of what you sent.
- `hello.room_id` defaults to `"main"` when absent (`peer.rs:88-91`). The app
  registers as `"main"` (`ws_transport.dart` hello). A Pi registers as its
  session id; the supervisor gateway registers as `"ctrl"`.
- The relay sends a WS **Ping every 25 s** (`peer.rs:181-184, 456-459`). Answer
  with Pong (URLSessionWebSocketTask does this automatically). Treat >70 s of
  total inbound silence as a dead socket and reconnect — that is exactly what
  the Pi does (`relay_client.ts:17-18`, `LIVENESS_TIMEOUT_MS = 70_000`), and it
  exists because half-open sockets never deliver `close`.
- Binary frames are dropped by the relay (`peer.rs:198`). Send text only.
- On disconnect the relay runs `registry.unregister` + `rooms.unsubscribe_all`
  (`peer.rs:464-465`). **Presence subscriptions are NOT cleared on
  disconnect** — only when the whole peer goes offline
  (`registry.rs:213`, inside the `peer_offlined` branch). Room subscriptions are
  cleared on every conn close. Consequence: after a reconnect you must re-send
  `subscribe_rooms`; re-sending `subscribe_presence` is idempotent and cheap, do
  both.

### Frame demux rule (the single most important parsing rule)

`peer.rs:202-211, 377-381`:

1. Parse the text as JSON. Invalid JSON → dropped with a warn, no reply.
2. **If the top-level object has a `type` field whose value is a JSON string**,
   it is a *control frame*, handled by the relay, and is **never forwarded**.
   An unrecognised `type` is dropped with a warn (`peer.rs:369-375`).
3. Otherwise it is an *outer envelope* and goes through `parse_line`.

So: your outer envelope must **not** contain a `type` key, and your control
frames must always contain one. There is no other discriminator.

Swift:

```swift
enum RelayFrame {
    case control(ControlInbound)
    case envelope(OuterEnvelope)
}
// decode: try container.decodeIfPresent(String.self, forKey: .type) != nil ? control : envelope
```

---

## 1. Outer envelope

`relay/src/protocol/outer.rs:12-19`:

```rust
pub struct OuterEnvelope {
    pub peer: String,
    #[serde(default = "default_room")]   // "main"
    pub room: String,
    pub ct: String,                       // base64 — never decoded by the relay
}
```

### Wire shape

```json
{ "peer": "kZ7c…4h8=", "room": "019ffb64-1c3e-7a91-b0d2-6f2a1c9e77aa", "ct": "eyJ0eXBlIjoi…" }
```

| Field | Required | Type | Notes |
|---|---|---|---|
| `peer` | **yes** | string | Destination peer's Ed25519 public key, **base64 STANDARD with padding**. No default; a missing `peer` fails `serde` deserialization and the frame is dropped with a warn. |
| `room` | no | string | Destination room. Absent ⇒ `"main"` (`outer.rs:8-10, 16-17`). |
| `ct` | **yes** | string | Base64 (**standard, padded**) of the inner JSON, UTF-8. Not ciphertext. |

`ct` is base64 of plaintext JSON — the relay operator can read it. This is
stated openly in `PROTOCOL.md` ("o que NÃO está protegido"). Do not describe the
product as end-to-end encrypted.

### The rewrite on forward

`peer.rs:385-406`:

```rust
let rewritten = OuterEnvelope {
    peer: peer_id.clone(),   // ← the AUTHENTICATED SENDER, not the destination
    room: room_id.clone(),   // ← the SENDER'S OWN hello room_id, not env.room
    ct:   env.ct,            // ← verbatim, never touched
};
```

Both header fields are replaced. Concretely:

| Direction | What you send | What the recipient sees |
|---|---|---|
| iOS → Pi | `{peer: <pi_key>, room: <session_id>, ct}` | `{peer: <owner_key>, room: "main", ct}` |
| Pi → iOS | `{peer: <owner_key>, room: "main", ct}` | `{peer: <pi_key>, room: <session_id>, ct}` |
| iOS → gateway | `{peer: <pi_key>, room: "ctrl", ct}` | `{peer: <owner_key>, room: "main", ct}` |
| gateway → iOS | `{peer: <owner_key>, room: "main", ct}` (`daemon/gateway.ts:217` sends `room: CONTROL_ROOM_ID` — rewritten to the gateway's own hello room, which *is* `"ctrl"`) | `{peer: <pi_key>, room: "ctrl", ct}` |

**Therefore inbound `room` is the SENDER's room and is your demux key.** The
Flutter client uses it exactly this way (`ws_transport.dart:104-116`): drop
payloads whose `room` is neither the currently-open chat room nor `"ctrl"`.
Reimplement that demux — a singleton session store without it will bleed one
session's `agent_chunk`s into another's transcript.

Delivery is fan-out to **every** live conn at `(peer, room)` except the sending
conn (`registry.rs:246-268`, skip-sender by `conn_id`). That is how a second
Owner device sees the first device's traffic without echoing its own.

### `ct` size ceiling

`outer.rs:22-46, 60-74`:

- Env var `RELAY_MAX_CT_MIB`, integer MiB, read **once** and memoized. Invalid /
  zero / absent ⇒ `DEFAULT_MAX_CT_MIB = 4`, i.e. **4 MiB = 4 194 304 bytes**.
- The check is `ct.len() * 3 / 4 > max_ct_bytes` — an *estimate* from the
  base64 string length, computed **without decoding**. Integer arithmetic, so a
  base64 string of `L` chars passes iff `L * 3 / 4 <= 4194304`, i.e. up to
  `L = 5 592 405` characters (`5592405 * 3 / 4 == 4194303`).
- Budget client-side against the **base64 length**, not the decoded length, to
  match the relay's arithmetic exactly.
- Images ride *double* base64 (inner `user_message.images[].data` is base64,
  then the whole inner JSON is base64'd into `ct`) ⇒ roughly `1.333 × 1.333 ≈
  1.78 ×` the raw JPEG. Keep attachments under ~1.5 MB of JPEG.

---

## 2. Control frames — outbound (client → relay)

All four subscribe/check frames share one shape: `{type, peers: [String]}`.
`peers` is parsed generically at `peer.rs:212-220`: non-array or absent ⇒ empty
vec; non-string elements are silently skipped.

Every entry of `peers` is used as a **raw HashMap key** against `peer_id`
(`presence.rs:35-56`, `rooms.rs:130-149`, `registry.rs:218-221`). It must be
**base64 STANDARD with padding**. See Traps §T1.

```json
{"type":"subscribe_presence",   "peers":["kZ7c…4h8=","Ab3F…9x0="]}
{"type":"unsubscribe_presence", "peers":["kZ7c…4h8="]}
{"type":"presence_check",       "peers":["kZ7c…4h8="]}
{"type":"subscribe_rooms",      "peers":["kZ7c…4h8="]}
{"type":"unsubscribe_rooms",    "peers":["kZ7c…4h8="]}
{"type":"rooms_check",          "peers":["kZ7c…4h8="]}
```

| Frame | Semantics | Relay code |
|---|---|---|
| `subscribe_presence` | **Replaces** the whole subscription set (not additive). Empty array = unsubscribe from everything. Then immediately backfills a `peer_online` for each listed peer that is currently online. | `peer.rs:224-230`, `presence.rs:35-56`, `registry.rs:145-152` |
| `unsubscribe_presence` | Removes just those peers. Empty array = no-op. | `peer.rs:231-233` |
| `presence_check` | One-shot `presence` snapshot for the listed peers. Does **not** change the subscription. **Deduped per connection** — see T4. | `peer.rs:234-256` |
| `subscribe_rooms` | Replaces the whole rooms-subscription set. Empty array = unsubscribe all. **Sends NO snapshot back** — unlike `subscribe_presence`. | `peer.rs:259-261`, `rooms.rs:130-149` |
| `unsubscribe_rooms` | Removes just those peers. | `peer.rs:262-264` |
| `rooms_check` | Emits **one `rooms` frame per listed peer**. Does not change the subscription. **Deduped per (conn, peer)** — see T4. | `peer.rs:265-287` |

The asymmetry (`subscribe_presence` backfills, `subscribe_rooms` does not) is
why the Flutter client always sends all four together
(`connection_manager.dart:338-350`). Do the same:

```
subscribe_presence(peers) ; subscribe_rooms(peers)
presence_check(peers)     ; rooms_check(peers)      // only if peers is non-empty
```

### `room_meta_update` (outbound patch)

`peer.rs:299-344`. Producer reference: `relay_client.ts:58-71`,
`index.ts:340 / 365-370 / 383`.

```json
{ "type": "room_meta_update",
  "room_id": "019ffb64-1c3e-7a91-b0d2-6f2a1c9e77aa",
  "meta": { "name": "backend", "name_rev": 1780000000001 } }
```

| Field | Required | Default |
|---|---|---|
| `room_id` | no | the **sender's own** `hello.room_id` (`peer.rs:299-304`) |
| `meta` | no | absent/non-object ⇒ every patch field is "absent" ⇒ empty patch |

Only these five keys are read out of `meta` (`peer.rs:308-333`):
`model`, `thinking`, `working`, `name`, `name_rev`. Anything else in `meta` is
**silently ignored** — you cannot patch `cwd`, `role`, `session_id`,
`workspace_path` or `started_at` at all.

The patch applies to `(sender_peer_id, room_id)` only (`registry.rs:284-292`).
**A peer can only patch its own rooms.** An iOS client sending this frame would
patch a room under *its own* Owner key, not the Pi's — which does not exist,
so the relay logs `"room_meta_update for unknown (peer, room), dropping"` and
nothing happens. To rename a session you send the inner `session_rename`
message to the Pi (see spec 03 / `PROTOCOL.md` "App actions"); the Pi then
issues this frame. The Flutter client never emits `room_meta_update` — verified
by grep over `app/lib/`. **iOS must not emit it either.**

---

## 3. Control frames — inbound (relay → client)

### 3.1 `peer_online`

`registry.rs:128` (transition emit) and `registry.rs:148` (subscribe backfill).

```json
{"type":"peer_online","peer":"kZ7c…4h8="}
```

No `since_ts`. Fires only on a genuine **0 → 1** conn transition for that peer
(`registry.rs:96-98, 121-136`); a second device of the same peer connecting
produces nothing. The backfill path re-emits it unconditionally for
already-online peers, so **you will receive duplicates** — dedupe on your side
(`connection_manager.dart:626-632` does).

### 3.2 `peer_offline`

`registry.rs:202-206`. Fires only on **N → 0**.

```json
{"type":"peer_offline","peer":"kZ7c…4h8=","since_ts":1780000000123}
```

`since_ts` is epoch **milliseconds**, always present on this frame.

### 3.3 `presence`

`peer.rs:238-242` + `presence.rs:21-26, 94-116`. Reply to `presence_check`.

```json
{"type":"presence","states":[
  {"peer":"kZ7c…4h8=","online":true, "since_ts":null},
  {"peer":"Ab3F…9x0=","online":false,"since_ts":1780000000123}
]}
```

`PeerPresence` has **no** `skip_serializing_if`, so `since_ts` is always a
present key, explicitly `null` when the peer is online (`presence.rs:104-108`).
`since_ts` is non-null only for an offline peer the relay has *seen* disconnect
since process start — it is in-memory only, so it is `null` for a peer that was
already offline when the relay booted.

`states` preserves the order of your request array and contains **one entry per
requested peer**, including peers the relay has never heard of (`online:false,
since_ts:null`).

```swift
struct PeerPresence: Decodable { let peer: String; let online: Bool; let sinceTs: Int64? }
```

### 3.4 `rooms`

`peer.rs:268-272` + `registry.rs:226-237`. Reply to `rooms_check`, **one frame
per requested peer**.

```json
{"type":"rooms","peer":"kZ7c…4h8=","rooms":[ <RoomMeta>, <RoomMeta> ]}
```

`rooms` is a flat array of full `RoomMeta` objects (§4). It is the
**authoritative live set** for that peer: a room absent from the array has no
live connection. An unknown peer yields `"rooms": []` — treat that as "all rooms
dead", not as "no information".

### 3.5 `room_announced`

`registry.rs:107-119`. Fires once, when the **first** connection opens a
`(peer, room)` pair. Requires at least one `subscribe_rooms` subscriber for that
peer, otherwise it is not built at all.

Payload = the serialized `RoomMeta` **flattened at the top level**, plus two
injected keys:

```json
{ "type": "room_announced",
  "peer": "kZ7c…4h8=",
  "room_id": "019ffb64-1c3e-7a91-b0d2-6f2a1c9e77aa",
  "session_id": "019ffb64-1c3e-7a91-b0d2-6f2a1c9e77aa",
  "workspace_path": "/Users/x/proj",
  "name": "backend",
  "name_rev": 1780000000000,
  "cwd": "/Users/x/proj",
  "model": "claude-sonnet-4.5",
  "thinking": "high",
  "working": false,
  "started_at": 1780000000456 }
```

There is **no `meta` sub-object** on this frame from the current relay. The
Flutter parser reads both flat and `meta.*` nested
(`protocol.dart:27-64`) purely as forward-compat paranoia against an older
relay build. iOS should read the flat form and may keep the nested fallback;
it is dead weight against `relay/src/` as it stands today.

### 3.6 `room_ended`

`registry.rs:186-192`. Fires once, when the **last** connection at a
`(peer, room)` closes.

```json
{"type":"room_ended","peer":"kZ7c…4h8=","room_id":"019ffb64-…","since_ts":1780000000999}
```

`since_ts` = epoch ms of the unregister. **Do not delete the session from your
store.** The Flutter client only removes the room from its *live* set and keeps
the tile (greyed) — `connection_manager.dart:723-732`. Post-plan-61 a rename
never produces `room_ended`, so `room_ended` genuinely means "process gone".

### 3.7 `room_meta_updated`

`registry.rs:351-386`. Broadcast to `subscribe_rooms` subscribers of that peer
after a successful `room_meta_update`.

```json
{ "type": "room_meta_updated",
  "peer": "kZ7c…4h8=",
  "room_id": "019ffb64-…",
  "meta": { "model":"claude-sonnet-4.5", "thinking":"high", "working":true,
            "name":"backend", "name_rev":1780000000001 } }
```

Critical properties, all provable from `registry.rs:353-375`:

- `meta` here is **not the patch you sent**. It is the relay's **post-patch
  snapshot of the five mutable fields only**. `cwd`, `session_id`,
  `workspace_path`, `role`, `started_at` are **never** in it.
- `working` is **always present** (non-nullable bool, `registry.rs:362-365`).
- `model`, `thinking`, `name`, `name_rev` are present **iff currently non-null**
  (`if let Some(...)` guards). Absence therefore means "currently null", but the
  consumer contract is *preserve*, not *clear* — see Trap T5.
- Suppressed entirely when `RoomMetaPatch::is_empty()` (`registry.rs:346-349`,
  `rooms.rs:100-105`): no `model`, `thinking`, `working`, `name` key in the
  patch ⇒ no broadcast. **`name_rev` alone does not count as content.**
- A **rejected** (stale-`name_rev`) name patch still broadcasts, carrying the
  *winning* name and rev. That is the resync mechanism.

Consumer rule (mirrors `protocol.dart:88-113` +
`connection_manager.dart:730-799`): for each of `model` / `thinking` / `name`,
`meta.containsKey(k)` decides set-vs-preserve; the *value* may be a JSON `null`,
which means clear. For `working`, `nil` means preserve.

```swift
struct RoomMetaUpdated {
    let peer: String, roomID: String
    let model: Patch<String?>      // .absent | .set(String?)
    let thinking: Patch<String?>
    let name: Patch<String?>
    let working: Bool?             // nil == absent == preserve
    let nameRev: Int64?
}
enum Patch<T> { case absent; case set(T) }
// Decode with a keyed container + `contains(key)` before `decodeIfPresent`.
// Swift's `decodeIfPresent` collapses absent and null — you MUST call
// `container.contains(.model)` separately.
```

### 3.8 `transport_error`

`peer.rs:414-439`. Emitted **to the sender**, on its own socket, when an outer
envelope's `(peer, room)` destination has no live connection
(`registry.forward` returned `false`).

```json
{"type":"transport_error","reason":"offline","peer":"kZ7c…4h8=","room_id":"019ffb64-…"}
```

- `peer` / `room_id` are the **destination you addressed**, echoed verbatim from
  your envelope (so `room_id` is `"main"` if you omitted `room`).
- `reason` is `"offline"` — the only value this path ever produces. Treat it as
  an open string.
- **Scoped to a destination, not to a message.** The outer envelope carries no
  message id and `ct` is opaque, so the relay cannot name which message failed.
  Fail *everything outstanding* for that `(peer, room_id)` and mark the room
  offline immediately (`connection_manager.dart:800-817`).
- Note the naming collision: `handlers/pi_forward.rs` has a *different*
  `transport_error` — an inner `body.type` inside a `pi_envelope_in`, with
  reasons `offline | not_authorized | bad_envelope`
  (`pi_forward.rs:258-273`). That is the Pi→Pi path, which **this fork does not
  use** (`PROTOCOL.md`, "Nota sobre `pi_envelope`"). Ignore it; only the
  top-level control frame above matters.

### Frames the relay never sends

`hello` is not acked (`relay_client.ts:271-273`). There is **no** `error` frame
and no `room_already_open` code anywhere in `relay/src/` (grep: zero hits) —
`RoomAlreadyOpenError` in `relay_client.ts:79-89` and the `challenge.type ===
"error"` branch at `relay_client.ts:250-256` are dead code against the current
relay, which happily accepts N conns at one `(peer, room)`
(`registry.rs:18-31`). **Rust wins: do not implement that error path.**

---

## 4. `RoomMeta` — the full post-plan-61 field set

Rust definition: `relay/src/rooms.rs:6-62`. Populated from `hello.room_meta` at
`peer.rs:84-157`. Producer type: `relay_client.ts:29-56`.

| JSON key | Type | Present in `room_announced` / `rooms`? | Source | Relay behaviour |
|---|---|---|---|---|
| `room_id` | string | **always** | `hello.room_id`, default `"main"` (`peer.rs:88-91`) | opaque key; **never** taken from `room_meta` |
| `session_id` | string | iff non-null | `hello.room_meta.session_id` (`peer.rs:119-122`) | opaque, stored, re-broadcast, never interpreted |
| `workspace_path` | string | iff non-null | `hello.room_meta.workspace_path`, **falling back to `cwd`** (`peer.rs:123-130`) | canonical `realpath(cwd)` |
| `name` | string | iff non-null | `hello.room_meta.name` (`peer.rs:93-96`) | patchable, `name_rev`-gated |
| `name_rev` | int64 | iff non-null | `hello.room_meta.name_rev` (`peer.rs:131-133`) | compared only, never generated |
| `role` | string | iff non-null | `hello.room_meta.role` (`peer.rs:136-139`) | `"control"` ⇒ gateway room; **not patchable** |
| `cwd` | string | iff non-null | `hello.room_meta.cwd` (`peer.rs:97-100`) | legacy twin of `workspace_path`; **not patchable** |
| `model` | string | iff non-null | `hello.room_meta.model` (`peer.rs:101-104`) | patchable |
| `thinking` | string | iff non-null | `hello.room_meta.thinking` (`peer.rs:105-108`) | opaque string, patchable. Values: `off\|minimal\|low\|medium\|high\|xhigh` (`PROTOCOL.md`) |
| `working` | bool | **always** (`rooms.rs:60`, no skip) | `hello.room_meta.working`, non-bool/absent ⇒ `false` (`peer.rs:109-112`) | patchable, no null state |
| `started_at` | int64 | **always** | **the relay's own clock at register time** (`peer.rs:140-143`) | see T3 |

Nullable fields carry `#[serde(skip_serializing_if = "Option::is_none")]`
(`rooms.rs:18,25,29,38,43,45,48,53`), so on the wire **absent means null**. The
relay never emits an explicit `null` in `RoomMeta`; `null` only appears inside
a `room_meta_update.meta` you or the Pi send.

`hello.room_meta` field extraction is per-field and type-checked with
`as_str()` / `as_bool()` / `as_i64()`: a wrong-typed value degrades to
`None`/`false` rather than failing the connection.

### Merge-patch semantics, per field

The patch model is `RoomMetaPatch` (`rooms.rs:64-91`), a two-level `Option`:
outer `None` = key absent = **preserve**; outer `Some(inner)` where inner is
`None` = explicit JSON `null` = **clear**; `Some(Some(v))` = **set**.

| Field | key absent | explicit `null` | value set |
|---|---|---|---|
| `model` | preserve | clear to null (`peer.rs:308-310`) | set |
| `thinking` | preserve | clear to null (`peer.rs:311-313`) | set |
| `name` | preserve | clear to null (`peer.rs:321-323`) | set — **subject to the `name_rev` gate** |
| `working` | preserve | **preserve** — `and_then(as_bool)` collapses `null` and absent (`peer.rs:314-316`); `false` *is* the off state (`rooms.rs:76-79`) | set |
| `name_rev` | no stored change unless a `name` is also accepted | **preserve** — `and_then(as_i64)` collapses null (`peer.rs:324-326`) | ordering input only |
| `room_id`, `session_id`, `workspace_path`, `role`, `cwd`, `started_at` | — | — | **not patchable at all**; only `hello` sets them |

### The `name_rev` gate

`registry.rs:306-311`, decided **once per update**, against the *first* conn's
stored rev, then applied to every conn at that key:

```rust
let stored_rev = v.first().and_then(|(_, m, _)| m.name_rev);
let name_accepted = match (patch.name.as_ref(), patch.name_rev, stored_rev) {
    (None, _, _)                        => false,  // no name in patch
    (Some(_), Some(incoming), Some(stored)) => incoming > stored,  // STRICTLY greater
    (Some(_), _, _)                     => true,   // either side omits a rev → accept
};
```

Truth table:

| patch has `name` | patch `name_rev` | stored `name_rev` | accepted |
|---|---|---|---|
| no | any | any | no (and `name_rev` alone never broadcasts) |
| yes | absent | any | **yes** (trusted) |
| yes | present | absent | **yes** (first rev seen wins) |
| yes | 100 | 100 | **no** (equal is rejected) |
| yes | 99 | 100 | no |
| yes | 101 | 100 | yes |

`name_rev` is written only when the name is accepted **and** the patch supplied
a rev (`registry.rs:322-329`) — accepting a rev-less name leaves the stored rev
untouched, so the next replay of an old rev can still lose to it.

Revision minting is the **Pi's** job (`index.ts:274-287`): seeded from
`Date.now()` and forced strictly increasing, so it survives process restarts.
The relay only compares. **iOS never mints a `name_rev`**; it echoes the last
one it saw as `rev` inside the inner `session_rename` message
(`protocol.dart:915-923`).

Apply the identical gate to your local cache when consuming
`room_meta_updated` — `connection_manager.dart:765-783` does, and skipping it
lets a second Owner device drag the label backwards.

---

## 5. The `ctrl` room

- `room_id` is the literal string `"ctrl"` (`pi-extension/src/protocol/control_wire.ts:19`,
  `app/lib/protocol/protocol.dart:933`). Reserved: it is neither a UUID nor a
  12-char digest, so it cannot collide with a chat room
  (`control_wire.test.ts:16-18`).
- `room_meta.role = "control"` (`control_wire.ts:22`, `gateway.ts:114-122`).
- The gateway registers with the **same Pi-key** as the chat sessions, so it is
  the *same* `peer_id` with a different `room_id`.
- Client obligations: never render a `role == "control"` room as a chat tile;
  exempt `room == "ctrl"` from your inbound room demux
  (`ws_transport.dart:104-111`) or every gateway reply will be discarded as a
  room mismatch; address control RPCs with `sendToRoom(ct, "ctrl")` **without**
  moving your active chat room (`ws_transport.dart:220-234` — repointing the
  active room silently relocates the user's conversation).

---

## 6. Traps

### T1 — base64url vs standard, and where each is legal (the recurring bug)

`app/lib/data/transport/epk_encoding.dart:1-16` documents four prior
regressions here. The rule:

| Place | Variant | Enforced by |
|---|---|---|
| `hello.pubkey` | **any** of standard/url-safe × padded/unpadded — normalized | `identity.rs:14-30` |
| `hello.sig`, `challenge.nonce` | STANDARD (`base64::STANDARD`) | `challenge.rs:49, 84` |
| `peer_id` the relay derives and echoes | STANDARD **with padding** | `peer.rs:80` |
| envelope `peer` | **STANDARD with padding — no normalization** | `registry.rs:254` (`(dest_peer.to_string(), …)` as a raw key) |
| `peers[]` in every subscribe/check frame | **STANDARD with padding — no normalization** | `presence.rs:46-52`, `rooms.rs:139-145`, `registry.rs:218-221` |
| `ct` | STANDARD (padded) | Dart `base64.encode` / Node `Buffer.toString("base64")` |
| QR payload / on-device pairing storage (Flutter) | base64url, **unpadded** | `epk_encoding.dart:38-59` |

`identity.rs` normalization applies **only to `hello.pubkey`**. Everywhere else
the string is a raw hash-map key. A url-safe `peer` in an envelope produces a
`transport_error: offline` even though the Pi is online; a url-safe entry in
`peers[]` produces a subscription that never fires — silently, forever, with
zero diagnostics.

Also note `identity.rs:15-19`: an encoding that mixes `+/` and `-_` is
**rejected outright**, so "just replace the characters" fixups must be total,
not partial.

**iOS:** hold peer keys as `Data` (32 bytes) internally, and have exactly one
`var wireKey: String { data.base64EncodedString() }` (Foundation's default is
standard + padding). Never let a url-safe string reach the transport layer.
Mirror `epk_encoding.dart`'s single-choke-point discipline.

### T2 — `room_id` is not globally unique, and must never be a lone key

`PROTOCOL.md` §"Unicidade do `room_id`" and `pi-extension/src/rooms.ts:92-120`:
the id is unique **per machine only**. Every persistent key must be
`(peer_id, room_id)`. Two machines emitting the same id is harmless *only*
because every store is already scoped by the Pi-key. Any new cache keyed by
`room_id` alone is a cross-machine collision waiting to happen. The relay itself
keys by the tuple (`registry.rs:15`).

Corollary: `room_id == session_id` post-plan-61, but a pre-plan-61 Pi still
announces `sha256(cwd[,name])[:12]` and omits `session_id`
(`rooms.ts:122-130`). **The signal that a room is stable is the *presence* of
`session_id`, not its value.** Do not compare `session_id == room_id` as a
feature test beyond that.

### T3 — `started_at` is re-stamped on every reconnect

`peer.rs:140-143`: it is `SystemTime::now()` **on the relay**, at registration —
not the Pi's session start, not a stable property of the session. Every WS
reconnect (NAT drop, laptop sleep, relay restart) mints a new value.

- **Never use it as a key.**
- **Never sort by it** — a flaky network reorders your session list under the
  user's finger. That is literally the "as sessões pulam" bug class plan 61
  exists to kill.
- It is also **relay wall-clock**, not device wall-clock: unusable for
  cross-device ordering.
- Sort by `workspace_path` then `session_id` (stable), or by locally-recorded
  last-activity. Not by `started_at`, not by list position, not by `name`.

### T4 — `presence_check` / `rooms_check` are NOT request-response

`peer.rs:247-255` and `peer.rs:277-286` keep per-connection caches
(`last_presence_resp: Option<String>`, `last_rooms_resp: HashMap<peer, String>`)
and **silently suppress a reply byte-identical to the previous one** on that
connection. Ask twice with nothing changed in between and you get **exactly one
answer**.

So: never `await` a `presence_check`/`rooms_check` with a completion handler or
a timeout — it will hang on the second call forever. These are hints into a
state stream, not RPCs. Drive your UI from the accumulated cache, refreshed by
pushes, and treat checks as best-effort nudges. (The suppressed replies are
counted in the relay's metrics, not surfaced to you.)

The cache is per-connection, so a reconnect resets it and the first check after
reconnect always answers.

### T5 — you cannot observe a `model` / `thinking` being cleared

`room_meta_update` can set `model: null` and the relay does store `None`
(`peer.rs:308-310`, `registry.rs:313-315`). But the broadcast omits any field
that is currently null (`registry.rs:354-359`), and every consumer treats an
absent key as **preserve** (`protocol.dart:90-92`,
`connection_manager.dart:747-748`). Net effect: **a clear is applied on the
relay but is invisible to clients**, which keep showing the stale model until a
`room_announced` or a `rooms` snapshot re-seeds them. Do not build UI that
depends on observing a clear. This is a genuine relay-side gap, not a client
bug — do not "fix" it in the iOS client by treating absent as null, or every
`working`-only ping will wipe the model badge.

### T6 — Swift `decodeIfPresent` collapses absent and explicit-null

The whole merge-patch contract turns on that distinction. `decodeIfPresent`
returns `nil` for both. You must call `container.contains(.key)` explicitly
before decoding, or model each field as `Patch<T>` (§3.7). The Flutter client
carries `hasModel` / `hasThinking` / `hasName` booleans for exactly this reason
(`protocol.dart:88-113`), and the `hasName` default is deliberately `false`
while the older two default to `true` (`protocol.dart` `RoomMetaUpdated` docs) —
because most updates are `working` churn and a `true` default would read every
one of them as a rename-to-null.

### T7 — a top-level `type` on your envelope makes it vanish

`peer.rs:211` checks `frame.get("type").and_then(as_str)` **before** envelope
parsing. Any envelope carrying a string `type` is treated as a control frame,
matches no arm, and is dropped with `"unknown control frame type, dropping"` —
no error to the sender, no `transport_error`. The inner message's `type` lives
*inside* `ct`, base64'd, where the relay cannot see it. Keep it that way.

### T8 — an oversized `ct` is dropped in total silence

`peer.rs:381-384`: a `ParseError::TooLarge` (or `InvalidJson`) is logged and the
frame is discarded. **No `transport_error`, no close, no ack.** This is the
original "app stuck at sending…" bug (`outer.rs:24-29`). Enforce the ceiling
client-side, against the base64 length, before you send.

### T9 — `room_ended` does not mean "session deleted", and a rename never emits it

Post-plan-61 a rename is a `room_meta_updated` on the **same** `room_id`
(`rooms.rs:80-87`). If you ever see `room_ended` + `room_announced` under a new
id for what the user perceives as one session, you are talking to a pre-plan-61
Pi. Keep the session row on `room_ended`; just mark it not-live.

### T10 — head/tail inconsistency in the relay's own meta reads

With two conns at the same `(peer, room)` — two Owner devices, or a Pi
reconnecting before the old conn is reaped — `rooms_of` reports the meta of the
**last-registered** conn (`registry.rs:229-234`, `v.last()`), while the
`name_rev` gate reads the **first** conn's stored rev (`registry.rs:306`,
`v.first()`). The patch loop then writes every conn, so they reconverge on the
next accepted patch — but a `rooms` snapshot taken in between can report a name
older or newer than the one the gate is comparing against. Do not build
invariants on "the relay's snapshot and the relay's gate agree". Trust
`room_meta_updated` as the ordering authority and let a later snapshot
overwrite.

### T11 — subscription lifetime is asymmetric across reconnects

`peer.rs:464-465` clears **room** subscriptions on every conn close, but
presence subscriptions survive until the peer's *last* conn drops
(`registry.rs:212-213`). After any reconnect, re-send `subscribe_rooms` or you
will get no `room_announced` / `room_ended` / `room_meta_updated` at all — a
silent, permanent dead UI with a perfectly healthy socket.

---

## 7. Suggested Swift surface

```swift
// ── Outer envelope ────────────────────────────────────────────────────────
struct OuterEnvelope: Codable {
    let peer: String            // STANDARD base64, padded — see T1
    let room: String            // decode: defaults to "main" when absent
    let ct: String              // STANDARD base64 of inner JSON
}

// ── Inbound control frames ────────────────────────────────────────────────
enum ControlInbound {
    case peerOnline(peer: String)
    case peerOffline(peer: String, sinceTs: Int64)
    case presence(states: [PeerPresence])
    case rooms(peer: String, rooms: [RoomMeta])
    case roomAnnounced(peer: String, meta: RoomMeta)     // meta is FLAT in the frame
    case roomEnded(peer: String, roomID: String, sinceTs: Int64)
    case roomMetaUpdated(RoomMetaUpdated)
    case transportError(peer: String, roomID: String, reason: String)
    case unknown(type: String)                           // forward-compat: ignore
}

struct RoomMeta: Decodable, Hashable {
    let roomID: String                  // "room_id"        — always
    let sessionID: String?              // "session_id"     — presence = stable-id signal
    let workspacePath: String?          // "workspace_path"
    let name: String?
    let nameRev: Int64?                 // "name_rev"
    let role: String?                   // "control" ⇒ gateway room, never a chat tile
    let cwd: String?
    let model: String?
    let thinking: String?               // open string; do not make it a closed enum
    let working: Bool                   // always present; decode with `?? false`
    let startedAt: Int64                // "started_at" — NEVER a key, NEVER a sort key (T3)
}
```

- `CodingKeys` explicit snake_case, or a `.convertFromSnakeCase` decoder — but
  note `.convertFromSnakeCase` maps `room_id` → `roomId`, so keep the
  `roomID`-style property names consistent with whichever you choose.
- `thinking` and `reason` stay `String`. The relay treats both as opaque
  (`rooms.rs:50-52`); a closed Swift enum will start throwing the day a new
  level ships.
- Model the outbound side as one `enum ControlOutbound { case subscribePresence([String]) … }`
  with a single encoder, so the "peers must be standard base64" rule lives in
  one place.

---

## 8. Open / undetermined

1. **Whether the relay ever emits a control frame the app cannot parse.**
   `protocol.dart:114` returns `null` for unknown `type` (forward-compat), and
   `ws_transport.dart:134` drops it silently. No versioning/capability
   negotiation exists anywhere in the handshake, so a future relay frame type is
   simply invisible. iOS should log unknown types rather than dropping them
   blind.
2. **`working` at announce time.** The relay always serializes it (`false` when
   unreported), but the Flutter `RoomAnnounced.working` is `bool?` with a
   "legacy relay omitted it" preserve path (`connection_manager.dart:678-681`).
   Against the current relay that path is unreachable; I could not determine
   whether any deployed relay build actually omits it. Keeping the preserve
   behaviour is harmless.
3. **`presence.since_ts` durability.** `last_offline_ts` is a plain in-memory
   `HashMap` (`presence.rs:12-13`) with no eviction and no persistence: it is
   empty after a relay restart and grows without bound otherwise. Whether an
   operator restart is frequent enough for clients to need a fallback "last
   seen" of their own is a product call not answerable from the code.
4. **Metrics visibility.** `metrics.inc_presence_suppressed` /
   `inc_rooms_suppressed` (`peer.rs:248, 278`) count the dedup drops, but I did
   not verify whether they are exposed on any HTTP endpoint — irrelevant to the
   client, noted so nobody expects a suppression signal on the wire.
