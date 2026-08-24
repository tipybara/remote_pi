// Tests for the new room-related control frames (plan 17).

import 'package:app/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ControlInbound — rooms (plan 17)', () {
    test('room_announced parses with name + cwd', () {
      final c = ControlInbound.tryFromJson({
        'type': 'room_announced',
        'peer': 'epk_A',
        'room_id': 'room-uuid-1',
        'name': 'work',
        'cwd': '/Users/jacob/projects/app',
        'started_at': 1700000000000,
      });
      expect(c, isA<RoomAnnounced>());
      final r = c! as RoomAnnounced;
      expect(r.peer, 'epk_A');
      expect(r.roomId, 'room-uuid-1');
      expect(r.name, 'work');
      expect(r.cwd, '/Users/jacob/projects/app');
      expect(r.startedAt, 1700000000000);
    });

    test('room_announced tolerates missing name + cwd', () {
      final c = ControlInbound.tryFromJson({
        'type': 'room_announced',
        'peer': 'epk_A',
        'room_id': 'main',
        'started_at': 1700000000000,
      });
      expect(c, isA<RoomAnnounced>());
      final r = c! as RoomAnnounced;
      expect(r.name, isNull);
      expect(r.cwd, isNull);
    });

    test('room_ended parses', () {
      final c = ControlInbound.tryFromJson({
        'type': 'room_ended',
        'peer': 'epk_A',
        'room_id': 'room-uuid-1',
        'since_ts': 1700000010000,
      });
      expect(c, isA<RoomEnded>());
      final r = c! as RoomEnded;
      expect(r.roomId, 'room-uuid-1');
      expect(r.sinceTs, 1700000010000);
    });

    test('rooms snapshot parses with nested RoomInfo list', () {
      final c = ControlInbound.tryFromJson({
        'type': 'rooms',
        'peer': 'epk_A',
        'rooms': [
          {
            'room_id': 'r1',
            'name': 'one',
            'cwd': '/one',
            'started_at': 1000,
          },
          {
            'room_id': 'r2',
            'started_at': 2000,
          },
        ],
      });
      expect(c, isA<RoomsSnapshot>());
      final r = c! as RoomsSnapshot;
      expect(r.peer, 'epk_A');
      expect(r.rooms, hasLength(2));
      expect(r.rooms[0].roomId, 'r1');
      expect(r.rooms[0].cwd, '/one');
      expect(r.rooms[1].name, isNull);
      expect(r.rooms[1].cwd, isNull);
    });

    test(
      'room_announced parses optional `model` (plan 18)',
      () {
        final c = ControlInbound.tryFromJson({
          'type': 'room_announced',
          'peer': 'epk_A',
          'room_id': 'r1',
          'started_at': 1700000000000,
          'model': 'claude-sonnet-4.5',
        });
        expect(c, isA<RoomAnnounced>());
        expect((c! as RoomAnnounced).model, 'claude-sonnet-4.5');
      },
    );

    test(
      'room_meta_updated parses with model (plan 18)',
      () {
        final c = ControlInbound.tryFromJson({
          'type': 'room_meta_updated',
          'peer': 'epk_A',
          'room_id': 'r1',
          'meta': {'model': 'gpt-4o'},
        });
        expect(c, isA<RoomMetaUpdated>());
        final r = c! as RoomMetaUpdated;
        expect(r.peer, 'epk_A');
        expect(r.roomId, 'r1');
        expect(r.model, 'gpt-4o');
      },
    );

    test(
      'room_meta_updated tolerates missing meta / model (clears value)',
      () {
        final c = ControlInbound.tryFromJson({
          'type': 'room_meta_updated',
          'peer': 'epk_A',
          'room_id': 'r1',
        });
        expect(c, isA<RoomMetaUpdated>());
        expect((c! as RoomMetaUpdated).model, isNull);
      },
    );

    test('RoomInfo serializes + parses round-trip (all fields set)', () {
      const r = RoomInfo(
        roomId: 'r1',
        startedAt: 100,
        name: 'work',
        cwd: '/x',
        model: 'claude-sonnet-4.5',
        // Plan 61 Phase 1 — the session identity must survive the round-trip
        // too; it is what the cached-rooms store persists across cold starts.
        sessionId: '019ffb64-7c21-7a3f-9d2e-4b1c8a0f6e5d',
        workspacePath: '/x',
        nameRev: 7,
        role: 'control',
      );
      final back = RoomInfo.fromJson(r.toJson());
      expect(back, r);
      expect(back.model, 'claude-sonnet-4.5');
      expect(back.sessionId, '019ffb64-7c21-7a3f-9d2e-4b1c8a0f6e5d');
      expect(back.nameRev, 7);
      expect(back.isControlRoom, isTrue);
    });

    test(
      'plan 61 Phase 1 — a legacy room (cwd only, no workspace_path) back-fills '
      'the workspace from cwd so Home can still group it',
      () {
        // Deliberately NOT an identity round-trip: a pre-plan-61 payload has no
        // `workspace_path`, and leaving it null would hide the session from the
        // Device → Workspace → Session grouping entirely. `cwd` already holds
        // the same canonical path, so it is promoted. Re-parsing is stable.
        const legacy = RoomInfo(roomId: 'r1', startedAt: 100, cwd: '/x');
        expect(legacy.workspacePath, isNull);

        final back = RoomInfo.fromJson(legacy.toJson());
        expect(back.workspacePath, '/x');
        expect(back.sessionId, isNull, reason: 'legacy rooms are not session-keyed');
        expect(back.isControlRoom, isFalse);
        expect(RoomInfo.fromJson(back.toJson()), back, reason: 'stable after one pass');
      },
    );

    test('outbound subscribe_rooms helper has correct shape', () {
      expect(subscribeRoomsFrame(['a', 'b']), {
        'type': 'subscribe_rooms',
        'peers': ['a', 'b'],
      });
      expect(unsubscribeRoomsFrame(['a']), {
        'type': 'unsubscribe_rooms',
        'peers': ['a'],
      });
      expect(roomsCheckFrame(['a']), {
        'type': 'rooms_check',
        'peers': ['a'],
      });
    });
  });
}
