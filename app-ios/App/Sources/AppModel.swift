import Foundation
import RemotePiCrypto
import RemotePiPairing
import RemotePiProtocol
import RemotePiSession
import RemotePiStore
import RemotePiTransport
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Composition root. Owns the store, the current socket, the coordinator,
/// and the values the UI reads. The six library targets stay UI-free.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case booting
        case ready
        case failed(String)
    }

    enum Connection: Equatable {
        case idle
        case connecting
        case retrying(Int)
        case online
        case offline(String)
    }

    /// What the boot-time Owner-key gate decided (spec 08 §1.1 step 2, §4).
    ///
    /// `BootCoordinator` reads exactly this to pick the launch phase; nothing
    /// else may. Mirrors `RemotePiPairing.OwnerBootResult` — deliberately, so
    /// wiring the real iCloud-Keychain gate (spec 62/05) is a change to
    /// ``boot()`` and not to the shell.
    enum IdentityGate: Equatable {
        /// `boot()` has not run.
        case pending
        /// Usable key. `generated == false` for a key that was *restored*,
        /// which is what keeps an existing user out of the onboarding wizard.
        case ready(generated: Bool)
        /// The key has no persistence path (iCloud Keychain off). Drives the
        /// sticky sync-required gate.
        ///
        /// **Currently unreachable**: `boot()` falls back to a local file key
        /// store so the simulator works without an iCloud account. This case
        /// is the seam — whoever wires `OwnerIdentityBridge` +
        /// `KeychainOwnerIdentityStore` here makes it live, and the shell
        /// already routes it.
        case syncUnavailable(String)
        /// Boot threw. A plain retry, not an iCloud claim.
        case failed(String)
    }

    private(set) var phase: Phase = .booting
    private(set) var identity: IdentityGate = .pending

    /// Persisted user preferences (theme, text size, grouping, onboarding).
    /// Screens read and write this directly; it writes through to defaults.
    let preferences = AppPreferences()
    private(set) var connection: Connection = .idle
    private(set) var peers: [PeerRecord] = []
    private(set) var catalog: [DeviceGroup] = []
    private(set) var ownerShort = ""
    private(set) var keyStoreSource = ""
    var lastError: String?
    var relayURLText: String {
        didSet { UserDefaults.standard.set(relayURLText, forKey: Self.relayDefaultsKey) }
    }
    var filter: SessionFilter = .all {
        didSet { rebuildCatalog() }
    }

    private static let relayDefaultsKey = "relayURL"

    /// The community relay this build ships with.
    ///
    /// The single spelling of "the default relay" in the app. `RelayURL`
    /// (onboarding) and `RelayURLPolicy` (settings) each used to carry their
    /// own copy of this literal and both flagged it as a bug waiting to
    /// happen; they now read this.
    /// `nonisolated` because `AppModel` is `@MainActor` and this is read from
    /// `RelayURL` / `RelayURLPolicy`, which are deliberately actor-free so the
    /// wizard's and Settings' validation stay unit-testable off the main
    /// actor. An immutable `String` is `Sendable`, so there is nothing to
    /// race on.
    nonisolated static let defaultRelayURL = "https://relay.tengfei.site"

    // `internal`, not `private`, so the integration extensions in
    // `AppModel+Requests.swift` / `AppModel+Screens.swift` can reach them.
    // The app target is one module, so this widens nothing outside it — it is
    // the same access the rest of `AppModel.swift` already had.
    var store: SQLiteSessionStore?
    private var keyStore: (any KeyStore)?
    var manager: RelayConnectionManager?
    var transport: ManagedRelayTransport?
    var coordinator: SessionCoordinator?
    private var didRestoreChat = false
    var directory: PeerDirectory?
    var publisher: MeshPublisher?
    private var observeTask: Task<Void, Never>?
    private var inboxTask: Task<Void, Never>?
    /// The relay's view of rooms, liveness and presence. Readable so a screen
    /// model can ask about one session without a second copy of the catalog;
    /// only `AppModel` writes it.
    private(set) var snapshot = RegistrySnapshot()
    var drafts: [SessionKey: [String: String]] = [:]
    private(set) var openedSession: SessionRow?

    // ── Request/reply + live chat signals (see `AppModel+Requests.swift`) ──

    /// Frames sent through ``request(_:to:)`` that are still waiting for the
    /// frame that answers them, keyed by the id we minted.
    ///
    /// One id per *intent*, re-used across retries of that intent — spec 08
    /// §13.9. `request(_:to:)` does not mint ids; its caller does.
    var pendingRequests: [String: CheckedContinuation<ServerMessage, any Error>] = [:]

    /// Live `extension_ui_request` subscribers, per session. `ChatIngest`
    /// deliberately drops these frames on the floor (they are not transcript
    /// rows); this is where the `ask_user` modal picks them up instead.
    var extensionUIFeeds: [SessionKey: [UUID: AsyncStream<ExtensionUIRequest>.Continuation]] = [:]

    /// The turn currently streaming in each session, if any.
    ///
    /// Separate from ``drafts`` on purpose: `drafts` is the *accumulator*
    /// `ChatIngest` writes into the store, this is the *presentation* value
    /// the streaming bubble renders and the chat's working flag is derived
    /// from. They move together but they are not the same thing — the draft
    /// survives an `agent_done` in the store as a persisted assistant row,
    /// and this one must not.
    /// Written only by ``trackStreaming(_:for:)`` on the inbox path and by
    /// teardown. Not `private(set)` because that writer lives in
    /// `AppModel+Requests.swift`, and Swift scopes `private` to the file.
    var streamingDrafts: [SessionKey: StreamingDraft] = [:]

    /// The Pi's last `bye` for a session, and why.
    ///
    /// Kept per session and cleared the moment the relay announces that room
    /// live again: a `bye` from a previous connection is not a fact about this
    /// one, and a sticky one silently locks the composer forever.
    var byeReasons: [SessionKey: String] = [:]

    /// The Pi's queue for each session.
    ///
    /// `queued_message_state` is a **full replacement**, never a delta —
    /// merging it leaves drained items on screen forever.
    var queuedStates: [SessionKey: QueuedMessageState] = [:]

    /// Set by ``BootCoordinator/bind(to:)``.
    ///
    /// Revoking the last pairing resets onboarding (spec 08 §9.3) and the
    /// shell has to react without a relaunch — but the coordinator is `@State`
    /// in `RootShell` and is not in the environment, so Settings cannot reach
    /// it. This is the one wire between them.
    @ObservationIgnored var bootPhaseDidChange: (() -> Void)?

    init() {
        // `--relay <url>` joins the existing `--pair` / `--send` / `--open` /
        // `--rename-to` debug family. It is the only way to point a simulator
        // at a relay on this Mac: the loopback rejection below deliberately
        // drops a *stored* localhost URL (a stale dev setting must not follow
        // a user into a release build), and that rule would otherwise also
        // block a deliberate, per-launch override.
        if let override = Self.launchRelayURL() {
            relayURLText = override
            UserDefaults.standard.set(override, forKey: Self.relayDefaultsKey)
            return
        }
        let stored = UserDefaults.standard.string(forKey: Self.relayDefaultsKey)
        if let stored, !Self.isLoopbackRelay(stored) {
            relayURLText = stored
        } else {
            relayURLText = Self.defaultRelayURL
            UserDefaults.standard.set(Self.defaultRelayURL, forKey: Self.relayDefaultsKey)
        }
    }

    func boot() async {
        do {
            let store = try SQLiteSessionStore(root: try SQLiteSessionStore.defaultRoot())
            self.store = store
            let resolved = await Self.resolveKeyStore(supportRoot: store.root)
            self.keyStore = resolved.store
            self.keyStoreSource = resolved.source
            // Ask before creating: "generated" must mean a genuinely fresh
            // identity. A key restored from the Keychain reports `false`, and
            // that is the difference between a returning user landing on Home
            // and being sent back through onboarding (spec 08 §1.1 step 3).
            let existing = try await resolved.store.loadOwnerKeySeed()
            let seed = try await resolved.store.loadOrCreateOwnerKeySeed()
            let signer = try Ed25519Signer(seed: seed)
            ownerShort = signer.publicKey.shortDescription
            peers = try await store.loadPeers()
            identity = .ready(generated: existing == nil)
            phase = .ready
            if let payload = Self.launchPairPayload() {
                await pair(pasted: payload)
            } else if !peers.isEmpty {
                await connect()
            }
        } catch {
            identity = .failed(error.localizedDescription)
            phase = .failed(error.localizedDescription)
        }
    }

    /// Re-runs the Owner-key gate only — the Sync Required screen's "Check
    /// again" (spec 08 §4). Never re-opens the socket: the gate is about the
    /// key, and the route it unblocks decides what connects next.
    func reloadIdentity() async {
        guard let keyStore else {
            await boot()
            return
        }
        do {
            let existing = try await keyStore.loadOwnerKeySeed()
            let seed = try await keyStore.loadOrCreateOwnerKeySeed()
            ownerShort = try Ed25519Signer(seed: seed).publicKey.shortDescription
            identity = .ready(generated: existing == nil)
        } catch {
            identity = .failed(error.localizedDescription)
        }
    }

    // MARK: - Read models for the UI
    //
    // Screens read these; they do not reach into the Kit. Everything here is
    // derived — no screen may write `AppModel` state except through the
    // `async` action methods below.

    /// `true` once at least one machine is paired. Drives the onboarding
    /// redirect and Home's first-pair empty state.
    var hasPeer: Bool { !peers.isEmpty }

    /// The app↔relay socket is up. This is a property of the **socket**, not
    /// of any room: when it is `false` we have no fresh signal about any
    /// session, which is why `reconnecting` outranks `live` on a presence dot
    /// (spec 08 §7.6.1).
    var isRelayConnected: Bool { connection == .online }

    /// The relay announced this room live. `false` while the socket is down —
    /// the live set is cleared on loss so a stale `true` cannot survive a flap.
    func isLive(_ session: SessionKey) -> Bool {
        isRelayConnected && snapshot.isLive(session)
    }

    /// The relay's per-room `working` flag. Read it for a Home tile exactly as
    /// it is: do **not** OR it with a local "I just sent something" signal at
    /// the list level, or a session that finishes while another chat is open
    /// keeps a blue dot forever (spec 08 §7.6.1).
    func isWorking(_ session: SessionKey) -> Bool {
        // working ⊆ live, by definition: an in-flight turn requires a
        // running, registered process (plan 62 state-sync audit). Without
        // the gate, a stale `working: true` on a cached dead room outranks
        // every other dot state and paints an offline session blue.
        isRelayConnected && snapshot.isLive(session)
            && (snapshot.room(session)?.working ?? false)
    }

    /// The presence level for one session, with the priority ladder applied.
    func presence(of session: SessionKey) -> PresenceLevel {
        .resolve(
            isWorking: isWorking(session),
            isReconnecting: !isRelayConnected,
            isLive: snapshot.isLive(session)
        )
    }

    /// The catalog row for a key, or `nil` when the relay has not announced
    /// that room. Never synthesise one: a row the Pi is not listening on drops
    /// its frames and reads as a ghost (spec 08 §13.10).
    func session(for key: SessionKey) -> SessionRow? {
        catalog.flatMap(\.sessions).first { $0.key == key }
    }

    /// The paired record for a machine, for a device label.
    func peer(_ peer: PeerID) -> PeerRecord? {
        peers.first { $0.peer == peer }
    }

    /// Machines that can be asked to start a session right now.
    ///
    /// Only the currently connected peer can ever qualify: the `create_session`
    /// control frame rides the active WebSocket, so an unreachable Mac
    /// genuinely cannot be asked. Home hides the `+` rather than disabling it
    /// when this is empty (spec 08 §7.2, §7.9).
    var machinesAcceptingSessions: [PeerRecord] {
        guard isRelayConnected else { return [] }
        return peers.filter { snapshot.controlPlaneIsUp($0.peer) }
    }

    func connect() async {
        guard let store, let keyStore else { return }
        await tearDownConnection()
        connection = .connecting
        lastError = nil
        do {
            let url = try Self.parseRelayURL(relayURLText)
            _ = try await attachPublisher(store: store, keyStore: keyStore, relayURL: url)
            try await startManagedSession(
                store: store,
                keyStore: keyStore,
                preferredRoom: peers.first?.lastOpenedRoom
            )
            await publishMembershipIfNeeded()
            await restoreOpenedSessionIfNeeded()
            await maybeDemoSend()
            await maybeDemoRename()
        } catch {
            connection = .offline(error.localizedDescription)
            lastError = error.localizedDescription
        }
    }

    func pair(pasted: String) async {
        guard let store, let keyStore else { return }
        let raw = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let payload = PairingQRPayload.parse(raw) else {
            lastError = "Not a remotepi://pair code."
            return
        }
        lastError = nil
        await tearDownConnection()
        connection = .connecting
        do {
            let url = try Self.parseRelayURL(relayURLText)
            let pairingTransport = RelayWebSocketTransport()
            let publisher = try await attachPublisher(store: store, keyStore: keyStore, relayURL: url)
            guard let directory else {
                throw RelayTransportError.handshakeFailed("peer directory missing")
            }
            let pairing = PairingCoordinator(
                transport: pairingTransport,
                keyStore: keyStore,
                directory: directory,
                publisher: publisher
            )
            let outcome = try await pairing.pairDetailed(
                with: payload,
                relayURL: url,
                deviceName: Self.deviceName
            )
            await pairingTransport.disconnect()
            peers = try await store.loadPeers()
            try await startManagedSession(
                store: store,
                keyStore: keyStore,
                preferredRoom: outcome.peer.lastOpenedRoom
            )
            await restoreOpenedSessionIfNeeded()
            await maybeDemoSend()
            await maybeDemoRename()
        } catch {
            connection = .offline(error.localizedDescription)
            lastError = error.localizedDescription
        }
    }

    func openChat(_ session: SessionRow) async {
        openedSession = session
        await openChat(session.key)
    }

    /// Open a chat by key alone.
    ///
    /// The chat screen is handed a ``SessionKey`` and nothing else, and a row
    /// may not exist for it — the relay has not announced that room yet, or
    /// this is a cold start restoring the last pointer. Synthesising a
    /// ``SessionRow`` to reach the other overload would mean inventing a
    /// ``RoomMeta``, which is the one thing spec 08 §13.10 forbids: a room the
    /// Pi is not listening on has no metadata, and made-up metadata reads as a
    /// live session.
    ///
    /// So `openedSession` is set only when a real row exists; the rest of the
    /// work (select, retarget, sync) is keyed and always safe.
    func openChat(_ key: SessionKey) async {
        if let row = session(for: key) { openedSession = row }
        try? await coordinator?.select(key)
        await transport?.retarget(peer: key.peer, room: key.room)
        do {
            try await sync(key)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func messages(for session: SessionKey) async -> AsyncStream<[MessageRow]> {
        if let store {
            return await store.messagesStream(for: session)
        }
        return AsyncStream { $0.finish() }
    }

    func rename(_ session: SessionKey, to displayName: String) async {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try await coordinator?.renameSession(session, to: trimmed)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Send a user message.
    ///
    /// `steer` maps to `streaming_behavior: "steer"` — sending while a turn is
    /// in flight, which is how the user redirects the agent. When it is
    /// `false` the key is **omitted**, never sent as `null`: older Pi
    /// extensions reject the explicit null (spec 08 §13.11), and `UserMessage`
    /// leaves a `nil` off the wire for us.
    ///
    /// An `image` rides inline on this frame as standard base64, and only on
    /// this frame — images never travel on a queued message.
    func send(
        _ text: String,
        to session: SessionKey,
        image: ComposerImage? = nil,
        steer: Bool = false
    ) async {
        guard let store, let coordinator else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // An image alone is a valid send: the caption is optional.
        guard !trimmed.isEmpty || image != nil else { return }
        let id = "cli_\(UUID().uuidString.lowercased())"
        let ts = SQLiteSessionStore.nowMilliseconds()
        do {
            _ = try await store.appendPendingUserMessage(
                id: id,
                text: trimmed,
                images: image.map { [$0.wire] } ?? [],
                ts: ts,
                steering: steer,
                for: session
            )
            await transport?.retarget(peer: session.peer, room: session.room)
            try await coordinator.send(
                WireJSON.encode(
                    ClientMessage.userMessage(
                        UserMessage(
                            id: id,
                            text: trimmed,
                            streamingBehavior: steer ? .steer : nil,
                            images: image.map { [$0.wire] }
                        )
                    )
                ),
                to: session
            )
            Task { [store] in
                try? await Task.sleep(for: .seconds(20))
                _ = try? await store.reapExpiredPending(for: session)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    // ── Named doors for the integration extensions ─────────────────────────
    //
    // `peers` and `openedSession` stay `private(set)` so the rule "screens
    // read, only `AppModel` writes" keeps holding at a glance. The extensions
    // in `AppModel+Screens.swift` are `AppModel`, but Swift scopes `private`
    // to the file, so they need a door. A named method is that door — and it
    // greps, which a plain `var` would not.

    /// Replace the paired-machine list. The only writer outside this file.
    func adoptPeers(_ next: [PeerRecord]) {
        peers = next
    }

    /// Re-read pairings from the store and publish them.
    @discardableResult
    func reloadPeersFromStore() async throws -> [PeerRecord] {
        guard let store else { return peers }
        peers = try await store.loadPeers()
        return peers
    }

    /// Move (or drop) the "chat the user has open" pointer.
    func adoptOpenedSession(_ row: SessionRow?) {
        openedSession = row
    }

    /// Stop the socket without re-dialling. Settings needs this after the
    /// last pairing is revoked, where `connect()` would immediately try to
    /// dial a machine that no longer exists.
    func disconnectForSettings() async {
        await tearDownConnection()
    }

    /// Re-derive the catalog after a purely local store edit.
    ///
    /// `rebuildCatalog()` reads the live registry snapshot, so a store-only
    /// change (a device-local label, a cache eviction) does not reach the UI
    /// on its own until the next relay update.
    func rebuildCatalogAfterLocalEdit() {
        rebuildCatalog()
    }

    // MARK: - Internals

    private func startObserving(_ coordinator: SessionCoordinator) {
        observeTask?.cancel()
        inboxTask?.cancel()
        observeTask = Task { [weak self] in
            let stream = await coordinator.registry.updates()
            for await next in stream {
                guard let self, !Task.isCancelled else { return }
                self.snapshot = next
                // A room the relay now reports live cannot still be "gone".
                self.byeReasons = self.byeReasons.filter { key, _ in
                    !next.isLive(key)
                }
                self.rebuildCatalog()
            }
        }
        inboxTask = Task { [weak self] in
            let stream = await coordinator.messages
            for await inbound in stream {
                guard let self, !Task.isCancelled else { return }
                await self.ingest(inbound)
            }
        }
    }

    private func ingest(_ inbound: InboundMessage) async {
        guard let store else { return }
        guard let message = try? WireJSON.decode(ServerMessage.self, from: inbound.payload) else {
            return
        }
        // Correlate BEFORE the store write. A reply that also mutates the
        // transcript (`session_history` answering a `session_sync`) must
        // resolve its waiter either way, and a store throw below must not
        // strand a caller that is already suspended.
        resolvePendingRequest(with: message)
        publishExtensionUI(message, for: inbound.session)
        trackStreaming(message, for: inbound.session)

        var sessionDrafts = drafts[inbound.session] ?? [:]
        do {
            try await ChatIngest.apply(
                message,
                session: inbound.session,
                store: store,
                drafts: &sessionDrafts
            )
            drafts[inbound.session] = sessionDrafts
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func sync(_ session: SessionKey) async throws {
        guard let coordinator else { return }
        await transport?.retarget(peer: session.peer, room: session.room)
        let request = ClientMessage.sessionSync(
            SessionSync(id: "sync_\(UUID().uuidString.lowercased())")
        )
        try await coordinator.send(WireJSON.encode(request), to: session)
    }

    private func maybeDemoRename() async {
        guard let name = Self.launchRenameTo() else { return }
        for _ in 0..<20 {
            if catalog.contains(where: { !$0.sessions.isEmpty }) { break }
            try? await Task.sleep(for: .milliseconds(150))
        }
        let open = await coordinator?.selectedSession()
        guard let target = catalog.flatMap(\.sessions).first(where: { $0.key != open })
            ?? catalog.flatMap(\.sessions).first
        else { return }
        await rename(target.key, to: name)
    }

    private func maybeDemoSend() async {
        guard let text = Self.launchSendText() else { return }
        for _ in 0..<20 {
            if catalog.contains(where: { !$0.sessions.isEmpty }) { break }
            try? await Task.sleep(for: .milliseconds(150))
        }
        let wanted = Self.launchOpenName()?.lowercased()
        let sessions = catalog.flatMap(\.sessions)
        let session = sessions.first(where: { row in
            guard let wanted else { return row.isLive }
            return row.displayName.lowercased().contains(wanted)
                || row.key.room.rawValue.lowercased().contains(wanted)
        }) ?? sessions.first(where: \.isLive) ?? sessions.first
        guard let session else { return }
        await openChat(session)
        await send(text, to: session.key)
    }

    private func rebuildCatalog() {
        catalog = SessionCatalog.build(peers: peers, snapshot: snapshot, filter: filter)
    }

    private func startManagedSession(
        store: SQLiteSessionStore,
        keyStore: any KeyStore,
        preferredRoom: RoomID?
    ) async throws {
        guard let peer = peers.first?.peer else {
            throw RelayTransportError.handshakeFailed("no paired machine")
        }
        let url = try Self.parseRelayURL(relayURLText)
        let seed = try await keyStore.loadOrCreateOwnerKeySeed()
        let signer = try Ed25519Signer(seed: seed)
        let manager = RelayConnectionManager()
        self.manager = manager
        let transport = ManagedRelayTransport(
            manager: manager,
            remotePeer: peer,
            preferredRoom: preferredRoom,
            onStatus: { status in
                Task { @MainActor in
                    self.applyManagerStatus(status)
                }
            }
        )
        self.transport = transport
        let coordinator = SessionCoordinator(transport: transport, store: store)
        self.coordinator = coordinator
        startObserving(coordinator)
        try await transport.connect(to: url, as: signer)
        try await coordinator.start(watching: peers.map(\.peer))
        await manager.subscribe(to: peers.map(\.peer))
    }

    private func applyManagerStatus(_ status: RelayConnectionManager.Status) {
        switch status {
        case .idle:
            connection = .idle
        case .connecting:
            connection = .connecting
        case .online:
            connection = .online
        case .retrying(let attempt, _):
            connection = .retrying(attempt)
        case .offline(let reason, _):
            connection = .offline(reason)
        }
    }

    private func restoreOpenedSessionIfNeeded() async {
        guard !didRestoreChat, Self.launchSendText() == nil else { return }
        if let stored = peers.first?.relayURL, !Self.sameRelayHost(stored, relayURLText) {
            didRestoreChat = true
            return
        }
        if Self.launchRenameTo() != nil {
            _ = await coordinator?.restoreSelection()
            didRestoreChat = true
            return
        }
        guard let key = await coordinator?.restoreSelection() else {
            didRestoreChat = true
            return
        }
        for _ in 0..<20 {
            if let row = catalog.flatMap(\.sessions).first(where: { $0.key == key }) {
                didRestoreChat = true
                openedSession = row
                return
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        didRestoreChat = true
    }

    @discardableResult
    private func attachPublisher(
        store: SQLiteSessionStore,
        keyStore: any KeyStore,
        relayURL: URL
    ) async throws -> MeshPublisher {
        let seed = try await keyStore.loadOrCreateOwnerKeySeed()
        let signer = try Ed25519Signer(seed: seed)
        guard let identity = OwnerIdentity(
            publicKey: signer.publicKey.rawValue,
            privateSeed: seed
        ) else {
            throw RelayTransportError.handshakeFailed("owner identity malformed")
        }
        let directory = self.directory ?? PeerDirectory(store: store)
        self.directory = directory
        let bridge = OwnerIdentityBridge(
            store: InMemoryOwnerIdentityStore(stored: identity),
            wipe: directory
        )
        _ = await bridge.boot()
        let publisher = MeshPublisher(
            client: MeshClient(baseURL: try Self.relayHTTPURL(from: relayURL)),
            directory: directory,
            bridge: bridge
        )
        self.publisher = publisher
        return publisher
    }

    private func publishMembershipIfNeeded() async {
        guard let publisher, let peer = peers.first?.peer else { return }
        switch await publisher.publish(intent: .add(peer)) {
        case .ok, .coalesced:
            break
        case .conflict(let current):
            lastError = "Mesh conflict (current=\(current.map(String.init) ?? "?"))"
        case .badRequest(let message), .forbidden(let message), .failure(let message):
            lastError = "Mesh: \(message)"
        case .tooLarge:
            lastError = "Mesh: payload too large"
        case .refusedEmpty:
            lastError = "Mesh: refused empty membership"
        }
    }

    private func tearDownConnection() async {
        observeTask?.cancel()
        observeTask = nil
        inboxTask?.cancel()
        inboxTask = nil
        drafts = [:]
        streamingDrafts = [:]
        byeReasons = [:]
        queuedStates = [:]
        // Nothing will ever answer these now. Failing them here is what turns
        // a socket drop into an immediate "Not connected" toast instead of
        // each caller sitting out its own 30 s timeout.
        failAllPendingRequests(ActionFailure.offline)
        didRestoreChat = false
        await coordinator?.stop()
        coordinator = nil
        await transport?.disconnect()
        transport = nil
        manager = nil
        connection = .idle
    }

    private static func resolveKeyStore(supportRoot: URL) async -> (store: any KeyStore, source: String) {
        let keychain = KeychainKeyStore()
        do {
            _ = try await keychain.loadOrCreateOwnerKeySeed()
            return (keychain, "keychain")
        } catch {
            return (FileKeyStore(url: supportRoot.appendingPathComponent("owner.seed")), "file")
        }
    }

    private static func isLoopbackRelay(_ raw: String) -> Bool {
        let host = URL(string: raw)?.host?.lowercased()
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    private static func sameRelayHost(_ lhs: String, _ rhs: String) -> Bool {
        func host(_ raw: String) -> String? {
            URL(string: raw)?.host?.lowercased()
        }
        guard let a = host(lhs), let b = host(rhs) else { return false }
        return a == b
    }

    private static func parseRelayURL(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil else {
            throw RelayTransportError.invalidRelayURL(trimmed)
        }
        return url
    }

    private static func relayHTTPURL(from url: URL) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw RelayTransportError.invalidRelayURL(url.absoluteString)
        }
        switch components.scheme?.lowercased() {
        case "http", "https":
            break
        case "ws":
            components.scheme = "http"
        case "wss":
            components.scheme = "https"
        default:
            throw RelayTransportError.invalidRelayURL(url.absoluteString)
        }
        guard let normalized = components.url else {
            throw RelayTransportError.invalidRelayURL(url.absoluteString)
        }
        return normalized
    }

    private static func launchRelayURL() -> String? {
        argumentValue("--relay")
    }

    private static func launchPairPayload() -> String? {
        argumentValue("--pair")
    }

    private static func launchSendText() -> String? {
        argumentValue("--send")
    }

    private static func launchRenameTo() -> String? {
        argumentValue("--rename-to")
    }

    private static func launchOpenName() -> String? {
        argumentValue("--open")
    }

    private static func argumentValue(_ flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else {
            return nil
        }
        return args[index + 1]
    }

    private static var deviceName: String {
        #if canImport(UIKit)
        UIDevice.current.name
        #else
        "Remote Pi"
        #endif
    }
}
