import CryptoKit
import Foundation

/// Server-issued identifiers and content hashes (SPEC §9.4).
public enum RCCID {
    /// An operation-journal id. A plain UUID is fine here — it identifies a row, it does
    /// not gate access to anything.
    public static func operation() -> String {
        UUID().uuidString
    }

    /// An opaque locator handle: 160 bits of randomness, lowercase hex, no delimiters or
    /// structure. SPEC §9.4 requires that a caller — or prompt-injected model output —
    /// cannot fabricate or tamper with one, which rules out anything a client could decode
    /// and re-encode. It carries no meaning; the row it keys carries everything.
    public static func locatorHandle() -> String {
        var bytes = [UInt8](repeating: 0, count: 20)
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 of a canonical string, lowercase hex. Used for `operation_hash` and, later,
    /// the `version` a mutable DTO carries for `if_match`.
    public static func hash(_ canonical: String) -> String {
        SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// The `version` a mutable DTO carries for optimistic concurrency (SPEC §9.4).
///
/// "A hash of canonical content fields, combined with `lastModifiedDate` when EventKit
/// provides it." Re-resolving a locator only proves the target still exists; comparing
/// `version` is what proves it is unchanged. `update_*` / `delete_*` / staged-approval
/// execution require an `if_match: <version>`; a mismatch is `conflict`.
public enum ContentVersion {
    /// Build a version from an ordered list of `field: value` pairs. The caller controls
    /// the order and is responsible for including everything a mutation could change;
    /// `lastModified` is appended when present.
    ///
    /// A source that does not populate `lastModifiedDate` (or reports it at low precision)
    /// passes `lastModified: nil` — the version then rests on the content hash alone. That
    /// is documented per-source rather than silently treated as "always matches".
    public static func make(_ fields: [(String, String)], lastModified: Date? = nil) -> String {
        // Each field is reduced to two fixed-width hashes before anything is joined, so a
        // separator or `=` inside a *value* cannot shift a field boundary and forge a
        // different content.
        var parts = fields.map { "\(RCCID.hash($0.0)):\(RCCID.hash($0.1))" }
        if let lastModified {
            parts.append("lastModified:\(RCCID.hash(RCCTime.instant(lastModified)))")
        }
        return RCCID.hash(parts.joined(separator: "|"))
    }
}

/// The result of checking a caller's `if_match` against a target's current `version`.
public enum IfMatch: Sendable, Equatable {
    /// The caller supplied no `if_match`. Callers that require one (every mutation) treat
    /// this as a usage error before they get here; this case exists for read paths.
    case notProvided
    case matches
    /// The target exists but has changed since the caller last saw it → `conflict`.
    case stale(current: String)

    public static func check(provided: String?, current: String) -> IfMatch {
        guard let provided else { return .notProvided }
        return provided == current ? .matches : .stale(current: current)
    }
}
