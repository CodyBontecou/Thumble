import Foundation
import Testing

@testable import MobileInputCore

private actor CatalogStorage: ControlCredentialSource {
  var calls = 0
  let credential: PhoneCredential?
  init(_ credential: PhoneCredential?) { self.credential = credential }
  func load(hostPin: String, now: UInt64) -> PhoneCredential? {
    calls += 1
    return credential
  }
}
@MainActor private final class CatalogIO: EnrollmentFrameIO {
  var frames: [ControlTLSFrame]
  var sent: [[String: EnrollmentJSON.Value]] = []
  var closed = false
  var pauseConnect = false
  var enteredConnect = false
  init(_ fields: [[String: Any]]) throws {
    frames = try fields.map {
      try ControlTLSFrame(kind: .control, payload: JSONSerialization.data(withJSONObject: $0))
    }
  }
  func connect() async throws {
    enteredConnect = true
    if pauseConnect { try await Task.sleep(for: .seconds(10)) }
  }
  func offer(_ frame: ControlTLSFrame) -> Bool {
    guard !closed, let fields = try? EnrollmentJSON.parse(frame.payload, allowNull: true) else {
      return false
    }
    sent.append(fields)
    return true
  }
  func receive() async throws -> ControlTLSFrame {
    guard !closed, !frames.isEmpty else { throw PhoneCatalogError.rejected }
    return frames.removeFirst()
  }
  func close() { closed = true }
}
private let catalogConnection = String(repeating: "a", count: 32)
private func catalogFields() -> [String: Any] {
  [
    "version": 1, "command": "configuration-result", "connectionId": catalogConnection,
    "kind": "catalog", "revision": "1", "contentHash": String(repeating: "b", count: 64),
    "activeProfileId": NSNull(), "defaultProfileId": NSNull(), "nextOffset": NSNull(),
    "profileCount": 1, "profile0Id": "00000000-0000-0000-0000-000000000001",
    "profile0Name": "Synthetic 😀", "profile0UpdatedAt": "9223372036854775807",
  ]
}
@MainActor private func catalogSetup(
  _ result: [String: Any] = catalogFields(), input: Bool = false, role: String = "management"
) throws -> (PhoneCatalogClient, CatalogIO, CatalogStorage) {
  let endpoint = try TrustedHostEndpoint(
    host: "127.0.0.1", port: 1234, certificatePin: String(repeating: "1", count: 64),
    authorityInstanceID: "authority-a")
  let credential = try PhoneCredential(
    hostPin: endpoint.certificatePin, phoneID: "phone-a", epoch: 1, expiresAt: 100000,
    token: Data(repeating: 34, count: 32))
  let hello: [String: Any] = [
    "version": 1, "command": "hello", "authorityInstanceId": "authority-a", "controlVersion": 7,
    "role": role, "inputVersion": 1, "documentVersion": 1, "capabilitiesVersion": 1,
    "inputEnabled": false,
  ]
  let admission: [String: Any] = [
    "version": 1, "command": "authenticated", "authorityInstanceId": "authority-a",
    "phoneId": "phone-a", "credentialEpoch": "1", "connectionId": catalogConnection,
    "expiresAt": 60100, "role": "management", "inputSessionAvailable": input, "inputEnabled": false,
  ]
  let io = try CatalogIO([hello, admission, result])
  let storage = CatalogStorage(credential)
  return (
    PhoneCatalogClient(endpoint: endpoint, io: io, storage: storage, now: { 100 }), io, storage
  )
}
@Test @MainActor func catalogReadUsesDedicatedManagementAndOnlyPublicMetadataLeavesClient()
  async throws
{
  let (client, io, storage) = try catalogSetup()
  let result = try await client.read()
  guard case .catalog(let page) = result else {
    Issue.record("catalog missing")
    return
  }
  #expect(page.profiles.count == 1)
  #expect(page.profiles[0].name == "Synthetic 😀")
  #expect(
    io.sent.compactMap { $0["command"] } == [
      .string("hello"), .string("authenticate"), .string("configuration-list"),
    ])
  #expect(io.sent[0]["role"] == .string("management"))
  #expect(io.sent[2]["expectedRevision"] == .null)
  #expect(await storage.calls == 1)
  #expect(io.closed)
  let value = result.bridgeMetadata
  #expect(value["connectionId"] == nil && value["credential"] == nil && value["host"] == nil)
  #expect(JSONSerialization.isValidJSONObject(value))
  await #expect(throws: (any Error).self) { try await client.read() }
}
@Test @MainActor func catalogRejectsInputRoleDowngradeMalformedPagesAndUnboundResults() async throws
{
  for badRole in ["input", ""] {
    let (client, io, storage) = try catalogSetup(role: badRole)
    await #expect(throws: (any Error).self) { try await client.read() }
    #expect(await storage.calls == 0)
    #expect(io.closed)
  }
  let (inputClient, inputIO, _) = try catalogSetup(input: true)
  await #expect(throws: (any Error).self) { try await inputClient.read() }
  #expect(inputIO.sent.count == 2)
  for patch in [
    ["connectionId": String(repeating: "c", count: 32)], ["revision": "01"], ["profileCount": 17],
    ["profile0Id": "not-an-id"], ["profile0UpdatedAt": "9223372036854775808"], ["nextOffset": 1],
    ["profile0Name": String(repeating: "😀", count: 257)], ["credential": "must-not-bridge"],
  ] as [[String: Any]] {
    var fields = catalogFields()
    fields.merge(patch) { _, value in value }
    let (client, io, _) = try catalogSetup(fields)
    await #expect(throws: (any Error).self) { try await client.read() }
    #expect(io.closed)
  }
}
@Test @MainActor func catalogConflictErrorsAndUInt64RevisionRemainExplicit() throws {
  var fields = catalogFields()
  fields["revision"] = "18446744073709551615"
  let parsed = try EnrollmentJSON.parse(
    JSONSerialization.data(withJSONObject: fields), allowNull: true)
  guard
    case .catalog(let page) = try PhoneCatalogClient.decode(
      parsed, connection: catalogConnection, expected: "18446744073709551615", offset: 0)
  else {
    Issue.record("catalog missing")
    return
  }
  #expect(page.revision == "18446744073709551615")
  let conflict: [String: EnrollmentJSON.Value] = [
    "version": .integer(1), "command": .string("configuration-result"),
    "connectionId": .string(catalogConnection), "kind": .string("conflict"),
    "currentRevision": .string("2"),
  ]
  #expect(
    try PhoneCatalogClient.decode(
      conflict, connection: catalogConnection, expected: "1", offset: 16) == .conflict("2"))
  #expect(throws: (any Error).self) {
    try PhoneCatalogClient.decode(conflict, connection: catalogConnection, expected: nil, offset: 0)
  }
  for error in ["phone_catalog_busy", "phone_catalog_timeout", "phone_catalog_unavailable"] {
    let result: [String: EnrollmentJSON.Value] = [
      "version": .integer(1), "command": .string("configuration-result"),
      "connectionId": .string(catalogConnection), "kind": .string("error"), "error": .string(error),
    ]
    #expect(
      try PhoneCatalogClient.decode(result, connection: catalogConnection, expected: nil, offset: 0)
        == .unavailable(error))
  }
}

@Test @MainActor func catalogPaginationAndWhitespaceMatchSavedCatalogContract() throws {
  var fields = catalogFields()
  fields["profileCount"] = 16
  fields["nextOffset"] = 16
  for index in 0..<16 {
    fields["profile\(index)Id"] = String(format: "00000000-0000-0000-0000-%012d", index + 1)
    fields["profile\(index)Name"] = index == 0 ? "\u{0085}" : String(repeating: "😀", count: 256)
    fields["profile\(index)UpdatedAt"] = "0"
  }
  func decode(_ fields: [String: Any]) throws -> PhoneCatalogResult {
    try PhoneCatalogClient.decode(
      EnrollmentJSON.parse(JSONSerialization.data(withJSONObject: fields), allowNull: true),
      connection: catalogConnection, expected: nil, offset: 0)
  }
  guard case .catalog(let page) = try decode(fields) else {
    Issue.record("page missing")
    return
  }
  #expect(page.nextOffset == 16 && page.profiles.count == 16)
  #expect(page.profiles[0].name == "\u{0085}")
  for patch: [String: Any] in [
    ["profile0Name": "\u{FEFF}\u{2000}\n"],
    ["profile1Id": fields["profile0Id"]!], ["nextOffset": 32],
  ] {
    var bad = fields
    bad.merge(patch) { _, value in value }
    #expect(throws: (any Error).self) { try decode(bad) }
  }
}

@Test @MainActor func catalogCancellationDuringConnectNeverLoadsCredentialOrAffectsInput()
  async throws
{
  let (client, io, storage) = try catalogSetup()
  io.pauseConnect = true
  let task = Task { try await client.read() }
  while !io.enteredConnect { await Task.yield() }
  task.cancel()
  await #expect(throws: (any Error).self) { try await task.value }
  #expect(io.closed)
  #expect(io.sent.isEmpty)
  #expect(await storage.calls == 0)
}
