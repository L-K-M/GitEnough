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
public enum KeychainStore {

    public static let service = "com.gitenough.GitEnough"

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

    public static func read(account: String) -> String? {
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
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
        #else
        return SecretService.read(service: service, account: account)
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
