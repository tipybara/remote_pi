import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart' show RemoteWorkspace;
import 'package:app/protocol/uuid7.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/home/viewmodels/home_viewmodel.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Plan 61 Phase 3 — "New session" flow: pick a machine, pick one of its
/// registered folders, and let the machine spawn a background Pi there.
///
/// The point of the whole phase: before this, creating a session required
/// already having one — discovery ran Pi → `room_announced` → app, so a Mac
/// with no interactive Pi open was simply unreachable. The supervisor's `ctrl`
/// room is always up, so the phone can now ask.
///
/// Deliberate constraints surfaced in the UI rather than hidden:
///  * Only ALREADY-REGISTERED folders are offered. There is no free-text path
///    field, because a path on the wire plus the daemon's `--approve` would be
///    remote code execution.
///  * The idempotency key is minted ONCE when the sheet opens and reused for
///    every retry, so tapping Create twice cannot spawn two processes.
///  * `action_ok` means "spawn requested". The sheet then waits for the relay
///    to announce the room before handing back a session to open.
Future<({String epk, String sessionId})?> showNewSessionSheet(
  BuildContext context,
  HomeViewModel vm,
) {
  return showModalBottomSheet<({String epk, String sessionId})?>(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.colors.bg,
    builder: (sheetCtx) => _NewSessionSheet(vm: vm),
  );
}

class _NewSessionSheet extends StatefulWidget {
  final HomeViewModel vm;
  const _NewSessionSheet({required this.vm});

  @override
  State<_NewSessionSheet> createState() => _NewSessionSheetState();
}

class _NewSessionSheetState extends State<_NewSessionSheet> {
  /// Minted once per sheet, NOT per attempt — see the class doc.
  final String _idempotencyKey = uuid7();

  PeerRecord? _machine;
  List<RemoteWorkspace>? _workspaces;
  bool _loading = false;
  bool _creating = false;
  String? _error;
  String? _progress;

  @override
  void initState() {
    super.initState();
    final machines = widget.vm.machinesAcceptingSessions;
    if (machines.length == 1) {
      // One connected machine is the overwhelmingly common case; skip a
      // one-option picker.
      _machine = machines.first;
      _loadWorkspaces();
    }
  }

  Future<void> _loadWorkspaces() async {
    final machine = _machine;
    if (machine == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await widget.vm.listRemoteWorkspaces(machine.remoteEpk);
      if (!mounted) return;
      setState(() {
        _workspaces = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _create(RemoteWorkspace ws) async {
    final machine = _machine;
    if (machine == null || _creating) return;
    setState(() {
      _creating = true;
      _error = null;
      _progress = 'Asking ${_machineLabel(machine)} to start a session…';
    });

    final result = await widget.vm.createRemoteSession(
      epk: machine.remoteEpk,
      workspaceId: ws.workspaceId,
      idempotencyKey: _idempotencyKey,
      displayName: ws.displayName,
    );
    if (!mounted) return;
    final sessionId = result.sessionId;
    if (sessionId == null) {
      setState(() {
        _creating = false;
        _progress = null;
        _error = result.error ?? 'Could not create the session.';
      });
      return;
    }

    setState(() => _progress = 'Waiting for the session to come online…');
    final live = await widget.vm.waitForSessionOnline(
      machine.remoteEpk,
      sessionId,
    );
    if (!mounted) return;
    if (!live) {
      // Honest wording: the spawn was accepted, we just stopped waiting. The
      // session may well appear in the list a moment later.
      setState(() {
        _creating = false;
        _progress = null;
        _error = 'Session created, but it has not come online yet. '
            'It will appear in the list when it does.';
      });
      return;
    }
    Navigator.of(context).pop((epk: machine.remoteEpk, sessionId: sessionId));
  }

  static String _machineLabel(PeerRecord p) =>
      (p.nickname?.isNotEmpty ?? false)
      ? p.nickname!
      : p.sessionName.isNotEmpty
      ? p.sessionName
      : p.remoteEpk.substring(0, 8);

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final machines = widget.vm.machinesAcceptingSessions;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
              child: Text(
                'New session',
                style: TextStyle(
                  fontFamily: kMonoFamily,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: colors.text,
                ),
              ),
            ),
            if (machines.isEmpty)
              _Message(
                icon: LucideIcons.plugZap,
                text: 'Connect to a paired Mac first — the machine that will '
                    'run the session has to be reachable.',
              )
            else ...[
              if (_machine == null)
                ...machines.map(
                  (m) => ListTile(
                    leading: Icon(LucideIcons.monitor, color: colors.accent),
                    title: Text(
                      _machineLabel(m),
                      style: TextStyle(color: colors.text),
                    ),
                    onTap: () {
                      setState(() => _machine = m);
                      _loadWorkspaces();
                    },
                  ),
                )
              else ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Text(
                    _machineLabel(_machine!),
                    style: TextStyle(
                      fontFamily: kMonoFamily,
                      fontSize: 11,
                      color: colors.muted,
                      letterSpacing: 1.0,
                    ),
                  ),
                ),
                if (_loading)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Center(
                      child: CircularProgressIndicator(color: colors.accent),
                    ),
                  )
                else if ((_workspaces ?? const []).isEmpty)
                  _Message(
                    icon: LucideIcons.folderX,
                    text: 'This machine has no registered folders yet. Run '
                        '`remote-pi create <folder>` on it — only registered '
                        'folders can be started remotely.',
                  )
                else
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final ws in _workspaces!)
                          ListTile(
                            enabled: !_creating,
                            leading: Icon(
                              LucideIcons.folder,
                              color: _creating ? colors.muted : colors.accent,
                            ),
                            title: Text(
                              ws.displayName,
                              style: TextStyle(color: colors.text),
                            ),
                            subtitle: Text(
                              ws.path,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: kMonoFamily,
                                fontSize: 11,
                                color: colors.muted,
                              ),
                            ),
                            onTap: _creating ? null : () => _create(ws),
                          ),
                      ],
                    ),
                  ),
              ],
            ],
            if (_progress != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                child: Row(
                  children: [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: colors.accent,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _progress!,
                        style: TextStyle(color: colors.muted, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                child: Text(
                  _error!,
                  style: TextStyle(color: colors.error, fontSize: 12),
                ),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Message({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: colors.muted),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: colors.muted, fontSize: 12, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}
