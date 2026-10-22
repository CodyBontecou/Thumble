import Foundation

/// Public admission metadata only. The next grant request independently checks
/// these epochs again; inspecting them never creates or restores a touch owner.
public struct PhoneInputConfiguration: Sendable, Equatable {
  public let active: Bool
  public let generation: String
  public let revision: String
  public let inputEnabled = false

  init(_ value: [String: EnrollmentJSON.Value], connection: String) throws {
    guard
      Set(value.keys)
        == Set([
          "version", "command", "connectionId", "active", "generation", "revision", "inputEnabled",
        ]), value["version"] == .integer(1), value["command"] == .string("input-configuration"),
      value["connectionId"] == .string(connection), value["inputEnabled"] == .boolean(false),
      case .boolean(let active)? = value["active"],
      case .string(let generation)? = value["generation"],
      let epoch = ControlMap.counter(generation), !active || epoch > 0,
      case .string(let revision)? = value["revision"], ControlMap.counter(revision) != nil
    else { throw PhoneControlError.rejected }
    self.active = active
    self.generation = generation
    self.revision = revision
  }
}
