import Foundation
import CoreGraphics

public struct KeypadKeyboardStrokeBinding: Codable, Equatable, Hashable, Sendable {
    public var keyCode: UInt16
    public var modifiersRawValue: UInt8

    public init(keyCode: UInt16, modifiersRawValue: UInt8 = 0) {
        self.keyCode = keyCode
        self.modifiersRawValue = modifiersRawValue
    }
}

public struct KeypadKeyboardBinding: Codable, Equatable, Hashable, Sendable {
    public var keyCode: UInt16
    public var modifiersRawValue: UInt8
    public var sequence: [KeypadKeyboardStrokeBinding]?

    public init(keyCode: UInt16, modifiersRawValue: UInt8 = 0, sequence: [KeypadKeyboardStrokeBinding]? = nil) {
        self.keyCode = keyCode
        self.modifiersRawValue = modifiersRawValue
        self.sequence = sequence
    }

    public init?(keyName: String, modifierNames: [String] = []) {
        guard let keyCode = KeypadKeyboardKeyCatalog.keyCode(named: keyName),
              let modifiers = KeypadKeyboardKeyCatalog.modifierMask(named: modifierNames)
        else { return nil }
        self.init(keyCode: keyCode, modifiersRawValue: modifiers)
    }

    public var strokes: [KeypadKeyboardStrokeBinding] {
        if let sequence, !sequence.isEmpty { return sequence }
        return [KeypadKeyboardStrokeBinding(keyCode: keyCode, modifiersRawValue: modifiersRawValue)]
    }
}

public struct KeypadElementOutputBinding: Codable, Equatable, Hashable, Sendable {
    public var keyboard: KeypadKeyboardBinding?
    public var gamepadButtons: Set<VirtualGamepadButton>

    public init(keyboard: KeypadKeyboardBinding? = nil, gamepadButtons: Set<VirtualGamepadButton> = []) {
        self.keyboard = keyboard
        self.gamepadButtons = gamepadButtons
    }

    public var isEmpty: Bool {
        keyboard == nil && gamepadButtons.isEmpty
    }
}

public enum VirtualGamepadButton: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
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

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .south: "South / A / Cross"
        case .east: "East / B / Circle"
        case .west: "West / X / Square"
        case .north: "North / Y / Triangle"
        case .leftShoulder: "Left Shoulder / L1"
        case .rightShoulder: "Right Shoulder / R1"
        case .leftTriggerButton: "Left Trigger Button / L2"
        case .rightTriggerButton: "Right Trigger Button / R2"
        case .select: "Select / Back"
        case .start: "Start / Menu"
        case .home: "Home / Guide"
        case .leftStickPress: "Left Stick Press"
        case .rightStickPress: "Right Stick Press"
        case .dpadUp: "D-pad Up"
        case .dpadDown: "D-pad Down"
        case .dpadLeft: "D-pad Left"
        case .dpadRight: "D-pad Right"
        }
    }

    public var shortName: String {
        switch self {
        case .south: "A"
        case .east: "B"
        case .west: "X"
        case .north: "Y"
        case .leftShoulder: "L1"
        case .rightShoulder: "R1"
        case .leftTriggerButton: "L2"
        case .rightTriggerButton: "R2"
        case .select: "Select"
        case .start: "Start"
        case .home: "Home"
        case .leftStickPress: "L3"
        case .rightStickPress: "R3"
        case .dpadUp: "D↑"
        case .dpadDown: "D↓"
        case .dpadLeft: "D←"
        case .dpadRight: "D→"
        }
    }
}

public enum VirtualGamepadStick: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case left
    case right

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .left: "Left Stick"
        case .right: "Right Stick"
        }
    }
}

public enum VirtualGamepadTrigger: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case left
    case right

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .left: "Left Trigger"
        case .right: "Right Trigger"
        }
    }

    public var shortName: String {
        switch self {
        case .left: "LT"
        case .right: "RT"
        }
    }
}

public enum GamepadJoystickAnalogTarget: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case leftStick = "left_stick"
    case rightStick = "right_stick"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: "Digital directions"
        case .leftStick: "Left analog stick"
        case .rightStick: "Right analog stick"
        }
    }

    public var stick: VirtualGamepadStick? {
        switch self {
        case .none: nil
        case .leftStick: .left
        case .rightStick: .right
        }
    }
}

public struct GamepadJoystickOutputSettings: Codable, Equatable, Sendable {
    public static let defaultValue = GamepadJoystickOutputSettings()
    public static let analogLeftStick = GamepadJoystickOutputSettings(analogTarget: .leftStick, sendsDigitalDirections: false)
    public static let analogRightStick = GamepadJoystickOutputSettings(analogTarget: .rightStick, sendsDigitalDirections: false)

    public var analogTarget: GamepadJoystickAnalogTarget
    public var sendsDigitalDirections: Bool
    public var deadZone: CGFloat
    public var sensitivity: CGFloat
    public var invertX: Bool
    public var invertY: Bool
    public var snapToCardinal: Bool

    public init(
        analogTarget: GamepadJoystickAnalogTarget = .none,
        sendsDigitalDirections: Bool = true,
        deadZone: CGFloat = 0.12,
        sensitivity: CGFloat = 1.0,
        invertX: Bool = false,
        invertY: Bool = false,
        snapToCardinal: Bool = false
    ) {
        self.analogTarget = analogTarget
        self.sendsDigitalDirections = sendsDigitalDirections
        self.deadZone = deadZone
        self.sensitivity = sensitivity
        self.invertX = invertX
        self.invertY = invertY
        self.snapToCardinal = snapToCardinal
    }

    public var normalized: GamepadJoystickOutputSettings {
        GamepadJoystickOutputSettings(
            analogTarget: analogTarget,
            sendsDigitalDirections: sendsDigitalDirections || analogTarget == .none,
            deadZone: Self.clamp(deadZone, lower: 0, upper: 0.85),
            sensitivity: Self.clamp(sensitivity, lower: 0.2, upper: 3.0),
            invertX: invertX,
            invertY: invertY,
            snapToCardinal: snapToCardinal
        )
    }

    public func transformedVector(x: CGFloat, y: CGFloat) -> CGVector {
        let settings = normalized
        var dx = x * settings.sensitivity
        var dy = y * settings.sensitivity
        if settings.invertX { dx = -dx }
        if settings.invertY { dy = -dy }

        let distance = hypot(dx, dy)
        guard distance > settings.deadZone else { return CGVector(dx: 0, dy: 0) }

        let scaledDistance = min(1, (distance - settings.deadZone) / max(0.001, 1 - settings.deadZone))
        dx = (dx / distance) * scaledDistance
        dy = (dy / distance) * scaledDistance

        if settings.snapToCardinal, abs(dx) != abs(dy) {
            if abs(dx) > abs(dy) {
                dy = 0
                dx = dx >= 0 ? scaledDistance : -scaledDistance
            } else {
                dx = 0
                dy = dy >= 0 ? scaledDistance : -scaledDistance
            }
        }

        return CGVector(dx: Self.clamp(dx, lower: -1, upper: 1), dy: Self.clamp(dy, lower: -1, upper: 1))
    }

    private static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        guard value.isFinite else { return lower }
        return min(max(value, lower), upper)
    }
}

public enum GamepadTriggerOrientation: String, Codable, CaseIterable, Identifiable, Sendable {
    case vertical
    case horizontal

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .vertical: "Vertical"
        case .horizontal: "Horizontal"
        }
    }
}

public struct GamepadTriggerSettings: Codable, Equatable, Sendable {
    public static let defaultValue = GamepadTriggerSettings()

    public var target: VirtualGamepadTrigger
    public var orientation: GamepadTriggerOrientation
    public var deadZone: CGFloat
    public var sensitivity: CGFloat
    public var sendsDigitalButton: Bool
    public var digitalThreshold: CGFloat

    public init(
        target: VirtualGamepadTrigger = .right,
        orientation: GamepadTriggerOrientation = .vertical,
        deadZone: CGFloat = 0.03,
        sensitivity: CGFloat = 1.0,
        sendsDigitalButton: Bool = false,
        digitalThreshold: CGFloat = 0.5
    ) {
        self.target = target
        self.orientation = orientation
        self.deadZone = deadZone
        self.sensitivity = sensitivity
        self.sendsDigitalButton = sendsDigitalButton
        self.digitalThreshold = digitalThreshold
    }

    public var normalized: GamepadTriggerSettings {
        GamepadTriggerSettings(
            target: target,
            orientation: orientation,
            deadZone: Self.clamp(deadZone, lower: 0, upper: 0.85),
            sensitivity: Self.clamp(sensitivity, lower: 0.2, upper: 3.0),
            sendsDigitalButton: sendsDigitalButton,
            digitalThreshold: Self.clamp(digitalThreshold, lower: 0.01, upper: 1.0)
        )
    }

    public func transformedValue(_ value: CGFloat) -> CGFloat {
        let settings = normalized
        let clamped = Self.clamp(value, lower: 0, upper: 1) * settings.sensitivity
        guard clamped > settings.deadZone else { return 0 }
        return Self.clamp((clamped - settings.deadZone) / max(0.001, 1 - settings.deadZone), lower: 0, upper: 1)
    }

    private static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        guard value.isFinite else { return lower }
        return min(max(value, lower), upper)
    }
}
