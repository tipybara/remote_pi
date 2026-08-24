import 'dart:async';

import 'package:app/data/actions/actions_repository.dart' show ActionFailure;
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/data/transport/epk_encoding.dart';
import 'package:app/data/transport/peer_channel.dart';
import 'package:app/domain/contracts/repository.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/protocol/uuid7.dart';

/// Plan 61 Phase 3 — talks to a paired machine's control plane.
///
/// Every other repository addresses a *session*. This one addresses the
/// **machine**: the supervisor's permanent `ctrl` room, which exists whether or
/// not any chat process is up. That is the whole point — discovery used to run
/// Pi → `room_announced` → app, so with no child there was no room and the
/// phone had no way to ask for one. You needed a Pi to create a Pi.
///
/// Frames are addressed at [kControlRoomId] WITHOUT moving the connection's
/// active room, so asking a machine for its workspaces never disturbs the chat
/// the user has open.
abstract class IMachineControlRepository extends Repository {
  /// Folders on [epk] that will accept a new session. v1 = the machine's
  /// registered daemons; there is no way to name an arbitrary path.
  Future<List<RemoteWorkspace>> listWorkspaces(String epk);

  /// Spawn a background session in [workspaceId] and return its id.
  ///
  /// [idempotencyKey] must be STABLE across retries of one user intent —
  /// see [CreateSession]. Callers that mint a fresh key per attempt get a
  /// process per attempt.
  ///
  /// The returned id is what to wait for on `room_announced`; the app must
  /// never precompute a room id itself.
  Future<String> createSession({
    required String epk,
    required String workspaceId,
    required String idempotencyKey,
    String? displayName,
  });
}

class MachineControlRepository extends Repository
    implements IMachineControlRepository {
  final ConnectionManager _conn;
  final Duration _timeout;

  StreamSubscription<ConnectionStatus>? _statusSub;
  StreamSubscription<ServerMessage>? _msgSub;
  IChannel? _channel;

  final Map<String, Completer<ActionOk>> _pending = {};
  final Map<String, Timer> _timers = {};

  /// Spawning is slower than a chat action: the supervisor has to fork `pi`,
  /// which loads settings and an extension before it answers. 15s (the chat
  /// default) times out a healthy cold start on a loaded machine.
  MachineControlRepository(
    this._conn, {
    Duration timeout = const Duration(seconds: 45),
  }) : _timeout = timeout {
    _statusSub = _conn.statusStream.listen(_onStatus);
    _onStatus(_conn.status);
  }

  void _onStatus(ConnectionStatus s) {
    _msgSub?.cancel();
    _msgSub = null;
    _channel = s is StatusOnline ? s.channel : null;
    final ch = _channel;
    if (ch == null) {
      // Fail everything in flight: the socket that would have carried the
      // replies is gone, and a silent hang is the worse failure.
      _failAll(const ActionFailure('offline'));
      return;
    }
    _msgSub = ch.serverMessages.listen(_onMessage);
  }

  void _onMessage(ServerMessage msg) {
    if (msg is ActionOk) {
      _resolve(msg.inReplyTo, (c) => c.complete(msg));
    } else if (msg is ActionError) {
      _resolve(msg.inReplyTo, (c) => c.completeError(ActionFailure(msg.error)));
    }
  }

  void _resolve(String id, void Function(Completer<ActionOk>) apply) {
    final c = _pending.remove(id);
    _timers.remove(id)?.cancel();
    if (c == null || c.isCompleted) return;
    apply(c);
  }

  void _failAll(Object error) {
    for (final entry in _pending.entries.toList()) {
      _timers.remove(entry.key)?.cancel();
      if (!entry.value.isCompleted) entry.value.completeError(error);
    }
    _pending.clear();
  }

  Future<ActionOk> _rpc(ClientMessage Function(String id) build) async {
    final ch = _channel;
    if (ch == null) throw const ActionFailure('offline');
    final id = 'ctl_${uuid7()}';
    final completer = Completer<ActionOk>();
    _pending[id] = completer;
    _timers[id] = Timer(_timeout, () {
      _resolve(id, (c) => c.completeError(const ActionFailure('timeout')));
    });
    try {
      final msg = build(id);
      if (ch is PlainPeerChannel) {
        await ch.sendToRoom(msg, kControlRoomId);
      } else {
        // Test fakes model a single destination; the room override is a no-op
        // there.
        await ch.send(msg);
      }
    } catch (e) {
      _resolve(id, (c) => c.completeError(ActionFailure(e.toString())));
    }
    return completer.future;
  }

  /// Reject a call aimed at a machine we are not currently connected to.
  ///
  /// The control frame would otherwise be addressed to the ACTIVE peer's
  /// gateway — silently asking the wrong machine to spawn a process.
  void _requireActivePeer(String epk) {
    final active = _conn.activePeer?.remoteEpk;
    if (active == null) throw const ActionFailure('offline');
    if (toStandardB64(active) != toStandardB64(epk)) {
      throw const ActionFailure(
        'Not connected to that machine — open one of its sessions first.',
      );
    }
  }

  @override
  Future<List<RemoteWorkspace>> listWorkspaces(String epk) async {
    _requireActivePeer(epk);
    final ok = await _rpc((id) => WorkspaceList(id: id));
    final raw = ok.data['workspaces'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(RemoteWorkspace.fromJson)
        .toList();
  }

  @override
  Future<String> createSession({
    required String epk,
    required String workspaceId,
    required String idempotencyKey,
    String? displayName,
  }) async {
    _requireActivePeer(epk);
    final ok = await _rpc(
      (id) => CreateSession(
        id: id,
        idempotencyKey: idempotencyKey,
        workspaceId: workspaceId,
        displayName: displayName,
      ),
    );
    final sessionId = ok.data['session_id'];
    if (sessionId is! String || sessionId.isEmpty) {
      throw const ActionFailure('machine did not return a session id');
    }
    return sessionId;
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _msgSub?.cancel();
    _failAll(const ActionFailure('disposed'));
    super.dispose();
  }
}
