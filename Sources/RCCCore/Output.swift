import Foundation

/// The only sanctioned way to write to stdout.
///
/// `rcc serve` hands stdout to the JSON-RPC framer and then calls `Output.lockStdout()`,
/// after which any accidental `Output.line(...)` goes to stderr instead of corrupting
/// the protocol stream (SPEC §10.1). Plain `print()` bypasses this, which is why nothing
/// in this codebase calls it.
public enum Output {
    nonisolated(unsafe) private static var stdoutLocked = false
    private static let lock = NSLock()

    /// Called by `rcc serve` once it owns stdout.
    public static func lockStdout() {
        lock.lock()
        defer { lock.unlock() }
        stdoutLocked = true
    }

    public static var isStdoutLocked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stdoutLocked
    }

    public static func line(_ text: String) {
        write(text + "\n", to: isStdoutLocked ? FileHandle.standardError : FileHandle.standardOutput)
    }

    public static func error(_ text: String) {
        write(text + "\n", to: FileHandle.standardError)
    }

    /// Pretty-printed, key-sorted JSON — stable enough for the acceptance harness to
    /// diff and for a human to read without piping through `jq`.
    public static func json(_ value: Any) throws {
        let data = try JSONSerialization.data(
            withJSONObject: value,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        guard let text = String(data: data, encoding: .utf8) else {
            throw RCCError(.internalError, "Could not encode JSON output as UTF-8.")
        }
        line(text)
    }

    private static func write(_ text: String, to handle: FileHandle) {
        guard let data = text.data(using: .utf8) else { return }
        try? handle.write(contentsOf: data)
    }
}
