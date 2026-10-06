import Foundation
import RCCCore

/// The seam between `rcc` and EventKit (SPEC §15).
///
/// EventKit has no first-party in-memory store, so everything above this protocol is
/// testable against `InMemoryCalendarRepository` and real EventKit is reserved for
/// adapter/integration tests.
///
public protocol CalendarRepository: Sendable {
    func authorizationStatus(for entityType: RCCEntityType) async -> RCCAuthorizationStatus
    /// Prompts if — and only if — status is `.notDetermined`. Returns the status after
    /// the attempt rather than a bare `Bool`, because "false" conflates "user said no"
    /// with "already denied, no prompt shown".
    func requestFullAccess(for entityType: RCCEntityType) async throws -> RCCAuthorizationStatus
    /// Discard every object fetched so far. Required after an authorization change and
    /// after `EKEventStoreChanged` (SPEC §6.2, §7.4).
    func reset() async

    func sources() async throws -> [SourceSummary]
    func calendars(for entityType: RCCEntityType) async throws -> [CalendarSummary]
    func calendar(withIdentifier identifier: String, entityType: RCCEntityType) async throws -> CalendarSummary?

    func createCalendar(title: String, entityType: RCCEntityType, sourceIdentifier: String) async throws -> CalendarSummary
    func deleteCalendar(identifier: String, entityType: RCCEntityType) async throws
    /// Whether a calendar with this identifier resolves. Used by crash recovery for
    /// container operations (SPEC §9.6).
    func calendarExists(identifier: String) async -> Bool

    /// Reminder-list management (SPEC §9.3). Restricted to calendars whose
    /// `allowedEntityTypes` is reminder-only — a mixed-entity calendar returns
    /// `unsupported`, since removing it could delete events too.
    func createReminderList(title: String, sourceIdentifier: String) async throws -> CalendarSummary
    func updateReminderList(identifier: String, title: String) async throws -> CalendarSummary
    /// Returns the number of reminders removed with the list.
    func deleteReminderList(identifier: String) async throws -> Int

    func createEvent(_ draft: EventDraft) async throws -> String
    /// Apply a patch to an event and return the saved DTO (with a fresh `version`). A
    /// recurring target requires `scope` (SPEC §9.4); a non-recurring one ignores it.
    ///
    /// `occurrenceDate` picks one occurrence of a recurring series. Every occurrence shares
    /// the series' identifier, so without it EventKit resolves the *first* one — editing
    /// "this occurrence" would silently edit the wrong day.
    func updateEvent(
        identifier: String, occurrenceDate: Date?, patch: EventPatch, scope: RecurrenceScope?
    ) async throws -> EventSummary
    func events(inCalendar calendarIdentifier: String, from: Date, to: Date) async throws -> [EventSummary]
    /// Events across the given calendars (or every event calendar when `nil`) in a bounded
    /// window. A window longer than four years is walked in ≤4-year chunks — EventKit's
    /// predicate silently truncates one otherwise (SPEC §9.4/§10).
    func listEvents(calendarIdentifiers: [String]?, from: Date, to: Date) async throws -> [EventSummary]
    /// One page of a filtered event query, plus how many matched in total (SPEC §10).
    ///
    /// Exists for cost, not semantics: it must return exactly what `listEvents` + filter +
    /// slice would, but an adapter can do the filtering and ordering on cheap fields and
    /// fully convert only the page — the difference between 16 s and well under one for a
    /// few thousand occurrences in EventKit.
    func queryEvents(_ query: EventQuery) async throws -> QueryPage<EventSummary>
    /// One event. With `occurrenceDate`, that specific occurrence of a recurring series, or
    /// `nil` if the series has no occurrence there — never a different one.
    func event(withIdentifier identifier: String, occurrenceDate: Date?) async throws -> EventSummary?
    /// Delete an event; for a recurring one, `scope` decides how much of the series goes.
    func deleteEvent(identifier: String, occurrenceDate: Date?, scope: RecurrenceScope?) async throws

    func createReminder(_ draft: ReminderDraft) async throws -> String
    func updateReminder(identifier: String, patch: ReminderPatch) async throws -> ReminderSummary
    /// `complete_reminder` is its own action because it sets `isCompleted` and
    /// `completionDate` together (SPEC §10). Returns the saved DTO.
    func setReminderCompleted(identifier: String, completed: Bool) async throws -> ReminderSummary
    func reminders(inCalendar calendarIdentifier: String) async throws -> [ReminderSummary]
    /// Reminders matching a filter, across lists. Its own query contract, not the events'
    /// one: most reminders have no due date, so a range is optional and, when given,
    /// undated reminders are still included unless excluded explicitly (SPEC §10).
    func listReminders(_ filter: ReminderFilter) async throws -> [ReminderSummary]
    /// One page of `listReminders(filter)`, plus the total. Same contract as `queryEvents`.
    func queryReminders(_ filter: ReminderFilter, offset: Int, limit: Int) async throws -> QueryPage<ReminderSummary>
    func reminder(withIdentifier identifier: String) async throws -> ReminderSummary?
    func deleteReminder(identifier: String) async throws

    /// Whether an item with this identifier currently resolves. Crash recovery (SPEC §9.6)
    /// uses it to decide whether a mid-flight mutation reached its expected state. Returns
    /// `false` rather than throwing when access is missing — the caller (`Reconciler`)
    /// checks authorization itself and does not probe at all when it is absent.
    func itemExists(identifier: String, entityType: RCCEntityType) async -> Bool

    /// Register for external calendar/reminder changes (`EKEventStoreChanged`, SPEC §7.4).
    /// `onChange` fires whenever another process (Calendar.app, a sync) mutates the store.
    /// Returns a token the caller must retain; releasing it removes the observer. The
    /// in-memory fake never fires (nothing external can change it).
    @discardableResult
    func observeStoreChanges(_ onChange: @escaping @Sendable () -> Void) -> AnyObject?
}

public extension CalendarRepository {
    /// The reference implementation: everything converted, then filtered and sliced.
    func queryEvents(_ query: EventQuery) async throws -> QueryPage<EventSummary> {
        let all = try await listEvents(
            calendarIdentifiers: query.calendarIdentifiers, from: query.from, to: query.to
        ).filter(query.matches)
        return QueryPage(slicing: all, offset: query.offset, limit: query.limit)
    }

    func queryReminders(_ filter: ReminderFilter, offset: Int, limit: Int) async throws -> QueryPage<ReminderSummary> {
        QueryPage(slicing: try await listReminders(filter), offset: offset, limit: limit)
    }

    func event(withIdentifier identifier: String) async throws -> EventSummary? {
        try await event(withIdentifier: identifier, occurrenceDate: nil)
    }

    func deleteEvent(identifier: String) async throws {
        try await deleteEvent(identifier: identifier, occurrenceDate: nil, scope: nil)
    }

    @discardableResult
    func observeStoreChanges(_ onChange: @escaping @Sendable () -> Void) -> AnyObject? { nil }
}

public enum RCCEntityType: String, Sendable, CaseIterable {
    case event
    case reminder

    public var displayName: String {
        switch self {
        case .event: return "Calendar"
        case .reminder: return "Reminders"
        }
    }
}

/// Mirrors `EKAuthorizationStatus`, plus the raw value so a case Apple adds in a future
/// OS stays representable instead of being coerced into an existing one (SPEC §9.1).
public struct RCCAuthorizationStatus: Sendable, Equatable {
    public enum Known: String, Sendable {
        case notDetermined
        case restricted
        case denied
        /// Legacy full-access spelling still reported by some EventKit versions.
        case authorized
        case fullAccess
        case writeOnly
        case unknown
    }

    public let known: Known
    public let rawValue: Int

    public init(known: Known, rawValue: Int) {
        self.known = known
        self.rawValue = rawValue
    }

    /// Only `fullAccess` (or the legacy `authorized`) lets `rcc` do its job. `writeOnly`
    /// is explicitly insufficient: the whole point is reading and writing (SPEC §6.3).
    public var grantsFullAccess: Bool {
        known == .fullAccess || known == .authorized
    }

    public var errorCode: RCCExitCode? {
        switch known {
        case .fullAccess, .authorized: return nil
        case .notDetermined: return .permission
        case .denied, .restricted, .writeOnly, .unknown: return .permission
        }
    }

    public var description: String { "\(known.rawValue) (raw \(rawValue))" }
}

public struct SourceSummary: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    /// Normalised `EKSourceType` name.
    public let sourceType: String
    /// The raw `EKSourceType` value, preserved so an unrecognised future case is still
    /// reportable (SPEC §9.1's both-name-and-raw-value rule).
    public let sourceTypeRawValue: Int
    /// True when the source represents a delegated/shared calendar account
    /// (`EKSource.isDelegate`, macOS 13+, read-only).
    public var isDelegate: Bool

    public init(
        id: String, title: String, sourceType: String, sourceTypeRawValue: Int,
        isDelegate: Bool = false
    ) {
        self.id = id
        self.title = title
        self.sourceType = sourceType
        self.sourceTypeRawValue = sourceTypeRawValue
        self.isDelegate = isDelegate
    }
}

public struct CalendarSummary: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let allowsContentModifications: Bool
    public let isSubscribed: Bool
    public let isImmutable: Bool
    public let allowedEntityTypes: Set<RCCEntityType>
    public let sourceIdentifier: String?
    public let sourceTitle: String?
    /// `#rrggbb`, when EventKit reports a colour.
    public var colorHex: String?
    /// Normalised `EKCalendarType` name + raw value.
    public var type: EnumValue?
    /// `busy` / `free` / `tentative` / `unavailable` names the calendar's source supports.
    public var supportedEventAvailabilities: [String]
    /// EventKit's default destination for new items of this calendar's type
    /// (`defaultCalendarForNewEvents` / `defaultCalendarForNewReminders()`). Reported so a
    /// caller can choose it *explicitly* — rcc never falls back to it implicitly (SPEC §10).
    public var isDefault: Bool = false

    public init(
        id: String,
        title: String,
        allowsContentModifications: Bool,
        isSubscribed: Bool,
        isImmutable: Bool,
        allowedEntityTypes: Set<RCCEntityType>,
        sourceIdentifier: String?,
        sourceTitle: String?,
        colorHex: String? = nil,
        type: EnumValue? = nil,
        supportedEventAvailabilities: [String] = []
    ) {
        self.id = id
        self.title = title
        self.allowsContentModifications = allowsContentModifications
        self.isSubscribed = isSubscribed
        self.isImmutable = isImmutable
        self.allowedEntityTypes = allowedEntityTypes
        self.sourceIdentifier = sourceIdentifier
        self.sourceTitle = sourceTitle
        self.colorHex = colorHex
        self.type = type
        self.supportedEventAvailabilities = supportedEventAvailabilities
    }

    public var isWritable: Bool { allowsContentModifications && !isImmutable }
}

/// Everything a new event can carry. Only the calendar, title, and start/end are
/// required; the rest default to EventKit's own defaults (SPEC §9.1).
public struct EventDraft: Sendable, Equatable {
    public var calendarIdentifier: String
    public var title: String
    public var start: Date
    public var end: Date
    public var notes: String?
    public var isAllDay: Bool
    /// IANA identifier; `nil` uses the system zone (a floating event is not offered).
    public var timeZoneIdentifier: String?
    public var location: String?
    public var url: String?
    /// busy / free / tentative / unavailable.
    public var availability: String?
    public var recurrenceRules: [RecurrenceRule]
    public var alarms: [AlarmSpec]

    public init(
        calendarIdentifier: String, title: String, start: Date, end: Date, notes: String? = nil,
        isAllDay: Bool = false, timeZoneIdentifier: String? = nil, location: String? = nil,
        url: String? = nil, availability: String? = nil,
        recurrenceRules: [RecurrenceRule] = [], alarms: [AlarmSpec] = []
    ) {
        self.calendarIdentifier = calendarIdentifier
        self.title = title
        self.start = start
        self.end = end
        self.notes = notes
        self.isAllDay = isAllDay
        self.timeZoneIdentifier = timeZoneIdentifier
        self.location = location
        self.url = url
        self.availability = availability
        self.recurrenceRules = recurrenceRules
        self.alarms = alarms
    }
}

/// The event DTO (SPEC §9.1). One shape; the MCP layer projects it down to a compact set
/// of fields for list results and returns the whole thing from `get_event` (SPEC §10, §13).
public struct EventSummary: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public let calendarIdentifier: String

    public var isAllDay: Bool
    /// IANA identifier of the event's own time zone, when it has one.
    public var timeZoneIdentifier: String?
    public var location: String?
    public var structuredLocation: GeoLocation?
    public var notes: String?
    public var url: String?
    /// confirmed / tentative / canceled / none. Only `canceled` is reliably reported
    /// across sources (Apple's own caveat).
    public var status: EnumValue?
    /// busy / free / tentative / unavailable / notSupported.
    public var availability: EnumValue?
    public var isRecurring: Bool
    /// A modified single instance detached from its series.
    public var isDetached: Bool
    public var occurrenceDate: Date?
    public var recurrenceRules: [RecurrenceRule]
    public var alarms: [Alarm]
    public var participants: [Participant]
    public var organizer: Participant?
    public var birthdayContactIdentifier: String?
    public var created: Date?
    public var lastModified: Date?
    public var sourceIdentifier: String?
    /// Content hash for `if_match` (SPEC §9.4). Populated by the repository.
    public var version: String

    public init(
        id: String, title: String, start: Date, end: Date, calendarIdentifier: String,
        isAllDay: Bool = false, timeZoneIdentifier: String? = nil, location: String? = nil,
        structuredLocation: GeoLocation? = nil, notes: String? = nil, url: String? = nil,
        status: EnumValue? = nil, availability: EnumValue? = nil,
        isRecurring: Bool = false, isDetached: Bool = false, occurrenceDate: Date? = nil,
        recurrenceRules: [RecurrenceRule] = [], alarms: [Alarm] = [],
        participants: [Participant] = [], organizer: Participant? = nil,
        birthdayContactIdentifier: String? = nil, created: Date? = nil, lastModified: Date? = nil,
        sourceIdentifier: String? = nil, version: String = ""
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.calendarIdentifier = calendarIdentifier
        self.isAllDay = isAllDay
        self.timeZoneIdentifier = timeZoneIdentifier
        self.location = location
        self.structuredLocation = structuredLocation
        self.notes = notes
        self.url = url
        self.status = status
        self.availability = availability
        self.isRecurring = isRecurring
        self.isDetached = isDetached
        self.occurrenceDate = occurrenceDate
        self.recurrenceRules = recurrenceRules
        self.alarms = alarms
        self.participants = participants
        self.organizer = organizer
        self.birthdayContactIdentifier = birthdayContactIdentifier
        self.created = created
        self.lastModified = lastModified
        self.sourceIdentifier = sourceIdentifier
        self.version = version
    }

    /// The fields that go into the `if_match` version. Order is fixed; every field a
    /// mutation could change is here (SPEC §9.4).
    public var contentFields: [(String, String)] {
        [
            ("title", title),
            ("start", RCCTime.instant(start)),
            ("end", RCCTime.instant(end)),
            ("allDay", isAllDay ? "1" : "0"),
            ("tz", timeZoneIdentifier ?? ""),
            ("location", location ?? ""),
            ("notes", notes ?? ""),
            ("url", url ?? ""),
            ("availability", availability?.name ?? ""),
            ("recurrence", recurrenceRules.map(\.canonicalString).joined(separator: "|")),
            ("alarms", alarms.map(\.canonicalString).sorted().joined(separator: ",")),
            ("calendar", calendarIdentifier),
        ]
    }
}

/// A bounded event query with its non-EventKit filters and the page wanted (SPEC §10).
public struct EventQuery: Sendable, Equatable {
    public var calendarIdentifiers: [String]?
    public var from: Date
    public var to: Date
    /// Matched against title and location (and notes, with `searchNotes`).
    public var text: String?
    public var searchNotes: Bool
    /// Matched against participant and organizer name, email, or URL.
    public var attendee: String?
    public var offset: Int
    public var limit: Int

    public init(
        calendarIdentifiers: [String]? = nil, from: Date, to: Date, text: String? = nil,
        searchNotes: Bool = false, attendee: String? = nil, offset: Int = 0, limit: Int = .max
    ) {
        self.calendarIdentifiers = calendarIdentifiers
        self.from = from
        self.to = to
        self.text = text
        self.searchNotes = searchNotes
        self.attendee = attendee
        self.offset = offset
        self.limit = limit
    }

    /// The post-fetch filters, applied before paging so page boundaries do not shift
    /// under a text filter (SPEC §10). Reads only title, location, notes, and
    /// participants — an adapter need load nothing else to evaluate it.
    public func matches(_ event: EventSummary) -> Bool {
        if let text {
            var haystack = "\(event.title)\n\(event.location ?? "")"
            if searchNotes { haystack += "\n\(event.notes ?? "")" }
            if !haystack.localizedCaseInsensitiveContains(text) { return false }
        }
        if let attendee {
            let people = event.participants + [event.organizer].compactMap { $0 }
            let hit = people.contains { participant in
                [participant.name, participant.email, participant.url]
                    .compactMap { $0 }
                    .contains { $0.localizedCaseInsensitiveContains(attendee) }
            }
            if !hit { return false }
        }
        return true
    }
}

/// A page of results and the size of the whole match.
public struct QueryPage<Item: Sendable>: Sendable {
    public var items: [Item]
    public var totalMatched: Int

    public init(items: [Item], totalMatched: Int) {
        self.items = items
        self.totalMatched = totalMatched
    }

    public init(slicing all: [Item], offset: Int, limit: Int) {
        self.init(items: Array(all[pageRange(count: all.count, offset: offset, limit: limit)]),
                  totalMatched: all.count)
    }
}

/// The indices of one page of `count` items, clamped — usable on arrays of non-`Sendable`
/// EventKit objects inside an adapter.
public func pageRange(count: Int, offset: Int, limit: Int) -> Range<Int> {
    let start = min(max(0, offset), count)
    let end = limit >= count - start ? count : start + max(0, limit)
    return start..<end
}

/// Filter for `list_reminders` / `search_reminders` (SPEC §10).
public struct ReminderFilter: Sendable, Equatable {
    public enum Completion: String, Sendable, CaseIterable { case any, incomplete, completed }

    public var calendarIdentifiers: [String]?
    public var completion: Completion
    /// Completion-date lower/upper bound, applied only to completed reminders.
    public var completedFrom: Date?
    public var completedTo: Date?
    /// Due/start component range. `nil` bounds are open. When a bound is set, undated
    /// reminders are still returned unless `includeUndated` is false.
    public var dueFrom: Date?
    public var dueTo: Date?
    public var includeUndated: Bool
    /// Free-text match over title (and, when the caller opts in, notes).
    public var text: String?
    public var searchNotes: Bool
    /// Keep only reminders whose priority bucket is at least this (`high` > `medium` > `low`).
    public var minimumPriorityBucket: ReminderPriorityBucket?
    /// Keep only reminders due in this window, evaluated at `now` in the local zone.
    public var dueWindow: ReminderDueWindow?
    public var now: Date = Date()

    public init(
        calendarIdentifiers: [String]? = nil,
        completion: Completion = .any,
        completedFrom: Date? = nil,
        completedTo: Date? = nil,
        dueFrom: Date? = nil,
        dueTo: Date? = nil,
        includeUndated: Bool = true,
        text: String? = nil,
        searchNotes: Bool = false,
        minimumPriorityBucket: ReminderPriorityBucket? = nil
    ) {
        self.calendarIdentifiers = calendarIdentifiers
        self.completion = completion
        self.completedFrom = completedFrom
        self.completedTo = completedTo
        self.dueFrom = dueFrom
        self.dueTo = dueTo
        self.includeUndated = includeUndated
        self.text = text
        self.searchNotes = searchNotes
        self.minimumPriorityBucket = minimumPriorityBucket
    }
}

extension ReminderFilter {
    /// Every filter the reminder contract defines, evaluated on a DTO (SPEC §10). Reads
    /// only list, completion, title/notes, priority, and due — never alarms or rules — so
    /// an adapter can evaluate it before paying for a full conversion.
    public func matches(_ reminder: ReminderSummary) -> Bool {
        if let calendarIdentifiers, !calendarIdentifiers.contains(reminder.calendarIdentifier) { return false }
        switch completion {
        case .any: break
        case .incomplete: if reminder.isCompleted { return false }
        case .completed:
            if !reminder.isCompleted { return false }
            if let completedFrom, (reminder.completionDate ?? .distantPast) < completedFrom { return false }
            if let completedTo, (reminder.completionDate ?? .distantFuture) > completedTo { return false }
        }
        if let text, !text.isEmpty {
            let haystack = searchNotes ? "\(reminder.title)\n\(reminder.notes ?? "")" : reminder.title
            if !haystack.localizedCaseInsensitiveContains(text) { return false }
        }
        if let minimumPriorityBucket,
           ReminderPriorityBucket(raw: reminder.priorityRaw).rank < minimumPriorityBucket.rank {
            return false
        }
        if dueFrom != nil || dueTo != nil {
            guard let due = reminder.dueDate?.resolvedDate() else { return includeUndated }
            if let dueFrom, due < dueFrom { return false }
            if let dueTo, due > dueTo { return false }
        }
        if let dueWindow, !dueWindow.matches(reminder.dueDate, now: now) { return false }
        return true
    }

    /// The documented, stable order (SPEC §10): incomplete before completed, then due date
    /// with undated last, then title, then identifier.
    public static func precedes(_ lhs: ReminderSummary, _ rhs: ReminderSummary) -> Bool {
        func key(_ r: ReminderSummary) -> (Int, Double, String, String) {
            (r.isCompleted ? 1 : 0, r.dueDate?.resolvedDate()?.timeIntervalSince1970 ?? .greatestFiniteMagnitude,
             r.title, r.id)
        }
        return key(lhs) < key(rhs)
    }
}

/// Everything a new reminder can carry. Only the list and title are required (SPEC §9.2).
public struct ReminderDraft: Sendable, Equatable {
    public var calendarIdentifier: String
    public var title: String
    public var notes: String?
    public var url: String?
    public var location: String?
    /// EventKit's raw 0–9 scale (1 high, 5 medium, 9 low, 0 none).
    public var priorityRaw: Int
    public var dueDate: ReminderDate?
    public var startDate: ReminderDate?
    /// IANA identifier for a timed due/start; `nil` uses the system zone.
    public var timeZoneIdentifier: String?
    /// EventKit needs a due date for a recurring reminder; the executor checks.
    public var recurrenceRules: [RecurrenceRule]
    /// `nil` applies the default: a timed due date gets an alert at that time, the way
    /// Reminders.app does it. `[]` means "no alerts", explicitly.
    public var alarms: [AlarmSpec]?

    public init(
        calendarIdentifier: String, title: String, notes: String? = nil, url: String? = nil,
        location: String? = nil, priorityRaw: Int = 0, dueDate: ReminderDate? = nil,
        startDate: ReminderDate? = nil, timeZoneIdentifier: String? = nil,
        recurrenceRules: [RecurrenceRule] = [], alarms: [AlarmSpec]? = nil
    ) {
        self.calendarIdentifier = calendarIdentifier
        self.title = title
        self.notes = notes
        self.url = url
        self.location = location
        self.priorityRaw = priorityRaw
        self.dueDate = dueDate
        self.startDate = startDate
        self.timeZoneIdentifier = timeZoneIdentifier
        self.recurrenceRules = recurrenceRules
        self.alarms = alarms
    }
}

/// The reminder DTO (SPEC §9.2). No native subtask support — a permanent parity gap
/// versus the Reminders app (confirmed against Apple's docs).
public struct ReminderSummary: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let isCompleted: Bool
    public let calendarIdentifier: String

    public var notes: String?
    public var url: String?
    public var location: String?
    public var timeZoneIdentifier: String?
    /// Preserves date-only vs date+time vs floating granularity (SPEC §9.5).
    public var dueDate: DateComponentsDTO?
    public var startDate: DateComponentsDTO?
    public var completionDate: Date?
    /// EventKit's raw 0–9 priority, always retained.
    public var priorityRaw: Int
    /// 1–4 high, 5 medium, 6–9 low, 0 none.
    public var priorityBucket: String
    public var recurrenceRules: [RecurrenceRule]
    public var alarms: [Alarm]
    public var created: Date?
    public var lastModified: Date?
    public var sourceIdentifier: String?
    public var version: String

    public init(
        id: String, title: String, isCompleted: Bool, calendarIdentifier: String,
        notes: String? = nil, url: String? = nil, location: String? = nil,
        timeZoneIdentifier: String? = nil, dueDate: DateComponentsDTO? = nil,
        startDate: DateComponentsDTO? = nil, completionDate: Date? = nil,
        priorityRaw: Int = 0, priorityBucket: String = "none",
        recurrenceRules: [RecurrenceRule] = [], alarms: [Alarm] = [],
        created: Date? = nil, lastModified: Date? = nil, sourceIdentifier: String? = nil,
        version: String = ""
    ) {
        self.id = id
        self.title = title
        self.isCompleted = isCompleted
        self.calendarIdentifier = calendarIdentifier
        self.notes = notes
        self.url = url
        self.location = location
        self.timeZoneIdentifier = timeZoneIdentifier
        self.dueDate = dueDate
        self.startDate = startDate
        self.completionDate = completionDate
        self.priorityRaw = priorityRaw
        self.priorityBucket = priorityBucket
        self.recurrenceRules = recurrenceRules
        self.alarms = alarms
        self.created = created
        self.lastModified = lastModified
        self.sourceIdentifier = sourceIdentifier
        self.version = version
    }

    public var contentFields: [(String, String)] {
        [
            ("title", title),
            ("completed", isCompleted ? "1" : "0"),
            ("notes", notes ?? ""),
            ("url", url ?? ""),
            ("location", location ?? ""),
            ("due", dueDate?.canonicalString ?? ""),
            ("start", startDate?.canonicalString ?? ""),
            ("priority", String(priorityRaw)),
            ("recurrence", recurrenceRules.map(\.canonicalString).joined(separator: "|")),
            ("alarms", alarms.map(\.canonicalString).sorted().joined(separator: ",")),
            ("calendar", calendarIdentifier),
        ]
    }
}

/// Failures the repository can surface, mapped onto SPEC §10.1's error taxonomy.
public enum CalendarRepositoryError: Error, CustomStringConvertible {
    case notAuthorized(RCCEntityType, RCCAuthorizationStatus)
    case notFound(String)
    case readOnly(String)
    case unsupported(String)
    /// A well-formed request with a value EventKit cannot use (an unknown time zone, say).
    case invalidArgument(String)
    /// Carries the underlying EventKit error so provider-specific failures stay
    /// diagnosable instead of collapsing into one generic code (SPEC §10.1).
    case native(String, underlying: NSError)

    public var description: String {
        switch self {
        case .notAuthorized(let entity, let status):
            return "Not authorized for \(entity.displayName): \(status.description)"
        case .notFound(let what):
            return "Not found: \(what)"
        case .readOnly(let what):
            return "Read-only: \(what)"
        case .unsupported(let what):
            return "Unsupported: \(what)"
        case .invalidArgument(let what):
            return what
        case .native(let context, let underlying):
            return "\(context): \(underlying.domain) \(underlying.code) — \(underlying.localizedDescription)"
        }
    }

    /// Stable error code from SPEC §10.1.
    public var code: String {
        switch self {
        case .notAuthorized(_, let status):
            switch status.known {
            case .notDetermined: return "permission_not_determined"
            case .restricted: return "permission_restricted"
            default: return "permission_denied"
            }
        case .notFound: return "not_found"
        case .readOnly: return "read_only"
        case .unsupported: return "unsupported"
        case .invalidArgument: return "invalid_argument"
        case .native: return "internal"
        }
    }

    /// EventKit's own domain/code, surfaced verbatim where we have it (SPEC §10.1).
    public var nativeError: [String: Any]? {
        guard case .native(_, let underlying) = self else { return nil }
        return ["domain": underlying.domain, "code": underlying.code]
    }
}
