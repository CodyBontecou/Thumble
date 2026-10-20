import CryptoKit
import SwiftUI
import XCTest

/// Frozen pre-removal behavior. These fixtures must outlive the package system.
final class FeatureRemovalBaselineTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func fixture(_ name: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
            root.appendingPathComponent("Host/fixtures/feature-removal/v1/\(name).json"))) as? [String: Any])
    }

    private func decode<T: Decodable>(_ type: T.Type, _ value: Any) throws -> T {
        try JSONDecoder().decodeUnique(type, from: JSONSerialization.data(withJSONObject: value))
    }

    private func package(_ value: [String: Any]) throws -> ThumbleSkinPackage {
        let payloads = try XCTUnwrap(value["assetPayloads"] as? [String: String])
        return ThumbleSkinPackage(
            manifest: try decode(ThumbleSkinManifest.self, XCTUnwrap(value["manifest"])),
            skin: try decode(ThumbleSkin.self, XCTUnwrap(value["skin"])),
            assets: try payloads.mapValues { try XCTUnwrap(Data(base64Encoded: $0)) })
    }

    func testOwnedAppearanceReproducesFrozenResolutionsWithoutPackages() throws {
        let value = try fixture("appearance")
        let profiles = try XCTUnwrap(value["profiles"] as? [String: Any])
        for row in try XCTUnwrap(value["cases"] as? [[String: Any]]) {
            let name = try XCTUnwrap(row["profile"] as? String)
            let local = try decode(GamepadCustomization.self, XCTUnwrap(profiles[name]))
            let expected = try decode(GamepadCustomization.self, XCTUnwrap(row["expected"]))
            let snapshot = GamepadAppearanceSnapshot(expected)
            let bytes = try JSONEncoder().encode(snapshot)
            let reloaded = try JSONDecoder().decodeUnique(GamepadAppearanceSnapshot.self, from: bytes)
            XCTAssertEqual(snapshot, reloaded)
            // No package or resolver is used after capture, including on reload.
            XCTAssertEqual(reloaded.applying(to: local), expected, "\(name) \(row["scheme"] ?? "")")
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            XCTAssertNil(json["skinReference"])
            XCTAssertNil(json["elements"])
            XCTAssertNil(json["deviceCanvas"])
            var invalid = json
            invalid["controls"] = ["not-a-control-uuid": [:]]
            XCTAssertThrowsError(try decode(GamepadAppearanceSnapshot.self, invalid))
            invalid = json
            invalid["controlBar"] = ["unknown-bar-item": [:]]
            XCTAssertThrowsError(try decode(GamepadAppearanceSnapshot.self, invalid))
            invalid = json
            invalid["deviceCanvas"] = ["frameID": "iphone-17-pro-portrait"]
            XCTAssertThrowsError(try decode(GamepadAppearanceSnapshot.self, invalid))
        }
    }

    func testOwnedControlAppearancePreservesGeometryAndIndependentCopies() throws {
        var source = GamepadButtonCustomization(centerX: 0.2, centerY: 0.3, widthScale: 2,
            heightScale: 3, rotationDegrees: 45, zIndex: 4, fillColor: .init(red: 1, green: 0, blue: 0),
            icon: .text("source"), showsIntegratedLabel: false, isLocationLocked: true, isHidden: true)
        let captured = GamepadControlAppearanceSnapshot(source)
        source.icon = .text("changed")
        var destination = GamepadButtonCustomization(centerX: 0.7, centerY: 0.8, widthScale: 4,
            heightScale: 5, rotationDegrees: 90, zIndex: 7, isLocationLocked: false, isHidden: false)
        let original = destination
        destination = captured.applying(to: destination)
        XCTAssertEqual(destination.icon, .text("source"))
        XCTAssertFalse(destination.showsIntegratedLabel)
        XCTAssertEqual(destination.centerX, original.centerX)
        XCTAssertEqual(destination.centerY, original.centerY)
        XCTAssertEqual(destination.widthScale, original.widthScale)
        XCTAssertEqual(destination.heightScale, original.heightScale)
        XCTAssertEqual(destination.rotationDegrees, original.rotationDegrees)
        XCTAssertEqual(destination.zIndex, original.zIndex)
        XCTAssertEqual(destination.isLocationLocked, original.isLocationLocked)
        XCTAssertEqual(destination.isHidden, original.isHidden)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(captured)) as? [String: Any])
        for field in ["centerX", "centerY", "widthScale", "heightScale", "rotationDegrees", "zIndex", "hitInsets", "isLocationLocked", "isHidden", "output"] {
            XCTAssertNil(encoded[field], field)
            var invalid = encoded
            invalid[field] = 1
            XCTAssertThrowsError(try decode(GamepadControlAppearanceSnapshot.self, invalid), field)
        }
    }

    func testLegacyMaterializationKeepsEverySchemeAndTriggerBank() throws {
        let value = try fixture("appearance")
        var skin = try package(value)
        // The resolver baseline deliberately predates package validation. Give
        // this derived migration input an honest digest and capability flag;
        // keep the frozen pre-removal fixture bytes unchanged.
        for index in skin.manifest.assets.indices {
            let data = try XCTUnwrap(skin.assets[skin.manifest.assets[index].id])
            skin.manifest.assets[index].sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        skin.manifest.compatibility = .init(requiredFeatures: [.actionSetLayers])
        let banks = try fixture("action-sets")
        let rows = try XCTUnwrap(banks["cases"] as? [[String: String]])
        let control = KeypadElementID(try XCTUnwrap(UUID(uuidString: XCTUnwrap(banks["controlID"] as? String))))
        skin.skin?.variants = try rows.map { row in
            ThumbleSkinVariant(id: "\(row["scheme"]!)-\(row["actionSet"]!)",
                colorScheme: try XCTUnwrap(ThumbleSkinColorScheme(rawValue: XCTUnwrap(row["scheme"]))),
                appearance: ThumbleSkinAppearance(buttonRules: [ThumbleSkinButtonRule(button: control,
                    appearance: ThumbleSkinControlAppearance(icon: .text(try XCTUnwrap(row["icon"]))))]),
                actionSet: try XCTUnwrap(ThumbleActionSet(rawValue: XCTUnwrap(row["actionSet"]))))
        }
        let profiles = try XCTUnwrap(value["profiles"] as? [String: Any])
        let local = try decode(GamepadCustomization.self, XCTUnwrap(profiles["wowForever"]))
        var profile = GamepadConfigurationProfile(name: "Migration", customization: local)
        profile.skinReference = .init(identifier: skin.manifest.identifier, version: skin.manifest.version)
        let before = profile
        let variants = try ThumbleLegacyAppearanceMaterializer.materialize(profile, orientation: .landscape, package: skin)
        XCTAssertEqual(variants.count, 8)
        XCTAssertEqual(profile, before)
        let encoded = try JSONEncoder().encode(variants)
        let reloaded = try JSONDecoder().decodeUnique([ThumbleLegacyAppearanceMaterializer.Variant].self, from: encoded)
        XCTAssertEqual(reloaded, variants)
        for variant in reloaded {
            let expected = try XCTUnwrap(rows.first { $0["scheme"] == variant.colorScheme.rawValue && $0["actionSet"] == variant.actionSet.rawValue })
            let result = variant.appearance.applying(to: local)
            XCTAssertEqual(result.buttonCustomization(for: control).icon, .text(try XCTUnwrap(expected["icon"])))
            XCTAssertEqual(result.elements.map(\.id), local.elements.map(\.id))
            XCTAssertEqual(result.elements.map(\.output), local.elements.map(\.output))
            XCTAssertEqual(result.elements.map(\.partOutputs), local.elements.map(\.partOutputs))
            XCTAssertEqual(result.designMetadata, local.designMetadata)
        }
        XCTAssertEqual(try ThumbleLegacyAppearanceMaterializer.materialize(profile, orientation: .landscape, package: skin), variants)
    }

    func testLegacyMaterializationRequiresTheExactCompletePackage() throws {
        let value = try fixture("appearance")
        var skin = try package(value)
        var profile = GamepadConfigurationProfile(name: "Recovery", customization: .blankCanvas)
        profile.skinReference = .init(identifier: skin.manifest.identifier, version: skin.manifest.version)
        XCTAssertThrowsError(try ThumbleLegacyAppearanceMaterializer.materialize(profile, orientation: .landscape, package: nil)) {
            XCTAssertEqual($0 as? ThumbleLegacyAppearanceMaterializer.RecoveryRequired, .missingPackage)
        }
        var mismatched = skin
        mismatched.manifest.version = "99.0.0"
        XCTAssertThrowsError(try ThumbleLegacyAppearanceMaterializer.materialize(profile, orientation: .landscape, package: mismatched)) {
            XCTAssertEqual($0 as? ThumbleLegacyAppearanceMaterializer.RecoveryRequired, .mismatchedPackage)
        }
        XCTAssertThrowsError(try ThumbleLegacyAppearanceMaterializer.materialize(profile, orientation: .landscape, package: skin)) {
            guard case .invalidPackage(let codes) = $0 as? ThumbleLegacyAppearanceMaterializer.RecoveryRequired else {
                return XCTFail("Expected corrupt-resource recovery, got \($0)")
            }
            XCTAssertTrue(codes.contains("asset-hash-mismatch"))
        }
        skin.assets.removeAll()
        XCTAssertThrowsError(try ThumbleLegacyAppearanceMaterializer.materialize(profile, orientation: .landscape, package: skin)) {
            guard case .invalidPackage(let codes) = $0 as? ThumbleLegacyAppearanceMaterializer.RecoveryRequired else {
                return XCTFail("Expected resource recovery, got \($0)")
            }
            XCTAssertTrue(codes.contains("missing-asset-data"))
        }
    }

    func testOwnedAppearanceDoesNotReviveDeletedControlsOrRevertEdits() throws {
        let value = try fixture("appearance")
        let row = try XCTUnwrap((value["cases"] as? [[String: Any]])?.first { $0["profile"] as? String == "mixed" })
        let original = try decode(GamepadCustomization.self, XCTUnwrap(row["expected"]))
        let snapshot = GamepadAppearanceSnapshot(original)
        var edited = original
        let removed = try XCTUnwrap(edited.elements.first).id
        edited.elements.removeAll { $0.id == removed }
        edited.customButtons.removeAll { $0.id == removed }
        edited.buttonCustomizations = edited.buttonCustomizations.filter { $0.key.uuid != removed }
        let retained = try XCTUnwrap(edited.elements.first).inputID
        edited.setPosition(CGPoint(x: 0.73, y: 0.62), for: .builtin(retained))
        edited.updatedAt = 12345
        edited = edited.normalized
        var applied = snapshot.applying(to: edited)
        XCTAssertEqual(applied.elements.map(\.id), edited.elements.map(\.id))
        XCTAssertFalse(applied.elements.contains { $0.id == removed })
        XCTAssertEqual(applied.elements.map(\.layout.centerX), edited.elements.map(\.layout.centerX))
        XCTAssertEqual(applied.elements.map(\.layout.centerY), edited.elements.map(\.layout.centerY))
        XCTAssertEqual(applied.elements.map(\.output), edited.elements.map(\.output))
        XCTAssertEqual(applied.updatedAt, 12345)
        // The restored design is ordinary editable data, with no package cascade
        // to mask a subsequent style change.
        var style = applied.buttonCustomization(for: retained)
        style.icon = .text("My edit")
        applied.setButtonCustomization(style, for: retained)
        let reloaded = try JSONDecoder().decodeUnique(GamepadCustomization.self, from: JSONEncoder().encode(applied))
        XCTAssertEqual(reloaded.buttonCustomization(for: retained).icon, .text("My edit"))
    }

    func testMaterializationRejectsMissingLocalResourcesWithoutChangingProfile() throws {
        var local = GamepadCustomization.defaultValue
        local.backgroundFillStyle = .image(GamepadImageFill(assetID: "missing-background"))
        let profile = GamepadConfigurationProfile(name: "Local recovery", customization: local)
        XCTAssertThrowsError(try ThumbleLegacyAppearanceMaterializer.materialize(profile, orientation: .landscape, package: nil)) {
            XCTAssertEqual($0 as? ThumbleLegacyAppearanceMaterializer.RecoveryRequired, .missingResources(["missing-background"]))
        }
        XCTAssertEqual(profile.customization.backgroundFillStyle, local.backgroundFillStyle)
        local.backgroundFillStyle = .image(GamepadImageFill(assetID: "embedded-background", data: Data([1, 2, 3])))
        XCTAssertEqual(try GamepadAppearanceSnapshot(local).missingResourceIDs(), [])
    }

    @MainActor
    func testNativeArchiveAppearanceSurvivesPackageFreeExportAndReload() throws {
        let archive = root.appendingPathComponent("Host/fixtures/legacy-skin-packages/solar-sumi-1.0.0-edbecde5b708.pocketpad")
        let package = try ThumbleSkinPackageCodec.decode(Data(contentsOf: archive))
        var profile = GamepadControllerTemplate.arcadeStick.makeProfile()
        // The current starter uses generic roles for its face/menu buttons.
        // This archive explicitly requires semantic roles before showing its
        // canvas artwork, so exercise a genuinely compatible saved design.
        var local = profile.customization(for: .landscape)
        let roles: [String: GamepadVisualRole] = [
            "B1": .primaryAction, "B2": .secondaryAction, "B3": .utility, "Start": .menu
        ]
        for index in local.elements.indices {
            guard let role = roles[local.elements[index].label] else { continue }
            local.elements[index].visualRole = role
            if let mirror = local.customButtons.firstIndex(where: { $0.id == local.elements[index].id }) {
                local.customButtons[mirror].visualRole = role
            }
        }
        profile.setCustomization(local, for: .landscape)
        let compatibility = ThumbleSkinCompatibilityEvaluator.evaluate(package.manifest.compatibility,
            customization: profile.customization(for: .landscape), orientation: .landscape)
        XCTAssertTrue(compatibility.allowsTemplateArtwork, "\(compatibility.issues)")
        profile.applySkin(package)
        let variants = try ThumbleLegacyAppearanceMaterializer.materialize(profile, orientation: .landscape, package: package)
        let reference = try XCTUnwrap(variants.first { $0.colorScheme == .light && $0.actionSet == .base })
        var candidate = GamepadConfigurationProfile(id: profile.id, name: profile.name,
            primaryCustomization: reference.appearance.applying(to: profile.customization(for: .landscape)),
            outputMode: profile.outputMode, launchTarget: profile.launchTarget, updatedAt: profile.updatedAt)
        candidate.appearanceBank = try GamepadAppearanceBank(variants: variants)
        let reloaded = try JSONDecoder().decodeUnique(GamepadConfigurationProfile.self, from: JSONEncoder().encode(candidate))
        XCTAssertNil(reloaded.skinReference)
        XCTAssertEqual(reloaded, candidate)
        let output = root.appendingPathComponent("build/FeatureRemovalBaseline")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for variant in try XCTUnwrap(reloaded.appearanceBank).variants where variant.actionSet == .base {
            let expected = profile.resolvedCustomization(for: .landscape, colorScheme: variant.colorScheme,
                skinPackage: package, actionSet: variant.actionSet)
            guard case .image(let background)? = expected.backgroundFillStyle else {
                return XCTFail("Use the compatible template so the archive's canvas artwork is exercised.")
            }
            XCTAssertFalse(background.data?.isEmpty ?? true)
            XCTAssertFalse(expected.assetLibrary.assets.isEmpty)
            let migrated = reloaded.resolvedCustomization(for: .landscape, colorScheme: variant.colorScheme,
                skinPackage: nil, actionSet: variant.actionSet)
            XCTAssertEqual(migrated, expected)
            for state in [GamepadControlPresentationState.normal, .pressed] {
                let originalPNG = try ThumbleNativeSkinPreviewRenderer.pngData(item: .init(title: "Archive migration",
                    customization: expected, colorScheme: variant.colorScheme, state: state), scale: 1)
                let migratedPNG = try ThumbleNativeSkinPreviewRenderer.pngData(item: .init(title: "Archive migration",
                    customization: migrated, colorScheme: variant.colorScheme, state: state), scale: 1)
                XCTAssertEqual(SHA256.hash(data: originalPNG), SHA256.hash(data: migratedPNG))
                try originalPNG.write(to: output.appendingPathComponent("source-solar-sumi-\(variant.colorScheme.rawValue)-\(state.rawValue).png"), options: .atomic)
                try migratedPNG.write(to: output.appendingPathComponent("migrated-solar-sumi-\(variant.colorScheme.rawValue)-\(state.rawValue).png"), options: .atomic)
            }
        }
    }

    func testFrozenAppearanceIncludesWoWOutputsAssetsStylesAndOverrides() throws {
        let value = try fixture("appearance")
        let package = try package(value)
        let profiles = try XCTUnwrap(value["profiles"] as? [String: Any])
        let rows = try XCTUnwrap(value["cases"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 10)
        for row in rows {
            let name = try XCTUnwrap(row["profile"] as? String)
            let local = try decode(GamepadCustomization.self, XCTUnwrap(profiles[name]))
            let baseline = try (row["baseline"] as? String).map {
                try decode(GamepadCustomization.self, XCTUnwrap(profiles[$0]))
            }
            let scheme = try XCTUnwrap(ThumbleSkinColorScheme(rawValue: XCTUnwrap(row["scheme"] as? String)))
            let result = local.applying(skinPackage: package, orientation: .landscape,
                colorScheme: scheme, options: .preservingUserOverrides, overrideBaseline: baseline)
            let expected = try decode(GamepadCustomization.self, XCTUnwrap(row["expected"]))
            XCTAssertEqual(result, expected, "\(name) \(scheme)")
            XCTAssertEqual(result.elements.map(\.id), local.elements.map(\.id))
            XCTAssertEqual(result.elements.map(\.output), local.elements.map(\.output))
            XCTAssertEqual(result.elements.map(\.partOutputs), local.elements.map(\.partOutputs))
            XCTAssertFalse(result.assetLibrary.assets.isEmpty)
            XCTAssertFalse(result.styleLibrary.styles.isEmpty)
        }
    }

    func testLegacyProfileFixturesRetainOrientationBaselinesAndInput() throws {
        let value = try fixture("legacy-profiles")
        let rows = try XCTUnwrap(value["cases"] as? [[String: Any]])
        let packages = try XCTUnwrap(value["packages"] as? [String: [String: Any]])
        XCTAssertEqual(rows.count, 4)
        for row in rows {
            let original = try decode(GamepadConfigurationProfile.self, XCTUnwrap(row["input"]))
            let expected = try decode(GamepadConfigurationProfile.self, XCTUnwrap(row["expected"]))
            let skin = try package(XCTUnwrap(packages[XCTUnwrap(row["package"] as? String)]))
            var detached = original
            detached.detachSkin(resolving: skin,
                colorScheme: try XCTUnwrap(ThumbleSkinColorScheme(rawValue: XCTUnwrap(row["scheme"] as? String))))
            detached.updatedAt = expected.updatedAt
            XCTAssertEqual(detached, expected)
            XCTAssertEqual(detached.id, original.id)
            XCTAssertEqual(detached.outputMode, original.outputMode)
            for orientation in GamepadEditorDeviceOrientation.allCases {
                XCTAssertEqual(detached.customization(for: orientation).elements.map(\.output),
                    original.customization(for: orientation).elements.map(\.output))
            }
        }
    }

    func testTriggerBanksKeepIndependentAppearanceAndNativeWoWInput() throws {
        let value = try fixture("appearance")
        var skin = try package(value)
        let banks = try fixture("action-sets")
        let rows = try XCTUnwrap(banks["cases"] as? [[String: String]])
        let control = KeypadElementID(try XCTUnwrap(UUID(uuidString: XCTUnwrap(banks["controlID"] as? String))))
        skin.skin?.variants = try rows.map { row in
            ThumbleSkinVariant(id: "\(row["scheme"]!)-\(row["actionSet"]!)",
                colorScheme: try XCTUnwrap(ThumbleSkinColorScheme(rawValue: XCTUnwrap(row["scheme"]))),
                appearance: ThumbleSkinAppearance(buttonRules: [ThumbleSkinButtonRule(button: control,
                    appearance: ThumbleSkinControlAppearance(icon: .text(try XCTUnwrap(row["icon"]))))]),
                actionSet: try XCTUnwrap(ThumbleActionSet(rawValue: XCTUnwrap(row["actionSet"]))))
        }
        let profiles = try XCTUnwrap(value["profiles"] as? [String: Any])
        let local = try decode(GamepadCustomization.self, XCTUnwrap(profiles["wowForever"]))
        XCTAssertEqual(rows.count, 8)
        for row in rows {
            let scheme = try XCTUnwrap(ThumbleSkinColorScheme(rawValue: XCTUnwrap(row["scheme"])))
            let bank = try XCTUnwrap(ThumbleActionSet(rawValue: XCTUnwrap(row["actionSet"])))
            let result = local.applying(skinPackage: skin, orientation: .landscape, colorScheme: scheme,
                options: .preservingUserOverrides, actionSet: bank)
            XCTAssertEqual(result.buttonCustomization(for: control).icon, .text(try XCTUnwrap(row["icon"])))
            XCTAssertEqual(result.elements.map(\.id), local.elements.map(\.id))
            XCTAssertEqual(result.elements.map(\.output), local.elements.map(\.output))
            XCTAssertEqual(result.elements.map(\.partOutputs), local.elements.map(\.partOutputs))
        }
    }

    func testFrozenOfflineEditsPreserveTrustedHostAndBothOrientations() throws {
        struct Case: Decodable {
            let incomingProfiles: [GamepadConfigurationProfile]
            let pendingEdits: [PendingKeypadLayoutEdit]
            let serverID: String?
            let expectedProfiles: [GamepadConfigurationProfile]
            let expectedRemainingKeys: [String]
            let expectedUploadKeys: [String]
        }
        let rows = try XCTUnwrap(fixture("pending-edits")["cases"] as? [Any])
        XCTAssertEqual(rows.count, 6)
        for row in rows {
            let value = try decode(Case.self, row)
            let result = PendingKeypadLayoutReconciler.reconcile(incomingProfiles: value.incomingProfiles,
                pendingEdits: value.pendingEdits, authoritativeServerID: value.serverID)
            XCTAssertEqual(result.profiles, value.expectedProfiles)
            XCTAssertEqual(result.remainingEdits.map(\.id), value.expectedRemainingKeys)
            XCTAssertEqual(result.editsToUpload.map(\.id), value.expectedUploadKeys)
        }
    }

    /// Candidate renders stay outside the immutable fixtures for explicit visual review.
    @MainActor
    func testRenderFrozenAppearanceWithNativeControls() throws {
        let value = try fixture("appearance")
        let profiles = try XCTUnwrap(value["profiles"] as? [String: Any])
        let rows = try XCTUnwrap(value["cases"] as? [[String: Any]])
        for row in rows where row["profile"] as? String == "mixed" || row["profile"] as? String == "wowForever" {
            let name = try XCTUnwrap(row["profile"] as? String)
            let schemeName = try XCTUnwrap(row["scheme"] as? String)
            let expected = try decode(GamepadCustomization.self, XCTUnwrap(row["expected"]))
            let local = try decode(GamepadCustomization.self, XCTUnwrap(profiles[name]))
            let encoded = try JSONEncoder().encode(GamepadAppearanceSnapshot(expected))
            let snapshot = try JSONDecoder().decodeUnique(GamepadAppearanceSnapshot.self, from: encoded)
            let layout = snapshot.applying(to: local)
            XCTAssertEqual(layout, expected)
            for state in [GamepadControlPresentationState.normal, .pressed] {
                let data = try ThumbleNativeSkinPreviewRenderer.pngData(item: .init(
                    title: "\(name) \(schemeName)", customization: layout,
                    colorScheme: try XCTUnwrap(ThumbleSkinColorScheme(rawValue: schemeName)), state: state), scale: 1)
                XCTAssertGreaterThan(data.count, 100)
                let output = root.appendingPathComponent("build/FeatureRemovalBaseline/\(name)-\(schemeName)-\(state.rawValue).png")
                try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: output, options: .atomic)
            }
        }
    }
}
