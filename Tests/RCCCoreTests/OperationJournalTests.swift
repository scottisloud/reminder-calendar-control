import Foundation
import Testing

@testable import RCCCore

@Suite("OperationJournal")
struct OperationJournalTests {
    private func store() throws -> Store {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rcc-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try Store(url: directory.appendingPathComponent("state.sqlite3", isDirectory: false))
    }

    private func intent(
        kind: String = "create_event",
        context: OperationContext = .live,
        json: String = #"{"title":"x"}"#,
        key: String? = nil
    ) -> Store.OperationIntent {
        Store.OperationIntent(kind: kind, context: context, intentJSON: json, idempotencyKey: key)
    }

    @Test("prepare -> executing -> succeeded, with fields round-tripping")
    func happyPath() throws {
        let store = try store()
        let prepared = try store.prepareOperation(
            intent(json: #"{"title":"Standup"}"#, key: "idem-1")
        )
        #expect(prepared.state == .prepared)
        #expect(prepared.operationHash == RCCID.hash(#"{"title":"Standup"}"#))

        try store.markExecuting(prepared.id)
        #expect(try store.operation(id: prepared.id)?.state == .executing)

        try store.markSucceeded(prepared.id, resultIdentifier: "EK-123", detail: "created")
        let done = try #require(try store.operation(id: prepared.id))
        #expect(done.state == .succeeded)
        #expect(done.resultIdentifier == "EK-123")
        #expect(done.outcomeDetail == "created")
        #expect(done.idempotencyKey == "idem-1")
        #expect(done.updatedAt >= done.preparedAt)
    }

    @Test("prepare -> executing -> failed records the error code")
    func failurePath() throws {
        let store = try store()
        let op = try store.prepareOperation(intent())
        try store.markExecuting(op.id)
        try store.markFailed(op.id, errorCode: "conflict", detail: "etag mismatch")
        let row = try #require(try store.operation(id: op.id))
        #expect(row.state == .failed)
        #expect(row.errorCode == "conflict")
    }

    @Test("outcome_unknown resolves only to reconciled or needs_human_review")
    func outcomeUnknownResolution() throws {
        let store = try store()

        let a = try store.prepareOperation(intent())
        try store.markExecuting(a.id)
        try store.markOutcomeUnknown(a.id, detail: "crash between save and journal")
        #expect(try store.operation(id: a.id)?.state == .outcomeUnknown)
        try store.resolveOutcomeUnknown(a.id, to: .reconciled, detail: "target exists, treat as succeeded")
        #expect(try store.operation(id: a.id)?.state == .reconciled)

        let b = try store.prepareOperation(intent())
        try store.markExecuting(b.id)
        try store.markOutcomeUnknown(b.id)
        try store.resolveOutcomeUnknown(b.id, to: .needsHumanReview)
        #expect(try store.operation(id: b.id)?.state == .needsHumanReview)
    }

    @Test("Illegal transitions are refused")
    func illegalTransitions() throws {
        let store = try store()
        let op = try store.prepareOperation(intent())

        // prepared -> succeeded skips executing
        #expect(throws: OperationTransitionError.self) {
            try store.markSucceeded(op.id, resultIdentifier: nil)
        }
        // double executing
        try store.markExecuting(op.id)
        #expect(throws: OperationTransitionError.self) { try store.markExecuting(op.id) }
        // succeeded is terminal
        try store.markSucceeded(op.id, resultIdentifier: "x")
        #expect(throws: OperationTransitionError.self) {
            try store.markFailed(op.id, errorCode: "internal")
        }
        // unknown id
        #expect(throws: OperationTransitionError.self) { try store.markExecuting("no-such-id") }
    }

    @Test("An idempotency key is unique and its recorded outcome is replayable")
    func idempotency() throws {
        let store = try store()
        let first = try store.prepareOperation(intent(json: #"{"n":1}"#, key: "dup"))
        try store.markExecuting(first.id)
        try store.markSucceeded(first.id, resultIdentifier: "EK-9")

        // A second prepare with the same key must not insert a competing row.
        #expect(throws: (any Error).self) {
            _ = try store.prepareOperation(intent(json: #"{"n":2}"#, key: "dup"))
        }

        let replayed = try #require(try store.operation(idempotencyKey: "dup"))
        #expect(replayed.id == first.id)
        #expect(replayed.state == .succeeded)
        #expect(replayed.resultIdentifier == "EK-9")

        // A different key is a different operation.
        #expect(try store.operation(idempotencyKey: "other") == nil)
    }

    @Test("operationsInFlight returns only executing rows; needing-review returns the unresolved ones")
    func queries() throws {
        let store = try store()

        let inflight = try store.prepareOperation(intent())
        try store.markExecuting(inflight.id)

        let unknown = try store.prepareOperation(intent())
        try store.markExecuting(unknown.id)
        try store.markOutcomeUnknown(unknown.id)

        let review = try store.prepareOperation(intent())
        try store.markExecuting(review.id)
        try store.markOutcomeUnknown(review.id)
        try store.resolveOutcomeUnknown(review.id, to: .needsHumanReview)

        let done = try store.prepareOperation(intent())
        try store.markExecuting(done.id)
        try store.markSucceeded(done.id, resultIdentifier: "x")

        #expect(try store.operationsInFlight().map(\.id) == [inflight.id])
        #expect(Set(try store.operationsNeedingReview().map(\.id)) == [unknown.id, review.id])
    }

    @Test("Pruning drops old terminal rows but never an unresolved one")
    func pruning() throws {
        let store = try store()
        let now = Date()
        let old = now.addingTimeInterval(-40 * 24 * 3600)   // 40 days ago
        let recent = now.addingTimeInterval(-1 * 24 * 3600)  // yesterday

        // Backdate rows by rewriting prepared_at directly — the public API always stamps "now".
        func backdate(_ id: String, to date: Date) throws {
            try store.run(
                "UPDATE operation_journal SET prepared_at = ? WHERE id = ?;",
                [.text(RCCTime.instant(date)), .text(id)]
            )
        }

        let oldDone = try store.prepareOperation(intent())
        try store.markExecuting(oldDone.id)
        try store.markSucceeded(oldDone.id, resultIdentifier: "x")
        try backdate(oldDone.id, to: old)

        let oldUnresolved = try store.prepareOperation(intent())
        try store.markExecuting(oldUnresolved.id)
        try store.markOutcomeUnknown(oldUnresolved.id)
        try backdate(oldUnresolved.id, to: old)

        let recentDone = try store.prepareOperation(intent())
        try store.markExecuting(recentDone.id)
        try store.markFailed(recentDone.id, errorCode: "conflict")
        try backdate(recentDone.id, to: recent)

        let pruned = try store.pruneOperations(retention: 30 * 24 * 3600, now: now)
        #expect(pruned == 1)
        #expect(try store.operation(id: oldDone.id) == nil)
        #expect(try store.operation(id: oldUnresolved.id)?.state == .outcomeUnknown)
        #expect(try store.operation(id: recentDone.id)?.state == .failed)
    }

    @Test("The journal survives a reopen of the same database file")
    func durableAcrossReopen() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rcc-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("state.sqlite3", isDirectory: false)

        let id: String
        do {
            let store = try Store(url: url)
            let op = try store.prepareOperation(intent())
            try store.markExecuting(op.id)
            id = op.id
        }
        // Simulates a crash: the process is gone, the row is still `executing`.
        let reopened = try Store(url: url)
        #expect(try reopened.operationsInFlight().map(\.id) == [id])
    }
}
