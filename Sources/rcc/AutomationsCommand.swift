import ArgumentParser
import Foundation
import RCCCore

/// Automation subcommands (SPEC §7.1, §11).
///
/// Milestone 1 needs only `run`, and only as a well-behaved no-op: the LaunchAgent
/// installed by `rcc setup` points at it, so it has to exit cleanly on a schedule long
/// before there are any rules to execute. The rule DSL, scheduling, and staged-approval
/// flow are Milestone 6.
///
/// `approve` and `reject` are deliberately absent from the MCP tool surface and will only
/// ever exist here (SPEC §6.4, §8.3): a model-callable approval tool does not prove a
/// human approved anything.
struct Automations: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "automations",
        abstract: "Manage unattended automation rules.",
        subcommands: [Run.self]
    )

    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "run",
            abstract: "Execute due automation rules. Invoked by launchd on a schedule."
        )

        @Flag(name: .long, help: "Show what would happen without staging or executing anything.")
        var dryRun = false

        @Option(name: .long, help: "Limit the run to one rule.")
        var rule: String?

        func run() async throws {
            // Logged rather than printed: under launchd, stdout goes to a file nobody
            // reads, and a scheduled no-op should not grow that file every 30 minutes.
            Log.shared.info("automations.run", [
                "dry_run": .bool(dryRun),
                "rule": .safe(rule ?? "all"),
                "outcome": .safe("no_rules_configured"),
            ])
            if isatty(STDOUT_FILENO) == 1 {
                Output.line("No automation rules are configured (Milestone 6).")
            }
        }
    }
}
