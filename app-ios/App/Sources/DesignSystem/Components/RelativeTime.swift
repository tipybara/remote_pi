import Foundation

/// `_relativeTime` from `session_tile.dart:308-318`, ported exactly.
///
/// ```
/// < 60s      -> "just now"
/// < 60m      -> "Nm ago"
/// < 24h      -> "Nh ago"
/// < 30d      -> "Nd ago"
/// otherwise  -> the first 10 characters of the ISO string  ("2026-08-25")
/// ```
///
/// ## Why not `RelativeDateTimeFormatter`
///
/// It localises ("3 minutes ago", "vor 3 Minuten") and rounds differently
/// ("last month"). The Home subtitle is a fixed-width mono line where the
/// budget is counted in characters, and it sits next to a truncated model name
/// — a formatter that can return a nine-word phrase breaks the row. When this
/// app is localised, this is one of the strings to revisit deliberately, not
/// something to get for free and be surprised by.
///
/// ## Truncation, not formatting, past 30 days
///
/// The fallback slices the **input string**, matching the Dart. That is only
/// correct for an ISO-8601 date whose first 10 characters are `yyyy-MM-dd`,
/// which is what `PeerRecord.pairedAt` holds. ``string(fromISO8601:now:)``
/// therefore takes the raw string and returns it unchanged when it does not
/// parse — never "Invalid Date", never a crash.
enum RelativeTime {
    /// Components are floored, matching Dart's `Duration.inMinutes` etc.
    static func string(from date: Date, now: Date = Date(), isoFallback: String? = nil) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        // A clock skew (the Pi's timestamp slightly ahead of ours) must read
        // "just now", not "-1m ago".
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        if days < 30 { return "\(days)d ago" }
        if let isoFallback, isoFallback.count >= 10 {
            return String(isoFallback.prefix(10))
        }
        return isoDay(from: date)
    }

    /// The common case: `PeerRecord.pairedAt`, which is an ISO-8601 string.
    /// Returns the input unchanged when it cannot be parsed.
    static func string(fromISO8601 raw: String, now: Date = Date()) -> String {
        guard let date = parseISO8601(raw) else { return raw }
        return string(from: date, now: now, isoFallback: raw)
    }

    /// Epoch milliseconds (`RoomMeta.startedAt`, `MessageRow.ts`).
    ///
    /// Note for the Home agent: **never** render `startedAt` as "last seen".
    /// The relay re-stamps it on every reconnect (spec 08 §13.7), so it means
    /// "when this socket connected", not "when this session started".
    static func string(fromEpochMilliseconds ms: Int64, now: Date = Date()) -> String {
        string(from: Date(timeIntervalSince1970: Double(ms) / 1000), now: now)
    }

    /// Accepts both `2026-08-25T12:00:00Z` and the fractional-seconds form the
    /// Pi sometimes emits; `ISO8601DateFormatter` needs to be told which.
    ///
    /// The formatter is built per call rather than cached in a `static let`.
    /// `ISO8601DateFormatter` is a mutable reference type and not `Sendable`,
    /// so a shared instance is a data race the moment anything parses off the
    /// main actor — and the only ways to keep one are `nonisolated(unsafe)` or
    /// an `@unchecked Sendable` box, i.e. asserting a guarantee Foundation does
    /// not give in writing. Allocation cost is a few hundred nanoseconds
    /// against a list row that is about to lay out text; if a profile ever
    /// disagrees, the fix is a `@MainActor` memo of the formatted *string* per
    /// session, not a shared formatter.
    static func parseISO8601(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    /// `yyyy-MM-dd` in UTC, built from calendar components so there is no
    /// shared `DateFormatter` and no locale to surprise us (an Arabic locale
    /// would otherwise render Eastern Arabic numerals here).
    private static func isoDay(from date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0
        )
    }
}
