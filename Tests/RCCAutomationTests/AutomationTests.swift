import Foundation
import Testing

@testable import RCCAutomation
@testable import RCCCalendar
@testable import RCCCore

// MARK: - Fixtures

final class RecordingNotifier: AutomationNotifier, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [(String, String)] = []
    var sent: [(String, String)] { lock.withLock { _sent } }
    func notify(title: String, body: String) { lock.withLock { _sent.append((title, body)) } }
}

struct Harness {
    let repo: InMemoryCalendarRepository
    let store: Store
    let notifier = RecordingNotifier()
    static let zone = TimeZone(identifier: "America/Vancouver")!

    static func make() async throws -> Harness {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rcc-auto-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try Store(url: dir.appendingPathComponent("state.sqlite3"))
        let repo = InMemoryCalendarRepository(scenario: .init(eventStatus: .fullAccess, reminderStatus: .fullAccess))
        func cal(_ id: String, _ title: String, _ types: Set<RCCEntityType>) -> CalendarSummary {
            CalendarSummary(id: id, title: title, allowsContentModifications: true, isSubscribed: false,
                            isImmutable: false, allowedEntityTypes: types, sourceIdentifier: "src", sourceTitle: "iCloud")
        }
        await repo.insert(calendar: cal("list-personal", "Personal", [.reminder]))
        await repo.insert(calendar: cal("list-work", "Work", [.reminder]))
        await repo.insert(calendar: cal("cal-work", "Work Calendar", [.event]))
        return Harness(repo: repo, store: store)
    }

    func runner(owner: String = "test") -> AutomationRunner {
        AutomationRunner(repository: repo, store: store, notifier: notifier, owner: owner)
    }

    var catalog: RuleCatalog { RuleCatalog(repository: repo, store: store) }

    func completed(_ id: String, list: String = "list-personal", daysAgo: Double, now: Date) async {
        await repo.insert(reminder: ReminderSummary(
            id: id, title: "done \(id)", isCompleted: true, calendarIdentifier: list,
            completionDate: now.addingTimeInterval(-daysAgo * 86_400)
        ))
    }

    static func at(_ iso: String) -> Date { RCCTime.parse(iso)! }
}

func person(_ name: String, me: Bool = false) -> Participant {
    Participant(name: name, url: "mailto:\(name)@x.com", email: "\(name)@x.com", isCurrentUser: me,
                type: EnumValue(name: "person", raw: 1), role: EnumValue(name: "required", raw: 1),
                status: EnumValue(name: "accepted", raw: 2))
}

var cleanupRule: [String: Any] { [
    "name": "Tidy Personal", "time_zone": "America/Vancouver", "schedule": ["daily_at": "02:00"],
    "trigger": ["completed_reminders": ["older_than_days": 30, "lists": ["Personal"]]], "action": "delete",
] }

var flagRule: [String: Any] { [
    "name": "Meetings missing a place", "time_zone": "America/Vancouver",
    "schedule": ["weekly": ["days": ["monday", "tuesday", "wednesday", "thursday", "friday"], "at": "07:30"]],
    "trigger": ["events_without_location": ["days_ahead": 7]], "action": "flag",
] }

// MARK: - DSL

@Suite("Rule DSL")
struct RuleDSLTests {
    @Test("A valid rule round-trips through its canonical JSON")
    func roundTrip() throws {
        let rule = try RuleDefinition(json: flagRule)
        #expect(try RuleDefinition(canonicalJSON: rule.canonicalJSON) == rule)
        #expect(rule.schedule == .weekly(weekdays: [2, 3, 4, 5, 6], hour: 7, minute: 30))
        #expect(rule.misfirePolicy == .runOnce && rule.maxFanOut == 50 && rule.maxLatenessMinutes == 720)
    }

    @Test("The allowlist: unknown keys, unknown triggers, and out-of-range values are refused")
    func refusals() {
        func refused(_ patch: (inout [String: Any]) -> Void) -> Bool {
            var doc = cleanupRule; patch(&doc)
            return (try? RuleDefinition(json: doc)) == nil
        }
        #expect(refused { $0["shell"] = "rm -rf /" })
        #expect(refused { $0["trigger"] = ["applescript": ["source": "x"]] })
        #expect(refused { $0["schedule"] = ["cron": "* * * * *"] })
        #expect(refused { $0["schedule"] = ["every_minutes": 1] })            // finer than launchd fires
        #expect(refused { $0["schedule"] = ["daily_at": "25:00"] })
        #expect(refused { $0["dsl_version"] = 2 })
        #expect(refused { $0["time_zone"] = "Mars/Olympus" })
        #expect(refused { $0["max_fan_out"] = 10_000 })
        #expect(refused { $0["trigger"] = ["completed_reminders": ["older_than_days": 30]] })  // no lists
        #expect(refused { $0["trigger"] = ["events_without_location": ["days_ahead": 7]] })    // delete + events
    }
}

// MARK: - Schedule

@Suite("Schedule")
struct ScheduleTests {
    let zone = Harness.zone
    /// Vancouver is permanent UTC−7 from March 2026, so the DST cases use Los Angeles,
    /// which still changes clocks.
    let dstZone = TimeZone(identifier: "America/Los_Angeles")!

    @Test("Daily slots are local wall-clock times")
    func daily() {
        let next = RuleDefinition.Schedule.daily(hour: 2, minute: 0)
            .nextSlot(after: Harness.at("2026-10-03T19:00:00Z"), in: zone)
        #expect(next == Harness.at("2026-10-04T09:00:00Z"))  // 02:00 PDT
    }

    @Test("A slot in the spring-forward gap fires at the next valid time, once")
    func springForward() {
        // 2027-03-14: 02:00–03:00 does not exist in Los Angeles.
        let schedule = RuleDefinition.Schedule.daily(hour: 2, minute: 30)
        let slot = schedule.nextSlot(after: Harness.at("2027-03-14T08:00:00Z"), in: dstZone)
        #expect(slot >= Harness.at("2027-03-14T10:00:00Z") && slot < Harness.at("2027-03-14T11:00:00Z"),
                "\(RCCTime.instant(slot))")  // just after the gap, that day
        #expect(schedule.nextSlot(after: slot, in: dstZone) == Harness.at("2027-03-15T09:30:00Z"))
    }

    @Test("A slot in the repeated fall-back hour fires on its first occurrence only")
    func fallBack() {
        // 2026-11-01: 01:00–02:00 happens twice in Los Angeles.
        let schedule = RuleDefinition.Schedule.daily(hour: 1, minute: 30)
        let slot = schedule.nextSlot(after: Harness.at("2026-11-01T07:00:00Z"), in: dstZone)
        #expect(slot == Harness.at("2026-11-01T08:30:00Z"))  // first 01:30, PDT
        #expect(schedule.nextSlot(after: slot, in: dstZone) == Harness.at("2026-11-02T09:30:00Z"))  // PST, not again at 09:30Z Nov 1
    }

    @Test("Vancouver no longer changes clocks: 02:00 is 09:00Z all year")
    func vancouverPermanentDaylight() {
        let schedule = RuleDefinition.Schedule.daily(hour: 2, minute: 0)
        #expect(schedule.nextSlot(after: Harness.at("2026-12-01T00:00:00Z"), in: zone) == Harness.at("2026-12-01T09:00:00Z"))
    }

    @Test("Weekly picks the soonest listed weekday")
    func weekly() {
        // Saturday 2026-10-03 → Monday 07:30.
        let next = RuleDefinition.Schedule.weekly(weekdays: [2, 6], hour: 7, minute: 30)
            .nextSlot(after: Harness.at("2026-10-03T19:00:00Z"), in: zone)
        #expect(next == Harness.at("2026-10-05T14:30:00Z"))
    }
}

// MARK: - Runner

@Suite("Automation runner", .serialized)
struct RunnerTests {
    @Test("A delete rule stages — it never deletes — and a later run supersedes the pending stage")
    func deleteIsStaged() async throws {
        let h = try await Harness.make()
        let created = Harness.at("2026-10-03T12:00:00Z")
        let record = try await h.catalog.create(cleanupRule, now: created)
        #expect(record.definitionJSON.contains("list-personal"))  // name resolved to an id at save time
        let night = Harness.at("2026-10-04T09:05:00Z")
        await h.completed("old1", daysAgo: 40, now: night)
        await h.completed("old2", daysAgo: 31, now: night)
        await h.completed("recent", daysAgo: 3, now: night)
        await h.completed("otherlist", list: "list-work", daysAgo: 90, now: night)

        let reports = try await h.runner().runDue(now: night)
        #expect(reports.map(\.outcome) == ["staged"])
        let actionID = try #require(reports.first?.stagedActionID)
        #expect(await h.repo.itemExists(identifier: "old1", entityType: .reminder))  // nothing deleted
        let staged = try #require(try h.store.stagedAction(id: actionID))
        let items = StagedActionExecutor(repository: h.repo, store: h.store).items(of: staged)
        #expect(Set(items.map(\.identifier)) == ["old1", "old2"])
        #expect(items.allSatisfy { !$0.version.isEmpty })
        #expect(h.notifier.sent.last?.1.contains("rcc automations approve \(actionID)") == true)

        let nextNight = night.addingTimeInterval(86_400)
        let second = try await h.runner().runDue(now: nextNight)
        #expect(try h.store.stagedAction(id: actionID)?.state == "stale")
        #expect(second.first?.outcome == "staged" && second.first?.stagedActionID != actionID)
    }

    @Test("A flag rule finds meetings with no place, ignoring located, linked, all-day, and solo events")
    func flagMeetings() async throws {
        let h = try await Harness.make()
        let now = Harness.at("2026-10-05T14:30:00Z")
        func event(_ id: String, location: String? = nil, notes: String? = nil, url: String? = nil,
                   allDay: Bool = false, attendees: Bool = true, hours: Double = 24) async {
            let start = now.addingTimeInterval(hours * 3600)
            await h.repo.insert(event: EventSummary(
                id: id, title: id, start: start, end: start.addingTimeInterval(1800), calendarIdentifier: "cal-work",
                isAllDay: allDay, location: location, notes: notes, url: url,
                participants: attendees ? [person("me", me: true), person("pat")] : []
            ))
        }
        await event("no-place")
        await event("has-location", location: "Room 4")
        await event("zoom", notes: "join https://zoom.us/j/123")
        await event("has-url", url: "https://meet.google.com/abc")
        await event("all-day", allDay: true)
        await event("solo", attendees: false)
        await event("next-month", hours: 24 * 30)

        let record = try await h.catalog.create(flagRule, now: now.addingTimeInterval(-3600))
        let report = try #require(try await h.runner().runDue(now: now).first)
        #expect(report.outcome == "flagged" && report.matched == 1)
        #expect(report.detail?.contains("no-place") == true)
        #expect(h.notifier.sent.count == 1)
        #expect(try h.store.rule(id: record.id)?.nextDueAt == "2026-10-06T14:30:00.000Z")  // next weekday
    }

    @Test("More matches than max_fan_out stops the run: nothing staged, and it says so")
    func fanOut() async throws {
        let h = try await Harness.make()
        var doc = cleanupRule; doc["max_fan_out"] = 2
        _ = try await h.catalog.create(doc, now: Harness.at("2026-10-03T12:00:00Z"))
        let night = Harness.at("2026-10-04T09:05:00Z")
        for n in 0..<3 { await h.completed("old\(n)", daysAgo: 40, now: night) }
        let report = try #require(try await h.runner().runDue(now: night).first)
        #expect(report.outcome == "fan_out_exceeded" && report.matched == 3)
        #expect(try h.store.stagedActions(states: ["pending"]).isEmpty)
        #expect(h.notifier.sent.last?.0.contains("stopped") == true)
    }

    @Test("misfire_policy skip drops a slot missed by more than max_lateness; run_once runs it once")
    func misfire() async throws {
        let h = try await Harness.make()
        var skip = flagRule; skip["misfire_policy"] = "skip"; skip["max_lateness_minutes"] = 60
        let skipRule = try await h.catalog.create(skip, now: Harness.at("2026-10-01T00:00:00Z"))
        let runOnce = try await h.catalog.create(flagRule, now: Harness.at("2026-10-01T00:00:00Z"))
        // Asleep from Thursday morning to Monday evening: several slots missed.
        let wake = Harness.at("2026-10-06T02:00:00Z")
        let reports = try await h.runner().runDue(now: wake)
        #expect(reports.first { $0.ruleID == skipRule.id }?.outcome == "skipped_misfire")
        #expect(reports.first { $0.ruleID == runOnce.id }?.outcome == "nothing")  // ran, matched nothing
        #expect(try h.store.runs(ruleID: runOnce.id).count == 1)                  // coalesced: one run
        for rule in [skipRule, runOnce] {
            #expect(try h.store.rule(id: rule.id)?.nextDueAt.flatMap(RCCTime.parse).map { $0 > wake } == true)
        }
    }

    @Test("A rule whose list has vanished fails loudly, is recorded, and is counted")
    func vanishedScope() async throws {
        let h = try await Harness.make()
        let record = try await h.catalog.create(cleanupRule, now: Harness.at("2026-10-03T12:00:00Z"))
        try await h.repo.deleteCalendar(identifier: "list-personal", entityType: .reminder)
        let report = try #require(try await h.runner().runDue(now: Harness.at("2026-10-04T09:05:00Z")).first)
        #expect(report.outcome == "failed" && report.detail?.contains("no longer exists") == true)
        #expect(try h.store.rule(id: record.id)?.consecutiveFailures == 1)
        #expect(try h.store.runs(ruleID: record.id).first?.outcome == "failed")
    }

    @Test("A dry run touches nothing: no run row, no stage, no schedule change")
    func dryRun() async throws {
        let h = try await Harness.make()
        let record = try await h.catalog.create(cleanupRule, now: Harness.at("2026-10-03T12:00:00Z"))
        await h.completed("old", daysAgo: 40, now: Harness.at("2026-10-04T09:05:00Z"))
        let report = try #require(try await h.runner().runDue(now: Harness.at("2026-10-04T09:05:00Z"),
                                                              ruleID: record.id, dryRun: true).first)
        #expect(report.outcome == "dry_run" && report.matched == 1)
        #expect(try h.store.runs(ruleID: record.id).isEmpty)
        #expect(try h.store.stagedActions().isEmpty)
        #expect(try h.store.rule(id: record.id)?.nextDueAt == record.nextDueAt)
    }

    @Test("A disabled rule does not run")
    func disabled() async throws {
        let h = try await Harness.make()
        let record = try await h.catalog.create(cleanupRule, now: Harness.at("2026-10-03T12:00:00Z"))
        try await h.catalog.update(id: record.id, document: nil, enabled: false)
        #expect(try await h.runner().runDue(now: Harness.at("2026-10-10T09:05:00Z")).isEmpty)
    }

    @Test("Leases: one holder at a time; an expired lease is taken over")
    func leases() async throws {
        let h = try await Harness.make()
        let record = try await h.catalog.create(cleanupRule)
        let now = Date()
        #expect(try h.store.acquireLease(ruleID: record.id, owner: "a", now: now, ttl: 600))
        #expect(try !h.store.acquireLease(ruleID: record.id, owner: "b", now: now.addingTimeInterval(60), ttl: 600))
        #expect(try h.store.acquireLease(ruleID: record.id, owner: "b", now: now.addingTimeInterval(601), ttl: 600))
        // The loser of a takeover cannot clobber the new holder's schedule.
        #expect(try !h.store.releaseLease(ruleID: record.id, owner: "a", nextDueAt: nil, consecutiveFailures: 0,
                                          lastRunAt: RCCTime.instant(), lastOutcome: "x"))
    }

    @Test("Overlapping invocations never double-fire a rule")
    func concurrentRuns() async throws {
        let h = try await Harness.make()
        let record = try await h.catalog.create(cleanupRule, now: Harness.at("2026-10-03T12:00:00Z"))
        let night = Harness.at("2026-10-04T09:05:00Z")
        async let a = h.runner(owner: "a").runDue(now: night)
        async let b = h.runner(owner: "b").runDue(now: night)
        async let c = h.runner(owner: "c").runDue(now: night)
        let total = try await a.count + b.count + c.count
        #expect(total == 1)
        #expect(try h.store.runs(ruleID: record.id).count == 1)
    }

    /// SPEC §18 M6's week, compressed: launchd's 30-minute cadence for seven days, with
    /// every tick invoked twice concurrently (as an overlapping manual run would), and
    /// the Mac asleep for a stretch of it.
    @Test("A simulated week: exact firing counts, no double-fire, no silent failure")
    func simulatedWeek() async throws {
        let h = try await Harness.make()
        let start = Harness.at("2026-10-04T07:00:00Z")  // Sunday 00:00 PDT
        let cleanup = try await h.catalog.create(cleanupRule, now: start)
        let flag = try await h.catalog.create(flagRule, now: start)
        await h.completed("old", daysAgo: 40, now: start)

        let asleep = Harness.at("2026-10-07T05:00:00Z")..<Harness.at("2026-10-07T20:00:00Z")  // Tue 22:00 → Wed 13:00
        var tick = start
        while tick < start.addingTimeInterval(7 * 86_400) {
            if !asleep.contains(tick) {
                let now = tick
                async let one = h.runner(owner: "x").runDue(now: now)
                async let two = h.runner(owner: "y").runDue(now: now)
                _ = try await (one, two)
            }
            tick = tick.addingTimeInterval(1800)
        }
        let cleanupRuns = try h.store.runs(ruleID: cleanup.id, limit: 100)
        let flagRuns = try h.store.runs(ruleID: flag.id, limit: 100)
        #expect(cleanupRuns.count == 7, "\(cleanupRuns.map { ($0.scheduledFor ?? "-") + "@" + $0.startedAt + ":" + $0.outcome })")
        #expect(flagRuns.count == 5, "\(flagRuns.map { ($0.scheduledFor ?? "-") + "@" + $0.startedAt })")
        #expect(Set(cleanupRuns.compactMap(\.scheduledFor)).count == 7)
        #expect((cleanupRuns + flagRuns).allSatisfy { $0.outcome != "running" && $0.outcome != "failed" })
        #expect(await h.repo.itemExists(identifier: "old", entityType: .reminder))  // never deleted unattended
        #expect(try h.store.stagedActions(states: ["pending"]).count == 1)       // latest stage only
    }
}

// MARK: - Approval

@Suite("Staged action approval", .serialized)
struct ApprovalTests {
    func staged(_ h: Harness, ids: [String]) async throws -> String {
        _ = try await h.catalog.create(cleanupRule, now: Harness.at("2026-10-03T12:00:00Z"))
        let night = Harness.at("2026-10-04T09:05:00Z")
        for id in ids { await h.completed(id, daysAgo: 40, now: night) }
        return try #require(try await h.runner().runDue(now: night).first?.stagedActionID)
    }

    var soon: Date { Harness.at("2026-10-04T15:00:00Z") }

    @Test("Approval deletes exactly the staged items, audited under the approval id")
    func approve() async throws {
        let h = try await Harness.make()
        let id = try await staged(h, ids: ["a", "b"])
        let result = try await StagedActionExecutor(repository: h.repo, store: h.store).approve(id, now: soon)
        #expect(result.state == "executed" && result.items.map(\.outcome) == ["deleted", "deleted"])
        #expect(await !h.repo.itemExists(identifier: "a", entityType: .reminder))
        let audited = try h.store.auditEntries().filter { $0.approvalID == id }
        #expect(audited.count == 2 && audited.allSatisfy { $0.context == "tier0" && $0.outcome == "succeeded" })
    }

    @Test("An item changed since staging is not deleted; one already gone is reported, not failed")
    func staleItems() async throws {
        let h = try await Harness.make()
        let id = try await staged(h, ids: ["changed", "gone", "fine"])
        var patch = ReminderPatch(); patch.title = .set("edited after staging")
        _ = try await h.repo.updateReminder(identifier: "changed", patch: patch)
        try await h.repo.deleteReminder(identifier: "gone")

        let result = try await StagedActionExecutor(repository: h.repo, store: h.store).approve(id, now: soon)
        let outcomes = Dictionary(uniqueKeysWithValues: result.items.map { ($0.identifier, $0.outcome) })
        #expect(outcomes == ["changed": "changed_since_staged", "gone": "already_deleted", "fine": "deleted"])
        #expect(result.state == "partially_executed")
        #expect(await h.repo.itemExists(identifier: "changed", entityType: .reminder))
    }

    @Test("Approval is one-use; a rejected or expired action cannot be approved")
    func oneUse() async throws {
        let h = try await Harness.make()
        let executor = StagedActionExecutor(repository: h.repo, store: h.store)
        let id = try await staged(h, ids: ["a"])
        _ = try await executor.approve(id, now: soon)
        await #expect(throws: StagedActionExecutor.ApprovalError.self) { _ = try await executor.approve(id, now: soon) }

        let h2 = try await Harness.make()
        let executor2 = StagedActionExecutor(repository: h2.repo, store: h2.store)
        let rejected = try await staged(h2, ids: ["b"])
        try executor2.reject(rejected, now: soon)
        await #expect(throws: StagedActionExecutor.ApprovalError.self) { _ = try await executor2.approve(rejected, now: soon) }
        #expect(await h2.repo.itemExists(identifier: "b", entityType: .reminder))

        let h3 = try await Harness.make()
        let executor3 = StagedActionExecutor(repository: h3.repo, store: h3.store)
        let expiring = try await staged(h3, ids: ["c"])
        await #expect(throws: StagedActionExecutor.ApprovalError.expired(expiring)) {
            _ = try await executor3.approve(expiring, now: soon.addingTimeInterval(2 * 86_400))
        }
        #expect(await h3.repo.itemExists(identifier: "c", entityType: .reminder))
    }

    /// A crash part-way through an approval: item 0 was deleted, then the process died
    /// with the action still `executing`. Re-running approve finishes the rest without
    /// re-deleting item 0 (its idempotency key replays the recorded outcome).
    @Test("An interrupted approval resumes without repeating finished items")
    func resumeAfterCrash() async throws {
        let h = try await Harness.make()
        let id = try await staged(h, ids: ["first", "second"])
        let action = try #require(try h.store.stagedAction(id: id))
        let items = StagedActionExecutor(repository: h.repo, store: h.store).items(of: action)
        _ = try h.store.transitionStagedAction(id: id, from: ["pending"], to: "executing", now: soon)
        _ = try await MutationExecutor(repository: h.repo, store: h.store).execute(.init(
            action: .deleteReminder, context: .tier0, targetIdentifier: items[0].identifier,
            ifMatch: items[0].version, idempotencyKey: "staged:\(id):0", approvalID: id
        ))
        // ...crash. Resume:
        let result = try await StagedActionExecutor(repository: h.repo, store: h.store).approve(id, now: soon)
        #expect(result.state == "executed")
        #expect(result.items.map(\.outcome) == ["deleted", "deleted"])
        #expect(try h.store.auditEntries().filter { $0.approvalID == id && $0.outcome == "succeeded" }.count == 2)
    }

    @Test("Replaying the idempotency key of a failed write re-surfaces the failure")
    func replayOfFailure() async throws {
        let h = try await Harness.make()
        let executor = MutationExecutor(repository: h.repo, store: h.store)
        let request = MutationExecutor.Request(action: .deleteReminder, targetIdentifier: "missing", idempotencyKey: "k")
        await #expect(throws: MutationExecutor.ExecutorError.self) { _ = try await executor.execute(request) }
        do {
            _ = try await executor.execute(request)
            Issue.record("a replay of a failed write must not report success")
        } catch let error as MutationExecutor.ExecutorError {
            #expect(error.code == "not_found")
        }
    }
}
