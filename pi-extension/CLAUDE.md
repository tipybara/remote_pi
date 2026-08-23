# Remote Pi — Pi Extension (Node + TypeScript)

Pi extension for mobile Remote Pi control. Each Pi process owns one App ↔ Relay room derived from cwd + Pi session display name.

## Product boundary

Keep:

- Relay WebSocket lifecycle, QR pairing, Owner channels, mobile commands, room metadata, reconnect.
- Signed Owner membership/self-revoke and existing pairing storage.
- Daemon registry, supervisor/service/cron control, RPC child, and supervisor IPC.

Do not add back:

- Local UDS agent broker, leader/follower election, peer roster/count.
- Agent-to-agent tools, Claude mesh launcher, agent-network skill.
- Cross-PC broker bridge or Pi-envelope production.

Backward-compatible Relay membership endpoints may remain because signed mobile self-revoke consumes them.

## Stack

- Node 20+ / TypeScript 6, ESM NodeNext.
- pnpm only.
- `@napi-rs/keyring` for Pi identity, with existing file fallback policy.
- `ws` for Relay transport.

## Commands

```bash
pnpm install
pnpm test
pnpm typecheck
rm -rf dist && pnpm build
```

## Relay startup

Resolution precedence:

1. `REMOTE_PI_RELAY`
2. `~/.pi/remote/config.json`
3. built-in default

`/remote-pi` starts Relay directly. `auto_start_relay` only gates automatic `session_start` startup. `/remote-pi stop` disconnects current Pi process Relay. Rename must reopen Relay under updated cwd + Pi session display-name room.

## Conventions

- Strict TypeScript; narrow `unknown` rather than adding `any`.
- Relative ESM imports include `.js` suffix.
- Preserve stale-context and lifecycle generation guards across awaits.
- Never alter daemon supervisor singleton semantics when changing extension connection lifecycle.
