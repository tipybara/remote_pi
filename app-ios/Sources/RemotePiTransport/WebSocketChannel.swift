import Foundation
import RemotePiProtocol

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The one-frame-at-a-time WebSocket the relay connection sits on.
///
/// Exists so ``RelayWebSocketTransport`` can be exercised without a network.
/// Everything above this seam — the handshake, the demux, the watchdogs — is
/// the part that has broken in production; none of it should need a live relay
/// to test.
///
/// Text only. The relay drops Binary frames (`relay/src/handlers/peer.rs:198`)
/// and this client has no use for them.
public protocol WebSocketChannel: Sendable {
    /// Sends one frame. The relay reads JSONL and never accepts a batch, so
    /// one call is one JSON object.
    func send(_ text: String) async throws

    /// Awaits the next inbound frame. Throws ``RelayTransportError/socketClosed(code:reason:)``
    /// when the socket ends.
    func receive() async throws -> String

    /// Sends an RFC 6455 Ping and returns when the Pong comes back.
    ///
    /// The round trip is the point: it is the only liveness evidence
    /// `URLSessionWebSocketTask` gives us, since it never surfaces the relay's
    /// own inbound Pings. See ``TransportTiming/isInboundStale(lastInboundAt:now:)``.
    func sendPing() async throws

    /// Closes the socket. Idempotent.
    func close()
}

/// Opens a channel to an already-normalized `ws://` / `wss://` URL.
public typealias WebSocketChannelFactory = @Sendable (URL) throws -> any WebSocketChannel

// MARK: - URLSession implementation

/// ``WebSocketChannel`` over `URLSessionWebSocketTask`.
///
/// `URLSessionWebSocketTask` is documented as safe to call from any thread and
/// holds its own queue, so this wrapper stores it directly rather than putting
/// an actor in front of every frame. The `@unchecked` is about that promise,
/// not about a lock we forgot.
public final class URLSessionWebSocketChannel: WebSocketChannel, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    public init(url: URL, session: URLSession = .shared) {
        self.task = session.webSocketTask(with: url)
        task.resume()
    }

    /// The factory to hand to ``RelayWebSocketTransport`` in production.
    public static let factory: WebSocketChannelFactory = { url in
        URLSessionWebSocketChannel(url: url)
    }

    public func send(_ text: String) async throws {
        do {
            try await task.send(.string(text))
        } catch {
            throw Self.mapped(error, task: task)
        }
    }

    public func receive() async throws -> String {
        let message: URLSessionWebSocketTask.Message
        do {
            message = try await task.receive()
        } catch {
            throw Self.mapped(error, task: task)
        }
        switch message {
        case .string(let text):
            return text
        case .data(let data):
            // The relay never sends Binary. If a proxy repackages a text frame
            // as binary, reading it as UTF-8 is still the right answer;
            // dropping it would silently lose a real message.
            guard let text = String(data: data, encoding: .utf8) else {
                throw RelayTransportError.malformedFrame("binary frame is not UTF-8")
            }
            return text
        @unknown default:
            throw RelayTransportError.malformedFrame("unknown WebSocket message case")
        }
    }

    public func sendPing() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            task.sendPing { error in
                if let error {
                    continuation.resume(throwing: RelayTransportError.underlying(error))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    public func close() {
        task.cancel(with: .goingAway, reason: nil)
    }

    /// Turns a URLSession failure into the taxonomy the rest of the app knows.
    ///
    /// The relay's entire auth failure path is an unadorned close with no
    /// frame (spec 03 §1.6), so `closeCode` is very often `.invalid` and the
    /// reason is `nil`. Carrying the raw code anyway lets a caller tell a
    /// server-initiated close from a local cancellation.
    private static func mapped(_ error: any Error, task: URLSessionWebSocketTask) -> RelayTransportError {
        let code = task.closeCode
        if code != .invalid {
            let reason = task.closeReason.flatMap { String(data: $0, encoding: .utf8) }
            return .socketClosed(code: code.rawValue, reason: reason)
        }
        return .underlying(error)
    }
}
