import Foundation

/// Relay endpoint vocabulary shared by the onboarding wizard (spec 08 §5.4).
///
/// Ported from `app/lib/data/transport/relay_config.dart`. The rules and both
/// user-facing strings are copied verbatim, because Settings shows the same
/// messages and the two screens diverging is a bug report waiting to happen.
enum RelayURL {

    // MARK: - The default

    /// The community relay this build ships with.
    ///
    /// Reads `AppModel.defaultRelayURL` rather than repeating the literal, so
    /// the card cannot print one host while the app dials another. The wizard
    /// needs the value (not just the concept) because the community card
    /// *prints the URL* (`relay_step.dart:73-79`) — a user picking "hosted by
    /// us" deserves to see which host that is before agreeing to it.
    static var communityDefault: String { AppModel.defaultRelayURL }

    // MARK: - Validation messages (verbatim, `relay_config.dart:27-37`)

    /// Called out explicitly so the user understands the app converts to
    /// WebSocket itself and must not type `ws://`.
    static let invalidSchemeMessage =
        "Use http:// or https:// (not ws:// or wss:// — the app converts "
        + "to WebSocket automatically)."

    static let invalidGenericMessage =
        "Enter a valid URL starting with https:// (or http:// for local "
        + "relays)."

    // MARK: - Validation

    /// `isValidRelayUrl` (`relay_config.dart:67-83`).
    ///
    /// Rules, in order: non-empty; not the legacy `ws(s)://` form; `http(s)://`
    /// scheme; parseable with a non-empty host.
    ///
    /// Deliberately *not* a `URL(string:)`-only check. `URL(string: "https://")`
    /// parses on Darwin and yields an empty host, and `URL(string: "notaurl")`
    /// also succeeds as a relative URL — either one would let a value through
    /// that cannot be connected to.
    static func isValid(_ url: String) -> Bool {
        if url.isEmpty { return false }
        if url.hasPrefix("ws://") || url.hasPrefix("wss://") { return false }
        if !url.hasPrefix("http://") && !url.hasPrefix("https://") { return false }
        guard let components = URLComponents(string: url) else { return false }
        guard let host = components.host, !host.isEmpty else { return false }
        return true
    }

    /// `relayUrlValidationMessage` (`relay_config.dart:88-95`).
    /// `nil` means the URL is acceptable.
    static func validationMessage(_ url: String) -> String? {
        if url.isEmpty { return invalidGenericMessage }
        if url.hasPrefix("ws://") || url.hasPrefix("wss://") { return invalidSchemeMessage }
        if isValid(url) { return nil }
        return invalidGenericMessage
    }
}
