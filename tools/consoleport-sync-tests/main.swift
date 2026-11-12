import Foundation
func check(_ value: @autoclosure () throws -> Bool, _ message: String = "") throws { let result = try value(); precondition(result, message) }
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let directory = root.appendingPathComponent("profiles")
let game = root.appendingPathComponent("_classic_era_")
let file = game.appendingPathComponent("WTF/Account/123/Realm/Hero/SavedVariables/ThumbleBridge.lua")
let manager = FileManager.default
try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
let instant = Date()
func encode(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
func snapshot(_ name: String = "Hero", guid: String = "Player-123-456", label: String = "Attack") -> [String: Any] {
    ["bridgeVersion":1, "kind":"consoleport-sync", "exportedAt":instant.timeIntervalSince1970,
     "character":["name":name, "guid":guid], "modifiers":["GamePadEmulateShift":"PADLTRIGGER", "GamePadEmulateCtrl":"PADRTRIGGER", "GamePadEmulateAlt":"NONE"],
     "consolePortLayout":[["key":"PAD1", "layers":ConsolePortSync.modifierKeys.map { state -> [String:Any] in
        ["modifier":state, "label": state.isEmpty ? label : "Modified Attack", "command":"ACTIONBUTTON1", "kind":"spell", "id":6603]
     }], ["key":"PAD2", "layers":ConsolePortSync.modifierKeys.map { ["modifier":$0, "label":"Jump", "command":"JUMP"] }]]]
}
func saved(_ data: Data) -> Data {
    let escaped = String(data:data, encoding:.utf8)!.replacingOccurrences(of:"\\", with:"\\\\").replacingOccurrences(of:"\"", with:"\\\"")
    return Data("ThumbleBridgeDB = {\n [\"exportText\"] = \"manual export stays separate\",\n [\"syncText\"] = \"\(escaped)\",\n}".utf8)
}
var stamp = instant
func write(_ data: Data) throws {
    try saved(data).write(to:file, options:.atomic)
    stamp = stamp.addingTimeInterval(1)
    try manager.setAttributes([.modificationDate:stamp], ofItemAtPath:file.path)
}
func rejects(_ operation: () throws -> Void) {
    do { try operation(); fatalError("accepted invalid data") } catch { }
}
let data = try encode(snapshot())
try check(try ConsolePortSync.decodeSavedSnapshot(saved(data)) == data)
let decimal = Data("ThumbleBridgeDB = {[\"syncText\"]=\"\\123\\034x\\034\\0581\\125\"}".utf8)
try check(try ConsolePortSync.decodeSavedSnapshot(decimal) == Data("{\"x\":1}".utf8))
for text in ["return os.execute('bad')", "ThumbleBridgeDB = {[\"syncText\"]=\"\\999\"}", "ThumbleBridgeDB = {[\"syncText\"]=\"unterminated", "ThumbleBridgeDB = {[\"syncText\"]=\"\\q\"}"] {
    rejects { _ = try ConsolePortSync.decodeSavedSnapshot(Data(text.utf8)) }
}
var old = snapshot(); old["exportedAt"] = instant.timeIntervalSince1970 - 301
rejects { _ = try ConsolePortSync.validateSnapshot(encode(old), now:instant) }
var bad = snapshot(); bad["bridgeVersion"] = true
rejects { _ = try ConsolePortSync.validateSnapshot(encode(bad), now:instant) }
bad = snapshot(); bad["modifiers"] = ["GamePadEmulateShift":"KEYBOARD"]
rejects { _ = try ConsolePortSync.validateSnapshot(encode(bad), now:instant) }
var duplicate = snapshot(); duplicate["consolePortLayout"] = [((duplicate["consolePortLayout"] as! [[String:Any]])[0]), ((duplicate["consolePortLayout"] as! [[String:Any]])[0])]
rejects { _ = try ConsolePortSync.validateSnapshot(encode(duplicate), now:instant) }
print("PASS bounded Lua string decoding, invalid escapes, stale snapshots, invalid schema and duplicate controls")

var enabled = true, lookups = 0
let sync = ConsolePortSync(directory:directory, roots:{ [game] }, enabled:{ enabled }, now:{ instant }, lookup:{ _,_ in lookups += 1; return "ability_meleedamage" })
try write(data)
sync.poll(baseline:true)
try check((try ProfileCatalog.read(directory))["active"] == nil, "startup imported an old character")
try write(data)
sync.poll()
let store = try ProfileCatalog.read(directory)
let active = store["active"] as! [String:Any], profile = active["profile"] as! [String:Any]
let summary = try ProfileCatalog.summary(store)
let provenance = summary["consolePortSync"] as! [String:Any]
try check(provenance["characterName"] as? String == "Hero" && provenance["following"] as? Bool == true)
try check(provenance["sourcePath"] == nil && provenance["character"] == nil, "private filesystem/character identifiers leaked")
try check(provenance["buttonCount"] as? Int == 2)
try check((provenance["modifiers"] as? [String:String])?["shift"] == "lt")
try check(active["revision"] as? Int == 1 && lookups == 1)
let original = ((store["profiles"] as! [[String:Any]]).first { ($0["profile"] as? [String:Any])?["id"] as? String == "consoleport-standard" })!["profile"] as! [String:Any]
try check(try encode(profile["mappings"]!) == encode(original["mappings"]!))
let controls = profile["controls"] as! [[String:Any]], originals = original["controls"] as! [[String:Any]]
for (control, source) in zip(controls, originals) { try check(try encode(control["frame"]!) == encode(source["frame"]!)) }
let aID = (profile["mappings"] as! [[String:Any]]).first { ($0["outputs"] as? [String]) == ["a"] }!["controlId"] as! String
let a = controls.first { $0["id"] as? String == aID }!
try check(a["icon"] as? String == "ability_meleedamage")
try check((a["layers"] as! [String:Any]).count == 8)
try check((profile["modifiers"] as! [String:String]) == ["shift":"lt", "ctrl":"rt", "alt":"none"])
try write(data); sync.poll()
try check(((try ProfileCatalog.read(directory))["active"] as! [String:Any])["revision"] as? Int == 1, "identical reload churned activation")
try check(lookups == 1, "artwork cache missed")
print("PASS reload import, all eight layers, actual modifiers, cached icons, preserved geometry/mappings and idempotence")

let before = try Data(contentsOf:directory.appendingPathComponent("store.json"))
try write(encode(old)); sync.poll()
try check(try Data(contentsOf:directory.appendingPathComponent("store.json")) == before)
enabled = false
try write(encode(snapshot(label:"New Attack"))); sync.poll()
try check(try Data(contentsOf:directory.appendingPathComponent("store.json")) == before)
enabled = true; sync.poll()
try check(((try ProfileCatalog.read(directory))["active"] as! [String:Any])["revision"] as? Int == 2)
rejects { try ConsolePortSync.commit(directory:directory, profile:profile, snapshot:snapshot(), sourcePath:file.path, expectedActivation:1) }
let other = try ProfileCatalog.activate(directory, id:"xbox-standard", profileRevision:1, expectedActivationRevision:2)
try check(other["activationRevision"] as? Int == 3)
try check((other["consolePortSync"] as? [String:Any])?["following"] as? Bool == false, "another profile was reported as following")
try write(encode(snapshot("Other", guid:"Player-123-789"))); sync.poll()
try check(((try ProfileCatalog.read(directory))["active"] as! [String:Any])["revision"] as? Int == 3, "sync replaced a non-ConsolePort controller")
_ = try ProfileCatalog.activate(directory, id:profile["id"] as! String, profileRevision:2, expectedActivationRevision:3)
try write(encode(snapshot("Other", guid:"Player-123-789"))); sync.poll()
let final = (try ProfileCatalog.read(directory))["active"] as! [String:Any]
try check((final["profile"] as! [String:Any])["id"] as? String != profile["id"] as? String)
let link = game.appendingPathComponent("WTF/Account/123/Realm/Linked")
try manager.createSymbolicLink(at:link, withDestinationURL:file.deletingLastPathComponent().deletingLastPathComponent())
try check(ConsolePortSync.snapshotFiles(roots:[root]).count == 1)
print("PASS stale file retention, opt-out, stale writer rejection, theme guard, character switching and symlink exclusion")

let raceDirectory = root.appendingPathComponent("race-profiles")
var rewrite = true
let racing = ConsolePortSync(directory:raceDirectory, roots:{ [game] }, now:{ instant }, lookup:{ _,_ in
    if rewrite { rewrite = false; try! write(encode(snapshot("Replacement", guid:"Player-123-999"))) }
    return "ability_meleedamage"
})
racing.poll(baseline:true)
try write(encode(snapshot("Before rewrite")))
racing.poll()
try check((try ProfileCatalog.read(raceDirectory))["active"] == nil, "published a snapshot replaced during artwork lookup")
racing.poll()
let replacement = ((try ProfileCatalog.read(raceDirectory))["active"] as! [String:Any])["profile"] as! [String:Any]
try check((replacement["name"] as! String).hasPrefix("Replacement"))
let offline = ConsolePortSync(directory:root.appendingPathComponent("offline"), lookup:{ _,_ in "../invalid" })
let fallback = try offline.makeProfile(snapshot:snapshot(), source:original)
let offlineA = (fallback["controls"] as! [[String:Any]]).first { $0["id"] as? String == aID }!
try check(offlineA["icon"] == nil && offlineA["label"] as? String == "Attack", "unsafe artwork name escaped validation")
print("PASS file-replacement race rejection and safe text fallback when artwork cannot resolve")

// A refreshed spell belongs to the mapped output. An edited profile keeps
// its own identity, placement, user labels and future write ownership.
var edited = profile
edited["id"] = "phone-" + String(repeating: "1", count: 32)
edited["name"] = "My layout"
var editedControls = controls
let aIndex = editedControls.firstIndex { $0["id"] as? String == aID }!
editedControls[aIndex]["label"] = "My label"
editedControls[aIndex]["frame"] = ["x":0.1, "y":0.2, "width":0.1, "height":0.2]
edited["controls"] = editedControls
let previous = ((try ProfileCatalog.read(directory))["active"] as! [String:Any])["revision"] as! Int
_ = try ProfileCatalog.savePhoneProfile(directory, profile:edited, expectedActivationRevision:previous)
try write(encode(snapshot("Hero", label:"New ability"))); sync.poll()
let refreshedActive = (try ProfileCatalog.read(directory))["active"] as! [String:Any]
let refreshed = refreshedActive["profile"] as! [String:Any]
let refreshedControl = (refreshed["controls"] as! [[String:Any]])[aIndex]
try check(refreshed["id"] as? String == edited["id"] as? String && refreshed["name"] as? String == "My layout")
try check(try encode(refreshed["mappings"]!) == encode(edited["mappings"]!))
try check(try encode(refreshedControl["frame"]!) == encode(editedControls[aIndex]["frame"]!))
try check(refreshedControl["label"] as? String == "My label")
try check((refreshedControl["layers"] as? [String:[String:Any]])?[""]?["label"] as? String == "New ability")
_ = try ProfileCatalog.savePhoneProfile(directory, profile:refreshed, expectedActivationRevision:refreshedActive["revision"] as! Int)
print("PASS edited layouts retain identity, geometry, labels, mappings and write ownership through ConsolePort reload")

var desktop = ((try ProfileCatalog.read(directory))["profiles"] as! [[String:Any]]).compactMap { $0["profile"] as? [String:Any] }.first { $0["id"] as? String == "consoleport-standard" }!
desktop["id"] = "desktop-" + String(repeating: "b", count: 32)
desktop["name"] = "My desktop layout"
let viewport: [String: Any] = ["width":844, "height":390]
try WorkspaceProfiles.save(directory, profile:desktop, expected:0, viewport:viewport)
let priorActive = ((try ProfileCatalog.read(directory))["active"] as! [String:Any])["revision"] as! Int
_ = try ProfileCatalog.activate(directory, id:desktop["id"] as! String, profileRevision:1, expectedActivationRevision:priorActive)
try write(encode(snapshot("Hero", label:"Desktop ability"))); sync.poll()
var desktopStore = try ProfileCatalog.read(directory)
let desktopActive = desktopStore["active"] as! [String:Any]
let desktopEntry = (desktopStore["profiles"] as! [[String:Any]]).first { ($0["profile"] as? [String:Any])?["id"] as? String == desktop["id"] as? String }!
try check(desktopEntry["desktopEdited"] as? Bool == true)
try check((desktopActive["profile"] as? [String:Any])?["name"] as? String == "My desktop layout")
var unsent = desktopEntry["profile"] as! [String:Any]; unsent["name"] = "Unsent desktop draft"
try WorkspaceProfiles.save(directory, profile:unsent, expected:desktopEntry["revision"] as! Int, viewport:viewport)
try write(encode(snapshot("Hero", label:"Later desktop ability"))); sync.poll()
desktopStore = try ProfileCatalog.read(directory)
let unsentEntry = (desktopStore["profiles"] as! [[String:Any]]).first { ($0["profile"] as? [String:Any])?["id"] as? String == desktop["id"] as? String }!
try check((unsentEntry["profile"] as? [String:Any])?["name"] as? String == "Unsent desktop draft")
try check((desktopStore["active"] as? [String:Any])?["revision"] as? Int == desktopActive["revision"] as? Int)
print("PASS desktop layout identity and unsent draft survive ConsolePort label sync")
