import Foundation
import RCCCore

/// The seam between `rcc` and EventKit (SPEC §15).
///
/// EventKit has no first-party in-memory store, so everything above this protocol is
/// testable against `InMemoryCalendarRepository` and real EventKit is reserved for
/// adapter/integration tests.
///
/// Milestone 1 deliberately keeps this surface small — enough to prove authorization,
/// provision the dev fixture, and round-trip one write. The full DTO model in SPEC §9
/// lands in Milestone 2 and will widen this protocol rather than replace it.
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

    func createEvent(_ draft: EventDraft) async throws -> String
    func events(inCalendar calendarIdentifier: String, from: Date, to: Date) async throws -> [EventSummary]
    /// Events across the given calendars (or every event calendar when `nil`) in a bounded
    /// window. A window longer than four years is walked in ≤4-year chunks — EventKit's
    /// predicate silently truncates one otherwise (SPEC §9.4/§10).
    func listEvents(calendarIdentifiers: [String]?, from: Date, to: Date) async throws -> [EventSummary]
    func event(withIdentifier identifier: String) async throws -> EventSummary?
    func deleteEvent(identifier: String) async throws

    func createReminder(_ draft: ReminderDraft) async throws -> String
    func reminders(inCalendar calendarIdentifier: String) async throws -> [ReminderSummary]
    /// Reminders matching a filter, across lists. Its own query contract, not the events'
    /// one: most reminders have no due date, so a range is optional and, when given,
    /// undated reminders are still included unless excluded explicitly (SPEC §10).
    func listReminders(_ filter: ReminderFilter) async throws -> [ReminderSummary]
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

public struct EventDraft: Sendable, Equatable {
    public let calendarIdentifier: String
    public let title: String
    public let start: Date
    public let end: Date
    public let notes: String?

    public init(calendarIdentifier: String, title: String, start: Date, end: Date, notes: String? = nil) {
        self.calendarIdentifier = calendarIdentifier
        self.title = title
        self.start = start
        self.end = end
        self.notes = notes
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
            ("alarms", alarms.map { "\($0.type.name):\($0.relativeOffset ?? 0)" }.sorted().joined(separator: ",")),
            ("calendar", calendarIdentifier),
        ]
    }
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

public struct ReminderDraft: Sendable, Equatable {
    public let calendarIdentifier: String
    public let title: String
    public let notes: String?

    public init(calendarIdentifier: String, title: String, notes: String? = nil) {
        self.calendarIdentifier = calendarIdentifier
        self.title = title
        self.notes = notes
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
        case .native: return "internal"
        }
    }

    /// EventKit's own domain/code, surfaced verbatim where we have it (SPEC §10.1).
    public var nativeError: [String: Any]? {
        guard case .native(_, let underlying) = self else { return nil }
        return ["domain": underlying.domain, "code": underlying.code]
    }
}
