# Local remote-pi patches

Upstream base: `jacobaraujo7/remote_pi` → `pi-extension` (`remote-pi@0.7.0`).

## Patches

1. **Git-package wrapper** — root `package.json`
   - Loads `pi-extension/src/index.ts` from `git:github.com/tipybara/remote_pi`.

2. **Local mesh with `auto_start_relay: false`**
   - Local mesh joins independently; relay startup remains gated.

3. **Reload-safe ExtensionAPI binding** — `src/index.ts`
   - `_safePiSendMessage`, `_pi = null` during shutdown, rebind on session start.
   - Mesh drain validates live lifecycle ownership.

4. **Editor-border relay state** — `src/index.ts`, `src/ui/footer.ts`
   - Publishes `Symbol.for("pi.remote-pi.relay-status")` and requests editor redraw.
   - Clears duplicate agent/session/relay footer slots and peers widget.
   - Retains active mobile-device footer slot.

5. **Pi session name is authoritative** — `src/index.ts`
   - Relay metadata, pair responses, QR payloads, and Cockpit labels use `pi.getSessionName()`.
   - Empty sessions default to `<project>-<8-char-session-id>`; forked sessions receive a fresh default.
   - `/name` changes reopen the Relay room so app-visible names stay exact.
   - Mesh `agent_name` remains an independent routing alias.

## Validation

```bash
pnpm test
pnpm typecheck
pnpm build
```
