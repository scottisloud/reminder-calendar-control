import Foundation
import Testing

@testable import RCCCalendar
@testable import RCCCore

/// SPEC §15 / §9.6: crash injection at every operation-journal transition, including the
/// EventKit-success / SQLite-failure fault specifically. Each test drives the executor
/// sequence by hand, stops at the "crash" point, then runs `Reconciler` against a fresh
/// `Store` handle over the same file and asserts the recovery is correct **and safe** —
/// never a silent retry.
@Suite("Reconciler — crash recovery")
struct ReconcilerTests {
    private func makeStore() throws -> (Store, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rcc-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("state.sqlite3", isDirectory: false)
        return (try Store(url: url), url)
    }

    private func repository(authorized: Bool = true) async -> InMemoryCalendarRepository {
        let status: RCCAuthorizationStatus = authorized ? .fullAccess : .notDetermined
        let repo = InMemoryCalendarRepository(
            scenario: .init(eventStatus: status, reminderStatus: status)
        )
        await repo.insert(calendar: CalendarSummary(
            id: "cal-1", title: "Dev", allowsContentModifications: true, isSubscribed: false,
            isImmutable: false, allowedEntityTypes: [.event, .reminder],
            sourceIdentifier: "src-local", sourceTitle: "On My Mac"
        ))
        return repo
    }

    private func draftEvent() -> EventDraft {
        EventDraft(
            calendarIdentifier: "cal-1", title: "Standup",
            start: Date(timeIntervalSince1970: 1_700_000_000),
            end: Date(timeIntervalSince1970: 1_700_003_600)
        )
    }

    private func intent(_ kind: String = "create_event", key: String? = nil) -> Store.OperationIntent {
        Store.OperationIntent(kind: kind, context: .live, intentJSON: #"{"title":"Standup"}"#, idempotencyKey: key)
    }

    // MARK: - prepared

    @Test("Fault right after prepare: EventKit untouched, row is failed")
    func faultAfterPrepare() async throws {
        let (store, url) = try makeStore()
        let repo = await repository()
        let op = try store.prepareOperation(intent())
        // crash — nothing else happened.

        let summary = try await Reconciler(repository: repo, store: try Store(url: url)).run()
        #expect(summary.reconciledFailed == [op.id])
        #expect(summary.isClean)
        let row = try #require(try Store(url: url).operation(id: op.id))
        #expect(row.state == .failed)
        #expect(row.errorCode == "internal")
    }

    // MARK: - executing, create

    @Test("Fault after markExecuting, before the EventKit call: outcome_unknown, no item")
    func faultBeforeEventKit() async throws {
        let (store, url) = try makeStore()
        let repo = await repository()
        let op = try store.prepareOperation(intent())
        try store.markExecuting(op.id)
        // crash — EventKit never called.

        let summary = try await Reconciler(repository: repo, store: try Store(url: url)).run()
        #expect(summary.outcomeUnknown == [op.id])
        #expect(!summary.isClean)
        #expect(try Store(url: url).operation(id: op.id)?.state == .outcomeUnknown)
        #expect(await repo.itemExists(identifier: "evt-1", entityType: .event) == false)
    }

    @Test("EventKit-success / SQLite-failure BEFORE the id is recorded: orphan item, outcome_unknown")
    func faultAfterSaveBeforeRecordId() async throws {
        let (store, url) = try makeStore()
        let repo = await repository()
        let op = try store.prepareOperation(intent())
        try store.markExecuting(op.id)
        let created = try await repo.createEvent(draftEvent())  // EventKit succeeded
        // crash — recordResultIdentifier never ran, so the row can't be linked to `created`.

        let summary = try await Reconciler(repository: repo, store: try Store(url: url)).run()
        #expect(summary.outcomeUnknown == [op.id])
        #expect(await repo.itemExists(identifier: created, entityType: .event))  // orphan left in place, not deleted
    }

    @Test("EventKit-success / SQLite-failure AT markSucceeded: id was recorded, so it reconciles to succeeded")
    func faultAtMarkSucceeded() async throws {
        let (store, url) = try makeStore()
        let repo = await repository()
        let op = try store.prepareOperation(intent(key: "idem-A"))
        try store.markExecuting(op.id)
        let created = try await repo.createEvent(draftEvent())
        try store.recordResultIdentifier(created, for: op.id)
        // crash — markSucceeded itself is the SQLite write that failed.

        let summary = try await Reconciler(repository: repo, store: try Store(url: url)).run()
        #expect(summary.reconciledSucceeded == [op.id])
        #expect(summary.isClean)
        let row = try #require(try Store(url: url).operation(id: op.id))
        #expect(row.state == .succeeded)
        #expect(row.resultIdentifier == created)
    }

    @Test("Recorded id no longer resolves (resync removed it): outcome_unknown, not a blind re-create")
    func faultAfterRecordButItemGone() async throws {
        let (store, url) = try makeStore()
        let repo = await repository()
        let op = try store.prepareOperation(intent())
        try store.markExecuting(op.id)
        let created = try await repo.createEvent(draftEvent())
        try store.recordResultIdentifier(created, for: op.id)
        try await repo.deleteEvent(identifier: created)  // an account resync, say

        let summary = try await Reconciler(repository: repo, store: try Store(url: url)).run()
        #expect(summary.outcomeUnknown == [op.id])
    }

    // MARK: - executing, delete

    @Test("Delete fault before remove: target still present -> outcome_unknown, never retried")
    func deleteFaultBeforeRemove() async throws {
        let (store, url) = try makeStore()
        let repo = await repository()
        let target = try await repo.createEvent(draftEvent())

        let op = try store.prepareOperation(intent("delete_event"))
        try store.markExecuting(op.id)
        try store.recordResultIdentifier(target, for: op.id)
        // crash — remove() never ran.

        let summary = try await Reconciler(repository: repo, store: try Store(url: url)).run()
        #expect(summary.outcomeUnknown == [op.id])
        #expect(await repo.itemExists(identifier: target, entityType: .event))  // not deleted by recovery
    }

    @Test("Delete fault after remove: target gone -> reconciles to succeeded")
    func deleteFaultAfterRemove() async throws {
        let (store, url) = try makeStore()
        let repo = await repository()
        let target = try await repo.createEvent(draftEvent())

        let op = try store.prepareOperation(intent("delete_event"))
        try store.markExecuting(op.id)
        try store.recordResultIdentifier(target, for: op.id)
        try await repo.deleteEvent(identifier: target)
        // crash — markSucceeded never ran.

        let summary = try await Reconciler(repository: repo, store: try Store(url: url)).run()
        #expect(summary.reconciledSucceeded == [op.id])
    }

    // MARK: - edges

    @Test("Not authorized: rows are deferred, left executing, summary is not clean")
    func deferredWhenUnauthorized() async throws {
        let (store, url) = try makeStore()
        let repo = await repository(authorized: false)
        let op = try store.prepareOperation(intent())
        try store.markExecuting(op.id)

        let summary = try await Reconciler(repository: repo, store: try Store(url: url)).run()
        #expect(summary.deferred == [op.id])
        #expect(!summary.isClean)
        #expect(try Store(url: url).operation(id: op.id)?.state == .executing)  // untouched, retried next start
    }

    @Test("Unrecognised kind is flagged, not guessed")
    func unknownKind() async throws {
        let (store, url) = try makeStore()
        let repo = await repository()
        let op = try store.prepareOperation(intent("frobnicate_event"))
        try store.markExecuting(op.id)

        let summary = try await Reconciler(repository: repo, store: try Store(url: url)).run()
        #expect(summary.outcomeUnknown == [op.id])
    }

    @Test("A container op reconciles against calendar existence, not item existence")
    func containerReconcile() async throws {
        let (store, url) = try makeStore()
        let repo = await repository()
        await repo.insert(calendar: CalendarSummary(
            id: "list-1", title: "L", allowsContentModifications: true, isSubscribed: false,
            isImmutable: false, allowedEntityTypes: [.reminder],
            sourceIdentifier: "s", sourceTitle: "S"
        ))

        // create_reminder_list crash after the calendar was made + id recorded → succeeded.
        let made = try store.prepareOperation(
            Store.OperationIntent(kind: "create_reminder_list", context: .live, intentJSON: "{}")
        )
        try store.markExecuting(made.id)
        try store.recordResultIdentifier("list-1", for: made.id)

        // delete_reminder_list whose target no longer resolves → succeeded.
        let gone = try store.prepareOperation(
            Store.OperationIntent(kind: "delete_reminder_list", context: .live, intentJSON: "{}")
        )
        try store.markExecuting(gone.id)
        try store.recordResultIdentifier("list-removed", for: gone.id)

        let summary = try await Reconciler(repository: repo, store: try Store(url: url)).run()
        #expect(Set(summary.reconciledSucceeded) == [made.id, gone.id])
    }

    @Test("A clean start reconciles nothing")
    func cleanStart() async throws {
        let (_, url) = try makeStore()
        let repo = await repository()
        let summary = try await Reconciler(repository: repo, store: try Store(url: url)).run()
        #expect(summary.examined == 0)
        #expect(summary.isClean)
    }

    @Test("After reconciliation, an idempotency-key replay returns the recovered outcome")
    func replayAfterRecovery() async throws {
        let (store, url) = try makeStore()
        let repo = await repository()
        let op = try store.prepareOperation(intent(key: "idem-Z"))
        try store.markExecuting(op.id)
        let created = try await repo.createEvent(draftEvent())
        try store.recordResultIdentifier(created, for: op.id)
        // crash at markSucceeded, then restart + reconcile
        _ = try await Reconciler(repository: repo, store: try Store(url: url)).run()

        // A retry of the same logical operation looks the key up first.
        let replay = try #require(try Store(url: url).operation(idempotencyKey: "idem-Z"))
        #expect(replay.id == op.id)
        #expect(replay.state == .succeeded)
        #expect(replay.resultIdentifier == created)
    }

    @Test("Every executing row is examined exactly once per run")
    func mixedBatch() async throws {
        let (store, url) = try makeStore()
        let repo = await repository()

        let clean = try store.prepareOperation(intent(key: "a"))
        try store.markExecuting(clean.id)
        let id = try await repo.createEvent(draftEvent())
        try store.recordResultIdentifier(id, for: clean.id)

        let murky = try store.prepareOperation(intent(key: "b"))
        try store.markExecuting(murky.id)

        let bad = try store.prepareOperation(intent("frobnicate_reminder", key: "c"))
        try store.markExecuting(bad.id)

        let summary = try await Reconciler(repository: repo, store: try Store(url: url)).run()
        #expect(summary.reconciledSucceeded == [clean.id])
        #expect(Set(summary.outcomeUnknown) == [murky.id, bad.id])
        #expect(summary.examined == 3)
        // Re-running finds nothing new — everything already terminal or outcome_unknown.
        let second = try await Reconciler(repository: repo, store: try Store(url: url)).run()
        #expect(second.examined == 0)
    }
}
