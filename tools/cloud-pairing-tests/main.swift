import AppKit
import Network

// Intercept every request: these tests never contact the hosted service.
final class PairingHTTP: URLProtocol {
    struct Upload { let body: [String: Any]; var cancelled = false; var completed = false }
    static let lock = NSLock()
    static var uploads: [Upload] = []
    static var deletions = 0
    static var registrations = 0
    static func snapshot() -> ([Upload], Int, Int) {
        lock.lock(); defer { lock.unlock() }; return (uploads, deletions, registrations)
    }
    private var work: DispatchWorkItem?
    private var uploadIndex: Int?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let method = request.httpMethod!, path = request.url!.path
        var response: [String: Any] = [:]
        var delay = 0.0
        Self.lock.lock()
        switch (method, path) {
        case ("GET", "/v1/config"):
            response = ["auth": ["issuer": "https://thumble.io/api/auth", "audience": "https://thumble.io/mcp"]]
        case ("POST", "/api/auth/oauth2/token"): response = ["access_token": "synthetic-access"]
        case ("POST", "/v1/receiver-pairing"):
            Self.registrations += 1
            response = ["receiverId": "11111111-1111-4111-8111-111111111111", "publisherToken": "rp_synthetic", "expiresAt": Date().timeIntervalSince1970 * 1000 + 300_000]
        case ("PUT", _):
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
            }
            let body = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
            uploadIndex = Self.uploads.count; Self.uploads.append(Upload(body: body))
            response = ["accepted": true]; delay = 0.25
        case ("DELETE", _): Self.deletions += 1; response = ["revoked": true]
        default: fatalError("Unexpected request: \(method) \(path)")
        }
        Self.lock.unlock()
        let data = try! JSONSerialization.data(withJSONObject: response)
        let job = DispatchWorkItem { [self] in
            Self.lock.lock()
            if let index = uploadIndex {
                if Self.uploads[index].cancelled { Self.lock.unlock(); return }
                Self.uploads[index].completed = true
            }
            Self.lock.unlock()
            client!.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client!.urlProtocol(self, didLoad: data)
            client!.urlProtocolDidFinishLoading(self)
        }
        work = job; DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: job)
    }
    override func stopLoading() {
        work?.cancel()
        Self.lock.lock(); defer { Self.lock.unlock() }
        if let index = uploadIndex, !Self.uploads[index].completed { Self.uploads[index].cancelled = true }
    }
}

@MainActor func until(_ message: String, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(5)
    while !condition(), Date() < deadline { try! await Task.sleep(for: .milliseconds(5)) }
    precondition(condition(), message)
}

let application = NSApplication.shared
Task { @MainActor in
    setenv("TAPPING_PROFILE_DIR", CommandLine.arguments[1], 1)
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [PairingHTTP.self]
    let network = URLSession(configuration: config)
    let sharing = CloudPairing(network: network, authorization: { url in
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "state" }!.value!
        var callback = URLComponents(string: PairingOAuth.redirect)!
        callback.queryItems = [URLQueryItem(name: "code", value: "synthetic"), URLQueryItem(name: "state", value: state), URLQueryItem(name: "iss", value: "https://thumble.io/api/auth")]
        return callback.url!
    }, heartbeatInterval: .milliseconds(30))
    var statuses: [String] = [], isSharing = false
    sharing.onStatus = { statuses.append($0) }; sharing.onSharing = { isSharing = $0 }
    let payload = try! JSONSerialization.data(withJSONObject: ["expires": Int(Date().timeIntervalSince1970) + 120])
    let invitation = "thumble://pair?data=" + payload.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    sharing.updateInvitation(invitation)
    sharing.start(window: NSWindow())
    await until("First QR upload never started") { PairingHTTP.snapshot().0.count == 1 }
    try! await Task.sleep(for: .milliseconds(120))
    var uploads = PairingHTTP.snapshot().0
    precondition(uploads.count == 1 && !uploads[0].cancelled, "Heartbeat cancelled an unchanged in-flight upload")
    precondition(uploads[0].body["png"] is String, "Initial upload did not contain a QR")
    await until("Slow QR upload never completed") { PairingHTTP.snapshot().0[0].completed }
    await until("Heartbeat did not resume after completion") { PairingHTTP.snapshot().0.count >= 2 }

    // Pairing is a state change and must supersede the pending QR immediately.
    sharing.updateInvitation("")
    await until("Connected state did not supersede QR") { PairingHTTP.snapshot().0.count == 3 }
    try! await Task.sleep(for: .milliseconds(100))
    uploads = PairingHTTP.snapshot().0
    precondition(uploads.count == 3 && uploads[1].cancelled && !uploads[2].cancelled, "Superseded completion cleared the newer upload")
    precondition(uploads[2].body["connected"] as? Bool == true && uploads[2].body["png"] == nil && uploads[2].body["expiresAt"] == nil)
    precondition((uploads[2].body["sequence"] as! Int) > (uploads[1].body["sequence"] as! Int))
    await until("Connected state was not published") { statuses.contains("Phone paired · ChatGPT QR cleared") }

    // Exercise the actual receiver listener-failure callback without starting HID.
    sharing.updateInvitation(invitation)
    await until("Fresh QR upload never started") { PairingHTTP.snapshot().0.last?.body["png"] is String }
    let receiver = Receiver()
    receiver.onPairingUnavailable = { Task { @MainActor in sharing.receiverUnavailable() } }
    receiver.queue.sync { receiver.handleListenerState(.failed(.posix(.ENETDOWN)), port: nil) }
    await until("Listener failure did not revoke hosted pairing") { PairingHTTP.snapshot().1 == 1 && !isSharing }
    precondition(statuses.last == "Receiver unavailable · ChatGPT pairing sharing stopped", "Failure was reported as a connected phone")
    let count = PairingHTTP.snapshot().0.count
    try! await Task.sleep(for: .milliseconds(150))
    precondition(PairingHTTP.snapshot().0.count == count, "Listener failure left heartbeat running")
    sharing.start(window: NSWindow())
    try! await Task.sleep(for: .milliseconds(80))
    precondition(PairingHTTP.snapshot().2 == 1 && !isSharing, "Sharing restarted with a stale invitation")
    network.invalidateAndCancel()
    print("Hosted pairing lifecycle regressions passed (slow heartbeats, changed state, listener failure).")
    exit(0)
}
RunLoop.main.run()
