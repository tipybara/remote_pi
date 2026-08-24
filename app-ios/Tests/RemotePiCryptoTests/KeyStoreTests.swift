import Foundation
import XCTest

@testable import RemotePiCrypto
@testable import RemotePiProtocol

/// Owner-key storage.
///
/// The Keychain half runs against a per-run service string so it can never
/// touch a real user's key, and skips rather than fails when the host has no
/// usable Keychain — a plain `swift test` on macOS is an unsigned CLI process
/// and the data-protection Keychain refuses it. The skip is deliberate: a red
/// suite that means "no entitlement here" trains people to ignore red.
final class KeyStoreTests: XCTestCase {

    // MARK: - InMemoryKeyStore

    func testInMemoryStoreStartsEmptyAndMintsOnce() async throws {
        let store = InMemoryKeyStore()
        let absent = try await store.loadOwnerKeySeed()
        XCTAssertNil(absent)

        let first = try await store.loadOrCreateOwnerKeySeed()
        XCTAssertEqual(first.count, 32)
        let second = try await store.loadOrCreateOwnerKeySeed()
        XCTAssertEqual(first, second, "a second call must not mint a second identity")

        // The seed is usable as an Owner key, which is the only reason to
        // store it.
        let signer = try Ed25519Signer(seed: first)
        XCTAssertEqual(signer.publicKey.wireValue.count, 44)
    }

    func testInMemoryStoreOverwritesAndDeletes() async throws {
        let store = InMemoryKeyStore()
        let seed = WireVectors.data(hex: WireVectors.nobleSeedHex)
        try await store.storeOwnerKeySeed(seed)

        let loaded = try await store.loadOwnerKeySeed()
        XCTAssertEqual(loaded, seed)
        XCTAssertEqual(
            try Ed25519Signer(seed: try XCTUnwrap(loaded)).publicKey.wireValue,
            WireVectors.noblePubkeyStandard
        )

        try await store.deleteOwnerKeySeed()
        let deleted = try await store.loadOwnerKeySeed()
        XCTAssertNil(deleted)
    }

    func testInMemoryStoreRefusesAWrongLengthSeed() async {
        let store = InMemoryKeyStore()
        do {
            try await store.storeOwnerKeySeed(Data(repeating: 1, count: 16))
            XCTFail("a 16-byte seed is not an Ed25519 key")
        } catch {
            XCTAssertEqual(error as? CryptoError, .invalidKeyLength(16))
        }
    }

    // MARK: - KeychainKeyStore

    /// Round-trips a real Keychain item under a throwaway service name.
    func testKeychainRoundTrip() async throws {
        let store = KeychainKeyStore(service: Self.throwawayService(), account: "owner-key")
        try await skipIfKeychainUnavailable(store)
        defer { Task { try? await store.deleteOwnerKeySeed() } }

        let seed = WireVectors.data(hex: WireVectors.nobleSeedHex)
        try await store.storeOwnerKeySeed(seed)
        let loaded = try await store.loadOwnerKeySeed()
        XCTAssertEqual(loaded, seed)

        // Overwriting replaces rather than accumulating: a second item at the
        // same (service, account) with a different `synchronizable` flag would
        // make "which key am I?" depend on query order.
        let replacement = try Ed25519Signer().seed
        try await store.storeOwnerKeySeed(replacement)
        let reloaded = try await store.loadOwnerKeySeed()
        XCTAssertEqual(reloaded, replacement)

        try await store.deleteOwnerKeySeed()
        let afterDelete = try await store.loadOwnerKeySeed()
        XCTAssertNil(afterDelete)
        // Idempotent: deleting an absent item is the desired end state.
        try await store.deleteOwnerKeySeed()
    }

    /// The first-launch path must mint exactly one key no matter how many
    /// callers race — two identities means every existing pairing is orphaned
    /// and every paired Mac self-revokes.
    func testKeychainLoadOrCreateIsAtomicUnderConcurrency() async throws {
        let store = KeychainKeyStore(service: Self.throwawayService(), account: "owner-key")
        try await skipIfKeychainUnavailable(store)
        defer { Task { try? await store.deleteOwnerKeySeed() } }
        try await store.deleteOwnerKeySeed()

        let seeds = await withTaskGroup(of: Data?.self, returning: [Data].self) { group in
            for _ in 0..<8 {
                group.addTask { try? await store.loadOrCreateOwnerKeySeed() }
            }
            var collected: [Data] = []
            for await seed in group { if let seed { collected.append(seed) } }
            return collected
        }

        XCTAssertEqual(seeds.count, 8)
        XCTAssertEqual(Set(seeds).count, 1, "concurrent first launches minted \(Set(seeds).count) identities")
        let persisted = try await store.loadOwnerKeySeed()
        XCTAssertEqual(persisted, seeds.first)
    }

    /// A missing key is `nil`; anything else must throw. This is the rule that
    /// keeps a locked Keychain from being read as "first launch".
    func testKeychainReportsAbsenceAsNil() async throws {
        let store = KeychainKeyStore(service: Self.throwawayService(), account: "never-written")
        do {
            let seed = try await store.loadOwnerKeySeed()
            XCTAssertNil(seed)
        } catch CryptoError.keychain(let status) {
            throw XCTSkip("no usable Keychain in this test host (OSStatus \(status))")
        }
    }

    // MARK: - helpers

    private static func throwawayService() -> String {
        "work.jacobmoura.remotepi.tests.\(UUID().uuidString)"
    }

    /// Probes with a write, because a read of an absent item succeeds even
    /// where writes are refused.
    private func skipIfKeychainUnavailable(_ store: KeychainKeyStore) async throws {
        do {
            try await store.storeOwnerKeySeed(Data(repeating: 0x11, count: 32))
            try await store.deleteOwnerKeySeed()
        } catch CryptoError.keychain(let status) {
            throw XCTSkip("no usable Keychain in this test host (OSStatus \(status))")
        }
    }
}
