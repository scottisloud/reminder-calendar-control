import Foundation
import Security
import RCCCore

/// Keychain reachability check for `rcc doctor` (SPEC §6.1, §16).
///
/// Tier 1's API key will live here (SPEC §11.2), but the failure worth catching is not
/// "the key is missing" — it is "this binary, under this signature, can no longer reach
/// the item it wrote". That is a real and frequent state: an ad-hoc-signed binary's
/// keychain ACL is bound to its cdhash, so every rebuild locks it out of its own item.
///
/// Two rules this probe follows:
///
/// * **Never store anything.** An add/read/delete round-trip would itself trip the ACL
///   prompt it is meant to detect.
/// * **Never decrypt.** The query asks for attributes only, never `kSecReturnData`. An
///   attribute query does not evaluate the item's ACL, so it cannot raise the blocking
///   authorisation dialog that would hang a LaunchAgent with nobody there to click it.
///
/// The older `SecKeychainGetStatus` lock-state introspection is deliberately *not* used:
/// it has been deprecated since 10.10 with no replacement, and everything `doctor`
/// actually needs is already distinguishable from the `SecItemCopyMatching` status code.
public enum KeychainProbe {
    public enum Presence: Equatable {
        case present
        /// Normal state before Tier 1 is ever enabled.
        case absent
        /// The keychain is locked, or macOS would need to ask the user something and we
        /// forbade interaction. SPEC §10.1 has a dedicated `keychain_locked` code.
        case locked(OSStatus)
        /// The item exists but this binary is not allowed to read it — almost always a
        /// rebuild under an unstable (ad-hoc) signature.
        case accessDenied(OSStatus)
        case error(OSStatus)

        public var detail: String {
            switch self {
            case .present:
                return "present"
            case .absent:
                return "absent (not configured — expected until Tier 1 is enabled)"
            case .locked(let status):
                return "keychain locked or interaction required (OSStatus \(status))"
            case .accessDenied(let status):
                return "present but not readable by this binary (OSStatus \(status): \(describe(status)))"
            case .error(let status):
                return "query failed (OSStatus \(status): \(describe(status)))"
            }
        }

        public var isHealthy: Bool {
            switch self {
            case .present, .absent: return true
            case .locked, .accessDenied, .error: return false
            }
        }
    }

    public struct State: Equatable {
        public let credentialPresence: Presence

        public var facts: [String: String] {
            [
                "service": credentialService,
                "credential": credentialPresence.detail,
            ]
        }
    }

    /// Keychain service the Tier 1 API key is stored under (SPEC §11.2).
    public static var credentialService: String { "\(RCCPaths.bundleIdentifier).tier1" }

    static func describe(_ status: OSStatus) -> String {
        SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
    }

    /// Inspect without storing and without any possibility of a blocking dialog.
    public static func inspect() -> State {
        State(credentialPresence: credentialPresence())
    }

    private static func credentialPresence() -> Presence {
        // Deliberately no `kSecReturnData`: attributes only, so no decryption and no ACL
        // evaluation. Also deliberately not `kSecUseDataProtectionKeychain` — that needs a
        // real signing identity and fails with `errSecMissingEntitlement`, whose follow-on
        // read then returns a plausible-looking "item not found".
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: credentialService,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &item) {
        case errSecSuccess:
            return .present
        case errSecItemNotFound:
            return .absent
        case errSecInteractionNotAllowed, errSecInteractionRequired:
            return .locked(errSecInteractionNotAllowed)
        case errSecAuthFailed, errSecNoAccessForItem:
            return .accessDenied(errSecAuthFailed)
        case let status:
            return .error(status)
        }
    }
}
