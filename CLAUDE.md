# Remote Pi — repo root

This folder is the monorepo root. Prefer planning here; implement in the matching subproject.

## Do

- Read and write `plan/NN-<slug>.md`
- Discuss architecture, product decisions, trade-offs
- Point the next implementation at one subproject

## Do not

- Edit `app/`, `pi-extension/`, `relay/`, `site/`, or `cockpit/` from a root-only planning session unless the user asked for that change
- Dispatch work through cmux or Cockpit CLI. Those harness injections are removed. Work in this checkout directly, or open a normal session in the subproject.

## Layout

See [README.md](./README.md) and [plan/](./plan/).

Closed decisions live in [`plan/00-decisions.md`](./plan/00-decisions.md). Do not silently reopen them. Current mobile identity / control-plane work is [`plan/61-stable-session-identity.md`](./plan/61-stable-session-identity.md).

## Plan conventions

- Sequential numbers: `01-bootstrap.md`, …
- Each plan: context, expected structure, steps with acceptance, DoD
- Plans say **what** and **how to verify**, not the full implementation

## Subprojects

| Path | What |
|---|---|
| `app/` | Flutter mobile client |
| `pi-extension/` | Pi coding-agent extension |
| `relay/` | Rust relay |
| `site/` | Docs / marketing site |
| `cockpit/` | Desktop Cockpit product (not a harness hook) |

Read-only scouts: `scout-app`, `scout-pi-extension`, `scout-relay`, `scout-site`, `scout-cockpit`.
