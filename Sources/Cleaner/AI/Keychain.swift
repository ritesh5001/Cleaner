import Foundation
import Security

/// API keys live in the login Keychain of the current macOS user — never in UserDefaults or on disk.
enum Keychain {
    private static let service = "app.cleaner.mac.ai-keys"

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    @discardableResult
    static func save(_ value: String, account: String) -> Bool {
        let query = baseQuery(account)
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        add[kSecAttrLabel as String] = "Storage Fusion AI key (\(account))"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func read(account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Checks for a stored key without reading the secret (never triggers a Keychain prompt).
    static func exists(account: String) -> Bool {
        var query = baseQuery(account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        return SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess
    }

    static func delete(account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }
}
