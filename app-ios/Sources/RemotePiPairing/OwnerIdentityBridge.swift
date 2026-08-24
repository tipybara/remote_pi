import Foundation
import RemotePiCrypto
import RemotePiProtocol

/// Whatever holds this device's pairings, from the identity layer's point of
/// view. Implemented by ``PeerDirectory``.
public protocol PairingWipe: Sendable {
    /// Drops every paired machine and its cached rooms. Called when a
    /// **different** Owner key arrives — never on a plain reload.
    func wipeAllPairings() async
}

/// What ``OwnerIdentityBridge/boot()`` decided.
public enum OwnerBootResult: Sendable, Equatable {
    /// The identity is usable. `generated == true` only on a genuinely fresh
    /// key — a key restored from iCloud Keychain (including "reinstalled the
    /// app on the same device") reports `false`, which is what keeps the
    /// onboarding wizard from re-running for an existing user.
    case ready(OwnerIdentity, generated: Bool)

    /// The Keychain reported `sync_unavailable`. The **only** trigger for the
    /// sync-required gate, which is sticky and retry-driven: the retry button
    /// calls ``OwnerIdentityBridge/reboot()`` and leaves only when the result
    /// is something else. There is deliberately no local-only fallback
    /// identity — `plan/23`: "Sem fallback 'gera local' pra evitar divergência
    /// silenciosa com sync futuro."
    case syncUnavailable

    /// The stored item was not a 64-byte blob.
    ///
    /// A divergence from the Flutter client, on purpose: there, a malformed
    /// blob throws out of `boot()` uncaught and pins every device of that Apple
    /// ID on the splash screen forever (spec 62/05 trap §10.7). Surfacing it as
    /// a state lets the UI offer an explicit reset. Do **not** auto-overwrite:
    /// that rotates the Owner key and self-revokes every paired machine.
    case corrupted(byteCount: Int)

    /// Any other failure. Distinct from ``syncUnavailable`` so the UI can
    /// offer a plain retry without claiming iCloud is off.
    case failed(reason: String)
}

/// Owns the Owner key for the process: the boot gate, the cached identity, and
/// the single path through which an Owner *change* is allowed to happen.
public actor OwnerIdentityBridge {
    private let store: any OwnerIdentityStoring
    private let wipe: (any PairingWipe)?
    private var watchTask: Task<Void, Never>?

    /// The identity `boot()` settled on. `nil` until then — and nothing that
    /// needs the Owner key may run before that, because the transport and the
    /// pairing flow both sign with it.
    public private(set) var current: OwnerIdentity?

    public init(store: any OwnerIdentityStoring, wipe: (any PairingWipe)? = nil) {
        self.store = store
        self.wipe = wipe
    }

    public var currentOwnerPeerID: PeerID? { current?.peerID }

    /// Loads or creates the Owner key.
    ///
    /// **Genuinely idempotent**, unlike the Dart original whose doc comment
    /// claims idempotence while the body re-reads the Keychain every time
    /// (spec 62/05 trap §10.8). That mattered: `/sync-required`'s "Check again"
    /// calls it again, and a second read that found *different* bytes replaced
    /// the in-memory identity **without** wiping peers, because the wipe lives
    /// only on the watch path. Here every identity *change* goes through
    /// ``startWatching(onOwnerReplaced:)`` and nowhere else.
    public func boot() async -> OwnerBootResult {
        if let current { return .ready(current, generated: false) }
        do {
            if let loaded = try await store.load() {
                current = loaded
                return .ready(loaded, generated: false)
            }
        } catch let error as OwnerIdentityError {
            switch error {
            case .syncUnavailable:
                return .syncUnavailable
            case .malformedBlob(let count):
                return .corrupted(byteCount: count)
            case .keychain:
                // Matches the Dart bridge: a non-sync store failure falls
                // through to generation rather than blocking the user. The
                // Keychain either accepts the new item or throws again below.
                break
            }
        } catch {
            return .failed(reason: String(describing: error))
        }

        do {
            let generated = try OwnerIdentity.generate()
            try await store.save(generated)
            current = generated
            return .ready(generated, generated: true)
        } catch OwnerIdentityError.syncUnavailable {
            return .syncUnavailable
        } catch {
            return .failed(reason: String(describing: error))
        }
    }

    /// Drops the cache and boots again — the "Check again" button on the
    /// sync-required gate, and the second half of an Owner replacement.
    public func reboot() async -> OwnerBootResult {
        current = nil
        return await boot()
    }

    /// Precondition: ``boot()`` returned ``OwnerBootResult/ready(_:generated:)``.
    public func requireIdentity() throws -> OwnerIdentity {
        guard let current else {
            throw OwnerIdentityError.syncUnavailable(reason: "boot() has not resolved yet")
        }
        return current
    }

    /// The signing key for the relay handshake and for the membership blob.
    public func requireSigner() throws -> Ed25519Signer {
        try requireIdentity().signer()
    }

    /// Starts watching the Keychain slot. **Install only after ``boot()``
    /// returned ready.**
    ///
    /// That ordering is half of a two-part defence, and both halves ship
    /// together (`owner_identity_bridge.dart:130-146`). The incident: the
    /// watcher was subscribed before `boot()` had populated the cache, the
    /// platform's *initial* emit looked like a different Owner, the freshly
    /// paired peer set was wiped, and the next `room_announced` made the app
    /// publish `v=N+1, members=[]` — every Pi the user owned self-revoked
    /// about 60 s later. The other half is the `current == nil` branch in
    /// ``handle(_:onOwnerReplaced:)``, which adopts instead of wiping.
    public func startWatching(onOwnerReplaced: @escaping @Sendable () async -> Void) {
        guard watchTask == nil else { return }
        let changes = store.changes()
        watchTask = Task { [weak self] in
            for await incoming in changes {
                guard let self else { return }
                await self.handle(incoming, onOwnerReplaced: onOwnerReplaced)
            }
        }
    }

    public func stopWatching() {
        watchTask?.cancel()
        watchTask = nil
    }

    private func handle(
        _ incoming: OwnerIdentity,
        onOwnerReplaced: @Sendable () async -> Void
    ) async {
        guard let existing = current else {
            // Adopt. NOT a wipe — see `startWatching`.
            current = incoming
            return
        }
        // Public key only. A same-pk different-seed blob is not an Owner
        // change; comparing whole blobs would turn a re-derived seed into a
        // fleet-wide wipe.
        guard existing.publicKey != incoming.publicKey else { return }
        current = incoming
        // Order matters and is load-bearing: local pairings are gone *before*
        // the caller resets its mesh watermark and re-boots, so nothing can
        // publish the outgoing Owner's member list under the incoming key.
        await wipe?.wipeAllPairings()
        await onOwnerReplaced()
    }

    // MARK: - KeyStore bridge

    /// Loads the seed, generating and persisting an Owner key if this device
    /// has never had one. Serialized by the actor, so two callers racing on
    /// first launch get the same key rather than two.
    fileprivate func loadOrCreateSeed() async throws -> Data {
        switch await boot() {
        case .ready(let identity, _):
            return identity.privateSeed
        case .syncUnavailable:
            throw OwnerIdentityError.syncUnavailable(reason: "iCloud Keychain unavailable")
        case .corrupted(let count):
            throw OwnerIdentityError.malformedBlob(byteCount: count)
        case .failed(let reason):
            throw OwnerIdentityError.syncUnavailable(reason: reason)
        }
    }

    fileprivate func loadSeed() async throws -> Data? {
        if let current { return current.privateSeed }
        return try await store.load()?.privateSeed
    }

    fileprivate func adopt(seed: Data) async throws {
        let signer = try Ed25519Signer(seed: seed)
        guard
            let identity = OwnerIdentity(
                publicKey: signer.publicKey.rawValue,
                privateSeed: seed
            )
        else { throw OwnerIdentityError.malformedBlob(byteCount: seed.count) }
        try await store.save(identity)
        current = identity
    }

    fileprivate func removeIdentity() async throws {
        try await store.delete()
        current = nil
    }
}

/// Adapts the Owner slot to the package-wide ``KeyStore`` seam, so the
/// transport signs the relay challenge with the same 32 bytes the membership
/// blob is signed with.
///
/// The seam trades in bare seeds; the Keychain item is 64 bytes (`pk || seed`)
/// because that is the layout the Flutter build already writes into the shared
/// iCloud item. Deriving the public half instead of storing it would be
/// cheaper and would produce a *different item* — and two clients disagreeing
/// about the layout of one synced blob is a silent identity corruption.
public struct OwnerKeyStore: KeyStore {
    private let bridge: OwnerIdentityBridge

    public init(bridge: OwnerIdentityBridge) {
        self.bridge = bridge
    }

    public func loadOwnerKeySeed() async throws -> Data? {
        try await bridge.loadSeed()
    }

    public func loadOrCreateOwnerKeySeed() async throws -> Data {
        try await bridge.loadOrCreateSeed()
    }

    public func storeOwnerKeySeed(_ seed: Data) async throws {
        try await bridge.adopt(seed: seed)
    }

    public func deleteOwnerKeySeed() async throws {
        try await bridge.removeIdentity()
    }
}
