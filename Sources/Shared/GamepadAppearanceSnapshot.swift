import Foundation

/// A control's editable appearance, without position, size, hit testing, or outputs.
/// Immutable storage keeps copies cheap and avoids embedding large style values in profiles.
public struct GamepadControlAppearanceSnapshot: Codable, Equatable, Sendable {
    private final class Storage: Sendable {
        let value: GamepadButtonCustomization
        init(_ value: GamepadButtonCustomization) { self.value = value }
    }

    private let storage: Storage

    public init(_ layout: GamepadButtonCustomization) {
        var value = GamepadButtonCustomization.defaultValue
        value.applyStyleSnapshot(layout)
        value.joystickVisualStyle = layout.joystickVisualStyle
        value.showsIntegratedLabel = layout.showsIntegratedLabel
        storage = Storage(value)
    }

    public func applying(to layout: GamepadButtonCustomization) -> GamepadButtonCustomization {
        var result = layout
        result.applyStyleSnapshot(storage.value)
        result.joystickVisualStyle = storage.value.joystickVisualStyle
        result.showsIntegratedLabel = storage.value.showsIntegratedLabel
        return result
    }

    func preservingEdits(from edited: Self, baseline: Self, scheme: ThumbleSkinColorScheme?, fallbackAccent: GamepadAccentStyle) -> Self {
        if edited == baseline { return self }
        return Self(GamepadAppearanceEditMerge.control(edited.storage.value, baseline.storage.value, storage.value,
            scheme: scheme, fallbackAccent: fallbackAccent))
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.storage === rhs.storage || lhs.storage.value == rhs.storage.value
    }

    // This allowlist is also the persistence boundary: geometry can never be
    // smuggled into an appearance bank by an old or hand-written document.
    private enum Field: String, CodingKey, CaseIterable {
        case shape, accentStyle, fillColor, lightFillColor, darkFillColor
        case fillStyle, lightFillStyle, darkFillStyle, joystickKnobColor
        case lightJoystickKnobColor, darkJoystickKnobColor, joystickVisualStyle
        case styleID, visualStyle, icon, hapticStyle, hapticFeedback
        case cornerRadius, cornerRadii, shadowStrength, showsIntegratedLabel
    }

    public init(from decoder: Decoder) throws {
        try AppearanceSnapshotCodingKey.require(fields: Set(Field.allCases.map(\.rawValue)), from: decoder)
        self.init(try GamepadButtonCustomization(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        // Keep typed Data visible to the owning profile's resource strategy.
        // An intermediate JSON tree here would bypass content deduplication.
        var container = encoder.container(keyedBy: Field.self)
        try encodeFills(into: &container)
        try encodeStyle(into: &container)
        try encodeFeedback(into: &container)
    }

    private func encodeFills(into container: inout KeyedEncodingContainer<Field>) throws {
        try container.encodeIfPresent(storage.value.fillColor, forKey: .fillColor)
        try container.encodeIfPresent(storage.value.lightFillColor, forKey: .lightFillColor)
        try container.encodeIfPresent(storage.value.darkFillColor, forKey: .darkFillColor)
        try container.encodeIfPresent(storage.value.fillStyle, forKey: .fillStyle)
        try container.encodeIfPresent(storage.value.lightFillStyle, forKey: .lightFillStyle)
        try container.encodeIfPresent(storage.value.darkFillStyle, forKey: .darkFillStyle)
        try container.encodeIfPresent(storage.value.joystickKnobColor?.normalized, forKey: .joystickKnobColor)
        try container.encodeIfPresent(storage.value.lightJoystickKnobColor?.normalized, forKey: .lightJoystickKnobColor)
        try container.encodeIfPresent(storage.value.darkJoystickKnobColor?.normalized, forKey: .darkJoystickKnobColor)
    }
    private func encodeStyle(into container: inout KeyedEncodingContainer<Field>) throws {
        try container.encodeIfPresent(storage.value.shape, forKey: .shape)
        try container.encodeIfPresent(storage.value.accentStyle, forKey: .accentStyle)
        try container.encodeIfPresent(storage.value.joystickVisualStyle, forKey: .joystickVisualStyle)
        try container.encodeIfPresent(storage.value.styleID, forKey: .styleID)
        try container.encodeIfPresent(storage.value.visualStyle, forKey: .visualStyle)
        try container.encodeIfPresent(storage.value.icon, forKey: .icon)
        try container.encodeIfPresent(storage.value.cornerRadius, forKey: .cornerRadius)
        try container.encodeIfPresent(storage.value.cornerRadii, forKey: .cornerRadii)
        try container.encode(storage.value.shadowStrength, forKey: .shadowStrength)
        if !storage.value.showsIntegratedLabel { try container.encode(false, forKey: .showsIntegratedLabel) }
    }
    private func encodeFeedback(into container: inout KeyedEncodingContainer<Field>) throws {
        try container.encodeIfPresent(storage.value.hapticStyle, forKey: .hapticStyle)
        try container.encodeIfPresent(storage.value.hapticFeedback, forKey: .hapticFeedback)
    }

    fileprivate func collectResources(into collector: GamepadAppearanceResourceReferences) {
        collector.control(storage.value)
    }
}

/// Profile-owned appearance for one color scheme and held-trigger state.
/// Applying it leaves the destination's controls, geometry, groups and outputs intact.
public struct GamepadAppearanceSnapshot: Codable, Equatable, Sendable {
    private struct Content: Codable, Equatable, Sendable {
        var backgroundLightColor: GamepadRGBAColor?
        var backgroundDarkColor: GamepadRGBAColor?
        var backgroundFillStyle: GamepadFillStyle?
        var backgroundLightFillStyle: GamepadFillStyle?
        var backgroundDarkFillStyle: GamepadFillStyle?
        var artworkLayers: [ThumbleSkinArtworkLayer]
        var accentStyle: GamepadAccentStyle
        var showsButtonLabels: Bool
        var controls: [String: GamepadControlAppearanceSnapshot]
        var topBar: GamepadControlAppearanceSnapshot
        var controlBar: [String: GamepadControlAppearanceSnapshot]
        var styleLibrary: GamepadStyleLibrary
        var assetLibrary: GamepadAssetLibrary

        init(_ layout: GamepadCustomization) {
            backgroundLightColor = layout.backgroundLightColor
            backgroundDarkColor = layout.backgroundDarkColor
            backgroundFillStyle = layout.backgroundFillStyle
            backgroundLightFillStyle = layout.backgroundLightFillStyle
            backgroundDarkFillStyle = layout.backgroundDarkFillStyle
            artworkLayers = layout.artworkLayers
            accentStyle = layout.accentStyle
            showsButtonLabels = layout.showsButtonLabels
            controls = Dictionary(uniqueKeysWithValues: layout.elements.map {
                ($0.id.uuidString.lowercased(), GamepadControlAppearanceSnapshot($0.layout))
            })
            topBar = GamepadControlAppearanceSnapshot(layout.topBarActivationRegion)
            controlBar = Dictionary(uniqueKeysWithValues: layout.controlBarItemCustomizations.map {
                ($0.item.rawValue, GamepadControlAppearanceSnapshot($0.appearance))
            })
            styleLibrary = layout.styleLibrary
            assetLibrary = layout.assetLibrary
        }

        func applySurface(to result: inout GamepadCustomization) {
            result.backgroundLightColor = backgroundLightColor
            result.backgroundDarkColor = backgroundDarkColor
            result.backgroundFillStyle = backgroundFillStyle
            result.backgroundLightFillStyle = backgroundLightFillStyle
            result.backgroundDarkFillStyle = backgroundDarkFillStyle
            result.artworkLayers = artworkLayers
            result.accentStyle = accentStyle
            result.showsButtonLabels = showsButtonLabels
            result.styleLibrary = styleLibrary
            result.assetLibrary = assetLibrary
        }
    }

    private final class Storage: Sendable {
        let content: Content
        init(_ content: Content) { self.content = content }
    }

    private let storage: Storage

    public init(_ customization: GamepadCustomization) {
        storage = Storage(Content(customization.normalized))
    }

    public func applying(to customization: GamepadCustomization) -> GamepadCustomization {
        let workspace = ApplicationWorkspace(customization, content: storage.content)
        return workspace.apply()
    }

    /// Resolve another state while retaining only the user's changes from the
    /// saved reference. Geometry and executable bindings always come from input.
    public func applying(to customization: GamepadCustomization, preservingEditsFrom baseline: Self,
                         colorScheme: ThumbleSkinColorScheme? = nil) -> GamepadCustomization {
        let workspace = EditWorkspace(edited: Content(customization.normalized),
            baseline: baseline.storage.content, target: storage.content, scheme: colorScheme)
        return ApplicationWorkspace(customization, content: workspace.merge()).apply()
    }

    var controlIDs: Set<String> { Set(storage.content.controls.keys) }

    private final class EditWorkspace {
        let edited: Content
        let baseline: Content
        var result: Content
        let scheme: ThumbleSkinColorScheme?
        init(edited: Content, baseline: Content, target: Content, scheme: ThumbleSkinColorScheme?) {
            self.edited = edited; self.baseline = baseline; result = target
            self.scheme = scheme
        }
        func merge() -> Content {
            if edited == baseline { return result }
            mergeSurface()
            mergeControls()
            mergeLibraries()
            return result
        }
        private func mergeSurface() {
            apply(\.backgroundLightColor)
            apply(\.backgroundDarkColor)
            apply(\.backgroundFillStyle)
            apply(\.backgroundLightFillStyle)
            apply(\.backgroundDarkFillStyle)
            apply(\.accentStyle)
            apply(\.showsButtonLabels)
            result.artworkLayers = GamepadAppearanceEditMerge.collection(edited.artworkLayers,
                baseline.artworkLayers, result.artworkLayers, id: \.id, merge: Self.artwork)
        }
        private func apply<T: Equatable>(_ path: WritableKeyPath<Content, T>) {
            result[keyPath: path] = GamepadAppearanceEditMerge.value(edited[keyPath: path],
                baseline[keyPath: path], result[keyPath: path])
        }
        private func mergeControls() {
            result.controls = controls(edited.controls, baseline.controls, result.controls)
            result.topBar = result.topBar.preservingEdits(from: edited.topBar, baseline: baseline.topBar,
                scheme: scheme, fallbackAccent: result.accentStyle)
            result.controlBar = controls(edited.controlBar, baseline.controlBar, result.controlBar)
        }
        private func controls(_ edited: [String: GamepadControlAppearanceSnapshot],
                                     _ baseline: [String: GamepadControlAppearanceSnapshot],
                                     _ target: [String: GamepadControlAppearanceSnapshot]) -> [String: GamepadControlAppearanceSnapshot] {
            var result = target
            for (id, original) in baseline {
                guard let current = edited[id] else { result[id] = nil; continue }
                if let appearance = target[id] {
                    result[id] = appearance.preservingEdits(from: current, baseline: original,
                        scheme: scheme, fallbackAccent: self.result.accentStyle)
                } else if current != original { result[id] = current }
            }
            for (id, current) in edited where baseline[id] == nil {
                result[id] = target[id]?.preservingEdits(from: current, baseline: .init(.defaultValue),
                    scheme: scheme, fallbackAccent: self.result.accentStyle) ?? current
            }
            return result
        }
        private func mergeLibraries() {
            result.styleLibrary = GamepadStyleLibrary(styles: GamepadAppearanceEditMerge.collection(
                edited.styleLibrary.styles, baseline.styleLibrary.styles, result.styleLibrary.styles,
                id: \.id, merge: GamepadAppearanceEditMerge.token))
            result.assetLibrary = GamepadAssetLibrary(assets: GamepadAppearanceEditMerge.collection(
                edited.assetLibrary.assets, baseline.assetLibrary.assets, result.assetLibrary.assets,
                id: \.id, merge: GamepadAppearanceEditMerge.value))
        }
        private static func artwork(_ edited: ThumbleSkinArtworkLayer, _ baseline: ThumbleSkinArtworkLayer,
                                    _ target: ThumbleSkinArtworkLayer) -> ThumbleSkinArtworkLayer {
            ThumbleSkinArtworkLayer(id: target.id,
                plane: GamepadAppearanceEditMerge.value(edited.plane, baseline.plane, target.plane),
                frame: GamepadAppearanceEditMerge.value(edited.frame, baseline.frame, target.frame),
                fillStyle: GamepadAppearanceEditMerge.value(edited.fillStyle, baseline.fillStyle, target.fillStyle),
                opacity: GamepadAppearanceEditMerge.value(edited.opacity, baseline.opacity, target.opacity),
                rotationDegrees: GamepadAppearanceEditMerge.value(edited.rotationDegrees, baseline.rotationDegrees, target.rotationDegrees),
                blendMode: GamepadAppearanceEditMerge.value(edited.blendMode, baseline.blendMode, target.blendMode),
                zIndex: GamepadAppearanceEditMerge.value(edited.zIndex, baseline.zIndex, target.zIndex),
                isHidden: GamepadAppearanceEditMerge.value(edited.isHidden, baseline.isHidden, target.isHidden))
        }
    }

    /// Migration/export validation, deliberately separate from runtime application.
    /// Walk nested state/content references without expanding image bytes to JSON.
    public func missingResourceIDs() throws -> [String] {
        let collector = GamepadAppearanceResourceReferences(library: storage.content.assetLibrary)
        collector.fill(storage.content.backgroundFillStyle)
        collector.fill(storage.content.backgroundLightFillStyle)
        collector.fill(storage.content.backgroundDarkFillStyle)
        for layer in storage.content.artworkLayers { collector.fill(layer.fillStyle) }
        for appearance in storage.content.controls.values { appearance.collectResources(into: collector) }
        storage.content.topBar.collectResources(into: collector)
        for appearance in storage.content.controlBar.values { appearance.collectResources(into: collector) }
        for token in storage.content.styleLibrary.styles { collector.visual(token.visualStyle) }
        return collector.missing.sorted()
    }

    // Split surface/control work on a heap-backed workspace to keep constrained
    // synchronization threads within their existing Debug stack budgets.
    private final class ApplicationWorkspace {
        var result: GamepadCustomization
        let content: Content

        init(_ customization: GamepadCustomization, content: Content) {
            result = customization.normalized
            self.content = content
        }

        func apply() -> GamepadCustomization {
            content.applySurface(to: &result)
            applyControls()
            applyBars()
            result.normalizeInPlace()
            return result
        }

        private func applyControls() {
            for index in result.elements.indices {
                let id = result.elements[index].id
                guard let appearance = content.controls[id.uuidString.lowercased()] else { continue }
                let layout = appearance.applying(to: result.elements[index].layout)
                result.elements[index].layout = layout
                // Maintain the native mirror collections; normalization uses
                // them as authorities and would otherwise undo this change.
                if let button = result.elements[index].defaultControlID {
                    result.buttonCustomizations[button] = layout.isDefault ? nil : layout
                }
                if let customIndex = result.customButtons.firstIndex(where: { $0.id == id }) {
                    result.customButtons[customIndex].layout = layout
                }
            }
        }

        private func applyBars() {
            result.topBarActivationRegion = content.topBar.applying(to: result.topBarActivationRegion)
            for item in result.controlBarItems { applyBarItem(item) }
        }

        private func applyBarItem(_ item: GamepadControlBarItem) {
            let existing = result.controlBarItemCustomization(for: item)
            let appearance = content.controlBar[item.rawValue] ?? GamepadControlAppearanceSnapshot(.defaultValue)
            result.setControlBarItemCustomization(appearance.applying(to: existing), for: item)
        }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.storage === rhs.storage || lhs.storage.content == rhs.storage.content
    }

    public init(from decoder: Decoder) throws {
        try AppearanceSnapshotCodingKey.require(fields: [
            "backgroundLightColor", "backgroundDarkColor", "backgroundFillStyle",
            "backgroundLightFillStyle", "backgroundDarkFillStyle", "artworkLayers",
            "accentStyle", "showsButtonLabels", "controls", "topBar", "controlBar",
            "styleLibrary", "assetLibrary"
        ], from: decoder)
        let content = try Content(from: decoder)
        guard content.controls.keys.allSatisfy({ UUID(uuidString: $0)?.uuidString.lowercased() == $0 }),
              content.controlBar.keys.allSatisfy({ GamepadControlBarItem(rawValue: $0) != nil }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Appearance snapshots require canonical control UUIDs and known bar items."))
        }
        storage = Storage(content)
    }

    public func encode(to encoder: Encoder) throws { try storage.content.encode(to: encoder) }
}

/// Validation walks typed references without encoding large image payloads.
private final class GamepadAppearanceResourceReferences {
    let available: Set<String>
    private(set) var missing = Set<String>()
    init(library: GamepadAssetLibrary) {
        available = Set(library.assets.compactMap { $0.data?.isEmpty == false ? $0.id : nil })
    }
    func fill(_ fill: GamepadFillStyle?) {
        guard case .image(let image)? = fill, let id = image.assetID,
              image.data?.isEmpty != false, !available.contains(id) else { return }
        missing.insert(id)
    }
    func icon(_ icon: GamepadControlIcon?) {
        guard let icon, icon.source == .asset, !available.contains(icon.value) else { return }
        missing.insert(icon.value)
    }
    func visual(_ style: GamepadControlVisualStyle?) {
        guard let style else { return }
        icon(style.icon)
        state(style.normal)
        if let value = style.pressed { state(value) }
        if let value = style.active { state(value) }
        if let value = style.disabled { state(value) }
    }
    private func state(_ style: GamepadControlStateStyle) {
        fill(style.fillStyle)
        icon(style.content?.icon)
    }
    func control(_ layout: GamepadButtonCustomization) {
        fill(layout.fillStyle)
        fill(layout.lightFillStyle)
        fill(layout.darkFillStyle)
        icon(layout.icon)
        visual(layout.visualStyle)
    }
}

private struct AppearanceSnapshotCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }

    static func require(fields: Set<String>, from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Self.self)
        if let key = container.allKeys.first(where: { !fields.contains($0.stringValue) }) {
            throw DecodingError.dataCorruptedError(forKey: key, in: container,
                debugDescription: "Appearance snapshots cannot contain \(key.stringValue).")
        }
    }
}
