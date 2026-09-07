import Foundation

/// The embedded `__TEXT,__info_plist` section, read back at runtime.
///
/// A bare Mach-O executable really does surface these through `Bundle.main` — verified
/// on macOS 26.6.2 — and they are the *only* source of `rcc`'s bundle identity, since
/// there is no `.app` wrapper. If the section is missing, EventKit's access request
/// fails instead of prompting (SPEC §6.3), so `rcc doctor` treats that as a hard
/// failure rather than a cosmetic one.
///
/// Takes a `Bundle` rather than reaching for `Bundle.main` internally: under
/// `swift test`, `Bundle.main` is `com.apple.dt.xctest.tool`, so a hardcoded reference
/// would make this untestable.
public struct BundleIdentity: Sendable, Equatable {
    public let bundleIdentifier: String?
    public let name: String?
    public let shortVersion: String?
    public let buildVersion: String?
    public let calendarsUsageDescription: String?
    public let remindersUsageDescription: String?
    /// Legacy pre-macOS-14 keys. SPEC §6.3 forbids them given the macOS 26 floor, so
    /// their presence is a packaging mistake worth reporting.
    public let legacyKeysPresent: [String]
    /// `Bundle.main.bundlePath` is the *containing directory* for a bare executable, so
    /// this deliberately comes from `executableURL`.
    public let executablePath: String?

    public static let legacyUsageKeys = ["NSCalendarsUsageDescription", "NSRemindersUsageDescription"]

    public init(bundle: Bundle) {
        func string(_ key: String) -> String? {
            (bundle.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        self.bundleIdentifier = bundle.bundleIdentifier
        self.name = string("CFBundleName")
        self.shortVersion = string("CFBundleShortVersionString")
        self.buildVersion = string("CFBundleVersion")
        self.calendarsUsageDescription = string("NSCalendarsFullAccessUsageDescription")
        self.remindersUsageDescription = string("NSRemindersFullAccessUsageDescription")
        self.legacyKeysPresent = Self.legacyUsageKeys.filter { bundle.object(forInfoDictionaryKey: $0) != nil }
        self.executablePath = bundle.executableURL?.resolvingSymlinksInPath().path
    }

    /// Direct-construction initialiser, for tests.
    public init(
        bundleIdentifier: String?,
        name: String?,
        shortVersion: String?,
        buildVersion: String?,
        calendarsUsageDescription: String?,
        remindersUsageDescription: String?,
        legacyKeysPresent: [String] = [],
        executablePath: String? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.shortVersion = shortVersion
        self.buildVersion = buildVersion
        self.calendarsUsageDescription = calendarsUsageDescription
        self.remindersUsageDescription = remindersUsageDescription
        self.legacyKeysPresent = legacyKeysPresent
        self.executablePath = executablePath
    }

    public static var current: BundleIdentity { BundleIdentity(bundle: .main) }

    /// Everything that must be true for EventKit to be able to prompt at all.
    public var missingRequirements: [String] {
        var missing: [String] = []
        if bundleIdentifier == nil { missing.append("CFBundleIdentifier") }
        if calendarsUsageDescription == nil { missing.append("NSCalendarsFullAccessUsageDescription") }
        if remindersUsageDescription == nil { missing.append("NSRemindersFullAccessUsageDescription") }
        return missing
    }

    public var isComplete: Bool { missingRequirements.isEmpty }

    public var facts: [String: String] {
        var facts: [String: String] = [:]
        facts["bundle_identifier"] = bundleIdentifier ?? "<missing>"
        facts["short_version"] = shortVersion ?? "<missing>"
        facts["build_version"] = buildVersion ?? "<missing>"
        facts["executable_path"] = executablePath ?? "<unknown>"
        facts["calendars_usage_description"] = calendarsUsageDescription == nil ? "<missing>" : "present"
        facts["reminders_usage_description"] = remindersUsageDescription == nil ? "<missing>" : "present"
        if !legacyKeysPresent.isEmpty {
            facts["legacy_keys_present"] = legacyKeysPresent.joined(separator: ",")
        }
        return facts
    }
}
