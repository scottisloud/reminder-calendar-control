import Foundation
import os

/// Structured, line-delimited JSON logging (SPEC §14).
///
/// Two hard rules, both load-bearing:
///
/// 1. **Nothing is ever written to stdout.** `rcc serve` reserves stdout exclusively for
///    JSON-RPC framing (SPEC §10.1); a single stray line corrupts the stream. Human
///    output from other subcommands goes through `Output`, which also avoids stdout
///    while serving.
/// 2. **Every value goes through `Redaction`.** Callers pass raw strings; the logger
///    sanitises and redacts. Making that the logger's job rather than the caller's is
///    what keeps a future call site from forgetting.
public struct Log: Sendable {
    public enum Level: String, Sendable, Comparable {
        case debug, info, warn, error

        private var rank: Int {
            switch self {
            case .debug: return 0
            case .info: return 1
            case .warn: return 2
            case .error: return 3
            }
        }

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rank < rhs.rank }
    }

    /// A log value that has already been through redaction policy.
    public enum Value: Sendable {
        /// Non-sensitive: enum names, counts, paths `rcc` itself owns, booleans.
        case safe(String)
        /// Calendar-derived or otherwise user-authored text.
        case content(String?)
        case int(Int)
        case bool(Bool)

        func rendered() -> String {
            switch self {
            case .safe(let s): return Redaction.sanitize(s)
            case .content(let s): return Redaction.redact(s)
            case .int(let i): return String(i)
            case .bool(let b): return b ? "true" : "false"
            }
        }
    }

    public static let shared = Log()

    private let minimumLevel: Level
    private let subsystem: Logger
    private let fileHandle: FileHandle?

    private init() {
        self.minimumLevel = Level(rawValue: ProcessInfo.processInfo.environment["RCC_LOG_LEVEL"] ?? "")
            ?? .info
        self.subsystem = Logger(subsystem: RCCPaths.bundleIdentifier, category: "rcc")
        self.fileHandle = Self.openLogFile()
    }

    private static func openLogFile() -> FileHandle? {
        // A logger that cannot open its file must not take the process down, and must
        // not fall back to stdout. It degrades to unified logging + stderr.
        let directory = RCCPaths.logDirectory
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return nil
        }

        let day = RCCTime.localDay()
        let url = directory.appendingPathComponent("rcc-\(day).jsonl", isDirectory: false)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(
                atPath: url.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        _ = try? handle.seekToEnd()
        return handle
    }

    public func event(
        _ level: Level,
        _ event: String,
        _ fields: [String: Value] = [:],
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        guard level >= minimumLevel else { return }

        var payload: [String: String] = [
            "ts": RCCTime.instant(),
            "level": level.rawValue,
            "event": event,
            "pid": String(ProcessInfo.processInfo.processIdentifier),
            "src": "\(file):\(line)",
        ]
        for (key, value) in fields {
            payload[key] = value.rendered()
        }

        // Sorted keys so log lines diff cleanly and tests can assert on them.
        guard
            let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            var text = String(data: data, encoding: .utf8)
        else { return }
        text.append("\n")

        if let fileHandle, let bytes = text.data(using: .utf8) {
            try? fileHandle.write(contentsOf: bytes)
        }

        switch level {
        case .debug: subsystem.debug("\(event, privacy: .public)")
        case .info: subsystem.info("\(event, privacy: .public)")
        case .warn: subsystem.warning("\(event, privacy: .public)")
        case .error: subsystem.error("\(event, privacy: .public)")
        }

        if fileHandle == nil {
            FileHandle.standardError.write(Data(text.utf8))
        }
    }

    public func debug(_ event: String, _ fields: [String: Value] = [:]) { self.event(.debug, event, fields) }
    public func info(_ event: String, _ fields: [String: Value] = [:]) { self.event(.info, event, fields) }
    public func warn(_ event: String, _ fields: [String: Value] = [:]) { self.event(.warn, event, fields) }
    public func error(_ event: String, _ fields: [String: Value] = [:]) { self.event(.error, event, fields) }
}
