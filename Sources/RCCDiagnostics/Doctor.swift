import Foundation
import RCCBootstrap
import RCCCalendar
import RCCCore
import RCCPlatform

/// Assembles `rcc doctor`'s report (SPEC §6.1, §16).
///
/// The point of `doctor` is that a *partial* install is immediately visible rather than
/// silently running mismatched versions — so most checks compare two things that must
/// agree (the running binary vs. the installed one, the LaunchAgent's program path vs. the
/// authoritative path, the MCP registration vs. both) rather than asking a single yes/no
/// question.
public struct Doctor: Sendable {
    private let repository: any CalendarRepository
    private let bundle: Bundle
    private let installedBinary: URL

    public init(
        repository: any CalendarRepository,
        bundle: Bundle = .main,
        installedBinary: URL = RCCPaths.installedBinary
    ) {
        self.repository = repository
        self.bundle = bundle
        self.installedBinary = installedBinary
    }

    public func run(now: Date = Date()) async -> HealthReport {
        var checks: [HealthReport.Check] = []
        checks.append(disclaimCheck())
        checks.append(bundleIdentityCheck())
        checks.append(runningBinaryCheck())
        checks.append(installedBinaryCheck())
        checks.append(gatekeeperCheck())
        let signature = CodeSignature.current()
        checks.append(await authorizationCheck(.event, signature: signature))
        checks.append(await authorizationCheck(.reminder, signature: signature))
        checks.append(mcpRegistrationCheck())
        checks.append(launchAgentCheck())
        checks.append(stateCheck())
        checks.append(devFixtureCheck())
        checks.append(keychainCheck())
        checks.append(notificationCheck())
        return HealthReport(generatedAt: now, checks: checks)
    }

    // MARK: - Individual checks

    /// The single point of failure the whole permission story rests on (SPEC §6.2).
    func disclaimCheck() -> HealthReport.Check {
        guard let result = Disclaim.result else {
            return HealthReport.Check(
                id: "disclaim",
                title: "TCC self-disclaim",
                status: .unknown,
                detail: "not run in this process",
                remediation: "This is a bug: Disclaim.ensure() must be the first thing main() does."
            )
        }

        let facts: [String: String] = [
            "outcome": result.outcome.rawValue,
            "generation": String(result.generation),
            "pid": String(result.pid),
            "responsible_pid": String(result.responsiblePID),
            "mechanism_available": result.mechanismAvailable ? "true" : "false",
        ]

        let status: HealthReport.Status = result.outcome.isHealthy ? .ok : .fail
        let detail: String
        if result.outcome.isHealthy {
            detail = "re-executed once; TCC holds rcc responsible for itself (pid \(result.pid))"
        } else {
            detail = "\(result.outcome.rawValue) — TCC holds pid \(result.responsiblePID) responsible, not rcc"
        }
        return HealthReport.Check(
            id: "disclaim",
            title: "TCC self-disclaim",
            status: status,
            detail: detail,
            remediation: result.outcome.remediation,
            facts: facts
        )
    }

    /// Without the embedded usage descriptions, EventKit's request fails instead of
    /// prompting — so a missing section is a hard failure, not cosmetic (SPEC §6.3).
    func bundleIdentityCheck() -> HealthReport.Check {
        let identity = BundleIdentity(bundle: bundle)
        if !identity.isComplete {
            return HealthReport.Check(
                id: "bundle_identity",
                title: "Embedded Info.plist",
                status: .fail,
                detail: "missing \(identity.missingRequirements.joined(separator: ", "))",
                remediation: "The binary was linked without its __TEXT,__info_plist section, or with an "
                    + "incomplete one. Rebuild with Scripts/build-release.sh — note that editing the "
                    + "plist alone does not trigger a relink.",
                facts: identity.facts
            )
        }
        if !identity.legacyKeysPresent.isEmpty {
            return HealthReport.Check(
                id: "bundle_identity",
                title: "Embedded Info.plist",
                status: .warn,
                detail: "carries legacy keys \(identity.legacyKeysPresent.joined(separator: ", "))",
                remediation: "The macOS 26 floor means the pre-14 usage-description keys are dead weight; "
                    + "remove them from Resources/rcc-Info.plist.",
                facts: identity.facts
            )
        }
        return HealthReport.Check(
            id: "bundle_identity",
            title: "Embedded Info.plist",
            status: .ok,
            detail: "\(identity.bundleIdentifier ?? "?") v\(identity.shortVersion ?? "?") with both usage descriptions",
            facts: identity.facts
        )
    }

    /// What is actually executing right now.
    func runningBinaryCheck() -> HealthReport.Check {
        guard let signature = CodeSignature.current() else {
            return HealthReport.Check(
                id: "running_binary",
                title: "Running binary signature",
                status: .fail,
                detail: "no code signature",
                remediation: "An unsigned binary has no identity for TCC to key a grant against. "
                    + "Re-run Scripts/sign.sh."
            )
        }
        var facts = signature.facts
        facts["path"] = Disclaim.canonicalExecutablePath() ?? "<unknown>"

        if signature.isDeveloperIDSigned && signature.hasHardenedRuntime {
            return HealthReport.Check(
                id: "running_binary",
                title: "Running binary signature",
                status: .ok,
                detail: "Developer ID, Hardened Runtime",
                facts: facts
            )
        }
        if signature.isAdHoc {
            return HealthReport.Check(
                id: "running_binary",
                title: "Running binary signature",
                status: .warn,
                detail: "ad-hoc signature\(signature.hasHardenedRuntime ? " with Hardened Runtime" : "")",
                remediation: "An ad-hoc signature's designated requirement is a bare cdhash, which changes on "
                    + "every rebuild — so the Calendar and Reminders grants are invalidated each time you "
                    + "reinstall, and you will be re-prompted. This is expected until a Developer ID "
                    + "certificate is available; see docs/milestone-1.md.",
                facts: facts
            )
        }
        return HealthReport.Check(
            id: "running_binary",
            title: "Running binary signature",
            status: .warn,
            detail: "signed by \(signature.authority ?? "unknown authority")",
            remediation: signature.hasHardenedRuntime
                ? nil
                : "Hardened Runtime is not enabled, which notarization requires.",
            facts: facts
        )
    }

    /// The authoritative copy on disk, and whether we are it (SPEC §6.1).
    func installedBinaryCheck() -> HealthReport.Check {
        var facts: [String: String] = ["expected_path": installedBinary.path]
        guard FileManager.default.fileExists(atPath: installedBinary.path) else {
            return HealthReport.Check(
                id: "installed_binary",
                title: "Authoritative install path",
                status: .fail,
                detail: "nothing at \(installedBinary.path)",
                remediation: "Run Scripts/install.sh, then `\(installedBinary.path) setup`.",
                facts: facts
            )
        }

        let installedSignature = CodeSignature.of(path: installedBinary.path)
        facts["installed_cdhash"] = installedSignature?.cdhash ?? "<unknown>"
        let runningPath = Disclaim.canonicalExecutablePath()
        facts["running_path"] = runningPath ?? "<unknown>"

        let expected = URL(fileURLWithPath: installedBinary.path).resolvingSymlinksInPath().path
        let isRunningInstalledCopy = runningPath.map { $0 == expected } ?? false
        facts["running_is_installed_copy"] = isRunningInstalledCopy ? "true" : "false"

        if isRunningInstalledCopy {
            return HealthReport.Check(
                id: "installed_binary",
                title: "Authoritative install path",
                status: .ok,
                detail: "running the installed copy",
                facts: facts
            )
        }

        let runningCDHash = CodeSignature.current()?.cdhash
        facts["running_cdhash"] = runningCDHash ?? "<unknown>"
        let sameBits = runningCDHash != nil && runningCDHash == installedSignature?.cdhash
        return HealthReport.Check(
            id: "installed_binary",
            title: "Authoritative install path",
            status: .warn,
            detail: sameBits
                ? "running a different path with identical bits"
                : "running a DIFFERENT build than the installed copy",
            remediation: sameBits
                ? "Harmless for a one-off invocation, but the installed copy at \(installedBinary.path) is "
                    + "what Claude Desktop and launchd run."
                : "Two builds are in play. Re-run Scripts/install.sh so the copy at \(installedBinary.path) "
                    + "matches, then `rcc setup --verify`.",
            facts: facts
        )
    }

    func gatekeeperCheck() -> HealthReport.Check {
        let path = Disclaim.canonicalExecutablePath()
            ?? bundle.executableURL?.path
            ?? installedBinary.path
        let (accepted, detail) = CodeSignature.gatekeeperAssessment(path: path)
        return HealthReport.Check(
            id: "gatekeeper",
            title: "Gatekeeper / notarization",
            status: accepted ? .ok : .warn,
            detail: accepted ? "accepted" : "rejected",
            remediation: accepted
                ? nil
                : "Expected for a locally built, un-notarized binary; it still runs because it was never "
                    + "quarantined. SPEC §18's Milestone 1 gate wants a notarized artifact, which needs a "
                    + "Developer ID certificate. See docs/milestone-1.md.",
            facts: ["spctl": detail, "path": path]
        )
    }

    func authorizationCheck(
        _ entityType: RCCEntityType,
        signature: CodeSignature? = nil
    ) async -> HealthReport.Check {
        let status = await repository.authorizationStatus(for: entityType)
        let facts = [
            "status": status.known.rawValue,
            "raw_value": String(status.rawValue),
        ]
        if status.grantsFullAccess {
            return HealthReport.Check(
                id: "authorization_\(entityType.rawValue)",
                title: "\(entityType.displayName) access",
                status: .ok,
                detail: "full access",
                facts: facts
            )
        }
        var remediation: String
        switch status.known {
        case .notDetermined:
            remediation = "Run `rcc setup` from Terminal; it will trigger the macOS permission prompt."
            // Measured on macOS 26.6.2: with the disclaim active and an ad-hoc signature,
            // EventKit returns granted=false with a nil error and no dialog at all, while
            // the same binary without the disclaim prompts and is granted. The likely
            // cause is that tccd has no stable designated requirement to record a grant
            // against. Say so here rather than letting the operator re-run setup forever.
            if signature?.isAdHoc == true, Disclaim.result?.outcome.isHealthy == true {
                remediation += "\n\nKnown issue for this build: rcc is ad-hoc signed, and a disclaimed "
                    + "ad-hoc process appears unable to obtain a grant on macOS 26 — the request is "
                    + "denied immediately with no dialog. A Developer ID signature is expected to fix "
                    + "it. See docs/milestone-1.md §1.0."
            }
        case .denied:
            remediation = "Grant access in System Settings › Privacy & Security › \(entityType.displayName), "
                + "then re-run `rcc setup --verify`."
        case .restricted:
            remediation = "Access is restricted by a profile or parental control; rcc cannot override that."
        case .writeOnly:
            remediation = "Only write-only access was granted. rcc needs full access — it reads as well as "
                + "writes. Revoke and re-grant in System Settings."
        default:
            remediation = "EventKit reported an authorization state rcc does not recognise (raw "
                + "\(status.rawValue)). Please report this."
        }
        return HealthReport.Check(
            id: "authorization_\(entityType.rawValue)",
            title: "\(entityType.displayName) access",
            status: .fail,
            detail: status.description,
            remediation: remediation,
            facts: facts
        )
    }

    func mcpRegistrationCheck() -> HealthReport.Check {
        do {
            let registration = try ClaudeDesktopConfig.inspect(expectedBinary: installedBinary)
            guard registration.isRegistered, let entry = registration.entry else {
                return HealthReport.Check(
                    id: "mcp_registration",
                    title: "Claude Desktop registration",
                    status: .fail,
                    detail: "no `\(RCCPaths.mcpServerKey)` entry in claude_desktop_config.json",
                    remediation: "Run `rcc setup`. Note Claude Desktop does not reload this file — quit it "
                        + "fully (⌘Q) and relaunch afterwards.",
                    facts: ["config_path": RCCPaths.claudeDesktopConfig.path]
                )
            }
            let facts = [
                "config_path": RCCPaths.claudeDesktopConfig.path,
                "command": entry.command,
                "args": entry.args.joined(separator: " "),
            ]
            guard registration.pathMatchesInstalledBinary else {
                return HealthReport.Check(
                    id: "mcp_registration",
                    title: "Claude Desktop registration",
                    status: .fail,
                    detail: "registered, but points at a different binary",
                    remediation: "Claude Desktop would run \(entry.command) while the authoritative binary is "
                        + "\(installedBinary.path). Re-run `rcc setup`.",
                    facts: facts
                )
            }
            return HealthReport.Check(
                id: "mcp_registration",
                title: "Claude Desktop registration",
                status: .ok,
                detail: "registered, pointing at the authoritative binary",
                facts: facts
            )
        } catch let error as RCCError {
            return HealthReport.Check(
                id: "mcp_registration",
                title: "Claude Desktop registration",
                status: .fail,
                detail: error.message,
                remediation: error.remediation
            )
        } catch {
            return HealthReport.Check(
                id: "mcp_registration",
                title: "Claude Desktop registration",
                status: .unknown,
                detail: error.localizedDescription
            )
        }
    }

    func launchAgentCheck() -> HealthReport.Check {
        let state = LaunchAgent.state(expectedBinary: installedBinary)
        var facts: [String: String] = [
            "label": RCCPaths.automationAgentLabel,
            "plist": RCCPaths.automationAgentPlist.path,
            "plist_exists": state.plistExists ? "true" : "false",
            "bootstrapped": state.isBootstrapped ? "true" : "false",
        ]
        if let programPath = state.programPath { facts["program"] = programPath }
        if let exitStatus = state.lastExitStatus { facts["last_exit_status"] = String(exitStatus) }
        if let pid = state.pid { facts["pid"] = String(pid) }

        guard state.plistExists else {
            return HealthReport.Check(
                id: "launch_agent",
                title: "Automation LaunchAgent",
                status: .fail,
                detail: "not installed",
                remediation: "Run `rcc setup`.",
                facts: facts
            )
        }
        guard state.pathMatchesInstalledBinary else {
            return HealthReport.Check(
                id: "launch_agent",
                title: "Automation LaunchAgent",
                status: .fail,
                detail: "installed, but runs \(state.programPath ?? "<unknown>")",
                remediation: "The LaunchAgent and Claude Desktop must run the same binary. Re-run `rcc setup`.",
                facts: facts
            )
        }
        guard state.isBootstrapped else {
            return HealthReport.Check(
                id: "launch_agent",
                title: "Automation LaunchAgent",
                status: .warn,
                detail: "plist present but not loaded",
                remediation: "Run `rcc setup --verify`. If that does not help, check "
                    + "`launchctl print-disabled \(LaunchAgent.guiDomain)` for a persistent disable record.",
                facts: facts
            )
        }
        return HealthReport.Check(
            id: "launch_agent",
            title: "Automation LaunchAgent",
            status: .ok,
            detail: "loaded, running the authoritative binary",
            facts: facts
        )
    }

    func stateCheck() -> HealthReport.Check {
        let path = RCCPaths.databaseFile.path
        guard FileManager.default.fileExists(atPath: path) else {
            return HealthReport.Check(
                id: "state",
                title: "Local state database",
                status: .warn,
                detail: "not created yet",
                remediation: "Created on first `rcc setup`.",
                facts: ["path": path]
            )
        }
        do {
            let store = try Store()
            let metadata = try store.installMetadata()
            var facts: [String: String] = [
                "path": path,
                "schema_version": String(Store.currentSchemaVersion),
            ]
            if let metadata {
                facts["installed_at"] = metadata.installedAt
                facts["installed_version"] = metadata.version
                facts["installed_cdhash"] = metadata.cdhash ?? "<unknown>"
            }
            if let mode = try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber {
                facts["mode"] = String(mode.intValue, radix: 8)
            }
            return HealthReport.Check(
                id: "state",
                title: "Local state database",
                status: .ok,
                detail: "schema v\(Store.currentSchemaVersion)",
                facts: facts
            )
        } catch let error as RCCError {
            return HealthReport.Check(
                id: "state",
                title: "Local state database",
                status: .fail,
                detail: error.message,
                remediation: error.remediation,
                facts: ["path": path]
            )
        } catch {
            return HealthReport.Check(
                id: "state",
                title: "Local state database",
                status: .fail,
                detail: error.localizedDescription,
                facts: ["path": path]
            )
        }
    }

    func devFixtureCheck() -> HealthReport.Check {
        guard FileManager.default.fileExists(atPath: RCCPaths.databaseFile.path),
              let store = try? Store() else {
            return HealthReport.Check(
                id: "dev_fixture",
                title: "Dev calendar & list",
                status: .skipped,
                detail: "no state database yet"
            )
        }
        var facts: [String: String] = [:]
        var present = 0
        for entityType in RCCEntityType.allCases {
            if let fixture = (try? store.devFixture(entityType.fixtureEntityType)) ?? nil {
                facts["\(entityType.rawValue)_calendar"] = fixture.calendarID
                facts["\(entityType.rawValue)_title"] = fixture.title
                present += 1
            }
        }
        guard present == RCCEntityType.allCases.count else {
            return HealthReport.Check(
                id: "dev_fixture",
                title: "Dev calendar & list",
                status: .skipped,
                detail: present == 0 ? "not provisioned" : "partially provisioned (\(present) of 2)",
                remediation: "Run `rcc setup --dev` if you want the tool-owned test fixtures.",
                facts: facts
            )
        }
        return HealthReport.Check(
            id: "dev_fixture",
            title: "Dev calendar & list",
            status: .ok,
            detail: "both provisioned",
            facts: facts
        )
    }

    func keychainCheck() -> HealthReport.Check {
        let state = KeychainProbe.inspect()
        switch state.credentialPresence {
        case .present, .absent:
            return HealthReport.Check(
                id: "keychain",
                title: "Keychain",
                status: .ok,
                detail: "reachable; Tier 1 credential \(state.credentialPresence.detail)",
                facts: state.facts
            )
        case .locked:
            return HealthReport.Check(
                id: "keychain",
                title: "Keychain",
                status: .warn,
                detail: state.credentialPresence.detail,
                remediation: "Tier 1 automation cannot read its API key while the login keychain is locked. "
                    + "Unlock it in Keychain Access.",
                facts: state.facts
            )
        case .accessDenied:
            return HealthReport.Check(
                id: "keychain",
                title: "Keychain",
                status: .warn,
                detail: state.credentialPresence.detail,
                remediation: "A rebuild changed this binary's signature, so the keychain ACL no longer "
                    + "matches. Remove the stale item with "
                    + "`security delete-generic-password -s \(KeychainProbe.credentialService)` and re-run "
                    + "`rcc setup --enable-tier1`.",
                facts: state.facts
            )
        case .error:
            return HealthReport.Check(
                id: "keychain",
                title: "Keychain",
                status: .warn,
                detail: state.credentialPresence.detail,
                facts: state.facts
            )
        }
    }

    func notificationCheck() -> HealthReport.Check {
        let capability = Notifications.capability(bundle: bundle)
        switch capability {
        case .unavailableNoBundleIdentifier:
            return HealthReport.Check(
                id: "notifications",
                title: "Notifications",
                status: .warn,
                detail: capability.detail,
                remediation: "Advisory notifications will be skipped. This does not affect whether an action "
                    + "is staged — approval is always a CLI step (SPEC §8.3)."
            )
        case .appBundle, .bareExecutable:
            return HealthReport.Check(
                id: "notifications",
                title: "Notifications",
                status: .ok,
                detail: capability.detail,
                facts: ["delivery": "osascript"]
            )
        }
    }
}
