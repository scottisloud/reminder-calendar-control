import AppKit
import Foundation

/// The running Claude Desktop app — only so `rcc setup` can offer to restart it.
///
/// Desktop reads `claude_desktop_config.json` once at launch, so a fresh registration (or a
/// new binary behind an existing one) takes effect only after a full quit and relaunch.
/// Quitting is a polite `terminate()`, the same as ⌘Q: Desktop gets to save state and may
/// refuse, in which case nothing is forced.
public enum ClaudeDesktopApp {
    public static let bundleIdentifier = "com.anthropic.claudefordesktop"

    public static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    public enum RestartOutcome: Equatable {
        case restarted
        /// Desktop did not quit within the timeout (an unsaved-work prompt, say).
        case didNotQuit
        case couldNotRelaunch(String)
    }

    public static func restart(timeout: TimeInterval = 20) -> RestartOutcome {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        let appURL = running.first?.bundleURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        for app in running { app.terminate() }

        let deadline = Date().addingTimeInterval(timeout)
        while isRunning {
            guard Date() < deadline else { return .didNotQuit }
            Thread.sleep(forTimeInterval: 0.25)
        }
        guard let appURL else { return .couldNotRelaunch("Claude.app not found") }
        // `open` rather than NSWorkspace.openApplication: the latter needs a main run loop
        // to deliver its completion, and setup's AppKit pump has already finished.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [appURL.path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .couldNotRelaunch(error.localizedDescription)
        }
        return process.terminationStatus == 0 ? .restarted : .couldNotRelaunch("open exited \(process.terminationStatus)")
    }
}
