import Foundation

public enum SavedControllerError: Error, Equatable {
  case rejected
  case unavailable(String)
}
/// Public read pin only. It neither owns input nor creates an activation epoch.
public struct SavedControllerRequest: Sendable {
  public let configurationRevision: String, sourceHash: String, profileID: String
  public let generation: String, revision: String, viewportWidth: String, viewportHeight: String
  public init(
    configurationRevision: String, sourceHash: String, profileID: String,
    generation: String, revision: String, viewportWidth: String, viewportHeight: String
  ) throws {
    guard SavedControllerWire.counter(configurationRevision), configurationRevision != "0",
      SavedControllerWire.hex(sourceHash, count: 64), SavedControllerWire.profileID(profileID),
      SavedControllerWire.counter(generation), generation != "0",
      SavedControllerWire.counter(revision),
      let width = SavedControllerWire.number(viewportWidth),
      let height = SavedControllerWire.number(viewportHeight), height >= 240, width >= height,
      width <= 4096, height <= 4096
    else { throw SavedControllerError.rejected }
    self.configurationRevision = configurationRevision
    self.sourceHash = sourceHash
    self.profileID = profileID
    self.generation = generation
    self.revision = revision
    self.viewportWidth = viewportWidth
    self.viewportHeight = viewportHeight
  }
  public init(
    catalog: PhoneCatalogPage, configuration: PhoneInputConfiguration,
    width: Double, height: Double
  ) throws {
    guard configuration.active, let sourceHash = catalog.contentHash,
      let profileID = catalog.activeProfileID
    else { throw SavedControllerError.rejected }
    try self.init(
      configurationRevision: catalog.revision, sourceHash: sourceHash, profileID: profileID,
      generation: configuration.generation, revision: configuration.revision,
      viewportWidth: String(width), viewportHeight: String(height))
  }
  func fields(connection: String) -> [String: Any] {
    [
      "version": 1, "command": "configuration-controls", "connectionId": connection,
      "expectedConfigurationRevision": configurationRevision, "expectedSourceHash": sourceHash,
      "profileId": profileID, "generation": generation, "revision": revision,
      "viewportWidth": viewportWidth, "viewportHeight": viewportHeight,
    ]
  }
}
public struct SavedControllerMap: Sendable {
  public let map: ControlMap
  public let configurationSha256: String
  /// Presentation metadata emitted only after this map's native engine installs.
  public var bridgeMap: [String: Any] {
    let controls: [[String: Any]] = map.controls.map { control in
      var fields: [String: Any] = [
        "id": control.id, "action": control.action, "x": control.x, "y": control.y,
        "width": control.width, "height": control.height,
      ]
      if let feedback = control.hapticFeedback {
        fields["hapticFeedback"] = [
          "style": feedback.style.rawValue, "pattern": feedback.pattern.rawValue,
          "intensity": feedback.intensity, "sharpness": feedback.sharpness,
          "duration": feedback.duration,
        ]
      }
      return fields
    }
    return [
      "version": 1, "generation": map.generation, "revision": map.revision, "controls": controls,
    ]
  }
}
enum SavedControllerWire {
  static func counter(_ value: String) -> Bool {
    UInt64(value).map { String($0) == value } ?? false
  }
  static func hex(_ value: String, count: Int) -> Bool {
    value.utf8.count == count
      && value.utf8.allSatisfy {
        (48...57).contains($0) || (97...102).contains($0)
      }
  }
  static func profileID(_ value: String) -> Bool {
    value.utf8.count == 36 && UUID(uuidString: value) != nil && value.lowercased() == value
  }
  static let errors = Set([
    "saved_map_busy", "saved_map_timeout", "saved_map_unavailable",
    "saved_map_reactivation_required", "saved_map_unsupported_profile",
    "saved_map_response_too_large",
  ])
  static func number(_ value: String) -> Double? {
    guard value.utf8.count <= 32,
      value.range(
        of: #"\A(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:e[+-]?[0-9]+)?\z"#, options: .regularExpression)
        != nil,
      let result = Double(value), result.isFinite, result >= 0
    else { return nil }
    return result
  }
  static func decode(
    _ fields: [String: EnrollmentJSON.Value], request: SavedControllerRequest,
    authority: String, connection: String
  ) throws -> SavedControllerMap {
    func text(_ key: String) throws -> String {
      guard case .string(let value)? = fields[key] else { throw SavedControllerError.rejected }
      return value
    }
    func numeric(_ key: String) throws -> Double {
      guard let result = number(try text(key)) else { throw SavedControllerError.rejected }
      return result
    }
    let header: Set<String> = ["version", "command", "connectionId", "kind"]
    guard fields.count <= 848, fields["version"] == .integer(1),
      fields["command"] == .string("configuration-controls-result"),
      fields["connectionId"] == .string(connection)
    else { throw SavedControllerError.rejected }
    if fields["kind"] == .string("error") {
      let error = try text("error")
      guard Set(fields.keys) == header.union(["error"]), errors.contains(error)
      else { throw SavedControllerError.rejected }
      throw SavedControllerError.unavailable(error)
    }
    var keys = header.union([
      "authorityInstanceId", "configurationRevision", "sourceHash", "configurationSha256",
      "profileId",
      "generation", "revision", "viewportWidth", "viewportHeight", "controlCount",
    ])
    guard fields["kind"] == .string("controls"),
      try text("authorityInstanceId") == authority,
      try text("configurationRevision") == request.configurationRevision,
      try text("sourceHash") == request.sourceHash, try text("profileId") == request.profileID,
      try text("generation") == request.generation, try text("revision") == request.revision,
      try text("viewportWidth") == request.viewportWidth,
      try text("viewportHeight") == request.viewportHeight,
      SavedControllerWire.hex(try text("configurationSha256"), count: 64),
      case .integer(let count)? = fields["controlCount"], count >= 1, count <= 64
    else { throw SavedControllerError.rejected }
    var controls: [ControlRegion] = []
    for index in 0..<Int(count) {
      let prefix = "control\(index)"
      keys.formUnion(["Id", "Action", "X", "Y", "Width", "Height"].map { prefix + $0 })
      let hapticKeys = ["Style", "Pattern", "Intensity", "Sharpness", "Duration"].map {
        prefix + "Haptic" + $0
      }
      var haptic: TouchHapticFeedback?
      if hapticKeys.contains(where: { fields[$0] != nil }) {
        keys.formUnion(hapticKeys)
        guard let style = TouchHapticFeedback.Style(rawValue: try text(hapticKeys[0])),
          let pattern = TouchHapticFeedback.Pattern(rawValue: try text(hapticKeys[1]))
        else { throw SavedControllerError.rejected }
        haptic = TouchHapticFeedback(
          style: style, pattern: pattern, intensity: try numeric(hapticKeys[2]),
          sharpness: try numeric(hapticKeys[3]), duration: try numeric(hapticKeys[4]))
        guard haptic?.valid == true else { throw SavedControllerError.rejected }
        haptic = haptic?.normalized
      }
      controls.append(
        ControlRegion(
          id: try text(prefix + "Id"), action: try text(prefix + "Action"),
          x: try numeric(prefix + "X"), y: try numeric(prefix + "Y"),
          width: try numeric(prefix + "Width"), height: try numeric(prefix + "Height"),
          hapticFeedback: haptic))
    }
    guard Set(fields.keys) == keys else { throw SavedControllerError.rejected }
    let map = ControlMap(
      generation: request.generation, revision: request.revision, controls: controls)
    do { _ = try map.validated() } catch { throw SavedControllerError.rejected }
    return SavedControllerMap(map: map, configurationSha256: try text("configurationSha256"))
  }
}
