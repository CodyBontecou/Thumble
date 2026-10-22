import Foundation
import Testing

@testable import MobileInputCore

@Test private func controlTLSFramingRejectsInvalidLengthsKindsAndInputSizes() throws {
  let frame = try ControlTLSFrame(kind: .control, payload: Data("native".utf8))
  #expect(frame.encoded() == Data([0, 0, 0, 7, 1]) + Data("native".utf8))
  #expect(try ControlTLSFrame.bodyLength(frame.encoded().prefix(4)) == 7)
  #expect(try ControlTLSFrame.decodeBody(frame.encoded().dropFirst(4)).payload == frame.payload)
  #expect(
    try ControlTLSFrame(kind: .control, payload: Data(repeating: 1, count: 65_536)).encoded()
      .prefix(5) == Data([0, 1, 0, 1, 1]))
  #expect(
    try ControlTLSFrame(kind: .input, payload: Data(repeating: 7, count: 108)).encoded().prefix(5)
      == Data([0, 0, 0, 109, 2]))
  for prefix in [
    Data(), Data([0, 0, 0, 0]), Data([0, 0, 0, 1]), Data([0, 1, 0, 2]),
    Data(repeating: 255, count: 4),
  ] {
    #expect(throws: ControlTLSError.self) { try ControlTLSFrame.bodyLength(prefix) }
  }
  for body in [
    Data(), Data([9, 1]), Data([1]), Data([2]) + Data(repeating: 0, count: 107),
    Data([2]) + Data(repeating: 0, count: 109),
  ] {
    #expect(throws: ControlTLSError.self) { try ControlTLSFrame.decodeBody(body) }
  }
}
@Test @MainActor private func controlTLSRejectsMalformedInvitationsAndTerminalReconnect()
  async throws
{
  for pin in ["", "0", String(repeating: "A", count: 64), String(repeating: "é", count: 32)] {
    #expect(throws: ControlTLSError.self) {
      try ControlTLSClient(host: "127.0.0.1", port: 1, certificatePin: pin)
    }
  }
  let pin = String(repeating: "0", count: 64)
  #expect(throws: ControlTLSError.self) {
    try ControlTLSClient(host: "", port: 1, certificatePin: pin)
  }
  #expect(throws: ControlTLSError.self) {
    try ControlTLSClient(host: "127.0.0.1", port: 0, certificatePin: pin)
  }
  let client = try ControlTLSClient(host: "127.0.0.1", port: 1, certificatePin: pin)
  #expect(client.diagnosticRuntimeOutcome == .idle)
  client.close()
  #expect(client.diagnosticRuntimeOutcome == .closed)
  client.close()
  #expect(client.diagnosticRuntimeOutcome == .closed)
  #expect(!client.offer(try ControlTLSFrame(kind: .control, payload: Data([1]))))
  do {
    try await client.connect()
    Issue.record("closed client reconnected")
  } catch {}
  do {
    _ = try await client.receive()
    Issue.record("closed client received")
  } catch {}
}

#if os(macOS)
  private struct ProbeInfo: Decodable {
    let port: UInt16
    let pin: String
    let inputEnabled: Bool
    let scope: String
  }
  @MainActor private func withProbe(mode: String = "valid", _ run: (ProbeInfo) async throws -> Void)
    async throws
  {
    let path = try #require(ProcessInfo.processInfo.environment["THUMBLE_NATIVE_TLS_PROBE"])
    let probe = NativeProbeProcess(path: path, arguments: [mode])
    do {
      try await probe.start()
      let info = try JSONDecoder().decode(ProbeInfo.self, from: await probe.line(maximum: 16_384))
      #expect(!info.inputEnabled && info.scope == "synthetic-loopback-only")
      try await run(info)
      await probe.stop()
    } catch {
      await probe.stop()
      throw error
    }
  }
  @Test(.enabled(if: ProcessInfo.processInfo.environment["THUMBLE_NATIVE_TLS_PROBE"] != nil))
  @MainActor private func actualNetworkFrameworkTLSExchangesControlAndEncryptedInputWithRust()
    async throws
  {
    try await withProbe { info in
      let client = try ControlTLSClient(
        host: "127.0.0.1", port: info.port, certificatePin: info.pin)
      defer { client.close() }
      try await client.connect()
      #expect(client.diagnosticConnectOutcome == .ready)
      #expect(client.diagnosticRuntimeOutcome == .ready)
      let message = Data("actual-swift-native-control".utf8)
      #expect(client.offer(try ControlTLSFrame(kind: .control, payload: message)))
      #expect(try await client.receive().payload == message)
      let fixtureURL = try #require(
        Bundle.module.url(
          forResource: "input-packet-v1", withExtension: "json", subdirectory: "Fixtures"))
      let fixture = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any])
      let vectors = try #require(fixture["vectors"] as? [[String: Any]])
      for (index, accepted) in [(0, true), (1, true), (1, false)] {
        let hex = try #require(vectors[index]["packetHex"] as? String)
        var packet = Data()
        for offset in stride(from: 0, to: hex.count, by: 2) {
          let start = hex.index(hex.startIndex, offsetBy: offset)
          packet.append(try #require(UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)))
        }
        #expect(client.offer(try ControlTLSFrame(kind: .input, payload: packet)))
        let response = try await client.receive()
        let result = try #require(
          JSONSerialization.jsonObject(with: response.payload) as? [String: Any])
        #expect(result["ok"] as? Bool == accepted)
        if !accepted { #expect(result["error"] as? String == "input_packet_rejected") }
        let snapshot = try #require(result["snapshot"] as? [String: Any])
        #expect(snapshot["inputEnabled"] as? Bool == false)
        #expect(snapshot["reportHex"] as? String == vectors[index]["reportHex"] as? String)
      }
    }
  }
  @Test(.enabled(if: ProcessInfo.processInfo.environment["THUMBLE_NATIVE_TLS_PROBE"] != nil))
  @MainActor private func actualNetworkFrameworkTLSRejectsWrongPinBeforeControl() async throws {
    try await withProbe { info in
      let client = try ControlTLSClient(
        host: "127.0.0.1", port: info.port, certificatePin: String(repeating: "0", count: 64))
      defer { client.close() }
      do {
        try await client.connect()
        Issue.record("wrong pin accepted")
      } catch {}
      #expect(!client.offer(try ControlTLSFrame(kind: .control, payload: Data([1]))))
      #expect(
        [ControlTLSConnectOutcome.networkFailed, .deadline].contains(
          client.diagnosticConnectOutcome))
      let failedOutcome = client.diagnosticConnectOutcome
      client.close()
      #expect(client.diagnosticConnectOutcome == failedOutcome)
    }
  }
  @Test(.enabled(if: ProcessInfo.processInfo.environment["THUMBLE_NATIVE_TLS_PROBE"] != nil))
  @MainActor private func actualNetworkFrameworkPinDoesNotBypassCertificatePolicy() async throws {
    for mode in ["expired", "future", "wrong-name", "client-usage"] {
      try await withProbe(mode: mode) { info in
        let client = try ControlTLSClient(
          host: "127.0.0.1", port: info.port, certificatePin: info.pin)
        defer { client.close() }
        do {
          try await client.connect()
          Issue.record("accepted invalid certificate: \(mode)")
        } catch {}
        #expect(!client.offer(try ControlTLSFrame(kind: .control, payload: Data([1]))))
      }
    }
  }
  @Test(.enabled(if: ProcessInfo.processInfo.environment["THUMBLE_NATIVE_TLS_PROBE"] != nil))
  @MainActor private func nativeTLSCoalescesInputBackpressureAndBoundsControlQueue() async throws {
    try await withProbe { info in
      let client = try ControlTLSClient(
        host: "127.0.0.1", port: info.port, certificatePin: info.pin)
      defer { client.close() }
      try await client.connect()
      let url = try #require(
        Bundle.module.url(
          forResource: "input-packet-v1", withExtension: "json", subdirectory: "Fixtures"))
      let fixture = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
      let vectors = try #require(fixture["vectors"] as? [[String: Any]])
      let packets = try vectors.map { vector -> Data in
        let hex = try #require(vector["packetHex"] as? String)
        var packet = Data()
        for offset in stride(from: 0, to: hex.count, by: 2) {
          let start = hex.index(hex.startIndex, offsetBy: offset)
          packet.append(try #require(UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)))
        }
        return packet
      }
      // No suspension lets network callbacks run until every newer snapshot replaces the one pending slot.
      for packet in packets {
        #expect(client.offer(try ControlTLSFrame(kind: .input, payload: packet)))
      }
      for expectedIndex in [0, packets.count - 1] {
        let response = try await client.receive()
        let result = try #require(
          JSONSerialization.jsonObject(with: response.payload) as? [String: Any])
        #expect(result["ok"] as? Bool == true)
        let snapshot = try #require(result["snapshot"] as? [String: Any])
        #expect(snapshot["reportHex"] as? String == vectors[expectedIndex]["reportHex"] as? String)
      }
      let sentinel = Data("no-native-input-backlog".utf8)
      #expect(client.offer(try ControlTLSFrame(kind: .control, payload: sentinel)))
      #expect(try await client.receive().payload == sentinel)
      let control = try ControlTLSFrame(kind: .control, payload: Data([1]))
      for _ in 0..<9 { #expect(client.offer(control)) }
      #expect(!client.offer(control))
      #expect(!client.offer(try ControlTLSFrame(kind: .input, payload: packets[0])))
    }
  }
  @Test(.enabled(if: ProcessInfo.processInfo.environment["THUMBLE_NATIVE_TLS_PROBE"] != nil))
  @MainActor private func grantPacketZeroSurvivesAWriteInFlightAndPrecedesItsStatusBarrier()
    async throws
  {
    try await withProbe { info in
      let client = try ControlTLSClient(
        host: "127.0.0.1", port: info.port, certificatePin: info.pin)
      defer { client.close() }
      try await client.connect()
      let url = try #require(
        Bundle.module.url(
          forResource: "input-packet-v1", withExtension: "json", subdirectory: "Fixtures"))
      let fixture = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
      let vectors = try #require(fixture["vectors"] as? [[String: Any]])
      let packets = try vectors.map { vector -> Data in
        let text = try #require(vector["packetHex"] as? String)
        var bytes = Data()
        for offset in stride(from: 0, to: text.count, by: 2) {
          let start = text.index(text.startIndex, offsetBy: offset)
          bytes.append(try #require(UInt8(text[start..<text.index(start, offsetBy: 2)], radix: 16)))
        }
        return bytes
      }
      let before = Data("before-native-grant".utf8)
      let after = Data("after-native-grant".utf8)
      #expect(client.offer(try ControlTLSFrame(kind: .control, payload: before)))
      // Do not suspend: the first write cannot complete on the main actor yet.
      for packet in packets {
        #expect(client.offer(try ControlTLSFrame(kind: .input, payload: packet)))
      }
      #expect(client.offer(try ControlTLSFrame(kind: .control, payload: after)))
      #expect(try await client.receive().payload == before)
      let first = try await client.receive()
      try #require(first.payload != after, "packet zero was replaced before its status barrier")
      let result = try #require(JSONSerialization.jsonObject(with: first.payload) as? [String: Any])
      #expect(result["ok"] as? Bool == true)
      #expect(
        (result["snapshot"] as? [String: Any])?["reportHex"] as? String == vectors[0]["reportHex"]
          as? String)
      #expect(try await client.receive().payload == after)
      let latest = try await client.receive()
      let latestResult = try #require(
        JSONSerialization.jsonObject(with: latest.payload) as? [String: Any])
      #expect(
        (latestResult["snapshot"] as? [String: Any])?["reportHex"] as? String == vectors.last?[
          "reportHex"] as? String)
    }
  }
  @Test(.enabled(if: ProcessInfo.processInfo.environment["THUMBLE_NATIVE_TLS_PROBE"] != nil))
  @MainActor private func actualNativeTouchEngineDeliversMultitouchThroughTLSAndReleasesOnLoss()
    async throws
  {
    try await withProbe { info in
      let client = try ControlTLSClient(
        host: "127.0.0.1", port: info.port, certificatePin: info.pin)
      defer { client.close() }
      try await client.connect()
      let url = try #require(
        Bundle.module.url(
          forResource: "input-packet-v1", withExtension: "json", subdirectory: "Fixtures"))
      let fixture = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
      func bytes(_ name: String) throws -> Data {
        let hex = try #require(fixture[name] as? String)
        var data = Data()
        for offset in stride(from: 0, to: hex.count, by: 2) {
          let start = hex.index(hex.startIndex, offsetBy: offset)
          data.append(try #require(UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)))
        }
        return data
      }
      let generation = try #require(fixture["generation"] as? String)
      let grant = try InputPacketGrant(
        key: bytes("keyHex"), session: bytes("sessionHex"), noncePrefix: bytes("noncePrefixHex"),
        generation: #require(UInt64(generation)))
      let channel = try InputPacketChannel(
        grant: grant,
        send: { packet in
          guard let frame = try? ControlTLSFrame(kind: .input, payload: packet) else {
            return false
          }
          return client.offer(frame)
        })
      let engine = InputEngine(output: channel.submit)
      try engine.activate(
        ControlMap(
          generation: generation, revision: "1",
          controls: [
            ControlRegion(id: "south", action: "south", x: 0.1, y: 0.1, width: 0.2, height: 0.2),
            ControlRegion(id: "lt", action: "leftTrigger", x: 0.4, y: 0.1, width: 0.2, height: 0.2),
            ControlRegion(
              id: "rt", action: "rightTrigger", x: 0.7, y: 0.1, width: 0.2, height: 0.2),
            ControlRegion(id: "ls", action: "leftStick", x: 0.1, y: 0.5, width: 0.3, height: 0.3),
            ControlRegion(id: "rs", action: "rightStick", x: 0.6, y: 0.5, width: 0.3, height: 0.3),
          ]))
      @MainActor func verifyNativeState() async throws {
        let response = try await client.receive()
        let result = try #require(
          JSONSerialization.jsonObject(with: response.payload) as? [String: Any])
        #expect(result["ok"] as? Bool == true)
        let snapshot = try #require(result["snapshot"] as? [String: Any])
        let expected = GamepadReport.encode(engine.state).map { String(format: "%02x", $0) }
          .joined()
        #expect(snapshot["reportHex"] as? String == expected)
        #expect(snapshot["inputEnabled"] as? Bool == false)
      }
      try engine.connect(generation: generation)
      try await verifyNativeState()
      for (id, x, y) in [
        (UInt64(1), 0.2, 0.2), (2, 0.5, 0.2), (3, 0.8, 0.2), (4, 0.38, 0.65), (5, 0.75, 0.52),
      ] {
        #expect(engine.begin(id: id, generation: generation, x: x, y: y))
        try await verifyNativeState()
      }
      #expect(engine.state.buttons.contains(.south))
      #expect(engine.state.leftTrigger == 1 && engine.state.rightTrigger == 1)
      #expect(engine.state.leftStickX != 0 && engine.state.rightStickY != 0)
      client.close()
      engine.tick()
      #expect(!engine.connected && engine.state.buttons.isEmpty)
      #expect(engine.state.leftTrigger == 0 && engine.state.rightTrigger == 0)
      #expect(engine.lastRelease == .transportFailure)
      #expect(throws: InputError.freshGenerationRequired) {
        try engine.connect(generation: generation)
      }
    }
  }
#endif

@Test private func connectDiagnosticPreservesFirstTerminalOutcomeAcrossLateCallbacks() {
  for outcome: ControlTLSConnectOutcome in [
    .deadline, .networkFailed, .cancelled, .versionRejected, .alpnRejected, .ready,
  ] {
    var diagnostic = ControlTLSConnectDiagnostic()
    #expect(diagnostic.outcome == .idle)
    diagnostic.begin()
    #expect(diagnostic.outcome == .connecting)
    diagnostic.finish(outcome)
    // A cancelled NWConnection callback, deadline task or late ready callback
    // cannot replace the first connection result after cleanup begins.
    for late: ControlTLSConnectOutcome in [.cancelled, .networkFailed, .deadline, .ready] {
      diagnostic.finish(late)
      diagnostic.begin()
      #expect(diagnostic.outcome == outcome)
    }
  }
}
@Test @MainActor private func explicitCloseBeforeOrDuringConnectPreservesCancellation() async throws
{
  let pin = String(repeating: "0", count: 64)
  let client = try ControlTLSClient(host: "127.0.0.1", port: 1, certificatePin: pin)
  #expect(client.diagnosticConnectOutcome == .idle)
  // A close queued before the unstructured connect task starts is terminal;
  // the task must throw without overwriting that outcome or reconnecting.
  let opening = Task { try await client.connect() }
  client.close()
  do {
    try await opening.value
    Issue.record("closed connection accepted")
  } catch {}
  #expect(client.diagnosticConnectOutcome == .cancelled)
  client.close()
  #expect(client.diagnosticConnectOutcome == .cancelled)
}
