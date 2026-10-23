import CryptoKit
import Foundation

public enum PhonePresentationError: Error, Equatable {
  case rejected
  case unavailable(String)
}
public struct PhonePresentationRequest: Sendable {
  public let saved: SavedControllerRequest
  public let configurationSha256: String, colorScheme: String
  public let bank: PhonePresentationBank?
  var protocolVersion: UInt64 { bank == nil ? 1 : 2 }
  var controlVersion: UInt64 { bank == nil ? 10 : 11 }
  let controlIDs: Set<String>
  public init(
    saved: SavedControllerRequest, map: SavedControllerMap, colorScheme: String,
    bank: PhonePresentationBank? = nil
  ) throws {
    _ = try map.map.validated()
    guard saved.generation == map.map.generation, saved.revision == map.map.revision,
      SavedControllerWire.hex(map.configurationSha256, count: 64),
      ["light", "dark"].contains(colorScheme)
    else { throw PhonePresentationError.rejected }
    self.saved = saved
    self.configurationSha256 = map.configurationSha256
    self.colorScheme = colorScheme
    self.bank = bank
    controlIDs = Set(map.map.controls.map(\.id))
  }
  private init(base: Self, colorScheme: String, bank: PhonePresentationBank?) {
    saved = base.saved
    configurationSha256 = base.configurationSha256
    controlIDs = base.controlIDs
    self.colorScheme = colorScheme
    self.bank = bank
  }
  public func withColorScheme(_ value: String) throws -> Self {
    guard ["light", "dark"].contains(value) else { throw PhonePresentationError.rejected }
    return Self(base: self, colorScheme: value, bank: bank)
  }
  public func withBank(_ value: PhonePresentationBank) throws -> Self {
    guard bank != nil else { throw PhonePresentationError.rejected }
    return Self(base: self, colorScheme: colorScheme, bank: value)
  }
  var pins: [String: String] {
    var value = [
      "expectedConfigurationRevision": saved.configurationRevision,
      "expectedSourceHash": saved.sourceHash, "profileId": saved.profileID,
      "generation": saved.generation, "revision": saved.revision,
      "viewportWidth": saved.viewportWidth, "viewportHeight": saved.viewportHeight,
      "configurationSha256": configurationSha256, "colorScheme": colorScheme,
    ]
    if let bank { value["bank"] = bank.rawValue }
    return value
  }
  var notificationPins: [String: Any] {
    var value: [String: Any] = pins
    value.removeValue(forKey: "viewportWidth")
    value.removeValue(forKey: "viewportHeight")
    return value
  }
  func notificationPins(authority: String) -> [String: Any] {
    guard bank != nil else { return notificationPins }
    var value: [String: Any] = pins
    value["presentationProtocol"] = 2
    value["authorityInstanceId"] = authority
    return value
  }
  public func bankNotification(authority: String) throws -> [String: Any] {
    guard bank != nil, EnrollmentInvitation.identity(authority) else {
      throw PhonePresentationError.rejected
    }
    var value = notificationPins(authority: authority)
    value["kind"] = "bank"
    return value
  }
  func fields(connection: String) -> [String: Any] {
    var value: [String: Any] = pins
    value["version"] = protocolVersion
    value["command"] = "configuration-presentation"
    value["connectionId"] = connection
    return value
  }
}
public struct PhonePresentationControl: Sendable {
  public let id: String, label: String
  public let iconSHA256: String?, iconByteCount: Int?, iconName: String?
  var bridge: [String: Any] {
    var fields: [String: Any] = ["id": id, "label": label]
    if let iconSHA256, let iconByteCount, let iconName {
      fields["iconSHA256"] = iconSHA256
      fields["iconByteCount"] = iconByteCount
      fields["iconName"] = iconName
    }
    return fields
  }
}
public struct PhonePresentationMetadata: Sendable {
  public let request: PhonePresentationRequest
  public let presentationRevision: String, presentationSourceHash: String
  public let profileName: String, freshness: String
  public let controls: [PhonePresentationControl]
  public let authorityInstanceID: String
  public var bridgeEvent: [String: Any] {
    var fields = request.notificationPins(authority: authorityInstanceID)
    fields["kind"] = "presentation"
    fields["bank"] = request.bank?.rawValue ?? "base"
    fields["profileName"] = profileName
    fields["freshness"] = freshness
    fields["presentationRevision"] = presentationRevision
    fields["presentationSourceHash"] = presentationSourceHash
    fields["controls"] = controls.map(\.bridge)
    return fields
  }
  func iconFields(connection: String, control: PhonePresentationControl) throws -> [String: Any] {
    guard let hash = control.iconSHA256,
      controls.contains(where: { $0.id == control.id && $0.iconSHA256 == hash })
    else { throw PhonePresentationError.rejected }
    var fields = request.fields(connection: connection)
    fields["command"] = "configuration-presentation-icon"
    fields["presentationRevision"] = presentationRevision
    fields["presentationSourceHash"] = presentationSourceHash
    fields["controlId"] = control.id
    fields["iconSHA256"] = hash
    return fields
  }
}
/// An immutable, hash-checked, bounded-decompressed icon. Native caches may reuse it by SHA.
public struct PhonePresentationIcon: Sendable {
  public let sha256: String, byteCount: Int
  private let png: Data
  init(png: Data, expectedHash: String, expectedBytes: Int) throws {
    guard png.count == expectedBytes,
      SHA256.hash(data: png).map({ String(format: "%02x", $0) }).joined() == expectedHash
    else { throw PhonePresentationError.rejected }
    try PhonePresentationPNG.verify(png)
    self.png = png
    sha256 = expectedHash
    byteCount = png.count
  }
  public func notification(metadata: PhonePresentationMetadata, controlId: String) throws
    -> [String: Any]
  {
    guard
      metadata.controls.contains(where: {
        $0.id == controlId && $0.iconSHA256 == sha256 && $0.iconByteCount == byteCount
      })
    else { throw PhonePresentationError.rejected }
    var fields = metadata.request.notificationPins(authority: metadata.authorityInstanceID)
    fields["kind"] = "icon"
    fields["bank"] = metadata.request.bank?.rawValue ?? "base"
    fields["presentationRevision"] = metadata.presentationRevision
    fields["presentationSourceHash"] = metadata.presentationSourceHash
    fields["controlId"] = controlId
    fields["iconSHA256"] = sha256
    fields["pngBase64"] = png.base64EncodedString()
    return fields
  }
}
enum PhonePresentationWire {
  static let errors: Set<String> = [
    "presentation_busy", "presentation_timeout", "presentation_unavailable",
    "presentation_reactivation_required", "presentation_unsupported_profile",
    "presentation_response_too_large", "presentation_stale",
  ]
  static func text(_ fields: [String: EnrollmentJSON.Value], _ key: String) throws -> String {
    guard case .string(let value)? = fields[key] else { throw PhonePresentationError.rejected }
    return value
  }
  static func label(_ value: String) -> Bool { value.utf8.count <= 128 }
  static func header(
    _ fields: [String: EnrollmentJSON.Value], command: String,
    connection: String, authority: String, request: PhonePresentationRequest
  ) throws -> Set<String> {
    let common: Set<String> = ["version", "command", "connectionId", "kind"]
    guard fields.count <= 384, fields["version"] == .integer(request.protocolVersion),
      fields["command"] == .string(command), fields["connectionId"] == .string(connection)
    else { throw PhonePresentationError.rejected }
    if fields["kind"] == .string("error") {
      let error = try text(fields, "error")
      guard Set(fields.keys) == common.union(["error"]), errors.contains(error)
      else { throw PhonePresentationError.rejected }
      throw PhonePresentationError.unavailable(error)
    }
    guard try text(fields, "authorityInstanceId") == authority else {
      throw PhonePresentationError.rejected
    }
    for (key, value) in request.pins {
      guard try text(fields, key) == value else { throw PhonePresentationError.rejected }
    }
    return common.union(request.pins.keys).union(["authorityInstanceId"])
  }
  static func metadata(
    _ fields: [String: EnrollmentJSON.Value], request: PhonePresentationRequest,
    authority: String, connection: String
  ) throws -> PhonePresentationMetadata {
    var keys = try header(
      fields, command: "configuration-presentation-result", connection: connection,
      authority: authority, request: request)
    keys.formUnion([
      "bank", "profileName", "presentationRevision", "presentationSourceHash", "freshness",
      "controlCount",
    ])
    let revision = try text(fields, "presentationRevision")
    let hash = try text(fields, "presentationSourceHash")
    let name = try text(fields, "profileName")
    let freshness = try text(fields, "freshness")
    guard fields["kind"] == .string("presentation"),
      fields["bank"] == .string(request.bank?.rawValue ?? "base"),
      SavedControllerWire.counter(revision), revision != "0",
      let revisionNumber = UInt64(revision),
      let installedNumber = UInt64(request.saved.configurationRevision),
      revisionNumber >= installedNumber,
      SavedControllerWire.hex(hash, count: 64), label(name),
      ["observed", "stale", "not-evaluated"].contains(freshness),
      case .integer(let count)? = fields["controlCount"], (1...64).contains(count)
    else { throw PhonePresentationError.rejected }
    var controls: [PhonePresentationControl] = []
    var ids: Set<String> = []
    for index in 0..<Int(count) {
      let prefix = "control\(index)"
      keys.formUnion([prefix + "Id", prefix + "Label"])
      let id = try text(fields, prefix + "Id")
      let name = try text(fields, prefix + "Label")
      guard EnrollmentInvitation.identity(id), ids.insert(id).inserted, label(name) else {
        throw PhonePresentationError.rejected
      }
      let iconKeys = ["IconSHA256", "IconByteCount", "IconName"].map { prefix + $0 }
      var iconHash: String?
      var iconCount: Int?
      var iconName: String?
      if iconKeys.contains(where: { fields[$0] != nil }) {
        keys.formUnion(iconKeys)
        let hash = try text(fields, iconKeys[0])
        let label = try text(fields, iconKeys[2])
        guard SavedControllerWire.hex(hash, count: 64), self.label(label),
          case .integer(let size)? = fields[iconKeys[1]], (1...8192).contains(size)
        else { throw PhonePresentationError.rejected }
        iconHash = hash
        iconCount = Int(size)
        iconName = label
      }
      controls.append(
        PhonePresentationControl(
          id: id, label: name,
          iconSHA256: iconHash, iconByteCount: iconCount, iconName: iconName))
    }
    guard Set(fields.keys) == keys, ids == request.controlIDs else {
      throw PhonePresentationError.rejected
    }
    return PhonePresentationMetadata(
      request: request, presentationRevision: revision,
      presentationSourceHash: hash, profileName: name, freshness: freshness, controls: controls,
      authorityInstanceID: authority)
  }
  static func icon(
    _ fields: [String: EnrollmentJSON.Value], metadata: PhonePresentationMetadata,
    control: PhonePresentationControl, authority: String, connection: String
  ) throws -> PhonePresentationIcon {
    var keys = try header(
      fields, command: "configuration-presentation-icon-result", connection: connection,
      authority: authority, request: metadata.request)
    keys.formUnion([
      "presentationRevision", "presentationSourceHash", "controlId", "iconSHA256", "byteCount",
      "pngBase64",
    ])
    guard Set(fields.keys) == keys, fields["kind"] == .string("icon"),
      fields["presentationRevision"] == .string(metadata.presentationRevision),
      fields["presentationSourceHash"] == .string(metadata.presentationSourceHash),
      fields["controlId"] == .string(control.id), let hash = control.iconSHA256,
      fields["iconSHA256"] == .string(hash), let count = control.iconByteCount,
      fields["byteCount"] == .integer(UInt64(count))
    else { throw PhonePresentationError.rejected }
    let encoded = try text(fields, "pngBase64")
    guard !encoded.isEmpty, encoded.utf8.count <= 10924, encoded.utf8.count % 4 == 0,
      let data = Data(base64Encoded: encoded), data.count <= 8192,
      data.base64EncodedString() == encoded
    else { throw PhonePresentationError.rejected }
    return try PhonePresentationIcon(png: data, expectedHash: hash, expectedBytes: count)
  }
}
