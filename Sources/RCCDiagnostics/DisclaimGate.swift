import Foundation
import RCCBootstrap
import RCCCore

/// The single gate every TCC-touching entry point passes through (SPEC §6.2).
///
/// SPEC §6.2's degradation path says that when the disclaim mechanism is unavailable `rcc`
/// is *non-functional*, not silently misattributing. That has to hold for every entry
/// point, not just the interactive one: `rcc serve` is the process Claude Desktop actually
/// spawns, and the MCP self-test tool reaches EventKit without a human anywhere nearby.
public enum DisclaimGate {
    /// Throws unless the given disclaim result shows this process is TCC-responsible for
    /// itself. Takes the result rather than reading `Disclaim.result` so callers — and
    /// tests — can be explicit about which state they are gating on.
    public static func require(_ result: Disclaim.Result?) throws {
        guard let result else {
            throw RCCError(
                .internalError,
                "The disclaim mechanism did not run in this process.",
                remediation: "This is a bug: Disclaim.ensure() must be the first statement in main()."
            )
        }
        guard result.outcome.isHealthy else {
            throw RCCError(
                .disclaimUnavailable,
                "rcc cannot establish its own TCC identity (\(result.outcome.rawValue)); refusing to "
                    + "touch Calendar or Reminders.",
                remediation: result.outcome.remediation
            )
        }
    }

    /// Non-throwing form, for reporting rather than gating.
    public static func isSatisfied(_ result: Disclaim.Result?) -> Bool {
        result?.outcome.isHealthy == true
    }
}
