import Foundation
import RCCCalendar
import RCCCore

/// The Milestone 3 read path (SPEC §10).
///
/// Every handler returns a common envelope — `schema_version`, `as_of`, `data`,
/// `warnings`, and (for list tools) `pagination`. List tools return a compact projection;
/// `get_*` tools return the full DTO. Notes, participant URLs, and precise structured
/// locations are omitted from list results unless the caller opts in (SPEC §13).
public enum ReadTools {
    public static let schemaVersion = 1

    // MARK: - Tool names

    public static let listCalendars = "list_calendars"
    public static let listReminderLists = "list_reminder_lists"
    public static let listSources = "list_sources"
    public static let listEvents = "list_events"
    public static let searchEvents = "search_events"
    public static let getEvent = "get_event"
    public static let listReminders = "list_reminders"
    public static let searchReminders = "search_reminders"
    public static let getReminder = "get_reminder"

    public static let names: Set<String> = [
        listCalendars, listReminderLists, listSources, listEvents, searchEvents, getEvent,
        listReminders, searchReminders, getReminder,
    ]

    // MARK: - Descriptors

    private static func readOnly(_ title: String) -> [String: Any] {
        ["title": title, "readOnlyHint": true, "destructiveHint": false,
         "idempotentHint": true, "openWorldHint": false]
    }

    private static func schema(
        _ properties: [String: Any], required: [String] = []
    ) -> [String: Any] {
        var out: [String: Any] = [
            "type": "object", "properties": properties, "additionalProperties": false,
        ]
        if !required.isEmpty { out["required"] = required }
        return out
    }

    private static func paginationProps() -> [String: Any] {
        [
            "limit": ["type": "integer", "description": "Page size, 1–200 (default 50)."],
            "cursor": ["type": "string", "description": "Opaque cursor from a previous page's `pagination.next_cursor`."],
            "include_details": ["type": "boolean", "description": "Return the full item shape instead of the compact list projection."],
        ]
    }

    private static func eventQueryProps() -> [String: Any] {
        var props: [String: Any] = [
            "from": ["type": "string", "description": "Window start, RFC 3339."],
            "to": ["type": "string", "description": "Window end, RFC 3339."],
            "calendar_ids": ["type": "array", "items": ["type": "string"],
                             "description": "Restrict to these calendars (ids or names); omit for all."],
            "text": ["type": "string", "description": "Match against title and location."],
            "search_notes": ["type": "boolean", "description": "Also match `text` against notes."],
            "attendee": ["type": "string", "description": "Match a participant name, email, or URL."],
        ]
        for (key, value) in paginationProps() { props[key] = value }
        return props
    }

    public static var descriptors: [[String: Any]] {
        [
            [
                "name": listSources,
                "description": "List the calendar/reminder accounts (EKSource) configured on this Mac.",
                "inputSchema": schema([:]),
                "annotations": readOnly("List Accounts"),
            ],
            [
                "name": listCalendars,
                "description": "List calendars and reminder lists. Optionally filter by `entity_type` ('event' or 'reminder').",
                "inputSchema": schema([
                    "entity_type": ["type": "string", "enum": ["event", "reminder"]],
                ]),
                "annotations": readOnly("List Calendars"),
            ],
            [
                "name": listReminderLists,
                "description": "List reminder lists (calendars that hold reminders).",
                "inputSchema": schema([:]),
                "annotations": readOnly("List Reminder Lists"),
            ],
            [
                "name": listEvents,
                "description": """
                    List calendar events in a bounded time window. `from` and `to` are \
                    required RFC 3339 timestamps; a window over four years is walked in \
                    chunks automatically. Optional `text` / `attendee` narrow the result \
                    (post-fetch). Compact projection unless `include_details` is set.
                    """,
                "inputSchema": schema(eventQueryProps(), required: ["from", "to"]),
                "annotations": readOnly("List Events"),
            ],
            [
                "name": searchEvents,
                "description": """
                    Search calendar events by free text (`text`, matched against title, \
                    location, and — with `search_notes` — notes) or by `attendee` (name, \
                    email, or URL), within the required `from`/`to` window. One of `text` \
                    or `attendee` is required.
                    """,
                "inputSchema": schema(eventQueryProps(), required: ["from", "to"]),
                "annotations": readOnly("Search Events"),
            ],
            [
                "name": getEvent,
                "description": """
                    Get one event with full detail (notes, attendees, alarms, recurrence). \
                    For one occurrence of a recurring event pass its `locator` from \
                    list_events (or `event_id` + `occurrence_date`); `event_id` alone returns \
                    the series' first occurrence.
                    """,
                "inputSchema": schema([
                    "event_id": ["type": "string"],
                    "occurrence_date": ["type": "string", "description": "RFC 3339; the occurrence's `occurrence_date`."],
                    "locator": ["type": "string"],
                ]),
                "annotations": readOnly("Get Event"),
            ],
            [
                "name": listReminders,
                "description": """
                    List reminders across lists, soonest due first. All filters optional: \
                    `due_window` ('overdue' | 'today' | 'overdue_or_today' | 'next_7_days', \
                    in local time, day-only reminders counted by their day), `completion` \
                    ('any'|'incomplete'|'completed'), `calendar_ids` (list ids or names), a \
                    `due_from`/`due_to` range (undated reminders are still included unless \
                    `include_undated` is false), `completed_from`/`completed_to`, `text` \
                    (+ `search_notes`), and `minimum_priority` ('low'|'medium'|'high').
                    """,
                "inputSchema": schema([
                    "due_window": ["type": "string", "enum": ReminderDueWindow.allCases.map(\.rawValue)],
                    "completion": ["type": "string", "enum": ["any", "incomplete", "completed"]],
                    "calendar_ids": ["type": "array", "items": ["type": "string"], "description": "List ids or names."],
                    "due_from": ["type": "string", "description": "RFC 3339."],
                    "due_to": ["type": "string", "description": "RFC 3339."],
                    "completed_from": ["type": "string", "description": "RFC 3339."],
                    "completed_to": ["type": "string", "description": "RFC 3339."],
                    "include_undated": ["type": "boolean"],
                    "text": ["type": "string"],
                    "search_notes": ["type": "boolean"],
                    "minimum_priority": ["type": "string", "enum": ["low", "medium", "high"]],
                    "limit": paginationProps()["limit"] as Any,
                    "cursor": paginationProps()["cursor"] as Any,
                    "include_details": paginationProps()["include_details"] as Any,
                ]),
                "annotations": readOnly("List Reminders"),
            ],
            [
                "name": searchReminders,
                "description": "Search reminders by free text (`text`, + `search_notes`). Same filters as list_reminders; `text` is required.",
                "inputSchema": schema([
                    "text": ["type": "string"],
                    "search_notes": ["type": "boolean"],
                    "completion": ["type": "string", "enum": ["any", "incomplete", "completed"]],
                    "calendar_ids": ["type": "array", "items": ["type": "string"]],
                    "minimum_priority": ["type": "string", "enum": ["low", "medium", "high"]],
                    "limit": paginationProps()["limit"] as Any,
                    "cursor": paginationProps()["cursor"] as Any,
                    "include_details": paginationProps()["include_details"] as Any,
                ], required: ["text"]),
                "annotations": readOnly("Search Reminders"),
            ],
            [
                "name": getReminder,
                "description": "Get one reminder by identifier, with full detail (notes, alerts, repeat rule).",
                "inputSchema": schema([
                    "reminder_id": ["type": "string"],
                ], required: ["reminder_id"]),
                "annotations": readOnly("Get Reminder"),
            ],
        ]
    }

    // MARK: - Dispatch

    /// Run one read tool. Returns the structured envelope, or a `ToolError` whose `code`
    /// is a stable SPEC §10.1 string.
    public static func run(
        _ name: String,
        arguments: [String: Any],
        repository: any CalendarRepository,
        store: Store?
    ) async throws -> [String: Any] {
        let generation = Int((try? store?.currentLocatorGeneration()) ?? 0 ?? 0)
        switch name {
        case listSources:
            return try await runListSources(repository)
        case listCalendars:
            return try await runListCalendars(arguments, repository, forcedEntity: nil)
        case listReminderLists:
            return try await runListCalendars(arguments, repository, forcedEntity: .reminder)
        case listEvents:
            return try await runListEvents(arguments, repository, store, generation, requireQuery: false)
        case searchEvents:
            return try await runListEvents(arguments, repository, store, generation, requireQuery: true)
        case getEvent:
            return try await runGetEvent(arguments, repository, store)
        case listReminders:
            return try await runListReminders(arguments, repository, generation, requireQuery: false)
        case searchReminders:
            return try await runListReminders(arguments, repository, generation, requireQuery: true)
        case getReminder:
            return try await runGetReminder(arguments, repository, store)
        default:
            throw ToolError(code: "internal", message: "\(name) is not a read tool")
        }
    }

    /// Issue a locator for an item just returned by a `get_*` tool, so the model has a
    /// tamper-proof handle to pass to a later `update_*` / `delete_*` (SPEC §9.4). Failing
    /// to issue one is not fatal — the model can still use the bare identifier.
    private static func locatorHandle(
        for entity: RCCEntityType, calendarID: String, sourceID: String?, identifier: String,
        recurringOccurrence: Date?, store: Store?
    ) -> String? {
        guard let store else { return nil }
        return try? store.issueLocator(
            entityType: entity.rawValue, calendarID: calendarID, sourceID: sourceID,
            itemIdentifier: identifier,
            occurrenceDate: recurringOccurrence.map(RCCTime.instant)
        ).handle
    }

    // MARK: - Handlers

    private static func runListSources(_ repository: any CalendarRepository) async throws -> [String: Any] {
        let sources = try await mapRepositoryError { try await repository.sources() }
        return envelope(data: sources.map(project(source:)))
    }

    private static func runListCalendars(
        _ arguments: [String: Any],
        _ repository: any CalendarRepository,
        forcedEntity: RCCEntityType?
    ) async throws -> [String: Any] {
        let entity = try forcedEntity ?? optionalEntity(arguments["entity_type"])
        let entities: [RCCEntityType] = entity.map { [$0] } ?? RCCEntityType.allCases

        var byID: [String: CalendarSummary] = [:]
        for entity in entities {
            let calendars = try await mapRepositoryError { try await repository.calendars(for: entity) }
            for calendar in calendars { byID[calendar.id] = calendar }
        }
        let ordered = byID.values.sorted { ($0.title, $0.id) < ($1.title, $1.id) }
        return envelope(data: ordered.map(project(calendar:)))
    }

    private static func runListEvents(
        _ arguments: [String: Any],
        _ repository: any CalendarRepository,
        _ store: Store?,
        _ generation: Int,
        requireQuery: Bool
    ) async throws -> [String: Any] {
        guard let from = date(arguments["from"]), let to = date(arguments["to"]) else {
            throw ToolError(code: "invalid_datetime", message: "`from` and `to` (RFC 3339) are required")
        }
        guard to > from else {
            throw ToolError(code: "invalid_datetime", message: "`to` must be after `from`")
        }
        let resolver = CalendarResolver(repository: repository)
        let calendarIDs = try await resolver.resolveFilter(stringArray(arguments["calendar_ids"]), entity: .event)
        let detail = bool(arguments["include_details"]) ?? false
        let text = string(arguments["text"])
        let searchNotes = bool(arguments["search_notes"]) ?? false
        let attendee = string(arguments["attendee"])
        if requireQuery, text == nil, attendee == nil {
            throw ToolError(code: "invalid_argument", message: "`search_events` needs `text` or `attendee`")
        }

        var all = try await mapRepositoryError {
            try await repository.listEvents(calendarIdentifiers: calendarIDs, from: from, to: to)
        }
        // Non-EventKit-native filters, applied before page construction so page semantics
        // do not shift under a text filter (SPEC §10).
        if let text {
            all = all.filter { event in
                var haystack = "\(event.title)\n\(event.location ?? "")"
                if searchNotes { haystack += "\n\(event.notes ?? "")" }
                return haystack.localizedCaseInsensitiveContains(text)
            }
        }
        if let attendee {
            all = all.filter { event in
                (event.participants + [event.organizer].compactMap { $0 }).contains { participant in
                    [participant.name, participant.email, participant.url]
                        .compactMap { $0 }
                        .contains { $0.localizedCaseInsensitiveContains(attendee) }
                }
            }
        }

        let page = try paginate(all, arguments: arguments, generation: generation)
        let titles = await resolver.titles()
        return envelope(
            data: page.items.map { event in
                var row = project(event: event, detail: detail)
                row["calendar_title"] = titles[event.calendarIdentifier] as Any? ?? NSNull()
                // Every occurrence of a series shares one `id`; the locator is what lets a
                // later write (or get_event) reach *this* occurrence (SPEC §9.4).
                if event.isRecurring || event.isDetached, let handle = locatorHandle(
                    for: .event, calendarID: event.calendarIdentifier, sourceID: event.sourceIdentifier,
                    identifier: event.id, recurringOccurrence: event.occurrenceDate, store: store
                ) {
                    row["locator"] = handle
                }
                return row
            },
            pagination: paginationBlock(page)
        )
    }

    private static func runGetEvent(
        _ arguments: [String: Any],
        _ repository: any CalendarRepository,
        _ store: Store?
    ) async throws -> [String: Any] {
        var id = string(arguments["event_id"])
        var occurrence = date(arguments["occurrence_date"])
        if arguments["occurrence_date"] != nil, occurrence == nil {
            throw ToolError(code: "invalid_datetime", message: "`occurrence_date` must be RFC 3339")
        }
        if let handle = string(arguments["locator"]) {
            guard let store, case .ok(let locator)? = try? store.resolveLocator(handle) else {
                throw ToolError(code: "not_found", message: "that locator is not recognised or has expired")
            }
            id = locator.itemIdentifier
            occurrence = locator.occurrenceDate.flatMap(RCCTime.parse)
        }
        guard let id else {
            throw ToolError(code: "invalid_argument", message: "pass `event_id` or `locator`")
        }
        guard let event = try await mapRepositoryError({
            try await repository.event(withIdentifier: id, occurrenceDate: occurrence)
        }) else {
            throw ToolError(code: "not_found", message: occurrence == nil
                ? "no event with identifier \(id)"
                : "event \(id) has no occurrence at \(RCCTime.instant(occurrence!))")
        }
        var payload = project(event: event, detail: true)
        payload["locator"] = locatorHandle(
            for: .event, calendarID: event.calendarIdentifier, sourceID: event.sourceIdentifier,
            identifier: id,
            recurringOccurrence: event.isRecurring || event.isDetached ? event.occurrenceDate : nil,
            store: store
        ) as Any? ?? NSNull()
        return envelope(data: payload)
    }

    private static func runListReminders(
        _ arguments: [String: Any],
        _ repository: any CalendarRepository,
        _ generation: Int,
        requireQuery: Bool
    ) async throws -> [String: Any] {
        if requireQuery, string(arguments["text"]) == nil {
            throw ToolError(code: "invalid_argument", message: "`search_reminders` needs `text`")
        }
        let resolver = CalendarResolver(repository: repository)
        var filter = ReminderFilter()
        filter.calendarIdentifiers = try await resolver.resolveFilter(
            stringArray(arguments["calendar_ids"]), entity: .reminder
        )
        var window: ReminderDueWindow?
        if let raw = string(arguments["due_window"]) {
            guard let parsed = ReminderDueWindow(rawValue: raw) else {
                throw ToolError(
                    code: "invalid_argument",
                    message: "`due_window` must be one of \(ReminderDueWindow.allCases.map(\.rawValue))"
                )
            }
            window = parsed
            // "What's due" means what is still to do, unless the caller asked otherwise.
            if arguments["completion"] == nil { filter.completion = .incomplete }
        }
        if let raw = string(arguments["completion"]) {
            guard let parsed = ReminderFilter.Completion(rawValue: raw) else {
                throw ToolError(
                    code: "invalid_argument",
                    message: "`completion` must be one of \(ReminderFilter.Completion.allCases.map(\.rawValue))"
                )
            }
            filter.completion = parsed
        }
        filter.dueFrom = date(arguments["due_from"])
        filter.dueTo = date(arguments["due_to"])
        filter.completedFrom = date(arguments["completed_from"])
        filter.completedTo = date(arguments["completed_to"])
        filter.includeUndated = bool(arguments["include_undated"]) ?? true
        filter.text = string(arguments["text"])
        filter.searchNotes = bool(arguments["search_notes"]) ?? false
        if let raw = string(arguments["minimum_priority"]) {
            guard let bucket = ReminderPriorityBucket(rawValue: raw), bucket != .none else {
                throw ToolError(code: "invalid_argument", message: "`minimum_priority` must be low, medium, or high")
            }
            filter.minimumPriorityBucket = bucket
        }
        let detail = bool(arguments["include_details"]) ?? false

        var all = try await mapRepositoryError { try await repository.listReminders(filter) }
        if let window {
            let now = Date()
            all = all.filter { window.matches($0.dueDate, now: now) }
        }
        let page = try paginate(all, arguments: arguments, generation: generation)
        let titles = await resolver.titles()
        return envelope(
            data: page.items.map { reminder in
                var row = project(reminder: reminder, detail: detail)
                row["list_title"] = titles[reminder.calendarIdentifier] as Any? ?? NSNull()
                return row
            },
            pagination: paginationBlock(page)
        )
    }

    private static func runGetReminder(
        _ arguments: [String: Any],
        _ repository: any CalendarRepository,
        _ store: Store?
    ) async throws -> [String: Any] {
        guard let id = string(arguments["reminder_id"]) else {
            throw ToolError(code: "invalid_argument", message: "`reminder_id` is required")
        }
        guard let reminder = try await mapRepositoryError({
            try await repository.reminder(withIdentifier: id)
        }) else {
            throw ToolError(code: "not_found", message: "no reminder with identifier \(id)")
        }
        var payload = project(reminder: reminder, detail: true)
        payload["locator"] = locatorHandle(
            for: .reminder, calendarID: reminder.calendarIdentifier,
            sourceID: reminder.sourceIdentifier, identifier: id, recurringOccurrence: nil, store: store
        ) as Any? ?? NSNull()
        return envelope(data: payload)
    }

    // MARK: - Pagination glue

    private static func paginate<Item: Sendable>(
        _ all: [Item], arguments: [String: Any], generation: Int
    ) throws -> Page<Item> {
        let limit = int(arguments["limit"]) ?? 50
        do {
            return try Page(
                all: all, limit: limit, cursor: string(arguments["cursor"]),
                currentGeneration: generation
            )
        } catch PaginationError.malformed {
            throw ToolError(code: "invalid_argument", message: "`cursor` is not a valid cursor")
        } catch PaginationError.stale {
            throw ToolError(
                code: "cursor_stale",
                message: "the calendar store changed since this cursor was issued; re-query from the start"
            )
        }
    }

    private static func paginationBlock<Item>(_ page: Page<Item>) -> [String: Any] {
        [
            "returned": page.items.count,
            "total_matched": page.totalMatched,
            "has_more": page.hasMore,
            "next_cursor": page.nextCursor as Any? ?? NSNull(),
        ]
    }

    // MARK: - Envelope

    static func envelope(
        data: Any, warnings: [String] = [], pagination: [String: Any]? = nil
    ) -> [String: Any] {
        var out: [String: Any] = [
            "schema_version": schemaVersion,
            "as_of": RCCTime.instant(),
            "data": data,
            "warnings": warnings,
        ]
        if let pagination { out["pagination"] = pagination }
        return out
    }

    // MARK: - Projection

    static func project(source: SourceSummary) -> [String: Any] {
        [
            "id": source.id,
            "title": source.title,
            "type": source.sourceType,
            "type_raw": source.sourceTypeRawValue,
            "is_delegate": source.isDelegate,
        ]
    }

    static func project(calendar: CalendarSummary) -> [String: Any] {
        var out: [String: Any] = [
            "id": calendar.id,
            "title": calendar.title,
            "writable": calendar.isWritable,
            "allows_content_modifications": calendar.allowsContentModifications,
            "is_immutable": calendar.isImmutable,
            "is_subscribed": calendar.isSubscribed,
            "allowed_entity_types": calendar.allowedEntityTypes.map(\.rawValue).sorted(),
            "source_id": calendar.sourceIdentifier as Any? ?? NSNull(),
            "source_title": calendar.sourceTitle as Any? ?? NSNull(),
        ]
        if let color = calendar.colorHex { out["color"] = color }
        if let type = calendar.type { out["type"] = enumValue(type) }
        if !calendar.supportedEventAvailabilities.isEmpty {
            out["supported_availabilities"] = calendar.supportedEventAvailabilities
        }
        return out
    }

    static func project(event: EventSummary, detail: Bool) -> [String: Any] {
        var out: [String: Any] = [
            "id": event.id,
            "title": event.title,
            "start": RCCTime.instant(event.start),
            "end": RCCTime.instant(event.end),
            "all_day": event.isAllDay,
            "calendar_id": event.calendarIdentifier,
            "is_recurring": event.isRecurring,
            "version": event.version,
        ]
        if let tz = event.timeZoneIdentifier { out["time_zone"] = tz }
        if event.isAllDay {
            // An all-day event's instants are local midnights, which read as the wrong day
            // in UTC. Its dates are what anyone means by it.
            out["start_date"] = RCCTime.localDay(event.start)
            out["end_date"] = RCCTime.localDay(event.end)
        }
        if let location = event.location { out["location"] = location }
        if let status = event.status { out["status"] = enumValue(status) }
        if let availability = event.availability { out["availability"] = enumValue(availability) }
        if event.isDetached { out["is_detached"] = true }
        if let occurrence = event.occurrenceDate { out["occurrence_date"] = RCCTime.instant(occurrence) }

        guard detail else {
            out["has_notes"] = event.notes?.isEmpty == false
            out["attendee_count"] = event.participants.count
            return out
        }

        if let notes = event.notes { out["notes"] = notes }
        if let url = event.url { out["url"] = url }
        if let geo = event.structuredLocation { out["structured_location"] = project(geo: geo) }
        if !event.recurrenceRules.isEmpty {
            out["recurrence_rules"] = event.recurrenceRules.map(project(recurrence:))
        }
        if !event.alarms.isEmpty { out["alarms"] = event.alarms.map(project(alarm:)) }
        if !event.participants.isEmpty { out["participants"] = event.participants.map(project(participant:)) }
        if let organizer = event.organizer { out["organizer"] = project(participant: organizer) }
        if let birthday = event.birthdayContactIdentifier { out["birthday_contact_id"] = birthday }
        if let created = event.created { out["created"] = RCCTime.instant(created) }
        if let modified = event.lastModified { out["last_modified"] = RCCTime.instant(modified) }
        if let source = event.sourceIdentifier { out["source_id"] = source }
        return out
    }

    static func project(reminder: ReminderSummary, detail: Bool) -> [String: Any] {
        var out: [String: Any] = [
            "id": reminder.id,
            "title": reminder.title,
            "completed": reminder.isCompleted,
            "calendar_id": reminder.calendarIdentifier,
            "priority": reminder.priorityRaw,
            "priority_bucket": reminder.priorityBucket,
            "is_recurring": !reminder.recurrenceRules.isEmpty,
            "version": reminder.version,
        ]
        if let due = reminder.dueDate { out["due"] = project(components: due) }
        if let completion = reminder.completionDate { out["completion_date"] = RCCTime.instant(completion) }

        guard detail else {
            out["has_notes"] = reminder.notes?.isEmpty == false
            return out
        }

        if let start = reminder.startDate { out["start"] = project(components: start) }
        if let notes = reminder.notes { out["notes"] = notes }
        if let url = reminder.url { out["url"] = url }
        if let location = reminder.location { out["location"] = location }
        if let tz = reminder.timeZoneIdentifier { out["time_zone"] = tz }
        if !reminder.recurrenceRules.isEmpty {
            out["recurrence_rules"] = reminder.recurrenceRules.map(project(recurrence:))
        }
        if !reminder.alarms.isEmpty { out["alarms"] = reminder.alarms.map(project(alarm:)) }
        if let created = reminder.created { out["created"] = RCCTime.instant(created) }
        if let modified = reminder.lastModified { out["last_modified"] = RCCTime.instant(modified) }
        if let source = reminder.sourceIdentifier { out["source_id"] = source }
        return out
    }

    static func project(geo: GeoLocation) -> [String: Any] {
        var out: [String: Any] = [:]
        if let title = geo.title { out["title"] = title }
        if let latitude = geo.latitude { out["latitude"] = latitude }
        if let longitude = geo.longitude { out["longitude"] = longitude }
        if let radius = geo.radius { out["radius_meters"] = radius }
        return out
    }

    static func project(participant: Participant) -> [String: Any] {
        var out: [String: Any] = [
            "is_current_user": participant.isCurrentUser,
            "type": enumValue(participant.type),
            "role": enumValue(participant.role),
            "status": enumValue(participant.status),
        ]
        if let name = participant.name { out["name"] = name }
        if let url = participant.url { out["url"] = url }
        if let email = participant.email { out["email"] = email }
        return out
    }

    static func project(alarm: Alarm) -> [String: Any] {
        var out: [String: Any] = ["type": enumValue(alarm.type)]
        if let offset = alarm.relativeOffset { out["relative_offset_seconds"] = offset }
        if let absolute = alarm.absoluteDate { out["absolute_date"] = RCCTime.instant(absolute) }
        if let geo = alarm.structuredLocation { out["structured_location"] = project(geo: geo) }
        if let proximity = alarm.proximity { out["proximity"] = enumValue(proximity) }
        return out
    }

    static func project(recurrence rule: RecurrenceRule) -> [String: Any] {
        var out: [String: Any] = [
            "frequency": rule.frequency.rawValue,
            "interval": rule.interval,
        ]
        if !rule.daysOfWeek.isEmpty {
            out["days_of_week"] = rule.daysOfWeek.map { ["weekday": $0.weekday, "ordinal": $0.ordinal] }
        }
        if !rule.daysOfMonth.isEmpty { out["days_of_month"] = rule.daysOfMonth }
        if !rule.monthsOfYear.isEmpty { out["months_of_year"] = rule.monthsOfYear }
        if !rule.weeksOfYear.isEmpty { out["weeks_of_year"] = rule.weeksOfYear }
        if !rule.daysOfYear.isEmpty { out["days_of_year"] = rule.daysOfYear }
        if !rule.setPositions.isEmpty { out["set_positions"] = rule.setPositions }
        if rule.firstDayOfWeek != 0 { out["first_day_of_week"] = rule.firstDayOfWeek }
        switch rule.end {
        case .never: out["end"] = ["kind": "never"]
        case .onDate(let date): out["end"] = ["kind": "date", "date": RCCTime.instant(date)]
        case .afterOccurrences(let count): out["end"] = ["kind": "count", "count": count]
        }
        return out
    }

    static func project(components: DateComponentsDTO) -> [String: Any] {
        var out: [String: Any] = ["granularity": components.granularity]
        if let year = components.year { out["year"] = year }
        if let month = components.month { out["month"] = month }
        if let day = components.day { out["day"] = day }
        if let hour = components.hour { out["hour"] = hour }
        if let minute = components.minute { out["minute"] = minute }
        if let second = components.second { out["second"] = second }
        if let tz = components.timeZoneIdentifier { out["time_zone"] = tz }
        return out
    }

    /// `2026-10-12`, or `2026-10-12 09:30 America/Vancouver` — for human-readable notes.
    static func describe(components: DateComponentsDTO) -> String {
        var out = String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
        if let hour = components.hour {
            out += String(format: " %02d:%02d", hour, components.minute ?? 0)
            if let zone = components.timeZoneIdentifier { out += " \(zone)" }
        }
        return out
    }

    private static func enumValue(_ value: EnumValue) -> [String: Any] {
        ["name": value.name, "raw": value.raw]
    }

    // MARK: - Argument coercion

    static func string(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    static func bool(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }

    static func int(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        return RCCTime.parse(string)
    }

    static func stringArray(_ value: Any?) -> [String]? {
        guard let array = value as? [Any] else { return nil }
        let strings = array.compactMap { $0 as? String }.filter { !$0.isEmpty }
        return strings.isEmpty ? nil : strings
    }

    private static func optionalEntity(_ value: Any?) throws -> RCCEntityType? {
        guard let raw = string(value) else { return nil }
        guard let entity = RCCEntityType(rawValue: raw) else {
            throw ToolError(code: "invalid_argument", message: "`entity_type` must be 'event' or 'reminder'")
        }
        return entity
    }

    static func mapRepositoryError<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as CalendarRepositoryError {
            throw ToolError(code: error.code, message: error.description, native: error.nativeError)
        }
    }
}

/// A read-tool failure carrying a stable SPEC §10.1 code. `MCPServer` renders it as a
/// successful tool result with `isError: true`.
public struct ToolError: Error {
    public let code: String
    public let message: String
    /// EventKit's own domain/code, surfaced verbatim where we have it (SPEC §10.1).
    public let nativeDomain: String?
    public let nativeCode: Int?
    /// For `ambiguous_target`: what the caller could have meant (SPEC §10).
    public let candidates: [[String: String]]

    public init(
        code: String, message: String, native: [String: Any]? = nil,
        candidates: [[String: String]] = []
    ) {
        self.code = code
        self.message = message
        self.nativeDomain = native?["domain"] as? String
        self.nativeCode = native?["code"] as? Int
        self.candidates = candidates
    }

    public var payload: [String: Any] {
        var out: [String: Any] = ["error": message, "code": code, "retryable": Self.retryable(code)]
        if let nativeDomain, let nativeCode {
            out["native_error"] = ["domain": nativeDomain, "code": nativeCode]
        }
        if !candidates.isEmpty { out["candidates"] = candidates }
        return out
    }

    private static func retryable(_ code: String) -> Bool {
        ["timeout", "provider_unavailable", "cursor_stale", "conflict"].contains(code)
    }
}
