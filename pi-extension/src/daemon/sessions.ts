import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { randomUUID } from "node:crypto";
import { daemonIdForCwd } from "./id.js";
import { listDaemons } from "./registry.js";
import { defaultAgentName } from "../session/local_config.js";

/**
 * Plan 61 Phase 3 — the machine's session catalogue.
 *
 * Deliberately lives on the MACHINE, not the relay (plan 61 D7): the relay's
 * SQLite stays membership-only. The Pi is the only party that knows which
 * sessions exist, which are supposed to be running, and which spawn requests it
 * has already served.
 *
 * Two files under `~/.pi/remote/`:
 *   workspaces.json — display-name overrides for registered folders
 *   sessions.json   — the session catalogue + desired state + idempotency ledger
 *
 * ── Why `workspace_id` is the daemon id, not a fresh UUID ──────────────────
 *
 * Plan 61 sketched `workspace_id = UUID registered on that machine`. In v1 a
 * workspace IS a registered daemon folder ("no remote register of arbitrary
 * paths"), and that already has a stable machine-local id: `daemonIdForCwd`,
 * `sha256(realpath(cwd))[:8]`. Minting a parallel UUID for the same thing would
 * mean a second id space plus a mapping to keep in sync, and every existing
 * `daemon start/stop` path already speaks the derived id. So the workspace id IS
 * the daemon id. `workspaces.json` therefore stores no ids of its own — only the
 * editable label, keyed by that derived id.
 */

function remoteHome(): string {
  const root = process.env["REMOTE_PI_HOME"] || homedir();
  return join(root, ".pi", "remote");
}

function workspacesPath(): string {
  return join(remoteHome(), "workspaces.json");
}

function sessionsPath(): string {
  return join(remoteHome(), "sessions.json");
}

/** How long a served idempotency key is remembered. The plan asks for ≥24h. */
export const IDEMPOTENCY_TTL_MS = 24 * 60 * 60 * 1000;

export interface WorkspaceView {
  /** `daemonIdForCwd(path)` — stable per machine, derived, never persisted. */
  workspace_id: string;
  /** Canonical `realpath` of the folder. */
  path: string;
  /** Editable label; defaults to the folder name. */
  display_name: string;
}

export type SessionMode = "interactive" | "background";
export type DesiredState = "running" | "stopped";

export interface SessionEntry {
  session_id: string;
  workspace_id: string;
  display_name: string;
  mode: SessionMode;
  /**
   * What the OPERATOR wants, independent of what is running right now.
   *
   * The audit's gap: `stop` was in-memory only, so a supervisor restart
   * `_spawnAllFromRegistry`'d everything back up and a session the user
   * deliberately stopped came back from the dead. Persisting intent is what
   * makes stop survive a reboot.
   */
  desired: DesiredState;
  created_at: number;
}

interface IdempotencyRecord {
  /** Session this key produced, when it succeeded. */
  session_id?: string;
  /** Error text, when it failed. Replaying a failed key re-reports the error
   *  rather than silently retrying — the caller decides whether to use a new
   *  key. */
  error?: string;
  at: number;
}

interface SessionsFile {
  sessions: SessionEntry[];
  idempotency: Record<string, IdempotencyRecord>;
}

function readJson<T>(path: string, fallback: T): T {
  if (!existsSync(path)) return fallback;
  try {
    const parsed = JSON.parse(readFileSync(path, "utf8")) as unknown;
    if (!parsed || typeof parsed !== "object") return fallback;
    return parsed as T;
  } catch {
    // A truncated/corrupt file must not brick the gateway. Losing the
    // catalogue degrades to "no known sessions", which the next
    // create_session repopulates; throwing would take the machine offline.
    return fallback;
  }
}

function writeJson(path: string, value: unknown): void {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, JSON.stringify(value, null, 2) + "\n");
}

// ── workspaces ──────────────────────────────────────────────────────────────

function loadWorkspaceLabels(): Record<string, string> {
  const raw = readJson<{ labels?: Record<string, unknown> }>(workspacesPath(), {});
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(raw.labels ?? {})) {
    if (typeof v === "string" && v.trim()) out[k] = v.trim();
  }
  return out;
}

/**
 * Every workspace the phone may target. v1 = exactly the registered daemon
 * folders; there is no remote "register an arbitrary path" (that would be
 * user-level RCE with `--approve`, per the audit).
 */
export function listWorkspaces(): WorkspaceView[] {
  const labels = loadWorkspaceLabels();
  return listDaemons().map((d) => ({
    workspace_id: d.id,
    path: d.cwd,
    display_name: labels[d.id] ?? d.name ?? defaultAgentName(d.cwd),
  }));
}

export function findWorkspace(workspaceId: string): WorkspaceView | undefined {
  return listWorkspaces().find((w) => w.workspace_id === workspaceId);
}

/** Rename a workspace (label only — the path is identity). */
export function setWorkspaceLabel(workspaceId: string, label: string): void {
  const labels = loadWorkspaceLabels();
  labels[workspaceId] = label;
  writeJson(workspacesPath(), { labels });
}

// ── sessions ────────────────────────────────────────────────────────────────

function loadSessionsFile(): SessionsFile {
  const raw = readJson<Partial<SessionsFile>>(sessionsPath(), {});
  const sessions: SessionEntry[] = [];
  for (const item of Array.isArray(raw.sessions) ? raw.sessions : []) {
    if (!item || typeof item !== "object") continue;
    const e = item as Partial<SessionEntry>;
    if (typeof e.session_id !== "string" || !e.session_id) continue;
    if (typeof e.workspace_id !== "string" || !e.workspace_id) continue;
    sessions.push({
      session_id: e.session_id,
      workspace_id: e.workspace_id,
      display_name: typeof e.display_name === "string" ? e.display_name : e.session_id,
      mode: e.mode === "interactive" ? "interactive" : "background",
      desired: e.desired === "stopped" ? "stopped" : "running",
      created_at: typeof e.created_at === "number" ? e.created_at : 0,
    });
  }
  const idempotency: Record<string, IdempotencyRecord> = {};
  for (const [k, v] of Object.entries(raw.idempotency ?? {})) {
    if (!v || typeof v !== "object") continue;
    const rec = v as Partial<IdempotencyRecord>;
    if (typeof rec.at !== "number") continue;
    const out: IdempotencyRecord = { at: rec.at };
    if (typeof rec.session_id === "string") out.session_id = rec.session_id;
    if (typeof rec.error === "string") out.error = rec.error;
    idempotency[k] = out;
  }
  return { sessions, idempotency };
}

function saveSessionsFile(file: SessionsFile, now: number): void {
  // Prune expired idempotency records on every write — cheap, and it keeps the
  // file from growing without bound on a long-lived machine.
  const kept: Record<string, IdempotencyRecord> = {};
  for (const [k, v] of Object.entries(file.idempotency)) {
    if (now - v.at < IDEMPOTENCY_TTL_MS) kept[k] = v;
  }
  writeJson(sessionsPath(), { sessions: file.sessions, idempotency: kept });
}

export function listSessions(workspaceId?: string): SessionEntry[] {
  const all = loadSessionsFile().sessions;
  return workspaceId ? all.filter((s) => s.workspace_id === workspaceId) : all;
}

export function findSession(sessionId: string): SessionEntry | undefined {
  return loadSessionsFile().sessions.find((s) => s.session_id === sessionId);
}

/**
 * Look up a previously-served idempotency key.
 *
 * `undefined` = never seen (or expired) → the caller must do the work.
 * A record = this exact request was already served; replay its outcome instead
 * of spawning a second process. This is what makes a phone retrying over a
 * flaky link safe.
 */
export function lookupIdempotency(
  key: string,
  now: number,
): IdempotencyRecord | undefined {
  const rec = loadSessionsFile().idempotency[key];
  if (!rec) return undefined;
  if (now - rec.at >= IDEMPOTENCY_TTL_MS) return undefined;
  return rec;
}

export function recordIdempotency(
  key: string,
  outcome: { session_id?: string; error?: string },
  now: number,
): void {
  const file = loadSessionsFile();
  const rec: IdempotencyRecord = { at: now };
  if (outcome.session_id !== undefined) rec.session_id = outcome.session_id;
  if (outcome.error !== undefined) rec.error = outcome.error;
  file.idempotency[key] = rec;
  saveSessionsFile(file, now);
}

/**
 * Create a catalogue entry for a new background session.
 *
 * The id is minted HERE rather than taken from the Pi, because the phone needs
 * an id to wait on before any process exists. The child adopts it via
 * `REMOTE_PI_SESSION_ID` so `room_id == session_id` still holds end-to-end.
 */
export function createSession(input: {
  workspaceId: string;
  displayName?: string;
  mode?: SessionMode;
  now: number;
}): SessionEntry {
  const file = loadSessionsFile();
  const ws = findWorkspace(input.workspaceId);
  const entry: SessionEntry = {
    session_id: randomUUID(),
    workspace_id: input.workspaceId,
    display_name:
      input.displayName?.trim()
      || ws?.display_name
      || input.workspaceId,
    mode: input.mode ?? "background",
    desired: "running",
    created_at: input.now,
  };
  file.sessions.push(entry);
  saveSessionsFile(file, input.now);
  return entry;
}

/** Set the operator's intent for a session. Returns the updated entry. */
export function setDesiredState(
  sessionId: string,
  desired: DesiredState,
  now: number,
): SessionEntry | undefined {
  const file = loadSessionsFile();
  const entry = file.sessions.find((s) => s.session_id === sessionId);
  if (!entry) return undefined;
  entry.desired = desired;
  saveSessionsFile(file, now);
  return entry;
}

/** Rename a session in the catalogue (label only). */
export function setSessionLabel(
  sessionId: string,
  displayName: string,
  now: number,
): SessionEntry | undefined {
  const file = loadSessionsFile();
  const entry = file.sessions.find((s) => s.session_id === sessionId);
  if (!entry) return undefined;
  entry.display_name = displayName;
  saveSessionsFile(file, now);
  return entry;
}

/** Test/diag-only paths. */
export const _paths = { workspacesPath, sessionsPath };
