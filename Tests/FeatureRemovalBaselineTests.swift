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
        let rows = try XCTUnwrap(fixture("appearance")["cases"] as? [[String: Any]])
        for row in rows where row["profile"] as? String == "mixed" || row["profile"] as? String == "wowForever" {
            let name = try XCTUnwrap(row["profile"] as? String)
            let schemeName = try XCTUnwrap(row["scheme"] as? String)
            let layout = try decode(GamepadCustomization.self, XCTUnwrap(row["expected"]))
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
