import Darwin
import Foundation
import RCCCore

/// Owns the JSON-RPC side of stdio for `rcc serve` (SPEC §10.1).
///
/// stdout is reserved exclusively for protocol frames. Rather than auditing every call
/// site for a stray `print`, `activate()` takes a private duplicate of the real stdout and
/// then points file descriptor 1 at stderr. After that, *anything* that writes to stdout —
/// our code, a Foundation warning, framework chatter we do not control — lands on stderr
/// where it is harmless.
///
/// This matters more than it looks: Swift's stdio is block-buffered when stdout is a pipe
/// (which is exactly how Claude Desktop runs us) and unbuffered through `FileHandle`, so a
/// stray line does not even reliably appear where it was emitted. Structural quarantine is
/// the only reliable fix.
public enum ProtocolIO {
    nonisolated(unsafe) private static var protocolFD: Int32 = -1
    private static let lock = NSLock()

    /// Install the quarantine. Must be the first thing `rcc serve` does.
    public static func activate() {
        lock.lock()
        defer { lock.unlock() }
        guard protocolFD < 0 else { return }

        fflush(stdout)
        let saved = dup(STDOUT_FILENO)
        precondition(saved >= 0, "could not duplicate stdout")
        precondition(dup2(STDERR_FILENO, STDOUT_FILENO) >= 0, "could not redirect stdout to stderr")
        // Never let a child process (osascript, launchctl, codesign) inherit the protocol
        // descriptor — anything it printed would land mid-frame in the JSON-RPC stream.
        _ = fcntl(saved, F_SETFD, FD_CLOEXEC)
        setvbuf(stdout, nil, _IOLBF, 0)
        protocolFD = saved

        Output.lockStdout()
    }

    /// Write one newline-delimited JSON frame.
    public static func send(_ object: [String: Any]) {
        lock.lock()
        let descriptor = protocolFD
        lock.unlock()
        guard descriptor >= 0 else { return }

        guard var data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.withoutEscapingSlashes]
        ) else {
            Log.shared.error("mcp.encode_failed")
            return
        }
        data.append(0x0A)
        writeAll(data, to: descriptor)
    }

    /// `write(2)` on a pipe returns short. Without the loop a large `tools/list` response
    /// silently truncates into invalid JSON under backpressure.
    private static func writeAll(_ data: Data, to descriptor: Int32) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = write(descriptor, base.advanced(by: offset), raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    Log.shared.error("mcp.write_failed", ["errno": .int(Int(errno))])
                    return
                }
                offset += written
            }
        }
    }

    /// Read newline-delimited frames from stdin until EOF.
    ///
    /// EOF means Claude Desktop closed the pipe; the caller exits rather than hanging.
    /// Deliberately not `readLine()`: it goes through buffered stdio, which we have just
    /// repointed, and it cannot distinguish an empty line from EOF.
    public static func readFrames(_ handle: (Data) async -> Void) async {
        var buffer = Data()
        let input = FileHandle.standardInput
        while let chunk = try? input.read(upToCount: 64 * 1024), !chunk.isEmpty {
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer = Data(buffer[buffer.index(after: newline)...])
                guard !line.isEmpty else { continue }
                await handle(line)
            }
        }
    }
}
