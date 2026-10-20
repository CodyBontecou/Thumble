import CryptoKit
import Foundation
import XCTest

final class ProfileResourceCodecTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }

    private func makeProfile(payload: Data, launchMetadata: Bool = false) throws -> GamepadConfigurationProfile {
        let template = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
            root.appendingPathComponent("Host/fixtures/controller-templates/v1/arcadeStick.json"))) as? [String: Any])
        let source = try JSONDecoder().decodeUnique(GamepadConfigurationProfile.self,
            from: JSONSerialization.data(withJSONObject: XCTUnwrap(template["profile"])))
        var local = source.customization(for: .landscape)
        let element = try XCTUnwrap(local.elements.first)
        local.elements = [element]
        local.customButtons.removeAll { $0.id != element.id }
        local.buttonCustomizations = local.buttonCustomizations.filter { $0.key == element.inputID }
        local.labelOverrides = local.labelOverrides.filter { $0.key == element.inputID }
        local.designMetadata = nil
        local.updatedAt = 100
        local.assetLibrary = .init(assets: [
            .init(id: "one", name: "One", data: payload, role: .texture),
            .init(id: "alias", name: "Alias", data: payload, role: .texture)
        ])
        let image = GamepadFillStyle.image(.init(assetID: "one", data: payload))
        local.backgroundFillStyle = image
        local.artworkLayers = [.init(id: "art", fillStyle: image)]
        var control = local.buttonCustomization(for: element.inputID)
        control.fillStyle = image
        control.visualStyle = .init(normal: .init(fillStyle: image), pressed: .init(fillStyle: image),
            active: .init(fillStyle: image), disabled: .init(fillStyle: image))
        local.setButtonCustomization(control, for: element.inputID)
        var variants: [GamepadAppearanceBank.Variant] = []
        for scheme in ThumbleSkinColorScheme.allCases {
            for action in ThumbleActionSet.allCases {
                var value = local
                var appearance = value.buttonCustomization(for: element.inputID)
                appearance.icon = .text("\(scheme.rawValue)/\(action.rawValue)")
                value.setButtonCustomization(appearance, for: element.inputID)
                variants.append(.init(colorScheme: scheme, actionSet: action, appearance: .init(value)))
            }
        }
        let baseline = try XCTUnwrap(variants.first { $0.colorScheme == .light && $0.actionSet == .base })
        var profile = GamepadConfigurationProfile(id: UUID(uuidString: "ea000000-0000-0000-0000-000000000001")!,
            name: "Resource fixture", primaryCustomization: baseline.appearance.applying(to: local), updatedAt: 100)
        profile.appearanceBank = try .init(variants: variants)
        if launchMetadata {
            profile.launchTarget = .init(displayName: "Local fixture app", bookmarkData: Data("local-bookmark".utf8),
                iconPNGData: payload, attachedAt: 100)
        }
        return profile
    }

    private func encoded(_ profile: GamepadConfigurationProfile) throws -> (Data, [String: ThumbleBridgeJSONValue]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(profile)
        return (data, try JSONDecoder().decode([String: ThumbleBridgeJSONValue].self, from: data))
    }

    private func decoded(_ value: [String: ThumbleBridgeJSONValue]) throws -> GamepadConfigurationProfile {
        try JSONDecoder().decodeUnique(GamepadConfigurationProfile.self,
            from: JSONEncoder().encode(ThumbleBridgeJSONValue.object(value)))
    }

    func testSharedFixtureMatchesNativeEncodingAndExactExpansion() throws {
        let profile = try makeProfile(payload: Data("fixture-image".utf8), launchMetadata: true)
        let (_, fields) = try encoded(profile)
        let expanded = try expand(fields)
        let stripped = fields.filter { $0.key != "launchTarget" }
        let portable = try GamepadProfileResourceCodec.pruningUnusedResources(in: .object(stripped))
        let fixture = ThumbleBridgeJSONValue.object([
            "schemaVersion": .integer(1), "pooledProfile": .object(fields),
            "expandedProfile": expanded, "portableProfile": portable
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let output = root.appendingPathComponent("build/ProfileResources/fixture.json")
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(fixture).write(to: output, options: .atomic)
        let frozen = try JSONDecoder().decodeUnique(ThumbleBridgeJSONValue.self, from: Data(contentsOf:
            root.appendingPathComponent("Host/fixtures/profile-resources/v1/fixture.json")))
        XCTAssertEqual(fixture, frozen)
        XCTAssertEqual(try decoded(fields), profile)
        XCTAssertEqual(try JSONDecoder().decodeUnique(GamepadConfigurationProfile.self, from: encoder.encode(expanded)), profile)
    }

    private func expand(_ fields: [String: ThumbleBridgeJSONValue]) throws -> ThumbleBridgeJSONValue {
        guard case .object(let resources)? = fields["appearanceResources"] else { throw CocoaError(.coderInvalidValue) }
        func walk(_ node: ThumbleBridgeJSONValue) throws -> ThumbleBridgeJSONValue {
            switch node {
            case .object(let object):
                if object.count == 1, case .string(let digest)? = object["resourceSHA256"] {
                    return try XCTUnwrap(resources[digest])
                }
                return .object(try object.mapValues(walk))
            case .array(let values): return .array(try values.map(walk))
            default: return node
            }
        }
        return try walk(.object(fields.filter { !["appearanceResources", "appearanceResourceVersion"].contains($0.key) }))
    }

    func testLargePayloadOccursOnceAcrossCanonicalAliasesAndEightStates() throws {
        let payload = Data((0..<(1024 * 1024)).map { UInt8($0 % 251) })
        let profile = try makeProfile(payload: payload)
        let (data, fields) = try encoded(profile)
        guard case .object(let resources)? = fields["appearanceResources"] else { return XCTFail("Missing pool") }
        XCTAssertEqual(resources.count, 1)
        XCTAssertLessThan(data.count, payload.base64EncodedString().utf8.count + 100_000)
        let restored = try decoded(fields)
        XCTAssertEqual(restored, profile)
        let canonical = try XCTUnwrap(restored.customization.assetLibrary.assets.first?.data)
        for variant in try XCTUnwrap(restored.appearanceBank).variants {
            let resolved = variant.appearance.applying(to: restored.customization)
            let bytes = try XCTUnwrap(resolved.assetLibrary.assets.first?.data)
            XCTAssertEqual(bytes, payload)
            canonical.withUnsafeBytes { first in
                bytes.withUnsafeBytes { other in XCTAssertEqual(first.baseAddress, other.baseAddress, "Retain shared COW storage") }
            }
        }
    }

    func testCorruptMissingAndMalformedReferencesNeverBecomeEmptyImageData() throws {
        let profile = try makeProfile(payload: Data("integrity".utf8))
        let (_, original) = try encoded(profile)
        guard case .object(let pool)? = original["appearanceResources"], let digest = pool.keys.first else { return XCTFail("Missing pool") }
        var fields = original
        fields["appearanceResources"] = .object([digest: .string(Data("changed".utf8).base64EncodedString())])
        XCTAssertThrowsError(try decoded(fields))
        fields["appearanceResources"] = .object([:])
        XCTAssertThrowsError(try decoded(fields))
        fields = original
        fields["appearanceResourceVersion"] = .integer(99)
        XCTAssertThrowsError(try decoded(fields))
        fields = original
        fields["appearanceResourceVersion"] = nil
        XCTAssertThrowsError(try decoded(fields))
        fields = original
        fields["appearanceBank"] = .null
        XCTAssertThrowsError(try decoded(fields))
        fields = original
        guard case .object(var layout)? = fields["customization"],
              case .object(var library)? = layout["assetLibrary"],
              case .array(var assets)? = library["assets"], case .object(var asset) = assets[0] else {
            return XCTFail("Missing asset fixture")
        }
        asset["data"] = .object(["resourceSHA256": .string(digest), "extra": .bool(true)])
        assets[0] = .object(asset)
        library["assets"] = .array(assets)
        layout["assetLibrary"] = .object(library)
        fields["customization"] = .object(layout)
        XCTAssertThrowsError(try decoded(fields))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let numeric = String(decoding: try encoder.encode(ThumbleBridgeJSONValue.object(original)), as: UTF8.self)
            .replacingOccurrences(of: "\"appearanceResourceVersion\":1", with: "\"appearanceResourceVersion\":1.0")
        XCTAssertEqual(try JSONDecoder().decodeUnique(GamepadConfigurationProfile.self, from: Data(numeric.utf8)), profile)
    }

    func testPruningPortableCopyRemovesPrivateLaunchBytesButPreservesSharedArtwork() throws {
        let profile = try makeProfile(payload: Data("shared-artwork".utf8), launchMetadata: true)
        let (_, original) = try encoded(profile)
        var stripped = original
        stripped["launchTarget"] = nil
        let portable = try GamepadProfileResourceCodec.pruningUnusedResources(in: .object(stripped))
        guard case .object(let fields) = portable, case .object(let resources)? = fields["appearanceResources"] else { return XCTFail("Missing pool") }
        XCTAssertEqual(resources.count, 1)
        let expected = SHA256.hash(data: Data("shared-artwork".utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(Set(resources.keys), [expected])
        XCTAssertNil(try decoded(fields).launchTarget)
        XCTAssertNotNil(try decoded(original).launchTarget)
        let bookmark = SHA256.hash(data: Data("local-bookmark".utf8)).map { String(format: "%02x", $0) }.joined()
        let future = ThumbleBridgeJSONValue.object(["resource": .object(["resourceSHA256": .string(bookmark)])])
        stripped["futureMigrationMetadata"] = future
        guard case .object(let retained) = try GamepadProfileResourceCodec.pruningUnusedResources(in: .object(stripped)),
              case .object(let retainedResources)? = retained["appearanceResources"] else { return XCTFail("Missing future resource") }
        XCTAssertEqual(retained["futureMigrationMetadata"], future)
        XCTAssertEqual(retainedResources.count, 2)
    }

    func testLegacyProfilesDoNotAcquireResourceMarkersOrRequireAppearanceBanks() throws {
        let profile = GamepadConfigurationProfile(name: "Legacy", primaryCustomization: .defaultValue)
        let (_, fields) = try encoded(profile)
        XCTAssertNil(fields["appearanceResources"])
        XCTAssertNil(fields["appearanceResourceVersion"])
        XCTAssertEqual(try decoded(fields), profile)
    }

    func testUniqueBinaryBudgetFailsBeforePublishingAnyPartialResult() throws {
        var profile = try makeProfile(payload: Data([0]))
        for index in 1...9 {
            profile.customization.assetLibrary.assets.append(.init(id: "large-\(index)", name: "Large \(index)",
                data: Data(repeating: UInt8(index), count: 1024 * 1024)))
        }
        let before = profile
        XCTAssertThrowsError(try JSONEncoder().encode(profile)) {
            XCTAssertEqual($0 as? GamepadProfileResourceCodec.ResourceError, .tooLarge)
        }
        XCTAssertEqual(profile, before)
    }
}
