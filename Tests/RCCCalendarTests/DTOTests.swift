import Foundation
import Testing

@testable import RCCCalendar
@testable import RCCCore

@Suite("DTO value logic")
struct DTOTests {
    @Test("DateComponentsDTO reports the right granularity")
    func dateComponentsGranularity() {
        var dateOnly = DateComponents()
        dateOnly.year = 2026; dateOnly.month = 9; dateOnly.day = 10
        #expect(DateComponentsDTO(dateOnly).granularity == "date")

        var floating = dateOnly
        floating.hour = 9; floating.minute = 30
        #expect(DateComponentsDTO(floating).granularity == "floating")

        var zoned = floating
        zoned.timeZone = TimeZone(identifier: "America/Toronto")
        #expect(DateComponentsDTO(zoned).granularity == "datetime")
        #expect(DateComponentsDTO(zoned).timeZoneIdentifier == "America/Toronto")
    }

    @Test("Reminder priority buckets follow the 1-4 / 5 / 6-9 / 0 split")
    func priorityBuckets() {
        #expect(ReminderPriorityBucket(raw: 0) == .none)
        #expect(ReminderPriorityBucket(raw: 1) == .high)
        #expect(ReminderPriorityBucket(raw: 4) == .high)
        #expect(ReminderPriorityBucket(raw: 5) == .medium)
        #expect(ReminderPriorityBucket(raw: 6) == .low)
        #expect(ReminderPriorityBucket(raw: 9) == .low)
    }

    @Test("An event's version moves when a mutable field changes, and only then")
    func eventVersionSensitivity() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var event = EventSummary(
            id: "e1", title: "Standup", start: start, end: start.addingTimeInterval(1800),
            calendarIdentifier: "cal-1"
        )
        event.version = ContentVersion.make(event.contentFields)
        let original = event.version

        // A field that isn't content — the identifier — must not change the version.
        var sameContent = event
        sameContent.lastModified = Date()
        sameContent.version = ContentVersion.make(sameContent.contentFields)
        #expect(sameContent.version == original)

        // A real change does.
        var retitled = event
        retitled = EventSummary(
            id: "e1", title: "Sync", start: start, end: start.addingTimeInterval(1800),
            calendarIdentifier: "cal-1"
        )
        retitled.version = ContentVersion.make(retitled.contentFields)
        #expect(retitled.version != original)
    }

    @Test("Recurrence in the version: same rule → same version regardless of list order")
    func recurrenceInVersion() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        func event(_ rule: RecurrenceRule) -> String {
            var e = EventSummary(
                id: "e", title: "Weekly", start: start, end: start.addingTimeInterval(3600),
                calendarIdentifier: "c", recurrenceRules: [rule]
            )
            e.version = ContentVersion.make(e.contentFields)
            return e.version
        }
        let a = event(RecurrenceRule(
            frequency: .weekly, interval: 1, daysOfWeek: [.init(weekday: 2), .init(weekday: 4)]
        ))
        let b = event(RecurrenceRule(
            frequency: .weekly, interval: 1, daysOfWeek: [.init(weekday: 4), .init(weekday: 2)]
        ))
        #expect(a == b)
    }

    @Test("Fake-created events and reminders carry a non-empty version")
    func fakePopulatesVersion() async throws {
        let repo = InMemoryCalendarRepository(
            scenario: .init(eventStatus: .fullAccess, reminderStatus: .fullAccess)
        )
        await repo.insert(calendar: CalendarSummary(
            id: "cal-1", title: "Dev", allowsContentModifications: true, isSubscribed: false,
            isImmutable: false, allowedEntityTypes: [.event, .reminder],
            sourceIdentifier: "src", sourceTitle: "On My Mac"
        ))
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await repo.createEvent(EventDraft(
            calendarIdentifier: "cal-1", title: "x", start: start, end: start.addingTimeInterval(60)
        ))
        let events = try await repo.events(inCalendar: "cal-1", from: start.addingTimeInterval(-60), to: start.addingTimeInterval(120))
        #expect(events.count == 1)
        #expect(events[0].version.count == 64)

        _ = try await repo.createReminder(ReminderDraft(calendarIdentifier: "cal-1", title: "y"))
        let reminders = try await repo.reminders(inCalendar: "cal-1")
        #expect(reminders.count == 1)
        #expect(reminders[0].version.count == 64)
    }

    @Test("EnumValue keeps the raw value alongside the name")
    func enumValue() {
        let v = EnumValue(name: "canceled", raw: 3)
        #expect(v.name == "canceled")
        #expect(v.raw == 3)
    }
}
