import Foundation
import RCCCore

/// The tool-owned test calendar and reminder list `rcc setup --dev` provisions (SPEC §15).
///
/// Its whole purpose is a safety boundary: destructive tests, and Milestone 1's read/write
/// proof, operate *only* on a calendar whose identifier `rcc` recorded when it created it.
/// Anything else is refused outright, so a mistyped identifier can never delete a real
/// calendar.
public struct DevFixtureManager: Sendable {
    /// Prefix for provisioned fixtures. Recognisable at a glance in Calendar.app, and
    /// unmistakably not something the user made.
    public static let titlePrefix = "RCC Dev"

    private let repository: any CalendarRepository
    private let store: Store

    public init(repository: any CalendarRepository, store: Store) {
        self.repository = repository
        self.store = store
    }

    /// Return the recorded fixture, creating it if absent.
    ///
    /// A recorded fixture whose calendar has since disappeared — the user deleted it in
    /// Calendar.app, or a full account sync invalidated the identifier (SPEC §9.4) — is
    /// treated as absent and re-provisioned, with the stale record replaced.
    @discardableResult
    public func provision(_ entityType: RCCEntityType) async throws -> Store.DevFixture {
        if let existing = try store.devFixture(entityType.fixtureEntityType),
           let calendar = try await repository.calendar(withIdentifier: existing.calendarID, entityType: entityType) {
            Log.shared.debug("devfixture.reused", [
                "entity": .safe(entityType.rawValue),
                "calendar": .safe(calendar.id),
            ])
            return existing
        }

        let source = try await preferredSource(for: entityType)
        // Suffixed so two provisions never collide, and so `create_event`'s
        // duplicate-display-name rule (SPEC §10) is never tripped by our own fixture.
        let title = "\(Self.titlePrefix) \(entityType.rawValue)s \(Self.shortToken())"
        let calendar = try await repository.createCalendar(
            title: title,
            entityType: entityType,
            sourceIdentifier: source.id
        )

        let fixture = Store.DevFixture(
            entityType: entityType.fixtureEntityType,
            calendarID: calendar.id,
            title: calendar.title,
            sourceID: calendar.sourceIdentifier,
            sourceTitle: calendar.sourceTitle,
            createdAt: RCCTime.instant()
        )
        try store.recordDevFixture(fixture)
        Log.shared.info("devfixture.created", [
            "entity": .safe(entityType.rawValue),
            "calendar": .safe(calendar.id),
            "source": .safe(calendar.sourceTitle ?? "unknown"),
        ])
        return fixture
    }

    /// The recorded fixture, or `nil`. Never creates anything — safe for `rcc doctor`.
    public func recorded(_ entityType: RCCEntityType) throws -> Store.DevFixture? {
        try store.devFixture(entityType.fixtureEntityType)
    }

    /// Delete the fixture calendar, refusing anything `rcc` did not create.
    public func remove(_ entityType: RCCEntityType) async throws {
        guard let fixture = try store.devFixture(entityType.fixtureEntityType) else { return }
        try assertOwned(fixture.calendarID, entityType: entityType)
        try await repository.deleteCalendar(identifier: fixture.calendarID, entityType: entityType)
        try store.removeDevFixture(entityType.fixtureEntityType)
        Log.shared.info("devfixture.removed", [
            "entity": .safe(entityType.rawValue),
            "calendar": .safe(fixture.calendarID),
        ])
    }

    /// Refuse to touch a calendar that is not the recorded fixture.
    public func assertOwned(_ calendarIdentifier: String, entityType: RCCEntityType) throws {
        guard let fixture = try store.devFixture(entityType.fixtureEntityType) else {
            throw RCCError(
                .validation,
                "No \(entityType.rawValue) dev fixture is recorded, so rcc will not write to any calendar.",
                remediation: "Run `rcc setup --dev` first."
            )
        }
        guard fixture.calendarID == calendarIdentifier else {
            throw RCCError(
                .validation,
                "Calendar \(calendarIdentifier) is not rcc's dev fixture; refusing to modify it.",
                remediation: "The recorded fixture is \(fixture.calendarID) (\"\(fixture.title)\")."
            )
        }
    }

    // MARK: - Read/write proof

    public struct RoundTrip: Sendable, Equatable {
        public let entityType: RCCEntityType
        public let calendarID: String
        public let calendarTitle: String
        public let createdIdentifier: String
        public let readBack: Bool
        public let deleted: Bool

        public var facts: [String: String] {
            [
                "calendar_id": calendarID,
                "calendar_title": calendarTitle,
                "created": createdIdentifier,
                "read_back": readBack ? "true" : "false",
                "deleted": deleted ? "true" : "false",
            ]
        }
    }

    /// Create one item in the fixture, read it back, then delete it.
    ///
    /// This is Milestone 1's actual acceptance evidence: it proves the TCC grant is real
    /// and *writable* from whichever launch context invoked it, not merely that
    /// `authorizationStatus` reads `fullAccess`. It cleans up after itself so it can run
    /// from Terminal, from Claude Desktop, and from the LaunchAgent in a single pass.
    public func roundTrip(_ entityType: RCCEntityType, now: Date = Date()) async throws -> RoundTrip {
        let fixture = try await provision(entityType)
        try assertOwned(fixture.calendarID, entityType: entityType)

        let title = "rcc selftest \(Self.shortToken())"
        let identifier: String
        let readBack: Bool

        switch entityType {
        case .event:
            // An hour, an hour from now: far enough from a day boundary that a DST
            // transition or an all-day-event edge case cannot make the read-back flaky.
            let start = now.addingTimeInterval(3600)
            let end = start.addingTimeInterval(3600)
            identifier = try await repository.createEvent(
                EventDraft(
                    calendarIdentifier: fixture.calendarID,
                    title: title,
                    start: start,
                    end: end,
                    notes: "Created by `rcc selftest`. Safe to delete."
                )
            )
            let found = try await repository.events(
                inCalendar: fixture.calendarID,
                from: now,
                to: now.addingTimeInterval(24 * 3600)
            )
            readBack = found.contains { $0.id == identifier }

        case .reminder:
            identifier = try await repository.createReminder(
                ReminderDraft(
                    calendarIdentifier: fixture.calendarID,
                    title: title,
                    notes: "Created by `rcc selftest`. Safe to delete."
                )
            )
            let found = try await repository.reminders(inCalendar: fixture.calendarID)
            readBack = found.contains { $0.id == identifier }
        }

        var deleted = false
        do {
            switch entityType {
            case .event: try await repository.deleteEvent(identifier: identifier)
            case .reminder: try await repository.deleteReminder(identifier: identifier)
            }
            deleted = true
        } catch {
            // Report the failed cleanup rather than masking a successful write behind it —
            // a leftover item in a fixture calendar is untidy, not dangerous.
            Log.shared.warn("devfixture.cleanup_failed", [
                "entity": .safe(entityType.rawValue),
                "error": .safe(String(describing: error)),
            ])
        }

        return RoundTrip(
            entityType: entityType,
            calendarID: fixture.calendarID,
            calendarTitle: fixture.title,
            createdIdentifier: identifier,
            readBack: readBack,
            deleted: deleted
        )
    }

    // MARK: - Helpers

    /// `preferredSource` is specific to the real adapter; the fake picks the first source
    /// that exists. Kept behind this shim so the fixture logic stays testable.
    private func preferredSource(for entityType: RCCEntityType) async throws -> SourceSummary {
        if let eventKit = repository as? EventKitRepository {
            return try await eventKit.preferredSource(for: entityType)
        }
        let sources = try await repository.sources()
        guard let first = sources.first else {
            throw CalendarRepositoryError.notFound("any EventKit source")
        }
        return first
    }

    static func shortToken() -> String {
        String(UUID().uuidString.prefix(8)).lowercased()
    }
}

extension RCCEntityType {
    public var fixtureEntityType: Store.DevFixture.EntityType {
        switch self {
        case .event: return .event
        case .reminder: return .reminder
        }
    }
}
