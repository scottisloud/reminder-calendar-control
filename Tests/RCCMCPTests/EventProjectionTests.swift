import Foundation
import Testing

@testable import RCCCalendar
@testable import RCCCore
@testable import RCCMCP

@Suite("Event projection and ranges")
struct EventProjectionTests {
    private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!

    private func instant(_ iso: String) -> Date { RCCTime.parse(iso)! }

    private func event(
        _ start: String, _ end: String, allDay: Bool = false, timeZone: String? = nil,
        recurring: Bool = false, detached: Bool = false, occurrence: String? = nil
    ) -> EventSummary {
        EventSummary(
            id: "e1", title: "Event", start: instant(start), end: instant(end),
            calendarIdentifier: "cal", isAllDay: allDay, timeZoneIdentifier: timeZone,
            isRecurring: recurring, isDetached: detached, occurrenceDate: occurrence.map(instant)
        )
    }

    private func project(_ event: EventSummary) -> [String: Any] {
        ReadTools.project(event: event, detail: false, zone: losAngeles)
    }

    @Test("A timed event gets local times in the Mac's zone, not the event's own")
    func timedLocal() {
        let row = project(event("2026-10-06T14:00:00Z", "2026-10-06T15:00:00Z", timeZone: "America/New_York"))
        #expect(row["start_local"] as? String == "2026-10-06T07:00:00-07:00")
        #expect(row["end_local"] as? String == "2026-10-06T08:00:00-07:00")
        #expect(row["start"] as? String == "2026-10-06T14:00:00.000Z")
        #expect(row["time_zone"] as? String == "America/New_York")
        #expect(row["start_date"] == nil)
        #expect(row["spans_multiple_days"] as? Bool == false)
    }

    @Test("A multi-day all-day event has inclusive dates and is flagged")
    func multiDayAllDay() {
        let row = project(event("2026-09-21T07:00:00Z", "2026-10-24T06:59:59Z", allDay: true))
        #expect(row["start_date"] as? String == "2026-09-21")
        #expect(row["end_date"] as? String == "2026-10-23")
        #expect(row["spans_multiple_days"] as? Bool == true)
        #expect(row["start_local"] == nil)
    }

    @Test("A one-day all-day event is not flagged")
    func singleDayAllDay() {
        let row = project(event("2026-09-21T07:00:00Z", "2026-09-22T06:59:59Z", allDay: true))
        #expect(row["start_date"] as? String == "2026-09-21")
        #expect(row["end_date"] as? String == "2026-09-21")
        #expect(row["spans_multiple_days"] as? Bool == false)
    }

    @Test("A timed event past local midnight spans days; one ending at midnight does not")
    func timedAcrossMidnight() {
        // 22:00–01:00 local
        #expect(project(event("2026-10-07T05:00:00Z", "2026-10-07T08:00:00Z"))["spans_multiple_days"] as? Bool == true)
        // 23:00–00:00 local
        #expect(project(event("2026-10-07T06:00:00Z", "2026-10-07T07:00:00Z"))["spans_multiple_days"] as? Bool == false)
    }

    @Test("A moved occurrence keeps its slot, and is marked part of a series")
    func detachedOccurrence() {
        let row = project(event(
            "2026-10-06T17:15:00Z", "2026-10-06T17:45:00Z", detached: true, occurrence: "2026-09-30T16:00:00Z"
        ))
        #expect(row["is_recurring"] as? Bool == false)
        #expect(row["is_detached"] as? Bool == true)
        #expect(row["part_of_series"] as? Bool == true)
        #expect(row["occurrence_date"] as? String == "2026-09-30T16:00:00.000Z")
    }

    @Test("A one-off event carries no occurrence_date")
    func oneOffHasNoOccurrence() {
        let row = project(event("2026-10-06T19:00:00Z", "2026-10-06T19:30:00Z", occurrence: "2026-10-06T19:00:00Z"))
        #expect(row["part_of_series"] as? Bool == false)
        #expect(row["occurrence_date"] == nil)
    }

    @Test("window resolves in local time")
    func windowRange() throws {
        let (from, to) = try ReadTools.eventRange(
            ["window": "today"], now: instant("2026-10-06T19:00:00Z"), zone: losAngeles
        )
        #expect(from == instant("2026-10-06T07:00:00Z"))
        #expect(to == instant("2026-10-07T07:00:00Z"))
    }

    @Test("window and from/to together, an unknown window, or neither are refused")
    func windowValidation() {
        let cases: [([String: Any], String)] = [
            (["window": "today", "from": "2026-10-06T00:00:00Z"], "invalid_argument"),
            (["window": "today", "to": "2026-10-07T00:00:00Z"], "invalid_argument"),
            (["window": "this_week"], "invalid_argument"),
            ([:], "invalid_datetime"),
            (["from": "2026-10-06T00:00:00Z"], "invalid_datetime"),
        ]
        for (args, code) in cases {
            #expect {
                _ = try ReadTools.eventRange(args)
            } throws: { error in
                (error as? ToolError)?.code == code
            }
        }
    }

    @Test("list_events with window 'today' returns today's events and says which range it used")
    func listEventsToday() async throws {
        let repo = InMemoryCalendarRepository(scenario: .init(eventStatus: .fullAccess))
        await repo.insert(calendar: CalendarSummary(
            id: "cal", title: "Work", allowsContentModifications: true, isSubscribed: false,
            isImmutable: false, allowedEntityTypes: [.event], sourceIdentifier: "src", sourceTitle: "iCloud"
        ))
        let today = EventWindow.today.interval()
        await repo.insert(event: EventSummary(
            id: "now", title: "Today", start: today.start.addingTimeInterval(3600),
            end: today.start.addingTimeInterval(7200), calendarIdentifier: "cal"
        ))
        await repo.insert(event: EventSummary(
            id: "later", title: "Next week", start: today.end.addingTimeInterval(7 * 86_400),
            end: today.end.addingTimeInterval(7 * 86_400 + 3600), calendarIdentifier: "cal"
        ))
        let envelope = try await ReadTools.run(
            ReadTools.listEvents, arguments: ["window": "today"], repository: repo, store: nil
        )
        let rows = try #require(envelope["data"] as? [[String: Any]])
        #expect(rows.map { $0["id"] as? String } == ["now"])
        let window = try #require(envelope["window"] as? [String: Any])
        #expect(window["name"] as? String == "today")
        #expect(window["from"] as? String == RCCTime.local(today.start))
    }

    @Test("Every due_window works with include_undated true and false")
    func dueWindowMatrix() async throws {
        let repo = InMemoryCalendarRepository(scenario: .init(reminderStatus: .fullAccess))
        await repo.insert(calendar: CalendarSummary(
            id: "list", title: "Chores", allowsContentModifications: true, isSubscribed: false,
            isImmutable: false, allowedEntityTypes: [.reminder], sourceIdentifier: "src", sourceTitle: "iCloud"
        ))
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.year, .month, .day], from: Date())
        let yesterday = calendar.dateComponents([.year, .month, .day], from: Date().addingTimeInterval(-86_400))
        _ = try await repo.createReminder(ReminderDraft(calendarIdentifier: "list", title: "Undated"))
        _ = try await repo.createReminder(ReminderDraft(
            calendarIdentifier: "list", title: "Today",
            dueDate: .day(year: parts.year!, month: parts.month!, day: parts.day!)
        ))
        _ = try await repo.createReminder(ReminderDraft(
            calendarIdentifier: "list", title: "Yesterday",
            dueDate: .day(year: yesterday.year!, month: yesterday.month!, day: yesterday.day!)
        ))
        for window in ReminderDueWindow.allCases {
            for includeUndated in [true, false] {
                let envelope = try await ReadTools.run(
                    ReadTools.listReminders,
                    arguments: ["completion": "incomplete", "due_window": window.rawValue,
                                "include_undated": includeUndated],
                    repository: repo, store: nil
                )
                let titles = try #require(envelope["data"] as? [[String: Any]]).compactMap { $0["title"] as? String }
                #expect(!titles.contains("Undated"), "\(window.rawValue), include_undated \(includeUndated)")
                switch window {
                case .overdue: #expect(titles == ["Yesterday"])
                case .today, .next7Days: #expect(titles == ["Today"])
                case .overdueOrToday: #expect(Set(titles) == ["Yesterday", "Today"])
                }
            }
        }
    }
}
