/**
 * capture-gateway.mts — runs the REAL `pi-extension` machine gateway.
 *
 * Driven by `capture-wire.mjs`. It exists so the control-plane fixtures under
 * `wire/` are the bytes `pi-extension/src/daemon/gateway.ts` actually writes,
 * not a paraphrase of them: the gateway's own `dispatch()` builds every
 * `action_ok` payload out of `daemon/sessions.ts` values, and the harness in
 * `scripts/fake-pi.mjs` deliberately answers `session_list` with a SIMPLER
 * shape (`status`, `name_rev`) than the real machine does (`mode`, `desired`,
 * `running`, `created_at`). Pinning the Swift decoder against the harness
 * would therefore pin the wrong contract.
 *
 * Nothing under `pi-extension/src/**` is modified. Two seams the production
 * code already exposes are used instead:
 *
 *   - `GatewayOptions.host` — the supervisor interface. Stubbed, because
 *     spawning real Pi daemons is not protocol.
 *   - `HOME` / `REMOTE_PI_HOME` — every catalogue path resolves through them,
 *     so the capture runs against a throwaway home and never reads or writes
 *     the operator's `~/.pi/remote/`.
 *
 * The relay connection is REAL: `Gateway.start()` builds its own `RelayClient`
 * from `REMOTE_PI_RELAY`, which the orchestrator points at the logging proxy.
 * So the `hello` this process sends is the production `hello`.
 *
 * Usage (the orchestrator sets all of these):
 *   HOME=<tmp> REMOTE_PI_HOME=<tmp> REMOTE_PI_RELAY=http://127.0.0.1:<proxy> \
 *   CAPTURE_WORKSPACE=<dir> tsx capture-gateway.mts
 *
 * Prints `GATEWAY_READY <json>` on stdout once the control room is open.
 */

import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const PI_EXT = process.env["CAPTURE_PI_EXT"];
if (!PI_EXT) throw new Error("CAPTURE_PI_EXT (path to pi-extension) is required");

const { addDaemon } = await import(`${PI_EXT}/src/daemon/registry.js`);
const { listWorkspaces, createSession } = await import(`${PI_EXT}/src/daemon/sessions.js`);
const { Gateway } = await import(`${PI_EXT}/src/daemon/gateway.js`);

// ── A workspace to talk about ───────────────────────────────────────────────
// `workspace_list` reports registered daemon folders, so register one. This is
// the same call `/remote-pi create <folder>` makes.
const workspaceDir = process.env["CAPTURE_WORKSPACE"];
if (!workspaceDir) throw new Error("CAPTURE_WORKSPACE is required");
mkdirSync(workspaceDir, { recursive: true });
addDaemon(workspaceDir);
const workspaces = listWorkspaces();

// One pre-existing catalogue entry, so `session_list` has something to report
// that was NOT created over the wire during this capture.
const seeded = createSession({
  workspaceId: workspaces[0].workspace_id,
  displayName: "seeded-session",
  mode: "background",
  now: 1_780_000_000_000,
});

// ── Supervisor stub ─────────────────────────────────────────────────────────
const running = new Set<string>();
const host = {
  startWorkspace: async (workspaceId: string, _sessionId: string) => {
    running.add(workspaceId);
  },
  stopWorkspace: async (workspaceId: string) => {
    running.delete(workspaceId);
  },
  isWorkspaceRunning: (workspaceId: string) => running.has(workspaceId),
};
running.add(workspaces[0].workspace_id);

const gateway = new Gateway({
  host,
  // The membership poller would hit a real `/mesh/<hash>` endpoint on a timer
  // and is orthogonal to the wire shapes being captured.
  selfRevoke: false,
  log: {
    info: (m: string) => console.error(`[gateway] ${m}`),
    warn: (m: string) => console.error(`[gateway] ${m}`),
  },
});

await gateway.start();

console.log(
  `GATEWAY_READY ${JSON.stringify({
    workspace: workspaces[0],
    seeded_session_id: seeded.session_id,
  })}`,
);

// Keep the process alive until the orchestrator kills it; a clean SIGTERM
// closes the relay socket, which is what produces `room_ended` on the app side.
process.on("SIGTERM", () => {
  void gateway.stop().then(() => process.exit(0));
});
setInterval(() => {}, 1 << 30);

// Written last so the orchestrator can poll for it as a readiness marker even
// if stdout is buffered.
writeFileSync(join(process.env["REMOTE_PI_HOME"]!, "gateway.ready"), "ok");
