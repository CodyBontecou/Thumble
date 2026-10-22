import Darwin
import Foundation
import Testing

@testable import MobileInputCore

@Test @MainActor private func nativeUdpSocketDeliversExactPacketAndClosesTerminally() async throws {
  let socket = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
  #expect(socket >= 0)
  defer { Darwin.close(socket) }
  var address = sockaddr_in()
  address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
  address.sin_family = sa_family_t(AF_INET)
  address.sin_addr.s_addr = inet_addr("127.0.0.1")
  let bound = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
  }
  #expect(bound == 0)
  var length = socklen_t(MemoryLayout<sockaddr_in>.size)
  let named = withUnsafeMutablePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) }
  }
  #expect(named == 0)
  var timeout = timeval(tv_sec: 2, tv_usec: 0)
  #expect(
    setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
      == 0)
  let client = try NativeDatagramClient(
    host: "127.0.0.1", port: UInt16(bigEndian: address.sin_port))
  defer { client.close() }
  try await client.connect()
  let receiving = Task.detached {
    var buffer = [UInt8](repeating: 0, count: 109)
    let count = Darwin.recv(socket, &buffer, buffer.count, 0)
    return count >= 0 ? Data(buffer.prefix(count)) : Data()
  }
  let packet = Data((0..<108).map(UInt8.init))
  #expect(client.offer(packet))
  #expect(await receiving.value == packet)
  #expect(!client.offer(Data(repeating: 0, count: 109)))
  client.close()
  #expect(!client.offer(packet))
  await #expect(throws: PhoneControlError.self) { try await client.connect() }
}
