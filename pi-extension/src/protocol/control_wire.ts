/**
 * Plan 61 Phase 3 — the App↔machine-gateway control protocol.
 *
 * A SEPARATE wire from the local UDS `ControlRequest` (`daemon/control_protocol.ts`),
 * on purpose. That one is same-user trust: no auth, no validation worth the
 * name, and it takes an arbitrary `cwd` that gets spawned with `--approve`.
 * Tunnelling it over the relay would hand anyone who reaches the socket
 * user-level RCE (plan 61 D5 / the daemon audit's §2). Nothing here can name a
 * path: every action addresses an ALREADY-REGISTERED workspace by id.
 *
 * Frames ride inside the existing encrypted App↔Pi envelope, addressed to the
 * gateway's reserved room (`ctrl`), and are answered with the same
 * `action_ok` / `action_error` shapes the chat actions already use.
 */

/** Room id the machine gateway holds. Reserved: never a `roomIdFor(...)` output
 *  (those are 12-char base64url digests) and never a session UUID, so it cannot
 *  collide with a chat room. */
export const CONTROL_ROOM_ID = "ctrl";

/** `room_meta.role` value that tells the app "this is not a chat". */
export const CONTROL_ROOM_ROLE = "control";

export type ControlActionName =
  | "workspace_list"
  | "session_list"
  | "create_session"
  | "session_start"
  | "session_stop"
  | "session_rename";

/** Actions that mutate machine state and therefore REQUIRE an idempotency key. */
const MUTATING: ReadonlySet<ControlActionName> = new Set([
  "create_session",
  "session_start",
  "session_stop",
]);

export type ControlAction =
  | { type: "workspace_list"; id: string }
  | { type: "session_list"; id: string; workspace_id?: string }
  | {
      type: "create_session";
      id: string;
      idempotency_key: string;
      workspace_id: string;
      display_name?: string;
      background?: boolean;
    }
  | { type: "session_start"; id: string; session_id: string; idempotency_key: string }
  | { type: "session_stop"; id: string; session_id: string; idempotency_key: string }
  | {
      type: "session_rename";
      id: string;
      session_id: string;
      display_name: string;
      rev?: number;
    };

export class ControlParseError extends Error {}

function str(v: unknown, field: string): string {
  if (typeof v !== "string" || !v.trim()) {
    throw new ControlParseError(`${field} must be a non-empty string`);
  }
  return v.trim();
}

/**
 * Validate an inbound control frame.
 *
 * Strict by design — this is the only remote-reachable surface that can spawn
 * processes, so an under-specified frame is rejected rather than defaulted.
 * In particular a mutating action with no `idempotency_key` is refused: without
 * one, a phone retrying over a flaky link would spawn a second process, which
 * is exactly the failure the key exists to prevent.
 *
 * Returns `null` for an unknown `type` so the caller can ignore forward-compat
 * frames instead of erroring on them.
 */
export function parseControlAction(raw: unknown): ControlAction | null {
  if (!raw || typeof raw !== "object") throw new ControlParseError("frame must be an object");
  const o = raw as Record<string, unknown>;
  const type = o["type"];
  if (typeof type !== "string") throw new ControlParseError("type must be a string");
  if (!isControlActionName(type)) return null;

  const id = str(o["id"], "id");
  if (MUTATING.has(type)) str(o["idempotency_key"], "idempotency_key");

  switch (type) {
    case "workspace_list":
      return { type, id };
    case "session_list": {
      const ws = o["workspace_id"];
      return typeof ws === "string" && ws.trim()
        ? { type, id, workspace_id: ws.trim() }
        : { type, id };
    }
    case "create_session": {
      const action: ControlAction = {
        type,
        id,
        idempotency_key: str(o["idempotency_key"], "idempotency_key"),
        workspace_id: str(o["workspace_id"], "workspace_id"),
      };
      const name = o["display_name"];
      if (typeof name === "string" && name.trim()) action.display_name = name.trim();
      // v1 only spawns background sessions; an explicit `background: false`
      // is refused rather than silently ignored, so a client asking for an
      // interactive remote session learns it is not supported.
      if (o["background"] !== undefined) {
        if (o["background"] !== true) {
          throw new ControlParseError("only background sessions can be created remotely");
        }
        action.background = true;
      }
      return action;
    }
    case "session_start":
    case "session_stop":
      return {
        type,
        id,
        session_id: str(o["session_id"], "session_id"),
        idempotency_key: str(o["idempotency_key"], "idempotency_key"),
      };
    case "session_rename": {
      const action: ControlAction = {
        type,
        id,
        session_id: str(o["session_id"], "session_id"),
        display_name: str(o["display_name"], "display_name"),
      };
      const rev = o["rev"];
      if (typeof rev === "number" && Number.isFinite(rev)) action.rev = rev;
      return action;
    }
  }
}

export function isControlActionName(v: string): v is ControlActionName {
  return (
    v === "workspace_list"
    || v === "session_list"
    || v === "create_session"
    || v === "session_start"
    || v === "session_stop"
    || v === "session_rename"
  );
}

/** Reply shapes. Mirror the chat actions so the app reuses its demultiplexer. */
export type ControlReplyFrame =
  | { type: "action_ok"; in_reply_to: string; action: ControlActionName; [k: string]: unknown }
  | { type: "action_error"; in_reply_to: string; action: ControlActionName; error: string };

export function actionOk(
  inReplyTo: string,
  action: ControlActionName,
  data: Record<string, unknown> = {},
): ControlReplyFrame {
  return { type: "action_ok", in_reply_to: inReplyTo, action, ...data };
}

export function actionError(
  inReplyTo: string,
  action: ControlActionName,
  error: string,
): ControlReplyFrame {
  return { type: "action_error", in_reply_to: inReplyTo, action, error };
}
