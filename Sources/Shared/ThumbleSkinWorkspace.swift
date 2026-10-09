import CryptoKit
import Foundation
import SwiftUI

public enum ThumbleSkinWorkspaceSchema {
    public static let identifier = "com.codybontecou.pocketpad.skin-source"
    /// Schema 1: materials. Schema 2: CSS. Schema 3: captured controller artboards.
    public static let currentVersion = 3
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

public enum ThumbleSkinMaterialKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case translucentPlastic = "translucent_plastic"
    case opaquePlastic = "opaque_plastic"
    case matteRubber = "matte_rubber"
    case glossyPlastic = "glossy_plastic"
    case glass
    case metal
    case raised
    case inset

    public var id: String { rawValue }
}

public struct ThumbleSkinPaletteToken: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var light: String
    public var dark: String?

    public init(id: String, light: String, dark: String? = nil) {
        self.id = id
        self.light = light
        self.dark = dark
    }
}

public struct ThumbleSkinMaterialSpec: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var kind: ThumbleSkinMaterialKind
    public var baseColor: String
    public var darkBaseColor: String?
    public var foregroundColor: String
    public var darkForegroundColor: String?
    public var strokeColor: String?
    public var darkStrokeColor: String?
    /// Surface highlight used for bevel and upper-left light response.
    public var highlightColor: String?
    /// Optional interaction accent used for the active state's crisp index stroke.
    public var activeColor: String?
    public var darkActiveColor: String?
    public var activeIndexColor: String?
    public var darkActiveIndexColor: String?
    public var activeIndexWidth: CGFloat?
    public var shadowColor: String?
    /// Optional native joystick puck colors. These remain passive appearance values.
    public var joystickKnobColor: String?
    public var darkJoystickKnobColor: String?
    /// Exact state colors opt a material into authored state output instead of derived color mixing.
    public var pressedFillColor: String?
    public var darkPressedFillColor: String?
    public var activeFillColor: String?
    public var darkActiveFillColor: String?
    public var disabledFillColor: String?
    public var darkDisabledFillColor: String?
    public var disabledForegroundColor: String?
    public var darkDisabledForegroundColor: String?
    public var disabledStrokeColor: String?
    public var darkDisabledStrokeColor: String?
    /// Optional state geometry and depth controls. Missing values preserve legacy compilation.
    public var shadowScale: CGFloat?
    public var pressedShadowScale: CGFloat?
    public var pressedInnerShadowScale: CGFloat?
    public var activeStrokeWidth: CGFloat?
    public var portraitActiveStrokeWidth: CGFloat?
    public var landscapeActiveStrokeWidth: CGFloat?
    public var disabledStrokeWidth: CGFloat?
    public var disabledOpacity: CGFloat?
    public var depth: CGFloat
    public var gloss: CGFloat
    public var cornerRadius: CGFloat?
    public var pressedScale: CGFloat
    public var hapticFeedback: GamepadHapticFeedback?

    public init(
        id: String,
        name: String,
        kind: ThumbleSkinMaterialKind,
        baseColor: String,
        darkBaseColor: String? = nil,
        foregroundColor: String,
        darkForegroundColor: String? = nil,
        strokeColor: String? = nil,
        darkStrokeColor: String? = nil,
        highlightColor: String? = nil,
        activeColor: String? = nil,
        darkActiveColor: String? = nil,
        activeIndexColor: String? = nil,
        darkActiveIndexColor: String? = nil,
        activeIndexWidth: CGFloat? = nil,
        shadowColor: String? = nil,
        joystickKnobColor: String? = nil,
        darkJoystickKnobColor: String? = nil,
        pressedFillColor: String? = nil,
        darkPressedFillColor: String? = nil,
        activeFillColor: String? = nil,
        darkActiveFillColor: String? = nil,
        disabledFillColor: String? = nil,
        darkDisabledFillColor: String? = nil,
        disabledForegroundColor: String? = nil,
        darkDisabledForegroundColor: String? = nil,
        disabledStrokeColor: String? = nil,
        darkDisabledStrokeColor: String? = nil,
        shadowScale: CGFloat? = nil,
        pressedShadowScale: CGFloat? = nil,
        pressedInnerShadowScale: CGFloat? = nil,
        activeStrokeWidth: CGFloat? = nil,
        portraitActiveStrokeWidth: CGFloat? = nil,
        landscapeActiveStrokeWidth: CGFloat? = nil,
        disabledStrokeWidth: CGFloat? = nil,
        disabledOpacity: CGFloat? = nil,
        depth: CGFloat = 0.6,
        gloss: CGFloat = 0.35,
        cornerRadius: CGFloat? = nil,
        pressedScale: CGFloat = 0.97,
        hapticFeedback: GamepadHapticFeedback? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseColor = baseColor
        self.darkBaseColor = darkBaseColor
        self.foregroundColor = foregroundColor
        self.darkForegroundColor = darkForegroundColor
        self.strokeColor = strokeColor
        self.darkStrokeColor = darkStrokeColor
        self.highlightColor = highlightColor
        self.activeColor = activeColor
        self.darkActiveColor = darkActiveColor
        self.activeIndexColor = activeIndexColor
        self.darkActiveIndexColor = darkActiveIndexColor
        self.activeIndexWidth = activeIndexWidth
        self.shadowColor = shadowColor
        self.joystickKnobColor = joystickKnobColor
        self.darkJoystickKnobColor = darkJoystickKnobColor
        self.pressedFillColor = pressedFillColor
        self.darkPressedFillColor = darkPressedFillColor
        self.activeFillColor = activeFillColor
        self.darkActiveFillColor = darkActiveFillColor
        self.disabledFillColor = disabledFillColor
        self.darkDisabledFillColor = darkDisabledFillColor
        self.disabledForegroundColor = disabledForegroundColor
        self.darkDisabledForegroundColor = darkDisabledForegroundColor
        self.disabledStrokeColor = disabledStrokeColor
        self.darkDisabledStrokeColor = darkDisabledStrokeColor
        self.shadowScale = shadowScale
        self.pressedShadowScale = pressedShadowScale
        self.pressedInnerShadowScale = pressedInnerShadowScale
        self.activeStrokeWidth = activeStrokeWidth
        self.portraitActiveStrokeWidth = portraitActiveStrokeWidth
        self.landscapeActiveStrokeWidth = landscapeActiveStrokeWidth
        self.disabledStrokeWidth = disabledStrokeWidth
        self.disabledOpacity = disabledOpacity
        self.depth = depth
        self.gloss = gloss
        self.cornerRadius = cornerRadius
        self.pressedScale = pressedScale
        self.hapticFeedback = hapticFeedback
    }
}

public enum ThumbleSkinComponentKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case canvasBackground = "canvas_background"
    case controllerShell = "controller_shell"
    case controlWell = "control_well"
    case buttonFace = "button_face"
    case dpad
    case joystick
    case utilityButton = "utility_button"
    case decorativeArtwork = "decorative_artwork"

    public var id: String { rawValue }
}

public struct ThumbleSkinComponentSpec: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: ThumbleSkinComponentKind
    public var materialID: String
    public var role: GamepadVisualRole?
    public var button: KeypadElementID?
    public var frame: ThumbleNormalizedRect?
    public var shape: GamepadButtonShapeStyle?
    public var zIndex: Int
    public var sourceAssetID: String?
    public var label: String?

    public init(
        id: String,
        kind: ThumbleSkinComponentKind,
        materialID: String,
        role: GamepadVisualRole? = nil,
        button: KeypadElementID? = nil,
        frame: ThumbleNormalizedRect? = nil,
        shape: GamepadButtonShapeStyle? = nil,
        zIndex: Int = 0,
        sourceAssetID: String? = nil,
        label: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.materialID = materialID
        self.role = role
        self.button = button
        self.frame = frame
        self.shape = shape
        self.zIndex = zIndex
        self.sourceAssetID = sourceAssetID
        self.label = label
    }
}

public enum ThumbleSkinRasterFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case png
    case webp

    public var id: String { rawValue }
}

public enum ThumbleSkinAssetPurpose: String, Codable, CaseIterable, Identifiable, Sendable {
    case canvasArtwork = "canvas_artwork"
    case controlFace = "control_face"
    case icon
    case texture
    case preview

    public var id: String { rawValue }
}

/// A compile-time passive-artwork anchor. It references appearance identity, never routing.
public final class ThumbleSkinArtworkAnchor: Codable, Equatable, Sendable {
    public let controlID: String?
    public let action: String?
    public let group: String?
    public let scaleX: CGFloat
    public let scaleY: CGFloat
    public let offsetX: CGFloat
    public let offsetY: CGFloat
    public let plane: ThumbleSkinArtworkPlane
    public let opacity: CGFloat
    public let zIndex: Int

    public init(controlID: String? = nil, action: String? = nil, group: String? = nil,
                scaleX: CGFloat = 1, scaleY: CGFloat = 1, offsetX: CGFloat = 0, offsetY: CGFloat = 0,
                plane: ThumbleSkinArtworkPlane = .underlay, opacity: CGFloat = 1, zIndex: Int = 0) {
        self.controlID = controlID; self.action = action; self.group = group
        self.scaleX = scaleX; self.scaleY = scaleY; self.offsetX = offsetX; self.offsetY = offsetY
        self.plane = plane; self.opacity = opacity; self.zIndex = zIndex
    }
    public static func == (lhs: ThumbleSkinArtworkAnchor, rhs: ThumbleSkinArtworkAnchor) -> Bool {
        lhs.controlID == rhs.controlID && lhs.action == rhs.action && lhs.group == rhs.group
            && lhs.scaleX == rhs.scaleX && lhs.scaleY == rhs.scaleY && lhs.offsetX == rhs.offsetX
            && lhs.offsetY == rhs.offsetY && lhs.plane == rhs.plane && lhs.opacity == rhs.opacity && lhs.zIndex == rhs.zIndex
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case controlID, action, group, scaleX, scaleY, offsetX, offsetY, plane, opacity, zIndex
    }
    private struct Key: CodingKey {
        let stringValue: String; let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    public convenience init(from decoder: Decoder) throws {
        let all = try decoder.container(keyedBy: Key.self)
        guard Set(all.allKeys.map(\.stringValue)).isSubset(of: Set(CodingKeys.allCases.map(\.rawValue))) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unsupported artwork anchor field."))
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(controlID: try c.decodeIfPresent(String.self, forKey: .controlID),
            action: try c.decodeIfPresent(String.self, forKey: .action), group: try c.decodeIfPresent(String.self, forKey: .group),
            scaleX: try c.decodeIfPresent(CGFloat.self, forKey: .scaleX) ?? 1,
            scaleY: try c.decodeIfPresent(CGFloat.self, forKey: .scaleY) ?? 1,
            offsetX: try c.decodeIfPresent(CGFloat.self, forKey: .offsetX) ?? 0,
            offsetY: try c.decodeIfPresent(CGFloat.self, forKey: .offsetY) ?? 0,
            plane: try c.decodeIfPresent(ThumbleSkinArtworkPlane.self, forKey: .plane) ?? .underlay,
            opacity: try c.decodeIfPresent(CGFloat.self, forKey: .opacity) ?? 1,
            zIndex: try c.decodeIfPresent(Int.self, forKey: .zIndex) ?? 0)
    }

    public func resolvedFrame(in variant: ThumbleSkinArtboardVariant,
                              semantics: [ThumbleSkinControlSemantics]) throws -> ThumbleNormalizedRect {
        guard variant.controls.count <= 256, semantics.count <= 256,
              [controlID, action, group].compactMap({ $0 }).count == 1,
              [scaleX, scaleY].allSatisfy({ $0.isFinite && (0.25...4).contains($0) }),
              [offsetX, offsetY].allSatisfy({ $0.isFinite && (-1...1).contains($0) }),
              opacity.isFinite, (0...1).contains(opacity), (-10_000...10_000).contains(zIndex),
              controlID.map({ !$0.isEmpty && $0.utf8.count <= 128 }) ?? true,
              [action, group].compactMap({ $0 }).allSatisfy({ tag in
                  !tag.isEmpty && tag.utf8.count <= 64 && tag.unicodeScalars.allSatisfy {
                      $0.value >= 97 && $0.value <= 122 || $0.value >= 48 && $0.value <= 57 || [45, 46, 95].contains($0.value)
                  }
              }) else { throw ThumbleSkinAnchorError.invalid("Artwork anchors require one exact target and bounded finite transforms.") }
        let ids: Set<String>
        if let controlID { ids = [controlID] }
        else {
            let effective = variant.controls.compactMap { control in
                semantics.first { $0.controlID == control.id }
                    ?? control.presentation.map { ThumbleSkinControlSemantics(controlID: control.id, action: $0.actionID, purpose: $0.purposeID, groups: $0.groupIDs) }
            }
            ids = Set(effective.filter { action != nil ? $0.action == action : $0.groups.contains(group ?? "") }.map(\.controlID))
        }
        let controls = variant.controls.filter { ids.contains($0.id) }
        guard !controls.isEmpty, controls.count <= 32 else {
            throw ThumbleSkinAnchorError.invalid("Artwork anchor targets must resolve to 1...32 visible controls in every selected orientation.")
        }
        let left = controls.map { $0.frame.x }.min() ?? 0
        let top = controls.map { $0.frame.y }.min() ?? 0
        let right = controls.map { $0.frame.x + $0.frame.width }.max() ?? 0
        let bottom = controls.map { $0.frame.y + $0.frame.height }.max() ?? 0
        let width = right - left, height = bottom - top
        let frame = ThumbleNormalizedRect(x: left + width * (0.5 + offsetX - scaleX / 2),
            y: top + height * (0.5 + offsetY - scaleY / 2), width: width * scaleX, height: height * scaleY)
        guard frame.width > 0, frame.height > 0, frame.x >= 0, frame.y >= 0,
              frame.x + frame.width <= 1.000001, frame.y + frame.height <= 1.000001 else {
            throw ThumbleSkinAnchorError.invalid("Anchored artwork must remain within the captured canvas; transforms are never silently clamped.")
        }
        return frame
    }
}
public enum ThumbleSkinAnchorError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { switch self { case .invalid(let message): message } }
}

public struct ThumbleSkinSourceAsset: Codable, Equatable, Identifiable, Sendable {
    public var anchor: ThumbleSkinArtworkAnchor?
    public var id: String
    public var path: String
    public var purpose: ThumbleSkinAssetPurpose
    public var outputWidth: Int
    public var outputHeight: Int
    public var format: ThumbleSkinRasterFormat
    public var nineSliceInsets: ThumbleNormalizedInsets?
    public var orientation: ThumbleSkinOrientation?
    public var colorScheme: ThumbleSkinColorScheme?

    public init(
        id: String,
        path: String,
        purpose: ThumbleSkinAssetPurpose,
        outputWidth: Int,
        outputHeight: Int,
        format: ThumbleSkinRasterFormat = .png,
        nineSliceInsets: ThumbleNormalizedInsets? = nil,
        orientation: ThumbleSkinOrientation? = nil,
        colorScheme: ThumbleSkinColorScheme? = nil,
        anchor: ThumbleSkinArtworkAnchor? = nil
    ) {
        self.anchor = anchor
        self.id = id
        self.path = path
        self.purpose = purpose
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        self.format = format
        self.nineSliceInsets = nineSliceInsets
        self.orientation = orientation
        self.colorScheme = colorScheme
    }
}

public struct ThumbleSemanticStyleAssignment: Codable, Equatable, Sendable {
    public var role: GamepadVisualRole?
    public var button: KeypadElementID?
    public var materialID: String
    public var componentID: String?

    public init(
        role: GamepadVisualRole? = nil,
        button: KeypadElementID? = nil,
        materialID: String,
        componentID: String? = nil
    ) {
        self.role = role
        self.button = button
        self.materialID = materialID
        self.componentID = componentID
    }
}

public enum ThumblePreviewState: String, Codable, CaseIterable, Identifiable, Sendable {
    case normal
    case pressed
    case active
    case disabled

    public var id: String { rawValue }
}

public struct ThumblePreviewRequest: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var artboardID: String
    public var orientation: ThumbleSkinOrientation
    public var colorScheme: ThumbleSkinColorScheme
    public var state: ThumblePreviewState
    public var scale: CGFloat

    public init(
        id: String,
        artboardID: String,
        orientation: ThumbleSkinOrientation,
        colorScheme: ThumbleSkinColorScheme,
        state: ThumblePreviewState = .normal,
        scale: CGFloat = 2
    ) {
        self.id = id
        self.artboardID = artboardID
        self.orientation = orientation
        self.colorScheme = colorScheme
        self.state = state
        self.scale = scale
    }
}

/// Appearance selection metadata, attached to exact artboard identities. These tags never
/// participate in input routing or executable output mappings.
public struct ThumbleSkinControlSemantics: Codable, Equatable, Sendable {
    public var controlID: String
    public var action: String?
    public var purpose: String?
    public var groups: [String]

    public init(controlID: String, action: String? = nil, purpose: String? = nil, groups: [String] = []) {
        self.controlID = controlID
        self.action = action
        self.purpose = purpose
        self.groups = groups
    }
}

public struct ThumbleSkinWorkspace: Codable, Equatable, Sendable {
    public var schema: String
    public var schemaVersion: Int
    public var identifier: String
    public var version: String
    public var name: String
    public var author: ThumbleSkinAuthor
    public var summary: String
    public var license: String
    public var artboardID: String
    public var orientations: [ThumbleSkinOrientation]
    public var colorSchemes: [ThumbleSkinColorScheme]
    public var palette: [ThumbleSkinPaletteToken]
    public var materials: [ThumbleSkinMaterialSpec]
    public var components: [ThumbleSkinComponentSpec]
    public var assignments: [ThumbleSemanticStyleAssignment]
    public var sourceAssets: [ThumbleSkinSourceAsset]
    /// CSS authoring (schema 2): paths relative to the workspace root, under `styles/`.
    public var stylesheets: [String]
    public var previews: [ThumblePreviewRequest]
    /// Source-only exact artboard. Array storage keeps the large contract off the stack.
    public var capturedArtboards: [ThumbleSkinArtboard]
    public var controlSemantics: [ThumbleSkinControlSemantics]

    public init(
        schema: String = ThumbleSkinWorkspaceSchema.identifier,
        schemaVersion: Int = ThumbleSkinWorkspaceSchema.currentVersion,
        identifier: String,
        version: String = "1.0.0",
        name: String,
        author: ThumbleSkinAuthor,
        summary: String,
        license: String = "All Rights Reserved",
        artboardID: String = "showcase-controller-v1",
        orientations: [ThumbleSkinOrientation] = [.landscape, .portrait],
        colorSchemes: [ThumbleSkinColorScheme] = [.light, .dark],
        palette: [ThumbleSkinPaletteToken] = [],
        materials: [ThumbleSkinMaterialSpec] = [],
        components: [ThumbleSkinComponentSpec] = [],
        assignments: [ThumbleSemanticStyleAssignment] = [],
        sourceAssets: [ThumbleSkinSourceAsset] = [],
        stylesheets: [String] = [],
        previews: [ThumblePreviewRequest] = [],
        capturedArtboards: [ThumbleSkinArtboard] = [],
        controlSemantics: [ThumbleSkinControlSemantics] = []
    ) {
        self.schema = schema
        self.schemaVersion = schemaVersion
        self.identifier = identifier
        self.version = version
        self.name = name
        self.author = author
        self.summary = summary
        self.license = license
        self.artboardID = artboardID
        self.orientations = orientations
        self.colorSchemes = colorSchemes
        self.palette = palette
        self.materials = materials
        self.components = components
        self.assignments = assignments
        self.sourceAssets = sourceAssets
        self.stylesheets = stylesheets
        self.previews = previews
        self.capturedArtboards = capturedArtboards
        self.controlSemantics = controlSemantics
    }

    private enum CodingKeys: String, CodingKey {
        case schema, schemaVersion, identifier, version, name, author, summary, license, artboardID
        case orientations, colorSchemes, palette, materials, components, assignments, sourceAssets
        case stylesheets, previews, capturedArtboards, controlSemantics
    }

    public var usesCSSAuthoring: Bool { !stylesheets.isEmpty }

    public var resolvedArtboard: ThumbleSkinArtboard? {
        if !capturedArtboards.isEmpty {
            guard capturedArtboards.count == 1, capturedArtboards[0].id == artboardID else { return nil }
            return capturedArtboards[0]
        }
        return ThumbleSkinArtboardCatalog.resolve(artboardID)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decodeIfPresent(String.self, forKey: .schema) ?? ThumbleSkinWorkspaceSchema.identifier
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        identifier = try container.decode(String.self, forKey: .identifier)
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? "1.0.0"
        name = try container.decode(String.self, forKey: .name)
        author = try container.decodeIfPresent(ThumbleSkinAuthor.self, forKey: .author) ?? ThumbleSkinAuthor(name: "Unknown Creator")
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        license = try container.decodeIfPresent(String.self, forKey: .license) ?? "All Rights Reserved"
        artboardID = try container.decodeIfPresent(String.self, forKey: .artboardID) ?? "showcase-controller-v1"
        orientations = try container.decodeIfPresent([ThumbleSkinOrientation].self, forKey: .orientations) ?? [.landscape]
        colorSchemes = try container.decodeIfPresent([ThumbleSkinColorScheme].self, forKey: .colorSchemes) ?? [.light, .dark]
        palette = try container.decodeIfPresent([ThumbleSkinPaletteToken].self, forKey: .palette) ?? []
        materials = try container.decodeIfPresent([ThumbleSkinMaterialSpec].self, forKey: .materials) ?? []
        components = try container.decodeIfPresent([ThumbleSkinComponentSpec].self, forKey: .components) ?? []
        assignments = try container.decodeIfPresent([ThumbleSemanticStyleAssignment].self, forKey: .assignments) ?? []
        sourceAssets = try container.decodeIfPresent([ThumbleSkinSourceAsset].self, forKey: .sourceAssets) ?? []
        stylesheets = try container.decodeIfPresent([String].self, forKey: .stylesheets) ?? []
        previews = try container.decodeIfPresent([ThumblePreviewRequest].self, forKey: .previews) ?? []
        capturedArtboards = try container.decodeIfPresent([ThumbleSkinArtboard].self, forKey: .capturedArtboards) ?? []
        controlSemantics = try container.decodeIfPresent([ThumbleSkinControlSemantics].self, forKey: .controlSemantics) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(identifier, forKey: .identifier)
        try container.encode(version, forKey: .version)
        try container.encode(name, forKey: .name)
        try container.encode(author, forKey: .author)
        try container.encode(summary, forKey: .summary)
        try container.encode(license, forKey: .license)
        try container.encode(artboardID, forKey: .artboardID)
        try container.encode(orientations, forKey: .orientations)
        try container.encode(colorSchemes, forKey: .colorSchemes)
        try container.encode(palette, forKey: .palette)
        try container.encode(materials, forKey: .materials)
        try container.encode(components, forKey: .components)
        try container.encode(assignments, forKey: .assignments)
        try container.encode(sourceAssets, forKey: .sourceAssets)
        if !stylesheets.isEmpty {
            try container.encode(stylesheets, forKey: .stylesheets)
        }
        try container.encode(previews, forKey: .previews)
        if !capturedArtboards.isEmpty { try container.encode(capturedArtboards, forKey: .capturedArtboards) }
        if !controlSemantics.isEmpty { try container.encode(controlSemantics, forKey: .controlSemantics) }
    }

    public static func starter(name: String, identifier: String, artboardID: String) -> ThumbleSkinWorkspace {
        let body = ThumbleSkinMaterialSpec(
            id: "shell",
            name: "Controller Shell",
            kind: .translucentPlastic,
            baseColor: "#433878",
            darkBaseColor: "#211A46",
            foregroundColor: "#F7F1FF",
            strokeColor: "#8E7BC7",
            highlightColor: "#B7A7E8",
            shadowColor: "#100C27",
            depth: 0.8,
            gloss: 0.62,
            cornerRadius: 36,
            pressedScale: 0.99
        )
        let rubber = ThumbleSkinMaterialSpec(
            id: "rubber",
            name: "Movement Rubber",
            kind: .matteRubber,
            baseColor: "#29243B",
            darkBaseColor: "#171421",
            foregroundColor: "#F2ECFF",
            strokeColor: "#5E5574",
            highlightColor: "#6F6685",
            shadowColor: "#08070D",
            depth: 0.55,
            gloss: 0.08,
            cornerRadius: 14,
            pressedScale: 0.965,
            hapticFeedback: GamepadHapticFeedback(style: .rigid, pattern: .single, intensity: 0.55, sharpness: 0.8)
        )
        let candy = ThumbleSkinMaterialSpec(
            id: "candy",
            name: "Glossy Action Plastic",
            kind: .glossyPlastic,
            baseColor: "#D95F91",
            darkBaseColor: "#A83D6A",
            foregroundColor: "#FFFFFF",
            strokeColor: "#FFB1D0",
            highlightColor: "#FFFFFF",
            shadowColor: "#49152D",
            depth: 0.9,
            gloss: 0.88,
            pressedScale: 0.94,
            hapticFeedback: GamepadHapticFeedback(style: .medium, pattern: .single, intensity: 0.62, sharpness: 0.54)
        )
        let utility = ThumbleSkinMaterialSpec(
            id: "utility",
            name: "Utility Rubber",
            kind: .inset,
            baseColor: "#4C4463",
            darkBaseColor: "#2C273A",
            foregroundColor: "#F5F0FF",
            strokeColor: "#776D91",
            depth: 0.35,
            gloss: 0.12,
            cornerRadius: 20,
            pressedScale: 0.97
        )
        return ThumbleSkinWorkspace(
            identifier: identifier,
            name: name,
            author: ThumbleSkinAuthor(name: "Your Name"),
            summary: "A handcrafted controller skin built from a canonical Thumble artboard.",
            license: "All Rights Reserved",
            artboardID: artboardID,
            palette: [
                ThumbleSkinPaletteToken(id: "indigo", light: "#433878", dark: "#211A46"),
                ThumbleSkinPaletteToken(id: "candy", light: "#D95F91", dark: "#A83D6A"),
                ThumbleSkinPaletteToken(id: "rubber", light: "#29243B", dark: "#171421")
            ],
            materials: [body, rubber, candy, utility],
            components: [
                ThumbleSkinComponentSpec(
                    id: "shell-plate",
                    kind: .controllerShell,
                    materialID: "shell",
                    frame: ThumbleNormalizedRect(x: 0.025, y: 0.075, width: 0.95, height: 0.85),
                    shape: .roundedRectangle,
                    zIndex: -100
                ),
                ThumbleSkinComponentSpec(
                    id: "movement-well",
                    kind: .controlWell,
                    materialID: "rubber",
                    role: .movement,
                    frame: ThumbleNormalizedRect(x: 0.055, y: 0.22, width: 0.30, height: 0.60),
                    shape: .circle,
                    zIndex: -50
                ),
                ThumbleSkinComponentSpec(
                    id: "action-well",
                    kind: .controlWell,
                    materialID: "shell",
                    role: .primaryAction,
                    frame: ThumbleNormalizedRect(x: 0.66, y: 0.20, width: 0.30, height: 0.62),
                    shape: .circle,
                    zIndex: -50
                )
            ],
            assignments: [
                ThumbleSemanticStyleAssignment(role: .movement, materialID: "rubber"),
                ThumbleSemanticStyleAssignment(role: .primaryAction, materialID: "candy"),
                ThumbleSemanticStyleAssignment(role: .secondaryAction, materialID: "candy"),
                ThumbleSemanticStyleAssignment(role: .utility, materialID: "utility"),
                ThumbleSemanticStyleAssignment(role: .menu, materialID: "utility"),
                ThumbleSemanticStyleAssignment(role: .joystick, materialID: "rubber"),
                ThumbleSemanticStyleAssignment(role: .trigger, materialID: "utility"),
                ThumbleSemanticStyleAssignment(role: .trackpad, materialID: "rubber"),
                ThumbleSemanticStyleAssignment(role: .custom, materialID: "utility")
            ],
            sourceAssets: [
                ThumbleSkinSourceAsset(
                    id: "accent-lines",
                    path: "sources/artwork/accent-lines.svg",
                    purpose: .canvasArtwork,
                    outputWidth: 1748,
                    outputHeight: 804
                )
            ],
            previews: [
                ThumblePreviewRequest(id: "landscape-light-normal", artboardID: artboardID, orientation: .landscape, colorScheme: .light),
                ThumblePreviewRequest(id: "landscape-dark-normal", artboardID: artboardID, orientation: .landscape, colorScheme: .dark),
                ThumblePreviewRequest(id: "portrait-light-normal", artboardID: artboardID, orientation: .portrait, colorScheme: .light),
                ThumblePreviewRequest(id: "portrait-dark-normal", artboardID: artboardID, orientation: .portrait, colorScheme: .dark)
            ]
        )
    }

    /// Schema-2 workspace whose control styling comes entirely from CSS.
    public static func starterCSS(name: String, identifier: String, artboardID: String) -> ThumbleSkinWorkspace {
        var workspace = ThumbleSkinWorkspace(
            schemaVersion: 2,
            identifier: identifier,
            name: name,
            author: ThumbleSkinAuthor(name: "Your Name"),
            summary: "A CSS-authored controller skin built from a canonical Thumble artboard.",
            license: "All Rights Reserved",
            artboardID: artboardID,
            palette: [
                ThumbleSkinPaletteToken(id: "surface", light: "#F2EEF5", dark: "#211A46"),
                ThumbleSkinPaletteToken(id: "accent", light: "#7C61A8", dark: "#A77CFF")
            ],
            materials: [],
            components: [],
            assignments: [],
            sourceAssets: [],
            stylesheets: ["styles/controller.css"],
            previews: [
                ThumblePreviewRequest(id: "landscape-light-normal", artboardID: artboardID, orientation: .landscape, colorScheme: .light),
                ThumblePreviewRequest(id: "landscape-dark-normal", artboardID: artboardID, orientation: .landscape, colorScheme: .dark),
                ThumblePreviewRequest(id: "portrait-light-normal", artboardID: artboardID, orientation: .portrait, colorScheme: .light),
                ThumblePreviewRequest(id: "portrait-dark-normal", artboardID: artboardID, orientation: .portrait, colorScheme: .dark)
            ]
        )
        workspace.schemaVersion = 2
        return workspace
    }
}

/// Box native interaction geometry so captured contracts do not grow control
/// aggregates on constrained Swift threads. This is a resolver rectangle, not a
/// replacement for native gesture routing or hit-shape behavior.
public final class ThumbleSkinArtboardNativeGeometry: Codable, Equatable, Sendable {
    public let hitFrame: ThumbleNormalizedRect
    public let scope: String
    public init(hitFrame: ThumbleNormalizedRect) {
        self.hitFrame = hitFrame
        scope = "normalized native resolver hit rectangle; canvas coordinates before separate control rotation; not gesture ownership or an exact hit shape; bounds may extend beyond the viewport"
    }
    public static func == (lhs: ThumbleSkinArtboardNativeGeometry, rhs: ThumbleSkinArtboardNativeGeometry) -> Bool {
        lhs.hitFrame == rhs.hitFrame && lhs.scope == rhs.scope
    }
}

/// Immutable baseline surface contract. Native flow boxes are measured at review;
/// primitive boxes are local control points, before parent scale and rotation.
public final class ThumbleSkinArtboardNativeSurfaces: Codable, Equatable, Sendable {
    public struct Sample: Codable, Equatable, Sendable {
        public let colorScheme: ThumbleSkinColorScheme
        public let state: GamepadControlPresentationState
        public let surfaceIDs: [String]
        public let localFrames: [String: CGRect]
        public let effectiveFaceScale: CGFloat
        public let fixedProperties: [String: CGFloat]
    }
    public let schemaVersion: Int
    public let samples: [Sample]
    public let potentialSurfaceIDs: [String]
    public let supportedProperties: [String: [String]]
    public let limitations: [String]
    init(control: GamepadResolvedControl, customization: GamepadCustomization) {
        var captured: [Sample] = []
        for scheme in ThumbleSkinColorScheme.allCases {
            for state in GamepadControlPresentationState.allCases {
                let appearance = customization.resolvedPresentation(for: control, state: state,
                    scheme: scheme == .dark ? .dark : .light)
                let native = GamepadNativeContentPresentation(control: control,
                    showsButtonLabels: customization.showsButtonLabels, content: appearance.content,
                    icon: appearance.icon, state: state, scheme: scheme == .dark ? .dark : .light,
                    authoredScale: appearance.scale, foregroundColor: appearance.foregroundColor,
                    profileAccentStyle: customization.accentStyle)
                var frames = native.localSurfaceFrames
                if !control.isText { frames["face"] = CGRect(origin: .zero, size: control.size) }
                captured.append(.init(colorScheme: scheme, state: state, surfaceIDs: native.visibleSurfaceIDs,
                    localFrames: frames, effectiveFaceScale: native.effectiveFaceScale ?? appearance.scale, fixedProperties: native.fixedProperties))
            }
        }
        schemaVersion = 1
        samples = captured
        var potential = Set(captured.flatMap(\.surfaceIDs))
        if !control.isDecoration {
            potential.insert("legend")
            if control.presentationMetadata?.caption?.isEmpty == false { potential.insert("caption") }
            if control.inputID != nil && !control.isText { potential.insert("binding-hint") }
        }
        if !control.isText && !control.isJoystick && !control.isTrackpad { potential.insert("icon") }
        if control.isJoystick { potential.insert("joystick-well-ring") }
        if control.isTrackpad { potential.formUnion(["trackpad-frame", "trackpad-cursor", "trackpad-indicators"]) }
        potentialSurfaceIDs = potential.sorted()
        let face = ["fillStyle", "foregroundColor", "strokeColor", "strokeWidth", "opacity", "scale", "blurRadius", "shadows", "shadowColor", "shadowRadius", "shadowX", "shadowY", "glowColor", "glowRadius", "innerShadowColor", "innerShadowRadius", "innerShadowX", "innerShadowY", "highlightColor", "highlightRadius", "highlightX", "highlightY", "highlightOpacity", "bevelHighlightColor", "bevelShadowColor", "bevelWidth", "indexColor", "indexWidth"]
        let inherited = ["face.foregroundColor", "face.opacity", "face.scale", "face.blurRadius"]
        let properties: [String: [String]] = [
            "face": face,
            "legend": ["legend", "fontSize", "fontWeight", "fontDesign", "tracking", "lineLimit", "alignment", "labelPadding", "labelPlacement"] + inherited,
            "caption": inherited,
            "binding-hint": inherited,
            "icon": ["icon.source", "icon.value", "icon.placement", "icon.scale", "icon.tintColor", "icon.renderingMode"] + inherited,
            "joystick-puck": ["joystickKnobRatio", "joystickKnobStrokeWidth", "joystickKnobFillColor", "joystickKnobStrokeColor", "face.opacity", "face.scale"],
            "joystick-well-ring": ["joystickRingVisible", "joystickRingColor", "joystickRingStrokeWidth", "face.opacity", "face.scale"],
            "trackpad-frame": ["trackpadFrameVisible", "trackpadFrameColor", "trackpadFrameStrokeWidth", "face.opacity", "face.scale"],
            "trackpad-cursor": ["trackpadCursorVisible", "trackpadCursorColor", "face.opacity", "face.scale"],
            "trackpad-indicators": ["trackpadIndicatorsVisible", "trackpadIndicatorColor", "trackpadSecondaryIndicatorColor", "face.opacity", "face.scale"],
            "trigger-fill": ["face.foregroundColor", "face.opacity", "face.scale"]]
        supportedProperties = properties.filter { potential.contains($0.key) }
        limitations = [
            "baseline frozen profile appearance in both schemes and four settled states; source skin edits can alter eligibility and style",
            "surface IDs describe eligible native paint before alpha or inter-layer occlusion; prefix IDs with the owning control ID",
            "localFrames are primitive layout in control points before parent state/authored scale and rotation; native capture stores baseline flow frames in variant.nativeLayout; source-edited flow frames require native review",
            "optional binding hints depend on separate frozen outputs and review input; hint text is excluded from this appearance contract",
            "property names refer to the native model; inherited face properties affect the whole control",
            "caption and binding-hint font size 10, medium monospaced, line limit 1, minimum scale 0.5 and foreground opacity 0.76 are fixed",
            "native ring diameter, cursor font size, indicator geometry, trigger opacity and touch-count feedback retain fixed native rules",
            "icon fit/mask/padding, scripts, remote fonts and CSS hit testing are unsupported; selected fonts and exact gesture ownership are unmeasured"]
    }
    public static func == (lhs: ThumbleSkinArtboardNativeSurfaces, rhs: ThumbleSkinArtboardNativeSurfaces) -> Bool {
        lhs.schemaVersion == rhs.schemaVersion && lhs.samples == rhs.samples && lhs.potentialSurfaceIDs == rhs.potentialSurfaceIDs
            && lhs.supportedProperties == rhs.supportedProperties && lhs.limitations == rhs.limitations
    }
}

public struct ThumbleSkinArtboardControl: Codable, Equatable, Identifiable, Sendable {
    public var presentation: GamepadControlPresentation? = nil
    public var nativeGeometry: ThumbleSkinArtboardNativeGeometry? = nil
    public var nativeSurfaces: ThumbleSkinArtboardNativeSurfaces? = nil
    public var id: String
    public var label: String
    public var kind: GamepadCustomControlKind
    public var visualRole: GamepadVisualRole
    public var inputID: KeypadElementID?
    public var frame: ThumbleNormalizedRect
    public var rotationDegrees: CGFloat? = nil

    public init(
        id: String,
        label: String,
        kind: GamepadCustomControlKind,
        visualRole: GamepadVisualRole,
        inputID: KeypadElementID?,
        frame: ThumbleNormalizedRect,
        rotationDegrees: CGFloat? = nil,
        presentation: GamepadControlPresentation? = nil,
        nativeGeometry: ThumbleSkinArtboardNativeGeometry? = nil,
        nativeSurfaces: ThumbleSkinArtboardNativeSurfaces? = nil
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.visualRole = visualRole
        self.inputID = inputID
        self.frame = frame
        self.rotationDegrees = rotationDegrees
        self.presentation = presentation
        self.nativeGeometry = nativeGeometry
        self.nativeSurfaces = nativeSurfaces
    }
}

/// Baseline viewport and native chrome inventory. Dynamic native layout is
/// measured by review; these identifiers never become executable input aliases.
public final class ThumbleSkinArtboardNativeChrome: Codable, Equatable, Sendable {
    public struct Visibility: Codable, Equatable, Sendable {
        public let isConnected: Bool
        public let isEditing: Bool
        public let requestedClosedResolvesOpen: Bool
        public let requestedOpenResolvesOpen: Bool
    }
    public let schemaVersion: Int
    public let canvasFrame: CGRect
    public let canvasFills: [String: GamepadFillStyle]
    public let containerPresentation: [String: GamepadNativeBarContainerPresentation]?
    public let revealControlID: String?
    public let revealArtboardFrame: CGRect?
    public let revealSurfaces: ThumbleSkinArtboardNativeSurfaces?
    public let surfaceIDs: [String]
    public let potentialSurfaceIDs: [String]
    public let visibleBarItems: [GamepadControlBarItem]
    public let drawerVisibility: [Visibility]
    public let baselineDrawerPadding: [String: CGFloat]
    public let supportedProperties: [String: [String]]
    public let limitations: [String]
    init(customization: GamepadCustomization, orientation: ThumbleSkinOrientation,
         canvasSize: CGSize, safeAreaInsets: ThumbleNormalizedInsets, hasLaunchTarget: Bool) {
        schemaVersion = 1
        canvasFrame = CGRect(origin: .zero, size: canvasSize)
        containerPresentation = Dictionary(uniqueKeysWithValues: ThumbleSkinColorScheme.allCases.map {
            ($0.rawValue, GamepadNativeBarContainerPresentation(isLandscape: orientation == .landscape, colorScheme: $0 == .dark ? .dark : .light))
        })
        let normalized = customization.normalized
        let reveal = normalized.resolvedControls(in: canvasSize).first { $0.id == .system(.topBarActivation) }
        revealControlID = reveal?.id.id
        revealArtboardFrame = reveal?.frame
        revealSurfaces = reveal.map { ThumbleSkinArtboardNativeSurfaces(control: $0, customization: normalized) }
        canvasFills = Dictionary(uniqueKeysWithValues: ThumbleSkinColorScheme.allCases.map {
            ($0.rawValue, normalized.keypadBackgroundFillStyle(scheme: $0 == .dark ? .dark : .light))
        })
        let items = GamepadControllerPresentationRouting.visibleControlBarItems(normalized.controlBarItems,
            hiddenItems: Set(normalized.controlBarItems.filter { normalized.controlBarItemCustomization(for: $0).isHidden }),
            hasProfiles: true, hasLaunchTarget: hasLaunchTarget)
        visibleBarItems = items
        let painted = items.filter { $0 != .spacer }.map { "native-control-bar/" + $0.rawValue }
        let leaves = GamepadControllerPresentationRouting.barLeafSurfaceIDs(items: items,
            isLandscape: orientation == .landscape, customization: normalized)
        let optionalConnectionIcon = items.contains(.connectionAction) ? ["native-control-bar/connection/icon"] : []
        surfaceIDs = ["canvas", "native-control-bar", "native-drawer", "native-drawer/reveal"] + painted + leaves
        potentialSurfaceIDs = Set(surfaceIDs + optionalConnectionIcon + ["canvas/artwork-underlay", "canvas/artwork-overlay"]).sorted()
        var visibility: [Visibility] = []
        for connected in [false, true] {
            for editing in [false, true] {
                visibility.append(.init(isConnected: connected, isEditing: editing,
                    requestedClosedResolvesOpen: ControllerRuntimeChromePolicy.resolvedTopBarVisibility(
                        requestedVisibility: false, isConnected: connected, isEditingLayout: editing),
                    requestedOpenResolvesOpen: ControllerRuntimeChromePolicy.resolvedTopBarVisibility(
                        requestedVisibility: true, isConnected: connected, isEditingLayout: editing)))
            }
        }
        drawerVisibility = visibility
        let layout = GamepadTopBarDrawerLayout(safeAreaInsets: EdgeInsets(
            top: safeAreaInsets.top * canvasSize.height, leading: safeAreaInsets.leading * canvasSize.width,
            bottom: safeAreaInsets.bottom * canvasSize.height, trailing: safeAreaInsets.trailing * canvasSize.width),
            isLandscape: orientation == .landscape, minimumPortraitTopInset: 0)
        baselineDrawerPadding = ["top": layout.topPadding, "leading": layout.leadingPadding, "trailing": layout.trailingPadding]
        var properties: [String: [String]] = [
            "canvas": ["backgroundFillStyle"],
            "canvas/artwork-underlay": ["asset", "frame", "opacity", "zIndex", "plane"],
            "canvas/artwork-overlay": ["asset", "frame", "opacity", "zIndex", "plane"],
            "native-control-bar": [], "native-drawer": [], "native-drawer/reveal": []]
        for id in painted {
            properties[id] = ["appearance.shape", "appearance.cornerRadius", "appearance.cornerRadii", "appearance.accentStyle",
                "appearance.fillStyle", "appearance.lightFillStyle", "appearance.darkFillStyle", "appearance.fillColor", "appearance.lightFillColor", "appearance.darkFillColor", "appearance.styleID",
                "appearance.visualStyle", "appearance.widthScale", "appearance.heightScale", "appearance.shadowStrength"]
        }
        for id in painted where id != "native-control-bar/spacer" {
            properties[id, default: []] += ["appearance.icon.source", "appearance.icon.value", "appearance.icon.scale",
                "appearance.icon.tintColor", "appearance.icon.renderingMode"]
        }
        for id in potentialSurfaceIDs where id.hasSuffix("/legend") || id.hasSuffix("/icon") {
            properties[id] = id.hasSuffix("/icon") ? ["appearance.icon.source", "appearance.icon.value", "appearance.icon.scale",
                "appearance.icon.tintColor", "appearance.icon.renderingMode"] : []
        }
        supportedProperties = properties
        limitations = [
            "baseline viewport inventory; bar and drawer eligibility depends on visibility/context; spacers are layout-only",
            "canvasFrame is viewport layout, not ink; artwork planes permit source-skin layers whose exact layer IDs and transforms are resolved in review",
            "primitive inventory does not guess rectangles; native capture adds baseline bar/drawer/item layout in variant.nativeLayout; native capture also measures bar legend/icon leaves; source-edited placement and leaf layout require native review; ink, selected fonts and hit bounds remain separate",
            "reveal paint uses the included exact system control ID and revealSurfaces when the resolver supplies it; a hidden region yields nil paint metadata while the drawer button layout remains; revealArtboardFrame is static geometry and the drawer repositions it",
            "bar child property names refer to existing profile customization, not new CSS selectors; icons support SF symbols, text and local assets with scale/tint/rendering; placement is fixed by the native label tree, typography/content overrides are not consumed, and icon fit/mask/padding are not authored",
            "bar container shape, scheme-dependent Geist fill/stroke, spacing/padding and drawer shadow are fixed native chrome",
            "baseline drawer padding uses frozen safe areas and portrait minimum zero; review can explicitly sample a different minimum; live iPhone uses 54 and merges window insets",
            "connection/default-profile context, menus, popovers, animation, accessibility adaptations and exact gestures are not frozen from live UI state"]
    }
    public static func == (lhs: ThumbleSkinArtboardNativeChrome, rhs: ThumbleSkinArtboardNativeChrome) -> Bool {
        lhs.schemaVersion == rhs.schemaVersion && lhs.canvasFrame == rhs.canvasFrame && lhs.canvasFills == rhs.canvasFills
            && lhs.containerPresentation == rhs.containerPresentation && lhs.revealControlID == rhs.revealControlID && lhs.revealArtboardFrame == rhs.revealArtboardFrame && lhs.revealSurfaces == rhs.revealSurfaces
            && lhs.surfaceIDs == rhs.surfaceIDs && lhs.potentialSurfaceIDs == rhs.potentialSurfaceIDs
            && lhs.visibleBarItems == rhs.visibleBarItems && lhs.drawerVisibility == rhs.drawerVisibility
            && lhs.baselineDrawerPadding == rhs.baselineDrawerPadding && lhs.supportedProperties == rhs.supportedProperties
            && lhs.limitations == rhs.limitations
    }
}

/// Immutable baseline native measurements, captured before source authoring. Keeping the
/// matrix behind one reference preserves the artboard variant's inline-size budget.
public final class ThumbleSkinArtboardNativeLayout: Codable, Equatable, Sendable {
    public struct ControlSample: Codable, Equatable, Sendable {
        public let controlID: String
        public let colorScheme: ThumbleSkinColorScheme
        public let state: GamepadControlPresentationState
        public let flowFrames: [String: CGRect]
    }
    public struct ChromeSample: Codable, Equatable, Sendable {
        public var paint: GamepadNativeBarPaintEvidence? = nil
        public let kind: String
        public let colorScheme: ThumbleSkinColorScheme
        public let isConnected: Bool
        public let isEditing: Bool
        public let requestedVisibility: Bool?
        public let resolvedVisibility: Bool?
        public let frames: [String: CGRect]
        public let viewport: CGRect
    }
    public let schemaVersion: Int
    public let rendererSHA256: String
    public let renderScale: CGFloat
    public let controlSamples: [ControlSample]
    public let chromeSamples: [ChromeSample]
    public let scope: String
    init(rendererSHA256: String, controls: [ControlSample], chrome: [ChromeSample]) {
        schemaVersion = 1; self.rendererSHA256 = rendererSHA256; renderScale = 1
        controlSamples = controls; chromeSamples = chrome
        scope = "frozen profile baseline at native 1x; flow leaf frames in canvas points including parent scale/rotation; standalone bar frames in bar-image points, drawer frames in canvas points; both schemes and four control states; connected/offline and editing on/off; drawer requested closed/open, opacity 1, portrait minimum 0, default-profile false; no binding hints, selected fonts, glyph ink, hit shapes, animations, menus or live device adaptations; source revisions are resolved separately in review"
    }
    public static func == (lhs: ThumbleSkinArtboardNativeLayout, rhs: ThumbleSkinArtboardNativeLayout) -> Bool {
        lhs.schemaVersion == rhs.schemaVersion && lhs.rendererSHA256 == rhs.rendererSHA256 && lhs.renderScale == rhs.renderScale
            && lhs.controlSamples == rhs.controlSamples && lhs.chromeSamples == rhs.chromeSamples && lhs.scope == rhs.scope
    }
}

public struct ThumbleSkinArtboardVariant: Codable, Equatable, Identifiable, Sendable {
    public var nativeLayout: ThumbleSkinArtboardNativeLayout? = nil
    public var nativeChrome: ThumbleSkinArtboardNativeChrome? = nil
    public var id: String
    public var orientation: ThumbleSkinOrientation
    public var canvasWidth: CGFloat
    public var canvasHeight: CGFloat
    public var safeAreaInsets: ThumbleNormalizedInsets
    public var controls: [ThumbleSkinArtboardControl]

    public init(
        id: String,
        orientation: ThumbleSkinOrientation,
        canvasWidth: CGFloat,
        canvasHeight: CGFloat,
        safeAreaInsets: ThumbleNormalizedInsets,
        controls: [ThumbleSkinArtboardControl],
        nativeChrome: ThumbleSkinArtboardNativeChrome? = nil,
        nativeLayout: ThumbleSkinArtboardNativeLayout? = nil
    ) {
        self.nativeLayout = nativeLayout
        self.id = id
        self.orientation = orientation
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.safeAreaInsets = safeAreaInsets
        self.controls = controls
        self.nativeChrome = nativeChrome
    }
}

public struct ThumbleSkinArtboard: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var revision: Int
    public var templateID: String
    public var name: String
    public var summary: String
    public var variants: [ThumbleSkinArtboardVariant]
    public var expectedRoles: [GamepadVisualRole]

    public init(
        id: String,
        revision: Int,
        templateID: String,
        name: String,
        summary: String,
        variants: [ThumbleSkinArtboardVariant],
        expectedRoles: [GamepadVisualRole]
    ) {
        self.id = id
        self.revision = revision
        self.templateID = templateID
        self.name = name
        self.summary = summary
        self.variants = variants
        self.expectedRoles = expectedRoles
    }
}

public enum ThumbleSkinArtboardCatalog {
    public static let defaultID = "showcase-controller-v1"

    public static var all: [ThumbleSkinArtboard] {
        let showcase = makeArtboard(
            id: defaultID,
            template: .snes,
            name: "Showcase Controller",
            summary: "Neutral 16-bit-style controller artboard used for deterministic skin previews."
        )
        let classic = makeArtboard(
            id: "classic-16-bit-v1",
            template: .snes,
            name: "Classic 16-Bit",
            summary: "D-pad, four face actions, two shoulders, and two utility controls."
        )
        let templates = GamepadControllerTemplate.allCases.map { template in
            makeArtboard(
                id: "\(kebabCase(template.rawValue))-v1",
                template: template,
                name: template.displayName,
                summary: template.description
            )
        }
        var seen = Set<String>()
        return ([showcase, classic] + templates).filter { seen.insert($0.id).inserted }
    }

    public static func resolve(_ value: String) -> ThumbleSkinArtboard? {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return all.first {
            $0.id.lowercased() == key
                || $0.name.lowercased() == key
                || $0.templateID.lowercased() == key
        }
    }

    public static func profile(for artboardID: String) -> GamepadConfigurationProfile? {
        guard let artboard = resolve(artboardID),
              let template = GamepadControllerTemplate.allCases.first(where: { $0.rawValue == artboard.templateID })
        else { return nil }
        return catalogProfile(template: template, id: artboard.id)
    }

    /// Preserve the two published catalog designs' authored role declarations. This is
    /// fixture metadata, not a fallback for arbitrary profiles or remapped controls.
    private static func catalogProfile(template: GamepadControllerTemplate, id: String) -> GamepadConfigurationProfile {
        var profile = stabilized(completingOrientations(template.makeProfile()), seed: id)
        guard ["showcase-controller-v1", "classic-16-bit-v1"].contains(id) else { return profile }
        let declarations: [KeypadElementID: GamepadVisualRole] = [
            .preset(1): .movement, .preset(2): .movement, .preset(3): .movement, .preset(4): .movement,
            .preset(5): .primaryAction, .preset(6): .primaryAction,
            .preset(7): .secondaryAction, .preset(8): .secondaryAction,
            .preset(9): .utility, .preset(10): .menu]
        func declaring(_ source: GamepadCustomization) -> GamepadCustomization {
            var result = source
            for index in result.elements.indices {
                if let identity = result.elements[index].defaultControlID,
                   let role = declarations[identity] { result.elements[index].visualRole = role }
            }
            return result.normalized
        }
        profile.customization = declaring(profile.customization)
        if let landscape = profile.landscapeCustomization { profile.landscapeCustomization = declaring(landscape) }
        if let portrait = profile.portraitCustomization { profile.portraitCustomization = declaring(portrait) }
        return profile
    }

    private static func makeArtboard(
        id: String,
        template: GamepadControllerTemplate,
        name: String,
        summary: String
    ) -> ThumbleSkinArtboard {
        let profile = catalogProfile(template: template, id: id)
        let availableOrientations: [(ThumbleSkinOrientation, GamepadCustomization)] = {
            var values: [(ThumbleSkinOrientation, GamepadCustomization)] = []
            if let landscape = profile.landscapeCustomization {
                values.append((.landscape, landscape))
            }
            if let portrait = profile.portraitCustomization {
                values.append((.portrait, portrait))
            }
            if values.isEmpty {
                let customization = profile.customization
                let orientation: ThumbleSkinOrientation = customization.deviceCanvas.editorDeviceFrame.orientation == .portrait ? .portrait : .landscape
                values.append((orientation, customization))
            }
            return values
        }()
        let variants = availableOrientations.map { orientation, customization in
            makeVariant(orientation: orientation, customization: customization)
        }
        let roles = Array(Set(variants.flatMap { $0.controls.map(\.visualRole) }))
            .sorted { $0.rawValue < $1.rawValue }
        return ThumbleSkinArtboard(
            id: id,
            revision: template.templateRevision,
            templateID: template.rawValue,
            name: name,
            summary: summary,
            variants: variants,
            expectedRoles: roles
        )
    }

    private static func makeVariant(
        orientation: ThumbleSkinOrientation,
        customization: GamepadCustomization
    ) -> ThumbleSkinArtboardVariant {
        let size = customization.deviceCanvas.editorDeviceFrame.screenRect.size
        let controls = customization.resolvedControls(in: size)
            .filter { !$0.layoutCustomization.isHidden }
            .enumerated()
            .map { index, control in
                let frame = control.frame
                let stableID: String
                switch control.id {
                case .builtin(let button): stableID = "builtin.\(button.rawValue)"
                case .custom: stableID = "custom.\(control.controlKind.rawValue).\(index)"
                case .system(let system): stableID = "system.\(system.rawValue)"
                case .controlBarItem(let item): stableID = "control-bar.\(item.rawValue)"
                }
        return ThumbleSkinArtboardControl(
                    id: stableID,
                    label: control.label,
                    kind: control.controlKind,
                    visualRole: control.visualRole,
                    inputID: control.inputID,
                    frame: ThumbleNormalizedRect(
                        x: frame.minX / max(size.width, 1),
                        y: frame.minY / max(size.height, 1),
                        width: frame.width / max(size.width, 1),
                        height: frame.height / max(size.height, 1)
                    ).normalized
                )
            }
        let safeArea: ThumbleNormalizedInsets = orientation == .portrait
            ? ThumbleNormalizedInsets(top: 0.055, leading: 0.025, bottom: 0.045, trailing: 0.025)
            : ThumbleNormalizedInsets(top: 0.035, leading: 0.045, bottom: 0.035, trailing: 0.045)
        return ThumbleSkinArtboardVariant(
            id: "\(orientation.rawValue)-v1",
            orientation: orientation,
            canvasWidth: size.width,
            canvasHeight: size.height,
            safeAreaInsets: safeArea,
            controls: controls
        )
    }

    private static func completingOrientations(
        _ original: GamepadConfigurationProfile
    ) -> GamepadConfigurationProfile {
        var profile = original
        let baseOrientation = profile.customization.deviceCanvas.editorDeviceFrame.orientation
        if baseOrientation == .landscape, profile.landscapeCustomization == nil {
            profile.landscapeCustomization = profile.customization
        } else if baseOrientation == .portrait, profile.portraitCustomization == nil {
            profile.portraitCustomization = profile.customization
        }
        if profile.portraitCustomization == nil {
            profile.copyLayoutVariant(from: .landscape, to: .portrait, automaticallyArrange: true)
        }
        if profile.landscapeCustomization == nil {
            profile.copyLayoutVariant(from: .portrait, to: .landscape, automaticallyArrange: true)
        }
        return profile
    }

    private static func stabilized(
        _ original: GamepadConfigurationProfile,
        seed: String
    ) -> GamepadConfigurationProfile {
        var profile = original
        profile.id = deterministicUUID("profile:\(seed)")
        profile.updatedAt = 0
        profile.customization = stabilized(profile.customization, seed: "\(seed):base")
        profile.landscapeCustomization = profile.landscapeCustomization.map { stabilized($0, seed: "\(seed):landscape") }
        profile.portraitCustomization = profile.portraitCustomization.map { stabilized($0, seed: "\(seed):portrait") }
        return profile.normalized
    }

    private static func stabilized(_ original: GamepadCustomization, seed: String) -> GamepadCustomization {
        var customization = original
        var replacements: [UUID: UUID] = [:]
        for index in customization.customButtons.indices {
            let oldID = customization.customButtons[index].id
            let newID = deterministicUUID("\(seed):custom:\(index):\(customization.customButtons[index].controlKind.rawValue)")
            customization.customButtons[index].id = newID
            replacements[oldID] = newID
        }
        customization.elements = customization.elements.map { element in
            var copy = element
            if let replacement = replacements[element.id] { copy.id = replacement }
            return copy
        }
        if var metadata = customization.designMetadata {
            metadata.layerOrder = metadata.layerOrder.map { identity in
                guard case .custom(let id) = identity, let replacement = replacements[id] else { return identity }
                return .custom(replacement)
            }
            metadata.groups = metadata.groups.map { group in
                var copy = group
                copy.children = group.children.map { identity in
                    guard case .custom(let id) = identity, let replacement = replacements[id] else { return identity }
                    return .custom(replacement)
                }
                return copy
            }
            customization.designMetadata = metadata
        }
        customization.updatedAt = 0
        return customization.normalized
    }

    private static func deterministicUUID(_ value: String) -> UUID {
        let digest = SHA256.hash(data: Data(value.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func kebabCase(_ value: String) -> String {
        var result = ""
        for character in value {
            if character.isUppercase {
                if !result.isEmpty { result.append("-") }
                result.append(character.lowercased())
            } else {
                result.append(character)
            }
        }
        return result
    }
}

public enum ThumbleSkinScaffoldError: Error, LocalizedError, Equatable {
    case invalidIdentity
    case unknownArtboard(String)
    case destinationNotEmpty(String)
    case cannotWrite(String)

    public var errorDescription: String? {
        switch self {
        case .invalidIdentity: "Skin scaffolds require a valid reverse-DNS identifier and semantic version."
        case .unknownArtboard(let value): "Unknown skin artboard: \(value)."
        case .destinationNotEmpty(let path): "Scaffold destination is not empty: \(path). Use --force to replace it."
        case .cannotWrite(let message): "Could not write skin scaffold: \(message)"
        }
    }
}

public enum ThumbleSkinScaffolder {
    public static let sourceFileName = "skin-source.json"

    @discardableResult
    public static func write(
        name: String,
        identifier: String,
        artboardID: String = ThumbleSkinArtboardCatalog.defaultID,
        to destination: URL,
        force: Bool = false,
        css: Bool = false,
        fileManager: FileManager = .default
    ) throws -> ThumbleSkinWorkspace {
        guard ThumbleSkinPackageValidator.isValidReverseDNSIdentifier(identifier),
              ThumbleSemanticVersion("1.0.0") != nil
        else { throw ThumbleSkinScaffoldError.invalidIdentity }
        guard ThumbleSkinArtboardCatalog.resolve(artboardID) != nil else {
            throw ThumbleSkinScaffoldError.unknownArtboard(artboardID)
        }
        if fileManager.fileExists(atPath: destination.path) {
            let contents = (try? fileManager.contentsOfDirectory(atPath: destination.path)) ?? []
            if !contents.isEmpty {
                guard force else { throw ThumbleSkinScaffoldError.destinationNotEmpty(destination.path) }
                try fileManager.removeItem(at: destination)
            }
        }
        let workspace = css
            ? ThumbleSkinWorkspace.starterCSS(name: name, identifier: identifier, artboardID: artboardID)
            : ThumbleSkinWorkspace.starter(name: name, identifier: identifier, artboardID: artboardID)
        do {
            try fileManager.createDirectory(
                at: destination.appendingPathComponent("sources/artwork", isDirectory: true),
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: destination.appendingPathComponent("sources/icons", isDirectory: true),
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: destination.appendingPathComponent("reviews", isDirectory: true),
                withIntermediateDirectories: true
            )
            if css {
                try fileManager.createDirectory(
                    at: destination.appendingPathComponent("styles", isDirectory: true),
                    withIntermediateDirectories: true
                )
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(workspace).write(
                to: destination.appendingPathComponent(sourceFileName),
                options: .atomic
            )
            try readme(name: name, artboardID: artboardID, css: css).write(
                to: destination.appendingPathComponent("README.md"),
                atomically: true,
                encoding: .utf8
            )
            if css {
                try starterStylesheet(name: name).write(
                    to: destination.appendingPathComponent("styles/controller.css"),
                    atomically: true,
                    encoding: .utf8
                )
            } else {
                try starterSVG(name: name).write(
                    to: destination.appendingPathComponent("sources/artwork/accent-lines.svg"),
                    atomically: true,
                    encoding: .utf8
                )
            }
            try reviewReadme.write(
                to: destination.appendingPathComponent("reviews/README.md"),
                atomically: true,
                encoding: .utf8
            )
            try pendingHumanApproval.write(
                to: destination.appendingPathComponent("reviews/human-approval.json"),
                atomically: true,
                encoding: .utf8
            )
            try "build/\n.DS_Store\n".write(
                to: destination.appendingPathComponent(".gitignore"),
                atomically: true,
                encoding: .utf8
            )
        } catch {
            throw ThumbleSkinScaffoldError.cannotWrite(error.localizedDescription)
        }
        return workspace
    }

    private static func readme(name: String, artboardID: String, css: Bool = false) -> String {
        if css {
            return """
            # \(name)

            Editable CSS-authored Thumble skin workspace targeting `\(artboardID)`.

            - Edit `styles/controller.css` using the `\(ThumbleCSSProfile.identifier)` profile.
            - `skin-source.json` points at the stylesheet; materials and SVG are not required.
            - Inspect with `thumble skin css lint .` and `thumble skin css computed . --control jump`.
            - Compile with `thumble skin compile . --strict`.
            - Review the native contact sheet before publication.
            """ + "\n"
        }
        return """
        # \(name)

        Editable Thumble skin workspace targeting `\(artboardID)`.

        - Edit `skin-source.json` for palette, materials, components, semantic assignments, and preview requests.
        - Keep authoring SVG under `sources/`; SVG is sanitized and rasterized during compilation and is never shipped at runtime.
        - Treat `build/` as generated output.
        - Compile with `thumble skin compile . --strict`.
        - Review the native contact sheet before publication.
        """ + "\n"
    }

    private static let reviewReadme = """
    # Review evidence

    Keep versioned native-renderer contact sheets and independent critique reports here.

    `human-approval.json` begins as `pending`. Agents and automation must never change it to `approved` or infer consent. Only a human may record approval after reviewing the named contact sheet and exact package hash.
    """ + "\n"

    private static let pendingHumanApproval = """
    {
      "schema": "com.codybontecou.pocketpad.skin-human-approval",
      "version": 1,
      "status": "pending",
      "approvedBy": null,
      "approvedAt": null,
      "reviewedContactSheet": null,
      "packageSHA256": null,
      "notes": null
    }
    """ + "\n"

    private static func starterSVG(name: String) -> String {
        let escaped = name
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1748 804" role="img" aria-label="\(escaped) accent artwork">
          <defs>
            <linearGradient id="accent" x1="0" y1="0" x2="1" y2="1">
              <stop offset="0" stop-color="#B7A7E8" stop-opacity="0.52"/>
              <stop offset="1" stop-color="#D95F91" stop-opacity="0.18"/>
            </linearGradient>
          </defs>
          <path d="M80 150 C420 40 650 210 920 105 S1430 30 1668 170" fill="none" stroke="url(#accent)" stroke-width="3"/>
          <path d="M80 654 C420 764 650 594 920 699 S1430 774 1668 634" fill="none" stroke="url(#accent)" stroke-width="2" opacity="0.62"/>
        </svg>
        """ + "\n"
    }

    private static func starterStylesheet(name: String) -> String {
        let escaped = name.replacingOccurrences(of: "*/", with: "")
        return """
        /* \(escaped) — \(ThumbleCSSProfile.identifier) */

        :root {
          --surface: #F2EEF5;
          --surface-dark: #211A46;
          --ink: #7C61A8;
          --accent: #A77CFF;
        }

        controller {
          background: linear-gradient(160deg, #E9E4F2, #C9C2D2);
        }

        control {
          color: var(--ink);
          background: var(--surface);
          border: 1px solid rgba(255, 255, 255, 0.6);
          border-radius: 14px;
          box-shadow: 0 2px 4px rgba(16, 12, 39, 0.18);
        }

        control:pressed {
          transform: scale(0.96);
        }

        control:disabled {
          opacity: 0.45;
        }

        control[role="primary_action"] {
          background: linear-gradient(135deg, #8A6FD0, #5B4497);
          color: #FFFFFF;
        }

        @media (prefers-color-scheme: dark) {
          :root {
            --surface: var(--surface-dark);
            --ink: #B8A0E8;
          }
          controller {
            background: linear-gradient(160deg, #17143B, #0A0819);
          }
        }
        """ + "\n"
    }
}

public enum ThumbleSkinArtboardCaptureError: LocalizedError {
    case missingSafeArea(ThumbleSkinOrientation)
    case invalidIdentifier
    case invalidViewport(ThumbleSkinOrientation)

    public var errorDescription: String? {
        switch self {
        case .missingSafeArea(let orientation):
            "Supply the render viewport's safe area for \(orientation.rawValue); capture never guesses device insets."
        case .invalidIdentifier: "A captured artboard requires a bounded nonempty identifier."
        case .invalidViewport(let orientation): "Captured \(orientation.rawValue) viewport or safe area is invalid."
        }
    }
}

extension ThumbleSkinArtboard {
    /// Capture authored variants only. UUIDs and resolved geometry are never synthesized
    /// from a template or enumeration order. Outputs do not enter the appearance contract.
    public static func capture(
        profile: GamepadConfigurationProfile,
        identifier: String,
        safeAreas: [ThumbleSkinOrientation: ThumbleNormalizedInsets]
    ) throws -> ThumbleSkinArtboard {
        guard !identifier.isEmpty, identifier.utf8.count <= 100 else {
            throw ThumbleSkinArtboardCaptureError.invalidIdentifier
        }
        var authored: [(ThumbleSkinOrientation, GamepadCustomization)] = []
        let base = profile.customization
        let baseOrientation: ThumbleSkinOrientation = base.deviceCanvas.editorDeviceFrame.orientation == .portrait ? .portrait : .landscape
        if let landscape = profile.landscapeCustomization { authored.append((.landscape, landscape)) }
        if let portrait = profile.portraitCustomization { authored.append((.portrait, portrait)) }
        if !authored.contains(where: { $0.0 == baseOrientation }) { authored.append((baseOrientation, base)) }
        var variants: [ThumbleSkinArtboardVariant] = []
        for (orientation, customization) in authored {
            guard let safeArea = safeAreas[orientation] else {
                throw ThumbleSkinArtboardCaptureError.missingSafeArea(orientation)
            }
            let size = customization.deviceCanvas.editorDeviceFrame.screenRect.size
            let actual: ThumbleSkinOrientation = customization.deviceCanvas.editorDeviceFrame.orientation == .portrait ? .portrait : .landscape
            guard actual == orientation, [safeArea.top, safeArea.leading, safeArea.bottom, safeArea.trailing].allSatisfy({ $0.isFinite && (0...0.45).contains($0) }),
                  size.width.isFinite, size.height.isFinite, (240...1800).contains(size.width), (240...1800).contains(size.height) else {
                throw ThumbleSkinArtboardCaptureError.invalidViewport(orientation)
            }
            let controls = customization.resolvedControls(in: size).filter { !$0.layoutCustomization.isHidden }.map { control in
                ThumbleSkinArtboardControl(
                    id: control.id.id,
                    label: control.label,
                    kind: control.controlKind,
                    visualRole: control.visualRole,
                    inputID: control.inputID,
                    frame: ThumbleNormalizedRect(x: control.frame.minX / size.width, y: control.frame.minY / size.height,
                                                width: control.frame.width / size.width, height: control.frame.height / size.height),
                    rotationDegrees: control.rotationDegrees,
                    presentation: control.presentationMetadata,
                    nativeGeometry: .init(hitFrame: .init(x: control.hitFrame.minX / size.width, y: control.hitFrame.minY / size.height,
                        width: control.hitFrame.width / size.width, height: control.hitFrame.height / size.height)),
                    nativeSurfaces: .init(control: control, customization: customization)
                )
            }
            variants.append(ThumbleSkinArtboardVariant(id: "\(orientation.rawValue)-captured", orientation: orientation,
                canvasWidth: size.width, canvasHeight: size.height, safeAreaInsets: safeArea, controls: controls,
                nativeChrome: .init(customization: customization, orientation: orientation, canvasSize: size,
                    safeAreaInsets: safeArea, hasLaunchTarget: profile.launchTarget != nil)))
        }
        variants.sort { $0.orientation.rawValue < $1.orientation.rawValue }
        return ThumbleSkinArtboard(id: identifier, revision: 1,
            templateID: base.designMetadata?.sourceTemplateID ?? "custom", name: profile.name,
            summary: "Exact authored controller geometry captured for native design review.", variants: variants,
            expectedRoles: Array(Set(variants.flatMap { $0.controls.map(\.visualRole) })).sorted { $0.rawValue < $1.rawValue })
    }
}
