import Foundation

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
public enum ReminderPriorityBucket: String, Sendable {
    case none, high, medium, low

    public init(raw: Int) {
        switch raw {
        case 1...4: self = .high
        case 5: self = .medium
        case 6...9: self = .low
        default: self = .none
        }
    }
}
