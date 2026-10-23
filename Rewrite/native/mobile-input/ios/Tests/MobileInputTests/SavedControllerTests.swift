import Foundation
import Testing

@testable import MobileInputCore

private func savedFixture() throws -> [String: Any] {
  let url = try #require(
    Bundle.module.url(
      forResource: "saved-controller-control-v8", withExtension: "json", subdirectory: "Fixtures"))
  let data = try Data(contentsOf: url)
  return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}
private func savedRequest() throws -> SavedControllerRequest {
  try SavedControllerRequest(
    configurationRevision: "3", sourceHash: String(repeating: "a", count: 64),
    profileID: "aaaaaaaa-0000-0000-0000-000000000001", generation: "7", revision: "2",
    viewportWidth: "874", viewportHeight: "393")
}
private func savedFields(_ value: [String: Any]) throws -> [String: EnrollmentJSON.Value] {
  try EnrollmentJSON.parse(JSONSerialization.data(withJSONObject: value), allowNull: true)
}
@Test func savedControllerSharedFixturePreservesExactControlsAndOptionalHaptics() throws {
  let fields = try #require(savedFixture()["reply"] as? [String: Any])
  let result = try SavedControllerWire.decode(
    try savedFields(fields), request: savedRequest(),
    authority: "synthetic-authority", connection: String(repeating: "cd", count: 16))
  #expect(result.map.controls.count == 2)
  #expect(result.map.controls[0].id == "synthetic-south")
  #expect(result.map.controls[0].x == 0.1)
  #expect(result.map.controls[0].hapticFeedback?.intensity == 0.5)
  #expect(result.map.controls[1].hapticFeedback == nil)
  #expect(result.configurationSha256 == String(repeating: "b", count: 64))
  #expect(result.bridgeMap["controls"] is [[String: Any]])
}
@Test func savedControllerWireRejectsMismatchedPinsMalformedNumbersAndPartialHaptics() throws {
  let baseline = try #require(savedFixture()["reply"] as? [String: Any])
  let changes: [(String, Any?)] = [
    ("connectionId", "ff"), ("authorityInstanceId", "other"), ("configurationRevision", "4"),
    ("sourceHash", String(repeating: "b", count: 64)), ("profileId", "wrong"),
    ("generation", "8"), ("revision", "3"), ("viewportWidth", "874.0"),
    ("configurationSha256", "invalid"), ("controlCount", 0), ("controlCount", 65),
    ("control1Id", "synthetic-south"), ("control0Action", "arbitrary"),
    ("control0X", "-0"), ("control0X", "01"), ("control0X", "1E-1"),
    ("control0X", "1e9999"), ("control0X", "0.1\n"), ("control0X", "NaN"),
    ("control0Width", "1.1"), ("control0HapticDuration", "0.301"),
    ("control0HapticStyle", "unknown"), ("control0HapticPattern", nil), ("extra", "field"),
  ]
  for (key, value) in changes {
    var fields = baseline
    fields[key] = value
    #expect(throws: (any Error).self) {
      try SavedControllerWire.decode(
        try savedFields(fields), request: savedRequest(),
        authority: "synthetic-authority", connection: String(repeating: "cd", count: 16))
    }
  }
  var none = baseline
  none["control0HapticStyle"] = "none"
  none["control0HapticIntensity"] = "2"
  #expect(throws: (any Error).self) {
    try SavedControllerWire.decode(
      try savedFields(none), request: savedRequest(),
      authority: "synthetic-authority", connection: String(repeating: "cd", count: 16))
  }
  #expect(throws: (any Error).self) {
    try EnrollmentJSON.parse(Data(#"{"version":1,"version":1}"#.utf8))
  }
}
@Test func savedControllerWireAcceptsBoundedScientificTextAndRejectsRequestViewport() throws {
  #expect(SavedControllerWire.number("1e-1") == 0.1)
  for value in ["-1", "+1", ".1", "1.", "1E2", "1e999", "١", String(repeating: "1", count: 33)] {
    #expect(SavedControllerWire.number(value) == nil)
  }
  #expect(throws: (any Error).self) {
    try SavedControllerRequest(
      configurationRevision: "3", sourceHash: String(repeating: "a", count: 64),
      profileID: "aaaaaaaa-0000-0000-0000-000000000001", generation: "7", revision: "2",
      viewportWidth: "393", viewportHeight: "874")
  }
  let errors = try #require(savedFixture()["errors"] as? [[String: Any]])
  for fields in errors {
    #expect(throws: SavedControllerError.unavailable(try #require(fields["error"] as? String))) {
      try SavedControllerWire.decode(
        try savedFields(fields), request: savedRequest(),
        authority: "synthetic-authority", connection: String(repeating: "cd", count: 16))
    }
  }
}
private actor SavedStorage: ControlCredentialSource {
  let credential: PhoneCredential
  init(_ credential: PhoneCredential) { self.credential = credential }
  func load(hostPin: String, now: UInt64) -> PhoneCredential? { credential }
}
@MainActor private final class SavedIO: EnrollmentFrameIO {
  var frames: [ControlTLSFrame]
  var sent: [[String: EnrollmentJSON.Value]] = []
  var closed = false, paused = false, entered = false
  var receiveCount = 0
  var beforeReceive: ((Int) -> Void)?
  init(_ fields: [[String: Any]]) throws {
    frames = try fields.map {
      try ControlTLSFrame(kind: .control, payload: JSONSerialization.data(withJSONObject: $0))
    }
  }
  func connect() async throws {
    entered = true
    if paused { try await Task.sleep(for: .seconds(10)) }
  }
  func offer(_ frame: ControlTLSFrame) -> Bool {
    guard !closed, let value = try? EnrollmentJSON.parse(frame.payload) else { return false }
    sent.append(value)
    return true
  }
  func receive() async throws -> ControlTLSFrame {
    guard !closed, !frames.isEmpty else { throw SavedControllerError.rejected }
    receiveCount += 1
    beforeReceive?(receiveCount)
    return frames.removeFirst()
  }
  func close() { closed = true }
}
@MainActor private func savedSetup(
  version: Int = 8, hostExpiry: UInt64 = 60100, credentialExpiry: UInt64 = 100000,
  clock: @escaping () -> UInt64 = { 100 }
) throws -> (SavedControllerClient, SavedIO) {
  let endpoint = try TrustedHostEndpoint(
    host: "127.0.0.1", port: 1234,
    certificatePin: String(repeating: "1", count: 64), authorityInstanceID: "synthetic-authority")
  let credential = try PhoneCredential(
    hostPin: endpoint.certificatePin, phoneID: "phone-a", epoch: 1,
    expiresAt: credentialExpiry, token: Data(repeating: 34, count: 32))
  let io = try SavedIO([
    [
      "version": 1, "command": "hello", "authorityInstanceId": endpoint.authorityInstanceID,
      "controlVersion": version, "role": "management", "inputVersion": 1, "documentVersion": 1,
      "capabilitiesVersion": 1, "inputEnabled": false,
    ],
    [
      "version": 1, "command": "authenticated", "authorityInstanceId": endpoint.authorityInstanceID,
      "phoneId": "phone-a", "credentialEpoch": "1",
      "connectionId": String(repeating: "cd", count: 16),
      "expiresAt": hostExpiry, "role": "management", "inputSessionAvailable": false,
      "inputEnabled": false,
    ],
    try #require(savedFixture()["reply"] as? [String: Any]),
  ])
  return (
    SavedControllerClient(
      endpoint: endpoint, io: io, storage: SavedStorage(credential), now: clock), io
  )
}
@Test @MainActor func savedControllerClientUsesSeparateReadOnlyV8AndClosesAfterOneRead()
  async throws
{
  let (client, io) = try savedSetup()
  let result = try await client.read(savedRequest())
  #expect(result.map.controls.count == 2)
  #expect(io.closed)
  #expect(io.sent.count == 3)
  #expect(io.sent.first?["controlVersion"] == .integer(8))
  #expect(io.sent.last?["command"] == .string("configuration-controls"))
  await #expect(throws: (any Error).self) { try await client.read(savedRequest()) }
}
@Test @MainActor func savedControllerClientRejectsUnsupportedVersionAndCancelsWithoutFallback()
  async throws
{
  let (old, oldIO) = try savedSetup(version: 7)
  await #expect(throws: (any Error).self) { try await old.read(savedRequest()) }
  #expect(oldIO.closed)
  #expect(oldIO.sent.count == 1)
  let (client, io) = try savedSetup()
  io.paused = true
  let operation = Task { try await client.read(savedRequest()) }
  for _ in 0..<1000 {
    if io.entered { break }
    await Task.yield()
  }
  #expect(io.entered)
  operation.cancel()
  await #expect(throws: (any Error).self) { try await operation.value }
  #expect(io.closed)
  #expect(io.sent.isEmpty)
}

private final class SavedStackResult: @unchecked Sendable {
  private let lock = NSLock()
  private var failure: String?
  func fail(_ code: String) {
    lock.lock()
    defer { lock.unlock() }
    failure = code
  }
  func read() -> String? {
    lock.lock()
    defer { lock.unlock() }
    return failure
  }
}
@Test func savedControllerMaximumMapFitsRetainedConstrainedStackAndFrameBoundary() throws {
  #expect(MemoryLayout<SavedControllerMap>.size <= 128)
  #expect(MemoryLayout<SavedControllerRequest>.size <= 128)
  let result = SavedStackResult()
  let done = DispatchSemaphore(value: 0)
  let thread = Thread {
    defer { done.signal() }
    do {
      var fields = try #require(savedFixture()["reply"] as? [String: Any])
      fields = fields.filter { !$0.key.hasPrefix("control") }
      fields["controlCount"] = 64
      for index in 0..<64 {
        let prefix = "control\(index)"
        fields[prefix + "Id"] = "synthetic-\(index)"
        fields[prefix + "Action"] = "south"
        fields[prefix + "X"] = "0.1"
        fields[prefix + "Y"] = "0.2"
        fields[prefix + "Width"] = "0.15"
        fields[prefix + "Height"] = "0.3"
        fields[prefix + "HapticStyle"] = "light"
        fields[prefix + "HapticPattern"] = "single"
        fields[prefix + "HapticIntensity"] = "0.5"
        fields[prefix + "HapticSharpness"] = "0.4"
        fields[prefix + "HapticDuration"] = "0.06"
      }
      var bytes = try JSONSerialization.data(withJSONObject: fields)
      guard bytes.count <= 65_536 else { throw SavedControllerError.rejected }
      bytes.append(contentsOf: repeatElement(UInt8(32), count: 65_536 - bytes.count))
      let frame = try ControlTLSFrame(kind: .control, payload: bytes)
      let parsed = try EnrollmentJSON.parse(frame.payload)
      let map = try SavedControllerWire.decode(
        parsed, request: savedRequest(),
        authority: "synthetic-authority", connection: String(repeating: "cd", count: 16))
      guard map.map.controls.count == 64 else { throw SavedControllerError.rejected }
      _ = try map.map.validated()
      bytes.append(32)
      do {
        _ = try ControlTLSFrame(kind: .control, payload: bytes)
        result.fail("oversized_frame_accepted")
      } catch {}
      do {
        _ = try EnrollmentJSON.parse(bytes)
        result.fail("oversized_json_accepted")
      } catch {}
    } catch { result.fail("maximum_map_decode_failed") }
  }
  thread.stackSize = 512 * 1024
  thread.start()
  #expect(done.wait(timeout: .now() + 10) == .success)
  #expect(result.read() == nil)
}

@MainActor private final class SavedMapClock { var now: UInt64 = 100 }
@Test(arguments: ["host-ahead", "local-cap", "rollback", "beyond-credential", "overflow"])
@MainActor func savedMapClockSkewUsesBoundedLocalLifetimeAndPreservesTerminalGuards(_ mode: String)
  async throws
{
  let clock = SavedMapClock()
  let overflow = mode == "overflow"
  if overflow { clock.now = UInt64(Int64.max) - 100 }
  let (client, io) = try savedSetup(
    hostExpiry: overflow ? UInt64(Int64.max) : mode == "beyond-credential" ? 100001 : 61100,
    credentialExpiry: overflow ? UInt64(Int64.max) : 100000, clock: { clock.now })
  io.beforeReceive = { index in
    if index == 3 && mode == "local-cap" { clock.now = 60100 }
    if index == 3 && mode == "rollback" { clock.now = 99 }
  }
  if mode == "host-ahead" {
    #expect(try await client.read(savedRequest()).map.controls.count == 2)
    #expect(io.sent.count == 3)
  } else {
    await #expect(throws: SavedControllerError.self) { try await client.read(savedRequest()) }
    #expect(io.sent.count == (mode == "local-cap" || mode == "rollback" ? 3 : 2))
  }
  #expect(io.closed)
}
