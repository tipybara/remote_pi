import Foundation
import XCTest

@testable import RemotePiCrypto
@testable import RemotePiPairing
@testable import RemotePiProtocol

final class MeshPublisherTests: XCTestCase {
    private let relayURL = URL(string: "https://relay-rp1.jacobmoura.work")!
    private let peerA = Fixture.key(2)
    private let peerB = Fixture.key(5)

    private func makeSystem(
        _ responses: [FakeMeshHTTP.Response],
        peers: [PeerRecord] = []
    ) async throws -> (MeshPublisher, PeerDirectory, InMemorySessionStore, FakeMeshHTTP, OwnerIdentityBridge) {
        let store = InMemorySessionStore(peers: peers)
        let directory = PeerDirectory(store: store)
        let signer = try Ed25519Signer(seed: Fixture.ownerSeed(1))
        let identity = try XCTUnwrap(
            OwnerIdentity(publicKey: signer.publicKey.rawValue, privateSeed: signer.seed)
        )
        let bridge = OwnerIdentityBridge(
            store: InMemoryOwnerIdentityStore(stored: identity),
            wipe: directory
        )
        _ = await bridge.boot()
        let http = FakeMeshHTTP(responses)
        let publisher = MeshPublisher(
            client: MeshClient(baseURL: relayURL, http: http),
            directory: directory,
            bridge: bridge,
            now: { 1_780_000_000_000 }
        )
        return (publisher, directory, store, http, bridge)
    }

    private func record(_ peer: PeerID, nickname: String? = nil) -> PeerRecord {
        PeerRecord(
            peer: peer,
            relayURL: "https://relay-rp1.jacobmoura.work",
            pairedAt: "2026-05-22T10:30:00.000Z",
            nickname: nickname
        )
    }

    private func publishedBlob(_ http: FakeMeshHTTP, at index: Int) throws -> MeshBlob {
        let request = http.requests[index]
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let bytes = try XCTUnwrap(Base64.decodeTolerant(body["blob"] as! String))
        // Every published blob must verify under the key inside it — that is
        // all the relay checks, and all any Pi checks.
        let signature = try XCTUnwrap(Base64.decodeTolerant(body["sig"] as! String))
        let blob = try MeshBlob.parse(bytes)
        XCTAssertTrue(verifyEd25519(signature: signature, of: bytes, by: blob.ownerPk))
        return blob
    }

    private func signedEnvelope(
        _ blob: MeshBlob,
        seed: Data = Fixture.ownerSeed(1)
    ) throws -> [String: Any] {
        let bytes = try blob.canonicalBytes()
        let signer = try Ed25519Signer(seed: seed)
        return [
            "blob": Base64.encodeStandard(bytes),
            "sig": Base64.encodeStandard(try signer.signature(for: bytes)),
        ]
    }

    // MARK: - Version selection

    /// Trap T10. The Dart service publishes `_lastVersion + 1` from a cold
    /// watermark of 0, eats the inevitable 409, and recovers with a pull that
    /// **applies the relay's older blob** — deleting the peer that was just
    /// paired. Fetching first is one round-trip and no data loss.
    func testFirstPublishLearnsTheVersionBeforeWriting() async throws {
        let existing = MeshBlob(
            version: 5,
            issuedAt: 1,
            ownerPk: try Ed25519Signer(seed: Fixture.ownerSeed(1)).publicKey,
            members: []
        )
        let (publisher, _, _, http, _) = try await makeSystem(
            [
                .json(
                    200,
                    try signedEnvelope(existing).merging(
                        ["version": 5, "updated_at": 1],
                        uniquingKeysWith: { a, _ in a }
                    )
                ),
                .json(200, ["version": 6, "updated_at": 2]),
            ],
            peers: [record(peerA)]
        )

        let result = await publisher.publish(intent: .add(peerA))
        XCTAssertEqual(result, .ok(version: 6, updatedAt: 2))
        XCTAssertEqual(http.requests.count, 2)
        XCTAssertEqual(http.requests[0].httpMethod, "GET")
        let blob = try publishedBlob(http, at: 1)
        XCTAssertEqual(blob.version, 6)
        XCTAssertEqual(blob.members.map(\.remoteEpk), [peerA])
        XCTAssertEqual(blob.issuedAt, 1_780_000_000_000)
    }

    func testNoRowYetPublishesVersionOne() async throws {
        let (publisher, _, _, http, _) = try await makeSystem(
            [.text(404, "not_found"), .json(200, ["version": 1, "updated_at": 2])],
            peers: [record(peerA, nickname: "Mac do trabalho")]
        )
        let published = await publisher.publish(intent: .add(peerA))
        XCTAssertEqual(published, .ok(version: 1, updatedAt: 2))
        let blob = try publishedBlob(http, at: 1)
        XCTAssertEqual(blob.version, 1)
        XCTAssertEqual(blob.members.first?.nickname, "Mac do trabalho")
        XCTAssertEqual(blob.members.first?.relayURL, "https://relay-rp1.jacobmoura.work")
        XCTAssertEqual(blob.members.first?.pairedAt, "2026-05-22T10:30:00.000Z")
    }

    // MARK: - The empty-membership safety net

    /// Trap T6. Publishing `members: []` at `version + 1` revokes every
    /// machine the Owner has, and a transient empty read of local storage did
    /// exactly that in the field.
    func testRefusesEmptyMembershipOnTopOfAnExistingVersion() async throws {
        let (publisher, directory, _, http, _) = try await makeSystem(
            [.text(404, "not_found"), .json(200, ["version": 1, "updated_at": 2])],
            peers: [record(peerA)]
        )
        _ = await publisher.publish(intent: .add(peerA))
        try await directory.deleteSilent(peerA)

        let refused = await publisher.publish(intent: .remove(peerA))
        XCTAssertEqual(refused, .refusedEmpty)
        XCTAssertEqual(http.requests.count, 2, "nothing left this device")
    }

    func testEmptyIsAllowedWhenTheCallerProvesItMeantIt() async throws {
        let (publisher, directory, _, http, _) = try await makeSystem(
            [
                .text(404, "not_found"),
                .json(200, ["version": 1, "updated_at": 2]),
                .json(200, ["version": 2, "updated_at": 3]),
            ],
            peers: [record(peerA)]
        )
        _ = await publisher.publish(intent: .add(peerA))
        // The revoke shape: silent delete so the mutation hook cannot fire a
        // default publish the safety net would refuse, then opt in with the
        // count that actually remains.
        try await directory.deleteSilent(peerA)
        let remaining = try await directory.peers()
        let result = await publisher.publish(
            intent: .remove(peerA),
            allowEmpty: remaining.isEmpty
        )
        XCTAssertEqual(result, .ok(version: 2, updatedAt: 3))
        let emptied = try publishedBlob(http, at: 2)
        XCTAssertTrue(emptied.members.isEmpty)
    }

    // MARK: - Conflict handling

    /// Traps T8 + T10. Another device of the same Owner published while we
    /// were writing. The Dart retry pulls (overwriting local storage with the
    /// relay's view) and then re-reads local storage — so a peer we just added
    /// is dropped, and a peer we just revoked is republished. Carrying the
    /// intent through the conflict fixes both.
    func testConflictRebasesTheIntentOntoTheFetchedMembers() async throws {
        let owner = try Ed25519Signer(seed: Fixture.ownerSeed(1)).publicKey
        let relayView = MeshBlob(
            version: 9,
            issuedAt: 1,
            ownerPk: owner,
            members: [
                MeshMember(
                    remoteEpk: peerB,
                    relayURL: "https://relay-rp1.jacobmoura.work",
                    pairedAt: "2026-01-01T00:00:00.000Z"
                )
            ]
        )
        let relayResponse = FakeMeshHTTP.Response.json(
            200,
            try signedEnvelope(relayView).merging(
                ["version": 9, "updated_at": 1],
                uniquingKeysWith: { a, _ in a }
            )
        )
        let (publisher, _, store, http, _) = try await makeSystem(
            [
                relayResponse,  // pre-publish version probe
                .text(409, "stale_version (current=9)"),  // someone raced us
                relayResponse,  // rebase fetch
                .json(200, ["version": 10, "updated_at": 11]),
            ],
            peers: [record(peerA)]
        )

        let result = await publisher.publish(intent: .add(peerA))
        XCTAssertEqual(result, .ok(version: 10, updatedAt: 11))

        let published = try publishedBlob(http, at: 3)
        XCTAssertEqual(published.version, 10)
        XCTAssertEqual(
            Set(published.members.map(\.remoteEpk)),
            [peerA, peerB],
            "the freshly paired machine must survive the conflict, and the "
                + "other device's member must not be dropped"
        )
        // Local storage is reconciled to what we actually published, so the
        // next pull is a no-op diff rather than a resurrection.
        let peers = try await store.loadPeers()
        XCTAssertEqual(Set(peers.map(\.peer)), [peerA, peerB])
    }

    // MARK: - Pull

    func testPullVerifiesAndReconcilesLocalStorage() async throws {
        let owner = try Ed25519Signer(seed: Fixture.ownerSeed(1)).publicKey
        let relayView = MeshBlob(
            version: 3,
            issuedAt: 1,
            ownerPk: owner,
            members: [
                MeshMember(
                    remoteEpk: peerB,
                    relayURL: "https://relay-rp1.jacobmoura.work",
                    pairedAt: "2026-01-01T00:00:00.000Z",
                    nickname: "casa"
                )
            ]
        )
        let (publisher, _, store, _, _) = try await makeSystem(
            [
                .json(
                    200,
                    try signedEnvelope(relayView).merging(
                        ["version": 3, "updated_at": 4],
                        uniquingKeysWith: { a, _ in a }
                    )
                )
            ],
            peers: [record(peerA)]
        )

        let pulled = await publisher.pull()
        XCTAssertTrue(pulled)
        let peers = try await store.loadPeers()
        // The relay row is the source of truth for membership: peerA is gone,
        // peerB arrived with its nickname.
        XCTAssertEqual(peers.map(\.peer), [peerB])
        XCTAssertEqual(peers.first?.nickname, "casa")
        let version = await publisher.lastVersion
        XCTAssertEqual(version, 3)
    }

    /// Trap T5. The verification key comes from **inside** the blob, so a
    /// hostile or buggy relay can serve a perfectly-signed blob belonging to a
    /// different Owner at our hash slot. A valid signature is necessary and
    /// not sufficient.
    func testPullRejectsAWellSignedBlobFromAnotherOwner() async throws {
        let stranger = try Ed25519Signer(seed: Fixture.ownerSeed(31))
        let hostile = MeshBlob(
            version: 99,
            issuedAt: 1,
            ownerPk: stranger.publicKey,
            members: []
        )
        let (publisher, _, store, _, _) = try await makeSystem(
            [
                .json(
                    200,
                    try signedEnvelope(hostile, seed: Fixture.ownerSeed(31)).merging(
                        ["version": 99, "updated_at": 4],
                        uniquingKeysWith: { a, _ in a }
                    )
                )
            ],
            peers: [record(peerA)]
        )
        let pulled = await publisher.pull()
        XCTAssertFalse(pulled)
        let peers = try await store.loadPeers()
        XCTAssertEqual(peers.map(\.peer), [peerA], "cache untouched")
        let version = await publisher.lastVersion
        XCTAssertEqual(version, 0)
    }

    func testPullTreats304And404AsNoChange() async throws {
        let (publisher, _, store, _, _) = try await makeSystem(
            [.text(304, ""), .text(404, "not_found")],
            peers: [record(peerA)]
        )
        let notModified = await publisher.pull()
        XCTAssertTrue(notModified)
        let notFound = await publisher.pull()
        XCTAssertTrue(notFound)
        let peers = try await store.loadPeers()
        XCTAssertEqual(peers.map(\.peer), [peerA])
    }

    // MARK: - Concurrency

    /// Trap T9. The Dart service *drops* a publish that arrives while another
    /// is in flight, and the "next fetch loop" it defers to applies the
    /// relay's view — which does not contain the dropped mutation, so the next
    /// pull deletes it locally. Two quick peer mutations lose one.
    func testConcurrentPublishIsCoalescedNotDropped() async throws {
        let gate = OneShotGate()
        let (publisher, directory, _, http, _) = try await makeSystem(
            [
                .text(404, "not_found"),
                .json(200, ["version": 1, "updated_at": 2]),
                .json(200, ["version": 2, "updated_at": 3]),
            ],
            peers: [record(peerA)]
        )
        http.onRequest = { request in
            guard request.httpMethod == "POST" else { return }
            await gate.waitIfFirst()
        }

        // Bind locally: capturing `peerA` would drag the (non-Sendable) test
        // case into the task.
        let a = peerA
        let first = Task { await publisher.publish(intent: .add(a)) }
        try await waitUntil { http.requests.contains { $0.httpMethod == "POST" } }

        // Arrives mid-flight; must be folded in, not dropped.
        try await directory.saveSilent(record(peerB))
        let second = await publisher.publish(intent: .add(peerB))
        XCTAssertEqual(second, .coalesced)

        await gate.open()
        // `publish` returns the result of the LAST round it ran, so the
        // caller that owned the lane sees the coalesced write's result.
        let firstResult = await first.value
        XCTAssertEqual(firstResult, .ok(version: 2, updatedAt: 3))
        try await waitUntil { http.requests.filter { $0.httpMethod == "POST" }.count == 2 }

        let redo = try publishedBlob(http, at: 2)
        XCTAssertEqual(Set(redo.members.map(\.remoteEpk)), [peerA, peerB])
    }
}

/// Blocks the first caller until `open()`; everyone after passes straight
/// through.
actor OneShotGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var captured = false

    func waitIfFirst() async {
        if captured || opened { return }
        captured = true
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}
