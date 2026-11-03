import Foundation
import Security

protocol ReceiverSecretStore {
    func load(_ account: String) throws -> Data?
    func save(_ data: Data, account: String) throws
    func remove(_ account: String) throws
}

// Data Protection Keychain binds access to the signed app; secrets never enter profile files.
struct KeychainReceiverSecrets: ReceiverSecretStore {
    private let service = "com.thumble.receiver.connection.v1"
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecUseDataProtectionKeychain as String: true]
    }
    func load(_ account: String) throws -> Data? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw ReceiverError.message("Could not read saved receiver credentials (\(status)).") }
        return data
    }
    func save(_ data: Data, account: String) throws {
        let request = query(account)
        var status = SecItemUpdate(request as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = request
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ReceiverError.message("Could not save receiver credentials (\(status)).") }
    }
    func remove(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ReceiverError.message("Could not forget receiver credentials (\(status)).") }
    }
}
