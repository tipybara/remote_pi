import Foundation
import RemotePiCrypto
import RemotePiProtocol
import XCTest

@testable import RemotePiTransport

// MARK: - Fake socket

/// An in-memory ``WebSocketChannel``.
///
/// A lock-guarded class rather than an actor because ``WebSocketChannel/close()``
/// is synchronous — the transport closes the socket from inside its own
/// teardown, where there is nothing to await on.
final class FakeWebSocketChannel: WebSocketChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var inbound: [String] = []
    private var waiters: [CheckedContinuation<String, any Error>] = []
    private var sentFrames: [String] = []
    private var isClosed = false
    private var pings = 0
    private var autoReply: [String] = []
    private var sendError: (any Error)?
    private var pingError: (any Error)?

    /// Frames the fake will push the moment it receives a `hello`.
    ///
    /// Modelled on the relay, which answers `hello` with exactly one
    /// `challenge` and nothing else — there is no auth acknowledgement.
    func replyToHello(with frames: [String]) {
        lock.lock(); defer { lock.unlock() }
        autoReply = frames
    }

    func failSends(with error: any Error) {
        lock.lock(); defer { lock.unlock() }
        sendError = error
    }

    func failPings(with error: any Error) {
        lock.lock(); defer { lock.unlock() }
        pingError = error
    }

    var sent: [String] {
        lock.lock(); defer { lock.unlock() }
        return sentFrames
    }

    var pingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pings
    }

    var closed: Bool {
        lock.lock(); defer { lock.unlock() }
        return isClosed
    }

    /// Frames the client sent, parsed. Order preserved.
    var sentObjects: [[String: Any]] {
        sent.compactMap {
            guard let data = $0.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
    }

    func sentObjects(ofType type: String) -> [[String: Any]] {
        sentObjects.filter { ($0["type"] as? String) == type }
    }

    // MARK: WebSocketChannel

    func send(_ text: String) async throws {
        var pending: [String] = []
        try lock.withLock {
            if let sendError { throw sendError }
            if isClosed { throw RelayTransportError.notConnected }
            sentFrames.append(text)
            if text.contains("\"hello\""), !autoReply.isEmpty {
                pending = autoReply
                autoReply = []
            }
        }
        for frame in pending { push(frame) }
    }

    func receive() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !inbound.isEmpty {
                let next = inbound.removeFirst()
                lock.unlock()
                continuation.resume(returning: next)
                return
            }
            if isClosed {
                lock.unlock()
                continuation.resume(throwing: RelayTransportError.socketClosed(code: 1000, reason: nil))
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func sendPing() async throws {
        try lock.withLock {
            if let pingError { throw pingError }
            if isClosed { throw RelayTransportError.notConnected }
            pings += 1
        }
    }

    func close() {
        closeFromServer(error: RelayTransportError.socketClosed(code: 1000, reason: nil))
    }

    // MARK: Server side

    /// Pushes one frame at the client, as the relay would.
    func push(_ text: String) {
        var waiter: CheckedContinuation<String, any Error>?
        lock.withLock {
            if waiters.isEmpty {
                inbound.append(text)
            } else {
                waiter = waiters.removeFirst()
            }
        }
        waiter?.resume(returning: text)
    }

    /// Drops the socket the way a relay close or a network failure would.
    func closeFromServer(error: any Error = RelayTransportError.socketClosed(code: 1006, reason: nil)) {
        var pending: [CheckedContinuation<String, any Error>] = []
        lock.withLock {
            guard !isClosed else { return }
            isClosed = true
            pending = waiters
            waiters = []
        }
        for waiter in pending { waiter.resume(throwing: error) }
    }
}

// MARK: - Event recording

/// Drains an `AsyncStream` into an array a test can poll.
actor EventRecorder<Element: Sendable> {
    private(set) var events: [Element] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<Element>) {
        Task { await self.start(stream) }
    }

    private func start(_ stream: AsyncStream<Element>) {
        task = Task { [weak self] in
            for await event in stream { await self?.append(event) }
        }
    }

    private func append(_ event: Element) { events.append(event) }

    func snapshot() -> [Element] { events }
    func count() -> Int { events.count }
    func stop() { task?.cancel() }
}

// MARK: - Polling

/// Waits for `condition`, polling. Returns `false` on timeout.
@discardableResult
func waitUntil(
    timeout: Duration = .seconds(3),
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(4))
    }
    return await condition()
}

// MARK: - Fixtures

enum Fixture {
    /// A deterministic Ed25519 identity, so a test can assert an exact
    /// `pubkey` string on the wire.
    static func signer(seedByte: UInt8 = 0x11) throws -> Ed25519Signer {
        try Ed25519Signer(seed: Data(repeating: seedByte, count: 32))
    }

    /// A 32-byte key that is not ours — stands in for the Mac's Pi-key.
    static let piKey = PeerID(rawValue: Data(repeating: 0xFB, count: 32))!

    /// Standard, padded — the only spelling the relay's registry understands.
    static var piKeyWire: String { piKey.wireValue }

    /// A challenge nonce in the relay's own encoding: 32 random-looking bytes,
    /// STANDARD Base64, padded — 44 characters ending in `=`
    /// (`relay/src/auth/challenge.rs:46-51`).
    static let nonceBytes = Data((0..<32).map { UInt8($0 &* 7 &+ 3) })
    static var nonceBase64: String { nonceBytes.base64EncodedString() }
    static var challengeFrame: String { #"{"type":"challenge","nonce":"\#(nonceBase64)"}"# }

    /// Timings small enough that the ladders and watchdogs run inside a test.
    static var fastTiming: TransportTiming {
        TransportTiming(
            challengeTimeout: .milliseconds(300),
            handshakeTimeout: .milliseconds(500),
            authGracePeriod: .milliseconds(1),
            socketPingInterval: .milliseconds(20),
            innerPingInterval: .milliseconds(20),
            missedPingsBeforeRoomOffline: 3,
            livenessTimeout: .milliseconds(120),
            livenessCheckInterval: .milliseconds(20),
            stuckOfflineWatchdogInterval: .seconds(30),
            backoffLadder: [.milliseconds(10), .milliseconds(20)]
        )
    }

    static let relayURL = URL(string: "https://relay-rp1.jacobmoura.work")!

    /// Opens a fake socket and runs the real handshake over it.
    static func connectedTransport(
        timing: TransportTiming = TransportTiming(),
        seedByte: UInt8 = 0x11,
        extraHelloReplies: [String] = []
    ) async throws -> (RelayWebSocketTransport, FakeWebSocketChannel, Ed25519Signer) {
        let socket = FakeWebSocketChannel()
        socket.replyToHello(with: [challengeFrame] + extraHelloReplies)
        let transport = RelayWebSocketTransport(
            channelFactory: { _ in socket },
            timing: timing
        )
        let signer = try Fixture.signer(seedByte: seedByte)
        try await transport.connect(to: relayURL, as: signer)
        return (transport, socket, signer)
    }
}

// MARK: - Assertions that tolerate `await`

// XCTest's macros take autoclosures, and an autoclosure cannot contain
// `await`. These thin wrappers take plain values instead, so a test can write
// `expectEqual(await actor.value(), x)`.

func expectEqual<T: Equatable>(
    _ actual: T, _ expected: T, _ message: String = "",
    file: StaticString = #filePath, line: UInt = #line
) {
    XCTAssertEqual(actual, expected, message, file: file, line: line)
}

func expectTrue(
    _ value: Bool, _ message: String = "",
    file: StaticString = #filePath, line: UInt = #line
) {
    XCTAssertTrue(value, message, file: file, line: line)
}

func expectFalse(
    _ value: Bool, _ message: String = "",
    file: StaticString = #filePath, line: UInt = #line
) {
    XCTAssertFalse(value, message, file: file, line: line)
}

func expectGreaterThan<T: Comparable>(
    _ lhs: T, _ rhs: T, _ message: String = "",
    file: StaticString = #filePath, line: UInt = #line
) {
    XCTAssertGreaterThan(lhs, rhs, message, file: file, line: line)
}

/// Polls `condition` and fails the test if it never becomes true.
func expectEventually(
    timeout: Duration = .seconds(3),
    _ message: String = "condition never became true",
    file: StaticString = #filePath, line: UInt = #line,
    _ condition: @Sendable () async -> Bool
) async {
    let satisfied = await waitUntil(timeout: timeout, condition)
    XCTAssertTrue(satisfied, message, file: file, line: line)
}
