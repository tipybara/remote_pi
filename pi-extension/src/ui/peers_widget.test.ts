import { describe, expect, test } from "vitest";
import {
  formatOnlinePeersLabel,
  makeRightAlignedPeersWidget,
  onlinePeerNames,
  peerDisplayName,
  renderRightAlignedLine,
} from "./peers_widget.js";

describe("peerDisplayName", () => {
  test("strips cwd from local address", () => {
    expect(peerDisplayName("/tmp/proj@backend")).toBe("backend");
  });

  test("keeps pc prefix for cross-PC address", () => {
    expect(peerDisplayName("macmini:/tmp/proj@backend")).toBe("macmini:backend");
  });

  test("filters self name", () => {
    expect(peerDisplayName("/tmp/proj@backend", "backend")).toBeNull();
  });
});

describe("onlinePeerNames", () => {
  test("dedupes, drops self, sorts", () => {
    expect(
      onlinePeerNames(
        ["/a@zebra", "/a@alpha", "/a@zebra", "pc:/b@beta", "/a@me"],
        "me",
      ),
    ).toEqual(["alpha", "pc:beta", "zebra"]);
  });
});

describe("right-aligned peers widget", () => {
  test("label lists peers", () => {
    expect(formatOnlinePeersLabel(["alpha", "beta"])).toBe(
      "🟢 online: alpha · beta",
    );
  });

  test("render pads to the right edge", () => {
    const line = renderRightAlignedLine("hi", 10);
    expect(line).toBe("        hi");
    expect(line).toHaveLength(10);
  });

  test("render truncates with ellipsis when too long", () => {
    const line = renderRightAlignedLine("abcdefghij", 6);
    expect(line.endsWith("…")).toBe(true);
    // Row always fills `width`; truncated body fits in width-1 then padded.
    expect(line).toHaveLength(6);
    expect(line.trimStart().length).toBeLessThanOrEqual(5);
  });

  test("widget factory returns right-aligned row", () => {
    const factory = makeRightAlignedPeersWidget(["alpha"]);
    const comp = factory();
    const row = comp.render(40)[0]!;
    expect(row.trimStart()).toBe("🟢 online: alpha");
    expect(row.endsWith("🟢 online: alpha")).toBe(true);
    expect(row).toHaveLength(40);
  });
});
