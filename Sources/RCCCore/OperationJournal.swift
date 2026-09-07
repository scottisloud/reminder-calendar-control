import Foundation

/// The durable state machine every mutating operation passes through (SPEC §9.6).
///
/// ```
/// prepared -> executing -> succeeded
///                      \-> failed
///                      \-> outcome_unknown -> reconciled | needs_human_review
/// ```
///
/// The row is written at `prepared` **before** EventKit is called, so a crash mid-write
/// always leaves a trace. On the next start, any row still `executing` is reconciled
/// against live EventKit state; if the outcome can't be determined it becomes
/// `outcome_unknown` and is **never** retried automatically — a human resolves it.
public enum OperationState: String, Sendable, CaseIterable {
    case prepared
    case executing
    case succeeded
    case failed
    case outcomeUnknown = "outcome_unknown"
    case reconciled
    case needsHumanReview = "needs_human_review"

    /// A terminal state needs no further action.
    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .reconciled, .needsHumanReview: return true
        case .prepared, .executing, .outcomeUnknown: return false
        }
    }
}

/// Where a mutation originated. Governs the write-safety policy (SPEC §8.3).
public enum OperationContext: String, Sendable, CaseIterable {
    case live    // a live Claude Desktop tool call
    case tier0   // a deterministic automation rule
    case tier1   // an LLM-in-the-loop automation rule
    case cli     // a human at `rcc automations …`
}

/// One row of the operation journal.
public struct OperationRecord: Sendable, Equatable {
    public let id: String
    public let kind: String
    public let state: OperationState
    public let context: OperationContext
    /// Canonical arguments as JSON, with note/content text already stripped (SPEC §13).
    public let intentJSON: String
    public let operationHash: String
    public let idempotencyKey: String?
    public let targetHandle: String?
    public let ifMatchVersion: String?
    public let recurrenceScope: String?
    public let resultIdentifier: String?
    public let outcomeDetail: String?
    public let errorCode: String?
    public let preparedAt: String
    public let updatedAt: String

    public init(
        id: String, kind: String, state: OperationState, context: OperationContext,
        intentJSON: String, operationHash: String, idempotencyKey: String?,
        targetHandle: String?, ifMatchVersion: String?, recurrenceScope: String?,
        resultIdentifier: String?, outcomeDetail: String?, errorCode: String?,
        preparedAt: String, updatedAt: String
    ) {
        self.id = id
        self.kind = kind
        self.state = state
        self.context = context
        self.intentJSON = intentJSON
        self.operationHash = operationHash
        self.idempotencyKey = idempotencyKey
        self.targetHandle = targetHandle
        self.ifMatchVersion = ifMatchVersion
        self.recurrenceScope = recurrenceScope
        self.resultIdentifier = resultIdentifier
        self.outcomeDetail = outcomeDetail
        self.errorCode = errorCode
        self.preparedAt = preparedAt
        self.updatedAt = updatedAt
    }
}

/// Raised when a caller tries an illegal state-machine move (e.g. marking a `prepared`
/// row succeeded without going through `executing`, or touching a row that a concurrent
/// process already advanced).
public struct OperationTransitionError: Error, CustomStringConvertible, Sendable {
    public let id: String
    public let attempted: String
    public var description: String {
        "operation \(id): \(attempted) is not a legal transition from its current state"
    }
}

extension Store {
    /// The plan for a mutation, before any of it has happened.
    public struct OperationIntent: Sendable {
        public var kind: String
        public var context: OperationContext
        /// Canonical arguments as JSON — the caller is responsible for stripping
        /// note/content text first (SPEC §13). Hashed into `operation_hash`.
        public var intentJSON: String
        public var idempotencyKey: String?
        public var targetHandle: String?
        public var ifMatchVersion: String?
        public var recurrenceScope: String?

        public init(
            kind: String, context: OperationContext, intentJSON: String,
            idempotencyKey: String? = nil, targetHandle: String? = nil,
            ifMatchVersion: String? = nil, recurrenceScope: String? = nil
        ) {
            self.kind = kind
            self.context = context
            self.intentJSON = intentJSON
            self.idempotencyKey = idempotencyKey
            self.targetHandle = targetHandle
            self.ifMatchVersion = ifMatchVersion
            self.recurrenceScope = recurrenceScope
        }
    }

    /// Persist a new operation at `prepared`. Call this **before** touching EventKit.
    ///
    /// If `intent.idempotencyKey` collides with an existing row, this throws rather than
    /// inserting — the caller should have checked `operation(idempotencyKey:)` first and
    /// replayed the recorded outcome (SPEC §9.4).
    @discardableResult
    public func prepareOperation(_ intent: OperationIntent) throws -> OperationRecord {
        let now = RCCTime.instant()
        let record = OperationRecord(
            id: RCCID.operation(),
            kind: intent.kind,
            state: .prepared,
            context: intent.context,
            intentJSON: intent.intentJSON,
            operationHash: RCCID.hash(intent.intentJSON),
            idempotencyKey: intent.idempotencyKey,
            targetHandle: intent.targetHandle,
            ifMatchVersion: intent.ifMatchVersion,
            recurrenceScope: intent.recurrenceScope,
            resultIdentifier: nil,
            outcomeDetail: nil,
            errorCode: nil,
            preparedAt: now,
            updatedAt: now
        )
        func optional(_ value: String?) -> Store.SQLValue { value.map(Store.SQLValue.text) ?? .null }
        let values: [Store.SQLValue] = [
            .text(record.id),
            .text(record.kind),
            .text(record.state.rawValue),
            .text(record.context.rawValue),
            .text(record.intentJSON),
            .text(record.operationHash),
            optional(record.idempotencyKey),
            optional(record.targetHandle),
            optional(record.ifMatchVersion),
            optional(record.recurrenceScope),
            .text(record.preparedAt),
            .text(record.updatedAt),
            .int(Store.currentSchemaVersion),
        ]
        try run(
            """
            INSERT INTO operation_journal
                (id, kind, state, context, intent_json, operation_hash, idempotency_key,
                 target_handle, if_match_version, recurrence_scope, result_identifier,
                 outcome_detail, error_code, prepared_at, updated_at, schema_version)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, NULL, ?, ?, ?);
            """,
            values
        )
        return record
    }

    public func operation(id: String) throws -> OperationRecord? {
        try queryFirst(Self.operationSelect + " WHERE id = ?;", [.text(id)], Self.decodeOperation)
    }

    public func operation(idempotencyKey key: String) throws -> OperationRecord? {
        try queryFirst(
            Self.operationSelect + " WHERE idempotency_key = ?;", [.text(key)], Self.decodeOperation
        )
    }

    /// prepared → executing.
    public func markExecuting(_ id: String) throws {
        try transition(id, to: .executing, from: [.prepared], sets: [:])
    }

    /// Record the affected item's identifier while the row is still `executing`, right
    /// after the EventKit call returns it and *before* `markSucceeded`. This is what makes
    /// a crash in the gap between "EventKit saved" and "journal updated" recoverable to
    /// `succeeded` rather than `outcome_unknown` (SPEC §9.6). Does not change state.
    public func recordResultIdentifier(_ identifier: String, for id: String) throws {
        try run(
            """
            UPDATE operation_journal
            SET result_identifier = ?, updated_at = ?
            WHERE id = ? AND state = 'executing';
            """,
            [.text(identifier), .text(RCCTime.instant()), .text(id)]
        )
        guard changes() == 1 else {
            throw OperationTransitionError(id: id, attempted: "record result_identifier")
        }
    }

    /// executing → succeeded, recording the affected item's identifier.
    public func markSucceeded(_ id: String, resultIdentifier: String?, detail: String? = nil) throws {
        try transition(id, to: .succeeded, from: [.executing], sets: [
            "result_identifier": resultIdentifier.map(Store.SQLValue.text) ?? .null,
            "outcome_detail": detail.map(Store.SQLValue.text) ?? .null,
        ])
    }

    /// executing → failed, recording the stable error code (SPEC §10.1).
    public func markFailed(_ id: String, errorCode: String, detail: String? = nil) throws {
        try transition(id, to: .failed, from: [.executing], sets: [
            "error_code": .text(errorCode),
            "outcome_detail": detail.map(Store.SQLValue.text) ?? .null,
        ])
    }

    /// executing → outcome_unknown: a crash or an EventKit result we can't classify.
    /// Never retried automatically (SPEC §9.6).
    public func markOutcomeUnknown(_ id: String, detail: String? = nil) throws {
        try transition(id, to: .outcomeUnknown, from: [.executing], sets: [
            "outcome_detail": detail.map(Store.SQLValue.text) ?? .null,
        ])
    }

    /// outcome_unknown → reconciled | needs_human_review, after startup reconciliation
    /// against live EventKit state.
    public func resolveOutcomeUnknown(
        _ id: String, to state: OperationState, detail: String? = nil
    ) throws {
        precondition(
            state == .reconciled || state == .needsHumanReview,
            "an outcome_unknown row resolves only to reconciled or needs_human_review"
        )
        try transition(id, to: state, from: [.outcomeUnknown], sets: [
            "outcome_detail": detail.map(Store.SQLValue.text) ?? .null,
        ])
    }

    /// Rows a crash left mid-write: still `executing`. Reconcile each on the next start.
    public func operationsInFlight() throws -> [OperationRecord] {
        try queryAll(
            Self.operationSelect + " WHERE state = 'executing' ORDER BY prepared_at;",
            [], Self.decodeOperation
        )
    }

    /// Rows that never left `prepared`: the process died before the write began, so
    /// EventKit was never touched. Reconciliation fails these outright.
    public func operationsPrepared() throws -> [OperationRecord] {
        try queryAll(
            Self.operationSelect + " WHERE state = 'prepared' ORDER BY prepared_at;",
            [], Self.decodeOperation
        )
    }

    /// Rows that need a human: `outcome_unknown` (not yet reconciled) or
    /// `needs_human_review`. Surfaced by `rcc doctor` / `get_system_status`.
    public func operationsNeedingReview() throws -> [OperationRecord] {
        try queryAll(
            Self.operationSelect
                + " WHERE state IN ('outcome_unknown', 'needs_human_review') ORDER BY prepared_at;",
            [], Self.decodeOperation
        )
    }

    /// Drop terminal rows whose `prepared_at` is older than `retention`. Pass the
    /// idempotency-key window here (SPEC §9.4 says 30 days): a terminal row younger than
    /// that is kept so a replay still finds its recorded outcome.
    ///
    /// An **unresolved** row (`prepared`, `executing`, `outcome_unknown`,
    /// `needs_human_review`) is never pruned, however old — losing it would lose the only
    /// record that a write may have half-happened.
    @discardableResult
    public func pruneOperations(retention: TimeInterval, now: Date = Date()) throws -> Int {
        let cutoff = RCCTime.instant(now.addingTimeInterval(-retention))
        try run(
            """
            DELETE FROM operation_journal
            WHERE state IN ('succeeded', 'failed', 'reconciled')
              AND prepared_at < ?;
            """,
            [.text(cutoff)]
        )
        return changes()
    }

    // MARK: - Internals

    private static let operationSelect = """
        SELECT id, kind, state, context, intent_json, operation_hash, idempotency_key,
               target_handle, if_match_version, recurrence_scope, result_identifier,
               outcome_detail, error_code, prepared_at, updated_at
        FROM operation_journal
        """

    private static func decodeOperation(_ row: Store.Row) -> OperationRecord {
        OperationRecord(
            id: row.text(0) ?? "",
            kind: row.text(1) ?? "",
            state: OperationState(rawValue: row.text(2) ?? "") ?? .needsHumanReview,
            context: OperationContext(rawValue: row.text(3) ?? "") ?? .live,
            intentJSON: row.text(4) ?? "",
            operationHash: row.text(5) ?? "",
            idempotencyKey: row.text(6),
            targetHandle: row.text(7),
            ifMatchVersion: row.text(8),
            recurrenceScope: row.text(9),
            resultIdentifier: row.text(10),
            outcomeDetail: row.text(11),
            errorCode: row.text(12),
            preparedAt: row.text(13) ?? "",
            updatedAt: row.text(14) ?? ""
        )
    }

    private func transition(
        _ id: String,
        to newState: OperationState,
        from allowed: [OperationState],
        sets: [String: Store.SQLValue]
    ) throws {
        let allowedList = allowed.map { "'\($0.rawValue)'" }.joined(separator: ", ")
        var assignments = ["state = ?", "updated_at = ?"]
        var values: [Store.SQLValue] = [.text(newState.rawValue), .text(RCCTime.instant())]
        for (column, value) in sets.sorted(by: { $0.key < $1.key }) {
            assignments.append("\(column) = ?")
            values.append(value)
        }
        values.append(.text(id))
        try run(
            """
            UPDATE operation_journal
            SET \(assignments.joined(separator: ", "))
            WHERE id = ? AND state IN (\(allowedList));
            """,
            values
        )
        guard changes() == 1 else {
            throw OperationTransitionError(id: id, attempted: "-> \(newState.rawValue)")
        }
    }
}
