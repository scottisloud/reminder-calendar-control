import Foundation
import Testing

@testable import RCCCore

@Suite("ContentVersion & if_match")
struct ContentVersionTests {
    @Test("Same fields, same last-modified → same version")
    func deterministic() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let a = ContentVersion.make([("title", "Standup"), ("start", "09:00")], lastModified: date)
        let b = ContentVersion.make([("title", "Standup"), ("start", "09:00")], lastModified: date)
        #expect(a == b)
        #expect(a.count == 64)  // sha-256 hex
    }

    @Test("Any content change moves the version")
    func sensitive() {
        let base = ContentVersion.make([("title", "Standup"), ("notes", "")])
        #expect(ContentVersion.make([("title", "Sync"), ("notes", "")]) != base)
        #expect(ContentVersion.make([("title", "Standup"), ("notes", "x")]) != base)
    }

    @Test("Field order is significant — the caller fixes it")
    func orderMatters() {
        #expect(
            ContentVersion.make([("a", "1"), ("b", "2")])
                != ContentVersion.make([("b", "2"), ("a", "1")])
        )
    }

    @Test("A separator in a value cannot forge a different field boundary")
    func separatorSafety() {
        // The unit separator (U+001F) is what joins fields; a literal one in a value
        // must not let "a=1<US>b=2" masquerade as two fields.
        let sneaky = ContentVersion.make([("a", "1\u{1f}b=2")])
        let real = ContentVersion.make([("a", "1"), ("b", "2")])
        #expect(sneaky != real)
    }

    @Test("last-modified participates only when supplied")
    func lastModifiedOptional() {
        let withDate = ContentVersion.make([("t", "x")], lastModified: Date(timeIntervalSince1970: 1))
        let without = ContentVersion.make([("t", "x")])
        #expect(withDate != without)
        // A source that never populates it is stable on content alone.
        #expect(ContentVersion.make([("t", "x")]) == ContentVersion.make([("t", "x")]))
    }

    @Test("if_match check: matches, stale, not provided")
    func ifMatch() {
        #expect(IfMatch.check(provided: nil, current: "v1") == .notProvided)
        #expect(IfMatch.check(provided: "v1", current: "v1") == .matches)
        #expect(IfMatch.check(provided: "v0", current: "v1") == .stale(current: "v1"))
    }
}
