import Foundation
import RCCBootstrap
import RCCCalendar
import RCCCore
import RCCDiagnostics

/// Minimal MCP server over stdio (SPEC §7.1, §10, §10.1).
///
/// Hand-rolled rather than built on the official Swift SDK. The SDK pulls swift-nio plus
/// five other packages to do what newline-delimited JSON over two file descriptors does in
/// a couple of hundred lines, it is pre-1.0 with breaking minor bumps, and fewer
/// third-party binaries inside a notarized artifact is strictly better. The seam is kept
/// narrow — a method dispatch table plus `ProtocolIO` — so adopting the SDK later is a
/// swap, not a rewrite. See docs/milestone-1.md.
///
/// **Milestone 1 scope.** Two tools, both about proving the platform works from inside the
/// process Claude Desktop actually spawns. The read/write tool surface in SPEC §10 lands
/// in Milestones 3 and 4.
public struct MCPServer: Sendable {
    /// SPEC §10.1 targets MCP revision `2026-07-28`, which removes the `initialize`
    /// handshake entirely. The shipping Claude Desktop (1.40609.0) verifiably still sends
    /// `initialize` and negotiates `2025-11-25`, so that is what this server speaks today.
    /// The dispatch table is data precisely so adding `server/discover` and a `_meta`
    /// envelope reader later is additive. `-32022` is reserved for the newer revision's
    /// `UnsupportedProtocolVersionError`.
    public static let supportedProtocolVersions = [
        "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05",
    ]
    public static let preferredProtocolVersion = "2025-11-25"

    public static let serverName = "reminder-calendar-control"

    private let repository: any CalendarRepository
    private let store: Store?
    private let disclaim: Disclaim.Result?

    /// `store` and `disclaim` are injectable so tests never touch the real state database
    /// and never depend on process-global disclaim state. `nil` store means the default
    /// path, which is what `rcc serve` uses.
    public init(
        repository: any CalendarRepository,
        store: Store? = nil,
        disclaim: Disclaim.Result? = Disclaim.result
    ) {
        self.repository = repository
        self.store = store
        self.disclaim = disclaim
    }

    /// Serve until stdin reaches EOF.
    public func run() async {
        ProtocolIO.activate()
        Log.shared.info("mcp.serving", ["version": .safe(BuildInfo.versionString)])

        // When another process changes the calendar store, bump the locator generation so
        // any page cursor issued beforehand is refused with `cursor_stale` on its next use
        // (SPEC §7.4/§10). Held for the lifetime of `run()`; released on return.
        let changeObserver = store.map { store in
            repository.observeStoreChanges {
                try? store.invalidateAllLocators()
                Log.shared.info("mcp.store_changed", ["outcome": .safe("locators_invalidated")])
            }
        } ?? nil
        defer { changeObserver.map(NotificationCenter.default.removeObserver) }

        await ProtocolIO.readFrames { line in
            if let reply = await response(for: line) {
                ProtocolIO.send(reply)
            }
        }
        Log.shared.info("mcp.stdin_closed")
    }

    /// Produce the reply for one frame, or `nil` when the frame must not be answered.
    ///
    /// Separated from the I/O so the dispatch rules — especially "never reply to a
    /// notification" — are directly testable without a pipe.
    func response(for line: Data) async -> [String: Any]? {
        guard let parsed = try? JSONSerialization.jsonObject(with: line) else {
            // A parse failure has no id to correlate against, so JSON-RPC requires null.
            return Self.errorResponse(id: NSNull(), code: -32700, message: "Parse error")
        }
        if parsed is [Any] {
            // A top-level array is a JSON-RPC batch: valid JSON, so not -32700. MCP removed
            // batching and Claude Desktop does not send it, but reporting it as a parse
            // error would send a client hunting for malformed JSON that is not there.
            return Self.errorResponse(
                id: NSNull(), code: -32600,
                message: "Batch requests are not supported; send one request per line."
            )
        }
        guard let message = parsed as? [String: Any] else {
            return Self.errorResponse(id: NSNull(), code: -32600, message: "Invalid Request")
        }

        let identifier = message["id"]
        guard let method = message["method"] as? String else {
            guard let identifier, !(identifier is NSNull) else { return nil }
            return Self.errorResponse(id: identifier, code: -32600, message: "Invalid Request")
        }

        // A notification has no `id` and must never be answered. Guarding here rather than
        // in each handler is what keeps `notifications/initialized` — which arrives
        // immediately after the initialize response — from desynchronising the stream.
        guard let identifier, !(identifier is NSNull) else {
            Log.shared.debug("mcp.notification", ["method": .safe(method)])
            return nil
        }

        switch method {
        case "initialize":
            return Self.successResponse(id: identifier, result: Self.initializeResult(for: message))
        case "ping":
            return Self.successResponse(id: identifier, result: [:])
        case "tools/list":
            return Self.successResponse(id: identifier, result: ["tools": Tools.descriptors])
        case "tools/call":
            switch await callTool(message["params"] as? [String: Any] ?? [:]) {
            case .success(let payload):
                return Self.successResponse(id: identifier, result: payload)
            case .protocolError(let code, let text):
                return Self.errorResponse(id: identifier, code: code, message: text)
            }
        default:
            return Self.errorResponse(id: identifier, code: -32601, message: "Method not found: \(method)")
        }
    }

    enum ToolOutcome {
        case success([String: Any])
        case protocolError(Int, String)
    }

    private func callTool(_ params: [String: Any]) async -> ToolOutcome {
        guard let name = params["name"] as? String else {
            return .protocolError(-32602, "Missing tool name")
        }
        // Arguments are validated here, never at the client: Claude Desktop rebuilds the
        // announced schema and drops `additionalProperties: false`, so client-side
        // rejection of unknown arguments cannot be relied on.
        let arguments = params["arguments"] as? [String: Any] ?? [:]

        switch name {
        case Tools.getSystemStatus:
            // Diagnostics are the one thing that must still work when the disclaim failed —
            // reporting *why* rcc is non-functional is the whole point of this tool.
            guard arguments.isEmpty else {
                return .success(Self.toolResult(
                    ["error": "This tool takes no arguments; received \(arguments.keys.sorted())"],
                    isError: true
                ))
            }
            let report = await Doctor(repository: repository, disclaim: disclaim).run()
            return .success(Self.toolResult(report.jsonObject(), isError: report.hasFailures))

        case Tools.runPlatformSelfTest:
            guard arguments.isEmpty else {
                return .success(Self.toolResult(
                    ["error": "This tool takes no arguments; received \(arguments.keys.sorted())"],
                    isError: true
                ))
            }
            do {
                let outcome = try await SelfTest(
                    repository: repository, store: store, disclaim: disclaim
                ).run(allowProvisioning: false)
                return .success(Self.toolResult(outcome.jsonObject(), isError: !outcome.passed))
            } catch {
                // A domain failure travels as a successful result with `isError: true` so
                // the model can act on it; JSON-RPC errors are reserved for protocol-level
                // problems it cannot do anything about.
                return .success(Self.toolResult(
                    ["error": Redaction.sanitize(String(describing: error), limit: 600)],
                    isError: true
                ))
            }

        case let name where ReadTools.names.contains(name):
            if let gate = disclaimGate() { return gate }
            do {
                var generation = 0
                if let store, let current = try? store.currentLocatorGeneration() {
                    generation = Int(current)
                }
                let payload = try await ReadTools.run(
                    name, arguments: arguments, repository: repository, generation: generation
                )
                return .success(Self.toolResult(payload, isError: false))
            } catch let error as ToolError {
                return .success(Self.toolResult(error.payload, isError: true))
            } catch {
                return .success(Self.toolResult(Self.internalErrorPayload(error), isError: true))
            }

        case let name where WriteTools.names.contains(name):
            if let gate = disclaimGate() { return gate }
            guard let store else {
                return .success(Self.toolResult(
                    ["error": "the local state database is unavailable, so writes cannot be journalled",
                     "code": "state", "retryable": false],
                    isError: true
                ))
            }
            do {
                let executor = MutationExecutor(repository: repository, store: store)
                let payload = try await WriteTools.run(name, arguments: arguments, executor: executor)
                return .success(Self.toolResult(payload, isError: false))
            } catch let error as ToolError {
                return .success(Self.toolResult(error.payload, isError: true))
            } catch {
                return .success(Self.toolResult(Self.internalErrorPayload(error), isError: true))
            }

        default:
            return .protocolError(-32602, "Unknown tool: \(name)")
        }
    }

    /// The shared "rcc has no TCC identity" refusal for every EventKit-touching tool.
    private func disclaimGate() -> ToolOutcome? {
        guard !DisclaimGate.isSatisfied(disclaim) else { return nil }
        return .success(Self.toolResult(
            ["error": "rcc cannot establish its own TCC identity; Calendar and Reminders are unavailable",
             "code": "disclaim_unavailable", "retryable": false],
            isError: true
        ))
    }

    private static func internalErrorPayload(_ error: any Error) -> [String: Any] {
        ["error": Redaction.sanitize(String(describing: error), limit: 600),
         "code": "internal", "retryable": false]
    }

    // MARK: - Envelope construction

    static func initializeResult(for message: [String: Any]) -> [String: Any] {
        let params = message["params"] as? [String: Any]
        let requested = params?["protocolVersion"] as? String
        // Echo the client's version when we speak it; otherwise answer with ours and let
        // the client decide whether to disconnect.
        let negotiated = requested.flatMap { supportedProtocolVersions.contains($0) ? $0 : nil }
            ?? preferredProtocolVersion

        return [
            "protocolVersion": negotiated,
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": [
                "name": serverName,
                "title": "Reminders & Calendar Control",
                "version": BuildInfo.version,
            ],
            "instructions": "macOS EventKit bridge. Milestone 1 exposes platform diagnostics only; "
                + "calendar and reminder CRUD arrive in later milestones.",
        ]
    }

    /// Structured content, mirrored into a text block.
    ///
    /// The spec asks a tool returning structured content to also return the serialized JSON
    /// as text for backwards compatibility, and in practice that text block is what most
    /// reliably reaches the model.
    static func toolResult(_ structured: [String: Any], isError: Bool) -> [String: Any] {
        // If the payload cannot be encoded, substituting `{}` for the *text* mirror is not
        // enough: embedding the same unencodable dictionary in `structuredContent` makes the
        // whole envelope fail to serialise, and `send` drops it — leaving the request with
        // no reply at all. Replace both, and say what happened.
        guard let data = try? JSONSerialization.data(
            withJSONObject: structured,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ), let text = String(data: data, encoding: .utf8) else {
            Log.shared.error("mcp.unencodable_result")
            let fallback: [String: Any] = [
                "error": "internal: the tool produced a result that could not be encoded as JSON",
            ]
            return [
                "content": [["type": "text", "text": #"{"error":"unencodable result"}"#]],
                "structuredContent": fallback,
                "isError": true,
            ]
        }
        return [
            "content": [["type": "text", "text": text]],
            "structuredContent": structured,
            "isError": isError,
        ]
    }

    static func successResponse(id: Any, result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func errorResponse(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }
}
