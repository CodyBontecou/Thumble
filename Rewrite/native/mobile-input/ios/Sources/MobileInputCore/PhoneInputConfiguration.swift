import Foundation

/// Public admission metadata only. The next grant request independently checks
/// these epochs again; inspecting them never creates or restores a touch owner.
public struct PhoneInputConfiguration: Sendable, Equatable {
  public let active: Bool
  public let generation: String
  public let revision: String
  public let inputEnabled: Bool
  public let outputMode: PhoneOutputMode

  init(
    _ value: [String: EnrollmentJSON.Value], connection: String,
    outputMode: PhoneOutputMode = .recording
  ) throws {
    guard
      Set(value.keys)
        == outputMode.fields(
          Set([
            "version", "command", "connectionId", "active", "generation", "revision",
            "inputEnabled",
          ])), value["version"] == .integer(1), value["command"] == .string("input-configuration"),
      value["connectionId"] == .string(connection),
      case .boolean(let active)? = value["active"],
      case .string(let generation)? = value["generation"],
      let epoch = ControlMap.counter(generation), !active || epoch > 0,
      case .string(let revision)? = value["revision"], ControlMap.counter(revision) != nil
    else { throw PhoneControlError.rejected }
    inputEnabled = try outputMode.validate(value, enabled: active)
    self.outputMode = outputMode
    self.active = active
    self.generation = generation
    self.revision = revision
  }
}
