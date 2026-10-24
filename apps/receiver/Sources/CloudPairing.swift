import AppKit
import AuthenticationServices
import CryptoKit
import Security

enum PairingOAuth {
    static let redirect = "thumble-receiver://cloud-auth/callback"
    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw Failure.invalid }
        return Data(bytes).base64URLEncoded
    }
    static func authorize(service: URL, audience: String, verifier: String, state: String) -> URL {
        var url = URLComponents(url: service.appendingPathComponent("api/auth/oauth2/authorize"), resolvingAgainstBaseURL: false)!
        url.queryItems = ["response_type": "code", "client_id": "thumble-receiver", "redirect_uri": redirect,
                          "scope": "openid pairing:manage", "resource": audience, "state": state,
                          "code_challenge_method": "S256", "code_challenge": Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded]
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        return url.url!
    }
    static func code(_ callback: URL, state: String, issuer: String) throws -> String {
        guard let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              parts.scheme == "thumble-receiver", parts.host == "cloud-auth", parts.path == "/callback",
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil else { throw Failure.invalid }
        func single(_ key: String) -> String? {
            let values = parts.queryItems?.filter { $0.name == key } ?? []
            return values.count == 1 ? values[0].value : nil
        }
        guard single("state") == state, single("iss") == issuer, single("error") == nil,
              let code = single("code"), !code.isEmpty, code.count <= 4096 else { throw Failure.invalid }
        return code
    }
    static func form(_ values: [String: String]) -> Data {
        var parts = URLComponents(); parts.queryItems = values.map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((parts.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
    }
    enum Failure: Error { case invalid }
}
private extension Data {
    var base64URLEncoded: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}

private final class PairingRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Explicit, memory-only sharing. No input packets, account refresh tokens or LAN listener.
@MainActor final class CloudPairing: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let service = URL(string: "https://thumble.io")!
    private let network: URLSession
    private let authorization: ((URL) async throws -> URL)?
    private let heartbeatInterval: Duration
    private var authentication: ASWebAuthenticationSession?
    private weak var window: NSWindow?
    private var operation: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var publication: Task<Void, Never>?
    private var publishingInvitation: String?
    private var generation = UUID()
    private var receiverId: String?
    private var publisherToken: String?
    private var expiresAt = 0.0
    private var sequence = 0
    private var invitation: String?
    var onStatus: ((String) -> Void)?
    var onSharing: ((Bool) -> Void)?

    init(network: URLSession? = nil, authorization: ((URL) async throws -> URL)? = nil, heartbeatInterval: Duration = .seconds(10)) {
        self.network = network ?? URLSession(configuration: .ephemeral, delegate: PairingRedirectPolicy(), delegateQueue: nil)
        self.authorization = authorization
        self.heartbeatInterval = heartbeatInterval
        super.init()
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { window ?? NSWindow() }
    func start(window: NSWindow) {
        guard operation == nil, publisherToken == nil else { return }
        guard invitation != nil else { onStatus?("Receiver unavailable · restart it before sharing a QR"); return }
        self.window = window
        let epoch = generation
        onSharing?(true); onStatus?("Sign in to share pairing with ChatGPT for 10 minutes…")
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let config = try await request("v1/config")
                guard generation == epoch, !Task.isCancelled else { return }
                guard let auth = config["auth"] as? [String: Any],
                      auth["issuer"] as? String == service.absoluteString + "/api/auth",
                      let audience = auth["audience"] as? String,
                      ["https://thumble.io/mcp", service.absoluteString + "/mcp"].contains(audience) else { throw PairingOAuth.Failure.invalid }
                let verifier = try PairingOAuth.random(), state = try PairingOAuth.random()
                let url = PairingOAuth.authorize(service: service, audience: audience, verifier: verifier, state: state)
                let callback = try await authenticate(url)
                guard generation == epoch, !Task.isCancelled else { return }
                let code = try PairingOAuth.code(callback, state: state, issuer: service.absoluteString + "/api/auth")
                let tokens = try await request("api/auth/oauth2/token", method: "POST", form: ["grant_type": "authorization_code", "client_id": "thumble-receiver", "redirect_uri": PairingOAuth.redirect, "code": code, "code_verifier": verifier, "resource": audience])
                guard generation == epoch, !Task.isCancelled, let access = tokens["access_token"] as? String, !access.isEmpty else { throw CancellationError() }
                let registered = try await request("v1/receiver-pairing", method: "POST", token: access, body: ["name": String((Host.current().localizedName ?? "My Mac").prefix(100))])
                guard let id = registered["receiverId"] as? String, UUID(uuidString: id) != nil,
                      let token = registered["publisherToken"] as? String, token.hasPrefix("rp_"),
                      let expiry = registered["expiresAt"] as? Double, expiry > Date().timeIntervalSince1970 * 1000,
                      expiry <= Date().timeIntervalSince1970 * 1000 + 600_000 else { throw PairingOAuth.Failure.invalid }
                guard generation == epoch, !Task.isCancelled else {
                    _ = try? await request("v1/receiver-pairing/\(id)", method: "DELETE", token: token)
                    return
                }
                receiverId = id; publisherToken = token; expiresAt = expiry; sequence = 0
                operation = nil; authentication = nil
                publish()
                heartbeat = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: self?.heartbeatInterval ?? .seconds(10)) } catch { return }
                        guard let self, self.generation == epoch else { return }
                        if Date().timeIntervalSince1970 * 1000 >= self.expiresAt { self.stop(); return }
                        self.publish()
                    }
                }
            } catch {
                guard generation == epoch else { return }
                operation = nil; authentication = nil; onSharing?(false)
                onStatus?("ChatGPT pairing could not start. Choose Pair through ChatGPT… to retry.")
            }
        }
    }
    private func authenticate(_ url: URL) async throws -> URL {
        if let authorization { return try await authorization(url) }
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "thumble-receiver") { callback, error in
                if let callback { continuation.resume(returning: callback) }
                else { continuation.resume(throwing: error ?? PairingOAuth.Failure.invalid) }
            }
            session.presentationContextProvider = self
            authentication = session
            if !session.start() { authentication = nil; continuation.resume(throwing: PairingOAuth.Failure.invalid) }
        }
    }
    func updateInvitation(_ value: String) { invitation = value; publish() }
    func receiverUnavailable() {
        invitation = nil
        stop()
        onStatus?("Receiver unavailable · ChatGPT pairing sharing stopped")
    }
    private func publish() {
        guard let id = receiverId, let token = publisherToken, let value = invitation else { return }
        guard Date().timeIntervalSince1970 * 1000 < expiresAt else { stop(); return }
        // An unchanged heartbeat must not cancel a slow but healthy upload.
        guard publication == nil || publishingInvitation != value else { return }
        sequence += 1
        let revision = sequence, epoch = generation
        // Supersede only changed state; sequence checks reject its late arrivals.
        publication?.cancel()
        publishingInvitation = value
        publication = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == epoch, sequence == revision {
                    publication = nil; publishingInvitation = nil
                }
            }
            do {
                var body: [String: Any] = ["sequence": revision, "connected": value.isEmpty]
                if !value.isEmpty {
                    guard let parts = URLComponents(string: value), let encoded = parts.queryItems?.first(where: { $0.name == "data" })?.value else { throw PairingOAuth.Failure.invalid }
                    let base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                    guard let data = Data(base64Encoded: base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4)),
                          let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let expiry = payload["expires"] as? Int else { throw PairingOAuth.Failure.invalid }
                    body["expiresAt"] = expiry * 1000
                    body["png"] = try PairingCode.png(value).base64EncodedString()
                }
                _ = try await request("v1/receiver-pairing/\(id)", method: "PUT", token: token, body: body)
                guard generation == epoch, sequence == revision, !Task.isCancelled else { return }
                onStatus?(value.isEmpty ? "Phone paired · ChatGPT QR cleared" : "QR shared · ask ChatGPT for show_pairing_code")
            } catch {
                guard generation == epoch, sequence == revision, !Task.isCancelled else { return }
                onStatus?("ChatGPT pairing is temporarily unavailable · retrying")
            }
        }
    }
    func stop() {
        let id = receiverId, token = publisherToken
        generation = UUID(); operation?.cancel(); operation = nil
        authentication?.cancel(); authentication = nil
        heartbeat?.cancel(); heartbeat = nil; publication?.cancel(); publication = nil; publishingInvitation = nil
        receiverId = nil; publisherToken = nil; expiresAt = 0
        onSharing?(false); onStatus?("ChatGPT pairing sharing stopped")
        if let id, let token { Task { _ = try? await request("v1/receiver-pairing/\(id)", method: "DELETE", token: token) } }
    }
    private func request(_ path: String, method: String = "GET", token: String? = nil, body: [String: Any]? = nil, form: [String: String]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: service.appendingPathComponent(path)); request.httpMethod = method; request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let form { request.httpBody = PairingOAuth.form(form); request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type") }
        else if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (stream, response) = try await network.bytes(for: request)
        var data = Data()
        for try await byte in stream {
            guard data.count < 262144 else { throw PairingOAuth.Failure.invalid }
            data.append(byte)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), data.count <= 262144,
              let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PairingOAuth.Failure.invalid }
        return result
    }
}
