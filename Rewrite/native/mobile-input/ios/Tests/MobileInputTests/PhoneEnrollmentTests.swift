import Foundation
import Testing

@testable import MobileInputCore

@MainActor private final class EnrollmentEvents {
  var items: [String] = []
  func add(_ value: String) { items.append(value) }
}
private actor EnrollmentTestSink: EnrollmentCredentialSink {
  let events: EnrollmentEvents
  let fail: Bool, pause: Bool
  var saved: PhoneCredential?
  var started = false
  var waiter: CheckedContinuation<Void, Never>?
  init(_ events: EnrollmentEvents, fail: Bool = false, pause: Bool = false) {
    self.events = events
    self.fail = fail
    self.pause = pause
  }
  func save(_ credential: PhoneCredential) async throws {
    if fail { throw PhoneCredentialError.unavailable }
    saved = credential
    await events.add("saved")
    started = true
    waiter?.resume()
    waiter = nil
    if pause { try await Task.sleep(for: .seconds(30)) }
  }
  func waitForStart() async { if !started { await withCheckedContinuation { waiter = $0 } } }
}
@MainActor private final class EnrollmentFakeIO: EnrollmentFrameIO {
  var frames: [ControlTLSFrame]
  var closed = false
  var failConnect = false
  let events: EnrollmentEvents
  init(_ objects: [[String: Any]], events: EnrollmentEvents) throws {
    self.events = events
    frames = try objects.map {
      try ControlTLSFrame(kind: .control, payload: JSONSerialization.data(withJSONObject: $0))
    }
  }
  func connect() async throws {
    events.add("connect")
    if failConnect { throw PhoneEnrollmentError.rejected }
  }
  func offer(_ frame: ControlTLSFrame) -> Bool {
    guard !closed, let values = try? EnrollmentJSON.parse(frame.payload),
      case .string(let command)? = values["command"]
    else { return false }
    events.add(command)
    return true
  }
  func receive() async throws -> ControlTLSFrame {
    guard !closed, !frames.isEmpty else { throw PhoneEnrollmentError.rejected }
    return frames.removeFirst()
  }
  func close() {
    closed = true
    events.add("closed")
  }
}
private func enrollmentFixture() throws -> [String: Any] {
  let path = try #require(
    Bundle.module.url(
      forResource: "enrollment-control-v2", withExtension: "json", subdirectory: "Fixtures"))
  return try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
}
private func object(_ fixture: [String: Any], _ key: String) throws -> [String: Any] {
  try #require(fixture[key] as? [String: Any])
}
private func invitation() throws -> EnrollmentInvitation {
  let path = try #require(
    Bundle.module.url(
      forResource: "pairing-invitation-v1", withExtension: "json", subdirectory: "Fixtures"))
  let fixture = try #require(
    JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
  let valid = try #require(fixture["valid"] as? [[String: Any]])
  return try EnrollmentInvitation.decode(JSONSerialization.data(withJSONObject: valid[0]))
}

@Test private func sharedControlJSONRejectsDuplicatesUnicodeAliasesAndInvalidTypes() throws {
  let f = try enrollmentFixture()
  for raw in try #require(f["invalidJSON"] as? [String]) {
    #expect(throws: (any Error).self) { try EnrollmentJSON.parse(Data(raw.utf8)) }
  }
  #expect(throws: (any Error).self) {
    try EnrollmentJSON.parse(Data([123, 34, 97, 34, 58, 34, 255, 34, 125]))
  }
  let valid = try EnrollmentJSON.parse(
    Data(#"{"label":"brace } comma , colon : and emoji \uD83D\uDE00","x":false,"n":0}"#.utf8))
  #expect(valid["label"] == .string("brace } comma , colon : and emoji 😀"))
  #expect(valid["x"] == .boolean(false))
  #expect(valid["n"] == .integer(0))
}
@Test @MainActor private func phoneEnrollmentAcknowledgesOnlyAfterStorageAndHostCompletion()
  async throws
{
  let f = try enrollmentFixture()
  let events = EnrollmentEvents()
  let sink = EnrollmentTestSink(events)
  let io = try EnrollmentFakeIO(
    [object(f, "hello"), object(f, "enrolled"), object(f, "complete")], events: events)
  let client = PhoneEnrollmentClient(
    invitation: try invitation(), io: io, sink: sink, now: { 1000 })
  let metadata = try await client.enroll(phoneID: "phone-a", label: "Controller")
  let stored = await sink.saved?.metadata
  #expect(metadata == stored)
  #expect(events.items == ["connect", "hello", "enroll", "saved", "enrollment-stored"])
  #expect(!io.closed)
  #expect(metadata.epoch == 7)
  #expect(client.diagnosticPhase == .complete)
  #expect(String(describing: try invitation()) == "EnrollmentInvitation([redacted])")
  client.close()
}
@Test @MainActor private func hostNegotiationMismatchNeverSendsPairingProof() async throws {
  let f = try enrollmentFixture()
  for field in [
    "authorityInstanceId", "controlVersion", "inputVersion", "documentVersion",
    "capabilitiesVersion", "inputEnabled", "extra",
  ] {
    var hello = try object(f, "hello")
    hello[field] = field == "authorityInstanceId" ? "wrong" : (field == "controlVersion" ? 1 : 99)
    let events = EnrollmentEvents()
    let sink = EnrollmentTestSink(events)
    let io = try EnrollmentFakeIO([hello], events: events)
    let client = PhoneEnrollmentClient(
      invitation: try invitation(), io: io, sink: sink, now: { 1000 })
    await #expect(throws: PhoneEnrollmentError.self) {
      try await client.enroll(phoneID: "phone-a", label: "Controller")
    }
    #expect(!events.items.contains("enroll"))
    #expect(client.diagnosticPhase == .negotiating)
    #expect(io.closed)
  }
}
@Test @MainActor private func malformedCredentialRepliesCannotReachStorageOrAcknowledgment()
  async throws
{
  let f = try enrollmentFixture()
  for field in ["phoneId", "credentialEpoch", "credential", "expiresAt", "extra"] {
    var reply = try object(f, "enrolled")
    switch field {
    case "phoneId": reply[field] = "other"
    case "credentialEpoch": reply[field] = "07"
    case "credential": reply[field] = String(repeating: "A", count: 64)
    case "expiresAt": reply[field] = 1000
    default: reply[field] = true
    }
    let events = EnrollmentEvents()
    let sink = EnrollmentTestSink(events)
    let io = try EnrollmentFakeIO([object(f, "hello"), reply], events: events)
    let client = PhoneEnrollmentClient(
      invitation: try invitation(), io: io, sink: sink, now: { 1000 })
    await #expect(throws: PhoneEnrollmentError.self) {
      try await client.enroll(phoneID: "phone-a", label: "Controller")
    }
    let saved = await sink.saved?.metadata
    #expect(saved == nil)
    #expect(client.diagnosticPhase == .credential)
    #expect(!events.items.contains("enrollment-stored"))
    #expect(io.closed)
  }
}
@Test @MainActor private func localStorageFailureNeverAcknowledgesEnrollment() async throws {
  let f = try enrollmentFixture()
  let events = EnrollmentEvents()
  let sink = EnrollmentTestSink(events, fail: true)
  let io = try EnrollmentFakeIO([object(f, "hello"), object(f, "enrolled")], events: events)
  let client = PhoneEnrollmentClient(
    invitation: try invitation(), io: io, sink: sink, now: { 1000 })
  await #expect(throws: PhoneEnrollmentError.self) {
    try await client.enroll(phoneID: "phone-a", label: "Controller")
  }
  #expect(!events.items.contains("enrollment-stored"))
  #expect(io.closed)
  #expect(client.diagnosticPhase == .storing)
}
@Test @MainActor private func missingOrMismatchedCompletionPreservesSavedCredentialWithoutSuccess()
  async throws
{
  let f = try enrollmentFixture()
  for missing in [true, false] {
    let events = EnrollmentEvents()
    let sink = EnrollmentTestSink(events)
    var frames = [try object(f, "hello"), try object(f, "enrolled")]
    if !missing {
      var last = try object(f, "complete")
      last["credentialEpoch"] = "8"
      frames.append(last)
    }
    let io = try EnrollmentFakeIO(frames, events: events)
    let client = PhoneEnrollmentClient(
      invitation: try invitation(), io: io, sink: sink, now: { 1000 })
    await #expect(throws: PhoneEnrollmentError.self) {
      try await client.enroll(phoneID: "phone-a", label: "Controller")
    }
    let saved = await sink.saved?.metadata
    #expect(saved?.epoch == 7)
    #expect(client.diagnosticPhase == .confirming)
    #expect(events.items.contains("enrollment-stored"))
    #expect(io.closed)
  }
}
@Test @MainActor private func cancellationWhileNativeStorageIsRunningNeverAcknowledgesOrReplays()
  async throws
{
  let f = try enrollmentFixture()
  let events = EnrollmentEvents()
  let sink = EnrollmentTestSink(events, pause: true)
  let io = try EnrollmentFakeIO([object(f, "hello"), object(f, "enrolled")], events: events)
  let client = PhoneEnrollmentClient(
    invitation: try invitation(), io: io, sink: sink, now: { 1000 })
  let task = Task { try await client.enroll(phoneID: "phone-a", label: "Controller") }
  await sink.waitForStart()
  task.cancel()
  await #expect(throws: PhoneEnrollmentError.self) { try await task.value }
  #expect(!events.items.contains("enrollment-stored"))
  #expect(io.closed)
  let saved = await sink.saved?.metadata
  #expect(saved?.epoch == 7)
}
@Test @MainActor private func expiredInvitationAndClockRollbackCloseBeforeProof() async throws {
  let f = try enrollmentFixture()
  for rollback in [false, true] {
    let events = EnrollmentEvents()
    let sink = EnrollmentTestSink(events)
    let io = try EnrollmentFakeIO([object(f, "hello")], events: events)
    var calls = 0
    let client = PhoneEnrollmentClient(
      invitation: try invitation(), io: io, sink: sink,
      now: {
        calls += 1
        return rollback ? (calls < 3 ? 1000 : 999) : 10_000
      })
    await #expect(throws: PhoneEnrollmentError.self) {
      try await client.enroll(phoneID: "phone-a", label: "Controller")
    }
    #expect(!events.items.contains("enroll"))
    #expect(client.diagnosticPhase == .negotiating)
    #expect(io.closed)
  }
}
#if os(macOS)
  @Test(.enabled(if: ProcessInfo.processInfo.environment["THUMBLE_NATIVE_ENROLLMENT_PROBE"] != nil))
  @MainActor private func actualNativePhoneClientEnrollsThroughPinnedTLSToRustLedger() async throws
  {
    let path = try #require(ProcessInfo.processInfo.environment["THUMBLE_NATIVE_ENROLLMENT_PROBE"])
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: path)
    process.standardOutput = output
    try process.run()
    defer { if process.isRunning { process.terminate() } }
    func line() throws -> [String: Any] {
      var data = Data()
      while data.count < 65_536 {
        let byte = try #require(try output.fileHandleForReading.read(upToCount: 1))
        guard !byte.isEmpty else { throw PhoneEnrollmentError.rejected }
        if byte[0] == 10 {
          return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        data.append(byte)
      }
      throw PhoneEnrollmentError.rejected
    }
    let offer = try line()
    let target = try EnrollmentInvitation(
      host: "127.0.0.1", port: UInt16(try #require(offer["port"] as? Int)),
      certificatePin: try #require(offer["pin"] as? String),
      authorityInstanceID: try #require(offer["authorityInstanceId"] as? String),
      windowID: try #require(offer["windowId"] as? String),
      secret: try #require(offer["secret"] as? String),
      expiresAt: UInt64(try #require(offer["expiresAt"] as? Int)))
    let events = EnrollmentEvents()
    let sink = EnrollmentTestSink(events)
    let client = PhoneEnrollmentClient(
      invitation: target,
      io: try ControlTLSClient(
        host: target.host, port: target.port, certificatePin: target.certificatePin), sink: sink,
      now: { UInt64(Date().timeIntervalSince1970 * 1000) })
    let metadata = try await client.enroll(phoneID: "phone-a", label: "Native controller")
    let saved = await sink.saved?.metadata
    #expect(metadata == saved)
    let result = try line()
    #expect(result["completed"] as? Bool == true)
    #expect(result["inputEnabled"] as? Bool == false)
    client.close()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
  }
#endif

@Test private func nativeInvitationIntakeUsesTheExactBoundedSharedOffer() throws {
  let path = try #require(
    Bundle.module.url(
      forResource: "pairing-invitation-v1", withExtension: "json", subdirectory: "Fixtures"))
  let fixture = try #require(
    JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
  for raw in try #require(fixture["valid"] as? [[String: Any]]) {
    let decoded = try EnrollmentInvitation.decode(JSONSerialization.data(withJSONObject: raw))
    #expect(decoded.host == raw["host"] as? String)
    #expect(decoded.port == (raw["port"] as? NSNumber)?.uint16Value)
    #expect(decoded.certificatePin == raw["certificatePin"] as? String)
    #expect(decoded.authorityInstanceID == raw["authorityInstanceId"] as? String)
    #expect(decoded.windowID == raw["windowId"] as? String)
    #expect(decoded.expiresAt == (raw["expiresAt"] as? NSNumber)?.uint64Value)
    #expect(!String(reflecting: decoded).contains(String(repeating: "4", count: 64)))
    #expect(!String(describing: decoded.customMirror).contains(String(repeating: "4", count: 64)))
  }
  for raw in try #require(fixture["invalidJSON"] as? [String]) {
    #expect(throws: (any Error).self) { try EnrollmentInvitation.decode(Data(raw.utf8)) }
  }
  #expect(throws: (any Error).self) {
    try EnrollmentInvitation.decode(Data(repeating: 32, count: 4097))
  }
  #expect(throws: (any Error).self) {
    try EnrollmentInvitation.decode(Data([123, 34, 97, 34, 58, 34, 255, 34, 125]))
  }
}

@Test @MainActor private func connectionFailureRetainsOnlyItsBoundedEnrollmentPhase() async throws {
  let f = try enrollmentFixture()
  let events = EnrollmentEvents()
  let sink = EnrollmentTestSink(events)
  let io = try EnrollmentFakeIO([object(f, "hello")], events: events)
  io.failConnect = true
  let client = PhoneEnrollmentClient(
    invitation: try invitation(), io: io, sink: sink, now: { 1000 })
  await #expect(throws: PhoneEnrollmentError.self) {
    try await client.enroll(phoneID: "phone-a", label: "Controller")
  }
  #expect(events.items == ["connect", "closed"])
  #expect(client.diagnosticPhase == .connecting)
  #expect(await sink.saved == nil)
}
