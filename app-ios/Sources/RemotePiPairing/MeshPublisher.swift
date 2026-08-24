import Foundation
import RemotePiCrypto
import RemotePiProtocol

/// Publishes and applies the Owner's signed membership list.
///
/// Membership is the *authority* layer of this product: a machine that stops
/// finding its own key in a fresh blob detaches the Owner's channel and drops
/// its control-room allow-list on its next 60 s poll. Everything in this type
/// is shaped by that consequence.
///
/// ## Guarantees this actor adds over the Flutter original
///
/// - **Serialized with coalescing** (trap T9). The Dart service *drops* a
///   publish that arrives while another is in flight and relies on "the next
///   fetch loop" to pick the change up — but the fetch loop applies the
///   relay's view, which does not contain the dropped mutation, so the next
///   pull deletes it locally. Here a concurrent mutation is folded into the
///   in-flight publish's member set.
/// - **Intent rebasing on 409** (traps T8 and T10). The Dart retry re-reads
///   local storage after a pull that has just overwritten it with the relay's
///   older view — so a revoke that lost a race is silently republished, and a
///   freshly paired peer is deleted before it is ever published. Here the
///   intent is carried through the conflict and re-applied on top of the
///   freshly fetched member set.
/// - **Fetch before the first publish** when the watermark is 0 (trap T10),
///   instead of publishing `version: 1`, taking the inevitable 409, and
///   recovering through a destructive pull.
public actor MeshPublisher {
    /// What the caller is trying to change. Carried through a 409 so the retry
    /// re-applies *the change*, not a stale snapshot of local storage.
    public enum Intent: Hashable, Sendable {
        case add(PeerID)
        case remove(PeerID)
        case setNickname(PeerID)
    }

    private let client: MeshClient
    private let directory: PeerDirectory
    private let bridge: OwnerIdentityBridge
    private let now: @Sendable () -> Int64

    /// In-memory watermark, exactly like the Dart service: not persisted, so a
    /// cold boot starts at 0 and learns the real version from the relay.
    public private(set) var lastVersion: Int = 0
    /// The relay's wall clock at the last write. A clock, not a version — do
    /// not order by it, do not compare it to `issued_at`.
    public private(set) var lastUpdatedAt: Int64?

    /// The member set of the last successful publish, kept so a lost
    /// last-writer-wins race is *detectable* (§6 of spec 62/06). Nothing in
    /// the Flutter client does this.
    public private(set) var lastPublishedMembers: [MeshMember]?
    /// Set when the most recent pull returned a membership that differs from
    /// what we last published — i.e. another device of the same Owner won.
    public private(set) var lostLastRace = false

    private var inFlight = false
    private var pending: [Intent] = []

    public init(
        client: MeshClient,
        directory: PeerDirectory,
        bridge: OwnerIdentityBridge,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.client = client
        self.directory = directory
        self.bridge = bridge
        self.now = now
    }

    /// Reset on an Owner-key change. The next publish re-learns the version
    /// from the relay rather than continuing the previous human's sequence.
    public func resetVersionWatermark() {
        lastVersion = 0
        lastUpdatedAt = nil
        lastPublishedMembers = nil
        lostLastRace = false
    }

    // MARK: - Publish

    /// Publishes the current membership.
    ///
    /// - Parameter allowEmpty: opt-in to publishing `members: []` on top of a
    ///   non-zero version. **Compute this as `remaining.isEmpty` at the call
    ///   site**; never hard-code it, never default it to `true`. Publishing an
    ///   empty membership revokes every machine the Owner has, and the guard
    ///   exists because a transient empty read of local storage — mid-apply, a
    ///   race with a pull, an Owner reset — did exactly that in the field.
    @discardableResult
    public func publish(intent: Intent? = nil, allowEmpty: Bool = false) async -> MeshPublishResult {
        if let intent { pending.append(intent) }
        if inFlight {
            // Folded into the running publish: it re-snapshots `pending` after
            // each round. Dropping it here is what loses mutations.
            return .coalesced
        }
        inFlight = true
        defer { inFlight = false }

        var result: MeshPublishResult = .coalesced
        var first = true
        while first || !pending.isEmpty {
            first = false
            let batch = pending
            pending = []
            result = await publishOnce(batch: batch, allowEmpty: allowEmpty)
        }
        return result
    }

    private func publishOnce(batch: [Intent], allowEmpty: Bool) async -> MeshPublishResult {
        guard let owner = await bridge.currentOwnerPeerID else {
            return .failure("owner pk not loaded")
        }

        var members = await localMembers()
        if lastVersion == 0 {
            // Learn the relay's version before the first publish of this
            // process. Publishing `version: 1` blind means a 409 whose Dart-era
            // recovery (pull, which applies the relay's older blob) deletes a
            // peer that was just paired.
            if let fetched = await fetchVerified(owner: owner) {
                lastVersion = fetched.version
                lastUpdatedAt = fetched.updatedAt
                members = rebase(batch, onto: fetched.blob.members, local: members)
            }
        }

        if members.isEmpty && lastVersion > 0 && !allowEmpty {
            return .refusedEmpty
        }

        var attempt = await sign(members: members, version: lastVersion + 1, owner: owner)
        switch attempt {
        case .success(let envelope):
            let result = await client.publish(owner: owner, envelope: envelope)
            switch result {
            case .ok(let version, let updatedAt):
                record(version: version, updatedAt: updatedAt, members: members)
                return result

            case .conflict(let current):
                // Somebody with the same Owner key published a higher version.
                // Rebase the *intent* onto their member set — do not re-read
                // local storage, and do not apply their blob first: either one
                // re-adds a peer we just revoked, or drops one we just added.
                var nextVersion: Int
                var nextMembers: [MeshMember]
                if let fetched = await fetchVerified(owner: owner) {
                    nextVersion = fetched.version + 1
                    nextMembers = rebase(batch, onto: fetched.blob.members, local: members)
                    lastVersion = fetched.version
                    lastUpdatedAt = fetched.updatedAt
                } else if let current {
                    nextVersion = current + 1
                    nextMembers = members
                    lastVersion = current
                } else {
                    return result
                }
                if nextMembers.isEmpty && lastVersion > 0 && !allowEmpty {
                    return .refusedEmpty
                }
                attempt = await sign(members: nextMembers, version: nextVersion, owner: owner)
                guard case .success(let retryEnvelope) = attempt else {
                    if case .failure(let error) = attempt {
                        return .failure(String(describing: error))
                    }
                    return .failure("could not sign membership")
                }
                let retry = await client.publish(owner: owner, envelope: retryEnvelope)
                if case .ok(let version, let updatedAt) = retry {
                    record(version: version, updatedAt: updatedAt, members: nextMembers)
                    // Local storage still holds the pre-conflict view; make it
                    // match what we actually published.
                    await applyLocally(members: nextMembers)
                }
                return retry

            default:
                return result
            }

        case .failure(let error):
            return .failure(String(describing: error))
        }
    }

    private func record(version: Int, updatedAt: Int64, members: [MeshMember]) {
        lastVersion = version
        lastUpdatedAt = updatedAt
        lastPublishedMembers = members
        lostLastRace = false
    }

    private func sign(
        members: [MeshMember],
        version: Int,
        owner: PeerID
    ) async -> Result<MeshEnvelope, any Error> {
        do {
            let blob = MeshBlob(
                version: version,
                issuedAt: now(),
                ownerPk: owner,
                members: members
            )
            let bytes = try blob.canonicalBytes()
            let signer = try await bridge.requireSigner()
            // Plain Ed25519 over the canonical bytes: no prehash, no domain
            // separator, no context string. The relay verifies with
            // `verify_strict` over exactly the bytes it received.
            let signature = try signer.signature(for: bytes)
            return .success(MeshEnvelope(blobData: bytes, signature: signature))
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Pull

    /// Fetches the relay's membership, verifies it, and reconciles local
    /// storage against it. Returns `true` when the local cache reflects a
    /// verified relay version — including `304` and `404`, where there is
    /// nothing to change.
    @discardableResult
    public func pull() async -> Bool {
        guard let owner = await bridge.currentOwnerPeerID else { return false }
        let result = await client.fetch(
            owner: owner,
            since: lastVersion > 0 ? lastVersion : nil
        )
        switch result {
        case .ok(let envelope, let version, let updatedAt):
            guard let blob = verified(envelope, expecting: owner) else { return false }
            if let published = lastPublishedMembers {
                // §6: nobody merges member sets — the higher version wins
                // wholesale. Detecting the loss is the only way to know a
                // mutation of ours evaporated.
                lostLastRace = Set(published) != Set(blob.members)
            }
            await applyLocally(members: blob.members)
            lastVersion = version
            lastUpdatedAt = updatedAt
            return true
        case .notModified, .notFound:
            return true
        case .failure:
            return false
        }
    }

    private func fetchVerified(
        owner: PeerID
    ) async -> (blob: MeshBlob, version: Int, updatedAt: Int64)? {
        // No `since`: the point of this fetch is the *contents*, and a 304
        // would give us nothing to rebase onto.
        guard case .ok(let envelope, let version, let updatedAt) = await client.fetch(owner: owner)
        else { return nil }
        guard let blob = verified(envelope, expecting: owner) else { return nil }
        return (blob, version, updatedAt)
    }

    /// Verifies a fetched envelope and confirms it belongs to *this* Owner.
    ///
    /// Trap T5: the verification key comes from **inside** the blob, so a
    /// hostile or merely buggy relay can serve a perfectly-signed blob
    /// belonging to a different Owner at your hash slot. A valid signature is
    /// necessary and not sufficient — both reference readers byte-compare the
    /// embedded `owner_pk` against the key they hold, and so does this.
    ///
    /// The blob bytes are used exactly as received: re-encoding a parsed blob
    /// before verifying would check a signature against bytes nobody signed.
    private func verified(_ envelope: MeshEnvelope, expecting owner: PeerID) -> MeshBlob? {
        guard
            let bytes = envelope.blobData,
            let signature = envelope.signatureData,
            let blob = try? MeshBlob.parse(bytes),
            verifyEd25519(signature: signature, of: bytes, by: blob.ownerPk),
            blob.ownerPk == owner
        else { return nil }
        return blob
    }

    // MARK: - Local reconciliation

    /// The relay row is the source of truth for *membership*: a machine listed
    /// there is upserted locally, one absent from it is dropped along with its
    /// cached rooms.
    ///
    /// Every write here is silent (trap T7). Firing the republish hook from the
    /// apply path loops `pull → apply → publish` and lets a publish observe the
    /// half-applied — possibly empty — storage state.
    ///
    /// Note what does *not* happen: no re-keying. The Flutter client keys peers
    /// by whatever spelling the QR gave (url-safe) and looks them up here by
    /// the blob's standard Base64, so the lookup misses, a duplicate record is
    /// written, and the machine's cached room pointer is lost (trap T11).
    /// ``PeerRecord/peer`` is a ``PeerID`` — 32 bytes — so the diff is a no-op
    /// where nothing changed.
    private func applyLocally(members: [MeshMember]) async {
        guard let existing = try? await directory.peers() else { return }
        var byPeer = Dictionary(uniqueKeysWithValues: existing.map { ($0.peer, $0) })

        for member in members {
            let previous = byPeer.removeValue(forKey: member.remoteEpk)
            var record = previous ?? PeerRecord(
                peer: member.remoteEpk,
                relayURL: member.relayURL,
                pairedAt: member.pairedAt
            )
            // Mesh-controlled fields only. `sessionName` and `lastOpenedRoom`
            // are per-device and must survive a pull.
            record.relayURL = member.relayURL
            record.pairedAt = member.pairedAt
            record.nickname = member.nickname
            if record.sessionName == nil {
                record.sessionName = member.nickname
            }
            if previous == nil || previous != record {
                try? await directory.saveSilent(record)
            }
        }

        for orphan in byPeer.keys {
            try? await directory.deleteSilent(orphan)
        }
    }

    private func localMembers() async -> [MeshMember] {
        let peers = (try? await directory.peers()) ?? []
        return normalized(peers.map(Self.member(from:)))
    }

    static func member(from record: PeerRecord) -> MeshMember {
        MeshMember(
            // `wireValue` is standard padded Base64 — see the type. The
            // pi-extension compares this string against its own key formatted
            // as standard Base64; a url-safe spelling here reads as "I am not
            // listed" and the machine self-revokes.
            remoteEpk: record.peer,
            relayURL: record.relayURL,
            pairedAt: record.pairedAt,
            nickname: record.nickname
        )
    }

    /// Member order is preserved on the wire, not sorted by anyone — so two
    /// devices publishing the same logical membership can produce different
    /// bytes. Sorting by the key makes "compare what I published with what came
    /// back" a byte comparison instead of a set comparison.
    private func normalized(_ members: [MeshMember]) -> [MeshMember] {
        members.sorted { $0.remoteEpk.wireValue < $1.remoteEpk.wireValue }
    }

    private func rebase(
        _ batch: [Intent],
        onto relayMembers: [MeshMember],
        local: [MeshMember]
    ) -> [MeshMember] {
        guard !batch.isEmpty else { return relayMembers.isEmpty ? local : normalized(relayMembers) }
        var result = relayMembers
        for intent in batch {
            switch intent {
            case .add(let peer), .setNickname(let peer):
                guard let mine = local.first(where: { $0.remoteEpk == peer }) else {
                    // The peer is gone locally — the intent is stale; leaving
                    // the relay's view untouched is the conservative answer.
                    continue
                }
                if let index = result.firstIndex(where: { $0.remoteEpk == peer }) {
                    result[index] = mine
                } else {
                    result.append(mine)
                }
            case .remove(let peer):
                result.removeAll { $0.remoteEpk == peer }
            }
        }
        return normalized(result)
    }
}
