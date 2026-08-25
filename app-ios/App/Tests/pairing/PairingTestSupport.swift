import Foundation
import RemotePiPairing
import RemotePiProtocol
import Testing
@testable import RemotePi

// ============================================================================
// Fakes and fixtures for the pairing-screen tests.
//
// These tests exercise `PairingFlowModel`, `PairingErrorCopy`, `NicknameDraft`
// and `PasteDraft` — the four types in `App/Sources/Pairing/` that import
// neither SwiftUI nor `AppModel`. Nothing here launches a simulator, opens a
// camera, or talks to a relay.
//
// NOTE ON HOW THESE RUN: the Xcode app target has no test bundle (`project.yml`
// declares one target, and adding a second changes the CI contract, which is
// not this agent's call). They are run today through a throwaway SwiftPM
// package that compiles the five pure sources plus this directory — see the
// report. Wiring a real `RemotePiTests` target is a `project.yml` edit and
// these files then compile unchanged.
// ============================================================================

@MainActor
final class FakePairingBackend: PairingBackend {
    /// What ``pair(with:raw:)`` returns. Default is a failure so a test that
    /// forgets to arm it fails loudly rather than pairing by accident.
    var pairResult: Result<PairedMachine, any Error> = .failure(
        PairingBackendError.pairedMachineMissing
    )
    var nicknameError: (any Error)?

    private(set) var pairedPayloads: [PairingQRPayload] = []
    private(set) var pairedRaw: [String] = []
    private(set) var nicknames: [(name: String, peer: PeerID)] = []

    /// Parks ``pair(with:raw:)`` until resumed, so a test can observe the
    /// `connecting` state and try to submit a second payload into it.
    var gate: AsyncStream<Void>.Continuation?
    private var gateStream: AsyncStream<Void>?

    func holdPairing() {
        var continuation: AsyncStream<Void>.Continuation!
        gateStream = AsyncStream { continuation = $0 }
        gate = continuation
    }

    func releasePairing() {
        gate?.finish()
        gate = nil
    }

    func pair(with payload: PairingQRPayload, raw: String) async throws -> PairedMachine {
        pairedPayloads.append(payload)
        pairedRaw.append(raw)
        if let gateStream {
            for await _ in gateStream {}
            self.gateStream = nil
        }
        return try pairResult.get()
    }

    func applyNickname(_ nickname: String, to peer: PeerID) async throws {
        nicknames.append((nickname, peer))
        if let nicknameError { throw nicknameError }
    }
}

/// An actor, not a class with an unchecked conformance: ``CameraGatekeeper`` is
/// `Sendable`, and a mutable call counter behind an actor is the honest way to
/// satisfy that.
actor FakeCameraGatekeeper: CameraGatekeeper {
    private let initial: CameraGate
    private let granted: CameraGate
    private(set) var requestCount = 0

    init(initial: CameraGate, granted: CameraGate = .ready) {
        self.initial = initial
        self.granted = granted
    }

    func currentGate() async -> CameraGate { initial }

    func requestAccess() async -> CameraGate {
        requestCount += 1
        return granted
    }
}

enum PairingFixtures {
    /// 32 raw bytes, so `PeerID(base64:)` accepts it.
    static let machineKey = PeerID(rawValue: Data(repeating: 0x2A, count: 32))!
    static let otherMachineKey = PeerID(rawValue: Data(repeating: 0x7F, count: 32))!

    /// A well-formed `remotepi://pair?…` URI.
    ///
    /// Built the way `qr.ts` builds it: base64url, unpadded, `t` decoding to
    /// exactly 16 bytes and `epk` to exactly 32 — `PairingQRPayload.parse`
    /// enforces both, and a fixture that half-parses would make these tests
    /// pass for the wrong reason.
    static func qr(
        name: String = "remote_pi · main",
        peer: PeerID = machineKey,
        room: String? = "0a5f1c2e-1111-4444-8888-abcdefabcdef"
    ) -> String {
        let token = base64url(Data((0..<16).map { UInt8($0) }))
        let epk = base64url(peer.rawValue)
        var uri = "remotepi://pair?t=\(token)&epk=\(epk)&n=\(percentEncoded(name))"
        if let room { uri += "&rm=\(room)" }
        return uri
    }

    static func machine(
        peer: PeerID = machineKey,
        hostnameHint: String? = "studio.local"
    ) -> PairedMachine {
        PairedMachine(peer: peer, hostnameHint: hostnameHint, nickname: nil)
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func percentEncoded(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

@MainActor
func makeModel(
    backend: FakePairingBackend = FakePairingBackend(),
    camera: CameraGate = .ready
) -> (PairingFlowModel, FakePairingBackend) {
    let model = PairingFlowModel()
    model.bind(backend: backend, gatekeeper: FakeCameraGatekeeper(initial: camera))
    return (model, backend)
}
