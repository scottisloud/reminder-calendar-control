import Foundation
import Testing

@testable import RCCBootstrap

@testable import RCCCalendar
@testable import RCCCore
@testable import RCCDiagnostics

@Suite("Doctor")
struct DoctorTests {
    private func check(_ report: HealthReport, _ id: String) throws -> HealthReport.Check {
        try #require(report.checks.first { $0.id == id })
    }

    @Test("An ungranted install fails on both authorization checks")
    func reportsMissingAuthorization() async throws {
        let doctor = Doctor(repository: InMemoryCalendarRepository())
        let report = await doctor.run()

        for entity in ["event", "reminder"] {
            let authorization = try check(report, "authorization_\(entity)")
            #expect(authorization.status == .fail)
            #expect(authorization.remediation?.contains("rcc setup") == true)
            #expect(authorization.facts["raw_value"] == "0")
        }
        #expect(report.hasFailures)
    }

    @Test("A granted install passes both authorization checks")
    func reportsGrantedAuthorization() async throws {
        let repository = InMemoryCalendarRepository(
            scenario: .init(eventStatus: .fullAccess, reminderStatus: .fullAccess)
        )
        let report = await Doctor(repository: repository).run()
        #expect(try check(report, "authorization_event").status == .ok)
        #expect(try check(report, "authorization_reminder").status == .ok)
    }

    /// `writeOnly` reads as "granted" to code that branches on the deprecated
    /// `.authorized`. rcc reads as well as writes, so it must be reported as a failure.
    @Test("Write-only access is reported as a failure with its own remediation")
    func writeOnlyIsAFailure() async throws {
        let repository = InMemoryCalendarRepository(scenario: .init(eventStatus: .writeOnly))
        let report = await Doctor(repository: repository).run()
        let authorization = try check(report, "authorization_event")
        #expect(authorization.status == .fail)
        #expect(authorization.remediation?.contains("full access") == true)
    }

    @Test("A denied grant tells the operator to use System Settings, not to re-run setup")
    func deniedRemediation() async throws {
        let repository = InMemoryCalendarRepository(scenario: .init(reminderStatus: .denied))
        let report = await Doctor(repository: repository).run()
        let authorization = try check(report, "authorization_reminder")
        #expect(authorization.remediation?.contains("System Settings") == true)
    }

    @Test("Every check reports a status, and failures always carry remediation")
    func everyFailureIsActionable() async {
        let report = await Doctor(repository: InMemoryCalendarRepository()).run()
        #expect(!report.checks.isEmpty)
        #expect(Set(report.checks.map(\.id)).count == report.checks.count)
        for check in report.checks where check.status == .fail {
            #expect(check.remediation?.isEmpty == false, "\(check.id) has no remediation")
        }
    }

    @Test("The report serialises cleanly for --json and for the MCP tool")
    func jsonSerialisable() async {
        let report = await Doctor(repository: InMemoryCalendarRepository()).run()
        #expect(JSONSerialization.isValidJSONObject(report.jsonObject()))
    }

    /// `rcc doctor` must describe the running image, and both of these come from the real
    /// process rather than the injected fake, so they are asserted for presence only.
    @Test("Platform checks are present regardless of authorization state")
    func includesPlatformChecks() async throws {
        let report = await Doctor(repository: InMemoryCalendarRepository(), disclaim: nil).run()
        for id in ["disclaim", "bundle_identity", "running_binary", "installed_binary",
                   "gatekeeper", "mcp_registration", "launch_agent", "state",
                   "dev_fixture", "keychain", "notifications"] {
            _ = try check(report, id)
        }
    }

    /// Under `swift test` the disclaim never runs — top-level `main.swift` code is not
    /// executed — so this must report "unknown", never a false "ok".
    /// "We did not check" must never be reported as "we checked and it is fine".
    @Test("A disclaim that never ran is unknown, not ok")
    func disclaimNotRunIsUnknown() async throws {
        let report = await Doctor(repository: InMemoryCalendarRepository(), disclaim: nil).run()
        let disclaim = try check(report, "disclaim")
        #expect(disclaim.status == .unknown)
        #expect(disclaim.detail.contains("not run"))
    }

    @Test("An unhealthy disclaim is a hard failure with remediation")
    func disclaimFailureIsReported() async throws {
        let unhealthy = Disclaim.Result(
            outcome: .notDisclaimed, generation: 1, responsiblePID: 999, pid: 1,
            mechanismAvailable: true
        )
        let report = await Doctor(repository: InMemoryCalendarRepository(), disclaim: unhealthy).run()
        let disclaim = try check(report, "disclaim")
        #expect(disclaim.status == .fail)
        #expect(disclaim.remediation?.isEmpty == false)
        #expect(disclaim.facts["responsible_pid"] == "999")
    }
}

@Suite("Self-test")
struct SelfTestTests {
    /// `Disclaim.ensure()` never runs under `swift test` — top-level `main.swift` code is
    /// not executed — so every test states the disclaim state it is exercising.
    private func result(_ outcome: Disclaim.Outcome) -> Disclaim.Result {
        Disclaim.Result(
            outcome: outcome, generation: 1, responsiblePID: 1, pid: 1, mechanismAvailable: true
        )
    }

    private func makeStore() throws -> Store {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rcc-selftest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try Store(url: directory.appendingPathComponent("state.sqlite3", isDirectory: false))
    }

    @Test("Both entity types are round-tripped")
    func roundTripsBothEntityTypes() async throws {
        let repository = InMemoryCalendarRepository(
            scenario: .init(eventStatus: .fullAccess, reminderStatus: .fullAccess)
        )
        let outcome = try await SelfTest(
            repository: repository, store: try makeStore(), disclaim: result(.disclaimed)
        ).run(context: "unit-test")
        #expect(outcome.roundTrips.count == 2)
        #expect(outcome.roundTrips.allSatisfy { $0.readBack && $0.deleted })
        #expect(outcome.context == "unit-test")
    }

    /// SPEC §6.2's degradation path: when the disclaim is unhealthy, rcc is non-functional
    /// for TCC-touching work. That has to hold for every entry point, not just `rcc setup`.
    @Test("An unhealthy disclaim refuses to touch EventKit at all", arguments: [
        Disclaim.Outcome.notDisclaimed, .mechanismUnavailable, .guardViolated, .spawnFailed,
    ])
    func failsClosedOnUnhealthyDisclaim(_ outcome: Disclaim.Outcome) async throws {
        let repository = InMemoryCalendarRepository(
            scenario: .init(eventStatus: .fullAccess, reminderStatus: .fullAccess)
        )
        let store = try makeStore()
        await #expect(throws: RCCError.self) {
            try await SelfTest(repository: repository, store: store, disclaim: result(outcome))
                .run(context: "unit-test")
        }
    }

    @Test("A disclaim that never ran also refuses")
    func failsClosedWhenDisclaimNeverRan() async throws {
        let repository = InMemoryCalendarRepository(
            scenario: .init(eventStatus: .fullAccess, reminderStatus: .fullAccess)
        )
        let store = try makeStore()
        await #expect(throws: RCCError.self) {
            try await SelfTest(repository: repository, store: store, disclaim: nil)
                .run(context: "unit-test")
        }
    }

    /// A model-invokable caller may use an existing fixture but must never create one:
    /// two permanent calendars appearing in Calendar.app is not something a tool annotated
    /// `destructiveHint: false` should do on its own.
    @Test("With provisioning disallowed and no fixture recorded, the run refuses")
    func refusesToProvisionForUntrustedCallers() async throws {
        let repository = InMemoryCalendarRepository(
            scenario: .init(eventStatus: .fullAccess, reminderStatus: .fullAccess)
        )
        let store = try makeStore()
        await #expect(throws: RCCError.self) {
            try await SelfTest(repository: repository, store: store, disclaim: result(.disclaimed))
                .run(context: "unit-test", allowProvisioning: false)
        }
    }

    @Test("Exactly-one-re-exec requires generation 1 and self-responsibility")
    func disclaimSummaryInvariants() {
        #expect(SelfTest.DisclaimSummary(
            outcome: "disclaimed", generation: 1, pid: 10, responsiblePID: 10, mechanismAvailable: true
        ).passed)
        // Generation 0: never re-executed.
        #expect(!SelfTest.DisclaimSummary(
            outcome: "disclaimed", generation: 0, pid: 10, responsiblePID: 10, mechanismAvailable: true
        ).passed)
        // Generation 2: the guard leaked.
        #expect(!SelfTest.DisclaimSummary(
            outcome: "disclaimed", generation: 2, pid: 10, responsiblePID: 10, mechanismAvailable: true
        ).passed)
        // Re-executed, but TCC still attributes us to an ancestor.
        #expect(!SelfTest.DisclaimSummary(
            outcome: "notDisclaimed", generation: 1, pid: 10, responsiblePID: 99, mechanismAvailable: true
        ).passed)
    }

    @Test("An unauthorized run fails rather than reporting a hollow pass")
    func unauthorizedFails() async throws {
        let repository = InMemoryCalendarRepository(scenario: .init(promptOutcome: nil))
        await #expect(throws: (any Error).self) {
            try await SelfTest(
                repository: repository, store: try makeStore(), disclaim: result(.disclaimed)
            ).run(context: "unit-test")
        }
    }

    @Test("The JSON payload is serialisable and carries the invariants")
    func jsonPayload() async throws {
        let repository = InMemoryCalendarRepository(
            scenario: .init(eventStatus: .fullAccess, reminderStatus: .fullAccess)
        )
        let outcome = try await SelfTest(
            repository: repository, store: try makeStore(), disclaim: result(.disclaimed)
        ).run(context: "unit-test")
        let object = outcome.jsonObject()
        #expect(JSONSerialization.isValidJSONObject(object))
        #expect(object["context"] as? String == "unit-test")
        #expect((object["disclaim"] as? [String: Any])?["exactly_one_reexec"] != nil)
        #expect((object["round_trips"] as? [[String: Any]])?.count == 2)
    }
}

@Suite("Install shape reporting")
struct InstallShapeDoctorTests {
    @Test("A missing install is a hard failure naming both candidate paths")
    func reportsMissingInstall() async throws {
        let report = await Doctor(repository: InMemoryCalendarRepository(), disclaim: nil).run()
        let check = try #require(report.checks.first { $0.id == "install_shape" })
        #expect(check.status == .fail)
        #expect(check.facts["bare_path"]?.hasSuffix("/bin/rcc") == true)
        #expect(check.facts["bundle_path"]?.hasSuffix("/RCC.app/Contents/MacOS/rcc") == true)
        #expect(check.remediation?.contains("--bundle") == true)
    }

    /// The record is not the calendar: a fixture deleted in Reminders.app used to read
    /// "both provisioned" forever (found at Milestone 5).
    @Test("A recorded dev fixture that no longer exists in EventKit is a warning")
    func missingFixtureCalendar() async throws {
        let store = try Store()
        defer {
            try? store.removeDevFixture(.event)
            try? store.removeDevFixture(.reminder)
        }
        let repository = InMemoryCalendarRepository(
            scenario: .init(eventStatus: .fullAccess, reminderStatus: .fullAccess)
        )
        await repository.insert(calendar: CalendarSummary(
            id: "fixture-events", title: "RCC Dev events x", allowsContentModifications: true,
            isSubscribed: false, isImmutable: false, allowedEntityTypes: [.event],
            sourceIdentifier: "src", sourceTitle: "iCloud"
        ))
        for (type, id) in [(Store.DevFixture.EntityType.event, "fixture-events"),
                           (.reminder, "fixture-reminders-gone")] {
            try store.recordDevFixture(Store.DevFixture(
                entityType: type, calendarID: id, title: "RCC Dev \(type.rawValue)s x",
                sourceID: "src", sourceTitle: "iCloud", createdAt: RCCTime.instant()
            ))
        }

        let result = await Doctor(repository: repository).devFixtureCheck()
        #expect(result.status == .warn)
        #expect(result.detail.contains("reminder"))
        #expect(result.facts["event_exists"] == "true")
        #expect(result.facts["reminder_exists"] == "false")
        #expect(result.remediation?.contains("rcc setup --dev") == true)
    }
}
