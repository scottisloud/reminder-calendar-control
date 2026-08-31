import ArgumentParser
import Foundation
import RCCBootstrap
import RCCCalendar
import RCCCore
import RCCDiagnostics
import RCCPlatform

/// The one command a human runs by hand (SPEC §6.1).
///
/// Everything it does is idempotent, so re-running it after an update is the supported
/// repair path rather than a risk.
struct Setup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Grant access, register with Claude Desktop, and install the automation LaunchAgent.",
        discussion: """
            Run this from the installed binary at
            ~/Library/Application Support/reminder-calendar-control/bin/rcc, not from a \
            build directory. macOS records the Calendar and Reminders grant against the \
            binary that asked for it, so granting from a build directory grants it to a \
            copy that nothing else runs.

            Claude Desktop does not reload its config file. Quit it fully (⌘Q) and \
            relaunch after setup.
            """
    )

    @Flag(name: .long, help: "Check an existing install without re-granting anything.")
    var verify = false

    @Flag(name: .long, help: "Remove the LaunchAgent and the Claude Desktop entry.")
    var uninstall = false

    @Flag(name: .long, help: "Provision the dedicated dev calendar and reminder list used by tests.")
    var dev = false

    @Flag(name: .long, help: "Provision Tier 1 automation credentials. Not implemented until Milestone 7.")
    var enableTier1 = false

    @Flag(name: .long, help: "With --uninstall: delete local state instead of preserving it.")
    var purgeState = false

    @Flag(name: .long, help: "With --uninstall: preserve local state without being asked.")
    var keepState = false

    @Flag(
        name: .long,
        help: "Allow running from somewhere other than the installed path. Development only — the TCC grant will attach to the wrong binary."
    )
    var allowAnyPath = false

    @Option(name: .long, help: "Automation LaunchAgent interval, in seconds.")
    var intervalSeconds: Int = LaunchAgent.defaultIntervalSeconds

    func run() async throws {
        do {
            if uninstall {
                try await runUninstall()
            } else if verify {
                try await runVerify()
            } else {
                try await runInstall()
            }
        } catch let error as ExitCode {
            throw error
        } catch {
            exitWith(error)
        }
    }

    // MARK: - Install

    private func runInstall() async throws {
        try requireDisclaimed()
        try requireInstalledPath()

        if enableTier1 {
            throw RCCError(
                .usage,
                "Tier 1 automation is not implemented yet (SPEC §11.2, Milestone 7).",
                remediation: "Run `rcc setup` without --enable-tier1. Core setup never needs an API key."
            )
        }

        let repository = EventKitRepository()

        Output.line("rcc setup — \(BuildInfo.versionString)")
        Output.line("")

        // 1. Authorization. Deliberately first: the LaunchAgent and MCP registration are
        //    worthless without it, and this is the step that can actually fail in a way
        //    the user has to resolve in System Settings.
        for entityType in RCCEntityType.allCases {
            let before = await repository.authorizationStatus(for: entityType)
            if before.grantsFullAccess {
                Output.line("  \(entityType.displayName) access: already granted")
                continue
            }
            if before.known == .denied || before.known == .restricted {
                throw RCCError(
                    .permission,
                    "\(entityType.displayName) access is \(before.known.rawValue); macOS will not prompt again.",
                    remediation: "Enable rcc under System Settings › Privacy & Security › "
                        + "\(entityType.displayName), then re-run `rcc setup --verify`."
                )
            }
            Output.line("  \(entityType.displayName) access: requesting…")
            let after = try await repository.requestFullAccess(for: entityType)
            guard after.grantsFullAccess else {
                throw RCCError(
                    .permission,
                    "\(entityType.displayName) access was not granted (\(after.description)).",
                    remediation: "Re-run `rcc setup`, or enable rcc under System Settings › "
                        + "Privacy & Security › \(entityType.displayName)."
                )
            }
            Output.line("  \(entityType.displayName) access: granted")
        }

        // 2. Local state. Created after the grant so a denied setup does not leave a
        //    half-initialised database behind.
        let store = try Store()
        let signature = CodeSignature.current()
        try store.recordInstall(
            Store.InstallMetadata(
                installedAt: RCCTime.instant(),
                version: BuildInfo.versionString,
                binaryPath: RCCPaths.installedBinary.path,
                signingIdentity: signature?.authority ?? (signature?.isAdHoc == true ? "ad-hoc" : nil),
                cdhash: signature?.cdhash
            )
        )
        Output.line("  state: \(RCCPaths.databaseFile.path)")

        // 3. Dev fixtures.
        if dev {
            let fixtures = DevFixtureManager(repository: repository, store: store)
            for entityType in RCCEntityType.allCases {
                let fixture = try await fixtures.provision(entityType)
                Output.line("  dev \(entityType.rawValue) fixture: \"\(fixture.title)\" "
                    + "(\(fixture.sourceTitle ?? "unknown source"))")
            }
        }

        // 4. Claude Desktop registration.
        let entry = ClaudeDesktopConfig.ServerEntry(
            command: RCCPaths.installedBinary.path,
            args: ["serve"]
        )
        let changed = try ClaudeDesktopConfig.register(entry: entry)
        Output.line("  Claude Desktop: \(changed ? "registered" : "already registered") "
            + "as `\(RCCPaths.mcpServerKey)`")

        // 5. LaunchAgent.
        try LaunchAgent.install(
            binaryPath: RCCPaths.installedBinary.path,
            intervalSeconds: intervalSeconds
        )
        Output.line("  LaunchAgent: \(RCCPaths.automationAgentLabel) every \(intervalSeconds)s")

        // 6. Notifications — advisory, never fatal.
        let capability = Notifications.capability()
        Output.line("  notifications: \(capability.detail)")

        Output.line("")
        Output.line("Setup complete. Quit Claude Desktop fully (⌘Q) and relaunch — it does not")
        Output.line("reload claude_desktop_config.json while running.")
        Output.line("")
        Output.line("Run `rcc doctor` to confirm, and `rcc selftest` to prove read/write works.")
    }

    // MARK: - Verify

    /// Fast, idempotent, and does not re-grant anything (SPEC §6.1).
    private func runVerify() async throws {
        let report = await RCCDiagnostics.Doctor(repository: EventKitRepository()).run()
        Output.line(report.renderText())
        if report.hasFailures {
            throw ExitCode(RCCExitCode.unhealthy.rawValue)
        }
    }

    // MARK: - Uninstall

    private func runUninstall() async throws {
        if purgeState && keepState {
            throw RCCError(.usage, "--purge-state and --keep-state are mutually exclusive.")
        }

        try LaunchAgent.uninstall()
        Output.line("  LaunchAgent: removed")

        let unregistered = try ClaudeDesktopConfig.unregister()
        Output.line("  Claude Desktop: \(unregistered ? "entry removed" : "no entry to remove")")

        // The dev fixtures are calendars in the user's Calendar.app; leaving them behind
        // after an uninstall would be litter, but deleting them is destructive, so it is
        // governed by the same explicit choice as the rest of the state.
        let decision = try stateDecision()
        switch decision {
        case .keep:
            Output.line("  state: preserved at \(RCCPaths.supportRoot.path)")
            Output.line("  dev fixtures: left in place")
        case .purge:
            try await removeDevFixtures()
            try removeStateDirectory()
            Output.line("  state: deleted")
        }

        Output.line("")
        Output.line("Uninstalled. The binary itself is still at \(RCCPaths.installedBinary.path);")
        Output.line("remove it by hand if you want it gone. Quit and relaunch Claude Desktop.")
    }

    private enum StateDecision { case keep, purge }

    private func stateDecision() throws -> StateDecision {
        if purgeState { return .purge }
        if keepState { return .keep }
        guard isatty(STDIN_FILENO) == 1 else {
            throw RCCError(
                .usage,
                "Uninstall needs to know whether to keep or delete local state, and stdin is not a terminal.",
                remediation: "Re-run with --keep-state or --purge-state."
            )
        }
        Output.line("")
        Output.line("Delete local state at \(RCCPaths.supportRoot.path)?")
        Output.line("This removes automation rules, the audit log, and rcc's dev calendars.")
        Output.error("Type 'delete' to remove it, anything else to keep it: ")
        let answer = readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespaces)
        return answer == "delete" ? .purge : .keep
    }

    private func removeDevFixtures() async throws {
        guard FileManager.default.fileExists(atPath: RCCPaths.databaseFile.path) else { return }
        let repository = EventKitRepository()
        let store = try Store()
        let fixtures = DevFixtureManager(repository: repository, store: store)
        for entityType in RCCEntityType.allCases {
            do {
                try await fixtures.remove(entityType)
            } catch {
                // A fixture we cannot delete — revoked access, or the user removed it
                // already — must not block the rest of the uninstall.
                Output.line("  dev \(entityType.rawValue) fixture: could not remove (\(error))")
            }
        }
    }

    private func removeStateDirectory() throws {
        // Only the state, never `bin/`: deleting the binary out from under the running
        // process is a different and much worse kind of surprise.
        for name in ["state.sqlite3", "state.sqlite3-wal", "state.sqlite3-shm"] {
            let url = RCCPaths.supportRoot.appendingPathComponent(name, isDirectory: false)
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Preconditions

    private func requireDisclaimed() throws {
        guard let result = Disclaim.result else {
            throw RCCError(.internalError, "The disclaim mechanism did not run.")
        }
        guard result.outcome.isHealthy else {
            throw RCCError(
                .disclaimUnavailable,
                "rcc cannot establish its own TCC identity (\(result.outcome.rawValue)).",
                remediation: result.outcome.remediation
            )
        }
    }

    /// macOS records the grant against the binary that asked for it. Granting from a build
    /// directory produces a grant that the installed copy — the one Claude Desktop and
    /// launchd actually run — does not hold.
    private func requireInstalledPath() throws {
        guard !allowAnyPath else {
            Output.line("  warning: running from a non-installed path with --allow-any-path;")
            Output.line("           the TCC grant will attach to this copy, not the installed one.")
            return
        }
        guard let running = Disclaim.canonicalExecutablePath() else {
            throw RCCError(.internalError, "Could not resolve rcc's own executable path.")
        }
        let expected = RCCPaths.installedBinary.resolvingSymlinksInPath().path
        guard running == expected else {
            throw RCCError(
                .install,
                "rcc setup must run from the installed binary, not \(running).",
                remediation: "Install first, then run setup from the stable path:\n"
                    + "    ./Scripts/install.sh\n"
                    + "    \"\(RCCPaths.installedBinary.path)\" setup --dev\n\n"
                    + "Pass --allow-any-path to override (development only)."
            )
        }
    }
}
