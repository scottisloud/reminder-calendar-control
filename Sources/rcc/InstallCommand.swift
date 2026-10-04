import ArgumentParser
import Foundation
import RCCBootstrap
import RCCCore
import RCCPlatform

/// `rcc install` — copy this binary to the authoritative path (SPEC §6.1).
///
/// What Homebrew's cask and the download installer run, so neither becomes a second install
/// location. Touches no Calendar or Reminders data and needs no permission grant, so it is
/// safe to run unattended; `rcc setup` remains the one step that needs a person.
struct Install: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install this rcc binary at its stable path (used by Homebrew and the installer).",
        discussion: """
            Copies the running binary to \
            ~/Library/Application Support/reminder-calendar-control/bin/rcc atomically. \
            Refuses an ad-hoc build, a downgrade, or a change of signing team unless told \
            otherwise. Running it again after an update is how the update reaches Claude \
            Desktop and the automation LaunchAgent, which both run the stable path.
            """
    )

    @Option(name: .long, help: "Also symlink `rcc` into this directory (or at this path), e.g. /opt/homebrew/bin.")
    var link: String?

    @Flag(name: .long, help: "Replace a newer version, or a binary signed by a different team.")
    var force = false

    @Flag(name: .long, help: "Accept an ad-hoc signature. Development only — macOS will not grant it access.")
    var allowAdhoc = false

    @Flag(name: .long, help: "Print only errors.")
    var quiet = false

    func run() async throws {
        guard let running = Disclaim.canonicalExecutablePath() else {
            throw RCCError(.internalError, "Could not resolve rcc's own executable path.")
        }
        if RCCPaths.installedShapes.contains(.bundle) {
            throw RCCError(
                .install,
                "An RCC.app install is present at \(RCCPaths.appBundle.path); installing the bare binary "
                    + "beside it would split the install.",
                remediation: "Update it with Scripts/install.sh --bundle, or remove RCC.app first."
            )
        }

        let installer = BinaryInstaller()
        let outcome = try installer.install(
            from: URL(fileURLWithPath: running),
            options: .init(force: force, allowAdHoc: allowAdhoc)
        )
        let linked = try link.map { try installer.link(at: URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)) }

        let configured = FileManager.default.fileExists(atPath: RCCPaths.databaseFile.path)
        if configured, case .updated = outcome, let store = try? Store() {
            // The bytes now at the stable path are exactly the running image's, so its
            // signature is the installed one's. Recording it keeps `rcc doctor` from
            // reporting the previous version as installed.
            let signature = CodeSignature.current()
            try? store.recordInstall(Store.InstallMetadata(
                installedAt: RCCTime.instant(), version: BuildInfo.versionString,
                binaryPath: RCCPaths.bareBinary.path,
                signingIdentity: signature?.authority ?? (signature?.isAdHoc == true ? "ad-hoc" : nil),
                cdhash: signature?.cdhash
            ))
        }
        guard !quiet else { return }

        switch outcome {
        case .installed(let version): Output.line("Installed rcc \(version) at \(RCCPaths.bareBinary.path)")
        case .updated(let from, let to): Output.line("Updated rcc \(from) → \(to) at \(RCCPaths.bareBinary.path)")
        case .alreadyCurrent(let version): Output.line("rcc \(version) is already installed at \(RCCPaths.bareBinary.path)")
        case .isInstalledCopy(let version): Output.line("This is the installed copy (rcc \(version)); nothing to do.")
        }
        if let linked { Output.line("Linked \(linked.path) → \(RCCPaths.bareBinary.path)") }

        Output.line("")
        if !configured {
            Output.line("Next, from Terminal (macOS will ask for Calendar and Reminders access):")
            Output.line("    \(linked == nil ? "\"\(RCCPaths.bareBinary.path)\"" : "rcc") setup")
        } else if case .updated = outcome {
            Output.line("Quit and relaunch Claude Desktop to start the new version.")
        }
    }
}
