import Foundation
import RemotePiProtocol

// The pair frames themselves — `PairRequest`, `PairOk`, `PairError`,
// `PairErrorCode`, `PiHarness` — live in `RemotePiProtocol` with the rest of
// the wire vocabulary. This file adds only what pairing needs on top of them:
// the room-precedence rule, the seed for the room cache, and one classifier
// for the frames that can arrive while a pairing is in flight.

extension PairOk {
    /// Room precedence, spelled out: `pair_ok.room_id` → the QR's `rm` →
    /// ``RoomID/main``.
    ///
    /// Trap T5. `roomID` is not enough on its own, because the decoder
    /// substitutes ``RoomID/main`` for an absent `room_id` — exactly as the
    /// Flutter decoder does (`protocol.dart:1311`), which then re-reads the raw
    /// map to tell the two apart (`pair_request_flow.dart:131-135`).
    /// ``PairOk/roomIDWasOmitted`` carries that distinction, and this is the
    /// only place that is allowed to resolve it.
    ///
    /// Getting it wrong stores `"main"` as the machine's room and addresses
    /// every later frame to a room only the phone lives in — the relay's
    /// lookup is an exact `(peer, room)` match with no fallback.
    public func resolvedRoom(qrRoom: RoomID?) -> RoomID {
        roomIDWasOmitted ? (qrRoom ?? .main) : roomID
    }

    /// Seeds the room cache from the very first frame.
    ///
    /// The Flutter client drops `session_id`, `workspace_path`, `display_name`
    /// and `name_rev` here and recovers them from a later `room_announced`
    /// (spec 62/04 §12 D2). Keeping them means a freshly paired machine is
    /// keyed by session immediately, which is the whole point of plan 61.
    ///
    /// `working` is false and `startedAt` is 0 deliberately: neither is carried
    /// by `pair_ok`, and `started_at` in room meta is the **relay's**
    /// registration instant — a different clock from `session_started_at`,
    /// which is the Pi *process* start and is `0` on a legacy Pi (trap T10).
    public func roomMeta(qrRoom: RoomID?) -> RoomMeta {
        RoomMeta(
            roomID: resolvedRoom(qrRoom: qrRoom),
            sessionID: sessionID,
            workspacePath: workspacePath,
            name: displayName ?? (sessionName.isEmpty ? nil : sessionName),
            nameRev: nameRev,
            role: nil,
            cwd: workspacePath,
            model: nil,
            thinking: nil,
            working: false,
            startedAt: 0
        )
    }

    /// The Pi process start, with the legacy sentinel folded away.
    ///
    /// `0` means *unknown* (`protocol.dart:1290-1294`). Restart detection only:
    /// never an ordering key, never identity.
    public var knownSessionStartedAt: Int64? {
        sessionStartedAt > 0 ? sessionStartedAt : nil
    }
}

/// What the phone can find inside a `ct` while a pairing is in flight.
///
/// Narrower than ``ServerMessage`` on purpose: during pairing there is exactly
/// one frame worth acting on, one worth failing on, and one — `unknown_peer` —
/// that means something different from both.
public enum InnerPairFrame: Hashable, Sendable {
    case pairOk(PairOk)
    case pairError(PairError)
    /// `{"type":"error","code":"unknown_peer","message":"Peer not paired — re-scan QR"}`
    /// (`index.ts:1919-1927`). Not a pairing failure: it means the Owner is not
    /// (or no longer) in the machine's `peers.json`. It is also the only
    /// positive confirmation the protocol gives that a revoke landed — the Pi
    /// sends no revocation frame of its own (spec 62/06 §8.4).
    case unknownPeer(message: String)
    /// Anything else on the socket. The pairing inbound queue is unfiltered
    /// (trap T8), so ordinary chat traffic and frames for other requests land
    /// here as a matter of course — not as an error.
    case other(type: String?)

    public static func classify(_ payload: Data) -> InnerPairFrame {
        guard let message = try? JSONDecoder().decode(ServerMessage.self, from: payload) else {
            // Undecodable is `other`, never a throw: one malformed frame from
            // any peer on this socket must not fail the pairing.
            return .other(type: nil)
        }
        switch message {
        case .pairOk(let ok):
            return .pairOk(ok)
        case .pairError(let error):
            return .pairError(error)
        case .error(let error) where error.code.indicatesRevokedPairing:
            return .unknownPeer(message: error.message)
        default:
            return .other(type: message.typeName)
        }
    }
}

/// Every way pairing can fail, wire and local, on one surface.
public enum PairFailure: Error, Hashable, Sendable {
    /// A `pair_error` frame.
    ///
    /// `code` is an open union (``PairErrorCode`` is a wrapped `String`, not a
    /// closed enum) and `message` is a developer string: the UI maps the codes
    /// it knows to its own copy and falls back to `message` for the rest
    /// (`pairing_viewmodel.dart:135-141`).
    case wire(code: PairErrorCode, message: String)

    /// A `transport_error` control frame from the relay: the `(peer, room)` we
    /// addressed has no live connection (`peer.rs:428-440`, plan 61 Phase 3).
    ///
    /// During pairing this means the QR's `rm` is stale — the Pi restarted, was
    /// renamed into a new session, or the daemon re-spawned it. It arrives
    /// within one RTT; there is nothing to wait for.
    case transportOffline(peer: PeerID, room: RoomID, reason: String)

    /// A legacy QR carrying `r=` that points at a different relay than the one
    /// the app is configured for (`pair_request_flow.dart:80-89`). Local only —
    /// never a wire code.
    case relayMismatch(qr: String, configured: String)

    /// No reply at all. Local only — and note there is no "is this token still
    /// valid?" probe in the protocol: a client only learns a token expired by
    /// spending it.
    case timedOut

    /// The Pi answered `unknown_peer` — this Owner is not in its `peers.json`.
    case unknownPeer(message: String)

    /// The socket died mid-pairing.
    case disconnected(reason: String?)
}
