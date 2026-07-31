# tipybara/remote_pi

Customized fork of [`jacobaraujo7/remote_pi`](https://github.com/jacobaraujo7/remote_pi) for the local Pi agent mesh.

The complete upstream repository documentation is preserved verbatim in [`original_readme.md`](./original_readme.md). The Pi extension's upstream documentation and patch details are in [`pi-extension/original_readme.md`](./pi-extension/original_readme.md) and [`pi-extension/CUSTOM_PATCHES.md`](./pi-extension/CUSTOM_PATCHES.md).

## Custom behavior

- Shows the local mesh/agent name first in the remote-pi footer status.
- Adds a right-aligned live online-peer widget.
- Keeps the local mesh usable when relay auto-start is disabled.
- Makes relay state notifications reload-safe: callbacks never use a stale captured Pi extension context after `/reload` or session replacement.
- Exposes the repository root as a Pi git package, so it can be installed directly with:

```bash
pi install git:github.com/tipybara/remote_pi
```

The root package loads `pi-extension/src/index.ts` and installs its non-core runtime dependencies. Pi core/TUI remain peer dependencies.

## Development

Run extension validation from `pi-extension/`:

```bash
pnpm install
pnpm typecheck
pnpm test
pnpm build
```
