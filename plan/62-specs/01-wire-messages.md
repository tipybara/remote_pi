# 62-specs/01 — Inner wire messages (App ↔ Pi)

**Status**: implementation-ready spec for a native iOS client.
**Protocol baseline**: post-plan-61 (`room_id == session_id`, `name_rev`,
`ctrl` room, `transport_error`). Written 2026-08-25 against the three
reference implementations at HEAD (`e0d9e95`).

**Ground truth, in this order of authority:**

1. `pi-extension/src/index.ts` — what the Pi *actually emits and accepts*.
2. `pi-extension/src/protocol/types.ts` — the declared TS union (a few
   places lag behind `index.ts`; noted inline).
3. `app/lib/protocol/protocol.dart` — the Flutter client's parser. Where it
   is stricter/looser than the Pi, the Pi wins; where it *drops* a field the
   Pi sends, the field is still on the wire and iOS should read it.

Nothing in this document should be inferred from `PROTOCOL.md` prose alone —
every claim below carries a `file:line`.

---

## 0. Layer boundaries — what this spec covers

```
Transport      WebSocket / TLS                       ← not here
Control frames presence / rooms / room_meta /        ← not here (spec 02)
               transport_error
Outer          { peer, room, ct }                    ← §1 only, for framing
Inner          ClientMessage / ServerMessage JSON    ← THIS SPEC
```

The relay never parses `ct` (`relay/src/protocol/outer.rs:18`,
`relay/CLAUDE.md`). Everything in §3 onward is opaque to it.

---

## 1. Framing (get this wrong and nothing else matters)

### 1.1 Outer envelope

App → relay (`app/lib/data/transport/ws_transport.dart:213-235`):

```json
{"peer":"<dest Pi-key, STANDARD base64 with padding>",
 "room":"<session_id | \"ctrl\">",
 "ct":"<STANDARD base64 of the inner JSON, UTF-8>"}
```

Pi → relay (`pi-extension/src/transport/peer_channel.ts:64-70`):

```json
{"peer":"<dest Owner-key>","ct":"<base64 inner JSON>"}
```

> The Pi **omits `room` on outbound frames** — deliberately, see the NOTE at
> `peer_channel.ts:65-69`. The relay fills it in on forward
> (`relay/src/handlers/peer.rs:392-396`: it rewrites `peer` to the sender and
> `room` to the *sender's* room). So an iOS client reads `room` off inbound
> envelopes and must not expect the Pi to have set it.
>
> The relay defaults a missing `room` to `"main"`
> (`relay/src/protocol/outer.rs:8-17`).

### 1.2 base64 variant — the recurring bug

| Field | Variant | Reference |
|---|---|---|
| outer `ct` | **standard** (`+/`, `=` padding) | `ws_transport.dart:217`, `peer_channel.ts:65` |
| outer `peer` | **standard**, padded | `ws_transport.dart:314-322`, `epk_encoding.dart:5-6` |
| `user_message.images[].data` | **standard**, no `data:` prefix | `types.ts:232-237`, `PROTOCOL.md:367` |
| QR payload / on-device storage epk | **base64url**, unpadded | `epk_encoding.dart:4` |

Decoders on both sides are lenient (`ws_transport.dart:301-310` tries
standard then url-safe; `Buffer.from(ct,"base64")` accepts both). **Encoders
must not be.** Emit standard base64 with padding on every wire field. See
`app/lib/data/transport/epk_encoding.dart` for the four-plan history of this
bug.

### 1.3 Inner serialization

- One JSON object, UTF-8, **no** wrapping array, **no** JSONL batching inside
  one `ct`.
- The Dart codec appends `\n` (`app/lib/protocol/codec.dart:5`) and the
  channel immediately strips it again with `.trimRight()`
  (`app/lib/data/transport/peer_channel.dart:76`). Net effect on the wire:
  **no trailing newline**. The Pi emits none either
  (`peer_channel.ts:65`). Both sides `JSON.parse`, which tolerates trailing
  whitespace — so a stray `\n` is harmless but pointless. Don't add one.
- Size ceiling: the relay estimates `ct.len() * 3 / 4` and rejects above
  `RELAY_MAX_CT_MIB` (default **4 MiB** decoded)
  (`relay/src/protocol/outer.rs:29,60-74`). Budget for the double base64 of
  images (~1.78× the raw JPEG after inner + outer encoding).

### 1.4 Correlation ids

Every inner request carries `id`; every reply carries `in_reply_to`. Prefixes
used by the Flutter client, all followed by a UUIDv7:

| Prefix | Producer | Reference |
|---|---|---|
| `cli_<uuid7>` | chat traffic (`user_message`, `cancel`, `session_sync`, queued msgs) | `sync_service.dart:1167` |
| `act_<uuid7>` | session actions (`session_*`, `model_set`, `thinking_set`, `list_models`) | `actions_repository.dart:359` |
| `ctl_<uuid7>` | machine-control actions to `ctrl` | `machine_control_repository.dart:107` |
| `ping_<n>` | heartbeat, a plain incrementing counter | `connection_manager.dart:1329` |

The prefixes are **client convention, not protocol** — the Pi echoes `id`
verbatim and never inspects it. But keep them: they make cross-device
collisions impossible and they are what the existing logs grep for. The
UUIDv7 tail matters: per-device counters caused a real bug where Android's
`cli_4` confirmed the iPhone's `cli_4` bubble (`app/lib/protocol/uuid7.dart:1-8`).

### 1.5 Absent vs. explicit `null` (inner messages)

For **inner** messages there is exactly one rule and it is simpler than the
control-frame rule: `JSON.stringify` drops `undefined` keys, so **the Pi never
emits an explicit `null` on an inner frame** except one place:
`ask.tool_call_id` and `ask.title`, which are typed `string | null`
(`types.ts:66,69`) and are genuinely serialized as `null`
(`extension_ui_bridge.ts:307-313`).

The App's encoders use `if (x != null) 'key': x` throughout
(`protocol.dart:641-644,670,746,921-922,986`), so absent means absent.

**Never send an explicit `null` to mean "clear"** on an inner frame. The
clear-by-null semantics belong to `room_meta_update` (a control frame,
`PROTOCOL.md:212`) and do not apply here.

Swift: use `encodeIfPresent` everywhere; `Optional<T> == nil` ⇒ key omitted.

---

## 2. Swift shape strategy (read before the catalogue)

Both directions are **externally tagged unions on `"type"`** with a *flat*
payload — the discriminant sits in the same object as the fields. Swift's
synthesized `Codable` can't do this alone.

Recommended:

```swift
// One enum per direction; decode `type` from a shallow container first,
// then decode the concrete struct from the SAME decoder.
enum ClientMessage: Encodable { case userMessage(UserMessage), /* … */ }
enum ServerMessage: Decodable { case agentChunk(AgentChunk), /* … */ }

private enum TypeKey: String, CodingKey { case type }

extension ServerMessage {
  init(from decoder: Decoder) throws {
    let t = try decoder.container(keyedBy: TypeKey.self)
                       .decode(String.self, forKey: .type)
    switch t {
    case "agent_chunk": self = .agentChunk(try AgentChunk(from: decoder))
    /* … */
    default: self = .unknown(type: t)   // ← MUST exist; see Trap T1
    }
  }
}
```

Use `JSONDecoder.keyDecodingStrategy = .convertFromSnakeCase` **except** inside
the `ask` envelope, which is camelCase on purpose (Trap T7). Because the
strategy is decoder-wide, the cleanest fix is: **do not use the strategy at
all**; write explicit `CodingKeys` on every struct. The protocol has ~40 field
names; explicit keys cost less than one mixed-casing bug.

`args` / `result` are free-form JSON — model them as a small
`AnyJSON: Codable` enum (`.object/.array/.string/.number/.bool/.null`), not
`[String: Any]`.

---

## 3. ClientMessage catalogue (app → Pi)

Declared: `app/lib/protocol/protocol.dart:573-1094` + `1983-2007`;
`pi-extension/src/protocol/types.ts:175-223`.
Dispatched: `pi-extension/src/index.ts:3986-4284`.

| `type` | Reply | Notes |
|---|---|---|
| `pair_request` | `pair_ok` / `pair_error` | pre-pairing only; ignored after (`index.ts:4108-4111`) |
| `user_message` | `user_message` echo (+ stream) | §3.2 |
| `queued_message_set` | `queued_message_state` broadcast | §3.3 |
| `queued_message_clear` | `queued_message_state` broadcast | §3.3 |
| `approve_tool` | **none — silently dropped** | §3.4, Trap T4 |
| `cancel` | `cancelled` or `error` | §3.5 |
| `ping` | `pong` | §3.6 |
| `session_sync` | `queued_message_state` + `session_history` + replayed `extension_ui_request`s | §3.7 |
| `session_new` | `action_ok` / `action_error` | §4 |
| `session_compact` | `action_ok` / `action_error` (+ later `compaction`) | §4 |
| `session_rename` | `action_ok` / `action_error` | §4.3 |
| `model_set` | `action_ok` / `action_error` | §4 |
| `thinking_set` | `action_ok` / `action_error` | §4 |
| `list_models` | `models_list` **or `error`** | §4.4, Trap T5 |
| `extension_ui_response` | none (fire-and-forget) | §6 |
| `workspace_list` / `session_list` / `create_session` / `session_start` / `session_stop` | `action_ok` / `action_error` | §5 — addressed at room `ctrl` |

### 3.1 `pair_request`

```json
{"type":"pair_request","id":"<uuid7>","token":"<QR one-shot token>",
 "device_name":"Jacob's iPhone"}
```

`protocol.dart:714-731`, `types.ts:176`. All three fields required, all
`String`. Sent on the *pairing* transport before a channel exists
(`app/lib/pairing/pair_request_flow.dart:105-112` builds the map by hand, not
via the codec — an iOS client may use the normal encoder).

### 3.2 `user_message`

```json
{"type":"user_message","id":"cli_019f…","text":"run the tests",
 "streaming_behavior":"steer",
 "images":[{"data":"<base64 jpeg>","mime":"image/jpeg"}]}
```

`protocol.dart:616-646`, `types.ts:179-185`, handled `index.ts:4040-4099`.

| JSON key | Swift | Required | Default |
|---|---|---|---|
| `type` | `"user_message"` | yes | — |
| `id` | `String` | yes | — |
| `text` | `String` | yes | — (may be `""` when only images) |
| `streaming_behavior` | `StreamingBehavior?` | no | omit |
| `images` | `[WireImage]?` | no | **omit entirely when empty** |

- `streaming_behavior` has exactly one legal value today: `"steer"`
  (`types.ts:7`, `protocol.dart:598-614`). Parse permissively — the app maps
  anything else to `nil` (`protocol.dart:602-607`).
- `WireImage` is `{ "data": String, "mime": String }` — both required,
  `data` is bare base64 **without** the `data:` URI prefix
  (`types.ts:232-237`, `protocol.dart:580-596`). The Pi maps it to the SDK's
  `{type:"image", data, mimeType}` (`index.ts:711-720`).
- The wire is a *list* but the product sends at most one, and the app's
  decoder only ever reads `images[0]` (`protocol.dart:1326-1331`).
- **Steering is inferred server-side**: if `streaming_behavior` is absent but
  the room is `working`, the Pi treats the message as a steer anyway
  (`index.ts:4055-4057`) and the echo comes back **with**
  `streaming_behavior:"steer"` added (`index.ts:722-732`). An iOS client must
  not assume the echo mirrors what it sent.
- On SDK rejection the Pi replies `error` with `in_reply_to = msg.id` and
  `code:"internal_error"` (`index.ts:4088-4094`) — never `action_error`.

Swift:

```swift
struct WireImage: Codable, Hashable { let data: String; let mime: String }
struct UserMessage: Encodable {
  let type = "user_message"
  let id: String, text: String
  var streamingBehavior: StreamingBehavior?   // key "streaming_behavior"
  var images: [WireImage]?                    // nil ⇒ key omitted
}
```

### 3.3 Queued messages

Text only — images ride only on the immediate `user_message`
(`PROTOCOL.md:378-381`, `index.ts:993` builds the drained message with no
`images`).

```json
{"type":"queued_message_set","id":"cli_…","text":"then push"}
{"type":"queued_message_clear","id":"cli_…","target_id":"cli_…"}
```

`protocol.dart:648-672`, `types.ts:186-187`.

- `queued_message_set` — `id`, `text` required. `id` is the id the message
  will carry **when it is later drained into a real turn**
  (`index.ts:992-993`), so mint it as if it were a `user_message` id.
- **`text` that trims to empty is a delete**, not a set: the Pi routes it to
  `_clearQueuedItems(msg.id)` (`index.ts:4028-4032`).
- `queued_message_clear.target_id` is **optional**; omitted ⇒ clear *all*
  queued items (`index.ts:4037-4038`, `_clearQueuedItems` at `index.ts:944-949`).
- Both are acknowledged only by a broadcast `queued_message_state`
  (§4.7) — there is no per-request ack.

### 3.4 `approve_tool` — dead on arrival

```json
{"type":"approve_tool","id":"cli_…","tool_call_id":"tc_1","decision":"allow"}
```

`protocol.dart:674-691` (`decision` is `decision.name` ⇒ `"allow"` | `"deny"`),
`types.ts:188`. **The Pi ignores it silently and never replies**
(`index.ts:4100-4104`: "Approval gate was removed (plano 10.2 revisado)").
The Flutter app still sends it and mutates its own UI optimistically
(`sync_service.dart:347-371`).

→ **iOS: do not implement the send path.** Keep the type in the enum for
forward-compat only. Never await a reply.

### 3.5 `cancel`

```json
{"type":"cancel","id":"cli_…","target_id":"cli_<the turn's user_message id>"}
```

`protocol.dart:693-704`, `types.ts:189`. Both fields required.

Replies (`index.ts:3997-4019`):

- success → `{"type":"cancelled","in_reply_to":"<id>","target_id":"<target_id>"}`
- no active turn → `{"type":"error","code":"internal_error","in_reply_to":"<id>",
  "message":"No active Pi context to abort"}`
- abort threw → same `error` shape with `"Abort failed: …"`.

`cancel` is handled **before** the `if (!_pi) return` guard
(`index.ts:3997` vs `4024`), so it works even when no Pi session is bound.

### 3.6 `ping`

```json
{"type":"ping","id":"ping_7"}   →   {"type":"pong","in_reply_to":"ping_7"}
```

`protocol.dart:706-712`, `index.ts:4105-4106`.

This is a **Pi-liveness** probe, not a WS keep-alive — the WS layer uses RFC
6455 ping/pong. The Flutter client sends every 25 s and marks the room offline
locally after 3 unanswered, **without** tearing down the socket
(`connection_manager.dart:1245-1286`). Copy that policy; the old
tear-down-on-3-misses behaviour produced permanent `room_already_open`
lockouts.

### 3.7 `session_sync`

```json
{"type":"session_sync","id":"cli_…","limit":30}
```

`protocol.dart:737-748`, `types.ts:191`. `limit` optional; the server clamps
to its own ceiling: `min(requested, REMOTE_PI_SYNC_LIMIT ?? 30)`
(`index.ts:1147-1156,4327-4329`). Asking for more than 30 gets you 30, not an
error. The Flutter client omits `limit` entirely (`sync_service.dart:381`).

Handled **before** the `_pi` guard (`index.ts:3993-3996`), so it answers even
on a half-initialised Pi.

Reply sequence, all to the *asking peer only* (`index.ts:4308-4355`):

1. `queued_message_state` (always, even when empty)
2. `session_history` (always; `session_started_at: 0`, `events: []`, `eos: true`
   when the Pi has no session yet)
3. zero or more `extension_ui_request` frames replaying unanswered ask flows

There is no delta/`since_ts` negotiation. **The reply is a full replacement of
local state** (`protocol.dart:733-736`, plan/16 mirror-cache).

---

## 4. Typed session actions and their replies

Sent to the **session's own room** (`room = session_id`), except
`session_rename`, which is often addressed at a *different* room than the
active chat (§4.3).

`ActionName` union — note the two implementations disagree on membership:

| Wire value | `types.ts:393-398` | `control_wire.ts:22-30` | `protocol.dart:758-786` |
|---|---|---|---|
| `session_new` | ✔ | — | ✔ |
| `session_compact` | ✔ | — | ✔ |
| `model_set` | ✔ | — | ✔ |
| `thinking_set` | ✔ | — | ✔ |
| `session_rename` | ✔ | ✔ | ✔ |
| `workspace_list` | — | ✔ | ✔ |
| `session_list` | — | ✔ | ✔ |
| `create_session` | — | ✔ | ✔ |
| `session_start` | — | ✔ | ✔ |
| `session_stop` | — | ✔ | ✔ |

**Winner: the app's merged enum.** Two *different producers* (the chat Pi and
the supervisor gateway) both emit `action_ok`/`action_error` with `action` set
from their own union, and a client sees both on one socket. Model one enum
with all ten cases plus an `unknown(String)` case.

### 4.1 The action frames

```json
{"type":"session_new","id":"act_…"}
{"type":"session_compact","id":"act_…"}
{"type":"model_set","id":"act_…","provider":"anthropic","model_id":"claude-opus-4-7"}
{"type":"thinking_set","id":"act_…","level":"high"}
{"type":"list_models","id":"act_…"}
```

`protocol.dart:878-892,1060-1093`; `types.ts:196-219`.

- `model_set` — `provider` and `model_id` both required `String`. Resolved
  against the live registry; failure modes are all `action_error`:
  `"model registry unavailable (no active Pi session context)"`,
  `"model \"<p>/<m>\" not in registry"`, `"no auth configured for this model"`
  (`actions/handlers.ts:243-274`).
- `thinking_set.level` ∈ `off | minimal | low | medium | high | xhigh`
  (`types.ts:412-413`, `protocol.dart:792-809`). No validation happens on the
  Pi — it forwards to `pi.setThinkingLevel` and any throw becomes
  `action_error` (`handlers.ts:233-241`). `xhigh` is honoured only by some
  model families; the SDK silently falls back.
- **`session_new` does NOT create a session.** It clears the *context* of the
  same session (`PROTOCOL.md:349-351`). The UI label is "New Context".
  Creating a session is `create_session` on the `ctrl` room (§5).

### 4.2 `action_ok` / `action_error`

```json
{"type":"action_ok","in_reply_to":"act_…","action":"session_compact"}
{"type":"action_error","in_reply_to":"act_…","action":"model_set",
 "error":"no auth configured for this model"}
```

`types.ts:380-381`, emitted by `handlers.ts:134-146`;
parsed `protocol.dart:1634-1692`.

| key | Swift | Required |
|---|---|---|
| `in_reply_to` | `String` | yes |
| `action` | `ActionName` (keep the raw string too) | yes |
| `error` | `String` | `action_error` only |
| *any other key* | passthrough | control-plane replies only (§5) |

**Chat actions carry no payload beyond ok/error.** Only the machine-control
replies add fields (`workspaces`, `sessions`, `session_id`, `display_name`,
`replayed`, `path`, `workspace_id`).

`ActionOk` in Dart keeps the **whole frame** in `data` so new control fields
don't need a new class (`protocol.dart:1642-1666`). Do the same in Swift:
decode the known keys and stash the raw `AnyJSON` object.

### 4.3 `session_rename` — plan 61 optimistic concurrency

```json
{"type":"session_rename","id":"act_…","display_name":"backend",
 "session_id":"019ffb64-…","rev":1780000000000}
```

`protocol.dart:894-924`, `types.ts:198-216`, handled `index.ts:4128-4183`.

| key | Swift | Required | Meaning |
|---|---|---|---|
| `display_name` | `String` | **yes** | new label; trimmed Pi-side |
| `session_id` | `String?` | no, but **always send it** | which session this rename targets |
| `rev` | `Int?` | no, but **always send it** | the `name_rev` **this device last saw** — *not* the new one |

The three refusals, in evaluation order (`index.ts:4129-4172`):

1. `display_name` missing / whitespace-only →
   `action_error … "display_name must be a non-empty string"`.
2. `session_id` present **and** the Pi can resolve its own id **and** they
   differ → `action_error … "session_id does not match this session"`.
   Guards a frame that raced a `/new`, fork or reload
   (`index.ts:4141-4153`).
3. `rev` present **and** the Pi's `name_rev` is present **and**
   `msg.rev < currentRev` → `action_error …
   "stale name revision — this session was renamed elsewhere"`.
   Note the comparison is **strictly less** — an equal `rev` is accepted.

On success the Pi mints the next revision itself
(`_nextNameRev`, `index.ts:283-287`: `now > _nameRev ? now : _nameRev + 1`,
i.e. wall-clock-ms-seeded and monotonic across restarts), applies the label,
and publishes a `room_meta_update` control patch
`{name, name_rev}` (`index.ts:359-371`). The relay re-gates that patch with
its own strictly-greater rule and re-broadcasts the *winning* name on
rejection (`PROTOCOL.md:215-219`).

Client rules:

- `rev` is **read from `room_meta.name_rev`** for that session, not invented.
  Sending a rev you minted yourself will be refused or will lose the next race.
- The frame must be **addressed at the target session's room** without moving
  the connection's active room — renaming from a list view otherwise drags the
  open chat to a different cwd (`actions_repository.dart:100-116`,
  `ws_transport.dart:221-235`, `peer_channel.dart:80-97`). iOS needs the same
  "send to this room, once" primitive.
- **A rename to the identical current name still returns `action_ok` but emits
  no patch and does not bump `name_rev`** (`index.ts:360`: early return when
  `_myRoomMeta?.name === name`). Don't treat `action_ok` as "a new revision
  exists".

### 4.4 `models_list` (reply to `list_models`)

```json
{"type":"models_list","in_reply_to":"act_…",
 "models":[{"id":"claude-opus-4-7","name":"Claude Opus 4.7",
            "provider":"anthropic","reasoning":true,
            "context_window":200000,"vision":true}],
 "current":{ …same shape… }}
```

`types.ts:382,423-440`; built at `handlers.ts:276-307` and `118-130`;
parsed `protocol.dart:1694-1715,814-876`.

`WireModel`:

| key | Swift | Required on wire | App's fallback |
|---|---|---|---|
| `id` | `String` | yes | — (throws if absent) |
| `name` | `String` | yes | — (throws if absent) |
| `provider` | `String` | yes | — (throws if absent) |
| `reasoning` | `Bool` | yes | `false` (`protocol.dart:849`) |
| `context_window` | `Int` | yes | `0` (`protocol.dart:850`) |
| `vision` | `Bool` | yes | `false` (`protocol.dart:851`) |

`current` is **optional** — absent when the Pi cannot resolve the live model
(`handlers.ts:297` passes `undefined`, which `JSON.stringify` drops). Absence
is honest: fall back to the cached `room_meta.model` string
(`protocol.dart:1698-1701`).

**`list_models` does not answer with `action_error`.** On registry failure it
answers `{"type":"error","in_reply_to":"<id>","code":"internal_error",
"message":"…"}` (`handlers.ts:299-306`). A client that only listens for
`models_list` + `action_error` hangs until timeout. See Trap T5.

---

## 5. Machine control plane (room `ctrl`)

Same inner envelope, `room = "ctrl"` (`control_wire.ts:20`,
`protocol.dart:933`). Answered by the supervisor gateway, not by a chat Pi.
Parsed by `parseControlAction` (`control_wire.ts:82-140`), dispatched at
`daemon/gateway.ts:226-292`.

```json
{"type":"workspace_list","id":"ctl_…"}
{"type":"session_list","id":"ctl_…","workspace_id":"a1b2c3d4"}
{"type":"create_session","id":"ctl_…","idempotency_key":"<uuid>",
 "workspace_id":"a1b2c3d4","display_name":"backend","background":true}
{"type":"session_start","id":"ctl_…","session_id":"019f…","idempotency_key":"<uuid>"}
{"type":"session_stop","id":"ctl_…","session_id":"019f…","idempotency_key":"<uuid>"}
{"type":"session_rename","id":"ctl_…","session_id":"019f…","display_name":"x","rev":4}
```

Validation is deliberately strict (`control_wire.ts:70-80`):

- `id` must be a **non-empty, non-whitespace** string; it is `.trim()`-ed.
- `create_session` / `session_start` / `session_stop` **require**
  `idempotency_key` — a missing one is a `ControlParseError`, never defaulted
  (`control_wire.ts:88`). The key must be **stable across retries of one user
  intent**; minting a fresh key per attempt spawns a process per attempt
  (`protocol.dart:961-966`, `gateway.ts:294-331`).
- `create_session.background`: omit it, or send `true`. An explicit `false` is
  **rejected** — `"only background sessions can be created remotely"`
  (`control_wire.ts:107-113`). The Flutter client hardcodes `true`
  (`protocol.dart:989`).
- **No action accepts a path.** Only ids of already-registered workspaces
  (`control_wire.ts:1-13`, plan 61 D5 — tunnelling the UDS `ControlRequest`
  would be user-level RCE).
- Unknown `type` ⇒ `null` ⇒ silently ignored, forward-compat
  (`control_wire.ts:87`, `gateway.ts:206`).
- A frame that fails validation **but** has string `id` + `type` still gets an
  `action_error` so the caller isn't left hanging (`gateway.ts:191-205`).
- Frames from a peer not in `peers.json` are dropped with no reply
  (`gateway.ts:169-179`).

### 5.1 Control `action_ok` payloads — the only replies with data

| Action | Extra keys on `action_ok` | Reference |
|---|---|---|
| `workspace_list` | `workspaces: [{workspace_id, path, display_name}]` | `gateway.ts:229`, `sessions.ts:128-135` |
| `session_list` | `sessions: [{session_id, workspace_id, display_name, mode, desired, created_at, running}]` | `gateway.ts:231-237`, `sessions.ts:61-76` |
| `create_session` | `session_id`, `workspace_id`, `display_name`, `path` | `gateway.ts:252-257` |
| `session_start` | `session_id`, `workspace_id` | `gateway.ts:266` |
| `session_stop` | `session_id`, `workspace_id` | `gateway.ts:278` |
| `session_rename` | `session_id`, `display_name` | `gateway.ts:286-289` |
| *any mutating action, replayed* | `session_id`, **`replayed: true`** | `gateway.ts:308-315` |

`session_list` entry fields: `mode` is `"interactive" | "background"`,
`desired` is `"running" | "stopped"`, `created_at` is epoch-ms, `running` is
computed live by the gateway (`gateway.ts:232-235`).

`RemoteWorkspace` decoding tolerance in the app (`protocol.dart:1043-1047`):
`workspace_id` required; `path` defaults to `""`; `display_name` falls back to
`path` then `""`. Match that leniency.

### 5.2 Idempotency replay semantics

A repeated key returns the **original outcome**, including the original error
(`gateway.ts:302-331`). A *replayed success* returns only
`{session_id, replayed: true}` — **not** the full original payload
(`gateway.ts:311-314`). So a retried `create_session` gives you the session id
but loses `path`/`display_name`. Design the client to need only `session_id`.

### 5.3 `action_ok` ≠ "room is live"

`action_ok` for `create_session`/`session_start` means "spawn requested". The
client must wait for the `room_announced` control frame carrying that
`session_id` before opening a chat, and must **never derive a `room_id`
itself** (`PROTOCOL.md:267-269`, `machine_control_repository.dart:30-35`).

Timeouts observed in the Flutter client: 15 s for chat actions
(`actions_repository.dart:156`), **45 s for control actions**
(`machine_control_repository.dart:59-62`) because a cold `pi` fork loads
settings and an extension before answering.

---

## 6. Extension UI (`ask_user`) request/response envelope

Plan/57. Bridges `@eko24ive/pi-ask` flows to the phone.
`types.ts:16-173`, `extension_ui_bridge.ts`, `protocol.dart:1738-2007`.

### 6.1 `extension_ui_request` (Pi → app)

Five methods, each with its own field set (`types.ts:101-140`):

```json
{"type":"extension_ui_request","id":"<flow_id>","method":"select",
 "title":"Which approach?","options":["Rewrite","Patch"],
 "ask":{ …AskEnrichmentWire… }}

{"type":"extension_ui_request","id":"…","method":"input",
 "title":"…","placeholder":"…","ask":{…}}

{"type":"extension_ui_request","id":"…","method":"confirm","title":"…","message":"…"}
{"type":"extension_ui_request","id":"…","method":"editor","title":"…","prefill":"…"}
{"type":"extension_ui_request","id":"…","method":"notify",
 "message":"Clarification resolved.","notify_type":"warning"}
```

**`id` IS the `flow_id`** — the bridge deliberately reuses it
(`extension_ui_bridge.ts:318-322,330-334`). That is what makes the degraded
(no-`ask`) response path routable.

Today the bridge only ever produces `select`, `input` and `notify`
(`extension_ui_bridge.ts:303-338` + the three `notify` broadcasts at
`:122-129,158-163,200-206`). `confirm` and `editor` are declared for the
generic SDK contract; implement them but expect never to see them.

App-side leniency (`protocol.dart:1910-1926`): unknown `method` → `select`;
missing `id` → `""`; `options` coerced with `.toString()`. `notify_type` is
kept as a raw `String?` (`"info" | "warning" | "error"` today,
`types.ts:139`).

**`notify` semantics the client must implement** (`extension_ui_bridge.ts:149-207`):

| `notify` shape | Meaning |
|---|---|
| id matches an open request, `notify_type` absent, message `"Clarification resolved."` | the flow completed elsewhere → **dismiss the modal** |
| id matches an open request, `notify_type: "warning"` | submit rejected / bridge TTL expired (10 min, `FLOW_TTL_MS`) → **keep the modal open, show a retry hint** |
| id matches nothing | ignore |

`notify` is fire-and-forget: **do not send an `extension_ui_response` for it**
(`protocol.dart:1750-1751`). (The Flutter sheet does send
`cancelled:true` for `notify` at `extension_ui_sheet.dart:194`, which is
harmless — the bridge drops it since no flow matches — but it is not required.)

`AskEnrichmentWire` (`types.ts:64-71`):

```json
{"flow_id":"f_1","tool_call_id":"tc_9","source":"tool","title":"Pick one",
 "questions":[{"id":"q1","label":"Approach","prompt":"Which approach?",
               "type":"single","required":true,
               "presentedType":"single","requestedType":"multi",
               "options":[{"value":"rewrite","label":"Rewrite",
                           "description":"…","preview":"…","freeform":false}]}]}
```

- `tool_call_id` and `title` are `string | null` — the **only inner fields
  that arrive as explicit `null`** (`types.ts:66,69`,
  `extension_ui_bridge.ts:309,311`). Decode as `String?` and accept `null`.
- `source` values seen: `"tool" | "answer" | "answer:again" | "ask:replay"`
  (`types.ts:67`); the app defaults it to `"tool"` (`protocol.dart:1876`).
- Question `type` ∈ `single | multi | preview`. `presentedType` /
  `requestedType` are optional and **camelCase** (Trap T7). Render multi when
  `type == multi || presentedType == multi`
  (`extension_ui_sheet.dart:100-102`).
- `options` may be **empty** — a pure-text question. The bridge then degrades
  the request to `method: "input"` (`extension_ui_bridge.ts:314-327`).
- `option.value` vs `option.label`: the top-level `options: [String]` array
  carries **labels only** (`extension_ui_bridge.ts:306`); the real values live
  in `ask.questions[].options[].value`. See Trap T6.

### 6.2 `extension_ui_response` (app → Pi)

Four legal shapes (`types.ts:145-173`), all `{type, id, …}`:

```json
{"type":"extension_ui_response","id":"<flow_id>","value":"Rewrite"}
{"type":"extension_ui_response","id":"<flow_id>","confirmed":true}
{"type":"extension_ui_response","id":"<flow_id>","cancelled":true}
{"type":"extension_ui_response","id":"<flow_id>",
 "ask":{"flow_id":"f_1","kind":"answer","mode":"submit",
        "answers":{"q1":{"values":["rewrite"],"customText":null,
                         "note":"…","optionNotes":{"rewrite":"…"}}}}}
```

The fourth is the **rich** shape a client that rendered the `ask` envelope
should send: **envelope only, no `value`/`confirmed`/`cancelled`**
(`types.ts:164-173`, `protocol.dart:1969-1977`). The bridge routes on
`ask.kind` **before** reading any discriminator
(`extension_ui_bridge.ts:209-234`).

Cancel: `{"id":…, "cancelled": true}` and/or
`ask: {"flow_id":…, "kind":"cancel"}` — the bridge accepts either
(`extension_ui_bridge.ts:215-224`). The Flutter client sends both when it has
an envelope (`extension_ui_sheet.dart:144-151`).

`AskAnswerWire` encoding rule (`protocol.dart:1943-1950`): **omit empty
parts**. `values` omitted when empty, `customText`/`note` omitted when
null-or-empty, `optionNotes` omitted when empty. An answer with nothing in it
is `{}` — and the Flutter client skips such questions entirely
(`extension_ui_sheet.dart:169`).

pi-ask constraint the client must enforce: **on a non-`multi` question you may
not combine `values` and `customText`** — pick one
(`extension_ui_sheet.dart:165-170`).

`mode` ∈ `"submit" | "elaborate"` (`types.ts:93`); keep it a raw String for
forward-compat (`protocol.dart:1958-1959`).

Degraded path (no `ask` in the response): the bridge looks up the flow by
`msg.id`, takes **question[0]**, and matches `msg.value` against
`option.label`. No match ⇒ it becomes `customText`
(`extension_ui_bridge.ts:236-258`). Duplicate labels ⇒ first wins — inherent
ambiguity, documented at `extension_ui_bridge.ts:244-245`.

There is **no reply** to `extension_ui_response` (`index.ts:4020-4023`
routes it to the bridge and returns). Confirmation arrives asynchronously as a
`notify`. The Flutter sheet arms a 25 s backstop; do the same.

---

## 7. ServerMessage catalogue (Pi → app)

Dispatch table: `protocol.dart:1103-1139`. Declared: `types.ts:282-386`.

### 7.1 Streaming a turn

```json
{"type":"agent_chunk","in_reply_to":"cli_…","delta":"Let me "}
{"type":"agent_done","in_reply_to":"cli_…","usage":{"input_tokens":120,"output_tokens":48}}
```

`types.ts:353-354`, emitted `index.ts:2210-2216,2278-2289`,
parsed `protocol.dart:1142-1164`.

- `in_reply_to` and `delta` are **required** on `agent_chunk` — the Dart parser
  hard-casts (`protocol.dart:1148-1149`). Same for `agent_done.in_reply_to`.
- `agent_done.usage` is optional and **the live path never sends it**
  (`index.ts:2282` emits no `usage`). Usage only appears on `agent_message`
  events inside `session_history` (`index.ts:4633-4634`). Don't build a live
  token counter on `agent_done`.
- `in_reply_to` is the Pi's `_currentTurnId`, which is normally the id of the
  `user_message` that started the turn — but for a turn started in the
  desktop TUI it can be a `sync_<ts>` id or absent, in which case chunks are
  **dropped entirely** (`index.ts:2211`: `if (!_anyPeerActive() || !_currentTurnId) return`).

```json
{"type":"agent_message","in_reply_to":"cli_…","text":"Done.","usage":{…}}
```

`types.ts:355`, `protocol.dart:1433-1446`. All of `in_reply_to` and `text`
required; `usage` optional. Primarily a `session_history` event type; may
arrive standalone as backfill and should then be treated as the final
assistant message for that `in_reply_to`.

### 7.2 `user_input` / `user_message` echo

**Two type strings, one payload.** `protocol.dart:1121` maps
`'user_input' || 'user_message'` to the same `UserInput` class.

```json
{"type":"user_message","id":"cli_…","text":"run the tests",
 "images":[{"data":"…","mime":"image/jpeg"}],"streaming_behavior":"steer"}
```

- `type:"user_message"` — echo of an app-originated message, broadcast to
  **every** attached owner including the sender (`index.ts:722-732`,
  `types.ts:344-350`). `id` is preserved verbatim; that is the dedup key.
- `type:"user_input"` — mirror of text typed in the desktop TUI
  (`types.ts:335`). Declared **without** `images`.
- `id` and `text` are required (`protocol.dart:1420-1421` hard-casts).
- The client renders its own bubble **only on echo**, not optimistically-final:
  the optimistic row stays `pending` until the echo confirms it, with a 20 s
  no-echo reaper (`sync_service.dart:204-212,499-545`).

### 7.3 Tools

```json
{"type":"tool_request","tool_call_id":"tc_1","tool":"edit","args":{…}}
{"type":"tool_result","tool_call_id":"tc_1","result":"…"}
{"type":"tool_result","tool_call_id":"tc_1","error":"ENOENT: …"}
```

`types.ts:359-360`, emitted `index.ts:2222-2243`,
parsed `protocol.dart:1166-1194`.

- No `in_reply_to`. Correlation is by `tool_call_id`.
- `args` is free-form (`Record<string, unknown>`).
- **`result` is always a string on the wire**, never the raw object
  (`_stringifyToolResult`, `index.ts:2238` and the identical call in the
  history mapper at `index.ts:4662` — deliberately, so live == re-sync). The
  Dart type is `dynamic` (`protocol.dart:1185`) but nothing produces a
  non-string. Model it as `String?` in Swift and accept `AnyJSON` defensively.
- `result` and `error` are **mutually exclusive**: exactly one is present
  (`index.ts:2239-2241`). Presence of `error` ⇒ failed.
- **Undocumented enrichment**: for `tool == "edit"` (case-insensitive) the Pi
  injects a synthetic `args.hunks` array the app renders as a diff
  (`index.ts:4395-4431`, consumed at
  `app/lib/ui/chat/widgets/tool_request_card.dart:198-235`):

```json
{"hunks":[{"lines":[{"kind":"context","oldLine":11,"newLine":11,"text":"…"},
                    {"kind":"remove","oldLine":12,"text":"…"},
                    {"kind":"add","newLine":12,"text":"…"},
                    {"kind":"ellipsis"}]}]}
```

`kind` ∈ `context | remove | add | ellipsis`; `oldLine`/`newLine`/`text`
optional per kind (`index.ts:4389-4393`). The key is absent when the Pi could
not read the file. This is real, load-bearing, and in no `.d.ts`.

### 7.4 `error`

```json
{"type":"error","in_reply_to":"cli_…","code":"internal_error","message":"…"}
```

`types.ts:361`, `protocol.dart:1196-1207`.

- `in_reply_to` **optional** — absent when the failure isn't tied to a request
  (`index.ts:2271-2273`).
- `code` and `message` are required Strings. `code` is an **open** union
  (`types.ts:241-251`): known values
  `tool_approval_required | invalid_message | unsupported_type | too_large |
  rate_limited | timeout | internal_error`, plus **`provider_error`**, which is
  emitted (`index.ts:2272-2273`) but not in the declared list. Treat `code` as
  `String`, never as a closed enum.
- The Flutter client special-cases `code.contains('unknown_peer')` as
  "pairing was revoked" (`sync_service.dart:625-630`). Mirror that.

### 7.5 `cancelled`, `pong`, `bye`

```json
{"type":"cancelled","in_reply_to":"cli_…","target_id":"cli_…"}
{"type":"pong","in_reply_to":"ping_7"}
{"type":"bye","reason":"session_replaced"}
```

`bye.reason` ∈ `peer_stop | session_replaced | shutdown`
(`types.ts:442`, parsed `protocol.dart:1730-1735` with an `unknown` fallback).
Emitted at `index.ts:1443` and `index.ts:3195`. It is a terminal
"Pi went offline" signal: stop the retry loop, surface a banner, reconnect
manually (`protocol.dart:1618-1622`).

`cancelled` carries no `error`; it is the success ack for `cancel` (§3.5).

### 7.6 `compaction`

```json
{"type":"compaction","summary":"…","tokens_before":31000,"ts":1780000000000}
```

`types.ts:358`, emitted `index.ts:2336-2350`, parsed `protocol.dart:1451-1462`.

- Live: `summary`, `tokens_before` and `ts` all present (`index.ts:2346`).
- In `session_history`: the `compaction` event has `ts` as the standard event
  timestamp and **no separate `ts` field** (`index.ts:4610-4615`).
- The app tolerates a missing `summary` (→ `""`) and a missing
  `tokens_before`/`ts` (→ `nil`) (`protocol.dart:1457-1461`). TS declares both
  required; the app's leniency wins for a decoder.
- Compaction is bracketed by `working: true/false` `room_meta_update` control
  patches, not by inner frames (`index.ts:2325-2348`).

### 7.7 `queued_message_state`

```json
{"type":"queued_message_state","id":"cli_…","text":"then push",
 "items":[{"id":"cli_…","text":"then push","editable":true,
           "created_at":1780000000000}]}
```

`types.ts:351`, built `index.ts:908-915`, parsed `protocol.dart:1357-1391`.

- `items` is the modern field and is **always present** (possibly `[]`).
- `id`/`text` are legacy top-level mirrors of `items[0]` and are **omitted
  entirely when the queue is empty** (`index.ts:912`).
- `QueuedMessageItem`: `id` (required), `text` (default `""`),
  `editable` (default `true`), `created_at` epoch-ms (default `0`)
  (`protocol.dart:1346-1354`).
- The app **drops items whose `text` is empty** (`protocol.dart:1371`). Do the
  same or you'll render blank rows.
- Decode order: prefer `items` when it is an array (even empty); only fall back
  to `id`/`text` when `items` is absent (`protocol.dart:1364-1390`).
- This frame is a **full replacement** of queue state, broadcast to all owners
  (`index.ts:921-923`).

### 7.8 `steer_consumed`

```json
{"type":"steer_consumed","id":"cli_…"}
```

`types.ts:352`, emitted `index.ts:973-983`. Tells the client the steering
message with that id was absorbed into the running turn, so the "steering…"
label can be cleared (`sync_service.dart:499-500`). `id` required.

### 7.9 `pair_ok` / `pair_error`

```json
{"type":"pair_ok","in_reply_to":"<pair_request id>",
 "session_name":"remote_pi","session_started_at":1780000000000,
 "room_id":"019ffb64-…","session_id":"019ffb64-…",
 "workspace_path":"/Users/x/proj","display_name":"remote_pi",
 "name_rev":1780000000000,
 "harness":{"name":"Pi coding agent","version":"0.9.3"},
 "hostname":"jacobs-mac"}
```

`types.ts:283-333`, emitted `index.ts:2019-2042`.

| key | Required on wire | Notes |
|---|---|---|
| `in_reply_to`, `session_name`, `session_started_at`, `room_id` | yes | `room_id == session_id` post-plan-61 |
| `session_id` | **conditional** | omitted when the Pi still keys its room by the legacy `sha256(cwd[,name])` derivation (`index.ts:2033`). Its **presence**, not its value, is the plan-61 signal (`types.ts:289-297`, `PROTOCOL.md:98-100`) |
| `workspace_path` | yes in practice | always emitted, `canonicalWorkspacePath(cwd)` fallback (`index.ts:2034`) |
| `display_name` | yes in practice | `index.ts:2035` |
| `name_rev` | conditional | omitted when the room meta has none (`index.ts:2036`) |
| `harness` | yes in practice | `{name, version}`; app defaults to `{"Pi coding agent","—"}` when absent (`protocol.dart:1241-1244`) |
| `hostname` | yes in practice | `os.hostname()` |

**Implementation disagreement — the Flutter client silently drops four of
these.** `PairOk.fromJson` (`protocol.dart:1297-1317`) parses only
`in_reply_to`, `session_name`, `session_started_at`, `room_id`, `harness`,
`hostname`; the pairing flow (`pair_request_flow.dart:118-151`) never reads
`session_id` / `workspace_path` / `display_name` / `name_rev`, even though
`PeerRecord` has fields for them (`pairing/storage.dart:66-82`).
**The wire wins — iOS should parse and persist all four**, so it keys by
session from the first frame (which is the stated intent at
`types.ts:289-297` and `PROTOCOL.md:327-330`).

Legacy fallbacks the app applies (keep them):
`session_started_at` non-numeric → `0` meaning "unknown"
(`protocol.dart:1307`); `room_id` absent → `"main"` (`protocol.dart:1311`) —
but distinguish "Pi said main" from "Pi omitted it" by peeking at the raw map,
because only the second case should fall back to the QR's room hint
(`pair_request_flow.dart:127-135`).

```json
{"type":"pair_error","in_reply_to":"…","code":"token_expired","message":"…"}
```

`code` ∈ `token_expired | token_consumed | token_unknown | internal_error`
(`types.ts:1-5`). All three fields required (`protocol.dart:1611-1615`).

---

## 8. `session_history` (reply to `session_sync`)

```json
{"type":"session_history","in_reply_to":"cli_…",
 "session_started_at":1780000000000,
 "events":[ …see below… ],"eos":true,"truncated":false}
```

`types.ts:365-372`, built `index.ts:4308-4342`, parsed `protocol.dart:1472-1496`.

| key | Swift | Required |
|---|---|---|
| `in_reply_to` | `String` | yes (hard cast) |
| `session_started_at` | `Int` (epoch ms) | yes (hard cast) |
| `events` | `[SessionHistoryEvent]` | yes (hard cast) |
| `eos` | `Bool` | yes (hard cast) |
| `truncated` | `Bool` | tolerated absent → `false` (`protocol.dart:1494`) |

The current Pi always sends a **single batch with `eos: true`**
(`index.ts:4335-4342`; the "may arrive in batches" comment at
`protocol.dart:1468-1471` is aspirational). Implement the accumulate-until-`eos`
loop anyway; it costs nothing.

`session_started_at` is the restart detector: a changed value means the Pi
restarted and the local cache must be **replaced**, not appended
(`protocol.dart:1265-1268`). `0` means "no session yet".

`truncated: true` = there were more events than the effective limit and the
**oldest** were dropped. Log only; no UI affordance (plan/16 D1=B).

### 8.1 Event shapes

Every event has `ts` (epoch ms, **required**, hard-cast at
`protocol.dart:1503`) plus `type`. `types.ts:253-280`, mapper
`index.ts:4599-4673`, parser `protocol.dart:1498-1538`.

```json
{"ts":1780000000000,"type":"user_input","id":"sync_1780000000000","text":"…",
 "images":[{"data":"…","mime":"image/jpeg"}]}

{"ts":…,"type":"tool_request","tool_call_id":"tc_1","tool":"edit","args":{…}}

{"ts":…,"type":"tool_result","tool_call_id":"tc_1","result":"…"}
{"ts":…,"type":"tool_result","tool_call_id":"tc_1","error":"…"}

{"ts":…,"type":"agent_message","in_reply_to":"sync_…","text":"…",
 "usage":{"input_tokens":1,"output_tokens":2}}

{"ts":…,"type":"compaction","summary":"…","tokens_before":31000}
```

- **`user_input` ids in history are `sync_<ts>`, not the live `cli_<uuid7>`**
  (`index.ts:4617`). A re-sync therefore *renumbers* every user message. The
  Flutter client handles this by rebuilding the whole box from history and
  preserving only still-`pending` local rows whose id is absent from history
  (`sync_service.dart:698-751`). See Trap T3.
- `agent_message.in_reply_to` in history is the **last** `user_input` id seen
  in a linear scan — an approximation, explicitly acknowledged at
  `index.ts:4594-4597`. Do not build strict threading on it.
- `usage` appears on history `agent_message` only when the SDK message carried
  it (`index.ts:4633-4635`); `{input_tokens, output_tokens}`, both `Int`
  (`types.ts:239`).
- `images` present only when the buffered message had image blocks
  (`index.ts:4622-4629`); the app reads only the first
  (`protocol.dart:1509`).
- `compaction` history events carry **no `ts` field of their own** beyond the
  standard event `ts`, and `tokens_before` defaults to `0` when the SDK didn't
  supply it (`index.ts:4614`).
- Unknown event `type` → the Dart parser **throws**
  (`protocol.dart:1535`), which the channel swallows, **dropping the whole
  `session_history` frame**. iOS must instead **skip the unknown event and
  keep the rest**. See Trap T2.

---

## 9. Traps

> These are the parts that have actually broken. They matter more than the
> happy path.

**T1 — Unknown `type` must not be fatal.**
`ServerMessage.fromJson` throws `UnsupportedTypeException` on any unrecognised
type (`protocol.dart:1137`); the channel catches it and synthesises
`ErrorMessage(code: "unsupported_type")` (`peer_channel.dart:122-128`), and
any *other* decode exception silently drops the frame
(`peer_channel.dart:129-133`). An iOS decoder that throws out of the socket
read loop will kill the connection on the first field the Pi adds. Model an
explicit `.unknown(type:)` case and keep reading.

**T2 — One bad history event kills the whole history.**
`SessionHistoryEvent.fromJson` throws on an unknown event type
(`protocol.dart:1535`) *inside* `SessionHistory.fromJson`
(`protocol.dart:1489-1491`), so the throw propagates and the entire
`session_history` frame is dropped by `_handleFrame`. The user sees an empty
chat, not a partial one. **iOS: decode events with a lossy array — skip
undecodable elements, keep the rest.**

**T3 — Message ids are not stable across a re-sync.**
Live user messages are `cli_<uuid7>`; the same messages come back from
`session_sync` as `sync_<epoch_ms>` (`index.ts:4617`). Any store keyed by
message id must be rebuilt-from-history rather than merged, and any pending
optimistic row must be matched by id-absence, not by id-equality
(`sync_service.dart:698-712`). Also: two user messages persisted in the same
millisecond collide on `sync_<ts>`.

**T4 — `approve_tool` is a no-op with no reply.**
Declared in both protocol files (`types.ts:188`, `protocol.dart:674-691`) and
still sent by the Flutter app (`sync_service.dart:347-351`), but the Pi
ignores it (`index.ts:4100-4104`). Awaiting a reply hangs forever. There is
no approval gate in this fork.

**T5 — `list_models` fails as `error`, not `action_error`.**
`handlers.ts:299-306`. A client demultiplexing only on
`models_list | action_error` will time out on a broken registry. The Flutter
`ActionsRepository` has exactly this hole — its `_onMessage`
(`actions_repository.dart:190-219`) never inspects `ErrorMessage`, so a
`list_models` failure surfaces as a 15 s "timeout" instead of the real
message. **Do better on iOS: match `error.in_reply_to` against the pending map
too.**

**T6 — `options[i]` is a label; `ask.questions[0].options[i].value` is the
value.**
`extension_ui_bridge.ts:306` builds the flat array from `o.label`. A degraded
response must therefore send the **label** in `value`, and the bridge maps it
back (`extension_ui_bridge.ts:246`). A rich response must send the **value**
in `ask.answers[qid].values`. Sending a value where a label is expected
silently becomes a `customText` free-form answer. Duplicate labels ⇒ first
match wins (`extension_ui_bridge.ts:244-245`).

**T7 — The `ask` envelope is camelCase on purpose.**
Frame-level keys are snake_case (`flow_id`, `tool_call_id`, `notify_type`),
but *inside* `ask` the pi-ask schema is mirrored verbatim:
`presentedType`, `requestedType`, `customText`, `optionNotes`
(`types.ts:73-85`, `protocol.dart:1845-1847,1946-1948`). A blanket
`.convertFromSnakeCase` decoding strategy will silently null these four out.
Write explicit `CodingKeys`.

**T8 — `"ctrl"` is a reserved room id and must never be a session key.**
`control_wire.ts:17-20`, `protocol.dart:930-933`. It is neither a 12-char
digest nor a UUID, so it cannot collide — but a client that stores rooms in
one map must exclude it from the chat-tile list (filter on
`room_meta.role == "control"`, `protocol.dart:258`).

**T9 — `room_id` is unique per machine, not globally.**
`PROTOCOL.md:102-129`. Every persistent key must be `(epk, room_id)`, never
`room_id` alone. Two machines emitting the same id is harmless *only* if you
respect this.

**T10 — `session_rename` `rev` is what you last SAW, not what you want.**
`protocol.dart:894-902`, `types.ts:211-214`. The Pi mints the new revision
(`index.ts:283-287`). Sending `currentRev + 1` will pass the Pi's
strictly-less check today but desynchronises you from the relay's own gate.
Read `name_rev` off `room_meta` and echo it.

**T11 — A same-name rename returns `action_ok` with no revision bump.**
`index.ts:360` early-returns when the name is unchanged, so no
`room_meta_update` is emitted and `name_rev` does not move. Don't infer "a
newer revision now exists" from `action_ok`.

**T12 — `create_session` with `background: false` is refused, not coerced.**
`control_wire.ts:107-113`. Omit the key or send `true`.

**T13 — A replayed idempotent `action_ok` carries a reduced payload.**
`gateway.ts:308-315` returns only `{session_id, replayed: true}`. Do not
depend on `path` / `display_name` surviving a retry.

**T14 — `agent_done` never carries `usage` on the live path.**
`index.ts:2282`. Only history `agent_message` events do. A live token meter
built on `agent_done.usage` will always read zero.

**T15 — `tool_result.result` is a pre-stringified string.**
`index.ts:2238,4662`. The Dart type says `dynamic` and the TS type says
`unknown`, but the producer always stringifies so live output matches re-sync
output. Do not JSON-parse it speculatively.

**T16 — `pi-extension/src/protocol/codec.ts` is dead code.**
Its `SERVER_TYPES` set (`codec.ts:3-20`) is missing `action_ok`,
`action_error`, `models_list`, `compaction`, `steer_consumed` and
`user_message`, and nothing outside its own test imports it — the relay path
parses raw JSON in `transport/peer_channel.ts:96-121`. **Do not use it as a
type inventory.** `types.ts` + `index.ts` are the inventory.

**T17 — the Pi omits `room` on its outbound envelopes.**
`transport/peer_channel.ts:65-69`. The relay backfills it
(`relay/src/handlers/peer.rs:392-396`). A client that requires `room` on
inbound frames works only because the relay is in the path.

**T18 — dest-miss is a control frame, not an inner error.**
`{"type":"transport_error","reason":"offline","peer":…,"room_id":…}` arrives
**outside** the `ct` envelope (`relay/src/handlers/peer.rs:429-436`). It is
scoped to a `(peer, room)`, not to a message id — the relay cannot correlate
it, since the outer envelope has no message id. On receipt: fail everything
pending for that `(peer, room)` and mark the room offline immediately
(`protocol.dart:441-455`, `PROTOCOL.md:168-186`).

---

## 10. Disagreement summary

| # | Disagreement | Winner | Action for iOS |
|---|---|---|---|
| 1 | `ActionName`: `types.ts:393-398` (5 values) vs `control_wire.ts:22-30` (6) vs `protocol.dart:758-786` (10) | app's merged enum | one enum, 10 cases + `unknown(String)` |
| 2 | `pair_ok` `session_id`/`workspace_path`/`display_name`/`name_rev` emitted (`index.ts:2033-2036`) but never parsed (`protocol.dart:1297-1317`) | the wire | parse and persist all four |
| 3 | `approve_tool` declared and sent by the app, ignored by the Pi | the Pi | don't send |
| 4 | `list_models` failure: `action_error` (implied by §4) vs `error` (`handlers.ts:300`) | `handlers.ts` | match `error.in_reply_to` against pending actions |
| 5 | `compaction.tokens_before`/`ts`: required in `types.ts:358`, optional in `protocol.dart:1459-1461` | the app's leniency | decode both as optional |
| 6 | `tool_result.result` typed `unknown`/`dynamic`, always a `String` in practice | producer | `String?`, with `AnyJSON` fallback |
| 7 | `codec.ts` `SERVER_TYPES` set is stale and unused | `types.ts` + `index.ts` | ignore `codec.ts` |
| 8 | `session_history` "may arrive in batches" (`protocol.dart:1468`) vs single-batch producer (`index.ts:4335`) | producer today | still implement the `eos` loop |
| 9 | `ActionOk.action` falls back to `.sessionCompact` on an unknown wire value (`protocol.dart:1663`) while keeping `rawAction` | neither — it's a landmine | never switch on the parsed enum without checking the raw string |

---

## 11. What I could not determine from the code

1. **`error.code` full vocabulary.** `types.ts:241-251` lists seven, the code
   emits an eighth (`provider_error`), and the type is explicitly open
   (`string & {}`). There is no exhaustive producer list — I found emitters
   only for `internal_error`, `provider_error`, `unsupported_type` and
   `unknown_peer` (the last inferred from the app's
   `code.contains('unknown_peer')` check at `sync_service.dart:625`; I could
   not find its emitter in this repo — it may come from the relay or an older
   Pi).
2. **Whether `session_list` is ever actually called by a client.**
   `WorkspaceList` and `CreateSession` have repository methods
   (`machine_control_repository.dart:143-175`); `SessionList`, `SessionStart`
   and `SessionStop` exist as `ClientMessage` classes with no caller in
   `app/lib`. Their reply shapes are documented from `gateway.ts` alone —
   untested against a live client.
3. **`confirm` / `editor` extension-UI methods.** Declared
   (`types.ts:110-133`) but no producer exists in this repo — the bridge only
   emits `select`, `input`, `notify`. Their exact field requirements are taken
   from the type declaration, not from observed traffic.
4. **`streaming_behavior` values beyond `"steer"`.** Both sides declare a
   one-member union; both parse permissively. Whether the SDK will grow others
   is not knowable here.
5. **Ordering guarantees between `user_message` echo, `agent_chunk` and
   `tool_request`.** All three go through `_broadcastToActive` on one WS, so
   they are ordered per-connection, but nothing in the code *states* a
   contract — and `_deliverImageUserMessage` (`index.ts:734-781`) awaits a
   preview emit before waking the agent, which can reorder the echo relative
   to a same-instant TUI-originated frame.
6. **What happens to an `extension_ui_response` for an already-resolved flow.**
   `extension_ui_bridge.ts:239-240` returns silently when the flow is gone.
   No frame is sent back, so a client that missed the `completed` notify has
   no way to learn its submit was a no-op except by timeout.
