// Plan-61 Fase 0 — "session identity" regressions for the Home list.
//
// Every test here pins one of the mechanics that made sessions appear to
// jump around: the presence tab being reset by an unrelated storage write,
// display names acting as sort identity, volatile room metadata acting as
// row identity, and list rows having no widget key (so Flutter matched
// elements by POSITION and handed a tapped row's element to another
// session).
//
// See plan/61-stable-session-identity.md and review/61-audit-app-session.md.

import 'dart:async';
import 'dart:typed_data';

import 'package:app/data/actions/actions_repository.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/data/transport/epk_encoding.dart';
import 'package:app/data/transport/peer_channel.dart';
import 'package:app/domain/contracts/dismissed_update_store.dart';
import 'package:app/domain/contracts/update_checker.dart';
import 'package:app/domain/contracts/url_opener.dart';
import 'package:app/domain/entities/update_info.dart';
import 'package:app/pairing/pair_request_flow.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/routing/adaptive.dart';
import 'package:app/ui/home/home_page.dart';
import 'package:app/ui/home/states/home_state.dart';
import 'package:app/ui/home/viewmodels/home_viewmodel.dart';
import 'package:app/ui/home/widgets/peer_section_header.dart';
import 'package:app/ui/home/widgets/session_tile.dart';
import 'package:app/ui/home/widgets/workspace_section_header.dart';
import 'package:app/ui/update/viewmodels/update_banner_viewmodel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

// ── fakes ────────────────────────────────────────────────────────────────

class _FakeStorage extends PairingStorage {
  List<PeerRecord> peers;
  _FakeStorage(this.peers);

  final Map<String, List<PersistedRoom>> _rooms = {};

  @override
  Future<List<PeerRecord>> listPeers() async => List.of(peers);

  /// Mirrors the real store: a peer mutation DOES notify (that's the
  /// notification `_load` reacts to).
  @override
  Future<void> savePeer(PeerRecord r) async {
    peers = [r, ...peers.where((p) => p.remoteEpk != r.remoteEpk)];
    notifyListeners();
  }

  @override
  Future<void> deletePeer(String epk) async {
    peers = peers.where((p) => p.remoteEpk != epk).toList();
    notifyListeners();
  }

  @override
  Future<void> saveRooms(String epk, List<PersistedRoom> rooms) async {
    _rooms[epk] = rooms;
  }

  @override
  Future<List<PersistedRoom>> loadRooms(String epk) async =>
      _rooms[epk] ?? const [];

  @override
  Future<void> deleteRooms(String epk) async {
    _rooms.remove(epk);
  }
}

class _FakeSecureStorage implements FlutterSecureStorage {
  final Map<String, String> _store = {};
  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _store[key];
  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      _store.remove(key);
    } else {
      _store[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _store.remove(key);
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _NoopTransport implements PeerTransport {
  @override
  Future<void> send(Uint8List data) async {}
  @override
  Future<Uint8List> receive() => Completer<Uint8List>().future;
  @override
  Future<void> close() async {}
}

class _ControllableChannel implements IChannel, IControlLink {
  final _serverCtrl = StreamController<ServerMessage>.broadcast();
  final _controlCtrl = StreamController<ControlInbound>.broadcast();

  @override
  Stream<ServerMessage> get serverMessages => _serverCtrl.stream;
  @override
  Stream<ControlInbound> get controlFrames => _controlCtrl.stream;
  @override
  Future<void> send(ClientMessage msg) async {}
  @override
  void sendControl(Map<String, dynamic> json) {}
  @override
  Future<void> close() async {
    await _serverCtrl.close();
    await _controlCtrl.close();
  }

  void pushControl(ControlInbound m) => _controlCtrl.add(m);
}

class _NoopChecker implements UpdateChecker {
  @override
  Future<UpdateInfo?> fetchLatest() async => null;
}

class _NoopDismissedStore implements DismissedUpdateStore {
  @override
  Future<String?> dismissedVersion() async => null;
  @override
  Future<void> dismiss(String version) async {}
}

class _NoopOpener implements UrlOpener {
  @override
  Future<bool> open(String url) async => true;
}

// ── fixtures ─────────────────────────────────────────────────────────────

PeerRecord _peer(
  String epk, {
  String name = 'Pi',
  String? nickname,
  String pairedAt = '2026-01-01T00:00:00Z',
}) => PeerRecord(
  remoteEpk: epk,
  sessionName: name,
  relayUrl: 'ws://x',
  pairedAt: pairedAt,
  nickname: nickname,
);

/// The SAME 32-byte key in both wire encodings the app juggles: base64url
/// (QR / `PairingStorage`) and base64 standard (relay `hello.pubkey`).
/// Bytes chosen so the two forms actually differ (`-_` vs `+/`).
const _epkUrlSafe = 'v_7-_f78-_r5-Pf29fTz8vHw7-7t7Ovq6ejn5uXk4-I';
final _epkStandard = toStandardB64(_epkUrlSafe);

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  // Both encodings must genuinely differ, otherwise the normalisation
  // tests below would pass vacuously.
  test('fixture sanity: the two epk encodings really differ', () {
    expect(_epkStandard, isNot(_epkUrlSafe));
    expect(toAppEpk(_epkStandard), _epkUrlSafe);
  });

  group('HomeItem identity (plan-61 fase 0)', () {
    test(
      'sessionKey normalises the epk — the url-safe (storage) and standard '
      '(relay) forms of one machine produce ONE row key, not two',
      () {
        const room = RoomInfo(roomId: 'r1', startedAt: 1);
        final fromStorage = HomeItem(peer: _peer(_epkUrlSafe), room: room);
        final fromRelay = HomeItem(peer: _peer(_epkStandard), room: room);

        expect(fromStorage.sessionKey, fromRelay.sessionKey);
        expect(fromStorage.sessionKey, '$_epkStandard|r1');
      },
    );

    test(
      'equality ignores volatile room metadata — `working` flips twice per '
      'turn and `startedAt` is re-stamped by the relay on every reconnect; '
      'neither may make a session look like a different session',
      () {
        final idle = HomeItem(
          peer: _peer('A'),
          room: const RoomInfo(roomId: 'r1', startedAt: 1, model: 'sonnet'),
        );
        final busy = HomeItem(
          peer: _peer('A'),
          room: const RoomInfo(
            roomId: 'r1',
            startedAt: 999, // relay re-stamped it on reconnect
            model: 'opus', // model switched mid-session
            working: true, // turn in flight
            thinking: ThinkingLevel.high,
          ),
        );

        expect(busy, idle);
        expect(busy.hashCode, idle.hashCode);
      },
    );

    test('equality still separates different rooms and different peers', () {
      final a1 = HomeItem(
        peer: _peer('A'),
        room: const RoomInfo(roomId: 'r1', startedAt: 1),
      );
      final a2 = HomeItem(
        peer: _peer('A'),
        room: const RoomInfo(roomId: 'r2', startedAt: 1),
      );
      final b1 = HomeItem(
        peer: _peer('B'),
        room: const RoomInfo(roomId: 'r1', startedAt: 1),
      );

      expect(a1, isNot(a2));
      expect(a1, isNot(b1));
    });
  });

  group('HomeList.items ordering (plan-61 fase 0)', () {
    test(
      'renaming a session does NOT move it — order comes from roomId, never '
      'from the (editable) display name',
      () {
        HomeList listWithNames(String r1Name, String r2Name) => HomeList(
          peers: [_peer('A')],
          roomsByPeer: {
            'A': [
              RoomInfo(roomId: 'r2', startedAt: 2, name: r2Name),
              RoomInfo(roomId: 'r1', startedAt: 1, name: r1Name),
            ],
          },
        );

        final before = listWithNames('alpha', 'beta');
        expect(before.items().map((i) => i.room.roomId).toList(), [
          'r1',
          'r2',
        ]);

        // User renames r1 to something that sorts last alphabetically.
        final after = listWithNames('zulu', 'beta');
        expect(
          after.items().map((i) => i.room.roomId).toList(),
          ['r1', 'r2'],
          reason: 'a rename is metadata; it must not reorder the list',
        );
      },
    );

    test(
      'peers are ordered by pairedAt (then epk) — not by nickname, so '
      'renaming a Mac cannot reshuffle its section',
      () {
        final list = HomeList(
          peers: [
            _peer('epk-z', nickname: 'aaa', pairedAt: '2026-02-01T00:00:00Z'),
            _peer('epk-a', nickname: 'zzz', pairedAt: '2026-01-01T00:00:00Z'),
          ],
          roomsByPeer: {
            'epk-z': [const RoomInfo(roomId: 'r1', startedAt: 1)],
            'epk-a': [const RoomInfo(roomId: 'r1', startedAt: 1)],
          },
        );

        expect(
          list.items().map((i) => i.peer.remoteEpk).toList(),
          ['epk-a', 'epk-z'],
          reason: 'older pairing first; nickname is irrelevant to order',
        );
      },
    );

    test('same pairedAt falls back to epk so the order is still total', () {
      final list = HomeList(
        peers: [_peer('epk-b'), _peer('epk-a')],
        roomsByPeer: {
          'epk-a': [const RoomInfo(roomId: 'r1', startedAt: 1)],
          'epk-b': [const RoomInfo(roomId: 'r1', startedAt: 1)],
        },
      );
      expect(list.items().map((i) => i.peer.remoteEpk).toList(), [
        'epk-a',
        'epk-b',
      ]);
    });
  });

  group('HomeViewModel — filter survives storage churn (plan-61 fase 0)', () {
    test(
      'a PairingStorage notification reloads the list WITHOUT resetting the '
      'presence tab back to Online',
      () async {
        final ch = _ControllableChannel();
        final storage = _FakeStorage([_peer('epk_A')]);
        final conn = ConnectionManager(
          factory: (_, _) async => ch,
          storage: storage,
          emitDebounce: Duration.zero,
        );
        final vm = HomeViewModel(storage, Preferences(_FakeSecureStorage()), conn);
        await conn.connectTo(_peer('epk_A'));
        await _settle();

        // r1 live, r2 cached-offline → one item per tab.
        ch.pushControl(
          const RoomAnnounced(peer: 'epk_A', roomId: 'r1', startedAt: 1),
        );
        ch.pushControl(
          const RoomAnnounced(peer: 'epk_A', roomId: 'r2', startedAt: 2),
        );
        ch.pushControl(
          const RoomEnded(peer: 'epk_A', roomId: 'r2', sinceTs: 3),
        );
        await _settle();

        vm.setFilter(HomeFilter.offline);
        expect((vm.state as HomeList).filter, HomeFilter.offline);
        expect(vm.visibleItems.map((i) => i.room.roomId).toList(), ['r2']);

        // Anything that writes a peer (room adoption, nickname, mesh sync)
        // notifies the storage → HomeViewModel._load().
        await storage.savePeer(_peer('epk_A', nickname: 'Macbook'));
        await _settle();

        expect(
          (vm.state as HomeList).filter,
          HomeFilter.offline,
          reason: 'the user picked this tab; a storage write must not undo it',
        );
        expect(vm.visibleItems.map((i) => i.room.roomId).toList(), ['r2']);

        vm.dispose();
        await conn.disconnect();
        conn.dispose();
      },
    );

    test('the first load still defaults to the Online tab', () async {
      final storage = _FakeStorage([_peer('epk_A')]);
      final conn = ConnectionManager(
        factory: (_, _) async => PlainPeerChannel(transport: _NoopTransport()),
        storage: storage,
      );
      final vm = HomeViewModel(storage, Preferences(_FakeSecureStorage()), conn);
      await _settle();

      expect((vm.state as HomeList).filter, HomeFilter.online);

      vm.dispose();
      conn.dispose();
    });
  });

  _phase1();
  _phase2();
  _grouping();

  group('Home tiles carry a stable ValueKey (plan-61 fase 0)', () {
    Future<HomeViewModel> pumpHome(
      WidgetTester tester, {
      required _FakeStorage storage,
      required ConnectionManager conn,
      Preferences? prefs,
    }) async {
      final vm = HomeViewModel(
        storage,
        prefs ?? Preferences(_FakeSecureStorage()),
        conn,
      );
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<HomeViewModel>.value(value: vm),
            ChangeNotifierProvider<ShellLayout>(create: (_) => ShellLayout()),
            ChangeNotifierProvider<SessionSelection>(
              create: (_) => SessionSelection(),
            ),
            ChangeNotifierProvider<UpdateBannerViewModel>(
              create: (_) => UpdateBannerViewModel(
                _NoopChecker(),
                _NoopDismissedStore(),
                _NoopOpener(),
                currentVersion: '1.0.0',
                enabled: false,
              ),
            ),
          ],
          child: const MaterialApp(home: HomePage()),
        ),
      );
      await tester.pump();
      return vm;
    }

    testWidgets(
      'grouping depth decides which HEADERS render — never which rows do',
      (tester) async {
        final ch = _ControllableChannel();
        final storage = _FakeStorage([_peer(_epkUrlSafe)]);
        final conn = ConnectionManager(
          factory: (_, _) async => ch,
          storage: storage,
          emitDebounce: Duration.zero,
        );
        final prefs = Preferences(_FakeSecureStorage());
        final vm = await pumpHome(
          tester,
          storage: storage,
          conn: conn,
          prefs: prefs,
        );
        await conn.connectTo(_peer(_epkUrlSafe));
        await tester.pump(const Duration(milliseconds: 20));

        ch.pushControl(
          RoomAnnounced(
            peer: _epkStandard,
            roomId: 'r1',
            name: 'alpha',
            workspacePath: '/w/api',
            startedAt: 1,
          ),
        );
        await tester.pump(const Duration(milliseconds: 20));
        await tester.pump();

        // Default: both headers.
        expect(find.byType(PeerSectionHeader), findsOneWidget);
        expect(find.byType(WorkspaceSectionHeader), findsOneWidget);
        expect(find.byType(SessionTile), findsOneWidget);

        // Device only: the folder header goes, the row stays.
        await vm.setGrouping(HomeGrouping.device);
        await tester.pump();
        expect(find.byType(PeerSectionHeader), findsOneWidget);
        expect(find.byType(WorkspaceSectionHeader), findsNothing);
        expect(find.byType(SessionTile), findsOneWidget);
        // …and the folder it lost is now on the tile, so attribution survives.
        expect(find.textContaining('api'), findsWidgets);

        // Flat: no headers at all.
        await vm.setGrouping(HomeGrouping.none);
        await tester.pump();
        expect(find.byType(PeerSectionHeader), findsNothing);
        expect(find.byType(WorkspaceSectionHeader), findsNothing);
        expect(find.byType(SessionTile), findsOneWidget);

        vm.dispose();
        await conn.disconnect();
        conn.dispose();
      },
    );

    testWidgets(
      'each row is keyed by `<normalised-epk>|<roomId>`, so Flutter matches '
      'elements by SESSION instead of by list position',
      (tester) async {
        final ch = _ControllableChannel();
        final storage = _FakeStorage([_peer(_epkUrlSafe)]);
        final conn = ConnectionManager(
          factory: (_, _) async => ch,
          storage: storage,
          emitDebounce: Duration.zero,
        );
        final vm = await pumpHome(tester, storage: storage, conn: conn);
        await conn.connectTo(_peer(_epkUrlSafe));
        await tester.pump(const Duration(milliseconds: 20));

        // The relay reports the STANDARD encoding of the same machine.
        ch.pushControl(
          RoomAnnounced(
            peer: _epkStandard,
            roomId: 'r1',
            name: 'alpha',
            startedAt: 1,
          ),
        );
        ch.pushControl(
          RoomAnnounced(
            peer: _epkStandard,
            roomId: 'r2',
            name: 'beta',
            startedAt: 2,
          ),
        );
        await tester.pump(const Duration(milliseconds: 20));
        await tester.pump();

        expect(find.byType(SessionTile), findsNWidgets(2));
        expect(find.byKey(ValueKey('$_epkStandard|r1')), findsOneWidget);
        expect(find.byKey(ValueKey('$_epkStandard|r2')), findsOneWidget);

        // Capture the element identity of the r1 row, then rename BOTH rooms
        // so the old name-based ordering would have swapped them.
        final r1Element = tester.element(
          find.byKey(ValueKey('$_epkStandard|r1')),
        );
        await conn.setRoomLocalName(_epkStandard, 'r1', 'zulu');
        await conn.setRoomLocalName(_epkStandard, 'r2', 'alpha');
        await tester.pump(const Duration(milliseconds: 20));
        await tester.pump();

        expect(
          tester.element(find.byKey(ValueKey('$_epkStandard|r1'))),
          same(r1Element),
          reason: 'the same session must keep the same element across renames',
        );
        expect(find.text('zulu'), findsOneWidget);

        vm.dispose();
        await conn.disconnect();
        conn.dispose();
      },
    );
  });
}

// ── plan 61 Phase 1 (app side) — rename is a patch, not a new room ──────────

void _phase1() {
  group('plan 61 Phase 1 — rename arrives as room_meta_updated', () {
    test(
      'a name patch updates the SAME room — no second tile, no lost history',
      () async {
        final ch = _ControllableChannel();
        final storage = _FakeStorage([_peer('epk_A')]);
        final conn = ConnectionManager(
          factory: (_, _) async => ch,
          storage: storage,
          emitDebounce: Duration.zero,
        );
        await conn.connectTo(_peer('epk_A'));
        await _settle();

        ch.pushControl(
          const RoomAnnounced(
            peer: 'epk_A',
            roomId: 'sess-1',
            sessionId: 'sess-1',
            name: 'before',
            cwd: '/w',
            workspacePath: '/w',
            nameRev: 1,
            startedAt: 1,
          ),
        );
        await _settle();
        expect(conn.roomsFor('epk_A').single.name, 'before');

        ch.pushControl(
          const RoomMetaUpdated(
            peer: 'epk_A',
            roomId: 'sess-1',
            name: 'after',
            hasName: true,
            nameRev: 2,
            hasModel: false,
            hasThinking: false,
          ),
        );
        await _settle();

        final rooms = conn.roomsFor('epk_A');
        expect(rooms, hasLength(1), reason: 'a rename must not create a room');
        expect(rooms.single.roomId, 'sess-1');
        expect(rooms.single.name, 'after');
        expect(rooms.single.nameRev, 2);

        await conn.disconnect();
        conn.dispose();
      },
    );

    test(
      'a stale name_rev is ignored — a reconnecting device replaying an old '
      'patch must not revert the label',
      () async {
        final ch = _ControllableChannel();
        final storage = _FakeStorage([_peer('epk_A')]);
        final conn = ConnectionManager(
          factory: (_, _) async => ch,
          storage: storage,
          emitDebounce: Duration.zero,
        );
        await conn.connectTo(_peer('epk_A'));
        await _settle();

        ch.pushControl(
          const RoomAnnounced(
            peer: 'epk_A',
            roomId: 'sess-1',
            name: 'current',
            nameRev: 5,
            startedAt: 1,
          ),
        );
        await _settle();

        ch.pushControl(
          const RoomMetaUpdated(
            peer: 'epk_A',
            roomId: 'sess-1',
            name: 'stale',
            hasName: true,
            nameRev: 3,
            hasModel: false,
            hasThinking: false,
          ),
        );
        await _settle();
        expect(conn.roomsFor('epk_A').single.name, 'current');

        // Equal revision loses too (strictly-greater rule).
        ch.pushControl(
          const RoomMetaUpdated(
            peer: 'epk_A',
            roomId: 'sess-1',
            name: 'equal',
            hasName: true,
            nameRev: 5,
            hasModel: false,
            hasThinking: false,
          ),
        );
        await _settle();
        expect(conn.roomsFor('epk_A').single.name, 'current');

        await conn.disconnect();
        conn.dispose();
      },
    );

    test('a model-only patch must not clear the name', () async {
      final ch = _ControllableChannel();
      final storage = _FakeStorage([_peer('epk_A')]);
      final conn = ConnectionManager(
        factory: (_, _) async => ch,
        storage: storage,
        emitDebounce: Duration.zero,
      );
      await conn.connectTo(_peer('epk_A'));
      await _settle();

      ch.pushControl(
        const RoomAnnounced(
          peer: 'epk_A',
          roomId: 'sess-1',
          name: 'keep-me',
          startedAt: 1,
        ),
      );
      ch.pushControl(
        const RoomMetaUpdated(
          peer: 'epk_A',
          roomId: 'sess-1',
          model: 'opus',
          hasModel: true,
          hasThinking: false,
        ),
      );
      await _settle();

      expect(conn.roomsFor('epk_A').single.name, 'keep-me');
      expect(conn.roomsFor('epk_A').single.model, 'opus');

      await conn.disconnect();
      conn.dispose();
    });
  });

  group('plan 61 Phase 3 — the machine control room is not a chat', () {
    test('a room with role=control is excluded from Home items and counts', () {
      final list = HomeList(
        peers: [_peer('A')],
        roomsByPeer: {
          'A': [
            const RoomInfo(roomId: 'ctrl', startedAt: 1, role: 'control'),
            const RoomInfo(roomId: 'sess-1', startedAt: 2),
          ],
        },
      );

      expect(list.items().map((i) => i.room.roomId).toList(), ['sess-1']);
    });

    test('a machine whose ONLY room is the control room shows no rows', () {
      final list = HomeList(
        peers: [_peer('A')],
        roomsByPeer: {
          'A': [const RoomInfo(roomId: 'ctrl', startedAt: 1, role: 'control')],
        },
      );
      expect(list.items(), isEmpty);
    });
  });

  group('plan 61 — the live-room set does not survive a disconnect', () {
    test(
      'disconnect clears _liveRoomIds so a reconnect cannot flash rooms green '
      'before the relay has said they are up',
      () async {
        final ch = _ControllableChannel();
        final storage = _FakeStorage([_peer('epk_A')]);
        final conn = ConnectionManager(
          factory: (_, _) async => ch,
          storage: storage,
          emitDebounce: Duration.zero,
        );
        await conn.connectTo(_peer('epk_A'));
        await _settle();

        ch.pushControl(
          const RoomAnnounced(peer: 'epk_A', roomId: 'sess-1', startedAt: 1),
        );
        await _settle();
        expect(conn.isRoomLive('epk_A', 'sess-1'), isTrue);

        await conn.disconnect();
        await _settle();

        // The cached room LIST survives — those are the grey offline tiles the
        // user can still open to read history.
        expect(conn.roomsFor('epk_A'), hasLength(1));
        expect(conn.isRoomLive('epk_A', 'sess-1'), isFalse);

        conn.dispose();
      },
    );
  });
}

// ── plan 61 Phase 2 — Device → Workspace → Session ─────────────────────────

class _RecordingActions implements IActionsRepository {
  ({String roomId, String displayName, String? sessionId, int? rev})? lastRename;
  Object? failWith;

  @override
  Future<void> renameSession({
    required String roomId,
    required String displayName,
    String? sessionId,
    int? rev,
  }) async {
    lastRename = (
      roomId: roomId,
      displayName: displayName,
      sessionId: sessionId,
      rev: rev,
    );
    if (failWith != null) throw failWith!;
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void _phase2() {
  group('plan 61 Phase 2 — Home groups Device → Workspace → Session', () {
    HomeList listWith(List<RoomInfo> rooms, {String epk = 'A'}) => HomeList(
      peers: [_peer(epk)],
      roomsByPeer: {
        epk: rooms,
      },
    );

    test('sessions in the same folder land under one workspace', () {
      final list = listWith(const [
        RoomInfo(roomId: 's1', startedAt: 1, workspacePath: '/w/api'),
        RoomInfo(roomId: 's2', startedAt: 2, workspacePath: '/w/api'),
        RoomInfo(roomId: 's3', startedAt: 3, workspacePath: '/w/web'),
      ]);

      final devices = list.groups();
      expect(devices, hasLength(1));
      expect(devices.single.workspaces.map((w) => w.path).toList(), [
        '/w/api',
        '/w/web',
      ]);
      expect(
        devices.single.workspaces.first.sessions.map((i) => i.room.roomId),
        ['s1', 's2'],
      );
      expect(devices.single.sessions, hasLength(3));
    });

    test('the workspace header shows the folder name, not the whole path', () {
      final ws = listWith(const [
        RoomInfo(roomId: 's1', startedAt: 1, workspacePath: '/Users/x/proj/api'),
      ]).groups().single.workspaces.single;
      expect(ws.displayName, 'api');
      expect(ws.path, '/Users/x/proj/api');
    });

    test(
      'a legacy room with only cwd still groups — it is the same canonical path',
      () {
        final ws = listWith(const [
          RoomInfo(roomId: 'legacy', startedAt: 1, cwd: '/w/api'),
          RoomInfo(roomId: 's1', startedAt: 2, workspacePath: '/w/api'),
        ]).groups().single.workspaces;
        expect(ws, hasLength(1), reason: 'cwd and workspace_path are one group');
        expect(ws.single.sessions, hasLength(2));
      },
    );

    test(
      'sessions with no directory at all collapse into ONE unknown group '
      'instead of inventing a header each',
      () {
        final ws = listWith(const [
          RoomInfo(roomId: 's1', startedAt: 1),
          RoomInfo(roomId: 's2', startedAt: 2),
        ]).groups().single.workspaces;
        expect(ws, hasLength(1));
        expect(ws.single.path, '');
        expect(ws.single.displayName, 'Unknown folder');
      },
    );

    test('a control room never produces a workspace row', () {
      final devices = listWith(const [
        RoomInfo(roomId: 'ctrl', startedAt: 1, role: 'control', workspacePath: '/w'),
        RoomInfo(roomId: 's1', startedAt: 2, workspacePath: '/w/api'),
      ]).groups();
      expect(
        devices.single.workspaces.map((w) => w.path).toList(),
        ['/w/api'],
      );
    });

    test(
      'filtering to a subset drops empty workspaces AND empty devices — no '
      'dangling headers on the Offline tab',
      () {
        final list = HomeList(
          peers: [_peer('A'), _peer('B', pairedAt: '2026-02-01T00:00:00Z')],
          roomsByPeer: {
            'A': const [RoomInfo(roomId: 'a1', startedAt: 1, workspacePath: '/a')],
            'B': const [RoomInfo(roomId: 'b1', startedAt: 1, workspacePath: '/b')],
          },
        );
        final all = list.items();
        expect(all, hasLength(2));

        // Pretend only B's session survived the presence filter.
        final onlyB = all.where((i) => i.room.roomId == 'b1').toList();
        final devices = list.groups(only: onlyB);
        expect(devices, hasLength(1));
        expect(devices.single.peer.remoteEpk, 'B');
        expect(devices.single.workspaces.single.path, '/b');
      },
    );

    test('workspaces are ordered by path, not by folder label', () {
      final ws = listWith(const [
        // Label order would be api, web; path order is /w/api, /z/aaa.
        RoomInfo(roomId: 's2', startedAt: 2, workspacePath: '/z/aaa'),
        RoomInfo(roomId: 's1', startedAt: 1, workspacePath: '/w/api'),
      ]).groups().single.workspaces;
      expect(ws.map((w) => w.path).toList(), ['/w/api', '/z/aaa']);
    });
  });

  group('plan 61 Phase 2 — Home rename reaches the Pi', () {
    Future<({HomeViewModel vm, _RecordingActions actions, ConnectionManager conn,
        _ControllableChannel ch})> setUpLive() async {
      final ch = _ControllableChannel();
      final storage = _FakeStorage([_peer('epk_A')]);
      final conn = ConnectionManager(
        factory: (_, _) async => ch,
        storage: storage,
        emitDebounce: Duration.zero,
      );
      final actions = _RecordingActions();
      final vm = HomeViewModel(
        storage,
        Preferences(_FakeSecureStorage()),
        conn,
        actions,
      );
      await conn.connectTo(_peer('epk_A'));
      await _settle();
      ch.pushControl(
        const RoomAnnounced(
          peer: 'epk_A',
          roomId: 'sess-1',
          sessionId: 'sess-1',
          name: 'old',
          nameRev: 4,
          startedAt: 1,
        ),
      );
      await _settle();
      return (vm: vm, actions: actions, conn: conn, ch: ch);
    }

    test(
      'a live session is renamed on the Pi, carrying session_id and the rev '
      'this device last saw',
      () async {
        final f = await setUpLive();

        final failure = await f.vm.renameRoom('epk_A', 'sess-1', '  New name ');

        expect(failure, isNull);
        expect(f.actions.lastRename, isNotNull);
        expect(f.actions.lastRename!.roomId, 'sess-1');
        expect(f.actions.lastRename!.displayName, 'New name');
        expect(f.actions.lastRename!.sessionId, 'sess-1');
        expect(
          f.actions.lastRename!.rev,
          4,
          reason: 'optimistic concurrency — the Pi refuses a stale revision',
        );

        f.vm.dispose();
        await f.conn.disconnect();
        f.conn.dispose();
      },
    );

    test(
      'an OFFLINE session stays local-only and says so — a rename that never '
      'left the device must not look like one that did',
      () async {
        final f = await setUpLive();
        f.ch.pushControl(
          const RoomEnded(peer: 'epk_A', roomId: 'sess-1', sinceTs: 9),
        );
        await _settle();

        final failure = await f.vm.renameRoom('epk_A', 'sess-1', 'Offline edit');

        expect(failure, isNotNull);
        expect(failure, contains('offline'));
        expect(f.actions.lastRename, isNull);
        // The local cache still reflects the user's intent.
        expect(f.conn.roomsFor('epk_A').single.name, 'Offline edit');

        f.vm.dispose();
        await f.conn.disconnect();
        f.conn.dispose();
      },
    );

    test('a refusal from the Pi is surfaced verbatim', () async {
      final f = await setUpLive();
      f.actions.failWith = const ActionFailure('stale name revision');

      final failure = await f.vm.renameRoom('epk_A', 'sess-1', 'Loser');

      expect(failure, 'stale name revision');

      f.vm.dispose();
      await f.conn.disconnect();
      f.conn.dispose();
    });

    test('clearing the label is a local-only affordance (nothing sent)', () async {
      final f = await setUpLive();

      final failure = await f.vm.renameRoom('epk_A', 'sess-1', '   ');

      expect(failure, isNull);
      expect(f.actions.lastRename, isNull);

      f.vm.dispose();
      await f.conn.disconnect();
      f.conn.dispose();
    });
  });
}

// ── plan 61 Phase 2 (follow-up) — grouping depth is the user's choice ───────

void _grouping() {
  group('HomeGrouping', () {
    test('the persisted wire value round-trips; anything else defaults', () {
      for (final g in HomeGrouping.values) {
        expect(HomeGrouping.fromWire(g.wire), g);
      }
      expect(HomeGrouping.fromWire(null), HomeGrouping.workspace);
      expect(HomeGrouping.fromWire('from-a-future-build'), HomeGrouping.workspace);
    });

    test('the first load takes the grouping from prefs, not the default', () async {
      // Otherwise the chosen layout visibly snaps back to the default for one
      // frame on every cold start.
      final storage = _FakeStorage([_peer('epk_A')]);
      final prefs = Preferences(_FakeSecureStorage());
      await prefs.setHomeGrouping(HomeGrouping.none);
      final conn = ConnectionManager(
        factory: (_, _) async => PlainPeerChannel(transport: _NoopTransport()),
        storage: storage,
      );
      final vm = HomeViewModel(storage, prefs, conn);
      await _settle();

      expect((vm.state as HomeList).grouping, HomeGrouping.none);
      expect(vm.grouping, HomeGrouping.none);

      vm.dispose();
      conn.dispose();
    });

    test('setGrouping persists and survives storage churn', () async {
      final storage = _FakeStorage([_peer('epk_A')]);
      final prefs = Preferences(_FakeSecureStorage());
      final conn = ConnectionManager(
        factory: (_, _) async => PlainPeerChannel(transport: _NoopTransport()),
        storage: storage,
      );
      final vm = HomeViewModel(storage, prefs, conn);
      await _settle();
      expect(vm.grouping, HomeGrouping.workspace);

      await vm.setGrouping(HomeGrouping.device);
      expect(prefs.homeGrouping, HomeGrouping.device);

      // Same trap the filter had: a peer write reloads the list.
      await storage.savePeer(_peer('epk_A', nickname: 'Mac'));
      await _settle();
      expect(
        (vm.state as HomeList).grouping,
        HomeGrouping.device,
        reason: 'a storage write must not reset the chosen layout',
      );

      vm.dispose();
      conn.dispose();
    });

    test('grouping does not change WHICH sessions are listed', () {
      // It is a presentation choice: the data is grouped identically either
      // way, only the headers differ.
      final list = HomeList(
        peers: [_peer('A')],
        roomsByPeer: {
          'A': const [
            RoomInfo(roomId: 's1', startedAt: 1, workspacePath: '/w/api'),
            RoomInfo(roomId: 's2', startedAt: 2, workspacePath: '/w/web'),
          ],
        },
      );
      for (final g in HomeGrouping.values) {
        final rows = list.copyWith(grouping: g).groups().expand((d) => d.sessions);
        expect(rows.map((i) => i.room.roomId).toList(), ['s1', 's2']);
      }
    });
  });
}
