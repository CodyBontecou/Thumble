import Darwin
import Foundation

/// Typed, bounded client for the exact-sibling Rust CLI authority bridge.
/// It never opens Unix sockets or reads Rust state from Swift.
final class ThumbleCLIProfileBackend {
    static let schemaVersion = 8
    static let maximumRequestBytes = 18 * 1024 * 1024
    static let maximumResponseBytes = 18 * 1024 * 1024
    static let maximumProfileArtifactBytes = 8 * 1024 * 1024
    static let maximumGenerationSpecBytes = 256 * 1024
    static let maximumGenerationOutputBytes = 8 * 1024 * 1024
    static let maximumStderrBytes = 16 * 1024

    enum ProfileSelector: Encodable, Equatable {
        case active
        case `default`
        case id(UUID)
        case name(String)

        init(_ value: String?) {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let trimmed, !trimmed.isEmpty else {
                self = .active
                return
            }
            switch trimmed.lowercased() {
            case "active": self = .active
            case "default": self = .default
            default:
                if let id = UUID(uuidString: trimmed) {
                    self = .id(id)
                } else {
                    self = .name(trimmed)
                }
            }
        }

        private enum CodingKeys: String, CodingKey {
            case kind, profileID, name
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .active:
                try container.encode("active", forKey: .kind)
            case .default:
                try container.encode("default", forKey: .kind)
            case .id(let id):
                try container.encode("id", forKey: .kind)
                try container.encode(id, forKey: .profileID)
            case .name(let name):
                try container.encode("name", forKey: .kind)
                try container.encode(name, forKey: .name)
            }
        }
    }

    enum OrientationPreference: String, Codable, Equatable {
        case automatic
        case portrait
        case landscape
    }

    enum LayoutOrientation: String, Codable, Equatable {
        case portrait
        case landscape
    }

    enum ConfigurationVariant: String, Codable, Equatable {
        case primary
        case landscape
        case portrait
    }

    enum ControllerTemplate: String, Codable, CaseIterable, Equatable {
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
    }

    enum CustomizationLayoutMode: String, Codable, Equatable {
        case standard
        case southpaw
    }

    enum CustomizationControlScale: String, Codable, Equatable {
        case compact
        case standard
        case large
    }

    enum CustomizationColorScheme: String, Codable, Equatable {
        case system
        case light
        case dark
    }

    enum CustomizationAccentStyle: String, Codable, Equatable {
        case monochrome
        case blue
        case green
        case purple
        case pink
        case amber
    }

    enum CustomizationBackgroundScope: String, Codable, Equatable {
        case all
        case light
        case dark
    }

    enum CustomizationBackgroundEdit: Encodable, Equatable {
        case keep
        case clear
        case set(CustomizationBackgroundScope, AuthorityColor)

        private enum CodingKeys: String, CodingKey { case action, scope, color }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .keep:
                try container.encode("keep", forKey: .action)
            case .clear:
                try container.encode("clear", forKey: .action)
            case .set(let scope, let color):
                try container.encode("set", forKey: .action)
                try container.encode(scope, forKey: .scope)
                try container.encode(color, forKey: .color)
            }
        }
    }

    struct CustomizationChanges: Encodable, Equatable {
        var layoutMode: CustomizationLayoutMode? = nil
        var controlScale: CustomizationControlScale? = nil
        var colorScheme: CustomizationColorScheme? = nil
        var accentStyle: CustomizationAccentStyle? = nil
        var showsButtonLabels: Bool? = nil
        var backgroundEdit: CustomizationBackgroundEdit = .keep

        var isEmpty: Bool {
            layoutMode == nil && controlScale == nil && colorScheme == nil
                && accentStyle == nil && showsButtonLabels == nil && backgroundEdit == .keep
        }
    }

    enum LayoutRepairKind: String, Codable, Equatable {
        case showDefaultControls = "show-default-controls"
        case moveInsideSafeArea = "move-inside-safe-area"
        case minimumTouchTarget = "minimum-touch-target"
        case resolveOverlap = "resolve-overlap"
        case autoArrange = "auto-arrange"
        case separateExpandedHitTargets = "separate-expanded-hit-targets"
        case ergonomicAutoArrange = "ergonomic-auto-arrange"
    }

    enum LayoutRepairTarget: Encodable, Equatable {
        case all
        case repair(LayoutRepairKind)

        private enum CodingKeys: String, CodingKey { case kind, repair }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .all:
                try container.encode("all", forKey: .kind)
            case .repair(let repair):
                try container.encode("repair", forKey: .kind)
                try container.encode(repair, forKey: .repair)
            }
        }
    }

    enum LayoutRepairCanvas: Encodable, Equatable {
        case stored
        case frame(String)
        case size(width: Double, height: Double)

        private enum CodingKeys: String, CodingKey { case source, frameID, width, height }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .stored:
                try container.encode("stored", forKey: .source)
            case .frame(let frameID):
                try container.encode("frame", forKey: .source)
                try container.encode(frameID, forKey: .frameID)
            case .size(let width, let height):
                try container.encode("size", forKey: .source)
                try container.encode(width, forKey: .width)
                try container.encode(height, forKey: .height)
            }
        }
    }

    enum ControlBarMoveDirection: String, Codable, Equatable {
        case up
        case down
    }

    enum OutputMode: String, Codable, Equatable {
        case keyboard
        case controller
        case custom
    }

    enum SemanticModifier: String, Codable, Equatable {
        case command
        case shift
        case option
        case control
    }

    struct SemanticKeyStroke: Codable, Equatable {
        var key: String
        var modifiers: [SemanticModifier]
    }

    enum KeyboardEdit: Encodable, Equatable {
        case keep
        case clear
        case set([SemanticKeyStroke])

        private enum CodingKeys: String, CodingKey { case action, sequence }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .keep:
                try container.encode("keep", forKey: .action)
            case .clear:
                try container.encode("clear", forKey: .action)
            case .set(let sequence):
                try container.encode("set", forKey: .action)
                try container.encode(sequence, forKey: .sequence)
            }
        }
    }

    enum GamepadEdit: Encodable, Equatable {
        case keep
        case clear
        case set(VirtualGamepadButton)

        private enum CodingKeys: String, CodingKey { case action, button }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .keep:
                try container.encode("keep", forKey: .action)
            case .clear:
                try container.encode("clear", forKey: .action)
            case .set(let button):
                try container.encode("set", forKey: .action)
                try container.encode(button, forKey: .button)
            }
        }
    }

    struct AuthorityColor: Codable, Equatable {
        var red: Double
        var green: Double
        var blue: Double
        var alpha: Double

        init(red: Double, green: Double, blue: Double, alpha: Double) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }

        init(_ color: GamepadRGBAColor) {
            let normalized = color.normalized
            red = Double(normalized.red)
            green = Double(normalized.green)
            blue = Double(normalized.blue)
            alpha = Double(normalized.alpha)
        }
    }

    struct AuthorityCornerRadii: Codable, Equatable {
        var topLeading: Double
        var topTrailing: Double
        var bottomTrailing: Double
        var bottomLeading: Double
    }

    struct AuthorityGradientStop: Codable, Equatable {
        var offset: Double
        var color: AuthorityColor
    }

    enum AuthorityFill: Codable, Equatable {
        case solid(AuthorityColor)
        case gradient(GamepadGradientType, Double, [AuthorityGradientStop])
        case tile(
            GamepadTilePattern, AuthorityColor, AuthorityColor, Double, Double, Double,
            GamepadTileAlignment, Double
        )

        private enum CodingKeys: String, CodingKey {
            case kind, color, type, angleDegrees, stops, pattern, foregroundColor
            case backgroundColor, scale, spacingX, spacingY, alignment, opacity
        }

        init(_ fill: GamepadFillStyle) throws {
            switch fill.normalized {
            case .solid(let color):
                self = .solid(AuthorityColor(color))
            case .gradient(let gradient):
                self = .gradient(
                    gradient.type,
                    Double(gradient.angleDegrees),
                    gradient.stops.map {
                        AuthorityGradientStop(
                            offset: Double($0.offset),
                            color: AuthorityColor($0.color)
                        )
                    }
                )
            case .tile(let tile):
                self = .tile(
                    tile.pattern,
                    AuthorityColor(tile.foregroundColor),
                    AuthorityColor(tile.backgroundColor),
                    Double(tile.scale),
                    Double(tile.spacingX),
                    Double(tile.spacingY),
                    tile.alignment,
                    Double(tile.opacity)
                )
            case .image:
                throw BackendError.encodingFailed
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .kind) {
            case "solid":
                self = .solid(try container.decode(AuthorityColor.self, forKey: .color))
            case "gradient":
                self = .gradient(
                    try container.decode(GamepadGradientType.self, forKey: .type),
                    try container.decode(Double.self, forKey: .angleDegrees),
                    try container.decode([AuthorityGradientStop].self, forKey: .stops)
                )
            case "tile":
                self = .tile(
                    try container.decode(GamepadTilePattern.self, forKey: .pattern),
                    try container.decode(AuthorityColor.self, forKey: .foregroundColor),
                    try container.decode(AuthorityColor.self, forKey: .backgroundColor),
                    try container.decode(Double.self, forKey: .scale),
                    try container.decode(Double.self, forKey: .spacingX),
                    try container.decode(Double.self, forKey: .spacingY),
                    try container.decode(GamepadTileAlignment.self, forKey: .alignment),
                    try container.decode(Double.self, forKey: .opacity)
                )
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .kind,
                    in: container,
                    debugDescription: "Unsupported safe fill kind"
                )
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .solid(let color):
                try container.encode("solid", forKey: .kind)
                try container.encode(color, forKey: .color)
            case .gradient(let type, let angle, let stops):
                try container.encode("gradient", forKey: .kind)
                try container.encode(type, forKey: .type)
                try container.encode(angle, forKey: .angleDegrees)
                try container.encode(stops, forKey: .stops)
            case .tile(
                let pattern, let foreground, let background, let scale, let spacingX,
                let spacingY, let alignment, let opacity
            ):
                try container.encode("tile", forKey: .kind)
                try container.encode(pattern, forKey: .pattern)
                try container.encode(foreground, forKey: .foregroundColor)
                try container.encode(background, forKey: .backgroundColor)
                try container.encode(scale, forKey: .scale)
                try container.encode(spacingX, forKey: .spacingX)
                try container.encode(spacingY, forKey: .spacingY)
                try container.encode(alignment, forKey: .alignment)
                try container.encode(opacity, forKey: .opacity)
            }
        }
    }

    enum AuthorityMaterialPreset: String, Codable, Equatable {
        case softWhiteRaised = "soft-white-raised"
        case softWhiteInset = "soft-white-inset"
        case softWhitePlate = "soft-white-plate"
    }

    enum AuthorityIconSource: String, Codable, Equatable {
        case sfSymbol = "sf_symbol"
        case text
    }

    struct AuthorityIcon: Codable, Equatable {
        var source: AuthorityIconSource
        var value: String
    }

    struct AuthorityHaptic: Codable, Equatable {
        var style: GamepadHapticStyle?
        var pattern: GamepadHapticPattern?
        var intensity: Double?
        var sharpness: Double?
        var duration: Double?
    }

    struct AuthorityShadow: Codable, Equatable {
        var color: AuthorityColor
        var radius: Double
        var x: Double
        var y: Double
        var opacity: Double
    }

    struct AuthorityStyleAppearance: Codable, Equatable {
        var materialPreset: AuthorityMaterialPreset? = nil
        var fillColor: AuthorityColor? = nil
        var foregroundColor: AuthorityColor? = nil
        var strokeColor: AuthorityColor? = nil
        var strokeWidth: Double? = nil
        var glowColor: AuthorityColor? = nil
        var glowRadius: Double? = nil
        var innerShadowColor: AuthorityColor? = nil
        var innerShadowRadius: Double? = nil
        var innerShadowX: Double? = nil
        var innerShadowY: Double? = nil
        var highlightColor: AuthorityColor? = nil
        var highlightRadius: Double? = nil
        var highlightX: Double? = nil
        var highlightY: Double? = nil
        var highlightOpacity: Double? = nil
        var bevelHighlightColor: AuthorityColor? = nil
        var bevelShadowColor: AuthorityColor? = nil
        var bevelWidth: Double? = nil
        var opacity: Double? = nil
        var shadows: [AuthorityShadow]? = nil
        var pressedFillColor: AuthorityColor? = nil
        var pressedScale: Double? = nil
        var icon: AuthorityIcon? = nil
        var haptic: AuthorityHaptic? = nil

        var isEmpty: Bool {
            self == AuthorityStyleAppearance()
        }
    }

    final class ControlBarItemChanges: Encodable {
        var widthScale: Double? = nil
        var heightScale: Double? = nil
        var isHidden: Bool? = nil
        var shape: GamepadButtonShapeStyle? = nil
        var accentStyle: GamepadAccentStyle? = nil
        var cornerRadius: Double? = nil
        var cornerRadii: AuthorityCornerRadii? = nil
        var shadowStrength: Double? = nil
        var fill: AuthorityFill? = nil
        var clearFill = false
        var lightFill: AuthorityFill? = nil
        var clearLightFill = false
        var darkFill: AuthorityFill? = nil
        var clearDarkFill = false
        var fillOpacity: Double? = nil
        var lightFillOpacity: Double? = nil
        var darkFillOpacity: Double? = nil
        var styleID: String? = nil
        var clearStyle = false
        var appearance: AuthorityStyleAppearance? = nil
        var icon: AuthorityIcon? = nil
        var clearIcon = false
        var haptic: AuthorityHaptic? = nil
        var clearHaptic = false

        var isEmpty: Bool {
            widthScale == nil && heightScale == nil && isHidden == nil && shape == nil
                && accentStyle == nil && cornerRadius == nil && cornerRadii == nil
                && shadowStrength == nil && fill == nil && !clearFill && lightFill == nil
                && !clearLightFill && darkFill == nil && !clearDarkFill && fillOpacity == nil
                && lightFillOpacity == nil && darkFillOpacity == nil && styleID == nil
                && !clearStyle && appearance == nil && icon == nil && !clearIcon
                && haptic == nil && !clearHaptic
        }
    }

    enum LayerMoveDestination: Encodable, Equatable {
        case index(Int)
        case before(String)
        case after(String)

        private enum CodingKeys: String, CodingKey { case action, index, elementID }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .index(let index):
                try container.encode("index", forKey: .action)
                try container.encode(index, forKey: .index)
            case .before(let elementID):
                try container.encode("before", forKey: .action)
                try container.encode(elementID, forKey: .elementID)
            case .after(let elementID):
                try container.encode("after", forKey: .action)
                try container.encode(elementID, forKey: .elementID)
            }
        }
    }

    enum MoveDestination: Encodable, Equatable {
        case index(Int)
        case before(ProfileSelector)
        case after(ProfileSelector)

        private enum CodingKeys: String, CodingKey {
            case kind, index, profile
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .index(let index):
                try container.encode("index", forKey: .kind)
                try container.encode(index, forKey: .index)
            case .before(let selector):
                try container.encode("before", forKey: .kind)
                try container.encode(selector, forKey: .profile)
            case .after(let selector):
                try container.encode("after", forKey: .kind)
                try container.encode(selector, forKey: .profile)
            }
        }
    }

    enum Command: Encodable {
        case authorityStatus
        case list
        case export(ProfileSelector?)
        case `import`(artifactJSON: String, appendAsCopies: Bool, select: Bool, makeDefault: Bool)
        case select(ProfileSelector)
        case setDefault(ProfileSelector)
        case rename(ProfileSelector, String)
        case duplicate(ProfileSelector?, String?)
        case delete([ProfileSelector])
        case reset(ProfileSelector?)
        case move([ProfileSelector], MoveDestination)
        case generationGenerate(select: Bool, makeDefault: Bool)
        case generationPlanSpec(specJSON: String, requestedGameName: String?)
        case templateInstall(ControllerTemplate, name: String?, select: Bool, makeDefault: Bool)
        case customizationSet(ProfileSelector, ConfigurationVariant, [CustomizationChanges], frameID: String?)
        case customizationFix(ProfileSelector, ConfigurationVariant, LayoutRepairTarget, LayoutRepairCanvas, includeLocked: Bool)
        case styleList(ProfileSelector)
        case styleShow(ProfileSelector, styleID: String)
        case styleCreate(ProfileSelector, styleID: String, name: String, appearance: AuthorityStyleAppearance)
        case styleRename(ProfileSelector, styleID: String, name: String)
        case styleApply(ProfileSelector, ConfigurationVariant, styleID: String, elementID: String)
        case styleDetach(ProfileSelector, ConfigurationVariant, elementID: String)
        case styleDelete(ProfileSelector, styleID: String)
        case layerList(ProfileSelector, ConfigurationVariant)
        case layerMove(ProfileSelector, elementID: String, destination: LayerMoveDestination)
        case layerForward(ProfileSelector, elementID: String)
        case layerBackward(ProfileSelector, elementID: String)
        case layerFront(ProfileSelector, elementID: String)
        case layerBack(ProfileSelector, elementID: String)
        case groupList(ProfileSelector, ConfigurationVariant)
        case groupCreate(ProfileSelector, ConfigurationVariant, name: String, elementIDs: [String])
        case groupRename(ProfileSelector, ConfigurationVariant, group: String, name: String)
        case groupDuplicate(ProfileSelector, ConfigurationVariant, group: String, name: String?, offsetX: Double, offsetY: Double)
        case groupUngroup(ProfileSelector, ConfigurationVariant, group: String)
        case groupHide(ProfileSelector, ConfigurationVariant, group: String)
        case groupShow(ProfileSelector, ConfigurationVariant, group: String)
        case groupLock(ProfileSelector, ConfigurationVariant, group: String)
        case groupUnlock(ProfileSelector, ConfigurationVariant, group: String)
        case groupNudge(ProfileSelector, ConfigurationVariant, group: String, canvasFrameID: String, deltaX: Double, deltaY: Double)
        case groupForward(ProfileSelector, ConfigurationVariant, group: String)
        case groupBackward(ProfileSelector, ConfigurationVariant, group: String)
        case groupFront(ProfileSelector, ConfigurationVariant, group: String)
        case groupBack(ProfileSelector, ConfigurationVariant, group: String)
        case orientationGet(ProfileSelector)
        case orientationSet(ProfileSelector, OrientationPreference)
        case orientationCopy(ProfileSelector, LayoutOrientation, LayoutOrientation, Bool)
        case bindingList(ProfileSelector)
        case bindingDisplay(ProfileSelector)
        case bindingSet(ProfileSelector, GameButton, [SemanticKeyStroke])
        case bindingClear(ProfileSelector, GameButton)
        case bindingReset(ProfileSelector, GameButton)
        case bindingResetAll(ProfileSelector)
        case outputList(ProfileSelector)
        case outputModeGet(ProfileSelector)
        case outputMode(ProfileSelector, OutputMode)
        case outputSet(ProfileSelector, GameButton, KeyboardEdit, GamepadEdit)
        case outputReset(ProfileSelector, GameButton)
        case outputResetAll(ProfileSelector)
        case deviceGet(ProfileSelector, ConfigurationVariant)
        case deviceSet(ProfileSelector, ConfigurationVariant, String)
        case controlBarList(ProfileSelector, ConfigurationVariant)
        case controlBarSet(ProfileSelector, ConfigurationVariant, [GamepadControlBarItem])
        case controlBarAdd(ProfileSelector, ConfigurationVariant, GamepadControlBarItem)
        case controlBarRemove(ProfileSelector, ConfigurationVariant, GamepadControlBarItem)
        case controlBarMove(ProfileSelector, ConfigurationVariant, GamepadControlBarItem, ControlBarMoveDirection)
        case controlBarReset(ProfileSelector, ConfigurationVariant)
        case controlBarItemShow(ProfileSelector, ConfigurationVariant, GamepadControlBarItem)
        case controlBarItemSet(ProfileSelector, ConfigurationVariant, GamepadControlBarItem, ControlBarItemChanges)
        case controlBarItemReset(ProfileSelector, ConfigurationVariant, GamepadControlBarItem)

        private enum CodingKeys: String, CodingKey {
            case type, target, name, targets, destination, preference, source, automaticallyArrange
            case artifactJSON, appendAsCopies
            case specJSON, requestedGameName
            case template, select, makeDefault, styleID, elementID, appearance
            case button, sequence, mode, keyboardEdit, gamepadEdit
            case variant, frameID, items, item, direction, changes
            case profile, canvas, includeLocked
            case group, elementIDs, offsetX, offsetY, canvasFrameID, deltaX, deltaY
        }

        private func encodeGroupBase(
            _ type: String,
            _ target: ProfileSelector,
            _ variant: ConfigurationVariant,
            group: String? = nil,
            to container: inout KeyedEncodingContainer<CodingKeys>
        ) throws {
            try container.encode(type, forKey: .type)
            try container.encode(target, forKey: .target)
            try container.encode(variant, forKey: .variant)
            try container.encodeIfPresent(group, forKey: .group)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .authorityStatus:
                try container.encode("authority.status", forKey: .type)
            case .list:
                try container.encode("profile.list", forKey: .type)
            case .export(let target):
                try container.encode("profile.export", forKey: .type)
                try container.encodeIfPresent(target, forKey: .target)
            case .import(let artifactJSON, let appendAsCopies, let select, let makeDefault):
                try container.encode("profile.import", forKey: .type)
                try container.encode(artifactJSON, forKey: .artifactJSON)
                try container.encode(appendAsCopies, forKey: .appendAsCopies)
                try container.encode(select, forKey: .select)
                try container.encode(makeDefault, forKey: .makeDefault)
            case .select(let target):
                try container.encode("profile.select", forKey: .type)
                try container.encode(target, forKey: .target)
            case .setDefault(let target):
                try container.encode("profile.default", forKey: .type)
                try container.encode(target, forKey: .target)
            case .rename(let target, let name):
                try container.encode("profile.rename", forKey: .type)
                try container.encode(target, forKey: .target)
                try container.encode(name, forKey: .name)
            case .duplicate(let target, let name):
                try container.encode("profile.duplicate", forKey: .type)
                try container.encodeIfPresent(target, forKey: .target)
                try container.encodeIfPresent(name, forKey: .name)
            case .delete(let targets):
                try container.encode("profile.delete", forKey: .type)
                try container.encode(targets, forKey: .targets)
            case .reset(let target):
                try container.encode("profile.reset", forKey: .type)
                try container.encodeIfPresent(target, forKey: .target)
            case .move(let targets, let destination):
                try container.encode("profile.move", forKey: .type)
                try container.encode(targets, forKey: .targets)
                try container.encode(destination, forKey: .destination)
            case .generationGenerate(let select, let makeDefault):
                try container.encode("generation.generate", forKey: .type)
                try container.encode(select, forKey: .select)
                try container.encode(makeDefault, forKey: .makeDefault)
            case .generationPlanSpec(let specJSON, let requestedGameName):
                try container.encode("generation.plan-spec", forKey: .type)
                try container.encode(specJSON, forKey: .specJSON)
                try container.encodeIfPresent(requestedGameName, forKey: .requestedGameName)
            case .templateInstall(let template, let name, let select, let makeDefault):
                try container.encode("template.install", forKey: .type)
                try container.encode(template, forKey: .template)
                try container.encodeIfPresent(name, forKey: .name)
                try container.encode(select, forKey: .select)
                try container.encode(makeDefault, forKey: .makeDefault)
            case .customizationSet(let target, let variant, let changes, let frameID):
                try container.encode("customization.set", forKey: .type)
                try container.encode(target, forKey: .target)
                try container.encode(variant, forKey: .variant)
                if !changes.isEmpty {
                    try container.encode(changes, forKey: .changes)
                }
                try container.encodeIfPresent(frameID, forKey: .frameID)
            case .customizationFix(let profile, let variant, let target, let canvas, let includeLocked):
                try container.encode("customization.fix", forKey: .type)
                try container.encode(profile, forKey: .profile)
                try container.encode(variant, forKey: .variant)
                try container.encode(target, forKey: .target)
                try container.encode(canvas, forKey: .canvas)
                try container.encode(includeLocked, forKey: .includeLocked)
            case .styleList(let target):
                try container.encode("style.list", forKey: .type)
                try container.encode(target, forKey: .target)
            case .styleShow(let target, let styleID):
                try container.encode("style.show", forKey: .type)
                try container.encode(target, forKey: .target)
                try container.encode(styleID, forKey: .styleID)
            case .styleCreate(let target, let styleID, let name, let appearance):
                try container.encode("style.create", forKey: .type)
                try container.encode(target, forKey: .target)
                try container.encode(styleID, forKey: .styleID)
                try container.encode(name, forKey: .name)
                try container.encode(appearance, forKey: .appearance)
            case .styleRename(let target, let styleID, let name):
                try container.encode("style.rename", forKey: .type)
                try container.encode(target, forKey: .target)
                try container.encode(styleID, forKey: .styleID)
                try container.encode(name, forKey: .name)
            case .styleApply(let target, let variant, let styleID, let elementID):
                try container.encode("style.apply", forKey: .type)
                try container.encode(target, forKey: .target)
                try container.encode(variant, forKey: .variant)
                try container.encode(styleID, forKey: .styleID)
                try container.encode(elementID, forKey: .elementID)
            case .styleDetach(let target, let variant, let elementID):
                try container.encode("style.detach", forKey: .type)
                try container.encode(target, forKey: .target)
                try container.encode(variant, forKey: .variant)
                try container.encode(elementID, forKey: .elementID)
            case .styleDelete(let target, let styleID):
                try container.encode("style.delete", forKey: .type)
                try container.encode(target, forKey: .target)
                try container.encode(styleID, forKey: .styleID)
            case .layerList(let target, let variant):
                try container.encode("layer.list", forKey: .type)
                try container.encode(target, forKey: .target)
                try container.encode(variant, forKey: .variant)
            case .layerMove(let target, let elementID, let destination):
                try container.encode("layer.move", forKey: .type)
                try container.encode(target, forKey: .target)
                try container.encode(elementID, forKey: .elementID)
                try container.encode(destination, forKey: .destination)
            case .layerForward(let target, let elementID):
                try container.encode("layer.forward", forKey: .type)
                try container.encode(target, forKey: .target)
                try container.encode(elementID, forKey: .elementID)
            case .layerBackward(let target, let elementID):
                try container.encode("layer.backward", forKey: .type)
                try container.encode(target, forKey: .target)
                try container.encode(elementID, forKey: .elementID)
            case .layerFront(let target, let elementID):
                try container.encode("layer.front", forKey: .type)
                try container.encode(target, forKey: .target)
                try container.encode(elementID, forKey: .elementID)
            case .layerBack(let target, let elementID):
                try container.encode("layer.back", forKey: .type)
                try container.encode(target, forKey: .target)
                try container.encode(elementID, forKey: .elementID)
            case .groupList(let target, let variant):
                try encodeGroupBase("group.list", target, variant, to: &container)
            case .groupCreate(let target, let variant, let name, let elementIDs):
                try encodeGroupBase("group.create", target, variant, to: &container)
                try container.encode(name, forKey: .name)
                try container.encode(elementIDs, forKey: .elementIDs)
            case .groupRename(let target, let variant, let group, let name):
                try encodeGroupBase("group.rename", target, variant, group: group, to: &container)
                try container.encode(name, forKey: .name)
            case .groupDuplicate(let target, let variant, let group, let name, let offsetX, let offsetY):
                try encodeGroupBase("group.duplicate", target, variant, group: group, to: &container)
                try container.encodeIfPresent(name, forKey: .name)
                try container.encode(offsetX, forKey: .offsetX)
                try container.encode(offsetY, forKey: .offsetY)
            case .groupUngroup(let target, let variant, let group):
                try encodeGroupBase("group.ungroup", target, variant, group: group, to: &container)
            case .groupHide(let target, let variant, let group):
                try encodeGroupBase("group.hide", target, variant, group: group, to: &container)
            case .groupShow(let target, let variant, let group):
                try encodeGroupBase("group.show", target, variant, group: group, to: &container)
            case .groupLock(let target, let variant, let group):
                try encodeGroupBase("group.lock", target, variant, group: group, to: &container)
            case .groupUnlock(let target, let variant, let group):
                try encodeGroupBase("group.unlock", target, variant, group: group, to: &container)
            case .groupNudge(let target, let variant, let group, let canvasFrameID, let deltaX, let deltaY):
                try encodeGroupBase("group.nudge", target, variant, group: group, to: &container)
                try container.encode(canvasFrameID, forKey: .canvasFrameID)
                try container.encode(deltaX, forKey: .deltaX)
                try container.encode(deltaY, forKey: .deltaY)
            case .groupForward(let target, let variant, let group):
                try encodeGroupBase("group.forward", target, variant, group: group, to: &container)
            case .groupBackward(let target, let variant, let group):
                try encodeGroupBase("group.backward", target, variant, group: group, to: &container)
            case .groupFront(let target, let variant, let group):
                try encodeGroupBase("group.front", target, variant, group: group, to: &container)
            case .groupBack(let target, let variant, let group):
                try encodeGroupBase("group.back", target, variant, group: group, to: &container)
            case .orientationGet(let target):
                try container.encode("orientation.get", forKey: .type)
                try container.encode(target, forKey: .target)
            case .orientationSet(let target, let preference):
                try container.encode("orientation.set", forKey: .type)
                try container.encode(target, forKey: .target)
                try container.encode(preference, forKey: .preference)
            case .orientationCopy(let target, let source, let destination, let automaticallyArrange):
                try container.encode("orientation.copy", forKey: .type)
                try container.encode(target, forKey: .target)
                try container.encode(source, forKey: .source)
                try container.encode(destination, forKey: .destination)
                try container.encode(automaticallyArrange, forKey: .automaticallyArrange)
            case .bindingList(let target):
                try container.encode("binding.list", forKey: .type)
                try container.encode(target, forKey: .target)
            case .bindingDisplay(let target):
                try container.encode("binding.display", forKey: .type)
                try container.encode(target, forKey: .target)
            case .bindingSet(let target, let button, let sequence):
                try container.encode("binding.set", forKey: .type)
                try container.encode(target, forKey: .target)
                try container.encode(button, forKey: .button)
                try container.encode(sequence, forKey: .sequence)
            case .bindingClear(let target, let button):
                try container.encode("binding.clear", forKey: .type)
                try container.encode(target, forKey: .target)
                try container.encode(button, forKey: .button)
            case .bindingReset(let target, let button):
                try container.encode("binding.reset", forKey: .type)
                try container.encode(target, forKey: .target)
                try container.encode(button, forKey: .button)
            case .bindingResetAll(let target):
                try container.encode("binding.reset-all", forKey: .type)
                try container.encode(target, forKey: .target)
            case .outputList(let target):
                try container.encode("output.list", forKey: .type)
                try container.encode(target, forKey: .target)
            case .outputModeGet(let target):
                try container.encode("output.mode.get", forKey: .type)
                try container.encode(target, forKey: .target)
            case .outputMode(let target, let mode):
                try container.encode("output.mode", forKey: .type)
                try container.encode(target, forKey: .target)
                try container.encode(mode, forKey: .mode)
            case .outputSet(let target, let button, let keyboardEdit, let gamepadEdit):
                try container.encode("output.set", forKey: .type)
                try container.encode(target, forKey: .target)
                try container.encode(button, forKey: .button)
                try container.encode(keyboardEdit, forKey: .keyboardEdit)
                try container.encode(gamepadEdit, forKey: .gamepadEdit)
            case .outputReset(let target, let button):
                try container.encode("output.reset", forKey: .type)
                try container.encode(target, forKey: .target)
                try container.encode(button, forKey: .button)
            case .outputResetAll(let target):
                try container.encode("output.reset-all", forKey: .type)
                try container.encode(target, forKey: .target)
            case .deviceGet(let target, let variant):
                try container.encode("device.get", forKey: .type)
                try container.encode(target, forKey: .target)
                try container.encode(variant, forKey: .variant)
            case .deviceSet(let target, let variant, let frameID):
                try container.encode("device.set", forKey: .type)
                try container.encode(target, forKey: .target)
                try container.encode(variant, forKey: .variant)
                try container.encode(frameID, forKey: .frameID)
            case .controlBarList(let target, let variant):
                try container.encode("control-bar.list", forKey: .type)
                try container.encode(target, forKey: .target)
                try container.encode(variant, forKey: .variant)
            case .controlBarSet(let target, let variant, let items):
                try container.encode("control-bar.set", forKey: .type)
                try container.encode(target, forKey: .target)
                try container.encode(variant, forKey: .variant)
                try container.encode(items, forKey: .items)
            case .controlBarAdd(let target, let variant, let item):
                try container.encode("control-bar.add", forKey: .type)
                try container.encode(target, forKey: .target)
                try container.encode(variant, forKey: .variant)
                try container.encode(item, forKey: .item)
            case .controlBarRemove(let target, let variant, let item):
                try container.encode("control-bar.remove", forKey: .type)
                try container.encode(target, forKey: .target)
                try container.encode(variant, forKey: .variant)
                try container.encode(item, forKey: .item)
            case .controlBarMove(let target, let variant, let item, let direction):
                try container.encode("control-bar.move", forKey: .type)
                try container.encode(target, forKey: .target)
                try container.encode(variant, forKey: .variant)
                try container.encode(item, forKey: .item)
                try container.encode(direction, forKey: .direction)
            case .controlBarReset(let target, let variant):
                try container.encode("control-bar.reset", forKey: .type)
                try container.encode(target, forKey: .target)
                try container.encode(variant, forKey: .variant)
            case .controlBarItemShow(let target, let variant, let item):
                try container.encode("control-bar.item.show", forKey: .type)
                try container.encode(target, forKey: .target)
                try container.encode(variant, forKey: .variant)
                try container.encode(item, forKey: .item)
            case .controlBarItemSet(let target, let variant, let item, let changes):
                try container.encode("control-bar.item.set", forKey: .type)
                try container.encode(target, forKey: .target)
                try container.encode(variant, forKey: .variant)
                try container.encode(item, forKey: .item)
                try container.encode(changes, forKey: .changes)
            case .controlBarItemReset(let target, let variant, let item):
                try container.encode("control-bar.item.reset", forKey: .type)
                try container.encode(target, forKey: .target)
                try container.encode(variant, forKey: .variant)
                try container.encode(item, forKey: .item)
            }
        }
    }

    final class Request: Encodable {
        let schemaVersion: Int
        let invocationID: UUID
        let expectedConfigurationRevision: UInt64?
        let command: Command

        init(
            command: Command,
            invocationID: UUID,
            expectedConfigurationRevision: UInt64? = nil
        ) {
            schemaVersion = ThumbleCLIProfileBackend.schemaVersion
            self.invocationID = invocationID
            self.expectedConfigurationRevision = expectedConfigurationRevision
            self.command = command
        }
    }

    struct ProfileSummary: Codable, Equatable {
        var profileID: UUID
        var name: String
        var active: Bool
        var `default`: Bool
        var index: Int
    }

    struct Catalog: Codable, Equatable {
        var configurationRevision: UInt64
        var profiles: [ProfileSummary]
    }

    struct OrientationSummary: Codable, Equatable {
        var configurationRevision: UInt64
        var profileID: UUID
        var profileName: String
        var orientation: OrientationPreference
    }

    enum ProjectionKind: String, Codable, Equatable {
        case bindingList
        case bindingDisplay
        case outputList
        case outputMode
    }

    struct SemanticOutput: Codable, Equatable {
        var keyboard: [SemanticKeyStroke]
        var gamepadButtons: [VirtualGamepadButton]
    }

    struct BindingOutputRow: Codable, Equatable {
        var button: GameButton
        var output: SemanticOutput?
    }

    struct BindingDisplayEntry: Codable, Equatable {
        var elementID: UUID
        var part: KeypadElementInputPart
        var output: SemanticOutput
    }

    struct BindingDisplayGroup: Codable, Equatable {
        var orientation: LayoutOrientation?
        var entries: [BindingDisplayEntry]
    }

    struct BindingOutputProjection: Codable, Equatable {
        var kind: ProjectionKind
        var configurationRevision: UInt64
        var profileID: UUID
        var profileName: String
        var outputMode: OutputMode?
        var rows: [BindingOutputRow]?
        var displayGroups: [BindingDisplayGroup]?
    }

    struct ControlBarItemSummary: Codable, Equatable {
        var order: Int
        var item: GamepadControlBarItem
    }

    struct ControlBarProjection: Codable, Equatable {
        var configurationRevision: UInt64
        var profileID: UUID
        var profileName: String
        var variant: ConfigurationVariant
        var items: [ControlBarItemSummary]
    }

    struct SafeStyleShadow: Codable, Equatable {
        var color: AuthorityColor
        var radius: Double
        var x: Double
        var y: Double
    }

    struct SafeStyleState: Codable, Equatable {
        var fillColor: AuthorityColor?
        var foregroundColor: AuthorityColor?
        var strokeColor: AuthorityColor?
        var strokeWidth: Double?
        var shadows: [SafeStyleShadow]?
        var glowColor: AuthorityColor?
        var glowRadius: Double?
        var innerShadowColor: AuthorityColor?
        var innerShadowRadius: Double?
        var innerShadowX: Double?
        var innerShadowY: Double?
        var highlightColor: AuthorityColor?
        var highlightRadius: Double?
        var highlightX: Double?
        var highlightY: Double?
        var highlightOpacity: Double?
        var bevelHighlightColor: AuthorityColor?
        var bevelShadowColor: AuthorityColor?
        var bevelWidth: Double?
        var opacity: Double?
        var scale: Double?
        var blurRadius: Double?
    }

    struct SafeIcon: Codable, Equatable {
        var source: AuthorityIconSource
        var value: String
        var placement: GamepadControlIconPlacement
        var scale: Double
        var renderingMode: GamepadControlIconRenderingMode
        var tintColor: AuthorityColor?
    }

    struct SafeHaptic: Codable, Equatable {
        var style: GamepadHapticStyle
        var pattern: GamepadHapticPattern
        var intensity: Double
        var sharpness: Double
        var duration: Double
    }

    struct SafeStyleAppearance: Codable, Equatable {
        var normal: SafeStyleState
        var pressed: SafeStyleState?
        var active: SafeStyleState?
        var disabled: SafeStyleState?
        var icon: SafeIcon?
        var hapticStyle: GamepadHapticStyle?
        var haptic: SafeHaptic?
    }

    struct SafeLayer: Codable, Equatable {
        var targetID: String
        var stableID: String
        var label: String
        var kind: String
        var zIndex: Int
        var isHidden: Bool
        var isLocationLocked: Bool
        var styleID: String?
    }

    struct LayerProjection: Codable, Equatable {
        var configurationRevision: UInt64
        var profileID: UUID
        var profileName: String
        var variant: ConfigurationVariant
        var layers: [SafeLayer]
    }

    struct SafeGroup: Codable, Equatable {
        var id: String
        var name: String
        var childTargetIDs: [String]
        var childStableIDs: [String]
        var isLocked: Bool
        var isHidden: Bool
    }

    struct GroupProjection: Codable, Equatable {
        var configurationRevision: UInt64
        var profileID: UUID
        var profileName: String
        var variant: ConfigurationVariant
        var groups: [SafeGroup]
    }

    struct SafeStyleDefinition: Codable, Equatable {
        var id: String
        var name: String
        var appliesTo: [String]
        var appearance: SafeStyleAppearance
        var unsupportedContentOmitted: Bool
    }

    struct StyleProjection: Codable, Equatable {
        var configurationRevision: UInt64
        var profileID: UUID
        var profileName: String
        var styles: [SafeStyleDefinition]
    }

    struct SafeControlBarItemAppearance: Codable, Equatable {
        var item: String
        var targetID: String
        var index: Int
        var isHidden: Bool
        var widthScale: Double
        var heightScale: Double
        var shape: GamepadButtonShapeStyle?
        var accentStyle: GamepadAccentStyle?
        var cornerRadius: Double?
        var cornerRadii: AuthorityCornerRadii?
        var shadowStrength: Double
        var fill: AuthorityFill?
        var lightFill: AuthorityFill?
        var darkFill: AuthorityFill?
        var styleID: String?
        var inlineAppearance: SafeStyleAppearance?
        var icon: SafeIcon?
        var haptic: SafeHaptic?
        var unsupportedContentOmitted: Bool
    }

    struct DeviceProjection: Codable, Equatable {
        var configurationRevision: UInt64
        var profileID: UUID
        var profileName: String
        var variant: ConfigurationVariant
        var frameID: String?
        var customWidth: Int?
        var customHeight: Int?
        var frameOrientation: LayoutOrientation
    }

    struct ControlBarItemProjection: Codable, Equatable {
        var configurationRevision: UInt64
        var profileID: UUID
        var profileName: String
        var variant: ConfigurationVariant
        var order: Int
        var item: GamepadControlBarItem
        var appearance: SafeControlBarItemAppearance
    }

    struct ContentHash: Codable, Equatable {
        var algorithm: String
        var canonicalization: String
        var value: String
    }

    struct ProfileArtifactResponse: Codable, Equatable {
        var configurationRevision: UInt64
        var artifactJSON: String
        var contentHash: ContentHash
    }

    struct GenerationWarning: Codable, Equatable {
        var code: String
        var sourceOrdinal: Int
        var message: String
    }

    struct GenerationAssignedControl: Codable, Equatable {
        var sourceOrdinal: Int
        var button: String
        var elementID: String
        var kind: String
        var usedExplicitButton: Bool
    }

    struct GenerationDroppedControl: Codable, Equatable {
        var sourceOrdinal: Int
        var reason: String
    }

    struct GenerationLayoutIssue: Codable, Equatable {
        var code: String
        var severity: String
        var controlIDs: [String]
        var controlCount: Int
        var metric: Double?
        var suggestedRepairs: [String]
    }

    struct GenerationLayoutQuality: Codable, Equatable {
        var issueCount: Int
        var errorCount: Int
        var warningCount: Int
        var issues: [GenerationLayoutIssue]
        var omittedIssueCount: Int
    }

    final class GenerationPlan: Codable, Equatable {
        let configurationRevision: UInt64
        let schemaVersion: Int
        let catalogRevision: Int
        let plannerRevision: Int
        let descriptorDigest: String
        let generatedJSON: String
        let artifactJSON: String
        let contentHash: ContentHash
        let warnings: [GenerationWarning]
        let omittedWarningCount: Int
        let assignedControls: [GenerationAssignedControl]
        let droppedControls: [GenerationDroppedControl]
        let layoutQuality: GenerationLayoutQuality

        static func == (lhs: GenerationPlan, rhs: GenerationPlan) -> Bool {
            lhs.configurationRevision == rhs.configurationRevision
                && lhs.schemaVersion == rhs.schemaVersion
                && lhs.catalogRevision == rhs.catalogRevision
                && lhs.plannerRevision == rhs.plannerRevision
                && lhs.descriptorDigest == rhs.descriptorDigest
                && lhs.generatedJSON == rhs.generatedJSON
                && lhs.artifactJSON == rhs.artifactJSON
                && lhs.contentHash == rhs.contentHash
                && lhs.warnings == rhs.warnings
                && lhs.omittedWarningCount == rhs.omittedWarningCount
                && lhs.assignedControls == rhs.assignedControls
                && lhs.droppedControls == rhs.droppedControls
                && lhs.layoutQuality == rhs.layoutQuality
        }
    }

    struct Outcome: Codable, Equatable {
        var operation: String
        var profileNames: [String]
        var destination: String?
        var removedEveryProfile: Bool
        var changed: Bool
        var configurationRevision: UInt64
        var draftID: UUID
        var commitID: UUID
        var idempotentReplay: Bool
    }

    struct RemoteFailure: Codable, Equatable {
        var code: String
        var message: String
        var expectedRevision: UInt64?
        var actualRevision: UInt64?
        var draftID: UUID?
        var draftRevision: UInt64?
        var conflictPaths: [String]?
    }

    struct Response: Codable, Equatable {
        var schemaVersion: Int
        var ok: Bool
        var invocationID: UUID
        var authorityMode: String
        var authorityPresent: Bool?
        var catalog: Catalog?
        var artifact: ProfileArtifactResponse?
        var generationPlan: GenerationPlan?
        var orientation: OrientationSummary?
        var projection: BindingOutputProjection?
        var controlBar: ControlBarProjection?
        var controlBarItem: ControlBarItemProjection?
        var device: DeviceProjection?
        var styles: StyleProjection?
        var layers: LayerProjection?
        var groups: GroupProjection?
        var outcome: Outcome?
        var error: RemoteFailure?
    }

    enum BackendError: LocalizedError, Equatable {
        case unavailable
        case insecureExecutable
        case encodingFailed
        case requestTooLarge
        case generationSpecTooLarge
        case requestedGameNameTooLong
        case launchFailed
        case timeout
        case inputWriteFailed
        case responseTooLarge
        case malformedResponse
        case helperFailed
        case remote(RemoteFailure, UUID)

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "Exact-sibling thumble-cli-bridge is unavailable."
            case .insecureExecutable:
                return "thumble-cli-bridge failed ownership, symlink, or permission validation."
            case .encodingFailed:
                return "Could not encode the typed CLI profile request."
            case .requestTooLarge:
                return "Typed CLI profile request exceeds its size limit."
            case .generationSpecTooLarge:
                return "Generation spec JSON exceeds its 256 KiB UTF-8 size limit."
            case .requestedGameNameTooLong:
                return "Requested game name exceeds its 256-character limit."
            case .launchFailed:
                return "Could not launch the validated CLI profile bridge."
            case .timeout:
                return "CLI profile bridge timed out and its process group was terminated."
            case .inputWriteFailed:
                return "Could not write the bounded CLI profile request."
            case .responseTooLarge:
                return "CLI profile bridge response exceeds its size limit."
            case .malformedResponse:
                return "CLI profile bridge returned a malformed or unexpected response."
            case .helperFailed:
                return "CLI profile bridge exited without a typed error response."
            case .remote(let failure, let invocationID):
                var detail = "\(failure.message) [\(failure.code)] Invocation ID: \(invocationID.uuidString)"
                if let draftID = failure.draftID, let draftRevision = failure.draftRevision {
                    detail += " Resume draft \(draftID.uuidString) at revision \(draftRevision) with the same invocation ID."
                }
                return detail
            }
        }
    }

    private let executableURL: URL
    private let timeout: TimeInterval

    init(executableURL: URL? = nil, timeout: TimeInterval = 20) throws {
        if let executableURL {
            self.executableURL = executableURL
        } else {
            let current = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            self.executableURL = current.deletingLastPathComponent()
                .appendingPathComponent("thumble-cli-bridge", isDirectory: false)
        }
        self.timeout = timeout
        try Self.validateExecutable(at: self.executableURL)
    }

    @discardableResult
    func perform(
        _ command: Command,
        invocationID: UUID? = nil,
        expectedConfigurationRevision: UInt64? = nil
    ) throws -> Response {
        try Self.validateBeforeLaunch(command)
        let invocationID = invocationID ?? UUID()
        let request = Request(
            command: command,
            invocationID: invocationID,
            expectedConfigurationRevision: expectedConfigurationRevision
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var input = try? encoder.encode(request) else { throw BackendError.encodingFailed }
        guard input.count + 1 <= Self.maximumRequestBytes else { throw BackendError.requestTooLarge }
        input.append(0x0A)
        let result = try execute(input: input)
        let line = try Self.singleLine(result.stdout)
        try Self.validateStrictResponseJSON(line)
        guard let response = try? JSONDecoder().decode(Response.self, from: line),
              response.schemaVersion == Self.schemaVersion,
              response.invocationID == invocationID,
              Self.isBoundedTypedResponse(response)
        else { throw BackendError.malformedResponse }
        if !response.ok {
            if let failure = response.error {
                throw BackendError.remote(failure, response.invocationID)
            }
            throw BackendError.helperFailed
        }
        guard result.status == 0 else { throw BackendError.helperFailed }
        return response
    }

    private static func validateBeforeLaunch(_ command: Command) throws {
        guard case .generationPlanSpec(let specJSON, let requestedGameName) = command else {
            return
        }
        guard specJSON.utf8.count <= maximumGenerationSpecBytes else {
            throw BackendError.generationSpecTooLarge
        }
        guard requestedGameName.map({ $0.unicodeScalars.count <= 256 }) ?? true else {
            throw BackendError.requestedGameNameTooLong
        }
    }

    func requireLegacyPersistenceAllowed(operation: String) throws {
        let response = try perform(.authorityStatus)
        guard response.authorityPresent == false else {
            throw BackendError.remote(
                RemoteFailure(
                    code: "operation_not_migrated",
                    message: "\(operation) is not migrated to Rust-authoritative transactions and cannot use legacy persistence while Rust authority artifacts exist.",
                    expectedRevision: nil,
                    actualRevision: nil,
                    draftID: nil,
                    draftRevision: nil,
                    conflictPaths: nil
                ),
                response.invocationID
            )
        }
    }

    static func validateExecutable(at url: URL) throws {
        let path = url.path
        let parent = url.deletingLastPathComponent().path
        var parentStatus = stat()
        guard lstat(parent, &parentStatus) == 0 else { throw BackendError.unavailable }
        let parentType = parentStatus.st_mode & S_IFMT
        guard parentType == S_IFDIR,
              parentStatus.st_uid == geteuid(),
              parentStatus.st_mode & 0o022 == 0
        else { throw BackendError.insecureExecutable }

        var status = stat()
        guard lstat(path, &status) == 0 else {
            if errno == ENOENT { throw BackendError.unavailable }
            throw BackendError.insecureExecutable
        }
        let fileType = status.st_mode & S_IFMT
        guard fileType == S_IFREG,
              status.st_uid == geteuid(),
              status.st_mode & 0o022 == 0,
              status.st_mode & 0o111 != 0
        else { throw BackendError.insecureExecutable }
    }

    private struct ExecutionResult {
        var status: Int32
        var stdout: Data
    }

    private func execute(input: Data) throws -> ExecutionResult {
        // Revalidate immediately before every launch to close replacement races
        // between discovery and execution as far as Process permits.
        try Self.validateExecutable(at: executableURL)
        let process = Process()
        process.executableURL = executableURL
        process.arguments = []
        process.environment = Self.sanitizedHomeEnvironment()
        process.currentDirectoryURL = URL(fileURLWithPath: "/", isDirectory: true)
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let termination = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in termination.signal() }
        do {
            try process.run()
        } catch {
            throw BackendError.launchFailed
        }
        let processID = process.processIdentifier
        _ = Darwin.setpgid(processID, processID)

        let stdout = BoundedReadBox(maximum: Self.maximumResponseBytes)
        let stderr = BoundedReadBox(maximum: Self.maximumStderrBytes)
        let readGroup = DispatchGroup()
        readGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stdout.readToEnd(from: stdoutPipe.fileHandleForReading)
            readGroup.leave()
        }
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stderr.readToEnd(from: stderrPipe.fileHandleForReading)
            readGroup.leave()
        }

        let inputResult = LockedResultBox()
        let writeGroup = DispatchGroup()
        writeGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try stdinPipe.fileHandleForWriting.write(contentsOf: input)
                try stdinPipe.fileHandleForWriting.close()
                inputResult.store(success: true)
            } catch {
                try? stdinPipe.fileHandleForWriting.close()
                inputResult.store(success: false)
            }
            writeGroup.leave()
        }

        guard termination.wait(timeout: .now() + timeout) == .success else {
            Darwin.kill(-processID, SIGKILL)
            process.terminate()
            _ = termination.wait(timeout: .now() + 1)
            throw BackendError.timeout
        }
        guard writeGroup.wait(timeout: .now() + 1) == .success,
              inputResult.success == true
        else {
            Darwin.kill(-processID, SIGKILL)
            throw BackendError.inputWriteFailed
        }
        guard readGroup.wait(timeout: .now() + 1) == .success else {
            Darwin.kill(-processID, SIGKILL)
            throw BackendError.timeout
        }
        guard !stdout.overflowed else { throw BackendError.responseTooLarge }
        _ = stderr.data // Always drain, never surface potentially sensitive text.
        return ExecutionResult(status: process.terminationStatus, stdout: stdout.data)
    }

    private static func sanitizedHomeEnvironment() -> [String: String] {
        guard let home = ProcessInfo.processInfo.environment["HOME"], home.hasPrefix("/") else {
            return [:]
        }
        var status = stat()
        guard lstat(home, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == geteuid(),
              status.st_mode & 0o022 == 0
        else { return [:] }
        return ["HOME": home]
    }

    private static func singleLine(_ data: Data) throws -> Data {
        guard !data.isEmpty, data.last == 0x0A else { throw BackendError.malformedResponse }
        let line = data.dropLast()
        guard !line.isEmpty, !line.contains(0x0A), !line.contains(0x0D) else {
            throw BackendError.malformedResponse
        }
        return Data(line)
    }

    private static func isBoundedTypedResponse(_ response: Response) -> Bool {
        guard ["online", "offline", "status", "none"].contains(response.authorityMode) else {
            return false
        }
        let safeText: (String, Int) -> Bool = { value, maximum in
            !value.isEmpty && value.count <= maximum && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
        if let artifact = response.artifact {
            guard artifact.artifactJSON.utf8.count <= maximumProfileArtifactBytes,
                  boundedSHA256(artifact.contentHash)
            else { return false }
        }
        if let generationPlan = response.generationPlan {
            guard boundedGenerationPlan(generationPlan) else { return false }
        }
        if let catalog = response.catalog {
            guard catalog.profiles.count <= 256,
                  catalog.profiles.enumerated().allSatisfy({ offset, profile in
                      profile.index == offset && safeText(profile.name, 256)
                  })
            else { return false }
        }
        if let orientation = response.orientation {
            guard safeText(orientation.profileName, 256) else { return false }
        }
        if let projection = response.projection {
            guard safeText(projection.profileName, 256),
                  (projection.rows?.count ?? 0) <= 18,
                  (projection.displayGroups?.count ?? 0) <= 2,
                  projection.rows?.allSatisfy({ row in
                      boundedSemanticOutput(row.output, safeText: safeText)
                  }) ?? true,
                  projection.displayGroups?.allSatisfy({ group in
                      group.entries.count <= 768 && group.entries.allSatisfy({ entry in
                          boundedSemanticOutput(entry.output, safeText: safeText)
                      })
                  }) ?? true
            else { return false }
        }
        if let controlBar = response.controlBar {
            guard safeText(controlBar.profileName, 256),
                  controlBar.items.count <= 8,
                  controlBar.items.enumerated().allSatisfy({ offset, summary in
                      summary.order == offset + 1
                  }),
                  Set(controlBar.items.map { $0.item.rawValue }).count == controlBar.items.count
            else { return false }
        }
        if let device = response.device {
            let catalogFrame = device.frameID.map { frameID in
                GamepadEditorDeviceCatalog.frames.contains(where: {
                    $0.id == frameID && $0.orientation.rawValue == device.frameOrientation.rawValue
                }) && device.customWidth == nil && device.customHeight == nil
            } ?? false
            let customFrame = device.frameID == nil
                && device.customWidth.map({ (240 ... 1_800).contains($0) }) == true
                && device.customHeight.map({ (240 ... 1_800).contains($0) }) == true
            guard safeText(device.profileName, 256), catalogFrame != customFrame
            else { return false }
        }
        if let item = response.controlBarItem {
            guard safeText(item.profileName, 256),
                  (1 ... 8).contains(item.order),
                  item.appearance.index == item.order - 1,
                  item.appearance.item == item.item.rawValue,
                  safeText(item.appearance.targetID, 128),
                  boundedSafeControlBarAppearance(item.appearance, safeText: safeText)
            else { return false }
        }
        if let layers = response.layers {
            guard safeText(layers.profileName, 256), layers.layers.count <= 128,
                  layers.layers.allSatisfy({ layer in
                      safeText(layer.targetID, 128) && safeText(layer.stableID, 128)
                          && safeText(layer.label, 64) && safeText(layer.kind, 32)
                          && (layer.styleID.map({ safeText($0, 128) }) ?? true)
                  })
            else { return false }
        }
        if let groups = response.groups {
            guard safeText(groups.profileName, 256), groups.groups.count <= 64,
                  Set(groups.groups.map(\.id)).count == groups.groups.count,
                  groups.groups.allSatisfy({ group in
                      safeText(group.id, 36) && UUID(uuidString: group.id) != nil
                          && safeText(group.name, 64)
                          && group.childTargetIDs.count == group.childStableIDs.count
                          && group.childTargetIDs.count <= 64
                          && group.childTargetIDs.allSatisfy({ safeText($0, 128) })
                          && group.childStableIDs.allSatisfy({ safeText($0, 128) })
                  })
            else { return false }
        }
        if let styles = response.styles {
            guard safeText(styles.profileName, 256), styles.styles.count <= 64,
                  styles.styles.allSatisfy({ style in
                      safeText(style.id, 128) && safeText(style.name, 64)
                          && style.appliesTo.count <= 6
                          && style.appliesTo.allSatisfy({ safeText($0, 32) })
                          && boundedStyleAppearance(style.appearance, safeText: safeText)
                  })
            else { return false }
        }
        if let outcome = response.outcome {
            guard safeText(outcome.operation, 64),
                  outcome.profileNames.count <= 256,
                  outcome.profileNames.allSatisfy({ safeText($0, 256) }),
                  outcome.destination.map({ safeText($0, 512) }) ?? true
            else { return false }
        }
        if let failure = response.error {
            guard safeText(failure.code, 64), safeText(failure.message, 512),
                  (failure.conflictPaths?.count ?? 0) <= 128,
                  failure.conflictPaths?.allSatisfy({ safeText($0, 512) }) ?? true
            else { return false }
        }
        return true
    }

    private static func boundedGenerationPlan(_ plan: GenerationPlan) -> Bool {
        let safeText: (String, Int) -> Bool = { value, maximum in
            !value.isEmpty && value.utf8.count <= maximum
                && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
        guard plan.schemaVersion == 1,
              plan.catalogRevision == 1,
              plan.plannerRevision == 1,
              isLowercaseSHA256(plan.descriptorDigest),
              plan.generatedJSON.utf8.count <= maximumGenerationOutputBytes,
              plan.artifactJSON.utf8.count <= maximumGenerationOutputBytes,
              boundedSHA256(plan.contentHash),
              plan.warnings.count <= 128,
              plan.omittedWarningCount >= 0,
              plan.omittedWarningCount <= 128,
              plan.omittedWarningCount == 0 || plan.warnings.count == 128,
              plan.assignedControls.count <= 18,
              plan.droppedControls.count <= 128,
              plan.layoutQuality.issues.count <= 128
        else { return false }

        let validOrdinal: (Int) -> Bool = { (0 ..< 128).contains($0) }
        guard plan.warnings.allSatisfy({ warning in
            validOrdinal(warning.sourceOrdinal)
                && safeText(warning.code, 64)
                && safeText(warning.message, 256)
        }),
        plan.assignedControls.allSatisfy({ control in
            validOrdinal(control.sourceOrdinal)
                && safeText(control.button, 32)
                && safeText(control.elementID, 64)
                && safeText(control.kind, 32)
        }),
        plan.droppedControls.allSatisfy({ control in
            validOrdinal(control.sourceOrdinal) && safeText(control.reason, 128)
        })
        else { return false }

        let assignedOrdinals = plan.assignedControls.map(\.sourceOrdinal)
        let droppedOrdinals = plan.droppedControls.map(\.sourceOrdinal)
        let allOrdinals = assignedOrdinals + droppedOrdinals
        guard Set(allOrdinals).count == allOrdinals.count,
              Set(plan.assignedControls.map(\.elementID)).count == plan.assignedControls.count
        else { return false }

        let quality = plan.layoutQuality
        guard quality.issueCount >= 0,
              quality.errorCount >= 0,
              quality.warningCount >= 0,
              quality.omittedIssueCount >= 0,
              quality.issueCount == quality.issues.count + quality.omittedIssueCount,
              quality.errorCount + quality.warningCount <= quality.issueCount
        else { return false }

        let retainedErrors = quality.issues.filter { $0.severity == "error" }.count
        let retainedWarnings = quality.issues.filter { $0.severity == "warning" }.count
        guard retainedErrors <= quality.errorCount,
              retainedWarnings <= quality.warningCount,
              quality.omittedIssueCount > 0
                || (retainedErrors == quality.errorCount
                    && retainedWarnings == quality.warningCount),
              quality.issues.allSatisfy({ issue in
                  safeText(issue.code, 64)
                      && ["error", "warning", "info"].contains(issue.severity)
                      && issue.controlIDs.count <= 16
                      && Set(issue.controlIDs).count == issue.controlIDs.count
                      && issue.controlIDs.allSatisfy({ safeText($0, 128) })
                      && issue.controlCount >= issue.controlIDs.count
                      && issue.controlCount <= 18
                      && (issue.metric.map(\.isFinite) ?? true)
                      && issue.suggestedRepairs.count <= 16
                      && issue.suggestedRepairs.allSatisfy({ safeText($0, 128) })
              })
        else { return false }
        return true
    }

    private static func boundedSHA256(_ hash: ContentHash) -> Bool {
        hash.algorithm == "sha256"
            && hash.canonicalization == "rfc8785"
            && isLowercaseSHA256(hash.value)
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (0x30 ... 0x39).contains(byte) || (0x61 ... 0x66).contains(byte)
        }
    }

    private static func validateStrictResponseJSON(_ data: Data) throws {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BackendError.malformedResponse
        }
        try requireOnly(root, [
            "schemaVersion", "ok", "invocationID", "authorityMode", "authorityPresent",
            "catalog", "artifact", "generationPlan", "orientation", "projection", "controlBar",
            "controlBarItem", "device", "styles", "layers", "groups", "outcome", "error"
        ])
        if let artifact = root["artifact"] as? [String: Any] {
            try requireOnly(artifact, ["configurationRevision", "artifactJSON", "contentHash"])
            guard let contentHash = artifact["contentHash"] as? [String: Any] else {
                throw BackendError.malformedResponse
            }
            try requireOnly(contentHash, ["algorithm", "canonicalization", "value"])
        }
        if let plan = root["generationPlan"] as? [String: Any] {
            try requireOnly(plan, [
                "configurationRevision", "schemaVersion", "catalogRevision", "plannerRevision",
                "descriptorDigest", "generatedJSON", "artifactJSON", "contentHash", "warnings",
                "omittedWarningCount", "assignedControls", "droppedControls", "layoutQuality"
            ])
            guard let contentHash = plan["contentHash"] as? [String: Any],
                  let warnings = plan["warnings"] as? [[String: Any]], warnings.count <= 128,
                  let assigned = plan["assignedControls"] as? [[String: Any]], assigned.count <= 18,
                  let dropped = plan["droppedControls"] as? [[String: Any]], dropped.count <= 128,
                  let quality = plan["layoutQuality"] as? [String: Any]
            else { throw BackendError.malformedResponse }
            try requireOnly(contentHash, ["algorithm", "canonicalization", "value"])
            for warning in warnings {
                try requireOnly(warning, ["code", "sourceOrdinal", "message"])
            }
            for control in assigned {
                try requireOnly(control, [
                    "sourceOrdinal", "button", "elementID", "kind", "usedExplicitButton"
                ])
            }
            for control in dropped {
                try requireOnly(control, ["sourceOrdinal", "reason"])
            }
            try requireOnly(quality, [
                "issueCount", "errorCount", "warningCount", "issues", "omittedIssueCount"
            ])
            guard let issues = quality["issues"] as? [[String: Any]], issues.count <= 128 else {
                throw BackendError.malformedResponse
            }
            for issue in issues {
                try requireOnly(issue, [
                    "code", "severity", "controlIDs", "controlCount", "metric",
                    "suggestedRepairs"
                ])
            }
        }
        if let catalog = root["catalog"] as? [String: Any] {
            try requireOnly(catalog, ["configurationRevision", "profiles"])
            guard let profiles = catalog["profiles"] as? [[String: Any]], profiles.count <= 256 else {
                throw BackendError.malformedResponse
            }
            for profile in profiles {
                try requireOnly(profile, ["profileID", "name", "active", "default", "index"])
            }
        }
        if let orientation = root["orientation"] as? [String: Any] {
            try requireOnly(orientation, ["configurationRevision", "profileID", "profileName", "orientation"])
        }
        if let projection = root["projection"] as? [String: Any] {
            try requireOnly(projection, [
                "kind", "configurationRevision", "profileID", "profileName", "outputMode",
                "rows", "displayGroups"
            ])
            if let rows = projection["rows"] as? [[String: Any]] {
                guard rows.count <= 18 else { throw BackendError.malformedResponse }
                for row in rows {
                    try requireOnly(row, ["button", "output"])
                    if let output = row["output"] as? [String: Any] {
                        try validateStrictSemanticOutput(output)
                    }
                }
            }
            if let groups = projection["displayGroups"] as? [[String: Any]] {
                guard groups.count <= 2 else { throw BackendError.malformedResponse }
                for group in groups {
                    try requireOnly(group, ["orientation", "entries"])
                    guard let entries = group["entries"] as? [[String: Any]], entries.count <= 768 else {
                        throw BackendError.malformedResponse
                    }
                    for entry in entries {
                        try requireOnly(entry, ["elementID", "part", "output"])
                        guard let output = entry["output"] as? [String: Any] else {
                            throw BackendError.malformedResponse
                        }
                        try validateStrictSemanticOutput(output)
                    }
                }
            }
        }
        if let controlBar = root["controlBar"] as? [String: Any] {
            try requireOnly(controlBar, [
                "configurationRevision", "profileID", "profileName", "variant", "items"
            ])
            guard let items = controlBar["items"] as? [[String: Any]], items.count <= 8 else {
                throw BackendError.malformedResponse
            }
            for item in items {
                try requireOnly(item, ["order", "item"])
            }
        }
        if let device = root["device"] as? [String: Any] {
            try requireOnly(device, [
                "configurationRevision", "profileID", "profileName", "variant", "frameID",
                "customWidth", "customHeight", "frameOrientation"
            ])
        }
        if let item = root["controlBarItem"] as? [String: Any] {
            try requireOnly(item, [
                "configurationRevision", "profileID", "profileName", "variant", "order",
                "item", "appearance"
            ])
            guard let appearance = item["appearance"] as? [String: Any] else {
                throw BackendError.malformedResponse
            }
            try validateStrictControlBarAppearance(appearance)
        }
        if let layers = root["layers"] as? [String: Any] {
            try requireOnly(layers, ["configurationRevision", "profileID", "profileName", "variant", "layers"])
            guard let definitions = layers["layers"] as? [[String: Any]], definitions.count <= 128 else {
                throw BackendError.malformedResponse
            }
            for layer in definitions {
                try requireOnly(layer, [
                    "targetID", "stableID", "label", "kind", "zIndex", "isHidden",
                    "isLocationLocked", "styleID"
                ])
            }
        }
        if let groups = root["groups"] as? [String: Any] {
            try requireOnly(groups, [
                "configurationRevision", "profileID", "profileName", "variant", "groups"
            ])
            guard let definitions = groups["groups"] as? [[String: Any]], definitions.count <= 64 else {
                throw BackendError.malformedResponse
            }
            for definition in definitions {
                try requireOnly(definition, [
                    "id", "name", "childTargetIDs", "childStableIDs", "isLocked", "isHidden"
                ])
            }
        }
        if let styles = root["styles"] as? [String: Any] {
            try requireOnly(styles, ["configurationRevision", "profileID", "profileName", "styles"])
            guard let definitions = styles["styles"] as? [[String: Any]], definitions.count <= 64 else {
                throw BackendError.malformedResponse
            }
            for definition in definitions {
                try requireOnly(definition, [
                    "id", "name", "appliesTo", "appearance", "unsupportedContentOmitted"
                ])
                guard let appearance = definition["appearance"] as? [String: Any] else {
                    throw BackendError.malformedResponse
                }
                try validateStrictStyleAppearance(appearance)
            }
        }
        if let outcome = root["outcome"] as? [String: Any] {
            try requireOnly(outcome, [
                "operation", "profileNames", "destination", "removedEveryProfile", "changed",
                "configurationRevision", "draftID", "commitID", "idempotentReplay"
            ])
        }
        if let failure = root["error"] as? [String: Any] {
            try requireOnly(failure, [
                "code", "message", "expectedRevision", "actualRevision", "draftID",
                "draftRevision", "conflictPaths"
            ])
        }
        let encoded = String(decoding: data, as: UTF8.self).lowercased()
        guard !encoded.contains("authtoken"),
              !encoded.contains("realtimetoken"),
              !encoded.contains("statepath"),
              !encoded.contains("controlsocket")
        else { throw BackendError.malformedResponse }
    }

    private static func boundedSafeControlBarAppearance(
        _ appearance: SafeControlBarItemAppearance,
        safeText: (String, Int) -> Bool
    ) -> Bool {
        guard (0 ... 7).contains(appearance.index),
              (0.001 ... 12).contains(appearance.widthScale),
              (0.001 ... 12).contains(appearance.heightScale),
              (0 ... 2).contains(appearance.shadowStrength),
              appearance.cornerRadius.map({ (0 ... 1_024).contains($0) }) ?? true,
              appearance.cornerRadii.map(boundedCornerRadii) ?? true,
              appearance.fill.map(boundedFill) ?? true,
              appearance.lightFill.map(boundedFill) ?? true,
              appearance.darkFill.map(boundedFill) ?? true,
              appearance.styleID.map({ safeText($0, 64) }) ?? true,
              appearance.icon.map({ boundedIcon($0, safeText: safeText) }) ?? true,
              appearance.haptic.map(boundedHaptic) ?? true,
              appearance.inlineAppearance.map({ boundedStyleAppearance($0, safeText: safeText) }) ?? true
        else { return false }
        return true
    }

    private static func boundedColor(_ color: AuthorityColor) -> Bool {
        [color.red, color.green, color.blue, color.alpha].allSatisfy { (0 ... 1).contains($0) }
    }

    private static func boundedCornerRadii(_ radii: AuthorityCornerRadii) -> Bool {
        [radii.topLeading, radii.topTrailing, radii.bottomTrailing, radii.bottomLeading]
            .allSatisfy { (0 ... 1_024).contains($0) }
    }

    private static func boundedFill(_ fill: AuthorityFill) -> Bool {
        switch fill {
        case .solid(let color):
            return boundedColor(color)
        case .gradient(_, let angle, let stops):
            return (-36_000 ... 36_000).contains(angle)
                && (2 ... 8).contains(stops.count)
                && stops.allSatisfy { (0 ... 1).contains($0.offset) && boundedColor($0.color) }
        case .tile(_, let foreground, let background, let scale, let spacingX, let spacingY, _, let opacity):
            return boundedColor(foreground) && boundedColor(background)
                && (0.25 ... 4).contains(scale)
                && (0 ... 2).contains(spacingX) && (0 ... 2).contains(spacingY)
                && (0 ... 1).contains(opacity)
        }
    }

    private static func boundedIcon(_ icon: SafeIcon, safeText: (String, Int) -> Bool) -> Bool {
        safeText(icon.value, 80) && (0.2 ... 3).contains(icon.scale)
            && (icon.tintColor.map(boundedColor) ?? true)
    }

    private static func boundedHaptic(_ haptic: SafeHaptic) -> Bool {
        (0 ... 1).contains(haptic.intensity) && (0 ... 1).contains(haptic.sharpness)
            && (0.02 ... 0.30).contains(haptic.duration)
    }

    private static func boundedStyleAppearance(
        _ appearance: SafeStyleAppearance,
        safeText: (String, Int) -> Bool
    ) -> Bool {
        boundedStyleState(appearance.normal)
            && (appearance.pressed.map(boundedStyleState) ?? true)
            && (appearance.active.map(boundedStyleState) ?? true)
            && (appearance.disabled.map(boundedStyleState) ?? true)
            && (appearance.icon.map({ boundedIcon($0, safeText: safeText) }) ?? true)
            && (appearance.haptic.map(boundedHaptic) ?? true)
    }

    private static func boundedStyleState(_ state: SafeStyleState) -> Bool {
        let colors = [
            state.fillColor, state.foregroundColor, state.strokeColor, state.glowColor,
            state.innerShadowColor, state.highlightColor, state.bevelHighlightColor,
            state.bevelShadowColor
        ]
        return colors.compactMap { $0 }.allSatisfy(boundedColor)
            && (state.shadows?.count ?? 0) <= 8
            && (state.shadows ?? []).allSatisfy { shadow in
                boundedColor(shadow.color) && (0 ... 96).contains(shadow.radius)
                    && (-96 ... 96).contains(shadow.x) && (-96 ... 96).contains(shadow.y)
            }
    }

    private static func validateStrictControlBarAppearance(_ value: [String: Any]) throws {
        try requireOnly(value, [
            "item", "targetID", "index", "isHidden", "widthScale", "heightScale",
            "shape", "accentStyle", "cornerRadius", "cornerRadii", "shadowStrength",
            "fill", "lightFill", "darkFill", "styleID", "inlineAppearance", "icon",
            "haptic", "unsupportedContentOmitted"
        ])
        if let radii = value["cornerRadii"] as? [String: Any] {
            try requireOnly(radii, ["topLeading", "topTrailing", "bottomTrailing", "bottomLeading"])
        }
        for key in ["fill", "lightFill", "darkFill"] {
            if let fill = value[key] as? [String: Any] { try validateStrictFill(fill) }
        }
        if let icon = value["icon"] as? [String: Any] { try validateStrictIcon(icon) }
        if let haptic = value["haptic"] as? [String: Any] { try validateStrictHaptic(haptic) }
        if let appearance = value["inlineAppearance"] as? [String: Any] {
            try validateStrictStyleAppearance(appearance)
        }
    }

    private static func validateStrictFill(_ fill: [String: Any]) throws {
        guard let kind = fill["kind"] as? String else { throw BackendError.malformedResponse }
        switch kind {
        case "solid":
            try requireOnly(fill, ["kind", "color"])
            guard let color = fill["color"] as? [String: Any] else { throw BackendError.malformedResponse }
            try validateStrictColor(color)
        case "gradient":
            try requireOnly(fill, ["kind", "type", "angleDegrees", "stops"])
            guard let stops = fill["stops"] as? [[String: Any]], (2 ... 8).contains(stops.count) else {
                throw BackendError.malformedResponse
            }
            for stop in stops {
                try requireOnly(stop, ["offset", "color"])
                guard let color = stop["color"] as? [String: Any] else { throw BackendError.malformedResponse }
                try validateStrictColor(color)
            }
        case "tile":
            try requireOnly(fill, [
                "kind", "pattern", "foregroundColor", "backgroundColor", "scale",
                "spacingX", "spacingY", "alignment", "opacity"
            ])
            for key in ["foregroundColor", "backgroundColor"] {
                guard let color = fill[key] as? [String: Any] else { throw BackendError.malformedResponse }
                try validateStrictColor(color)
            }
        default:
            throw BackendError.malformedResponse
        }
    }

    private static func validateStrictStyleAppearance(_ appearance: [String: Any]) throws {
        try requireOnly(appearance, [
            "normal", "pressed", "active", "disabled", "icon", "hapticStyle", "haptic"
        ])
        for key in ["normal", "pressed", "active", "disabled"] {
            if let state = appearance[key] as? [String: Any] { try validateStrictStyleState(state) }
        }
        if let icon = appearance["icon"] as? [String: Any] { try validateStrictIcon(icon) }
        if let haptic = appearance["haptic"] as? [String: Any] { try validateStrictHaptic(haptic) }
    }

    private static func validateStrictStyleState(_ state: [String: Any]) throws {
        try requireOnly(state, [
            "fillColor", "foregroundColor", "strokeColor", "strokeWidth", "shadows",
            "glowColor", "glowRadius", "innerShadowColor", "innerShadowRadius",
            "innerShadowX", "innerShadowY", "highlightColor", "highlightRadius",
            "highlightX", "highlightY", "highlightOpacity", "bevelHighlightColor",
            "bevelShadowColor", "bevelWidth", "opacity", "scale", "blurRadius"
        ])
        for key in [
            "fillColor", "foregroundColor", "strokeColor", "glowColor", "innerShadowColor",
            "highlightColor", "bevelHighlightColor", "bevelShadowColor"
        ] {
            if let color = state[key] as? [String: Any] { try validateStrictColor(color) }
        }
        if let shadows = state["shadows"] as? [[String: Any]] {
            guard shadows.count <= 8 else { throw BackendError.malformedResponse }
            for shadow in shadows {
                try requireOnly(shadow, ["color", "radius", "x", "y"])
                guard let color = shadow["color"] as? [String: Any] else { throw BackendError.malformedResponse }
                try validateStrictColor(color)
            }
        }
    }

    private static func validateStrictColor(_ color: [String: Any]) throws {
        try requireOnly(color, ["red", "green", "blue", "alpha"])
    }

    private static func validateStrictIcon(_ icon: [String: Any]) throws {
        try requireOnly(icon, ["source", "value", "placement", "scale", "renderingMode", "tintColor"])
        if let color = icon["tintColor"] as? [String: Any] { try validateStrictColor(color) }
    }

    private static func validateStrictHaptic(_ haptic: [String: Any]) throws {
        try requireOnly(haptic, ["style", "pattern", "intensity", "sharpness", "duration"])
    }

    private static func boundedSemanticOutput(
        _ output: SemanticOutput?,
        safeText: (String, Int) -> Bool
    ) -> Bool {
        guard let output else { return true }
        return output.keyboard.count <= 32
            && output.keyboard.allSatisfy({ stroke in
                safeText(stroke.key, 64) && stroke.modifiers.count <= 4
            })
            && output.gamepadButtons.count <= 17
    }

    private static func validateStrictSemanticOutput(_ output: [String: Any]) throws {
        try requireOnly(output, ["keyboard", "gamepadButtons"])
        guard let keyboard = output["keyboard"] as? [[String: Any]], keyboard.count <= 32,
              let gamepad = output["gamepadButtons"] as? [String], gamepad.count <= 17
        else { throw BackendError.malformedResponse }
        for stroke in keyboard {
            try requireOnly(stroke, ["key", "modifiers"])
            guard let modifiers = stroke["modifiers"] as? [String], modifiers.count <= 4 else {
                throw BackendError.malformedResponse
            }
        }
    }

    private static func requireOnly(_ object: [String: Any], _ keys: Set<String>) throws {
        guard Set(object.keys).isSubset(of: keys) else { throw BackendError.malformedResponse }
    }
}

private final class BoundedReadBox: @unchecked Sendable {
    private let lock = NSLock()
    private let maximum: Int
    private var storage = Data()
    private(set) var overflowed = false

    init(maximum: Int) {
        self.maximum = maximum
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func readToEnd(from handle: FileHandle) {
        while true {
            let chunk: Data
            do {
                guard let next = try handle.read(upToCount: 16 * 1024), !next.isEmpty else { break }
                chunk = next
            } catch {
                break
            }
            lock.lock()
            if storage.count + chunk.count > maximum {
                overflowed = true
            }
            if storage.count < maximum {
                storage.append(chunk.prefix(maximum - storage.count))
            }
            lock.unlock()
        }
        try? handle.close()
    }
}

private final class LockedResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?

    var success: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func store(success: Bool) {
        lock.lock()
        stored = success
        lock.unlock()
    }
}
