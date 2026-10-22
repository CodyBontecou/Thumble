import Foundation
import Testing
import ThumbleContracts

@testable import MobileInputCore

private actor InputTestStorage: ControlCredentialSource {
  var loads = 0
  func load(hostPin: String, now: UInt64) throws -> PhoneCredential? {
    loads += 1
    return try PhoneCredential(
      hostPin: hostPin, phoneID: "phone-a", epoch: 1,
      expiresAt: 100_000, token: Data(repeating: 34, count: 32))
  }
}
@MainActor private final class InputControlIO: EnrollmentFrameIO {
  var replies: [[String: Any]]
  var frames: [ControlTLSFrame] = []
  var closed = false
  var receiving = 0
  var beforeReceive: (Int) -> Void = { _ in }
  var paused: CheckedContinuation<Void, Never>?
  var pauseGrant = false
  var didPause = false
  var onPause: CheckedContinuation<Void, Never>?
  init(_ replies: [[String: Any]]) { self.replies = replies }
  func connect() async throws {}
  func offer(_ frame: ControlTLSFrame) -> Bool {
    guard !closed else { return false }
    frames.append(frame)
    return true
  }
  func receive() async throws -> ControlTLSFrame {
    receiving += 1
    if pauseGrant && receiving == 4 {
      didPause = true
      onPause?.resume()
      onPause = nil
      await withCheckedContinuation { paused = $0 }
    }
    beforeReceive(receiving)
    guard !closed, !replies.isEmpty else { throw PhoneControlError.rejected }
    return try ControlTLSFrame(
      kind: .control,
      payload: JSONSerialization.data(withJSONObject: replies.removeFirst()))
  }
  func waitForGrant() async { if !didPause { await withCheckedContinuation { onPause = $0 } } }
  func resume() {
    paused?.resume()
    paused = nil
  }
  func close() { closed = true }
  var inputs: [Data] { frames.filter { $0.kind == .input }.map(\.payload) }
  var commands: [String] {
    frames.filter { $0.kind == .control }.compactMap {
      guard let value = try? EnrollmentJSON.parse($0.payload),
        case .string(let command)? = value["command"]
      else { return nil }
      return command
    }
  }
}
private func inputFixture() throws -> [String: [String: Any]] {
  let path = try #require(
    Bundle.module.url(
      forResource: "native-input-control-v4", withExtension: "json", subdirectory: "Fixtures"))
  let value = try #require(
    JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
  return try Dictionary(
    uniqueKeysWithValues: ["hello", "authenticated", "configuration", "grant", "status"].map {
      ($0, try #require(value[$0] as? [String: Any]))
    })
}
private func inputMap() -> ControlMap {
  ControlMap(
    generation: "1", revision: "1",
    controls: [ControlRegion(id: "south", action: "south", x: 0, y: 0, width: 1, height: 1)])
}
@MainActor private func inputClient(
  _ io: InputControlIO, now: @escaping () -> UInt64 = { 1000 }, version: Int = 4
) throws -> PhoneControlClient {
  PhoneControlClient(
    endpoint: try TrustedHostEndpoint(
      host: "127.0.0.1", port: 1234,
      certificatePin: String(repeating: "1", count: 64), authorityInstanceID: "authority-a"),
    io: io, storage: InputTestStorage(), now: now, controlVersion: version)
}

@Test @MainActor private func version4BindsOneNativeEngineAndStartsNeutralWithoutExportingGrant()
  async throws
{
  let f = try inputFixture()
  let io = InputControlIO([f["hello"]!, f["authenticated"]!, f["configuration"]!, f["grant"]!])
  let client = try inputClient(io)
  defer { client.close() }
  #expect(try await client.authenticate().inputSessionAvailable)
  let engine = try await client.bindInput(inputMap())
  #expect(engine.connected)
  await #expect(throws: PhoneControlError.self) { try await client.bindInput(inputMap()) }
  #expect(engine.connected)
  let receiver = InputPacketReceiver(
    grant: try InputPacketGrant(
      key: Data(repeating: 0x44, count: 32),
      session: Data(repeating: 0x33, count: 16), noncePrefix: Data(repeating: 0x55, count: 4),
      generation: 1))
  #expect(try GamepadReport.hex(receiver.open(io.inputs[0])) == GamepadReport.hex(.neutral))
  #expect(engine.begin(id: 1, generation: "1", x: 0.2, y: 0.2))
  #expect(try receiver.open(io.inputs[1]).buttons == [.south])
  engine.cancel(.background)
  #expect(
    !engine.connected && io.closed && GamepadReport.hex(engine.state) == GamepadReport.hex(.neutral)
  )
  #expect(io.commands == ["hello", "authenticate", "input-configuration", "input-grant"])
}
@Test @MainActor private func metadataVersionCannotRequestInputAndInputVersionRefusesDowngrade()
  async throws
{
  let f = try inputFixture()
  for version in [2, 3] {
    let io = InputControlIO([f["hello"]!.merging(["controlVersion": version]) { _, new in new }])
    let client = try inputClient(io)
    await #expect(throws: PhoneControlError.self) { try await client.authenticate() }
    #expect(io.closed && io.commands == ["hello"])
  }
  var hello = f["hello"]!
  hello["controlVersion"] = 3
  var auth = f["authenticated"]!
  auth["inputSessionAvailable"] = false
  let io = InputControlIO([hello, auth])
  let client = try inputClient(io, version: 3)
  defer { client.close() }
  _ = try await client.authenticate()
  await #expect(throws: PhoneControlError.self) { try await client.bindInput(inputMap()) }
  #expect(io.commands == ["hello", "authenticate"])
}
@Test @MainActor private func staleInactiveForeignOrExtendedConfigurationNeverRequestsGrant()
  async throws
{
  let f = try inputFixture()
  for change: [String: Any] in [
    ["active": false], ["generation": "2"], ["revision": "0"],
    ["connectionId": String(repeating: "0", count: 32)], ["inputEnabled": true], ["extra": true],
  ] {
    let io = InputControlIO([
      f["hello"]!, f["authenticated"]!, f["configuration"]!.merging(change) { _, new in new },
    ])
    let client = try inputClient(io)
    _ = try await client.authenticate()
    await #expect(throws: PhoneControlError.self) { try await client.bindInput(inputMap()) }
    #expect(io.closed && io.inputs.isEmpty && !io.commands.contains("input-grant"))
  }
}
@Test @MainActor private func malformedOrCrossConnectionGrantNeverCreatesSender() async throws {
  let f = try inputFixture()
  for change: [String: Any] in [
    ["version": 2], ["command": "other"], ["connectionId": "cd".repeated(16)],
    ["generation": "01"], ["revision": "2"], ["sessionId": "00".repeated(16)],
    ["key": "AA".repeated(32)],
    ["noncePrefix": "0"], ["lifetimeMs": 99], ["lifetimeMs": 60_001], ["packetVersion": 2],
    ["packetBytes": 107], ["packetLimit": 1_048_576], ["transport": "udp"], ["inputEnabled": true],
    ["extra": "x"],
  ] {
    let io = InputControlIO([
      f["hello"]!, f["authenticated"]!, f["configuration"]!,
      f["grant"]!.merging(change) { _, new in new },
    ])
    let client = try inputClient(io)
    _ = try await client.authenticate()
    await #expect(throws: PhoneControlError.self) { try await client.bindInput(inputMap()) }
    #expect(io.closed && io.inputs.isEmpty)
  }
}
extension String {
  fileprivate func repeated(_ count: Int) -> String { String(repeating: self, count: count) }
}
@Test @MainActor private func grantLatencyConsumesLifetimeAndClockFailureClosesHeldInput()
  async throws
{
  let f = try inputFixture()
  for delayed in [true, false] {
    var now: UInt64 = 1000
    let io = InputControlIO([f["hello"]!, f["authenticated"]!, f["configuration"]!, f["grant"]!])
    if delayed { io.beforeReceive = { if $0 == 4 { now = 2000 } } }
    let client = try inputClient(io, now: { now })
    _ = try await client.authenticate()
    if delayed {
      await #expect(throws: PhoneControlError.self) { try await client.bindInput(inputMap()) }
      #expect(io.inputs.isEmpty && io.closed)
    } else {
      let engine = try await client.bindInput(inputMap())
      #expect(engine.begin(id: 1, generation: "1", x: 0.2, y: 0.2))
      now = 2000
      engine.tick()
      #expect(
        !engine.connected && GamepadReport.hex(engine.state) == GamepadReport.hex(.neutral)
          && io.closed)
    }
  }
}
@Test @MainActor private func closedOrCancelledGrantReadCannotRestoreTouches() async throws {
  let f = try inputFixture()
  for cancel in [false, true] {
    let io = InputControlIO([f["hello"]!, f["authenticated"]!, f["configuration"]!, f["grant"]!])
    io.pauseGrant = true
    let client = try inputClient(io)
    _ = try await client.authenticate()
    let binding = Task { try await client.bindInput(inputMap()) }
    await io.waitForGrant()
    if cancel { binding.cancel() } else { client.close() }
    io.resume()
    await #expect(throws: PhoneControlError.self) { try await binding.value }
    #expect(io.inputs.isEmpty && io.closed)
  }
}
@Test @MainActor private func heartbeatRejectsChangedReceiptAndRetiresTheNativeTouchOwner()
  async throws
{
  var f = try inputFixture()
  f["grant"]!["lifetimeMs"] = 5000
  f["status"]!["connectionId"] = "cd".repeated(16)
  let io = InputControlIO([
    f["hello"]!, f["authenticated"]!, f["configuration"]!, f["grant"]!, f["status"]!,
  ])
  let client = try inputClient(io)
  _ = try await client.authenticate()
  let engine = try await client.bindInput(inputMap())
  defer { client.close() }
  #expect(engine.begin(id: 1, generation: "1", x: 0.2, y: 0.2))
  try await Task.sleep(for: .milliseconds(1150))
  #expect(
    io.closed && !engine.connected && GamepadReport.hex(engine.state) == GamepadReport.hex(.neutral)
  )
}
@Test(arguments: ReleaseReason.allCases) @MainActor
private func everyNativeLifecycleCancellationClosesTheGrantChannel(_ reason: ReleaseReason)
  async throws
{
  let f = try inputFixture()
  let io = InputControlIO([f["hello"]!, f["authenticated"]!, f["configuration"]!, f["grant"]!])
  let client = try inputClient(io)
  _ = try await client.authenticate()
  let engine = try await client.bindInput(inputMap())
  #expect(engine.begin(id: 1, generation: "1", x: 0.2, y: 0.2))
  engine.cancel(reason)
  #expect(
    io.closed && !engine.connected && GamepadReport.hex(engine.state) == GamepadReport.hex(.neutral)
  )
}

@Test @MainActor private func wallClockRollbackCannotExtendNativeGrant() async throws {
  let f = try inputFixture()
  var now: UInt64 = 1000
  let io = InputControlIO([f["hello"]!, f["authenticated"]!, f["configuration"]!, f["grant"]!])
  let client = try inputClient(io, now: { now })
  _ = try await client.authenticate()
  var feedback: [String] = []
  let engine = try await client.bindInput(
    inputMap(), feedback: { feedback.append(GamepadReport.hex($0)) })
  #expect(engine.begin(id: 1, generation: "1", x: 0.2, y: 0.2))
  let sent = io.inputs.count
  now = 999
  engine.tick()
  #expect(io.closed && !engine.connected && io.inputs.count == sent)
  #expect(feedback.last == GamepadReport.hex(.neutral))
}
#if os(macOS)
  @Test(.enabled(if: ProcessInfo.processInfo.environment["THUMBLE_NATIVE_INPUT_PROBE"] != nil))
  @MainActor
  private func actualPhoneTouchCrossesTlsAndNativeIpcThenRetiresAndReconnectsNeutral() async throws
  {
    let process = Process()
    let output = Pipe()
    let input = Pipe()
    process.executableURL = URL(
      fileURLWithPath: try #require(
        ProcessInfo.processInfo.environment["THUMBLE_NATIVE_INPUT_PROBE"]))
    process.standardOutput = output
    process.standardInput = input
    try process.run()
    defer { if process.isRunning { process.terminate() } }
    func command(_ value: UInt8) throws {
      try input.fileHandleForWriting.write(contentsOf: Data([value]))
    }
    let reader = InputProbeReader(output.fileHandleForReading)
    func line() async throws -> [String: Any] {
      let data = try await reader.line()
      return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    let offer = try await line()
    let invitation = try EnrollmentInvitation(
      host: "127.0.0.1", port: UInt16(try #require(offer["port"] as? Int)),
      certificatePin: try #require(offer["pin"] as? String),
      authorityInstanceID: try #require(offer["authorityInstanceId"] as? String),
      windowID: try #require(offer["windowId"] as? String),
      secret: try #require(offer["secret"] as? String),
      expiresAt: UInt64(try #require(offer["expiresAt"] as? Int)))
    let storage = ActualInputStorage()
    let enrollment = PhoneEnrollmentClient(
      invitation: invitation,
      io: try ControlTLSClient(
        host: invitation.host,
        port: invitation.port, certificatePin: invitation.certificatePin), sink: storage,
      now: { UInt64(Date().timeIntervalSince1970 * 1000) })
    _ = try await enrollment.enroll(phoneID: "phone-a", label: "Native touch witness")
    enrollment.close()
    let endpoint = try TrustedHostEndpoint(
      host: invitation.host, port: invitation.port,
      certificatePin: invitation.certificatePin, authorityInstanceID: invitation.authorityInstanceID
    )
    for generation in ["1", "2"] {
      let control = PhoneControlClient(
        endpoint: endpoint,
        io: try ControlTLSClient(
          host: endpoint.host,
          port: endpoint.port, certificatePin: endpoint.certificatePin), storage: storage,
        now: { UInt64(Date().timeIntervalSince1970 * 1000) }, controlVersion: 4)
      defer { control.close() }
      #expect(try await control.authenticate().inputSessionAvailable)
      try command(97)
      let configuration = try await line()
      #expect(configuration["generation"] as? String == generation)
      let map = ControlMap(
        generation: generation, revision: generation, controls: inputMap().controls)
      let engine = try await control.bindInput(map)
      try command(122)
      #expect(try await line()["freshNeutral"] as? Bool == true)
      #expect(engine.begin(id: 1, generation: generation, x: 0.2, y: 0.2))
      if generation == "1" {
        for _ in 0..<62 {
          try await Task.sleep(for: .milliseconds(50))
          engine.tick()
        }
      }
      try command(104)
      let held = try await line()
      #expect(held["held"] as? Bool == true && held["inputEnabled"] as? Bool == false)
      if generation == "1" { engine.cancel(.background) } else { control.close() }
      try command(110)
      let neutral = try await line()
      #expect(
        neutral["neutral"] as? Bool == true
          && neutral["reason"] as? String == "native_input_released")
      #expect(!engine.connected && GamepadReport.hex(engine.state) == GamepadReport.hex(.neutral))
    }
    try command(102)
    #expect(try await line()["completed"] as? Bool == true)
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
  }
  private actor InputProbeReader {
    let handle: FileHandle
    init(_ handle: FileHandle) { self.handle = handle }
    func line() throws -> Data {
      var data = Data()
      while data.count < 65536 {
        guard let byte = try handle.read(upToCount: 1), !byte.isEmpty else {
          throw PhoneControlError.rejected
        }
        if byte[0] == 10 { return data }
        data.append(byte)
      }
      throw PhoneControlError.rejected
    }
  }
  private actor ActualInputStorage: ControlCredentialSource, EnrollmentCredentialSink {
    var credential: PhoneCredential?
    func save(_ credential: PhoneCredential) { self.credential = credential }
    func load(hostPin: String, now: UInt64) -> PhoneCredential? { credential }
  }
#endif
