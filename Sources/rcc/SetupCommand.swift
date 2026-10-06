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

    @Flag(name: .long, help: "Remove the LaunchAgent and the Claude Desktop entry. Calendar and Reminders data is never changed.")
    var uninstall = false

    @Flag(name: .long, help: "Provision the dedicated dev calendar and reminder list used by tests.")
    var dev = false

    @Flag(name: .long, help: "Delete the dev calendar and reminder list that `--dev` created, and nothing else.")
    var removeDev = false

    @Flag(name: .long, help: "With --uninstall: delete rcc's local state and logs instead of preserving them. Never touches Calendar or Reminders data.")
    var purgeState = false

    @Flag(name: .long, help: "With --uninstall: preserve local state without being asked.")
    var keepState = false

    @Flag(name: .long, help: "With --uninstall: also delete the rcc binary (and RCC.app), leaving nothing installed.")
    var removeBinary = false

    @Flag(
        name: .long,
        help: "Allow running from somewhere other than the installed path. Development only — the TCC grant will attach to the wrong binary."
    )
    var allowAnyPath = false

    @Option(name: .long, help: "Automation LaunchAgent interval, in seconds.")
    var intervalSeconds: Int = LaunchAgent.defaultIntervalSeconds

    func run() async throws {
        do {
            if removeDev {
                try await runRemoveDev()
            } else if uninstall {
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

        let repository = EventKitRepository()

        Output.line("rcc setup — \(BuildInfo.versionString)")
        Output.line("")

        // 1. Authorization. Deliberately first: the LaunchAgent and MCP registration are
        //    worthless without it, and this is the step that can actually fail in a way
        //    the user has to resolve in System Settings.
        try await grantAccess(using: repository)

        // 2. Local state. Created after the grant so a denied setup does not leave a
        //    half-initialised database behind.
        let store = try Store()
        try Self.recordInstall(in: store)
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
        Output.line("Setup complete.")
        offerDesktopRestart()
        Output.line("")
        Output.line("Run `rcc doctor` to confirm, and `rcc selftest` to prove read/write works.")
    }

    /// Desktop reads its config only at launch. Offer to do the ⌘Q-and-relaunch for the
    /// user rather than leave it as an instruction that is easy to miss — but only ask: it
    /// may be hosting the very conversation that is installing rcc.
    private func offerDesktopRestart() {
        guard ClaudeDesktopApp.isRunning else {
            Output.line("Claude Desktop will pick up rcc the next time it starts.")
            return
        }
        guard isatty(STDIN_FILENO) == 1 else {
            Output.line("Quit Claude Desktop fully (⌘Q) and relaunch — it reads its config only at launch.")
            return
        }
        Output.line("")
        Output.line("Claude Desktop reads its config only at launch, so it needs a restart to see rcc.")
        Output.error("Restart Claude Desktop now? [Y/n] ")
        let answer = readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespaces).lowercased() ?? "n"
        guard answer.isEmpty || answer == "y" || answer == "yes" else {
            Output.line("Skipped. Quit it fully (⌘Q) and relaunch when convenient.")
            return
        }
        switch ClaudeDesktopApp.restart() {
        case .restarted:
            Output.line("Claude Desktop restarted.")
        case .didNotQuit:
            Output.line("Claude Desktop did not quit (it may be asking about something). Quit it with ⌘Q and relaunch.")
        case .couldNotRelaunch(let why):
            Output.line("Claude Desktop quit but could not be relaunched (\(why)); open it yourself.")
        }
    }

    // MARK: - Authorization

    /// Bring Calendar and Reminders to full access, or fail with a clear reason.
    ///
    /// The request goes through `InteractiveGrant`, which runs a foreground `NSApplication`
    /// run loop: on macOS 14+ a bare CLI async request is denied with no dialog, and on
    /// macOS 26.5+ tccd also needs the `personal-information` entitlements the signed binary
    /// now carries (SPEC §6.3). A non-interactive invocation
    /// (LaunchAgent, piped) never spins up AppKit — it reports what is missing and stops.
    private func grantAccess(using repository: EventKitRepository) async throws {
        let entities = RCCEntityType.allCases

        var undetermined: [RCCEntityType] = []
        for entityType in entities {
            let status = await repository.authorizationStatus(for: entityType)
            if status.grantsFullAccess {
                Output.line("  \(entityType.displayName) access: already granted")
            } else if status.known == .denied || status.known == .restricted {
                throw RCCError(
                    .permission,
                    "\(entityType.displayName) access is \(status.known.rawValue); macOS will not prompt again.",
                    remediation: "Enable rcc under System Settings › Privacy & Security › "
                        + "\(entityType.displayName), then re-run `rcc setup --verify`."
                )
            } else {
                undetermined.append(entityType)
            }
        }

        guard !undetermined.isEmpty else { return }

        let names = undetermined.map(\.displayName).joined(separator: " and ")
        guard isInteractive else {
            throw RCCError(
                .permission,
                "\(names) access is not yet granted, and this is not an interactive session "
                    + "so macOS cannot show the permission dialog.",
                remediation: "Run this once from Terminal:\n    \(RCCPaths.installedBinary.path) setup"
            )
        }

        Output.line("  \(names) access: requesting — approve the macOS dialog(s)…")
        let outcome = await InteractiveGrant.requestFullAccess(for: undetermined)

        // The stores used for the requests were created while authorization was
        // undetermined; drop the repository's own store so later steps get a fresh one.
        await repository.reset()

        for entityType in undetermined {
            let status = outcome.statuses[entityType] ?? RCCAuthorizationStatus(known: .unknown, rawValue: -1)
            guard status.grantsFullAccess else {
                let why = outcome.timedOut
                    ? "no dialog appeared within the timeout"
                    : "result: \(status.description)"
                throw RCCError(
                    .permission,
                    "\(entityType.displayName) access was not granted (\(why)).",
                    remediation: "Re-run `rcc setup`. If no dialog appears at all, check "
                        + "System Settings › Privacy & Security › \(entityType.displayName) for an `rcc` "
                        + "entry, and run `rcc doctor`."
                )
            }
            Output.line("  \(entityType.displayName) access: granted")
        }
    }

    private var isInteractive: Bool {
        isatty(STDIN_FILENO) == 1 || isatty(STDOUT_FILENO) == 1
    }

    // MARK: - Verify

    /// Fast, idempotent, and does not re-grant anything (SPEC §6.1).
    ///
    /// This is the second half of an update: after `install.sh` swaps the binary, `--verify`
    /// proves the grant, LaunchAgent, and Desktop entry all still resolve against it — and,
    /// when they do, records the new binary as the installed one, so `rcc doctor` stops
    /// reporting the version from the original setup.
    private func runVerify() async throws {
        let report = await RCCDiagnostics.Doctor(repository: EventKitRepository()).run()
        Output.line(report.renderText())
        if report.hasFailures {
            throw ExitCode(RCCExitCode.unhealthy.rawValue)
        }
        guard FileManager.default.fileExists(atPath: RCCPaths.databaseFile.path),
              let store = try? Store() else { return }
        let recorded = try? store.installMetadata()
        let current = CodeSignature.current()?.cdhash
        if recorded?.cdhash != current || recorded?.version != BuildInfo.versionString {
            try Self.recordInstall(in: store)
            Output.line("")
            Output.line("Recorded the update: \(recorded?.version ?? "unknown") → \(BuildInfo.versionString)")
        }
    }

    /// Which binary (version, signer, cdhash) is the installed one. Written by setup and by
    /// a healthy `--verify` after an update.
    private static func recordInstall(in store: Store) throws {
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
    }

    // MARK: - Dev fixtures

    /// The one path that deletes the `--dev` fixtures — explicit, never a side effect of
    /// install or uninstall. `DevFixtureManager.remove` refuses any calendar that is not the
    /// recorded fixture, so this cannot reach a calendar the user made.
    private func runRemoveDev() async throws {
        try requireDisclaimed()
        let store = try Store()
        let fixtures = DevFixtureManager(repository: EventKitRepository(), store: store)
        for entityType in RCCEntityType.allCases {
            guard let recorded = try fixtures.recorded(entityType) else {
                Output.line("  dev \(entityType.rawValue) fixture: none recorded")
                continue
            }
            do {
                try await fixtures.remove(entityType)
                Output.line("  dev \(entityType.rawValue) fixture: deleted \"\(recorded.title)\"")
            } catch CalendarRepositoryError.notFound {
                // Already deleted (in Calendar/Reminders, or by an account resync): the
                // goal is reached, so forget the record and carry on with the other one.
                try store.removeDevFixture(entityType.fixtureEntityType)
                Output.line("  dev \(entityType.rawValue) fixture: \"\(recorded.title)\" was already gone")
            }
        }
        Output.line("")
        Output.line("`rcc selftest` needs them; `rcc setup --dev` recreates them.")
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

        // Uninstall removes rcc's own footprint — its database, logs, LaunchAgent, Desktop
        // entry, and optionally its binary — and nothing else. rcc is an interface to
        // Calendar and Reminders, not an owner of their data: installing or uninstalling it
        // never changes anything there. That includes the `--dev` test calendars, which
        // live in the user's accounts like any other calendar; they are named so the user
        // can remove them in Calendar or Reminders if they want them gone.
        let fixtures = recordedDevFixtures()
        switch try stateDecision() {
        case .keep:
            Output.line("  state: preserved at \(RCCPaths.supportRoot.path)")
        case .purge:
            try removeStateDirectory()
            Output.line("  state: deleted")
            try? FileManager.default.removeItem(at: RCCPaths.logDirectory)
            Output.line("  logs: deleted")
        }
        Output.line("  Calendar & Reminders: untouched")
        if !fixtures.isEmpty {
            Output.line("  dev test calendars left in place (delete them in Calendar/Reminders if unwanted):")
            for fixture in fixtures { Output.line("      \(fixture)") }
        }

        if removeBinary {
            // Unlinking the running executable is safe: the process keeps its mapped image
            // and exits normally. Only `bin/` and `RCC.app` go — state was handled above.
            try? FileManager.default.removeItem(at: RCCPaths.binDirectory)
            try? FileManager.default.removeItem(at: RCCPaths.appBundle)
            // The product directory itself goes only if nothing is left in it (kept state
            // stays exactly where it was).
            let root = RCCPaths.supportRoot
            if (try? FileManager.default.contentsOfDirectory(atPath: root.path))?.isEmpty == true {
                try? FileManager.default.removeItem(at: root)
            }
            Output.line("  binary: removed")
            Output.line("")
            Output.line("Uninstalled. Quit and relaunch Claude Desktop.")
        } else {
            Output.line("")
            Output.line("Uninstalled. The binary itself is still at \(RCCPaths.installedBinary.path);")
            Output.line("pass --remove-binary to delete it too. Quit and relaunch Claude Desktop.")
        }
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
        Output.line("This removes rcc's own automation rules, operation journal, and logs.")
        Output.line("Nothing in Calendar or Reminders is changed either way.")
        Output.error("Type 'delete' to remove it, anything else to keep it: ")
        let answer = readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespaces)
        return answer == "delete" ? .purge : .keep
    }

    /// The `--dev` fixtures rcc recorded, described for the user. Read-only.
    private func recordedDevFixtures() -> [String] {
        guard FileManager.default.fileExists(atPath: RCCPaths.databaseFile.path),
              let store = try? Store() else { return [] }
        return RCCEntityType.allCases.compactMap { entityType in
            guard let fixture = (try? store.devFixture(entityType.fixtureEntityType)) ?? nil else { return nil }
            return "\"\(fixture.title)\" (\(fixture.sourceTitle ?? "unknown account"))"
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

    private func requireDisclaimed() throws { try DisclaimGate.require(Disclaim.result) }

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
                remediation: "Install this copy first, then run setup from the stable path:\n"
                    + "    \"\(running)\" install\n"
                    + "    \"\(RCCPaths.installedBinary.path)\" setup\n\n"
                    + "Pass --allow-any-path to override (development only)."
            )
        }
    }
}
