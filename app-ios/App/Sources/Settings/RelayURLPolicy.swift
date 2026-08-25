import Foundation

/// Relay-URL validation, ported 1:1 from `app/lib/data/transport/relay_config.dart`
/// and `settings_viewmodel.dart:67-87` (spec 08 §9.1).
///
/// Pure, `Foundation`-only, and deliberately separate from the screen model so
/// the rules can be tested — and so onboarding's relay step (spec 08 §5.4) can
/// reuse the *same* strings rather than re-inventing near-identical copy.
///
/// ## The rules, and why each exists
///
/// * **Empty is not "use the default"** — it is a distinct message. The Dart
///   returns `'Enter a URL or clear the field to use the default relay.'`
///   rather than silently substituting the default, because the field is
///   pre-filled with the effective URL: an empty field is almost always a
///   half-finished edit, not an intent to reset. The explicit reset is the
///   **Use default Relay** button.
/// * **`ws://` / `wss://` are refused with their own message.** They are
///   *technically* the transport's scheme, which is exactly why users type
///   them. The app stores the canonical `http(s)` form and converts right
///   before opening the socket, so accepting a `ws` URL here would double the
///   spellings a `PeerRecord.relayURL` comparison has to handle.
/// * **Host must be non-empty.** `URL(string: "https://")` parses; it just has
///   no host, and dialling it fails much later with an opaque error.
enum RelayURLPolicy {
    /// The public community relay, for the "Use default Relay" button.
    ///
    /// Forwards to `AppModel.defaultRelayURL` — the one spelling of "the
    /// default relay" in the app. It used to repeat the literal, which is a
    /// bug waiting to happen the first time one of the two moves.
    static var defaultRelayURL: String { AppModel.defaultRelayURL }

    /// Shown when the field is blank. Not the generic message: blankness has a
    /// remedy (the button) that a malformed URL does not.
    static let emptyMessage =
        "Enter a URL or clear the field to use the default relay."

    /// Called out explicitly so the user understands the app does the
    /// WebSocket conversion itself and is not simply rejecting their relay.
    static let invalidSchemeMessage =
        "Use http:// or https:// (not ws:// or wss:// — the app converts "
        + "to WebSocket automatically)."

    static let invalidGenericMessage =
        "Enter a valid URL starting with https:// (or http:// for local "
        + "relays)."

    /// `nil` when `raw` is acceptable, otherwise the verbatim user-facing
    /// rejection. Keep these strings stable — spec 08 §9.1 pins them and
    /// onboarding shows the same ones.
    static func validationMessage(for raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return emptyMessage }
        if trimmed.hasPrefix("ws://") || trimmed.hasPrefix("wss://") {
            return invalidSchemeMessage
        }
        guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") else {
            return invalidGenericMessage
        }
        // `URLComponents` rather than `URL`: on iOS 17+ `URL(string:)` is far
        // more permissive than the RFC parser the Dart `Uri.parse` mimics, and
        // it happily hands back a URL with an empty host for `https://`.
        guard let host = URLComponents(string: trimmed)?.host, !host.isEmpty else {
            return invalidGenericMessage
        }
        return nil
    }

    /// The value actually persisted: whitespace-trimmed, nothing else. No
    /// scheme rewriting, no trailing-slash normalisation — `PeerRecord.relayURL`
    /// is compared against this by host, and quietly rewriting it here would
    /// make a paired machine look like it lives on a different relay.
    static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
