import EventKit
import Foundation
import RCCCore

/// A recurrence rule, exposed close to `EKRecurrenceRule`'s own shape (SPEC §9.5).
///
/// Every list field is kept as an ordinary `[Int]` of the values EventKit uses (signed
/// where EventKit allows negatives — e.g. `-1` for "last"). `EKWeekday` raw values are
/// 1 = Sunday … 7 = Saturday.
public struct RecurrenceRule: Sendable, Equatable {
    public enum Frequency: String, Sendable, CaseIterable {
        case daily, weekly, monthly, yearly

        init(_ ek: EKRecurrenceFrequency) {
            switch ek {
            case .daily: self = .daily
            case .weekly: self = .weekly
            case .monthly: self = .monthly
            case .yearly: self = .yearly
            @unknown default: self = .daily
            }
        }

        var ek: EKRecurrenceFrequency {
            switch self {
            case .daily: return .daily
            case .weekly: return .weekly
            case .monthly: return .monthly
            case .yearly: return .yearly
            }
        }
    }

    /// A weekday, optionally qualified by an ordinal ("the 2nd Tuesday", "the last Friday").
    public struct DayOfWeek: Sendable, Equatable {
        /// 1 = Sunday … 7 = Saturday.
        public let weekday: Int
        /// 0 = every occurrence of this weekday; ±1…±53 = the nth (negative counts back).
        public let ordinal: Int

        public init(weekday: Int, ordinal: Int = 0) {
            self.weekday = weekday
            self.ordinal = ordinal
        }
    }

    /// When the series stops. `never` when EventKit reports neither an end date nor a
    /// count (SPEC §9.5 "a date, an occurrence count, or neither/never").
    public enum End: Sendable, Equatable {
        case never
        case onDate(Date)
        case afterOccurrences(Int)
    }

    public let frequency: Frequency
    public let interval: Int
    public let daysOfWeek: [DayOfWeek]
    public let daysOfMonth: [Int]
    public let monthsOfYear: [Int]
    public let weeksOfYear: [Int]
    public let daysOfYear: [Int]
    public let setPositions: [Int]
    /// EKWeekday raw value, or 0 when EventKit leaves it unset.
    public let firstDayOfWeek: Int
    public let end: End

    public init(
        frequency: Frequency, interval: Int,
        daysOfWeek: [DayOfWeek] = [], daysOfMonth: [Int] = [], monthsOfYear: [Int] = [],
        weeksOfYear: [Int] = [], daysOfYear: [Int] = [], setPositions: [Int] = [],
        firstDayOfWeek: Int = 0, end: End = .never
    ) {
        self.frequency = frequency
        self.interval = interval
        self.daysOfWeek = daysOfWeek
        self.daysOfMonth = daysOfMonth
        self.monthsOfYear = monthsOfYear
        self.weeksOfYear = weeksOfYear
        self.daysOfYear = daysOfYear
        self.setPositions = setPositions
        self.firstDayOfWeek = firstDayOfWeek
        self.end = end
    }
}

extension RecurrenceRule {
    /// Convert an EventKit rule to the DTO. `interval` is clamped to at least 1 —
    /// `EKRecurrenceRule` guarantees `>= 1`, but a defensive floor keeps a corrupt value
    /// from producing a zero-interval DTO.
    public init(_ ek: EKRecurrenceRule) {
        let days = (ek.daysOfTheWeek ?? []).map {
            DayOfWeek(weekday: $0.dayOfTheWeek.rawValue, ordinal: $0.weekNumber)
        }
        let end: End
        if let recurrenceEnd = ek.recurrenceEnd {
            if let date = recurrenceEnd.endDate {
                end = .onDate(date)
            } else if recurrenceEnd.occurrenceCount > 0 {
                end = .afterOccurrences(recurrenceEnd.occurrenceCount)
            } else {
                end = .never
            }
        } else {
            end = .never
        }
        self.init(
            frequency: Frequency(ek.frequency),
            interval: max(1, ek.interval),
            daysOfWeek: days,
            daysOfMonth: (ek.daysOfTheMonth ?? []).map(\.intValue),
            monthsOfYear: (ek.monthsOfTheYear ?? []).map(\.intValue),
            weeksOfYear: (ek.weeksOfTheYear ?? []).map(\.intValue),
            daysOfYear: (ek.daysOfTheYear ?? []).map(\.intValue),
            setPositions: (ek.setPositions ?? []).map(\.intValue),
            firstDayOfWeek: ek.firstDayOfTheWeek,
            end: end
        )
    }

    /// Build an `EKRecurrenceRule` from the DTO. Used on the write path (create / update).
    public func toEKRecurrenceRule() -> EKRecurrenceRule {
        let days: [EKRecurrenceDayOfWeek]? = daysOfWeek.isEmpty ? nil : daysOfWeek.compactMap {
            guard let weekday = EKWeekday(rawValue: $0.weekday) else { return nil }
            return EKRecurrenceDayOfWeek(weekday, weekNumber: $0.ordinal)
        }
        let recurrenceEnd: EKRecurrenceEnd?
        switch end {
        case .never: recurrenceEnd = nil
        case .onDate(let date): recurrenceEnd = EKRecurrenceEnd(end: date)
        case .afterOccurrences(let count): recurrenceEnd = EKRecurrenceEnd(occurrenceCount: count)
        }
        let rule = EKRecurrenceRule(
            recurrenceWith: frequency.ek,
            interval: max(1, interval),
            daysOfTheWeek: days,
            daysOfTheMonth: daysOfMonth.isEmpty ? nil : daysOfMonth.map { NSNumber(value: $0) },
            monthsOfTheYear: monthsOfYear.isEmpty ? nil : monthsOfYear.map { NSNumber(value: $0) },
            weeksOfTheYear: weeksOfYear.isEmpty ? nil : weeksOfYear.map { NSNumber(value: $0) },
            daysOfTheYear: daysOfYear.isEmpty ? nil : daysOfYear.map { NSNumber(value: $0) },
            setPositions: setPositions.isEmpty ? nil : setPositions.map { NSNumber(value: $0) },
            end: recurrenceEnd
        )
        return rule
    }

    /// A stable, order-independent string for hashing into a DTO `version` (SPEC §9.4).
    /// Lists are sorted so a reordering EventKit might do between fetches does not read as
    /// a content change.
    public var canonicalString: String {
        func sortedInts(_ values: [Int]) -> String {
            values.sorted().map(String.init).joined(separator: ",")
        }
        let days = daysOfWeek
            .map { "\($0.weekday):\($0.ordinal)" }
            .sorted()
            .joined(separator: ",")
        let endString: String
        switch end {
        case .never: endString = "never"
        case .onDate(let date): endString = "date:\(RCCTime.instant(date))"
        case .afterOccurrences(let count): endString = "count:\(count)"
        }
        return [
            "freq=\(frequency.rawValue)",
            "interval=\(max(1, interval))",
            "dow=\(days)",
            "dom=\(sortedInts(daysOfMonth))",
            "moy=\(sortedInts(monthsOfYear))",
            "woy=\(sortedInts(weeksOfYear))",
            "doy=\(sortedInts(daysOfYear))",
            "setpos=\(sortedInts(setPositions))",
            "fdow=\(firstDayOfWeek)",
            "end=\(endString)",
        ].joined(separator: ";")
    }
}

/// Which slice of a recurring series a mutation applies to (SPEC §9.4). A recurring
/// target with no explicit scope is rejected — `rcc` never guesses.
public enum RecurrenceScope: String, Sendable, CaseIterable {
    case thisOccurrence = "this_occurrence"
    case thisAndFuture = "this_and_future"

    var ekSpan: EKSpan {
        switch self {
        case .thisOccurrence: return .thisEvent
        case .thisAndFuture: return .futureEvents
        }
    }
}
