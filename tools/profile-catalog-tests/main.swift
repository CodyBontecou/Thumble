import Foundation
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let store = try ProfileCatalog.read(directory)
let list = try ProfileCatalog.summary(store)
precondition((list["profiles"] as! [[String: Any]]).count == 2)
precondition(ProfileCatalog.revision(true) == nil)
precondition(list["agentCheckSupported"] as? Bool == true)
let check = list["agentConnection"] as! [String: Any]
precondition(check["code"] as? String == "123456abcdef")
var staleStore = store
staleStore["agentConnection"] = ["code": "123456abcdef", "checkedAt": (Date().timeIntervalSince1970 - 601) * 1000]
let expiredSummary = try ProfileCatalog.summary(staleStore)
precondition(expiredSummary["agentConnection"] == nil)
staleStore["agentConnection"] = ["code": "bad", "checkedAt": Date().timeIntervalSince1970 * 1000]
let invalidSummary = try ProfileCatalog.summary(staleStore)
precondition(invalidSummary["agentConnection"] == nil)
let lock = directory.appendingPathComponent("write.lock")
try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { try! FileManager.default.removeItem(at: lock) }
let started = ProcessInfo.processInfo.systemUptime
let activated = try ProfileCatalog.activate(directory, id: "warrior", profileRevision: 1, expectedActivationRevision: 0)
precondition(ProcessInfo.processInfo.systemUptime - started >= 0.08, "did not honor shared lock")
precondition(activated["activationRevision"] as? Int == 1)
let before = try Data(contentsOf: directory.appendingPathComponent("store.json"))
for (id, revision, activation) in [("warrior", 2, 1), ("warrior", 1, 0), ("../other", 1, 1)] {
    do { _ = try ProfileCatalog.activate(directory, id: id, profileRevision: revision, expectedActivationRevision: activation); fatalError("accepted stale request") }
    catch ProfileCatalog.Failure.conflict { }
    let after = try Data(contentsOf: directory.appendingPathComponent("store.json"))
    precondition(after == before)
}
print("PASS catalog: shared writer lock, atomic activation, stale revisions, unknown IDs, boolean rejection")

let casesData = try Data(contentsOf: directory.appendingPathComponent("adoption-cases.json"))
for item in try JSONSerialization.jsonObject(with: casesData) as! [[String: Any]] {
    var valid = true
    do { try CloudProfile.validate(item["profile"] as! [String: Any]) } catch { valid = false }
    precondition(valid == item["valid"] as! Bool, "Swift/JS profile validation differed")
}
let original = ((store["profiles"] as! [[String: Any]]).first { ($0["profile"] as? [String: Any])?["id"] as? String == "warrior" })!["profile"] as! [String: Any]
var source: [String: Any] = ["service": "https://pilot.example", "accountId": String(repeating: "a", count: 64), "profileId": "warrior", "revision": 7]
let adopted = try ProfileCatalog.adopt(directory, profile: original, source: source, expectedActivationRevision: 1)
let imported = adopted["adoption"] as! [String: Any]
let localID = imported["profileId"] as! String
precondition(localID.hasPrefix("cloud-") && localID.count == 46)
precondition(adopted["activationRevision"] as? Int == 2)
let retry = try ProfileCatalog.adopt(directory, profile: original, source: source, expectedActivationRevision: 2)
precondition(retry["activationRevision"] as? Int == 2, "retry created another activation")
let afterAdoption = try Data(contentsOf: directory.appendingPathComponent("store.json"))
var changed = original; changed["name"] = "Changed without new cloud revision"
do { _ = try ProfileCatalog.adopt(directory, profile: changed, source: source, expectedActivationRevision: 2); fatalError("overwrote immutable imported copy") } catch ProfileCatalog.Failure.conflict { }
do { _ = try ProfileCatalog.adopt(directory, profile: original, source: source, expectedActivationRevision: 1); fatalError("accepted stale activation") } catch ProfileCatalog.Failure.conflict { }
let afterRejectedAdoption = try Data(contentsOf: directory.appendingPathComponent("store.json"))
precondition(afterRejectedAdoption == afterAdoption)
source["revision"] = 8
let newer = try ProfileCatalog.adopt(directory, profile: original, source: source, expectedActivationRevision: 2)
precondition(newer["activationRevision"] as? Int == 3)
precondition((newer["adoption"] as! [String: Any])["profileId"] as? String != localID)
let finalStore = try ProfileCatalog.read(directory)
let originalEntry = (finalStore["profiles"] as! [[String: Any]]).first { ($0["profile"] as? [String: Any])?["id"] as? String == "warrior" }!
precondition(originalEntry["revision"] as? Int == 1, "overwrote existing local profile")
print("PASS cloud adoption: Swift/JS validation, separate immutable local IDs, stale CAS rejection, idempotent retry, independent revisions")
