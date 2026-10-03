import Foundation
import RCCCore

/// A normalized name paired with the raw integer EventKit reported (SPEC §9.1).
///
/// Every EventKit enum crosses the boundary this way: a case Apple adds in a future OS
/// stays representable as `EnumValue(name: "unknown", raw: <n>)` rather than being coerced
/// into an existing case.
public struct EnumValue: Sendable, Equatable {
    public let name: String
    public let raw: Int

    public init(name: String, raw: Int) {
        self.name = name
        self.raw = raw
    }
}

/// A structured (geofence-capable) location: the title EventKit stores plus coordinates
/// and, for a location-triggered alarm, a radius in metres (SPEC §9.1).
public struct GeoLocation: Sendable, Equatable {
    public let title: String?
    public let latitude: Double?
    public let longitude: Double?
    public let radius: Double?

    public init(title: String?, latitude: Double?, longitude: Double?, radius: Double? = nil) {
        self.title = title
        self.latitude = latitude
        self.longitude = longitude
        self.radius = radius
    }
}

/// An attendee or organizer (SPEC §9.1). The URL is canonical; an email is *derived* from
/// a `mailto:` URL only, never read from a native property that does not exist.
public struct Participant: Sendable, Equatable {
    public let name: String?
    public let url: String?
    public let email: String?
    public let isCurrentUser: Bool
    public let type: EnumValue
    public let role: EnumValue
    /// Read-only: public EventKit cannot change participation status (SPEC §8.4).
    public let status: EnumValue

    public init(
        name: String?, url: String?, email: String?, isCurrentUser: Bool,
        type: EnumValue, role: EnumValue, status: EnumValue
    ) {
        self.name = name
        self.url = url
        self.email = email
        self.isCurrentUser = isCurrentUser
        self.type = type
        self.role = role
        self.status = status
    }
}

/// An alarm on an event or reminder (SPEC §9.1).
///
/// A `.procedure` alarm's URL cannot be read or created on modern macOS; an existing one
/// is surfaced as `type: .procedure` with a warning and otherwise left untouched.
public struct Alarm: Sendable, Equatable {
    public let type: EnumValue
    /// Seconds before the item. `nil` when the alarm is absolute.
    public let relativeOffset: TimeInterval?
    /// Absolute trigger time, when the alarm is not relative.
    public let absoluteDate: Date?
    /// For a location-triggered alarm.
    public let structuredLocation: GeoLocation?
    public let proximity: EnumValue?

    public init(
        type: EnumValue, relativeOffset: TimeInterval?, absoluteDate: Date?,
        structuredLocation: GeoLocation?, proximity: EnumValue?
    ) {
        self.type = type
        self.relativeOffset = relativeOffset
        self.absoluteDate = absoluteDate
        self.structuredLocation = structuredLocation
        self.proximity = proximity
    }
}

/// A reminder's start/due value, preserving the `DateComponents` granularity EventKit
/// stored rather than coercing to one representation (SPEC §9.5).
public struct DateComponentsDTO: Sendable, Equatable {
    public let year: Int?
    public let month: Int?
    public let day: Int?
    public let hour: Int?
    public let minute: Int?
    public let second: Int?
    /// The IANA identifier when the components carry a time zone; `nil` for a floating value.
    public let timeZoneIdentifier: String?

    public init(
        year: Int?, month: Int?, day: Int?, hour: Int?, minute: Int?, second: Int?,
        timeZoneIdentifier: String?
    ) {
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
        self.second = second
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    /// `date` (no time-of-day), `datetime` (with time), or `floating` (time, no zone).
    public var granularity: String {
        if hour == nil && minute == nil { return "date" }
        return timeZoneIdentifier == nil ? "floating" : "datetime"
    }

    public var canonicalString: String {
        func part(_ label: String, _ value: Int?) -> String { "\(label)=\(value.map(String.init) ?? "-")" }
        return [
            part("y", year), part("mo", month), part("d", day),
            part("h", hour), part("mi", minute), part("s", second),
            "tz=\(timeZoneIdentifier ?? "-")",
        ].joined(separator: ",")
    }
}

extension DateComponentsDTO {
    public init(_ components: DateComponents) {
        self.init(
            year: components.year,
            month: components.month,
            day: components.day,
            hour: components.hour,
            minute: components.minute,
            second: components.second,
            timeZoneIdentifier: components.timeZone?.identifier
        )
    }
}

/// The reminder priority bucket EventKit's 0–9 scale maps to (SPEC §9.2).
/// 1–4 high, 5 medium, 6–9 low, 0 none. The raw value is always retained alongside.
public enum ReminderPriorityBucket: String, Sendable, Equatable, CaseIterable {
    case none, low, medium, high

    public init(raw: Int) {
        switch raw {
        case 1...4: self = .high
        case 5: self = .medium
        case 6...9: self = .low
        default: self = .none
        }
    }

    /// `high` > `medium` > `low` > `none`, for "at least this priority" filters.
    public var rank: Int {
        switch self {
        case .none: return 0
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        }
    }
}

extension DateComponentsDTO {
    /// Best-effort `Date` for ordering and range filters. Uses the components' own time
    /// zone, else `defaultZone`; a date-only value resolves to midnight in that zone.
    public func resolvedDate(defaultZone: TimeZone = .current) -> Date? {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? defaultZone
        return calendar.date(from: components)
    }
}

/// A reminder's due or start value as a caller writes it (SPEC §9.5).
///
/// Reminders distinguish "due on a day" from "due at a time", and the Reminders app shows
/// them differently — a day-only reminder is not overdue until the day is over. Writing a
/// bare `Date` cannot express the first, so the write path takes this instead.
public enum ReminderDate: Sendable, Equatable {
    /// A calendar day with no time of day.
    case day(year: Int, month: Int, day: Int)
    /// A specific instant, stored in the reminder's time zone.
    case instant(Date)

    /// Parse `YYYY-MM-DD` as a day, or any RFC 3339 timestamp as an instant.
    public init?(parsing string: String) {
        let parts = string.split(separator: "-", omittingEmptySubsequences: false)
        if parts.count == 3, string.count == 10,
           let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
           (1...12).contains(month), (1...31).contains(day) {
            self = .day(year: year, month: month, day: day)
            return
        }
        guard let date = RCCTime.parse(string) else { return nil }
        self = .instant(date)
    }

    /// The `DateComponents` EventKit stores. A day carries no time and no zone (which is
    /// how Reminders.app writes one); an instant carries the full time and its zone.
    public func dateComponents(zone: TimeZone) -> DateComponents {
        switch self {
        case .day(let year, let month, let day):
            return DateComponents(year: year, month: month, day: day)
        case .instant(let date):
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            var components = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute, .second], from: date
            )
            components.timeZone = zone
            return components
        }
    }

    /// The instant a timed value fires at; `nil` for a day.
    public var instant: Date? {
        if case .instant(let date) = self { return date }
        return nil
    }
}

/// An alarm as a caller writes it. Location-triggered alarms are read-only here: they need
/// a geofence the model has no good way to supply, and an existing one is left untouched.
public enum AlarmSpec: Sendable, Equatable {
    /// Seconds relative to the item's start (events) or due time (reminders); negative is
    /// before, matching `EKAlarm.relativeOffset`.
    case relative(TimeInterval)
    case absolute(Date)

    /// The writable form of a read DTO, or `nil` for one that cannot be rewritten as-is
    /// (a location alarm).
    public init?(_ alarm: Alarm) {
        if alarm.structuredLocation != nil || alarm.proximity != nil { return nil }
        if let date = alarm.absoluteDate { self = .absolute(date); return }
        self = .relative(alarm.relativeOffset ?? 0)
    }
}

extension Alarm {
    /// The order-independent string an item's `version` hashes (SPEC §9.4).
    var canonicalString: String {
        if let date = absoluteDate { return "\(type.name):at=\(RCCTime.instant(date))" }
        if let geo = structuredLocation {
            return "\(type.name):geo=\(geo.title ?? ""):\(proximity?.name ?? "")"
        }
        return "\(type.name):\(relativeOffset ?? 0)"
    }
}

/// Named due windows for "what's on my plate" questions, evaluated in local time with the
/// Reminders app's own semantics: a day-only reminder is due *on* its day and becomes
/// overdue only once that day has ended; a timed one is overdue once its time has passed.
public enum ReminderDueWindow: String, Sendable, CaseIterable {
    case overdue
    case today
    case overdueOrToday = "overdue_or_today"
    case next7Days = "next_7_days"

    public func matches(_ due: DateComponentsDTO?, now: Date = Date(), zone: TimeZone = .current) -> Bool {
        guard let due, let dueDate = due.resolvedDate(defaultZone: zone) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let startOfToday = calendar.startOfDay(for: now)
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday)!
        let isDayOnly = due.granularity == "date"

        let overdue = isDayOnly ? dueDate < startOfToday : dueDate < now
        let today = dueDate >= startOfToday && dueDate < startOfTomorrow
        switch self {
        case .overdue: return overdue
        case .today: return today
        case .overdueOrToday: return overdue || today
        case .next7Days:
            let end = calendar.date(byAdding: .day, value: 7, to: startOfToday)!
            return !overdue && dueDate >= startOfToday && dueDate < end
        }
    }
}
