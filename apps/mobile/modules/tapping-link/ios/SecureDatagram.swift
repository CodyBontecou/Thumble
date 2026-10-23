import Foundation
import Network

final class SecureDatagram: @unchecked Sendable {
    private let connection: NWConnection
    private let cipher: DatagramCipher
    private let queue = DispatchQueue(label: "tapping.udp.input", qos: .userInteractive)
    private let lock = NSLock()
    private var stopped = false
    private var ready = false
    private var pending = 0
    private var confirmed = false
    var canSend: Bool { lock.lock(); defer { lock.unlock() }; return !stopped && ready && pending < 6 }
    private let event: (String, Double) -> Void
    init?(host: String, port: Int, key: String, event: @escaping (String, Double) -> Void) {
        guard (1...65535).contains(port), let key = Data(base64Encoded: key), let cipher = DatagramCipher(key: key, server: false), let udpPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return nil }
        self.cipher = cipher; self.event = event
        connection = NWConnection(host: NWEndpoint.Host(host), port: udpPort, using: .udp)
    }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state {
                self.lock.lock(); self.ready = true; self.lock.unlock()
                self.probe(0)
                self.receive()
            }
        }
        connection.start(queue: queue)
    }
    private func probe(_ attempt: Int) {
        lock.lock(); let retry = !stopped && !confirmed && attempt < 8; lock.unlock()
        guard retry else { return }
        _ = send("{\"type\":\"probe\"}")
        queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.probe(attempt + 1) }
    }
    func send(_ text: String) -> Bool {
        lock.lock()
        guard !stopped, ready, pending < 8, let packet = try? cipher.seal(Data(text.utf8)) else { lock.unlock(); return false }
        pending += 1
        connection.send(content: packet, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }; self.lock.lock(); self.pending -= 1; self.lock.unlock()
        })
        lock.unlock()
        return true
    }
    private func receive() {
        connection.receiveMessage { [weak self] packet, _, _, error in
            let receivedAt = ProcessInfo.processInfo.systemUptime * 1000
            guard let self else { return }
            self.lock.lock()
            if self.stopped { self.lock.unlock(); return }
            let clear = packet.flatMap { try? self.cipher.open($0) }
            if clear != nil { self.confirmed = true }
            self.lock.unlock()
            if let clear, let text = String(data: clear, encoding: .utf8) { self.event(text, receivedAt) }
            if error == nil { self.receive() }
        }
    }
    func close() { lock.lock(); stopped = true; ready = false; lock.unlock(); connection.cancel() }
}
