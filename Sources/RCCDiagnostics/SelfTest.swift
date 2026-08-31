import Foundation
import RCCBootstrap
import RCCCalendar
import RCCCore

/// Milestone 1's acceptance probe (SPEC §18).
///
/// The gate is "a fresh install can read and write the dev calendar/list from Terminal,
/// manual config, and a LaunchAgent, with `rcc doctor` reporting healthy and exactly one
/// re-exec observed in each context". This type is what each of those three contexts runs,
/// so all three exercise identical code and produce comparable JSON.
///
/// It deliberately writes. `EKEventStore.authorizationStatus(for:)` reads `notDetermined`
/// both before and after the disclaim, so it discriminates nothing — only an actual
/// round-trip through EventKit proves the grant is real.
public struct SelfTest: Sendable {
    private let repository: any CalendarRepository
    private let injectedStore: Store?
    private let disclaim: Disclaim.Result?

    /// `store` and `disclaim` are injectable so tests never touch the real state database
    /// and never depend on process-global disclaim state.
    public init(
        repository: any CalendarRepository,
        store: Store? = nil,
        disclaim: Disclaim.Result? = Disclaim.result
    ) {
        self.repository = repository
        self.injectedStore = store
        self.disclaim = disclaim
    }

    public struct Outcome: Sendable {
        public let context: String
        public let disclaim: DisclaimSummary
        public let roundTrips: [DevFixtureManager.RoundTrip]
        public let authorization: [String: String]

        /// Everything must hold: exactly one disclaimed re-exec, and both entity types
        /// written, read back, and cleaned up.
        public var passed: Bool {
            disclaim.passed
                && roundTrips.count == RCCEntityType.allCases.count
                && roundTrips.allSatisfy { $0.readBack && $0.deleted }
        }

        public func jsonObject() -> [String: Any] {
            [
                "schema_version": 1,
                "as_of": RCCTime.instant(),
                "context": context,
                "rcc_version": BuildInfo.versionString,
                "passed": passed,
                "disclaim": disclaim.jsonObject(),
                "authorization": authorization,
                "round_trips": roundTrips.map { trip in
                    [
                        "entity_type": trip.entityType.rawValue,
                        "calendar_id": trip.calendarID,
                        "calendar_title": trip.calendarTitle,
                        "created": trip.createdIdentifier,
                        "read_back": trip.readBack,
                        "deleted": trip.deleted,
                    ] as [String: Any]
                },
            ]
        }
    }

    public struct DisclaimSummary: Sendable {
        public let outcome: String
        public let generation: Int
        public let pid: Int32
        public let responsiblePID: Int32
        public let mechanismAvailable: Bool

        public init(
            outcome: String,
            generation: Int,
            pid: Int32,
            responsiblePID: Int32,
            mechanismAvailable: Bool
        ) {
            self.outcome = outcome
            self.generation = generation
            self.pid = pid
            self.responsiblePID = responsiblePID
            self.mechanismAvailable = mechanismAvailable
        }

        /// Exactly one re-exec, and the process is now responsible for itself.
        public var passed: Bool {
            generation == 1 && pid == responsiblePID && outcome == Disclaim.Outcome.disclaimed.rawValue
        }

        public func jsonObject() -> [String: Any] {
            [
                "outcome": outcome,
                "generation": generation,
                "pid": Int(pid),
                "responsible_pid": Int(responsiblePID),
                "mechanism_available": mechanismAvailable,
                "exactly_one_reexec": passed,
            ]
        }
    }

    /// Run the probe. `context` records which launch context invoked it, so the acceptance
    /// harness can diff three runs side by side.
    /// `allowProvisioning` is false when a model can reach this: `run_platform_selftest`
    /// must operate on a fixture a human already created, never mint one.
    public func run(
        context: String = SelfTest.detectContext(),
        allowProvisioning: Bool = true
    ) async throws -> Outcome {
        // Fail closed before touching EventKit, whichever entry point got us here.
        try DisclaimGate.require(disclaim)

        let result = disclaim
        let summary = DisclaimSummary(
            outcome: result?.outcome.rawValue ?? "not_run",
            generation: result?.generation ?? -1,
            pid: result?.pid ?? getpid(),
            responsiblePID: result?.responsiblePID ?? -1,
            mechanismAvailable: result?.mechanismAvailable ?? false
        )

        var authorization: [String: String] = [:]
        for entityType in RCCEntityType.allCases {
            authorization[entityType.rawValue] = await repository.authorizationStatus(for: entityType).description
        }

        let store = try injectedStore ?? Store()
        let fixtures = DevFixtureManager(repository: repository, store: store)
        var roundTrips: [DevFixtureManager.RoundTrip] = []
        for entityType in RCCEntityType.allCases {
            roundTrips.append(try await fixtures.roundTrip(entityType, allowProvisioning: allowProvisioning))
        }

        let outcome = Outcome(
            context: context,
            disclaim: summary,
            roundTrips: roundTrips,
            authorization: authorization
        )
        Log.shared.info("selftest.finished", [
            "context": .safe(context),
            "passed": .bool(outcome.passed),
        ])
        return outcome
    }

    /// Best-effort guess at which of SPEC §18's three launch contexts we are in.
    ///
    /// `XPC_SERVICE_NAME` is set for a launchd-managed job; a tty on stdin means a human
    /// ran it; otherwise stdio is a pipe, which is how Claude Desktop spawns `rcc serve`.
    /// Advisory only — the acceptance harness passes the context explicitly.
    public static func detectContext() -> String {
        let environment = ProcessInfo.processInfo.environment
        if let service = environment["XPC_SERVICE_NAME"], service != "0", !service.isEmpty {
            return "launchagent"
        }
        if isatty(STDIN_FILENO) == 1 { return "terminal" }
        return "spawned"
    }
}
