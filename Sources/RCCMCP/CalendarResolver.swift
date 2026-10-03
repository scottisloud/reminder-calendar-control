import Foundation
import RCCCalendar

/// Turns what a caller wrote for a calendar or reminder list — its identifier or its name —
/// into an identifier (SPEC §10).
///
/// A name is matched case-insensitively against the calendars of the right entity type. A
/// name that matches more than one is `ambiguous_target` with the candidates listed, never
/// a guess; one that matches none is `not_found` with the names that do exist, so the
/// caller can correct itself without another round trip. Calendars are fetched once per
/// resolver, so a batch of writes costs one EventKit query.
final class CalendarResolver {
    private let repository: any CalendarRepository
    private var cache: [RCCEntityType: [CalendarSummary]] = [:]

    init(repository: any CalendarRepository) {
        self.repository = repository
    }

    func calendars(for entity: RCCEntityType) async throws -> [CalendarSummary] {
        if let cached = cache[entity] { return cached }
        let fetched = try await ReadTools.mapRepositoryError { try await repository.calendars(for: entity) }
        cache[entity] = fetched
        return fetched
    }

    /// The single calendar a write targets.
    func resolve(_ reference: String, entity: RCCEntityType) async throws -> String {
        let all = try await calendars(for: entity)
        if all.contains(where: { $0.id == reference }) { return reference }

        let matches = Self.matching(reference, in: all)
        switch matches.count {
        case 1:
            return matches[0].id
        case 0:
            let names = all.map(\.title).sorted()
            throw ToolError(
                code: "not_found",
                message: "no \(Self.noun(entity)) named '\(reference)'; available: \(names.joined(separator: ", "))"
            )
        default:
            throw ToolError(
                code: "ambiguous_target",
                message: "\(matches.count) \(Self.noun(entity))s are named '\(reference)'; pass one of their ids",
                candidates: matches.map {
                    ["id": $0.id, "title": $0.title, "source": $0.sourceTitle ?? ""]
                }
            )
        }
    }

    /// The calendars a read filter names. Every calendar a name matches is included —
    /// a read over two same-named lists is not dangerous the way a write is.
    func resolveFilter(_ references: [String]?, entity: RCCEntityType) async throws -> [String]? {
        guard let references else { return nil }
        let all = try await calendars(for: entity)
        var out: [String] = []
        for reference in references {
            if all.contains(where: { $0.id == reference }) {
                out.append(reference)
                continue
            }
            let matches = Self.matching(reference, in: all)
            guard !matches.isEmpty else {
                throw ToolError(
                    code: "not_found",
                    message: "no \(Self.noun(entity)) named '\(reference)'; available: "
                        + all.map(\.title).sorted().joined(separator: ", ")
                )
            }
            out.append(contentsOf: matches.map(\.id))
        }
        return out
    }

    /// Titles by identifier, for labelling list results. Best effort: a label is a
    /// convenience, so an entity type this process cannot read just goes unlabelled.
    func titles() async -> [String: String] {
        var out: [String: String] = [:]
        for entity in RCCEntityType.allCases {
            for calendar in (try? await calendars(for: entity)) ?? [] { out[calendar.id] = calendar.title }
        }
        return out
    }

    private static func matching(_ name: String, in calendars: [CalendarSummary]) -> [CalendarSummary] {
        let wanted = name.trimmingCharacters(in: .whitespaces)
        return calendars.filter {
            $0.title.trimmingCharacters(in: .whitespaces)
                .compare(wanted, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }

    private static func noun(_ entity: RCCEntityType) -> String {
        entity == .reminder ? "reminder list" : "calendar"
    }
}
