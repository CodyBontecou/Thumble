import Foundation
import CryptoKit

// All disk and signature work happens on this utility queue, never on HID's queue.
final class AccessSession {
    private let queue = DispatchQueue(label: "tapping.receiver.access", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let directory: URL
    private let publicKey: String
    private let now: () -> Double
    private let wallNow: () -> Double
    private var current: [String: Any] = [:]
    private var used = 0.0
    private var deadline = 0.0
    private var running = false
    private var pro = false
    private var grantExpires = 0.0
    private var grantIssued = 0.0
    private var nonce = UUID().uuidString
    private(set) var receiverID = UUID().uuidString
    private var phoneID = ""
    private var cachedGrant: [String: Any]?
    private var error = ""
    var onChange: (([String: Any], Double) -> Void)?
    init(directory: URL, publicKey: String, now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }, wallNow: @escaping () -> Double = { Date().timeIntervalSince1970 }) {
        self.directory = directory; self.publicKey = publicKey; self.now = now; self.wallNow = wallNow
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = directory.appendingPathComponent("demo.json")
            if FileManager.default.fileExists(atPath: url.path) {
                let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
                guard let id = object?["receiverId"] as? String, UUID(uuidString: id) != nil,
                      let seconds = object?["used"] as? Double, seconds.isFinite, (0...1800).contains(seconds) else { throw AccessError.invalid }
                receiverID = id; used = seconds
            } else { try persist() }
            if let data = try? Data(contentsOf: directory.appendingPathComponent("pro-grant.json")),
               let grant = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                cachedGrant = grant
            }
        } catch { used = 1800; self.error = "Demo record could not be loaded. Restore Pro or contact support." }
    }
    func snapshot() -> [String: Any] { queue.sync { tick(); return current } }
    func begin() {
        queue.async {
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(250))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer; timer.resume()
        }
    }
    func stop() { queue.sync { pauseNow(); timer?.cancel(); timer = nil } }
    func pair(phoneID: String, mirroredUsed: Double) {
        queue.async {
            self.pauseNow(); self.nonce = UUID().uuidString
            self.phoneID = phoneID; self.pro = false
            if let grant = self.cachedGrant { try? self.acceptGrant(grant, requireNonce: false) }
            self.used = max(self.used, min(1800, max(0, mirroredUsed)))
            self.saveOrExhaust(); self.emit()
        }
    }
    func start() {
        queue.async {
            guard !self.running else { self.emit(); return }
            let now = self.now()
            if self.pro { self.running = true; self.emit(); return }
            let reserve = min(5, 1800 - self.used)
            guard reserve > 0 else { self.emit(); return }
            self.used += reserve
            guard self.saveOrExhaust() else { self.emit(); return }
            self.running = true; self.deadline = now + reserve
            self.emit()
        }
    }
    func pause() { queue.async { self.pauseNow(); self.emit() } }
    func submitGrant(_ grant: [String: Any]) {
        queue.async {
            do {
                try self.acceptGrant(grant, requireNonce: true)
                try self.write(grant, name: "pro-grant.json"); self.cachedGrant = grant
                // Ownership changes always require an explicit Resume from neutral input.
                self.pauseNow(); self.error = ""
            } catch { self.error = "Pro could not be verified on this Mac. Retry Restore Purchases." }
            self.emit()
        }
    }
    private func tick() {
        let now = self.now()
        if pro && self.wallNow() >= grantExpires { pro = false; pauseNow() }
        if running && !pro {
            if now >= deadline { running = false }
            else if deadline - now <= 1 && used < 1800 {
                let reserve = min(5, 1800 - used)
                used += reserve
                if saveOrExhaust() { deadline += reserve } else { running = false }
            }
        }
        emit()
    }
    private func pauseNow() {
        if running && !pro {
            used = max(0, used - max(0, deadline - self.now()))
            saveOrExhaust()
        }
        running = false; deadline = 0
    }
    private func emit() {
        let now = self.now()
        let remaining = max(0, 1800 - used + (running && !pro ? max(0, deadline - now) : 0))
        let value: [String: Any] = ["v": 1, "pro": pro, "remaining": remaining,
            "debitedUsed": used, "running": running, "receiverId": receiverID, "nonce": nonce,
            "error": error, "grantExpires": grantExpires]
        current = value
        onChange?(value, running ? (pro ? Double.greatestFiniteMagnitude : deadline) : 0)
    }
    @discardableResult private func saveOrExhaust() -> Bool {
        do { try persist(); return true }
        catch { used = 1800; running = false; deadline = 0; self.error = "Demo time could not be saved. Restore Pro or contact support."; return false }
    }
    private func persist() throws { try write(["version": 1, "receiverId": receiverID, "used": used], name: "demo.json") }
    private func write(_ value: [String: Any], name: String) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        let destination = directory.appendingPathComponent(name)
        try data.write(to: destination, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        let handle = try FileHandle(forWritingTo: destination); try handle.synchronize(); try handle.close()
    }
    private func acceptGrant(_ grant: [String: Any], requireNonce: Bool) throws {
        guard let payloadText = grant["payload"] as? String, let signatureText = grant["signature"] as? String,
              let data = Data(base64Encoded: payloadText), let signature = Data(base64Encoded: signatureText),
              let raw = Data(base64Encoded: publicKey), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
              key.isValidSignature(signature, for: data),
              let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              payload["v"] as? Int == 1, payload["receiverId"] as? String == receiverID,
              payload["phoneId"] as? String == phoneID,
              payload["productId"] as? String == "tapping_pro_lifetime",
              let owned = payload["pro"] as? Bool,
              let issued = payload["issuedAt"] as? Double, let expires = payload["expiresAt"] as? Double,
              issued.isFinite, expires.isFinite, issued >= grantIssued,
              issued <= self.wallNow() + 60, expires > self.wallNow(),
              expires - issued <= 7 * 86400,
              !requireNonce || payload["nonce"] as? String == nonce else { throw AccessError.invalid }
        // Debit/refund outstanding demo reservation before changing the ownership flag.
        pauseNow(); grantIssued = issued; grantExpires = expires; pro = owned
    }
    private enum AccessError: Error { case invalid }
}
