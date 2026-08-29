import Foundation

public enum ThumbleVectorCompilerError: Error, LocalizedError, Equatable {
    case missingArtboard(String)
    case missingMaterial(String)
    case invalidColor(String)
    case unsafeSourcePath(String)
    case missingSource(String)
    case unsupportedSourceFormat(String)
    case outputTooLarge(String)

    public var errorDescription: String? {
        switch self {
        case .missingArtboard(let id): "No canonical artboard exists for \(id)."
        case .missingMaterial(let id): "A visual component references missing material \(id)."
        case .invalidColor(let value): "Invalid skin source color: \(value)."
        case .unsafeSourcePath(let path): "Unsafe skin source path: \(path)."
        case .missingSource(let path): "Skin source asset is missing: \(path)."
        case .unsupportedSourceFormat(let path): "Only sanitized SVG authoring assets are currently compiled: \(path)."
        case .outputTooLarge(let id): "Compiled image asset \(id) exceeds the runtime image budget."
        }
    }
}

public struct ThumbleCompiledCanvas: Equatable, Sendable {
    public var id: String
    public var orientation: ThumbleSkinOrientation
    public var colorScheme: ThumbleSkinColorScheme
    public var width: Int
    public var height: Int
    public var data: Data

    public init(
        id: String,
        orientation: ThumbleSkinOrientation,
        colorScheme: ThumbleSkinColorScheme,
        width: Int,
        height: Int,
        data: Data
    ) {
        self.id = id
        self.orientation = orientation
        self.colorScheme = colorScheme
        self.width = width
        self.height = height
        self.data = data
    }
}

public enum ThumbleVectorCompiler {
    public static func compileCanvases(
        workspace: ThumbleSkinWorkspace,
        sourceRoot: URL,
        fileManager: FileManager = .default
    ) throws -> [ThumbleCompiledCanvas] {
        guard let artboard = ThumbleSkinArtboardCatalog.resolve(workspace.artboardID) else {
            throw ThumbleVectorCompilerError.missingArtboard(workspace.artboardID)
        }
        let orientations = unique(workspace.orientations)
        let schemes = unique(workspace.colorSchemes)
        var canvases: [ThumbleCompiledCanvas] = []
        for orientation in orientations {
            guard let variant = artboard.variants.first(where: { $0.orientation == orientation }) else { continue }
            for scheme in schemes {
                let width = orientation == .landscape ? 1748 : 804
                let height = orientation == .landscape ? 804 : 1748
                let svg = try generatedSVG(
                    workspace: workspace,
                    artboard: variant,
                    scheme: scheme,
                    width: width,
                    height: height
                )
                var png = try ThumbleSVGRasterizer.rasterize(Data(svg.utf8), width: width, height: height)
                for source in workspace.sourceAssets where source.purpose == .canvasArtwork {
                    if let requested = source.orientation, requested != orientation { continue }
                    if let requested = source.colorScheme, requested != scheme { continue }
                    let sourceURL = try safeSourceURL(source.path, root: sourceRoot, fileManager: fileManager)
                    guard sourceURL.pathExtension.lowercased() == "svg" else {
                        throw ThumbleVectorCompilerError.unsupportedSourceFormat(source.path)
                    }
                    let overlay = try ThumbleSVGRasterizer.rasterize(
                        Data(contentsOf: sourceURL, options: [.mappedIfSafe]),
                        width: width,
                        height: height
                    )
                    png = try ThumbleSVGRasterizer.composite(
                        basePNG: png,
                        overlayPNG: overlay,
                        width: width,
                        height: height
                    )
                }
                let id = "canvas-\(orientation.rawValue)-\(scheme.rawValue)"
                guard png.count <= GamepadImageFill.maximumStoredBytes else {
                    throw ThumbleVectorCompilerError.outputTooLarge(id)
                }
                canvases.append(ThumbleCompiledCanvas(
                    id: id,
                    orientation: orientation,
                    colorScheme: scheme,
                    width: width,
                    height: height,
                    data: png
                ))
            }
        }
        return canvases
    }

    /// Rasterizes declared SVG source assets by ID for CSS-authored workspaces, where
    /// `background: url(#asset-id)` references them from stylesheets.
    public static func compileSourceAssets(
        workspace: ThumbleSkinWorkspace,
        sourceRoot: URL,
        fileManager: FileManager = .default
    ) throws -> [(id: String, data: Data, width: Int, height: Int, purpose: ThumbleSkinAssetPurpose)] {
        var results: [(String, Data, Int, Int, ThumbleSkinAssetPurpose)] = []
        for source in workspace.sourceAssets {
            let sourceURL = try safeSourceURL(source.path, root: sourceRoot, fileManager: fileManager)
            guard sourceURL.pathExtension.lowercased() == "svg" else {
                throw ThumbleVectorCompilerError.unsupportedSourceFormat(source.path)
            }
            let png = try ThumbleSVGRasterizer.rasterize(
                Data(contentsOf: sourceURL, options: [.mappedIfSafe]),
                width: source.outputWidth,
                height: source.outputHeight
            )
            guard png.count <= GamepadImageFill.maximumStoredBytes else {
                throw ThumbleVectorCompilerError.outputTooLarge(source.id)
            }
            results.append((source.id, png, source.outputWidth, source.outputHeight, source.purpose))
        }
        return results
    }

    public static func generatedSVG(
        workspace: ThumbleSkinWorkspace,
        artboard: ThumbleSkinArtboardVariant,
        scheme: ThumbleSkinColorScheme,
        width: Int,
        height: Int
    ) throws -> String {
        let materials = Dictionary(uniqueKeysWithValues: workspace.materials.map { ($0.id, $0) })
        let backgroundToken = workspace.palette.first
        let background = try color(
            scheme == .dark ? (backgroundToken?.dark ?? "#120E24") : (backgroundToken?.light ?? "#E9E4F2")
        )
        let backgroundEnd = scheme == .dark ? mix(background, with: "#05040A", amount: 0.48) : mix(background, with: "#FFFFFF", amount: 0.44)
        var definitions: [String] = []
        var layers: [(Int, String)] = []

        definitions.append("""
          <linearGradient id="canvas-bg" x1="0" y1="0" x2="1" y2="1">
            <stop offset="0" stop-color="\(background)"/>
            <stop offset="1" stop-color="\(backgroundEnd)"/>
          </linearGradient>
          <filter id="soft-shadow" x="-30%" y="-30%" width="160%" height="170%">
            <feDropShadow dx="0" dy="18" stdDeviation="24" flood-color="#070510" flood-opacity="0.44"/>
          </filter>
          <filter id="inset-shadow" x="-20%" y="-20%" width="140%" height="140%">
            <feGaussianBlur in="SourceAlpha" stdDeviation="10" result="blur"/>
            <feOffset dx="5" dy="8" result="offset"/>
            <feComposite in="offset" in2="SourceAlpha" operator="out" result="inner"/>
            <feColorMatrix in="inner" type="matrix" values="0 0 0 0 0.03 0 0 0 0 0.02 0 0 0 0 0.07 0 0 0 .55 0"/>
            <feComposite in2="SourceGraphic" operator="over"/>
          </filter>
        """)
        layers.append((-1000, "<rect width=\"\(width)\" height=\"\(height)\" fill=\"url(#canvas-bg)\"/>"))

        for (index, component) in workspace.components.enumerated() {
            guard let frame = component.frame?.normalized else { continue }
            guard let material = materials[component.materialID] else {
                throw ThumbleVectorCompilerError.missingMaterial(component.materialID)
            }
            let base = try color(scheme == .dark ? (material.darkBaseColor ?? material.baseColor) : material.baseColor)
            let highlight = try color(material.highlightColor ?? mix(base, with: "#FFFFFF", amount: 0.42))
            let shadow = try color(material.shadowColor ?? mix(base, with: "#000000", amount: 0.54))
            let stroke = try color(material.strokeColor ?? highlight)
            let gradientID = "material-\(sanitizeID(component.id))-\(index)"
            definitions.append("""
              <linearGradient id="\(gradientID)" x1="0" y1="0" x2="1" y2="1">
                <stop offset="0" stop-color="\(highlight)" stop-opacity="\(format(0.62 + material.gloss * 0.30))"/>
                <stop offset="0.22" stop-color="\(base)"/>
                <stop offset="0.82" stop-color="\(base)"/>
                <stop offset="1" stop-color="\(shadow)" stop-opacity="\(format(0.76))"/>
              </linearGradient>
            """)
            let x = frame.x * CGFloat(width)
            let y = frame.y * CGFloat(height)
            let w = frame.width * CGFloat(width)
            let h = frame.height * CGFloat(height)
            let radius = min(material.cornerRadius ?? min(w, h) * 0.16, min(w, h) / 2)
            let shape: String
            if component.shape == .circle || component.kind == .controlWell && abs(w - h) < 4 {
                shape = "<ellipse cx=\"\(format(x + w / 2))\" cy=\"\(format(y + h / 2))\" rx=\"\(format(w / 2))\" ry=\"\(format(h / 2))\""
            } else {
                shape = "<rect x=\"\(format(x))\" y=\"\(format(y))\" width=\"\(format(w))\" height=\"\(format(h))\" rx=\"\(format(radius))\""
            }
            let filter = component.kind == .controllerShell ? "soft-shadow" : (component.kind == .controlWell ? "inset-shadow" : "soft-shadow")
            let opacity = material.kind == .translucentPlastic ? 0.88 : 1
            let element = "\(shape) fill=\"url(#\(gradientID))\" stroke=\"\(stroke)\" stroke-width=\"\(format(max(1, material.depth * 3)))\" opacity=\"\(format(opacity))\" filter=\"url(#\(filter))\"/>"
            layers.append((component.zIndex, element))
        }

        // Precision accents make the generated shell feel authored while remaining neutral enough for custom SVG overlays.
        layers.append((900, "<path d=\"M \(format(CGFloat(width) * 0.08)) \(format(CGFloat(height) * 0.14)) H \(format(CGFloat(width) * 0.92))\" stroke=\"#FFFFFF\" stroke-opacity=\"0.16\" stroke-width=\"2\" fill=\"none\"/>"))
        layers.append((901, "<path d=\"M \(format(CGFloat(width) * 0.12)) \(format(CGFloat(height) * 0.88)) C \(format(CGFloat(width) * 0.35)) \(format(CGFloat(height) * 0.82)), \(format(CGFloat(width) * 0.66)) \(format(CGFloat(height) * 0.94)), \(format(CGFloat(width) * 0.88)) \(format(CGFloat(height) * 0.86))\" stroke=\"#FFFFFF\" stroke-opacity=\"0.08\" stroke-width=\"2\" fill=\"none\"/>"))

        let body = layers.sorted { lhs, rhs in lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0 }
            .map(\.1)
            .joined(separator: "\n  ")
        return """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(width) \(height)" width="\(width)" height="\(height)">
          <defs>
          \(definitions.joined(separator: "\n"))
          </defs>
          \(body)
        </svg>
        """
    }

    private static func safeSourceURL(
        _ path: String,
        root: URL,
        fileManager: FileManager
    ) throws -> URL {
        guard ThumbleSkinPackageCodec.isSafePackagePath(path), path.hasPrefix("sources/") else {
            throw ThumbleVectorCompilerError.unsafeSourcePath(path)
        }
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(root.path + "/") else {
            throw ThumbleVectorCompilerError.unsafeSourcePath(path)
        }
        guard fileManager.fileExists(atPath: candidate.path) else {
            throw ThumbleVectorCompilerError.missingSource(path)
        }
        let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values?.isRegularFile == true, values?.isSymbolicLink != true else {
            throw ThumbleVectorCompilerError.unsafeSourcePath(path)
        }
        return candidate
    }

    private static func color(_ value: String) throws -> String {
        guard GamepadRGBAColor(hexString: value) != nil else {
            throw ThumbleVectorCompilerError.invalidColor(value)
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if trimmed.count == 9 { return String(trimmed.prefix(7)) }
        return trimmed
    }

    private static func mix(_ color: String, with other: String, amount: CGFloat) -> String {
        guard let left = GamepadRGBAColor(hexString: color), let right = GamepadRGBAColor(hexString: other) else {
            return color
        }
        let mixed = left.mixed(with: right, amount: min(max(amount, 0), 1)).normalized
        return String(format: "#%02X%02X%02X", Int(mixed.red * 255), Int(mixed.green * 255), Int(mixed.blue * 255))
    }

    private static func sanitizeID(_ value: String) -> String {
        value.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce(into: "") { $0.append($1) }
    }

    private static func format(_ value: CGFloat) -> String {
        String(format: "%.3f", Double(value))
    }

    private static func unique<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }
}
