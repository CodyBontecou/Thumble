import Foundation
import ThumbleContracts

extension GamepadStateV1 {
  public static var neutral: Self {
    Self(
      buttons: [], leftStickX: 0, leftStickY: 0, rightStickX: 0, rightStickY: 0, leftTrigger: 0,
      rightTrigger: 0)
  }
  public var isValid: Bool {
    buttons.count <= 17 && Set(buttons).count == buttons.count
      && [leftStickX, leftStickY, rightStickX, rightStickY].allSatisfy {
        $0.isFinite && (-1...1).contains($0)
      }
      && [leftTrigger, rightTrigger].allSatisfy { $0.isFinite && (0...1).contains($0) }
  }
}
public enum GamepadReport {
  /// Retained v2 conformance oracle. This function emits no OS input.
  public static func encode(_ state: GamepadStateV1) -> [UInt8] {
    let buttons = Set(state.buttons)
    var mask: UInt16 = 0
    for button in buttons {
      let bit: Int? =
        switch button {
        case .dpadUp: 0
        case .dpadDown: 1
        case .dpadLeft: 2
        case .dpadRight: 3
        case .start: 4
        case .select: 5
        case .leftStickPress: 6
        case .rightStickPress: 7
        case .leftShoulder: 8
        case .rightShoulder: 9
        case .home: 10
        case .south: 12
        case .east: 13
        case .west: 14
        case .north: 15
        case .leftTriggerButton, .rightTriggerButton: nil
        }
      if let bit { mask |= 1 << bit }
    }
    if buttons.contains(.dpadUp) && buttons.contains(.dpadDown) { mask &= ~3 }
    if buttons.contains(.dpadLeft) && buttons.contains(.dpadRight) { mask &= ~12 }
    func bounded(_ value: Double, minimum: Double) -> Double {
      min(1, max(minimum, value.isFinite ? value : 0))
    }
    var bytes = [UInt8](repeating: 0, count: 20)
    bytes[1] = 20
    bytes[2] = UInt8(truncatingIfNeeded: mask)
    bytes[3] = UInt8(mask >> 8)
    bytes[4] = UInt8(
      (bounded(buttons.contains(.leftTriggerButton) ? 1 : state.leftTrigger, minimum: 0) * 255)
        .rounded())
    bytes[5] = UInt8(
      (bounded(buttons.contains(.rightTriggerButton) ? 1 : state.rightTrigger, minimum: 0) * 255)
        .rounded())
    for (i, raw) in [state.leftStickX, -state.leftStickY, state.rightStickX, -state.rightStickY]
      .enumerated()
    {
      let value = bounded(raw, minimum: -1)
      let bits = UInt16(bitPattern: Int16((value * (value < 0 ? 32768 : 32767)).rounded()))
      bytes[6 + i * 2] = UInt8(truncatingIfNeeded: bits)
      bytes[7 + i * 2] = UInt8(bits >> 8)
    }
    return bytes
  }
  public static func hex(_ state: GamepadStateV1) -> String {
    encode(state).map { String(format: "%02x", $0) }.joined()
  }
}
