import Foundation
import ImageIO

public enum ThumbleSkinQualitySeverity: String, Codable, Equatable, Sendable {
    case error
    case warning
}

public struct ThumbleSkinQualityIssue: Codable, Equatable, Identifiable, Sendable {
    public var severity: ThumbleSkinQualitySeverity
    public var code: String
    public var message: String
    public var path: String?

    public init(
        severity: ThumbleSkinQualitySeverity,
        code: String,
        message: String,
        path: String? = nil
    ) {
        self.severity = severity
        self.code = code
        self.message = message
        self.path = path
    }

    public var id: String { "\(severity.rawValue):\(code):\(path ?? ""):\(message)" }
}

public struct ThumbleSkinQualityReport: Codable, Equatable, Sendable {
    public var issues: [ThumbleSkinQualityIssue]
    public var score: Int
    public var checkedArtboardID: String?

    public init(issues: [ThumbleSkinQualityIssue], checkedArtboardID: String? = nil) {
        self.issues = issues
        self.score = max(0, 100 - issues.reduce(0) { partial, issue in
            partial + (issue.severity == .error ? 18 : 4)
        })
        self.checkedArtboardID = checkedArtboardID
    }

    public var errors: [ThumbleSkinQualityIssue] { issues.filter { $0.severity == .error } }
    public var warnings: [ThumbleSkinQualityIssue] { issues.filter { $0.severity == .warning } }
    public var isPassing: Bool { errors.isEmpty }
    public var isStrictlyPassing: Bool { issues.isEmpty }
}

/// Publication-oriented checks that go beyond archive safety. These gates inspect authored
/// source intent, state completeness, native layout compatibility, asset dimensions, and budgets.
public enum ThumbleSkinQualityEvaluator {
    public static func evaluate(
        package: ThumbleSkinPackage,
        workspace: ThumbleSkinWorkspace? = nil,
        artboardID requestedArtboardID: String? = nil
    ) -> ThumbleSkinQualityReport {
        var issues: [ThumbleSkinQualityIssue] = []
        func add(_ severity: ThumbleSkinQualitySeverity, _ code: String, _ message: String, path: String? = nil) {
            guard !issues.contains(where: { $0.code == code && $0.path == path && $0.message == message }) else { return }
            issues.append(.init(severity: severity, code: code, message: message, path: path))
        }

        let packageReport = ThumbleSkinPackageValidator.validate(package)
        for issue in packageReport.issues {
            add(
                issue.severity == .error ? .error : .warning,
                "package-\(issue.code)",
                issue.message,
                path: issue.path
            )
        }

        if let workspace {
            let sourceReport = ThumbleSkinSourceValidator.validate(workspace)
            for issue in sourceReport.issues {
                add(
                    issue.severity == .error ? .error : .warning,
                    "source-\(issue.code)",
                    issue.message,
                    path: issue.path
                )
            }
            evaluateAuthorship(workspace, usesCSS: workspace.usesCSSAuthoring, add: add)
            if workspace.usesCSSAuthoring {
                evaluatePackageContrast(package, add: add)
            } else {
                evaluateSourceContrast(workspace, add: add)
            }
        }

        let artboardID = requestedArtboardID
            ?? workspace?.artboardID
            ?? package.manifest.compatibility?.templates.first?.templateID
        let artboard = artboardID.flatMap(ThumbleSkinArtboardCatalog.resolve)
        if let artboard {
            evaluateArtboard(artboard, package: package, workspace: workspace, add: add)
        } else if package.manifest.compatibility?.mode == .templateAligned {
            add(.error, "unknown-canonical-artboard", "Template-aligned artwork must resolve to a committed canonical artboard.", path: "manifest.compatibility.templates")
        } else {
            add(.warning, "unverified-artboard", "No canonical artboard was selected, so alignment and safe-area checks were skipped.")
        }

        evaluateVariantMatrix(package, artboard: artboard, workspace: workspace, add: add)
        evaluateControlStates(package, add: add)
        evaluateAssetDimensionsAndBudgets(package, artboard: artboard, add: add)
        evaluateLayerSafety(package, add: add)

        let ordered = issues.sorted {
            if $0.severity != $1.severity { return $0.severity == .error }
            if $0.code != $1.code { return $0.code < $1.code }
            return ($0.path ?? "") < ($1.path ?? "")
        }
        return ThumbleSkinQualityReport(issues: ordered, checkedArtboardID: artboard?.id)
    }

    private static func evaluateAuthorship(
        _ workspace: ThumbleSkinWorkspace,
        usesCSS: Bool,
        add: (ThumbleSkinQualitySeverity, String, String, String?) -> Void
    ) {
        if workspace.summary.trimmingCharacters(in: .whitespacesAndNewlines).count < 40 {
            add(.warning, "thin-art-direction", "Write a specific art-direction summary of at least 40 characters.", "skin-source.json.summary")
        }
        if usesCSS {
            if workspace.stylesheets.isEmpty {
                add(.error, "missing-stylesheet", "CSS skins must declare at least one stylesheet under styles/.", "skin-source.json.stylesheets")
            }
        } else {
            if workspace.materials.count < 3 {
                add(.error, "insufficient-material-system", "Handcrafted skins need at least three deliberate materials.", "skin-source.json.materials")
            }
            let kinds = Set(workspace.components.map(\.kind))
            if !kinds.contains(.controllerShell) {
                add(.error, "missing-controller-shell", "Add an authored controller shell component.", "skin-source.json.components")
            }
            if !kinds.contains(.controlWell) {
                add(.warning, "missing-control-wells", "Add layout-aware control wells or equivalent grouping artwork.", "skin-source.json.components")
            }
            if workspace.sourceAssets.isEmpty {
                add(.error, "missing-editable-artwork", "Retain at least one editable SVG source asset.", "skin-source.json.sourceAssets")
            }
        }
        if workspace.license.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add(.error, "missing-source-license", "Declare a redistribution license.", "skin-source.json.license")
        }
        if workspace.author.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().contains("unknown") {
            add(.warning, "placeholder-author", "Replace the placeholder creator name before publication.", "skin-source.json.author")
        }
    }

    /// CSS skins evaluate contrast against their compiled style tokens.
    private static func evaluatePackageContrast(
        _ package: ThumbleSkinPackage,
        add: (ThumbleSkinQualitySeverity, String, String, String?) -> Void
    ) {
        guard let skin = package.skin else { return }
        var scopes: [(label: String, styles: [GamepadStyleToken])] = [("base", skin.base.styleLibrary.styles)]
        for variant in skin.variants {
            let label = [variant.orientation?.rawValue, variant.colorScheme?.rawValue]
                .compactMap { $0 }
                .joined(separator: "-")
            scopes.append((label.isEmpty ? variant.id : label, variant.appearance.styleLibrary.styles))
        }
        for (scope, styles) in scopes {
            for style in styles {
                let normal = style.visualStyle.normal
                guard let foreground = normal.foregroundColor,
                      let fill = normal.fillStyle?.representativeColor
                else { continue }
                let ratio = contrastRatio(foreground, fill)
                if ratio < 3 {
                    add(
                        .error,
                        "low-style-contrast",
                        "Style \(style.id) (\(scope)) has \(String(format: "%.2f", ratio)):1 legend contrast; require at least 3:1.",
                        "skin.json.styleLibrary.\(style.id)"
                    )
                } else if ratio < 4.5 {
                    add(
                        .warning,
                        "moderate-style-contrast",
                        "Style \(style.id) (\(scope)) has \(String(format: "%.2f", ratio)):1 legend contrast; 4.5:1 is preferred for small legends.",
                        "skin.json.styleLibrary.\(style.id)"
                    )
                }
            }
        }
    }

    private static func evaluateSourceContrast(
        _ workspace: ThumbleSkinWorkspace,
        add: (ThumbleSkinQualitySeverity, String, String, String?) -> Void
    ) {
        for material in workspace.materials {
            let pairs = [
                ("light", material.foregroundColor, material.baseColor),
                ("dark", material.darkForegroundColor ?? material.foregroundColor, material.darkBaseColor ?? material.baseColor)
            ]
            for (scheme, foregroundHex, backgroundHex) in pairs {
                guard let foreground = GamepadRGBAColor(hexString: foregroundHex),
                      let background = GamepadRGBAColor(hexString: backgroundHex)
                else { continue }
                let ratio = contrastRatio(foreground, background)
                if ratio < 3 {
                    add(
                        .error,
                        "low-material-contrast",
                        "\(material.name) has \(String(format: "%.2f", ratio)):1 \(scheme) contrast; require at least 3:1.",
                        "skin-source.json.materials.\(material.id)"
                    )
                } else if ratio < 4.5 {
                    add(
                        .warning,
                        "moderate-material-contrast",
                        "\(material.name) has \(String(format: "%.2f", ratio)):1 \(scheme) contrast; 4.5:1 is preferred for small legends.",
                        "skin-source.json.materials.\(material.id)"
                    )
                }
            }
        }
    }

    private static func evaluateArtboard(
        _ artboard: ThumbleSkinArtboard,
        package: ThumbleSkinPackage,
        workspace: ThumbleSkinWorkspace?,
        add: (ThumbleSkinQualitySeverity, String, String, String?) -> Void
    ) {
        let requiredRoles = Set(artboard.expectedRoles.filter { ![.system, .decoration, .custom].contains($0) })
        if let workspace {
            let assignedRoles: Set<GamepadVisualRole>
            if workspace.usesCSSAuthoring {
                assignedRoles = Set((package.skin?.base.roleRules ?? []).map(\.role))
            } else {
                assignedRoles = Set(workspace.assignments.compactMap(\.role))
            }
            for role in requiredRoles.subtracting(assignedRoles).sorted(by: { $0.rawValue < $1.rawValue }) {
                add(.error, "missing-semantic-role", "No \(workspace.usesCSSAuthoring ? "CSS role rule" : "material assignment") covers \(role.displayName.lowercased()).", "skin-source.json.\(workspace.usesCSSAuthoring ? "stylesheets" : "assignments")")
            }
            for component in workspace.components where component.frame != nil && (component.role != nil || component.button != nil) {
                guard let frame = component.frame?.normalized else { continue }
                let aligns = artboard.variants.contains { variant in
                    variant.controls.contains { control in
                        let semanticMatch = component.role.map { $0 == control.visualRole } ?? (component.button == control.mappedButton)
                        guard semanticMatch else { return false }
                        let centerX = control.frame.x + control.frame.width / 2
                        let centerY = control.frame.y + control.frame.height / 2
                        return centerX >= frame.x - 0.03 && centerX <= frame.x + frame.width + 0.03
                            && centerY >= frame.y - 0.03 && centerY <= frame.y + frame.height + 0.03
                    }
                }
                if !aligns {
                    add(.warning, "component-layout-misalignment", "Component \(component.id) does not align with its canonical role in any artboard variant.", "skin-source.json.components.\(component.id)")
                }
            }
        }

        guard let profile = ThumbleSkinArtboardCatalog.profile(for: artboard.id) else {
            add(.error, "missing-artboard-profile", "Canonical artboard \(artboard.id) has no deterministic profile.", nil)
            return
        }
        for variant in artboard.variants {
            let deviceOrientation: GamepadEditorDeviceOrientation = variant.orientation == .portrait ? .portrait : .landscape
            let customization = profile.customization(for: deviceOrientation)
            let compatibility = ThumbleSkinCompatibilityEvaluator.evaluate(
                package.manifest.compatibility,
                customization: customization,
                orientation: variant.orientation
            )
            if compatibility.status != .compatible {
                add(.error, "canonical-template-incompatible", "Package compatibility rejects its canonical \(variant.orientation.rawValue) artboard.", "manifest.compatibility")
            }
            let safe = variant.safeAreaInsets.normalized
            let safeRect = ThumbleNormalizedRect(
                x: safe.leading,
                y: safe.top,
                width: max(0, 1 - safe.leading - safe.trailing),
                height: max(0, 1 - safe.top - safe.bottom)
            )
            for control in variant.controls where control.visualRole != .system && control.visualRole != .decoration {
                let centerX = control.frame.x + control.frame.width / 2
                let centerY = control.frame.y + control.frame.height / 2
                if centerX < safeRect.x || centerX > safeRect.x + safeRect.width
                    || centerY < safeRect.y || centerY > safeRect.y + safeRect.height {
                    add(.error, "control-outside-safe-area", "\(control.label) falls outside the canonical safe area in \(variant.orientation.rawValue).", "artboard.\(variant.id)")
                }
            }
        }
    }

    private static func evaluateVariantMatrix(
        _ package: ThumbleSkinPackage,
        artboard: ThumbleSkinArtboard?,
        workspace: ThumbleSkinWorkspace?,
        add: (ThumbleSkinQualitySeverity, String, String, String?) -> Void
    ) {
        guard let skin = package.skin else { return }
        let isCSS = package.manifest.tags.contains("css")
        let orientations = package.manifest.compatibility?.normalized.orientations.isEmpty == false
            ? package.manifest.compatibility!.normalized.orientations
            : (artboard?.variants.map(\.orientation) ?? ThumbleSkinOrientation.allCases)
        for orientation in Set(orientations) {
            for scheme in ThumbleSkinColorScheme.allCases {
                let appearance = skin.appearance(orientation: orientation, colorScheme: scheme)
                if appearance.backgroundFillStyle == nil && (appearance.artworkLayers ?? []).isEmpty {
                    if isCSS {
                        add(.warning, "missing-controller-background", "No controller background was declared for \(orientation.rawValue) \(scheme.rawValue); the user's keypad background shows through.", "stylesheets")
                    } else {
                        add(.error, "missing-artwork-variant", "Missing \(orientation.rawValue) \(scheme.rawValue) canvas artwork.", "skin.json.variants")
                    }
                }
                if isCSS {
                    // CSS packages carry no raster previews; the workspace preview requests
                    // define the review matrix instead.
                    if let workspace {
                        let declared = workspace.previews.contains {
                            $0.artboardID == workspace.artboardID
                                && $0.orientation == orientation
                                && $0.colorScheme == scheme
                        }
                        if !declared {
                            add(.error, "missing-preview-variant", "Missing \(orientation.rawValue) \(scheme.rawValue) preview request.", "skin-source.json.previews")
                        }
                    }
                } else {
                    let previewExists = package.manifest.previews.contains {
                        $0.orientation == orientation && ($0.colorScheme == nil || $0.colorScheme == scheme)
                    }
                    if !previewExists {
                        add(.error, "missing-preview-variant", "Missing \(orientation.rawValue) \(scheme.rawValue) package preview.", "manifest.previews")
                    }
                }
            }
        }
    }

    private static func evaluateControlStates(
        _ package: ThumbleSkinPackage,
        add: (ThumbleSkinQualitySeverity, String, String, String?) -> Void
    ) {
        guard let skin = package.skin else { return }
        let appearances = [("base", skin.base)] + skin.variants.map { ($0.id, $0.appearance) }
        var styles: [(id: String, visualStyle: GamepadControlVisualStyle)] = []
        for (appearanceID, appearance) in appearances {
            for style in appearance.styleLibrary.styles {
                styles.append(("\(appearanceID).\(style.id)", style.visualStyle))
            }
            let direct = [appearance.defaultControl].compactMap { $0 }
                + appearance.roleRules.map(\.appearance)
                + appearance.buttonRules.map(\.appearance)
            for (index, control) in direct.enumerated() {
                if let visualStyle = control.visualStyle {
                    styles.append(("\(appearanceID).direct-\(index)", visualStyle))
                }
            }
        }
        if styles.isEmpty {
            add(.error, "missing-control-materials", "Skin has no authored native control materials.", "skin.json")
        }
        for (id, style) in styles.sorted(by: { $0.id < $1.id }) {
            if style.pressed == nil { add(.error, "missing-pressed-state", "Style \(id) has no pressed state.", "skin.json.styleLibrary.\(id)") }
            if style.active == nil { add(.error, "missing-active-state", "Style \(id) has no active state.", "skin.json.styleLibrary.\(id)") }
            if style.disabled == nil { add(.error, "missing-disabled-state", "Style \(id) has no disabled state.", "skin.json.styleLibrary.\(id)") }
            if let pressed = style.pressed, pressed == style.normal {
                add(.error, "indistinguishable-pressed-state", "Style \(id)'s pressed state is indistinguishable from normal.", "skin.json.styleLibrary.\(id)")
            }
            if let disabled = style.disabled, disabled == style.normal {
                add(.warning, "indistinguishable-disabled-state", "Style \(id)'s disabled state is indistinguishable from normal.", "skin.json.styleLibrary.\(id)")
            }
        }
    }

    private static func evaluateAssetDimensionsAndBudgets(
        _ package: ThumbleSkinPackage,
        artboard: ThumbleSkinArtboard?,
        add: (ThumbleSkinQualitySeverity, String, String, String?) -> Void
    ) {
        let totalAssets = package.assets.values.reduce(0) { $0 + $1.count }
        let totalPreviews = package.previews.values.reduce(0) { $0 + $1.count }
        if totalAssets > 24 * 1024 * 1024 {
            add(.error, "asset-budget-exceeded", "Skin assets exceed the 24 MB publication budget.", "manifest.assets")
        } else if totalAssets > 12 * 1024 * 1024 {
            add(.warning, "heavy-asset-budget", "Skin assets exceed 12 MB; optimize raster media.", "manifest.assets")
        }
        if totalPreviews > 8 * 1024 * 1024 {
            add(.error, "preview-budget-exceeded", "Package previews exceed the 8 MB publication budget.", "manifest.previews")
        }
        if let archive = try? ThumbleSkinPackageCodec.encode(package), archive.count > 30 * 1024 * 1024 {
            add(.error, "archive-budget-exceeded", "Encoded package exceeds the 30 MB publication budget.", nil)
        }

        for descriptor in package.manifest.assets {
            guard let data = package.assets[descriptor.id], let dimensions = imageDimensions(data) else {
                add(.error, "unreadable-visual-asset", "Asset \(descriptor.id) cannot be decoded as an image.", descriptor.path)
                continue
            }
            if dimensions.width > 8192 || dimensions.height > 8192 {
                add(.error, "oversized-asset-dimensions", "Asset \(descriptor.id) exceeds 8192 pixels on one axis.", descriptor.path)
            }
            if descriptor.role == .background {
                if min(dimensions.width, dimensions.height) < 256 || max(dimensions.width, dimensions.height) < 512 {
                    add(.error, "undersized-background", "Background \(descriptor.id) is too small for high-resolution previewing.", descriptor.path)
                }
                if let orientation = inferredOrientation(from: descriptor.id),
                   let variant = artboard?.variants.first(where: { $0.orientation == orientation }) {
                    let sourceAspect = CGFloat(dimensions.width) / CGFloat(max(dimensions.height, 1))
                    let targetAspect = variant.canvasWidth / max(variant.canvasHeight, 1)
                    if abs(sourceAspect - targetAspect) > 0.02 {
                        add(.error, "background-aspect-mismatch", "Background \(descriptor.id) does not match the canonical \(orientation.rawValue) aspect ratio.", descriptor.path)
                    }
                }
            }
        }
        for descriptor in package.manifest.previews {
            guard let data = package.previews[descriptor.id], let dimensions = imageDimensions(data) else {
                add(.error, "unreadable-preview", "Preview \(descriptor.id) cannot be decoded as an image.", descriptor.path)
                continue
            }
            if min(dimensions.width, dimensions.height) < 300 || max(dimensions.width, dimensions.height) < 640 {
                add(.warning, "small-preview", "Preview \(descriptor.id) is small for directory presentation.", descriptor.path)
            }
        }
    }

    private static func evaluateLayerSafety(
        _ package: ThumbleSkinPackage,
        add: (ThumbleSkinQualitySeverity, String, String, String?) -> Void
    ) {
        guard let skin = package.skin else { return }
        let appearances = [skin.base] + skin.variants.map(\.appearance)
        let layers = appearances.flatMap { $0.artworkLayers ?? [] }
        if layers.count > 32 {
            add(.error, "too-many-artwork-layers", "Skins may define at most 32 artwork layers across the cascade.", "skin.json.artworkLayers")
        }
        for layer in layers {
            if layer.fillStyle == nil {
                add(.warning, "empty-artwork-layer", "Artwork layer \(layer.id) has no fill.", "skin.json.artworkLayers.\(layer.id)")
            }
            if layer.plane == .overlay && layer.opacity > 0.92 && layer.frame?.normalized == ThumbleNormalizedRect(x: 0, y: 0, width: 1, height: 1) {
                add(.warning, "opaque-full-overlay", "Full-canvas overlay \(layer.id) may obscure native control states.", "skin.json.artworkLayers.\(layer.id)")
            }
        }
    }

    private static func inferredOrientation(from id: String) -> ThumbleSkinOrientation? {
        let value = id.lowercased()
        if value.contains("portrait") { return .portrait }
        if value.contains("landscape") { return .landscape }
        return nil
    }

    private static func imageDimensions(_ data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }

    private static func contrastRatio(_ lhs: GamepadRGBAColor, _ rhs: GamepadRGBAColor) -> CGFloat {
        let bright = max(relativeLuminance(lhs), relativeLuminance(rhs))
        let dark = min(relativeLuminance(lhs), relativeLuminance(rhs))
        return (bright + 0.05) / (dark + 0.05)
    }

    private static func relativeLuminance(_ color: GamepadRGBAColor) -> CGFloat {
        func channel(_ value: CGFloat) -> CGFloat {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.red) + 0.7152 * channel(color.green) + 0.0722 * channel(color.blue)
    }
}
