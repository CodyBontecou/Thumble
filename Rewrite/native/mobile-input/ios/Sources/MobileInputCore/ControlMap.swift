import Foundation
import ThumbleContracts

public enum InputError: Error, Equatable {
  case invalidMap, staleMap, unavailable, freshGenerationRequired, reentrant
}
public struct ControlRegion: Sendable, Decodable {
  public let id: String
  public let action: String
  public let x: Double
  public let y: Double
  public let width: Double
  public let height: Double
  public let hapticFeedback: TouchHapticFeedback?
  public init(
    id: String, action: String, x: Double, y: Double, width: Double, height: Double,
    hapticFeedback: TouchHapticFeedback? = nil
  ) {
    self.id = id
    self.action = action
    self.x = x
    self.y = y
    self.width = width
    self.height = height
    self.hapticFeedback = hapticFeedback
  }
  private enum CodingKeys: String, CodingKey {
    case id, action, x, y, width, height, hapticFeedback
  }
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try c.decode(String.self, forKey: .id),
      action: try c.decode(String.self, forKey: .action),
      x: try c.decode(Double.self, forKey: .x), y: try c.decode(Double.self, forKey: .y),
      width: try c.decode(Double.self, forKey: .width),
      height: try c.decode(Double.self, forKey: .height),
      hapticFeedback: try c.contains(.hapticFeedback)
        ? c.decode(TouchHapticFeedback.self, forKey: .hapticFeedback).normalized : nil)
  }
  func contains(_ x: Double, _ y: Double) -> Bool {
    x >= self.x && y >= self.y && x < self.x + width && y < self.y + height
  }
  /// Aliases share one native capture owner for their physical output.
  var analogTarget: String? {
    switch action {
    case "leftStick", "leftStandardStick": "leftStick"
    case "rightStick", "rightStandardStick": "rightStick"
    case "leftTrigger", "leftVerticalTrigger", "leftHorizontalTrigger": "leftTrigger"
    case "rightTrigger", "rightVerticalTrigger", "rightHorizontalTrigger": "rightTrigger"
    default: nil
    }
  }
  var valid: Bool {
    let actions =
      GamepadButtonV1.allCases.map(\.rawValue) + [
        "leftStick", "rightStick", "leftTrigger", "rightTrigger",
        "leftStandardStick", "rightStandardStick", "leftVerticalTrigger", "rightVerticalTrigger",
        "leftHorizontalTrigger", "rightHorizontalTrigger",
      ]
    return !id.isEmpty && id.utf8.count <= 64
      && id.utf8.allSatisfy {
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
      }
      && (hapticFeedback?.valid ?? true) && actions.contains(action)
      && [x, y, width, height].allSatisfy(\.isFinite)
      && x >= 0 && y >= 0 && width >= 0.001 && height >= 0.001
      && x + width <= 1 && y + height <= 1
  }
}
public struct ControlMap: Sendable, Decodable {
  public let version: Int
  public let generation: String
  public let revision: String
  public let controls: [ControlRegion]
  public init(version: Int = 1, generation: String, revision: String, controls: [ControlRegion]) {
    self.version = version
    self.generation = generation
    self.revision = revision
    self.controls = controls
  }
  func validated() throws -> (UInt64, UInt64) {
    guard version == 1, (1...64).contains(controls.count), controls.allSatisfy(\.valid),
      Set(controls.map(\.id)).count == controls.count,
      let generation = Self.counter(generation), generation > 0,
      let revision = Self.counter(revision)
    else { throw InputError.invalidMap }
    return (generation, revision)
  }
  static func counter(_ text: String) -> UInt64? {
    guard !text.isEmpty, text.utf8.count <= 20, text == "0" || !text.hasPrefix("0"),
      text.utf8.allSatisfy({ (48...57).contains($0) })
    else { return nil }
    return UInt64(text)
  }
}
public enum ReleaseReason: String, Sendable, CaseIterable {
  case touchCancelled, background, screenLock, rotation, profileReplacement, disconnected, disposed,
    practice, invalidTouch, transportFailure, sequenceExhausted
}
public struct InputSample: Sendable {
  public let generation: String
  public let sequence: String
  public let state: GamepadStateV1
}
public struct ActivationReceipt: Sendable {
  public let version: Int
  public let generation: String
  public let revision: String
}
