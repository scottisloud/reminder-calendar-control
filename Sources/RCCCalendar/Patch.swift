import Foundation

/// One field of an update request (SPEC §9.5).
///
/// An **omitted** field is `.unchanged`; an explicit JSON `null` is `.clear`; a value is
/// `.set`. The tool layer maps `nil` argument → `.unchanged` and `NSNull` → `.clear`.
public enum FieldPatch<Value: Sendable & Equatable>: Sendable, Equatable {
    case unchanged
    case set(Value)
    case clear

    /// Resolve against the current value: `.unchanged` keeps it, `.set` replaces it,
    /// `.clear` returns `nil`.
    public func resolved(from current: Value?) -> Value? {
        switch self {
        case .unchanged: return current
        case .set(let value): return value
        case .clear: return nil
        }
    }

    public var isChange: Bool {
        if case .unchanged = self { return false }
        return true
    }
}

/// A patch for `update_event` (SPEC §9.1/§9.5). Clearing `title`/`start`/`end` is
/// rejected by the executor.
public struct EventPatch: Sendable, Equatable {
    public var title: FieldPatch<String> = .unchanged
    public var start: FieldPatch<Date> = .unchanged
    public var end: FieldPatch<Date> = .unchanged
    public var isAllDay: FieldPatch<Bool> = .unchanged
    public var location: FieldPatch<String> = .unchanged
    public var notes: FieldPatch<String> = .unchanged
    public var url: FieldPatch<String> = .unchanged
    public var timeZoneIdentifier: FieldPatch<String> = .unchanged
    public var availability: FieldPatch<String> = .unchanged
    /// Move the event to another calendar.
    public var calendarIdentifier: FieldPatch<String> = .unchanged
    /// Replaces every rule; `.clear` makes the event non-recurring.
    public var recurrenceRules: FieldPatch<[RecurrenceRule]> = .unchanged
    /// Replaces every alarm; `.clear` removes them all.
    public var alarms: FieldPatch<[AlarmSpec]> = .unchanged

    public init() {}

    public var isEmpty: Bool { changedFields.isEmpty }

    /// Wire names of the fields this patch touches, for the journal intent (SPEC §13).
    public var changedFields: [String] {
        var out: [String] = []
        if title.isChange { out.append("title") }
        if start.isChange { out.append("start") }
        if end.isChange { out.append("end") }
        if isAllDay.isChange { out.append("all_day") }
        if location.isChange { out.append("location") }
        if notes.isChange { out.append("notes") }
        if url.isChange { out.append("url") }
        if timeZoneIdentifier.isChange { out.append("time_zone") }
        if availability.isChange { out.append("availability") }
        if calendarIdentifier.isChange { out.append("calendar") }
        if recurrenceRules.isChange { out.append("recurrence") }
        if alarms.isChange { out.append("alarms") }
        return out
    }

    /// Fields whose `.clear` is illegal (an event must keep a title, a start/end, and a
    /// calendar).
    public var illegalClears: [String] {
        var out: [String] = []
        if title == .clear { out.append("title") }
        if start == .clear { out.append("start") }
        if end == .clear { out.append("end") }
        if calendarIdentifier == .clear { out.append("calendar") }
        return out
    }
}

/// A patch for `update_reminder` (SPEC §9.2/§9.5). `completed` is handled by
/// `complete_reminder`, not here.
public struct ReminderPatch: Sendable, Equatable {
    public var title: FieldPatch<String> = .unchanged
    public var notes: FieldPatch<String> = .unchanged
    public var url: FieldPatch<String> = .unchanged
    public var location: FieldPatch<String> = .unchanged
    public var priorityRaw: FieldPatch<Int> = .unchanged
    /// A day or an instant; `.clear` removes the due date.
    public var dueDate: FieldPatch<ReminderDate> = .unchanged
    public var startDate: FieldPatch<ReminderDate> = .unchanged
    /// Move the reminder to another list.
    public var calendarIdentifier: FieldPatch<String> = .unchanged
    public var recurrenceRules: FieldPatch<[RecurrenceRule]> = .unchanged
    public var alarms: FieldPatch<[AlarmSpec]> = .unchanged

    public init() {}

    public var isEmpty: Bool { changedFields.isEmpty }

    public var changedFields: [String] {
        var out: [String] = []
        if title.isChange { out.append("title") }
        if notes.isChange { out.append("notes") }
        if url.isChange { out.append("url") }
        if location.isChange { out.append("location") }
        if priorityRaw.isChange { out.append("priority") }
        if dueDate.isChange { out.append("due") }
        if startDate.isChange { out.append("start") }
        if calendarIdentifier.isChange { out.append("list") }
        if recurrenceRules.isChange { out.append("recurrence") }
        if alarms.isChange { out.append("alarms") }
        return out
    }

    public var illegalClears: [String] {
        var out: [String] = []
        if title == .clear { out.append("title") }
        if calendarIdentifier == .clear { out.append("list") }
        return out
    }
}

/// The Reminders.app convention the write path follows by default: a reminder due at a
/// *time* alerts at that time. EventKit does not do this on its own — a reminder saved
/// with a timed due date and no alarm never notifies, a long-standing papercut of every
/// EventKit-based reminders tool.
public enum ReminderAlertDefaults {
    /// Alarms for a new reminder whose caller did not specify any.
    public static func forNewReminder(due: ReminderDate?) -> [AlarmSpec] {
        guard let instant = due?.instant else { return [] }
        return [.absolute(instant)]
    }

    /// Alarms after a due-date change, when the caller did not touch alarms — or `nil` to
    /// leave them as they are. An alert that was tracking the old due time follows it; a
    /// reminder with no alerts gains one only if the new due date is timed. Anything else
    /// (relative or location alerts, an absolute alert at some other time) is the user's
    /// own and is left alone.
    public static func afterDueChange(
        oldDue: Date?, newDue: ReminderDate?, current: [Alarm]
    ) -> [AlarmSpec]? {
        let specs = current.map(AlarmSpec.init)
        guard !specs.contains(where: { $0 == nil }) else { return nil }  // a location alarm
        let alarms = specs.compactMap { $0 }

        if alarms.isEmpty {
            guard let instant = newDue?.instant else { return nil }
            return [.absolute(instant)]
        }
        guard let oldDue, alarms.contains(.absolute(oldDue)) else { return nil }
        var updated = alarms.filter { $0 != .absolute(oldDue) }
        if let instant = newDue?.instant { updated.append(.absolute(instant)) }
        return updated
    }
}
