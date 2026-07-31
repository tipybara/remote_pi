# remote-pi (local fork)

Local customizations on top of upstream [`remote-pi`](https://github.com/jacobaraujo7/remote_pi) **0.7.0**.

Full upstream docs: [`original_readme.md`](./original_readme.md). Patch inventory: [`CUSTOM_PATCHES.md`](./CUSTOM_PATCHES.md).

## Custom behavior

### Git-package wrapper

Repository root contains Pi package metadata and loads `pi-extension/src/index.ts` directly.

### Local mesh without relay auto-start

`auto_start_relay: false` disables phone relay startup, not local UDS mesh join. Local agents still communicate.

### Reload-safe ExtensionAPI use

- `_safePiSendMessage` reads current module `_pi`, catches dead-runtime calls, and no-ops while disposed.
- `session_shutdown` clears `_pi` before async teardown.
- `session_start` rebinds `_pi` for module-reuse hosts.
- Mesh drain checks lifecycle ownership before every delivery.

### Local editor-border status

Extension publishes `Symbol.for("pi.remote-pi.relay-status")` and requests editor redraw. Local editor UI owns session-name/relay/peer presentation, so redundant remote-pi footer/widget mesh chips stay cleared. Active mobile-device footer status remains.

## Develop

```bash
pnpm install
pnpm test
pnpm typecheck
pnpm build
```
