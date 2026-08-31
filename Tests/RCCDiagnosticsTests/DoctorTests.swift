import Foundation
import Testing

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
        let report = await Doctor(repository: InMemoryCalendarRepository()).run()
        for id in ["disclaim", "bundle_identity", "running_binary", "installed_binary",
                   "gatekeeper", "mcp_registration", "launch_agent", "state",
                   "dev_fixture", "keychain", "notifications"] {
            _ = try check(report, id)
        }
    }

    /// Under `swift test` the disclaim never runs — top-level `main.swift` code is not
    /// executed — so this must report "unknown", never a false "ok".
    @Test("A disclaim that never ran is unknown, not ok")
    func disclaimNotRunIsUnknown() async throws {
        let report = await Doctor(repository: InMemoryCalendarRepository()).run()
        let disclaim = try check(report, "disclaim")
        #expect(disclaim.status == .unknown)
        #expect(disclaim.detail.contains("not run"))
    }
}

@Suite("Self-test")
struct SelfTestTests {
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
        let outcome = try await SelfTest(repository: repository, store: try makeStore())
            .run(context: "unit-test")
        #expect(outcome.roundTrips.count == 2)
        #expect(outcome.roundTrips.allSatisfy { $0.readBack && $0.deleted })
        #expect(outcome.context == "unit-test")
    }

    /// The gate is "exactly one re-exec", so a run where the disclaim never happened must
    /// not report a pass no matter how well the EventKit round trips went.
    @Test("A failed disclaim fails the whole self-test")
    func disclaimFailureFailsEverything() async throws {
        let repository = InMemoryCalendarRepository(
            scenario: .init(eventStatus: .fullAccess, reminderStatus: .fullAccess)
        )
        let outcome = try await SelfTest(repository: repository, store: try makeStore())
            .run(context: "unit-test")
        // `Disclaim.ensure()` is never called under `swift test`.
        #expect(!outcome.disclaim.passed)
        #expect(!outcome.passed)
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
            _ = try await SelfTest(repository: repository, store: try makeStore()).run(context: "unit-test")
        }
    }

    @Test("The JSON payload is serialisable and carries the invariants")
    func jsonPayload() async throws {
        let repository = InMemoryCalendarRepository(
            scenario: .init(eventStatus: .fullAccess, reminderStatus: .fullAccess)
        )
        let outcome = try await SelfTest(repository: repository, store: try makeStore())
            .run(context: "unit-test")
        let object = outcome.jsonObject()
        #expect(JSONSerialization.isValidJSONObject(object))
        #expect(object["context"] as? String == "unit-test")
        #expect((object["disclaim"] as? [String: Any])?["exactly_one_reexec"] != nil)
        #expect((object["round_trips"] as? [[String: Any]])?.count == 2)
    }
}
