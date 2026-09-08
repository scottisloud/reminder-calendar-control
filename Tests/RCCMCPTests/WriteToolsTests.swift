import Foundation
import Testing

@testable import RCCCalendar
@testable import RCCCore
@testable import RCCMCP

@Suite("WriteTools")
struct WriteToolsTests {
    private func setup() async throws -> (MutationExecutor, InMemoryCalendarRepository, Store) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rcc-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try Store(url: dir.appendingPathComponent("state.sqlite3", isDirectory: false))
        let repo = InMemoryCalendarRepository(
            scenario: .init(eventStatus: .fullAccess, reminderStatus: .fullAccess)
        )
        await repo.insert(calendar: CalendarSummary(
            id: "cal", title: "Dev", allowsContentModifications: true, isSubscribed: false,
            isImmutable: false, allowedEntityTypes: [.event, .reminder],
            sourceIdentifier: "src", sourceTitle: "iCloud"
        ))
        return (MutationExecutor(repository: repo, store: store), repo, store)
    }

    private func run(_ name: String, _ args: [String: Any], _ ex: MutationExecutor) async throws -> [String: Any] {
        try await WriteTools.run(name, arguments: args, executor: ex)
    }

    @Test("create_event returns the outcome envelope and a resolvable locator")
    func createEvent() async throws {
        let (ex, repo, store) = try await setup()
        let envelope = try await run(WriteTools.createEvent, [
            "calendar_id": "cal", "title": "Standup",
            "start": "2026-09-10T09:00:00.000Z", "end": "2026-09-10T09:30:00.000Z",
        ], ex)
        let data = try #require(envelope["data"] as? [String: Any])
        let id = try #require(data["result_identifier"] as? String)
        #expect(await repo.itemExists(identifier: id, entityType: .event))
        let handle = try #require(data["locator"] as? String)
        #expect(try store.resolveLocator(handle).locator?.itemIdentifier == id)
        #expect((data["version"] as? String)?.count == 64)
        #expect(data["replayed"] as? Bool == false)
    }

    @Test("update_event: included key sets, explicit null clears, omitted key leaves alone")
    func updatePatchSemantics() async throws {
        let (ex, repo, _) = try await setup()
        let created = try #require(try await run(WriteTools.createEvent, [
            "calendar_id": "cal", "title": "Old", "notes": "keep me",
            "start": "2026-09-10T09:00:00.000Z", "end": "2026-09-10T09:30:00.000Z",
        ], ex)["data"] as? [String: Any])
        let id = created["result_identifier"] as! String

        // set title, clear location (already nil, no-op but legal), leave notes untouched.
        _ = try await run(WriteTools.updateEvent, [
            "locator": created["locator"] as! String,
            "if_match": created["version"] as! String,
            "patch": ["title": "New", "location": NSNull()],
        ], ex)
        let after = try await repo.event(withIdentifier: id)
        #expect(after?.title == "New")
        #expect(after?.notes == "keep me")   // omitted → unchanged

        // now clear notes explicitly
        _ = try await run(WriteTools.updateEvent, [
            "identifier": id,
            "patch": ["notes": NSNull()],
        ], ex)
        #expect(try await repo.event(withIdentifier: id)?.notes == nil)
    }

    @Test("A stale if_match through the tool is a conflict ToolError")
    func conflict() async throws {
        let (ex, _, _) = try await setup()
        let created = try #require(try await run(WriteTools.createEvent, [
            "calendar_id": "cal", "title": "T",
            "start": "2026-09-10T09:00:00.000Z", "end": "2026-09-10T09:30:00.000Z",
        ], ex)["data"] as? [String: Any])
        let staleVersion = created["version"] as! String
        let locator = created["locator"] as! String

        _ = try await run(WriteTools.updateEvent, [
            "locator": locator, "if_match": staleVersion, "patch": ["title": "T2"],
        ], ex)

        do {
            _ = try await run(WriteTools.updateEvent, [
                "locator": locator, "if_match": staleVersion, "patch": ["title": "T3"],
            ], ex)
            Issue.record("expected a conflict")
        } catch let error as ToolError {
            #expect(error.code == "conflict")
        }
    }

    @Test("delete_event removes the item; a bad patch and missing fields are rejected")
    func deleteAndValidation() async throws {
        let (ex, repo, _) = try await setup()
        let created = try #require(try await run(WriteTools.createEvent, [
            "calendar_id": "cal", "title": "T",
            "start": "2026-09-10T09:00:00.000Z", "end": "2026-09-10T09:30:00.000Z",
        ], ex)["data"] as? [String: Any])
        let id = created["result_identifier"] as! String

        await #expect(throws: ToolError.self) {
            _ = try await run(WriteTools.createEvent, ["title": "no calendar"], ex)
        }
        await #expect(throws: ToolError.self) {
            _ = try await run(WriteTools.updateEvent, ["identifier": id, "patch": [:] as [String: Any]], ex)
        }

        _ = try await run(WriteTools.deleteEvent, ["locator": created["locator"] as! String], ex)
        #expect(await repo.itemExists(identifier: id, entityType: .event) == false)
    }

    @Test("complete_reminder and update_reminder go through the tool")
    func reminders() async throws {
        let (ex, repo, _) = try await setup()
        let created = try #require(try await run(WriteTools.createReminder, [
            "calendar_id": "cal", "title": "Water plants",
        ], ex)["data"] as? [String: Any])
        let id = created["result_identifier"] as! String

        _ = try await run(WriteTools.updateReminder, [
            "locator": created["locator"] as! String,
            "patch": ["priority": 2, "due": "2026-09-11T17:00:00.000Z"],
        ], ex)
        let patched = try await repo.reminder(withIdentifier: id)
        #expect(patched?.priorityRaw == 2)
        #expect(patched?.dueDate != nil)

        _ = try await run(WriteTools.completeReminder, ["identifier": id], ex)
        #expect(try await repo.reminder(withIdentifier: id)?.isCompleted == true)
    }

    @Test("An idempotency key replays through the tool")
    func idempotency() async throws {
        let (ex, repo, _) = try await setup()
        let args: [String: Any] = [
            "calendar_id": "cal", "title": "once",
            "start": "2026-09-10T09:00:00.000Z", "end": "2026-09-10T09:30:00.000Z",
            "idempotency_key": "k1",
        ]
        let first = try #require(try await run(WriteTools.createEvent, args, ex)["data"] as? [String: Any])
        let second = try #require(try await run(WriteTools.createEvent, args, ex)["data"] as? [String: Any])
        #expect(second["replayed"] as? Bool == true)
        #expect(second["operation_id"] as? String == first["operation_id"] as? String)

        let all = try await repo.listEvents(
            calendarIdentifiers: ["cal"],
            from: Date(timeIntervalSince1970: 1_757_000_000),
            to: Date(timeIntervalSince1970: 1_800_000_000)
        )
        #expect(all.count == 1)
    }

    @Test("Descriptors: delete tools are the only destructive ones, none claim read-only")
    func descriptorShape() {
        for tool in WriteTools.descriptors {
            let name = tool["name"] as! String
            let annotations = tool["annotations"] as! [String: Any]
            #expect(annotations["readOnlyHint"] as? Bool == false)
            #expect(annotations["destructiveHint"] as? Bool == WriteTools.destructive.contains(name))
        }
    }
}
