import Foundation
import CryptoKit

// Controller output requires a signed plan grant. All disk and signature work happens
// on this utility queue, never on HID's queue.
final class AccessSession {
    private let queue = DispatchQueue(label: "tapping.receiver.access", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let directory: URL
    private let publicKey: String
    private let wallNow: () -> Double
    private var current: [String: Any] = [:]
    private var running = false
    private var pro = false
    // This branch is compiled only into the separately named local QA receiver.
    // Grant verification and the receiver record remain unchanged.
    private var unlimited: Bool {
#if THUMBLE_LOCAL_TESTING
        return true
#else
        return pro
#endif
    }
    private var grantExpires = 0.0
    private var grantIssued = 0.0
    private var nonce = UUID().uuidString
    private(set) var receiverID = UUID().uuidString
    private var phoneID = ""
    private var cachedGrant: [String: Any]?
    private var error = ""
    /// Called with the access snapshot and whether output may run.
    var onChange: (([String: Any], Bool) -> Void)?
    init(directory: URL, publicKey: String, wallNow: @escaping () -> Double = { Date().timeIntervalSince1970 }) {
        self.directory = directory; self.publicKey = publicKey; self.wallNow = wallNow
        // demo.json is the receiver record. It once also metered the retired free demo;
        // it stays because plan grants are bound to its receiverId, which must never
        // rotate for existing installs. New records keep a spent `used` value so the
        // file stays readable by older receivers; this receiver ignores it.
        let url = directory.appendingPathComponent("demo.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if FileManager.default.fileExists(atPath: url.path) {
                let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
                guard let id = object?["receiverId"] as? String, UUID(uuidString: id) != nil else { throw AccessError.invalid }
                receiverID = id
            } else {
                do { try write(["version": 1, "receiverId": receiverID, "used": 1800], name: "demo.json") }
                catch { self.error = "Receiver record could not be saved. Restore your plan in Thumble on your phone, or contact support."; return }
            }
            if let data = try? Data(contentsOf: directory.appendingPathComponent("pro-grant.json")),
               let grant = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                cachedGrant = grant
            }
        } catch {
            // Never replace an unreadable record: that would rotate the receiver ID.
            self.error = "Receiver record could not be loaded. Restore your plan in Thumble on your phone, or contact support."
        }
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
    func stop() { queue.sync { running = false; timer?.cancel(); timer = nil } }
    func pair(phoneID: String) {
        queue.async {
            self.running = false; self.nonce = UUID().uuidString
            self.phoneID = phoneID; self.pro = false
            if let grant = self.cachedGrant { try? self.acceptGrant(grant, requireNonce: false) }
            self.emit()
        }
    }
    func start() {
        queue.async {
            if self.unlimited { self.running = true }
            self.emit()
        }
    }
    func pause() { queue.async { self.running = false; self.emit() } }
    func submitGrant(_ grant: [String: Any]) {
        queue.async {
            do {
                try self.acceptGrant(grant, requireNonce: true)
                try self.write(grant, name: "pro-grant.json"); self.cachedGrant = grant
                self.error = ""
            } catch { self.error = "Your plan could not be verified on this Mac. Tap Restore in Thumble on your phone." }
            self.emit()
        }
    }
    private func tick() {
        if pro && wallNow() >= grantExpires { pro = false; running = false }
        emit()
    }
    private func emit() {
        // remaining and debitedUsed stay on the wire for older phone builds; there is no free time.
        let value: [String: Any] = ["v": 1, "pro": unlimited, "remaining": 0.0,
            "debitedUsed": 1800.0, "running": running, "receiverId": receiverID, "nonce": nonce,
            "error": error, "grantExpires": grantExpires]
        current = value
        onChange?(value, running)
    }
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
              payload["productId"] as? String == "thumble_pro_lifetime",
              let owned = payload["pro"] as? Bool,
              let issued = payload["issuedAt"] as? Double, let expires = payload["expiresAt"] as? Double,
              issued.isFinite, expires.isFinite, issued >= grantIssued,
              issued <= self.wallNow() + 60, expires > self.wallNow(),
              expires - issued <= 7 * 86400,
              !requireNonce || payload["nonce"] as? String == nonce else { throw AccessError.invalid }
        // Ownership changes always require an explicit Resume from neutral input.
        running = false; grantIssued = issued; grantExpires = expires; pro = owned
    }
    private enum AccessError: Error { case invalid }
}
