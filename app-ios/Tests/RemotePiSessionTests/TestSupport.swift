import Foundation
import XCTest

@testable import RemotePiProtocol
@testable import RemotePiSession

// MARK: - Fixtures

/// A deterministic 32-byte Ed25519 key. Real keys, because `PeerID` refuses
/// anything that is not exactly 32 bytes — the Dart tests get away with
/// `'epk_A'` only because their epk is a bare `String`.
func makePeer(_ byte: UInt8) -> PeerID {
    PeerID(rawValue: Data(repeating: byte, count: 32))!
}

let machineKey = makePeer(0x11)
let otherMachineKey = makePeer(0x22)

func pairing(_ peer: PeerID, pairedAt: String, nickname: String? = nil) -> PeerRecord {
    PeerRecord(
        peer: peer,
        relayURL: "wss://relay.example",
        pairedAt: pairedAt,
        sessionName: "Mac",
        nickname: nickname
    )
}

/// Parses a wire frame the way the transport does, then hands it to the
/// protocol parser. Going through the JSON text (rather than building a
/// `ControlFrame` by hand) is the point: it is the decoder under test.
func controlFrame(_ json: String) throws -> ControlFrame {
    let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
    let dictionary = try XCTUnwrap(object as? [String: Any])
    return try XCTUnwrap(ControlFrame.parse(dictionary))
}

/// `XCTUnwrap` with a normal parameter instead of an autoclosure, so
/// `try unwrap(await …)` compiles — `await` is not allowed inside a
/// non-async autoclosure, which is what every `XCTAssert…` takes.
func unwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}

func jsonObject(_ data: Data) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: data)
    return try XCTUnwrap(object as? [String: Any])
}

/// `NSDictionary` comparison, so key order and Swift's lack of `[String: Any]`
/// equality do not get in the way.
func assertJSONEqual(
    _ actual: [String: Any],
    _ expected: [String: Any],
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(
        actual as NSDictionary,
        expected as NSDictionary,
        file: file,
        line: line
    )
}

/// Polls until `condition` holds. The coordinator consumes transport events on
/// its own task, so a test cannot assert synchronously after feeding one.
func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: @Sendable () async -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(2))
    }
    XCTFail("condition never became true", file: file, line: line)
}

// MARK: - Fake transport

/// In-memory ``RelayTransport``. Records what the client sent and lets a test
/// push relay frames back.
final class FakeTransport: RelayTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _controlFrames: [ClientControlFrame] = []
    private var _envelopes: [Envelope] = []
    private var _sendError: (any Error)?

    let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation

    init() {
        let stream = AsyncStream<TransportEvent>.makeStream()
        events = stream.stream
        continuation = stream.continuation
    }

    var controlFrames: [ClientControlFrame] {
        lock.withLock { _controlFrames }
    }

    var envelopes: [Envelope] {
        lock.withLock { _envelopes }
    }

    func failSends(with error: any Error) {
        lock.withLock { _sendError = error }
    }

    func connect(to relayURL: URL, as signer: any Signer) async throws {}

    func send(_ envelope: Envelope) async throws {
        if let error = lock.withLock({ _sendError }) { throw error }
        lock.withLock { _envelopes.append(envelope) }
    }

    func send(_ frame: ClientControlFrame) async throws {
        if let error = lock.withLock({ _sendError }) { throw error }
        lock.withLock { _controlFrames.append(frame) }
    }

    func disconnect() async {
        continuation.finish()
    }

    // Test-side pushes.

    func emit(_ event: TransportEvent) {
        continuation.yield(event)
    }

    /// Delivers an inner frame as the relay would: the envelope header names
    /// the **sender** and the sender's room, because the relay rewrites both on
    /// the way through.
    func deliverInner(from peer: PeerID, room: RoomID, json: String) {
        emit(.envelope(Envelope(peer: peer, room: room, payload: Data(json.utf8))))
    }
}

// MARK: - Fake store

final class FakeStore: SessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var rooms: [PeerID: [RoomMeta]] = [:]
    private var selected: SessionKey?

    init(rooms: [PeerID: [RoomMeta]] = [:], selected: SessionKey? = nil) {
        self.rooms = rooms
        self.selected = selected
    }

    var savedRooms: [PeerID: [RoomMeta]] { lock.withLock { rooms } }
    var savedSelection: SessionKey? { lock.withLock { selected } }

    func loadPeers() async throws -> [PeerRecord] { [] }
    func savePeer(_ record: PeerRecord) async throws {}
    func deletePeer(_ peer: PeerID) async throws {}

    func loadRooms(for peer: PeerID) async throws -> [RoomMeta] {
        lock.withLock { rooms[peer] ?? [] }
    }

    func saveRooms(_ rooms: [RoomMeta], for peer: PeerID) async throws {
        lock.withLock { self.rooms[peer] = rooms }
    }

    func loadMessages(for session: SessionKey, limit: Int) async throws -> [StoredMessage] { [] }
    func appendMessage(_ message: StoredMessage, for session: SessionKey) async throws {}
    func replaceMessages(_ messages: [StoredMessage], for session: SessionKey) async throws {}
    func deleteMessages(for session: SessionKey) async throws {}

    func loadSelectedSession() async throws -> SessionKey? { lock.withLock { selected } }
    func saveSelectedSession(_ session: SessionKey?) async throws {
        lock.withLock { selected = session }
    }
}
