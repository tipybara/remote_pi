import Foundation
import RemotePiProtocol

@testable import RemotePiPairing

// Test doubles shared by the pairing tests. Deliberately dumb: every
// assertion about behaviour lives in a test, not in here.

/// A relay socket whose inbound side the test drives frame by frame.
final class FakeRelayTransport: RelayTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _sentEnvelopes: [Envelope] = []
    private var _sentControl: [ClientControlFrame] = []
    private var _connectedTo: URL?
    private var _connectedAs: PeerID?
    private let continuation: AsyncStream<TransportEvent>.Continuation
    let events: AsyncStream<TransportEvent>

    /// When set, `connect` throws this instead of succeeding.
    var connectError: (any Error)?
    /// Called on every outbound envelope — the seam a test uses to play the
    /// Pi's side, the way the Dart suite's `_MemTransport` responder does.
    var onEnvelope: (@Sendable (Envelope) -> Void)?

    init() {
        let (stream, continuation) = AsyncStream<TransportEvent>.makeStream()
        self.events = stream
        self.continuation = continuation
    }

    var sentEnvelopes: [Envelope] {
        lock.lock(); defer { lock.unlock() }
        return _sentEnvelopes
    }

    var sentControl: [ClientControlFrame] {
        lock.lock(); defer { lock.unlock() }
        return _sentControl
    }

    var connectedAs: PeerID? {
        lock.lock(); defer { lock.unlock() }
        return _connectedAs
    }

    var connectedTo: URL? {
        lock.lock(); defer { lock.unlock() }
        return _connectedTo
    }

    func connect(to relayURL: URL, as signer: any Signer) async throws {
        if let connectError { throw connectError }
        // `withLock` rather than lock()/unlock(): the bare calls are `noasync`.
        lock.withLock {
            _connectedTo = relayURL
            _connectedAs = signer.publicKey
        }
        continuation.yield(.connected(peer: signer.publicKey))
    }

    func send(_ envelope: Envelope) async throws {
        let responder = lock.withLock { () -> (@Sendable (Envelope) -> Void)? in
            _sentEnvelopes.append(envelope)
            return onEnvelope
        }
        responder?(envelope)
    }

    func send(_ frame: ClientControlFrame) async throws {
        lock.withLock { _sentControl.append(frame) }
    }

    func disconnect() async {
        continuation.finish()
    }

    // MARK: - Driving the inbound side

    func deliver(_ event: TransportEvent) {
        continuation.yield(event)
    }

    /// Delivers an inner frame the way the relay would: `peer` and `room`
    /// rewritten to the **sender**.
    func deliverInner(_ json: [String: Any], from peer: PeerID, room: RoomID) {
        let payload = try! JSONSerialization.data(withJSONObject: json)
        continuation.yield(.envelope(Envelope(peer: peer, room: room, payload: payload)))
    }

    /// Delivers a control frame from its literal relay JSON, so the test pins
    /// the relay's own wording rather than our constructor.
    func deliverControl(_ json: [String: Any]) {
        guard let frame = ControlFrame.parse(json) else {
            preconditionFailure("test fixture is not a control frame: \(json)")
        }
        continuation.yield(.control(frame))
    }
}

/// Minimal `SessionStore` — only the peer/room half is exercised here.
actor InMemorySessionStore: SessionStore {
    private(set) var peers: [PeerID: PeerRecord] = [:]
    private(set) var rooms: [PeerID: [RoomMeta]] = [:]
    private var messages: [String: [StoredMessage]] = [:]
    private var selected: SessionKey?

    init(peers: [PeerRecord] = []) {
        for peer in peers { self.peers[peer.peer] = peer }
    }

    func loadPeers() async throws -> [PeerRecord] {
        // Stable order so assertions do not depend on dictionary iteration.
        peers.values.sorted { $0.peer.wireValue < $1.peer.wireValue }
    }

    func savePeer(_ record: PeerRecord) async throws {
        peers[record.peer] = record
    }

    func deletePeer(_ peer: PeerID) async throws {
        peers[peer] = nil
    }

    func loadRooms(for peer: PeerID) async throws -> [RoomMeta] {
        rooms[peer] ?? []
    }

    func saveRooms(_ rooms: [RoomMeta], for peer: PeerID) async throws {
        self.rooms[peer] = rooms
    }

    func loadMessages(for session: SessionKey, limit: Int) async throws -> [StoredMessage] {
        Array((messages[session.storageKey] ?? []).suffix(limit))
    }

    func appendMessage(_ message: StoredMessage, for session: SessionKey) async throws {
        messages[session.storageKey, default: []].append(message)
    }

    func replaceMessages(_ messages: [StoredMessage], for session: SessionKey) async throws {
        self.messages[session.storageKey] = messages
    }

    func deleteMessages(for session: SessionKey) async throws {
        messages[session.storageKey] = nil
    }

    func loadSelectedSession() async throws -> SessionKey? { selected }

    func saveSelectedSession(_ session: SessionKey?) async throws { selected = session }
}

/// Canned HTTP for the mesh endpoints.
final class FakeMeshHTTP: MeshHTTPClient, @unchecked Sendable {
    struct Response {
        var status: Int
        var body: Data

        static func json(_ status: Int, _ object: [String: Any]) -> Response {
            Response(status: status, body: try! JSONSerialization.data(withJSONObject: object))
        }

        /// The relay's 4xx bodies are `text/plain`.
        static func text(_ status: Int, _ body: String) -> Response {
            Response(status: status, body: Data(body.utf8))
        }
    }

    private let lock = NSLock()
    private var queued: [Response] = []
    private var _requests: [URLRequest] = []
    /// Runs before each response is handed back — lets a test observe
    /// interleaving.
    var onRequest: (@Sendable (URLRequest) async -> Void)?

    init(_ responses: [Response] = []) {
        queued = responses
    }

    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    func enqueue(_ response: Response) {
        lock.lock(); defer { lock.unlock() }
        queued.append(response)
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        // Recorded before the hook runs: a hook that blocks is exactly how a
        // test holds a request in flight, and it still needs to see it.
        let response = lock.withLock { () -> Response in
            _requests.append(request)
            return queued.isEmpty ? Response.text(500, "internal") : queued.removeFirst()
        }
        await onRequest?(request)
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (response.body, http)
    }
}

// MARK: - Fixtures

enum Fixture {
    /// Deterministic 32-byte keys, so a failure prints the same bytes twice.
    static func key(_ seed: UInt8) -> PeerID {
        PeerID(rawValue: Data((0..<32).map { UInt8(($0 &* 7 &+ Int(seed)) & 0xFF) }))!
    }

    static func ownerSeed(_ seed: UInt8) -> Data {
        Data((0..<32).map { UInt8(($0 &* 5 &+ Int(seed)) & 0xFF) })
    }
}
