import Foundation

/// Stable, category-distinct process exit codes (SPEC §16).
///
/// These are part of `rcc`'s public contract: scripts, the acceptance harness, and
/// `launchd` all branch on them. Never renumber an existing case.
public enum RCCExitCode: Int32, Sendable, CaseIterable {
    /// Command completed successfully.
    case ok = 0
    /// Catch-all internal failure — a bug in `rcc`, not the environment.
    case internalError = 1
    /// Caller error: bad flags, bad arguments, malformed input.
    case usage = 2
    /// TCC/authorization problem: not determined, denied, or restricted.
    case permission = 3
    /// Network or remote-API failure (Tier 1 model calls, notarization checks).
    case network = 4
    /// Input passed argument parsing but failed semantic validation.
    case validation = 5
    /// Local state is unusable: SQLite open/migration failure, unreadable state dir.
    case state = 6
    /// Install topology is broken: missing binary, path mismatch, LaunchAgent drift.
    case install = 7
    /// The self-disclaim mechanism is unavailable, so TCC attribution cannot be
    /// established. `rcc` deliberately fails closed here rather than running
    /// misattributed (SPEC §6.2 degradation path).
    case disclaimUnavailable = 8
    /// `rcc doctor` ran to completion but found at least one unhealthy check.
    case unhealthy = 9

    public var label: String {
        switch self {
        case .ok: return "ok"
        case .internalError: return "internal"
        case .usage: return "usage"
        case .permission: return "permission"
        case .network: return "network"
        case .validation: return "validation"
        case .state: return "state"
        case .install: return "install"
        case .disclaimUnavailable: return "disclaim_unavailable"
        case .unhealthy: return "unhealthy"
        }
    }
}

/// An error that carries the process exit code `rcc` should terminate with.
public struct RCCError: Error, CustomStringConvertible, Sendable {
    public let exitCode: RCCExitCode
    public let message: String
    /// Operator-facing next step. Kept separate from `message` so `--json` output can
    /// expose it as its own field rather than making callers parse prose.
    public let remediation: String?

    public init(_ exitCode: RCCExitCode, _ message: String, remediation: String? = nil) {
        self.exitCode = exitCode
        self.message = message
        self.remediation = remediation
    }

    public var description: String {
        guard let remediation else { return message }
        return "\(message)\n\nTo fix: \(remediation)"
    }
}
