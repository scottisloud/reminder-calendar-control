import Foundation
import RCCCore

/// Startup crash recovery for the operation journal (SPEC §9.6).
///
/// SQLite can make its own rows atomic, but it cannot commit an `EKEventStore` save or
/// remove together with the journal row that records the outcome. So a crash can leave a
/// row `executing` with the EventKit side already done, half done, or untouched. On the
/// next start, `Reconciler.run()` resolves each such row against live EventKit state:
///
///  * unambiguous (the target is provably in / out of its expected post-write state)
///    → `succeeded` / `failed`
///  * anything else → `outcome_unknown`, which is **never retried automatically** and is
///    surfaced for a human via `rcc doctor` / `get_system_status`.
///
/// A `prepared` row means the process died before the write even started; EventKit was
/// never touched, so it is safe to fail it outright.
public struct Reconciler: Sendable {
    private let repository: any CalendarRepository
    private let store: Store

    public init(repository: any CalendarRepository, store: Store) {
        self.repository = repository
        self.store = store
    }

    public struct Summary: Sendable, Equatable {
        public var reconciledSucceeded: [String] = []
        public var reconciledFailed: [String] = []
        public var outcomeUnknown: [String] = []
        /// Rows left untouched because access to that entity type is not currently granted.
        public var deferred: [String] = []

        public var examined: Int {
            reconciledSucceeded.count + reconciledFailed.count + outcomeUnknown.count + deferred.count
        }
        /// Nothing needs a human and nothing was left pending.
        public var isClean: Bool { outcomeUnknown.isEmpty && deferred.isEmpty }
    }

    /// Resolve every `prepared` and `executing` row. Call once at process start, before
    /// serving requests or firing automations.
    @discardableResult
    public func run(now: Date = Date()) async throws -> Summary {
        var summary = Summary()

        // A stale `prepared` row: the writer is gone and EventKit was never called.
        for op in try store.operationsPrepared() {
            try store.markExecuting(op.id)
            try store.markFailed(
                op.id, errorCode: "internal",
                detail: "reconciled: the process exited before the write began"
            )
            summary.reconciledFailed.append(op.id)
        }

        for op in try store.operationsInFlight() {
            guard let kind = OperationKind(op.kind) else {
                try store.markOutcomeUnknown(op.id, detail: "unrecognised operation kind '\(op.kind)'")
                summary.outcomeUnknown.append(op.id)
                continue
            }

            let authorized = await repository.authorizationStatus(for: kind.entity).grantsFullAccess
            guard authorized else {
                summary.deferred.append(op.id)
                continue
            }

            let verdict = await classify(op, kind: kind)
            switch verdict {
            case .succeeded(let identifier, let detail):
                try store.markSucceeded(op.id, resultIdentifier: identifier, detail: detail)
                summary.reconciledSucceeded.append(op.id)
            case .failed(let code, let detail):
                try store.markFailed(op.id, errorCode: code, detail: detail)
                summary.reconciledFailed.append(op.id)
            case .unknown(let detail):
                try store.markOutcomeUnknown(op.id, detail: detail)
                summary.outcomeUnknown.append(op.id)
            }
        }

        return summary
    }

    // MARK: - Classification

    private enum Verdict {
        case succeeded(identifier: String?, detail: String)
        case failed(code: String, detail: String)
        case unknown(detail: String)
    }

    private func classify(_ op: OperationRecord, kind: OperationKind) async -> Verdict {
        let noun = kind.isContainer ? "\(kind.entity.rawValue) list" : kind.entity.rawValue
        func resolves(_ identifier: String) async -> Bool {
            if kind.isContainer {
                return await repository.calendarExists(identifier: identifier)
            }
            return await repository.itemExists(identifier: identifier, entityType: kind.entity)
        }

        switch kind.verb {
        case .create:
            guard let identifier = op.resultIdentifier else {
                return .unknown(detail:
                    "no identifier was recorded before the crash; cannot tell whether a \(noun) was created")
            }
            if await resolves(identifier) {
                return .succeeded(identifier: identifier, detail: "reconciled: the created \(noun) resolves")
            }
            return .unknown(detail:
                "recorded \(noun) \(identifier) no longer resolves — created then removed, or never committed")

        case .delete:
            guard let identifier = op.resultIdentifier else {
                return .unknown(detail: "no target identifier was recorded; the delete cannot be verified")
            }
            if await resolves(identifier) {
                return .unknown(detail:
                    "delete target \(identifier) still resolves — the remove may not have run; not retried")
            }
            return .succeeded(identifier: identifier, detail: "reconciled: the delete target no longer resolves")

        case .update:
            if let identifier = op.resultIdentifier, await resolves(identifier) {
                return .unknown(detail:
                    "update target \(identifier) resolves, but whether the patch applied cannot be "
                    + "determined from existence alone")
            }
            return .unknown(detail: "update outcome is indeterminate after a crash")
        }
    }
}

/// A journal `kind` string split into its verb and entity. Recognises `create_event`,
/// `update_reminder`, … and the container forms `create_reminder_list` etc. Unknown
/// strings produce `nil` so the reconciler flags them rather than guessing.
public struct OperationKind: Sendable, Equatable {
    public enum Verb: String, Sendable { case create, update, delete }

    public let verb: Verb
    public let entity: RCCEntityType
    /// True for `*_reminder_list` — the operation targets a calendar (container), not an
    /// item, so reconciliation probes calendar existence rather than item existence.
    public let isContainer: Bool

    public init?(_ raw: String) {
        if raw.hasSuffix("_list") {
            let stem = String(raw.dropLast("_list".count))
            let parts = stem.split(separator: "_", maxSplits: 1)
            guard parts.count == 2,
                  let verb = Verb(rawValue: String(parts[0])),
                  RCCEntityType(rawValue: String(parts[1])) == .reminder
            else { return nil }
            self.verb = verb
            self.entity = .reminder
            self.isContainer = true
            return
        }
        let parts = raw.split(separator: "_", maxSplits: 1)
        guard parts.count == 2,
              let verb = Verb(rawValue: String(parts[0])),
              let entity = RCCEntityType(rawValue: String(parts[1]))
        else { return nil }
        self.verb = verb
        self.entity = entity
        self.isContainer = false
    }

    public var rawValue: String {
        isContainer ? "\(verb.rawValue)_\(entity.rawValue)_list" : "\(verb.rawValue)_\(entity.rawValue)"
    }
}
