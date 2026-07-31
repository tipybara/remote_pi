# tipybara/remote_pi

Customized fork of [`jacobaraujo7/remote_pi`](https://github.com/jacobaraujo7/remote_pi) for local Pi agent mesh.

Complete upstream documentation: [`original_readme.md`](./original_readme.md). Extension-specific upstream docs and local patch notes: [`pi-extension/original_readme.md`](./pi-extension/original_readme.md), [`pi-extension/CUSTOM_PATCHES.md`](./pi-extension/CUSTOM_PATCHES.md).

## Custom behavior

- Exposes repository root as installable Pi git package.
- Keeps local mesh usable when relay auto-start is disabled.
- Makes extension messaging reload-safe after `/reload` or session replacement.
- Publishes relay state for local editor-border UI and clears duplicate footer/widget mesh chips.
- Keeps active mobile-device footer status.

```bash
pi install git:github.com/tipybara/remote_pi
```

Root package loads `pi-extension/src/index.ts`; Pi core/TUI stay peer dependencies.

## Development

```bash
cd pi-extension
pnpm install
pnpm typecheck
pnpm test
pnpm build
```
