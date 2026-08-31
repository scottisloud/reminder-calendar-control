import Foundation
import Testing

@testable import RCCCore

@Suite("Exit codes")
struct ExitCodeTests {
    @Test("Every category has a distinct, stable code")
    func distinctCodes() {
        let codes = RCCExitCode.allCases.map(\.rawValue)
        #expect(Set(codes).count == codes.count)
        // These are a public contract: scripts and the acceptance harness branch on them.
        #expect(RCCExitCode.ok.rawValue == 0)
        #expect(RCCExitCode.permission.rawValue == 3)
        #expect(RCCExitCode.disclaimUnavailable.rawValue == 8)
        #expect(RCCExitCode.unhealthy.rawValue == 9)
    }

    @Test("Remediation is surfaced separately from the message")
    func errorDescription() {
        let error = RCCError(.install, "It broke.", remediation: "Turn it off and on again.")
        #expect(error.description.contains("It broke."))
        #expect(error.description.contains("Turn it off and on again."))
        #expect(RCCError(.usage, "Just this.").description == "Just this.")
    }
}

@Suite("Timestamps")
struct TimeTests {
    @Test("Instants are RFC 3339 UTC with milliseconds")
    func instantFormat() {
        let formatted = RCCTime.instant(Date(timeIntervalSince1970: 0))
        #expect(formatted == "1970-01-01T00:00:00.000Z")
    }

    @Test("Local day is the operator's calendar date, not UTC's")
    func localDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try! #require(TimeZone(identifier: "Pacific/Auckland"))
        // 23:00 UTC on 30 Aug is already 31 Aug in Auckland — the log file should be
        // named for the day the operator is living in.
        let instant = Date(timeIntervalSince1970: 1_788_130_800)
        #expect(RCCTime.localDay(instant, calendar: calendar).count == 10)
        #expect(RCCTime.localDay(instant, calendar: calendar).hasPrefix("20"))
    }
}

@Suite("Bundle identity")
struct BundleIdentityTests {
    @Test("Missing usage descriptions are reported, not tolerated")
    func reportsMissingRequirements() {
        let identity = BundleIdentity(
            bundleIdentifier: nil, name: nil, shortVersion: nil, buildVersion: nil,
            calendarsUsageDescription: nil, remindersUsageDescription: nil
        )
        #expect(!identity.isComplete)
        #expect(identity.missingRequirements.contains("CFBundleIdentifier"))
        #expect(identity.missingRequirements.contains("NSCalendarsFullAccessUsageDescription"))
        #expect(identity.missingRequirements.contains("NSRemindersFullAccessUsageDescription"))
    }

    @Test("A complete identity has nothing missing")
    func completeIdentity() {
        let identity = BundleIdentity(
            bundleIdentifier: "com.example.rcc", name: "rcc", shortVersion: "0.1.0",
            buildVersion: "1", calendarsUsageDescription: "cal", remindersUsageDescription: "rem"
        )
        #expect(identity.isComplete)
        #expect(identity.missingRequirements.isEmpty)
        #expect(identity.facts["bundle_identifier"] == "com.example.rcc")
    }

    @Test("Legacy pre-macOS-14 keys are surfaced")
    func flagsLegacyKeys() {
        let identity = BundleIdentity(
            bundleIdentifier: "com.example.rcc", name: "rcc", shortVersion: "0.1.0",
            buildVersion: "1", calendarsUsageDescription: "cal", remindersUsageDescription: "rem",
            legacyKeysPresent: ["NSCalendarsUsageDescription"]
        )
        #expect(identity.isComplete)
        #expect(identity.facts["legacy_keys_present"] == "NSCalendarsUsageDescription")
    }
}

@Suite("Health report")
struct HealthReportTests {
    private func check(_ id: String, _ status: HealthReport.Status) -> HealthReport.Check {
        HealthReport.Check(id: id, title: id, status: status, detail: "")
    }

    @Test("Overall status is the worst individual status")
    func overallIsWorst() {
        #expect(HealthReport(checks: [check("a", .ok), check("b", .warn)]).overall == .warn)
        #expect(HealthReport(checks: [check("a", .warn), check("b", .fail)]).overall == .fail)
        #expect(HealthReport(checks: [check("a", .ok), check("b", .skipped)]).overall == .skipped)
        #expect(HealthReport(checks: [check("a", .ok), check("b", .unknown)]).overall == .unknown)
    }

    @Test("Only an outright failure makes the report unhealthy")
    func warningsDoNotFail() {
        // An ad-hoc signature warns on every single run; if that made `doctor` exit
        // non-zero the command would be useless in a script.
        #expect(HealthReport(checks: [check("a", .warn)]).isHealthy)
        #expect(!HealthReport(checks: [check("a", .fail)]).isHealthy)
        #expect(HealthReport(checks: [check("a", .unknown)]).isHealthy)
    }

    @Test("JSON carries every check with its status")
    func jsonShape() throws {
        let report = HealthReport(checks: [
            HealthReport.Check(
                id: "disclaim", title: "TCC self-disclaim", status: .fail,
                detail: "broken", remediation: "fix it", facts: ["gen": "0"]
            )
        ])
        let object = report.jsonObject()
        #expect(object["overall"] as? String == "fail")
        let checks = try #require(object["checks"] as? [[String: Any]])
        #expect(checks.count == 1)
        #expect(checks[0]["id"] as? String == "disclaim")
        #expect(checks[0]["remediation"] as? String == "fix it")
        #expect((checks[0]["facts"] as? [String: String])?["gen"] == "0")
        // Must be JSON-encodable — `rcc doctor --json` and the MCP tool both serialise it.
        #expect(JSONSerialization.isValidJSONObject(object))
    }

    @Test("Text rendering includes remediation for failures")
    func textRendering() {
        let report = HealthReport(checks: [
            HealthReport.Check(id: "x", title: "Thing", status: .fail, detail: "no", remediation: "do this")
        ])
        let text = report.renderText()
        #expect(text.contains("[FAIL]"))
        #expect(text.contains("do this"))
    }
}

@Suite("Path sandboxing")
struct PathSandboxTests {
    /// Guards against a regression that actually happened: a test run created a real
    /// `state.sqlite3` under the operator's Application Support directory, which then made
    /// `rcc doctor` report an install that had never been set up.
    @Test("Under swift test, every writable path is redirected away from the real home")
    func writablePathsAreRedirected() {
        #expect(RCCPaths.isTestSandboxed, "Bundle.main is not the xctest tool — detection broke")

        let home = RCCPaths.home.path
        for url in [
            RCCPaths.supportRoot,
            RCCPaths.databaseFile,
            RCCPaths.logDirectory,
            RCCPaths.launchAgentsDirectory,
            RCCPaths.claudeDesktopConfig,
            RCCPaths.installedBinary,
            RCCPaths.automationAgentPlist,
        ] {
            #expect(
                !url.path.hasPrefix(home + "/Library"),
                "\(url.path) still points into the real home"
            )
        }
    }
}
