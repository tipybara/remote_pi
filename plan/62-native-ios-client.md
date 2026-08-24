# 62 — Native iOS client

**Status:** proposed 2026-08-25. **Not started.** Phase 0 is a decision gate, not code.
**Protocol baseline:** post plan 61 (`room_id == session_id`, `name_rev`, `ctrl` room,
`transport_error`). See [`PROTOCOL.md`](../PROTOCOL.md) and
[`plan/61-stable-session-identity.md`](61-stable-session-identity.md).
**Work happens in:** `app-ios/` (already scaffolded: six module dirs + `App/` + `Tests/`).
**Must not change:** `app/lib/**`, `relay/src/**`, `pi-extension/src/**`, `PROTOCOL.md`.

---

## 0. This plan reopens a closed decision. Read this section before the rest.

[`plan/00-decisions.md:158`](00-decisions.md) currently says, under "Em aberto":

> **Apps nativos (Swift/Kotlin) em vez de Flutter** — Provavelmente nunca. Reconsiderar
> só se Flutter limitar features críticas (ex: integração profunda iOS Keychain).
> **Desktop: reconsiderado e mantido Flutter** — decidido no plano 37, validado em
> produção (Cockpit 1.13.0; plano encerrado 2026-07-19).

And [`plan/00-decisions.md:166`](00-decisions.md), under "Distribuição (fechado 2026-06-12)":

> **App mobile: distribuição DUPLA** — iOS = **App Store**; Android = **Play Store**
> (AAB) **+ APK direto**. […] Artefatos store-ready verificados em `1.1.0+5`.

**Both rows are being reopened by the user's explicit request**, on 2026-08-25, and the
reopening is the reason this plan exists. Per the convention at the bottom of
`00-decisions.md`, **that file is not edited by this plan.** It gets its strike-through
and its dated replacement row only after §0.4 is answered in conversation. Until then,
the closed decision is still the standing rule and this plan is a proposal.

### 0.1 What replacing the Flutter client costs

Measured on this checkout, `e0d9e95`:

| | Files | Lines |
|---|---|---|
| `app/lib/**` | 111 | 22,907 |
| `app/test/**` | 63 | 15,621 |
| Passing tests | | ~600 (`flutter test`; 595 recorded at plan 61 Phase 0, plus Phase 1–3 additions) |

The line count is the smaller half of the cost. The larger half is that those lines encode
bug fixes that are not deducible from the protocol, and that a fresh implementation will
rediscover by shipping them. A partial list, all of which the native client must
reproduce deliberately:

- the base64url/standard epk split and its single choke point
  (`app/lib/data/transport/epk_encoding.dart`, four prior regressions in its header comment);
- the room-pointer trio (`_activeRoomId` / `_activeRoomOwner` / `_activeRoomPinned`) and the
  "reseed only on a destination change" rule that stopped the chat jumping after backgrounding;
- clearing `_liveRoomIds` on disconnect so a reconnect cannot flash stale green tiles;
- the `_applyHistory` minimal-write diff that removed the "embaralha e some" flicker on every reconnect;
- 3 missed inner pings → mark the room offline **without** tearing down the WS, because
  tearing it down produced permanent lockouts;
- intercepting hardware Enter on the field's own (leaf) focus node, with an IME-composing guard;
- the hold-to-talk permission-prompt race that leaves a phantom recording running;
- `DismissOnSessionChange` on every chat-scoped sheet in the iPad split view.

`plan/62-specs/*.md` (nine documents, ~450 KB, written 2026-08-25) exist precisely because
that knowledge had to be excavated from three implementations rather than read off a
protocol document. **They are the deliverable that makes this plan feasible at all.** They
are also the honest measure of the cost: a native client is not "the protocol plus a UI",
it is those nine documents made executable.

Cutting the other way — the specs found real defects in the Flutter client that a rewrite
would not inherit, and that this plan deliberately does not reproduce (§3.1): local history
truncated to 30 events on every reconnect (spec 07 T1), no `transport_error` handling in
`SyncService` at all (spec 07 §2.5), `sendToRoom` replies dropped by the client's own demux
(spec 03 T5), `list_models` failures surfacing as a 15 s timeout instead of the real message
(spec 01 T5), a non-idempotent `boot()` that can swap the Owner identity without wiping
(spec 05 §10.8), and a mesh 409-retry that can silently undo a revoke (spec 06 T8). Those
are arguments for **rewriting**, not for **going native** — every one of them is fixable in
Dart, and cheaper there.

### 0.2 Android. This does not go away by not mentioning it.

**A native iOS client does not replace the Android client.** There is no shared code path
between them: the Flutter app is one binary for both platforms today, and a Swift client
covers exactly one of them. So the reopened distribution row has two possible answers and
no third that costs nothing.

**Branch A — Android keeps the Flutter app. Two clients, permanently.**

- Nothing gets deleted. All 22,907 lines of `app/lib/**` stay alive and maintained; the
  native client is pure addition, not replacement.
- Every protocol change lands **twice**, in two languages, with two test suites. The
  protocol is not stable: plan 61 landed on 2026-08-24 and changed session identity,
  rename semantics, dest-miss behaviour and added a whole control plane. The next such
  plan costs double from the day this branch is chosen.
- Two release trains, two crash surfaces, two sets of encoding traps to keep in sync.
  Spec 06 T1 alone (three consumers, three different base64 strictnesses) is a bug class
  that now has two client implementations to get wrong independently.
- Honest total: the mobile client's maintenance cost roughly doubles, forever, in exchange
  for the iOS-side wins in §0.3.

**Branch B — Android is dropped.**

- This directly contradicts `00-decisions.md:166`, which is a **closed** decision with
  verified artifacts (signed AAB and direct APK at `1.1.0+5`, CI covering the APK) and its
  own plan (`plan/44-app-android-apk-release.md`).
- It removes the **direct APK** channel, which is the product's only store-free
  distribution path. "Não precisamos subir pras lojas" was explicitly reinterpreted in that
  decision as "não *depender* delas" — dropping Android drops the independence, not just
  the platform.
- The Owner-key story loses half its surface: `plan/23-owner-key-sync.md` is built on
  iCloud Keychain **and** Android Block Store. Spec 05 §7.3 notes the Block Store half has
  real limitations (no live sync, no cross-ecosystem sync, no per-device revoke) — those
  bound the *product*, and dropping Android is one way to stop paying for them, but it is
  also giving up every non-Apple user of a product whose pitch is "control your Mac from
  your phone".
- Honest total: strictly cheaper to build and maintain, strictly smaller product.

**Branch C — native iOS is a second client that does not ship until it earns the right to.**
Flutter stays the shipping client on both platforms. The native client is built to the
conformance gate in Phase 8 and only then does the user choose A or B with real evidence
(a working binary, a measured feel, a real App Store submission) instead of a forecast.

**This plan recommends Branch C as the default**, because it is the only branch that lets
Phases 0–4 start without forcing the A/B answer today, and because the A/B answer is much
easier once a native binary exists to compare against. It is a deferral, not an avoidance:
§0.4 still has to be answered before Phase 8 closes.

---

#### ANSWERED 2026-08-25 — Android is set aside, provisionally

The user answered §0.4 Q1 with **「暂时放弃 android」** — *temporarily* drop Android.

Recorded as written: **provisional, not closed.** 「暂时」 is a qualifier and this plan does
not upgrade it to Branch B. Concretely that means:

- Android work stops; the native iOS client is unblocked and does not have to carry a
  double-implementation argument.
- **Nothing Android is deleted or marked abandoned.** `plan/44-app-android-apk-release.md`,
  `.github/workflows/app-release.yml` and `scripts/docker-build-apk.sh` stay exactly as they
  are. Deleting them would convert 「暂时」 into 「永久」 on the user's behalf, and the
  artifacts they produce (signed AAB + direct APK, verified at `1.1.0+5`) are expensive to
  reconstruct.
- **`plan/00-decisions.md:166` is NOT struck.** Per §0.4 the strike lands only after all four
  questions are answered; three are still open, and a provisional answer to one of them is
  not grounds for editing a closed decision row.

**What this answer does and does not buy.** It removes Branch A's price — the mobile client's
maintenance no longer doubles. It does **not**, on its own, justify the rewrite: dropping
Android also makes the *cheapest* option cheaper, namely keeping Flutter and shipping
iOS-only, which costs zero of the 22,907 lines. The case for native still rests entirely on
§0.3 — the identity-plugin boundary and Keychain depth — which is §0.4 Q4 and is still
unanswered. See R8.

### 0.3 What this plan is actually betting on — and what it is not

| Candidate reason | Evidence in this repo | Betting on it? |
|---|---|---|
| **iOS simulator / architecture friction** | `app/pubspec.yaml` in this working tree bumps `mobile_scanner ^5.0.0 → ^7.4.0`. That is the whole fix, it is ~10 lines, and it is being done independently right now. | **No.** Naming it would be dishonest, and it would be the weakest possible justification for a 22,907-line rewrite. |
| **Toolchain / plugin-boundary friction** | `plan/61-stable-session-identity.md:88` lists "Publishing the Flutter app (identity plugin license still unresolved)" as an open blocker — i.e. the Flutter app **cannot ship today** for a reason that lives at the plugin boundary. The Owner key is already hand-written Swift (`KeychainSyncStore.swift`, 108 lines, zero Flutter imports); everything around it — `MethodChannel`, `EventChannel`, `FlutterStandardTypedData`, a three-code error-string mapping, a stale `:ios, '18.0'` podspec that disagrees with the documented 26.0 target — exists only to cross that boundary. | **Yes — primary.** |
| **Keychain / app-extension depth** | Spec 05 §12 Q4: no `kSecAttrAccessGroup`, no `.entitlements` anywhere under `app/ios` or the plugin. A widget, a share extension, or a notification-service extension needs the Owner key, and introducing an access group **changes the Keychain item's identity** and needs a migration. Push notifications (`00-decisions.md` "Push notifications: v2", `plan/36-push-notifications.md`) land on exactly that. And `00-decisions.md:158` names "integração profunda iOS Keychain" as *the* condition for reconsidering — this is that condition. | **Yes — secondary, and it is the trigger the closed decision itself wrote down.** |
| **Native input / Dynamic Type** | Spec 08 §9.2: the Settings "Text size" control exists *only* because the app hardcodes font sizes and Flutter cannot read iOS's per-app Text Size — a native client deletes the control and gets Dynamic Type. Spec 08 §8.7 and §8.9 document keyboard and gesture workarounds that are Flutter-shaped. | **Partly.** Real, and small. Not sufficient on its own. |
| **App Store review** | Nothing in the repo. The app has never been submitted. | **No.** |
| **Binary size** | Never measured anywhere in the repo. | **No.** |

Stated plainly: **the case for native rests on the plugin/Keychain boundary — the exact
condition `00-decisions.md:158` named — plus a smaller native-feel argument. It does not
rest on the simulator, on review, or on size.** If the identity-plugin licensing blocker
resolves before Phase 8, the primary reason weakens substantially and the user should be
told so rather than discovering it after the work is sunk.

### 0.4 The decision this plan owes back

Before Phase 8 closes, the user must answer, in conversation:

1. ~~**Android: Branch A or Branch B?**~~ — **answered provisionally 2026-08-25**: 「暂时放弃
   android」. Android work stops; nothing is deleted; `00-decisions.md:166` stays standing
   until this is confirmed as permanent. See the ANSWERED block in §0.2.
2. If A: who owns the Flutter client, and is doubling protocol work per plan accepted?
3. If B: is the direct-APK channel being given up, and does `plan/44` get marked abandoned?
   **Still open** — 「暂时」 deliberately did not answer this, and the answer is what turns
   the provisional call into a closed one.
4. ~~**Does the identity-plugin licensing blocker still stand?**~~ — **answered 2026-08-25
   by inspection, not by a legal opinion.** See the ANSWERED block below. The remaining
   case is Keychain depth + native feel, and R8 has fired.

Then, and only then, `00-decisions.md` gets edited: strike line 158's row, add a dated
replacement with the reason; and if Branch B, strike line 166's row the same way.

#### ANSWERED 2026-08-25 — Q4: the license blocker is administrative, not a third-party tangle

The user asked Q4 to be tested rather than guessed. Three files disagree:

| Location | Claim |
|---|---|
| repo-root `LICENSE` | MIT, Copyright (c) 2026 Jacob Moura |
| `app/packages/remote_pi_identity/LICENSE` | `TODO: Add your license here.` — 29-byte `flutter create` placeholder |
| `ios/remote_pi_identity.podspec` | `:type => 'Proprietary', :text => 'Internal use only'` |

That is three unaligned declarations, not a dispute with a third party.

iOS side of the plugin: 304 lines of original Swift, imports only Flutter / Foundation /
Security / UIKit, one git author, `publish_to: none`, zero Dart-side packages. No third-party
copyright header, no "adapted from", no SPDX of anyone else.

Android side: `com.google.android.gms:play-services-auth-blockstore:16.4.0` — a proprietary
binary under Google APIs terms. That is the plugin's only real third-party proprietary
dependency, and it sits on the Android path the user just set aside.

So after 「暂时放弃 android」, "license unresolved" on the iOS path collapses to: pick MIT or
Proprietary and make two files agree. Minutes, not a rewrite. **This is R8 firing.** The
primary §0.3 reason ("the Flutter app cannot ship today because of the plugin boundary")
does not survive this inspection. What remains:

- Keychain depth (`kSecAttrAccessGroup`, widget / share / push-v2) — real, and it is the
  reopen condition `00-decisions.md:158` wrote down, but it is **prospective**, not a
  current ship blocker.
- Native input / Dynamic Type — real and small; the plan already said not sufficient alone.

`00-decisions.md` is still not struck. Q3 is still open (「暂时」), and aligning the two
license files is a product choice (MIT vs Proprietary), not something this plan will pick.

Work on `app-ios/` continues because the user asked for the B path to be built, not because
Q4 still justifies it. The specs remain an asset either way — they found six real Flutter
defects that are cheaper to fix in Dart than to inherit.

---

## 1. Goal

A native iOS client that is **byte-compatible** with `relay/src/**` and
`pi-extension/src/**` as they exist at `e0d9e95`, with no protocol change on either side,
and no third-party Swift dependency in the wire path.

Non-goal: feature parity with `app/lib/**` on day one. Parity is Phase 7; correctness on
the wire is Phase 1.

---

## 2. Target model — modules

Already scaffolded at `app-ios/Sources/` and `app-ios/Tests/`. **Keep these names.**

```text
RemotePiCrypto      no deps
RemotePiProtocol    no deps
RemotePiTransport   → Protocol, Crypto
RemotePiStore       → Protocol
RemotePiSession     → Protocol, Transport, Store
RemotePiPairing     → Protocol, Transport, Crypto
App (SwiftUI)       → all of the above
```

| Module | Owns | Spec |
|---|---|---|
| **RemotePiProtocol** | `Codable` models for every inner `ClientMessage`/`ServerMessage`, every relay control frame, and the outer envelope. Encode/decode helpers. `RoomMeta` with the full post-plan-61 field set, and merge-patch application (absent / explicit-null / set) including the strictly-greater `name_rev` gate **as a pure function**. | 01, 02 |
| **RemotePiCrypto** | Ed25519 via CryptoKit `Curve25519.Signing`. **No third-party dependency.** Signing the relay auth challenge; signing the mesh blob. Base64 standard↔url-safe normalization mirroring `epk_encoding.dart` exactly — including its idempotence and its refusal to mangle unparseable input. | 03, 05, 06 |
| **RemotePiTransport** | `URLSessionWebSocketTask` client: hello/challenge/auth handshake, envelope send/receive, per-send `sendToRoom` that does **not** move the active room, inbound room demux with the `ctrl` exemption, presence/rooms subscription replay on reconnect, reconnect backoff, ping cadence and liveness watchdog, clearing cached live-room state on disconnect. Modelled as an `actor` exposing an `AsyncStream` of decoded events. | 02, 03 |
| **RemotePiSession** | The registry the UI reads: rooms per peer, the live set, applying `room_announced` / `room_ended` / `rooms` / `room_meta_updated` with correct preserve semantics, the `name_rev` gate, the Device → Workspace → Session grouping, and the control-room filter. Plus the machine control-plane client (`workspace_list` / `session_list` / `create_session` / `session_start` / `session_stop` / `session_rename`) with the idempotency contract and the wait-for-`room_announced` step. | 02, 08, 09 |
| **RemotePiPairing** | QR payload parsing, `pair_request`/`pair_ok` flow, `PeerRecord` storage, the Owner-key Keychain store with iCloud sync (port of `app/packages/remote_pi_identity/ios/Classes`), the boot-time sync gate and owner-drift wipe, and the mesh membership blob sign/publish/fetch. | 04, 05, 06 |
| **RemotePiStore** | Local persistence for sessions, messages and volatile runtime, keyed by `(epk, session_id)` — **never by session id alone.** SQLite per spec 07 §4. Must be an `actor`, must survive backgrounding, must expose `AsyncStream`s the UI observes. | 07 |
| **App** | SwiftUI. `NavigationStack` (compact) / `NavigationSplitView` (regular). | 08 |

### 2.1 Spec index — read before touching a module

| Spec | Subject | The part that will bite you |
|---|---|---|
| [01](62-specs/01-wire-messages.md) | Inner App↔Pi messages | T1 unknown `type` must not be fatal; T2 one bad history event must not kill the batch; T5 `list_models` fails as `error`, not `action_error`; T7 the `ask` envelope is camelCase inside a snake_case frame |
| [02](62-specs/02-relay-control-frames.md) | Relay control frames + envelope | Frame demux: a top-level string `type` makes it a control frame and it is **never forwarded**; the `name_rev` truth table; T4 `presence_check`/`rooms_check` are not request-response |
| [03](62-specs/03-relay-auth-transport.md) | Handshake, lifecycle, demux, targeting | `sig` is STANDARD base64 only (no url-safe fallback, unlike `pubkey`); success has **no ack**; T11 room subscriptions die on every reconnect, presence ones do not |
| [04](62-specs/04-pairing.md) | Pairing + peer storage | `pair_request` carries **no signature** (§12 D1); `hello.room_id` must be `"main"`; T5 absent vs `"main"` vs explicit for `pair_ok.room_id` |
| [05](62-specs/05-identity-keychain.md) | Owner key + Keychain | §10.1 `kSecAttrSynchronizable` is all-or-nothing at query time — getting it wrong generates a second Owner key and self-revokes every Pi |
| [06](62-specs/06-mesh-membership.md) | Membership blobs + self-revoke | T2 `JSONEncoder` cannot produce the canonical bytes (`\/` escaping); T6 `members: []` is a weapon; T8 the 409 retry can undo a revoke |
| [07](62-specs/07-local-storage.md) | Local persistence | T1 the Flutter client destroys local history on every reconnect — **do not copy**; T5 identity is `(role, id)`, not `id` |
| [08](62-specs/08-ui-inventory.md) | Screens + interactions | §12 what must survive backgrounding; §13.6 do **not** reproduce the `'main'` fallback room |
| [09](62-specs/09-control-plane.md) | `ctrl` room | D1/T1: the gateway addresses replies to `room:"ctrl"` while the app registers `"main"`. **Unverified. Answer it empirically in Phase 6 before designing around it.** |

---

## 3. Decisions (closed for this plan)

| ID | Decision |
|---|---|
| D1 | **No protocol change.** The relay and pi-extension are fixed binaries. Every disagreement is resolved in the client. If something genuinely cannot be done client-side, it stops this plan and opens a new one. |
| D2 | **No third-party dependency in the wire path.** Ed25519 is CryptoKit `Curve25519.Signing`; JSON is `Codable`; the socket is `URLSessionWebSocketTask`; the DB is `libsqlite3` (or GRDB, which does not change the schema). A crypto dependency here would reintroduce exactly the class of Dart↔Node interop pain that killed Noise XX in plan 06. |
| D3 | **An epk is 32 raw bytes in memory, never a `String`.** Exactly one `var wireForm: String` (standard + padding) serialises it, and a lenient `init?(anyBase64:)` mirrors `relay/src/identity.rs` (accept both alphabets, padded or not, **reject mixed**). Every dictionary key is the value type. This removes spec-02 T1 / spec-06 T1 structurally instead of by discipline. |
| D4 | **Absent ≠ null ≠ set, everywhere.** `enum Patch<T> { case unchanged; case set(T?) }`, decoded with `container.contains(key)` + `decodeNil(forKey:)`. `decodeIfPresent` is banned on any merge-patch field. |
| D5 | **Explicit `CodingKeys` on every type. No `.convertFromSnakeCase`.** The `ask` envelope is camelCase inside a snake_case frame (spec 01 T7), and `room_id`→`roomID` does not round-trip. |
| D6 | **Never derive a `room_id`.** It comes from `action_ok.session_id`, `session_list`, `room_meta.session_id`, or `pair_ok`. Never from a cwd, a name, or a hash. (plan 61 D8.) |
| D7 | **Never key persistent state by `room_id` alone.** Always `(epk, session_id)`. Enforced in the schema by `UNIQUE (machine_pk, session_id)` with no unique index on `session_id`. |
| D8 | **Never reproduce the `'main'` fallback session.** Selection is `sessionID: String?`; "no session" is a real state. (spec 08 §13.6.) |
| D9 | **Persistence is SQLite**, one file, WAL, `Application Support/RemotePi/`, `NSFileProtectionCompleteUntilFirstUserAuthentication`. Not Core Data, not files-per-session. Rationale in spec 07 §4.1. |
| D10 | **No migration from Hive. Re-sync.** Same call `boxes.dart:14-38` already made for `rp_v2`→`rp_v3`. (spec 07 §4.6.) |
| D11 | **`KeychainSyncStore.swift` is ported verbatim**, including its constants (`dev.remotepi.owner.identity` / `"singleton"`), its update-or-add order, and its `isSyncAvailable()` comment. Changing the service or account orphans every already-synced identity. |
| D12 | The blob is **64 raw bytes, `pk || seed`**, no header, no version, not `Codable`. A device running the Flutter app and one running the native app under the same Apple ID share one Keychain item. |
| D13 | The boot gate keys on the **`sync_unavailable` error from load/save**, never on `isSyncAvailable()` as a pre-flight. (spec 05 §11 row 1 — issue #39.) |
| D14 | An unknown inner `type`, an unknown control-frame `type`, and an unknown `session_history` event `type` are all **non-fatal**. Log and continue; never throw out of the socket read loop, never drop a whole history batch. |
| D15 | **iOS-only.** No Android target, no shared-core-for-Kotlin ambition, no cross-platform abstraction layer built "just in case". If Branch A is chosen, Flutter serves Android unchanged. |

---

### 3.1 Deliberate divergences from `app/lib/**`

These are the places where "byte-compatible with the wire" and "copy the Dart" disagree.
Each is a spec recommendation, not an improvisation. Implement the right column.

| # | Flutter behaviour | Native behaviour | Source |
|---|---|---|---|
| V1 | `session_history` replaces the box wholesale, truncating local history to the 30-event window on every reconnect | Buffer until `eos: true`, then reconcile the window against the local tail; keep older rows; delete only on an explicit `session_new` ack | spec 07 T1, §5.11 |
| V2 | `SyncService` has no `transport_error` case at all | On `transport_error{peer, room_id}`: fail every pending row for that `(peer, room)` and mark the room offline immediately; keep the ts-based 20 s reap as backstop | spec 07 §2.5, spec 02 §3.8 |
| V3 | `sendToRoom` to a non-`ctrl` room has its reply dropped by the client's own demux → spurious 15 s timeout | Demux on the inner payload's correlation, or exempt any room with an outstanding RPC. **Do not widen the exemption to "everything"** — that reintroduces chunk bleed | spec 03 T5 |
| V4 | `list_models` failure surfaces as a timeout because `ErrorMessage` is never matched against pending actions | Match `error.in_reply_to` against the pending-RPC map too | spec 01 T5 |
| V5 | `boot()` is documented idempotent and is not; an identity change through `boot()` swaps `_current` without wiping | Make `boot()` actually cache; route **every** identity change through the single `watch()` path that wipes | spec 05 §10.8 |
| V6 | A malformed 64-byte blob escapes uncaught and pins the app on the splash screen forever, on every device of that Apple ID | Classify `malformedBlob` as its own error and show a dedicated "corrupted identity — reset" screen offering `delete()` + regenerate. **Never silently overwrite** (that rotates the Owner key and self-revokes every Pi) | spec 05 §10.7 |
| V7 | A 409 on mesh publish re-pulls, re-applies the relay's blob to local storage, then re-snapshots — which can resurrect a peer the user just revoked | Carry the **intent** (`.add` / `.remove` / `.setNickname`) through the retry and rebase it onto the freshly fetched member set | spec 06 T8, T10 |
| V8 | A concurrent `publish()` is dropped, and the next pull deletes the dropped mutation locally | Serial actor with a coalescing dirty flag: publish again after the in-flight one completes | spec 06 T9 |
| V9 | Quick-actions row is labelled "New session" but sends `session_new`, which clears context in the same session | Ship plan 61's copy: **"New Context"** in quick actions; **"New Session"** only on Home (`create_session`). Wire names unchanged | spec 08 §13.4, plan 61 §Target model |
| V10 | Pre-auth inbound frames go into a one-shot `Completer` and a second frame is lost | Buffer post-challenge frames into the normal inbound path — a queue, not a promise | spec 03 T8 |
| V11 | The phone has no inbound-silence watchdog (only the Pi does) | Implement the Pi's watchdog: 70 s deadline, 20 s poll, refreshed by *any* inbound activity. The phone is more exposed to half-open sockets than a Mac daemon | spec 03 §3.5 |
| V12 | `_maybeAdoptLegacyRoom` adopts the first announced room and is **not** role-guarded | Any "adopt a room" heuristic filters `role == "control" || roomId == "ctrl"` first | spec 09 §2 |

---

## 4. Out of scope

- Android in any form (D15). A Kotlin client is a different plan that does not exist.
- Changing `app/lib/**`, `relay/src/**`, `pi-extension/src/**`, or `PROTOCOL.md`.
- Migrating Hive data (D10).
- `pi_envelope` / Pi→Pi forwarding. The relay carries the code; this fork emits none.
- `approve_tool` and any approval UI. The Pi ignores the frame and never replies.
- Restoring the local/cross-PC agent mesh (plan 61 D10).
- Push notifications. They are the *motivation* named in §0.3, not this plan's deliverable.
- Same-cwd multi-session, remote workspace registration, one-WS multiplex (plan 61, still open).
- Shipping to the App Store. Phase 8 decides whether that is even the goal.

---

## 5. Phases

Implement in order. Phases 0–4 are the first vertical slice: **pair → list sessions →
read a chat**. Do not start Phase 5 before Phase 4's acceptance holds end to end.

### Phase 0 — Decision gate + skeleton

No protocol code.

- Put §0.4 in front of the user and record the answer (or an explicit "Branch C, decide at
  Phase 8") at the top of this file.
- `app-ios/Package.swift` declaring the six library targets with the dependency graph in §2,
  plus six test targets. Zero external package dependencies.
- CI job running `swift build` and `swift test` on macOS.

**Accept:** `swift test` runs green with zero tests; `swift package show-dependencies`
lists nothing but the local targets; §0.4 has a recorded answer.

### Phase 1 — Codec floor: `RemotePiCrypto` + `RemotePiProtocol`

Offline. No socket. This is where the byte-compatibility risk actually lives, and it is
fully testable with no infrastructure — **which is why it comes first.**

- `PeerKey` (D3): 32 bytes, lenient `init?(anyBase64:)` mirroring `relay/src/identity.rs`
  (both alphabets, padded or not, **mixed rejected**), one `wireForm`.
- `toStandardB64` / `toAppEpk` equivalents, ported **test-for-test** from
  `app/test/data/transport/` — including idempotence and pass-through on unparseable input.
- Ed25519 sign/verify over raw bytes via CryptoKit. Seed ↔ `rawRepresentation` mapping
  per spec 05 §1.1.
- Hand-rolled canonical JSON serializer for the mesh blob (spec 06 T2). Not `JSONEncoder`.
- The whole inner `ClientMessage`/`ServerMessage` union, externally tagged on `type`, with
  an `.unknown(type:)` case (D14).
- Every control frame, the outer envelope, `RoomMeta`, `RoomMetaPatch`.
- `applyNamePatch(stored:incoming:) -> Decision` as a **pure function** implementing the
  relay's six-row truth table (spec 02 §4).
- `Patch<T>` decoding via `contains` + `decodeNil` (D4).

**Accept — golden vectors, all asserted as literals:**

1. `sha256("")` hex == `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`.
2. A fixed Owner keypair + two members (one with `nickname`, one without) produces canonical
   bytes **byte-identical** to what `app/test/data/mesh/mesh_blob_test.dart` asserts for the
   same input — key order `issued_at, members, owner_pk, version`, member order
   `nickname, paired_at, relay_url, remote_epk`, no whitespace, `//` **unescaped**.
3. The `name_rev` truth table, all six rows: no-name→reject; name+no-rev→accept;
   name+rev/no-stored→accept; equal→**reject**; lower→reject; higher→accept.
4. A `room_meta_updated` with `{"working":true}` leaves cached `model` and `thinking`
   untouched; one with `{"model":null}` clears `model`; one with no `model` key preserves it.
5. `Data(base64Encoded:)` failures on url-safe/unpadded input are handled — a 22-char token
   and a 43-char epk from a real QR decode to 16 and 32 bytes.
6. A mixed-alphabet epk (`+` and `-` in one string) is **rejected**, not coerced.
7. `{"type":"unknown_future_frame"}` decodes to `.unknown`, does not throw.
8. A `session_history` with one undecodable event yields the other events, not an empty list.
9. An encoded outer envelope contains exactly the keys `peer`, `room`, `ct` and **no `type`**
   (spec 02 T7 — a stray `type` makes the frame vanish silently).
10. Round-trip fixtures captured from `pi-extension/src/protocol/types.ts` and
    `app/lib/protocol/protocol.dart` for every frame in spec 01 §3 and §7.

### Phase 2 — `RemotePiTransport` against a locally-run relay

`cargo run` in `relay/` is the test fixture. No Mac, no pi-extension yet.

- hello → challenge → auth, signing the **32 raw nonce bytes**, `sig` as STANDARD base64.
- Handshake timeout 10 s; "closed within ~1 s of `auth`" classified as an auth failure,
  not a network blip (spec 03 §1.4).
- Frame demux, in the shipped order: `peer`+`ct` ⇒ envelope; else top-level `type` ⇒
  control frame; else drop.
- Inbound room demux with the `ctrl` exemption; `sendToRoom` that leaves the active room alone.
- Subscription replay on every connect: `subscribe_presence`, `presence_check`,
  `subscribe_rooms`, `rooms_check` — **all four**, because `subscribe_rooms` sends no snapshot.
- Backoff `[1, 2, 5, 10, 30] s`, clamped, **no jitter**; `retryAttempt` reset **only** on real
  inbound traffic, never on connect success.
- Inner ping every 25 s; 3 missed ⇒ mark the active room offline, **WS untouched**.
- Inbound-silence watchdog: 70 s deadline, 20 s poll (V11).
- `_clearLiveRooms()` on every disconnect and teardown.
- Client-side 4 MiB ceiling checked against the **base64 length** (`L * 3 / 4 <= 4194304`),
  failing the send locally — the relay drops an oversized frame in total silence.

**Accept:**

- Two clients on a local relay exchange envelopes; the receiver sees `peer` rewritten to the
  sender and `room` rewritten to the **sender's** hello room.
- A second connection with the same key at the same `(peer, room)` is accepted (N conns are
  legal since plan 23 Wave 2C) and the sender does **not** echo to itself.
- Sending to a dead `(peer, room)` produces a `transport_error` control frame within one RTT.
- Killing the relay: backoff ladder is exactly 1, 2, 5, 10, 30, 30…; on reconnect all four
  subscription frames are re-sent and the first `rooms_check` reply arrives (fresh dedup cache).
- A frame with a top-level `type` on an envelope disappears — asserted as a **negative** test
  so nobody re-adds one.
- `presence_check` twice with nothing changed returns **one** reply; no code path awaits it.
- No `room_already_open` handling exists anywhere (grep the module: zero hits).

### Phase 3 — `RemotePiPairing`: pair for real

Needs a Mac running `pi-extension` and a relay.

- `KeychainSyncStore` ported verbatim (D11), wrapped in a Swift `AsyncStream` instead of
  `FlutterEventChannel`; `willEnterForeground` re-read kept; the `NSUbiquitousKeyValueStore`
  observer **dropped** (spec 05 §10.4).
- Boot gate: `.ready(identity, generated:)` / `.syncUnavailable`; sticky `/sync-required`
  screen with the verbatim iOS copy from spec 08 §4; "Check again" re-runs boot.
- Owner-drift watcher installed **only after** boot returns `.ready`, with the
  `current == nil ⇒ adopt, do not wipe` guard. Both defences ship together.
- Corrupted-blob screen (V6).
- QR parse: scheme/host check, `+`→space on `n` only, base64url unpadded decode, 16/32-byte
  length checks, trim pasted input.
- `pair_request` with exactly four fields and **no signature**; `hello.room_id == "main"`.
- `pair_ok`: parse and persist **all** of `session_id`, `workspace_path`, `display_name`,
  `name_rev` — the four the Flutter client drops (spec 04 §12 D2).
- `room_id` precedence: `pair_ok.room_id` (non-empty) → `qr.rm` → `"main"`, distinguishing
  "the Pi said main" from "the Pi omitted it".
- Mesh publish after `savePeer`, with `remote_epk` in **standard** base64; `allowEmpty`
  reachable only from the revoke path; `suppressPublish` scope around an apply (V7, V8).

**Accept** (spec 04 §15 verbatim, plus):

- A real QR pairs; a second scan of the same QR yields `pair_error: token_consumed`.
- A stale `rm` yields a `transport_error` surfaced within one RTT — **not** a 30 s wait.
- After pairing, killing and relaunching the app reconnects with the Owner key, sends **no**
  `pair_request`, and the Pi routes normally.
- The Pi's next `SelfRevoke` sweep (≤ 60 s) sees itself listed and stays alive.
- Revoking from the app: the machine stops answering `ctrl` (silent drop) and answers the
  chat room with `error{code:"unknown_peer"}` — that error is the positive confirmation.
- Publishing `members: []` at `version > 1` is refused unless `allowEmpty` was passed.

### Phase 4 — Vertical slice: `RemotePiStore` + `RemotePiSession` + SwiftUI

**pair → list sessions → read a chat → send one message.** The first shippable-ish build.

- SQLite schema from spec 07 §4.2, verbatim, including `UNIQUE (machine_pk, session_id)`,
  `UNIQUE INDEX message_identity ON message(session_pk, role, msg_id)` and the attachment table.
- Store is an `actor` with a single serial write lane; a failed write is logged and dropped,
  never retried, never allowed to stall the lane.
- `next_seq` allocated in-transaction (crash-safe), dense from 0.
- Room registry: `room_announced` / `rooms` / `room_ended` / `room_meta_updated` applied with
  preserve semantics and the `name_rev` gate; `role`/`session_id`/`workspace_path` learned
  from announce+snapshot only and **preserved** when a snapshot omits them.
- Home: Device → Workspace → Session, `ForEach(id: \.sessionKey)`, workspaces sorted by
  **path**, sessions sorted by `session_id`, filter tabs (All/Online/Offline) as a pure view,
  grouping picker persisted, presence dot with the four-state priority
  (working > reconnecting > live > idle), control rooms filtered out.
- Chat read path: `session_sync` → buffer to `eos` → reconcile (V1) → render user/assistant/
  tool/compaction rows in a bottom-anchored list.
- Send path: persist the `pending` row **before** the socket write, arm the reap timer from the
  row's `ts`, re-arm on store load, reap silently, and fail the pending set on
  `transport_error` (V2).

**Accept:**

- Cold start on a paired phone lands on the previously-open chat, restoring **both** halves
  of the `epk:sessionId` pointer.
- Rename a session from Home while a **different** chat is open: the label changes, the open
  chat does not move (`sendToRoom`, not `setActiveRoom`), and the reply is not swallowed (V3).
- `/name` on the Mac keeps the same chat, the same store rows, and produces no `room_ended`.
- Two sessions in the same folder stay distinct after both are renamed.
- Backgrounding for 10 minutes and returning does not lose the transcript, does not duplicate
  assistant rows, and does not truncate history to 30 events (V1).
- Force-quitting mid-send leaves the pending row on disk, and it is reaped on next launch.
- The `ctrl` room never appears as a tile, never gets a message store, never becomes the
  selection.

### Phase 5 — Chat breadth

`agent_chunk` coalescing (16 ms, in-memory only, never persisted), segment finalisation at
`agent_done` **and** at every `tool_request` boundary, tool cards including the undocumented
`args.hunks` diff enrichment, compaction rows keyed by wire `ts` and insert-only, queue vs
steer as two distinct mechanisms, `cancel`, images (out-of-row storage, content-addressed),
`bye`, and `error{unknown_peer}` → revoked banner.

**Accept:** a full turn with narration → tool → narration persists in chronological order;
a re-sync of the same turn produces **zero** writes; live and replayed assistant rows do not
duplicate (matched by `(inReplyTo, text)` or turn position, never by id — spec 07 T5).

### Phase 6 — Control plane

`workspace_list`, `create_session`, wait-for-`room_announced`, `session_list`,
`session_start`, `session_stop`. Idempotency key minted **once per intent**, stored on the
intent object, reused across every retry. RPC timeout 45 s (not the chat 15 s). Pending
control RPCs failed immediately on `transport_error{room_id:"ctrl"}` (spec 09 T6).

**First task of this phase, before any UI:** answer spec 09 D1/T1 empirically — does a
control reply addressed to `room:"ctrl"` reach a client registered at `"main"`? Static
reading says no; nothing in any repo exercises it. Implement **both** mitigations (a second
socket registered at `"ctrl"`, **and** correlation purely by `in_reply_to` regardless of the
delivering socket) so the client works either way and stays correct if the gateway is later
fixed. Never key the pending-RPC table by room.

**Accept:** the phone creates a background session on a Mac with **no** interactive Pi open;
`action_ok` is treated as "spawn requested" and the chat opens only after `room_announced`
for that `session_id`; a retry with the same key does not double-spawn and replays the
original outcome including the original error; a replayed `action_ok` carrying only
`{session_id, replayed:true}` decodes without throwing.

### Phase 7 — Parity breadth

Settings (relay URL with both-halves reboot, theme, hide-tool-calls; Dynamic Type replaces
the Text-size control), pairings list with swipe-to-revoke, `ask_user` modal (rich + degraded,
25 s backstop, dismissal must send the cancel frame), voice hold-to-talk with the
permission-prompt race guard, image attach, iPad split view with per-column safe-area
trimming and sheet dismissal on selection change.

**Accept:** the screen inventory in spec 08 §3–§11 is covered or explicitly waived in writing.

### Phase 8 — Conformance gate and the ship-or-shelve decision

- The full conformance suite (§6) green.
- A side-by-side session on real hardware against the Flutter build: same Mac, same relay,
  same workspace.
- Measured: cold-start time, memory during a long transcript, binary size, and whether the
  native-feel claims in §0.3 actually materialised.
- **Answer §0.4.** Then edit `00-decisions.md` per its own convention.

---

## 6. Test bar

Per module, mirroring plan 61's discipline:

- **Crypto:** the epk normalizer's full table (both alphabets × padded/unpadded × mixed);
  idempotence; unparseable pass-through; Ed25519 sign/verify against fixtures produced by
  `relay/src/auth/challenge.rs` tests and `app/test/`.
- **Protocol:** every frame in spec 01 §3 and §7 round-trips; `Patch` three-way decoding;
  the `name_rev` truth table as a parameterised test; `.unknown` on every union; lossy
  history-event decoding; an envelope carries no `type`.
- **Transport:** handshake against a locally-run relay binary; backoff ladder asserted
  exactly; 3-missed-pings marks the room offline without closing the socket; subscription
  replay after reconnect; live-set cleared on disconnect; `sendToRoom` does not move the
  active room; size ceiling enforced client-side.
- **Session:** preserve-vs-clear on `room_meta_updated`; identity fields preserved across a
  snapshot that omits them; control-room filter; Device→Workspace→Session grouping with no
  dangling headers; idempotency key stability across retries; `action_ok` ≠ room live.
- **Pairing:** spec 04 §15 (10 checks) and spec 05 §9 (9 checks), as written.
- **Mesh:** spec 06's four golden vectors; `allowEmpty` refusal; intent-rebased 409 retry;
  `suppressPublish` around an apply.
- **Store:** all 20 items of spec 07 §5 as named tests.

**Conformance suite** = the union of those five checklists, run as one target. It is the
gate in Phase 8, and no phase is "landed" until its slice of it is green.

Regression discipline: every trap in every spec that this client hits in the wild gets a
named test referencing the spec section, the way `plan/61` pinned its regressions to named
Flutter test files.

---

## 7. What cannot be verified without a paired Mac and a live relay

Say so in every phase report rather than implying green means correct. This is the same
caveat plan 61 closed with, and it applies harder here.

**Verifiable locally** (`cargo run` in `relay/`, plus a scripted fake peer): the handshake,
the envelope rewrite, dest-miss `transport_error`, the `name_rev` gate, backoff, subscription
replay, size ceiling, the mesh HTTP surface.

**Not verifiable without a real Mac running `pi-extension`:**

- the exact `pair_ok` field set from a live plan-61 Pi, and the legacy-Pi shape (no
  `session_id`) which needs an old build to reproduce at all;
- `session_history` behaviour after a Pi process restart (`events: []` with a valid
  `session_started_at`) — the condition that makes V1 matter;
- the undocumented `args.hunks` enrichment on `edit` tool calls;
- `ask_user` flows, which need `@eko24ive/pi-ask` installed;
- `SelfRevoke` timing (≤ 60 s poll) and the revoked-machine observable sequence;
- **spec 09 D1 — whether control replies reach a client registered at `"main"` at all.**
  This is the largest single unknown in the plan and it blocks Phase 6's design.

**Not verifiable in the simulator at all:**

- iCloud Keychain sync of the Owner key between two real devices under one Apple ID
  (spec 05 §9 check 2) — needs two physical devices;
- `kSecAttrAccessible` behaviour on a locked-but-once-unlocked device;
- background/suspension durability of the SQLite store under real memory pressure;
- anything involving an access group or an app extension (spec 05 §12 Q4).

---

## 8. Risk

**Wire compatibility is the hard part. The UI is not.** Ranked, with the phase that retires
each:

| # | Risk | Why it is real | Retired by |
|---|---|---|---|
| R1 | An epk in the wrong base64 variant reaches the wire | Four prior regressions, documented in `epk_encoding.dart`'s header. Symptoms are silent: `transport_error: offline` from an online Pi, or a subscription that simply never fires | D3 + Phase 1 golden vectors |
| R2 | The Keychain item is queried without `kSecAttrSynchronizable` and a **second** Owner key is generated | Spec 05 §10.1 calls it "the single most destructive mistake in this spec": the mesh blob is then signed by a key nobody recognises and **every paired Pi self-revokes** | D11 + Phase 3 |
| R3 | Canonical mesh bytes differ from Dart's | `JSONEncoder` escapes `/` and every `relay_url` contains `//`. The relay verifies the bytes it received, so a wrong form still returns **200** — the damage only shows on other clients | Phase 1 vector 2 |
| R4 | `decodeIfPresent` collapses absent and null somewhere in a merge patch | The entire `room_meta_update` contract turns on that distinction; a `{working}` patch would wipe the model badge | D4 + Phase 1 vector 4 |
| R5 | Spec 09 D1 turns out to be real and control replies never arrive | No shipped client exercises it; `gateway.test.ts` stubs the relay and the relay tests have no control-room case | Phase 6, first task |
| R6 | The history reconciler (V1) duplicates assistant rows | Live rows are `agent_<uuid7>`, replayed rows are `inReplyTo` — the same text under two ids. Spec 07 T5 names this "the single hardest part" of V1 | Phase 5 accept |
| R7 | Branch A's doubled protocol cost is discovered after the fact | Plan 61 landed one day before this plan and touched all three implementations | §0.4, answered at Phase 0 or Phase 8 |
| R8 | The identity-plugin blocker resolves and the primary justification evaporates mid-build | It is the strongest reason in §0.3 and it is somebody else's timeline | Re-check at every phase boundary; report it |

Deliberately **not** a risk: SwiftUI's ability to render this UI. Everything in spec 08 is
a list, a sheet, a text field and a modal.

---

## 9. Suggested split

| Agent | Owns | Must not touch |
|---|---|---|
| iOS-codec | Phase 1 (`RemotePiCrypto`, `RemotePiProtocol`) | anything with a socket |
| iOS-transport | Phase 2, then Phase 6's transport half | store schema, UI |
| iOS-identity | Phase 3 (`RemotePiPairing`, Keychain, mesh) | chat/store |
| iOS-store | Phase 4's `RemotePiStore` | transport, crypto |
| iOS-app | Phase 4 UI, then 5 and 7 | wire encoding of any kind |

Start with **Phase 0 only.** It is a question, not a task, and the rest of the plan is
worth nothing until it has an answer.
