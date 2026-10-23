import Foundation

/// Receiver acknowledgment only. Does not refresh TTL or authorize a new input source.
struct PhoneInputProgress {
  let active: Bool
  let lastAccepted: UInt64?
  init(
    _ value: [String: EnrollmentJSON.Value], connection: String, session: String,
    map: ControlMap, lastOffered: UInt64?, previous: UInt64?,
    outputMode: PhoneOutputMode = .recording
  ) throws {
    guard
      Set(value.keys)
        == outputMode.fields(
          Set([
            "version", "command", "connectionId", "sessionId", "active", "generation", "revision",
            "lastAcceptedSequence", "inputEnabled",
          ])), value["version"] == .integer(1), value["command"] == .string("input-status"),
      value["connectionId"] == .string(connection), value["sessionId"] == .string(session),
      value["generation"] == .string(map.generation), value["revision"] == .string(map.revision),
      case .boolean(let active)? = value["active"]
    else { throw PhoneControlError.rejected }
    _ = try outputMode.validate(value, enabled: active)
    self.active = active
    switch value["lastAcceptedSequence"] {
    case .null?:
      guard previous == nil else { throw PhoneControlError.rejected }
      lastAccepted = nil
    case .string(let text)?:
      guard let sequence = ControlMap.counter(text), sequence < 1_048_576,
        let lastOffered, sequence <= lastOffered, previous.map({ sequence >= $0 }) ?? true
      else { throw PhoneControlError.rejected }
      lastAccepted = sequence
    default: throw PhoneControlError.rejected
    }
  }
}
