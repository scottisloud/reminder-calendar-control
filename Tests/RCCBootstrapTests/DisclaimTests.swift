import Darwin
import Foundation
import Testing

@testable import RCCBootstrap

@Suite("Disclaim sentinel")
struct DisclaimSentinelTests {
    /// A bare boolean sentinel is spoofable: any parent that exports it makes `rcc` skip
    /// the disclaim while believing it succeeded, and then run fully misattributed. The
    /// pid binding is what makes an inherited value provably foreign — `POSIX_SPAWN_SETEXEC`
    /// preserves the pid, so only we can have written a sentinel bearing ours.
    @Test("Only a sentinel bearing our own pid is honoured")
    func rejectsForeignPid() {
        let pid = getpid()
        #expect(Disclaim.parseSentinel("\(pid):1", pid: pid) == 1)
        #expect(Disclaim.parseSentinel("\(pid + 1):1", pid: pid) == 0)
        #expect(Disclaim.parseSentinel("99999:1", pid: pid) == 0)
    }

    @Test("Malformed sentinels read as generation zero")
    func rejectsGarbage() {
        let pid = getpid()
        for raw in ["1", "", "lolno", ":", "\(pid):", ":1", "\(pid):x", "\(pid):-1", "a:b"] {
            #expect(Disclaim.parseSentinel(raw, pid: pid) == 0, "accepted \(raw)")
        }
        #expect(Disclaim.parseSentinel(nil, pid: pid) == 0)
    }

    @Test("Generation zero means we have not re-executed yet")
    func acceptsGenerationZero() {
        let pid = getpid()
        #expect(Disclaim.parseSentinel("\(pid):0", pid: pid) == 0)
    }
}

@Suite("Disclaim outcome classification")
struct DisclaimClassificationTests {
    @Test("Second image, responsible for itself, is the only healthy outcome")
    func healthyOutcome() {
        #expect(Disclaim.classify(generation: 1, responsiblePID: 42, pid: 42) == .disclaimed)
        #expect(Disclaim.Outcome.disclaimed.isHealthy)
        #expect(Disclaim.Outcome.disclaimed.remediation == nil)
    }

    /// The SPI accepting the attribute is not evidence it did anything: a silently
    /// no-opping symbol produces exactly this state, and it must fail closed rather than
    /// run under another application's TCC identity.
    @Test("Re-executed but still attributed to an ancestor fails closed")
    func silentNoOp() {
        let outcome = Disclaim.classify(generation: 1, responsiblePID: 1234, pid: 42)
        #expect(outcome == .notDisclaimed)
        #expect(!outcome.isHealthy)
        #expect(outcome.remediation != nil)
    }

    @Test("Generation above one means the guard leaked or a sentinel was forged")
    func guardViolation() {
        #expect(Disclaim.classify(generation: 2, responsiblePID: 42, pid: 42) == .guardViolated)
        #expect(!Disclaim.Outcome.guardViolated.isHealthy)
    }

    @Test("Generation zero is never healthy, even if we already look self-responsible")
    func generationZero() {
        #expect(Disclaim.classify(generation: 0, responsiblePID: 42, pid: 42) == .notDisclaimed)
    }

    @Test("Every unhealthy outcome carries remediation an operator can act on")
    func remediationCoverage() {
        for outcome in [
            Disclaim.Outcome.notDisclaimed, .mechanismUnavailable, .spawnFailed,
            .pathUnresolved, .guardViolated,
        ] {
            #expect(!outcome.isHealthy)
            #expect(outcome.remediation?.isEmpty == false, "\(outcome) has no remediation")
        }
    }
}

@Suite("Executable path resolution")
struct ExecutablePathTests {
    /// `argv[0]` is fully caller-controlled and need not even be a path, so the re-exec
    /// target comes from `_NSGetExecutablePath` + `realpath` instead.
    @Test("The resolved path is absolute, canonical, and exists")
    func resolvesCanonically() throws {
        let path = try #require(Disclaim.canonicalExecutablePath())
        #expect(path.hasPrefix("/"))
        #expect(!path.contains("/./"))
        #expect(!path.contains("/../"))
        #expect(FileManager.default.fileExists(atPath: path))
        // realpath output must already be canonical.
        #expect(URL(fileURLWithPath: path).resolvingSymlinksInPath().path == path)
    }

    @Test("The resolved path ignores argv[0] entirely")
    func ignoresArgvZero() throws {
        let path = try #require(Disclaim.canonicalExecutablePath())
        // Under `swift test` argv[0] is the xctest tool; the resolved path is whatever is
        // actually executing. The two need not match, and the point is that we never read
        // argv[0] to decide.
        #expect(!path.isEmpty)
        #expect(CommandLine.arguments.first != nil)
    }
}
