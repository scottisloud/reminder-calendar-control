import Foundation
import RCCCore

/// Install, inspect, and remove the per-user LaunchAgent that runs
/// `rcc automations run` on a schedule (SPEC §6.1, §11.3, §16).
///
/// All operations are idempotent (SPEC §16): installing twice is a no-op, removing
/// something absent succeeds. The `launchctl` verbs used are the modern
/// `bootstrap`/`bootout`/`kickstart` domain-target forms; `load`/`unload` are legacy and
/// silently do the wrong thing in some session contexts.
public enum LaunchAgent {
    /// launchd domain for the current GUI login session.
    public static var guiDomain: String { "gui/\(getuid())" }
    public static var serviceTarget: String { "\(guiDomain)/\(RCCPaths.automationAgentLabel)" }

    public struct State: Equatable {
        public let plistExists: Bool
        public let isBootstrapped: Bool
        /// `ProgramArguments[0]` as written in the installed plist.
        public let programPath: String?
        /// Whether that path resolves to the authoritative binary (SPEC §6.1).
        public let pathMatchesInstalledBinary: Bool
        public let lastExitStatus: Int?
        public let pid: Int?
    }

    // MARK: - Plist

    /// Default cadence. SPEC §7.3 flags ~50–100 launches/day as a measured tradeoff, not
    /// a free one, and says to drop the cadence if the energy cost proves real — so this
    /// is a named constant, not a number buried in the plist template.
    public static let defaultIntervalSeconds = 1800

    public static func plistData(
        binaryPath: String,
        intervalSeconds: Int = defaultIntervalSeconds,
        logDirectory: URL = RCCPaths.logDirectory
    ) throws -> Data {
        let plist: [String: Any] = [
            "Label": RCCPaths.automationAgentLabel,
            "ProgramArguments": [binaryPath, "automations", "run"],
            "StartInterval": intervalSeconds,
            // launchd would otherwise start the job the moment it is bootstrapped, which
            // turns `rcc setup` into an immediate automation run.
            "RunAtLoad": false,
            // Never let a scheduled run pin a core; automation is background work.
            "ProcessType": "Background",
            "LowPriorityIO": true,
            "Nice": 5,
            "StandardOutPath": logDirectory.appendingPathComponent("automation.out.log").path,
            "StandardErrorPath": logDirectory.appendingPathComponent("automation.err.log").path,
            // launchd does supply HOME, USER, LOGNAME and TMPDIR, but PATH is the bare
            // `/usr/bin:/bin:/usr/sbin:/sbin` with no shell rc files sourced. Both are
            // pinned explicitly so a run under launchd resolves the same paths and the
            // same helper binaries as a run from Terminal.
            "EnvironmentVariables": [
                "HOME": RCCPaths.home.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            ],
            // launchd's cwd is `/`. Pin it so relative paths, if any ever creep in,
            // resolve somewhere rcc owns.
            "WorkingDirectory": RCCPaths.supportRoot.path,
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    // MARK: - Install / remove

    /// Write the plist and bootstrap it. Safe to call repeatedly.
    public static func install(
        binaryPath: String,
        intervalSeconds: Int = defaultIntervalSeconds
    ) throws {
        let data = try plistData(binaryPath: binaryPath, intervalSeconds: intervalSeconds)
        try FileManager.default.createDirectory(
            at: RCCPaths.launchAgentsDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: RCCPaths.logDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        // Bootstrapping a plist that is already loaded fails, so unload first. This is
        // also what makes an update pick up a changed program path. Exit 3 ("no such
        // process") is the expected result on a first install.
        _ = try? runLaunchctl(["bootout", serviceTarget])

        // 0644 exactly. launchd refuses to bootstrap a group- or world-writable plist, and
        // reports it as the same generic "Input/output error" as everything else.
        try writeAtomically(data, to: RCCPaths.automationAgentPlist, mode: 0o644)

        // A previous `launchctl disable` writes a persistent, root-owned record that
        // survives bootout and even deleting the plist, and makes `bootstrap` fail
        // outright. Clearing it first is what makes install genuinely idempotent —
        // `enable` alone does not load the job, so this has to come before `bootstrap`.
        _ = try? runLaunchctl(["enable", serviceTarget])

        let result = try runLaunchctl(["bootstrap", guiDomain, RCCPaths.automationAgentPlist.path])
        guard result.status == 0 else {
            throw RCCError(
                .install,
                "launchctl bootstrap failed (exit \(result.status)): \(result.combinedOutput)",
                remediation: "launchd reports exit 5 (\"Input/output error\") for several unrelated causes: "
                    + "the job is already loaded, the plist is group/world-writable, or a persistent "
                    + "disable record exists. Check `launchctl print-disabled \(guiDomain)` and "
                    + "`ls -l \(RCCPaths.automationAgentPlist.path)`."
            )
        }
        Log.shared.info("launchagent.installed", [
            "label": .safe(RCCPaths.automationAgentLabel),
            "program": .safe(binaryPath),
            "interval_seconds": .int(intervalSeconds),
        ])
    }

    /// Bootout and delete. Succeeds when nothing is installed.
    public static func uninstall() throws {
        _ = try? runLaunchctl(["bootout", serviceTarget])
        if FileManager.default.fileExists(atPath: RCCPaths.automationAgentPlist.path) {
            try FileManager.default.removeItem(at: RCCPaths.automationAgentPlist)
        }
        Log.shared.info("launchagent.uninstalled", ["label": .safe(RCCPaths.automationAgentLabel)])
    }

    /// Run the job now, without waiting for its interval. Used by the acceptance harness
    /// to exercise the LaunchAgent launch context (SPEC §18, Milestone 1).
    ///
    /// `-k` kills a currently-running instance first; `-p` prints the new pid.
    @discardableResult
    public static func kickstart(wait: Bool = true) throws -> LaunchctlResult {
        try runLaunchctl(wait ? ["kickstart", "-kp", serviceTarget] : ["kickstart", serviceTarget])
    }

    // MARK: - Inspection

    public static func state(expectedBinary: URL = RCCPaths.installedBinary) -> State {
        let plistURL = RCCPaths.automationAgentPlist
        let plistExists = FileManager.default.fileExists(atPath: plistURL.path)

        var programPath: String?
        if plistExists,
           let data = try? Data(contentsOf: plistURL),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let arguments = plist["ProgramArguments"] as? [String] {
            programPath = arguments.first
        }

        let printResult = try? runLaunchctl(["print", serviceTarget])
        let isBootstrapped = (printResult?.status ?? 1) == 0
        let output = printResult?.combinedOutput ?? ""

        return State(
            plistExists: plistExists,
            isBootstrapped: isBootstrapped,
            programPath: programPath,
            pathMatchesInstalledBinary: programPath.map {
                ClaudeDesktopConfig.resolve($0) == ClaudeDesktopConfig.resolve(expectedBinary.path)
            } ?? false,
            lastExitStatus: parseInteger(after: "last exit code = ", in: output),
            pid: parseInteger(after: "pid = ", in: output)
        )
    }

    // MARK: - Plumbing

    public struct LaunchctlResult {
        public let status: Int32
        public let combinedOutput: String
    }

    /// Always `bootstrap`/`bootout`/`kickstart`, never `load`/`unload`/`start`.
    ///
    /// The legacy verbs still work on macOS 26 but **always exit 0**, including when they
    /// print `Load failed: 5: Input/output error` — so an install script can never detect
    /// their failure. The domain-target verbs return real exit codes (5 for bootstrap
    /// failure, 3 for "no such process").
    @discardableResult
    static func runLaunchctl(_ arguments: [String]) throws -> LaunchctlResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // Read before waiting: a full pipe buffer would otherwise deadlock the child.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return LaunchctlResult(
            status: process.terminationStatus,
            combinedOutput: String(data: data, encoding: .utf8) ?? ""
        )
    }

    static func parseInteger(after marker: String, in text: String) -> Int? {
        guard let range = text.range(of: marker) else { return nil }
        let tail = text[range.upperBound...]
        let digits = tail.prefix { $0.isNumber || $0 == "-" }
        return Int(digits)
    }

    static func writeAtomically(_ data: Data, to url: URL, mode: Int) throws {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(
            ".\(url.lastPathComponent).rcc-\(ProcessInfo.processInfo.processIdentifier)",
            isDirectory: false
        )
        try? FileManager.default.removeItem(at: temporary)
        guard FileManager.default.createFile(
            atPath: temporary.path,
            contents: data,
            attributes: [.posixPermissions: mode]
        ) else {
            throw RCCError(.install, "Could not stage a write at \(temporary.path).")
        }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw RCCError(.install, "Could not write \(url.path): \(error.localizedDescription)")
        }
    }
}
