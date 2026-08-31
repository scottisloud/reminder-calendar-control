import Foundation
import RCCCore

/// User notifications from a bare, non-`.app` executable (SPEC §6.1, §8.3).
///
/// Notifications are advisory only: SPEC §8.3 is explicit that delivery never gates
/// whether a staged action happened, and a notification is never itself an approval. That
/// matters here, because a headless tool's options are genuinely poor:
///
/// * `UNUserNotificationCenter.current()` **aborts the process** when the executable has
///   no bundle identifier — and the abort is uncatchable, even from Objective-C `@try`,
///   because it unwinds through libdispatch's `_dispatch_client_callout`, which calls
///   `objc_terminate()`. The only defence is not calling it.
/// * Even *with* an embedded `Info.plist`, a bundle-less client's authorization status
///   stays `notDetermined`, `add()` returns `UNErrorDomain` 1, and the error text degrades
///   to `(null)`. Apple does not support that path.
///
/// So v1 delivers through `osascript`, and reports honestly that the notification is
/// attributed to Script Editor rather than to `rcc`. A signed helper `.app` is the real
/// fix and is deliberately deferred with the rest of the bundling question (SPEC §3).
public enum Notifications {
    public enum Capability: Equatable {
        /// `UNUserNotificationCenter.current()` would abort. Never call it.
        case unavailableNoBundleIdentifier
        /// Running from a real `.app`, so the modern API would work.
        case appBundle(String)
        /// A bare executable with an embedded plist: identity exists, but the
        /// UserNotifications path is still unsupported.
        case bareExecutable(String)

        public var detail: String {
            switch self {
            case .unavailableNoBundleIdentifier:
                return "unavailable — no bundle identifier, so UserNotifications would abort the process"
            case .appBundle(let identifier):
                return "available via app bundle \(identifier)"
            case .bareExecutable(let identifier):
                return "delivered via osascript; bare executable \(identifier) cannot use UserNotifications"
            }
        }
    }

    /// Safe to call anywhere: touches no UserNotifications symbol.
    public static func capability(bundle: Bundle = .main) -> Capability {
        guard let identifier = bundle.bundleIdentifier, !identifier.isEmpty else {
            return .unavailableNoBundleIdentifier
        }
        // `bundleURL` is the `.app` for a bundled binary and the *containing directory*
        // for a bare executable, which is what distinguishes the two.
        if bundle.bundleURL.pathExtension == "app" {
            return .appBundle(identifier)
        }
        return .bareExecutable(identifier)
    }

    public enum DeliveryResult: Equatable {
        case delivered
        case failed(String)
    }

    /// Post an advisory notification. Never throws; failure is reported, not propagated.
    ///
    /// Title and body go through `Redaction.sanitize` first: this text can originate in a
    /// calendar event, and a raw newline or ANSI escape in an AppleScript string literal is
    /// both a rendering hazard and an injection one.
    @discardableResult
    public static func post(title: String, body: String) -> DeliveryResult {
        let safeTitle = Redaction.sanitize(title, limit: 120)
        let safeBody = Redaction.sanitize(body, limit: 240)

        let script = "display notification \(appleScriptString(safeBody)) with title \(appleScriptString(safeTitle))"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return .failed("could not run osascript: \(error.localizedDescription)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let output = String(data: data, encoding: .utf8) ?? ""
            return .failed("osascript exited \(process.terminationStatus): \(Redaction.sanitize(output))")
        }
        // Deliberately not "delivered, confirmed": osascript exits 0 even when the
        // notification is suppressed because the user has Script Editor notifications
        // switched off. There is no observable that distinguishes the two.
        Log.shared.debug("notification.posted", ["title": .content(title)])
        return .delivered
    }

    /// Quote for an AppleScript string literal. Backslash and double-quote are the only
    /// two characters that need escaping once control characters are already stripped.
    static func appleScriptString(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count + 2)
        escaped.append("\"")
        for character in value {
            if character == "\\" || character == "\"" { escaped.append("\\") }
            escaped.append(character)
        }
        escaped.append("\"")
        return escaped
    }
}
