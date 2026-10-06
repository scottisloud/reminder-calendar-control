import AppKit
import EventKit
import Foundation
import RCCCore

/// Requests Calendar/Reminders full access from inside a foreground `NSApplication` so
/// macOS actually presents its TCC dialogs (SPEC §6.2a).
///
/// Two independently-measured facts drive this:
///
///  * On macOS 14+, the first `requestFullAccessTo…` call issued from a bare CLI async
///    context returns denied **without ever presenting a dialog**. A running AppKit run
///    loop in a real application context is what lets the modal appear.
///  * On macOS 26.5+, tccd additionally refuses to prompt at all unless the binary carries
///    `com.apple.security.personal-information.{calendars,reminders}` — handled by
///    `Resources/rcc-Entitlements.plist` at signing time, not here.
///
/// `.accessory` activation policy: a genuine GUI process (so tccd will route the modal)
/// with no Dock tile and no menu bar, which suits a one-shot `rcc setup` step.
@MainActor
public enum InteractiveGrant {
    public struct Outcome: Sendable {
        public let statuses: [RCCEntityType: RCCAuthorizationStatus]
        /// True if the run loop hit the deadline with a request still outstanding — most
        /// likely the dialog could not be presented (no window server session).
        public let timedOut: Bool
    }

    /// Drive the AppKit run loop and request full access to each still-undetermined entity
    /// type. Entity types already granted (or already denied) are reported as-is without a
    /// request. Safe to call when every entity is already resolved — it returns immediately.
    public static func requestFullAccess(
        for entityTypes: [RCCEntityType],
        timeout: TimeInterval = 120
    ) -> Outcome {
        let undetermined = entityTypes.filter {
            EventKitRepository.map(EKEventStore.authorizationStatus(for: $0.ekEntityType)).known == .notDetermined
        }

        guard !undetermined.isEmpty else {
            return Outcome(statuses: currentStatuses(for: entityTypes), timedOut: false)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.activate()

        // A store created while authorization is undetermined holds a connection scoped to
        // that state; the caller (EventKitRepository) recreates its own afterwards.
        let store = EKEventStore()
        let state = PendingRequests(undetermined)

        for entityType in undetermined {
            // Called on an arbitrary queue; the run-loop pump below only observes `state`
            // on the main thread.
            let handler: @Sendable (Bool, (any Error)?) -> Void = { _, _ in
                DispatchQueue.main.async { state.complete(entityType) }
            }
            switch entityType {
            case .event: store.requestFullAccessToEvents(completion: handler)
            case .reminder: store.requestFullAccessToReminders(completion: handler)
            }
        }

        // Explicit pump rather than `app.run()` / `RunLoop.main.run(until:)`: both were
        // measured to hang once an AppKit observer is live on this codebase.
        // `run(mode:before:)` with a short horizon returns
        // control every tick so the deadline is honoured.
        let deadline = Date().addingTimeInterval(timeout)
        while !state.isEmpty, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }

        return Outcome(statuses: currentStatuses(for: entityTypes), timedOut: !state.isEmpty)
    }

    private static func currentStatuses(
        for entityTypes: [RCCEntityType]
    ) -> [RCCEntityType: RCCAuthorizationStatus] {
        var out: [RCCEntityType: RCCAuthorizationStatus] = [:]
        for entityType in entityTypes {
            out[entityType] = EventKitRepository.map(
                EKEventStore.authorizationStatus(for: entityType.ekEntityType)
            )
        }
        return out
    }
}

/// Main-thread-confined countdown of outstanding access requests. `@unchecked Sendable`
/// because every access is funnelled onto the main thread (the `DispatchQueue.main.async`
/// in the completion handler, and the pump loop that reads `isEmpty`).
private final class PendingRequests: @unchecked Sendable {
    private var pending: Set<RCCEntityType>

    init(_ entityTypes: [RCCEntityType]) { pending = Set(entityTypes) }

    var isEmpty: Bool { pending.isEmpty }

    func complete(_ entityType: RCCEntityType) { pending.remove(entityType) }
}
