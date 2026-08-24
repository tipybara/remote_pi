import 'package:app/data/transport/epk_encoding.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:flutter/foundation.dart' show listEquals, mapEquals;

sealed class HomeState {
  const HomeState();
}

/// Plan-38 Fase 3 — which presence slice of the Home list is shown.
/// Pure view filter over the existing (peer → room) list; the tabs never
/// reload or regroup data. Default is [online] (see [HomeList.filter]).
///
///   - [all]     — every known session (live + cached/offline).
///   - [online]  — only sessions live on the relay right now.
///   - [offline] — only cached sessions that aren't live.
enum HomeFilter { all, online, offline }

/// Plan 61 Phase 2 (follow-up) — how deep Home groups the list.
///
/// The hierarchy is a PRESENTATION choice, not a data one: `HomeList.groups()`
/// always computes Device → Workspace → Session, and this only decides which
/// headers get rendered. A user with one Mac and one folder per project wants
/// the full nesting; a user with one busy folder and eight sessions in it wants
/// none of it, and neither should have to accept the other's layout.
///
///   - [workspace] — Device → Workspace → Session (default).
///   - [device]    — Device → Session. The pre-hierarchy shape.
///   - [none]      — one flat list. Tiles then carry their own device/folder
///                   label, so attribution is not lost with the headers.
enum HomeGrouping {
  workspace('workspace'),
  device('device'),
  none('none');

  final String wire;
  const HomeGrouping(this.wire);

  static HomeGrouping fromWire(String? s) {
    for (final g in values) {
      if (g.wire == s) return g;
    }
    return HomeGrouping.workspace;
  }
}

class HomeLoading extends HomeState {
  const HomeLoading();
}

class HomeNoPeer extends HomeState {
  const HomeNoPeer();
}

/// Plan 17 — single row on Home: a Pi room (per-cwd session) bound to
/// a paired Mac. Multiple HomeItems per peer when the Mac runs more
/// than one Pi session. When `roomId == 'main'` (the only room from a
/// legacy/single-cwd Pi), the UI may collapse the cwd subtitle.
class HomeItem {
  final PeerRecord peer;
  final RoomInfo room;

  const HomeItem({required this.peer, required this.room});

  /// Display name preference: explicit room.name → cwd basename →
  /// `<peer-nickname>` → fallback session_name.
  String get displayName {
    if (room.name != null && room.name!.isNotEmpty) return room.name!;
    final cwd = room.cwd;
    if (cwd != null && cwd.isNotEmpty) {
      final last = cwd.split('/').where((s) => s.isNotEmpty).toList();
      if (last.isNotEmpty) return last.last;
    }
    if (peer.nickname != null && peer.nickname!.isNotEmpty) {
      return peer.nickname!;
    }
    return peer.sessionName;
  }

  /// Plan-61 Fase 0 — the stable identity of this row: `<epk>|<roomId>`,
  /// with the epk normalised so the url-safe (storage / QR) and standard
  /// (relay) encodings of the same key never produce two different rows.
  ///
  /// Used as the widget `ValueKey` on Home tiles so Flutter re-uses the
  /// element for the SAME session instead of the same list position — the
  /// mechanic behind tiles visually "jumping" when the list reorders or a
  /// room goes offline. Phase 1 replaces `roomId` here with `session_id`.
  String get sessionKey => '${toStandardB64(peer.remoteEpk)}|${room.roomId}';

  /// Plan 61 Phase 2 — the workspace this session belongs to, for grouping.
  ///
  /// Prefers the canonical `workspace_path` the Pi publishes; falls back to
  /// `cwd` (which pre-plan-61 Pis send instead and which holds the same path),
  /// then to the empty string so sessions with no directory at all collapse
  /// into a single "unknown" group instead of one header each.
  String get workspacePath => room.workspacePath ?? room.cwd ?? '';

  /// Identity is `(epk, roomId)` — nothing else.
  ///
  /// Plan-61 Fase 0: the old implementation compared the whole [RoomInfo],
  /// whose `==` covers `working`, `startedAt`, `model` and `thinking`.
  /// `working` flips twice per turn and `startedAt` is re-stamped by the
  /// relay on every reconnect, so two `HomeItem`s for the *same* session
  /// compared unequal several times a minute. Volatile metadata must not
  /// be able to say "this is a different session". Display still reads the
  /// live [room] fields, and `HomeList.==` still diffs `roomsByPeer` (real
  /// `RoomInfo` equality), so metadata changes keep repainting.
  @override
  bool operator ==(Object other) =>
      other is HomeItem &&
      toStandardB64(other.peer.remoteEpk) == toStandardB64(peer.remoteEpk) &&
      other.room.roomId == room.roomId;

  @override
  int get hashCode => Object.hash(toStandardB64(peer.remoteEpk), room.roomId);
}

/// Plan 61 Phase 2 — one workspace row on Home: a directory on a machine,
/// holding every session that runs there.
///
/// Grouping key is [path] — the canonical `realpath(cwd)` the Pi publishes as
/// `room_meta.workspace_path`. **Not a primary key** (plan 61 target model):
/// sessions are identified by their own id, and a workspace only decides which
/// header a row sits under. That distinction is why a workspace carries no
/// identity of its own beyond the path string.
class HomeWorkspace {
  /// Canonical path. Empty string for sessions whose Pi published neither
  /// `workspace_path` nor `cwd` — they collapse into one "unknown" group
  /// rather than each inventing a header.
  final String path;
  final List<HomeItem> sessions;

  const HomeWorkspace({required this.path, required this.sessions});

  /// Folder name for the header. Falls back to the full path when it has no
  /// segments (`/`), and to a neutral label when the path is unknown.
  String get displayName {
    if (path.isEmpty) return 'Unknown folder';
    final segs = path.split('/').where((s) => s.isNotEmpty).toList();
    return segs.isEmpty ? path : segs.last;
  }

  @override
  bool operator ==(Object other) =>
      other is HomeWorkspace &&
      other.path == path &&
      listEquals(other.sessions, sessions);

  @override
  int get hashCode => Object.hash(path, Object.hashAll(sessions));
}

/// Plan 61 Phase 2 — one machine on Home, with its workspaces beneath it.
class HomeDevice {
  final PeerRecord peer;
  final List<HomeWorkspace> workspaces;

  const HomeDevice({required this.peer, required this.workspaces});

  /// Device label: nickname → sessionName → epk prefix. Editable, and
  /// therefore never used for ordering (see [HomeList.items]).
  String get displayName {
    if (peer.nickname != null && peer.nickname!.isNotEmpty) return peer.nickname!;
    if (peer.sessionName.isNotEmpty) return peer.sessionName;
    return peer.remoteEpk.length > 8
        ? peer.remoteEpk.substring(0, 8)
        : peer.remoteEpk;
  }

  /// Every session under this device, flattened — the order the list renders.
  Iterable<HomeItem> get sessions => workspaces.expand((w) => w.sessions);

  @override
  bool operator ==(Object other) =>
      other is HomeDevice &&
      other.peer.remoteEpk == peer.remoteEpk &&
      listEquals(other.workspaces, workspaces);

  @override
  int get hashCode => Object.hash(peer.remoteEpk, Object.hashAll(workspaces));
}

/// Paired peers + their live rooms + presence. Items are derived from
/// `roomsByPeer`: a peer with no announced rooms yet still gets one
/// synthetic item (`roomId='main'`) so the user can enter chat — that
/// covers legacy Pis and the pre-room-announce window after reconnect.
class HomeList extends HomeState {
  final List<PeerRecord> peers;
  final Map<String, PresenceState> statusByEpk;
  final Map<String, List<RoomInfo>> roomsByPeer;

  /// Plan-38 Fase 3 — the selected presence tab. Part of the immutable
  /// state (per the `ViewModel<T>` pattern) so the choice is reactive and
  /// survives presence/rooms/status re-emits. Default [HomeFilter.online].
  final HomeFilter filter;

  /// Plan 61 Phase 2 (follow-up) — which grouping headers to render. Part of
  /// the immutable state for the same reason [filter] is: it is user state and
  /// must survive every presence / rooms / storage re-emit.
  final HomeGrouping grouping;

  const HomeList({
    required this.peers,
    this.statusByEpk = const {},
    this.roomsByPeer = const {},
    this.filter = HomeFilter.online,
    this.grouping = HomeGrouping.workspace,
  });

  HomeList copyWith({
    List<PeerRecord>? peers,
    Map<String, PresenceState>? statusByEpk,
    Map<String, List<RoomInfo>>? roomsByPeer,
    HomeFilter? filter,
    HomeGrouping? grouping,
  }) => HomeList(
    peers: peers ?? this.peers,
    statusByEpk: statusByEpk ?? this.statusByEpk,
    roomsByPeer: roomsByPeer ?? this.roomsByPeer,
    filter: filter ?? this.filter,
    grouping: grouping ?? this.grouping,
  );

  /// Flatten to a single ordered list of items: one row per (peer, room).
  /// **Plan-17 follow-up**: peers without any currently-announced rooms
  /// produce ZERO items. Earlier behaviour created a synthetic 'main'
  /// tile for legacy compatibility, but that tile pointed at a (peer,
  /// 'main') destination the Pi was no longer listening on — sending
  /// there got dropped by the relay AND the row felt like a ghost. The
  /// user only wants live rooms in the list.
  ///
  /// Ordering — **Plan-61 Fase 0: never by display name.**
  ///
  /// `listPeers()` reads an unordered secure-storage map and the relay
  /// reorders its room pushes freely, so `items()` must impose a total
  /// order. It used to do that with the *display label* (nickname →
  /// sessionName; room.name → cwd basename). That made a mutable,
  /// user-editable string act as sort identity: renaming a session — or
  /// the Pi publishing a `room_meta` name — silently moved the row to a
  /// different index, which read as sessions jumping around and (before
  /// tile keys existed) handed the tapped position to a different chat.
  ///
  /// Order now comes from immutable-per-session values only:
  ///   • peers by `pairedAt`, tie-broken by `remoteEpk`
  ///   • rooms by `roomId`
  ///
  /// `startedAt` is deliberately NOT used: the relay re-stamps it every
  /// time the last connection drops and reconnects. Phase 2 replaces this
  /// with the Device → Workspace → Session hierarchy and may sort the
  /// leaf level by `lastMessageAt`.
  List<HomeItem> items({String Function(String)? normalizeEpk}) {
    final sortedPeers = [...peers]
      ..sort((a, b) {
        final byPairedAt = a.pairedAt.compareTo(b.pairedAt);
        if (byPairedAt != 0) return byPairedAt;
        return a.remoteEpk.compareTo(b.remoteEpk);
      });
    final out = <HomeItem>[];
    for (final p in sortedPeers) {
      final key = normalizeEpk != null
          ? normalizeEpk(p.remoteEpk)
          : p.remoteEpk;
      final rooms = roomsByPeer[key];
      if (rooms == null || rooms.isEmpty) continue;
      // Plan 61 Phase 3 — the machine gateway holds a permanent relay room
      // (`role: control`) so the phone can create/start/stop sessions on a Mac
      // with no interactive Pi open. It is a control plane, not a
      // conversation: rendering it as a chat tile would offer the user a chat
      // that answers nothing.
      final sortedRooms = [...rooms.where((r) => !r.isControlRoom)]
        ..sort((a, b) => a.roomId.compareTo(b.roomId));
      for (final r in sortedRooms) {
        out.add(HomeItem(peer: p, room: r));
      }
    }
    return out;
  }

  /// Plan 61 Phase 2 — the Home hierarchy: Device → Workspace → Session.
  ///
  /// Pure regrouping of [items] (or of an already-filtered subset, passed as
  /// [only]) — it never re-reads state, so the presence tabs stay a view over
  /// the same list. Order is inherited from `items()`, so it is still driven by
  /// immutable values, never by an editable label.
  ///
  /// A workspace with no visible session is dropped, and so is a device left
  /// with no workspace: on the Offline tab a machine whose sessions are all
  /// live must not leave an empty header behind.
  List<HomeDevice> groups({
    String Function(String)? normalizeEpk,
    List<HomeItem>? only,
  }) {
    final rows = only ?? items(normalizeEpk: normalizeEpk);
    final devices = <HomeDevice>[];
    // `items()` already emits every row of a device consecutively, and every
    // session of one workspace consecutively within it, so a single pass with
    // two cursors preserves that order without re-sorting.
    var deviceStart = 0;
    while (deviceStart < rows.length) {
      final peer = rows[deviceStart].peer;
      var deviceEnd = deviceStart;
      while (deviceEnd < rows.length &&
          rows[deviceEnd].peer.remoteEpk == peer.remoteEpk) {
        deviceEnd++;
      }
      final workspaces = <HomeWorkspace>[];
      final byPath = <String, List<HomeItem>>{};
      final pathOrder = <String>[];
      for (var i = deviceStart; i < deviceEnd; i++) {
        final key = rows[i].workspacePath;
        if (!byPath.containsKey(key)) {
          byPath[key] = <HomeItem>[];
          pathOrder.add(key);
        }
        byPath[key]!.add(rows[i]);
      }
      // Workspaces sort by path — a stable, non-editable value, unlike the
      // folder label shown in the header.
      pathOrder.sort();
      for (final path in pathOrder) {
        workspaces.add(HomeWorkspace(path: path, sessions: byPath[path]!));
      }
      devices.add(HomeDevice(peer: peer, workspaces: workspaces));
      deviceStart = deviceEnd;
    }
    return devices;
  }

  @override
  bool operator ==(Object other) =>
      other is HomeList &&
      other.filter == filter &&
      other.grouping == grouping &&
      listEquals(other.peers, peers) &&
      mapEquals(other.statusByEpk, statusByEpk) &&
      mapEquals(other.roomsByPeer, roomsByPeer);

  @override
  int get hashCode => Object.hash(
    filter,
    grouping,
    Object.hashAll(peers),
    Object.hashAllUnordered(
      statusByEpk.entries.map((e) => '${e.key}:${e.value.runtimeType}'),
    ),
    Object.hashAllUnordered(
      roomsByPeer.entries.map((e) => '${e.key}:${e.value.length}'),
    ),
  );
}
