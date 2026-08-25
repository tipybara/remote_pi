import Foundation
import Observation
import RemotePiProtocol
import RemotePiSession
import XCTest
@testable import RemotePi

// ============================================================================
// Fixtures for the Home tests.
//
// The whole reason `HomeBackend` exists: everything below is 120 lines of
// plain values, with no store, no socket, no simulator and no SwiftUI. The
// ordering and identity rules plan 61 exists for are asserted here, not
// eyeballed on a device.
// ============================================================================

func makePeer(_ byte: UInt8) -> PeerID {
    // Real 32 bytes — `PeerID` refuses anything else, which is exactly why the
    // Kit models a peer as bytes rather than as a Base64 string with two
    // spellings to get wrong (spec 08 §13.1).
    PeerID(rawValue: Data(repeating: byte, count: 32))!
}

let macA = makePeer(0x11)
let macB = makePeer(0x22)

func pairing(
    _ peer: PeerID,
    pairedAt: String = "2026-01-01T00:00:00Z",
    nickname: String? = nil,
    sessionName: String? = "Mac"
) -> PeerRecord {
    PeerRecord(
        peer: peer,
        relayURL: "wss://relay.example",
        pairedAt: pairedAt,
        sessionName: sessionName,
        nickname: nickname
    )
}

func meta(
    _ room: String,
    workspace: String? = nil,
    cwd: String? = nil,
    name: String? = nil,
    nameRev: Int64? = nil,
    role: String? = nil,
    model: String? = nil,
    working: Bool = false,
    startedAt: Int64 = 0
) -> RoomMeta {
    RoomMeta(
        roomID: RoomID(room),
        sessionID: SessionID(room),
        workspacePath: workspace,
        name: name,
        nameRev: nameRev,
        role: role,
        cwd: cwd ?? workspace,
        model: model,
        working: working,
        startedAt: startedAt
    )
}

func key(_ peer: PeerID, _ room: String) -> SessionKey {
    SessionKey(peer: peer, room: RoomID(room))
}

// MARK: - Fake backend

@MainActor
@Observable
final class FakeHomeBackend: HomeBackend {
    // Read model
    var isBooting = false
    var homePeers: [PeerRecord] = []
    var homeSnapshot = RegistrySnapshot()
    var isRelayConnected = true
    let preferences: AppPreferences
    var machinesAcceptingSessions: [PeerRecord] = []

    // Action results
    var localRenameSupported = true
    var renameFailure: String?
    var deleteFailure: String?
    var workspacesResult: Result<[RemoteWorkspace], any Error> = .success([])
    var requestResult: Result<SessionID, any Error> = .failure(
        HomeBackendUnavailable(capability: "test")
    )
    var waitResult = true

    // Recorded calls
    @ObservationIgnored private(set) var opened: [SessionKey] = []
    @ObservationIgnored private(set) var localNames: [(SessionKey, String?)] = []
    @ObservationIgnored private(set) var renames: [(SessionKey, String)] = []
    @ObservationIgnored private(set) var deletes: [SessionKey] = []
    @ObservationIgnored private(set) var workspaceCalls = 0
    @ObservationIgnored private(set) var requests: [CreateSessionIntent] = []
    @ObservationIgnored private(set) var waits: [SessionKey] = []

    init(defaultsSuite: String = UUID().uuidString) {
        // A throwaway suite so a test cannot inherit the developer's real
        // grouping preference, and two tests cannot see each other's writes.
        preferences = AppPreferences(defaults: UserDefaults(suiteName: defaultsSuite)!)
    }

    func isLive(_ session: SessionKey) -> Bool {
        isRelayConnected && homeSnapshot.isLive(session)
    }

    func isWorking(_ session: SessionKey) -> Bool {
        isRelayConnected && (homeSnapshot.room(session)?.working ?? false)
    }

    func presence(of session: SessionKey) -> PresenceLevel {
        .resolve(
            isWorking: isWorking(session),
            isReconnecting: !isRelayConnected,
            isLive: homeSnapshot.isLive(session)
        )
    }

    func peer(_ peer: PeerID) -> PeerRecord? {
        homePeers.first { $0.peer == peer }
    }

    func openSession(_ row: SessionRow) async {
        opened.append(row.key)
    }

    @discardableResult
    func setLocalSessionName(_ session: SessionKey, to name: String?) async -> Bool {
        localNames.append((session, name))
        return localRenameSupported
    }

    func renameSession(_ session: SessionKey, to displayName: String) async -> String? {
        renames.append((session, displayName))
        return renameFailure
    }

    func deleteCachedSession(_ session: SessionKey) async -> String? {
        deletes.append(session)
        return deleteFailure
    }

    func listWorkspaces(on machine: PeerID) async throws -> [RemoteWorkspace] {
        workspaceCalls += 1
        return try workspacesResult.get()
    }

    func requestSession(_ intent: CreateSessionIntent) async throws -> SessionID {
        requests.append(intent)
        return try requestResult.get()
    }

    func waitForSession(_ session: SessionKey, timeout: Duration) async -> Bool {
        waits.append(session)
        return waitResult
    }

    // MARK: Convenience

    /// Installs rooms for a machine and marks a subset of them live.
    func install(_ rooms: [RoomMeta], on peer: PeerID, live: [String] = []) {
        var snapshot = homeSnapshot
        snapshot.rooms[peer] = rooms.sorted { $0.roomID.rawValue < $1.roomID.rawValue }
        snapshot.live[peer] = Set(live.map { RoomID($0) })
        homeSnapshot = snapshot
    }
}

func workspace(_ id: String, path: String, name: String? = nil) -> RemoteWorkspace {
    RemoteWorkspace(
        workspaceID: WorkspaceID(id),
        path: path,
        displayName: name ?? (path.split(separator: "/").last.map(String.init) ?? path)
    )
}
