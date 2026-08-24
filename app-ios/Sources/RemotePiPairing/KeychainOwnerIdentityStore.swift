import Foundation
import Security

#if canImport(UIKit)
import UIKit
#endif

/// The Owner-key slot in the iOS Keychain, synchronized through iCloud
/// Keychain.
///
/// This is a port of `app/packages/remote_pi_identity/ios/Classes/KeychainSyncStore.swift`
/// with the Flutter channel plumbing removed. **The constants and the query
/// shape are not ours to change**: a device running the Flutter app and a
/// device running this client must land on the same item, or the same human
/// ends up with two Owner keys.
///
/// | Attribute | Value | Set on |
/// |---|---|---|
/// | `kSecClass` | `kSecClassGenericPassword` | every query |
/// | `kSecAttrService` | `dev.remotepi.owner.identity` | every query |
/// | `kSecAttrAccount` | `singleton` | every query |
/// | `kSecAttrSynchronizable` | `true` | every query |
/// | `kSecAttrAccessible` | `kSecAttrAccessibleAfterFirstUnlock` | **add only** |
///
/// Three traps live in that table:
///
/// - **`kSecAttrSynchronizable` is all-or-nothing at query time.** A query
///   that omits it will not match a synchronizable item even when service and
///   account are right. The symptom is `load()` returning `nil` on a device
///   that visibly has the key → a second Owner key is generated → the mesh
///   blob is signed by a key nobody recognizes → every paired Pi self-revokes.
///   Every query goes through ``baseQuery(service:account:)`` for that reason.
/// - **The account is the literal string `singleton`.** Keying the item by the
///   Owner public key would look tidier and would destroy the design: the
///   "a different Owner arrived" detection works precisely because there is
///   one slot whose contents can change under you.
/// - **`kSecAttrAccessible` is attached on add and never on update.** An item
///   that landed with a different accessibility class keeps it forever, so a
///   change of constant needs an explicit migration. And never a
///   `…ThisDeviceOnly` variant: those cannot sync, which defeats the feature.
///   `AfterFirstUnlock` (not `WhenUnlocked`) is what lets a background
///   reconnect read the key on a locked-but-once-unlocked device.
public actor KeychainOwnerIdentityStore: OwnerIdentityStoring {
    /// Changing this strands every already-synced identity.
    public static let defaultService = "dev.remotepi.owner.identity"
    /// Not a key. See the type doc.
    public static let defaultAccount = "singleton"

    private let service: String
    private let account: String
    private let pollInterval: Duration?

    /// - Parameter pollInterval: how often ``changes()`` re-reads the item
    ///   while the app is in the foreground. The Flutter plugin only re-read on
    ///   `willEnterForeground` (`RemotePiIdentityPlugin.swift:131-136`), which
    ///   means a session that never backgrounds never notices a key arriving
    ///   from another device — spec 62/05 Q3 leaves the interval as an open
    ///   product question, so this is a conservative default rather than
    ///   parity.
    public init(
        service: String = KeychainOwnerIdentityStore.defaultService,
        account: String = KeychainOwnerIdentityStore.defaultAccount,
        pollInterval: Duration? = .seconds(60)
    ) {
        self.service = service
        self.account = account
        self.pollInterval = pollInterval
    }

    /// The attribute set every operation starts from. Exposed so a test can
    /// assert its shape without touching a real Keychain — the shape is the
    /// contract with the Flutter build, and it is invisible at runtime until
    /// it has already cost someone their pairings.
    public nonisolated static func baseQuery(
        service: String = KeychainOwnerIdentityStore.defaultService,
        account: String = KeychainOwnerIdentityStore.defaultAccount
    ) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
        ]
    }

    private nonisolated var base: [String: Any] {
        Self.baseQuery(service: service, account: account)
    }

    // MARK: - OwnerIdentityStoring

    public func load() async throws -> OwnerIdentity? {
        // Pre-flight, exactly as the plugin does (`:56-59`). This is what
        // *produces* the `sync_unavailable` error the boot gate keys on; the
        // app layer must never call `isSyncAvailable()` itself as a gate.
        guard isSyncAvailable() else {
            throw OwnerIdentityError.syncUnavailable(
                reason: "iCloud Keychain is not enabled on this device"
            )
        }
        guard let blob = try loadBlob() else { return nil }
        guard let identity = OwnerIdentity(blob: blob) else {
            // Not silently regenerated: a wrong-length item that propagated
            // through iCloud would otherwise make every device mint a new
            // Owner key and revoke every machine.
            throw OwnerIdentityError.malformedBlob(byteCount: blob.count)
        }
        return identity
    }

    public func save(_ identity: OwnerIdentity) async throws {
        guard isSyncAvailable() else {
            throw OwnerIdentityError.syncUnavailable(
                reason: "iCloud Keychain is not enabled on this device"
            )
        }
        let blob = identity.blob
        // Update-or-add, never add-first: `SecItemAdd` would return
        // `errSecDuplicateItem` on every re-save (`KeychainSyncStore.swift:46-47`).
        let updateStatus = SecItemUpdate(
            base as CFDictionary,
            [kSecValueData as String: blob] as CFDictionary
        )
        switch updateStatus {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            var insert = base
            insert[kSecValueData as String] = blob
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw OwnerIdentityError.keychain(status: addStatus, operation: "SecItemAdd failed")
            }
        default:
            throw OwnerIdentityError.keychain(
                status: updateStatus,
                operation: "SecItemUpdate failed"
            )
        }
        emitIfChanged(identity)
    }

    public func delete() async throws {
        let status = SecItemDelete(base as CFDictionary)
        // "Not found" folds into success — idempotent, same as the port source.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw OwnerIdentityError.keychain(status: status, operation: "SecItemDelete failed")
        }
        // No emit: there is no "identity removed" event on the stream, by
        // design (`RemotePiIdentityPlugin.swift:106`). Callers that need to
        // know must ask.
        lastEmitted = nil
    }

    /// Whether the synchronizable Keychain surface answers at all.
    ///
    /// Deliberately **not** `FileManager.ubiquityIdentityToken` — that is the
    /// iCloud *Drive/ubiquity* signal and is always `nil` without an iCloud
    /// entitlement, which this app does not ship. Using it locked every App
    /// Store user out at "Sync required" even with iCloud and iCloud Keychain
    /// fully on (issue #39).
    ///
    /// `kSecAttrSynchronizable` items need no iCloud entitlement, and Apple
    /// exposes no public "is iCloud Keychain on?" query — the load/save error
    /// path is the real check. So this returns `true` on a device with iCloud
    /// Keychain switched **off**; all it proves is that the Keychain answered.
    /// Do not read more into it, and do not "improve" it into an iCloud-account
    /// check.
    public nonisolated func isSyncAvailable() -> Bool {
        var query = base
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Change observation

    private var lastEmitted: Data?
    private var continuations: [UUID: AsyncStream<OwnerIdentity>.Continuation] = [:]

    public nonisolated func changes() -> AsyncStream<OwnerIdentity> {
        AsyncStream { continuation in
            let id = UUID()
            let task = Task { [self] in
                await register(id, continuation)
                await watchLoop()
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task { await self.unregister(id) }
            }
        }
    }

    private func register(_ id: UUID, _ continuation: AsyncStream<OwnerIdentity>.Continuation) {
        continuations[id] = continuation
        // Initial emit on subscribe: a subscriber gets the current blob with
        // no separate load (`RemotePiIdentityPlugin.swift:122-126`).
        if let identity = try? load_noThrowingGate() { emitIfChanged(identity) }
    }

    private func unregister(_ id: UUID) {
        continuations[id] = nil
    }

    /// Load for the *observation* path: a Keychain hiccup here must not tear
    /// the stream down, so the sync pre-flight is skipped and failures become
    /// `nil`. The gate lives on ``load()``, which the boot path calls.
    private func load_noThrowingGate() throws -> OwnerIdentity? {
        guard let blob = try loadBlob(), let identity = OwnerIdentity(blob: blob) else {
            return nil
        }
        return identity
    }

    private func watchLoop() async {
        await withTaskGroup(of: Void.self) { group in
            #if canImport(UIKit) && !os(watchOS)
            group.addTask { [self] in
                // The Keychain has no change observer. The *working* trigger is
                // this one — a re-read every time the app comes forward
                // (`RemotePiIdentityPlugin.swift:131-136`).
                //
                // Bridged through an `AsyncStream` rather than
                // `NotificationCenter.notifications(named:)` because
                // `Notification` is not `Sendable`: iterating it from this task
                // would drag a non-Sendable value across an isolation boundary
                // for a value we never even read.
                let name = await MainActor.run { UIApplication.willEnterForegroundNotification }
                let (ticks, tickContinuation) = AsyncStream<Void>.makeStream()
                let token = NotificationCenter.default.addObserver(
                    forName: name,
                    object: nil,
                    queue: nil
                ) { _ in tickContinuation.yield(()) }
                defer { NotificationCenter.default.removeObserver(token) }
                for await _ in ticks {
                    await self.reread()
                }
            }
            #endif
            if let pollInterval {
                group.addTask { [self] in
                    // The foreground trigger alone never fires for a session
                    // that stays open, so a key arriving from the user's other
                    // device would be invisible until the next backgrounding.
                    while !Task.isCancelled {
                        try? await Task.sleep(for: pollInterval)
                        if Task.isCancelled { return }
                        await self.reread()
                    }
                }
            }
            await group.waitForAll()
        }
    }

    private func reread() {
        guard let identity = try? load_noThrowingGate() else { return }
        emitIfChanged(identity)
    }

    /// Full-blob equality de-dup (`RemotePiIdentityPlugin.swift:168-172`).
    /// A re-save of identical bytes must not look like an Owner change — the
    /// bridge's wipe path is downstream of this.
    private func emitIfChanged(_ identity: OwnerIdentity) {
        let blob = identity.blob
        guard blob != lastEmitted else { return }
        lastEmitted = blob
        for continuation in continuations.values { continuation.yield(identity) }
    }

    // MARK: - Raw Keychain

    private func loadBlob() throws -> Data? {
        var query = base
        query[kSecReturnData as String] = kCFBooleanTrue as Any
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var raw: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &raw)
        switch status {
        case errSecSuccess:
            return raw as? Data
        case errSecItemNotFound:
            // First run. NOT an error — but see `load()`: this must stay
            // distinguishable from a read that failed.
            return nil
        default:
            throw OwnerIdentityError.keychain(
                status: status,
                operation: "SecItemCopyMatching failed"
            )
        }
    }
}
