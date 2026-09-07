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
