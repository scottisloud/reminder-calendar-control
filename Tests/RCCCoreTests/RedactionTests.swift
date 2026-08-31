import Foundation
import Testing

@testable import RCCCore

@Suite("Redaction")
struct RedactionTests {
    @Test("Control characters are replaced, not dropped")
    func stripsControlCharacters() {
        // A space rather than "" so removed characters cannot silently join two tokens
        // into a third that reads as something else.
        #expect(Redaction.sanitize("a\u{0}b") == "a b")
        #expect(Redaction.sanitize("line1\nline2") == "line1 line2")
        #expect(Redaction.sanitize("tab\there") == "tab here")
        #expect(Redaction.sanitize("bell\u{7}x") == "bell x")
    }

    @Test("ANSI escape sequences cannot forge terminal output")
    func defusesAnsi() {
        let forged = "\u{1B}[2K\u{1B}[1;31mAPPROVED\u{1B}[0m"
        let sanitized = Redaction.sanitize(forged)
        #expect(!sanitized.contains("\u{1B}"))
        #expect(sanitized.contains("APPROVED"))
    }

    @Test("Bidi overrides and zero-width characters are removed")
    func defusesBidiAndInvisibles() {
        for scalar in ["\u{202E}", "\u{2066}", "\u{200B}", "\u{FEFF}", "\u{2028}"] {
            let sanitized = Redaction.sanitize("a\(scalar)b")
            #expect(!sanitized.unicodeScalars.contains { $0 == Unicode.Scalar(scalar.unicodeScalars.first!) })
        }
    }

    @Test("Truncation counts graphemes, so it cannot split a cluster")
    func truncatesOnGraphemeBoundaries() {
        let flags = String(repeating: "🇬🇧", count: 20)
        let sanitized = Redaction.sanitize(flags, limit: 5)
        #expect(sanitized == String(repeating: "🇬🇧", count: 5) + "…")
    }

    @Test("Short strings pass through untouched")
    func leavesOrdinaryTextAlone() {
        #expect(Redaction.sanitize("Team standup") == "Team standup")
    }

    @Test("Redaction hides content but keeps a correlatable shape")
    func redactsContent() {
        let redacted = Redaction.redact("Dinner with Sam at 7")
        #expect(!redacted.contains("Sam"))
        #expect(redacted.hasPrefix("<redacted:20c:"))
        // Same input, same fingerprint — that is what makes a log correlatable.
        #expect(redacted == Redaction.redact("Dinner with Sam at 7"))
        #expect(redacted != Redaction.redact("Dinner with Sal at 7"))
    }

    @Test("nil and empty are distinguishable in a log")
    func distinguishesNilFromEmpty() {
        #expect(Redaction.redact(nil) == "<nil>")
        #expect(Redaction.redact("") == "<empty>")
    }

    @Test("Fingerprints are eight lowercase hex digits")
    func fingerprintShape() {
        let fingerprint = Redaction.fingerprint("anything")
        #expect(fingerprint.count == 8)
        #expect(fingerprint.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }
}
