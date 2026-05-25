import Foundation
import Security

/// Minimal Keychain wrapper for per-instance auth headers.
/// Service = bundle id + ".auth", account = instance UUID string.
enum Keychain {
    private static let service = "\(ConfigManager.bundleIdentifier).auth"

    static func setAuthHeader(_ value: String?, for id: UUID) {
        if let value, !value.isEmpty {
            write(value, account: id.uuidString)
        } else {
            delete(account: id.uuidString)
        }
    }

    static func authHeader(for id: UUID) -> String? { read(account: id.uuidString) }
    static func hasAuthHeader(for id: UUID) -> Bool { read(account: id.uuidString) != nil }

    static func deleteAll() {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(q as CFDictionary)
    }

    private static func write(_ value: String, account: String) {
        let data = Data(value.utf8)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attrs = baseQuery.merging([
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ]) { _, new in new }
        let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            _ = SecItemAdd(attrs as CFDictionary, nil)
        }
    }

    private static func read(account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func delete(account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(q as CFDictionary)
    }
}
