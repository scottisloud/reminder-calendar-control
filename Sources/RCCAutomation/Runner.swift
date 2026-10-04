import Foundation
import RCCCalendar
import RCCCore

/// Delivers advisory output (SPEC §11.4). Never an approval mechanism; failing to notify
/// never changes what a run did.
public protocol AutomationNotifier: Sendable {
    func notify(title: String, body: String)
}

/// `rcc automations run` — what launchd invokes every 30 minutes (SPEC §11.3).
///
/// For each enabled rule whose `next_due_at` has passed: claim its lease (so a rule never
/// runs concurrently with itself, however many `run`s overlap), apply the misfire policy,
/// evaluate the trigger, refuse a match set larger than `max_fan_out` outright, then flag
/// or stage. Destructive actions are **never** executed here — only staged (§8.3). Every
/// firing, including a misfire skip or a failure, is a row in `automation_runs`.
public struct AutomationRunner: Sendable {
    public static let leaseTTL: TimeInterval = 10 * 60
    /// A staged action is approvable for a day: long enough to see the morning
    /// notification, short enough that the nightly rule supersedes it before it goes stale.
    public static let stagedActionLifetime: TimeInterval = 24 * 3600
    /// Retry ceiling for retryable failures before falling back to the normal schedule.
    public static let maxRetries = 3

    private let repository: any CalendarRepository
    private let store: Store
    private let notifier: (any AutomationNotifier)?
    private let owner: String

    public init(
        repository: any CalendarRepository, store: Store, notifier: (any AutomationNotifier)?,
        owner: String = "pid:\(ProcessInfo.processInfo.processIdentifier):\(UUID().uuidString.prefix(8))"
    ) {
        self.repository = repository
        self.store = store
        self.notifier = notifier
        self.owner = owner
    }

    public struct RunReport: Sendable, Equatable {
        public var ruleID: String
        public var ruleName: String
        public var outcome: String
        public var matched: Int?
        public var stagedActionID: String?
        public var detail: String?
    }

    /// Run every due rule (or just `ruleID`, which then runs even if not yet due).
    public func runDue(now: Date = Date(), ruleID: String? = nil, dryRun: Bool = false) async throws -> [RunReport] {
        try store.expireStagedActions(now: now)
        try store.failAbandonedRuns(now: now)
        var reports: [RunReport] = []
        for record in try store.rules() where record.enabled && (ruleID == nil || record.id == ruleID) {
            let definition: RuleDefinition
            do {
                definition = try RuleDefinition(canonicalJSON: record.definitionJSON)
            } catch {
                reports.append(RunReport(ruleID: record.id, ruleName: record.name, outcome: "failed",
                                         detail: "stored rule does not parse: \(error)"))
                continue
            }
            let due = record.nextDueAt.flatMap(RCCTime.parse)
                ?? definition.schedule.nextSlot(after: RCCTime.parse(record.createdAt) ?? now, in: definition.timeZone)
            guard ruleID != nil || due <= now else { continue }
            if dryRun {
                reports.append(try await preview(record, definition, now: now))
            } else if let report = try await fire(record, definition, due: due, now: now, forced: ruleID != nil) {
                reports.append(report)
            }
        }
        return reports
    }

    // MARK: - One firing

    private func fire(
        _ record: Store.AutomationRuleRecord, _ rule: RuleDefinition, due: Date, now: Date, forced: Bool
    ) async throws -> RunReport? {
        // The lease is the double-fire guard: a rule already running elsewhere is skipped,
        // not run concurrently with itself (SPEC §11.3).
        guard try store.acquireLease(ruleID: record.id, owner: owner, now: now, ttl: Self.leaseTTL) else {
            return nil
        }
        // ...but holding the lease is not enough. `record` was read before claiming it, and
        // an overlapping run may have claimed, run, and released in between — leaving the
        // lease free and the slot already served. Re-read under the lease and proceed only
        // if the slot is still due. (The simulated-week test caught exactly this double
        // fire.)
        let fresh = try store.rule(id: record.id)
        let stillDue = fresh.map { $0.nextDueAt == record.nextDueAt } ?? false
        guard forced || stillDue else {
            try store.abandonLease(ruleID: record.id, owner: owner)
            return nil
        }
        let runID = UUID().uuidString
        try store.startRun(id: runID, ruleID: record.id, scheduledFor: RCCTime.instant(due), now: now)
        let lateness = now.timeIntervalSince(due)

        var report = RunReport(ruleID: record.id, ruleName: rule.name, outcome: "nothing")
        var failures = record.consecutiveFailures
        var nextDue = rule.schedule.nextSlot(after: now, in: rule.timeZone)

        if rule.misfirePolicy == .skip, lateness > TimeInterval(rule.maxLatenessMinutes * 60) {
            report.outcome = "skipped_misfire"
            report.detail = "started \(Int(lateness / 60)) min after its slot; misfire_policy is skip "
                + "(max lateness \(rule.maxLatenessMinutes) min)"
        } else {
            do {
                let items = try await TriggerEvaluator(repository: repository).evaluate(rule, now: now)
                report.matched = items.count
                if items.count > rule.maxFanOut {
                    // Never truncate silently: a rule that suddenly matches far more than its
                    // author expected is exactly the case a human must look at.
                    report.outcome = "fan_out_exceeded"
                    report.detail = "matched \(items.count) items, over max_fan_out \(rule.maxFanOut); nothing done"
                    notifier?.notify(title: "rcc: \(rule.name) stopped",
                                     body: "Matched \(items.count) items, over its limit of \(rule.maxFanOut). Nothing was changed.")
                } else if items.isEmpty {
                    report.outcome = "nothing"
                } else {
                    switch rule.action {
                    case .flag:
                        report.outcome = "flagged"
                        report.detail = Self.digest(items)
                        notifier?.notify(title: "rcc: \(rule.name)", body: Self.notificationBody(items))
                    case .delete:
                        let actionID = try stage(record: record, rule: rule, runID: runID, items: items, now: now)
                        report.outcome = "staged"
                        report.stagedActionID = actionID
                        report.detail = "staged deletion of \(items.count) item(s) for approval: \(actionID)"
                        notifier?.notify(
                            title: "rcc: \(rule.name) — approval needed",
                            body: "Delete \(items.count) item(s)? Review and approve in Terminal: rcc automations approve \(actionID)"
                        )
                    }
                }
                failures = 0
            } catch {
                failures += 1
                report.outcome = "failed"
                report.detail = Redaction.sanitize(String(describing: error), limit: 400)
                if Self.isRetryable(error), failures <= Self.maxRetries {
                    nextDue = now.addingTimeInterval(Self.backoff(attempt: failures))
                }
                notifier?.notify(title: "rcc: \(rule.name) failed", body: report.detail ?? "")
            }
        }

        try store.finishRun(id: runID, outcome: report.outcome, matched: report.matched,
                            stagedActionID: report.stagedActionID, detail: report.detail, now: now)
        try store.releaseLease(ruleID: record.id, owner: owner, nextDueAt: RCCTime.instant(nextDue),
                               consecutiveFailures: failures, lastRunAt: RCCTime.instant(now),
                               lastOutcome: report.outcome)
        Log.shared.info("automation.run", [
            "rule": .safe(record.id), "outcome": .safe(report.outcome),
            "matched": .int(report.matched ?? 0), "lateness_s": .int(Int(lateness)),
        ])
        return report
    }

    /// `--dry-run`: evaluate and report, touching nothing — no lease, no run row, no
    /// staging, no schedule change (SPEC §11.4).
    private func preview(_ record: Store.AutomationRuleRecord, _ rule: RuleDefinition, now: Date) async throws -> RunReport {
        do {
            let items = try await TriggerEvaluator(repository: repository).evaluate(rule, now: now)
            let verb = rule.action == .delete ? "would stage deletion of" : "would flag"
            return RunReport(
                ruleID: record.id, ruleName: rule.name, outcome: "dry_run", matched: items.count,
                detail: items.count > rule.maxFanOut
                    ? "matched \(items.count), over max_fan_out \(rule.maxFanOut) — a real run would stop"
                    : "\(verb) \(items.count) item(s)" + (items.isEmpty ? "" : ":\n" + Self.digest(items))
            )
        } catch {
            return RunReport(ruleID: record.id, ruleName: rule.name, outcome: "failed",
                             detail: Redaction.sanitize(String(describing: error), limit: 400))
        }
    }

    /// Stage a deletion. A still-pending action from an earlier run of the same rule is
    /// superseded (marked `stale`): the new one reflects the current state, and two pending
    /// actions over overlapping items would only invite approving the wrong one.
    private func stage(
        record: Store.AutomationRuleRecord, rule: RuleDefinition, runID: String, items: [MatchedItem], now: Date
    ) throws -> String {
        for pending in try store.stagedActions(states: ["pending"]) where pending.ruleID == record.id {
            _ = try store.transitionStagedAction(id: pending.id, from: ["pending"], to: "stale",
                                                 resultJSON: #"{"reason":"superseded by a later run"}"#, now: now)
        }
        let id = StagedActions.newHandle()
        let itemsJSON = String(decoding: try JSONSerialization.data(
            withJSONObject: items.map(\.jsonObject), options: [.sortedKeys]), as: UTF8.self)
        try store.insertStagedAction(
            id: id, ruleID: record.id, runID: runID,
            kind: items.first?.entity == .event ? "delete_events" : "delete_reminders",
            impact: "deletion", summary: "\(rule.name): delete \(items.count) item(s)",
            itemsJSON: itemsJSON, now: now, expiresAt: now.addingTimeInterval(Self.stagedActionLifetime)
        )
        return id
    }

    // MARK: - Policy helpers

    /// Failures worth retrying soon: a temporarily unavailable account. Permission, a
    /// missing calendar, a bad rule — none of those fix themselves in five minutes.
    static func isRetryable(_ error: any Error) -> Bool {
        if let error = error as? CalendarRepositoryError, case .native = error { return true }
        return false
    }

    /// 5, 10, 20 … minutes, capped at 2 hours, with ±10% jitter so retries of several
    /// rules do not land on the same firing.
    static func backoff(attempt: Int) -> TimeInterval {
        let base = min(300 * pow(2, Double(max(0, attempt - 1))), 7200)
        return base * Double.random(in: 0.9...1.1)
    }

    static func digest(_ items: [MatchedItem], limit: Int = 25) -> String {
        var lines = items.prefix(limit).map { "• \($0.title) — \($0.detail)" }
        if items.count > limit { lines.append("… and \(items.count - limit) more") }
        return lines.joined(separator: "\n")
    }

    static func notificationBody(_ items: [MatchedItem]) -> String {
        let first = items.prefix(3).map(\.title).joined(separator: ", ")
        return items.count > 3 ? "\(items.count) items: \(first), …" : "\(items.count) item(s): \(first)"
    }
}

public enum StagedActions {
    /// A short approval handle a human can read off a notification and type:
    /// `xxxx-xxxx` from an alphabet without look-alikes. ~41 bits — it identifies a row;
    /// approval itself is gated by a terminal, not by the handle's secrecy.
    public static func newHandle() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        let chars = (0..<8).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] }
        return String(chars[0..<4]) + "-" + String(chars[4..<8])
    }
}
