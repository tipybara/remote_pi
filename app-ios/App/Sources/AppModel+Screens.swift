import Foundation
import RemotePiPairing
import RemotePiProtocol
import RemotePiSession
import RemotePiStore

// ============================================================================
// The rest of what the screen agents asked the integration agent for.
//
// Home wanted four `HomeBackend` members that need `AppModel`'s private
// `coordinator` / `store`; Settings wanted the whole `SettingsAppModelBridge`,
// and until it existed every peer-mutating action failed loudly with
// `SettingsWiringError`; Pairing wanted `setNickname(_:for:)` so it could stop
// opening a second SQLite handle behind `AppModel`'s back.
//
// All of them are here. The stubs in `HomeBackend+AppModel.swift` and the
// runtime cast in `AppModelSettingsHost` now find real implementations.
// ============================================================================

// MARK: - Peer records

extension AppModel {
    /// Set or clear a machine's nickname.
    ///
    /// Writes through the store `AppModel` already owns and refreshes `peers`,
    /// which is what `PeerNicknameWriter` could not do from its own handle —
    /// its write landed in the database but `AppModel`'s in-memory copy kept
    /// the old label until the next launch.
    ///
    /// The nickname is part of the Owner's `mesh_versions` member entry, so
    /// this goes through the *republishing* save: the Owner's other devices
    /// should learn the label too.
    func setNickname(_ nickname: String?, for peer: PeerID) async {
        guard let store else { return }
        do {
            guard var record = try await store.loadPeers().first(where: { $0.peer == peer })
            else { return }
            let trimmed = nickname?.trimmingCharacters(in: .whitespacesAndNewlines)
            // Empty and nil both mean "no nickname"; storing "" would make
            // `displayLabel` render a blank line rather than fall through to
            // the session name.
            record.nickname = (trimmed?.isEmpty ?? true) ? nil : trimmed
            if let directory {
                try await directory.save(record)
            } else {
                try await store.savePeer(record)
            }
            try await reloadPeersFromStore()
        } catch {
            lastError = error.localizedDescription
        }
    }
}

// MARK: - Home

extension AppModel {
    /// `workspace_list` on the machine's `ctrl` room.
    ///
    /// An empty list is a legitimate answer — it means nothing is registered
    /// yet, not that the call failed.
    func homeListWorkspaces(on machine: PeerID) async throws -> [RemoteWorkspace] {
        guard let coordinator else {
            throw HomeBackendUnavailable(capability: "Listing workspaces")
        }
        return try await coordinator.listWorkspaces(on: machine)
    }

    /// `create_session`, awaiting only `action_ok`.
    ///
    /// Deliberately does **not** wait for the room: `action_ok` means "spawn
    /// requested", not "the room is up" (spec 08 §13.10), and the two stages
    /// have different progress copy. `waitForSession` is the second half.
    func homeRequestSession(_ intent: CreateSessionIntent) async throws -> SessionID {
        guard let coordinator else {
            throw HomeBackendUnavailable(capability: "Starting a session")
        }
        switch try await coordinator.createSession(intent) {
        case .online(let id), .acceptedNotYetOnline(let id):
            return id
        case .failed(let message):
            throw HomeBackendUnavailable(capability: message)
        }
    }

    /// Waits for the relay to announce the new room.
    ///
    /// `false` means "created, not online yet" — never "failed" (spec 08 §7.9).
    func homeWaitForSession(_ session: SessionKey, timeout: Duration) async -> Bool {
        guard let coordinator else { return false }
        return await coordinator.registry.waitForRoom(session, timeout: timeout)
    }

    /// Writes a display label into this device's cache only.
    ///
    /// A local affordance: `nil` clears it, which has no equivalent on the
    /// wire (spec 08 §7.7). The rev is left alone deliberately — bumping it
    /// would make a device-local label win over a real `session_rename` from
    /// another device.
    func homeSetLocalSessionName(_ session: SessionKey, to name: String?) async -> Bool {
        guard let store else { return false }
        do {
            _ = try await store.applyRoomMetaPatch(
                RoomMetaPatch(name: name.map { .set($0) } ?? .clear),
                for: session
            )
            rebuildCatalogAfterLocalEdit()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Evicts a session from this device's cache only.
    ///
    /// Nothing is sent to the Pi; if the session is still alive it reappears
    /// on the next announce (spec 08 §7.7). That is why the registry is asked
    /// to forget it too — otherwise the row is deleted from the store and
    /// immediately rebuilt from the live snapshot, and the delete looks like
    /// it did nothing.
    func homeDeleteCachedSession(_ session: SessionKey) async -> String? {
        guard let store else { return "Storage is not open yet." }
        do {
            try await store.deleteSession(session)
            try await store.deleteMessages(for: session)
            drafts[session] = nil
            streamingDrafts[session] = nil
            queuedStates[session] = nil
            byeReasons[session] = nil
            if openedSession?.key == session { adoptOpenedSession(nil) }
            rebuildCatalogAfterLocalEdit()
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

// MARK: - Settings

extension AppModel: SettingsAppModelBridge {
    func settingsSavePeer(_ record: PeerRecord) async throws {
        guard let store else { throw SettingsWiringError(what: "Saving a nickname") }
        if let directory {
            // The republishing save: a nickname rides in the `mesh_versions`
            // member entry, so the Owner's other devices should learn it.
            try await directory.save(record)
        } else {
            try await store.savePeer(record)
        }
        try await reloadPeersFromStore()
    }

    @discardableResult
    func settingsReloadPeers() async throws -> [PeerRecord] {
        try await reloadPeersFromStore()
    }

    func settingsDeletePeerSilent(_ peer: PeerID) async throws {
        guard let store else { throw SettingsWiringError(what: "Revoking a pairing") }
        // `deleteSilent`, never `delete` (spec 08 §9.3 step 3, trap T7). The
        // mutation hook's default publish is refused by the empty-membership
        // safety net when this was the last machine, which leaves the relay
        // holding a blob that still lists the revoked machine — and the next
        // 60 s pull resurrects it locally. The screen model publishes itself,
        // in the right order, with `allowEmpty` computed from what remains.
        if let directory {
            try await directory.deleteSilent(peer)
        } else {
            try await store.deletePeer(peer)
        }
        try await store.purgePeer(peer)
        try await reloadPeersFromStore()
    }

    func settingsClearSelectedSession() async {
        adoptOpenedSession(nil)
        try? await store?.saveSelectedSession(nil)
    }

    func settingsSelectPeerWithoutRoom(_ peer: PeerID) async {
        // The room half belonged to the machine that was just revoked, so
        // carrying it over would restore a session that does not exist on the
        // fallback peer (spec 08 §9.3).
        adoptOpenedSession(nil)
        try? await store?.saveSelectedSession(nil)
        guard var record = peers.first(where: { $0.peer == peer }) else { return }
        record.lastOpenedRoom = nil
        try? await store?.savePeer(record)
        _ = try? await reloadPeersFromStore()
    }

    var settingsActivePeer: PeerID? {
        // The peer the live socket is actually dialled into. `nil` when there
        // is no socket, which is different from "the first paired machine".
        isRelayConnected ? peers.first?.peer : nil
    }

    func settingsDisconnect() async {
        // Distinct from `connect()`, which tears down and immediately
        // re-dials: after revoking the last pairing there is nothing to dial
        // and the socket must simply stop.
        await disconnectForSettings()
    }

    func settingsSubscribe(to peers: [PeerID]) async {
        guard let coordinator else { return }
        await manager?.subscribe(to: peers)
        try? await coordinator.start(watching: peers)
    }

    func settingsPublishMembership(allowEmpty: Bool) async -> MembershipPublish {
        guard let publisher else { return .deferred("membership publishing is not connected") }
        switch await publisher.publish(allowEmpty: allowEmpty) {
        case .ok, .coalesced:
            return .published
        case .refusedEmpty:
            // Never a failed revoke: the local pairing is already gone.
            return .deferred("the relay still lists this machine; it clears on the next publish")
        case .conflict(let current):
            return .deferred("membership changed elsewhere (version \(current.map(String.init) ?? "?"))")
        case .badRequest(let reason), .forbidden(let reason), .failure(let reason):
            return .deferred(reason)
        case .tooLarge:
            return .deferred("membership blob is too large to publish")
        }
    }

    func settingsReevaluateBootPhase() {
        // `BootCoordinator` is `@State` in `RootShell` and is not in the
        // environment, so Settings cannot reach it. It registers this hook in
        // `bind(to:)` instead.
        bootPhaseDidChange?()
    }
}
