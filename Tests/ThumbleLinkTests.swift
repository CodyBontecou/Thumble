import Foundation
import XCTest

final class ThumbleLinkTests: XCTestCase {
    private func fixture() throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ThumbleLink/warrior.txt"), encoding: .utf8)
    }

    private func emptyConfiguration() throws -> Data {
        let profile = GamepadConfigurationProfile(name: "Existing Setup", customization: GamepadCustomization())
        return try JSONEncoder().encode(ThumbleKeypadConfigurationExport(profiles: [profile], activeProfileID: profile.id, defaultProfileID: profile.id))
    }

    private func profile(_ plan: ThumbleLinkImport.Plan) throws -> GamepadConfigurationProfile {
        try XCTUnwrap(MacConfigurationBindings.decodeKeypadImport(data: plan.configurationData, sourceName: "Test").profiles.first)
    }

    private func editedSnapshot(_ change: (inout [String: Any]) -> Void) throws -> String {
        let json = try fixture().replacingOccurrences(of: ThumbleLinkSnapshot.prefix, with: "")
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        change(&value)
        return String(decoding: try JSONSerialization.data(withJSONObject: value, options: .sortedKeys), as: UTF8.self)
    }

    func testSnapshotBoundsVersionsAndDuplicateKeys() throws {
        let snapshot = try ThumbleLinkSnapshot.parse(fixture())
        XCTAssertEqual(snapshot.character.name, "Test Warrior")
        XCTAssertEqual(snapshot.actions.count, 5)
        XCTAssertEqual(snapshot.profileID, try ThumbleLinkSnapshot.parse(fixture()).profileID)
        XCTAssertThrowsError(try ThumbleLinkSnapshot.parse(String(repeating: "x", count: ThumbleLinkSnapshot.maximumBytes + 1)))
        XCTAssertThrowsError(try ThumbleLinkSnapshot.parse("{\"schema\":\"a\",\"schema\":\"b\"}"))
        for invalid in [try editedSnapshot { $0["version"] = 2 },
                        try editedSnapshot { $0["actions"] = [] },
                        try editedSnapshot { $0["client"] = ["flavor": "retail", "version": "12", "build": "1", "interface": 120000] },
                        try editedSnapshot { value in
                            let rows = value["actions"] as! [[String: Any]]
                            value["actions"] = [rows[0], rows[0]]
                        }] {
            XCTAssertThrowsError(try ThumbleLinkSnapshot.parse(invalid))
        }
    }

    func testWoWKeyVocabularyUsesPhysicalKeysAndModifierChords() throws {
        XCTAssertEqual(ThumbleLinkKeyBinding.resolve("CTRL-SHIFT-Q"), KeypadKeyboardBinding(keyCode: 12, modifiersRawValue: 10))
        XCTAssertEqual(ThumbleLinkKeyBinding.resolve("SHIFT--"), KeypadKeyboardBinding(keyCode: 27, modifiersRawValue: 2))
        XCTAssertEqual(ThumbleLinkKeyBinding.resolve("DELETE")?.keyCode, 117)
        XCTAssertEqual(ThumbleLinkKeyBinding.resolve("BACKSPACE")?.keyCode, 51)
        XCTAssertEqual(ThumbleLinkKeyBinding.resolve("NUMPAD1")?.keyCode, 83)
        XCTAssertEqual(ThumbleLinkKeyBinding.resolve("ALT-META-F12")?.modifiersRawValue, 5)
        for unsupported in ["BUTTON1", "MOUSEWHEELUP", "PAD1", "SHIFT-BUTTON4", "18", "123", "CTRL-CTRL-Q", "F01", "F21", "", "CMD-Q"] {
            XCTAssertNil(ThumbleLinkKeyBinding.resolve(unsupported), unsupported)
        }
    }

    func testCreateProfileSelectsSupportedAlternateAndSkipsUnboundOrOverridden() throws {
        let plan = try ThumbleLinkImport.prepare(text: fixture(), currentConfiguration: emptyConfiguration())
        let profile = try profile(plan)
        XCTAssertFalse(plan.isRefresh)
        XCTAssertEqual(profile.outputMode, .keyboard)
        XCTAssertEqual(profile.customization.elements.count, 3)
        XCTAssertEqual(profile.portraitCustomization?.elements.map(\.id), profile.customization.elements.map(\.id))
        let q = try XCTUnwrap(profile.customization.elements.first { $0.label == "Pummel" })
        XCTAssertEqual(q.output?.keyboard?.keyCode, 12)
        XCTAssertEqual(plan.rows.first { $0.label == "Pummel" }?.key, "Q")
        XCTAssertEqual(plan.rows.filter { $0.key == nil }.count, 2)
        XCTAssertEqual(q.defaultOutput, q.output)
        XCTAssertTrue(try ThumbleKeypadConfigurationExport.validateImportBoundary(plan.configurationData))
    }

    func testRefreshUpdatesBindingsAndNamesPreservingGeometryAndMetadata() throws {
        let first = try ThumbleLinkImport.prepare(text: fixture(), currentConfiguration: emptyConfiguration())
        var envelope = try MacConfigurationBindings.decodeKeypadImport(data: first.configurationData, sourceName: "Test")
        let id = first.snapshot.elementID(for: "ACTIONBUTTON1")
        let index = try XCTUnwrap(envelope.profiles[0].customization.elements.firstIndex { $0.id == id })
        envelope.profiles[0].customization.setPosition(CGPoint(x: 0.24, y: 0.54), for: .custom(id))
        envelope.profiles[0].name = "My Warrior"
        let newText = try editedSnapshot { value in
            var actions = value["actions"] as! [[String: Any]]
            actions[0]["keys"] = ["E"]
            actions[0]["label"] = "New Ability"
            value["actions"] = actions
        }
        let plan = try ThumbleLinkImport.prepare(text: newText, currentConfiguration: JSONEncoder().encode(envelope))
        let refreshed = try profile(plan)
        XCTAssertTrue(plan.isRefresh)
        XCTAssertEqual(plan.profileName, "My Warrior")
        XCTAssertEqual(try XCTUnwrap(refreshed.customization.elements[index].layout.centerX), 0.24, accuracy: 0.001)
        XCTAssertEqual(refreshed.customization.elements[index].label, "New Ability")
        XCTAssertEqual(refreshed.customization.elements[index].output?.keyboard?.keyCode, 14)
        XCTAssertEqual(refreshed.portraitCustomization?.elements.first { $0.id == id }?.output?.keyboard?.keyCode, 14)
        let raw = try MacConfigurationBindings.decodeKeypadImport(data: plan.configurationData, sourceName: "Test")
        guard case .object(let source) = raw.profileSources[refreshed.id] else { return XCTFail("missing raw metadata") }
        XCTAssertNotNil(source["thumbleLink"])
    }

    func testRefreshPreservesUserLabelsOutputsAndDeletedControls() throws {
        let first = try ThumbleLinkImport.prepare(text: fixture(), currentConfiguration: emptyConfiguration())
        var envelope = try MacConfigurationBindings.decodeKeypadImport(data: first.configurationData, sourceName: "Test")
        let id = first.snapshot.elementID(for: "ACTIONBUTTON1")
        let index = try XCTUnwrap(envelope.profiles[0].customization.elements.firstIndex { $0.id == id })
        envelope.profiles[0].customization.elements[index].label = "My button"
        let mirrorIndex = try XCTUnwrap(envelope.profiles[0].customization.customButtons.firstIndex { $0.id == id })
        envelope.profiles[0].customization.customButtons[mirrorIndex].label = "My button"
        let custom = KeypadElementOutputBinding(keyboard: KeypadKeyboardBinding(keyCode: 7))
        envelope.profiles[0].customization.elements[index].output = custom
        envelope.profileOutputBindings[envelope.profiles[0].id.uuidString]?[id.uuidString] = MacControlOutputBinding(shared: custom)
        envelope.profileKeyBindings[envelope.profiles[0].id.uuidString]?[id.uuidString] = MacControlOutputBinding(shared: custom).keyboard
        let deletedID = first.snapshot.elementID(for: "ACTIONBUTTON2")
        envelope.profiles[0].customization.removeCustomButton(id: deletedID)
        envelope.profiles[0].portraitCustomization?.removeCustomButton(id: deletedID)
        envelope.profileOutputBindings[envelope.profiles[0].id.uuidString]?.removeValue(forKey: deletedID.uuidString)
        envelope.profileKeyBindings[envelope.profiles[0].id.uuidString]?.removeValue(forKey: deletedID.uuidString)
        let refreshed = try profile(ThumbleLinkImport.prepare(text: fixture(), currentConfiguration: JSONEncoder().encode(envelope)))
        XCTAssertEqual(refreshed.customization.elements.first { $0.id == id }?.label, "My button")
        XCTAssertEqual(refreshed.customization.elements.first { $0.id == id }?.output, custom)
        XCTAssertNil(refreshed.customization.elements.first { $0.id == deletedID })
    }

    func testMissingBindingClearsPreviouslyImportedOutput() throws {
        let first = try ThumbleLinkImport.prepare(text: fixture(), currentConfiguration: emptyConfiguration())
        let newText = try editedSnapshot { value in
            var actions = value["actions"] as! [[String: Any]]
            actions[0]["keys"] = []
            value["actions"] = actions
        }
        let refreshed = try profile(ThumbleLinkImport.prepare(text: newText, currentConfiguration: first.configurationData))
        let element = try XCTUnwrap(refreshed.customization.elements.first { $0.id == first.snapshot.elementID(for: "ACTIONBUTTON1") })
        XCTAssertTrue(element.output?.isEmpty == true)
        XCTAssertTrue(element.defaultOutput?.isEmpty == true)
    }

    func testPreviouslyUnboundActionIsAddedWhenItGetsAKeyboardBinding() throws {
        let first = try ThumbleLinkImport.prepare(text: fixture(), currentConfiguration: emptyConfiguration())
        let text = try editedSnapshot { value in
            var actions = value["actions"] as! [[String: Any]]
            actions[3]["keys"] = ["R"]
            value["actions"] = actions
        }
        let refreshed = try profile(ThumbleLinkImport.prepare(text: text, currentConfiguration: first.configurationData))
        XCTAssertEqual(refreshed.customization.elements.count, 4)
        XCTAssertEqual(refreshed.customization.elements.first { $0.id == first.snapshot.elementID(for: "ACTIONBUTTON4") }?.output?.keyboard?.keyCode, 15)
    }

    func testReviewDetectsConcurrentEditsAndNameCollisions() throws {
        let base = try emptyConfiguration()
        let plan = try ThumbleLinkImport.prepare(text: fixture(), currentConfiguration: base)
        try plan.requireUnchangedConfiguration(base)
        var envelope = try MacConfigurationBindings.decodeKeypadImport(data: base, sourceName: "Test")
        envelope.profiles[0].name = "Changed"
        XCTAssertThrowsError(try plan.requireUnchangedConfiguration(JSONEncoder().encode(envelope)))
        XCTAssertThrowsError(try ThumbleLinkImport.prepare(text: fixture(), currentConfiguration: base, name: "Existing Setup"))
    }

    func testNoUsableBindingsDoesNotProduceAnImport() throws {
        let text = try editedSnapshot { value in
            var actions = value["actions"] as! [[String: Any]]
            for index in actions.indices { actions[index]["keys"] = ["BUTTON1"] }
            value["actions"] = actions
        }
        XCTAssertThrowsError(try ThumbleLinkImport.prepare(text: text, currentConfiguration: emptyConfiguration()))
    }
}
