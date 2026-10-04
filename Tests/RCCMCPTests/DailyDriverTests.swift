import Foundation
import Testing

@testable import RCCCalendar
@testable import RCCCore
@testable import RCCMCP

/// The full-fidelity write surface: names for lists, day-vs-time due dates, repeat rules,
/// alerts, moves, batches, and recurring-occurrence targeting — each through the real tool
/// entry points against the in-memory repository.
@Suite("Daily-driver write surface")
struct DailyDriverTests {
    private struct Fixture {
        let executor: MutationExecutor
        let repo: InMemoryCalendarRepository
        let store: Store

        func write(_ name: String, _ args: [String: Any]) async throws -> WriteTools.Result {
            try await WriteTools.run(name, arguments: args, executor: executor, repository: repo)
        }

        func data(_ name: String, _ args: [String: Any]) async throws -> [String: Any] {
            try #require(try await write(name, args).payload["data"] as? [String: Any])
        }

        func read(_ name: String, _ args: [String: Any]) async throws -> [String: Any] {
            try await ReadTools.run(name, arguments: args, repository: repo, store: store)
        }
    }

    private func fixture() async throws -> Fixture {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rcc-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try Store(url: dir.appendingPathComponent("state.sqlite3", isDirectory: false))
        let repo = InMemoryCalendarRepository(
            scenario: .init(eventStatus: .fullAccess, reminderStatus: .fullAccess)
        )
        func calendar(_ id: String, _ title: String, _ types: Set<RCCEntityType>, source: String = "src") -> CalendarSummary {
            CalendarSummary(
                id: id, title: title, allowsContentModifications: true, isSubscribed: false,
                isImmutable: false, allowedEntityTypes: types, sourceIdentifier: source, sourceTitle: source
            )
        }
        await repo.insert(calendar: calendar("list-personal", "Personal", [.reminder]))
        await repo.insert(calendar: calendar("list-work", "Work", [.reminder]))
        await repo.insert(calendar: calendar("list-dup-a", "Errands", [.reminder]))
        await repo.insert(calendar: calendar("list-dup-b", "Errands", [.reminder], source: "other"))
        await repo.insert(calendar: calendar("cal-home", "Home", [.event]))
        await repo.insert(calendar: calendar("cal-work", "Work Calendar", [.event]))
        return Fixture(executor: MutationExecutor(repository: repo, store: store), repo: repo, store: store)
    }

    private func expectError(_ code: String, _ body: () async throws -> Void) async {
        do {
            try await body()
            Issue.record("expected \(code)")
        } catch let error as ToolError {
            #expect(error.code == code, "\(error.message)")
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    // MARK: - Reminders

    @Test("create_reminder: a list by name, a day-only due, a named priority — saved and echoed back")
    func createDayOnly() async throws {
        let f = try await fixture()
        let data = try await f.data(WriteTools.createReminder, [
            "list": "personal", "title": "Descale coffee maker", "due": "2026-10-05", "priority": "high",
        ])
        let reminder = try #require(data["reminder"] as? [String: Any])
        #expect(reminder["calendar_id"] as? String == "list-personal")
        #expect(reminder["priority"] as? Int == 1)
        let due = try #require(reminder["due"] as? [String: Any])
        #expect(due["granularity"] as? String == "date")
        #expect(due["day"] as? Int == 5 && due["hour"] == nil)
        #expect(reminder["alarms"] == nil)  // a day has no time to alert at
    }

    @Test("create_reminder: a timed due gets an alert at that time; `alarms: []` opts out")
    func createTimed() async throws {
        let f = try await fixture()
        let timed = try await f.data(WriteTools.createReminder, [
            "list": "Personal", "title": "Call the vet", "due": "2026-10-05T09:00:00-07:00",
        ])
        let alarms = try #require((timed["reminder"] as? [String: Any])?["alarms"] as? [[String: Any]])
        #expect(alarms.count == 1)
        #expect(alarms[0]["absolute_date"] as? String == "2026-10-05T16:00:00.000Z")

        let silent = try await f.data(WriteTools.createReminder, [
            "list": "Personal", "title": "Quiet", "due": "2026-10-05T09:00:00-07:00", "alarms": [],
        ])
        #expect((silent["reminder"] as? [String: Any])?["alarms"] == nil)
    }

    @Test("create_reminder with a repeat rule round-trips the rule; without a due date it is refused")
    func createRecurring() async throws {
        let f = try await fixture()
        let data = try await f.data(WriteTools.createReminder, [
            "list": "Personal", "title": "Change the cat diffusers", "due": "2026-10-05",
            "recurrence": ["frequency": "monthly", "interval": 1],
        ])
        let rules = try #require((data["reminder"] as? [String: Any])?["recurrence_rules"] as? [[String: Any]])
        #expect(rules.first?["frequency"] as? String == "monthly")

        await expectError("invalid_argument") {
            _ = try await f.write(WriteTools.createReminder, [
                "list": "Personal", "title": "x", "recurrence": ["frequency": "daily"],
            ])
        }
    }

    @Test("A list name matching two lists is ambiguous_target with candidates; an unknown one lists what exists")
    func nameResolution() async throws {
        let f = try await fixture()
        do {
            _ = try await f.write(WriteTools.createReminder, ["list": "Errands", "title": "x"])
            Issue.record("expected ambiguous_target")
        } catch let error as ToolError {
            #expect(error.code == "ambiguous_target")
            #expect(Set(error.candidates.compactMap { $0["id"] }) == ["list-dup-a", "list-dup-b"])
        }
        do {
            _ = try await f.write(WriteTools.createReminder, ["list": "Shopping", "title": "x"])
            Issue.record("expected not_found")
        } catch let error as ToolError {
            #expect(error.code == "not_found")
            #expect(error.message.contains("Personal") && error.message.contains("Work"))
        }
        // An id is always accepted, even where the name would be ambiguous.
        _ = try await f.write(WriteTools.createReminder, ["list": "list-dup-b", "title": "x"])
        // The old `calendar_id` spelling still works.
        _ = try await f.write(WriteTools.createReminder, ["calendar_id": "list-work", "title": "y"])
    }

    @Test("update_reminder moves lists by name, and a tracking alert follows a reschedule")
    func updateMoveAndReschedule() async throws {
        let f = try await fixture()
        let created = try await f.data(WriteTools.createReminder, [
            "list": "Personal", "title": "Call the vet", "due": "2026-10-05T09:00:00-07:00",
        ])
        let id = try #require(created["result_identifier"] as? String)

        let moved = try await f.data(WriteTools.updateReminder, [
            "identifier": id, "if_match": created["version"] as Any,
            "patch": ["list": "Work", "due": "2026-10-06T10:00:00-07:00"],
        ])
        let reminder = try #require(moved["reminder"] as? [String: Any])
        #expect(reminder["calendar_id"] as? String == "list-work")
        let alarms = try #require(reminder["alarms"] as? [[String: Any]])
        #expect(alarms.map { $0["absolute_date"] as? String } == ["2026-10-06T17:00:00.000Z"])
    }

    @Test("A patch key the tool does not know is an error, not a silent no-op")
    func unknownPatchKey() async throws {
        let f = try await fixture()
        let created = try await f.data(WriteTools.createReminder, ["list": "Personal", "title": "x"])
        await expectError("invalid_argument") {
            _ = try await f.write(WriteTools.updateReminder, [
                "identifier": created["result_identifier"] as Any, "patch": ["due_date": "2026-10-05"],
            ])
        }
    }

    @Test("complete_reminders: per-item results; a partial failure is a warning, a total one an error")
    func completeBatch() async throws {
        let f = try await fixture()
        var ids: [String] = []
        for title in ["a", "b"] {
            let data = try await f.data(WriteTools.createReminder, ["list": "Personal", "title": title])
            ids.append(data["result_identifier"] as! String)
        }

        let mixed = try await f.write(WriteTools.completeReminders, [
            "items": [["identifier": ids[0]], ["identifier": "nope"], ["identifier": ids[1]]],
        ])
        #expect(mixed.isError == false)
        let data = try #require(mixed.payload["data"] as? [String: Any])
        #expect(data["succeeded"] as? Int == 2 && data["failed"] as? Int == 1)
        let results = try #require(data["results"] as? [[String: Any]])
        #expect(results.map { $0["ok"] as? Bool } == [true, false, true])
        #expect(results[1]["code"] as? String == "not_found")
        #expect((mixed.payload["warnings"] as? [String])?.first?.hasPrefix("partial_failure") == true)
        #expect(try await f.repo.reminder(withIdentifier: ids[0])?.isCompleted == true)

        let allBad = try await f.write(WriteTools.completeReminders, ["items": [["identifier": "nope"]]])
        #expect(allBad.isError)
    }

    @Test("update_reminders moves several reminders in one call")
    func updateBatch() async throws {
        let f = try await fixture()
        var ids: [String] = []
        for title in ["a", "b", "c"] {
            let data = try await f.data(WriteTools.createReminder, ["list": "Personal", "title": title])
            ids.append(data["result_identifier"] as! String)
        }
        let result = try await f.write(WriteTools.updateReminders, [
            "items": ids.map { ["identifier": $0, "patch": ["list": "Work", "due": "2026-10-04"]] },
        ])
        #expect(result.isError == false)
        for id in ids {
            let reminder = try #require(try await f.repo.reminder(withIdentifier: id))
            #expect(reminder.calendarIdentifier == "list-work")
            #expect(reminder.dueDate?.granularity == "date")
        }
    }

    @Test("A batch over the limit is refused outright")
    func batchLimit() async throws {
        let f = try await fixture()
        await expectError("invalid_argument") {
            _ = try await f.write(WriteTools.completeReminders, [
                "items": Array(repeating: ["identifier": "x"], count: WriteTools.batchLimit + 1),
            ])
        }
    }

    // MARK: - Reads

    @Test("list_reminders: due_window filters by local-day semantics; rows carry their list's title")
    func dueWindowRead() async throws {
        let f = try await fixture()
        let calendar = Calendar.current
        let today = calendar.dateComponents([.year, .month, .day], from: Date())
        let yesterday = calendar.dateComponents([.year, .month, .day], from: Date().addingTimeInterval(-86400))
        let nextMonth = calendar.dateComponents([.year, .month, .day], from: Date().addingTimeInterval(30 * 86400))
        func iso(_ c: DateComponents) -> String { String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!) }

        _ = try await f.write(WriteTools.createReminder, ["list": "Personal", "title": "today", "due": iso(today)])
        _ = try await f.write(WriteTools.createReminder, ["list": "Work", "title": "late", "due": iso(yesterday)])
        _ = try await f.write(WriteTools.createReminder, ["list": "Personal", "title": "later", "due": iso(nextMonth)])
        _ = try await f.write(WriteTools.createReminder, ["list": "Personal", "title": "someday"])

        let envelope = try await f.read(ReadTools.listReminders, ["due_window": "overdue_or_today"])
        let rows = try #require(envelope["data"] as? [[String: Any]])
        #expect(Set(rows.compactMap { $0["title"] as? String }) == ["today", "late"])
        #expect(rows.first { $0["title"] as? String == "late" }?["list_title"] as? String == "Work")

        let byName = try await f.read(ReadTools.listReminders, ["calendar_ids": ["Work"]])
        #expect((byName["data"] as? [[String: Any]])?.map { $0["title"] as? String } == ["late"])
    }

    // MARK: - Events

    @Test("create_event: calendar by name, an all-day span by dates, a repeat rule, and alerts")
    func createEventFull() async throws {
        let f = try await fixture()
        let data = try await f.data(WriteTools.createEvent, [
            "calendar": "Home", "title": "Cabin", "all_day": true,
            "start": "2026-10-09", "end": "2026-10-11",
            "recurrence": ["frequency": "yearly", "until": "2030-12-31"],
            "alarms": [["minutes_before": 1440]],
            "location": "Tofino",
        ])
        let event = try #require(data["event"] as? [String: Any])
        #expect(event["calendar_id"] as? String == "cal-home")
        #expect(event["all_day"] as? Bool == true)
        #expect(event["start_date"] as? String == "2026-10-09")
        #expect(event["end_date"] as? String == "2026-10-11")
        #expect(event["location"] as? String == "Tofino")
        let rule = try #require((event["recurrence_rules"] as? [[String: Any]])?.first)
        #expect(rule["frequency"] as? String == "yearly")
        #expect((rule["end"] as? [String: Any])?["kind"] as? String == "date")
        let alarm = try #require((event["alarms"] as? [[String: Any]])?.first)
        #expect(alarm["relative_offset_seconds"] as? Double == -86400)
    }

    @Test("create_event: `end` defaults to an hour after a timed start")
    func defaultEnd() async throws {
        let f = try await fixture()
        let data = try await f.data(WriteTools.createEvent, [
            "calendar": "Home", "title": "Dentist", "start": "2026-10-09T15:00:00Z",
        ])
        #expect((data["event"] as? [String: Any])?["end"] as? String == "2026-10-09T16:00:00.000Z")
    }

    @Test("Weekday names, ordinals, and counts parse into the rule EventKit gets")
    func recurrenceParsing() throws {
        let rules = try WriteArguments.recurrence([
            "frequency": "monthly",
            "days_of_week": [["weekday": "friday", "ordinal": -1], "mon"],
            "count": 6,
        ])
        #expect(rules == [RecurrenceRule(
            frequency: .monthly, interval: 1,
            daysOfWeek: [.init(weekday: 6, ordinal: -1), .init(weekday: 2)],
            end: .afterOccurrences(6)
        )])
        #expect(throws: ToolError.self) { try WriteArguments.recurrence(["frequency": "fortnightly"]) }
        #expect(throws: ToolError.self) { try WriteArguments.recurrence(["frequency": "weekly", "byday": ["mo"]]) }
    }

    @Test("A recurring event's occurrence locator reaches that occurrence, and delete honours the scope")
    func occurrenceTargeting() async throws {
        let f = try await fixture()
        let occurrence = RCCTime.parse("2026-10-12T16:00:00.000Z")!
        await f.repo.insert(event: EventSummary(
            id: "series-1", title: "Standup", start: occurrence, end: occurrence.addingTimeInterval(900),
            calendarIdentifier: "cal-work", isRecurring: true, occurrenceDate: occurrence,
            recurrenceRules: [RecurrenceRule(frequency: .daily, interval: 1)]
        ))
        let listed = try await f.read(ReadTools.listEvents, [
            "from": "2026-10-12T00:00:00Z", "to": "2026-10-13T00:00:00Z",
        ])
        let row = try #require((listed["data"] as? [[String: Any]])?.first)
        #expect(row["calendar_title"] as? String == "Work Calendar")
        let locator = try #require(row["locator"] as? String)

        _ = try await f.write(WriteTools.updateEvent, [
            "locator": locator, "recurrence_scope": "this_occurrence", "patch": ["title": "Standup (moved)"],
        ])
        #expect(await f.repo.lastTargetedOccurrence == occurrence)
        #expect(await f.repo.lastEventScope == .thisOccurrence)

        // One occurrence cannot be moved to another calendar or re-ruled on its own.
        await expectError("unsupported") {
            _ = try await f.write(WriteTools.updateEvent, [
                "locator": locator, "recurrence_scope": "this_occurrence", "patch": ["calendar": "Home"],
            ])
        }

        _ = try await f.write(WriteTools.deleteEvent, [
            "locator": locator, "recurrence_scope": "this_and_future",
        ])
        #expect(await f.repo.lastEventScope == .thisAndFuture)
        #expect(await f.repo.lastTargetedOccurrence == occurrence)
    }

    @Test("update_event refuses an end before the start, after merging with the stored event")
    func mergedRangeCheck() async throws {
        let f = try await fixture()
        let created = try await f.data(WriteTools.createEvent, [
            "calendar": "Home", "title": "x", "start": "2026-10-09T15:00:00Z", "end": "2026-10-09T16:00:00Z",
        ])
        await expectError("invalid_argument") {
            _ = try await f.write(WriteTools.updateEvent, [
                "identifier": created["result_identifier"] as Any, "patch": ["start": "2026-10-09T17:00:00Z"],
            ])
        }
    }

    @Test("Server instructions describe the tools that exist, not Milestone 1")
    func instructions() {
        let text = MCPServer.instructions
        #expect(!text.contains("Milestone"))
        #expect(text.contains("due_window") && text.contains("complete_reminders"))
    }
}

extension DailyDriverTests {
    @Test("Completing a repeating reminder explains why the returned item is not completed")
    func recurringCompletionNote() async throws {
        let f = try await fixture()
        let created = try await f.data(WriteTools.createReminder, [
            "list": "Personal", "title": "Bins", "due": "2026-10-05",
            "recurrence": ["frequency": "weekly"],
        ])
        let id = try #require(created["result_identifier"] as? String)

        let done = try await f.data(WriteTools.completeReminder, ["identifier": id])
        let reminder = try #require(done["reminder"] as? [String: Any])
        #expect(reminder["completed"] as? Bool == false)
        #expect((reminder["due"] as? [String: Any])?["day"] as? Int == 12)
        #expect((done["note"] as? String)?.contains("due 2026-10-12") == true)

        // The completed occurrence exists as its own completed reminder.
        let completed = try await f.repo.listReminders(ReminderFilter(completion: .completed))
        #expect(completed.map(\.title) == ["Bins"])

        // A one-off completion carries no note.
        let oneOff = try await f.data(WriteTools.createReminder, ["list": "Personal", "title": "once"])
        let plain = try await f.data(WriteTools.completeReminder, ["identifier": oneOff["result_identifier"] as Any])
        #expect(plain["note"] == nil)
    }
}

extension DailyDriverTests {
    @Test("Paging through list_reminders visits every item exactly once, in the documented order")
    func pagedReminders() async throws {
        let f = try await fixture()
        for n in 0..<7 {
            _ = try await f.write(WriteTools.createReminder, [
                "list": "Personal", "title": "r\(n)", "due": "2026-10-\(String(format: "%02d", 10 - n))",
            ])
        }
        var seen: [String] = []
        var cursor: String?
        repeat {
            var args: [String: Any] = ["limit": 3]
            if let cursor { args["cursor"] = cursor }
            let envelope = try await f.read(ReadTools.listReminders, args)
            let rows = try #require(envelope["data"] as? [[String: Any]])
            seen += rows.compactMap { $0["title"] as? String }
            let pagination = try #require(envelope["pagination"] as? [String: Any])
            #expect(pagination["total_matched"] as? Int == 7)
            cursor = pagination["next_cursor"] as? String
        } while cursor != nil
        #expect(seen == ["r6", "r5", "r4", "r3", "r2", "r1", "r0"])  // soonest due first
    }

    @Test("queryEvents' reference implementation is list + filter + slice")
    func queryEventsContract() async throws {
        let f = try await fixture()
        for n in 0..<5 {
            _ = try await f.write(WriteTools.createEvent, [
                "calendar": "Home", "title": n.isMultiple(of: 2) ? "gym \(n)" : "work \(n)",
                "start": "2026-10-1\(n)T15:00:00Z",
            ])
        }
        let page = try await f.repo.queryEvents(EventQuery(
            from: RCCTime.parse("2026-10-01T00:00:00Z")!, to: RCCTime.parse("2026-11-01T00:00:00Z")!,
            text: "gym", offset: 1, limit: 1
        ))
        #expect(page.totalMatched == 3)
        #expect(page.items.map(\.title) == ["gym 2"])
    }
}

extension DailyDriverTests {
    @Test("An invitation from someone else is refused for update and delete; an own event is not")
    func invitationsAreReadOnly() async throws {
        let f = try await fixture()
        func person(_ name: String, me: Bool, role: String) -> Participant {
            Participant(name: name, url: "mailto:\(name)@example.com", email: "\(name)@example.com",
                        isCurrentUser: me, type: EnumValue(name: "person", raw: 1),
                        role: EnumValue(name: role, raw: 1), status: EnumValue(name: "accepted", raw: 2))
        }
        let start = RCCTime.parse("2026-10-20T16:00:00Z")!
        await f.repo.insert(event: EventSummary(
            id: "invite", title: "Their meeting", start: start, end: start.addingTimeInterval(1800),
            calendarIdentifier: "cal-work",
            participants: [person("pat", me: false, role: "chair"), person("scott", me: true, role: "required")],
            organizer: person("pat", me: false, role: "chair")
        ))
        await expectError("unsupported") {
            _ = try await f.write(WriteTools.updateEvent, ["identifier": "invite", "patch": ["title": "x"]])
        }
        await expectError("unsupported") {
            _ = try await f.write(WriteTools.deleteEvent, ["identifier": "invite"])
        }

        await f.repo.insert(event: EventSummary(
            id: "mine", title: "My meeting", start: start, end: start.addingTimeInterval(1800),
            calendarIdentifier: "cal-work",
            participants: [person("scott", me: true, role: "chair"), person("pat", me: false, role: "required")],
            organizer: person("scott", me: true, role: "chair")
        ))
        _ = try await f.write(WriteTools.updateEvent, ["identifier": "mine", "patch": ["title": "My meeting (moved)"]])
    }
}
