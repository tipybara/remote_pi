// Plan/31 — local SSOT box layer (Hive v2).
//
// Three families of box in a NEW namespace (`rp_v2`); v1 (`session_history`,
// the blob snapshot) is abandoned without migration (#6 — re-sync from the Pi
// on first boot). The `runtime` box is VOLATILE: wiped on every boot (#3) so
// connection/presence never report stale online across restarts.
//
//   DURABLE  msgs_<epk>__<roomId>   key = seq (int)        → MessageRecord
//   DURABLE  sessions_index         key = <epk>:<roomId>   → SessionIndexRecord
//   VOLATILE runtime  (wiped@boot)  key = <epk>:<roomId>   → RuntimeRecord
//
// `<epk>` is ALWAYS the url-safe form (`toAppEpk`) — see [LocalBoxes.sessionKey].
//
// ── plan 61 Phase 2: why there is no `rp_v3` ────────────────────────────────
//
// Plan 61 Phase 2 listed "Hive `rp_v3` keyed by `session_id`, messages
// `msgs_<session_id>`". That was the plan's assumed MECHANISM for reaching
// session-keyed storage; Phase 1 reached the same place more cheaply, so the
// namespace bump was deliberately not taken. Recorded here because the
// difference is not obvious from the code alone:
//
//  * Phase 1 made the Pi key its relay room by the session UUID
//    (`room_id == session_id`). `<roomId>` above therefore ALREADY is the
//    session id for every Phase-1 session — the keys are session-keyed today,
//    with no data movement.
//  * A namespace bump would mean copying every message box to a new
//    directory. That is pure migration risk (a partial copy loses
//    conversations) for zero change in what the keys mean.
//  * Dropping `<epk>` from the key — the literal `msgs_<session_id>` shape —
//    is actively unsafe while legacy rooms exist. Their ids are 12-char
//    truncated digests, and the audit flags collision across machines as a
//    real (if unlikely) failure mode: two Macs would then share one message
//    box. The epk costs nothing and removes that class entirely.
//
// Boxes orphaned by PRE-Phase-1 renames (history written under a room id no
// tile points at any more) are left in place. They are unreachable, but they
// are the user's conversations; deleting them to reclaim space is worse than
// the leak.

import 'package:app/data/transport/epk_encoding.dart';
import 'package:hive_flutter/hive_flutter.dart';

const String _kNamespace = 'rp_v2';
const String _kSessionsIndex = 'sessions_index';
const String _kRuntime = 'runtime';

/// Facade over the v2 Hive boxes. A single instance is shared by the
/// [SyncService] (writer) and the read repositories (readers) so they observe
/// the same open box objects (`Hive.openBox` is idempotent).
class LocalBoxes {
  static bool _initialized = false;

  /// Open the v2 namespace and the always-on boxes; **wipe `runtime`** before
  /// anything subscribes (#3 / Risk 2). Call once during bootstrap, before
  /// `runApp` and before any read-repo is constructed.
  static Future<void> init() async {
    if (_initialized) return;
    await Hive.initFlutter(_kNamespace);
    await _openCommon();
    _initialized = true;
  }

  /// For tests: open against a custom directory. Unlike [init] this always
  /// re-opens + wipes the volatile box, so a second call simulates a restart
  /// (and lets tests assert the wipe).
  static Future<void> initForTest(String path) async {
    if (!_initialized) Hive.init(path);
    await _openCommon();
    _initialized = true;
  }

  static Future<void> _openCommon() async {
    await Hive.openBox<dynamic>(_kSessionsIndex);
    final runtime = await Hive.openBox<dynamic>(_kRuntime);
    await runtime.clear(); // VOLATILE — zero on boot (#3)
  }

  Box<dynamic> sessionsIndexBox() => Hive.box<dynamic>(_kSessionsIndex);

  Box<dynamic> runtimeBox() => Hive.box<dynamic>(_kRuntime);

  /// Per-session message box. Lazily opened; idempotent (returns the already
  /// open box on subsequent calls).
  Future<Box<dynamic>> msgsBox(String epk, String roomId) =>
      Hive.openBox<dynamic>(msgsBoxName(epk, roomId));

  /// Synchronous accessor for a msgs box known to be open already.
  Box<dynamic> openMsgsBox(String epk, String roomId) =>
      Hive.box<dynamic>(msgsBoxName(epk, roomId));

  bool isMsgsBoxOpen(String epk, String roomId) =>
      Hive.isBoxOpen(msgsBoxName(epk, roomId));

  /// `:` and the epk's `/`+`=` would break the on-disk filename — sanitise to
  /// the url-safe, unpadded epk form (same approach as the v1 store).
  static String msgsBoxName(String epk, String roomId) =>
      'msgs_${toAppEpk(epk)}__$roomId';

  /// Key of a session row in `sessions_index` / `runtime`.
  ///
  /// Plan-61 Fase 0 — the epk is normalised with [toAppEpk], exactly like
  /// [msgsBoxName] already did. Callers reach here with whatever encoding
  /// their source used (prefs and `PeerRecord` carry base64url; anything
  /// derived from a relay frame carries base64 standard), and the raw
  /// `<epk>:<roomId>` form let the SAME session own two index rows —
  /// one per encoding — so the Home/chat projections disagreed about
  /// unread state and last message. Existing rows are unaffected: every
  /// current writer already passes the url-safe form, for which
  /// [toAppEpk] is the identity.
  static String sessionKey(String epk, String roomId) =>
      '${toAppEpk(epk)}:$roomId';
}
