import Foundation

extension RuleDefinition.Schedule {
    /// The first slot strictly after `date`, in `zone` (SPEC §11.3).
    ///
    /// Wall-clock schedules are matched in the rule's own time zone, so they follow DST
    /// and a change of the Mac's zone does not move them. Each candidate is built from a
    /// local calendar day plus the rule's hour and minute, then converted to an instant:
    ///
    /// - a slot in the spring-forward gap (02:30 when 02:00–03:00 does not exist) resolves
    ///   to the instant just after the gap, once;
    /// - a slot in the repeated fall-back hour resolves to its first occurrence, once.
    ///
    /// Built from components rather than `Calendar.nextDate(after:matching:)` so the gap and
    /// repeat behaviour is the documented `date(from:)` behaviour, and stated here. Note the
    /// zone decides whether there is any DST at all: America/Vancouver has been permanent
    /// UTC−7 since March 2026, so a Vancouver rule has no gap or repeat to handle.
    public func nextSlot(after date: Date, in zone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        switch self {
        case .daily(let hour, let minute):
            return Self.firstSlot(after: date, calendar: calendar, hour: hour, minute: minute) { _ in true }
        case .weekly(let weekdays, let hour, let minute):
            return Self.firstSlot(after: date, calendar: calendar, hour: hour, minute: minute) {
                weekdays.contains(calendar.component(.weekday, from: $0))
            }
        case .everyMinutes(let minutes):
            return date.addingTimeInterval(TimeInterval(minutes * 60))
        }
    }

    /// Walk forward day by day from the local day containing `date` and return the first
    /// qualifying day's slot that lies after `date`.
    private static func firstSlot(
        after date: Date, calendar: Calendar, hour: Int, minute: Int, qualifies: (Date) -> Bool
    ) -> Date {
        let today = calendar.startOfDay(for: date)
        for offset in 0...8 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today), qualifies(day) else { continue }
            var components = calendar.dateComponents([.year, .month, .day], from: day)
            components.hour = hour
            components.minute = minute
            components.second = 0
            // For a time inside the spring-forward gap, `date(from:)` returns the instant
            // the gap skips to; for a repeated time, the first occurrence.
            if let slot = calendar.date(from: components), slot > date { return slot }
        }
        return date.addingTimeInterval(86_400)
    }
}
