# 62-08 — Screen + Interaction Inventory (native iOS client)

**Status:** implementation-ready specification. Written 2026-08-25 against the
Flutter client at `app/lib/**` as of `e0d9e95` (post plan-61 phases 0–4).

**Ground truth.** Everything below is derived from three implementations that
must not change: `app/lib/**` (Flutter), `relay/src/**` (Rust), and
`pi-extension/src/**` (Node/TS). Where they disagree, the disagreement is
called out and a winner is named. `PROTOCOL.md` (rewritten 2026-08-24) is the
narrative companion; this document is the UI contract.

**Reading order.** §1 navigation, §2 identity rules that every screen obeys,
§3–§11 per-screen specs, §12 backgrounding/state restoration, §13 **Traps**
(most valuable section), §14 suggested Swift types, §15 what could not be
determined.

---

## 1. Navigation graph and route table

The Flutter app uses `go_router` with a `StatefulShellRoute` for the adaptive
master–detail. Source: `app/lib/routing/app_router.dart:212-405`.

| Path | Screen | Presentation | Providers scoped to the route |
|---|---|---|---|
| `/boot` | `_BootSplash` (spinner) | full screen | — (`app_router.dart:443-461`) |
| `/sync-required` | `SyncRequiredPage` | full screen, **sticky** | — (`:245-248`) |
| `/onboarding` | `OnboardingPage` (3 steps) | full screen | `OnboardingViewModel`, `PairingViewModel` (`:346-353`) |
| `/home` | `HomePage` | shell branch 0 (master) | `HomeViewModel`, `UpdateBannerViewModel` (`:306-315`) |
| `/session` | `_DetailPane` | shell branch 1 (detail, `preload: true`) | see `_DetailPane` (`:322-330`) |
| `/chat` | `ChatPage` | **root push** (phone only) | `ChatViewModel`, `VoiceInputViewModel`, `AttachmentViewModel` (`:366-396`) |
| `/pair` | `PairingPage` | full screen push | `PairingViewModel` (`:335-339`) |
| `/settings` | `SettingsPage` | full screen push (phone only) | `SettingsViewModel` (`:399-403`) |

### 1.1 Boot state machine

`_BootState.load` (`app_router.dart:55-147`) runs once at launch and is the
router's `refreshListenable`. Sequence, in order — the order is load-bearing:

1. `prefs.load()` — hydrate persisted preferences (`:63`).
2. `ownerBridge.boot()` — materialize/restore the Owner Ed25519 key from
   iCloud Keychain (iOS). If it returns `SyncUnavailableResult`, set
   `syncAvailable = false`, mark ready, **return early** (`:70-76`). Nothing
   else runs.
3. Record `identityWasGenerated = ownerResult is IdentityReady && generated`
   (`:78-79`). "Restored from iCloud" ⇒ `false`.
4. Install the platform key-sync watcher **only after** boot succeeds
   (`:85`, rationale `:81-84` and `:170-195`) — the plugin emits an initial
   blob on subscribe, and subscribing before `_current` is populated makes the
   bridge think the Owner key changed and wipe the freshly-loaded peer set.
5. `meshSync.pullOnDemand()` — pull `mesh_versions` from the relay **before**
   listing peers (`:92`), so a reinstall materializes membership.
6. `storage.listPeers()` → `hasPeer` (`:94`).
7. If `hasPeer && !prefs.onboardingCompleted`, force `onboardingCompleted = true`
   (`:99-101`) — a user who paired in a pre-onboarding build must not re-run it.
8. Restore the selection pointer and dial: see §2.3.

Redirect rules (`app_router.dart:215-237`):

```
!ready                       -> /boot
!syncAvailable               -> /sync-required   (sticky: only /sync-required allowed)
identityWasGenerated && !hasPeer -> /onboarding  (only from /boot or /sync-required)
otherwise                    -> /home            (only from /boot or /sync-required)
```

A **restored** identity with zero peers goes to `/home`, not `/onboarding`
(`:224-231`) — Home has a first-pair empty state that reads better than
re-running the wizard.

### 1.2 Phone vs tablet navigation split

* Phone (`isWideLayout == false`): tapping a session does
  `context.push('/chat', extra: {...})` on the **root** navigator
  (`home_page.dart:642-647`), preserving native back/swipe. The detail branch
  is built but never displayed.
* Tablet: no navigation at all. `SessionSelection.select(...)` fires and
  `_DetailPane` reacts (`app_router.dart:413-441`).

SwiftUI mapping: a `NavigationStack` for the compact size class and an
`NavigationSplitView` for regular — with the crucial caveat in §11 that the
selection object is shared and must key on `(epk, sessionId)`.

---

## 2. Identity rules every screen must obey (plan 61)

These are not suggestions. They are the reason plan 61 exists.

### 2.1 The keys

```
machine  : epk        = Pi-key, Ed25519 pubkey, Base64
workspace: path       = realpath(cwd), a GROUPING key, never an identity
session  : session_id = UUID;  room_id == session_id  (transport key)
```

| Purpose | Key | Source |
|---|---|---|
| Home row widget key | `"<standardB64(epk)>|<roomId>"` | `home_state.dart:88` (`HomeItem.sessionKey`) |
| Tablet detail pane key | `"chat-<standardB64(epk)>|<roomId>"` | `adaptive.dart:96-99`, used at `app_router.dart:423-424` |
| Persisted selection | `"<epk>:<roomId>"` in one secure-storage string | `preferences.dart:192-200` |
| Message store (Hive) | `msgs_<toAppEpk(epk)>__<roomId>` | see plan 61 §Phase 2 deviation |
| Session index row | `<toAppEpk(epk)>:<roomId>` | `boxes.dart` (`LocalBoxes.sessionKey`) |

**Never key on:** display name, `cwd`, list index, or `started_at`.
`started_at` is re-stamped by the relay on *every* reconnect
(`relay/src/handlers/peer.rs:139-142`) — it is neither an identity nor a sort
key. `HomeItem.==` deliberately compares only `(normalizedEpk, roomId)`
(`home_state.dart:108-115`) so that `working` flipping twice per turn does not
make a session compare unequal to itself.

### 2.2 `room_id` uniqueness is per-machine, not global

Every cache is keyed by `(epk, roomId)`. Two machines emitting the same room id
is harmless. Do **not** prefix room ids with a device id — see `PROTOCOL.md`
"Unicidade do `room_id`". The invariant to preserve in Swift: **never key
persistent state by room id alone.**

### 2.3 Cold-start restoration of the pointer

`_BootState.load` (`app_router.dart:115-146`):

1. Sort peers by `pairedAt`, tie-broken by `remoteEpk` — because
   `listPeers()` reads an unordered secure-storage map and `peers.first`
   varies per run (`:119-124`).
2. Match `prefs.selectedPeerEpk` against the peer list using
   `toStandardB64` on **both** sides (`:126-136`).
3. On no match (peer revoked / never selected): fall back to `ordered.first`
   **and drop the room half** — it belonged to a peer that is gone (`:138-143`).
4. `conn.boot(preferredEpk:, preferredRoomId:)` — **both halves**. Reading only
   the epk was the bug that made cold start reopen `PeerRecord.roomId ?? 'main'`
   instead of the chat the user last had open.

`PeerRecord.roomId` is a **last-opened hint**, not connection identity
(plan 61 Phase 0).

---

## 3. Screen: Boot splash (`/boot`)

Full-screen `Scaffold` with `backgroundColor = colors.bg` and a centered
24×24 `CircularProgressIndicator` in `colors.accent`, stroke width 2
(`app_router.dart:443-461`). No text, no logo. Shown only while
`_BootState.load` is in flight.

---

## 4. Screen: Sync Required (`/sync-required`)

`app/lib/ui/sync_required/sync_required_page.dart`.

**Purpose.** Hard gate: the Owner Ed25519 key has no persistence path other
than iCloud Keychain (iOS) / Block Store (Android). Without it the app cannot
proceed.

**Layout** (`:50-142`), top to bottom:

| Element | Content | Ref |
|---|---|---|
| Icon | `cloudOff` (iOS) / `cloudUpload` (Android), accent, 44pt | `:59-63` |
| Title | `"Sync required"`, mono, 20pt, w600 | `:65-73` |
| Body | Platform-specific "why" copy | `:41-47` |
| Label | `"To enable, on this device:"` | `:85-94` |
| List | Numbered requirement cards, scrollable | `:96-105`, cards `:182-262` |
| Button | `"Check again"` → `_recheck` | `:107-135` |

iOS requirements list (`:169-180`), verbatim:

1. **Sign in to iCloud** — `Settings › [your name]` — note: *If you see "Sign in
   to your iPhone" at the top, tap it.*
2. **Turn on iCloud Keychain** — `Settings › [your name] › iCloud › Passwords
   and Keychain` — note: *Toggle "Sync this iPhone" on.*

**State machine.** One boolean `_checking` (`:22`). `_recheck` (`:24-35`):
guard re-entrancy → `_checking = true` → `OwnerIdentityBridge.boot()` → on any
result that is not `SyncUnavailableResult`, `context.go('/boot')` so the
router's redirect re-evaluates (peers empty → `/onboarding`, else `/home`).
While `_checking`, the button is disabled and shows an 18×18 spinner in
`onAccent`.

The route is **sticky**: the redirect refuses to leave until the bridge reports
sync available (`app_router.dart:220-222`).

---

## 5. Screen: Onboarding (`/onboarding`) — 3 steps

`onboarding_page.dart`, `onboarding_viewmodel.dart`, `states/onboarding_state.dart`.

### 5.1 Shell

`ResponsiveCenter` (max width 460, `adaptive.dart:33`) wrapping a column of
`_StepIndicator` + `PageView`. The `PageView` has
`physics: NeverScrollableScrollPhysics` (`onboarding_page.dart:68`) — swiping
between steps is **disabled**; only the buttons advance. Page changes are
driven by an animated `animateToPage` (220ms, `easeInOut`) reacting to state
(`:26-36`).

`_StepIndicator` (`:100-129`): one 3pt-tall bar per step, full-width
`Expanded`, 4pt gaps; bars at index ≤ current step use `colors.accent`, the
rest `colors.border`.

### 5.2 State

```dart
enum OnboardingStep { welcome, relay, pair }   // onboarding_state.dart:4
enum RelayChoice { community, custom }         // :6

OnboardingInProgress {
  step             = welcome
  relayChoice      = community
  customRelayUrl   = ''
  customRelayError = null
}
OnboardingComplete {}
```

`OnboardingComplete` triggers a post-frame `context.go('/home')`
(`onboarding_page.dart:43-51`).

### 5.3 Step 1 — Welcome

Static, deliberately un-animated (plan 14 D2). `welcome_step.dart:12-78`:
terminal icon 64pt accent, brand title "Remote Pi" 24pt w600, subtitle
"Control your Pi agent from anywhere", body paragraph, `"Get started"` filled
button → `vm.next()`.

### 5.4 Step 2 — Relay configuration

`relay_step.dart`. Title "Choose a relay" / "Where the app and your PC meet."

Two radio cards, **in this order** (the self-hosted card is first and carries
the `recommended` badge, because the privacy story is the product's honest
position — the relay sees plaintext, see `PROTOCOL.md`):

1. `_CustomRelayCard` — "Use my own server", badge `recommended`, description
   "Self-hosted. Best privacy." When selected, reveals a `TextField` with
   placeholder `https://my-relay.com` and inline `errorText` (`:311-348`).
2. `_RelayCard` — "Community relay", "Hosted by us. Quick to start.", footer
   showing `kDefaultRelayUrl` (`:73-79`).

Continue-enabled predicate (`:31-36`):

```
community                        -> enabled
custom && customRelayUrl.isEmpty -> enabled   (empty == "use the default")
custom && non-empty              -> enabled iff isValidRelayUrl(url)
```

Validation runs on every keystroke (`onboarding_viewmodel.dart:76-85`) and
again on `next()` (`:28-35`). On `next()` the URL is persisted as
`prefs.setRelayUrl(url)` — or **`null`** when the choice is community or the
custom field is empty (`:37-42`). `null` means "fall back to `kDefaultRelayUrl`".

Buttons: `Back` (outlined) + `Continue` (filled, disabled state uses
`colors.border` as background).

### 5.5 Step 3 — Pair

`pair_step.dart` embeds the real pairing flow via the shared
`PairingViewModel`. Copy: "Connect to your device" → "On your computer (Mac,
Linux, or Windows), open Pi and run:" → boxed mono `/remote-pi pair` in accent
→ "Scan the QR code that appears:" → camera viewfinder.

Body switches on `PairingState` (`:196-240`):

| State | Body |
|---|---|
| `PairingScanning` | live camera + accent 2pt border overlay |
| `PairingConnecting` | `_StatusOverlay(refreshCw, "Pairing…")` |
| `PairingError` | `_StatusOverlay(circleAlert, message)` + `Try again` when `canRetry` |
| `PairingPaired` | `_StatusOverlay(circleCheck, "Paired!")` |
| `PairingIdle` | `SizedBox.shrink()` |

Below the viewfinder, only while `Scanning`/`Idle`: a text button
`"Can't scan? Paste code instead"` opening the paste sheet (`:131-147`).
Footer row: `Back` + `Scan later`.

**Camera disarm.** `_submitRaw` sets `_scannerActive = false` and stops the
scanner *before* handing the payload to the VM (`:52-58`) so the camera and the
paste sheet cannot both submit the same QR. `Try again` re-arms it (`:225-230`).

**Transition detection.** The page notifies the parent exactly once, by
comparing the current state to `_lastObserved` and firing `onPaired` in a
post-frame callback when it becomes `PairingPaired` (`:70-75`). `PairingPaired`
is re-emitted on `applyNickname`, so an unguarded observer fires twice.

`completePairing()` and `skipPairing()` both set
`prefs.onboardingCompleted = true` and emit `OnboardingComplete`
(`onboarding_viewmodel.dart:95-107`). Skipping leaves zero peers; Home shows
its first-pair empty state.

---

## 6. Screen: QR Pairing (`/pair`)

`pairing_page.dart`, `pairing_viewmodel.dart`, `states/pairing_state.dart`.
Entered from Home's empty state, Settings → "Add new pairing", or the chat's
revoked banner (`context.go('/pair')`).

### 6.1 States

```dart
sealed PairingState                       // pairing_state.dart
  PairingIdle
  PairingScanning                          // initial state of the VM (:40)
  PairingConnecting(sessionName)
  PairingPaired(peer, hostnameHint?)       // == compares (remoteEpk, hostnameHint)
  PairingError(message, canRetry = true)
```

### 6.2 Scanner screen

`_buildScannerBody` (`:120-188`): full-bleed camera, a centered 268×268 rounded
frame (radius 24) with corner brackets drawn by `_BracketPainter`, hint text
`"Point camera at the QR shown in your Mac terminal"` at `bottom: 110`, and a
bottom `"Can't scan? Paste code instead"` outlined button at `bottom: 32`.
While `PairingConnecting` the camera is removed, the frame fills with
`Colors.black54` + a spinner, and the hint becomes
`"Connecting to $sessionName…"` at `bottom: 48`.

### 6.3 Pairing sequence (`pairing_viewmodel.dart:47-102`)

```
onQrScanned(raw)
  guard state is not PairingConnecting                       (:48)
  qr = QrPairPayload.tryParse(raw); null -> silently ignore  (:50-51)
  emit PairingConnecting(qr.sessionName)
  await conn.disconnect()        // same Ed25519 on a 2nd WS collides in the
                                 // relay registry and unregisters the new entry (:56-59)
  ownerKey = await ownerBridge.requireKeyPair()              (:65)
  transport = await transportFactory(qr, ownerKey)
  result = await performPairing(...).timeout(30s)            (:78-85)
  channel = PlainPeerChannel(transport); conn.adopt(channel, result.peer)
  emit PairingPaired(peer, hostnameHint: result.hostnameHint)
```

Error mapping (`:135-141`), user-visible verbatim:

| code | message |
|---|---|
| `token_expired` | QR expired — generate a new one on your Mac |
| `token_consumed` | QR already used — generate a new one |
| `token_unknown` | QR not recognized by Mac — re-run /remote-pi pair |
| `pair_timeout` | Timed out — make sure /remote-pi is running on your Mac |
| other | `e.message` or `e.code` |

`pair_ok` also carries, post plan-61, `session_id` / `workspace_path` /
`display_name` / `name_rev` alongside the legacy `session_name` / `room_id`
(`PROTOCOL.md` §Pareamento). Persist them so the very first frame is already
session-keyed.

### 6.4 Post-pair nickname sheet

`_runPostPairFlow` (`pairing_page.dart:88-98`) is fired once, guarded by
`_postPairStarted` (`:31`) because `PairingPaired` re-emits.

`showNicknameSheet` (`nickname_sheet.dart:20-35`) — bottom sheet, dismissible,
drag-enabled, rounded 20pt top. Copy: "Name this PC" / "Pick a label so this
Mac is easy to spot in your list. You can change it later from the home
screen." One autofocused text field hinting `defaultName` (= `pair_ok.hostname`)
or literal `"Pi"`.

Return contract (`:11-15`, `:75-82`) — non-obvious, keep it:

| Action | Returns |
|---|---|
| Save, non-empty | trimmed input |
| Save, empty | the placeholder (`defaultName` or `"Pi"`) |
| Skip | the placeholder |
| Drag-dismiss | `null` (caller treats as skip) |

Then `vm.applyNickname(result)` (no-op on null/empty, `pairing_viewmodel.dart:116-124`)
and `context.go('/home')`.

### 6.5 Paste-QR sheet

`paste_qr_sheet.dart` — a bottom sheet with a multi-line field for the raw
`remotepi://pair?…` string, submit disabled while the trimmed text is empty
(`:78-80`). Submitting closes the sheet and routes into the exact same
`_submitRaw` path as a camera scan.

---

## 7. Screen: Home (`/home`) — the plan-61 centerpiece

`home_page.dart` (859 lines), `home_viewmodel.dart`, `states/home_state.dart`,
`widgets/{session_tile,home_filter_tabs,workspace_section_header,peer_section_header,new_session_sheet}.dart`.

### 7.1 Top-level state

```dart
sealed HomeState                    // home_state.dart:6
  HomeLoading                       // :47
  HomeNoPeer                        // :51
  HomeList(peers, statusByEpk, roomsByPeer, filter, grouping)  // :187
```

`HomeList` defaults: `filter = HomeFilter.online`, `grouping = HomeGrouping.workspace`
(`:206-207`).

Body switch (`home_page.dart:55-67` region):

| State | Body |
|---|---|
| `HomeLoading` | centered spinner, `SliverFillRemaining` |
| `HomeNoPeer` | `_EmptyState` — `scanQrCode` icon, "No pairings yet" / "Scan a QR from your Mac to start." + `Scan QR` button → `/pair` (`:818-859`) |
| `HomeList` with `counts.all == 0` | `_LonelyEmptyState` — moon icon at 0.35 opacity, "Nothing here…" / "When a paired Pi opens a session, it shows up here." **Tabs hidden** (`:285-290`, `:771-816`) |
| `HomeList` otherwise | tabs + grouped list |

`ShellLayout.isZeroState` is computed as
`HomeNoPeer` **or** `state.items(normalizeEpk: toStandardB64).isEmpty`
(`home_page.dart:34-38`) and pushed post-frame (`:39-42`). It collapses the
tablet split (§11).

### 7.2 Large title bar

`SliverAppBar`, `pinned: true`, `expandedHeight: 124`, `collapsedHeight: 56`.
Title rendering happens **entirely inside `flexibleSpace`** with a manual
cross-fade on `t = (maxH - 56) / (124 - 56)` (`home_page.dart:123-201` region):
large "Remote Pi" 32pt w700 + subtitle at `opacity: t`, compact "Remote Pi"
16pt w600 at `opacity: 1-t`, and a bottom divider at `opacity: 1-t`. Using
`SliverAppBar.title` here produced a "two app bars" overlap.

Subtitle line (`:214-233`), a dot + `Relay · <status>` in mono 13pt:

| Condition | Dot | Label | Label color |
|---|---|---|---|
| `vm.isRelayConnected` | `success` | `Connected` | `muted` |
| `state is HomeNoPeer` | `muted` | `Awaiting pairing` | `muted` |
| else | `warning` | `Offline` | `warning` |

The `HomeNoPeer` case matters: with no peer the WS is never opened (its URL
embeds the destination peer's pubkey), so "not connected" is not a fault.

Actions, right to left: **Settings** gear (always) and **New session** `+`
— the latter rendered only when `vm.canCreateRemoteSessions &&
vm.machinesAcceptingSessions.isNotEmpty` (`:102-108`). Hidden rather than
disabled: the control frame rides the active WebSocket, so an unreachable Mac
genuinely cannot be asked.

### 7.3 Presence filter tabs

`HomeFilterTabs` (`home_filter_tabs.dart:12-101`). A 3-segment pill inside a
`colors.surface` container (radius 10, 3pt inner padding), each segment
`Expanded`, selected segment filled `colors.accent` with `onAccent` text,
150ms `easeOut` animation. Order and labels are fixed: **All · Online ·
Offline**, each followed by its own count.

```dart
enum HomeFilter { all, online, offline }   // home_state.dart:17
```

Counts are per-tab and independent of the active tab
(`home_viewmodel.dart:220-226`). The filter is a **pure view** over
`state.items()` (`:179-188`) — tapping a tab never reloads or refetches.

Per-tab empty state, rendered *below* the still-visible tabs when the tab is
empty but the list is not globally empty (`home_filter_tabs.dart:109-169`):

| Tab | Title | Subtitle |
|---|---|---|
| `online` | No sessions online | Live sessions appear here when a paired Pi is active. |
| `offline` | No offline sessions | Sessions you've seen before that aren't live show up here. |
| `all` | Nothing here… | When a paired Pi opens a session, it shows up here. |

### 7.4 Grouping picker

```dart
enum HomeGrouping { workspace('workspace'), device('device'), none('none') }
// home_state.dart:31-45 — fromWire falls back to `workspace` (:43)
```

A `PopupMenuButton` with the `listTree` icon, to the right of the tabs
(mounted at `home_page.dart:304`, widget at `:722-768`). Labels:

| Value | Menu label | Headers rendered |
|---|---|---|
| `workspace` (default) | Device / folder | peer header + workspace header |
| `device` | Device only | peer header only |
| `none` | No grouping | none — flat list |

Grouping is **persisted** (`preferences.dart:247-252`, key
`prefs.home_grouping`, stored by the stable `wire` string) and read on the
first `_load` so the layout does not snap back for one frame on cold start
(`home_viewmodel.dart:117`).

Dropping a header must not drop attribution: `_contextLabelFor`
(`home_page.dart:403-416`) computes what the suppressed header would have said
and hands it to the tile:

```
workspace -> null
device    -> "<folder>"
none      -> "<device>"  or  "<device> / <folder>"
```

### 7.5 The Device → Workspace → Session hierarchy

`HomeList.items()` (`home_state.dart:251-277`):

1. Sort peers by `pairedAt`, tie-broken by `remoteEpk`.
2. Look up rooms by `normalizeEpk(p.remoteEpk)` — i.e. `toStandardB64`.
3. A peer with **zero announced rooms contributes zero rows** (`:264`). There
   is no synthetic `main` tile any more: it pointed at a destination the Pi
   was not listening on.
4. **Filter out `r.isControlRoom`** (`:270`) — the supervisor's `ctrl` room is
   a control plane, not a conversation.
5. Sort rooms by `roomId` — a value that never changes (`:271`).

`HomeList.groups(only:)` (`:289-327`) regroups the **already-filtered** rows
(so an emptied workspace or device leaves no dangling header) in a single pass
with two cursors, then sorts workspaces **by `path`** (`:319`), never by the
editable folder label.

```
HomeDevice  { peer, workspaces[] }        displayName: nickname → sessionName → epk[0..8]
HomeWorkspace { path, sessions[] }        displayName: last non-empty path segment,
                                          else full path, else "Unknown folder"
HomeItem    { peer, room }                displayName: room.name → cwd basename
                                                       → peer.nickname → peer.sessionName
```

`HomeItem.workspacePath` = `room.workspacePath ?? room.cwd ?? ''`
(`home_state.dart:96`) — the empty string collapses path-less sessions into a
single "Unknown folder" group instead of one header each.

**Widget keys** (`home_page.dart:357`, `:363-364`, `:439`):

```
peer header      ValueKey("peer|<standardB64(epk)>")
workspace header ValueKey("ws|<standardB64(epk)>|<path>")
session row      ValueKey(HomeItem.sessionKey)   // "<standardB64(epk)>|<roomId>"
```

Without these, the framework matches elements by list **position**: when the
list reorders (a room goes offline, a filter flips), index 2's element — with
its ripple, scroll offset and in-flight animation — is handed to a different
session. In SwiftUI this is `ForEach(..., id: \.sessionKey)` and
`.id(sessionKey)`; do not use array indices.

### 7.6 Session tile

`session_tile.dart:11-117`. Row: 40pt circular avatar (first grapheme of the
title, uppercased, accent on `surface` with a `border` ring, `?` when empty) →
title block → presence dot. Selected state paints a 3pt left `accent` bar plus
a 6% accent fill, and trims the left padding from 18 to 15 so content does not
shift (`:65-78`).

Title preference (`:169-184`), identical to `HomeItem.displayName`:
`room.name` → last non-empty `cwd` segment → `peer.nickname` → `peer.sessionName`.

Subtitle (`:204-263`), **always exactly one line** — switching grouping must
never change row height:

```
model present:  "<model truncated to 24 chars>"            in colors.accent
model absent:   "Last paired: <relative time>"             in colors.muted
contextLabel:   "<contextLabel>  ·  <the above>"           context in muted
```

`_truncateModel` cuts at 24 chars with `…` (`:269-270`). `_relativeTime`
(`:308-318`): `just now` (<60s), `Nm ago`, `Nh ago`, `Nd ago` (<30d), else the
ISO date's first 10 chars.

#### 7.6.1 Presence dot — the four states

10×10 circle. Priority high → low (`session_tile.dart:131-143`):

| Priority | Condition | Token | Meaning |
|---|---|---|---|
| 1 | `isWorking` | `colors.working` (blue) | agent mid-turn in **this room** |
| 2 | `isReconnecting` (`!vm.isRelayConnected`) | `colors.warning` (amber) | app↔relay WS is down; no fresh signal about **any** room |
| 3 | `isLive` | `colors.success` (green) | relay announced this room live |
| 4 | else | `colors.muted` (grey) | cached / offline |

Sources: `isLive = ConnectionManager.isRoomLive(epk, roomId)`, which returns
`false` outright unless `_status is StatusOnline`
(`connection_manager.dart:957-961`); `isWorking = isRoomWorking(...)`, likewise
gated on `StatusOnline` and read from the relay's per-room `meta.working`
broadcast (`:974-982`). The relay fans `working` out to **every** subscribed
room, so a session that finishes while you are looking at a different chat
still turns its dot off — deliberately *not* OR'd with the local DB index,
which is only kept fresh for the connected room
(`home_viewmodel.dart:76-85`).

On WS loss the whole live set is cleared (`connection_manager.dart:1227-1228`)
so the first moment back online cannot read a stale live set.

**`transport_error` short-circuit.** When the relay answers a dest-miss, the
app removes `roomId` from the live set immediately
(`connection_manager.dart:802-817`), so the tile greys **now** instead of after
a ~20s no-echo timeout. Wire shape:

```jsonc
{ "type": "transport_error", "reason": "offline",
  "peer": "<destination epk, standard Base64>", "room_id": "<session id>" }
```

### 7.7 Long-press menu

`_showSessionMenu` (`home_page.dart:462-516`) — a modal bottom sheet with two
`ListTile`s:

1. **Rename session** (`pencil`, accent) → closes sheet → `_promptRename`.
2. **Delete session (local only)** (`trash2`) — `enabled: !isLive` (`:493`).
   When live: greyed with subtitle *"Only available when the room is offline"*.

**Rename dialog** (`_promptRename`, `:518-575`): `AlertDialog` "Rename session",
one autofocused mono field pre-filled with `it.room.name ?? ''` and hinting
`it.room.cwd ?? 'Session'`; `Cancel` / `Save` (accent). `Cancel` returns
`null` ⇒ no-op; `Save` returns the trimmed text (possibly empty).

`HomeViewModel.renameRoom(epk, roomId, name)` (`home_viewmodel.dart:292-331`):

```
1. conn.setRoomLocalName(epk, roomId, name)      // optimistic, immediate
2. trimmed empty/null  -> return null            // clearing is local-only;
                                                 // there is no "unset the name" on the wire
3. no actions repo     -> return null
4. !conn.isRoomLive    -> return "Session is offline — renamed on this device only."
5. find RoomInfo for roomId; send
   actions.renameSession(roomId:, displayName:, sessionId: room?.sessionId, rev: room?.nameRev)
6. ActionFailure -> return e.message
```

A non-null return is surfaced as a `SnackBar` (`home_page.dart:568-574`).

Wire (`protocol.dart:903-937`):

```jsonc
{ "type": "session_rename", "id": "<rpc>", "display_name": "backend",
  "session_id": "019ffb64-…",   // OMITTED when unknown
  "rev": 1780000000000 }        // OMITTED when unknown
```

`rev` is the `name_rev` this device **last saw** — optimistic concurrency, not
the new revision; the Pi mints the new one. Both `session_id` and `rev` are
omitted keys, never explicit `null`.

**Delete dialog** (`_confirmDelete`, `:577-609`): "Delete session?" / "Removes
locally only. If the session comes back online on the Pi, it reappears in the
list." → `Cancel` / `Delete` (in `colors.error`). Calls
`vm.deleteRoom(epk, roomId)` → `conn.deleteCachedRoom` — a local cache eviction
only. Nothing is sent to the Pi.

### 7.8 Opening a session

`_open` (`home_page.dart:611-648`), in this exact order:

```
1. await vm.openSession(peer.remoteEpk, roomId: room.roomId)
      -> prefs.setSelectedRoom(epk:, roomId:)      // "<epk>:<roomId>"
      -> savePeer(peer.copyWith(roomId:)) when the hint differs
      -> conn.switchRoom(effectiveRoom, epk: epk)  // epk passed EXPLICITLY,
                                                   // Home can tap a machine we
                                                   // are not yet dialled into
2. title  = _titleFor(peer, room)     // room.name → cwd tail → nickname → sessionName → epk[0..8]
   device = _deviceFor(peer)          // nickname → sessionName → epk[0..8]
   online = vm.isRoomLive(...)
3. SessionSelection.select(epk, roomId, title, device, online)   // AFTER step 1
4. phone only: context.push('/chat', extra: {title, device, online})
```

Step 3 must come after step 1 so the detail pane's fresh view model reads the
already-updated preferences. The three `extra` values exist purely to make the
chat top bar render correctly from frame 1 (see §8.2).

`openSession` falls back to `roomId = 'main'` when the caller passes none
(`home_viewmodel.dart:248`). See Traps §13.6.

### 7.9 New Session sheet

`new_session_sheet.dart`. This is the whole point of plan 61 Phase 3: before
it, creating a session required already having one.

```dart
Future<({String epk, String sessionId})?> showNewSessionSheet(ctx, vm)  // :25-35
```

**Local state** (`:45-55`): `_idempotencyKey = uuid7()` minted **once when the
sheet opens** (`:47`), `_machine`, `_workspaces`, `_loading`, `_creating`,
`_error`, `_progress`.

**Flow:**

1. `initState` — if `vm.machinesAcceptingSessions.length == 1`, auto-select it
   and load workspaces; a one-option picker is noise (`:57-66`).
2. Machine list: `ListTile` per machine, `monitor` icon,
   label = nickname → sessionName → `epk[0..8]` (`:137-142`).
3. `_loadWorkspaces` → `control.listWorkspaces(epk)` → `workspace_list` RPC.
4. Workspace list: `ListTile` per `RemoteWorkspace`, `folder` icon,
   title = `displayName`, subtitle = `path` (mono 11pt, single line, ellipsis).
   Disabled while `_creating`.
5. Tap → `_create(ws)` (`:91-135`):
   - `_progress = "Asking <machine> to start a session…"`
   - `vm.createRemoteSession(epk:, workspaceId:, idempotencyKey: _idempotencyKey, displayName: ws.displayName)`
   - on error → show `_error`, `_creating = false`
   - `_progress = "Waiting for the session to come online…"`
   - `vm.waitForSessionOnline(epk, sessionId)` — 45s default
     (`home_viewmodel.dart:404-426`)
   - not live in time → `_error = "Session created, but it has not come online
     yet. It will appear in the list when it does."` — honest wording; the
     spawn *was* accepted
   - live → `Navigator.pop((epk:, sessionId:))`
6. Home's `_newSession` (`home_page.dart:656-685`) resolves the announced
   `RoomInfo` from `vm.roomsFor(created.epk)` by matching
   `r.roomId == created.sessionId`, then calls `_open`. It **never synthesizes**
   a `RoomInfo`.

**Empty/blocked states**, verbatim (`:170-217`):

| Condition | Icon | Copy |
|---|---|---|
| no reachable machine | `plugZap` | Connect to a paired Mac first — the machine that will run the session has to be reachable. |
| machine has no registered folders | `folderX` | This machine has no registered folders yet. Run \`remote-pi create <folder>\` on it — only registered folders can be started remotely. |

**Wire** (`protocol.dart:967-992`, addressed to room `ctrl`):

```jsonc
{ "type": "create_session", "id": "ctl_<uuid7>",
  "idempotency_key": "<uuid7>",
  "workspace_id": "ws_…",
  "display_name": "app",     // OMITTED when null
  "background": true }       // always literally true; v1 is background-only
```

Reply: `action_ok` with `data.session_id` (`machine_control_repository.dart:170-174`)
or `action_error`. The control RPC timeout is **45s**, not the chat default 15s
(`:59-62`) — the supervisor has to fork `pi`, which loads settings and an
extension before it answers.

`machinesAcceptingSessions` returns **only the currently connected peer**
(`home_viewmodel.dart:343-351`) because the control frame rides the active
WebSocket. `MachineControlRepository._requireActivePeer` re-checks with
normalized epks and throws *"Not connected to that machine — open one of its
sessions first."* otherwise (`:132-140`).

### 7.10 Update banner (Android-only; iOS renders nothing)

`update_banner.dart`. Sits inside the scroll content between the title and the
list (`home_page.dart:54`). `UpdateBannerViewModel.check()` is a no-op
unless `enabled` (injected as `Platform.isAndroid`,
`update_banner_viewmodel.dart:58`). **On iOS this component does not exist** —
the App Store handles updates. Do not port it; note only that the Home layout
reserves a zero-height slot there.

---

## 8. Screen: Chat (`/chat` on phone, detail pane on tablet)

`chat_page.dart`, `chat_viewmodel.dart`, `states/chat_state.dart`,
`widgets/*`, `voice/*`, `attachment/*`, `quick_actions/*`.

### 8.1 States

```dart
sealed ChatState                              // chat_state.dart
  ChatNoPeer                                  // :12
  ChatConnecting                              // :17  — reachable but effectively unused, see below
  ChatReady { messages, streaming, isOffline, pairingRevoked,
              peerOfflineReason, peerPresence, isWorking,
              queuedMessages, pendingUiRequest, pendingUiError }   // :22-140
  ChatFatalError(message)                     // :143
```

**There is no connecting spinner.** `_compose` (`chat_viewmodel.dart:283-312`)
returns `ChatReady(messages: [])` while bootstrapping and `ChatNoPeer` only
after bootstrap has finished without a peer (`:289-293`). Connection status is
shown inline (top-bar pill + disabled composer), never as a full-screen state
swap, so entering the chat does not flicker.

`ChatReady.==` compares `peerPresence.runtimeType`, not the instance
(`chat_state.dart:121`) — presence carries a timestamp that would otherwise
churn the state identity.

Body mapping (`chat_page.dart:368-409`):

| State | Body |
|---|---|
| `ChatNoPeer` | `messageCircle` icon, "No active device", **no action button** — the chat is not the place to pair |
| `ChatConnecting` | `refreshCw`, "Connecting…" |
| `ChatFatalError` | `circleAlert`, message, `Re-pair` button → `/pair` |
| `ChatReady`, nothing to show | `terminal`, "Nothing here" (`:396-401`) |
| `ChatReady` | `_MessageList` |

`Preferences.hideToolCalls` filters `ToolEvent` rows out of the list
(`:369`, `:390-392`). The filter is presentation-only; the events stay in the
store.

### 8.2 Top bar

Fixed 56pt `Container` (not an `AppBar`) with a bottom border
(`chat_page.dart:145-260`).

* Leading: `chevronLeft` when `showBack` (phone), else a 16pt spacer (tablet
  detail pane passes `showBack: false`, `app_router.dart:437`). Back does
  `context.canPop() ? pop() : go('/home')`.
* Line 1: room name, mono 13pt w500, truncated to 28 chars with `…`
  (`_truncate`, `:365-366`). Resolution `_roomDisplayName` (`:326-348`):
  `room.name` → cwd basename → first user message's first 32 chars → the
  `initialTitle` nav hint → literal `"Remote Pi"`.
* Line 2: device label (mono 10pt, truncated to 24) + status pill.
  `_peerDisplayName` (`:350-363`): `peer.nickname` → `peer.sessionName` →
  `epk[0..8]`, falling back to the `initialDevice` nav hint (**not**
  `initialTitle`) while the peer record loads, then `"—"`.
* Trailing: `info` icon — **always rendered** (`:242-257`). Gating it on the
  async peer record made it pop in and shift the bar. On tap it reads
  `vm.activePeer` and no-ops if still null.

Status pill, priority high → low (`:196-212`):

| Priority | Condition | Color | Label |
|---|---|---|---|
| 1 | `vm.isWorking` | `working` | `working…` |
| 2 | `resolved && state.isOffline` | `warning` | `reconnecting…` |
| 3 | `isOnline` | `success` | `online` |
| 4 | else | `muted` | `offline` |

where `isOnline = vm.connectionResolved ? vm.isRoomLive : initialOnline`
(`:125-126`). Until the view model has read a real runtime record it trusts the
`initialOnline` hint Home passed, so the dot never flashes "reconnecting" on
the default runtime.

`vm.isWorking` (`chat_viewmodel.dart:108-112`) is
`relayRoomWorking(epk, roomId) || _working || _streaming != null` — the relay's
per-room flag OR'd with the local optimistic signals, both of which are reset
by `SyncService.activate` on a session switch so they can never leak across
sessions.

### 8.3 Revoked banner

Rendered directly under the top bar when `state.pairingRevoked`
(`chat_page.dart:75-77`, widget `:659-699`): full-width red
(`Colors.red.shade900` at 85%), `unlink` icon, *"Pairing revoked by Mac —
re-pair to continue"*, underlined `Re-pair` → `context.go('/pair')`. This is
the **only** banner kept; plain offline / Pi-gone / presence-off banners were
removed because the status pill already says it and stacking them was noise.

### 8.4 Message list

`_MessageList` (`chat_page.dart:566-617`).

* `ListView.separated`, **`reverse: true`** (`:585`), padding
  `(16, 18, 16, 12)`, 14pt separators. Index 0 = bottom = newest. The reversed
  viewport is anchored at the bottom and stays there as content arrives — the
  previous `animateTo`-on-every-rebuild fought this and produced flicker and
  runaway scroll during streaming. **Do not add manual scroll-to-bottom.**
* `itemCount = messages.length + (streaming != null ? 1 : 0)`.
* Keys are **required**: the streaming bubble is `ValueKey('streaming')` at
  index 0; every other row is `ValueKey(msg.id)` (`:597-613`). When the
  streaming bubble appears/disappears at index 0, every other index shifts by
  one; unkeyed, the framework re-matches by position and briefly paints the
  wrong message in a slot.

Row mapping (`:607-613`):

| `ChatMessage` subtype | Widget |
|---|---|
| `UserMsg` | `UserBubble` |
| `AssistantMsg` | `AssistantBubble` |
| `ToolEvent` | `ToolRequestCard` |
| `CompactionMsg` | `CompactionBubble` |

### 8.5 Bubbles

**UserBubble** (`message_bubble.dart:12-111`) — right-aligned, `maxWidth: 300`,
`colors.userBubble` fill, radius 12, selectable text. Lifecycle badge below the
bubble:

| `UserMsgStatus` / flag | Rendering |
|---|---|
| `pending` | bubble at `opacity: 0.6` + 10pt spinner + `sending…` |
| `steering` | spinner + `steering…` |
| `failed` | 1pt `colors.error` border + `circleAlert` + `not delivered` |
| `confirmed` | no badge |

`failed` means the Pi did not echo the message back within ~15s.

**AssistantBubble** (`:192-207`) — **no bubble chrome at all**. Full content
width (`SizedBox(width: double.infinity)`), rendered as Markdown (GFM + code
blocks) via `AgentMarkdown`, selectable.

**CompactionBubble** (`:120-186`) — centered card, `maxWidth: 360`,
`colors.surface` + border, check icon, "Context compacted", the recap summary,
and `~<n> tokens` on the right when `tokensBefore != null`.

**StreamingBubble** (`streaming_bubble.dart`) — full content width, partial
Markdown rendered live (the renderer tolerates incomplete syntax) and **not**
selectable while it changes; a 7×14 blinking cursor on its **own line below**
the text, driven by a 1000ms repeating controller, visible while
`controller.value < 0.5` (`:24-27`, `:58-74`). Inline-beside-text placement was
rejected: with wrapped text the cursor floated toward the middle.

**ImageBubble** (`image_bubble.dart`) — replaces the user bubble body when
`message.image != null`. Thumbnail capped at `maxHeight: 220` (width follows
the 300pt bubble cap), `BoxFit.cover`, `gaplessPlayback: true`; optional
caption below in the same padding as a text bubble. Bytes are
`base64Decode`d **once** in `initState`/`didUpdateWidget` (`:31-54`) so list
scrolling does not re-decode every frame; a decode failure renders a 120pt
`broken_image` placeholder rather than throwing. **No tap, no zoom, no
full-screen** — deliberate (plan 30 decision #7).

### 8.6 Tool cards

`tool_request_card.dart`. **Purely informational.** The `onDecide` callback is
kept on the API for forward compatibility and is unused today: the pi-extension
emits `tool_request` *after* the SDK has already accepted the tool, so
Allow/Deny buttons could only blink for a few hundred ms (`:6-17`). Do not
build approval buttons for iOS v1.

One color drives the whole card (`:27-35`):

| `ToolEventStatus` | Color | Header label | Outcome line | Dimmed |
|---|---|---|---|---|
| `pending`, `allowed` | `accent` | `RUNNING` | `⏳ Running…` | no |
| `completed` | `success` | `DONE` | `✓ Done` | no |
| `failed` | `error` | `FAILED` | `✗ <error ?? "Failed">` | no |
| `denied` | `muted` | `DENIED` | `✗ <error ?? "Denied">` | 0.65 |
| `expired` | `muted` | `EXPIRED` | `✗ Expired` | 0.65 |

Body: a `codeBg` block prefixed with `$ `. Argument formatting (`:176-225`):

* `bash` → `args["command"]`
* `edit` / `write` → `"<tool> <file_path|path>"`
* `edit` with `args["hunks"]` → a rendered diff: per line
  `"<sign> <oldLine|newLine padded to 3> <text>"` with `kind: context|remove|add|ellipsis`
  colored `text` / `error` / `success`; `"      ..."` separates hunks.
* anything else → `key=value` pairs joined by spaces.

### 8.7 Composer (`InputBar`)

`input_bar.dart` (954 lines). Host gating (`chat_page.dart:411-468`):

```
disabled = !isReady || isOffline || pairingRevoked
                    || peerOfflineReason != null
                    || peerPresence is PresenceOffline
streaming = vm.isWorking                       // the WHOLE turn, not just token flow
onCancel  = vm.cancelTargetId != null ? () => vm.cancel(id) : null
actionsEnabled = isReady && !any of the above  // gates ⚙ and 📎
```

`cancelTargetId` (`chat_viewmodel.dart:117-120`):
`_streaming?.inReplyTo` → `_sync.workingReplyTo` → the literal `'working'` when
working. Never null while working.

**Layout**, bottom-anchored `Container` padded `(14, 10, 14, 22)` with a top
border, containing a `Stack`:

```
Column
  [attachment preview]      when an image is attached
  [queued previews]         one per QueuedMsg
  Row
    ⚙ quick actions   (animated in/out)
    📎 attach
    TextField         minLines 1, maxLines 6, then scrolls internally
    ◎ primary action  (mic / send / stop)
    ■ inline stop     only while steering with content
Positioned.fill overlay: RecordingStrip / TranscribingStrip   (IgnorePointer)
```

Placeholder text (`:394-400`), in priority order: `disabled` → `Offline…`;
`streaming` → `Steer current response…`; image attached → `Add a caption…`;
else `Send a message…`.

**Primary action modes** (`:828-889`):

| Mode | When | Icon | Tap |
|---|---|---|---|
| `cancel` | `streaming && !hasContent` | `square600` | `onCancel` |
| `sendText` | `hasContent` (text **or** attached image) | `send600` | `_submit` |
| `sendAudio` | otherwise | `mic600` | hold-to-talk; plain tap → "Hold the mic to talk" hint |

The button is hidden entirely in `sendAudio` mode when voice is
`VoiceUnavailable(unsupported)` (`:895-897`). Icon transitions are a 180ms
fade+scale `AnimatedSwitcher` keyed on the mode.

**Quick-actions button visibility** (`:314-320`):
`_empty && !hasImage && !disabled && !streaming && !showStrip && hasCallback`.
It animates with a two-phase 320ms timeline — grow [0.0–0.5] then fade in
[0.5–1.0]; reverse flips the order.

**Attach button enabled** (`:306-312`): callback present && `!disabled` &&
`!streaming` && `!showStrip` && `!visionBlocked` && `!hasImage`. Always
visible; greyed to `muted @ 35%` when inert.

**Hardware Enter** (`_onComposerKey`, `:172-199`) — intercepted on the field's
**own** focus node (the leaf), because the focus manager dispatches leaf→root
and an ancestor `Focus` would see Enter only after the multiline handler had
already consumed it:

```
not KeyDown                      -> ignored
not Enter/NumpadEnter            -> ignored
disabled || IME composing active -> ignored   (CJK candidates are confirmed with Enter)
Shift held                       -> insert "\n" at the caret, handled
otherwise                        -> _submit(), handled
```

On a touch soft-keyboard the newline arrives via `performAction`, not a key
event, so this never fires there — the field grows and the user sends with the
button (`textInputAction: TextInputAction.newline`).

`_submit` (`:150-157`): trim; bail when text is empty **and** no image; clear
the field; `onSend(text)`. The host then does
`vm.sendMessage(text, image: attachmentVm.takeImageForSend())`
(`chat_page.dart:463-466`).

### 8.8 Queued messages and steering

Two distinct mechanisms — do not conflate them:

* **Steer** — sending while a turn is in flight. `ChatViewModel.sendMessage`
  attaches `streamingBehavior: steer` when `isWorking`
  (`chat_viewmodel.dart:316-323`). Wire (`protocol.dart:637-645`):
  `{"type":"user_message","id":…,"text":…,"streaming_behavior":"steer"}` — the
  key is **omitted** when null, for older Pi extensions.
* **Queue** — a follow-up committed for auto-send after the current turn.
  `queued_message_set {id, text}` / `queued_message_clear {id, target_id?}`
  (`protocol.dart:648-672`). The Pi answers with `queued_message_state`
  carrying `items[] = {id, text, editable, created_at}`
  (`:1333-1391`) — with a legacy single-item `{id, text}` fallback shape that
  defaults `editable: true` and `created_at: 0`. Items with empty text are
  dropped on parse (`:1371`).

Queued preview (`input_bar.dart:491-587`): an accent-tinted rounded card above
the composer row, header *"Queued. Tap to edit."* when `editable`, else
*"Queued follow-up."*; body text up to 3 lines. Tapping an editable item
clears it on the Pi and pulls the text back into the composer with the caret at
the end (`_editQueued`, `:159-165`); the ✕ just clears it. Non-editable items
are inert.

Images ride **only** on the immediate `user_message`, never on a queued one
(`PROTOCOL.md` §Mensagem enfileirada).

### 8.9 Voice input (hold-to-talk)

`voice/states/voice_input_state.dart`, `voice/viewmodels/voice_input_viewmodel.dart`,
`voice/widgets/recording_strip.dart`.

```dart
sealed VoiceInputState
  VoiceIdle
  VoiceRecording(elapsed, level)       // level is a 0..1 amplitude envelope
  VoiceTranscribing
  VoiceUnavailable(permissionDenied | unsupported)
```

Gesture, owned by `InputBar` so it survives the row→strip swap
(`input_bar.dart:223-272`):

```
onLongPressStart   -> _holding = true; startRecording()
onLongPressMove    -> armed = dx < -90 (logical px)    -> flips the strip to "release to cancel"
onLongPressEnd     -> armed ? voice.cancel() : voice.stopAndTranscribe()
onTap              -> VoiceHint.holdToTalk snackbar ("Hold the mic to talk", 2s)
```

**Permission-prompt race** (`_beginVoice`, `:229-249`): on first use the OS
prompt steals the hold — the finger lifts to tap Allow, so the press ends
*before* recording actually begins and the release no-ops. If the gesture is
already over when `startRecording` resolves and the state is `VoiceRecording`,
the phantom recording is cancelled. Reproduce this guard.

`stopAndTranscribe` (`voice_input_viewmodel.dart:108-116`) emits
`VoiceTranscribing`, awaits the recognizer, returns to `VoiceIdle`, and pushes
the text onto the `transcripts` broadcast stream. **Both** the release path and
the 60s cap go through this one stream (`:89-100`) so the cap can never
silently drop a transcript. The composer replaces (never appends to) the field
text and puts the caret at the end (`input_bar.dart:125-131`). **The recognizer
never auto-sends.**

`RecordingStrip` (`recording_strip.dart`): pulsing red dot (900ms, reversing),
`MM:SS` timer, a rolling 28-bar waveform fed one sample per `level` change, and
a "‹ slide to cancel" hint. Timer turns `warning`-colored in the last 10s
(`warnBefore`), and `muted` once cancel is armed. It renders inside an
`IgnorePointer` overlay so it never steals the in-flight gesture
(`input_bar.dart:462-481`).

Permission denial surfaces `VoiceHint.permissionDenied` → a 5s snackbar
*"Microphone access is off — enable it in Settings to dictate."* with a
`Settings` action deep-linking to app settings (`chat_page.dart:539-552`).

### 8.10 Image attachment

`attachment/states/attachment_state.dart`, `attachment/viewmodels/attachment_viewmodel.dart`,
`widgets/attach_sheet.dart`.

```dart
sealed AttachmentState { visionSupported: bool? }   // null = unknown, do NOT gate
  AttachmentEmpty
  AttachmentPicking
  AttachmentAttached(image)
enum AttachHint { cameraPermissionDenied, pickFailed }
```

`attachBlockedByVision => visionSupported == false` (`:16`) — tri-state on
purpose: gate the attach button only when the active model is *known* not to
accept images. Vision is resolved from the model catalogue the app already
fetches for the quick-actions picker, re-resolved on every
`activeRoomMetaStream` emit (`attachment_viewmodel.dart:19-22`, `:84-110`). If
the catalogue is unavailable, vision stays `null` and the button stays enabled.

**Attach sheet** (`attach_sheet.dart:15-34`): a bottom sheet with exactly two
rows — `Camera` (`camera` icon) and `Photo Library` (`image` icon) — returning
`AttachSource`. Wrapped in `DismissOnSessionChange` (§11.2).

`takeImageForSend()` (`attachment_viewmodel.dart:73-78`) returns
`MessageImage(data: base64Encode(bytes), mime: image.mime)` and resets to
empty. Wire (`protocol.dart:580-596`, `PROTOCOL.md` §Imagens):

```jsonc
{ "type": "user_message", "id": "…", "text": "caption or empty",
  "images": [ { "data": "<STANDARD base64, no data: prefix>", "mime": "image/jpeg" } ] }
```

`images` is **omitted entirely** when empty (`protocol.dart:643-644`).

Hints (`chat_page.dart:493-522`): `cameraPermissionDenied` → 5s snackbar
*"Camera access is off — enable it in Settings to attach a photo."* + Settings
action; `pickFailed` → 3s *"Couldn't attach that image."*

### 8.11 Quick Actions sheet

`quick_actions/widgets/quick_actions_sheet.dart`, `.../viewmodels/quick_actions_viewmodel.dart`.

Opened from the ⚙ button. Bottom sheet, `isScrollControlled`, rounded 16pt top,
barrier `black @ 60%`. Two context values are captured from the **page**
context before the modal route is pushed (`:27-32`), because the modal's
builder context sits above the chat page's providers: the `ScaffoldMessenger`
(so toasts outlive the sheet) and the `SessionSelection` (for §11.2).

Rows, top to bottom (`:139-167`):

| Row | Icon | Label / subtitle | Busy signal |
|---|---|---|---|
| 1 | `shrink` | **Compact context** / "Summarize old turns to free room." | `ActionName.sessionCompact` |
| 2 | `sparkles` | **New session** / "Clears the conversation on the Pi." | `ActionName.sessionNew` |
| 3 | `memoryStick` | **Model** / `<current label>` + chevron | `ActionName.modelSet` |
| 4 | `brain` | **Thinking** + a 6-way segmented control | `ActionName.thinkingSet` |

Busy renders a 14pt spinner in place of the trailing affordance and disables
the row.

* **Compact** (`_onCompact`, `:175-187`): dispatch `session_compact`; on
  `action_ok` just close the sheet (no success toast — it is quiet and
  frequent); on failure the sheet stays open and the error toasts via
  `vm.errors`.
* **New session** (`_onNewSession`, `:189-263`): **UI copy lies about the wire
  name** — see Traps §13.4. Closes the sheet **first** (capturing the root
  navigator before popping), then shows an `AlertDialog`:
  *"Start a new session?"* / *"This clears the Pi-side conversation history.
  The current thread cannot be resumed."* → `Cancel` / `Start new`. On confirm,
  dispatch `session_new` and then call `chat.clearActiveSession()` to wipe the
  local mirror. Because the sheet is already gone, its `vm.errors` listener is
  gone too — failures are toasted directly through the captured messenger.
* **Thinking** (`_ThinkingSegmented`, `:514-558`): one segment per
  `ThinkingLevel`, labels `off · min · low · med · high · x`, keys
  `qa-thinking-<wire>`. Selection tints with `accent @ 15%`.

`QuickActionsViewModel` (`quick_actions_viewmodel.dart`):

* State carries `currentThinking`, `currentModel` (structured `WireModel`) and
  `currentModelName` (the display string from `room_meta.model`) — the display
  row prefers `currentModel?.name ?? currentModelName` and falls back to
  `"Choose a model"` (or `"Switching…"` while busy).
* `setModel` / `setThinking` flip the highlight **optimistically** and revert on
  `ActionFailure` (`:58-112`).
* `_adoptMeta` (`:145-179`) hydrates from `activeRoomMetaStream`, so the sheet
  reflects the Pi's real state on first open and picks up external changes
  (another paired device, or `/model` in the TUI). If the meta's model name
  differs from the structured `currentModel.name`, the structured model is
  dropped to `null` so the picker re-fetches (`:155-160`).

### 8.12 Model picker sub-sheet

`quick_actions/widgets/model_picker_sheet.dart`. Pushed from the Model row,
sharing the parent view model by value (`:27-31`). Height capped at 78% of the
screen (`:79`).

Header: back arrow, "Choose a model", refresh icon (`model-picker-refresh`).
Body is a `FutureBuilder<ModelsCatalogue>`:

| Snapshot | Body |
|---|---|
| not done | 120pt centered 18pt spinner |
| error | message (`ActionFailure.message` or "Failed to load models") + `Retry` |
| `models.isEmpty` | "No models available" |
| otherwise | provider chips + model list |

Provider chips are rendered **only when more than one provider exists**
(`:214`), sorted, prefixed by an `all` chip. Rows (`_ModelTile`, `:298-366`):
`model.name` (accent when current), a `reasoning` badge when
`model.reasoning`, subtitle `"<provider> · ctx <n>k"` (or just the provider
when `contextWindow <= 0`), and a check icon on the current model.
"Current" compares **both** `id` and `provider` (`:246-247`).

Tapping a row dispatches `model_set {provider, model_id}` and pops on success;
failure is toasted by the parent sheet's listener.

### 8.13 `ask_user` extension sheet

`widgets/extension_ui_sheet.dart` + `chat_viewmodel.dart:247-276`, `:330-348`.

This is **not** a bottom sheet: it is a full-screen modal layered *above* the
chat `Scaffold` in a `Stack` (`chat_page.dart:90-108`), purely reactive — it
leaves the tree when `pendingUiRequest` clears. No route lifecycle to manage.
It is keyed `ValueKey(uiRequest.id)` because question ids repeat across flows
(e.g. `"goal"`), and reusing the state would leak old selections into a new
modal.

**Inbound routing** (`_onExtensionUiRequest`, `chat_viewmodel.dart:254-276`):

```
method == notify:
    id matches the open request?
        notify_type in {warning, error} -> keep the modal open,
                                           set pendingUiError = message
                                           (or "Answer was not accepted.")
        otherwise                       -> a `completed` dismiss: clear the
                                           request and the error
    id does not match                   -> ignored in v1 (stand-alone notices)
any other method                        -> open/replace the modal, clear the error
```

**Two rendering modes.** When `request.ask` (the pi-ask enrichment) is present,
render the rich flow; otherwise the degraded plain-SDK form.

*Rich* (`:255-415`): a `ListView` of questions, 24pt separators. Per question:
prompt (`titleMedium`), an advisory `required` chip (pi-ask marks `required` as
advisory only — it **never blocks submission**, `:279-286`), a `multi` chip when
applicable, the optional `label` in muted, one tappable option card per option,
and a free-text field hinting *"Type your own…"*. Option cards show a checkbox
(multi) or radio (single) glyph, the label, an optional description indented
30pt, and — for `type == preview` — the option's `preview` in a `codeBg` block.
`_isMulti` checks **both** `q.type` and `q.presentedType` (`:101-103`).

*Degraded* (`:417-468`): `select` → a radio group over `request.options`;
`input`/`editor` → a 5-line text field hinting `request.placeholder`;
`confirm` → "Please confirm."; `notify` → nothing (unreachable).

Submit enablement (`_canSubmit`, `:105-123`): rich → at least one question has
a selection **or** non-empty custom text; degraded → `select` needs a value,
`input`/`editor` need non-empty trimmed text, `confirm` is always enabled,
`notify` never.

**Response construction** (`_buildResponse`, `:156-196`) — pi-ask forbids
combining a selected value with custom text on a non-multi question, so
**custom text wins** (`:170`). Questions with neither are omitted from
`answers` entirely.

```jsonc
// rich submit
{ "type": "extension_ui_response", "id": "<request id>",
  "ask": { "flow_id": "…", "kind": "answer", "mode": "submit",
           "answers": { "goal": { "values": ["a","b"], "customText": "…" } } } }

// rich cancel
{ "type": "extension_ui_response", "id": "<request id>", "cancelled": true,
  "ask": { "flow_id": "…", "kind": "cancel" } }

// degraded
{ "type": "extension_ui_response", "id": "…", "value": "…" }        // select/input/editor
{ "type": "extension_ui_response", "id": "…", "confirmed": true }   // confirm
```

Serializer omissions (`protocol.dart:1998-2006`, `:1943-1950`): `cancelled` is
written only when true; `value`, `confirmed`, `ask` only when non-null; inside
an answer, `values` only when non-empty and `customText`/`note` only when
non-empty. Note the **camelCase** `customText` and `optionNotes` inside the
answer object, versus **snake_case** `flow_id` around it — this asymmetry is
real, it mirrors pi-ask.

**Submit lifecycle** — the subtle part:

* `_submit` sets `_submitting = true`, arms a **25s backstop timer** (`:77-86`)
  and sends. It does **not** close the modal optimistically: pi-ask may reject
  the answer (`invalid_answer`) without emitting `completed`, which would close
  the modal and leave the flow blocked on the desktop — a dead end
  (`chat_viewmodel.dart:330-339`).
* The modal closes only on the `completed` dismiss notify.
* When the backstop fires, `_submitting` clears and `_awaitHint` shows
  *"No response from Pi yet — retry or cancel."* (`:488-495`).
* `respondExtensionUi` returns whether the frame actually left the device; a
  send with no live channel immediately sets
  *"Not connected — check the link to Pi and retry."* rather than spinning 25s
  (`chat_viewmodel.dart:340-348`).
* `didUpdateWidget` (`:55-75`) stops the spinner when a **new** error arrives,
  but explicitly **not** when an error is cleared (non-null → null) — that is
  the view model wiping the old message at the start of a retry, and stopping
  there would re-enable the buttons mid-flight and allow a double submit.
* Android system back is intercepted with `PopScope(canPop: false)` and mapped
  to cancel (`:223-227`). On iOS, map the swipe-to-dismiss / close button the
  same way: a dismissal must send the cancel frame, never just disappear.

### 8.14 Session info dialog

`_showSessionInfo` (`chat_page.dart:266-324`). `AlertDialog` "Session info",
rows of uppercase mono label + **selectable** value (so the path can be
copied):

| Label | Value |
|---|---|
| NAME | resolved room name |
| PATH | `room?.cwd ?? "—"` |
| OWNER | nickname → sessionName → `epk[0..8]` |
| MODEL | `room.model` — row omitted when absent |
| ROOM | `room?.roomId ?? "—"` (this is the session id post-plan-61) |
| PAIRED | `pairedAt` truncated at the `T` |

---

## 9. Screen: Settings

`settings_page.dart`, `settings_sheet.dart`, `settings_viewmodel.dart`.

Two presentations of the **same page** (`settings_sheet.dart:14-20`):

* phone → `context.push('/settings')`, leading `chevronLeft`, tooltip "Back";
* tablet → `showSettingsSheet` — a modal bottom sheet at
  `heightFactor: 0.92`, `clipBehavior: antiAlias`, rounded 16pt top; the page
  is built with `embedded: true` so the leading becomes a 22pt `x` with
  tooltip "Close" (`settings_page.dart:33-42`).

Sections, in order (`:48-77`):

### 9.1 RELAY

A text field pre-filled with `vm.relayUrlOverride` (= `prefs.relayUrl ??
kDefaultRelayUrl`), helper text `Current: <effectiveRelayUrl>`, inline
`errorText`, plus `Save` and `Use default Relay` (which stuffs
`kDefaultRelayUrl` into the field and saves).

`saveRelayUrl` (`settings_viewmodel.dart:67-87`):

```
empty/blank -> "Enter a URL or clear the field to use the default relay."
invalid     -> relayUrlValidationMessage(url)
valid       -> prefs.setRelayUrl(trimmed)
               conn.disconnect()
               conn.boot(preferredEpk: prefs.selectedPeerEpk,
                         preferredRoomId: prefs.selectedRoomId)   // BOTH halves
```

Carrying the room half across a relay change is plan-61 Phase 0: reconnecting
with the epk alone dropped the user onto `PeerRecord.roomId ?? 'main'`, i.e. a
different chat than the one they were reading. Success shows a 2s
`"Relay updated"` snackbar.

### 9.2 DISPLAY

Three controls, all backed by `Preferences` (`ChangeNotifier`, watched
directly by the section):

| Control | Type | Values | Persisted key |
|---|---|---|---|
| Theme | 3-way segmented | System / Light / Dark | `prefs.theme_mode` (by `name`) |
| Text size | segmented | `AppFontScale.values` (by `label`) | `prefs.font_scale` (by `name`) |
| Hide tool calls in chat | switch | bool | `prefs.hide_tool_calls` |

Text size exists because the app hardcodes font sizes and Flutter cannot read
iOS's per-app Text Size; it is applied as a `TextScaler` above the router so it
also scales per-widget `copyWith(fontSize:)` overrides. A native iOS client
should prefer Dynamic Type and may drop this control — but then the setting has
no home, so keep an equivalent if the design keeps fixed sizes.

### 9.3 PAIRINGS

`SettingsLoading` → spinner; `SettingsNoPeer` → `monitorSmartphone` icon, "No
pairings yet" / "Tap + to pair a new Mac." + `Scan QR`; `SettingsList` → one
`PeerListItem` per peer.

`PeerListItem` (`peer_list_item.dart`): title = nickname when set, with
`sessionName` as a muted second line; trailing pencil → nickname editor;
**swipe end-to-start** reveals a red `Revoke` background and calls
`confirmDismiss` → the revoke confirm dialog → `vm.revoke(epk)`
(`settings_page.dart:428-436`). Returning `false` from the confirm snaps the
row back.

Below the list: `Add new pairing` outlined button → `/pair`.

`revoke` (`settings_viewmodel.dart:95-140`) — order matters:

```
1. wasActive = conn.activePeer?.remoteEpk == epk
2. clear prefs.selectedPeerEpk when it matches
3. storage.deletePeerSilent(epk)          // SILENT: the normal hook would try
                                          // to auto-publish members=[] and the
                                          // safety net would refuse it, leaving
                                          // the relay holding stale membership
4. meshSync.publish(allowEmpty: remaining.isEmpty)   // the only opt-out in the app
5. conn.subscribeToPeers(remaining)
6. if wasActive: disconnect; if peers remain, pick the pairedAt-ordered first,
   setSelectedRoom(epk: fallback) with NO room (it belonged to the revoked peer),
   and conn.boot(preferredEpk: fallback)
7. if no peers remain: prefs.setOnboardingCompleted(false)   // revoke == start fresh
```

---

## 10. Traps and edge cases in the small sheets

* **Revoke confirm dialog** (`widgets/revoke_confirm_dialog.dart`) returns a
  `bool`; the `Dismissible` uses it as `confirmDismiss`, so `false` must snap
  the row back rather than delete.
* **Nickname editor** (`widgets/nickname_editor.dart`) returns `null` on cancel
  and `''` to *clear* the nickname — the caller maps `''` to `null` before
  saving (`settings_page.dart:442-450`). Absent-vs-empty matters here.

---

## 11. Adaptive tablet master–detail

### 11.1 Layout

`isWideLayout(context)` is `MediaQuery.sizeOf(context).shortestSide >= 600`
(`adaptive.dart:6`, `:27-28`). **`shortestSide`, not `width`** — width alone
confuses device class with orientation: a phone in landscape has
`width >= 600` and used to be misclassified as a tablet. `shortestSide` is
rotation-invariant and still collapses correctly for iPadOS Split View / Slide
Over, because `MediaQuery` measures the window given to the app, not the
physical device.

Two-pane is active when `isWideLayout && !ShellLayout.isZeroState`
(`app_router.dart:270-271`). Layout: a fixed **360pt** master, a 1pt
`VerticalDivider` in `colors.border`, and an `Expanded` detail
(`:282-300`).

**The notch fix** (`:275-281`): on a notched device in landscape each pane's
own `SafeArea` reads the *full screen* insets and pads the edge facing the
divider too, producing a phantom gutter. Each pane is wrapped in
`MediaQuery.removePadding` stripping only the divider-facing inset
(`removeRight` on the master, `removeLeft` on the detail); outer edges and
top/bottom stay inset, and the backgrounds still paint full-bleed. The iOS
equivalent: strip the corresponding safe-area edge per column.

`ShellLayout.isZeroState` defaults to `false` (`adaptive.dart:65-69`) so the
common case (sessions already exist at boot) does not flash single→split.

### 11.2 `SessionSelection`

`adaptive.dart:86-150`. A `ChangeNotifier` holding
`({epk, roomId, title, device, online})?`, deliberately **not** restored across
launches: the app always starts with nothing selected and the detail pane shows
`DetailPlaceholder` (`messagesSquare` icon at 0.4 opacity, "Select a session" /
"Pick a session on the left to open its chat.").

* `sessionKey` → `"<toStandardB64(epk)>|<roomId>"` (`:96-99`).
* `matches(epk, roomId)` compares the **normalized** epk (`:109-114`). Comparing
  raw strings meant the same session stopped matching itself when one screen
  wrote url-safe and another standard base64 — the tile lost its highlight and
  the detail pane did not recognize the selection.
* `select(...)` is a **no-op** when the normalized `(epk, roomId)` is unchanged
  (`:136-140`), so re-tapping the open session does not rebuild anything.

`_DetailPane` (`app_router.dart:413-441`) keys its provider subtree
`ValueKey('chat-${sel.sessionKey}')`, so switching sessions tears down the old
chat view model and builds a fresh one bound to the now-selected peer. Keying
on the **raw** epk re-keyed the same session whenever the selection was written
in the other base64 encoding, destroying and rebuilding the whole chat for
nothing.

**Modal orphaning.** Sheets pushed from the chat live on the detail-pane
navigator. Changing the selection swaps the chat *under* an open sheet, leaving
it hovering over a different session. `DismissOnSessionChange`
(`quick_actions/widgets/dismiss_on_session_change.dart`) snapshots the
`(epk, roomId)` at mount and, on any change, does
`Navigator.popUntil((r) => r is! PopupRoute)` — closing the sheet **and any
sub-picker above it**. It wraps the Quick Actions sheet
(`quick_actions_sheet.dart:43-52`) and the attach sheet
(`attach_sheet.dart:29-33`). Any new chat-scoped sheet must do the same.

The tile highlight is applied **only** in two-pane mode
(`home_page.dart:432-437`) — on phone the list is covered by the pushed chat,
so a persistent highlight would be meaningless.

---

## 12. What must survive backgrounding — and what must not be re-derived

iOS will suspend and may terminate the app. Split the state three ways.

### 12.1 Must be persisted (survives process death)

| State | Storage today | Note |
|---|---|---|
| Owner Ed25519 key | iCloud Keychain (synced) | boot blocks on it (§4) |
| Peer records (`PeerRecord`) | secure storage | `remoteEpk`, `sessionName`, `nickname`, `pairedAt`, `roomId` **hint** |
| `mesh_versions` blob + version watermark | local cache + relay | anti-rollback by monotonic `version` |
| **Selected session pointer** | `prefs.selected_peer_epk` = `"<epk>:<roomId>"` | one composite string; **restore both halves** |
| Relay URL override | `prefs.relay_url` | `null` ⇒ `kDefaultRelayUrl` |
| `onboardingCompleted` | `prefs.onboarding_completed` | |
| Theme / font scale | `prefs.theme_mode`, `prefs.font_scale` | stored by stable `name` |
| `hideToolCalls` | `prefs.hide_tool_calls` | |
| **Home grouping** | `prefs.home_grouping` | stored by stable `wire` string, `fromWire` defaults `workspace` |
| Messages | Hive `msgs_<toAppEpk(epk)>__<roomId>` | |
| Room cache (incl. `session_id`, `workspace_path`, `name_rev`, `role`) | persisted per peer | so a cold start does not look legacy |

### 12.2 Must survive backgrounding within a session (in-memory, but never reset by a data re-emit)

* **`HomeFilter`.** `_load` runs on *every* `PairingStorage` mutation — room
  adoption, per-turn metadata persistence, mesh sync — i.e. many times per
  minute while a session works. Rebuilding `HomeList` with the default
  `online` threw the user back to the Online tab mid-scroll; that was the
  "sessions jumping" report. It is preserved in `_load`
  (`home_viewmodel.dart:107-113`) **and** in the status handler
  (`:143-155`), which would otherwise reset it on every WS flap.
* **`HomeGrouping`.** Same rule, plus it is persisted.
* **Scroll position and tile identity.** Guaranteed by the stable widget keys
  (§7.5), not by list order.
* **`SessionSelection`** for the current run (tablet). Not restored across
  launches, by design.
* **Composer draft text, attached image, recording state.** All live in the
  composer's own state. Backgrounding mid-recording must release the mic:
  `VoiceInputViewModel.dispose` cancels an in-flight session but never disposes
  the shared service (`voice_input_viewmodel.dart:133-144`). On iOS, also cancel
  on `scenePhase != .active`.
* **`pendingUiRequest` / `pendingUiError`.** The `ask_user` modal is derived
  from view-model state, not from a route — so it survives a rebuild but is
  **not** persisted. If the app is killed with a modal open, the desktop flow is
  still blocked; on relaunch the Pi will re-emit only if pi-ask re-requests.
  See §15.

### 12.3 Must NOT be re-derived from a mutable label (the whole point of plan 61)

Never recompute any of these from `display_name`, `room.name`, `cwd`, or list
position:

* the room/session id used to address frames (`room` in the envelope);
* the Hive box name and session index key;
* the persisted selection pointer;
* widget/`ForEach` identity;
* sort order — `HomeList.items()` sorts by `pairedAt`/`remoteEpk` and `roomId`
  precisely because sorting by the display label meant a rename silently moved a
  row to a different index, and (before tile keys) handed the tapped position to
  a different chat (`home_state.dart:232-250`);
* workspace grouping order — `pathOrder.sort()` sorts by **path**, not by the
  editable folder label (`:317-319`).

A rename is a metadata patch. It must change exactly one thing: the string
shown to the user.

---

## 13. Traps

### 13.1 base64url vs standard base64 — the recurring bug

Two encodings of the same 32 Ed25519 bytes are in play at all times
(`epk_encoding.dart:1-15`):

* **base64url** (`-_`, no padding): the QR payload, `PairingStorage`,
  `PeerRecord.remoteEpk`.
* **standard base64** (`+/`, `=` padded): the relay registry, `hello`, the
  `peer` field of every envelope, and every relay-emitted control frame.

Rules that must hold in Swift:

* Everything going **to** the wire: `toStandardB64` (`:24-36`).
* Every epk arriving **from** the relay used as a store key: `toAppEpk`
  (`:41-60`) — which **strips `=` padding** to match QR payloads.
* Every **comparison** of two epks normalizes both sides. `SessionSelection.matches`
  (`adaptive.dart:109-114`), `HomeItem.==` (`home_state.dart:108-115`),
  `_requireActivePeer` (`machine_control_repository.dart:132-140`) and the boot
  restore (`app_router.dart:129-135`) all do this. Every place that historically
  did not was a bug.
* Both helpers are **idempotent** and return the input unchanged on a decode
  failure — never silently drop a peer id.

Separately: the envelope's `ct` is **standard** base64 on send
(`ws_transport.dart:217`, `:233`) but decoding accepts either variant with
defensive padding (`:301-310`). Be permissive inbound, strict outbound. And
`ct` is base64 of **plaintext JSON**, not ciphertext — there is no E2E; do not
write product copy claiming otherwise.

### 13.2 `room_meta_updated` does not carry `session_id`, `workspace_path`, or `role`

The relay's broadcast builds `meta` from scratch with only `model`, `thinking`,
`working`, `name`, `name_rev`
(`relay/src/peers/registry.rs:352-378`). The identity fields ride **only** on
`hello` → `room_announced` / `rooms`
(`relay/src/handlers/peer.rs:118-155`). Consequences:

* Learn `session_id` / `workspace_path` / `role` from announce and snapshot
  frames only.
* On a snapshot merge, **preserve** the previously-known values when the frame
  omits them (`connection_manager.dart:842-849`) — dropping them makes a known
  session look legacy again and lose its workspace row.
* `role` is only ever set at `hello` time, so a control room can never *become*
  a chat room mid-connection. That is the invariant that lets Home filter it
  once at `items()`.

### 13.3 `name_rev` gating — and the deliberate double gate

The relay accepts a name patch only when `incoming > stored`
(`relay/src/peers/registry.rs:306-311`); a rejected patch **still re-broadcasts
the current name** (`:366-375`), which is what re-syncs the device that sent the
stale one. The app applies the *same* gate again on receipt
(`connection_manager.dart:765-783`).

Acceptance table (both sides agree):

| `name` in patch | `name_rev` | stored rev | accepted? |
|---|---|---|---|
| absent | any | any | no (nothing to apply) |
| present | absent | any | **yes**, on trust (legacy Pi) |
| present | present | absent | **yes** (first revision wins) |
| present | `n` | `m` | `n > m` |

A bare `name_rev` with no `name` carries no state and produces no broadcast at
all (relay `RoomMetaPatch::is_empty`, `rooms.rs:100-105`).

Client-side, `hasName` on `RoomMetaUpdated` defaults to **`false`**
(`protocol.dart:496-501`), unlike `hasModel`/`hasThinking` which default to
`true`. The overwhelming majority of these updates are model/thinking/working
churn; defaulting `hasName` to `true` would make every one of them look like a
rename-to-null.

In Swift: model this as `name: Present(String?) | Absent`, not `String?`.

### 13.4 "New session" in the quick-actions sheet is NOT `create_session`

The sheet row labelled **"New session"** with subtitle *"Clears the
conversation on the Pi"* dispatches `session_new`, which wipes the context of
the **same** session, in the same process, keeping the same `session_id`
(`quick_actions_sheet.dart:148-156`, `PROTOCOL.md` §App actions). Plan 61
renamed this action **New Context** in the target model
(`plan/61-stable-session-identity.md:63-65`) — **the Flutter UI copy was never
updated.** The genuinely-new-session flow is the `+` in the Home title bar,
which sends `create_session` to the `ctrl` room.

**The iOS client should ship the plan-61 copy: "New Context" in the quick
actions sheet, "New Session" only on Home.** The wire names stay as they are.
This is a real disagreement between the plan and the app; the plan wins on copy,
the app wins on wire.

### 13.5 `'ctrl'` is a reserved room id and must never render as a chat

`kControlRoomId = 'ctrl'` (`protocol.dart:933`) mirrors `CONTROL_ROOM_ID`
(`pi-extension/src/protocol/control_wire.ts:19`). It is neither a 12-char
digest nor a UUID, so it cannot collide with a chat room. Three places depend
on it:

1. `HomeList.items()` drops `r.isControlRoom` rows (`home_state.dart:265-271`).
2. The inbound room demux **exempts** `ctrl` from the room-mismatch drop
   (`ws_transport.dart:102-116`) — the app's active room is whichever chat is
   open, so without the exemption every gateway reply would be discarded.
3. Control RPCs are addressed with `sendToRoom(msg, kControlRoomId)`
   (`machine_control_repository.dart:116`) which sends **one** frame at that
   room *without moving the connection's active target* — asking a machine for
   its workspaces must not disturb the open chat.

The gateway announces `role: "control"`, `name: "machine control"`, plus `cwd`
and `workspace_path` set to its own cwd (`pi-extension/src/daemon/gateway.ts:113-123`).
Filtering by `role`, not by the literal `"ctrl"` string, is the right check —
but both are true today.

### 13.6 The `'main'` fallback room is a legacy landmine

`HomeViewModel.openSession` defaults `roomId` to `'main'` when the caller passes
none (`home_viewmodel.dart:242-248`), and `ChatViewModel._bootstrap` defaults
`prefs.selectedRoomId ?? 'main'` (`chat_viewmodel.dart:144`). Meanwhile
`HomeList.items()` no longer *creates* synthetic `'main'` tiles, precisely
because that tile pointed at a destination the Pi was not listening on: the
frame was dropped by the relay and the row felt like a ghost
(`home_state.dart:224-231`).

For a new iOS client: **do not reproduce the `'main'` fallback.** Model the
selection as `sessionId: String?` and treat "no session" as a real state
(show the placeholder / navigate nowhere) rather than inventing an id. Every
call site that would have needed `'main'` is a call site that should not have
been reachable.

### 13.7 `started_at` is not stable and not a sort key

`RoomMeta.started_at` is stamped at registration time in the relay
(`relay/src/handlers/peer.rs:139-142`), so it changes on **every reconnect**.
It is excluded from ordering (`home_state.dart:248-250`) and, historically,
including it in `HomeItem.==` recycled tiles several times a minute.

### 13.8 `working` is a bool, never "explicitly null"

Wire-level: `working` is a non-nullable bool in the relay's `RoomMeta`
(`relay/src/rooms.rs:57-60`) and always rides along in the broadcast
(`registry.rs:361-365`). Patch-level: `Option<bool>` where `None` means "not in
this patch, preserve" (`rooms.rs:76-79`), matching the app
(`connection_manager.dart:760-764`, `protocol.dart:482-486`). So there is no
`hasWorking` flag and none is needed. Do not model it as a tri-state.

### 13.9 Idempotency keys must be minted per *intent*, not per *attempt*

`_NewSessionSheetState._idempotencyKey` is a `final` field initialized once at
sheet construction (`new_session_sheet.dart:47`) and reused for every retry.
Minting a fresh key per attempt "defeats the mechanism entirely"
(`protocol.dart:960-966`); the machine keeps the key for ≥24h and replays the
original outcome — **including the original error**, so a retry loop cannot
become a spawn loop (`PROTOCOL.md` §Idempotência). Mutating control actions
with no `idempotency_key` are **refused**, not defaulted.

In Swift: the key belongs to the sheet's model object, created in `init`, not
recomputed in `body` or in the action closure.

### 13.10 `action_ok` means "spawn requested", not "room is up"

`create_session` returns as soon as the supervisor forked `pi`. The room exists
only once that child connects and says hello. Opening the chat earlier targets
a room the relay does not know and the first message is dropped
(`home_viewmodel.dart:395-403`). Hence `waitForSessionOnline` (45s) before
handing back a session, and Home resolving the `RoomInfo` from the live
snapshot rather than synthesizing one (`home_page.dart:662-683`). **The app
must never derive a room id itself** (plan 61 D8).

### 13.11 Absent vs explicit null, by field

| Frame / field | Absent | Explicit `null` |
|---|---|---|
| `room_meta_update.<field>` | preserve current | clear (for nullable fields) |
| `room_meta_update.working` | preserve | *impossible* — `false` is the off state |
| `room_meta_update.name` | preserve (`hasName == false`) | clear the name |
| `session_rename.session_id` | omit key when unknown | never send `null` |
| `session_rename.rev` | omit key when unknown | never send `null` |
| `create_session.display_name` | omit key | never send `null` |
| `user_message.streaming_behavior` | omit when not steering | never send `null` |
| `user_message.images` | omit when empty | never send `[]` or `null` |
| `extension_ui_response.cancelled` | omit when false | — |
| `extension_ui_response.value`/`confirmed`/`ask` | omit when null | — |
| `RoomInfo.workspace_path` | falls back to `cwd` on parse (`protocol.dart:287-289`, relay `peer.rs:123-130`) | — |
| Nickname editor result | `null` = cancel | `''` = clear the nickname |

`RoomInfo.copyWith` uses an `_kRoomInfoUnset` sentinel for exactly this reason
(`protocol.dart:200-202`, `:309-344`): plain `String? name` with `name ?? this.name`
turned "set to null" into "keep current", which would have made a
rename-to-empty a silent no-op instead of falling back to the cwd basename. In
Swift, use a `Patch<T>` enum (`.unchanged` / `.set(T?)`), never `T?`.

### 13.12 A rejected rename still re-broadcasts — do not treat it as an error

When the relay refuses a stale `name_rev`, it broadcasts the **current** name
anyway. The client that sent the stale patch will therefore see its label snap
to the winning value. That is convergence, not failure. Only `action_error`
from the Pi is a failure the UI reports.

### 13.13 The relay carries `pi_envelope` code this fork does not use

`relay/src/handlers/pi_forward.rs` implements Pi→Pi forwarding authorized by
signed co-membership. **No pi-extension code emits `pi_envelope`**
(`PROTOCOL.md` §Mesh membership note). Do not implement it on iOS and do not
infer a feature from its presence in the relay.

---

## 14. Suggested Swift types

Sketches only — not an implementation.

```swift
// ── Identity ────────────────────────────────────────────────────────────────
/// A Pi-key. Stores the canonical STANDARD-base64 form; never compare raw.
struct MachineID: Hashable, Codable {
    let standardB64: String                 // "+/" with "=" padding
    var appForm: String { /* base64url, unpadded */ }
    init(anyBase64: String) { /* normalize once, at the boundary */ }
}

/// room_id == session_id. Opaque: may be a UUID (post plan-61) or a
/// 12-char digest (legacy Pi). Never parse it, never derive it.
struct SessionID: Hashable, Codable, RawRepresentable {
    let rawValue: String
    static let control = SessionID(rawValue: "ctrl")!
}

/// The only legitimate key for storage, navigation and view identity.
struct SessionKey: Hashable {
    let machine: MachineID
    let session: SessionID
    var storageKey: String { "\(machine.standardB64)|\(session.rawValue)" }
}

// ── Patch semantics (§13.11) ────────────────────────────────────────────────
enum Patch<T: Codable & Equatable>: Equatable {
    case unchanged                 // key absent
    case set(T?)                   // key present; nil == explicit clear
}

// ── Room metadata ───────────────────────────────────────────────────────────
struct RoomInfo: Equatable {
    let roomID: SessionID
    var name: String?
    var cwd: String?
    let startedAt: Int64           // NOT an identity, NOT a sort key (§13.7)
    var model: String?
    var thinking: ThinkingLevel?
    var working: Bool = false      // plain Bool (§13.8)
    var sessionID: String?         // PRESENCE == "this room is stable"
    var workspacePath: String?     // falls back to cwd at parse time
    var nameRev: Int64?
    var role: String?              // "control" -> never a chat tile
    var isControlRoom: Bool { role == "control" }

    // Identity is (machine, roomID) only.
    static func == (a: Self, b: Self) -> Bool { a.roomID == b.roomID }
}

// ── Home ────────────────────────────────────────────────────────────────────
enum HomeFilter: String, CaseIterable { case all, online, offline }
enum HomeGrouping: String, CaseIterable, Codable {
    case workspace, device, none
    init(wire: String?) { self = HomeGrouping(rawValue: wire ?? "") ?? .workspace }
}

enum PresenceDot { case working, reconnecting, live, idle }   // priority order

// ── Chat ────────────────────────────────────────────────────────────────────
enum ChatScreenState { case noPeer, ready(ChatReady), fatal(String) }
// no `.connecting` case is rendered as a full screen — see §8.1

enum ComposerMode { case sendAudio, sendText, cancel }
enum VoiceState { case idle, recording(elapsed: Duration, level: Double),
                       transcribing, unavailable(VoiceUnavailableReason) }
enum AttachmentState { case empty, picking, attached(PickedImage) }
// visionSupported is Bool? on all three: nil == unknown, do NOT gate.

// ── Codable strategy ────────────────────────────────────────────────────────
// * Use explicit CodingKeys with snake_case literals. DO NOT rely on
//   .convertFromSnakeCase globally: `ask.answers[*].customText` and
//   `optionNotes` are camelCase INSIDE a snake_case envelope (§8.13).
// * Encode with a custom container that omits keys rather than writing null:
//   `encodeIfPresent` everywhere, and never `encode(Optional.none)`.
// * Decode base64 permissively (standard OR url-safe, pad defensively);
//   encode strictly as standard (§13.1).
// * Decode `working` with `decodeIfPresent(Bool.self) ?? false`.
// * Distinguish key presence for `name` explicitly:
//   `container.contains(.name)` -> Patch.set(try decodeIfPresent(...))
//                       else    -> Patch.unchanged
```

---

## 15. What could not be determined from the code

1. **The `.md` copy for "New Context".** Plan 61 mandates the rename
   (`plan/61-stable-session-identity.md:63-65`) but no Flutter string was
   changed. I specified the plan's copy for iOS (§13.4); if product wants the
   old wording, that is a decision, not a code question.
2. **Whether `session_start` / `session_stop` have any UI.** Both wire messages
   exist (`protocol.dart:994-1032`) and the pi-extension implements them, but
   `IMachineControlRepository` exposes only `listWorkspaces` and `createSession`
   (`machine_control_repository.dart:23-42`) and no screen calls start/stop.
   The `desired: running | stopped` state on the machine
   (`PROTOCOL.md` §Estado desejado) is therefore unreachable from the phone
   today. A native client could surface it, but there is no existing UI to copy.
3. **`session_list` is never called by the app.** The message exists; the
   repository does not expose it. Home's list comes entirely from
   `room_announced` / `rooms` — meaning a **stopped** session on a machine is
   invisible to the phone, since it has no relay room. Whether the New Session
   sheet or Home should show catalogued-but-stopped sessions is an open product
   question.
4. **Multiple machines in the New Session sheet.** `machinesAcceptingSessions`
   can only ever return the single connected peer
   (`home_viewmodel.dart:343-351`), so the sheet's machine-picker branch
   (`new_session_sheet.dart:177-190`) is effectively dead code today. Either
   the transport gains multi-machine addressing or the picker should be removed.
5. **`ChatConnecting` is unreachable.** `_compose` never returns it
   (`chat_viewmodel.dart:283-312`), yet `chat_page.dart:379-382` renders it.
   I documented the rendering for completeness but would not build the state.
6. **`ToolRequestCard.onDecide`.** Plumbed end-to-end (`approve_tool` exists on
   the wire, `protocol.dart:674-691`) but never invoked, because the Pi
   auto-approves before emitting `tool_request` (`tool_request_card.dart:6-17`).
   Whether the Pi will ever pause for approval is a pi-extension roadmap
   question I cannot answer from this repo.
7. **Restoring an open `ask_user` modal after app termination.** Nothing
   persists `pendingUiRequest`. Whether pi-ask re-emits on reconnect could not
   be determined from the app side.
8. **Exact `AppFontScale` values and `relayUrlValidationMessage` rules** live in
   `app/lib/ui/core/themes/app_font_scale.dart` and
   `app/lib/data/transport/relay_config.dart`; I did not enumerate them here.
   Read those two files before building the Settings and Onboarding-step-2
   validation.
