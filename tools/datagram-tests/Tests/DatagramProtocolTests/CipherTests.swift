import Foundation
import Testing
@testable import DatagramProtocol

@Test func authenticatedRoundTripAndDirectionSeparation() throws {
    let key = Data(0..<32), client = DatagramCipher(key: key, server: false)!, server = DatagramCipher(key: key, server: true)!
    let clear = Data("test".utf8), packet = try client.seal(clear)
    #expect(try server.open(packet) == clear)
    #expect(throws: (any Error).self) { try server.open(packet) }
    #expect(throws: (any Error).self) { try client.open(packet) }
    #expect(try client.open(server.seal(clear)) == clear)
}
@Test func forgedCounterDoesNotAdvanceReplayWindow() throws {
    let key = Data(0..<32), client = DatagramCipher(key: key, server: false)!, server = DatagramCipher(key: key, server: true)!
    let first = try client.seal(Data("first".utf8)); var forged = first; forged[11] = 100
    #expect(throws: (any Error).self) { try server.open(forged) }
    #expect(try server.open(first) == Data("first".utf8))
    var tampered = try client.seal(Data("second".utf8)); tampered[tampered.count - 1] ^= 1
    #expect(throws: (any Error).self) { try server.open(tampered) }
    #expect(try server.open(client.seal(Data("third".utf8))) == Data("third".utf8))
}
@Test func reorderedOldPacketsAndPriorSessionKeysAreRejected() throws {
    let key = Data(0..<32), client = DatagramCipher(key: key, server: false)!, server = DatagramCipher(key: key, server: true)!
    let first = try client.seal(Data([1])), second = try client.seal(Data([2]))
    #expect(try server.open(second) == Data([2]))
    #expect(throws: (any Error).self) { try server.open(first) }
    let wrongSession = DatagramCipher(key: Data(repeating: 9, count: 32), server: true)!
    #expect(throws: (any Error).self) { try wrongSession.open(second) }
}
@Test(arguments: [0, 12, 27, 1129, 65535]) func invalidSizesAreRejected(size: Int) {
    let server = DatagramCipher(key: Data(repeating: 0, count: 32), server: true)!
    #expect(throws: (any Error).self) { try server.open(Data(repeating: 0, count: size)) }
}
@Test func interoperableKnownFixture() throws {
    let cipher = DatagramCipher(key: Data(0..<32), server: false)!
    let packet = try cipher.seal(Data("test".utf8))
    // AES-256-GCM, direction=1, counter=1, AAD=tapping-udp-v1.
    let hex = packet.map { String(format: "%02x", $0) }.joined()
    #expect(hex == "000000010000000000000001df72b7ba610ef8fc5cb4b111ebee8e57fd7110ea")
    #expect(packet.count == 32)
}
