import Foundation
import RCCCore

/// Runs one mutation through the crash-safe sequence the `Reconciler` expects (SPEC §9.6):
///
/// ```
/// prepareOperation (prepared)  ->  markExecuting  ->  [resolve target, if_match,
/// recurrence scope]  ->  EventKit call  ->  recordResultIdentifier  ->  markSucceeded
/// ```
///
/// A repository failure moves the row to `failed` with a stable code. Anything else thrown
/// between `markExecuting` and `markSucceeded` — a SQLite error at `markSucceeded`, a
/// crash — leaves the row `executing` for startup reconciliation; the executor
/// deliberately does not swallow it.
public struct MutationExecutor: Sendable {
    private let repository: any CalendarRepository
    private let store: Store
    /// A reused idempotency key inside this window replays the recorded outcome (SPEC §9.4).
    private let idempotencyRetention: TimeInterval

    public init(
        repository: any CalendarRepository,
        store: Store,
        idempotencyRetention: TimeInterval = 30 * 24 * 3600
    ) {
        self.repository = repository
        self.store = store
        self.idempotencyRetention = idempotencyRetention
    }

    // MARK: - Request / Outcome

    public struct Request: Sendable {
        public enum Action: Sendable {
            case createEvent(EventDraft)
            case updateEvent(EventPatch)
            case deleteEvent
            case createReminder(ReminderDraft)
            case updateReminder(ReminderPatch)
            case completeReminder(Bool)
            case deleteReminder
        }

        public var action: Action
        public var context: OperationContext
        /// Preferred target reference for update/delete/complete — a server-issued handle.
        public var targetLocator: String?
        /// Fallback target reference: a bare EventKit identifier. Rejected on its own for a
        /// recurring event (SPEC §9.4); a locator is required there.
        public var targetIdentifier: String?
        public var ifMatch: String?
        public var recurrenceScope: RecurrenceScope?
        public var idempotencyKey: String?
        /// Canonical arguments as JSON, already stripped of note/content text (SPEC §13).
        public var intentJSON: String

        public init(
            action: Action, context: OperationContext = .live,
            targetLocator: String? = nil, targetIdentifier: String? = nil,
            ifMatch: String? = nil, recurrenceScope: RecurrenceScope? = nil,
            idempotencyKey: String? = nil, intentJSON: String = "{}"
        ) {
            self.action = action
            self.context = context
            self.targetLocator = targetLocator
            self.targetIdentifier = targetIdentifier
            self.ifMatch = ifMatch
            self.recurrenceScope = recurrenceScope
            self.idempotencyKey = idempotencyKey
            self.intentJSON = intentJSON
        }
    }

    public struct Outcome: Sendable, Equatable {
        public var operationID: String
        public var resultIdentifier: String?
        /// Fresh locator handle for the affected item (create/update), for the caller to
        /// pass to a later mutation.
        public var locator: String?
        public var version: String?
        public var replayed: Bool
    }

    public enum ExecutorError: Error, Equatable {
        case notFound(String)
        case conflict(current: String)
        case locatorUnknown
        case locatorExpired
        case locatorStale
        case targetUnspecified
        case bareIdentifierRejectedForRecurring
        case recurrenceScopeRequired
        case illegalClear([String])
        case emptyPatch
        case readOnly(String)
        case repository(code: String, message: String)

        /// Stable SPEC §10.1 code.
        public var code: String {
            switch self {
            case .notFound: return "not_found"
            case .conflict: return "conflict"
            case .locatorUnknown, .targetUnspecified: return "not_found"
            case .locatorExpired: return "approval_stale"
            case .locatorStale: return "cursor_stale"
            case .bareIdentifierRejectedForRecurring, .recurrenceScopeRequired: return "unsupported"
            case .illegalClear, .emptyPatch: return "invalid_datetime"
            case .readOnly: return "read_only"
            case .repository(let code, _): return code
            }
        }
    }

    // MARK: - Execute

    public func execute(_ request: Request) async throws -> Outcome {
        if let key = request.idempotencyKey, let replay = try replay(key) {
            return replay
        }

        let kind = Self.kind(for: request.action)
        let intent = Store.OperationIntent(
            kind: kind.rawValue,
            context: request.context,
            intentJSON: request.intentJSON,
            idempotencyKey: request.idempotencyKey,
            targetHandle: request.targetLocator,
            ifMatchVersion: request.ifMatch,
            recurrenceScope: request.recurrenceScope?.rawValue
        )
        let op = try store.prepareOperation(intent)
        try store.markExecuting(op.id)

        do {
            let result = try await perform(request, kind: kind, op: op)
            if let identifier = result.resultIdentifier {
                try store.recordResultIdentifier(identifier, for: op.id)
            }
            try store.markSucceeded(op.id, resultIdentifier: result.resultIdentifier)
            return Outcome(
                operationID: op.id, resultIdentifier: result.resultIdentifier,
                locator: result.locator, version: result.version, replayed: false
            )
        } catch let error as ExecutorError {
            try? store.markFailed(op.id, errorCode: error.code, detail: "\(error)")
            throw error
        } catch let error as CalendarRepositoryError {
            try? store.markFailed(op.id, errorCode: error.code, detail: error.description)
            throw ExecutorError.repository(code: error.code, message: error.description)
        }
        // Any other throw (e.g. a SQLite error at markSucceeded) is left uncaught: the row
        // stays `executing` and startup reconciliation resolves it (SPEC §9.6).
    }

    // MARK: - Internals

    private struct PerformResult {
        var resultIdentifier: String?
        var locator: String?
        var version: String?
    }

    private func perform(
        _ request: Request, kind: OperationKind, op: OperationRecord
    ) async throws -> PerformResult {
        switch request.action {
        case .createEvent(let draft):
            let id = try await repository.createEvent(draft)
            let dto = try await repository.event(withIdentifier: id)
            let locator = try store.issueLocator(
                entityType: "event",
                calendarID: dto?.calendarIdentifier ?? draft.calendarIdentifier,
                sourceID: dto?.sourceIdentifier, itemIdentifier: id
            )
            return PerformResult(resultIdentifier: id, locator: locator.handle, version: dto?.version)

        case .updateEvent(let patch):
            guard patch.illegalClears.isEmpty else { throw ExecutorError.illegalClear(patch.illegalClears) }
            guard !patch.isEmpty else { throw ExecutorError.emptyPatch }
            let id = try await resolveTarget(request, entity: .event)
            let before = try await requireEvent(id)
            try check(ifMatch: request.ifMatch, against: before.version)
            if before.isRecurring, request.recurrenceScope == nil {
                throw ExecutorError.recurrenceScopeRequired
            }
            let saved = try await repository.updateEvent(
                identifier: id, patch: patch, scope: request.recurrenceScope
            )
            let locator = try store.issueLocator(
                entityType: "event", calendarID: saved.calendarIdentifier,
                sourceID: saved.sourceIdentifier, itemIdentifier: saved.id
            )
            return PerformResult(resultIdentifier: saved.id, locator: locator.handle, version: saved.version)

        case .deleteEvent:
            let id = try await resolveTarget(request, entity: .event)
            let before = try await requireEvent(id)
            try check(ifMatch: request.ifMatch, against: before.version)
            if before.isRecurring, request.recurrenceScope == nil {
                throw ExecutorError.recurrenceScopeRequired
            }
            // Record the target BEFORE removing it, so a crash here reconciles to succeeded.
            try store.recordResultIdentifier(id, for: op.id)
            try await repository.deleteEvent(identifier: id)
            return PerformResult(resultIdentifier: id)

        case .createReminder(let draft):
            let id = try await repository.createReminder(draft)
            let dto = try await repository.reminder(withIdentifier: id)
            let locator = try store.issueLocator(
                entityType: "reminder",
                calendarID: dto?.calendarIdentifier ?? draft.calendarIdentifier,
                sourceID: dto?.sourceIdentifier, itemIdentifier: id
            )
            return PerformResult(resultIdentifier: id, locator: locator.handle, version: dto?.version)

        case .updateReminder(let patch):
            guard patch.illegalClears.isEmpty else { throw ExecutorError.illegalClear(patch.illegalClears) }
            guard !patch.isEmpty else { throw ExecutorError.emptyPatch }
            let id = try await resolveTarget(request, entity: .reminder)
            let before = try await requireReminder(id)
            try check(ifMatch: request.ifMatch, against: before.version)
            let saved = try await repository.updateReminder(identifier: id, patch: patch)
            let locator = try store.issueLocator(
                entityType: "reminder", calendarID: saved.calendarIdentifier,
                sourceID: saved.sourceIdentifier, itemIdentifier: saved.id
            )
            return PerformResult(resultIdentifier: saved.id, locator: locator.handle, version: saved.version)

        case .completeReminder(let completed):
            let id = try await resolveTarget(request, entity: .reminder)
            let before = try await requireReminder(id)
            try check(ifMatch: request.ifMatch, against: before.version)
            let saved = try await repository.setReminderCompleted(identifier: id, completed: completed)
            let locator = try store.issueLocator(
                entityType: "reminder", calendarID: saved.calendarIdentifier,
                sourceID: saved.sourceIdentifier, itemIdentifier: saved.id
            )
            return PerformResult(resultIdentifier: saved.id, locator: locator.handle, version: saved.version)

        case .deleteReminder:
            let id = try await resolveTarget(request, entity: .reminder)
            let before = try await requireReminder(id)
            try check(ifMatch: request.ifMatch, against: before.version)
            try store.recordResultIdentifier(id, for: op.id)
            try await repository.deleteReminder(identifier: id)
            return PerformResult(resultIdentifier: id)
        }
    }

    private func resolveTarget(_ request: Request, entity: RCCEntityType) async throws -> String {
        if let handle = request.targetLocator {
            switch try store.resolveLocator(handle) {
            case .ok(let locator): return locator.itemIdentifier
            case .unknown: throw ExecutorError.locatorUnknown
            case .expired: throw ExecutorError.locatorExpired
            case .staleGeneration: throw ExecutorError.locatorStale
            }
        }
        guard let identifier = request.targetIdentifier else {
            throw ExecutorError.targetUnspecified
        }
        // A bare identifier is fine for a non-recurring target; a recurring event needs a
        // locator (SPEC §9.4). Detect recurrence and reject early with a clear reason.
        if entity == .event, request.recurrenceScope == nil,
           let event = try await repository.event(withIdentifier: identifier), event.isRecurring {
            throw ExecutorError.bareIdentifierRejectedForRecurring
        }
        return identifier
    }

    private func requireEvent(_ id: String) async throws -> EventSummary {
        guard let dto = try await repository.event(withIdentifier: id) else {
            throw ExecutorError.notFound(id)
        }
        return dto
    }

    private func requireReminder(_ id: String) async throws -> ReminderSummary {
        guard let dto = try await repository.reminder(withIdentifier: id) else {
            throw ExecutorError.notFound(id)
        }
        return dto
    }

    private func check(ifMatch provided: String?, against current: String) throws {
        guard let provided else { return }
        if provided != current { throw ExecutorError.conflict(current: current) }
    }

    private func replay(_ key: String) throws -> Outcome? {
        guard let prior = try store.operation(idempotencyKey: key) else { return nil }
        guard let preparedAt = RCCTime.parse(prior.preparedAt),
              Date().timeIntervalSince(preparedAt) < idempotencyRetention
        else {
            // Outside the window the unique index still holds the row, so the key cannot be
            // reused for a fresh operation.
            throw ExecutorError.conflict(current: "idempotency key reused outside the \(Int(idempotencyRetention / 86400))-day replay window")
        }
        return Outcome(
            operationID: prior.id, resultIdentifier: prior.resultIdentifier,
            locator: nil, version: nil, replayed: true
        )
    }

    static func kind(for action: Request.Action) -> OperationKind {
        switch action {
        case .createEvent: return OperationKind("create_event")!
        case .updateEvent: return OperationKind("update_event")!
        case .deleteEvent: return OperationKind("delete_event")!
        case .createReminder: return OperationKind("create_reminder")!
        case .updateReminder, .completeReminder: return OperationKind("update_reminder")!
        case .deleteReminder: return OperationKind("delete_reminder")!
        }
    }
}
