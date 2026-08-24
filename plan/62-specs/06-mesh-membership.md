# 62-06 — Owner membership blobs + self-revoke

Implementation-ready spec for the native iOS client. Ground truth is the code
referenced inline; this document does not invent behaviour.

Scope: the `mesh_versions` blob, its canonical bytes, the `{blob, sig}`
envelope, `POST`/`GET /mesh/<hash>`, monotonic-version + LWW rules, when the
app publishes, the `allowEmpty` safety net, and what a revoke looks like from
the Pi's side.

Out of scope (and explicitly dead in this fork): agent mesh, UDS broker,
`pi_envelope` Pi→Pi routing. See `PROTOCOL.md:6-17` and `PROTOCOL.md:311-314`.

Post-plan-61 note: **the mesh blob has no session dimension at all.** It lists
machines (Pi-keys). Revoking a member kills every session on that machine,
including the supervisor's permanent `ctrl` room (`PROTOCOL.md:232-240`).
`session_id`, `room_id`, `name_rev` never appear here.

---

## 1. Identities and who signs what

| Thing | Key | Where it appears |
|---|---|---|
| Owner | Ed25519, lives in iOS Keychain (iCloud-synced) | `owner_pk` in the blob; the signer of `sig`; `sha256(bytes)` is the URL slot |
| Pi (machine) | Ed25519, one per PC | `members[].remote_epk` |
| App-key (ephemeral pairing) | Ed25519 | **not** in the blob |

One row per Owner at the relay, keyed by `owner_pk_hash`
(`relay/migrations/001_mesh_versions.sql`). Membership is Owner-scoped, not
device-scoped: two phones sharing the synced Owner key write the *same* row
and race by LWW (§6).

> **Naming collision — read twice.** In the mesh blob, `members[].remote_epk`
> is the **Pi** public key. In the pi-extension's `~/.pi/remote/peers.json`,
> the field also called `remote_epk` is the **Owner** public key
> (`pi-extension/src/pairing/storage.ts:445-449`). Same name, opposite ends of
> the pairing. Every self-revoke bug in the repo's history is a variant of
> crossing these two.

---

## 2. The canonical blob

Logical shape (`app/lib/data/mesh/mesh_blob.dart:92-147`,
`relay/src/mesh/types.rs:25-40`, `pi-extension/src/mesh/verify.ts:42-100`):

```json
{
  "issued_at": 1780000000000,
  "members": [
    {
      "nickname": "Mac do trabalho",
      "paired_at": "2026-05-22T10:30:00.000Z",
      "relay_url": "https://relay-rp1.jacobmoura.work",
      "remote_epk": "N0Uc4fT2sJ0m1v6WcQe9m1n1lQ3+aXk7Yq0Zb3cD4eE="
    },
    {
      "paired_at": "2026-06-01T08:00:00.000Z",
      "relay_url": "https://relay-rp1.jacobmoura.work",
      "remote_epk": "Aq9Yb2c3dEf4Gh5Ij6Kl7Mn8Op9Qr0St1Uv2Wx3Yz4="
    }
  ],
  "owner_pk": "9k2Lq8sW3xTn5Vb7Cd1Ef4Gh6Ij8Kl0Mn2Op4Qr6S=",
  "version": 7
}
```

Field contract:

| Field | Type | Required | Notes |
|---|---|---|---|
| `version` | integer ≥ 1 | yes | monotonic per Owner. `u64` at the relay (`types.rs:37`); Dart refuses `<= 0` on both construct and parse (`mesh_blob.dart:123-129`, `:167-171`) |
| `issued_at` | integer, ms since Unix epoch UTC | yes | **nobody validates it.** Not used for ordering, not used for anti-rollback. Informational only |
| `owner_pk` | string, base64 of 32 raw bytes | yes | Dart enforces exactly 32 bytes (`mesh_blob.dart:116-122`); relay decodes via `identity.rs:14-30` and builds the `VerifyingKey` from it (`verify.rs:44-51`) |
| `members` | array, possibly empty | yes | full replacement set — see §5 |
| `members[].remote_epk` | string, base64 of 32 raw bytes | yes | relay rejects the whole POST if *any* member fails to decode to 32 bytes (`verify.rs:64-70`) |
| `members[].relay_url` | string | yes | opaque metadata. Nothing routes on it. May be `https://…` (current relay) or `wss://…` (legacy QR) — `app/lib/pairing/pair_request_flow.dart:141` |
| `members[].paired_at` | string, ISO-8601 | yes | opaque. The app writes `DateTime.now().toUtc().toIso8601String()` → `2026-05-22T10:30:00.000Z` (`pair_request_flow.dart:143`) |
| `members[].nickname` | string | **no** | omit the key entirely when absent (`mesh_blob.dart:31-36`) |

### 2.1 Canonicalization

Rule (`app/lib/data/mesh/mesh_blob.dart:132-147`, restated in
`relay/src/mesh/verify.rs:33-39`): **keys sorted lexicographically, compact
separators (`,` and `:`, no whitespace), UTF-8**. That produces:

- top level key order: `issued_at`, `members`, `owner_pk`, `version`
- member key order: `nickname`, `paired_at`, `relay_url`, `remote_epk`

Asserted by `app/test/data/mesh/mesh_blob_test.dart:58` and `:81`; whitespace
bytes `0x20 / 0x09 / 0x0a` are asserted absent at `:112-114`.

Canonical bytes for the example above (newlines added here only for reading —
the real bytes have none):

```
{"issued_at":1780000000000,"members":[{"nickname":"Mac do trabalho",
"paired_at":"2026-05-22T10:30:00.000Z","relay_url":"https://relay-rp1.jacobmoura.work",
"remote_epk":"N0Uc…"},{"paired_at":"2026-06-01T08:00:00.000Z",
"relay_url":"https://relay-rp1.jacobmoura.work","remote_epk":"Aq9Y…"}],
"owner_pk":"9k2L…","version":7}
```

**Who actually enforces it: nobody.** The relay verifies the signature against
the exact bytes it received and never re-serializes (`verify.rs:33-39`,
`:40-42`); its own unit tests sign plain `serde_json` output in a different key
order (`verify.rs:115-121`). The pi-extension parses with `JSON.parse` and is
order-agnostic (`verify.ts:31-53`). Dart's reader is likewise tolerant
(`mesh_blob.dart:149-152`).

So canonicalization is a **producer discipline**, not a validated invariant.
Follow it anyway: the LWW loss-detection rule in `plan/24` Q5 ("compare the
blob you published with the blob that came back") only works if the same
logical membership serializes to the same bytes on every client.

---

## 3. The `{blob, sig}` envelope

Wire form (`app/lib/data/mesh/mesh_envelope.dart:19-52`,
`relay/src/mesh/types.rs:5-9`, `pi-extension/src/mesh/types.ts:32-37`):

```json
{
  "blob": "eyJpc3N1ZWRfYXQiOjE3ODAwMDAwMDAwMDAsIm1lbWJlcnMiOltdLCJvd25lcl9wayI6Ii4uLiIsInZlcnNpb24iOjd9",
  "sig":  "Yk3s…64-byte-signature-base64…=="
}
```

- `blob` = base64 of the canonical JSON **bytes**.
- `sig` = base64 of the raw 64-byte Ed25519 signature over those exact bytes
  (`mesh_blob.dart:198-205`). No prehash, no domain separator, no context
  string — plain `Ed25519.sign(canonicalBytes)`. The relay verifies with
  `verify_strict` (`relay/src/mesh/verify.rs:60-62`), the extension with
  `ed25519Verify(ownerPk, blob, sig)` (`verify.ts:88`).
- The verification key comes **from inside the blob** (`owner_pk`), which is
  why §7-T5 exists.
- Never re-encode `blob` after receiving it (`mesh_envelope.dart:16-18`).
  Keep the decoded `Data` and verify against that.

Base64 variant: **RFC 4648 standard alphabet, with padding**, in both
directions. See §7-T1 — this is the single most expensive detail to get wrong.

---

## 4. HTTP API

Base URL = the configured relay, `http(s)://…`, same host and port as the
WebSocket (`app/lib/config/dependencies.dart:78-81`,
`app/lib/data/transport/relay_config.dart:39-45`). Strip one trailing `/`, then
append `/mesh/<hash>` (`mesh_client.dart:144-148`;
`pi-extension/src/mesh/client.ts:86` strips all trailing slashes).

Routes are mounted at `/mesh/:owner_pk_hash` for both verbs
(`relay/src/lib.rs:60-65`). No authentication — the endpoint is public and
verifiable, by design (`plan/24-mesh-membership.md:180-183`).

### 4.1 `<hash>` derivation

```
hash = lowercase_hex( SHA256( owner_pk_raw_32_bytes ) )     // 64 hex chars
```

`app/lib/data/mesh/mesh_client.dart:135-142`,
`relay/src/mesh/verify.rs:88-96`, `pi-extension/src/mesh/self_revoke.ts:276`.

**Over the raw key bytes, not over the base64 string.** The relay lowercases
whatever segment you send before comparing (`handler.rs:76`) and before reading
(`handler.rs:112`), so an uppercase URL works, but emit lowercase.

### 4.2 `POST /mesh/<hash>`

Request: `Content-Type: application/json`, body is the `{blob, sig}` object.
Body cap 500 KB, enforced twice: `DefaultBodyLimit` on the whole router
(`lib.rs:65`) and again in the handler (`handler.rs:58-60`).

Server pipeline (`handler.rs:53-105`):

1. size check → `413`
2. `serde_json` parse of `{blob, sig}` → `400 invalid json: …`
3. base64-decode both fields → `400 decode: …`
4. parse the blob JSON into `{version, owner_pk, issued_at, members[]}`; any
   missing/mistyped field → `400`
5. decode `owner_pk`, build `VerifyingKey`, `verify_strict(blob, sig)` →
   `403 sig_invalid`
6. every `members[].remote_epk` must decode to 32 bytes → `403` /`400`
   (`VerifyError::BadMemberPk` maps through `handler.rs:66-72` to `400`)
7. `sha256(owner_pk) == lowercase(url_hash)` → else `403 owner_pk_hash mismatch`
8. `store.upsert` inside one transaction; `new_version <= current` →
   `409` (`store.rs:101-148`)
9. `200` with `{"version":<u64>,"updated_at":<i64 ms, relay clock>}`

| Status | Body | Meaning | Swift case |
|---|---|---|---|
| 200 | `{"version":7,"updated_at":1780000000123}` | stored | `.ok` |
| 400 | `invalid json: …` / `decode: …` / `blob is not valid JSON…` (**text/plain**) | your bug | `.badRequest(String)` |
| 403 | `sig_invalid` / `owner_pk_hash mismatch` / `owner_pk in blob is not a valid 32-byte Ed25519 key` (**text/plain**) | signature or slot mismatch | `.forbidden` |
| 409 | `stale_version (current=12)` (**text/plain**) | someone published a higher version | `.conflict(current:)` |
| 413 | `payload_too_large` | body > 500 KB | `.tooLarge` |
| 5xx | `internal` | relay fault | `.failure` |

The app's mapping is `app/lib/data/mesh/mesh_client.dart:219-247`; it throws
the 409 body away (`MeshPublishConflict` carries nothing,
`mesh_client.dart:59-61`). A Swift client should parse `current=` out of the
409 text and jump straight to `current + 1` instead of paying a `GET`.

### 4.3 `GET /mesh/<hash>[?since=<version>]`

`handler.rs:107-132`.

- no row → `404` (body `not_found`). Treat as `current_version = 0`
  (`mesh_client.dart:33-36`, `plan/24-mesh-membership.md:58`).
- row exists and `since` present and `row.version <= since` → `304`, **empty
  body** (`handler.rs:119-123`). Note `<=`, not `<`.
- otherwise `200`:

```json
{
  "blob": "<base64 standard, padded>",
  "sig": "<base64 standard, padded>",
  "version": 7,
  "updated_at": 1780000000123
}
```

`version` and `updated_at` sit **outside** the envelope; strip them before
handing the map to your envelope decoder (`mesh_envelope.dart:37-39`).

`updated_at` is the relay's wall clock at write time (`handler.rs:80-83`,
`store.rs` column `updated_at`). It is **not** `issued_at`, and it is not a
version. Use it for "last synced" UI only.

A non-numeric `since` is rejected by axum's `Query` extractor before the
handler runs (`types.rs:67-70`) — send integers or omit the parameter.

There is **no DELETE**. "Forget everything" = publish `members: []` at
`version + 1` (§5.3).

---

## 5. Publishing: when, and with what member set

### 5.1 The trigger

Every peer mutation republishes. `PairingStorage` fires a fire-and-forget hook
after `savePeer` / `deletePeer` (`app/lib/pairing/storage.dart:261-286`,
`:303-306`), and DI wires that hook to `meshSync.publish()`
(`app/lib/config/dependencies.dart:88-91`).

Concretely, the mutations that publish:

| Event | Path | Publishes |
|---|---|---|
| Pairing succeeded | `pair_request_flow.dart:148` `storage.savePeer(peer)` | yes, via hook |
| Nickname set/cleared | `settings_viewmodel.dart:56` `savePeer(updated)` | yes, via hook |
| Revoke a peer | `settings_viewmodel.dart:106` `deletePeerSilent` + explicit publish | yes, explicitly, with `allowEmpty` |
| Applying a pulled blob | `mesh_sync_service.dart:137,142` `*Silent` variants | **no** — deliberately (§7-T7) |
| Room cache writes | `saveRooms` | no — rooms are a per-device cache |

### 5.2 The publish algorithm (`mesh_sync_service.dart:171-256`)

```
publish(allowEmpty = false):
  if _publishing: return .failure("already in flight")          # :172-174
  pk = ownerPublicKey or return .failure("owner pk not loaded")  # :175-178
  _publishing = true
  try: _publishOnce(pk, refetchOnConflict: true, allowEmpty)
  finally: _publishing = false

_publishOnce(pk, refetchOnConflict, allowEmpty):
  peers = storage.listPeers()
  if peers.isEmpty && _lastVersion > 0 && !allowEmpty:
      return .failure("refused empty-on-existing")               # :206-208  ← safety net
  members = peers.map { remote_epk: toStandardB64(p.remoteEpk),  # :216-223  ← encoding fix
                        relay_url:  p.relayUrl,
                        paired_at:  p.pairedAt,
                        nickname:   p.nickname }                 # omitted when nil
  blob = { version: _lastVersion + 1,                            # :224
           issued_at: nowUtcMillis,
           owner_pk:  pk,
           members }
  env = sign(canonicalBytes(blob), ownerSecretKey)
  switch client.publish(sha256hex(pk), env):
    .ok(v, u):      _lastVersion = v; lastUpdatedAt = u
    .conflict:      if !refetchOnConflict: return
                    pullOnDemand()                               # :243
                    return _publishOnce(pk, refetchOnConflict: false, allowEmpty)
    else:           return as-is                                 # no retry
```

`_lastVersion` is an **in-memory watermark** (`:29-33`), reset to 0 by
`resetVersionWatermark()` when the Owner key changes
(`:286-289`, called from `app_router.dart:190`). It is not persisted, so a cold
boot starts at 0 → first publish attempts `version: 1` → `409` → refetch →
`current + 1`. One wasted round-trip, plus the hazard in §7-T10.

### 5.3 The `allowEmpty` safety net

`mesh_sync_service.dart:196-208`. The rule:

> Refuse to publish `members: []` when `_lastVersion > 0`, **unless** the
> caller explicitly opted in.

Why it exists (comment at `:197-205`, and `SettingsViewModel` doc at
`settings_viewmodel.dart:19-22`): a transient empty read of local storage —
mid-apply state, a race with a pull, an Owner-key reset — would publish an
empty membership, and **every Pi the user owns would self-revoke on its next
60 s poll.** That bug was reproduced in the field; the safety net is the fix.

The one legitimate caller: revoking the **last** peer
(`settings_viewmodel.dart:95-112`):

```dart
await _storage.deletePeerSilent(epk);          // silent: do NOT let the hook publish
final remaining = await _storage.listPeers();
_meshSync.publish(allowEmpty: remaining.isEmpty);   // opt in only when it truly is the last one
```

Note the two-step shape: the **silent** delete prevents the hook from firing a
default `publish()` that the safety net would refuse — which would leave the
relay holding a blob that still lists the revoked Pi, and the next
`pullOnDemand` would resurrect the peer locally.

Swift contract: `allowEmpty` must be computed as `remaining.isEmpty` at the
call site, never hard-coded `true`, never defaulted `true`.

### 5.4 Pull and apply (`mesh_sync_service.dart:58-146`)

```
pullOnDemand():
  pk = ownerPublicKey or return false
  switch client.fetch(sha256hex(pk), since: _lastVersion > 0 ? _lastVersion : nil):
    .ok(env, v, u):
        verify sig over env.blob                                  # :95-98
        parse blob
        require blob.owner_pk == pk (byte equality)               # :100-102  ← anti-substitution
        replaceLocalCache(blob)                                   # :103
        _lastVersion = v; lastUpdatedAt = u; return true
    .notModified: return true        # cache untouched
    .notFound:    return true        # cache untouched — relay simply has no row
    .failure:     return false
```

`replaceLocalCache` (`:120-146`) is a **full reconciliation**: members present
in the blob are upserted (silently), and any locally-known peer absent from
`blob.members` is deleted along with its cached rooms. That is the whole point
— *the relay row is the source of truth for membership* — and it is also why
`allowEmpty` matters.

Cadence:
- boot: `app_router.dart:92` `await meshSync.pullOnDemand()`
- foreground resume: `main.dart:63-73` — `startPolling()` + one `pullOnDemand()`
- background/inactive/hidden/detached: `stopPolling()`
- poll interval: 60 s (`mesh_sync_service.dart:269`, `plan/24` Q1)

---

## 6. Monotonic version + LWW

Three independent enforcement points; they do not contradict each other, but
they live at different scopes.

| Where | Rule | Scope | Persistence |
|---|---|---|---|
| Relay | `new_version <= current` → `409`, whole upsert in one txn (`store.rs:112-127`) | per `owner_pk_hash` row | durable (SQLite) |
| pi-extension | `header.version <= lastSeen` → log `owner_rollback`, ignore (`self_revoke.ts:309-315`) | per Owner slot, per process | **in-memory only** (`self_revoke.ts:106-111`, issue #73) |
| app | `_lastVersion` used only to pick the next version and as `since` | per process | in-memory (`mesh_sync_service.dart:29-33`) |

LWW (`plan/24` Q5, Q2): only the newest version is retained (UPSERT,
`store.rs:128-146`); there is no history and no merge. Two Owner devices that
publish concurrently do not merge member sets — the higher version wins
wholesale. The loser is expected to *detect* the loss by comparing the blob it
published against the blob returned by the next poll, log it, and accept it. No
automatic retry in the MVP.

Practical consequence for iOS: after any successful publish, keep the bytes you
published. On the next `pullOnDemand`, if the returned blob's members differ
from yours, you lost the race — re-apply your intent (add/remove the specific
peer) on top of the fetched set and publish again at `fetched.version + 1`.
Do **not** blindly re-publish your old snapshot.

---

## 7. Traps

These are worth more than the happy path. Each one has cost the project a bug.

### T1 — base64 variant, three different strictnesses

| Consumer | Accepts | Reference |
|---|---|---|
| Relay, `blob` + `sig` on POST | **standard only, canonical padding required** (`base64` 0.22 `STANDARD`) | `verify.rs:76-84` |
| Relay, `owner_pk` + `remote_epk` inside the blob | standard **or** url-safe, padded **or** unpadded; mixed alphabets rejected | `identity.rs:14-30` |
| pi-extension, `blob` + `sig` on GET | standard or url-safe, padded or unpadded, canonical trailing bits enforced, mixed rejected | `client.ts:27-73` |
| pi-extension, key fields | same strict decoder, then re-encoded to standard-padded | `encoding.ts:35-106` |
| App | `base64.decode` (Dart accepts both alphabets); emits standard-padded | `mesh_envelope.dart:32-35` |

**Rule for Swift: always emit RFC 4648 standard with padding, everywhere.**
`Data.base64EncodedString()` is exactly right. Inbound, `Data(base64Encoded:)`
is *stricter* than everyone else — it rejects url-safe characters and rejects
missing padding — so normalize before decoding anything that may have come from
a QR code or an older client (`-`→`+`, `_`→`/`, pad to a multiple of 4).

The recurring bug (`app/lib/data/transport/epk_encoding.dart` header comment,
`pi-extension/src/mesh/encoding.ts:1-17`): the QR payload carries the Pi key as
**base64url without padding** (`app/lib/pairing/qr_scanner.dart:4,23`;
`pi-extension/src/pairing/qr.ts:81` uses Node's `"base64url"`), while
`members[].remote_epk` must be standard. The app normalizes at exactly one
place, on the way out — `toStandardB64(p.remoteEpk)`
(`mesh_sync_service.dart:216-218`). Skip that and the Pi computes
`member.remoteEpk !== standardBase64(myKey)`, concludes "I am not listed", and
self-revokes. **Never compare base64 strings; compare 32-byte values.**

### T2 — Swift's JSONEncoder will not produce the canonical bytes

Two defaults break byte-equality with Dart:

1. **Slash escaping.** `JSONEncoder` writes `https:\/\/relay…` unless you set
   `.outputFormatting.insert(.withoutEscapingSlashes)`. Dart's `jsonEncode`
   does not escape `/`. `relay_url` contains two of them in every member.
2. **Key order.** You need `.sortedKeys` for the top level *and* for members.

Even with both flags, you are trusting Foundation's escaping table to match
Dart's forever. Given the blob has exactly four top-level keys and four member
keys, the safe move is a **hand-rolled canonical serializer** for this one
structure: emit the fixed key sequence, JSON-escape strings yourself
(`"` `\` and `U+0000..U+001F` as `\u00XX`; everything else literal UTF-8),
integers as plain decimal. ~30 lines, zero encoder-version risk. Decoding can
stay on `JSONDecoder` — readers are order-tolerant everywhere.

### T3 — `remote_epk` means opposite things in two files

See §1. Mesh blob member = Pi key. `peers.json` record = Owner key. When
reading pi-extension code, check which file you are in.

### T4 — the hash is over key bytes, not over the base64 string

`sha256(rawOwnerKeyBytes)`, lowercase hex. Hashing the base64 text produces a
64-hex string that looks perfectly valid and yields `403 owner_pk_hash
mismatch` on POST and `404` on GET forever.

### T5 — the URL slot proves nothing; check `owner_pk` yourself

`pi-extension/src/mesh/verify.ts:20-24` spells out the attack: the verification
key comes from inside the blob, so a hostile or buggy relay can serve a
perfectly-signed blob belonging to a *different* Owner at your hash slot. Both
reference readers defend:

- app: byte-compares `blob.owner_pk` against the local Owner key before
  applying (`mesh_sync_service.dart:100-102`) and drops silently on mismatch
- pi-extension: `bytesEqual(header.ownerPk, slot.ownerPk)` before acting
  (`self_revoke.ts:304-307`)

A signature that verifies is necessary and not sufficient.

### T6 — `members: []` is a weapon; keep the safety net

§5.3. Publishing an empty membership at `version + 1` revokes every machine the
Owner has. The guard is: *empty is only allowed when the caller proves it meant
it.* Port `allowEmpty` verbatim; do not "simplify" it away.

### T7 — applying a pulled blob must not re-publish

`storage.dart:288-295` and `:308-310` exist purely so the apply path can write
without firing the mutation hook. Without the silent variants you get
`pull → apply → savePeer → hook → publish → …` forever, and worse, a publish
observing the intermediate (possibly empty) storage state
(`mesh_sync_service.dart:113-119`). Model this in Swift as an explicit
`suppressPublish` scope around the apply, not as a debounce.

### T8 — the 409 retry re-reads storage and can undo a revoke

`_publishOnce` on conflict calls `pullOnDemand()` — which **re-applies the
relay's blob to local storage** — and then re-snapshots `listPeers()`
(`mesh_sync_service.dart:241-248`). For a revoke that lost a race, the pulled
blob still contains the peer you just deleted, the apply writes it back
locally, and the retry publishes it *back to the relay*. The revoke silently
un-happens.

Swift fix: carry the *intent* (`.add(member)` / `.remove(epk)` /
`.setNickname`) through the retry and rebase it onto the freshly fetched member
set, instead of re-reading local storage. This is the one place this spec
recommends diverging from the Dart behaviour.

### T9 — concurrent publishes are dropped, not queued

`publish()` returns `.failure("already in flight")` when `_publishing` is true
(`mesh_sync_service.dart:172-174`). The doc comment claims the change will be
"picked up by the next fetch loop", but the fetch loop *applies the relay's
view*, which does not contain the dropped mutation — so the next pull deletes
it locally. Two peer mutations in quick succession can therefore lose one.
Swift: a serial actor with a coalescing dirty-flag (publish again after the
in-flight one completes), never a plain drop.

### T10 — the version counter is `_lastVersion + 1`, not `fetched + 1`

If the boot pull failed (offline) and the user pairs, the app publishes
`version: 1`, gets `409`, pulls — and that pull *deletes the freshly paired
peer* from local storage because the relay's blob predates it — then republishes
without it. Prefer: fetch first, then publish `fetched.version + 1` with your
intent applied on top.

### T11 — the apply path re-keys peers and drops their rooms

`_replaceLocalCacheWith` looks up `existing[m.remoteEpk]` using the blob's
standard-base64 key, while `PairingStorage` records are keyed by whatever the
QR gave — base64url (`mesh_sync_service.dart:121-139`). The lookup misses, a
new record is written under the standard key with `sessionName` falling back to
`nickname ?? 'remote_pi'` and `roomId: null`, and the old record is deleted
along with `deleteRooms(oldEpk)` (`:140-145`). The user loses the cached room
pointer for that machine.

Swift: **store the Pi key in canonical standard base64 from the moment of
pairing**, and normalize the QR value once, at ingest. Then the mesh apply is a
no-op diff instead of a migration.

### T12 — `304` semantics and the empty body

`since` is compared with `<=`, so `since == current` yields `304`
(`handler.rs:119-123`). The body is empty — do not attempt to decode it. `304`
means "your cache is current", not "no membership": leave the local cache
untouched (`mesh_sync_service.dart:78-79`).

### T13 — error bodies are `text/plain`, not JSON

`MeshHttpError::into_response` returns bare strings (`handler.rs:31-50`). The
app's `_extractMessage` tries JSON then falls back to the raw string
(`mesh_client.dart:259-269`). Do not `JSONDecoder` a 4xx body.

### T14 — values that must never be keys

- `nickname` — a user-editable label. Never index, dedupe, or route by it.
- `relay_url` — historical, per-record, may be `wss://` in old records while
  the app connects to `https://`. Connection resolution is **global**
  (`relay_config.dart:17-19`: "`peer.relayUrl` … is no longer consulted when
  opening a connection"). Carry it, don't obey it.
- `paired_at` — display + tie-break only.
- `updated_at` / `issued_at` — clocks, not versions. `started_at` elsewhere in
  the protocol has the same warning (`PROTOCOL.md:221-223`).
- The only key in this document is `remote_epk` (as 32 raw bytes), and the only
  ordering value is `version`.

### T15 — revoke is cooperative, not enforced

The relay does not consult mesh membership when routing App↔Pi frames — routing
is `(peer_id, room_id)` registry only. Removing a member from the blob does
nothing at the relay; the Pi is what stops answering, on its own next poll
(§8). A machine that is powered off, offline, or running a patched extension
stays paired. `PROTOCOL.md:405-411` states this openly. Do not build UI that
claims instant, server-side revocation.

### T16 — the Pi's anti-rollback floor dies with its process

`self_revoke.ts:106-111` — the `lastSeenVersion` map is in-memory. Restart the
Pi and a relay that replays a pre-revocation version can un-revoke it.
Acknowledged in `PROTOCOL.md:395-397`. Not the client's problem to fix, but do
not assume revocation is durable against a hostile relay.

### T17 — publishing also grants relay-side Pi→Pi forwarding

`relay/src/handlers/pi_forward.rs:226-243` derives co-membership from stored
blobs (60 s positive cache, `:37-39`). This fork emits no `pi_envelope`
(`PROTOCOL.md:311-314`), so it is inert — but a blob is not a purely private
document; it is authorization data at the relay.

---

## 8. Self-revoke, from the Pi's side

This is what the phone's action actually causes, and what the phone can
observe.

### 8.1 Who polls

Two independent `SelfRevoke` instances per machine, both using the **same
Pi-key** and the **same `peers.json`** (`PROTOCOL.md:46-49`):

1. the chat extension, started on relay connect
   (`pi-extension/src/index.ts:2953-3005`): one immediate `checkOnce()` at
   `:2997`, then every 60 s (`self_revoke.ts:73`), plus a `requestFreshCheck()`
   after same-process pairing mutations (`self_revoke.ts:154-159`).
2. the supervisor gateway that owns the `ctrl` room
   (`pi-extension/src/daemon/gateway.ts:113-137`). Non-optional by design:
   "a gateway that does not poll membership keeps its spawn capability after
   the user revokes" (`gateway.ts:44-46`, `:131-133`).

### 8.2 One sweep (`self_revoke.ts:274-349`)

```
for each distinct Owner key in peers.json:                     # :208-243
    hash  = sha256hex(ownerKeyBytes)                           # :276
    env   = GET /mesh/<hash>?since=<lastSeenVersion or absent> # :279
    304 or 404 → null → no change                              # client.ts:117
    verify signature; on failure → warn owner_envelope_invalid # :296-302
    require bytesEqual(header.ownerPk, slotOwnerPk)            # :304-307
    require header.version > lastSeen else warn owner_rollback # :309-315
    selfPubkey  = standardBase64(myPiKey)                      # :317
    stillMember = header.members.any { $0.remoteEpk == selfPubkey }   # :318
    if stillMember: clear pending, lastSeen = version, done    # :321-326
    else:           lastSeen = version; queue revocation       # :328-338
```

The member comparison is string equality — but both sides are already
canonical standard base64: `verify.ts:93-96` re-encodes every
`members[].remote_epk` through `canonicalizeEd25519PublicKey`, and `selfPubkey`
comes from `encodeEd25519PublicKey` (`encoding.ts:94-106`). That
canonicalization is the *only* reason a url-safe `remote_epk` in the blob does
not immediately self-revoke the Pi — do not rely on it, emit standard.

### 8.3 What a queued revocation does

`conditionalRemovePeer(rawOwnerHandle, token)`
(`pi-extension/src/pairing/storage.ts:610-648`) removes that Owner from
`peers.json` under a serialized mutation lane, guarded by an opaque
per-Owner-slot provenance token so a re-pair that happened during the poll
cannot be clobbered (outcome `stale` → the revocation is abandoned).

Then, per instance:

- **chat extension** — `_revokeActiveOwnerRuntime(canonicalOwnerPubkey)`
  (`index.ts:1403-1409`): detaches that Owner's channel, refreshes the footer,
  and posts a local chat notice `remote-pi:mesh-revoked` —
  `"🔒 Revoked by Owner <fp>… Re-pair via /remote-pi pair if this was
  unexpected."` (`index.ts:1391-1401`). That notice is **local to the Pi's
  terminal**; it is not sent to the phone.
- **gateway** — `refreshOwners()` (`gateway.ts:134`, `:155-162`) re-reads
  `peers.json` into the allow-list. Subsequent `ctrl` frames from that peer are
  dropped before the action decoder runs (`gateway.ts:168-180`).

Sessions themselves are not killed and the relay rooms stay registered (other
Owners may still be paired). What dies is *that Owner's* access.

### 8.4 What the iOS client observes after it revokes a machine

There is **no revoke notification frame**. The observable sequence:

1. Your `POST` returns `200`. Nothing has happened on the Pi yet.
2. Up to 60 s later, the Pi's poll notices. In between, the machine still
   answers normally.
3. After that, per room:
   - **chat room** — the Owner channel is detached. The next inner frame you
     send is picked up by the extension's fallback listener and answered with
     an inner control frame:
     ```json
     { "type": "error", "code": "unknown_peer",
       "message": "Peer not paired — re-scan QR" }
     ```
     (`index.ts:1920-1928`). This is your positive confirmation of revocation.
   - **`ctrl` room** — the gateway drops the frame silently
     (`gateway.ts:174-180`). No `action_error`, no reply. Your RPC just times
     out. Do not treat `ctrl` silence as a transport fault.
4. `transport_error` (`PROTOCOL.md:177-186`) does **not** fire here — the Pi is
   still connected and the room still exists; the frame is delivered and then
   ignored. You will only see `transport_error: offline` if the machine also
   disconnects.

Design consequence: revoke the peer **locally first** (drop it from the UI, the
presence subscription, the connection) and publish afterwards, exactly as
`SettingsViewModel.revoke` does (`settings_viewmodel.dart:95-131`). Do not wait
for a confirmation the protocol never sends.

### 8.5 Re-pairing after a revoke

Nothing special at the mesh layer: `pair_request` from an unknown peer is still
accepted (`index.ts:1896-1899`), `addPeer` re-adds the Owner and invalidates
the storage slot token (`storage.ts:541-565`), and the app's normal pairing
path re-publishes the member at `version + 1`. The revoked-then-re-paired
machine is a plain member again.

---

## 9. Suggested Swift shapes

Domain (byte-oriented; strings only where the wire is a string):

```swift
struct MeshMember: Equatable, Sendable {
    var remoteEPK: String     // canonical standard base64, padded — the ONLY key
    var relayURL:  String     // opaque metadata
    var pairedAt:  String     // opaque ISO-8601
    var nickname:  String?    // nil ⇒ key omitted from JSON
}

struct MeshBlob: Equatable, Sendable {
    var version:  UInt64      // ≥ 1
    var issuedAt: Int64       // ms since epoch, UTC
    var ownerPK:  Data        // exactly 32 bytes
    var members:  [MeshMember]
}

struct MeshEnvelope: Sendable {
    let blob: Data            // canonical bytes AS RECEIVED / AS SIGNED — never re-encode
    let sig:  Data            // 64 bytes
}
```

Wire DTOs stay separate from the domain types, so canonical encoding never
leaks into `Codable`:

```swift
private struct MeshEnvelopeWire: Codable { let blob: String; let sig: String }
private struct MeshGetResponse: Codable {
    let blob: String, sig: String
    let version: UInt64
    let updatedAt: Int64
    enum CodingKeys: String, CodingKey { case blob, sig, version, updatedAt = "updated_at" }
}
```

Results, mirroring the Dart sealed hierarchies
(`mesh_client.dart:10-85`) so the call sites stay exhaustive:

```swift
enum MeshFetchResult { case ok(MeshEnvelope, version: UInt64, updatedAt: Int64)
                       case notModified, notFound
                       case failure(String) }

enum MeshPublishResult { case ok(version: UInt64, updatedAt: Int64)
                         case conflict(current: UInt64?)   // parsed from "stale_version (current=N)"
                         case badRequest(String)
                         case forbidden, tooLarge
                         case failure(String) }
```

Signing/verifying: CryptoKit `Curve25519.Signing.PrivateKey/PublicKey` —
`signature(for: canonicalBytes)` and `isValidSignature(sig, for: canonicalBytes)`.
`rawRepresentation` is the 32-byte key that goes into `owner_pk` and into the
SHA-256 for the URL. Hash with `SHA256.hash(data:)` and hex-encode lowercase.

Publishing should be an actor with:

- a serialized publish lane plus a coalescing dirty flag (T9),
- an explicit intent enum (`.add`, `.remove`, `.rename`) rebased onto a fresh
  fetch on `409` (T8, T10),
- an `allowEmpty` parameter reachable only from the revoke path (T6),
- a `suppressPublish` scope wrapping the apply of a fetched blob (T7).

### Golden vectors to build first

1. Fixed Owner keypair + two members (one with `nickname`, one without) →
   assert the canonical bytes string literally, and assert the same bytes come
   out of the Dart implementation (`app/test/data/mesh/mesh_blob_test.dart` is
   the model for the key-order assertions).
2. `sha256("")` sanity for the hex helper:
   `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`
   (`relay/src/mesh/verify.rs:186-193`).
3. A url-safe `remote_epk` fed to the normalizer must produce the standard form
   byte-identically (T1).
4. `members: []` at `version > 1` must be refused unless `allowEmpty` (T6).

---

## 10. Open / undetermined

- **Rate limiting** on `/mesh` is *recommended* by `plan/24-mesh-membership.md:184`
  but no implementation exists in `relay/src/mesh/`. Assume unlimited; do not
  design a retry storm.
- **`version` ceiling** is unspecified. Relay `u64`, TS `number` (safe to 2^53),
  Dart `int`. Nothing wraps or resets. Use `UInt64` and never jump versions.
- **Conflict-loss detection** (plan/24 Q5) is documented as "compare and log"
  but is not implemented anywhere in the app — no code compares the published
  blob against the next fetched blob. Treat §6's recommendation as new
  behaviour for the Swift client, not as parity.
- **`GET` with `since` on a row whose `version` is 0**: reachable only if a
  non-app publisher writes `version: 0` (the relay accepts it into an empty
  slot; Dart cannot then parse it). Nothing in this repo produces it. Publish
  `≥ 1` and the case never arises.
