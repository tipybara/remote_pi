import { createHash } from "node:crypto";
import { realpathSync } from "node:fs";
import { defaultAgentName } from "./session/local_config.js";

/**
 * Deterministic room id derived from a cwd. Two Pi processes in the same
 * directory produce the same id; different cwds produce different ids
 * (with cryptographic-strength collision resistance). Symlinks are resolved
 * via `realpath` so `/a` and `/symlink-to-a` map to the same room.
 *
 * Format: first 12 chars of base64url(sha256(realpath)).
 */
export function roomIdForCwd(cwd: string): string {
  let target: string;
  try {
    target = realpathSync(cwd);
  } catch {
    // cwd doesn't exist (unlikely in production) — fallback to raw path.
    target = cwd;
  }
  return createHash("sha256").update(target).digest("base64url").slice(0, 12);
}

/**
 * THE single derivation of the App↔Pi `room_id` (plan/41) — keyed by
 * `(cwd, name)` so several agents in the SAME folder get distinct rooms (the
 * app then renders one tile per agent instead of merging them into one).
 *
 * Default-preserving: when `name` is absent OR equals `defaultAgentName(cwd)`,
 * it returns the legacy cwd-only id exactly, so an existing default room is not
 * re-keyed on upgrade. Any other Pi session display name gets a name-scoped id.
 * Two simultaneous processes cannot own the same room id; users distinguish
 * same-folder sessions with `/name`.
 *
 * INVARIANT: every callsite that derives the App↔Pi room for the same agent
 * MUST go through this function — otherwise the app would pair on a room the
 * Pi never announces.
 */
export function roomIdFor(cwd: string, name?: string): string {
  if (!name || name === defaultAgentName(cwd)) return roomIdForCwd(cwd);
  let target: string;
  try {
    target = realpathSync(cwd);
  } catch {
    target = cwd;
  }
  // NUL is impossible in a filesystem path or Pi session name, making the
  // cwd/name boundary unambiguous.
  const sep = String.fromCharCode(0);
  return createHash("sha256").update(target + sep + name).digest("base64url").slice(0, 12);
}

/**
 * Plan 61 Phase 1 — the canonical workspace key: `realpath(cwd)`.
 *
 * The same value `roomIdForCwd` hashes, exposed directly so it can be published
 * as `room_meta.workspace_path`. Phase 2 groups Home by this, so `/a` and
 * `/symlink-to-a` MUST collapse to one workspace exactly like they collapse to
 * one room id. Falls back to the raw path when the directory cannot be resolved
 * (deleted cwd), matching `roomIdForCwd`'s behaviour.
 */
export function canonicalWorkspacePath(cwd: string): string {
  try {
    return realpathSync(cwd);
  } catch {
    return cwd;
  }
}

/**
 * Plan 61 Phase 1 — THE room id from here on: the Pi session UUID itself.
 *
 * `roomIdFor(cwd, name)` made the transport key a function of the DISPLAY
 * NAME, so `/name` re-keyed the room: the relay saw `room_ended` for the old
 * id and `room_announced` for a brand-new one, the app grew a second tile, and
 * the Hive box holding that conversation was orphaned under the dead id. A
 * rename must move no identifiers (plan 61 D1/D2), so the room id has to be
 * something the user cannot edit — the session id already is exactly that.
 *
 * Falls back to the legacy derivation when no usable session id is available.
 * That covers the real cases where `sessionManager` is not reachable yet (a
 * `pair_request` arriving before the first `session_start`, an older SDK), and
 * is the one-release alias the plan asks for: such a Pi keeps announcing the
 * id its already-paired apps know.
 *
 * Accepted shape is deliberately strict. The id ends up in Hive box FILENAMES
 * on the app (`msgs_<epk>__<roomId>`) and in relay log lines, so anything with
 * a path separator, whitespace or exotic unicode is rejected rather than
 * sanitised — a silently mangled id would split one session's history in two.
 * Pi session ids are UUIDs and pass unchanged.
 *
 * ── Uniqueness: PER-MACHINE, not global ────────────────────────────────────
 *
 * A room id only ever has meaning inside one machine, because every layer that
 * keys by it already carries the machine's Pi-key alongside:
 *
 *   relay registry   (peer_id, room_id)          — `relay/src/peers/registry.rs`
 *   app rooms cache  Map<epk, List<RoomInfo>>    — ConnectionManager
 *   app live set     Map<epk, Set<roomId>>       — ConnectionManager
 *   app messages     msgs_<epk>__<roomId>        — LocalBoxes.msgsBoxName
 *   app index        <epk>:<roomId>              — LocalBoxes.sessionKey
 *   app selection    <epk>:<roomId>              — Preferences
 *   app tile keys    <epk>|<roomId>              — HomeItem.sessionKey
 *   app action cache <epk>|<roomId>              — ActionsRepository
 *
 * So two machines emitting the SAME id is harmless: they are different entries
 * everywhere. That is also why this validator does not demand UUID shape — an
 * 8-char id from some other harness is fine as long as it is unique on its own
 * machine — and why prefixing the id with a device id would be redundant: it
 * would embed the machine identity into a value that is already scoped by it,
 * on every frame, while undoing the `room_id == session_id` identity Phase 1
 * exists to establish.
 *
 * The invariant that DOES matter, and that any new cache must respect:
 * **never key persistent state by room id alone.**
 *
 * (For the record, Pi's own ids are UUIDv7 — 48-bit ms timestamp plus 74
 * random bits, so a same-millisecond collision is ~2^-74. The
 * supervisor-minted ones are `crypto.randomUUID()`, 122 random bits. Neither
 * is a number worth designing against.)
 */
export function roomIdForSession(
  sessionId: string | null | undefined,
  cwd: string,
  name?: string,
): string {
  const trimmed = sessionId?.trim();
  if (trimmed && /^[A-Za-z0-9_-]{8,64}$/.test(trimmed)) return trimmed;
  return roomIdFor(cwd, name);
}

/**
 * `true` when `roomId` is a Phase-1 session-derived id rather than a legacy
 * `sha256(cwd[,name])` digest. Used to decide whether a `session_id` field is
 * worth publishing alongside it.
 */
export function isSessionRoomId(roomId: string, sessionId: string | null | undefined): boolean {
  const trimmed = sessionId?.trim();
  return !!trimmed && trimmed === roomId;
}
