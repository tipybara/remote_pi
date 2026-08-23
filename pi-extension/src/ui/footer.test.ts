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

describe("updateFooter — relay/mobile rendering", () => {
  test("legacy name/session and relay slots stay cleared", () => {
    const ctx = makeMockCtx();
    updateFooter(ctx, {
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
      relayOn: true,
      agentName: "backend",
    });
    expect(ctx.titleCalls.at(-1)).toBe("backend · On");
  });

  test("title is `<agent> · Off` when relay is down", () => {
    const ctx = makeMockCtx();
    updateFooter(ctx, {
      relayOn: false,
      agentName: "backend",
    });
    expect(ctx.titleCalls.at(-1)).toBe("backend · Off");
  });

  test("title falls back to 'Pi' when no agentName configured", () => {
    const ctx = makeMockCtx();
    updateFooter(ctx, {
      relayOn: false,
    });
    expect(ctx.titleCalls.at(-1)).toBe("Pi · Off");
  });

});
