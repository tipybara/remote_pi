import { mkdtempSync, readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { afterEach, beforeEach, describe, expect, test } from "vitest";
import { addDaemon } from "./registry.js";
import {
  IDEMPOTENCY_TTL_MS,
  _paths,
  createSession,
  findSession,
  findWorkspace,
  listSessions,
  listWorkspaces,
  lookupIdempotency,
  recordIdempotency,
  setDesiredState,
  setSessionLabel,
  setWorkspaceLabel,
} from "./sessions.js";

let home: string;
const saved = process.env["REMOTE_PI_HOME"];

beforeEach(() => {
  home = mkdtempSync(join(tmpdir(), "pi-sessions-"));
  process.env["REMOTE_PI_HOME"] = home;
});

afterEach(() => {
  if (saved === undefined) delete process.env["REMOTE_PI_HOME"];
  else process.env["REMOTE_PI_HOME"] = saved;
});

/** Register a real directory as a daemon (workspaces derive from the registry). */
function registerWorkspace(name: string): { id: string; cwd: string } {
  const dir = mkdtempSync(join(tmpdir(), `ws-${name}-`));
  const { id, cwd } = addDaemon(dir);
  return { id, cwd };
}

describe("workspaces — plan 61 Phase 3", () => {
  test("workspaces ARE the registered daemon folders; nothing else is reachable", () => {
    expect(listWorkspaces()).toEqual([]);
    const a = registerWorkspace("a");
    const list = listWorkspaces();
    expect(list).toHaveLength(1);
    expect(list[0]!.workspace_id).toBe(a.id);
    expect(list[0]!.path).toBe(a.cwd);
    // An arbitrary path is simply not in the catalogue — there is no remote
    // "register this path" (that would be user-level RCE with `--approve`).
    expect(findWorkspace("not-a-real-id")).toBeUndefined();
  });

  test("the label is editable; the path stays identity", () => {
    const a = registerWorkspace("b");
    setWorkspaceLabel(a.id, "Backend API");
    const ws = findWorkspace(a.id)!;
    expect(ws.display_name).toBe("Backend API");
    expect(ws.workspace_id).toBe(a.id);
    expect(ws.path).toBe(a.cwd);
  });
});

describe("session catalogue — plan 61 Phase 3", () => {
  test("a created session is background, desired-running, and uniquely identified", () => {
    const ws = registerWorkspace("c");
    const s1 = createSession({ workspaceId: ws.id, now: 1_000 });
    const s2 = createSession({ workspaceId: ws.id, now: 2_000 });

    expect(s1.mode).toBe("background");
    expect(s1.desired).toBe("running");
    expect(s1.created_at).toBe(1_000);
    expect(s1.session_id).not.toBe(s2.session_id);
    expect(listSessions(ws.id).map((s) => s.session_id)).toEqual([
      s1.session_id,
      s2.session_id,
    ]);
  });

  test("the id is minted BEFORE any process exists — that is what the phone waits on", () => {
    const ws = registerWorkspace("d");
    const s = createSession({ workspaceId: ws.id, now: 1 });
    // Survives a reload: it is on disk, not in memory.
    expect(findSession(s.session_id)?.session_id).toBe(s.session_id);
  });

  test("desired state persists — a stopped session must not come back on restart", () => {
    // The daemon audit's "desired running: none" gap: `stop` was in-memory, so
    // a supervisor restart re-spawned everything.
    const ws = registerWorkspace("e");
    const s = createSession({ workspaceId: ws.id, now: 1 });
    setDesiredState(s.session_id, "stopped", 2);
    expect(findSession(s.session_id)?.desired).toBe("stopped");
    setDesiredState(s.session_id, "running", 3);
    expect(findSession(s.session_id)?.desired).toBe("running");
    expect(setDesiredState("nope", "stopped", 4)).toBeUndefined();
  });

  test("renaming a session touches only the label", () => {
    const ws = registerWorkspace("f");
    const s = createSession({ workspaceId: ws.id, now: 1 });
    const renamed = setSessionLabel(s.session_id, "Nightly build", 2)!;
    expect(renamed.display_name).toBe("Nightly build");
    expect(renamed.session_id).toBe(s.session_id);
    expect(renamed.workspace_id).toBe(s.workspace_id);
  });

  test("a corrupt catalogue degrades to empty instead of bricking the gateway", () => {
    const p = _paths.sessionsPath();
    mkdirSync(dirname(p), { recursive: true });
    writeFileSync(p, "{ not json");
    expect(listSessions()).toEqual([]);
  });
});

describe("idempotency ledger — plan 61 Phase 3", () => {
  test("an unseen key is undefined; a recorded one replays its outcome", () => {
    expect(lookupIdempotency("k1", 1_000)).toBeUndefined();
    recordIdempotency("k1", { session_id: "s-1" }, 1_000);
    expect(lookupIdempotency("k1", 1_000)?.session_id).toBe("s-1");
  });

  test("a FAILED key replays the error — a retry loop cannot become a spawn loop", () => {
    recordIdempotency("k2", { error: "unknown workspace" }, 1_000);
    expect(lookupIdempotency("k2", 1_000)?.error).toBe("unknown workspace");
  });

  test("records expire after the 24h TTL", () => {
    recordIdempotency("k3", { session_id: "s" }, 0);
    expect(lookupIdempotency("k3", IDEMPOTENCY_TTL_MS - 1)).toBeDefined();
    expect(lookupIdempotency("k3", IDEMPOTENCY_TTL_MS)).toBeUndefined();
  });

  test("expired records are pruned from disk on the next write", () => {
    recordIdempotency("old", { session_id: "s" }, 0);
    recordIdempotency("new", { session_id: "s" }, IDEMPOTENCY_TTL_MS + 1);
    const raw = JSON.parse(readFileSync(_paths.sessionsPath(), "utf8")) as {
      idempotency: Record<string, unknown>;
    };
    expect(Object.keys(raw.idempotency)).toEqual(["new"]);
  });
});
