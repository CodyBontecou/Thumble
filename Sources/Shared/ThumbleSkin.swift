import Foundation

public enum ThumbleSkinOrientation: String, Codable, CaseIterable, Identifiable, Sendable {
    case portrait
    case landscape

    public var id: String { rawValue }
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

/// Exact held-trigger state used by appearance layers. It never changes output bindings.
public struct ThumbleSkinVariant: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var orientation: ThumbleSkinOrientation?
    public var colorScheme: ThumbleSkinColorScheme?
    public var appearance: ThumbleSkinAppearance
    public var actionSet: ThumbleActionSet?

    public init(
        id: String,
        orientation: ThumbleSkinOrientation? = nil,
        colorScheme: ThumbleSkinColorScheme? = nil,
        appearance: ThumbleSkinAppearance,
        actionSet: ThumbleActionSet? = nil
    ) {
        self.actionSet = actionSet
        self.id = id
        self.orientation = orientation
        self.colorScheme = colorScheme
        self.appearance = appearance
    }

    // Conditional banks overlay ordinary orientation/scheme variants (whose maximum weight is 2).
    public var specificity: Int {
        (orientation == nil ? 0 : 1) + (colorScheme == nil ? 0 : 1) + (actionSet == nil ? 0 : 4)
    }

    public func matches(
        orientation requestedOrientation: ThumbleSkinOrientation,
        colorScheme requestedColorScheme: ThumbleSkinColorScheme,
        actionSet requestedActionSet: ThumbleActionSet = .base
    ) -> Bool {
        (orientation == nil || orientation == requestedOrientation)
            && (colorScheme == nil || colorScheme == requestedColorScheme)
            && (actionSet == nil || actionSet == requestedActionSet)
    }

    public var normalized: ThumbleSkinVariant? {
        let normalizedID = GamepadStyleToken.normalizedIdentifier(id)
        guard !normalizedID.isEmpty else { return nil }
        return ThumbleSkinVariant(
            id: normalizedID,
            orientation: orientation,
            colorScheme: colorScheme,
            appearance: appearance.normalized,
            actionSet: actionSet
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

    private func matchingVariants(orientation: ThumbleSkinOrientation, colorScheme: ThumbleSkinColorScheme, actionSet: ThumbleActionSet = .base) -> [ThumbleSkinVariant] {
        variants.filter { $0.matches(orientation: orientation, colorScheme: colorScheme, actionSet: actionSet) }
            .sorted { lhs, rhs in
                if lhs.specificity == rhs.specificity { return lhs.id < rhs.id }
                return lhs.specificity < rhs.specificity
            }
    }

    /// Exact definition provenance for the same style-token cascade used by native paint.
    public func styleSources(orientation: ThumbleSkinOrientation, colorScheme: ThumbleSkinColorScheme, actionSet: ThumbleActionSet = .base) -> [String: String] {
        let value = normalized
        var sources = Dictionary(uniqueKeysWithValues: value.base.styleLibrary.styles.map { ($0.id, "base") })
        for variant in value.matchingVariants(orientation: orientation, colorScheme: colorScheme, actionSet: actionSet) {
            for style in variant.appearance.styleLibrary.styles { sources[style.id] = "variant." + variant.id }
        }
        return sources
    }

    public func appearance(
        orientation: ThumbleSkinOrientation,
        colorScheme: ThumbleSkinColorScheme,
        actionSet: ThumbleActionSet = .base
    ) -> ThumbleSkinAppearance {
        let value = normalized
        return value.matchingVariants(orientation: orientation, colorScheme: colorScheme, actionSet: actionSet)
            .reduce(value.base) { appearance, variant in variant.appearance.merged(over: appearance) }
            .normalized
    }
}
