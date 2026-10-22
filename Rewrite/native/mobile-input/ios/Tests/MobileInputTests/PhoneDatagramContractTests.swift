import Foundation
import Testing

@testable import MobileInputCore

private let binding = String(repeating: "ab", count: 16)
private let session = String(repeating: "33", count: 16)
private func datagramMap() -> ControlMap {
  ControlMap(generation: "1", revision: "1", controls: [])
}
private func datagramFixture(_ name: String) throws -> [String: EnrollmentJSON.Value] {
  let url = try #require(
    Bundle.module.url(
      forResource: "native-input-control-v5", withExtension: "json", subdirectory: "Fixtures"))
  let root = try #require(
    JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
  let value = try #require(root[name] as? [String: Any])
  return try EnrollmentJSON.parse(JSONSerialization.data(withJSONObject: value), allowNull: true)
}
@Test private func datagramGrantRequiresExplicitVersionAndExactBoundPort() throws {
  let fixture = try datagramFixture("grant")
  #expect(throws: PhoneControlError.self) {
    try PhoneInputGrant(fixture, connection: binding, map: datagramMap())
  }
  let grant = try PhoneInputGrant(fixture, connection: binding, map: datagramMap(), datagrams: true)
  #expect(grant.udpPort == 43210 && grant.sessionID == session)
  for replacement in [EnrollmentJSON.Value.integer(0), .integer(65536), .string("43210"), .null] {
    var value = fixture
    value["udpPort"] = replacement
    #expect(throws: PhoneControlError.self) {
      try PhoneInputGrant(value, connection: binding, map: datagramMap(), datagrams: true)
    }
  }
  for field in ["udpPort", "connectionId", "generation", "key"] {
    var value = fixture
    value.removeValue(forKey: field)
    #expect(throws: PhoneControlError.self) {
      try PhoneInputGrant(value, connection: binding, map: datagramMap(), datagrams: true)
    }
  }
}
@Test private func datagramProgressCannotAcknowledgeUnsentOrRegress() throws {
  var value = try datagramFixture("progress")
  #expect(
    try PhoneInputProgress(
      value, connection: binding, session: session, map: datagramMap(), lastOffered: nil,
      previous: nil
    ).lastAccepted == nil)
  value["lastAcceptedSequence"] = .string("7")
  #expect(
    try PhoneInputProgress(
      value, connection: binding, session: session, map: datagramMap(), lastOffered: 8, previous: 6
    ).lastAccepted == 7)
  for (offered, previous) in [(UInt64?(6), UInt64?(6)), (nil, nil), (8, 8)] {
    #expect(throws: PhoneControlError.self) {
      try PhoneInputProgress(
        value, connection: binding, session: session, map: datagramMap(), lastOffered: offered,
        previous: previous)
    }
  }
  for sequence in [EnrollmentJSON.Value.string("07"), .string("1048576"), .integer(7), .null] {
    value["lastAcceptedSequence"] = sequence
    #expect(throws: PhoneControlError.self) {
      try PhoneInputProgress(
        value, connection: binding, session: session, map: datagramMap(), lastOffered: 8,
        previous: 6)
    }
  }
}
@Test private func datagramProgressRejectsWrongScopeAndRetainsTerminalState() throws {
  let fixture = try datagramFixture("progress")
  for (field, replacement) in [
    ("connectionId", EnrollmentJSON.Value.string(String(repeating: "cd", count: 16))),
    ("sessionId", .string(String(repeating: "44", count: 16))),
    ("generation", .string("2")), ("revision", .string("2")),
    ("inputEnabled", .boolean(true)), ("extra", .boolean(false)),
  ] {
    var value = fixture
    value[field] = replacement
    #expect(throws: PhoneControlError.self) {
      try PhoneInputProgress(
        value, connection: binding, session: session, map: datagramMap(), lastOffered: nil,
        previous: nil)
    }
  }
  var closed = fixture
  closed["active"] = .boolean(false)
  #expect(
    try !PhoneInputProgress(
      closed, connection: binding, session: session, map: datagramMap(), lastOffered: nil,
      previous: nil
    ).active)
}
@Test private func nullProgressRequiresExplicitParserOptInAndStillRejectsDuplicates() throws {
  #expect(throws: (any Error).self) { try EnrollmentJSON.parse(Data("{\"value\":null}".utf8)) }
  #expect(
    try EnrollmentJSON.parse(Data("{\"value\":null}".utf8), allowNull: true)["value"] == .null)
  #expect(throws: (any Error).self) {
    try EnrollmentJSON.parse(Data("{\"value\":null,\"value\":null}".utf8), allowNull: true)
  }
}
