# Audit — Relay / App / Extension wire protocol (2026-08-24)

Read-only audit of Relay, Flutter protocol, and `pi-extension` identity.

**Conclusion:** App↔Pi is a live router, not a directory service. Authoritative IDs live on the endpoints: machine = `Pi-key`, room = `sha256(cwd[,name])[:12]`, Owner = `Owner-key`. Relay persists only `mesh_versions`. Phone `create_session` **cannot** reuse `session_new`. A resident control plane is required. Relay SQLite schema **does not** need to become a session catalog.

Implement from [plan/61-stable-session-identity.md](../plan/61-stable-session-identity.md).

---

## 1. Identifiers: who mints, who is authoritative

| ID | Minted by | Authority | Notes |
|---|---|---|---|
| **Pi-key / peer_id** | Extension first boot, Keychain | that PC's private key | 1 key / PC. Relay `peer_id = B64(vk)` |
| **Owner-key / app peer** | App first boot, Keychain | the person; syncs across phones | App hello **always** `room_id='main'` (`app/lib/data/transport/ws_transport.dart:154-157`). Same Owner, many phones share `(owner_pk, main)` |
| **room_id** | Pi `roomIdFor(cwd,name)` (`pi-extension/src/rooms.ts:38-50`) | **Pi**. Relay treats it as opaque string | default/basename → `sha256(realpath)[:12]`; else `sha256(cwd\\0name)[:12]`. App does **not** derive it |
| **daemon_id** | `daemonIdForCwd` hex8 (`daemon/id.ts:28`) | local supervisor | **cwd only**, no name axis. UDS, not on Relay |
| **session_started_at** | first `_cmdStart` in that process (`index.ts:2733-2738`) | that process clock | stop/start keeps it; `session_new` overwrites. ≠ Relay `started_at` |
| **room.started_at** | Relay register time | none | reconnect after last conn drops changes it |
| **inner msg id** | App UUID | sender | echo / `in_reply_to`; **no transport ACK** |
| **mesh version** | App monotonic + Owner signature | Owner blob | Relay LWW |

`pair_ok.room_id` is the room that happened to be pairing (`index.ts:1894-1903`). `PeerRecord.roomId` is leftover **1 pair → 1 room** (`app/lib/pairing/storage.dart`).

`PROTOCOL.md` is stale: it still describes the deleted local agent mesh. Do not implement from it.

---

## 2. Does Relay persist directories / rooms?

**No.** SQLite is only `mesh_versions` (Owner membership). Rooms / presence / conns are RAM (`relay/src/peers/registry.rs`).

- Register key `(peer_id, room_id)` → N conns (plan 23 already dropped `room_already_open`; client still treats that error as fatal in `relay_client.ts`)
- `room_announced` only on **first** conn; `room_ended` only on **last** conn
- `subscribe_rooms` does **not** snapshot (`peer.rs`); client must `rooms_check`
- dest miss: **silent drop** for App↔Pi (`peer.rs` forward path). `transport_error` exists only for `pi_envelope`
- `room_meta_update` can patch model / thinking / working only. **Cannot** patch name / cwd / room_id (`relay/src/rooms.rs:38-47`)

---

## 3. How the app discovers machines / rooms

1. Local `peers.json` + mesh GET membership (`mesh_sync_service.dart`)
2. One App WS (`room=main`) then `subscribe_presence` + `subscribe_rooms` + `*_check` (`connection_manager.dart:298-311`)
3. Home: peer sections × each peer's `RoomInfo` list. Disk cache = grey tiles on cold start; live comes from announce/snapshot
4. `switchRoom` does not reconnect; it only changes outbound `room` (`connection_manager.dart:238-246`)
5. Chat boxes keyed `(epk, roomId)` (`boxes.dart:68-71`)

There is no “list machine directories / unstarted workspaces”. No process = no room = undeliverable.

---

## 4. Jump / duplicate / lost-update map

| Point | Mechanism | Symptom |
|---|---|---|
| dest has no ACK | App↔Pi drop | optimistic bubble vanishes ~20s; Pi never saw it |
| rename / `/name` | `_renameAgent` closes WS then `roomIdFor` new id (`index.ts:1614-1626`) | old tile `room_ended`, new tile; Hive history orphaned |
| `session_new` ≠ new process | wipe buffer + new `session_started_at`, same room (`index.ts:3959-4133`) | reuse destroys current conversation |
| `session_sync` last-N full replace | `index.ts` | over-limit history lost; reconnect refill |
| `RoomsSnapshot` merge-only | `connection_manager.dart:707-746` | dead rooms stay in cache (grey) |
| `_maybeAdoptLegacyRoom` takes **first** | connection_manager | multi-room race binds wrong `PeerRecord.roomId` |
| `started_at` = Relay now | reconnect changes it | never use as session primary key |
| `working` merge-patch | disconnect while `true` | grey tile can stick busy |
| 12-char truncate | `rooms.ts:21,50` | theoretical collision → crossed rooms |
| same `(peer,room)` N conns | last meta wins | two Pis with same id interleave |
| no hello.version | new fields optional | mixed versions by convention |

Cross-PC mesh ACK (`received/denied/timeout`) does **not** cover App↔Pi.

---

## 5. Proposed machine / workspace / session + `create_session`

Map onto what exists. Do not invent a second peer type.

- `machine_id` = Pi-key (exists)
- `workspace` = `realpath(cwd)` (`room_meta.cwd` exists, not a key)
- `session` = live process. Current `room_id` is a **derived value**, not a UUID

**Required control plane:** supervisor holds a stable room, `room_id="ctrl"`. Otherwise nothing can receive create. Local UDS already has `register/start` (`control_protocol.ts:33-44`). Missing piece is the App-facing door.

Suggested inner actions (existing `ct` + `action_ok/error`, target = `ctrl`):

```jsonc
{ "type": "create_session", "id": "<uuid>",
  "idempotency_key": "<uuid>",
  "cwd": "/abs/path",          // Phase 3: prefer workspace_id
  "name": "optional",
  "resume": "new" | "continue" }

{ "type": "action_ok", "in_reply_to": "<id>", "action": "create_session",
  "room_id": "<id>", "session_id": "<id>", "cwd": "...", "name": "..." }

{ "type": "list_sessions", "id": "..." }
{ "type": "stop_session", "id": "...", "session_id": "...", "idempotency_key": "..." }
```

**Auth:** only a paired Owner. `ctrl` shares the machine Pi-key. Do not let a random chat room spawn processes.

**ACK / idempotency:**

- `id` = RPC; `idempotency_key` = spawn key; supervisor disk `(key → session_id|error)` ≥ 24h
- same key replay → same `action_ok`, no second spawn
- dest miss **must** return `_relay` / `transport_error: offline` (today only mesh has this)
- after success still wait for `room_announced`
- **App must not precompute `room_id`**

**State machine (supervisor):** `idle → starting(key) → announced(session_id) | failed`.
App: `pending(key) → wait announce → switch to session_id`. Timeout keeps pending; reconcile via `list_sessions`.

**Do not use:** `session_new` (wipes current chat), Relay-stored directory, App-side room hash.

---

## 6. Relay schema / versioning

| | |
|---|---|
| **Do not** change Relay SQLite into a directory | catalog + idempotency stay on the Pi supervisor disk |
| **Do not** require a hard hello version | unknown types already drop; old apps ignore new fields |
| **Defer** `hello.protocol_min`; UUID rooms need Hive key migration | Phase 1 can set `room_id = session_id` and alias once |
| **Must change (protocol / both ends, not DB)** | dest-miss error; `ctrl` hello; `create_session` / `list_sessions`; stop treating `RoomAlreadyOpenError` as the only collision story; collapse `PeerRecord.roomId` |

Must: control room + new actions + dest-miss + idempotency + never reuse `session_new`.
Defer: Relay persistence, workspace tree, FS browse, protocol version byte, Home three-level UI (that is App Phase 2).
