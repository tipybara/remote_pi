import { describe, expect, test, vi } from "vitest";
import { mkdtempSync, existsSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runSetupWizard, type WizardUI } from "./setup_wizard.js";
import {
  defaultAgentName,
  loadLocalConfig,
  localConfigExists,
  saveLocalConfig,
  effectiveAutoStartRelay,
} from "./local_config.js";

const YES = "Yes";
const NO = "No";

function tmpCwd(): string {
  return mkdtempSync(join(tmpdir(), "pi-wiz-"));
}

/** Sequencing helper: returns a UI mock that replays canned answers in order. */
function makeUI(answers: Array<string | undefined>): WizardUI & {
  selectCalls: Array<{ title: string; options: string[] }>;
  notifies: Array<{ msg: string; kind: string }>;
} {
  const queue = [...answers];
  const selectCalls: Array<{ title: string; options: string[] }> = [];
  const notifies: Array<{ msg: string; kind: string }> = [];
  return {
    selectCalls,
    notifies,
    select: vi.fn().mockImplementation(async (title: string, options: string[]) => {
      selectCalls.push({ title, options });
      return queue.shift();
    }),
    notify: vi.fn().mockImplementation((msg: string, kind: string) => {
      notifies.push({ msg, kind });
    }),
  };
}

describe("runSetupWizard (Relay auto-start + confirm)", () => {
  test("accepts auto-start and returns only Relay config", async () => {
    const ui = makeUI([YES, YES]);
    const cfg = await runSetupWizard(ui, { use_relay: true });
    expect(cfg).toEqual({ auto_start_relay: true });
    expect(ui.selectCalls.map((c) => c.title)).toEqual([
      "Start the mobile Relay automatically for future Pi sessions?",
      "Save and activate?",
    ]);
  });

  test("cancel on Relay prompt returns null", async () => {
    const ui = makeUI([undefined]);
    expect(await runSetupWizard(ui, { use_relay: true })).toBeNull();
  });

  test("No on final confirmation returns null", async () => {
    const ui = makeUI([YES, NO]);
    expect(await runSetupWizard(ui, { use_relay: true })).toBeNull();
  });

  test("disabled default keeps No first and persists auto-start false", async () => {
    const ui = makeUI([NO, YES]);
    expect(await runSetupWizard(ui, { use_relay: false })).toEqual({
      auto_start_relay: false,
    });
    expect(ui.selectCalls[0]?.options).toEqual([NO, YES]);
  });

  test("explains that /name owns the Relay room identity", async () => {
    const ui = makeUI([YES, YES]);
    await runSetupWizard(ui, { use_relay: true });
    expect(ui.notifies.some((n) => n.msg.includes("/name"))).toBe(true);
    expect(ui.notifies.some((n) => n.msg.includes("Agent name:"))).toBe(false);
  });
});

describe("localConfig integration with the wizard", () => {
  test("localConfigExists() reflects fresh cwd (config absent before save)", () => {
    const cwd = tmpCwd();
    expect(localConfigExists(cwd)).toBe(false);
    saveLocalConfig(cwd, {
      agent_name: "x",
      auto_start_relay: true,
    });
    expect(localConfigExists(cwd)).toBe(true);
    const persisted = loadLocalConfig(cwd);
    expect(persisted).toMatchObject({
      agent_name: "x",
      auto_start_relay: true,
    });
  });

  test("/remote-pi setup updates Relay preference without changing a daemon name", async () => {
    const cwd = tmpCwd();
    saveLocalConfig(cwd, { agent_name: "daemon-name", auto_start_relay: false });
    const current = loadLocalConfig(cwd);

    const ui = makeUI([YES, YES]);
    const cfg = await runSetupWizard(ui, {
      use_relay: effectiveAutoStartRelay(current),
    });
    expect(cfg).toEqual({ auto_start_relay: true });
    saveLocalConfig(cwd, cfg!);

    const updated = loadLocalConfig(cwd);
    expect(updated.agent_name).toBe("daemon-name");
    expect(updated.auto_start_relay).toBe(true);
  });

  test("legacy config without auto_start_relay → treated as true", () => {
    const cwd = tmpCwd();
    const cfgPath = join(cwd, ".pi", "remote-pi", "config.json");
    const { mkdirSync, writeFileSync } = require("node:fs") as typeof import("node:fs");
    mkdirSync(join(cwd, ".pi", "remote-pi"), { recursive: true });
    writeFileSync(
      cfgPath,
      JSON.stringify({ agent_name: "legacy" }, null, 2),
    );

    const loaded = loadLocalConfig(cwd);
    expect(loaded.auto_start_relay).toBeUndefined();
    expect(effectiveAutoStartRelay(loaded)).toBe(true);

    saveLocalConfig(cwd, { agent_name: "legacy-renamed" });
    const reloaded = loadLocalConfig(cwd);
    expect(reloaded.auto_start_relay).toBe(true);
    expect(reloaded.agent_name).toBe("legacy-renamed");
    expect(existsSync(cfgPath)).toBe(true);
    const raw = JSON.parse(readFileSync(cfgPath, "utf8")) as Record<string, unknown>;
    expect(raw["auto_start_relay"]).toBe(true);
  });

  test("legacy config with session_name field is silently dropped on load", () => {
    // Pre-refactor configs carried session_name. Current room identity uses
    // cwd + Pi session display name, so legacy field is ignored.
    const cwd = tmpCwd();
    const cfgPath = join(cwd, ".pi", "remote-pi", "config.json");
    const { mkdirSync, writeFileSync } = require("node:fs") as typeof import("node:fs");
    mkdirSync(join(cwd, ".pi", "remote-pi"), { recursive: true });
    writeFileSync(
      cfgPath,
      JSON.stringify({
        agent_name: "legacy",
        session_name: "old-session",
        auto_start_relay: true,
      }, null, 2),
    );

    const loaded = loadLocalConfig(cwd);
    expect(loaded.agent_name).toBe("legacy");
    expect((loaded as Record<string, unknown>)["session_name"]).toBeUndefined();
    expect(loaded.auto_start_relay).toBe(true);
  });
});

describe("defaultAgentName", () => {
  test("returns the leaf (basename) of the cwd", () => {
    expect(defaultAgentName("/Users/jacob/Projects/remote_pi")).toBe("remote_pi");
    expect(defaultAgentName("/home/dev/myapp/backend")).toBe("backend");
    expect(defaultAgentName("/foo")).toBe("foo");
  });

  test("falls back to 'agent' for empty/root edge cases", () => {
    expect(defaultAgentName("/")).toBe("agent");
  });
});
