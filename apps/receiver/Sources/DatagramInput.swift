import Foundation
import Network
import CryptoKit

// Created per authenticated WebSocket peer; all callbacks use the receiver's queue.
final class DatagramInput {
    private let queue: DispatchQueue
    private let listener: NWListener
    private let cipher: DatagramCipher
    private var clients: [ObjectIdentifier: NWConnection] = [:]
    private var stopped = false
    private var admissionWindow = 0.0
    private var admissions = 0
    var onMessage: (([String: Any], Double, NWConnection) -> Void)?
    var onReady: ((UInt16) -> Void)?
    let key: Data
    init(queue: DispatchQueue) throws {
        self.queue = queue
        key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        cipher = DatagramCipher(key: key, server: true)!
        let parameters = NWParameters.udp
        listener = try NWListener(using: parameters, on: .any)
        listener.stateUpdateHandler = { [weak self] phase in
            guard let self, !self.stopped else { return }
            if case .ready = phase, let port = self.listener.port { self.onReady?(port.rawValue) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, !self.stopped, self.clients.count < 4 else { connection.cancel(); return }
            let now = ProcessInfo.processInfo.systemUptime
            if now - self.admissionWindow >= 1 { self.admissionWindow = now; self.admissions = 0 }
            guard self.admissions < 16 else { connection.cancel(); return }
            self.admissions += 1
            let id = ObjectIdentifier(connection); self.clients[id] = connection
            connection.stateUpdateHandler = { [weak self, weak connection] phase in
                guard let self, let connection else { return }
                switch phase {
                case .ready: self.receive(connection)
                case .cancelled, .failed: self.clients.removeValue(forKey: id)
                default: break
                }
            }
            connection.start(queue: self.queue)
            // Bound unauthenticated endpoint allocations. An authenticated endpoint
            // is renewed by successful receives, not by arbitrary UDP traffic.
            self.queue.asyncAfter(deadline: .now() + 2) { [weak self, weak connection] in
                guard let self, let connection, self.clients[id] != nil else { return }
                if self.authenticated !== connection { connection.cancel(); self.clients.removeValue(forKey: id) }
            }
        }
    }
    private weak var authenticated: NWConnection?
    func start() { listener.start(queue: queue) }
    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] packet, _, _, error in
            let receivedMs = ProcessInfo.processInfo.systemUptime * 1000
            guard let self, let connection, !self.stopped else { return }
            if error != nil { connection.cancel(); self.clients.removeValue(forKey: ObjectIdentifier(connection)); return }
            if let authenticated = self.authenticated, authenticated !== connection { connection.cancel(); self.clients.removeValue(forKey: ObjectIdentifier(connection)); return }
            if let packet, let clear = try? self.cipher.open(packet),
               let object = try? JSONSerialization.jsonObject(with: clear) as? [String: Any] {
                // Only a holder of the TLS-delivered key can bind the UDP endpoint.
                if let authenticated = self.authenticated, authenticated !== connection { connection.cancel(); return }
                self.authenticated = connection
                self.onMessage?(object, receivedMs, connection)
            } else if self.authenticated !== connection {
                connection.cancel(); self.clients.removeValue(forKey: ObjectIdentifier(connection)); return
            }
            if self.clients[ObjectIdentifier(connection)] != nil { self.receive(connection) }
        }
    }
    func send(_ object: [String: Any], to connection: NWConnection) {
        guard !stopped, authenticated === connection,
              let clear = try? JSONSerialization.data(withJSONObject: object), let packet = try? cipher.seal(clear) else { return }
        connection.send(content: packet, completion: .contentProcessed { _ in })
    }
    func stop() { stopped = true; listener.cancel(); clients.values.forEach { $0.cancel() }; clients.removeAll(); authenticated = nil }
}
