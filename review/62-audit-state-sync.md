# Audit — communication & state sync across App / Relay / pi-extension (2026-08-26)

Requested as a design review of how the three components talk and stay in
agreement. Scope: liveness (`online`/`offline`/`working` dots), the
subscription/push/poll protocol, and the recovery story when the two sides
disagree. Trigger: the user reported "online 状态经常不准".

**Conclusion:** the push protocol is sound; the failure was concentrated in
the *reconciliation* half. Three defects, all fixed in this pass, each pinned
by a regression test that was verified to fail against the pre-fix code where
that was possible.

Baselines after the fixes: relay 116 tests + clippy clean · Flutter 631 tests ·
Swift 480 tests. (pi-extension needed no change for these findings; its
`gateway.ts` reply-routing defect was found and fixed separately the day
before, see the wire-conformance fixtures README.)

---

## D1 — a missed-ping "offline" was PERMANENT (both clients)

**Mechanism.** Three unanswered inner pings mark the active room offline
locally (`_markActiveRoomOffline` / `markActiveRoomOffline()`). The comments
in both clients claimed recovery was automatic:

> "When Pi comes back … `room_announced` repopulates `_liveRoomIds` → tile
> flips back to green automatically."

That path does not exist, for two independent reasons:

1. `room_announced` fires only on a room's **first** connection
   (`relay/src/peers/registry.rs`, `is_first_in_room`). The scenario that
   produces missed pings is a Pi that is slow/paused **while its socket stays
   up** — it never re-announces.
2. The fallback poll was starved by D2 below.

And the client-side revive logic had been amputated — the Dart inbound handler
literally read:

```dart
final wasMissed = _missedPings;
if (wasMissed > 0) {}        // ← empty
if (_retryAttempt != 0) {}   // ← empty
```

**Effect.** One hiccup ≥75 s and the tile stayed grey until the Pi *process*
restarted. Biased toward false-offline, permanently — matching the report.

**Fix (both clients).** The mark is now bookkept as *ours*
(`_locallyMarkedOffline` / `locallyMarkedOffline`), with an explicit
reversibility rule:

- **local pessimism** is reversed by **local evidence** — the next inbound
  frame that passes the demux re-inserts the live flag;
- **relay verdicts** (`room_ended`, a `rooms` snapshot, `transport_error`)
  settle the mark and are *never* overturned from the inbound path — a
  straggler Pong queued before a real death cannot revive a dead room.

The mark also dies with the connection it was made on, and on a room switch.

Worst-case wrong-revive window: an RPC-reply frame from another room can
revive a genuinely dead Pi for ≤3 ping intervals (75 s) before re-marking —
self-correcting, and strictly better than never recovering.

## D2 — the relay refused to answer identical polls

`presence_check` / `rooms_check` replies were deduplicated per connection:
identical to the previous reply → suppressed (`last_rooms_resp` in
`handlers/peer.rs`, with metrics and tests asserting the suppression).

That contract is wrong by design: **a poll is a question the client asks
precisely because it suspects its own copy is wrong.** Suppressing the answer
when the relay's view hasn't changed starves the resync channel in exactly the
case that needs it — any client-side divergence within one connection became
unrecoverable. (This was the second half of D1's permanence.)

**Fix.** Checks are always answered. Unsolicited pushes keep their
edge-triggered dedup in the registry (`was_offline_before` /
`is_first_in_room`) — the change is only about direct questions. The firehose
the dedup once guarded against (checks re-sent on every peer-storage mutation)
was removed at the source by plan 61 Phase 0. The two relay tests asserting
suppression were inverted into always-answer tests, with the rationale in
their doc comments.

## D3 — `working` outlived the process (both clients)

`room_ended` and `transport_error` removed a room from the live set but left
the cached `RoomInfo.working` / `RoomMeta.working` untouched, and neither
client's `isRoomWorking` / `isWorking` was gated on liveness. The presence
ladder ranks working above everything else, so a Pi killed mid-turn kept a
**blue** dot on an offline session indefinitely. (The plan-61 relay audit
listed this as "grey tile can stick busy"; it was never fixed, and the native
client inherited it through the specs.)

**Fix (both clients).** Two layers, same direction:

- *cache honesty* — room death (`room_ended`, `transport_error`) clears the
  cached `working` flag, so persistence cannot resurrect it;
- *invariant* — the getter is gated: working ⊆ live, by definition (an
  in-flight turn requires a running, registered process).

---

## What was deliberately NOT changed

- The **edge-triggered push dedup** in the relay registry. That one is
  correct: pushes are unsolicited, and re-broadcasting identical state to
  every subscriber on every reconnect of every device was the real firehose.
- The **envelopes-only** rule for resetting the ping-miss counter. Control
  frames keep flowing from the relay while the agent is dead; counting them as
  liveness would pin the backoff ladder at rung 0 forever (that bug existed
  and was fixed once already).
- `started_at` semantics, the demux, `name_rev` gating — reviewed, sound.

## Verification notes (honesty section)

- D1/Dart: the revive test cannot run against the pre-fix code (it uses a new
  test seam), but the amputated empty-`if` blocks are the defect made visible;
  the relay-verdict-wins test pins the non-overturn rule.
- D2: the old tests *asserted the defect*; they were inverted, and the new
  contract is pinned in both `presence_test.rs` and `rooms_test.rs`.
- D3/Dart: verified red-without-fix indirectly — `isRoomWorking` had no
  liveness gate (grep), and the new tests assert both the getter and the
  cache. D3/Swift: `testRoomEndedClearsWorking` fails against the old
  `markDead` by construction (it only touched the live set).
- End-to-end (fake-pi + local relay) was NOT re-run in this pass; the fixes
  are unit-pinned. Worth one manual pass before the next release.
