import CryptoKit
import Foundation
import RemotePiProtocol

/// The on-device store: paired machines, the session catalogue, transcripts,
/// attachments, UI pointers, and the volatile per-session runtime.
///
/// One SQLite file, one connection, one actor. The actor **is** the serial
/// writer spec 07 §2.1 requires (`SyncService._writeChain`): every mutation is
/// isolated, so two writes can never interleave, and a throwing write cannot
/// poison the next one because there is no shared chain to poison.
///
/// ## What is deliberately not here
///
/// | State | Why not |
/// |---|---|
/// | connection / presence | volatile: lives in this actor's memory, gone at launch (spec §4.3) |
/// | streaming buffer | a partial turn is not history (`sync_service.dart:1-9` #7) |
/// | queued messages | the Pi is SSOT and re-broadcasts on every `session_sync` |
/// | `extension_ui_request` | live request with a TTL |
/// | `room_meta.started_at` / `working` | change on every reconnect (`PROTOCOL.md:221`) |
/// | Owner key, pairing secrets | Keychain, via `RemotePiCrypto` |
///
/// ## Durability
///
/// WAL + `synchronous = NORMAL`, autocommit per logical write. That survives an
/// app kill; only an OS crash can lose the last commit. No write transaction is
/// ever held across a suspension point — ``SQLiteDatabase/transaction(_:)``
/// takes a non-`async` body so it cannot be.
public actor SQLiteSessionStore: SessionStore {
    /// Directory holding the database and the blob directory.
    public let root: URL

    private let database: SQLiteDatabase
    private let blobDirectory: URL

    // Volatile runtime. No table, on purpose: a persisted `online` is read for
    // one frame at launch and lies (`boxes.dart:72-76`).
    private var runtimeStates: [SessionKey: RuntimeState] = [:]

    // Observers.
    private struct MessageObserver {
        let limit: Int
        let continuation: AsyncStream<[MessageRow]>.Continuation
    }
    private var messageObservers: [String: [UUID: MessageObserver]] = [:]
    private var summaryObservers: [UUID: AsyncStream<[SessionSummary]>.Continuation] = [:]
    private var runtimeObservers: [String: [UUID: AsyncStream<RuntimeState>.Continuation]] = [:]

    /// Trap T9 — `session_history` batches are staged until `eos: true`.
    ///
    /// The pi-extension never batches (it hard-codes `eos: true` at all three
    /// emit sites), but the protocol doc says it may. Applying a partial batch
    /// against a store that merges would interleave a half window into the
    /// transcript, so the cost of one array buys immunity to a future Pi.
    private var historyStaging: [String: [HistoryEntry]] = [:]

    // MARK: - Lifecycle

    public init(root: URL) throws {
        self.root = root
        self.blobDirectory = root.appendingPathComponent("blobs", isDirectory: true)

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: blobDirectory, withIntermediateDirectories: true)

        let databaseURL = root.appendingPathComponent("remotepi.sqlite3")
        database = try SQLiteDatabase(path: databaseURL.path)
        try database.execute(Schema.pragmas)
        try database.execute(Schema.ddl)
        try database.execute("PRAGMA user_version = \(Schema.version)")

        Self.applyFileProtection(databaseURL: databaseURL, blobDirectory: blobDirectory)
    }

    /// `Application Support/RemotePi` — **not** `Documents`.
    ///
    /// `Hive.initFlutter('rp_v2')` lands in Documents, which is iCloud-backed
    /// and can be exposed wholesale by `UIFileSharingEnabled` (spec §4.5).
    public static func defaultRoot() throws -> URL {
        try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("RemotePi", isDirectory: true)
    }

    /// Call from `scenePhase == .background`.
    ///
    /// Truncating the WAL at suspension keeps committed pages from sitting in a
    /// `-wal` file that a later crash-on-resume would have to replay.
    public func checkpoint() {
        database.checkpointTruncate()
    }

    private static func applyFileProtection(databaseURL: URL, blobDirectory: URL) {
        // Blobs never need to be in a backup: they are re-downloadable from the
        // Pi's buffer at best and disposable at worst, and they are the bulk of
        // the bytes.
        var blobDirectory = blobDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? blobDirectory.setResourceValues(values)

        #if os(iOS)
            // `…UntilFirstUserAuthentication`, not `…Complete`: a Complete-class
            // file is unreadable while the device is locked, which kills any
            // notification-service or background-refresh path that wants to
            // show the last message.
            let protection: [FileAttributeKey: Any] = [
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
            ]
            for suffix in ["", "-wal", "-shm"] {
                let path = databaseURL.path + suffix
                try? FileManager.default.setAttributes(protection, ofItemAtPath: path)
            }
            try? FileManager.default.setAttributes(protection, ofItemAtPath: blobDirectory.path)
        #endif
    }

    // MARK: - Peers (the `machine` table)

    public func loadPeers() async throws -> [PeerRecord] {
        // `provisional` rows are anchors for a transcript that arrived before
        // the pairing was written; they have no relay URL, so returning one as
        // a pairing would send the reconnect logic at an empty string.
        // `unpaired_at` rows are kept only so their conversations survive
        // (Trap T11) — they are not pairings either.
        let rows = try database.query(
            """
            SELECT epk, relay_url, paired_at, session_name, nickname, hostname,
                   harness_name, harness_version, last_opened_room
              FROM machine
             WHERE provisional = 0 AND unpaired_at IS NULL
             ORDER BY paired_at
            """
        )
        return rows.compactMap { row in
            guard let blob = row.blob("epk"), let peer = PeerID(rawValue: blob) else { return nil }
            return PeerRecord(
                peer: peer,
                relayURL: row.text("relay_url") ?? "",
                pairedAt: row.text("paired_at") ?? "",
                sessionName: row.text("session_name"),
                nickname: row.text("nickname"),
                hostname: row.text("hostname"),
                harnessName: row.text("harness_name"),
                harnessVersion: row.text("harness_version"),
                lastOpenedRoom: row.text("last_opened_room").map { RoomID($0) }
            )
        }
    }

    public func savePeer(_ record: PeerRecord) async throws {
        try database.run(
            """
            INSERT INTO machine (epk, relay_url, paired_at, session_name, nickname,
                                 hostname, harness_name, harness_version,
                                 last_opened_room, provisional, unpaired_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, NULL)
            ON CONFLICT(epk) DO UPDATE SET
              relay_url = excluded.relay_url,
              paired_at = excluded.paired_at,
              session_name = excluded.session_name,
              nickname = excluded.nickname,
              hostname = excluded.hostname,
              harness_name = excluded.harness_name,
              harness_version = excluded.harness_version,
              last_opened_room = excluded.last_opened_room,
              provisional = 0,
              unpaired_at = NULL
            """,
            [
                .blob(record.peer.rawValue),
                .text(record.relayURL),
                .text(record.pairedAt),
                .optionalText(record.sessionName),
                .optionalText(record.nickname),
                .optionalText(record.hostname),
                .optionalText(record.harnessName),
                .optionalText(record.harnessVersion),
                .optionalText(record.lastOpenedRoom?.rawValue),
            ]
        )
        notifySummaries()
    }

    /// Unpairs a machine. **Keeps every conversation.**
    ///
    /// Trap T11: `PairingStorage.wipeAll` erases Keychain records and touches
    /// no transcript, and `boxes.dart:35-38` states the policy — "they are the
    /// user's conversations; deleting them to reclaim space is worse than the
    /// leak". Deleting the `machine` row would cascade the transcripts away, so
    /// unpairing marks instead. ``purgePeer(_:)`` is the explicit destructive
    /// path Settings can offer once it has shown the size.
    public func deletePeer(_ peer: PeerID) async throws {
        try database.run(
            "UPDATE machine SET unpaired_at = ? WHERE epk = ?",
            [.int(Self.nowMilliseconds()), .blob(peer.rawValue)]
        )
        notifySummaries()
    }

    /// Deletes a machine **and everything it owns**: sessions, transcripts,
    /// attachment rows. Only ever from an explicit user action.
    public func purgePeer(_ peer: PeerID) async throws {
        let sessions = try summaries().filter { $0.key.peer == peer }
        try database.run("DELETE FROM machine WHERE epk = ?", [.blob(peer.rawValue)])
        for session in sessions { notifyMessages(session.key) }
        notifySummaries()
    }

    // MARK: - Rooms (the `session` table)

    public func loadRooms(for peer: PeerID) async throws -> [RoomMeta] {
        try summaries(for: peer).map(\.cachedRoomMeta)
    }

    /// Caches the room catalogue for one machine.
    ///
    /// Rooms **absent** from `rooms` are left alone rather than deleted: the
    /// relay only lists rooms that are currently registered, so a Mac that is
    /// asleep publishes nothing, and treating "not listed" as "gone" would wipe
    /// Home every time the machine went offline. `room_ended` and an explicit
    /// delete are the only removals.
    public func saveRooms(_ rooms: [RoomMeta], for peer: PeerID) async throws {
        try database.transaction {
            let machinePK = try ensureMachine(peer)
            for meta in rooms {
                try upsertRoomMeta(meta, machinePK: machinePK)
            }
        }
        notifySummaries()
    }

    /// Applies a `room_meta_updated` patch, honouring the `name_rev` gate.
    ///
    /// Returns `true` when the name actually moved. A **rejected** patch is not
    /// an error: the relay re-broadcasts the current name after rejecting one,
    /// which is how the device that sent a stale patch re-syncs, so an inbound
    /// `name` is not evidence of a rename (`RoomMetaPatch` doc).
    @discardableResult
    public func applyRoomMetaPatch(_ patch: RoomMetaPatch, for session: SessionKey) throws -> Bool {
        var nameMoved = false
        try database.transaction {
            let machinePK = try ensureMachine(session.peer)
            let sessionPK = try ensureSession(session, machinePK: machinePK)
            let current = try database.queryOne(
                "SELECT display_name, name_rev, model, thinking FROM session WHERE session_pk = ?",
                [.int(sessionPK)]
            )
            let storedRev = current?.int("name_rev")

            var assignments: [String] = []
            var values: [SQLValue] = []
            if patch.model.isPresent {
                assignments.append("model = ?")
                values.append(.optionalText(patch.model.applied(to: current?.text("model"))))
            }
            if patch.thinking.isPresent {
                assignments.append("thinking = ?")
                values.append(.optionalText(patch.thinking.applied(to: current?.text("thinking"))))
            }
            // `working` is deliberately dropped: it is live state, not storage
            // (spec §4.3). It reaches the UI through the session layer.
            if patch.nameAccepted(over: storedRev) {
                assignments.append("display_name = ?")
                values.append(.optionalText(patch.name.applied(to: current?.text("display_name"))))
                if let rev = patch.nameRev {
                    assignments.append("name_rev = ?")
                    values.append(.int(rev))
                }
                nameMoved = true
            }
            guard !assignments.isEmpty else { return }
            values.append(.int(sessionPK))
            try database.run(
                "UPDATE session SET \(assignments.joined(separator: ", ")) WHERE session_pk = ?",
                values
            )
        }
        notifySummaries()
        return nameMoved
    }

    /// Every known session, newest activity first.
    public func summaries() throws -> [SessionSummary] {
        try loadSummaries(where: nil, parameters: [])
    }

    public func summaries(for peer: PeerID) throws -> [SessionSummary] {
        try loadSummaries(where: "machine.epk = ?", parameters: [.blob(peer.rawValue)])
    }

    /// Sessions whose machine is unpaired or was never paired.
    ///
    /// Trap T11 wants the conversations kept **and** enumerable, so Settings can
    /// show what they cost and offer deletion. Hive could not answer this at all
    /// — it cannot list boxes.
    public func orphanedSessions() throws -> [SessionSummary] {
        try loadSummaries(
            where: "(machine.unpaired_at IS NOT NULL OR machine.provisional = 1)",
            parameters: []
        )
    }

    /// Drops one session entirely: transcript, attachments and catalogue row.
    public func deleteSession(_ session: SessionKey) throws {
        guard let sessionPK = try sessionPK(for: session) else { return }
        try database.run("DELETE FROM session WHERE session_pk = ?", [.int(sessionPK)])
        notifyMessages(session)
        notifySummaries()
    }

    // MARK: - Selection

    public func loadSelectedSession() async throws -> SessionKey? {
        // Both halves or nothing. Restoring the peer and defaulting the room to
        // `main` is what reopened the wrong chat after a cold start (the
        // `PeerRecord.lastOpenedRoom` note on the seam).
        guard
            let peerText = try appState("selected_peer"),
            let peer = PeerID(base64: peerText),
            let room = try appState("selected_room"), !room.isEmpty
        else { return nil }
        return SessionKey(peer: peer, room: RoomID(room))
    }

    public func saveSelectedSession(_ session: SessionKey?) async throws {
        guard let session else {
            try database.run("DELETE FROM app_state WHERE key IN ('selected_peer','selected_room')")
            return
        }
        try setAppState("selected_peer", session.peer.urlSafeValue)
        try setAppState("selected_room", session.room.rawValue)
    }

    // MARK: - Messages: seam API

    public func loadMessages(for session: SessionKey, limit: Int) async throws -> [StoredMessage] {
        try rows(for: session, limit: limit).map(StoredMessage.init(row:))
    }

    public func appendMessage(_ message: StoredMessage, for session: SessionKey) async throws {
        _ = try upsert(
            HistoryEntry(row: MessageRow(storedMessage: message), images: message.images),
            for: session
        )
    }

    /// Replaces the transcript wholesale.
    ///
    /// This is the seam's shape, and it is **not** what a `session_history`
    /// re-sync should call — see ``applyHistory(_:sessionStartedAt:eos:for:)``.
    /// Trap T1: the Pi answers `session_sync` with at most 30 events and, right
    /// after a Pi restart, with **zero**, so wholesale replacement is how the
    /// Flutter client deletes entire conversations on reconnect.
    public func replaceMessages(_ messages: [StoredMessage], for session: SessionKey) async throws {
        try requireChatRoom(session)
        try database.transaction {
            let machinePK = try ensureMachine(session.peer)
            let sessionPK = try ensureSession(session, machinePK: machinePK)
            try database.run("DELETE FROM message WHERE session_pk = ?", [.int(sessionPK)])
            try database.run("UPDATE session SET next_seq = 0 WHERE session_pk = ?", [.int(sessionPK)])
            for message in messages {
                _ = try insertRow(
                    MessageRow(storedMessage: message),
                    images: message.images,
                    sessionPK: sessionPK
                )
            }
            try refreshLastMessage(sessionPK: sessionPK)
        }
        notifyMessages(session)
        notifySummaries()
    }

    public func deleteMessages(for session: SessionKey) async throws {
        guard let sessionPK = try sessionPK(for: session) else { return }
        try database.transaction {
            try database.run("DELETE FROM message WHERE session_pk = ?", [.int(sessionPK)])
            try database.run(
                """
                UPDATE session
                   SET next_seq = 0, last_message_at = NULL, last_message_preview = NULL
                 WHERE session_pk = ?
                """,
                [.int(sessionPK)]
            )
        }
        historyStaging[session.storageKey] = nil
        notifyMessages(session)
        notifySummaries()
    }

    // MARK: - Messages: native API

    /// Most recent `limit` rows, oldest-first. `limit <= 0` means everything.
    public func rows(for session: SessionKey, limit: Int = 0) throws -> [MessageRow] {
        guard let sessionPK = try sessionPK(for: session) else { return [] }
        return try loadRows(sessionPK: sessionPK, limit: limit)
    }

    /// Writes a row, keyed by `(role, msg_id)`.
    ///
    /// Trap T5: the dedupe key is the pair, never the id. `agent_message`
    /// persists under `in_reply_to` — the *user* message's id — so keying by id
    /// alone would have an assistant row overwrite the question it answers.
    ///
    /// `insertOnly` reproduces `_upsert(… existing ?? …)`: a second delivery of
    /// a compaction or an `agent_message` is a no-op, not an overwrite.
    @discardableResult
    public func upsert(
        _ entry: HistoryEntry,
        for session: SessionKey,
        insertOnly: Bool = false
    ) throws -> MessageRow {
        try requireChatRoom(session)
        let result = try database.transaction { () throws -> MessageRow in
            let machinePK = try ensureMachine(session.peer)
            let sessionPK = try ensureSession(session, machinePK: machinePK)
            let existing = try existingRow(sessionPK: sessionPK, identity: entry.row.id)
            let written: MessageRow
            if let existing {
                if insertOnly { return existing }
                var updated = entry.row
                updated.seq = existing.seq
                // The row keeps the attachments it already has, and `images` on
                // an update are ignored: an echo carries the same picture back
                // (`_firstImage`, `protocol.dart:1326`), and re-attaching it
                // would add a second row pointing at the same blob.
                updated.attachments = existing.attachments
                try updateRow(updated, sessionPK: sessionPK)
                written = updated
            } else {
                written = try insertRow(entry.row, images: entry.images, sessionPK: sessionPK)
            }
            if let preview = Self.preview(text: written.text, hasImage: !entry.images.isEmpty),
                written.role != .divider
            {
                try setLastMessage(preview: preview, at: written.ts, sessionPK: sessionPK)
            }
            return written
        }
        notifyMessages(session)
        notifySummaries()
        return result
    }

    /// The optimistic-send row.
    ///
    /// Conformance item 5: this must be on disk **before** the frame reaches the
    /// socket, and the reap window is measured from the row's `ts`, not from
    /// when a timer was armed — that is what makes the window survive process
    /// death (`sync_service.dart:248-255`). The caller's ordering is
    /// persist → arm timer → send; an offline send still persists, which is what
    /// lets the user see what they typed while the Pi is down.
    @discardableResult
    public func appendPendingUserMessage(
        id: String,
        text: String,
        images: [WireImage] = [],
        ts: Int64,
        steering: Bool = false,
        for session: SessionKey
    ) throws -> MessageRow {
        let row = MessageRow(
            role: .user,
            msgID: id,
            text: text,
            ts: ts,
            pending: true,
            steering: steering
        )
        return try upsert(HistoryEntry(row: row, images: images), for: session)
    }

    /// The local echo: confirm in place, do **not** overwrite text or image.
    ///
    /// `sync_service.dart:502-547` — the local copy wins over the echo's copy.
    /// Returns `false` when no such row exists, which is the *foreign* echo
    /// (typed in the Mac's terminal or on another phone): the caller inserts a
    /// fresh row whose `ts` is the receive time, not the origin time.
    @discardableResult
    public func confirmUserEcho(id: String, for session: SessionKey) throws -> Bool {
        guard let sessionPK = try sessionPK(for: session) else { return false }
        let changed = try database.run(
            """
            UPDATE message SET pending = 0
             WHERE session_pk = ? AND role = 'user' AND msg_id = ?
            """,
            [.int(sessionPK), .text(id)]
        )
        if changed > 0 { notifyMessages(session) }
        return changed > 0
    }

    /// `steer_consumed`: drop the steering label, keep the row.
    /// Passing `nil` clears every steering label in the session.
    public func clearSteering(id: String?, for session: SessionKey) throws {
        guard let sessionPK = try sessionPK(for: session) else { return }
        let changed: Int
        if let id {
            changed = try database.run(
                "UPDATE message SET steering = 0 WHERE session_pk = ? AND role = 'user' AND msg_id = ?",
                [.int(sessionPK), .text(id)]
            )
        } else {
            changed = try database.run(
                "UPDATE message SET steering = 0 WHERE session_pk = ? AND steering = 1",
                [.int(sessionPK)]
            )
        }
        if changed > 0 { notifyMessages(session) }
    }

    /// `tool_result` / `approve_tool`.
    ///
    /// Trap T4 — `result` and `error` are ``PatchField``s, not optionals. Dart's
    /// `ToolEventData.copyWith` writes `result ?? this.result`, so a retried
    /// tool that succeeds with no result **keeps its old error forever**. Absent
    /// preserves; `.clear` actually clears.
    public func updateTool(
        toolCallID: String,
        status: ToolStatus? = nil,
        result: PatchField<Data> = .absent,
        error: PatchField<String> = .absent,
        for session: SessionKey
    ) throws {
        guard let sessionPK = try sessionPK(for: session) else { return }
        var assignments: [String] = []
        var values: [SQLValue] = []
        if let status {
            assignments.append("tool_status = ?")
            values.append(.text(status.rawValue))
        }
        switch result {
        case .absent: break
        case .clear:
            assignments.append("tool_result = NULL")
        case .set(let data):
            assignments.append("tool_result = ?")
            values.append(.blob(data))
        }
        switch error {
        case .absent: break
        case .clear:
            assignments.append("tool_error = NULL")
        case .set(let text):
            assignments.append("tool_error = ?")
            values.append(.text(text))
        }
        guard !assignments.isEmpty else { return }
        values.append(.int(sessionPK))
        values.append(.text(toolCallID))
        let changed = try database.run(
            """
            UPDATE message SET \(assignments.joined(separator: ", "))
             WHERE session_pk = ? AND role = 'tool' AND msg_id = ?
            """,
            values
        )
        if changed > 0 { notifyMessages(session) }
    }

    /// `cancelled`: delete **pending** rows with that id only. A confirmed row
    /// with the same id survives (`_removePendingById`).
    public func removePending(id: String, for session: SessionKey) throws {
        guard let sessionPK = try sessionPK(for: session) else { return }
        let changed = try database.run(
            "DELETE FROM message WHERE session_pk = ? AND msg_id = ? AND pending = 1",
            [.int(sessionPK), .text(id)]
        )
        if changed > 0 {
            notifyMessages(session)
            notifySummaries()
        }
    }

    public func removeMessage(role: MessageRole, msgID: String, for session: SessionKey) throws {
        guard let sessionPK = try sessionPK(for: session) else { return }
        let changed = try database.run(
            "DELETE FROM message WHERE session_pk = ? AND role = ? AND msg_id = ?",
            [.int(sessionPK), .text(role.rawValue), .text(msgID)]
        )
        if changed > 0 {
            notifyMessages(session)
            notifySummaries()
        }
    }

    // MARK: - The pending reap

    /// Default no-echo window: 20 s (`sync_service.dart:99`).
    public static let pendingSendTimeoutMilliseconds: Int64 = 20_000

    /// When each pending row expires, so the session layer can arm one timer per
    /// row after a cold start.
    ///
    /// Conformance item 6: `_loadIndex` re-arms every pending row it finds
    /// (`sync_service.dart:876`) and an already-stale row fires immediately —
    /// a deadline in the past is normal, not an error.
    public func pendingDeadlines(
        for session: SessionKey,
        timeout: Int64 = pendingSendTimeoutMilliseconds
    ) throws -> [(id: String, deadlineMilliseconds: Int64)] {
        guard let sessionPK = try sessionPK(for: session) else { return [] }
        let rows = try database.query(
            "SELECT msg_id, ts FROM message WHERE session_pk = ? AND pending = 1 ORDER BY seq",
            [.int(sessionPK)]
        )
        return rows.compactMap { row in
            guard let id = row.text("msg_id"), let ts = row.int("ts") else { return nil }
            return (id, ts + timeout)
        }
    }

    /// Deletes pending rows whose window has closed, **silently**.
    ///
    /// Conformance item 7: no "failed" bubble. `UserMsgStatus.failed` exists in
    /// the Dart domain enum and is never produced — a failed bubble the user
    /// cannot retry is worse than one that disappears.
    @discardableResult
    public func reapExpiredPending(
        for session: SessionKey,
        now: Int64 = SQLiteSessionStore.nowMilliseconds(),
        timeout: Int64 = pendingSendTimeoutMilliseconds
    ) throws -> [String] {
        try reapPending(for: session, cutoff: now - timeout)
    }

    /// Clears **every** pending row for this `(peer, room)`.
    ///
    /// Conformance item 8, and new behaviour: the relay answers a dest-miss with
    /// a `transport_error` control frame (`PROTOCOL.md:176-187`), which is
    /// faster and more specific than the 20 s backstop. It carries no message
    /// id — the outer envelope has none — so it can only clear the whole
    /// pending set for the room. Keep the ts-based timer as the backstop.
    @discardableResult
    public func reapAllPending(for session: SessionKey) throws -> [String] {
        try reapPending(for: session, cutoff: nil)
    }

    private func reapPending(for session: SessionKey, cutoff: Int64?) throws -> [String] {
        guard let sessionPK = try sessionPK(for: session) else { return [] }
        let condition = cutoff == nil ? "" : " AND ts <= ?"
        var parameters: [SQLValue] = [.int(sessionPK)]
        if let cutoff { parameters.append(.int(cutoff)) }
        let doomed = try database.query(
            "SELECT msg_id FROM message WHERE session_pk = ? AND pending = 1\(condition)",
            parameters
        ).compactMap { $0.text("msg_id") }
        guard !doomed.isEmpty else { return [] }
        try database.run(
            "DELETE FROM message WHERE session_pk = ? AND pending = 1\(condition)",
            parameters
        )
        notifyMessages(session)
        notifySummaries()
        return doomed
    }

    // MARK: - Runtime (volatile)

    public func runtime(for session: SessionKey) -> RuntimeState {
        runtimeStates[session] ?? RuntimeState()
    }

    public func setRuntime(_ state: RuntimeState, for session: SessionKey) {
        guard runtimeStates[session] != state else { return }
        runtimeStates[session] = state
        for continuation in (runtimeObservers[session.storageKey] ?? [:]).values {
            continuation.yield(state)
        }
    }

    // MARK: - Observation

    /// Rows for one session, re-emitted after every write that touches it.
    ///
    /// The current snapshot is yielded synchronously at subscribe time, so a
    /// view never renders empty while waiting for the first change.
    public func messagesStream(for session: SessionKey, limit: Int = 0) -> AsyncStream<[MessageRow]> {
        AsyncStream { continuation in
            let token = UUID()
            let key = session.storageKey
            messageObservers[key, default: [:]][token] = MessageObserver(
                limit: limit,
                continuation: continuation
            )
            continuation.yield((try? rows(for: session, limit: limit)) ?? [])
            continuation.onTermination = { [weak self] _ in
                // Hops back onto the actor: `onTermination` runs on whatever
                // context cancelled the stream.
                Task { await self?.removeMessageObserver(token, key: key) }
            }
        }
    }

    public func sessionsStream() -> AsyncStream<[SessionSummary]> {
        AsyncStream { continuation in
            let token = UUID()
            summaryObservers[token] = continuation
            continuation.yield((try? summaries()) ?? [])
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSummaryObserver(token) }
            }
        }
    }

    public func runtimeStream(for session: SessionKey) -> AsyncStream<RuntimeState> {
        AsyncStream { continuation in
            let token = UUID()
            let key = session.storageKey
            runtimeObservers[key, default: [:]][token] = continuation
            continuation.yield(runtime(for: session))
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeRuntimeObserver(token, key: key) }
            }
        }
    }

    private func removeMessageObserver(_ token: UUID, key: String) {
        messageObservers[key]?[token] = nil
        if messageObservers[key]?.isEmpty == true { messageObservers[key] = nil }
    }

    private func removeSummaryObserver(_ token: UUID) { summaryObservers[token] = nil }

    private func removeRuntimeObserver(_ token: UUID, key: String) {
        runtimeObservers[key]?[token] = nil
        if runtimeObservers[key]?.isEmpty == true { runtimeObservers[key] = nil }
    }

    private func notifyMessages(_ session: SessionKey) {
        guard let observers = messageObservers[session.storageKey], !observers.isEmpty else { return }
        for observer in observers.values {
            observer.continuation.yield((try? rows(for: session, limit: observer.limit)) ?? [])
        }
    }

    private func notifySummaries() {
        guard !summaryObservers.isEmpty else { return }
        let snapshot = (try? summaries()) ?? []
        for continuation in summaryObservers.values { continuation.yield(snapshot) }
    }

    // MARK: - Attachments

    /// Rebuilds the wire form of an attachment.
    ///
    /// Standard Base64, no `data:` prefix — the shape `MessageImage.data` and
    /// `user_message.images[].data` both use. Re-encoding a canonical blob is
    /// byte-identical to what arrived; a non-canonical one is returned verbatim
    /// because it never decoded in the first place.
    public func wireImage(for attachment: AttachmentRef) -> WireImage? {
        let url = blobDirectory.appendingPathComponent(attachment.fileName)
        guard let bytes = try? Data(contentsOf: url) else { return nil }
        let data =
            attachment.canonical
            ? bytes.base64EncodedString()
            : String(decoding: bytes, as: UTF8.self)
        return WireImage(data: data, mime: attachment.mime)
    }

    private func storeBlob(_ image: WireImage) throws -> AttachmentRef {
        // Content-addressed: a history replay echoes the same image back
        // (`_firstImage`, `protocol.dart:1326`), so the same bytes must cost
        // nothing the second time.
        if let bytes = Data(base64Encoded: image.data) {
            let digest = Self.hexDigest(bytes)
            try writeBlobIfNeeded(named: "\(digest).bin", bytes: bytes)
            return AttachmentRef(
                mime: image.mime,
                sha256Hex: digest,
                byteLength: bytes.count,
                canonical: true
            )
        }
        // Not decodable as base64. Keep the string as it arrived rather than
        // dropping an image the user actually sent — a url-safe or otherwise
        // odd spelling from some future sender is not a reason to lose data.
        let raw = Data(image.data.utf8)
        let digest = Self.hexDigest(raw)
        try writeBlobIfNeeded(named: "\(digest).bin", bytes: raw)
        return AttachmentRef(
            mime: image.mime,
            sha256Hex: digest,
            byteLength: raw.count,
            canonical: false
        )
    }

    private func writeBlobIfNeeded(named name: String, bytes: Data) throws {
        let url = blobDirectory.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try bytes.write(to: url, options: .atomic)
    }

    private static func hexDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Helpers used by the SQL layer

    public static func nowMilliseconds() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    /// `_preview` (`sync_service.dart:1162-1165`): 80 characters with an
    /// ellipsis, and a bare image renders as `📷 Image`.
    public static func preview(text: String, hasImage: Bool) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return hasImage ? "📷 Image" : nil }
        guard trimmed.count > 80 else { return trimmed }
        return String(trimmed.prefix(80)) + "…"
    }

    private func requireChatRoom(_ session: SessionKey) throws {
        // Trap T10 — `ctrl` is a valid `(epk, room)` pair and would happily key
        // a transcript, but it carries `action_ok`/`action_error` RPC only. The
        // Flutter client's equivalent guard is structural (only the chat screen
        // calls `activate`), i.e. one refactor away from not existing.
        if session.room.isControl { throw StoreError.controlRoom(session) }
        if let role = try database.queryOne(
            """
            SELECT session.role AS role FROM session
              JOIN machine ON machine.machine_pk = session.machine_pk
             WHERE machine.epk = ? AND session.session_id = ?
            """,
            [.blob(session.peer.rawValue), .text(session.room.rawValue)]
        )?.text("role"), role == RoomRole.control.rawValue {
            throw StoreError.controlRoom(session)
        }
    }

    private func appState(_ key: String) throws -> String? {
        try database.queryOne("SELECT value FROM app_state WHERE key = ?", [.text(key)])?
            .text("value")
    }

    private func setAppState(_ key: String, _ value: String) throws {
        try database.run(
            """
            INSERT INTO app_state (key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """,
            [.text(key), .text(value)]
        )
    }

    // MARK: - Row/session plumbing

    private func ensureMachine(_ peer: PeerID) throws -> Int64 {
        if let existing = try database.queryOne(
            "SELECT machine_pk FROM machine WHERE epk = ?",
            [.blob(peer.rawValue)]
        )?.int("machine_pk") {
            return existing
        }
        // Provisional: a frame arrived before `savePeer`. Anchoring the
        // transcript now and letting `savePeer` fill in the pairing later is
        // better than dropping messages on an ordering race.
        try database.run(
            "INSERT INTO machine (epk, relay_url, paired_at, provisional) VALUES (?, '', '', 1)",
            [.blob(peer.rawValue)]
        )
        return database.lastInsertRowID
    }

    private func sessionPK(for session: SessionKey) throws -> Int64? {
        try database.queryOne(
            """
            SELECT session.session_pk AS session_pk FROM session
              JOIN machine ON machine.machine_pk = session.machine_pk
             WHERE machine.epk = ? AND session.session_id = ?
            """,
            [.blob(session.peer.rawValue), .text(session.room.rawValue)]
        )?.int("session_pk")
    }

    private func ensureSession(_ session: SessionKey, machinePK: Int64) throws -> Int64 {
        if let existing = try sessionPK(for: session) { return existing }
        try database.run(
            "INSERT INTO session (machine_pk, session_id) VALUES (?, ?)",
            [.int(machinePK), .text(session.room.rawValue)]
        )
        return database.lastInsertRowID
    }

    private func upsertRoomMeta(_ meta: RoomMeta, machinePK: Int64) throws {
        let existing = try database.queryOne(
            "SELECT session_pk, display_name, name_rev FROM session WHERE machine_pk = ? AND session_id = ?",
            [.int(machinePK), .text(meta.roomID.rawValue)]
        )
        guard let existing, let sessionPK = existing.int("session_pk") else {
            try database.run(
                """
                INSERT INTO session (machine_pk, session_id, workspace_path, cwd, display_name,
                                     name_rev, role, model, thinking)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .int(machinePK),
                    .text(meta.roomID.rawValue),
                    .optionalText(meta.workspacePath),
                    .optionalText(meta.cwd),
                    .optionalText(meta.name),
                    .optionalInt(meta.nameRev),
                    .optionalText(meta.role),
                    .optionalText(meta.model),
                    .optionalText(meta.thinking),
                ]
            )
            return
        }

        // The rename gate, applied to a full snapshot as well as to a patch:
        // an announcement carrying an older `name_rev` loses to what we hold.
        // The relay does the same comparison in its registry, and a snapshot
        // that arrives out of order (two devices, one reconnecting) is exactly
        // the case the gate exists for.
        let patch = RoomMetaPatch(name: meta.name.map { .set($0) } ?? .clear, nameRev: meta.nameRev)
        let acceptName = patch.nameAccepted(over: existing.int("name_rev"))
        try database.run(
            """
            UPDATE session
               SET workspace_path = ?, cwd = ?, role = ?, model = ?, thinking = ?,
                   display_name = CASE WHEN ? THEN ? ELSE display_name END,
                   name_rev = CASE WHEN ? THEN ? ELSE name_rev END
             WHERE session_pk = ?
            """,
            [
                .optionalText(meta.workspacePath),
                .optionalText(meta.cwd),
                .optionalText(meta.role),
                .optionalText(meta.model),
                .optionalText(meta.thinking),
                .bool(acceptName),
                .optionalText(meta.name),
                .bool(acceptName && meta.nameRev != nil),
                .optionalInt(meta.nameRev),
                .int(sessionPK),
            ]
        )
    }

    private func loadSummaries(where condition: String?, parameters: [SQLValue]) throws -> [SessionSummary] {
        let whereClause = condition.map { "WHERE \($0)" } ?? ""
        let rows = try database.query(
            """
            SELECT machine.epk AS epk, machine.unpaired_at AS unpaired_at,
                   machine.provisional AS provisional,
                   session.session_id AS session_id, session.workspace_id AS workspace_id,
                   session.workspace_path AS workspace_path, session.cwd AS cwd,
                   session.display_name AS display_name, session.name_rev AS name_rev,
                   session.role AS role, session.mode AS mode, session.model AS model,
                   session.thinking AS thinking,
                   session.session_started_at AS session_started_at,
                   session.last_message_at AS last_message_at,
                   session.last_message_preview AS last_message_preview
              FROM session
              JOIN machine ON machine.machine_pk = session.machine_pk
              \(whereClause)
             ORDER BY session.last_message_at DESC, session.session_id
            """,
            parameters
        )
        return rows.compactMap { row in
            guard
                let blob = row.blob("epk"), let peer = PeerID(rawValue: blob),
                let sessionID = row.text("session_id")
            else { return nil }
            let key = SessionKey(peer: peer, room: RoomID(sessionID))
            return SessionSummary(
                key: key,
                // Post plan 61 `room_id == session_id`, but the *presence* of a
                // session id is the signal, not its value — a legacy room whose
                // id is `sha256(cwd)` must not be reported as stable. We only
                // claim one when the id has the shape a Pi mints.
                sessionID: key.room.hasSessionIDShape && !key.room.isControl
                    ? SessionID(sessionID) : nil,
                workspaceID: row.text("workspace_id").map { WorkspaceID($0) },
                workspacePath: row.text("workspace_path"),
                cwd: row.text("cwd"),
                displayName: row.text("display_name"),
                nameRev: row.int("name_rev"),
                role: row.text("role"),
                mode: row.text("mode"),
                model: row.text("model"),
                thinking: row.text("thinking"),
                sessionStartedAt: row.int("session_started_at"),
                lastMessageAt: row.int("last_message_at"),
                lastMessagePreview: row.text("last_message_preview"),
                orphaned: row.int("unpaired_at") != nil || row.bool("provisional")
            )
        }
    }

    private func existingRow(sessionPK: Int64, identity: MessageIdentity) throws -> MessageRow? {
        guard
            let row = try database.queryOne(
                "\(Self.messageColumns) WHERE session_pk = ? AND role = ? AND msg_id = ?",
                [.int(sessionPK), .text(identity.role.rawValue), .text(identity.msgID)]
            )
        else { return nil }
        var built = Self.messageRow(from: row)
        built.attachments = try attachments(sessionPK: sessionPK, seq: built.seq)
        return built
    }

    private static let messageColumns = """
        SELECT seq, role, msg_id, text, ts, pending, steering, tokens_before, in_reply_to,
               tool_call_id, tool_name, tool_status, tool_args, tool_result, tool_error
          FROM message
        """

    private static func messageRow(from row: SQLRow) -> MessageRow {
        var tool: ToolPayload?
        if let toolCallID = row.text("tool_call_id") {
            tool = ToolPayload(
                toolCallID: toolCallID,
                tool: row.text("tool_name") ?? "unknown",
                argsJSON: row.blob("tool_args"),
                status: ToolStatus(wire: row.text("tool_status")),
                resultJSON: row.blob("tool_result"),
                error: row.text("tool_error")
            )
        }
        return MessageRow(
            seq: row.int("seq") ?? 0,
            role: MessageRole(wire: row.text("role")),
            msgID: row.text("msg_id") ?? "",
            text: row.text("text") ?? "",
            ts: row.int("ts") ?? 0,
            pending: row.bool("pending"),
            steering: row.bool("steering"),
            tokensBefore: row.int("tokens_before"),
            inReplyTo: row.text("in_reply_to"),
            tool: tool
        )
    }

    private func loadRows(sessionPK: Int64, limit: Int) throws -> [MessageRow] {
        let sql: String
        var parameters: [SQLValue] = [.int(sessionPK)]
        if limit > 0 {
            // Tail read: newest `limit` by seq, then flipped to oldest-first.
            // The point of the index on (session_pk, seq) is that this does not
            // materialise 5,000 rows to show 50 — which is what
            // `SessionReadRepository.watchMessages` does today (Trap T8).
            sql = """
                SELECT * FROM (
                  \(Self.messageColumns) WHERE session_pk = ? ORDER BY seq DESC LIMIT ?
                ) ORDER BY seq ASC
                """
            parameters.append(.int(Int64(limit)))
        } else {
            sql = "\(Self.messageColumns) WHERE session_pk = ? ORDER BY seq ASC"
        }
        var rows = try database.query(sql, parameters).map(Self.messageRow(from:))
        let byMessage = try attachmentsBySeq(sessionPK: sessionPK)
        for index in rows.indices {
            rows[index].attachments = byMessage[rows[index].seq] ?? []
        }
        return rows
    }

    private func attachments(sessionPK: Int64, seq: Int64) throws -> [AttachmentRef] {
        try database.query(
            """
            SELECT mime, sha256, byte_len, canonical FROM attachment
             WHERE session_pk = ? AND seq = ? ORDER BY ordinal
            """,
            [.int(sessionPK), .int(seq)]
        ).compactMap(Self.attachmentRef(from:))
    }

    private func attachmentsBySeq(sessionPK: Int64) throws -> [Int64: [AttachmentRef]] {
        let rows = try database.query(
            """
            SELECT seq, mime, sha256, byte_len, canonical FROM attachment
             WHERE session_pk = ? ORDER BY seq, ordinal
            """,
            [.int(sessionPK)]
        )
        var result: [Int64: [AttachmentRef]] = [:]
        for row in rows {
            guard let seq = row.int("seq"), let reference = Self.attachmentRef(from: row) else { continue }
            result[seq, default: []].append(reference)
        }
        return result
    }

    private static func attachmentRef(from row: SQLRow) -> AttachmentRef? {
        guard let mime = row.text("mime"), let digest = row.blob("sha256") else { return nil }
        return AttachmentRef(
            mime: mime,
            sha256Hex: digest.map { String(format: "%02x", $0) }.joined(),
            byteLength: Int(row.int("byte_len") ?? 0),
            canonical: row.bool("canonical")
        )
    }

    /// Allocates the next `seq` and writes the row.
    ///
    /// `next_seq` lives on the session row rather than in memory (`_nextSeq`),
    /// so allocation is crash-safe: an app killed between the insert and the
    /// counter bump would otherwise reuse a seq and collide on the primary key.
    /// Both statements are inside the caller's transaction.
    @discardableResult
    private func insertRow(_ row: MessageRow, images: [WireImage], sessionPK: Int64) throws -> MessageRow {
        let nextSeq =
            try database.queryOne("SELECT next_seq FROM session WHERE session_pk = ?", [.int(sessionPK)])?
            .int("next_seq") ?? 0
        var written = row
        written.seq = nextSeq
        try database.run(
            """
            INSERT INTO message (session_pk, seq, role, msg_id, text, ts, pending, steering,
                                 tokens_before, in_reply_to, tool_call_id, tool_name,
                                 tool_status, tool_args, tool_result, tool_error)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            Self.insertParameters(written, sessionPK: sessionPK)
        )
        try database.run(
            "UPDATE session SET next_seq = ? WHERE session_pk = ?",
            [.int(nextSeq + 1), .int(sessionPK)]
        )
        var references: [AttachmentRef] = []
        for (ordinal, image) in images.enumerated() {
            let reference = try storeBlob(image)
            try database.run(
                """
                INSERT INTO attachment (session_pk, seq, ordinal, mime, sha256, byte_len, file_name, canonical)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .int(sessionPK),
                    .int(nextSeq),
                    .int(Int64(ordinal)),
                    .text(reference.mime),
                    .blob(Self.bytes(fromHex: reference.sha256Hex)),
                    .int(Int64(reference.byteLength)),
                    .text(reference.fileName),
                    .bool(reference.canonical),
                ]
            )
            references.append(reference)
        }
        written.attachments = references
        return written
    }

    private func updateRow(_ row: MessageRow, sessionPK: Int64) throws {
        try database.run(
            """
            UPDATE message
               SET text = ?, ts = ?, pending = ?, steering = ?, tokens_before = ?,
                   in_reply_to = ?, tool_call_id = ?, tool_name = ?, tool_status = ?,
                   tool_args = ?, tool_result = ?, tool_error = ?
             WHERE session_pk = ? AND seq = ?
            """,
            [
                .text(row.text),
                .int(row.ts),
                .bool(row.pending),
                .bool(row.steering),
                .optionalInt(row.tokensBefore),
                .optionalText(row.inReplyTo),
                .optionalText(row.tool?.toolCallID),
                .optionalText(row.tool?.tool),
                .optionalText(row.tool?.status.rawValue),
                .optionalBlob(row.tool?.argsJSON),
                .optionalBlob(row.tool?.resultJSON),
                .optionalText(row.tool?.error),
                .int(sessionPK),
                .int(row.seq),
            ]
        )
    }

    private static func insertParameters(_ row: MessageRow, sessionPK: Int64) -> [SQLValue] {
        [
            .int(sessionPK),
            .int(row.seq),
            .text(row.role.rawValue),
            .text(row.msgID),
            .text(row.text),
            .int(row.ts),
            .bool(row.pending),
            .bool(row.steering),
            .optionalInt(row.tokensBefore),
            .optionalText(row.inReplyTo),
            .optionalText(row.tool?.toolCallID),
            .optionalText(row.tool?.tool),
            .optionalText(row.tool?.status.rawValue),
            .optionalBlob(row.tool?.argsJSON),
            .optionalBlob(row.tool?.resultJSON),
            .optionalText(row.tool?.error),
        ]
    }

    private static func bytes(fromHex hex: String) -> Data {
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
            data.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return data
    }

    private func setLastMessage(preview: String, at ts: Int64, sessionPK: Int64) throws {
        try database.run(
            "UPDATE session SET last_message_at = ?, last_message_preview = ? WHERE session_pk = ?",
            [.int(ts), .text(preview), .int(sessionPK)]
        )
    }

    private func refreshLastMessage(sessionPK: Int64) throws {
        let row = try database.queryOne(
            """
            SELECT text, ts, seq FROM message
             WHERE session_pk = ? AND role <> 'divider' ORDER BY seq DESC LIMIT 1
            """,
            [.int(sessionPK)]
        )
        guard let row, let ts = row.int("ts") else { return }
        let hasImage =
            try database.queryOne(
                "SELECT 1 AS present FROM attachment WHERE session_pk = ? AND seq = ? LIMIT 1",
                [.int(sessionPK), .int(row.int("seq") ?? -1)]
            ) != nil
        guard let preview = Self.preview(text: row.text("text") ?? "", hasImage: hasImage) else { return }
        try setLastMessage(preview: preview, at: ts, sessionPK: sessionPK)
    }

    // MARK: - History reconciliation

    /// Stages one `session_history` payload and, on `eos`, reconciles it.
    ///
    /// See ``HistoryOutcome`` and the long comment in `applyStagedHistory`.
    @discardableResult
    public func applyHistory(
        _ entries: [HistoryEntry],
        sessionStartedAt: Int64,
        eos: Bool = true,
        for session: SessionKey
    ) throws -> HistoryOutcome {
        try requireChatRoom(session)
        let key = session.storageKey
        historyStaging[key, default: []].append(contentsOf: entries)
        guard eos else { return HistoryOutcome(applied: false) }
        let staged = historyStaging.removeValue(forKey: key) ?? []
        let outcome = try applyStagedHistory(staged, sessionStartedAt: sessionStartedAt, for: session)
        if outcome.inserted > 0 || outcome.updated > 0 {
            notifyMessages(session)
            notifySummaries()
        }
        return outcome
    }

    /// Reconciles a history window against local rows **without deleting
    /// anything** (Trap T1, conformance item 11).
    ///
    /// The Flutter client truncates the box to the payload
    /// (`_applyHistory` deletes every key `>= desired.length`). The Pi caps the
    /// payload at 30 events and answers with **zero** right after a restart,
    /// so a 500-row conversation is reduced to 30 — or to nothing — on the next
    /// reconnect. That is the single most consequential fact in spec 07 and it
    /// is not reproduced here.
    ///
    /// Matching cannot be by id (Trap T5, and worse): the history replay mints
    /// **fresh ids** for everything. `_mapAgentMessagesToEvents`
    /// (`index.ts:4617`) gives each user event `sync_<ts>`, and each assistant
    /// event `in_reply_to = sync_<ts>`, while the live path stored `cli_<uuid7>`
    /// and `agent_<uuid7>`. So *every* row would look new and the transcript
    /// would double on each reconnect. The window is therefore aligned
    /// **positionally**: find the smallest offset into the local tail where the
    /// whole overlap matches on (role, content), update those rows in place,
    /// and append only the remainder.
    private func applyStagedHistory(
        _ entries: [HistoryEntry],
        sessionStartedAt: Int64,
        for session: SessionKey
    ) throws -> HistoryOutcome {
        try database.transaction { () throws -> HistoryOutcome in
            let machinePK = try ensureMachine(session.peer)
            let sessionPK = try ensureSession(session, machinePK: machinePK)
            let storedStartedAt = try database.queryOne(
                "SELECT session_started_at FROM session WHERE session_pk = ?",
                [.int(sessionPK)]
            )?.int("session_started_at")

            // A Pi that just restarted answers with a *new* `session_started_at`
            // and an empty buffer. `PairOk.sessionStartedAt` was documented for
            // exactly this comparison (`protocol.dart:1266-1270`) and no such
            // comparison exists in `SyncService` — this is the gap being closed.
            let restarted =
                sessionStartedAt != 0 && storedStartedAt != nil && storedStartedAt != sessionStartedAt

            let local = try loadRows(sessionPK: sessionPK, limit: 0)

            // Rule 5: empty window, unchanged clock → do nothing at all. Not
            // even a notification: an idle reconnect must not repaint the chat.
            if entries.isEmpty && !restarted {
                if storedStartedAt == nil && sessionStartedAt != 0 {
                    try database.run(
                        "UPDATE session SET session_started_at = ? WHERE session_pk = ?",
                        [.int(sessionStartedAt), .int(sessionPK)]
                    )
                }
                return HistoryOutcome(applied: true)
            }

            // Trailing un-echoed pendings are not in the window by definition;
            // they must not break the alignment, and they must end up after the
            // synced rows (Dart appends them last, `sync_service.dart:709-713`).
            var alignable = local.filter { $0.role != .divider }
            var trailingPending: [MessageRow] = []
            while let last = alignable.last, last.role == .user, last.pending {
                trailingPending.insert(alignable.removeLast(), at: 0)
            }

            let offset = Self.alignmentOffset(local: alignable, incoming: entries.map(\.row))
            var updated = 0
            var inserted = 0
            var pendingToConfirm = trailingPending

            var appendFrom = entries.count
            for index in entries.indices {
                let localIndex = offset + index
                guard localIndex < alignable.count else {
                    appendFrom = index
                    break
                }
                var target = alignable[localIndex]
                let incoming = entries[index].row
                if Self.merge(incoming: incoming, into: &target) {
                    try updateRow(target, sessionPK: sessionPK)
                    updated += 1
                }
                appendFrom = index + 1
            }

            if restarted && appendFrom < entries.count {
                // The boundary row, instead of deleting what came before it
                // (Trap T1 rule 3). Insert-only: a second sync after the same
                // restart must not stack dividers.
                let divider = MessageRow(
                    role: .divider,
                    msgID: "boundary_\(sessionStartedAt)",
                    text: "",
                    ts: sessionStartedAt
                )
                if try existingRow(sessionPK: sessionPK, identity: divider.id) == nil {
                    _ = try insertRow(divider, images: [], sessionPK: sessionPK)
                    inserted += 1
                }
            }

            for index in appendFrom..<entries.count {
                let entry = entries[index]
                // Second chance for a trailing pending row: its echo comes back
                // under a *different* id (`sync_<ts>`), so identity cannot see
                // it. Confirming the local row beats inserting a twin of it.
                if entry.row.role == .user,
                    let match = pendingToConfirm.firstIndex(where: { $0.text == entry.row.text })
                {
                    var confirmed = pendingToConfirm.remove(at: match)
                    confirmed.pending = false
                    confirmed.steering = false
                    try updateRow(confirmed, sessionPK: sessionPK)
                    updated += 1
                    continue
                }
                _ = try insertRow(entry.row, images: entry.images, sessionPK: sessionPK)
                inserted += 1
            }

            // Move any still-unconfirmed pending row to the tail so the bubble
            // the user is waiting on stays below the freshly synced rows.
            if inserted > 0 {
                for row in pendingToConfirm {
                    try moveRowToTail(row, sessionPK: sessionPK)
                }
            }

            if sessionStartedAt != 0 {
                try database.run(
                    "UPDATE session SET session_started_at = ? WHERE session_pk = ?",
                    [.int(sessionStartedAt), .int(sessionPK)]
                )
            }
            try refreshLastMessage(sessionPK: sessionPK)
            return HistoryOutcome(
                applied: true,
                inserted: inserted,
                updated: updated,
                restartDetected: restarted
            )
        }
    }

    /// Re-keys a row to the end of the session.
    ///
    /// The `attachment` FK is declared `ON UPDATE CASCADE`, so the image rows
    /// follow the seq instead of failing the constraint.
    private func moveRowToTail(_ row: MessageRow, sessionPK: Int64) throws {
        let nextSeq =
            try database.queryOne("SELECT next_seq FROM session WHERE session_pk = ?", [.int(sessionPK)])?
            .int("next_seq") ?? 0
        guard nextSeq > row.seq else { return }
        try database.run(
            "UPDATE message SET seq = ? WHERE session_pk = ? AND seq = ?",
            [.int(nextSeq), .int(sessionPK), .int(row.seq)]
        )
        try database.run(
            "UPDATE session SET next_seq = ? WHERE session_pk = ?",
            [.int(nextSeq + 1), .int(sessionPK)]
        )
    }

    /// Smallest offset where the incoming window lines up with the local tail.
    ///
    /// Smallest, not largest: the smallest offset that matches covers the most
    /// rows, so it produces the fewest inserts. `local.count` (append
    /// everything) is the fallback when nothing lines up.
    static func alignmentOffset(local: [MessageRow], incoming: [MessageRow]) -> Int {
        guard !local.isEmpty, !incoming.isEmpty else { return local.count }
        for offset in 0...local.count {
            let overlap = min(incoming.count, local.count - offset)
            guard overlap > 0 else { break }
            var matched = true
            for index in 0..<overlap where !Self.sameRow(local[offset + index], incoming[index]) {
                matched = false
                break
            }
            if matched { return offset }
        }
        return local.count
    }

    /// Content equality for alignment. Ids are useless here (see
    /// ``applyStagedHistory``), so this compares what the user would call "the
    /// same message".
    private static func sameRow(_ local: MessageRow, _ incoming: MessageRow) -> Bool {
        guard local.role == incoming.role else { return false }
        switch local.role {
        case .tool:
            // `tool_call_id` really is stable across a replay — the Pi echoes
            // the SDK's own id — so it is the strongest signal available.
            return local.tool?.toolCallID == incoming.tool?.toolCallID
        case .compaction:
            // `compaction_<ts>` is derived from the wire ts on both paths
            // (`sync_service.dart:669`, `:839`), so ids do match here.
            return local.msgID == incoming.msgID || local.text == incoming.text
        case .user, .assistant, .divider:
            return local.text == incoming.text
        }
    }

    /// Folds an incoming history row into a matched local row.
    ///
    /// Returns `false` when nothing changed, so an identical re-sync writes
    /// nothing and emits nothing — the "embaralha e some" flicker on every
    /// reconnect was ~2N writes producing ~2N watch events
    /// (`sync_service.dart:714-723`).
    private static func merge(incoming: MessageRow, into target: inout MessageRow) -> Bool {
        let before = target
        // Never blank a local row from an empty history text.
        if !incoming.text.isEmpty { target.text = incoming.text }
        if let tokens = incoming.tokensBefore { target.tokensBefore = tokens }
        if let tool = incoming.tool {
            var merged = target.tool ?? tool
            merged.status = tool.status
            if tool.argsJSON != nil { merged.argsJSON = tool.argsJSON }
            // Absent in the replay means "no result yet", not "clear" — but a
            // present one is authoritative, including a present error.
            if tool.resultJSON != nil { merged.resultJSON = tool.resultJSON }
            if tool.error != nil { merged.error = tool.error }
            target.tool = merged
        }
        // A row the Pi replayed has been accepted: it can no longer be pending,
        // and its steering label is spent.
        target.pending = false
        target.steering = false
        return target != before
    }
}

// MARK: - History payload

/// One `session_history` event, already mapped to a row by the session layer,
/// plus its images (which a ``MessageRow`` cannot carry — Trap T8).
public struct HistoryEntry: Hashable, Sendable {
    public var row: MessageRow
    public var images: [WireImage]

    public init(row: MessageRow, images: [WireImage] = []) {
        self.row = row
        self.images = images
    }
}

/// What a history apply did.
public struct HistoryOutcome: Hashable, Sendable {
    /// `false` while batches are still being staged (`eos` not yet seen).
    public var applied: Bool
    public var inserted: Int
    public var updated: Int
    /// The Pi's `session_started_at` moved: the process restarted, and a
    /// boundary row now separates the two generations.
    public var restartDetected: Bool

    public init(applied: Bool, inserted: Int = 0, updated: Int = 0, restartDetected: Bool = false) {
        self.applied = applied
        self.inserted = inserted
        self.updated = updated
        self.restartDetected = restartDetected
    }
}

// MARK: - Seam bridging

extension MessageRow {
    /// Builds a row from the seam's lossy ``StoredMessage``.
    ///
    /// `StoredMessageRole.event` covers both tool rows and compaction markers.
    /// The id prefix is what tells them apart, and it is reliable because both
    /// prefixes are minted by us: `compaction_<ts>` (`sync_service.dart:669`)
    /// and the SDK's `toolu_…` for tool calls.
    init(storedMessage message: StoredMessage) {
        let role: MessageRole
        switch message.role {
        case .user: role = .user
        case .agent: role = .assistant
        case .event: role = message.id.hasPrefix("compaction_") ? .compaction : .tool
        }
        self.init(
            role: role,
            msgID: message.id,
            text: message.text,
            ts: message.timestamp,
            tool: role == .tool
                ? ToolPayload(toolCallID: message.id, tool: "unknown", status: .completed) : nil
        )
    }
}

extension StoredMessage {
    init(row: MessageRow) {
        let role: StoredMessageRole
        switch row.role {
        case .user: role = .user
        case .assistant: role = .agent
        case .tool, .compaction, .divider: role = .event
        }
        // Images are refs here, not bytes: the seam's `images` array would have
        // to re-read every blob, which is the memory blowup Trap T8 is about.
        // Callers that need pixels ask `wireImage(for:)` per attachment.
        self.init(id: row.msgID, role: role, text: row.text, timestamp: row.ts, images: [])
    }
}
