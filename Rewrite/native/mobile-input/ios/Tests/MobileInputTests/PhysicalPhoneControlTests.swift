import Foundation
import Testing

@testable import MobileInputCore

private actor PhysicalCredentialSource: ControlCredentialSource {
  var loads = 0
  func load(hostPin: String, now: UInt64) throws -> PhoneCredential? {
    loads += 1
    return try PhoneCredential(
      hostPin: hostPin, phoneID: "phone-a", epoch: 1, expiresAt: 100_000,
      token: Data(repeating: 34, count: 32))
  }
}
@MainActor private final class PhysicalFrameIO: EnrollmentFrameIO {
  var replies: [[String: Any]]
  var sent: [ControlTLSFrame] = []
  var closed = false
  init(_ replies: [[String: Any]]) { self.replies = replies }
  func connect() async throws {}
  func offer(_ frame: ControlTLSFrame) -> Bool {
    guard !closed else { return false }
    sent.append(frame)
    return true
  }
  func receive() async throws -> ControlTLSFrame {
    guard !closed, !replies.isEmpty else { throw PhoneControlError.rejected }
    return try ControlTLSFrame(
      kind: .control, payload: JSONSerialization.data(withJSONObject: replies.removeFirst()))
  }
  func close() { closed = true }
}
private func physicalFixture() throws -> [String: [String: Any]] {
  let path = try #require(
    Bundle.module.url(
      forResource: "physical-input-control-v9", withExtension: "json", subdirectory: "Fixtures"))
  let values = try #require(
    JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
  return values.compactMapValues { $0 as? [String: Any] }
}
private func physicalValues(_ value: [String: Any]) throws -> [String: EnrollmentJSON.Value] {
  try EnrollmentJSON.parse(JSONSerialization.data(withJSONObject: value), allowNull: true)
}
private func physicalMap() -> ControlMap {
  ControlMap(
    generation: "1", revision: "1",
    controls: [ControlRegion(id: "south", action: "south", x: 0, y: 0, width: 1, height: 1)])
}
@MainActor private func physicalClient(
  _ io: PhysicalFrameIO, _ storage: PhysicalCredentialSource, mode: PhoneOutputMode = .macosHID
) throws -> PhoneControlClient {
  PhoneControlClient(
    endpoint: try TrustedHostEndpoint(
      host: "127.0.0.1", port: 1234, certificatePin: String(repeating: "1", count: 64),
      authorityInstanceID: "authority-a"), io: io, storage: storage, now: { 1000 },
    controlVersion: 9, outputMode: mode,
    datagramFactory: { _, _ in throw PhoneControlError.rejected })
}
@Test @MainActor private func explicitPhysicalV9AuthenticatesAndBindsWithoutCreatingAnOSDevice()
  async throws
{
  let f = try physicalFixture()
  let storage = PhysicalCredentialSource()
  let io = PhysicalFrameIO([
    f["hello"]!, f["authenticated"]!, f["configuration"]!, f["configuration"]!, f["grant"]!,
  ])
  let client = try physicalClient(io, storage)
  defer { client.close() }
  let metadata = try await client.authenticate()
  #expect(metadata.outputMode == .macosHID && metadata.inputEnabled)
  let configuration = try await client.inputConfiguration()
  #expect(
    configuration.active && configuration.inputEnabled && configuration.outputMode == .macosHID)
  let engine = try await client.bindInput(physicalMap())
  #expect(engine.connected)
  #expect(engine.begin(id: 1, generation: "1", x: 0.2, y: 0.2))
  #expect(io.sent.filter { $0.kind == .input }.count == 2)
  #expect(try EnrollmentJSON.parse(io.sent[0].payload) == physicalValues(f["request"]!))
  client.close()
  #expect(!engine.connected && io.closed)
}
@Test @MainActor
private func physicalV9RejectsImplicitIntentAndRecordingFallbackBeforeReadingCredential()
  async throws
{
  let f = try physicalFixture()
  for mode in [PhoneOutputMode.recording, .macosHID] {
    var hello = f["hello"]!
    hello["controlVersion"] = 6
    let io = PhysicalFrameIO([hello])
    let storage = PhysicalCredentialSource()
    let client = try physicalClient(io, storage, mode: mode)
    await #expect(throws: PhoneControlError.self) { try await client.authenticate() }
    #expect(await storage.loads == 0)
    #expect(
      !io.sent.contains {
        (try? EnrollmentJSON.parse($0.payload)["command"]) == .string("authenticate")
      })
  }
}
@Test @MainActor private func physicalDTOsRequireExactBackendAdmissionAndKeepRecordingFalseGuards()
  throws
{
  let f = try physicalFixture()
  let connection = String(repeating: "ab", count: 16)
  let map = physicalMap()
  _ = try PhoneInputGrant(
    physicalValues(f["grant"]!), connection: connection, map: map, datagrams: true,
    outputMode: .macosHID)
  _ = try PhoneInputProgress(
    physicalValues(f["progress"]!), connection: connection,
    session: String(repeating: "33", count: 16), map: map, lastOffered: 0, previous: nil,
    outputMode: .macosHID)
  _ = try PhoneInputRenewal(
    physicalValues(f["renewal"]!), connection: connection, map: map,
    scope: PhoneInputRenewalScope(
      sessionID: String(repeating: "33", count: 16), udpPort: 43210, authorizationExpiresAt: 2000,
      credentialExpiresAt: 100000), now: 1000, outputMode: .macosHID)
  for patch: [String: Any] in [
    ["inputEnabled": false], ["outputBackend": "recording"], ["generation": "2"], ["extra": true],
  ] {
    var grant = f["grant"]!
    grant.merge(patch) { _, next in next }
    #expect(throws: PhoneControlError.self) {
      try PhoneInputGrant(
        physicalValues(grant), connection: connection, map: map, datagrams: true,
        outputMode: .macosHID)
    }
  }
  #expect(throws: PhoneControlError.self) {
    try PhoneInputGrant(
      physicalValues(f["grant"]!), connection: connection, map: map, datagrams: true)
  }
  #expect(throws: PhoneControlError.self) {
    try PhoneInputConfiguration(physicalValues(f["configuration"]!), connection: connection)
  }
  var inactive = f["configuration"]!
  inactive["active"] = false
  inactive["inputEnabled"] = false
  #expect(
    try !PhoneInputConfiguration(
      physicalValues(inactive), connection: connection, outputMode: .macosHID
    ).inputEnabled)
}
