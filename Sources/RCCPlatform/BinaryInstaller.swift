import CoreFoundation
import Foundation
import RCCCore

/// `rcc install`: put *this* binary at the one authoritative path (SPEC §6.1).
///
/// This is what makes a package manager or a downloaded zip a delivery vehicle rather than
/// a second install location. Homebrew keeps its copy in the Caskroom; macOS records the
/// Calendar/Reminders grant against a binary's path plus its designated requirement
/// (SPEC §6.1), so every copy that is *run* has to be the one at the
/// stable path. A downloaded `rcc` therefore installs itself there and gets out of the way.
///
/// The same rules as `Scripts/install.sh`:
///
/// * **Atomic.** Written to a temp file in the destination directory and `rename()`d over
///   the old one, so Claude Desktop or launchd never exec a half-written file. A running
///   `rcc serve` keeps its mapped image.
/// * **Only a sealed, properly signed binary.** An ad-hoc or linker-signed build carries no
///   stable identity, and on macOS 26 is never shown the permission dialog at all.
/// * **No silent identity change.** Replacing a binary signed by one team with another's
///   would quietly hand the grant's path to different code; that needs `--force`.
/// * **No silent downgrade.** A stale Caskroom or download never replaces a newer install.
///
/// Bytes are copied, not the file: extended attributes — the quarantine flag on a
/// downloaded copy in particular — stay behind.
public struct BinaryInstaller {
    public struct Options: Sendable {
        /// Replace a binary signed by another team, or a newer version.
        public var force = false
        /// Accept an ad-hoc signature. Development only.
        public var allowAdHoc = false

        public init(force: Bool = false, allowAdHoc: Bool = false) {
            self.force = force
            self.allowAdHoc = allowAdHoc
        }
    }

    public enum Outcome: Equatable, Sendable {
        /// Nothing was there before.
        case installed(version: String)
        case updated(from: String, to: String)
        /// The destination already holds exactly these bytes (same cdhash).
        case alreadyCurrent(version: String)
        /// Running from the destination itself.
        case isInstalledCopy(version: String)
    }

    public let destination: URL
    let signatureOf: (String) -> CodeSignature?
    let versionOf: (URL) -> String?

    public init(destination: URL = RCCPaths.bareBinary) {
        self.init(destination: destination, signatureOf: CodeSignature.of(path:), versionOf: Self.embeddedVersion)
    }

    init(destination: URL, signatureOf: @escaping (String) -> CodeSignature?, versionOf: @escaping (URL) -> String?) {
        self.destination = destination
        self.signatureOf = signatureOf
        self.versionOf = versionOf
    }

    public func install(from source: URL, options: Options = Options()) throws -> Outcome {
        let fileManager = FileManager.default
        let sourcePath = source.resolvingSymlinksInPath().path
        let destinationPath = destination.resolvingSymlinksInPath().path

        guard let sourceSignature = signatureOf(sourcePath) else {
            throw RCCError(.install, "\(sourcePath) is not code-signed.")
        }
        guard let sourceVersion = versionOf(URL(fileURLWithPath: sourcePath)) else {
            throw RCCError(
                .install,
                "\(sourcePath) has no embedded Info.plist, so TCC would have no usage strings to show.",
                remediation: "Install a release build (Scripts/build-release.sh), not a plain `swift build`."
            )
        }
        if sourceSignature.isAdHoc && !options.allowAdHoc {
            throw RCCError(
                .install,
                "\(sourcePath) is only ad-hoc signed; macOS will not show it the Calendar/Reminders prompt.",
                remediation: "Install a Developer ID–signed release. Pass --allow-adhoc to override (development only)."
            )
        }
        if sourcePath == destinationPath {
            return .isInstalledCopy(version: sourceVersion)
        }

        var previousVersion: String?
        if fileManager.fileExists(atPath: destinationPath) {
            let existing = signatureOf(destinationPath)
            if let existing, existing.cdhash != nil, existing.cdhash == sourceSignature.cdhash {
                return .alreadyCurrent(version: sourceVersion)
            }
            if !options.force, let theirs = existing?.teamIdentifier, theirs != sourceSignature.teamIdentifier {
                throw RCCError(
                    .install,
                    "The installed rcc is signed by team \(theirs), this one by "
                        + "\(sourceSignature.teamIdentifier ?? "no team"). Refusing to swap identities silently.",
                    remediation: "Pass --force if this is intended."
                )
            }
            previousVersion = versionOf(URL(fileURLWithPath: destinationPath))
            if !options.force, let installed = previousVersion, Self.compare(installed, sourceVersion) == .orderedDescending {
                throw RCCError(
                    .install,
                    "The installed rcc (\(installed)) is newer than this one (\(sourceVersion)).",
                    remediation: "Pass --force to downgrade."
                )
            }
        }

        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        // 0700 on the product root as well as bin/ (SPEC §13): `createDirectory` creates
        // intermediates at the default umask.
        for url in [directory, directory.deletingLastPathComponent()] {
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: sourcePath))
        let temporary = directory.appendingPathComponent(".rcc.\(UUID().uuidString)", isDirectory: false)
        do {
            try data.write(to: temporary)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
            guard rename(temporary.path, destination.path) == 0 else {
                throw RCCError(.install, "Could not move the new binary into place: \(String(cString: strerror(errno))).")
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
        return previousVersion.map { .updated(from: $0, to: sourceVersion) } ?? .installed(version: sourceVersion)
    }

    /// Point a command on `PATH` at the installed binary. `at` may be a directory (the link
    /// is `at/rcc`) or the link path itself. Replaces an existing symlink, never a file.
    @discardableResult
    public func link(at: URL) throws -> URL {
        var isDirectory: ObjCBool = false
        let fileManager = FileManager.default
        let link = fileManager.fileExists(atPath: at.path, isDirectory: &isDirectory) && isDirectory.boolValue
            ? at.appendingPathComponent("rcc", isDirectory: false)
            : at
        if let attributes = try? fileManager.attributesOfItem(atPath: link.path) {
            guard attributes[.type] as? FileAttributeType == .typeSymbolicLink else {
                throw RCCError(
                    .install,
                    "\(link.path) exists and is not a symlink; refusing to replace it.",
                    remediation: "Remove it, or choose another directory with --link."
                )
            }
            try fileManager.removeItem(at: link)
        }
        try fileManager.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: link, withDestinationURL: destination)
        return link
    }

    // MARK: - Helpers

    /// `CFBundleShortVersionString` from a bare Mach-O's `__TEXT,__info_plist` section.
    /// CoreFoundation reads that section directly, without running the binary.
    static func embeddedVersion(of url: URL) -> String? {
        guard let info = CFBundleCopyInfoDictionaryForURL(url as CFURL) as? [String: Any] else { return nil }
        return info["CFBundleShortVersionString"] as? String
    }

    /// Numeric, component-wise: "0.10.0" is newer than "0.9.1". Anything after a `+` or
    /// `-` (build metadata) is ignored.
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        func parts(_ version: String) -> [Int] {
            let core = version.split(whereSeparator: { $0 == "+" || $0 == "-" }).first.map(String.init) ?? version
            return core.split(separator: ".").map { Int($0) ?? 0 }
        }
        let (a, b) = (parts(lhs), parts(rhs))
        for index in 0..<max(a.count, b.count) {
            let (x, y) = (index < a.count ? a[index] : 0, index < b.count ? b[index] : 0)
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}
