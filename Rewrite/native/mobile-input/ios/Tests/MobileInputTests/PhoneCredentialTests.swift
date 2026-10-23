import Foundation
import Testing

@testable import MobileInputCore

private final class CredentialMemoryStorage: PhoneCredentialStorage {
  var values: [String: Data] = [:]
  var failRead = false, failWrite = false, corruptReadback = false
  var depth = 0, writes = 0
  func transaction<T>(_ action: () throws -> T) rethrows -> T {
    precondition(depth == 0)
    depth += 1
    defer { depth -= 1 }
    return try action()
  }
  func read(pin: String) throws -> Data? {
    precondition(depth == 1)
    if failRead { throw PhoneCredentialError.unavailable }
    if corruptReadback && writes > 0 { return Data([0]) }
    return values[pin]
  }
  func write(pin: String, bytes: Data) throws {
    precondition(depth == 1)
    if failWrite { throw PhoneCredentialError.unavailable }
    values[pin] = bytes
    writes += 1
  }
  func remove(pin: String) throws {
    precondition(depth == 1)
    values[pin] = nil
  }
}
private func credential(
  _ epoch: UInt64 = 7, pin: String = String(repeating: "1", count: 64), token: UInt8 = 34
) throws -> PhoneCredential {
  try PhoneCredential(
    hostPin: pin, phoneID: "phone-a", epoch: epoch, expiresAt: 1_234_567_890_000,
    token: Data(repeating: token, count: 32))
}
private func bytes(_ hex: String) -> Data {
  var result = Data()
  var at = hex.startIndex
  while at < hex.endIndex {
    let end = hex.index(at, offsetBy: 2)
    result.append(UInt8(hex[at..<end], radix: 16)!)
    at = end
  }
  return result
}
@Test private func sharedCredentialFixtureAndOpaqueStoragePreserveExactBytes() throws {
  let url = try #require(
    Bundle.module.url(
      forResource: "phone-credential-v1", withExtension: "json", subdirectory: "Fixtures"))
  let f = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
  let expected = bytes(try #require(f["recordHex"] as? String))
  let value = try credential()
  #expect(value.encoded() == expected)
  #expect(try PhoneCredential.decode(expected).metadata == value.metadata)
  #expect(String(describing: value) == "PhoneCredential([redacted])")
  #expect(String(reflecting: value) == "PhoneCredential([redacted])")
  #expect(Mirror(reflecting: value).children.count == 1)
  #expect(MemoryLayout<PhoneCredential>.size <= 16)
}
@Test private func credentialDecodeRejectsMalformedBoundsMagicIDsEpochsAndExpiry() throws {
  let valid = try credential().encoded()
  for raw in [Data(), valid.dropLast(), valid + Data([0]), Data(repeating: 0, count: 1000)] {
    #expect(throws: PhoneCredentialError.self) { try PhoneCredential.decode(Data(raw)) }
  }
  for offset in [0, 40, 41, 48, 56] {
    var bad = valid
    if offset == 40 {
      bad[offset] = 65
    } else if offset == 41 {
      bad[offset] = 0
    } else if offset == 48 {
      for i in 48..<56 { bad[i] = 0 }
    } else if offset == 56 {
      for i in 56..<64 { bad[i] = 0 }
    } else {
      bad[offset] = 0
    }
    #expect(throws: PhoneCredentialError.self) { try PhoneCredential.decode(bad) }
  }
  #expect(throws: PhoneCredentialError.self) { try credential(0) }
  #expect(throws: PhoneCredentialError.self) { try credential(UInt64.max) }
  #expect(throws: PhoneCredentialError.self) {
    try credential(pin: String(repeating: "A", count: 64))
  }
}
@Test private func vaultPersistsReadbackAndIdempotentSaveWithNoSecretExposure() throws {
  let store = CredentialMemoryStorage()
  let value = try credential()
  let vault = PhoneCredentialVault(storage: store)
  #expect(try vault.load(hostPin: value.metadata.hostPin, now: 100) == nil)
  try vault.save(value)
  try vault.save(value)
  #expect(store.writes == 1)
  let loaded = try #require(try vault.load(hostPin: value.metadata.hostPin, now: 100))
  #expect(loaded.encoded() == value.encoded())
  #expect(store.depth == 0)
}
@Test private func vaultRejectsStaleOrConflictingEpochAndPreservesNewerCredential() throws {
  let store = CredentialMemoryStorage()
  let pin = String(repeating: "1", count: 64)
  let vault = PhoneCredentialVault(storage: store)
  try vault.save(credential(8))
  #expect(throws: PhoneCredentialError.rollback) { try vault.save(credential(7)) }
  #expect(throws: PhoneCredentialError.rollback) { try vault.save(credential(8, token: 9)) }
  #expect(try vault.load(hostPin: pin, now: 100)?.metadata.epoch == 8)
  #expect(store.writes == 1)
}
@Test private func vaultStorageFailureNeverAcknowledgesOrErasesExistingTrust() throws {
  let store = CredentialMemoryStorage()
  let value = try credential()
  let vault = PhoneCredentialVault(storage: store)
  try vault.save(value)
  store.failWrite = true
  #expect(throws: PhoneCredentialError.unavailable) { try vault.save(credential(8)) }
  #expect(store.values[value.metadata.hostPin] == value.encoded())
  store.failRead = true
  #expect(throws: PhoneCredentialError.unavailable) {
    try vault.load(hostPin: value.metadata.hostPin, now: 100)
  }
  #expect(store.values[value.metadata.hostPin] == value.encoded())
}
@Test private func failedReadbackLeavesPotentiallyCommittedCredentialForExplicitRecovery() throws {
  let store = CredentialMemoryStorage()
  let value = try credential()
  store.corruptReadback = true
  let vault = PhoneCredentialVault(storage: store)
  #expect(throws: PhoneCredentialError.unconfirmed) { try vault.save(value) }
  #expect(store.values[value.metadata.hostPin] == value.encoded())
  store.corruptReadback = false
  #expect(try vault.load(hostPin: value.metadata.hostPin, now: 100)?.metadata == value.metadata)
}
@Test private func expiryHostBindingAndForgetRemainIndependent() throws {
  let store = CredentialMemoryStorage()
  let value = try credential()
  let other = try credential(pin: String(repeating: "2", count: 64))
  let vault = PhoneCredentialVault(storage: store)
  try vault.save(value)
  try vault.save(other)
  #expect(throws: PhoneCredentialError.expired) {
    try vault.load(hostPin: value.metadata.hostPin, now: value.metadata.expiresAt)
  }
  #expect(store.values[value.metadata.hostPin] != nil)
  store.values[value.metadata.hostPin] = other.encoded()
  #expect(throws: PhoneCredentialError.invalid) {
    try vault.load(hostPin: value.metadata.hostPin, now: 100)
  }
  #expect(throws: PhoneCredentialError.invalid) { try vault.save(value) }
  try vault.forget(hostPin: value.metadata.hostPin)
  #expect(try vault.load(hostPin: value.metadata.hostPin, now: 100) == nil)
  #expect(try vault.load(hostPin: other.metadata.hostPin, now: 100)?.metadata == other.metadata)
}
