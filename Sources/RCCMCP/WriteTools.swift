import Foundation
import RCCCalendar
import RCCCore

/// The write path (SPEC §10). Every mutation runs through `MutationExecutor`, so the
/// operation journal, locators, `if_match`, recurrence-scope validation, and idempotency
/// replay all apply. A result carries the new `operation_id`, `result_identifier`, a fresh
/// `locator`, the item's new `version`, and the item itself as saved — so the caller sees
/// what EventKit actually stored (a day-only due date, the alert it added) without a
/// second read.
///
/// Calendars and lists are named by identifier *or* title (`CalendarResolver`). The two
/// batch tools exist because Claude Desktop confirms each tool call: "complete these five"
/// as five calls is five prompts.
///
/// Live-chat confirmation is Claude Desktop's own job (SPEC §8.3): destructive tools are
/// annotated `destructiveHint: true`, which Desktop does honour with a prompt.
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
    public static let completeReminders = "complete_reminders"
    public static let updateReminders = "update_reminders"

    public static let names: Set<String> = [
        createEvent, updateEvent, deleteEvent,
        createReminder, updateReminder, completeReminder, deleteReminder,
        createReminderList, updateReminderList, deleteReminderList,
        completeReminders, updateReminders,
    ]

    public static let destructive: Set<String> = [deleteEvent, deleteReminder, deleteReminderList]

    /// The most items one batch call may carry.
    static let batchLimit = 50

    /// A tool result: the envelope, and whether it reports a failure. A batch in which
    /// every item failed is an error; one in which only some did is not (SPEC §10.1's
    /// best-effort, per-item contract), and says so in `warnings`.
    public struct Result {
        public var payload: [String: Any]
        public var isError: Bool
    }

    // MARK: - Dispatch

    public static func run(
        _ name: String, arguments: [String: Any],
        executor: MutationExecutor, repository: any CalendarRepository
    ) async throws -> Result {
        let resolver = CalendarResolver(repository: repository)
        switch name {
        case completeReminders, updateReminders:
            return try await runBatch(name, arguments, executor: executor, resolver: resolver)
        default:
            let request = try await buildRequest(name, arguments, resolver: resolver)
            let outcome = try await execute(request, executor: executor)
            let completing = name == completeReminder ? (ReadTools.bool(arguments["completed"]) ?? true) : nil
            return Result(
                payload: ReadTools.envelope(data: project(outcome, completing: completing)), isError: false
            )
        }
    }

    private static func execute(
        _ request: MutationExecutor.Request, executor: MutationExecutor
    ) async throws -> MutationExecutor.Outcome {
        do {
            return try await executor.execute(request)
        } catch let error as MutationExecutor.ExecutorError {
            throw ToolError(code: error.code, message: describe(error))
        }
    }

    private static func project(_ outcome: MutationExecutor.Outcome, completing: Bool? = nil) -> [String: Any] {
        var data: [String: Any] = [
            "operation_id": outcome.operationID,
            "result_identifier": outcome.resultIdentifier as Any? ?? NSNull(),
            "locator": outcome.locator as Any? ?? NSNull(),
            "version": outcome.version as Any? ?? NSNull(),
            "replayed": outcome.replayed,
        ]
        if let count = outcome.affectedCount { data["reminders_removed"] = count }
        if let event = outcome.event { data["event"] = ReadTools.project(event: event, detail: true) }
        if let reminder = outcome.reminder {
            data["reminder"] = ReadTools.project(reminder: reminder, detail: true)
        }
        if completing == true, let reminder = outcome.reminder,
           !reminder.recurrenceRules.isEmpty, !reminder.isCompleted {
            // EventKit records a completed occurrence of a repeating reminder as a new,
            // completed reminder and advances this one to its next date — so the item
            // returned here reads `completed: false`. Say what happened, or it looks like a
            // failed write.
            let next = reminder.dueDate.map { ReadTools.describe(components: $0) } ?? "its next date"
            data["note"] = "This reminder repeats: this occurrence was completed and recorded "
                + "separately, and the reminder has moved on to its next occurrence (due \(next))."
        }
        if let calendar = outcome.calendar { data["list"] = ReadTools.project(calendar: calendar) }
        return data
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
            return "this is a recurring event — pass the occurrence's `locator` (from list_events or get_event) and a `recurrence_scope`"
        case .recurrenceScopeRequired:
            return "this is a recurring event — set `recurrence_scope` to 'this_occurrence' or 'this_and_future'"
        case .illegalClear(let fields): return "these fields cannot be cleared: \(fields.joined(separator: ", "))"
        case .emptyPatch: return "the patch changes nothing"
        case .invalid(let message), .unsupported(let message): return message
        case .readOnly(let what): return "\(what) is read-only"
        case .repository(_, let message): return message
        }
    }

    // MARK: - Batches

    private static func runBatch(
        _ name: String, _ args: [String: Any],
        executor: MutationExecutor, resolver: CalendarResolver
    ) async throws -> Result {
        guard let items = args["items"] as? [Any], !items.isEmpty else {
            throw WriteArguments.invalid("`items` must be a non-empty array")
        }
        guard items.count <= batchLimit else {
            throw WriteArguments.invalid("at most \(batchLimit) items per call (got \(items.count))")
        }
        let completed = ReadTools.bool(args["completed"]) ?? true

        var results: [[String: Any]] = []
        var failures = 0
        for (index, raw) in items.enumerated() {
            var row: [String: Any] = ["index": index]
            do {
                guard let item = raw as? [String: Any] else {
                    throw WriteArguments.invalid("item \(index) is not an object")
                }
                let request: MutationExecutor.Request
                if name == completeReminders {
                    try WriteArguments.requireKnownKeys(
                        item, ["locator", "identifier", "if_match", "idempotency_key"], in: "items[\(index)]"
                    )
                    request = completeRequest(item, completed: completed)
                } else {
                    try WriteArguments.requireKnownKeys(
                        item, ["locator", "identifier", "if_match", "idempotency_key", "patch"],
                        in: "items[\(index)]"
                    )
                    request = try await updateReminderRequest(item, resolver: resolver)
                }
                let outcome = try await execute(request, executor: executor)
                row["ok"] = true
                let completing = name == completeReminders ? completed : nil
                for (key, value) in project(outcome, completing: completing) { row[key] = value }
            } catch let error as ToolError {
                failures += 1
                row["ok"] = false
                for (key, value) in error.payload { row[key] = value }
            }
            results.append(row)
        }

        var warnings: [String] = []
        if failures > 0, failures < items.count {
            warnings.append("partial_failure: \(failures) of \(items.count) items failed; see `results`")
        }
        let data: [String: Any] = [
            "succeeded": items.count - failures,
            "failed": failures,
            "results": results,
        ]
        return Result(
            payload: ReadTools.envelope(data: data, warnings: warnings),
            isError: failures == items.count
        )
    }

    // MARK: - Request building

    private static func buildRequest(
        _ name: String, _ args: [String: Any], resolver: CalendarResolver
    ) async throws -> MutationExecutor.Request {
        switch name {
        case createEvent:
            let draft = try await eventDraft(args, resolver: resolver)
            return .init(action: .createEvent(draft), idempotencyKey: idem(args),
                         intentJSON: intent("create_event", calendar: draft.calendarIdentifier))

        case updateEvent:
            let patch = try await eventPatch(args["patch"], resolver: resolver)
            return .init(
                action: .updateEvent(patch),
                targetLocator: ReadTools.string(args["locator"]),
                targetIdentifier: ReadTools.string(args["identifier"]),
                ifMatch: ReadTools.string(args["if_match"]),
                recurrenceScope: try scope(args["recurrence_scope"]),
                idempotencyKey: idem(args),
                intentJSON: intent("update_event", fields: patch.changedFields)
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
            let draft = try await reminderDraft(args, resolver: resolver)
            return .init(action: .createReminder(draft), idempotencyKey: idem(args),
                         intentJSON: intent("create_reminder", calendar: draft.calendarIdentifier))

        case updateReminder:
            return try await updateReminderRequest(args, resolver: resolver)

        case completeReminder:
            return completeRequest(args, completed: ReadTools.bool(args["completed"]) ?? true)

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
                throw WriteArguments.invalid("`title` is required")
            }
            let source = try await reminderSource(args, resolver: resolver)
            return .init(
                action: .createReminderList(title: title, sourceIdentifier: source),
                idempotencyKey: idem(args), intentJSON: intent("create_reminder_list")
            )

        case updateReminderList:
            guard let title = ReadTools.string(args["title"]) else {
                throw WriteArguments.invalid("`title` is required")
            }
            return .init(
                action: .updateReminderList(title: title),
                targetIdentifier: try await listTarget(args, resolver: resolver),
                idempotencyKey: idem(args), intentJSON: intent("update_reminder_list")
            )

        case deleteReminderList:
            return .init(
                action: .deleteReminderList,
                targetIdentifier: try await listTarget(args, resolver: resolver),
                idempotencyKey: idem(args), intentJSON: intent("delete_reminder_list")
            )

        default:
            throw ToolError(code: "internal", message: "\(name) is not a write tool")
        }
    }

    private static func completeRequest(_ args: [String: Any], completed: Bool) -> MutationExecutor.Request {
        .init(
            action: .completeReminder(completed),
            targetLocator: ReadTools.string(args["locator"]),
            targetIdentifier: ReadTools.string(args["identifier"]),
            ifMatch: ReadTools.string(args["if_match"]),
            idempotencyKey: idem(args),
            intentJSON: intent("update_reminder", fields: ["completed"])
        )
    }

    private static func updateReminderRequest(
        _ args: [String: Any], resolver: CalendarResolver
    ) async throws -> MutationExecutor.Request {
        let patch = try await reminderPatch(args["patch"], resolver: resolver)
        return .init(
            action: .updateReminder(patch),
            targetLocator: ReadTools.string(args["locator"]),
            targetIdentifier: ReadTools.string(args["identifier"]),
            ifMatch: ReadTools.string(args["if_match"]),
            idempotencyKey: idem(args),
            intentJSON: intent("update_reminder", fields: patch.changedFields)
        )
    }

    /// `list` (id or name) for a reminder list target; `identifier`/`list_id` still work.
    private static func listTarget(_ args: [String: Any], resolver: CalendarResolver) async throws -> String? {
        guard let reference = ReadTools.string(args["list"])
            ?? ReadTools.string(args["identifier"]) ?? ReadTools.string(args["list_id"])
        else { return nil }
        return try await resolver.resolve(reference, entity: .reminder)
    }

    /// The account a new list goes in: `source_id` if given, else the account the user's
    /// existing reminder lists live in — when there is exactly one.
    private static func reminderSource(_ args: [String: Any], resolver: CalendarResolver) async throws -> String {
        if let source = ReadTools.string(args["source_id"]) { return source }
        let sources = Set(try await resolver.calendars(for: .reminder).compactMap(\.sourceIdentifier))
        guard sources.count == 1, let only = sources.first else {
            throw WriteArguments.invalid(
                "your reminder lists span \(sources.count) accounts; pass `source_id` (see list_sources)"
            )
        }
        return only
    }

    // MARK: - Drafts

    private static let eventFields: Set<String> = [
        "calendar", "calendar_id", "title", "start", "end", "all_day", "time_zone", "location",
        "notes", "url", "availability", "recurrence", "alarms", "idempotency_key",
    ]

    private static func eventDraft(_ args: [String: Any], resolver: CalendarResolver) async throws -> EventDraft {
        try WriteArguments.requireKnownKeys(args, eventFields, in: "create_event")
        guard let calendarRef = ReadTools.string(args["calendar"]) ?? ReadTools.string(args["calendar_id"]) else {
            throw WriteArguments.invalid("`calendar` (a calendar name or id) is required")
        }
        guard let title = ReadTools.string(args["title"]) else {
            throw WriteArguments.invalid("`title` is required")
        }
        let zone = try WriteArguments.timeZone(args["time_zone"]) ?? .current
        let allDay = ReadTools.bool(args["all_day"]) ?? false
        guard let start = try WriteArguments.eventTime(args["start"], field: "start", zone: zone) else {
            throw ToolError(code: "invalid_datetime", message: "`start` is required")
        }
        let end: Date
        if let given = try WriteArguments.eventTime(args["end"], field: "end", zone: zone) {
            end = given
        } else {
            // Unstated: an all-day event is one day; a timed one is an hour.
            end = allDay ? start : start.addingTimeInterval(3600)
        }
        guard end >= start else {
            throw ToolError(code: "invalid_datetime", message: "`end` must not precede `start`")
        }
        return EventDraft(
            calendarIdentifier: try await resolver.resolve(calendarRef, entity: .event),
            title: title, start: start, end: end,
            notes: ReadTools.string(args["notes"]),
            isAllDay: allDay,
            timeZoneIdentifier: ReadTools.string(args["time_zone"]),
            location: ReadTools.string(args["location"]),
            url: ReadTools.string(args["url"]),
            availability: ReadTools.string(args["availability"]),
            recurrenceRules: try args["recurrence"].flatMap { $0 is NSNull ? nil : $0 }
                .map { try WriteArguments.recurrence($0) } ?? [],
            alarms: try args["alarms"].flatMap { $0 is NSNull ? nil : $0 }
                .map { try WriteArguments.alarms($0) } ?? []
        )
    }

    private static let reminderFields: Set<String> = [
        "list", "calendar_id", "title", "notes", "url", "location", "priority", "due", "start",
        "time_zone", "recurrence", "alarms", "idempotency_key",
    ]

    private static func reminderDraft(
        _ args: [String: Any], resolver: CalendarResolver
    ) async throws -> ReminderDraft {
        try WriteArguments.requireKnownKeys(args, reminderFields, in: "create_reminder")
        guard let listRef = ReadTools.string(args["list"]) ?? ReadTools.string(args["calendar_id"]) else {
            throw WriteArguments.invalid("`list` (a reminder list name or id) is required")
        }
        guard let title = ReadTools.string(args["title"]) else {
            throw WriteArguments.invalid("`title` is required")
        }
        _ = try WriteArguments.timeZone(args["time_zone"])  // validate early
        return ReminderDraft(
            calendarIdentifier: try await resolver.resolve(listRef, entity: .reminder),
            title: title,
            notes: ReadTools.string(args["notes"]),
            url: ReadTools.string(args["url"]),
            location: ReadTools.string(args["location"]),
            priorityRaw: try args["priority"].map(WriteArguments.priority) ?? 0,
            dueDate: try args["due"].flatMap { $0 is NSNull ? nil : $0 }
                .map { try WriteArguments.reminderDate($0, field: "due") },
            startDate: try args["start"].flatMap { $0 is NSNull ? nil : $0 }
                .map { try WriteArguments.reminderDate($0, field: "start") },
            timeZoneIdentifier: ReadTools.string(args["time_zone"]),
            recurrenceRules: try args["recurrence"].flatMap { $0 is NSNull ? nil : $0 }
                .map { try WriteArguments.recurrence($0) } ?? [],
            alarms: try args["alarms"].flatMap { $0 is NSNull ? nil : $0 }
                .map { try WriteArguments.alarms($0) }
        )
    }

    // MARK: - Patches

    private static let eventPatchFields: Set<String> = [
        "title", "start", "end", "all_day", "location", "notes", "url", "time_zone",
        "availability", "calendar", "recurrence", "alarms",
    ]

    /// A `patch` object: a key present → `.set` (or `.clear` when its value is JSON null),
    /// a key absent → `.unchanged` (SPEC §9.5).
    private static func eventPatch(_ raw: Any?, resolver: CalendarResolver) async throws -> EventPatch {
        guard let dict = raw as? [String: Any], !dict.isEmpty else {
            throw WriteArguments.invalid("`patch` must be a non-empty object")
        }
        try WriteArguments.requireKnownKeys(dict, eventPatchFields, in: "patch")
        var patch = EventPatch()
        func has(_ key: String) -> Bool { dict.keys.contains(key) }
        func isNull(_ key: String) -> Bool { dict[key] is NSNull }
        let zone = isNull("time_zone") ? .current : (try WriteArguments.timeZone(dict["time_zone"]) ?? .current)

        patch.title = WriteArguments.stringPatch(dict, "title")
        for key in ["start", "end"] where has(key) {
            guard let date = try WriteArguments.eventTime(dict[key], field: "patch.\(key)", zone: zone) else {
                throw ToolError(code: "invalid_datetime", message: "`patch.\(key)` cannot be cleared")
            }
            if key == "start" { patch.start = .set(date) } else { patch.end = .set(date) }
        }
        if has("all_day") { patch.isAllDay = .set(ReadTools.bool(dict["all_day"]) ?? false) }
        patch.location = WriteArguments.stringPatch(dict, "location")
        patch.notes = WriteArguments.stringPatch(dict, "notes")
        patch.url = WriteArguments.stringPatch(dict, "url")
        patch.timeZoneIdentifier = WriteArguments.stringPatch(dict, "time_zone")
        if has("availability") {
            guard let name = ReadTools.string(dict["availability"]) else {
                throw WriteArguments.invalid("`patch.availability` cannot be cleared; set busy, free, tentative, or unavailable")
            }
            patch.availability = .set(name)
        }
        if has("calendar") {
            if isNull("calendar") {
                patch.calendarIdentifier = .clear  // rejected by the executor, with a reason
            } else {
                guard let reference = ReadTools.string(dict["calendar"]) else {
                    throw WriteArguments.invalid("`patch.calendar` must be a calendar name or id")
                }
                patch.calendarIdentifier = .set(try await resolver.resolve(reference, entity: .event))
            }
        }
        if has("recurrence") {
            patch.recurrenceRules = isNull("recurrence") ? .clear : .set(try WriteArguments.recurrence(dict["recurrence"]))
        }
        if has("alarms") {
            patch.alarms = isNull("alarms") ? .clear : .set(try WriteArguments.alarms(dict["alarms"]))
        }
        return patch
    }

    private static let reminderPatchFields: Set<String> = [
        "title", "notes", "url", "location", "priority", "due", "start", "list",
        "recurrence", "alarms",
    ]

    private static func reminderPatch(_ raw: Any?, resolver: CalendarResolver) async throws -> ReminderPatch {
        guard let dict = raw as? [String: Any], !dict.isEmpty else {
            throw WriteArguments.invalid("`patch` must be a non-empty object")
        }
        try WriteArguments.requireKnownKeys(dict, reminderPatchFields, in: "patch")
        var patch = ReminderPatch()
        func has(_ key: String) -> Bool { dict.keys.contains(key) }
        func isNull(_ key: String) -> Bool { dict[key] is NSNull }

        patch.title = WriteArguments.stringPatch(dict, "title")
        patch.notes = WriteArguments.stringPatch(dict, "notes")
        patch.url = WriteArguments.stringPatch(dict, "url")
        patch.location = WriteArguments.stringPatch(dict, "location")
        if has("priority") { patch.priorityRaw = .set(try WriteArguments.priority(dict["priority"])) }
        if has("due") {
            patch.dueDate = isNull("due") ? .clear : .set(try WriteArguments.reminderDate(dict["due"], field: "patch.due"))
        }
        if has("start") {
            patch.startDate = isNull("start") ? .clear : .set(try WriteArguments.reminderDate(dict["start"], field: "patch.start"))
        }
        if has("list") {
            if isNull("list") {
                patch.calendarIdentifier = .clear  // rejected by the executor, with a reason
            } else {
                guard let reference = ReadTools.string(dict["list"]) else {
                    throw WriteArguments.invalid("`patch.list` must be a reminder list name or id")
                }
                patch.calendarIdentifier = .set(try await resolver.resolve(reference, entity: .reminder))
            }
        }
        if has("recurrence") {
            patch.recurrenceRules = isNull("recurrence") ? .clear : .set(try WriteArguments.recurrence(dict["recurrence"]))
        }
        if has("alarms") {
            patch.alarms = isNull("alarms") ? .clear : .set(try WriteArguments.alarms(dict["alarms"]))
        }
        return patch
    }

    private static func scope(_ raw: Any?) throws -> RecurrenceScope? {
        guard let value = ReadTools.string(raw) else { return nil }
        guard let scope = RecurrenceScope(rawValue: value) else {
            throw WriteArguments.invalid("`recurrence_scope` must be 'this_occurrence' or 'this_and_future'")
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

    private static var recurrenceSchema: [String: Any] { [
        "type": "object",
        "description": """
            A repeat rule — the same shape get_event/get_reminder return in \
            `recurrence_rules`. E.g. every other Tuesday until June: {"frequency": \
            "weekly", "interval": 2, "days_of_week": ["tuesday"], "until": "2027-06-30"}. \
            Last Friday of each month: {"frequency": "monthly", "days_of_week": \
            [{"weekday": "friday", "ordinal": -1}]}. Ends via `until` (date), `count`, or \
            neither (forever).
            """,
        "properties": [
            "frequency": ["type": "string", "enum": ["daily", "weekly", "monthly", "yearly"]],
            "interval": ["type": "integer", "minimum": 1],
            "days_of_week": ["type": "array", "description": "Weekday names, or {weekday, ordinal} for 'the 2nd Tuesday' (ordinal -1 = last)."],
            "days_of_month": ["type": "array", "items": ["type": "integer"]],
            "months_of_year": ["type": "array", "items": ["type": "integer"]],
            "set_positions": ["type": "array", "items": ["type": "integer"]],
            "until": ["type": "string", "description": "Last date, inclusive (YYYY-MM-DD or RFC 3339)."],
            "count": ["type": "integer", "minimum": 1],
        ] as [String: Any],
        "required": ["frequency"],
    ] }

    private static var alarmsSchema: [String: Any] { [
        "type": "array",
        "description": "Alerts. Each is {\"minutes_before\": n} or {\"absolute_date\": RFC 3339}. [] for none.",
        "items": ["type": "object", "properties": [
            "minutes_before": ["type": "number", "minimum": 0],
            "absolute_date": ["type": "string"],
            "relative_offset_seconds": ["type": "number"],
        ] as [String: Any]],
    ] }

    private static let priorityDescription =
        "'high', 'medium', 'low', or 'none' (or EventKit's 0–9, 1 = highest)."

    public static var descriptors: [[String: Any]] {
        func annotations(_ title: String, destructive: Bool, idempotent: Bool = false) -> [String: Any] {
            ["title": title, "readOnlyHint": false, "destructiveHint": destructive,
             "idempotentHint": idempotent, "openWorldHint": false]
        }
        func targetProps() -> [String: Any] {
            [
                "locator": ["type": "string", "description": "The item's `locator` from a read (preferred; required for one occurrence of a recurring event)."],
                "identifier": ["type": "string", "description": "The item's `id`. Fine for reminders and one-off events."],
                "if_match": ["type": "string", "description": "The item's `version` from your last read; if it has changed since, the write is refused as a conflict."],
                "idempotency_key": ["type": "string", "description": "Any unique string; retrying with the same key replays the first result instead of writing twice."],
            ]
        }
        func object(_ props: [String: Any], required: [String] = []) -> [String: Any] {
            var out: [String: Any] = ["type": "object", "properties": props, "additionalProperties": false]
            if !required.isEmpty { out["required"] = required }
            return out
        }
        func with(_ base: [String: Any], _ extra: [String: Any]) -> [String: Any] {
            base.merging(extra) { _, new in new }
        }

        let eventPatchSchema: [String: Any] = [
            "type": "object",
            "description": "Fields to change. Include a key to set it, set it to null to clear it, omit it to leave it.",
            "properties": [
                "title": ["type": "string"],
                "start": ["type": "string", "description": "RFC 3339, or YYYY-MM-DD for all-day."],
                "end": ["type": "string"],
                "all_day": ["type": "boolean"],
                "location": ["type": ["string", "null"]],
                "notes": ["type": ["string", "null"]],
                "url": ["type": ["string", "null"]],
                "time_zone": ["type": ["string", "null"], "description": "IANA name."],
                "availability": ["type": "string", "enum": ["busy", "free", "tentative", "unavailable"]],
                "calendar": ["type": "string", "description": "Move to this calendar (name or id)."],
                "recurrence": ["description": "A repeat rule, or null to stop repeating. Series-level: needs recurrence_scope 'this_and_future'."],
                "alarms": with(alarmsSchema, ["type": ["array", "null"]]),
            ] as [String: Any],
        ]
        let reminderPatchSchema: [String: Any] = [
            "type": "object",
            "description": "Fields to change. Include a key to set it, set it to null to clear it, omit it to leave it.",
            "properties": [
                "title": ["type": "string"],
                "notes": ["type": ["string", "null"]],
                "url": ["type": ["string", "null"]],
                "location": ["type": ["string", "null"]],
                "priority": ["description": priorityDescription],
                "due": ["type": ["string", "null"], "description": "YYYY-MM-DD for a day, RFC 3339 for a time. An alert that was tracking the old due time moves with it."],
                "start": ["type": ["string", "null"]],
                "list": ["type": "string", "description": "Move to this reminder list (name or id)."],
                "recurrence": ["description": "A repeat rule, or null to stop repeating."],
                "alarms": with(alarmsSchema, ["type": ["array", "null"]]),
            ] as [String: Any],
        ]

        return [
            [
                "name": createEvent,
                "description": """
                    Create a calendar event. Needs `calendar` (name or id), `title`, and \
                    `start`. `end` defaults to an hour later (or the same day when `all_day`). \
                    For an all-day event pass dates: start "2026-10-05", end "2026-10-07" \
                    (inclusive). Returns the event as saved.
                    """,
                "inputSchema": object([
                    "calendar": ["type": "string", "description": "Calendar name or id (see list_calendars)."],
                    "title": ["type": "string"],
                    "start": ["type": "string", "description": "RFC 3339 with offset, or YYYY-MM-DD when all_day."],
                    "end": ["type": "string"],
                    "all_day": ["type": "boolean"],
                    "time_zone": ["type": "string", "description": "IANA name; defaults to this Mac's zone."],
                    "location": ["type": "string"],
                    "notes": ["type": "string"],
                    "url": ["type": "string"],
                    "availability": ["type": "string", "enum": ["busy", "free", "tentative", "unavailable"]],
                    "recurrence": recurrenceSchema,
                    "alarms": alarmsSchema,
                    "idempotency_key": ["type": "string"],
                ], required: ["calendar", "title", "start"]),
                "annotations": annotations("Create Event", destructive: false),
            ],
            [
                "name": updateEvent,
                "description": """
                    Edit a calendar event, including moving it to another calendar or \
                    changing its repeat rule and alerts. Target it with `locator` (or \
                    `identifier`) and pass a `patch`. A recurring event needs \
                    `recurrence_scope`: 'this_occurrence' edits only the occurrence whose \
                    locator you pass; 'this_and_future' splits the series there.
                    """,
                "inputSchema": object(with(targetProps(), [
                    "recurrence_scope": ["type": "string", "enum": ["this_occurrence", "this_and_future"]],
                    "patch": eventPatchSchema,
                ]), required: ["patch"]),
                "annotations": annotations("Update Event", destructive: false),
            ],
            [
                "name": deleteEvent,
                "description": """
                    Delete a calendar event. A recurring event needs `recurrence_scope`: \
                    'this_occurrence' removes the one occurrence; 'this_and_future' ends the \
                    series there.
                    """,
                "inputSchema": object(with(targetProps(), [
                    "recurrence_scope": ["type": "string", "enum": ["this_occurrence", "this_and_future"]],
                ])),
                "annotations": annotations("Delete Event", destructive: true),
                "_meta": ["anthropic/requiresUserInteraction": true],
            ],
            [
                "name": createReminder,
                "description": """
                    Create a reminder. Needs `list` (name or id) and `title`. `due` is a date \
                    ("2026-10-05", due that day) or an RFC 3339 time; a timed reminder gets an \
                    alert at that time unless you pass `alarms`. A repeating reminder needs a \
                    `due`. Returns the reminder as saved.
                    """,
                "inputSchema": object([
                    "list": ["type": "string", "description": "Reminder list name or id (see list_reminder_lists)."],
                    "title": ["type": "string"],
                    "due": ["type": "string", "description": "YYYY-MM-DD for a day, RFC 3339 for a time."],
                    "start": ["type": "string", "description": "When to start showing it; same format as due."],
                    "priority": ["description": priorityDescription],
                    "notes": ["type": "string"],
                    "url": ["type": "string"],
                    "location": ["type": "string"],
                    "time_zone": ["type": "string", "description": "IANA name for a timed due; defaults to this Mac's zone."],
                    "recurrence": recurrenceSchema,
                    "alarms": alarmsSchema,
                    "idempotency_key": ["type": "string"],
                ], required: ["list", "title"]),
                "annotations": annotations("Create Reminder", destructive: false),
            ],
            [
                "name": updateReminder,
                "description": """
                    Edit a reminder: retitle, reschedule, re-prioritise, move to another list, \
                    change its repeat rule or alerts. Target with `identifier` (or `locator`) \
                    and pass a `patch`. For several reminders at once use update_reminders.
                    """,
                "inputSchema": object(with(targetProps(), ["patch": reminderPatchSchema]), required: ["patch"]),
                "annotations": annotations("Update Reminder", destructive: false),
            ],
            [
                "name": completeReminder,
                "description": "Mark a reminder complete (or `completed: false` to reopen it). For several at once use complete_reminders.",
                "inputSchema": object(with(targetProps(), [
                    "completed": ["type": "boolean", "description": "Defaults to true."],
                ])),
                "annotations": annotations("Complete Reminder", destructive: false, idempotent: true),
            ],
            [
                "name": completeReminders,
                "description": """
                    Mark up to \(batchLimit) reminders complete (or reopen them with \
                    `completed: false`) in one call. Each item succeeds or fails on its own; \
                    the result lists both.
                    """,
                "inputSchema": object([
                    "items": ["type": "array", "maxItems": batchLimit, "items": object(targetProps())],
                    "completed": ["type": "boolean", "description": "Defaults to true."],
                ], required: ["items"]),
                "annotations": annotations("Complete Reminders", destructive: false, idempotent: true),
            ],
            [
                "name": updateReminders,
                "description": """
                    Apply a patch to each of up to \(batchLimit) reminders in one call — move \
                    several to a list, push several to tomorrow, and so on. Each item has its \
                    own target and `patch` (same fields as update_reminder) and succeeds or \
                    fails on its own.
                    """,
                "inputSchema": object([
                    "items": ["type": "array", "maxItems": batchLimit,
                              "items": object(with(targetProps(), ["patch": reminderPatchSchema]), required: ["patch"])],
                ], required: ["items"]),
                "annotations": annotations("Update Reminders", destructive: false),
            ],
            [
                "name": deleteReminder,
                "description": "Delete a reminder.",
                "inputSchema": object(targetProps()),
                "annotations": annotations("Delete Reminder", destructive: true),
                "_meta": ["anthropic/requiresUserInteraction": true],
            ],
            [
                "name": createReminderList,
                "description": """
                    Create a reminder list. `title` required. It goes in the same account as \
                    your other lists; pass `source_id` (from list_sources) only if they span \
                    several accounts.
                    """,
                "inputSchema": object([
                    "title": ["type": "string"], "source_id": ["type": "string"],
                    "idempotency_key": ["type": "string"],
                ], required: ["title"]),
                "annotations": annotations("Create Reminder List", destructive: false),
            ],
            [
                "name": updateReminderList,
                "description": "Rename a reminder list (`list`: its current name or id). Reminder-only lists only.",
                "inputSchema": object([
                    "list": ["type": "string"], "title": ["type": "string", "description": "The new name."],
                    "idempotency_key": ["type": "string"],
                ], required: ["list", "title"]),
                "annotations": annotations("Rename Reminder List", destructive: false),
            ],
            [
                "name": deleteReminderList,
                "description": "Delete a reminder list (`list`: name or id) and every reminder in it. The result reports `reminders_removed`.",
                "inputSchema": object([
                    "list": ["type": "string"], "idempotency_key": ["type": "string"],
                ], required: ["list"]),
                "annotations": annotations("Delete Reminder List", destructive: true),
                "_meta": ["anthropic/requiresUserInteraction": true],
            ],
        ]
    }
}
