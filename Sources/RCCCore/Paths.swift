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

    /// Redirects every writable path to a throwaway directory when running under
    /// `swift test`.
    ///
    /// Without this, any test that reaches a default-path `Store()` — or simply logs —
    /// writes into the operator's real state and log directories. That actually happened:
    /// a test run created `~/Library/Application Support/reminder-calendar-control/
    /// state.sqlite3` on a machine where `rcc setup` had never succeeded, which then made
    /// `rcc doctor` report an install that did not exist.
    ///
    /// Detection covers both runners: XCTest hosts tests in `xctest`
    /// (`Bundle.main.bundleIdentifier == "com.apple.dt.xctest.tool"`), while swift-testing
    /// uses `swiftpm-testing-helper`, whose main bundle has no identifier at all. The
    /// reliable signal common to both is that a `.xctest` bundle is loaded.
    ///
    /// Deliberately not an environment variable: `Log.shared` is a lazy global that a test
    /// can touch before any setup code runs, so the check has to be intrinsic.
    private static let testSandboxRoot: URL? = {
        let isTestRunner = Bundle.main.bundleIdentifier == "com.apple.dt.xctest.tool"
            || Bundle.main.executableURL?.lastPathComponent == "swiftpm-testing-helper"
            || Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
        guard isTestRunner else { return nil }
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(
                "rcc-test-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true
            )
        try? FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        return root
    }()

    /// True when writable paths are redirected away from the operator's real directories.
    public static var isTestSandboxed: Bool { testSandboxRoot != nil }

    /// `~/Library/Application Support/reminder-calendar-control`
    public static var supportRoot: URL {
        if let testSandboxRoot { return testSandboxRoot.appendingPathComponent("support", isDirectory: true) }
        return home
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
        if let testSandboxRoot { return testSandboxRoot.appendingPathComponent("logs", isDirectory: true) }
        return home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(productDirectoryName, isDirectory: true)
    }

    /// Redirected under test as well: a test that reached `LaunchAgent.install` would
    /// otherwise write a real plist into the operator's LaunchAgents directory.
    public static var launchAgentsDirectory: URL {
        if let testSandboxRoot {
            return testSandboxRoot.appendingPathComponent("LaunchAgents", isDirectory: true)
        }
        return home
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
    ///
    /// Redirected under test so no test can reach the operator's real config, which holds
    /// their other MCP servers and any API keys in those servers' `env` blocks.
    public static var claudeDesktopConfig: URL {
        if let testSandboxRoot {
            return testSandboxRoot
                .appendingPathComponent("Claude", isDirectory: true)
                .appendingPathComponent("claude_desktop_config.json", isDirectory: false)
        }
        return home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("claude_desktop_config.json", isDirectory: false)
    }

    /// Key `rcc` writes under `mcpServers` in Claude Desktop's config.
    public static let mcpServerKey = "reminder-calendar-control"
}
