import Foundation
import RCCCalendar
import RCCCore

/// The Milestone 4 write path (SPEC §10). Every mutation runs through
/// `MutationExecutor`, so the operation journal, locators, `if_match`, recurrence-scope
/// validation, and idempotency replay all apply. The result envelope carries the new
/// `operation_id`, `result_identifier`, a fresh `locator`, and the item's new `version`.
///
/// Live-chat confirmation is Claude Desktop's own job (SPEC §8.3): destructive tools are
/// annotated `destructiveHint: true` and emit `_meta.anthropic/requiresUserInteraction`,
/// though Desktop currently forwards only `readOnlyHint`.
public enum WriteTools {
    public static let createEvent = "create_event"
    public static let updateEvent = "update_event"
    public static let deleteEvent = "delete_event"
    public static let createReminder = "create_reminder"
    public static let updateReminder = "update_reminder"
    public static let completeReminder = "complete_reminder"
    public static let deleteReminder = "delete_reminder"
    public static let createReminderList = "create_reminder_list"
    public static let updateReminderList = "update_reminder_list"
    public static let deleteReminderList = "delete_reminder_list"

    public static let names: Set<String> = [
        createEvent, updateEvent, deleteEvent,
        createReminder, updateReminder, completeReminder, deleteReminder,
        createReminderList, updateReminderList, deleteReminderList,
    ]

    public static let destructive: Set<String> = [deleteEvent, deleteReminder, deleteReminderList]

    // MARK: - Dispatch

    public static func run(
        _ name: String, arguments: [String: Any], executor: MutationExecutor
    ) async throws -> [String: Any] {
        let request = try buildRequest(name, arguments)
        do {
            let outcome = try await executor.execute(request)
            var data: [String: Any] = [
                "operation_id": outcome.operationID,
                "result_identifier": outcome.resultIdentifier as Any? ?? NSNull(),
                "locator": outcome.locator as Any? ?? NSNull(),
                "version": outcome.version as Any? ?? NSNull(),
                "replayed": outcome.replayed,
            ]
            if let count = outcome.affectedCount { data["reminders_removed"] = count }
            return ReadTools.envelope(data: data)
        } catch let error as MutationExecutor.ExecutorError {
            throw ToolError(code: error.code, message: describe(error))
        }
    }

    private static func describe(_ error: MutationExecutor.ExecutorError) -> String {
        switch error {
        case .notFound(let id): return "no such item: \(id)"
        case .conflict(let current): return "the item changed since you last saw it (current version \(current))"
        case .locatorUnknown: return "that locator is not recognised"
        case .locatorExpired: return "that locator has expired; re-read the item to get a fresh one"
        case .staleTargetNeedsIfMatch:
            return "the calendar changed since that locator was issued; re-read the item and pass its `if_match`"
        case .targetUnspecified: return "provide a `locator` or an `identifier` for the target"
        case .bareIdentifierRejectedForRecurring:
            return "this is a recurring event — pass a `locator` (from a read) and a `recurrence_scope`"
        case .recurrenceScopeRequired:
            return "this is a recurring event — set `recurrence_scope` to 'this_occurrence' or 'this_and_future'"
        case .illegalClear(let fields): return "these fields cannot be cleared: \(fields.joined(separator: ", "))"
        case .emptyPatch: return "the patch changes nothing"
        case .readOnly(let what): return "\(what) is read-only"
        case .repository(_, let message): return message
        }
    }

    // MARK: - Request building

    private static func buildRequest(
        _ name: String, _ args: [String: Any]
    ) throws -> MutationExecutor.Request {
        switch name {
        case createEvent:
            let draft = try eventDraft(args)
            return .init(action: .createEvent(draft), idempotencyKey: idem(args),
                         intentJSON: intent("create_event", calendar: draft.calendarIdentifier))

        case updateEvent:
            let (patch, changed) = try eventPatch(args["patch"])
            return .init(
                action: .updateEvent(patch),
                targetLocator: ReadTools.string(args["locator"]),
                targetIdentifier: ReadTools.string(args["identifier"]),
                ifMatch: ReadTools.string(args["if_match"]),
                recurrenceScope: try scope(args["recurrence_scope"]),
                idempotencyKey: idem(args),
                intentJSON: intent("update_event", fields: changed)
            )

        case deleteEvent:
            return .init(
                action: .deleteEvent,
                targetLocator: ReadTools.string(args["locator"]),
                targetIdentifier: ReadTools.string(args["identifier"]),
                ifMatch: ReadTools.string(args["if_match"]),
                recurrenceScope: try scope(args["recurrence_scope"]),
                idempotencyKey: idem(args),
                intentJSON: intent("delete_event")
            )

        case createReminder:
            let draft = try reminderDraft(args)
            return .init(action: .createReminder(draft), idempotencyKey: idem(args),
                         intentJSON: intent("create_reminder", calendar: draft.calendarIdentifier))

        case updateReminder:
            let (patch, changed) = try reminderPatch(args["patch"])
            return .init(
                action: .updateReminder(patch),
                targetLocator: ReadTools.string(args["locator"]),
                targetIdentifier: ReadTools.string(args["identifier"]),
                ifMatch: ReadTools.string(args["if_match"]),
                idempotencyKey: idem(args),
                intentJSON: intent("update_reminder", fields: changed)
            )

        case completeReminder:
            let completed = ReadTools.bool(args["completed"]) ?? true
            return .init(
                action: .completeReminder(completed),
                targetLocator: ReadTools.string(args["locator"]),
                targetIdentifier: ReadTools.string(args["identifier"]),
                ifMatch: ReadTools.string(args["if_match"]),
                idempotencyKey: idem(args),
                intentJSON: intent("update_reminder", fields: ["completed"])
            )

        case deleteReminder:
            return .init(
                action: .deleteReminder,
                targetLocator: ReadTools.string(args["locator"]),
                targetIdentifier: ReadTools.string(args["identifier"]),
                ifMatch: ReadTools.string(args["if_match"]),
                idempotencyKey: idem(args),
                intentJSON: intent("delete_reminder")
            )

        case createReminderList:
            guard let title = ReadTools.string(args["title"]) else {
                throw ToolError(code: "invalid_datetime", message: "`title` is required")
            }
            guard let source = ReadTools.string(args["source_id"]) else {
                throw ToolError(code: "invalid_datetime", message: "`source_id` is required (see list_sources)")
            }
            return .init(
                action: .createReminderList(title: title, sourceIdentifier: source),
                idempotencyKey: idem(args), intentJSON: intent("create_reminder_list")
            )

        case updateReminderList:
            guard let title = ReadTools.string(args["title"]) else {
                throw ToolError(code: "invalid_datetime", message: "`title` is required")
            }
            return .init(
                action: .updateReminderList(title: title),
                targetIdentifier: ReadTools.string(args["identifier"]) ?? ReadTools.string(args["list_id"]),
                idempotencyKey: idem(args), intentJSON: intent("update_reminder_list")
            )

        case deleteReminderList:
            return .init(
                action: .deleteReminderList,
                targetIdentifier: ReadTools.string(args["identifier"]) ?? ReadTools.string(args["list_id"]),
                idempotencyKey: idem(args), intentJSON: intent("delete_reminder_list")
            )

        default:
            throw ToolError(code: "internal", message: "\(name) is not a write tool")
        }
    }

    private static func eventDraft(_ args: [String: Any]) throws -> EventDraft {
        guard let calendarID = ReadTools.string(args["calendar_id"]) else {
            throw ToolError(code: "invalid_datetime", message: "`calendar_id` is required")
        }
        guard let title = ReadTools.string(args["title"]) else {
            throw ToolError(code: "invalid_datetime", message: "`title` is required")
        }
        guard let start = ReadTools.date(args["start"]), let end = ReadTools.date(args["end"]) else {
            throw ToolError(code: "invalid_datetime", message: "`start` and `end` (RFC 3339) are required")
        }
        guard end >= start else {
            throw ToolError(code: "invalid_datetime", message: "`end` must not precede `start`")
        }
        return EventDraft(
            calendarIdentifier: calendarID, title: title, start: start, end: end,
            notes: ReadTools.string(args["notes"])
        )
    }

    private static func reminderDraft(_ args: [String: Any]) throws -> ReminderDraft {
        guard let calendarID = ReadTools.string(args["calendar_id"]) else {
            throw ToolError(code: "invalid_datetime", message: "`calendar_id` is required")
        }
        guard let title = ReadTools.string(args["title"]) else {
            throw ToolError(code: "invalid_datetime", message: "`title` is required")
        }
        return ReminderDraft(
            calendarIdentifier: calendarID, title: title, notes: ReadTools.string(args["notes"])
        )
    }

    /// A `patch` object: a key present → `.set` (or `.clear` when its value is JSON null),
    /// a key absent → `.unchanged` (SPEC §9.5).
    private static func eventPatch(_ raw: Any?) throws -> (EventPatch, [String]) {
        guard let dict = raw as? [String: Any], !dict.isEmpty else {
            throw ToolError(code: "invalid_datetime", message: "`patch` must be a non-empty object")
        }
        var patch = EventPatch()
        var changed: [String] = []
        func field(_ key: String) -> Bool { dict.keys.contains(key) }
        func isNull(_ key: String) -> Bool { dict[key] is NSNull }

        if field("title") {
            patch.title = isNull("title") ? .clear : .set((dict["title"] as? String) ?? "")
            changed.append("title")
        }
        if field("start") {
            guard let date = ReadTools.date(dict["start"]) else {
                throw ToolError(code: "invalid_datetime", message: "`patch.start` must be RFC 3339")
            }
            patch.start = .set(date); changed.append("start")
        }
        if field("end") {
            guard let date = ReadTools.date(dict["end"]) else {
                throw ToolError(code: "invalid_datetime", message: "`patch.end` must be RFC 3339")
            }
            patch.end = .set(date); changed.append("end")
        }
        if field("all_day") { patch.isAllDay = .set(ReadTools.bool(dict["all_day"]) ?? false); changed.append("all_day") }
        if field("location") { patch.location = isNull("location") ? .clear : .set((dict["location"] as? String) ?? ""); changed.append("location") }
        if field("notes") { patch.notes = isNull("notes") ? .clear : .set((dict["notes"] as? String) ?? ""); changed.append("notes") }
        if field("url") { patch.url = isNull("url") ? .clear : .set((dict["url"] as? String) ?? ""); changed.append("url") }
        if field("time_zone") { patch.timeZoneIdentifier = isNull("time_zone") ? .clear : .set((dict["time_zone"] as? String) ?? ""); changed.append("time_zone") }
        if field("availability") { patch.availability = .set((dict["availability"] as? String) ?? ""); changed.append("availability") }
        return (patch, changed)
    }

    private static func reminderPatch(_ raw: Any?) throws -> (ReminderPatch, [String]) {
        guard let dict = raw as? [String: Any], !dict.isEmpty else {
            throw ToolError(code: "invalid_datetime", message: "`patch` must be a non-empty object")
        }
        var patch = ReminderPatch()
        var changed: [String] = []
        func field(_ key: String) -> Bool { dict.keys.contains(key) }
        func isNull(_ key: String) -> Bool { dict[key] is NSNull }

        if field("title") { patch.title = isNull("title") ? .clear : .set((dict["title"] as? String) ?? ""); changed.append("title") }
        if field("notes") { patch.notes = isNull("notes") ? .clear : .set((dict["notes"] as? String) ?? ""); changed.append("notes") }
        if field("url") { patch.url = isNull("url") ? .clear : .set((dict["url"] as? String) ?? ""); changed.append("url") }
        if field("location") { patch.location = isNull("location") ? .clear : .set((dict["location"] as? String) ?? ""); changed.append("location") }
        if field("priority") {
            if isNull("priority") { patch.priorityRaw = .set(0) }
            else if let value = ReadTools.int(dict["priority"]) { patch.priorityRaw = .set(value) }
            changed.append("priority")
        }
        if field("due") {
            if isNull("due") { patch.dueDate = .clear }
            else if let date = ReadTools.date(dict["due"]) { patch.dueDate = .set(date) }
            else { throw ToolError(code: "invalid_datetime", message: "`patch.due` must be RFC 3339 or null") }
            changed.append("due")
        }
        if field("start") {
            if isNull("start") { patch.startDate = .clear }
            else if let date = ReadTools.date(dict["start"]) { patch.startDate = .set(date) }
            else { throw ToolError(code: "invalid_datetime", message: "`patch.start` must be RFC 3339 or null") }
            changed.append("start")
        }
        return (patch, changed)
    }

    private static func scope(_ raw: Any?) throws -> RecurrenceScope? {
        guard let value = ReadTools.string(raw) else { return nil }
        guard let scope = RecurrenceScope(rawValue: value) else {
            throw ToolError(code: "invalid_datetime",
                            message: "`recurrence_scope` must be 'this_occurrence' or 'this_and_future'")
        }
        return scope
    }

    private static func idem(_ args: [String: Any]) -> String? {
        ReadTools.string(args["idempotency_key"])
    }

    /// Journal intent — names of changed fields and the calendar, never content text (§13).
    private static func intent(_ kind: String, calendar: String? = nil, fields: [String] = []) -> String {
        var object: [String: Any] = ["kind": kind]
        if let calendar { object["calendar_id"] = calendar }
        if !fields.isEmpty { object["fields_changed"] = fields.sorted() }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{\"kind\":\"\(kind)\"}"
    }

    // MARK: - Descriptors

    public static var descriptors: [[String: Any]] {
        func annotations(_ title: String, destructive: Bool) -> [String: Any] {
            ["title": title, "readOnlyHint": false, "destructiveHint": destructive,
             "idempotentHint": false, "openWorldHint": false]
        }
        func target(extra: [String: Any] = [:]) -> [String: Any] {
            var props: [String: Any] = [
                "locator": ["type": "string", "description": "A handle from a read result (preferred)."],
                "identifier": ["type": "string", "description": "A bare EventKit id (not accepted for a recurring event)."],
                "if_match": ["type": "string", "description": "The item's `version` from when you last read it; a mismatch is a conflict."],
                "idempotency_key": ["type": "string"],
            ]
            for (k, v) in extra { props[k] = v }
            return ["type": "object", "properties": props, "additionalProperties": false]
        }

        return [
            [
                "name": createEvent,
                "description": "Create a calendar event. `calendar_id`, `title`, `start`, `end` (RFC 3339) required.",
                "inputSchema": ["type": "object", "additionalProperties": false, "properties": [
                    "calendar_id": ["type": "string"], "title": ["type": "string"],
                    "start": ["type": "string"], "end": ["type": "string"],
                    "notes": ["type": "string"], "idempotency_key": ["type": "string"],
                ], "required": ["calendar_id", "title", "start", "end"]],
                "annotations": annotations("Create Event", destructive: false),
            ],
            [
                "name": updateEvent,
                "description": """
                    Edit a calendar event. Give a `locator` (or `identifier`) plus a `patch` \
                    object: an included key sets that field, an explicit null clears it, an \
                    omitted key leaves it. A recurring event needs `recurrence_scope`.
                    """,
                "inputSchema": target(extra: [
                    "recurrence_scope": ["type": "string", "enum": ["this_occurrence", "this_and_future"]],
                    "patch": ["type": "object", "description":
                        "Any of: title, start, end, all_day, location, notes, url, time_zone, availability."],
                ]),
                "annotations": annotations("Update Event", destructive: false),
            ],
            [
                "name": deleteEvent,
                "description": "Delete a calendar event. A recurring event needs `recurrence_scope`.",
                "inputSchema": target(extra: [
                    "recurrence_scope": ["type": "string", "enum": ["this_occurrence", "this_and_future"]],
                ]),
                "annotations": annotations("Delete Event", destructive: true),
                "_meta": ["anthropic/requiresUserInteraction": true],
            ],
            [
                "name": createReminder,
                "description": "Create a reminder. `calendar_id` and `title` required.",
                "inputSchema": ["type": "object", "additionalProperties": false, "properties": [
                    "calendar_id": ["type": "string"], "title": ["type": "string"],
                    "notes": ["type": "string"], "idempotency_key": ["type": "string"],
                ], "required": ["calendar_id", "title"]],
                "annotations": annotations("Create Reminder", destructive: false),
            ],
            [
                "name": updateReminder,
                "description": "Edit a reminder. `locator`/`identifier` + a `patch` object (title, notes, url, location, priority, due, start; null clears).",
                "inputSchema": target(extra: [
                    "patch": ["type": "object"],
                ]),
                "annotations": annotations("Update Reminder", destructive: false),
            ],
            [
                "name": completeReminder,
                "description": "Mark a reminder complete (or set `completed: false` to reopen it).",
                "inputSchema": target(extra: [
                    "completed": ["type": "boolean", "description": "Defaults to true."],
                ]),
                "annotations": annotations("Complete Reminder", destructive: false),
            ],
            [
                "name": deleteReminder,
                "description": "Delete a reminder.",
                "inputSchema": target(),
                "annotations": annotations("Delete Reminder", destructive: true),
                "_meta": ["anthropic/requiresUserInteraction": true],
            ],
            [
                "name": createReminderList,
                "description": "Create a new reminder list. `title` and `source_id` (from list_sources) required.",
                "inputSchema": ["type": "object", "additionalProperties": false, "properties": [
                    "title": ["type": "string"], "source_id": ["type": "string"],
                    "idempotency_key": ["type": "string"],
                ], "required": ["title", "source_id"]],
                "annotations": annotations("Create Reminder List", destructive: false),
            ],
            [
                "name": updateReminderList,
                "description": "Rename a reminder list. Reminder-only lists only — a mixed-entity calendar is refused.",
                "inputSchema": ["type": "object", "additionalProperties": false, "properties": [
                    "identifier": ["type": "string"], "list_id": ["type": "string"],
                    "title": ["type": "string"], "idempotency_key": ["type": "string"],
                ], "required": ["title"]],
                "annotations": annotations("Update Reminder List", destructive: false),
            ],
            [
                "name": deleteReminderList,
                "description": "Delete a reminder list and everything in it. Reminder-only lists only. The result reports `reminders_removed`.",
                "inputSchema": ["type": "object", "additionalProperties": false, "properties": [
                    "identifier": ["type": "string"], "list_id": ["type": "string"],
                    "idempotency_key": ["type": "string"],
                ]],
                "annotations": annotations("Delete Reminder List", destructive: true),
                "_meta": ["anthropic/requiresUserInteraction": true],
            ],
        ]
    }
}
