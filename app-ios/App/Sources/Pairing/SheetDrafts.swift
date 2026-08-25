import Foundation

/// The post-pair nickname sheet's return contract (spec 08 §6.4).
///
/// Spelled out because it is the kind of thing that gets "simplified" into a
/// bug six months later — three of the four exits produce a *different* value
/// and two of them look identical from the outside:
///
/// | Action | Returns |
/// |---|---|
/// | Save, non-empty | the trimmed input |
/// | Save, empty | the placeholder (`hostname` or `"Pi"`) |
/// | Skip | the placeholder |
/// | Drag-dismiss | `nil` — the caller treats it as skip |
///
/// So **Skip persists the hostname as the nickname** while **drag-dismiss
/// persists nothing**. That asymmetry is intentional: a tapped Skip is a
/// decision ("whatever you suggested is fine"), and a drag is an escape. The
/// downstream `applyNickname` is a no-op on `nil`/empty, which is what makes
/// the escape lossless.
enum NicknameDraft {
    /// What the field hints with, and what Skip resolves to, when the Pi sent
    /// no `hostname` — a legacy Pi, or one whose `os.hostname()` was blank.
    static let fallback = "Pi"

    /// The hint text, from `pair_ok.hostname`.
    static func placeholder(defaultName: String?) -> String {
        let trimmed = defaultName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return fallback }
        return trimmed
    }

    /// "Save" — with whatever is in the field.
    static func save(typed: String, placeholder: String) -> String {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? placeholder : trimmed
    }

    /// "Skip".
    static func skip(placeholder: String) -> String { placeholder }

    /// What actually gets persisted, given whatever the sheet returned.
    ///
    /// `nil` in ⇒ `nil` out (drag-dismiss). A whitespace-only string also maps
    /// to `nil` rather than to the placeholder: it can only arrive from a
    /// caller that skipped ``save(typed:placeholder:)``, and writing " " as a
    /// device label would be worse than writing nothing.
    static func resolve(sheetResult: String?) -> String? {
        guard let trimmed = sheetResult?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}

/// The paste-QR sheet's one rule (spec 08 §6.5): submit is disabled while the
/// trimmed text is empty (`paste_qr_sheet.dart:78-80`).
///
/// Trimming matters beyond tidiness. The Pi prints the URI on its own line and
/// a user dragging it out of a terminal brings a newline and often an indent
/// with it; `PairingQRPayload.parse` trims too, but the *button* has to agree
/// or a paste of "\n" leaves an enabled button that does nothing.
enum PasteDraft {
    static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func canSubmit(_ raw: String) -> Bool {
        !normalized(raw).isEmpty
    }
}
