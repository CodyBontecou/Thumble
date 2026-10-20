import Foundation

// Profile-owned design primitives. Legacy type names retain source compatibility
// while package APIs are removed; their Codable field names remain unchanged.

/// Semantic design roles independent of profile-specific UUIDs, labels, or packages.
public enum GamepadVisualRole: String, Codable, CaseIterable, Identifiable, Sendable {
    case movement
    case primaryAction = "primary_action"
    case secondaryAction = "secondary_action"
    case utility
    case menu
    case custom
    case joystick
    case trigger
    case trackpad
    case decoration
    case system

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .movement: "Movement"
        case .primaryAction: "Primary Action"
        case .secondaryAction: "Secondary Action"
        case .utility: "Utility"
        case .menu: "Menu"
        case .custom: "Custom Action"
        case .joystick: "Joystick"
        case .trigger: "Trigger"
        case .trackpad: "Trackpad"
        case .decoration: "Decoration"
        case .system: "System"
        }
    }

    /// Kind-only fallback. Button position, UUID, label and output never imply importance.
    public static func inferred(for button: KeypadElementID, controlKind: GamepadCustomControlKind) -> GamepadVisualRole {
        switch controlKind {
        case .joystick: return .joystick
        case .trigger: return .trigger
        case .trackpad: return .trackpad
        case .text, .decoration: return .decoration
        case .button: return .custom
        }
    }
}


public enum ThumbleSkinArtworkPlane: String, Codable, CaseIterable, Identifiable, Sendable {
    case underlay
    case overlay

    public var id: String { rawValue }
}

public enum ThumbleSkinArtworkBlendMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case normal
    case multiply
    case screen
    case overlay
    case softLight = "soft_light"

    public var id: String { rawValue }
}

/// Passive canvas decoration. It has no hit target, output binding, label, or accessibility action.
public struct ThumbleSkinArtworkLayer: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var plane: ThumbleSkinArtworkPlane
    public var frame: ThumbleNormalizedRect?
    public var fillStyle: GamepadFillStyle?
    public var opacity: CGFloat
    public var rotationDegrees: CGFloat
    public var blendMode: ThumbleSkinArtworkBlendMode
    public var zIndex: Int
    public var isHidden: Bool

    public init(
        id: String,
        plane: ThumbleSkinArtworkPlane = .underlay,
        frame: ThumbleNormalizedRect? = nil,
        fillStyle: GamepadFillStyle? = nil,
        opacity: CGFloat = 1,
        rotationDegrees: CGFloat = 0,
        blendMode: ThumbleSkinArtworkBlendMode = .normal,
        zIndex: Int = 0,
        isHidden: Bool = false
    ) {
        self.id = id
        self.plane = plane
        self.frame = frame
        self.fillStyle = fillStyle
        self.opacity = opacity
        self.rotationDegrees = rotationDegrees
        self.blendMode = blendMode
        self.zIndex = zIndex
        self.isHidden = isHidden
    }

    public var normalized: ThumbleSkinArtworkLayer? {
        let id = GamepadStyleToken.normalizedIdentifier(id)
        guard !id.isEmpty else { return nil }
        let rotation = rotationDegrees.isFinite ? rotationDegrees.truncatingRemainder(dividingBy: 360) : 0
        return ThumbleSkinArtworkLayer(
            id: id,
            plane: plane,
            frame: (frame ?? ThumbleNormalizedRect(x: 0, y: 0, width: 1, height: 1)).normalized,
            fillStyle: fillStyle?.normalized,
            opacity: min(max(opacity.isFinite ? opacity : 1, 0), 1),
            rotationDegrees: rotation,
            blendMode: blendMode,
            zIndex: min(max(zIndex, -10_000), 10_000),
            isHidden: isHidden
        )
    }
}

/// Appearance-only properties for one control. Geometry and output bindings deliberately do not live here.
public struct ThumbleSkinControlAppearance: Codable, Equatable, Sendable {
    public var styleID: String?
    public var shape: GamepadButtonShapeStyle?
    public var accentStyle: GamepadAccentStyle?
    public var visualStyle: GamepadControlVisualStyle?
    public var icon: GamepadControlIcon?
    public var hapticFeedback: GamepadHapticFeedback?
    public var cornerRadius: CGFloat?
    public var cornerRadii: GamepadCornerRadii?
    public var shadowStrength: CGFloat?
    public var joystickKnobColor: GamepadRGBAColor?
    public var joystickVisualStyle: GamepadJoystickVisualStyle?

    public init(
        styleID: String? = nil,
        shape: GamepadButtonShapeStyle? = nil,
        accentStyle: GamepadAccentStyle? = nil,
        visualStyle: GamepadControlVisualStyle? = nil,
        icon: GamepadControlIcon? = nil,
        hapticFeedback: GamepadHapticFeedback? = nil,
        cornerRadius: CGFloat? = nil,
        cornerRadii: GamepadCornerRadii? = nil,
        shadowStrength: CGFloat? = nil,
        joystickKnobColor: GamepadRGBAColor? = nil,
        joystickVisualStyle: GamepadJoystickVisualStyle? = nil
    ) {
        self.styleID = styleID
        self.shape = shape
        self.accentStyle = accentStyle
        self.visualStyle = visualStyle
        self.icon = icon
        self.hapticFeedback = hapticFeedback
        self.cornerRadius = cornerRadius
        self.cornerRadii = cornerRadii
        self.shadowStrength = shadowStrength
        self.joystickKnobColor = joystickKnobColor
        self.joystickVisualStyle = joystickVisualStyle
    }

    public static let empty = ThumbleSkinControlAppearance()

    public var normalized: ThumbleSkinControlAppearance {
        var copy = self
        copy.normalizeInPlace()
        return copy
    }

    mutating func normalizeInPlace() {
        normalizeIdentityAndFeedbackInPlace()
        normalizeVisualStyleInPlace()
        normalizeGeometryAndColorInPlace()
    }

    private mutating func normalizeIdentityAndFeedbackInPlace() {
        let normalizedStyleID = styleID.map(GamepadStyleToken.normalizedIdentifier) ?? ""
        styleID = normalizedStyleID.isEmpty ? nil : normalizedStyleID
        icon = icon?.normalized
        hapticFeedback = hapticFeedback?.normalized
    }

    private mutating func normalizeVisualStyleInPlace() {
        visualStyle = visualStyle?.normalized
    }

    private mutating func normalizeGeometryAndColorInPlace() {
        cornerRadius = cornerRadius.map(GamepadButtonCustomization.normalizedCornerRadius)
        cornerRadii = cornerRadii?.normalized
        shadowStrength = shadowStrength.map {
            GamepadButtonCustomization.clamp(
                $0,
                lower: GamepadButtonCustomization.minimumShadowStrength,
                upper: GamepadButtonCustomization.maximumShadowStrength
            )
        }
        joystickKnobColor = joystickKnobColor?.normalized
    }

    public var isEmpty: Bool {
        var value = self
        value.normalizeInPlace()
        return value.isEmptyWithoutNormalization
    }

    var isEmptyWithoutNormalization: Bool {
        if styleID != nil { return false }
        if shape != nil { return false }
        if accentStyle != nil { return false }
        if visualStyle != nil { return false }
        if icon != nil { return false }
        if hapticFeedback != nil { return false }
        if cornerRadius != nil { return false }
        if cornerRadii != nil { return false }
        if shadowStrength != nil { return false }
        if joystickKnobColor != nil { return false }
        return joystickVisualStyle == nil
    }

    /// Returns this appearance layered over a less-specific appearance.
    public func merged(over base: ThumbleSkinControlAppearance) -> ThumbleSkinControlAppearance {
        MergeWorkspace(base: base, overlay: self).resolve()
    }

    private final class MergeWorkspace {
        private var base: ThumbleSkinControlAppearance
        private var overlay: ThumbleSkinControlAppearance
        private var result: ThumbleSkinControlAppearance

        init(base: ThumbleSkinControlAppearance, overlay: ThumbleSkinControlAppearance) {
            self.base = base
            self.overlay = overlay
            self.result = base
        }

        func resolve() -> ThumbleSkinControlAppearance {
            base.normalizeInPlace()
            overlay.normalizeInPlace()
            result = base
            applyOverlay()
            result.normalizeInPlace()
            return result
        }

        private func applyOverlay() {
            if let value = overlay.styleID { result.styleID = value }
            if let value = overlay.shape { result.shape = value }
            if let value = overlay.accentStyle { result.accentStyle = value }
            if let value = overlay.visualStyle { result.visualStyle = value }
            if let value = overlay.icon { result.icon = value }
            if let value = overlay.hapticFeedback { result.hapticFeedback = value }
            if let value = overlay.cornerRadius { result.cornerRadius = value }
            if let value = overlay.cornerRadii { result.cornerRadii = value }
            if let value = overlay.shadowStrength { result.shadowStrength = value }
            if let value = overlay.joystickKnobColor { result.joystickKnobColor = value }
            if let value = overlay.joystickVisualStyle { result.joystickVisualStyle = value }
        }
    }
}


public enum ThumbleActionSet: String, Codable, CaseIterable, Identifiable, Sendable {
    case base
    case leftTrigger = "left-trigger"
    case rightTrigger = "right-trigger"
    case bothTriggers = "both-triggers"

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .base: "Base"
        case .leftTrigger: "LT"
        case .rightTrigger: "RT"
        case .bothTriggers: "LT + RT"
        }
    }

    public init(leftHeld: Bool, rightHeld: Bool) {
        self = leftHeld ? (rightHeld ? .bothTriggers : .leftTrigger) : (rightHeld ? .rightTrigger : .base)
    }
}

/// Ephemeral local input mirror. Touch owners retain the trigger selected on down,
/// so rebinding during a hold cannot strand the display on the wrong layer.
public struct ThumbleActionSetInputState: Sendable {
    private struct Owner: Hashable, Sendable {
        let input: String
        let pressIdentifier: UInt64?
    }
    private var digital: [Owner: Set<VirtualGamepadButton>] = [:]
    private var analog: Set<VirtualGamepadTrigger> = []

    public init() {}

    public var actionSet: ThumbleActionSet {
        let buttons = digital.values.reduce(into: Set<VirtualGamepadButton>()) { $0.formUnion($1) }
        return ThumbleActionSet(
            leftHeld: analog.contains(.left) || buttons.contains(.leftTriggerButton),
            rightHeld: analog.contains(.right) || buttons.contains(.rightTriggerButton)
        )
    }

    public mutating func record(input: String, pressed: Bool, pressIdentifier: UInt64? = nil,
                                buttons: Set<VirtualGamepadButton>) {
        let owner = Owner(input: input, pressIdentifier: pressIdentifier)
        if pressed {
            // Repeated refresh/down edges are idempotent, even if a non-trigger is rebound during a hold.
            guard digital[owner] == nil else { return }
            let triggers = buttons.intersection([.leftTriggerButton, .rightTriggerButton])
            digital[owner] = triggers
        } else {
            digital.removeValue(forKey: owner)
        }
    }

    public mutating func record(trigger: VirtualGamepadTrigger, value: Double) {
        // Display activation threshold for analog inputs; digital held buttons have no threshold.
        if value.isFinite && value > 0.5 { analog.insert(trigger) }
        else { analog.remove(trigger) }
    }

    public mutating func reset() {
        digital.removeAll()
        analog.removeAll()
    }
}


public struct ThumbleNormalizedRect: Codable, Equatable, Sendable {
    public var x: CGFloat
    public var y: CGFloat
    public var width: CGFloat
    public var height: CGFloat

    public init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var normalized: ThumbleNormalizedRect {
        let width = Self.clamp(self.width, 0, 1)
        let height = Self.clamp(self.height, 0, 1)
        return ThumbleNormalizedRect(
            x: Self.clamp(x, 0, 1 - width),
            y: Self.clamp(y, 0, 1 - height),
            width: width,
            height: height
        )
    }

    private static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        guard value.isFinite else { return lower }
        return min(max(value, lower), max(lower, upper))
    }
}

public struct ThumbleNormalizedInsets: Codable, Equatable, Sendable {
    public var top: CGFloat
    public var leading: CGFloat
    public var bottom: CGFloat
    public var trailing: CGFloat

    public init(top: CGFloat = 0, leading: CGFloat = 0, bottom: CGFloat = 0, trailing: CGFloat = 0) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }

    public var normalized: ThumbleNormalizedInsets {
        ThumbleNormalizedInsets(
            top: Self.clamp(top),
            leading: Self.clamp(leading),
            bottom: Self.clamp(bottom),
            trailing: Self.clamp(trailing)
        )
    }

    private static func clamp(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 0.45)
    }
}


public enum ThumbleSkinColorScheme: String, Codable, CaseIterable, Identifiable, Sendable {
    case light
    case dark

    public var id: String { rawValue }
}
