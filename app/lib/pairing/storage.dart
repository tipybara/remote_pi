import 'dart:convert';

import 'package:app/protocol/protocol.dart' show PiHarness;
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const _kPeersService = 'dev.remotepi.peers';
const _kRoomsService = 'dev.remotepi.rooms';

/// Plan-17 follow-up — persisted snapshot of every room we have ever
/// learned about for a peer (relay-announced via `room_announced` /
/// `rooms` push). Allows Home to keep showing the same tiles after a
/// cold start while the relay is still warming up + lets the user
/// open a chat offline and read history.
class PersistedRoom {
  final String roomId;
  final String? name;
  final String? cwd;
  final int startedAt;
  /// Local-only override for [name]. When non-null, takes precedence
  /// in UI (long-press rename).
  final String? localName;
  /// Plan 18 — last-known model the Pi-extension is running with.
  /// Persisted so the subtitle survives cold starts.
  final String? model;

  /// Plan 61 Phase 1 — the Pi session UUID this room is keyed by (equal to
  /// [roomId] for a Phase-1 Pi; `null` for a legacy `sha256(cwd[,name])`
  /// room). Persisted so a cold start can tell the two generations apart
  /// before the relay has announced anything.
  final String? sessionId;

  /// Plan 61 Phase 1 — canonical workspace path. Persisted so Home can render
  /// its Device → Workspace → Session grouping from cache, offline.
  final String? workspacePath;

  /// Plan 61 Phase 1 — revision of [name]. Persisted so a stale rename patch
  /// arriving right after a cold start cannot revert a newer label.
  final int? nameRev;

  /// Plan 61 Phase 3 — `'control'` for a machine gateway room. Persisted so a
  /// cached control room is still filtered out of Home before the relay
  /// re-announces it.
  final String? role;

  const PersistedRoom({
    required this.roomId,
    required this.startedAt,
    this.name,
    this.cwd,
    this.localName,
    this.model,
    this.sessionId,
    this.workspacePath,
    this.nameRev,
    this.role,
  });

  Map<String, dynamic> toJson() => {
    'room_id': roomId,
    'name': name,
    'cwd': cwd,
    'started_at': startedAt,
    'local_name': localName,
    'model': model,
    if (sessionId != null) 'session_id': sessionId,
    if (workspacePath != null) 'workspace_path': workspacePath,
    if (nameRev != null) 'name_rev': nameRev,
    if (role != null) 'role': role,
  };

  factory PersistedRoom.fromJson(Map<String, dynamic> j) => PersistedRoom(
    roomId: j['room_id'] as String,
    name: j['name'] as String?,
    cwd: j['cwd'] as String?,
    startedAt: (j['started_at'] as num).toInt(),
    localName: j['local_name'] as String?,
    model: j['model'] as String?,
    sessionId: j['session_id'] as String?,
    // Rooms cached before plan 61 only have `cwd`; it holds the same path.
    workspacePath: (j['workspace_path'] as String?) ?? (j['cwd'] as String?),
    nameRev: (j['name_rev'] as num?)?.toInt(),
    role: j['role'] as String?,
  );

  PersistedRoom copyWith({
    String? name,
    String? cwd,
    int? startedAt,
    Object? localName = _unset,
    Object? model = _unset,
    Object? sessionId = _unset,
    Object? workspacePath = _unset,
    Object? nameRev = _unset,
    Object? role = _unset,
  }) => PersistedRoom(
    roomId: roomId,
    name: name ?? this.name,
    cwd: cwd ?? this.cwd,
    startedAt: startedAt ?? this.startedAt,
    localName: identical(localName, _unset)
        ? this.localName
        : localName as String?,
    model: identical(model, _unset)
        ? this.model
        : model as String?,
    sessionId: identical(sessionId, _unset)
        ? this.sessionId
        : sessionId as String?,
    workspacePath: identical(workspacePath, _unset)
        ? this.workspacePath
        : workspacePath as String?,
    nameRev: identical(nameRev, _unset) ? this.nameRev : nameRev as int?,
    role: identical(role, _unset) ? this.role : role as String?,
  );
}

// ---------------------------------------------------------------------------
// PeerRecord — persisted per pairing
// ---------------------------------------------------------------------------

// Sentinel for nullable copyWith parameters that need to distinguish
// "keep current" (omit) from "set to null" (pass `null` explicitly).
const Object _unset = Object();

class PeerRecord {
  // base64 Ed25519 pubkey of the Pi — the only peer identifier post-rollback.
  final String remoteEpk;
  final String sessionName;
  final String relayUrl;
  final String pairedAt; // ISO-8601
  // Local-only display label (Pi does not know about this). Renders in
  // place of [sessionName] when set; null = use sessionName everywhere.
  final String? nickname;
  /// Last-opened room **hint** for this machine — NOT connection
  /// identity.
  ///
  /// Plan-61 Fase 0 (was: "the room this pairing is bound to"). A Mac
  /// runs many Pi sessions; a single field per pairing can never express
  /// that, and treating it as the connection key is what made a cold
  /// start reopen the wrong chat. The authoritative selection now lives
  /// in `Preferences.selectedRoomRaw` (`epk:roomId`) and, at runtime, in
  /// `ConnectionManager.activeRoomId`.
  ///
  /// This field survives only as a fallback for the first connect when
  /// prefs carry no room (fresh install, legacy value, peer never
  /// opened). `null` = no hint yet; discovery adopts the first announced
  /// room.
  final String? roomId;
  /// Plan/27 Wave A — agent harness reported by the PC at pair time.
  /// Surfaced as the "via Pi coding agent" subtitle on the PiCard.
  /// `null` for PeerRecords saved before the field existed; consumers
  /// fall back to [PiHarness.piCodingAgentUnknown] so the UI never
  /// renders an empty subtitle.
  final PiHarness? harness;

  const PeerRecord({
    required this.remoteEpk,
    required this.sessionName,
    required this.relayUrl,
    required this.pairedAt,
    this.nickname,
    this.roomId,
    this.harness,
  });

  Map<String, dynamic> toJson() => {
    'remote_epk': remoteEpk,
    'session_name': sessionName,
    'relay_url': relayUrl,
    'paired_at': pairedAt,
    'nickname': nickname,
    'room_id': roomId,
    if (harness != null) 'harness': harness!.toJson(),
  };

  factory PeerRecord.fromJson(Map<String, dynamic> j) {
    final harnessJson = j['harness'];
    return PeerRecord(
      remoteEpk: j['remote_epk'] as String,
      sessionName: j['session_name'] as String,
      relayUrl: j['relay_url'] as String,
      pairedAt: j['paired_at'] as String,
      // Legacy records (saved before plan 10.3) have no 'nickname' field.
      nickname: j['nickname'] as String?,
      // Legacy records (saved before plan 17 fix) have no 'room_id'.
      // Stays null until ConnectionManager discovers it via subscribe_rooms.
      roomId: j['room_id'] as String?,
      // Plan/27 Wave A — harness was added later. Records saved before
      // it lack the field; null falls back to the default at consumer
      // side.
      harness: harnessJson is Map<String, dynamic>
          ? PiHarness.fromJson(harnessJson)
          : null,
    );
  }

  PeerRecord copyWith({
    String? sessionName,
    // Sentinel-typed so the caller can pass `nickname: null` to clear.
    Object? nickname = _unset,
    Object? roomId = _unset,
    Object? harness = _unset,
  }) => PeerRecord(
    remoteEpk: remoteEpk,
    sessionName: sessionName ?? this.sessionName,
    relayUrl: relayUrl,
    pairedAt: pairedAt,
    nickname: identical(nickname, _unset)
        ? this.nickname
        : nickname as String?,
    roomId: identical(roomId, _unset)
        ? this.roomId
        : roomId as String?,
    harness: identical(harness, _unset)
        ? this.harness
        : harness as PiHarness?,
  );

  @override
  bool operator ==(Object other) =>
      other is PeerRecord &&
      other.remoteEpk == remoteEpk &&
      other.sessionName == sessionName &&
      other.relayUrl == relayUrl &&
      other.pairedAt == pairedAt &&
      other.nickname == nickname &&
      other.roomId == roomId &&
      other.harness == harness;

  @override
  int get hashCode => Object.hash(
        remoteEpk,
        sessionName,
        relayUrl,
        pairedAt,
        nickname,
        roomId,
        harness,
      );
}

// ---------------------------------------------------------------------------
// PairingStorage
// ---------------------------------------------------------------------------

/// Pairing storage with change notification.
///
/// Mutations to the peer set (`savePeer`, `deletePeer`, `wipeAll`) call
/// `notifyListeners()` so any UI watching the storage (HomeViewModel,
/// SettingsViewModel) can refresh without manual plumbing between
/// screens. Read methods do not notify.
///
/// Plan-61 Fase 0 — [saveRooms] is the one mutation that stays silent:
/// see its doc comment. Rooms reach the UI through
/// `ConnectionManager.roomsStream`, not through this notifier.
class PairingStorage extends ChangeNotifier {
  final FlutterSecureStorage _store;

  /// Plan 24 — optional fire-and-forget hook that runs after every
  /// peer mutation (`savePeer` / `deletePeer`). The `MeshSyncService`
  /// registers this so changes propagate to the relay's
  /// `mesh_versions` row in the background. Failures of the hook are
  /// the hook's problem — local mutation is already committed and
  /// observers were notified by the time the hook fires.
  ///
  /// Room mutations are intentionally NOT hooked — rooms are a
  /// per-device cache, not synced membership.
  void Function()? _onPeersMutated;

  PairingStorage([FlutterSecureStorage? store])
    : _store = store ?? const FlutterSecureStorage();

  /// Plug the mesh-publish callback. The hook fires after the local
  /// write completes and after [notifyListeners], so UI sees the
  /// change before the relay does. Pass `null` to detach.
  void attachPeerMutationHook(void Function()? hook) {
    _onPeersMutated = hook;
  }

  // ---- Peer records --------------------------------------------------------

  String _peerKey(String remoteEpk) => '$_kPeersService:$remoteEpk';

  Future<void> savePeer(PeerRecord record) async {
    await _writePeer(record);
    _onPeersMutated?.call();
  }

  /// Same as [savePeer] but skips the mutation hook. Used by the
  /// MeshSyncService when applying a verified mesh blob to the local
  /// cache — without this we'd round-trip back to the relay
  /// (pull→apply→savePeer→hook→publish) and a race could publish an
  /// empty members list (see plan/24-fix-app-publish-race).
  Future<void> savePeerSilent(PeerRecord record) => _writePeer(record);

  Future<PeerRecord?> loadPeer(String remoteEpk) async {
    final raw = await _store.read(key: _peerKey(remoteEpk));
    if (raw == null) return null;
    return PeerRecord.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> deletePeer(String remoteEpk) async {
    await _erasePeer(remoteEpk);
    _onPeersMutated?.call();
  }

  /// Same as [deletePeer] but skips the mutation hook — see
  /// [savePeerSilent] for the rationale.
  Future<void> deletePeerSilent(String remoteEpk) => _erasePeer(remoteEpk);

  Future<void> _writePeer(PeerRecord record) async {
    await _store.write(
      key: _peerKey(record.remoteEpk),
      value: jsonEncode(record.toJson()),
    );
    notifyListeners();
  }

  Future<void> _erasePeer(String remoteEpk) async {
    await _store.delete(key: _peerKey(remoteEpk));
    notifyListeners();
  }

  Future<List<PeerRecord>> listPeers() async {
    final all = await _store.readAll();
    final prefix = '$_kPeersService:';
    return all.entries
        .where((e) => e.key.startsWith(prefix))
        .map((e) => PeerRecord.fromJson(
          jsonDecode(e.value) as Map<String, dynamic>,
        ))
        .toList();
  }

  /// Wipe every peer + every persisted room map. Used by the
  /// Owner-key bridge when iCloud / Backup sync brings a different
  /// Owner-pk — the previous device's peer list is meaningless for
  /// the newly-synced identity, so we start clean rather than risk
  /// connecting against stale `remote_epk`s.
  Future<void> wipeAll() async {
    final all = await _store.readAll();
    final prefixes = ['$_kPeersService:', '$_kRoomsService:'];
    for (final key in all.keys) {
      if (prefixes.any(key.startsWith)) {
        await _store.delete(key: key);
      }
    }
    notifyListeners();
  }

  // ---- Rooms (plan 17 follow-up) -----------------------------------------

  String _roomsKey(String remoteEpk) => '$_kRoomsService:$remoteEpk';

  /// Persist the full set of known rooms for a peer. Replaces any
  /// previously stored set. Called on every room-state change in
  /// ConnectionManager so a cold start can reflect the same view.
  ///
  /// Plan-61 Fase 0 — deliberately does **not** `notifyListeners()`. This
  /// is the highest-frequency write in the app (every `room_meta_update`,
  /// i.e. every turn_start/turn_end of every subscribed room re-persists
  /// the cache). The only storage listener is `HomeViewModel`, whose
  /// callback runs a full `_load()` — rebuilding the entire Home list
  /// from scratch several times per turn. Home already receives the very
  /// same data reactively through `ConnectionManager.roomsStream`, so the
  /// notification was pure churn *and* the trigger for the visible
  /// "sessions jumping" behaviour. Peer mutations (`savePeer` /
  /// `deletePeer` / `wipeAll`) still notify — those genuinely change the
  /// peer set Home reads from storage.
  Future<void> saveRooms(String remoteEpk, List<PersistedRoom> rooms) async {
    await _store.write(
      key: _roomsKey(remoteEpk),
      value: jsonEncode(rooms.map((r) => r.toJson()).toList()),
    );
  }

  Future<List<PersistedRoom>> loadRooms(String remoteEpk) async {
    final raw = await _store.read(key: _roomsKey(remoteEpk));
    if (raw == null) return const [];
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .map((e) => PersistedRoom.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> deleteRooms(String remoteEpk) async {
    await _store.delete(key: _roomsKey(remoteEpk));
    notifyListeners();
  }
}
