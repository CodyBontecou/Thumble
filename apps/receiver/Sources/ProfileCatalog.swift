import Foundation
import CoreFoundation

// Same atomic store and directory lock as the agent tools. Phone requests select
// existing revisions, or explicitly adopt validated cloud configuration. No executable input.
enum ProfileCatalog {
    enum Failure: LocalizedError {
        case invalid, conflict, busy
        var errorDescription: String? {
            switch self {
            case .invalid: return "The saved profiles could not be loaded."
            case .conflict: return "Profiles changed. Refresh the list and try again."
            case .busy: return "Profiles are busy. Try again shortly."
            }
        }
    }
    static func revision(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue >= 0, n.doubleValue <= 9_007_199_254_740_991, n.doubleValue.rounded() == n.doubleValue else { return nil }
        return n.intValue
    }
    static func read(_ directory: URL) throws -> [String: Any] {
        var store: [String: Any]
        do { store = try readSaved(directory) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            store = ["version": 1, "profiles": []]
        }
        // Command-line test binaries use the checked-in resource; app bundles ship a copy.
        let resource = Bundle.main.url(forResource: "BuiltInProfiles", withExtension: "json")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/BuiltInProfiles.json")
        guard let builtIns = try JSONSerialization.jsonObject(with: Data(contentsOf: resource)) as? [[String: Any]],
              var entries = store["profiles"] as? [[String: Any]] else { throw Failure.invalid }
        for profile in builtIns {
            guard let id = profile["id"] as? String else { throw Failure.invalid }
            if !entries.contains(where: { ($0["profile"] as? [String: Any])?["id"] as? String == id }) {
                if entries.count >= 256 { break }
                entries.append(["revision": 1, "profile": profile])
            }
        }
        store["profiles"] = entries
        return store
    }
    private static func readSaved(_ directory: URL) throws -> [String: Any] {
        let url = directory.appendingPathComponent("store.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= 8 * 1024 * 1024 else { throw Failure.invalid }
        let data = try Data(contentsOf: url)
        guard let store = try JSONSerialization.jsonObject(with: data) as? [String: Any], revision(store["version"]) == 1,
              let entries = store["profiles"] as? [[String: Any]], entries.count <= 256 else { throw Failure.invalid }
        var ids = Set<String>()
        for entry in entries {
            guard let rev = revision(entry["revision"]), rev > 0, let p = entry["profile"] as? [String: Any],
                  let id = p["id"] as? String, id.range(of: "^[a-z0-9][a-z0-9-]{0,63}$", options: .regularExpression) != nil,
                  ids.insert(id).inserted, let name = p["name"] as? String, !name.isEmpty, name.utf16.count <= 80,
                  revision(p["schemaVersion"]) == 1, try JSONSerialization.data(withJSONObject: p).count <= 60000 else { throw Failure.invalid }
        }
        if let active = store["active"], !(active is NSNull) {
            guard let a = active as? [String: Any], let rev = revision(a["revision"]), rev > 0,
                  let profileRev = revision(a["profileRevision"]), profileRev > 0,
                  a["profile"] is [String: Any] else { throw Failure.invalid }
        }
        return store
    }
    static func summary(_ store: [String: Any]) throws -> [String: Any] {
        guard let entries = store["profiles"] as? [[String: Any]] else { throw Failure.invalid }
        let active = store["active"] as? [String: Any]
        var result: [String: Any] = ["profiles": entries.map { e -> [String: Any] in
            let p = e["profile"] as! [String: Any]
            return ["id": p["id"]!, "name": p["name"]!, "revision": e["revision"]!]
        }, "activationRevision": revision(active?["revision"]) ?? 0, "agentCheckSupported": true, "cloudAdoptionSupported": true]
        if let check = store["agentConnection"] as? [String: Any],
           let code = check["code"] as? String, code.range(of: "^[a-f0-9]{12}$", options: .regularExpression) != nil,
           let checkedAt = check["checkedAt"] as? NSNumber, CFGetTypeID(checkedAt) != CFBooleanGetTypeID() {
            let age = Date().timeIntervalSince1970 - checkedAt.doubleValue / 1000
            if age.isFinite && age >= 0 && age <= 600 { result["agentConnection"] = ["code": code, "ageSeconds": age] }
        }
        if let sync = store["consolePortSync"] as? [String: Any],
           let profileId = sync["profileId"] as? String,
           profileId.range(of: "^[a-z0-9][a-z0-9-]{0,63}$", options: .regularExpression) != nil,
           let character = sync["character"] as? [String: Any], let name = character["name"] as? String,
           !name.isEmpty, name.utf16.count <= 80, !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
           let exportedAt = sync["exportedAt"] as? NSNumber, CFGetTypeID(exportedAt) != CFBooleanGetTypeID(),
           exportedAt.doubleValue.isFinite, exportedAt.doubleValue > 0, exportedAt.doubleValue <= 9_007_199_254_740_991 {
            var status: [String: Any] = ["profileId":profileId, "characterName":name, "exportedAt":exportedAt,
                "following":(active?["profile"] as? [String: Any])?["id"] as? String == profileId]
            if let count = revision(sync["buttonCount"]), (1...17).contains(count) { status["buttonCount"] = count }
            if let version = sync["consolePortVersion"] as? String, version.utf8.count <= 80 { status["consolePortVersion"] = version }
            if let page = revision(sync["actionPage"]), page <= 100 { status["actionPage"] = page }
            if let modifiers = sync["modifiers"] as? [String: String], modifiers.count <= 3,
               Set(modifiers.keys).isSubset(of: ["shift", "ctrl", "alt"]),
               modifiers.values.allSatisfy({ CloudProfile.buttons.contains($0) || CloudProfile.triggers.contains($0) || $0 == "none" }) {
                status["modifiers"] = modifiers
            }
            result["consolePortSync"] = status
        }
        return result
    }
    static func activate(_ directory: URL, id: String, profileRevision: Int, expectedActivationRevision: Int) throws -> [String: Any] {
        let manager = FileManager.default, lock = directory.appendingPathComponent("write.lock", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while true {
            do { try manager.createDirectory(at: lock, withIntermediateDirectories: false); break }
            catch {
                guard manager.fileExists(atPath: lock.path) else { throw error }
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure.busy }
                Thread.sleep(forTimeInterval: 0.025)
            }
        }
        defer { try? manager.removeItem(at: lock) }
        var store = try read(directory)
        let active = store["active"] as? [String: Any]
        guard let entries = store["profiles"] as? [[String: Any]],
              let entry = entries.first(where: { ($0["profile"] as? [String: Any])?["id"] as? String == id }),
              revision(entry["revision"]) == profileRevision,
              revision(active?["revision"]) ?? 0 == expectedActivationRevision,
              expectedActivationRevision < 9_007_199_254_740_991 else { throw Failure.conflict }
        let next = expectedActivationRevision + 1
        store["active"] = ["revision": next, "profileRevision": profileRevision, "profile": entry["profile"]!]
        let data = try JSONSerialization.data(withJSONObject: store)
        guard data.count <= 8 * 1024 * 1024 else { throw Failure.invalid }
        let path = directory.appendingPathComponent("store.json")
        try data.write(to: path, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        return try summary(store)
    }
    static func adopt(_ directory: URL, profile: [String: Any], source: [String: Any], expectedActivationRevision: Int) throws -> [String: Any] {
        try CloudProfile.validate(profile)
        let id = try CloudProfile.localID(source: source, profile: profile)
        var local = profile; local["id"] = id
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = directory.appendingPathComponent("write.lock", isDirectory: true)
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while true {
            do { try manager.createDirectory(at: lock, withIntermediateDirectories: false); break }
            catch {
                guard manager.fileExists(atPath: lock.path) else { throw error }
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure.busy }
                Thread.sleep(forTimeInterval: 0.025)
            }
        }
        defer { try? manager.removeItem(at: lock) }
        var store: [String: Any]
        do { store = try read(directory) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { store = ["version": 1, "profiles": []] }
        var entries = store["profiles"] as! [[String: Any]]
        let active = store["active"] as? [String: Any]
        let previous = revision(active?["revision"]) ?? 0
        guard expectedActivationRevision == previous, previous < 9_007_199_254_740_991 else { throw Failure.conflict }
        let canonical = try JSONSerialization.data(withJSONObject: local, options: [.sortedKeys])
        let sourceData = try JSONSerialization.data(withJSONObject: source, options: [.sortedKeys])
        if let entry = entries.first(where: { ($0["profile"] as? [String: Any])?["id"] as? String == id }) {
            guard revision(entry["revision"]) == 1, let old = entry["profile"] as? [String: Any],
                  let oldSource = entry["cloudSource"] as? [String: Any],
                  try JSONSerialization.data(withJSONObject: old, options: [.sortedKeys]) == canonical,
                  try JSONSerialization.data(withJSONObject: oldSource, options: [.sortedKeys]) == sourceData else { throw Failure.conflict }
        } else {
            guard entries.count < 256 else { throw Failure.invalid }
            entries.append(["profile": local, "revision": 1, "cloudSource": source])
        }
        // Lost-response retries reuse the same immutable local copy and activation.
        let sameActive = (active?["profile"] as? [String: Any])?["id"] as? String == id && revision(active?["profileRevision"]) == 1
        let next = sameActive ? previous : previous + 1
        store["profiles"] = entries
        store["active"] = ["revision": next, "profileRevision": 1, "profile": local]
        let data = try JSONSerialization.data(withJSONObject: store)
        guard data.count <= 8 * 1024 * 1024 else { throw Failure.invalid }
        let path = directory.appendingPathComponent("store.json")
        try data.write(to: path, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        var result = try summary(store)
        result["adoption"] = ["profileId": id, "profileRevision": 1, "source": source]
        return result
    }
}
