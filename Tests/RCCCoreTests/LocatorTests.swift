import Foundation
import Testing

@testable import RCCCore

@Suite("Locators")
struct LocatorTests {
    private func store() throws -> Store {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rcc-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try Store(url: directory.appendingPathComponent("state.sqlite3", isDirectory: false))
    }

    @Test("A handle is opaque: 40 hex chars, no structure, unique per issue")
    func handleShape() throws {
        let store = try store()
        var seen = Set<String>()
        for _ in 0..<50 {
            let locator = try store.issueLocator(
                entityType: "event", calendarID: "cal", sourceID: "src", itemIdentifier: "EK-1"
            )
            #expect(locator.handle.count == 40)
            #expect(locator.handle.allSatisfy { $0.isHexDigit && !$0.isUppercase })
            #expect(seen.insert(locator.handle).inserted)
            // Nothing in the handle should echo the fields it stands for.
            #expect(!locator.handle.contains("cal"))
            #expect(!locator.handle.contains("EK-1"))
        }
    }

    @Test("A freshly issued handle resolves with every field intact")
    func resolveOk() throws {
        let store = try store()
        let issued = try store.issueLocator(
            entityType: "event", calendarID: "cal-7", sourceID: "src-1",
            itemIdentifier: "EK-42", externalID: "ext-9",
            occurrenceDate: "2026-09-10T09:00:00.000Z"
        )
        guard case .ok(let resolved) = try store.resolveLocator(issued.handle) else {
            Issue.record("expected .ok"); return
        }
        #expect(resolved == issued)
        #expect(resolved.isRecurringOccurrence)
    }

    @Test("An unknown handle resolves to .unknown, not a crash")
    func resolveUnknown() throws {
        let store = try store()
        #expect(try store.resolveLocator("deadbeef") == .unknown)
    }

    @Test("A handle past its TTL resolves to .expired")
    func resolveExpired() throws {
        let store = try store()
        let issued = try store.issueLocator(
            entityType: "reminder", calendarID: "cal", sourceID: nil, itemIdentifier: "EK-1",
            ttl: 60, now: Date(timeIntervalSince1970: 1_000_000)
        )
        // 61 seconds later.
        let later = Date(timeIntervalSince1970: 1_000_061)
        #expect(try store.resolveLocator(issued.handle, now: later) == .expired)
    }

    @Test("invalidateAllLocators bumps the generation; a prior handle still resolves but is not current")
    func generationBump() throws {
        let store = try store()
        let before = try store.issueLocator(
            entityType: "event", calendarID: "cal", sourceID: nil, itemIdentifier: "EK-1"
        )
        #expect(try store.isLocatorCurrent(before))

        try store.invalidateAllLocators()

        // The handle still resolves — generation staleness is a mutation-time `if_match`
        // concern, not a "wrong handle" one — but it is no longer current.
        let resolved = try #require(try store.resolveLocator(before.handle).locator)
        #expect(resolved.itemIdentifier == "EK-1")
        #expect(try store.isLocatorCurrent(resolved) == false)

        let after = try store.issueLocator(
            entityType: "event", calendarID: "cal", sourceID: nil, itemIdentifier: "EK-2"
        )
        #expect(try store.isLocatorCurrent(after))
        #expect(after.generation == before.generation + 1)
    }

    @Test("Pruning clears expired and superseded-generation rows")
    func pruning() throws {
        let store = try store()
        let t0 = Date(timeIntervalSince1970: 2_000_000)

        let expiring = try store.issueLocator(
            entityType: "event", calendarID: "c", sourceID: nil, itemIdentifier: "EK-1",
            ttl: 10, now: t0
        )
        let live = try store.issueLocator(
            entityType: "event", calendarID: "c", sourceID: nil, itemIdentifier: "EK-2",
            ttl: 3600, now: t0
        )
        try store.invalidateAllLocators()  // sends both to a superseded generation
        let fresh = try store.issueLocator(
            entityType: "event", calendarID: "c", sourceID: nil, itemIdentifier: "EK-3",
            ttl: 3600, now: t0
        )

        let at = t0.addingTimeInterval(20)
        let removed = try store.pruneExpiredLocators(now: at)
        #expect(removed == 2)  // expiring (aged out) + live (stale generation)
        #expect(try store.resolveLocator(expiring.handle, now: at) == .unknown)
        #expect(try store.resolveLocator(live.handle, now: at) == .unknown)
        #expect(try store.resolveLocator(fresh.handle, now: at).locator != nil)
    }

    @Test("Generation and locators persist across a reopen")
    func durableAcrossReopen() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rcc-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("state.sqlite3", isDirectory: false)

        let handle: String
        do {
            let store = try Store(url: url)
            try store.invalidateAllLocators()
            try store.invalidateAllLocators()
            handle = try store.issueLocator(
                entityType: "event", calendarID: "c", sourceID: nil, itemIdentifier: "EK-1"
            ).handle
        }
        let reopened = try Store(url: url)
        #expect(try reopened.currentLocatorGeneration() == 2)
        #expect(try reopened.resolveLocator(handle).locator != nil)
    }
}
