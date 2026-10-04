import Foundation

/// Compile-time and runtime identity of this binary.
///
/// `rcc doctor` has to be able to say *exactly* which artifact is answering, because
/// SPEC §6.1's whole install story is "there is one authoritative binary" and the way
/// that fails is silently, with two copies at different versions.
public enum BuildInfo {
    /// Marketing version. Kept in one place; `Scripts/build-release.sh` asserts it
    /// matches the embedded `CFBundleShortVersionString`.
    public static let version = "0.2.0"

    /// Git revision, injected at build time. Absent for a plain `swift build`.
    public static var gitRevision: String? {
        let value = buildEnvironmentValue("RCC_GIT_REVISION")
        return value?.isEmpty == false ? value : nil
    }

    /// Build configuration this binary was produced with.
    public static var configuration: String {
        #if DEBUG
        return "debug"
        #else
        return "release"
        #endif
    }

    public static var versionString: String {
        var text = version
        if let gitRevision { text += "+\(gitRevision)" }
        text += " (\(configuration))"
        return text
    }

    /// Values baked in by the build script are not readable at runtime as `-D` defines,
    /// so the release build writes them into the embedded Info.plist instead and we read
    /// them back from there. Falls back to the environment for local development builds.
    ///
    /// Note the embedded plist is sealed by the code signature: it must be generated
    /// *before* linking, never patched into an already-signed binary (doing so makes the
    /// kernel SIGKILL the process).
    private static func buildEnvironmentValue(_ key: String) -> String? {
        if let fromPlist = Bundle.main.object(forInfoDictionaryKey: key) as? String {
            return fromPlist
        }
        return ProcessInfo.processInfo.environment[key]
    }
}
