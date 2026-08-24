# Spec 05 — Owner key + iOS Keychain sync

**Audience**: implementer of a **native iOS client** replacing `app/` (Flutter).
**Status**: implementation-ready. Post-plan-61 protocol.
**Ground truth read for this spec**:

- `app/packages/remote_pi_identity/ios/Classes/KeychainSyncStore.swift` (108 lines)
- `app/packages/remote_pi_identity/ios/Classes/RemotePiIdentityPlugin.swift` (196 lines)
- `app/packages/remote_pi_identity/lib/src/owner_identity.dart`
- `app/packages/remote_pi_identity/lib/src/owner_identity_store.dart`
- `app/packages/remote_pi_identity/lib/src/method_channel_store.dart`
- `app/lib/pairing/owner_identity_bridge.dart`
- `app/lib/routing/app_router.dart`, `app/lib/config/dependencies.dart`, `app/lib/main.dart`
- `app/lib/pairing/storage.dart`, `app/lib/data/mesh/**`, `app/lib/data/transport/epk_encoding.dart`
- `relay/src/mesh/{verify,types,handler}.rs`, `relay/src/identity.rs`
- `pi-extension/src/mesh/encoding.ts`
- `PROTOCOL.md`, `plan/23-owner-key-sync.md`

Nothing in this spec changes an existing file.

---

## 1. What the Owner key is, and what it is not

| Key | Curve | Lives where | Created by | Used for |
|---|---|---|---|---|
| **Owner-key** | Ed25519 | iOS Keychain, `kSecAttrSynchronizable=true` (iCloud Keychain) | the phone app, on first boot | signs the `mesh_versions` blob; authenticates the app's WebSocket to the relay (challenge-response) |
| **Pi-key** | Ed25519 | the Mac's OS keychain (`@napi-rs/keyring`) | pi-extension | identity of the **machine** |
| **App-key** | Ed25519, ephemeral | RAM | app, per pairing | *historical* — see §7.3 |

`PROTOCOL.md:39-41`. One Owner key **per human**, not per device — that is the entire
point of plan 23 (`plan/23-owner-key-sync.md`, "Granularidade: Chave única por
humano"). Two devices of the same Apple ID hold the *same* 32 bytes and both look
like the same peer to the relay and to every paired Pi.

**The key never rotates.** `plan/23-owner-key-sync.md`, decision table
"Imutabilidade da Owner-key": generated once; if `watch()` ever delivers a
*different* key, the new one is authoritative and the device treats itself as
"started from zero" — no prompt, no merge, no reconciliation.

### 1.1 In-memory representation

`app/packages/remote_pi_identity/lib/src/owner_identity.dart:14-40`:

- `ownerPk` — **exactly 32 bytes**, Ed25519 public key. Constructor throws
  `ArgumentError` otherwise (`:26-33`).
- `ownerSk` — **exactly 32 bytes**, the Ed25519 **seed** (not the 64-byte
  expanded secret key). Constructor throws otherwise (`:34-39`).

Proof that `ownerSk` is the seed and not an expanded key: the bridge rebuilds the
keypair with `_ed25519.newKeyPairFromSeed(id.ownerSk)`
(`app/lib/pairing/owner_identity_bridge.dart:118`) and fills it from
`kp.extractPrivateKeyBytes()` (`:100`) into a field asserted to be 32 bytes.

CryptoKit maps 1:1 and byte-compatibly:

| Dart (`package:cryptography`) | CryptoKit |
|---|---|
| `Ed25519().newKeyPair()` | `Curve25519.Signing.PrivateKey()` |
| `kp.extractPrivateKeyBytes()` → 32B seed | `privateKey.rawRepresentation` → 32B |
| `kp.extractPublicKey().bytes` → 32B | `privateKey.publicKey.rawRepresentation` → 32B |
| `Ed25519().newKeyPairFromSeed(seed)` | `Curve25519.Signing.PrivateKey(rawRepresentation: seed)` |
| `Ed25519().sign(msg, keyPair:)` → 64B | `privateKey.signature(for: msg)` → 64B |

### 1.2 Persisted blob — fixed 64 bytes, no header, no version

`owner_identity.dart:42-61`:

```
byte offset:  0 ─────────── 31 │ 32 ─────────── 63
content:      ownerPk (32B)    │ ownerSk seed (32B)
```

- `toBlob()` → `Uint8List(64)`, `setRange(0,32,ownerPk)`, `setRange(32,64,ownerSk)`.
- `fromBlob()` throws `FormatException` when `blob.length != 64` (`:51-55`).
- **No version byte, no JSON, no base64.** Deliberate — `CHANGELOG.md` 0.2.0
  BREAKING: "Blob format changed: now a fixed 64-byte buffer (`ownerPk || ownerSk`)
  instead of versioned JSON. Old blobs from 0.1.0 are not migrated."

A native client must write the same 64 raw bytes. A device running the Flutter app
and a device running the native app under the same Apple ID share one Keychain
item; a different layout there is a **silent cross-device identity corruption**,
not a version negotiation.

---

## 2. The Keychain item — exact attributes

From `KeychainSyncStore.swift:100-107` (`baseQuery()`), `:25-26`, `:59`:

| Attribute | Value | Set on |
|---|---|---|
| `kSecClass` | `kSecClassGenericPassword` | every query |
| `kSecAttrService` | `"dev.remotepi.owner.identity"` | every query |
| `kSecAttrAccount` | `"singleton"` | every query |
| `kSecAttrSynchronizable` | `kCFBooleanTrue` | every query |
| `kSecAttrAccessible` | `kSecAttrAccessibleAfterFirstUnlock` | **`SecItemAdd` only** (`:59`) |
| `kSecValueData` | the 64-byte blob | add / update |
| `kSecAttrAccessGroup` | **not set** — no keychain-sharing group anywhere in the repo (`grep -r kSecAttrAccessGroup app/ ⇒ no hits`) | — |

`service` + `account` are **constants**. The account is literally the string
`"singleton"`. See Traps §10.5 for why keying it by the owner public key would be
a bug, not an improvement.

### 2.1 Operations (reusable verbatim)

`load()` — `KeychainSyncStore.swift:29-44`

```
baseQuery + kSecReturnData=true + kSecMatchLimit=kSecMatchLimitOne
→ SecItemCopyMatching
   errSecSuccess      → Data
   errSecItemNotFound → nil            (first run — NOT an error)
   other              → throw .osStatus(status, "SecItemCopyMatching failed")
```

`save(blob:)` — `:48-67` — **update-or-add**, never add-first:

```
SecItemUpdate(baseQuery, [kSecValueData: blob])
   errSecSuccess      → done
   errSecItemNotFound → baseQuery + kSecValueData + kSecAttrAccessible
                        → SecItemAdd; non-success → throw .osStatus(...,"SecItemAdd failed")
   other              → throw .osStatus(..., "SecItemUpdate failed")
```

The comment at `:46-47` gives the reason: add-first would return
`errSecDuplicateItem` on every re-save.

`delete()` — `:70-76` — `SecItemDelete(baseQuery)`; `errSecItemNotFound` is
folded into success (idempotent).

`isSyncAvailable()` — `:93-98` — see §3.

---

## 3. `isSyncAvailable()` — what it proves and what it does not

```swift
// KeychainSyncStore.swift:93-98
var query = baseQuery()
query[kSecMatchLimit as String] = kSecMatchLimitOne
let status = SecItemCopyMatching(query as CFDictionary, nil)
return status == errSecSuccess || status == errSecItemNotFound
```

Read the comment at `:78-92` before touching this. Two hard-won facts:

1. It is **deliberately not** `FileManager.ubiquityIdentityToken`. That is the
   iCloud **Drive/ubiquity** signal and is always `nil` without an iCloud
   entitlement, which this app does not ship. Using it "locked every App Store
   user out at 'Sync required' even with iCloud + iCloud Keychain fully enabled
   (issue #39)".
2. `kSecAttrSynchronizable` items need **no iCloud entitlement**, and Apple
   exposes **no public API** for "is iCloud Keychain on?". The load/save error
   path is the real check.

Therefore: `isSyncAvailable()` returns `true` on a device with iCloud Keychain
**off**. It only reports `false` for hard Keychain failures (keychain unavailable,
`errSecInteractionNotAllowed`). Reuse it verbatim — but do not read more into
`true` than "the Keychain answered". See Traps §10.2.

---

## 4. The boot-time gate

This is the contract the native client must reproduce. Authoritative source:
`app/lib/pairing/owner_identity_bridge.dart:72-104` (the decision) and
`app/lib/routing/app_router.dart:55-237` (the routing consequence).

### 4.1 `boot()` state machine

`owner_identity_bridge.dart:72-92`:

```
boot():
  try  loaded = store.load()
       if loaded != nil:  _current = loaded;  return .ready(loaded, generated: false)
  catch SyncUnavailable:   return .syncUnavailable          ← the ONLY gate trigger
  catch IdentityStoreError(other): fall through and generate

  try  generated = generateAndSave()   // Ed25519 keypair → store.save()
       _current = generated;  return .ready(generated, generated: true)
  catch SyncUnavailable:   return .syncUnavailable
  // NOTE: any other error escapes boot() uncaught — see Traps §10.7
```

`_generateAndSave()` (`:94-104`) is: new Ed25519 keypair → extract 32B public +
32B seed → `OwnerIdentity(...)` → `store.save(id)` → return. The key is generated
**by the app**, never by the Keychain (`plan/23`, decision "Curva": "Chave gerada
em Dart ... e persistida como blob arbitrário — não usa `SecKey`/`KeyStore` como
key-handle"). No `SecKey`, no Secure Enclave — Secure Enclave keys cannot sync.

### 4.2 Where `SyncUnavailable` comes from

Native → Dart error mapping (`method_channel_store.dart:84-89`): the platform
error **code string** `"sync_unavailable"` maps to `SyncUnavailable`; every other
code maps to `PlatformFailure`.

The iOS plugin raises it in exactly two places, both by pre-flighting
`isSyncAvailable()`:

- `RemotePiIdentityPlugin.swift:56-59` — `load`
- `:74-77` — `save`

with `code: "sync_unavailable"`, `message: "iCloud Keychain is not enabled on
this device"` (`:176-178`). `delete` (`:103-113`) has **no** such pre-flight —
asymmetry, see §11.

`OSStatus` failures map to `code: "keychain_error"`, `message: "<what>:
<SecCopyErrorMessageString>"`, `details: ["osStatus": Int(status)]` (`:180-187`).
Anything else → `code: "unknown"` (`:189-195`).

### 4.3 Routing consequences

`app_router.dart:55-104` (`_BootState.load`), `:212-237` (`redirect`):

```
/boot  ← initialLocation; splash while boot.ready == false
   │
   ├─ boot() == .syncUnavailable ──► _syncAvailable=false, _ready=true
   │        redirect: every path ⇒ "/sync-required"  (STICKY — :220-222)
   │        "/sync-required" itself returns nil so the user can stay there
   │
   └─ boot() == .ready(id, generated:)
            _identityWasGenerated = generated                     (:78-79)
            installWatcherAfterBoot()   ← watch installed ONLY here (:85)
            meshSync.pullOnDemand()     ← BEFORE listing peers    (:92)
            peers = storage.listPeers(); _hasPeer = peers.isNotEmpty
            _ready = true
            redirect: shouldOnboard = identityWasGenerated && !hasPeer   (:231)
                      target = shouldOnboard ? "/onboarding" : "/home"
```

Four rules a native client must keep:

1. **Nothing that needs the Owner key runs before `boot()` resolves.** The WS
   connection factory calls `requireKeyPair()` (`dependencies.dart:239-240`) and
   the pairing flow calls it too (`pairing_viewmodel.dart:65`); both throw
   `StateError` if `boot()` has not populated `_current`
   (`owner_identity_bridge.dart:110-119`).
2. **`/sync-required` is sticky and retry-driven.** The "Check again" button calls
   `boot()` again and only navigates away when the result is not
   `SyncUnavailableResult` (`sync_required_page.dart:24-35`). iOS copy lives at
   `sync_required_page.dart:169-180`: (1) Sign in to iCloud — *Settings › [your
   name]*; (2) Turn on iCloud Keychain — *Settings › [your name] › iCloud ›
   Passwords and Keychain*, "Toggle 'Sync this iPhone' on."
3. **No local-only fallback identity, ever.** `plan/23`, "Comportamento sem sync
   disponível": blocks first launch, "Sem fallback 'gera local' pra evitar
   divergência silenciosa com sync futuro." The plugin README repeats it
   (`README.md:63-68`).
4. **Onboarding only on a genuinely fresh identity.** A key restored from iCloud
   Keychain — including "reinstalled the app on the same device" — sets
   `generated == false` and skips the wizard even with zero peers
   (`app_router.dart:43-53`, `:223-232`).

Also note the local-store ordering in `main.dart:15-24`: local boxes are opened
and the volatile runtime box wiped **before** dependency setup, and the router
(hence `boot()`) is built after. Reproduce that order: local persistence ready →
identity gate → transport.

---

## 5. Change detection (`watch`) and the owner-swap wipe

### 5.1 Native side — the emitter

`RemotePiIdentityPlugin.swift:117-172`. Three triggers, one de-dup:

| Trigger | Line | Notes |
|---|---|---|
| **initial emit on subscribe** | `:122-126` | `if store.isSyncAvailable(), let data = try? store.load() { emitIfChanged(data) }` — a subscriber immediately receives the current blob, no separate load needed |
| **`UIApplication.willEnterForegroundNotification`** | `:131-136` | the *primary* signal: "Keychain itself has no change observer. We poll on each willEnterForeground" (`:129-130`) |
| **`NSUbiquitousKeyValueStore.didChangeExternallyNotification`** | `:141-145` | admittedly a proxy tickle: "iCloud key-value store doesn't carry our blob (Keychain does), but its notification is a useful 'iCloud surface changed something' tickle" (`:138-140`). See Traps §10.4 |
| **echo of our own `save`** | `:94` | `handleSave` calls `emitIfChanged(typed.data)` so a writer's own subscribers see the new value |

De-dup: `emitIfChanged` (`:168-172`) compares full `Data` equality against
`lastEmittedBlob` and drops equals. `onCancel` (`:150-161`) removes both
observers and nils the sink. `handleDelete` sets `lastEmittedBlob = nil` but
**emits nothing** (`:106`) — there is no "identity removed" event on the stream.

### 5.2 Dart side — the reactor

`owner_identity_bridge.dart:147-163`:

```
store.watch().listen(incoming):
   current = _current
   if current == nil:            _current = incoming;  return   ← adopt, DO NOT wipe
   if bytesEqual(current.pk, incoming.pk):             return   ← same owner, no-op
   _current = incoming
   await pairing.wipeAll()                                      ← peers + rooms gone
   await onReset()
onError: swallowed silently (:161-162)
```

The `current == nil` branch is load-bearing. Its 25-line comment (`:130-146`)
documents the incident: subscribing before `boot()` populated `_current` made the
platform's **initial** emit look like a different owner, which wiped the freshly
paired peer set; a following `room_announced` then made the app publish
`v=N+1, members=[]`, and the pi-extension self-revoked ~60s later. Two defences
ship together — this null-guard, and installing the watcher only after `boot()`
returns (`app_router.dart:85`, `:176-195`). **Keep both.**

Comparison is on the **public key only** (`:155`), not the whole blob. A same-pk
different-sk event is treated as no change.

`onReset` (`app_router.dart:187-194`), in order:

```
conn.disconnect()
meshSync.resetVersionWatermark()     // _lastVersion=0, lastUpdatedAt=null
boot.onOwnerKeyReplaced()            // _ready=false → router falls back to /boot
boot.load(...)                       // full re-boot
```

Note the wipe happens **inside the bridge before** `onReset` runs
(`owner_identity_bridge.dart:159-160`), so by the time the mesh watermark resets,
local peers are already gone.

### 5.3 What the wipe actually clears

`PairingStorage.wipeAll` (`app/lib/pairing/storage.dart:341-350`) deletes only
keys prefixed `dev.remotepi.peers:` and `dev.remotepi.rooms:`. It does **not**
touch `Preferences` (selected room/peer) nor the local message SSOT boxes. See
Traps §10.9.

---

## 6. Wire shapes that consume the Owner key

The Keychain layer is opaque-bytes only, but the native client needs these to know
what the 32/64 bytes are *for*. Both are byte-exact requirements.

### 6.1 Relay WebSocket challenge-response (the Owner key is the WS identity)

`app/lib/data/transport/ws_transport.dart:157-182`, `dependencies.dart:235-273`:

```jsonc
// 1. app → relay
{ "type": "hello",
  "pubkey": "<ownerPk, base64 STANDARD, padded>",
  "room_id": "main" }

// 2. relay → app
{ "type": "challenge", "nonce": "<base64>" }

// 3. app → relay          sig = Ed25519(ownerSk).sign(nonce_bytes)
{ "type": "auth", "sig": "<base64 STANDARD of the 64-byte signature>" }
```

The app always announces `room_id: "main"` — it is a client, it has no cwd
(`ws_transport.dart:159-161`). Post-plan-61 `room` on **envelopes** is the Pi
`session_id` UUID (or the literal `"ctrl"`), but the app's own hello room stays
`"main"`. Do not conflate the two.

`peer` on an outbound envelope is the **destination Pi-key**, standard base64
(`ws_transport.dart:11-12`, `:183`, `_normalizeToStandard` at `:312-321`).

### 6.2 Mesh membership blob — signed by the Owner key

Canonical JSON that gets signed (`app/lib/data/mesh/mesh_blob.dart:139-147`;
mirrored in `PROTOCOL.md:280-295`):

```json
{"issued_at":1780000000000,"members":[{"nickname":"casa","paired_at":"2026-05-22T18:03:11.000Z","relay_url":"wss://relay.example","remote_epk":"BASE64STANDARD32B="}],"owner_pk":"BASE64STANDARD32B=","version":7}
```

Rules, all enforced somewhere:

- keys sorted lexicographically at **both** levels, no whitespace, compact
  separators (`mesh_blob.dart:139-147` uses `SplayTreeMap` at root and per member).
- `owner_pk` — base64 **standard, padded**, of the raw 32 bytes
  (`mesh_blob.dart:143` uses `base64.encode`).
- `version` — positive int, strictly monotonic; relay 409s on `new <= current`
  (`relay/src/mesh/handler.rs:100-103`, `MeshHttpError::Conflict`).
- `issued_at` — int milliseconds since Unix epoch UTC
  (`mesh_sync_service.dart:227`); relay parses it as `u64`
  (`relay/src/mesh/types.rs:38`).
- `members[]` — `remote_epk`, `relay_url`, `paired_at` are **required**;
  `nickname` is the **only** optional field, and it is **omitted when null**, never
  emitted as `null` (`mesh_blob.dart:31-36`). The relay's `MeshMemberHeader`
  (`types.rs:25-30`) types it `Option<String>`, so absent and explicit `null` both
  deserialize to `None` there — but omit it, to match the producer that already
  ships. A member missing any of the other three is a **400**, not a skipped
  member (`verify.rs:41-42`, `VerifyError::BadBlobJson`).

Envelope on the wire (`mesh_envelope.dart:32-35`, `relay/src/mesh/types.rs:5-9`):

```json
{ "blob": "<base64 standard of the canonical JSON bytes>",
  "sig":  "<base64 standard of the 64-byte Ed25519 signature>" }
```

- `POST /mesh/<owner_pk_hash>` → `200 {"version":u64,"updated_at":i64}` /
  400 / 403 / 409 / 413 (`relay/src/mesh/handler.rs:55-106`;
  `mesh_client.dart:219-247`).
- `GET /mesh/<owner_pk_hash>?since=<v>` → `200 {"blob","sig","version","updated_at"}`,
  `304` when `stored.version <= since`, `404` when the row never existed
  (`handler.rs:118-131`; `mesh_client.dart:164-190`).
- `owner_pk_hash` = **SHA-256 over the raw 32 key bytes**, lowercase hex
  (`mesh_client.dart:135-142`; `relay/src/mesh/verify.rs:88-96`). The relay
  lowercases the path segment and re-derives the hash from the *verified* key,
  403ing on mismatch (`handler.rs:74-78`).
- The relay **never re-canonicalizes**; it verifies the signature over exactly the
  bytes received (`verify.rs:34-39`, `types.rs:12-13`). So a wrong canonical form
  still verifies at the relay and only breaks other clients. See Traps §10.3.

---

## 7. What a native client reuses, changes, drops

### 7.1 Reuse **verbatim**

`KeychainSyncStore.swift` — the whole file, all 108 lines. It imports only
`Foundation` and `Security`; it has no Flutter dependency of any kind. Copy it
unchanged, including:

- the `service`/`account` constants (`:25-26`) — changing either orphans every
  already-synced identity;
- `baseQuery()` always carrying `kSecAttrSynchronizable` (`:100-107`) and the
  reason in the type doc (`:13-16`);
- update-or-add in `save` (`:48-67`);
- `errSecItemNotFound`-is-success in `load` and `delete`;
- `isSyncAvailable()` exactly as written, **and its comment** (`:78-92`) — that
  comment is the record of issue #39 and will be re-broken by anyone who
  "improves" it into an iCloud-account check.

Also reuse conceptually, from the plugin: the `emitIfChanged` byte-comparison
de-dup (`RemotePiIdentityPlugin.swift:168-172`) and the
`willEnterForeground` re-read (`:131-136`).

### 7.2 Must change

| Piece | Why | Replace with |
|---|---|---|
| `import Flutter` / `FlutterPlugin` / `FlutterMethodChannel` / `FlutterEventChannel` (`RemotePiIdentityPlugin.swift:1-38`) | no Flutter engine in a native client | a plain Swift type; see §8 |
| `FlutterStandardTypedData(bytes:)` boxing (`:62`, `:90`, `:171`) | Flutter's byte-transport type | `Data` |
| `FlutterError(code:message:details:)` (`:176-195`) | Flutter's error channel shape | a Swift `Error` enum; keep the same three discriminants — `sync_unavailable`, `keychain_error` (+`osStatus`), `unknown` — because §4.2's gate keys off exactly the first one |
| `FlutterStreamHandler` `onListen`/`onCancel` (`:117-161`) | channel lifecycle | `AsyncStream` (with `onTermination` doing the observer teardown of `:150-161`) or Combine publisher |
| `NSUbiquitousKeyValueStore` observer (`:141-145`) | see Traps §10.4 | drop it, or gate it behind an actual `com.apple.developer.ubiquity-kvstore-identifier` entitlement |
| Only-on-foreground polling (`:131-136`) | a long foreground session never notices an incoming sync | add a timer/`SecItemCopyMatching` re-read while foregrounded (see §12 Q3) |
| `s.platform = :ios, '18.0'` in `ios/remote_pi_identity.podspec:18` | CocoaPods target, irrelevant natively; also disagrees with the docs (§11) | your own deployment target |

### 7.3 Drop

- The whole MethodChannel/EventChannel indirection (`method_channel_store.dart`).
  Channel names `remote_pi_identity` / `remote_pi_identity/events` become dead
  vocabulary.
- The Android/Block Store half of the plugin. Its limitations
  (`README.md:121-134`: no live sync, no cross-ecosystem sync, no per-device
  revoke) still bound the *product*, not the iOS code.
- The `App-key` (ephemeral per-pairing Ed25519, `PROTOCOL.md:41`). Both
  `dependencies.dart:235-273` and `pairing_viewmodel.dart:61-67` already pass the
  **Owner** keypair into pairing and into every reconnect. Plan 23 replaced
  `DeviceIdentity` outright (`plan/23`, "Migração: Nenhuma").

---

## 8. Swift API the native client should expose

Types only — no implementation here.

```swift
// ── Value type ────────────────────────────────────────────────────────────
/// 32-byte Ed25519 public key + 32-byte seed. Blob layout is pk || seed.
/// Deliberately NOT Codable: the persisted form is 64 raw bytes, and any
/// JSON/plist encoder here would silently break cross-device compatibility.
struct OwnerIdentity: Equatable, Sendable {
    let publicKey: Data      // exactly 32
    let privateSeed: Data    // exactly 32
    init?(publicKey: Data, privateSeed: Data)      // nil unless both are 32
    init?(blob: Data)                              // nil unless blob.count == 64
    var blob: Data { get }                         // pk || seed, 64
}

// ── Errors — mirror the plugin's three codes (RemotePiIdentityPlugin:176-195)
enum OwnerIdentityError: Error {
    case syncUnavailable(reason: String)           // ⇒ the boot gate
    case keychain(status: OSStatus, operation: String)
    case malformedBlob(byteCount: Int)             // ⇒ NOT recoverable by retry
}

// ── Storage boundary ──────────────────────────────────────────────────────
protocol OwnerIdentityStoring: Sendable {
    func load() throws -> OwnerIdentity?           // nil == first run
    func save(_ identity: OwnerIdentity) throws
    func delete() throws                           // idempotent; propagates to all devices
    func isSyncAvailable() -> Bool                 // see §3 — weak signal by design
    /// Emits the current identity on subscribe, then on every observed change.
    /// Byte-deduplicated. Never emits on delete.
    func changes() -> AsyncStream<OwnerIdentity>
}

struct KeychainOwnerIdentityStore: OwnerIdentityStoring { /* = KeychainSyncStore + observers */ }
struct InMemoryOwnerIdentityStore: OwnerIdentityStoring { /* tests; see in_memory_store.dart */ }

// ── Boot gate ─────────────────────────────────────────────────────────────
enum OwnerBootResult: Sendable {
    case syncUnavailable                            // ⇒ show the sync-required gate
    case ready(OwnerIdentity, generated: Bool)      // generated == true ⇒ onboarding eligible
}

actor OwnerIdentityBridge {
    init(store: OwnerIdentityStoring, pairing: PairingStore)

    private(set) var current: OwnerIdentity?
    var currentOwnerPublicKey: Data? { get }        // for mesh publish/fetch

    /// §4.1. Make this genuinely idempotent (the Dart doc claims it and the
    /// code is not — see Traps §10.8): return the cached identity when set.
    func boot() async -> OwnerBootResult

    /// Rehydrated signing key for WS auth + mesh signing.
    /// Precondition: boot() returned .ready. Throw otherwise.
    func requireSigningKey() throws -> Curve25519.Signing.PrivateKey

    /// §5.2. Install ONLY after boot() returned .ready.
    func startWatching(onOwnerReplaced: @Sendable () async -> Void)
    func stopWatching()
}
```

Codable guidance, narrowly:

- **`OwnerIdentity`: no Codable.** 64 raw bytes, hand-rolled.
- **Mesh blob: no `JSONEncoder`.** Build the canonical bytes by hand (see Traps
  §10.3). `Codable` is fine for *decoding* a fetched blob and for the
  `{blob,sig}` envelope and the relay's `{version,updated_at}` responses; for the
  bytes you **sign**, hand-serialize.
- The relay's JSON uses `snake_case` throughout (`owner_pk`, `issued_at`,
  `remote_epk`, `relay_url`, `paired_at`, `updated_at`, `room_id`, `name_rev`).
  If you use `Codable` for the decode side, either declare `CodingKeys` or set
  `.convertFromSnakeCase` — but never `.convertToSnakeCase` on the signing path,
  because the key **order** it produces is not the canonical one.

---

## 9. Test/acceptance checklist

1. Blob round-trip: `OwnerIdentity(blob:)` rejects 63 and 65 bytes; accepts 64;
   `blob` is byte-identical to `pk || seed`.
2. A key written by the Flutter app on device A is loadable by the native app on
   device B under the same Apple ID, and `publicKey` matches.
3. `save` twice in a row succeeds (no `errSecDuplicateItem`).
4. `load` on a fresh install with iCloud Keychain **on** but nothing synced yet
   returns `nil` (→ generate), not an error.
5. Boot with the Keychain refusing (`errSecInteractionNotAllowed`) → gate, and no
   identity generated.
6. Watch: subscribe → get the current blob once; re-save the identical blob → no
   second emit; foreground round-trip with no change → no emit.
7. Owner swap: inject a different-pk blob → peers **and** rooms are wiped, the
   connection is dropped, the mesh watermark resets, boot re-runs.
8. Watch subscribed before boot with `current == nil` → adopt, **no wipe**
   (regression test for the incident in `owner_identity_bridge.dart:130-146`).
9. Sign a fixture mesh blob and verify the bytes against
   `relay/src/mesh/verify.rs` expectations — same `owner_pk_hash` hex, and the
   canonical bytes byte-equal to what `mesh_blob.dart:139-147` produces for the
   same input.

---

## 10. Traps

### 10.1 `kSecAttrSynchronizable` is all-or-nothing at query time

Documented at `KeychainSyncStore.swift:13-16`: "a query that omits or sets it
differently from how the item was stored will match no item, even if the
service/account match." A query without the flag will not find a synchronizable
item, and a query with the flag will not find a local one. **Every** query in
`baseQuery()` passes it explicitly. Symptom of getting this wrong: `load()`
returns `nil` on a device that visibly has the item → the app happily *generates a
second Owner key* → the mesh blob is now signed by a key nobody recognizes → every
paired Pi self-revokes. This is the single most destructive mistake in this spec.

### 10.2 `isSyncAvailable() == true` does not mean iCloud Keychain is on

§3. The probe only asks whether the Keychain answered. On a device with iCloud
Keychain off, the whole flow succeeds locally, the key is generated and stored
non-synchronized-in-practice, and the divergence surfaces later as "my iPad shows
no Pis". Consequence for the native client: the gate must stay driven by the
`sync_unavailable` **error** on load/save, exactly as the Dart bridge does
(`owner_identity_bridge.dart:64-71`), and the `/sync-required` screen must keep
its "Check again" retry — it is the only recovery path, because there is no signal
to observe.

### 10.3 Canonical JSON: Foundation will corrupt it in two different ways

The relay verifies the signature over the exact bytes it received
(`relay/src/mesh/verify.rs:34-39`) — so an incorrect canonical form still gets a
`200`, and the damage shows up on *other* clients that re-derive the bytes. The
two Foundation traps:

- `JSONSerialization` / `JSONEncoder` escape `/` as `\/`. Every `relay_url` in
  `members[]` contains `//` (`"wss://…"`). Dart's `jsonEncode` does **not** escape
  it (`mesh_blob.dart:146`). Same logical object, different bytes.
- `JSONEncoder.OutputFormatting.sortedKeys` sorts, but you still control neither
  the number formatting of `issued_at`/`version` nor the escaping table.

Rule: hand-build the canonical bytes. Keys ASCII-sorted, no whitespace, no
gratuitous escaping, integers as bare decimal. Then sign those exact bytes and
base64 them into `blob`; **never re-encode a blob you are about to verify**
(`mesh_envelope.dart:16-18`: "never re-encode it — Ed25519 verification operates
on the exact bytes that were signed").

### 10.4 The `NSUbiquitousKeyValueStore` observer is decorative at best

`RemotePiIdentityPlugin.swift:141-145` observes
`NSUbiquitousKeyValueStore.didChangeExternallyNotification` on
`NSUbiquitousKeyValueStore.default`. But `KeychainSyncStore.swift:82-84` states
plainly that this app ships **no iCloud entitlement**. Without the ubiquity-KVS
entitlement the default store does not participate in iCloud, so the
external-change notification does not arrive — the comment at `:138-140` already
concedes the store "doesn't carry our blob". The **working** trigger is the
foreground re-read at `:131-136`. Do not treat the KVS observer as a sync signal
in the native port; drop it or earn it with a real entitlement.

### 10.5 The account is a constant — the owner key must never be a key

`kSecAttrAccount = "singleton"` (`KeychainSyncStore.swift:26`). Keying the item by
`owner_pk` (or by a hash of it) breaks the entire design: the "different owner
arrived" detection in `owner_identity_bridge.dart:147-163` works precisely because
there is **one slot** whose contents can change under you. With per-key slots you
would accumulate identities and never notice a swap. Same rule elsewhere:

- `PairingStorage` keys are `dev.remotepi.peers:<remote_epk>` and
  `dev.remotepi.rooms:<remote_epk>` (`app/lib/pairing/storage.dart:7-8`, `:283`,
  `:354`) — the **Pi** key, never the Owner key.
- Post-plan-61, `room_id == session_id`, a UUID (`app/lib/pairing/storage.dart:37-41`).
  It is not derived from a key, a cwd, or a name. Do not compute it.
- The Owner key appears as a URL path segment only as `sha256(raw32)` hex, never
  raw and never base64 (§6.2).

### 10.6 base64: standard vs url-safe, and the mixed-alphabet cliff

Read `app/lib/data/transport/epk_encoding.dart:1-15` — it exists solely because
this broke twice. The state of the world:

| Producer | Variant |
|---|---|
| QR payload + `PairingStorage.remoteEpk` | base64**url**, unpadded (`epk_encoding.dart:41-49`) |
| relay registry / `hello.pubkey` / `peer` envelope field | base64 **standard**, padded |
| mesh blob `owner_pk` and `members[].remote_epk` | base64 **standard**, padded |
| Keychain blob | **not base64 at all** — 64 raw bytes |

`mesh_sync_service.dart:209-223` carries the incident report: the pi-extension
compares its own key (formatted standard) against `members[].remote_epk`; a
url-safe string there reads as "I'm not listed" → **self-revoke**. Hence
`toStandardB64(p.remoteEpk)` on the way out.

Both non-Dart implementations accept either alphabet but **reject mixed
alphabets** in one string: `relay/src/identity.rs:15-19` and
`pi-extension/src/mesh/encoding.ts:43-47`. The pi-extension is stricter still — it
rejects non-canonical trailing bits (`encoding.ts:83-88`). Native rule: **emit
standard padded base64 everywhere on the wire; never compare base64 strings —
decode to 32 bytes and compare bytes** (`encoding.ts:14-16`).

### 10.7 A malformed 64-byte blob bricks the app at the splash screen

`OwnerIdentity.fromBlob` throws `FormatException`
(`owner_identity.dart:51-55`). `MethodChannelOwnerIdentityStore.load()` catches
only `PlatformException` (`method_channel_store.dart:30-32`), so the
`FormatException` escapes. `boot()` catches only `SyncUnavailable` and
`IdentityStoreError` (`owner_identity_bridge.dart:79-83`), so it escapes there
too. `_BootState.load` awaits `boot()` with no try (`app_router.dart:70`), so
`_ready` never flips and the redirect pins the user on `/boot` forever
(`:216`). Same shape for a non-`SyncUnavailable` failure inside `_generateAndSave`
(`:86-91` catches only `SyncUnavailable`).

There is no automatic recovery today: a wrong-length item in iCloud Keychain
propagates to every device and each one hangs on the splash. The native client
**must** classify a malformed blob as its own error and pick a policy —
recommended: surface a distinct "corrupted identity — reset" screen that offers
`delete()` + regenerate, and never silently overwrite (that would rotate the
Owner key and self-revoke every Pi). Related: `watch()`'s decode throws inside the
stream map (`method_channel_store.dart:52-57`) and the bridge's `onError` is an
**empty block** (`owner_identity_bridge.dart:161-162`) — a corrupt sync arrival is
today invisible. Log it.

### 10.8 `boot()` is documented idempotent and is not

The doc comment says "Idempotent — repeated calls are cheap once `_current` is
populated" (`owner_identity_bridge.dart:62-63`), but the body never consults
`_current` — it hits `store.load()` every time (`:72-92`). `/sync-required`'s
"Check again" calls it again (`sync_required_page.dart:27`). Consequence: if the
underlying item changed between calls, `boot()` replaces `_current` **without
wiping peers**, because the wipe lives only in the `watch()` path (§5.2). Make
`boot()` actually cache, and route every identity *change* through the single
watch path.

### 10.9 The owner-swap wipe leaves message history and preferences behind

`PairingStorage.wipeAll` clears only the `dev.remotepi.peers:` and
`dev.remotepi.rooms:` prefixes (`app/lib/pairing/storage.dart:341-350`).
`Preferences` (including `selectedRoomRaw` = `epk:roomId`, see
`app_router.dart:105-146`) and the local message SSOT boxes (`LocalBoxes`,
`main.dart:19` only wipes the *volatile runtime* box) survive. After an Owner
swap, the new identity can therefore inherit a selected-room pointer and chat
transcripts belonging to the previous human. Decide this explicitly in the native
client; do not inherit the omission by accident.

### 10.10 `delete()` is a fleet-wide destructive operation

`SecItemDelete` on a synchronizable item propagates the tombstone through iCloud
Keychain (`KeychainSyncStore.swift:69`). The Dart app never calls it — `grep`
shows `OwnerIdentityStore` referenced only in `dependencies.dart:67-68` and the
bridge holds no delete path. Do not wire it to a "sign out" affordance. It also
skips the `isSyncAvailable` pre-flight the other two operations have
(`RemotePiIdentityPlugin.swift:103-113` vs `:56-59`, `:74-77`), so it can succeed
in states where load/save report unavailable — and it emits nothing on the watch
stream (`:106`), so other in-process subscribers never learn the identity is gone.

### 10.11 `kSecAttrAccessible` is set on add and never on update

`SecItemUpdate` at `KeychainSyncStore.swift:49-51` passes only `kSecValueData`;
`kSecAttrAccessibleAfterFirstUnlock` is attached only in the `SecItemAdd` branch
(`:59`). An item that ever landed with a different accessibility class keeps it
forever. Two consequences: (a) if you ever change the accessibility constant, add
an explicit migration — a plain re-save will not move it; (b) never choose a
`…ThisDeviceOnly` variant here — those are by definition non-syncable and defeat
the whole feature. `AfterFirstUnlock` (not `WhenUnlocked`) is what lets a
background reconnect read the key on a locked-but-once-unlocked device; keep it.

---

## 11. Where the implementations disagree

| # | Disagreement | Who wins |
|---|---|---|
| 1 | **Is `isSyncAvailable()` a boot gate?** The plugin README says call it first and bail (`README.md:63-68`), and the plugin pre-flights it on `load`/`save` (`RemotePiIdentityPlugin.swift:56-59`, `:74-77`). The Dart bridge explicitly refuses to gate on it (`owner_identity_bridge.dart:64-71`, issue #39). | **The bridge.** Gate only on the `sync_unavailable` error from load/save. Keeping the native pre-flight is fine — it is what *produces* that error — but never call `isSyncAvailable()` from the app layer as a gate. |
| 2 | **iOS minimum.** `ios/remote_pi_identity.podspec:18` says `:ios, '18.0'`; `README.md:47` and `plan/23-owner-key-sync.md` ("Versão mínima iOS: iOS 26.0") say 26.0. | **The docs (26.0) express product intent**; the podspec is stale. Nothing in `KeychainSyncStore.swift` needs either — the APIs used are ancient. Pick your own target; do not read 18.0 as a decision. |
| 3 | **epk base64 variant.** App storage/QR: url-safe unpadded. Relay + pi-extension + mesh blob: standard padded. | **Standard padded wins on the wire.** The app normalizes on the way out (`mesh_sync_service.dart:209-223`, `ws_transport.dart:312-321`). A native client should store standard internally and skip the conversion layer entirely. |
| 4 | **Strictness of key decoding.** Relay accepts standard/url-safe, padded/unpadded, rejects mixed (`relay/src/identity.rs:14-30`). Pi-extension additionally rejects non-canonical trailing bits and odd padding (`pi-extension/src/mesh/encoding.ts:49-88`). Dart's `toStandardB64` silently returns the input unchanged when it cannot parse (`epk_encoding.dart:33-35`). | **The pi-extension is the strictest consumer** — target it. Never adopt Dart's lenient fallback; a pass-through of an unparseable epk is how a bad key reaches the blob. |
| 5 | **`nickname` absent vs null.** Dart omits when null (`mesh_blob.dart:35`); the relay's `Option<String>` accepts both (`relay/src/mesh/types.rs:29`). | **Omit.** Match the shipping producer; explicit `null` is untested against the pi-extension. |
| 6 | **`boot()` idempotence**: doc comment vs body (§10.8). | **The body is the current behavior; the doc is the intended one.** Implement the doc. |

---

## 12. Could not be determined from the code

1. **Q1 — Is there any recovery UX for a corrupted / wrong-length blob?** None
   exists (§10.7). The failure mode is a permanent splash-screen hang on every
   device of that Apple ID. A policy decision is required before shipping native;
   this spec recommends a dedicated reset screen but the product answer is not in
   the repo.
2. **Q2 — Blob size ceiling.** `plan/23-owner-key-sync.md` leaves "Q4 — Limites de
   tamanho" open, but that concerns Block Store's ~1KB limit on Android. For a
   64-byte iOS Keychain item it is moot; no iOS-side limit is stated anywhere.
   Treat as non-issue for iOS, unresolved for the product.
3. **Q3 — Sync latency while the app stays foregrounded.** The only real trigger
   is `willEnterForeground` (`RemotePiIdentityPlugin.swift:131-136`). Nothing in
   the repo states the expected iPhone↔iPad live-sync latency, and no polling
   interval is defined. The `plan/23` P3 goal ("iPhone + iPad simultâneos") is not
   met by the current trigger set for a session that never backgrounds. Needs a
   product answer (poll interval? accept next-foreground?).
4. **Q4 — Keychain access group / app-extension sharing.** No
   `kSecAttrAccessGroup` and no `.entitlements` file exists anywhere under
   `app/ios` or the plugin. If the native client ships a share extension, a
   widget, or a notification-service extension that needs the Owner key, the
   access group must be introduced — and doing so **changes the item's identity**,
   so it needs a migration plan. Unspecified today.
5. **Q5 — Multiple Apple IDs / account switch mid-session.** iOS gives no
   notification for "iCloud account changed" that this code observes. Behavior on
   account switch is untested and undocumented; the swap would surface, if at all,
   as a different blob at the next foreground → the §5.2 wipe path.
