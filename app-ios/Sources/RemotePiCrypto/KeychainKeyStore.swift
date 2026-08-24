import CryptoKit
import Foundation
import RemotePiProtocol
import Security

/// Owner-key storage in the iOS Keychain.
///
/// One item, one key: the 32-byte Ed25519 **seed** of the Owner identity.
/// Everything the user has ever paired hangs off it, so the rules below are
/// not style choices.
///
/// - `kSecClassGenericPassword` with `kSecAttrSynchronizable = true`, so the
///   Owner-key rides iCloud Keychain to the user's next phone. That
///   synchronization is a product requirement, not an optimization: it is the
///   reason a lost phone is recoverable while a lost Mac is not.
/// - `kSecAttrAccessibleAfterFirstUnlock` — **not**
///   `…ThisDeviceOnly`, which contradicts `synchronizable` and would be
///   rejected. "After first unlock" is also what lets a backgrounded app
///   reconnect to the relay after a reboot the user has unlocked once.
/// - A locked or unavailable Keychain **throws**. Reading a failure as "no
///   key" would mint a second Owner identity, orphan every existing pairing,
///   and leave every paired Mac self-revoking because the new Owner's
///   membership blob does not list them. That is why the only status mapped
///   to `nil` is `errSecItemNotFound` and everything else becomes
///   ``CryptoError/keychain(status:)``.
public actor KeychainKeyStore: KeyStore {
    /// Keychain service string. Changing it strands every existing key.
    public let service: String
    public let account: String

    public init(service: String = "work.jacobmoura.remotepi.owner", account: String = "owner-key") {
        self.service = service
        self.account = account
    }

    public func loadOwnerKeySeed() async throws -> Data? {
        try readSeed()
    }

    /// Returns the stored seed, generating and persisting one if absent.
    ///
    /// Atomicity has two layers. In-process, actor isolation serializes
    /// callers, so two first-launch racers cannot both reach the "generate"
    /// branch. Out-of-process (an extension, a second launch mid-migration),
    /// `SecItemAdd` answers `errSecDuplicateItem` and we adopt the key that
    /// won instead of overwriting it — the one outcome that must never happen
    /// here is two devices' worth of pairings split across two identities.
    public func loadOrCreateOwnerKeySeed() async throws -> Data {
        if let existing = try readSeed() { return existing }

        let seed = Curve25519.Signing.PrivateKey().rawRepresentation
        do {
            try addSeed(seed)
            return seed
        } catch CryptoError.keychain(let status) where status == errSecDuplicateItem {
            guard let winner = try readSeed() else {
                // Duplicate on add but nothing to read: the item exists in a
                // shape our query cannot see. Surfacing the status beats
                // silently minting a second identity.
                throw CryptoError.keychain(status: errSecDuplicateItem)
            }
            return winner
        }
    }

    public func storeOwnerKeySeed(_ seed: Data) async throws {
        guard seed.count == 32 else { throw CryptoError.invalidKeyLength(seed.count) }
        // Delete-then-add rather than SecItemUpdate: `kSecAttrSynchronizable`
        // is part of an item's primary key, so updating an item that was
        // stored non-synchronizable (an older build, a migration) would leave
        // the old copy in place and the two would diverge across devices.
        try deleteSeed()
        try addSeed(seed)
    }

    public func deleteOwnerKeySeed() async throws {
        try deleteSeed()
    }

    // MARK: - Keychain primitives

    /// Attributes that identify the item. `kSecAttrSynchronizable` is
    /// deliberately absent here — each caller states its own value, because
    /// searches must use `kSecAttrSynchronizableAny` (to find both the synced
    /// item and any legacy local one) while writes must be explicit.
    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func readSeed() throws -> Data? {
        var query = baseQuery
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw CryptoError.corruptStoredKey }
            // A wrong-length blob is corruption, not absence: returning nil
            // would generate a fresh identity on top of a real one.
            guard data.count == 32 else { throw CryptoError.corruptStoredKey }
            return data
        case errSecItemNotFound:
            return nil
        default:
            // Includes errSecInteractionNotAllowed (device locked) and
            // errSecMissingEntitlement — both must throw. See the type doc.
            throw CryptoError.keychain(status: status)
        }
    }

    private func addSeed(_ seed: Data) throws {
        var attributes = baseQuery
        attributes[kSecAttrSynchronizable as String] = kCFBooleanTrue
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        attributes[kSecValueData as String] = seed

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CryptoError.keychain(status: status)
        }
    }

    private func deleteSeed() throws {
        var query = baseQuery
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        let status = SecItemDelete(query as CFDictionary)
        // Deleting something that is not there is the desired end state, not
        // an error — `deleteOwnerKeySeed()` is documented as idempotent.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CryptoError.keychain(status: status)
        }
    }
}

/// A `KeyStore` that lives only in memory.
///
/// For tests, SwiftUI previews, and the simulator runs where a real Keychain
/// item would leak between test cases. **Never** reachable from a shipping
/// code path: an Owner key that does not survive a relaunch means the user
/// re-pairs every launch and every paired Mac self-revokes behind them.
public actor InMemoryKeyStore: KeyStore {
    private var seed: Data?

    public init(seed: Data? = nil) {
        self.seed = seed
    }

    public func loadOwnerKeySeed() async throws -> Data? { seed }

    public func loadOrCreateOwnerKeySeed() async throws -> Data {
        if let seed { return seed }
        let fresh = Curve25519.Signing.PrivateKey().rawRepresentation
        seed = fresh
        return fresh
    }

    public func storeOwnerKeySeed(_ seed: Data) async throws {
        guard seed.count == 32 else { throw CryptoError.invalidKeyLength(seed.count) }
        self.seed = seed
    }

    public func deleteOwnerKeySeed() async throws {
        seed = nil
    }
}
