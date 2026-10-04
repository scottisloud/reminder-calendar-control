import Foundation
import RCCCalendar
import RCCCore

/// One item a rule's trigger matched, with everything a staged action needs to act on
/// exactly this version of it later (SPEC §8.3).
public struct MatchedItem: Sendable, Equatable {
    public enum Entity: String, Sendable { case event, reminder }

    public let entity: Entity
    public let identifier: String
    /// For one occurrence of a recurring event.
    public let occurrenceDate: Date?
    public let version: String
    /// Truncated and control-character-sanitised: shown to a human, never interpreted.
    public let title: String
    /// One line of why it matched ("completed 2026-08-01", "10:00–10:30, no location").
    public let detail: String

    public var jsonObject: [String: Any] {
        var out: [String: Any] = [
            "entity": entity.rawValue, "identifier": identifier, "version": version,
            "title": title, "detail": detail,
        ]
        if let occurrenceDate { out["occurrence_date"] = RCCTime.instant(occurrenceDate) }
        return out
    }

    public init(entity: Entity, identifier: String, occurrenceDate: Date?, version: String, title: String, detail: String) {
        self.entity = entity
        self.identifier = identifier
        self.occurrenceDate = occurrenceDate
        self.version = version
        self.title = title
        self.detail = detail
    }

    public init?(json: [String: Any]) {
        guard let entity = (json["entity"] as? String).flatMap(Entity.init(rawValue:)),
              let identifier = json["identifier"] as? String, let version = json["version"] as? String
        else { return nil }
        self.init(
            entity: entity, identifier: identifier,
            occurrenceDate: (json["occurrence_date"] as? String).flatMap(RCCTime.parse),
            version: version, title: json["title"] as? String ?? "", detail: json["detail"] as? String ?? ""
        )
    }
}

/// Evaluates a trigger against the calendar store. Read-only by construction: it holds a
/// repository but only ever calls its read methods.
public struct TriggerEvaluator: Sendable {
    let repository: any CalendarRepository

    public init(repository: any CalendarRepository) {
        self.repository = repository
    }

    public func evaluate(_ rule: RuleDefinition, now: Date) async throws -> [MatchedItem] {
        try await requireScopeExists(rule)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = rule.timeZone

        switch rule.trigger {
        case .completedReminders(let days, let lists):
            var filter = ReminderFilter(calendarIdentifiers: lists, completion: .completed)
            filter.completedTo = now.addingTimeInterval(-TimeInterval(days) * 86_400)
            return try await repository.listReminders(filter).map { reminder in
                let completed = reminder.completionDate.map { RCCTime.localDay($0, calendar: calendar) } ?? "unknown date"
                return MatchedItem(
                    entity: .reminder, identifier: reminder.id, occurrenceDate: nil,
                    version: reminder.version, title: Self.label(reminder.title), detail: "completed \(completed)"
                )
            }

        case .eventsWithoutLocation(let daysAhead, let calendars, let onlyWithAttendees):
            let events = try await upcoming(daysAhead, calendars, now)
            return events.filter { event in
                !event.isAllDay
                    && event.status?.name != "canceled"
                    && (!onlyWithAttendees || event.participants.contains { !$0.isCurrentUser })
                    && Self.hasNoPlace(event)
            }.map { event in
                MatchedItem(
                    entity: .event, identifier: event.id,
                    occurrenceDate: event.isRecurring || event.isDetached ? event.occurrenceDate : nil,
                    version: event.version, title: Self.label(event.title),
                    detail: "\(Self.when(event, calendar)) — no location or video link (heuristic)"
                )
            }

        case .backToBackEvents(let daysAhead, let calendars, let minGap):
            let events = try await upcoming(daysAhead, calendars, now)
                .filter { !$0.isAllDay && $0.status?.name != "canceled" && $0.availability?.name != "free" }
                .sorted { ($0.start, $0.end) < ($1.start, $1.end) }
            var flagged: [MatchedItem] = []
            for (previous, next) in zip(events, events.dropFirst())
            where calendar.isDate(previous.start, inSameDayAs: next.start) {
                let gap = next.start.timeIntervalSince(previous.end) / 60
                guard gap >= 0, gap <= Double(minGap) else { continue }
                flagged.append(MatchedItem(
                    entity: .event, identifier: next.id,
                    occurrenceDate: next.isRecurring || next.isDetached ? next.occurrenceDate : nil,
                    version: next.version, title: Self.label(next.title),
                    detail: "\(Self.when(next, calendar)) — starts \(Int(gap)) min after "
                        + "\"\(Self.label(previous.title, limit: 40))\" ends"
                ))
            }
            return flagged
        }
    }

    private func upcoming(_ days: Int, _ calendars: [String]?, _ now: Date) async throws -> [EventSummary] {
        try await repository.queryEvents(EventQuery(
            calendarIdentifiers: calendars, from: now, to: now.addingTimeInterval(TimeInterval(days) * 86_400)
        )).items
    }

    /// A rule scoped to a calendar that no longer exists fails loudly instead of quietly
    /// matching nothing forever (SPEC §11.3: no silent failure).
    private func requireScopeExists(_ rule: RuleDefinition) async throws {
        guard let scope = rule.scope else { return }
        let entity: RCCEntityType
        if case .completedReminders = rule.trigger { entity = .reminder } else { entity = .event }
        for identifier in scope where try await repository.calendar(withIdentifier: identifier, entityType: entity) == nil {
            throw RuleError("this rule's \(entity == .reminder ? "list" : "calendar") \(identifier) no longer exists; "
                + "edit or delete the rule")
        }
    }

    /// "No location or video-conferencing link" (SPEC §10.1): no location, no structured
    /// location, no URL, and no common conferencing host in the notes. A heuristic — the
    /// result says so.
    static func hasNoPlace(_ event: EventSummary) -> Bool {
        if let location = event.location, !location.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        if event.structuredLocation?.title?.isEmpty == false { return false }
        if let url = event.url, !url.isEmpty { return false }
        let notes = (event.notes ?? "").lowercased()
        let conferencing = ["zoom.us/", "meet.google.com/", "teams.microsoft.com/", "webex.com/",
                            "whereby.com/", "facetime.apple.com/", "gotomeeting.com/", "around.co/"]
        return !conferencing.contains { notes.contains($0) }
    }

    static func label(_ text: String, limit: Int = 80) -> String {
        Redaction.sanitize(text.isEmpty ? "(untitled)" : text, limit: limit)
    }

    static func when(_ event: EventSummary, _ calendar: Calendar) -> String {
        let format = Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: calendar.timeZone)
        return event.start.formatted(format)
    }
}
