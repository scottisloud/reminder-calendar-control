import Foundation
import Testing

@testable import RCCCore
@testable import RCCPlatform

/// `rcc install` against fake signatures and versions: the file operations are real, the
/// Security framework answers are scripted per path.
@Suite("BinaryInstaller")
struct BinaryInstallerTests {
    let root: URL
    let source: URL
    let destination: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rcc-installer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        source = root.appendingPathComponent("download/rcc")
        destination = root.appendingPathComponent("support/bin/rcc")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("new".utf8).write(to: source)
    }

    static func signature(team: String? = "T879Q2BE7Q", cdhash: String, adHoc: Bool = false) -> CodeSignature {
        CodeSignature(identifier: "rcc", teamIdentifier: team, authority: adHoc ? nil : "Developer ID Application: X",
                      cdhash: cdhash, isAdHoc: adHoc, hasHardenedRuntime: true, designatedRequirement: nil)
    }

    func installer(signatures: [String: CodeSignature], versions: [String: String]) -> BinaryInstaller {
        BinaryInstaller(
            destination: destination,
            signatureOf: { signatures[$0.contains("/download/") ? "source" : "dest"] },
            versionOf: { versions[$0.path.contains("/download/") ? "source" : "dest"] }
        )
    }

    func installExisting(_ contents: String) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: destination)
    }

    @Test("A fresh install copies the bytes, executable, with 0700 directories")
    func freshInstall() throws {
        let outcome = try installer(signatures: ["source": Self.signature(cdhash: "a")], versions: ["source": "0.2.0"])
            .install(from: source)
        #expect(outcome == .installed(version: "0.2.0"))
        #expect(try Data(contentsOf: destination) == Data("new".utf8))
        let mode = try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? Int
        #expect(mode == 0o755)
        let dirMode = try FileManager.default.attributesOfItem(atPath: destination.deletingLastPathComponent().path)[.posixPermissions] as? Int
        #expect(dirMode == 0o700)
        // No temp files left behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path) == ["rcc"])
    }

    @Test("An update replaces the old binary and reports both versions")
    func update() throws {
        try installExisting("old")
        let outcome = try installer(
            signatures: ["source": Self.signature(cdhash: "b"), "dest": Self.signature(cdhash: "a")],
            versions: ["source": "0.3.0", "dest": "0.2.0"]
        ).install(from: source)
        #expect(outcome == .updated(from: "0.2.0", to: "0.3.0"))
        #expect(try Data(contentsOf: destination) == Data("new".utf8))
    }

    @Test("Identical bytes are left alone")
    func alreadyCurrent() throws {
        try installExisting("same")
        let outcome = try installer(
            signatures: ["source": Self.signature(cdhash: "a"), "dest": Self.signature(cdhash: "a")],
            versions: ["source": "0.2.0", "dest": "0.2.0"]
        ).install(from: source)
        #expect(outcome == .alreadyCurrent(version: "0.2.0"))
        #expect(try Data(contentsOf: destination) == Data("same".utf8))
    }

    @Test("A downgrade is refused unless forced")
    func downgrade() throws {
        try installExisting("newer")
        let subject = installer(
            signatures: ["source": Self.signature(cdhash: "b"), "dest": Self.signature(cdhash: "a")],
            versions: ["source": "0.2.0", "dest": "0.10.0"]
        )
        #expect(throws: RCCError.self) { try subject.install(from: source) }
        #expect(try Data(contentsOf: destination) == Data("newer".utf8))
        #expect(try subject.install(from: source, options: .init(force: true)) == .updated(from: "0.10.0", to: "0.2.0"))
    }

    @Test("A different signing team is refused unless forced")
    func teamChange() throws {
        try installExisting("theirs")
        let subject = installer(
            signatures: ["source": Self.signature(team: "OTHERTEAM1", cdhash: "b"), "dest": Self.signature(cdhash: "a")],
            versions: ["source": "0.3.0", "dest": "0.2.0"]
        )
        #expect(throws: RCCError.self) { try subject.install(from: source) }
        #expect(try Data(contentsOf: destination) == Data("theirs".utf8))
    }

    @Test("Ad-hoc, unsigned, and plist-less binaries are refused")
    func refusals() throws {
        #expect(throws: RCCError.self) {
            try installer(signatures: ["source": Self.signature(team: nil, cdhash: "a", adHoc: true)],
                          versions: ["source": "0.2.0"]).install(from: source)
        }
        #expect(throws: RCCError.self) {
            try installer(signatures: [:], versions: ["source": "0.2.0"]).install(from: source)
        }
        #expect(throws: RCCError.self) {
            try installer(signatures: ["source": Self.signature(cdhash: "a")], versions: [:]).install(from: source)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("Running the installed copy is a no-op")
    func installedCopy() throws {
        try installExisting("me")
        let subject = BinaryInstaller(destination: destination, signatureOf: { _ in Self.signature(cdhash: "a") },
                                      versionOf: { _ in "0.2.0" })
        #expect(try subject.install(from: destination) == .isInstalledCopy(version: "0.2.0"))
    }

    @Test("--link creates or replaces a symlink, never a file")
    func link() throws {
        let subject = installer(signatures: [:], versions: [:])
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)

        let link = try subject.link(at: bin)
        #expect(link.lastPathComponent == "rcc")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == destination.path)
        // Re-linking replaces the symlink.
        #expect(try subject.link(at: bin) == link)

        let file = root.appendingPathComponent("taken")
        try Data("x".utf8).write(to: file)
        #expect(throws: RCCError.self) { try subject.link(at: file) }
    }

    @Test("Versions compare numerically, ignoring build metadata")
    func compare() {
        #expect(BinaryInstaller.compare("0.10.0", "0.9.1") == .orderedDescending)
        #expect(BinaryInstaller.compare("0.2", "0.2.0") == .orderedSame)
        #expect(BinaryInstaller.compare("0.2.0+abc1234", "0.2.0") == .orderedSame)
        #expect(BinaryInstaller.compare("1.0.0", "1.0.1") == .orderedAscending)
    }
}
