import Foundation
import CoreFoundation
import CryptoKit

/// Phone-relayed configuration only. Never fetches URLs or executes profile data.
/// Keep validation equivalent to packages/controller/src/controller.js.
enum CloudProfile {
    static let buttons: Set<String> = ["a", "b", "x", "y", "lb", "rb", "back", "start", "ls", "rs", "up", "down", "left", "right", "guide"]
    static let axes: Set<String> = ["lx", "ly", "rx", "ry"]
    static let triggers: Set<String> = ["lt", "rt"]
    static func keys(_ object: [String: Any], _ allowed: Set<String>) -> Bool { Set(object.keys).isSubset(of: allowed) }
    static func text(_ value: Any?) -> Bool { guard let s = value as? String else { return false }; return (1...80).contains(s.utf16.count) }
    static func matches(_ value: Any?, _ pattern: String) -> Bool { guard let s = value as? String else { return false }; return s.range(of: pattern, options: .regularExpression) != nil }
    static func number(_ value: Any?, _ min: Double, _ max: Double) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite, (min...max).contains(n.doubleValue) else { return nil }; return n.doubleValue
    }
    static func boolean(_ value: Any) -> Bool { guard let n = value as? NSNumber else { return false }; return CFGetTypeID(n) == CFBooleanGetTypeID() }
    static func validate(_ profile: [String: Any]) throws {
        guard keys(profile, ["schemaVersion", "id", "name", "controls", "mappings", "theme", "modifiers"]),
              ProfileCatalog.revision(profile["schemaVersion"]) == 1,
              matches(profile["id"], "^[a-z0-9][a-z0-9-]{0,63}$"), text(profile["name"]),
              profile["theme"] == nil || profile["theme"] as? String == "consoleport",
              let controls = profile["controls"] as? [[String: Any]], (1...64).contains(controls.count),
              let mappings = profile["mappings"] as? [[String: Any]], mappings.count == controls.count,
              try JSONSerialization.data(withJSONObject: profile).count <= 60000 else { throw ProfileCatalog.Failure.invalid }
        if let value = profile["modifiers"] {
            guard let mods = value as? [String: String], keys(mods, ["shift", "ctrl", "alt"]), mods.values.allSatisfy({ buttons.union(triggers).union(["none"]).contains($0) }) else { throw ProfileCatalog.Failure.invalid }
        }
        var ids: [String: String] = [:]
        for c in controls {
            guard keys(c, ["id", "type", "label", "frame", "color", "icon", "badge", "layers"]), text(c["id"]), text(c["label"]),
                  let id = c["id"] as? String, ids[id] == nil, let type = c["type"] as? String, ["button", "trigger", "stick"].contains(type),
                  let frame = c["frame"] as? [String: Any], keys(frame, ["x", "y", "width", "height"]),
                  let x = number(frame["x"], 0, 1), let y = number(frame["y"], 0, 1),
                  let width = number(frame["width"], 0.01, 1), let height = number(frame["height"], 0.01, 1),
                  x + width <= 1.000001, y + height <= 1.000001 else { throw ProfileCatalog.Failure.invalid }
            if let color = c["color"], !matches(color, "^#[0-9a-fA-F]{6}$") { throw ProfileCatalog.Failure.invalid }
            if let icon = c["icon"], !matches(icon, "^[a-z0-9_]{1,128}$") { throw ProfileCatalog.Failure.invalid }
            if let badge = c["badge"], !text(badge) { throw ProfileCatalog.Failure.invalid }
            if let value = c["layers"] {
                guard let layers = value as? [String: [String: Any]], Set(layers.keys).isSubset(of: ["", "SHIFT-", "CTRL-", "ALT-", "CTRL-SHIFT-", "ALT-SHIFT-", "ALT-CTRL-", "ALT-CTRL-SHIFT-"]) else { throw ProfileCatalog.Failure.invalid }
                for layer in layers.values {
                    guard keys(layer, ["label", "icon"]), text(layer["label"]) else { throw ProfileCatalog.Failure.invalid }
                    if let icon = layer["icon"], !matches(icon, "^[a-z0-9_]{1,128}$") { throw ProfileCatalog.Failure.invalid }
                }
            }
            ids[id] = type
        }
        var mapped = Set<String>(), owned = Set<String>()
        for m in mappings {
            guard keys(m, ["controlId", "outputs", "deadzone", "sensitivity", "invertX", "invertY"]),
                  let id = m["controlId"] as? String, let type = ids[id], mapped.insert(id).inserted,
                  let outputs = m["outputs"] as? [String] else { throw ProfileCatalog.Failure.invalid }
            switch type {
            case "button": guard outputs.count == 1, buttons.contains(outputs[0]) else { throw ProfileCatalog.Failure.invalid }
            case "trigger": guard outputs.count == 1, triggers.contains(outputs[0]) else { throw ProfileCatalog.Failure.invalid }
            default: guard outputs == ["lx", "ly"] || outputs == ["rx", "ry"] else { throw ProfileCatalog.Failure.invalid }
            }
            if let d = m["deadzone"], type != "stick" || number(d, 0, 0.5) == nil { throw ProfileCatalog.Failure.invalid }
            if let s = m["sensitivity"], type != "stick" || number(s, 0.1, 3) == nil { throw ProfileCatalog.Failure.invalid }
            for key in ["invertX", "invertY"] { if let value = m[key], type != "stick" || !boolean(value) { throw ProfileCatalog.Failure.invalid } }
            for output in outputs where axes.union(triggers).contains(output) { guard owned.insert(output).inserted else { throw ProfileCatalog.Failure.invalid } }
        }
    }
    static func localID(source: [String: Any], profile: [String: Any]) throws -> String {
        guard keys(source, ["service", "accountId", "profileId", "revision"]), source.count == 4,
              let service = source["service"] as? String, service.utf8.count <= 2048,
              let url = URLComponents(string: service), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              matches(source["accountId"], "^[a-f0-9]{64}$"),
              source["profileId"] as? String == profile["id"] as? String,
              let revision = ProfileCatalog.revision(source["revision"]), revision > 0 else { throw ProfileCatalog.Failure.invalid }
        let data = try JSONSerialization.data(withJSONObject: source, options: [.sortedKeys])
        return "cloud-" + SHA256.hash(data: data).prefix(20).map { String(format: "%02x", $0) }.joined()
    }
}
