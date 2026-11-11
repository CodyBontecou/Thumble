import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}
let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[1])
let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as! [String: Any]
let base = fixture["profile"] as! [String: Any], viewport = fixture["viewport"] as! [String: Any]
let id = base["id"] as! String
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("thumble-workspace-contract-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: directory) }
for (index, step) in (fixture["steps"] as! [[String: Any]]).enumerated() {
    let storeURL = directory.appendingPathComponent("store.json")
    let before = try? Data(contentsOf: storeURL)
    var failed = false
    do {
        let expected = step["expected"] as! Int
        switch step["operation"] as! String {
        case "save":
            var profile = base; profile["name"] = step["name"]
            if step["small"] as? Bool == true {
                var controls = profile["controls"] as! [[String: Any]], frame = controls[0]["frame"] as! [String: Any]
                frame["width"] = 0.01; controls[0]["frame"] = frame; profile["controls"] = controls
            }
            try WorkspaceProfiles.save(directory, profile: profile, expected: expected, viewport: viewport)
        case "activate":
            let entries = try ProfileCatalog.read(directory)["profiles"] as! [[String: Any]]
            let entry = entries.first(where: { ($0["profile"] as? [String: Any])?["id"] as? String == id })!
            try WorkspaceProfiles.validateLayout(entry["profile"] as! [String: Any], viewport: viewport)
            _ = try ProfileCatalog.activate(directory, id: id, profileRevision: expected, expectedActivationRevision: step["activation"] as! Int)
        default: try WorkspaceProfiles.remove(directory, id: id, expected: expected, activation: step["activation"] as! Int)
        }
    } catch { failed = true }
    check(failed == (step["error"] as? Bool ?? false), "Unexpected operation result at step \(index)")
    if failed { check((try? Data(contentsOf: storeURL)) == before, "Failed transaction changed disk at step \(index)") }
    let state = try WorkspaceProfiles.snapshot(directory), entries = state["profiles"] as! [[String: Any]]
    let entry = entries.first(where: { ($0["profile"] as? [String: Any])?["id"] as? String == id })!
    check(entry["revision"] as? Int == step["profileRevision"] as? Int, "Profile revision differs at step \(index)")
    check(state["activationRevision"] as? Int == step["activationRevision"] as? Int, "Activation differs at step \(index)")
    if let name = step["activeName"] as? String {
        let active = state["active"] as! [String: Any]
        check((active["profile"] as? [String: Any])?["name"] as? String == name, "Saving a draft activated it at step \(index)")
    }
}
print("PASS: shared desktop workspace contract (\((fixture["steps"] as! [Any]).count) operations)")
