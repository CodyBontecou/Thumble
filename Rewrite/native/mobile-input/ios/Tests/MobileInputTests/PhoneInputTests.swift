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
  var pauseAt = 4
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
    if pauseGrant && receiving == pauseAt {
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
  _ io: InputControlIO, now: @escaping () -> UInt64 = { 1000 }, version: Int = 4,
  datagramFactory: @escaping (String, UInt16) throws -> any NativeDatagramIO = {
    try NativeDatagramClient(host: $0, port: $1)
  }
) throws -> PhoneControlClient {
  PhoneControlClient(
    endpoint: try TrustedHostEndpoint(
      host: "127.0.0.1", port: 1234,
      certificatePin: String(repeating: "1", count: 64), authorityInstanceID: "authority-a"),
    io: io, storage: InputTestStorage(), now: now, controlVersion: version,
    datagramFactory: datagramFactory)
}

@MainActor private final class NeverReadyDatagram: NativeDatagramIO {
  private var waiting: CheckedContinuation<Void, any Error>?
  private(set) var closed = false
  func connect() async throws {
    guard !closed else { throw PhoneControlError.rejected }
    try await withCheckedThrowingContinuation { waiting = $0 }
  }
  func offer(_ packet: Data) -> Bool { false }
  func close() {
    closed = true
    let pending = waiting
    waiting = nil
    pending?.resume(throwing: PhoneControlError.rejected)
  }
}
private func version5InputFixture() throws -> [String: [String: Any]] {
  var f = try inputFixture()
  f["hello"]?["controlVersion"] = 5
  f["grant"]?["transport"] = "udp+tls"
  f["grant"]?["udpPort"] = 43210
  return f
}
@Test @MainActor private func stalledUdpSetupCannotDelayNeutralInputOrTlsFallback() async throws {
  let f = try version5InputFixture()
  let io = InputControlIO([f["hello"]!, f["authenticated"]!, f["configuration"]!, f["grant"]!])
  let udp = NeverReadyDatagram()
  let client = try inputClient(io, version: 5, datagramFactory: { _, _ in udp })
  defer { client.close() }
  _ = try await client.authenticate()
  let fence = Task {
    try await Task.sleep(for: .milliseconds(500))
    client.close()
  }
  defer { fence.cancel() }
  let engine = try await client.bindInput(inputMap())
  #expect(engine.connected && io.inputs.count == 1)
  #expect(engine.begin(id: 1, generation: "1", x: 0.2, y: 0.2))
  #expect(io.inputs.count == 2)
  client.close()
  #expect(udp.closed && !engine.connected)
}
@Test @MainActor private func invalidVersion5ProgressClosesTheActualTouchOwner() async throws {
  let f = try version5InputFixture()
  for replacement: [String: Any] in [
    ["active": false], ["sessionId": String(repeating: "99", count: 16)],
    ["lastAcceptedSequence": "2"],
  ] {
    var progress: [String: Any] = [
      "version": 1, "command": "input-status", "connectionId": String(repeating: "ab", count: 16),
      "sessionId": String(repeating: "33", count: 16), "active": true, "generation": "1",
      "revision": "1", "lastAcceptedSequence": "0", "inputEnabled": false,
    ]
    progress.merge(replacement) { _, new in new }
    let io = InputControlIO([
      f["hello"]!, f["authenticated"]!, f["configuration"]!, f["grant"]!, progress,
    ])
    let client = try inputClient(io, version: 5, datagramFactory: { _, _ in NeverReadyDatagram() })
    defer { client.close() }
    _ = try await client.authenticate()
    let engine = try await client.bindInput(inputMap())
    #expect(engine.begin(id: 1, generation: "1", x: 0.2, y: 0.2))
    for _ in 0..<50 {
      if io.closed { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(
      io.closed && !engine.connected
        && GamepadReport.hex(engine.state) == GamepadReport.hex(.neutral))
  }
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
  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["THUMBLE_NATIVE_INPUT_PROBE"] != nil),
    arguments: ["tls", "udp", "udp-blackhole", "renewal-udp", "renewal-tls-fallback"])
  @MainActor
  private func actualPhoneTouchCrossesTlsAndNativeIpcThenRetiresAndReconnectsNeutral(mode: String)
    async throws
  {
    let renewing = mode.hasPrefix("renewal-")
    let process = NativeProbeProcess(
      path: try #require(ProcessInfo.processInfo.environment["THUMBLE_NATIVE_INPUT_PROBE"]),
      arguments: renewing ? ["--renewal-watch"] : [], timeout: .seconds(120))
    do {
      try await process.start()
      func command(_ value: UInt8) async throws { try await process.send(value) }
      func line() async throws -> [String: Any] {
        let data = try await process.line()
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
        certificatePin: invitation.certificatePin,
        authorityInstanceID: invitation.authorityInstanceID
      )
      for generation in ["1", "2"] {
        let control = PhoneControlClient(
          endpoint: endpoint,
          io: try ControlTLSClient(
            host: endpoint.host,
            port: endpoint.port, certificatePin: endpoint.certificatePin), storage: storage,
          now: { UInt64(Date().timeIntervalSince1970 * 1000) },
          controlVersion: renewing ? 6 : (mode == "tls" ? 4 : 5),
          datagramFactory: { host, port in
            if mode == "udp-blackhole" || mode == "renewal-tls-fallback" {
              return BlackholeDatagram()
            }
            return try NativeDatagramClient(host: host, port: port)
          })
        defer { control.close() }
        #expect(try await control.authenticate().inputSessionAvailable)
        try await command(97)
        let configuration = try await line()
        #expect(configuration["generation"] as? String == generation)
        let metadata = try await control.inputConfiguration()
        #expect(
          metadata.active && metadata.generation == generation && metadata.revision == generation)
        #expect(!metadata.inputEnabled)
        let map = ControlMap(
          generation: generation, revision: generation,
          controls: renewing
            ? [
              ControlRegion(id: "south", action: "south", x: 0, y: 0, width: 0.4, height: 1),
              ControlRegion(
                id: "trigger", action: "leftTrigger", x: 0.5, y: 0, width: 0.4, height: 1),
            ] : inputMap().controls)
        let engine = try await control.bindInput(map)
        let adopted = try engine.claimTouchSurface()
        #expect(adopted.generation == generation && adopted.revision == generation)
        #expect(engine.connected)
        try await command(122)
        #expect(try await line()["freshNeutral"] as? Bool == true)
        #expect(engine.begin(id: 1, generation: generation, x: 0.2, y: 0.2))
        if renewing && generation == "1" {
          #expect(engine.begin(id: 2, generation: generation, x: 0.6, y: 0.2))
          // Native frames keep flowing while the initial UDP loss detector selects fallback.
          for _ in 0..<16 {
            try await Task.sleep(for: .milliseconds(16))
            engine.tick()
          }
          try await command(98)
          #expect(try await line()["watching"] as? Bool == true)
          let until = ContinuousClock.now.advanced(by: .seconds(75))
          while ContinuousClock.now < until {
            try await Task.sleep(for: .milliseconds(16))
            engine.tick()
            try #require(engine.connected)
          }
          try await command(118)
          let verified = try await line()
          #expect(verified["continuousHeld"] as? Bool == true)
          #expect((verified["rotations"] as? Int ?? 0) >= 2)
          #expect((verified["durationMs"] as? Int ?? 0) >= 75_000)
          #expect(verified["neutralPulses"] as? Int == 0)
          #expect(verified["inputTtlMs"] as? Int == 350)
          print(
            "native-renewal-witness platform=swift mode=\(mode) durationMs=\(verified["durationMs"] ?? 0) rotations=\(verified["rotations"] ?? 0) samples=\(verified["samples"] ?? 0)"
          )
          engine.end(id: 2, generation: generation)
        } else if generation == "1" || mode != "tls" {
          for _ in 0..<(generation == "1" ? 62 : 5) {
            try await Task.sleep(for: .milliseconds(50))
            engine.tick()
          }
        }
        try await command(104)
        let held = try await line()
        #expect(held["held"] as? Bool == true && held["inputEnabled"] as? Bool == false)
        if generation == "1" { engine.cancel(.background) } else { control.close() }
        try await command(110)
        let neutral = try await line()
        #expect(
          neutral["neutral"] as? Bool == true
            && neutral["reason"] as? String == "native_input_released")
        #expect(!engine.connected && GamepadReport.hex(engine.state) == GamepadReport.hex(.neutral))
      }
      try await command(102)
      #expect(try await line()["completed"] as? Bool == true)
      #expect(await process.wait() == 0)
      await process.stop()
    } catch {
      await process.stop()
      throw error
    }
  }
  @MainActor private final class BlackholeDatagram: NativeDatagramIO {
    private var closed = false
    func connect() async throws {}
    func offer(_ packet: Data) -> Bool { !closed }
    func close() { closed = true }
  }
  private actor ActualInputStorage: ControlCredentialSource, EnrollmentCredentialSink {
    var credential: PhoneCredential?
    func save(_ credential: PhoneCredential) { self.credential = credential }
    func load(hostPin: String, now: UInt64) -> PhoneCredential? { credential }
  }
#endif

@Test @MainActor private func bootstrapConfigurationExposesExactEpochsWithoutAdmittingInput()
  async throws
{
  let f = try inputFixture()
  for changes: [String: Any] in [
    ["active": false, "generation": "0", "revision": "0"],
    ["active": false, "generation": "1", "revision": "1"],
    ["generation": "18446744073709551615", "revision": "18446744073709551615"],
  ] {
    let config = f["configuration"]!.merging(changes) { _, new in new }
    let io = InputControlIO([f["hello"]!, f["authenticated"]!, config])
    let client = try inputClient(io)
    defer { client.close() }
    await #expect(throws: PhoneControlError.self) { try await client.inputConfiguration() }
    _ = try await client.authenticate()
    let receipt = try await client.inputConfiguration()
    #expect(receipt.active == config["active"] as? Bool)
    #expect(receipt.generation == config["generation"] as? String)
    #expect(receipt.revision == config["revision"] as? String)
    #expect(!receipt.inputEnabled && io.inputs.isEmpty)
    #expect(io.commands == ["hello", "authenticate", "input-configuration"])
  }
}
@Test @MainActor private func malformedBootstrapMetadataClosesWithoutGrantOrTouchOwner()
  async throws
{
  let f = try inputFixture()
  for changes: [String: Any] in [
    ["connectionId": String(repeating: "ff", count: 16)], ["generation": "0"],
    ["generation": "18446744073709551616"], ["generation": "01"], ["generation": 1],
    ["revision": "-1"], ["revision": "18446744073709551616"],
    ["active": 1], ["inputEnabled": true], ["credential": "unexpected"],
  ] {
    let io = InputControlIO([
      f["hello"]!, f["authenticated"]!, f["configuration"]!.merging(changes) { _, new in new },
    ])
    let client = try inputClient(io)
    _ = try await client.authenticate()
    await #expect(throws: PhoneControlError.self) { try await client.inputConfiguration() }
    #expect(io.closed && io.inputs.isEmpty)
    #expect(io.commands == ["hello", "authenticate", "input-configuration"])
  }
}
@Test @MainActor private func metadataInspectionDoesNotConsumeOrReplaceExactGrantAdmission()
  async throws
{
  let f = try inputFixture()
  for changed in [false, true] {
    var configuration = f["configuration"]!
    if changed { configuration["revision"] = "2" }
    let io = InputControlIO([
      f["hello"]!, f["authenticated"]!, f["configuration"]!, configuration, f["grant"]!,
    ])
    let client = try inputClient(io)
    defer { client.close() }
    _ = try await client.authenticate()
    #expect(try await client.inputConfiguration().revision == "1")
    #expect(io.inputs.isEmpty)
    if changed {
      await #expect(throws: PhoneControlError.self) { try await client.bindInput(inputMap()) }
      #expect(io.closed && io.inputs.isEmpty && !io.commands.contains("input-grant"))
    } else {
      let engine = try await client.bindInput(inputMap())
      #expect(engine.connected && GamepadReport.hex(engine.state) == GamepadReport.hex(.neutral))
      await #expect(throws: PhoneControlError.self) { try await client.inputConfiguration() }
      #expect(engine.connected && io.inputs.count == 1)
      engine.cancel(.disconnected)
    }
  }
}
@Test @MainActor private func lateBootstrapMetadataCannotSurviveCloseOrCancellation() async throws {
  let f = try inputFixture()
  for cancel in [false, true] {
    let io = InputControlIO([f["hello"]!, f["authenticated"]!, f["configuration"]!])
    let client = try inputClient(io)
    _ = try await client.authenticate()
    io.pauseGrant = true
    io.pauseAt = 3
    let pending = Task { try await client.inputConfiguration() }
    await io.waitForGrant()
    await #expect(throws: PhoneControlError.self) { try await client.status() }
    if cancel { pending.cancel() } else { client.close() }
    io.resume()
    await #expect(throws: PhoneControlError.self) { try await pending.value }
    #expect(io.closed && io.inputs.isEmpty)
    #expect(io.commands == ["hello", "authenticate", "input-configuration"])
  }
}
