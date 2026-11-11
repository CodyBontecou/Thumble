import Foundation

/// Desktop drafts share the agent/phone lock and store, but saving is separate
/// from selecting a controller for the phone.
enum WorkspaceProfiles {
    static func editable(_ entry: [String: Any]) -> Bool {
        entry["cloudSource"] == nil && (entry["desktopEdited"] as? Bool == true || entry["phoneEdited"] as? Bool == true)
    }
    static func snapshot(_ directory: URL) throws -> [String: Any] {
        let store = try ProfileCatalog.read(directory)
        let entries = store["profiles"] as? [[String: Any]] ?? []
        for entry in entries {
            guard let profile = entry["profile"] as? [String: Any] else { throw ProfileCatalog.Failure.invalid }
            try CloudProfile.validate(profile)
        }
        let active = store["active"] as? [String: Any]
        return ["profiles": entries.map { ["profile": $0["profile"]!, "revision": $0["revision"]!, "editable": editable($0)] },
                "active": active as Any? ?? NSNull(), "activationRevision": ProfileCatalog.revision(active?["revision"]) ?? 0]
    }
    static func transaction(_ directory: URL, _ operation: (inout [String: Any]) throws -> Void) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = directory.appendingPathComponent("write.lock", isDirectory: true)
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while true {
            do { try manager.createDirectory(at: lock, withIntermediateDirectories: false); break }
            catch {
                guard manager.fileExists(atPath: lock.path) else { throw error }
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw ProfileCatalog.Failure.busy }
                Thread.sleep(forTimeInterval: 0.025)
            }
        }
        defer { try? manager.removeItem(at: lock) }
        var store = try ProfileCatalog.read(directory)
        try operation(&store)
        let data = try JSONSerialization.data(withJSONObject: store, options: [.sortedKeys])
        guard data.count <= 8 * 1024 * 1024 else { throw ProfileCatalog.Failure.invalid }
        let path = directory.appendingPathComponent("store.json")
        try data.write(to: path, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
    static func validateLayout(_ profile: [String: Any], viewport: [String: Any]) throws {
        try CloudProfile.validate(profile)
        guard let name = profile["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Set(viewport.keys) == ["width", "height"], let w = CloudProfile.number(viewport["width"], 0.01, 10000),
              let h = CloudProfile.number(viewport["height"], 0.01, 10000), let controls = profile["controls"] as? [[String: Any]] else { throw ProfileCatalog.Failure.invalid }
        struct Area { var x: Double; var y: Double; var w: Double; var h: Double; var r: Double }
        var areas: [Area] = []
        for c in controls {
            let f = c["frame"] as! [String: Any]
            var a = Area(x: (f["x"] as! NSNumber).doubleValue * w, y: (f["y"] as! NSNumber).doubleValue * h,
                         w: (f["width"] as! NSNumber).doubleValue * w, h: (f["height"] as! NSNumber).doubleValue * h, r: 0)
            let minimum: Double = c["type"] as? String == "stick" ? 96 : 48
            guard min(a.w, a.h) + 0.001 >= minimum else { throw ProfileCatalog.Failure.invalid }
            if c["type"] as? String == "stick" { let d = min(a.w, a.h); a.x += (a.w-d)/2; a.y += (a.h-d)/2; a.w = d; a.h = d; a.r = d/2 }
            areas.append(a)
        }
        var reserved = [Area(x: w-44, y: 4, w: 44, h: 44, r: 0)]
        if !controls.contains(where: { $0["id"] as? String == "chat" }) { reserved.append(Area(x: w/2-26, y: 4, w: 52, h: 44, r: 0)) }
        func overlap(_ a: Area, _ b: Area) -> Bool {
            if a.r > 0 && b.r > 0 { return hypot(a.x+a.r-b.x-b.r, a.y+a.r-b.y-b.r) < a.r+b.r-0.001 }
            if a.r > 0 || b.r > 0 {
                let c = a.r > 0 ? a : b, box = a.r > 0 ? b : a, x = c.x+c.r, y = c.y+c.r
                return hypot(x-max(box.x,min(x,box.x+box.w)), y-max(box.y,min(y,box.y+box.h))) < c.r-0.001
            }
            return min(a.x+a.w,b.x+b.w)-max(a.x,b.x) > 0.001 && min(a.y+a.h,b.y+b.h)-max(a.y,b.y) > 0.001
        }
        for (i, area) in areas.enumerated() {
            guard !(Array(areas.dropFirst(i+1)) + reserved).contains(where: { overlap(area, $0) }) else { throw ProfileCatalog.Failure.invalid }
        }
    }
    static func save(_ directory: URL, profile: [String: Any], expected: Int, viewport: [String: Any]) throws {
        try validateLayout(profile, viewport: viewport)
        guard let id = profile["id"] as? String else { throw ProfileCatalog.Failure.invalid }
        try transaction(directory) { store in
            var entries = store["profiles"] as! [[String: Any]]
            if let i = entries.firstIndex(where: { ($0["profile"] as? [String: Any])?["id"] as? String == id }) {
                guard editable(entries[i]), let rev = ProfileCatalog.revision(entries[i]["revision"]), rev == expected,
                      rev < 9_007_199_254_740_991 else { throw ProfileCatalog.Failure.conflict }
                let old = try JSONSerialization.data(withJSONObject: entries[i]["profile"]!, options: [.sortedKeys])
                let new = try JSONSerialization.data(withJSONObject: profile, options: [.sortedKeys])
                if old != new { entries[i]["profile"] = profile; entries[i]["revision"] = rev+1 }
            } else {
                guard expected == 0, CloudProfile.matches(id, "^desktop-[a-f0-9]{32}$"), entries.count < 256 else { throw ProfileCatalog.Failure.invalid }
                entries.append(["profile": profile, "revision": 1, "desktopEdited": true])
            }
            store["profiles"] = entries
        }
    }
    static func remove(_ directory: URL, id: String, expected: Int, activation: Int) throws {
        try transaction(directory) { store in
            let active = store["active"] as? [String: Any]
            guard (ProfileCatalog.revision(active?["revision"]) ?? 0) == activation,
                  (active?["profile"] as? [String: Any])?["id"] as? String != id else { throw ProfileCatalog.Failure.conflict }
            var entries = store["profiles"] as! [[String: Any]]
            guard let i = entries.firstIndex(where: { ($0["profile"] as? [String: Any])?["id"] as? String == id }),
                  editable(entries[i]), ProfileCatalog.revision(entries[i]["revision"]) == expected else { throw ProfileCatalog.Failure.conflict }
            entries.remove(at: i); store["profiles"] = entries
        }
    }
}
