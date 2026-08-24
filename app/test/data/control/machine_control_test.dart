// Plan 61 Phase 3 — the machine control plane, from the app's side.
//
// The problem this phase exists to solve: discovery ran Pi → `room_announced`
// → app, so a Mac with no interactive Pi open had no room and the phone had no
// way to ask for one. You needed a Pi to create a Pi.

import 'dart:async';
import 'package:app/data/actions/actions_repository.dart' show ActionFailure;
import 'package:app/data/control/machine_control_repository.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeStorage extends PairingStorage {
  final List<PeerRecord> peers;
  _FakeStorage(this.peers);
  @override
  Future<List<PeerRecord>> listPeers() async => List.of(peers);
  @override
  Future<void> savePeer(PeerRecord r) async {}
  @override
  Future<void> saveRooms(String epk, List<PersistedRoom> rooms) async {}
  @override
  Future<List<PersistedRoom>> loadRooms(String epk) async => const [];
  @override
  Future<void> deleteRooms(String epk) async {}
}

/// Channel that records outbound frames and lets a test push replies back.
class _RpcChannel implements IChannel, IControlLink {
  final _server = StreamController<ServerMessage>.broadcast();
  final _control = StreamController<ControlInbound>.broadcast();
  final List<ClientMessage> sent = [];

  @override
  Stream<ServerMessage> get serverMessages => _server.stream;
  @override
  Stream<ControlInbound> get controlFrames => _control.stream;
  @override
  Future<void> send(ClientMessage msg) async => sent.add(msg);
  @override
  void sendControl(Map<String, dynamic> json) {}
  @override
  Future<void> close() async {
    await _server.close();
    await _control.close();
  }

  void reply(ServerMessage m) => _server.add(m);
  void pushControl(ControlInbound c) => _control.add(c);

  /// The rpc id of the last outbound frame, so a test can answer it.
  String lastId() {
    final json = sent.last.toJson();
    return json['id'] as String;
  }
}

const _peer = PeerRecord(
  remoteEpk: 'epk_mac',
  sessionName: 'Mac',
  relayUrl: 'ws://x',
  pairedAt: '2026-01-01T00:00:00Z',
);

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 10));

Future<({ConnectionManager conn, _RpcChannel ch, MachineControlRepository repo})>
_online() async {
  final ch = _RpcChannel();
  final conn = ConnectionManager(
    factory: (_, _) async => ch,
    storage: _FakeStorage([_peer]),
    emitDebounce: Duration.zero,
  );
  final repo = MachineControlRepository(
    conn,
    timeout: const Duration(milliseconds: 200),
  );
  await conn.connectTo(_peer);
  await _settle();
  return (conn: conn, ch: ch, repo: repo);
}

void main() {
  group('MachineControlRepository', () {
    test('workspace_list is answered from the action payload', () async {
      final f = await _online();

      final future = f.repo.listWorkspaces('epk_mac');
      await _settle();

      expect(f.ch.sent.single, isA<WorkspaceList>());
      f.ch.reply(
        ActionOk(
          inReplyTo: f.ch.lastId(),
          action: ActionName.workspaceList,
          rawAction: 'workspace_list',
          data: {
            'workspaces': [
              {'workspace_id': 'w1', 'path': '/w/api', 'display_name': 'api'},
            ],
          },
        ),
      );

      final list = await future;
      expect(list, hasLength(1));
      expect(list.single.workspaceId, 'w1');
      expect(list.single.path, '/w/api');
      expect(list.single.displayName, 'api');

      f.repo.dispose();
      await f.conn.disconnect();
      f.conn.dispose();
    });

    test(
      'create_session sends the caller-supplied idempotency key VERBATIM — '
      'the machine deduplicates on it, so the app must not re-mint per retry',
      () async {
        final f = await _online();

        final future = f.repo.createSession(
          epk: 'epk_mac',
          workspaceId: 'w1',
          idempotencyKey: 'stable-key',
          displayName: 'Nightly',
        );
        await _settle();

        final frame = f.ch.sent.single.toJson();
        expect(frame['type'], 'create_session');
        expect(frame['idempotency_key'], 'stable-key');
        expect(frame['workspace_id'], 'w1');
        expect(frame['display_name'], 'Nightly');
        // v1 is background-only and says so explicitly.
        expect(frame['background'], true);
        // And there is no way to smuggle a path.
        expect(frame.containsKey('cwd'), isFalse);
        expect(frame.containsKey('path'), isFalse);

        f.ch.reply(
          ActionOk(
            inReplyTo: f.ch.lastId(),
            action: ActionName.createSession,
            rawAction: 'create_session',
            data: {'session_id': 'sess-new'},
          ),
        );
        expect(await future, 'sess-new');

        f.repo.dispose();
        await f.conn.disconnect();
        f.conn.dispose();
      },
    );

    test('an action_error surfaces the machine\'s reason', () async {
      final f = await _online();

      final future = f.repo.createSession(
        epk: 'epk_mac',
        workspaceId: 'nope',
        idempotencyKey: 'k',
      );
      await _settle();
      f.ch.reply(
        ActionError(
          inReplyTo: f.ch.lastId(),
          action: ActionName.createSession,
          rawAction: 'create_session',
          error: 'unknown workspace: nope',
        ),
      );

      await expectLater(
        future,
        throwsA(
          isA<ActionFailure>().having(
            (e) => e.message,
            'message',
            'unknown workspace: nope',
          ),
        ),
      );

      f.repo.dispose();
      await f.conn.disconnect();
      f.conn.dispose();
    });

    test('a reply that omits session_id is a failure, not an empty id', () async {
      final f = await _online();

      final future = f.repo.createSession(
        epk: 'epk_mac',
        workspaceId: 'w1',
        idempotencyKey: 'k',
      );
      await _settle();
      f.ch.reply(
        ActionOk(
          inReplyTo: f.ch.lastId(),
          action: ActionName.createSession,
          rawAction: 'create_session',
          data: const {},
        ),
      );

      await expectLater(future, throwsA(isA<ActionFailure>()));

      f.repo.dispose();
      await f.conn.disconnect();
      f.conn.dispose();
    });

    test('an unanswered rpc times out instead of hanging forever', () async {
      final f = await _online();
      await expectLater(
        f.repo.listWorkspaces('epk_mac'),
        throwsA(
          isA<ActionFailure>().having((e) => e.message, 'message', 'timeout'),
        ),
      );
      f.repo.dispose();
      await f.conn.disconnect();
      f.conn.dispose();
    });

    test(
      'a call aimed at a machine we are NOT connected to is refused — the '
      'frame would otherwise ask the active machine to spawn a process',
      () async {
        final f = await _online();
        await expectLater(
          f.repo.listWorkspaces('epk_some_other_mac'),
          throwsA(isA<ActionFailure>()),
        );
        expect(f.ch.sent, isEmpty);
        f.repo.dispose();
        await f.conn.disconnect();
        f.conn.dispose();
      },
    );

    test('going offline fails everything in flight', () async {
      final f = await _online();
      final future = f.repo.listWorkspaces('epk_mac');
      await _settle();

      await f.conn.disconnect();

      await expectLater(future, throwsA(isA<ActionFailure>()));
      f.repo.dispose();
      f.conn.dispose();
    });
  });

  group('transport_error — plan 61 Phase 3', () {
    test(
      'the relay reporting an undeliverable destination marks that room '
      'offline immediately instead of waiting out the no-echo timer',
      () async {
        final f = await _online();
        f.ch.pushControl(
          const RoomAnnounced(peer: 'epk_mac', roomId: 'sess-1', startedAt: 1),
        );
        await _settle();
        expect(f.conn.isRoomLive('epk_mac', 'sess-1'), isTrue);

        final seen = <({String epk, String roomId, String reason})>[];
        f.conn.transportErrors.listen(seen.add);

        f.ch.pushControl(
          const TransportError(
            peer: 'epk_mac',
            roomId: 'sess-1',
            reason: 'offline',
          ),
        );
        await _settle();

        expect(f.conn.isRoomLive('epk_mac', 'sess-1'), isFalse);
        expect(seen, hasLength(1));
        expect(seen.single.roomId, 'sess-1');
        expect(seen.single.reason, 'offline');
        // The tile survives as a grey/offline row — history stays readable.
        expect(f.conn.roomsFor('epk_mac'), hasLength(1));

        f.repo.dispose();
        await f.conn.disconnect();
        f.conn.dispose();
      },
    );

    test('an error for an unknown room is harmless', () async {
      final f = await _online();
      f.ch.pushControl(
        const TransportError(peer: 'epk_mac', roomId: 'ghost', reason: 'offline'),
      );
      await _settle();
      expect(f.conn.roomsFor('epk_mac'), isEmpty);

      f.repo.dispose();
      await f.conn.disconnect();
      f.conn.dispose();
    });

    test('the wire frame parses, defaulting the room to main', () {
      final c = ControlInbound.tryFromJson({
        'type': 'transport_error',
        'reason': 'offline',
        'peer': 'p',
      });
      expect(c, isA<TransportError>());
      expect((c! as TransportError).roomId, 'main');
      expect((c as TransportError).reason, 'offline');
    });
  });
}
