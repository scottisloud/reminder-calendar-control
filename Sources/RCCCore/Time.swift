import Foundation

/// Timestamp formatting.
///
/// `ISO8601DateFormatter` is a non-`Sendable` class, so a shared static instance is a
/// strict-concurrency error and a per-call instance is wasteful in a hot logging path.
/// `Date.ISO8601FormatStyle` is a `Sendable` value type, which sidesteps both.
public enum RCCTime {
    private static let instantStyle = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true,
        timeZone: .gmt
    )

    /// RFC 3339 / ISO 8601 instant in UTC, with milliseconds. Used for every log line,
    /// database timestamp, and JSON `generated_at`.
    public static func instant(_ date: Date = Date()) -> String {
        instantStyle.format(date)
    }

    /// Parse an instant produced by `instant(_:)` (or any RFC 3339 string) back to a
    /// `Date`. Accepts values with or without fractional seconds. Returns `nil` on garbage.
    public static func parse(_ string: String) -> Date? {
        if let date = try? Date(string, strategy: instantStyle) { return date }
        return try? Date(string, strategy: Date.ISO8601FormatStyle(timeZone: .gmt))
    }

    /// RFC 3339 wall-clock time in `zone`, with its UTC offset and no fractional seconds:
    /// `2026-10-06T07:00:00-07:00`. For values a person reads as local time; `instant(_:)`
    /// stays the machine form.
    public static func local(_ date: Date, zone: TimeZone = .current) -> String {
        Date.ISO8601FormatStyle(timeZoneSeparator: .colon, timeZone: zone).format(date)
    }

    /// Local calendar date, `YYYY-MM-DD`. Used for daily log-file names, where the
    /// operator's expectation is "today's log", not "today in UTC".
    public static func localDay(_ date: Date = Date(), calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}
