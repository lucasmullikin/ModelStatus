import Foundation
import Security

/// Minimal Keychain wrapper for per-instance auth headers.
/// Service = bundle id + ".auth", account = instance UUID string.
enum Keychain {
    private static let service = "\(ConfigManager.bundleIdentifier).auth"

    /// Returns true on success (write OR delete). Audit-round-3: callers that
    /// stage credentials before persisting config need to know whether the
    /// keychain write actually landed.
    @discardableResult
    static func setAuthHeader(_ value: String?, for id: UUID) -> Bool {
        if let value, !value.isEmpty {
            return write(value, account: id.uuidString)
        }
        return delete(account: id.uuidString)
    }

    static func authHeader(for id: UUID) -> String? { read(account: id.uuidString) }
    static func hasAuthHeader(for id: UUID) -> Bool { read(account: id.uuidString) != nil }

    /// Audit-round-D23: return Bool so logout/reset flows can verify the
    /// keychain delete actually succeeded. errSecItemNotFound counts as
    /// success (nothing to delete is the same end state).
    @discardableResult
    static func deleteAll() -> Bool {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        let status = SecItemDelete(q as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func write(_ value: String, account: String) -> Bool {
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
        // Audit-round-D11: include kSecAttrAccessible in the update payload so
        // an older item created with weaker accessibility gets UPGRADED to
        // `AfterFirstUnlockThisDeviceOnly` on every write, not stuck at
        // whatever it was first stored with.
        let updateAttrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus == errSecItemNotFound {
            let addStatus = SecItemAdd(attrs as CFDictionary, nil)
            if addStatus == errSecSuccess { return true }
            // Race: a concurrent writer raced us between update-not-found and
            // add. Retry the update path so we don't drop the credential.
            if addStatus == errSecDuplicateItem {
                return SecItemUpdate(baseQuery as CFDictionary, updateAttrs as CFDictionary) == errSecSuccess
            }
        }
        return false
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

    private static func delete(account: String) -> Bool {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(q as CFDictionary)
        // errSecItemNotFound is "nothing to delete" — treat as success.
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
