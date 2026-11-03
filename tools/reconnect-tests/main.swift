import Foundation
var trust = RememberedPhone()
let phone = UUID().uuidString
let credential = trust.pair(phone)!
precondition(credential.count == 64)
precondition(trust.accepts(phoneID: phone, credential: credential))
precondition(!trust.accepts(phoneID: UUID().uuidString, credential: credential))
precondition(!trust.accepts(phoneID: phone, credential: String(repeating: "a", count: 64)))
precondition(!trust.accepts(phoneID: phone, credential: ""))
try trust.reset()
precondition(!trust.accepts(phoneID: phone, credential: credential))
let replacement = trust.pair(phone)!
precondition(replacement != credential)
precondition(!trust.accepts(phoneID: phone, credential: credential))
print("Remembered phone: correct phone accepted; wrong phone, forged token, reset and superseded credentials rejected")

final class MemorySecrets: ReceiverSecretStore {
    var values: [String: Data] = [:]
    var failWrites = false
    func load(_ account: String) throws -> Data? { values[account] }
    func save(_ data: Data, account: String) throws {
        if failWrites { throw ReceiverError.message("Synthetic storage failure") }
        values[account] = data
    }
    func remove(_ account: String) throws { values[account] = nil }
}
let store = MemorySecrets()
var original = RememberedPhone(); try original.restore(from: store)
let retained = original.pair(phone)!
var relaunched = RememberedPhone(); try relaunched.restore(from: store)
precondition(relaunched.accepts(phoneID: phone, credential: retained))
store.failWrites = true
precondition(relaunched.pair(UUID().uuidString) == nil)
precondition(relaunched.accepts(phoneID: phone, credential: retained))
store.failWrites = false
try relaunched.reset()
var afterReset = RememberedPhone(); try afterReset.restore(from: store)
precondition(!afterReset.accepts(phoneID: phone, credential: retained))
store.values["remembered-phone"] = Data("corrupt".utf8)
var afterCorruption = RememberedPhone(); try afterCorruption.restore(from: store)
precondition(!afterCorruption.accepts(phoneID: phone, credential: retained), "Corrupt persisted pairing accepted")
precondition(store.values["remembered-phone"] == nil, "Corrupt persisted pairing retained")
print("Persistent pairing: restart, durable reset, failed save and corrupt credentials verified")

let identityStore = MemorySecrets()
let first = try ReceiverIdentity.create(secrets: identityStore)
let reloaded = try ReceiverIdentity.create(secrets: identityStore)
precondition(reloaded.fingerprint == first.fingerprint)
var paired = RememberedPhone(); try paired.restore(from: identityStore)
_ = paired.pair(phone)!
identityStore.values["tls-identity"] = Data("corrupt".utf8)
let regenerated = try ReceiverIdentity.create(secrets: identityStore)
precondition(regenerated.fingerprint != first.fingerprint)
precondition(identityStore.values["remembered-phone"] == nil, "Phone pinned to a replaced certificate was kept")
print("TLS identity: stable across restarts; corrupt identity regenerated and its pinned phone forgotten")
