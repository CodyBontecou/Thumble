import Foundation
import Darwin

/// Disk traffic stays off the input/watchdog queue. Agents only write declarative data.
final class ProfileBridge {
    private let queue = DispatchQueue(label: "tapping.receiver.profiles", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var lastModification: Date?
    private var lastPayload: Data?
    private var ticks = 0
    private var pairing: [String: Any]?
    private var consolePortStatus = "ConsolePort: waiting for /reload"
    private let directory: URL = {
        if let path = ProcessInfo.processInfo.environment["TAPPING_PROFILE_DIR"] { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Tapping/profiles", isDirectory: true)
    }()
    var onActivation: ((Int, [String: Any]) -> Void)?
    var onStatusTick: (() -> Void)?
    var onError: ((String) -> Void)?
    var onConsolePortSyncStatus: ((String) -> Void)?
    private lazy var consolePortSync = ConsolePortSync(directory: directory)
    func start() {
        consolePortSync.onStatus = { [weak self] text in
            self?.queue.async { [weak self] in self?.consolePortStatus = text }
            self?.onConsolePortSyncStatus?(text)
        }
        consolePortSync.start()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.poll() }
        self.timer = timer; timer.resume()
    }
    func stop() {
        consolePortSync.stop()
        queue.sync { timer?.cancel(); timer = nil; pairing = nil; removePairingCode() }
    }
    func updatePairingCode(_ invitation: String, expires: Double = 0) {
        queue.async { [self] in
            pairing = nil
            removePairingCode()
            guard !invitation.isEmpty else { return }
            do {
                pairing = ["version": 1, "expiresAt": Int(expires * 1000),
                           "png": try PairingCode.png(invitation).base64EncodedString()]
                publishPairingCode()
            } catch { onError?("Pairing image could not be generated.") }
        }
    }
    private func removePairingCode() {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("pairing-code.json"))
    }
    private func publishPairingCode() {
        guard var payload = pairing else { return }
        let now = Date().timeIntervalSince1970 * 1000
        guard let expires = payload["expiresAt"] as? Int, Double(expires) > now else {
            pairing = nil; removePairingCode(); return
        }
        payload["updatedAt"] = Int(now)
        let temporary = directory.appendingPathComponent("pairing-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONSerialization.data(withJSONObject: payload)
            guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]),
                  rename(temporary.path, directory.appendingPathComponent("pairing-code.json").path) == 0 else {
                throw BridgeError.invalidStore
            }
        } catch { pairing = nil; removePairingCode(); onError?("Pairing image could not be saved privately.") }
    }
    private func poll() {
        ticks += 1
        if ticks % 4 == 0 { onStatusTick?(); publishPairingCode() }
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
                    result = try ProfileCatalog.summary(ProfileCatalog.read(directory))
                }
                var catalog = result
                catalog["consolePortBridge"] = ["enabled": !UserDefaults.standard.bool(forKey: "consolePortSyncDisabled"), "detail": consolePortStatus]
                completion(.success(catalog))
            } catch { completion(.failure(error)) }
        }
    }
    func saveAndActivate(profile: [String: Any], source: [String: Any]?, expectedActivationRevision: Int, expectedProfileRevision: Int = 0, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        queue.async { [self] in
            do {
                let result: [String: Any]
                if let source {
                    result = try ProfileCatalog.adopt(directory, profile: profile, source: source, expectedActivationRevision: expectedActivationRevision)
                } else {
                    result = try ProfileCatalog.savePhoneProfile(directory, profile: profile, expectedActivationRevision: expectedActivationRevision, expectedProfileRevision: expectedProfileRevision)
                }
                lastModification = nil; poll()
                completion(.success(result))
            } catch { completion(.failure(error)) }
        }
    }
    func bindingPage(offset: Int, snapshot: String?, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        queue.async { [self] in
            completion(Result { try PhoneBindings.page(directory, offset: offset, expectedSnapshot: snapshot) })
        }
    }
    func bindingPlan(_ plan: [String: Any], completion: @escaping (Result<String, Error>) -> Void) {
        queue.async { [self] in completion(Result { try PhoneBindings.validatePlan(directory, plan: plan) }) }
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
