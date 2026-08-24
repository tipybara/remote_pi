import { mkdtempSync, mkdirSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, test } from "vitest";
import { canonicalWorkspacePath, isSessionRoomId, roomIdForCwd, roomIdFor, roomIdForSession } from "./rooms.js";
import { defaultAgentName } from "./session/local_config.js";

describe("roomIdForCwd", () => {
  test("deterministic for the same cwd", () => {
    const a = roomIdForCwd("/tmp/some/path/that/may/not/exist");
    const b = roomIdForCwd("/tmp/some/path/that/may/not/exist");
    expect(a).toBe(b);
  });

  test("different cwds produce different ids", () => {
    const a = roomIdForCwd("/tmp/path/a");
    const b = roomIdForCwd("/tmp/path/b");
    expect(a).not.toBe(b);
  });

  test("id is 12-char base64url (safe in URLs / log lines)", () => {
    const id = roomIdForCwd("/tmp/path/c");
    expect(id).toMatch(/^[A-Za-z0-9_-]{12}$/);
  });

  test("realpath: symlinks resolve to the same id", () => {
    // Real fs setup: dir + symlink → dir. Both must produce identical ids.
    const tmp = mkdtempSync(join(tmpdir(), "remote-pi-rooms-"));
    const real = join(tmp, "real");
    mkdirSync(real);
    writeFileSync(join(real, "marker"), "x");
    const link = join(tmp, "link");
    symlinkSync(real, link);

    expect(roomIdForCwd(real)).toBe(roomIdForCwd(link));
  });

  test("non-existent cwd falls back to raw-path hash (no throw)", () => {
    const id = roomIdForCwd("/no/such/path/anywhere/xyz");
    expect(id).toMatch(/^[A-Za-z0-9_-]{12}$/);
  });
});

describe("roomIdFor (plan/41 — App↔Pi room per (cwd, name))", () => {
  const cwd = "/tmp/proj/backend";              // basename → default name "backend"
  const dflt = defaultAgentName(cwd);           // "backend"

  test("INVARIANT: default/absent name preserves the LEGACY cwd-only id (no re-keying)", () => {
    expect(roomIdFor(cwd)).toBe(roomIdForCwd(cwd));         // absent name
    expect(roomIdFor(cwd, dflt)).toBe(roomIdForCwd(cwd));   // name == defaultAgentName(cwd)
  });

  test("a custom agent_name produces a DISTINCT id (name-scoped)", () => {
    expect(roomIdFor(cwd, "reviewer")).not.toBe(roomIdForCwd(cwd));
    expect(roomIdFor(cwd, "reviewer")).toMatch(/^[A-Za-z0-9_-]{12}$/);
  });

  test("two different names in the SAME folder → distinct ids", () => {
    expect(roomIdFor(cwd, "alice")).not.toBe(roomIdFor(cwd, "bob"));
  });

  test("`folder` (default → legacy) vs `folder#2` (scoped) → distinct", () => {
    // The disambiguation for two UNNAMED agents: 1st keeps the legacy room,
    // 2nd gets a name-scoped room under the broker's #2 suffix.
    expect(roomIdFor(cwd, dflt)).toBe(roomIdForCwd(cwd));          // 1st = legacy
    expect(roomIdFor(cwd, `${dflt}#2`)).not.toBe(roomIdForCwd(cwd)); // 2nd = scoped
    expect(roomIdFor(cwd, dflt)).not.toBe(roomIdFor(cwd, `${dflt}#2`));
  });

  test("realpath: a symlinked cwd yields the SAME name-scoped id as the real dir", () => {
    const tmp = mkdtempSync(join(tmpdir(), "remote-pi-rooms41-"));
    const real = join(tmp, "real");
    mkdirSync(real);
    writeFileSync(join(real, "marker"), "x");
    const link = join(tmp, "link");
    symlinkSync(real, link);
    // Custom name (≠ either basename) → both take the scoped branch, which
    // canonicalizes via realpath → identical id despite different basenames.
    expect(roomIdFor(real, "reviewer")).toBe(roomIdFor(link, "reviewer"));
  });

  test("scoped id is 12-char base64url", () => {
    expect(roomIdFor(cwd, "reviewer")).toMatch(/^[A-Za-z0-9_-]{12}$/);
  });
});

describe("roomIdForSession (plan 61 Phase 1 — room_id == session_id)", () => {
  const cwd = "/tmp/proj/backend";
  const sessionId = "019ffb64-7c21-7a3f-9d2e-4b1c8a0f6e5d";

  test("a usable session id IS the room id — verbatim, no hashing", () => {
    expect(roomIdForSession(sessionId, cwd, "anything")).toBe(sessionId);
  });

  test("INVARIANT: renaming cannot change the room id", () => {
    // The whole point of Phase 1. Under roomIdFor(cwd, name) these differ.
    expect(roomIdForSession(sessionId, cwd, "before")).toBe(
      roomIdForSession(sessionId, cwd, "after"),
    );
    expect(roomIdFor(cwd, "before")).not.toBe(roomIdFor(cwd, "after"));
  });

  test("two sessions in the SAME folder get distinct rooms without needing /name", () => {
    expect(roomIdForSession("019ffb64-aaaa-7a3f-9d2e-4b1c8a0f6e5d", cwd)).not.toBe(
      roomIdForSession("019ffb64-bbbb-7a3f-9d2e-4b1c8a0f6e5d", cwd),
    );
  });

  test("falls back to the legacy (cwd, name) id when no session id is available", () => {
    // The one-release alias: an already-paired app keeps talking to the id it
    // knows instead of the room silently moving under it.
    expect(roomIdForSession(undefined, cwd, "reviewer")).toBe(roomIdFor(cwd, "reviewer"));
    expect(roomIdForSession(null, cwd)).toBe(roomIdForCwd(cwd));
    expect(roomIdForSession("   ", cwd)).toBe(roomIdForCwd(cwd));
  });

  test("rejects ids that would corrupt a Hive box filename or a log line", () => {
    // These end up in `msgs_<epk>__<roomId>` on the app. Silently sanitising
    // would split one session's history across two boxes, so we fall back to
    // the legacy id instead.
    for (const bad of ["../escape", "has space", "has/slash", "sh:rt", "x".repeat(65), "short"]) {
      expect(roomIdForSession(bad, cwd)).toBe(roomIdForCwd(cwd));
    }
  });

  test("isSessionRoomId reports whether the room really is session-keyed", () => {
    expect(isSessionRoomId(roomIdForSession(sessionId, cwd), sessionId)).toBe(true);
    // Legacy fallback: the room id is a digest, not the session id.
    expect(isSessionRoomId(roomIdForSession(undefined, cwd), sessionId)).toBe(false);
    expect(isSessionRoomId("anything", undefined)).toBe(false);
  });
});

describe("canonicalWorkspacePath (plan 61 Phase 1)", () => {
  test("resolves symlinks so Phase 2 groups both paths under ONE workspace", () => {
    const tmp = mkdtempSync(join(tmpdir(), "remote-pi-ws-"));
    const real = join(tmp, "real");
    mkdirSync(real);
    const link = join(tmp, "link");
    symlinkSync(real, link);

    expect(canonicalWorkspacePath(link)).toBe(canonicalWorkspacePath(real));
    // And it agrees with what the legacy room id hashes.
    expect(roomIdForCwd(link)).toBe(roomIdForCwd(canonicalWorkspacePath(link)));
  });

  test("a non-existent cwd falls back to the raw path (no throw)", () => {
    expect(canonicalWorkspacePath("/no/such/path/anywhere/xyz")).toBe("/no/such/path/anywhere/xyz");
  });
});
