# Spec 62/04 — Pairing handshake + peer storage (post plan 61)

Implementation-ready specification for a **native iOS client**. Everything below is
grounded in the three reference implementations as they exist on `main` at
2026-08-25 (`e0d9e95`). Where the code and `PROTOCOL.md` disagree, **the code
wins** and the disagreement is called out.

Reference sources (all paths repo-relative):

| Area | File |
|---|---|
| QR build / token | `pi-extension/src/pairing/qr.ts` |
| QR parse | `app/lib/pairing/qr_scanner.dart` |
| `pair_request` send | `app/lib/pairing/pair_request_flow.dart` |
| `pair_request` handle, `pair_ok`/`pair_error` emit | `pi-extension/src/index.ts:1857-2060` |
| Wire types | `pi-extension/src/protocol/types.ts`, `app/lib/protocol/protocol.dart` |
| Pi peer storage | `pi-extension/src/pairing/storage.ts:443-562` |
| Phone peer storage | `app/lib/pairing/storage.dart` |
| Relay auth | `relay/src/auth/challenge.rs`, `relay/src/handlers/peer.rs:36-90` |
| Relay routing | `relay/src/handlers/peer.rs:380-440`, `relay/src/peers/registry.rs:246-268` |
| epk encoding | `app/lib/data/transport/epk_encoding.dart`, `relay/src/identity.rs` |
| Membership blob | `app/lib/data/mesh/mesh_blob.dart`, `mesh_envelope.dart`, `mesh_client.dart` |

---

## 1. Actors and keys

| Key | Alg | Lives | Used in pairing for |
|---|---|---|---|
| **Pi-key** | Ed25519 | Mac keyring (`dev.remotepi.pi` / `longterm-ed25519`), fallback `~/.pi/remote/identity.json` `0600` (`pairing/storage.ts:27-29,81`) | Is the Pi's **relay peer id**; its public half is the QR's `epk` |
| **Owner-key** | Ed25519 | iOS Keychain (iCloud-synced) | The phone's **relay peer id**; signs the relay challenge; signs `mesh_versions` |
| ~~App-key (ephemeral)~~ | — | — | **Does not exist in this fork.** See §12 D1. |

`PROTOCOL.md:41` still lists an "App-key Ed25519 efêmera … RAM do app". No code
creates one. `PairingViewModel.onQrScanned` calls
`_ownerBridge.requireKeyPair()` and passes **the Owner keypair** into the pairing
transport (`app/lib/ui/pairing/viewmodels/pairing_viewmodel.dart:65-67`), the
same key the steady-state connection uses
(`app/lib/config/dependencies.dart:236-258`). iOS must do the same: **one
long-lived Owner key, used from the very first pairing WebSocket.**

---

## 2. End-to-end sequence

```
Mac (pi-extension)                Relay                     iPhone
──────────────────────────────────────────────────────────────────────────
/remote-pi pair
  issueToken() ──► QR: remotepi://pair?t=…&epk=…&n=…&rm=…
                                                     scan / paste
                                                  ┌─ WS connect
                                          ◄───────┤  hello{pubkey=Owner-pk,
                                                  │        room_id:"main"}
                                          ───────►│  challenge{nonce}
                                          ◄───────┤  auth{sig = Ed25519(nonce)}
                                                  └─ registered at (Owner-pk,"main")
        ◄── {peer:Pi-pk, room:"<rm>", ct:b64(pair_request)} ───────────────
  consumeToken()
  addPeer() → ~/.pi/remote/peers.json
        ─── {peer:Owner-pk, ct:b64(pair_ok)} ──────────────────────────────►
                                        (relay rewrites peer→Pi-pk,
                                         room→Pi's registered room id)
                                                     persist PeerRecord
                                                     POST /mesh/<sha256(owner_pk)>
  SelfRevoke poll sees itself listed → stays alive
```

The **same WebSocket** stays open and becomes the chat connection — the Flutter
app "adopts" it (`connection_manager.dart:456-481`); it never reconnects to
finish pairing.

---

## 3. QR payload

### 3.1 Format

Produced by `buildQRUri` (`pi-extension/src/pairing/qr.ts:62-89`):

```
remotepi://pair?t=<token>&epk=<pi-pubkey>&n=<session name>[&rm=<room id>]
```

Concretely (`URLSearchParams` order is insertion order — `t`, `epk`, `n`, then
`rm`):

```
remotepi://pair?t=Zm9vYmFyYmF6cXV4MTIzNA&epk=1sbg3nsX4kRTBmM3XZ_hs4mAujHmbcm7CjfPGkDgpTQ&n=remote_pi&rm=019ffb64-3c21-7a55-9b0e-2f7d1c4a88e1
```

| Param | Required | Produced as | Meaning | Validation the app must do |
|---|---|---|---|---|
| `t` | **yes** | `randomBytes(16).toString("base64url")` — **22 chars, no padding** (`qr.ts:27`) | one-time pairing token | decode base64url → **must be exactly 16 bytes** (`qr_scanner.dart:57`) |
| `epk` | **yes** | `Buffer.from(edPk).toString("base64url")` — **43 chars, no padding** (`qr.ts:81`) | Pi-key public half = the Pi's relay peer id | decode base64url → **must be exactly 32 bytes** (`qr_scanner.dart:58`) |
| `n` | **yes** | `sessionName.slice(0, 80)`, percent-encoded by `URLSearchParams` (`qr.ts:85`) | session display name, shown on the "connecting" screen before `pair_ok` | non-null; no length/charset check |
| `rm` | optional | the Pi's live `room_id` (`index.ts:3071-3072`) | destination room for the `pair_request` envelope | **none — treat as an opaque string** (see Traps T4) |
| `r` | legacy only | removed in plan 14 (`qr.ts:74`) | relay ws URL | if present and `toWsRelayUrl(r) != toWsRelayUrl(configured)` → abort with `relay_mismatch` (`pair_request_flow.dart:80-89`) |

Scheme/host check: `uri.scheme == "remotepi" && uri.host == "pair"`, otherwise
the payload is ignored *silently* (not an error) — the camera keeps scanning
(`qr_scanner.dart:45`, `pairing_viewmodel.dart:50-51`).

The **same string** is offered as copy-paste text for camera-less devices
(`index.ts:3084-3090`, `app/lib/ui/pairing/widgets/paste_qr_sheet.dart`), so the
iOS parser must accept a pasted string identically — including surrounding
whitespace the user may drag in (trim before parsing; the Flutter app does not,
which is a bug you should not clone).

### 3.2 Swift shape

```swift
struct QRPairPayload: Equatable {
    let token: String        // keep the ORIGINAL base64url string; never re-encode
    let epk: String          // ditto — this is the storage key
    let sessionName: String
    let roomId: String?      // `rm`
    let relayURL: String?    // legacy `r`

    var epkBytes: Data       // base64url-decoded, 32 bytes
    var tokenBytes: Data     // base64url-decoded, 16 bytes
}
```

Parse with `URLComponents` + manual `+`-handling (Traps T2). Keep `token` and
`epk` as the **exact strings from the QR** — the token is echoed back verbatim
and must match byte-for-byte (`qr.ts:46`).

---

## 4. The one-time token

State machine, `QRSession` (`qr.ts:16-56`), **one active token per Pi process**:

| Call | Effect |
|---|---|
| `issueToken(ttl)` | 16 random bytes → base64url; sets `{token, expiresAt: now+ttl, consumed:false}`; **invalidates any previous token** |
| `consumeToken(t)` | `t !== active.token` → `"unknown"`; already consumed → `"consumed"`; `now > expiresAt` → `"expired"`; else marks consumed → `"ok"` |
| `clear()` | drops the active token (called by `startQRRotation`'s stop) |

- Default TTL **60 000 ms** (`TOKEN_TTL_MS`, `qr.ts:5`).
- `/remote-pi pair --ttl <seconds>` clamps to **[10 s, 600 s]**; NaN → 60 s
  (`qr.ts:7-14`, `index.ts:3066-3069`).
- Expiry is checked **after** the consumed check, so a second scan of an expired
  token reports `token_consumed`, not `token_expired` (`qr.ts:46-50`).
- Ordering matters: the token is consumed **before** anything is persisted
  (`index.ts:1972`), so a failed `addPeer` burns the token → the user must
  generate a new QR.
- The client gets **no signal** that a token expired until it sends
  `pair_request`. There is no "token still valid?" probe. iOS should show the
  expiry from a local timer only as a hint, and always let the user retry.

---

## 5. Connecting to the relay (pairing and afterwards are the same)

`WsTransport.connect` (`app/lib/data/transport/ws_transport.dart:44-191`) and
`relay/src/handlers/peer.rs:36-90`.

### 5.1 Handshake, exact frames

```jsonc
// → client, first frame, within 5 000 ms of the socket opening (HELLO_TIMEOUT_MS,
//   relay/src/auth/challenge.rs:12) — else the relay closes with no message.
{ "type": "hello",
  "pubkey": "0T5vX…=",          // Owner-key, 32B, base64 STANDARD with padding
  "room_id": "main" }           // the app is ALWAYS "main"

// ← relay
{ "type": "challenge", "nonce": "SGVsbG8…=" }   // 32 random bytes, base64 STANDARD (challenge.rs:46-51)

// → client
{ "type": "auth", "sig": "…" }  // 64-byte Ed25519 sig, base64 STANDARD
```

On success the relay registers the connection at the key
`(peer_id, room_id)` where `peer_id = STANDARD_base64(vk.to_bytes())`
(`peer.rs:80`) — i.e. **the relay's canonical form, not whatever you sent**.

### 5.2 What the Owner key signs — byte layout

**This is the only signature in the pairing handshake.**

```
message = the 32 raw bytes of the challenge nonce
```

- No prefix, no domain separator, no length framing, no hashing by the caller.
  `relay/src/auth/challenge.rs:78-88` does
  `vk.verify(nonce /* &[u8;32] */, &sig)`; the client does
  `Ed25519().sign(base64_decode(challenge.nonce))`
  (`ws_transport.dart:175-181`).
- Decode `nonce` with **standard** base64 (the relay encodes with `STANDARD`,
  `challenge.rs:49`). The Flutter helper is padding-tolerant and falls back to
  url-safe (`ws_transport.dart:302-310`); iOS should do the same defensively but
  the wire value is always standard-with-padding (44 chars).
- Signature is raw Ed25519 (RFC 8032, PureEdDSA over Curve25519), 64 bytes,
  encoded standard base64 **with** padding (`ws_transport.dart:178`, verified by
  `B64.decode` in `challenge.rs:84`).

> The **`pair_request` itself carries no signature.** `PROTOCOL.md:325`
> ("App manda `pair_request` assinado com a Owner-sk") and `PROTOCOL.md:388`
> are describing the challenge-response, not a field. See §12 D1.

The second, separate Owner signature in the flow is over the **membership blob**
(§10) — different message, different layout.

### 5.3 Why `room_id` must be `"main"`

The Pi's replies are sent as `{peer, ct}` **with no `room` field** — both
`_handlePairRequest`'s `sendInner` (`index.ts:1964-1967`) and the steady-state
`PlainPeerChannel.send` (`pi-extension/src/transport/peer_channel.ts:63-79`)
omit it. The relay's `OuterEnvelope` defaults a missing `room` to `"main"`
(`relay/src/protocol/outer.rs:8-18`), and delivery is an **exact-string lookup**
of `(dest_peer, dest_room)` in a `HashMap` (`registry.rs:254-256`). So a phone
that registered at any room other than `"main"` never receives `pair_ok` — the
relay reports `dest (peer, room) not found` and answers the *Pi* with a
`transport_error`.

`"main"` is a hard constant of the app side of the protocol. Do not derive it,
do not make it configurable.

### 5.4 Outer envelope the phone sends

```jsonc
{ "peer": "<Pi-key, base64 STANDARD with padding>",
  "room": "<qr.rm, or \"main\" when the QR carried none>",
  "ct":   "<base64 STANDARD of the UTF-8 JSON inner frame>" }
```

- `peer` **must be standard base64**: the QR gives you base64url, the relay's
  registry key is standard (`peer.rs:80`), and `forward()` does no
  normalisation (`registry.rs:254`). Flutter converts in
  `_normalizeToStandard` (`ws_transport.dart:314-321`).
- `room` is set before the send (`pair_request_flow.dart:97-103`); default
  `"main"` for legacy QRs without `rm`.
- `ct` size ceiling: `ct.len() * 3 / 4` must be ≤ 4 MiB
  (`relay/src/protocol/outer.rs:29,60-74`). Irrelevant for pairing, relevant for
  the same transport later.
- On delivery the relay **rewrites** the envelope: the recipient sees
  `peer` = the *sender's* canonical peer id and `room` = the *sender's*
  registered `room_id` (`peer.rs:391-396`). So the `pair_ok` arrives with
  `room` = the Pi's real room id, which may differ from `qr.rm` only if the QR
  was stale — in which case the `pair_request` would already have failed.

### 5.5 Dest-miss (plan 61 Phase 3)

If `(peer, room)` has no live connection the relay answers **the sender** with a
control frame (`peer.rs:428-440`):

```json
{ "type": "transport_error", "reason": "offline",
  "peer": "<the dest peer you sent>", "room_id": "<the dest room you sent>" }
```

During pairing this is the signal that the QR's `rm` is stale (Pi restarted,
`/remote-pi stop`, session replaced). iOS should surface it as
*"That Mac session is no longer running — generate a new QR"* and **not** wait
for the 30 s timeout the Flutter app uses (`pairing_viewmodel.dart:78-85`).
Note the frame is scoped to `(peer, room)`, carries **no** `in_reply_to`, and is
not a `pair_error`.

---

## 6. `pair_request`

Inner frame, base64'd into `ct`. Full schema — there are exactly four fields
(`pair_request_flow.dart:105-112`, `protocol.dart:713-729`,
`protocol/types.ts:176`):

```json
{ "type": "pair_request",
  "id": "019ffb64-3c21-7a55-9b0e-2f7d1c4a88e1",
  "token": "Zm9vYmFyYmF6cXV4MTIzNA",
  "device_name": "iPhone" }
```

| Field | Type | Notes |
|---|---|---|
| `type` | `"pair_request"` | |
| `id` | string | UUIDv7 in the app (`app/lib/protocol/uuid7.dart`); the Pi treats it as opaque and echoes it in `in_reply_to`. Any unique string works |
| `token` | string | **verbatim** `t` from the QR — base64url, unpadded. Do not re-encode, do not pad |
| `device_name` | string | free text; becomes `peers.json[].name` on the Mac. Flutter sends `"iPhone"` / `"Android device"` / `"Mobile"` (`pairing_viewmodel.dart:143-151`). Never used as a key — see Traps T7 |

No `sig`, no `owner_pk`, no timestamp. The Owner's identity is established
purely by the relay handshake: the Pi reads it from `outer.peer` *as rewritten
by the relay* (`index.ts:1894`, `_handlePairRequest(relay, appPeerId, …)`).

**Idempotency**: a `pair_request` from an *already attached* peer is silently
ignored (`index.ts:4108-4111`). A second `pair_request` from a *new* peer with
the same (already consumed) token gets `pair_error: token_consumed`.

---

## 7. `pair_ok`

Emitted by `index.ts:2019-2042`. Field-exact, with a plan-61 Pi:

```json
{ "type": "pair_ok",
  "in_reply_to": "019ffb64-3c21-7a55-9b0e-2f7d1c4a88e1",
  "session_name": "remote_pi",
  "session_started_at": 1780000000000,
  "room_id": "019ffb64-1111-7a55-9b0e-2f7d1c4a88e1",
  "session_id": "019ffb64-1111-7a55-9b0e-2f7d1c4a88e1",
  "workspace_path": "/Users/jacob/Projects/remote_pi",
  "display_name": "remote_pi",
  "name_rev": 1780000000000,
  "harness": { "name": "Pi coding agent", "version": "0.9.3" },
  "hostname": "jacobs-mbp.local" }
```

| Field | Emitted | Type | Source | Absent when |
|---|---|---|---|---|
| `in_reply_to` | always | string | `pair_request.id` | never |
| `session_name` | always | string | `_displayName(cwd)` = Pi session name, else `defaultAgentName(cwd)` (`index.ts:1285-1290`) | never |
| `session_started_at` | always | int (epoch ms) | `_sessionStartedAt ?? Date.now()` | never — but may be `0` from a legacy Pi; treat `0` as *unknown* (`protocol.dart:1290-1294`) |
| `room_id` | always | string | `_myRoomId`, fallback `roomIdForSession(sessionId, cwd, name)` (`index.ts:2029`) | legacy Pis omit it |
| **`session_id`** | conditional | string | `_myRoomMeta.session_id`, only present when the room really *is* keyed by the session id (`index.ts:2033`, `2884-2886`) | legacy `sha256(cwd[,name])` room, or session id not resolvable yet |
| **`workspace_path`** | always (plan-61 Pi) | string | `_myRoomMeta.workspace_path ?? canonicalWorkspacePath(cwd)` = `realpath(cwd)` (`rooms.ts:62-68`) | pre-plan-61 Pi |
| **`display_name`** | always (plan-61 Pi) | string | same value as `session_name` today (`index.ts:2035`) | pre-plan-61 Pi |
| **`name_rev`** | conditional | int (epoch-ms-ish, monotonic) | `_myRoomMeta.name_rev` (`index.ts:2036`, minted by `_nextNameRev`, `index.ts:283-287`) | room meta has no rev yet / pre-plan-61 Pi |
| `harness` | always (≥ plan 27) | `{name, version}` | `{"Pi coding agent", package.json version}` (`index.ts:1951-1954`) | pre-plan-27 Pi |
| `hostname` | always (≥ plan 27) | string | `os.hostname()` | pre-plan-27 Pi |

Absent vs null: **every optional field is omitted, never `null`.**
`...(cond ? {k:v} : {})` spreads (`index.ts:2033,2036`) — so `"session_id": null`
must never appear and, if it did, must be read as *absent*.

### 7.1 Client rules

1. **Match `in_reply_to` against your `pair_request.id`** before accepting
   (`pair_request_flow.dart:118`). The inbound queue is not filtered by sender
   peer, so any frame arriving on that socket lands in it.
2. `room_id`: distinguish **"the Pi said `main`"** from **"the Pi omitted the
   field"**. Flutter's decoder defaults a missing `room_id` to `"main"`
   (`protocol.dart:1311`), and the caller then re-checks the raw map
   (`pair_request_flow.dart:131-135`) to fall back to `qr.rm` instead. Model
   this as `String?` in Swift and apply the precedence explicitly:
   `pair_ok.room_id (non-empty) → qr.rm → "main"`.
3. `session_id`: **presence, not value, is the signal** that this room is
   rename-stable (`PROTOCOL.md:98-100`, `types.ts:279-283`). When present it
   equals `room_id`. Never derive one; never synthesise one from `room_id`.
4. `name_rev`: seed your local revision with it. A later
   `room_meta_update`/rename with `rev <= stored` must be ignored — the relay
   enforces strictly-greater on its side (`registry.rs:284-300`,
   `PROTOCOL.md:215-219`) and rebroadcasts the *current* name on rejection.
5. `workspace_path`: this is the canonical `realpath`; use it as the workspace
   grouping key. Never `cwd`-from-elsewhere, never the string in the QR.
6. Persist immediately, then treat the socket as the live chat channel — do not
   reconnect (§11).

---

## 8. `pair_error`

`index.ts:1968-1985`; code enum in `protocol/types.ts:1-5`.

```json
{ "type": "pair_error",
  "in_reply_to": "019ffb64-…",
  "code": "token_expired",
  "message": "Ephemeral token expired. Generate a new QR with /remote-pi pair." }
```

| `code` | Cause | Exact `message` the Pi sends |
|---|---|---|
| `token_expired` | `now > expiresAt` | `Ephemeral token expired. Generate a new QR with /remote-pi pair.` |
| `token_consumed` | token already used (or expired-and-used) | `Token already consumed by another pair_request.` |
| `token_unknown` | token not the active one (rotated / different Pi / typo) | `Token was not issued by this Pi.` |
| `internal_error` | `addPeer` threw | `Failed to persist peer: <err>` |

`message` is always present and non-null; it is a developer string, **not**
user-facing copy — the Flutter app maps codes to its own text
(`pairing_viewmodel.dart:135-141`) and only falls back to `message` for unknown
codes. iOS should do the same and treat the code set as **open** (forward-compat
for future codes).

Client-side pseudo-codes the Flutter app raises locally, which are *not* on the
wire and should not be parsed as such: `relay_mismatch`
(`pair_request_flow.dart:82`), `pair_timeout` (`pairing_viewmodel.dart:80`),
`unexpected_response` (`pair_request_flow.dart:160`).

There is also a **non-pair** error the Pi sends to an unknown peer that talks
without pairing first (`index.ts:1919-1927`):

```json
{ "type": "error", "code": "unknown_peer", "message": "Peer not paired — re-scan QR" }
```

Treat that as "this pairing was revoked" (drop stored peer or prompt re-pair),
not as a pairing failure.

---

## 9. Peer storage

### 9.1 On the Mac — `~/.pi/remote/peers.json`

Container shape (`pairing/storage.ts:445-449, 541-562`, `PEERS_PATH` at :81):

```json
{ "peers": [
    { "name": "iPhone",
      "remote_epk": "0T5vXk…=",
      "paired_at": "2026-08-25T12:34:56.789Z" }
] }
```

- `remote_epk` is stored **verbatim from `outer.peer`** — i.e. the relay's
  canonical standard base64 **with padding**. The comment at `storage.ts:447`
  says "raw standard/base64url … preserved exactly".
- `paired_at` = `new Date().toISOString()` (`index.ts:1991`).
- `addPeer` is upsert-by-`remote_epk` **exact string match**
  (`storage.ts:543-549`) — re-pairing overwrites the record.
- Written with `JSON.stringify({peers}, null, 2)`, no explicit mode; the parent
  dir is `0700` from the identity path.
- This is not something iOS writes; it matters because it decides whether your
  peer is recognised after a reconnect (§11) and by the supervisor gateway
  (Traps T6).

### 9.2 On the phone — `PeerRecord`

`app/lib/pairing/storage.dart:126-241`. Persisted in `FlutterSecureStorage`
(iOS Keychain) under key `dev.remotepi.peers:<remoteEpk>`
(`storage.dart:7, 283`), value = JSON:

```json
{ "remote_epk": "1sbg3nsX4kRTBmM3XZ_hs4mAujHmbcm7CjfPGkDgpTQ",
  "session_name": "remote_pi",
  "relay_url": "https://relay.remotepi.dev",
  "paired_at": "2026-08-25T12:34:56.789Z",
  "nickname": null,
  "room_id": "019ffb64-1111-7a55-9b0e-2f7d1c4a88e1",
  "harness": { "name": "Pi coding agent", "version": "0.9.3" } }
```

Field-by-field, as written by `performPairing` (`pair_request_flow.dart:136-149`):

| Key | From | Notes |
|---|---|---|
| `remote_epk` | **`qr.epk`** — base64url, unpadded | THE primary key. See Traps T1 |
| `session_name` | `pair_ok.session_name` | display only |
| `relay_url` | `qr.relayUrl ?? currentRelayUrl` | kept for legacy QRs; **not** consulted when connecting (`dependencies.dart:250-253`) |
| `paired_at` | `DateTime.now().toUtc().toIso8601String()` — the **phone's** clock, not the Mac's | also the tie-break ordering for "which peer to open on boot" |
| `nickname` | user, post-pair sheet | `null` allowed and written explicitly as `null` (`storage.dart:172`) |
| `room_id` | `pair_ok.room_id` → `qr.rm` → `"main"` | **a last-opened hint, not identity** (`storage.dart:135-149`) |
| `harness` | `pair_ok.harness` | omitted entirely when null (`storage.dart:174`) — asymmetric with `nickname`/`room_id`, which are written as JSON `null` |

`session_id`, `workspace_path` and `name_rev` from `pair_ok` are **not**
persisted by the Flutter app — see §12 D2. A native client should persist them,
either on a session record keyed by `(epk, session_id)` or on the room cache
below.

Room cache (separate secure-storage key `dev.remotepi.rooms:<remoteEpk>`, a JSON
**array** of `PersistedRoom`, `storage.dart:15-124, 352-386`) already carries the
plan-61 fields and is the right home for what `pair_ok` tells you:

```json
[{ "room_id": "019ffb64-1111-…", "name": "remote_pi", "cwd": "/Users/j/p",
   "started_at": 1780000000000, "local_name": null, "model": null,
   "session_id": "019ffb64-1111-…", "workspace_path": "/Users/j/p",
   "name_rev": 1780000000000, "role": null }]
```

`role == "control"` marks the supervisor's `ctrl` room and must be filtered out
of any chat list (`storage.dart:41-44`).

### 9.3 Swift sketch

```swift
struct PeerRecord: Codable, Equatable {
    var remoteEPK: String          // base64url, unpadded — storage key
    var sessionName: String
    var relayURL: String
    var pairedAt: String           // ISO-8601 UTC, keep as String (round-trip fidelity)
    var nickname: String?
    var roomID: String?            // hint only
    var harness: PiHarness?

    // plan 61 — NOT in the Flutter record; add them.
    var sessionID: String?
    var workspacePath: String?
    var nameRev: Int?
}

struct PiHarness: Codable, Equatable {   // defaults when pair_ok omits it
    var name: String = "Pi coding agent"
    var version: String = "—"
}
```

Use `JSONDecoder.keyDecodingStrategy = .convertFromSnakeCase` **only if** you also
set the matching encoding strategy; note `remote_epk` → `remoteEpk` under that
strategy, not `remoteEPK`, so explicit `CodingKeys` is safer and self-documenting.
Store in the iOS Keychain with `kSecAttrSynchronizable` matching however the
Owner key is stored, and keep one item per peer (prefix-scan for `listPeers`,
mirroring `storage.dart:325-334`).

---

## 10. Post-pair: publish `mesh_versions` (mandatory)

Pairing is **not durable** until the phone republishes the signed membership
blob: the pi-extension (and the supervisor gateway) poll it and *self-revoke*
when their own Pi-key is absent (`PROTOCOL.md:305-307`). The Flutter app wires
this as a mutation hook on `savePeer` (`storage.dart:260-280`,
`mesh_sync_service.dart:191-247`).

Canonical bytes signed by the Owner key (`mesh_blob.dart:132-146`) — **JCS-lite:
keys sorted lexicographically at every level, compact separators, UTF-8, no
whitespace**:

```json
{"issued_at":1780000000000,"members":[{"nickname":"casa","paired_at":"2026-08-25T12:34:56.789Z","relay_url":"https://relay.remotepi.dev","remote_epk":"0T5vXk…="}],"owner_pk":"…=","version":8}
```

Member key order after sorting is `nickname, paired_at, relay_url, remote_epk`;
`nickname` is **omitted when null** (`mesh_blob.dart:31-36`).

Wire form (`mesh_envelope.dart:32-35`) — `POST /mesh/<hash>` where
`hash = lowercase hex SHA-256 of the 32 raw Owner-pk bytes`
(`mesh_client.dart:135-143`):

```json
{ "blob": "<base64 STANDARD of the canonical bytes>",
  "sig":  "<base64 STANDARD of Ed25519(canonical bytes)>" }
```

**`members[].remote_epk` must be standard base64**, converted from the
base64url form the QR/PeerRecord holds (`mesh_sync_service.dart:209-221`) — the
Pi compares it against its own standard-base64 Pi-key, and an encoding mismatch
reads as "I am not listed" → self-revoke. `version` is monotonic; a `409`
means re-fetch and republish with a higher version. Never publish
`members: []` on top of a non-zero version unless the user explicitly revoked
the last peer (`mesh_sync_service.dart:197-206`).

Full membership semantics belong to a separate spec; what pairing owes is:
**save the peer, then publish, and treat a publish failure as retry-later, not
as a pairing failure.**

---

## 11. Ephemeral peer during pairing vs afterwards

There is **no** ephemeral key and **no** second connection. What differs is only
what the socket is used for:

| | During pairing | Afterwards |
|---|---|---|
| Key used in `hello.pubkey` | Owner-key (`pairing_viewmodel.dart:65-67`) | Owner-key (`dependencies.dart:236-238`) |
| `hello.room_id` | `"main"` | `"main"` |
| `hello.room_meta` | absent | absent (only Pis send it) |
| Envelope `room` | `qr.rm ?? "main"` (`pair_request_flow.dart:97-103`) | the room the user is chatting in; `sendToRoom` for one-off frames to another room (`ws_transport.dart:216-224`) |
| Pre-flight | `ConnectionManager.disconnect()` first — a second live WS with the same key would fight over the registry (`pairing_viewmodel.dart:56-59`) | — |
| Socket lifetime | reused: `PlainPeerChannel(transport)` then `conn.adopt(channel, peer)` (`pairing_viewmodel.dart:87-91`) | reconnect with backoff |
| Timeout | 30 s around the whole pairing (`pairing_viewmodel.dart:78-85`) | 10 s WS connect (`dependencies.dart:255-266`) |

N connections from the same Owner key at the same `(peer, room)` are legal — one
per device (`registry.rs:19-31`). The sender is skipped on forward
(`registry.rs:258-262`), so a second phone of the same Owner sees the frames but
the originator does not echo to itself.

**Reconnect after pairing needs no handshake**: the Pi recognises a peer that is
already in `peers.json` when *any* non-pair inner frame arrives, attaches a
channel, and routes it (`index.ts:1902-1913`). So iOS does **not** re-send
`pair_request` on reconnect — doing so would burn a token it does not have and,
if the peer is already attached, be dropped silently (`index.ts:4108-4111`).

Recognition uses **canonicalised** comparison on that path
(`_findKnownPeer`, `index.ts:1411-1423` → `canonicalizeEd25519PublicKey`), so
encoding drift in `peers.json` is tolerated *there* but not everywhere
(Traps T6).

---

## 12. Where the three implementations disagree

**D1 — "Owner-signed `pair_request`".** `PROTOCOL.md:325, 388` and
`plan/04-pairing.md` describe a signed pairing message and an ephemeral App-key.
The wire type has four fields and no signature (`types.ts:176`,
`protocol.dart:713-729`), and the key used is the long-lived Owner key.
**The code wins**: authenticity comes from the relay challenge-response over the
same socket, and from the Pi trusting the relay's `peer` rewrite. Implement no
`pair_request` signature; a Pi would ignore the extra field, but a native client
that *requires* one would never pair.

**D2 — plan-61 fields in `pair_ok`.** The pi-extension emits `session_id`,
`workspace_path`, `display_name`, `name_rev` (`index.ts:2033-2036`) and the
protocol doc says the app keys by session "from the first frame"
(`PROTOCOL.md:328-330`). The Flutter `PairOk` class **has no such fields** —
`PairOk.fromJson` (`protocol.dart:1297-1319`) parses only `in_reply_to`,
`session_name`, `session_started_at`, `room_id`, `harness`, `hostname`, and
`performPairing` drops the rest. **The pi-extension + plan 61 win**: iOS must
parse and persist all four. (Flutter recovers them later from `room_announced`;
a native client should not need that round-trip.)

**D3 — QR `rm` is documented as a 12-char digest.** `qr.ts:66-72` and
`qr_scanner.dart:14-19` both say "12 chars, base64url … derived from cwd". Since
plan 61 the value is `_myRoomId`, which is the **session UUID** (36 chars with
hyphens) for any current Pi (`index.ts:3071`, `rooms.ts:122-130`). **The runtime
value wins**: treat `rm` as opaque, do not validate length or alphabet.

**D4 — control-room replies are addressed to `room:"ctrl"`.** The supervisor
gateway sends `{peer, room: "ctrl", ct}` (`daemon/gateway.ts:212-218`), which
makes the relay look up `(app_pk, "ctrl")` — a key the app never registers,
since its `hello.room_id` is always `"main"`. Chat Pis omit `room` and therefore
land on `"main"` correctly. This is outside pairing but shapes the rule in §5.3:
**register at `"main"`, and do not assume a reply's dest room mirrors its sender
room.** (Flagged for the control-plane spec; not something the pairing client can
fix.)

---

## 13. Traps

**T1 — base64url vs standard, and the value that must never be a key.**
Three encodings of the same 32 bytes coexist:

| Place | Encoding |
|---|---|
| QR `epk`, QR `t` | base64url, **no padding** (`qr.ts:27,81`) |
| Relay registry / `hello.pubkey` / envelope `peer` / `transport_error.peer` | standard, **with padding** (`peer.rs:80`) |
| Phone `PeerRecord.remoteEpk` + Keychain key | base64url (whatever the QR gave) (`pair_request_flow.dart:137`) |
| `peers.json.remote_epk` on the Mac | standard (whatever `outer.peer` gave) (`index.ts:1993-1997`, value from `outer.peer` at `:1894`) |
| `mesh_versions.members[].remote_epk`, `owner_pk` | standard, normalised on the way out (`mesh_sync_service.dart:209-221`) |

The relay accepts either alphabet on `hello.pubkey` and canonicalises to
standard (`relay/src/identity.rs:14-34`) — but it **rejects a string mixing
`+/` with `-_`**, and it never normalises the `peer` field of an envelope
(`registry.rs:254`). Rule for iOS: **decode to 32 bytes at the boundary, keep
one canonical in-memory representation (raw `Data`), and re-encode per
destination.** Never string-compare two epks from different sources.

**T2 — `+` in the QR's `n`.** `URLSearchParams.toString()` encodes spaces as
`+` (`qr.ts:82-88`), and Dart's `Uri.queryParameters` decodes `+` back to a
space. **`URLComponents.queryItems` in Swift does not** — a session named
`my project` arrives as `my+project`. Percent-decode with an explicit
`+` → space pass for `n`. `t` and `epk` are base64url and can never contain `+`,
so only `n` is affected (and `r`, if a legacy QR carries a URL with a `+`).

**T3 — base64url without padding.** Node emits 22-char tokens and 43-char epks
(no `=`). `Data(base64Encoded:)` in Swift returns `nil` for those *and* for the
`-_` alphabet. Pad to a multiple of 4 and translate `-`→`+`, `_`→`/` before
decoding (Flutter does exactly this in `qr_scanner.dart:73-76` and
`epk_encoding.dart:24-36`). Conversely, when echoing the token back, send the
**original unpadded string** — the Pi compares with `!==` (`qr.ts:46`).

**T4 — `rm` may not exist any more.** The QR embeds the room id at *generation*
time. If the Pi restarts, `/name`s itself into a new session, or the daemon
re-spawns, the id changes; the `pair_request` then hits a dead
`(peer, room)` and you get a `transport_error`, **not** a `pair_error`. Two
distinct failure channels for one user-visible problem — handle both, and do not
let a `transport_error` reset the 30 s timer.

**T5 — absent vs explicit null vs "the string `main`".** `pair_ok` uses
conditional spreads, so optional fields are *absent*, never `null`
(`index.ts:2033,2036`). But `room_id` has a third state: Flutter's decoder
substitutes `"main"` for a missing `room_id` and then *re-reads the raw map* to
tell the two apart (`protocol.dart:1311` vs
`pair_request_flow.dart:131-135`). If you model `roomId` as a non-optional with
a default you will store `"main"` as the peer's room and address every later
frame to a room that only the phone lives in. Model it `String?` and resolve
precedence explicitly.

**T6 — two different peer-recognition rules on the Mac.** The chat path
canonicalises before comparing (`index.ts:1414-1420`); the supervisor gateway
compares **raw strings** (`daemon/gateway.ts:150-153, 169-176`). A `peers.json`
entry whose `remote_epk` is url-safe therefore works for chat and is refused by
the control room. Since the Mac writes whatever `outer.peer` contained, and the
relay always rewrites that to standard, this holds today — but never hand-edit
or migrate `peers.json` into url-safe form, and never assume the two gates agree.

**T7 — `device_name` is display-only.** It is upserted into `peers.json[].name`
and defaults to `"Unknown Owner"` when malformed (`index.ts:1374`). It is
**never** an identity: two phones with the same name are two records keyed by
distinct `remote_epk`. Do not key anything by it, and do not assume it is unique
or stable.

**T8 — the pairing inbound queue is unfiltered.** `WsTransport` enqueues every
`{peer, ct}` frame regardless of sender (`ws_transport.dart:92-122`); the only
guard is `in_reply_to == id` (`pair_request_flow.dart:118`). A native client
should additionally check the delivered `peer` equals the Pi's canonical key
before accepting a `pair_ok`.

**T9 — the token dies before the reply arrives.** `consumeToken` runs before
`addPeer` (`index.ts:1972` vs `:1993`). If persistence fails you get
`internal_error` **and** a dead token: the retry must start from a *new* QR, not
from a re-send. Do not build an automatic retry that re-sends the same token.

**T10 — `started_at` / `session_started_at` are not identity.** `started_at` in
room meta is the relay's registration instant and changes on every reconnect
(`PROTOCOL.md:221-223`). `pair_ok.session_started_at` changes when the Pi
*process* restarts and is `0` on legacy Pis. Use them for restart detection
only; never for ordering, never as a key.

**T11 — one QR, one Pi process.** `qrSession` is a module-level singleton
(`qr.ts:58`) with a single active token. Two `/remote-pi pair` runs in the same
Pi invalidate each other; two *different* Pi processes each have their own
token and their own `rm`, but share the machine's Pi-key — so `epk` alone does
not tell you which session you are pairing with. `rm` does.

---

## 14. Suggested Swift wire types

```swift
enum InnerClientFrame: Encodable {          // phone → Pi
    case pairRequest(id: String, token: String, deviceName: String)
    // …
}

struct PairOk: Decodable {
    let inReplyTo: String
    let sessionName: String
    let sessionStartedAt: Int?              // absent/0 ⇒ unknown
    let roomID: String?                     // nil ⇒ "Pi omitted", NOT "main"
    let sessionID: String?                  // presence ⇒ rename-stable room
    let workspacePath: String?
    let displayName: String?
    let nameRev: Int?
    let harness: PiHarness?
    let hostname: String?

    enum CodingKeys: String, CodingKey {
        case inReplyTo = "in_reply_to", sessionName = "session_name"
        case sessionStartedAt = "session_started_at", roomID = "room_id"
        case sessionID = "session_id", workspacePath = "workspace_path"
        case displayName = "display_name", nameRev = "name_rev"
        case harness, hostname
    }
}

struct PairErrorFrame: Decodable {
    let inReplyTo: String
    let code: String                        // keep String: the enum is open
    let message: String
}

enum PairFailure: Error {                   // local + wire, one surface
    case wire(code: String, message: String)      // pair_error
    case transportOffline(peer: String, room: String)   // transport_error
    case relayMismatch(qr: String, configured: String)
    case timedOut
    case unexpected(type: String?)
}
```

Decoding strategy: **explicit `CodingKeys`, no `convertFromSnakeCase`** — the
acronym cases (`epk`, `room_id` vs `roomID`) and the absent-vs-null rules are
easier to audit when the mapping is written out.

---

## 15. Acceptance checks

1. `remotepi://pair?t=<22>&epk=<43>&n=my+project` parses with
   `sessionName == "my project"` and 16/32-byte decodes.
2. A QR with `epk` in **standard** base64 (`+`/`/`, padded) still pairs: the
   envelope `peer` is normalised to standard, and the stored key is whatever the
   QR gave — round-trip `toStandard(stored) == relay peer id`.
3. `pair_request` bytes: `{"type":"pair_request","id":…,"token":…,"device_name":…}`
   and nothing else; `ct == base64Standard(utf8(json))`.
4. `hello.room_id == "main"` on every connection, pairing included; a `pair_ok`
   is received on that same socket.
5. `pair_ok` without `session_id` ⇒ the session is flagged *legacy*, and the app
   still functions keyed by `room_id`.
6. `pair_ok` with `room_id` absent ⇒ stored room is `qr.rm`, and only `"main"`
   when the QR had no `rm` either.
7. Sending `pair_request` to a stale `rm` yields a `transport_error` control
   frame, surfaced within one RTT — no 30 s wait.
8. Second scan of the same QR ⇒ `pair_error: token_consumed`.
9. After `savePeer`, a `mesh_versions` publish goes out with `remote_epk` in
   **standard** base64 and `version = previous + 1`.
10. Killing and reopening the app reconnects with the Owner key, sends no
    `pair_request`, and the Pi routes normally.
