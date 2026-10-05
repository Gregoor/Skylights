import Foundation
import Security

/// Stores user-provided credentials in the device Keychain, never in UserDefaults or logs.
struct KeychainCredentialStore {
    enum StoreError: Error {
        case keychainStatus(OSStatus)
    }

    private let service: String

    init(service: String = Bundle.main.bundleIdentifier ?? "com.tinycast.skylights") {
        self.service = service
    }

    func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        var attributes: [String: Any] = [kSecValueData as String: data]
        #if os(iOS)
        query[kSecUseDataProtectionKeychain as String] = true
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        #endif
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            attributes.forEach { insert[$0.key] = $0.value }
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw StoreError.keychainStatus(addStatus) }
        } else if status != errSecSuccess {
            throw StoreError.keychainStatus(status)
        }
    }

    func delete(account: String) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        #if os(iOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.keychainStatus(status)
        }
    }
}
