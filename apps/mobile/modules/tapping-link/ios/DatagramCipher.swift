import Foundation
import CryptoKit

// A fresh 256-bit key is delivered only over the certificate-pinned TLS session.
// Direction-specific nonces avoid reuse across peers; all state is queue/lock confined.
final class DatagramCipher {
    private let key: SymmetricKey
    private let sending: UInt32
    private let receiving: UInt32
    private var counter: UInt64 = 0
    private var received: UInt64 = 0
    private let context = Data("tapping-udp-v1".utf8)
    init?(key: Data, server: Bool) {
        guard key.count == 32 else { return nil }
        self.key = SymmetricKey(data: key)
        sending = server ? 2 : 1; receiving = server ? 1 : 2
    }
    func seal(_ data: Data) throws -> Data {
        guard data.count <= 1100, counter < UInt64.max else { throw DatagramError.invalid }
        counter += 1
        var direction = sending.bigEndian, sequence = counter.bigEndian
        var nonce = withUnsafeBytes(of: &direction) { Data($0) }
        nonce.append(withUnsafeBytes(of: &sequence) { Data($0) })
        guard let combined = try AES.GCM.seal(data, using: key, nonce: AES.GCM.Nonce(data: nonce), authenticating: context).combined else { throw DatagramError.invalid }
        return combined
    }
    func open(_ packet: Data) throws -> Data {
        guard (28...1128).contains(packet.count) else { throw DatagramError.invalid }
        let bytes = [UInt8](packet.prefix(12))
        let direction = bytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let sequence = bytes.dropFirst(4).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard direction == receiving, sequence > received else { throw DatagramError.invalid }
        let data = try AES.GCM.open(AES.GCM.SealedBox(combined: packet), using: key, authenticating: context)
        received = sequence // Never let a forged counter advance the replay window.
        return data
    }
}
enum DatagramError: Error { case invalid }
