# remote-pi (local fork)

Local customizations on top of upstream
[`jacobaraujo7/remote_pi`](https://github.com/jacobaraujo7/remote_pi)
`pi-extension` (`remote-pi`).

**Full upstream docs:** [`original_readme.md`](./original_readme.md)

Upstream homepage: <https://remote-pi.jacobmoura.work>

---

## What this fork keeps

Intentional deltas vs stock `remote-pi`. Re-apply after pulling upstream.

### 1. Footer: agent name first

Pi footer status keys sort alphabetically. This fork sets:

| key | content |
| --- | --- |
| `remote-pi:agent-name` | mesh/agent name (leftmost) |
| `remote-pi:session` | `📡 local (N)` |
| `remote-pi:relay` | relay chip |
| `remote-pi:peer-active` | paired mobile device |

So the local mesh name stays visible first in the TUI footer.

### 2. Right-aligned online peers widget

`ctx.ui.setWidget("remote-pi:peers-online", …)` draws a right-aligned chip
above the editor:

```text
                                        🟢 online: alpha · beta
```

Built from broker `list_peers` (excludes self). Cleared when idle / no peers.

### 3. Local mesh with relay auto-start off

`.pi/remote-pi/config.json`:

```json
{
  "agent_name": "ad_hoc",
  "auto_start_relay": false
}
```

`/remote-pi` (and session auto-init) **always joins the local UDS mesh**.
Only the **relay** is gated by `auto_start_relay`. Agents still talk over the
local mesh when the phone relay is disabled.

### 4. Reload / session-replacement safety

After `/reload`, `newSession`, fork, or switch, async relay paths must not call
into a dead `ExtensionAPI` or a stale command ctx.

Guards in this fork (on top of upstream lifecycle generations):

- **`_liveCtx` / `_lastEventCtx`** — prefer session_start ctx over captured
  command ctx (upstream issue #55).
- **`_safePiSendMessage`** — reads live module `_pi` each call; no-ops when
  disposed/unbound; try/catches dead runtime throws.
- **`_emitRelayState`** — uses `_safePiSendMessage` only (never a factory-
  captured `pi`).
- **`session_shutdown`** — sets `_disposed`, bumps generations, **nulls `_pi`**,
  clears captured ctxs, then tears down mesh/relay.
- **`session_start`** — rebinds `_pi` on module-reuse hosts after shutdown.

Result: late relay close / `_emitRelayState` after `/reload` cannot crash pi
with `Extension runtime not initialized` or stale-ctx getter throws.

---

## Develop

```bash
cd pi-extension
pnpm install
pnpm test
pnpm typecheck
pnpm build
```

Link into pi (example):

```bash
# from a pi agent npm prefix, or point extensions at dist/
pnpm build
```

---

## Upstream

- Repo: https://github.com/jacobaraujo7/remote_pi
- Package path: `pi-extension/`
- Protocol: [`../PROTOCOL.md`](../PROTOCOL.md)
- Stock README: [`original_readme.md`](./original_readme.md)

Do **not** drop newer upstream behavior when replaying these patches.
Prefer merge/rebase onto latest `upstream/main`, then re-check the four items
above.
