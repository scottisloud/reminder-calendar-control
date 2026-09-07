import ArgumentParser
import Foundation
import RCCBootstrap
import RCCCalendar
import RCCCore
import RCCDiagnostics

/// Milestone 1's acceptance probe, as a command (SPEC §18).
///
/// Exit codes are the contract the acceptance harness relies on, so each failure mode gets
/// its own: a harness that only checked "non-zero" could not tell a missing dev fixture
/// from a broken disclaim.
struct SelfTestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "selftest",
        abstract: "Prove rcc can read and write its dev calendar and list from this launch context.",
        discussion: """
            Creates one throwaway event and one throwaway reminder in rcc's own dev \
            fixtures, reads them back, then deletes them. Never touches any other \
            calendar. Requires `rcc setup --dev` first.
            """
    )

    @Flag(name: .long, help: "Emit the result as JSON.")
    var json = false

    @Option(
        name: .long,
        help: "Label recorded in the output, e.g. terminal / spawned / launchagent. Auto-detected if omitted."
    )
    var context: String?

    @Option(name: .long, help: "Also write the JSON result to this path. Useful under launchd.")
    var out: String?

    @Flag(name: .long, help: "Only check the disclaim mechanism; do not touch EventKit.")
    var disclaimOnly = false

    func run() async throws {
        if disclaimOnly {
            try reportDisclaimOnly()
            return
        }

        let probe = SelfTest(repository: EventKitRepository())
        let outcome: SelfTest.Outcome
        do {
            outcome = try await probe.run(context: context ?? SelfTest.detectContext())
        } catch {
            // Emit machine-readable failure to `--out` too: under launchd there is no
            // other channel, and a harness that gets nothing cannot distinguish a crash
            // from a permission problem.
            let payload: [String: Any] = [
                "schema_version": 1,
                "as_of": RCCTime.instant(),
                "context": context ?? SelfTest.detectContext(),
                "passed": false,
                "error": Redaction.sanitize(String(describing: error), limit: 600),
            ]
            writeOut(payload)
            exitWith(mapped(error))
        }

        let payload = outcome.jsonObject()
        writeOut(payload)
        if json {
            try Output.json(payload)
        } else {
            Output.line(render(outcome))
        }

        guard outcome.passed else {
            if !outcome.disclaim.passed {
                throw ExitCode(RCCExitCode.disclaimUnavailable.rawValue)
            }
            throw ExitCode(RCCExitCode.unhealthy.rawValue)
        }
    }

    private func reportDisclaimOnly() throws {
        let result = Disclaim.result
        let summary = SelfTest.DisclaimSummary(
            outcome: result?.outcome.rawValue ?? "not_run",
            generation: result?.generation ?? -1,
            pid: result?.pid ?? getpid(),
            responsiblePID: result?.responsiblePID ?? -1,
            mechanismAvailable: result?.mechanismAvailable ?? false
        )
        var payload = summary.jsonObject()
        payload["context"] = context ?? SelfTest.detectContext()
        payload["schema_version"] = 1
        writeOut(payload)
        if json {
            try Output.json(payload)
        } else {
            Output.line("disclaim: \(summary.outcome) gen=\(summary.generation) "
                + "pid=\(summary.pid) responsible=\(summary.responsiblePID)")
        }
        guard summary.passed else {
            throw ExitCode(RCCExitCode.disclaimUnavailable.rawValue)
        }
    }

    private func writeOut(_ payload: [String: Any]) {
        guard let out else { return }
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return }
        try? data.write(to: URL(fileURLWithPath: out), options: .atomic)
    }

    private func mapped(_ error: any Error) -> any Error {
        if error is RCCError { return error }
        if let repositoryError = error as? CalendarRepositoryError {
            switch repositoryError {
            case .notAuthorized:
                return RCCError(
                    .permission,
                    String(describing: repositoryError),
                    remediation: "Run `rcc setup` from Terminal so macOS can show the permission prompt."
                )
            default:
                return RCCError(.internalError, String(describing: repositoryError))
            }
        }
        return error
    }

    private func render(_ outcome: SelfTest.Outcome) -> String {
        var lines: [String] = []
        lines.append("rcc selftest — context: \(outcome.context)")
        lines.append("  disclaim: \(outcome.disclaim.outcome) gen=\(outcome.disclaim.generation) "
            + "pid=\(outcome.disclaim.pid) responsible=\(outcome.disclaim.responsiblePID) "
            + "→ \(outcome.disclaim.passed ? "exactly one re-exec" : "FAILED")")
        for (entity, status) in outcome.authorization.sorted(by: { $0.key < $1.key }) {
            lines.append("  authorization[\(entity)]: \(status)")
        }
        for trip in outcome.roundTrips {
            lines.append("  \(trip.entityType.rawValue): wrote \(trip.createdIdentifier) to "
                + "\"\(trip.calendarTitle)\" — read back \(trip.readBack), deleted \(trip.deleted)")
        }
        lines.append(outcome.passed ? "PASS" : "FAIL")
        return lines.joined(separator: "\n")
    }
}
