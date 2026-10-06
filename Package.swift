// swift-tools-version: 6.2

import Foundation
import PackageDescription

// The embedded `__TEXT,__info_plist` section is what gives this bare Mach-O executable a
// bundle identity and, critically, the Calendar/Reminders usage descriptions TCC needs in
// order to prompt at all (SPEC §6.3). `Scripts/build-release.sh` generates a plist with
// build metadata baked in and points `RCC_INFO_PLIST` at it; a plain `swift build` uses
// the committed one.
//
// SwiftPM does not track this file as a link input, so editing it alone will NOT trigger a
// relink — the release script deletes the product binary first for exactly that reason.
let infoPlistPath = ProcessInfo.processInfo.environment["RCC_INFO_PLIST"]
    ?? Context.packageDirectory + "/Resources/rcc-Info.plist"

// `.strictMemorySafety()` and `InternalImportsByDefault` are deliberately absent: both
// produce dozens of hard errors against the SQLite3, `posix_spawn`, and `dlsym` code this
// tool is largely made of. `.defaultIsolation(MainActor.self)` is likewise avoided —
// ArgumentParser's `run()` requirement is nonisolated, so it would force `@MainActor` on
// every command.
let commonSwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "reminder-calendar-control",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "rcc", targets: ["rcc"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.6.1")
    ],
    targets: [
        // dlsym wrappers over the two private `libquarantine` symbols the disclaim
        // mechanism needs. Swift can reach them directly, but a C target keeps the
        // function-pointer casting and `posix_spawnattr_t` optionality out of Swift — and
        // the by-reference vs by-value distinction, which silently no-ops when got wrong,
        // is enforced by the C compiler here.
        .target(name: "CDisclaim"),

        // Paths, exit codes, logging, redaction, SQLite state. No EventKit, no platform
        // services, so it stays trivially unit-testable.
        .target(name: "RCCCore", swiftSettings: commonSwiftSettings),

        // The self-disclaim mechanism (SPEC §6.2). Its own target because it must run
        // before anything else and has no business depending on code that could pull in a
        // framework initialiser.
        .target(
            name: "RCCBootstrap",
            dependencies: ["CDisclaim", "RCCCore"],
            swiftSettings: commonSwiftSettings
        ),

        // Code signing, launchd, Claude Desktop config, Keychain, notifications.
        .target(name: "RCCPlatform", dependencies: ["RCCCore"], swiftSettings: commonSwiftSettings),

        // The EventKit seam: protocol, real adapter, in-memory fake (SPEC §15).
        .target(name: "RCCCalendar", dependencies: ["RCCCore"], swiftSettings: commonSwiftSettings),

        // Assembles `rcc doctor`'s report out of the platform and calendar checks. Its
        // own target so both the CLI and the MCP `get_system_status` tool share one
        // implementation, and so it can be unit-tested against the repository fake.
        .target(
            name: "RCCDiagnostics",
            dependencies: ["RCCBootstrap", "RCCCalendar", "RCCCore", "RCCPlatform"],
            swiftSettings: commonSwiftSettings
        ),

        // Tier 0 automation (SPEC §11): the rule DSL, scheduling, staging, and approval
        // execution. Depends on the calendar layer, never on the MCP server — approval has
        // no MCP path (SPEC §8.3).
        .target(
            name: "RCCAutomation",
            dependencies: ["RCCCalendar", "RCCCore"],
            swiftSettings: commonSwiftSettings
        ),

        // Hand-rolled MCP stdio server rather than the official Swift SDK; MCPServer.swift
        // says why.
        .target(
            name: "RCCMCP",
            dependencies: ["RCCAutomation", "RCCCalendar", "RCCCore", "RCCDiagnostics"],
            swiftSettings: commonSwiftSettings
        ),

        .executableTarget(
            name: "rcc",
            dependencies: [
                "RCCAutomation", "RCCBootstrap", "RCCCalendar", "RCCCore", "RCCDiagnostics", "RCCMCP", "RCCPlatform",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: commonSwiftSettings,
            linkerSettings: [
                // `-Xlinker` must precede every token; the bare and `-Wl,` comma forms are
                // both rejected by the Swift driver. Executable target only — putting this
                // on a library target leaks the section into the test bundle's Mach-O.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", infoPlistPath,
                ])
            ]
        ),

        .testTarget(name: "RCCCoreTests", dependencies: ["RCCCore"], swiftSettings: commonSwiftSettings),
        .testTarget(
            name: "RCCBootstrapTests",
            dependencies: ["RCCBootstrap", "RCCCore"],
            swiftSettings: commonSwiftSettings
        ),
        .testTarget(
            name: "RCCPlatformTests",
            dependencies: ["RCCPlatform", "RCCCore"],
            swiftSettings: commonSwiftSettings
        ),
        .testTarget(
            name: "RCCCalendarTests",
            dependencies: ["RCCCalendar", "RCCCore"],
            swiftSettings: commonSwiftSettings
        ),
        .testTarget(
            name: "RCCMCPTests",
            dependencies: ["RCCMCP", "RCCCore", "RCCCalendar"],
            swiftSettings: commonSwiftSettings
        ),
        .testTarget(
            name: "RCCAutomationTests",
            dependencies: ["RCCAutomation", "RCCCalendar", "RCCCore"],
            swiftSettings: commonSwiftSettings
        ),
        .testTarget(
            name: "RCCDiagnosticsTests",
            dependencies: ["RCCDiagnostics", "RCCCalendar", "RCCCore"],
            swiftSettings: commonSwiftSettings
        ),
    ]
)
