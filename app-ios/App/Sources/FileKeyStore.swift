import Foundation
import RemotePiCrypto
import RemotePiProtocol

/// Persistent Owner-key fallback for hosts where the Keychain item cannot be
/// created — the unsigned simulator build hits `errSecMissingEntitlement`
/// (`-34018`) because `kSecAttrSynchronizable` needs an iCloud entitlement
/// the project deliberately does not declare yet.
///
/// Same 32-byte seed layout as ``KeychainKeyStore``. Survives relaunch. Not
/// an iCloud-sync path: two simulators do not share this file, and a device
/// build must use the Keychain.
actor FileKeyStore: KeyStore {
    private let url: URL
    private var cached: Data?

    init(url: URL) {
        self.url = url
    }

    func loadOwnerKeySeed() async throws -> Data? {
        if let cached { return cached }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard data.count == 32 else { throw CryptoError.corruptStoredKey }
        cached = data
        return data
    }

    func loadOrCreateOwnerKeySeed() async throws -> Data {
        if let existing = try await loadOwnerKeySeed() { return existing }
        let seed = try Ed25519Signer().seed
        try await storeOwnerKeySeed(seed)
        return seed
    }

    func storeOwnerKeySeed(_ seed: Data) async throws {
        guard seed.count == 32 else { throw CryptoError.invalidKeyLength(seed.count) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try seed.write(to: url, options: .atomic)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try? mutable.setResourceValues(values)
        cached = seed
    }

    func deleteOwnerKeySeed() async throws {
        cached = nil
        try? FileManager.default.removeItem(at: url)
    }
}
