# Audit — supervisor / background session control plane (2026-08-24)

Read-only audit of `pi-extension/src/daemon/**` and session IPC.

**Conclusion:** a local fleet control plane already exists (`pi-supervisord`) but it only lives on a local UDS. Phone → Relay → pick machine/workspace → create a background session **has no entry**. Today 1 daemon = 1 cwd = 1 `pi --mode rpc` = 1 App↔Pi room. `session/ipc.ts` is only a UDS/named-pipe address helper, not a session protocol.

Implement from [plan/61-stable-session-identity.md](../plan/61-stable-session-identity.md) Phase 3. Do not start this before Phase 1 freezes `room_id`.

---

## 1. What exists

| Action | Exists? | Scope |
|---|---|---|
| enumerate workspace | no | no FS catalog |
| enumerate Pi session | no | no JSONL / session id |
| enumerate daemon | yes | `list` / `status` ← `daemons.json` |
| spawn | yes | `register` + `start`; 1 cwd 1 process |
| stop | yes | SIGTERM; **not persisted** as desired state |
| resume | half | `--continue` last JSONL only; no session id |

- list = registry + runtime, not workspace/session (`supervisor.ts:304-318`, ops `267-296`)
- register takes `cwd` only; `realpath` must exist; rejects duplicates (`registry.ts:88-110`)
- id = `sha256(realpath(cwd))[:8]` hex, **no name axis** (`id.ts:35-45`)
- spawn: `pi --mode rpc --approve --continue --name <agent> -e ext` with `REMOTE_PI_DAEMON=1` + `REMOTE_PI_DIRECT_CONFIG` (`rpc_child.ts:168-196,261-280`, `supervisor.ts:564-590`)
- stop is in-memory; supervisor restart `_spawnAllFromRegistry` starts **everything** (`171-176`)
- `session_new` ≠ new process: ack → exit **42** → next spawn omits `--continue` (`index.ts:3959-3973`, `rpc_child.ts:410-412`, `supervisor.ts:602-606`)

---

## 2. IPC / security

Three layers, not connected:

1. **CLI ↔ supervisor:** `~/.pi/remote/supervisor.sock`, 1 JSON line / 1 connection / close. No auth, no TLS, no Owner (`control_protocol.ts:1-11`, `client.ts:14-20,47-66`). `parseRequest` barely validates fields.
2. **supervisor ↔ child:** Pi RPC stdin JSONL. `send` is fire-and-forget (`rpc_child.ts:349-363`).
3. **App ↔ Pi:** one Relay WS per process, room = `roomIdFor(cwd,name)` (`rooms.ts:39-50`, `index.ts:2673-2718`). Relay key `(pubkey, room_id)`.

Local UDS = same-user trust. **Shipping that JSON over Relay = arbitrary cwd + `--approve` = user-level RCE.**

Pairing / `peers.json` is machine-level. Self-revoke currently runs in **Pi children**, not the supervisor. A gateway that does not poll membership stays spawnable after revoke.

---

## 3. Who should be the machine gateway

**`pi-supervisord`.** Already a singleton, launchd/systemd, fleet owner (`supervisor.ts:35-46`, `bin/supervisord.ts`). This fork has no local mesh (`README.md` product boundary). Plan 26 also said “no cross-machine”.

Do **not** use “whichever interactive Pi is open”. `session_new` / crash / exit kills the door.

---

## 4. Avoid “need a Pi before you can create a Pi”

Current discovery: Pi hello → Relay `room_announced` → App `subscribe_rooms` (plan 17). **No child = no room = phone cannot spawn.**

**Recommended:** supervisor itself holds **one** machine control WS (`room_id` reserved, e.g. `ctrl`, **never** `roomIdFor`). Same machine Ed25519. Phone talks to control → list/start → child announces its own session room. Chat stays 1 WS / Pi. Control stays 1 WS / machine.

Alternatives:

- **A** home daemon doubles as control: fewer files, door dies on `session_new`.
- **B** Relay HTTP control: Relay cannot spawn; extra trust surface.
- **C** MVP: only start/stop **already registered** daemons. New workspace still requires local `create`. No “create before entry”, but zero protocol debt.

Plan 61 Phase 3 = recommended + C as the first slice (registered workspaces only).

---

## 5. Persistence today

| Item | Today |
|---|---|
| cwd / name | `~/.pi/remote/daemons.json` (`registry.ts:30-32`) |
| daemon id | derived, not stored |
| Pi session id | **not stored**; `--continue` = latest JSONL (`rpc_child.ts:168-181`) |
| logs | child stderr → supervisor stderr; cron has `cron.jsonl` |
| desired running | **none**; stop is lost across supervisor restart |
| lifecycle | crash backoff 4 then `crashed`; exit 42 respawns immediately |

Need for Phase 3: `workspaces.json` + `sessions.json` with `session_id`, `workspace_id`, `display_name`, `mode`, desired state.

---

## 6. Must add

Modules:

- `daemon/gateway.ts` — supervisor attaches to Relay + SelfRevoke
- `protocol/control_wire.ts` — **do not** reuse `user_message`
- optional `workspace_allowlist.ts`

Protocol: `workspace_list` / `session_list` / `create_session` / `session_start` / `session_stop` / `session_rename`. Map `session_new` to “fresh context / exit 42”, never to create. `room_meta.role=control` so App skips the tile.

Auth:

- inner frames only from Owner ∈ `peers.json`
- gateway **must** run SelfRevoke
- cwd ∈ registry / allowlist
- no path traversal
- **v1 no remote `register` of arbitrary paths**

Tests:

- control connects
- unpaired / revoked rejected
- start → child `room_announced`
- stop does not kill control WS
- `ctrl` does not collide with `roomIdFor`
- gateway identity is the **same** Pi-key as children (do not mint a second key; systemd vs desktop keyring already self-revokes and wipes `peers.json`)
- supervisor restart restores control room

---

## 7. Compatibility risks

- Control room announced as a normal room → fake session tile.
- `pair_ok.room_id` is the **pairing Pi session** (`index.ts:1896-1908`). Machine pairing should complete on the control room; old “pair interactive Pi then promote” can remain.
- Self-revoke not on gateway → spawn backdoor.
- Same `(pubkey, room_id)` as a child → `RoomAlreadyOpenError`.
- Remote `session_new` destroys the `--continue` session. It is not a second concurrent session.
- Second background session in the same cwd: **registry forbids it**. Concurrent sessions need a new id axis (Phase 4).
- `--approve` (`rpc_child.ts:183-196`) + remote register = high severity.

---

## Landing order

1. Do **not** expose UDS `ControlRequest` on Relay.
2. Phase 1 freeze `room_id = session_id` first.
3. Then C: remote start/stop of registered daemons via `ctrl`.
4. Then `create_session` for registered workspaces.
5. Only later: remote add-workspace / same-cwd multi-session.
