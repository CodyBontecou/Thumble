import Foundation

/// Explicit caller intent. It never creates or authorizes an OS device.
public enum PhoneOutputMode: Sendable, Equatable {
  case recording
  case macosHID

  func fields(_ base: Set<String>) -> Set<String> {
    self == .recording ? base : base.union(["outputBackend"])
  }
  func validate(_ value: [String: EnrollmentJSON.Value], enabled: Bool? = nil) throws -> Bool {
    guard case .boolean(let actual)? = value["inputEnabled"] else {
      throw PhoneControlError.rejected
    }
    switch self {
    case .recording:
      guard !actual, value["outputBackend"] == nil else { throw PhoneControlError.rejected }
    case .macosHID:
      guard value["outputBackend"] == .string("macos-hid"), enabled.map({ actual == $0 }) ?? true
      else {
        throw PhoneControlError.rejected
      }
    }
    return actual
  }
}
