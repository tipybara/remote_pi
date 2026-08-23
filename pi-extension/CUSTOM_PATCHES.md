# Local remote-pi patches

Upstream base: `jacobaraujo7/remote_pi` → `pi-extension` (`remote-pi@0.7.0`).

## Current patches

1. **Git-package wrapper** — root `package.json`
   - Loads `pi-extension/src/index.ts` from `git:github.com/tipybara/remote_pi`.

2. **Mobile Relay product boundary** — `src/index.ts`
   - Keeps App ↔ Relay ↔ individual Pi room behavior, pairing, Owner channels, reconnect, and room metadata.
   - Removes local UDS broker/election, cross-PC broker bridge, peer roster, mesh commands, agent tools, Claude launcher, and skill deployment.
   - `/remote-pi` starts Relay directly; `auto_start_relay` gates automatic startup only.

3. **Pi session name is authoritative** — `src/index.ts`
   - Relay room metadata, pair responses, and QR payloads use `pi.getSessionName()`.
   - Room ID remains derived per process from cwd + Pi session display name.
   - Session rename cycles Relay so room identity follows name without restarting Pi process.

4. **Signed mobile ownership preserved** — `src/mesh/self_revoke.ts`, `src/pairing/storage.ts`
   - Signed Owner membership polling and exact self-revoke storage removal remain active.
   - Durable mobile membership storage is unchanged.

5. **Reload-safe Relay lifecycle** — `src/index.ts`
   - Safe ExtensionAPI rebinding, shutdown teardown, stale-candidate rejection, reconnect backoff, and replacement startup remain covered.

6. **Daemon/supervisor control preserved** — `src/daemon/`, `src/session/ipc.ts`
   - Supervisor singleton/service control, daemon registry, RPC child, cron, and control IPC remain unchanged.

7. **Relay/mobile editor status** — `src/index.ts`, `src/ui/footer.ts`
   - Publishes `Symbol.for("pi.remote-pi.relay-status")` and requests editor redraw.
   - Status output has no mesh/peer line; active mobile-device footer slot remains.

## Validation

```bash
pnpm test
pnpm typecheck
rm -rf dist && pnpm build
```

Also verify removed surface with targeted `rg` checks for `MeshNode`, agent tool names, mesh commands, UDS broker code, and Pi-envelope production under `pi-extension/src` and built `dist`.
