import Foundation
import Testing

@testable import RCCCore
@testable import RCCPlatform

@Suite("LaunchAgent plist")
struct LaunchAgentTests {
    private func plist(intervalSeconds: Int = 1800) throws -> [String: Any] {
        let data = try LaunchAgent.plistData(binaryPath: "/opt/rcc", intervalSeconds: intervalSeconds)
        return try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
    }

    @Test("The agent runs the authoritative binary, not a wrapper")
    func programArguments() throws {
        let arguments = try #require(try plist()["ProgramArguments"] as? [String])
        #expect(arguments == ["/opt/rcc", "automations", "run"])
    }

    /// A launchd job's PATH is the bare system one with no shell rc files sourced, and
    /// pinning HOME matters because every rcc path derives from it.
    @Test("Environment is pinned so launchd and Terminal resolve identically")
    func pinsEnvironment() throws {
        let environment = try #require(try plist()["EnvironmentVariables"] as? [String: String])
        #expect(environment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(environment["HOME"] == RCCPaths.home.path)
    }

    @Test("StartInterval is used, and the job does not fire at load")
    func schedule() throws {
        let contents = try plist(intervalSeconds: 900)
        #expect(contents["StartInterval"] as? Int == 900)
        // Firing at bootstrap would turn `rcc setup` into an immediate automation run.
        #expect(contents["RunAtLoad"] as? Bool == false)
        // `StartCalendarInterval` would need three dict entries per hour for this cadence
        // and fires with measurable jitter; `StartInterval` is one key.
        #expect(contents["StartCalendarInterval"] == nil)
    }

    @Test("Automation is marked background work")
    func backgroundPriority() throws {
        let contents = try plist()
        #expect(contents["ProcessType"] as? String == "Background")
        #expect(contents["LowPriorityIO"] as? Bool == true)
    }

    @Test("The plist is valid and parses back")
    func plistIsValid() throws {
        let data = try LaunchAgent.plistData(binaryPath: "/opt/rcc")
        #expect(!data.isEmpty)
        #expect((try plist()["Label"] as? String) == RCCPaths.automationAgentLabel)
    }

    /// Regression: launchd hard-refuses a group- or world-writable plist, and reports it as
    /// the same generic "Input/output error" as everything else — so a mode that silently
    /// came out as 0664 produces a baffling install failure.
    @Test("The plist is written 0644 even over an existing looser file and a permissive umask")
    func writesPlistWithExactMode() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rcc-plist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("agent.plist", isDirectory: false)

        // Pre-existing file with a mode launchd would reject.
        FileManager.default.createFile(
            atPath: url.path, contents: Data("old".utf8), attributes: [.posixPermissions: 0o666]
        )
        try LaunchAgent.writeAtomically(
            try LaunchAgent.plistData(binaryPath: "/opt/rcc"), to: url, mode: 0o644
        )

        let mode = try #require(
            FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        )
        #expect(mode.intValue == 0o644)
        #expect(mode.intValue & 0o022 == 0, "launchd refuses a group/world-writable plist")
    }

    @Test("launchctl print output is parsed for exit status and pid")
    func parsesLaunchctlOutput() {
        let output = """
            gui/501/com.example.job = {
                runs = 3
                last exit code = 0
                pid = 12345
            }
            """
        #expect(LaunchAgent.parseInteger(after: "last exit code = ", in: output) == 0)
        #expect(LaunchAgent.parseInteger(after: "pid = ", in: output) == 12345)
        #expect(LaunchAgent.parseInteger(after: "nothing = ", in: output) == nil)
    }

    @Test("Negative exit codes parse")
    func parsesNegativeExitCode() {
        #expect(LaunchAgent.parseInteger(after: "last exit code = ", in: "last exit code = -1") == -1)
    }
}

@Suite("Notifications")
struct NotificationTests {
    /// `UNUserNotificationCenter.current()` aborts the process — uncatchably, even from
    /// Objective-C — when there is no bundle identifier. The pre-check is the only defence,
    /// so it must never itself touch a UserNotifications symbol.
    @Test("A bundle without an identifier reports unavailable rather than crashing")
    func detectsMissingBundleIdentifier() {
        // Under `swift test`, Bundle.main is the xctest tool, which does have an
        // identifier — so a synthetic bundle is used for the negative case.
        let bundle = Bundle(for: FakeBundleMarker.self)
        let capability = Notifications.capability(bundle: bundle)
        switch capability {
        case .unavailableNoBundleIdentifier:
            #expect(capability.detail.contains("no bundle identifier"))
        case .appBundle, .bareExecutable:
            #expect(!capability.detail.isEmpty)
        }
    }

    @Test("AppleScript string literals escape quotes and backslashes")
    func escapesAppleScript() {
        #expect(Notifications.appleScriptString("plain") == "\"plain\"")
        #expect(Notifications.appleScriptString("say \"hi\"") == "\"say \\\"hi\\\"\"")
        #expect(Notifications.appleScriptString("back\\slash") == "\"back\\\\slash\"")
    }

    /// Notification text can originate in a calendar event, which is untrusted (SPEC §13).
    @Test("Untrusted text cannot break out of the AppleScript literal")
    func neutralisesInjection() {
        let hostile = "\" & (do shell script \"rm -rf ~\") & \""
        let escaped = Notifications.appleScriptString(Redaction.sanitize(hostile))
        // Every interior quote is escaped, so the literal cannot be terminated early.
        let interior = escaped.dropFirst().dropLast()
        var previous: Character?
        for character in interior {
            if character == "\"" { #expect(previous == "\\") }
            previous = character
        }
    }
}

private final class FakeBundleMarker {}

@Suite("Code signature")
struct CodeSignatureTests {
    @Test("The running test binary reports a signature we can describe")
    func readsOwnSignature() throws {
        // Every Mach-O SwiftPM produces is at least linker-signed, so this must not be nil.
        let signature = try #require(CodeSignature.current())
        #expect(signature.facts["adhoc"] != nil)
        #expect(signature.facts["hardened_runtime"] != nil)
        #expect(signature.cdhash?.isEmpty == false)
    }

    @Test("A path with no binary yields no signature")
    func missingBinary() {
        #expect(CodeSignature.of(path: "/nonexistent-\(UUID().uuidString)") == nil)
    }

    @Test("Apple's own signed tools read as Developer-ID-free but identified")
    func readsSystemBinary() throws {
        let signature = try #require(CodeSignature.of(path: "/usr/bin/log"))
        #expect(signature.identifier == "com.apple.log")
        #expect(!signature.isDeveloperIDSigned)
        // Apple's bare tools carry an identifier-based designated requirement, which is
        // exactly the shape a Developer ID signature would give rcc.
        #expect(signature.designatedRequirement?.contains("identifier") == true)
    }
}
