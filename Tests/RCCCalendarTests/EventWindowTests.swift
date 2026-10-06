import Foundation
import Testing

@testable import RCCCalendar
@testable import RCCCore

@Suite("EventWindow")
struct EventWindowTests {
    /// Vancouver is permanent UTC−7 from March 2026, so the DST cases use Los Angeles.
    private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!

    private func instant(_ iso: String) -> Date { RCCTime.parse(iso)! }

    @Test("today is local midnight to local midnight")
    func today() {
        let range = EventWindow.today.interval(now: instant("2026-10-06T19:00:00Z"), zone: losAngeles)
        #expect(range.start == instant("2026-10-06T07:00:00Z"))
        #expect(range.end == instant("2026-10-07T07:00:00Z"))
    }

    @Test("tomorrow and next_7_days start from the local day")
    func tomorrowAndNextSevenDays() {
        let now = instant("2026-10-06T19:00:00Z")
        let tomorrow = EventWindow.tomorrow.interval(now: now, zone: losAngeles)
        #expect(tomorrow.start == instant("2026-10-07T07:00:00Z"))
        #expect(tomorrow.end == instant("2026-10-08T07:00:00Z"))
        let week = EventWindow.next7Days.interval(now: now, zone: losAngeles)
        #expect(week.start == instant("2026-10-06T07:00:00Z"))
        #expect(week.end == instant("2026-10-13T07:00:00Z"))
    }

    @Test("A fall-back day is 25 hours long")
    func fallBack() {
        let range = EventWindow.today.interval(now: instant("2026-11-01T20:00:00Z"), zone: losAngeles)
        #expect(range.start == instant("2026-11-01T07:00:00Z"))
        #expect(range.end == instant("2026-11-02T08:00:00Z"))
        #expect(range.end.timeIntervalSince(range.start) == 25 * 3600)
    }

    @Test("A spring-forward day is 23 hours long")
    func springForward() {
        let range = EventWindow.today.interval(now: instant("2026-03-08T19:00:00Z"), zone: losAngeles)
        #expect(range.start == instant("2026-03-08T08:00:00Z"))
        #expect(range.end == instant("2026-03-09T07:00:00Z"))
        #expect(range.end.timeIntervalSince(range.start) == 23 * 3600)
    }

    @Test("Local time renders with an RFC 3339 offset")
    func localRendering() {
        #expect(RCCTime.local(instant("2026-10-06T14:00:00Z"), zone: losAngeles) == "2026-10-06T07:00:00-07:00")
        #expect(RCCTime.local(instant("2026-12-06T14:00:00Z"), zone: losAngeles) == "2026-12-06T06:00:00-08:00")
    }
}
