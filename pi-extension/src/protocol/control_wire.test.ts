import { describe, expect, test } from "vitest";
import {
  CONTROL_ROOM_ID,
  ControlParseError,
  actionError,
  actionOk,
  parseControlAction,
} from "./control_wire.js";

describe("control_wire — plan 61 Phase 3", () => {
  test("the control room id cannot collide with a chat room", () => {
    // `roomIdFor(...)` emits 12-char base64url digests and Phase-1 rooms are
    // session UUIDs. "ctrl" is neither, so the gateway can never land on the
    // same (pubkey, room) key as one of its own children — which would be a
    // RoomAlreadyOpen rejection at the relay.
    expect(CONTROL_ROOM_ID).toBe("ctrl");
    expect(CONTROL_ROOM_ID).not.toMatch(/^[A-Za-z0-9_-]{12}$/);
    expect(CONTROL_ROOM_ID.length).toBeLessThan(12);
  });

  test("workspace_list / session_list parse", () => {
    expect(parseControlAction({ type: "workspace_list", id: "a" }))
      .toEqual({ type: "workspace_list", id: "a" });
    expect(parseControlAction({ type: "session_list", id: "b" }))
      .toEqual({ type: "session_list", id: "b" });
    expect(parseControlAction({ type: "session_list", id: "b", workspace_id: " w1 " }))
      .toEqual({ type: "session_list", id: "b", workspace_id: "w1" });
  });

  test("an unknown type is ignored, not an error (forward-compat)", () => {
    expect(parseControlAction({ type: "some_future_action", id: "x" })).toBeNull();
  });

  test("a mutating action without an idempotency key is REFUSED", () => {
    // Without the key a phone retrying over a flaky link spawns a second
    // process. Defaulting one server-side would defeat the purpose (each retry
    // would get a fresh default), so the frame is rejected outright.
    for (const frame of [
      { type: "create_session", id: "1", workspace_id: "w" },
      { type: "session_start", id: "1", session_id: "s" },
      { type: "session_stop", id: "1", session_id: "s" },
    ]) {
      expect(() => parseControlAction(frame)).toThrow(ControlParseError);
    }
  });

  test("create_session requires a workspace id — there are no paths on the wire", () => {
    expect(() => parseControlAction({
      type: "create_session", id: "1", idempotency_key: "k",
    })).toThrow(/workspace_id/);
    // And there is no field that could carry one.
    const ok = parseControlAction({
      type: "create_session", id: "1", idempotency_key: "k", workspace_id: "w1",
      cwd: "/etc",
    });
    expect(ok).toEqual({
      type: "create_session", id: "1", idempotency_key: "k", workspace_id: "w1",
    });
    expect(ok).not.toHaveProperty("cwd");
  });

  test("create_session refuses an explicit non-background request", () => {
    // v1 only spawns background sessions. Silently ignoring `background:false`
    // would leave the caller believing it got an interactive one.
    expect(() => parseControlAction({
      type: "create_session", id: "1", idempotency_key: "k",
      workspace_id: "w1", background: false,
    })).toThrow(/background/);
    expect(parseControlAction({
      type: "create_session", id: "1", idempotency_key: "k",
      workspace_id: "w1", background: true,
    })).toMatchObject({ background: true });
  });

  test("blank strings are rejected like missing ones", () => {
    expect(() => parseControlAction({ type: "workspace_list", id: "   " }))
      .toThrow(ControlParseError);
    expect(() => parseControlAction({
      type: "session_start", id: "1", session_id: "", idempotency_key: "k",
    })).toThrow(ControlParseError);
  });

  test("session_rename carries an optional rev", () => {
    expect(parseControlAction({
      type: "session_rename", id: "1", session_id: "s", display_name: " New ",
    })).toEqual({ type: "session_rename", id: "1", session_id: "s", display_name: "New" });
    expect(parseControlAction({
      type: "session_rename", id: "1", session_id: "s", display_name: "N", rev: 4,
    })).toMatchObject({ rev: 4 });
    // A non-finite rev is dropped rather than poisoning the comparison.
    expect(parseControlAction({
      type: "session_rename", id: "1", session_id: "s", display_name: "N", rev: NaN,
    })).not.toHaveProperty("rev");
  });

  test("non-object frames are rejected", () => {
    for (const bad of [null, undefined, 42, "hello", []]) {
      expect(() => parseControlAction(bad)).toThrow(ControlParseError);
    }
  });

  test("reply helpers mirror the chat action shapes", () => {
    expect(actionOk("r1", "workspace_list", { workspaces: [] })).toEqual({
      type: "action_ok", in_reply_to: "r1", action: "workspace_list", workspaces: [],
    });
    expect(actionError("r1", "create_session", "nope")).toEqual({
      type: "action_error", in_reply_to: "r1", action: "create_session", error: "nope",
    });
  });
});
