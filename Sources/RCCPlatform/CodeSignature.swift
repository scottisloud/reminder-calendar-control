import Foundation
import Security
import RCCCore

/// Code-signing introspection for `rcc doctor` (SPEC §6.1, §6.3, §16).
///
/// Uses the Security framework rather than parsing `codesign` output: `doctor` needs to
/// describe the *running image*, not just a file on disk, and `SecCodeCopySelf` is the
/// only way to be sure those are the same thing.
public struct CodeSignature: Sendable, Equatable {
    /// `CFBundleIdentifier`, or the signing identifier for a bare executable.
    public let identifier: String?
    public let teamIdentifier: String?
    /// Leaf certificate common name, e.g. `Developer ID Application: Name (TEAMID)`.
    public let authority: String?
    public let cdhash: String?
    public let isAdHoc: Bool
    public let hasHardenedRuntime: Bool
    /// The designated requirement, which is what TCC actually matches a grant against
    /// for a properly signed binary.
    public let designatedRequirement: String?

    public var isDeveloperIDSigned: Bool {
        authority?.hasPrefix("Developer ID Application:") == true
    }

    /// Signing flags, from `<Security/CSCommon.h>`.
    private static let adhocFlag: UInt32 = 0x0000_0002
    private static let runtimeFlag: UInt32 = 0x0001_0000

    /// The signature of the currently running image.
    public static func current() -> CodeSignature? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        return from(staticCode: staticCode)
    }

    /// The signature of a binary on disk.
    public static func of(path: String) -> CodeSignature? {
        var staticCode: SecStaticCode?
        let url = URL(fileURLWithPath: path) as CFURL
        guard SecStaticCodeCreateWithPath(url, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        return from(staticCode: staticCode)
    }

    private static func from(staticCode: SecStaticCode) -> CodeSignature? {
        var infoRef: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &infoRef) == errSecSuccess,
              let info = infoRef as? [String: Any] else { return nil }

        let signingFlags = (info[kSecCodeInfoFlags as String] as? UInt32) ?? 0

        var requirementText: String?
        var requirement: SecRequirement?
        if SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
           let requirement {
            var text: CFString?
            if SecRequirementCopyString(requirement, [], &text) == errSecSuccess {
                requirementText = text as String?
            }
        }

        return CodeSignature(
            identifier: info[kSecCodeInfoIdentifier as String] as? String,
            teamIdentifier: info[kSecCodeInfoTeamIdentifier as String] as? String,
            authority: leafCommonName(from: info),
            cdhash: (info[kSecCodeInfoUnique as String] as? Data)
                .map { $0.map { String(format: "%02x", $0) }.joined() },
            isAdHoc: signingFlags & adhocFlag != 0,
            hasHardenedRuntime: signingFlags & runtimeFlag != 0,
            designatedRequirement: requirementText
        )
    }

    private static func leafCommonName(from info: [String: Any]) -> String? {
        guard let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else { return nil }
        var commonName: CFString?
        guard SecCertificateCopyCommonName(leaf, &commonName) == errSecSuccess else { return nil }
        return commonName as String?
    }

    /// Whether the binary satisfies the `notarized` code requirement.
    ///
    /// NOT `spctl -a -t exec`: on a bare Mach-O (which `rcc` is) that always reports
    /// "the code is valid but does not seem to be an app" and exits non-zero even when the
    /// binary is fully notarised — it only accepts `.app`/`.pkg`/`.dmg`. `codesign
    /// -R=notarized` checks the actual notarisation ticket (online, since a flat Mach-O
    /// cannot be stapled) and is the right probe for this artifact shape.
    public static func gatekeeperAssessment(path: String) -> (accepted: Bool, detail: String) {
        let (status, output) = run(
            "/usr/bin/codesign",
            ["--verify", "--strict", "-R=notarized", "--verbose=1", path]
        )
        if status == 0 {
            return (true, "codesign -R=notarized: satisfied")
        }
        // Fall back to spctl's text purely for a human-readable reason in `facts`.
        let (_, spctlOutput) = run("/usr/sbin/spctl", ["-a", "-vvv", "-t", "exec", path])
        let reason = spctlOutput.isEmpty ? output : spctlOutput
        return (false, "not notarized (\(reason.isEmpty ? "no detail" : reason))")
    }

    private static func run(_ tool: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, "could not run \(tool): \(error.localizedDescription)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: "; ")
        return (process.terminationStatus, output)
    }

    public var facts: [String: String] {
        var facts: [String: String] = [
            "adhoc": isAdHoc ? "true" : "false",
            "hardened_runtime": hasHardenedRuntime ? "true" : "false",
        ]
        if let identifier { facts["identifier"] = identifier }
        if let teamIdentifier { facts["team_identifier"] = teamIdentifier }
        if let authority { facts["authority"] = authority }
        if let cdhash { facts["cdhash"] = cdhash }
        if let designatedRequirement { facts["designated_requirement"] = designatedRequirement }
        return facts
    }
}
