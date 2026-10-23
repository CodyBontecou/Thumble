import Foundation
import Testing
import ThumbleContracts

@testable import MobileInputCore

private struct PacketFixture: Decodable {
  struct Vector: Decodable {
    let state: GamepadStateV1
    let sequence: String
    let payloadHex: String
    let packetHex: String
    let reportHex: String
  }
  struct Invalid: Decodable {
    let name: String
    let packetHex: String
  }
  let keyHex: String
  let sessionHex: String
  let noncePrefixHex: String
  let generation: String
  let packetBytes: Int
  let packetLimit: UInt64
  let vectors: [Vector]
  let invalidAuthenticated: [Invalid]
  let maximumSequencePacketHex: String
  let overLimitPacketHex: String
}
private func bytes(_ hex: String) throws -> Data {
  guard hex.count % 2 == 0 else { throw InputPacketError.rejected }
  let chars = Array(hex)
  var result = [UInt8]()
  for i in stride(from: 0, to: chars.count, by: 2) {
    guard let byte = UInt8(String(chars[i...i + 1]), radix: 16) else {
      throw InputPacketError.rejected
    }
    result.append(byte)
  }
  return Data(result)
}
private func packetFixture() throws -> PacketFixture {
  let url = try #require(
    Bundle.module.url(
      forResource: "input-packet-v1", withExtension: "json", subdirectory: "Fixtures"))
  return try JSONDecoder().decode(PacketFixture.self, from: Data(contentsOf: url))
}
private func grant(_ f: PacketFixture, key: Data? = nil) throws -> InputPacketGrant {
  try InputPacketGrant(
    key: key ?? bytes(f.keyHex), session: bytes(f.sessionHex), noncePrefix: bytes(f.noncePrefixHex),
    generation: #require(UInt64(f.generation)))
}
@Test @MainActor private func sharedEncryptedPacketsMatchAndDecodeBeforeHardwareQuantization()
  throws
{
  let f = try packetFixture()
  #expect(f.vectors.count == 33 && f.packetBytes == 108 && f.packetLimit == 1 << 20)
  let sender = try InputPacketSender(grant: grant(f))
  let receiver = InputPacketReceiver(grant: try grant(f))
  for v in f.vectors {
    #expect(try InputPacketState.encode(v.state) == bytes(v.payloadHex))
    #expect(try sender.seal(v.state) == bytes(v.packetHex))
    let state = try receiver.open(bytes(v.packetHex))
    #expect(try InputPacketState.encode(state) == bytes(v.payloadHex))
    #expect(GamepadReport.encode(state).map { String(format: "%02x", $0) }.joined() == v.reportHex)
  }
}
@Test @MainActor private func packetTamperingAndMalformedPayloadsNeverBurnTheReplayCounter() throws
{
  let f = try packetFixture()
  let original = try bytes(f.vectors[0].packetHex)
  let receiver = InputPacketReceiver(grant: try grant(f))
  for i in original.indices {
    var mutated = original
    mutated[i] ^= 1
    #expect(throws: InputPacketError.self) { try receiver.open(mutated) }
  }
  for v in f.invalidAuthenticated {
    #expect(throws: InputPacketError.self) { try receiver.open(bytes(v.packetHex)) }
  }
  #expect(throws: InputPacketError.self) { try receiver.open(original + Data([0])) }
  #expect(throws: InputPacketError.self) { try receiver.open(original.dropLast()) }
  #expect(throws: InputPacketError.self) { try receiver.open(bytes(f.overLimitPacketHex)) }
  #expect(try receiver.open(original).isValid)
}
@Test @MainActor private func packetReplayReorderingWrongKeysAndTerminalClose() throws {
  let f = try packetFixture()
  let receiver = InputPacketReceiver(grant: try grant(f))
  _ = try receiver.open(bytes(f.vectors[2].packetHex))
  for index in [0, 1, 2] {
    #expect(throws: InputPacketError.self) { try receiver.open(bytes(f.vectors[index].packetHex)) }
  }
  _ = try receiver.open(bytes(f.vectors[3].packetHex))
  _ = try receiver.open(bytes(f.maximumSequencePacketHex))
  #expect(throws: InputPacketError.self) { try receiver.open(bytes(f.vectors.last!.packetHex)) }
  receiver.close()
  receiver.close()
  #expect(throws: InputPacketError.self) { try receiver.open(bytes(f.maximumSequencePacketHex)) }
  let wrong = InputPacketReceiver(grant: try grant(f, key: Data(repeating: 255, count: 32)))
  #expect(throws: InputPacketError.self) { try wrong.open(bytes(f.vectors[0].packetHex)) }
}
@Test @MainActor private func packetSenderBudgetValidationAndOwnership() throws {
  let f = try packetFixture()
  let sender = try InputPacketSender(grant: grant(f), packetLimit: 2)
  _ = try sender.seal(.neutral)
  _ = try sender.seal(.neutral)
  #expect(throws: InputPacketError.self) { try sender.seal(.neutral) }
  #expect(throws: InputPacketError.self) { try sender.seal(.neutral) }
  let closed = try InputPacketSender(grant: grant(f))
  closed.close()
  #expect(throws: InputPacketError.self) { try closed.seal(.neutral) }
  for limit: UInt64 in [0, (1 << 20) + 1] {
    #expect(throws: InputPacketError.self) {
      try InputPacketSender(grant: grant(f), packetLimit: limit)
    }
  }
  #expect(throws: InputPacketError.self) {
    try InputPacketGrant(
      key: Data(count: 31), session: bytes(f.sessionHex), noncePrefix: bytes(f.noncePrefixHex),
      generation: 1)
  }
  #expect(throws: InputPacketError.self) {
    try InputPacketGrant(
      key: bytes(f.keyHex), session: Data(count: 16), noncePrefix: bytes(f.noncePrefixHex),
      generation: 1)
  }
  #expect(throws: InputPacketError.self) {
    try InputPacketGrant(
      key: bytes(f.keyHex), session: bytes(f.sessionHex), noncePrefix: Data(count: 3), generation: 1
    )
  }
  #expect(throws: InputPacketError.self) {
    try InputPacketGrant(
      key: bytes(f.keyHex), session: bytes(f.sessionHex), noncePrefix: bytes(f.noncePrefixHex),
      generation: 0)
  }
  #expect(MemoryLayout<InputPacketGrant>.size <= 64)
}

@Test @MainActor private func nativeTouchEngineUsesEncryptedChannelAndFailsNeutralOnTransportLoss()
  throws
{
  let f = try packetFixture()
  var packets: [Data] = []
  var accepting = true
  let channel = try InputPacketChannel(
    grant: grant(f),
    send: { packet in
      if accepting { packets.append(packet) }
      return accepting
    })
  let engine = InputEngine(output: channel.submit)
  let map = ControlMap(
    generation: f.generation, revision: "1",
    controls: [ControlRegion(id: "south", action: "south", x: 0.1, y: 0.1, width: 0.3, height: 0.3)]
  )
  try engine.activate(map)
  try engine.connect(generation: f.generation)
  #expect(engine.begin(id: 1, generation: f.generation, x: 0.2, y: 0.2))
  let receiver = InputPacketReceiver(grant: try grant(f))
  #expect(try receiver.open(packets[0]).buttons.isEmpty)
  #expect(try receiver.open(packets[1]).buttons == [.south])
  accepting = false
  engine.tick()
  #expect(
    !engine.connected && engine.state.buttons.isEmpty && engine.lastRelease == .transportFailure)
  let count = packets.count
  accepting = true
  engine.tick()
  #expect(packets.count == count)
  #expect(!channel.submit(InputSample(generation: f.generation, sequence: "3", state: .neutral)))
  #expect(throws: InputError.freshGenerationRequired) {
    try engine.connect(generation: f.generation)
  }
}
@Test @MainActor private func channelGenerationSequenceAndReentrancyBarriersAreTerminal() throws {
  let f = try packetFixture()
  var sends = 0
  let wrong = try InputPacketChannel(
    grant: grant(f),
    send: { _ in
      sends += 1
      return true
    })
  #expect(!wrong.submit(InputSample(generation: "1", sequence: "0", state: .neutral)))
  #expect(!wrong.submit(InputSample(generation: f.generation, sequence: "0", state: .neutral)))
  let gap = try InputPacketChannel(
    grant: grant(f),
    send: { _ in
      sends += 1
      return true
    })
  #expect(!gap.submit(InputSample(generation: f.generation, sequence: "1", state: .neutral)))
  #expect(sends == 0)
  var reentrant: InputPacketChannel?
  reentrant = try InputPacketChannel(
    grant: grant(f),
    send: { _ in
      #expect(
        reentrant?.submit(InputSample(generation: f.generation, sequence: "1", state: .neutral))
          == false)
      return true
    })
  #expect(
    reentrant?.submit(InputSample(generation: f.generation, sequence: "0", state: .neutral))
      == false)
}

@Test @MainActor private func freshKeysContinueHeldTouchesWithoutResettingEngineSequence() throws {
  let f = try packetFixture()
  var packets: [Data] = []
  var channel = try InputPacketChannel(grant: grant(f)) {
    packets.append($0)
    return true
  }
  let engine = InputEngine(output: { channel.submit($0) })
  let map = ControlMap(
    generation: f.generation, revision: "1",
    controls: [
      ControlRegion(id: "south", action: "south", x: 0.1, y: 0.1, width: 0.3, height: 0.3)
    ])
  try engine.activate(map)
  try engine.connect(generation: f.generation)
  #expect(engine.begin(id: 1, generation: f.generation, x: 0.2, y: 0.2))
  let priorRelease = engine.lastRelease
  for byte: UInt8 in [31, 32] {
    let next = try InputPacketGrant(
      key: Data(repeating: byte, count: 32),
      session: Data(repeating: byte, count: 16), noncePrefix: Data(repeating: byte, count: 4),
      generation: #require(UInt64(f.generation)))
    let old = channel
    channel = try old.continued(grant: next) {
      packets.append($0)
      return true
    }
    #expect(!old.submit(InputSample(generation: f.generation, sequence: "2", state: .neutral)))
    let before = packets.count
    engine.tick()
    #expect(
      engine.connected && engine.state.buttons == [.south] && engine.lastRelease == priorRelease)
    #expect(packets.count == before + 1)
    #expect(packets.last!.dropFirst(32).prefix(8).allSatisfy { $0 == 0 })
    #expect(try InputPacketReceiver(grant: next).open(packets.last!).buttons == [.south])
  }
  engine.end(id: 1, generation: f.generation)
  #expect(engine.connected && engine.state.buttons.isEmpty)
  #expect(packets.last!.dropFirst(32).first == 1)
}

@Test @MainActor private func continuationCannotReuseMaterialReviveClosedChannelsOrHideSendFailure()
  throws
{
  let f = try packetFixture()
  let reusedKey = try InputPacketGrant(
    key: bytes(f.keyHex), session: Data(repeating: 91, count: 16),
    noncePrefix: Data(repeating: 91, count: 4), generation: #require(UInt64(f.generation)))
  for next in [try grant(f), try grant(f, key: Data(repeating: 57, count: 32)), reusedKey] {
    let channel = try InputPacketChannel(grant: grant(f)) { _ in true }
    #expect(channel.submit(InputSample(generation: f.generation, sequence: "0", state: .neutral)))
    #expect(throws: InputPacketError.self) { try channel.continued(grant: next) { _ in true } }
    #expect(!channel.submit(InputSample(generation: f.generation, sequence: "1", state: .neutral)))
  }
  let fresh = try InputPacketGrant(
    key: Data(repeating: 73, count: 32),
    session: Data(repeating: 73, count: 16), noncePrefix: Data(repeating: 73, count: 4),
    generation: #require(UInt64(f.generation)))
  let closed = try InputPacketChannel(grant: grant(f)) { _ in true }
  closed.close()
  #expect(throws: InputPacketError.self) { try closed.continued(grant: fresh) { _ in true } }
  var channel = try InputPacketChannel(grant: grant(f)) { _ in true }
  let engine = InputEngine(output: { channel.submit($0) })
  try engine.activate(
    ControlMap(
      generation: f.generation, revision: "1",
      controls: [
        ControlRegion(id: "south", action: "south", x: 0.1, y: 0.1, width: 0.3, height: 0.3)
      ]))
  try engine.connect(generation: f.generation)
  channel = try channel.continued(grant: fresh) { _ in false }
  engine.tick()
  #expect(!engine.connected && engine.lastRelease == .transportFailure)
  #expect(throws: InputPacketError.self) { try channel.continued(grant: grant(f)) { _ in true } }
}
