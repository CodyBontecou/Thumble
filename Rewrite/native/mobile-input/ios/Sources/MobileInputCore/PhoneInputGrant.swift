import Foundation

/// Native-only strict grant decoder. No Codable, secret accessors or bridge representation.
struct PhoneInputGrant {
  let packet: InputPacketGrant
  let lifetime: UInt64
  let sessionID: String
  let udpPort: UInt16?
  static func configuration(
    _ value: [String: EnrollmentJSON.Value], connection: String, map: ControlMap
  ) throws {
    guard
      value == [
        "version": .integer(1), "command": .string("input-configuration"),
        "connectionId": .string(connection), "active": .boolean(true),
        "generation": .string(map.generation), "revision": .string(map.revision),
        "inputEnabled": .boolean(false),
      ]
    else { throw PhoneControlError.rejected }
  }
  init(
    _ value: [String: EnrollmentJSON.Value], connection: String, map: ControlMap,
    datagrams: Bool = false
  ) throws {
    let fields = Set([
      "version", "command", "connectionId", "generation", "revision",
      "sessionId", "key", "noncePrefix", "lifetimeMs", "packetVersion", "packetBytes",
      "packetLimit", "transport", "inputEnabled",
    ])
    guard
      Set(value.keys) == (datagrams ? fields.union(["udpPort"]) : fields),
      value["version"] == .integer(1), value["command"] == .string("input-granted"),
      value["connectionId"] == .string(connection), value["generation"] == .string(map.generation),
      value["revision"] == .string(map.revision), value["packetVersion"] == .integer(1),
      value["packetBytes"] == .integer(108), value["packetLimit"] == .string("1048576"),
      value["transport"] == .string(datagrams ? "udp+tls" : "tls"),
      value["inputEnabled"] == .boolean(false),
      case .integer(let duration)? = value["lifetimeMs"], (100...60_000).contains(duration),
      let generation = ControlMap.counter(map.generation), generation > 0
    else { throw PhoneControlError.rejected }
    packet = try InputPacketGrant(
      key: Self.hex(value["key"], bytes: 32),
      session: Self.hex(value["sessionId"], bytes: 16),
      noncePrefix: Self.hex(value["noncePrefix"], bytes: 4), generation: generation)
    lifetime = UInt64(duration)
    guard case .string(let session)? = value["sessionId"] else { throw PhoneControlError.rejected }
    sessionID = session
    if datagrams {
      guard case .integer(let port)? = value["udpPort"], (1...65_535).contains(port) else {
        throw PhoneControlError.rejected
      }
      udpPort = UInt16(port)
    } else {
      udpPort = nil
    }
  }
  private static func hex(_ value: EnrollmentJSON.Value?, bytes: Int) throws -> Data {
    guard case .string(let text)? = value, text.utf8.count == bytes * 2,
      text.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else { throw PhoneControlError.rejected }
    let chars = Array(text.utf8)
    func digit(_ c: UInt8) -> UInt8 { c <= 57 ? c - 48 : c - 87 }
    return Data(
      stride(from: 0, to: chars.count, by: 2).map { digit(chars[$0]) * 16 + digit(chars[$0 + 1]) })
  }
}
