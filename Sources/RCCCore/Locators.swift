import Foundation

/// A server-issued handle for a mutation target (SPEC §9.4).
///
/// EventKit's own identifiers are not durable — a full account sync can invalidate
/// `calendarItemIdentifier`, `eventIdentifier` changes when an event moves calendars, and
/// even `calendarIdentifier` can change. A locator is `rcc`'s stable-for-a-while handle:
/// an opaque random string whose row records everything needed to re-resolve the target,
/// plus the era (`generation`) it was issued in and an expiry.
public struct Locator: Sendable, Equatable {
    public let handle: String
    public let entityType: String
    public let calendarID: String
    public let sourceID: String?
    /// The EventKit identifier at issue time — a *hint* for re-resolution, never trusted
    /// alone for a recurring item.
    public let itemIdentifier: String
    public let externalID: String?
    /// For one occurrence of a recurring series: the occurrence's start instant.
    public let occurrenceDate: String?
    public let generation: Int64
    public let issuedAt: String
    public let expiresAt: String

    public var isRecurringOccurrence: Bool { occurrenceDate != nil }
}

/// The outcome of resolving a handle. Only `.ok` carries a usable locator.
///
/// A handle from an older generation still resolves `.ok` — the generation counter is for
/// pagination `cursor_stale` (SPEC §10), not for mutation targets. A mutation target's
/// staleness is caught by `if_match` on the item's `version`; the executor additionally
/// requires an `if_match` when the handle predates a store change (`Locator.isCurrent`).
public enum LocatorResolution: Sendable, Equatable {
    case ok(Locator)
    case unknown  // never issued, or already pruned
    case expired  // past its TTL

    public var locator: Locator? {
        if case .ok(let locator) = self { return locator }
        return nil
    }
}

extension Store {
    private static let locatorGenerationKey = "locator_generation"

    /// Default locator lifetime. Long enough for a chat turn or an automation firing,
    /// short enough that a handle can't be replayed days later against a changed store.
    public static let defaultLocatorTTL: TimeInterval = 15 * 60

    public func currentLocatorGeneration() throws -> Int64 {
        try queryFirst(
            "SELECT value FROM meta WHERE key = ?;", [.text(Self.locatorGenerationKey)]
        ) { Int64($0.text(0) ?? "0") ?? 0 } ?? 0
    }

    /// Bump the generation so every handle issued before now is dead on the next resolve.
    /// Deliberately lazy — it does not delete rows — so it is cheap to call on every
    /// `EKEventStoreChanged` notification. `pruneExpiredLocators` clears the corpses.
    public func invalidateAllLocators() throws {
        try run(
            """
            UPDATE meta SET value = CAST(CAST(value AS INTEGER) + 1 AS TEXT)
            WHERE key = ?;
            """,
            [.text(Self.locatorGenerationKey)]
        )
    }

    public func issueLocator(
        entityType: String,
        calendarID: String,
        sourceID: String?,
        itemIdentifier: String,
        externalID: String? = nil,
        occurrenceDate: String? = nil,
        ttl: TimeInterval = Store.defaultLocatorTTL,
        now: Date = Date()
    ) throws -> Locator {
        let generation = try currentLocatorGeneration()
        let locator = Locator(
            handle: RCCID.locatorHandle(),
            entityType: entityType,
            calendarID: calendarID,
            sourceID: sourceID,
            itemIdentifier: itemIdentifier,
            externalID: externalID,
            occurrenceDate: occurrenceDate,
            generation: generation,
            issuedAt: RCCTime.instant(now),
            expiresAt: RCCTime.instant(now.addingTimeInterval(ttl))
        )
        func optional(_ value: String?) -> Store.SQLValue { value.map(Store.SQLValue.text) ?? .null }
        let values: [Store.SQLValue] = [
            .text(locator.handle),
            .text(locator.entityType),
            .text(locator.calendarID),
            optional(locator.sourceID),
            .text(locator.itemIdentifier),
            optional(locator.externalID),
            optional(locator.occurrenceDate),
            .int(locator.generation),
            .text(locator.issuedAt),
            .text(locator.expiresAt),
            .int(Store.currentSchemaVersion),
        ]
        try run(
            """
            INSERT INTO locators
                (handle, entity_type, calendar_id, source_id, item_identifier, external_id,
                 occurrence_date, generation, issued_at, expires_at, schema_version)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            values
        )
        return locator
    }

    public func resolveLocator(_ handle: String, now: Date = Date()) throws -> LocatorResolution {
        guard let locator = try queryFirst(
            """
            SELECT handle, entity_type, calendar_id, source_id, item_identifier, external_id,
                   occurrence_date, generation, issued_at, expires_at
            FROM locators WHERE handle = ?;
            """,
            [.text(handle)],
            Self.decodeLocator
        ) else {
            return .unknown
        }
        if let expiry = RCCTime.parse(locator.expiresAt), expiry <= now {
            return .expired
        }
        return .ok(locator)
    }

    /// Whether `locator` was issued in the current generation — i.e. no external calendar
    /// change has happened since. The executor uses this to insist on an `if_match` for a
    /// handle that predates a store change (SPEC §9.4).
    public func isLocatorCurrent(_ locator: Locator) throws -> Bool {
        try locator.generation >= currentLocatorGeneration()
    }

    /// Delete locators that are expired or from a superseded generation.
    @discardableResult
    public func pruneExpiredLocators(now: Date = Date()) throws -> Int {
        let generation = try currentLocatorGeneration()
        try run(
            "DELETE FROM locators WHERE expires_at <= ? OR generation < ?;",
            [.text(RCCTime.instant(now)), .int(generation)]
        )
        return changes()
    }

    private static func decodeLocator(_ row: Store.Row) -> Locator {
        Locator(
            handle: row.text(0) ?? "",
            entityType: row.text(1) ?? "",
            calendarID: row.text(2) ?? "",
            sourceID: row.text(3),
            itemIdentifier: row.text(4) ?? "",
            externalID: row.text(5),
            occurrenceDate: row.text(6),
            generation: row.int(7),
            issuedAt: row.text(8) ?? "",
            expiresAt: row.text(9) ?? ""
        )
    }
}
