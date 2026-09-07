import EventKit
import Foundation
import Testing

@testable import RCCCalendar

@Suite("RecurrenceRule")
struct RecurrenceTests {
    @Test("A simple weekly rule round-trips through EventKit")
    func weeklyRoundTrip() {
        let dto = RecurrenceRule(
            frequency: .weekly,
            interval: 2,
            daysOfWeek: [.init(weekday: 2), .init(weekday: 4)],  // Mon, Wed
            end: .afterOccurrences(10)
        )
        let back = RecurrenceRule(dto.toEKRecurrenceRule())
        #expect(back.frequency == .weekly)
        #expect(back.interval == 2)
        #expect(Set(back.daysOfWeek.map(\.weekday)) == [2, 4])
        #expect(back.end == .afterOccurrences(10))
    }

    @Test("A monthly 'last Friday' rule keeps its ordinal")
    func monthlyOrdinal() {
        let dto = RecurrenceRule(
            frequency: .monthly,
            interval: 1,
            daysOfWeek: [.init(weekday: 6, ordinal: -1)],  // last Friday
            setPositions: [-1]
        )
        let back = RecurrenceRule(dto.toEKRecurrenceRule())
        #expect(back.daysOfWeek == [.init(weekday: 6, ordinal: -1)])
        #expect(back.setPositions == [-1])
    }

    @Test("An end date survives the round trip")
    func endDate() {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        let dto = RecurrenceRule(frequency: .daily, interval: 1, end: .onDate(end))
        let back = RecurrenceRule(dto.toEKRecurrenceRule())
        guard case .onDate(let backDate) = back.end else {
            Issue.record("expected .onDate"); return
        }
        #expect(abs(backDate.timeIntervalSince(end)) < 1)
    }

    @Test("No end reads as .never, not a zero count")
    func noEnd() {
        let ek = EKRecurrenceRule(recurrenceWith: .yearly, interval: 1, end: nil)
        #expect(RecurrenceRule(ek).end == .never)
    }

    @Test("canonicalString is stable under list reordering")
    func canonicalOrderIndependent() {
        let a = RecurrenceRule(
            frequency: .weekly, interval: 1,
            daysOfWeek: [.init(weekday: 2), .init(weekday: 5)],
            monthsOfYear: [3, 1, 12]
        )
        let b = RecurrenceRule(
            frequency: .weekly, interval: 1,
            daysOfWeek: [.init(weekday: 5), .init(weekday: 2)],
            monthsOfYear: [12, 1, 3]
        )
        #expect(a.canonicalString == b.canonicalString)
    }

    @Test("canonicalString changes when the rule really changes")
    func canonicalSensitive() {
        let base = RecurrenceRule(frequency: .weekly, interval: 1).canonicalString
        #expect(RecurrenceRule(frequency: .weekly, interval: 2).canonicalString != base)
        #expect(RecurrenceRule(frequency: .daily, interval: 1).canonicalString != base)
        #expect(
            RecurrenceRule(frequency: .weekly, interval: 1, end: .afterOccurrences(5))
                .canonicalString != base
        )
    }

    @Test("RecurrenceScope maps to the right EKSpan")
    func scopeSpan() {
        #expect(RecurrenceScope.thisOccurrence.ekSpan == .thisEvent)
        #expect(RecurrenceScope.thisAndFuture.ekSpan == .futureEvents)
        #expect(RecurrenceScope(rawValue: "this_occurrence") == .thisOccurrence)
        #expect(RecurrenceScope(rawValue: "nonsense") == nil)
    }
}
