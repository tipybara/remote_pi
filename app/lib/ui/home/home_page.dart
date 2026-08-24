import 'package:app/data/transport/epk_encoding.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart' show RoomInfo;
import 'package:app/routing/adaptive.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/home/states/home_state.dart';
import 'package:app/ui/settings/settings_sheet.dart';
import 'package:app/ui/home/viewmodels/home_viewmodel.dart';
import 'package:app/ui/home/widgets/widgets.dart';
import 'package:app/ui/update/widgets/update_banner.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

/// Plan-18 follow-up — iOS-style large title that collapses into a
/// compact bar when scrolled. Built with `SliverAppBar +
/// FlexibleSpaceBar`. Subtitle shows the first paired Mac + relay
/// status. Body is sectioned by pairing always (single peer also
/// gets the pairing header, per the mock).
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final vm = context.watch<HomeViewModel>();
    final state = vm.state;

    // Plan/tablet — tell the adaptive shell whether Home has anything to
    // list. On a zero-state (no Pi paired / empty list) the shell drops
    // the two-pane split and shows this page full-width + centered. Done
    // post-frame so we never notify mid-build.
    final isZeroState = switch (state) {
      HomeLoading() => false,
      HomeNoPeer() => true,
      HomeList() => state.items(normalizeEpk: toStandardB64).isEmpty,
    };
    final shell = context.read<ShellLayout>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      shell.setZeroState(isZeroState);
    });

    return Scaffold(
      backgroundColor: colors.bg,
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            _buildLargeTitleBar(context, vm, state),
            // Plan 44 — Android-only update notice. Sits at the top of the
            // scroll content (below the title, above the list); shrinks to
            // zero height when there's nothing to announce, so it's invisible
            // on iOS and when no newer version exists.
            const SliverToBoxAdapter(child: UpdateBanner()),
            switch (state) {
              HomeLoading() => SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: CircularProgressIndicator(color: colors.accent),
                ),
              ),
              HomeNoPeer() => const SliverFillRemaining(
                hasScrollBody: false,
                child: _EmptyState(),
              ),
              HomeList() => _buildListSlivers(context, vm, state),
            },
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Large title (iOS-style)
  // ---------------------------------------------------------------------------

  Widget _buildLargeTitleBar(
    BuildContext context,
    HomeViewModel vm,
    HomeState state,
  ) {
    final colors = context.colors;
    final subtitle = _subtitleFor(context, vm, state);
    const maxExpanded = 124.0;
    return SliverAppBar(
      backgroundColor: colors.bg,
      surfaceTintColor: colors.bg,
      elevation: 0,
      scrolledUnderElevation: 0,
      pinned: true,
      stretch: false,
      expandedHeight: maxExpanded,
      collapsedHeight: 56,
      toolbarHeight: 56,
      automaticallyImplyLeading: false,
      actions: [
        // Plan 61 Phase 3 — create a session on a paired machine. Hidden when
        // no machine is reachable rather than shown-and-failing: the control
        // frame rides the active WebSocket, so an unreachable Mac genuinely
        // cannot be asked.
        if (vm.canCreateRemoteSessions &&
            vm.machinesAcceptingSessions.isNotEmpty)
          IconButton(
            tooltip: 'New session',
            icon: Icon(LucideIcons.plus, color: colors.muted2),
            onPressed: () => _newSession(context, vm),
          ),
        IconButton(
          tooltip: 'Settings',
          icon: Icon(LucideIcons.settings, color: colors.muted2),
          // Tablet → bottom sheet (keeps the chat in context); phone →
          // full-screen push. See openSettings.
          onPressed: () => openSettings(context),
        ),
        const SizedBox(width: 4),
      ],
      // Title rendering happens entirely inside flexibleSpace so we
      // can cross-fade between the large form (expanded) and the
      // compact form (collapsed). Using `SliverAppBar.title` here
      // would overlay the compact title on top of the large one
      // while expanded — that was the "two app bars" bug.
      flexibleSpace: LayoutBuilder(
        builder: (ctx, constraints) {
          final maxH = constraints.maxHeight;
          const minH = 56.0;
          // t=1 → fully expanded; t=0 → fully collapsed.
          final t = ((maxH - minH) / (maxExpanded - minH)).clamp(0.0, 1.0);
          return Stack(
            fit: StackFit.expand,
            children: [
              Container(color: colors.bg),
              // Large title block — fades OUT as we collapse.
              Positioned(
                left: 20,
                right: 20,
                bottom: 8,
                child: IgnorePointer(
                  ignoring: t < 0.05,
                  child: Opacity(
                    opacity: t,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Remote Pi',
                          style: brandTextStyle(
                            fontSize: 32,
                            fontWeight: FontWeight.w700,
                            color: colors.text,
                            letterSpacing: -0.5,
                            height: 1.05,
                          ),
                        ),
                        const SizedBox(height: 6),
                        subtitle,
                      ],
                    ),
                  ),
                ),
              ),
              // Compact title — fades IN as we collapse.
              Positioned(
                left: 20,
                right: 64, // leave space for the actions icon
                top: 0,
                height: 56,
                child: IgnorePointer(
                  ignoring: t > 0.95,
                  child: Opacity(
                    opacity: 1 - t,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Remote Pi',
                        style: brandTextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: colors.text,
                          letterSpacing: -0.2,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // Bottom divider — only shows once collapsed.
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Opacity(
                  opacity: 1 - t,
                  child: Divider(color: colors.border, height: 1, thickness: 1),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Subtitle line under "Remote Pi": ● Relay · [Connected|Awaiting pairing|Offline].
  /// Reflects the app→relay WS state (not per-Pi presence) so the
  /// user always knows whether the app itself is reachable.
  ///
  /// `HomeNoPeer` is the special case where no peer is paired yet —
  /// the WS is never opened (its URL embeds the destination peer's
  /// pubkey), so `isRelayConnected` is false but that doesn't mean
  /// the relay is down. Render a neutral "Awaiting pairing" instead
  /// of the alarming amber "Offline".
  Widget _subtitleFor(BuildContext context, HomeViewModel vm, HomeState state) {
    final colors = context.colors;
    final connected = vm.isRelayConnected;
    final awaitingPairing = state is HomeNoPeer;
    final Color dotColor;
    final String statusLabel;
    final Color statusColor;
    if (connected) {
      dotColor = colors.success;
      statusLabel = 'Connected';
      statusColor = colors.muted;
    } else if (awaitingPairing) {
      dotColor = colors.muted;
      statusLabel = 'Awaiting pairing';
      statusColor = colors.muted;
    } else {
      dotColor = colors.warning;
      statusLabel = 'Offline';
      statusColor = colors.warning;
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(shape: BoxShape.circle, color: dotColor),
        ),
        const SizedBox(width: 8),
        Text(
          'Relay',
          style: TextStyle(
            fontFamily: kMonoFamily,
            color: colors.text,
            fontSize: 13,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          '·',
          style: TextStyle(
            fontFamily: kMonoFamily,
            color: colors.muted,
            fontSize: 13,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          statusLabel,
          style: TextStyle(
            fontFamily: kMonoFamily,
            color: statusColor,
            fontSize: 13,
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // List body
  // ---------------------------------------------------------------------------

  Widget _buildListSlivers(
    BuildContext context,
    HomeViewModel vm,
    HomeList state,
  ) {
    final counts = vm.counts;
    // Globally empty (paired Pi, no rooms at all): keep the original lonely
    // state and DON'T show the tabs — there's nothing to filter.
    if (counts.all == 0) {
      return const SliverFillRemaining(
        hasScrollBody: false,
        child: _LonelyEmptyState(),
      );
    }

    // Plan-38 Fase 3 — presence filter at the top of the list. Pure view:
    // tapping a tab only swaps `state.filter` → `vm.visibleItems` re-derives.
    final tabs = SliverToBoxAdapter(
      child: Row(
        children: [
          Expanded(
            child: HomeFilterTabs(
              filter: state.filter,
              counts: counts,
              onSelected: vm.setFilter,
            ),
          ),
          _GroupingButton(vm: vm),
          const SizedBox(width: 12),
        ],
      ),
    );

    final visible = vm.visibleItems;
    if (visible.isEmpty) {
      // Items exist, but none match this tab → per-tab empty state beneath
      // the tabs (which stay visible so the user can switch back).
      return SliverMainAxisGroup(
        slivers: [
          tabs,
          SliverFillRemaining(
            hasScrollBody: false,
            child: HomeFilterEmptyState(filter: state.filter),
          ),
        ],
      );
    }

    // Build the per-peer groups over the VISIBLE items: each group is
    // [header, tile, tile, …]. Plan-18 follow-up — always include a header
    // even when there's a single Mac, per the mock. A peer with no visible
    // item in this filter contributes no header (the `lastEpk` cursor only
    // advances on rows we actually render).
    //
    // Plan 61 Phase 2 — the list is a three-level hierarchy now:
    // Device (machine) → Workspace (folder) → Session. It used to be a flat
    // run of session tiles with one header per machine, which meant a Mac
    // running five sessions across three projects rendered as five
    // indistinguishable rows whose only clue was a cwd basename in the
    // subtitle.
    //
    // Plan-61 Fase 0 — every row carries a stable `ValueKey`. Without one,
    // Flutter matches elements by list POSITION: when the list reorders
    // (a room goes offline, a filter flips, a rename shuffles the order)
    // index 2's element — with its ink ripple, scroll offset and any
    // in-flight animation — is silently handed to a different session.
    // Keying by `HomeItem.sessionKey` (`epk|roomId`) makes the element
    // follow the SESSION instead. Headers are keyed the same way so a
    // workspace appearing or emptying doesn't recycle another one's element.
    //
    // How MUCH of that hierarchy is rendered is the user's choice
    // (`HomeGrouping`): the grouped data is identical either way, only the
    // headers differ. Whatever a header would have said is moved onto the tile
    // instead, so dropping headers never drops attribution.
    final grouping = vm.grouping;
    final children = <Widget>[];
    for (final device in vm.visibleGroups) {
      final epk = toStandardB64(device.peer.remoteEpk);
      if (grouping != HomeGrouping.none) {
        children.add(
          PeerSectionHeader(key: ValueKey('peer|$epk'), peer: device.peer),
        );
      }
      for (final ws in device.workspaces) {
        if (grouping == HomeGrouping.workspace) {
          children.add(
            WorkspaceSectionHeader(
              key: ValueKey('ws|$epk|${ws.path}'),
              workspace: ws,
              sessionCount: ws.sessions.length,
            ),
          );
        }
        for (final it in ws.sessions) {
          children.add(
            _buildItemRowAt(
              context,
              vm,
              state,
              it,
              contextLabel: _contextLabelFor(grouping, device, ws),
            ),
          );
        }
      }
    }
    return SliverMainAxisGroup(
      slivers: [
        tabs,
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(0, 0, 0, 24),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (ctx, i) => children[i],
              childCount: children.length,
            ),
          ),
        ),
      ],
    );
  }

  /// What the suppressed headers would have said, for the tile to carry.
  ///
  /// `workspace` grouping shows both headers → nothing to add. `device` hides
  /// the folder → show the folder. `none` hides both → show machine + folder.
  static String? _contextLabelFor(
    HomeGrouping grouping,
    HomeDevice device,
    HomeWorkspace ws,
  ) {
    final folder = ws.path.isEmpty ? null : ws.displayName;
    return switch (grouping) {
      HomeGrouping.workspace => null,
      HomeGrouping.device => folder,
      HomeGrouping.none => folder == null
          ? device.displayName
          : '${device.displayName} / $folder',
    };
  }

  Widget _buildItemRowAt(
    BuildContext context,
    HomeViewModel vm,
    HomeList state,
    HomeItem it, {
    String? contextLabel,
  }) {
    final colors = context.colors;
    final isLive = vm.isRoomLive(it.peer.remoteEpk, it.room.roomId);
    final isReconnecting = !vm.isRelayConnected;
    final isWorking = vm.isRoomWorking(it.peer.remoteEpk, it.room.roomId);
    // Plan/tablet — highlight the open session, but only in the two-pane
    // layout (on phone the list is covered by the pushed chat, so a
    // persistent highlight would be meaningless).
    final isSelected =
        isWideLayout(context) &&
        context.watch<SessionSelection>().matches(
          it.peer.remoteEpk,
          it.room.roomId,
        );
    return Column(
      key: ValueKey(it.sessionKey),
      mainAxisSize: MainAxisSize.min,
      children: [
        SessionTile(
          peer: it.peer,
          isLive: isLive,
          isReconnecting: isReconnecting,
          isWorking: isWorking,
          isSelected: isSelected,
          room: it.room,
          contextLabel: contextLabel,
          onOpen: () => _open(context, vm, it.peer, it.room),
          onLongPress: () => _showSessionMenu(context, vm, it, isLive: isLive),
        ),
        Divider(color: colors.border, height: 1),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Long-press menu (preserved from prior plan-17 wiring)
  // ---------------------------------------------------------------------------

  void _showSessionMenu(
    BuildContext context,
    HomeViewModel vm,
    HomeItem it, {
    required bool isLive,
  }) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.colors.bg,
      builder: (sheetCtx) {
        final colors = sheetCtx.colors;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(LucideIcons.pencil, color: colors.accent),
                title: Text(
                  'Rename session',
                  style: TextStyle(color: colors.text),
                ),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  _promptRename(context, vm, it);
                },
              ),
              ListTile(
                leading: Icon(
                  LucideIcons.trash2,
                  color: isLive ? colors.muted : colors.error,
                ),
                enabled: !isLive,
                title: Text(
                  'Delete session (local only)',
                  style: TextStyle(color: isLive ? colors.muted : colors.text),
                ),
                subtitle: isLive
                    ? Text(
                        'Only available when the room is offline',
                        style: TextStyle(color: colors.muted, fontSize: 11),
                      )
                    : null,
                onTap: isLive
                    ? null
                    : () {
                        Navigator.of(sheetCtx).pop();
                        _confirmDelete(context, vm, it);
                      },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _promptRename(
    BuildContext context,
    HomeViewModel vm,
    HomeItem it,
  ) async {
    final controller = TextEditingController(text: it.room.name ?? '');
    final result = await showDialog<String?>(
      context: context,
      builder: (dCtx) {
        final colors = dCtx.colors;
        return AlertDialog(
          backgroundColor: colors.bg,
          title: Text('Rename session', style: TextStyle(color: colors.text)),
          content: TextField(
            controller: controller,
            autofocus: true,
            style: TextStyle(color: colors.text, fontFamily: kMonoFamily),
            decoration: InputDecoration(
              hintText: it.room.cwd ?? 'Session',
              hintStyle: TextStyle(color: colors.muted),
              enabledBorder: OutlineInputBorder(
                borderSide: BorderSide(color: colors.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderSide: BorderSide(color: colors.accent),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dCtx).pop(null),
              child: Text('Cancel', style: TextStyle(color: colors.muted)),
            ),
            TextButton(
              onPressed: () => Navigator.of(dCtx).pop(controller.text.trim()),
              child: Text('Save', style: TextStyle(color: colors.accent)),
            ),
          ],
        );
      },
    );
    if (result == null) return;
    // Plan 61 Phase 2 — the rename now travels to the Pi. Surface the reason
    // when it doesn't land: previously every rename looked identical whether
    // or not the Pi ever heard about it.
    final failure = await vm.renameRoom(
      it.peer.remoteEpk,
      it.room.roomId,
      result,
    );
    if (failure == null || !context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(failure),
        backgroundColor: context.colors.bg,
      ),
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    HomeViewModel vm,
    HomeItem it,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dCtx) {
        final colors = dCtx.colors;
        return AlertDialog(
          backgroundColor: colors.bg,
          title: Text('Delete session?', style: TextStyle(color: colors.text)),
          content: Text(
            'Removes locally only. If the session comes back online on '
            'the Pi, it reappears in the list.',
            style: TextStyle(color: colors.muted, fontSize: 12),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dCtx).pop(false),
              child: Text('Cancel', style: TextStyle(color: colors.muted)),
            ),
            TextButton(
              onPressed: () => Navigator.of(dCtx).pop(true),
              child: Text('Delete', style: TextStyle(color: colors.error)),
            ),
          ],
        );
      },
    );
    if (ok != true) return;
    await vm.deleteRoom(it.peer.remoteEpk, it.room.roomId);
  }

  static Future<void> _open(
    BuildContext context,
    HomeViewModel vm,
    PeerRecord peer,
    RoomInfo room,
  ) async {
    // Sets prefs (selectedPeerEpk + room) + switchRoom so a fresh
    // ChatViewModel binds to this session.
    await vm.openSession(peer.remoteEpk, roomId: room.roomId);
    if (!context.mounted) return;
    final title = _titleFor(peer, room);
    // Plan/32g — the device (Mac) name we already know here. The Chat AppBar's
    // line 2 renders this immediately instead of flickering empty/room-title
    // until the PeerRecord loads async.
    final device = _deviceFor(peer);
    // Plan/32g — the live state of this tile (the green dot). Passed so the
    // Chat AppBar's status dot starts correct instead of flashing
    // "reconnecting" before the runtime is read.
    final online = vm.isRoomLive(peer.remoteEpk, room.roomId);
    // Mark the UI selection — drives the tablet detail pane AND the
    // highlighted tile. Set AFTER openSession so the detail's fresh
    // ChatViewModel reads the already-updated prefs.
    context.read<SessionSelection>().select(
      peer.remoteEpk,
      room.roomId,
      title,
      device,
      online,
    );
    // Phone: full-screen chat (root push → native back/swipe). Tablet:
    // the detail pane reacts to the selection above — no nav needed.
    if (!isWideLayout(context)) {
      context.push(
        '/chat',
        extra: {'title': title, 'device': device, 'online': online},
      );
    }
  }

  /// Plan 61 Phase 3 — run the New Session flow and open what it created.
  ///
  /// The sheet only returns once the relay has ANNOUNCED the room, so by the
  /// time we get here the session is genuinely addressable. Opening earlier
  /// would target a room the relay does not know and the first message would be
  /// dropped.
  static Future<void> _newSession(
    BuildContext context,
    HomeViewModel vm,
  ) async {
    final created = await showNewSessionSheet(context, vm);
    if (created == null || !context.mounted) return;
    // Resolve the freshly-announced room from the live snapshot rather than
    // synthesising one — the app must never derive a room id itself.
    final peers = switch (vm.state) {
      HomeList(:final peers) => peers,
      _ => const <PeerRecord>[],
    };
    PeerRecord? peer;
    for (final p in peers) {
      if (toStandardB64(p.remoteEpk) == toStandardB64(created.epk)) {
        peer = p;
        break;
      }
    }
    if (peer == null) return;
    RoomInfo? room;
    for (final r in vm.roomsFor(created.epk)) {
      if (r.roomId == created.sessionId) {
        room = r;
        break;
      }
    }
    if (room == null || !context.mounted) return;
    await _open(context, vm, peer, room);
  }

  /// Plan/32g — the paired-device label for the Chat AppBar's line 2
  /// (nickname → sessionName → epk prefix). Mirrors [ChatPage]'s own peer
  /// resolution so there's no change when the PeerRecord finishes loading.
  static String _deviceFor(PeerRecord peer) =>
      (peer.nickname?.isNotEmpty ?? false)
      ? peer.nickname!
      : peer.sessionName.isNotEmpty
      ? peer.sessionName
      : peer.remoteEpk.substring(0, 8);

  /// Plan/24-fix-title: the peer/room label we already know here, so the
  /// Chat AppBar doesn't show '—' / 'Remote Pi' until the ChatViewModel
  /// loads the PeerRecord + the first room_meta_updated arrives. Prefers
  /// room.name (per-cwd title) → cwd tail → nickname → sessionName.
  static String _titleFor(PeerRecord peer, RoomInfo room) {
    final roomCwdTail = room.cwd
        ?.split('/')
        .where((s) => s.isNotEmpty)
        .lastOrNull;
    return (room.name?.isNotEmpty ?? false)
        ? room.name!
        : (roomCwdTail != null && roomCwdTail.isNotEmpty)
        ? roomCwdTail
        : (peer.nickname?.isNotEmpty ?? false)
        ? peer.nickname!
        : peer.sessionName.isNotEmpty
        ? peer.sessionName
        : peer.remoteEpk.substring(0, 8);
  }
}

/// Plan 61 Phase 2 (follow-up) — grouping-depth picker.
///
/// A menu rather than a Settings row: it is a layout knob the user flips while
/// LOOKING at the list, and the effect is only judgeable in place.
class _GroupingButton extends StatelessWidget {
  final HomeViewModel vm;
  const _GroupingButton({required this.vm});

  static const _labels = {
    HomeGrouping.workspace: 'Device / folder',
    HomeGrouping.device: 'Device only',
    HomeGrouping.none: 'No grouping',
  };

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final current = vm.grouping;
    return PopupMenuButton<HomeGrouping>(
      tooltip: 'Group sessions by…',
      initialValue: current,
      color: colors.bg,
      icon: Icon(LucideIcons.listTree, size: 18, color: colors.muted2),
      onSelected: vm.setGrouping,
      itemBuilder: (_) => [
        for (final g in HomeGrouping.values)
          PopupMenuItem<HomeGrouping>(
            value: g,
            child: Row(
              children: [
                Icon(
                  g == current ? LucideIcons.check : LucideIcons.minus,
                  size: 14,
                  color: g == current ? colors.accent : Colors.transparent,
                ),
                const SizedBox(width: 10),
                Text(
                  _labels[g]!,
                  style: TextStyle(
                    color: colors.text,
                    fontSize: 13,
                    fontFamily: kMonoFamily,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Plan-17 follow-up — soft empty state for paired-but-no-rooms.
class _LonelyEmptyState extends StatelessWidget {
  const _LonelyEmptyState();

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: kMaxContentWidth),
        child: Opacity(
          opacity: 0.35,
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(LucideIcons.moon, color: colors.muted, size: 56),
                const SizedBox(height: 18),
                Text(
                  'Nothing here…',
                  style: TextStyle(
                    fontFamily: kMonoFamily,
                    color: colors.muted2,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'When a paired Pi opens a session, it shows up here.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: kMonoFamily,
                    color: colors.muted,
                    fontSize: 11,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: kMaxContentWidth),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.scanQrCode, color: colors.muted, size: 48),
              const SizedBox(height: 16),
              Text(
                'No pairings yet',
                style: TextStyle(color: colors.muted2, fontSize: 14),
              ),
              const SizedBox(height: 6),
              Text(
                'Scan a QR from your Mac to start.',
                style: TextStyle(color: colors.muted, fontSize: 12),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: () => context.push('/pair'),
                style: FilledButton.styleFrom(
                  backgroundColor: colors.accent,
                  foregroundColor: colors.onAccent,
                ),
                icon: const Icon(LucideIcons.scanQrCode, size: 18),
                label: const Text('Scan QR'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
