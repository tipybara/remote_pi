/**
 * Resolve the model registry exposed by the current Pi extension context.
 *
 * Pi 0.83 removed the old public `ModelRegistry.create(AuthStorage.create())`
 * factories. More importantly, a separately-created registry never included
 * providers registered dynamically by extensions. The live context registry is
 * now the only supported source of truth.
 */

import type { ModelRegistry } from "@earendil-works/pi-coding-agent";

export interface ModelRegistryContext {
  modelRegistry?: ModelRegistry;
}

/**
 * Return the live registry or fail with a controlled, actionable error.
 * Callers must catch this error and reply on the wire; it must never escape a
 * relay/WebSocket callback as an uncaughtException.
 */
export function ensureModelRegistry(
  ctx: ModelRegistryContext | null | undefined,
): ModelRegistry {
  if (!ctx?.modelRegistry) {
    throw new Error("model registry unavailable (no active Pi session context)");
  }
  return ctx.modelRegistry;
}

/** Retained as a no-op compatibility seam for older tests/importers. */
export function _resetModelRegistryForTests(): void {
  // No module cache remains: the registry belongs to the live Pi context.
}
