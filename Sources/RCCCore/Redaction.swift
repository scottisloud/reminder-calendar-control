import Foundation

/// Sanitisation applied to every piece of calendar-derived text before it reaches a
/// log file, a notification, or an approval preview (SPEC §13, §14).
///
/// Two separate jobs, deliberately kept separate:
///
/// * `sanitize` neutralises *rendering* hazards — control characters, bidi overrides,
///   ANSI escapes — so untrusted calendar text cannot forge log lines or rewrite what
///   an operator sees in a terminal before they approve something.
/// * `redact` enforces *minimisation* — user content never lands in a log by default.
///
/// Sanitising is always applied. Redaction is the default and is lifted only when the
/// operator explicitly asks for content (`RCC_LOG_CONTENT=1`).
public enum Redaction {
    /// Default cap for any single sanitised string.
    public static let defaultLimit = 240

    /// Whether user content may appear in logs. Off unless explicitly enabled.
    public static var contentLoggingEnabled: Bool {
        ProcessInfo.processInfo.environment["RCC_LOG_CONTENT"] == "1"
    }

    /// Strip control characters, collapse newlines, defuse bidi/ANSI, and truncate.
    ///
    /// Truncation counts Characters (grapheme clusters), not UTF-16 units, so a string
    /// of emoji or combining marks cannot be cut mid-grapheme.
    public static func sanitize(_ raw: String, limit: Int = defaultLimit) -> String {
        var out = String.UnicodeScalarView()
        out.reserveCapacity(raw.unicodeScalars.count)
        for scalar in raw.unicodeScalars {
            if isHazardous(scalar) {
                // A space, not "", so removed characters cannot silently join two
                // tokens into a third one that reads as something else.
                out.append(" ")
            } else {
                out.append(scalar)
            }
        }
        let collapsed = String(out)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)) + "…"
    }

    /// Replace user content with a shape-preserving placeholder.
    ///
    /// The length and a truncated SHA-ish fingerprint are kept because they are what
    /// makes a log actionable ("the title was 43 chars and identical across both runs")
    /// without disclosing the text itself.
    public static func redact(_ raw: String?, limit: Int = defaultLimit) -> String {
        guard let raw else { return "<nil>" }
        if contentLoggingEnabled { return sanitize(raw, limit: limit) }
        if raw.isEmpty { return "<empty>" }
        return "<redacted:\(raw.count)c:\(fingerprint(raw))>"
    }

    /// Short, stable, non-reversible fingerprint. FNV-1a is used deliberately: this is
    /// a log-correlation aid, never an integrity or authentication mechanism.
    public static func fingerprint(_ value: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100_0000_01b3
        }
        return String(format: "%08x", UInt32(truncatingIfNeeded: hash))
    }

    private static func isHazardous(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        // C0 controls (including newline, tab, and ESC) and DEL.
        case 0x00...0x1F, 0x7F:
            return true
        // C1 controls.
        case 0x80...0x9F:
            return true
        // Bidirectional overrides/isolates — the classic "trojan source" trick.
        case 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069:
            return true
        // Zero-width and other invisible formatting characters.
        case 0x200B...0x200D, 0xFEFF:
            return true
        // Unicode line/paragraph separators.
        case 0x2028, 0x2029:
            return true
        default:
            return false
        }
    }
}
