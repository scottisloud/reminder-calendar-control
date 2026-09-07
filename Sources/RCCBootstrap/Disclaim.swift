import CDisclaim
import Darwin
import Foundation
import os
import RCCCore

/// TCC "responsible process" reattribution (SPEC §6.1, §6.2, §8.1).
///
/// When Claude Desktop spawns `rcc`, macOS attributes `rcc`'s Calendar/Reminders request
/// to Claude Desktop, whose own `Info.plist` declares no usage strings — so the request
/// fails with no prompt. The fix is to make `rcc` the responsible process for itself,
/// which can only be set as a spawn attribute, which means `rcc` must re-exec itself
/// once at startup.
///
/// **Must be the first thing `main` does**, before Foundation opens a log file, before
/// EventKit or UserNotifications cache an audit token, and before any `O_CLOEXEC`
/// descriptor is opened (those do not survive the image replacement).
public enum Disclaim {
    /// Environment key carrying the re-exec generation.
    ///
    /// The value is `"<pid>:<generation>"`, not a bare `1`. That matters: with a plain
    /// boolean sentinel, a parent that happens to export the same variable makes `rcc`
    /// skip the disclaim while believing it succeeded — verified on macOS 26.6.2, where
    /// `env __RCC_DISCLAIMED=1 ./probe` ran fully undisclaimed and still reported
    /// success. `POSIX_SPAWN_SETEXEC` preserves the pid, so binding the sentinel to
    /// `getpid()` makes an inherited value provably foreign.
    public static let generationEnvironmentKey = "__RCC_DISCLAIM_GEN"

    public enum Outcome: String, Sendable {
        /// Re-executed once and the process is now responsible for itself. The only
        /// healthy outcome.
        case disclaimed
        /// Re-executed, but TCC still attributes us to an ancestor. The SPI accepted the
        /// attribute and did nothing. `rcc` fails closed rather than running
        /// misattributed (SPEC §6.2).
        case notDisclaimed
        /// The private symbols are gone from this OS. No fallback exists by design.
        case mechanismUnavailable
        /// The symbols resolved but rejected the request. Distinct from
        /// `mechanismUnavailable`: "the OS removed this" and "the OS refused this call" call
        /// for different investigations, and reporting the second as the first sends an
        /// operator looking for the wrong thing.
        case mechanismRejected
        /// `posix_spawn` itself failed.
        case spawnFailed
        /// Could not resolve our own executable path.
        case pathUnresolved
        /// A generation above 1 was observed — the guard leaked, or a caller forged a
        /// pid-matching sentinel. Treated as untrusted, same as `notDisclaimed`.
        case guardViolated
        /// DIAGNOSTIC ONLY (milestone-1b): the disclaim was deliberately skipped because
        /// `RCC_DISCLAIM=0` was set in the environment. Used to test whether a properly
        /// signed `rcc` still needs the disclaim at all on macOS 26. Not a production path.
        case bypassed

        public var isHealthy: Bool { self == .disclaimed || self == .bypassed }

        public var remediation: String? {
            switch self {
            case .disclaimed:
                return nil
            case .bypassed:
                return "DIAGNOSTIC BUILD: the self-disclaim was skipped (RCC_DISCLAIM=0). "
                    + "TCC attribution falls to whatever launched rcc. Unset RCC_DISCLAIM for "
                    + "normal behaviour."
            case .mechanismRejected:
                return "responsibility_spawnattrs_setdisclaim is present on this system but rejected "
                    + "the request. This is not the symbol having been removed; something about the "
                    + "spawn attributes or the caller was refused. `rcc doctor --json` records the "
                    + "raw outcome."
            case .notDisclaimed, .guardViolated:
                return "TCC still attributes rcc's requests to the process that launched it, so a "
                    + "Calendar/Reminders prompt will never name rcc. This usually means the OS "
                    + "changed the behaviour of the disclaim SPI. rcc will not run TCC-sensitive "
                    + "commands in this state."
            case .mechanismUnavailable:
                return "This macOS build no longer exports responsibility_spawnattrs_setdisclaim. "
                    + "There is deliberately no fallback: rcc would otherwise request access under "
                    + "another application's identity. A new approach is required."
            case .spawnFailed:
                return "rcc could not re-execute itself. Check that the binary at the install path "
                    + "is readable and executable, and that it has not been replaced mid-run."
            case .pathUnresolved:
                return "rcc could not determine its own executable path."
            }
        }
    }

    public struct Result: Sendable {
        public let outcome: Outcome
        /// 0 = original image, 1 = the disclaimed replacement. Never legitimately higher.
        public let generation: Int
        /// What TCC currently holds responsible for this process. Equal to our own pid
        /// exactly when the disclaim took effect.
        public let responsiblePID: pid_t
        public let pid: pid_t
        /// Whether the private symbols resolved at all.
        public let mechanismAvailable: Bool
        /// Set when `posix_spawn` failed; carries its return value, which *is* the errno
        /// (`posix_spawn` returns it rather than setting the global).
        public let spawnErrno: Int32?

        public init(
            outcome: Outcome, generation: Int, responsiblePID: pid_t,
            pid: pid_t, mechanismAvailable: Bool, spawnErrno: Int32? = nil
        ) {
            self.outcome = outcome
            self.generation = generation
            self.responsiblePID = responsiblePID
            self.pid = pid
            self.mechanismAvailable = mechanismAvailable
            self.spawnErrno = spawnErrno
        }

        public var isSelfResponsible: Bool { responsiblePID == pid }
    }

    /// The result of the one `ensure()` call this process makes.
    ///
    /// Every TCC-sensitive command reads this instead of re-running the mechanism.
    nonisolated(unsafe) public private(set) static var result: Result?

    private static let logger = Logger(subsystem: RCCPaths.bundleIdentifier, category: "disclaim")

    /// Run the disclaim handshake exactly once per process.
    ///
    /// On the first image this does not return: `POSIX_SPAWN_SETEXEC` replaces the
    /// process image in place, so control resumes at the top of `main` in the same pid,
    /// this time with the sentinel set. Anything after the `posix_spawn` call is the
    /// error path.
    @discardableResult
    public static func ensure() -> Result {
        if let result { return result }

        // DIAGNOSTIC (milestone-1b): RCC_DISCLAIM=0 skips the disclaim entirely so we can
        // test whether a properly signed rcc still needs it on macOS 26. Loud on stderr so
        // it can never be mistaken for normal operation.
        if ProcessInfo.processInfo.environment["RCC_DISCLAIM"] == "0" {
            let pid = getpid()
            let warning = "RCC_DISCLAIM=0 — self-disclaim SKIPPED (diagnostic build). "
                + "TCC attribution falls to the launching process.\n"
            warning.withCString { _ = write(STDERR_FILENO, $0, strlen($0)) }
            return finish(Result(
                outcome: .bypassed, generation: 0,
                responsiblePID: rcc_responsible_pid(pid), pid: pid,
                mechanismAvailable: rcc_disclaim_available() == 1, spawnErrno: nil
            ))
        }

        let pid = getpid()
        let generation = readGeneration(for: pid)
        let available = rcc_disclaim_available() == 1

        if generation == 0 {
            // First image. Re-exec unconditionally rather than skipping when we already
            // look self-responsible: a context-dependent branch here would mean the
            // launch contexts SPEC §18 requires testing do not actually exercise the
            // same code path, which is exactly how TCC bugs hide.
            guard available else {
                return finish(Result(
                    outcome: .mechanismUnavailable, generation: 0,
                    responsiblePID: rcc_responsible_pid(pid), pid: pid,
                    mechanismAvailable: false, spawnErrno: nil
                ))
            }
            return reexec(pid: pid, nextGeneration: 1)
        }

        // Second image (or a forged sentinel). Never re-exec again, whatever we find.
        let responsible = rcc_responsible_pid(pid)
        let outcome = classify(generation: generation, responsiblePID: responsible, pid: pid)
        return finish(Result(
            outcome: outcome, generation: generation, responsiblePID: responsible,
            pid: pid, mechanismAvailable: available, spawnErrno: nil
        ))
    }

    // MARK: - Internals

    /// Read and consume the sentinel. Parsing lives in `parseSentinel` so the production
    /// path and the tests exercise the same code rather than two copies that can drift.
    private static func readGeneration(for pid: pid_t) -> Int {
        let raw = ProcessInfo.processInfo.environment[generationEnvironmentKey]
        // Unset immediately so the sentinel never leaks into child processes, where it
        // would make a nested `rcc` skip its own disclaim.
        unsetenv(generationEnvironmentKey)
        return parseSentinel(raw, pid: pid)
    }

    private static func reexec(pid: pid_t, nextGeneration: Int) -> Result {
        guard let executablePath = canonicalExecutablePath() else {
            return finish(Result(
                outcome: .pathUnresolved, generation: 0, responsiblePID: rcc_responsible_pid(pid),
                pid: pid, mechanismAvailable: true, spawnErrno: nil
            ))
        }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            return finish(Result(
                outcome: .spawnFailed, generation: 0, responsiblePID: rcc_responsible_pid(pid),
                pid: pid, mechanismAvailable: true, spawnErrno: nil
            ))
        }
        defer { posix_spawnattr_destroy(&attributes) }

        // SETEXEC replaces this image in place: same pid, same fds (bar FD_CLOEXEC ones),
        // same cwd, same process group, same signal mask.
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETEXEC)) == 0 else {
            return finish(Result(
                outcome: .spawnFailed, generation: 0, responsiblePID: rcc_responsible_pid(pid),
                pid: pid, mechanismAvailable: true, spawnErrno: nil
            ))
        }
        // The shim returns -1 only when the symbol did not resolve; any other nonzero value
        // is the SPI's own rejection, which is a different problem.
        let disclaimStatus = rcc_spawnattrs_setdisclaim(&attributes, 1)
        guard disclaimStatus == 0 else {
            let symbolMissing = disclaimStatus == -1
            return finish(Result(
                outcome: symbolMissing ? .mechanismUnavailable : .mechanismRejected,
                generation: 0,
                responsiblePID: rcc_responsible_pid(pid), pid: pid,
                mechanismAvailable: !symbolMissing, spawnErrno: symbolMissing ? nil : disclaimStatus
            ))
        }

        emit(level: .debug, "reexec", [
            "gen": String(nextGeneration), "pid": String(pid), "path": executablePath,
        ])

        var argv: [UnsafeMutablePointer<CChar>?] = CommandLine.arguments.map { strdup($0) }
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] = currentEnvironment(
            adding: "\(generationEnvironmentKey)=\(pid):\(nextGeneration)"
        ).map { strdup($0) }
        envp.append(nil)
        defer {
            for pointer in argv where pointer != nil { free(pointer) }
            for pointer in envp where pointer != nil { free(pointer) }
        }

        // Buffered stdio is discarded by the image replacement; flush before handing over.
        fflush(nil)

        let status = posix_spawn(nil, executablePath, nil, &attributes, argv, envp)

        // Reaching this line at all means the spawn failed: with `POSIX_SPAWN_SETEXEC` the
        // image is replaced on success, so `posix_spawn` never returns. `posix_spawn` returns
        // the errno instead of setting it, so `perror` would print garbage.
        //
        // A return of 0 would mean SETEXEC was silently dropped and a *second* process now
        // shares our stdio — the worst possible outcome for an MCP server. Treat it as a
        // failure rather than assuming it cannot happen.
        return finish(Result(
            outcome: .spawnFailed, generation: 0, responsiblePID: rcc_responsible_pid(pid),
            pid: pid, mechanismAvailable: true, spawnErrno: status == 0 ? -1 : status
        ))
    }

    /// Our own executable, resolved through `_NSGetExecutablePath` + `realpath`.
    ///
    /// Never `argv[0]`: a caller controls it completely and it need not be a path at all.
    /// `_NSGetExecutablePath` alone is not enough either — it can return a non-canonical
    /// path containing symlinks or `..`.
    public static func canonicalExecutablePath() -> String? {
        var capacity = UInt32(PATH_MAX)
        var raw = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard _NSGetExecutablePath(&raw, &capacity) == 0 else { return nil }
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(raw, &resolved) != nil else { return nil }
        let bytes = resolved.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(validating: bytes, as: UTF8.self)
    }

    /// Snapshot `environ` directly rather than `ProcessInfo.environment`, which caches
    /// and would not reflect the `unsetenv` above.
    private static func currentEnvironment(adding entry: String) -> [String] {
        var entries: [String] = []
        let environment = environ
        var index = 0
        while let raw = environment[index] {
            let value = String(cString: raw)
            if !value.hasPrefix("\(generationEnvironmentKey)=") {
                entries.append(value)
            }
            index += 1
        }
        entries.append(entry)
        return entries
    }

    private static func finish(_ result: Result) -> Result {
        self.result = result
        emit(
            level: result.outcome.isHealthy ? .info : .error,
            "result",
            [
                "outcome": result.outcome.rawValue,
                "gen": String(result.generation),
                "pid": String(result.pid),
                "responsible": String(result.responsiblePID),
                "mechanism": result.mechanismAvailable ? "available" : "missing",
            ]
        )
        return result
    }

    private enum EmitLevel { case debug, info, error }

    /// Emits to both stderr and unified logging.
    ///
    /// stderr is what a Terminal or a LaunchAgent's `StandardErrorPath` captures; `os_log`
    /// is what survives when neither is redirected, which is the Claude Desktop case. Both
    /// carry the pid, and `POSIX_SPAWN_SETEXEC` preserves it, so the acceptance harness can
    /// count images per pid and assert exactly one re-exec (SPEC §18, Milestone 1).
    ///
    /// Uses `write(2)` rather than `print`: buffered stdio does not survive the exec, and
    /// stdout belongs to the JSON-RPC framer.
    private static func emit(level: EmitLevel, _ event: String, _ fields: [String: String]) {
        let rendered = fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        let line = "RCC_DISCLAIM event=\(event) \(rendered)\n"
        line.withCString { pointer in
            _ = write(STDERR_FILENO, pointer, strlen(pointer))
        }
        switch level {
        case .debug: logger.debug("RCC_DISCLAIM event=\(event, privacy: .public) \(rendered, privacy: .public)")
        case .info: logger.info("RCC_DISCLAIM event=\(event, privacy: .public) \(rendered, privacy: .public)")
        case .error: logger.error("RCC_DISCLAIM event=\(event, privacy: .public) \(rendered, privacy: .public)")
        }
    }

    /// Test seam: lets `RCCBootstrapTests` exercise the outcome-classification logic
    /// without re-executing the test runner.
    public static func classify(generation: Int, responsiblePID: pid_t, pid: pid_t) -> Outcome {
        if generation == 0 { return .notDisclaimed }
        if generation > 1 { return .guardViolated }
        return responsiblePID == pid ? .disclaimed : .notDisclaimed
    }

    /// Parse a sentinel value the way `ensure()` does. Exposed for tests.
    public static func parseSentinel(_ raw: String?, pid: pid_t) -> Int {
        guard let raw else { return 0 }
        let parts = raw.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let sentinelPID = pid_t(parts[0]),
              sentinelPID == pid,
              let generation = Int(parts[1]),
              generation >= 0
        else { return 0 }
        return generation
    }
}
