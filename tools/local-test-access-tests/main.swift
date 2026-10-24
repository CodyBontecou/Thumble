import Foundation
let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at:folder, withIntermediateDirectories:true)
defer { try? FileManager.default.removeItem(at:folder) }
let path = folder.appendingPathComponent("demo.json")
let record: [String:Any] = ["version":1, "receiverId":UUID().uuidString, "used":1800]
try JSONSerialization.data(withJSONObject:record).write(to:path)
var clock = 100.0
func make() -> AccessSession { AccessSession(directory:folder, publicKey:"", now:{ clock }) }
func check(_ session: AccessSession) {
    let value = session.snapshot()
#if THUMBLE_LOCAL_TESTING
    precondition(value["pro"] as? Bool == true && value["running"] as? Bool == true)
#else
    precondition(value["pro"] as? Bool == false && value["running"] as? Bool == false)
#endif
    precondition(value["remaining"] as? Double == 0 && value["debitedUsed"] as? Double == 1800)
}
let session = make()
session.pair(phoneID:UUID().uuidString, mirroredUsed:1800)
session.start(); check(session)
clock += 86400; check(session)
session.pause(); _ = session.snapshot()
let restarted = make()
restarted.pair(phoneID:UUID().uuidString, mirroredUsed:1800)
restarted.start(); check(restarted)
let saved = try JSONSerialization.jsonObject(with:Data(contentsOf:path)) as! [String:Any]
precondition(saved["used"] as? Double == 1800)
precondition(!FileManager.default.fileExists(atPath:folder.appendingPathComponent("pro-grant.json").path))
#if THUMBLE_LOCAL_TESTING
print("PASS local QA: exhausted phone can resume beyond 24h and reconnect; no fake grant or usage reset")
#else
print("PASS production: exhausted phone remains blocked; local QA code absent")
#endif
