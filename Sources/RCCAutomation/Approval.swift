import Foundation
import RCCCalendar
import RCCCore

/// Executes or rejects a staged action (SPEC §8.3). Called only from the CLI
/// (`rcc automations approve|reject`); there is no MCP path to it, in any context.
///
/// Execution re-resolves every item and passes its staged `version` as `if_match`, so an
/// item that changed since it was staged is refused (`conflict`) rather than deleted on
/// the strength of a stale preview. Each item runs through `MutationExecutor` with its own
/// journal row and an idempotency key derived from the action, so an approval that dies
/// half-way can be resumed: items already done replay their recorded outcome instead of
/// running twice.
public struct StagedActionExecutor: Sendable {
    private let repository: any CalendarRepository
    private let store: Store

    public init(repository: any CalendarRepository, store: Store) {
        self.repository = repository
        self.store = store
    }

    public struct ItemResult: Sendable, Equatable {
        public let identifier: String
        public let title: String
        /// `deleted`, `already_deleted`, `changed_since_staged`, or `failed:<code>`.
        public let outcome: String
    }

    public struct Result: Sendable, Equatable {
        public let actionID: String
        /// `executed`, `partially_executed`, or `stale`.
        public let state: String
        public let items: [ItemResult]
    }

    public enum ApprovalError: Error, Equatable, CustomStringConvertible {
        case notFound(String)
        case notPending(String, state: String)
        case expired(String)

        public var description: String {
            switch self {
            case .notFound(let id): return "No staged action \(id)."
            case .notPending(let id, let state): return "Staged action \(id) is already \(state); an approval is one-use."
            case .expired(let id): return "Staged action \(id) expired before it was approved; the rule will stage a fresh one on its next run."
            }
        }
    }

    public func items(of action: Store.StagedActionRecord) -> [MatchedItem] {
        guard let array = try? JSONSerialization.jsonObject(with: Data(action.itemsJSON.utf8)) as? [[String: Any]] else {
            return []
        }
        return array.compactMap(MatchedItem.init(json:))
    }

    public func approve(_ id: String, now: Date = Date()) async throws -> Result {
        guard let action = try store.stagedAction(id: id) else { throw ApprovalError.notFound(id) }
        if action.state == "pending", let expiry = RCCTime.parse(action.expiresAt), expiry < now {
            _ = try store.transitionStagedAction(id: id, from: ["pending"], to: "expired", now: now)
            throw ApprovalError.expired(id)
        }
        // pending → executing is the one-use gate. `executing` is accepted too, so an
        // approval interrupted by a crash can be finished; the per-item idempotency keys
        // make that resumption safe.
        let claimed = try action.state == "executing"
            || store.transitionStagedAction(id: id, from: ["pending"], to: "executing", now: now)
        guard claimed else {
            throw ApprovalError.notPending(id, state: (try store.stagedAction(id: id))?.state ?? action.state)
        }

        let executor = MutationExecutor(repository: repository, store: store)
        var results: [ItemResult] = []
        for (index, item) in items(of: action).enumerated() {
            // One occurrence of a recurring event is reachable only through a locator that
            // carries its occurrence date; a bare identifier resolves to the first one.
            let locator = try item.occurrenceDate.map { date in
                try store.issueLocator(entityType: item.entity.rawValue, calendarID: "", sourceID: nil,
                                       itemIdentifier: item.identifier, occurrenceDate: RCCTime.instant(date)).handle
            }
            let request = MutationExecutor.Request(
                action: item.entity == .event ? .deleteEvent : .deleteReminder,
                context: .tier0,
                targetLocator: locator,
                targetIdentifier: locator == nil ? item.identifier : nil,
                ifMatch: item.version,
                recurrenceScope: item.occurrenceDate == nil ? nil : .thisOccurrence,
                idempotencyKey: "staged:\(id):\(index)",
                intentJSON: #"{"kind":"approved_staged_delete"}"#,
                approvalID: id
            )
            let outcome: String
            do {
                _ = try await executor.execute(request)
                outcome = "deleted"
            } catch let error as MutationExecutor.ExecutorError {
                // By code, not case: a resumed approval sees the original failure re-surfaced
                // through an idempotent replay as `.repository(code:)`.
                switch error.code {
                case "conflict": outcome = "changed_since_staged"
                case "not_found": outcome = "already_deleted"
                default: outcome = "failed:\(error.code)"
                }
            }
            results.append(ItemResult(identifier: item.identifier, title: item.title, outcome: outcome))
        }

        let acted = results.filter { $0.outcome == "deleted" || $0.outcome == "already_deleted" }.count
        let state = acted == results.count ? "executed" : acted == 0 ? "stale" : "partially_executed"
        let resultJSON = String(decoding: try JSONSerialization.data(
            withJSONObject: results.map { ["identifier": $0.identifier, "outcome": $0.outcome] },
            options: [.sortedKeys]), as: UTF8.self)
        _ = try store.transitionStagedAction(id: id, from: ["executing"], to: state, resultJSON: resultJSON, now: now)
        return Result(actionID: id, state: state, items: results)
    }

    public func reject(_ id: String, now: Date = Date()) throws {
        guard let action = try store.stagedAction(id: id) else { throw ApprovalError.notFound(id) }
        guard try store.transitionStagedAction(id: id, from: ["pending"], to: "rejected", now: now) else {
            throw ApprovalError.notPending(id, state: action.state)
        }
        try store.appendAudit(context: .cli, kind: "reject_staged_action", target: action.ruleID,
                              operationID: nil, operationHash: nil, approvalID: id, outcome: "rejected", now: now)
    }
}
