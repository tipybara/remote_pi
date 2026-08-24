import Foundation
import RemotePiProtocol

/// One authenticated relay connection.
///
/// ## Lifetime
///
/// **One instance is one socket.** ``events`` finishes with
/// ``TransportEvent/disconnected(error:)`` and never restarts; a reconnect
/// builds a new transport. ``RelayConnectionManager`` is what owns the
/// reconnect ladder, so this type can stay a straight-line state machine with
/// no "am I retrying" branch anywhere in it.
///
/// ## Handshake
///
/// ```text
/// client                                      relay
///   │  {"type":"hello","pubkey":…,"room_id":"main"}  ──►   (≤ 5 s)
///   │                                   ◄──  {"type":"challenge","nonce":…}
///   │  {"type":"auth","sig":…}                      ──►   (no ack, ever)
///   ▼  ═══════════════ routing loop ═══════════════
/// ```
///
/// Three details that have each cost real debugging time:
///
/// - **Sign the raw nonce bytes.** `sig = Ed25519(sk, base64_decode(nonce))`
///   with no domain separator, no hashing, and no re-encoding
///   (`relay/src/auth/challenge.rs:76-89`). Signing the Base64 *text* produces
///   a perfectly well-formed frame that fails verification, and the relay
///   answers a verification failure with a bare close — no error frame exists
///   anywhere in this relay.
/// - **`sig` must be standard Base64.** `verify_auth` decodes with the
///   `STANDARD` engine only — unlike `pubkey`, there is no URL-safe and no
///   unpadded fallback. A 64-byte signature almost always contains `+` or `/`,
///   so a "safe base64" helper reused here fails every time.
/// - **The phone must not publish `room_meta`.** A `hello` carrying meta makes
///   this device's own `main` room show up as a session tile on every other
///   paired device.
public actor RelayWebSocketTransport: RelayTransport {
    public nonisolated let events: AsyncStream<TransportEvent>
    private nonisolated let continuation: AsyncStream<TransportEvent>.Continuation

    private let makeChannel: WebSocketChannelFactory
    private let timing: TransportTiming

    private var channel: (any WebSocketChannel)?
    private var receiveLoop: Task<Void, Never>?
    private var pingLoop: Task<Void, Never>?
    private var livenessLoop: Task<Void, Never>?

    private var authenticated = false
    private var finished = false
    private var localPeer: PeerID?

    /// The room this connection currently talks to, and the room it accepts
    /// inbound envelopes from. Defaults to `main` — which is why the manager
    /// must push the real value down *before* it reports itself online.
    private var activeRoom: RoomID = .main

    /// Frames that arrived before the handshake finished.
    ///
    /// The Flutter client funnels the whole pre-auth window into a single
    /// `Completer`, so a second frame arriving there calls `complete()` twice,
    /// throws into a swallowing `catch`, and is **lost**
    /// (`ws_transport.dart:76-88`). The window is real, not theoretical:
    /// there is an `await` on the signature between reading the challenge and
    /// flipping `authDone`. Nothing is pushed in that window by today's relay,
    /// but a queue costs nothing and cannot lose a frame.
    private var pendingPreAuth: [String] = []
    private var handshakeWaiter: CheckedContinuation<String, any Error>?

    private var lastInboundAt: ContinuousClock.Instant = .now
    private var authSentAt: ContinuousClock.Instant?
    private var sawInboundAfterAuth = false

    private var statistics = TransportStatistics()

    public init(
        channelFactory: @escaping WebSocketChannelFactory = URLSessionWebSocketChannel.factory,
        timing: TransportTiming = TransportTiming()
    ) {
        self.makeChannel = channelFactory
        self.timing = timing
        let (stream, continuation) = AsyncStream<TransportEvent>.makeStream()
        self.events = stream
        self.continuation = continuation
    }

    // MARK: - Connection

    public func connect(to relayURL: URL, as signer: any Signer) async throws {
        guard channel == nil, !finished else {
            throw RelayTransportError.handshakeFailed("transport already used; build a new one")
        }
        let url = try relayWebSocketURL(from: relayURL)
        let socket = try makeChannel(url)
        channel = socket
        localPeer = signer.publicKey
        lastInboundAt = .now
        startReceiveLoop(on: socket)

        // Whole connect + handshake budget, enforced by a watchdog rather than
        // by racing `performHandshake` inside a task group. A group would have
        // to wait for the losing child to finish, and that child is parked on
        // `handshakeWaiter` — which only `finish(error:)` resumes. Racing
        // deadlocks; tearing the connection down from the side does not.
        let deadline = Task { [weak self, timeout = timing.handshakeTimeout] in
            try? await Task.sleep(for: timeout)
            await self?.failHandshakeIfStillPending()
        }
        defer { deadline.cancel() }

        do {
            try await performHandshake(signer: signer, on: socket)
        } catch {
            let mapped = (error as? RelayTransportError) ?? .underlying(error)
            finish(error: mapped)
            throw mapped
        }

        startSocketPingLoop(on: socket)
        startLivenessLoop()
    }

    private func performHandshake(signer: any Signer, on socket: any WebSocketChannel) async throws {
        // 1. hello. `room_id` is always the literal "main": this device is a
        //    client, it owns no session, and `meta` stays nil (see the type
        //    doc). The relay ignores every other key at auth time and re-reads
        //    the body afterwards, so `room_id` is deliberately NOT covered by
        //    the signature — do not try to bind it.
        try await write(.hello(pubkey: signer.publicKey, room: .main, meta: nil), to: socket)

        // 2. challenge.
        let raw = try await nextHandshakeFrame(timeout: timing.challengeTimeout)
        guard case .control(.challenge(let nonce)) = RelayFrame.classify(raw) else {
            // There is no `{"type":"error"}` in this relay — `grep` finds the
            // string only in the pi-extension's dead `room_already_open` path.
            // So anything that is not a challenge here is a protocol break,
            // not a rejection we can explain to the user.
            throw RelayTransportError.handshakeFailed("expected challenge, got: \(raw.prefix(120))")
        }
        guard nonce.count == 32 else {
            throw RelayTransportError.handshakeFailed("challenge nonce is \(nonce.count) bytes, expected 32")
        }

        // 3. auth over the RAW nonce bytes.
        let signature: Data
        do {
            signature = try signer.signature(for: nonce)
        } catch {
            throw RelayTransportError.underlying(error)
        }
        guard signature.count == 64 else {
            // `verify_auth` does `try_into::<[u8;64]>()`; a wrong length is an
            // `InvalidSig` and therefore a silent close.
            throw RelayTransportError.handshakeFailed("signature is \(signature.count) bytes, expected 64")
        }
        try await write(.auth(signature: signature), to: socket)
        authSentAt = .now

        // 4. There is no acknowledgement. The relay registers the connection
        //    and starts routing; both reference clients declare themselves
        //    connected right here.
        authenticated = true
        continuation.yield(.connected(peer: signer.publicKey))
        drainPreAuthQueue()
    }

    /// The whole-handshake watchdog. Closing the socket is what unblocks a
    /// `performHandshake` parked on ``handshakeWaiter`` or on a write.
    private func failHandshakeIfStillPending() {
        guard !authenticated, !finished else { return }
        finish(error: .handshakeTimeout)
    }

    /// Awaits the next pre-auth frame, with its own deadline.
    ///
    /// Separate from the whole-handshake budget because the two peers enforce
    /// different numbers: the Pi gives the `challenge` 5 s
    /// (`relay_client.ts:6`) while the phone gives the whole connect 10 s. The
    /// timeout resumes the waiter itself rather than being raced in a task
    /// group — a `CheckedContinuation` is not cancellation-aware, and an
    /// abandoned one is a leak the runtime will (rightly) shout about.
    private func nextHandshakeFrame(timeout: Duration) async throws -> String {
        if !pendingPreAuth.isEmpty { return pendingPreAuth.removeFirst() }
        guard handshakeWaiter == nil else {
            throw RelayTransportError.handshakeFailed("concurrent handshake reads")
        }
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.failHandshakeWait()
        }
        defer { watchdog.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            // Safe against the watchdog firing first: this body runs
            // synchronously while the actor is still held, so the waiter is
            // installed before anything else can reach the actor.
            self.handshakeWaiter = continuation
        }
    }

    private func failHandshakeWait() {
        guard let waiter = handshakeWaiter else { return }
        handshakeWaiter = nil
        waiter.resume(throwing: RelayTransportError.handshakeTimeout)
    }

    private func drainPreAuthQueue() {
        let queued = pendingPreAuth
        pendingPreAuth = []
        for frame in queued { dispatch(frame) }
    }

    // MARK: - Reading

    private func startReceiveLoop(on socket: any WebSocketChannel) {
        receiveLoop = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let text = try await socket.receive()
                    await self?.ingest(text)
                } catch {
                    if Task.isCancelled { return }
                    await self?.handleSocketFailure(error)
                    return
                }
            }
        }
    }

    private func ingest(_ text: String) {
        lastInboundAt = .now
        if authenticated { sawInboundAfterAuth = true }

        // The relay sends exactly one JSON object per Text message, but the
        // wire is documented as JSONL and the Pi's own client splits on
        // newlines (`relay_client.ts:152-155`). Matching that costs one pass
        // and survives a proxy that coalesces frames.
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let frame = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if frame.isEmpty { continue }
            guard authenticated else {
                if let waiter = handshakeWaiter {
                    handshakeWaiter = nil
                    waiter.resume(returning: frame)
                } else {
                    pendingPreAuth.append(frame)
                }
                continue
            }
            dispatch(frame)
        }
    }

    private func dispatch(_ text: String) {
        guard let parsed = ParsedFrame(text) else {
            statistics.droppedMalformed += 1
            return
        }
        switch parsed.frame {
        case .envelope(let envelope):
            guard shouldDeliverEnvelope(senderRoom: parsed.declaredRoom, activeRoom: activeRoom) else {
                statistics.droppedByRoomDemux += 1
                return
            }
            statistics.deliveredEnvelopes += 1
            continuation.yield(.envelope(envelope))
        case .control(let frame):
            statistics.deliveredControlFrames += 1
            continuation.yield(.control(frame))
        case .unknown:
            // The relay ships independently of this client and will grow frame
            // types this build has never heard of. Dropping is correct;
            // throwing would take the socket down over a forward-compatible
            // addition.
            statistics.droppedUnknown += 1
        }
    }

    // MARK: - Writing

    public func send(_ envelope: Envelope) async throws {
        guard let socket = channel, authenticated else { throw RelayTransportError.notConnected }
        // The relay drops an oversized envelope with nothing but a `warn`: no
        // `transport_error`, no close, no ack (`peer.rs:381-384`). That silence
        // is the original "app stuck at sending… forever" bug. Fail locally,
        // and fail against the relay's own arithmetic — `ct.len() * 3 / 4` on
        // the Base64 *string*, not the real decoded size — so the two checks
        // agree exactly at the boundary.
        guard !envelope.exceedsRelayLimit() else {
            throw RelayTransportError.payloadTooLarge(estimatedBytes: envelope.relayEstimatedPayloadBytes)
        }
        // Built by hand rather than through `JSONEncoder` for one reason: this
        // object must carry **no** top-level `type` key. The relay checks for
        // one *before* it tries to parse an envelope, so a frame with a `type`
        // matches no control arm and is dropped with no error to the sender
        // (spec 02 T7). The inner message's own `type` lives inside `ct`,
        // Base64'd, where the relay cannot see it.
        let object: [String: Any] = [
            "peer": envelope.peer.wireValue,   // standard + padded; the registry key is a raw string
            "room": envelope.room.rawValue,
            "ct": envelope.ct,
        ]
        try await write(json: object, to: socket)
    }

    public func send(_ frame: ClientControlFrame) async throws {
        guard let socket = channel, authenticated else { throw RelayTransportError.notConnected }
        try await write(frame, to: socket)
    }

    /// Addresses one payload at `room` **without moving the active room**
    /// (plan 61 Phase 2).
    ///
    /// Renaming a session from Home targets whichever session the user
    /// long-pressed, and a machine-control RPC targets `ctrl` — neither is
    /// usually the chat the user is reading. Re-pointing the active room to
    /// deliver them would silently relocate the conversation, which is exactly
    /// the class of jump plan 61 exists to stop.
    public func sendToRoom(_ payload: Data, peer: PeerID, room: RoomID) async throws {
        try await send(Envelope(peer: peer, room: room, payload: payload))
    }

    /// Addresses one payload at the current active room.
    public func sendToActiveRoom(_ payload: Data, peer: PeerID) async throws {
        try await send(Envelope(peer: peer, room: activeRoom, payload: payload))
    }

    private func write(_ frame: ClientControlFrame, to socket: any WebSocketChannel) async throws {
        try await write(json: frame.jsonObject, to: socket)
    }

    private func write(json object: [String: Any], to socket: any WebSocketChannel) async throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        guard let text = String(data: data, encoding: .utf8) else {
            throw RelayTransportError.malformedFrame("frame is not UTF-8")
        }
        try await socket.send(text)
    }

    // MARK: - Room targeting

    /// Points this connection at `room`.
    ///
    /// Sets **both** the default outbound destination and the inbound demux
    /// gate — they are the same pointer, which is what makes "the current
    /// conversation" a single fact rather than two that can disagree.
    public func setActiveRoom(_ room: RoomID) async {
        activeRoom = room
    }

    public func currentActiveRoom() -> RoomID { activeRoom }

    public func currentStatistics() -> TransportStatistics { statistics }

    // MARK: - Keepalives

    private func startSocketPingLoop(on socket: any WebSocketChannel) {
        let interval = timing.socketPingInterval
        pingLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                do {
                    try await socket.sendPing()
                    // A returned Pong is proof of a full round trip, and the
                    // only inbound signal URLSession gives us on an otherwise
                    // idle connection. Without this refresh the liveness
                    // watchdog would tear down a perfectly healthy socket
                    // every 70 s whenever no one is chatting.
                    await self?.noteRoundTrip()
                } catch {
                    // A ping that cannot be sent means the socket is gone; the
                    // receive loop is about to fail too. Let it own the
                    // teardown so there is one path, not two.
                    return
                }
            }
        }
    }

    private func noteRoundTrip() {
        lastInboundAt = .now
    }

    private func startLivenessLoop() {
        let interval = timing.livenessCheckInterval
        livenessLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                await self?.checkLiveness()
            }
        }
    }

    private func checkLiveness() {
        guard !finished else { return }
        guard timing.isInboundStale(lastInboundAt: lastInboundAt, now: .now) else { return }
        // Half-open: NAT drop, laptop sleep, cellular handoff, or a proxy
        // reaping the connection without a close frame. Nothing will ever
        // arrive on this socket again and no close is coming, so the only way
        // out is to declare it dead ourselves.
        finish(error: .socketClosed(code: 0, reason: "inbound silence exceeded liveness deadline"))
    }

    // MARK: - Teardown

    public func disconnect() async {
        finish(error: nil)
    }

    private func handleSocketFailure(_ error: any Error) {
        let mapped = (error as? RelayTransportError) ?? .underlying(error)
        // The relay acknowledges nothing on a successful auth and answers
        // every auth failure with a bare `Message::Close(None)`. So a close
        // landing within a beat of our `auth`, with nothing having arrived in
        // between, is a rejected signature — not a network blip. Reporting it
        // as a plain socket drop makes the reconnect ladder spin forever on a
        // key the relay will never accept.
        if let authSentAt, !sawInboundAfterAuth,
            ContinuousClock.now - authSentAt < timing.authGracePeriod {
            finish(error: .handshakeFailed("relay closed immediately after auth — signature rejected"))
            return
        }
        finish(error: mapped)
    }

    private func finish(error: RelayTransportError?) {
        guard !finished else { return }
        finished = true
        authenticated = false

        receiveLoop?.cancel()
        pingLoop?.cancel()
        livenessLoop?.cancel()
        receiveLoop = nil
        pingLoop = nil
        livenessLoop = nil

        channel?.close()
        channel = nil

        if let waiter = handshakeWaiter {
            handshakeWaiter = nil
            waiter.resume(throwing: error ?? RelayTransportError.notConnected)
        }
        pendingPreAuth = []

        continuation.yield(.disconnected(error: error))
        continuation.finish()
    }
}

/// Counters for what the socket did with each inbound frame.
///
/// The demux and the forward-compat drops are both **silent** by design, which
/// makes them impossible to assert on from the event stream alone — absence of
/// an event is not a signal you can wait for. These counters are how a test
/// tells "dropped by the room demux" apart from "still in flight".
public struct TransportStatistics: Sendable, Hashable {
    public var deliveredEnvelopes = 0
    public var deliveredControlFrames = 0
    /// Envelopes discarded because they came from a room other than the active
    /// one (and were not the exempt `ctrl` room).
    public var droppedByRoomDemux = 0
    /// Valid JSON with a shape this build does not know.
    public var droppedUnknown = 0
    /// Not JSON at all.
    public var droppedMalformed = 0

    public init() {}
}
