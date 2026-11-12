import Foundation
import AppKit

/// Reads only the character file already selected by ConsolePort sync.
/// The phone can prepare a proposal. WoW remains responsible for reviewing it.
enum PhoneBindings {
    enum Failure: LocalizedError {
        case unavailable, changed, invalid
        var errorDescription: String? {
            switch self {
            case .unavailable: return "Install the updated Thumble addon, then type /reload in WoW with ConsolePort sync enabled."
            case .changed: return "Your character, layout or bindings changed. Refresh and choose the action again."
            case .invalid: return "The binding proposal could not be validated."
            }
        }
    }
    static let keyMap = Dictionary(uniqueKeysWithValues: ConsolePortSync.keyMap.map { ($0.value, $0.key) })
    static let utilities: Set<String> = ["JUMP", "OPENCHAT", "TARGETNEARESTENEMY", "TARGETPREVIOUSENEMY", "TARGETSELF", "OPENALLBAGS", "TOGGLEWORLDMAP", "TOGGLECHARACTER0", "TOGGLEGAMEMENU", "INTERACTTARGET"]
    static func snapshot(_ directory: URL) throws -> [String: Any] {
        let store = try ProfileCatalog.read(directory)
        guard let sync = store["consolePortSync"] as? [String: Any],
              let path = sync["sourcePath"] as? String,
              ConsolePortSync.snapshotFiles(roots: ConsolePortSync.defaultRoots()).contains(where: { $0.path == path }),
              let character = sync["character"] as? [String: Any] else { throw Failure.unavailable }
        let file = URL(fileURLWithPath: path)
        guard let size = (try FileManager.default.attributesOfItem(atPath: path))[.size] as? NSNumber, size.intValue <= 4 * 1024 * 1024 else { throw Failure.invalid }
        let data: Data
        do { data = try ConsolePortSync.decodeSavedSnapshot(Data(contentsOf: file), field: "phoneExportText") }
        catch { throw Failure.unavailable }
        guard var value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              ProfileCatalog.revision(value["bridgeVersion"]) == 1, value["kind"] as? String == "character",
              let identity = value["character"] as? [String: Any], identity["guid"] as? String == character["guid"] as? String,
              CloudProfile.text(identity["name"]), let snapshotID = value["snapshotId"] as? String, !snapshotID.isEmpty, snapshotID.utf8.count <= 128,
              let scope = ProfileCatalog.revision(value["bindingSet"]), [1, 2].contains(scope),
              CloudProfile.number(value["exportedAt"], 1, 9_007_199_254_740_991) != nil,
              let spells = value["spells"] as? [[String: Any]], spells.count <= 2048,
              let bindings = value["bindings"] as? [[String: Any]], bindings.count <= 256,
              value["reserved"] is [String: String] else { throw Failure.invalid }
        for spell in spells {
            guard let id = ProfileCatalog.revision(spell["id"]), id > 0,
                  let name = spell["name"] as? String, !name.isEmpty, name.utf16.count <= 256,
                  let passive = spell["passive"], CloudProfile.boolean(passive) else { throw Failure.invalid }
        }
        if let receiptData = try? ConsolePortSync.decodeSavedSnapshot(Data(contentsOf: file), field: "receiptText"),
           let receipt = try? JSONSerialization.jsonObject(with: receiptData) as? [String: Any],
           receipt["kind"] as? String == "binding-receipt", let planID = receipt["planId"] as? String,
           receipt["characterGuid"] as? String == identity["guid"] as? String,
           ProfileCatalog.revision(receipt["bindingSet"]) == scope,
           let results = receipt["results"] as? [[String: Any]], !results.isEmpty,
           results.allSatisfy({ row in
               guard let key = row["key"] as? String, let command = row["command"] as? String,
                     let current = bindings.first(where: { $0["key"] as? String == key }) else { return false }
               return current["base"] as? String == command && current["effective"] as? String == command
           }) {
            value["phoneReceipt"] = ["planId": planID, "status": "verified"]
        }
        return value
    }
    static func page(_ directory: URL, offset: Int, expectedSnapshot: String?) throws -> [String: Any] {
        let value = try snapshot(directory)
        if let expectedSnapshot, expectedSnapshot != value["snapshotId"] as? String { throw Failure.changed }
        let spells = (value["spells"] as! [[String: Any]]).filter { $0["passive"] as? Bool == false }
        guard offset >= 0, offset <= spells.count else { throw Failure.invalid }
        let bindings = (value["bindings"] as! [[String: Any]]).filter { keyMap.values.contains($0["key"] as? String ?? "") }
        var end = min(offset + 32, spells.count)
        var result: [String: Any] = ["snapshotId": value["snapshotId"]!, "character": value["character"]!, "bindingSet": value["bindingSet"]!,
                                    "exportedAt": value["exportedAt"]!, "reserved": value["reserved"]!, "bindings": bindings]
        if let receipt = value["phoneReceipt"] { result["receipt"] = receipt }
        while true {
            result["spells"] = Array(spells[offset..<end])
            result["nextOffset"] = end < spells.count ? end : NSNull()
            if try JSONSerialization.data(withJSONObject: result).count <= 58000 { break }
            guard end > offset else { throw Failure.invalid }; end -= 1
        }
        return result
    }
    static func validatePlan(_ directory: URL, plan: [String: Any]) throws -> String {
        let snapshot = try snapshot(directory)
        let store = try ProfileCatalog.read(directory)
        guard let active = store["active"] as? [String: Any], let profile = active["profile"] as? [String: Any],
              let reference = plan["profile"] as? [String: Any],
              reference["id"] as? String == profile["id"] as? String, reference["name"] as? String == profile["name"] as? String,
              ProfileCatalog.revision(reference["revision"]) == ProfileCatalog.revision(active["profileRevision"]),
              CloudProfile.keys(plan, ["bridgeVersion", "kind", "id", "snapshotId", "characterGuid", "bindingSet", "profile", "changes"]),
              ProfileCatalog.revision(plan["bridgeVersion"]) == 1, plan["kind"] as? String == "binding-plan", CloudProfile.text(plan["id"]),
              plan["snapshotId"] as? String == snapshot["snapshotId"] as? String,
              plan["characterGuid"] as? String == (snapshot["character"] as? [String: Any])?["guid"] as? String,
              ProfileCatalog.revision(plan["bindingSet"]) == ProfileCatalog.revision(snapshot["bindingSet"]),
              let changes = plan["changes"] as? [[String: Any]], (1...32).contains(changes.count),
              let mappings = profile["mappings"] as? [[String: Any]], let controls = profile["controls"] as? [[String: Any]] else { throw Failure.changed }
        let reserved = snapshot["reserved"] as! [String: String]
        let bindings = snapshot["bindings"] as! [[String: Any]]
        let spells = snapshot["spells"] as! [[String: Any]]
        var keys = Set<String>(), ids = Set<String>()
        for change in changes {
            guard CloudProfile.keys(change, ["controlId", "label", "key", "expectedBase", "expectedEffective", "spellId", "action"]),
                  let id = change["controlId"] as? String, id != "chat", ids.insert(id).inserted,
                  controls.contains(where: { $0["id"] as? String == id && $0["type"] as? String != "stick" }),
                  let mapping = mappings.first(where: { $0["controlId"] as? String == id }), let output = (mapping["outputs"] as? [String])?.first,
                  let key = keyMap[output], key == change["key"] as? String, keys.insert(key).inserted, reserved[key] == nil,
                  let binding = bindings.first(where: { $0["key"] as? String == key }),
                  let base = binding["base"] as? String, let effective = binding["effective"] as? String,
                  base == change["expectedBase"] as? String, effective == change["expectedEffective"] as? String,
                  base == effective || (binding["consolePortProxy"] as? Bool == true && effective == "CLICK CPB_\(key):ControllerInput" && base.range(of: "^(?:ACTIONBUTTON[0-9]+|MULTIACTIONBAR[0-9]+BUTTON[0-9]+)$", options: .regularExpression) != nil),
                  CloudProfile.text(change["label"]) else { throw Failure.invalid }
            if let spell = ProfileCatalog.revision(change["spellId"]) {
                guard change["action"] == nil, spells.contains(where: { ProfileCatalog.revision($0["id"]) == spell && $0["passive"] as? Bool == false }) else { throw Failure.invalid }
            } else {
                guard change["spellId"] == nil, let action = change["action"] as? String, utilities.contains(action) else { throw Failure.invalid }
            }
        }
        let data = try JSONSerialization.data(withJSONObject: plan, options: [.sortedKeys])
        guard data.count <= 58000, let text = String(data: data, encoding: .utf8) else { throw Failure.invalid }
        return text
    }
    @MainActor static func copy(_ text: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }
}
