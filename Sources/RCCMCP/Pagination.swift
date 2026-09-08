import Foundation
import RCCCore

/// Best-effort pagination (SPEC §10).
///
/// A cursor is **not** a snapshot — `rcc` re-runs the query for every page against a
/// store with no TTL cache (§7.4), so under concurrent modification a later page can
/// duplicate or skip items. What the cursor *does* carry is the store generation it was
/// issued under: if the overall EventKit change-generation has advanced, the next page is
/// refused with `cursor_stale` rather than returning a quietly mismatched slice. Claude is
/// expected to treat a paginated result as approximate under concurrent edits and re-query
/// from scratch for a guaranteed-consistent view.
public struct PageCursor: Codable, Equatable, Sendable {
    public var offset: Int
    public var generation: Int

    public init(offset: Int, generation: Int) {
        self.offset = offset
        self.generation = generation
    }

    /// base64url of the JSON, no padding. Opaque to the client.
    public func encoded() -> String {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ string: String) -> PageCursor? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONDecoder().decode(PageCursor.self, from: data)
    }
}

public enum PaginationError: Error, Equatable {
    /// The cursor did not decode, or its offset is negative.
    case malformed
    /// The store has changed generation since the cursor was issued.
    case stale
}

/// Slice `items` for the page the caller asked for, and describe what comes next.
public struct Page<Item>: Sendable where Item: Sendable {
    public let items: [Item]
    public let nextCursor: String?
    public let totalMatched: Int

    public var hasMore: Bool { nextCursor != nil }

    /// - Parameters:
    ///   - all: the full, already-ordered result of re-running the query.
    ///   - limit: page size, clamped to `1...maxLimit`.
    ///   - cursor: the caller's cursor string, or `nil` for the first page.
    ///   - currentGeneration: the store's generation right now.
    public init(
        all: [Item],
        limit: Int,
        cursor: String?,
        currentGeneration: Int,
        maxLimit: Int = 200
    ) throws {
        let pageSize = max(1, min(limit, maxLimit))

        let offset: Int
        if let cursor {
            guard let decoded = PageCursor.decode(cursor), decoded.offset >= 0 else {
                throw PaginationError.malformed
            }
            guard decoded.generation == currentGeneration else {
                throw PaginationError.stale
            }
            offset = decoded.offset
        } else {
            offset = 0
        }

        totalMatched = all.count
        let start = min(offset, all.count)
        let end = min(start + pageSize, all.count)
        items = Array(all[start..<end])
        nextCursor = end < all.count
            ? PageCursor(offset: end, generation: currentGeneration).encoded()
            : nil
    }
}
