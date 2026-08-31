import Foundation
import Testing

@testable import RCCCore

@Suite("Store")
struct StoreTests {
    /// Each test gets its own database in a temp directory; nothing here ever touches the
    /// real state path.
    private func temporaryStoreURL() -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rcc-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("state.sqlite3", isDirectory: false)
    }

    @Test("A fresh database lands on the current schema version")
    func migratesToCurrentVersion() throws {
        let url = temporaryStoreURL()
        _ = try Store(url: url)
        // Reopening must be a no-op, not a re-run of the migrations.
        _ = try Store(url: url)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("The database and its WAL sidecars are 0600 even under a permissive umask")
    func restrictsPermissions() throws {
        let previous = umask(0o000)
        defer { umask(previous) }

        let url = temporaryStoreURL()
        let store = try Store(url: url)
        // Force the WAL sidecars into existence.
        try store.recordInstall(
            Store.InstallMetadata(
                installedAt: "now", version: "0", binaryPath: "/x", signingIdentity: nil, cdhash: nil
            )
        )

        for suffix in ["", "-wal", "-shm"] {
            let path = url.path + suffix
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let mode = try #require(
                FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
            )
            #expect(mode.intValue == 0o600, "\(path) is \(String(mode.intValue, radix: 8))")
        }
    }

    @Test("Install metadata round-trips and upserts")
    func installMetadataRoundTrip() throws {
        let store = try Store(url: temporaryStoreURL())
        #expect(try store.installMetadata() == nil)

        let first = Store.InstallMetadata(
            installedAt: "2026-08-31T12:00:00.000Z",
            version: "0.1.0",
            binaryPath: "/tmp/rcc",
            signingIdentity: "ad-hoc",
            cdhash: "aaaa"
        )
        try store.recordInstall(first)
        #expect(try store.installMetadata() == first)

        let second = Store.InstallMetadata(
            installedAt: "2026-09-01T12:00:00.000Z",
            version: "0.2.0",
            binaryPath: "/tmp/rcc",
            signingIdentity: "Developer ID Application: Someone (TEAM)",
            cdhash: "bbbb"
        )
        try store.recordInstall(second)
        #expect(try store.installMetadata() == second)
    }

    @Test("Dev fixtures round-trip per entity type and do not collide")
    func devFixtureRoundTrip() throws {
        let store = try Store(url: temporaryStoreURL())
        #expect(try store.devFixture(.event) == nil)

        let event = Store.DevFixture(
            entityType: .event, calendarID: "cal-1", title: "RCC Dev events",
            sourceID: "src", sourceTitle: "On My Mac", createdAt: "now"
        )
        let reminder = Store.DevFixture(
            entityType: .reminder, calendarID: "cal-2", title: "RCC Dev reminders",
            sourceID: "src", sourceTitle: "On My Mac", createdAt: "now"
        )
        try store.recordDevFixture(event)
        try store.recordDevFixture(reminder)

        #expect(try store.devFixture(.event) == event)
        #expect(try store.devFixture(.reminder) == reminder)

        try store.removeDevFixture(.event)
        #expect(try store.devFixture(.event) == nil)
        #expect(try store.devFixture(.reminder) == reminder)
    }

    @Test("A database from a newer build is refused, not silently downgraded")
    func refusesFutureSchema() throws {
        let url = temporaryStoreURL()
        let store = try Store(url: url)
        try store.execute("PRAGMA user_version=9999;")

        #expect(throws: RCCError.self) {
            _ = try Store(url: url)
        }
    }
}
