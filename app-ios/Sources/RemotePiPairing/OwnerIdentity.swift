import Foundation
import RemotePiCrypto
import RemotePiProtocol

// MARK: - The value

/// The Owner key: one Ed25519 keypair **per human**, not per device.
///
/// Two devices signed into the same Apple ID hold the *same* 32 bytes and look
/// like the same peer to the relay and to every paired Pi
/// (`plan/23-owner-key-sync.md`). It never rotates: if a different key ever
/// arrives from iCloud, the new one is authoritative and this device treats
/// itself as started from zero — no prompt, no merge (see
/// ``OwnerIdentityBridge``).
///
/// ## The persisted form is 64 raw bytes and nothing else
///
/// ```text
/// byte 0 ─────────── 31 │ 32 ─────────── 63
///      publicKey (32B)  │  privateSeed (32B)
/// ```
///
/// No version byte, no JSON, no Base64 (`owner_identity.dart:42-61`,
/// `CHANGELOG.md` 0.2.0 BREAKING). A device running the Flutter app and a
/// device running this client share **one** iCloud Keychain item; writing a
/// different layout there is a silent cross-device identity corruption, not a
/// version negotiation. That is why this type is deliberately **not**
/// `Codable`: any encoder reachable from here would be a way to get that
/// wrong.
///
/// `privateSeed` is the 32-byte Ed25519 **seed**, which is exactly
/// `Curve25519.Signing.PrivateKey.rawRepresentation` and exactly what Dart's
/// `extractPrivateKeyBytes()` returns — not a 64-byte expanded secret key.
public struct OwnerIdentity: Equatable, Sendable {
    public let publicKey: Data
    public let privateSeed: Data

    /// Fails unless both halves are exactly 32 bytes — a wrong length here is
    /// a different identity, not a recoverable formatting problem.
    public init?(publicKey: Data, privateSeed: Data) {
        guard publicKey.count == 32, privateSeed.count == 32 else { return nil }
        self.publicKey = publicKey
        self.privateSeed = privateSeed
    }

    /// Reads the 64-byte Keychain blob. `nil` for any other length.
    public init?(blob: Data) {
        guard blob.count == 64 else { return nil }
        self.init(
            publicKey: blob.prefix(32),
            privateSeed: blob.suffix(32)
        )
    }

    /// `publicKey || privateSeed`.
    public var blob: Data {
        var out = Data(capacity: 64)
        out.append(publicKey)
        out.append(privateSeed)
        return out
    }

    /// The relay-facing form of the public half.
    public var peerID: PeerID? { PeerID(rawValue: publicKey) }

    /// Rehydrates the signer. The seed is the whole key; deriving the public
    /// half again and checking it against ``publicKey`` catches a blob whose
    /// two halves do not belong together (a hand-edited item, a partial
    /// iCloud write) before it signs anything.
    public func signer() throws -> Ed25519Signer {
        let signer = try Ed25519Signer(seed: privateSeed)
        guard signer.publicKey.rawValue == publicKey else {
            throw OwnerIdentityError.malformedBlob(byteCount: 64)
        }
        return signer
    }

    /// Generates a fresh Owner key. Called exactly once per human, on the
    /// first launch that finds an empty Keychain slot.
    public static func generate() throws -> OwnerIdentity {
        let signer = try Ed25519Signer()
        guard
            let identity = OwnerIdentity(
                publicKey: signer.publicKey.rawValue,
                privateSeed: signer.seed
            )
        else { throw OwnerIdentityError.malformedBlob(byteCount: 0) }
        return identity
    }
}

// MARK: - Errors

/// Mirrors the three discriminants the Flutter plugin put on its error channel
/// (`RemotePiIdentityPlugin.swift:176-195`), because the boot gate keys off
/// exactly the first one.
public enum OwnerIdentityError: Error, Hashable, Sendable {
    /// `code: "sync_unavailable"` — the Keychain refused in a way that means
    /// "this device cannot participate right now".
    ///
    /// This is the **only** trigger for the sync-required gate. Note what it
    /// is not: it is not "iCloud Keychain is switched off", because Apple
    /// exposes no API for that (see
    /// ``KeychainOwnerIdentityStore/isSyncAvailable()``).
    case syncUnavailable(reason: String)
    /// `code: "keychain_error"` with the `OSStatus` in the details.
    case keychain(status: Int32, operation: String)
    /// A stored item that is not 64 bytes. **Not** retryable, and not
    /// something to silently overwrite: overwriting rotates the Owner key and
    /// self-revokes every paired machine (spec 62/05 trap §10.7).
    case malformedBlob(byteCount: Int)
}

// MARK: - Storage seam

/// The Owner-key slot. One item, whose contents may change under you — that
/// single-slot design is what makes "a different Owner arrived" detectable at
/// all (spec 62/05 trap §10.5).
public protocol OwnerIdentityStoring: Sendable {
    /// `nil` means first run. A Keychain that *failed* must throw instead:
    /// reading a failure as absence mints a second Owner key and orphans every
    /// existing pairing.
    func load() async throws -> OwnerIdentity?
    func save(_ identity: OwnerIdentity) async throws
    /// Idempotent, and fleet-wide: the tombstone propagates through iCloud
    /// Keychain. Never wire this to a "sign out" button.
    func delete() async throws
    /// A weak probe — see the implementation's doc. Never gate on it.
    func isSyncAvailable() async -> Bool
    /// Emits the current identity on subscribe, then on every observed change.
    /// Byte-deduplicated, and silent on delete.
    func changes() -> AsyncStream<OwnerIdentity>
}

/// In-memory store for tests and previews.
public actor InMemoryOwnerIdentityStore: OwnerIdentityStoring {
    private var stored: OwnerIdentity?
    private var syncAvailable: Bool
    private var loadError: OwnerIdentityError?
    private var saveError: OwnerIdentityError?
    private var continuations: [UUID: AsyncStream<OwnerIdentity>.Continuation] = [:]
    private var lastEmitted: Data?

    public init(
        stored: OwnerIdentity? = nil,
        syncAvailable: Bool = true,
        loadError: OwnerIdentityError? = nil,
        saveError: OwnerIdentityError? = nil
    ) {
        self.stored = stored
        self.syncAvailable = syncAvailable
        self.loadError = loadError
        self.saveError = saveError
    }

    public func load() async throws -> OwnerIdentity? {
        if let loadError { throw loadError }
        return stored
    }

    public func save(_ identity: OwnerIdentity) async throws {
        if let saveError { throw saveError }
        stored = identity
        emit(identity)
    }

    public func delete() async throws {
        stored = nil
        // Deliberately emits nothing — matches `handleDelete`
        // (`RemotePiIdentityPlugin.swift:106`), which clears the de-dup
        // watermark and stays silent.
        lastEmitted = nil
    }

    public func isSyncAvailable() async -> Bool { syncAvailable }

    // `nonisolated`: the protocol requirement is synchronous, and an
    // actor-isolated witness would not satisfy it.
    public nonisolated func changes() -> AsyncStream<OwnerIdentity> {
        let id = UUID()
        return AsyncStream { continuation in
            Task { await self.register(id, continuation) }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.unregister(id) }
            }
        }
    }

    /// Test hook: simulate a blob arriving from another device.
    public func inject(_ identity: OwnerIdentity) {
        stored = identity
        emit(identity)
    }

    public func setLoadError(_ error: OwnerIdentityError?) { loadError = error }

    private func register(_ id: UUID, _ continuation: AsyncStream<OwnerIdentity>.Continuation) {
        continuations[id] = continuation
        // Initial emit on subscribe, matching `onListen`
        // (`RemotePiIdentityPlugin.swift:122-126`).
        if let stored { continuation.yield(stored) }
    }

    private func unregister(_ id: UUID) { continuations[id] = nil }

    private func emit(_ identity: OwnerIdentity) {
        guard lastEmitted != identity.blob else { return }
        lastEmitted = identity.blob
        for continuation in continuations.values { continuation.yield(identity) }
    }
}
