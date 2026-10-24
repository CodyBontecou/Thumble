import Foundation

/// Disk traffic stays off the input/watchdog queue. Agents only write declarative data.
final class ProfileBridge {
    private let queue = DispatchQueue(label: "tapping.receiver.profiles", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var lastModification: Date?
    private var lastPayload: Data?
    private var ticks = 0
    private let directory: URL = {
        if let path = ProcessInfo.processInfo.environment["TAPPING_PROFILE_DIR"] { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Tapping/profiles", isDirectory: true)
    }()
    var onActivation: ((Int, [String: Any]) -> Void)?
    var onStatusTick: (() -> Void)?
    var onError: ((String) -> Void)?
    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.poll() }
        self.timer = timer; timer.resume()
    }
    func stop() { queue.sync { timer?.cancel(); timer = nil } }
    private func poll() {
        ticks += 1
        if ticks % 4 == 0 { onStatusTick?() }
        let path = directory.appendingPathComponent("store.json")
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
            let modified = attributes[.modificationDate] as? Date
            guard modified != lastModification else { return }
            guard let size = attributes[.size] as? NSNumber, size.intValue <= 8 * 1024 * 1024 else { throw BridgeError.invalidStore }
            let data = try Data(contentsOf: path)
            guard let store = try JSONSerialization.jsonObject(with: data) as? [String: Any], store["version"] as? Int == 1 else { throw BridgeError.invalidStore }
            lastModification = modified
            guard let active = store["active"] as? [String: Any] else { return }
            let payload = try JSONSerialization.data(withJSONObject: active, options: [.sortedKeys])
            guard payload != lastPayload else { return }
            guard let revision = active["revision"] as? NSNumber, CFGetTypeID(revision) != CFBooleanGetTypeID(),
                  revision.doubleValue >= 1, revision.doubleValue <= 9_007_199_254_740_991, revision.doubleValue.rounded() == revision.doubleValue,
                  let profile = active["profile"] as? [String: Any],
                  try JSONSerialization.data(withJSONObject: profile).count <= 60000 else { throw BridgeError.invalidStore }
            lastPayload = payload
            onActivation?(revision.intValue, profile)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            // No profile has been activated yet: use the built-in phone layout.
        } catch { onError?("Profile file could not be loaded: \(error.localizedDescription)") }
    }
    func catalog(selection: (String, Int, Int)? = nil, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        queue.async { [self] in
            do {
                let result: [String: Any]
                if let (id, profileRevision, activationRevision) = selection {
                    result = try ProfileCatalog.activate(directory, id: id, profileRevision: profileRevision, expectedActivationRevision: activationRevision)
                    lastModification = nil
                    poll()
                } else {
                    do { result = try ProfileCatalog.summary(ProfileCatalog.read(directory)) }
                    catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
                        result = ["profiles": [], "activationRevision": 0, "agentCheckSupported": true]
                    }
                }
                completion(.success(result))
            } catch { completion(.failure(error)) }
        }
    }
    func adopt(profile: [String: Any], source: [String: Any], expectedActivationRevision: Int, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        queue.async { [self] in
            do {
                let result = try ProfileCatalog.adopt(directory, profile: profile, source: source, expectedActivationRevision: expectedActivationRevision)
                lastModification = nil; poll()
                completion(.success(result))
            } catch { completion(.failure(error)) }
        }
    }
    func writeStatus(_ status: [String: Any]) {
        queue.async { [self] in
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let data = try JSONSerialization.data(withJSONObject: status)
                let path = directory.appendingPathComponent("receiver-status.json")
                try data.write(to: path, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            } catch { onError?("Controller status could not be saved: \(error.localizedDescription)") }
        }
    }
    private enum BridgeError: Error { case invalidStore }
}
