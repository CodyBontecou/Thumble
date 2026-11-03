import Foundation
import CryptoKit
import Darwin

/// Reads only snapshots WoW saves during reload/logout. Never executes Lua or writes game files.
final class ConsolePortSync {
    enum Failure: LocalizedError {
        case invalid, stale, changed, unsupported
        var errorDescription: String? {
            switch self {
            case .invalid: return "Invalid ConsolePort snapshot; the previous controller is retained."
            case .stale: return "Reload WoW to save a fresh ConsolePort snapshot."
            case .changed: return "Controller changed during sync; reload WoW to sync again."
            case .unsupported: return "Select a ConsolePort controller to enable automatic sync."
            }
        }
    }
    static let keyMap = ["PAD1":"a", "PAD2":"b", "PAD3":"x", "PAD4":"y", "PADLSHOULDER":"lb", "PADRSHOULDER":"rb", "PADLTRIGGER":"lt", "PADRTRIGGER":"rt", "PADBACK":"back", "PADFORWARD":"start", "PADLSTICK":"ls", "PADRSTICK":"rs", "PADDUP":"up", "PADDDOWN":"down", "PADDLEFT":"left", "PADDRIGHT":"right", "PADSYSTEM":"guide"]
    static let modifierKeys = ["", "SHIFT-", "CTRL-", "ALT-", "CTRL-SHIFT-", "ALT-SHIFT-", "ALT-CTRL-", "ALT-CTRL-SHIFT-"]
    let directory: URL
    private let roots: () -> [URL]
    private let enabled: () -> Bool
    private let lookup: (String, Int) -> String?
    private let now: () -> Date
    private let queue = DispatchQueue(label: "thumble.consoleport.sync", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var stamps: [String: Date] = [:]
    private var cache: [String: String] = [:]
    private var pending: (URL, Data)?
    private var lastStatus = ""
    var onStatus: ((String) -> Void)?

    init(directory: URL, roots: @escaping () -> [URL] = ConsolePortSync.defaultRoots,
         enabled: @escaping () -> Bool = { !UserDefaults.standard.bool(forKey: "consolePortSyncDisabled") },
         now: @escaping () -> Date = Date.init, lookup: @escaping (String, Int) -> String? = ConsolePortSync.lookupIcon) {
        self.directory = directory; self.roots = roots; self.enabled = enabled; self.now = now; self.lookup = lookup
    }
    static func defaultRoots() -> [URL] {
        if let path = ProcessInfo.processInfo.environment["TAPPING_WOW_CLIENT_DIR"] ?? UserDefaults.standard.string(forKey: "consolePortWoWFolder") {
            return [URL(fileURLWithPath: path, isDirectory: true)]
        }
        return [URL(fileURLWithPath: "/Applications/World of Warcraft", isDirectory: true)]
    }
    func start() {
        queue.async { [self] in
            poll(baseline: true) // A receiver restart must not activate an old logged-out character.
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 2, repeating: .seconds(2))
            timer.setEventHandler { [weak self] in self?.poll() }
            self.timer = timer; timer.resume()
        }
    }
    func stop() { queue.sync { timer?.cancel(); timer = nil; pending = nil } }
    private func status(_ text: String) {
        guard text != lastStatus else { return }; lastStatus = text; onStatus?(text)
    }
    private static func directories(_ url: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? []
        return Array(urls.filter { u in
            guard let values = try? u.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
            return values.isDirectory == true && values.isSymbolicLink != true
        }.prefix(512))
    }
    static func snapshotFiles(roots: [URL]) -> [URL] {
        var result: [URL] = []
        for root in roots {
            let clients = FileManager.default.fileExists(atPath: root.appendingPathComponent("WTF/Account").path) ? [root] : directories(root).filter { $0.lastPathComponent.hasPrefix("_") }
            for client in clients {
                let accountRoot = client.appendingPathComponent("WTF/Account").resolvingSymlinksInPath()
                for account in directories(accountRoot) {
                    for realm in directories(account) where realm.lastPathComponent != "SavedVariables" {
                        for character in directories(realm) {
                            let file = character.appendingPathComponent("SavedVariables/ThumbleBridge.lua")
                            let resolved = file.resolvingSymlinksInPath()
                            guard resolved.path.hasPrefix(accountRoot.path + "/"), let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]), values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                            result.append(resolved)
                            if result.count >= 512 { return result }
                        }
                    }
                }
            }
        }
        return result
    }
    /// Called on the dedicated sync queue; also directly exercised by the native fixture tests.
    func poll(baseline: Bool = false) {
        guard enabled() else { pending = nil; status("ConsolePort sync off"); return }
        let files = Self.snapshotFiles(roots: roots())
        var newest: (URL, Data, Date)?
        for file in files {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path), let stamp = attrs[.modificationDate] as? Date else { continue }
            let previous = stamps[file.path]; stamps[file.path] = stamp
            if baseline || previous == stamp { continue }
            do {
                guard let size = attrs[.size] as? NSNumber, size.intValue <= 4 * 1024 * 1024 else { throw Failure.invalid }
                let data = try Self.decodeSavedSnapshot(Data(contentsOf: file))
                _ = try Self.validateSnapshot(data, now: now())
                if newest == nil || stamp > newest!.2 { newest = (file, data, stamp) }
            } catch Failure.unsupported { /* No enabled auto-sync snapshot in this file. */ }
            catch { status("ConsolePort: \(error.localizedDescription)") }
        }
        if let newest { pending = (newest.0, newest.1) }
        guard let (file, data) = pending else {
            if lastStatus.isEmpty { status(files.isEmpty ? "ConsolePort: choose your WoW folder" : "ConsolePort: waiting for /reload") }
            return
        }
        do {
            let snapshot = try Self.validateSnapshot(data, now: now())
            let store = try ProfileCatalog.read(directory)
            let active = store["active"] as? [String: Any]
            let expected = ProfileCatalog.revision(active?["revision"]) ?? 0
            let source = active?["profile"] as? [String: Any] ?? (store["profiles"] as? [[String: Any]])?.compactMap { $0["profile"] as? [String: Any] }.first { $0["id"] as? String == "consoleport-standard" }
            guard let source, source["theme"] as? String == "consoleport" else { throw Failure.unsupported }
            let profile = try makeProfile(snapshot: snapshot, source: source)
            // Ignore a file rewritten/replaced while artwork was being resolved.
            guard try Self.decodeSavedSnapshot(Data(contentsOf: file)) == data else { throw Failure.changed }
            try Self.commit(directory: directory, profile: profile, snapshot: snapshot, sourcePath: file.path, expectedActivation: expected)
            pending = nil
            let character = snapshot["character"] as! [String: Any]
            status("ConsolePort: \(character["name"] as! String) synced after reload")
        } catch Failure.unsupported { pending = nil; status(Failure.unsupported.localizedDescription) }
        catch Failure.changed { pending = nil; status(Failure.changed.localizedDescription) }
        catch { status("ConsolePort: \(error.localizedDescription)") }
    }

    /// Decode the single syncText Lua string, without loading any Lua code.
    static func decodeSavedSnapshot(_ source: Data) throws -> Data {
        guard source.count <= 4 * 1024 * 1024, let text = String(data: source, encoding: .utf8), text.range(of: "^\\s*ThumbleBridgeDB\\s*=\\s*\\{", options: .regularExpression) != nil else { throw Failure.invalid }
        guard let range = text.range(of: "\\[\"syncText\"\\]\\s*=\\s*\"", options: .regularExpression) else { throw Failure.unsupported }
        let bytes = Array(text[range.upperBound...].utf8)
        var output = Data(), index = 0
        let escapes: [UInt8: UInt8] = [97:7, 98:8, 102:12, 110:10, 114:13, 116:9, 118:11, 92:92, 34:34, 39:39]
        while index < bytes.count {
            let byte = bytes[index]; index += 1
            if byte == 34 { return output }
            guard byte != 10 && byte != 13 && output.count < 262144 else { throw Failure.invalid }
            if byte != 92 { output.append(byte); continue }
            guard index < bytes.count else { throw Failure.invalid }
            let escape = bytes[index]; index += 1
            if (48...57).contains(escape) {
                var value = Int(escape - 48), count = 1
                while count < 3 && index < bytes.count && (48...57).contains(bytes[index]) {
                    value = value * 10 + Int(bytes[index] - 48); index += 1; count += 1
                }
                guard value <= 255 else { throw Failure.invalid }; output.append(UInt8(value))
            } else if let decoded = escapes[escape] { output.append(decoded) }
            else { throw Failure.invalid }
        }
        throw Failure.invalid
    }
    static func validateSnapshot(_ data: Data, now: Date) throws -> [String: Any] {
        guard data.count <= 262144, let s = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              ProfileCatalog.revision(s["bridgeVersion"]) == 1, s["kind"] as? String == "consoleport-sync",
              let timestamp = CloudProfile.number(s["exportedAt"], 1, 9_007_199_254_740_991),
              let character = s["character"] as? [String: Any], CloudProfile.text(character["name"]),
              CloudProfile.matches(character["guid"], "^[A-Za-z0-9-]{1,128}$"),
              let mods = s["modifiers"] as? [String: String],
              let buttons = s["consolePortLayout"] as? [[String: Any]], (1...17).contains(buttons.count) else { throw Failure.invalid }
        guard abs(now.timeIntervalSince1970 - timestamp) <= 300 else { throw Failure.stale }
        for key in ["GamePadEmulateShift", "GamePadEmulateCtrl", "GamePadEmulateAlt"] {
            guard let value = mods[key], value.uppercased() == "NONE" || Self.keyMap[value] != nil else { throw Failure.invalid }
        }
        var seen = Set<String>()
        for button in buttons {
            guard let key = button["key"] as? String, Self.keyMap[key] != nil, seen.insert(key).inserted,
                  let layers = button["layers"] as? [[String: Any]], layers.count == 8 else { throw Failure.invalid }
            var states = Set<String>()
            for layer in layers {
                guard let state = layer["modifier"] as? String, modifierKeys.contains(state), states.insert(state).inserted,
                      let label = layer["label"] as? String, !label.isEmpty, label.utf8.count <= 512, !label.contains("|"),
                      let command = layer["command"] as? String, command.utf8.count <= 512,
                      !label.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
                      !command.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw Failure.invalid }
                if let kind = layer["kind"] {
                    guard let kind = kind as? String, ["spell", "item"].contains(kind), let id = ProfileCatalog.revision(layer["id"]), id > 0, id < 2147483648 else { throw Failure.invalid }
                }
            }
        }
        return s
    }
    func makeProfile(snapshot: [String: Any], source: [String: Any]) throws -> [String: Any] {
        try CloudProfile.validate(source)
        let character = snapshot["character"] as! [String: Any]
        let guid = character["guid"] as! String
        let id = "consoleport-" + SHA256.hash(data: Data(guid.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let exported = snapshot["consolePortLayout"] as! [[String: Any]]
        let byOutput = Dictionary(uniqueKeysWithValues: exported.map { (Self.keyMap[$0["key"] as! String]!, $0) })
        let mods = snapshot["modifiers"] as! [String: String]
        let mappings = source["mappings"] as! [[String: Any]]
        let outputByControl = Dictionary(uniqueKeysWithValues: mappings.map { ($0["controlId"] as! String, ($0["outputs"] as! [String])[0]) })
        let utilityIcons = ["JUMP":"cp_jump", "INTERACTTARGET":"cp_interact", "TARGETNEARESTENEMY":"cp_target", "TARGETPREVIOUSENEMY":"cp_target", "TARGETSCANENEMY":"cp_target", "TARGETNEARESTFRIEND":"cp_interact", "TARGETPREVIOUSFRIEND":"cp_interact", "OPENALLBAGS":"cp_bags", "TOGGLEWORLDMAP":"cp_map", "TOGGLEGAMEMENU":"cp_menu", "CLICK ConsolePortQuickMenu:LeftButton":"cp_menu"]
        let utilityLabels = ["CLICK ConsolePortQuickMenu:LeftButton":"Quick menu", "CLICK ConsolePortUtilityToggle:LeftButton":"Utility ring"]
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        var attempted = Set<String>()
        let controls = try (source["controls"] as! [[String: Any]]).map { control -> [String: Any] in
            guard control["type"] as? String != "stick", let output = outputByControl[control["id"] as! String] else { return control }
            var result = control
            result.removeValue(forKey: "layers"); result.removeValue(forKey: "icon")
            guard let button = byOutput[output] else {
                if control["layers"] != nil { result["label"] = control["badge"] as? String ?? output.uppercased() }
                return result
            }
            var layers: [String: [String: Any]] = [:]
            for layer in button["layers"] as! [[String: Any]] {
                let command = layer["command"] as! String
                let empty = layer["kind"] == nil && command.range(of: "^(?:ACTIONBUTTON[0-9]+|MULTIACTIONBAR[0-9]+BUTTON[0-9]+)$", options: .regularExpression) != nil
                let label = empty ? "Unbound" : utilityLabels[command] ?? layer["label"] as! String
                var display: [String: Any] = ["label": Self.shortLabel(label)]
                var icon = utilityIcons[command]
                if let kind = layer["kind"] as? String, let spellID = ProfileCatalog.revision(layer["id"]) {
                    let reference = "\(kind):\(spellID)"
                    if cache[reference] == nil && attempted.insert(reference).inserted && ProcessInfo.processInfo.systemUptime < deadline {
                        if let resolved = lookup(kind, spellID), CloudProfile.matches(resolved, "^[a-z0-9_]{1,128}$") { cache[reference] = resolved }
                    }
                    icon = cache[reference] ?? icon
                }
                if label != "Unbound", let icon { display["icon"] = icon }
                layers[layer["modifier"] as! String] = display
            }
            guard let base = layers[""] else { throw Failure.invalid }
            result["label"] = base["label"]; result["icon"] = base["icon"]; result["layers"] = layers
            return result
        }
        let profile: [String: Any] = ["schemaVersion":1, "id":id, "name":Self.shortLabel("\(character["name"] as! String) · ConsolePort"), "theme":"consoleport", "controls":controls, "mappings":mappings,
            "modifiers":Dictionary(uniqueKeysWithValues: [("shift","GamePadEmulateShift"), ("ctrl","GamePadEmulateCtrl"), ("alt","GamePadEmulateAlt")].map { ($0.0, Self.keyMap[mods[$0.1]!] ?? "none") })]
        try CloudProfile.validate(profile)
        return profile
    }
    private static func shortLabel(_ text: String) -> String {
        var result = ""
        for character in text { if (result + String(character)).utf16.count > 80 { break }; result.append(character) }
        return result.isEmpty ? "Unbound" : result
    }
    static func commit(directory: URL, profile: [String: Any], snapshot: [String: Any], sourcePath: String, expectedActivation: Int) throws {
        try CloudProfile.validate(profile)
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
        let active = store["active"] as? [String: Any]
        guard ProfileCatalog.revision(active?["revision"]) ?? 0 == expectedActivation else { throw Failure.changed }
        let encode: (Any) throws -> Data = { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
        if try active?["profile"].map(encode) != encode(profile) {
            var entries = store["profiles"] as! [[String: Any]]
            let index = entries.firstIndex { ($0["profile"] as? [String: Any])?["id"] as? String == profile["id"] as? String }
            let revision = (index.flatMap { ProfileCatalog.revision(entries[$0]["revision"]) } ?? 0) + 1
            guard revision <= 9_007_199_254_740_991, expectedActivation < 9_007_199_254_740_991, index != nil || entries.count < 256 else { throw Failure.invalid }
            let entry: [String: Any] = ["revision": revision, "profile": profile]
            if let index { entries[index] = entry } else { entries.append(entry) }
            store["profiles"] = entries
            store["active"] = ["revision":expectedActivation + 1, "profileRevision":revision, "profile":profile]
        }
        var provenance: [String: Any] = ["sourcePath":sourcePath, "exportedAt":snapshot["exportedAt"]!, "character":snapshot["character"]!, "profileId":profile["id"]!, "modifiers":profile["modifiers"]!, "buttonCount":(snapshot["consolePortLayout"] as! [[String: Any]]).count]
        if let version = snapshot["consolePortVersion"] as? String, version.utf8.count <= 80 { provenance["consolePortVersion"] = version }
        if let page = ProfileCatalog.revision(snapshot["actionPage"]), page <= 100 { provenance["actionPage"] = page }
        store["consolePortSync"] = provenance
        let data = try encode(store)
        guard data.count <= 8 * 1024 * 1024 else { throw Failure.invalid }
        let path = directory.appendingPathComponent("store.json")
        try data.write(to: path, options: .atomic)
        try manager.setAttributes([.posixPermissions:0o600], ofItemAtPath: path.path)
    }
    private final class IconResult {
        private let lock = NSLock()
        private var value: String?
        func set(_ value: String) { lock.lock(); self.value = value; lock.unlock() }
        func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
    }
    static func lookupIcon(kind: String, id: Int) -> String? {
        guard ["spell", "item"].contains(kind), id > 0, id < 2147483648 else { return nil }
        if kind == "spell" && id == 6603 { return "ability_meleedamage" }
        let url = URL(string:"https://nether.wowhead.com/classic/tooltip/\(kind)/\(id)")!
        var request = URLRequest(url:url); request.timeoutInterval = 3
        let result = IconResult(), done = DispatchSemaphore(value:0)
        let task = URLSession.shared.dataTask(with:request) { data, response, _ in
            defer { done.signal() }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data, data.count <= 100000,
                  let json = try? JSONSerialization.jsonObject(with:data) as? [String:Any], let icon = json["icon"] as? String,
                  CloudProfile.matches(icon.lowercased(), "^[a-z0-9_]{1,128}$") else { return }
            result.set(icon.lowercased())
        }
        task.resume()
        if done.wait(timeout:.now() + 3) == .timedOut { task.cancel() }
        return result.get()
    }
}
