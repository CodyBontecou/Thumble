import ExpoModulesCore
import Foundation
import CryptoKit
import Security

public final class TappingLinkModule: Module {
    private var link: PinnedSocket?
    private var datagram: SecureDatagram?
    private var identity: String?
    private var host: String?
    public func definition() -> ModuleDefinition {
        Name("TappingLink")
        Events("status", "message")
        Function("connect") { (url: String, pin: String) in
            self.datagram?.close(); self.datagram = nil
            let id = UUID().uuidString
            self.identity = id; self.host = URL(string: url)?.host
            self.link?.close()
            let socket = PinnedSocket(url: url, pin: pin) { [weak self] event, value in self?.sendEvent(event, ["value": value, "id": id, "receivedAt": ProcessInfo.processInfo.systemUptime * 1000]) }
            self.link = socket; socket.open()
            return id
        }
        Function("send") { (text: String) -> Bool in self.link?.send(text) ?? false }
        Function("canSendInput") { (transport: String) -> Bool in
            transport == "udp" ? (self.datagram?.canSend ?? false) : (self.link?.canSendInput ?? false)
        }
        Function("sendTimed") { (text: String) -> Double in
            let sentAt = ProcessInfo.processInfo.systemUptime * 1000
            return self.link?.send(text) == true ? sentAt : -1
        }
        Function("configureDatagram") { (port: Int, key: String) -> Bool in
            self.datagram?.close(); self.datagram = nil
            guard let host = self.host, let id = self.identity,
                  let udp = SecureDatagram(host: host, port: port, key: key, event: { [weak self] value, receivedAt in
                      self?.sendEvent("message", ["value": value, "id": id, "receivedAt": receivedAt, "transport": "udp"])
                  }) else { return false }
            self.datagram = udp; udp.start(); return true
        }
        Function("sendDatagram") { (text: String) -> Double in
            let sentAt = ProcessInfo.processInfo.systemUptime * 1000
            return self.datagram?.send(text) == true ? sentAt : -1
        }
        Function("disconnect") { self.datagram?.close(); self.datagram = nil; self.identity = nil; self.host = nil; self.link?.close(); self.link = nil }
        OnDestroy { self.datagram?.close(); self.datagram = nil; self.identity = nil; self.host = nil; self.link?.close(); self.link = nil }
    }
}

// One URLSession per QR identity. Certificate exceptions never affect other network clients.
private final class PinnedSocket: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let url: String
    private let pin: String
    private let event: (String, String) -> Void
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private let lock = NSLock()
    private var pending = 0
    private var closed = false
    var canSendInput: Bool { lock.lock(); defer { lock.unlock() }; return !closed && pending < 6 && task != nil }
    init(url: String, pin: String, event: @escaping (String, String) -> Void) { self.url = url; self.pin = pin; self.event = event }
    private func notify(_ name: String, _ value: String) {
        lock.lock(); let active = !closed; lock.unlock()
        if active { event(name, value) }
    }
    func open() {
        guard let url = URL(string: url), url.scheme == "wss", pin.count == 64 else { notify("status", "Invalid pairing link"); return }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5; config.timeoutIntervalForResource = 86_400
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.webSocketTask(with: url); task.maximumMessageSize = 65536; self.task = task; task.resume()
    }
    func close() {
        lock.lock(); closed = true; lock.unlock()
        task?.cancel(with: .goingAway, reason: nil); session?.invalidateAndCancel(); task = nil; session = nil
    }
    func send(_ text: String) -> Bool {
        lock.lock()
        guard !closed, pending < 8, text.utf8.count <= 4096, let task else { lock.unlock(); notify("status", "Connection stalled"); close(); return false }
        pending += 1; lock.unlock()
        task.send(.string(text)) { [weak self] error in
            guard let self else { return }
            self.lock.lock(); self.pending -= 1; let closed = self.closed; self.lock.unlock()
            if let error, !closed { self.notify("status", error.localizedDescription); self.close() }
        }
        return true
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let certificate = certificates.first else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        let hash = SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
        guard hash == pin else { notify("status", "Mac certificate does not match the QR code"); completionHandler(.cancelAuthenticationChallenge, nil); return }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) { notify("status", "open"); receive(webSocketTask) }
    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            self.lock.lock(); let closed = self.closed; self.lock.unlock(); guard !closed else { return }
            switch result {
            case .success(.string(let text)): self.notify("message", text); self.receive(task)
            case .success: self.notify("status", "Unexpected receiver message"); self.close()
            case .failure(let error): self.notify("status", error.localizedDescription); self.close()
            }
        }
    }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) { notify("status", "Mac disconnected"); close() }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { if let error { notify("status", error.localizedDescription); close() } }
}
