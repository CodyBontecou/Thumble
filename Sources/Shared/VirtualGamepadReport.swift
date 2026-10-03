import Foundation

/// Canonical v1 input report shared by both receiver implementations. Y grows
/// downwards on the HID wire; consumer APIs may expose a different convention.
public struct VirtualGamepadReportState: Equatable, Sendable {
    public var buttons: Set<VirtualGamepadButton> = []
    public var leftStickX: Double = 0
    public var leftStickY: Double = 0
    public var rightStickX: Double = 0
    public var rightStickY: Double = 0
    public var leftTrigger: Double = 0
    public var rightTrigger: Double = 0

    public init() {}

    // A digital trigger always actuates its axis. Releasing it restores the
    // independently held analog value instead of releasing another owner.
    public var effectiveLeftTrigger: Double { buttons.contains(.leftTriggerButton) ? 1 : leftTrigger }
    public var effectiveRightTrigger: Double { buttons.contains(.rightTriggerButton) ? 1 : rightTrigger }

    public var reportBytes: [UInt8] {
        var mask: UInt16 = 0
        for button in buttons {
            if let bit = Self.bitIndex(button) { mask |= UInt16(1) << bit }
        }
        return [
            VirtualGamepadReport.reportID,
            UInt8(truncatingIfNeeded: mask), UInt8(truncatingIfNeeded: mask >> 8),
            Self.hat(buttons),
            Self.signedAxis(leftStickX), Self.signedAxis(leftStickY),
            Self.signedAxis(rightStickX), Self.signedAxis(rightStickY),
            Self.triggerAxis(effectiveLeftTrigger), Self.triggerAxis(effectiveRightTrigger)
        ]
    }

    private static func bitIndex(_ button: VirtualGamepadButton) -> UInt16? {
        switch button {
        case .south: 0
        case .east: 1
        case .west: 2
        case .north: 3
        case .leftShoulder: 4
        case .rightShoulder: 5
        case .leftTriggerButton: 6
        case .rightTriggerButton: 7
        case .select: 8
        case .start: 9
        case .home: 10
        case .leftStickPress: 11
        case .rightStickPress: 12
        case .dpadUp, .dpadDown, .dpadLeft, .dpadRight: nil
        }
    }

    private static func hat(_ buttons: Set<VirtualGamepadButton>) -> UInt8 {
        switch (buttons.contains(.dpadUp), buttons.contains(.dpadDown),
                buttons.contains(.dpadLeft), buttons.contains(.dpadRight)) {
        case (true, false, false, false): 0
        case (true, false, false, true): 1
        case (false, false, false, true): 2
        case (false, true, false, true): 3
        case (false, true, false, false): 4
        case (false, true, true, false): 5
        case (false, false, true, false): 6
        case (true, false, true, false): 7
        default: 8 // Opposing directions cancel to the descriptor's null value.
        }
    }

    private static func signedAxis(_ value: Double) -> UInt8 {
        let finite = value.isFinite ? value : 0
        return UInt8(bitPattern: Int8((min(1, max(-1, finite)) * 127).rounded()))
    }

    private static func triggerAxis(_ value: Double) -> UInt8 {
        let finite = value.isFinite ? value : 0
        return UInt8((min(1, max(0, finite)) * 255).rounded())
    }
}

public enum VirtualGamepadReport {
    public static let reportID: UInt8 = 1
    public static let byteCount = 10
    public static let vendorID = 0xCB01
    public static let productID = 0x5050

    /// Thirteen buttons, three reserved constant bits, hat with eight directions
    /// and a null state, signed X/Y/Rx/Ry, independent unsigned Z/Rz triggers.
    /// Reset all angular globals before the axes (HID globals are sticky).
    public static let descriptor: [UInt8] = [
        0x05, 0x01, 0x09, 0x05, 0xA1, 0x01, 0x85, 0x01,
        0x05, 0x09, 0x19, 0x01, 0x29, 0x0D, 0x15, 0x00, 0x25, 0x01,
        0x75, 0x01, 0x95, 0x0D, 0x81, 0x02,
        0x95, 0x03, 0x81, 0x03,
        0x05, 0x01, 0x09, 0x39, 0x15, 0x00, 0x25, 0x07,
        0x35, 0x00, 0x46, 0x3B, 0x01, 0x65, 0x14,
        0x75, 0x04, 0x95, 0x01, 0x81, 0x42,
        0x75, 0x04, 0x95, 0x01, 0x81, 0x03,
        0x35, 0x00, 0x45, 0x00, 0x65, 0x00, 0x55, 0x00,
        0x09, 0x30, 0x09, 0x31, 0x09, 0x33, 0x09, 0x34,
        0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x04, 0x81, 0x02,
        0x09, 0x32, 0x09, 0x35, 0x15, 0x00, 0x26, 0xFF, 0x00,
        0x75, 0x08, 0x95, 0x02, 0x81, 0x02, 0xC0
    ]
}
