import Foundation
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let store = try ProfileCatalog.read(directory)
let list = try ProfileCatalog.summary(store)
precondition((list["profiles"] as! [[String: Any]]).count == 2)
precondition(ProfileCatalog.revision(true) == nil)
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
