import ArgumentParser
import Foundation
import RCCBootstrap
import RCCCore

// ORDER IS LOAD-BEARING.
//
// `Disclaim.ensure()` must be the first Swift that runs in this process (SPEC §6.2):
//
//  * On the first image it replaces the process image in place via
//    `posix_spawn(POSIX_SPAWN_SETEXEC)`, so this line executes twice under one pid — and
//    anything done before it is done twice.
//  * `FD_CLOEXEC` descriptors do not survive the replacement, and Swift's `FileHandle`,
//    `URLSession`, and libdispatch sources all set it. Nothing may open a file first.
//  * EventKit, UserNotifications, and XPC cache a TCC audit token on first touch, which
//    would pin the *pre-disclaim* identity.
//
// This is also why the entry point is `main.swift` top-level code rather than `@main`:
// the two cannot coexist in one target, and `@main` gives no hook that runs this early.
Disclaim.ensure()

// `await RCCCommand.main(nil)` written directly binds to the *synchronous*
// `ParsableCommand.main(_:)` overload, and the async `run()` is silently never called.
// Only a generic function constrained to `AsyncParsableCommand` resolves correctly.
//
// `main(_:)` would also exit with ArgumentParser's own codes — 64 for a usage error — which
// contradicts SPEC §16's exit-code contract. Parsing is driven explicitly instead so a
// usage error exits 2 like every other caller error.
func runAsRoot<Command: AsyncParsableCommand>(_ type: Command.Type) async -> Never {
    do {
        var command = try type.parseAsRoot()
        if var asyncCommand = command as? any AsyncParsableCommand {
            try await asyncCommand.run()
        } else {
            try command.run()
        }
        exit(RCCExitCode.ok.rawValue)
    } catch {
        if error is RCCError { exitWith(error) }
        // A command that threw its own ExitCode (doctor's `unhealthy`, for instance) keeps it.
        if let exitCode = error as? ExitCode { exit(exitCode.rawValue) }

        // ArgumentParser signals `--help` and `--version` as errors whose exit code is
        // success. Its help text belongs on stdout in that case, and on stderr otherwise.
        let message = type.fullMessage(for: error)
        if type.exitCode(for: error) == .success {
            if !message.isEmpty { Output.line(message) }
            exit(RCCExitCode.ok.rawValue)
        }
        if !message.isEmpty { Output.error(message) }
        // Deliberately rcc's code, not ArgumentParser's 64: SPEC §16 calls these a contract.
        exit(RCCExitCode.usage.rawValue)
    }
}

await runAsRoot(RCCCommand.self)
