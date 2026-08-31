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
    /// Raw descriptor rather than a `FileHandle`: it is opened `O_APPEND`, which makes each
    /// `write` atomically seek to the current end of file. A `FileHandle` plus a one-time
    /// `seekToEnd()` gives every process a private, immediately-stale offset, so `rcc serve`
    /// and a `launchd`-fired `rcc automations run` would overwrite each other's lines.
    private let descriptor: Int32

    private init() {
        self.minimumLevel = Level(rawValue: ProcessInfo.processInfo.environment["RCC_LOG_LEVEL"] ?? "")
            ?? .info
        self.subsystem = Logger(subsystem: RCCPaths.bundleIdentifier, category: "rcc")
        self.descriptor = Self.openLogFile()
    }

    /// Returns -1 when unavailable. A logger that cannot open its file must not take the
    /// process down, and must never fall back to stdout.
    private static func openLogFile() -> Int32 {
        let directory = RCCPaths.logDirectory
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return -1
        }

        let url = directory.appendingPathComponent("rcc-\(RCCTime.localDay()).jsonl", isDirectory: false)
        let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return -1 }
        // An existing file keeps whatever mode it was created with, which may predate a
        // umask fix or have come from another tool. Logs carry redacted user content, so
        // tighten it every time rather than only at creation (SPEC §13).
        _ = fchmod(descriptor, 0o600)
        return descriptor
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

        if descriptor >= 0 {
            writeAll(text, to: descriptor)
        }

        switch level {
        case .debug: subsystem.debug("\(event, privacy: .public)")
        case .info: subsystem.info("\(event, privacy: .public)")
        case .warn: subsystem.warning("\(event, privacy: .public)")
        case .error: subsystem.error("\(event, privacy: .public)")
        }

        if descriptor < 0 {
            FileHandle.standardError.write(Data(text.utf8))
        }
    }

    /// One `write` per line where possible, retrying short writes and `EINTR`. `O_APPEND`
    /// makes each call atomic with respect to other processes appending to the same file.
    private func writeAll(_ text: String, to descriptor: Int32) {
        var bytes = Array(text.utf8)
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, base + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return
                }
                offset += written
            }
        }
    }

    public func debug(_ event: String, _ fields: [String: Value] = [:]) { self.event(.debug, event, fields) }
    public func info(_ event: String, _ fields: [String: Value] = [:]) { self.event(.info, event, fields) }
    public func warn(_ event: String, _ fields: [String: Value] = [:]) { self.event(.warn, event, fields) }
    public func error(_ event: String, _ fields: [String: Value] = [:]) { self.event(.error, event, fields) }
}
