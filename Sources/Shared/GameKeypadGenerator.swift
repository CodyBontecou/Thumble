import Foundation
import CoreGraphics

public enum GeneratedKeypadConfidence: String, Codable, Sendable {
    case high
    case medium
    case low
}

public struct GeneratedKeyBindingSpec: Codable, Equatable, Sendable {
    public var key: String
    public var modifiers: [String]

    public init(key: String, modifiers: [String] = []) {
        self.key = key
        self.modifiers = modifiers
    }
}

public struct GeneratedGameKeypadProfile: Codable, Equatable, Sendable {
    public var requestedGameName: String
    public var resolvedGameName: String
    public var profile: GamepadConfigurationProfile
    public var keyBindings: [GameButton: GeneratedKeyBindingSpec]
    public var source: String
    public var confidence: GeneratedKeypadConfidence
    public var notes: [String]

    public init(
        requestedGameName: String,
        resolvedGameName: String,
        profile: GamepadConfigurationProfile,
        keyBindings: [GameButton: GeneratedKeyBindingSpec],
        source: String,
        confidence: GeneratedKeypadConfidence,
        notes: [String] = []
    ) {
        self.requestedGameName = requestedGameName
        self.resolvedGameName = resolvedGameName
        self.profile = profile
        self.keyBindings = keyBindings
        self.source = source
        self.confidence = confidence
        self.notes = notes
    }
}

public enum AgentKeypadControlRole: String, Codable, CaseIterable, Sendable {
    case movement
    case primary
    case secondary
    case utility
    case system
}

public struct AgentKeypadControlSpec: Codable, Equatable, Sendable {
    public var id: String?
    public var button: GameButton?
    public var label: String
    public var key: String
    public var modifiers: [String]
    public var role: AgentKeypadControlRole?
    public var centerX: CGFloat?
    public var centerY: CGFloat?
    public var widthScale: CGFloat?
    public var heightScale: CGFloat?
    public var shape: GamepadButtonShapeStyle?
    public var accentStyle: GamepadAccentStyle?
    public var fillColor: GamepadRGBAColor?
    public var joystickKnobColor: GamepadRGBAColor?
    public var joystickVisualStyle: GamepadJoystickVisualStyle?
    public var styleID: String?
    public var visualStyle: GamepadControlVisualStyle?
    public var icon: GamepadControlIcon?
    public var hapticStyle: GamepadHapticStyle?
    public var hapticFeedback: GamepadHapticFeedback?
    public var cornerRadius: CGFloat?
    public var shadowStrength: CGFloat?
    public var isHidden: Bool?
    public var isLocationLocked: Bool?
    public var controlKind: GamepadCustomControlKind?
    public var joystickMapping: GamepadJoystickMapping?
    public var trackpadSettings: GamepadTrackpadSettings?

    public init(
        id: String? = nil,
        button: GameButton? = nil,
        label: String,
        key: String,
        modifiers: [String] = [],
        role: AgentKeypadControlRole? = nil,
        centerX: CGFloat? = nil,
        centerY: CGFloat? = nil,
        widthScale: CGFloat? = nil,
        heightScale: CGFloat? = nil,
        shape: GamepadButtonShapeStyle? = nil,
        accentStyle: GamepadAccentStyle? = nil,
        fillColor: GamepadRGBAColor? = nil,
        joystickKnobColor: GamepadRGBAColor? = nil,
        joystickVisualStyle: GamepadJoystickVisualStyle? = nil,
        styleID: String? = nil,
        visualStyle: GamepadControlVisualStyle? = nil,
        icon: GamepadControlIcon? = nil,
        hapticStyle: GamepadHapticStyle? = nil,
        hapticFeedback: GamepadHapticFeedback? = nil,
        cornerRadius: CGFloat? = nil,
        shadowStrength: CGFloat? = nil,
        isHidden: Bool? = nil,
        isLocationLocked: Bool? = nil,
        controlKind: GamepadCustomControlKind? = nil,
        joystickMapping: GamepadJoystickMapping? = nil,
        trackpadSettings: GamepadTrackpadSettings? = nil
    ) {
        self.id = id
        self.button = button
        self.label = label
        self.key = key
        self.modifiers = modifiers
        self.role = role
        self.centerX = centerX
        self.centerY = centerY
        self.widthScale = widthScale
        self.heightScale = heightScale
        self.shape = shape
        self.accentStyle = accentStyle
        self.fillColor = fillColor
        self.joystickKnobColor = joystickKnobColor
        self.joystickVisualStyle = joystickVisualStyle
        self.styleID = styleID
        self.visualStyle = visualStyle
        self.icon = icon
        self.hapticStyle = hapticStyle
        self.hapticFeedback = hapticFeedback
        self.cornerRadius = cornerRadius
        self.shadowStrength = shadowStrength
        self.isHidden = isHidden
        self.isLocationLocked = isLocationLocked
        self.controlKind = controlKind
        self.joystickMapping = joystickMapping
        self.trackpadSettings = trackpadSettings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        button = try container.decodeIfPresent(GameButton.self, forKey: .button)
        if button == nil, let id, let idButton = GameButton(rawValue: id) {
            button = idButton
        }
        label = try container.decodeIfPresent(String.self, forKey: .label)
            ?? button?.displayName
            ?? id
            ?? "Button"
        key = try container.decodeIfPresent(String.self, forKey: .key) ?? ""
        modifiers = try container.decodeIfPresent([String].self, forKey: .modifiers) ?? []
        role = try container.decodeIfPresent(AgentKeypadControlRole.self, forKey: .role)
        centerX = try container.decodeIfPresent(CGFloat.self, forKey: .centerX)
            ?? container.decodeIfPresent(CGFloat.self, forKey: .x)
        centerY = try container.decodeIfPresent(CGFloat.self, forKey: .centerY)
            ?? container.decodeIfPresent(CGFloat.self, forKey: .y)
        widthScale = try container.decodeIfPresent(CGFloat.self, forKey: .widthScale)
            ?? container.decodeIfPresent(CGFloat.self, forKey: .width)
        heightScale = try container.decodeIfPresent(CGFloat.self, forKey: .heightScale)
            ?? container.decodeIfPresent(CGFloat.self, forKey: .height)
        shape = try container.decodeIfPresent(GamepadButtonShapeStyle.self, forKey: .shape)
        accentStyle = try container.decodeIfPresent(GamepadAccentStyle.self, forKey: .accentStyle)
        fillColor = Self.decodeFillColor(from: container)
        joystickKnobColor = Self.decodeJoystickKnobColor(from: container)
        joystickVisualStyle = try Self.decodeJoystickVisualStyle(from: container)
        styleID = try container.decodeIfPresent(String.self, forKey: .styleID)
        visualStyle = try Self.decodeVisualStyle(from: container)
        icon = try Self.decodeIcon(from: container)
        hapticStyle = try container.decodeIfPresent(GamepadHapticStyle.self, forKey: .hapticStyle)
        hapticFeedback = try Self.decodeHapticFeedback(from: container, hapticStyle: hapticStyle)
        if hapticStyle == nil { hapticStyle = hapticFeedback?.style }
        cornerRadius = try container.decodeIfPresent(CGFloat.self, forKey: .cornerRadius)
        shadowStrength = try container.decodeIfPresent(CGFloat.self, forKey: .shadowStrength)
        isHidden = try container.decodeIfPresent(Bool.self, forKey: .isHidden)
        isLocationLocked = try container.decodeIfPresent(Bool.self, forKey: .isLocationLocked)
        controlKind = try container.decodeIfPresent(GamepadCustomControlKind.self, forKey: .controlKind)
            ?? Self.decodeControlKindAlias(from: container, forKey: .kind)
        joystickMapping = try Self.decodeJoystickMapping(from: container)
        trackpadSettings = try Self.decodeTrackpadSettings(from: container)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(button, forKey: .button)
        try container.encode(label, forKey: .label)
        try container.encode(key, forKey: .key)
        try container.encode(modifiers, forKey: .modifiers)
        try container.encodeIfPresent(role, forKey: .role)
        try container.encodeIfPresent(centerX, forKey: .centerX)
        try container.encodeIfPresent(centerY, forKey: .centerY)
        try container.encodeIfPresent(widthScale, forKey: .widthScale)
        try container.encodeIfPresent(heightScale, forKey: .heightScale)
        try container.encodeIfPresent(shape, forKey: .shape)
        try container.encodeIfPresent(accentStyle, forKey: .accentStyle)
        try container.encodeIfPresent(fillColor, forKey: .fillColor)
        try container.encodeIfPresent(joystickKnobColor, forKey: .joystickKnobColor)
        try container.encodeIfPresent(joystickVisualStyle, forKey: .joystickVisualStyle)
        try container.encodeIfPresent(styleID, forKey: .styleID)
        try container.encodeIfPresent(visualStyle?.normalized, forKey: .visualStyle)
        try container.encodeIfPresent(icon?.normalized, forKey: .icon)
        try container.encodeIfPresent(hapticStyle, forKey: .hapticStyle)
        try container.encodeIfPresent(hapticFeedback?.normalized, forKey: .hapticFeedback)
        try container.encodeIfPresent(cornerRadius, forKey: .cornerRadius)
        try container.encodeIfPresent(shadowStrength, forKey: .shadowStrength)
        try container.encodeIfPresent(isHidden, forKey: .isHidden)
        try container.encodeIfPresent(isLocationLocked, forKey: .isLocationLocked)
        try container.encodeIfPresent(controlKind, forKey: .controlKind)
        try container.encodeIfPresent(joystickMapping, forKey: .joystickMapping)
        try container.encodeIfPresent(trackpadSettings?.normalized, forKey: .trackpadSettings)
    }

    private static func decodeFillColor(from container: KeyedDecodingContainer<CodingKeys>) -> GamepadRGBAColor? {
        if let color = try? container.decodeIfPresent(GamepadRGBAColor.self, forKey: .fillColor) {
            return color
        }

        for key in [CodingKeys.fillColor, .fill, .fillHex, .color] {
            if let hexString = try? container.decodeIfPresent(String.self, forKey: key),
               let color = GamepadRGBAColor(hexString: hexString) {
                return color
            }
        }

        return nil
    }

    private static func decodeJoystickKnobColor(from container: KeyedDecodingContainer<CodingKeys>) -> GamepadRGBAColor? {
        if let color = try? container.decodeIfPresent(GamepadRGBAColor.self, forKey: .joystickKnobColor) {
            return color
        }

        for key in [CodingKeys.joystickKnobColor, .knobColor, .thumbColor, .thumbFill, .joystickThumbFill, .joystickKnobFill] {
            if let hexString = try? container.decodeIfPresent(String.self, forKey: key),
               let color = GamepadRGBAColor(hexString: hexString) {
                return color
            }
        }

        return nil
    }

    private static func decodeJoystickVisualStyle(from container: KeyedDecodingContainer<CodingKeys>) throws -> GamepadJoystickVisualStyle? {
        if let explicit = try container.decodeIfPresent(GamepadJoystickVisualStyle.self, forKey: .joystickVisualStyle) {
            return explicit
        }
        for key in [CodingKeys.joystickStyle, .stickStyle] {
            if let raw = try? container.decodeIfPresent(String.self, forKey: key),
               let style = parseJoystickVisualStyle(raw) {
                return style
            }
        }
        if (try? container.decodeIfPresent(Bool.self, forKey: .thumbstick)) == true {
            return .thumbstick
        }
        return nil
    }

    private static func parseJoystickVisualStyle(_ text: String) -> GamepadJoystickVisualStyle? {
        let normalized = text.lowercased().filter { $0.isLetter || $0.isNumber }
        switch normalized {
        case "pad", "fullpad", "classic", "joystick": return .pad
        case "thumbstick", "thumb", "nub", "stickball", "ball": return .thumbstick
        default: return nil
        }
    }

    private static func decodeVisualStyle(from container: KeyedDecodingContainer<CodingKeys>) throws -> GamepadControlVisualStyle? {
        if let explicit = try container.decodeIfPresent(GamepadControlVisualStyle.self, forKey: .visualStyle) {
            return explicit.normalized
        }

        var style = if let material = try container.decodeIfPresent(String.self, forKey: .material) ?? container.decodeIfPresent(String.self, forKey: .materialPreset),
                       let materialStyle = materialVisualStyle(material) {
            materialStyle
        } else {
            GamepadControlVisualStyle.empty
        }
        var normal = style.normal
        if let strokeColor = decodeHexColor(from: container, keys: [.stroke, .strokeColor]) {
            normal.strokeColor = strokeColor
        }
        if let foregroundColor = decodeHexColor(from: container, keys: [.foreground, .foregroundColor, .textColor]) {
            normal.foregroundColor = foregroundColor
        }
        if let strokeWidth = try container.decodeIfPresent(CGFloat.self, forKey: .strokeWidth) {
            normal.strokeWidth = strokeWidth
        }
        if let shadows = try container.decodeIfPresent([GamepadControlShadowStyle].self, forKey: .shadows) {
            normal.shadows = shadows
        }
        if let glowColor = decodeHexColor(from: container, keys: [.glow, .glowColor]) {
            normal.glowColor = glowColor
        }
        if let glowRadius = try container.decodeIfPresent(CGFloat.self, forKey: .glowRadius) {
            normal.glowRadius = glowRadius
        }
        if let innerShadowColor = decodeHexColor(from: container, keys: [.innerShadow, .innerShadowColor]) {
            normal.innerShadowColor = innerShadowColor
        }
        if let innerShadowRadius = try container.decodeIfPresent(CGFloat.self, forKey: .innerShadowRadius) {
            normal.innerShadowRadius = innerShadowRadius
        }
        if let innerShadowX = try container.decodeIfPresent(CGFloat.self, forKey: .innerShadowX) {
            normal.innerShadowX = innerShadowX
        }
        if let innerShadowY = try container.decodeIfPresent(CGFloat.self, forKey: .innerShadowY) {
            normal.innerShadowY = innerShadowY
        }
        if let highlightColor = decodeHexColor(from: container, keys: [.highlight, .highlightColor]) {
            normal.highlightColor = highlightColor
        }
        if let highlightRadius = try container.decodeIfPresent(CGFloat.self, forKey: .highlightRadius) {
            normal.highlightRadius = highlightRadius
        }
        if let highlightX = try container.decodeIfPresent(CGFloat.self, forKey: .highlightX) {
            normal.highlightX = highlightX
        }
        if let highlightY = try container.decodeIfPresent(CGFloat.self, forKey: .highlightY) {
            normal.highlightY = highlightY
        }
        if let highlightOpacity = try container.decodeIfPresent(CGFloat.self, forKey: .highlightOpacity) {
            normal.highlightOpacity = highlightOpacity
        }
        if let bevelHighlightColor = decodeHexColor(from: container, keys: [.bevelHighlight, .bevelHighlightColor]) {
            normal.bevelHighlightColor = bevelHighlightColor
        }
        if let bevelShadowColor = decodeHexColor(from: container, keys: [.bevelShadow, .bevelShadowColor]) {
            normal.bevelShadowColor = bevelShadowColor
        }
        if let bevelWidth = try container.decodeIfPresent(CGFloat.self, forKey: .bevelWidth) {
            normal.bevelWidth = bevelWidth
        }
        if let opacity = try container.decodeIfPresent(CGFloat.self, forKey: .opacity) {
            normal.opacity = opacity
        }

        var pressed = style.pressed
        if let pressedFill = decodeHexColor(from: container, keys: [.pressedFill, .pressedColor]) {
            var pressedStyle = pressed ?? .empty
            pressedStyle.fillStyle = .solid(pressedFill)
            pressed = pressedStyle
        }

        style.normal = normal
        style.pressed = pressed
        return style.normalized
    }

    private static func materialVisualStyle(_ text: String) -> GamepadControlVisualStyle? {
        let normalized = text.lowercased().filter { $0.isLetter || $0.isNumber }
        switch normalized {
        case "softwhite", "softwhiteraised", "raised", "neumorphic", "neumorphicraised":
            return .softWhiteRaised()
        case "softwhiteinset", "inset", "recessed", "well":
            return .softWhiteInset()
        case "softwhiteplate", "plate", "panel", "shell":
            return .softWhitePlate()
        default:
            return nil
        }
    }

    private static func decodeIcon(from container: KeyedDecodingContainer<CodingKeys>) throws -> GamepadControlIcon? {
        if let explicit = try container.decodeIfPresent(GamepadControlIcon.self, forKey: .icon) {
            return explicit.normalized
        }
        if let symbol = try container.decodeIfPresent(String.self, forKey: .sfSymbol) {
            return GamepadControlIcon.sfSymbol(symbol).normalized
        }
        if let text = try container.decodeIfPresent(String.self, forKey: .iconText) {
            return GamepadControlIcon.text(text).normalized
        }
        if let shorthand = try container.decodeIfPresent(String.self, forKey: .iconName) {
            if shorthand.hasPrefix("sf:") {
                return GamepadControlIcon.sfSymbol(String(shorthand.dropFirst(3))).normalized
            }
            if shorthand.hasPrefix("text:") {
                return GamepadControlIcon.text(String(shorthand.dropFirst(5))).normalized
            }
            return GamepadControlIcon.sfSymbol(shorthand).normalized
        }
        return nil
    }

    private static func decodeHapticFeedback(from container: KeyedDecodingContainer<CodingKeys>, hapticStyle: GamepadHapticStyle?) throws -> GamepadHapticFeedback? {
        if var explicit = try container.decodeIfPresent(GamepadHapticFeedback.self, forKey: .hapticFeedback) {
            if let hapticStyle { explicit.style = hapticStyle }
            return explicit.normalized
        }

        let pattern = try container.decodeIfPresent(GamepadHapticPattern.self, forKey: .hapticPattern)
        let intensity = try container.decodeIfPresent(CGFloat.self, forKey: .hapticIntensity)
            ?? container.decodeIfPresent(CGFloat.self, forKey: .hapticStrength)
        let sharpness = try container.decodeIfPresent(CGFloat.self, forKey: .hapticSharpness)
        let duration = try container.decodeIfPresent(CGFloat.self, forKey: .hapticDuration)
            ?? container.decodeIfPresent(CGFloat.self, forKey: .hapticDurationMS).map { $0 / 1_000 }

        guard hapticStyle != nil || pattern != nil || intensity != nil || sharpness != nil || duration != nil else {
            return nil
        }

        var feedback = GamepadHapticFeedback(style: hapticStyle ?? .light)
        if let pattern { feedback.pattern = pattern }
        if let intensity { feedback.intensity = intensity }
        if let sharpness { feedback.sharpness = sharpness }
        if let duration { feedback.duration = duration }
        return feedback.normalized
    }

    private static func decodeHexColor(from container: KeyedDecodingContainer<CodingKeys>, keys: [CodingKeys]) -> GamepadRGBAColor? {
        for key in keys {
            if let color = try? container.decodeIfPresent(GamepadRGBAColor.self, forKey: key) {
                return color
            }
            if let hexString = try? container.decodeIfPresent(String.self, forKey: key), let color = GamepadRGBAColor(hexString: hexString) {
                return color
            }
        }
        return nil
    }

    private static func decodeControlKindAlias(from container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> GamepadCustomControlKind? {
        guard let rawValue = try? container.decodeIfPresent(String.self, forKey: key) else { return nil }
        if let kind = GamepadCustomControlKind(rawValue: rawValue) { return kind }
        let normalized = rawValue.lowercased().filter { $0.isLetter || $0.isNumber }
        switch normalized {
        case "shape": return .button
        case "stick": return .joystick
        case "touchpad", "cursorpad": return .trackpad
        case "decor", "visual", "plate", "panel", "ring": return .decoration
        default: return nil
        }
    }

    private static func decodeGameButtonAlias(from container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> GameButton? {
        guard let rawValue = try? container.decodeIfPresent(String.self, forKey: key) else { return nil }
        return GameButton(rawValue: rawValue)
    }

    private static func decodeJoystickMapping(from container: KeyedDecodingContainer<CodingKeys>) throws -> GamepadJoystickMapping? {
        let explicitMapping = try container.decodeIfPresent(GamepadJoystickMapping.self, forKey: .joystickMapping)
        let up = decodeGameButtonAlias(from: container, forKey: .up)
        let down = decodeGameButtonAlias(from: container, forKey: .down)
        let left = decodeGameButtonAlias(from: container, forKey: .left)
        let right = decodeGameButtonAlias(from: container, forKey: .right)

        guard up != nil || down != nil || left != nil || right != nil else {
            return explicitMapping
        }

        let baseMapping = explicitMapping ?? .movement
        return GamepadJoystickMapping(
            up: up ?? baseMapping.up,
            down: down ?? baseMapping.down,
            left: left ?? baseMapping.left,
            right: right ?? baseMapping.right
        )
    }

    private static func decodeTrackpadSettings(from container: KeyedDecodingContainer<CodingKeys>) throws -> GamepadTrackpadSettings? {
        let explicitSettings = try container.decodeIfPresent(GamepadTrackpadSettings.self, forKey: .trackpadSettings)
        let sensitivity = try container.decodeIfPresent(CGFloat.self, forKey: .sensitivity)
            ?? container.decodeIfPresent(CGFloat.self, forKey: .cursorSensitivity)
            ?? container.decodeIfPresent(CGFloat.self, forKey: .pointerSensitivity)
        let scrollSensitivity = try container.decodeIfPresent(CGFloat.self, forKey: .scrollSensitivity)
        let tapToClick = try container.decodeIfPresent(Bool.self, forKey: .tapToClick)
        let twoFingerScroll = try container.decodeIfPresent(Bool.self, forKey: .twoFingerScroll)
        let naturalScrolling = try container.decodeIfPresent(Bool.self, forKey: .naturalScrolling)
            ?? container.decodeIfPresent(Bool.self, forKey: .naturalScroll)

        guard sensitivity != nil || scrollSensitivity != nil || tapToClick != nil || twoFingerScroll != nil || naturalScrolling != nil else {
            return explicitSettings?.normalized
        }

        let base = explicitSettings ?? .defaultValue
        return GamepadTrackpadSettings(
            sensitivity: sensitivity ?? base.sensitivity,
            scrollSensitivity: scrollSensitivity ?? base.scrollSensitivity,
            tapToClick: tapToClick ?? base.tapToClick,
            twoFingerScroll: twoFingerScroll ?? base.twoFingerScroll,
            naturalScrolling: naturalScrolling ?? base.naturalScrolling
        ).normalized
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case button
        case label
        case key
        case modifiers
        case role
        case centerX
        case centerY
        case x
        case y
        case widthScale
        case heightScale
        case width
        case height
        case shape
        case accentStyle
        case fillColor
        case fill
        case fillHex
        case color
        case joystickKnobColor
        case knobColor
        case thumbColor
        case thumbFill
        case joystickThumbFill
        case joystickKnobFill
        case joystickVisualStyle
        case joystickStyle
        case stickStyle
        case thumbstick
        case styleID
        case visualStyle
        case icon
        case iconName
        case sfSymbol
        case iconText
        case hapticStyle
        case hapticFeedback
        case hapticPattern
        case hapticIntensity
        case hapticStrength
        case hapticSharpness
        case hapticDuration
        case hapticDurationMS
        case stroke
        case strokeColor
        case strokeWidth
        case foreground
        case foregroundColor
        case textColor
        case material
        case materialPreset
        case shadows
        case glow
        case glowColor
        case glowRadius
        case innerShadow
        case innerShadowColor
        case innerShadowRadius
        case innerShadowX
        case innerShadowY
        case highlight
        case highlightColor
        case highlightRadius
        case highlightX
        case highlightY
        case highlightOpacity
        case bevelHighlight
        case bevelHighlightColor
        case bevelShadow
        case bevelShadowColor
        case bevelWidth
        case pressedFill
        case pressedColor
        case opacity
        case cornerRadius
        case shadowStrength
        case isHidden
        case isLocationLocked
        case controlKind
        case kind
        case joystickMapping
        case up
        case down
        case left
        case right
        case trackpadSettings
        case sensitivity
        case cursorSensitivity
        case pointerSensitivity
        case scrollSensitivity
        case tapToClick
        case twoFingerScroll
        case naturalScrolling
        case naturalScroll
    }
}

public struct AgentKeypadSpec: Codable, Equatable, Sendable {
    public var gameName: String
    public var source: String?
    public var confidence: GeneratedKeypadConfidence?
    public var notes: [String]
    public var controls: [AgentKeypadControlSpec]

    public init(
        gameName: String,
        source: String? = nil,
        confidence: GeneratedKeypadConfidence? = nil,
        notes: [String] = [],
        controls: [AgentKeypadControlSpec]
    ) {
        self.gameName = gameName
        self.source = source
        self.confidence = confidence
        self.notes = notes
        self.controls = controls
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gameName = try container.decodeIfPresent(String.self, forKey: .gameName)
            ?? container.decodeIfPresent(String.self, forKey: .name)
            ?? container.decodeIfPresent(String.self, forKey: .game)
            ?? "Agent Generated Game"
        source = try container.decodeIfPresent(String.self, forKey: .source)
        confidence = try container.decodeIfPresent(GeneratedKeypadConfidence.self, forKey: .confidence)
        notes = try container.decodeIfPresent([String].self, forKey: .notes) ?? []
        controls = try container.decode([AgentKeypadControlSpec].self, forKey: .controls)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(gameName, forKey: .gameName)
        try container.encodeIfPresent(source, forKey: .source)
        try container.encodeIfPresent(confidence, forKey: .confidence)
        try container.encode(notes, forKey: .notes)
        try container.encode(controls, forKey: .controls)
    }

    private enum CodingKeys: String, CodingKey {
        case gameName
        case name
        case game
        case source
        case confidence
        case notes
        case controls
    }
}

public enum GameKeypadGenerator {
    public static func generate(for requestedGameName: String) -> GeneratedGameKeypadProfile? {
        let cleanedName = requestedGameName.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = cleanedName.isEmpty ? "Generated Game" : cleanedName

        if HollowKnightTemplate.matches(displayName) {
            return HollowKnightTemplate.make(requestedGameName: displayName)
        }

        return nil
    }

    public static func generate(from spec: AgentKeypadSpec, requestedGameName: String? = nil) -> GeneratedGameKeypadProfile {
        AgentSpecTemplate.make(spec: spec, requestedGameName: requestedGameName)
    }
}

private enum KeypadRole {
    case movement
    case primary
    case secondary
    case utility
    case system

    init(_ agentRole: AgentKeypadControlRole) {
        switch agentRole {
        case .movement: self = .movement
        case .primary: self = .primary
        case .secondary: self = .secondary
        case .utility: self = .utility
        case .system: self = .system
        }
    }

    var fillColor: GamepadRGBAColor {
        switch self {
        case .movement:
            GamepadRGBAColor(hexString: "#1F2937") ?? .defaultValue
        case .primary:
            GamepadRGBAColor(hexString: "#7C3AED") ?? .defaultValue
        case .secondary:
            GamepadRGBAColor(hexString: "#0EA5E9") ?? .defaultValue
        case .utility:
            GamepadRGBAColor(hexString: "#6B7280") ?? .defaultValue
        case .system:
            GamepadRGBAColor(hexString: "#374151") ?? .defaultValue
        }
    }

    var accentStyle: GamepadAccentStyle {
        switch self {
        case .movement, .system: .monochrome
        case .primary: .purple
        case .secondary: .blue
        case .utility: .monochrome
        }
    }
}

private struct GeneratedControlDefinition {
    var button: GameButton
    var label: String
    var binding: GeneratedKeyBindingSpec
    var role: KeypadRole
    var centerX: CGFloat
    var centerY: CGFloat
    var widthScale: CGFloat
    var heightScale: CGFloat
    var shape: GamepadButtonShapeStyle
    var fillColor: GamepadRGBAColor?
    var joystickKnobColor: GamepadRGBAColor?
    var joystickVisualStyle: GamepadJoystickVisualStyle?
    var styleID: String?
    var visualStyle: GamepadControlVisualStyle?
    var icon: GamepadControlIcon?
    var hapticStyle: GamepadHapticStyle?
    var hapticFeedback: GamepadHapticFeedback?
    var accentStyle: GamepadAccentStyle?
    var cornerRadius: CGFloat?
    var shadowStrength: CGFloat?
    var isHidden: Bool?
    var isLocationLocked: Bool?
    var controlKind: GamepadCustomControlKind?
    var joystickMapping: GamepadJoystickMapping?
    var trackpadSettings: GamepadTrackpadSettings?

    init(
        _ button: GameButton,
        label: String,
        key: String,
        modifiers: [String] = [],
        role: KeypadRole,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat = 1.0,
        height: CGFloat = 1.0,
        shape: GamepadButtonShapeStyle = .roundedRectangle,
        fill: String? = nil,
        fillColor: GamepadRGBAColor? = nil,
        joystickKnobColor: GamepadRGBAColor? = nil,
        joystickVisualStyle: GamepadJoystickVisualStyle? = nil,
        styleID: String? = nil,
        visualStyle: GamepadControlVisualStyle? = nil,
        icon: GamepadControlIcon? = nil,
        hapticStyle: GamepadHapticStyle? = nil,
        hapticFeedback: GamepadHapticFeedback? = nil,
        accentStyle: GamepadAccentStyle? = nil,
        cornerRadius: CGFloat? = nil,
        shadowStrength: CGFloat? = nil,
        isHidden: Bool? = nil,
        isLocationLocked: Bool? = nil,
        controlKind: GamepadCustomControlKind? = nil,
        joystickMapping: GamepadJoystickMapping? = nil,
        trackpadSettings: GamepadTrackpadSettings? = nil
    ) {
        self.button = button
        self.label = label
        self.binding = GeneratedKeyBindingSpec(key: key, modifiers: modifiers)
        self.role = role
        self.centerX = x
        self.centerY = y
        self.widthScale = width
        self.heightScale = height
        self.shape = shape
        self.fillColor = fillColor ?? fill.flatMap { GamepadRGBAColor(hexString: $0) }
        self.joystickKnobColor = joystickKnobColor
        self.joystickVisualStyle = joystickVisualStyle
        self.styleID = styleID
        self.visualStyle = visualStyle
        self.icon = icon
        self.hapticStyle = hapticStyle
        self.hapticFeedback = hapticFeedback
        self.accentStyle = accentStyle
        self.cornerRadius = cornerRadius
        self.shadowStrength = shadowStrength
        self.isHidden = isHidden
        self.isLocationLocked = isLocationLocked
        self.controlKind = controlKind
        self.joystickMapping = joystickMapping
        self.trackpadSettings = trackpadSettings
    }
}

private enum GeneratedProfileBuilder {
    static func build(
        requestedGameName: String,
        resolvedGameName: String,
        controls: [GeneratedControlDefinition],
        source: String,
        confidence: GeneratedKeypadConfidence,
        notes: [String],
        controlScale: GamepadControlScale = .standard,
        accentStyle: GamepadAccentStyle = .purple
    ) -> GeneratedGameKeypadProfile {
        var customization = GamepadCustomization.blankCanvas
        customization.layoutMode = .standard
        customization.controlScale = controlScale
        customization.accentStyle = accentStyle
        customization.showsButtonLabels = true

        var keyBindings: [GameButton: GeneratedKeyBindingSpec] = [:]
        var customButtons: [GamepadCustomButton] = []

        for control in controls {
            let layout = GamepadButtonCustomization(
                centerX: control.centerX,
                centerY: control.centerY,
                widthScale: control.widthScale,
                heightScale: control.heightScale,
                shape: control.shape,
                accentStyle: control.accentStyle ?? control.role.accentStyle,
                fillColor: control.fillColor ?? control.role.fillColor,
                joystickKnobColor: control.joystickKnobColor,
                joystickVisualStyle: control.joystickVisualStyle,
                styleID: control.styleID,
                visualStyle: control.visualStyle,
                icon: control.icon,
                hapticStyle: control.hapticStyle,
                hapticFeedback: control.hapticFeedback,
                cornerRadius: control.cornerRadius ?? resolvedCornerRadius(for: control.shape),
                shadowStrength: control.shadowStrength ?? (control.role == .primary ? 1.25 : 1.0),
                isLocationLocked: control.isLocationLocked ?? false,
                isHidden: control.isHidden ?? false
            )

            let controlKind = control.controlKind ?? (control.trackpadSettings == nil ? (control.joystickMapping == nil ? .button : .joystick) : .trackpad)
            if GameButton.builtInControls.contains(control.button), controlKind == .button {
                customization.setButtonCustomization(layout, for: control.button)
                customization.setLabel(control.label, for: control.button)
            } else {
                customButtons.append(
                    GamepadCustomButton(
                        mappedButton: control.button,
                        label: control.label,
                        layout: layout,
                        controlKind: controlKind,
                        joystickMapping: controlKind == .joystick ? (control.joystickMapping ?? .movement) : nil,
                        trackpadSettings: controlKind == .trackpad ? (control.trackpadSettings ?? .defaultValue).normalized : nil
                    )
                )
            }

            if controlKind != .decoration,
               controlKind != .text,
               !control.binding.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                keyBindings[control.button] = control.binding
            }
        }

        customization.customButtons = customButtons
        customization.updatedAt = Date.currentMilliseconds

        let profile = GamepadConfigurationProfile(
            name: resolvedGameName,
            primaryCustomization: customization.normalized
        )

        return GeneratedGameKeypadProfile(
            requestedGameName: requestedGameName,
            resolvedGameName: resolvedGameName,
            profile: profile,
            keyBindings: keyBindings,
            source: source,
            confidence: confidence,
            notes: notes
        )
    }

    private static func resolvedCornerRadius(for shape: GamepadButtonShapeStyle) -> CGFloat? {
        switch shape {
        case .capsule, .circle, .ellipse:
            nil
        default:
            12
        }
    }
}

private enum AgentSpecTemplate {
    private struct LayoutDefaults {
        var x: CGFloat
        var y: CGFloat
        var width: CGFloat
        var height: CGFloat
        var shape: GamepadButtonShapeStyle
    }

    static func make(spec: AgentKeypadSpec, requestedGameName: String?) -> GeneratedGameKeypadProfile {
        var usedButtons = Set<GameButton>()
        var roleCounts: [KeypadRole: Int] = [:]
        var controls: [GeneratedControlDefinition] = []

        for controlSpec in spec.controls {
            guard let button = assignButton(for: controlSpec, usedButtons: usedButtons) else { continue }
            usedButtons.insert(button)

            let controlKind = inferredControlKind(for: controlSpec)
            let role = inferRole(for: controlSpec, button: button)
            let roleIndex = roleCounts[role, default: 0]
            roleCounts[role] = roleIndex + 1
            let defaults = if controlKind == .trackpad {
                trackpadLayoutDefaults()
            } else if controlKind == .joystick {
                joystickLayoutDefaults(style: controlSpec.joystickVisualStyle)
            } else {
                layoutDefaults(for: button, role: role, index: roleIndex)
            }
            let label = controlSpec.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? (controlKind == .trackpad ? "Trackpad" : button.displayName)
                : controlSpec.label

            controls.append(
                GeneratedControlDefinition(
                    button,
                    label: label,
                    key: controlSpec.key,
                    modifiers: controlSpec.modifiers,
                    role: role,
                    x: controlSpec.centerX ?? defaults.x,
                    y: controlSpec.centerY ?? defaults.y,
                    width: controlSpec.widthScale ?? defaults.width,
                    height: controlSpec.heightScale ?? defaults.height,
                    shape: controlSpec.shape ?? defaults.shape,
                    fillColor: controlSpec.fillColor,
                    joystickKnobColor: controlSpec.joystickKnobColor,
                    joystickVisualStyle: controlSpec.joystickVisualStyle,
                    styleID: controlSpec.styleID,
                    visualStyle: controlSpec.visualStyle,
                    icon: controlSpec.icon,
                    hapticStyle: controlSpec.hapticStyle,
                    hapticFeedback: controlSpec.hapticFeedback,
                    accentStyle: controlSpec.accentStyle,
                    cornerRadius: controlSpec.cornerRadius ?? (controlKind == .trackpad ? 18 : nil),
                    shadowStrength: controlSpec.shadowStrength,
                    isHidden: controlSpec.isHidden,
                    isLocationLocked: controlSpec.isLocationLocked,
                    controlKind: controlKind,
                    joystickMapping: controlSpec.joystickMapping,
                    trackpadSettings: controlSpec.trackpadSettings
                )
            )
        }

        let resolvedName = normalizedDisplayName(spec.gameName, fallback: requestedGameName ?? "Agent Generated Game")
        var notes = spec.notes
        if notes.isEmpty {
            notes = ["Installed from an agent-provided keypad spec."]
        }

        return GeneratedProfileBuilder.build(
            requestedGameName: requestedGameName ?? resolvedName,
            resolvedGameName: resolvedName,
            controls: controls,
            source: spec.source ?? "Agent-provided keypad spec",
            confidence: spec.confidence ?? .low,
            notes: notes
        )
    }

    private static func inferredControlKind(for control: AgentKeypadControlSpec) -> GamepadCustomControlKind? {
        if let controlKind = control.controlKind { return controlKind }
        if control.trackpadSettings != nil { return .trackpad }
        if control.joystickMapping != nil || control.joystickVisualStyle != nil { return .joystick }
        return nil
    }

    private static func assignButton(for control: AgentKeypadControlSpec, usedButtons: Set<GameButton>) -> GameButton? {
        if let button = control.button, !usedButtons.contains(button) {
            return button
        }

        if let controlKind = inferredControlKind(for: control), controlKind != .button {
            return GameButton.customSlots.first { !usedButtons.contains($0) }
        }

        let normalized = normalizedControlText(control)
        let preferredButton: GameButton? = {
            if normalized.contains("left") || normalized.contains("arrowleft") { return .left }
            if normalized.contains("right") || normalized.contains("arrowright") { return .right }
            if normalized.contains("up") || normalized.contains("arrowup") { return .up }
            if normalized.contains("down") || normalized.contains("arrowdown") { return .down }
            if normalized.contains("jump") { return .jump }
            if normalized.contains("attack") || normalized.contains("nail") || normalized.contains("fire") || normalized.contains("shoot") { return .attack }
            if normalized.contains("dash") || normalized.contains("dodge") || normalized.contains("sprint") { return .dash }
            if normalized.contains("focus") || normalized.contains("cast") || normalized.contains("special") || normalized.contains("magic") { return .focus }
            if normalized.contains("map") { return .map }
            if normalized.contains("pause") || normalized.contains("escape") || normalized.contains("menu") { return .pause }
            return nil
        }()

        if let preferredButton, !usedButtons.contains(preferredButton) {
            return preferredButton
        }

        return GameButton.customSlots.first { !usedButtons.contains($0) }
    }

    private static func inferRole(for control: AgentKeypadControlSpec, button: GameButton) -> KeypadRole {
        if let role = control.role {
            return KeypadRole(role)
        }

        if let controlKind = inferredControlKind(for: control), controlKind != .button {
            return .movement
        }

        switch button {
        case .up, .down, .left, .right:
            return .movement
        case .jump, .attack, .dash:
            return .primary
        case .focus:
            return .secondary
        case .map:
            return .utility
        case .pause:
            return .system
        case .custom1, .custom2, .custom3, .custom4, .custom5, .custom6, .custom7, .custom8:
            break
        }

        let normalized = normalizedControlText(control)
        if normalized.contains("inventory") || normalized.contains("map") || normalized.contains("item") {
            return .utility
        }
        if normalized.contains("pause") || normalized.contains("escape") || normalized.contains("menu") {
            return .system
        }
        if normalized.contains("focus") || normalized.contains("cast") || normalized.contains("special") || normalized.contains("magic") {
            return .secondary
        }
        return .primary
    }

    private static func trackpadLayoutDefaults() -> LayoutDefaults {
        LayoutDefaults(x: 0.50, y: 0.58, width: 1.25, height: 1.0, shape: .roundedRectangle)
    }

    private static func joystickLayoutDefaults(style: GamepadJoystickVisualStyle?) -> LayoutDefaults {
        switch style ?? .pad {
        case .pad:
            LayoutDefaults(x: 0.22, y: 0.64, width: 1.35, height: 1.35, shape: .circle)
        case .thumbstick:
            LayoutDefaults(x: 0.50, y: 0.62, width: 0.58, height: 0.58, shape: .circle)
        }
    }

    /// Thumb-first defaults tuned on the reference iPhone landscape canvas
    /// (~874×402pt). Primary actions land ~110–122pt, movement ~96×90pt, and
    /// clusters keep ≥20pt visual gaps so runtime hit regions stay separate.
    /// `layout validate` reports no issues for the common 4-movement + 4-action
    /// + secondary + utility + system mixes generated from these values.
    private static func layoutDefaults(for button: GameButton, role: KeypadRole, index: Int) -> LayoutDefaults {
        switch button {
        case .up:
            return LayoutDefaults(x: 0.20, y: 0.42, width: 1.12, height: 1.05, shape: .roundedRectangle)
        case .down:
            return LayoutDefaults(x: 0.20, y: 0.70, width: 1.12, height: 1.05, shape: .roundedRectangle)
        case .left:
            return LayoutDefaults(x: 0.066, y: 0.56, width: 1.12, height: 1.05, shape: .roundedRectangle)
        case .right:
            return LayoutDefaults(x: 0.334, y: 0.56, width: 1.12, height: 1.05, shape: .roundedRectangle)
        case .map:
            return LayoutDefaults(x: 0.29, y: 0.16, width: 1.0, height: 1.1, shape: .capsule)
        case .pause:
            return LayoutDefaults(x: 0.78, y: 0.21, width: 0.95, height: 1.1, shape: .capsule)
        default:
            break
        }

        switch role {
        case .movement:
            return repeating([
                LayoutDefaults(x: 0.20, y: 0.42, width: 1.12, height: 1.05, shape: .roundedRectangle),
                LayoutDefaults(x: 0.20, y: 0.70, width: 1.12, height: 1.05, shape: .roundedRectangle),
                LayoutDefaults(x: 0.066, y: 0.56, width: 1.12, height: 1.05, shape: .roundedRectangle),
                LayoutDefaults(x: 0.334, y: 0.56, width: 1.12, height: 1.05, shape: .roundedRectangle)
            ], index: index)
        case .primary:
            return repeating([
                LayoutDefaults(x: 0.82, y: 0.84, width: 1.42, height: 1.28, shape: .roundedRectangle),
                LayoutDefaults(x: 0.66, y: 0.62, width: 1.34, height: 1.20, shape: .roundedRectangle),
                LayoutDefaults(x: 0.93, y: 0.53, width: 1.24, height: 1.12, shape: .roundedRectangle),
                LayoutDefaults(x: 0.62, y: 0.32, width: 1.18, height: 1.06, shape: .roundedRectangle),
                LayoutDefaults(x: 0.60, y: 0.89, width: 1.12, height: 0.95, shape: .roundedRectangle),
                LayoutDefaults(x: 0.94, y: 0.42, width: 1.06, height: 0.94, shape: .roundedRectangle)
            ], index: index)
        case .secondary:
            return repeating([
                LayoutDefaults(x: 0.94, y: 0.255, width: 1.06, height: 0.96, shape: .roundedRectangle),
                LayoutDefaults(x: 0.42, y: 0.86, width: 1.06, height: 0.94, shape: .roundedRectangle),
                LayoutDefaults(x: 0.68, y: 0.88, width: 1.06, height: 0.94, shape: .roundedRectangle),
                LayoutDefaults(x: 0.36, y: 0.74, width: 1.06, height: 0.94, shape: .roundedRectangle)
            ], index: index)
        case .utility:
            return repeating([
                LayoutDefaults(x: 0.29, y: 0.16, width: 1.0, height: 1.1, shape: .capsule),
                LayoutDefaults(x: 0.55, y: 0.86, width: 1.0, height: 0.94, shape: .capsule),
                LayoutDefaults(x: 0.68, y: 0.90, width: 1.0, height: 0.94, shape: .capsule),
                LayoutDefaults(x: 0.50, y: 0.90, width: 1.0, height: 0.94, shape: .capsule)
            ], index: index)
        case .system:
            return repeating([
                LayoutDefaults(x: 0.78, y: 0.21, width: 0.95, height: 1.1, shape: .capsule),
                LayoutDefaults(x: 0.68, y: 0.90, width: 0.90, height: 0.95, shape: .capsule)
            ], index: index)
        }
    }

    private static func repeating(_ layouts: [LayoutDefaults], index: Int) -> LayoutDefaults {
        guard !layouts.isEmpty else {
            return LayoutDefaults(x: 0.5, y: 0.5, width: 1.0, height: 1.0, shape: .roundedRectangle)
        }
        return layouts[min(index, layouts.count - 1)]
    }

    private static func normalizedControlText(_ control: AgentKeypadControlSpec) -> String {
        normalizedGameName([control.id, control.button?.rawValue, control.label, control.key].compactMap { $0 }.joined(separator: " "))
    }

    private static func normalizedDisplayName(_ name: String, fallback: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let fallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? "Agent Generated Game" : fallback
    }
}

private enum HollowKnightTemplate {
    static func matches(_ name: String) -> Bool {
        let normalized = normalizedGameName(name)
        return [
            "hollowknight",
            "hollownight",
            "holyknight",
            "holynight"
        ].contains(normalized)
    }

    static func make(requestedGameName: String) -> GeneratedGameKeypadProfile {
        let dPadFill = "#171717"
        let utilityFill = "#374151"

        // Thumb-first sizing: d-pad ~96×91pt, face buttons ~91pt circles on the
        // reference landscape canvas, with ≥20pt gaps so hit regions stay separate.
        let controls: [GeneratedControlDefinition] = [
            .init(.up, label: "↑", key: "UpArrow", role: .movement, x: 0.205, y: 0.46, width: 1.12, height: 1.06, fill: dPadFill, cornerRadius: 8),
            .init(.down, label: "↓", key: "DownArrow", role: .movement, x: 0.205, y: 0.86, width: 1.12, height: 1.06, fill: dPadFill, cornerRadius: 8),
            .init(.left, label: "←", key: "LeftArrow", role: .movement, x: 0.065, y: 0.655, width: 1.12, height: 1.06, fill: dPadFill, cornerRadius: 8),
            .init(.right, label: "→", key: "RightArrow", role: .movement, x: 0.345, y: 0.655, width: 1.12, height: 1.06, fill: dPadFill, cornerRadius: 8),

            .init(.focus, label: "Soul", key: "A", role: .secondary, x: 0.815, y: 0.40, width: 1.06, height: 1.06, shape: .circle, fill: "#22C55E", shadowStrength: 1.25),
            .init(.dash, label: "Dash", key: "C", role: .primary, x: 0.945, y: 0.65, width: 1.06, height: 1.06, shape: .circle, fill: "#EF4444", shadowStrength: 1.25),
            .init(.jump, label: "Jump", key: "Z", role: .primary, x: 0.815, y: 0.88, width: 1.06, height: 1.06, shape: .circle, fill: "#3B82F6", shadowStrength: 1.25),
            .init(.attack, label: "Nail", key: "X", role: .primary, x: 0.685, y: 0.65, width: 1.06, height: 1.06, shape: .circle, fill: "#EC4899", shadowStrength: 1.25),

            .init(.map, label: "Map", key: "Tab", role: .utility, x: 0.47, y: 0.905, width: 1.0, height: 1.1, shape: .capsule, fill: utilityFill, shadowStrength: 0.75),
            .init(.pause, label: "Pause", key: "Escape", role: .system, x: 0.655, y: 0.905, width: 1.0, height: 1.1, shape: .capsule, fill: utilityFill, shadowStrength: 0.75),

            .init(.custom5, label: "Quick Cast", key: "F", role: .secondary, x: 0.20, y: 0.10, width: 1.0, height: 0.78, shape: .capsule, fill: utilityFill),
            .init(.custom6, label: "Dream Nail", key: "D", role: .secondary, x: 0.80, y: 0.10, width: 1.0, height: 0.78, shape: .capsule, fill: utilityFill),
            .init(.custom7, label: "Super Dash", key: "S", role: .utility, x: 0.345, y: 0.23, width: 1.0, height: 0.78, shape: .capsule, fill: dPadFill),
            .init(.custom8, label: "Inventory", key: "I", role: .utility, x: 0.63, y: 0.17, width: 1.0, height: 0.78, shape: .capsule, fill: dPadFill)
        ]

        var generated = GeneratedProfileBuilder.build(
            requestedGameName: requestedGameName,
            resolvedGameName: "Hollow Knight",
            controls: controls,
            source: "Built-in Hollow Knight default keyboard template with Thumble's Cavern Glow showcase theme",
            confidence: .high,
            notes: [
                "Uses Hollow Knight's default keyboard bindings: Arrow keys for movement, Z jump, X attack, C dash, A focus/cast.",
                "Applies the Cavern Glow theme: dark cave gradient background, pale glyph controls, cyan Soul glow, slate utility buttons, pressed states, icons, and per-control haptics.",
                "The theme is inspired by dark-fantasy metroidvania controls without bundling copyrighted game art."
            ],
            controlScale: .standard,
            accentStyle: .purple
        )
        GamepadThemePreset.cavernGlow.apply(to: &generated.profile.customization)
        return generated
    }
}

private func normalizedGameName(_ name: String) -> String {
    name.lowercased().filter { $0.isLetter || $0.isNumber }
}
