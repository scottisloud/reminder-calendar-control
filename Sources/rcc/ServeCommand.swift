import ArgumentParser
import Foundation
import RCCCalendar
import RCCCore
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
        await MCPServer(repository: EventKitRepository()).run()
    }
}
