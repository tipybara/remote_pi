import { getOrCreateEd25519Keypair, listPeers, conditionalRemovePeer, snapshotOwnerPubkeys } from "../pairing/storage.js";
import { resolveRelayUrl, toWebSocketUrl } from "../config.js";
import { RelayClient } from "../transport/relay_client.js";
import { MeshClient } from "../mesh/client.js";
import { SelfRevoke } from "../mesh/self_revoke.js";
import { canonicalWorkspacePath } from "../rooms.js";
import {
  CONTROL_ROOM_ID,
  CONTROL_ROOM_ROLE,
  ControlParseError,
  actionError,
  actionOk,
  parseControlAction,
  type ControlAction,
  type ControlReplyFrame,
} from "../protocol/control_wire.js";
import {
  createSession,
  findSession,
  findWorkspace,
  listSessions,
  listWorkspaces,
  lookupIdempotency,
  recordIdempotency,
  setDesiredState,
  setSessionLabel,
} from "./sessions.js";

/**
 * Plan 61 Phase 3 — the machine's control plane on the relay.
 *
 * The problem it solves: discovery ran Pi → `room_announced` → app, so **no
 * child meant no room meant the phone could not ask for one**. You needed a Pi
 * open to create a Pi. The supervisor is the natural gateway — it is already a
 * singleton, already launchd/systemd-managed, and already owns the fleet — so
 * it holds ONE permanent relay room (`ctrl`) whether or not any chat process is
 * up.
 *
 * Three rules this file exists to enforce (all from the daemon audit):
 *
 *  1. **Same key as the children.** The gateway authenticates with the machine's
 *     existing Pi-key. Minting a second identity is what made the desktop
 *     keyring and the systemd unit disagree and wipe `peers.json` on self-revoke.
 *  2. **Owner-only.** Every frame must come from a peer in `peers.json`, and the
 *     gateway runs SelfRevoke itself. A gateway that does not poll membership
 *     stays spawnable after the user revokes the pairing — a spawn backdoor.
 *  3. **No paths on the wire.** Actions address registered workspaces by id.
 *     The local UDS protocol takes an arbitrary `cwd` and spawns it with
 *     `--approve`; exposing that remotely is user-level RCE.
 */

/** What the gateway needs from the supervisor. Narrow on purpose: the gateway
 *  never reaches into child bookkeeping, and a test can drive it with a stub. */
export interface GatewayHost {
  /**
   * Start the daemon owning `workspaceId`, adopting `sessionId` as its stable
   * session identity (the child publishes it as `room_id`/`session_id`).
   * Idempotent: already-running is success.
   */
  startWorkspace(workspaceId: string, sessionId: string): Promise<void>;
  /** Stop the daemon owning `workspaceId`. Idempotent. */
  stopWorkspace(workspaceId: string): Promise<void>;
  /** `true` when that workspace's daemon is up right now. */
  isWorkspaceRunning(workspaceId: string): boolean;
}

export interface GatewayLog {
  info(msg: string): void;
  warn(msg: string): void;
}

export interface GatewayOptions {
  host: GatewayHost;
  log?: GatewayLog;
  /** Injected for tests. Defaults to the real relay client. */
  relayFactory?: (url: string, kp: { publicKey: Uint8Array; secretKey: Uint8Array }) => RelayClient;
  /** Injected for tests so time-dependent behaviour is deterministic. */
  now?: () => number;
  /** Disable the membership poller (tests). */
  selfRevoke?: boolean;
}

const noopLog: GatewayLog = { info: () => undefined, warn: () => undefined };

export class Gateway {
  private relay: RelayClient | null = null;
  private selfRevoke: SelfRevoke | null = null;
  private stopped = false;
  private readonly log: GatewayLog;
  private readonly now: () => number;

  /** Owner peer ids allowed to drive this gateway, refreshed from storage. */
  private owners = new Set<string>();

  constructor(private readonly opts: GatewayOptions) {
    this.log = opts.log ?? noopLog;
    this.now = opts.now ?? (() => Date.now());
  }

  async start(): Promise<void> {
    this.stopped = false;
    await this.refreshOwners();

    const kp = await getOrCreateEd25519Keypair();
    const { url } = resolveRelayUrl();
    const relay = this.opts.relayFactory
      ? this.opts.relayFactory(toWebSocketUrl(url), kp)
      : new RelayClient(toWebSocketUrl(url), kp);
    this.relay = relay;

    relay.on("message", (line: string) => void this.onLine(line));

    await relay.connect({
      roomId: CONTROL_ROOM_ID,
      roomMeta: {
        // `role` is what keeps this out of the app's chat list. Without it the
        // gateway would render as a session tile that answers nothing.
        role: CONTROL_ROOM_ROLE,
        name: "machine control",
        cwd: canonicalWorkspacePath(process.cwd()),
        workspace_path: canonicalWorkspacePath(process.cwd()),
      },
    });
    this.log.info(`[gateway] control room open (${CONTROL_ROOM_ID})`);

    if (this.opts.selfRevoke !== false) {
      // Rule 2: a gateway that does not poll membership keeps its spawn
      // capability after the user revokes. Same storage + same pubkey as the
      // chat sessions, so a revoke lands once for the whole machine.
      this.selfRevoke = new SelfRevoke({
        client: new MeshClient(url),
        storage: { snapshotOwnerPubkeys, conditionalRemovePeer },
        myPubkey: kp.publicKey,
        onRevoke: () => { void this.refreshOwners(); },
        onAuthoritativeOwners: () => { void this.refreshOwners(); },
      });
      this.selfRevoke.start();
    }
  }

  async stop(): Promise<void> {
    this.stopped = true;
    this.selfRevoke?.stop();
    this.selfRevoke = null;
    try { this.relay?.close(); } catch { /* best-effort */ }
    this.relay = null;
  }

  /** Re-read the Owner allow-list from storage. */
  async refreshOwners(): Promise<void> {
    try {
      const peers = await listPeers();
      this.owners = new Set(peers.map((p) => p.remote_epk));
    } catch {
      // Storage unreadable → keep the previous set rather than opening up.
    }
  }

  // ── Inbound ───────────────────────────────────────────────────────────────

  private async onLine(line: string): Promise<void> {
    if (this.stopped) return;
    let outer: { peer?: unknown; ct?: unknown };
    try { outer = JSON.parse(line) as typeof outer; } catch { return; }
    const peer = typeof outer.peer === "string" ? outer.peer : "";
    const ct = typeof outer.ct === "string" ? outer.ct : "";
    if (!peer || !ct) return;

    // Rule 2 — Owner-only. Checked BEFORE parsing so an unpaired sender cannot
    // even reach the action decoder.
    if (!this.owners.has(peer)) {
      // Re-read once: a device that paired seconds ago is legitimate and would
      // otherwise be refused until the next revoke poll.
      await this.refreshOwners();
      if (!this.owners.has(peer)) {
        this.log.warn("[gateway] frame from a non-Owner peer, dropping");
        return;
      }
    }

    let inner: unknown;
    try {
      inner = JSON.parse(Buffer.from(ct, "base64").toString("utf8"));
    } catch {
      return;
    }

    let action: ControlAction | null;
    try {
      action = parseControlAction(inner);
    } catch (e) {
      const id = (inner as { id?: unknown } | null)?.id;
      const type = (inner as { type?: unknown } | null)?.type;
      if (typeof id === "string" && typeof type === "string") {
        // Malformed but addressable: answer so the caller is not left waiting
        // for a reply that will never come.
        this.reply(peer, {
          type: "action_error",
          in_reply_to: id,
          action: type as never,
          error: e instanceof ControlParseError ? e.message : String(e),
        });
      }
      return;
    }
    if (!action) return; // unknown type — forward-compat, ignore silently

    const reply = await this.dispatch(action);
    this.reply(peer, reply);
  }

  private reply(peer: string, frame: ControlReplyFrame): void {
    const relay = this.relay;
    if (!relay) return;
    const ct = Buffer.from(JSON.stringify(frame)).toString("base64");
    try {
      // The outer `room` names the DESTINATION's room, not ours.
      //
      // This used to say `room: CONTROL_ROOM_ID`, which addressed
      // `(app, "ctrl")` — a registry key that does not exist, because the app
      // always registers at `main` (`ws_transport.dart` hello). The relay
      // dropped every control reply, answered US with `transport_error:
      // offline`, and `onLine` discarded that. The visible symptom was every
      // control RPC timing out after 45s while the machine looked perfectly
      // online — i.e. the whole control plane was dead end-to-end.
      //
      // Omitting `room` matches `PlainPeerChannel.send` (the chat path, which
      // has always worked) and lets the relay apply its documented default of
      // `main`. Do not "fix" this by naming a room: the app's room is not ours
      // to know, and hardcoding `main` would break the day it registers
      // elsewhere.
      relay.send(JSON.stringify({ peer, ct }));
    } catch {
      // Relay mid-reconnect. The caller retries with the same idempotency key,
      // which replays the recorded outcome instead of re-spawning.
    }
  }

  // ── Dispatch ──────────────────────────────────────────────────────────────

  private async dispatch(action: ControlAction): Promise<ControlReplyFrame> {
    switch (action.type) {
      case "workspace_list":
        return actionOk(action.id, action.type, { workspaces: listWorkspaces() });

      case "session_list": {
        const sessions = listSessions(action.workspace_id).map((s) => ({
          ...s,
          running: this.opts.host.isWorkspaceRunning(s.workspace_id),
        }));
        return actionOk(action.id, action.type, { sessions });
      }

      case "create_session":
        return this.withIdempotency(action.id, action.type, action.idempotency_key, async () => {
          const ws = findWorkspace(action.workspace_id);
          // Rule 3 — the workspace must already be registered locally. There is
          // no remote "register this path".
          if (!ws) throw new Error(`unknown workspace: ${action.workspace_id}`);
          const entry = createSession({
            workspaceId: ws.workspace_id,
            ...(action.display_name !== undefined ? { displayName: action.display_name } : {}),
            mode: "background",
            now: this.now(),
          });
          await this.opts.host.startWorkspace(ws.workspace_id, entry.session_id);
          return {
            session_id: entry.session_id,
            workspace_id: entry.workspace_id,
            display_name: entry.display_name,
            path: ws.path,
          };
        });

      case "session_start":
        return this.withIdempotency(action.id, action.type, action.idempotency_key, async () => {
          const entry = findSession(action.session_id);
          if (!entry) throw new Error(`unknown session: ${action.session_id}`);
          setDesiredState(entry.session_id, "running", this.now());
          await this.opts.host.startWorkspace(entry.workspace_id, entry.session_id);
          return { session_id: entry.session_id, workspace_id: entry.workspace_id };
        });

      case "session_stop":
        return this.withIdempotency(action.id, action.type, action.idempotency_key, async () => {
          const entry = findSession(action.session_id);
          if (!entry) throw new Error(`unknown session: ${action.session_id}`);
          // Persist the intent BEFORE stopping: a supervisor restart in the
          // window between the two must not resurrect a session the operator
          // just stopped (the audit's "desired running: none" gap).
          setDesiredState(entry.session_id, "stopped", this.now());
          await this.opts.host.stopWorkspace(entry.workspace_id);
          return { session_id: entry.session_id, workspace_id: entry.workspace_id };
        });

      case "session_rename": {
        const entry = setSessionLabel(action.session_id, action.display_name, this.now());
        if (!entry) {
          return actionError(action.id, action.type, `unknown session: ${action.session_id}`);
        }
        return actionOk(action.id, action.type, {
          session_id: entry.session_id,
          display_name: entry.display_name,
        });
      }
    }
  }

  /**
   * Run `work` at most once per idempotency key.
   *
   * A phone on a flaky link retries; without this, each retry would spawn
   * another process. A replayed key returns the ORIGINAL outcome — including
   * the original error, so a caller cannot turn a permanent failure into a
   * spawn loop by retrying.
   */
  private async withIdempotency(
    rpcId: string,
    action: ControlAction["type"],
    key: string,
    work: () => Promise<Record<string, unknown>>,
  ): Promise<ControlReplyFrame> {
    const seen = lookupIdempotency(key, this.now());
    if (seen) {
      if (seen.error !== undefined) return actionError(rpcId, action, seen.error);
      return actionOk(rpcId, action, {
        session_id: seen.session_id,
        replayed: true,
      });
    }
    try {
      const data = await work();
      recordIdempotency(
        key,
        typeof data["session_id"] === "string"
          ? { session_id: data["session_id"] }
          : {},
        this.now(),
      );
      return actionOk(rpcId, action, data);
    } catch (e) {
      const error = e instanceof Error ? e.message : String(e);
      recordIdempotency(key, { error }, this.now());
      return actionError(rpcId, action, error);
    }
  }
}
