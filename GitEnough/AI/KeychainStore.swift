import Foundation
#if canImport(Security)
import Security
#endif

/// The LLM API key's home in the system's secret store — the macOS Keychain, or
/// the Secret Service (GNOME Keyring / KWallet) on Linux. UserDefaults only ever
/// holds non-secret settings.
///
/// The Linux backend drives `secret-tool` (Debian/Ubuntu package
/// `libsecret-tools`) rather than linking libsecret, keeping GitEnough's
/// zero-dependency build. When it isn't installed the key simply isn't stored:
/// GitEnough never falls back to writing a secret to disk in the clear.
/// What a secret store said when asked for a secret.
///
/// `absent` and `unavailable` are kept apart because collapsing them destroys
/// data: a caller that reads "I could not look" as "there is nothing there"
/// will happily write an empty value over a key the user never touched. Only
/// `absent` is evidence that nothing is stored.
public enum SecretLookup: Equatable {
    case found(String)
    case absent
    case unavailable
}

public enum KeychainStore {

    public static let service = Bundle.main.bundleIdentifier ?? "ch.lkmc.GitEnough"

    /// Whether this machine can store a secret at all.
    ///
    /// Settings asks before offering an API-key field it might not be able to
    /// honour: the macOS Keychain is always there, but a Linux desktop without
    /// libsecret-tools has nowhere to put a secret, and GitEnough will not fall
    /// back to a file. Which of those applies is the `Platform` seam's business,
    /// not a front end's — hence the question lives here rather than on
    /// `SecretService`.
    public static var isAvailable: Bool {
        #if canImport(Security)
        return true
        #else
        return SecretService.isAvailable
        #endif
    }

    public static func save(secret: String, account: String) throws {
        #if canImport(Security)
        let data = Data(secret.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Replace an existing item if there is one.
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            let attributes: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.saveFailed(status: updateStatus)
            }
        } else if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.saveFailed(status: addStatus)
            }
        } else {
            throw KeychainError.saveFailed(status: status)
        }
        #else
        try SecretService.save(secret: secret, service: service, account: account)
        #endif
    }

    /// The stored secret, or nil for every reason there might not be one.
    ///
    /// Fine for a caller that only wants a key to send. A caller deciding
    /// whether to *write* must use `lookup` instead: nil here cannot tell
    /// "nothing is stored" from "I could not ask".
    public static func read(account: String) -> String? {
        guard case .found(let secret) = lookup(account: account) else { return nil }
        return secret
    }

    /// The stored secret, with absence and failure kept apart.
    public static func lookup(account: String) -> SecretLookup {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let secret = String(data: data, encoding: .utf8) else { return .unavailable }
            return .found(secret)
        case errSecItemNotFound:
            return .absent
        default:
            // A locked keychain, a denied prompt, a daemon that did not answer.
            return .unavailable
        }
        #else
        return SecretService.lookup(service: service, account: account)
        #endif
    }

    public static func delete(account: String) {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        #else
        SecretService.delete(service: service, account: account)
        #endif
    }

    #if canImport(Security)
    public enum KeychainError: Error, LocalizedError {
        case saveFailed(status: OSStatus)

        public var errorDescription: String? {
            switch self {
            case .saveFailed(let status):
                return "Could not save the API key to the Keychain (OSStatus \(status))."
            }
        }
    }
    #endif
}
