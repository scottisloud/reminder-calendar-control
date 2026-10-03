import Foundation
import RCCCore

/// Deterministic stand-in for EventKit (SPEC §15).
///
/// Everything above `CalendarRepository` — setup flow, dev-fixture provisioning, the
/// read/write self-test, `rcc doctor`'s calendar checks — is unit-testable against this
/// without a TCC prompt, a real calendar, or a signed binary.
public actor InMemoryCalendarRepository: CalendarRepository {
    public struct Scenario: Sendable {
        public var eventStatus: RCCAuthorizationStatus
        public var reminderStatus: RCCAuthorizationStatus
        /// What a prompt would resolve to. `nil` means the prompt never resolves, which
        /// is how the headless fast-fail path (SPEC §8.1) gets exercised.
        public var promptOutcome: RCCAuthorizationStatus?
        /// Injected failure for the next mutating call, to exercise error handling.
        public var nextWriteFailure: CalendarRepositoryError?

        public init(
            eventStatus: RCCAuthorizationStatus = .notDetermined,
            reminderStatus: RCCAuthorizationStatus = .notDetermined,
            promptOutcome: RCCAuthorizationStatus? = .fullAccess,
            nextWriteFailure: CalendarRepositoryError? = nil
        ) {
            self.eventStatus = eventStatus
            self.reminderStatus = reminderStatus
            self.promptOutcome = promptOutcome
            self.nextWriteFailure = nextWriteFailure
        }
    }

    private var scenario: Scenario
    private var storedSources: [SourceSummary]
    private var storedCalendars: [String: CalendarSummary] = [:]
    private var storedEvents: [String: EventSummary] = [:]
    private var storedReminders: [String: ReminderSummary] = [:]
    private var nextIdentifier = 0

    /// Incremented by `reset()` so tests can assert the store really was recreated after
    /// an authorization change (SPEC §6.2).
    public private(set) var resetCount = 0
    /// The fake keeps one row per series, so it records which occurrence and scope a
    /// mutation targeted for tests to assert on, rather than modelling expansion.
    public private(set) var lastTargetedOccurrence: Date?
    public private(set) var lastEventScope: RecurrenceScope?

    public init(scenario: Scenario = Scenario(), sources: [SourceSummary]? = nil) {
        self.scenario = scenario
        self.storedSources = sources ?? [
            SourceSummary(id: "src-icloud", title: "iCloud", sourceType: "calDAV", sourceTypeRawValue: 2),
            SourceSummary(id: "src-local", title: "On My Mac", sourceType: "local", sourceTypeRawValue: 0),
        ]
    }

    public func setScenario(_ scenario: Scenario) { self.scenario = scenario }

    // MARK: - Authorization

    public func authorizationStatus(for entityType: RCCEntityType) async -> RCCAuthorizationStatus {
        switch entityType {
        case .event: return scenario.eventStatus
        case .reminder: return scenario.reminderStatus
        }
    }

    public func requestFullAccess(for entityType: RCCEntityType) async throws -> RCCAuthorizationStatus {
        let current = await authorizationStatus(for: entityType)
        // A prompt only ever appears from `.notDetermined`; every other state is
        // terminal until the user changes it in System Settings.
        guard current.known == .notDetermined else { return current }
        guard let outcome = scenario.promptOutcome else {
            throw CalendarRepositoryError.notAuthorized(entityType, current)
        }
        switch entityType {
        case .event: scenario.eventStatus = outcome
        case .reminder: scenario.reminderStatus = outcome
        }
        return outcome
    }

    public func reset() async {
        resetCount += 1
    }

    // MARK: - Sources & calendars

    public func sources() async throws -> [SourceSummary] { storedSources }

    public func calendars(for entityType: RCCEntityType) async throws -> [CalendarSummary] {
        try requireAccess(entityType)
        return storedCalendars.values
            .filter { $0.allowedEntityTypes.contains(entityType) }
            .sorted { $0.id < $1.id }
    }

    public func calendar(withIdentifier identifier: String, entityType: RCCEntityType) async throws -> CalendarSummary? {
        try requireAccess(entityType)
        guard let calendar = storedCalendars[identifier],
              calendar.allowedEntityTypes.contains(entityType) else { return nil }
        return calendar
    }

    public func createCalendar(
        title: String,
        entityType: RCCEntityType,
        sourceIdentifier: String
    ) async throws -> CalendarSummary {
        try requireAccess(entityType)
        try consumeInjectedFailure()
        guard let source = storedSources.first(where: { $0.id == sourceIdentifier }) else {
            throw CalendarRepositoryError.notFound("source \(sourceIdentifier)")
        }
        let calendar = CalendarSummary(
            id: mintIdentifier("cal"),
            title: title,
            allowsContentModifications: true,
            isSubscribed: false,
            isImmutable: false,
            allowedEntityTypes: [entityType],
            sourceIdentifier: source.id,
            sourceTitle: source.title
        )
        storedCalendars[calendar.id] = calendar
        return calendar
    }

    public func deleteCalendar(identifier: String, entityType: RCCEntityType) async throws {
        try requireAccess(entityType)
        try consumeInjectedFailure()
        guard let calendar = storedCalendars[identifier] else {
            throw CalendarRepositoryError.notFound("calendar \(identifier)")
        }
        guard calendar.isWritable else {
            throw CalendarRepositoryError.readOnly("calendar \(identifier)")
        }
        storedCalendars.removeValue(forKey: identifier)
        storedEvents = storedEvents.filter { $0.value.calendarIdentifier != identifier }
        storedReminders = storedReminders.filter { $0.value.calendarIdentifier != identifier }
    }

    public func calendarExists(identifier: String) async -> Bool {
        storedCalendars[identifier] != nil
    }

    // MARK: - Reminder lists

    public func createReminderList(
        title: String, sourceIdentifier: String
    ) async throws -> CalendarSummary {
        try requireAccess(.reminder)
        try consumeInjectedFailure()
        guard let source = storedSources.first(where: { $0.id == sourceIdentifier }) else {
            throw CalendarRepositoryError.notFound("source \(sourceIdentifier)")
        }
        let calendar = CalendarSummary(
            id: mintIdentifier("list"), title: title, allowsContentModifications: true,
            isSubscribed: false, isImmutable: false, allowedEntityTypes: [.reminder],
            sourceIdentifier: source.id, sourceTitle: source.title
        )
        storedCalendars[calendar.id] = calendar
        return calendar
    }

    public func updateReminderList(
        identifier: String, title: String
    ) async throws -> CalendarSummary {
        try requireAccess(.reminder)
        try consumeInjectedFailure()
        let current = try reminderOnlyCalendar(identifier)
        let updated = CalendarSummary(
            id: current.id, title: title, allowsContentModifications: current.allowsContentModifications,
            isSubscribed: current.isSubscribed, isImmutable: current.isImmutable,
            allowedEntityTypes: current.allowedEntityTypes,
            sourceIdentifier: current.sourceIdentifier, sourceTitle: current.sourceTitle
        )
        storedCalendars[identifier] = updated
        return updated
    }

    public func deleteReminderList(identifier: String) async throws -> Int {
        try requireAccess(.reminder)
        try consumeInjectedFailure()
        let calendar = try reminderOnlyCalendar(identifier)
        guard !calendar.isImmutable else {
            throw CalendarRepositoryError.readOnly("reminder list \(identifier)")
        }
        let removed = storedReminders.values.filter { $0.calendarIdentifier == identifier }.count
        storedCalendars.removeValue(forKey: identifier)
        storedReminders = storedReminders.filter { $0.value.calendarIdentifier != identifier }
        return removed
    }

    private func reminderOnlyCalendar(_ identifier: String) throws -> CalendarSummary {
        guard let calendar = storedCalendars[identifier] else {
            throw CalendarRepositoryError.notFound("reminder list \(identifier)")
        }
        guard calendar.allowedEntityTypes == [.reminder] else {
            throw CalendarRepositoryError.unsupported(
                "\(identifier) is not a reminder-only calendar"
            )
        }
        return calendar
    }

    // MARK: - Events

    public func createEvent(_ draft: EventDraft) async throws -> String {
        try requireAccess(.event)
        try consumeInjectedFailure()
        let calendar = try writableCalendar(draft.calendarIdentifier, entityType: .event)
        if let zone = draft.timeZoneIdentifier, TimeZone(identifier: zone) == nil {
            throw CalendarRepositoryError.invalidArgument("unknown time zone '\(zone)'")
        }
        var event = EventSummary(
            id: mintIdentifier("evt"),
            title: draft.title,
            start: draft.start,
            end: draft.end,
            calendarIdentifier: calendar.id,
            isAllDay: draft.isAllDay,
            timeZoneIdentifier: draft.timeZoneIdentifier ?? TimeZone.current.identifier,
            location: draft.location,
            notes: draft.notes,
            url: draft.url,
            availability: draft.availability.map { EnumValue(name: $0, raw: -1) },
            isRecurring: !draft.recurrenceRules.isEmpty,
            recurrenceRules: draft.recurrenceRules,
            alarms: draft.alarms.map(Self.alarm),
            sourceIdentifier: calendar.sourceIdentifier
        )
        event.version = ContentVersion.make(event.contentFields)
        storedEvents[event.id] = event
        return event.id
    }

    public func events(inCalendar calendarIdentifier: String, from: Date, to: Date) async throws -> [EventSummary] {
        try requireAccess(.event)
        return storedEvents.values
            .filter { $0.calendarIdentifier == calendarIdentifier && $0.end > from && $0.start < to }
            .sorted { $0.start < $1.start }
    }

    public func updateEvent(
        identifier: String, occurrenceDate: Date?, patch: EventPatch, scope: RecurrenceScope?
    ) async throws -> EventSummary {
        try requireAccess(.event)
        try consumeInjectedFailure()
        guard let current = storedEvents[identifier] else {
            throw CalendarRepositoryError.notFound("event \(identifier)")
        }
        lastTargetedOccurrence = occurrenceDate
        lastEventScope = scope
        var calendarID = current.calendarIdentifier
        if case .set(let target) = patch.calendarIdentifier {
            calendarID = try writableCalendar(target, entityType: .event).id
        }
        var event = EventSummary(
            id: current.id,
            title: patch.title.isChange ? (patch.title.resolved(from: current.title) ?? "") : current.title,
            start: { if case .set(let value) = patch.start { return value } else { return current.start } }(),
            end: { if case .set(let value) = patch.end { return value } else { return current.end } }(),
            calendarIdentifier: calendarID
        )
        event.isAllDay = { if case .set(let value) = patch.isAllDay { return value } else { return current.isAllDay } }()
        event.location = patch.location.resolved(from: current.location)
        event.notes = patch.notes.resolved(from: current.notes)
        event.url = patch.url.resolved(from: current.url)
        event.timeZoneIdentifier = patch.timeZoneIdentifier.resolved(from: current.timeZoneIdentifier)
        event.availability = { if case .set(let name) = patch.availability {
            return EnumValue(name: name, raw: -1)
        } else { return current.availability } }()
        event.recurrenceRules = patch.recurrenceRules.resolved(from: current.recurrenceRules) ?? []
        event.isRecurring = !event.recurrenceRules.isEmpty
        event.alarms = patch.alarms.isChange
            ? (patch.alarms.resolved(from: nil) ?? []).map(Self.alarm) : current.alarms
        event.occurrenceDate = current.occurrenceDate
        event.sourceIdentifier = current.sourceIdentifier
        event.version = ContentVersion.make(event.contentFields)
        storedEvents[identifier] = event
        return event
    }

    public func listEvents(
        calendarIdentifiers: [String]?, from: Date, to: Date
    ) async throws -> [EventSummary] {
        try requireAccess(.event)
        let allowed = calendarIdentifiers.map(Set.init)
        return storedEvents.values
            .filter { event in
                (allowed?.contains(event.calendarIdentifier) ?? true)
                    && event.end > from && event.start < to
            }
            .sorted { ($0.start, $0.id) < ($1.start, $1.id) }
    }

    public func event(withIdentifier identifier: String, occurrenceDate: Date?) async throws -> EventSummary? {
        try requireAccess(.event)
        return storedEvents[identifier]
    }

    public func deleteEvent(
        identifier: String, occurrenceDate: Date?, scope: RecurrenceScope?
    ) async throws {
        try requireAccess(.event)
        try consumeInjectedFailure()
        lastTargetedOccurrence = occurrenceDate
        lastEventScope = scope
        guard storedEvents.removeValue(forKey: identifier) != nil else {
            throw CalendarRepositoryError.notFound("event \(identifier)")
        }
    }

    // MARK: - Reminders

    public func createReminder(_ draft: ReminderDraft) async throws -> String {
        try requireAccess(.reminder)
        try consumeInjectedFailure()
        let calendar = try writableCalendar(draft.calendarIdentifier, entityType: .reminder)
        let zoneName = draft.timeZoneIdentifier ?? TimeZone.current.identifier
        guard let zone = TimeZone(identifier: zoneName) else {
            throw CalendarRepositoryError.invalidArgument("unknown time zone '\(zoneName)'")
        }
        let alarms = draft.alarms ?? ReminderAlertDefaults.forNewReminder(due: draft.dueDate)
        var reminder = ReminderSummary(
            id: mintIdentifier("rem"),
            title: draft.title,
            isCompleted: false,
            calendarIdentifier: calendar.id,
            notes: draft.notes,
            url: draft.url,
            location: draft.location,
            timeZoneIdentifier: zoneName,
            dueDate: draft.dueDate.map { DateComponentsDTO($0.dateComponents(zone: zone)) },
            startDate: draft.startDate.map { DateComponentsDTO($0.dateComponents(zone: zone)) },
            priorityRaw: max(0, min(9, draft.priorityRaw)),
            priorityBucket: ReminderPriorityBucket(raw: draft.priorityRaw).rawValue,
            recurrenceRules: draft.recurrenceRules,
            alarms: alarms.map(Self.alarm),
            sourceIdentifier: calendar.sourceIdentifier
        )
        reminder.version = ContentVersion.make(reminder.contentFields)
        storedReminders[reminder.id] = reminder
        return reminder.id
    }

    public func reminders(inCalendar calendarIdentifier: String) async throws -> [ReminderSummary] {
        try requireAccess(.reminder)
        return storedReminders.values
            .filter { $0.calendarIdentifier == calendarIdentifier }
            .sorted { $0.id < $1.id }
    }

    public func updateReminder(
        identifier: String, patch: ReminderPatch
    ) async throws -> ReminderSummary {
        try requireAccess(.reminder)
        try consumeInjectedFailure()
        guard let current = storedReminders[identifier] else {
            throw CalendarRepositoryError.notFound("reminder \(identifier)")
        }
        var calendarID = current.calendarIdentifier
        if case .set(let target) = patch.calendarIdentifier {
            calendarID = try writableCalendar(target, entityType: .reminder).id
        }
        var reminder = ReminderSummary(
            id: current.id,
            title: patch.title.isChange ? (patch.title.resolved(from: current.title) ?? "") : current.title,
            isCompleted: current.isCompleted,
            calendarIdentifier: calendarID
        )
        reminder.notes = patch.notes.resolved(from: current.notes)
        reminder.url = patch.url.resolved(from: current.url)
        reminder.location = patch.location.resolved(from: current.location)
        reminder.timeZoneIdentifier = current.timeZoneIdentifier
        if case .set(let value) = patch.priorityRaw {
            reminder.priorityRaw = max(0, min(9, value))
        } else {
            reminder.priorityRaw = current.priorityRaw
        }
        reminder.priorityBucket = ReminderPriorityBucket(raw: reminder.priorityRaw).rawValue
        let zone = current.timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .current
        reminder.dueDate = dateComponents(patch.dueDate, current: current.dueDate, zone: zone)
        reminder.startDate = dateComponents(patch.startDate, current: current.startDate, zone: zone)
        reminder.completionDate = current.completionDate
        reminder.recurrenceRules = patch.recurrenceRules.resolved(from: current.recurrenceRules) ?? []
        reminder.alarms = patch.alarms.isChange
            ? (patch.alarms.resolved(from: nil) ?? []).map(Self.alarm) : current.alarms
        reminder.sourceIdentifier = current.sourceIdentifier
        reminder.version = ContentVersion.make(reminder.contentFields)
        storedReminders[identifier] = reminder
        return reminder
    }

    private func dateComponents(
        _ patch: FieldPatch<ReminderDate>, current: DateComponentsDTO?, zone: TimeZone
    ) -> DateComponentsDTO? {
        switch patch {
        case .unchanged: return current
        case .clear: return nil
        case .set(let value): return DateComponentsDTO(value.dateComponents(zone: zone))
        }
    }

    private static func advance(_ due: DateComponentsDTO, by rule: RecurrenceRule) -> DateComponentsDTO {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = due.timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .current
        guard let date = due.resolvedDate(defaultZone: calendar.timeZone) else { return due }
        let component: Calendar.Component = switch rule.frequency {
        case .daily: .day
        case .weekly: .weekOfYear
        case .monthly: .month
        case .yearly: .year
        }
        let next = calendar.date(byAdding: component, value: max(1, rule.interval), to: date) ?? date
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: next)
        let hasTime = due.hour != nil
        return DateComponentsDTO(
            year: parts.year, month: parts.month, day: parts.day,
            hour: hasTime ? parts.hour : nil, minute: hasTime ? parts.minute : nil,
            second: hasTime ? parts.second : nil, timeZoneIdentifier: due.timeZoneIdentifier
        )
    }

    /// The read DTO EventKit would report for a written alarm (a display alarm).
    static func alarm(_ spec: AlarmSpec) -> Alarm {
        switch spec {
        case .relative(let offset):
            return Alarm(type: EnumValue(name: "display", raw: 0), relativeOffset: offset,
                         absoluteDate: nil, structuredLocation: nil, proximity: nil)
        case .absolute(let date):
            return Alarm(type: EnumValue(name: "display", raw: 0), relativeOffset: nil,
                         absoluteDate: date, structuredLocation: nil, proximity: nil)
        }
    }

    public func setReminderCompleted(
        identifier: String, completed: Bool
    ) async throws -> ReminderSummary {
        try requireAccess(.reminder)
        try consumeInjectedFailure()
        guard let current = storedReminders[identifier] else {
            throw CalendarRepositoryError.notFound("reminder \(identifier)")
        }
        // EventKit's behaviour for a repeating reminder, modelled: the completed occurrence
        // becomes a new, completed reminder, and this one advances to its next due date and
        // stays incomplete. (Simplified to frequency × interval from the current due.)
        if completed, let rule = current.recurrenceRules.first, let due = current.dueDate {
            var done = ReminderSummary(
                id: mintIdentifier("rem"), title: current.title, isCompleted: true,
                calendarIdentifier: current.calendarIdentifier, notes: current.notes,
                dueDate: current.dueDate, completionDate: Date(), priorityRaw: current.priorityRaw,
                priorityBucket: current.priorityBucket, sourceIdentifier: current.sourceIdentifier
            )
            done.version = ContentVersion.make(done.contentFields)
            storedReminders[done.id] = done

            var advanced = current
            advanced.dueDate = Self.advance(due, by: rule)
            advanced.version = ContentVersion.make(advanced.contentFields)
            storedReminders[identifier] = advanced
            return advanced
        }
        var reminder = ReminderSummary(
            id: current.id, title: current.title, isCompleted: completed,
            calendarIdentifier: current.calendarIdentifier
        )
        reminder.notes = current.notes
        reminder.url = current.url
        reminder.location = current.location
        reminder.timeZoneIdentifier = current.timeZoneIdentifier
        reminder.dueDate = current.dueDate
        reminder.startDate = current.startDate
        reminder.priorityRaw = current.priorityRaw
        reminder.priorityBucket = current.priorityBucket
        reminder.recurrenceRules = current.recurrenceRules
        reminder.alarms = current.alarms
        reminder.sourceIdentifier = current.sourceIdentifier
        reminder.completionDate = completed ? Date() : nil
        reminder.version = ContentVersion.make(reminder.contentFields)
        storedReminders[identifier] = reminder
        return reminder
    }

    public func listReminders(_ filter: ReminderFilter) async throws -> [ReminderSummary] {
        try requireAccess(.reminder)
        return storedReminders.values.filter(filter.matches).sorted(by: ReminderFilter.precedes)
    }

    public func reminder(withIdentifier identifier: String) async throws -> ReminderSummary? {
        try requireAccess(.reminder)
        return storedReminders[identifier]
    }

    public func deleteReminder(identifier: String) async throws {
        try requireAccess(.reminder)
        try consumeInjectedFailure()
        guard storedReminders.removeValue(forKey: identifier) != nil else {
            throw CalendarRepositoryError.notFound("reminder \(identifier)")
        }
    }

    public func itemExists(identifier: String, entityType: RCCEntityType) async -> Bool {
        switch entityType {
        case .event: return storedEvents[identifier] != nil
        case .reminder: return storedReminders[identifier] != nil
        }
    }

    // MARK: - Helpers

    private func requireAccess(_ entityType: RCCEntityType) throws {
        let status: RCCAuthorizationStatus
        switch entityType {
        case .event: status = scenario.eventStatus
        case .reminder: status = scenario.reminderStatus
        }
        guard status.grantsFullAccess else {
            throw CalendarRepositoryError.notAuthorized(entityType, status)
        }
    }

    private func writableCalendar(_ identifier: String, entityType: RCCEntityType) throws -> CalendarSummary {
        guard let calendar = storedCalendars[identifier] else {
            throw CalendarRepositoryError.notFound("calendar \(identifier)")
        }
        guard calendar.allowedEntityTypes.contains(entityType) else {
            throw CalendarRepositoryError.unsupported(
                "calendar \(identifier) does not accept \(entityType.rawValue) items"
            )
        }
        guard calendar.isWritable else {
            throw CalendarRepositoryError.readOnly("calendar \(identifier)")
        }
        return calendar
    }

    private func consumeInjectedFailure() throws {
        guard let failure = scenario.nextWriteFailure else { return }
        scenario.nextWriteFailure = nil
        throw failure
    }

    private func mintIdentifier(_ prefix: String) -> String {
        nextIdentifier += 1
        return "\(prefix)-\(nextIdentifier)"
    }

    /// Test affordance: seed a calendar that is not writable, to exercise the guards.
    public func insert(calendar: CalendarSummary) { storedCalendars[calendar.id] = calendar }

    /// Test affordance: seed an event (e.g. a recurring one) with a chosen identifier.
    public func insert(event: EventSummary) {
        var stored = event
        stored.version = ContentVersion.make(stored.contentFields)
        storedEvents[event.id] = stored
    }

    /// Test affordance: seed a reminder with a chosen identifier.
    public func insert(reminder: ReminderSummary) {
        var stored = reminder
        stored.version = ContentVersion.make(stored.contentFields)
        storedReminders[reminder.id] = stored
    }
}

extension RCCAuthorizationStatus {
    public static let notDetermined = RCCAuthorizationStatus(known: .notDetermined, rawValue: 0)
    public static let restricted = RCCAuthorizationStatus(known: .restricted, rawValue: 1)
    public static let denied = RCCAuthorizationStatus(known: .denied, rawValue: 2)
    public static let fullAccess = RCCAuthorizationStatus(known: .fullAccess, rawValue: 3)
    public static let writeOnly = RCCAuthorizationStatus(known: .writeOnly, rawValue: 4)
}
