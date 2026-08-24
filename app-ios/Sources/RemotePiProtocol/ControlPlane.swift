import Foundation

/// The App ↔ machine-gateway control plane (plan 61 Phase 3).
///
/// ## Where these frames live
///
/// They are **inner** frames: JSON inside an ``Envelope``'s `ct`, addressed to
/// ``RoomID/control`` on the machine's ``PeerID``. They are not relay control
/// frames — the relay forwards them opaquely like any chat message. The reply
/// shapes are the same `action_ok` / `action_error` the chat actions already
/// use, so one demultiplexer handles both.
///
/// ## Why it exists
///
/// Discovery used to run Pi → `room_announced` → app. No child, no room; no
/// room, nobody to ask. **You needed a Pi to create a Pi.** The supervisor now
/// holds one permanent room per machine so the phone always has an addressee.
///
/// ## Two rules that are not negotiable
///
/// 1. **No paths on the wire.** Every action names an already-registered
///    ``WorkspaceID``. The local UDS `ControlRequest` protocol does take an
///    arbitrary `cwd` and spawns it with `--approve`; tunnelling that through
///    the relay would be user-level RCE, which is why this is a separate wire
///    rather than a tunnel (plan 61, D5).
/// 2. **Mutating actions require an ``IdempotencyKey``.** The gateway refuses a
///    mutating frame without one instead of defaulting it — a per-attempt
///    default deduplicates nothing. The machine keeps the key ≥24h and replays
///    the original outcome, *including the original error*, so a retry loop
///    cannot become a spawn loop.
public enum ControlAction: Hashable, Sendable {
    /// Which folders will this machine accept a session in?
    case workspaceList(id: RequestID)

    /// The machine's session catalogue, optionally filtered to one workspace.
    case sessionList(id: RequestID, workspace: WorkspaceID?)

    /// Spawn a **background** session in a registered workspace.
    ///
    /// v1 is background-only: the gateway rejects an explicit
    /// `background: false` rather than quietly handing back something else, so
    /// this frame always writes `true`.
    ///
    /// `idempotencyKey` must be minted **once per user intent** and reused for
    /// every retry of that intent.
    case createSession(
        id: RequestID,
        idempotencyKey: IdempotencyKey,
        workspace: WorkspaceID,
        displayName: String?
    )

    /// Start a catalogued session that is currently stopped. Also flips the
    /// machine's persisted `desired` state to `running`.
    case sessionStart(id: RequestID, session: SessionID, idempotencyKey: IdempotencyKey)

    /// Stop a running session. Persists `desired: stopped`, so a supervisor
    /// restart does not resurrect a session the user deliberately stopped.
    case sessionStop(id: RequestID, session: SessionID, idempotencyKey: IdempotencyKey)

    /// Rename a catalogued session on the machine.
    ///
    /// Not mutating in the idempotency sense — no key required. `rev` is the
    /// ``RoomMeta/nameRev`` this device last saw, used for optimistic
    /// concurrency: if the machine holds a newer one, another device renamed
    /// first and this request is **refused** rather than silently clobbering.
    case sessionRename(
        id: RequestID,
        session: SessionID,
        displayName: String,
        rev: Int64?
    )

    /// The wire `type`.
    public var name: String {
        switch self {
        case .workspaceList: return "workspace_list"
        case .sessionList: return "session_list"
        case .createSession: return "create_session"
        case .sessionStart: return "session_start"
        case .sessionStop: return "session_stop"
        case .sessionRename: return "session_rename"
        }
    }

    /// The correlation id this action's reply will echo in `in_reply_to`.
    public var id: RequestID {
        switch self {
        case .workspaceList(let id),
             .sessionList(let id, _),
             .createSession(let id, _, _, _),
             .sessionStart(let id, _, _),
             .sessionStop(let id, _, _),
             .sessionRename(let id, _, _, _):
            return id
        }
    }

    /// The inner JSON object, ready to be Base64'd into an ``Envelope``.
    public var jsonObject: [String: Any] {
        var object: [String: Any] = ["type": name, "id": id.rawValue]
        switch self {
        case .workspaceList:
            break

        case .sessionList(_, let workspace):
            // Omitted entirely when nil — an empty string would read as a
            // filter for a workspace named "".
            if let workspace { object["workspace_id"] = workspace.rawValue }

        case .createSession(_, let key, let workspace, let displayName):
            object["idempotency_key"] = key.rawValue
            object["workspace_id"] = workspace.rawValue
            if let displayName { object["display_name"] = displayName }
            object["background"] = true

        case .sessionStart(_, let session, let key),
             .sessionStop(_, let session, let key):
            object["session_id"] = session.rawValue
            object["idempotency_key"] = key.rawValue

        case .sessionRename(_, let session, let displayName, let rev):
            object["session_id"] = session.rawValue
            object["display_name"] = displayName
            if let rev { object["rev"] = rev }
        }
        return object
    }

    public func encoded() throws -> Data {
        try JSONSerialization.data(withJSONObject: jsonObject, options: [])
    }
}

/// One folder the machine will accept a session in.
///
/// Registered locally with `remote-pi create <folder>`; there is no remote
/// "register this path", deliberately.
public struct RemoteWorkspace: Hashable, Sendable, Codable {
    public var workspaceID: WorkspaceID
    /// Canonical `realpath` of the folder. Display only — it can never be sent
    /// back as a target.
    public var path: String
    /// Editable folder label. Falls back to the path when the machine has none.
    public var displayName: String

    public init(workspaceID: WorkspaceID, path: String, displayName: String) {
        self.workspaceID = workspaceID
        self.path = path
        self.displayName = displayName
    }

    public enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case path
        case displayName = "display_name"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspaceID = try container.decode(WorkspaceID.self, forKey: .workspaceID)
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        displayName =
            try container.decodeIfPresent(String.self, forKey: .displayName) ?? path
    }
}

/// Whether the machine intends a session to be up.
///
/// Persisted in `~/.pi/remote/sessions.json`. Before it existed, `stop` was
/// in-memory only and a supervisor restart resurrected a session the user had
/// deliberately stopped.
public enum DesiredState: String, Hashable, Sendable, Codable {
    case running
    case stopped
}

/// How a session was created.
public enum SessionMode: String, Hashable, Sendable, Codable {
    /// A Pi someone started at a terminal.
    case interactive
    /// Spawned by the supervisor — the only mode ``ControlAction/createSession``
    /// can produce.
    case background
}

/// One entry of the machine's session catalogue.
///
/// Note the split between ``desired`` (what the machine intends) and
/// ``running`` (what is actually up right now). They disagree while a spawn is
/// in flight, and after a crash.
public struct RemoteSession: Hashable, Sendable, Codable {
    public var sessionID: SessionID
    public var workspaceID: WorkspaceID
    /// Editable label. Falls back to the session id when unnamed.
    public var displayName: String
    public var mode: SessionMode
    public var desired: DesiredState
    /// Whether the machine reports a live process for this session right now.
    public var running: Bool
    /// Milliseconds since epoch, minted when the catalogue entry was created.
    /// Unlike ``RoomMeta/startedAt`` this one is stable across reconnects, so
    /// it *is* safe to sort by.
    public var createdAt: Int64

    public init(
        sessionID: SessionID,
        workspaceID: WorkspaceID,
        displayName: String,
        mode: SessionMode = .background,
        desired: DesiredState = .running,
        running: Bool = false,
        createdAt: Int64 = 0
    ) {
        self.sessionID = sessionID
        self.workspaceID = workspaceID
        self.displayName = displayName
        self.mode = mode
        self.desired = desired
        self.running = running
        self.createdAt = createdAt
    }

    public enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case workspaceID = "workspace_id"
        case displayName = "display_name"
        case mode
        case desired
        case running
        case createdAt = "created_at"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(SessionID.self, forKey: .sessionID)
        workspaceID = try container.decode(WorkspaceID.self, forKey: .workspaceID)
        displayName =
            try container.decodeIfPresent(String.self, forKey: .displayName)
            ?? sessionID.rawValue
        mode = try container.decodeIfPresent(SessionMode.self, forKey: .mode) ?? .background
        desired = try container.decodeIfPresent(DesiredState.self, forKey: .desired) ?? .running
        running = try container.decodeIfPresent(Bool.self, forKey: .running) ?? false
        createdAt = try container.decodeIfPresent(Int64.self, forKey: .createdAt) ?? 0
    }
}

/// Reply to a ``ControlAction`` — or to a chat action, which uses the same two
/// shapes.
///
/// ```jsonc
/// { "type": "action_ok",    "in_reply_to": "<rpc>", "action": "create_session",
///   "session_id": "…", "workspace_id": "…", "display_name": "…" }
/// { "type": "action_error", "in_reply_to": "<rpc>", "action": "create_session",
///   "error": "unknown workspace: ws_…" }
/// ```
///
/// ## `action_ok` means "spawn requested", not "room is up"
///
/// After a successful ``ControlAction/createSession``, the app must wait for
/// the ``ControlFrame/roomAnnounced(peer:meta:)`` carrying that `session_id`
/// before opening a chat. It must **never** derive the room id itself
/// (plan 61, D8) — even though `room_id == session_id` today, deriving it
/// re-introduces exactly the client-side identity computation plan 61 removed.
public enum ControlReply: Hashable, Sendable {
    case ok(ControlSuccess)
    case error(inReplyTo: RequestID, action: String, message: String)

    /// The payload of an `action_ok`. Which fields are populated depends on
    /// the action: `workspace_list` fills ``workspaces``, `session_list` fills
    /// ``sessions``, and the three mutating actions fill ``session`` (plus
    /// ``workspace``, and ``displayName`` on create).
    public struct ControlSuccess: Hashable, Sendable {
        public var inReplyTo: RequestID
        public var action: String
        public var workspaces: [RemoteWorkspace]
        public var sessions: [RemoteSession]
        public var session: SessionID?
        public var workspace: WorkspaceID?
        public var displayName: String?

        public init(
            inReplyTo: RequestID,
            action: String,
            workspaces: [RemoteWorkspace] = [],
            sessions: [RemoteSession] = [],
            session: SessionID? = nil,
            workspace: WorkspaceID? = nil,
            displayName: String? = nil
        ) {
            self.inReplyTo = inReplyTo
            self.action = action
            self.workspaces = workspaces
            self.sessions = sessions
            self.session = session
            self.workspace = workspace
            self.displayName = displayName
        }
    }

    /// The correlation id this reply answers.
    public var inReplyTo: RequestID {
        switch self {
        case .ok(let success): return success.inReplyTo
        case .error(let id, _, _): return id
        }
    }

    /// Parses an inner reply frame. Returns `nil` when the frame is neither
    /// `action_ok` nor `action_error`.
    public static func parse(_ json: [String: Any]) -> ControlReply? {
        guard let type = json["type"] as? String,
              let inReplyTo = json["in_reply_to"] as? String
        else { return nil }
        let action = (json["action"] as? String) ?? ""

        switch type {
        case "action_ok":
            let sessionID: SessionID? = (json["session_id"] as? String).map { SessionID($0) }
            let workspaceID: WorkspaceID? = (json["workspace_id"] as? String).map {
                WorkspaceID($0)
            }
            return .ok(
                ControlSuccess(
                    inReplyTo: RequestID(inReplyTo),
                    action: action,
                    workspaces: decodeList(json["workspaces"], as: RemoteWorkspace.self),
                    sessions: decodeList(json["sessions"], as: RemoteSession.self),
                    session: sessionID,
                    workspace: workspaceID,
                    displayName: json["display_name"] as? String
                )
            )
        case "action_error":
            return .error(
                inReplyTo: RequestID(inReplyTo),
                action: action,
                message: (json["error"] as? String) ?? "unknown error"
            )
        default:
            return nil
        }
    }

    private static func decodeList<T: Decodable>(_ raw: Any?, as type: T.Type) -> [T] {
        guard let array = raw as? [[String: Any]] else { return [] }
        return array.compactMap { element in
            guard let data = try? JSONSerialization.data(withJSONObject: element) else {
                return nil
            }
            return try? JSONDecoder().decode(T.self, from: data)
        }
    }
}
