import Foundation
import RemotePiPairing
import RemotePiProtocol

/// The user-visible copy for every way a pairing can fail (spec 08 §6.3).
///
/// The first four rows are **verbatim** from `pairing_viewmodel.dart:135-141`
/// and must stay that way: they are the strings support answers questions
/// about, and half of them tell the user which command to re-run.
///
/// | code | message |
/// |---|---|
/// | `token_expired`  | QR expired — generate a new one on your Mac |
/// | `token_consumed` | QR already used — generate a new one |
/// | `token_unknown`  | QR not recognized by Mac — re-run /remote-pi pair |
/// | `pair_timeout`   | Timed out — make sure /remote-pi is running on your Mac |
/// | other            | `e.message` or `e.code` |
///
/// The Swift Kit surfaces failures the Dart client never modelled — a
/// `transport_error` control frame, a relay mismatch, a mid-pairing socket
/// drop — which in Dart all collapsed into the "other" row and reached the
/// user as a Dart exception's `toString()`. Those get real copy here; each one
/// is marked with why it exists and what the user is supposed to do about it.
enum PairingErrorCopy {
    // The four strings the table names, hoisted so a test can assert on the
    // same constant the UI renders rather than on a re-typed literal.
    static let tokenExpired = "QR expired — generate a new one on your Mac"
    static let tokenConsumed = "QR already used — generate a new one"
    static let tokenUnknown = "QR not recognized by Mac — re-run /remote-pi pair"
    static let timedOut = "Timed out — make sure /remote-pi is running on your Mac"

    /// The paste sheet's rejection. There is no Flutter equivalent: Dart drops
    /// an unparseable paste on the floor (`pairing_viewmodel.dart:50-51`),
    /// which closes the sheet and leaves a camera-less device with a screen
    /// that does nothing. See ``PairingFlowModel/submit(_:from:)``.
    static let unrecognizedPaste =
        "That doesn't look like a pairing code — it should start with remotepi://pair?"

    static func message(for failure: PairFailure) -> String {
        switch failure {
        case .wire(let code, let message):
            return self.message(code: code, fallback: message)

        case .timedOut:
            return timedOut

        case .transportOffline:
            // Trap T4 / plan 61 Phase 3. The QR embedded the Pi's room id at
            // the moment it was *drawn*; a restarted Pi, a `/name`, or a
            // re-spawned daemon invalidates it and the relay answers a
            // `transport_error` control frame instead of a `pair_error`. Two
            // wire channels, one user-visible problem, one instruction: get a
            // fresh QR. Deliberately does not name the room id — it is opaque
            // and means nothing to the person reading this.
            return "That session is no longer running on your Mac — re-run /remote-pi pair for a fresh QR"

        case .relayMismatch(let qr, _):
            // Legacy QRs carry `r=`. Retrying cannot help until either the
            // app's relay or the QR changes, so the copy names the relay the
            // QR wants rather than saying "try again".
            return "This QR was generated for a different relay (\(qr)). Change the relay in Settings, or generate a new QR."

        case .unknownPeer(let message):
            // The Mac has no record of this phone — it was revoked there, or
            // its `peers.json` was reset. Pairing again is exactly the fix.
            return message.isEmpty
                ? "Your Mac doesn't recognize this phone — re-run /remote-pi pair"
                : message

        case .disconnected(let reason):
            // The relay socket died mid-pairing. This is the "offline" state
            // for this screen: nothing about the QR is wrong, so the copy
            // points at the connection and retry is genuinely useful.
            return reason.map { "Lost the connection to the relay (\($0)) — try again" }
                ?? "Lost the connection to the relay — try again"
        }
    }

    /// The `pair_error` code table. `PairErrorCode` is an open union (a wrapped
    /// `String`, not a closed enum), so an unknown code must fall through to
    /// the Pi's developer message rather than to a `default` string that hides
    /// what actually happened.
    static func message(code: PairErrorCode, fallback: String) -> String {
        switch code {
        case .tokenExpired: tokenExpired
        case .tokenConsumed: tokenConsumed
        case .tokenUnknown: tokenUnknown
        default: fallback.isEmpty ? code.rawValue : fallback
        }
    }

    /// Entry point for anything thrown out of the backend.
    ///
    /// `PairFailure` first, because that is the typed answer and the only one
    /// with real copy. Everything else is a `localizedDescription`, which for a
    /// bare Swift `enum` error is the useless
    /// "The operation couldn't be completed. (… error 3.)" — so a backend that
    /// only has a string carries it as ``PairingBackendError/reported(_:)``.
    static func message(for error: any Error) -> String {
        if let failure = error as? PairFailure {
            return message(for: failure)
        }
        if let reported = error as? PairingBackendError {
            return reported.userMessage
        }
        return error.localizedDescription
    }

    /// Whether the error view offers "Try again".
    ///
    /// Flutter hard-codes `canRetry: true` for every failure
    /// (`pairing_viewmodel.dart:96,100`) and we keep that: even a relay
    /// mismatch is retryable once the user has changed a setting or generated
    /// a new QR, and an error screen with no way out is worse than a retry
    /// that fails again with the same explanation.
    static func canRetry(after error: any Error) -> Bool { true }
}
