/**
 * Right-aligned "online peers" chip rendered via `ctx.ui.setWidget`.
 *
 * Pure helpers live here so footer/widget UX can be unit-tested without the
 * full extension harness. The extension binds them to live mesh state.
 */

export const PEERS_WIDGET_KEY = "remote-pi:peers-online";

/** Build the chip label from this session's assigned mesh name. */
export function formatOnlinePeersLabel(name: string): string {
  return `🟢 online: ${name}`;
}

/**
 * Right-align `label` into a single terminal row of `width` cells.
 * Truncates with an ellipsis when the label exceeds the row.
 */
export function renderRightAlignedLine(label: string, width: number): string {
  const max = Math.max(0, width - 1);
  const text =
    label.length > max ? `${label.slice(0, Math.max(0, max - 1))}…` : label;
  return `${" ".repeat(Math.max(0, width - text.length))}${text}`;
}

/**
 * Extract a short display name from a mesh address.
 *
 * Address forms:
 *   - `<cwd>@<name>`
 *   - `<pc>:<cwd>@<name>`  (cross-PC)
 *
 * Returns null when the address is empty or names this agent (`selfName`).
 */
export function peerDisplayName(
  addr: string,
  selfName?: string | null,
): string | null {
  const s = String(addr);
  if (!s) return null;
  const at = s.lastIndexOf("@");
  if (at < 0) {
    if (selfName && s === selfName) return null;
    return s;
  }
  const name = s.slice(at + 1);
  if (!name || (selfName && name === selfName)) return null;
  const colon = s.indexOf(":");
  const pc = colon > 0 && colon < at ? s.slice(0, colon) : null;
  return pc ? `${pc}:${name}` : name;
}

/** Dedupe + sort peer display names from raw broker addresses. */
export function onlinePeerNames(
  addresses: readonly string[],
  selfName?: string | null,
): string[] {
  const names = new Set<string>();
  for (const addr of addresses) {
    const n = peerDisplayName(addr, selfName);
    if (n) names.add(n);
  }
  return [...names].sort();
}

/** Minimal Component-shaped factory for `ui.setWidget`. */
export function makeRightAlignedPeersWidget(name: string): () => {
  render: (width: number) => string[];
  invalidate: () => void;
} {
  const label = formatOnlinePeersLabel(name);
  return () => ({
    render: (width: number) => [renderRightAlignedLine(label, width)],
    invalidate() {},
  });
}
