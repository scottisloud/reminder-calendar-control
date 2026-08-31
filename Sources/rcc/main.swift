import ArgumentParser
import Foundation
import RCCBootstrap

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
func runAsRoot<Command: AsyncParsableCommand>(_ type: Command.Type) async {
    await type.main(nil)
}

await runAsRoot(RCCCommand.self)
