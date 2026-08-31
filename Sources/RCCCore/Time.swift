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
