import CryptoKit
import Foundation
import ThumbleContracts

public enum InputPacketError: Error { case rejected }
public struct InputPacketGrant: Sendable {
  fileprivate let key: SymmetricKey
  fileprivate let session: [UInt8]
  fileprivate let prefix: [UInt8]
  fileprivate let generation: UInt64
  public init(key: Data, session: Data, noncePrefix: Data, generation: UInt64) throws {
    guard key.count == 32, session.count == 16, session.contains(where: { $0 != 0 }),
      noncePrefix.count == 4, generation > 0
    else { throw InputPacketError.rejected }
    self.key = SymmetricKey(data: key)
    self.session = Array(session)
    self.prefix = Array(noncePrefix)
    self.generation = generation
  }
  fileprivate func header(_ sequence: UInt64) -> [UInt8] {
    Array("THI1".utf8) + [0, 0, 0, 0] + session + little(generation) + little(sequence)
  }
  fileprivate func nonce(_ sequence: UInt64) throws -> AES.GCM.Nonce {
    try AES.GCM.Nonce(data: prefix + little(sequence))
  }
}
private func little(_ value: UInt64) -> [UInt8] {
  (0..<8).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
}
private func integer(_ bytes: [UInt8], _ offset: Int, _ count: Int = 8) -> UInt64 {
  (0..<count).reduce(UInt64(0)) { $0 | (UInt64(bytes[offset + $1]) << ($1 * 8)) }
}
public enum InputPacketState {
  public static func encode(_ state: GamepadStateV1) throws -> Data {
    guard state.isValid, GamepadButtonV1.allCases.count == 17 else {
      throw InputPacketError.rejected
    }
    var mask: UInt64 = 0
    for (i, button) in GamepadButtonV1.allCases.enumerated() where state.buttons.contains(button) {
      mask |= UInt64(1) << i
    }
    var bytes = Array(little(mask).prefix(4))
    for value in [
      state.leftStickX, state.leftStickY, state.rightStickX, state.rightStickY, state.leftTrigger,
      state.rightTrigger,
    ] {
      bytes += little(value.bitPattern)
    }
    return Data(bytes)
  }
  public static func decode(_ data: Data) throws -> GamepadStateV1 {
    guard data.count == 52, GamepadButtonV1.allCases.count == 17 else {
      throw InputPacketError.rejected
    }
    let bytes = Array(data)
    let mask = integer(bytes, 0, 4)
    guard mask >> 17 == 0 else { throw InputPacketError.rejected }
    let values = (0..<6).map { Double(bitPattern: integer(bytes, 4 + $0 * 8)) }
    let state = GamepadStateV1(
      buttons: GamepadButtonV1.allCases.enumerated().filter { mask & (UInt64(1) << $0.offset) != 0 }
        .map(\.element), leftStickX: values[0], leftStickY: values[1], rightStickX: values[2],
      rightStickY: values[3], leftTrigger: values[4], rightTrigger: values[5])
    guard state.isValid else { throw InputPacketError.rejected }
    return state
  }
}
/// Exactly one sender owns a grant's nonce counter. React never supplies sequences or keys.
@MainActor public final class InputPacketSender {
  public static let packetLimit: UInt64 = 1 << 20
  private var grant: InputPacketGrant?
  private var next: UInt64 = 0
  private let limit: UInt64
  public init(grant: InputPacketGrant, packetLimit: UInt64 = InputPacketSender.packetLimit) throws {
    guard packetLimit > 0, packetLimit <= Self.packetLimit else { throw InputPacketError.rejected }
    self.grant = grant
    limit = packetLimit
  }
  public func close() { grant = nil }
  fileprivate func acceptsContinuation(_ successor: InputPacketGrant) -> Bool {
    guard let grant else { return false }
    return grant.generation == successor.generation && grant.session != successor.session
      && grant.key != successor.key
  }
  public func seal(_ state: GamepadStateV1) throws -> Data {
    let plain = try InputPacketState.encode(state)
    guard let grant, next < limit else {
      close()
      throw InputPacketError.rejected
    }
    let sequence = next
    next += 1
    do {
      let header = grant.header(sequence)
      let box = try AES.GCM.seal(
        plain, using: grant.key, nonce: grant.nonce(sequence), authenticating: header)
      return Data(header) + box.ciphertext + box.tag
    } catch {
      close()
      throw InputPacketError.rejected
    }
  }
}
@MainActor public final class InputPacketReceiver {
  private var grant: InputPacketGrant?
  private var newest: UInt64?
  public init(grant: InputPacketGrant) { self.grant = grant }
  public func close() { grant = nil }
  public func open(_ data: Data) throws -> GamepadStateV1 {
    guard data.count == 108, let grant else { throw InputPacketError.rejected }
    let packet = Array(data)
    let sequence = integer(packet, 32)
    guard sequence < InputPacketSender.packetLimit, newest.map({ sequence > $0 }) ?? true,
      Array(packet.prefix(40)) == grant.header(sequence)
    else { throw InputPacketError.rejected }
    do {
      let box = try AES.GCM.SealedBox(
        nonce: grant.nonce(sequence), ciphertext: packet[40..<92], tag: packet[92..<108])
      let plain = try AES.GCM.open(box, using: grant.key, authenticating: packet.prefix(40))
      let state = try InputPacketState.decode(plain)
      newest = sequence
      return state
    } catch { throw InputPacketError.rejected }
  }
}

/// Bounded native output adapter: no queue, no React callbacks, one sealed packet per sample.
@MainActor public final class InputPacketChannel {
  private let sender: InputPacketSender
  private let generation: String
  private let send: (Data) -> Bool
  private var next: UInt64 = 0
  private var available = true
  private var publishing = false
  public init(
    grant: InputPacketGrant, packetLimit: UInt64 = InputPacketSender.packetLimit,
    send: @escaping (Data) -> Bool
  ) throws {
    sender = try InputPacketSender(grant: grant, packetLimit: packetLimit)
    generation = String(grant.generation)
    self.send = send
  }
  public func close() {
    available = false
    sender.close()
  }
  /// Continue only a live channel with fresh native material; engine sequence never resets.
  func continued(grant: InputPacketGrant, send: @escaping (Data) -> Bool) throws
    -> InputPacketChannel
  {
    guard available, !publishing, next > 0, sender.acceptsContinuation(grant) else {
      close()
      throw InputPacketError.rejected
    }
    defer { close() }
    let successor = try InputPacketChannel(grant: grant, packetLimit: 65_536, send: send)
    successor.next = next
    return successor
  }
  public func submit(_ sample: InputSample) -> Bool {
    guard available, !publishing, next < UInt64.max,
      sample.generation == generation, sample.sequence == String(next)
    else {
      close()
      return false
    }
    publishing = true
    defer { publishing = false }
    do {
      let packet = try sender.seal(sample.state)
      next += 1
      guard send(packet), available else {
        close()
        return false
      }
      return true
    } catch {
      close()
      return false
    }
  }
}
