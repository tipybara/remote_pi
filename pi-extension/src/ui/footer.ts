/** Footer renderer for Relay/mobile status and terminal title. */
export interface FooterContext {
  ui: {
    setStatus(key: string, value: string | undefined): void;
    setTitle(title: string): void;
  };
}

export interface FooterState {
  relayOn?: boolean;
  /** Active device session right now (drives the 📱 slot).
   *  Independent from `hasPairings` — a device may be paired globally
   *  in peers.json without being actively connected to THIS Pi process. */
  devicePaired?: string;
  /** At least one device has been paired with this machine before
   *  (peers.json is non-empty). Drives the 🟢/🟡 icon on the relay slot:
   *  🟢 when true (ready — devices can connect), 🟡 when false (first
   *  pairing needed). Pairing is per-machine (global), not per-process. */
  hasPairings?: boolean;
  /** Pi session display name used as title prefix. */
  agentName?: string;
}

// Clear legacy status keys left by older mesh-capable builds.
const K_NAME = "remote-pi:agent-name";
const K_SESSION = "remote-pi:session";
const K_RELAY = "remote-pi:relay";
const K_PEER = "remote-pi:peer-active";

export function updateFooter(ctx: FooterContext, state: FooterState): void {
  const agentName = state.agentName?.trim();
  // Editor border owns session name and Relay state.
  ctx.ui.setStatus(K_NAME, undefined);
  ctx.ui.setStatus(K_SESSION, undefined);
  ctx.ui.setStatus(K_RELAY, undefined);

  if (state.devicePaired) {
    ctx.ui.setStatus(K_PEER, `📱 ${state.devicePaired}`);
  } else {
    ctx.ui.setStatus(K_PEER, undefined);
  }

  // Terminal title: `<Pi session name> · <On|Off>`.
  const prefix = agentName || "Pi";
  const relayState = state.relayOn ? "On" : "Off";
  ctx.ui.setTitle(`${prefix} · ${relayState}`);
}
