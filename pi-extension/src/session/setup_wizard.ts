import type { LocalConfig } from "./local_config.js";

/**
 * Pi SDK UI surface needed by the wizard. Subset of `ExtensionUIContext` —
 * declared inline so tests can mock cleanly without dragging the full
 * ExtensionContext shape.
 */
export interface WizardUI {
  /** Picker. Returns the picked option, or undefined if cancelled. */
  select: (title: string, options: string[]) => Promise<string | undefined>;
  /** Non-blocking notification. Used for inline context. */
  notify?: (msg: string, kind: "info" | "warning" | "error") => void;
}

export interface WizardDefaults {
  use_relay: boolean;
}

const YES = "Yes";
const NO = "No";

/**
 * Configures whether future interactive Pi sessions connect to the mobile
 * Relay automatically. The Pi session display name is the room identity and
 * remains managed by `/name`; legacy `agent_name` is daemon-only compatibility.
 */
export async function runSetupWizard(
  ui: WizardUI,
  defaults: WizardDefaults,
): Promise<LocalConfig | null> {
  ui.notify?.(
    "Remote Pi can start its mobile Relay connection automatically when this Pi session starts. You can always connect manually with /remote-pi. The Relay room uses the Pi session name; change it with /name.",
    "info",
  );
  const useRelayChoice = await ui.select(
    "Start the mobile Relay automatically for future Pi sessions?",
    defaults.use_relay ? [YES, NO] : [NO, YES],
  );
  if (!useRelayChoice) return null;
  const auto_start_relay = useRelayChoice === YES;

  ui.notify?.(`Summary:\n  Auto-start:    ${auto_start_relay ? YES : NO}`, "info");
  const confirm = await ui.select("Save and activate?", [YES, NO]);
  if (confirm !== YES) return null;

  return { auto_start_relay };
}
