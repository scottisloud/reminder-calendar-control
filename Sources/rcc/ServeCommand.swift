import ArgumentParser
import Foundation
import RCCBootstrap
import RCCCalendar
import RCCCore
import RCCDiagnostics
import RCCMCP

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Run the MCP server over stdio. This is what Claude Desktop spawns.",
        discussion: """
            Reads newline-delimited JSON-RPC on stdin and writes it on stdout. Everything \
            else — logs, warnings, diagnostics — goes to stderr; stdout is reserved for \
            protocol frames and is structurally quarantined at startup.

            Exits 0 when stdin closes. rcc keeps no in-memory state that is unsafe to \
            lose, so Claude Desktop may spawn, kill, and respawn it freely.
            """
    )

    func run() async throws {
        // Deliberately still serves when the disclaim failed, rather than refusing to start.
        // A server that exits immediately gives Claude Desktop nothing to show the user;
        // one that starts and reports the failure through `get_system_status` — while every
        // EventKit-touching tool refuses via DisclaimGate — is strictly more diagnosable.
        if !DisclaimGate.isSatisfied(Disclaim.result) {
            Log.shared.error("serve.disclaim_unhealthy", [
                "outcome": .safe(Disclaim.result?.outcome.rawValue ?? "not_run"),
            ])
        }
        await MCPServer(repository: EventKitRepository()).run()
    }
}
