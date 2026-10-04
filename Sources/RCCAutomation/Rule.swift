import Foundation
import RCCCore

/// A Tier 0 automation rule: the normative, allowlisted DSL of SPEC §11.2.
///
/// Bounded predicates and actions only — no shell, AppleScript, SQL, expressions, or
/// templates. Every rule declares its time zone, schedule, misfire policy, maximum
/// lateness, maximum fan-out, and (through its trigger's `lists`/`calendars`) the
/// destinations it may touch. The JSON shape is versioned by `dsl_version`; a document
/// with an unknown key is rejected rather than half-understood.
///
/// ```json
/// {
///   "dsl_version": 1,
///   "name": "Clear out old completed reminders",
///   "time_zone": "America/Vancouver",
///   "schedule": {"daily_at": "02:00"},
///   "misfire_policy": "run_once",
///   "max_lateness_minutes": 720,
///   "max_fan_out": 100,
///   "trigger": {"completed_reminders": {"older_than_days": 30, "lists": ["<list id>"]}},
///   "action": "delete"
/// }
/// ```
public struct RuleDefinition: Sendable, Equatable {
    public static let dslVersion = 1

    public enum Schedule: Sendable, Equatable {
        /// Every day at a local wall-clock time.
        case daily(hour: Int, minute: Int)
        /// On the given weekdays (1 = Sunday … 7 = Saturday) at a local time.
        case weekly(weekdays: [Int], hour: Int, minute: Int)
        /// Every N minutes (≥ 15 — the LaunchAgent fires every 30 by default, so anything
        /// finer is a promise rcc cannot keep).
        case everyMinutes(Int)
    }

    /// What a run does when it starts later than its slot (sleep, logged out, DST gap).
    public enum MisfirePolicy: String, Sendable, Equatable {
        /// Run once if no later than `maxLateness`, otherwise skip to the next slot.
        case skip
        /// Run once however late — every missed slot coalesces into that one run.
        case runOnce = "run_once"
    }

    public enum Trigger: Sendable, Equatable {
        /// Completed reminders whose completion is older than N days, in the given lists.
        case completedReminders(olderThanDays: Int, lists: [String])
        /// Upcoming timed events with no location and no recognisable conferencing link
        /// (a heuristic, SPEC §10.1). `onlyWithAttendees` narrows it to meetings.
        case eventsWithoutLocation(daysAhead: Int, calendars: [String]?, onlyWithAttendees: Bool)
        /// Consecutive timed events in the same day with less than `minGapMinutes` between
        /// them (0 = touching end to start).
        case backToBackEvents(daysAhead: Int, calendars: [String]?, minGapMinutes: Int)
    }

    public enum Action: String, Sendable, Equatable {
        /// Report the matches (log + notification). Never mutates anything.
        case flag
        /// Delete the matches — always staged for human approval (SPEC §8.3).
        case delete
    }

    public var name: String
    public var enabled: Bool
    public var timeZone: TimeZone
    public var schedule: Schedule
    public var misfirePolicy: MisfirePolicy
    public var maxLatenessMinutes: Int
    public var maxFanOut: Int
    public var trigger: Trigger
    public var action: Action

    public init(
        name: String, enabled: Bool = true, timeZone: TimeZone, schedule: Schedule,
        misfirePolicy: MisfirePolicy = .runOnce, maxLatenessMinutes: Int = 720, maxFanOut: Int = 50,
        trigger: Trigger, action: Action
    ) {
        self.name = name
        self.enabled = enabled
        self.timeZone = timeZone
        self.schedule = schedule
        self.misfirePolicy = misfirePolicy
        self.maxLatenessMinutes = maxLatenessMinutes
        self.maxFanOut = maxFanOut
        self.trigger = trigger
        self.action = action
    }

    /// The calendars/lists this rule may read or act on: its destination allowlist.
    /// `nil` means "every calendar", which only a non-mutating rule may have.
    public var scope: [String]? {
        switch trigger {
        case .completedReminders(_, let lists): return lists
        case .eventsWithoutLocation(_, let calendars, _), .backToBackEvents(_, let calendars, _): return calendars
        }
    }
}

public struct RuleError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

// MARK: - Parsing

extension RuleDefinition {
    /// Parse and validate a rule document. Every key is checked against an allowlist.
    public init(json object: [String: Any]) throws {
        try Self.allow(object, ["dsl_version", "name", "enabled", "time_zone", "schedule", "misfire_policy",
                                "max_lateness_minutes", "max_fan_out", "trigger", "action"], in: "rule")
        let version = Self.int(object["dsl_version"]) ?? Self.dslVersion
        guard version == Self.dslVersion else {
            throw RuleError("`dsl_version` \(version) is not supported (this rcc understands \(Self.dslVersion))")
        }
        guard let name = (object["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty, name.count <= 120 else {
            throw RuleError("`name` is required (1–120 characters)")
        }
        guard let zoneName = object["time_zone"] as? String, let zone = TimeZone(identifier: zoneName) else {
            throw RuleError("`time_zone` must be an IANA name such as America/Vancouver")
        }
        let misfire: MisfirePolicy
        if let raw = object["misfire_policy"] {
            guard let value = raw as? String, let parsed = MisfirePolicy(rawValue: value) else {
                throw RuleError("`misfire_policy` must be 'skip' or 'run_once'")
            }
            misfire = parsed
        } else {
            misfire = .runOnce
        }
        let lateness = Self.int(object["max_lateness_minutes"]) ?? 720
        guard (30...10_080).contains(lateness) else {
            throw RuleError("`max_lateness_minutes` must be 30–10080 (at least the LaunchAgent's 30-minute cadence)")
        }
        let fanOut = Self.int(object["max_fan_out"]) ?? 50
        guard (1...500).contains(fanOut) else { throw RuleError("`max_fan_out` must be 1–500") }

        let action: Action
        guard let rawAction = object["action"] as? String, let parsedAction = Action(rawValue: rawAction) else {
            throw RuleError("`action` must be 'flag' or 'delete'")
        }
        action = parsedAction
        let trigger = try Self.trigger(object["trigger"])

        // The allowlist of action × trigger. Deleting is defined only where it is a
        // routine clean-up of the rule's own explicitly named lists.
        if action == .delete {
            guard case .completedReminders = trigger else {
                throw RuleError("`delete` is only allowed with the `completed_reminders` trigger")
            }
        }

        self.init(
            name: name, enabled: (object["enabled"] as? Bool) ?? true, timeZone: zone,
            schedule: try Self.schedule(object["schedule"]), misfirePolicy: misfire,
            maxLatenessMinutes: lateness, maxFanOut: fanOut, trigger: trigger, action: action
        )
    }

    private static func schedule(_ raw: Any?) throws -> Schedule {
        guard let object = raw as? [String: Any], object.count == 1, let (key, value) = object.first else {
            throw RuleError("`schedule` must be exactly one of {\"daily_at\": \"HH:MM\"}, "
                + "{\"weekly\": {\"days\": [\"monday\"], \"at\": \"HH:MM\"}}, {\"every_minutes\": N}")
        }
        switch key {
        case "daily_at":
            let (hour, minute) = try clock(value, "schedule.daily_at")
            return .daily(hour: hour, minute: minute)
        case "weekly":
            guard let weekly = value as? [String: Any] else { throw RuleError("`schedule.weekly` must be an object") }
            try allow(weekly, ["days", "at"], in: "schedule.weekly")
            guard let days = weekly["days"] as? [Any], !days.isEmpty else {
                throw RuleError("`schedule.weekly.days` must be a non-empty array of weekday names")
            }
            let weekdays = try days.map(weekday)
            let (hour, minute) = try clock(weekly["at"] as Any, "schedule.weekly.at")
            return .weekly(weekdays: Array(Set(weekdays)).sorted(), hour: hour, minute: minute)
        case "every_minutes":
            guard let minutes = int(value), (15...10_080).contains(minutes) else {
                throw RuleError("`schedule.every_minutes` must be 15–10080")
            }
            return .everyMinutes(minutes)
        default:
            throw RuleError("unknown schedule '\(key)'; use daily_at, weekly, or every_minutes")
        }
    }

    private static func trigger(_ raw: Any?) throws -> Trigger {
        guard let object = raw as? [String: Any], object.count == 1, let (key, value) = object.first,
              let body = value as? [String: Any] else {
            throw RuleError("`trigger` must be exactly one of completed_reminders, events_without_location, back_to_back_events")
        }
        switch key {
        case "completed_reminders":
            try allow(body, ["older_than_days", "lists"], in: "trigger.completed_reminders")
            guard let days = int(body["older_than_days"]), (1...3650).contains(days) else {
                throw RuleError("`older_than_days` must be 1–3650")
            }
            guard let lists = strings(body["lists"]), !lists.isEmpty else {
                throw RuleError("`completed_reminders.lists` must name at least one list — a clean-up rule never "
                    + "gets an implicit 'every list' scope")
            }
            return .completedReminders(olderThanDays: days, lists: lists)
        case "events_without_location":
            try allow(body, ["days_ahead", "calendars", "only_with_attendees"], in: "trigger.events_without_location")
            return .eventsWithoutLocation(
                daysAhead: try daysAhead(body), calendars: strings(body["calendars"]),
                onlyWithAttendees: (body["only_with_attendees"] as? Bool) ?? true
            )
        case "back_to_back_events":
            try allow(body, ["days_ahead", "calendars", "min_gap_minutes"], in: "trigger.back_to_back_events")
            let gap = int(body["min_gap_minutes"]) ?? 0
            guard (0...240).contains(gap) else { throw RuleError("`min_gap_minutes` must be 0–240") }
            return .backToBackEvents(daysAhead: try daysAhead(body), calendars: strings(body["calendars"]), minGapMinutes: gap)
        default:
            throw RuleError("unknown trigger '\(key)'")
        }
    }

    private static func daysAhead(_ body: [String: Any]) throws -> Int {
        let days = int(body["days_ahead"]) ?? 7
        guard (1...90).contains(days) else { throw RuleError("`days_ahead` must be 1–90") }
        return days
    }

    private static func clock(_ raw: Any, _ field: String) throws -> (Int, Int) {
        guard let text = raw as? String else { throw RuleError("`\(field)` must be \"HH:MM\"") }
        let parts = text.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else {
            throw RuleError("`\(field)` must be \"HH:MM\" (24-hour)")
        }
        return (hour, minute)
    }

    private static let weekdayNames: [String: Int] = [
        "sunday": 1, "sun": 1, "monday": 2, "mon": 2, "tuesday": 3, "tue": 3, "wednesday": 4, "wed": 4,
        "thursday": 5, "thu": 5, "friday": 6, "fri": 6, "saturday": 7, "sat": 7,
    ]

    private static func weekday(_ raw: Any) throws -> Int {
        if let name = raw as? String, let value = weekdayNames[name.lowercased()] { return value }
        if let value = int(raw), (1...7).contains(value) { return value }
        throw RuleError("a weekday must be a name ('monday') or 1–7 with 1 = Sunday")
    }

    private static func allow(_ object: [String: Any], _ keys: Set<String>, in field: String) throws {
        if let unknown = object.keys.sorted().first(where: { !keys.contains($0) }) {
            throw RuleError("`\(field)` has an unknown key '\(unknown)'; allowed: \(keys.sorted().joined(separator: ", "))")
        }
    }

    private static func int(_ value: Any?) -> Int? {
        if value is Bool { return nil }
        if let int = value as? Int { return int }
        if let number = value as? NSNumber, number.doubleValue == number.doubleValue.rounded() { return number.intValue }
        return nil
    }

    private static func strings(_ value: Any?) -> [String]? {
        guard let array = value as? [Any] else { return nil }
        let out = array.compactMap { $0 as? String }.filter { !$0.isEmpty }
        return out.isEmpty ? nil : out
    }
}

// MARK: - Serialisation

extension RuleDefinition {
    private static let weekdayLabels = ["", "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    /// The canonical document — what is stored, and what the read tools return.
    public var jsonObject: [String: Any] {
        func clock(_ h: Int, _ m: Int) -> String { String(format: "%02d:%02d", h, m) }
        let scheduleObject: [String: Any]
        switch schedule {
        case .daily(let h, let m): scheduleObject = ["daily_at": clock(h, m)]
        case .weekly(let days, let h, let m):
            scheduleObject = ["weekly": ["days": days.map { Self.weekdayLabels[$0] }, "at": clock(h, m)]]
        case .everyMinutes(let n): scheduleObject = ["every_minutes": n]
        }
        let triggerObject: [String: Any]
        switch trigger {
        case .completedReminders(let days, let lists):
            triggerObject = ["completed_reminders": ["older_than_days": days, "lists": lists]]
        case .eventsWithoutLocation(let days, let calendars, let attendees):
            var body: [String: Any] = ["days_ahead": days, "only_with_attendees": attendees]
            if let calendars { body["calendars"] = calendars }
            triggerObject = ["events_without_location": body]
        case .backToBackEvents(let days, let calendars, let gap):
            var body: [String: Any] = ["days_ahead": days, "min_gap_minutes": gap]
            if let calendars { body["calendars"] = calendars }
            triggerObject = ["back_to_back_events": body]
        }
        return [
            "dsl_version": Self.dslVersion, "name": name, "enabled": enabled,
            "time_zone": timeZone.identifier, "schedule": scheduleObject,
            "misfire_policy": misfirePolicy.rawValue, "max_lateness_minutes": maxLatenessMinutes,
            "max_fan_out": maxFanOut, "trigger": triggerObject, "action": action.rawValue,
        ]
    }

    public var canonicalJSON: String {
        let data = (try? JSONSerialization.data(withJSONObject: jsonObject, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    public init(canonicalJSON: String) throws {
        guard let object = try JSONSerialization.jsonObject(with: Data(canonicalJSON.utf8)) as? [String: Any] else {
            throw RuleError("stored rule is not a JSON object")
        }
        try self.init(json: object)
    }
}
