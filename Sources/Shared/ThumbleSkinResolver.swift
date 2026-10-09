import Foundation
import SwiftUI

public struct ThumbleSkinReference: Codable, Equatable, Hashable, Sendable {
    public var identifier: String
    public var version: String

    public init(identifier: String, version: String) {
        self.identifier = identifier.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        self.version = version.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isValid: Bool {
        ThumbleSkinPackageValidator.isValidReverseDNSIdentifier(identifier)
            && ThumbleSemanticVersion(version) != nil
    }
}

public struct ThumbleSkinApplicationOptions: Equatable, Sendable {
    /// Existing per-control appearance remains the final cascade layer when enabled.
    public var preservesLocalControlAppearance: Bool
    /// Existing non-default background and label choices remain the final cascade layer when enabled.
    public var preservesLocalKeypadAppearance: Bool

    public init(
        preservesLocalControlAppearance: Bool = true,
        preservesLocalKeypadAppearance: Bool = true
    ) {
        self.preservesLocalControlAppearance = preservesLocalControlAppearance
        self.preservesLocalKeypadAppearance = preservesLocalKeypadAppearance
    }

    public static let preservingUserOverrides = ThumbleSkinApplicationOptions()
    public static let replacingAppearance = ThumbleSkinApplicationOptions(
        preservesLocalControlAppearance: false,
        preservesLocalKeypadAppearance: false
    )
}

public enum ThumbleSkinResolver {
    /// Produces a render-ready customization without mutating the saved profile.
    public static func applying(
        package: ThumbleSkinPackage,
        to customization: GamepadCustomization,
        orientation: ThumbleSkinOrientation,
        colorScheme: ThumbleSkinColorScheme,
        options: ThumbleSkinApplicationOptions = .preservingUserOverrides,
        overrideBaseline: GamepadCustomization? = nil
    ) -> GamepadCustomization {
        guard let skin = package.skin else { return customization.normalized }
        return SkinApplicationWorkspace(
            package: package,
            skin: skin,
            customization: customization,
            orientation: orientation,
            colorScheme: colorScheme,
            options: options,
            overrideBaseline: overrideBaseline
        ).resolve()
    }

    private final class SkinApplicationWorkspace {
        private let package: ThumbleSkinPackage
        private let skin: ThumbleSkin
        private let orientation: ThumbleSkinOrientation
        private let colorScheme: ThumbleSkinColorScheme
        private let options: ThumbleSkinApplicationOptions
        private var original: GamepadCustomization
        private var baseline: GamepadCustomization?
        private var result: GamepadCustomization
        private var appearance: ThumbleSkinAppearance?
        private var compatibility: ThumbleSkinCompatibilityEvaluation?

        init(
            package: ThumbleSkinPackage,
            skin: ThumbleSkin,
            customization: GamepadCustomization,
            orientation: ThumbleSkinOrientation,
            colorScheme: ThumbleSkinColorScheme,
            options: ThumbleSkinApplicationOptions,
            overrideBaseline: GamepadCustomization?
        ) {
            self.package = package
            self.skin = skin
            self.orientation = orientation
            self.colorScheme = colorScheme
            self.options = options
            self.original = customization
            self.baseline = overrideBaseline
            self.result = customization
        }

        func resolve() -> GamepadCustomization {
            normalizeInputs()
            prepareAppearance()
            mergeLibrariesAndArtwork()
            applyKeypadAppearance()
            applyBuiltInControls()
            applyCustomControls()
            applyTopBar()
            applyControlBarItems()
            finalizeResult()
            return result
        }

        private func normalizeInputs() {
            original.normalizeInPlace()
            if var normalizedBaseline = baseline {
                normalizedBaseline.normalizeInPlace()
                baseline = normalizedBaseline
            }
            result = original
        }

        private func prepareAppearance() {
            appearance = skin.appearance(orientation: orientation, colorScheme: colorScheme)
            compatibility = ThumbleSkinCompatibilityEvaluator.evaluate(
                package.manifest.compatibility,
                customization: original,
                orientation: orientation
            )
        }

        private func mergeLibrariesAndArtwork() {
            guard let appearance, let compatibility else { return }
            result.assetLibrary = ThumbleSkinResolver.mergedAssetLibrary(
                package: package,
                local: original.assetLibrary,
                baseline: baseline?.assetLibrary
            )
            result.styleLibrary = ThumbleSkinResolver.mergedStyleLibrary(
                skin: appearance.styleLibrary,
                local: original.styleLibrary,
                baseline: baseline?.styleLibrary
            )
            result.artworkLayers = compatibility.allowsTemplateArtwork
                ? (appearance.artworkLayers ?? [])
                : []
        }

        private func applyKeypadAppearance() {
            guard let appearance, let compatibility else { return }
            applyBackground(appearance, compatibility: compatibility)
            applyAccent(appearance)
            applyLabelVisibility(appearance)
        }

        private func applyBackground(
            _ appearance: ThumbleSkinAppearance,
            compatibility: ThumbleSkinCompatibilityEvaluation
        ) {
            guard let background = appearance.backgroundFillStyle,
                  ![ThumbleSkinCompatibilityMode.templateAligned, .capturedController].contains(package.manifest.compatibility?.mode ?? .universal)
                    || compatibility.allowsTemplateArtwork
            else { return }
            let shouldPreserve: Bool
            if options.preservesLocalKeypadAppearance, let baseline {
                shouldPreserve = original.hasBackgroundAppearanceDifferent(from: baseline)
            } else {
                shouldPreserve = options.preservesLocalKeypadAppearance
                    && original.hasCustomBackgroundFill(for: colorScheme.swiftUIColorScheme)
            }
            guard !shouldPreserve else { return }
            result.backgroundFillStyle = background
            result.backgroundLightFillStyle = nil
            result.backgroundDarkFillStyle = nil
            result.backgroundLightColor = nil
            result.backgroundDarkColor = nil
        }

        private func applyAccent(_ appearance: ThumbleSkinAppearance) {
            guard let accent = appearance.accentStyle else { return }
            let hasLocalOverride = baseline.map { original.accentStyle != $0.accentStyle }
                ?? (original.accentStyle != .monochrome)
            if !options.preservesLocalKeypadAppearance || !hasLocalOverride {
                result.accentStyle = accent
            }
        }

        private func applyLabelVisibility(_ appearance: ThumbleSkinAppearance) {
            guard let showsLabels = appearance.showsButtonLabels else { return }
            let hasLocalOverride = baseline.map { original.showsButtonLabels != $0.showsButtonLabels }
                ?? (original.showsButtonLabels != true)
            if !options.preservesLocalKeypadAppearance || !hasLocalOverride {
                result.showsButtonLabels = showsLabels
            }
        }

        private func applyBuiltInControls() {
            guard appearance != nil else { return }
            let declared = Set(original.elements.filter { $0.kind == .button }.compactMap(\.defaultControlID))
            for button in DefaultKeypadElements.ids where declared.contains(button) {
                applyBuiltInControl(button)
            }
        }

        private func applyBuiltInControl(_ button: KeypadElementID) {
            guard let appearance else { return }
            let role = original.elements.first(where: { $0.defaultControlID == button })?.visualRole
                ?? GamepadVisualRole.inferred(for: button, controlKind: .button)
            let skinControl = appearance.controlAppearance(
                for: button,
                controlKind: .button,
                visualRole: role
            )
            let local = original.buttonCustomization(for: button)
            result.setButtonCustomization(
                ThumbleSkinResolver.applying(
                    skinControl,
                    to: local,
                    preserveLocal: options.preservesLocalControlAppearance,
                    baseline: baseline?.buttonCustomization(for: button)
                ),
                for: button
            )
        }

        private func applyCustomControls() {
            guard appearance != nil else { return }
            for index in result.customButtons.indices {
                applyCustomControl(at: index)
            }
        }

        private func applyCustomControl(at index: Int) {
            guard let appearance else { return }
            let control = result.customButtons[index]
            let local = original.customButtons.first(where: { $0.id == control.id })?.layout
                ?? control.layout
            let baselineLayout = baseline?.customButtons.first(where: { $0.id == control.id })?.layout
            let role = control.visualRole
                ?? GamepadVisualRole.inferred(
                    for: control.inputID,
                    controlKind: control.controlKind
                )
            let skinControl = appearance.controlAppearance(
                for: control.inputID,
                controlKind: control.controlKind,
                visualRole: role
            )
            result.customButtons[index].layout = ThumbleSkinResolver.applying(
                skinControl,
                to: local,
                preserveLocal: options.preservesLocalControlAppearance,
                baseline: baselineLayout
            )
        }

        private func applyTopBar() {
            guard let appearance else { return }
            result.topBarActivationRegion = ThumbleSkinResolver.applying(
                appearance.controlAppearance(for: .system),
                to: original.topBarActivationRegion,
                preserveLocal: options.preservesLocalControlAppearance,
                baseline: baseline?.topBarActivationRegion
            )
        }

        private func applyControlBarItems() {
            guard appearance != nil else { return }
            for item in result.controlBarItems {
                applyControlBarItem(item)
            }
        }

        private func applyControlBarItem(_ item: GamepadControlBarItem) {
            guard let appearance else { return }
            let role: GamepadVisualRole = switch item {
            case .profileMenu, .launchTarget, .editLayout, .settings, .home: .utility
            case .connectionStatus, .connectionAction, .spacer: .system
            }
            let skinControl = appearance.controlAppearance(for: role)
            let local = original.controlBarItemCustomization(for: item)
            result.setControlBarItemCustomization(
                ThumbleSkinResolver.applying(
                    skinControl,
                    to: local,
                    preserveLocal: options.preservesLocalControlAppearance,
                    baseline: baseline?.controlBarItemCustomization(for: item)
                ),
                for: item
            )
        }

        private func finalizeResult() {
            result.normalizeInPlace()
            result.resolveAssetReferencesInPlace()
        }
    }

    private static func applying(
        _ appearance: ThumbleSkinControlAppearance,
        to local: GamepadButtonCustomization,
        preserveLocal: Bool,
        baseline: GamepadButtonCustomization?
    ) -> GamepadButtonCustomization {
        ControlApplicationWorkspace(
            appearance: appearance,
            local: local,
            preserveLocal: preserveLocal,
            baseline: baseline
        ).resolve()
    }

    private final class ControlApplicationWorkspace {
        private var appearance: ThumbleSkinControlAppearance
        private let local: GamepadButtonCustomization
        private let preserveLocal: Bool
        private let baseline: GamepadButtonCustomization?
        private var result: GamepadButtonCustomization

        init(
            appearance: ThumbleSkinControlAppearance,
            local: GamepadButtonCustomization,
            preserveLocal: Bool,
            baseline: GamepadButtonCustomization?
        ) {
            self.appearance = appearance
            self.local = local
            self.preserveLocal = preserveLocal
            self.baseline = baseline
            self.result = local
        }

        func resolve() -> GamepadButtonCustomization {
            normalizeAppearance()
            clearLocalAppearance()
            applySkinAppearance()
            preserveLocalOverrides()
            normalizeResult()
            return result
        }

        private func normalizeAppearance() {
            appearance.normalizeInPlace()
        }

        private func clearLocalAppearance() {
            // Geometry, hit insets, labels, mappings, and accessibility remain native/local.
            result.clearVisualAppearance()
            // A material-only skin must retain the authored native silhouette.
            // Explicit package shape/radius fields can still replace it below.
            result.shape = local.shape
            result.cornerRadius = local.cornerRadius
            result.cornerRadii = local.cornerRadii
        }

        private func applySkinAppearance() {
            if let value = appearance.styleID { result.styleID = value }
            if let value = appearance.shape { result.shape = value }
            if let value = appearance.accentStyle { result.accentStyle = value }
            if let value = appearance.visualStyle { result.visualStyle = value }
            if let value = appearance.icon { result.icon = value }
            if let value = appearance.hapticFeedback {
                result.hapticFeedback = value
                result.hapticStyle = nil
            }
            if let value = appearance.cornerRadius {
                result.cornerRadius = value
                result.cornerRadii = nil
            }
            if let value = appearance.cornerRadii {
                result.cornerRadii = value
                result.cornerRadius = nil
            }
            if let value = appearance.shadowStrength { result.shadowStrength = value }
            if let value = appearance.joystickKnobColor { result.joystickKnobColor = value }
            if let value = appearance.joystickVisualStyle { result.joystickVisualStyle = value }
        }

        private func preserveLocalOverrides() {
            if preserveLocal, let baseline {
                result.applyStyleDifferences(from: local, baseline: baseline)
            } else if preserveLocal {
                result.applyNonDefaultStyleSnapshot(local.styleSnapshot)
            }
        }

        private func normalizeResult() {
            result = result.normalized
        }
    }

    private static func mergedStyleLibrary(
        skin: GamepadStyleLibrary,
        local: GamepadStyleLibrary,
        baseline: GamepadStyleLibrary?
    ) -> GamepadStyleLibrary {
        StyleLibraryMergeWorkspace(
            skin: skin,
            local: local,
            baseline: baseline
        ).resolve()
    }

    private final class StyleLibraryMergeWorkspace {
        private let skin: GamepadStyleLibrary
        private let local: GamepadStyleLibrary
        private let baseline: GamepadStyleLibrary?
        private var styles: [GamepadStyleToken] = []
        private var localStyles: [GamepadStyleToken] = []
        private var baselineByID: [String: GamepadStyleToken] = [:]

        init(
            skin: GamepadStyleLibrary,
            local: GamepadStyleLibrary,
            baseline: GamepadStyleLibrary?
        ) {
            self.skin = skin
            self.local = local
            self.baseline = baseline
        }

        func resolve() -> GamepadStyleLibrary {
            prepareSkinStyles()
            prepareLocalStyles()
            prepareBaselineIndex()
            mergeLocalStyles()
            return GamepadStyleLibrary(styles: styles).normalized
        }

        private func prepareSkinStyles() {
            styles = skin.normalized.styles
        }

        private func prepareLocalStyles() {
            localStyles = local.normalized.styles
        }

        private func prepareBaselineIndex() {
            guard let baseline else { return }
            baselineByID = Dictionary(
                uniqueKeysWithValues: baseline.normalized.styles.map { ($0.id, $0) }
            )
        }

        private func mergeLocalStyles() {
            for index in localStyles.indices {
                mergeLocalStyle(at: index)
            }
        }

        private func mergeLocalStyle(at index: Int) {
            let style = localStyles[index]
            guard baseline == nil || baselineByID[style.id] != style else { return }
            if let existingIndex = styles.firstIndex(where: { $0.id == style.id }) {
                styles[existingIndex] = style
            } else {
                styles.append(style)
            }
        }
    }

    private static func mergedAssetLibrary(
        package: ThumbleSkinPackage,
        local: GamepadAssetLibrary,
        baseline: GamepadAssetLibrary?
    ) -> GamepadAssetLibrary {
        var assets: [GamepadAsset] = package.manifest.assets.compactMap { descriptor in
            guard let data = package.assets[descriptor.id] else { return nil }
            return GamepadAsset(
                id: descriptor.id,
                name: URL(fileURLWithPath: descriptor.path).deletingPathExtension().lastPathComponent,
                fileName: URL(fileURLWithPath: descriptor.path).lastPathComponent,
                contentType: descriptor.contentType,
                data: data,
                byteCount: descriptor.byteCount,
                hash: descriptor.sha256,
                role: descriptor.role
            )
        }
        let baselineByID = Dictionary(uniqueKeysWithValues: (baseline?.normalized.assets ?? []).map { ($0.id, $0) })
        for asset in local.normalized.assets where baseline == nil || baselineByID[asset.id] != asset {
            if let index = assets.firstIndex(where: { $0.id == asset.id }) {
                // A dehydrated profile descriptor points back to the package payload.
                // Only a local asset with actual data replaces that package resource.
                if asset.data != nil || assets[index].data == nil {
                    assets[index] = asset
                }
            } else {
                assets.append(asset)
            }
        }
        return GamepadAssetLibrary(assets: assets).normalized
    }
}

public extension GamepadCustomization {
    func applying(
        skinPackage: ThumbleSkinPackage,
        orientation: ThumbleSkinOrientation,
        colorScheme: ThumbleSkinColorScheme,
        options: ThumbleSkinApplicationOptions = .preservingUserOverrides,
        overrideBaseline: GamepadCustomization? = nil
    ) -> GamepadCustomization {
        ThumbleSkinResolver.applying(
            package: skinPackage,
            to: self,
            orientation: orientation,
            colorScheme: colorScheme,
            options: options,
            overrideBaseline: overrideBaseline
        )
    }

    fileprivate func hasBackgroundAppearanceDifferent(from baseline: GamepadCustomization) -> Bool {
        backgroundFillStyle != baseline.backgroundFillStyle
            || backgroundLightFillStyle != baseline.backgroundLightFillStyle
            || backgroundDarkFillStyle != baseline.backgroundDarkFillStyle
            || artworkLayers != baseline.artworkLayers
            || backgroundLightColor != baseline.backgroundLightColor
            || backgroundDarkColor != baseline.backgroundDarkColor
    }

    /// Removes package-owned binary payloads while retaining IDs, hashes, and metadata.
    /// Saved profiles therefore reference archive assets instead of duplicating Base64 data.
    func dehydratingAssets(from package: ThumbleSkinPackage) -> GamepadCustomization {
        var copy = self
        copy.dehydrateAssetReferencesInPlace(from: package)
        return copy
    }

    mutating func dehydrateAssetReferencesInPlace(from package: ThumbleSkinPackage) {
        let packageAssets = package.assets
        backgroundFillStyle = backgroundFillStyle?.dehydrating(packageAssets: packageAssets)
        backgroundLightFillStyle = backgroundLightFillStyle?.dehydrating(packageAssets: packageAssets)
        backgroundDarkFillStyle = backgroundDarkFillStyle?.dehydrating(packageAssets: packageAssets)
        artworkLayers = artworkLayers.map { layer in
            var layer = layer
            layer.fillStyle = layer.fillStyle?.dehydrating(packageAssets: packageAssets)
            return layer
        }
        styleLibrary = styleLibrary.dehydrating(packageAssets: packageAssets)
        for button in DefaultKeypadElements.ids {
            guard var layout = buttonCustomizations[button] else { continue }
            layout.dehydrateAssetReferences(packageAssets: packageAssets)
            buttonCustomizations[button] = layout
        }
        for index in customButtons.indices {
            customButtons[index].layout.dehydrateAssetReferences(packageAssets: packageAssets)
        }
        topBarActivationRegion.dehydrateAssetReferences(packageAssets: packageAssets)
        for index in controlBarItemCustomizations.indices {
            controlBarItemCustomizations[index].appearance.dehydrateAssetReferences(packageAssets: packageAssets)
        }
        for index in assetLibrary.assets.indices {
            let id = assetLibrary.assets[index].id
            if let packageData = packageAssets[id], assetLibrary.assets[index].data == packageData {
                assetLibrary.assets[index].data = nil
            }
        }
        normalizeInPlace()
    }

    func resolvingAssetReferences() -> GamepadCustomization {
        var copy = self
        copy.resolveAssetReferencesInPlace()
        return copy
    }

    mutating func resolveAssetReferencesInPlace() {
        let library = assetLibrary
        backgroundFillStyle = backgroundFillStyle?.resolvingAssets(in: library)
        backgroundLightFillStyle = backgroundLightFillStyle?.resolvingAssets(in: library)
        backgroundDarkFillStyle = backgroundDarkFillStyle?.resolvingAssets(in: library)
        artworkLayers = artworkLayers.map { layer in
            var layer = layer
            layer.fillStyle = layer.fillStyle?.resolvingAssets(in: library)
            return layer
        }
        styleLibrary = styleLibrary.resolvingAssets(in: library)
        for button in DefaultKeypadElements.ids {
            guard var layout = buttonCustomizations[button] else { continue }
            layout.resolveAssetReferences(in: library)
            buttonCustomizations[button] = layout
        }
        for index in customButtons.indices {
            customButtons[index].layout.resolveAssetReferences(in: library)
        }
        topBarActivationRegion.resolveAssetReferences(in: library)
        for index in controlBarItemCustomizations.indices {
            controlBarItemCustomizations[index].appearance.resolveAssetReferences(in: library)
        }
        normalizeInPlace()
    }
}

public extension GamepadFillStyle {
    func resolvingAssets(in library: GamepadAssetLibrary) -> GamepadFillStyle {
        guard case .image(var image) = normalized,
              image.data == nil,
              let assetID = image.assetID,
              let data = library.asset(id: assetID)?.data
        else { return normalized }
        image.data = data
        return .image(image.normalized)
    }
}

private extension GamepadFillStyle {
    func dehydrating(packageAssets: [String: Data]) -> GamepadFillStyle {
        guard case .image(var image) = normalized,
              let assetID = image.assetID,
              let packageData = packageAssets[assetID],
              image.data == packageData
        else { return normalized }
        image.data = nil
        return .image(image.normalized)
    }
}

extension GamepadControlStateStyle {
    func resolvingAssets(in library: GamepadAssetLibrary) -> GamepadControlStateStyle {
        var copy = self
        copy.fillStyle = copy.fillStyle?.resolvingAssets(in: library)
        return copy.normalized
    }

    fileprivate func dehydrating(packageAssets: [String: Data]) -> GamepadControlStateStyle {
        var copy = self
        copy.fillStyle = copy.fillStyle?.dehydrating(packageAssets: packageAssets)
        return copy.normalized
    }
}

extension GamepadControlVisualStyle {
    func resolvingAssets(in library: GamepadAssetLibrary) -> GamepadControlVisualStyle {
        GamepadControlVisualStyle(
            normal: normal.resolvingAssets(in: library),
            pressed: pressed?.resolvingAssets(in: library),
            active: active?.resolvingAssets(in: library),
            disabled: disabled?.resolvingAssets(in: library),
            icon: icon,
            hapticStyle: hapticStyle,
            hapticFeedback: hapticFeedback
        )
    }

    fileprivate func dehydrating(packageAssets: [String: Data]) -> GamepadControlVisualStyle {
        GamepadControlVisualStyle(
            normal: normal.dehydrating(packageAssets: packageAssets),
            pressed: pressed?.dehydrating(packageAssets: packageAssets),
            active: active?.dehydrating(packageAssets: packageAssets),
            disabled: disabled?.dehydrating(packageAssets: packageAssets),
            icon: icon,
            hapticStyle: hapticStyle,
            hapticFeedback: hapticFeedback
        )
    }
}

extension GamepadStyleLibrary {
    func resolvingAssets(in library: GamepadAssetLibrary) -> GamepadStyleLibrary {
        GamepadStyleLibrary(styles: normalized.styles.map { style in
            var style = style
            style.visualStyle = style.visualStyle.resolvingAssets(in: library)
            return style
        }).normalized
    }

    fileprivate func dehydrating(packageAssets: [String: Data]) -> GamepadStyleLibrary {
        GamepadStyleLibrary(styles: normalized.styles.map { style in
            var style = style
            style.visualStyle = style.visualStyle.dehydrating(packageAssets: packageAssets)
            return style
        }).normalized
    }
}

extension GamepadButtonCustomization {
    var resolvedHitInsets: GamepadHitInsets {
        hitInsets?.normalized ?? .runtimeDefault
    }

    mutating func resolveAssetReferences(in library: GamepadAssetLibrary) {
        fillStyle = fillStyle?.resolvingAssets(in: library)
        lightFillStyle = lightFillStyle?.resolvingAssets(in: library)
        darkFillStyle = darkFillStyle?.resolvingAssets(in: library)
        visualStyle = visualStyle?.resolvingAssets(in: library)
    }

    fileprivate mutating func dehydrateAssetReferences(packageAssets: [String: Data]) {
        fillStyle = fillStyle?.dehydrating(packageAssets: packageAssets)
        lightFillStyle = lightFillStyle?.dehydrating(packageAssets: packageAssets)
        darkFillStyle = darkFillStyle?.dehydrating(packageAssets: packageAssets)
        visualStyle = visualStyle?.dehydrating(packageAssets: packageAssets)
    }

    fileprivate mutating func clearVisualAppearance() {
        shape = nil
        accentStyle = nil
        fillColor = nil
        lightFillColor = nil
        darkFillColor = nil
        fillStyle = nil
        lightFillStyle = nil
        darkFillStyle = nil
        joystickKnobColor = nil
        lightJoystickKnobColor = nil
        darkJoystickKnobColor = nil
        joystickVisualStyle = nil
        styleID = nil
        visualStyle = nil
        icon = nil
        hapticStyle = nil
        hapticFeedback = nil
        cornerRadius = nil
        cornerRadii = nil
        shadowStrength = Self.defaultShadowStrength
    }

    fileprivate mutating func applyNonDefaultStyleSnapshot(_ local: GamepadButtonCustomization) {
        if local.shape != nil { shape = local.shape }
        if local.accentStyle != nil { accentStyle = local.accentStyle }
        if local.fillColor != nil { fillColor = local.fillColor }
        if local.lightFillColor != nil { lightFillColor = local.lightFillColor }
        if local.darkFillColor != nil { darkFillColor = local.darkFillColor }
        if local.fillStyle != nil { fillStyle = local.fillStyle }
        if local.lightFillStyle != nil { lightFillStyle = local.lightFillStyle }
        if local.darkFillStyle != nil { darkFillStyle = local.darkFillStyle }
        if local.joystickKnobColor != nil { joystickKnobColor = local.joystickKnobColor }
        if local.lightJoystickKnobColor != nil { lightJoystickKnobColor = local.lightJoystickKnobColor }
        if local.darkJoystickKnobColor != nil { darkJoystickKnobColor = local.darkJoystickKnobColor }
        if local.joystickVisualStyle != nil { joystickVisualStyle = local.joystickVisualStyle }
        if local.styleID != nil { styleID = local.styleID }
        if local.visualStyle != nil { visualStyle = local.visualStyle }
        if local.icon != nil { icon = local.icon }
        if local.hapticStyle != nil { hapticStyle = local.hapticStyle }
        if local.hapticFeedback != nil { hapticFeedback = local.hapticFeedback }
        if local.cornerRadius != nil { cornerRadius = local.cornerRadius; cornerRadii = nil }
        if local.cornerRadii != nil { cornerRadii = local.cornerRadii; cornerRadius = nil }
        if abs(local.shadowStrength - Self.defaultShadowStrength) >= 0.001 {
            shadowStrength = local.shadowStrength
        }
    }

    /// Applies only fields changed since a skin baseline was captured, including intentional clears.
    fileprivate mutating func applyStyleDifferences(
        from local: GamepadButtonCustomization,
        baseline: GamepadButtonCustomization
    ) {
        if local.shape != baseline.shape { shape = local.shape }
        if local.accentStyle != baseline.accentStyle { accentStyle = local.accentStyle }
        if local.fillColor != baseline.fillColor { fillColor = local.fillColor }
        if local.lightFillColor != baseline.lightFillColor { lightFillColor = local.lightFillColor }
        if local.darkFillColor != baseline.darkFillColor { darkFillColor = local.darkFillColor }
        if local.fillStyle != baseline.fillStyle { fillStyle = local.fillStyle }
        if local.lightFillStyle != baseline.lightFillStyle { lightFillStyle = local.lightFillStyle }
        if local.darkFillStyle != baseline.darkFillStyle { darkFillStyle = local.darkFillStyle }
        if local.joystickKnobColor != baseline.joystickKnobColor { joystickKnobColor = local.joystickKnobColor }
        if local.lightJoystickKnobColor != baseline.lightJoystickKnobColor { lightJoystickKnobColor = local.lightJoystickKnobColor }
        if local.darkJoystickKnobColor != baseline.darkJoystickKnobColor { darkJoystickKnobColor = local.darkJoystickKnobColor }
        if local.joystickVisualStyle != baseline.joystickVisualStyle { joystickVisualStyle = local.joystickVisualStyle }
        if local.styleID != baseline.styleID { styleID = local.styleID }
        if local.visualStyle != baseline.visualStyle { visualStyle = local.visualStyle }
        if local.icon != baseline.icon { icon = local.icon }
        if local.hapticStyle != baseline.hapticStyle { hapticStyle = local.hapticStyle }
        if local.hapticFeedback != baseline.hapticFeedback { hapticFeedback = local.hapticFeedback }
        if local.cornerRadius != baseline.cornerRadius { cornerRadius = local.cornerRadius }
        if local.cornerRadii != baseline.cornerRadii { cornerRadii = local.cornerRadii }
        if abs(local.shadowStrength - baseline.shadowStrength) >= 0.001 { shadowStrength = local.shadowStrength }
    }
}

private extension ThumbleSkinColorScheme {
    var swiftUIColorScheme: ColorScheme {
        switch self {
        case .light: .light
        case .dark: .dark
        }
    }
}
