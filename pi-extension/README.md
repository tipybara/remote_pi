# remote-pi (local fork)

Local customizations on upstream [`remote-pi`](https://github.com/jacobaraujo7/remote_pi) **0.7.0**.

Historical upstream docs: [`original_readme.md`](./original_readme.md). Current patch inventory: [`CUSTOM_PATCHES.md`](./CUSTOM_PATCHES.md).

## Current behavior

### Mobile Relay only

Pi extension connects each Pi process to its own Relay room. Room ID remains derived from cwd plus Pi session display name. Pairing, connected Owner channels, mobile commands, room metadata, signed Owner membership/self-revoke, and reconnect remain supported.

Local agent mesh is not part of this fork: no UDS broker, leader/follower election, peer roster, agent-to-agent tools, Claude mesh command, agent-network skill, or cross-PC broker bridge.

### Startup

- `/remote-pi` starts Relay directly after first-run setup.
- `auto_start_relay` gates automatic startup from `session_start` only.
- `/remote-pi stop` disconnects this process's Relay.
- Session rename restarts Relay so room ID and metadata follow updated Pi session display name.

### Daemon and supervisor

Daemon registry, supervisor singleton behavior, service install/uninstall, cron dispatch, and supervisor IPC remain unchanged. Signed mobile membership storage remains under existing Remote Pi user storage.

### Editor status

Extension publishes `Symbol.for("pi.remote-pi.relay-status")` and requests editor redraw. Footer retains active mobile-device status. `/remote-pi status` reports Relay/mobile state only.

## Develop

```bash
pnpm install
pnpm test
pnpm typecheck
rm -rf dist && pnpm build
```
