import Foundation

/// The `rcc doctor` data model (SPEC §6.1, §16).
///
/// Deliberately a plain value type with no I/O: the checks live in `RCCPlatform` and
/// `RCCCalendar`, which lets them be unit-tested against a fake and lets `doctor` and
/// the MCP `get_system_status` tool share one renderer.
public struct HealthReport: Sendable {
    public enum Status: String, Sendable, Comparable {
        /// Working as intended.
        case ok
        /// Working, but something an operator should know about.
        case warn
        /// Broken. `rcc doctor` exits non-zero if any check is `fail`.
        case fail
        /// Could not be determined — distinct from `fail` so "we did not check" is never
        /// silently reported as "we checked and it is fine".
        case unknown
        /// Deliberately not applicable in this configuration (e.g. Tier 1 not enabled).
        case skipped

        private var rank: Int {
            switch self {
            case .ok: return 0
            case .skipped: return 1
            case .unknown: return 2
            case .warn: return 3
            case .fail: return 4
            }
        }

        public static func < (lhs: Status, rhs: Status) -> Bool { lhs.rank < rhs.rank }
    }

    public struct Check: Sendable {
        public let id: String
        public let title: String
        public let status: Status
        public let detail: String
        /// What the operator should do. Present whenever status is `warn` or `fail`.
        public let remediation: String?
        /// Machine-readable extras, surfaced verbatim under `--json`.
        public let facts: [String: String]

        public init(
            id: String,
            title: String,
            status: Status,
            detail: String,
            remediation: String? = nil,
            facts: [String: String] = [:]
        ) {
            self.id = id
            self.title = title
            self.status = status
            self.detail = detail
            self.remediation = remediation
            self.facts = facts
        }
    }

    public let generatedAt: Date
    public let checks: [Check]

    public init(generatedAt: Date = Date(), checks: [Check]) {
        self.generatedAt = generatedAt
        self.checks = checks
    }

    /// The worst applicable status. A `skipped` check is not applicable by definition, so it
    /// does not drag a healthy install down to "SKIPPED" (as an absent `--dev` fixture did);
    /// only an all-skipped report is overall `skipped`.
    public var overall: Status {
        let applicable = checks.map(\.status).filter { $0 != .skipped }
        if applicable.isEmpty { return checks.isEmpty ? .unknown : .skipped }
        return applicable.max() ?? .unknown
    }

    /// Any check that outright failed. `unknown` is not a failure — it means the check
    /// could not run — but it is never reported as `ok` either.
    public var hasFailures: Bool {
        checks.contains { $0.status == .fail }
    }

    /// "Healthy" for the purposes of SPEC §18's Milestone 1 gate: nothing failed.
    /// Warnings are surfaced loudly but do not make the install unusable — an ad-hoc
    /// signature, for instance, warns without breaking anything locally.
    public var isHealthy: Bool { !hasFailures }

    public func jsonObject() -> [String: Any] {
        [
            "schema_version": 1,
            "generated_at": RCCTime.instant(generatedAt),
            "overall": overall.rawValue,
            "rcc_version": BuildInfo.versionString,
            "checks": checks.map { check -> [String: Any] in
                var object: [String: Any] = [
                    "id": check.id,
                    "title": check.title,
                    "status": check.status.rawValue,
                    "detail": check.detail,
                ]
                if let remediation = check.remediation { object["remediation"] = remediation }
                if !check.facts.isEmpty { object["facts"] = check.facts }
                return object
            },
        ]
    }

    /// Human-readable rendering. One line per check, remediation indented beneath.
    public func renderText() -> String {
        var lines: [String] = []
        lines.append("rcc doctor — \(BuildInfo.versionString)")
        lines.append("overall: \(overall.rawValue.uppercased())")
        lines.append("")
        let width = checks.map(\.title.count).max() ?? 0
        for check in checks {
            let marker: String
            switch check.status {
            case .ok: marker = "ok  "
            case .warn: marker = "warn"
            case .fail: marker = "FAIL"
            case .unknown: marker = "?   "
            case .skipped: marker = "--  "
            }
            let padded = check.title.padding(toLength: max(width, check.title.count), withPad: " ", startingAt: 0)
            lines.append("[\(marker)] \(padded)  \(check.detail)")
            if let remediation = check.remediation {
                for line in remediation.split(separator: "\n", omittingEmptySubsequences: false) {
                    lines.append("         → \(line)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }
}
