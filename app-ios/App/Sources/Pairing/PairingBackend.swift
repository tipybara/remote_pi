import Foundation
import RemotePiPairing
import RemotePiProtocol

/// Everything the pairing screen needs the app to actually *do*.
///
/// Two methods, both of which run the real thing:
///
/// * ``pair(with:raw:)`` drives `RemotePiPairing.PairingCoordinator` — the
///   handshake is **not** reimplemented here. The sequence (disconnect the
///   live socket, load the Owner key, `pair_request` addressed to the QR's
///   `(epk, rm)`, await `pair_ok` under a 30 s budget, adopt the socket,
///   publish `mesh_versions`) all lives in the Kit and is already covered by
///   `Tests/RemotePiPairingTests`.
/// * ``applyNickname(_:to:)`` persists the label the post-pair sheet produced.
///
/// It is a protocol because the composition root (`AppModel`) cannot be
/// constructed in a test process, and because the screen must not be allowed
/// to reach past `AppModel` into the Kit — `ScreenModel`'s rules, and the
/// reason `SessionCoordinator` is private to `AppModel`.
@MainActor
protocol PairingBackend: AnyObject {
    /// Runs one pairing to completion. Throws ``RemotePiPairing/PairFailure``
    /// when it can, so §6.3's copy table applies; anything else is wrapped in
    /// ``PairingBackendError``.
    ///
    /// - Parameters:
    ///   - payload: the parsed QR. Parsed by the *model*, before the scanner is
    ///     disarmed, so an unparseable frame never stops the camera.
    ///   - raw: the original string, because today's `AppModel.pair` takes the
    ///     text rather than the payload. Removing this parameter is part of the
    ///     `pairDetailed` request in this task's report.
    func pair(with payload: PairingQRPayload, raw: String) async throws -> PairedMachine

    /// Writes a nickname onto an already-paired machine.
    ///
    /// Never called with an empty or whitespace-only string — the sheet's
    /// return contract (§6.4) resolves that to the placeholder or to `nil`
    /// before it gets here.
    func applyNickname(_ nickname: String, to peer: PeerID) async throws
}

/// A failure the backend could only describe as a string.
///
/// Exists so ``PairingErrorCopy`` has something better than
/// `localizedDescription` to work with while `AppModel.pair` still swallows
/// its typed `PairFailure` into `lastError`. When `AppModel` grows
/// `pairDetailed(payload:) throws -> PairingOutcome`, this type stops being
/// produced by the adapter and §6.3's table lights up with no change to the
/// model or to this file.
enum PairingBackendError: Error, Equatable {
    /// The app reported a failure but only as prose.
    case reported(String)
    /// The app finished without reporting an error and without producing the
    /// machine we asked for. A silent no-op is a bug somewhere upstream, and
    /// the user still needs a screen that says something.
    case pairedMachineMissing

    var userMessage: String {
        switch self {
        case .reported(let message):
            message.isEmpty ? "Pairing failed" : message
        case .pairedMachineMissing:
            "Pairing didn't complete — try again"
        }
    }
}
