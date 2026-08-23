# tipybara/remote_pi

Customized fork of [`jacobaraujo7/remote_pi`](https://github.com/jacobaraujo7/remote_pi) focused on Remote Pi mobile control for individual Pi sessions.

Complete upstream documentation: [`original_readme.md`](./original_readme.md). Extension-specific historical docs and current patch notes: [`pi-extension/original_readme.md`](./pi-extension/original_readme.md), [`pi-extension/CUSTOM_PATCHES.md`](./pi-extension/CUSTOM_PATCHES.md).

## Product boundary

Kept:

- Mobile App ↔ relay ↔ individual Pi room transport.
- QR pairing, Owner channels, durable mobile membership, and signed Owner self-revoke.
- Room metadata for session name, cwd, model, thinking level, and working state.
- Relay reconnect, session rename/restart, editor relay status, daemon control, and supervisor IPC.

Removed from Pi extension:

- Local/cross-PC agent mesh, UDS broker election, peer roster, and broker bridge.
- Agent-to-agent tools and Claude mesh launcher.
- Agent-network skill deployment and Pi-envelope production.

`/remote-pi` starts Relay directly. `auto_start_relay` controls session-start automation only; it never disables manual startup.

```bash
pi install git:github.com/tipybara/remote_pi
```

Root package loads `pi-extension/src/index.ts`; Pi core/TUI remain peer dependencies.

## Development

```bash
cd pi-extension
pnpm install
pnpm test
pnpm typecheck
rm -rf dist && pnpm build
```
