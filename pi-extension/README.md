# remote-pi (local fork)

Local customizations on upstream [`remote-pi`](https://github.com/jacobaraujo7/remote_pi) **0.7.0**.

Historical upstream docs: [`original_readme.md`](./original_readme.md). Current patch inventory: [`CUSTOM_PATCHES.md`](./CUSTOM_PATCHES.md).

## Current behavior

### Mobile Relay only

Pi extension connects each Pi process to its own Relay room. **Room ID is the Pi session id** (plan 61 Phase 1) — it used to be derived from cwd plus the session display name, which meant renaming re-keyed the room. Pairing, connected Owner channels, mobile commands, room metadata, signed Owner membership/self-revoke, and reconnect remain supported.

Local agent mesh is not part of this fork: no UDS broker, leader/follower election, peer roster, agent-to-agent tools, Claude mesh command, agent-network skill, or cross-PC broker bridge.

### Startup

- `/remote-pi` starts Relay directly after first-run setup.
- `auto_start_relay` gates automatic startup from `session_start` only.
- `/remote-pi stop` disconnects this process's Relay.
- Session rename is metadata only (plan 61 Phase 1): it publishes a `room_meta_update` patch carrying the new name plus a monotonic `name_rev`. It no longer restarts Relay — that used to be required because the room ID was derived from the name, and it cost the app its tile and its history on every rename.

### Daemon and supervisor

Daemon registry, supervisor singleton behavior, service install/uninstall, cron dispatch, and supervisor IPC remain unchanged. Signed mobile membership storage remains under existing Remote Pi user storage.

Plan 61 Phase 3 adds a **machine control plane**: the supervisor holds one permanent Relay room (`room_id = "ctrl"`, `room_meta.role = "control"`) on the same Pi-key as its children, so the phone can list workspaces and create/start/stop background sessions on a machine with no interactive Pi open. Only already-registered workspaces are reachable — no path ever travels on the wire — every mutating action requires an idempotency key, and the gateway runs Owner self-revoke itself. State lives in `~/.pi/remote/workspaces.json` and `~/.pi/remote/sessions.json`; `sessions.json` also persists the desired running state, so a session the operator stopped is no longer resurrected by a supervisor restart.

### Editor status

Extension publishes `Symbol.for("pi.remote-pi.relay-status")` and requests editor redraw. Footer retains active mobile-device status. `/remote-pi status` reports Relay/mobile state only.

## Develop

```bash
pnpm install
pnpm test
pnpm typecheck
rm -rf dist && pnpm build
```
