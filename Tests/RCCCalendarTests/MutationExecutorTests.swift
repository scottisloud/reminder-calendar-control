import Foundation
import Testing

@testable import RCCCalendar
@testable import RCCCore

@Suite("MutationExecutor")
struct MutationExecutorTests {
    private func makeStore() throws -> Store {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rcc-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try Store(url: dir.appendingPathComponent("state.sqlite3", isDirectory: false))
    }

    private func repo() async -> InMemoryCalendarRepository {
        let repo = InMemoryCalendarRepository(
            scenario: .init(eventStatus: .fullAccess, reminderStatus: .fullAccess)
        )
        await repo.insert(calendar: CalendarSummary(
            id: "cal", title: "Dev", allowsContentModifications: true, isSubscribed: false,
            isImmutable: false, allowedEntityTypes: [.event, .reminder],
            sourceIdentifier: "src", sourceTitle: "iCloud"
        ))
        return repo
    }

    private func eventDraft() -> EventDraft {
        EventDraft(
            calendarIdentifier: "cal", title: "Standup",
            start: Date(timeIntervalSince1970: 1_700_000_000),
            end: Date(timeIntervalSince1970: 1_700_003_600)
        )
    }

    // MARK: - Create

    @Test("create_event: journal succeeded, locator resolves, version present")
    func createEvent() async throws {
        let store = try makeStore()
        let repo = await repo()
        let executor = MutationExecutor(repository: repo, store: store)

        let outcome = try await executor.execute(.init(action: .createEvent(eventDraft())))
        #expect(!outcome.replayed)
        let id = try #require(outcome.resultIdentifier)
        #expect(await repo.itemExists(identifier: id, entityType: .event))
        #expect(try store.operation(id: outcome.operationID)?.state == .succeeded)

        let handle = try #require(outcome.locator)
        #expect(try store.resolveLocator(handle).locator?.itemIdentifier == id)
        #expect(outcome.version?.count == 64)
    }

    // MARK: - Update + if_match

    @Test("update_event via locator, then a stale if_match is a conflict that does not write")
    func updateWithIfMatch() async throws {
        let store = try makeStore()
        let repo = await repo()
        let executor = MutationExecutor(repository: repo, store: store)

        let created = try await executor.execute(.init(action: .createEvent(eventDraft())))
        let handle = try #require(created.locator)
        let version1 = try #require(created.version)

        var rename = EventPatch()
        rename.title = .set("Sync")
        let updated = try await executor.execute(.init(
            action: .updateEvent(rename), targetLocator: handle, ifMatch: version1
        ))
        #expect(updated.version != version1)
        let after = try await repo.event(withIdentifier: created.resultIdentifier!)
        #expect(after?.title == "Sync")

        // The stale version1 now conflicts.
        var again = EventPatch()
        again.title = .set("Too late")
        await #expect(throws: MutationExecutor.ExecutorError.self) {
            _ = try await executor.execute(.init(
                action: .updateEvent(again), targetLocator: handle, ifMatch: version1
            ))
        }
        let unchanged = try await repo.event(withIdentifier: created.resultIdentifier!)
        #expect(unchanged?.title == "Sync")
    }

    @Test("update_event: empty patch and illegal title clear are rejected")
    func updateValidation() async throws {
        let store = try makeStore()
        let repo = await repo()
        let executor = MutationExecutor(repository: repo, store: store)
        let created = try await executor.execute(.init(action: .createEvent(eventDraft())))
        let id = created.resultIdentifier!

        do {
            _ = try await executor.execute(.init(action: .updateEvent(EventPatch()), targetIdentifier: id))
            Issue.record("expected emptyPatch")
        } catch let error as MutationExecutor.ExecutorError {
            #expect(error == .emptyPatch)
        }

        var clearTitle = EventPatch()
        clearTitle.title = .clear
        do {
            _ = try await executor.execute(.init(action: .updateEvent(clearTitle), targetIdentifier: id))
            Issue.record("expected illegalClear")
        } catch let error as MutationExecutor.ExecutorError {
            #expect(error == .illegalClear(["title"]))
        }
    }

    // MARK: - Recurrence scope

    @Test("A recurring event refuses a bare identifier, and an update without a scope")
    func recurrenceGuards() async throws {
        let store = try makeStore()
        let repo = await repo()
        await repo.insert(event: EventSummary(
            id: "evt-weekly", title: "Weekly", start: Date(timeIntervalSince1970: 1_700_000_000),
            end: Date(timeIntervalSince1970: 1_700_003_600), calendarIdentifier: "cal",
            isRecurring: true,
            recurrenceRules: [RecurrenceRule(frequency: .weekly, interval: 1)]
        ))
        let executor = MutationExecutor(repository: repo, store: store)

        var patch = EventPatch()
        patch.title = .set("Weekly sync")

        // Bare identifier, no scope -> rejected before touching EventKit.
        do {
            _ = try await executor.execute(.init(action: .updateEvent(patch), targetIdentifier: "evt-weekly"))
            Issue.record("expected bareIdentifierRejectedForRecurring")
        } catch let error as MutationExecutor.ExecutorError {
            #expect(error == .bareIdentifierRejectedForRecurring)
        }

        // Locator but still no scope -> recurrenceScopeRequired.
        let locator = try store.issueLocator(
            entityType: "event", calendarID: "cal", sourceID: nil, itemIdentifier: "evt-weekly"
        )
        do {
            _ = try await executor.execute(.init(
                action: .updateEvent(patch), targetLocator: locator.handle
            ))
            Issue.record("expected recurrenceScopeRequired")
        } catch let error as MutationExecutor.ExecutorError {
            #expect(error == .recurrenceScopeRequired)
        }

        // With a scope it goes through.
        let ok = try await executor.execute(.init(
            action: .updateEvent(patch), targetLocator: locator.handle,
            recurrenceScope: .thisAndFuture
        ))
        #expect(ok.resultIdentifier == "evt-weekly")
    }

    // MARK: - Delete

    @Test("delete_event records the target before removing it, and the journal is succeeded")
    func deleteEvent() async throws {
        let store = try makeStore()
        let repo = await repo()
        let executor = MutationExecutor(repository: repo, store: store)
        let created = try await executor.execute(.init(action: .createEvent(eventDraft())))
        let id = created.resultIdentifier!

        let deleted = try await executor.execute(.init(
            action: .deleteEvent, targetLocator: created.locator
        ))
        #expect(deleted.resultIdentifier == id)
        #expect(await repo.itemExists(identifier: id, entityType: .event) == false)
        let row = try #require(try store.operation(id: deleted.operationID))
        #expect(row.state == .succeeded)
        #expect(row.resultIdentifier == id)
    }

    // MARK: - Locator lifecycle

    @Test("Locator lifecycle: unknown, expired, and stale-without-if_match fail distinctly")
    func locatorLifecycle() async throws {
        let store = try makeStore()
        let repo = await repo()
        await repo.insert(event: EventSummary(
            id: "evt-1", title: "Fixed", start: Date(timeIntervalSince1970: 1_700_000_000),
            end: Date(timeIntervalSince1970: 1_700_003_600), calendarIdentifier: "cal"
        ))
        let executor = MutationExecutor(repository: repo, store: store)
        let patch = { var p = EventPatch(); p.title = .set("x"); return p }()

        await #expect(throws: MutationExecutor.ExecutorError.locatorUnknown) {
            _ = try await executor.execute(.init(action: .updateEvent(patch), targetLocator: "deadbeef"))
        }

        let expiring = try store.issueLocator(
            entityType: "event", calendarID: "cal", sourceID: nil, itemIdentifier: "evt-1",
            ttl: 10, now: Date(timeIntervalSince1970: 1_000_000)
        )
        await #expect(throws: MutationExecutor.ExecutorError.locatorExpired) {
            _ = try await executor.execute(.init(action: .updateEvent(patch), targetLocator: expiring.handle))
        }

        // A handle from before a store change: usable, but only with an if_match.
        let handle = try store.issueLocator(
            entityType: "event", calendarID: "cal", sourceID: nil, itemIdentifier: "evt-1"
        )
        let currentVersion = try #require(try await repo.event(withIdentifier: "evt-1")).version
        try store.invalidateAllLocators()

        await #expect(throws: MutationExecutor.ExecutorError.staleTargetNeedsIfMatch) {
            _ = try await executor.execute(.init(action: .updateEvent(patch), targetLocator: handle.handle))
        }
        // With the current if_match it goes through.
        let ok = try await executor.execute(.init(
            action: .updateEvent(patch), targetLocator: handle.handle, ifMatch: currentVersion
        ))
        #expect(ok.resultIdentifier == "evt-1")
    }

    // MARK: - Idempotency

    @Test("A reused idempotency key replays the recorded outcome, does not re-execute")
    func idempotencyReplay() async throws {
        let store = try makeStore()
        let repo = await repo()
        let executor = MutationExecutor(repository: repo, store: store)

        let first = try await executor.execute(.init(
            action: .createEvent(eventDraft()), idempotencyKey: "make-standup"
        ))
        #expect(!first.replayed)

        let replay = try await executor.execute(.init(
            action: .createEvent(eventDraft()), idempotencyKey: "make-standup"
        ))
        #expect(replay.replayed)
        #expect(replay.operationID == first.operationID)
        #expect(replay.resultIdentifier == first.resultIdentifier)

        // Exactly one event was created.
        let events = try await repo.listEvents(
            calendarIdentifiers: ["cal"],
            from: Date(timeIntervalSince1970: 1_699_000_000),
            to: Date(timeIntervalSince1970: 1_701_000_000)
        )
        #expect(events.count == 1)
    }

    // MARK: - Repository failure

    @Test("A repository failure moves the journal row to failed with the repo's code")
    func repositoryFailure() async throws {
        let store = try makeStore()
        let repo = await repo()
        await repo.setScenario(.init(
            eventStatus: .fullAccess, reminderStatus: .fullAccess,
            nextWriteFailure: .readOnly("cal")
        ))
        let executor = MutationExecutor(repository: repo, store: store)

        do {
            _ = try await executor.execute(.init(action: .createEvent(eventDraft())))
            Issue.record("expected a repository error")
        } catch let error as MutationExecutor.ExecutorError {
            #expect(error.code == "read_only")
        }
        // The most recent journal row is failed (terminal, not "needs review").
        #expect(try store.operationsNeedingReview().isEmpty)
        let operationID = try #require(try store.queryFirst(
            "SELECT id FROM operation_journal ORDER BY prepared_at DESC LIMIT 1;", []
        ) { $0.text(0) ?? "" })
        #expect(try store.operation(id: operationID)?.state == .failed)
        #expect(try store.operation(id: operationID)?.errorCode == "read_only")
    }

    // MARK: - Reminders

    @Test("complete_reminder sets completion, update_reminder patches fields")
    func reminderMutations() async throws {
        let store = try makeStore()
        let repo = await repo()
        let executor = MutationExecutor(repository: repo, store: store)

        let created = try await executor.execute(.init(
            action: .createReminder(ReminderDraft(calendarIdentifier: "cal", title: "Water plants"))
        ))
        let id = created.resultIdentifier!

        var patch = ReminderPatch()
        patch.priorityRaw = .set(1)
        patch.notes = .set("the big one on the balcony")
        _ = try await executor.execute(.init(action: .updateReminder(patch), targetLocator: created.locator))
        let patched = try await repo.reminder(withIdentifier: id)
        #expect(patched?.priorityRaw == 1)
        #expect(patched?.priorityBucket == "high")

        let done = try await executor.execute(.init(
            action: .completeReminder(true), targetIdentifier: id
        ))
        let completed = try await repo.reminder(withIdentifier: done.resultIdentifier!)
        #expect(completed?.isCompleted == true)
        #expect(completed?.completionDate != nil)
    }
}
