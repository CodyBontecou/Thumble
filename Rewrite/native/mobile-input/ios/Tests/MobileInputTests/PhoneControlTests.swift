import Foundation
import Testing

@testable import MobileInputCore

private actor ControlTestStorage: ControlCredentialSource, EnrollmentCredentialSink {
  var credential: PhoneCredential?
  let pause: Bool
  var started = false
  var start: CheckedContinuation<Void, Never>?
  var resume: CheckedContinuation<Void, Never>?
  init(_ credential: PhoneCredential? = nil, pause: Bool = false) {
    self.credential = credential
    self.pause = pause
  }
  func save(_ credential: PhoneCredential) { self.credential = credential }
  func load(hostPin: String, now: UInt64) async -> PhoneCredential? {
    started = true
    start?.resume()
    start = nil
    if pause { await withCheckedContinuation { resume = $0 } }
    return credential
  }
  func waitForLoad() async { if !started { await withCheckedContinuation { start = $0 } } }
  func release() {
    resume?.resume()
    resume = nil
  }
}
@MainActor private final class ControlTestIO: EnrollmentFrameIO {
  var frames: [ControlTLSFrame]
  var sent: [String] = []
  var closed = false
  var pauseNext = false
  var paused = false
  var onPause: CheckedContinuation<Void, Never>?
  var onResume: CheckedContinuation<Void, Never>?
  func waitForPause() async { if !paused { await withCheckedContinuation { onPause = $0 } } }
  func resume() {
    onResume?.resume()
    onResume = nil
  }
  init(_ values: [[String: Any]]) throws {
    frames = try values.map {
      try ControlTLSFrame(kind: .control, payload: JSONSerialization.data(withJSONObject: $0))
    }
  }
  func connect() async throws {}
  func offer(_ frame: ControlTLSFrame) -> Bool {
    guard !closed, let values = try? EnrollmentJSON.parse(frame.payload),
      case .string(let command)? = values["command"]
    else { return false }
    sent.append(command)
    return true
  }
  func receive() async throws -> ControlTLSFrame {
    if pauseNext {
      pauseNext = false
      paused = true
      onPause?.resume()
      onPause = nil
      await withCheckedContinuation { onResume = $0 }
    }
    guard !closed, !frames.isEmpty else { throw PhoneControlError.rejected }
    return frames.removeFirst()
  }
  func close() { closed = true }
}
private func controlFixture() throws -> [String: [String: Any]] {
  let path = try #require(
    Bundle.module.url(
      forResource: "authenticated-control-v3", withExtension: "json", subdirectory: "Fixtures"))
  let f = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
  return try Dictionary(
    uniqueKeysWithValues: ["hello", "authenticated", "status", "disconnected"].map {
      ($0, try #require(f[$0] as? [String: Any]))
    })
}
private func controlEndpoint() throws -> TrustedHostEndpoint {
  try TrustedHostEndpoint(
    host: "127.0.0.1", port: 1234, certificatePin: String(repeating: "1", count: 64),
    authorityInstanceID: "authority-a")
}
private func controlCredential(
  pin: String = String(repeating: "1", count: 64), expires: UInt64 = 100_000
) throws -> PhoneCredential {
  try PhoneCredential(
    hostPin: pin, phoneID: "phone-a", epoch: 1, expiresAt: expires,
    token: Data(repeating: 34, count: 32))
}

@Test @MainActor private func nativeControlLoadsOnlyAfterHelloAndExposesMetadata() async throws {
  let f = try controlFixture()
  let storage = ControlTestStorage(try controlCredential())
  let io = try ControlTestIO([f["hello"]!, f["authenticated"]!, f["status"]!, f["disconnected"]!])
  let client = PhoneControlClient(
    endpoint: try controlEndpoint(), io: io, storage: storage, now: { 1000 })
  await #expect(throws: PhoneControlError.self) { try await client.status() }
  let receipt = try await client.authenticate()
  await #expect(throws: PhoneControlError.self) { try await client.authenticate() }
  #expect(receipt.phoneID == "phone-a")
  #expect(!receipt.inputSessionAvailable)
  #expect(try await client.status() == receipt)
  try await client.disconnect()
  #expect(io.closed)
  #expect(io.sent == ["hello", "authenticate", "control-status", "disconnect"])
  await #expect(throws: PhoneControlError.self) { try await client.authenticate() }
  await #expect(throws: PhoneControlError.self) { try await client.status() }
}
@Test @MainActor private func wrongControlNegotiationNeverReadsVaultOrSendsBearer() async throws {
  let f = try controlFixture()
  for changes: [String: Any] in [
    ["controlVersion": 2], ["authorityInstanceId": "other"], ["inputEnabled": true],
    ["credential": "unexpected"],
  ] {
    let storage = ControlTestStorage(try controlCredential())
    let io = try ControlTestIO([f["hello"]!.merging(changes) { _, new in new }])
    let client = PhoneControlClient(
      endpoint: try controlEndpoint(), io: io, storage: storage, now: { 1000 })
    await #expect(throws: PhoneControlError.self) { try await client.authenticate() }
    #expect(await !storage.started)
    #expect(io.sent == ["hello"])
    #expect(io.closed)
  }
}
@Test @MainActor private func missingExpiredOrForeignVaultCredentialNeverAuthenticates()
  async throws
{
  let f = try controlFixture()
  for credential in [
    nil, try controlCredential(pin: String(repeating: "2", count: 64)),
    try controlCredential(expires: 1000),
  ] {
    let io = try ControlTestIO([f["hello"]!])
    let storage = ControlTestStorage(credential)
    let client = PhoneControlClient(
      endpoint: try controlEndpoint(), io: io, storage: storage, now: { 1000 })
    await #expect(throws: PhoneControlError.self) { try await client.authenticate() }
    #expect(io.sent == ["hello"])
    #expect(io.closed)
  }
}
@Test @MainActor private func malformedAuthenticationCannotAdmitOrChangeConnection() async throws {
  let f = try controlFixture()
  for changes: [String: Any] in [
    ["credentialEpoch": "01"], ["credentialEpoch": "2"], ["phoneId": "other"],
    ["connectionId": String(repeating: "A", count: 32)], ["expiresAt": 1000], ["expiresAt": 100001],
    ["inputSessionAvailable": true], ["inputEnabled": true], ["credential": "leak"],
  ] {
    let io = try ControlTestIO([
      f["hello"]!, f["authenticated"]!.merging(changes) { _, new in new },
    ])
    let client = PhoneControlClient(
      endpoint: try controlEndpoint(), io: io, storage: ControlTestStorage(try controlCredential()),
      now: { 1000 })
    await #expect(throws: PhoneControlError.self) { try await client.authenticate() }
    #expect(io.closed)
  }
  let io = try ControlTestIO([
    f["hello"]!, f["authenticated"]!,
    f["status"]!.merging(["connectionId": String(repeating: "b", count: 32)]) { _, new in new },
  ])
  let client = PhoneControlClient(
    endpoint: try controlEndpoint(), io: io, storage: ControlTestStorage(try controlCredential()),
    now: { 1000 })
  _ = try await client.authenticate()
  await #expect(throws: PhoneControlError.self) { try await client.status() }
  #expect(io.closed)
}
@Test @MainActor private func lateVaultReadCannotAuthenticateAfterCloseOrCancellation() async throws
{
  let f = try controlFixture()
  for cancel in [false, true] {
    let io = try ControlTestIO([f["hello"]!])
    let storage = ControlTestStorage(try controlCredential(), pause: true)
    let client = PhoneControlClient(
      endpoint: try controlEndpoint(), io: io, storage: storage, now: { 1000 })
    let pending = Task { try await client.authenticate() }
    await storage.waitForLoad()
    if cancel { pending.cancel() } else { client.close() }
    await storage.release()
    await #expect(throws: PhoneControlError.self) { try await pending.value }
    #expect(io.sent == ["hello"])
    #expect(io.closed)
  }
}
@Test @MainActor private func localControlExpiryAndRollbackAreTerminalBeforeAnyFurtherSend()
  async throws
{
  let f = try controlFixture()
  for time: UInt64 in [999, 61000] {
    var now: UInt64 = 1000
    let io = try ControlTestIO([f["hello"]!, f["authenticated"]!])
    let client = PhoneControlClient(
      endpoint: try controlEndpoint(), io: io, storage: ControlTestStorage(try controlCredential()),
      now: { now })
    _ = try await client.authenticate()
    now = time
    await #expect(throws: PhoneControlError.self) { try await client.status() }
    #expect(io.sent == ["hello", "authenticate"])
    #expect(io.closed)
  }
}
@Test @MainActor private func concurrentStatusNeverQueuesAndCloseFencesLateReply() async throws {
  let f = try controlFixture()
  for close in [false, true] {
    let io = try ControlTestIO([f["hello"]!, f["authenticated"]!, f["status"]!])
    let client = PhoneControlClient(
      endpoint: try controlEndpoint(), io: io, storage: ControlTestStorage(try controlCredential()),
      now: { 1000 })
    let receipt = try await client.authenticate()
    io.pauseNext = true
    let first = Task { try await client.status() }
    await io.waitForPause()
    await #expect(throws: PhoneControlError.self) { try await client.status() }
    #expect(io.sent == ["hello", "authenticate", "control-status"])
    if close { client.close() }
    io.resume()
    if close {
      await #expect(throws: PhoneControlError.self) { try await first.value }
    } else {
      #expect(try await first.value == receipt)
    }
    client.close()
  }
}
@Test @MainActor private func nativeControlLocalLeaseCannotBeExtendedByLongerHostExpiry()
  async throws
{
  let f = try controlFixture()
  var now: UInt64 = 1000
  let io = try ControlTestIO([
    f["hello"]!, f["authenticated"]!.merging(["expiresAt": 90000]) { _, new in new },
  ])
  let client = PhoneControlClient(
    endpoint: try controlEndpoint(), io: io, storage: ControlTestStorage(try controlCredential()),
    now: { now })
  _ = try await client.authenticate()
  now = 61000
  await #expect(throws: PhoneControlError.self) { try await client.status() }
  #expect(io.sent == ["hello", "authenticate"])
  #expect(io.closed)
}
#if os(macOS)
  @Test(.enabled(if: ProcessInfo.processInfo.environment["THUMBLE_NATIVE_AUTH_PROBE"] != nil))
  @MainActor
  private func actualNativePhoneEnrollsAndAuthenticatesOverPinnedTLSWithoutExportingBearer()
    async throws
  {
    let process = Process()
    let output = Pipe()
    let input = Pipe()
    process.executableURL = URL(
      fileURLWithPath: try #require(
        ProcessInfo.processInfo.environment["THUMBLE_NATIVE_AUTH_PROBE"]))
    process.standardOutput = output
    process.standardInput = input
    try process.run()
    defer { if process.isRunning { process.terminate() } }
    func line() throws -> [String: Any] {
      var data = Data()
      while data.count < 65536 {
        let byte = try #require(try output.fileHandleForReading.read(upToCount: 1))
        guard !byte.isEmpty else { throw PhoneControlError.rejected }
        if byte[0] == 10 {
          return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        data.append(byte)
      }
      throw PhoneControlError.rejected
    }
    let offer = try line()
    let invitation = try EnrollmentInvitation(
      host: "127.0.0.1", port: UInt16(try #require(offer["port"] as? Int)),
      certificatePin: try #require(offer["pin"] as? String),
      authorityInstanceID: try #require(offer["authorityInstanceId"] as? String),
      windowID: try #require(offer["windowId"] as? String),
      secret: try #require(offer["secret"] as? String),
      expiresAt: UInt64(try #require(offer["expiresAt"] as? Int)))
    let storage = ControlTestStorage()
    let enrollment = PhoneEnrollmentClient(
      invitation: invitation,
      io: try ControlTLSClient(
        host: invitation.host, port: invitation.port, certificatePin: invitation.certificatePin),
      sink: storage, now: { UInt64(Date().timeIntervalSince1970 * 1000) })
    let saved = try await enrollment.enroll(phoneID: "phone-a", label: "Native control")
    enrollment.close()
    let endpoint = try TrustedHostEndpoint(
      host: invitation.host, port: invitation.port, certificatePin: invitation.certificatePin,
      authorityInstanceID: invitation.authorityInstanceID)
    let control = PhoneControlClient(
      endpoint: endpoint,
      io: try ControlTLSClient(
        host: endpoint.host, port: endpoint.port, certificatePin: endpoint.certificatePin),
      storage: storage, now: { UInt64(Date().timeIntervalSince1970 * 1000) })
    defer { control.close() }
    let receipt = try await control.authenticate()
    #expect(receipt.phoneID == saved.phoneID)
    #expect(receipt.credentialEpoch == saved.epoch)
    #expect(try await control.status() == receipt)
    try await control.disconnect()
    try input.fileHandleForWriting.write(contentsOf: Data([102]))
    #expect(try line()["completed"] as? Bool == true)
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
  }
#endif
