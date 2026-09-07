import Foundation
import Testing

@testable import RCCCore
@testable import RCCPlatform

@Suite("Claude Desktop config")
struct ClaudeDesktopConfigTests {
    private func temporaryConfig(_ contents: String?) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rcc-cfg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("claude_desktop_config.json", isDirectory: false)
        if let contents {
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    private func read(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private let entry = ClaudeDesktopConfig.ServerEntry(command: "/opt/rcc", args: ["serve"])

    @Test("A config with no mcpServers key is the normal first-run case")
    func addsMcpServersKey() throws {
        // Verified on this machine: the real file exists with `preferences` and
        // `coworkUserFilesPath` and no `mcpServers` at all.
        let url = try temporaryConfig(#"{"preferences":{"menuBarEnabled":true}}"#)
        #expect(try ClaudeDesktopConfig.register(entry: entry, configURL: url))

        let root = try read(url)
        let servers = try #require(root["mcpServers"] as? [String: Any])
        let written = try #require(ClaudeDesktopConfig.ServerEntry.fromJSON(servers[RCCPaths.mcpServerKey]))
        #expect(written == entry)
        // Everything we did not author survives.
        #expect((root["preferences"] as? [String: Any])?["menuBarEnabled"] as? Bool == true)
    }

    @Test("Sibling MCP servers are never disturbed")
    func preservesSiblings() throws {
        let url = try temporaryConfig(#"""
            {"mcpServers":{"other":{"command":"/usr/local/bin/other","env":{"TOKEN":"secret"}}}}
            """#)
        #expect(try ClaudeDesktopConfig.register(entry: entry, configURL: url))

        let servers = try #require(try read(url)["mcpServers"] as? [String: Any])
        #expect(servers.count == 2)
        let other = try #require(ClaudeDesktopConfig.ServerEntry.fromJSON(servers["other"]))
        #expect(other.command == "/usr/local/bin/other")
        #expect(other.env["TOKEN"] == "secret")
    }

    @Test("Registering an identical entry twice does not rewrite the file")
    func isIdempotent() throws {
        let url = try temporaryConfig("{}")
        #expect(try ClaudeDesktopConfig.register(entry: entry, configURL: url))
        #expect(try ClaudeDesktopConfig.register(entry: entry, configURL: url) == false)
    }

    /// Claude Desktop parses this file as strict JSON and shows a blocking error dialog for
    /// a malformed one. Rewriting a user's hand-annotated config from under them is worse
    /// than failing loudly — especially since sibling entries can hold API keys.
    @Test("A malformed config is refused, never overwritten")
    func refusesMalformedConfig() throws {
        let original = "{ // a comment JSON5 would allow\n  \"mcpServers\": {} }"
        let url = try temporaryConfig(original)

        #expect(throws: RCCError.self) {
            _ = try ClaudeDesktopConfig.register(entry: entry, configURL: url)
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == original)
    }

    @Test("An empty file is treated as absent, not corrupt")
    func toleratesEmptyFile() throws {
        let url = try temporaryConfig("")
        #expect(try ClaudeDesktopConfig.register(entry: entry, configURL: url))
        #expect(try read(url)["mcpServers"] != nil)
    }

    @Test("A missing config directory is an actionable error")
    func missingDirectory() {
        let url = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/claude_desktop_config.json")
        #expect(throws: RCCError.self) {
            _ = try ClaudeDesktopConfig.register(entry: entry, configURL: url)
        }
    }

    @Test("The file is written 0600, matching what Claude Desktop uses")
    func writesRestrictivePermissions() throws {
        // Sibling entries routinely carry API keys in `env`; widening the mode would leak
        // them to every process on the machine.
        let url = try temporaryConfig("{}")
        try ClaudeDesktopConfig.register(entry: entry, configURL: url)
        let mode = try #require(
            FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        )
        #expect(mode.intValue == 0o600)
    }

    /// Regression: `replaceItemAt` carries over the *original* file's metadata, so setting
    /// 0600 on the temp file is not enough when the existing config is looser. This file
    /// holds other MCP servers' API keys in their `env` blocks.
    @Test("An existing world-readable config is tightened, not left as it was")
    func tightensExistingLoosePermissions() throws {
        let url = try temporaryConfig(#"{"mcpServers":{}}"#)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)

        try ClaudeDesktopConfig.register(entry: entry, configURL: url)

        let mode = try #require(
            FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        )
        #expect(mode.intValue == 0o600)
    }

    @Test("The first modification leaves a backup behind")
    func keepsBackup() throws {
        let url = try temporaryConfig(#"{"preferences":{}}"#)
        try ClaudeDesktopConfig.register(entry: entry, configURL: url)
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("claude_desktop_config.json.rcc-backup")
        #expect(FileManager.default.fileExists(atPath: backup.path))
    }

    @Test("Inspection reports drift when the entry points elsewhere")
    func detectsPathDrift() throws {
        let url = try temporaryConfig(#"{"mcpServers":{"reminder-calendar-control":{"command":"/elsewhere/rcc"}}}"#)
        let registration = try ClaudeDesktopConfig.inspect(
            configURL: url, expectedBinary: URL(fileURLWithPath: "/opt/rcc")
        )
        #expect(registration.isRegistered)
        #expect(!registration.pathMatchesInstalledBinary)
    }

    @Test("Unregistering removes only our entry")
    func unregisters() throws {
        let url = try temporaryConfig(#"{"mcpServers":{"other":{"command":"/x"}}}"#)
        try ClaudeDesktopConfig.register(entry: entry, configURL: url)
        #expect(try ClaudeDesktopConfig.unregister(configURL: url))

        let servers = try #require(try read(url)["mcpServers"] as? [String: Any])
        #expect(servers[RCCPaths.mcpServerKey] == nil)
        #expect(servers["other"] != nil)
        // Removing something already absent succeeds.
        #expect(try ClaudeDesktopConfig.unregister(configURL: url) == false)
    }
}
