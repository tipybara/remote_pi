# Spec 07 — Local persistence model

**Status:** implementation-ready specification for the native iOS client.
**Protocol baseline:** post plan 61 (`room_id == session_id`, `name_rev`, `ctrl`
room, `transport_error`). See [`PROTOCOL.md`](../../PROTOCOL.md) and
[`plan/61-stable-session-identity.md`](../61-stable-session-identity.md).
**Ground truth read for this spec:** `app/lib/data/local/**`,
`app/lib/data/sync/sync_service.dart`, `app/lib/data/repositories/**`,
`app/lib/pairing/storage.dart`, `app/lib/data/preferences/preferences.dart`,
`pi-extension/src/rooms.ts`, `pi-extension/src/index.ts`,
`pi-extension/src/daemon/sessions.ts`, `relay/src/mesh/store.rs`.

This document has three parts:

1. **What exists today** — the Hive v2 schema and the SyncService write model,
   described exactly, with file:line citations. This is the behaviour the native
   client must reproduce, because the Pi and the relay assume it.
2. **Traps** — the encoding / absent-vs-null / key-shape landmines. These are
   the parts worth more than the happy path.
3. **The native design** — a concrete SQLite schema plus Swift types, and why
   SQLite over Core Data or files.

---

## 0. Who owns what state (the 30-second version)

| Store | Owner | Contents | Durability |
|---|---|---|---|
| Relay SQLite (`mesh.db`) | relay | **only** `mesh_versions` blobs | durable, server-side |
| `~/.pi/remote/sessions.json` + `workspaces.json` | the Mac | session catalogue, `desired: running\|stopped`, idempotency ledger | durable, machine-side |
| Pi `_messageBuffer` | the Pi process | last N chat events, answers `session_sync` | **in-memory, per-process** |
| App Hive `rp_v2` | the phone | message rows, session index, volatile runtime | durable (index + msgs), wiped (runtime) |
| App `FlutterSecureStorage` | the phone | pairings, room cache, preferences, Owner key | durable, Keychain |

`relay/src/mesh/store.rs:23` — "Mesh blob storage backed by SQLite. Single-table
UPSERT keyed by `owner_pk_hash`." There is no conversation table anywhere in
`relay/src`; `grep -rn "CREATE TABLE" relay/src` returns nothing (schema is in
`relay/migrations/001_mesh_versions.sql`). **The relay stores no chat.**

`pi-extension/src/daemon/sessions.ts:11-30` — the catalogue "deliberately lives
on the MACHINE, not the relay (plan 61 D7)".

Consequence for the native client: the phone's local DB is a **cache with
independent lifetime**, not a replica of an authoritative log. Nothing on the
server can restore it. See Trap T1 — and note that the current app actively
*destroys* that cache on every reconnect.

---

## 1. The Hive v2 schema

### 1.1 Namespace and boot

```dart
// app/lib/data/local/boxes.dart:43-45
const String _kNamespace   = 'rp_v2';
const String _kSessionsIndex = 'sessions_index';
const String _kRuntime       = 'runtime';
```

`boxes.dart:56-61` / `72-76`:

```dart
static Future<void> init() async {
  if (_initialized) return;
  await Hive.initFlutter(_kNamespace);   // → <AppDocuments>/rp_v2/
  await _openCommon();
  _initialized = true;
}

static Future<void> _openCommon() async {
  await Hive.openBox<dynamic>(_kSessionsIndex);
  final runtime = await Hive.openBox<dynamic>(_kRuntime);
  await runtime.clear();                 // VOLATILE — zero on boot (#3)
}
```

Called exactly once, before `runApp`, at `app/lib/main.dart:19`. The comment
there is load-bearing: the wipe must happen **before anything subscribes**,
otherwise a stale `online` row is observed for one frame.

`Hive.initFlutter('rp_v2')` resolves to
`getApplicationDocumentsDirectory()/rp_v2` (`hive_flutter-1.1.0/lib/src/hive_extensions.dart`).
On iOS that is the app's **Documents** directory — iCloud-backed by default.

There is **no `rp_v3`**, deliberately. `boxes.dart:14-38` records why: plan 61
Phase 1 made `room_id == session_id`, so the existing keys are *already*
session-keyed and a namespace bump would be pure migration risk. Keep this
reasoning — the native port inherits the same conclusion (§4.6).

### 1.2 The three box families

```
DURABLE   msgs_<epk>__<roomId>   key = seq (int)         → MessageRecord
DURABLE   sessions_index         key = <epk>:<roomId>    → SessionIndexRecord
VOLATILE  runtime (wiped@boot)   key = <epk>:<roomId>    → RuntimeRecord
```
(`boxes.dart:8-10`)

| Box | Key shape | Value | Durable? | Opened |
|---|---|---|---|---|
| `msgs_<epk>__<roomId>` | `int seq`, 0-based, dense | `Map` (MessageRecord JSON) | yes | lazily, `Hive.openBox` is idempotent (`boxes.dart:84-92`) |
| `sessions_index` | `String "<epk>:<roomId>"` | `Map` (SessionIndexRecord JSON) | yes | at boot |
| `runtime` | `String "<epk>:<roomId>"` | `Map` (RuntimeRecord JSON) | **no — `clear()` at every boot** | at boot |

### 1.3 Key derivation — the two normalizers

```dart
// boxes.dart:96-97
static String msgsBoxName(String epk, String roomId) =>
    'msgs_${toAppEpk(epk)}__$roomId';

// boxes.dart:110-111
static String sessionKey(String epk, String roomId) =>
    '${toAppEpk(epk)}:$roomId';
```

`toAppEpk` (`app/lib/data/transport/epk_encoding.dart:41-60`) converts any epk
to **base64url without padding**. Both key spaces therefore agree on the epk
form — this was a bug fixed in plan 61 Fase 0 and is asserted by
`app/test/data/local/boxes_test.dart` ("sessionKey and msgsBoxName agree on the
epk form").

**Both keys are scoped by `(epk, session_id)` and must stay that way.**
`pi-extension/src/rooms.ts:92-120` is the normative statement:

> A room id only ever has meaning inside one machine, because every layer that
> keys by it already carries the machine's Pi-key alongside […] **never key
> persistent state by room id alone.**

The table it enumerates (rooms.ts:97-104) is the full list of key spaces; three
of them are local persistence:

```
app messages     msgs_<epk>__<roomId>   — LocalBoxes.msgsBoxName
app index        <epk>:<roomId>         — LocalBoxes.sessionKey
app selection    <epk>:<roomId>         — Preferences (secure storage)
```

Note the two other key spaces use *different separators and a different epk
encoding*: `HomeItem.sessionKey` is `'${toStandardB64(peer.remoteEpk)}|${room.roomId}'`
(`app/lib/ui/home/states/home_state.dart:88`) and `ActionsRepository._sessionKey()`
(`app/lib/data/actions/actions_repository.dart:386`). Those are **in-memory /
widget keys only** — they never touch disk. Do not copy that encoding into
storage. See Trap T3.

### 1.4 `MessageRecord`

`app/lib/data/local/records/message_record.dart:6-104`.

```dart
enum MsgRole { user, assistant, tool, compaction }   // :6
```

| Field | Dart type | JSON key | Emitted when | Default on read |
|---|---|---|---|---|
| `id` | `String` | `id` | always | required (throws if missing) |
| `seq` | `int` | `seq` | always | required |
| `role` | `MsgRole` | `role` (enum `.name`) | always | `assistant` on unknown (`:85-88`) |
| `text` | `String` | `text` | always | `''` (`:89`) |
| `image` | `MessageImage?` | `image` `{data,mime}` | **only if non-null** (`:71`) | `null` |
| `tool` | `ToolEventData?` | `tool` | **only if non-null** (`:72`) | `null` |
| `ts` | `DateTime` | `ts` (epoch **ms**, int) | always | required |
| `pending` | `bool` | `pending` | **always**, incl. `false` (`:74`) | `false` |
| `steering` | `bool` | `steering` | **only if `true`** (`:75`) | `false` |
| `tokensBefore` | `int?` | `tokens_before` | **only if non-null** (`:76`) | `null` |

Wire shape of a confirmed user row with an image:

```json
{
  "id": "cli_019ffb64-3c11-7a2e-9f00-6d2a1b3c4d5e",
  "seq": 12,
  "role": "user",
  "text": "run the tests",
  "image": { "data": "/9j/4AAQSkZJRgABAQ…", "mime": "image/jpeg" },
  "ts": 1780000000123,
  "pending": false
}
```

A steering row still in flight:

```json
{ "id": "cli_…", "seq": 13, "role": "user", "text": "actually, skip lint",
  "ts": 1780000000456, "pending": true, "steering": true }
```

A tool row (`ToolEventData.toJson`, `message_record.dart:167-174`) — note this
nested object emits **explicit `null`s**, unlike the parent:

```json
{
  "id": "toolu_01ABC",
  "seq": 14,
  "role": "tool",
  "text": "",
  "tool": {
    "tool_call_id": "toolu_01ABC",
    "tool": "bash",
    "args": { "command": "pnpm test" },
    "status": "completed",
    "result": "42 passed",
    "error": null
  },
  "ts": 1780000000789,
  "pending": false
}
```

A compaction system row:

```json
{ "id": "compaction_1780000009999", "seq": 15, "role": "compaction",
  "text": "Recapped the refactor of rooms.ts…", "ts": 1780000009999,
  "pending": false, "tokens_before": 48213 }
```

`ToolEventStatus` (`app/lib/domain/session_state.dart:168`) is
`pending | allowed | denied | expired | completed | failed`, persisted by
`.name`, with `completed` as the read fallback (`message_record.dart:180-183`).

`args` and `result` are `dynamic` — arbitrary JSON from the Pi. They round-trip
through Hive as nested `Map<dynamic, dynamic>` / `List<dynamic>`; see Trap T7.

### 1.5 `SessionIndexRecord`

`app/lib/data/local/records/session_index_record.dart:2-70`.

```dart
enum SessionActivity { idle, working }   // :2
```

`toJson` (`:44-52`) emits **all seven keys, with explicit `null`s**:

```json
{
  "epk": "v_7-_f78-_r5-Pf29fTz8vHw7-7t7Ovq6ejn5uXk4-I",
  "room_id": "019ffb64-3c11-7a2e-9f00-6d2a1b3c4d5e",
  "display_name": "",
  "status": "working",
  "last_message_at": 1780000000123,
  "last_message_preview": "run the tests",
  "session_started_at": 1780000000000
}
```

Key of that row: `sessions_index["v_7-_f78-…:019ffb64-3c11-7a2e-9f00-6d2a1b3c4d5e"]`.

Two facts about this record that the code does not advertise:

* **`display_name` is dead.** No writer ever sets it —
  `SyncService._updateIndex` (`sync_service.dart:1040-1054`) only ever mutates
  `status`, `lastMessageAt`, `lastMessagePreview`, `sessionStartedAt` (via
  `_setActivity` `:984-992` and `_applyHistory` `:752-759`). Session labels live
  in `PersistedRoom.name` / `.localName` in secure storage
  (`app/lib/pairing/storage.dart:15-118`), not here.
* **The whole box is write-only in production.** `HomeReadRepository`
  (`app/lib/data/repositories/home_read_repository.dart`) is registered in DI
  (`app/lib/config/dependencies.dart:123-124`) but `grep -rn HomeReadRepository
  lib/` finds no UI consumer. Home reads working-state from the relay's
  `room_meta.working` instead — `HomeViewModel.isRoomWorking` delegates to
  `_conn.isRoomWorking` (`app/lib/ui/home/viewmodels/home_viewmodel.dart:84-85`),
  documented at `:75` as "single source of truth: the relay broadcasts
  `meta.working`".

The native client should **not** reproduce a write-only index. §4 folds the
useful half (last message preview + timestamp, for a Home tile that works
offline) into a real table and drops the rest.

### 1.6 `RuntimeRecord` (volatile)

`app/lib/data/local/records/runtime_record.dart:5-40`.

```dart
enum RuntimeConnection { connecting, online, offline, retrying }  // :5
enum RuntimePresence   { alive, stale, unknown }                  // :7
```

```json
{ "connection": "online", "presence": "alive" }
```

Both keys always present. Read fallbacks: `connecting` / `unknown` (`:32-39`).

Written by `SyncService._writeRuntime` (`sync_service.dart:1056-1078`) — mapped
from `ConnectionManager.status` and `isRoomLive(epk, room)`. Read reactively by
`SessionReadRepository.watchRuntime` (`session_read_repository.dart:52-76`), the
one repository the chat actually uses.

This box exists **only** so the chat screen can observe connection state through
the same reactive path as messages. It is wiped at every boot precisely because
persisting it would report a stale `online`. In a native client this is state
that never needs to touch disk at all (§4.3).

---

## 2. The write model in `SyncService`

`app/lib/data/sync/sync_service.dart` — 1185 lines, and the single writer of the
durable store. Header comment (`:1-9`):

> Consumes the channel […] and writes row-granular records to Hive (v2 boxes).
> The UI never touches this stream — it reads the DB via the read repositories.
> Streaming is the ONE exception to SSOT (#7): AgentChunk deltas are coalesced
> into an in-memory `Stream<StreamingMessage?>` and NEVER written to the DB.

### 2.1 Single writer, serialized chain

```dart
// :48
Future<void> _writeChain = Future<void>.value();

// :1150-1154
Future<void> _enqueue(Future<void> Function() op) {
  final next = _writeChain.then((_) => op());
  _writeChain = next.catchError((Object _, StackTrace _) {});
  return next;
}
```

Every box mutation goes through `_enqueue`. A thrown op is swallowed so the
chain never poisons. **Requirement for the port:** all persistence runs on one
serial queue; a failed write is logged and dropped, never retried and never
allowed to stall subsequent writes.

### 2.2 In-memory ordering + dedupe index

```dart
// :43-45
final Map<String, int> _idToSeq = {};
int _nextSeq = 0;
bool _indexLoaded = false;

// :856
String _key(MsgRole role, String id) => '${role.name}:$id';
```

The dedupe key is **`<role>:<id>`, not `id`** — comment at `:41-42`: "so a user
msg and the assistant reply that shares its id don't collide." This is not
hypothetical: `AgentMessage` persists under `inReplyTo`, which *is* the user
message's id (`:472-486`). Same for tool rows, which use `toolCallId` as `id`.

`_loadIndex` (`:858-880`) rebuilds it by scanning the whole box on `activate`:

```dart
for (final k in box.keys) {
  final seq = (k as num).toInt();
  final r = MessageRecord.fromJson(_coerce(box.get(k)));
  _idToSeq[_key(r.role, r.id)] = seq;
  _nextSeq = math.max(_nextSeq, seq + 1);
  if (r.role == MsgRole.user && r.pending) _armSendTimeout(r.id, r.ts);   // :876
}
_indexLoaded = true;
```

`_upsert` (`:882-905`) is the only insert path:

```dart
final existingSeq = _idToSeq[mapKey];
if (existingSeq != null) {
  final existing = MessageRecord.fromJson(_coerce(box.get(existingSeq)));
  await box.put(existingSeq, build(existingSeq, existing).toJson());
} else {
  final seq = _nextSeq++;
  await box.put(seq, build(seq, null).toJson());
  _idToSeq[mapKey] = seq;
}
```

So `seq` is **append-position, allocated locally**, never carried on the wire.
It is stable for a row's lifetime *within one history generation* and is rewritten
wholesale by `_applyHistory` (§2.8).

### 2.3 Optimistic send

`sendMessage` (`:179-242`) writes the row **before** touching the channel:

```dart
final id = _newId();                    // 'cli_' + uuid7()  (:1167)
final now = DateTime.now();
final isSteer = streamingBehavior == UserMessageStreamingBehavior.steer;
if (epk != null) {
  await _upsert(MsgRole.user, id, (seq, _) => MessageRecord(
    id: id, seq: seq, role: MsgRole.user, text: text, image: image,
    ts: now, pending: true, steering: isSteer));
  if (!isSteer) _setWorking(true, preview: _preview(text, image), replyTo: id);
  _armSendTimeout(id, now);             // :212
}
final ch = _conn.channel;
if (ch == null) { /* offline → row stays pending, reaped by ts */ return; }
if (!isSteer) _emitStreaming(StreamingMessage(inReplyTo: id));   // :229
await ch.send(UserMessage(id: id, text: text, streamingBehavior: …, images: …));
```

Ordering is deliberate and must be preserved: **persist → arm timer → send**.
An offline send still persists a pending row (`:216-221`), which is what lets
the user see what they typed while the Pi is down.

Message ids are `cli_<uuid7>` (`:1167`). The `cli_` prefix distinguishes
app-originated ids from Pi-originated ones on the wire; keep it.

### 2.4 Echo confirmation

`case UserInput` (`:502-547`):

```dart
_pendingSendTimers.remove(id)?.cancel();           // :512 — echo ⇒ disarm reap
if (_queuedMessages.any((item) => item.id == id))  // :513-518 — leave the queue
  _setQueuedMessages([...without id]);
_upsert(MsgRole.user, id, (seq, existing) => existing != null
    ? existing.copyWith(pending: false)            // ← confirm in place
    : MessageRecord(id: id, seq: seq, role: MsgRole.user, text: text,
        image: image == null ? null : MessageImage(data: …, mime: …),
        ts: DateTime.now()));                      // ← foreign-device insert
```

Two distinct outcomes from one frame, keyed on whether the row already exists:

* **local echo** — row exists → `copyWith(pending: false)`. Text/image are *not*
  overwritten from the echo; the local copy wins.
* **foreign echo** (message typed in the Mac's terminal, or sent from another
  phone) → inserted fresh, `pending` defaults to `false`, `ts` is the **receive
  time**, not the origin time.

Then the turn state moves (`:536-547`): a `steer` echo only bumps the index
activity; a normal echo sets working + seeds a thinking cursor if one is not
already accumulating for that id.

### 2.5 The no-echo reap (20 s, silent)

`:87-94`:

> Plan/32 safety net — if the relay never echoes a sent message back, the
> optimistic `pending:true` bubble would spin forever. After this window we
> remove the bubble **SILENTLY** (no "failed" state, no spinner).

```dart
final Duration pendingSendTimeout;                     // default 20 s (:99)
final Map<String, Timer> _pendingSendTimers = {};

void _armSendTimeout(String id, DateTime ts) {         // :248-255
  _pendingSendTimers.remove(id)?.cancel();
  final remaining = pendingSendTimeout - DateTime.now().difference(ts);
  _pendingSendTimers[id] = Timer(
    remaining > Duration.zero ? remaining : Duration.zero, () => _onSendTimeout(id));
}

void _onSendTimeout(String id) {                       // :259-272
  _pendingSendTimers.remove(id);
  _removeById(id);                                     // hard delete the row
  if (_streaming?.inReplyTo == id) _emitStreaming(null);
  if (_workingReplyTo == id) _setWorking(false);
}
```

The window is measured **from the row's `ts`, not from arming** (`:250`). That
is what makes it survive process death: `_loadIndex` re-arms every pending row
it finds (`:876`), and an already-stale row fires at `Duration.zero`.

Disarm points: echo (`:512`), user cancel (`cancel()`, `:323`), `Cancelled`
frame (`:598`), session switch (`_cancelAllSendTimers`, `:171`), `dispose`
(`:1173`), `clearActiveSession` (`:390`).

`UserMsgStatus.failed` exists in the domain enum
(`domain/session_state.dart:23`) but **is never produced** — `toChatMessage`
maps `pending ? pending : confirmed` only (`message_record.dart:113`). The reap
deletes rather than marks. Keep that: a "failed" bubble the user cannot retry is
worse than a disappearing one.

> **Post-plan-61 note.** The relay now answers a dest-miss with a
> `transport_error` control frame (`PROTOCOL.md:176-187`), which is a *faster
> and more specific* signal than this 20 s backstop for the same condition. The
> native client should reap `(peer, room)`-scoped pending rows on
> `transport_error` **and** keep the ts-based timer as the backstop — the
> control frame is not correlated to a message id (it cannot be: the outer
> envelope carries none), so it can only clear the whole pending set for that
> room. `SyncService` as of this reading does not implement the
> `transport_error` path at all; `_onServerMessage` (`:458-662`) has no case for
> it. This is a **gap to close in the port**, not behaviour to mirror.

### 2.6 Streaming buffer — in-memory only

State (`:51-56`):

```dart
final StringBuffer _chunkBuffer = StringBuffer();
String _chunkReplyTo = '';
Timer? _flushTimer;
StreamingMessage? _streaming;
final StreamController<StreamingMessage?> _streamingController = …broadcast();
```

`AgentChunk` (`:459-464`) appends to the buffer and re-arms a **16 ms coalescing
timer**; it never writes to a box:

```dart
_chunkBuffer.write(delta);
_chunkReplyTo = inReplyTo;
_flushTimer?.cancel();
_flushTimer = Timer(const Duration(milliseconds: 16), _flushChunks);
_setWorking(true, replyTo: inReplyTo);
```

`_finalizeSegment()` (`:1102-1133`) is the only path from buffer to disk:

```dart
_flushTimer?.cancel(); _flushTimer = null;
if (_chunkBuffer.isNotEmpty) { /* drain into _streaming */ }
final text = _streaming?.buffer ?? '';
if (text.isNotEmpty) {
  final id = 'agent_${uuid7()}';           // ← NEW id, not inReplyTo
  _upsert(MsgRole.assistant, id, (seq, _) => MessageRecord(
      id: id, seq: seq, role: MsgRole.assistant, text: text, ts: DateTime.now()));
}
_chunkReplyTo = '';
_emitStreaming(null);
return text;
```

It is called at **two** boundaries:

* `AgentDone` (`:466-471`) — end of turn.
* `ToolRequest` (`:553`) — *before* the tool row is written, so
  "narration → command → narration" persists in chronological order instead of
  all text landing after all commands (comment `:550-552`).

Therefore one assistant turn can produce **several** assistant rows, each with a
distinct `agent_<uuid7>` id. This differs from the history replay path, where
`AgentMessageEvt` produces one row per event keyed by `inReplyTo`
(`:780-789`) — see Trap T5.

`_discardStreamingState()` (`:1135-1141`) drops the buffer without persisting;
used on `Cancelled` (`:599`), `ErrorMessage` (`:631`), remote-working-cleared
(`:1013`) and `clearActiveSession` (`:391`).

### 2.7 Compaction system rows

```dart
// :668-688
void _writeCompaction(String summary, int? tokensBefore, int? ts) {
  final id = 'compaction_${ts ?? uuid7()}';
  final when = ts != null ? DateTime.fromMillisecondsSinceEpoch(ts) : DateTime.now();
  _upsert(MsgRole.compaction, id, (seq, existing) => existing ??
      MessageRecord(id: id, seq: seq, role: MsgRole.compaction,
          text: summary, tokensBefore: tokensBefore, ts: when));
}
```

The id is **derived from the wire `ts`** so the live `Compaction` frame and its
`session_history` replay (`CompactionEvt` → `'compaction_${e.ts}'`, `:839`)
collapse to one row. `_upsert` with `existing ?? …` makes it insert-only — a
second delivery is a no-op.

When the Pi omits `ts`, the fallback `uuid7()` id can never match a replay id.
That is tolerable **only** because `_applyHistory` replaces the box wholesale
(§2.8); a merge-based store would accumulate duplicate compaction rows.
`pi-extension/src/index.ts:2344` pushes `{role:"compaction", content, timestamp: ts, tokensBefore}`
into the buffer with a timestamp always set, so in practice `ts` is present.

### 2.8 History apply — full replacement with a minimal-write diff

`_applyHistory` (`:690-760`). Three things happen, in order:

**(a) Preserve un-echoed local pendings** (`:698-707`):

```dart
final historyIds = {for (final r in rows) _key(r.role, r.id)};
for (final v in box.values) {
  final r = MessageRecord.fromJson(_coerce(v));
  if (r.role == MsgRole.user && r.pending && !historyIds.contains(_key(r.role, r.id)))
    preserved.add(r);
}
```

**(b) Compute the desired state** — history rows at `seq = index`, then the
preserved pendings appended (`:709-713`).

**(c) Reconcile with the minimum number of writes** (`:714-740`):

```dart
for (final k in box.keys.toList())
  if ((k as num).toInt() >= desired.length) await box.delete(k);
for (var i = 0; i < desired.length; i++) {
  final newJson = desired[i].toJson();
  final curRaw = box.get(i);
  final curNorm = curRaw == null ? null
      : jsonEncode(MessageRecord.fromJson(_coerce(curRaw)).toJson());
  if (curNorm != jsonEncode(newJson)) await box.put(i, newJson);
}
```

The comment (`:714-723`) explains why the diff exists: the old `clear()` +
re-put emitted ~2N watch events, which tore the chat list down to empty and
rebuilt it on **every reconnect** — the visible "embaralha e some" flicker.
A re-sent identical history now produces **zero** writes and zero emits.
Normalising through `fromJson→toJson` before comparing makes the compare
independent of Hive's map ordering.

Then `_idToSeq` / `_nextSeq` are rebuilt in memory (`:741-750`) and
`sessionStartedAt` is stamped into the index (`:752-759`).

**This is a full replacement, and the Pi sends at most 30 events.** See Trap T1.

### 2.9 Session-switch bleed prevention — two independent gates

This is the most subtle part of the write model. There are **two** gates, and
both are needed.

**Gate 1 — origin-epk gate on the frame stream** (`:410-435`, `:447-457`):

```dart
// _onStatus, on StatusOnline:
final originEpk = _conn.activePeer?.remoteEpk;
_msgSub = s.channel.serverMessages.listen((msg) => _onServerMessage(msg, originEpk), …);

// _onServerMessage:
if (originEpk != null && _activeEpk != null && originEpk != _activeEpk) return;
```

Rationale (`:414-425`): the chat calls `activate()` *before* `switchTo`, so a
straggler frame from the old peer's still-draining channel would otherwise be
written into the new session's box. The gate is on **epk only, never room** —
rooms of the same peer share one channel and `_onStatus` does not re-fire on a
same-peer room switch, so a room gate "would wrongly drop everything after
switching cwds on the same Mac".

Note the two deliberate escape hatches: `originEpk == null` (direct test calls)
and `_activeEpk == null` (cold boot before `activate`) both flow through.

**Gate 2 — active-target re-check inside every enqueued write.** Because
`_enqueue` defers work, the target can change between enqueue and execution.
Every write helper snapshots `(epk, room)` at call time and re-checks at
execution time:

```dart
// _upsert :887-892
final epk = _activeEpk; if (epk == null) return …;
final room = _activeRoomId;
return _enqueue(() async {
  final active = _activeEpk == epk && _activeRoomId == room;
  if (!active) return;
  …
});
```

Same pattern at `_loadIndex:863`, `_removeById:912`, `_clearSteeringLabel:927`,
`_clearSteeringLabels:945`, `_removePendingById:965`, `clearActiveSession:395`,
`_applyHistory:741`. `_updateIndex` (`:1040`) and `_writeRuntime` (`:1056`)
deliberately do **not** re-check: they bind the key up front and write to that
key, which is correct for an index row that belongs to the snapshotted session.

**Gate 3 (turn state, not persistence)** — `activate` calls `_resetTurnState()`
on a genuine switch (`:141-156`, `:161-177`):

```dart
Future<void> activate(String epk, String roomId) async {
  final room = roomId.isEmpty ? 'main' : roomId;
  if (_activeEpk == epk && _activeRoomId == room && _indexLoaded) return;  // idempotent
  _resetTurnState();     // flush timer, chunk buffer, workingReplyTo,
                         // queued list, ALL send timers, streaming, working flag
  _activeEpk = epk; _activeRoomId = room;
  await _loadIndex();
  _writeRuntime();
}
```

`_resetTurnState` explicitly **does not** clear the durable index (`:145-150`):
the previous room may still be running on the Pi, and Home keeps showing it via
the relay's per-room `meta.working`.

`'main'` is the fallback room id when an empty string arrives (`:38`, `:142`).
Post-plan-61 that value should never be seen from a current Pi, but legacy
`PairOk` still defaults to it (`protocol.dart:1305-1307`).

### 2.10 Queued messages — never persisted

```dart
List<QueuedMsg> _queuedMessages = const [];                    // :67
final StreamController<List<QueuedMsg>> _queuedController = …;  // :68-69
```

`queueMessage` (`:285-301`) requires a live channel (returns early when
`ch == null`), mints a `cli_<uuid7>` id, appends optimistically to the
**in-memory** list, and sends `QueuedMessageSet`. `QueuedMessageState` from the
Pi (`:488-497`) replaces the list wholesale. `clearQueuedMessage(targetId?)`
(`:305-317`) removes locally then sends `QueuedMessageClear`; a null `targetId`
clears all.

The queue is dropped on session switch (`_resetTurnState`, `:168`) and on
`clearActiveSession` (`:392`). **It does not survive backgrounding-to-kill.**
The Pi is the source of truth and re-broadcasts `QueuedMessageState` on
`session_sync` (`pi-extension/src/index.ts:4310` — `_sendQueuedState(sender)`
runs *before* the history reply).

`ExtensionUiRequest` (ask_user, plan 57) is likewise transient
(`:650-654`): "surface to the UI; never persist (it's a live request, not
history)". The Pi replays outstanding ones after every `session_sync`
(`index.ts:4344-4353`).

### 2.11 Session index maintenance

Single mutation point (`:1040-1054`):

```dart
void _updateIndex(SessionIndexRecord Function(SessionIndexRecord cur) build) {
  final epk = _activeEpk; if (epk == null) return;
  final room = _activeRoomId;
  _enqueue(() async {
    final idx = _boxes.sessionsIndexBox();
    final key = LocalBoxes.sessionKey(epk, room);
    final raw = idx.get(key);
    final cur = raw is Map ? SessionIndexRecord.fromJson(raw.cast<String, dynamic>())
                           : SessionIndexRecord(epk: epk, roomId: room);   // ← RAW epk
    await idx.put(key, build(cur).toJson());
  });
}
```

Read-modify-write, creating the row on demand. Callers:

| Caller | Effect | Line |
|---|---|---|
| `_setActivity(status, preview)` | `status`, and `lastMessageAt = now` + `lastMessagePreview` **only when `preview != null`** | `:984-992` |
| `_setWorking(on, preview, replyTo)` | wraps `_setActivity`, mirrors to `_conn.markRoomWorking`, tracks `_workingReplyTo` | `:1019-1038` |
| `_applyHistory` | `sessionStartedAt` from the wire | `:752-759` |
| `clearActiveSession` | `idx.delete(key)` | `:402` |

`_preview` (`:1162-1165`) truncates at 80 chars with an ellipsis and renders a
bare image as `'📷 Image'`.

`_setWorking(false)` passes no preview, so `copyWith(lastMessageAt: null, …)`
**preserves** the previous values — see Trap T4.

`_syncTurnStateFromRoomMeta` (`:1004-1017`) is the reconciliation against the
relay's authoritative `meta.working`: once a remote `working: true` has been
observed (`_sawRemoteWorking`), a later `false` tears down the local turn state.
This is how a turn that finished while the app was backgrounded gets cleaned up.

### 2.12 Frame → persistence map (complete)

| Frame | Durable write | Notes |
|---|---|---|
| `agent_chunk` | **none** | in-memory buffer, 16 ms coalesce (`:459`) |
| `agent_done` | assistant row iff buffer non-empty | via `_finalizeSegment` (`:466`) |
| `agent_message` | assistant row keyed `inReplyTo`, insert-only | `:472` |
| `user_input` | user row: confirm-in-place or insert | `:502` |
| `tool_request` | finalize segment, then tool row insert-only | `:549` |
| `tool_result` | tool row update (status/result/error) | `:573` |
| `approve_tool` (outbound) | tool row update (allowed/denied) | `:347-372` |
| `cancelled` | delete **pending** rows with that id only | `:597-606`, `_removePendingById` |
| `compaction` | compaction row insert-only | `:647` |
| `session_history` | **full box replacement** | `:620`, §2.8 |
| `queued_message_state` | none (in-memory) | `:488` |
| `steer_consumed` | user row: `steering → false` | `:499`, `_clearSteeringLabel` |
| `error` | assistant row `'⚠ $code: $message'`, unless `unknown_peer` | `:624-645` |
| `bye` | none; emits `PeerWentOffline`, reconnects | `:608-618` |
| `extension_ui_request` | none | `:650` |
| `pong` / `pair_ok` / `pair_error` / `action_ok` / `action_error` / `models_list` | none | `:655-661` |
| `transport_error` | **not handled** | gap, see §2.5 |

`clearActiveSession()` (`:385-404`) — called when `session_new` is acked —
cancels timers, discards streaming, clears the queue, sets working false, then
`box.clear()` + `idx.delete(sessionKey)` and resets `_idToSeq` / `_nextSeq`.

---

## 3. Traps

### T1 — Local history is destroyed on every reconnect, and is capped at 30 events

This is the single most consequential fact in this document.

* The app requests a sync 200 ms after every `StatusOnline`
  (`sync_service.dart:442-444`) and again on every chat mount
  (`chat_viewmodel.dart:185`), sending `SessionSync(id: _newId())` with **no
  `limit`** (`:381`; `SessionSync.limit` is optional, `protocol.dart:737-748`).
* The Pi clamps to its own server limit regardless of what was asked:
  ```ts
  // pi-extension/src/index.ts:4327-4332
  const serverLimit = _getSyncLimit();                 // REMOTE_PI_SYNC_LIMIT || 30
  const effectiveLimit = Math.min(requested, serverLimit);
  const slice = effectiveLimit > 0 ? allEvents.slice(-effectiveLimit) : [];
  const truncated = allEvents.length > effectiveLimit;
  ```
  `SYNC_LIMIT_DEFAULT = 30` (`index.ts:1151`).
* `_applyHistory` deletes every box key `>= desired.length` (`:724-728`).

**Net effect: a box holding 500 rows is reduced to 30 the next time the phone
reconnects.** `truncated: true` is parsed (`protocol.dart:1489-1490`) and then
never read — `grep -n "truncated\|eos" sync_service.dart` returns nothing.

Worse case: the Pi's `_messageBuffer` is process-local in-memory
(`index.ts:900`, preserved across `/remote-pi stop`+`start` but not across a Pi
process restart, `index.ts:2941-2943`). A Pi that just restarted answers
`session_sync` with `events: []` and a valid `session_started_at`; the app then
computes `desired = [preserved pendings]` and **deletes the entire local
conversation**.

`PairOk.sessionStartedAt` is documented as existing so "a future `session_sync`
can detect a Pi restart (value changed) and replace the cache instead of
appending stale events" (`protocol.dart:1266-1270`) — but no such comparison
exists anywhere in `SyncService`; `_applyHistory` writes the value
unconditionally (`:752-759`). **Documented intent and implementation disagree;
the implementation wins today, and it is wrong.**

*Requirement for the native client:* do **not** implement history apply as
truncate-to-payload. Treat `session_history` as an **authoritative window over
the tail**, and reconcile:

1. Match the incoming window against local rows by `(role, id)`.
2. If every incoming row matches a contiguous local tail → update in place, keep
   everything older.
3. If `session_started_at` differs from the stored value → the Pi restarted;
   still keep the old rows, but mark a session-boundary (a local-only divider
   row) rather than deleting.
4. Delete local rows only on an explicit `session_new` ack
   (`clearActiveSession`) or user action.
5. If `events` is empty and `session_started_at` is unchanged, do nothing.

### T2 — base64url vs standard base64: normalize once, at the boundary

`app/lib/data/transport/epk_encoding.dart:1-16` is the canonical account:

> QR payload + PairingStorage use base64url (RFC 4648 §5; `-_` chars). Relay's
> registry / hello / `peer` envelope field use base64 standard (RFC 4648 §4;
> `+/` chars, `=` padding).

`toAppEpk` returns base64url **with `=` stripped** (`:46-48`); `toStandardB64`
returns standard **with padding** (`:28-29`). Both are idempotent and both
return the input unchanged on a parse failure — a silent pass-through that can
put a malformed epk into a key.

Every storage key runs through `toAppEpk` (`boxes.dart:96-97`, `:110-111`).
Plan 61 Fase 0 fixed `sessionKey`, which previously did not
(`boxes.dart:101-109`): "the raw `<epk>:<roomId>` form let the SAME session own
two index rows — one per encoding — so the Home/chat projections disagreed
about unread state and last message."

`PROTOCOL.md:51-53`: at protocol boundaries keys are **standard, with padding**;
URL-safe forms may enter but are normalized.

*Requirement for the native client:* **store the epk as 32 raw bytes, never as a
string.** Decode at the transport boundary (accepting both alphabets, with and
without padding), encode on the way out. This removes the entire bug class
structurally instead of by discipline. §4.2 makes this a schema constraint.

### T3 — Three key spaces, three separators; only two are persistent

```
msgs_<toAppEpk(epk)>__<roomId>   Hive box filename       DURABLE
<toAppEpk(epk)>:<roomId>         index / runtime / prefs DURABLE
<toStandardB64(epk)>|<roomId>    widget keys, action cache  IN-MEMORY
```

`home_state.dart:88` and `actions_repository.dart:386` use the `|` form with the
**standard** encoding. Do not let that form reach disk. And note the `:`
separator collides with nothing only because `toAppEpk` output is base64url
(no `:`, no `/`, no `+`) — the reason `msgsBoxName` sanitizes at all
(`boxes.dart:94-95`).

`SessionIndexRecord.key` (`session_index_record.dart:26`) is
`'$epk:$roomId'` using the record's **raw, unnormalized** `epk` field, while the
row is stored under `LocalBoxes.sessionKey(epk, room)` (normalized). If a
standard-base64 epk ever reaches `_updateIndex`, `record.key != actual box key`.
`_updateIndex` seeds the record with the raw `_activeEpk` (`:1051`). Today that
epk always comes from `Preferences.selectedPeerEpk` / `PeerRecord.remoteEpk`
(both base64url), so `toAppEpk` is the identity and they agree — but the getter
is a loaded gun. Do not port it.

### T4 — `copyWith` cannot clear anything

Every record's `copyWith` uses `x ?? this.x`:

* `MessageRecord.copyWith` (`message_record.dart:46-64`) — `image`, `tool`,
  `text` cannot be cleared; `tokensBefore` is not even a parameter; `id`,
  `role`, `ts` are structurally immutable.
* `ToolEventData.copyWith` (`:154-165`) — **`result: result ?? this.result`,
  `error: error ?? this.error`**. A `tool_result` that succeeds with a null
  result after a prior failure keeps the old `result` *and the old `error`*
  (`sync_service.dart:586-593` passes both through). A retried tool cannot clear
  its error state.
* `SessionIndexRecord.copyWith` (`session_index_record.dart:28-42`) — a null
  `lastMessageAt`/`lastMessagePreview` preserves, which `_setActivity` relies on
  (`sync_service.dart:988-989`): `_setWorking(false)` must not wipe the preview.

Contrast with `PersistedRoom.copyWith` / `PeerRecord.copyWith`
(`pairing/storage.dart:88-118`, `:198-219`), which use an explicit `_unset`
sentinel (`:124`) precisely so `null` can mean *clear*.

*Requirement:* the native model must distinguish **absent** from **explicit
null** in every patch type. In Swift, `Field<T>` = `.unchanged | .set(T?)`, or
double-optional `T??` with a custom `decodeIfPresent` — never a bare optional
that conflates the two. This mirrors the wire contract for `room_meta_update`
(`PROTOCOL.md:212-213`: "campo ausente = preserva; `null` explícito = limpa").

### T5 — `id` is not unique; `(role, id)` is. And `id` means different things per role

| Role | `id` is | Source |
|---|---|---|
| `user` | the message id | `cli_<uuid7>` locally, or the Pi's id on a foreign echo |
| `assistant`, live | `agent_<uuid7>`, **minted locally** | `sync_service.dart:1116` |
| `assistant`, via `agent_message` | `inReplyTo` — **the user message's id** | `:472-486` |
| `assistant`, via history | `inReplyTo` | `:780-789` |
| `assistant`, error row | `err_<seq>` | `:641` |
| `tool` | `toolCallId` | `:549`, `:573` |
| `compaction` | `compaction_<ts>` | `:669`, `:839` |

So a user row and an assistant row routinely share the same `id` — hence
`_key(role, id)` (`:856`). A native schema must make the dedupe key
`(epk, session_id, role, msg_id)`, not `(epk, session_id, msg_id)`.

Also note the live path and the history path mint **different** assistant ids
for the same text: live text becomes `agent_<uuid7>`, replayed text becomes
`inReplyTo`. Under the current whole-box replacement that is invisible; under
the merge semantics recommended in T1 it would duplicate every assistant
message. **The reconciler must match assistant rows by `(inReplyTo, text)` or by
position within the turn, not by id.** This is the single hardest part of
implementing T1's recommendation and must be tested explicitly.

The `err_<seq>` row is a small live bug worth not reproducing: `_upsert` is
called with `_newId()` (a `cli_…` id) as the dedupe key while the persisted
record carries `id: 'err_$seq'` (`:635-645`). So `_idToSeq` holds
`assistant:cli_…` in this process and `assistant:err_<seq>` after a restart
rebuild (`:870`). Harmless only because error rows are never updated.

### T6 — `seq` is a position, not an identity

`seq` is the Hive key and is allocated locally by `_nextSeq++` (`:900`). It is
**rewritten from scratch** by `_applyHistory` (`rows[i].copyWith(seq: i)`,
`:710`). A row's `seq` therefore changes across a sync. Nothing outside the box
may reference it — no bookmarks, no scroll anchors, no notification payloads.
`_applyHistory` also assumes the key space is **dense from 0**: its delete loop
is `k >= desired.length` (`:724-727`), so any gap would leave orphans and any
sparse numbering would be misread.

Related, from `PROTOCOL.md:221`: **`started_at` is the relay registration
instant and changes on every reconnect — never a key, never a sort criterion.**
`PersistedRoom.startedAt` is persisted (`pairing/storage.dart:64`) as display
data only.

And the plan-61 rule (`PROTOCOL.md:93-95`): storage keys use `session_id` —
never the name, never the cwd, never the list index.

### T7 — Hive returns `Map<dynamic, dynamic>`, and box names are lowercased

Two Hive-specific behaviours that shaped this code and must be understood before
porting or migrating:

* **Every read comes back as `Map<dynamic, dynamic>`,** not
  `Map<String, dynamic>`. Hence `_coerce` in two places
  (`sync_service.dart:1156-1160`, `session_read_repository.dart:83-87`) and
  `.cast<String, dynamic>()` at every index read. Nested values inside
  `tool.args` / `tool.result` are *also* dynamic maps, and `ToolEventData`
  passes them through untouched (`message_record.dart:178`) — so consumers of
  `args` receive `Map<dynamic, dynamic>`, not typed JSON.
* **`Hive.openBox(name)` lowercases the name** (`hive-2.2.3/lib/src/hive_impl.dart:75`,
  `:173`, `:205`, `:219`). The on-disk file is `msgs_<epk>__<roomid>.hive` with
  the epk and room id **case-folded**. Internally consistent (lookups fold too),
  but: (a) any tool reading these files must fold too; (b) base64url and UUIDs
  are case-sensitive alphabets, so the *theoretical* collision space is real
  even if the probability is not worth designing against. A native store must
  **not** case-fold identifiers.

Also relevant to sizing: Hive boxes are append-only logs compacted only when
`deletedEntries > 60 && deletedEntries/entries > 0.15`
(`hive-2.2.3/lib/src/box/default_compaction_strategy.dart:1-9`). Because
`_applyHistory` rewrites up to 30 rows on every reconnect, the log file grows
faster than the row count suggests.

### T8 — Images are stored inline, base64, in the message row

`MessageImage.data` is "Base64-encoded image bytes (no data-URI prefix)"
(`domain/session_state.dart:29-37`), persisted verbatim inside the message JSON
(`message_record.dart:71`). The envelope cap is 4 MiB decoded
(`RELAY_MAX_CT_MIB`, `PROTOCOL.md:370-373`), so one row can be multiple
megabytes of base64 — and `SessionReadRepository.watchMessages` materialises
**every row in the box** into memory on listen (`session_read_repository.dart:27-31`).

*Requirement:* the native client stores image bytes as binary, out of the row.
§4.2 gives the schema.

### T9 — `session_history` batching: the doc says yes, the Pi says no, the app assumes no

`SessionHistory` is documented as "May arrive in batches; the final batch sets
`eos: true`" (`protocol.dart:1466-1471`). The pi-extension **never batches**: both
emit sites hard-code `eos: true` with the full slice
(`index.ts:4310-4319`, `:4336-4343`, `:4377-4382`). `SyncService` ignores `eos`
entirely and treats every `SessionHistory` as complete.

**Ground truth: the pi-extension.** A native client must send `eos: true`
expectations, but should defensively **buffer batches until `eos: true`** before
applying, so a future batching Pi does not clobber the store. Cost: one array.

### T10 — the `ctrl` room must never become a chat store

`room_id = "ctrl"` is reserved for the machine control room, `room_meta.role =
"control"` (`PROTOCOL.md:232-239`). It is a valid `(epk, room)` pair and would
happily key a message box. It must not: it carries `action_ok`/`action_error`
RPC only, and the app "não renderiza como tile de chat". The native client
should refuse to create a message store for `room_id == "ctrl"` or for any room
whose cached `role == "control"` (`PersistedRoom.role`,
`pairing/storage.dart:44`). `SyncService` has no such guard today because
`activate` is only ever called from the chat screen — a structural, not an
enforced, invariant.

### T11 — the store outlives the pairing

Nothing deletes message boxes when a peer is unpaired. `PairingStorage.wipeAll`
(`pairing/storage.dart:340-350`) erases peers and room caches from the Keychain
but touches no Hive box. `boxes.dart:35-38` states the policy for boxes orphaned
by pre-plan-61 renames: "They are unreachable, but they are the user's
conversations; deleting them to reclaim space is worse than the leak."

Keep the policy, but the native client should be able to **enumerate** orphans
(a session store with no matching pairing) so Settings can show size and offer
deletion. Hive cannot enumerate boxes; SQLite can (`SELECT` on the sessions
table).

---

## 4. Recommended native persistence design

### 4.1 Choice: SQLite, single file, WAL, accessed through the C API

**Recommendation: one SQLite database, opened via `libsqlite3` (the C API) behind
a thin Swift actor.** If a dependency is acceptable, GRDB is the same choice with
better ergonomics and identical semantics; the schema below is unchanged either
way. Do **not** use Core Data. Do **not** use files-per-session.

*Why not Core Data.* The write model in §2 is a **serialized command log with
explicit conflict rules**, not an object graph. Core Data's value is
change-tracking, faulting and relationship maintenance across a managed object
graph — none of which is needed here, and each of which costs control we need:

* Backgrounding. The app must be durable at arbitrary suspension points; §2.3
  requires the pending row to be on disk *before* the frame is sent. With Core
  Data that means `save()` on every mutation, which discards the batching that
  is Core Data's main performance argument, while keeping its overhead. With
  SQLite the same guarantee is one `INSERT` in autocommit.
* Migration. `_applyHistory`-style bulk reconciliation is a handful of
  `INSERT … ON CONFLICT DO UPDATE` and one `DELETE … WHERE seq >= ?`. In Core
  Data it is a fetch-batch-mutate loop with faulting, and a lightweight
  migration surface that is brittle across store versions.
* Determinism. §2.1 requires a single serial writer with drop-on-error. An
  `NSPersistentContainer` with a background context plus a view context gives
  two write paths and merge policies to reason about.
* Reactivity. `NSFetchedResultsController` would replace the `box.watch()`
  incremental projection, but SQLite gives the same thing with an explicit
  change token per `(epk, session_id)` published to an `AsyncStream`, which is
  simpler to test.

*Why not files.* The existing design *is* files-per-session (one Hive box each),
and that is the source of T7 (name folding), T11 (cannot enumerate) and the
inability to answer a cross-session query without opening every box — which is
exactly why `sessions_index` was invented and then went unused (§1.5). A single
relational file gives Home's cross-session query for free.

*Why SQLite specifically for this workload.* Long chat histories with
partial updates and tail reads: `LIMIT`/`OFFSET` paging with an index on
`(session_pk, seq)` reads the last 50 rows without materialising 5,000 — the
current implementation cannot (T8). Durability across suspension is a solved
problem in WAL mode. And the relay already ships SQLite
(`relay/src/mesh/store.rs`), so the operational knowledge exists in the project.

### 4.2 Schema

```sql
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;
PRAGMA synchronous = NORMAL;      -- WAL + NORMAL is durable across app kill;
                                  -- only an OS crash can lose the last commit

-- ── machines ────────────────────────────────────────────────────────────────
-- The epk as 32 RAW BYTES. This is the whole fix for Trap T2: an encoding
-- cannot be wrong if there is no encoding. Encode only at the transport edge.
CREATE TABLE machine (
  machine_pk   INTEGER PRIMARY KEY,
  epk          BLOB NOT NULL UNIQUE CHECK (length(epk) = 32),
  nickname     TEXT,
  relay_url    TEXT NOT NULL,
  paired_at    INTEGER NOT NULL           -- epoch ms
);

-- ── sessions (durable index; replaces `sessions_index`) ─────────────────────
CREATE TABLE session (
  session_pk        INTEGER PRIMARY KEY,
  machine_pk        INTEGER NOT NULL REFERENCES machine(machine_pk) ON DELETE CASCADE,
  session_id        TEXT NOT NULL,        -- == room_id, opaque, case-sensitive
  workspace_id      TEXT,                 -- sha256(realpath(cwd))[:8], may be null
  workspace_path    TEXT,                 -- canonical realpath
  display_name      TEXT,
  name_rev          INTEGER,              -- monotonic; gate renames strictly-greater
  role              TEXT,                 -- 'control' for the ctrl room; NULL for chat
  mode              TEXT,                 -- 'interactive' | 'background'
  session_started_at INTEGER,             -- from session_history / pair_ok
  last_message_at   INTEGER,
  last_message_preview TEXT,
  next_seq          INTEGER NOT NULL DEFAULT 0,   -- replaces _nextSeq
  UNIQUE (machine_pk, session_id)         -- ← the (epk, session_id) scope, enforced
);
CREATE INDEX session_by_recency ON session(last_message_at DESC);

-- ── messages ────────────────────────────────────────────────────────────────
CREATE TABLE message (
  session_pk    INTEGER NOT NULL REFERENCES session(session_pk) ON DELETE CASCADE,
  seq           INTEGER NOT NULL,         -- position, NOT identity (Trap T6)
  role          TEXT NOT NULL,            -- 'user'|'assistant'|'tool'|'compaction'
  msg_id        TEXT NOT NULL,
  text          TEXT NOT NULL DEFAULT '',
  ts            INTEGER NOT NULL,         -- epoch ms
  pending       INTEGER NOT NULL DEFAULT 0,
  steering      INTEGER NOT NULL DEFAULT 0,
  tokens_before INTEGER,                  -- compaction rows only
  in_reply_to   TEXT,                     -- assistant rows: the answered user id
  tool_call_id  TEXT,
  tool_name     TEXT,
  tool_status   TEXT,                     -- ToolEventStatus.name
  tool_args     BLOB,                     -- raw JSON bytes, opaque
  tool_result   BLOB,                     -- raw JSON bytes, opaque
  tool_error    TEXT,
  PRIMARY KEY (session_pk, seq)
) WITHOUT ROWID;

-- Trap T5: identity is (role, msg_id), not msg_id.
CREATE UNIQUE INDEX message_identity ON message(session_pk, role, msg_id);
CREATE INDEX message_pending ON message(session_pk, pending) WHERE pending = 1;

-- ── attachments (Trap T8: bytes out of the row) ─────────────────────────────
CREATE TABLE attachment (
  attachment_pk INTEGER PRIMARY KEY,
  session_pk    INTEGER NOT NULL REFERENCES session(session_pk) ON DELETE CASCADE,
  seq           INTEGER NOT NULL,
  mime          TEXT NOT NULL,
  sha256        BLOB NOT NULL,
  byte_len      INTEGER NOT NULL,
  file_name     TEXT NOT NULL,            -- relative to the blob directory
  FOREIGN KEY (session_pk, seq) REFERENCES message(session_pk, seq) ON DELETE CASCADE
);
CREATE INDEX attachment_by_message ON attachment(session_pk, seq);
```

Notes on the shape:

* `UNIQUE (machine_pk, session_id)` is the schema-level statement of the
  `rooms.ts:92-120` invariant. There is deliberately no unique index on
  `session_id` alone — two machines may legitimately emit the same id.
* `next_seq` on the session row replaces the in-memory `_nextSeq` and makes seq
  allocation crash-safe (`UPDATE session SET next_seq = next_seq + 1 …
  RETURNING next_seq - 1` inside the insert transaction).
* `tool_args` / `tool_result` stay **raw JSON bytes**. They are opaque
  pass-through values from the Pi; parsing them into typed Swift on write would
  invent a contract that does not exist and would fail on unknown tools.
* Runtime state (`RuntimeRecord`) has **no table** — see §4.3.
* Queued messages have **no table** — §2.10; the Pi re-broadcasts them.
* `display_name` here is *live*, unlike the dead Hive field (§1.5): it is the
  merge of `room_meta.name` and the local override, gated by `name_rev`.

### 4.3 What must not be persisted

| State | Where it lives natively | Why |
|---|---|---|
| connection / presence (`RuntimeRecord`) | in-memory `@Observable` | wiped at boot anyway (`boxes.dart:75`); persisting it reports stale `online` |
| streaming buffer | in-memory `String` + `AsyncStream` | `sync_service.dart:1-9` #7; a partial turn is not history |
| queued messages | in-memory array | Pi is SSOT, re-sent on every `session_sync` (`index.ts:4310`) |
| `extension_ui_request` | in-memory | live request with a TTL (`index.ts:4344-4353`) |
| `started_at` (relay registration) | in-memory only | changes every reconnect (`PROTOCOL.md:221`) |
| idempotency keys for control actions | in-memory per attempt | the **machine** owns the ledger (`daemon/sessions.ts:45`) |

### 4.4 Suggested Swift types

```swift
// Identity — no strings, so Trap T2 cannot recur.
struct MachineKey: Hashable, Sendable {
    let raw: Data                                    // exactly 32 bytes
    var standardBase64: String { raw.base64EncodedString() }          // wire
    var urlSafeBase64: String {                                        // legacy keys
        raw.base64EncodedString()
           .replacingOccurrences(of: "+", with: "-")
           .replacingOccurrences(of: "/", with: "_")
           .replacingOccurrences(of: "=", with: "")
    }
    init?(anyBase64 s: String)                       // accepts both alphabets, padded or not
}

struct SessionRef: Hashable, Sendable {
    let machine: MachineKey
    let sessionID: String                            // == room_id, opaque, case-sensitive
    var isControlRoom: Bool { sessionID == "ctrl" }  // Trap T10
}

enum MsgRole: String, Codable, Sendable { case user, assistant, tool, compaction }

enum ToolStatus: String, Codable, Sendable {
    case pending, allowed, denied, expired, completed, failed
    // decode fallback: .completed  (message_record.dart:180-183)
}

struct MessageRow: Sendable, Identifiable {
    let seq: Int                                     // position, NOT identity
    let role: MsgRole
    let msgID: String
    var identity: MessageIdentity { .init(role: role, msgID: msgID) }  // Trap T5
    var text: String
    let ts: Date
    var pending: Bool
    var steering: Bool
    var tokensBefore: Int?
    var inReplyTo: String?
    var tool: ToolPayload?
    var attachment: AttachmentRef?                   // NOT the bytes
}

// Absent vs explicit-null, for every patch type (Trap T4, PROTOCOL.md:212-213).
enum Patch<T: Sendable>: Sendable {
    case unchanged
    case set(T?)                                     // .set(nil) clears
}

struct SessionMetaPatch: Sendable {
    var displayName: Patch<String> = .unchanged
    var nameRev:     Patch<Int>    = .unchanged      // apply only if strictly greater
    var model:       Patch<String> = .unchanged
    var thinking:    Patch<String> = .unchanged
    var working:     Bool?                           // plain bool, never null (PROTOCOL.md:213)
    var role:        Patch<String> = .unchanged
}
```

`Codable` guidance:

* Do **not** use a synthesised `Codable` on `MessageRow` for the wire. The
  storage row and the wire frame have different shapes (`role` is local; the
  wire has `type`). Keep a separate wire-DTO layer and map explicitly.
* For `Patch<T>` decoding, implement `init(from:)` on the *container*: use
  `container.contains(key)` to distinguish absent from present, then
  `decodeNil(forKey:)` to distinguish explicit null. A `decodeIfPresent`
  returning `nil` conflates the two and reintroduces T4.
* Timestamps: `Int64` epoch **milliseconds** everywhere (`ts`,
  `last_message_at`, `session_started_at`, `name_rev`). Never `Date` in the
  codec — `JSONDecoder.DateDecodingStrategy` has bitten this codebase's Dart
  counterpart's assumptions before and there is no reason to reintroduce it.
* `tool_args` / `tool_result`: decode as `Data` (the raw JSON sub-tree), not as
  a typed `AnyCodable`.

### 4.5 iOS specifics

* **File location.** Put the database and blob directory in
  `Application Support/RemotePi/`, not `Documents` (which is where
  `Hive.initFlutter` lands, §1.1, and which is iCloud-backed and can be exposed
  by `UIFileSharingEnabled`). Set `isExcludedFromBackup = true` on the blob
  directory; the DB itself may be backed up if chat history in an encrypted
  backup is acceptable — note `PROTOCOL.md:406` already flags that a full
  encrypted backup can carry the Keychain.
* **Data protection.** Set `NSFileProtectionCompleteUntilFirstUserAuthentication`
  on the DB and WAL files. `…Complete` would make the store unreadable while the
  device is locked, which breaks any background/notification-service path.
* **Background durability.** WAL + `synchronous = NORMAL`, autocommit per
  logical write, plus a `sqlite3_wal_checkpoint_v2(TRUNCATE)` on
  `scenePhase == .background`. Never hold a write transaction open across an
  `await` that can be suspended.
* **Secrets stay in Keychain.** Owner-key and pairing records do **not** move
  into SQLite. Today they are `FlutterSecureStorage` under
  `dev.remotepi.peers:<epk>` / `dev.remotepi.rooms:<epk>`
  (`pairing/storage.dart:7-8`, `:283`, `:354`). Natively: Keychain for the Owner
  key (`kSecAttrSynchronizable` for the iCloud sync the product depends on,
  `PROTOCOL.md:39`), and the `machine` table for the non-secret pairing metadata
  (nickname, relay URL, paired-at). The room cache (`PersistedRoom`) becomes the
  `session` table — it is not secret and it is exactly what that table holds.
* **Size.** Attachment blobs go on the filesystem, named by
  `sha256` hex, referenced from `attachment.file_name`. Content-addressing means
  a re-sent image (history replay echoes `images` back — `_firstImage`,
  `protocol.dart:1326`, used at `:1425` and `:1509`) costs zero extra bytes.

### 4.6 Migration from Hive

**Recommendation: do not migrate. Re-sync.**

This is the same call `boxes.dart:14-38` already made for the `rp_v2` → `rp_v3`
question, and the same one plan 31 made for v1 → v2 ("v1 is abandoned without
migration (#6 — re-sync from the Pi on first boot)", `boxes.dart:3-6`).
Rationale here is stronger: the native client is a different app binary, and the
Hive box files are a Dart-specific binary log with lowercased names (T7). A
partial import loses conversations; a full import inherits every trap above.

If a migration is nonetheless required, it is a **one-way, one-time, read-only**
import: enumerate `<Documents>/rp_v2/msgs_*.hive`, parse the Hive frame format,
split the filename on `__` to recover `(epk_urlsafe, room_id)`, decode the epk
back to 32 bytes, and insert. Budget the case-folding problem (T7) as
unresolvable: you cannot recover the original case of the epk or a legacy
12-char room id from the filename. Recover it instead by matching against the
`peers` Keychain entries, which hold the un-folded epk.

---

## 5. Conformance checklist

A native implementation is correct when all of these hold:

1. Every persistent key is scoped by `(epk, session_id)`; no table, index or
   file is keyed by `session_id` alone. (`rooms.ts:114-115`)
2. The epk is stored as 32 raw bytes; base64 appears only at the transport
   boundary, in the standard alphabet with padding. (`PROTOCOL.md:51-53`)
3. Message identity is `(role, msg_id)`. A user row and an assistant row with
   the same id coexist. (`sync_service.dart:41-42`, `:856`)
4. `seq` is dense from 0, locally allocated, and referenced by nothing outside
   the message table.
5. A send persists a `pending` row **before** the frame is written to the socket,
   and arms a reap timer measured from the row's `ts`.
6. Pending rows are re-armed on store load; an already-stale row is reaped
   immediately. (`sync_service.dart:876`, `:248-255`)
7. A reap **deletes** the row silently. No "failed" bubble.
8. `transport_error` clears every pending row for that `(peer, room)` and marks
   the session offline immediately. (`PROTOCOL.md:176-187`) — *new behaviour;
   the Flutter app does not do this.*
9. `agent_chunk` never touches the store. The buffer is flushed to a row only at
   a tool boundary or `agent_done`, and only when non-empty.
10. Compaction rows are keyed by wire `ts` and are insert-only.
11. `session_history` is buffered until `eos: true`, then reconciled against
    local rows **without deleting history older than the window**. (T1, T9)
12. Session switch: in-flight turn state (buffer, working flag, queue, send
    timers) is dropped; the durable index is not. (`sync_service.dart:145-150`)
13. Every deferred write re-checks that its snapshotted `(epk, session_id)` is
    still active before touching the store. (§2.9 Gate 2)
14. Frames are dropped when their origin epk differs from the active epk;
    the gate is on epk only, never on room. (`sync_service.dart:414-425`)
15. `room_id == "ctrl"` (or `role == "control"`) never gets a message store.
16. Renames apply only when `name_rev` is strictly greater.
    (`PROTOCOL.md:215-219`)
17. Every patch type distinguishes absent (preserve) from explicit null (clear).
    (`PROTOCOL.md:212-213`)
18. Image bytes are stored out of the message row.
19. `started_at` is never a key and never a sort criterion. (`PROTOCOL.md:221`)
20. Unpairing does not delete conversations, but orphaned stores are
    enumerable and deletable from Settings. (`boxes.dart:35-38`, T11)

---

## 6. Could not be determined from the code

* **Whether losing pre-window history is intentional.** T1 is unambiguous in the
  code but I found no plan that states "the phone should only ever hold the last
  30 events". `plan/16-mirror-cache.md` is referenced by
  `protocol.dart:1466-1471` as "plan/16 D1=B" for the truncation UI decision; I
  did not read it. **Read `plan/16-mirror-cache.md` before implementing the T1
  recommendation** — if mirror-only was a deliberate product decision, the
  native design in §4 still holds but the reconciler in T1 should be dropped in
  favour of the simpler replacement.
* **Whether `REMOTE_PI_SYNC_LIMIT` is raised in any shipped configuration.** The
  default is 30 (`index.ts:1151`) and the app never sends a `limit`; I found no
  packaging that sets the env var, but I did not audit the installer scripts.
* **What the `ctrl` room's `action_ok`/`action_error` responses should persist,
  if anything.** `MachineControlRepository`
  (`app/lib/data/control/machine_control_repository.dart`) exists but I did not
  read it for this spec; the control-plane RPC state model belongs in the
  machine-control spec, not here.
* **Whether any consumer of `sessions_index` is planned.** It is write-only
  today (§1.5). §4.2 keeps the equivalent columns on `session` because an
  offline-capable Home needs them, but nothing in the current code proves the
  requirement.
