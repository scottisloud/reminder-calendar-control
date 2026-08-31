import Foundation
import RCCCore

/// Registers `rcc serve` in Claude Desktop's `claude_desktop_config.json` (SPEC §6.1).
///
/// The file belongs to another application and routinely contains the user's other MCP
/// servers, including ones holding credentials in `env`. Three rules follow from that:
///
/// * **Never rewrite what we did not author.** Unknown top-level keys and sibling
///   `mcpServers` entries are round-tripped untouched.
/// * **Never clobber a file we could not parse.** Malformed JSON is a hard error with a
///   pointer to the file, not an excuse to start fresh.
/// * **Never leave it half-written.** Write to a temp file in the same directory and
///   `rename()` over the original, the same atomicity rule the binary install uses.
public enum ClaudeDesktopConfig {
    public struct ServerEntry: Equatable {
        public let command: String
        public let args: [String]
        public let env: [String: String]

        public init(command: String, args: [String] = [], env: [String: String] = [:]) {
            self.command = command
            self.args = args
            self.env = env
        }

        public var jsonObject: [String: Any] {
            var object: [String: Any] = ["command": command]
            if !args.isEmpty { object["args"] = args }
            if !env.isEmpty { object["env"] = env }
            return object
        }

        public static func fromJSON(_ raw: Any?) -> ServerEntry? {
            guard let object = raw as? [String: Any],
                  let command = object["command"] as? String else { return nil }
            return ServerEntry(
                command: command,
                args: (object["args"] as? [String]) ?? [],
                env: (object["env"] as? [String: String]) ?? [:]
            )
        }
    }

    public struct Registration: Equatable {
        public let isRegistered: Bool
        public let entry: ServerEntry?
        /// True when an entry exists but points somewhere other than the authoritative
        /// binary — the split-install failure SPEC §6.1 wants immediately visible.
        public let pathMatchesInstalledBinary: Bool
    }

    /// What is currently registered, without modifying anything. Safe for `rcc doctor`.
    public static func inspect(
        configURL: URL = RCCPaths.claudeDesktopConfig,
        expectedBinary: URL = RCCPaths.installedBinary
    ) throws -> Registration {
        guard let root = try readConfig(at: configURL) else {
            return Registration(isRegistered: false, entry: nil, pathMatchesInstalledBinary: false)
        }
        let servers = root["mcpServers"] as? [String: Any] ?? [:]
        guard let entry = ServerEntry.fromJSON(servers[RCCPaths.mcpServerKey]) else {
            return Registration(isRegistered: false, entry: nil, pathMatchesInstalledBinary: false)
        }
        // Compare resolved paths: a symlinked or `..`-laden command string that lands on
        // the right inode is still correct, and a string comparison would call it drift.
        let matches = resolve(entry.command) == resolve(expectedBinary.path)
        return Registration(isRegistered: true, entry: entry, pathMatchesInstalledBinary: matches)
    }

    /// Add or update this tool's entry, preserving everything else.
    /// Returns `true` if the file changed.
    @discardableResult
    public static func register(
        entry: ServerEntry,
        configURL: URL = RCCPaths.claudeDesktopConfig
    ) throws -> Bool {
        var root = try readConfig(at: configURL) ?? [:]
        var servers = root["mcpServers"] as? [String: Any] ?? [:]

        if let existing = ServerEntry.fromJSON(servers[RCCPaths.mcpServerKey]), existing == entry {
            return false
        }
        servers[RCCPaths.mcpServerKey] = entry.jsonObject
        root["mcpServers"] = servers
        try writeConfig(root, to: configURL)
        return true
    }

    /// Remove this tool's entry. Leaves an empty `mcpServers` object in place rather than
    /// deleting the key — Claude Desktop tolerates it and removing a key we did not add
    /// is more surprising than leaving it.
    @discardableResult
    public static func unregister(configURL: URL = RCCPaths.claudeDesktopConfig) throws -> Bool {
        guard var root = try readConfig(at: configURL),
              var servers = root["mcpServers"] as? [String: Any],
              servers[RCCPaths.mcpServerKey] != nil else { return false }
        servers.removeValue(forKey: RCCPaths.mcpServerKey)
        root["mcpServers"] = servers
        try writeConfig(root, to: configURL)
        return true
    }

    // MARK: - File I/O

    /// `nil` means "no config file yet", which is a normal first-run state.
    static func readConfig(at url: URL) throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw RCCError(
                .install,
                "Could not read Claude Desktop's config at \(url.path): \(error.localizedDescription)"
            )
        }
        // An empty file is a plausible artefact of a previous crashed write; treat it as
        // "no config" rather than as corruption.
        if data.isEmpty || String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            return [:]
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RCCError(
                .install,
                "Claude Desktop's config at \(url.path) is not valid JSON, so rcc will not modify it.",
                remediation: "Fix or remove the file, then re-run `rcc setup`. rcc deliberately refuses to "
                    + "overwrite a config it cannot parse, because that file holds your other MCP servers."
            )
        }
        return root
    }

    static func writeConfig(_ root: [String: Any], to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw RCCError(
                .install,
                "Claude Desktop's config directory does not exist at \(directory.path).",
                remediation: "Install and launch Claude Desktop at least once, then re-run `rcc setup`."
            )
        }

        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )

        // Back up whatever was there before the first modification of the day, so a bad
        // merge is recoverable without a Time Machine trip.
        if FileManager.default.fileExists(atPath: url.path) {
            let backup = directory.appendingPathComponent(
                "claude_desktop_config.json.rcc-backup", isDirectory: false
            )
            if !FileManager.default.fileExists(atPath: backup.path) {
                try? FileManager.default.copyItem(at: url, to: backup)
            }
        }

        let temporary = directory.appendingPathComponent(
            ".claude_desktop_config.json.rcc-\(ProcessInfo.processInfo.processIdentifier)",
            isDirectory: false
        )
        try? FileManager.default.removeItem(at: temporary)
        guard FileManager.default.createFile(
            atPath: temporary.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw RCCError(.install, "Could not stage a config update at \(temporary.path).")
        }
        do {
            // Same-directory rename: atomic, so no reader ever sees a partial file.
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw RCCError(
                .install,
                "Could not update Claude Desktop's config at \(url.path): \(error.localizedDescription)"
            )
        }
        // `replaceItemAt` carries over the *original* file's metadata, so the 0600 set on the
        // temp file above does not survive if the existing config was looser. Pin it after
        // the fact: sibling `mcpServers` entries routinely hold API keys in `env`, and
        // Claude Desktop itself keeps this file at 0600.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func resolve(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
