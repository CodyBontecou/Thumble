import Foundation
import Security

// Confined to Receiver.queue. Pairing trust is persisted separately from single-use QR tokens.
struct RememberedPhone {
    private var phoneID: String?
    private var credential: String?
    private var secrets: ReceiverSecretStore?
    private struct Saved: Codable { let phoneID: String; let credential: String }
    mutating func restore(from secrets: ReceiverSecretStore) throws {
        self.secrets = secrets
        guard let data = try secrets.load("remembered-phone") else { return }
        // A damaged pairing only costs a rescan; never let it stop the receiver from starting.
        guard let saved = try? JSONDecoder().decode(Saved.self, from: data), UUID(uuidString: saved.phoneID) != nil, saved.credential.count == 64,
              saved.credential.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { try secrets.remove("remembered-phone"); return }
        phoneID = saved.phoneID; credential = saved.credential
    }

    mutating func pair(_ phoneID: String) -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let value = bytes.map { String(format: "%02x", $0) }.joined()
        do { try secrets?.save(JSONEncoder().encode(Saved(phoneID: phoneID, credential: value)), account: "remembered-phone") }
        catch { return nil } // Never report a pairing that cannot survive receiver restart.
        self.phoneID = phoneID; credential = value
        return value
    }
    var isRemembered: Bool { phoneID != nil }
    func accepts(phoneID: String, credential: String) -> Bool {
        guard self.phoneID == phoneID, let expected = self.credential,
              credential.utf8.count == 64 else { return false }
        // Do not expose prefix matches through a short-circuit comparison.
        return zip(expected.utf8, credential.utf8).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    mutating func reset() throws {
        phoneID = nil; credential = nil
        try secrets?.remove("remembered-phone")
    }
}
