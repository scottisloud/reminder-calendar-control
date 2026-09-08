import Foundation
import Testing

@testable import RCCCalendar
@testable import RCCCore
@testable import RCCMCP

@Suite("ReadTools")
struct ReadToolsTests {
    private func seededRepository() async throws -> InMemoryCalendarRepository {
        let repo = InMemoryCalendarRepository(
            scenario: .init(eventStatus: .fullAccess, reminderStatus: .fullAccess)
        )
        await repo.insert(calendar: CalendarSummary(
            id: "cal-events", title: "Work", allowsContentModifications: true, isSubscribed: false,
            isImmutable: false, allowedEntityTypes: [.event],
            sourceIdentifier: "src", sourceTitle: "iCloud"
        ))
        await repo.insert(calendar: CalendarSummary(
            id: "cal-reminders", title: "Chores", allowsContentModifications: true, isSubscribed: false,
            isImmutable: false, allowedEntityTypes: [.reminder],
            sourceIdentifier: "src", sourceTitle: "iCloud"
        ))
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for hour in 0..<5 {
            _ = try await repo.createEvent(EventDraft(
                calendarIdentifier: "cal-events", title: "Meeting \(hour)",
                start: base.addingTimeInterval(Double(hour) * 3600),
                end: base.addingTimeInterval(Double(hour) * 3600 + 1800),
                notes: "agenda \(hour)"
            ))
        }
        for n in 0..<3 {
            _ = try await repo.createReminder(ReminderDraft(
                calendarIdentifier: "cal-reminders", title: "Task \(n)", notes: "detail \(n)"
            ))
        }
        return repo
    }

    private func tempStore() throws -> Store {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rcc-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try Store(url: dir.appendingPathComponent("state.sqlite3", isDirectory: false))
    }

    private func run(
        _ name: String, _ repo: any CalendarRepository,
        args: [String: Any] = [:], store: Store? = nil
    ) async throws -> [String: Any] {
        try await ReadTools.run(name, arguments: args, repository: repo, store: store)
    }

    @Test("list_sources returns the accounts")
    func listSources() async throws {
        let repo = InMemoryCalendarRepository(scenario: .init(eventStatus: .fullAccess))
        let envelope = try await run(ReadTools.listSources, repo)
        let data = try #require(envelope["data"] as? [[String: Any]])
        #expect(data.contains { $0["title"] as? String == "iCloud" })
        #expect(envelope["schema_version"] as? Int == 1)
        #expect(envelope["as_of"] as? String != nil)
    }

    @Test("list_calendars, and list_reminder_lists filters to reminder calendars")
    func listCalendars() async throws {
        let repo = try await seededRepository()

        let all = try await run(ReadTools.listCalendars, repo)
        #expect((all["data"] as? [[String: Any]])?.count == 2)

        let lists = try await run(ReadTools.listReminderLists, repo)
        let titles = try #require(lists["data"] as? [[String: Any]]).compactMap { $0["title"] as? String }
        #expect(titles == ["Chores"])
    }

    @Test("list_events requires a valid from/to window")
    func listEventsValidation() async throws {
        let repo = try await seededRepository()
        await #expect(throws: ToolError.self) { _ = try await run(ReadTools.listEvents, repo) }
        await #expect(throws: ToolError.self) {
            _ = try await run(ReadTools.listEvents, repo,
                args: ["from": "2026-01-02T00:00:00Z", "to": "2026-01-01T00:00:00Z"])
        }
    }

    @Test("list_events returns a compact projection and paginates")
    func listEventsPaginated() async throws {
        let repo = try await seededRepository()
        let args: [String: Any] = [
            "from": "2023-11-14T00:00:00.000Z",
            "to": "2023-11-16T00:00:00.000Z",
            "limit": 2,
        ]
        let first = try await run(ReadTools.listEvents, repo, args: args)
        let firstData = try #require(first["data"] as? [[String: Any]])
        #expect(firstData.count == 2)
        // Compact projection: no notes, but a has_notes flag.
        #expect(firstData[0]["notes"] == nil)
        #expect(firstData[0]["has_notes"] as? Bool == true)
        #expect(firstData[0]["version"] as? String != nil)

        let pagination = try #require(first["pagination"] as? [String: Any])
        #expect(pagination["total_matched"] as? Int == 5)
        #expect(pagination["has_more"] as? Bool == true)
        let cursor = try #require(pagination["next_cursor"] as? String)

        var seen = firstData.compactMap { $0["id"] as? String }
        var next: String? = cursor
        while let c = next {
            var pageArgs = args
            pageArgs["cursor"] = c
            let page = try await run(ReadTools.listEvents, repo, args: pageArgs)
            seen += try #require(page["data"] as? [[String: Any]]).compactMap { $0["id"] as? String }
            next = (page["pagination"] as? [String: Any])?["next_cursor"] as? String
        }
        #expect(Set(seen).count == 5)
    }

    @Test("include_details expands the event, get_event always does")
    func detailProjection() async throws {
        let repo = try await seededRepository()
        let list = try await run(ReadTools.listEvents, repo, args: [
            "from": "2023-11-14T00:00:00.000Z", "to": "2023-11-15T00:00:00.000Z",
            "include_details": true,
        ])
        let first = try #require((list["data"] as? [[String: Any]])?.first)
        #expect(first["notes"] as? String == "agenda 0")

        let id = try #require(first["id"] as? String)
        let detail = try await run(ReadTools.getEvent, repo, args: ["event_id": id])
        #expect((detail["data"] as? [String: Any])?["notes"] as? String == "agenda 0")
    }

    @Test("get_event on an unknown id is a not_found ToolError")
    func getEventNotFound() async throws {
        let repo = try await seededRepository()
        await #expect(throws: ToolError.self) {
            _ = try await run(ReadTools.getEvent, repo, args: ["event_id": "nope"])
        }
    }

    @Test("list_reminders filters by completion and text")
    func listReminders() async throws {
        let repo = try await seededRepository()

        let all = try await run(ReadTools.listReminders, repo)
        #expect((all["data"] as? [[String: Any]])?.count == 3)

        let one = try await run(ReadTools.listReminders, repo, args: ["text": "Task 1"])
        let data = try #require(one["data"] as? [[String: Any]])
        #expect(data.count == 1)
        #expect(data[0]["title"] as? String == "Task 1")
        #expect(data[0]["priority_bucket"] as? String == "none")

        let completed = try await run(ReadTools.listReminders, repo, args: ["completion": "completed"])
        #expect((completed["data"] as? [[String: Any]])?.isEmpty == true)
    }

    @Test("A cursor issued before a store change surfaces as cursor_stale")
    func staleCursor() async throws {
        let repo = try await seededRepository()
        let store = try tempStore()
        let args: [String: Any] = [
            "from": "2023-11-14T00:00:00.000Z", "to": "2023-11-16T00:00:00.000Z", "limit": 2,
        ]
        let first = try await run(ReadTools.listEvents, repo, args: args, store: store)
        let cursor = try #require((first["pagination"] as? [String: Any])?["next_cursor"] as? String)

        try store.invalidateAllLocators()  // an external calendar change

        var pageArgs = args
        pageArgs["cursor"] = cursor
        do {
            _ = try await run(ReadTools.listEvents, repo, args: pageArgs, store: store)
            Issue.record("expected cursor_stale")
        } catch let error as ToolError {
            #expect(error.code == "cursor_stale")
            #expect(error.payload["retryable"] as? Bool == true)
        }
    }

    @Test("get_event and get_reminder hand back a resolvable locator")
    func getIssuesLocator() async throws {
        let repo = try await seededRepository()
        let store = try tempStore()
        let list = try await run(ReadTools.listEvents, repo, args: [
            "from": "2023-11-14T00:00:00.000Z", "to": "2023-11-16T00:00:00.000Z",
        ], store: store)
        let eventID = try #require(((list["data"] as? [[String: Any]])?.first)?["id"] as? String)

        let detail = try await run(ReadTools.getEvent, repo, args: ["event_id": eventID], store: store)
        let handle = try #require((detail["data"] as? [String: Any])?["locator"] as? String)
        #expect(try store.resolveLocator(handle).locator?.itemIdentifier == eventID)

        // Without a store, `locator` is present but null.
        let noStore = try await run(ReadTools.getEvent, repo, args: ["event_id": eventID])
        #expect((noStore["data"] as? [String: Any])?["locator"] is NSNull)
    }

    @Test("search_events requires a query and filters post-fetch")
    func searchEvents() async throws {
        let repo = try await seededRepository()
        let window: [String: Any] = [
            "from": "2023-11-14T00:00:00.000Z", "to": "2023-11-16T00:00:00.000Z",
        ]

        await #expect(throws: ToolError.self) {
            _ = try await run(ReadTools.searchEvents, repo, args: window)
        }

        var args = window
        args["text"] = "Meeting 3"
        let hit = try await run(ReadTools.searchEvents, repo, args: args)
        let data = try #require(hit["data"] as? [[String: Any]])
        #expect(data.count == 1)
        #expect(data[0]["title"] as? String == "Meeting 3")

        // list_events with the same text works too, but without requiring it.
        let viaList = try await run(ReadTools.listEvents, repo, args: args)
        #expect((viaList["data"] as? [[String: Any]])?.count == 1)
    }

    @Test("search_reminders requires text")
    func searchReminders() async throws {
        let repo = try await seededRepository()
        await #expect(throws: ToolError.self) {
            _ = try await run(ReadTools.searchReminders, repo)
        }
        let hit = try await run(ReadTools.searchReminders, repo, args: ["text": "Task 2"])
        let data = try #require(hit["data"] as? [[String: Any]])
        #expect(data.count == 1)
        #expect(data[0]["title"] as? String == "Task 2")
    }

    @Test("A repository authorization failure maps to a permission code")
    func unauthorized() async throws {
        let repo = InMemoryCalendarRepository(scenario: .init(eventStatus: .denied))
        do {
            _ = try await run(ReadTools.listEvents, repo, args: [
                "from": "2023-11-14T00:00:00.000Z", "to": "2023-11-15T00:00:00.000Z",
            ])
            Issue.record("expected a ToolError")
        } catch let error as ToolError {
            #expect(error.code == "permission_denied")
        }
    }
}
