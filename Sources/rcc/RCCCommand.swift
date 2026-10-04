import ArgumentParser
import Foundation
import RCCCore

/// Root command (SPEC §7.1).
///
/// Every subcommand is `AsyncParsableCommand`, including ones that need nothing async:
/// ArgumentParser aborts the whole binary — `--help` included — if an async subcommand
/// hangs off a synchronous root, so mixing the two is not an option.
struct RCCCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rcc",
        abstract: "Calendar and Reminders control for Claude Desktop, via EventKit.",
        discussion: """
            rcc is a single binary with several modes. `rcc setup` is the one you run by \
            hand; `rcc serve` is what Claude Desktop spawns; `rcc automations run` is what \
            launchd invokes on a schedule. `rcc automations approve` is the only way a \
            staged automation change is ever executed, and it needs you at a terminal.
            """,
        version: BuildInfo.versionString,
        subcommands: [
            Setup.self,
            Install.self,
            Doctor.self,
            Status.self,
            Serve.self,
            SelfTestCommand.self,
            Automations.self,
        ],
        defaultSubcommand: Doctor.self
    )
}

/// Bridges a thrown `RCCError` to a process exit code, having printed it usefully first.
///
/// ArgumentParser's own `ExitCode` carries no message, and its `ValidationError` always
/// exits 64. Routing through here keeps SPEC §16's stable, category-distinct exit codes
/// intact.
func exitWith(_ error: any Error) -> Never {
    if let rccError = error as? RCCError {
        Output.error("error: \(rccError.message)")
        if let remediation = rccError.remediation {
            Output.error("")
            Output.error(remediation)
        }
        Log.shared.error("command.failed", [
            "code": .safe(rccError.exitCode.label),
            "message": .safe(rccError.message),
        ])
        exit(rccError.exitCode.rawValue)
    }
    Output.error("error: \(error)")
    Log.shared.error("command.failed", [
        "code": .safe(RCCExitCode.internalError.label),
        "message": .safe(String(describing: error)),
    ])
    exit(RCCExitCode.internalError.rawValue)
}
