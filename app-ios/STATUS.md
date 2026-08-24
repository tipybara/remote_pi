# app-ios — STATUS

Handover snapshot, 2026-08-25, after the six library targets were written
concurrently and integrated.

**Bottom line: the six libraries are still the core; the app target is now a
real composition root.** `AppModel` opens the store, resolves a KeyStore
(Keychain, falling back to a file seed when the unsigned simulator hits
`-34018`), connects `RelayWebSocketTransport`, and drives `SessionCoordinator`
+ `PairingCoordinator`. Home shows Device → Workspace → Session and a paste-QR
sheet. Chat, mesh publish, and a live-relay automated test are still missing.

---

## Commands

Run from `/Users/yang/workspace/remote_pi/app-ios`.

```bash
swift build     # all six libraries
swift test      # 397 tests
```

```bash
# App target (RemotePi.xcodeproj is generated, NOT checked in)
xcodegen generate
xcodebuild -project /Users/yang/workspace/remote_pi/app-ios/RemotePi.xcodeproj \
           -scheme RemotePi -sdk iphonesimulator \
           -destination 'generic/platform=iOS Simulator' build
```

`swift build` / `swift test` compile for **macOS** (`arm64e-apple-macos14.0`).
Only `xcodebuild` proves the iOS SDK. Run both — a green `swift test` alone does
not mean the app compiles.

---

## Current state

| Command | Result |
|---|---|
| `swift build` | **Build complete**, 0 errors, **0 warnings** (clean scratch dir) |
| `swift test` | **397 executed, 0 failures, 2 skipped** |
| `xcodegen generate` | OK |
| `xcodebuild … build` | **BUILD SUCCEEDED** |

Swift tools 6.0, Swift 6 language mode, `SWIFT_STRICT_CONCURRENCY: complete`.
Zero third-party dependencies — CryptoKit, Security, SQLite3, Foundation only.

---

## What compiles

All six library targets, for macOS (`swift build`) **and** for the iOS simulator
in both arches. Verified in DerivedData — `arm64-apple-ios-simulator` and
`x86_64-apple-ios-simulator` `.swiftmodule` outputs exist for every one of
`RemotePiProtocol`, `RemotePiCrypto`, `RemotePiTransport`, `RemotePiSession`,
`RemotePiPairing`, `RemotePiStore`.

The app target links the `RemotePiKit` umbrella product, so all six are built by
the Xcode path, not just the one `ContentView` imports.

---

## What is tested

397 tests, all XCTest. No swift-testing suites yet (the six `Test run with 0
tests in 0 suites` lines in the log are the empty swift-testing runner, not a
failure).

| Target | Tests | Notes |
|---|---|---|
| `RemotePiProtocolTests` | 112 | wire shapes, envelope, control frames, patch tri-state |
| `RemotePiSessionTests` | 74 | room registry, catalog grouping, control-plane RPC |
| `RemotePiPairingTests` | 64 | QR parse, pair frames, mesh publish, peer directory |
| `RemotePiTransportTests` | 57 | handshake ordering, frame codec, reconnect timing |
| `RemotePiStoreTests` | 49 | SQLite behaviour, Hive-record compat, session keying |
| `RemotePiCryptoTests` | 41 | RFC 8032 vectors, EPK encoding, relay auth sig, 2 skipped |

### What that coverage is actually worth

Good: the wire-facing modules are tested against fixtures hand-derived from the
Rust/Dart/TS ground truth, and I spot-checked the riskiest ones myself (below).
The base64url-vs-standard trap has ten dedicated tests.

Weak: **every test is in-process against fakes.** Nothing has ever talked to a
running relay or a real Pi. `RemotePiTransport` is tested through an injected
`WebSocketChannelFactory`, never through `URLSessionWebSocketChannel`. Byte
compatibility is *asserted*, not *observed*. The first real connection will find
things these tests cannot.

### Skipped tests (2)

```
RemotePiCryptoTests.KeyStoreTests.testKeychainRoundTrip
RemotePiCryptoTests.KeyStoreTests.testKeychainLoadOrCreateIsAtomicUnderConcurrency
```

Both skip with `OSStatus -34018` (`errSecMissingEntitlement`) — a command-line
XCTest host has no keychain-access-group entitlement. This is a **host
limitation, not a bug**, and it is self-reported by the test rather than
silently passing. `KeychainKeyStore` is therefore **unverified on device**.
Exercise it in a simulator/device test target before trusting it; a bug in
`loadOrCreateOwnerKeySeed` mints a second Owner identity and orphans every
existing pairing.

---

## Integration conflicts found and resolved

Far fewer than expected. The six agents respected the shared seams almost
perfectly.

**1. One test failure — `ClientMessageWireTests.testEnvelopeCarriesStandardBase64AndNoTypeKey`.**
It compared the inner `ct` payload as a raw string:

```swift
XCTAssertEqual(String(data: inner, encoding: .utf8), #"{"type":"ping","id":"ping_7"}"#)
```

The encoder emitted `{"id":"ping_7","type":"ping"}`. **The test was wrong about
its own module**, and it contradicted the policy documented in its own
`WireFixtures.swift`: *"A string comparison of encoder output would pin key
order, which is not part of the wire contract."* Every other assertion in the
suite compares parsed `NSDictionary`s; this one assertion did not.

Root cause, confirmed by an isolated probe: Foundation's `JSONEncoder` does
**not** emit a keyed container in insertion order. `ClientMessage.encode`
genuinely writes `type` before `id`; the encoder reorders anyway. Adding
`.sortedKeys` would have produced `id`-first, which matches neither the test nor
Dart.

Fix: made that one assertion order-insensitive, preserving its intent (the inner
frame carries exactly `type` and `id`, nothing else). **No test was deleted or
weakened** — it still fails if a key is added, dropped, or given a wrong value.

Key order is not part of the wire contract: Dart `jsonEncode` emits insertion
order, `serde_json` emits struct order, `JSONEncoder` emits its own, and all
three parse each other fine.

**2. No duplicated vocabulary.** I diffed every `public` type name across the six
modules — zero collisions. `RemotePiProtocol` is the sole hub (27 files import
it); nothing redefines a concept that lives there.

**3. `MessageRole` vs `StoredMessageRole` — checked, not a duplication.**
`RemotePiStore.MessageRole` (`user/assistant/tool/compaction/divider`) is the
on-disk Hive-compatible spelling; `RemotePiProtocol.StoredMessageRole`
(`user/agent/event`) is the seam's deliberately lossy view. `SQLiteSessionStore`
bridges them explicitly and conforms to the `SessionStore` seam. Correct
two-level model, left alone.

**4. No scaffolded bodies.** `ScaffoldError` / `notImplemented` exist as types
but are **never thrown anywhere**. There are no `fatalError`s, no
`preconditionFailure`s, no TODO/FIXME markers in `Sources/`. The
implementations are real.

### Ground-truth spot checks I ran myself

Because each module's tests were written by the same agent that wrote the
module, I verified the load-bearing plan-61 details directly against the Rust
and Dart rather than trusting the tests:

- **`transport_error`** — Swift decodes `peer` (required), `room_id` defaulting
  to `main`, `reason` defaulting to `unknown`. Matches `protocol.dart:86-90`
  exactly, and matches what `relay/src/handlers/peer.rs:431` emits.
- **`name_rev` gating** — `RoomMetaPatch.nameAccepted(over:)` reproduces
  `relay/src/peers/registry.rs:307-311` case for case: no name → never accepted;
  both revisions present → strictly-greater only; either missing → accepted.
- **Patch tri-state** — `PatchField` is a real three-way (`.absent` / `.clear` /
  `.set`), serialized through a dictionary rather than `Codable`, so
  absent-preserves and explicit-`null`-clears stay distinguishable. This is the
  thing `Codable` would have quietly collapsed.
- **`room_id == session_id`**, `ctrl` reserved and shaped so it cannot collide
  with a session id — present and asserted.

I did **not** audit every frame. Treat the above as evidence the protocol module
was built from the real sources, not as a completed conformance review.

---

## Stubbed

**The entire UI.** `App/Sources` is 44 lines:

- `RemotePiApp.swift` (16 lines) — `@main`, one `WindowGroup`.
- `ContentView.swift` (28 lines) — a terminal glyph, the word "Remote Pi", and
  `RoomID.control.rawValue` rendered as a footnote to prove the package
  dependency links.

That is the whole app. There is no Home, no device/workspace/session list, no
chat, no pairing screen.

**Declared-but-absent capabilities.** `App/Info.plist` carries purpose strings
for camera, microphone, speech recognition, and photo library. **No code uses
any of them** — no `AVFoundation`, no `Speech`, no `PhotosUI` anywhere in
`Sources/` or `App/`. In particular there is **no QR scanner**:
`PairingQRPayload` parses a payload string, but nothing produces that string
from a camera.

---

## Missing

### 1. The composition root — this is the headline

Import graph as it actually stands:

```
RemotePiProtocol   ← imported by 27 files   (the hub; the seams held)
RemotePiCrypto     ← imported by 6
RemotePiTransport  ← imported by 1
RemotePiSession    ← imported by 0
RemotePiPairing    ← imported by 0
RemotePiStore      ← imported by 0
```

Three fully-implemented, fully-tested modules are consumed by **nobody**.
Nothing constructs a `SessionCoordinator`, opens a socket, or opens the
database. The app cannot connect to anything.

The good news: **the seams line up, and I verified it rather than assuming it.**
I temporarily added a probe to the app target that builds the real object graph,
confirmed `BUILD SUCCEEDED` against the iOS SDK, then removed it. This
type-checks today:

```swift
let store: any SessionStore     = try SQLiteSessionStore(root: someDirectory)
let transport: any RelayTransport = RelayWebSocketTransport()
let coordinator = SessionCoordinator(transport: transport, store: store)
let control     = MachineControlClient(transport: transport)
try await transport.connect(to: relayURL, as: signer)   // signer: Ed25519Signer
```

`SessionCoordinator(transport:store:)` is the intended composition point. Note
`RelayWebSocketTransport()` takes no URL or signer — those go to `connect(to:as:)`
— and it is single-use: after a disconnect you must build a new one
(`"transport already used; build a new one"`). `RelayConnectionManager` is the
actor that owns that lifecycle; wire it, don't hand-roll reconnection.

### 2. No end-to-end test

Nothing has been run against a live relay or Pi extension. There is no
integration harness in this package. Byte compatibility with the Rust relay and
the Node/TS Pi is inferred from reading their source, not demonstrated. **Assume
the first live connection surfaces bugs**, most likely in handshake ordering or
an optional field that is absent in practice but required by a decoder.

### 3. Package.swift declares an edge that is not used

`RemotePiSession` declares a dependency on `RemotePiTransport` but never imports
it — it talks to the `RelayTransport` seam in `RemotePiProtocol`. That is
*correct layering* (depend on the seam, not the implementation), so the edge is
merely redundant, not wrong. Left in place deliberately; removing it is
cosmetic and would only churn the manifest.

### 4. Not addressed at all

- Push notifications (`plan` has them; nothing here).
- Background modes — deliberately **not** declared in `Info.plist`, and the
  comment there explains why (no offline queue on the relay). Don't add them
  without revisiting that decision.
- App icon (`ASSETCATALOG_COMPILER_APPICON_NAME` is empty).
- Code signing (simulator-only; no team configured, by design).

---

## If you pick this up next

Done since this file was first written:

1. **Composition root** — `App/Sources/AppModel.swift`. Store + KeyStore +
   transport + `SessionCoordinator` + `PairingCoordinator`.
2. **Live round trip** — 2026-08-25, against the already-running local relay
   on `:3777` and `scripts/fake-pi.mjs`. Handshake, `pair_request`/`pair_ok`,
   then Device → Workspace → Session (jacobs-mbp / api+infra+web / 6 live
   tiles). The first attempt hung: `pair_ok` arrives from the QR `rm`, the
   phone's active room was `main`, and the transport demux dropped the reply
   while fake-pi had already enrolled us. Fix: `PairingCoordinator` calls
   `setActiveRoom(rm)` before send. Locked in
   `testPairOkFromQRRoomIsDroppedWhileActiveRoomIsMain`.
3. **Home UI** — empty state, paste-QR sheet, relay URL bar, `--pair` launch
   argument for camera-less pairing.
4. **Chat** — tap a session (or `--send <text>`). Persist pending
   `user_message` before the socket write, `session_sync` → `applyHistory` on
   open, live `user_message` echo + `agent_chunk` accumulation. Verified
   2026-08-25 against fake-pi: sent "hello from native", got the harness
   echo back in `api-worker`. Demux must `setActiveRoom` to the open
   session or the reply is dropped the same way pairing was.
5. **Reconnect + restore** — `ManagedRelayTransport` wraps
   `RelayConnectionManager` so a drop does not finish the coordinator's
   event stream; the next online re-subscribes. Cold start restores the
   last `SessionKey` (verified: relaunch opened `api-worker` with the
   previous transcript still on screen).
6. **Rename from Home** — swipe / context menu, or `--rename-to`. Sends
   `session_rename` to that session's own room and does **not**
   `retarget` / `select`. Verified 2026-08-25: `api-worker` →
   `zz-payments-api`, `room_id` unchanged, still first under `api (2)`
   (sort is room id, so a `zz-` label does not jump).

Still open, in order:

1. **Test `KeychainKeyStore` on a signed host.** Simulator used the file
   fallback (`Owner … · file`) because unsigned `kSecAttrSynchronizable`
   hits `-34018`.
2. Mesh publish after pair (skipped; fake-pi has no SelfRevoke).
3. Chat breadth (Phase 5): tool cards, images, queue/steer, cancel.
4. Live reconnect proof (kill the relay, watch the backoff, confirm
   rooms come back). Library tests cover the ladder; the app path is
   wired but not yet failed on purpose against this relay.

Do not trust `swift test` alone as a release gate — it does not compile for iOS
and it never opens a socket.
