import Foundation
import Testing

@testable import RCCBootstrap

@testable import RCCCalendar
@testable import RCCCore
@testable import RCCMCP

@Suite("MCP wire contract")
struct MCPServerTests {
    private func makeStore() throws -> Store {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rcc-mcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try Store(url: directory.appendingPathComponent("state.sqlite3", isDirectory: false))
    }

    private var healthyDisclaim: Disclaim.Result {
        Disclaim.Result(
            outcome: .disclaimed, generation: 1, responsiblePID: 1, pid: 1, mechanismAvailable: true
        )
    }

    private func makeServer(
        repository: InMemoryCalendarRepository? = nil,
        store: Store? = nil
    ) throws -> MCPServer {
        MCPServer(
            repository: repository ?? InMemoryCalendarRepository(
                scenario: .init(eventStatus: .fullAccess, reminderStatus: .fullAccess)
            ),
            store: try store ?? makeStore(),
            disclaim: healthyDisclaim
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
        #expect(tools.count == 2 + ReadTools.names.count)
        var names = Set<String>()
        for tool in tools {
            let name = try #require(tool["name"] as? String)
            #expect(!name.isEmpty)
            #expect(names.insert(name).inserted, "duplicate descriptor \(name)")
            #expect((tool["description"] as? String)?.isEmpty == false)
            let schema = try #require(tool["inputSchema"] as? [String: Any])
            #expect(schema["type"] as? String == "object")
            #expect(schema["additionalProperties"] as? Bool == false)
        }
        #expect(JSONSerialization.isValidJSONObject(["tools": tools]))
    }

    /// `readOnlyHint: true` is not decoration — it is the only annotation Claude Desktop
    /// forwards, and it exempts a tool from the approval policy. Marking a mutating tool
    /// read-only would be a real security bug.
    @Test("Only genuinely read-only tools claim to be read-only")
    func readOnlyHintIsHonest() throws {
        // The only tool that writes anything.
        let mutating: Set<String> = [Tools.runPlatformSelfTest]
        for tool in Tools.descriptors {
            let name = try #require(tool["name"] as? String)
            let annotations = try #require(tool["annotations"] as? [String: Any])
            let readOnly = annotations["readOnlyHint"] as? Bool ?? false
            if mutating.contains(name) {
                #expect(readOnly == false, "\(name) writes but claims readOnlyHint")
            } else {
                #expect(readOnly == true, "\(name) is read-only but does not claim it")
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
        let names = Set(tools.compactMap { $0["name"] as? String })
        #expect(names == ReadTools.names.union([Tools.getSystemStatus, Tools.runPlatformSelfTest]))
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
            repository: InMemoryCalendarRepository(scenario: .init(eventStatus: .denied)),
            store: try makeStore(),
            disclaim: healthyDisclaim
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

    @Test("The self-test tool round-trips an already-provisioned fixture")
    func selfTestToolPasses() async throws {
        let repository = InMemoryCalendarRepository(
            scenario: .init(eventStatus: .fullAccess, reminderStatus: .fullAccess)
        )
        let store = try makeStore()
        // A human provisions the fixture; the model-facing tool only uses it.
        let fixtures = DevFixtureManager(repository: repository, store: store)
        for entityType in RCCEntityType.allCases {
            _ = try await fixtures.provision(entityType)
        }

        let server = try makeServer(repository: repository, store: store)
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

    /// A model-invokable tool must not create two permanent calendars in the user's
    /// Calendar.app, whatever its description says it requires.
    @Test("The self-test tool refuses when no fixture has been provisioned")
    func selfTestToolWillNotProvision() async throws {
        let server = try makeServer()
        let response = try #require(try await send(
            #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"run_platform_selftest","arguments":{}}}"#,
            to: server
        ))
        let result = try #require(response["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
    }

    /// SPEC §6.2: when the disclaim is unhealthy rcc is non-functional for TCC-touching
    /// work — including when the caller is a model rather than a human.
    @Test("An unhealthy disclaim makes the EventKit tool refuse, while diagnostics still answer")
    func failsClosedOverMCP() async throws {
        let unhealthy = Disclaim.Result(
            outcome: .notDisclaimed, generation: 1, responsiblePID: 99, pid: 1, mechanismAvailable: true
        )
        let server = MCPServer(
            repository: InMemoryCalendarRepository(
                scenario: .init(eventStatus: .fullAccess, reminderStatus: .fullAccess)
            ),
            store: try makeStore(),
            disclaim: unhealthy
        )
        let selfTest = try #require(try await send(
            #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"run_platform_selftest","arguments":{}}}"#,
            to: server
        ))
        #expect((selfTest["result"] as? [String: Any])?["isError"] as? Bool == true)

        // Diagnostics must keep working: reporting why rcc is broken is their whole job.
        let status = try #require(try await send(
            #"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"get_system_status","arguments":{}}}"#,
            to: server
        ))
        #expect(status["result"] != nil)
    }

    @Test("A JSON-RPC batch is rejected as an invalid request, not as malformed JSON")
    func rejectsBatch() async throws {
        let server = try makeServer()
        let response = try #require(try await send(
            #"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#, to: server
        ))
        let error = try #require(response["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32600)
        #expect((error["message"] as? String)?.contains("Batch") == true)
    }

    @Test("get_system_status also rejects unknown arguments")
    func statusValidatesArguments() async throws {
        let server = try makeServer()
        let response = try #require(try await send(
            #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"get_system_status","arguments":{"x":1}}}"#,
            to: server
        ))
        #expect((response["result"] as? [String: Any])?["isError"] as? Bool == true)
    }
}

@Suite("Frame splitting")
struct FrameSplitterTests {
    private func text(_ frames: [Data]) -> [String] {
        frames.map { String(decoding: $0, as: UTF8.self) }
    }

    @Test("Several frames in one chunk all come back, in order")
    func splitsMultipleFrames() {
        var splitter = FrameSplitter()
        #expect(text(splitter.append(Data("{\"a\":1}\n{\"b\":2}\n".utf8))) == ["{\"a\":1}", "{\"b\":2}"])
        #expect(splitter.pendingByteCount == 0)
    }

    @Test("A frame split across chunks is reassembled")
    func reassemblesAcrossChunks() {
        var splitter = FrameSplitter()
        #expect(splitter.append(Data("{\"a\"".utf8)).isEmpty)
        #expect(splitter.append(Data(":1}".utf8)).isEmpty)
        #expect(text(splitter.append(Data("\n".utf8))) == ["{\"a\":1}"])
    }

    /// The hazard this type exists for: a sliced `Data` keeps its parent's index base, so
    /// index arithmetic that assumes zero-based storage reads the wrong bytes or traps.
    /// Feeding one byte at a time maximises the number of re-slices.
    @Test("Byte-at-a-time delivery survives repeated re-slicing")
    func survivesByteAtATime() {
        var splitter = FrameSplitter()
        var frames: [Data] = []
        for byte in Array("one\ntwo\nthree\n".utf8) {
            frames.append(contentsOf: splitter.append(Data([byte])))
        }
        #expect(text(frames) == ["one", "two", "three"])
        #expect(splitter.pendingByteCount == 0)
    }

    @Test("Blank lines are padding, not frames")
    func skipsBlankLines() {
        var splitter = FrameSplitter()
        #expect(text(splitter.append(Data("\n\n{\"a\":1}\n\n".utf8))) == ["{\"a\":1}"])
    }

    @Test("A frame larger than one read is handled")
    func handlesLargeFrame() {
        var splitter = FrameSplitter()
        let payload = String(repeating: "x", count: 200_000)
        #expect(splitter.append(Data(payload.utf8)).isEmpty)
        #expect(splitter.pendingByteCount == 200_000)
        let frames = splitter.append(Data("\n".utf8))
        #expect(frames.count == 1)
        #expect(frames[0].count == 200_000)
        #expect(splitter.pendingByteCount == 0)
    }

    @Test("A truncated trailing frame is retained, not silently emitted")
    func retainsTruncatedFrame() {
        var splitter = FrameSplitter()
        #expect(splitter.append(Data("{\"a\":1}\n{\"incomp".utf8)).count == 1)
        // At EOF a non-zero pending count is how a caller detects a truncated stream.
        #expect(splitter.pendingByteCount == 8)
    }

    @Test("Non-UTF8 bytes do not break framing")
    func handlesBinaryGarbage() {
        var splitter = FrameSplitter()
        let frames = splitter.append(Data([0xFF, 0xFE, 0x0A, 0x7B, 0x7D, 0x0A]))
        #expect(frames.count == 2)
        #expect(frames[0] == Data([0xFF, 0xFE]))
        #expect(frames[1] == Data([0x7B, 0x7D]))
    }
}
