import { describe, expect, test, vi } from "vitest";
import { updateFooter, type FooterContext, type FooterState } from "./footer.js";

function makeMockCtx(): FooterContext & {
  statusCalls: Array<{ key: string; value: string | undefined }>;
  titleCalls: string[];
} {
  const statusCalls: Array<{ key: string; value: string | undefined }> = [];
  const titleCalls: string[] = [];
  return {
    ui: {
      setStatus: vi.fn().mockImplementation((key: string, value: string | undefined) => {
        statusCalls.push({ key, value });
      }),
      setTitle: vi.fn().mockImplementation((title: string) => {
        titleCalls.push(title);
      }),
    },
    statusCalls,
    titleCalls,
  };
}

describe("updateFooter — footer slots ('local' rendering)", () => {
  test("name / session / relay slots stay cleared (moved to editor border)", () => {
    const ctx = makeMockCtx();
    updateFooter(ctx, {
      session: "local",
      peerCount: 3,
      relayOn: true,
      hasPairings: true,
      agentName: "backend",
    });
    expect(ctx.statusCalls.find((c) => c.key === "remote-pi:agent-name")?.value).toBeUndefined();
    expect(ctx.statusCalls.find((c) => c.key === "remote-pi:session")?.value).toBeUndefined();
    expect(ctx.statusCalls.find((c) => c.key === "remote-pi:relay")?.value).toBeUndefined();
  });

  test("keeps the active-device slot", () => {
    const ctx = makeMockCtx();
    updateFooter(ctx, { devicePaired: "qAoPpAbg" });
    expect(ctx.statusCalls.find((c) => c.key === "remote-pi:peer-active")?.value).toBe(
      "📱 qAoPpAbg",
    );
  });
});

describe("updateFooter — terminal title (post-2026-05-24 two-part format)", () => {
  test("title is `<agent> · On` when relay is up", () => {
    const ctx = makeMockCtx();
    updateFooter(ctx, {
      session: "local",
      peerCount: 2,
      relayOn: true,
      agentName: "backend",
    });
    expect(ctx.titleCalls.at(-1)).toBe("backend · On");
  });

  test("title is `<agent> · Off` when relay is down", () => {
    const ctx = makeMockCtx();
    updateFooter(ctx, {
      session: "local",
      peerCount: 1,
      relayOn: false,
      agentName: "backend",
    });
    expect(ctx.titleCalls.at(-1)).toBe("backend · Off");
  });

  test("broker-assigned name with #N suffix flows through verbatim", () => {
    // Two Pis in the same cwd: the second gets "backend#2" from the broker.
    const ctx = makeMockCtx();
    updateFooter(ctx, {
      session: "local",
      peerCount: 2,
      relayOn: true,
      agentName: "backend#2",
    });
    expect(ctx.titleCalls.at(-1)).toBe("backend#2 · On");
  });

  test("title falls back to 'Pi' when no agentName configured", () => {
    const ctx = makeMockCtx();
    updateFooter(ctx, {
      session: "local",
      peerCount: 1,
      relayOn: false,
    });
    expect(ctx.titleCalls.at(-1)).toBe("Pi · Off");
  });

  test("title never includes the session name (pre-2026-05-24 had `· local ·`)", () => {
    const ctx = makeMockCtx();
    updateFooter(ctx, {
      session: "local",
      peerCount: 0,
      relayOn: true,
      agentName: "foo",
    });
    expect(ctx.titleCalls.at(-1)).not.toContain("local");
  });
});
