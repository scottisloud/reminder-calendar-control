import EventKit
import Foundation
import RCCCore

/// The real EventKit adapter (SPEC §7.4).
///
/// An actor because `EKEventStore` is not `Sendable` and each process holds exactly one
/// (SPEC §7.4: one long-lived store per process, so `calaccessd`'s connection limit is
/// never a factor). Every `EKEvent`/`EKReminder`/`EKCalendar` is converted to a value DTO
/// before it crosses the actor boundary and never retained across calls — Apple documents
/// objects fetched before an `EKEventStoreChanged` as invalid afterwards.
public actor EventKitRepository: CalendarRepository {
    private var store = EKEventStore()

    public init() {}

    // MARK: - Authorization

    /// Never prompts, so it is safe to call from `rcc doctor` and from a LaunchAgent.
    public nonisolated func authorizationStatus(for entityType: RCCEntityType) async -> RCCAuthorizationStatus {
        Self.map(EKEventStore.authorizationStatus(for: entityType.ekEntityType))
    }

    /// Request full access. Only ever prompts from `.notDetermined`.
    ///
    /// Full access to both entity types is the only thing requested: `writeOnly` exists
    /// for events but not reminders, and would be useless here anyway (SPEC §6.3).
    /// The deprecated unified `requestAccess(to:)` is never called — it still exists on
    /// the macOS 26 SDK but is the legacy single-class request.
    public func requestFullAccess(for entityType: RCCEntityType) async throws -> RCCAuthorizationStatus {
        let before = Self.map(EKEventStore.authorizationStatus(for: entityType.ekEntityType))
        guard before.known == .notDetermined else { return before }

        do {
            switch entityType {
            case .event: _ = try await store.requestFullAccessToEvents()
            case .reminder: _ = try await store.requestFullAccessToReminders()
            }
        } catch {
            // A thrown error here is not the same as "the user said no"; report the
            // resulting status and let the caller decide, but keep the native error.
            let after = Self.map(EKEventStore.authorizationStatus(for: entityType.ekEntityType))
            if after.grantsFullAccess {
                // Same reason as the success path: the store was built while authorization
                // was undetermined and must not be reused. Returning early here without the
                // reset was a real hole.
                await reset()
                return after
            }
            throw CalendarRepositoryError.native("requesting \(entityType.displayName) access", underlying: error as NSError)
        }

        // The store was created while authorization was undetermined, so it holds a
        // connection scoped to that state. Recreate it before it is used for anything real
        // (SPEC §6.2).
        await reset()
        return Self.map(EKEventStore.authorizationStatus(for: entityType.ekEntityType))
    }

    /// Replace the store outright rather than calling `reset()`.
    ///
    /// Both are valid, but a fresh instance makes it impossible to accidentally keep
    /// holding a pre-reset object — and passing an object from one store to another
    /// raises an Objective-C exception, which Swift cannot catch.
    public func reset() async {
        store = EKEventStore()
    }

    // MARK: - Sources & calendars

    public func sources() async throws -> [SourceSummary] {
        store.sources.map(Self.summarize(source:))
    }

    public func calendars(for entityType: RCCEntityType) async throws -> [CalendarSummary] {
        try requireFullAccess(entityType)
        return store.calendars(for: entityType.ekEntityType).map(Self.summarize(calendar:))
    }

    public func calendar(withIdentifier identifier: String, entityType: RCCEntityType) async throws -> CalendarSummary? {
        try requireFullAccess(entityType)
        guard let calendar = store.calendar(withIdentifier: identifier),
              calendar.allowedEntityTypes.contains(entityType.ekEntityMask)
        else { return nil }
        return Self.summarize(calendar: calendar)
    }

    public func createCalendar(
        title: String,
        entityType: RCCEntityType,
        sourceIdentifier: String
    ) async throws -> CalendarSummary {
        try requireFullAccess(entityType)
        guard let source = store.sources.first(where: { $0.sourceIdentifier == sourceIdentifier }) else {
            throw CalendarRepositoryError.notFound("source \(sourceIdentifier)")
        }
        let calendar = EKCalendar(for: entityType.ekEntityType, eventStore: store)
        calendar.title = title
        // `source` is settable only before the first save; after that a calendar cannot be
        // moved between sources.
        calendar.source = source
        do {
            try store.saveCalendar(calendar, commit: true)
        } catch {
            throw CalendarRepositoryError.native("creating calendar '\(title)'", underlying: error as NSError)
        }
        return Self.summarize(calendar: calendar)
    }

    /// Delete a calendar, refusing anything that holds more than the entity type asked for.
    ///
    /// EventKit's documented behaviour for a mixed-entity calendar when you hold only one
    /// authorization is to delete that entity type's items and *strip the bit* rather than
    /// delete the calendar — a silent half-success. Guarding on the exact allowed set is
    /// what turns that into a refusal (SPEC §9.3).
    public func deleteCalendar(identifier: String, entityType: RCCEntityType) async throws {
        try requireFullAccess(entityType)
        guard let calendar = store.calendar(withIdentifier: identifier) else {
            throw CalendarRepositoryError.notFound("calendar \(identifier)")
        }
        guard calendar.allowedEntityTypes == entityType.ekEntityMask else {
            throw CalendarRepositoryError.unsupported(
                "calendar \(identifier) holds more than \(entityType.rawValue) items; deleting it would "
                    + "silently remove only some of its contents"
            )
        }
        guard !calendar.isImmutable else {
            throw CalendarRepositoryError.readOnly("calendar \(identifier)")
        }
        do {
            try store.removeCalendar(calendar, commit: true)
        } catch {
            throw CalendarRepositoryError.native("deleting calendar \(identifier)", underlying: error as NSError)
        }
    }

    // MARK: - Events

    public func createEvent(_ draft: EventDraft) async throws -> String {
        try requireFullAccess(.event)
        let calendar = try writableCalendar(draft.calendarIdentifier, entityType: .event)
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = draft.title
        event.startDate = draft.start
        event.endDate = draft.end
        event.notes = draft.notes
        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            throw CalendarRepositoryError.native("creating event", underlying: error as NSError)
        }
        guard let identifier = event.eventIdentifier else {
            throw CalendarRepositoryError.unsupported("EventKit saved the event but issued no identifier")
        }
        return identifier
    }

    public func events(inCalendar calendarIdentifier: String, from: Date, to: Date) async throws -> [EventSummary] {
        try requireFullAccess(.event)
        guard let calendar = store.calendar(withIdentifier: calendarIdentifier) else {
            throw CalendarRepositoryError.notFound("calendar \(calendarIdentifier)")
        }
        // `predicateForEvents` silently truncates any range longer than four years. The
        // full chunking contract is Milestone 3's; Milestone 1 only ever asks for hours.
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: [calendar])
        return store.events(matching: predicate).compactMap(Self.summarize(event:))
    }

    public func deleteEvent(identifier: String) async throws {
        try requireFullAccess(.event)
        guard let event = store.event(withIdentifier: identifier) else {
            throw CalendarRepositoryError.notFound("event \(identifier)")
        }
        do {
            try store.remove(event, span: .thisEvent, commit: true)
        } catch {
            throw CalendarRepositoryError.native("deleting event \(identifier)", underlying: error as NSError)
        }
    }

    // MARK: - Reminders

    public func createReminder(_ draft: ReminderDraft) async throws -> String {
        try requireFullAccess(.reminder)
        let calendar = try writableCalendar(draft.calendarIdentifier, entityType: .reminder)
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = calendar
        reminder.title = draft.title
        reminder.notes = draft.notes
        do {
            try store.save(reminder, commit: true)
        } catch {
            throw CalendarRepositoryError.native("creating reminder", underlying: error as NSError)
        }
        return reminder.calendarItemIdentifier
    }

    public func reminders(inCalendar calendarIdentifier: String) async throws -> [ReminderSummary] {
        try requireFullAccess(.reminder)
        guard let calendar = store.calendar(withIdentifier: calendarIdentifier) else {
            throw CalendarRepositoryError.notFound("calendar \(calendarIdentifier)")
        }
        let predicate = store.predicateForReminders(in: [calendar])
        // Convert to DTOs *inside* the callback: `[EKReminder]` is not `Sendable`, and
        // letting it cross the continuation would be exactly the "retained across
        // requests" mistake SPEC §7.4 forbids.
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).map(Self.summarize(reminder:)))
            }
        }
    }

    public func deleteReminder(identifier: String) async throws {
        try requireFullAccess(.reminder)
        guard let reminder = store.calendarItem(withIdentifier: identifier) as? EKReminder else {
            throw CalendarRepositoryError.notFound("reminder \(identifier)")
        }
        do {
            try store.remove(reminder, commit: true)
        } catch {
            throw CalendarRepositoryError.native("deleting reminder \(identifier)", underlying: error as NSError)
        }
    }

    public func itemExists(identifier: String, entityType: RCCEntityType) async -> Bool {
        guard Self.map(EKEventStore.authorizationStatus(for: entityType.ekEntityType)).grantsFullAccess
        else { return false }
        switch entityType {
        case .event:
            return store.event(withIdentifier: identifier) != nil
        case .reminder:
            return (store.calendarItem(withIdentifier: identifier) as? EKReminder) != nil
        }
    }

    // MARK: - Source selection

    /// Pick a source for a tool-owned calendar.
    ///
    /// `.local` ("On My Mac") is preferred: a dev fixture has no business syncing to
    /// anyone's phone. Falling back to the default calendar's source is what makes this
    /// work on an iCloud-only Mac, where a local source may not exist for reminders.
    public func preferredSource(for entityType: RCCEntityType) async throws -> SourceSummary {
        try requireFullAccess(entityType)
        let all = store.sources

        // A Local source that already holds calendars of this entity type is the ideal:
        // it demonstrably accepts them, and it never syncs anywhere.
        if let local = all.first(where: {
            $0.sourceType == .local && !$0.calendars(for: entityType.ekEntityType).isEmpty
        }) {
            return Self.summarize(source: local)
        }
        // Then whatever EventKit itself would use, which is known-good for this entity type.
        // Deliberately ahead of "any Local source": on an iCloud-only Mac a Local source can
        // exist for events but reject reminders, and preferring it blindly would shadow a
        // working fallback with one that fails at save time.
        let defaultCalendar = entityType == .event
            ? store.defaultCalendarForNewEvents
            : store.defaultCalendarForNewReminders()
        if let source = defaultCalendar?.source {
            return Self.summarize(source: source)
        }
        if let usable = all.first(where: { !$0.calendars(for: entityType.ekEntityType).isEmpty }) {
            return Self.summarize(source: usable)
        }
        // Last resort: an empty Local source. It may reject the save, but a clear EventKit
        // error beats "no source found".
        if let local = all.first(where: { $0.sourceType == .local }) {
            return Self.summarize(source: local)
        }
        throw CalendarRepositoryError.notFound(
            "no EventKit source on this Mac accepts a new \(entityType.rawValue) calendar"
        )
    }

    // MARK: - Helpers

    private func requireFullAccess(_ entityType: RCCEntityType) throws {
        let status = Self.map(EKEventStore.authorizationStatus(for: entityType.ekEntityType))
        guard status.grantsFullAccess else {
            throw CalendarRepositoryError.notAuthorized(entityType, status)
        }
    }

    private func writableCalendar(_ identifier: String, entityType: RCCEntityType) throws -> EKCalendar {
        guard let calendar = store.calendar(withIdentifier: identifier) else {
            throw CalendarRepositoryError.notFound("calendar \(identifier)")
        }
        guard calendar.allowedEntityTypes.contains(entityType.ekEntityMask) else {
            throw CalendarRepositoryError.unsupported(
                "calendar \(identifier) does not accept \(entityType.rawValue) items"
            )
        }
        guard calendar.allowsContentModifications, !calendar.isImmutable else {
            throw CalendarRepositoryError.readOnly("calendar \(identifier)")
        }
        return calendar
    }

    // MARK: - DTO conversion

    /// Both the normalised name and the raw value, so a case Apple adds later stays
    /// representable rather than being coerced into an existing one (SPEC §9.1).
    static func map(_ status: EKAuthorizationStatus) -> RCCAuthorizationStatus {
        let known: RCCAuthorizationStatus.Known
        switch status {
        case .notDetermined: known = .notDetermined
        case .restricted: known = .restricted
        case .denied: known = .denied
        // `.authorized` is a deprecated alias with the same raw value as `.fullAccess`,
        // so it can never be matched separately here.
        case .fullAccess: known = .fullAccess
        case .writeOnly: known = .writeOnly
        @unknown default: known = .unknown
        }
        return RCCAuthorizationStatus(known: known, rawValue: Int(status.rawValue))
    }

    static func name(for sourceType: EKSourceType) -> String {
        switch sourceType {
        case .local: return "local"
        case .exchange: return "exchange"
        // A Google account added through Internet Accounts is expected to land here, but
        // that mapping is an inference until confirmed against a live account (SPEC §8.2).
        case .calDAV: return "calDAV"
        case .mobileMe: return "mobileMe"
        case .subscribed: return "subscribed"
        case .birthdays: return "birthdays"
        @unknown default: return "unknown"
        }
    }

    static func summarize(source: EKSource) -> SourceSummary {
        SourceSummary(
            id: source.sourceIdentifier,
            title: source.title,
            sourceType: name(for: source.sourceType),
            sourceTypeRawValue: Int(source.sourceType.rawValue),
            isDelegate: source.isDelegate
        )
    }

    static func summarize(calendar: EKCalendar) -> CalendarSummary {
        var allowed: Set<RCCEntityType> = []
        if calendar.allowedEntityTypes.contains(.event) { allowed.insert(.event) }
        if calendar.allowedEntityTypes.contains(.reminder) { allowed.insert(.reminder) }
        let mask = calendar.supportedEventAvailabilities
        let availabilities: [String] = [
            (EKCalendarEventAvailabilityMask.busy, "busy"),
            (.free, "free"),
            (.tentative, "tentative"),
            (.unavailable, "unavailable"),
        ].compactMap { mask.contains($0.0) ? $0.1 : nil }
        return CalendarSummary(
            id: calendar.calendarIdentifier,
            title: calendar.title,
            allowsContentModifications: calendar.allowsContentModifications,
            isSubscribed: calendar.isSubscribed,
            isImmutable: calendar.isImmutable,
            allowedEntityTypes: allowed,
            sourceIdentifier: calendar.source?.sourceIdentifier,
            sourceTitle: calendar.source?.title,
            colorHex: hexString(from: calendar.cgColor),
            type: EnumValue(name: calendarTypeName(calendar.type), raw: Int(calendar.type.rawValue)),
            supportedEventAvailabilities: availabilities
        )
    }

    static func summarize(event: EKEvent) -> EventSummary? {
        guard let identifier = event.eventIdentifier,
              let start = event.startDate,
              let end = event.endDate else { return nil }
        var dto = EventSummary(
            id: identifier,
            title: event.title ?? "",
            start: start,
            end: end,
            calendarIdentifier: event.calendar?.calendarIdentifier ?? "",
            isAllDay: event.isAllDay,
            timeZoneIdentifier: event.timeZone?.identifier,
            location: event.location,
            structuredLocation: geo(from: event.structuredLocation),
            notes: event.hasNotes ? event.notes : nil,
            url: event.url?.absoluteString,
            status: EnumValue(name: statusName(event.status), raw: Int(event.status.rawValue)),
            availability: EnumValue(
                name: availabilityName(for: event.availability), raw: Int(event.availability.rawValue)
            ),
            isRecurring: event.hasRecurrenceRules,
            isDetached: event.isDetached,
            occurrenceDate: event.occurrenceDate,
            recurrenceRules: (event.recurrenceRules ?? []).map(RecurrenceRule.init),
            alarms: (event.alarms ?? []).map(alarm(from:)),
            participants: (event.attendees ?? []).map { participant(from: $0) },
            organizer: event.organizer.map { participant(from: $0) },
            birthdayContactIdentifier: event.birthdayContactIdentifier,
            created: event.creationDate,
            lastModified: event.lastModifiedDate,
            sourceIdentifier: event.calendar?.source?.sourceIdentifier
        )
        dto.version = ContentVersion.make(dto.contentFields, lastModified: event.lastModifiedDate)
        return dto
    }

    static func summarize(reminder: EKReminder) -> ReminderSummary {
        var dto = ReminderSummary(
            id: reminder.calendarItemIdentifier,
            title: reminder.title ?? "",
            isCompleted: reminder.isCompleted,
            calendarIdentifier: reminder.calendar?.calendarIdentifier ?? "",
            notes: reminder.hasNotes ? reminder.notes : nil,
            url: reminder.url?.absoluteString,
            location: reminder.location,
            timeZoneIdentifier: reminder.timeZone?.identifier,
            dueDate: reminder.dueDateComponents.map(DateComponentsDTO.init),
            startDate: reminder.startDateComponents.map(DateComponentsDTO.init),
            completionDate: reminder.completionDate,
            priorityRaw: reminder.priority,
            priorityBucket: ReminderPriorityBucket(raw: reminder.priority).rawValue,
            recurrenceRules: (reminder.recurrenceRules ?? []).map(RecurrenceRule.init),
            alarms: (reminder.alarms ?? []).map(alarm(from:)),
            created: reminder.creationDate,
            lastModified: reminder.lastModifiedDate,
            sourceIdentifier: reminder.calendar?.source?.sourceIdentifier
        )
        dto.version = ContentVersion.make(dto.contentFields, lastModified: reminder.lastModifiedDate)
        return dto
    }

    // MARK: - Enum & value mapping

    static func statusName(_ status: EKEventStatus) -> String {
        switch status {
        case .none: return "none"
        case .confirmed: return "confirmed"
        case .tentative: return "tentative"
        case .canceled: return "canceled"
        @unknown default: return "unknown"
        }
    }

    static func availabilityName(for availability: EKEventAvailability) -> String {
        switch availability {
        case .notSupported: return "notSupported"
        case .busy: return "busy"
        case .free: return "free"
        case .tentative: return "tentative"
        case .unavailable: return "unavailable"
        @unknown default: return "unknown"
        }
    }

    static func calendarTypeName(_ type: EKCalendarType) -> String {
        switch type {
        case .local: return "local"
        case .calDAV: return "calDAV"
        case .exchange: return "exchange"
        case .subscription: return "subscription"
        case .birthday: return "birthday"
        @unknown default: return "unknown"
        }
    }

    static func participant(from participant: EKParticipant) -> Participant {
        let url = participant.url.absoluteString
        let email = url.lowercased().hasPrefix("mailto:") ? String(url.dropFirst("mailto:".count)) : nil
        return Participant(
            name: participant.name,
            url: url,
            email: email,
            isCurrentUser: participant.isCurrentUser,
            type: EnumValue(name: participantTypeName(participant.participantType),
                            raw: Int(participant.participantType.rawValue)),
            role: EnumValue(name: participantRoleName(participant.participantRole),
                            raw: Int(participant.participantRole.rawValue)),
            status: EnumValue(name: participantStatusName(participant.participantStatus),
                              raw: Int(participant.participantStatus.rawValue))
        )
    }

    static func participantTypeName(_ type: EKParticipantType) -> String {
        switch type {
        case .unknown: return "unknown"
        case .person: return "person"
        case .room: return "room"
        case .resource: return "resource"
        case .group: return "group"
        @unknown default: return "unknown"
        }
    }

    static func participantRoleName(_ role: EKParticipantRole) -> String {
        switch role {
        case .unknown: return "unknown"
        case .required: return "required"
        case .optional: return "optional"
        case .chair: return "chair"
        case .nonParticipant: return "nonParticipant"
        @unknown default: return "unknown"
        }
    }

    static func participantStatusName(_ status: EKParticipantStatus) -> String {
        switch status {
        case .unknown: return "unknown"
        case .pending: return "pending"
        case .accepted: return "accepted"
        case .declined: return "declined"
        case .tentative: return "tentative"
        case .delegated: return "delegated"
        case .completed: return "completed"
        case .inProcess: return "inProcess"
        @unknown default: return "unknown"
        }
    }

    static func alarm(from alarm: EKAlarm) -> Alarm {
        let typeName: String
        switch alarm.type {
        case .display: typeName = "display"
        case .audio: typeName = "audio"
        case .procedure: typeName = "procedure"
        case .email: typeName = "email"
        @unknown default: typeName = "unknown"
        }
        let proximity: EnumValue?
        switch alarm.proximity {
        case .none: proximity = nil
        case .enter: proximity = EnumValue(name: "enter", raw: Int(alarm.proximity.rawValue))
        case .leave: proximity = EnumValue(name: "leave", raw: Int(alarm.proximity.rawValue))
        @unknown default: proximity = EnumValue(name: "unknown", raw: Int(alarm.proximity.rawValue))
        }
        return Alarm(
            type: EnumValue(name: typeName, raw: Int(alarm.type.rawValue)),
            relativeOffset: alarm.absoluteDate == nil ? alarm.relativeOffset : nil,
            absoluteDate: alarm.absoluteDate,
            structuredLocation: geo(from: alarm.structuredLocation),
            proximity: proximity
        )
    }

    static func geo(from location: EKStructuredLocation?) -> GeoLocation? {
        guard let location else { return nil }
        let coordinate = location.geoLocation?.coordinate
        return GeoLocation(
            title: location.title,
            latitude: coordinate?.latitude,
            longitude: coordinate?.longitude,
            radius: location.radius == 0 ? nil : location.radius
        )
    }

    static func hexString(from color: CGColor?) -> String? {
        guard let color, let components = color.components, components.count >= 3 else { return nil }
        let r = Int((components[0] * 255).rounded())
        let g = Int((components[1] * 255).rounded())
        let b = Int((components[2] * 255).rounded())
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}

extension RCCEntityType {
    var ekEntityType: EKEntityType {
        switch self {
        case .event: return .event
        case .reminder: return .reminder
        }
    }

    var ekEntityMask: EKEntityMask {
        switch self {
        case .event: return .event
        case .reminder: return .reminder
        }
    }
}
