import Foundation
import Testing
import ThumbleContracts

@testable import MobileInputCore

private actor RenewalStorage: ControlCredentialSource {
  func load(hostPin: String, now: UInt64) throws -> PhoneCredential? {
    try PhoneCredential(
      hostPin: hostPin, phoneID: "phone-a", epoch: 1, expiresAt: 180_000,
      token: Data(repeating: 34, count: 32))
  }
}
@MainActor private final class RenewalIO: EnrollmentFrameIO {
  private var fixture: [String: [String: Any]]
  private var replies: [[String: Any]] = []
  var inputs: [Data] = []
  var commands: [String] = []
  var wall: UInt64 = 1000
  var elapsed: Int64 = 0
  let origin = ContinuousClock.now
  var continuous: ContinuousClock.Instant { origin.advanced(by: .milliseconds(elapsed)) }
  var renewals = 0
  var currentSession = String(repeating: "33", count: 16)
  var closed = false
  var pauseRenewal = false
  var waiting = false
  var pending: CheckedContinuation<Void, Never>?
  var changeReply: ([String: Any]) -> [String: Any] = { $0 }
  var nullProgress = false
  init() throws {
    let url = try #require(
      Bundle.module.url(
        forResource: "native-input-control-v4", withExtension: "json", subdirectory: "Fixtures"))
    let raw = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    fixture = try Dictionary(
      uniqueKeysWithValues: ["hello", "authenticated", "configuration", "grant"].map {
        ($0, try #require(raw[$0] as? [String: Any]))
      })
    fixture["hello"]?["controlVersion"] = 6
    fixture["authenticated"]?["expiresAt"] = 61_000
    fixture["grant"]?["lifetimeMs"] = 60_000
    fixture["grant"]?["transport"] = "udp+tls"
    fixture["grant"]?["udpPort"] = 43210
  }
  func connect() async throws {}
  func offer(_ frame: ControlTLSFrame) -> Bool {
    guard !closed else { return false }
    if frame.kind == .input {
      inputs.append(frame.payload)
      return true
    }
    guard let value = try? EnrollmentJSON.parse(frame.payload),
      case .string(let command)? = value["command"]
    else { return false }
    commands.append(command)
    switch command {
    case "hello": replies.append(fixture["hello"]!)
    case "authenticate": replies.append(fixture["authenticated"]!)
    case "input-configuration": replies.append(fixture["configuration"]!)
    case "input-grant": replies.append(fixture["grant"]!)
    case "input-renew":
      guard value["sessionId"] == .string(currentSession) else { return false }
      renewals += 1
      var grant = fixture["grant"]!
      grant["command"] = "input-renewed"
      grant["replacesSessionId"] = currentSession
      currentSession = String(repeating: String(format: "%02x", 0x60 + renewals), count: 16)
      grant["sessionId"] = currentSession
      grant["key"] = String(repeating: String(format: "%02x", 0x70 + renewals), count: 32)
      grant["noncePrefix"] = String(repeating: String(format: "%02x", 0x80 + renewals), count: 4)
      grant["authorizationExpiresAt"] = wall + 60_000
      replies.append(changeReply(grant))
    case "input-status":
      guard case .string(let session)? = value["sessionId"], session == currentSession,
        let last = inputs.last
      else { return false }
      let sequence = last.dropFirst(32).prefix(8).enumerated().reduce(UInt64(0)) {
        $0 | UInt64($1.element) << ($1.offset * 8)
      }
      replies.append([
        "version": 1, "command": "input-status", "connectionId": String(repeating: "ab", count: 16),
        "sessionId": session, "active": true, "generation": "1", "revision": "1",
        "lastAcceptedSequence": nullProgress ? NSNull() : String(sequence), "inputEnabled": false,
      ])
    default: return false
    }
    return true
  }
  func receive() async throws -> ControlTLSFrame {
    if pauseRenewal && commands.last == "input-renew" {
      waiting = true
      await withCheckedContinuation { pending = $0 }
    }
    guard !closed, !replies.isEmpty else { throw PhoneControlError.rejected }
    return try ControlTLSFrame(
      kind: .control, payload: JSONSerialization.data(withJSONObject: replies.removeFirst()))
  }
  func close() { closed = true }
  func resume() {
    pending?.resume()
    pending = nil
  }
}
@MainActor private func renewingClient(_ io: RenewalIO) throws -> PhoneControlClient {
  PhoneControlClient(
    endpoint: try TrustedHostEndpoint(
      host: "127.0.0.1", port: 1234,
      certificatePin: String(repeating: "1", count: 64), authorityInstanceID: "authority-a"),
    io: io,
    storage: RenewalStorage(), now: { io.wall }, controlVersion: 6,
    datagramFactory: { _, _ in throw PhoneControlError.rejected },
    routeNow: { UInt64(max(io.elapsed, 0)) },
    continuousNow: { io.continuous })
}
private func renewalMap() -> ControlMap {
  ControlMap(
    generation: "1", revision: "1",
    controls: [
      ControlRegion(id: "south", action: "south", x: 0, y: 0, width: 0.4, height: 1),
      ControlRegion(id: "trigger", action: "leftTrigger", x: 0.5, y: 0, width: 0.4, height: 1),
    ])
}
@MainActor private func awaitRenewal(_ condition: () -> Bool) async throws {
  for _ in 0..<300 {
    if condition() { return }
    try await Task.sleep(for: .milliseconds(5))
  }
  Issue.record("automatic native renewal did not reach its expected barrier")
}

@Test @MainActor private func automaticSwiftRenewalPreservesTouchesThroughTwoFreshCounters()
  async throws
{
  let io = try RenewalIO()
  let client = try renewingClient(io)
  defer { client.close() }
  _ = try await client.authenticate()
  let engine = try await client.bindInput(renewalMap())
  #expect(engine.begin(id: 1, generation: "1", x: 0.1, y: 0.1))
  #expect(engine.begin(id: 2, generation: "1", x: 0.6, y: 0.1))
  let held = engine.state
  for count in 1...2 {
    io.wall = UInt64(1000 + count * 35_000)
    io.elapsed = Int64(count * 35_000)
    let before = io.inputs.count
    try await awaitRenewal {
      io.renewals == count && io.inputs.count > before && io.commands.last == "input-status"
    }
    #expect(
      !io.closed && engine.connected && engine.state.buttons == held.buttons
        && engine.state.leftTrigger == 1)
    let packet = try #require(io.inputs.dropFirst(before).first)
    #expect(packet.dropFirst(32).prefix(8).allSatisfy { $0 == 0 })
    let grant = try InputPacketGrant(
      key: Data(repeating: UInt8(0x70 + count), count: 32),
      session: Data(repeating: UInt8(0x60 + count), count: 16),
      noncePrefix: Data(repeating: UInt8(0x80 + count), count: 4), generation: 1)
    let decoded = try InputPacketReceiver(grant: grant).open(packet)
    #expect(decoded.buttons == held.buttons && decoded.leftTrigger == 1)
    engine.tick()
    #expect(engine.connected)
  }
  // The second renewal is beyond the original 61,000 wall deadline.
  engine.end(id: 1, generation: "1")
  #expect(engine.connected && engine.state.buttons.isEmpty && engine.state.leftTrigger == 1)
  engine.end(id: 2, generation: "1")
  #expect(engine.connected && GamepadReport.hex(engine.state) == GamepadReport.hex(.neutral))
  #expect(io.commands.filter { $0 == "authenticate" }.count == 1)
}

@Test @MainActor private func lateOrCancelledSwiftRenewalCannotReviveTheOldInteraction()
  async throws
{
  for fault in [
    "wall-expiry", "continuous-expiry", "wall-rollback", "continuous-rollback", "background",
  ] {
    let io = try RenewalIO()
    io.pauseRenewal = true
    let client = try renewingClient(io)
    defer {
      client.close()
      io.resume()
    }
    _ = try await client.authenticate()
    let engine = try await client.bindInput(renewalMap())
    #expect(engine.begin(id: 1, generation: "1", x: 0.1, y: 0.1))
    io.wall = 36_000
    io.elapsed = 35_000
    try await awaitRenewal { io.waiting }
    engine.tick()  // Live input may advance while renewal waits for TLS.
    switch fault {
    case "wall-expiry": io.wall = 61_000
    case "continuous-expiry": io.elapsed = 60_000
    case "wall-rollback": io.wall = 35_999
    case "continuous-rollback": io.elapsed = 34_999
    default: engine.cancel(.background)
    }
    let beforeReply = io.inputs.count
    io.resume()
    try await awaitRenewal { io.closed }
    #expect(!engine.connected && engine.state.buttons.isEmpty && io.inputs.count == beforeReply)
  }
}

@Test @MainActor private func invalidSwiftRenewalScopeAndUnacknowledgedCommitAreTerminal()
  async throws
{
  for fault in ["port", "old-session", "key-reuse", "no-ack"] {
    let io = try RenewalIO()
    io.changeReply = { value in
      var value = value
      if fault == "port" { value["udpPort"] = 43211 }
      if fault == "old-session" { value["replacesSessionId"] = String(repeating: "99", count: 16) }
      if fault == "key-reuse" { value["key"] = String(repeating: "44", count: 32) }
      return value
    }
    io.nullProgress = fault == "no-ack"
    let client = try renewingClient(io)
    defer { client.close() }
    _ = try await client.authenticate()
    let engine = try await client.bindInput(renewalMap())
    #expect(engine.begin(id: 1, generation: "1", x: 0.1, y: 0.1))
    io.wall = 36_000
    io.elapsed = 35_000
    try await awaitRenewal { io.closed }
    #expect(!engine.connected && engine.state.buttons.isEmpty)
  }
}
