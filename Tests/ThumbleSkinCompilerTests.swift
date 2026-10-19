import Foundation
import XCTest

@MainActor
final class ThumbleSkinCompilerTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThumbleSkinCompilerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
    }

    func testCompilerProducesDeterministicPackageAssetsStatesAndBuildDirectory() throws {
        let source = try makePublishableWorkspace()
        let first = try ThumbleSkinCompiler.compile(source: source, clean: true, strict: true)
        let second = try ThumbleSkinCompiler.compile(source: source, clean: true, strict: true)

        XCTAssertEqual(first.packageData, second.packageData)
        XCTAssertEqual(first.package.manifest.identifier, "com.example.indigo-pocket")
        XCTAssertEqual(first.package.manifest.previews.count, 4)
        XCTAssertEqual(first.package.manifest.assets.count, 4)
        XCTAssertTrue(first.package.manifest.tags.contains("handcrafted"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.packageURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.buildDirectory.appendingPathComponent("skin.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.buildDirectory.appendingPathComponent("assets/canvas-landscape-dark.png").path))

        let report = ThumbleSkinPackageValidator.validate(second.package)
        XCTAssertTrue(report.isValid)
        XCTAssertTrue(report.warnings.isEmpty, "\(report.warnings)")

        let skin = try XCTUnwrap(second.package.skin)
        let dark = skin.appearance(orientation: .landscape, colorScheme: .dark)
        guard case .image(let background)? = dark.backgroundFillStyle else {
            return XCTFail("Expected compiled background image")
        }
        XCTAssertEqual(background.assetID, "canvas-landscape-dark")
        let action = dark.controlAppearance(for: .primaryAction)
        let styleID = try XCTUnwrap(action.styleID)
        let style = try XCTUnwrap(dark.styleLibrary.style(id: styleID)?.visualStyle)
        XCTAssertNotNil(style.pressed)
        XCTAssertNotNil(style.active)
        XCTAssertNotNil(style.disabled)
        XCTAssertLessThan(style.pressed?.scale ?? 1, 1)

        let png = try XCTUnwrap(second.package.assets["canvas-landscape-dark"])
        XCTAssertEqual(Array(png.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        XCTAssertEqual(readBigEndianUInt32(png, at: 16), 1748)
        XCTAssertEqual(readBigEndianUInt32(png, at: 20), 804)
    }

    func testLegacyWorkspaceStillCompilesToCommittedGoldenPackage() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = repository.appendingPathComponent("docs/skins/examples/indigo-pocket", isDirectory: true)
        let golden = source.appendingPathComponent("dist/indigo-pocket-1.0.0.pocketpad")
        let build = temporaryDirectory.appendingPathComponent("golden-build", isDirectory: true)
        let output = temporaryDirectory.appendingPathComponent("indigo-pocket-1.0.0.pocketpad")

        let result = try ThumbleSkinCompiler.compile(
            source: source,
            buildDirectory: build,
            packageOutputURL: output,
            clean: true,
            strict: true
        )

        XCTAssertEqual(result.packageData, try Data(contentsOf: golden))
        XCTAssertEqual(result.packageData.thumbleSHA256, "d88d237a01c42a70e8bdce8577a2efe3e036ab09fa0840e9822d123a85b7f037")
    }

    func testCompilerMapsOptionalMaterialStateControlsAndJoystickColors() throws {
        let source = try makePublishableWorkspace()
        let sourceURL = source.appendingPathComponent("skin-source.json")
        var workspace = try JSONDecoder().decode(ThumbleSkinWorkspace.self, from: Data(contentsOf: sourceURL))
        let materialID = workspace.materials[0].id
        workspace.materials[0].darkStrokeColor = "#8899AA"
        workspace.materials[0].joystickKnobColor = "#224466"
        workspace.materials[0].darkJoystickKnobColor = "#88AACC"
        workspace.materials[0].pressedFillColor = "#102030"
        workspace.materials[0].darkPressedFillColor = "#203040"
        workspace.materials[0].activeFillColor = "#304050"
        workspace.materials[0].darkActiveFillColor = "#405060"
        workspace.materials[0].activeColor = "#FFD060"
        workspace.materials[0].darkActiveColor = "#FFF080"
        workspace.materials[0].disabledFillColor = "#505050"
        workspace.materials[0].darkDisabledFillColor = "#606060"
        workspace.materials[0].disabledForegroundColor = "#F0F0F0"
        workspace.materials[0].darkDisabledForegroundColor = "#E0E0E0"
        workspace.materials[0].disabledStrokeColor = "#A0A0A0"
        workspace.materials[0].darkDisabledStrokeColor = "#B0B0B0"
        workspace.materials[0].shadowScale = 0.25
        workspace.materials[0].pressedShadowScale = 0.2
        workspace.materials[0].pressedInnerShadowScale = 0.1
        workspace.materials[0].activeStrokeWidth = 3.5
        workspace.materials[0].portraitActiveStrokeWidth = 4.5
        workspace.materials[0].landscapeActiveStrokeWidth = 2.5
        workspace.materials[0].activeIndexColor = "#AABBCC"
        workspace.materials[0].darkActiveIndexColor = "#CCDDEE"
        workspace.materials[0].activeIndexWidth = 2
        workspace.materials[0].disabledStrokeWidth = 2.5
        workspace.materials[0].disabledOpacity = 0.94
        workspace.assignments.append(ThumbleSemanticStyleAssignment(role: .joystick, materialID: materialID))
        try write(workspace, to: sourceURL)

        let result = try ThumbleSkinCompiler.compile(source: source, clean: true, strict: true)
        let skin = try XCTUnwrap(result.package.skin)
        let light = skin.appearance(orientation: .landscape, colorScheme: .light)
        let dark = skin.appearance(orientation: .landscape, colorScheme: .dark)
        let lightStyle = try XCTUnwrap(light.styleLibrary.style(id: materialID)?.visualStyle)
        let darkStyle = try XCTUnwrap(dark.styleLibrary.style(id: materialID)?.visualStyle)

        XCTAssertEqual(lightStyle.pressed?.fillStyle?.representativeColor.hexString, "#102030")
        XCTAssertEqual(darkStyle.pressed?.fillStyle?.representativeColor.hexString, "#203040")
        XCTAssertEqual(lightStyle.active?.fillStyle?.representativeColor.hexString, "#304050")
        XCTAssertEqual(darkStyle.active?.fillStyle?.representativeColor.hexString, "#405060")
        XCTAssertEqual(lightStyle.active?.strokeWidth, 2.5)
        XCTAssertEqual(darkStyle.active?.strokeWidth, 2.5)
        let portraitLight = skin.appearance(orientation: .portrait, colorScheme: .light)
        let portraitStyle = try XCTUnwrap(portraitLight.styleLibrary.style(id: materialID)?.visualStyle)
        XCTAssertEqual(portraitStyle.active?.strokeWidth, 4.5)
        XCTAssertEqual(lightStyle.active?.indexColor?.hexString, "#AABBCC")
        XCTAssertEqual(darkStyle.active?.indexColor?.hexString, "#CCDDEE")
        XCTAssertEqual(lightStyle.active?.indexWidth, 2)
        XCTAssertEqual(lightStyle.disabled?.fillStyle?.representativeColor.hexString, "#505050")
        XCTAssertEqual(darkStyle.disabled?.fillStyle?.representativeColor.hexString, "#606060")
        XCTAssertEqual(lightStyle.disabled?.strokeColor?.hexString, "#A0A0A0")
        XCTAssertEqual(darkStyle.disabled?.strokeColor?.hexString, "#B0B0B0")
        XCTAssertEqual(lightStyle.disabled?.strokeWidth, 2.5)
        XCTAssertEqual(lightStyle.disabled?.opacity, 0.94)
        XCTAssertEqual(light.controlAppearance(for: .joystick).joystickKnobColor?.hexString, "#224466")
        XCTAssertEqual(dark.controlAppearance(for: .joystick).joystickKnobColor?.hexString, "#88AACC")
        XCTAssertLessThan(lightStyle.normal.shadows?.first?.radius ?? 10, 2)
        XCTAssertLessThan(lightStyle.pressed?.innerShadowRadius ?? 10, 1)
    }

    func testSourceValidatorRejectsInvalidOptionalMaterialColorsAndRanges() {
        var workspace = ThumbleSkinWorkspace.starter(
            name: "Invalid States",
            identifier: "com.example.invalid-states",
            artboardID: "classic-16-bit-v1"
        )
        workspace.materials[0].disabledFillColor = "not-a-color"
        workspace.materials[0].shadowScale = 3
        workspace.materials[0].pressedShadowScale = -0.1
        workspace.materials[0].activeStrokeWidth = 13
        workspace.materials[0].portraitActiveStrokeWidth = 13
        workspace.materials[0].landscapeActiveStrokeWidth = 13
        workspace.materials[0].activeIndexWidth = 13
        workspace.materials[0].disabledOpacity = 1.1

        let report = ThumbleSkinSourceValidator.validate(workspace)
        XCTAssertTrue(report.errors.contains { $0.code == "invalid-color" })
        XCTAssertGreaterThanOrEqual(report.errors.filter { $0.code == "invalid-material-range" }.count, 7)
    }

    func testWorkspaceDetectionDoesNotTreatExistingPackageAsJSONSource() throws {
        let workspace = temporaryDirectory.appendingPathComponent("Workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let source = workspace.appendingPathComponent(ThumbleSkinScaffolder.sourceFileName)
        try Data("{}".utf8).write(to: source)
        let package = temporaryDirectory.appendingPathComponent("skin.pocketpad")
        try Data([0x50, 0x4B, 0x03, 0x04]).write(to: package)

        XCTAssertTrue(ThumbleSkinCompiler.containsWorkspace(at: workspace))
        XCTAssertTrue(ThumbleSkinCompiler.containsWorkspace(at: source))
        XCTAssertFalse(ThumbleSkinCompiler.containsWorkspace(at: package))
    }

    func testSourceValidatorFindsBrokenIdentityReferencesColorsAndMatrix() throws {
        var workspace = ThumbleSkinWorkspace.starter(
            name: "Broken",
            identifier: "bad",
            artboardID: "classic-16-bit-v1"
        )
        workspace.version = "one"
        workspace.materials[0].baseColor = "not-a-color"
        workspace.components[0].materialID = "missing"
        workspace.assignments = [ThumbleSemanticStyleAssignment(materialID: "missing")]
        workspace.orientations = [.landscape]
        workspace.previews = []

        let report = ThumbleSkinSourceValidator.validate(workspace)
        let errors = Set(report.errors.map(\.code))
        let warnings = Set(report.warnings.map(\.code))
        XCTAssertTrue(errors.contains("invalid-identifier"))
        XCTAssertTrue(errors.contains("invalid-version"))
        XCTAssertTrue(errors.contains("invalid-color"))
        XCTAssertTrue(errors.contains("missing-material"))
        XCTAssertTrue(errors.contains("empty-assignment"))
        XCTAssertTrue(warnings.contains("incomplete-orientation-matrix"))
        XCTAssertTrue(warnings.contains("missing-preview-matrix"))
    }

    func testSVGSanitizerRejectsExecutableExternalAndPathologicalSources() throws {
        let safe = Data(#"<svg xmlns="http://www.w3.org/2000/svg"><defs><linearGradient id="a"/></defs><path fill="url(#a)" d="M0 0L1 1"/></svg>"#.utf8)
        XCTAssertEqual(try ThumbleSVGRasterizer.sanitize(safe), safe)

        for source in [
            #"<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>"#,
            #"<!DOCTYPE svg [<!ENTITY xxe SYSTEM "file:///etc/passwd">]><svg/>"#,
            #"<svg xmlns="http://www.w3.org/2000/svg"><image href="https://example.com/a.png"/></svg>"#,
            #"<svg xmlns="http://www.w3.org/2000/svg"><rect onclick="run()"/></svg>"#,
            #"<svg xmlns="http://www.w3.org/2000/svg"><style>.x{fill:url(https://example.com/a)}</style></svg>"#
        ] {
            XCTAssertThrowsError(try ThumbleSVGRasterizer.sanitize(Data(source.utf8)), source)
        }
        XCTAssertThrowsError(try ThumbleSVGRasterizer.sanitize(Data(repeating: 65, count: ThumbleSVGRasterizer.maximumSourceBytes + 1)))
    }

    func testVectorCompilerRejectsTraversalAndSymlinkSources() throws {
        let source = try makePublishableWorkspace()
        let sourceURL = source.appendingPathComponent("skin-source.json")
        var workspace = try JSONDecoder().decode(ThumbleSkinWorkspace.self, from: Data(contentsOf: sourceURL))
        workspace.sourceAssets[0].path = "sources/../outside.svg"
        try write(workspace, to: sourceURL)
        XCTAssertThrowsError(try ThumbleSkinCompiler.compile(source: source))

        workspace.sourceAssets[0].path = "sources/artwork/link.svg"
        try write(workspace, to: sourceURL)
        let outside = temporaryDirectory.appendingPathComponent("outside.svg")
        try Data(#"<svg xmlns="http://www.w3.org/2000/svg"/>"#.utf8).write(to: outside)
        let link = source.appendingPathComponent("sources/artwork/link.svg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try ThumbleSkinCompiler.compile(source: source))
    }

    func testPNGSourcePreservesBytesAndRejectsMalformedMismatchedOrOversizedInput() throws {
        let source = try makePublishableWorkspace()
        var workspace = try JSONDecoder().decode(ThumbleSkinWorkspace.self, from: Data(contentsOf: source.appendingPathComponent("skin-source.json")))
        let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64"><rect width="64" height="64" fill='#D7B673'/></svg>"#.utf8)
        let original = try ThumbleSVGRasterizer.rasterize(svg, width: 64, height: 64)
        let url = source.appendingPathComponent("sources/artwork/ability.png")
        try original.write(to: url)
        workspace.sourceAssets = [.init(id: "ability", path: "sources/artwork/ability.png", purpose: .icon, outputWidth: 64, outputHeight: 64)]
        let compiled = try ThumbleVectorCompiler.compileSourceAssets(workspace: workspace, sourceRoot: source)
        XCTAssertEqual(compiled.first?.data, original, "Native icons must retain original PNG bytes")
        workspace.sourceAssets[0].outputWidth = 63
        XCTAssertThrowsError(try ThumbleVectorCompiler.compileSourceAssets(workspace: workspace, sourceRoot: source))
        workspace.sourceAssets[0].outputWidth = 64
        try original.prefix(32).write(to: url)
        XCTAssertThrowsError(try ThumbleVectorCompiler.compileSourceAssets(workspace: workspace, sourceRoot: source))
        try Data(repeating: 0, count: GamepadImageFill.maximumStoredBytes + 1).write(to: url)
        XCTAssertThrowsError(try ThumbleVectorCompiler.compileSourceAssets(workspace: workspace, sourceRoot: source)) { error in
            XCTAssertEqual(error as? ThumbleVectorCompilerError, .outputTooLarge("ability"))
        }
    }

    private func makePublishableWorkspace() throws -> URL {
        let source = temporaryDirectory.appendingPathComponent("IndigoPocket", isDirectory: true)
        var workspace = try ThumbleSkinScaffolder.write(
            name: "Indigo Pocket",
            identifier: "com.example.indigo-pocket",
            artboardID: "classic-16-bit-v1",
            to: source
        )
        workspace.author = ThumbleSkinAuthor(name: "Example Designer", url: URL(string: "https://example.com"))
        workspace.summary = "A carefully authored translucent indigo controller with rubber movement controls and glossy action buttons."
        workspace.license = "MIT"
        try write(workspace, to: source.appendingPathComponent("skin-source.json"))
        return source
    }

    private func write(_ workspace: ThumbleSkinWorkspace, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(workspace).write(to: url, options: .atomic)
    }

    private func readBigEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}
