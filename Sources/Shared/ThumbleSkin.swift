import Foundation

/// Semantic roles let a skin style controls without depending on profile-specific UUIDs or labels.
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

public enum ThumbleSkinOrientation: String, Codable, CaseIterable, Identifiable, Sendable {
    case portrait
    case landscape

    public var id: String { rawValue }
}

public enum ThumbleSkinColorScheme: String, Codable, CaseIterable, Identifiable, Sendable {
    case light
    case dark

    public var id: String { rawValue }
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

    fileprivate var isEmptyWithoutNormalization: Bool {
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

public struct ThumbleSkinRoleRule: Codable, Equatable, Sendable {
    public var role: GamepadVisualRole
    public var appearance: ThumbleSkinControlAppearance

    public init(role: GamepadVisualRole, appearance: ThumbleSkinControlAppearance) {
        self.role = role
        self.appearance = appearance
    }
}

public struct ThumbleSkinButtonRule: Codable, Equatable, Sendable {
    public var button: KeypadElementID
    public var appearance: ThumbleSkinControlAppearance

    public init(button: KeypadElementID, appearance: ThumbleSkinControlAppearance) {
        self.button = button
        self.appearance = appearance
    }
}

/// A complete appearance layer. Every property is optional so variants can override only what changes.
public struct ThumbleSkinAppearance: Codable, Equatable, Sendable {
    public var backgroundFillStyle: GamepadFillStyle?
    public var accentStyle: GamepadAccentStyle?
    public var showsButtonLabels: Bool?
    public var defaultControl: ThumbleSkinControlAppearance?
    public var roleRules: [ThumbleSkinRoleRule]
    public var buttonRules: [ThumbleSkinButtonRule]
    public var styleLibrary: GamepadStyleLibrary
    /// Optional for schema-1 decoding; normalized values always use a concrete array.
    public var artworkLayers: [ThumbleSkinArtworkLayer]?

    public init(
        backgroundFillStyle: GamepadFillStyle? = nil,
        accentStyle: GamepadAccentStyle? = nil,
        showsButtonLabels: Bool? = nil,
        defaultControl: ThumbleSkinControlAppearance? = nil,
        roleRules: [ThumbleSkinRoleRule] = [],
        buttonRules: [ThumbleSkinButtonRule] = [],
        styleLibrary: GamepadStyleLibrary = .empty,
        artworkLayers: [ThumbleSkinArtworkLayer] = []
    ) {
        self.backgroundFillStyle = backgroundFillStyle
        self.accentStyle = accentStyle
        self.showsButtonLabels = showsButtonLabels
        self.defaultControl = defaultControl
        self.roleRules = roleRules
        self.buttonRules = buttonRules
        self.styleLibrary = styleLibrary
        self.artworkLayers = artworkLayers
    }

    public static let empty = ThumbleSkinAppearance()

    public var normalized: ThumbleSkinAppearance {
        var copy = self
        copy.normalizeInPlace()
        return copy
    }

    mutating func normalizeInPlace() {
        normalizeSurfaceInPlace()
        normalizeDefaultControlInPlace()
        normalizeRoleRulesInPlace()
        normalizeButtonRulesInPlace()
        normalizeLibrariesAndArtworkInPlace()
    }

    private mutating func normalizeSurfaceInPlace() {
        backgroundFillStyle = backgroundFillStyle?.normalized
    }

    private mutating func normalizeDefaultControlInPlace() {
        guard var value = defaultControl else { return }
        value.normalizeInPlace()
        defaultControl = value.isEmptyWithoutNormalization ? nil : value
    }

    private mutating func normalizeRoleRulesInPlace() {
        var byRole: [GamepadVisualRole: ThumbleSkinControlAppearance] = [:]
        for rule in roleRules {
            var appearance = rule.appearance
            appearance.normalizeInPlace()
            if !appearance.isEmptyWithoutNormalization {
                byRole[rule.role] = appearance
            }
        }
        var normalizedRules: [ThumbleSkinRoleRule] = []
        normalizedRules.reserveCapacity(byRole.count)
        for role in GamepadVisualRole.allCases {
            if let appearance = byRole[role] {
                normalizedRules.append(ThumbleSkinRoleRule(role: role, appearance: appearance))
            }
        }
        roleRules = normalizedRules
    }

    private mutating func normalizeButtonRulesInPlace() {
        var byButton: [KeypadElementID: ThumbleSkinControlAppearance] = [:]
        for rule in buttonRules {
            var appearance = rule.appearance
            appearance.normalizeInPlace()
            if !appearance.isEmptyWithoutNormalization {
                byButton[rule.button] = appearance
            }
        }
        var normalizedRules: [ThumbleSkinButtonRule] = []
        normalizedRules.reserveCapacity(byButton.count)
        for button in byButton.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            if let appearance = byButton[button] {
                normalizedRules.append(ThumbleSkinButtonRule(button: button, appearance: appearance))
            }
        }
        buttonRules = normalizedRules
    }

    private mutating func normalizeLibrariesAndArtworkInPlace() {
        styleLibrary = styleLibrary.normalized
        artworkLayers = normalizedArtworkLayers(artworkLayers ?? [])
    }

    private func normalizedArtworkLayers(_ layers: [ThumbleSkinArtworkLayer]) -> [ThumbleSkinArtworkLayer] {
        var byID: [String: ThumbleSkinArtworkLayer] = [:]
        for layer in layers {
            if let normalized = layer.normalized { byID[normalized.id] = normalized }
        }
        return byID.values.sorted {
            if $0.plane != $1.plane { return $0.plane.rawValue < $1.plane.rawValue }
            if $0.zIndex != $1.zIndex { return $0.zIndex < $1.zIndex }
            return $0.id < $1.id
        }
    }

    public func controlAppearance(
        for button: KeypadElementID,
        controlKind: GamepadCustomControlKind,
        visualRole: GamepadVisualRole? = nil
    ) -> ThumbleSkinControlAppearance {
        ControlAppearanceResolutionWorkspace(
            appearance: self,
            button: button,
            controlKind: controlKind,
            visualRole: visualRole
        ).resolve()
    }

    public func controlAppearance(for role: GamepadVisualRole) -> ThumbleSkinControlAppearance {
        ControlAppearanceResolutionWorkspace(
            appearance: self,
            visualRole: role
        ).resolve()
    }

    private final class ControlAppearanceResolutionWorkspace {
        private var appearance: ThumbleSkinAppearance
        private let button: KeypadElementID?
        private let controlKind: GamepadCustomControlKind?
        private let requestedRole: GamepadVisualRole?
        private var result = ThumbleSkinControlAppearance.empty

        init(
            appearance: ThumbleSkinAppearance,
            button: KeypadElementID,
            controlKind: GamepadCustomControlKind,
            visualRole: GamepadVisualRole?
        ) {
            self.appearance = appearance
            self.button = button
            self.controlKind = controlKind
            self.requestedRole = visualRole
        }

        init(
            appearance: ThumbleSkinAppearance,
            visualRole: GamepadVisualRole
        ) {
            self.appearance = appearance
            self.button = nil
            self.controlKind = nil
            self.requestedRole = visualRole
        }

        func resolve() -> ThumbleSkinControlAppearance {
            normalizeAppearance()
            selectDefaultAppearance()
            mergeRoleAppearance()
            mergeButtonAppearance()
            return result
        }

        private func normalizeAppearance() {
            appearance.normalizeInPlace()
        }

        private func selectDefaultAppearance() {
            result = appearance.defaultControl ?? .empty
        }

        private func mergeRoleAppearance() {
            guard let role = resolvedRole,
                  let roleAppearance = appearance.roleRules.last(where: { $0.role == role })?.appearance
            else { return }
            result = roleAppearance.merged(over: result)
        }

        private func mergeButtonAppearance() {
            guard let button,
                  let buttonAppearance = appearance.buttonRules.last(where: { $0.button == button })?.appearance
            else { return }
            result = buttonAppearance.merged(over: result)
        }

        private var resolvedRole: GamepadVisualRole? {
            if let requestedRole { return requestedRole }
            guard let button, let controlKind else { return nil }
            return GamepadVisualRole.inferred(for: button, controlKind: controlKind)
        }
    }

    /// Returns this appearance layered over a less-specific appearance.
    public func merged(over base: ThumbleSkinAppearance) -> ThumbleSkinAppearance {
        MergeWorkspace(base: base, overlay: self).resolve()
    }

    private final class MergeWorkspace {
        private var base: ThumbleSkinAppearance
        private var overlay: ThumbleSkinAppearance
        private var result: ThumbleSkinAppearance

        init(base: ThumbleSkinAppearance, overlay: ThumbleSkinAppearance) {
            self.base = base
            self.overlay = overlay
            self.result = base
        }

        func resolve() -> ThumbleSkinAppearance {
            base.normalizeInPlace()
            overlay.normalizeInPlace()
            result = base
            mergeSurface()
            mergeStyles()
            mergeRoleRules()
            mergeButtonRules()
            mergeDefaultControl()
            mergeArtwork()
            result.normalizeInPlace()
            return result
        }

        private func mergeSurface() {
            if let value = overlay.backgroundFillStyle { result.backgroundFillStyle = value }
            if let value = overlay.accentStyle { result.accentStyle = value }
            if let value = overlay.showsButtonLabels { result.showsButtonLabels = value }
        }

        private func mergeStyles() {
            var styles = base.styleLibrary.styles
            for style in overlay.styleLibrary.styles {
                if let index = styles.firstIndex(where: { $0.id == style.id }) {
                    styles[index] = style
                } else {
                    styles.append(style)
                }
            }
            result.styleLibrary = GamepadStyleLibrary(styles: styles)
        }

        private func mergeRoleRules() {
            var rules = base.roleRules
            for rule in overlay.roleRules {
                if let index = rules.firstIndex(where: { $0.role == rule.role }) {
                    rules[index].appearance = rule.appearance.merged(over: rules[index].appearance)
                } else {
                    rules.append(rule)
                }
            }
            result.roleRules = rules
        }

        private func mergeButtonRules() {
            var rules = base.buttonRules
            for rule in overlay.buttonRules {
                if let index = rules.firstIndex(where: { $0.button == rule.button }) {
                    rules[index].appearance = rule.appearance.merged(over: rules[index].appearance)
                } else {
                    rules.append(rule)
                }
            }
            result.buttonRules = rules
        }

        private func mergeDefaultControl() {
            if let overlayDefault = overlay.defaultControl {
                result.defaultControl = overlayDefault.merged(over: base.defaultControl ?? .empty)
            } else {
                result.defaultControl = base.defaultControl
            }
        }

        private func mergeArtwork() {
            var artworkByID: [String: ThumbleSkinArtworkLayer] = [:]
            for layer in base.artworkLayers ?? [] { artworkByID[layer.id] = layer }
            for layer in overlay.artworkLayers ?? [] { artworkByID[layer.id] = layer }
            result.artworkLayers = artworkByID.values
                .filter { !$0.isHidden }
                .sorted {
                    if $0.plane != $1.plane { return $0.plane.rawValue < $1.plane.rawValue }
                    if $0.zIndex != $1.zIndex { return $0.zIndex < $1.zIndex }
                    return $0.id < $1.id
                }
        }
    }
}

public struct ThumbleSkinVariant: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var orientation: ThumbleSkinOrientation?
    public var colorScheme: ThumbleSkinColorScheme?
    public var appearance: ThumbleSkinAppearance

    public init(
        id: String,
        orientation: ThumbleSkinOrientation? = nil,
        colorScheme: ThumbleSkinColorScheme? = nil,
        appearance: ThumbleSkinAppearance
    ) {
        self.id = id
        self.orientation = orientation
        self.colorScheme = colorScheme
        self.appearance = appearance
    }

    public var specificity: Int {
        (orientation == nil ? 0 : 1) + (colorScheme == nil ? 0 : 1)
    }

    public func matches(
        orientation requestedOrientation: ThumbleSkinOrientation,
        colorScheme requestedColorScheme: ThumbleSkinColorScheme
    ) -> Bool {
        (orientation == nil || orientation == requestedOrientation)
            && (colorScheme == nil || colorScheme == requestedColorScheme)
    }

    public var normalized: ThumbleSkinVariant? {
        let normalizedID = GamepadStyleToken.normalizedIdentifier(id)
        guard !normalizedID.isEmpty else { return nil }
        return ThumbleSkinVariant(
            id: normalizedID,
            orientation: orientation,
            colorScheme: colorScheme,
            appearance: appearance.normalized
        )
    }
}

public struct ThumbleSkin: Codable, Equatable, Sendable {
    public var base: ThumbleSkinAppearance
    public var variants: [ThumbleSkinVariant]

    public init(base: ThumbleSkinAppearance, variants: [ThumbleSkinVariant] = []) {
        self.base = base
        self.variants = variants
    }

    public var normalized: ThumbleSkin {
        var seen = Set<String>()
        let variants = variants.compactMap { variant -> ThumbleSkinVariant? in
            guard let normalized = variant.normalized, seen.insert(normalized.id).inserted else { return nil }
            return normalized
        }
        return ThumbleSkin(base: base.normalized, variants: variants)
    }

    private func matchingVariants(orientation: ThumbleSkinOrientation, colorScheme: ThumbleSkinColorScheme) -> [ThumbleSkinVariant] {
        variants.filter { $0.matches(orientation: orientation, colorScheme: colorScheme) }
            .sorted { lhs, rhs in
                if lhs.specificity == rhs.specificity { return lhs.id < rhs.id }
                return lhs.specificity < rhs.specificity
            }
    }

    /// Exact definition provenance for the same style-token cascade used by native paint.
    public func styleSources(orientation: ThumbleSkinOrientation, colorScheme: ThumbleSkinColorScheme) -> [String: String] {
        let value = normalized
        var sources = Dictionary(uniqueKeysWithValues: value.base.styleLibrary.styles.map { ($0.id, "base") })
        for variant in value.matchingVariants(orientation: orientation, colorScheme: colorScheme) {
            for style in variant.appearance.styleLibrary.styles { sources[style.id] = "variant." + variant.id }
        }
        return sources
    }

    public func appearance(
        orientation: ThumbleSkinOrientation,
        colorScheme: ThumbleSkinColorScheme
    ) -> ThumbleSkinAppearance {
        let value = normalized
        return value.matchingVariants(orientation: orientation, colorScheme: colorScheme)
            .reduce(value.base) { appearance, variant in variant.appearance.merged(over: appearance) }
            .normalized
    }
}
