import Foundation
import Testing

@testable import RCCCalendar
@testable import RCCCore
@testable import RCCMCP

@Suite("MCP wire contract")
struct MCPServerTests {
    private func makeServer() throws -> MCPServer {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rcc-mcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return MCPServer(
            repository: InMemoryCalendarRepository(
                scenario: .init(eventStatus: .fullAccess, reminderStatus: .fullAccess)
            ),
            store: try Store(url: directory.appendingPathComponent("state.sqlite3", isDirectory: false))
        )
    }

    private func send(_ json: String, to server: MCPServer) async throws -> [String: Any]? {
        await server.response(for: Data(json.utf8))
    }

    @Test("A supported protocol version is echoed back verbatim")
    func echoesSupportedVersion() throws {
        let result = MCPServer.initializeResult(for: [
            "params": ["protocolVersion": "2025-06-18"]
        ])
        #expect(result["protocolVersion"] as? String == "2025-06-18")
    }

    /// SPEC §10.1 names revision 2026-07-28, which abolished the `initialize` handshake
    /// entirely. The shipping Claude Desktop still sends `initialize` and negotiates
    /// 2025-11-25, so that is what this server answers. See docs/milestone-1.md.
    @Test("An unknown protocol version falls back to ours, not to theirs")
    func fallsBackToPreferredVersion() {
        let result = MCPServer.initializeResult(for: [
            "params": ["protocolVersion": "2026-07-28"]
        ])
        #expect(result["protocolVersion"] as? String == MCPServer.preferredProtocolVersion)
    }

    @Test("A missing protocol version still yields a usable handshake")
    func handlesMissingVersion() throws {
        let result = MCPServer.initializeResult(for: [:])
        #expect(result["protocolVersion"] as? String == MCPServer.preferredProtocolVersion)
        let serverInfo = try #require(result["serverInfo"] as? [String: Any])
        #expect(serverInfo["name"] as? String == MCPServer.serverName)
        #expect(result["capabilities"] != nil)
    }

    /// Replying to a notification desynchronises strict clients, and
    /// `notifications/initialized` arrives immediately after the initialize response.
    @Test("A notification is never answered")
    func neverAnswersNotifications() async throws {
        let server = try makeServer()
        #expect(try await send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, to: server) == nil)
        #expect(try await send(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{}}"#, to: server) == nil)
    }

    @Test("A parse failure is answered with a null id")
    func parseError() async throws {
        let server = try makeServer()
        let response = try #require(try await send("not json at all", to: server))
        let error = try #require(response["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32700)
        #expect(response["id"] is NSNull)
    }

    @Test("An unknown method is a JSON-RPC error, not a tool result")
    func unknownMethod() async throws {
        let server = try makeServer()
        let response = try #require(try await send(#"{"jsonrpc":"2.0","id":7,"method":"nope"}"#, to: server))
        let error = try #require(response["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32601)
        #expect(response["id"] as? Int == 7)
    }

    @Test("An unknown tool is -32602")
    func unknownTool() async throws {
        let server = try makeServer()
        let response = try #require(try await send(
            #"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"delete_everything"}}"#,
            to: server
        ))
        let error = try #require(response["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32602)
    }

    @Test("ping is answered with an empty result")
    func ping() async throws {
        let server = try makeServer()
        let response = try #require(try await send(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, to: server))
        #expect((response["result"] as? [String: Any])?.isEmpty == true)
    }

    @Test("Every advertised tool has a name, a description, and an object input schema")
    func toolDescriptorShape() throws {
        let tools = Tools.descriptors
        #expect(tools.count == 2)
        for tool in tools {
            #expect((tool["name"] as? String)?.isEmpty == false)
            #expect((tool["description"] as? String)?.isEmpty == false)
            let schema = try #require(tool["inputSchema"] as? [String: Any])
            #expect(schema["type"] as? String == "object")
        }
        #expect(JSONSerialization.isValidJSONObject(["tools": tools]))
    }

    /// `readOnlyHint: true` is not decoration — it is the only annotation Claude Desktop
    /// forwards, and it exempts a tool from the approval policy. Marking a mutating tool
    /// read-only would be a real security bug.
    @Test("Only the genuinely read-only tool claims to be read-only")
    func readOnlyHintIsHonest() throws {
        for tool in Tools.descriptors {
            let name = try #require(tool["name"] as? String)
            let annotations = try #require(tool["annotations"] as? [String: Any])
            let readOnly = annotations["readOnlyHint"] as? Bool
            switch name {
            case Tools.getSystemStatus:
                #expect(readOnly == true)
            case Tools.runPlatformSelfTest:
                #expect(readOnly == false)
            default:
                Issue.record("unexpected tool \(name)")
            }
            // EventKit is a closed local domain; nothing here reaches the network.
            #expect(annotations["openWorldHint"] as? Bool == false)
        }
    }

    @Test("tools/list returns the descriptors")
    func toolsList() async throws {
        let server = try makeServer()
        let response = try #require(try await send(
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#, to: server
        ))
        let tools = try #require((response["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(tools.map { $0["name"] as? String }.sorted { ($0 ?? "") < ($1 ?? "") }
            == [Tools.getSystemStatus, Tools.runPlatformSelfTest].sorted())
    }

    @Test("Structured content is mirrored into a text block")
    func toolResultMirrorsStructuredContent() throws {
        let result = MCPServer.toolResult(["passed": true, "context": "terminal"], isError: false)
        #expect(result["isError"] as? Bool == false)
        #expect(result["structuredContent"] != nil)
        let content = try #require(result["content"] as? [[String: Any]])
        #expect(content.count == 1)
        #expect(content[0]["type"] as? String == "text")
        let text = try #require(content[0]["text"] as? String)
        let decoded = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(decoded["passed"] as? Bool == true)
    }

    /// A domain failure must arrive as a successful result with `isError: true` so the
    /// model can act on it; a JSON-RPC error is something it cannot do anything with.
    @Test("A tool that fails still returns a result, not a protocol error")
    func toolFailureIsNotAProtocolError() async throws {
        let server = MCPServer(
            repository: InMemoryCalendarRepository(scenario: .init(eventStatus: .denied))
        )
        let response = try #require(try await send(
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_system_status","arguments":{}}}"#,
            to: server
        ))
        #expect(response["error"] == nil)
        let result = try #require(response["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
    }

    /// Claude Desktop rebuilds the announced schema and drops `additionalProperties: false`,
    /// so server-side validation is mandatory rather than defence in depth.
    @Test("Unexpected arguments are rejected server-side")
    func validatesArgumentsServerSide() async throws {
        let server = try makeServer()
        let response = try #require(try await send(
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"run_platform_selftest","arguments":{"surprise":1}}}"#,
            to: server
        ))
        let result = try #require(response["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
    }

    @Test("A request with no method but an id is an invalid request")
    func invalidRequest() async throws {
        let server = try makeServer()
        let response = try #require(try await send(#"{"jsonrpc":"2.0","id":9}"#, to: server))
        #expect((response["error"] as? [String: Any])?["code"] as? Int == -32600)
    }

    @Test("The self-test tool round-trips against the fake and reports pass")
    func selfTestToolPasses() async throws {
        let server = try makeServer()
        let response = try #require(try await send(
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"run_platform_selftest","arguments":{}}}"#,
            to: server
        ))
        let result = try #require(response["result"] as? [String: Any])
        let structured = try #require(result["structuredContent"] as? [String: Any])
        let trips = try #require(structured["round_trips"] as? [[String: Any]])
        #expect(trips.count == 2)
        #expect(trips.allSatisfy { $0["read_back"] as? Bool == true })
        #expect(trips.allSatisfy { $0["deleted"] as? Bool == true })
    }
}
