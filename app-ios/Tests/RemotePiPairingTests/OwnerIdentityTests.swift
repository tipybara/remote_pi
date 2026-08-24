import Foundation
import Security
import XCTest

@testable import RemotePiCrypto
@testable import RemotePiPairing
@testable import RemotePiProtocol

final class OwnerIdentityTests: XCTestCase {
    private func identity(_ seed: UInt8) throws -> OwnerIdentity {
        let signer = try Ed25519Signer(seed: Fixture.ownerSeed(seed))
        return try XCTUnwrap(
            OwnerIdentity(publicKey: signer.publicKey.rawValue, privateSeed: signer.seed)
        )
    }

    // MARK: - The 64-byte blob

    func testBlobLayoutIsPublicKeyThenSeed() throws {
        let id = try identity(3)
        let blob = id.blob
        XCTAssertEqual(blob.count, 64)
        XCTAssertEqual(blob.prefix(32), id.publicKey)
        XCTAssertEqual(blob.suffix(32), id.privateSeed)
        // The Flutter app writes exactly these 64 bytes into the same iCloud
        // item (`owner_identity.dart:42-61`). No version byte, no JSON, no
        // base64 — a different layout here is a silent cross-device identity
        // corruption, not a version negotiation.
        XCTAssertEqual(OwnerIdentity(blob: blob), id)
    }

    func testBlobRejectsAnyOtherLength() throws {
        let blob = try identity(3).blob
        XCTAssertNil(OwnerIdentity(blob: blob.dropLast()))
        XCTAssertNil(OwnerIdentity(blob: blob + Data([0])))
        XCTAssertNil(OwnerIdentity(blob: Data()))
    }

    func testSignerRejectsAMismatchedBlob() throws {
        // pk and seed from two different keys — a hand-edited item, or a
        // partial iCloud write. Signing with it would produce a signature no
        // Pi accepts, and the failure would surface far from here.
        let a = try identity(3)
        let b = try identity(4)
        let frankenstein = try XCTUnwrap(
            OwnerIdentity(publicKey: a.publicKey, privateSeed: b.privateSeed)
        )
        XCTAssertThrowsError(try frankenstein.signer())
    }

    // MARK: - The Keychain item

    func testKeychainQueryShapeMatchesTheFlutterBuild() {
        let query = KeychainOwnerIdentityStore.baseQuery()
        XCTAssertEqual(query[kSecClass as String] as! CFString, kSecClassGenericPassword)
        XCTAssertEqual(query[kSecAttrService as String] as? String, "dev.remotepi.owner.identity")
        // Literally "singleton": one slot whose contents can change under us
        // is what makes an Owner swap detectable. Keying by the Owner key
        // would accumulate identities and never notice a change.
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, "singleton")
        // `kSecAttrSynchronizable` is all-or-nothing at query time: a query
        // that omits it matches no synchronizable item even when service and
        // account are right. Symptom: `load()` returns nil on a device that
        // has the key, a second Owner key is generated, and every paired Pi
        // self-revokes.
        XCTAssertEqual(query[kSecAttrSynchronizable as String] as! CFBoolean, kCFBooleanTrue)
        // Accessibility is attached on ADD only (`KeychainSyncStore.swift:59`);
        // an update that carried it would still not move an existing item's
        // class, so putting it here would be a lie.
        XCTAssertNil(query[kSecAttrAccessible as String])
        XCTAssertNil(
            query[kSecAttrAccessGroup as String],
            "no keychain sharing group exists anywhere in the product"
        )
    }

    // MARK: - The boot gate

    func testFirstBootGeneratesAndPersists() async throws {
        let store = InMemoryOwnerIdentityStore()
        let bridge = OwnerIdentityBridge(store: store)
        guard case .ready(let id, let generated) = await bridge.boot() else {
            return XCTFail("expected ready")
        }
        XCTAssertTrue(generated, "a fresh key makes the device onboarding-eligible")
        let persisted = try await store.load()
        XCTAssertEqual(persisted, id)
    }

    func testKeyRestoredFromICloudIsNotGenerated() async throws {
        // Reinstalling the app on the same device, or a new phone under the
        // same Apple ID: the wizard must not re-run even with zero peers.
        let existing = try identity(7)
        let bridge = OwnerIdentityBridge(store: InMemoryOwnerIdentityStore(stored: existing))
        guard case .ready(let id, let generated) = await bridge.boot() else {
            return XCTFail("expected ready")
        }
        XCTAssertEqual(id, existing)
        XCTAssertFalse(generated)
    }

    func testBootIsIdempotentAndCaches() async throws {
        let store = InMemoryOwnerIdentityStore(stored: try identity(7))
        let bridge = OwnerIdentityBridge(store: store)
        _ = await bridge.boot()
        // The Dart bridge re-reads the Keychain on every call and swaps
        // `_current` **without** wiping peers, because the wipe lives only on
        // the watch path — "Check again" on the sync gate calls boot() again.
        // Caching is what keeps every identity change on the single path that
        // knows how to handle one.
        await store.setLoadError(.keychain(status: -25300, operation: "should not be called"))
        guard case .ready(_, let generated) = await bridge.boot() else {
            return XCTFail("expected the cached identity")
        }
        XCTAssertFalse(generated)
    }

    func testSyncUnavailableGatesAndGeneratesNothing() async throws {
        let store = InMemoryOwnerIdentityStore(
            syncAvailable: false,
            loadError: .syncUnavailable(reason: "iCloud Keychain is not enabled on this device")
        )
        let bridge = OwnerIdentityBridge(store: store)
        guard case .syncUnavailable = await bridge.boot() else {
            return XCTFail("expected the gate")
        }
        // No local-only fallback identity, ever: `plan/23` blocks first launch
        // rather than diverge silently from a future sync.
        let persisted = try? await store.load()
        XCTAssertNil(persisted ?? nil)
        await XCTAssertThrowsErrorAsync(try await bridge.requireIdentity())
    }

    func testMalformedBlobIsItsOwnStateNotASplashScreenHang() async {
        let store = InMemoryOwnerIdentityStore(loadError: .malformedBlob(byteCount: 63))
        let bridge = OwnerIdentityBridge(store: store)
        guard case .corrupted(let count) = await bridge.boot() else {
            return XCTFail("expected corrupted")
        }
        XCTAssertEqual(count, 63)
        // The Flutter path throws out of boot() uncaught and pins every device
        // of that Apple ID on the splash forever. And auto-overwriting would
        // rotate the Owner key and revoke every machine — so this must stay a
        // state the UI can offer an explicit reset for.
    }

    // MARK: - Watching

    func testWatcherAdoptsWhenNothingIsBootedYet() async throws {
        // The regression this guards: subscribing before boot() populated the
        // cache made the platform's *initial* emit look like a different
        // Owner, which wiped the freshly paired peer set — and the next
        // publish shipped `members: []`, self-revoking every Pi ~60 s later.
        let store = InMemorySessionStore(peers: [
            PeerRecord(peer: Fixture.key(2), relayURL: "https://r", pairedAt: "t")
        ])
        let directory = PeerDirectory(store: store)
        let identityStore = InMemoryOwnerIdentityStore(stored: try identity(7))
        let bridge = OwnerIdentityBridge(store: identityStore, wipe: directory)
        await bridge.startWatching(onOwnerReplaced: { XCTFail("adopting is not a replacement") })

        try await waitUntil {
            let current = await bridge.current
            return current != nil
        }
        let adopted = await bridge.current
        XCTAssertEqual(adopted, try identity(7))
        let peers = try await store.loadPeers()
        XCTAssertEqual(peers.count, 1, "adopting is not a wipe")
    }

    func testDifferentOwnerWipesPairingsThenNotifies() async throws {
        let store = InMemorySessionStore(peers: [
            PeerRecord(peer: Fixture.key(2), relayURL: "https://r", pairedAt: "t")
        ])
        try await store.saveRooms([RoomMeta(roomID: .main)], for: Fixture.key(2))
        let directory = PeerDirectory(store: store)
        let identityStore = InMemoryOwnerIdentityStore(stored: try identity(7))
        let bridge = OwnerIdentityBridge(store: identityStore, wipe: directory)
        _ = await bridge.boot()

        let replaced = expectation(description: "onOwnerReplaced")
        await bridge.startWatching(onOwnerReplaced: { replaced.fulfill() })
        await identityStore.inject(try identity(9))

        await fulfillment(of: [replaced], timeout: 2)
        let swapped = await bridge.current
        XCTAssertEqual(swapped, try identity(9))
        let peers = try await store.loadPeers()
        XCTAssertTrue(peers.isEmpty, "peers must be gone before the caller re-boots")
        let rooms = try await store.loadRooms(for: Fixture.key(2))
        XCTAssertTrue(rooms.isEmpty)
    }

    func testSameKeyDifferentSeedIsNotAnOwnerChange() async throws {
        let store = InMemorySessionStore(peers: [
            PeerRecord(peer: Fixture.key(2), relayURL: "https://r", pairedAt: "t")
        ])
        let directory = PeerDirectory(store: store)
        let original = try identity(7)
        let identityStore = InMemoryOwnerIdentityStore(stored: original)
        let bridge = OwnerIdentityBridge(store: identityStore, wipe: directory)
        _ = await bridge.boot()
        await bridge.startWatching(onOwnerReplaced: { XCTFail("public key did not change") })

        // Comparison is on the public key only (`:155`): a blob whose seed
        // differs but whose key does not is not an Owner change.
        let sameKey = try XCTUnwrap(
            OwnerIdentity(publicKey: original.publicKey, privateSeed: Fixture.ownerSeed(42))
        )
        await identityStore.inject(sameKey)
        try await Task.sleep(for: .milliseconds(80))
        let peers = try await store.loadPeers()
        XCTAssertEqual(peers.count, 1)
    }

    // MARK: - The KeyStore seam

    func testKeyStoreAdapterIsStableAcrossCalls() async throws {
        let bridge = OwnerIdentityBridge(store: InMemoryOwnerIdentityStore())
        let keyStore = OwnerKeyStore(bridge: bridge)
        let first = try await keyStore.loadOrCreateOwnerKeySeed()
        let second = try await keyStore.loadOrCreateOwnerKeySeed()
        XCTAssertEqual(first, second, "two callers on first launch get one key, never two")
        let reloaded = try await keyStore.loadOwnerKeySeed()
        XCTAssertEqual(reloaded, first)
        let signer = try Ed25519Signer(seed: first)
        let peerID = await bridge.currentOwnerPeerID
        XCTAssertEqual(peerID, signer.publicKey)
    }
}

// MARK: - helpers

func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("condition never became true")
}

func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {
        // Expected.
    }
}
