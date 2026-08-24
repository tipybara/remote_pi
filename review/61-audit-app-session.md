# Audit — Flutter session identity (2026-08-24)

Read-only audit of `app/`. Source: live tree at `tipybara/remote_pi` HEAD `e0d9e95` plus the same files in this clone.

**Conclusion:** there is no single stable Session ID. The protocol key is `(epk, roomId)`, but UI / connection / persistence keep six other pointers. Home sorts by **display name** and has **no widget keys**. Jumps come from `_load` dropping filter, `PeerRecord.roomId` being one-room-per-Mac, boot ignoring `selectedRoomId`, and Pi `/name` changing `room_id`.

Implement from [plan/61-stable-session-identity.md](../plan/61-stable-session-identity.md) Phase 0 first.

---

## 1. Data model

**Protocol primary key:** `(peer_id, room_id)` (`relay/src/peers/registry.rs`).
Pi `room_id` = `sha256(realpath(cwd))[:12]`, or if `/name` is not the default, `sha256(cwd+NUL+name)[:12]` (`pi-extension/src/rooms.ts:13-51`). **Rename = new ID.**

**Local half-key:**

- Hive `rp_v2`:
  - `sessions_index` key `$epk:$roomId` (`app/lib/data/local/boxes.dart:9,71`) — epk **not normalized**
  - msgs `msgs_${toAppEpk(epk)}__$roomId` (`boxes.dart:66`)
  - `runtime` same key, wiped on boot (`boxes.dart:41`)
- `SessionIndexRecord` equality is `epk+roomId` (`session_index_record.dart:27,74-77`)
- Home **does not read** `HomeReadRepository` (only DI). The list is `ConnectionManager._roomsByPeer` + `PeerRecord`

**Parallel pointers (not synchronized):**

| Pointer | File | Meaning |
|---|---|---|
| `prefs.selected_peer_epk` = `epk[:roomId]`, split on first `:` | `preferences.dart:47-62,179-188` | navigation intent |
| `PeerRecord.roomId` **one per Mac** | `pairing/storage.dart:183-189` | connection bind |
| `CM._activeRoomId` + `_activePeer` | `connection_manager.dart:154-155` | WS envelope |
| `SessionSelection` in-memory, not persisted | `routing/adaptive.dart:85-129` | tablet highlight |
| `SyncService._activeEpk/_activeRoomId` | `sync_service.dart:37-38` | writer |
| `ChatVM._activeRoomId` | `chat_viewmodel.dart:42,143-144` | reader |

**Persistence schema:**

- SecureStorage `dev.remotepi.peers:$epk`: `remote_epk, session_name, relay_url, paired_at, nickname, room_id, harness` (`storage.dart:202-211`)
- `dev.remotepi.rooms:$epk`: `[{room_id,name,cwd,started_at,local_name,model}]` (`storage.dart:31-40`)
- Hive index: `display_name,status,last_message_*` (`session_index_record.dart:41-50`)
- Prefs: composite `prefs.selected_peer_epk`

**Name / order used as identity:**

- `HomeList.items` sorts by peer/room **display name** (`home_state.dart:113-141`)
- `SliverList` has no Key (`home_page.dart:273-280`); `SessionTile` has no `ValueKey`
- `listPeers()` unordered (`storage.dart:269-277`) → boot `peers.first` (`app_router.dart:109-115`, `connection_manager.dart:369-374`)
- legacy discovery uses `rooms.first.roomId` (`connection_manager.dart:1047-1050`)
- `HomeItem.==` includes entire `RoomInfo` (name/cwd/startedAt/model/thinking/working) (`home_state.dart:47-50`, `protocol.dart:421-428`)
- Title: `room.name → cwd basename` (`session_tile.dart:151-161`, `home_page.dart:564-575`)

---

## 2. Event flow → jumps

**P0 `_load` resets filter.** `saveRooms` / `savePeer` → `notifyListeners` → `_onStorageChanged` → `_load` emits `HomeList` **without filter**, default `online` (`home_viewmodel.dart:50-52,88-95`). `_onStatus` deliberately preserves filter (`128-138`). `RoomMetaUpdated` / `markRoomWorking` persist every turn (`connection_manager.dart:822-826,1028`) → Online/Offline page is emptied and refilled. Looks like sessions jumping.

**P0 cold start connects the wrong room.** Boot only passes `selectedPeerEpk` (room stripped). Room becomes `peer.roomId ?? 'main'` (`app_router.dart:104-124`, `connection_manager.dart:506-515`). `openSession` writes the whole-machine `PeerRecord.roomId` to the tapped room (`home_viewmodel.dart:180-198`). `setSelectedPeerEpk(epk)` wipes `:room` (revoke / default, `settings_viewmodel.dart:114-117`).

**Reconnect:** `isRoomLive` requires `StatusOnline` (`connection_manager.dart:804-809`) → Online tab empties. `_liveRoomIds` is not cleared on disconnect; first online moment uses the stale live set. Same peer keeps `_activeRoomId`; switching peer uses stale `peer.roomId`.

**Sort / rename:** `setRoomLocalName` writes into `RoomInfo.name` (`connection_manager.dart:967-971`) → `_roomLabel` changes → reorder + index reuses the wrong tile. Pi `/name` changes `room_id` → old grey tile + new tile.

**Selection / chat:** `SessionSelection.matches` does not normalize epk (`adaptive.dart:93-97`); url-safe vs standard drops highlight. Tablet `ValueKey('chat-$epk-$roomId')` (`app_router.dart:387`) rebuilds the whole VM when it changes. `switchTo` no-ops when same epk + Online (`connection_manager.dart:387-390`). Sync drops frames by epk only, not room (`sync_service.dart:416-425,455`). Wrong `activeRoomId` mixes histories (`chat_viewmodel.dart:215-220`).

**`session_new`:** same `roomId`, wipes msgs+index (`sync_service.dart:384,402`). Not a new session.

---

## 3. Risks

1. No `SessionId` SSOT. Name / cwd / order / list index act as identity.
2. One peer, one `roomId` cannot express multiple cwds.
3. Persist → full Home reload + filter reset (high frequency).
4. Hive index detached from Home. Mixed epk encodings can double rows.
5. Device layer = `PeerRecord`. No workspace. cwd is only a subtitle.

---

## 4. Minimal migration (App)

1. Unique key `(toAppEpk(epk), roomId)` until Phase 1 introduces `session_id`. Navigation / Hive / Key / Selection only use that. `localName` / `piName` editable, **not in ID, not in sort-identity**.
2. Delete or demote `PeerRecord.roomId` (lastOpened at most). `boot(preferredEpk, roomId)` reads `prefs.selectedRoomRaw`. Never `setSelectedPeerEpk(bare epk)` again.
3. `_load` must keep `filter`. `saveRooms` should not `notifyListeners` (Home already subscribes to `roomsStream`).
4. `ValueKey('$epk|$roomId')` on tiles and detail. Sort by `lastMessageAt` or stable `roomId`.
5. `matches` / `activate` / `sessionKey` all `toAppEpk`.
6. After Phase 1: `/name` only changes display. Transition: App may treat old/new `roomId` as aliases via `cwd`.

---

## 5. Workspace / device UI touch list

Today: Device = `PeerRecord`, Session = `RoomInfo`, only `PeerSectionHeader` + flat list (`home_page.dart:307-318`, `peer_section_header.dart:5-8`).

Phase 2 must change:

- `home_state.dart` — three levels `(device → workspace=cwd → sessions)`, key still `(epk,roomId)` until `session_id` exists
- `home_page.dart` + new section widgets
- `session_tile.dart` / `chat_page.dart` titles
- `SessionSelection` + `_DetailPane` key
- `PersistedRoom` already has `cwd` as workspace grouping hint
- `connection_manager` still merges by `roomId`
- prefs keep a composite ID until `selected_session_id`

Workspace is **not** a primary key.
