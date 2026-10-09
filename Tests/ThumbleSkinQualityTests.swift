import XCTest

@MainActor
final class ThumbleSkinQualityTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThumbleSkinQualityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
    }

    func testCompiledHandcraftedWorkspacePassesRequiredQualityGates() throws {
        let (workspace, package) = try makeWorkspaceAndPackage()
        let report = ThumbleSkinQualityEvaluator.evaluate(package: package, workspace: workspace)

        XCTAssertTrue(report.isPassing, "\(report.errors)")
        XCTAssertEqual(report.checkedArtboardID, "classic-16-bit-v1")
        XCTAssertFalse(report.issues.contains { $0.code == "missing-artwork-variant" })
        XCTAssertFalse(report.issues.contains { $0.code == "missing-preview-variant" })
        XCTAssertFalse(report.issues.contains { $0.code == "missing-pressed-state" })
        XCTAssertFalse(report.issues.contains { $0.code == "canonical-template-incompatible" })
        XCTAssertGreaterThan(report.score, 50)
    }

    func testQualityGateFindsContrastStateAndVariantRegressions() throws {
        var (workspace, package) = try makeWorkspaceAndPackage()
        workspace.materials[0].foregroundColor = workspace.materials[0].baseColor
        workspace.materials[0].darkForegroundColor = workspace.materials[0].darkBaseColor ?? workspace.materials[0].baseColor

        package.manifest.previews.removeAll { $0.orientation == .portrait && $0.colorScheme == .dark }
        var skin = try XCTUnwrap(package.skin)
        XCTAssertFalse(skin.base.styleLibrary.styles.isEmpty)
        skin.base.styleLibrary.styles[0].visualStyle.pressed = nil
        package.skin = skin

        let report = ThumbleSkinQualityEvaluator.evaluate(package: package, workspace: workspace)
        let codes = Set(report.issues.map(\.code))
        XCTAssertFalse(report.isPassing)
        XCTAssertTrue(codes.contains("low-material-contrast"))
        XCTAssertTrue(codes.contains("missing-pressed-state"))
        XCTAssertTrue(codes.contains("missing-preview-variant"))
    }

    func testQualityReportScoreAndStrictStatusAreDeterministic() {
        let issues = [
            ThumbleSkinQualityIssue(severity: .warning, code: "warning", message: "Review"),
            ThumbleSkinQualityIssue(severity: .error, code: "error", message: "Fix")
        ]
        let report = ThumbleSkinQualityReport(issues: issues, checkedArtboardID: "showcase-controller-v1")
        XCTAssertEqual(report.score, 78)
        XCTAssertFalse(report.isPassing)
        XCTAssertFalse(report.isStrictlyPassing)
        XCTAssertEqual(report.errors.count, 1)
        XCTAssertEqual(report.warnings.count, 1)
    }

    private func makeWorkspaceAndPackage() throws -> (ThumbleSkinWorkspace, ThumbleSkinPackage) {
        let source = temporaryDirectory.appendingPathComponent("QualitySkin", isDirectory: true)
        var workspace = try ThumbleSkinScaffolder.write(
            name: "Quality Skin",
            identifier: "com.example.quality-skin",
            artboardID: "classic-16-bit-v1",
            to: source
        )
        workspace.author = ThumbleSkinAuthor(name: "Test Designer", url: URL(string: "https://example.com/designer"))
        workspace.summary = "A deliberate indigo hardware study with a layered shell, inset wells, and legible controls."
        workspace.license = "MIT"
        for index in workspace.materials.indices {
            workspace.materials[index].baseColor = "#11131A"
            workspace.materials[index].darkBaseColor = "#080A10"
            workspace.materials[index].foregroundColor = "#FFFFFF"
            workspace.materials[index].darkForegroundColor = "#FFFFFF"
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(workspace).write(
            to: source.appendingPathComponent(ThumbleSkinScaffolder.sourceFileName),
            options: .atomic
        )
        let compiled = try ThumbleSkinCompiler.compile(
            source: source,
            buildDirectory: source.appendingPathComponent("build", isDirectory: true),
            clean: true
        )
        return (workspace, compiled.package)
    }
}


extension ThumbleSkinQualityTests {
    func testRasterFaceEstimateUsesOpaqueArtworkAndIgnoresTransparentCorners() throws {
        let svg = Data("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 128 128\"><circle cx=\"64\" cy=\"64\" r=\"60\" fill=\"#D5DED9\"/></svg>".utf8)
        let png = try ThumbleSVGRasterizer.rasterize(svg, width: 128, height: 128)
        let sampled = try XCTUnwrap(ThumbleSkinQualityEvaluator.rasterFillRepresentativeColor(png))
        XCTAssertEqual(sampled.red, CGFloat(213) / 255, accuracy: 0.02)
        XCTAssertEqual(sampled.green, CGFloat(222) / 255, accuracy: 0.02)
        XCTAssertEqual(sampled.blue, CGFloat(217) / 255, accuracy: 0.02)
        XCTAssertNil(ThumbleSkinQualityEvaluator.rasterFillRepresentativeColor(Data("invalid".utf8)))
    }
}

extension ThumbleSkinQualityTests {
    func testCSSJoystickLegendContrastUsesAuthoredPuckInsteadOfWell() throws {
        let (workspace, package) = try makePuckContrastWorkspace(legend: "#182735")
        let report = ThumbleSkinQualityEvaluator.evaluate(package: package, workspace: workspace)
        XCTAssertFalse(report.issues.contains {
            $0.target?.styleID == "css-role-joystick" && $0.code.contains("style-contrast")
        }, "Readable dark legend on cream puck must not be compared to its dark well: \(report.issues)")
    }

    func testCSSJoystickLegendContrastRejectsUnreadablePuckAndInheritedStates() throws {
        let (workspace, package) = try makePuckContrastWorkspace(legend: "#FFF8E8")
        let report = ThumbleSkinQualityEvaluator.evaluate(package: package, workspace: workspace)
        let issues = report.issues.filter { $0.target?.styleID == "css-role-joystick" && $0.code == "low-style-contrast" }
        for state in GamepadControlPresentationState.allCases {
            XCTAssertTrue(issues.contains { $0.message.contains(", \(state.rawValue))") && $0.message.contains("joystick puck") })
        }
    }

    func testCSSJoystickContrastChecksStateOverrideAndSharedButtonFace() throws {
        let (workspace, initial) = try makePuckContrastWorkspace(legend: "#182735", extra: """
        control[role=\"joystick\"]:pressed { -thumble-joystick-knob-fill: #182735; }
        control[role=\"joystick\"]:active { -thumble-joystick-knob-fill: #182735; }
        """)
        let stateReport = ThumbleSkinQualityEvaluator.evaluate(package: initial, workspace: workspace)
        let stateIssues = stateReport.issues.filter { $0.target?.styleID == "css-role-joystick" && $0.code == "low-style-contrast" }
        XCTAssertTrue(stateIssues.contains { $0.message.contains(", pressed)") })
        XCTAssertTrue(stateIssues.contains { $0.message.contains(", active)") })
        XCTAssertFalse(stateIssues.contains { $0.message.contains(", normal)") || $0.message.contains(", disabled)") })

        var package = initial
        var skin = try XCTUnwrap(package.skin)
        func shareWithButtons(_ appearance: inout ThumbleSkinAppearance) {
            appearance.roleRules.removeAll { $0.role == .utility }
            appearance.roleRules.append(.init(role: .utility, appearance: .init(styleID: "css-role-joystick")))
        }
        shareWithButtons(&skin.base)
        for index in skin.variants.indices { shareWithButtons(&skin.variants[index].appearance) }
        package.skin = skin
        let shared = ThumbleSkinQualityEvaluator.evaluate(package: package, workspace: workspace)
        XCTAssertTrue(shared.issues.contains {
            $0.target?.styleID == "css-role-joystick" && $0.code == "low-style-contrast"
                && $0.message.contains(", normal)") && $0.message.contains("against its face")
        }, "A token shared with buttons must still check their face, even if the joystick puck is readable.")
    }

    private func makePuckContrastWorkspace(legend: String, extra: String = "") throws -> (ThumbleSkinWorkspace, ThumbleSkinPackage) {
        let source = temporaryDirectory.appendingPathComponent("Puck-\(UUID().uuidString)", isDirectory: true)
        var workspace = try ThumbleSkinScaffolder.write(name: "Puck Contrast", identifier: "com.example.puck-contrast",
            artboardID: "xbox-v1", to: source, css: true)
        workspace.author = ThumbleSkinAuthor(name: "Contrast Fixture")
        try JSONEncoder().encode(workspace).write(to: source.appendingPathComponent(ThumbleSkinScaffolder.sourceFileName))
        let css = """
        control { background: #172A3A; color: #FFF8E8; }
        control[role="joystick"] {
            color: \(legend);
            -thumble-joystick-knob-fill: #FFF8E8;
        }
        \(extra)
        """
        try Data(css.utf8).write(to: source.appendingPathComponent("styles/controller.css"))
        let result = try ThumbleSkinCompiler.compile(source: source, strict: true)
        return (workspace, result.package)
    }
}
