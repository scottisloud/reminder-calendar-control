import Foundation
import Testing

@testable import RCCMCP

@Suite("Pagination")
struct PaginationTests {
    @Test("A cursor round-trips through its opaque encoding")
    func cursorRoundTrip() throws {
        let cursor = PageCursor(offset: 120, generation: 7)
        let decoded = try #require(PageCursor.decode(cursor.encoded()))
        #expect(decoded == cursor)
        // No base64url padding or unsafe characters.
        #expect(!cursor.encoded().contains("="))
        #expect(!cursor.encoded().contains("+"))
        #expect(!cursor.encoded().contains("/"))
    }

    @Test("Garbage decodes to nil")
    func garbageCursor() {
        #expect(PageCursor.decode("not a cursor!!") == nil)
        #expect(PageCursor.decode("") == nil)
    }

    @Test("First page: no cursor, slices from zero, offers next")
    func firstPage() throws {
        let page = try Page(all: Array(1...10), limit: 3, cursor: nil, currentGeneration: 1)
        #expect(page.items == [1, 2, 3])
        #expect(page.totalMatched == 10)
        #expect(page.hasMore)
        let next = try #require(page.nextCursor.flatMap(PageCursor.decode))
        #expect(next.offset == 3)
        #expect(next.generation == 1)
    }

    @Test("Following a cursor continues where the last page stopped")
    func followCursor() throws {
        let first = try Page(all: Array(1...10), limit: 4, cursor: nil, currentGeneration: 2)
        let second = try Page(
            all: Array(1...10), limit: 4, cursor: first.nextCursor, currentGeneration: 2
        )
        #expect(second.items == [5, 6, 7, 8])
        let third = try Page(
            all: Array(1...10), limit: 4, cursor: second.nextCursor, currentGeneration: 2
        )
        #expect(third.items == [9, 10])
        #expect(!third.hasMore)
        #expect(third.nextCursor == nil)
    }

    @Test("limit is clamped to 1...maxLimit")
    func limitClamped() throws {
        #expect(try Page(all: Array(1...10), limit: 0, cursor: nil, currentGeneration: 1).items.count == 1)
        #expect(try Page(all: Array(1...10), limit: 999, cursor: nil, currentGeneration: 1, maxLimit: 5)
            .items.count == 5)
    }

    @Test("A cursor from an older generation is rejected as stale")
    func staleCursor() throws {
        let first = try Page(all: Array(1...10), limit: 3, cursor: nil, currentGeneration: 4)
        #expect(throws: PaginationError.stale) {
            _ = try Page(all: Array(1...10), limit: 3, cursor: first.nextCursor, currentGeneration: 5)
        }
    }

    @Test("A malformed cursor is rejected as malformed, not stale")
    func malformedCursor() {
        #expect(throws: PaginationError.malformed) {
            _ = try Page(all: [1, 2, 3], limit: 2, cursor: "@@@", currentGeneration: 1)
        }
    }

    @Test("An offset past the end yields an empty final page")
    func offsetPastEnd() throws {
        let cursor = PageCursor(offset: 50, generation: 1).encoded()
        let page = try Page(all: Array(1...10), limit: 5, cursor: cursor, currentGeneration: 1)
        #expect(page.items.isEmpty)
        #expect(!page.hasMore)
    }
}
