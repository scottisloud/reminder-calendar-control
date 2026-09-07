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

    // MARK: - Events

    public func createEvent(_ draft: EventDraft) async throws -> String {
        try requireAccess(.event)
        try consumeInjectedFailure()
        let calendar = try writableCalendar(draft.calendarIdentifier, entityType: .event)
        var event = EventSummary(
            id: mintIdentifier("evt"),
            title: draft.title,
            start: draft.start,
            end: draft.end,
            calendarIdentifier: calendar.id,
            notes: draft.notes,
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

    public func deleteEvent(identifier: String) async throws {
        try requireAccess(.event)
        try consumeInjectedFailure()
        guard storedEvents.removeValue(forKey: identifier) != nil else {
            throw CalendarRepositoryError.notFound("event \(identifier)")
        }
    }

    // MARK: - Reminders

    public func createReminder(_ draft: ReminderDraft) async throws -> String {
        try requireAccess(.reminder)
        try consumeInjectedFailure()
        let calendar = try writableCalendar(draft.calendarIdentifier, entityType: .reminder)
        var reminder = ReminderSummary(
            id: mintIdentifier("rem"),
            title: draft.title,
            isCompleted: false,
            calendarIdentifier: calendar.id,
            notes: draft.notes,
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
}

extension RCCAuthorizationStatus {
    public static let notDetermined = RCCAuthorizationStatus(known: .notDetermined, rawValue: 0)
    public static let restricted = RCCAuthorizationStatus(known: .restricted, rawValue: 1)
    public static let denied = RCCAuthorizationStatus(known: .denied, rawValue: 2)
    public static let fullAccess = RCCAuthorizationStatus(known: .fullAccess, rawValue: 3)
    public static let writeOnly = RCCAuthorizationStatus(known: .writeOnly, rawValue: 4)
}
