// Generated from gamepad-state-v1.schema.json; do not edit. DTO only: validate before activation.
import Foundation

public enum GamepadButtonV1: String, Codable, CaseIterable, Sendable {
    case south
    case east
    case west
    case north
    case leftShoulder
    case rightShoulder
    case leftTriggerButton
    case rightTriggerButton
    case select
    case start
    case home
    case leftStickPress
    case rightStickPress
    case dpadUp
    case dpadDown
    case dpadLeft
    case dpadRight
}

public struct GamepadStateV1: Codable, Sendable {
    public let buttons: [GamepadButtonV1]
    public let leftStickX: Double
    public let leftStickY: Double
    public let rightStickX: Double
    public let rightStickY: Double
    public let leftTrigger: Double
    public let rightTrigger: Double

    public init(buttons: [GamepadButtonV1], leftStickX: Double, leftStickY: Double, rightStickX: Double, rightStickY: Double, leftTrigger: Double, rightTrigger: Double) {
        self.buttons = buttons
        self.leftStickX = leftStickX
        self.leftStickY = leftStickY
        self.rightStickX = rightStickX
        self.rightStickY = rightStickY
        self.leftTrigger = leftTrigger
        self.rightTrigger = rightTrigger
    }
}
