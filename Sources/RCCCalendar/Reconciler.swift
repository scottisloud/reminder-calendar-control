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
        switch kind.verb {
        case .create:
            guard let identifier = op.resultIdentifier else {
                return .unknown(detail:
                    "no item identifier was recorded before the crash; cannot tell whether a "
                    + "\(kind.entity.rawValue) was created")
            }
            if await repository.itemExists(identifier: identifier, entityType: kind.entity) {
                return .succeeded(identifier: identifier, detail: "reconciled: the created item resolves")
            }
            return .unknown(detail:
                "recorded item \(identifier) no longer resolves — created then removed, or never committed")

        case .delete:
            guard let identifier = op.resultIdentifier else {
                return .unknown(detail: "no target identifier was recorded; the delete cannot be verified")
            }
            if await repository.itemExists(identifier: identifier, entityType: kind.entity) {
                return .unknown(detail:
                    "delete target \(identifier) still resolves — the remove may not have run; not retried")
            }
            return .succeeded(identifier: identifier, detail: "reconciled: the delete target no longer resolves")

        case .update:
            if let identifier = op.resultIdentifier,
               await repository.itemExists(identifier: identifier, entityType: kind.entity) {
                return .unknown(detail:
                    "update target \(identifier) resolves, but whether the patch applied cannot be "
                    + "determined from existence alone")
            }
            return .unknown(detail: "update outcome is indeterminate after a crash")
        }
    }
}

/// A journal `kind` string (`create_event`, `update_reminder`, …) split into its verb and
/// entity. Unknown strings produce `nil` so the reconciler can flag them rather than guess.
public struct OperationKind: Sendable, Equatable {
    public enum Verb: String, Sendable { case create, update, delete }

    public let verb: Verb
    public let entity: RCCEntityType

    public init?(_ raw: String) {
        let parts = raw.split(separator: "_", maxSplits: 1)
        guard parts.count == 2,
              let verb = Verb(rawValue: String(parts[0])),
              let entity = RCCEntityType(rawValue: String(parts[1]))
        else { return nil }
        self.verb = verb
        self.entity = entity
    }

    public var rawValue: String { "\(verb.rawValue)_\(entity.rawValue)" }
}
