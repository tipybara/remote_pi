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

    private(set) var phase: Phase = .booting
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
    private static let defaultRelay = "https://relay.tengfei.site"

    private var store: SQLiteSessionStore?
    private var keyStore: (any KeyStore)?
    private var manager: RelayConnectionManager?
    private var transport: ManagedRelayTransport?
    private var coordinator: SessionCoordinator?
    private var didRestoreChat = false
    private var directory: PeerDirectory?
    private var publisher: MeshPublisher?
    private var observeTask: Task<Void, Never>?
    private var inboxTask: Task<Void, Never>?
    private var snapshot = RegistrySnapshot()
    private var drafts: [SessionKey: [String: String]] = [:]
    private(set) var openedSession: SessionRow?

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.relayDefaultsKey)
        if let stored, !Self.isLoopbackRelay(stored) {
            relayURLText = stored
        } else {
            relayURLText = Self.defaultRelay
            UserDefaults.standard.set(Self.defaultRelay, forKey: Self.relayDefaultsKey)
        }
    }

    func boot() async {
        do {
            let store = try SQLiteSessionStore(root: try SQLiteSessionStore.defaultRoot())
            self.store = store
            let resolved = await Self.resolveKeyStore(supportRoot: store.root)
            self.keyStore = resolved.store
            self.keyStoreSource = resolved.source
            let seed = try await resolved.store.loadOrCreateOwnerKeySeed()
            let signer = try Ed25519Signer(seed: seed)
            ownerShort = signer.publicKey.shortDescription
            peers = try await store.loadPeers()
            phase = .ready
            if let payload = Self.launchPairPayload() {
                await pair(pasted: payload)
            } else if !peers.isEmpty {
                await connect()
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
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
        try? await coordinator?.select(session.key)
        await transport?.retarget(peer: session.key.peer, room: session.key.room)
        do {
            try await sync(session.key)
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

    func send(_ text: String, to session: SessionKey) async {
        guard let store, let coordinator else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let id = "cli_\(UUID().uuidString.lowercased())"
        let ts = SQLiteSessionStore.nowMilliseconds()
        do {
            _ = try await store.appendPendingUserMessage(id: id, text: trimmed, ts: ts, for: session)
            await transport?.retarget(peer: session.peer, room: session.room)
            try await coordinator.send(
                WireJSON.encode(ClientMessage.userMessage(UserMessage(id: id, text: trimmed))),
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

    // MARK: - Internals

    private func startObserving(_ coordinator: SessionCoordinator) {
        observeTask?.cancel()
        inboxTask?.cancel()
        observeTask = Task { [weak self] in
            let stream = await coordinator.registry.updates()
            for await next in stream {
                guard let self, !Task.isCancelled else { return }
                self.snapshot = next
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
