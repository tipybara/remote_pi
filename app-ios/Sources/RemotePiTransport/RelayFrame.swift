import Foundation
import RemotePiProtocol

// MARK: - URL normalization

/// Normalizes a user-facing relay URL to the scheme the socket needs.
///
/// The user types (and the QR sometimes carries) `https://relay.example`, but
/// `URLSessionWebSocketTask` needs `wss://`. `http` → `ws`, `https` → `wss`;
/// an already-`ws`/`wss` URL passes through. Anything else is rejected rather
/// than guessed at.
///
/// Mirrors `toWsRelayUrl` in `app/lib/data/transport/relay_config.dart`.
public func relayWebSocketURL(from url: URL) throws -> URL {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        throw RelayTransportError.invalidRelayURL(url.absoluteString)
    }
    switch components.scheme?.lowercased() {
    case "ws", "wss":
        break
    case "http":
        components.scheme = "ws"
    case "https":
        components.scheme = "wss"
    default:
        throw RelayTransportError.invalidRelayURL(url.absoluteString)
    }
    guard let normalized = components.url else {
        throw RelayTransportError.invalidRelayURL(url.absoluteString)
    }
    return normalized
}

// MARK: - Frame classification

/// Classifies one raw text frame from the relay.
///
/// The ordering rule — envelope before control — is a correctness requirement,
/// not a style choice. `room_announced`, `rooms`, `peer_online` and
/// `transport_error` all carry a top-level `peer`, so a "check `type` first"
/// implementation would be *fine*, but a "check `peer` first" one would not:
/// the shipped Flutter client checks `peer` **and** `ct` together
/// (`ws_transport.dart:92`), which is the discriminator that actually
/// separates the two families. An envelope never carries `type` (the relay
/// would eat it as a control frame — spec 02 T7) and a control frame never
/// carries `ct`.
public enum RelayFrame: Sendable {
    case envelope(Envelope)
    case control(ControlFrame)
    /// Valid JSON the client does not understand. Drop it; do not disconnect.
    case unknown

    public static func classify(_ text: String) -> RelayFrame {
        guard let parsed = ParsedFrame(text) else { return .unknown }
        return parsed.frame
    }
}

/// One inbound text frame, parsed once.
///
/// Exists because ``RelayFrame`` alone loses a fact the demux needs: whether
/// the envelope carried a `room` **key at all**. ``Envelope``'s decoder
/// collapses "absent" into `"main"` (that is the relay's own serde default),
/// but the Flutter demux distinguishes them — a legacy sender that omits
/// `room` is routed unconditionally rather than being judged against the
/// active room (`ws_transport.dart:104`, spec 03 §4 rule 5). Against today's
/// relay the key is always present, so this only ever matters for a relay
/// older than plan 17. Keeping it costs one dictionary lookup.
struct ParsedFrame: Sendable {
    let frame: RelayFrame
    /// The literal `room` value on an envelope, or `nil` when the key is
    /// absent. Meaningless for control frames.
    let declaredRoom: RoomID?

    init?(_ text: String) {
        guard
            let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // Envelope first — see the note on `RelayFrame`.
        if object["peer"] != nil, object["ct"] != nil {
            guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
                // A `peer` that is not a 32-byte key, or a missing `ct`: the
                // relay would never emit this, so treat it as garbage rather
                // than falling through to the control parser.
                self.frame = .unknown
                self.declaredRoom = nil
                return
            }
            self.frame = .envelope(envelope)
            self.declaredRoom = (object["room"] as? String).map { RoomID($0) }
            return
        }
        if let control = ControlFrame.parse(object) {
            self.frame = .control(control)
            self.declaredRoom = nil
            return
        }
        self.frame = .unknown
        self.declaredRoom = nil
    }
}

// MARK: - Inbound room demux

/// The inbound room demux, as a pure function so it can be tested without a
/// socket.
///
/// `senderRoom` is the **sender's** room: the relay rewrites both addressing
/// fields on the way through (`relay/src/handlers/peer.rs:392-396`), so an
/// inbound envelope answers "who sent this, from which of *their* rooms".
///
/// Three rules, all load-bearing:
///
/// 1. **Room mismatch is dropped at the transport layer.** The session store
///    is a singleton keyed by the open chat, so an `agent_chunk` from a
///    session the user just left would otherwise bleed into the one they are
///    reading (`ws_transport.dart:95-101`).
/// 2. **`ctrl` is exempt** (plan 61 Phase 3). The machine gateway is not a
///    chat — it only ever answers `action_ok` / `action_error` for
///    workspace/session RPCs, so it cannot pollute conversation state. Without
///    the exemption *every* gateway reply is discarded, because the active
///    room is whichever chat happens to be open, and machine control breaks
///    entirely with no error anywhere.
/// 3. **An absent `room` routes unconditionally.** Legacy tolerance only; the
///    current relay always serializes `room` (`OuterEnvelope` has no
///    `skip_serializing_if`).
///
/// Note what is deliberately *not* here: a widened exemption list. Spec 03 T5
/// records that an `action_ok` answering a `sendToRoom` to a non-`ctrl` room
/// is dropped by this very rule and the RPC times out. Widening the exemption
/// to "everything" would reintroduce the chunk bleed rule 1 exists to prevent;
/// the fix belongs one layer up, by exempting rooms with an outstanding RPC.
public func shouldDeliverEnvelope(senderRoom: RoomID?, activeRoom: RoomID) -> Bool {
    guard let senderRoom else { return true }
    return senderRoom == activeRoom || senderRoom.isControl
}
