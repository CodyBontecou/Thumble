import Foundation
import Testing

struct AndroidLayoutEditOracleTests {
    private func phoneRequest(_ fields: [String: Any]) throws -> ThumblePhoneLayoutBridgeRequest {
        try JSONDecoder().decodeUnique(ThumblePhoneLayoutBridgeRequest.self, from: JSONSerialization.data(withJSONObject: fields))
    }
    @Test func phoneLayoutReplacementPreservesMetadataAndOrientationAndNoopTimestamp() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("Host/fixtures/controller-templates/v1/productivityStarter.json"))) as? [String: Any])
        var profile = try #require(fixture["profile"] as? [String: Any])
        profile["futureProfile"] = "keep"
        var layout = try #require(profile["customization"] as? [String: Any])
        layout["deviceCanvas"] = ["frameID": "iphone-17-pro-portrait"]
        layout["colorSchemePreference"] = "dark"
        let fields: [String: Any] = ["schemaVersion": 1, "invocationID": UUID().uuidString, "phoneLayoutCommand": "replace",
            "profileID": try #require(profile["id"]), "profile": profile, "customization": layout, "nowMillis": 81]
        let result = try ThumblePhoneLayoutBridge.transform(phoneRequest(fields))
        #expect(result.changed && !result.recovered)
        let raw = try #require(result.profile)
        let encoded = try JSONEncoder().encode(raw)
        let typed = try JSONDecoder().decodeUnique(GamepadConfigurationProfile.self, from: encoded)
        #expect(typed.customization.deviceCanvas.editorDeviceFrame.orientation == .portrait)
        #expect(typed.hasCustomizationVariant(for: .landscape))
        #expect(typed.customization(for: .landscape).colorSchemePreference == .dark)
        let metadata = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(metadata["futureProfile"] as? String == "keep")
        #expect(metadata["name"] as? String == profile["name"] as? String)
        var repeated = fields
        repeated["profile"] = metadata
        repeated["customization"] = metadata["customization"]
        repeated["nowMillis"] = 82
        let noop = try ThumblePhoneLayoutBridge.transform(phoneRequest(repeated))
        #expect(!noop.changed && noop.profile == raw)
    }
    @Test func phoneLayoutRecoveryAndStrictCapabilities() throws {
        let id = UUID()
        let customization = try JSONSerialization.jsonObject(with: JSONEncoder().encode(GamepadCustomization.defaultValue))
        let fields: [String: Any] = ["schemaVersion": 1, "invocationID": UUID().uuidString, "phoneLayoutCommand": "replace",
            "profileID": id.uuidString, "customization": customization, "nowMillis": 42]
        let result = try ThumblePhoneLayoutBridge.transform(phoneRequest(fields))
        #expect(result.changed && result.recovered)
        let profile = try JSONDecoder().decodeUnique(GamepadConfigurationProfile.self, from: JSONEncoder().encode(#require(result.profile)))
        #expect(profile.id == id && profile.name == "Recovered Phone Layout")
        #expect(profile.hasCustomizationVariant(for: profile.customization.deviceCanvas.editorDeviceFrame.orientation))
        #expect(profile.launchTarget == nil && profile.skinReference == nil)
        let capabilities: [String: Any] = ["schemaVersion": 1, "invocationID": UUID().uuidString, "phoneLayoutCommand": "capabilities", "nowMillis": 0]
        #expect(try ThumblePhoneLayoutBridge.transform(phoneRequest(capabilities)).profile == nil)
        var unsafe = capabilities
        unsafe["path"] = "/tmp/not-an-input"
        #expect(throws: (any Error).self) { try phoneRequest(unsafe) }
        unsafe = capabilities
        unsafe["customization"] = customization
        #expect(throws: (any Error).self) { try ThumblePhoneLayoutBridge.transform(phoneRequest(unsafe)) }
    }
    @Test func phoneLayoutDehydratesOnlyMatchingInstalledPackageAssets() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("docs/skins/examples/indigo-pocket/dist/indigo-pocket-1.0.0.pocketpad"))
        let package = try ThumbleSkinPackageCodec.decode(data)
        let assetID = try #require(package.assets.keys.sorted().first)
        let assetData = try #require(package.assets[assetID])
        var profile = GamepadConfigurationProfile(id: UUID(), name: "Package", primaryCustomization: .defaultValue)
        profile.applySkin(package, colorScheme: .light)
        var layout = profile.customization
        let index = try #require(layout.assetLibrary.assets.firstIndex(where: { $0.id == assetID }))
        layout.assetLibrary.assets[index].data = assetData
        let localData = Data([1, 2, 3])
        layout.assetLibrary.assets.append(GamepadAsset(id: "phone-local", name: "Local", data: localData))
        let fields: [String: Any] = ["schemaVersion": 1, "invocationID": UUID().uuidString, "phoneLayoutCommand": "replace",
            "profileID": profile.id.uuidString, "profile": try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)),
            "customization": try JSONSerialization.jsonObject(with: JSONEncoder().encode(layout)), "packageData": data.base64EncodedString(), "nowMillis": 42]
        let result = try ThumblePhoneLayoutBridge.transform(phoneRequest(fields))
        let updated = try JSONDecoder().decodeUnique(GamepadConfigurationProfile.self, from: JSONEncoder().encode(#require(result.profile)))
        #expect(updated.skinReference == profile.skinReference)
        #expect(updated.customization.assetLibrary.assets.first(where: { $0.id == assetID })?.data == nil)
        #expect(updated.customization.assetLibrary.assets.first(where: { $0.id == "phone-local" })?.data == localData)
        var wrong = fields
        var metadata = try #require(wrong["profile"] as? [String: Any])
        metadata["skinReference"] = ["identifier": "com.example.wrong", "version": "1.0.0"]
        wrong["profile"] = metadata
        #expect(throws: (any Error).self) { try ThumblePhoneLayoutBridge.transform(phoneRequest(wrong)) }
    }
    private struct Oracle: Decodable, Equatable {
        let schemaVersion: Int
        let cases: [Case]
    }
    private struct Case: Decodable, Equatable {
        let name: String
        let incomingProfiles: [GamepadConfigurationProfile]
        let pendingEdits: [PendingKeypadLayoutEdit]
        let serverID: String?
        let expectedProfiles: [GamepadConfigurationProfile]
        let expectedRemainingKeys: [String]
        let expectedUploadKeys: [String]
    }
    @Test func nativeLayoutReconciliationFixtures() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try Data(contentsOf: root.appendingPathComponent("Host/fixtures/controller-templates/v1/productivityStarter.json"))
        let wrapper = try #require(JSONSerialization.jsonObject(with: fixture) as? [String: Any])
        let source = try JSONSerialization.data(withJSONObject: #require(wrapper["profile"]))
        var profile = try JSONDecoder().decodeUnique(GamepadConfigurationProfile.self, from: source)
        profile.updatedAt = 10

        var landscape = profile.customization(for: .landscape)
        landscape.setLabel("Offline Landscape", for: .preset(5))
        landscape.colorSchemePreference = .dark
        landscape.updatedAt = 42
        var portrait = landscape
        portrait.deviceCanvas = GamepadDeviceCanvas(frameID: "iphone-17-pro-portrait")
        portrait.setLabel("Offline Portrait", for: .preset(5))
        portrait.colorSchemePreference = .light
        portrait.updatedAt = 43
        let first = PendingKeypadLayoutEdit(profileID: profile.id, orientation: .landscape, customization: landscape, serverID: "mac", updatedAt: 42)
        let second = PendingKeypadLayoutEdit(profileID: profile.id, orientation: .portrait, customization: portrait, serverID: "mac", updatedAt: 43)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        func object<Value: Encodable>(_ value: Value) throws -> Any {
            try JSONSerialization.jsonObject(with: encoder.encode(value))
        }
        var cases: [[String: Any]] = []
        func record(_ name: String, incoming: [GamepadConfigurationProfile], pending: [PendingKeypadLayoutEdit], serverID: String?) throws {
            let result = PendingKeypadLayoutReconciler.reconcile(incomingProfiles: incoming, pendingEdits: pending, authoritativeServerID: serverID)
            cases.append([
                "name": name,
                "incomingProfiles": try object(incoming),
                "pendingEdits": try object(pending),
                "serverID": serverID as Any? ?? NSNull(),
                "expectedProfiles": try object(result.profiles),
                "expectedRemainingKeys": result.remainingEdits.map(\.id),
                "expectedUploadKeys": result.editsToUpload.map(\.id)
            ])
        }
        try record("offline-landscape", incoming: [profile], pending: [first], serverID: "mac")
        try record("different-mac", incoming: [profile], pending: [first], serverID: "other")
        try record("untrusted", incoming: [profile], pending: [first], serverID: nil)
        try record("recover-two-orientations", incoming: [], pending: [first, second], serverID: "mac")
        var acknowledged = profile
        acknowledged.setCustomization(landscape, for: .landscape)
        try record("acknowledged-landscape", incoming: [acknowledged], pending: [first], serverID: "mac")
        var laterAppearance = profile
        laterAppearance.setCustomization(portrait, for: .portrait)
        let interaction = PendingKeypadLayoutReconciler.reconcile(incomingProfiles: [laterAppearance], pendingEdits: [first, second], authoritativeServerID: "mac")
        #expect(interaction.remainingEdits.count == 2)
        #expect(interaction.profiles.first?.customization.colorSchemePreference == .light)
        try record("orientation-global-mode-interaction", incoming: [laterAppearance], pending: [first, second], serverID: "mac")
        #expect(cases.count == 6)

        let generated = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "cases": cases], options: [.sortedKeys])
        if let destination = ProcessInfo.processInfo.environment["THUMBLE_ANDROID_LAYOUT_FIXTURE_OUTPUT"] {
            let url = URL(fileURLWithPath: destination)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try generated.write(to: url, options: .atomic)
        } else {
            let recorded = try Data(contentsOf: root.appendingPathComponent("Host/fixtures/android-layout-edits/v1.json"))
            // Decode typed models so UUID dictionary serialization order cannot
            // hide meaningful model drift or make the fixture check flaky.
            #expect(try JSONDecoder().decodeUnique(Oracle.self, from: recorded) == JSONDecoder().decodeUnique(Oracle.self, from: generated))
        }
    }
}
