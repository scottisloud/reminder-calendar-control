import Foundation
import SQLite3

/// SQLite-backed durable state (SPEC §7.4).
///
/// Milestone 1 only needs install metadata and the dev-fixture record, but the store is
/// introduced now — with WAL and a `schema_version` from the first migration — because
/// the spec requires durable state to live here from day one and retrofitting a
/// migration path onto a JSON file later is strictly worse.
///
/// Opened with `SQLITE_OPEN_FULLMUTEX`, so the underlying handle serialises access
/// itself; the only Swift-level state is the handle, assigned once at init. That is what
/// makes the `@unchecked Sendable` conformance honest rather than a shrug.
public final class Store: @unchecked Sendable {
    /// Bump this and append to `migrations` for every schema change. Never edit an
    /// existing migration — a released binary has already applied it.
    public static let currentSchemaVersion = 1

    private let handle: OpaquePointer
    public let url: URL

    public init(url: URL = RCCPaths.databaseFile) throws {
        self.url = url

        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        // SQLite honours the process umask when it creates the database and its `-wal`
        // and `-shm` sidecars, and there is no API to pass it a mode. Tightening the umask
        // around the open is the only way to get 0600 on all three at creation time rather
        // than in a racy chmod afterwards (SPEC §13).
        let previousMask = umask(0o077)
        defer { umask(previousMask) }

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close_v2(db)
            throw RCCError(.state, "Could not open state database at \(url.path): \(message)")
        }
        self.handle = db

        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA foreign_keys=ON;")
        try execute("PRAGMA busy_timeout=5000;")
        try migrate()
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    // MARK: - Migrations

    /// Index in this array + 1 is the schema version it produces.
    private static let migrations: [String] = [
        """
        CREATE TABLE IF NOT EXISTS install_metadata (
            id                INTEGER PRIMARY KEY CHECK (id = 1),
            installed_at      TEXT NOT NULL,
            version           TEXT NOT NULL,
            binary_path       TEXT NOT NULL,
            signing_identity  TEXT,
            cdhash            TEXT
        );

        CREATE TABLE IF NOT EXISTS dev_fixture (
            entity_type       TEXT PRIMARY KEY CHECK (entity_type IN ('event', 'reminder')),
            calendar_id       TEXT NOT NULL,
            title             TEXT NOT NULL,
            source_id         TEXT,
            source_title      TEXT,
            created_at        TEXT NOT NULL
        );
        """
    ]

    private func migrate() throws {
        var version = try userVersion()
        guard version <= Self.currentSchemaVersion else {
            throw RCCError(
                .state,
                "State database is at schema version \(version), but this build of rcc only "
                    + "understands version \(Self.currentSchemaVersion).",
                remediation: "Install the newer rcc build, or move \(url.path) aside to start fresh. "
                    + "Downgrade migration is deliberately refused rather than guessed at."
            )
        }
        while version < Self.currentSchemaVersion {
            try execute("BEGIN IMMEDIATE;")
            do {
                try execute(Self.migrations[version])
                try execute("PRAGMA user_version=\(version + 1);")
                try execute("COMMIT;")
            } catch {
                try? execute("ROLLBACK;")
                throw error
            }
            version += 1
        }
    }

    private func userVersion() throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK else {
            throw lastError("reading schema version")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    // MARK: - Records

    public struct InstallMetadata: Sendable, Equatable {
        public let installedAt: String
        public let version: String
        public let binaryPath: String
        public let signingIdentity: String?
        public let cdhash: String?

        public init(installedAt: String, version: String, binaryPath: String,
                    signingIdentity: String?, cdhash: String?) {
            self.installedAt = installedAt
            self.version = version
            self.binaryPath = binaryPath
            self.signingIdentity = signingIdentity
            self.cdhash = cdhash
        }
    }

    public func recordInstall(_ metadata: InstallMetadata) throws {
        try run(
            """
            INSERT INTO install_metadata (id, installed_at, version, binary_path, signing_identity, cdhash)
            VALUES (1, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                installed_at = excluded.installed_at,
                version = excluded.version,
                binary_path = excluded.binary_path,
                signing_identity = excluded.signing_identity,
                cdhash = excluded.cdhash;
            """,
            [metadata.installedAt, metadata.version, metadata.binaryPath,
             metadata.signingIdentity, metadata.cdhash]
        )
    }

    public func installMetadata() throws -> InstallMetadata? {
        try queryOne(
            "SELECT installed_at, version, binary_path, signing_identity, cdhash FROM install_metadata WHERE id = 1;"
        ) { statement in
            InstallMetadata(
                installedAt: Self.text(statement, 0) ?? "",
                version: Self.text(statement, 1) ?? "",
                binaryPath: Self.text(statement, 2) ?? "",
                signingIdentity: Self.text(statement, 3),
                cdhash: Self.text(statement, 4)
            )
        }
    }

    /// The tool-owned test calendar / reminder list provisioned by `rcc setup --dev`.
    ///
    /// Recording these is what lets destructive tests assert "this fixture is mine"
    /// before touching anything (SPEC §15).
    public struct DevFixture: Sendable, Equatable {
        public enum EntityType: String, Sendable { case event, reminder }

        public let entityType: EntityType
        public let calendarID: String
        public let title: String
        public let sourceID: String?
        public let sourceTitle: String?
        public let createdAt: String

        public init(entityType: EntityType, calendarID: String, title: String,
                    sourceID: String?, sourceTitle: String?, createdAt: String) {
            self.entityType = entityType
            self.calendarID = calendarID
            self.title = title
            self.sourceID = sourceID
            self.sourceTitle = sourceTitle
            self.createdAt = createdAt
        }
    }

    public func recordDevFixture(_ fixture: DevFixture) throws {
        try run(
            """
            INSERT INTO dev_fixture (entity_type, calendar_id, title, source_id, source_title, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(entity_type) DO UPDATE SET
                calendar_id = excluded.calendar_id,
                title = excluded.title,
                source_id = excluded.source_id,
                source_title = excluded.source_title,
                created_at = excluded.created_at;
            """,
            [fixture.entityType.rawValue, fixture.calendarID, fixture.title,
             fixture.sourceID, fixture.sourceTitle, fixture.createdAt]
        )
    }

    public func devFixture(_ entityType: DevFixture.EntityType) throws -> DevFixture? {
        try queryOne(
            """
            SELECT calendar_id, title, source_id, source_title, created_at
            FROM dev_fixture WHERE entity_type = '\(entityType.rawValue)';
            """
        ) { statement in
            DevFixture(
                entityType: entityType,
                calendarID: Self.text(statement, 0) ?? "",
                title: Self.text(statement, 1) ?? "",
                sourceID: Self.text(statement, 2),
                sourceTitle: Self.text(statement, 3),
                createdAt: Self.text(statement, 4) ?? ""
            )
        }
    }

    public func removeDevFixture(_ entityType: DevFixture.EntityType) throws {
        try run("DELETE FROM dev_fixture WHERE entity_type = ?;", [entityType.rawValue])
    }

    // MARK: - Primitives

    public func execute(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorPointer)
            throw RCCError(.state, "SQLite error: \(message)")
        }
    }

    public func run(_ sql: String, _ parameters: [String?]) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError("preparing statement")
        }
        defer { sqlite3_finalize(statement) }
        try bind(parameters, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError("executing statement")
        }
    }

    private func queryOne<T>(_ sql: String, _ decode: (OpaquePointer) -> T) throws -> T? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError("preparing query")
        }
        defer { sqlite3_finalize(statement) }
        guard let statement, sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return decode(statement)
    }

    private func bind(_ parameters: [String?], to statement: OpaquePointer?) throws {
        // SQLITE_TRANSIENT: sqlite must copy the bytes, because the Swift String's
        // storage is not guaranteed to outlive this call.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, parameter) in parameters.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            if let parameter {
                status = sqlite3_bind_text(statement, index, parameter, -1, transient)
            } else {
                status = sqlite3_bind_null(statement, index)
            }
            guard status == SQLITE_OK else { throw lastError("binding parameter \(index)") }
        }
    }

    private static func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let raw = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: raw)
    }

    private func lastError(_ context: String) -> RCCError {
        RCCError(.state, "SQLite error while \(context): \(String(cString: sqlite3_errmsg(handle)))")
    }
}
