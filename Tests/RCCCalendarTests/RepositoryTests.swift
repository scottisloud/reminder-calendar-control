import EventKit
import Foundation
import Testing

@testable import RCCCalendar
@testable import RCCCore

@Suite("In-memory repository")
struct InMemoryRepositoryTests {
    @Test("Reads and writes are refused until full access is granted")
    func gatesOnAuthorization() async throws {
        let repository = InMemoryCalendarRepository()
        await #expect(throws: CalendarRepositoryError.self) {
            _ = try await repository.calendars(for: .event)
        }
        _ = try await repository.requestFullAccess(for: .event)
        _ = try await repository.calendars(for: .event)
    }

    /// A prompt only ever appears from `.notDetermined`; every other state is terminal
    /// until the user changes it in System Settings.
    @Test("A denied grant is never re-prompted")
    func doesNotRepromptWhenDenied() async throws {
        let repository = InMemoryCalendarRepository(
            scenario: .init(eventStatus: .denied, promptOutcome: .fullAccess)
        )
        let status = try await repository.requestFullAccess(for: .event)
        #expect(status.known == .denied)
    }

    /// The headless case: a LaunchAgent where no prompt can render must fail, not hang.
    @Test("A prompt that can never resolve surfaces as an error")
    func unresolvablePromptThrows() async throws {
        let repository = InMemoryCalendarRepository(scenario: .init(promptOutcome: nil))
        await #expect(throws: CalendarRepositoryError.self) {
            _ = try await repository.requestFullAccess(for: .event)
        }
    }

    @Test("Write-only access does not count as full access")
    func writeOnlyIsInsufficient() async throws {
        let repository = InMemoryCalendarRepository(scenario: .init(eventStatus: .writeOnly))
        #expect(!RCCAuthorizationStatus.writeOnly.grantsFullAccess)
        await #expect(throws: CalendarRepositoryError.self) {
            _ = try await repository.calendars(for: .event)
        }
    }

    @Test("Events round-trip through create, read, and delete")
    func eventRoundTrip() async throws {
        let repository = InMemoryCalendarRepository(scenario: .init(eventStatus: .fullAccess))
        let calendar = try await repository.createCalendar(
            title: "Fixture", entityType: .event, sourceIdentifier: "src-local"
        )
        let now = Date()
        let identifier = try await repository.createEvent(
            EventDraft(
                calendarIdentifier: calendar.id, title: "Standup",
                start: now.addingTimeInterval(60), end: now.addingTimeInterval(3600)
            )
        )
        let found = try await repository.events(
            inCalendar: calendar.id, from: now, to: now.addingTimeInterval(86400)
        )
        #expect(found.map(\.id) == [identifier])

        try await repository.deleteEvent(identifier: identifier)
        #expect(try await repository.events(
            inCalendar: calendar.id, from: now, to: now.addingTimeInterval(86400)
        ).isEmpty)
    }

    @Test("Reminders round-trip through create, read, and delete")
    func reminderRoundTrip() async throws {
        let repository = InMemoryCalendarRepository(scenario: .init(reminderStatus: .fullAccess))
        let calendar = try await repository.createCalendar(
            title: "Fixture", entityType: .reminder, sourceIdentifier: "src-local"
        )
        let identifier = try await repository.createReminder(
            ReminderDraft(calendarIdentifier: calendar.id, title: "Buy milk")
        )
        #expect(try await repository.reminders(inCalendar: calendar.id).map(\.id) == [identifier])
        try await repository.deleteReminder(identifier: identifier)
        #expect(try await repository.reminders(inCalendar: calendar.id).isEmpty)
    }

    @Test("A read-only calendar refuses writes")
    func rejectsReadOnlyCalendar() async throws {
        let repository = InMemoryCalendarRepository(scenario: .init(eventStatus: .fullAccess))
        await repository.insert(calendar: CalendarSummary(
            id: "subscribed", title: "Holidays", allowsContentModifications: false,
            isSubscribed: true, isImmutable: true, allowedEntityTypes: [.event],
            sourceIdentifier: "src-local", sourceTitle: "On My Mac"
        ))
        await #expect(throws: CalendarRepositoryError.self) {
            _ = try await repository.createEvent(EventDraft(
                calendarIdentifier: "subscribed", title: "nope", start: Date(), end: Date()
            ))
        }
    }

    @Test("An event calendar refuses reminders")
    func rejectsWrongEntityType() async throws {
        let repository = InMemoryCalendarRepository(
            scenario: .init(eventStatus: .fullAccess, reminderStatus: .fullAccess)
        )
        let calendar = try await repository.createCalendar(
            title: "Events only", entityType: .event, sourceIdentifier: "src-local"
        )
        await #expect(throws: CalendarRepositoryError.self) {
            _ = try await repository.createReminder(
                ReminderDraft(calendarIdentifier: calendar.id, title: "nope")
            )
        }
    }

    @Test("reset() is observable, so post-grant recreation can be asserted")
    func resetIsObservable() async {
        let repository = InMemoryCalendarRepository()
        #expect(await repository.resetCount == 0)
        await repository.reset()
        #expect(await repository.resetCount == 1)
    }
}

@Suite("Authorization status mapping")
struct AuthorizationMappingTests {
    /// Raw values are pinned deliberately: they appear in `doctor --json` and in the
    /// acceptance harness, and a silent renumbering would go unnoticed.
    @Test("EventKit statuses map to both a name and their raw value")
    func mapsKnownCases() {
        #expect(EventKitRepository.map(.notDetermined) == RCCAuthorizationStatus(known: .notDetermined, rawValue: 0))
        #expect(EventKitRepository.map(.restricted) == RCCAuthorizationStatus(known: .restricted, rawValue: 1))
        #expect(EventKitRepository.map(.denied) == RCCAuthorizationStatus(known: .denied, rawValue: 2))
        #expect(EventKitRepository.map(.fullAccess) == RCCAuthorizationStatus(known: .fullAccess, rawValue: 3))
        #expect(EventKitRepository.map(.writeOnly) == RCCAuthorizationStatus(known: .writeOnly, rawValue: 4))
    }

    /// `.authorized` is a deprecated alias for `.fullAccess` with the same raw value, so
    /// code that branches on it silently misreads a `.writeOnly` grant.
    @Test("Only full access unlocks the tool")
    func onlyFullAccessCounts() {
        #expect(EventKitRepository.map(.fullAccess).grantsFullAccess)
        #expect(!EventKitRepository.map(.writeOnly).grantsFullAccess)
        #expect(!EventKitRepository.map(.notDetermined).grantsFullAccess)
        #expect(!EventKitRepository.map(.denied).grantsFullAccess)
    }

    @Test("Source type names cover every case EventKit defines on macOS 26")
    func mapsSourceTypes() {
        #expect(EventKitRepository.name(for: .local) == "local")
        #expect(EventKitRepository.name(for: .exchange) == "exchange")
        // A Google account added through Internet Accounts is expected here; that mapping
        // is an inference until confirmed against a live account (SPEC §8.2).
        #expect(EventKitRepository.name(for: .calDAV) == "calDAV")
        #expect(EventKitRepository.name(for: .mobileMe) == "mobileMe")
        #expect(EventKitRepository.name(for: .subscribed) == "subscribed")
        #expect(EventKitRepository.name(for: .birthdays) == "birthdays")
    }

    @Test("Repository errors carry SPEC §10.1's stable codes")
    func mapsErrorCodes() {
        #expect(CalendarRepositoryError.notFound("x").code == "not_found")
        #expect(CalendarRepositoryError.readOnly("x").code == "read_only")
        #expect(CalendarRepositoryError.unsupported("x").code == "unsupported")
        #expect(
            CalendarRepositoryError.notAuthorized(.event, .notDetermined).code == "permission_not_determined"
        )
        #expect(CalendarRepositoryError.notAuthorized(.event, .denied).code == "permission_denied")
        #expect(CalendarRepositoryError.notAuthorized(.event, .restricted).code == "permission_restricted")
    }

    @Test("A native EventKit error keeps its domain and code")
    func preservesNativeError() throws {
        let underlying = NSError(domain: EKErrorDomain, code: EKError.Code.calendarIsImmutable.rawValue)
        let error = CalendarRepositoryError.native("saving", underlying: underlying)
        let native = try #require(error.nativeError)
        #expect(native["domain"] as? String == "EKErrorDomain")
        #expect(native["code"] as? Int == 16)
    }
}
