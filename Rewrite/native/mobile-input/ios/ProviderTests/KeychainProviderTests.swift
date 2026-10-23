import Foundation
import Security
import Testing

@testable import MobileInputCore

#if os(iOS)
  @Test private func actualDeviceKeychainPersistsSyntheticCredentialAcrossVaultInstances() throws {
    let pin = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    let now = UInt64(Date().timeIntervalSince1970 * 1000)
    let value = try PhoneCredential(
      hostPin: pin + pin, phoneID: "test-phone", epoch: 1, expiresAt: now + 300_000,
      token: Data(repeating: 42, count: 32))
    let vault = PhoneCredentialVault()
    defer { try? vault.forget(hostPin: value.metadata.hostPin) }
    try vault.save(value)
    var attributes: CFTypeRef?
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: KeychainPhoneCredentialStorage.service,
      kSecAttrAccount as String: value.metadata.hostPin,
      kSecAttrSynchronizable as String: false,
      kSecUseDataProtectionKeychain as String: true,
      kSecReturnAttributes as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    #expect(SecItemCopyMatching(query as CFDictionary, &attributes) == errSecSuccess)
    let stored = try #require(attributes as? [String: Any])
    #expect(
      stored[kSecAttrAccessible as String] as? String
        == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    #expect(stored[kSecAttrSynchronizable as String] as? Bool != true)
    let loaded = try #require(
      try PhoneCredentialVault().load(hostPin: value.metadata.hostPin, now: now))
    #expect(loaded.metadata == value.metadata)
    #expect(loaded.encoded() == value.encoded())
    try vault.forget(hostPin: value.metadata.hostPin)
    #expect(try PhoneCredentialVault().load(hostPin: value.metadata.hostPin, now: now) == nil)
  }
#endif
