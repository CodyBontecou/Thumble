import Foundation

public enum PhoneCatalogError: Error { case rejected }
/// Saved metadata only. No source document, endpoint or credential is representable.
public struct PhoneCatalogProfile: Sendable, Equatable {
  public let id: String, name: String, updatedAt: String
}
public struct PhoneCatalogPage: Sendable, Equatable {
  public let revision: String
  public let contentHash: String?, activeProfileID: String?, defaultProfileID: String?
  public let nextOffset: Int?
  public let profiles: [PhoneCatalogProfile]
}
public enum PhoneCatalogResult: Sendable, Equatable {
  case catalog(PhoneCatalogPage)
  case conflict(String)
  case unavailable(String)
  /// Deliberately copies only the flat, public catalog protocol fields.
  public var bridgeMetadata: [String: Any] {
    switch self {
    case .unavailable(let error): return ["kind": "error", "error": error]
    case .conflict(let revision): return ["kind": "conflict", "currentRevision": revision]
    case .catalog(let page):
      var fields: [String: Any] = [
        "kind": "catalog", "revision": page.revision,
        "contentHash": page.contentHash as Any? ?? NSNull(),
        "activeProfileId": page.activeProfileID as Any? ?? NSNull(),
        "defaultProfileId": page.defaultProfileID as Any? ?? NSNull(),
        "nextOffset": page.nextOffset as Any? ?? NSNull(), "profileCount": page.profiles.count,
      ]
      for (index, profile) in page.profiles.enumerated() {
        fields["profile\(index)Id"] = profile.id
        fields["profile\(index)Name"] = profile.name
        fields["profile\(index)UpdatedAt"] = profile.updatedAt
      }
      return fields
    }
  }
}
/// Host and phone wall clocks need not agree. The host enforces its receipt expiry;
/// the phone independently caps this one-shot read to sixty local seconds.
enum ManagementReadDeadline {
  static func admitted(hostExpiry: UInt64, credentialExpiry: UInt64, now: UInt64) -> UInt64? {
    guard hostExpiry > now, hostExpiry <= credentialExpiry,
      now <= UInt64(Int64.max) - 60000
    else { return nil }
    return min(hostExpiry, now + 60000)
  }
}
/// A one-page, dedicated MANAGEMENT connection. It cannot create or access input sessions.
@MainActor public final class PhoneCatalogClient {
  private let endpoint: TrustedHostEndpoint
  private let io: any EnrollmentFrameIO
  private let storage: any ControlCredentialSource
  private let now: () -> UInt64
  private var started = false, closed = false
  private var last: UInt64 = 0
  private var expires: UInt64?
  public convenience init(endpoint: TrustedHostEndpoint, storage: PhoneCredentialWorker) throws {
    try self.init(
      endpoint: endpoint,
      io: ControlTLSClient(
        host: endpoint.host, port: endpoint.port, certificatePin: endpoint.certificatePin),
      storage: storage,
      now: {
        let value = Date().timeIntervalSince1970 * 1000
        return value.isFinite && value >= 0 && value < Double(Int64.max)
          ? UInt64(value) : UInt64.max
      })
  }
  init(
    endpoint: TrustedHostEndpoint, io: any EnrollmentFrameIO, storage: any ControlCredentialSource,
    now: @escaping () -> UInt64
  ) {
    self.endpoint = endpoint
    self.io = io
    self.storage = storage
    self.now = now
  }
  @discardableResult private func checkpoint() throws -> UInt64 {
    try Task.checkCancellation()
    let time = now()
    guard !closed, time >= last, time <= UInt64(Int64.max), expires.map({ time < $0 }) ?? true
    else { throw PhoneCatalogError.rejected }
    last = time
    return time
  }
  private func send(_ value: [String: Any]) throws {
    try checkpoint()
    guard
      io.offer(
        try ControlTLSFrame(kind: .control, payload: JSONSerialization.data(withJSONObject: value)))
    else { throw PhoneCatalogError.rejected }
  }
  private func receive() async throws -> [String: EnrollmentJSON.Value] {
    let frame = try await io.receive()
    try checkpoint()
    guard frame.kind == .control, frame.payload.count <= 32768 else {
      throw PhoneCatalogError.rejected
    }
    return try EnrollmentJSON.parse(frame.payload, allowNull: true)
  }
  public func read(expectedRevision: String? = nil, offset: Int = 0) async throws
    -> PhoneCatalogResult
  {
    guard !started, (0...255).contains(offset), expectedRevision.map(Self.counter) ?? (offset == 0)
    else { throw PhoneCatalogError.rejected }
    started = true
    defer { close() }
    return try await withTaskCancellationHandler {
      try checkpoint()
      try await io.connect()
      try checkpoint()
      let hello: [String: Any] = [
        "version": 1, "command": "hello", "controlVersion": 7, "role": "management",
        "inputVersion": 1, "documentVersion": 1, "capabilitiesVersion": 1,
      ]
      try send(hello)
      let reply = try await receive()
      guard
        reply == [
          "version": .integer(1), "command": .string("hello"),
          "authorityInstanceId": .string(endpoint.authorityInstanceID),
          "controlVersion": .integer(7), "role": .string("management"), "inputVersion": .integer(1),
          "documentVersion": .integer(1), "capabilitiesVersion": .integer(1),
          "inputEnabled": .boolean(false),
        ]
      else { throw PhoneCatalogError.rejected }
      let credential = try await storage.load(hostPin: endpoint.certificatePin, now: checkpoint())
      try checkpoint()
      guard let credential, credential.metadata.hostPin == endpoint.certificatePin,
        last < credential.metadata.expiresAt,
        io.offer(try credential.authenticationFrame(authority: endpoint.authorityInstanceID))
      else { throw PhoneCatalogError.rejected }
      let admission = try await receive()
      guard
        Set(admission.keys)
          == Set([
            "version", "command", "authorityInstanceId", "phoneId", "credentialEpoch",
            "connectionId", "expiresAt", "inputSessionAvailable", "inputEnabled", "role",
          ]), admission["version"] == .integer(1), admission["command"] == .string("authenticated"),
        admission["authorityInstanceId"] == .string(endpoint.authorityInstanceID),
        admission["phoneId"] == .string(credential.metadata.phoneID),
        admission["credentialEpoch"] == .string(String(credential.metadata.epoch)),
        admission["inputSessionAvailable"] == .boolean(false),
        admission["inputEnabled"] == .boolean(false), admission["role"] == .string("management"),
        case .string(let connection)? = admission["connectionId"], Self.hex(connection, count: 32),
        case .integer(let end)? = admission["expiresAt"], end > last,
        let localDeadline = ManagementReadDeadline.admitted(
          hostExpiry: end, credentialExpiry: credential.metadata.expiresAt, now: last)
      else { throw PhoneCatalogError.rejected }
      expires = localDeadline
      try send([
        "version": 1, "command": "configuration-list", "connectionId": connection,
        "expectedRevision": expectedRevision as Any? ?? NSNull(), "offset": offset,
      ])
      return try Self.decode(
        try await receive(), connection: connection, expected: expectedRevision, offset: offset)
    } onCancel: {
      Task { @MainActor [weak self] in self?.close() }
    }
  }
  public func close() {
    if !closed {
      closed = true
      io.close()
    }
  }
  private static func jsWhitespace(_ scalar: UInt32) -> Bool {
    switch scalar {
    case 0x9...0xD, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000,
      0xFEFF:
      return true
    default: return false
    }
  }
  static func counter(_ value: String) -> Bool {
    UInt64(value).map { String($0) == value } ?? false
  }
  static func hex(_ value: String, count: Int) -> Bool {
    value.utf8.count == count
      && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
  static func profileID(_ value: String) -> Bool {
    value.utf8.count == 36 && UUID(uuidString: value) != nil && value.lowercased() == value
  }
  static func decode(
    _ fields: [String: EnrollmentJSON.Value], connection: String, expected: String?, offset: Int
  ) throws -> PhoneCatalogResult {
    func text(_ key: String) throws -> String {
      guard case .string(let value)? = fields[key] else { throw PhoneCatalogError.rejected }
      return value
    }
    let envelope: Set<String> = ["version", "command", "connectionId", "kind"]
    guard fields["version"] == .integer(1), fields["command"] == .string("configuration-result"),
      fields["connectionId"] == .string(connection)
    else { throw PhoneCatalogError.rejected }
    switch try text("kind") {
    case "error":
      let error = try text("error")
      guard Set(fields.keys) == envelope.union(["error"]),
        ["phone_catalog_busy", "phone_catalog_timeout", "phone_catalog_unavailable"].contains(error)
      else { throw PhoneCatalogError.rejected }
      return .unavailable(error)
    case "conflict":
      let revision = try text("currentRevision")
      guard Set(fields.keys) == envelope.union(["currentRevision"]), let expected,
        counter(revision), expected != revision
      else { throw PhoneCatalogError.rejected }
      return .conflict(revision)
    case "catalog":
      let revision = try text("revision")
      guard counter(revision), expected.map({ $0 == revision }) ?? true,
        case .integer(let count)? = fields["profileCount"], count <= 16
      else { throw PhoneCatalogError.rejected }
      var keys = envelope.union([
        "revision", "contentHash", "activeProfileId", "defaultProfileId", "nextOffset",
        "profileCount",
      ])
      var profiles: [PhoneCatalogProfile] = []
      for index in 0..<Int(count) {
        let prefix = "profile\(index)"
        keys.formUnion([prefix + "Id", prefix + "Name", prefix + "UpdatedAt"])
        let id = try text(prefix + "Id")
        let name = try text(prefix + "Name")
        let updated = try text(prefix + "UpdatedAt")
        guard profileID(id), name.unicodeScalars.contains(where: { !Self.jsWhitespace($0.value) }),
          name.unicodeScalars.count <= 256, counter(updated), UInt64(updated)! <= UInt64(Int64.max),
          !profiles.contains(where: { $0.id == id })
        else { throw PhoneCatalogError.rejected }
        profiles.append(PhoneCatalogProfile(id: id, name: name, updatedAt: updated))
      }
      func nullable(_ key: String, valid: (String) -> Bool) throws -> String? {
        if fields[key] == .null { return nil }
        let value = try text(key)
        guard valid(value) else { throw PhoneCatalogError.rejected }
        return value
      }
      let hash = try nullable("contentHash", valid: { hex($0, count: 64) })
      let active = try nullable("activeProfileId", valid: profileID)
      let standard = try nullable("defaultProfileId", valid: profileID)
      let next: Int?
      if fields["nextOffset"] == .null {
        next = nil
      } else {
        guard case .integer(let value)? = fields["nextOffset"], value <= 255, count == 16,
          value == offset + Int(count)
        else { throw PhoneCatalogError.rejected }
        next = Int(value)
      }
      guard Set(fields.keys) == keys,
        revision == "0"
          ? (hash == nil && profiles.isEmpty && active == nil && standard == nil && next == nil)
          : hash != nil
      else { throw PhoneCatalogError.rejected }
      return .catalog(
        PhoneCatalogPage(
          revision: revision, contentHash: hash, activeProfileID: active,
          defaultProfileID: standard, nextOffset: next, profiles: profiles))
    default: throw PhoneCatalogError.rejected
    }
  }
}
