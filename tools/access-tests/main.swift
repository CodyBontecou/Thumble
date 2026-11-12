import Foundation
import CryptoKit
let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }
var wall = 1000.0
let key = Curve25519.Signing.PrivateKey()
let phone = UUID().uuidString
func session(_ directory: URL = folder) -> AccessSession {
    AccessSession(directory: directory, publicKey: key.publicKey.rawRepresentation.base64EncodedString(), wallNow: { wall })
}
func record(_ directory: URL) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("demo.json"))) as! [String: Any]
}

// No plan: output cannot start and there is no free time, however long the phone stays.
let access = session()
var running = false
access.onChange = { _, value in running = value }
access.pair(phoneID: phone)
let first = access.snapshot()
precondition(first["v"] as? Int == 1 && first["pro"] as? Bool == false && first["running"] as? Bool == false)
precondition(first["remaining"] as? Double == 0 && first["debitedUsed"] as? Double == 1800, "Wire numbers changed")
precondition(first["receiverId"] is String && first["nonce"] is String && first["error"] as? String == "" && first["grantExpires"] as? Double == 0)
access.start()
precondition(access.snapshot()["running"] as? Bool == false && !running, "Started without a plan")
wall += 86400
precondition(access.snapshot()["remaining"] as? Double == 0)
let receiverID = access.snapshot()["receiverId"] as! String
let saved = try record(folder)
precondition(saved["receiverId"] as? String == receiverID && saved["version"] as? Int == 1 && saved["used"] as? Double == 1800)
print("PASS no plan: cannot start, remaining always 0, new receiver record keeps the old schema")

func grant(pro: Bool = true, receiver: String = receiverID, nonce: String? = nil, owner: String = phone, lasts: Double = 100) throws -> [String: Any] {
    let value: [String: Any] = ["v": 1, "productId": "thumble_pro_lifetime", "receiverId": receiver, "phoneId": owner, "nonce": nonce ?? access.snapshot()["nonce"]!, "pro": pro, "issuedAt": wall, "expiresAt": wall + lasts]
    let data = try JSONSerialization.data(withJSONObject: value)
    return ["payload": data.base64EncodedString(), "signature": try key.signature(for: data).base64EncodedString()]
}
access.submitGrant(try grant(receiver: UUID().uuidString))
precondition(access.snapshot()["pro"] as? Bool == false)
precondition(access.snapshot()["error"] as? String == "Your plan could not be verified on this Mac. Tap Restore in Thumble on your phone.")
access.submitGrant(try grant(nonce: UUID().uuidString))
precondition(access.snapshot()["pro"] as? Bool == false)
access.submitGrant(try grant(lasts: 8 * 86400))
precondition(access.snapshot()["pro"] as? Bool == false, "Accepted a grant longer than seven days")
access.submitGrant(try grant())
precondition(access.snapshot()["pro"] as? Bool == true && access.snapshot()["error"] as? String == "")
precondition(access.snapshot()["running"] as? Bool == false, "A new grant must wait for Resume")
access.start()
precondition(access.snapshot()["running"] as? Bool == true && running, "Valid plan could not start")
precondition(access.snapshot()["remaining"] as? Double == 0)
access.pause()
precondition(access.snapshot()["running"] as? Bool == false && !running)
access.pair(phoneID: UUID().uuidString)
precondition(access.snapshot()["pro"] as? Bool == false, "Another phone inherited the plan")
access.pair(phoneID: phone)
precondition(access.snapshot()["pro"] as? Bool == true, "Cached plan grant not restored")
access.start(); precondition(access.snapshot()["running"] as? Bool == true)
wall += 99
precondition(access.snapshot()["running"] as? Bool == true)
wall += 1
let expired = access.snapshot()
precondition(expired["pro"] as? Bool == false && expired["running"] as? Bool == false && !running, "Expired plan kept output running")
access.start(); precondition(access.snapshot()["running"] as? Bool == false)
access.pair(phoneID: phone)
precondition(access.snapshot()["pro"] as? Bool == false, "Expired cached grant restored")
access.submitGrant(try grant())
precondition(access.snapshot()["pro"] as? Bool == true)
wall += 1
access.submitGrant(try grant(pro: false))
precondition(access.snapshot()["pro"] as? Bool == false && access.snapshot()["remaining"] as? Double == 0)
print("PASS grants: signature, receiver, pairing nonce, phone binding, cache, expiry stops output, revocation")

// Ledgers written by the demo-era receivers keep their receiver ID and are not rewritten.
for used in [0.0, 500.0, 1800.0] {
    let old = folder.appendingPathComponent("old-\(Int(used))")
    try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
    let id = UUID().uuidString
    let bytes = try JSONSerialization.data(withJSONObject: ["version": 1, "receiverId": id, "used": used])
    try bytes.write(to: old.appendingPathComponent("demo.json"))
    let restored = session(old)
    restored.pair(phoneID: phone)
    let value = restored.snapshot()
    precondition(value["receiverId"] as? String == id && value["error"] as? String == "", "Old ledger did not load")
    precondition(value["remaining"] as? Double == 0 && value["pro"] as? Bool == false)
    let after = try Data(contentsOf: old.appendingPathComponent("demo.json"))
    precondition(after == bytes, "Old ledger was rewritten")
}
print("PASS old ledgers load, keep their receiver ID and grant no free time")

let corrupt = folder.appendingPathComponent("corrupt")
try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
try Data("broken".utf8).write(to: corrupt.appendingPathComponent("demo.json"))
let damaged = session(corrupt)
damaged.pair(phoneID: phone)
precondition(damaged.snapshot()["remaining"] as? Double == 0 && damaged.snapshot()["pro"] as? Bool == false)
precondition(damaged.snapshot()["error"] as? String == "Receiver record could not be loaded. Restore your plan in Thumble on your phone, or contact support.")
let kept = try Data(contentsOf: corrupt.appendingPathComponent("demo.json"))
precondition(String(decoding: kept, as: UTF8.self) == "broken", "Unreadable record was replaced")
let locked = folder.appendingPathComponent("locked")
try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o500])
defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
precondition(session(locked).snapshot()["error"] as? String == "Receiver record could not be saved. Restore your plan in Thumble on your phone, or contact support.")
print("PASS unreadable or unwritable records fail closed without replacing the receiver ID")
