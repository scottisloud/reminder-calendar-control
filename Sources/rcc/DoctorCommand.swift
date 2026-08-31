import ArgumentParser
import Foundation
import RCCCalendar
import RCCCore
import RCCDiagnostics

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check that every part of the install is present, coherent, and authorized."
    )

    @Flag(name: .long, help: "Emit the report as JSON instead of text.")
    var json = false

    func run() async throws {
        let report = await RCCDiagnostics.Doctor(repository: EventKitRepository()).run()
        if json {
            do {
                try Output.json(report.jsonObject())
            } catch {
                exitWith(error)
            }
        } else {
            Output.line(report.renderText())
        }
        // Warnings do not fail the command: an ad-hoc signature warns on every run and
        // that must not make `doctor` useless in a script.
        if report.hasFailures {
            throw ExitCode(RCCExitCode.unhealthy.rawValue)
        }
    }
}

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "One-line health snapshot. Use `rcc doctor` for the detail."
    )

    @Flag(name: .long, help: "Emit JSON instead of text.")
    var json = false

    func run() async throws {
        let report = await RCCDiagnostics.Doctor(repository: EventKitRepository()).run()
        let failing = report.checks.filter { $0.status == .fail }.map(\.id)
        let warning = report.checks.filter { $0.status == .warn }.map(\.id)

        if json {
            try Output.json([
                "schema_version": 1,
                "as_of": RCCTime.instant(),
                "rcc_version": BuildInfo.versionString,
                "overall": report.overall.rawValue,
                "failing": failing,
                "warning": warning,
                // Milestone 6 fills these in; reported as null rather than omitted so the
                // shape does not change when they arrive.
                "pending_approvals": NSNull(),
                "last_automation_run": NSNull(),
            ])
            return
        }

        Output.line("rcc \(BuildInfo.versionString) — \(report.overall.rawValue.uppercased())")
        if !failing.isEmpty { Output.line("  failing: \(failing.joined(separator: ", "))") }
        if !warning.isEmpty { Output.line("  warning: \(warning.joined(separator: ", "))") }
        if failing.isEmpty && warning.isEmpty { Output.line("  all checks passed") }
        Output.line("  automations: none configured (Milestone 6)")

        if report.hasFailures {
            throw ExitCode(RCCExitCode.unhealthy.rawValue)
        }
    }
}
