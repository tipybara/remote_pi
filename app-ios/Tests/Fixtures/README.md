# Wire fixtures — bytes off a real relay

Everything in `wire/` and `transcript.jsonl` was **recorded**, not written.
Each file holds the exact UTF-8 text of one WebSocket frame as it crossed a
transparent logging proxy sitting between real peers and a real `relay`
process. Nothing here is a guess about what the protocol looks like.

Plan 62 ranks wire compatibility as risk **R1**. A Swift suite that asserts the
Swift encoder against the Swift decoder proves nothing about interop: it passes
just as happily when both sides are wrong together. These fixtures are the
other half — the bytes `relay/src/**` and `pi-extension/src/**` actually
produce.

---

## Reproduce

```bash
# 1. A relay on :3777 (it may already be running).
cd /Users/yang/workspace/remote_pi/relay && cargo run

# 2. In another shell, from the repo root:
cd /Users/yang/workspace/remote_pi
node app-ios/Tests/Fixtures/capture-wire.mjs
```

Options: `--relay <ws url>` (default `ws://127.0.0.1:3777`), `--port <n>` for
the logging proxy (default 3877), `--out <dir>` (default `wire/`), `--keep` to
leave the throwaway `HOME` behind.

The capture takes about 20 seconds and rewrites every file under `wire/` plus
`transcript.jsonl`. It never touches `~/.pi/remote` or `~/.remote-pi-fake`:
every child process runs with `HOME` pointed at a fresh temp directory.

Prerequisites: `node` ≥ 22, a built `relay`, and `pi-extension/node_modules`
present (the capture borrows `ws` and `tsx` from it — no dependency is added
anywhere).

---

## What produced what

| Source | Frames it produced |
|---|---|
| **`relay/`**, a live `cargo run` | `challenge`, the REWRITTEN outer envelope, `room_announced`, `room_ended`, `rooms`, `room_meta_updated`, `presence`, `peer_online`, `peer_offline`, `transport_error` |
| **`pi-extension/src/daemon/gateway.ts`** — the real `Gateway`, driven by `capture-gateway.mts` | the `ctrl` room's `hello`, and every control-plane `action_ok` / `action_error` |
| **`scripts/fake-pi.mjs`**, unmodified | a chat room's `hello` with the full post-plan-61 `room_meta`, `room_meta_update`, `pair_ok` / `pair_error`, the chat stream, `session_rename` replies |
| **`capture-wire.mjs`** itself | the APP side (`hello`, `auth`, subscriptions, envelopes), and a synthetic Pi used only to *stimulate* the relay's merge-patch gate |

The synthetic Pi exists for one reason: `fake-pi.mjs` never sends a
deliberately stale `name_rev` and never sends an explicit `null`, and modifying
it was out of bounds. What is pinned from those exchanges is always the
**relay's reply**, never the stimulus.

`capture-gateway.mts` runs the production `Gateway` class against the real
relay. Only two seams the production code already exposes are used:
`GatewayOptions.host` (the supervisor interface — stubbed, since spawning real
Pi daemons is not protocol) and `HOME` / `REMOTE_PI_HOME`. Nothing under
`pi-extension/src/**` is modified.

---

## File format

```jsonc
{
  "_fixture":     "room_announced",
  "_captured_at": "2026-08-25T…Z",
  "_produced_by": "app-ios/Tests/Fixtures/capture-wire.mjs against a live relay on :3777",
  "_note":        "what this frame is and why it is here",
  "direction":    "app/main ← relay",
  "raw":          "{\"type\":\"room_announced\",…}",   // the exact wire text
  "frame":        { … },                                // the same bytes, parsed, for humans
  "inner_raw":    "{\"type\":\"user_message\",…}",      // envelopes only: the decoded `ct`
  "inner":        { … }
}
```

JSON has no comments, which is why the provenance lives in the `_`-prefixed
keys. **Tests read `raw` (and `inner_raw`) only.** `frame` and `inner` are
there so a human can read the file; nothing asserts against them.

`transcript.jsonl` is the full ordered capture — every frame in both directions
on every connection, with a `label` of the form `"<peer>/<room>"`. Two tests
replay it wholesale rather than cherry-picking.

---

## What the tests pin, and what they deliberately do not

**Pinned:** which keys exist, which are absent, the value of each, and its JSON
type. A `working` that degraded from a bool into a number fails.

**Not pinned:** key order. `serde_json` emits its `BTreeMap` order
(alphabetical), `JSON.stringify` emits insertion order, `JSONEncoder` emits its
own — all three are the same JSON. Comparisons go through a structural walk,
never string equality.

**Also not pinned:** the order of entries inside a `rooms` snapshot. The relay
builds it from a `HashMap`, so it is genuinely nondeterministic between runs.

Values that change on every capture (peer keys, session UUIDs, timestamps) are
never hardcoded in a test — assertions either derive them from the fixtures or
cross-check one fixture against another. The values that *are* hardcoded are
the ones the capture script controls on purpose: `name_rev` 1780000000000 /
…001, the labels `patch-target` / `patched name` / `stale must lose` /
`equal-rev must lose` / `seeded-session` / `created by capture`, and
`created_at` 1780000000000.

---

## Fixtures

### Handshake
| File | What |
|---|---|
| `hello_app` | the app's `hello` — `room_id` is always `"main"`, no `room_meta` |
| `hello_pi_session` | a Pi opening a chat room, full plan-61 `room_meta` |
| `hello_pi_control` | the REAL gateway opening `ctrl` — no `session_id`, no `name_rev` |
| `hello_harness_control` | `fake-pi.mjs`'s control room, for comparison |
| `challenge` | relay step 2, on the app's own connection |
| `auth` | the signature over that challenge — verifiable against `hello_app.pubkey` |

`hello_app` + `challenge` + `auth` are one connection, in order, so the triple
is a cross-implementation Ed25519 vector: Node signed it, CryptoKit verifies it.

### Relay control frames
`room_announced`, `room_announced_control`, `room_ended`, `rooms_empty`,
`rooms_snapshot`, `presence_offline`, `presence_with_since_ts`, `peer_online`,
`peer_offline`, `transport_error`.

### App → relay control frames
`subscribe_rooms`, `subscribe_presence`, `rooms_check`, `presence_check`.

### The merge patch — absent vs null vs set
| File | What |
|---|---|
| `room_meta_update_name` | a Pi's rename patch: `{name, name_rev}` |
| `room_meta_update_working` | a one-field patch; everything else must be preserved |
| `room_meta_update_clear_model` | an explicit `null` — the case `encodeIfPresent` cannot express |
| `room_meta_update_stale_name` | an OLDER `name_rev`; the relay rejects it |
| `room_meta_update_equal_rev` | an EQUAL `name_rev`; rejected too — the gate is strictly-greater |
| `room_meta_updated_name` | the broadcast after an ACCEPTED patch |
| `room_meta_updated_working` | the broadcast after the one-field patch: post-patch FULL state |
| `room_meta_updated_model_cleared` | after the explicit null, `model` is **omitted**, not `null` |
| `room_meta_updated_stale_rejected` | the broadcast after a REJECTED patch — byte-identical to `room_meta_updated_name` |
| `room_meta_updated_harness_working` | the same shape from `fake-pi.mjs` when a turn starts |

The last one in that list is the trap the whole design turns on: an inbound
`name` is **not** evidence of a rename. A rejected patch still triggers a
broadcast of the *current* name, which is how the stale sender re-syncs.

### Envelopes
`envelope_app_to_pi` (outbound: `peer` = destination, `room` = the
destination's room) and `envelope_pi_to_app_rewritten` (the same `ct` coming
back, after the relay rewrote both fields to describe the sender).

### Inner frames
`inner_pair_request`, `inner_pair_ok`, `inner_pair_error`,
`inner_user_message_echo`, `inner_agent_chunk`, `inner_agent_done`,
`inner_models_list`, `inner_session_history`, `inner_pong`,
`inner_session_rename`, `inner_action_ok_rename`, `inner_action_error_rename`.

### Control plane (the REAL gateway)
`control_workspace_list`, `control_create_session`,
`control_action_ok_workspace_list`, `control_action_ok_session_list`,
`control_action_ok_create_session`, `control_action_ok_create_session_replay`,
`control_action_ok_session_rename`, `control_action_error_missing_key`,
`control_action_error_unknown_session`.

`control_action_ok_session_list` comes from the machine and **not** from
`fake-pi.mjs` on purpose: the harness answers with a simpler shape (`status`,
`name_rev`) than the real `daemon/sessions.ts` does (`mode`, `desired`,
`created_at`, plus a live `running`). Pinning the Swift decoder against the
harness would have pinned the wrong contract.

### The gateway's reply-routing defect
| File | What |
|---|---|
| `control_reply_envelope_as_gateway_writes_it` | the gateway's reply envelope, verbatim: `room` is `"ctrl"` — its OWN room |
| `transport_error_gateway_reply_bounced` | the relay telling the *gateway* it could not deliver that reply |

The outer `room` names the **destination's** room, and the app registers only
`main`. So `(app, "ctrl")` does not exist, the relay drops the reply and
answers the gateway with `transport_error: offline`, which the gateway
discards. Every control RPC then times out at 45 s with the machine looking
perfectly online.

`plan/62-specs/09-control-plane.md` §7 D1 / §9 T1 derived this from reading the
three implementations and recorded that **no test covered it**. These two
fixtures are that exchange, captured off a live relay. The capture harness
works around it by holding a second app connection registered at `ctrl` —
mitigation 1 from spec 09 T1 — which is what a native client will have to do
until `gateway.ts` stops naming its own room.

### Not a wire frame
`pairing_qr.json` — the `remotepi://pair?…` text plus both spellings of the
same Pi key: `epk_url_safe` (43 chars, url-safe, unpadded) and `peer_standard`
(44 chars, standard, padded). A `PeerID` parsed from the QR must encode to the
standard form on the wire; comparing the two spellings as strings is the bug
`app/lib/data/transport/epk_encoding.dart` exists to contain.

---

## The tests

One `WireConformanceTests.swift` per Kit target, each with its own copy of the
fixture loader (test targets are separate modules and share no code):

| Target | Covers |
|---|---|
| `RemotePiProtocolTests` | every frame type, the merge patch, the `name_rev` gate, envelopes, control-plane replies, PeerID spelling |
| `RemotePiCryptoTests` | the captured handshake triple, verified with CryptoKit; EPK spelling round trips |
| `RemotePiTransportTests` | envelope-vs-control discrimination over the whole transcript, the room demux, the size ceiling, the gateway routing evidence |
| `RemotePiSessionTests` | the transcript replayed through `RoomRegistry`; `MachineControlClient` driven with the real gateway replies |
| `RemotePiPairingTests` | the QR payload, `pair_request` / `pair_ok` / `pair_error` |

Fixtures load from the filesystem via `#filePath` rather than `Bundle.module`,
because resource bundling would need a `resources:` clause in `Package.swift`.
