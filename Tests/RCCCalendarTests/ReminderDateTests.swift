import Foundation
import Testing

@testable import RCCCalendar
@testable import RCCCore

@Suite("ReminderDate, due windows, and alert defaults")
struct ReminderDateTests {
    private let vancouver = TimeZone(identifier: "America/Vancouver")!

    private func instant(_ string: String) -> Date { RCCTime.parse(string)! }

    @Test("A bare date is a day; RFC 3339 is an instant; nonsense is neither")
    func parsing() {
        #expect(ReminderDate(parsing: "2026-10-05") == .day(year: 2026, month: 10, day: 5))
        #expect(ReminderDate(parsing: "2026-10-05T09:00:00-07:00") == .instant(instant("2026-10-05T16:00:00Z")))
        #expect(ReminderDate(parsing: "2026-13-05") == nil)
        #expect(ReminderDate(parsing: "next tuesday") == nil)
    }

    @Test("A day stores no time and no zone, so it reads back as granularity 'date'")
    func dayComponents() {
        let dto = DateComponentsDTO(ReminderDate.day(year: 2026, month: 10, day: 5).dateComponents(zone: vancouver))
        #expect(dto.granularity == "date")
        #expect(dto.hour == nil && dto.timeZoneIdentifier == nil)
    }

    @Test("An instant is stored as wall-clock time in the reminder's zone")
    func instantComponents() {
        let dto = DateComponentsDTO(
            ReminderDate.instant(instant("2026-10-05T16:00:00Z")).dateComponents(zone: vancouver)
        )
        #expect(dto.granularity == "datetime")
        #expect(dto.hour == 9 && dto.day == 5 && dto.timeZoneIdentifier == "America/Vancouver")
    }

    @Test("Due windows follow Reminders.app: a day-only reminder is not overdue on its day")
    func dueWindows() {
        let now = instant("2026-10-03T19:00:00Z")  // 12:00 in Vancouver
        func day(_ d: Int) -> DateComponentsDTO {
            DateComponentsDTO(year: 2026, month: 10, day: d, hour: nil, minute: nil, second: nil, timeZoneIdentifier: nil)
        }
        func at(_ iso: String) -> DateComponentsDTO {
            DateComponentsDTO(ReminderDate.instant(instant(iso)).dateComponents(zone: vancouver))
        }
        let check = { (window: ReminderDueWindow, due: DateComponentsDTO?) in
            window.matches(due, now: now, zone: self.vancouver)
        }

        #expect(!check(.overdue, day(3)))           // due today, day-only
        #expect(check(.today, day(3)))
        #expect(check(.overdue, day(2)))            // yesterday
        #expect(!check(.today, day(2)))
        #expect(check(.overdueOrToday, day(2)) && check(.overdueOrToday, day(3)))
        #expect(!check(.overdueOrToday, day(4)))

        let thisMorning = at("2026-10-03T16:00:00Z") // 09:00 local, already past
        #expect(check(.overdue, thisMorning) && check(.today, thisMorning))
        let tonight = at("2026-10-04T03:00:00Z")     // 20:00 local
        #expect(!check(.overdue, tonight) && check(.today, tonight))

        #expect(check(.next7Days, day(9)) && !check(.next7Days, day(10)) && !check(.next7Days, day(2)))
        #expect(!check(.overdueOrToday, nil))        // undated never matches a window
    }

    @Test("A new timed reminder alerts at its due time; a day-only one does not")
    func newReminderAlerts() {
        let due = instant("2026-10-05T16:00:00Z")
        #expect(ReminderAlertDefaults.forNewReminder(due: .instant(due)) == [.absolute(due)])
        #expect(ReminderAlertDefaults.forNewReminder(due: .day(year: 2026, month: 10, day: 5)).isEmpty)
        #expect(ReminderAlertDefaults.forNewReminder(due: nil).isEmpty)
    }

    @Test("On reschedule an alert tracking the due time moves with it; the user's own alerts stay")
    func rescheduleAlerts() {
        let old = instant("2026-10-05T16:00:00Z")
        let new = instant("2026-10-06T16:00:00Z")
        func absolute(_ date: Date) -> Alarm {
            Alarm(type: EnumValue(name: "display", raw: 0), relativeOffset: nil, absoluteDate: date,
                  structuredLocation: nil, proximity: nil)
        }
        let relative = Alarm(type: EnumValue(name: "display", raw: 0), relativeOffset: -600,
                             absoluteDate: nil, structuredLocation: nil, proximity: nil)

        // Tracking alert follows.
        #expect(ReminderAlertDefaults.afterDueChange(oldDue: old, newDue: .instant(new), current: [absolute(old)])
                == [.absolute(new)])
        // Rescheduled to a day: the tracking alert goes, nothing replaces it.
        #expect(ReminderAlertDefaults.afterDueChange(
            oldDue: old, newDue: .day(year: 2026, month: 10, day: 6), current: [absolute(old)]) == [])
        // No alerts, now timed: one is added.
        #expect(ReminderAlertDefaults.afterDueChange(oldDue: nil, newDue: .instant(new), current: []) == [.absolute(new)])
        // A relative alert is the user's; leave everything alone.
        #expect(ReminderAlertDefaults.afterDueChange(oldDue: old, newDue: .instant(new), current: [relative]) == nil)
        // A location alert can't be rewritten; leave everything alone.
        let geo = Alarm(type: EnumValue(name: "display", raw: 0), relativeOffset: nil, absoluteDate: nil,
                        structuredLocation: GeoLocation(title: "Home", latitude: 49, longitude: -123),
                        proximity: EnumValue(name: "enter", raw: 1))
        #expect(ReminderAlertDefaults.afterDueChange(oldDue: old, newDue: .instant(new), current: [absolute(old), geo]) == nil)
    }
}

@Suite("Event listing")
struct EventListingTests {
    @Test("Occurrences of one series are distinct rows; a seam duplicate is not")
    func occurrenceKey() {
        let monday = RCCTime.parse("2026-10-12T16:00:00Z")!
        let tuesday = monday.addingTimeInterval(86400)
        func occurrence(_ date: Date) -> EventSummary {
            EventSummary(id: "series", title: "Standup", start: date, end: date.addingTimeInterval(900),
                         calendarIdentifier: "cal", isRecurring: true, occurrenceDate: date)
        }
        #expect(EventKitRepository.occurrenceKey(occurrence(monday)) != EventKitRepository.occurrenceKey(occurrence(tuesday)))
        #expect(EventKitRepository.occurrenceKey(occurrence(monday)) == EventKitRepository.occurrenceKey(occurrence(monday)))
    }
}
