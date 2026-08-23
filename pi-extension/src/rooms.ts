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
