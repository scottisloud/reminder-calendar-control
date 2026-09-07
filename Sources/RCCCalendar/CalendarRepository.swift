import Foundation
import RCCCore

/// The seam between `rcc` and EventKit (SPEC §15).
///
/// EventKit has no first-party in-memory store, so everything above this protocol is
/// testable against `InMemoryCalendarRepository` and real EventKit is reserved for
/// adapter/integration tests.
///
/// Milestone 1 deliberately keeps this surface small — enough to prove authorization,
/// provision the dev fixture, and round-trip one write. The full DTO model in SPEC §9
/// lands in Milestone 2 and will widen this protocol rather than replace it.
public protocol CalendarRepository: Sendable {
    func authorizationStatus(for entityType: RCCEntityType) async -> RCCAuthorizationStatus
    /// Prompts if — and only if — status is `.notDetermined`. Returns the status after
    /// the attempt rather than a bare `Bool`, because "false" conflates "user said no"
    /// with "already denied, no prompt shown".
    func requestFullAccess(for entityType: RCCEntityType) async throws -> RCCAuthorizationStatus
    /// Discard every object fetched so far. Required after an authorization change and
    /// after `EKEventStoreChanged` (SPEC §6.2, §7.4).
    func reset() async

    func sources() async throws -> [SourceSummary]
    func calendars(for entityType: RCCEntityType) async throws -> [CalendarSummary]
    func calendar(withIdentifier identifier: String, entityType: RCCEntityType) async throws -> CalendarSummary?

    func createCalendar(title: String, entityType: RCCEntityType, sourceIdentifier: String) async throws -> CalendarSummary
    func deleteCalendar(identifier: String, entityType: RCCEntityType) async throws

    func createEvent(_ draft: EventDraft) async throws -> String
    func events(inCalendar calendarIdentifier: String, from: Date, to: Date) async throws -> [EventSummary]
    func deleteEvent(identifier: String) async throws

    func createReminder(_ draft: ReminderDraft) async throws -> String
    func reminders(inCalendar calendarIdentifier: String) async throws -> [ReminderSummary]
    func deleteReminder(identifier: String) async throws

    /// Whether an item with this identifier currently resolves. Crash recovery (SPEC §9.6)
    /// uses it to decide whether a mid-flight mutation reached its expected state. Returns
    /// `false` rather than throwing when access is missing — the caller (`Reconciler`)
    /// checks authorization itself and does not probe at all when it is absent.
    func itemExists(identifier: String, entityType: RCCEntityType) async -> Bool
}

public enum RCCEntityType: String, Sendable, CaseIterable {
    case event
    case reminder

    public var displayName: String {
        switch self {
        case .event: return "Calendar"
        case .reminder: return "Reminders"
        }
    }
}

/// Mirrors `EKAuthorizationStatus`, plus the raw value so a case Apple adds in a future
/// OS stays representable instead of being coerced into an existing one (SPEC §9.1).
public struct RCCAuthorizationStatus: Sendable, Equatable {
    public enum Known: String, Sendable {
        case notDetermined
        case restricted
        case denied
        /// Legacy full-access spelling still reported by some EventKit versions.
        case authorized
        case fullAccess
        case writeOnly
        case unknown
    }

    public let known: Known
    public let rawValue: Int

    public init(known: Known, rawValue: Int) {
        self.known = known
        self.rawValue = rawValue
    }

    /// Only `fullAccess` (or the legacy `authorized`) lets `rcc` do its job. `writeOnly`
    /// is explicitly insufficient: the whole point is reading and writing (SPEC §6.3).
    public var grantsFullAccess: Bool {
        known == .fullAccess || known == .authorized
    }

    public var errorCode: RCCExitCode? {
        switch known {
        case .fullAccess, .authorized: return nil
        case .notDetermined: return .permission
        case .denied, .restricted, .writeOnly, .unknown: return .permission
        }
    }

    public var description: String { "\(known.rawValue) (raw \(rawValue))" }
}

public struct SourceSummary: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    /// Normalised `EKSourceType` name.
    public let sourceType: String
    /// The raw `EKSourceType` value, preserved so an unrecognised future case is still
    /// reportable (SPEC §9.1's both-name-and-raw-value rule).
    public let sourceTypeRawValue: Int

    public init(id: String, title: String, sourceType: String, sourceTypeRawValue: Int) {
        self.id = id
        self.title = title
        self.sourceType = sourceType
        self.sourceTypeRawValue = sourceTypeRawValue
    }
}

public struct CalendarSummary: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let allowsContentModifications: Bool
    public let isSubscribed: Bool
    public let isImmutable: Bool
    public let allowedEntityTypes: Set<RCCEntityType>
    public let sourceIdentifier: String?
    public let sourceTitle: String?

    public init(
        id: String,
        title: String,
        allowsContentModifications: Bool,
        isSubscribed: Bool,
        isImmutable: Bool,
        allowedEntityTypes: Set<RCCEntityType>,
        sourceIdentifier: String?,
        sourceTitle: String?
    ) {
        self.id = id
        self.title = title
        self.allowsContentModifications = allowsContentModifications
        self.isSubscribed = isSubscribed
        self.isImmutable = isImmutable
        self.allowedEntityTypes = allowedEntityTypes
        self.sourceIdentifier = sourceIdentifier
        self.sourceTitle = sourceTitle
    }

    public var isWritable: Bool { allowsContentModifications && !isImmutable }
}

public struct EventDraft: Sendable, Equatable {
    public let calendarIdentifier: String
    public let title: String
    public let start: Date
    public let end: Date
    public let notes: String?

    public init(calendarIdentifier: String, title: String, start: Date, end: Date, notes: String? = nil) {
        self.calendarIdentifier = calendarIdentifier
        self.title = title
        self.start = start
        self.end = end
        self.notes = notes
    }
}

public struct EventSummary: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public let calendarIdentifier: String

    public init(id: String, title: String, start: Date, end: Date, calendarIdentifier: String) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.calendarIdentifier = calendarIdentifier
    }
}

public struct ReminderDraft: Sendable, Equatable {
    public let calendarIdentifier: String
    public let title: String
    public let notes: String?

    public init(calendarIdentifier: String, title: String, notes: String? = nil) {
        self.calendarIdentifier = calendarIdentifier
        self.title = title
        self.notes = notes
    }
}

public struct ReminderSummary: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let isCompleted: Bool
    public let calendarIdentifier: String

    public init(id: String, title: String, isCompleted: Bool, calendarIdentifier: String) {
        self.id = id
        self.title = title
        self.isCompleted = isCompleted
        self.calendarIdentifier = calendarIdentifier
    }
}

/// Failures the repository can surface, mapped onto SPEC §10.1's error taxonomy.
public enum CalendarRepositoryError: Error, CustomStringConvertible {
    case notAuthorized(RCCEntityType, RCCAuthorizationStatus)
    case notFound(String)
    case readOnly(String)
    case unsupported(String)
    /// Carries the underlying EventKit error so provider-specific failures stay
    /// diagnosable instead of collapsing into one generic code (SPEC §10.1).
    case native(String, underlying: NSError)

    public var description: String {
        switch self {
        case .notAuthorized(let entity, let status):
            return "Not authorized for \(entity.displayName): \(status.description)"
        case .notFound(let what):
            return "Not found: \(what)"
        case .readOnly(let what):
            return "Read-only: \(what)"
        case .unsupported(let what):
            return "Unsupported: \(what)"
        case .native(let context, let underlying):
            return "\(context): \(underlying.domain) \(underlying.code) — \(underlying.localizedDescription)"
        }
    }

    /// Stable error code from SPEC §10.1.
    public var code: String {
        switch self {
        case .notAuthorized(_, let status):
            switch status.known {
            case .notDetermined: return "permission_not_determined"
            case .restricted: return "permission_restricted"
            default: return "permission_denied"
            }
        case .notFound: return "not_found"
        case .readOnly: return "read_only"
        case .unsupported: return "unsupported"
        case .native: return "internal"
        }
    }

    /// EventKit's own domain/code, surfaced verbatim where we have it (SPEC §10.1).
    public var nativeError: [String: Any]? {
        guard case .native(_, let underlying) = self else { return nil }
        return ["domain": underlying.domain, "code": underlying.code]
    }
}
