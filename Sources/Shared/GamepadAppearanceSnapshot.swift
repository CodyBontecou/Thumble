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

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.storage === rhs.storage || lhs.storage.value == rhs.storage.value
    }

    // This allowlist is also the persistence boundary: geometry can never be
    // smuggled into an appearance bank by an old or hand-written document.
    private static let fields: Set<String> = [
        "shape", "accentStyle", "fillColor", "lightFillColor", "darkFillColor",
        "fillStyle", "lightFillStyle", "darkFillStyle", "joystickKnobColor",
        "lightJoystickKnobColor", "darkJoystickKnobColor", "joystickVisualStyle",
        "styleID", "visualStyle", "icon", "hapticStyle", "hapticFeedback",
        "cornerRadius", "cornerRadii", "shadowStrength", "showsIntegratedLabel"
    ]

    public init(from decoder: Decoder) throws {
        try AppearanceSnapshotCodingKey.require(fields: Self.fields, from: decoder)
        self.init(try GamepadButtonCustomization(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        // Encoding is a save/export operation, never part of applying a bank to
        // a touch event. Reuse the native codec to preserve style wire formats.
        let encoded = try JSONEncoder().encode(storage.value)
        let fields = try JSONDecoder().decode([String: ThumbleBridgeJSONValue].self, from: encoded)
        var container = encoder.container(keyedBy: AppearanceSnapshotCodingKey.self)
        for (key, value) in fields where Self.fields.contains(key) {
            try container.encode(value, forKey: AppearanceSnapshotCodingKey(key))
        }
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

    /// Migration/export validation, deliberately separate from runtime application.
    /// Inspect the serialized design tree so nested state/content/paint references
    /// get the same coverage as top-level fills and icons.
    public func missingResourceIDs() throws -> [String] {
        let encoded = try JSONEncoder().encode(self)
        var pending = [try JSONDecoder().decode(ThumbleBridgeJSONValue.self, from: encoded)]
        let available = Set(storage.content.assetLibrary.assets.compactMap { asset in
            asset.data?.isEmpty == false ? asset.id : nil
        })
        var missing = Set<String>()
        while let node = pending.popLast() {
            switch node {
            case .object(let fields):
                if case .string(let id) = fields["assetID"], !available.contains(id) {
                    let hasInlineData: Bool
                    if case .string(let encodedData) = fields["data"] {
                        hasInlineData = Data(base64Encoded: encodedData)?.isEmpty == false
                    } else { hasInlineData = false }
                    if !hasInlineData { missing.insert(id) }
                }
                if fields["source"] == .string("asset"), case .string(let id) = fields["value"], !available.contains(id) {
                    missing.insert(id)
                }
                pending.append(contentsOf: fields.values)
            case .array(let children): pending.append(contentsOf: children)
            default: break
            }
        }
        return missing.sorted()
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
