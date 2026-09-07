import Foundation
import Testing

@testable import RCCCalendar
@testable import RCCCore

@Suite("Dev fixture")
struct DevFixtureTests {
    private func makeStore() throws -> Store {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rcc-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try Store(url: directory.appendingPathComponent("state.sqlite3", isDirectory: false))
    }

    private func makeRepository() -> InMemoryCalendarRepository {
        InMemoryCalendarRepository(scenario: .init(eventStatus: .fullAccess, reminderStatus: .fullAccess))
    }

    @Test("Provisioning creates a calendar and records it")
    func provisions() async throws {
        let store = try makeStore()
        let manager = DevFixtureManager(repository: makeRepository(), store: store)

        let fixture = try await manager.provision(.event)
        #expect(fixture.title.hasPrefix(DevFixtureManager.titlePrefix))
        #expect(try store.devFixture(.event)?.calendarID == fixture.calendarID)
    }

    @Test("Provisioning twice reuses the same calendar")
    func provisionIsIdempotent() async throws {
        let store = try makeStore()
        let repository = makeRepository()
        let manager = DevFixtureManager(repository: repository, store: store)

        let first = try await manager.provision(.reminder)
        let second = try await manager.provision(.reminder)
        #expect(first.calendarID == second.calendarID)
        #expect(try await repository.calendars(for: .reminder).count == 1)
    }

    /// A recorded fixture whose calendar has since been deleted — by the user, or by a full
    /// account sync invalidating the identifier (SPEC §9.4) — must be re-provisioned rather
    /// than treated as fatal.
    @Test("A vanished calendar is re-provisioned and the stale record replaced")
    func reprovisionsAfterCalendarVanishes() async throws {
        let store = try makeStore()
        let repository = makeRepository()
        let manager = DevFixtureManager(repository: repository, store: store)

        let first = try await manager.provision(.event)
        try await repository.deleteCalendar(identifier: first.calendarID, entityType: .event)

        let second = try await manager.provision(.event)
        #expect(second.calendarID != first.calendarID)
        #expect(try store.devFixture(.event)?.calendarID == second.calendarID)
    }

    /// The safety boundary: destructive test code may only ever touch a calendar rcc itself
    /// created and recorded.
    @Test("Any calendar that is not the recorded fixture is refused")
    func refusesForeignCalendars() async throws {
        let store = try makeStore()
        let manager = DevFixtureManager(repository: makeRepository(), store: store)

        // Nothing recorded at all.
        #expect(throws: RCCError.self) {
            try manager.assertOwned("someone-elses-calendar", entityType: .event)
        }

        let fixture = try await manager.provision(.event)
        try manager.assertOwned(fixture.calendarID, entityType: .event)
        #expect(throws: RCCError.self) {
            try manager.assertOwned("someone-elses-calendar", entityType: .event)
        }
    }

    @Test("A round trip writes, reads back, and cleans up")
    func roundTripSucceeds() async throws {
        let store = try makeStore()
        let repository = makeRepository()
        let manager = DevFixtureManager(repository: repository, store: store)

        for entityType in RCCEntityType.allCases {
            let trip = try await manager.roundTrip(entityType)
            #expect(trip.readBack)
            #expect(trip.deleted)
            #expect(trip.entityType == entityType)
        }
        // Nothing is left behind in the fixture calendars.
        let eventFixture = try #require(try store.devFixture(.event))
        let now = Date()
        #expect(try await repository.events(
            inCalendar: eventFixture.calendarID, from: now.addingTimeInterval(-86400),
            to: now.addingTimeInterval(86400)
        ).isEmpty)
    }

    @Test("A failed write surfaces rather than being reported as a pass")
    func surfacesWriteFailure() async throws {
        let store = try makeStore()
        let repository = makeRepository()
        let manager = DevFixtureManager(repository: repository, store: store)
        _ = try await manager.provision(.event)

        await repository.setScenario(
            .init(
                eventStatus: .fullAccess, reminderStatus: .fullAccess,
                nextWriteFailure: .readOnly("injected")
            )
        )
        await #expect(throws: CalendarRepositoryError.self) {
            _ = try await manager.roundTrip(.event)
        }
    }

    @Test("Removing a fixture deletes the calendar and clears the record")
    func removesFixture() async throws {
        let store = try makeStore()
        let repository = makeRepository()
        let manager = DevFixtureManager(repository: repository, store: store)

        let fixture = try await manager.provision(.reminder)
        try await manager.remove(.reminder)
        #expect(try store.devFixture(.reminder) == nil)
        #expect(try await repository.calendar(withIdentifier: fixture.calendarID, entityType: .reminder) == nil)
        // Removing again is a no-op, not an error.
        try await manager.remove(.reminder)
    }
}
