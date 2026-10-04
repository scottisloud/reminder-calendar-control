import Foundation

/// Persistence for Tier 0 automation (SPEC §8.3, §11, §14). Rows only — the rule DSL,
/// scheduling arithmetic, and execution live in `RCCAutomation`.
///
/// Every timestamp is `RCCTime.instant` (fixed-width UTC with milliseconds), so string
/// comparison in SQL is chronological comparison.
extension Store {
    // MARK: - Rules

    public struct AutomationRuleRecord: Sendable, Equatable {
        public let id: String
        public let name: String
        public let enabled: Bool
        public let definitionJSON: String
        public let dslVersion: Int
        public let createdAt: String
        public let updatedAt: String
        public let nextDueAt: String?
        public let leaseOwner: String?
        public let leaseExpiresAt: String?
        public let consecutiveFailures: Int
        public let lastRunAt: String?
        public let lastOutcome: String?
    }

    private static let ruleSelect = """
        SELECT id, name, enabled, definition_json, dsl_version, created_at, updated_at,
               next_due_at, lease_owner, lease_expires_at, consecutive_failures, last_run_at,
               last_outcome
        FROM automation_rules
        """

    private static func decodeRule(_ row: Row) -> AutomationRuleRecord {
        AutomationRuleRecord(
            id: row.text(0) ?? "", name: row.text(1) ?? "", enabled: row.int(2) == 1,
            definitionJSON: row.text(3) ?? "{}", dslVersion: Int(row.int(4)),
            createdAt: row.text(5) ?? "", updatedAt: row.text(6) ?? "",
            nextDueAt: row.text(7), leaseOwner: row.text(8), leaseExpiresAt: row.text(9),
            consecutiveFailures: Int(row.int(10)), lastRunAt: row.text(11), lastOutcome: row.text(12)
        )
    }

    public func insertRule(
        id: String, name: String, enabled: Bool, definitionJSON: String, dslVersion: Int,
        nextDueAt: String?, now: Date = Date()
    ) throws {
        let stamp = RCCTime.instant(now)
        try run(
            """
            INSERT INTO automation_rules
                (id, name, enabled, definition_json, dsl_version, created_at, updated_at, next_due_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """,
            [.text(id), .text(name), .int(enabled ? 1 : 0), .text(definitionJSON), .int(dslVersion),
             .text(stamp), .text(stamp), nextDueAt.map(SQLValue.text) ?? .null]
        )
    }

    /// Replace a rule's definition. Resets its schedule (`next_due_at`) and failure
    /// count, since both were computed from the old definition.
    public func updateRule(
        id: String, name: String, enabled: Bool, definitionJSON: String, dslVersion: Int,
        nextDueAt: String?, now: Date = Date()
    ) throws {
        try run(
            """
            UPDATE automation_rules
            SET name = ?, enabled = ?, definition_json = ?, dsl_version = ?, updated_at = ?,
                next_due_at = ?, consecutive_failures = 0
            WHERE id = ?;
            """,
            [.text(name), .int(enabled ? 1 : 0), .text(definitionJSON), .int(dslVersion),
             .text(RCCTime.instant(now)), nextDueAt.map(SQLValue.text) ?? .null, .text(id)]
        )
        guard changes() == 1 else { throw RCCError(.validation, "No automation rule \(id).") }
    }

    public func deleteRule(id: String) throws {
        try run("DELETE FROM automation_rules WHERE id = ?;", [.text(id)])
        guard changes() == 1 else { throw RCCError(.validation, "No automation rule \(id).") }
    }

    public func rules() throws -> [AutomationRuleRecord] {
        try queryAll(Self.ruleSelect + " ORDER BY created_at, id;", [], Self.decodeRule)
    }

    public func rule(id: String) throws -> AutomationRuleRecord? {
        try queryAll(Self.ruleSelect + " WHERE id = ?;", [.text(id)], Self.decodeRule).first
    }

    // MARK: - Leases (SPEC §11.3)

    /// Claim a rule for one run. Succeeds only if no live lease exists — a lease whose
    /// expiry has passed belongs to a run that died, and is taken over (stale-lease
    /// recovery). Exactly one of any number of concurrent claimants gets `true`: the
    /// conditional UPDATE is atomic, and the changed-row count is the arbiter.
    public func acquireLease(ruleID: String, owner: String, now: Date, ttl: TimeInterval) throws -> Bool {
        try run(
            """
            UPDATE automation_rules SET lease_owner = ?, lease_expires_at = ?
            WHERE id = ? AND enabled = 1 AND (lease_expires_at IS NULL OR lease_expires_at < ?);
            """,
            [.text(owner), .text(RCCTime.instant(now.addingTimeInterval(ttl))), .text(ruleID),
             .text(RCCTime.instant(now))]
        )
        return changes() == 1
    }

    /// Extend a held lease. `false` means it was lost (expired and taken over) — the
    /// holder must stop before doing anything else.
    public func renewLease(ruleID: String, owner: String, now: Date, ttl: TimeInterval) throws -> Bool {
        try run(
            "UPDATE automation_rules SET lease_expires_at = ? WHERE id = ? AND lease_owner = ?;",
            [.text(RCCTime.instant(now.addingTimeInterval(ttl))), .text(ruleID), .text(owner)]
        )
        return changes() == 1
    }

    /// Release the lease and record where the schedule goes next — only if `owner` still
    /// holds it, so a run that lost its lease cannot clobber the run that took it over.
    @discardableResult
    public func releaseLease(
        ruleID: String, owner: String, nextDueAt: String?, consecutiveFailures: Int,
        lastRunAt: String, lastOutcome: String
    ) throws -> Bool {
        try run(
            """
            UPDATE automation_rules
            SET lease_owner = NULL, lease_expires_at = NULL, next_due_at = ?,
                consecutive_failures = ?, last_run_at = ?, last_outcome = ?
            WHERE id = ? AND lease_owner = ?;
            """,
            [nextDueAt.map(SQLValue.text) ?? .null, .int(consecutiveFailures), .text(lastRunAt),
             .text(lastOutcome), .text(ruleID), .text(owner)]
        )
        return changes() == 1
    }

    /// Give a lease back without touching the schedule — for a holder that, having
    /// claimed it, finds there is nothing to do.
    public func abandonLease(ruleID: String, owner: String) throws {
        try run(
            "UPDATE automation_rules SET lease_owner = NULL, lease_expires_at = NULL WHERE id = ? AND lease_owner = ?;",
            [.text(ruleID), .text(owner)]
        )
    }

    // MARK: - Runs

    public struct AutomationRunRecord: Sendable, Equatable {
        public let id: String
        public let ruleID: String
        public let scheduledFor: String?
        public let startedAt: String
        public let finishedAt: String?
        public let outcome: String
        public let matched: Int?
        public let stagedActionID: String?
        public let detail: String?
    }

    public func startRun(id: String, ruleID: String, scheduledFor: String?, now: Date) throws {
        try run(
            "INSERT INTO automation_runs (id, rule_id, scheduled_for, started_at, outcome) VALUES (?, ?, ?, ?, 'running');",
            [.text(id), .text(ruleID), scheduledFor.map(SQLValue.text) ?? .null, .text(RCCTime.instant(now))]
        )
    }

    public func finishRun(
        id: String, outcome: String, matched: Int?, stagedActionID: String?, detail: String?, now: Date
    ) throws {
        try run(
            """
            UPDATE automation_runs SET finished_at = ?, outcome = ?, matched = ?, staged_action_id = ?, detail = ?
            WHERE id = ?;
            """,
            [.text(RCCTime.instant(now)), .text(outcome), matched.map { .int($0) } ?? .null,
             stagedActionID.map(SQLValue.text) ?? .null, detail.map(SQLValue.text) ?? .null, .text(id)]
        )
    }

    /// A run still `running` whose rule lease has expired died mid-flight; close it out
    /// as failed so the log never shows a run that is forever in progress.
    public func failAbandonedRuns(now: Date) throws {
        try run(
            """
            UPDATE automation_runs SET outcome = 'failed', finished_at = ?,
                detail = 'abandoned: the process ended before the run finished'
            WHERE outcome = 'running' AND rule_id IN (
                SELECT id FROM automation_rules WHERE lease_expires_at IS NULL OR lease_expires_at < ?);
            """,
            [.text(RCCTime.instant(now)), .text(RCCTime.instant(now))]
        )
    }

    public func runs(ruleID: String? = nil, limit: Int = 50) throws -> [AutomationRunRecord] {
        let filter = ruleID == nil ? "" : " WHERE rule_id = ?"
        return try queryAll(
            """
            SELECT id, rule_id, scheduled_for, started_at, finished_at, outcome, matched,
                   staged_action_id, detail
            FROM automation_runs\(filter) ORDER BY started_at DESC, id DESC LIMIT \(max(1, limit));
            """,
            ruleID.map { [.text($0)] } ?? []
        ) { row in
            AutomationRunRecord(
                id: row.text(0) ?? "", ruleID: row.text(1) ?? "", scheduledFor: row.text(2),
                startedAt: row.text(3) ?? "", finishedAt: row.text(4), outcome: row.text(5) ?? "",
                matched: row.isNull(6) ? nil : Int(row.int(6)), stagedActionID: row.text(7),
                detail: row.text(8)
            )
        }
    }

    // MARK: - Staged actions (SPEC §8.3)

    public struct StagedActionRecord: Sendable, Equatable {
        public let id: String
        public let ruleID: String?
        public let runID: String?
        public let kind: String
        public let impact: String
        public let summary: String
        public let itemsJSON: String
        public let state: String
        public let createdAt: String
        public let expiresAt: String
        public let decidedAt: String?
        public let resultJSON: String?
    }

    public func insertStagedAction(
        id: String, ruleID: String?, runID: String?, kind: String, impact: String,
        summary: String, itemsJSON: String, now: Date, expiresAt: Date
    ) throws {
        try run(
            """
            INSERT INTO staged_actions
                (id, rule_id, run_id, kind, impact, summary, items_json, state, created_at, expires_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?);
            """,
            [.text(id), ruleID.map(SQLValue.text) ?? .null, runID.map(SQLValue.text) ?? .null,
             .text(kind), .text(impact), .text(summary), .text(itemsJSON),
             .text(RCCTime.instant(now)), .text(RCCTime.instant(expiresAt))]
        )
    }

    private static let stagedSelect = """
        SELECT id, rule_id, run_id, kind, impact, summary, items_json, state, created_at,
               expires_at, decided_at, result_json
        FROM staged_actions
        """

    private static func decodeStaged(_ row: Row) -> StagedActionRecord {
        StagedActionRecord(
            id: row.text(0) ?? "", ruleID: row.text(1), runID: row.text(2), kind: row.text(3) ?? "",
            impact: row.text(4) ?? "", summary: row.text(5) ?? "", itemsJSON: row.text(6) ?? "[]",
            state: row.text(7) ?? "", createdAt: row.text(8) ?? "", expiresAt: row.text(9) ?? "",
            decidedAt: row.text(10), resultJSON: row.text(11)
        )
    }

    public func stagedAction(id: String) throws -> StagedActionRecord? {
        try queryAll(Self.stagedSelect + " WHERE id = ?;", [.text(id)], Self.decodeStaged).first
    }

    public func stagedActions(states: [String]? = nil, limit: Int = 100) throws -> [StagedActionRecord] {
        guard let states, !states.isEmpty else {
            return try queryAll(Self.stagedSelect + " ORDER BY created_at DESC LIMIT \(max(1, limit));", [], Self.decodeStaged)
        }
        let marks = Array(repeating: "?", count: states.count).joined(separator: ", ")
        return try queryAll(
            Self.stagedSelect + " WHERE state IN (\(marks)) ORDER BY created_at DESC LIMIT \(max(1, limit));",
            states.map(SQLValue.text), Self.decodeStaged
        )
    }

    /// Move a staged action between states, but only from one of `from`. Returns whether
    /// this caller made the transition — the one-use guarantee: two concurrent approvals
    /// of the same action cannot both see `true`.
    public func transitionStagedAction(
        id: String, from: [String], to: String, resultJSON: String? = nil, now: Date
    ) throws -> Bool {
        let marks = Array(repeating: "?", count: from.count).joined(separator: ", ")
        try run(
            """
            UPDATE staged_actions SET state = ?, decided_at = COALESCE(decided_at, ?),
                result_json = COALESCE(?, result_json)
            WHERE id = ? AND state IN (\(marks));
            """,
            [.text(to), .text(RCCTime.instant(now)), resultJSON.map(SQLValue.text) ?? .null, .text(id)]
                + from.map(SQLValue.text)
        )
        return changes() == 1
    }

    /// Pending actions past their expiry become `expired` (never silently executable later).
    @discardableResult
    public func expireStagedActions(now: Date) throws -> Int {
        try run(
            "UPDATE staged_actions SET state = 'expired', decided_at = ? WHERE state = 'pending' AND expires_at < ?;",
            [.text(RCCTime.instant(now)), .text(RCCTime.instant(now))]
        )
        return changes()
    }

    // MARK: - Audit log (SPEC §14)

    public struct AuditEntry: Sendable, Equatable {
        public let seq: Int
        public let at: String
        public let context: String
        public let kind: String
        public let target: String?
        public let operationID: String?
        public let operationHash: String?
        public let approvalID: String?
        public let outcome: String
    }

    /// Append one entry. There is deliberately no update or delete counterpart.
    public func appendAudit(
        context: OperationContext, kind: String, target: String?, operationID: String?,
        operationHash: String?, approvalID: String?, outcome: String, now: Date = Date()
    ) throws {
        try run(
            """
            INSERT INTO audit_log (at, context, kind, target, operation_id, operation_hash, approval_id, outcome)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """,
            [.text(RCCTime.instant(now)), .text(context.rawValue), .text(kind),
             target.map(SQLValue.text) ?? .null, operationID.map(SQLValue.text) ?? .null,
             operationHash.map(SQLValue.text) ?? .null, approvalID.map(SQLValue.text) ?? .null,
             .text(outcome)]
        )
    }

    public func auditEntries(limit: Int = 50) throws -> [AuditEntry] {
        try queryAll(
            """
            SELECT seq, at, context, kind, target, operation_id, operation_hash, approval_id, outcome
            FROM audit_log ORDER BY seq DESC LIMIT \(max(1, limit));
            """
        ) { row in
            AuditEntry(
                seq: Int(row.int(0)), at: row.text(1) ?? "", context: row.text(2) ?? "",
                kind: row.text(3) ?? "", target: row.text(4), operationID: row.text(5),
                operationHash: row.text(6), approvalID: row.text(7), outcome: row.text(8) ?? ""
            )
        }
    }
}
