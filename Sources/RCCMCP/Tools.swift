import Foundation

/// The Milestone 1 tool surface (SPEC §10).
///
/// Annotations are set deliberately. `readOnlyHint` is the one annotation Claude Desktop
/// forwards to the model, and `readOnlyHint: true` exempts a tool from the approval
/// policy — so it is an authorisation-adjacent switch, not decoration. Nothing that writes
/// is ever marked read-only.
///
/// `_meta["anthropic/requiresUserInteraction"]` is emitted where SPEC §8.3 asks for it, but
/// nothing is architected around it: Claude Desktop's local MCP bridge rebuilds a
/// third-party server's tool descriptor from scratch and drops `_meta`, `title`,
/// `outputSchema`, and every annotation except `readOnlyHint`. SPEC §17 lists confirming
/// Desktop's behaviour as an open question; it is answered, and the answer is "it does not
/// honour it". See docs/milestone-1.md.
public enum Tools {
    public static let getSystemStatus = "get_system_status"
    public static let runPlatformSelfTest = "run_platform_selftest"

    public static var descriptors: [[String: Any]] {
        [
            [
                "name": getSystemStatus,
                "title": "Get System Status",
                "description": """
                    Report rcc's own health: TCC authorization for Calendar and Reminders, the \
                    self-disclaim mechanism, code-signing identity, install-path coherence, \
                    LaunchAgent state, and local state. Reads nothing from your calendars.
                    """,
                "inputSchema": [
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "additionalProperties": false,
                ],
                "annotations": [
                    "title": "Get System Status",
                    "readOnlyHint": true,
                    "destructiveHint": false,
                    "idempotentHint": true,
                    // EventKit is a closed local domain — nothing here reaches the network.
                    "openWorldHint": false,
                ],
            ],
            [
                "name": runPlatformSelfTest,
                "title": "Run Platform Self-Test",
                "description": """
                    Prove that rcc can read and write EventKit from this process. Creates one \
                    throwaway event and one throwaway reminder in rcc's own dedicated dev \
                    calendar and list, reads them back, then deletes them. Never touches any \
                    other calendar. Requires `rcc setup --dev` to have been run.
                    """,
                "inputSchema": [
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "additionalProperties": false,
                ],
                "annotations": [
                    "title": "Run Platform Self-Test",
                    "readOnlyHint": false,
                    // It writes, but only items it created and immediately removes.
                    "destructiveHint": false,
                    "idempotentHint": true,
                    "openWorldHint": false,
                ],
                "_meta": ["anthropic/requiresUserInteraction": true],
            ],
        ] + ReadTools.descriptors + WriteTools.descriptors + AutomationTools.descriptors
    }
}
