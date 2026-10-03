import Foundation

public enum VirtualGamepadPhase: String, Codable, Sendable {
    case inactive
    case ready
    case missingEntitlement = "missing-entitlement"
    case creationFailed = "creation-failed"
    case reportFailed = "report-failed"
    case recording
}

/// An immutable diagnostic snapshot. Keeping this aggregate boxed avoids growing
/// ControllerMessage and profile/startup frames on constrained network threads.
public final class VirtualGamepadStatus: Codable, Equatable, Sendable {
    public let phase: VirtualGamepadPhase
    public let entitlementGranted: Bool?
    public let lastError: String?
    public let lastReportResult: UInt32?
    public let lastReportUptimeNanoseconds: UInt64?
    public let reportCount: UInt64
    public let pressedButtons: [VirtualGamepadButton]
    public let leftStickX: Double
    public let leftStickY: Double
    public let rightStickX: Double
    public let rightStickY: Double
    public let leftTrigger: Double
    public let rightTrigger: Double

    // Ready means the device exists AND its initial neutral report succeeded.
    // It deliberately makes no claim about GameController, SDL, Steam or games.
    public var isAvailable: Bool { phase == .ready }
    public var isActive: Bool { phase == .ready }

    public var summary: String {
        switch phase {
        case .inactive: "Controller output off"
        case .ready: "Virtual HID ready • game compatibility unverified"
        case .missingEntitlement: "Controller unavailable • HID entitlement missing"
        case .creationFailed: "Controller unavailable • HID creation failed"
        case .reportFailed: "Controller unavailable • HID report failed"
        case .recording: "Controller recording only • system input off"
        }
    }

    public init(
        phase: VirtualGamepadPhase = .inactive,
        entitlementGranted: Bool? = nil,
        lastError: String? = nil,
        lastReportResult: UInt32? = nil,
        lastReportUptimeNanoseconds: UInt64? = nil,
        reportCount: UInt64 = 0,
        pressedButtons: [VirtualGamepadButton] = [],
        leftStickX: Double = 0, leftStickY: Double = 0,
        rightStickX: Double = 0, rightStickY: Double = 0,
        leftTrigger: Double = 0, rightTrigger: Double = 0
    ) {
        self.phase = phase
        self.entitlementGranted = entitlementGranted
        self.lastError = lastError
        self.lastReportResult = lastReportResult
        self.lastReportUptimeNanoseconds = lastReportUptimeNanoseconds
        self.reportCount = reportCount
        self.pressedButtons = pressedButtons
        self.leftStickX = leftStickX
        self.leftStickY = leftStickY
        self.rightStickX = rightStickX
        self.rightStickY = rightStickY
        self.leftTrigger = leftTrigger
        self.rightTrigger = rightTrigger
    }

    public static func == (lhs: VirtualGamepadStatus, rhs: VirtualGamepadStatus) -> Bool {
        lhs.phase == rhs.phase && lhs.entitlementGranted == rhs.entitlementGranted &&
        lhs.lastError == rhs.lastError && lhs.lastReportResult == rhs.lastReportResult &&
        lhs.lastReportUptimeNanoseconds == rhs.lastReportUptimeNanoseconds &&
        lhs.reportCount == rhs.reportCount && lhs.pressedButtons == rhs.pressedButtons &&
        lhs.leftStickX == rhs.leftStickX && lhs.leftStickY == rhs.leftStickY &&
        lhs.rightStickX == rhs.rightStickX && lhs.rightStickY == rhs.rightStickY &&
        lhs.leftTrigger == rhs.leftTrigger && lhs.rightTrigger == rhs.rightTrigger
    }
}
