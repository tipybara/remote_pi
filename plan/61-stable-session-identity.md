# 61 — Stable session identity + machine control plane

**Status:** Phases 0–4 implemented 2026-08-24. Audits closed 2026-08-24.

| Phase | State | Verification |
|---|---|---|
| 0 — App jump-stop | landed | app: analyze clean, 595 tests (baseline 542) |
| 1 — Freeze identity | landed | extension: 593 tests (baseline 538); relay: 116 (baseline 111), clippy clean |
| 2 — Home hierarchy | landed | app, as above |
| 3 — Machine control plane | landed | extension + app, as above |
| 4 — Hardening + docs | landed | `PROTOCOL.md` rewritten; `pi-extension/README.md` corrected |

Everything below the Phase 0 section records what actually shipped, including
two deliberate deviations (`rp_v3`, `workspace_id`) that are called out where
they occur.
**Product:** mobile App ↔ Relay ↔ Pi only. Local agent mesh stays deleted.
**Clone to work in:** `~/workspace/remote_pi` (this repo).

## Goal

1. Session uniqueness is an ID. Display name is editable and never the storage key.
2. Phone can pick a paired machine + workspace and create a background Pi session.
3. Home groups sessions by device → workspace directory.
4. Stop the “session jumps” class of bugs.

## Evidence

Do not re-audit from scratch. Read these first:

- [review/61-audit-app-session.md](../review/61-audit-app-session.md)
- [review/61-audit-relay-protocol.md](../review/61-audit-relay-protocol.md)
- [review/61-audit-daemon-control.md](../review/61-audit-daemon-control.md)

## Target model

```text
Machine
  machine_id   = Pi-key (already exists, 1 per PC)
  display_name = device nickname

Workspace
  workspace_id = UUID registered on that machine
  path         = canonical realpath(cwd)
  display_name = folder label, editable

Session
  session_id   = Pi session UUID (authoritative)
  room_id      = session_id (transport key; never changes on rename)
  workspace_id
  display_name = editable label
  mode         = interactive | background
  status       = running | idle | crashed | stopped
```

Hard rules:

- Storage, navigation, Hive, widget keys, and selection pointers use `session_id`.
- Rename is metadata only. Never rehash `room_id`. Never restart Relay to rename.
- `cwd` / display name are never primary keys.
- Each paired machine has a resident control plane even when zero chat Pi processes are up.

Rename the current mobile action:

- `session_new` → **New Context** (wipe history in the same process / same `session_id`).
- Phone “new session” → **`create_session`** (supervisor spawns a process, new `session_id`).

## Decisions (closed)

| ID | Decision |
|---|---|
| D1 | `room_id == session_id`. Stop `roomIdFor(cwd, name)` for App↔Pi rooms. |
| D2 | Display name is a patch (`name_rev` monotonic). App must not treat name as identity or sort-identity. |
| D3 | Machine gateway is `pi-supervisord`, not “whatever Pi happens to be open”. |
| D4 | Gateway holds one stable Relay room: `room_id = "ctrl"`, same Pi-key, `meta.role = control`. App must not render it as a chat tile. |
| D5 | Do **not** tunnel UDS `ControlRequest` over Relay. New inner actions only. |
| D6 | v1 `create_session` only targets an already-registered workspace. No arbitrary remote path spawn. |
| D7 | Relay SQLite stays membership-only. Session catalog + idempotency live on the machine. |
| D8 | App must never hash `room_id` itself. Wait for `action_ok` + `room_announced`. |
| D9 | Same-cwd multi-session is **not** Phase 0–1. Current daemon id is cwd-only. |
| D10 | Local mesh / `list_peers` / cross-PC agent tools stay deleted. |

## Out of scope

- Restoring local/cross-PC agent mesh.
- Relay as a session database.
- Phone scanning the whole filesystem.
- Moving Cockpit SSH workspace model into the chat app.
- Publishing the Flutter app (identity plugin license still unresolved).
- One-WebSocket multiplex of all session rooms (keep 1 WS per Pi chat process for now).

## Phases

Implement in order. Do not start Phase 3 before Phase 1 lands: otherwise Home still keys by a name-derived room.

### Phase 0 — App jump-stop (app only) — **LANDED 2026-08-24**

No protocol change. Branch `feat/61-phase0-app-jump-stop`.
`flutter analyze` clean, `flutter test` 567 passing (was 542).

- `_load` must preserve `HomeList.filter` (`app/lib/ui/home/viewmodels/home_viewmodel.dart`).
- `saveRooms` must not `notifyListeners` in a way that rebuilds Home from scratch; Home already listens to `roomsStream`.
- Boot must restore full `epk:roomId` from `Preferences.selectedRoomRaw`. Stop using `peer.roomId ?? 'main'`.
- Demote `PeerRecord.roomId` to last-opened hint, not connection identity.
- `ValueKey('$normalizedEpk|$roomId')` on Home tiles and tablet `_DetailPane`.
- Normalize every lookup with `toAppEpk` / `toStandardB64` consistently (`SessionSelection.matches`, Hive `sessionKey`, prefs).
- Stop sorting Home by display name as identity. Prefer `roomId` or `lastMessageAt`.
- `HomeItem.==` must not include volatile `working` / `startedAt` if that recycles tiles.

**Accept:** switch Online/Offline, send a message, rename locally — selected session does not jump; chat does not reopen the wrong room after cold start.

**What actually shipped** (all eight bullets above, plus what they dragged in):

| Change | File |
|---|---|
| `_load` carries the previous `HomeList.filter` | `ui/home/viewmodels/home_viewmodel.dart` |
| `saveRooms` no longer `notifyListeners` (peer mutations still do) | `pairing/storage.dart` |
| `boot(preferredEpk, preferredRoomId)` restores the full `epk:roomId`; epk match is normalised; peer fallback is `pairedAt`-ordered instead of `peers.first` | `routing/app_router.dart`, `data/transport/connection_manager.dart` |
| Room pointer trio `_activeRoomId` / `_activeRoomOwner` / `_activeRoomPinned` is the connection identity; `_connect` reseeds only on a destination change; discovery re-points only an unpinned + dead pointer | `data/transport/connection_manager.dart` |
| `switchRoom(roomId, {epk})` pins for a machine not yet connected (Home taps before the WS exists) | `data/transport/connection_manager.dart`, callers in Home/Chat |
| `PeerRecord.roomId` documented as a last-opened **hint** | `pairing/storage.dart` |
| `ValueKey(HomeItem.sessionKey)` on rows + peer headers; `ValueKey('chat-${SessionSelection.sessionKey}')` on the tablet detail pane | `ui/home/home_page.dart`, `routing/app_router.dart` |
| `SessionSelection.matches` / `select` normalise the epk; new `sessionKey` getter | `routing/adaptive.dart` |
| `LocalBoxes.sessionKey` normalises with `toAppEpk` (matches `msgsBoxName`) | `data/local/boxes.dart` |
| Ordering by `pairedAt`/`roomId`; `HomeItem.==` is `(epk, roomId)` only | `ui/home/states/home_state.dart` |
| Relay-URL change and revoke fallback keep/clear the room deliberately | `ui/settings/viewmodels/settings_viewmodel.dart` |

Regressions pinned by `test/ui/home/home_session_identity_test.dart`,
`test/data/local/boxes_test.dart`, plus additions to the storage, adaptive and
connection-manager suites.

**Known unrelated flake** (pre-existing, reproduced on the untouched baseline):
`flutter test` occasionally fails one case in `test/data/sync/sync_service_test.dart`
or `test/ui/chat/chat_viewmodel_test.dart` when Hive-using test files run
concurrently. Different case each time; passes in isolation. Worth its own fix.

**Not done here** (deliberately out of Phase 0 scope): `_liveRoomIds` is still
not cleared on disconnect, so the first moment back online reads a stale live
set. Fold into Phase 1.

### Phase 1 — Freeze identity (pi-extension + small protocol) — **LANDED 2026-08-24**

- `room_id = ctx.sessionManager.getSessionId()` (or equivalent stable Pi session UUID).
- `_renameAgent` only `setSessionName` + metadata broadcast. Delete `_goIdle` + `_cmdStart` from the rename path (`pi-extension/src/index.ts`).
- Extend `hello` / `room_announced` / `pair_ok` with `session_id`, `workspace_path`, `display_name`, `name_rev`.
- Relay `room_meta_update` must be able to patch `name` (today only model/thinking/working — `relay/src/rooms.rs`).
- Keep old `roomIdFor(cwd,name)` as a one-release alias if needed so existing tiles can remap once.

**Accept:** `/name` keeps the same chat and the same Hive box. No `room_ended` + new tile.

**What shipped**

| Change | Where |
|---|---|
| `roomIdForSession()` — the room IS the Pi session UUID; strict id validation (it becomes a Hive filename); legacy `roomIdFor(cwd,name)` kept as the one-release alias | `pi-extension/src/rooms.ts` |
| `canonicalWorkspacePath()` — `realpath(cwd)`, published as `workspace_path` | same |
| Session id latched from any ctx carrying a `sessionManager`, cleared on `session_shutdown`, and defensively wrapped (reading a stale ctx *throws*) | `pi-extension/src/index.ts` |
| `_renameAgent` / `_publishSessionDisplayName` are metadata-only — no `_goIdle` + `_cmdStart` | same |
| `name_rev` minted from the wall clock so it keeps rising across restarts | same |
| Rename publishes the **requested** name, not the SDK read-back (a host with no `setSessionName` would otherwise ack a rename that never happened); `changed` is now computed honestly instead of hardcoded `false` | same |
| `hello.room_meta` + `pair_ok` carry `session_id` / `workspace_path` / `display_name` / `name_rev` | `index.ts`, `protocol/types.ts` |
| `RoomMeta` gains `session_id`, `workspace_path`, `name_rev`, `role`; `RoomMetaPatch` gains `name` + `name_rev` with a strictly-greater revision gate; a rejected patch still re-broadcasts the winning name so the stale device resyncs | `relay/src/rooms.rs`, `relay/src/peers/registry.rs`, `relay/src/handlers/peer.rs` |
| App parses the new fields, applies the name patch under the same revision gate, and persists them so a cold start doesn't look legacy | `app/lib/protocol/protocol.dart`, `connection_manager.dart`, `pairing/storage.dart` |
| `_liveRoomIds` cleared on disconnect (the Phase 0 leftover) | `app/lib/data/transport/connection_manager.dart` |

### Phase 2 — Home hierarchy (app) — **LANDED 2026-08-24**

- UI: Device → Workspace (cwd) → Sessions.
- Offline sessions remain under their workspace.
- In-place rename UI (calls `session_rename`, not local-only forever).
- Selection pointer becomes `selected_session_id`.
- Hive `rp_v3` keyed by `session_id`. Messages `msgs_<session_id>`.

**Accept:** two sessions in one folder stay distinct after rename; offline session remains visible.

**What shipped**

| Change | Where |
|---|---|
| `HomeWorkspace` / `HomeDevice` + `HomeList.groups()` — Device → Workspace → Session, grouped from the already-filtered rows so no empty header survives a tab switch; workspaces ordered by path, never by folder label | `app/lib/ui/home/states/home_state.dart` |
| `WorkspaceSectionHeader` + three-level rendering, every row and header keyed | `app/lib/ui/home/widgets/`, `home_page.dart` |
| `session_rename` on the wire — Pi-side handler with session-id targeting and `rev` optimistic concurrency | `pi-extension/src/index.ts`, `protocol/types.ts` |
| `PlainPeerChannel.sendToRoom` / `WsTransport.sendToRoom` — address ONE frame at a room without moving the active target (Home renames a session that is usually not the open chat) | `app/lib/data/transport/` |
| `ActionsRepository.renameSession` + Home rename that reports failure instead of silently staying local | `actions_repository.dart`, `home_viewmodel.dart`, `home_page.dart` |
| `Preferences.selectedSessionId` | `app/lib/data/preferences/preferences.dart` |

**Deviation — no `rp_v3`.** The plan asked for a Hive namespace bump keyed by
`session_id` with `msgs_<session_id>`. Not taken, reasoning recorded in
`app/lib/data/local/boxes.dart`: Phase 1 already made `roomId == session_id`, so
the existing `rp_v2` keys ARE session-keyed with no data movement; a namespace
bump would be a full copy of every message box (a partial copy loses
conversations) for zero change in meaning; and dropping the epk from the key is
unsafe while legacy 12-char digest rooms exist, since the audit flags cross-machine
collision as a real failure mode. `sessionKey` was normalised with `toAppEpk`
instead, which was a genuine bug (one session could own two index rows).

### Phase 3 — Machine control plane — **LANDED 2026-08-24**

- Supervisor opens Relay room `ctrl`.
- Actions (inner `ct`, Owner-paired only, idempotency key required):

```jsonc
{ "type": "workspace_list", "id": "<rpc>" }
{ "type": "session_list", "id": "<rpc>", "workspace_id": "optional" }
{ "type": "create_session", "id": "<rpc>",
  "idempotency_key": "<uuid>",
  "workspace_id": "ws_…",
  "display_name": "optional",
  "background": true }
{ "type": "session_start", "id": "<rpc>", "session_id": "…", "idempotency_key": "…" }
{ "type": "session_stop", "id": "<rpc>", "session_id": "…", "idempotency_key": "…" }
{ "type": "session_rename", "id": "<rpc>", "session_id": "…", "display_name": "…", "rev": 4 }
```

- Persist `~/.pi/remote/workspaces.json` and `~/.pi/remote/sessions.json`.
- Gateway must run Owner self-revoke. Revoked machine must not keep spawn capability.
- v1: only registered workspaces. No remote `register` of arbitrary paths.
- Dest-miss on App↔Pi must return `transport_error: offline` (today App↔Pi drops silently).
- App: pick machine → workspace → New Session → wait `action_ok` + `room_announced` → open that `session_id`.

**Accept:** phone creates a background session on a machine that has no interactive Pi open, after `remote-pi install`. Control room never appears as a chat tile. Retry with same idempotency key does not double-spawn.

**What shipped**

| Change | Where |
|---|---|
| `workspaces.json` / `sessions.json` + idempotency ledger (24h TTL, pruned on write, replays the ORIGINAL error so a retry loop can't become a spawn loop) | `pi-extension/src/daemon/sessions.ts` |
| Control wire, separate from the UDS protocol; no action can name a path; mutating actions refuse a missing `idempotency_key` rather than defaulting one | `pi-extension/src/protocol/control_wire.ts` |
| `Gateway` — `ctrl` room on the machine's existing Pi-key, Owner-only (re-reads the allow-list once before refusing, so a just-paired device works), runs SelfRevoke | `pi-extension/src/daemon/gateway.ts` |
| Supervisor starts/stops the gateway, injects `REMOTE_PI_SESSION_ID`, re-adopts it on crash-restart, and honours persisted `desired` | `pi-extension/src/daemon/supervisor.ts` |
| Relay answers dest-miss on App↔Pi with `transport_error` | `relay/src/handlers/peer.rs` |
| App: control-plane messages, `MachineControlRepository`, `transport_error` handling that greys the tile immediately, control-room exemption in the inbound room demux, New Session sheet | `app/lib/protocol/`, `app/lib/data/control/`, `app/lib/ui/home/widgets/new_session_sheet.dart` |

**Deviation — `workspace_id` is the daemon id, not a fresh UUID.** In v1 a
workspace IS a registered daemon folder, and that already has a stable
machine-local id (`sha256(realpath(cwd))[:8]`) that every existing `daemon
start/stop` path speaks. A parallel UUID would mean a second id space plus a
mapping to keep in sync. Reasoning recorded in `daemon/sessions.ts`.

**Note on the session id.** The machine mints it in the catalogue *before* the
process exists (the phone needs something concrete to wait on) and the child
adopts it via `REMOTE_PI_SESSION_ID`. For a daemon this is also the more stable
of the two ids: the SDK's own session id rolls over whenever `--continue` cannot
resume or `session_new` recycles the process, either of which would re-key the
room — exactly what Phase 1 set out to stop.

### Phase 4 — Hardening + docs — **LANDED 2026-08-24**

- Rewrite `PROTOCOL.md` (delete local-mesh narrative). **Done** — rewritten
  around App ↔ Relay ↔ Pi, with the session-identity model, the control plane,
  the transport-error contract, and an explicit note that the relay still
  carries `pi_envelope` code this fork does not use.
- `pi-extension/README.md` corrected: it still claimed the room id was derived
  from cwd + display name and that rename restarts the Relay.
- Supervisor restart restores control room and desired session running bits.
  **Done** — `_startGateway()` runs in `start()`; `_spawnAllFromRegistry`
  respects `desired`.
- Reconnect does not reset selected session. **Done in Phase 0** — the room
  pointer is pinned and only reseeded when the destination machine changes.
- Optional later: one WS multiplex, remote workspace picker, same-cwd multi-session.

### Still open (deliberately out of scope)

- **Real-device verification.** Everything above is verified by
  `flutter analyze` / `flutter test`, `pnpm typecheck` / `pnpm test`,
  `cargo test` / `cargo clippy`. The plan's accept criteria are behavioural
  (rename keeps the chat; the phone spawns a session on a Mac with no Pi open)
  and need a paired device plus a running relay to confirm end to end.
- **Pre-existing test flake**, reproduced on the untouched baseline: `flutter
  test` intermittently fails one case in `sync_service_test.dart` or
  `chat_viewmodel_test.dart` when Hive-using files run concurrently. Different
  case each run; passes in isolation. Worth its own fix.
- Same-cwd multi-session (D9), remote workspace registration, one-WS multiplex.

## Compatibility

- Old apps still read `room_id` / `name`.
- New apps prefer `session_id`.
- `session_new` wire name can stay; UI copy becomes New Context.
- Pairing stays Owner-key + Pi-key. Control room uses the same pair.
- Do not mint a second Pi-key for the supervisor (desktop keyring vs systemd split already causes self-revoke wipes).

## Suggested agent split

| Agent | Owns | Must not touch |
|---|---|---|
| App | Phase 0, then Phase 2 | pi-extension spawn / Relay schema |
| Extension | Phase 1 rename + `room_id = session_id` | Flutter UI chrome |
| Relay | name patch + dest-miss error | membership SQLite redesign |
| Daemon | Phase 3 control room | UDS protocol exposed on the wire |

Start with **Phase 0 only** unless the user says otherwise.
Phase 0 is done — the next slice is Phase 1 (Extension + small protocol).

## Test bar

- App: Home filter survival, cold-start room restore, tile keys, epk normalization.
- Extension: rename does not change `room_id`; `session_new` still wipes same session.
- Relay: `room_meta_update` name patch; dest-miss error on App↔Pi.
- Daemon: unpaired/revoked rejected; start → child `room_announced`; stop does not kill `ctrl` WS; `ctrl` room id does not collide with `roomIdFor`.
