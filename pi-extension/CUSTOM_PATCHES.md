# Local remote-pi patches

Upstream base: `jacobaraujo7/remote_pi` → `pi-extension` (`remote-pi@0.6.x`).

Replay these after upgrading upstream. Keep newer upstream fixes.

## Patches

1. **Footer agent name first** — `src/ui/footer.ts`
   - Status key `remote-pi:agent-name` written first (alpha sort → leftmost).

2. **Online peers widget** — `src/ui/peers_widget.ts` + `src/index.ts`
   - Right-aligned `setWidget("remote-pi:peers-online")` from broker peer list.

3. **Mesh with `auto_start_relay: false`** — already upstream in `_cmdRoot`
   - Local mesh always joins; only relay is gated. Do not regress.

4. **Stale ExtensionAPI / reload** — `src/index.ts`
   - `_safePiSendMessage`, `_pi = null` on `session_shutdown`, rebind on
     `session_start`, `_emitRelayState` via safe send only.

## Tests

- `src/ui/footer.test.ts` — agent-name slot
- `src/ui/peers_widget.test.ts` — label / right-align / name parse
- `src/extension.test.ts` — stale `sendMessage`, shutdown drops `_pi`, footer widget wiring

## Docs

- Stock upstream README copied to `original_readme.md`
- This package `README.md` describes fork-only behavior
