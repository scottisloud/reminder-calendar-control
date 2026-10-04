import Foundation
import RCCCalendar
import RCCCore

/// Create, change, describe, and delete rules — the shared core of the CLI and the MCP
/// `*_automation` tools (SPEC §11.4).
///
/// A rule's `lists`/`calendars` may be written as names; they are resolved to identifiers
/// once, at save time, and stored as identifiers. A rule then keeps acting on the list it
/// was written for even if another list later takes that name — which matters most for a
/// deletion rule.
public struct RuleCatalog: Sendable {
    private let repository: any CalendarRepository
    private let store: Store

    public init(repository: any CalendarRepository, store: Store) {
        self.repository = repository
        self.store = store
    }

    @discardableResult
    public func create(_ document: [String: Any], now: Date = Date()) async throws -> Store.AutomationRuleRecord {
        let rule = try await resolved(RuleDefinition(json: document))
        let id = "rule-" + StagedActions.newHandle()
        try store.insertRule(
            id: id, name: rule.name, enabled: rule.enabled, definitionJSON: rule.canonicalJSON,
            dslVersion: RuleDefinition.dslVersion,
            nextDueAt: RCCTime.instant(rule.schedule.nextSlot(after: now, in: rule.timeZone)), now: now
        )
        guard let record = try store.rule(id: id) else { throw RuleError("rule \(id) vanished after insert") }
        return record
    }

    /// Replace a rule's definition, or (with `document` nil) only switch it on or off.
    @discardableResult
    public func update(
        id: String, document: [String: Any]?, enabled: Bool?, now: Date = Date()
    ) async throws -> Store.AutomationRuleRecord {
        guard let existing = try store.rule(id: id) else { throw RuleError("no automation rule \(id)") }
        var rule = try document.map { try RuleDefinition(json: $0) }
            ?? RuleDefinition(canonicalJSON: existing.definitionJSON)
        if document != nil { rule = try await resolved(rule) }
        if let enabled { rule.enabled = enabled }
        try store.updateRule(
            id: id, name: rule.name, enabled: rule.enabled, definitionJSON: rule.canonicalJSON,
            dslVersion: RuleDefinition.dslVersion,
            nextDueAt: RCCTime.instant(rule.schedule.nextSlot(after: now, in: rule.timeZone)), now: now
        )
        guard let record = try store.rule(id: id) else { throw RuleError("rule \(id) vanished after update") }
        return record
    }

    public func delete(id: String) throws {
        try store.deleteRule(id: id)
    }

    /// A rule as the read surfaces present it: definition, schedule state, last outcome,
    /// and its most recent runs.
    public func describe(_ record: Store.AutomationRuleRecord, runs runLimit: Int = 5) throws -> [String: Any] {
        var out: [String: Any] = [
            "id": record.id, "name": record.name, "enabled": record.enabled,
            "next_due_at": record.nextDueAt as Any? ?? NSNull(),
            "last_run_at": record.lastRunAt as Any? ?? NSNull(),
            "last_outcome": record.lastOutcome as Any? ?? NSNull(),
            "consecutive_failures": record.consecutiveFailures,
        ]
        if let definition = try? RuleDefinition(canonicalJSON: record.definitionJSON) {
            out["definition"] = definition.jsonObject
        }
        out["recent_runs"] = try store.runs(ruleID: record.id, limit: runLimit).map(Self.describe(run:))
        return out
    }

    public static func describe(run: Store.AutomationRunRecord) -> [String: Any] {
        var out: [String: Any] = ["id": run.id, "started_at": run.startedAt, "outcome": run.outcome]
        if let scheduled = run.scheduledFor { out["scheduled_for"] = scheduled }
        if let matched = run.matched { out["matched"] = matched }
        if let staged = run.stagedActionID { out["staged_action_id"] = staged }
        if let detail = run.detail { out["detail"] = detail }
        return out
    }

    /// Resolve every scope entry to an identifier: an existing id stays; a name must match
    /// exactly one calendar of the right type, case-insensitively.
    private func resolved(_ rule: RuleDefinition) async throws -> RuleDefinition {
        guard let scope = rule.scope else { return rule }
        let entity: RCCEntityType
        if case .completedReminders = rule.trigger { entity = .reminder } else { entity = .event }
        let calendars = try await repository.calendars(for: entity)
        let ids = try scope.map { reference -> String in
            if calendars.contains(where: { $0.id == reference }) { return reference }
            let matches = calendars.filter {
                $0.title.compare(reference, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }
            switch matches.count {
            case 1: return matches[0].id
            case 0:
                throw RuleError("no \(entity == .reminder ? "reminder list" : "calendar") named '\(reference)'; "
                    + "available: \(calendars.map(\.title).sorted().joined(separator: ", "))")
            default:
                throw RuleError("\(matches.count) calendars are named '\(reference)' ("
                    + matches.map { "\($0.id) in \($0.sourceTitle ?? "?")" }.joined(separator: "; ")
                    + "); use an id")
            }
        }
        var out = rule
        switch rule.trigger {
        case .completedReminders(let days, _):
            out.trigger = .completedReminders(olderThanDays: days, lists: ids)
        case .eventsWithoutLocation(let days, _, let attendees):
            out.trigger = .eventsWithoutLocation(daysAhead: days, calendars: ids, onlyWithAttendees: attendees)
        case .backToBackEvents(let days, _, let gap):
            out.trigger = .backToBackEvents(daysAhead: days, calendars: ids, minGapMinutes: gap)
        }
        return out
    }
}
