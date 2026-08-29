import Foundation
import RemotePiProtocol
import RemotePiSession

// ============================================================================
// The Home list, as pure data (spec 08 §7.5, §7.6).
//
// Nothing in this file imports SwiftUI, touches `AppModel`, or performs I/O.
// It takes the Kit's already-ordered `[DeviceGroup]`, a visibility predicate
// and a clock, and returns exactly what the rows render. That is what makes
// the ordering and identity rules — the whole point of plan 61 — testable
// without a simulator.
//
// ── The two rules this file exists to keep ─────────────────────────────────
//
// 1. **Order comes only from immutable values.** `SessionCatalog` already
//    sorts devices by `pairedAt` (tie-broken by the key's wire spelling),
//    workspaces by `path`, and sessions by `roomId`. This file NEVER re-sorts:
//    it preserves the incoming order verbatim, filters, and regroups.
//    Re-sorting here by a display name would move a row while the user types
//    a rename; re-sorting by `startedAt` would reshuffle the list on every
//    reconnect, because the relay re-stamps that field every time
//    (spec 08 §13.7).
//
// 2. **Identity is `(PeerID, RoomID)`.** Every row, workspace header and
//    device header carries a stable `id` built from that pair (plus the path
//    for a workspace). SwiftUI matches `ForEach` elements by `id`; without
//    one it matches by position, and a list that reorders hands index 2's
//    element — with its scroll offset and in-flight animation — to a
//    different session (spec 08 §7.5).
// ============================================================================

// MARK: - Row

/// The right-hand half of a tile's one-line subtitle.
///
/// Exactly one of two things, never both, never two lines: switching grouping
/// must not change row height (spec 08 §7.6), and neither must a model badge
/// arriving.
enum HomeRowDetail: Hashable, Sendable {
    /// The session's model id, already truncated. Painted in `accent`.
    case model(String)
    /// `"Last paired: <relative time>"`, already formatted. Painted in `muted`.
    case lastPaired(String)
}

/// One session row.
///
/// Deliberately carries **no** `startedAt` and no `working` flag: the first is
/// re-stamped on every reconnect and the second flips twice per turn, and
/// neither may be able to influence ordering or identity. Live/working state
/// is asked for per-render from the model, keyed by ``key``.
struct HomeRow: Identifiable, Hashable, Sendable {
    /// The one legitimate identity. Everything else on this struct is display.
    let key: SessionKey

    /// Title preference, from spec 08 §7.6 / `session_tile.dart:169-184`:
    /// `room.name` → last non-empty `cwd` segment → peer nickname → peer
    /// session name → short key.
    let title: String

    /// What the *suppressed* grouping header would have said, or `nil` when
    /// the headers are on screen. Rendered on the SAME line as ``detail``
    /// (spec 08 §7.4, §7.6).
    let contextLabel: String?

    let detail: HomeRowDetail

    /// `room.name` — the rename field's pre-filled text. `nil` means the Pi
    /// has published no label, in which case the field starts empty
    /// (spec 08 §7.7).
    let currentName: String?

    /// The rename field's placeholder: `room.cwd`, else `"Session"`.
    let hintName: String

    /// `ForEach(id:)` and `.id(_:)` both key on this. Same value the store
    /// uses, so a row's identity and its persisted state cannot drift apart.
    var id: String { key.storageKey }
}

// MARK: - Sections

/// One folder on one machine, with the sessions running there.
///
/// A workspace is a **grouping key, not an entity** (plan 61): there is no
/// workspace detail screen, and the header is not tappable.
struct HomeWorkspaceSection: Identifiable, Hashable, Sendable {
    /// The owning machine, so the id cannot collide across two Macs that
    /// happen to have the same folder path.
    let peer: PeerID
    /// The canonical `realpath`. Empty for path-less sessions, which collapse
    /// into a single "Unknown folder" group instead of one header each
    /// (spec 08 §7.5).
    let path: String
    /// Folder basename, else the whole path, else "Unknown folder".
    let title: String
    /// The dimmed second line — present only when the path says something the
    /// folder name does not (`workspace_section_header.dart:57-59`).
    let pathLine: String?
    let rows: [HomeRow]

    /// `ws|<peer>|<path>` — the Flutter widget key, spec 08 §7.5.
    var id: String { "ws|\(peer.urlSafeValue)|\(path)" }
}

/// One machine, with its folders beneath it.
struct HomeDeviceSection: Identifiable, Hashable, Sendable {
    let peer: PeerID
    /// nickname → session name → short key. Editable, so never a sort input.
    let title: String
    let workspaces: [HomeWorkspaceSection]

    /// `peer|<peer>` — the Flutter widget key, spec 08 §7.5.
    var id: String { "peer|\(peer.urlSafeValue)" }

    var rows: [HomeRow] { workspaces.flatMap(\.rows) }
}

// MARK: - Counts

/// Per-tab counts, **independent of the active tab** (spec 08 §7.3): the
/// Online badge says how many are online whether or not Online is selected.
struct HomeSessionCounts: Hashable, Sendable {
    var all = 0
    var online = 0
    var offline = 0

    func count(for filter: SessionFilter) -> Int {
        switch filter {
        case .all: all
        case .online: online
        case .offline: offline
        }
    }
}

// MARK: - Builder

enum HomeListBuilder {
    /// Regroups an already-ordered, already-control-room-free catalog into
    /// render sections.
    ///
    /// - Parameters:
    ///   - devices: `SessionCatalog.build(..., filter: .all)`. **Always `.all`**
    ///     — the visibility filter is applied here so that the counts and the
    ///     rows come from one traversal and one definition of "live".
    ///   - grouping: which headers the user asked for. It changes only which
    ///     headers render and what the tile carries instead; the data is
    ///     identical either way.
    ///   - isVisible: the presence filter, as a predicate on the key. Applied
    ///     **before** regrouping, so an emptied workspace or device leaves no
    ///     dangling header (spec 08 §7.5).
    ///   - now: injected clock, so "Last paired: 3m ago" is testable.
    static func sections(
        devices: [DeviceGroup],
        grouping: HomeGrouping,
        isVisible: (SessionKey) -> Bool,
        now: Date = Date()
    ) -> [HomeDeviceSection] {
        var result: [HomeDeviceSection] = []
        for device in devices {
            let deviceTitle = device.displayName
            var workspaces: [HomeWorkspaceSection] = []

            for workspace in device.workspaces {
                let visible = workspace.sessions.filter { isVisible($0.key) }
                // Drop the header with the group. On the Offline tab a machine
                // whose sessions are all live must not leave an empty header.
                guard !visible.isEmpty else { continue }

                let folderTitle = workspace.displayName
                let context = grouping.contextLabel(
                    device: deviceTitle,
                    // A path-less group has no folder to name, so `device`
                    // grouping contributes nothing and `none` falls back to
                    // the machine alone — matching `_contextLabelFor`
                    // (`home_page.dart:403-416`).
                    folder: workspace.path.isEmpty ? "" : folderTitle
                )

                workspaces.append(
                    HomeWorkspaceSection(
                        peer: device.peer,
                        path: workspace.path,
                        title: folderTitle,
                        pathLine: pathLine(path: workspace.path, title: folderTitle),
                        rows: visible.map {
                            row($0, record: device.record, contextLabel: context, now: now)
                        }
                    )
                )
            }

            guard !workspaces.isEmpty else { continue }
            result.append(
                HomeDeviceSection(peer: device.peer, title: deviceTitle, workspaces: workspaces)
            )
        }
        return result
    }

    /// The three tab counts, from one pass over the unfiltered catalog.
    ///
    /// - Parameter isLive: the **gated** liveness — `relay connected && room
    ///   announced`. When the socket is down nothing is online, which is what
    ///   makes the tab counts agree with the amber "reconnecting" dots
    ///   (spec 08 §7.6.1).
    static func counts(devices: [DeviceGroup], isLive: (SessionKey) -> Bool) -> HomeSessionCounts {
        var counts = HomeSessionCounts()
        for device in devices {
            for workspace in device.workspaces {
                for session in workspace.sessions {
                    counts.all += 1
                    if isLive(session.key) { counts.online += 1 } else { counts.offline += 1 }
                }
            }
        }
        return counts
    }

    // MARK: Row assembly

    private static func row(
        _ session: SessionRow,
        record: PeerRecord?,
        contextLabel: String?,
        now: Date
    ) -> HomeRow {
        HomeRow(
            key: session.key,
            title: title(for: session, record: record),
            contextLabel: contextLabel,
            detail: detail(for: session, record: record, now: now),
            currentName: session.meta.name,
            // `_promptRename`'s hint (spec 08 §7.7). The cwd rather than the
            // workspace path, because that is the field the Flutter dialog
            // shows and it is the one a legacy Pi always publishes.
            hintName: session.meta.cwd.flatMap { $0.isEmpty ? nil : $0 } ?? "Session"
        )
    }

    /// Spec 08 §7.6: `room.name` → last non-empty `cwd` segment → peer
    /// nickname → peer session name → short key.
    ///
    /// Deliberately **not** `SessionRow.displayName`, which falls back to the
    /// raw room id. On Home a machine-scoped opaque id is noise; the device's
    /// own label is what the Flutter tile shows and it is what a user can act
    /// on. The Kit's version stays correct for contexts with no `PeerRecord`.
    static func title(for session: SessionRow, record: PeerRecord?) -> String {
        if let name = session.meta.name, !name.isEmpty { return name }
        if let tail = lastPathSegment(of: session.meta.cwd), !tail.isEmpty { return tail }
        // `workspacePath` is the same canonical value on a current Pi, and the
        // only one present when the relay dropped `cwd` from a snapshot.
        if let tail = lastPathSegment(of: session.workspacePath), !tail.isEmpty { return tail }
        if let nickname = record?.nickname, !nickname.isEmpty { return nickname }
        if let sessionName = record?.sessionName, !sessionName.isEmpty { return sessionName }
        return session.key.peer.shortDescription
    }

    private static func detail(
        for session: SessionRow,
        record: PeerRecord?,
        now: Date
    ) -> HomeRowDetail {
        if let model = session.meta.model, !model.isEmpty {
            return .model(truncateModel(model))
        }
        // NEVER `startedAt` here. It is re-stamped on every reconnect, so
        // rendering it as "last seen" would tell the user the session
        // restarted every time the phone changed networks (spec 08 §13.7).
        guard let pairedAt = record?.pairedAt, !pairedAt.isEmpty else {
            return .lastPaired("Last paired: —")
        }
        return .lastPaired("Last paired: " + RelativeTime.string(fromISO8601: pairedAt, now: now))
    }

    /// `_truncateModel` (`session_tile.dart:269-270`): 24 characters, cut at
    /// 21 plus an ellipsis.
    static func truncateModel(_ name: String) -> String {
        name.count <= 24 ? name : String(name.prefix(21)) + "…"
    }

    /// Show the path only when it says something the folder name does not.
    /// `~`-abbreviated first (terminal redesign), then head-truncated — in
    /// that order, so the abbreviation buys back real characters of tail.
    static func pathLine(path: String, title: String) -> String? {
        guard !path.isEmpty, path != title else { return nil }
        return headTruncatedPath(tildeAbbreviatedPath(path))
    }

    private static func lastPathSegment(of path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return path.split(separator: "/").last.map(String.init)
    }
}
