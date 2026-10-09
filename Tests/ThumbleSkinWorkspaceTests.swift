import Foundation
import AppKit
import XCTest

final class ThumbleSkinWorkspaceTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThumbleSkinWorkspaceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testMinimalWorkspaceDecodesWithBackwardCompatibleDefaults() throws {
        let data = Data(#"{"identifier":"com.example.skin","name":"Example"}"#.utf8)
        let workspace = try JSONDecoder().decode(ThumbleSkinWorkspace.self, from: data)

        XCTAssertEqual(workspace.schema, ThumbleSkinWorkspaceSchema.identifier)
        XCTAssertEqual(workspace.schemaVersion, 1)
        XCTAssertEqual(workspace.version, "1.0.0")
        XCTAssertEqual(workspace.artboardID, ThumbleSkinArtboardCatalog.defaultID)
        XCTAssertEqual(workspace.orientations, [.landscape])
        XCTAssertEqual(workspace.colorSchemes, [.light, .dark])
        XCTAssertTrue(workspace.materials.isEmpty)
        XCTAssertTrue(workspace.sourceAssets.isEmpty)
    }

    func testLegacyMaterialDecodesWithNilOptionalStateControls() throws {
        let json = ##"{"id":"paper","name":"Paper","kind":"matte_rubber","baseColor":"#112233","foregroundColor":"#FFFFFF","depth":0.4,"gloss":0.1,"pressedScale":0.97}"##
        let material = try JSONDecoder().decode(ThumbleSkinMaterialSpec.self, from: Data(json.utf8))

        XCTAssertNil(material.joystickKnobColor)
        XCTAssertNil(material.darkJoystickKnobColor)
        XCTAssertNil(material.pressedFillColor)
        XCTAssertNil(material.activeFillColor)
        XCTAssertNil(material.disabledFillColor)
        XCTAssertNil(material.shadowScale)
        XCTAssertNil(material.activeStrokeWidth)
        XCTAssertNil(material.disabledOpacity)
    }

    func testOptionalMaterialStateControlsRoundTrip() throws {
        var material = ThumbleSkinMaterialSpec(
            id: "paper",
            name: "Paper",
            kind: .matteRubber,
            baseColor: "#112233",
            foregroundColor: "#FFFFFF"
        )
        material.darkStrokeColor = "#778899"
        material.joystickKnobColor = "#223344"
        material.darkJoystickKnobColor = "#334455"
        material.pressedFillColor = "#101820"
        material.darkPressedFillColor = "#080C10"
        material.activeFillColor = "#203040"
        material.darkActiveFillColor = "#304050"
        material.darkActiveColor = "#FFEEDD"
        material.activeIndexColor = "#AABBCC"
        material.darkActiveIndexColor = "#CCDDEE"
        material.activeIndexWidth = 2
        material.disabledFillColor = "#555555"
        material.darkDisabledFillColor = "#333333"
        material.disabledForegroundColor = "#F0F0F0"
        material.darkDisabledForegroundColor = "#E0E0E0"
        material.disabledStrokeColor = "#999999"
        material.darkDisabledStrokeColor = "#BBBBBB"
        material.shadowScale = 0.25
        material.pressedShadowScale = 0.2
        material.pressedInnerShadowScale = 0.1
        material.activeStrokeWidth = 3
        material.portraitActiveStrokeWidth = 4
        material.landscapeActiveStrokeWidth = 2
        material.disabledStrokeWidth = 2
        material.disabledOpacity = 0.92

        let data = try JSONEncoder().encode(material)
        let decoded = try JSONDecoder().decode(ThumbleSkinMaterialSpec.self, from: data)
        XCTAssertEqual(decoded, material)
    }

    func testSourceSchemaDeclaresStateControlsAsOptionalMaterialProperties() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let schemaURL = repository.appendingPathComponent("docs/skins/pocketpad-skin-source.schema.json")
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: schemaURL)) as? [String: Any]
        )
        let definitions = try XCTUnwrap(root["$defs"] as? [String: Any])
        let material = try XCTUnwrap(definitions["material"] as? [String: Any])
        let properties = try XCTUnwrap(material["properties"] as? [String: Any])
        let required = Set((material["required"] as? [String]) ?? [])

        for key in [
            "joystickKnobColor", "darkJoystickKnobColor", "pressedFillColor",
            "activeFillColor", "activeStrokeWidth", "portraitActiveStrokeWidth",
            "landscapeActiveStrokeWidth", "activeIndexColor", "activeIndexWidth", "disabledFillColor",
            "disabledStrokeColor", "disabledStrokeWidth", "disabledOpacity", "shadowScale"
        ] {
            XCTAssertNotNil(properties[key], key)
            XCTAssertFalse(required.contains(key), key)
        }
    }

    func testSystemControlsNeverExposeAStarterInputIdentity() throws {
        var customization = GamepadCustomization.blankCanvas
        customization.topBarActivationRegion.isHidden = false
        let systemID = GamepadControlIdentity.system(.topBarActivation)
        let control = try XCTUnwrap(customization.resolvedControls(in: CGSize(width: 874, height: 402)).first { $0.id == systemID })
        XCTAssertNil(control.elementID)
        XCTAssertNil(control.inputID)
        let cache = GamepadResolvedControlsLayoutCacheKey(customization: customization)
        XCTAssertNil(try XCTUnwrap(cache.controls.first { $0.id == systemID }).inputID)
        let resolver = GamepadResolvedControlsCache()
        for _ in 0..<2 {
            let cached = resolver.controls(for: customization, in: CGSize(width: 874, height: 402), defaultLabelProvider: nil)
            XCTAssertNil(try XCTUnwrap(cached.first { $0.id == systemID }).inputID)
        }
        XCTAssertEqual(resolver.resolutionCount, 1, "The second check must exercise the warm-cache presentation path")
        let report = customization.layoutQualityReport(canvasSize: CGSize(width: 874, height: 402))
        XCTAssertNil(try XCTUnwrap(report.controls.first { $0.id == systemID.id }).inputID)
        for artboard in ThumbleSkinArtboardCatalog.all {
            for variant in artboard.variants {
                for system in variant.controls where system.id.hasPrefix("system.") {
                    XCTAssertNil(system.inputID, "\(artboard.id)/\(variant.id)")
                    let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(system)) as? [String: Any])
                    XCTAssertNil(raw["inputID"])
                }
                for element in variant.controls where !element.id.hasPrefix("system.") {
                    XCTAssertNotNil(element.inputID, "Declared controls must keep their own UUIDs")
                }
            }
        }
    }

    func testCanonicalArtboardsHaveStableFramesRolesAndProfiles() throws {
        let artboards = ThumbleSkinArtboardCatalog.all
        XCTAssertGreaterThan(artboards.count, 10)
        let showcase = try XCTUnwrap(ThumbleSkinArtboardCatalog.resolve("showcase-controller-v1"))
        XCTAssertEqual(showcase.templateID, GamepadControllerTemplate.snes.rawValue)
        XCTAssertFalse(showcase.variants.isEmpty)
        XCTAssertTrue(showcase.expectedRoles.contains(.movement))
        XCTAssertTrue(showcase.expectedRoles.contains(.primaryAction))

        for artboard in artboards {
            XCTAssertFalse(artboard.variants.isEmpty, artboard.id)
            for variant in artboard.variants {
                XCTAssertGreaterThan(variant.canvasWidth, 100)
                XCTAssertGreaterThan(variant.canvasHeight, 100)
                for control in variant.controls {
                    XCTAssertGreaterThan(control.frame.width, 0)
                    XCTAssertGreaterThan(control.frame.height, 0)
                    XCTAssertGreaterThanOrEqual(control.frame.x, 0)
                    XCTAssertGreaterThanOrEqual(control.frame.y, 0)
                    XCTAssertLessThanOrEqual(control.frame.x + control.frame.width, 1.0001)
                    XCTAssertLessThanOrEqual(control.frame.y + control.frame.height, 1.0001)
                }
            }
        }

        let first = try XCTUnwrap(ThumbleSkinArtboardCatalog.profile(for: showcase.id))
        let second = try XCTUnwrap(ThumbleSkinArtboardCatalog.profile(for: showcase.id))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(first), try encoder.encode(second))
        XCTAssertEqual(first.updatedAt, 0)
        XCTAssertEqual(first.customization.designMetadata?.sourceTemplateID, GamepadControllerTemplate.snes.rawValue.lowercased())
        XCTAssertEqual(first.customization.designMetadata?.sourceTemplateRevision, 2)
    }

    func testCommittedCanonicalArtboardsMatchCompiledCatalog() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for id in ["showcase-controller-v1", "classic-16-bit-v1"] {
            let url = repository.appendingPathComponent("docs/skins/artboards/\(id).json")
            let committed = try JSONDecoder().decode(ThumbleSkinArtboard.self, from: Data(contentsOf: url))
            XCTAssertEqual(committed, ThumbleSkinArtboardCatalog.resolve(id), id)
        }
    }

    func testScaffolderWritesEditableSourcesAndProtectsExistingWork() throws {
        let destination = temporaryDirectory.appendingPathComponent("IndigoPocket", isDirectory: true)
        let workspace = try ThumbleSkinScaffolder.write(
            name: "Indigo Pocket",
            identifier: "com.example.pocketpad.skin.indigo-pocket",
            artboardID: "classic-16-bit-v1",
            to: destination
        )

        XCTAssertEqual(workspace.name, "Indigo Pocket")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("skin-source.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("sources/artwork/accent-lines.svg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("README.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("reviews/README.md").path))
        let approval = try String(contentsOf: destination.appendingPathComponent("reviews/human-approval.json"), encoding: .utf8)
        XCTAssertTrue(approval.contains("\"status\": \"pending\""))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("build").path))

        let decoded = try JSONDecoder().decode(
            ThumbleSkinWorkspace.self,
            from: Data(contentsOf: destination.appendingPathComponent("skin-source.json"))
        )
        XCTAssertEqual(decoded.artboardID, "classic-16-bit-v1")
        XCTAssertEqual(decoded.materials.count, 4)
        XCTAssertTrue(decoded.assignments.contains { $0.role == .movement && $0.materialID == "rubber" })

        XCTAssertThrowsError(
            try ThumbleSkinScaffolder.write(
                name: "Replacement",
                identifier: "com.example.replacement",
                to: destination
            )
        ) { error in
            guard case ThumbleSkinScaffoldError.destinationNotEmpty = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testScaffolderRejectsUnknownArtboardsAndUnsafeIdentity() {
        XCTAssertThrowsError(
            try ThumbleSkinScaffolder.write(
                name: "Bad",
                identifier: "not-an-id",
                to: temporaryDirectory.appendingPathComponent("bad")
            )
        ) { error in
            XCTAssertEqual(error as? ThumbleSkinScaffoldError, .invalidIdentity)
        }
        XCTAssertThrowsError(
            try ThumbleSkinScaffolder.write(
                name: "Bad",
                identifier: "com.example.bad",
                artboardID: "missing-artboard",
                to: temporaryDirectory.appendingPathComponent("missing")
            )
        ) { error in
            XCTAssertEqual(error as? ThumbleSkinScaffoldError, .unknownArtboard("missing-artboard"))
        }
    }
}

extension ThumbleSkinWorkspaceTests {
    func testCapturedArtboardPreservesExactIDsAndDoesNotInventPortrait() throws {
        var profile = GamepadControllerTemplate.xbox.makeProfile()
        profile.landscapeCustomization = nil
        profile.portraitCustomization = nil
        let artboard = try ThumbleSkinArtboard.capture(profile: profile, identifier: "captured-lux",
            safeAreas: [.landscape: ThumbleNormalizedInsets()])
        XCTAssertEqual(artboard.variants.map(\.orientation), [.landscape])
        let chrome = try XCTUnwrap(artboard.variants[0].nativeChrome)
        XCTAssertEqual(chrome.schemaVersion, 1)
        XCTAssertEqual(Set(chrome.canvasFills.keys), ["light", "dark"])
        XCTAssertEqual(chrome.containerPresentation?["light"]?.fillColor, GamepadRGBAColor(red: 1, green: 1, blue: 1))
        XCTAssertEqual(chrome.containerPresentation?["dark"]?.strokeColor.alpha ?? 0, 36.0 / 255, accuracy: 0.000001)
        var legacyChrome = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(chrome)) as? [String: Any])
        legacyChrome.removeValue(forKey: "containerPresentation")
        let decodedLegacy = try JSONDecoder().decode(ThumbleSkinArtboardNativeChrome.self,
            from: JSONSerialization.data(withJSONObject: legacyChrome))
        XCTAssertNil(decodedLegacy.containerPresentation)
        XCTAssertEqual(decodedLegacy.surfaceIDs, chrome.surfaceIDs)
        XCTAssertEqual(chrome.canvasFrame.origin, .zero)
        XCTAssertEqual(Set(chrome.supportedProperties.keys), Set(chrome.potentialSurfaceIDs))
        XCTAssertFalse(chrome.surfaceIDs.contains("native-control-bar/spacer"))
        XCTAssertFalse(chrome.visibleBarItems.contains(.launchTarget))
        XCTAssertEqual(chrome.revealSurfaces?.samples.count, 8)
        XCTAssertTrue(chrome.surfaceIDs.contains("native-drawer/reveal"))
        for item in chrome.visibleBarItems where item != .spacer {
            let properties = try XCTUnwrap(chrome.supportedProperties["native-control-bar/" + item.rawValue])
            XCTAssertTrue(properties.contains("appearance.icon.source"))
            XCTAssertTrue(properties.contains("appearance.icon.scale"))
            XCTAssertTrue(properties.contains("appearance.icon.tintColor"))
            XCTAssertTrue(properties.contains("appearance.icon.renderingMode"))
            XCTAssertFalse(properties.contains("appearance.icon.placement"))
        }
        for context in chrome.drawerVisibility {
            XCTAssertTrue(context.requestedOpenResolvesOpen)
            XCTAssertEqual(context.requestedClosedResolvesOpen, !context.isConnected || context.isEditing)
        }

        let customization = profile.customization
        let size = customization.deviceCanvas.editorDeviceFrame.screenRect.size
        let resolved = customization.resolvedControls(in: size).filter { !$0.layoutCustomization.isHidden }
        XCTAssertEqual(artboard.variants[0].controls.map(\.id), resolved.map { $0.id.id })
        for (captured, native) in zip(artboard.variants[0].controls, resolved) {
            XCTAssertEqual(captured.inputID, native.inputID)
            XCTAssertEqual(captured.frame.x * size.width, native.frame.minX, accuracy: 0.000001)
            XCTAssertEqual(captured.frame.height * size.height, native.frame.height, accuracy: 0.000001)
            let hit = try XCTUnwrap(captured.nativeGeometry?.hitFrame)
            XCTAssertEqual(hit.x * size.width, native.hitFrame.minX, accuracy: 0.000001)
            XCTAssertEqual(hit.y * size.height, native.hitFrame.minY, accuracy: 0.000001)
            XCTAssertEqual(hit.width * size.width, native.hitFrame.width, accuracy: 0.000001)
            XCTAssertEqual(hit.height * size.height, native.hitFrame.height, accuracy: 0.000001)
            let inventory = try XCTUnwrap(captured.nativeSurfaces)
            XCTAssertEqual(inventory.schemaVersion, 1)
            XCTAssertEqual(inventory.samples.count, 8)
            XCTAssertEqual(Set(inventory.samples.map(\.colorScheme)), [.light, .dark])
            XCTAssertEqual(Set(inventory.samples.map(\.state)), Set(GamepadControlPresentationState.allCases))
            XCTAssertEqual(Set(inventory.supportedProperties.keys), Set(inventory.potentialSurfaceIDs))
            for sample in inventory.samples {
                XCTAssertTrue(Set(sample.surfaceIDs).isSubset(of: Set(inventory.potentialSurfaceIDs)))
                XCTAssertTrue(Set(sample.localFrames.keys).isSubset(of: Set(sample.surfaceIDs)))
                if native.isJoystick { XCTAssertNotNil(sample.localFrames["joystick-puck"]) }
                if !native.isText { XCTAssertEqual(sample.localFrames["face"]?.size, native.size) }
                let expected = native.controlKind == .button && sample.state == .pressed && native.inputID != nil ? 0.94 : native.controlKind == .trackpad && sample.state == .active ? 0.97 : 1
                XCTAssertEqual(sample.fixedProperties["nativeStateScaleMultiplier"], expected)
            }


        }
        XCTAssertThrowsError(try ThumbleSkinArtboard.capture(profile: profile, identifier: "captured-lux", safeAreas: [:]))
    }

    func testFrozenChromeExcludesHiddenBarItemsAndRecordsAbsentRevealPaint() throws {
        var profile = GamepadControllerTemplate.xbox.makeProfile()
        profile.landscapeCustomization = nil; profile.portraitCustomization = nil
        var hidden = profile.customization.controlBarItemCustomization(for: .home)
        hidden.isHidden = true
        profile.customization.setControlBarItemCustomization(hidden, for: .home)
        profile.customization.topBarActivationRegion.isHidden = true
        let artboard = try ThumbleSkinArtboard.capture(profile: profile, identifier: "hidden-chrome",
            safeAreas: [.landscape: .init()])
        let chrome = try XCTUnwrap(artboard.variants[0].nativeChrome)
        XCTAssertFalse(chrome.visibleBarItems.contains(.home))
        XCTAssertFalse(chrome.surfaceIDs.contains("native-control-bar/home"))
        XCTAssertTrue(chrome.surfaceIDs.contains("native-drawer/reveal"))
        XCTAssertNil(chrome.revealControlID)
        XCTAssertNil(chrome.revealArtboardFrame)
        XCTAssertNil(chrome.revealSurfaces)
    }

    func testFrozenTextSurfaceInventoryReportsIgnoredIcons() throws {
        var customization = GamepadCustomization.blankCanvas
        let id = UUID()
        customization.elements = [KeypadElement(id: id, label: "Title", kind: .text,
            layout: GamepadButtonCustomization(icon: .sfSymbol("sun.max.fill")))]
        var profile = GamepadControllerTemplate.xbox.makeProfile()
        profile.customization = customization
        profile.landscapeCustomization = nil; profile.portraitCustomization = nil
        let artboard = try ThumbleSkinArtboard.capture(profile: profile, identifier: "text-surfaces",
            safeAreas: [.landscape: .init()])
        let native = try XCTUnwrap(customization.resolvedControls(in: customization.deviceCanvas.editorDeviceFrame.screenRect.size).first { $0.elementID == id })
        let captured = try XCTUnwrap(artboard.variants[0].controls.first { $0.id == native.id.id })
        let inventory = try XCTUnwrap(captured.nativeSurfaces)
        XCTAssertFalse(inventory.potentialSurfaceIDs.contains("icon"))
        XCTAssertTrue(inventory.samples.allSatisfy { !$0.surfaceIDs.contains("icon") && !$0.surfaceIDs.contains("face") })
        let content = GamepadNativeContentPresentation(control: native, showsButtonLabels: true,
            content: nil, icon: .sfSymbol("sun.max.fill"))
        XCTAssertTrue(content.fallbacks.contains("native-text-icon-not-rendered"))
    }

    func testCSSCompilesAgainstCapturedArtboardAndRejectsAmbiguousContracts() throws {
        var artboard = try XCTUnwrap(ThumbleSkinArtboardCatalog.resolve("xbox-v1"))
        artboard.id = "captured-controller"
        artboard.variants = Array(artboard.variants.prefix(1))
        var workspace = ThumbleSkinWorkspace.starterCSS(name: "Captured", identifier: "com.example.captured", artboardID: artboard.id)
        workspace.schemaVersion = 3
        workspace.capturedArtboards = [artboard]
        workspace.orientations = artboard.variants.map(\.orientation)
        let styles = temporaryDirectory.appendingPathComponent("styles", isDirectory: true)
        try FileManager.default.createDirectory(at: styles, withIntermediateDirectories: true)
        try "control { background: #112233; color: #FFFFFF; }".write(to: styles.appendingPathComponent("controller.css"), atomically: true, encoding: .utf8)
        let decoded = try JSONDecoder().decode(ThumbleSkinWorkspace.self, from: JSONEncoder().encode(workspace))
        XCTAssertEqual(decoded.resolvedArtboard, artboard)
        XCTAssertTrue(ThumbleSkinSourceValidator.validate(decoded).isValid)
        let compiled = try ThumbleCSSCompiler.compile(workspace: decoded, sourceRoot: temporaryDirectory)
        XCTAssertTrue(compiled.report.isValid)
        XCTAssertEqual(Set(compiled.variants.compactMap(\.orientation)), Set(workspace.orientations))
        workspace.capturedArtboards.append(artboard)
        XCTAssertNil(workspace.resolvedArtboard)
        XCTAssertFalse(ThumbleSkinSourceValidator.validate(workspace).isValid)
        workspace.capturedArtboards = [artboard]
        workspace.schemaVersion = 2
        XCTAssertFalse(ThumbleSkinSourceValidator.validate(workspace).isValid)
    }
}

extension ThumbleSkinWorkspaceTests {
    private func beginDesign(_ path: URL) throws -> ControllerDesignSession {
        var profile = GamepadControllerTemplate.xbox.makeProfile()
        profile.landscapeCustomization = nil
        profile.portraitCustomization = nil
        return try ControllerDesignWorkspace.begin(profile: profile, bindings: Data("{\"mapping\":[]}".utf8),
            targetRevision: 17, safeAreas: [.landscape: .init()], name: "Design Lab",
            identifier: "com.example.design-lab", at: path)
    }

    func testWorkspaceJSONBudgetRejectsOversizedWriteWithoutReplacingFile() throws {
        let file = temporaryDirectory.appendingPathComponent("bounded.json")
        let budget = ControllerDesignWorkspace.maximumFileBytes
        // A JSON string adds two quote bytes, so this reaches the exact limit.
        try ControllerDesignWorkspace.write(String(repeating: "x", count: budget - 2), to: file)
        let original = try Data(contentsOf: file)
        XCTAssertEqual(original.count, budget)
        XCTAssertThrowsError(try ControllerDesignWorkspace.write(String(repeating: "x", count: budget - 1), to: file))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testDesignSessionFreezesContractAndBoundsTransactionalSourceUpdates() throws {
        let root = temporaryDirectory.appendingPathComponent("design")
        let initial = try beginDesign(root)
        XCTAssertEqual(try ControllerDesignWorkspace.load(at: root), initial)
        XCTAssertEqual(initial.targetRevision, 17)
        let css = Data("control { background: #334455; color: #FFFFFF; }".utf8)
        let update = try ControllerDesignWorkspace.update(at: root, expectedRevision: 1,
            edits: [.init(path: "styles/controller.css", data: css)])
        XCTAssertEqual(update.session.revision, 2)
        XCTAssertEqual(update.changedFiles, ["styles/controller.css"])
        XCTAssertEqual(update.session.artboardSHA256, initial.artboardSHA256)
        XCTAssertEqual(update.session.bindingSHA256, initial.bindingSHA256)
        XCTAssertNotEqual(update.session.sourceSHA256, initial.sourceSHA256)
        XCTAssertThrowsError(try ControllerDesignWorkspace.update(at: root, expectedRevision: 1, edits: []))
        for path in ["../escape.css", "contract/profile.json", "reviews/human-approval.json", "sources/script.js"] {
            XCTAssertThrowsError(try ControllerDesignWorkspace.update(at: root, expectedRevision: 2,
                edits: [.init(path: path, data: css)]))
        }
        XCTAssertThrowsError(try ControllerDesignWorkspace.update(at: root, expectedRevision: 2,
            edits: [.init(path: "styles/controller.css", data: Data("control { unsupported: yes; }".utf8))]))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("styles/controller.css")), css)
        XCTAssertEqual(try ControllerDesignWorkspace.load(at: root).revision, 2)
        try Data("{}".utf8).write(to: root.appendingPathComponent("contract/profile.json"))
        XCTAssertThrowsError(try ControllerDesignWorkspace.load(at: root))
    }

    @MainActor
    func testNativeBeginFreezesFlowAndChromeAndRecapturesTypedLayout() throws {
        let root = temporaryDirectory.appendingPathComponent("native-baseline")
        var profile = GamepadControllerTemplate.xbox.makeProfile()
        profile.landscapeCustomization = nil; profile.portraitCustomization = nil
        profile.customization.elements[0].presentation = .init(actionID: "ability.q", legend: "Q", caption: "Light Binding")
        let renderer = String(repeating: "a", count: 64)
        let initial = try ControllerDesignWorkspace.beginNative(profile: profile, bindings: Data("{}".utf8), targetRevision: 17,
            safeAreas: [.landscape: .init(top: 0.03)], name: "Native baseline", identifier: "com.example.native-baseline",
            at: root, rendererSHA256: renderer)
        let board = try ControllerDesignWorkspace.inspect(at: root).artboard
        let compatibility = ThumbleSkinCapturedGeometry(variants: board.variants)
        XCTAssertTrue(compatibility.isValid)
        XCTAssertTrue(compatibility.variants.allSatisfy { $0.nativeLayout == nil })
        XCTAssertEqual(compatibility.variants.map(\.controls), board.variants.map(\.controls))
        let variant = try XCTUnwrap(board.variants.first)
        let baseline = try XCTUnwrap(variant.nativeLayout)
        XCTAssertEqual(baseline.schemaVersion, 1)
        XCTAssertEqual(baseline.rendererSHA256, renderer)
        XCTAssertEqual(baseline.renderScale, 1)
        XCTAssertEqual(baseline.controlSamples.count, variant.controls.count * 8)
        XCTAssertEqual(baseline.chromeSamples.filter { $0.kind == "bar" }.count, 8)
        XCTAssertEqual(baseline.chromeSamples.filter { $0.kind == "drawer" }.count, 16)
        XCTAssertTrue(baseline.chromeSamples.allSatisfy { !$0.frames.isEmpty })
        for sample in baseline.chromeSamples {
            let paint = try XCTUnwrap(sample.paint)
            XCTAssertEqual(paint.items.isEmpty, sample.kind == "drawer" && sample.resolvedVisibility == false)
            XCTAssertTrue(paint.icons.keys.allSatisfy { sample.frames[$0] != nil })
            if sample.kind == "bar" || sample.resolvedVisibility == true {
                XCTAssertNotNil(sample.frames["native-control-bar/profile_menu/legend"])
                XCTAssertNotNil(sample.frames["native-control-bar/profile_menu/icon"])
            } else {
                XCTAssertFalse(sample.frames.keys.contains { $0.hasPrefix("native-control-bar") })
            }
        }
        XCTAssertTrue(try XCTUnwrap(variant.nativeChrome).surfaceIDs.contains("native-control-bar/profile_menu/legend"))
        let target = try XCTUnwrap(variant.controls.first { $0.presentation?.actionID == "ability.q" })
        let sample = try XCTUnwrap(baseline.controlSamples.first { $0.controlID == target.id && $0.colorScheme == .light && $0.state == .normal })
        XCTAssertNotNil(sample.flowFrames["legend"])
        XCTAssertNotNil(sample.flowFrames["caption"])
        let customization = profile.customization
        let size = customization.deviceCanvas.editorDeviceFrame.screenRect.size
        let native = try XCTUnwrap(customization.resolvedControls(in: size).first { $0.id.id == target.id })
        let measured = try XCTUnwrap(ThumbleNativeSkinPreviewRenderer.surfaceInk(control: native, customization: customization,
            state: .normal, scheme: .light, canvasSize: size, scale: 1, surfaces: ["legend", "caption"]))
        XCTAssertEqual(sample.flowFrames["legend"], measured.samples["legend"]?.nativeLayout?.canvasBounds)
        XCTAssertEqual(sample.flowFrames["caption"], measured.samples["caption"]?.nativeLayout?.canvasBounds)
        var remapped = profile
        remapped.customization.elements[0].output = .init(keyboard: .init(keyCode: 49))
        let remappedRoot = temporaryDirectory.appendingPathComponent("native-baseline-remapped")
        let remappedSession = try ControllerDesignWorkspace.beginNative(profile: remapped,
            bindings: Data("{\"keyboard\":{\"keyCode\":49}}".utf8), targetRevision: 18,
            safeAreas: [.landscape: .init(top: 0.03)], name: "Native baseline", identifier: "com.example.native-baseline",
            at: remappedRoot, rendererSHA256: renderer)
        let remappedBoard = try ControllerDesignWorkspace.inspect(at: remappedRoot).artboard
        XCTAssertNotEqual(remappedSession.id, initial.id)
        XCTAssertEqual(board.id, "captured-" + profile.id.uuidString.lowercased())
        XCTAssertEqual(remappedBoard, board)
        XCTAssertEqual(remappedSession.artboardSHA256, initial.artboardSHA256)
        XCTAssertEqual(remappedSession.sourceSHA256, initial.sourceSHA256)
        XCTAssertNotEqual(remappedSession.profileSHA256, initial.profileSHA256)
        XCTAssertNotEqual(remappedSession.bindingSHA256, initial.bindingSHA256)
        let newCenter = target.frame.x + target.frame.width / 2 + 0.01
        let patch = ControllerDesignLayoutEdit(variant: .primary, controlID: target.id, centerX: newCenter)
        XCTAssertThrowsError(try ControllerDesignWorkspace.update(at: root, expectedRevision: 1, edits: [], layoutEdits: [patch]))
        XCTAssertEqual(try ControllerDesignWorkspace.load(at: root), initial)
        let changed = try ControllerDesignWorkspace.updateNative(at: root, expectedRevision: 1, edits: [],
            layoutEdits: [patch], rendererSHA256: renderer)
        XCTAssertEqual(changed.session.revision, 2)
        XCTAssertEqual(changed.session.bindingSHA256, initial.bindingSHA256)
        XCTAssertNotEqual(changed.session.artboardSHA256, initial.artboardSHA256)
        let next = try XCTUnwrap(ControllerDesignWorkspace.inspect(at: root).artboard.variants.first?.nativeLayout)
        let moved = try XCTUnwrap(next.controlSamples.first { $0.controlID == target.id && $0.colorScheme == .light && $0.state == .normal })
        XCTAssertEqual(try XCTUnwrap(moved.flowFrames["legend"]).midX - XCTUnwrap(sample.flowFrames["legend"]).midX,
                       size.width * 0.01, accuracy: 1) // Native 1x text layout rounds to pixel boundaries.
        let archived = try JSONDecoder().decode(ThumbleSkinArtboard.self,
            from: Data(contentsOf: root.appendingPathComponent("reviews/contracts/revision-1/artboard.json")))
        XCTAssertEqual(archived, board)
        let sourceOnly = try ControllerDesignWorkspace.updateNative(at: root, expectedRevision: 2,
            edits: [.init(path: "styles/controller.css", data: Data("control { opacity: 0.8; }".utf8))], rendererSHA256: renderer)
        XCTAssertEqual(sourceOnly.session.artboardSHA256, changed.session.artboardSHA256)
        XCTAssertEqual(try ControllerDesignWorkspace.inspect(at: root).artboard.variants.first?.nativeLayout, next)
        // Additive baseline storage leaves old geometry-only contracts readable.
        XCTAssertEqual(try JSONDecoder().decode(ThumbleSkinArtboard.self, from: JSONEncoder().encode(board)), board)
    }

    @MainActor
    func testTypedDesignLayoutRevisionReplacesContractAndPreservesOldEvidence() throws {
        let root = temporaryDirectory.appendingPathComponent("layout-revision")
        let original = try beginDesign(root)
        let renderer = String(repeating: "a", count: 64)
        let review = try ControllerDesignWorkspace.review(at: root, expectedRevision: 1, rendererSHA256: renderer)
        let frozen = try JSONDecoder().decode(GamepadConfigurationProfile.self,
            from: Data(contentsOf: root.appendingPathComponent("contract/profile.json")))
        let control = try XCTUnwrap(frozen.customization.resolvedControls(in: frozen.customization.deviceCanvas.editorDeviceFrame.screenRect.size)
            .first { $0.id.id.hasPrefix("builtin.") })
        let center = control.frame.midX / frozen.customization.deviceCanvas.editorDeviceFrame.screenRect.size.width
        let movedX = center > 0.5 ? center - 0.01 : center + 0.01
        let metadata = GamepadControlPresentation(actionID: "lux.light-binding", purposeID: "ability.q",
            groupIDs: ["abilities"], legend: "Q", caption: "Light Binding", accessibilityName: "Light Binding")
        let receipt = try ControllerDesignWorkspace.update(at: root, expectedRevision: 1, edits: [],
            layoutEdits: [.init(variant: .primary, controlID: control.id.id, centerX: movedX, presentation: metadata, visualRole: .utility)])
        XCTAssertEqual(receipt.session.revision, 2)
        XCTAssertEqual(receipt.session.baseProfileSHA256, original.profileSHA256)
        XCTAssertEqual(receipt.session.bindingSHA256, original.bindingSHA256)
        XCTAssertNotEqual(receipt.session.artboardSHA256, original.artboardSHA256)
        XCTAssertNotNil(receipt.session.layoutPlanSHA256)
        XCTAssertEqual(receipt.staleReviews, [1])
        XCTAssertNil(receipt.session.latestReview)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("reviews/contracts/revision-1/profile.json").path))
        let originalPixels = try Data(contentsOf: root.appendingPathComponent(review.contactSheet.path))
        XCTAssertEqual(originalPixels.thumbleSHA256, review.contactSheet.sha256)
        XCTAssertThrowsError(try ControllerDesignWorkspace.reviewedCandidate(at: root, number: 1, expectedRevision: 2,
            rendererSHA256: renderer, evidenceSHA256: ControllerDesignWorkspace.digest(review)))
        let next = try ControllerDesignWorkspace.review(at: root, expectedRevision: 2, rendererSHA256: renderer)
        XCTAssertEqual(next.baseProfileSHA256, original.profileSHA256)
        XCTAssertEqual(next.layoutPlanSHA256, receipt.session.layoutPlanSHA256)
        let revised = try XCTUnwrap(next.frames[0].controls.first { $0.id == control.id.id })
        XCTAssertEqual(revised.presentationMetadata, metadata)
        XCTAssertEqual(revised.visualRole, .utility)
        XCTAssertEqual(revised.frame.midX / next.frames[0].viewportWidth, movedX, accuracy: 0.000001)
        let recaptured = try JSONDecoder().decode(ThumbleSkinArtboard.self,
            from: Data(contentsOf: root.appendingPathComponent("contract/artboard.json")))
        let hit = try XCTUnwrap(recaptured.variants[0].controls.first { $0.id == control.id.id }?.nativeGeometry?.hitFrame)
        XCTAssertEqual(hit.x * next.frames[0].viewportWidth, revised.hitFrame.minX, accuracy: 0.000001)
        XCTAssertEqual(hit.width * next.frames[0].viewportWidth, revised.hitFrame.width, accuracy: 0.000001)
        XCTAssertNotEqual(revised.hitFrame.minX, control.hitFrame.minX)

        let rotation = try ControllerDesignWorkspace.update(at: root, expectedRevision: 2, edits: [],
            layoutEdits: [.init(variant: .primary, controlID: control.id.id, rotationDegrees: 10)])
        XCTAssertEqual(rotation.session.revision, 3)
        let plan = try JSONDecoder().decode([ControllerDesignLayoutEdit].self,
            from: Data(contentsOf: root.appendingPathComponent("contract/layout-edits.json")))
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0].centerX, movedX)
        XCTAssertEqual(plan[0].rotationDegrees, 10)
        XCTAssertEqual(plan[0].presentation, metadata)
        XCTAssertEqual(plan[0].visualRole, .utility)
        let cleared = try ControllerDesignWorkspace.update(at: root, expectedRevision: 3, edits: [],
            layoutEdits: [.init(variant: .primary, controlID: control.id.id, clearPresentation: true, clearVisualRole: true)])
        XCTAssertEqual(cleared.session.revision, 4)
        XCTAssertEqual(cleared.session.bindingSHA256, original.bindingSHA256)
        let clearedProfile = try JSONDecoder().decode(GamepadConfigurationProfile.self,
            from: Data(contentsOf: root.appendingPathComponent("contract/profile.json")))
        let clearedControl = try XCTUnwrap(clearedProfile.customization.resolvedControls(in: clearedProfile.customization.deviceCanvas.editorDeviceFrame.screenRect.size)
            .first { $0.id == control.id })
        XCTAssertNil(clearedControl.presentationMetadata)
        XCTAssertEqual(clearedControl.visualRole, .custom)
        XCTAssertEqual(clearedControl.rotationDegrees, 10)
        XCTAssertThrowsError(try ControllerDesignLayoutEdit(variant: .primary, controlID: control.id.id,
            presentation: metadata, clearPresentation: true).validate())
        XCTAssertThrowsError(try ControllerDesignLayoutEdit(variant: .primary, controlID: "system.topBarActivation",
            presentation: metadata).validate())
        XCTAssertThrowsError(try ControllerDesignWorkspace.update(at: root, expectedRevision: 4, edits: [],
            layoutEdits: [.init(variant: .portrait, controlID: control.id.id, centerX: 0.5)]))
        XCTAssertEqual(try ControllerDesignWorkspace.load(at: root).revision, 4)
        XCTAssertThrowsError(try JSONDecoder().decodeUnique(ControllerDesignLayoutEdit.self,
            from: Data("{\"variant\":\"primary\",\"controlID\":\"x\",\"centerX\":0.5,\"output\":{}}".utf8)))
        try Data("[]".utf8).write(to: root.appendingPathComponent("contract/layout-edits.json"))
        XCTAssertThrowsError(try ControllerDesignWorkspace.load(at: root))
    }

    func testUnifiedDiagnosticsUseExactTargetsAndRetainUnresolvedPaths() throws {
        let profile = GamepadControllerTemplate.xbox.makeProfile()
        let artboard = try ThumbleSkinArtboard.capture(profile: profile, identifier: "diagnostic-fixture",
            safeAreas: [.landscape: .init(), .portrait: .init()])
        let variant = try XCTUnwrap(artboard.variants.first)
        let source = profile.customization(for: variant.orientation == .landscape ? .landscape : .portrait)
        let controls = Array(source.resolvedControls(in: CGSize(width: variant.canvasWidth, height: variant.canvasHeight))
            .filter { $0.controlKind == .button }.prefix(2))
        XCTAssertEqual(controls.count, 2)
        let evidence = controls.enumerated().map { index, control in
            var layout = control.layoutCustomization; layout.styleID = index == 0 ? "fixture.style.a" : "fixture.style.b"
            return ControllerDesignSession.ControlEvidence(id: control.id.id, accessibilityLabel: "Same label", visualLegend: "Same label",
                kind: control.controlKind, frame: control.frame, hitFrame: control.hitFrame, rotationDegrees: control.rotationDegrees,
                state: .normal, requested: layout, resolved: source.resolvedPresentation(for: control, state: .normal, scheme: .light),
                fallbacks: [], presentationMetadata: .init(actionID: index == 0 ? "ability.q" : "ability.w"))
        }
        let title = variant.orientation.rawValue + "-light-normal"
        let frame = ControllerDesignSession.ReviewFrame(title: title, orientation: variant.orientation, colorScheme: .light,
            state: .normal, statesByControlID: [:], viewportWidth: variant.canvasWidth, viewportHeight: variant.canvasHeight,
            safeAreaInsets: variant.safeAreaInsets, renderScale: 1, canvasFill: .solid(.defaultValue),
            artworkLayers: [.init(id: "overlay.ring", plane: .overlay)], controls: evidence,
            image: .init(path: "fixture.png", byteCount: 0, sha256: String(repeating: "a", count: 64)))
        let sourceReport = ThumbleSkinSourceValidationReport(issues: [.init(severity: .warning, code: "placeholder", message: "Author metadata", path: "author.name")])
        let quality = ThumbleSkinQualityReport(issues: [
            .init(severity: .warning, code: "source-placeholder", message: "Author metadata", path: "author.name"),
            .init(severity: .error, code: "control-outside-safe-area", message: "Same label is outside", path: "artboard." + variant.id,
                  target: .init(controlID: controls[0].id.id)),
            .init(severity: .warning, code: "empty-artwork-layer", message: "Empty layer", path: "skin.json.artworkLayers.overlay.ring", target: .init(layerID: "overlay.ring")),
            .init(severity: .error, code: "missing-pressed-state", message: "State missing", path: "skin.json.styleLibrary.fixture.style.a"),
            .init(severity: .error, code: "missing-active-state", message: "Unreferenced style", path: "skin.json.styleLibrary.unreferenced")])
        let layouts = [ControllerDesignDiagnosticBuilder.LayoutInput(orientation: variant.orientation,
            issues: [.init(severity: .warning, code: "control-overlap", message: "Overlap", controls: controls.map { $0.id.id }, metric: 0.5)])]
        let report = try ControllerDesignDiagnosticBuilder.build(source: sourceReport, quality: quality, artboard: artboard, frames: [frame], layouts: layouts)
        XCTAssertEqual(report.schemaVersion, 1)
        XCTAssertEqual(report.issues.count, 6)
        XCTAssertEqual(Set(report.issues.map(\.id)).count, 6)
        let safe = try XCTUnwrap(report.issues.first { $0.code == "control-outside-safe-area" })
        XCTAssertEqual(safe.targets.map(\.controlID), [controls[0].id.id])
        XCTAssertEqual(safe.targets.map(\.action), ["ability.q"])
        XCTAssertEqual(safe.frameTitles, [title])
        let style = try XCTUnwrap(report.issues.first { $0.code == "missing-pressed-state" })
        XCTAssertEqual(style.targets, safe.targets)
        XCTAssertEqual(report.issues.first { $0.code == "empty-artwork-layer" }?.targets.first?.layerID, "overlay.ring")
        XCTAssertEqual(report.issues.first { $0.code == "missing-active-state" }?.targetResolution, "unresolved")
        let overlap = try XCTUnwrap(report.issues.first { $0.origin == "layout" })
        XCTAssertEqual(Set(overlap.targets.compactMap(\.action)), ["ability.q", "ability.w"])
        XCTAssertEqual(overlap.suggestedRepairs, ["auto-arrange", "resolve-overlap"])
        XCTAssertEqual(overlap.metric, 0.5)
        let token = GamepadStyleToken(id: "fixture.style.a", name: "Base", visualStyle: .init(normal: .init(fillStyle: .solid(.defaultValue))))
        var override = token; override.name = "Dark Override"
        let skin = ThumbleSkin(base: .init(styleLibrary: .init(styles: [token])), variants: [
            .init(id: "dark-override", colorScheme: .dark, appearance: .init(styleLibrary: .init(styles: [override])))])
        XCTAssertEqual(skin.styleSources(orientation: variant.orientation, colorScheme: .light)[token.id], "base")
        XCTAssertEqual(skin.styleSources(orientation: variant.orientation, colorScheme: .dark)[token.id], "variant.dark-override")
        XCTAssertEqual(skin.appearance(orientation: variant.orientation, colorScheme: .dark).styleLibrary.style(id: token.id)?.name, "Dark Override")
        let dark = ControllerDesignSession.ReviewFrame(title: variant.orientation.rawValue + "-dark-normal", orientation: variant.orientation,
            colorScheme: .dark, state: .normal, statesByControlID: [:], viewportWidth: frame.viewportWidth, viewportHeight: frame.viewportHeight,
            safeAreaInsets: frame.safeAreaInsets, renderScale: 1, canvasFill: frame.canvasFill, artworkLayers: frame.artworkLayers,
            controls: frame.controls, image: frame.image)
        let scopedQuality = ThumbleSkinQualityReport(issues: [
            .init(severity: .error, code: "base-state", message: "Base defect", target: .init(styleID: token.id)),
            .init(severity: .error, code: "dark-state", message: "Dark defect", target: .init(styleID: token.id, appearanceID: "dark-override"))])
        let scoped = try ControllerDesignDiagnosticBuilder.build(source: .init(issues: []), quality: scopedQuality,
            artboard: artboard, frames: [frame, dark], layouts: [], skin: skin)
        XCTAssertEqual(scoped.issues.first { $0.code == "base-state" }?.frameTitles, [frame.title])
        XCTAssertEqual(scoped.issues.first { $0.code == "dark-state" }?.frameTitles, [dark.title])
        let overridden = try ControllerDesignDiagnosticBuilder.build(source: .init(issues: []), quality: scopedQuality,
            artboard: artboard, frames: [dark], layouts: [], skin: skin)
        XCTAssertEqual(overridden.issues.first { $0.code == "base-state" }?.targetResolution, "unresolved")
        var namedBase = skin
        namedBase.variants.append(.init(id: "base", colorScheme: .light, appearance: .init(styleLibrary: .init(styles: [override]))))
        XCTAssertEqual(namedBase.styleSources(orientation: variant.orientation, colorScheme: .light)[token.id], "variant.base")
        let collisionQuality = ThumbleSkinQualityReport(issues: [
            .init(severity: .error, code: "base-defect", message: "Base", target: .init(styleID: token.id)),
            .init(severity: .error, code: "variant-base-defect", message: "Variant", target: .init(styleID: token.id, appearanceID: "base"))])
        let collision = try ControllerDesignDiagnosticBuilder.build(source: .init(issues: []), quality: collisionQuality,
            artboard: artboard, frames: [frame], layouts: [], skin: namedBase)
        XCTAssertEqual(collision.issues.first { $0.code == "base-defect" }?.targetResolution, "unresolved")
        XCTAssertEqual(collision.issues.first { $0.code == "variant-base-defect" }?.frameTitles, [frame.title])
        let again = try ControllerDesignDiagnosticBuilder.build(source: sourceReport, quality: quality, artboard: artboard, frames: [frame], layouts: layouts)
        XCTAssertEqual(try ControllerDesignWorkspace.digest(report), try ControllerDesignWorkspace.digest(again))
    }

    func testGenericDesignCanonicalizationRetainsMetadataAndRejectsAmbiguousJSON() throws {
        let a = Data("{\"contentHash\":\"a\",\"exportedAt\":1.0,\"nested\":{\"z\":2,\"a\":3}}".utf8)
        let b = Data("{\"nested\":{\"a\":3,\"z\":2},\"exportedAt\":1,\"contentHash\":\"a\"}".utf8)
        let canonical = try PortableArtifactCanonicalizer.canonicalizeJSON(a)
        XCTAssertEqual(canonical, try PortableArtifactCanonicalizer.canonicalizeJSON(b))
        XCTAssertTrue(String(decoding: canonical, as: UTF8.self).contains("contentHash"))
        XCTAssertThrowsError(try PortableArtifactCanonicalizer.canonicalizeJSON(Data("{\"a\":1,\"a\":2}".utf8)))
        XCTAssertThrowsError(try PortableArtifactCanonicalizer.canonicalizeJSON(Data("{\"a\":9007199254740993}".utf8)))
    }

    @MainActor
    func testDesignNativeEvidenceIncludesExactMatrixAndRejectsStaleSourceOrPixels() throws {
        let root = temporaryDirectory.appendingPathComponent("review")
        _ = try beginDesign(root)
        let renderer = String(repeating: "a", count: 64)
        let review = try ControllerDesignWorkspace.review(at: root, expectedRevision: 1, rendererSHA256: renderer,
                                                         showsSafeAreaOverlay: true, showsTouchTargets: true)
        XCTAssertEqual(review.frames.count, 10)
        let unified = try XCTUnwrap(review.diagnostics)
        XCTAssertEqual(unified.schemaVersion, 1)
        XCTAssertTrue(unified.issues.contains { $0.origin == "quality" && !$0.targets.isEmpty })
        let frameTitles = Set(review.frames.map(\.title) + (review.controlBar?.frames.map(\.title) ?? []))
        XCTAssertTrue(unified.issues.allSatisfy { Set($0.frameTitles).isSubset(of: frameTitles) })
        let bar = try XCTUnwrap(review.controlBar)
        XCTAssertEqual(bar.frames.count, 8)
        let drawer = try XCTUnwrap(review.drawer)
        XCTAssertEqual(drawer.frames.count, 12)
        XCTAssertEqual(drawer.frames.filter(\.resolvedVisibility).count, 8)
        for scene in drawer.frames {
            XCTAssertEqual(scene.nativeLayout.viewport.size, CGSize(width: review.frames[0].viewportWidth, height: review.frames[0].viewportHeight))
            let paint = try XCTUnwrap(scene.nativeLayout.paint)
            XCTAssertEqual(paint.items.isEmpty, !scene.resolvedVisibility)
            XCTAssertNotNil(scene.nativeLayout.frames["native-drawer"])
            XCTAssertNotNil(scene.nativeLayout.frames["native-drawer/reveal"])
            XCTAssertEqual(scene.nativeLayout.frames["native-control-bar"] != nil, scene.resolvedVisibility)
            XCTAssertEqual(scene.surfaceIDs.contains("native-drawer/reveal"), scene.resolvedVisibility || scene.collapsedOpacity > 0)
            if !scene.resolvedVisibility && scene.collapsedOpacity == 0 { XCTAssertTrue(scene.surfaceIDs.isEmpty) }
        }

        XCTAssertEqual(Set(bar.frames.map(\.colorScheme)), [.light, .dark])
        XCTAssertEqual(Set(bar.frames.map(\.isConnected)), [false, true])
        XCTAssertEqual(Set(bar.frames.map(\.isEditing)), [false, true])
        XCTAssertTrue(bar.frames.allSatisfy { $0.viewportWidth > 0 && $0.viewportHeight > 0 && !$0.isDefaultProfile })
        XCTAssertTrue(bar.frames.allSatisfy { !$0.visibleItems.contains(.launchTarget) })
        for frame in bar.frames {
            let items = try XCTUnwrap(frame.nativeLayout?.paint)
            XCTAssertEqual(Set(items.items.keys), Set(frame.visibleItems.filter { $0 != .spacer }.map { "native-control-bar/" + $0.rawValue }))
            XCTAssertEqual(Set(items.icons.keys), Set(frame.surfaceIDs.filter { $0.hasSuffix("/icon") }))
            let paint = try XCTUnwrap(frame.containerPresentation)
            XCTAssertEqual(paint.shape, "capsule")
            XCTAssertEqual(paint.padding, 8)
            XCTAssertEqual(paint.shadowColor.alpha, frame.colorScheme == .dark ? 0.22 : 0.08)
            let layout = try XCTUnwrap(frame.nativeLayout)
            let leaves = ["status/legend", "status/icon", "profile_menu/legend", "profile_menu/icon",
                "edit_layout/legend", "edit_layout/icon", "settings/icon", "home/icon", "connection/legend"]
                .map { "native-control-bar/" + $0 }
            XCTAssertEqual(Set(layout.frames.keys), Set(["native-control-bar"] + frame.visibleItems.map { "native-control-bar/" + $0.rawValue } + leaves))
            XCTAssertEqual(Set(frame.surfaceIDs), Set(layout.frames.keys.filter { !$0.hasSuffix("/spacer") }))
            XCTAssertEqual(layout.viewport.width, frame.viewportWidth)
            XCTAssertEqual(layout.viewport.height, frame.viewportHeight)
        }
        XCTAssertTrue(review.frames.allSatisfy { $0.showsSafeAreaOverlay == true && $0.showsTouchTargets == true })
        let frame = try XCTUnwrap(review.frames.first)
        XCTAssertFalse(frame.controls.isEmpty)
        XCTAssertTrue(frame.controls.allSatisfy { $0.nativeContent != nil })
        let stick = try XCTUnwrap(frame.controls.first { $0.kind == .joystick })
        let nativeStick = try XCTUnwrap(stick.nativeContent)
        let puck = try XCTUnwrap(nativeStick.localSurfaceFrames["joystick-puck"])
        XCTAssertEqual(puck.midX, stick.frame.width / 2, accuracy: 0.001)
        XCTAssertEqual(puck.midY, stick.frame.height / 2, accuracy: 0.001)
        XCTAssertTrue(nativeStick.visibleSurfaceIDs.contains("joystick-puck"))
        XCTAssertTrue(frame.controls.allSatisfy { $0.hitFrame.width >= $0.frame.width })
        XCTAssertTrue(frame.controls.contains { $0.fallbacks.contains("profile-label") })
        let mixed = try XCTUnwrap(review.frames.first { $0.title.hasSuffix("mixed") })
        for control in mixed.controls {
            XCTAssertEqual(control.state, mixed.statesByControlID[control.id] ?? mixed.state)
        }
        let contract = try JSONDecoder().decode(ThumbleSkinArtboard.self, from: Data(contentsOf: root.appendingPathComponent("contract/artboard.json")))
        XCTAssertEqual(Set(frame.controls.map(\.id)), Set(contract.variants[0].controls.map(\.id)))
        let frozen = try JSONDecoder().decode(GamepadConfigurationProfile.self, from: Data(contentsOf: root.appendingPathComponent("contract/profile.json")))
        let source = frozen.customization.resolvedControls(in: frozen.customization.deviceCanvas.editorDeviceFrame.screenRect.size)
        for control in frame.controls {
            let original = try XCTUnwrap(source.first { $0.id.id == control.id })
            XCTAssertEqual(control.requested.shape, original.layoutCustomization.shape)
            XCTAssertEqual(control.frame, original.frame)
            let hit = try XCTUnwrap(contract.variants[0].controls.first { $0.id == control.id }?.nativeGeometry?.hitFrame)
            XCTAssertEqual(control.hitFrame.minX, hit.x * frame.viewportWidth, accuracy: 0.000001)
            XCTAssertEqual(control.hitFrame.height, hit.height * frame.viewportHeight, accuracy: 0.000001)
        }
        let roundTrip = try JSONDecoder().decode(ControllerDesignSession.Review.self, from: JSONEncoder().encode(review))
        XCTAssertEqual(roundTrip.frames.first?.controls.first?.resolved, frame.controls.first?.resolved)
        XCTAssertEqual(roundTrip.frames.first?.showsSafeAreaOverlay, true)
        XCTAssertEqual(roundTrip.frames.first?.showsTouchTargets, true)
        XCTAssertEqual(Set(review.frames.map(\.orientation)), [.landscape])
        XCTAssertEqual(review.visualApproval, "pending-independent-critique")
        XCTAssertTrue(review.frames.contains { $0.title.hasSuffix("mixed") && !$0.statesByControlID.isEmpty })
        XCTAssertEqual(try ControllerDesignWorkspace.reviewedCandidate(at: root, number: 1,
            expectedRevision: 1, rendererSHA256: renderer, evidenceSHA256: try ControllerDesignWorkspace.digest(review)).sourceSHA256, review.sourceSHA256)
        XCTAssertThrowsError(try ControllerDesignWorkspace.reviewedCandidate(at: root, number: 1,
            expectedRevision: 1, rendererSHA256: String(repeating: "b", count: 64), evidenceSHA256: try ControllerDesignWorkspace.digest(review)))
        let hash = try ControllerDesignWorkspace.digest(review)
        let barCritic = ControllerDesignSession.Critique(id: UUID(), review: 1, evidenceSHA256: hash,
            reviewer: "bar-critic", stage: .criticOne, verdict: .revise,
            issues: [.init(id: "bar-spacing", severity: .minor, controlID: nil, layerID: "native-control-bar",
                action: nil, frameTitles: [bar.frames[0].title], observation: "The bar needs more optical spacing.",
                requestedCorrection: "Adjust the bar material and item spacing.", surfaceID: "native-control-bar")])
        _ = try ControllerDesignWorkspace.recordCritique(at: root, expectedRevision: 1,
            rendererSHA256: renderer, critique: barCritic)
        let expanded = try XCTUnwrap(drawer.frames.first { $0.resolvedVisibility })
        let drawerCritic = ControllerDesignSession.Critique(id: UUID(), review: 1, evidenceSHA256: hash,
            reviewer: "drawer-critic", stage: .criticOne, verdict: .revise,
            issues: [.init(id: "reveal-spacing", severity: .minor, controlID: nil, layerID: "native-drawer",
                action: nil, frameTitles: [expanded.title], observation: "Reveal spacing needs refinement.",
                requestedCorrection: "Increase drawer spacing.", surfaceID: "native-drawer/reveal")])
        _ = try ControllerDesignWorkspace.recordCritique(at: root, expectedRevision: 1,
            rendererSHA256: renderer, critique: drawerCritic)
        let firstSurface = try XCTUnwrap(frame.controls[0].nativeContent?.visibleSurfaceIDs.first)
        let critic = ControllerDesignSession.Critique(id: UUID(), review: 1, evidenceSHA256: hash,
            reviewer: "independent-critic-one", stage: .criticOne, verdict: .revise,
            issues: [.init(id: "legend-spacing", severity: .minor, controlID: frame.controls[0].id,
                layerID: nil, action: nil, frameTitles: [frame.title], observation: "Legend spacing needs refinement.",
                requestedCorrection: "Increase the optical margin around the legend.",
                surfaceID: frame.controls[0].id + "/" + firstSurface)])
        var targeted = critic
        // A surface target is stable under the control UUID and checked against each panel.
        var issue = ControllerDesignSession.Critique.Issue(id: "mismatched", severity: .minor,
            controlID: try XCTUnwrap(frame.controls.first { $0.id != stick.id }?.id), layerID: nil, action: nil,
            frameTitles: [frame.title], observation: "Puck needs optical separation.", requestedCorrection: "Reduce puck ratio.",
            surfaceID: stick.id + "/joystick-puck")
        targeted = .init(id: UUID(), review: 1, evidenceSHA256: hash, reviewer: "surface-critic", stage: .criticOne,
                         verdict: .revise, issues: [issue])
        XCTAssertThrowsError(try ControllerDesignWorkspace.recordCritique(at: root, expectedRevision: 1,
            rendererSHA256: renderer, critique: targeted)) // mismatched control target
        issue = .init(id: "puck-spacing", severity: .minor, controlID: stick.id, layerID: nil, action: nil,
                      frameTitles: [frame.title], observation: "Puck needs more optical separation.",
                      requestedCorrection: "Reduce puck ratio.", surfaceID: stick.id + "/unknown-surface")
        targeted = .init(id: UUID(), review: 1, evidenceSHA256: hash, reviewer: "surface-critic", stage: .criticOne,
                         verdict: .revise, issues: [issue])
        XCTAssertThrowsError(try ControllerDesignWorkspace.recordCritique(at: root, expectedRevision: 1,
            rendererSHA256: renderer, critique: targeted))
        let qa = ControllerDesignSession.Critique(id: UUID(), review: 1, evidenceSHA256: hash,
            reviewer: "independent-qa", stage: .qa, verdict: .pass, issues: [])
        XCTAssertThrowsError(try ControllerDesignWorkspace.recordCritique(at: root, expectedRevision: 1,
            rendererSHA256: renderer, critique: qa))
        let record = try ControllerDesignWorkspace.recordCritique(at: root, expectedRevision: 1,
            rendererSHA256: renderer, critique: critic)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(record).path))
        XCTAssertThrowsError(try ControllerDesignWorkspace.recordCritique(at: root, expectedRevision: 1,
            rendererSHA256: renderer, critique: critic))
        let second = ControllerDesignSession.Critique(id: UUID(), review: 1, evidenceSHA256: hash,
            reviewer: "independent-critic-two", stage: .criticTwo, verdict: .pass, issues: [])
        _ = try ControllerDesignWorkspace.recordCritique(at: root, expectedRevision: 1,
            rendererSHA256: renderer, critique: second)
        _ = try ControllerDesignWorkspace.recordCritique(at: root, expectedRevision: 1,
            rendererSHA256: renderer, critique: qa)
        XCTAssertEqual(try ControllerDesignWorkspace.inspect(at: root).session.revision, 1)
        let png = root.appendingPathComponent(review.frames[0].image.path)
        for file in [bar.frames[0].image, bar.contactSheet, drawer.frames[0].image, drawer.contactSheet] {
            let path = root.appendingPathComponent(file.path)
            let bytes = try Data(contentsOf: path)
            try Data("tampered bar evidence".utf8).write(to: path)
            XCTAssertThrowsError(try ControllerDesignWorkspace.reviewedCandidate(at: root, number: 1,
                expectedRevision: 1, rendererSHA256: renderer, evidenceSHA256: hash))
            try bytes.write(to: path)
        }
        let original = try Data(contentsOf: png)
        try Data("tampered".utf8).write(to: png)
        XCTAssertThrowsError(try ControllerDesignWorkspace.reviewedCandidate(at: root, number: 1,
            expectedRevision: 1, rendererSHA256: renderer, evidenceSHA256: try ControllerDesignWorkspace.digest(review)))
        try original.write(to: png)
        try Data("control { background: #445566; color: #FFFFFF; }".utf8)
            .write(to: root.appendingPathComponent("styles/controller.css"))
        XCTAssertThrowsError(try ControllerDesignWorkspace.reviewedCandidate(at: root, number: 1,
            expectedRevision: 1, rendererSHA256: renderer, evidenceSHA256: try ControllerDesignWorkspace.digest(review)))
        let synchronized = try ControllerDesignWorkspace.update(at: root, expectedRevision: 1, edits: [])
        XCTAssertEqual(synchronized.changedFiles, ["styles/controller.css"])
        XCTAssertEqual(synchronized.session.revision, 2)
        XCTAssertEqual(synchronized.staleReviews, [1])
        XCTAssertNil(synchronized.session.latestReview)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(review.contactSheet.path).path))
    }
}

extension ThumbleSkinWorkspaceTests {
    func testSemanticArtworkAnchorsResolveOrientationLocalUnionsAndRejectUnsafeTransforms() throws {
        let first = ThumbleSkinArtboardControl(id: "a", label: "A", kind: .button, visualRole: .primaryAction, inputID: nil,
            frame: .init(x: 0.2, y: 0.3, width: 0.1, height: 0.1))
        let second = ThumbleSkinArtboardControl(id: "b", label: "B", kind: .button, visualRole: .primaryAction, inputID: nil,
            frame: .init(x: 0.4, y: 0.3, width: 0.1, height: 0.1))
        var variant = try XCTUnwrap(ThumbleSkinArtboardCatalog.resolve("xbox-v1")?.variants.first)
        variant.controls = [first, second]
        let semantics: [ThumbleSkinControlSemantics] = [
            .init(controlID: "a", action: "ability.q", groups: ["abilities"]),
            .init(controlID: "b", groups: ["abilities"]),
            .init(controlID: "portrait-only", groups: ["abilities"])]
        let group = try ThumbleSkinArtworkAnchor(group: "abilities").resolvedFrame(in: variant, semantics: semantics)
        XCTAssertEqual(group.x, 0.2, accuracy: 0.000001)
        XCTAssertEqual(group.width, 0.3, accuracy: 0.000001)
        let action = try ThumbleSkinArtworkAnchor(action: "ability.q", scaleX: 2, offsetY: 0.5)
            .resolvedFrame(in: variant, semantics: semantics)
        XCTAssertEqual(action.x, 0.15, accuracy: 0.000001)
        XCTAssertEqual(action.y, 0.35, accuracy: 0.000001)
        for anchor in [ThumbleSkinArtworkAnchor(controlID: "missing"), .init(group: "absent"),
                       .init(controlID: "a", action: "ability.q"), .init(controlID: "a", scaleX: 5),
                       .init(controlID: "a", offsetX: -.infinity), .init(controlID: "a", scaleX: 4, offsetX: -1),
                       .init(group: "UPPERCASE")] {
            XCTAssertThrowsError(try anchor.resolvedFrame(in: variant, semantics: semantics))
        }
        XCTAssertThrowsError(try JSONDecoder().decode(ThumbleSkinArtworkAnchor.self,
            from: Data(#"{"controlID":"a","hitTesting":true}"#.utf8)))
    }

    @MainActor
    func testAnchoredArtworkRecompilesWithLayoutAndCapturedCompatibilityRequiresExactGeometry() throws {
        let root = temporaryDirectory.appendingPathComponent("anchored-design")
        var profile = GamepadControllerTemplate.xbox.makeProfile()
        profile.landscapeCustomization = nil
        profile.portraitCustomization = nil
        profile.customization.designMetadata = nil
        let initial = try ControllerDesignWorkspace.begin(profile: profile, bindings: Data("{}".utf8),
            targetRevision: 17, safeAreas: [.landscape: .init()], name: "Anchor Test",
            identifier: "com.example.anchor-test", at: root)
        var workspace = try ThumbleSkinCompiler.loadWorkspace(from: root).workspace
        let target = try XCTUnwrap(workspace.capturedArtboards[0].variants[0].controls.first { $0.id.hasPrefix("builtin.") })
        workspace.controlSemantics = [.init(controlID: target.id, action: "ability.q", groups: ["abilities"])]
        workspace.sourceAssets = [.init(id: "ability-well", path: "sources/well.svg", purpose: .canvasArtwork,
            outputWidth: 256, outputHeight: 256, anchor: .init(action: "ability.q", scaleX: 1.1, scaleY: 1.1, plane: .overlay))]
        let edited = try ControllerDesignWorkspace.update(at: root, expectedRevision: 1, edits: [
            .init(path: "skin-source.json", data: JSONEncoder().encode(workspace)),
            .init(path: "styles/controller.css", data: Data("controller { background: #000000; } control { background: #111111; color: #ffffff; }".utf8)),
            .init(path: "sources/well.svg", data: Data(##"<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256" viewBox="0 0 256 256"><rect width="256" height="256" fill="#ff0000"/></svg>"##.utf8))])
        let first = try ThumbleSkinCompiler.compile(source: root)
        XCTAssertEqual(first.packageData, try ThumbleSkinCompiler.compile(source: root).packageData)
        let declaration = try XCTUnwrap(first.package.manifest.compatibility)
        XCTAssertEqual(declaration.mode, .capturedController)
        XCTAssertTrue(declaration.templates.isEmpty)
        XCTAssertTrue(ThumbleSkinCompatibilityEvaluator.evaluate(declaration, customization: profile.customization,
            orientation: .landscape).allowsTemplateArtwork)
        let oldLayer = try XCTUnwrap(try XCTUnwrap(first.package.skin).appearance(orientation: .landscape, colorScheme: .light)
            .artworkLayers?.first { $0.id == "ability-well" })
        let oldFrame = try XCTUnwrap(oldLayer.frame)
        let center = target.frame.x + target.frame.width / 2
        let delta = center > 0.5 ? -0.01 : 0.01
        let moved = try ControllerDesignWorkspace.update(at: root, expectedRevision: edited.session.revision, edits: [],
            layoutEdits: [.init(variant: .primary, controlID: target.id, centerX: center + delta, rotationDegrees: 10)])
        XCTAssertEqual(moved.session.bindingSHA256, initial.bindingSHA256)
        let second = try ThumbleSkinCompiler.compile(source: root)
        let newFrame = try XCTUnwrap(try XCTUnwrap(second.package.skin).appearance(orientation: .landscape, colorScheme: .light)
            .artworkLayers?.first { $0.id == "ability-well" }?.frame)
        XCTAssertEqual(newFrame.x - oldFrame.x, delta, accuracy: 0.000001)
        XCTAssertEqual(newFrame.width, oldFrame.width, accuracy: 0.000001)
        XCTAssertEqual(second.workspace.sourceAssets[0].anchor, workspace.sourceAssets[0].anchor)
        let revised = try JSONDecoder().decode(GamepadConfigurationProfile.self,
            from: Data(contentsOf: root.appendingPathComponent("contract/profile.json")))
        XCTAssertFalse(ThumbleSkinCompatibilityEvaluator.evaluate(declaration, customization: revised.customization,
            orientation: .landscape).allowsTemplateArtwork)
        let revisedDeclaration = try XCTUnwrap(second.package.manifest.compatibility)
        XCTAssertTrue(ThumbleSkinCompatibilityEvaluator.evaluate(revisedDeclaration, customization: revised.customization,
            orientation: .landscape).allowsTemplateArtwork)
        let before = profile.customization.applying(skinPackage: first.package, orientation: .landscape,
            colorScheme: .light, options: .replacingAppearance)
        let after = revised.customization.applying(skinPackage: second.package, orientation: .landscape,
            colorScheme: .light, options: .replacingAppearance)
        let row = Int(oldFrame.y * before.deviceCanvas.editorDeviceFrame.screenRect.height
            + oldFrame.height * before.deviceCanvas.editorDeviceFrame.screenRect.height / 2)
        func firstRedPixel(_ customization: GamepadCustomization) throws -> Int {
            let image = try ThumbleNativeSkinPreviewRenderer.render(item: .init(title: "anchor", customization: customization,
                colorScheme: .light, state: .normal), scale: 1)
            let bitmap = NSBitmapImageRep(cgImage: image)
            XCTAssertEqual(customization.artworkLayers.count, 1)
            return try XCTUnwrap((0..<image.width).first { x in
                guard let color = bitmap.colorAt(x: x, y: row) else { return false }
                return color.redComponent > 0.9 && color.greenComponent < 0.1 && color.blueComponent < 0.1
            })
        }
        let oldPixel = try firstRedPixel(before)
        let newPixel = try firstRedPixel(after)
        XCTAssertEqual(Double(newPixel - oldPixel), Double(delta * before.deviceCanvas.editorDeviceFrame.screenRect.width), accuracy: 1.1)
        // Rotation is independently part of the compatibility contract, even when bounds match.
        let rotationOnly = ThumbleSkinCapturedGeometry(variants: [ThumbleSkinArtboardVariant(
            id: "rotation-check", orientation: workspace.capturedArtboards[0].variants[0].orientation,
            canvasWidth: workspace.capturedArtboards[0].variants[0].canvasWidth,
            canvasHeight: workspace.capturedArtboards[0].variants[0].canvasHeight,
            safeAreaInsets: workspace.capturedArtboards[0].variants[0].safeAreaInsets,
            controls: workspace.capturedArtboards[0].variants[0].controls.map { value in
                var control = value; if control.id == target.id { control.rotationDegrees = 10 }; return control
            })])
        XCTAssertFalse(rotationOnly.matches(profile.customization, orientation: .landscape))
    }
}

extension ThumbleSkinWorkspaceTests {
    @MainActor
    func testPersistentNativePresentationFeedsCaptureSelectorsAnchorsAndReview() throws {
        let root = temporaryDirectory.appendingPathComponent("native-presentation")
        var profile = GamepadControllerTemplate.xbox.makeProfile()
        profile.landscapeCustomization = nil; profile.portraitCustomization = nil
        let index = try XCTUnwrap(profile.customization.elements.firstIndex { $0.kind == .button })
        let metadata = GamepadControlPresentation(actionID: "ability.q", purposeID: "primary", groupIDs: ["abilities"],
            legend: "Q", caption: "Light Binding", accessibilityName: "Cast Light Binding")
        profile.customization.elements[index].presentation = metadata
        let id = profile.customization.elements[index].id
        profile = try JSONDecoder().decode(GamepadConfigurationProfile.self, from: JSONEncoder().encode(profile))
        let session = try ControllerDesignWorkspace.begin(profile: profile, bindings: Data("{}".utf8), targetRevision: 17,
            safeAreas: [.landscape: .init()], name: "Native Presentation", identifier: "com.example.native-presentation", at: root)
        let workspace = try ThumbleSkinCompiler.loadWorkspace(from: root).workspace
        let captured = try XCTUnwrap(workspace.capturedArtboards[0].variants[0].controls.first { $0.inputID?.uuid == id })
        XCTAssertEqual(captured.presentation, metadata)
        let anchored = try ThumbleSkinArtworkAnchor(group: "abilities").resolvedFrame(in: workspace.capturedArtboards[0].variants[0], semantics: [])
        XCTAssertEqual(anchored.x, captured.frame.x, accuracy: 0.000001)
        XCTAssertEqual(anchored.y, captured.frame.y, accuracy: 0.000001)
        XCTAssertEqual(anchored.width, captured.frame.width, accuracy: 0.000001)
        XCTAssertEqual(anchored.height, captured.frame.height, accuracy: 0.000001)
        _ = try ControllerDesignWorkspace.update(at: root, expectedRevision: session.revision, edits: [
            .init(path: "styles/controller.css", data: Data("control { background: #111111; color: #ffffff; } control[action=\"ability.q\"] { background: #ff0000; }".utf8))])
        let css = try ThumbleCSSCompiler.compile(workspace: workspace, sourceRoot: root)
        XCTAssertFalse(css.report.warnings.contains { $0.code == "selector-matches-nothing" })
        let review = try ControllerDesignWorkspace.review(at: root, expectedRevision: 2, rendererSHA256: String(repeating: "a", count: 64))
        let control = try XCTUnwrap(review.frames[0].controls.first { $0.id == captured.id })
        XCTAssertEqual(control.visualLegend, "Q")
        XCTAssertEqual(control.accessibilityLabel, "Cast Light Binding")
        XCTAssertEqual(control.presentationMetadata, metadata)
        XCTAssertEqual(control.nativeContent?.caption, "Light Binding")
        XCTAssertTrue(control.nativeContent?.visibleSurfaceIDs.contains("caption") == true)
        XCTAssertTrue(control.fallbacks.contains("native-model-legend"))
        XCTAssertEqual(control.nativeContent?.fixedProperties["captionFontSize"], 10)
        let resolved = try XCTUnwrap(profile.customization.resolvedControls(in: profile.customization.deviceCanvas.editorDeviceFrame.screenRect.size).first { $0.elementID == id })
        XCTAssertEqual(resolved.visualLegend, "Q")
        XCTAssertEqual(resolved.accessibilityName, "Cast Light Binding")
    }
}
