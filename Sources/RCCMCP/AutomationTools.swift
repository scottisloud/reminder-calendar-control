import Foundation
import RCCAutomation
import RCCCalendar
import RCCCore

/// Automation over MCP (SPEC §10, §11.4): Claude can author, preview, inspect, and switch
/// rules, and see what is waiting for approval. It cannot approve or reject anything — no
/// such tool exists here, in any context (SPEC §8.3, §6.4). `list_pending_actions` tells
/// the user which terminal command to run instead.
public enum AutomationTools {
    public static let listAutomations = "list_automations"
    public static let createAutomation = "create_automation"
    public static let updateAutomation = "update_automation"
    public static let deleteAutomation = "delete_automation"
    public static let previewAutomation = "preview_automation"
    public static let listPendingActions = "list_pending_actions"

    public static let names: Set<String> = [
        listAutomations, createAutomation, updateAutomation, deleteAutomation,
        previewAutomation, listPendingActions,
    ]

    public static func run(
        _ name: String, arguments: [String: Any], repository: any CalendarRepository, store: Store
    ) async throws -> [String: Any] {
        let catalog = RuleCatalog(repository: repository, store: store)
        do {
            switch name {
            case listAutomations:
                return ReadTools.envelope(data: try store.rules().map { try catalog.describe($0) })

            case createAutomation:
                guard let rule = arguments["rule"] as? [String: Any] else {
                    throw WriteArguments.invalid("`rule` (the rule document) is required")
                }
                let record = try await catalog.create(rule)
                return ReadTools.envelope(data: try catalog.describe(record), warnings: [
                    "Preview it with preview_automation before relying on it.",
                ])

            case updateAutomation:
                guard let id = ReadTools.string(arguments["id"]) else { throw WriteArguments.invalid("`id` is required") }
                let rule = arguments["rule"] as? [String: Any]
                let enabled = ReadTools.bool(arguments["enabled"])
                guard rule != nil || enabled != nil else {
                    throw WriteArguments.invalid("pass `rule` (a full replacement) and/or `enabled`")
                }
                return ReadTools.envelope(data: try catalog.describe(
                    try await catalog.update(id: id, document: rule, enabled: enabled)
                ))

            case deleteAutomation:
                guard let id = ReadTools.string(arguments["id"]) else { throw WriteArguments.invalid("`id` is required") }
                try catalog.delete(id: id)
                return ReadTools.envelope(data: ["deleted": id])

            case previewAutomation:
                guard let id = ReadTools.string(arguments["id"]) else { throw WriteArguments.invalid("`id` is required") }
                let reports = try await AutomationRunner(repository: repository, store: store, notifier: nil)
                    .runDue(ruleID: id, dryRun: true)
                guard let report = reports.first else { throw ToolError(code: "not_found", message: "no enabled rule \(id)") }
                return ReadTools.envelope(data: [
                    "rule_id": report.ruleID, "outcome": report.outcome,
                    "matched": report.matched as Any? ?? NSNull(), "detail": report.detail as Any? ?? NSNull(),
                ])

            case listPendingActions:
                try store.expireStagedActions(now: Date())
                let executor = StagedActionExecutor(repository: repository, store: store)
                let pending = try store.stagedActions(states: ["pending"]).map { action -> [String: Any] in
                    [
                        "id": action.id, "rule_id": action.ruleID as Any? ?? NSNull(), "summary": action.summary,
                        "impact": action.impact, "created_at": action.createdAt, "expires_at": action.expiresAt,
                        "items": executor.items(of: action).map(\.jsonObject),
                        "approve_with": "rcc automations approve \(action.id)",
                        "reject_with": "rcc automations reject \(action.id)",
                    ]
                }
                return ReadTools.envelope(
                    data: pending,
                    warnings: pending.isEmpty ? [] : [
                        "Only the user can approve, by running the approve_with command in Terminal. "
                            + "There is no tool for it; do not suggest a workaround.",
                    ]
                )

            default:
                throw ToolError(code: "internal", message: "\(name) is not an automation tool")
            }
        } catch let error as RuleError {
            throw ToolError(code: "invalid_argument", message: error.message)
        } catch let error as RCCError {
            throw ToolError(code: "invalid_argument", message: error.message)
        }
    }

    // MARK: - Descriptors

    private static var ruleSchema: [String: Any] {
        [
            "type": "object",
            "description": """
                A Tier 0 rule. Example — clear completed reminders older than 30 days from \
                Personal, nightly at 02:00: {"name": "Tidy Personal", "time_zone": \
                "America/Vancouver", "schedule": {"daily_at": "02:00"}, "trigger": \
                {"completed_reminders": {"older_than_days": 30, "lists": ["Personal"]}}, \
                "action": "delete"}. Flag meetings next week with no location, weekdays at \
                07:30: {"name": "Meetings missing a place", "time_zone": "America/Vancouver", \
                "schedule": {"weekly": {"days": ["monday","tuesday","wednesday","thursday","friday"], \
                "at": "07:30"}}, "trigger": {"events_without_location": {"days_ahead": 7}}, \
                "action": "flag"}. Triggers: completed_reminders {older_than_days, lists}, \
                events_without_location {days_ahead, calendars?, only_with_attendees?}, \
                back_to_back_events {days_ahead, calendars?, min_gap_minutes?}. Actions: \
                "flag" (notify; changes nothing) or "delete" (completed_reminders only; always \
                staged for the user to approve in Terminal). Optional: misfire_policy \
                ("run_once" | "skip"), max_lateness_minutes (default 720), max_fan_out \
                (default 50), enabled. Lists/calendars may be names or ids.
                """,
        ]
    }

    public static var descriptors: [[String: Any]] {
        func annotations(_ title: String, readOnly: Bool, destructive: Bool = false) -> [String: Any] {
            ["title": title, "readOnlyHint": readOnly, "destructiveHint": destructive,
             "idempotentHint": readOnly, "openWorldHint": false]
        }
        func object(_ props: [String: Any], required: [String] = []) -> [String: Any] {
            var out: [String: Any] = ["type": "object", "properties": props, "additionalProperties": false]
            if !required.isEmpty { out["required"] = required }
            return out
        }
        return [
            [
                "name": listAutomations,
                "description": "List automation rules: definition, enabled, next due time, last outcome, and recent runs.",
                "inputSchema": object([:]),
                "annotations": annotations("List Automations", readOnly: true),
            ],
            [
                "name": createAutomation,
                "description": """
                    Create an unattended automation rule that runs on a schedule without \
                    Claude. Flag rules only notify. Delete rules never delete on their own: \
                    each run stages its deletions and the user approves them in Terminal.
                    """,
                "inputSchema": object(["rule": ruleSchema], required: ["rule"]),
                "annotations": annotations("Create Automation", readOnly: false),
            ],
            [
                "name": updateAutomation,
                "description": "Replace a rule's definition (`rule`, full document) and/or switch it on or off (`enabled`).",
                "inputSchema": object(["id": ["type": "string"], "rule": ruleSchema, "enabled": ["type": "boolean"]],
                                      required: ["id"]),
                "annotations": annotations("Update Automation", readOnly: false),
            ],
            [
                "name": deleteAutomation,
                "description": "Delete an automation rule. Its run history is kept.",
                "inputSchema": object(["id": ["type": "string"]], required: ["id"]),
                "annotations": annotations("Delete Automation", readOnly: false, destructive: true),
                "_meta": ["anthropic/requiresUserInteraction": true],
            ],
            [
                "name": previewAutomation,
                "description": "Evaluate a rule now and report what it would do, changing nothing (a dry run).",
                "inputSchema": object(["id": ["type": "string"]], required: ["id"]),
                "annotations": annotations("Preview Automation", readOnly: true),
            ],
            [
                "name": listPendingActions,
                "description": """
                    List changes automation rules have staged for approval, with every item \
                    they would affect. Read-only: approval happens only when the user runs \
                    the `approve_with` command in Terminal — tell them the command.
                    """,
                "inputSchema": object([:]),
                "annotations": annotations("List Pending Actions", readOnly: true),
            ],
        ]
    }
}
