import Foundation
import RemotePiProtocol
import RemotePiTransport

/// Presents ``RelayConnectionManager`` as the ``RelayTransport`` seam.
///
/// The manager owns backoff and subscription replay across disconnects. This
/// type keeps one long-lived ``events`` stream so ``SessionCoordinator``
/// stays attached: a transient drop yields ``TransportEvent/disconnected``
/// without finishing the stream, and the next online yields ``connected``.
actor ManagedRelayTransport: RelayTransport {
    nonisolated let events: AsyncStream<TransportEvent>
    private nonisolated let continuation: AsyncStream<TransportEvent>.Continuation

    let manager: RelayConnectionManager
    private var remotePeer: PeerID
    private var preferredRoom: RoomID?
    private var pump: Task<Void, Never>?
    private var connectWaiter: CheckedContinuation<Void, any Error>?
    private let onStatus: @Sendable (RelayConnectionManager.Status) -> Void

    init(
        manager: RelayConnectionManager,
        remotePeer: PeerID,
        preferredRoom: RoomID? = nil,
        onStatus: @escaping @Sendable (RelayConnectionManager.Status) -> Void
    ) {
        self.manager = manager
        self.remotePeer = remotePeer
        self.preferredRoom = preferredRoom
        self.onStatus = onStatus
        let stream = AsyncStream<TransportEvent>.makeStream()
        self.events = stream.stream
        self.continuation = stream.continuation
    }

    func connect(to relayURL: URL, as signer: any Signer) async throws {
        startPump()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connectWaiter = continuation
            Task {
                await manager.start(
                    relayURL: relayURL,
                    signer: signer,
                    remotePeer: remotePeer,
                    preferredRoom: preferredRoom
                )
            }
        }
    }

    func send(_ envelope: Envelope) async throws {
        guard let payload = envelope.payload else {
            throw RelayTransportError.malformedFrame("envelope had no payload")
        }
        try await manager.send(payload, to: envelope.peer, room: envelope.room)
    }

    func send(_ frame: ClientControlFrame) async throws {
        try await manager.send(frame)
    }

    func disconnect() async {
        connectWaiter?.resume(throwing: CancellationError())
        connectWaiter = nil
        await manager.stop()
        pump?.cancel()
        pump = nil
        continuation.finish()
    }

    func setActiveRoom(_ room: RoomID) async {
        preferredRoom = room
        await manager.setActiveRoom(room, owner: remotePeer, pinned: true)
    }

    func retarget(peer: PeerID, room: RoomID) async {
        remotePeer = peer
        preferredRoom = room
        await manager.setActiveRoom(room, owner: peer, pinned: true)
    }

    private func startPump() {
        guard pump == nil else { return }
        pump = Task { [weak self] in
            guard let self else { return }
            let stream = manager.events
            for await event in stream {
                await self.forward(event)
            }
        }
    }

    private func forward(_ event: RelayConnectionManager.Event) {
        switch event {
        case .status(let status):
            onStatus(status)
            switch status {
            case .online:
                continuation.yield(.connected(peer: remotePeer))
                if let waiter = connectWaiter {
                    connectWaiter = nil
                    waiter.resume()
                }
            case .offline(let reason, let canRetry):
                continuation.yield(
                    .disconnected(error: .socketClosed(code: 0, reason: reason))
                )
                if !canRetry, let waiter = connectWaiter {
                    connectWaiter = nil
                    waiter.resume(throwing: RelayTransportError.handshakeFailed(reason))
                }
            case .retrying:
                continuation.yield(
                    .disconnected(error: .socketClosed(code: 0, reason: "retrying"))
                )
            case .idle, .connecting:
                break
            }
        case .envelope(let envelope):
            continuation.yield(.envelope(envelope))
        case .control(let frame):
            continuation.yield(.control(frame))
        case .liveRoomsChanged:
            break
        }
    }
}
