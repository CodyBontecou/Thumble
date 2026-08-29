import CryptoKit
import Foundation

public enum ThumbleSkinWorkspaceSchema {
    public static let identifier = "com.codybontecou.pocketpad.skin-source"
    /// Schema 1: material/component authoring. Schema 2 adds optional CSS stylesheets.
    public static let currentVersion = 2
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
    public var button: GameButton?
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
        button: GameButton? = nil,
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

public struct ThumbleSkinSourceAsset: Codable, Equatable, Identifiable, Sendable {
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
        colorScheme: ThumbleSkinColorScheme? = nil
    ) {
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
    public var button: GameButton?
    public var materialID: String
    public var componentID: String?

    public init(
        role: GamepadVisualRole? = nil,
        button: GameButton? = nil,
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
        previews: [ThumblePreviewRequest] = []
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
    }

    private enum CodingKeys: String, CodingKey {
        case schema, schemaVersion, identifier, version, name, author, summary, license, artboardID
        case orientations, colorSchemes, palette, materials, components, assignments, sourceAssets
        case stylesheets, previews
    }

    public var usesCSSAuthoring: Bool { !stylesheets.isEmpty }

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

public struct ThumbleSkinArtboardControl: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var kind: GamepadCustomControlKind
    public var visualRole: GamepadVisualRole
    public var mappedButton: GameButton
    public var frame: ThumbleNormalizedRect

    public init(
        id: String,
        label: String,
        kind: GamepadCustomControlKind,
        visualRole: GamepadVisualRole,
        mappedButton: GameButton,
        frame: ThumbleNormalizedRect
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.visualRole = visualRole
        self.mappedButton = mappedButton
        self.frame = frame
    }
}

public struct ThumbleSkinArtboardVariant: Codable, Equatable, Identifiable, Sendable {
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
        controls: [ThumbleSkinArtboardControl]
    ) {
        self.id = id
        self.orientation = orientation
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.safeAreaInsets = safeAreaInsets
        self.controls = controls
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
        return stabilized(completingOrientations(template.makeProfile()), seed: artboard.id)
    }

    private static func makeArtboard(
        id: String,
        template: GamepadControllerTemplate,
        name: String,
        summary: String
    ) -> ThumbleSkinArtboard {
        let profile = stabilized(completingOrientations(template.makeProfile()), seed: id)
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
                    mappedButton: control.mappedButton,
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
            let newID = deterministicUUID("\(seed):custom:\(index):\(customization.customButtons[index].controlKind.rawValue):\(customization.customButtons[index].mappedButton.rawValue)")
            customization.customButtons[index].id = newID
            replacements[oldID] = newID
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
