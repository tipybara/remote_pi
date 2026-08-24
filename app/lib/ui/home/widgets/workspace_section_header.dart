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
/// Longest path rendered in full. Beyond this the HEAD is dropped.
///
/// A character budget is exact here because the path is drawn in
/// [kMonoFamily] — every glyph is the same width.
const int _kPathBudget = 42;

/// Shorten a path from the FRONT, keeping the tail.
///
/// The tail is the part that disambiguates (`…/proj/api` tells you more than
/// `/Users/jacob/pr…`), so a plain `TextOverflow.ellipsis` — which drops the
/// tail — is the wrong end to cut.
///
/// This used to be done with `textDirection: TextDirection.rtl`, which was a
/// real bug: `/` is a direction-neutral character, so under RTL the LEADING
/// slash was reordered to the visual end and `/Users/jacob/proj/api` rendered
/// as `Users/jacob/proj/api/`. The path was simply displayed wrong. Truncating
/// explicitly keeps the text LTR and the slashes where they belong.
String headTruncatedPath(String path, {int budget = _kPathBudget}) {
  if (path.length <= budget) return path;
  // Reserve one column for the ellipsis itself.
  return '…${path.substring(path.length - (budget - 1))}';
}

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
                    headTruncatedPath(path),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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
