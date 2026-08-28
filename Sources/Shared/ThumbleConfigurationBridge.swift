import Foundation

public let thumbleConfigurationBridgeSchemaVersion = 1
public let thumbleConfigurationBridgeMaximumBytes = (8 * 1024 * 1024) + (256 * 1024)

/// Credential-free configuration transformed by the constrained Swift bridge.
/// Profile payloads remain lossless JSON so fields from newer model versions survive.
public struct ThumbleBridgeConfigurationDocument: Codable, Equatable, Sendable {
    public var profiles: [ThumbleBridgeJSONValue]
    public var activeProfileID: String
    public var defaultProfileID: String
    public var keyBindings: ThumbleBridgeJSONValue
    public var outputBindings: ThumbleBridgeJSONValue
    public var profileKeyBindings: [String: ThumbleBridgeJSONValue]
    public var profileOutputBindings: [String: ThumbleBridgeJSONValue]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ThumbleBridgeCodingKey.self)
        try container.requireOnly([
            "profiles", "activeProfileID", "defaultProfileID", "keyBindings", "outputBindings",
            "profileKeyBindings", "profileOutputBindings"
        ])
        profiles = try container.decode([ThumbleBridgeJSONValue].self, forKey: .init("profiles"))
        activeProfileID = try container.decode(String.self, forKey: .init("activeProfileID"))
        defaultProfileID = try container.decode(String.self, forKey: .init("defaultProfileID"))
        keyBindings = try container.decode(ThumbleBridgeJSONValue.self, forKey: .init("keyBindings"))
        outputBindings = try container.decode(ThumbleBridgeJSONValue.self, forKey: .init("outputBindings"))
        profileKeyBindings = try container.decode([String: ThumbleBridgeJSONValue].self, forKey: .init("profileKeyBindings"))
        profileOutputBindings = try container.decode([String: ThumbleBridgeJSONValue].self, forKey: .init("profileOutputBindings"))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: ThumbleBridgeCodingKey.self)
        try container.encode(profiles, forKey: .init("profiles"))
        try container.encode(activeProfileID, forKey: .init("activeProfileID"))
        try container.encode(defaultProfileID, forKey: .init("defaultProfileID"))
        try container.encode(keyBindings, forKey: .init("keyBindings"))
        try container.encode(outputBindings, forKey: .init("outputBindings"))
        try container.encode(profileKeyBindings, forKey: .init("profileKeyBindings"))
        try container.encode(profileOutputBindings, forKey: .init("profileOutputBindings"))
    }

    public init(
        profiles: [ThumbleBridgeJSONValue],
        activeProfileID: String,
        defaultProfileID: String,
        keyBindings: ThumbleBridgeJSONValue = .object([:]),
        outputBindings: ThumbleBridgeJSONValue = .object([:]),
        profileKeyBindings: [String: ThumbleBridgeJSONValue] = [:],
        profileOutputBindings: [String: ThumbleBridgeJSONValue] = [:]
    ) {
        self.profiles = profiles
        self.activeProfileID = activeProfileID
        self.defaultProfileID = defaultProfileID
        self.keyBindings = keyBindings
        self.outputBindings = outputBindings
        self.profileKeyBindings = profileKeyBindings
        self.profileOutputBindings = profileOutputBindings
    }
}

public struct ThumbleConfigurationBridgeRequest: Decodable, Sendable {
    public let schemaVersion: Int
    public let nowMillis: Int64
    public let document: ThumbleBridgeConfigurationDocument
    public let operation: ThumbleBridgeOperation

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ThumbleBridgeCodingKey.self)
        try container.requireOnly(["schemaVersion", "nowMillis", "document", "operation"])
        schemaVersion = try container.decode(Int.self, forKey: .init("schemaVersion"))
        nowMillis = try container.decode(Int64.self, forKey: .init("nowMillis"))
        document = try container.decode(ThumbleBridgeConfigurationDocument.self, forKey: .init("document"))
        operation = try container.decode(ThumbleBridgeOperation.self, forKey: .init("operation"))
    }
}

public struct ThumbleConfigurationBridgeResponse: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let document: ThumbleBridgeConfigurationDocument
    public let changed: Bool
    public let changedPaths: [String]

    public init(document: ThumbleBridgeConfigurationDocument, changed: Bool, changedPaths: [String]) {
        schemaVersion = thumbleConfigurationBridgeSchemaVersion
        self.document = document
        self.changed = changed
        self.changedPaths = changedPaths
    }
}

public struct ThumbleConfigurationBridgeFailure: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let error: ThumbleConfigurationBridgeFailureDetail

    public init(code: String, message: String) {
        schemaVersion = thumbleConfigurationBridgeSchemaVersion
        error = ThumbleConfigurationBridgeFailureDetail(code: code, message: String(message.prefix(512)))
    }
}

public struct ThumbleConfigurationBridgeFailureDetail: Codable, Equatable, Sendable {
    public let code: String
    public let message: String
}

public enum ThumbleBridgeLayoutVariant: String, Decodable, Sendable {
    case primary
    case landscape
    case portrait
}

public struct ThumbleBridgeSemanticKeyStroke: Decodable, Sendable {
    public let key: String
    public let modifiers: [String]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ThumbleBridgeCodingKey.self)
        try container.requireOnly(["key", "modifiers"])
        key = try container.decode(String.self, forKey: .init("key"))
        modifiers = try container.decode([String].self, forKey: .init("modifiers"))
    }
}

public enum ThumbleBridgeKeyboardOutputEdit: Decodable, Sendable {
    case keep
    case clear
    case set([ThumbleBridgeSemanticKeyStroke])

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ThumbleBridgeCodingKey.self)
        let action = try container.decode(String.self, forKey: .init("action"))
        switch action {
        case "keep":
            try container.requireOnly(["action"])
            self = .keep
        case "clear":
            try container.requireOnly(["action"])
            self = .clear
        case "set":
            try container.requireOnly(["action", "sequence"])
            self = .set(try container.decode(
                [ThumbleBridgeSemanticKeyStroke].self,
                forKey: .init("sequence")
            ))
        default:
            throw ThumbleConfigurationBridgeError.invalidOutputEdit
        }
    }
}

public enum ThumbleBridgeProfileDestination: Decodable, Sendable {
    case create(newProfileID: String)
    case replace(profileID: String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ThumbleBridgeCodingKey.self)
        let action = try container.decode(String.self, forKey: .init("action"))
        switch action {
        case "create":
            try container.requireOnly(["action", "newProfileID"])
            self = .create(newProfileID: try container.decode(
                String.self,
                forKey: .init("newProfileID")
            ))
        case "replace":
            try container.requireOnly(["action", "profileID"])
            self = .replace(profileID: try container.decode(
                String.self,
                forKey: .init("profileID")
            ))
        default:
            throw ThumbleConfigurationBridgeError.invalidDestination
        }
    }
}

public enum ThumbleBridgeGenerationPreset: String, CaseIterable, Decodable, Sendable {
    case hollowKnight = "hollow-knight"

    // Revision 2: thumb-sized controls — d-pad/face buttons enlarged ~30%,
    // controlScale compact → standard, re-tuned cluster spacing.
    var revision: Int { 2 }
    var customElementIDCount: Int { 4 }
}

public enum ThumbleBridgeControllerTemplate: String, CaseIterable, Decodable, Sendable {
    case productivityStarter
    case productivityOneHandedLeft
    case productivityOneHandedRight
    case nes
    case snes
    case nintendo64
    case gameCube
    case gameBoy
    case gameBoyAdvance
    case genesisSixButton
    case saturn
    case dreamcast
    case arcadeStick
    case psp
    case playStation
    case xbox
    case softWhite

    var template: GamepadControllerTemplate {
        GamepadControllerTemplate(rawValue: rawValue)!
    }

    var revision: Int { template.templateRevision }

    var customElementIDCount: Int {
        switch self {
        case .productivityStarter, .productivityOneHandedLeft,
             .productivityOneHandedRight, .nes, .gameBoy:
            0
        case .snes, .gameBoyAdvance, .genesisSixButton:
            2
        case .dreamcast, .psp:
            3
        case .saturn:
            4
        case .gameCube, .arcadeStick:
            5
        case .playStation, .xbox:
            6
        case .nintendo64:
            8
        case .softWhite:
            15
        }
    }
}

public enum ThumbleBridgeGamepadOutputEdit: Decodable, Sendable {
    case keep
    case clear
    case set(VirtualGamepadButton)

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ThumbleBridgeCodingKey.self)
        let action = try container.decode(String.self, forKey: .init("action"))
        switch action {
        case "keep":
            try container.requireOnly(["action"])
            self = .keep
        case "clear":
            try container.requireOnly(["action"])
            self = .clear
        case "set":
            try container.requireOnly(["action", "button"])
            self = .set(try container.decode(
                VirtualGamepadButton.self,
                forKey: .init("button")
            ))
        default:
            throw ThumbleConfigurationBridgeError.invalidOutputEdit
        }
    }
}

public enum ThumbleBridgeBackgroundScope: String, Decodable, Sendable {
    case all
    case light
    case dark
}

public struct ThumbleBridgeRGBAColor: Decodable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ThumbleBridgeCodingKey.self)
        try container.requireOnly(["red", "green", "blue", "alpha"])
        red = try container.decode(Double.self, forKey: .init("red"))
        green = try container.decode(Double.self, forKey: .init("green"))
        blue = try container.decode(Double.self, forKey: .init("blue"))
        alpha = try container.decode(Double.self, forKey: .init("alpha"))
    }

    fileprivate var color: GamepadRGBAColor? {
        let components = [red, green, blue, alpha]
        guard components.allSatisfy({ $0.isFinite && (0 ... 1).contains($0) }) else { return nil }
        return GamepadRGBAColor(
            red: CGFloat(red),
            green: CGFloat(green),
            blue: CGFloat(blue),
            alpha: CGFloat(alpha)
        )
    }
}

public enum ThumbleBridgeBackgroundEdit: Decodable, Sendable {
    case keep
    case clear
    case set(scope: ThumbleBridgeBackgroundScope, color: ThumbleBridgeRGBAColor)

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ThumbleBridgeCodingKey.self)
        let action = try container.decode(String.self, forKey: .init("action"))
        switch action {
        case "keep":
            try container.requireOnly(["action"])
            self = .keep
        case "clear":
            try container.requireOnly(["action"])
            self = .clear
        case "set":
            try container.requireOnly(["action", "scope", "color"])
            self = .set(
                scope: try container.decode(ThumbleBridgeBackgroundScope.self, forKey: .init("scope")),
                color: try container.decode(ThumbleBridgeRGBAColor.self, forKey: .init("color"))
            )
        default:
            throw ThumbleConfigurationBridgeError.invalidCustomizationChanges
        }
    }
}

public struct ThumbleBridgeCustomizationChanges: Decodable, Sendable {
    public let layoutMode: GamepadLayoutMode?
    public let controlScale: GamepadControlScale?
    public let colorScheme: GamepadColorSchemePreference?
    public let accentStyle: GamepadAccentStyle?
    public let showsButtonLabels: Bool?
    public let backgroundEdit: ThumbleBridgeBackgroundEdit

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ThumbleBridgeCodingKey.self)
        try container.requireOnly([
            "layoutMode", "controlScale", "colorScheme", "accentStyle",
            "showsButtonLabels", "backgroundEdit"
        ])
        layoutMode = try container.decodeIfPresent(GamepadLayoutMode.self, forKey: .init("layoutMode"))
        controlScale = try container.decodeIfPresent(GamepadControlScale.self, forKey: .init("controlScale"))
        colorScheme = try container.decodeIfPresent(GamepadColorSchemePreference.self, forKey: .init("colorScheme"))
        accentStyle = try container.decodeIfPresent(GamepadAccentStyle.self, forKey: .init("accentStyle"))
        showsButtonLabels = try container.decodeIfPresent(Bool.self, forKey: .init("showsButtonLabels"))
        backgroundEdit = try container.decode(ThumbleBridgeBackgroundEdit.self, forKey: .init("backgroundEdit"))
    }

    fileprivate var isEmpty: Bool {
        layoutMode == nil
            && controlScale == nil
            && colorScheme == nil
            && accentStyle == nil
            && showsButtonLabels == nil
            && {
                if case .keep = backgroundEdit { return true }
                return false
            }()
    }
}

public enum ThumbleBridgeControlBarMoveDirection: String, Decodable, Sendable {
    case up
    case down
}

public enum ThumbleBridgeLayerMoveDestination: Decodable, Sendable {
    case index(Int)
    case before(String)
    case after(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ThumbleBridgeCodingKey.self)
        let action = try container.decode(String.self, forKey: .init("action"))
        switch action {
        case "index":
            try container.requireOnly(["action", "index"])
            self = .index(try container.decode(Int.self, forKey: .init("index")))
        case "before":
            try container.requireOnly(["action", "elementID"])
            self = .before(try container.decode(String.self, forKey: .init("elementID")))
        case "after":
            try container.requireOnly(["action", "elementID"])
            self = .after(try container.decode(String.self, forKey: .init("elementID")))
        default:
            throw ThumbleConfigurationBridgeError.invalidLayerDestination
        }
    }
}

public enum ThumbleBridgeStyleMaterialPreset: String, Decodable, Sendable {
    case softWhiteRaised = "soft-white-raised"
    case softWhiteInset = "soft-white-inset"
    case softWhitePlate = "soft-white-plate"

    fileprivate var visualStyle: GamepadControlVisualStyle {
        switch self {
        case .softWhiteRaised: .softWhiteRaised()
        case .softWhiteInset: .softWhiteInset()
        case .softWhitePlate: .softWhitePlate()
        }
    }
}

public enum ThumbleBridgeStyleIconSource: String, Decodable, Sendable {
    case sfSymbol = "sf_symbol"
    case text
}

public struct ThumbleBridgeStyleIcon: Decodable, Sendable {
    public let source: ThumbleBridgeStyleIconSource
    public let value: String

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ThumbleBridgeCodingKey.self)
        try container.requireOnly(["source", "value"])
        source = try container.decode(ThumbleBridgeStyleIconSource.self, forKey: .init("source"))
        value = try container.decode(String.self, forKey: .init("value"))
    }
}

public struct ThumbleBridgeStyleHaptic: Decodable, Sendable {
    public let style: GamepadHapticStyle?
    public let pattern: GamepadHapticPattern?
    public let intensity: Double?
    public let sharpness: Double?
    public let duration: Double?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ThumbleBridgeCodingKey.self)
        try container.requireOnly(["style", "pattern", "intensity", "sharpness", "duration"])
        style = try container.decodeIfPresent(GamepadHapticStyle.self, forKey: .init("style"))
        pattern = try container.decodeIfPresent(GamepadHapticPattern.self, forKey: .init("pattern"))
        intensity = try container.decodeIfPresent(Double.self, forKey: .init("intensity"))
        sharpness = try container.decodeIfPresent(Double.self, forKey: .init("sharpness"))
        duration = try container.decodeIfPresent(Double.self, forKey: .init("duration"))
    }

    fileprivate var feedback: GamepadHapticFeedback? {
        guard style != nil || pattern != nil || intensity != nil || sharpness != nil || duration != nil else {
            return nil
        }
        if let intensity, !intensity.isFinite || !(0 ... 1).contains(intensity) { return nil }
        if let sharpness, !sharpness.isFinite || !(0 ... 1).contains(sharpness) { return nil }
        if let duration, !duration.isFinite || !(0.02 ... 0.30).contains(duration) { return nil }
        var feedback = GamepadHapticFeedback(style: style ?? .light)
        if let style { feedback.style = style }
        if let pattern { feedback.pattern = pattern }
        if let intensity { feedback.intensity = intensity }
        if let sharpness { feedback.sharpness = sharpness }
        if let duration { feedback.duration = duration }
        return feedback.normalized
    }
}

public struct ThumbleBridgeStyleShadow: Decodable, Sendable {
    public let color: ThumbleBridgeRGBAColor
    public let radius: Double
    public let x: Double
    public let y: Double
    public let opacity: Double

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ThumbleBridgeCodingKey.self)
        try container.requireOnly(["color", "radius", "x", "y", "opacity"])
        color = try container.decode(ThumbleBridgeRGBAColor.self, forKey: .init("color"))
        radius = try container.decode(Double.self, forKey: .init("radius"))
        x = try container.decode(Double.self, forKey: .init("x"))
        y = try container.decode(Double.self, forKey: .init("y"))
        opacity = try container.decodeIfPresent(Double.self, forKey: .init("opacity")) ?? 1
    }

    fileprivate var shadow: GamepadControlShadowStyle? {
        guard let color = color.color,
              radius.isFinite, (0 ... 96).contains(radius),
              x.isFinite, (-96 ... 96).contains(x),
              y.isFinite, (-96 ... 96).contains(y),
              opacity.isFinite, (0 ... 1).contains(opacity)
        else { return nil }
        return GamepadControlShadowStyle(
            color: color,
            radius: radius,
            x: x,
            y: y,
            opacity: opacity
        )
    }
}

public final class ThumbleBridgeStyleAppearance: Decodable, @unchecked Sendable {
    public let materialPreset: ThumbleBridgeStyleMaterialPreset?
    public let fillColor: ThumbleBridgeRGBAColor?
    public let foregroundColor: ThumbleBridgeRGBAColor?
    public let strokeColor: ThumbleBridgeRGBAColor?
    public let strokeWidth: Double?
    public let glowColor: ThumbleBridgeRGBAColor?
    public let glowRadius: Double?
    public let innerShadowColor: ThumbleBridgeRGBAColor?
    public let innerShadowRadius: Double?
    public let innerShadowX: Double?
    public let innerShadowY: Double?
    public let highlightColor: ThumbleBridgeRGBAColor?
    public let highlightRadius: Double?
    public let highlightX: Double?
    public let highlightY: Double?
    public let highlightOpacity: Double?
    public let bevelHighlightColor: ThumbleBridgeRGBAColor?
    public let bevelShadowColor: ThumbleBridgeRGBAColor?
    public let bevelWidth: Double?
    public let opacity: Double?
    public let shadows: [ThumbleBridgeStyleShadow]?
    public let pressedFillColor: ThumbleBridgeRGBAColor?
    public let pressedScale: Double?
    public let icon: ThumbleBridgeStyleIcon?
    public let haptic: ThumbleBridgeStyleHaptic?

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ThumbleBridgeCodingKey.self)
        try container.requireOnly([
            "materialPreset", "fillColor", "foregroundColor", "strokeColor", "strokeWidth",
            "glowColor", "glowRadius", "innerShadowColor", "innerShadowRadius", "innerShadowX",
            "innerShadowY", "highlightColor", "highlightRadius", "highlightX", "highlightY",
            "highlightOpacity", "bevelHighlightColor", "bevelShadowColor", "bevelWidth", "opacity",
            "shadows", "pressedFillColor", "pressedScale", "icon", "haptic"
        ])
        materialPreset = try container.decodeIfPresent(ThumbleBridgeStyleMaterialPreset.self, forKey: .init("materialPreset"))
        fillColor = try container.decodeIfPresent(ThumbleBridgeRGBAColor.self, forKey: .init("fillColor"))
        foregroundColor = try container.decodeIfPresent(ThumbleBridgeRGBAColor.self, forKey: .init("foregroundColor"))
        strokeColor = try container.decodeIfPresent(ThumbleBridgeRGBAColor.self, forKey: .init("strokeColor"))
        strokeWidth = try container.decodeIfPresent(Double.self, forKey: .init("strokeWidth"))
        glowColor = try container.decodeIfPresent(ThumbleBridgeRGBAColor.self, forKey: .init("glowColor"))
        glowRadius = try container.decodeIfPresent(Double.self, forKey: .init("glowRadius"))
        innerShadowColor = try container.decodeIfPresent(ThumbleBridgeRGBAColor.self, forKey: .init("innerShadowColor"))
        innerShadowRadius = try container.decodeIfPresent(Double.self, forKey: .init("innerShadowRadius"))
        innerShadowX = try container.decodeIfPresent(Double.self, forKey: .init("innerShadowX"))
        innerShadowY = try container.decodeIfPresent(Double.self, forKey: .init("innerShadowY"))
        highlightColor = try container.decodeIfPresent(ThumbleBridgeRGBAColor.self, forKey: .init("highlightColor"))
        highlightRadius = try container.decodeIfPresent(Double.self, forKey: .init("highlightRadius"))
        highlightX = try container.decodeIfPresent(Double.self, forKey: .init("highlightX"))
        highlightY = try container.decodeIfPresent(Double.self, forKey: .init("highlightY"))
        highlightOpacity = try container.decodeIfPresent(Double.self, forKey: .init("highlightOpacity"))
        bevelHighlightColor = try container.decodeIfPresent(ThumbleBridgeRGBAColor.self, forKey: .init("bevelHighlightColor"))
        bevelShadowColor = try container.decodeIfPresent(ThumbleBridgeRGBAColor.self, forKey: .init("bevelShadowColor"))
        bevelWidth = try container.decodeIfPresent(Double.self, forKey: .init("bevelWidth"))
        opacity = try container.decodeIfPresent(Double.self, forKey: .init("opacity"))
        shadows = try container.decodeIfPresent([ThumbleBridgeStyleShadow].self, forKey: .init("shadows"))
        pressedFillColor = try container.decodeIfPresent(ThumbleBridgeRGBAColor.self, forKey: .init("pressedFillColor"))
        pressedScale = try container.decodeIfPresent(Double.self, forKey: .init("pressedScale"))
        icon = try container.decodeIfPresent(ThumbleBridgeStyleIcon.self, forKey: .init("icon"))
        haptic = try container.decodeIfPresent(ThumbleBridgeStyleHaptic.self, forKey: .init("haptic"))
    }

    fileprivate func token(id: String, name: String) throws -> GamepadStyleToken {
        let normalizedID = GamepadStyleToken.normalizedIdentifier(id)
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty, normalizedID == id, id.utf8.count <= 128,
              !normalizedName.isEmpty, normalizedName.count <= 48
        else { throw ThumbleConfigurationBridgeError.invalidStyle }

        var visualStyle = materialPreset?.visualStyle ?? .empty
        var normal = visualStyle.normal
        if let fillColor { normal.fillStyle = .solid(try requiredColor(fillColor)) }
        if let foregroundColor { normal.foregroundColor = try requiredColor(foregroundColor) }
        if let strokeColor { normal.strokeColor = try requiredColor(strokeColor) }
        if let strokeWidth { normal.strokeWidth = try requiredNumber(strokeWidth, in: 0 ... 12) }
        if let glowColor { normal.glowColor = try requiredColor(glowColor) }
        if let glowRadius { normal.glowRadius = try requiredNumber(glowRadius, in: 0 ... 64) }
        if let innerShadowColor { normal.innerShadowColor = try requiredColor(innerShadowColor) }
        if let innerShadowRadius { normal.innerShadowRadius = try requiredNumber(innerShadowRadius, in: 0 ... 64) }
        if let innerShadowX { normal.innerShadowX = try requiredNumber(innerShadowX, in: -64 ... 64) }
        if let innerShadowY { normal.innerShadowY = try requiredNumber(innerShadowY, in: -64 ... 64) }
        if let highlightColor { normal.highlightColor = try requiredColor(highlightColor) }
        if let highlightRadius { normal.highlightRadius = try requiredNumber(highlightRadius, in: 0 ... 64) }
        if let highlightX { normal.highlightX = try requiredNumber(highlightX, in: -64 ... 64) }
        if let highlightY { normal.highlightY = try requiredNumber(highlightY, in: -64 ... 64) }
        if let highlightOpacity { normal.highlightOpacity = try requiredNumber(highlightOpacity, in: 0 ... 1) }
        if let bevelHighlightColor { normal.bevelHighlightColor = try requiredColor(bevelHighlightColor) }
        if let bevelShadowColor { normal.bevelShadowColor = try requiredColor(bevelShadowColor) }
        if let bevelWidth { normal.bevelWidth = try requiredNumber(bevelWidth, in: 0 ... 24) }
        if let opacity { normal.opacity = try requiredNumber(opacity, in: 0 ... 1) }
        if let shadows {
            guard shadows.count <= 8 else { throw ThumbleConfigurationBridgeError.invalidStyle }
            let normalized = shadows.compactMap(\.shadow)
            guard normalized.count == shadows.count else { throw ThumbleConfigurationBridgeError.invalidStyle }
            normal.shadows = normalized
        }
        visualStyle.normal = normal

        if pressedFillColor != nil || pressedScale != nil {
            var pressed = visualStyle.pressed ?? .empty
            if let pressedFillColor { pressed.fillStyle = .solid(try requiredColor(pressedFillColor)) }
            if let pressedScale { pressed.scale = try requiredNumber(pressedScale, in: 0.5 ... 1.5) }
            visualStyle.pressed = pressed
        }
        if let icon {
            let value = icon.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.count <= 80 else { throw ThumbleConfigurationBridgeError.invalidStyle }
            visualStyle.icon = switch icon.source {
            case .sfSymbol: .sfSymbol(value)
            case .text: .text(value)
            }
        }
        if let haptic {
            guard let feedback = haptic.feedback else { throw ThumbleConfigurationBridgeError.invalidStyle }
            visualStyle.hapticStyle = feedback.style
            visualStyle.hapticFeedback = feedback
        }
        guard let token = GamepadStyleToken(
            id: normalizedID,
            name: normalizedName,
            visualStyle: visualStyle
        ).normalized else { throw ThumbleConfigurationBridgeError.invalidStyle }
        return token
    }

    fileprivate func elementVisualStyle(
        overlaying existing: GamepadControlVisualStyle?
    ) throws -> GamepadControlVisualStyle {
        let typed = try token(id: "element-inline", name: "Element Inline").visualStyle
        guard materialPreset == nil, let existing else { return typed }
        var result = existing
        var normal = result.normal
        let overlay = typed.normal
        if fillColor != nil { normal.fillStyle = overlay.fillStyle }
        if foregroundColor != nil { normal.foregroundColor = overlay.foregroundColor }
        if strokeColor != nil { normal.strokeColor = overlay.strokeColor }
        if strokeWidth != nil { normal.strokeWidth = overlay.strokeWidth }
        if glowColor != nil { normal.glowColor = overlay.glowColor }
        if glowRadius != nil { normal.glowRadius = overlay.glowRadius }
        if innerShadowColor != nil { normal.innerShadowColor = overlay.innerShadowColor }
        if innerShadowRadius != nil { normal.innerShadowRadius = overlay.innerShadowRadius }
        if innerShadowX != nil { normal.innerShadowX = overlay.innerShadowX }
        if innerShadowY != nil { normal.innerShadowY = overlay.innerShadowY }
        if highlightColor != nil { normal.highlightColor = overlay.highlightColor }
        if highlightRadius != nil { normal.highlightRadius = overlay.highlightRadius }
        if highlightX != nil { normal.highlightX = overlay.highlightX }
        if highlightY != nil { normal.highlightY = overlay.highlightY }
        if highlightOpacity != nil { normal.highlightOpacity = overlay.highlightOpacity }
        if bevelHighlightColor != nil { normal.bevelHighlightColor = overlay.bevelHighlightColor }
        if bevelShadowColor != nil { normal.bevelShadowColor = overlay.bevelShadowColor }
        if bevelWidth != nil { normal.bevelWidth = overlay.bevelWidth }
        if opacity != nil { normal.opacity = overlay.opacity }
        if shadows != nil { normal.shadows = overlay.shadows }
        result.normal = normal
        if pressedFillColor != nil || pressedScale != nil {
            var pressed = result.pressed ?? .empty
            if pressedFillColor != nil { pressed.fillStyle = typed.pressed?.fillStyle }
            if pressedScale != nil { pressed.scale = typed.pressed?.scale }
            result.pressed = pressed
        }
        if icon != nil { result.icon = typed.icon }
        if haptic != nil {
            result.hapticStyle = typed.hapticStyle
            result.hapticFeedback = typed.hapticFeedback
        }
        return result.normalized ?? .empty
    }

    private func requiredColor(_ input: ThumbleBridgeRGBAColor) throws -> GamepadRGBAColor {
        guard let color = input.color else { throw ThumbleConfigurationBridgeError.invalidStyle }
        return color
    }

    private func requiredNumber(_ value: Double, in range: ClosedRange<Double>) throws -> CGFloat {
        guard value.isFinite, range.contains(value) else { throw ThumbleConfigurationBridgeError.invalidStyle }
        return CGFloat(value)
    }
}

public enum ThumbleBridgeElementFill: Decodable, Sendable {
    case solid(GamepadRGBAColor)
    case gradient(GamepadGradientFill)
    case tile(GamepadTileFill)

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ThumbleBridgeCodingKey.self)
        let kind = try container.decode(String.self, forKey: .init("kind"))
        switch kind {
        case "solid":
            try container.requireOnly(["kind", "color"])
            let input = try container.decode(ThumbleBridgeRGBAColor.self, forKey: .init("color"))
            guard let color = input.color else { throw ThumbleConfigurationBridgeError.invalidElementChanges }
            self = .solid(color)
        case "gradient":
            try container.requireOnly(["kind", "type", "angleDegrees", "stops"])
            let type = try container.decode(GamepadGradientType.self, forKey: .init("type"))
            let angle = try container.decode(Double.self, forKey: .init("angleDegrees"))
            let stops = try container.decode([ThumbleBridgeGradientStop].self, forKey: .init("stops"))
            guard angle.isFinite, (-36_000 ... 36_000).contains(angle), (2 ... 8).contains(stops.count),
                  stops.allSatisfy({ $0.stop != nil })
            else { throw ThumbleConfigurationBridgeError.invalidElementChanges }
            self = .gradient(GamepadGradientFill(
                type: type,
                angleDegrees: angle,
                stops: stops.compactMap(\.stop)
            ).normalized)
        case "tile":
            try container.requireOnly([
                "kind", "pattern", "foregroundColor", "backgroundColor", "scale",
                "spacingX", "spacingY", "alignment", "opacity"
            ])
            let foreground = try container.decode(ThumbleBridgeRGBAColor.self, forKey: .init("foregroundColor"))
            let background = try container.decode(ThumbleBridgeRGBAColor.self, forKey: .init("backgroundColor"))
            let scale = try container.decode(Double.self, forKey: .init("scale"))
            let spacingX = try container.decode(Double.self, forKey: .init("spacingX"))
            let spacingY = try container.decode(Double.self, forKey: .init("spacingY"))
            let opacity = try container.decode(Double.self, forKey: .init("opacity"))
            guard let foregroundColor = foreground.color, let backgroundColor = background.color,
                  scale.isFinite, (0.25 ... 4).contains(scale),
                  spacingX.isFinite, (0 ... 2).contains(spacingX),
                  spacingY.isFinite, (0 ... 2).contains(spacingY),
                  opacity.isFinite, (0 ... 1).contains(opacity)
            else { throw ThumbleConfigurationBridgeError.invalidElementChanges }
            self = .tile(GamepadTileFill(
                pattern: try container.decode(GamepadTilePattern.self, forKey: .init("pattern")),
                foregroundColor: foregroundColor,
                backgroundColor: backgroundColor,
                scale: scale,
                spacingX: spacingX,
                spacingY: spacingY,
                alignment: try container.decode(GamepadTileAlignment.self, forKey: .init("alignment")),
                opacity: opacity
            ).normalized)
        default:
            throw ThumbleConfigurationBridgeError.invalidElementChanges
        }
    }

    fileprivate var fillStyle: GamepadFillStyle {
        switch self {
        case .solid(let color): .solid(color)
        case .gradient(let gradient): .gradient(gradient)
        case .tile(let tile): .tile(tile)
        }
    }
}

public struct ThumbleBridgeGradientStop: Decodable, Sendable {
    public let offset: Double
    public let color: ThumbleBridgeRGBAColor

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ThumbleBridgeCodingKey.self)
        try container.requireOnly(["offset", "color"])
        offset = try container.decode(Double.self, forKey: .init("offset"))
        color = try container.decode(ThumbleBridgeRGBAColor.self, forKey: .init("color"))
    }

    fileprivate var stop: GamepadGradientStop? {
        guard offset.isFinite, (0 ... 1).contains(offset), let color = color.color else { return nil }
        return GamepadGradientStop(offset: offset, color: color)
    }
}

public struct ThumbleBridgeElementHitInsets: Decodable, Sendable {
    public let top: Double
    public let leading: Double
    public let bottom: Double
    public let trailing: Double

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ThumbleBridgeCodingKey.self)
        try container.requireOnly(["top", "leading", "bottom", "trailing"])
        top = try container.decode(Double.self, forKey: .init("top"))
        leading = try container.decode(Double.self, forKey: .init("leading"))
        bottom = try container.decode(Double.self, forKey: .init("bottom"))
        trailing = try container.decode(Double.self, forKey: .init("trailing"))
    }

    fileprivate var insets: GamepadHitInsets? {
        let values = [top, leading, bottom, trailing]
        guard values.allSatisfy({ $0.isFinite && (0 ... 96).contains($0) }) else { return nil }
        return GamepadHitInsets(top: top, leading: leading, bottom: bottom, trailing: trailing)
    }
}

public struct ThumbleBridgeElementCornerRadii: Decodable, Sendable {
    public let topLeading: Double
    public let topTrailing: Double
    public let bottomTrailing: Double
    public let bottomLeading: Double

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ThumbleBridgeCodingKey.self)
        try container.requireOnly(["topLeading", "topTrailing", "bottomTrailing", "bottomLeading"])
        topLeading = try container.decode(Double.self, forKey: .init("topLeading"))
        topTrailing = try container.decode(Double.self, forKey: .init("topTrailing"))
        bottomTrailing = try container.decode(Double.self, forKey: .init("bottomTrailing"))
        bottomLeading = try container.decode(Double.self, forKey: .init("bottomLeading"))
    }

    fileprivate var radii: GamepadCornerRadii? {
        let values = [topLeading, topTrailing, bottomTrailing, bottomLeading]
        guard values.allSatisfy({ $0.isFinite && (0 ... 1_024).contains($0) }) else { return nil }
        return GamepadCornerRadii(
            topLeading: topLeading,
            topTrailing: topTrailing,
            bottomTrailing: bottomTrailing,
            bottomLeading: bottomLeading
        )
    }
}

public struct ThumbleBridgeJoystickSettings: Decodable, Sendable {
    public let analogTarget: GamepadJoystickAnalogTarget?
    public let sendsDigitalDirections: Bool?
    public let deadZone: Double?
    public let sensitivity: Double?
    public let invertX: Bool?
    public let invertY: Bool?
    public let snapToCardinal: Bool?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ThumbleBridgeCodingKey.self)
        try container.requireOnly(["analogTarget", "sendsDigitalDirections", "deadZone", "sensitivity", "invertX", "invertY", "snapToCardinal"])
        analogTarget = try container.decodeIfPresent(GamepadJoystickAnalogTarget.self, forKey: .init("analogTarget"))
        sendsDigitalDirections = try container.decodeIfPresent(Bool.self, forKey: .init("sendsDigitalDirections"))
        deadZone = try container.decodeIfPresent(Double.self, forKey: .init("deadZone"))
        sensitivity = try container.decodeIfPresent(Double.self, forKey: .init("sensitivity"))
        invertX = try container.decodeIfPresent(Bool.self, forKey: .init("invertX"))
        invertY = try container.decodeIfPresent(Bool.self, forKey: .init("invertY"))
        snapToCardinal = try container.decodeIfPresent(Bool.self, forKey: .init("snapToCardinal"))
    }

    fileprivate func applying(to input: GamepadJoystickOutputSettings) throws -> GamepadJoystickOutputSettings {
        if let deadZone { try requireFinite(deadZone, in: 0 ... 0.85) }
        if let sensitivity { try requireFinite(sensitivity, in: 0.2 ... 3) }
        var output = input.normalized
        if let analogTarget { output.analogTarget = analogTarget }
        if let sendsDigitalDirections { output.sendsDigitalDirections = sendsDigitalDirections }
        if let deadZone { output.deadZone = deadZone }
        if let sensitivity { output.sensitivity = sensitivity }
        if let invertX { output.invertX = invertX }
        if let invertY { output.invertY = invertY }
        if let snapToCardinal { output.snapToCardinal = snapToCardinal }
        return output.normalized
    }
}

public struct ThumbleBridgeTriggerSettings: Decodable, Sendable {
    public let target: VirtualGamepadTrigger?
    public let orientation: GamepadTriggerOrientation?
    public let deadZone: Double?
    public let sensitivity: Double?
    public let sendsDigitalButton: Bool?
    public let digitalThreshold: Double?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ThumbleBridgeCodingKey.self)
        try container.requireOnly(["target", "orientation", "deadZone", "sensitivity", "sendsDigitalButton", "digitalThreshold"])
        target = try container.decodeIfPresent(VirtualGamepadTrigger.self, forKey: .init("target"))
        orientation = try container.decodeIfPresent(GamepadTriggerOrientation.self, forKey: .init("orientation"))
        deadZone = try container.decodeIfPresent(Double.self, forKey: .init("deadZone"))
        sensitivity = try container.decodeIfPresent(Double.self, forKey: .init("sensitivity"))
        sendsDigitalButton = try container.decodeIfPresent(Bool.self, forKey: .init("sendsDigitalButton"))
        digitalThreshold = try container.decodeIfPresent(Double.self, forKey: .init("digitalThreshold"))
    }

    fileprivate func applying(to input: GamepadTriggerSettings) throws -> GamepadTriggerSettings {
        if let deadZone { try requireFinite(deadZone, in: 0 ... 0.85) }
        if let sensitivity { try requireFinite(sensitivity, in: 0.2 ... 3) }
        if let digitalThreshold { try requireFinite(digitalThreshold, in: 0.01 ... 1) }
        var output = input.normalized
        if let target { output.target = target }
        if let orientation { output.orientation = orientation }
        if let deadZone { output.deadZone = deadZone }
        if let sensitivity { output.sensitivity = sensitivity }
        if let sendsDigitalButton { output.sendsDigitalButton = sendsDigitalButton }
        if let digitalThreshold { output.digitalThreshold = digitalThreshold }
        return output.normalized
    }
}

public struct ThumbleBridgeTrackpadSettings: Decodable, Sendable {
    public let sensitivity: Double?
    public let scrollSensitivity: Double?
    public let tapToClick: Bool?
    public let twoFingerScroll: Bool?
    public let naturalScrolling: Bool?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ThumbleBridgeCodingKey.self)
        try container.requireOnly(["sensitivity", "scrollSensitivity", "tapToClick", "twoFingerScroll", "naturalScrolling"])
        sensitivity = try container.decodeIfPresent(Double.self, forKey: .init("sensitivity"))
        scrollSensitivity = try container.decodeIfPresent(Double.self, forKey: .init("scrollSensitivity"))
        tapToClick = try container.decodeIfPresent(Bool.self, forKey: .init("tapToClick"))
        twoFingerScroll = try container.decodeIfPresent(Bool.self, forKey: .init("twoFingerScroll"))
        naturalScrolling = try container.decodeIfPresent(Bool.self, forKey: .init("naturalScrolling"))
    }

    fileprivate func applying(to input: GamepadTrackpadSettings) throws -> GamepadTrackpadSettings {
        if let sensitivity { try requireFinite(sensitivity, in: 0.2 ... 4) }
        if let scrollSensitivity { try requireFinite(scrollSensitivity, in: 0.1 ... 4) }
        var output = input.normalized
        if let sensitivity { output.sensitivity = sensitivity }
        if let scrollSensitivity { output.scrollSensitivity = scrollSensitivity }
        if let tapToClick { output.tapToClick = tapToClick }
        if let twoFingerScroll { output.twoFingerScroll = twoFingerScroll }
        if let naturalScrolling { output.naturalScrolling = naturalScrolling }
        return output.normalized
    }
}

private func requireFinite(_ value: Double, in range: ClosedRange<Double>) throws {
    guard value.isFinite, range.contains(value) else { throw ThumbleConfigurationBridgeError.invalidElementChanges }
}

public struct ThumbleBridgeElementOutputChanges: Decodable, Sendable {
    public let part: KeypadElementInputPart
    public let keyboardEdit: ThumbleBridgeKeyboardOutputEdit
    public let gamepadEdit: ThumbleBridgeGamepadOutputEdit

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ThumbleBridgeCodingKey.self)
        try container.requireOnly(["part", "keyboardEdit", "gamepadEdit"])
        part = try container.decode(KeypadElementInputPart.self, forKey: .init("part"))
        keyboardEdit = try container.decode(ThumbleBridgeKeyboardOutputEdit.self, forKey: .init("keyboardEdit"))
        gamepadEdit = try container.decode(ThumbleBridgeGamepadOutputEdit.self, forKey: .init("gamepadEdit"))
    }
}

/// Heap-backed because this input spans the complete safe non-file CLI element surface.
public final class ThumbleBridgeElementChanges: Decodable, @unchecked Sendable {
    public let label: String?
    public let clearLabel: Bool
    public let kind: GamepadCustomControlKind?
    public let mappedButton: GameButton?
    public let visualRole: GamepadVisualRole?
    public let clearVisualRole: Bool
    public let centerX: Double?
    public let centerY: Double?
    public let widthScale: Double?
    public let heightScale: Double?
    public let rotationDegrees: Double?
    public let shape: GamepadButtonShapeStyle?
    public let isHidden: Bool?
    public let isLocationLocked: Bool?
    public let showsIntegratedLabel: Bool?
    public let zIndex: Int?
    public let hitInsets: ThumbleBridgeElementHitInsets?
    public let clearHitInsets: Bool
    public let cornerRadius: Double?
    public let cornerRadii: ThumbleBridgeElementCornerRadii?
    public let shadowStrength: Double?
    public let fill: ThumbleBridgeElementFill?
    public let clearFill: Bool
    public let lightFill: ThumbleBridgeElementFill?
    public let clearLightFill: Bool
    public let darkFill: ThumbleBridgeElementFill?
    public let clearDarkFill: Bool
    public let fillOpacity: Double?
    public let lightFillOpacity: Double?
    public let darkFillOpacity: Double?
    public let thumbFill: ThumbleBridgeRGBAColor?
    public let clearThumbFill: Bool
    public let lightThumbFill: ThumbleBridgeRGBAColor?
    public let clearLightThumbFill: Bool
    public let darkThumbFill: ThumbleBridgeRGBAColor?
    public let clearDarkThumbFill: Bool
    public let thumbOpacity: Double?
    public let lightThumbOpacity: Double?
    public let darkThumbOpacity: Double?
    public let joystickVisualStyle: GamepadJoystickVisualStyle?
    public let styleID: String?
    public let clearStyle: Bool
    public let appearance: ThumbleBridgeStyleAppearance?
    public let icon: ThumbleBridgeStyleIcon?
    public let clearIcon: Bool
    public let haptic: ThumbleBridgeStyleHaptic?
    public let clearHaptic: Bool
    public let joystickMapping: GamepadJoystickMapping?
    public let joystickSettings: ThumbleBridgeJoystickSettings?
    public let triggerSettings: ThumbleBridgeTriggerSettings?
    public let trackpadSettings: ThumbleBridgeTrackpadSettings?
    public let output: ThumbleBridgeElementOutputChanges?

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ThumbleBridgeCodingKey.self)
        try container.requireOnly([
            "label", "clearLabel", "kind", "mappedButton", "visualRole", "clearVisualRole",
            "centerX", "centerY", "widthScale", "heightScale", "rotationDegrees", "shape",
            "isHidden", "isLocationLocked", "showsIntegratedLabel", "zIndex", "hitInsets",
            "clearHitInsets", "cornerRadius", "cornerRadii", "shadowStrength", "fill", "clearFill",
            "lightFill", "clearLightFill", "darkFill", "clearDarkFill", "fillOpacity",
            "lightFillOpacity", "darkFillOpacity", "thumbFill", "clearThumbFill", "lightThumbFill",
            "clearLightThumbFill", "darkThumbFill", "clearDarkThumbFill", "thumbOpacity",
            "lightThumbOpacity", "darkThumbOpacity", "joystickVisualStyle", "styleID", "clearStyle",
            "appearance", "icon", "clearIcon", "haptic", "clearHaptic", "joystickMapping",
            "joystickSettings", "triggerSettings", "trackpadSettings", "output"
        ])
        label = try container.decodeIfPresent(String.self, forKey: .init("label"))
        clearLabel = try container.decodeIfPresent(Bool.self, forKey: .init("clearLabel")) ?? false
        kind = try container.decodeIfPresent(GamepadCustomControlKind.self, forKey: .init("kind"))
        mappedButton = try container.decodeIfPresent(GameButton.self, forKey: .init("mappedButton"))
        visualRole = try container.decodeIfPresent(GamepadVisualRole.self, forKey: .init("visualRole"))
        clearVisualRole = try container.decodeIfPresent(Bool.self, forKey: .init("clearVisualRole")) ?? false
        centerX = try container.decodeIfPresent(Double.self, forKey: .init("centerX"))
        centerY = try container.decodeIfPresent(Double.self, forKey: .init("centerY"))
        widthScale = try container.decodeIfPresent(Double.self, forKey: .init("widthScale"))
        heightScale = try container.decodeIfPresent(Double.self, forKey: .init("heightScale"))
        rotationDegrees = try container.decodeIfPresent(Double.self, forKey: .init("rotationDegrees"))
        shape = try container.decodeIfPresent(GamepadButtonShapeStyle.self, forKey: .init("shape"))
        isHidden = try container.decodeIfPresent(Bool.self, forKey: .init("isHidden"))
        isLocationLocked = try container.decodeIfPresent(Bool.self, forKey: .init("isLocationLocked"))
        showsIntegratedLabel = try container.decodeIfPresent(Bool.self, forKey: .init("showsIntegratedLabel"))
        zIndex = try container.decodeIfPresent(Int.self, forKey: .init("zIndex"))
        hitInsets = try container.decodeIfPresent(ThumbleBridgeElementHitInsets.self, forKey: .init("hitInsets"))
        clearHitInsets = try container.decodeIfPresent(Bool.self, forKey: .init("clearHitInsets")) ?? false
        cornerRadius = try container.decodeIfPresent(Double.self, forKey: .init("cornerRadius"))
        cornerRadii = try container.decodeIfPresent(ThumbleBridgeElementCornerRadii.self, forKey: .init("cornerRadii"))
        shadowStrength = try container.decodeIfPresent(Double.self, forKey: .init("shadowStrength"))
        fill = try container.decodeIfPresent(ThumbleBridgeElementFill.self, forKey: .init("fill"))
        clearFill = try container.decodeIfPresent(Bool.self, forKey: .init("clearFill")) ?? false
        lightFill = try container.decodeIfPresent(ThumbleBridgeElementFill.self, forKey: .init("lightFill"))
        clearLightFill = try container.decodeIfPresent(Bool.self, forKey: .init("clearLightFill")) ?? false
        darkFill = try container.decodeIfPresent(ThumbleBridgeElementFill.self, forKey: .init("darkFill"))
        clearDarkFill = try container.decodeIfPresent(Bool.self, forKey: .init("clearDarkFill")) ?? false
        fillOpacity = try container.decodeIfPresent(Double.self, forKey: .init("fillOpacity"))
        lightFillOpacity = try container.decodeIfPresent(Double.self, forKey: .init("lightFillOpacity"))
        darkFillOpacity = try container.decodeIfPresent(Double.self, forKey: .init("darkFillOpacity"))
        thumbFill = try container.decodeIfPresent(ThumbleBridgeRGBAColor.self, forKey: .init("thumbFill"))
        clearThumbFill = try container.decodeIfPresent(Bool.self, forKey: .init("clearThumbFill")) ?? false
        lightThumbFill = try container.decodeIfPresent(ThumbleBridgeRGBAColor.self, forKey: .init("lightThumbFill"))
        clearLightThumbFill = try container.decodeIfPresent(Bool.self, forKey: .init("clearLightThumbFill")) ?? false
        darkThumbFill = try container.decodeIfPresent(ThumbleBridgeRGBAColor.self, forKey: .init("darkThumbFill"))
        clearDarkThumbFill = try container.decodeIfPresent(Bool.self, forKey: .init("clearDarkThumbFill")) ?? false
        thumbOpacity = try container.decodeIfPresent(Double.self, forKey: .init("thumbOpacity"))
        lightThumbOpacity = try container.decodeIfPresent(Double.self, forKey: .init("lightThumbOpacity"))
        darkThumbOpacity = try container.decodeIfPresent(Double.self, forKey: .init("darkThumbOpacity"))
        joystickVisualStyle = try container.decodeIfPresent(GamepadJoystickVisualStyle.self, forKey: .init("joystickVisualStyle"))
        styleID = try container.decodeIfPresent(String.self, forKey: .init("styleID"))
        clearStyle = try container.decodeIfPresent(Bool.self, forKey: .init("clearStyle")) ?? false
        appearance = try container.decodeIfPresent(ThumbleBridgeStyleAppearance.self, forKey: .init("appearance"))
        icon = try container.decodeIfPresent(ThumbleBridgeStyleIcon.self, forKey: .init("icon"))
        clearIcon = try container.decodeIfPresent(Bool.self, forKey: .init("clearIcon")) ?? false
        haptic = try container.decodeIfPresent(ThumbleBridgeStyleHaptic.self, forKey: .init("haptic"))
        clearHaptic = try container.decodeIfPresent(Bool.self, forKey: .init("clearHaptic")) ?? false
        joystickMapping = try container.decodeIfPresent(GamepadJoystickMapping.self, forKey: .init("joystickMapping"))
        joystickSettings = try container.decodeIfPresent(ThumbleBridgeJoystickSettings.self, forKey: .init("joystickSettings"))
        triggerSettings = try container.decodeIfPresent(ThumbleBridgeTriggerSettings.self, forKey: .init("triggerSettings"))
        trackpadSettings = try container.decodeIfPresent(ThumbleBridgeTrackpadSettings.self, forKey: .init("trackpadSettings"))
        output = try container.decodeIfPresent(ThumbleBridgeElementOutputChanges.self, forKey: .init("output"))
    }
}

/// Heap-backed to keep the tagged bridge operation below constrained-stack budgets.
public final class ThumbleBridgeControlBarItemChanges: Decodable, @unchecked Sendable {
    public let widthScale: Double?
    public let heightScale: Double?
    public let isHidden: Bool?
    public let shape: GamepadButtonShapeStyle?
    public let accentStyle: GamepadAccentStyle?
    public let cornerRadius: Double?
    public let cornerRadii: ThumbleBridgeElementCornerRadii?
    public let shadowStrength: Double?
    public let fill: ThumbleBridgeElementFill?
    public let clearFill: Bool
    public let lightFill: ThumbleBridgeElementFill?
    public let clearLightFill: Bool
    public let darkFill: ThumbleBridgeElementFill?
    public let clearDarkFill: Bool
    public let fillOpacity: Double?
    public let lightFillOpacity: Double?
    public let darkFillOpacity: Double?
    public let styleID: String?
    public let clearStyle: Bool
    public let appearance: ThumbleBridgeStyleAppearance?
    public let icon: ThumbleBridgeStyleIcon?
    public let clearIcon: Bool
    public let haptic: ThumbleBridgeStyleHaptic?
    public let clearHaptic: Bool

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ThumbleBridgeCodingKey.self)
        try container.requireOnly([
            "widthScale", "heightScale", "isHidden", "shape", "accentStyle", "cornerRadius",
            "cornerRadii", "shadowStrength", "fill", "clearFill", "lightFill", "clearLightFill",
            "darkFill", "clearDarkFill", "fillOpacity", "lightFillOpacity", "darkFillOpacity",
            "styleID", "clearStyle", "appearance", "icon", "clearIcon", "haptic", "clearHaptic"
        ])
        widthScale = try container.decodeIfPresent(Double.self, forKey: .init("widthScale"))
        heightScale = try container.decodeIfPresent(Double.self, forKey: .init("heightScale"))
        isHidden = try container.decodeIfPresent(Bool.self, forKey: .init("isHidden"))
        shape = try container.decodeIfPresent(GamepadButtonShapeStyle.self, forKey: .init("shape"))
        accentStyle = try container.decodeIfPresent(GamepadAccentStyle.self, forKey: .init("accentStyle"))
        cornerRadius = try container.decodeIfPresent(Double.self, forKey: .init("cornerRadius"))
        cornerRadii = try container.decodeIfPresent(ThumbleBridgeElementCornerRadii.self, forKey: .init("cornerRadii"))
        shadowStrength = try container.decodeIfPresent(Double.self, forKey: .init("shadowStrength"))
        fill = try container.decodeIfPresent(ThumbleBridgeElementFill.self, forKey: .init("fill"))
        clearFill = try container.decodeIfPresent(Bool.self, forKey: .init("clearFill")) ?? false
        lightFill = try container.decodeIfPresent(ThumbleBridgeElementFill.self, forKey: .init("lightFill"))
        clearLightFill = try container.decodeIfPresent(Bool.self, forKey: .init("clearLightFill")) ?? false
        darkFill = try container.decodeIfPresent(ThumbleBridgeElementFill.self, forKey: .init("darkFill"))
        clearDarkFill = try container.decodeIfPresent(Bool.self, forKey: .init("clearDarkFill")) ?? false
        fillOpacity = try container.decodeIfPresent(Double.self, forKey: .init("fillOpacity"))
        lightFillOpacity = try container.decodeIfPresent(Double.self, forKey: .init("lightFillOpacity"))
        darkFillOpacity = try container.decodeIfPresent(Double.self, forKey: .init("darkFillOpacity"))
        styleID = try container.decodeIfPresent(String.self, forKey: .init("styleID"))
        clearStyle = try container.decodeIfPresent(Bool.self, forKey: .init("clearStyle")) ?? false
        appearance = try container.decodeIfPresent(ThumbleBridgeStyleAppearance.self, forKey: .init("appearance"))
        icon = try container.decodeIfPresent(ThumbleBridgeStyleIcon.self, forKey: .init("icon"))
        clearIcon = try container.decodeIfPresent(Bool.self, forKey: .init("clearIcon")) ?? false
        haptic = try container.decodeIfPresent(ThumbleBridgeStyleHaptic.self, forKey: .init("haptic"))
        clearHaptic = try container.decodeIfPresent(Bool.self, forKey: .init("clearHaptic")) ?? false
    }

    fileprivate var isEmpty: Bool {
        widthScale == nil && heightScale == nil && isHidden == nil && shape == nil
            && accentStyle == nil && cornerRadius == nil && cornerRadii == nil
            && shadowStrength == nil && fill == nil && !clearFill && lightFill == nil
            && !clearLightFill && darkFill == nil && !clearDarkFill && fillOpacity == nil
            && lightFillOpacity == nil && darkFillOpacity == nil && styleID == nil
            && !clearStyle && appearance == nil && icon == nil && !clearIcon
            && haptic == nil && !clearHaptic
    }

    fileprivate var hasSpacerForbiddenChange: Bool {
        heightScale != nil || shape != nil || accentStyle != nil || cornerRadius != nil
            || cornerRadii != nil || shadowStrength != nil || fill != nil || clearFill
            || lightFill != nil || clearLightFill || darkFill != nil || clearDarkFill
            || fillOpacity != nil || lightFillOpacity != nil || darkFillOpacity != nil
            || styleID != nil || clearStyle || appearance != nil || icon != nil
            || clearIcon || haptic != nil || clearHaptic
    }
}

public enum ThumbleBridgeLayoutRepairKind: String, Decodable, Sendable {
    case showDefaultControls = "show-default-controls"
    case moveInsideSafeArea = "move-inside-safe-area"
    case minimumTouchTarget = "minimum-touch-target"
    case resolveOverlap = "resolve-overlap"
    case autoArrange = "auto-arrange"
    case separateExpandedHitTargets = "separate-expanded-hit-targets"
    case ergonomicAutoArrange = "ergonomic-auto-arrange"

    fileprivate var shared: GamepadLayoutRepairKind {
        GamepadLayoutRepairKind(rawValue: rawValue)!
    }
}

public enum ThumbleBridgeLayoutRepairTarget: Decodable, Sendable {
    case all
    case repair(ThumbleBridgeLayoutRepairKind)

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ThumbleBridgeCodingKey.self)
        let kind = try container.decode(String.self, forKey: .init("kind"))
        switch kind {
        case "all":
            try container.requireOnly(["kind"])
            self = .all
        case "repair":
            try container.requireOnly(["kind", "repair"])
            self = .repair(try container.decode(
                ThumbleBridgeLayoutRepairKind.self,
                forKey: .init("repair")
            ))
        default:
            throw ThumbleConfigurationBridgeError.invalidCustomizationChanges
        }
    }

    fileprivate var shared: GamepadLayoutRepairTarget {
        switch self {
        case .all: .all
        case .repair(let repair): .repair(repair.shared)
        }
    }
}

public enum ThumbleBridgeLayoutRepairCanvas: Decodable, Sendable {
    case stored
    case frame(String)
    case size(width: Double, height: Double)

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ThumbleBridgeCodingKey.self)
        let source = try container.decode(String.self, forKey: .init("source"))
        switch source {
        case "stored":
            try container.requireOnly(["source"])
            self = .stored
        case "frame":
            try container.requireOnly(["source", "frameID"])
            self = .frame(try container.decode(String.self, forKey: .init("frameID")))
        case "size":
            try container.requireOnly(["source", "width", "height"])
            let width = try container.decode(Double.self, forKey: .init("width"))
            let height = try container.decode(Double.self, forKey: .init("height"))
            guard width.isFinite, height.isFinite,
                  (240 ... 1_800).contains(width), (240 ... 1_800).contains(height)
            else { throw ThumbleConfigurationBridgeError.invalidGeometry }
            self = .size(width: width, height: height)
        default:
            throw ThumbleConfigurationBridgeError.invalidDeviceFrame
        }
    }

    fileprivate func size(for customization: GamepadCustomization) throws -> CGSize {
        switch self {
        case .stored:
            return customization.deviceCanvas.editorDeviceFrame.screenRect.size
        case .frame(let frameID):
            guard frameID.utf8.count <= 128,
                  let frame = GamepadEditorDeviceCatalog.frames.first(where: { $0.id == frameID })
            else { throw ThumbleConfigurationBridgeError.invalidDeviceFrame }
            return frame.screenRect.size
        case let .size(width, height):
            return CGSize(width: width, height: height)
        }
    }
}

/// Boxed because layout repair decoding and orchestration are intentionally kept
/// off constrained bridge caller stacks.
public final class ThumbleBridgeCustomizationFixInput: Decodable, @unchecked Sendable {
    public let profileID: String
    public let variant: ThumbleBridgeLayoutVariant
    public let target: ThumbleBridgeLayoutRepairTarget
    public let canvas: ThumbleBridgeLayoutRepairCanvas
    public let includeLocked: Bool

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ThumbleBridgeCodingKey.self)
        try container.requireOnly(["type", "profileID", "variant", "target", "canvas", "includeLocked"])
        profileID = try container.decode(String.self, forKey: .init("profileID"))
        variant = try container.decode(ThumbleBridgeLayoutVariant.self, forKey: .init("variant"))
        target = try container.decode(ThumbleBridgeLayoutRepairTarget.self, forKey: .init("target"))
        canvas = try container.decode(ThumbleBridgeLayoutRepairCanvas.self, forKey: .init("canvas"))
        includeLocked = try container.decode(Bool.self, forKey: .init("includeLocked"))
    }
}

public enum ThumbleBridgeOperation: Decodable, Sendable {
    case bindingSet(profileID: String, button: GameButton, sequence: [ThumbleBridgeSemanticKeyStroke])
    case bindingClear(profileID: String, button: GameButton)
    case bindingReset(profileID: String, button: GameButton)
    case bindingResetAll(profileID: String)
    case outputMode(profileID: String, mode: GamepadProfileOutputMode)
    case outputSet(profileID: String, button: GameButton, keyboardEdit: ThumbleBridgeKeyboardOutputEdit, gamepadEdit: ThumbleBridgeGamepadOutputEdit)
    case outputReset(profileID: String, button: GameButton)
    case outputResetAll(profileID: String)
    case profileReset(profileID: String)
    case customizationSet(profileID: String, variant: ThumbleBridgeLayoutVariant, changes: ThumbleBridgeCustomizationChanges)
    case customizationReset(profileID: String, variant: ThumbleBridgeLayoutVariant)
    case customizationFix(ThumbleBridgeCustomizationFixInput)
    case orientationSet(profileID: String, preference: GamepadProfileOrientationPreference)
    case deviceSet(profileID: String, variant: ThumbleBridgeLayoutVariant, frameID: String)
    case controlBarSet(profileID: String, variant: ThumbleBridgeLayoutVariant, items: [GamepadControlBarItem])
    case controlBarAdd(profileID: String, variant: ThumbleBridgeLayoutVariant, item: GamepadControlBarItem)
    case controlBarRemove(profileID: String, variant: ThumbleBridgeLayoutVariant, item: GamepadControlBarItem)
    case controlBarMove(profileID: String, variant: ThumbleBridgeLayoutVariant, item: GamepadControlBarItem, direction: ThumbleBridgeControlBarMoveDirection)
    case styleCreate(profileID: String, styleID: String, name: String, appearance: ThumbleBridgeStyleAppearance)
    case styleRename(profileID: String, styleID: String, name: String)
    case styleApply(profileID: String, variant: ThumbleBridgeLayoutVariant, styleID: String, elementID: String)
    case styleDetach(profileID: String, variant: ThumbleBridgeLayoutVariant, elementID: String)
    case styleDelete(profileID: String, styleID: String)
    case layerMove(profileID: String, variant: ThumbleBridgeLayoutVariant, elementID: String, destination: ThumbleBridgeLayerMoveDestination)
    case layerForward(profileID: String, variant: ThumbleBridgeLayoutVariant, elementID: String)
    case layerBackward(profileID: String, variant: ThumbleBridgeLayoutVariant, elementID: String)
    case layerFront(profileID: String, variant: ThumbleBridgeLayoutVariant, elementID: String)
    case layerBack(profileID: String, variant: ThumbleBridgeLayoutVariant, elementID: String)
    case groupCreate(profileID: String, variant: ThumbleBridgeLayoutVariant, groupID: String, name: String, elementIDs: [String])
    case groupRename(profileID: String, variant: ThumbleBridgeLayoutVariant, groupID: String, name: String)
    case groupDuplicate(profileID: String, variant: ThumbleBridgeLayoutVariant, groupID: String, newGroupID: String, name: String?, newElementIDs: [String], offsetX: Double, offsetY: Double)
    case groupUngroup(profileID: String, variant: ThumbleBridgeLayoutVariant, groupID: String)
    case groupHide(profileID: String, variant: ThumbleBridgeLayoutVariant, groupID: String)
    case groupShow(profileID: String, variant: ThumbleBridgeLayoutVariant, groupID: String)
    case groupLock(profileID: String, variant: ThumbleBridgeLayoutVariant, groupID: String)
    case groupUnlock(profileID: String, variant: ThumbleBridgeLayoutVariant, groupID: String)
    case groupNudge(profileID: String, variant: ThumbleBridgeLayoutVariant, groupID: String, canvasFrameID: String, deltaX: Double, deltaY: Double)
    case groupForward(profileID: String, variant: ThumbleBridgeLayoutVariant, groupID: String)
    case groupBackward(profileID: String, variant: ThumbleBridgeLayoutVariant, groupID: String)
    case groupFront(profileID: String, variant: ThumbleBridgeLayoutVariant, groupID: String)
    case groupBack(profileID: String, variant: ThumbleBridgeLayoutVariant, groupID: String)
    case controlBarReset(profileID: String, variant: ThumbleBridgeLayoutVariant)
    case controlBarItemReset(profileID: String, variant: ThumbleBridgeLayoutVariant, item: GamepadControlBarItem)
    case controlBarItemSet(profileID: String, variant: ThumbleBridgeLayoutVariant, item: GamepadControlBarItem, changes: ThumbleBridgeControlBarItemChanges)
    case generationGenerate(preset: ThumbleBridgeGenerationPreset, presetRevision: Int, destination: ThumbleBridgeProfileDestination, newElementIDs: [String], select: Bool, makeDefault: Bool)
    case templateInstall(template: ThumbleBridgeControllerTemplate, templateRevision: Int, destination: ThumbleBridgeProfileDestination, name: String?, newElementIDs: [String], select: Bool, makeDefault: Bool)
    case profileSelect(profileID: String)
    case profileSetDefault(profileID: String)
    case profileDuplicate(profileID: String, newProfileID: String, name: String)
    case profileDelete(profileID: String, replacementProfileID: String?)
    case profileMove(profileID: String, index: Int)
    case profileCreate(name: String, newProfileID: String, sourceProfileID: String?, select: Bool, makeDefault: Bool)
    case themeApply(profileID: String, variant: ThumbleBridgeLayoutVariant, preset: String)
    case orientationCopy(profileID: String, source: GamepadProfileLayoutVariant, destination: GamepadProfileLayoutVariant, automaticallyArrange: Bool)
    case elementAdd(profileID: String, variant: ThumbleBridgeLayoutVariant, elementID: String, kind: GamepadCustomControlKind, mappedButton: GameButton?, changes: ThumbleBridgeElementChanges)
    case elementSet(profileID: String, variant: ThumbleBridgeLayoutVariant, elementID: String, changes: ThumbleBridgeElementChanges)
    case elementDuplicate(profileID: String, variant: ThumbleBridgeLayoutVariant, elementIDs: [String], newElementIDs: [String], offsetX: Double, offsetY: Double)
    case elementAlign(profileID: String, variant: ThumbleBridgeLayoutVariant, elementIDs: [String], alignment: String)
    case elementDistribute(profileID: String, variant: ThumbleBridgeLayoutVariant, elementIDs: [String], distribution: String)
    case elementNudge(profileID: String, variant: ThumbleBridgeLayoutVariant, elementIDs: [String], deltaX: Double, deltaY: Double)
    case elementDelete(profileID: String, variant: ThumbleBridgeLayoutVariant, elementID: String)
    case elementReset(profileID: String, variant: ThumbleBridgeLayoutVariant, elementID: String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ThumbleBridgeCodingKey.self)
        let type = try container.decode(String.self, forKey: .init("type"))
        switch type {
        case "binding.set":
            try container.requireOnly(["type", "profileID", "button", "sequence"])
            self = .bindingSet(
                profileID: try container.decode(String.self, forKey: .init("profileID")),
                button: try container.decode(GameButton.self, forKey: .init("button")),
                sequence: try container.decode([ThumbleBridgeSemanticKeyStroke].self, forKey: .init("sequence"))
            )
        case "binding.clear":
            try container.requireOnly(["type", "profileID", "button"])
            self = .bindingClear(
                profileID: try container.decode(String.self, forKey: .init("profileID")),
                button: try container.decode(GameButton.self, forKey: .init("button"))
            )
        case "binding.reset":
            try container.requireOnly(["type", "profileID", "button"])
            self = .bindingReset(
                profileID: try container.decode(String.self, forKey: .init("profileID")),
                button: try container.decode(GameButton.self, forKey: .init("button"))
            )
        case "binding.reset-all":
            try container.requireOnly(["type", "profileID"])
            self = .bindingResetAll(
                profileID: try container.decode(String.self, forKey: .init("profileID"))
            )
        case "output.mode":
            try container.requireOnly(["type", "profileID", "mode"])
            self = .outputMode(
                profileID: try container.decode(String.self, forKey: .init("profileID")),
                mode: try container.decode(GamepadProfileOutputMode.self, forKey: .init("mode"))
            )
        case "output.set":
            try container.requireOnly(["type", "profileID", "button", "keyboardEdit", "gamepadEdit"])
            self = .outputSet(
                profileID: try container.decode(String.self, forKey: .init("profileID")),
                button: try container.decode(GameButton.self, forKey: .init("button")),
                keyboardEdit: try container.decode(
                    ThumbleBridgeKeyboardOutputEdit.self,
                    forKey: .init("keyboardEdit")
                ),
                gamepadEdit: try container.decode(
                    ThumbleBridgeGamepadOutputEdit.self,
                    forKey: .init("gamepadEdit")
                )
            )
        case "output.reset":
            try container.requireOnly(["type", "profileID", "button"])

            self = .outputReset(
                profileID: try container.decode(String.self, forKey: .init("profileID")),
                button: try container.decode(GameButton.self, forKey: .init("button"))
            )
        case "output.reset-all":
            try container.requireOnly(["type", "profileID"])
            self = .outputResetAll(
                profileID: try container.decode(String.self, forKey: .init("profileID"))
            )
        case "profile.reset":
            try container.requireOnly(["type", "profileID"])
            self = .profileReset(
                profileID: try container.decode(String.self, forKey: .init("profileID"))
            )
        case "customization.set":
            try container.requireOnly(["type", "profileID", "variant", "changes"])
            self = .customizationSet(
                profileID: try container.decode(String.self, forKey: .init("profileID")),
                variant: try container.decode(ThumbleBridgeLayoutVariant.self, forKey: .init("variant")),
                changes: try container.decode(ThumbleBridgeCustomizationChanges.self, forKey: .init("changes"))
            )
        case "customization.reset":
            try container.requireOnly(["type", "profileID", "variant"])
            self = .customizationReset(
                profileID: try container.decode(String.self, forKey: .init("profileID")),
                variant: try container.decode(ThumbleBridgeLayoutVariant.self, forKey: .init("variant"))
            )
        case "customization.fix":
            try container.requireOnly(["type", "profileID", "variant", "target", "canvas", "includeLocked"])
            self = .customizationFix(try ThumbleBridgeCustomizationFixInput(from: decoder))
        case "orientation.set":
            try container.requireOnly(["type", "profileID", "preference"])
            self = .orientationSet(
                profileID: try container.decode(String.self, forKey: .init("profileID")),
                preference: try container.decode(GamepadProfileOrientationPreference.self, forKey: .init("preference"))
            )
        case "device.set":
            try container.requireOnly(["type", "profileID", "variant", "frameID"])
            self = .deviceSet(
                profileID: try container.decode(String.self, forKey: .init("profileID")),
                variant: try container.decode(ThumbleBridgeLayoutVariant.self, forKey: .init("variant")),
                frameID: try container.decode(String.self, forKey: .init("frameID"))
            )
        case "control-bar.set":
            try container.requireOnly(["type", "profileID", "variant", "items"])
            self = .controlBarSet(
                profileID: try container.decode(String.self, forKey: .init("profileID")),
                variant: try container.decode(ThumbleBridgeLayoutVariant.self, forKey: .init("variant")),
                items: try container.decode([GamepadControlBarItem].self, forKey: .init("items"))
            )
        case "control-bar.add":
            try container.requireOnly(["type", "profileID", "variant", "item"])
            self = .controlBarAdd(
                profileID: try container.decode(String.self, forKey: .init("profileID")),
                variant: try container.decode(ThumbleBridgeLayoutVariant.self, forKey: .init("variant")),
                item: try container.decode(GamepadControlBarItem.self, forKey: .init("item"))
            )
        case "control-bar.remove":
            try container.requireOnly(["type", "profileID", "variant", "item"])
            self = .controlBarRemove(
                profileID: try container.decode(String.self, forKey: .init("profileID")),
                variant: try container.decode(ThumbleBridgeLayoutVariant.self, forKey: .init("variant")),
                item: try container.decode(GamepadControlBarItem.self, forKey: .init("item"))
            )
        case "control-bar.move":
            try container.requireOnly(["type", "profileID", "variant", "item", "direction"])
            self = .controlBarMove(
                profileID: try container.decode(String.self, forKey: .init("profileID")),
                variant: try container.decode(ThumbleBridgeLayoutVariant.self, forKey: .init("variant")),
                item: try container.decode(GamepadControlBarItem.self, forKey: .init("item")),
                direction: try container.decode(ThumbleBridgeControlBarMoveDirection.self, forKey: .init("direction"))
            )
        case "style.create":
            try container.requireOnly(["type", "profileID", "styleID", "name", "appearance"])
            self = .styleCreate(
                profileID: try container.decode(String.self, forKey: .init("profileID")),
                styleID: try container.decode(String.self, forKey: .init("styleID")),
                name: try container.decode(String.self, forKey: .init("name")),
                appearance: try container.decode(ThumbleBridgeStyleAppearance.self, forKey: .init("appearance"))
            )
        case "style.rename":
            try container.requireOnly(["type", "profileID", "styleID", "name"])
            self = .styleRename(
                profileID: try container.decode(String.self, forKey: .init("profileID")),
                styleID: try container.decode(String.self, forKey: .init("styleID")),
                name: try container.decode(String.self, forKey: .init("name"))
            )
        case "style.apply":
            try container.requireOnly(["type", "profileID", "variant", "styleID", "elementID"])
            self = .styleApply(
                profileID: try container.decode(String.self, forKey: .init("profileID")),
                variant: try container.decode(ThumbleBridgeLayoutVariant.self, forKey: .init("variant")),
                styleID: try container.decode(String.self, forKey: .init("styleID")),
                elementID: try container.decode(String.self, forKey: .init("elementID"))
            )
        case "style.detach":
            try container.requireOnly(["type", "profileID", "variant", "elementID"])
            self = .styleDetach(
                profileID: try container.decode(String.self, forKey: .init("profileID")),
                variant: try container.decode(ThumbleBridgeLayoutVariant.self, forKey: .init("variant")),
                elementID: try container.decode(String.self, forKey: .init("elementID"))
            )
        case "style.delete":
            try container.requireOnly(["type", "profileID", "styleID"])
            self = .styleDelete(
                profileID: try container.decode(String.self, forKey: .init("profileID")),
                styleID: try container.decode(String.self, forKey: .init("styleID"))
            )
        case "layer.move":
            try container.requireOnly(["type", "profileID", "variant", "elementID", "destination"])
            self = .layerMove(
                profileID: try container.decode(String.self, forKey: .init("profileID")),
                variant: try container.decode(ThumbleBridgeLayoutVariant.self, forKey: .init("variant")),
                elementID: try container.decode(String.self, forKey: .init("elementID")),
                destination: try container.decode(ThumbleBridgeLayerMoveDestination.self, forKey: .init("destination"))
            )
        case "layer.forward":
            try container.requireOnly(["type", "profileID", "variant", "elementID"])
            self = .layerForward(
                profileID: try container.decode(String.self, forKey: .init("profileID")),
                variant: try container.decode(ThumbleBridgeLayoutVariant.self, forKey: .init("variant")),
                elementID: try container.decode(String.self, forKey: .init("elementID"))
            )
        case "layer.backward":
            try container.requireOnly(["type", "profileID", "variant", "elementID"])
            self = .layerBackward(
                profileID: try container.decode(String.self, forKey: .init("profileID")),
                variant: try container.decode(ThumbleBridgeLayoutVariant.self, forKey: .init("variant")),
                elementID: try container.decode(String.self, forKey: .init("elementID"))
            )
        case "layer.front":
            try container.requireOnly(["type", "profileID", "variant", "elementID"])
            self = .layerFront(
                profileID: try container.decode(String.self, forKey: .init("profileID")),
                variant: try container.decode(ThumbleBridgeLayoutVariant.self, forKey: .init("variant")),
                elementID: try container.decode(String.self, forKey: .init("elementID"))
            )
        case "layer.back":
            try container.requireOnly(["type", "profileID", "variant", "elementID"])
            self = .layerBack(
                profileID: try container.decode(String.self, forKey: .init("profileID")),
                variant: try container.decode(ThumbleBridgeLayoutVariant.self, forKey: .init("variant")),
                elementID: try container.decode(String.self, forKey: .init("elementID"))
            )
        case "group.create":
            try container.requireOnly(["type", "profileID", "variant", "groupID", "name", "elementIDs"])
            self = .groupCreate(
                profileID: try container.decode(String.self, forKey: .init("profileID")),
                variant: try container.decode(ThumbleBridgeLayoutVariant.self, forKey: .init("variant")),
                groupID: try container.decode(String.self, forKey: .init("groupID")),
                name: try container.decode(String.self, forKey: .init("name")),
                elementIDs: try container.decode([String].self, forKey: .init("elementIDs"))
            )
        case "group.rename":
            try container.requireOnly(["type", "profileID", "variant", "groupID", "name"])
            self = .groupRename(
                profileID: try container.decode(String.self, forKey: .init("profileID")),
                variant: try container.decode(ThumbleBridgeLayoutVariant.self, forKey: .init("variant")),
                groupID: try container.decode(String.self, forKey: .init("groupID")),
                name: try container.decode(String.self, forKey: .init("name"))
            )
        case "group.duplicate":
            try container.requireOnly(["type", "profileID", "variant", "groupID", "newGroupID", "name", "newElementIDs", "offsetX", "offsetY"])
            self = .groupDuplicate(
                profileID: try container.decode(String.self, forKey: .init("profileID")),
                variant: try container.decode(ThumbleBridgeLayoutVariant.self, forKey: .init("variant")),
                groupID: try container.decode(String.self, forKey: .init("groupID")),
                newGroupID: try container.decode(String.self, forKey: .init("newGroupID")),
                name: try container.decodeIfPresent(String.self, forKey: .init("name")),
                newElementIDs: try container.decode([String].self, forKey: .init("newElementIDs")),
                offsetX: try container.decode(Double.self, forKey: .init("offsetX")),
                offsetY: try container.decode(Double.self, forKey: .init("offsetY"))
            )
        case "group.ungroup":
            try container.requireOnly(["type", "profileID", "variant", "groupID"])
            self = .groupUngroup(
                profileID: try container.decode(String.self, forKey: .init("profileID")),
                variant: try container.decode(ThumbleBridgeLayoutVariant.self, forKey: .init("variant")),
                groupID: try container.decode(String.self, forKey: .init("groupID"))
            )
        case "group.hide", "group.show", "group.lock", "group.unlock",
             "group.forward", "group.backward", "group.front", "group.back":
            try container.requireOnly(["type", "profileID", "variant", "groupID"])
            let profileID = try container.decode(String.self, forKey: .init("profileID"))
            let variant = try container.decode(ThumbleBridgeLayoutVariant.self, forKey: .init("variant"))
            let groupID = try container.decode(String.self, forKey: .init("groupID"))
            switch type {
            case "group.hide": self = .groupHide(profileID: profileID, variant: variant, groupID: groupID)
            case "group.show": self = .groupShow(profileID: profileID, variant: variant, groupID: groupID)
            case "group.lock": self = .groupLock(profileID: profileID, variant: variant, groupID: groupID)
            case "group.unlock": self = .groupUnlock(profileID: profileID, variant: variant, groupID: groupID)
            case "group.forward": self = .groupForward(profileID: profileID, variant: variant, groupID: groupID)
            case "group.backward": self = .groupBackward(profileID: profileID, variant: variant, groupID: groupID)
            case "group.front": self = .groupFront(profileID: profileID, variant: variant, groupID: groupID)
            default: self = .groupBack(profileID: profileID, variant: variant, groupID: groupID)
            }
        case "group.nudge":
            try container.requireOnly(["type", "profileID", "variant", "groupID", "canvasFrameID", "deltaX", "deltaY"])
            self = .groupNudge(
                profileID: try container.decode(String.self, forKey: .init("profileID")),
                variant: try container.decode(ThumbleBridgeLayoutVariant.self, forKey: .init("variant")),
                groupID: try container.decode(String.self, forKey: .init("groupID")),
                canvasFrameID: try container.decodeIfPresent(String.self, forKey: .init("canvasFrameID"))
                    ?? GamepadEditorDeviceCatalog.defaultFrameID,
                deltaX: try container.decode(Double.self, forKey: .init("deltaX")),
                deltaY: try container.decode(Double.self, forKey: .init("deltaY"))
            )
        case "control-bar.reset":
            try container.requireOnly(["type", "profileID", "variant"])
            self = .controlBarReset(
                profileID: try container.decode(String.self, forKey: .init("profileID")),
                variant: try container.decode(ThumbleBridgeLayoutVariant.self, forKey: .init("variant"))
            )
        case "control-bar.item.reset":
            try container.requireOnly(["type", "profileID", "variant", "item"])
            self = .controlBarItemReset(
                profileID: try container.decode(String.self, forKey: .init("profileID")),
                variant: try container.decode(ThumbleBridgeLayoutVariant.self, forKey: .init("variant")),
                item: try container.decode(GamepadControlBarItem.self, forKey: .init("item"))
            )
        case "control-bar.item.set":
            try container.requireOnly(["type", "profileID", "variant", "item", "changes"])
            self = .controlBarItemSet(
                profileID: try container.decode(String.self, forKey: .init("profileID")),
                variant: try container.decode(ThumbleBridgeLayoutVariant.self, forKey: .init("variant")),
                item: try container.decode(GamepadControlBarItem.self, forKey: .init("item")),
                changes: try container.decode(ThumbleBridgeControlBarItemChanges.self, forKey: .init("changes"))
            )
        case "generation.generate":
            try container.requireOnly([
                "type", "preset", "presetRevision", "destination", "newElementIDs",
                "select", "makeDefault"
            ])
            self = .generationGenerate(
                preset: try container.decode(ThumbleBridgeGenerationPreset.self, forKey: .init("preset")),
                presetRevision: try container.decode(Int.self, forKey: .init("presetRevision")),
                destination: try container.decode(ThumbleBridgeProfileDestination.self, forKey: .init("destination")),
                newElementIDs: try container.decode([String].self, forKey: .init("newElementIDs")),
                select: try container.decode(Bool.self, forKey: .init("select")),
                makeDefault: try container.decode(Bool.self, forKey: .init("makeDefault"))
            )
        case "template.install":
            try container.requireOnly([
                "type", "template", "templateRevision", "destination", "name",
                "newElementIDs", "select", "makeDefault"
            ])
            self = .templateInstall(
                template: try container.decode(ThumbleBridgeControllerTemplate.self, forKey: .init("template")),
                templateRevision: try container.decode(Int.self, forKey: .init("templateRevision")),
                destination: try container.decode(ThumbleBridgeProfileDestination.self, forKey: .init("destination")),
                name: try container.decodeIfPresent(String.self, forKey: .init("name")),
                newElementIDs: try container.decode([String].self, forKey: .init("newElementIDs")),
                select: try container.decode(Bool.self, forKey: .init("select")),
                makeDefault: try container.decode(Bool.self, forKey: .init("makeDefault"))
            )
        case "profile.select":
            try container.requireOnly(["type", "profileID"])
            self = .profileSelect(profileID: try container.decode(String.self, forKey: .init("profileID")))
        case "profile.default":
            try container.requireOnly(["type", "profileID"])
            self = .profileSetDefault(profileID: try container.decode(String.self, forKey: .init("profileID")))
        case "profile.duplicate":
            try container.requireOnly(["type", "profileID", "newProfileID", "name"])
            self = .profileDuplicate(
                profileID: try container.decode(String.self, forKey: .init("profileID")),
                newProfileID: try container.decode(String.self, forKey: .init("newProfileID")),
                name: try container.decode(String.self, forKey: .init("name"))
            )
        case "profile.delete":
            try container.requireOnly(["type", "profileID", "replacementProfileID"])
            self = .profileDelete(
                profileID: try container.decode(String.self, forKey: .init("profileID")),
                replacementProfileID: try container.decodeIfPresent(String.self, forKey: .init("replacementProfileID"))
            )
        case "profile.move":
            try container.requireOnly(["type", "profileID", "index"])
            self = .profileMove(
                profileID: try container.decode(String.self, forKey: .init("profileID")),
                index: try container.decode(Int.self, forKey: .init("index"))
            )
        case "profile.create":
            try container.requireOnly(["type", "name", "newProfileID", "sourceProfileID", "select", "makeDefault"])
            self = .profileCreate(
                name: try container.decode(String.self, forKey: .init("name")),
                newProfileID: try container.decode(String.self, forKey: .init("newProfileID")),
                sourceProfileID: try container.decodeIfPresent(String.self, forKey: .init("sourceProfileID")),
                select: try container.decodeIfPresent(Bool.self, forKey: .init("select")) ?? false,
                makeDefault: try container.decodeIfPresent(Bool.self, forKey: .init("makeDefault")) ?? false
            )
        case "theme.apply":
            try container.requireOnly(["type", "profileID", "variant", "preset"])
            self = .themeApply(
                profileID: try container.decode(String.self, forKey: .init("profileID")),
                variant: try container.decode(ThumbleBridgeLayoutVariant.self, forKey: .init("variant")),
                preset: try container.decode(String.self, forKey: .init("preset"))
            )
        case "orientation.copy":
            try container.requireOnly(["type", "profileID", "source", "destination", "automaticallyArrange"])
            let sourceValue = try container.decode(String.self, forKey: .init("source"))
            let destinationValue = try container.decode(String.self, forKey: .init("destination"))
            guard let source = GamepadProfileLayoutVariant(rawValue: sourceValue),
                  let destination = GamepadProfileLayoutVariant(rawValue: destinationValue)
            else { throw ThumbleConfigurationBridgeError.invalidOrientation }
            self = .orientationCopy(
                profileID: try container.decode(String.self, forKey: .init("profileID")),
                source: source,
                destination: destination,
                automaticallyArrange: try container.decodeIfPresent(Bool.self, forKey: .init("automaticallyArrange")) ?? true
            )
        case "element.add":
            try container.requireOnly(["type", "profileID", "variant", "elementID", "kind", "mappedButton", "changes"])
            self = .elementAdd(
                profileID: try container.decode(String.self, forKey: .init("profileID")),
                variant: try container.decode(ThumbleBridgeLayoutVariant.self, forKey: .init("variant")),
                elementID: try container.decode(String.self, forKey: .init("elementID")),
                kind: try container.decode(GamepadCustomControlKind.self, forKey: .init("kind")),
                mappedButton: try container.decodeIfPresent(GameButton.self, forKey: .init("mappedButton")),
                changes: try container.decode(ThumbleBridgeElementChanges.self, forKey: .init("changes"))
            )
        case "element.set":
            try container.requireOnly(["type", "profileID", "variant", "elementID", "changes"])
            self = .elementSet(
                profileID: try container.decode(String.self, forKey: .init("profileID")),
                variant: try container.decode(ThumbleBridgeLayoutVariant.self, forKey: .init("variant")),
                elementID: try container.decode(String.self, forKey: .init("elementID")),
                changes: try container.decode(ThumbleBridgeElementChanges.self, forKey: .init("changes"))
            )
        case "element.duplicate":
            try container.requireOnly(["type", "profileID", "variant", "elementIDs", "newElementIDs", "offsetX", "offsetY"])
            self = .elementDuplicate(
                profileID: try container.decode(String.self, forKey: .init("profileID")),
                variant: try container.decode(ThumbleBridgeLayoutVariant.self, forKey: .init("variant")),
                elementIDs: try container.decode([String].self, forKey: .init("elementIDs")),
                newElementIDs: try container.decode([String].self, forKey: .init("newElementIDs")),
                offsetX: try container.decode(Double.self, forKey: .init("offsetX")),
                offsetY: try container.decode(Double.self, forKey: .init("offsetY"))
            )
        case "element.align":
            try container.requireOnly(["type", "profileID", "variant", "elementIDs", "alignment"])
            self = .elementAlign(
                profileID: try container.decode(String.self, forKey: .init("profileID")),
                variant: try container.decode(ThumbleBridgeLayoutVariant.self, forKey: .init("variant")),
                elementIDs: try container.decode([String].self, forKey: .init("elementIDs")),
                alignment: try container.decode(String.self, forKey: .init("alignment"))
            )
        case "element.distribute":
            try container.requireOnly(["type", "profileID", "variant", "elementIDs", "distribution"])
            self = .elementDistribute(
                profileID: try container.decode(String.self, forKey: .init("profileID")),
                variant: try container.decode(ThumbleBridgeLayoutVariant.self, forKey: .init("variant")),
                elementIDs: try container.decode([String].self, forKey: .init("elementIDs")),
                distribution: try container.decode(String.self, forKey: .init("distribution"))
            )
        case "element.nudge":
            try container.requireOnly(["type", "profileID", "variant", "elementIDs", "deltaX", "deltaY"])
            self = .elementNudge(
                profileID: try container.decode(String.self, forKey: .init("profileID")),
                variant: try container.decode(ThumbleBridgeLayoutVariant.self, forKey: .init("variant")),
                elementIDs: try container.decode([String].self, forKey: .init("elementIDs")),
                deltaX: try container.decode(Double.self, forKey: .init("deltaX")),
                deltaY: try container.decode(Double.self, forKey: .init("deltaY"))
            )
        case "element.delete":
            try container.requireOnly(["type", "profileID", "variant", "elementID"])
            self = .elementDelete(
                profileID: try container.decode(String.self, forKey: .init("profileID")),
                variant: try container.decode(ThumbleBridgeLayoutVariant.self, forKey: .init("variant")),
                elementID: try container.decode(String.self, forKey: .init("elementID"))
            )
        case "element.reset":
            try container.requireOnly(["type", "profileID", "variant", "elementID"])
            self = .elementReset(
                profileID: try container.decode(String.self, forKey: .init("profileID")),
                variant: try container.decode(ThumbleBridgeLayoutVariant.self, forKey: .init("variant")),
                elementID: try container.decode(String.self, forKey: .init("elementID"))
            )
        default:
            throw ThumbleConfigurationBridgeError.unsupportedOperation
        }
    }
}

public enum ThumbleConfigurationBridge {
    public static func transform(_ request: ThumbleConfigurationBridgeRequest) throws -> ThumbleConfigurationBridgeResponse {
        guard request.schemaVersion == thumbleConfigurationBridgeSchemaVersion else {
            throw ThumbleConfigurationBridgeError.unsupportedSchemaVersion
        }
        guard request.nowMillis >= 0 else { throw ThumbleConfigurationBridgeError.invalidTimestamp }
        var document = request.document
        try validate(document)
        let before = document
        let changedPaths = try apply(request.operation, to: &document, nowMillis: request.nowMillis)
        try validate(document)
        return ThumbleConfigurationBridgeResponse(
            document: document,
            changed: document != before,
            changedPaths: document == before ? [] : Array(Set(changedPaths)).sorted()
        )
    }

    private static func apply(
        _ operation: ThumbleBridgeOperation,
        to document: inout ThumbleBridgeConfigurationDocument,
        nowMillis: Int64
    ) throws -> [String] {
        switch operation {
        #if os(macOS)
        case let .bindingSet(profileID, button, sequence):
            let binding = try semanticKeyBinding(sequence)
            return try applyBindingChange(
                profileID: profileID,
                document: &document,
                nowMillis: nowMillis
            ) { bindings, _ in
                bindings[button] = binding
            }
        case let .bindingClear(profileID, button):
            return try applyBindingChange(
                profileID: profileID,
                document: &document,
                nowMillis: nowMillis
            ) { bindings, _ in
                bindings[button] = nil
            }
        case let .bindingReset(profileID, button):
            return try applyBindingChange(
                profileID: profileID,
                document: &document,
                nowMillis: nowMillis
            ) { bindings, profile in
                bindings[button] = profile.recommendedMacOutputBindings[button]?.keyboard
            }
        case .bindingResetAll(let profileID):
            return try applyBindingChange(
                profileID: profileID,
                document: &document,
                nowMillis: nowMillis
            ) { bindings, profile in
                bindings = profile.recommendedMacOutputBindings.keyboardBindings
            }
        case let .outputMode(profileID, mode):
            return try applyOutputMode(
                profileID: profileID,
                mode: mode,
                document: &document,
                nowMillis: nowMillis
            )
        case let .outputSet(profileID, button, keyboardEdit, gamepadEdit):
            return try applyOutputSet(
                profileID: profileID,
                button: button,
                keyboardEdit: keyboardEdit,
                gamepadEdit: gamepadEdit,
                document: &document,
                nowMillis: nowMillis
            )
        case let .outputReset(profileID, button):
            return try applyOutputReset(
                profileID: profileID,
                button: button,
                document: &document,
                nowMillis: nowMillis
            )
        case .outputResetAll(let profileID):
            return try applyOutputResetAll(
                profileID: profileID,
                document: &document,
                nowMillis: nowMillis
            )
        #else
        case .bindingSet, .bindingClear, .bindingReset, .bindingResetAll,
             .outputMode, .outputSet, .outputReset, .outputResetAll:
            throw ThumbleConfigurationBridgeError.unsupportedOperation
        #endif
        case .profileReset(let profileID):
            return try mutateProfile(profileID, in: &document, nowMillis: nowMillis) { profile in
                profile.customization = .defaultValue
                profile.landscapeCustomization = nil
                profile.portraitCustomization = nil
            }
        case let .customizationSet(profileID, variant, changes):
            guard !changes.isEmpty else {
                throw ThumbleConfigurationBridgeError.invalidCustomizationChanges
            }
            return try mutateProfile(profileID, in: &document, nowMillis: nowMillis) { profile in
                var customization = customization(in: profile, variant: variant)
                if let layoutMode = changes.layoutMode { customization.layoutMode = layoutMode }
                if let controlScale = changes.controlScale { customization.controlScale = controlScale }
                if let colorScheme = changes.colorScheme { customization.colorSchemePreference = colorScheme }
                if let accentStyle = changes.accentStyle { customization.accentStyle = accentStyle }
                if let showsButtonLabels = changes.showsButtonLabels {
                    customization.showsButtonLabels = showsButtonLabels
                }
                switch changes.backgroundEdit {
                case .keep:
                    break
                case .clear:
                    customization.backgroundLightColor = nil
                    customization.backgroundDarkColor = nil
                    customization.backgroundFillStyle = nil
                    customization.backgroundLightFillStyle = nil
                    customization.backgroundDarkFillStyle = nil
                case let .set(scope, inputColor):
                    guard let color = inputColor.color else {
                        throw ThumbleConfigurationBridgeError.invalidCustomizationChanges
                    }
                    switch scope {
                    case .all:
                        customization.backgroundLightColor = color.normalized
                        customization.backgroundDarkColor = color.normalized
                        customization.backgroundFillStyle = nil
                        customization.backgroundLightFillStyle = nil
                        customization.backgroundDarkFillStyle = nil
                    case .light:
                        customization.backgroundLightColor = color.normalized
                        customization.backgroundLightFillStyle = nil
                    case .dark:
                        customization.backgroundDarkColor = color.normalized
                        customization.backgroundDarkFillStyle = nil
                    }
                }
                setCustomization(customization, in: &profile, variant: variant)
            }
        case let .customizationReset(profileID, variant):
            return try mutateProfile(profileID, in: &document, nowMillis: nowMillis) { profile in
                setCustomization(.defaultValue, in: &profile, variant: variant)
            }
        case .customizationFix(let input):
            return try mutateProfile(input.profileID, in: &document, nowMillis: nowMillis) { profile in
                var customization = customization(in: profile, variant: input.variant)
                let canvasSize = try input.canvas.size(for: customization)
                _ = customization.applyLayoutRepairs(
                    target: input.target.shared,
                    canvasSize: canvasSize,
                    respectingLocks: !input.includeLocked
                )
                setCustomization(customization, in: &profile, variant: input.variant)
            }
        case let .orientationSet(profileID, preference):
            return try mutateProfile(profileID, in: &document, nowMillis: nowMillis) { profile in
                profile.orientationPreference = preference
            }
        case let .deviceSet(profileID, variant, frameID):
            guard frameID.utf8.count <= 128,
                  let frame = GamepadEditorDeviceCatalog.frames.first(where: { $0.id == frameID }),
                  variant == .primary
                    || (variant == .landscape && frame.orientation == .landscape)
                    || (variant == .portrait && frame.orientation == .portrait)
            else { throw ThumbleConfigurationBridgeError.invalidDeviceFrame }
            return try mutateProfile(profileID, in: &document, nowMillis: nowMillis) { profile in
                var customization = customization(in: profile, variant: variant)
                customization.deviceCanvas = GamepadDeviceCanvas(frameID: frame.id)
                setCustomization(customization, in: &profile, variant: variant)
            }
        case let .controlBarSet(profileID, variant, items):
            guard !items.isEmpty, items.count <= GamepadControlBarItem.allCases.count,
                  Set(items).count == items.count
            else { throw ThumbleConfigurationBridgeError.invalidControlBar }
            return try mutateProfile(profileID, in: &document, nowMillis: nowMillis) { profile in
                var customization = customization(in: profile, variant: variant)
                customization.controlBarItems = GamepadCustomization.normalizedControlBarItems(items)
                setCustomization(customization, in: &profile, variant: variant)
            }
        case let .controlBarAdd(profileID, variant, item):
            return try mutateProfile(profileID, in: &document, nowMillis: nowMillis) { profile in
                var customization = customization(in: profile, variant: variant)
                customization.addControlBarItem(item)
                setCustomization(customization, in: &profile, variant: variant)
            }
        case let .controlBarRemove(profileID, variant, item):
            return try mutateProfile(profileID, in: &document, nowMillis: nowMillis) { profile in
                var customization = customization(in: profile, variant: variant)
                customization.removeControlBarItem(item)
                setCustomization(customization, in: &profile, variant: variant)
            }
        case let .controlBarMove(profileID, variant, item, direction):
            return try mutateProfile(profileID, in: &document, nowMillis: nowMillis) { profile in
                var customization = customization(in: profile, variant: variant)
                let items = GamepadCustomization.normalizedControlBarItems(customization.controlBarItems)
                guard let index = items.firstIndex(of: item) else { return }
                let offset = direction == .up ? -1 : 1
                let destination = min(max(index + offset, 0), max(items.count - 1, 0))
                guard destination != index else { return }
                customization.moveControlBarItem(item, to: destination)
                setCustomization(customization, in: &profile, variant: variant)
            }
        case let .styleCreate(profileID, styleID, name, appearance):
            let token = try appearance.token(id: styleID, name: name)
            return try mutateProfile(profileID, in: &document, nowMillis: nowMillis) { profile in
                mutateStyleResources(in: &profile) { customization in
                    customization.upsertReusableStyle(token)
                }
            }
        case let .styleRename(profileID, styleID, name):
            let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard styleID == GamepadStyleToken.normalizedIdentifier(styleID), styleID.utf8.count <= 128,
                  !normalizedName.isEmpty, normalizedName.count <= 48
            else { throw ThumbleConfigurationBridgeError.invalidStyle }
            return try mutateProfile(profileID, in: &document, nowMillis: nowMillis) { profile in
                guard profile.customization.styleLibrary.style(id: styleID) != nil else {
                    throw ThumbleConfigurationBridgeError.invalidStyle
                }
                mutateStyleResources(in: &profile) { customization in
                    _ = customization.renameReusableStyle(id: styleID, name: normalizedName)
                }
            }
        case let .styleApply(profileID, variant, styleID, elementID):
            try validateStyleID(styleID)
            try validateElementIDs([elementID], minimum: 1)
            return try mutateProfile(profileID, in: &document, nowMillis: nowMillis) { profile in
                var customization = customization(in: profile, variant: variant)
                guard customization.styleLibrary.style(id: styleID) != nil else {
                    throw ThumbleConfigurationBridgeError.invalidStyle
                }
                let identity = try layerIdentity(elementID, in: customization)
                try setStyleID(styleID, for: identity, in: &customization)
                setCustomization(customization, in: &profile, variant: variant)
            }
        case let .styleDetach(profileID, variant, elementID):
            try validateElementIDs([elementID], minimum: 1)
            return try mutateProfile(profileID, in: &document, nowMillis: nowMillis) { profile in
                var customization = customization(in: profile, variant: variant)
                let identity = try layerIdentity(elementID, in: customization)
                try setStyleID(nil, for: identity, in: &customization)
                setCustomization(customization, in: &profile, variant: variant)
            }
        case let .styleDelete(profileID, styleID):
            try validateStyleID(styleID)
            return try mutateProfile(profileID, in: &document, nowMillis: nowMillis) { profile in
                mutateStyleResources(in: &profile) { customization in
                    customization.deleteReusableStyle(id: styleID)
                }
            }
        case let .layerMove(profileID, variant, elementID, destination):
            try validateElementIDs([elementID], minimum: 1)
            if case .index(let index) = destination, !(-512 ... 512).contains(index) {
                throw ThumbleConfigurationBridgeError.invalidLayerDestination
            }
            return try mutateProfile(profileID, in: &document, nowMillis: nowMillis) { profile in
                var customization = customization(in: profile, variant: variant)
                let identity = try layerIdentity(elementID, in: customization)
                let index: Int
                switch destination {
                case .index(let value):
                    index = value
                case .before(let referenceID):
                    let reference = try layerIdentity(referenceID, in: customization)
                    index = customization.orderedControlIdentitiesForDesign.firstIndex(of: reference) ?? 0
                case .after(let referenceID):
                    let reference = try layerIdentity(referenceID, in: customization)
                    let order = customization.orderedControlIdentitiesForDesign
                    index = (order.firstIndex(of: reference) ?? max(order.count - 1, 0)) + 1
                }
                customization.moveLayer(identity, to: index)
                setCustomization(customization, in: &profile, variant: variant)
            }
        case let .layerForward(profileID, variant, elementID):
            return try mutateLayer(profileID, variant: variant, elementID: elementID, in: &document, nowMillis: nowMillis) {
                $0.bringLayerForward($1)
            }
        case let .layerBackward(profileID, variant, elementID):
            return try mutateLayer(profileID, variant: variant, elementID: elementID, in: &document, nowMillis: nowMillis) {
                $0.sendLayerBackward($1)
            }
        case let .layerFront(profileID, variant, elementID):
            return try mutateLayer(profileID, variant: variant, elementID: elementID, in: &document, nowMillis: nowMillis) {
                $0.bringLayerToFront($1)
            }
        case let .layerBack(profileID, variant, elementID):
            return try mutateLayer(profileID, variant: variant, elementID: elementID, in: &document, nowMillis: nowMillis) {
                $0.sendLayerToBack($1)
            }
        case let .groupCreate(profileID, variant, groupID, name, elementIDs):
            try validateElementIDs(elementIDs, minimum: 1)
            let groupID = try groupUUID(groupID)
            return try mutateProfile(profileID, in: &document, nowMillis: nowMillis) { profile in
                var customization = customization(in: profile, variant: variant)
                let children = try elementIDs.map { try layerIdentity($0, in: customization) }
                do {
                    _ = try customization.createLayerGroup(id: groupID, name: name, children: children)
                } catch {
                    throw ThumbleConfigurationBridgeError.invalidGroup
                }
                setCustomization(customization, in: &profile, variant: variant)
            }
        case let .groupRename(profileID, variant, groupID, name):
            let groupID = try groupUUID(groupID)
            return try mutateProfile(profileID, in: &document, nowMillis: nowMillis) { profile in
                var customization = customization(in: profile, variant: variant)
                do {
                    _ = try customization.renameLayerGroup(id: groupID, to: name)
                } catch {
                    throw ThumbleConfigurationBridgeError.invalidGroup
                }
                setCustomization(customization, in: &profile, variant: variant)
            }
        case let .groupDuplicate(profileID, variant, groupID, newGroupID, name, newElementIDs, offsetX, offsetY):
            let groupID = try groupUUID(groupID)
            let newGroupID = try groupUUID(newGroupID)
            try validateFinite(offsetX, range: -1 ... 1)
            try validateFinite(offsetY, range: -1 ... 1)
            let newIDs = try newElementIDs.map { value -> UUID in
                guard let id = UUID(uuidString: value) else {
                    throw ThumbleConfigurationBridgeError.invalidElementID
                }
                return id
            }
            guard !newIDs.isEmpty, newIDs.count <= 128, Set(newIDs).count == newIDs.count else {
                throw ThumbleConfigurationBridgeError.invalidElementID
            }
            return try mutateProfile(profileID, in: &document, nowMillis: nowMillis) { profile in
                var customization = customization(in: profile, variant: variant)
                do {
                    _ = try customization.duplicateLayerGroup(
                        id: groupID,
                        name: name,
                        normalizedOffset: CGSize(width: offsetX, height: offsetY),
                        canvasSize: customization.deviceCanvas.editorDeviceFrame.screenRect.size,
                        newGroupID: newGroupID,
                        newElementIDs: newIDs
                    )
                } catch {
                    throw ThumbleConfigurationBridgeError.invalidGroup
                }
                setCustomization(customization, in: &profile, variant: variant)
            }
        case let .groupUngroup(profileID, variant, groupID):
            let groupID = try groupUUID(groupID)
            return try mutateProfile(profileID, in: &document, nowMillis: nowMillis) { profile in
                var customization = customization(in: profile, variant: variant)
                do {
                    _ = try customization.removeLayerGroup(id: groupID)
                } catch {
                    throw ThumbleConfigurationBridgeError.invalidGroup
                }
                setCustomization(customization, in: &profile, variant: variant)
            }
        case let .groupHide(profileID, variant, groupID):
            return try mutateGroupState(profileID, variant: variant, groupID: groupID, in: &document, nowMillis: nowMillis) {
                _ = try $0.setLayerGroupHidden(id: $1, isHidden: true)
            }
        case let .groupShow(profileID, variant, groupID):
            return try mutateGroupState(profileID, variant: variant, groupID: groupID, in: &document, nowMillis: nowMillis) {
                _ = try $0.setLayerGroupHidden(id: $1, isHidden: false)
            }
        case let .groupLock(profileID, variant, groupID):
            return try mutateGroupState(profileID, variant: variant, groupID: groupID, in: &document, nowMillis: nowMillis) {
                _ = try $0.setLayerGroupLocked(id: $1, isLocked: true)
            }
        case let .groupUnlock(profileID, variant, groupID):
            return try mutateGroupState(profileID, variant: variant, groupID: groupID, in: &document, nowMillis: nowMillis) {
                _ = try $0.setLayerGroupLocked(id: $1, isLocked: false)
            }
        case let .groupNudge(profileID, variant, groupID, canvasFrameID, deltaX, deltaY):
            try validateFinite(deltaX, range: -1_000 ... 1_000)
            try validateFinite(deltaY, range: -1_000 ... 1_000)
            guard deltaX != 0 || deltaY != 0 else { throw ThumbleConfigurationBridgeError.invalidGeometry }
            guard let canvasFrame = GamepadEditorDeviceCatalog.frames.first(where: { $0.id == canvasFrameID }) else {
                throw ThumbleConfigurationBridgeError.invalidDeviceFrame
            }
            return try mutateGroupState(profileID, variant: variant, groupID: groupID, in: &document, nowMillis: nowMillis) { customization, groupID in
                let group = try requiredGroup(groupID, in: customization)
                if let nudged = customization.nudgedControls(
                    Set(group.children),
                    by: CGSize(width: deltaX, height: deltaY),
                    in: canvasFrame.screenRect.size
                ) {
                    customization = nudged
                }
            }
        case let .groupForward(profileID, variant, groupID):
            return try mutateGroupLayers(profileID, variant: variant, groupID: groupID, in: &document, nowMillis: nowMillis) {
                $0.bringLayersForward($1)
            }
        case let .groupBackward(profileID, variant, groupID):
            return try mutateGroupLayers(profileID, variant: variant, groupID: groupID, in: &document, nowMillis: nowMillis) {
                $0.sendLayersBackward($1)
            }
        case let .groupFront(profileID, variant, groupID):
            return try mutateGroupLayers(profileID, variant: variant, groupID: groupID, in: &document, nowMillis: nowMillis) {
                $0.bringLayersToFront($1)
            }
        case let .groupBack(profileID, variant, groupID):
            return try mutateGroupLayers(profileID, variant: variant, groupID: groupID, in: &document, nowMillis: nowMillis) {
                $0.sendLayersToBack($1)
            }
        case let .controlBarReset(profileID, variant):
            return try mutateProfile(profileID, in: &document, nowMillis: nowMillis) { profile in
                var customization = customization(in: profile, variant: variant)
                customization.resetControlBar()
                setCustomization(customization, in: &profile, variant: variant)
            }
        case let .controlBarItemReset(profileID, variant, item):
            return try mutateProfile(profileID, in: &document, nowMillis: nowMillis) { profile in
                var customization = customization(in: profile, variant: variant)
                customization.resetControlBarItemAppearance(item)
                setCustomization(customization, in: &profile, variant: variant)
            }
        case let .controlBarItemSet(profileID, variant, item, changes):
            try validateControlBarItemChanges(changes, item: item)
            return try mutateProfile(profileID, in: &document, nowMillis: nowMillis) { profile in
                var customization = customization(in: profile, variant: variant)
                var patch = GamepadControlBarAppearancePatch(
                    existing: customization.controlBarItemCustomization(for: item)
                )
                try applyControlBarItemChanges(changes, to: &patch.appearance, in: customization)
                do {
                    try customization.applyControlBarAppearancePatch(patch, for: item)
                } catch {
                    throw ThumbleConfigurationBridgeError.invalidControlBar
                }
                setCustomization(customization, in: &profile, variant: variant)
            }
        case let .generationGenerate(preset, presetRevision, destination, newElementIDs, select, makeDefault):
            guard presetRevision == preset.revision else {
                throw ThumbleConfigurationBridgeError.revisionMismatch
            }
            guard let generated = GameKeypadGenerator.generate(for: preset.rawValue) else {
                throw ThumbleConfigurationBridgeError.unknownGenerationPreset
            }
            var profile = generated.profile
            profile.updatedAt = nowMillis
            profile.customization.updatedAt = nowMillis
            try assignCustomElementIDs(
                newElementIDs,
                expectedCount: preset.customElementIDCount,
                to: &profile,
                in: document
            )
            #if os(macOS)
            var bindings = DefaultKeypadKeyMap.defaultBindings
            for (button, specification) in generated.keyBindings {
                guard let binding = MacKeyBinding(generatedSpec: specification) else {
                    throw ThumbleConfigurationBridgeError.invalidGeneratedBinding
                }
                bindings[button] = binding
            }
            let outputs = MacConfigurationBindings.keyboardOutputs(from: bindings)
            MacConfigurationBindings.synchronizeElementOutputs(in: &profile, outputs: outputs)
            return try installGeneratedProfile(
                profile,
                keyBindings: bindings,
                outputBindings: outputs,
                destination: destination,
                select: select,
                makeDefault: makeDefault,
                in: &document
            )
            #else
            throw ThumbleConfigurationBridgeError.unsupportedOperation
            #endif
        case let .templateInstall(templateInput, templateRevision, destination, name, newElementIDs, select, makeDefault):
            guard templateRevision == templateInput.revision else {
                throw ThumbleConfigurationBridgeError.revisionMismatch
            }
            let template = templateInput.template
            var profile = template.makeProfile()
            profile.name = try profileName(name ?? template.displayName)
            profile.updatedAt = nowMillis
            try assignCustomElementIDs(
                newElementIDs,
                expectedCount: templateInput.customElementIDCount,
                to: &profile,
                in: document
            )
            #if os(macOS)
            guard let outputs = template.recommendedMacOutputBindings else {
                throw ThumbleConfigurationBridgeError.invalidGeneratedBinding
            }
            let bindings = outputs.keyboardBindings
            MacConfigurationBindings.synchronizeElementOutputs(in: &profile, outputs: outputs)
            return try installGeneratedProfile(
                profile,
                keyBindings: bindings,
                outputBindings: outputs,
                destination: destination,
                select: select,
                makeDefault: makeDefault,
                in: &document
            )
            #else
            throw ThumbleConfigurationBridgeError.unsupportedOperation
            #endif
        case .profileSelect(let profileID):
            let canonical = try existingProfileID(profileID, in: document)
            document.activeProfileID = canonical
            try synchronizeActiveBindings(in: &document)
            return ["/activeProfileID", "/keyBindings", "/outputBindings", "/profileKeyBindings", "/profileOutputBindings"]
        case .profileSetDefault(let profileID):
            let canonical = try existingProfileID(profileID, in: document)
            document.defaultProfileID = canonical
            return ["/defaultProfileID"]
        case let .profileDuplicate(profileID, newProfileID, name):
            let sourceIndex = try profileIndex(profileID, in: document)
            let sourceID = try document.profiles[sourceIndex].requiredString(forKey: "id")
            let newID = try canonicalNewProfileID(newProfileID, in: document)
            let normalizedName = try profileName(name)
            var duplicate = document.profiles[sourceIndex]
            try duplicate.setObjectValue(.string(newID), forKey: "id")
            try duplicate.setObjectValue(.string(normalizedName), forKey: "name")
            try duplicate.setObjectValue(.integer(nowMillis), forKey: "updatedAt")
            document.profiles.append(duplicate)
            try cloneOrInstallBindingMaps(from: sourceID, to: newID, in: &document)
            document.activeProfileID = newID
            try synchronizeActiveBindings(in: &document)
            return ["/profiles", "/activeProfileID", "/keyBindings", "/outputBindings", "/profileKeyBindings", "/profileOutputBindings"]
        case let .profileDelete(profileID, replacementProfileID):
            let index = try profileIndex(profileID, in: document)
            let removedID = try document.profiles[index].requiredString(forKey: "id")
            if document.profiles.count == 1 {
                guard let replacementProfileID else { throw ThumbleConfigurationBridgeError.replacementProfileRequired }
                let replacementID = try canonicalNewProfileID(replacementProfileID, in: document, ignoring: removedID)
                let replacement = GamepadConfigurationProfile(
                    id: UUID(uuidString: replacementID)!,
                    name: "Setup 1",
                    primaryCustomization: .blankCanvas,
                    updatedAt: nowMillis
                )
                var encodedReplacement = try encodedJSONValue(replacement)
                // Foundation's UUID encoder emits uppercase text. Keep every
                // identity mirror on the exact caller-provided canonical spelling
                // so binding maps cannot gain case-variant duplicate keys.
                try encodedReplacement.setObjectValue(.string(replacementID), forKey: "id")
                document.profiles = [encodedReplacement]
                document.activeProfileID = replacementID
                document.defaultProfileID = replacementID
                document.profileKeyBindings[replacementID] = try defaultKeyBindings()
                document.profileOutputBindings[replacementID] = try defaultOutputBindings()
            } else {
                document.profiles.remove(at: index)
                let fallback = try document.profiles[min(index, document.profiles.count - 1)].requiredString(forKey: "id")
                if idsEqual(document.activeProfileID, removedID) { document.activeProfileID = fallback }
                if idsEqual(document.defaultProfileID, removedID) { document.defaultProfileID = document.activeProfileID }
            }
            removeBindingMap(for: removedID, from: &document.profileKeyBindings)
            removeBindingMap(for: removedID, from: &document.profileOutputBindings)
            try synchronizeActiveBindings(in: &document)
            return ["/profiles", "/activeProfileID", "/defaultProfileID", "/keyBindings", "/outputBindings", "/profileKeyBindings", "/profileOutputBindings"]
        case let .profileMove(profileID, index):
            let source = try profileIndex(profileID, in: document)
            guard index >= 0, index < document.profiles.count else { throw ThumbleConfigurationBridgeError.invalidProfileIndex }
            let profile = document.profiles.remove(at: source)
            document.profiles.insert(profile, at: index)
            return ["/profiles"]
        case let .profileCreate(name, newProfileID, sourceProfileID, select, makeDefault):
            let newID = try canonicalNewProfileID(newProfileID, in: document)
            let normalizedName = try profileName(name)
            let profile: GamepadConfigurationProfile
            if let sourceProfileID {
                let sourceIndex = try profileIndex(sourceProfileID, in: document)
                let source: GamepadConfigurationProfile = try decoded(document.profiles[sourceIndex])
                profile = GamepadConfigurationProfile(
                    id: UUID(uuidString: newID)!,
                    name: normalizedName,
                    customization: source.customization,
                    landscapeCustomization: source.landscapeCustomization,
                    portraitCustomization: source.portraitCustomization,
                    orientationPreference: source.orientationPreference,
                    outputMode: source.outputMode,
                    updatedAt: nowMillis
                )
                try cloneOrInstallBindingMaps(from: source.id.uuidString, to: newID, in: &document)
            } else {
                profile = GamepadConfigurationProfile(
                    id: UUID(uuidString: newID)!,
                    name: normalizedName,
                    primaryCustomization: .blankCanvas,
                    updatedAt: nowMillis
                )
                document.profileKeyBindings[newID] = try defaultKeyBindings()
                document.profileOutputBindings[newID] = try defaultOutputBindings()
            }
            document.profiles.append(try encodedJSONValue(profile))
            if select { document.activeProfileID = newID }
            if makeDefault { document.defaultProfileID = newID }
            if select { try synchronizeActiveBindings(in: &document) }
            return ["/profiles", "/activeProfileID", "/defaultProfileID", "/keyBindings", "/outputBindings", "/profileKeyBindings", "/profileOutputBindings"]
        case let .themeApply(profileID, variant, preset):
            guard let theme = GamepadThemePreset.resolve(preset) else { throw ThumbleConfigurationBridgeError.unknownTheme }
            return try mutateProfile(profileID, in: &document, nowMillis: nowMillis) { profile in
                var customization = customization(in: profile, variant: variant)
                theme.apply(to: &customization)
                customization.updatedAt = nowMillis
                setCustomization(customization.normalized, in: &profile, variant: variant)
            }
        case let .orientationCopy(profileID, source, destination, automaticallyArrange):
            return try copyOrientation(
                profileID: profileID,
                source: source,
                destination: destination,
                automaticallyArrange: automaticallyArrange,
                in: &document,
                nowMillis: nowMillis
            )
        case let .elementAdd(profileID, variant, elementID, kind, mappedButton, changes):
            guard let id = UUID(uuidString: elementID), elementID.utf8.count <= 128 else {
                throw ThumbleConfigurationBridgeError.invalidElementID
            }
            return try mutateProfile(profileID, in: &document, nowMillis: nowMillis) { profile in
                try ensureElementIDIsAvailable(id, in: profile)
                var customization = customization(in: profile, variant: variant)
                let control = try makeStandaloneElement(
                    id: id,
                    kind: kind,
                    mappedButton: mappedButton,
                    changes: changes,
                    in: customization
                )
                do {
                    try customization.addStandaloneCustomControl(control)
                    try applyElementOutput(changes.output, to: .custom(id), in: &customization)
                } catch {
                    throw ThumbleConfigurationBridgeError.invalidElementChanges
                }
                setCustomization(customization, in: &profile, variant: variant)
            }
        case let .elementSet(profileID, variant, elementID, changes):
            try validateElementIDs([elementID], minimum: 1)
            return try mutateProfile(profileID, in: &document, nowMillis: nowMillis) { profile in
                var customization = customization(in: profile, variant: variant)
                let identity = try controlIdentity(elementID, in: customization)
                try applyStandaloneElementChanges(changes, to: identity, in: &customization)
                setCustomization(customization, in: &profile, variant: variant)
            }
        case let .elementDuplicate(profileID, variant, elementIDs, newElementIDs, offsetX, offsetY):
            try validateElementIDs(elementIDs, minimum: 1)
            guard newElementIDs.count == elementIDs.count else { throw ThumbleConfigurationBridgeError.invalidElementID }
            let newIDs = try newElementIDs.map { value -> UUID in
                guard let id = UUID(uuidString: value) else { throw ThumbleConfigurationBridgeError.invalidElementID }
                return id
            }
            guard Set(newIDs).count == newIDs.count else { throw ThumbleConfigurationBridgeError.invalidElementID }
            try validateFinite(offsetX, range: -1 ... 1)
            try validateFinite(offsetY, range: -1 ... 1)
            return try mutateProfile(profileID, in: &document, nowMillis: nowMillis) { profile in
                var customization = customization(in: profile, variant: variant)
                let identities = try elementIDs.map { try controlIdentity($0, in: customization) }
                _ = try customization.duplicateControls(
                    identities,
                    normalizedOffset: CGSize(width: offsetX, height: offsetY),
                    canvasSize: customization.deviceCanvas.editorDeviceFrame.screenRect.size,
                    newElementIDs: newIDs
                )
                setCustomization(customization, in: &profile, variant: variant)
            }
        case let .elementAlign(profileID, variant, elementIDs, alignment):
            try validateElementIDs(elementIDs, minimum: 2)
            guard let alignment = GamepadControlAlignment(rawValue: alignment) else {
                throw ThumbleConfigurationBridgeError.invalidAlignment
            }
            return try mutateProfile(profileID, in: &document, nowMillis: nowMillis) { profile in
                var customization = customization(in: profile, variant: variant)
                let identities = try Set(elementIDs.map { try controlIdentity($0, in: customization) })
                _ = try customization.alignControls(
                    identities,
                    alignment: alignment,
                    in: customization.deviceCanvas.editorDeviceFrame.screenRect.size
                )
                setCustomization(customization, in: &profile, variant: variant)
            }
        case let .elementDistribute(profileID, variant, elementIDs, distribution):
            try validateElementIDs(elementIDs, minimum: 3)
            guard let distribution = GamepadControlDistribution(rawValue: distribution) else {
                throw ThumbleConfigurationBridgeError.invalidDistribution
            }
            return try mutateProfile(profileID, in: &document, nowMillis: nowMillis) { profile in
                var customization = customization(in: profile, variant: variant)
                let identities = try Set(elementIDs.map { try controlIdentity($0, in: customization) })
                _ = try customization.distributeControls(
                    identities,
                    distribution: distribution,
                    in: customization.deviceCanvas.editorDeviceFrame.screenRect.size
                )
                setCustomization(customization, in: &profile, variant: variant)
            }
        case let .elementNudge(profileID, variant, elementIDs, deltaX, deltaY):
            try validateElementIDs(elementIDs, minimum: 1)
            try validateFinite(deltaX, range: -1_000 ... 1_000)
            try validateFinite(deltaY, range: -1_000 ... 1_000)
            return try mutateProfile(profileID, in: &document, nowMillis: nowMillis) { profile in
                var customization = customization(in: profile, variant: variant)
                let identities = try Set(elementIDs.map { try controlIdentity($0, in: customization) })
                guard deltaX != 0 || deltaY != 0 else { return }
                if let nudged = customization.nudgedControls(
                    identities,
                    by: CGSize(width: deltaX, height: deltaY),
                    in: customization.deviceCanvas.editorDeviceFrame.screenRect.size
                ) {
                    customization = nudged
                }
                setCustomization(customization, in: &profile, variant: variant)
            }
        case let .elementDelete(profileID, variant, elementID):
            try validateElementIDs([elementID], minimum: 1)
            return try mutateProfile(profileID, in: &document, nowMillis: nowMillis) { profile in
                var customization = customization(in: profile, variant: variant)
                switch try controlIdentity(elementID, in: customization) {
                case .builtin(let button):
                    var layout = customization.buttonCustomization(for: button)
                    layout.isHidden = true
                    customization.setButtonCustomization(layout, for: button)
                case .custom(let id):
                    customization.removeCustomButton(id: id)
                case .system(.topBarActivation):
                    customization.topBarActivationRegion.isHidden = true
                case .controlBarItem:
                    throw ThumbleConfigurationBridgeError.invalidElementID
                }
                setCustomization(customization, in: &profile, variant: variant)
            }
        case let .elementReset(profileID, variant, elementID):
            try validateElementIDs([elementID], minimum: 1)
            return try mutateProfile(profileID, in: &document, nowMillis: nowMillis) { profile in
                var customization = customization(in: profile, variant: variant)
                do {
                    try customization.resetControl(controlIdentity(elementID, in: customization))
                } catch {
                    throw ThumbleConfigurationBridgeError.invalidElementID
                }
                setCustomization(customization, in: &profile, variant: variant)
            }
        }
    }

    private static func assignCustomElementIDs(
        _ values: [String],
        expectedCount: Int,
        to profile: inout GamepadConfigurationProfile,
        in document: ThumbleBridgeConfigurationDocument
    ) throws {
        guard values.count == expectedCount else {
            throw ThumbleConfigurationBridgeError.invalidGeneratedElementIDs
        }
        let ids = try values.map { value -> UUID in
            guard value.utf8.count <= 128, let id = UUID(uuidString: value) else {
                throw ThumbleConfigurationBridgeError.invalidGeneratedElementIDs
            }
            return id
        }
        guard Set(ids).count == ids.count else {
            throw ThumbleConfigurationBridgeError.invalidGeneratedElementIDs
        }
        let profileIDs = try Set(document.profiles.map {
            try $0.requiredString(forKey: "id").lowercased()
        })
        guard ids.allSatisfy({ !profileIDs.contains($0.uuidString.lowercased()) }) else {
            throw ThumbleConfigurationBridgeError.invalidGeneratedElementIDs
        }

        var replacements: [UUID: UUID] = [:]
        var nextIndex = 0
        func remap(_ source: GamepadCustomization) throws -> GamepadCustomization {
            var customization = source
            for index in customization.customButtons.indices {
                let oldID = customization.customButtons[index].id
                let replacement: UUID
                if let existing = replacements[oldID] {
                    replacement = existing
                } else {
                    guard nextIndex < ids.count else {
                        throw ThumbleConfigurationBridgeError.invalidGeneratedElementIDs
                    }
                    replacement = ids[nextIndex]
                    nextIndex += 1
                    replacements[oldID] = replacement
                }
                customization.customButtons[index].id = replacement
            }
            for index in customization.elements.indices {
                if let replacement = replacements[customization.elements[index].id] {
                    customization.elements[index].id = replacement
                }
            }
            if var metadata = customization.designMetadata {
                metadata.layerOrder = metadata.layerOrder.map { identity in
                    guard case .custom(let id) = identity,
                          let replacement = replacements[id]
                    else { return identity }
                    return .custom(replacement)
                }
                metadata.groups = metadata.groups.map { group in
                    var copy = group
                    copy.children = group.children.map { identity in
                        guard case .custom(let id) = identity,
                              let replacement = replacements[id]
                        else { return identity }
                        return .custom(replacement)
                    }
                    return copy
                }
                customization.designMetadata = metadata
            }
            return customization.normalized
        }

        profile.customization = try remap(profile.customization)
        if let landscape = profile.landscapeCustomization {
            profile.landscapeCustomization = try remap(landscape)
        }
        if let portrait = profile.portraitCustomization {
            profile.portraitCustomization = try remap(portrait)
        }
        guard nextIndex == ids.count else {
            throw ThumbleConfigurationBridgeError.invalidGeneratedElementIDs
        }
    }

    #if os(macOS)
    private static func installGeneratedProfile(
        _ inputProfile: GamepadConfigurationProfile,
        keyBindings: [GameButton: MacKeyBinding],
        outputBindings: [GameButton: MacControlOutputBinding],
        destination: ThumbleBridgeProfileDestination,
        select: Bool,
        makeDefault: Bool,
        in document: inout ThumbleBridgeConfigurationDocument
    ) throws -> [String] {
        var profile = inputProfile.normalized
        let finalName = try profileName(profile.name)
        let finalID: String
        let replacementIndex: Int?
        switch destination {
        case .create(let newProfileID):
            finalID = try canonicalNewProfileID(newProfileID, in: document)
            guard try !document.profiles.contains(where: {
                try profileName($0.requiredString(forKey: "name"))
                    .caseInsensitiveCompare(finalName) == .orderedSame
            }) else { throw ThumbleConfigurationBridgeError.staleDestination }
            replacementIndex = nil
        case .replace(let profileID):
            let index = try profileIndex(profileID, in: document)
            finalID = try document.profiles[index].requiredString(forKey: "id").lowercased()
            guard let firstNameMatch = try document.profiles.firstIndex(where: {
                try profileName($0.requiredString(forKey: "name"))
                    .caseInsensitiveCompare(finalName) == .orderedSame
            }), firstNameMatch == index else {
                throw ThumbleConfigurationBridgeError.staleDestination
            }
            replacementIndex = index
        }
        let customElementIDs = [
            Optional(profile.customization),
            profile.landscapeCustomization,
            profile.portraitCustomization
        ].compactMap { $0 }.flatMap { $0.customButtons.map(\.id) }
        guard customElementIDs.allSatisfy({
            $0.uuidString.caseInsensitiveCompare(finalID) != .orderedSame
        }) else { throw ThumbleConfigurationBridgeError.invalidGeneratedElementIDs }
        profile.id = UUID(uuidString: finalID)!
        profile.name = finalName
        let afterCanonical = try encodedJSONValue(profile.normalized)
        if let replacementIndex {
            let raw = document.profiles[replacementIndex]
            let before: GamepadConfigurationProfile = try decoded(raw)
            document.profiles[replacementIndex] = applyCanonicalChanges(
                raw: raw,
                before: try encodedJSONValue(before),
                after: afterCanonical
            )
        } else {
            document.profiles.append(afterCanonical)
        }

        let keys = try encodedJSONValue(MacConfigurationBindings.rawKeyBindings(keyBindings))
        let outputs = try encodedJSONValue(MacConfigurationBindings.rawOutputs(outputBindings))
        removeBindingMap(for: finalID, from: &document.profileKeyBindings)
        removeBindingMap(for: finalID, from: &document.profileOutputBindings)
        document.profileKeyBindings[finalID] = keys
        document.profileOutputBindings[finalID] = outputs
        if select { document.activeProfileID = finalID }
        if makeDefault { document.defaultProfileID = finalID }
        if idsEqual(document.activeProfileID, finalID) {
            document.keyBindings = keys
            document.outputBindings = outputs
        }
        return [
            "/profiles", "/activeProfileID", "/defaultProfileID", "/keyBindings",
            "/outputBindings", "/profileKeyBindings", "/profileOutputBindings"
        ]
    }

    private static func applyBindingChange(
        profileID: String,
        document: inout ThumbleBridgeConfigurationDocument,
        nowMillis: Int64,
        change: (inout [GameButton: MacKeyBinding], GamepadConfigurationProfile) throws -> Void
    ) throws -> [String] {
        try mutateMacConfiguration(
            profileID: profileID,
            document: &document,
            nowMillis: nowMillis
        ) { profile, bindings, outputs in
            try change(&bindings, profile)
            switch profile.outputMode {
            case .keyboard:
                outputs = MacConfigurationBindings.keyboardOutputs(from: bindings)
            case .controller:
                outputs = MacConfigurationBindings.effectiveOutputs(
                    for: .controller,
                    keyBindings: bindings,
                    customOutputs: outputs
                )
            case .custom:
                for (button, binding) in bindings {
                    var output = outputs[button] ?? MacControlOutputBinding()
                    output.keyboard = binding
                    outputs[button] = output
                }
            }
        }
    }

    private static func applyOutputMode(
        profileID: String,
        mode: GamepadProfileOutputMode,
        document: inout ThumbleBridgeConfigurationDocument,
        nowMillis: Int64
    ) throws -> [String] {
        try mutateMacConfiguration(
            profileID: profileID,
            document: &document,
            nowMillis: nowMillis
        ) { profile, bindings, outputs in
            profile.outputMode = mode
            outputs = MacConfigurationBindings.effectiveOutputs(
                for: mode,
                keyBindings: bindings,
                customOutputs: outputs
            )
        }
    }

    private static func applyOutputSet(
        profileID: String,
        button: GameButton,
        keyboardEdit: ThumbleBridgeKeyboardOutputEdit,
        gamepadEdit: ThumbleBridgeGamepadOutputEdit,
        document: inout ThumbleBridgeConfigurationDocument,
        nowMillis: Int64
    ) throws -> [String] {
        if case .keep = keyboardEdit, case .keep = gamepadEdit {
            throw ThumbleConfigurationBridgeError.invalidOutputEdit
        }
        return try mutateMacConfiguration(
            profileID: profileID,
            document: &document,
            nowMillis: nowMillis
        ) { profile, bindings, outputs in
            let original = outputs[button]
            var output = original ?? MacControlOutputBinding()
            switch keyboardEdit {
            case .keep:
                break
            case .clear:
                output.keyboard = nil
            case .set(let sequence):
                output.keyboard = try semanticKeyBinding(sequence)
            }
            switch gamepadEdit {
            case .keep:
                break
            case .clear:
                output.gamepadButtons.removeAll()
            case .set(let gamepadButton):
                output.setGamepadButton(gamepadButton)
            }
            if case .keep = keyboardEdit,
               output.keyboard == nil,
               !output.gamepadButtons.isEmpty,
               let keyboard = bindings[button] {
                output.keyboard = keyboard
            }
            outputs[button] = output.isEmpty ? nil : output
            profile.outputMode = .custom
            if outputs[button] != original {
                bindings[button] = outputs[button]?.keyboard
            }
        }
    }

    private static func semanticKeyBinding(
        _ sequence: [ThumbleBridgeSemanticKeyStroke]
    ) throws -> MacKeyBinding {
        guard !sequence.isEmpty, sequence.count <= 32 else {
            throw ThumbleConfigurationBridgeError.invalidOutputEdit
        }
        let strokes = try sequence.map { stroke -> MacKeyStroke in
            guard !stroke.key.isEmpty, stroke.key.utf8.count <= 32,
                  let keyCode = MacVirtualKey.keyCode(named: stroke.key),
                  stroke.modifiers.count <= 4,
                  Set(stroke.modifiers).count == stroke.modifiers.count,
                  stroke.modifiers.allSatisfy({
                      ["command", "shift", "option", "control"].contains($0)
                  }),
                  let modifiers = MacKeyModifiers(generatedModifierNames: stroke.modifiers)
            else { throw ThumbleConfigurationBridgeError.invalidOutputEdit }
            return MacKeyStroke(keyCode: keyCode, modifiers: modifiers)
        }
        return MacKeyBinding(strokes: strokes)
    }

    private static func applyOutputReset(
        profileID: String,
        button: GameButton,
        document: inout ThumbleBridgeConfigurationDocument,
        nowMillis: Int64
    ) throws -> [String] {
        try mutateMacConfiguration(
            profileID: profileID,
            document: &document,
            nowMillis: nowMillis
        ) { profile, bindings, outputs in
            let original = outputs[button]
            outputs[button] = profile.recommendedMacOutputBindings[button]
            profile.outputMode = .custom
            if outputs[button] != original {
                bindings[button] = outputs[button]?.keyboard
            }
        }
    }

    private static func applyOutputResetAll(
        profileID: String,
        document: inout ThumbleBridgeConfigurationDocument,
        nowMillis: Int64
    ) throws -> [String] {
        try mutateMacConfiguration(
            profileID: profileID,
            document: &document,
            nowMillis: nowMillis
        ) { profile, bindings, outputs in
            outputs = profile.recommendedMacOutputBindings
            bindings = outputs.keyboardBindings
            profile.outputMode = .keyboard
        }
    }

    private static func mutateMacConfiguration(
        profileID: String,
        document: inout ThumbleBridgeConfigurationDocument,
        nowMillis: Int64,
        mutate: (
            inout GamepadConfigurationProfile,
            inout [GameButton: MacKeyBinding],
            inout [GameButton: MacControlOutputBinding]
        ) throws -> Void
    ) throws -> [String] {
        let profileIndex = try profileIndex(profileID, in: document)
        let rawProfile = document.profiles[profileIndex]
        let canonicalID = try rawProfile.requiredString(forKey: "id")
        var profile: GamepadConfigurationProfile = try decoded(rawProfile)
        let beforeProfileCanonical = try encodedJSONValue(profile)

        let rawKeyValue = bindingValue(for: canonicalID, in: document.profileKeyBindings)
        let rawOutputValue = bindingValue(for: canonicalID, in: document.profileOutputBindings)
        let rawKeys: [String: MacKeyBinding]
        if let rawKeyValue {
            rawKeys = try decoded(rawKeyValue)
        } else {
            rawKeys = MacConfigurationBindings.rawKeyBindings(DefaultKeypadKeyMap.defaultBindings)
        }
        var bindings = MacConfigurationBindings.decodedKeyBindings(rawKeys)
            ?? DefaultKeypadKeyMap.defaultBindings
        let rawOutputs: [String: MacControlOutputBinding]
        if let rawOutputValue {
            rawOutputs = try decoded(rawOutputValue)
        } else {
            rawOutputs = MacConfigurationBindings.rawOutputs(
                MacConfigurationBindings.keyboardOutputs(from: bindings)
            )
        }
        var outputs = MacConfigurationBindings.decodedOutputs(rawOutputs)
            ?? MacConfigurationBindings.keyboardOutputs(from: bindings)
        // Compare only the typed, recognized semantic projection so keyed
        // forward-compatible entries and nested unknown fields remain in the
        // raw maps when canonical mutations are overlaid.
        let beforeKeysCanonical = try encodedJSONValue(
            MacConfigurationBindings.rawKeyBindings(bindings)
        )
        let beforeOutputsCanonical = try encodedJSONValue(
            MacConfigurationBindings.rawOutputs(outputs)
        )

        try mutate(&profile, &bindings, &outputs)
        MacConfigurationBindings.synchronizeElementOutputs(in: &profile, outputs: outputs)
        let afterKeysCanonical = try encodedJSONValue(
            MacConfigurationBindings.rawKeyBindings(bindings)
        )
        let afterOutputsCanonical = try encodedJSONValue(
            MacConfigurationBindings.rawOutputs(outputs)
        )
        let mutatedProfileCanonical = try encodedJSONValue(profile.normalized)
        guard mutatedProfileCanonical != beforeProfileCanonical
                || afterKeysCanonical != beforeKeysCanonical
                || afterOutputsCanonical != beforeOutputsCanonical
        else { return [] }

        profile.updatedAt = nowMillis
        let afterProfileCanonical = try encodedJSONValue(profile.normalized)
        document.profiles[profileIndex] = applyCanonicalChanges(
            raw: rawProfile,
            before: beforeProfileCanonical,
            after: afterProfileCanonical
        )
        let nextKeys = applyCanonicalChanges(
            raw: rawKeyValue ?? beforeKeysCanonical,
            before: beforeKeysCanonical,
            after: afterKeysCanonical
        )
        let nextOutputs = applyCanonicalChanges(
            raw: rawOutputValue ?? beforeOutputsCanonical,
            before: beforeOutputsCanonical,
            after: afterOutputsCanonical
        )
        removeBindingMap(for: canonicalID, from: &document.profileKeyBindings)
        removeBindingMap(for: canonicalID, from: &document.profileOutputBindings)
        document.profileKeyBindings[canonicalID] = nextKeys
        document.profileOutputBindings[canonicalID] = nextOutputs

        var changedPaths = [
            "/profiles/\(escapePointer(canonicalID))",
            "/profileKeyBindings",
            "/profileOutputBindings"
        ]
        if idsEqual(document.activeProfileID, canonicalID) {
            document.keyBindings = nextKeys
            document.outputBindings = nextOutputs
            changedPaths.append(contentsOf: ["/keyBindings", "/outputBindings"])
        }
        return changedPaths
    }
    #endif

    private static func ensureElementIDIsAvailable(
        _ id: UUID,
        in profile: GamepadConfigurationProfile
    ) throws {
        let customizations = [
            Optional(profile.customization),
            profile.landscapeCustomization,
            profile.portraitCustomization
        ].compactMap { $0 }
        guard customizations.allSatisfy({ customization in
            !customization.customButtons.contains(where: { $0.id == id })
                && !customization.elements.contains(where: { $0.id == id })
        }) else { throw ThumbleConfigurationBridgeError.invalidElementID }
    }

    private static func makeStandaloneElement(
        id: UUID,
        kind: GamepadCustomControlKind,
        mappedButton: GameButton?,
        changes: ThumbleBridgeElementChanges,
        in customization: GamepadCustomization
    ) throws -> GamepadCustomButton {
        try validateElementChanges(changes, permitsKind: false)
        let passive = kind == .text || kind == .decoration
        let mapped = mappedButton
            ?? (kind == .joystick ? .up : (passive ? .custom8 : firstAvailableCustomSlot(in: customization) ?? .custom1))
        let triggerCount = customization.customButtons.filter { $0.normalized.isTrigger }.count
        let triggerTarget: VirtualGamepadTrigger = triggerCount == 0 ? .left : .right
        let label = changes.label ?? (kind == .trigger ? triggerTarget.shortName : kind.defaultElementLabel)
        var control = GamepadCustomButton(
            id: id,
            mappedButton: mapped,
            label: label,
            controlKind: kind,
            joystickMapping: kind == .joystick ? .movement : nil,
            joystickOutputSettings: kind == .joystick ? .defaultValue : nil,
            triggerSettings: kind == .trigger
                ? GamepadTriggerSettings(target: triggerTarget, orientation: .horizontal)
                : nil,
            trackpadSettings: kind == .trackpad ? .defaultValue : nil
        )
        switch kind {
        case .button:
            control.layout.showsIntegratedLabel = false
        case .joystick:
            control.layout.shape = .circle
            control.layout.widthScale = changes.joystickVisualStyle == .thumbstick ? 0.58 : 1.35
            control.layout.heightScale = control.layout.widthScale
        case .trigger:
            control.layout.shape = .capsule
            control.layout.widthScale = 1.08
            control.layout.heightScale = 0.42
            control.layout.centerX = triggerTarget == .left ? 0.20 : 0.80
            control.layout.centerY = 0.14
        case .trackpad:
            control.layout.shape = .roundedRectangle
            control.layout.widthScale = 1.25
            control.layout.heightScale = 1
            control.layout.centerY = 0.58
            control.layout.cornerRadius = 18
        case .text:
            control.layout.shape = .rectangle
            control.layout.widthScale = 1.4
            control.layout.heightScale = 0.7
            control.layout.shadowStrength = 0
            control.layout.showsIntegratedLabel = false
        case .decoration:
            control.layout.shape = .roundedRectangle
            control.layout.widthScale = 2.2
            control.layout.heightScale = 1.2
            control.layout.cornerRadius = 28
            control.layout.shadowStrength = 0
            control.layout.visualStyle = .softWhitePlate()
        }
        try applyChanges(changes, to: &control, in: customization, permitsKind: false)
        return control.normalized
    }

    private static func applyStandaloneElementChanges(
        _ changes: ThumbleBridgeElementChanges,
        to identity: GamepadControlIdentity,
        in customization: inout GamepadCustomization
    ) throws {
        try validateElementChanges(changes, permitsKind: true)
        switch identity {
        case .builtin(let button):
            guard changes.kind == nil, changes.mappedButton == nil,
                  changes.joystickMapping == nil, changes.joystickSettings == nil,
                  changes.triggerSettings == nil, changes.trackpadSettings == nil
            else { throw ThumbleConfigurationBridgeError.invalidElementChanges }
            if changes.clearLabel { customization.setLabel("", for: button) }
            else if let label = changes.label { customization.setLabel(label, for: button) }
            if changes.clearVisualRole,
               let index = customization.elements.firstIndex(where: { $0.builtInButton == button }) {
                customization.elements[index].visualRole = nil
            } else if let visualRole = changes.visualRole,
                      let index = customization.elements.firstIndex(where: { $0.builtInButton == button }) {
                customization.elements[index].visualRole = visualRole
            }
            var layout = customization.buttonCustomization(for: button)
            try applyLayoutChanges(changes, to: &layout, in: customization)
            customization.setButtonCustomization(layout, for: button)
            customization = customization.normalized
        case .custom(let id):
            let fallback = customization.customButtons.first(where: { $0.id == id })
                .map { customization.visualLabel(for: $0.mappedButton) } ?? "Button"
            let referenceCustomization = customization
            do {
                try customization.mutateStandaloneCustomControl(id: id) { control in
                    if changes.clearLabel {
                        control.label = control.controlKind == .text ? "Text" : fallback
                    } else if let label = changes.label {
                        control.label = label
                    }
                    if let mappedButton = changes.mappedButton { control.mappedButton = mappedButton }
                    if let kind = changes.kind { control.controlKind = kind }
                    if changes.clearVisualRole { control.visualRole = nil }
                    else if let visualRole = changes.visualRole { control.visualRole = visualRole }
                    try applyChanges(changes, to: &control, in: referenceCustomization, permitsKind: true)
                }
            } catch {
                throw ThumbleConfigurationBridgeError.invalidElementChanges
            }
        case .system(.topBarActivation):
            guard changes.label == nil, !changes.clearLabel, changes.kind == nil,
                  changes.mappedButton == nil, changes.visualRole == nil, !changes.clearVisualRole,
                  changes.joystickMapping == nil, changes.joystickSettings == nil,
                  changes.triggerSettings == nil, changes.trackpadSettings == nil,
                  changes.output == nil
            else { throw ThumbleConfigurationBridgeError.invalidElementChanges }
            try applyLayoutChanges(changes, to: &customization.topBarActivationRegion, in: customization)
            customization = customization.normalized
        case .controlBarItem:
            throw ThumbleConfigurationBridgeError.invalidElementID
        }
        try applyElementOutput(changes.output, to: identity, in: &customization)
    }

    private static func applyChanges(
        _ changes: ThumbleBridgeElementChanges,
        to control: inout GamepadCustomButton,
        in customization: GamepadCustomization,
        permitsKind: Bool
    ) throws {
        if permitsKind, let kind = changes.kind { control.controlKind = kind }
        let hasJoystickChanges = changes.joystickMapping != nil
            || changes.joystickSettings != nil
            || changes.joystickVisualStyle != nil
        if control.controlKind == .joystick || hasJoystickChanges {
            control.controlKind = .joystick
            if let mapping = changes.joystickMapping { control.joystickMapping = mapping }
            control.joystickMapping = control.joystickMapping ?? .movement
            if let settings = changes.joystickSettings {
                control.joystickOutputSettings = try settings.applying(
                    to: control.joystickOutputSettings ?? .defaultValue
                )
            } else {
                control.joystickOutputSettings = control.joystickOutputSettings ?? .defaultValue
            }
            control.triggerSettings = nil
            control.trackpadSettings = nil
            control.layout.shape = .circle
        } else if control.controlKind == .trigger || changes.triggerSettings != nil {
            control.controlKind = .trigger
            control.joystickMapping = nil
            control.joystickOutputSettings = nil
            if let settings = changes.triggerSettings {
                control.triggerSettings = try settings.applying(to: control.triggerSettings ?? .defaultValue)
            } else {
                control.triggerSettings = control.triggerSettings ?? .defaultValue
            }
            control.trackpadSettings = nil
            control.layout.shape = .capsule
        } else if control.controlKind == .trackpad || changes.trackpadSettings != nil {
            control.controlKind = .trackpad
            control.joystickMapping = nil
            control.joystickOutputSettings = nil
            control.triggerSettings = nil
            if let settings = changes.trackpadSettings {
                control.trackpadSettings = try settings.applying(to: control.trackpadSettings ?? .defaultValue)
            } else {
                control.trackpadSettings = control.trackpadSettings ?? .defaultValue
            }
            control.layout.shape = control.layout.shape ?? .roundedRectangle
        } else {
            control.joystickMapping = nil
            control.joystickOutputSettings = nil
            control.triggerSettings = nil
            control.trackpadSettings = nil
            if control.controlKind == .text {
                control.layout.shape = .rectangle
                control.layout.shadowStrength = 0
                control.layout.showsIntegratedLabel = false
            } else if control.controlKind == .decoration {
                control.layout.shape = control.layout.shape ?? .roundedRectangle
                control.layout.shadowStrength = 0
            }
        }
        try applyLayoutChanges(changes, to: &control.layout, in: customization)
    }

    private static func validateElementChanges(
        _ changes: ThumbleBridgeElementChanges,
        permitsKind: Bool
    ) throws {
        guard permitsKind || changes.kind == nil,
              !(changes.label != nil && changes.clearLabel),
              !(changes.visualRole != nil && changes.clearVisualRole),
              !(changes.hitInsets != nil && changes.clearHitInsets),
              !(changes.fill != nil && changes.clearFill),
              !(changes.lightFill != nil && changes.clearLightFill),
              !(changes.darkFill != nil && changes.clearDarkFill),
              !(changes.thumbFill != nil && changes.clearThumbFill),
              !(changes.lightThumbFill != nil && changes.clearLightThumbFill),
              !(changes.darkThumbFill != nil && changes.clearDarkThumbFill),
              !(changes.styleID != nil && changes.clearStyle),
              !(changes.icon != nil && changes.clearIcon),
              !(changes.haptic != nil && changes.clearHaptic),
              !(changes.cornerRadius != nil && changes.cornerRadii != nil),
              !(changes.appearance?.icon != nil && changes.icon != nil),
              !(changes.appearance?.haptic != nil && changes.haptic != nil)
        else { throw ThumbleConfigurationBridgeError.invalidElementChanges }
        if let label = changes.label {
            guard label.count <= 64, !label.contains(where: \.isNewline) else {
                throw ThumbleConfigurationBridgeError.invalidElementChanges
            }
        }
        for (value, range) in [
            (changes.centerX, 0.0 ... 1.0), (changes.centerY, 0.0 ... 1.0),
            (changes.widthScale, 0.001 ... 12.0), (changes.heightScale, 0.001 ... 12.0),
            (changes.rotationDegrees, -36_000.0 ... 36_000.0),
            (changes.cornerRadius, 0.0 ... 1_024.0), (changes.shadowStrength, 0.0 ... 2.0),
            (changes.fillOpacity, 0.0 ... 1.0), (changes.lightFillOpacity, 0.0 ... 1.0),
            (changes.darkFillOpacity, 0.0 ... 1.0), (changes.thumbOpacity, 0.0 ... 1.0),
            (changes.lightThumbOpacity, 0.0 ... 1.0), (changes.darkThumbOpacity, 0.0 ... 1.0)
        ] {
            if let value { try requireFinite(value, in: range) }
        }
        if let zIndex = changes.zIndex, !(-100 ... 100).contains(zIndex) {
            throw ThumbleConfigurationBridgeError.invalidElementChanges
        }
        if let hitInsets = changes.hitInsets, hitInsets.insets == nil {
            throw ThumbleConfigurationBridgeError.invalidElementChanges
        }
        if let cornerRadii = changes.cornerRadii, cornerRadii.radii == nil {
            throw ThumbleConfigurationBridgeError.invalidElementChanges
        }
        for color in [changes.thumbFill, changes.lightThumbFill, changes.darkThumbFill].compactMap({ $0 }) {
            guard color.color != nil else { throw ThumbleConfigurationBridgeError.invalidElementChanges }
        }
        if let styleID = changes.styleID { try validateStyleID(styleID) }
        if let output = changes.output, case .keep = output.keyboardEdit, case .keep = output.gamepadEdit {
            throw ThumbleConfigurationBridgeError.invalidOutputEdit
        }
    }

    private static func validateControlBarItemChanges(
        _ changes: ThumbleBridgeControlBarItemChanges,
        item: GamepadControlBarItem
    ) throws {
        guard !changes.isEmpty,
              !(changes.fill != nil && changes.clearFill),
              !(changes.lightFill != nil && changes.clearLightFill),
              !(changes.darkFill != nil && changes.clearDarkFill),
              !(changes.styleID != nil && changes.clearStyle),
              !(changes.icon != nil && changes.clearIcon),
              !(changes.haptic != nil && changes.clearHaptic),
              !(changes.cornerRadius != nil && changes.cornerRadii != nil),
              !(changes.appearance?.icon != nil && changes.icon != nil),
              !(changes.appearance?.haptic != nil && changes.haptic != nil),
              item != .spacer || !changes.hasSpacerForbiddenChange
        else { throw ThumbleConfigurationBridgeError.invalidControlBar }
        for (value, range) in [
            (changes.widthScale, 0.001 ... 12.0), (changes.heightScale, 0.001 ... 12.0),
            (changes.cornerRadius, 0.0 ... 1_024.0), (changes.shadowStrength, 0.0 ... 2.0),
            (changes.fillOpacity, 0.0 ... 1.0), (changes.lightFillOpacity, 0.0 ... 1.0),
            (changes.darkFillOpacity, 0.0 ... 1.0)
        ] {
            if let value { try requireFinite(value, in: range) }
        }
        if let cornerRadii = changes.cornerRadii, cornerRadii.radii == nil {
            throw ThumbleConfigurationBridgeError.invalidControlBar
        }
        if let styleID = changes.styleID { try validateStyleID(styleID) }
    }

    private static func applyControlBarItemChanges(
        _ changes: ThumbleBridgeControlBarItemChanges,
        to layout: inout GamepadButtonCustomization,
        in customization: GamepadCustomization
    ) throws {
        if let widthScale = changes.widthScale { layout.widthScale = widthScale }
        if let heightScale = changes.heightScale { layout.heightScale = heightScale }
        if let isHidden = changes.isHidden { layout.isHidden = isHidden }
        if let shape = changes.shape { layout.shape = shape }
        if let accentStyle = changes.accentStyle {
            layout.accentStyle = accentStyle
            layout.fillColor = nil
            layout.lightFillColor = nil
            layout.darkFillColor = nil
            layout.fillStyle = nil
            layout.lightFillStyle = nil
            layout.darkFillStyle = nil
        }
        if let cornerRadius = changes.cornerRadius {
            layout.shape = .roundedRectangle
            layout.cornerRadius = cornerRadius
            layout.cornerRadii = nil
        } else if let cornerRadii = changes.cornerRadii {
            layout.shape = .roundedRectangle
            layout.cornerRadius = nil
            layout.cornerRadii = cornerRadii.radii
        }
        if let shadowStrength = changes.shadowStrength { layout.shadowStrength = shadowStrength }
        if changes.clearFill {
            layout.fillColor = nil
            layout.lightFillColor = nil
            layout.darkFillColor = nil
            layout.fillStyle = nil
            layout.lightFillStyle = nil
            layout.darkFillStyle = nil
        } else if let fill = changes.fill {
            setGlobalFill(fill.fillStyle, in: &layout)
        }
        if changes.clearLightFill { clearSchemeFill(isDark: false, in: &layout) }
        else if let fill = changes.lightFill { setSchemeFill(fill.fillStyle, isDark: false, in: &layout) }
        if changes.clearDarkFill { clearSchemeFill(isDark: true, in: &layout) }
        else if let fill = changes.darkFill { setSchemeFill(fill.fillStyle, isDark: true, in: &layout) }
        if let opacity = changes.fillOpacity { setGlobalFillOpacity(opacity, in: &layout) }
        if let opacity = changes.lightFillOpacity { setSchemeFillOpacity(opacity, isDark: false, in: &layout) }
        if let opacity = changes.darkFillOpacity { setSchemeFillOpacity(opacity, isDark: true, in: &layout) }
        if changes.clearStyle {
            layout.styleID = nil
        } else if let styleID = changes.styleID {
            guard customization.styleLibrary.style(id: styleID) != nil else {
                throw ThumbleConfigurationBridgeError.invalidStyle
            }
            layout.styleID = styleID
        }
        if let appearance = changes.appearance {
            layout.visualStyle = try appearance.elementVisualStyle(overlaying: layout.visualStyle)
        }
        if changes.clearIcon {
            layout.icon = nil
        } else if let icon = changes.icon {
            let value = icon.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.count <= 80 else { throw ThumbleConfigurationBridgeError.invalidStyle }
            layout.icon = switch icon.source {
            case .sfSymbol: .sfSymbol(value)
            case .text: .text(value)
            }
        }
        if changes.clearHaptic {
            layout.hapticStyle = nil
            layout.hapticFeedback = nil
        } else if let input = changes.haptic {
            let existing = layout.hapticFeedback ?? layout.hapticStyle.map { GamepadHapticFeedback(style: $0) }
            let feedback = try elementHaptic(input, existing: existing)
            if feedback.isDefault {
                layout.hapticStyle = nil
                layout.hapticFeedback = nil
            } else {
                layout.hapticStyle = feedback.style
                layout.hapticFeedback = feedback
            }
        }
        layout = layout.normalized
    }

    private static func applyLayoutChanges(
        _ changes: ThumbleBridgeElementChanges,
        to layout: inout GamepadButtonCustomization,
        in customization: GamepadCustomization
    ) throws {
        if let centerX = changes.centerX { layout.centerX = centerX }
        if let centerY = changes.centerY { layout.centerY = centerY }
        if let widthScale = changes.widthScale { layout.widthScale = widthScale }
        if let heightScale = changes.heightScale { layout.heightScale = heightScale }
        if let rotationDegrees = changes.rotationDegrees { layout.rotationDegrees = rotationDegrees }
        if let shape = changes.shape { layout.shape = shape }
        if let isHidden = changes.isHidden { layout.isHidden = isHidden }
        if let isLocationLocked = changes.isLocationLocked { layout.isLocationLocked = isLocationLocked }
        if let showsIntegratedLabel = changes.showsIntegratedLabel { layout.showsIntegratedLabel = showsIntegratedLabel }
        if let zIndex = changes.zIndex { layout.zIndex = zIndex }
        if changes.clearHitInsets { layout.hitInsets = nil }
        else if let hitInsets = changes.hitInsets { layout.hitInsets = hitInsets.insets }
        if let cornerRadius = changes.cornerRadius {
            layout.shape = .roundedRectangle
            layout.cornerRadius = cornerRadius
            layout.cornerRadii = nil
        } else if let cornerRadii = changes.cornerRadii {
            layout.shape = .roundedRectangle
            layout.cornerRadius = nil
            layout.cornerRadii = cornerRadii.radii
        }
        if let shadowStrength = changes.shadowStrength { layout.shadowStrength = shadowStrength }
        if changes.clearFill {
            layout.fillColor = nil
            layout.lightFillColor = nil
            layout.darkFillColor = nil
            layout.fillStyle = nil
            layout.lightFillStyle = nil
            layout.darkFillStyle = nil
        } else if let fill = changes.fill {
            setGlobalFill(fill.fillStyle, in: &layout)
        }
        if changes.clearLightFill { clearSchemeFill(isDark: false, in: &layout) }
        else if let fill = changes.lightFill { setSchemeFill(fill.fillStyle, isDark: false, in: &layout) }
        if changes.clearDarkFill { clearSchemeFill(isDark: true, in: &layout) }
        else if let fill = changes.darkFill { setSchemeFill(fill.fillStyle, isDark: true, in: &layout) }
        if let opacity = changes.fillOpacity { setGlobalFillOpacity(opacity, in: &layout) }
        if let opacity = changes.lightFillOpacity { setSchemeFillOpacity(opacity, isDark: false, in: &layout) }
        if let opacity = changes.darkFillOpacity { setSchemeFillOpacity(opacity, isDark: true, in: &layout) }
        if changes.clearThumbFill {
            layout.joystickKnobColor = nil
            layout.lightJoystickKnobColor = nil
            layout.darkJoystickKnobColor = nil
        } else if let color = changes.thumbFill?.color {
            layout.joystickKnobColor = color
            layout.lightJoystickKnobColor = nil
            layout.darkJoystickKnobColor = nil
        }
        if changes.clearLightThumbFill { clearSchemeThumb(isDark: false, in: &layout) }
        else if let color = changes.lightThumbFill?.color { setSchemeThumb(color, isDark: false, in: &layout) }
        if changes.clearDarkThumbFill { clearSchemeThumb(isDark: true, in: &layout) }
        else if let color = changes.darkThumbFill?.color { setSchemeThumb(color, isDark: true, in: &layout) }
        if let opacity = changes.thumbOpacity {
            var color = layout.joystickKnobColor ?? .defaultValue
            color.alpha = opacity
            layout.joystickKnobColor = color
        }
        if let opacity = changes.lightThumbOpacity { setSchemeThumbOpacity(opacity, isDark: false, in: &layout) }
        if let opacity = changes.darkThumbOpacity { setSchemeThumbOpacity(opacity, isDark: true, in: &layout) }
        if let joystickVisualStyle = changes.joystickVisualStyle {
            layout.joystickVisualStyle = joystickVisualStyle == .pad ? nil : joystickVisualStyle
        }
        if changes.clearStyle { layout.styleID = nil }
        else if let styleID = changes.styleID {
            guard customization.styleLibrary.style(id: styleID) != nil else {
                throw ThumbleConfigurationBridgeError.invalidStyle
            }
            layout.styleID = styleID
        }
        if let appearance = changes.appearance {
            layout.visualStyle = try appearance.elementVisualStyle(overlaying: layout.visualStyle)
        }
        if changes.clearIcon { layout.icon = nil }
        else if let icon = changes.icon {
            let value = icon.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.count <= 80 else { throw ThumbleConfigurationBridgeError.invalidStyle }
            layout.icon = switch icon.source {
            case .sfSymbol: .sfSymbol(value)
            case .text: .text(value)
            }
        }
        if changes.clearHaptic {
            layout.hapticStyle = nil
            layout.hapticFeedback = nil
        } else if let input = changes.haptic {
            let existing = layout.hapticFeedback ?? layout.hapticStyle.map { GamepadHapticFeedback(style: $0) }
            let feedback = try elementHaptic(input, existing: existing)
            if feedback.isDefault {
                layout.hapticStyle = nil
                layout.hapticFeedback = nil
            } else {
                layout.hapticStyle = feedback.style
                layout.hapticFeedback = feedback
            }
        }
        layout = layout.normalized
    }

    private static func setGlobalFill(_ fill: GamepadFillStyle, in layout: inout GamepadButtonCustomization) {
        layout.lightFillColor = nil
        layout.darkFillColor = nil
        layout.lightFillStyle = nil
        layout.darkFillStyle = nil
        if case .solid(let color) = fill {
            layout.fillColor = color
            layout.fillStyle = nil
        } else {
            layout.fillColor = nil
            layout.fillStyle = fill
        }
    }

    private static func prepareSchemeFills(_ layout: inout GamepadButtonCustomization) {
        if let fill = layout.fillColor {
            layout.lightFillColor = layout.lightFillColor ?? fill
            layout.darkFillColor = layout.darkFillColor ?? fill
        }
        if let fill = layout.fillStyle {
            layout.lightFillStyle = layout.lightFillStyle ?? fill
            layout.darkFillStyle = layout.darkFillStyle ?? fill
        }
        layout.fillColor = nil
        layout.fillStyle = nil
    }

    private static func setSchemeFill(_ fill: GamepadFillStyle, isDark: Bool, in layout: inout GamepadButtonCustomization) {
        prepareSchemeFills(&layout)
        if isDark {
            if case .solid(let color) = fill { layout.darkFillColor = color; layout.darkFillStyle = nil }
            else { layout.darkFillColor = nil; layout.darkFillStyle = fill }
        } else {
            if case .solid(let color) = fill { layout.lightFillColor = color; layout.lightFillStyle = nil }
            else { layout.lightFillColor = nil; layout.lightFillStyle = fill }
        }
    }

    private static func clearSchemeFill(isDark: Bool, in layout: inout GamepadButtonCustomization) {
        prepareSchemeFills(&layout)
        if isDark { layout.darkFillColor = nil; layout.darkFillStyle = nil }
        else { layout.lightFillColor = nil; layout.lightFillStyle = nil }
    }

    private static func setGlobalFillOpacity(_ opacity: Double, in layout: inout GamepadButtonCustomization) {
        if let fill = layout.fillStyle { layout.fillStyle = fill.withOpacity(opacity) }
        else { var color = layout.fillColor ?? .defaultValue; color.alpha = opacity; layout.fillColor = color }
    }

    private static func setSchemeFillOpacity(_ opacity: Double, isDark: Bool, in layout: inout GamepadButtonCustomization) {
        let fill: GamepadFillStyle = if isDark {
            layout.darkFillStyle ?? layout.darkFillColor.map(GamepadFillStyle.solid)
                ?? layout.fillStyle ?? layout.fillColor.map(GamepadFillStyle.solid) ?? .solid(.defaultValue)
        } else {
            layout.lightFillStyle ?? layout.lightFillColor.map(GamepadFillStyle.solid)
                ?? layout.fillStyle ?? layout.fillColor.map(GamepadFillStyle.solid) ?? .solid(.defaultValue)
        }
        setSchemeFill(fill.withOpacity(opacity), isDark: isDark, in: &layout)
    }

    private static func prepareSchemeThumbs(_ layout: inout GamepadButtonCustomization) {
        if let color = layout.joystickKnobColor {
            layout.lightJoystickKnobColor = layout.lightJoystickKnobColor ?? color
            layout.darkJoystickKnobColor = layout.darkJoystickKnobColor ?? color
        }
        layout.joystickKnobColor = nil
    }

    private static func setSchemeThumb(_ color: GamepadRGBAColor, isDark: Bool, in layout: inout GamepadButtonCustomization) {
        prepareSchemeThumbs(&layout)
        if isDark { layout.darkJoystickKnobColor = color } else { layout.lightJoystickKnobColor = color }
    }

    private static func clearSchemeThumb(isDark: Bool, in layout: inout GamepadButtonCustomization) {
        prepareSchemeThumbs(&layout)
        if isDark { layout.darkJoystickKnobColor = nil } else { layout.lightJoystickKnobColor = nil }
    }

    private static func setSchemeThumbOpacity(_ opacity: Double, isDark: Bool, in layout: inout GamepadButtonCustomization) {
        var color = (isDark ? layout.darkJoystickKnobColor : layout.lightJoystickKnobColor)
            ?? layout.joystickKnobColor ?? .defaultValue
        color.alpha = opacity
        setSchemeThumb(color, isDark: isDark, in: &layout)
    }

    private static func elementHaptic(
        _ input: ThumbleBridgeStyleHaptic,
        existing: GamepadHapticFeedback?
    ) throws -> GamepadHapticFeedback {
        guard input.style != nil || input.pattern != nil || input.intensity != nil
                || input.sharpness != nil || input.duration != nil
        else { throw ThumbleConfigurationBridgeError.invalidStyle }
        var feedback = existing ?? GamepadHapticFeedback(style: input.style ?? .light)
        if let style = input.style { feedback.style = style }
        if let pattern = input.pattern { feedback.pattern = pattern }
        if let intensity = input.intensity { try requireFinite(intensity, in: 0 ... 1); feedback.intensity = intensity }
        if let sharpness = input.sharpness { try requireFinite(sharpness, in: 0 ... 1); feedback.sharpness = sharpness }
        if let duration = input.duration { try requireFinite(duration, in: 0.02 ... 0.30); feedback.duration = duration }
        return feedback.normalized
    }

    private static func applyElementOutput(
        _ changes: ThumbleBridgeElementOutputChanges?,
        to identity: GamepadControlIdentity,
        in customization: inout GamepadCustomization
    ) throws {
        guard let changes else { return }
        #if os(macOS)
        let normalized = customization.normalized
        guard let element = normalized.element(for: identity) else {
            throw ThumbleConfigurationBridgeError.invalidElementID
        }
        var output = element.outputBinding(for: changes.part)
            .map(MacControlOutputBinding.init(shared:)) ?? MacControlOutputBinding()
        switch changes.keyboardEdit {
        case .keep: break
        case .clear: output.keyboard = nil
        case .set(let sequence): output.keyboard = try semanticKeyBinding(sequence)
        }
        switch changes.gamepadEdit {
        case .keep: break
        case .clear: output.gamepadButtons.removeAll()
        case .set(let button): output.setGamepadButton(button)
        }
        do {
            try customization.setStandaloneElementOutput(
                output.isEmpty ? nil : output.sharedBinding,
                for: identity,
                part: changes.part
            )
        } catch {
            throw ThumbleConfigurationBridgeError.invalidElementChanges
        }
        #else
        throw ThumbleConfigurationBridgeError.unsupportedOperation
        #endif
    }

    private static func firstAvailableCustomSlot(in customization: GamepadCustomization) -> GameButton? {
        GameButton.customSlots.first { slot in
            !customization.customButtons.contains { $0.mappedButton == slot }
        }
    }

    private static func validateStyleID(_ styleID: String) throws {
        guard !styleID.isEmpty, styleID.utf8.count <= 128,
              styleID == GamepadStyleToken.normalizedIdentifier(styleID)
        else { throw ThumbleConfigurationBridgeError.invalidStyle }
    }

    private static func mutateStyleResources(
        in profile: inout GamepadConfigurationProfile,
        mutate: (inout GamepadCustomization) -> Void
    ) {
        mutate(&profile.customization)
        profile.customization = profile.customization.normalized
        if var landscape = profile.landscapeCustomization {
            mutate(&landscape)
            profile.landscapeCustomization = landscape.normalized
        }
        if var portrait = profile.portraitCustomization {
            mutate(&portrait)
            profile.portraitCustomization = portrait.normalized
        }
    }

    private static func setStyleID(
        _ styleID: String?,
        for identity: GamepadControlIdentity,
        in customization: inout GamepadCustomization
    ) throws {
        guard customization.setReusableStyleID(styleID, for: identity) else {
            throw ThumbleConfigurationBridgeError.invalidElementID
        }
    }

    private static func copyOrientation(
        profileID: String,
        source: GamepadProfileLayoutVariant,
        destination: GamepadProfileLayoutVariant,
        automaticallyArrange: Bool,
        in document: inout ThumbleBridgeConfigurationDocument,
        nowMillis: Int64
    ) throws -> [String] {
        guard source != destination else { throw ThumbleConfigurationBridgeError.identicalOrientations }
        let index = try profileIndex(profileID, in: document)
        let rawProfile = document.profiles[index]
        guard case .object(var rawObject) = rawProfile,
              let rawPrimary = rawObject["customization"]
        else { throw ThumbleConfigurationBridgeError.invalidProfile }
        var profile: GamepadConfigurationProfile = try decoded(rawProfile)
        let sourceOrientation = source == .landscape
            ? GamepadEditorDeviceOrientation.landscape
            : GamepadEditorDeviceOrientation.portrait
        let sourceKey = source == .landscape ? "landscapeCustomization" : "portraitCustomization"
        let destinationKey = destination == .landscape ? "landscapeCustomization" : "portraitCustomization"
        let sourceExists = profile.hasCustomizationVariant(for: sourceOrientation)
            || profile.customization.deviceCanvas.editorDeviceFrame.orientation == sourceOrientation
        guard sourceExists else { throw ThumbleConfigurationBridgeError.missingOrientation }

        let rawSource = rawObject[sourceKey] ?? rawPrimary
        let canonicalSource = try encodedJSONValue(profile.customization(for: sourceOrientation))
        profile.copyLayoutVariant(
            from: source,
            to: destination,
            automaticallyArrange: automaticallyArrange
        )
        let canonicalDestination = try encodedJSONValue(profile.customization)
        let copiedDestination = applyCanonicalChanges(
            raw: rawSource,
            before: canonicalSource,
            after: canonicalDestination
        )
        if rawObject[sourceKey] == nil { rawObject[sourceKey] = rawSource }
        rawObject[destinationKey] = copiedDestination
        rawObject["customization"] = copiedDestination
        rawObject["updatedAt"] = .integer(nowMillis)
        let after = ThumbleBridgeJSONValue.object(rawObject)
        guard after != rawProfile else { return [] }
        document.profiles[index] = after
        let canonicalID = try rawProfile.requiredString(forKey: "id")
        return ["/profiles/\(escapePointer(canonicalID))"]
    }

    private static func mutateProfile(
        _ profileID: String,
        in document: inout ThumbleBridgeConfigurationDocument,
        nowMillis: Int64,
        mutate: (inout GamepadConfigurationProfile) throws -> Void
    ) throws -> [String] {
        let index = try profileIndex(profileID, in: document)
        let raw = document.profiles[index]
        let beforeProfile: GamepadConfigurationProfile = try decoded(raw)
        let beforeCanonical = try encodedJSONValue(beforeProfile)
        var afterProfile = beforeProfile
        try mutate(&afterProfile)
        let mutatedCanonical = try encodedJSONValue(afterProfile.normalized)
        guard mutatedCanonical != beforeCanonical else { return [] }
        afterProfile.updatedAt = nowMillis
        let afterCanonical = try encodedJSONValue(afterProfile.normalized)
        let overlaid = applyCanonicalChanges(raw: raw, before: beforeCanonical, after: afterCanonical)
        document.profiles[index] = compactAddedOrientationMirrors(
            raw: raw,
            before: beforeCanonical,
            after: afterCanonical,
            overlaid: overlaid
        )
        let canonicalID = try raw.requiredString(forKey: "id")
        return ["/profiles/\(escapePointer(canonicalID))"]
    }

    private static func compactAddedOrientationMirrors(
        raw: ThumbleBridgeJSONValue,
        before: ThumbleBridgeJSONValue,
        after: ThumbleBridgeJSONValue,
        overlaid: ThumbleBridgeJSONValue
    ) -> ThumbleBridgeJSONValue {
        guard case .object(let rawObject) = raw,
              case .object(let beforeObject) = before,
              case .object(let afterObject) = after,
              case .object(var result) = overlaid
        else { return overlaid }
        for key in ["landscapeCustomization", "portraitCustomization"] {
            guard rawObject[key] == nil,
                  beforeObject[key] == nil,
                  let added = afterObject[key]
            else { continue }
            if added == afterObject["customization"], let customization = result["customization"] {
                result[key] = customization
            } else if added == beforeObject["customization"],
                      let customization = rawObject["customization"] {
                result[key] = customization
            }
        }
        return .object(result)
    }

    private static func customization(
        in profile: GamepadConfigurationProfile,
        variant: ThumbleBridgeLayoutVariant
    ) -> GamepadCustomization {
        switch variant {
        case .primary: profile.customization
        case .landscape: profile.customization(for: .landscape)
        case .portrait: profile.customization(for: .portrait)
        }
    }

    private static func setCustomization(
        _ customization: GamepadCustomization,
        in profile: inout GamepadConfigurationProfile,
        variant: ThumbleBridgeLayoutVariant
    ) {
        switch variant {
        case .primary:
            profile.setCustomization(customization, for: customization.deviceCanvas.editorDeviceFrame.orientation)
        case .landscape:
            profile.setCustomization(customization, for: .landscape)
        case .portrait:
            profile.setCustomization(customization, for: .portrait)
        }
    }

    private static func validate(_ document: ThumbleBridgeConfigurationDocument) throws {
        guard !document.profiles.isEmpty, document.profiles.count <= 256 else {
            throw ThumbleConfigurationBridgeError.invalidProfileCount
        }
        var ids = Set<String>()
        for profile in document.profiles {
            let id = try profile.requiredString(forKey: "id")
            guard UUID(uuidString: id) != nil, ids.insert(id.lowercased()).inserted else {
                throw ThumbleConfigurationBridgeError.invalidProfileID
            }
            _ = try profileName(profile.requiredString(forKey: "name"))
            guard case .object = try profile.requiredObjectValue(forKey: "customization") else {
                throw ThumbleConfigurationBridgeError.invalidProfile
            }
            let _: GamepadConfigurationProfile = try decoded(profile)
        }
        guard ids.contains(document.activeProfileID.lowercased()),
              ids.contains(document.defaultProfileID.lowercased())
        else { throw ThumbleConfigurationBridgeError.missingSelectedProfile }
        guard document.profileKeyBindings.count <= 512, document.profileOutputBindings.count <= 512 else {
            throw ThumbleConfigurationBridgeError.tooManyBindingMaps
        }
    }

    private static func groupUUID(_ value: String) throws -> UUID {
        guard value.utf8.count <= 128, let id = UUID(uuidString: value) else {
            throw ThumbleConfigurationBridgeError.invalidGroup
        }
        return id
    }

    private static func requiredGroup(
        _ id: UUID,
        in customization: GamepadCustomization
    ) throws -> GamepadLayerGroup {
        guard let group = customization.designMetadata?
            .normalized(availableControls: customization.allControlIdentitiesForDesign)?
            .groups.first(where: { $0.id == id })
        else { throw ThumbleConfigurationBridgeError.invalidGroup }
        return group
    }

    private static func mutateGroupState(
        _ profileID: String,
        variant: ThumbleBridgeLayoutVariant,
        groupID: String,
        in document: inout ThumbleBridgeConfigurationDocument,
        nowMillis: Int64,
        mutate: (inout GamepadCustomization, UUID) throws -> Void
    ) throws -> [String] {
        let groupID = try groupUUID(groupID)
        return try mutateProfile(profileID, in: &document, nowMillis: nowMillis) { profile in
            var customization = customization(in: profile, variant: variant)
            do {
                try mutate(&customization, groupID)
            } catch let error as ThumbleConfigurationBridgeError {
                throw error
            } catch {
                throw ThumbleConfigurationBridgeError.invalidGroup
            }
            setCustomization(customization, in: &profile, variant: variant)
        }
    }

    private static func mutateGroupLayers(
        _ profileID: String,
        variant: ThumbleBridgeLayoutVariant,
        groupID: String,
        in document: inout ThumbleBridgeConfigurationDocument,
        nowMillis: Int64,
        mutate: (inout GamepadCustomization, Set<GamepadControlIdentity>) -> Void
    ) throws -> [String] {
        try mutateGroupState(profileID, variant: variant, groupID: groupID, in: &document, nowMillis: nowMillis) { customization, groupID in
            let group = try requiredGroup(groupID, in: customization)
            mutate(&customization, Set(group.children))
        }
    }

    private static func mutateLayer(
        _ profileID: String,
        variant: ThumbleBridgeLayoutVariant,
        elementID: String,
        in document: inout ThumbleBridgeConfigurationDocument,
        nowMillis: Int64,
        mutate: (inout GamepadCustomization, GamepadControlIdentity) -> Void
    ) throws -> [String] {
        try validateElementIDs([elementID], minimum: 1)
        return try mutateProfile(profileID, in: &document, nowMillis: nowMillis) { profile in
            var customization = customization(in: profile, variant: variant)
            let identity = try layerIdentity(elementID, in: customization)
            mutate(&customization, identity)
            setCustomization(customization, in: &profile, variant: variant)
        }
    }

    private static func validateElementIDs(_ values: [String], minimum: Int) throws {
        guard values.count >= minimum, values.count <= 128 else {
            throw ThumbleConfigurationBridgeError.invalidElementID
        }
        var seen = Set<String>()
        for value in values {
            guard !value.isEmpty, value.utf8.count <= 128, seen.insert(value.lowercased()).inserted else {
                throw ThumbleConfigurationBridgeError.invalidElementID
            }
        }
    }

    private static func validateFinite(_ value: Double, range: ClosedRange<Double>) throws {
        guard value.isFinite, range.contains(value) else {
            throw ThumbleConfigurationBridgeError.invalidGeometry
        }
    }

    private static func layerIdentity(
        _ value: String,
        in customization: GamepadCustomization
    ) throws -> GamepadControlIdentity {
        let identity: GamepadControlIdentity?
        if let uuid = UUID(uuidString: value) {
            identity = customization.identity(forElementID: uuid)
        } else if let stable = GamepadControlIdentity(stableID: value) {
            identity = stable
        } else {
            identity = nil
        }
        guard let identity, customization.allControlIdentitiesForDesign.contains(identity) else {
            throw ThumbleConfigurationBridgeError.invalidElementID
        }
        return identity
    }

    private static func controlIdentity(
        _ value: String,
        in customization: GamepadCustomization
    ) throws -> GamepadControlIdentity {
        if let uuid = UUID(uuidString: value),
           let identity = customization.identity(forElementID: uuid) {
            return identity
        }
        if let identity = GamepadControlIdentity(stableID: value),
           customization.resolvedControls(
               in: customization.deviceCanvas.editorDeviceFrame.screenRect.size
           ).contains(where: { $0.id == identity }) {
            return identity
        }
        throw ThumbleConfigurationBridgeError.invalidElementID
    }

    private static func profileIndex(
        _ profileID: String,
        in document: ThumbleBridgeConfigurationDocument
    ) throws -> Int {
        guard !profileID.isEmpty, profileID.utf8.count <= 128 else { throw ThumbleConfigurationBridgeError.invalidProfileID }
        guard let index = try document.profiles.firstIndex(where: { profile in
            idsEqual(try profile.requiredString(forKey: "id"), profileID)
        }) else { throw ThumbleConfigurationBridgeError.profileNotFound }
        return index
    }

    private static func existingProfileID(
        _ profileID: String,
        in document: ThumbleBridgeConfigurationDocument
    ) throws -> String {
        let index = try profileIndex(profileID, in: document)
        return try document.profiles[index].requiredString(forKey: "id")
    }

    private static func canonicalNewProfileID(
        _ profileID: String,
        in document: ThumbleBridgeConfigurationDocument,
        ignoring ignoredID: String? = nil
    ) throws -> String {
        guard let uuid = UUID(uuidString: profileID), profileID.utf8.count <= 128 else {
            throw ThumbleConfigurationBridgeError.invalidProfileID
        }
        let canonical = uuid.uuidString.lowercased()
        let duplicate = try document.profiles.contains { profile in
            let current = try profile.requiredString(forKey: "id")
            return !idsEqual(current, ignoredID ?? "") && idsEqual(current, canonical)
        }
        guard !duplicate else { throw ThumbleConfigurationBridgeError.duplicateProfileID }
        return canonical
    }

    private static func profileName(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 256 else { throw ThumbleConfigurationBridgeError.invalidProfileName }
        return trimmed
    }

    private static func idsEqual(_ lhs: String, _ rhs: String) -> Bool {
        lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }

    private static func bindingValue(
        for profileID: String,
        in bindings: [String: ThumbleBridgeJSONValue]
    ) -> ThumbleBridgeJSONValue? {
        guard let key = bindings.keys.first(where: { idsEqual($0, profileID) }) else { return nil }
        return bindings[key]
    }

    private static func defaultKeyBindings() throws -> ThumbleBridgeJSONValue {
        #if os(macOS)
        return try encodedJSONValue(Dictionary(uniqueKeysWithValues: DefaultKeypadKeyMap.defaultBindings.map {
            ($0.key.rawValue, $0.value)
        }))
        #else
        return .object([:])
        #endif
    }

    private static func defaultOutputBindings() throws -> ThumbleBridgeJSONValue {
        #if os(macOS)
        return try encodedJSONValue(Dictionary(uniqueKeysWithValues: DefaultMacControlOutputMap.defaultBindings.map {
            ($0.key.rawValue, $0.value)
        }))
        #else
        return .object([:])
        #endif
    }

    private static func cloneOrInstallBindingMaps(
        from sourceID: String,
        to destinationID: String,
        in document: inout ThumbleBridgeConfigurationDocument
    ) throws {
        let keyFallback: ThumbleBridgeJSONValue
        let outputFallback: ThumbleBridgeJSONValue
        if idsEqual(sourceID, document.activeProfileID) {
            keyFallback = document.keyBindings
            outputFallback = document.outputBindings
        } else {
            keyFallback = try defaultKeyBindings()
            outputFallback = try defaultOutputBindings()
        }
        document.profileKeyBindings[destinationID] = bindingValue(
            for: sourceID,
            in: document.profileKeyBindings
        ) ?? keyFallback
        document.profileOutputBindings[destinationID] = bindingValue(
            for: sourceID,
            in: document.profileOutputBindings
        ) ?? outputFallback
    }

    private static func synchronizeActiveBindings(
        in document: inout ThumbleBridgeConfigurationDocument
    ) throws {
        let profileID = try existingProfileID(document.activeProfileID, in: document)
        let keys: ThumbleBridgeJSONValue
        if let existing = bindingValue(for: profileID, in: document.profileKeyBindings) {
            keys = existing
        } else {
            keys = try defaultKeyBindings()
        }
        let outputs: ThumbleBridgeJSONValue
        if let existing = bindingValue(for: profileID, in: document.profileOutputBindings) {
            outputs = existing
        } else {
            outputs = try defaultOutputBindings()
        }
        document.profileKeyBindings[profileID] = keys
        document.profileOutputBindings[profileID] = outputs
        document.keyBindings = keys
        document.outputBindings = outputs
    }

    private static func cloneBindingMap(
        from sourceID: String,
        to destinationID: String,
        in bindings: inout [String: ThumbleBridgeJSONValue]
    ) {
        guard let sourceKey = bindings.keys.first(where: { idsEqual($0, sourceID) }),
              let value = bindings[sourceKey]
        else { return }
        bindings[destinationID] = value
    }

    private static func removeBindingMap(
        for profileID: String,
        from bindings: inout [String: ThumbleBridgeJSONValue]
    ) {
        for key in bindings.keys where idsEqual(key, profileID) { bindings.removeValue(forKey: key) }
    }

    private static func decoded<T: Decodable>(_ value: ThumbleBridgeJSONValue) throws -> T {
        let data = try JSONEncoder.bridge.encode(value)
        return try JSONDecoder.bridge.decode(T.self, from: data)
    }

    private static func encodedJSONValue<T: Encodable>(_ value: T) throws -> ThumbleBridgeJSONValue {
        let data = try JSONEncoder.bridge.encode(value)
        return try JSONDecoder.bridge.decode(ThumbleBridgeJSONValue.self, from: data)
    }

    private static func applyCanonicalChanges(
        raw: ThumbleBridgeJSONValue,
        before: ThumbleBridgeJSONValue,
        after: ThumbleBridgeJSONValue
    ) -> ThumbleBridgeJSONValue {
        if before == after { return raw }
        switch (raw, before, after) {
        case let (.object(rawObject), .object(beforeObject), .object(afterObject)):
            var result = rawObject
            for key in Set(beforeObject.keys).union(afterObject.keys) {
                switch (beforeObject[key], afterObject[key]) {
                case let (beforeValue?, afterValue?):
                    if beforeValue != afterValue {
                        result[key] = applyCanonicalChanges(
                            raw: rawObject[key] ?? beforeValue,
                            before: beforeValue,
                            after: afterValue
                        )
                    }
                case (nil, let afterValue?):
                    if key == "designMetadata",
                       let rawValue = rawObject[key],
                       let defaultMetadata = defaultDesignMetadata(in: beforeObject),
                       containsUnknownFields(raw: rawValue, canonical: defaultMetadata) {
                        result[key] = applyCanonicalChanges(
                            raw: rawValue,
                            before: defaultMetadata,
                            after: afterValue
                        )
                    } else {
                        result[key] = afterValue
                    }
                case (let beforeValue?, nil):
                    if key == "designMetadata",
                       let rawValue = rawObject[key],
                       containsUnknownFields(raw: rawValue, canonical: beforeValue),
                       let defaultMetadata = defaultDesignMetadata(in: afterObject) {
                        result[key] = applyCanonicalChanges(
                            raw: rawValue,
                            before: beforeValue,
                            after: defaultMetadata
                        )
                    } else {
                        result.removeValue(forKey: key)
                    }
                case (nil, nil): break
                }
            }
            return .object(result)
        case let (.array(rawValues), .array(beforeValues), .array(afterValues)):
            if let rawPairs = keyedPairs(rawValues),
               let beforePairs = keyedPairs(beforeValues),
               keyedPairs(afterValues) != nil {
                var result: [ThumbleBridgeJSONValue] = []
                var index = 0
                while index + 1 < afterValues.count {
                    guard case .string(let key) = afterValues[index] else { break }
                    let normalizedKey = key.lowercased()
                    let afterValue = afterValues[index + 1]
                    result.append(afterValues[index])
                    if let beforeValue = beforePairs[normalizedKey] {
                        result.append(applyCanonicalChanges(
                            raw: rawPairs[normalizedKey] ?? beforeValue,
                            before: beforeValue,
                            after: afterValue
                        ))
                    } else {
                        result.append(afterValue)
                    }
                    index += 2
                }
                return .array(result)
            }
            if let rawByIdentity = keyedControlIdentities(rawValues),
               let beforeByIdentity = keyedControlIdentities(beforeValues),
               keyedControlIdentities(afterValues) != nil {
                return .array(afterValues.compactMap { afterValue in
                    guard let key = controlIdentityKey(afterValue) else { return nil }
                    guard let beforeValue = beforeByIdentity[key] else { return afterValue }
                    return applyCanonicalChanges(
                        raw: rawByIdentity[key] ?? beforeValue,
                        before: beforeValue,
                        after: afterValue
                    )
                })
            }
            if let rawByItem = keyedControlBarItemCustomizations(rawValues),
               let beforeByItem = keyedControlBarItemCustomizations(beforeValues),
               keyedControlBarItemCustomizations(afterValues) != nil {
                return .array(afterValues.compactMap { afterValue in
                    guard let key = controlBarItemCustomizationKey(afterValue) else { return nil }
                    guard let beforeValue = beforeByItem[key] else { return afterValue }
                    return applyCanonicalChanges(
                        raw: rawByItem[key] ?? beforeValue,
                        before: beforeValue,
                        after: afterValue
                    )
                })
            }
            if let rawByID = keyed(rawValues),
               let beforeByID = keyed(beforeValues),
               keyed(afterValues) != nil {
                var result: [ThumbleBridgeJSONValue] = []
                for afterValue in afterValues {
                    guard let id = try? afterValue.requiredString(forKey: "id") else { continue }
                    let key = id.lowercased()
                    if let beforeValue = beforeByID[key] {
                        result.append(applyCanonicalChanges(
                            raw: rawByID[key] ?? beforeValue,
                            before: beforeValue,
                            after: afterValue
                        ))
                    } else {
                        result.append(afterValue)
                    }
                }
                return .array(result)
            }
            if rawValues.count == beforeValues.count,
               beforeValues.count == afterValues.count {
                return .array(zip(zip(rawValues, beforeValues), afterValues).map { pair, afterValue in
                    applyCanonicalChanges(raw: pair.0, before: pair.1, after: afterValue)
                })
            }
            return .array(afterValues)
        default:
            return after
        }
    }

    private static func containsUnknownFields(
        raw: ThumbleBridgeJSONValue,
        canonical: ThumbleBridgeJSONValue
    ) -> Bool {
        switch (raw, canonical) {
        case let (.object(rawObject), .object(canonicalObject)):
            return rawObject.contains { key, value in
                guard let canonicalValue = canonicalObject[key] else { return true }
                return containsUnknownFields(raw: value, canonical: canonicalValue)
            }
        case let (.array(rawValues), .array(canonicalValues)):
            if let rawByIdentity = keyedControlIdentities(rawValues),
               let canonicalByIdentity = keyedControlIdentities(canonicalValues) {
                return rawByIdentity.contains { key, value in
                    guard let canonicalValue = canonicalByIdentity[key] else { return true }
                    return containsUnknownFields(raw: value, canonical: canonicalValue)
                }
            }
            if let rawByItem = keyedControlBarItemCustomizations(rawValues),
               let canonicalByItem = keyedControlBarItemCustomizations(canonicalValues) {
                return rawByItem.contains { key, value in
                    guard let canonicalValue = canonicalByItem[key] else { return true }
                    return containsUnknownFields(raw: value, canonical: canonicalValue)
                }
            }
            if let rawByID = keyed(rawValues), let canonicalByID = keyed(canonicalValues) {
                return rawByID.contains { key, value in
                    guard let canonicalValue = canonicalByID[key] else { return true }
                    return containsUnknownFields(raw: value, canonical: canonicalValue)
                }
            }
            guard rawValues.count == canonicalValues.count else { return false }
            return zip(rawValues, canonicalValues).contains {
                containsUnknownFields(raw: $0, canonical: $1)
            }
        default:
            return false
        }
    }

    private static func defaultDesignMetadata(
        in customization: [String: ThumbleBridgeJSONValue]
    ) -> ThumbleBridgeJSONValue? {
        var order: [ThumbleBridgeJSONValue] = [
            .object(["kind": .string("system"), "system": .string("top_bar_activation")])
        ]
        for button in GameButton.builtInControls {
            order.append(.object([
                "kind": .string("builtin"),
                "button": .string(button.rawValue)
            ]))
        }
        if case .array(let buttons)? = customization["customButtons"] {
            for button in buttons {
                guard case .object(let object) = button,
                      case .string(let id)? = object["id"],
                      UUID(uuidString: id) != nil
                else { return nil }
                order.append(.object(["kind": .string("custom"), "id": .string(id)]))
            }
        }
        return .object([
            "schemaVersion": .integer(1),
            "layerOrder": .array(order),
            "groups": .array([]),
            "grid": .object([
                "gridSize": .integer(16),
                "showsGrid": .bool(false),
                "snapToGrid": .bool(false),
                "snapToObjects": .bool(true),
                "snapTolerance": .integer(6)
            ]),
            "guides": .array([]),
            "tags": .array([])
        ])
    }

    private static func keyedControlIdentities(
        _ values: [ThumbleBridgeJSONValue]
    ) -> [String: ThumbleBridgeJSONValue]? {
        var result: [String: ThumbleBridgeJSONValue] = [:]
        for value in values {
            guard let key = controlIdentityKey(value), result[key] == nil else { return nil }
            result[key] = value
        }
        return result
    }

    private static func controlIdentityKey(_ value: ThumbleBridgeJSONValue) -> String? {
        guard case .object(let object) = value,
              case .string(let kind)? = object["kind"]
        else { return nil }
        let field: String
        switch kind {
        case "builtin": field = "button"
        case "custom": field = "id"
        case "system": field = "system"
        case "controlBarItem": field = "controlBarItem"
        default: return nil
        }
        guard case .string(let identifier)? = object[field], !identifier.isEmpty else { return nil }
        return "\(kind):\(identifier.lowercased())"
    }

    private static func keyedControlBarItemCustomizations(
        _ values: [ThumbleBridgeJSONValue]
    ) -> [String: ThumbleBridgeJSONValue]? {
        var result: [String: ThumbleBridgeJSONValue] = [:]
        for value in values {
            guard let key = controlBarItemCustomizationKey(value), result[key] == nil else { return nil }
            result[key] = value
        }
        return result
    }

    private static func controlBarItemCustomizationKey(_ value: ThumbleBridgeJSONValue) -> String? {
        guard case .object(let object) = value,
              case .string(let item)? = object["item"],
              GamepadControlBarItem(rawValue: item) != nil
        else { return nil }
        return item.lowercased()
    }

    private static func keyedPairs(
        _ values: [ThumbleBridgeJSONValue]
    ) -> [String: ThumbleBridgeJSONValue]? {
        guard values.count.isMultiple(of: 2) else { return nil }
        var result: [String: ThumbleBridgeJSONValue] = [:]
        var index = 0
        while index + 1 < values.count {
            guard case .string(let key) = values[index] else { return nil }
            let normalizedKey = key.lowercased()
            guard result[normalizedKey] == nil else { return nil }
            result[normalizedKey] = values[index + 1]
            index += 2
        }
        return result
    }

    private static func keyed(_ values: [ThumbleBridgeJSONValue]) -> [String: ThumbleBridgeJSONValue]? {
        var result: [String: ThumbleBridgeJSONValue] = [:]
        for value in values {
            guard let id = try? value.requiredString(forKey: "id") else { return nil }
            let key = id.lowercased()
            guard result[key] == nil else { return nil }
            result[key] = value
        }
        return result
    }

    private static func escapePointer(_ value: String) -> String {
        value.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
    }
}

public enum ThumbleBridgeJSONValue: Codable, Equatable, Sendable {
    case object([String: ThumbleBridgeJSONValue])
    case array([ThumbleBridgeJSONValue])
    case string(String)
    case integer(Int64)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int64.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) {
            guard value.isFinite else { throw ThumbleConfigurationBridgeError.nonFiniteNumber }
            self = .number(value)
        }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([ThumbleBridgeJSONValue].self) { self = .array(value) }
        else if let value = try? container.decode([String: ThumbleBridgeJSONValue].self) { self = .object(value) }
        else { throw ThumbleConfigurationBridgeError.invalidJSON }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value):
            guard value.isFinite else { throw ThumbleConfigurationBridgeError.nonFiniteNumber }
            try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    fileprivate mutating func setObjectValue(_ value: ThumbleBridgeJSONValue, forKey key: String) throws {
        guard case .object(var object) = self else { throw ThumbleConfigurationBridgeError.invalidProfile }
        object[key] = value
        self = .object(object)
    }

    fileprivate func requiredObjectValue(forKey key: String) throws -> ThumbleBridgeJSONValue {
        guard case .object(let object) = self, let value = object[key] else {
            throw ThumbleConfigurationBridgeError.invalidProfile
        }
        return value
    }

    fileprivate func requiredString(forKey key: String) throws -> String {
        guard case .string(let value) = try requiredObjectValue(forKey: key) else {
            throw ThumbleConfigurationBridgeError.invalidProfile
        }
        return value
    }
}

public enum ThumbleConfigurationBridgeError: String, LocalizedError, Sendable {
    case invalidJSON = "invalid_json"
    case unsupportedSchemaVersion = "unsupported_schema_version"
    case unsupportedOperation = "unsupported_operation"
    case unexpectedField = "unexpected_field"
    case invalidTimestamp = "invalid_timestamp"
    case nonFiniteNumber = "non_finite_number"
    case invalidProfileCount = "invalid_profile_count"
    case invalidProfile = "invalid_profile"
    case invalidProfileID = "invalid_profile_id"
    case duplicateProfileID = "duplicate_profile_id"
    case profileNotFound = "profile_not_found"
    case missingSelectedProfile = "missing_selected_profile"
    case invalidProfileName = "invalid_profile_name"
    case invalidProfileIndex = "invalid_profile_index"
    case replacementProfileRequired = "replacement_profile_required"
    case tooManyBindingMaps = "too_many_binding_maps"
    case unknownTheme = "unknown_theme"
    case invalidOrientation = "invalid_orientation"
    case identicalOrientations = "identical_orientations"
    case missingOrientation = "missing_orientation"
    case invalidElementID = "invalid_element_id"
    case invalidElementChanges = "invalid_element_changes"
    case invalidAlignment = "invalid_alignment"
    case invalidDistribution = "invalid_distribution"
    case invalidGeometry = "invalid_geometry"
    case invalidOutputEdit = "invalid_output_edit"
    case invalidCustomizationChanges = "invalid_customization_changes"
    case invalidDeviceFrame = "invalid_device_frame"
    case invalidControlBar = "invalid_control_bar"
    case invalidLayerDestination = "invalid_layer_destination"
    case invalidGroup = "invalid_group"
    case invalidStyle = "invalid_style"
    case invalidDestination = "invalid_destination"
    case staleDestination = "stale_destination"
    case unknownGenerationPreset = "unknown_generation_preset"
    case revisionMismatch = "revision_mismatch"
    case invalidGeneratedElementIDs = "invalid_generated_element_ids"
    case invalidGeneratedBinding = "invalid_generated_binding"

    public var errorDescription: String? {
        switch self {
        case .invalidJSON: "Request or model JSON is invalid"
        case .unsupportedSchemaVersion: "Bridge schema version is not supported"
        case .unsupportedOperation: "Operation is not allowlisted by this bridge"
        case .unexpectedField: "Request contains an unexpected field"
        case .invalidTimestamp: "Operation timestamp is invalid"
        case .nonFiniteNumber: "Non-finite numbers are not accepted"
        case .invalidProfileCount: "Configuration must contain 1 through 256 profiles"
        case .invalidProfile: "Configuration contains an invalid profile"
        case .invalidProfileID: "Profile ID must be a UUID"
        case .duplicateProfileID: "Profile ID already exists"
        case .profileNotFound: "Profile was not found"
        case .missingSelectedProfile: "Active or default profile does not exist"
        case .invalidProfileName: "Profile name is invalid"
        case .invalidProfileIndex: "Profile index is out of bounds"
        case .replacementProfileRequired: "Deleting the final profile requires a replacement profile UUID"
        case .tooManyBindingMaps: "Configuration has too many profile binding maps"
        case .unknownTheme: "Theme preset was not found"
        case .invalidOrientation: "Orientation must be landscape or portrait"
        case .identicalOrientations: "Source and destination orientations must differ"
        case .missingOrientation: "Source orientation has no saved layout"
        case .invalidElementID: "Element IDs must be unique installed controls"
        case .invalidElementChanges: "Element changes are empty, conflicting, unsupported for the kind, or outside safe bounds"
        case .invalidAlignment: "Alignment is not allowlisted"
        case .invalidDistribution: "Distribution is not allowlisted"
        case .invalidGeometry: "Geometry value is outside allowed bounds"
        case .invalidOutputEdit: "Output edit is invalid"
        case .invalidCustomizationChanges: "Customization changes are empty or invalid"
        case .invalidDeviceFrame: "Device frame is not in the built-in catalog"
        case .invalidControlBar: "Control bar items are invalid"
        case .invalidLayerDestination: "Layer destination is invalid"
        case .invalidGroup: "Layer group is missing, duplicated, or invalid"
        case .invalidStyle: "Style definition or reference is invalid"
        case .invalidDestination: "Profile destination is invalid"
        case .staleDestination: "Profile destination no longer matches the requested generated profile"
        case .unknownGenerationPreset: "Generation preset was not found"
        case .revisionMismatch: "Requested preset or template revision is not installed"
        case .invalidGeneratedElementIDs: "Generated element IDs do not match the preset contract"
        case .invalidGeneratedBinding: "Generated bindings are invalid"
        }
    }
}

private struct ThumbleBridgeCodingKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int? = nil
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
}

private extension KeyedDecodingContainer where Key == ThumbleBridgeCodingKey {
    func requireOnly(_ names: Set<String>) throws {
        guard Set(allKeys.map(\.stringValue)).isSubset(of: names) else {
            throw ThumbleConfigurationBridgeError.unexpectedField
        }
    }
}

private extension JSONEncoder {
    static var bridge: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

private extension JSONDecoder {
    static var bridge: JSONDecoder { JSONDecoder() }
}
