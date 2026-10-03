import Foundation
import RCCCalendar
import RCCCore

/// Parsing for the structured write arguments — dates, repeat rules, alerts, priority.
///
/// Each shape mirrors what the read tools return, so an item read back can be written back
/// unchanged: `recurrence_rules[n]` from `get_event` is a valid `recurrence`, and so on.
/// Where a friendlier spelling costs nothing it is accepted too (`"monday"` for a weekday,
/// `minutes_before` for an alert, `"high"` for a priority), because the caller is a model
/// writing JSON from a sentence, and every rejected-then-retried call is a wasted turn.
enum WriteArguments {
    static func invalid(_ message: String) -> ToolError {
        ToolError(code: "invalid_argument", message: message)
    }

    // MARK: - Times

    /// An event boundary: RFC 3339, or `YYYY-MM-DD` meaning local midnight that day in
    /// `zone` (how an all-day event is naturally written).
    static func eventTime(_ raw: Any?, field: String, zone: TimeZone) throws -> Date? {
        guard let string = ReadTools.string(raw) else { return nil }
        switch ReminderDate(parsing: string) {
        case .instant(let date):
            return date
        case .day(let year, let month, let day):
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
                throw ToolError(code: "invalid_datetime", message: "`\(field)` is not a real date")
            }
            return date
        case nil:
            throw ToolError(
                code: "invalid_datetime",
                message: "`\(field)` must be RFC 3339 (2026-10-05T09:00:00-07:00) or a date (2026-10-05)"
            )
        }
    }

    /// A reminder due/start: `YYYY-MM-DD` (a day, no time) or RFC 3339 (a time).
    static func reminderDate(_ raw: Any?, field: String) throws -> ReminderDate {
        guard let string = ReadTools.string(raw), let value = ReminderDate(parsing: string) else {
            throw ToolError(
                code: "invalid_datetime",
                message: "`\(field)` must be a date (2026-10-05) for a day, or RFC 3339 for a time"
            )
        }
        return value
    }

    static func timeZone(_ raw: Any?) throws -> TimeZone? {
        guard let name = ReadTools.string(raw) else { return nil }
        guard let zone = TimeZone(identifier: name) else {
            throw invalid("unknown time zone '\(name)' — use an IANA name such as America/Vancouver")
        }
        return zone
    }

    // MARK: - Priority

    /// `high` / `medium` / `low` / `none`, or EventKit's raw 0–9 (1 = highest).
    /// The names map to the values Reminders.app itself writes: 1, 5, 9, 0.
    static func priority(_ raw: Any?) throws -> Int {
        if raw is NSNull { return 0 }
        if let name = raw as? String {
            switch name.lowercased() {
            case "high": return 1
            case "medium": return 5
            case "low": return 9
            case "none": return 0
            default:
                if let value = Int(name), (0...9).contains(value) { return value }
            }
        } else if let value = ReadTools.int(raw), (0...9).contains(value) {
            return value
        }
        throw invalid("`priority` must be 'high', 'medium', 'low', 'none', or 0–9")
    }

    // MARK: - Recurrence

    private static let weekdayNames: [String: Int] = [
        "sunday": 1, "sun": 1, "su": 1,
        "monday": 2, "mon": 2, "mo": 2,
        "tuesday": 3, "tue": 3, "tu": 3,
        "wednesday": 4, "wed": 4, "we": 4,
        "thursday": 5, "thu": 5, "th": 5,
        "friday": 6, "fri": 6, "fr": 6,
        "saturday": 7, "sat": 7, "sa": 7,
    ]

    /// One rule object, or an array of them. `null` is handled by the caller (it clears).
    static func recurrence(_ raw: Any?) throws -> [RecurrenceRule] {
        if let array = raw as? [Any] { return try array.map(rule) }
        return [try rule(raw as Any)]
    }

    private static func rule(_ raw: Any) throws -> RecurrenceRule {
        guard let object = raw as? [String: Any] else {
            throw invalid("`recurrence` must be an object such as {\"frequency\": \"weekly\", \"days_of_week\": [\"monday\"]}")
        }
        let known: Set<String> = [
            "frequency", "interval", "days_of_week", "days_of_month", "months_of_year",
            "weeks_of_year", "days_of_year", "set_positions", "first_day_of_week", "end",
            "until", "count",
        ]
        if let unknown = object.keys.first(where: { !known.contains($0) }) {
            throw invalid("`recurrence` has an unknown key '\(unknown)'")
        }
        guard let name = ReadTools.string(object["frequency"]),
              let frequency = RecurrenceRule.Frequency(rawValue: name.lowercased())
        else {
            throw invalid("`recurrence.frequency` must be daily, weekly, monthly, or yearly")
        }
        let interval = ReadTools.int(object["interval"]) ?? 1
        guard interval >= 1 else { throw invalid("`recurrence.interval` must be at least 1") }

        return RecurrenceRule(
            frequency: frequency,
            interval: interval,
            daysOfWeek: try daysOfWeek(object["days_of_week"]),
            daysOfMonth: try ints(object["days_of_month"], "days_of_month", allowed: -31...31),
            monthsOfYear: try ints(object["months_of_year"], "months_of_year", allowed: 1...12),
            weeksOfYear: try ints(object["weeks_of_year"], "weeks_of_year", allowed: -53...53),
            daysOfYear: try ints(object["days_of_year"], "days_of_year", allowed: -366...366),
            setPositions: try ints(object["set_positions"], "set_positions", allowed: -366...366),
            firstDayOfWeek: try object["first_day_of_week"].map { try weekday($0) } ?? 0,
            end: try end(object)
        )
    }

    private static func daysOfWeek(_ raw: Any?) throws -> [RecurrenceRule.DayOfWeek] {
        guard let raw else { return [] }
        guard let array = raw as? [Any] else {
            throw invalid("`recurrence.days_of_week` must be an array")
        }
        return try array.map { item in
            if let object = item as? [String: Any] {
                guard let day = object["weekday"] else {
                    throw invalid("each `days_of_week` object needs a `weekday`")
                }
                return .init(weekday: try weekday(day), ordinal: ReadTools.int(object["ordinal"]) ?? 0)
            }
            return .init(weekday: try weekday(item))
        }
    }

    private static func weekday(_ raw: Any) throws -> Int {
        if let name = raw as? String, let value = weekdayNames[name.lowercased()] { return value }
        if let value = ReadTools.int(raw), (1...7).contains(value) { return value }
        throw invalid("a weekday must be a name ('monday') or 1–7 with 1 = Sunday")
    }

    private static func ints(_ raw: Any?, _ field: String, allowed: ClosedRange<Int>) throws -> [Int] {
        guard let raw else { return [] }
        guard let array = raw as? [Any] else { throw invalid("`recurrence.\(field)` must be an array") }
        return try array.map {
            guard let value = ReadTools.int($0), value != 0, allowed.contains(value) else {
                throw invalid("`recurrence.\(field)` values must be non-zero and within \(allowed)")
            }
            return value
        }
    }

    /// `end: {kind: never|date|count, ...}` as the read tools emit it, or the shorthands
    /// `until` (a date) and `count`.
    private static func end(_ object: [String: Any]) throws -> RecurrenceRule.End {
        if let until = object["until"] {
            return .onDate(try endDate(until))
        }
        if let count = object["count"] {
            guard let value = ReadTools.int(count), value > 0 else {
                throw invalid("`recurrence.count` must be a positive integer")
            }
            return .afterOccurrences(value)
        }
        guard let end = object["end"] as? [String: Any] else { return .never }
        switch ReadTools.string(end["kind"]) ?? "never" {
        case "never":
            return .never
        case "date":
            return .onDate(try endDate(end["date"] as Any))
        case "count":
            guard let value = ReadTools.int(end["count"]), value > 0 else {
                throw invalid("`recurrence.end.count` must be a positive integer")
            }
            return .afterOccurrences(value)
        default:
            throw invalid("`recurrence.end.kind` must be never, date, or count")
        }
    }

    /// A series end. A bare date means "through the end of that day", local time.
    private static func endDate(_ raw: Any) throws -> Date {
        guard let string = ReadTools.string(raw), let value = ReminderDate(parsing: string) else {
            throw ToolError(code: "invalid_datetime", message: "a recurrence end date must be a date or RFC 3339")
        }
        switch value {
        case .instant(let date):
            return date
        case .day(let year, let month, let day):
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            let start = calendar.date(from: DateComponents(year: year, month: month, day: day))!
            return calendar.date(byAdding: DateComponents(day: 1, second: -1), to: start)!
        }
    }

    // MARK: - Alerts

    /// An array of `{minutes_before: n}`, `{relative_offset_seconds: s}` (negative is
    /// before, as the read tools report it), or `{absolute_date: RFC 3339}`.
    static func alarms(_ raw: Any?) throws -> [AlarmSpec] {
        guard let array = raw as? [Any] else {
            throw invalid("`alarms` must be an array, e.g. [{\"minutes_before\": 15}]")
        }
        return try array.map { item in
            guard let object = item as? [String: Any] else {
                throw invalid("each alarm must be an object")
            }
            if let minutes = object["minutes_before"] {
                guard let value = ReadTools.double(minutes), value >= 0 else {
                    throw invalid("`minutes_before` must be zero or more")
                }
                return .relative(-value * 60)
            }
            if let seconds = object["relative_offset_seconds"] {
                guard let value = ReadTools.double(seconds) else {
                    throw invalid("`relative_offset_seconds` must be a number")
                }
                return .relative(value)
            }
            if let absolute = object["absolute_date"] {
                guard let date = ReadTools.date(absolute) else {
                    throw ToolError(code: "invalid_datetime", message: "`absolute_date` must be RFC 3339")
                }
                return .absolute(date)
            }
            throw invalid("an alarm needs `minutes_before`, `relative_offset_seconds`, or `absolute_date`")
        }
    }

    // MARK: - Patch plumbing

    /// Reject keys a patch does not know, so a typo is an error instead of a silent no-op —
    /// Claude Desktop drops `additionalProperties: false` before the model sees the schema.
    static func requireKnownKeys(_ dict: [String: Any], _ known: Set<String>, in field: String) throws {
        if let unknown = dict.keys.sorted().first(where: { !known.contains($0) }) {
            throw invalid("`\(field)` has an unknown key '\(unknown)'; allowed: \(known.sorted().joined(separator: ", "))")
        }
    }

    static func stringPatch(_ dict: [String: Any], _ key: String) -> FieldPatch<String> {
        guard dict.keys.contains(key) else { return .unchanged }
        if dict[key] is NSNull { return .clear }
        return .set((dict[key] as? String) ?? "")
    }
}

extension ReadTools {
    static func double(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }
}
