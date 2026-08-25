# app-ios — STATUS

Handover snapshot, **2026-08-25**, after the first genuine end-to-end run
against a real relay and a real Pi-side peer.

**Bottom line: the app works end to end.** Pairing, the Home hierarchy, all
three grouping modes, all three filter tabs, chat send + echo, rename (from
both sides), the offline flip and the reattach-after-restart were all driven
through the real UI against `relay` + `scripts/fake-pi.mjs` and screenshotted.
Plan 61's acceptance criterion — rename a live session, the tile does not move
and no second tile appears — **passes, asserted four ways**.

What is *not* proven is listed under "Built but unverified" and "Missing".
Read those before believing the first paragraph.

---

## Commands

Run from `/Users/yang/workspace/remote_pi/app-ios`.

### Kit (no simulator needed)

```bash
swift build     # the six libraries, compiled for macOS
swift test      # 478 Kit tests
```

### App target

```bash
xcodegen generate            # RemotePi.xcodeproj is generated, NOT checked in

xcodebuild -project RemotePi.xcodeproj -scheme RemotePi \
           -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
           -derivedDataPath build/dd build

xcodebuild -project RemotePi.xcodeproj -scheme RemotePi \
           -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
           -derivedDataPath build/dd test
```

`swift build` / `swift test` compile for **macOS**. The app target and its
tests are iOS-only (UIKit, PhotosUI, Speech). Run both — a green `swift test`
alone does not mean the app compiles, and it never opens a socket.

### End-to-end (relay + fake-pi + simulator)

This is the only gate that proves the app *works* rather than *compiles*.

```bash
# 1. relay  (default port is 3000; :3888 keeps it off a colleague's instance)
cd ../relay && REMOTEPI_RELAY_PORT=3888 cargo run

# 2. a Pi-side peer: 5 sessions across 4 workspaces + the `ctrl` control room
node ../scripts/fake-pi.mjs --relay ws://localhost:3888 \
  --session '/Users/you/proj/app:api-server' \
  --session '/Users/you/proj/app:api-worker' \
  --session '/Users/you/proj/relay:relay-dev' \
  --session '/Users/you/proj/site:site-build' \
  --session '/Users/you/proj/ext:ext-watch'

# 3. boot a simulator and note its UDID
xcrun simctl boot 'iPhone 17 Pro'
xcrun simctl list devices booted

# 4. put the pairing payload fake-pi printed on the simulator pasteboard
printf '%s' 'remotepi://pair?t=…' | xcrun simctl pbcopy booted

# 5. run one E2E test; screenshots land in build/native-<name>.png
RP_SIM=<udid> RP_RELAY=ws://localhost:3888 ./scripts/e2e.sh test00_pairViaPastedCode
./scripts/e2e.sh test01_homeHierarchy
./scripts/e2e.sh test02_groupingModes
./scripts/e2e.sh test03_filterTabs
./scripts/e2e.sh test04_renameKeepsTileInPlace
./scripts/e2e.sh test05_chatSendAndEcho
./scripts/e2e.sh test06_offlineFlipWhenPiDies   # kill fake-pi while this waits
```

Manual driving without the tests uses the app's debug launch arguments —
`--relay`, `--pair`, `--open`, `--send`, `--rename-to`:

```bash
xcrun simctl launch booted work.jacobmoura.remotepi.native \
  --relay ws://localhost:3888 --pair 'remotepi://pair?t=…'
```

---

## Current state

| Command | Result |
|---|---|
| `swift build` | **Build complete**, 0 errors, 0 warnings |
| `swift test` | **478 executed — 476 passed, 2 skipped, 0 failures** |
| `xcodegen generate` | OK |
| `xcodebuild … -scheme RemotePi build` | **BUILD SUCCEEDED**, 0 errors, 0 warnings |
| `xcodebuild … -scheme RemotePi test` | **TEST SUCCEEDED** — 294 XCTest + 102 swift-testing |
| `./scripts/e2e.sh <test>` ×7 | **7 / 7 pass** against relay + fake-pi |

881 tests. Swift tools 6.0, Swift 6 language mode,
`SWIFT_STRICT_CONCURRENCY: complete`. Zero third-party dependencies.

| Target | Tests | Runs under |
|---|---|---|
| `RemotePiProtocolTests` | 161 | `swift test` |
| `RemotePiSessionTests` | 83 | `swift test` |
| `RemotePiPairingTests` | 71 | `swift test` |
| `RemotePiTransportTests` | 65 | `swift test` |
| `RemotePiCryptoTests` | 49 (2 skipped) | `swift test` |
| `RemotePiStoreTests` | 49 | `swift test` |
| `RemotePiAppTests` | 396 | `xcodebuild -scheme RemotePi test` |
| `RemotePiUITests` | 7 | `./scripts/e2e.sh` (needs relay + fake-pi) |

---

## Works end to end

Verified 2026-08-25 on an **iPhone 17 Pro simulator (iOS 26.5, arm64)**,
against `relay` on `:3888` and `scripts/fake-pi.mjs` running **5 sessions
across 4 workspaces** plus the `ctrl` control room. Every line below has a
screenshot in `build/`.

| What | Evidence | Screenshot |
|---|---|---|
| First-pair empty state on a clean install | fresh install, no peers | `native-first-pair-empty-state.png` |
| **Paste-QR pairing through the real UI** — Scan QR → camera-blocked body → "Paste code instead" → `PasteButton` → Pair → nickname sheet | `test00`, fake-pi logged `PAIRED with "iPhone 17 Pro - 1"` | `native-pair-paste-sheet.png`, `native-pair-nickname-sheet.png`, `native-home-after-pairing.png` |
| Device → Workspace → Session hierarchy, 5 real rooms, correct per-workspace counts, green presence dots, `Relay · Connected` | `test01` | `native-home-hierarchy.png` |
| All three grouping modes, none of which drops a session | `test02` | `native-grouping-device-folder.png`, `native-grouping-device-only.png`, `native-grouping-none.png` |
| All three filter tabs, each rendering exactly the count it claims, with `All == Online + Offline` | `test03` | `native-filter-all.png`, `native-filter-online.png`, `native-filter-offline.png` |
| **Rename a live session from the app** — long-press menu → alert (pre-filled with the current name) → Save | `test04` | `native-rename-menu.png`, `native-rename-alert.png`, `native-rename-after.png` |
| **Rename a live session from the Pi** — an unsolicited `room_meta_update` patch with a bumped `name_rev` | fake-pi `rename 2 …`, `room_id UNCHANGED` | `native-rename-live-session.png` |
| Chat: open a session, type, send, the Pi echoes the user bubble and streams `agent_chunk` → `agent_done` | `test05`, asserted on `You said: <unique-per-run>` | `native-chat-open.png`, `native-chat-typed.png`, `native-chat-sent-and-echoed.png` |
| **Offline flip on Pi death** — `SIGKILL` fake-pi, every room goes Offline in **~1 s**, presence dots grey, `+` correctly disappears (control plane down), `Relay · Connected` stays (the socket is fine, the Pi is not) | `test06` | `native-offline-before.png`, `native-offline-after.png` |
| **Reattach after a supervisor restart** — fake-pi restarted on the *same* session ids, app returns to 5 tiles (not 10) with the rename preserved | manual, host-driven | `native-restart-reattach.png` |

### Plan 61's acceptance criterion, specifically

`test04_renameKeepsTileInPlace` renames the **second** tile (renaming the first
cannot detect a move to the top) and asserts four things, all green:

1. the session count did not change — **no second tile**;
2. the new name sits at exactly the index the old one occupied — **no move**;
3. the pre-rename label is gone entirely — **no ghost row**;
4. every other tile kept its slot.

The Pi-initiated direction was checked separately and behaves the same: the
accessibility element ref for the tile was **unchanged** across the rename
(`e43` before and after), which is the SwiftUI-level statement that
`.id(row.id)` keyed by `SessionKey` held the view identity.

Ordering is by room id (`SessionCatalog`), never by name and never by
`started_at` — confirmed live: `api-worker` (`26e4…`) renders above
`api-server` (`aefc…`) and stayed there through renames, restarts and
presence flips.

---

## Fixed during this run

### 1. The Send button was invisible to accessibility — `App/Sources/Chat/Composer.swift`

`primaryButtonFace` is a `Circle()` with `.onTapGesture`, not a `Button` —
deliberately, because the mic branch needs a `DragGesture` a `Button` would
swallow. But it carried only `.accessibilityLabel` and
`.accessibilityIdentifier`. With no `.isButton` trait and no accessibility
action, **VoiceOver announced Send as an image and offered no way to activate
it**: `.onTapGesture` is not an accessibility action. The composer's send,
stop and mic control could not be pressed by assistive technology at all.

Found because XCUITest could not press Send either — the same tree, the same
missing trait. Fixed with `.accessibilityAddTraits(.isButton)` and
`.accessibilityAction { … primaryTapped() }`; `primaryTapped()` is already the
correct action in all three modes (submit / cancel / explain-hold-to-talk), so
this adds no new behaviour, it just exposes the existing one.

### 2. New end-to-end harness

* `App/UITests/` — `RemotePiUITests`, 7 tests (`E2ESupport.swift`,
  `HomeE2ETests.swift`);
* `project.yml` — a `bundle.ui-testing` target and a separate
  `RemotePiUITests` scheme, so `-scheme RemotePi test` stays fast and
  hermetic;
* `scripts/e2e.sh` — runs one E2E test and extracts its screenshots from the
  `.xcresult` into `build/native-*.png`.

---

## Environment traps (cost real time — read before driving a simulator here)

1. **Host HID injection does not work on this machine.** `axe` / XcodeBuildMCP
   `tap` report `SUCCEEDED` and drop every event: taps, `--tap-style
   physical`, `--tap-style simulator`, even the hardware Home button. It is
   not the app — tapping "General" in the *system Settings app* does nothing
   either. The cause is that the simulator is booted headless and this Xcode
   (`/Applications/Xcode-beta.app`, 3.6 GB) ships **no `Simulator.app`** —
   `Contents/Developer/Applications` does not exist, and `mdfind` finds no
   copy anywhere on the box. Without a UI session there is no HID port.
   **XCUITest is therefore the only way to drive this app**: its runner lives
   inside the simulator and posts events through the automation session.

2. **`TEST_RUNNER_*` environment never reaches the runner here.** It is baked
   into the generated `.xctestrun` at `build-for-testing` time, so passing it
   to `test-without-building` is silently ignored — and passing it to
   `xcodebuild test` did not work either. An env-driven test skips itself and
   the run still reports success. The pairing payload therefore travels on the
   **simulator pasteboard** (`xcrun simctl pbcopy booted`), which is both
   reliable and the real user flow.

3. **`xcrun simctl spawn booted defaults read <bundleid>` lies.** It reads a
   partial, sandbox-external view and omits keys the app has written. Read the
   container plist, and expect `cfprefsd` to be holding recent writes in
   memory.

---

## Built but unverified

* **`KeychainKeyStore` on a signed host.** The simulator falls back to the
  file key store (`OSStatus -34018`, no keychain-access-group entitlement) and
  two tests skip themselves rather than pass falsely. A bug in
  `loadOrCreateOwnerKeySeed` would mint a second Owner identity and orphan
  every pairing. Untested on device.
* **`transport_error` as a client-visible signal.** The offline flip observed
  above arrives via room liveness (`room_ended` / presence), which is the
  primary path and is proven. The dest-miss `transport_error` answer to an
  App→Pi frame sent into a dead room is implemented and unit-tested but was
  not observed live — the composer is already locked by then, so provoking it
  needs a deliberate race.
* **Reconnect after a relay flap.** The backoff ladder is unit-tested; the
  relay itself was never restarted under a live app.
* **Everything reached only through `ctrl`**: `create_session` (the `+`
  button), `session_start` / `session_stop`, `workspace_list`. The control
  room is up and `+` correctly appears and disappears with it, but no session
  was created through the UI.
* **Voice input, image attachments, quick actions, the model picker, the
  `ask_user` modal.** All compile, all carry unit tests, none was exercised
  live.
* **Tablet split.** `SplitShell` was verified live in the previous handover on
  an iPad simulator; this run was phone-only.
* **Everything below iOS 26.5 / above it.** One runtime, one device.

Weakness that has not changed: **every unit test is in-process against fakes.**
`RemotePiTransport` is tested through an injected `WebSocketChannelFactory`,
never through `URLSessionWebSocketChannel` — byte compatibility was *asserted*
by fixtures and is now, finally, also *observed* by the E2E suite, but only
for the frames those seven tests happen to send.

---

## Missing

1. **`RoomRegistry` has no `forget(_:)`.** `deleteCachedSession` removes the
   store rows, but a room still in the live snapshot is rebuilt by the next
   announce. Correct for a *live* session (spec 08 §7.7); a dead one should
   stay gone and today only does until the next cold start. The menu row is
   shown disabled with the reason, rather than lying.
2. **Session info dialog (§8.14)** is not built. `ChatTopBar`'s ⓘ renders
   disabled, which is the shape the spec asks for when there is nothing to
   show.
3. **`ChatScreenModel.refreshDerived` polls at 100 ms.** `@Observable` has no
   multi-property stream and eight `withObservationTracking` loops would be
   worse, but it is still a poll.
4. **Push notifications, app icon, code signing.** Untouched.
5. **No CI.** The E2E suite needs a relay and a Node process; nothing wires
   that up yet.

### Watch item, not yet a bug

Home's grouping preference is persisted through `UserDefaults` on `didSet`.
Once, after XCUITest `SIGKILL`ed the app, the persisted value was the
**second** of three selections — the last write had not flushed. It did not
reproduce across two further runs, and real suspends flush normally, so this
reads as `cfprefsd` timing under an abrupt kill rather than a code defect.
Worth remembering if a user ever reports a preference reverting.

---

## Things that look like bugs and are not

* **The device header showed a session name (`API-SERVER`) instead of the
  hostname.** Only on the `--pair` debug launch path, which skips the nickname
  sheet. `DeviceGroup.displayName` is `nickname → sessionName captured at pair
  time → short key`, which matches the Dart (`peer_section_header.dart:15`)
  exactly. Through the real UI the nickname sheet runs, Save with an untouched
  field commits the `pair_ok` hostname placeholder, and the header reads
  `YANG-MBP`. See `native-home-after-pairing.png`.
* **`Online` is the default filter tab, not `All`.** Spec 08 line 400:
  `HomeList` defaults `filter = HomeFilter.online`.
* **`--open` does not navigate to the chat.** By design — spec 08 §11.2, "the
  app starts with nothing selected". `--send` does send: the messages land and
  are echoed, they just land in a chat that is not on screen.
* **A rename does not rename the device header.** The header is the *peer*
  label, captured at pair time; renaming a session is a different thing.

---

## Routes

Every route in spec 08 §1.1 is reachable by user action; the starred ones were
walked by hand this run.

| Route | Where it lives | Reached from |
|---|---|---|
| `/boot` | `BootSplashScreen` | `BootCoordinator.Phase.booting` |
| `/sync-required` | `SyncRequiredScreen` | sticky, `identity == .syncUnavailable` (unreachable today — `boot()` falls back to a file key store) |
| `/onboarding` | `OnboardingScreen` | generated identity + no peer |
| `/home` ★ | `HomeScreen` | stack root / sidebar column |
| `/session` | `SplitShell` detail | `SessionSelection` (tablet) |
| `/chat` ★ | `AppRoute.chat` | `SessionOpener` (compact push) |
| `/pair` ★ | `AppRoute.pair` | Home empty state, Settings ×2, chat revoked banner |
| `/settings` | `AppRoute.settings` | Home title bar — pushed on compact, 92% sheet on tablet |

A **restored** identity with zero peers goes to `/home`, not `/onboarding` —
which is why a reinstall on this simulator lands on the first-pair empty state
rather than the wizard: the Owner key survives in the Keychain.

---

## Layout

```
Package.swift            six library targets + the RemotePiKit umbrella
Sources/                 the Kit — UI-free, `swift test`-able
  RemotePiProtocol/      wire types, RoomMeta + patch semantics, envelope
  RemotePiCrypto/        Ed25519 (CryptoKit), base64 std/url normalisation
  RemotePiTransport/     URLSession WebSocket, hello/challenge/auth, rooms
  RemotePiSession/       SessionCoordinator, MachineControlClient, catalog
  RemotePiPairing/       QR payload, pair flow, Keychain identity, mesh
  RemotePiStore/         SQLite persistence
Tests/                   478 Kit tests
App/Sources/             the app — ~16,600 lines, 86 files, 60 view types
App/Tests/               396 screen-model tests (iOS host)
App/UITests/             7 end-to-end tests (simulator + relay + fake-pi)
scripts/e2e.sh           run one E2E test, extract its screenshots
project.yml              xcodegen spec — the source of truth for the project
```

Do not trust `swift test` alone as a release gate. It does not compile the app
target, it never opens a socket, and a screen-model test cannot see an
observation bug — that is exactly how a Home screen that never left its
spinner once shipped with 53 green tests.
