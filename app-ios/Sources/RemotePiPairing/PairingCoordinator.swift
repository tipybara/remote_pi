import Foundation
import RemotePiCrypto
import RemotePiProtocol
import RemotePiTransport

/// Everything one successful pairing produced.
public struct PairingOutcome: Sendable, Equatable {
    /// The machine, as it will be remembered on this device.
    public let peer: PeerRecord
    /// The session the QR was generated from, seeded from `pair_ok` so the
    /// client keys by session before the first `room_announced` arrives.
    public let room: RoomMeta
    /// The reply verbatim, for anything the two above do not carry.
    public let pairOk: PairOk

    /// `os.hostname()` of the Mac. The post-pair nickname sheet pre-fills with
    /// it so the user sees "Mac do Jacob" rather than a generic "Pi".
    public var hostnameHint: String? { pairOk.hostname }

    public init(peer: PeerRecord, room: RoomMeta, pairOk: PairOk) {
        self.peer = peer
        self.room = room
        self.pairOk = pairOk
    }
}

/// Runs a pairing from scanned QR to signed membership.
///
/// ## The sequence
///
/// 1. Scan → ``PairingQRPayload``.
/// 2. Connect to the relay **as the Owner key** — `hello.room_id` is always
///    `"main"` — and answer the challenge.
/// 3. Send `pair_request` inside an ``Envelope`` addressed to the QR's `epk`
///    and `rm` (or ``RoomID/main``).
/// 4. The Pi answers `pair_ok`, carrying the historical `session_name` /
///    `room_id` **and** the plan-61 identity — `session_id`, `workspace_path`,
///    `display_name`, `name_rev`.
/// 5. Persist, then publish a new `mesh_versions` including this machine.
///
/// ## There is no ephemeral App-key, and no second connection
///
/// `PROTOCOL.md:41` still describes an ephemeral per-pairing key. No code in
/// any of the three implementations creates one: the Flutter client passes the
/// **Owner** keypair into pairing (`pairing_viewmodel.dart:65-67`) — the same
/// key the steady-state connection uses — and the socket that carried
/// `pair_request` is adopted as the chat connection rather than reconnected.
/// Reproducing that matters beyond tidiness: the Pi learns who the Owner is
/// from `outer.peer` **as the relay rewrote it**, so pairing with a throwaway
/// key would enrol the throwaway key in `peers.json` and nothing would work
/// afterwards.
///
/// ## And no `pair_request` on reconnect
///
/// The Pi recognises a peer already in `peers.json` when any non-pair frame
/// arrives (`index.ts:1902-1913`). Re-sending `pair_request` would burn a token
/// this client does not have — and if the peer is already attached the frame is
/// dropped silently, so the client would wait out its timeout for nothing.
public actor PairingCoordinator {
    private let transport: any RelayTransport
    private let keyStore: any KeyStore
    private let directory: PeerDirectory?
    private let publisher: MeshPublisher?
    private let http: any MeshHTTPClient
    private let timeout: Duration
    private let makeRequestID: @Sendable () -> String
    private let now: @Sendable () -> Date

    public init(transport: any RelayTransport, keyStore: any KeyStore) {
        self.init(transport: transport, keyStore: keyStore, directory: nil, publisher: nil)
    }

    public init(
        transport: any RelayTransport,
        keyStore: any KeyStore,
        directory: PeerDirectory?,
        publisher: MeshPublisher?,
        http: any MeshHTTPClient = URLSessionMeshHTTPClient(),
        // 30 s around the whole pairing, matching `pairing_viewmodel.dart:78-85`.
        // A `transport_error` short-circuits it — see `pairDetailed`.
        timeout: Duration = .seconds(30),
        makeRequestID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.keyStore = keyStore
        self.directory = directory
        self.publisher = publisher
        self.http = http
        self.timeout = timeout
        self.makeRequestID = makeRequestID
        self.now = now
    }

    /// Performs steps 2–5 and returns the resulting record.
    @discardableResult
    public func pair(
        with payload: PairingQRPayload,
        relayURL: URL,
        deviceName: String
    ) async throws -> PeerRecord {
        try await pairDetailed(with: payload, relayURL: relayURL, deviceName: deviceName).peer
    }

    /// Same flow, keeping everything `pair_ok` said.
    public func pairDetailed(
        with payload: PairingQRPayload,
        relayURL: URL,
        deviceName: String
    ) async throws -> PairingOutcome {
        try checkRelay(payload: payload, configured: relayURL)

        let seed = try await keyStore.loadOrCreateOwnerKeySeed()
        let signer = try Ed25519Signer(seed: seed)

        // Subscribe before connecting: the reply can land the instant the
        // handshake completes, and an `AsyncStream` created afterwards would
        // not replay it.
        let events = transport.events
        try await transport.connect(to: relayURL, as: signer)

        let request = PairRequest(
            id: makeRequestID(),
            token: payload.token,
            deviceName: deviceName
        )
        // `.sortedKeys` only so the bytes are reproducible in tests — the Pi
        // runs `JSON.parse` and does not care about order. There is no
        // signature field to add here: `PROTOCOL.md:325` describes an
        // Owner-signed pair_request, and the wire type has never had one.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // The room must be set on the envelope *before* the send: the relay
        // routes by an exact `(peer, room)` lookup with no normalisation, and
        // a `pair_request` addressed to `main` reaches a Pi that lives in a
        // session room only by accident.
        let destination = payload.room ?? .main
        // The phone hellos at `main`. The Pi answers `pair_ok` from `rm`
        // (the session room). Without this, the transport demux drops the
        // reply as a room mismatch and pairing sits on the 30 s timeout
        // while the Mac has already enrolled us.
        await transport.setActiveRoom(destination)
        let envelope = Envelope(
            peer: payload.peer,
            room: destination,
            payload: try encoder.encode(ClientMessage.pairRequest(request))
        )
        try await transport.send(envelope)

        let pairOk = try await awaitReply(
            events: events,
            id: request.id,
            expecting: payload.peer
        )

        let room = pairOk.roomMeta(qrRoom: payload.room)
        let record = PeerRecord(
            peer: payload.peer,
            // Whichever relay we just paired on. A legacy QR's `r` is kept for
            // the record only; connection resolution is global, never per-peer.
            relayURL: payload.relayURL ?? relayURL.absoluteString,
            // The **phone's** clock, deliberately: the Mac writes its own
            // `paired_at` into `peers.json` and the two never need to agree.
            pairedAt: Self.iso8601(now()),
            sessionName: pairOk.sessionName.isEmpty ? nil : pairOk.sessionName,
            nickname: nil,
            hostname: pairOk.hostname,
            harnessName: pairOk.harness?.name,
            harnessVersion: pairOk.harness?.version,
            // A hint for restoring the UI, never identity.
            lastOpenedRoom: room.roomID
        )

        if let directory {
            if publisher != nil {
                // Explicit ordering: save, then publish once. Going through the
                // mutation hook here would publish from two places for one
                // pairing.
                try await directory.saveSilent(record)
            } else {
                try await directory.save(record)
            }
            try await directory.upsertRoom(room, for: payload.peer)
        }

        // Pairing is not durable until the machine sees itself in a signed
        // membership — it self-revokes otherwise. But a publish failure is
        // retry-later, **not** a pairing failure: the peer is already in the
        // Mac's `peers.json` and the chat works.
        await publisher?.publish(intent: .add(payload.peer))

        return PairingOutcome(peer: record, room: room, pairOk: pairOk)
    }

    /// Signs `members` at `version` and `POST`s them.
    ///
    /// `version` must be strictly greater than what the relay holds or the
    /// publish comes back `409`; ``MeshPublisher`` is the path that knows how
    /// to pick one and how to recover. This entry point exists for callers that
    /// already know the version.
    @discardableResult
    public func publishMembership(
        _ members: [MeshMember],
        version: Int,
        relayBaseURL: URL
    ) async throws -> MeshEnvelope {
        let seed = try await keyStore.loadOrCreateOwnerKeySeed()
        let signer = try Ed25519Signer(seed: seed)
        let blob = MeshBlob(
            version: version,
            issuedAt: Int64(now().timeIntervalSince1970 * 1000),
            ownerPk: signer.publicKey,
            members: members
        )
        let bytes = try blob.canonicalBytes()
        let envelope = MeshEnvelope(
            blobData: bytes,
            signature: try signer.signature(for: bytes)
        )
        let client = MeshClient(baseURL: relayBaseURL, http: http)
        switch await client.publish(owner: signer.publicKey, envelope: envelope) {
        case .ok:
            return envelope
        case .conflict(let current):
            throw MeshPublishError.conflict(current: current)
        case .badRequest(let message), .forbidden(let message), .failure(let message):
            throw MeshPublishError.rejected(message)
        case .tooLarge:
            throw MeshPublishError.rejected("payload_too_large")
        case .refusedEmpty, .coalesced:
            throw MeshPublishError.rejected("not published")
        }
    }

    /// Fetches the current membership and verifies its signature locally.
    ///
    /// The relay is not trusted to vouch for a blob: the signature is checked
    /// against the `owner_pk` **inside** it, and that key is then compared with
    /// the one this device holds. A signature that verifies is necessary and
    /// not sufficient — the URL slot proves nothing.
    public func fetchMembership(relayBaseURL: URL, owner: PeerID) async throws -> MeshBlob {
        let client = MeshClient(baseURL: relayBaseURL, http: http)
        switch await client.fetch(owner: owner) {
        case .ok(let envelope, _, _):
            guard
                let bytes = envelope.blobData,
                let signature = envelope.signatureData,
                let blob = try? MeshBlob.parse(bytes),
                verifyEd25519(signature: signature, of: bytes, by: blob.ownerPk),
                blob.ownerPk == owner
            else { throw MeshBlobError.badSignature }
            return blob
        case .notFound:
            // No row yet: an empty membership at version 0, not an error.
            return MeshBlob(
                version: 1,
                issuedAt: Int64(now().timeIntervalSince1970 * 1000),
                ownerPk: owner,
                members: []
            )
        case .notModified:
            throw MeshPublishError.rejected("304 without a cached version")
        case .failure(let message):
            throw MeshPublishError.rejected(message)
        }
    }

    // MARK: - Internals

    private func checkRelay(payload: PairingQRPayload, configured: URL) throws {
        guard let raw = payload.relayURL else { return }
        // Legacy QRs carry `r=`. Comparison is done in ws form because the same
        // relay is spelled `https://` in settings and `wss://` in an old QR.
        let configuredWS = (try? relayWebSocketURL(from: configured))?.absoluteString
        let qrWS = URL(string: raw).flatMap { try? relayWebSocketURL(from: $0) }?.absoluteString
        guard let qrWS, let configuredWS, qrWS == configuredWS else {
            throw PairFailure.relayMismatch(qr: raw, configured: configured.absoluteString)
        }
    }

    private func awaitReply(
        events: AsyncStream<TransportEvent>,
        id: String,
        expecting peer: PeerID
    ) async throws -> PairOk {
        let deadline = timeout
        return try await withThrowingTaskGroup(of: PairOk.self) { group in
            group.addTask {
                try await Self.consume(events, id: id, expecting: peer)
            }
            group.addTask {
                try await Task.sleep(for: deadline)
                throw PairFailure.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw PairFailure.timedOut }
            return result
        }
    }

    private static func consume(
        _ events: AsyncStream<TransportEvent>,
        id: String,
        expecting peer: PeerID
    ) async throws -> PairOk {
        for await event in events {
            switch event {
            case .envelope(let envelope):
                // Trap T8: the socket's inbound queue is not filtered by
                // sender, and `in_reply_to` is the Flutter client's only
                // guard. Checking the delivered `peer` too costs nothing: the
                // relay rewrote it to the authenticated sender, so it cannot
                // be spoofed by a third party with a live connection.
                guard envelope.peer == peer, let payload = envelope.payload else { continue }
                switch InnerPairFrame.classify(payload) {
                case .pairOk(let ok):
                    guard ok.inReplyTo == id else { continue }
                    return ok
                case .pairError(let error):
                    guard error.inReplyTo == id else { continue }
                    throw PairFailure.wire(code: error.code, message: error.message)
                case .unknownPeer(let message):
                    throw PairFailure.unknownPeer(message: message)
                case .other:
                    continue
                }

            case .control(.transportError(let errorPeer, let room, let reason)):
                guard errorPeer == peer else { continue }
                // Trap T4: the QR embedded the room id when it was *drawn*. A
                // restarted Pi, a `/name`, or a re-spawned daemon changes it,
                // and the `pair_request` then hits a dead `(peer, room)`. This
                // is the answer, and it is not a `pair_error` — two failure
                // channels for one user-visible problem. Surface it now rather
                // than sitting out the 30 s timeout.
                throw PairFailure.transportOffline(peer: errorPeer, room: room, reason: reason)

            case .disconnected(let error):
                throw PairFailure.disconnected(reason: error.map { String(describing: $0) })

            case .connected, .control:
                continue
            }
        }
        throw PairFailure.disconnected(reason: nil)
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        // `2026-08-25T12:34:56.789Z` — the shape Dart's
        // `toUtc().toIso8601String()` produces, which is what already sits in
        // every `mesh_versions` blob and `peers.json` in the wild. Opaque to
        // every consumer, so the only requirement is that it stays stable.
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

/// Failures of the membership endpoints that are not pairing failures.
public enum MeshPublishError: Error, Hashable, Sendable {
    case conflict(current: Int?)
    case rejected(String)
}
