import Foundation
import LocalAuthentication
import Security

public enum PhoneCredentialError: Error, Equatable {
  case invalid, unavailable, expired, rollback, unconfirmed
}
public struct PhoneCredentialMetadata: Sendable, Equatable {
  public let hostPin: String
  public let phoneID: String
  public let epoch: UInt64
  public let expiresAt: UInt64
}
/// Secret-bearing native value; intentionally has no Codable conformance or public secret getter.
public struct PhoneCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  private final class Storage: Sendable {
    let metadata: PhoneCredentialMetadata
    let token: Data
    init(_ metadata: PhoneCredentialMetadata, _ token: Data) {
      self.metadata = metadata
      self.token = token
    }
  }
  private let storage: Storage
  public var metadata: PhoneCredentialMetadata { storage.metadata }
  public var description: String { "PhoneCredential([redacted])" }
  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, children: ["credential": "[redacted]"]) }
  init(hostPin: String, phoneID: String, epoch: UInt64, expiresAt: UInt64, token: Data) throws {
    guard Self.pin(hostPin), (1...64).contains(phoneID.utf8.count),
      phoneID.utf8.allSatisfy({
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
      }),
      epoch > 0, epoch <= UInt64(Int64.max), expiresAt > 0, expiresAt <= UInt64(Int64.max),
      token.count == 32
    else { throw PhoneCredentialError.invalid }
    storage = Storage(
      PhoneCredentialMetadata(
        hostPin: hostPin, phoneID: phoneID, epoch: epoch, expiresAt: expiresAt), token)
  }
  static func pin(_ text: String) -> Bool {
    text.utf8.count == 64
      && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
  /// Native TLS use only. No raw token getter is exposed to the application bridge.
  func authenticationFrame(authority: String) throws -> ControlTLSFrame {
    guard EnrollmentInvitation.identity(authority) else { throw PhoneCredentialError.invalid }
    let token = storage.token.map { String(format: "%02x", $0) }.joined()
    return try ControlTLSFrame(
      kind: .control,
      payload: JSONSerialization.data(withJSONObject: [
        "version": 1, "command": "authenticate", "authorityInstanceId": authority,
        "phoneId": metadata.phoneID, "credentialEpoch": String(metadata.epoch), "credential": token,
      ]))
  }
  private static let magic = Data([84, 72, 80, 67, 49, 0, 0, 0])
  func encoded() -> Data {
    var bytes = Self.magic
    let pin = Array(metadata.hostPin.utf8)
    for i in stride(from: 0, to: 64, by: 2) {
      func nibble(_ b: UInt8) -> UInt8 { b <= 57 ? b - 48 : b - 87 }
      bytes.append(nibble(pin[i]) * 16 + nibble(pin[i + 1]))
    }
    bytes.append(UInt8(metadata.phoneID.utf8.count))
    bytes.append(contentsOf: metadata.phoneID.utf8)
    for value in [metadata.epoch, metadata.expiresAt] {
      bytes.append(contentsOf: (0..<8).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    bytes.append(storage.token)
    return bytes
  }
  static func decode(_ bytes: Data) throws -> Self {
    let bytes = Array(bytes)
    guard (90...153).contains(bytes.count), Data(bytes.prefix(8)) == magic else {
      throw PhoneCredentialError.invalid
    }
    let count = Int(bytes[40])
    guard (1...64).contains(count), bytes.count == 89 + count,
      let id = String(bytes: bytes[41..<41 + count], encoding: .utf8)
    else { throw PhoneCredentialError.invalid }
    func number(_ offset: Int) -> UInt64 {
      (0..<8).reduce(0) { $0 | UInt64(bytes[offset + $1]) << ($1 * 8) }
    }
    let pin = bytes[8..<40].map { String(format: "%02x", $0) }.joined()
    return try Self(
      hostPin: pin, phoneID: id, epoch: number(41 + count), expiresAt: number(49 + count),
      token: Data(bytes[(57 + count)...]))
  }
}
/// The backend is synchronous and belongs to a native enrollment worker, never the input/UI thread.
protocol PhoneCredentialStorage {
  func transaction<T>(_ action: () throws -> T) rethrows -> T
  func read(pin: String) throws -> Data?
  func write(pin: String, bytes: Data) throws
  func remove(pin: String) throws
}
public final class PhoneCredentialVault {
  private let storage: any PhoneCredentialStorage
  public init() { storage = KeychainPhoneCredentialStorage() }
  init(storage: any PhoneCredentialStorage) { self.storage = storage }
  public func load(hostPin: String, now: UInt64) throws -> PhoneCredential? {
    try storage.transaction { try loadUnlocked(hostPin: hostPin, now: now) }
  }
  private func loadUnlocked(hostPin: String, now: UInt64) throws -> PhoneCredential? {
    guard PhoneCredential.pin(hostPin), now <= UInt64(Int64.max) else {
      throw PhoneCredentialError.invalid
    }
    guard let bytes = try storage.read(pin: hostPin) else { return nil }
    let value = try PhoneCredential.decode(bytes)
    guard value.metadata.hostPin == hostPin else { throw PhoneCredentialError.invalid }
    guard now < value.metadata.expiresAt else { throw PhoneCredentialError.expired }
    return value
  }
  /// Caller may acknowledge enrollment only after this returns. A readback failure never erases storage.
  public func save(_ credential: PhoneCredential) throws {
    try storage.transaction { try saveUnlocked(credential) }
  }
  private func saveUnlocked(_ credential: PhoneCredential) throws {
    let pin = credential.metadata.hostPin
    let bytes = credential.encoded()
    if let old = try storage.read(pin: pin) {
      let prior = try PhoneCredential.decode(old)
      guard prior.metadata.hostPin == pin else { throw PhoneCredentialError.invalid }
      if prior.metadata.phoneID == credential.metadata.phoneID {
        guard credential.metadata.epoch >= prior.metadata.epoch else {
          throw PhoneCredentialError.rollback
        }
        if credential.metadata.epoch == prior.metadata.epoch {
          guard bytes == old else { throw PhoneCredentialError.rollback }
          return
        }
      }
    }
    try storage.write(pin: pin, bytes: bytes)
    guard try storage.read(pin: pin) == bytes else { throw PhoneCredentialError.unconfirmed }
  }
  public func forget(hostPin: String) throws {
    guard PhoneCredential.pin(hostPin) else { throw PhoneCredentialError.invalid }
    try storage.transaction { try storage.remove(pin: hostPin) }
  }
}
struct KeychainPhoneCredentialStorage: PhoneCredentialStorage {
  private static let owner = NSLock()
  func transaction<T>(_ action: () throws -> T) rethrows -> T {
    Self.owner.lock()
    defer { Self.owner.unlock() }
    return try action()
  }
  static let service = "com.thumble.rewrite.phone-trust.v1"
  private func query(_ pin: String) -> [String: Any] {
    let context = LAContext()
    context.interactionNotAllowed = true
    return [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
      kSecAttrAccount as String: pin, kSecAttrSynchronizable as String: false,
      kSecUseDataProtectionKeychain as String: true,
      kSecUseAuthenticationContext as String: context,
    ]
  }
  func read(pin: String) throws -> Data? {
    var q = query(pin)
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var value: CFTypeRef?
    let status = SecItemCopyMatching(q as CFDictionary, &value)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = value as? Data, (90...153).contains(data.count) else {
      throw PhoneCredentialError.unavailable
    }
    return data
  }
  func write(pin: String, bytes: Data) throws {
    let attributes: [String: Any] = [
      kSecValueData as String: bytes,
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    var status = SecItemUpdate(query(pin) as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      var q = query(pin)
      for (key, value) in attributes { q[key] = value }
      status = SecItemAdd(q as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw PhoneCredentialError.unavailable }
  }
  func remove(pin: String) throws {
    let status = SecItemDelete(query(pin) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw PhoneCredentialError.unavailable
    }
  }
}
