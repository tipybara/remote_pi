// ConnectionManager — lifecycle of the relay connection.
//
// State machine:
//
//   [noPeer] → connect() → [connecting] → success → [online]
//                              ↓                         ↓
//                           failure               (WS close or 2 ping misses)
//                              ↓                         ↓
//                          [offline] ←── canRetry=false
//                          [retrying] ←── backoff 1→2→5→10→30s
//                              ↓
//                          connect() → [connecting] → …
//
// Ping: every 25 s. `_missedPings` increments per tick BEFORE sending the
// next ping; inbound traffic (handled by the channel listener) resets the
// counter back to 0. Two consecutive misses (~50s of silence) → retrying.
//
// Post plan offline-loop (4 patches):
//
//  A) `_channelSub` is stored and cancelled on every transition. The old
//     channel's `onDone` (triggered by the relay killing it on duplicate
//     auth) can no longer leak into a retry storm.
//  B) `_retryAttempt` is no longer reset on factory success — only when
//     the channel listener receives real inbound traffic. With the Pi down
//     the WS keeps re-authenticating against the relay; without this fix
//     the backoff stayed pinned at 1s.
//  C) `_startPing` increments `_missedPings` per tick before sending the
//     ping. Inbound (`_watchChannel` listener) is the only path that
//     zeroes it; with the Pi offline two ticks elapse and we transition
//     to retrying without a leaky-bucket race.

import 'dart:async';

import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/epk_encoding.dart';
import 'package:app/domain/contracts/service.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';

// ---------------------------------------------------------------------------
// Status model
// ---------------------------------------------------------------------------

sealed class ConnectionStatus {
  const ConnectionStatus();
}

class StatusNoPeer extends ConnectionStatus {
  const StatusNoPeer();
}

class StatusConnecting extends ConnectionStatus {
  const StatusConnecting();
}

class StatusOnline extends ConnectionStatus {
  final IChannel channel;
  const StatusOnline(this.channel);
}

class StatusRetrying extends ConnectionStatus {
  final Duration nextRetry;
  final int attempt; // 0-based
  const StatusRetrying({required this.nextRetry, required this.attempt});
}

class StatusOffline extends ConnectionStatus {
  final String reason;
  final bool canRetry;
  const StatusOffline({required this.reason, this.canRetry = true});
}

// ---------------------------------------------------------------------------
// Backoff sequence (seconds)
// ---------------------------------------------------------------------------

const _kBackoff = [1, 2, 5, 10, 30];

Duration _backoffFor(int attempt) =>
    Duration(seconds: _kBackoff[attempt.clamp(0, _kBackoff.length - 1)]);

// ---------------------------------------------------------------------------
// Factory typedef — injectable for tests
// ---------------------------------------------------------------------------

/// Called to establish a new connection for a given peer.
/// Returns an [IChannel] on success, throws on failure.
typedef ConnectionFactory =
    Future<IChannel> Function(PeerRecord peer, CancelToken cancel);

class CancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

// ---------------------------------------------------------------------------
// ConnectionManager
// ---------------------------------------------------------------------------

class ConnectionManager extends Service {
  final ConnectionFactory _factory;
  final PairingStorage _storage;

  final _statusController = StreamController<ConnectionStatus>.broadcast();
  // Presence (plano 12): map per remote_epk + a broadcast stream the UI
  // listens to. The map is emitted whole on every change for simple
  // diffing on the consumer side.
  final Map<String, PresenceState> _presence = <String, PresenceState>{};
  final _presenceController =
      StreamController<Map<String, PresenceState>>.broadcast();
  // Plan 17 — rooms tracking. Keys are STANDARD base64 epks (matches
  // presence map). Each value is the canonical room list for that peer.
  // Plan-17 follow-up — `_roomsByPeer` is the CANONICAL set (cached +
  // currently announced). `_liveRoomIds` tracks which roomIds are
  // alive RIGHT NOW (in the relay snapshot). Rooms in `_roomsByPeer`
  // but not in `_liveRoomIds` are "offline" (last-seen state).
  final Map<String, List<RoomInfo>> _roomsByPeer = <String, List<RoomInfo>>{};
  final Map<String, Set<String>> _liveRoomIds = <String, Set<String>>{};
  final _roomsController =
      StreamController<Map<String, List<RoomInfo>>>.broadcast();
  /// Plan 61 Phase 3 — undeliverable-destination reports from the relay.
  /// Consumers (the chat writer) use it to fail outstanding sends for that
  /// session immediately instead of waiting out the no-echo timer.
  final _transportErrorController =
      StreamController<({String epk, String roomId, String reason})>
          .broadcast();
  bool _roomsRestored = false;
  ConnectionStatus _status = const StatusNoPeer();
  PeerRecord? _activePeer;
  // Plan 17 — active room on the destination Pi. 'main' is the implicit
  // default and matches the per-cwd room a Pi opens.
  //
  // Plan-61 Fase 0 — this trio IS the connection identity. `PeerRecord.roomId`
  // was demoted to a last-opened hint (see its doc): one field per pairing
  // cannot address a Mac that runs several Pi sessions, and letting a stale
  // hint win on reconnect is what moved the user to another cwd mid-chat.
  //
  //   _activeRoomId    — the room every outbound envelope is addressed to
  //   _activeRoomOwner — standard-b64 epk the pointer belongs to; when we
  //                      connect to a DIFFERENT peer the pointer is
  //                      meaningless and gets reseeded
  //   _activeRoomPinned— the pointer came from an explicit choice (user tap
  //                      via [switchRoom], or the persisted `epk:roomId`
  //                      restored in [boot]). Pinned pointers are never
  //                      overwritten by room discovery.
  String _activeRoomId = 'main';
  String? _activeRoomOwner;
  bool _activeRoomPinned = false;

  Timer? _retryTimer;
  Timer? _pingTimer;
  // Plan-18 follow-up — watchdog timer that periodically checks for
  // "stuck offline" state (active peer set but status not online and
  // no retry / connect in flight). When detected, forces a fresh
  // _scheduleRetry. Belt-and-suspenders against any code path that
  // accidentally drops the retry chain.
  Timer? _watchdogTimer;
  CancelToken? _connectCancel;
  StreamSubscription<ServerMessage>? _channelSub;
  StreamSubscription<ControlInbound>? _controlSub;
  // List currently subscribed for presence (so reconnect can replay it).
  List<String> _subscribedEpks = const [];
  int _missedPings = 0;
  int _retryAttempt = 0;
  // Tracks the last-running connect token so the watchdog can tell
  // whether a connect is in flight (without poking at the live token).
  bool _connectInFlight = false;

  // Debounce timers — relay's control-frame firehose (peer_online +
  // presence + rooms snapshots, often dozens per second when multiple
  // devices reconnect) is filtered upstream by the dedup in
  // [_onControl], but legitimate changes still arrive in tight bursts
  // (e.g. cwd switch publishes a new RoomAnnounced + RoomsSnapshot
  // back-to-back). Coalesce those into a single emit per window so
  // downstream listeners (HomeViewModel → Flutter widget rebuilds)
  // see one update instead of three.
  Timer? _presenceEmitTimer;
  Timer? _roomsEmitTimer;
  final Duration _emitDebounce;

  ConnectionManager({
    required ConnectionFactory factory,
    required PairingStorage storage,
    Duration emitDebounce = const Duration(milliseconds: 50),
  }) : _factory = factory,
       _storage = storage,
       _emitDebounce = emitDebounce {
    _startWatchdog();
  }

  /// Plan-18 follow-up — periodically checks for stuck offline state
  /// and forces a reconnect attempt. Runs every 15s. Cheap; only
  /// fires the actual `_scheduleRetry` when the conditions match.
  void _startWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      final peer = _activePeer;
      if (peer == null) return;
      if (_status is StatusOnline) return;
      if (_connectInFlight) return;
      if (_retryTimer != null) return;
      // We SHOULD be reconnecting but nothing's scheduled and no
      // attempt is in flight. Kick the retry chain.
      _scheduleRetry(peer);
    });
  }

  ConnectionStatus get status => _status;
  Stream<ConnectionStatus> get statusStream => _statusController.stream;

  IChannel? get channel =>
      _status is StatusOnline ? (_status as StatusOnline).channel : null;

  /// The peer this manager is currently driving (online, connecting, or
  /// retrying). Null when there is no active peer (NoPeer / Offline-noRetry
  /// / fresh after disconnect()).
  PeerRecord? get activePeer => _activePeer;

  // ---- Presence (plano 12) -------------------------------------------------

  /// Stream of full presence-map snapshots. Subscribers should treat each
  /// event as the canonical state for all keys present in the map.
  Stream<Map<String, PresenceState>> get presenceStream =>
      _presenceController.stream;

  /// Current presence for an epk (or [PresenceUnknown] if never observed).
  /// Accepts either url-safe (PairingStorage) or standard base64; the map
  /// itself is keyed in standard form (see [_onControl]).
  PresenceState presenceFor(String epk) =>
      _presence[toStandardB64(epk)] ?? const PresenceUnknown();

  /// Full snapshot copy of the current presence map. Keys are standard
  /// base64 — UI code that compares against `PeerRecord.remoteEpk`
  /// (url-safe) should also call [toStandardB64] before lookup. The Home
  /// tile / chat resolver do this via [presenceFor].
  Map<String, PresenceState> get presenceSnapshot =>
      Map.unmodifiable(_presence);

  // ---- Rooms (plan 17) -----------------------------------------------------

  /// Stream of full room-map snapshots. Each event is the canonical
  /// list of rooms per peer (standard-base64 keys).
  Stream<Map<String, List<RoomInfo>>> get roomsStream =>
      _roomsController.stream;

  /// Plan 61 Phase 3 — see [_transportErrorController].
  Stream<({String epk, String roomId, String reason})> get transportErrors =>
      _transportErrorController.stream;

  Map<String, List<RoomInfo>> get roomsSnapshot => _roomsSnapshot();

  /// Rooms for a single peer (or empty list if none known yet). Accepts
  /// url-safe or standard base64.
  List<RoomInfo> roomsFor(String epk) =>
      List.unmodifiable(_roomsByPeer[toStandardB64(epk)] ?? const []);

  /// Active destination room (the Pi-side room id). 'main' = default.
  String get activeRoomId => _activeRoomId;

  /// Switch the destination room WITHOUT closing the current WS. The
  /// outer envelope's `room` field on subsequent sends will carry this
  /// value. Use when the user taps a different Pi cwd on Home.
  ///
  /// Plan-61 Fase 0 — an explicit switch PINS the pointer: neither a
  /// reconnect nor room discovery may move it afterwards. [epk] names the
  /// machine the room belongs to; pass it when the caller knows the target
  /// but the manager is not connected to it yet (Home taps a tile before
  /// any WS exists), otherwise the current active peer is assumed.
  void switchRoom(String roomId, {String? epk}) {
    // Pin BEFORE the no-op guard: re-selecting the room we already point at
    // still turns a tentative hint into a user-chosen target.
    _activeRoomPinned = true;
    final owner = epk ?? _activePeer?.remoteEpk;
    if (owner != null && owner.isNotEmpty) {
      _activeRoomOwner = toStandardB64(owner);
    }
    if (roomId == _activeRoomId) {
      return;
    }
    _activeRoomId = roomId;
    final active = _activePeer;
    if (active != null) {
      _activePeer = active.copyWith(roomId: roomId);
    }
    // Push down to the underlying WS transport so outbound envelopes
    // get the right `room` value.
    final cur = _status;
    if (cur is StatusOnline) {
      _propagateActiveRoom(roomId, cur.channel);
    }
    // Re-emit the rooms snapshot so derived per-active-room state
    // (ActionsRepository.activeRoomMeta → the Quick Actions sheet's current
    // model/thinking) recomputes for the NEW room. Switching cwd-rooms on the
    // same Mac doesn't change status/rooms otherwise, so without this the
    // sheet kept showing the previous chat's model.
    if (!_roomsController.isClosed) {
      _roomsController.add(_roomsSnapshot());
    }
  }

  void _propagateActiveRoom(String roomId, IChannel link) {
    // Sends a synthetic control frame ourselves NOT to the relay — we
    // just need a hook into the transport. PlainPeerChannel exposes
    // `setActiveRoom` via a hidden interface; for typing simplicity we
    // try the dynamic call. If the transport doesn't support it, we
    // silently skip and the default 'main' room is used.
    try {
      (link as dynamic).setActiveRoom(roomId);
    } catch (_) {
      // Tests / non-WS transports — fine to ignore.
    }
  }

  /// Subscribe (or re-subscribe) the relay to push presence AND room
  /// updates for [epks] (`peer_online` / `peer_offline` and
  /// `room_announced` / `room_ended` / `rooms` snapshot). Idempotent.
  /// Stored so the subscription is replayed automatically on
  /// reconnect via [_replaySubscriptions].
  ///
  /// Both subscriptions are sent together — historically this method
  /// only emitted `subscribe_presence`, which left a hole after the
  /// first pairing: `adopt()` runs before [_BootState] has had a
  /// chance to call this with the new peer, so `_subscribedEpks` is
  /// empty and `_replaySubscriptions` short-circuits. Home then
  /// subscribed (here) for presence only — never asking the relay to
  /// push rooms — and the first session tile only appeared after the
  /// next cold start (when boot() runs the full subscribe + connect
  /// path). Keeping presence/rooms in lockstep here closes that hole.
  ///
  /// IMPORTANT: every epk on the wire is base64 STANDARD — the relay's
  /// registry is keyed by what comes in `hello.pubkey` (always standard).
  /// Callers may pass url-safe (PairingStorage default) and we normalise
  /// once here. The internal cache (`_subscribedEpks`, `_presence` keys)
  /// is also kept in standard form so lookups don't have to coerce again.
  /// See `epk_encoding.dart` for the recurring-bug history.
  void subscribeToPeers(List<String> epks) {
    final standard = epks.map(toStandardB64).toList();
    _subscribedEpks = standard;
    final link = _controlLink;
    if (link == null) {
      return;
    }
    link.sendControl(subscribePresenceFrame(standard));
    link.sendControl(subscribeRoomsFrame(standard));
    if (standard.isNotEmpty) {
      link.sendControl(presenceCheckFrame(standard));
      link.sendControl(roomsCheckFrame(standard));
    }
  }

  /// One-shot snapshot request without changing the subscription.
  void refreshPresence([List<String>? epks]) {
    final link = _controlLink;
    if (link == null) return;
    final list = (epks ?? _subscribedEpks).map(toStandardB64).toList();
    if (list.isEmpty) return;
    link.sendControl(presenceCheckFrame(list));
  }

  /// Current online channel cast to its control side, when supported.
  IControlLink? get _controlLink {
    final s = _status;
    if (s is! StatusOnline) return null;
    final ch = s.channel;
    return ch is IControlLink ? ch as IControlLink : null;
  }

  /// Open the WS and start driving a peer. Accepts an optional
  /// [preferredEpk] (plano 13) so the caller can express the user's
  /// authoritative choice — typically `Preferences.selectedPeerEpk`.
  /// When the preferred epk is not in storage (or omitted), falls back
  /// to `peers.first`.
  ///
  /// No-op when there is already an active peer (online, connecting, or
  /// retrying). In that case we still re-subscribe presence with the
  /// full peer list, since the storage may have changed.
  ///
  /// Plan-61 Fase 0 — [preferredRoomId] restores the room half of the
  /// persisted `epk:roomId` selection. Without it, boot only knew the
  /// machine and the room fell back to `PeerRecord.roomId ?? 'main'`,
  /// so a cold start reopened whichever room happened to be persisted on
  /// the pairing instead of the chat the user last had open.
  Future<void> boot({String? preferredEpk, String? preferredRoomId}) async {
    // Plan-17 follow-up — restore cached rooms from disk FIRST so
    // Home tiles render with last-known state even before the relay
    // pushes a fresh snapshot. Idempotent so reentrant boots are
    // harmless.
    await _restoreCachedRooms();
    if (_activePeer != null) {
      final peers = await _storage.listPeers();
      subscribeToPeers(peers.map((p) => p.remoteEpk).toList());
      return;
    }
    if (_status is StatusOnline) return;
    final peers = await _storage.listPeers();
    if (peers.isEmpty) {
      _emit(const StatusNoPeer());
      return;
    }
    // IMPORTANT: route through `subscribeToPeers` so the epks land in
    // `_subscribedEpks` already normalised to standard base64. Direct
    // assignment used to leave url-safe values here, and the
    // `_replaySubscriptions` call inside `_connect` would then send
    // `subscribe_presence` with the wrong encoding — relay indexes its
    // PresenceManager by standard (from `hello.pubkey`), would not
    // match, and Home dots stayed cinza intermittently (race with
    // `HomeViewModel._load` which DOES normalise). The WS isn't online
    // yet here, so subscribeToPeers will just store + defer; the actual
    // frames go out via `_replaySubscriptions` once `_connect` succeeds.
    subscribeToPeers(peers.map((p) => p.remoteEpk).toList());
    PeerRecord target;
    if (preferredEpk != null) {
      target = peers.firstWhere(
        (p) => p.remoteEpk == preferredEpk,
        orElse: () => peers.first,
      );
    } else {
      target = peers.first;
    }
    // Plan-61 Fase 0 — apply the persisted room BEFORE connecting, and pin
    // it, so `_connect` does not reseed from the hint and discovery does
    // not steal the pointer once the relay starts announcing rooms. Only
    // valid when the restored epk actually resolved to this peer.
    if (preferredRoomId != null &&
        preferredRoomId.isNotEmpty &&
        preferredEpk != null &&
        target.remoteEpk == preferredEpk) {
      _activeRoomId = preferredRoomId;
      _activeRoomOwner = toStandardB64(target.remoteEpk);
      _activeRoomPinned = true;
    }
    await _connect(target);
  }

  // Connect to a specific peer (used after fresh pairing).
  Future<void> connectTo(PeerRecord peer) => _connect(peer);

  /// Idempotent switch to another paired peer. If `peer` already matches
  /// [activePeer] AND we are Online, no-op. Otherwise tears down the
  /// current channel WITHOUT emitting a transient `StatusNoPeer` (plano
  /// 13) and starts a fresh connection — the visible transition becomes
  /// `Online → Connecting → Online`, never landing on NoPeer.
  Future<void> switchTo(PeerRecord peer) async {
    final fromEpk = _activePeer?.remoteEpk;
    if (fromEpk == peer.remoteEpk && _status is StatusOnline) {
      return;
    }
    await _teardownActive(emitNoPeer: false);
    await _connect(peer);
  }

  // Adopt a channel that was established by an external flow (e.g. the
  // pairing handshake). Skips the factory entirely — the channel is already
  // connected and ready for use.
  void adopt(IChannel channel, PeerRecord peer) {
    _cancelRetry();
    _cancelPing();
    _connectCancel?.cancel();
    _channelSub?.cancel();
    _channelSub = null;
    _controlSub?.cancel();
    _controlSub = null;
    if (_status is StatusOnline) {
      final old = (_status as StatusOnline).channel;
      // ignore: unawaited_futures
      Future(() async {
        try {
          await old.close();
        } catch (_) {}
      });
    }
    _retryAttempt = 0;
    _missedPings = 0;
    _activePeer = peer;
    _emit(StatusOnline(channel));
    _startPing(peer, channel);
    _watchChannel(peer, channel);
    _watchControl(channel);
    _replaySubscriptions();
  }

  // Permanently disconnect and go to NoPeer.
  Future<void> disconnect() => _teardownActive(emitNoPeer: true);

  /// Shared implementation between [disconnect] and [switchTo]. When
  /// [emitNoPeer] is false (switch path), the `_status` is left as-is so
  /// a subsequent `_connect` can emit `StatusConnecting` directly,
  /// avoiding the visible Online → NoPeer → Connecting flicker that used
  /// to trip up `ChatViewModel._bootstrap`.
  Future<void> _teardownActive({required bool emitNoPeer}) async {
    _cancelRetry();
    _cancelPing();
    _connectCancel?.cancel();
    _channelSub?.cancel();
    _channelSub = null;
    _controlSub?.cancel();
    _controlSub = null;
    if (_status is StatusOnline) {
      await (_status as StatusOnline).channel.close();
    }
    // Same reasoning as `_onChannelLost`: whatever the relay last told us is
    // live stops being true the moment the socket goes away.
    _clearLiveRooms();
    if (emitNoPeer) {
      _activePeer = null;
      _emit(const StatusNoPeer());
    }
    // When emitNoPeer is false, `_connect` will immediately overwrite
    // `_activePeer` and emit `StatusConnecting`, so we deliberately leave
    // the state alone here.
  }

  @override
  void dispose() {
    _cancelRetry();
    _cancelPing();
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    _presenceEmitTimer?.cancel();
    _presenceEmitTimer = null;
    _roomsEmitTimer?.cancel();
    _roomsEmitTimer = null;
    _channelSub?.cancel();
    _channelSub = null;
    _controlSub?.cancel();
    _controlSub = null;
    _statusController.close();
    _presenceController.close();
    _transportErrorController.close();
  }

  // ---------------------------------------------------------------------------

  Future<void> _connect(PeerRecord peer) async {
    _cancelRetry();
    _cancelPing();
    _connectCancel?.cancel();
    _channelSub?.cancel();
    _channelSub = null;
    _controlSub?.cancel();
    _controlSub = null;

    final token = CancelToken();
    _connectCancel = token;
    _connectInFlight = true;
    // Plan 17 fix — the destination room is settled BEFORE emitting
    // StatusOnline so the very first send after connect goes to the right
    // (peer, room) on the relay.
    //
    // Plan-61 Fase 0 — and it SURVIVES the reconnect. The pointer is only
    // reseeded when the DESTINATION changes (a different Mac), because only
    // then is the current room id meaningless; `PeerRecord.roomId` is a
    // hint used exclusively for that reseed. Two paths used to clobber a
    // live pointer here and both are closed:
    //   • WS retry after backgrounding — the `peer` argument is a stale
    //     capture from `_watchChannel` while `switchRoom` had already moved
    //     the user to another cwd (header=cwd-A, messages/sync=cwd-B);
    //   • cold start — the persisted `epk:roomId` lost to whatever room the
    //     pairing happened to carry.
    // When nothing is known yet we still fall back to `main` and let the
    // `room_announced` discovery in `_onControl` re-point us.
    final peerKey = toStandardB64(peer.remoteEpk);
    if (_activeRoomOwner != peerKey) {
      final hint = peer.roomId;
      _activeRoomId = (hint != null && hint.isNotEmpty) ? hint : 'main';
      _activeRoomOwner = peerKey;
      _activeRoomPinned = false;
    }
    _activePeer = peer.copyWith(roomId: _activeRoomId);
    _emit(const StatusConnecting());

    try {
      final ch = await _factory(peer, token);
      if (token.isCancelled) {
        await ch.close();
        return;
      }
      _missedPings = 0;
      // Push down the active room to the WS so the outer envelope
      // carries it from frame 1 (factory creates a fresh WsTransport
      // every reconnect — default _activeRoom='main' unless we set).
      _propagateActiveRoom(_activeRoomId, ch);
      _emit(StatusOnline(ch));
      _startPing(peer, ch);
      _watchChannel(peer, ch);
      _watchControl(ch);
      _replaySubscriptions();
    } catch (e) {
      if (!token.isCancelled) _scheduleRetry(peer);
    } finally {
      // Only clear the flight flag if THIS call is still the active
      // attempt — a newer _connect may have superseded us.
      if (identical(_connectCancel, token)) _connectInFlight = false;
    }
  }

  void _watchControl(IChannel ch) {
    _controlSub?.cancel();
    if (ch is! IControlLink) {
      _controlSub = null;
      return;
    }
    _controlSub = (ch as IControlLink).controlFrames.listen(_onControl);
  }

  void _onControl(ControlInbound c) {
    // Relay-reported epks are base64 STANDARD (they came in from the
    // remote peer's `hello.pubkey`). Normalise once on insert so the map
    // is always keyed in the same canonical form regardless of what we
    // received on the wire — and so consumer-side lookups via
    // `presenceFor` (which coerces) round-trip.
    //
    // Dedup contract: relay re-pushes `peer_online`, `presence`, and
    // `rooms` aggressively (every reconnect of every device, every
    // pi-extension restart, periodically as keep-alive). Without
    // de-duplication every push fires `_presenceController` /
    // `_roomsController`, which propagates to `HomeViewModel`, which
    // rebuilds the whole list, which keeps the CPU busy and the
    // device hot. Each case below only flips its `*Dirty` flag if
    // the incoming payload actually changes our cached view.
    var presenceDirty = false;
    var roomsDirty = false;
    switch (c) {
      case PeerOnline(:final peer):
        final key = toStandardB64(peer);
        final prev = _presence[key];
        const next = PresenceOnline();
        if (!_presenceEquals(prev, next)) {
          _presence[key] = next;
          presenceDirty = true;
        }
      case PeerOffline(:final peer, :final sinceTs):
        final key = toStandardB64(peer);
        final prev = _presence[key];
        final next = PresenceOffline(sinceTs: sinceTs);
        if (!_presenceEquals(prev, next)) {
          _presence[key] = next;
          presenceDirty = true;
        }
      case PresenceSnapshot(:final states):
        for (final s in states) {
          final key = toStandardB64(s.peer);
          final prev = _presence[key];
          final next = s.online
              ? PresenceOnline(sinceTs: s.sinceTs)
              : PresenceOffline(sinceTs: s.sinceTs);
          if (!_presenceEquals(prev, next)) {
            _presence[key] = next;
            presenceDirty = true;
          }
        }
      case RoomAnnounced(
        :final peer,
        :final roomId,
        :final name,
        :final cwd,
        :final startedAt,
        :final model,
        :final thinking,
        :final working,
        :final sessionId,
        :final workspacePath,
        :final nameRev,
        :final role,
      ):
        final key = toStandardB64(peer);
        final list = _roomsByPeer[key] ?? <RoomInfo>[];
        // Preserve any localName the user already set for this room
        // (long-press rename) — only the live metadata comes from the
        // wire, the rename is local-only.
        String? preservedName;
        // Plan/28 Wave D — also preserve a previously-learned thinking
        // level when the announce frame omits it. Relays that don't
        // flatten `meta.thinking` will keep `thinking == null` here;
        // the previously cached value (if any) survives until the
        // next genuine `room_meta_updated`.
        ThinkingLevel? preservedThinking;
        // Plan/32 — same preserve convention for `working`: a legacy
        // relay that omits it (null) keeps the cached value instead of
        // forcing the room back to idle.
        var preservedWorking = false;
        final existingIdx = list.indexWhere((r) => r.roomId == roomId);
        if (existingIdx >= 0) {
          preservedName = list[existingIdx].name;
          preservedThinking = list[existingIdx].thinking;
          preservedWorking = list[existingIdx].working;
        }
        final next = RoomInfo(
          roomId: roomId,
          name: preservedName ?? name,
          cwd: cwd,
          startedAt: startedAt,
          model: model,
          thinking: thinking ?? preservedThinking,
          working: working ?? preservedWorking,
          // Plan 61 Phase 1 — the session identity travels with the announce.
          sessionId: sessionId,
          workspacePath: workspacePath ?? cwd,
          nameRev: nameRev,
          role: role,
        );
        final liveAlready = _liveRoomIds[key]?.contains(roomId) ?? false;
        final identicalEntry = existingIdx >= 0 && list[existingIdx] == next;
        if (identicalEntry && liveAlready) {
          // No-op announce — relay re-broadcast. Skip to keep the UI
          // quiet.
          break;
        }
        list.removeWhere((r) => r.roomId == roomId);
        list.add(next);
        _roomsByPeer[key] = list;
        (_liveRoomIds[key] ??= <String>{}).add(roomId);
        roomsDirty = true;
        // Persist the new view so cold restart shows the same tiles.
        // ignore: unawaited_futures
        _persistRoomsForPeer(key);
        // Plan 17 fix — legacy discovery: if the active peer has no
        // persisted roomId yet (PeerRecord saved before this fix or
        // QR without `rm`), adopt the first room we learn about as
        // the canonical one. Persists the choice on the PeerRecord
        // so future reconnects address it directly.
        _maybeAdoptLegacyRoom(key, roomId);
      case RoomEnded(:final peer, :final roomId):
        final key = toStandardB64(peer);
        // Mark the room offline but KEEP it in the cached set so the
        // tile stays in Home (now grey). Removing from _liveRoomIds
        // is enough.
        final removed = _liveRoomIds[key]?.remove(roomId) ?? false;
        if (_liveRoomIds[key]?.isEmpty ?? false) {
          _liveRoomIds.remove(key);
        }
        if (removed) roomsDirty = true;
      case RoomMetaUpdated(
        :final peer,
        :final roomId,
        :final model,
        :final thinking,
        :final working,
        :final hasModel,
        :final hasThinking,
        :final name,
        :final hasName,
        :final nameRev,
      ):
        final key = toStandardB64(peer);
        final list = _roomsByPeer[key];
        if (list == null) break;
        final idx = list.indexWhere((r) => r.roomId == roomId);
        if (idx < 0) break;
        final current = list[idx];
        // Plan/28 Wave D — meta is open-ended; only update the fields
        // the broadcast actually carried. `hasModel` / `hasThinking`
        // distinguishes "field was absent from the meta envelope"
        // (preserve previous value) from "field was explicitly null"
        // (overwrite with null). Without this, a thinking-only update
        // would clobber the previously cached model with null.
        final nextModel = hasModel ? model : current.model;
        final nextThinking = hasThinking ? thinking : current.thinking;
        // Plan/32 — `working` is nullable-as-absent: null preserves the
        // cached value (e.g. a model-only update must not flip the dot),
        // non-null sets it. This is what carries the relay's
        // turn_start/turn_end broadcast to the Home dot for EVERY room.
        final nextWorking = working ?? current.working;
        // Plan 61 Phase 1 — a rename arrives as a patch on the SAME room id.
        //
        // Revision gate: accept only a strictly-newer `name_rev`. Two devices
        // of the same Owner both hold this room, and a reconnecting one
        // replays the patch it last saw — without the gate that replay would
        // drag the label back to an older name. An update that carries no
        // revision at all is taken on trust (older Pi), and a room that has no
        // stored revision yet accepts the first one it sees.
        var nextName = current.name;
        var nextNameRev = current.nameRev;
        if (hasName) {
          final stored = current.nameRev;
          final accepted =
              nameRev == null || stored == null || nameRev > stored;
          if (accepted) {
            nextName = name;
            if (nameRev != null) nextNameRev = nameRev;
          }
        }
        if (current.model == nextModel &&
            current.thinking == nextThinking &&
            current.working == nextWorking &&
            current.name == nextName &&
            current.nameRev == nextNameRev) {
          break; // dedup: nothing actually changed
        }
        list[idx] = current.copyWith(
          model: nextModel,
          thinking: nextThinking,
          working: nextWorking,
          name: nextName,
          nameRev: nextNameRev,
        );
        roomsDirty = true;
        // ignore: unawaited_futures
        _persistRoomsForPeer(key);
      // Plan 61 Phase 3 — the relay could not deliver to this destination.
      case TransportError(:final peer, :final roomId, :final reason):
        final key = toStandardB64(peer);
        // Trust it: the relay is the only party that knows whether a
        // `(peer, room)` has a live connection. Dropping the room from the
        // live set turns the tile grey NOW instead of after the ~20s no-echo
        // timeout, and the next `room_announced` puts it back.
        final live = _liveRoomIds[key];
        if (live != null && live.remove(roomId)) {
          if (live.isEmpty) _liveRoomIds.remove(key);
          roomsDirty = true;
        }
        if (!_transportErrorController.isClosed) {
          _transportErrorController.add(
            (epk: key, roomId: roomId, reason: reason),
          );
        }
      case RoomsSnapshot(:final peer, :final rooms):
        final key = toStandardB64(peer);
        // Merge snapshot into cache: add unknown rooms, refresh
        // metadata (preserving local rename + previous model when
        // the snapshot omits it), update live set.
        final existing = _roomsByPeer[key] ?? <RoomInfo>[];
        final byId = {for (final r in existing) r.roomId: r};
        for (final r in rooms) {
          final preservedName = byId[r.roomId]?.name ?? r.name;
          final preservedModel = r.model ?? byId[r.roomId]?.model;
          // Plan/28 Wave D — same convention as model: keep the
          // previously-known thinking when the snapshot omits it.
          final preservedThinking = r.thinking ?? byId[r.roomId]?.thinking;
          byId[r.roomId] = RoomInfo(
            roomId: r.roomId,
            name: preservedName,
            cwd: r.cwd,
            startedAt: r.startedAt,
            model: preservedModel,
            thinking: preservedThinking,
            // Plan/32 — the snapshot is authoritative for live state:
            // `rooms_of` reads the current registry meta, so its
            // `working` reflects the latest turn_start/turn_end.
            working: r.working,
            // Plan 61 Phase 1 — same preserve convention as model/thinking:
            // an older relay omits these, and dropping them would make a
            // known session look legacy again (and lose its workspace row).
            sessionId: r.sessionId ?? byId[r.roomId]?.sessionId,
            workspacePath:
                r.workspacePath ?? r.cwd ?? byId[r.roomId]?.workspacePath,
            nameRev: r.nameRev ?? byId[r.roomId]?.nameRev,
            role: r.role ?? byId[r.roomId]?.role,
          );
        }
        final newList = byId.values.toList();
        final newLive = rooms.map((r) => r.roomId).toSet();
        final liveChanged = !_setEquals(
          newLive,
          _liveRoomIds[key] ?? const <String>{},
        );
        final listChanged = !_roomListEquals(newList, existing);
        if (!liveChanged && !listChanged) {
          // Relay re-emitted a snapshot identical to what we already
          // have. Skip — no listeners need to know.
          break;
        }
        _roomsByPeer[key] = newList;
        _liveRoomIds[key] = newLive;
        roomsDirty = true;
        // ignore: unawaited_futures
        _persistRoomsForPeer(key);
        // Same legacy-discovery hook as RoomAnnounced.
        if (rooms.isNotEmpty) {
          _maybeAdoptLegacyRoom(key, rooms.first.roomId);
        }
    }
    if (presenceDirty) _schedulePresenceEmit();
    if (roomsDirty) _scheduleRoomsEmit();
  }

  /// Coalesce presence emits within `_emitDebounce`. Each call resets
  /// the timer; the snapshot sent at fire time is whatever `_presence`
  /// looks like then (always the latest view).
  void _schedulePresenceEmit() {
    _presenceEmitTimer?.cancel();
    _presenceEmitTimer = Timer(_emitDebounce, () {
      _presenceEmitTimer = null;
      if (_presenceController.isClosed) return;
      _presenceController.add(Map.unmodifiable(_presence));
    });
  }

  /// Same shape as [_schedulePresenceEmit] but for the rooms stream.
  void _scheduleRoomsEmit() {
    _roomsEmitTimer?.cancel();
    _roomsEmitTimer = Timer(_emitDebounce, () {
      _roomsEmitTimer = null;
      if (_roomsController.isClosed) return;
      _roomsController.add(_roomsSnapshot());
    });
  }

  /// Value-equality helper for [PresenceState] — the sealed classes
  /// don't define their own `==`, and identity equality misfires
  /// because we construct fresh `PresenceOnline(...)` / `PresenceOffline(...)`
  /// objects on each control frame.
  bool _presenceEquals(PresenceState? a, PresenceState? b) {
    if (a == null) return b == null;
    if (b == null) return false;
    if (a.runtimeType != b.runtimeType) return false;
    if (a is PresenceOnline && b is PresenceOnline) {
      return a.sinceTs == b.sinceTs;
    }
    if (a is PresenceOffline && b is PresenceOffline) {
      return a.sinceTs == b.sinceTs;
    }
    // PresenceUnknown has no fields — same type ⇒ equal.
    return true;
  }

  /// `Set<String>` deep-equality (Dart sets don't have value-equality
  /// by default).
  bool _setEquals(Set<String> a, Set<String> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (final x in a) {
      if (!b.contains(x)) return false;
    }
    return true;
  }

  /// `List<RoomInfo>` order-insensitive equality keyed by `roomId`.
  /// `RoomInfo` already defines value `==`.
  bool _roomListEquals(List<RoomInfo> a, List<RoomInfo> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    final byIdB = {for (final r in b) r.roomId: r};
    for (final r in a) {
      if (byIdB[r.roomId] != r) return false;
    }
    return true;
  }

  Map<String, List<RoomInfo>> _roomsSnapshot() => Map.unmodifiable(
    _roomsByPeer.map((k, v) => MapEntry(k, List<RoomInfo>.unmodifiable(v))),
  );

  /// Returns `true` if `roomId` is currently announced live for the
  /// peer (the relay's last `room_announced` / `rooms` push included
  /// it). Cached rooms not in the live set return `false`. Used by
  /// the chat AppBar to render the online dot.
  ///
  /// Plan-18 follow-up: gated by `_status is StatusOnline`. When the
  /// WS to the relay drops (retrying / offline), we have no fresh
  /// signal that any room is reachable, so EVERY room is reported
  /// offline regardless of the cached `_liveRoomIds`. Home tiles +
  /// chat AppBar flip to grey immediately. On reconnect, the relay
  /// re-pushes the rooms snapshot which repopulates the live set
  /// and tiles go green again.
  bool isRoomLive(String epk, String roomId) {
    if (_status is! StatusOnline) return false;
    final live = _liveRoomIds[toStandardB64(epk)];
    return live != null && live.contains(roomId);
  }

  /// Plan/32 — `true` when the relay's last room-meta broadcast for
  /// `(epk, roomId)` carried `working: true` (an in-flight agent turn).
  /// Unlike the DB session-index signal (which only covers the single
  /// connected room), this reflects EVERY subscribed room because the
  /// relay broadcasts `meta.working` to all room subscribers — the same
  /// fan-out as presence. Drives the blue Home dot on non-active
  /// sessions.
  ///
  /// Gated on `StatusOnline` (same as [isRoomLive]): a dropped WS means
  /// we have no fresh signal, so we report not-working and let the tile
  /// fall back to the amber "reconnecting" / grey state.
  bool isRoomWorking(String epk, String roomId) {
    if (_status is! StatusOnline) return false;
    final list = _roomsByPeer[toStandardB64(epk)];
    if (list == null) return false;
    for (final r in list) {
      if (r.roomId == roomId) return r.working;
    }
    return false;
  }

  /// App-side correction for the connected room's working flag.
  ///
  /// The relay remains the source for non-active rooms, but the active channel
  /// also sees the actual `user_input` / `agent_done` frames. Use that local
  /// observation as a backstop so a missed or delayed `meta.working=false`
  /// broadcast cannot leave the active chat/Home tile stuck as working.
  void markRoomWorking(String epk, String roomId, bool working) {
    final key = toStandardB64(epk);
    final list = _roomsByPeer[key];
    if (list == null) return;
    final idx = list.indexWhere((r) => r.roomId == roomId);
    if (idx < 0 || list[idx].working == working) return;
    list[idx] = list[idx].copyWith(working: working);
    _scheduleRoomsEmit();
    // ignore: unawaited_futures
    _persistRoomsForPeer(key);
  }

  /// Plan-17 follow-up — hydrate `_roomsByPeer` from disk on boot so
  /// Home tiles persist across cold starts even before the relay
  /// pushes a fresh snapshot. Idempotent.
  Future<void> _restoreCachedRooms() async {
    if (_roomsRestored) return;
    _roomsRestored = true;
    final peers = await _storage.listPeers();
    for (final p in peers) {
      final cached = await _storage.loadRooms(p.remoteEpk);
      if (cached.isEmpty) continue;
      final key = toStandardB64(p.remoteEpk);
      _roomsByPeer[key] = cached
          .map(
            (c) => RoomInfo(
              roomId: c.roomId,
              name: c.localName ?? c.name,
              cwd: c.cwd,
              startedAt: c.startedAt,
              model: c.model,
              // Plan 61 Phase 1 — restore the session identity too. Without
              // `nameRev` here a stale rename patch landing right after boot
              // would be accepted (no stored revision to compare against) and
              // revert a label the user already changed.
              sessionId: c.sessionId,
              workspacePath: c.workspacePath ?? c.cwd,
              nameRev: c.nameRev,
              role: c.role,
            ),
          )
          .toList();
      // Note: nothing in _liveRoomIds yet — those rooms are "offline"
      // until the relay announces them again.
    }
    if (!_roomsController.isClosed) {
      _roomsController.add(_roomsSnapshot());
    }
  }

  Future<void> _persistRoomsForPeer(String peerKey) async {
    final peers = await _storage.listPeers();
    PeerRecord? match;
    for (final p in peers) {
      if (toStandardB64(p.remoteEpk) == peerKey) {
        match = p;
        break;
      }
    }
    if (match == null) return;
    final list = _roomsByPeer[peerKey] ?? const <RoomInfo>[];
    // Read the current on-disk localNames so we don't drop the user's
    // long-press rename when we re-persist in response to a wire
    // metadata refresh.
    final existing = await _storage.loadRooms(match.remoteEpk);
    final localById = {
      for (final p in existing)
        if (p.localName != null && p.localName!.isNotEmpty)
          p.roomId: p.localName!,
    };
    final persisted = list
        .map(
          (r) => PersistedRoom(
            roomId: r.roomId,
            name: r.name,
            cwd: r.cwd,
            startedAt: r.startedAt,
            localName: localById[r.roomId],
            model: r.model,
            // Plan 61 Phase 1 — the session identity has to survive a cold
            // start, otherwise Home would render every cached room as legacy
            // (no workspace row) until the relay re-announced it.
            sessionId: r.sessionId,
            workspacePath: r.workspacePath,
            nameRev: r.nameRev,
            role: r.role,
          ),
        )
        .toList();
    await _storage.saveRooms(match.remoteEpk, persisted);
  }

  /// Plan-17 follow-up — long-press menu support. Override the
  /// display name of a single room locally (Pi never sees this).
  /// Reflects immediately in the rooms snapshot.
  Future<void> setRoomLocalName(String epk, String roomId, String? name) async {
    final key = toStandardB64(epk);
    final list = _roomsByPeer[key];
    if (list == null) return;
    final idx = list.indexWhere((r) => r.roomId == roomId);
    if (idx < 0) return;
    final old = list[idx];
    // Use copyWith so EVERY field (model, cwd, startedAt, …) is
    // preserved. The previous explicit constructor call dropped
    // `model`, which made the tile subtitle fall back to
    // "Last Paired: …" right after a rename — bug.
    list[idx] = old.copyWith(
      name: (name != null && name.isNotEmpty) ? name : old.name,
    );
    // Persist with localName so it survives cold start.
    final cached = await _storage.loadRooms(epk);
    final updated = cached
        .map((c) => c.roomId == roomId ? c.copyWith(localName: name) : c)
        .toList();
    await _storage.saveRooms(epk, updated);
    if (!_roomsController.isClosed) {
      _roomsController.add(_roomsSnapshot());
    }
  }

  /// Plan-17 follow-up — delete a cached room locally. Only safe when
  /// the room is offline (not live); UI gates this.
  Future<void> deleteCachedRoom(String epk, String roomId) async {
    final key = toStandardB64(epk);
    final list = _roomsByPeer[key];
    if (list != null) {
      list.removeWhere((r) => r.roomId == roomId);
      if (list.isEmpty) _roomsByPeer.remove(key);
    }
    final cached = await _storage.loadRooms(epk);
    final pruned = cached.where((c) => c.roomId != roomId).toList();
    await _storage.saveRooms(epk, pruned);
    if (!_roomsController.isClosed) {
      _roomsController.add(_roomsSnapshot());
    }
  }

  /// Room discovery — points an UNPINNED connection at a room the relay
  /// actually announced:
  ///   1. Update `_activeRoomId` so outbound envelopes are routed.
  ///   2. Push the change down to the WS transport.
  ///   3. Persist it as `PeerRecord.roomId` — the last-opened hint used to
  ///      seed the next cold start when prefs carry no room.
  void _maybeAdoptLegacyRoom(String peerKey, String discoveredRoom) {
    final active = _activePeer;
    if (active == null) return;
    if (toStandardB64(active.remoteEpk) != peerKey) return;
    // Plan-61 Fase 0 — an explicit selection wins, always. Previously the
    // guard was `active.roomId != null`, i.e. "has this pairing ever had a
    // room persisted"; that conflated a stale hint with a user choice and,
    // once set, also froze the pointer onto a room the Pi may no longer
    // serve.
    if (_activeRoomPinned) return;
    // Unpinned pointer = a hint. Keep it while the relay says it is alive;
    // re-point only when it is not (dead hint, or the implicit 'main').
    final live = _liveRoomIds[peerKey];
    if (live != null && live.contains(_activeRoomId)) return;
    if (_activeRoomId == discoveredRoom) return;
    _activeRoomId = discoveredRoom;
    _activeRoomOwner = peerKey;
    final cur = _status;
    if (cur is StatusOnline) {
      _propagateActiveRoom(discoveredRoom, cur.channel);
    }
    // Persist asynchronously — failure here is non-fatal (next discovery
    // round will re-adopt).
    final updated = active.copyWith(roomId: discoveredRoom);
    _activePeer = updated;
    // ignore: unawaited_futures
    _storage
        .savePeer(updated)
        .then((_) {})
        .catchError((Object e, StackTrace _) {});
  }

  /// On (re)connect, re-send the last subscribe_presence so the relay
  /// pushes updates again for our current peer list. Plan 17: also
  /// subscribe to rooms for the same peer set — the relay pushes
  /// `room_announced` / `room_ended` / `rooms` (snapshot) the same way
  /// presence does. Single subscription covers all per-cwd sessions on
  /// every paired Mac.
  void _replaySubscriptions() {
    if (_subscribedEpks.isEmpty) return;
    final link = _controlLink;
    if (link == null) return;
    link.sendControl(subscribePresenceFrame(_subscribedEpks));
    link.sendControl(presenceCheckFrame(_subscribedEpks));
    link.sendControl(subscribeRoomsFrame(_subscribedEpks));
    link.sendControl(roomsCheckFrame(_subscribedEpks));
  }

  void _watchChannel(PeerRecord peer, IChannel ch) {
    _channelSub?.cancel();
    _channelSub = ch.serverMessages.listen(
      (msg) {
        // Real inbound — the Pi is alive and reachable. Safe to reset
        // both the ping miss counter and the retry backoff.
        final wasMissed = _missedPings;
        if (wasMissed > 0) {}
        if (_retryAttempt != 0) {}
        _missedPings = 0;
        _retryAttempt = 0;
      },
      onError: (_) => _onChannelLost(peer, ch),
      onDone: () => _onChannelLost(peer, ch),
    );
  }

  void _onChannelLost(PeerRecord peer, IChannel ch) {
    if (_status is! StatusOnline) return;
    final cur = (_status as StatusOnline).channel;
    if (!identical(cur, ch)) {
      // Stale: this onDone came from a channel we already replaced. The
      // relay typically kicks the previous WS when our retry authenticates
      // again — that close would otherwise trigger an immediate
      // self-sustaining retry loop.
      return;
    }
    _cancelPing();
    // Plan 61 — the live set is now stale.
    //
    // `_liveRoomIds` is what the relay last told us was up. Losing the WS
    // means we have no fresh signal about ANY room, and `isRoomLive` is
    // already gated on `StatusOnline` so nothing renders green meanwhile.
    // But the stale set survived the outage, so the first moment the WS came
    // back — before the relay's `rooms` snapshot landed — every previously
    // live room flipped green again, including ones whose Pi had exited
    // during the outage. Clearing here makes the reconnect honest: rooms go
    // green only once the relay says so.
    _clearLiveRooms();
    _scheduleRetry(peer);
  }

  /// Drop the cached "currently live" set. The cached room LIST
  /// (`_roomsByPeer`) is deliberately kept — those are the tiles Home shows
  /// offline/grey, and the user can still open them to read history.
  void _clearLiveRooms() {
    if (_liveRoomIds.isEmpty) return;
    _liveRoomIds.clear();
    _scheduleRoomsEmit();
  }

  void _scheduleRetry(PeerRecord peer) {
    final delay = _backoffFor(_retryAttempt);
    _emit(StatusRetrying(nextRetry: delay, attempt: _retryAttempt));
    // Cancel any previous timer before scheduling — prevents the
    // "two timers firing back-to-back" footgun.
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      _retryAttempt++;
      _connect(peer);
    });
  }

  void _startPing(PeerRecord peer, IChannel ch) {
    _pingTimer = Timer.periodic(const Duration(seconds: 25), (_) async {
      if (_status is! StatusOnline) return;
      // Plan-18 follow-up — DECOUPLED Pi-liveness from WS-liveness.
      //
      // Before: 3 missed Pongs from the Pi triggered `_onChannelLost`,
      // which tore down the WS to the relay. The relay only frees
      // the slot when its own `sink.send` returns an error (which
      // can take MINUTES on certain network failures — half-open
      // TCP), so every reconnect attempt during that window hit
      // `room_already_open` and the app sat permanently offline.
      // [ORCH:19-heartbeat-investigate] reported this.
      //
      // After: the WS↔relay keep-alive is now exclusively handled
      // by RFC 6455 Ping/Pong (IOWebSocketChannel.pingInterval).
      // Protocol Ping/Pong here is a Pi-LIVENESS probe — when it
      // fails, we mark the active room as offline locally so Home /
      // chat reflect it; the WS stays online for presence updates
      // and other rooms. A real WS failure surfaces via the catch
      // below (ping SEND fails) or via the channel listener's
      // onError / onDone, both of which still trigger
      // `_onChannelLost`.
      _missedPings++;
      if (_missedPings == 3) {
        _markActiveRoomOffline();
        // No `return` — keep firing pings. When Pi comes back, the
        // inbound Pong (or any other frame) resets _missedPings via
        // _watchChannel, and `room_announced` repopulates
        // _liveRoomIds → tile + AppBar flip back to green
        // automatically.
      }
      try {
        final id = _newId();
        await ch.send(Ping(id: id));
      } catch (e) {
        _cancelPing();
        _onChannelLost(peer, ch);
      }
    });
  }

  /// Plan-18 follow-up — when the Pi stops responding to protocol
  /// Pings, mark its current cwd-room as offline locally so the UI
  /// reflects the degraded state. The WS↔relay stays up.
  void _markActiveRoomOffline() {
    final activeEpk = _activePeer?.remoteEpk;
    if (activeEpk == null) return;
    final key = toStandardB64(activeEpk);
    final live = _liveRoomIds[key];
    if (live == null || !live.contains(_activeRoomId)) return;
    live.remove(_activeRoomId);
    if (live.isEmpty) _liveRoomIds.remove(key);
    if (!_roomsController.isClosed) {
      _roomsController.add(_roomsSnapshot());
    }
  }

  void _cancelRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  void _cancelPing() {
    _pingTimer?.cancel();
    _pingTimer = null;
    _missedPings = 0;
  }

  void _emit(ConnectionStatus s) {
    // Plan-18 follow-up — when the connection-status flips ON or OFF
    // StatusOnline, every room's "live" answer changes too (see
    // `isRoomLive` gate). Re-emit the rooms snapshot so subscribers
    // (Home, Chat AppBar) re-evaluate dot color immediately, without
    // waiting for the relay's next push.
    final wasOnline = _status is StatusOnline;
    final nowOnline = s is StatusOnline;
    _status = s;
    if (!_statusController.isClosed) _statusController.add(s);
    if (wasOnline != nowOnline && !_roomsController.isClosed) {
      _roomsController.add(_roomsSnapshot());
    }
  }

  static int _idCounter = 0;
  static String _newId() => 'ping_${++_idCounter}';
}
