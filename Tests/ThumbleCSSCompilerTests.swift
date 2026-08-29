import Foundation
import XCTest

@MainActor
final class ThumbleCSSCompilerTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThumbleCSSCompilerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
    }

    // MARK: - Workspace fixtures

    private func makeCSSWorkspace(
        css: String,
        artboardID: String = "showcase-controller-v1",
        identifier: String = "com.example.css-tests"
    ) throws -> URL {
        let source = temporaryDirectory.appendingPathComponent("CSSSkin", isDirectory: true)
        var workspace = ThumbleSkinWorkspace.starterCSS(
            name: "CSS Test",
            identifier: identifier,
            artboardID: artboardID
        )
        workspace.author = ThumbleSkinAuthor(name: "CSS Test Author")
        workspace.summary = "A CSS-authored controller skin exercising the thumble-css-core-1 profile."
        workspace.orientations = [.landscape, .portrait]
        workspace.colorSchemes = [.light, .dark]
        workspace.previews = [
            ThumblePreviewRequest(id: "landscape-light", artboardID: artboardID, orientation: .landscape, colorScheme: .light),
            ThumblePreviewRequest(id: "landscape-dark", artboardID: artboardID, orientation: .landscape, colorScheme: .dark)
        ]
        try write(workspace, css: css, to: source)
        return source
    }

    private func write(_ workspace: ThumbleSkinWorkspace, css: String, to source: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: source.appendingPathComponent("styles"), withIntermediateDirectories: true)
        try encoder.encode(workspace).write(
            to: source.appendingPathComponent(ThumbleSkinScaffolder.sourceFileName),
            options: .atomic
        )
        try css.write(
            to: source.appendingPathComponent("styles/controller.css"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func loadWorkspace(_ source: URL) throws -> ThumbleSkinWorkspace {
        try JSONDecoder().decode(
            ThumbleSkinWorkspace.self,
            from: Data(contentsOf: source.appendingPathComponent(ThumbleSkinScaffolder.sourceFileName))
        )
    }

    // MARK: - Parser

    func testParserAcceptsSelectorsMediaCustomPropertiesAndStates() throws {
        let source = try makeCSSWorkspace(css: """
            /* comment */
            :root { --accent: #7C61A8; }
            controller { background: linear-gradient(160deg, #E9E4F2, #C9C2D2); }
            control, control[kind="button"] {
              color: var(--accent);
              border: 1px solid rgba(255, 255, 255, 0.6);
              box-shadow: 0 2px 4px #101027, inset 1px 1px 2px #FFFFFF;
            }
            control:pressed { transform: scale(0.96); }
            control:disabled { opacity: 0.45; }
            @media (prefers-color-scheme: dark) {
              :root { --accent: #B8A0E8; }
              controller { background: #17143B; }
            }
            """)
        let report = ThumbleCSSCompiler.lint(workspace: try loadWorkspace(source), sourceRoot: source)
        XCTAssertTrue(report.isValid, "\(report.issues)")
    }

    func testLintRejectsUnsupportedConstructsWithStrictDiagnostics() throws {
        for (css, code) in [
            ("control { display: flex; }", "unsupported-property"),
            ("control { color: red !important; }", "important-unsupported"),
            ("@import url(\"evil.css\");", "unsupported-at-rule"),
            ("control:hover { color: red; }", "unsupported-pseudo-class"),
            ("control::before { color: red; }", "unsupported-selector"),
            ("a > b { color: red; }", "unknown-type-selector"),
            ("control { background: url(https://example.com/x.png); }", "invalid-value"),
            ("@media (min-width: 100px) { }", "unsupported-media"),
            ("@media (prefers-color-scheme: dark) , (orientation: portrait) { }", "unsupported-media")
        ] {
            let source = try makeCSSWorkspace(css: css)
            let report = ThumbleCSSCompiler.lint(workspace: try loadWorkspace(source), sourceRoot: source)
            XCTAssertTrue(
                report.errors.contains { $0.code == code },
                "expected \(code) for \(css); got \(report.errors.map(\.code))"
            )
        }
    }

    func testLintWarnsWhenSelectorMatchesNothing() throws {
        let source = try makeCSSWorkspace(css: "joystick { border-radius: 50%; }", artboardID: "classic-16-bit-v1")
        let report = ThumbleCSSCompiler.lint(workspace: try loadWorkspace(source), sourceRoot: source)
        XCTAssertTrue(report.warnings.contains { $0.code == "selector-matches-nothing" })
    }

    // MARK: - Cascade semantics

    func testComputedStyleAppliesSpecificitySourceOrderStatesAndVariables() throws {
        let source = try makeCSSWorkspace(css: """
            :root { --ink: #111111; }
            control { color: #AAAAAA; background: #DDDDDD; }
            control[role="primary_action"] { background: #702653; }
            #builtin-jump { background: #0000FF; }
            control:pressed { transform: scale(0.9); }
            @media (prefers-color-scheme: dark) {
              :root { --ink: #EEEEEE; }
            }
            """)
        let documents = try ThumbleCSSCompiler.computed(
            workspace: try loadWorkspace(source),
            sourceRoot: source
        )
        let light = try XCTUnwrap(documents.first { $0.orientation == "landscape" && $0.colorScheme == "light" })
        let dark = try XCTUnwrap(documents.first { $0.orientation == "landscape" && $0.colorScheme == "dark" })

        func declarations(_ element: ThumbleCSSCompiler.ComputedElementStyles, _ state: String) throws -> [String: String] {
            try XCTUnwrap(element.states.first { $0.state == state }?.declarations)
        }

        let jump = try XCTUnwrap(light.elements.first { $0.id == "builtin-jump" })
        // ID selector wins over attribute and type selectors.
        XCTAssertEqual(try declarations(jump, "normal")["background"], "#0000FF")
        // State declarations appear only on their state.
        XCTAssertNil(try declarations(jump, "normal")["transform"])
        XCTAssertEqual(try declarations(jump, "pressed")["transform"], "scale(0.9)")
        // Custom properties inherit from the controller root and resolve per scheme.
        XCTAssertEqual(try declarations(jump, "normal")["--ink"], "#111111")
        let darkJump = try XCTUnwrap(dark.elements.first { $0.id == "builtin-jump" })
        XCTAssertEqual(try declarations(darkJump, "normal")["--ink"], "#EEEEEE")

        // Attribute selector beats the bare type selector for other primary-action controls.
        let attack = try XCTUnwrap(light.elements.first { $0.id == "builtin-attack" })
        XCTAssertEqual(try declarations(attack, "normal")["background"], "#702653")
    }

    func testUndefinedVariableWithoutFallbackIsAnError() throws {
        let source = try makeCSSWorkspace(css: "control { color: var(--missing); }")
        let report = ThumbleCSSCompiler.lint(workspace: try loadWorkspace(source), sourceRoot: source)
        XCTAssertTrue(report.errors.contains { $0.code == "undefined-custom-property" }, "\(report.issues)")
        let threw = expectation(description: "compile throws")
        do {
            _ = try ThumbleSkinCompiler.compile(source: source, strict: false)
        } catch {
            threw.fulfill()
        }
        wait(for: [threw], timeout: 5)
    }

    func testCustomPropertyCycleIsRejected() throws {
        let source = try makeCSSWorkspace(css: """
            :root { --a: var(--b); --b: var(--a); }
            control { color: var(--a); }
            """)
        let threw = expectation(description: "compile throws")
        do {
            _ = try ThumbleSkinCompiler.compile(source: source, strict: false)
        } catch {
            threw.fulfill()
        }
        wait(for: [threw], timeout: 5)
    }

    // MARK: - Lowering to the native model

    func testCompileLowersCSSIntoDeterministicPackageWithRoleAndButtonRules() throws {
        let source = try makeCSSWorkspace(css: """
            :root { --surface: #F2EEF5; }
            controller { background: linear-gradient(160deg, #E9E4F2, #C9C2D2); }
            control {
              color: #7C61A8;
              background: var(--surface);
              border: 1px solid #FFFFFF;
              border-radius: 14px;
              box-shadow: 0 2px 4px #101027;
            }
            control:pressed { transform: scale(0.96); }
            control:disabled { opacity: 0.45; }
            control[role="primary_action"] { background: #702653; color: #FFFFFF; }
            @media (prefers-color-scheme: dark) {
              :root { --surface: #211A46; }
              controller { background: #17143B; }
            }
            """)
        let first = try ThumbleSkinCompiler.compile(source: source, strict: true)
        let second = try ThumbleSkinCompiler.compile(source: source, strict: true)
        XCTAssertEqual(first.packageData, second.packageData, "CSS packages must compile byte-identically")

        let validation = ThumbleSkinPackageValidator.validate(second.package)
        XCTAssertTrue(validation.isValid, "\(validation.issues)")
        XCTAssertTrue(first.package.manifest.tags.contains("css"))

        let skin = try XCTUnwrap(second.package.skin)
        let light = skin.appearance(orientation: .landscape, colorScheme: .light)
        let dark = skin.appearance(orientation: .landscape, colorScheme: .dark)

        // Controller background lowers per scheme.
        XCTAssertEqual(light.backgroundFillStyle?.representativeColor.hexString, "#D9D3E2")
        XCTAssertEqual(dark.backgroundFillStyle?.representativeColor.hexString, "#17143B")

        // Default control style from `control` with var() resolution.
        let defaultStyleID = try XCTUnwrap(light.defaultControl?.styleID)
        let defaultStyle = try XCTUnwrap(light.styleLibrary.style(id: defaultStyleID)?.visualStyle)
        XCTAssertEqual(defaultStyle.normal.foregroundColor?.hexString, "#7C61A8")
        XCTAssertEqual(defaultStyle.normal.strokeColor?.hexString, "#FFFFFF")
        XCTAssertEqual(defaultStyle.normal.strokeWidth, 1)
        XCTAssertEqual(light.defaultControl?.cornerRadius, 14)
        XCTAssertEqual(defaultStyle.normal.shadows?.count, 1)
        XCTAssertEqual(defaultStyle.pressed?.scale, 0.96)
        XCTAssertEqual(defaultStyle.disabled?.opacity, 0.45)

        // Dark variant resolves the same variable differently.
        let darkDefault = try XCTUnwrap(dark.styleLibrary.style(id: defaultStyleID)?.visualStyle)
        XCTAssertEqual(darkDefault.normal.fillStyle?.representativeColor.hexString, "#211A46")
        XCTAssertEqual(defaultStyle.normal.fillStyle?.representativeColor.hexString, "#F2EEF5")

        // Role rules attach per-role tokens; primary action wins for its controls via button rules.
        let primaryRule = try XCTUnwrap(light.roleRules.first { $0.role == .primaryAction })
        let primaryStyle = try XCTUnwrap(light.styleLibrary.style(id: primaryRule.appearance.styleID ?? "")?.visualStyle)
        XCTAssertEqual(primaryStyle.normal.fillStyle?.representativeColor.hexString, "#702653")
        let jumpAppearance = light.controlAppearance(for: .jump, controlKind: .button)
        let jumpStyle = try XCTUnwrap(light.styleLibrary.style(id: jumpAppearance.styleID ?? "")?.visualStyle)
        XCTAssertEqual(jumpStyle.normal.fillStyle?.representativeColor.hexString, "#702653")
    }

    func testInsetBoxShadowLowersToInnerShadow() throws {
        let source = try makeCSSWorkspace(css: """
            control {
              background: #EEEEEE;
              box-shadow: inset 2px 3px 5px #333333;
            }
            """)
        let result = try ThumbleSkinCompiler.compile(source: source, strict: true)
        let skin = try XCTUnwrap(result.package.skin)
        let appearance = skin.appearance(orientation: .landscape, colorScheme: .light)
        let styleID = try XCTUnwrap(appearance.defaultControl?.styleID)
        let style = try XCTUnwrap(appearance.styleLibrary.style(id: styleID)?.visualStyle)
        XCTAssertEqual(style.normal.innerShadowColor?.hexString, "#333333")
        XCTAssertEqual(style.normal.innerShadowRadius, 5)
        XCTAssertEqual(style.normal.innerShadowX, 2)
        XCTAssertEqual(style.normal.innerShadowY, 3)
    }

    func testJoystickKnobColorLowersThroughRoleRule() throws {
        let source = try makeCSSWorkspace(css: """
            control { background: #EEEEEE; }
            control[role="joystick"] { -thumble-knob-color: #A77CFF; }
            """, artboardID: "xbox-v1")
        let result = try ThumbleSkinCompiler.compile(source: source, strict: true)
        let skin = try XCTUnwrap(result.package.skin)
        let appearance = skin.appearance(orientation: .landscape, colorScheme: .light)
        XCTAssertEqual(appearance.controlAppearance(for: .joystick).joystickKnobColor?.hexString, "#A77CFF")
    }

    // MARK: - Workspace validation and scaffolding

    func testValidatorAcceptsSchemaTwoAndRejectsUnsafeStylesheetPaths() throws {
        let source = try makeCSSWorkspace(css: "control { background: #EEEEEE; }")
        var workspace = try loadWorkspace(source)
        XCTAssertTrue(ThumbleSkinSourceValidator.validate(workspace).isValid)

        workspace.schemaVersion = 1
        let legacyReport = ThumbleSkinSourceValidator.validate(workspace)
        XCTAssertTrue(legacyReport.errors.contains { $0.code == "stylesheets-require-schema-2" })

        workspace.schemaVersion = 2
        workspace.stylesheets = ["../outside.css"]
        let traversalReport = ThumbleSkinSourceValidator.validate(workspace)
        XCTAssertTrue(traversalReport.errors.contains { $0.code == "unsafe-stylesheet-path" })

        workspace.stylesheets = ["styles/a.css", "styles/a.css"]
        let duplicateReport = ThumbleSkinSourceValidator.validate(workspace)
        XCTAssertTrue(duplicateReport.errors.contains { $0.code == "duplicate-stylesheet" })
    }

    func testCSSWorkspaceDecodingRoundTripsAndOmitsEmptyStylesheets() throws {
        let source = try makeCSSWorkspace(css: "control { background: #EEEEEE; }")
        let data = try Data(contentsOf: source.appendingPathComponent(ThumbleSkinScaffolder.sourceFileName))
        let decoded = try JSONDecoder().decode(ThumbleSkinWorkspace.self, from: data)
        XCTAssertEqual(decoded.stylesheets, ["styles/controller.css"])
        XCTAssertEqual(decoded.schemaVersion, 2)

        // Schema-1 material workspaces decode with empty stylesheets and re-encode without the key.
        let materialData = try JSONEncoder().encode(ThumbleSkinWorkspace.starter(
            name: "Material",
            identifier: "com.example.material",
            artboardID: "classic-16-bit-v1"
        ))
        let materialJSON = String(decoding: materialData, as: UTF8.self)
        XCTAssertFalse(materialJSON.contains("stylesheets"))
    }

    func testScaffolderWritesCSSStarterWorkspaceThatCompilesStrictly() throws {
        let destination = temporaryDirectory.appendingPathComponent("Scaffolded", isDirectory: true)
        var workspace = try ThumbleSkinScaffolder.write(
            name: "CSS Scaffold",
            identifier: "com.example.css-scaffold",
            artboardID: "showcase-controller-v1",
            to: destination,
            css: true
        )
        workspace.author = ThumbleSkinAuthor(name: "Scaffold Author")
        workspace.summary = "A scaffolded CSS skin that compiles cleanly under strict mode."
        try write(workspace, css: try String(contentsOf: destination.appendingPathComponent("styles/controller.css"), encoding: .utf8), to: destination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("styles/controller.css").path))
        XCTAssertTrue(workspace.usesCSSAuthoring)
        let result = try ThumbleSkinCompiler.compile(source: destination, strict: true)
        XCTAssertTrue(ThumbleSkinPackageValidator.validate(result.package).isValid)
    }

    // MARK: - Legacy parity

    func testMaterialWorkspacesStillCompileIdentically() throws {
        // Schema-1 material workspaces must remain byte-stable; the CSS path must not leak in.
        let material = temporaryDirectory.appendingPathComponent("MaterialSkin", isDirectory: true)
        var workspace = try ThumbleSkinScaffolder.write(
            name: "Material Skin",
            identifier: "com.example.material-skin",
            artboardID: "classic-16-bit-v1",
            to: material
        )
        workspace.author = ThumbleSkinAuthor(name: "Material Author")
        workspace.summary = "A material workspace proving the legacy compiler path is unchanged."
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(workspace).write(
            to: material.appendingPathComponent(ThumbleSkinScaffolder.sourceFileName),
            options: .atomic
        )
        let first = try ThumbleSkinCompiler.compile(source: material, strict: true)
        let second = try ThumbleSkinCompiler.compile(source: material, strict: true)
        XCTAssertEqual(first.packageData, second.packageData)
        XCTAssertTrue(first.package.manifest.assets.count > 0)
        XCTAssertTrue(first.package.manifest.tags.contains("agent-source"))
        XCTAssertFalse(first.package.manifest.tags.contains("css"))
    }

    // MARK: - Image fills, resolver application, and multi-stylesheet order

    func testImageFillViaURLEmbedsRasterizedAssetAndValidates() throws {
        let source = try makeCSSWorkspace(css: """
            control { background: url(#face-texture); border: 1px solid #333333; }
            """)
        var workspace = try loadWorkspace(source)
        workspace.sourceAssets = [
            ThumbleSkinSourceAsset(
                id: "face-texture",
                path: "sources/artwork/face.svg",
                purpose: .controlFace,
                outputWidth: 128,
                outputHeight: 128
            )
        ]
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("sources/artwork"),
            withIntermediateDirectories: true
        )
        try """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128">
          <rect width="128" height="128" fill="#8A6FD0"/>
          <circle cx="64" cy="64" r="24" fill="#5B4497"/>
        </svg>
        """.write(to: source.appendingPathComponent("sources/artwork/face.svg"), atomically: true, encoding: .utf8)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(workspace).write(
            to: source.appendingPathComponent(ThumbleSkinScaffolder.sourceFileName),
            options: .atomic
        )

        let result = try ThumbleSkinCompiler.compile(source: source, strict: true)
        let validation = ThumbleSkinPackageValidator.validate(result.package)
        XCTAssertTrue(validation.isValid, "\(validation.issues)")
        let descriptor = try XCTUnwrap(result.package.manifest.assets.first { $0.id == "face-texture" })
        XCTAssertEqual(descriptor.contentType, "image/png")
        XCTAssertNotNil(result.package.assets["face-texture"])

        let skin = try XCTUnwrap(result.package.skin)
        let appearance = skin.appearance(orientation: .landscape, colorScheme: .light)
        let styleID = try XCTUnwrap(appearance.defaultControl?.styleID)
        let style = try XCTUnwrap(appearance.styleLibrary.style(id: styleID)?.visualStyle)
        guard case .image(let image)? = style.normal.fillStyle else {
            return XCTFail("Expected an image fill")
        }
        XCTAssertEqual(image.assetID, "face-texture")

        // Unknown asset references are strict compile errors.
        workspace.sourceAssets = []
        try encoder.encode(workspace).write(
            to: source.appendingPathComponent(ThumbleSkinScaffolder.sourceFileName),
            options: .atomic
        )
        XCTAssertThrowsError(try ThumbleSkinCompiler.compile(source: source, strict: false)) { error in
            guard case ThumbleSkinCompilerError.invalidSource(let report) = error else {
                return XCTFail("Unexpected error \(error)")
            }
            XCTAssertTrue(report.errors.contains { $0.code == "css-unknown-asset-reference" }, "\(report.issues)")
        }
    }

    func testCompiledCSSPackageAppliesToProfileThroughResolver() throws {
        let source = try makeCSSWorkspace(css: """
            control { background: #F2EEF5; color: #6E4F9E; border: 1px solid #FFFFFF; }
            control[role="primary_action"] { background: #702653; }
            control:pressed { transform: scale(0.9); }
            """)
        let result = try ThumbleSkinCompiler.compile(source: source, strict: true)
        let package = result.package

        let customization = GamepadCustomization.defaultValue
        let applied = ThumbleSkinResolver.applying(
            package: package,
            to: customization,
            orientation: .landscape,
            colorScheme: .light,
            options: .replacingAppearance
        )
        let jump = applied.buttonCustomization(for: .jump)
        XCTAssertEqual(jump.styleID, "css-button-jump")
        let size = customization.deviceCanvas.editorDeviceFrame.screenRect.size
        let controls = applied.resolvedControls(in: size)
        let jumpControl = try XCTUnwrap(controls.first(where: { $0.mappedButton == GameButton.jump && $0.controlKind == .button }))
        let presentation = applied.resolvedPresentation(for: jumpControl, state: .normal, scheme: .light)
        XCTAssertEqual(presentation.fillStyle.representativeColor.hexString, "#702653")
        let pressed = applied.resolvedPresentation(for: jumpControl, state: .pressed, scheme: .light)
        XCTAssertEqual(pressed.scale, 0.9, accuracy: 0.001)
    }

    func testMultipleStylesheetsCascadeInDeclaredOrder() throws {
        let source = try makeCSSWorkspace(css: "control { background: #FF0000; }")
        var workspace = try loadWorkspace(source)
        workspace.stylesheets = ["styles/controller.css", "styles/override.css"]
        try """
        control { background: #00FF00; }
        """.write(to: source.appendingPathComponent("styles/override.css"), atomically: true, encoding: .utf8)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(workspace).write(
            to: source.appendingPathComponent(ThumbleSkinScaffolder.sourceFileName),
            options: .atomic
        )
        let documents = try ThumbleCSSCompiler.computed(workspace: workspace, sourceRoot: source)
        let light = try XCTUnwrap(documents.first { $0.orientation == "landscape" && $0.colorScheme == "light" })
        let jump = try XCTUnwrap(light.elements.first { $0.id == "builtin-jump" })
        let normal = try XCTUnwrap(jump.states.first { $0.state == "normal" }?.declarations)
        // Later stylesheets override earlier ones at equal specificity.
        XCTAssertEqual(normal["background"], "#00FF00")
    }

    func testCommittedExampleCompilesToGoldenPackage() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = repository.appendingPathComponent("docs/skins/examples/css-first-light", isDirectory: true)
        let golden = source.appendingPathComponent("dist/css-first-light-1.0.0.pocketpad")
        let result = try ThumbleSkinCompiler.compile(
            source: source,
            buildDirectory: temporaryDirectory.appendingPathComponent("golden-build", isDirectory: true),
            packageOutputURL: temporaryDirectory.appendingPathComponent("css-first-light.pocketpad"),
            clean: true,
            strict: true
        )

        XCTAssertEqual(result.packageData, try Data(contentsOf: golden))
        XCTAssertEqual(result.packageData.thumbleSHA256, "9900347f3a02fef762e83beacd0021ba82a95f7c3edf6a4be51e357cc2aa7a0c")

        let quality = ThumbleSkinQualityEvaluator.evaluate(
            package: result.package,
            workspace: result.workspace,
            artboardID: "showcase-controller-v1"
        )
        XCTAssertTrue(quality.isStrictlyPassing, "\(quality.issues)")
    }

    func testComputedStyleInspectionIsDeterministicAcrossRuns() throws {
        let css = """
            :root { --a: #123456; }
            control { color: var(--a); border-radius: 8px 4px 2px 1px; }
            control:active { opacity: 0.8; }
            """
        let source = try makeCSSWorkspace(css: css)
        let first = try ThumbleCSSCompiler.computed(workspace: try loadWorkspace(source), sourceRoot: source)
        let second = try ThumbleCSSCompiler.computed(workspace: try loadWorkspace(source), sourceRoot: source)
        let encoder = { () -> JSONEncoder in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return encoder
        }()
        let firstData = try encoder.encode(first)
        let secondData = try encoder.encode(second)
        XCTAssertEqual(firstData, secondData)

        // Per-corner border radius lowers to GamepadCornerRadii.
        let result = try ThumbleSkinCompiler.compile(source: source, strict: true)
        let skin = try XCTUnwrap(result.package.skin)
        let appearance = skin.appearance(orientation: .landscape, colorScheme: .light)
        let radii = try XCTUnwrap(appearance.defaultControl?.cornerRadii)
        XCTAssertEqual(radii.topLeading, 8)
        XCTAssertEqual(radii.topTrailing, 4)
        XCTAssertEqual(radii.bottomTrailing, 2)
        XCTAssertEqual(radii.bottomLeading, 1)
    }
}
