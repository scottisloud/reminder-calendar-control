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
            case createReminderList(title: String, sourceIdentifier: String)
            case updateReminderList(title: String)
            case deleteReminderList
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
        /// Reminders removed alongside a deleted list (SPEC §9.3).
        public var affectedCount: Int?
        public var replayed: Bool
        /// The item as saved — the canonical re-fetch SPEC §10.1 promises after a write.
        /// `nil` for deletes and replays.
        public var event: EventSummary?
        public var reminder: ReminderSummary?
        /// A created or renamed reminder list.
        public var calendar: CalendarSummary?
    }

    public enum ExecutorError: Error, Equatable {
        case notFound(String)
        case conflict(current: String)
        /// The handle predates an external calendar change; the caller must re-read the
        /// item and pass its `if_match` to confirm what they are acting on (SPEC §9.4).
        case staleTargetNeedsIfMatch
        case locatorUnknown
        case locatorExpired
        case targetUnspecified
        case bareIdentifierRejectedForRecurring
        case recurrenceScopeRequired
        case illegalClear([String])
        case emptyPatch
        /// A request that is well-formed but asks for something incoherent.
        case invalid(String)
        /// Something EventKit cannot do for this target (e.g. moving one occurrence of a
        /// series to another calendar).
        case unsupported(String)
        case readOnly(String)
        case repository(code: String, message: String)

        /// Stable SPEC §10.1 code.
        public var code: String {
            switch self {
            case .notFound: return "not_found"
            case .conflict, .staleTargetNeedsIfMatch: return "conflict"
            case .locatorUnknown, .targetUnspecified: return "not_found"
            case .locatorExpired: return "approval_stale"
            case .bareIdentifierRejectedForRecurring, .recurrenceScopeRequired, .unsupported:
                return "unsupported"
            case .illegalClear, .emptyPatch, .invalid: return "invalid_argument"
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
                locator: result.locator, version: result.version,
                affectedCount: result.affectedCount, replayed: false,
                event: result.event, reminder: result.reminder, calendar: result.calendar
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
        var affectedCount: Int?
        var event: EventSummary?
        var reminder: ReminderSummary?
        var calendar: CalendarSummary?
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
            return PerformResult(resultIdentifier: id, locator: locator.handle, version: dto?.version, event: dto)

        case .updateEvent(let patch):
            guard patch.illegalClears.isEmpty else { throw ExecutorError.illegalClear(patch.illegalClears) }
            guard !patch.isEmpty else { throw ExecutorError.emptyPatch }
            let target = try await resolveTarget(request, entity: .event)
            let before = try await requireEvent(target)
            try refuseIfInvitation(before)
            try check(ifMatch: request.ifMatch, against: before.version)
            if before.isRecurring {
                guard let scope = request.recurrenceScope else { throw ExecutorError.recurrenceScopeRequired }
                if scope == .thisOccurrence, patch.calendarIdentifier.isChange {
                    throw ExecutorError.unsupported(
                        "one occurrence cannot move to another calendar on its own; use 'this_and_future'"
                    )
                }
                if scope == .thisOccurrence, patch.recurrenceRules.isChange {
                    throw ExecutorError.unsupported(
                        "a repeat rule belongs to the series, not one occurrence; use 'this_and_future'"
                    )
                }
            }
            let start = { if case .set(let value) = patch.start { return value } else { return before.start } }()
            let end = { if case .set(let value) = patch.end { return value } else { return before.end } }()
            guard end >= start else { throw ExecutorError.invalid("`end` must not precede `start`") }
            let saved = try await repository.updateEvent(
                identifier: target.identifier, occurrenceDate: target.occurrenceDate,
                patch: patch, scope: request.recurrenceScope
            )
            let locator = try store.issueLocator(
                entityType: "event", calendarID: saved.calendarIdentifier,
                sourceID: saved.sourceIdentifier, itemIdentifier: saved.id,
                // A detached occurrence shares the series' identifier too, so it needs its
                // slot recorded just like a live one.
                occurrenceDate: saved.isRecurring || saved.isDetached
                    ? saved.occurrenceDate.map(RCCTime.instant) : nil
            )
            return PerformResult(
                resultIdentifier: saved.id, locator: locator.handle, version: saved.version, event: saved
            )

        case .deleteEvent:
            let target = try await resolveTarget(request, entity: .event)
            let before = try await requireEvent(target)
            try refuseIfInvitation(before)
            try check(ifMatch: request.ifMatch, against: before.version)
            if before.isRecurring, request.recurrenceScope == nil {
                throw ExecutorError.recurrenceScopeRequired
            }
            // Record the target BEFORE removing it, so a crash here reconciles to succeeded.
            try store.recordResultIdentifier(target.identifier, for: op.id)
            try await repository.deleteEvent(
                identifier: target.identifier, occurrenceDate: target.occurrenceDate,
                scope: request.recurrenceScope
            )
            return PerformResult(resultIdentifier: target.identifier)

        case .createReminder(let draft):
            if !draft.recurrenceRules.isEmpty, draft.dueDate == nil {
                throw ExecutorError.invalid("a repeating reminder needs a `due` date to repeat from")
            }
            let id = try await repository.createReminder(draft)
            let dto = try await repository.reminder(withIdentifier: id)
            let locator = try store.issueLocator(
                entityType: "reminder",
                calendarID: dto?.calendarIdentifier ?? draft.calendarIdentifier,
                sourceID: dto?.sourceIdentifier, itemIdentifier: id
            )
            return PerformResult(
                resultIdentifier: id, locator: locator.handle, version: dto?.version, reminder: dto
            )

        case .updateReminder(var patch):
            guard patch.illegalClears.isEmpty else { throw ExecutorError.illegalClear(patch.illegalClears) }
            guard !patch.isEmpty else { throw ExecutorError.emptyPatch }
            let id = try await resolveTarget(request, entity: .reminder).identifier
            let before = try await requireReminder(id)
            try check(ifMatch: request.ifMatch, against: before.version)
            let willRepeat = !(patch.recurrenceRules.resolved(from: before.recurrenceRules) ?? []).isEmpty
            let willHaveDue: Bool = {
                switch patch.dueDate {
                case .unchanged: return before.dueDate != nil
                case .set: return true
                case .clear: return false
                }
            }()
            if willRepeat, !willHaveDue {
                throw ExecutorError.invalid("a repeating reminder needs a `due` date to repeat from")
            }
            // An alert that was tracking the due time follows it (Reminders.app behaviour),
            // unless the caller said what the alerts should be.
            if patch.dueDate.isChange, !patch.alarms.isChange {
                let newDue: ReminderDate? = { if case .set(let value) = patch.dueDate { return value } else { return nil } }()
                if let alarms = ReminderAlertDefaults.afterDueChange(
                    oldDue: before.dueDate.flatMap { $0.granularity == "date" ? nil : $0.resolvedDate() },
                    newDue: newDue, current: before.alarms
                ) {
                    patch.alarms = .set(alarms)
                }
            }
            let saved = try await repository.updateReminder(identifier: id, patch: patch)
            let locator = try store.issueLocator(
                entityType: "reminder", calendarID: saved.calendarIdentifier,
                sourceID: saved.sourceIdentifier, itemIdentifier: saved.id
            )
            return PerformResult(
                resultIdentifier: saved.id, locator: locator.handle, version: saved.version, reminder: saved
            )

        case .completeReminder(let completed):
            let id = try await resolveTarget(request, entity: .reminder).identifier
            let before = try await requireReminder(id)
            try check(ifMatch: request.ifMatch, against: before.version)
            let saved = try await repository.setReminderCompleted(identifier: id, completed: completed)
            let locator = try store.issueLocator(
                entityType: "reminder", calendarID: saved.calendarIdentifier,
                sourceID: saved.sourceIdentifier, itemIdentifier: saved.id
            )
            return PerformResult(
                resultIdentifier: saved.id, locator: locator.handle, version: saved.version, reminder: saved
            )

        case .deleteReminder:
            let id = try await resolveTarget(request, entity: .reminder).identifier
            let before = try await requireReminder(id)
            try check(ifMatch: request.ifMatch, against: before.version)
            try store.recordResultIdentifier(id, for: op.id)
            try await repository.deleteReminder(identifier: id)
            return PerformResult(resultIdentifier: id)

        case .createReminderList(let title, let sourceIdentifier):
            let calendar = try await repository.createReminderList(
                title: title, sourceIdentifier: sourceIdentifier
            )
            return PerformResult(resultIdentifier: calendar.id, calendar: calendar)

        case .updateReminderList(let title):
            guard let id = request.targetIdentifier ?? request.targetLocator else {
                throw ExecutorError.targetUnspecified
            }
            let calendar = try await repository.updateReminderList(identifier: id, title: title)
            return PerformResult(resultIdentifier: calendar.id, calendar: calendar)

        case .deleteReminderList:
            guard let id = request.targetIdentifier ?? request.targetLocator else {
                throw ExecutorError.targetUnspecified
            }
            try store.recordResultIdentifier(id, for: op.id)
            let removed = try await repository.deleteReminderList(identifier: id)
            return PerformResult(resultIdentifier: id, affectedCount: removed)
        }
    }

    /// What a mutation acts on: the item, and for a recurring event the one occurrence the
    /// caller read (carried by its locator).
    private struct Target {
        var identifier: String
        var occurrenceDate: Date?
    }

    private func resolveTarget(_ request: Request, entity: RCCEntityType) async throws -> Target {
        if let handle = request.targetLocator {
            switch try store.resolveLocator(handle) {
            case .ok(let locator):
                // A handle from before an external change is still usable, but only with an
                // `if_match` — re-resolving proves the item exists, not that it is the one
                // the caller last saw (SPEC §9.4).
                if request.ifMatch == nil, try !store.isLocatorCurrent(locator) {
                    throw ExecutorError.staleTargetNeedsIfMatch
                }
                return Target(
                    identifier: locator.itemIdentifier,
                    occurrenceDate: locator.occurrenceDate.flatMap(RCCTime.parse)
                )
            case .unknown: throw ExecutorError.locatorUnknown
            case .expired: throw ExecutorError.locatorExpired
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
        return Target(identifier: identifier)
    }

    /// An event someone else organised, that the user was invited to, is not theirs to
    /// edit or delete through rcc (SPEC §8.4, §12). On CalDAV and Exchange, deleting an
    /// invitation can send the organiser a decline and an edit can send a counter-proposal
    /// — a participation-status write by another route, which public EventKit does not let
    /// rcc do deliberately and which it must not do by accident. Claude for iOS documents
    /// the same line: edit only events you organised.
    private func refuseIfInvitation(_ event: EventSummary) throws {
        guard let organizer = event.organizer, !organizer.isCurrentUser,
              event.participants.contains(where: \.isCurrentUser)
        else { return }
        throw ExecutorError.unsupported(
            "this is an invitation from \(organizer.name ?? organizer.email ?? "someone else"); "
                + "rcc does not edit or delete events you did not organise, because that can send "
                + "the organiser a reply. Change it in Calendar instead."
        )
    }

    private func requireEvent(_ target: Target) async throws -> EventSummary {
        guard let dto = try await repository.event(
            withIdentifier: target.identifier, occurrenceDate: target.occurrenceDate
        ) else {
            throw ExecutorError.notFound(target.identifier)
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
            locator: nil, version: nil, affectedCount: nil, replayed: true,
            event: nil, reminder: nil, calendar: nil
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
        case .createReminderList: return OperationKind("create_reminder_list")!
        case .updateReminderList: return OperationKind("update_reminder_list")!
        case .deleteReminderList: return OperationKind("delete_reminder_list")!
        }
    }
}
