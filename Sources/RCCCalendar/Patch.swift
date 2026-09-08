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

/// A patch for `update_event` (SPEC §9.1/§9.5). Recurrence and alarm editing land later;
/// clearing `title`/`start`/`end` is rejected by the executor.
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

    public init() {}

    public var isEmpty: Bool {
        !(title.isChange || start.isChange || end.isChange || isAllDay.isChange
            || location.isChange || notes.isChange || url.isChange
            || timeZoneIdentifier.isChange || availability.isChange)
    }

    /// Fields whose `.clear` is illegal (an event must keep a title and a start/end).
    public var illegalClears: [String] {
        var out: [String] = []
        if title == .clear { out.append("title") }
        if start == .clear { out.append("start") }
        if end == .clear { out.append("end") }
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
    /// A due instant; the repository stores it with the reminder's time zone. `.clear`
    /// removes the due date.
    public var dueDate: FieldPatch<Date> = .unchanged
    public var startDate: FieldPatch<Date> = .unchanged

    public init() {}

    public var isEmpty: Bool {
        !(title.isChange || notes.isChange || url.isChange || location.isChange
            || priorityRaw.isChange || dueDate.isChange || startDate.isChange)
    }

    public var illegalClears: [String] {
        title == .clear ? ["title"] : []
    }
}
