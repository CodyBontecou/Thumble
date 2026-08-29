import Foundation

public enum ThumbleSkinSourceIssueSeverity: String, Codable, Equatable, Sendable {
    case warning
    case error
}

public struct ThumbleSkinSourceIssue: Codable, Equatable, Sendable {
    public var severity: ThumbleSkinSourceIssueSeverity
    public var code: String
    public var message: String
    public var path: String?

    public init(
        severity: ThumbleSkinSourceIssueSeverity,
        code: String,
        message: String,
        path: String? = nil
    ) {
        self.severity = severity
        self.code = code
        self.message = message
        self.path = path
    }
}

public struct ThumbleSkinSourceValidationReport: Codable, Equatable, Sendable {
    public var issues: [ThumbleSkinSourceIssue]

    public init(issues: [ThumbleSkinSourceIssue]) {
        self.issues = issues
    }

    public var errors: [ThumbleSkinSourceIssue] { issues.filter { $0.severity == .error } }
    public var warnings: [ThumbleSkinSourceIssue] { issues.filter { $0.severity == .warning } }
    public var isValid: Bool { errors.isEmpty }
}

public enum ThumbleSkinSourceValidator {
    public static func validate(_ workspace: ThumbleSkinWorkspace) -> ThumbleSkinSourceValidationReport {
        var issues: [ThumbleSkinSourceIssue] = []
        func issue(_ severity: ThumbleSkinSourceIssueSeverity, _ code: String, _ message: String, _ path: String? = nil) {
            issues.append(.init(severity: severity, code: code, message: message, path: path))
        }
        guard workspace.schema == ThumbleSkinWorkspaceSchema.identifier else {
            issue(.error, "invalid-source-schema", "Unknown skin source schema.", "schema")
            return ThumbleSkinSourceValidationReport(issues: issues)
        }
        if workspace.schemaVersion > ThumbleSkinWorkspaceSchema.currentVersion || workspace.schemaVersion < 1 {
            issue(.error, "unsupported-source-version", "Unsupported skin source schema version.", "schemaVersion")
        }
        if !workspace.stylesheets.isEmpty, workspace.schemaVersion < 2 {
            issue(.error, "stylesheets-require-schema-2", "CSS stylesheets require skin-source schema version 2.", "stylesheets")
        }
        if workspace.stylesheets.count > ThumbleCSSProfile.Limits.maximumStylesheetCount {
            issue(.error, "stylesheet-count-limit", "At most \(ThumbleCSSProfile.Limits.maximumStylesheetCount) stylesheets are supported.", "stylesheets")
        }
        var seenStylesheets = Set<String>()
        for (index, path) in workspace.stylesheets.enumerated() {
            guard ThumbleSkinPackageCodec.isSafePackagePath(path), path.hasPrefix("styles/"), path.hasSuffix(".css") else {
                issue(.error, "unsafe-stylesheet-path", "Stylesheet paths must stay below styles/ and end in .css.", "stylesheets[\(index)]")
                continue
            }
            guard seenStylesheets.insert(path).inserted else {
                issue(.error, "duplicate-stylesheet", "Duplicate stylesheet \(path).", "stylesheets[\(index)]")
                continue
            }
        }
        if !ThumbleSkinPackageValidator.isValidReverseDNSIdentifier(workspace.identifier) {
            issue(.error, "invalid-identifier", "Use a reverse-DNS package identifier.", "identifier")
        }
        if ThumbleSemanticVersion(workspace.version) == nil {
            issue(.error, "invalid-version", "Use a semantic version such as 1.0.0.", "version")
        }
        if workspace.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issue(.error, "missing-name", "Give the skin a name.", "name")
        }
        if workspace.author.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "your name" {
            issue(.warning, "placeholder-author", "Replace the scaffold author before publication.", "author.name")
        }
        if workspace.summary.trimmingCharacters(in: .whitespacesAndNewlines).count < 20 {
            issue(.warning, "short-summary", "Describe the skin's visual direction and material language.", "summary")
        }
        guard let artboard = ThumbleSkinArtboardCatalog.resolve(workspace.artboardID) else {
            issue(.error, "missing-artboard", "Unknown canonical artboard \(workspace.artboardID).", "artboardID")
            return ThumbleSkinSourceValidationReport(issues: issues)
        }

        checkUnique(workspace.palette.map(\.id), path: "palette", issues: &issues)
        checkUnique(workspace.materials.map(\.id), path: "materials", issues: &issues)
        checkUnique(workspace.components.map(\.id), path: "components", issues: &issues)
        checkUnique(workspace.sourceAssets.map(\.id), path: "sourceAssets", issues: &issues)
        checkUnique(workspace.previews.map(\.id), path: "previews", issues: &issues)

        let materialIDs = Set(workspace.materials.map(\.id))
        for (index, material) in workspace.materials.enumerated() {
            let values = [material.baseColor, material.foregroundColor]
                + [
                    material.darkBaseColor,
                    material.darkForegroundColor,
                    material.strokeColor,
                    material.darkStrokeColor,
                    material.highlightColor,
                    material.activeColor,
                    material.darkActiveColor,
                    material.activeIndexColor,
                    material.darkActiveIndexColor,
                    material.shadowColor,
                    material.joystickKnobColor,
                    material.darkJoystickKnobColor,
                    material.pressedFillColor,
                    material.darkPressedFillColor,
                    material.activeFillColor,
                    material.darkActiveFillColor,
                    material.disabledFillColor,
                    material.darkDisabledFillColor,
                    material.disabledForegroundColor,
                    material.darkDisabledForegroundColor,
                    material.disabledStrokeColor,
                    material.darkDisabledStrokeColor
                ].compactMap { $0 }
            for value in values where GamepadRGBAColor(hexString: value) == nil {
                issue(.error, "invalid-color", "Invalid material color \(value).", "materials[\(index)]")
            }
            if !(0...1).contains(material.depth) || !(0...1).contains(material.gloss) {
                issue(.error, "invalid-material-range", "Material depth and gloss must be between 0 and 1.", "materials[\(index)]")
            }
            if !(0.5...1).contains(material.pressedScale) {
                issue(.error, "invalid-pressed-scale", "Pressed scale must be between 0.5 and 1.", "materials[\(index)].pressedScale")
            }
            for (field, value) in [
                ("pressedShadowScale", material.pressedShadowScale),
                ("pressedInnerShadowScale", material.pressedInnerShadowScale),
                ("disabledOpacity", material.disabledOpacity)
            ] where value.map({ !(0...1).contains($0) }) == true {
                issue(.error, "invalid-material-range", "\(field) must be between 0 and 1.", "materials[\(index)].\(field)")
            }
            if material.shadowScale.map({ !(0...2).contains($0) }) == true {
                issue(.error, "invalid-material-range", "shadowScale must be between 0 and 2.", "materials[\(index)].shadowScale")
            }
            for (field, value) in [
                ("activeStrokeWidth", material.activeStrokeWidth),
                ("portraitActiveStrokeWidth", material.portraitActiveStrokeWidth),
                ("landscapeActiveStrokeWidth", material.landscapeActiveStrokeWidth),
                ("activeIndexWidth", material.activeIndexWidth),
                ("disabledStrokeWidth", material.disabledStrokeWidth)
            ] where value.map({ !(0...12).contains($0) }) == true {
                issue(.error, "invalid-material-range", "\(field) must be between 0 and 12.", "materials[\(index)].\(field)")
            }
        }
        for (index, component) in workspace.components.enumerated() where !materialIDs.contains(component.materialID) {
            issue(.error, "missing-material", "Component references missing material \(component.materialID).", "components[\(index)].materialID")
        }
        for (index, assignment) in workspace.assignments.enumerated() {
            if assignment.role == nil && assignment.button == nil {
                issue(.error, "empty-assignment", "A semantic assignment needs a role or button.", "assignments[\(index)]")
            }
            if !materialIDs.contains(assignment.materialID) {
                issue(.error, "missing-material", "Assignment references missing material \(assignment.materialID).", "assignments[\(index)].materialID")
            }
        }
        if !workspace.usesCSSAuthoring {
            if workspace.assignments.isEmpty {
                issue(.error, "missing-assignments", "Assign materials to semantic control roles.", "assignments")
            }
            let assignedRoles = Set(workspace.assignments.compactMap(\.role))
            for role in artboard.expectedRoles where role != .system && role != .decoration && !assignedRoles.contains(role) {
                issue(.warning, "unstyled-role", "Canonical artboard role \(role.rawValue) has no explicit material assignment.", "assignments")
            }
        }
        for orientation in workspace.orientations where !artboard.variants.contains(where: { $0.orientation == orientation }) {
            issue(.error, "unsupported-orientation", "The artboard has no \(orientation.rawValue) variant.", "orientations")
        }
        if Set(workspace.orientations) != Set(ThumbleSkinOrientation.allCases) {
            issue(.warning, "incomplete-orientation-matrix", "Directory-quality skins should intentionally support portrait and landscape.", "orientations")
        }
        if Set(workspace.colorSchemes) != Set(ThumbleSkinColorScheme.allCases) {
            issue(.warning, "incomplete-color-matrix", "Directory-quality skins should intentionally support light and dark.", "colorSchemes")
        }
        for (index, asset) in workspace.sourceAssets.enumerated() {
            if !ThumbleSkinPackageCodec.isSafePackagePath(asset.path, requiredRoot: "sources") {
                issue(.error, "unsafe-source-path", "Source assets must stay below sources/.", "sourceAssets[\(index)].path")
            }
            if !(16...4096).contains(asset.outputWidth) || !(16...4096).contains(asset.outputHeight) {
                issue(.error, "invalid-source-dimensions", "Source raster dimensions must be 16...4096.", "sourceAssets[\(index)]")
            }
            if asset.format != .png {
                issue(.warning, "unsupported-raster-format", "The current compiler emits deterministic PNG; WebP is reserved for a future encoder.", "sourceAssets[\(index)].format")
            }
        }
        if workspace.previews.isEmpty {
            issue(.warning, "missing-preview-matrix", "Declare native preview requests for visual review.", "previews")
        }
        return ThumbleSkinSourceValidationReport(issues: issues)
    }

    private static func checkUnique(
        _ ids: [String],
        path: String,
        issues: inout [ThumbleSkinSourceIssue]
    ) {
        var seen = Set<String>()
        for id in ids {
            let normalized = GamepadStyleToken.normalizedIdentifier(id)
            if normalized.isEmpty {
                issues.append(.init(severity: .error, code: "invalid-id", message: "IDs cannot be empty.", path: path))
            } else if !seen.insert(normalized).inserted {
                issues.append(.init(severity: .error, code: "duplicate-id", message: "Duplicate ID \(normalized).", path: path))
            }
        }
    }
}

public enum ThumbleSkinCompilerError: Error, LocalizedError {
    case missingSource(URL)
    case invalidSource(ThumbleSkinSourceValidationReport)
    case strictWarnings(ThumbleSkinSourceValidationReport)
    case cannotPrepareBuild(String)
    case unsupportedPlatform

    public var errorDescription: String? {
        switch self {
        case .missingSource(let url): "No skin-source.json exists at \(url.path)."
        case .invalidSource(let report): report.errors.first?.message ?? "Skin source validation failed."
        case .strictWarnings(let report): report.warnings.first?.message ?? "Strict skin source validation failed."
        case .cannotPrepareBuild(let message): "Could not prepare generated skin build: \(message)"
        case .unsupportedPlatform: "Skin compilation is supported by the macOS authoring CLI."
        }
    }
}

public struct ThumbleSkinCompilationResult: Sendable {
    public var workspace: ThumbleSkinWorkspace
    public var sourceReport: ThumbleSkinSourceValidationReport
    public var package: ThumbleSkinPackage
    public var packageData: Data
    public var buildDirectory: URL
    public var packageURL: URL

    public init(
        workspace: ThumbleSkinWorkspace,
        sourceReport: ThumbleSkinSourceValidationReport,
        package: ThumbleSkinPackage,
        packageData: Data,
        buildDirectory: URL,
        packageURL: URL
    ) {
        self.workspace = workspace
        self.sourceReport = sourceReport
        self.package = package
        self.packageData = packageData
        self.buildDirectory = buildDirectory
        self.packageURL = packageURL
    }
}

public enum ThumbleSkinCompiler {
    public static func sourceURL(for input: URL) -> URL {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: input.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return input.appendingPathComponent(ThumbleSkinScaffolder.sourceFileName)
        }
        return input
    }

    public static func containsWorkspace(at input: URL, fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: input.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return fileManager.fileExists(
                atPath: input.appendingPathComponent(ThumbleSkinScaffolder.sourceFileName).path
            )
        }
        return input.lastPathComponent == ThumbleSkinScaffolder.sourceFileName
            && fileManager.fileExists(atPath: input.path)
    }

    public static func loadWorkspace(from input: URL) throws -> (workspace: ThumbleSkinWorkspace, root: URL) {
        let source = sourceURL(for: input)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw ThumbleSkinCompilerError.missingSource(source)
        }
        let workspace = try JSONDecoder().decode(
            ThumbleSkinWorkspace.self,
            from: Data(contentsOf: source, options: [.mappedIfSafe])
        )
        return (workspace, source.deletingLastPathComponent())
    }

    public static func compile(
        source input: URL,
        buildDirectory requestedBuildDirectory: URL? = nil,
        packageOutputURL: URL? = nil,
        clean: Bool = false,
        strict: Bool = false,
        fileManager: FileManager = .default
    ) throws -> ThumbleSkinCompilationResult {
        #if !os(macOS)
        throw ThumbleSkinCompilerError.unsupportedPlatform
        #else
        let loaded = try loadWorkspace(from: input)
        var report = ThumbleSkinSourceValidator.validate(loaded.workspace)
        guard report.isValid else { throw ThumbleSkinCompilerError.invalidSource(report) }
        var cssCompilation: ThumbleCSSCompilation?
        var canvases: [ThumbleCompiledCanvas] = []
        if loaded.workspace.usesCSSAuthoring {
            do {
                cssCompilation = try ThumbleCSSCompiler.compile(
                    workspace: loaded.workspace,
                    sourceRoot: loaded.root,
                    fileManager: fileManager
                )
            } catch ThumbleCSSCompilerError.invalidCSS(let cssReport) {
                report.issues.append(contentsOf: cssReport.issues.map(\.sourceIssue))
                throw ThumbleSkinCompilerError.invalidSource(report)
            }
            report.issues.append(contentsOf: (cssCompilation?.report.warnings ?? []).map(\.sourceIssue))
        } else {
            canvases = try ThumbleVectorCompiler.compileCanvases(
                workspace: loaded.workspace,
                sourceRoot: loaded.root,
                fileManager: fileManager
            )
        }
        if strict, !report.warnings.isEmpty { throw ThumbleSkinCompilerError.strictWarnings(report) }
        let package = try makePackage(workspace: loaded.workspace, canvases: canvases, css: cssCompilation, sourceRoot: loaded.root, fileManager: fileManager)
        let packageData = try ThumbleSkinPackageCodec.encode(package)
        let decodedPackage = try ThumbleSkinPackageCodec.decode(packageData)
        let buildDirectory = requestedBuildDirectory ?? loaded.root.appendingPathComponent("build", isDirectory: true)
        let staging = buildDirectory.deletingLastPathComponent()
            .appendingPathComponent(".\(buildDirectory.lastPathComponent).staging-\(UUID().uuidString)", isDirectory: true)
        do {
            if fileManager.fileExists(atPath: staging.path) { try fileManager.removeItem(at: staging) }
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            try writeGeneratedPackageDirectory(decodedPackage, to: staging, fileManager: fileManager)
            let filename = suggestedFilename(loaded.workspace)
            let stagedPackage = staging.appendingPathComponent(filename)
            try packageData.write(to: stagedPackage, options: .atomic)
            if clean, fileManager.fileExists(atPath: buildDirectory.path) {
                try fileManager.removeItem(at: buildDirectory)
            }
            if fileManager.fileExists(atPath: buildDirectory.path) {
                try fileManager.removeItem(at: buildDirectory)
            }
            try fileManager.moveItem(at: staging, to: buildDirectory)
            let builtPackage = buildDirectory.appendingPathComponent(filename)
            if let packageOutputURL {
                try fileManager.createDirectory(at: packageOutputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try packageData.write(to: packageOutputURL, options: .atomic)
            }
            return ThumbleSkinCompilationResult(
                workspace: loaded.workspace,
                sourceReport: report,
                package: decodedPackage,
                packageData: packageData,
                buildDirectory: buildDirectory,
                packageURL: packageOutputURL ?? builtPackage
            )
        } catch let error as ThumbleSkinCompilerError {
            throw error
        } catch {
            try? fileManager.removeItem(at: staging)
            throw ThumbleSkinCompilerError.cannotPrepareBuild(error.localizedDescription)
        }
        #endif
    }

    private static func makePackage(
        workspace: ThumbleSkinWorkspace,
        canvases: [ThumbleCompiledCanvas],
        css: ThumbleCSSCompilation? = nil,
        sourceRoot: URL = URL(fileURLWithPath: "."),
        fileManager: FileManager = .default
    ) throws -> ThumbleSkinPackage {
        if let css {
            return try makeCSSPackage(workspace: workspace, css: css, sourceRoot: sourceRoot, fileManager: fileManager)
        }
        let materialByID = Dictionary(uniqueKeysWithValues: workspace.materials.map { ($0.id, $0) })
        let lightStyles = workspace.materials.compactMap { materialStyle($0, scheme: .light) }
        let darkStyles = workspace.materials.compactMap { materialStyle($0, scheme: .dark) }
        let roleRules = workspace.assignments.compactMap { assignment -> ThumbleSkinRoleRule? in
            guard let role = assignment.role, materialByID[assignment.materialID] != nil else { return nil }
            return ThumbleSkinRoleRule(
                role: role,
                appearance: ThumbleSkinControlAppearance(styleID: assignment.materialID)
            )
        }
        let buttonRules = workspace.assignments.compactMap { assignment -> ThumbleSkinButtonRule? in
            guard let button = assignment.button, materialByID[assignment.materialID] != nil else { return nil }
            return ThumbleSkinButtonRule(
                button: button,
                appearance: ThumbleSkinControlAppearance(styleID: assignment.materialID)
            )
        }
        let base = ThumbleSkinAppearance(
            accentStyle: .purple,
            showsButtonLabels: true,
            roleRules: roleRules,
            buttonRules: buttonRules,
            styleLibrary: GamepadStyleLibrary(styles: lightStyles)
        )
        var variants: [ThumbleSkinVariant] = []
        for scheme in workspace.colorSchemes {
            let joystickRules = workspace.assignments.compactMap { assignment -> ThumbleSkinRoleRule? in
                guard assignment.role == .joystick,
                      let material = materialByID[assignment.materialID]
                else { return nil }
                let colorString: String?
                switch scheme {
                case .light:
                    colorString = material.joystickKnobColor
                case .dark:
                    colorString = material.darkJoystickKnobColor ?? material.joystickKnobColor
                }
                guard let colorString, let color = GamepadRGBAColor(hexString: colorString) else { return nil }
                return ThumbleSkinRoleRule(
                    role: .joystick,
                    appearance: ThumbleSkinControlAppearance(joystickKnobColor: color)
                )
            }
            variants.append(ThumbleSkinVariant(
                id: "styles-\(scheme.rawValue)",
                colorScheme: scheme,
                appearance: ThumbleSkinAppearance(
                    roleRules: joystickRules,
                    styleLibrary: GamepadStyleLibrary(styles: scheme == .dark ? darkStyles : lightStyles)
                )
            ))
        }
        for orientation in workspace.orientations {
            let hasOrientationOverride = workspace.materials.contains { material in
                switch orientation {
                case .portrait: material.portraitActiveStrokeWidth != nil
                case .landscape: material.landscapeActiveStrokeWidth != nil
                }
            }
            guard hasOrientationOverride else { continue }
            for scheme in workspace.colorSchemes {
                let styles = workspace.materials.compactMap { material -> GamepadStyleToken? in
                    let width: CGFloat? = switch orientation {
                    case .portrait: material.portraitActiveStrokeWidth
                    case .landscape: material.landscapeActiveStrokeWidth
                    }
                    return materialStyle(
                        material,
                        scheme: scheme,
                        activeStrokeWidthOverride: width
                    )
                }
                variants.append(ThumbleSkinVariant(
                    id: "styles-\(orientation.rawValue)-\(scheme.rawValue)",
                    orientation: orientation,
                    colorScheme: scheme,
                    appearance: ThumbleSkinAppearance(
                        styleLibrary: GamepadStyleLibrary(styles: styles)
                    )
                ))
            }
        }
        for canvas in canvases {
            let image = GamepadImageFill(
                assetID: canvas.id,
                fileName: "\(canvas.id).png",
                contentMode: .fill
            )
            variants.append(ThumbleSkinVariant(
                id: "canvas-\(canvas.orientation.rawValue)-\(canvas.colorScheme.rawValue)",
                orientation: canvas.orientation,
                colorScheme: canvas.colorScheme,
                appearance: ThumbleSkinAppearance(backgroundFillStyle: .image(image))
            ))
        }
        let skin = ThumbleSkin(base: base, variants: variants)
        let assetDescriptors = canvases.map { canvas in
            ThumbleSkinResourceDescriptor(
                id: canvas.id,
                path: "assets/\(canvas.id).png",
                contentType: "image/png",
                role: .background,
                byteCount: canvas.data.count,
                sha256: canvas.data.thumbleSHA256
            )
        }
        let previewDescriptors = canvases.map { canvas in
            ThumbleSkinPreviewDescriptor(
                id: "preview-\(canvas.id)",
                path: "previews/\(canvas.id).png",
                orientation: canvas.orientation,
                colorScheme: canvas.colorScheme,
                byteCount: canvas.data.count,
                sha256: canvas.data.thumbleSHA256
            )
        }
        let artboard = ThumbleSkinArtboardCatalog.resolve(workspace.artboardID)
        let compatibleRoles = (artboard?.expectedRoles ?? [])
            .filter { ![GamepadVisualRole.system, .decoration, .custom].contains($0) }
        return ThumbleSkinPackage(
            manifest: ThumbleSkinManifest(
                identifier: workspace.identifier,
                version: workspace.version,
                name: workspace.name,
                author: workspace.author,
                summary: workspace.summary,
                license: workspace.license,
                minimumAppVersion: "1.0.0",
                tags: ["handcrafted", "agent-source", workspace.artboardID],
                assets: assetDescriptors,
                previews: previewDescriptors,
                compatibility: ThumbleSkinCompatibility(
                    mode: .templateAligned,
                    templates: artboard.map {
                        [ThumbleSkinTemplateRequirement(templateID: $0.templateID, minimumRevision: $0.revision, maximumRevision: $0.revision)]
                    } ?? [],
                    orientations: workspace.orientations,
                    minimumAspectRatio: 0.4,
                    maximumAspectRatio: 2.5,
                    requiredRoles: compatibleRoles,
                    requiredFeatures: [.bitmapControlStates]
                )
            ),
            skin: skin,
            assets: Dictionary(uniqueKeysWithValues: canvases.map { ($0.id, $0.data) }),
            previews: Dictionary(uniqueKeysWithValues: canvases.map { ("preview-\($0.id)", $0.data) })
        )
    }

    /// CSS-authored workspaces compile to the same package shape with resolved role/button
    /// styles and no rasterized material canvases. The background comes from `controller {}`.
    private static func makeCSSPackage(
        workspace: ThumbleSkinWorkspace,
        css: ThumbleCSSCompilation,
        sourceRoot: URL,
        fileManager: FileManager
    ) throws -> ThumbleSkinPackage {
        let variants = css.variants.map { lowered in
            ThumbleSkinVariant(
                id: "css-\(lowered.orientation?.rawValue ?? "any")-\(lowered.colorScheme?.rawValue ?? "any")",
                orientation: lowered.orientation,
                colorScheme: lowered.colorScheme,
                appearance: lowered.appearance
            )
        }
        let skin = ThumbleSkin(base: css.base, variants: variants)
        let artboard = ThumbleSkinArtboardCatalog.resolve(workspace.artboardID)
        let compatibleRoles = (artboard?.expectedRoles ?? [])
            .filter { ![GamepadVisualRole.system, .decoration, .custom].contains($0) }

        // CSS workspaces rasterize their declared SVG sourceAssets once and expose
        // them to stylesheets through url(#asset-id) references.
        let compiledAssets = try ThumbleVectorCompiler.compileSourceAssets(
            workspace: workspace,
            sourceRoot: sourceRoot,
            fileManager: fileManager
        )
        let assetDescriptors = compiledAssets.map { asset in
            ThumbleSkinResourceDescriptor(
                id: asset.id,
                path: "assets/\(asset.id).png",
                contentType: "image/png",
                role: asset.purpose == .canvasArtwork ? .background : (asset.purpose == .texture ? .texture : .icon),
                byteCount: asset.data.count,
                sha256: asset.data.thumbleSHA256
            )
        }
        return ThumbleSkinPackage(
            manifest: ThumbleSkinManifest(
                identifier: workspace.identifier,
                version: workspace.version,
                name: workspace.name,
                author: workspace.author,
                summary: workspace.summary,
                license: workspace.license,
                minimumAppVersion: "1.0.0",
                tags: ["handcrafted", "css", ThumbleCSSProfile.identifier, workspace.artboardID],
                assets: assetDescriptors,
                previews: [],
                compatibility: ThumbleSkinCompatibility(
                    mode: .templateAligned,
                    templates: artboard.map {
                        [ThumbleSkinTemplateRequirement(templateID: $0.templateID, minimumRevision: $0.revision, maximumRevision: $0.revision)]
                    } ?? [],
                    orientations: workspace.orientations,
                    minimumAspectRatio: 0.4,
                    maximumAspectRatio: 2.5,
                    requiredRoles: compatibleRoles,
                    requiredFeatures: []
                )
            ),
            skin: skin,
            assets: Dictionary(uniqueKeysWithValues: compiledAssets.map { ($0.id, $0.data) }),
            previews: [:]
        )
    }

    private static func materialStyle(
        _ material: ThumbleSkinMaterialSpec,
        scheme: ThumbleSkinColorScheme,
        activeStrokeWidthOverride: CGFloat? = nil
    ) -> GamepadStyleToken? {
        guard let base = GamepadRGBAColor(hexString: scheme == .dark ? (material.darkBaseColor ?? material.baseColor) : material.baseColor),
              let foreground = GamepadRGBAColor(hexString: scheme == .dark ? (material.darkForegroundColor ?? material.foregroundColor) : material.foregroundColor)
        else { return nil }
        let highlight = GamepadRGBAColor(hexString: material.highlightColor ?? "#FFFFFF") ?? foreground
        let activeColorString = scheme == .dark
            ? (material.darkActiveColor ?? material.activeColor)
            : material.activeColor
        let activeAccent = GamepadRGBAColor(
            hexString: activeColorString ?? material.highlightColor ?? material.foregroundColor
        ) ?? foreground
        let activeIndexColorString = scheme == .dark
            ? (material.darkActiveIndexColor ?? material.activeIndexColor)
            : material.activeIndexColor
        let activeIndexColor = activeIndexColorString.flatMap { GamepadRGBAColor(hexString: $0) }
        let shadow = GamepadRGBAColor(hexString: material.shadowColor ?? "#000000") ?? .defaultValue
        let strokeColorString = scheme == .dark
            ? (material.darkStrokeColor ?? material.strokeColor)
            : material.strokeColor
        let stroke = GamepadRGBAColor(
            hexString: strokeColorString ?? material.highlightColor ?? material.foregroundColor
        ) ?? foreground
        func stateColor(light: String?, dark: String?) -> GamepadRGBAColor? {
            let value = scheme == .dark ? (dark ?? light) : light
            return value.flatMap { GamepadRGBAColor(hexString: $0) }
        }
        let pressedFill = stateColor(light: material.pressedFillColor, dark: material.darkPressedFillColor)
        let activeFill = stateColor(light: material.activeFillColor, dark: material.darkActiveFillColor)
        let disabledFill = stateColor(light: material.disabledFillColor, dark: material.darkDisabledFillColor)
        let disabledForeground = stateColor(
            light: material.disabledForegroundColor,
            dark: material.darkDisabledForegroundColor
        )
        let disabledStroke = stateColor(
            light: material.disabledStrokeColor,
            dark: material.darkDisabledStrokeColor
        )
        let depth = min(max(material.depth, 0), 1)
        let gloss = min(max(material.gloss, 0), 1)
        let shadowScale = min(max(material.shadowScale ?? 1, 0), 2)
        let pressedShadowScale = min(max(material.pressedShadowScale ?? 1, 0), 1) * shadowScale
        let pressedInnerShadowScale = min(max(material.pressedInnerShadowScale ?? 1, 0), 1) * shadowScale
        let isMatte = material.kind == .matteRubber || material.kind == .inset
        let isLacquer = material.kind == .glossyPlastic
        let surfaceHighlightRadius: CGFloat = isMatte ? 2.4 : (isLacquer ? 0.6 : 1 + gloss * 1.4)
        let surfaceHighlightOpacity: CGFloat = isMatte ? 0.07 : (isLacquer ? 0.25 : 0.08 + gloss * 0.14)
        let surfaceBevelWidth: CGFloat = isMatte ? 0.75 : (isLacquer ? 1.6 : 0.6 + depth * 1.1)
        let fill: GamepadFillStyle
        switch material.kind {
        case .matteRubber, .inset:
            fill = .solid(base)
        default:
            fill = .gradient(GamepadGradientFill(
                type: .linear,
                angleDegrees: 135,
                stops: [
                    GamepadGradientStop(offset: 0, color: base.mixed(with: highlight, amount: 0.22 + gloss * 0.34)),
                    GamepadGradientStop(offset: 0.38, color: base),
                    GamepadGradientStop(offset: 1, color: base.mixed(with: shadow, amount: 0.22 + depth * 0.28))
                ]
            ))
        }
        let normalShadows: [GamepadControlShadowStyle] = shadowScale <= 0 ? [] : [
            GamepadControlShadowStyle(
                color: shadow.withAlpha((0.28 + depth * 0.22) * shadowScale),
                radius: (2 + depth * 3) * shadowScale,
                x: (1.5 + depth * 2) * shadowScale,
                y: (2 + depth * 2.5) * shadowScale
            )
        ]
        let normal = GamepadControlStateStyle(
            fillStyle: fill,
            foregroundColor: foreground,
            strokeColor: stroke.withAlpha(0.34 + gloss * 0.38),
            strokeWidth: 0.8 + gloss * 1.2,
            shadows: normalShadows,
            innerShadowColor: material.kind == .inset ? shadow.withAlpha(0.42 * shadowScale) : nil,
            innerShadowRadius: material.kind == .inset ? 7 * shadowScale : nil,
            innerShadowX: material.kind == .inset ? 3 * shadowScale : nil,
            innerShadowY: material.kind == .inset ? 4 * shadowScale : nil,
            highlightColor: highlight,
            highlightRadius: surfaceHighlightRadius,
            highlightX: -1 - gloss,
            highlightY: -1 - gloss,
            highlightOpacity: surfaceHighlightOpacity,
            bevelHighlightColor: highlight.withAlpha(isLacquer ? 0.72 : 0.24 + gloss * 0.24),
            bevelShadowColor: shadow.withAlpha(0.25 + depth * 0.30),
            bevelWidth: surfaceBevelWidth
        )
        let pressedShadows: [GamepadControlShadowStyle] = pressedShadowScale <= 0 ? [] : [
            GamepadControlShadowStyle(
                color: shadow.withAlpha(0.20 * pressedShadowScale),
                radius: 5 * pressedShadowScale,
                x: 2 * pressedShadowScale,
                y: 3 * pressedShadowScale
            )
        ]
        let pressed = GamepadControlStateStyle(
            fillStyle: .solid(pressedFill ?? base.mixed(with: shadow, amount: 0.10 + depth * 0.12)),
            shadows: pressedShadows,
            innerShadowColor: shadow.withAlpha((0.42 + depth * 0.22) * pressedInnerShadowScale),
            innerShadowRadius: (5 + depth * 6) * pressedInnerShadowScale,
            innerShadowX: (2 + depth * 2) * pressedInnerShadowScale,
            innerShadowY: (3 + depth * 2) * pressedInnerShadowScale,
            highlightOpacity: 0.04,
            scale: material.pressedScale
        )
        let active = GamepadControlStateStyle(
            fillStyle: activeFill.map(GamepadFillStyle.solid),
            strokeColor: activeAccent.withAlpha(0.96),
            strokeWidth: activeStrokeWidthOverride ?? material.activeStrokeWidth ?? (1.5 + gloss * 0.5),
            highlightColor: highlight,
            highlightRadius: surfaceHighlightRadius,
            highlightX: -1 - gloss,
            highlightY: -1 - gloss,
            highlightOpacity: surfaceHighlightOpacity,
            indexColor: activeIndexColor,
            indexWidth: material.activeIndexWidth,
            scale: 1
        )
        let disabled = GamepadControlStateStyle(
            fillStyle: .solid(disabledFill ?? base.mixed(with: shadow, amount: 0.14)),
            foregroundColor: disabledForeground ?? foreground,
            strokeColor: disabledStroke ?? stroke.mixed(with: base, amount: 0.36),
            strokeWidth: material.disabledStrokeWidth ?? 0.8,
            shadows: [],
            highlightOpacity: 0,
            bevelHighlightColor: highlight.withAlpha(0.12),
            bevelShadowColor: shadow.withAlpha(0.20),
            bevelWidth: 0.6,
            opacity: material.disabledOpacity ?? 0.90,
            scale: 1
        )
        let style = GamepadControlVisualStyle(
            normal: normal,
            pressed: pressed,
            active: active,
            disabled: disabled,
            hapticFeedback: material.hapticFeedback
        )
        return GamepadStyleToken(
            id: material.id,
            name: material.name,
            visualStyle: style
        ).normalized
    }

    private static func writeGeneratedPackageDirectory(
        _ package: ThumbleSkinPackage,
        to directory: URL,
        fileManager: FileManager
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(package.manifest).write(
            to: directory.appendingPathComponent("manifest.json"),
            options: .atomic
        )
        if let skin = package.skin {
            try encoder.encode(skin).write(to: directory.appendingPathComponent("skin.json"), options: .atomic)
        }
        for descriptor in package.manifest.assets {
            guard let data = package.assets[descriptor.id] else { continue }
            let url = directory.appendingPathComponent(descriptor.path)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
        for descriptor in package.manifest.previews {
            guard let data = package.previews[descriptor.id] else { continue }
            let url = directory.appendingPathComponent(descriptor.path)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
    }

    private static func suggestedFilename(_ workspace: ThumbleSkinWorkspace) -> String {
        let slug = workspace.name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { result, character in
                if character == "-", result.last == "-" { return }
                result.append(character)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "\(slug)-\(workspace.version).pocketpad"
    }
}
