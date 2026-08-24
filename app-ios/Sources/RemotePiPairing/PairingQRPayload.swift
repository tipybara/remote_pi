import Foundation
import RemotePiProtocol

/// The payload encoded in a Pi's pairing QR code — and in the copy-paste
/// string the Pi prints next to it for camera-less devices.
///
/// ```text
/// remotepi://pair?t=<base64url>&epk=<base64url>&n=<name>[&rm=<room>][&r=<relay>]
/// ```
///
/// Produced by `buildQRUri` (`pi-extension/src/pairing/qr.ts:62-89`) through
/// `URLSearchParams`, so the parameter order is insertion order — `t`, `epk`,
/// `n`, then `rm` — and spaces are encoded as `+`, not `%20`.
///
/// | Key | Required | Produced as | Validated as |
/// |---|---|---|---|
/// | `t` | yes | `randomBytes(16).toString("base64url")`, 22 chars unpadded | decodes to **exactly 16 bytes** |
/// | `epk` | yes | `Buffer.from(edPk).toString("base64url")`, 43 chars unpadded | decodes to **exactly 32 bytes** |
/// | `n` | yes | `sessionName.slice(0, 80)` | non-nil, no charset check |
/// | `rm` | no | the Pi's live `room_id` | **opaque** — see the `rm` trap below |
/// | `r` | legacy | relay ws URL, removed in plan 14 | compared, not trusted |
///
/// A payload that is not a well-formed `remotepi://pair` URI parses to `nil`
/// **silently** — the camera keeps scanning rather than raising
/// (`app/lib/pairing/qr_scanner.dart:45`).
public struct PairingQRPayload: Hashable, Sendable {
    /// The `t` parameter **exactly as it appeared in the QR**.
    ///
    /// Trap: the Pi compares with `!==` against the string it issued
    /// (`qr.ts:46`). Re-encoding it — padding it, converting it to the
    /// standard alphabet, round-tripping it through a `Data` — produces a
    /// different string and a `pair_error: token_unknown` that looks for all
    /// the world like a stale QR.
    public var token: String

    /// The Pi's machine key. Stored as bytes, so nothing downstream can
    /// compare the QR's URL-safe spelling against the relay's standard one.
    public var peer: PeerID

    /// `n` — display only, shown on the "connecting" screen before `pair_ok`.
    public var sessionName: String

    /// Legacy `r`. New QRs omit it; when present it is only used to detect
    /// that the QR was generated against a different relay than the app is
    /// configured for.
    public var relayURL: String?

    /// `rm` — the room the `pair_request` envelope must be addressed to.
    ///
    /// Trap: this is captured when the QR is *drawn*. If the Pi restarted or
    /// its session was replaced the id is dead, and the `pair_request` comes
    /// back as a `transport_error` control frame rather than a `pair_error`.
    /// Also do **not** validate its shape: the doc comments in `qr.ts:66-72`
    /// still describe a 12-character digest, but since plan 61 the runtime
    /// value is the session UUID (36 chars with hyphens). Opaque string.
    public var room: RoomID?

    public init(
        token: String,
        peer: PeerID,
        sessionName: String,
        relayURL: String? = nil,
        room: RoomID? = nil
    ) {
        self.token = token
        self.peer = peer
        self.sessionName = sessionName
        self.relayURL = relayURL
        self.room = room
    }

    /// The 16 raw token bytes. Only useful for a length assertion — the token
    /// travels back to the Pi as ``token``, never re-encoded from here.
    public var tokenBytes: Data? { Base64.decodeTolerant(token) }

    /// Parses a scanned or pasted string. Returns `nil` for anything that is
    /// not a well-formed `remotepi://pair` URI with a 16-byte token and a
    /// 32-byte key — a QR that half-parses is worse than one that does not.
    public static func parse(_ raw: String) -> PairingQRPayload? {
        // Trap: the same URI is offered as copy-paste text
        // (`index.ts:3084-3090`), and a user dragging it out of a terminal
        // brings surrounding whitespace with it. The Flutter parser does not
        // trim and rejects those pastes; that is a bug, not a contract.
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let components = URLComponents(string: trimmed),
            components.scheme == "remotepi",
            components.host == "pair"
        else { return nil }

        let query = decodeQuery(components.percentEncodedQuery)
        guard
            let token = query["t"],
            let epk = query["epk"],
            let name = query["n"],
            // 16 bytes exactly (`qr_scanner.dart:57`). A shorter/longer token
            // is not a token this Pi could have issued.
            let tokenBytes = Base64.decodeTolerant(token), tokenBytes.count == 16,
            let peer = PeerID(base64: epk)
        else { return nil }

        return PairingQRPayload(
            token: token,
            peer: peer,
            sessionName: name,
            relayURL: query["r"].flatMap { $0.isEmpty ? nil : $0 },
            room: query["rm"].flatMap { $0.isEmpty ? nil : RoomID($0) }
        )
    }

    /// Splits and decodes a raw query string the way `URLSearchParams` wrote it.
    ///
    /// Trap T2: `URLSearchParams.toString()` encodes a space as `+`
    /// (`qr.ts:82-88`) and Dart's `Uri.queryParameters` decodes `+` back to a
    /// space — but `URLComponents.queryItems` does **not**, so a session named
    /// `my project` would arrive as `my+project` and be shown, stored and
    /// published with a literal plus in it.
    ///
    /// The `+`→space pass is applied to every parameter, uniformly, because
    /// that is what the producer's encoder means by a bare `+`: a real plus
    /// inside a value is written `%2B`. That includes a QR whose `epk` is
    /// standard Base64 — `URLSearchParams` percent-encodes its `+` — so this
    /// pass cannot corrupt a key that a real Pi produced.
    private static func decodeQuery(_ rawQuery: String?) -> [String: String] {
        guard let rawQuery, !rawQuery.isEmpty else { return [:] }
        var result: [String: String] = [:]
        for pair in rawQuery.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let rawName = parts.first else { continue }
            let rawValue = parts.count > 1 ? String(parts[1]) : ""
            guard
                let name = String(rawName).replacingOccurrences(of: "+", with: " ")
                    .removingPercentEncoding,
                let value = rawValue.replacingOccurrences(of: "+", with: " ")
                    .removingPercentEncoding
            else { continue }
            // First occurrence wins, matching `URLSearchParams.get`.
            if result[name] == nil { result[name] = value }
        }
        return result
    }
}
