import Foundation
import CryptoKit
let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }
var clock = 100.0
var wall = 1000.0
let key = Curve25519.Signing.PrivateKey()
let phone = UUID().uuidString
func session(_ directory: URL = folder) -> AccessSession {
    AccessSession(directory: directory, publicKey: key.publicKey.rawRepresentation.base64EncodedString(), now: { clock }, wallNow: { wall })
}
let demo = session()
demo.pair(phoneID: phone, mirroredUsed: 0)
precondition(demo.snapshot()["remaining"] as? Double == 1800)
clock += 10000
precondition(demo.snapshot()["remaining"] as? Double == 1800, "Setup consumed time")
demo.start()
precondition(demo.snapshot()["running"] as? Bool == true)
clock += 2
demo.pause()
precondition(demo.snapshot()["remaining"] as? Double == 1798, "Clean pause did not credit unused reservation")
clock += 10000
precondition(demo.snapshot()["remaining"] as? Double == 1798)
demo.start(); _ = demo.snapshot(); clock += 1
// Simulate process death: durable pre-debit cannot be recovered by repeated kills.
let restarted = session()
restarted.pair(phoneID: phone, mirroredUsed: 0)
precondition(restarted.snapshot()["remaining"] as? Double == 1793)
restarted.start(); _ = restarted.snapshot()
for _ in 0..<1800 { clock += 1; _ = restarted.snapshot() }
precondition(restarted.snapshot()["remaining"] as? Double == 0)
precondition(restarted.snapshot()["running"] as? Bool == false)
restarted.start(); precondition(restarted.snapshot()["running"] as? Bool == false)
restarted.pair(phoneID: UUID().uuidString, mirroredUsed: 0)
precondition(restarted.snapshot()["remaining"] as? Double == 0, "Re-pair reset demo")
wall -= 500
precondition(restarted.snapshot()["remaining"] as? Double == 0, "Wall clock reset demo")
print("PASS demo: setup, pause, cumulative use, crash debit, 1800-second exhaustion, reconnect and clock changes")

let receiverID = restarted.snapshot()["receiverId"] as! String
func grant(pro: Bool, receiver: String = receiverID, nonce: String? = nil, owner: String = phone) throws -> [String: Any] {
    let value: [String: Any] = ["v": 1, "productId": "thumble_pro_lifetime", "receiverId": receiver, "phoneId": owner, "nonce": nonce ?? restarted.snapshot()["nonce"]!, "pro": pro, "issuedAt": wall, "expiresAt": wall + 100]
    let data = try JSONSerialization.data(withJSONObject: value)
    return ["payload": data.base64EncodedString(), "signature": try key.signature(for: data).base64EncodedString()]
}
restarted.pair(phoneID: phone, mirroredUsed: 0); _ = restarted.snapshot()
restarted.submitGrant(try grant(pro: true, receiver: UUID().uuidString))
precondition(restarted.snapshot()["pro"] as? Bool == false)
restarted.submitGrant(try grant(pro: true, nonce: UUID().uuidString))
precondition(restarted.snapshot()["pro"] as? Bool == false)
restarted.submitGrant(try grant(pro: true))
precondition(restarted.snapshot()["pro"] as? Bool == true)
restarted.start(); precondition(restarted.snapshot()["running"] as? Bool == true)
clock += 3000
precondition(restarted.snapshot()["pro"] as? Bool == true)
restarted.pause(); _ = restarted.snapshot()
restarted.pair(phoneID: UUID().uuidString, mirroredUsed: 0)
precondition(restarted.snapshot()["pro"] as? Bool == false, "Another phone inherited ownership")
restarted.pair(phoneID: phone, mirroredUsed: 0)
precondition(restarted.snapshot()["pro"] as? Bool == true, "Cached valid ownership not restored")
wall += 1
restarted.submitGrant(try grant(pro: false))
precondition(restarted.snapshot()["pro"] as? Bool == false)
precondition(restarted.snapshot()["remaining"] as? Double == 0, "Refund replenished demo")
print("PASS grants: signature, receiver, pairing nonce, phone binding, cached ownership and revocation")
let corrupt = folder.appendingPathComponent("corrupt")
try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
try Data("broken".utf8).write(to: corrupt.appendingPathComponent("demo.json"))
precondition(session(corrupt).snapshot()["remaining"] as? Double == 0)
print("PASS corrupted ledger fails closed")
