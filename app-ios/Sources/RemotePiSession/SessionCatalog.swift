import Foundation
import RemotePiProtocol

// MARK: - Rows

/// One session row: a room on a machine, plus the live state the list renders.
///
/// Identity is ``key`` — `(PeerID, RoomID)` — and **nothing else**. Not the
/// label, not the workspace, not the position in the list. Volatile metadata
/// (`working` flips twice a turn, `startedAt` is re-stamped on every reconnect)
/// must never be able to say "this is a different session": that is what made
/// the Flutter tiles compare unequal several times a minute and jump under the
/// user's finger.
public struct SessionRow: Hashable, Sendable, Identifiable {
    public let key: SessionKey
    public let meta: RoomMeta
    public let isLive: Bool

    public var id: String { key.storageKey }
    public var peer: PeerID { key.peer }

    public init(key: SessionKey, meta: RoomMeta, isLive: Bool) {
        self.key = key
        self.meta = meta
        self.isLive = isLive
    }

    /// The workspace this row groups under.
    ///
    /// `workspace_path` when the Pi publishes it, `cwd` for a pre-plan-61 Pi
    /// (same canonical value), and `""` when there is neither — so rooms with
    /// no directory collapse into one "unknown" group instead of inventing a
    /// header each.
    public var workspacePath: String { meta.effectiveWorkspacePath ?? "" }

    /// Label for the tile: published name → workspace basename → room id.
    ///
    /// Display only. Never a key, never a sort input.
    public var displayName: String {
        if let name = meta.name, !name.isEmpty { return name }
        let basename = WorkspaceGroup.basename(of: workspacePath)
        if !basename.isEmpty { return basename }
        return key.room.rawValue
    }

    /// `true` when this row's id survives a rename — i.e. the Pi published a
    /// `session_id`. Presence of the field is the signal; its value is not
    /// (spec 02 T2).
    public var hasStableIdentity: Bool { meta.hasStableIdentity }
}

/// One directory on one machine, with every session that runs there.
///
/// The path is a grouping key, not a primary key: sessions are identified by
/// their own id and a workspace only decides which header a row sits under.
public struct WorkspaceGroup: Hashable, Sendable, Identifiable {
    public let path: String
    public let sessions: [SessionRow]

    public var id: String { path }

    public init(path: String, sessions: [SessionRow]) {
        self.path = path
        self.sessions = sessions
    }

    public var displayName: String {
        if path.isEmpty { return "Unknown folder" }
        let name = Self.basename(of: path)
        return name.isEmpty ? path : name
    }

    static func basename(of path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? ""
    }
}

/// One machine, with its workspaces beneath it.
public struct DeviceGroup: Hashable, Sendable, Identifiable {
    public let peer: PeerID
    /// The pairing record, when this device is one we have paired with. `nil`
    /// for a machine we only know about from the relay.
    public let record: PeerRecord?
    public let presence: PresenceState
    public let workspaces: [WorkspaceGroup]

    public var id: String { peer.urlSafeValue }

    public init(
        peer: PeerID,
        record: PeerRecord?,
        presence: PresenceState,
        workspaces: [WorkspaceGroup]
    ) {
        self.peer = peer
        self.record = record
        self.presence = presence
        self.workspaces = workspaces
    }

    /// Label: nickname → session name captured at pair time → short key.
    /// Editable, and therefore never used for ordering.
    public var displayName: String {
        if let nickname = record?.nickname, !nickname.isEmpty { return nickname }
        if let sessionName = record?.sessionName, !sessionName.isEmpty { return sessionName }
        return peer.shortDescription
    }

    /// Every session under this device, in render order.
    public var sessions: [SessionRow] { workspaces.flatMap(\.sessions) }
}

/// Which slice of the list to show. A pure view filter — it never reloads or
/// regroups data.
public enum SessionFilter: Hashable, Sendable {
    case all
    case online
    case offline
}

// MARK: - Catalog

/// Builds the Device → Workspace → Session hierarchy from a registry snapshot.
///
/// Pure and synchronous: same inputs, same output, no I/O. That is what lets a
/// view model rebuild on every snapshot without worrying about ordering races.
public enum SessionCatalog {
    /// Groups `peers`' rooms into the render hierarchy.
    ///
    /// ## Ordering — never by an editable or volatile value
    ///
    /// - devices by `pairedAt`, tie-broken by the key's wire spelling;
    /// - workspaces by path;
    /// - sessions by room id.
    ///
    /// `name` is out because the user edits it and the row would move as they
    /// type. `started_at` is out because the relay re-stamps it on every
    /// reconnect, so a flaky network would reorder the list under the user's
    /// finger — literally the bug class plan 61 exists to kill (spec 02 T3).
    ///
    /// The `ctrl` room is dropped here, at the single boundary where rooms
    /// become sessions, so no downstream widget has to remember to filter it
    /// (spec 09 T10).
    ///
    /// Empty groups are dropped: a workspace with no visible session, and a
    /// device left with no workspace, must not leave a bare header behind on
    /// the Offline tab.
    public static func build(
        peers: [PeerRecord],
        snapshot: RegistrySnapshot,
        filter: SessionFilter = .all
    ) -> [DeviceGroup] {
        let ordered = peers.sorted { left, right in
            if left.pairedAt != right.pairedAt { return left.pairedAt < right.pairedAt }
            return left.peer.wireValue < right.peer.wireValue
        }

        var devices: [DeviceGroup] = []
        for record in ordered {
            let group = device(
                peer: record.peer,
                record: record,
                snapshot: snapshot,
                filter: filter
            )
            if !group.workspaces.isEmpty { devices.append(group) }
        }
        return devices
    }

    /// Builds one device group. Exposed for a detail screen that already knows
    /// which machine it is showing.
    public static func device(
        peer: PeerID,
        record: PeerRecord?,
        snapshot: RegistrySnapshot,
        filter: SessionFilter = .all
    ) -> DeviceGroup {
        let rows = sessions(for: peer, snapshot: snapshot, filter: filter)

        var byPath: [String: [SessionRow]] = [:]
        for row in rows { byPath[row.workspacePath, default: []].append(row) }

        let workspaces = byPath.keys.sorted().map { path in
            // `rows` is already ordered by room id, and grouping preserves that
            // order within each bucket, so no second sort is needed.
            WorkspaceGroup(path: path, sessions: byPath[path] ?? [])
        }

        return DeviceGroup(
            peer: peer,
            record: record,
            presence: snapshot.presence(of: peer),
            workspaces: workspaces
        )
    }

    /// The flat, ordered, control-room-free session list for one machine.
    public static func sessions(
        for peer: PeerID,
        snapshot: RegistrySnapshot,
        filter: SessionFilter = .all
    ) -> [SessionRow] {
        snapshot.chatRooms(for: peer)
            .map { meta in
                let key = SessionKey(peer: peer, room: meta.roomID)
                return SessionRow(key: key, meta: meta, isLive: snapshot.isLive(key))
            }
            .filter { row in
                switch filter {
                case .all: return true
                case .online: return row.isLive
                case .offline: return !row.isLive
                }
            }
    }
}
