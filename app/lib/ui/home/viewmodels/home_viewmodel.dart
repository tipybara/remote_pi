import 'dart:async';

import 'package:app/data/actions/actions_repository.dart';
import 'package:app/data/control/machine_control_repository.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/data/transport/epk_encoding.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/core/viewmodel/viewmodel.dart';
import 'package:app/ui/home/states/home_state.dart';

/// HomeViewModel — passive list of paired peers + live presence dots
/// + rooms discovered on each peer (plan 17). A single tile per
/// (peer, room).
///
/// The WS connection is owned by [ConnectionManager] from app boot (plano
/// 12). Home only:
///   - reads the peer list from storage
///   - watches `presenceStream` + `roomsStream` to render dots / rooms
///     in real time
///   - writes [Preferences.selectedRoom] when the user taps a tile so
///     `/chat` knows which (peer, room) to address
class HomeViewModel extends ViewModel<HomeState> {
  final PairingStorage _storage;
  final Preferences _prefs;
  final ConnectionManager _conn;

  /// Plan 61 Phase 2 — used to send an authoritative `session_rename` to the
  /// Pi. Optional: when absent (older tests, or a build with no actions
  /// stack) [renameRoom] degrades to the historical local-only rename.
  final IActionsRepository? _actions;

  /// Plan 61 Phase 3 — talks to a machine's `ctrl` room to list workspaces and
  /// spawn background sessions. Optional for the same reason as [_actions].
  final IMachineControlRepository? _control;
  StreamSubscription<Map<String, PresenceState>>? _presenceSub;
  StreamSubscription<Map<String, List<RoomInfo>>>? _roomsSub;
  StreamSubscription<ConnectionStatus>? _statusSub;
  bool _relayConnected = false;
  bool _disposed = false;

  HomeViewModel(
    this._storage,
    this._prefs,
    this._conn, [
    this._actions,
    this._control,
  ]) : super(const HomeLoading()) {
    _relayConnected = _conn.status is StatusOnline;
    _load();
    _presenceSub = _conn.presenceStream.listen(_onPresence);
    _roomsSub = _conn.roomsStream.listen(_onRooms);
    _statusSub = _conn.statusStream.listen(_onStatus);
    // Settings (rename / revoke) and pairing flow both write through
    // PairingStorage; listening here keeps Home in sync without manual
    // notifications between screens.
    _storage.addListener(_onStorageChanged);
  }

  void _onStorageChanged() {
    if (_disposed) return;
    _load();
  }

  /// `true` when the app's WS to the relay is alive (StatusOnline).
  /// When `false`, every room dot should render in the "reconnecting"
  /// colour (amber) regardless of `isRoomLive`, because the app has
  /// no fresh signal on any room.
  bool get isRelayConnected => _relayConnected;

  /// `true` when `(epk, roomId)`'s agent is currently mid-turn. Drives
  /// the blue "working" dot on the Home tile.
  ///
  /// Plan/32 — single source of truth: the relay broadcasts `meta.working`
  /// (turn_start/turn_end from the Pi-extension) to ALL subscribed rooms,
  /// exactly like presence, so this reflects EVERY session — connected or
  /// not. We deliberately do NOT OR the DB session index here: that row is
  /// only kept fresh for the currently-connected room (the SyncService
  /// writer follows the active connection), so a session that finishes
  /// while the app is on a DIFFERENT chat would never get its index idled
  /// and the dot would stay blue forever. The relay flag has no such blind
  /// spot.
  bool isRoomWorking(String epk, String roomId) =>
      _conn.isRoomWorking(epk, roomId);

  Future<void> _load() async {
    final peers = await _storage.listPeers();
    if (_disposed) return;
    if (peers.isEmpty) {
      emit(const HomeNoPeer());
      return;
    }
    // Make sure the relay is pushing updates for everyone we know about;
    // the call is idempotent so this is safe even mid-session. The same
    // subscribe also covers rooms (plan 17 — replay block in
    // ConnectionManager sends both presence and rooms subscribes).
    _conn.subscribeToPeers(peers.map((p) => p.remoteEpk).toList());
    // Plan-61 Fase 0 — PRESERVE the presence tab. `_load` runs on every
    // PairingStorage mutation (`savePeer` from room adoption / open, the
    // per-turn room metadata persistence, mesh sync, …), i.e. many times
    // per minute while a session is working. Rebuilding `HomeList` with
    // the default `HomeFilter.online` silently threw the user back to
    // the Online tab mid-scroll — the "sessions jumping" report. The
    // filter is user state, not storage state: it only ever changes via
    // [setFilter].
    final prev = state;
    emit(
      HomeList(
        peers: peers,
        statusByEpk: _conn.presenceSnapshot,
        roomsByPeer: _conn.roomsSnapshot,
        filter: prev is HomeList ? prev.filter : HomeFilter.online,
        // Grouping is persisted, so the FIRST load takes it from prefs rather
        // than defaulting — otherwise the chosen layout would visibly snap
        // back to the default for one frame on every cold start.
        grouping: prev is HomeList ? prev.grouping : _prefs.homeGrouping,
      ),
    );
  }

  void _onPresence(Map<String, PresenceState> snapshot) {
    final s = state;
    if (s is! HomeList) return;
    emit(s.copyWith(statusByEpk: snapshot));
  }

  void _onRooms(Map<String, List<RoomInfo>> snapshot) {
    final s = state;
    if (s is! HomeList) return;
    emit(s.copyWith(roomsByPeer: snapshot));
  }

  void _onStatus(ConnectionStatus status) {
    final next = status is StatusOnline;
    if (next == _relayConnected) return;
    _relayConnected = next;
    // Trigger a re-render of any HomeList so tiles re-evaluate dot
    // colour (room-live vs reconnecting).
    final s = state;
    if (s is HomeList) {
      // emit a duplicate-looking HomeList so context.watch() triggers
      // even though peers / roomsByPeer / presence didn't change.
      // Preserve `filter` — otherwise a status flip would silently reset
      // the user's tab back to the Online default (and, because the new
      // object would then differ, actually fire that reset).
      emit(
        HomeList(
          peers: s.peers,
          statusByEpk: s.statusByEpk,
          roomsByPeer: s.roomsByPeer,
          filter: s.filter,
          grouping: s.grouping,
        ),
      );
    }
  }

  /// Plan-38 Fase 3 — switch the presence tab. No reload: it only swaps the
  /// `filter` in state so [visibleItems] re-derives. No-op when the state
  /// isn't a list or the filter is unchanged.
  void setFilter(HomeFilter filter) {
    final s = state;
    if (s is! HomeList) return;
    if (s.filter == filter) return;
    emit(s.copyWith(filter: filter));
  }

  /// `true` when `(epk, roomId)` is live on the relay AND the relay itself
  /// is reachable. The single source of truth for the Online/Offline split.
  /// [ConnectionManager.isRoomLive] is already gated on `StatusOnline`, so
  /// the `_relayConnected &&` is belt-and-suspenders that also documents
  /// intent: "online" requires a live relay.
  bool _online(HomeItem it) =>
      _relayConnected && _conn.isRoomLive(it.peer.remoteEpk, it.room.roomId);

  /// Plan-38 Fase 3 — the items the current [HomeList.filter] keeps. A pure
  /// view over `state.items()`; returns `const []` outside a list state.
  List<HomeItem> get visibleItems {
    final s = state;
    if (s is! HomeList) return const [];
    final all = s.items(normalizeEpk: normalizeEpkForLookup);
    return switch (s.filter) {
      HomeFilter.all => all,
      HomeFilter.online => all.where(_online).toList(),
      HomeFilter.offline => all.where((i) => !_online(i)).toList(),
    };
  }

  /// Plan 61 Phase 2 (follow-up) — how deep Home groups the list right now.
  HomeGrouping get grouping {
    final s = state;
    return s is HomeList ? s.grouping : _prefs.homeGrouping;
  }

  /// Change the grouping depth. Persists the choice, then re-emits so the list
  /// re-renders. No reload: the grouped data is the same either way — only the
  /// headers differ.
  Future<void> setGrouping(HomeGrouping value) async {
    final s = state;
    if (s is HomeList && s.grouping == value) return;
    await _prefs.setHomeGrouping(value);
    if (_disposed) return;
    final cur = state;
    if (cur is HomeList) emit(cur.copyWith(grouping: value));
  }

  /// Plan 61 Phase 2 — [visibleItems] regrouped as Device → Workspace →
  /// Session for rendering. Pure view: the filter is applied first, then the
  /// surviving rows are grouped, so an empty workspace or device never leaves
  /// a dangling header on the Offline/Online tabs.
  List<HomeDevice> get visibleGroups {
    final s = state;
    if (s is! HomeList) return const [];
    return s.groups(only: visibleItems);
  }

  /// Plan-38 Fase 3 — per-tab counts for the filter badges. Independent of
  /// the active tab (each badge always shows its own slice's size).
  ({int all, int online, int offline}) get counts {
    final s = state;
    if (s is! HomeList) return (all: 0, online: 0, offline: 0);
    final all = s.items(normalizeEpk: normalizeEpkForLookup);
    final online = all.where(_online).length;
    return (all: all.length, online: online, offline: all.length - online);
  }

  /// Remember which (peer, room) the user picked. Falls back to
  /// `roomId='main'` when the caller doesn't supply one (legacy /
  /// pre-room-announce). Also flips the ConnectionManager's active
  /// room so subsequent sends carry the right outer envelope.
  ///
  /// Plan-24 follow-up: when the peer record in storage has no
  /// `roomId` yet (post-mesh-restore: the mesh blob doesn't carry
  /// per-device room data, so `PeerRecord.roomId` is null until the
  /// relay announces the room and `ConnectionManager._maybeAdoptLegacyRoom`
  /// catches up), persist the tapped roomId on the PeerRecord too.
  /// Without this, the next cold-start reads `peer.roomId=null` →
  /// `ConnectionManager._connect` falls back to room `'main'` → Pi
  /// never sees the frame → ChatViewModel sits on Connecting/offline
  /// even though the WS is alive.
  Future<void> openSession(String epk, {String? roomId}) async {
    final peers = await _storage.listPeers();
    if (_disposed) return;
    final match = peers.where((p) => p.remoteEpk == epk).cast<PeerRecord?>();
    if (match.isEmpty) return;
    final peer = match.first!;
    final effectiveRoom = (roomId == null || roomId.isEmpty) ? 'main' : roomId;
    await _prefs.setSelectedRoom(epk: epk, roomId: effectiveRoom);
    if (peer.roomId != effectiveRoom) {
      // ignore: unawaited_futures
      _storage.savePeer(peer.copyWith(roomId: effectiveRoom));
    }
    // Tell the manager which Pi-side room to address. Safe to call
    // even if the manager is mid-connect (room is applied on the next
    // send and any active StatusOnline channel).
    //
    // Plan-61 Fase 0 — pass `epk` explicitly: Home taps a tile for a
    // machine the manager may not be connected to yet, and the pin has to
    // be attributed to THAT machine, otherwise the following `_connect`
    // would treat the pointer as belonging to someone else and reseed it
    // from the stale `PeerRecord.roomId` hint.
    _conn.switchRoom(effectiveRoom, epk: epk);
  }

  /// Helper for widgets: pass a peer's url-safe epk → returns standard
  /// for indexing into [HomeList.roomsByPeer] / [HomeList.statusByEpk].
  static String normalizeEpkForLookup(String epk) => toStandardB64(epk);

  /// Rooms known for `epk` (live + cached). Home uses it to resolve a
  /// freshly-created session to the room the relay actually announced.
  List<RoomInfo> roomsFor(String epk) => _conn.roomsFor(epk);

  /// Plan-17 follow-up — `true` if `(epk, roomId)` is currently live on
  /// the relay. Drives the presence dot on each tile (per-room, not
  /// per-peer anymore).
  bool isRoomLive(String epk, String roomId) => _conn.isRoomLive(epk, roomId);

  /// Long-press menu — rename a session.
  ///
  /// Plan 61 Phase 2 — this is authoritative now. It used to write only into
  /// the phone's own cache, so the Pi never learned the new label and a second
  /// device of the same Owner kept showing the old one. The rename goes to the
  /// Pi, which persists it and publishes a `room_meta_update`; the relay fans
  /// that out to every device, including this one.
  ///
  /// Returns `null` on success, or a human-readable reason when the Pi could
  /// not be reached / refused. The local cache is updated either way so the
  /// tile reflects the user's intent immediately — but on failure the caller
  /// is told, instead of the old behaviour where a rename that never left the
  /// device looked identical to one that did.
  Future<String?> renameRoom(String epk, String roomId, String? name) async {
    // Local write first: the relay broadcast will overwrite it with the
    // authoritative value moments later, and this keeps the tile responsive.
    await _conn.setRoomLocalName(epk, roomId, name);

    final trimmed = name?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      // Clearing the label is a local-only affordance — there is no "unset the
      // name" on the wire (the Pi always has one).
      return null;
    }
    final actions = _actions;
    if (actions == null) return null;
    if (!_conn.isRoomLive(epk, roomId)) {
      return 'Session is offline — renamed on this device only.';
    }
    // Send what we know: `session_id` pins the target so a frame that races a
    // session replacement is refused, and `rev` lets the Pi detect that
    // another device renamed first.
    RoomInfo? room;
    for (final r in _conn.roomsFor(epk)) {
      if (r.roomId == roomId) {
        room = r;
        break;
      }
    }
    try {
      await actions.renameSession(
        roomId: roomId,
        displayName: trimmed,
        sessionId: room?.sessionId,
        rev: room?.nameRev,
      );
      return null;
    } on ActionFailure catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }

  // ── Plan 61 Phase 3 — create a session on a machine ──────────────────────

  /// `true` when this build can drive a machine's control plane at all.
  bool get canCreateRemoteSessions => _control != null;

  /// Machines the user could create a session on right now.
  ///
  /// Only the CONNECTED peer qualifies: the control frame rides the active
  /// WebSocket, so a machine we are not dialled into cannot be asked. Returning
  /// the honest subset keeps the picker from offering a choice that would fail.
  List<PeerRecord> get machinesAcceptingSessions {
    final s = state;
    if (s is! HomeList || _control == null) return const [];
    final active = _conn.activePeer?.remoteEpk;
    if (active == null || !_relayConnected) return const [];
    return s.peers
        .where((p) => toStandardB64(p.remoteEpk) == toStandardB64(active))
        .toList();
  }

  /// Folders on [epk] that will accept a new session.
  Future<List<RemoteWorkspace>> listRemoteWorkspaces(String epk) async {
    final control = _control;
    if (control == null) return const [];
    return control.listWorkspaces(epk);
  }

  /// Ask [epk] to spawn a background session in [workspaceId].
  ///
  /// Returns the new session id on success, or a human-readable error.
  ///
  /// [idempotencyKey] must be minted ONCE per user intent and reused across
  /// retries — the machine records it, so a retry replays the original outcome
  /// instead of spawning a second process. The caller owns the key for exactly
  /// that reason.
  ///
  /// The session id comes from the machine; the app never derives a room id
  /// itself. Use [waitForSessionOnline] before opening the chat: `action_ok`
  /// only means "spawn requested", not "room is up".
  Future<({String? sessionId, String? error})> createRemoteSession({
    required String epk,
    required String workspaceId,
    required String idempotencyKey,
    String? displayName,
  }) async {
    final control = _control;
    if (control == null) return (sessionId: null, error: 'unavailable');
    try {
      final id = await control.createSession(
        epk: epk,
        workspaceId: workspaceId,
        idempotencyKey: idempotencyKey,
        displayName: displayName,
      );
      return (sessionId: id, error: null);
    } on ActionFailure catch (e) {
      return (sessionId: null, error: e.message);
    } catch (e) {
      return (sessionId: null, error: e.toString());
    }
  }

  /// Wait until the relay announces `(epk, sessionId)` as live.
  ///
  /// `create_session` returns as soon as the supervisor has forked `pi`; the
  /// room only exists once that child connects and says hello. Opening the chat
  /// before then lands on a room the relay does not know, and the first message
  /// is dropped.
  ///
  /// Returns `true` when the room came up, `false` on timeout — the session may
  /// still appear later, so the caller should say "starting…", not "failed".
  Future<bool> waitForSessionOnline(
    String epk,
    String sessionId, {
    Duration timeout = const Duration(seconds: 45),
  }) async {
    if (_conn.isRoomLive(epk, sessionId)) return true;
    final done = Completer<bool>();
    late final StreamSubscription<Map<String, List<RoomInfo>>> sub;
    final timer = Timer(timeout, () {
      if (!done.isCompleted) done.complete(false);
    });
    sub = _conn.roomsStream.listen((_) {
      if (_conn.isRoomLive(epk, sessionId) && !done.isCompleted) {
        done.complete(true);
      }
    });
    try {
      return await done.future;
    } finally {
      timer.cancel();
      await sub.cancel();
    }
  }

  /// Long-press menu — delete a cached room locally. Caller should
  /// gate on `!isRoomLive` (only offline rooms can be removed).
  Future<void> deleteRoom(String epk, String roomId) =>
      _conn.deleteCachedRoom(epk, roomId);

  @override
  void dispose() {
    _disposed = true;
    _presenceSub?.cancel();
    _roomsSub?.cancel();
    _statusSub?.cancel();
    _storage.removeListener(_onStorageChanged);
    super.dispose();
  }
}
