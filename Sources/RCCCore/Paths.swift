import Foundation

/// Every filesystem location `rcc` owns.
///
/// SPEC §6.1 requires exactly one authoritative binary at a stable path; everything
/// else here hangs off the same install root so `rcc doctor` can prove the install is
/// coherent rather than guessing.
public enum RCCPaths {
    /// Reverse-DNS identity used for the embedded `CFBundleIdentifier`, the LaunchAgent
    /// label prefix, and Keychain service names. Overridable at build time so a fork or
    /// a different signing team does not have to patch source.
    public static let bundleIdentifier: String =
        ProcessInfo.processInfo.environment["RCC_BUNDLE_IDENTIFIER"]
        ?? "com.scottlougheed.reminder-calendar-control"

    /// Directory name used under Application Support, Logs, and LaunchAgents.
    public static let productDirectoryName = "reminder-calendar-control"

    /// `~` for the invoking user. Read from the passwd database rather than `$HOME`:
    /// a `launchd` job's environment is not guaranteed to carry a sane `HOME`, and a
    /// caller can set `$HOME` to anything.
    public static var home: URL {
        // `NSHomeDirectory()` consults the passwd entry when `$HOME` is absent.
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    /// `~/Library/Application Support/reminder-calendar-control`
    public static var supportRoot: URL {
        home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(productDirectoryName, isDirectory: true)
    }

    /// The one authoritative binary location (SPEC §6.1).
    public static var installedBinary: URL {
        supportRoot.appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("rcc", isDirectory: false)
    }

    public static var binDirectory: URL {
        supportRoot.appendingPathComponent("bin", isDirectory: true)
    }

    /// SQLite database holding automation rules, the operation journal, the audit log,
    /// locators, and install metadata (SPEC §7.4).
    public static var databaseFile: URL {
        supportRoot.appendingPathComponent("state.sqlite3", isDirectory: false)
    }

    /// `~/Library/Logs/reminder-calendar-control`
    public static var logDirectory: URL {
        home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(productDirectoryName, isDirectory: true)
    }

    public static var launchAgentsDirectory: URL {
        home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
    }

    /// Label of the LaunchAgent that runs `rcc automations run` on a schedule.
    public static var automationAgentLabel: String { "\(bundleIdentifier).automation" }

    public static var automationAgentPlist: URL {
        launchAgentsDirectory
            .appendingPathComponent("\(automationAgentLabel).plist", isDirectory: false)
    }

    /// Claude Desktop's MCP configuration file.
    public static var claudeDesktopConfig: URL {
        home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("claude_desktop_config.json", isDirectory: false)
    }

    /// Key `rcc` writes under `mcpServers` in Claude Desktop's config.
    public static let mcpServerKey = "reminder-calendar-control"
}
