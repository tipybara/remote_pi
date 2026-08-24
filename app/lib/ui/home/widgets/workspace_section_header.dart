import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/home/states/home_state.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Plan 61 Phase 2 — the middle level of the Home hierarchy:
/// Device → **Workspace** → Session.
///
/// Renders the folder a group of sessions runs in. Sits under
/// [PeerSectionHeader] (the machine) and above the session tiles, indented so
/// the nesting reads at a glance without drawing an actual tree.
///
/// The folder NAME is shown, with the full path as a dimmed second line when it
/// adds information. Both are display-only: the workspace is a grouping key,
/// never an identity (plan 61 target model), so nothing here is tappable.
class WorkspaceSectionHeader extends StatelessWidget {
  final HomeWorkspace workspace;

  /// Number of sessions rendered under this header in the current tab. Shown
  /// as a count chip so a collapsed-looking group still says how big it is.
  final int sessionCount;

  const WorkspaceSectionHeader({
    super.key,
    required this.workspace,
    required this.sessionCount,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final name = workspace.displayName;
    // Only show the path when it says something the folder name doesn't.
    final path = workspace.path;
    final showPath = path.isNotEmpty && path != name;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(LucideIcons.folder, size: 13, color: colors.muted),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: kMonoFamily,
                    fontSize: 12,
                    color: colors.muted2,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (showPath)
                  Text(
                    path,
                    maxLines: 1,
                    // Long absolute paths are more useful truncated at the
                    // START — the tail (the folder you are in) is the part
                    // that disambiguates.
                    overflow: TextOverflow.ellipsis,
                    textDirection: TextDirection.rtl,
                    style: TextStyle(
                      fontFamily: kMonoFamily,
                      fontSize: 10,
                      color: colors.muted,
                      height: 1.3,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '$sessionCount',
            style: TextStyle(
              fontFamily: kMonoFamily,
              fontSize: 11,
              color: colors.muted,
            ),
          ),
        ],
      ),
    );
  }
}
