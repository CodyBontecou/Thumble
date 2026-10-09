import Foundation
import XCTest

final class ThumbleConfigurationBridgeTests: XCTestCase {
    private let profileID = UUID(uuidString: "00000000-0000-0000-0000-000000000201")!

    func testElementOnlyControlEditsAndRepairsPreserveIdentityOutputsAndMetadata() throws {
        let id = "B6FD297D-7508-4FF4-AFF7-97B3831F6AD0"
        let output: [String: Any] = ["keyboard": ["keyCode": 49, "modifiersRawValue": 0], "gamepadButtons": ["south"]]
        let raw: [String: Any] = [
            "id": profileID.uuidString, "name": "Element only",
            "customization": ["elements": [[
                "id": id, "label": "Owned", "kind": "button", "visualRole": "primary_action",
                "layout": ["centerX": 0.5, "centerY": 0.5, "widthScale": 0.2, "heightScale": 0.2],
                "output": output, "defaultOutput": output, "futureControl": ["kept": true]
            ]], "futureCustomization": ["kept": true]]
        ]
        let operations: [[String: Any]] = [
            ["type": "element.set", "profileID": profileID.uuidString, "variant": "primary", "elementID": id,
             "changes": ["label": "Edited", "centerX": 0.35, "widthScale": 1.3]],
            ["type": "customization.fix", "profileID": profileID.uuidString, "variant": "primary",
             "target": ["kind": "repair", "repair": "minimum-touch-target"], "canvas": ["source": "stored"], "includeLocked": false]
        ]
        for operation in operations {
            let response = try ThumbleConfigurationBridge.transform(decodeRequest(profileObjects: [raw], operation: operation))
            XCTAssertTrue(response.changed)
            let result = try object(from: response.document.profiles[0])
            let customization = try XCTUnwrap(result["customization"] as? [String: Any])
            let elements = try XCTUnwrap(customization["elements"] as? [[String: Any]])
            XCTAssertEqual(elements.count, 1)
            let element = try XCTUnwrap(elements.first)
            XCTAssertEqual(element["id"] as? String, id)
            XCTAssertEqual((element["futureControl"] as? [String: Bool])?["kept"], true)
            XCTAssertEqual((customization["futureCustomization"] as? [String: Bool])?["kept"], true)
            XCTAssertTrue(NSDictionary(dictionary: try XCTUnwrap(element["output"] as? [String: Any])).isEqual(to: output))
            if operation["type"] as? String == "element.set" {
                XCTAssertEqual(element["label"] as? String, "Edited")
                XCTAssertEqual((element["layout"] as? [String: Any])?["centerX"] as? Double, 0.35)
            } else {
                let decoded: GamepadConfigurationProfile = try decoded(response.document.profiles[0])
                let control = try XCTUnwrap(decoded.customization.resolvedControls(in: CGSize(width: 874, height: 402)).first { $0.elementID == UUID(uuidString: id) })
                XCTAssertGreaterThanOrEqual(control.hitFrame.width, 44)
                XCTAssertGreaterThanOrEqual(control.hitFrame.height, 44)
            }
        }
    }

    func testSpecializedLabelEditsPreserveExplicitShapesAndDecorationShadow() throws {
        for kind in [GamepadCustomControlKind.trigger, .text, .decoration] {
            for id in [UUID(uuidString: "B86010AB-59B6-450B-9200-58EF8F60DB9E")!, KeypadElementID.preset(5).uuid] {
                let element = KeypadElement(id: id, label: "Owned", kind: kind,
                    layout: GamepadButtonCustomization(centerX: 0.4, centerY: 0.6, shape: .circle, shadowStrength: 0.7))
                let profile = GamepadConfigurationProfile(id: profileID, name: "Specialized", customization: GamepadCustomization(elements: [element]))
                let response = try ThumbleConfigurationBridge.transform(decodeRequest(profileObjects: [try encodedObject(profile)], operation: [
                    "type": "element.set", "profileID": profileID.uuidString, "variant": "primary", "elementID": id.uuidString,
                    "changes": ["label": "Renamed"]
                ]))
                let result: GamepadConfigurationProfile = try decoded(response.document.profiles[0])
                let edited = try XCTUnwrap(result.customization.elements.first { $0.id == id })
                XCTAssertEqual(edited.label, "Renamed")
                XCTAssertEqual(edited.layout.shape, .circle)
                XCTAssertEqual(edited.layout.shadowStrength, kind == .text ? 0 : 0.7)
                XCTAssertEqual(edited.layout.centerX, 0.4)
                XCTAssertEqual(edited.layout.centerY, 0.6)
            }
        }
    }

    func testLabelEditsAndAppearanceResetsNeverBindUnboundJoystickDirections() throws {
        for id in ["E8197FBC-7085-4DEC-8257-EA2B5276BF71", "00000000-0000-0000-0000-000000000105"] {
            let raw: [String: Any] = ["id": profileID.uuidString, "name": "Unbound joystick", "customization": [
                "elements": [["id": id, "label": "Unbound", "kind": "joystick", "layout": ["centerX": 0.5, "centerY": 0.5],
                              "output": ["gamepadButtons": []], "partOutputs": []]]
            ]]
            for type in ["element.set", "element.reset"] {
                var operation: [String: Any] = ["type": type, "profileID": profileID.uuidString, "variant": "primary", "elementID": id]
                if type == "element.set" { operation["changes"] = ["label": "Renamed"] }
                let response = try ThumbleConfigurationBridge.transform(decodeRequest(profileObjects: [raw], operation: operation))
                let profile: GamepadConfigurationProfile = try decoded(response.document.profiles[0])
                let element = try XCTUnwrap(profile.customization.elements.first)
                XCTAssertEqual(element.id.uuidString, id)
                XCTAssertEqual(element.label, type == "element.set" ? "Renamed" : "Joystick")
                XCTAssertNil(element.joystickMapping)
                XCTAssertEqual(element.partOutputs.count, 0)
                XCTAssertNil(profile.customization.customButtons.first?.joystickMapping)
                XCTAssertEqual(profile.customization.identity(forElementID: element.id), .custom(element.id))
            }
        }
    }

    func testBlankCreationAndLastProfileReplacementNeverInstallOrphanBindings() throws {
        let source = GamepadConfigurationProfile(id: profileID, name: "Source", customization: .defaultValue)
        let newID = "6ED7B0C5-657D-45C7-A069-24E719C14773"
        let operations: [[String: Any]] = [
            ["type": "profile.create", "name": "Blank", "newProfileID": newID, "select": true, "makeDefault": false],
            ["type": "profile.delete", "profileID": profileID.uuidString, "replacementProfileID": newID]
        ]
        for operation in operations {
            let response = try ThumbleConfigurationBridge.transform(decodeRequest(
                profileObjects: [try encodedObject(source)], operation: operation
            ))
            let raw = try XCTUnwrap(response.document.profiles.last)
            let profile: GamepadConfigurationProfile = try decoded(raw)
            XCTAssertTrue(profile.customization.elements.isEmpty)
            XCTAssertEqual(response.document.keyBindings, .object([:]))
            XCTAssertEqual(response.document.outputBindings, .object([:]))
            let activeID = response.document.activeProfileID
            XCTAssertEqual(response.document.profileKeyBindings[activeID], .object([:]))
            XCTAssertEqual(response.document.profileOutputBindings[activeID], .object([:]))
        }
    }

    func testCustomizationFixUsesSharedRepairAndExactOrientationMirrors() throws {
        var landscape = GamepadCustomization.defaultValue
        landscape.deviceCanvas = GamepadDeviceCanvas(frameID: "iphone-17-pro-landscape")
        var portrait = landscape
        portrait.deviceCanvas = GamepadDeviceCanvas(frameID: "iphone-17-pro-portrait")
        var jump = portrait.buttonCustomization(for: .preset(5))
        jump.centerX = 0
        jump.centerY = 0
        portrait.setButtonCustomization(jump, for: .preset(5))
        var profile = GamepadConfigurationProfile(
            id: profileID,
            name: "Repair",
            primaryCustomization: landscape,
            updatedAt: 1
        )
        profile.setCustomizationVariant(portrait, for: .portrait)
        var rawProfile = try encodedObject(profile)
        rawProfile["futureProfile"] = ["kept": true]
        var rawPortrait = try XCTUnwrap(rawProfile["portraitCustomization"] as? [String: Any])
        rawPortrait["futureCustomization"] = ["kept": "yes"]
        rawProfile["portraitCustomization"] = rawPortrait

        let request = try decodeRequest(
            profileObjects: [rawProfile],
            operation: [
                "type": "customization.fix",
                "profileID": profileID.uuidString,
                "variant": "portrait",
                "target": ["kind": "repair", "repair": "move-inside-safe-area"],
                "canvas": ["source": "frame", "frameID": "iphone-17-pro-portrait"],
                "includeLocked": false
            ]
        )
        let response = try ThumbleConfigurationBridge.transform(request)
        XCTAssertEqual(response, try ThumbleConfigurationBridge.transform(request))
        XCTAssertTrue(response.changed)
        let rawResult = try object(from: response.document.profiles[0])
        XCTAssertEqual((rawResult["futureProfile"] as? [String: Bool])?["kept"], true)
        let rawResultPortrait = try XCTUnwrap(rawResult["portraitCustomization"] as? [String: Any])
        XCTAssertEqual((rawResultPortrait["futureCustomization"] as? [String: String])?["kept"], "yes")

        let result: GamepadConfigurationProfile = try decoded(response.document.profiles[0])
        let repairedPortrait = try XCTUnwrap(result.portraitCustomization)
        let repairedJump = try XCTUnwrap(
            repairedPortrait.resolvedControls(in: CGSize(width: 402, height: 874)).first { $0.id == .builtin(.preset(5)) }
        )
        XCTAssertGreaterThan(repairedJump.frame.minX, 1)
        XCTAssertGreaterThan(repairedJump.frame.minY, 1)
        XCTAssertEqual(result.customization, repairedPortrait)
        XCTAssertEqual(result.landscapeCustomization?.deviceCanvas.editorDeviceFrame.orientation, .landscape)
    }

    func testCustomizationFixStrictlyRejectsUnsafeCanvasAndUnknownFields() throws {
        let profile = GamepadConfigurationProfile(
            id: profileID,
            name: "Repair",
            primaryCustomization: .defaultValue,
            updatedAt: 1
        )
        let validBase: [String: Any] = [
            "type": "customization.fix",
            "profileID": profileID.uuidString,
            "variant": "primary",
            "target": ["kind": "all"],
            "canvas": ["source": "stored"],
            "includeLocked": false
        ]
        for mutation in [
            { (operation: inout [String: Any]) in operation["path"] = "/tmp/private" },
            { (operation: inout [String: Any]) in operation["canvas"] = ["source": "size", "width": 600] },
            { (operation: inout [String: Any]) in operation["canvas"] = ["source": "size", "width": 239, "height": 300] },
            { (operation: inout [String: Any]) in operation["target"] = ["kind": "repair", "repair": "minimum-size"] }
        ] {
            var operation = validBase
            mutation(&operation)
            XCTAssertThrowsError(try decodeRequest(
                profileObjects: [try encodedObject(profile)],
                operation: operation
            ))
        }

        let arbitraryFrame = try decodeRequest(
            profileObjects: [try encodedObject(profile)],
            operation: validBase.merging([
                "canvas": ["source": "frame", "frameID": "custom-600x300-landscape"]
            ]) { _, new in new }
        )
        XCTAssertThrowsError(try ThumbleConfigurationBridge.transform(arbitraryFrame)) { error in
            XCTAssertEqual(error as? ThumbleConfigurationBridgeError, .invalidDeviceFrame)
        }
    }

    func testLayerReorderPreservesUnknownDefaultDesignMetadataWhenMaterialized() throws {
        let profile = GamepadConfigurationProfile(
            id: profileID,
            name: "Layers",
            primaryCustomization: .defaultValue,
            updatedAt: 1
        )
        var rawProfile = try encodedObject(profile)
        var customization = try XCTUnwrap(rawProfile["customization"] as? [String: Any])
        customization["designMetadata"] = [
            "schemaVersion": 1,
            "layerOrder": [],
            "groups": [],
            "grid": [
                "showsGrid": false,
                "snapToGrid": false,
                "snapToObjects": true,
                "gridSize": 16,
                "snapTolerance": 6
            ],
            "guides": [],
            "tags": [],
            "futureNested": ["futurePath": "preserve-me", "value": 41]
        ]
        rawProfile["customization"] = customization
        let request = try decodeRequest(
            profileObjects: [rawProfile],
            operation: [
                "type": "layer.front",
                "profileID": profileID.uuidString,
                "variant": "primary",
                "elementID": KeypadElementID.preset(5).rawValue
            ]
        )
        let response = try ThumbleConfigurationBridge.transform(request)
        let result = try object(from: response.document.profiles[0])
        let resultCustomization = try XCTUnwrap(result["customization"] as? [String: Any])
        let metadata = try XCTUnwrap(resultCustomization["designMetadata"] as? [String: Any])
        let future = try XCTUnwrap(metadata["futureNested"] as? [String: Any])
        XCTAssertEqual(future["futurePath"] as? String, "preserve-me")
        XCTAssertEqual(future["value"] as? Int, 41)
        let order = try XCTUnwrap(metadata["layerOrder"] as? [[String: Any]])
        XCTAssertEqual(order.first?["system"] as? String, "top_bar_activation")
        XCTAssertEqual(order.last?["button"] as? String, KeypadElementID.preset(5).rawValue)
    }

    func testThemeApplyPreservesUnknownProfileAndCustomizationFields() throws {
        var baseCustomization = GamepadCustomization.defaultValue
        var jumpLayout = baseCustomization.buttonCustomization(for: .preset(5))
        jumpLayout.centerX = 0.6
        baseCustomization.setButtonCustomization(jumpLayout, for: .preset(5))
        var rawProfile = try encodedObject(GamepadConfigurationProfile(
            id: profileID,
            name: "Bridge",
            primaryCustomization: baseCustomization,
            updatedAt: 1
        ))
        rawProfile["futureProfile"] = ["kept": true]
        var customization = try XCTUnwrap(rawProfile["customization"] as? [String: Any])
        customization["futureCustomization"] = ["kept": "yes"]
        var buttonCustomizations = try XCTUnwrap(customization["buttonCustomizations"] as? [Any])
        let valueIndex = try XCTUnwrap(buttonCustomizations.firstIndex { $0 is [String: Any] })
        var buttonValue = try XCTUnwrap(buttonCustomizations[valueIndex] as? [String: Any])
        buttonValue["futureButtonField"] = "preserved"
        buttonCustomizations[valueIndex] = buttonValue
        customization["buttonCustomizations"] = buttonCustomizations
        rawProfile["customization"] = customization

        let request = try decodeRequest(
            profileObjects: [rawProfile],
            operation: [
                "type": "theme.apply",
                "profileID": profileID.uuidString.lowercased(),
                "variant": "primary",
                "preset": "cavern-glow"
            ]
        )
        let response = try ThumbleConfigurationBridge.transform(request)
        XCTAssertEqual(response, try ThumbleConfigurationBridge.transform(request))
        XCTAssertTrue(response.changed)
        XCTAssertEqual(response.changedPaths, ["/profiles/00000000-0000-0000-0000-000000000201"])
        let result = try object(from: response.document.profiles[0])
        XCTAssertEqual((result["futureProfile"] as? [String: Bool])?["kept"], true)
        let resultCustomization = try XCTUnwrap(result["customization"] as? [String: Any])
        XCTAssertEqual((resultCustomization["futureCustomization"] as? [String: String])?["kept"], "yes")
        let resultButtons = try XCTUnwrap(resultCustomization["buttonCustomizations"] as? [Any])
        XCTAssertTrue(resultButtons.contains {
            ($0 as? [String: Any])?["futureButtonField"] as? String == "preserved"
        })
    }

    func testDuplicateUsesCallerUUIDAndClonesProfileBindingMaps() throws {
        let rawProfile = try encodedObject(GamepadConfigurationProfile(
            id: profileID,
            name: "Original",
            primaryCustomization: .defaultValue,
            updatedAt: 1
        ))
        let newID = "00000000-0000-0000-0000-000000000202"
        var envelope = try requestEnvelope(
            profileObjects: [rawProfile],
            operation: [
                "type": "profile.duplicate",
                "profileID": profileID.uuidString,
                "newProfileID": newID,
                "name": "Copy"
            ]
        )
        var document = try XCTUnwrap(envelope["document"] as? [String: Any])
        document["profileKeyBindings"] = [profileID.uuidString.lowercased(): [KeypadElementID.preset(5).rawValue: ["keyCode": 49, "modifiers": 0]]]
        document["profileOutputBindings"] = [profileID.uuidString.lowercased(): [KeypadElementID.preset(5).rawValue: ["gamepadButtons": ["south"]]]]
        envelope["document"] = document
        let data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        let request = try JSONDecoder().decode(ThumbleConfigurationBridgeRequest.self, from: data)
        let response = try ThumbleConfigurationBridge.transform(request)

        XCTAssertEqual(response.document.profiles.count, 2)
        let duplicate = try object(from: response.document.profiles[1])
        XCTAssertEqual(duplicate["id"] as? String, newID)
        XCTAssertEqual(duplicate["name"] as? String, "Copy")
        XCTAssertNotNil(response.document.profileKeyBindings[newID])
        XCTAssertNotNil(response.document.profileOutputBindings[newID])
    }

    func testDeletingOnlyProfileRequiresCallerReplacementUUID() throws {
        let rawProfile = try encodedObject(GamepadConfigurationProfile(
            id: profileID,
            name: "Only",
            primaryCustomization: .defaultValue,
            updatedAt: 1
        ))
        let missingReplacement = try decodeRequest(
            profileObjects: [rawProfile],
            operation: ["type": "profile.delete", "profileID": profileID.uuidString]
        )
        XCTAssertThrowsError(try ThumbleConfigurationBridge.transform(missingReplacement)) { error in
            XCTAssertEqual(error as? ThumbleConfigurationBridgeError, .replacementProfileRequired)
        }

        let replacementID = "00000000-0000-0000-0000-00000000cafe"
        let replacing = try decodeRequest(
            profileObjects: [rawProfile],
            operation: [
                "type": "profile.delete",
                "profileID": profileID.uuidString,
                "replacementProfileID": replacementID
            ]
        )
        let response = try ThumbleConfigurationBridge.transform(replacing)
        XCTAssertEqual(response.document.activeProfileID, replacementID)
        XCTAssertEqual(response.document.defaultProfileID, replacementID)
        let replacement = try object(from: response.document.profiles[0])
        XCTAssertEqual(replacement["id"] as? String, replacementID)
        XCTAssertEqual(replacement["name"] as? String, "Setup 1")
        XCTAssertEqual(Array(response.document.profileKeyBindings.keys), [replacementID])
        XCTAssertEqual(Array(response.document.profileOutputBindings.keys), [replacementID])
    }

    func testOutputOnlyElementSetPreservesPrimaryBindingWhenEditingJoystickPart() throws {
        let id = UUID().uuidString
        let primary: [String: Any] = ["keyboard": ["keyCode": 40, "modifiersRawValue": 0], "gamepadButtons": []]
        let down: [String: Any] = ["keyboard": ["keyCode": 1, "modifiersRawValue": 0], "gamepadButtons": []]
        let raw: [String: Any] = ["id": profileID.uuidString, "name": "Part output", "customization": ["elements": [[
            "id": id, "kind": "joystick", "label": "Aim", "layout": ["centerX": 0.3, "centerY": 0.5],
            "output": primary, "defaultOutput": primary, "partOutputs": ["joystick_down", down], "future": true
        ]]]]
        let response = try ThumbleConfigurationBridge.transform(decodeRequest(profileObjects: [raw], operation: [
            "type": "element.set", "profileID": profileID.uuidString, "variant": "primary", "elementID": id,
            "changes": ["output": ["part": "joystick_up", "keyboardEdit": ["action": "set", "sequence": [["key": "Space", "modifiers": []]]], "gamepadEdit": ["action": "keep"]]]
        ]))
        let result = try object(from: response.document.profiles[0])
        let customization = try XCTUnwrap(result["customization"] as? [String: Any])
        let elements = try XCTUnwrap(customization["elements"] as? [[String: Any]])
        let owner = try XCTUnwrap(elements.first)
        XCTAssertTrue(NSDictionary(dictionary: try XCTUnwrap(owner["output"] as? [String: Any])).isEqual(to: primary))
        let parts = try XCTUnwrap(owner["partOutputs"] as? [Any])
        XCTAssertEqual(parts.count, 4)
        let upIndex = try XCTUnwrap(parts.firstIndex { ($0 as? String) == "joystick_up" })
        let up = try XCTUnwrap(parts[upIndex + 1] as? [String: Any])
        XCTAssertEqual((up["keyboard"] as? [String: Any])?["keyCode"] as? Int, 49)
        let downIndex = try XCTUnwrap(parts.firstIndex { ($0 as? String) == "joystick_down" })
        XCTAssertTrue(NSDictionary(dictionary: try XCTUnwrap(parts[downIndex + 1] as? [String: Any])).isEqual(to: down))
        var restored = owner; restored["partOutputs"] = ["joystick_down", down]
        let original = try XCTUnwrap(((raw["customization"] as? [String: Any])?["elements"] as? [[String: Any]])?.first)
        XCTAssertTrue(NSDictionary(dictionary: restored).isEqual(to: original))
    }

    func testRawFieldPatchClassificationRetainsExplicitFalseChanges() throws {
        for field in ["isHidden", "isLocationLocked", "showsIntegratedLabel"] {
            let data = try JSONSerialization.data(withJSONObject: ["presentation": ["legend": "Q"], field: false])
            let changes = try JSONDecoder().decode(ThumbleBridgeElementChanges.self, from: data)
            XCTAssertFalse(changes.isPresentationOnly, field)
        }
    }

    func testOutputOnlyElementSetPreservesRawLayoutAndIndependentPortrait() throws {
        let targetID = KeypadElementID.preset(6).rawValue
        let siblingID = UUID().uuidString
        let output: [String: Any] = ["keyboard": ["keyCode": 40, "modifiersRawValue": 0], "gamepadButtons": []]
        let customization: [String: Any] = ["elements": [
            ["id": siblingID, "kind": "button", "label": "First", "layout": ["centerX": 0.3, "centerY": 0.5], "future": true],
            ["id": targetID, "kind": "button", "label": "Ability", "layout": ["centerX": 0.7, "centerY": 0.5, "shadowStrength": 1.0],
             "output": output, "defaultOutput": output, "partOutputs": [], "future": "kept"]
        ], "future": "layout"]
        for mirror in [false, true] {
            var raw: [String: Any] = ["id": profileID.uuidString, "name": "Output order", "customization": customization,
                "portraitCustomization": customization, "future": "profile"]
            if mirror { raw["landscapeCustomization"] = customization }
            let response = try ThumbleConfigurationBridge.transform(decodeRequest(profileObjects: [raw], operation: [
                "type": "element.set", "profileID": profileID.uuidString, "variant": "primary", "elementID": targetID,
                "changes": ["output": ["part": "primary", "keyboardEdit": ["action": "set", "sequence": [["key": "Space", "modifiers": []]]], "gamepadEdit": ["action": "keep"]]]
            ]))
            XCTAssertTrue(response.changed)
            let result = try object(from: response.document.profiles[0])
            XCTAssertTrue(NSDictionary(dictionary: try XCTUnwrap(result["portraitCustomization"] as? [String: Any])).isEqual(to: customization))
            if !mirror { XCTAssertNil(result["landscapeCustomization"]) }
            for field in mirror ? ["customization", "landscapeCustomization"] : ["customization"] {
                var changed = try XCTUnwrap(result[field] as? [String: Any])
                var elements = try XCTUnwrap(changed["elements"] as? [[String: Any]])
                XCTAssertEqual(elements.compactMap { $0["id"] as? String }, [siblingID, targetID])
                let nextOutput = try XCTUnwrap(elements[1]["output"] as? [String: Any])
                XCTAssertEqual((nextOutput["keyboard"] as? [String: Any])?["keyCode"] as? Int, 49)
                elements[1]["output"] = output; changed["elements"] = elements
                XCTAssertTrue(NSDictionary(dictionary: changed).isEqual(to: customization))
            }
        }
    }

    func testBindingSetPreservesRawControlOrderAndAuthoredLayoutAcrossVariants() throws {
        let customID = "B6FD297D-7508-4FF4-AFF7-97B3831F6AD0"
        let buttonID = KeypadElementID.preset(6).rawValue
        let output: [String: Any] = ["keyboard": ["keyCode": 40, "modifiersRawValue": 0], "gamepadButtons": []]
        let elements: [[String: Any]] = [
            ["id": customID, "kind": "button", "label": "Custom first",
             "layout": ["centerX": 0.321, "centerY": 0.5, "fillColor": ["red": 0.2, "green": 0.3, "blue": 0.4, "alpha": 1]],
             "output": output, "defaultOutput": output, "future": "custom"],
            ["id": buttonID, "kind": "button", "label": "Ability",
             "layout": ["centerX": 0.75, "centerY": 0.5, "shadowStrength": 0],
             "output": output, "defaultOutput": output, "future": "ability"],
            ["id": "00000000-0000-0000-0000-000000000120", "kind": "trigger", "label": "Unbound",
             "layout": ["centerX": 0.5, "centerY": 0.5], "partOutputs": []]
        ]
        let customization: [String: Any] = ["elements": elements, "future": "layout"]
        let raw: [String: Any] = ["id": profileID.uuidString, "name": "Raw order",
            "customization": customization, "portraitCustomization": customization, "future": "profile"]
        let response = try ThumbleConfigurationBridge.transform(decodeRequest(profileObjects: [raw], operation: [
            "type": "binding.set", "profileID": profileID.uuidString, "button": buttonID,
            "sequence": [["key": "Space", "modifiers": []]]
        ]))
        XCTAssertTrue(response.changed)
        let result = try object(from: response.document.profiles[0])
        XCTAssertNil(result["landscapeCustomization"])
        for field in ["customization", "portraitCustomization"] {
            var edited = try XCTUnwrap(result[field] as? [String: Any])
            var editedElements = try XCTUnwrap(edited["elements"] as? [[String: Any]])
            XCTAssertEqual(editedElements.compactMap { $0["id"] as? String }, [customID, buttonID, "00000000-0000-0000-0000-000000000120"])
            let changedOutput = try XCTUnwrap(editedElements[1]["output"] as? [String: Any])
            XCTAssertEqual((changedOutput["keyboard"] as? [String: Any])?["keyCode"] as? Int, 49)
            XCTAssertNil(editedElements[2]["output"])
            for index in editedElements.indices { editedElements[index]["output"] = elements[index]["output"] }
            edited["elements"] = editedElements
            XCTAssertTrue(NSDictionary(dictionary: edited).isEqual(to: customization), field)
        }
    }

    func testBindingResetUsesSharedCLITransformAndPreservesUnknownFields() throws {
        let futureID = UUID(uuidString: "78AEF38D-AC53-4766-9F41-8633D9533455")!
        var customization = GamepadCustomization.defaultValue
        customization.elements.append(KeypadElement(id: futureID, label: "Extra", output: KeypadElementOutputBinding(keyboard: KeypadKeyboardBinding(keyCode: 1))))
        try customization.setStandaloneElementOutput(KeypadElementOutputBinding(keyboard: KeypadKeyboardBinding(keyCode: MacVirtualKey.q), gamepadButtons: [.east]), for: .builtin(.preset(6)), part: .primary)
        let profile = GamepadConfigurationProfile(
            id: profileID,
            name: "Bindings",
            primaryCustomization: customization,
            outputMode: .keyboard,
            updatedAt: 1
        )
        let keys = profile.initialMacOutputBindings.keyboardBindings
        let outputs = profile.initialMacOutputBindings
        var envelope = try requestEnvelope(
            profileObjects: [try encodedObject(profile)],
            operation: [
                "type": "binding.reset",
                "profileID": profileID.uuidString,
                "button": KeypadElementID.preset(6).rawValue
            ]
        )
        var document = try XCTUnwrap(envelope["document"] as? [String: Any])
        var rawKeys = try XCTUnwrap(try jsonObject(
            MacConfigurationBindings.rawKeyBindings(keys)
        ) as? [String: Any])
        var attack = try XCTUnwrap(rawKeys[KeypadElementID.preset(6).rawValue] as? [String: Any])
        attack["futureBindingField"] = ["kept": true]
        rawKeys[KeypadElementID.preset(6).rawValue] = attack
        rawKeys[futureID.uuidString] = ["keyCode": 1, "modifiers": 0, "future": "key-map"]
        var rawOutputs = try XCTUnwrap(try jsonObject(
            MacConfigurationBindings.rawOutputs(outputs)
        ) as? [String: Any])
        rawOutputs[futureID.uuidString] = [
            "keyboard": ["keyCode": 1, "modifiers": 0],
            "gamepadButtons": [],
            "future": "output-map"
        ]
        document["keyBindings"] = rawKeys
        document["outputBindings"] = rawOutputs
        document["profileKeyBindings"] = [profileID.uuidString.lowercased(): rawKeys]
        document["profileOutputBindings"] = [profileID.uuidString.lowercased(): rawOutputs]
        envelope["document"] = document
        let request = try JSONDecoder().decode(
            ThumbleConfigurationBridgeRequest.self,
            from: JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        )
        let response = try ThumbleConfigurationBridge.transform(request)

        let resultKeys = try object(from: XCTUnwrap(
            response.document.profileKeyBindings[profileID.uuidString.lowercased()]
        ))
        let resultAttack = try XCTUnwrap(resultKeys[KeypadElementID.preset(6).rawValue] as? [String: Any])
        XCTAssertEqual((resultAttack["futureBindingField"] as? [String: Bool])?["kept"], true)
        XCTAssertEqual(
            (resultKeys[futureID.uuidString] as? [String: Any])?["future"] as? String,
            "key-map"
        )
        let resultOutputs = try object(from: XCTUnwrap(
            response.document.profileOutputBindings[profileID.uuidString.lowercased()]
        ))
        XCTAssertEqual(
            (resultOutputs[futureID.uuidString] as? [String: Any])?["future"] as? String,
            "output-map"
        )
        let decodedKeys: [String: MacKeyBinding] = try decoded(
            XCTUnwrap(response.document.profileKeyBindings[profileID.uuidString.lowercased()])
        )
        XCTAssertEqual(decodedKeys[KeypadElementID.preset(6).rawValue], profile.recommendedMacOutputBindings[.preset(6)]?.keyboard)
        XCTAssertEqual(
            response.document.keyBindings,
            response.document.profileKeyBindings[profileID.uuidString.lowercased()]
        )
    }

    func testBindingClearAndOutputModesMatchStandaloneSemantics() throws {
        let profile = GamepadConfigurationProfile(
            id: profileID,
            name: "Outputs",
            primaryCustomization: .defaultValue,
            outputMode: .keyboard,
            updatedAt: 1
        )
        let keys = profile.initialMacOutputBindings.keyboardBindings
        let outputs = profile.initialMacOutputBindings
        let clear = try requestWithBindings(
            profile: profile,
            keys: keys,
            outputs: outputs,
            operation: [
                "type": "binding.clear",
                "profileID": profileID.uuidString,
                "button": KeypadElementID.preset(6).rawValue
            ]
        )
        let cleared = try ThumbleConfigurationBridge.transform(clear)
        let clearedKeys: [String: MacKeyBinding] = try decoded(
            XCTUnwrap(cleared.document.profileKeyBindings[profileID.uuidString.lowercased()])
        )
        let clearedOutputs: [String: MacControlOutputBinding] = try decoded(
            XCTUnwrap(cleared.document.profileOutputBindings[profileID.uuidString.lowercased()])
        )
        XCTAssertNil(clearedKeys[KeypadElementID.preset(6).rawValue])
        XCTAssertNil(clearedOutputs[KeypadElementID.preset(6).rawValue]?.keyboard)
        XCTAssertEqual(clearedOutputs[KeypadElementID.preset(6).rawValue]?.gamepadButtons, outputs[.preset(6)]?.gamepadButtons)

        let controller = try requestWithBindings(
            profile: profile,
            keys: keys,
            outputs: outputs,
            operation: [
                "type": "output.mode",
                "profileID": profileID.uuidString,
                "mode": "controller"
            ]
        )
        let controllerResponse = try ThumbleConfigurationBridge.transform(controller)
        let controllerProfile: GamepadConfigurationProfile = try decoded(controllerResponse.document.profiles[0])
        let controllerOutputs: [String: MacControlOutputBinding] = try decoded(
            XCTUnwrap(controllerResponse.document.profileOutputBindings[profileID.uuidString.lowercased()])
        )
        XCTAssertEqual(controllerProfile.outputMode, .controller)
        XCTAssertEqual(controllerOutputs, MacConfigurationBindings.rawOutputs(outputs))
        XCTAssertEqual(controllerOutputs[KeypadElementID.preset(5).rawValue]?.filtered(for: .controller).gamepadButtons, [.south])
        XCTAssertEqual(
            controllerResponse,
            try ThumbleConfigurationBridge.transform(controller)
        )
    }

    func testOutputSetPreservesKeyboardForGamepadOnlyEdit() throws {
        let profile = GamepadConfigurationProfile(
            id: profileID,
            name: "Mixed Output",
            primaryCustomization: .defaultValue,
            outputMode: .keyboard,
            updatedAt: 1
        )
        let keys = DefaultKeypadKeyMap.defaultBindings
        let request = try requestWithBindings(
            profile: profile,
            keys: keys,
            outputs: MacConfigurationBindings.keyboardOutputs(from: keys),
            operation: [
                "type": "output.set",
                "profileID": profileID.uuidString,
                "button": KeypadElementID.preset(5).rawValue,
                "keyboardEdit": ["action": "keep"],
                "gamepadEdit": ["action": "set", "button": "south"]
            ]
        )
        let response = try ThumbleConfigurationBridge.transform(request)
        let resultProfile: GamepadConfigurationProfile = try decoded(response.document.profiles[0])
        let resultKeys: [String: MacKeyBinding] = try decoded(
            XCTUnwrap(response.document.profileKeyBindings[profileID.uuidString.lowercased()])
        )
        let resultOutputs: [String: MacControlOutputBinding] = try decoded(
            XCTUnwrap(response.document.profileOutputBindings[profileID.uuidString.lowercased()])
        )
        XCTAssertEqual(resultProfile.outputMode, .custom)
        XCTAssertEqual(resultOutputs[KeypadElementID.preset(5).rawValue]?.keyboard, keys[.preset(5)])
        XCTAssertEqual(resultOutputs[KeypadElementID.preset(5).rawValue]?.gamepadButtons, [.south])
        XCTAssertEqual(resultKeys[KeypadElementID.preset(5).rawValue], keys[.preset(5)])
        XCTAssertEqual(MacConfigurationBindings.decodedOutputs(resultOutputs), resultProfile.configuredMacOutputBindings)

        let sequenceRequest = try requestWithBindings(
            profile: profile,
            keys: keys,
            outputs: MacConfigurationBindings.keyboardOutputs(from: keys),
            operation: [
                "type": "output.set",
                "profileID": profileID.uuidString,
                "button": KeypadElementID.preset(8).rawValue,
                "keyboardEdit": [
                    "action": "set",
                    "sequence": [
                        ["key": "B", "modifiers": ["control"]],
                        ["key": "H", "modifiers": []]
                    ]
                ],
                "gamepadEdit": ["action": "clear"]
            ]
        )
        let sequenceResponse = try ThumbleConfigurationBridge.transform(sequenceRequest)
        let sequenceOutputs: [String: MacControlOutputBinding] = try decoded(
            XCTUnwrap(sequenceResponse.document.profileOutputBindings[profileID.uuidString.lowercased()])
        )
        XCTAssertEqual(sequenceOutputs[KeypadElementID.preset(8).rawValue]?.keyboard?.strokes.count, 2)
        XCTAssertTrue(sequenceOutputs[KeypadElementID.preset(8).rawValue]?.gamepadButtons.isEmpty == true)

        let invalid = try requestWithBindings(
            profile: profile,
            keys: keys,
            outputs: MacConfigurationBindings.keyboardOutputs(from: keys),
            operation: [
                "type": "output.set",
                "profileID": profileID.uuidString,
                "button": KeypadElementID.preset(5).rawValue,
                "keyboardEdit": ["action": "keep"],
                "gamepadEdit": ["action": "keep"]
            ]
        )
        XCTAssertThrowsError(try ThumbleConfigurationBridge.transform(invalid)) { error in
            XCTAssertEqual(error as? ThumbleConfigurationBridgeError, .invalidOutputEdit)
        }
    }

    func testOutputResetAllRestoresRecommendedKeyboardMode() throws {
        let profile = GamepadConfigurationProfile(
            id: profileID,
            name: "Reset",
            primaryCustomization: .defaultValue,
            outputMode: .controller,
            updatedAt: 1
        )
        let keys = DefaultKeypadKeyMap.defaultBindings
        let request = try requestWithBindings(
            profile: profile,
            keys: keys,
            outputs: profile.initialMacOutputBindings,
            operation: [
                "type": "output.reset-all",
                "profileID": profileID.uuidString
            ]
        )
        let response = try ThumbleConfigurationBridge.transform(request)
        let resultProfile: GamepadConfigurationProfile = try decoded(response.document.profiles[0])
        let resultOutputs: [String: MacControlOutputBinding] = try decoded(
            XCTUnwrap(response.document.profileOutputBindings[profileID.uuidString.lowercased()])
        )
        XCTAssertEqual(resultProfile.outputMode, .keyboard)
        XCTAssertEqual(
            resultOutputs,
            MacConfigurationBindings.rawOutputs(DefaultMacControlOutputMap.defaultBindings)
        )
    }

    func testProfileSelectSynchronizesGlobalBindingMirrors() throws {
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000202")!
        let first = try encodedObject(GamepadConfigurationProfile(
            id: profileID,
            name: "First",
            primaryCustomization: .defaultValue,
            updatedAt: 1
        ))
        let second = try encodedObject(GamepadConfigurationProfile(
            id: secondID,
            name: "Second",
            primaryCustomization: .defaultValue,
            updatedAt: 1
        ))
        var envelope = try requestEnvelope(
            profileObjects: [first, second],
            operation: ["type": "profile.select", "profileID": secondID.uuidString.lowercased()]
        )
        var document = try XCTUnwrap(envelope["document"] as? [String: Any])
        document["profileKeyBindings"] = [secondID.uuidString.lowercased(): [KeypadElementID.preset(5).rawValue: ["keyCode": 49, "modifiers": 0]]]
        document["profileOutputBindings"] = [secondID.uuidString.lowercased(): [KeypadElementID.preset(5).rawValue: ["gamepadButtons": ["south"]]]]
        envelope["document"] = document
        let request = try JSONDecoder().decode(
            ThumbleConfigurationBridgeRequest.self,
            from: JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        )
        let response = try ThumbleConfigurationBridge.transform(request)

        XCTAssertEqual(response.document.activeProfileID, secondID.uuidString.lowercased())
        XCTAssertEqual(response.document.keyBindings, response.document.profileKeyBindings[secondID.uuidString.lowercased()])
        XCTAssertEqual(response.document.outputBindings, response.document.profileOutputBindings[secondID.uuidString.lowercased()])
    }

    func testElementDuplicationPreservesFutureElementMetadataUnderTheFreshUUID() throws {
        let sourceID = "81C296ED-309D-4F05-BB11-F5A2E2027801"
        let copyID = "F5A5CB2B-A218-49D3-A3B4-3158B18B99CC"
        let raw: [String: Any] = ["id": profileID.uuidString, "name": "Metadata", "customization": ["elements": [[
            "id": sourceID, "kind": "button", "label": "Owned", "futureControl": ["vendor": "x"],
            "output": ["gamepadButtons": []], "defaultOutput": ["keyboard": ["keyCode": 49, "modifiersRawValue": 0], "gamepadButtons": ["east"]],
            "partOutputs": [KeypadElementInputPart.joystickUp.rawValue, ["keyboard": ["keyCode": 13, "modifiersRawValue": 2], "gamepadButtons": ["dpadUp"]], KeypadElementInputPart.joystickDown.rawValue, ["gamepadButtons": []]]
        ]]]]
        let response = try ThumbleConfigurationBridge.transform(decodeRequest(profileObjects: [raw], operation: [
            "type": "element.duplicate", "profileID": profileID.uuidString, "variant": "primary", "elementIDs": [sourceID],
            "newElementIDs": [copyID], "offsetX": 0.03, "offsetY": 0.04]))
        let profile = try object(from: response.document.profiles[0])
        let customization = try XCTUnwrap(profile["customization"] as? [String: Any])
        let elements = try XCTUnwrap(customization["elements"] as? [[String: Any]])
        XCTAssertEqual(elements.count, 2)
        let ownedDefault = KeypadElementOutputBinding(keyboard: KeypadKeyboardBinding(keyCode: 49), gamepadButtons: [.east])
        let ownedPart = KeypadElementOutputBinding(keyboard: KeypadKeyboardBinding(keyCode: 13, modifiersRawValue: 2), gamepadButtons: [.dpadUp])
        var decodedElements: [KeypadElement] = []
        for id in [sourceID, copyID] {
            let element = try XCTUnwrap(elements.first { ($0["id"] as? String)?.uppercased() == id })
            XCTAssertEqual(element["futureControl"] as? [String: String], ["vendor": "x"])
            let decoded = try JSONDecoder().decodeUnique(KeypadElement.self, from: JSONSerialization.data(withJSONObject: element))
            XCTAssertEqual(decoded.output, KeypadElementOutputBinding())
            XCTAssertEqual(decoded.defaultOutput, ownedDefault)
            XCTAssertEqual(decoded.partOutputs, [.joystickUp: ownedPart, .joystickDown: KeypadElementOutputBinding()])
            decodedElements.append(decoded)
        }
        var changedCopy = decodedElements[1]
        changedCopy.setOutputBinding(ownedDefault)
        changedCopy.setOutputBinding(KeypadElementOutputBinding(), for: .joystickUp)
        XCTAssertEqual(decodedElements[0].output, KeypadElementOutputBinding())
        XCTAssertEqual(decodedElements[0].partOutputs[.joystickUp], ownedPart)
        XCTAssertEqual(decodedElements[0].defaultOutput, ownedDefault)
        XCTAssertEqual(changedCopy.defaultOutput, ownedDefault)
    }

    func testElementDuplicateUsesCallerIDsDeterministically() throws {
        let rawProfile = try encodedObject(GamepadConfigurationProfile(
            id: profileID,
            name: "Elements",
            primaryCustomization: .defaultValue,
            updatedAt: 1
        ))
        let customization = try XCTUnwrap(rawProfile["customization"] as? [String: Any])
        let elements = try XCTUnwrap(customization["elements"] as? [[String: Any]])
        let sourceID = try XCTUnwrap(elements.first?["id"] as? String)
        let newID = "00000000-0000-0000-0000-0000000002f1"
        let request = try decodeRequest(
            profileObjects: [rawProfile],
            operation: [
                "type": "element.duplicate",
                "profileID": profileID.uuidString,
                "variant": "primary",
                "elementIDs": [sourceID],
                "newElementIDs": [newID],
                "offsetX": 0.01,
                "offsetY": 0.01
            ]
        )
        let first = try ThumbleConfigurationBridge.transform(request)
        let second = try ThumbleConfigurationBridge.transform(request)
        XCTAssertEqual(first, second)
        let result = try object(from: first.document.profiles[0])
        let resultCustomization = try XCTUnwrap(result["customization"] as? [String: Any])
        let resultElements = try XCTUnwrap(resultCustomization["elements"] as? [[String: Any]])
        XCTAssertTrue(resultElements.contains { ($0["id"] as? String)?.lowercased() == newID })
    }

    func testOrientationCopyUsesMatchingPrimaryFallbackAndPreservesUnknownSourceFields() throws {
        var landscape = GamepadCustomization.blankCanvas
        landscape.deviceCanvas = GamepadDeviceCanvas(frameID: "iphone-17-pro-landscape")
        let customID = UUID(uuidString: "00000000-0000-0000-0000-0000000002F2")!
        landscape.addCustomButton(id: customID)
        landscape.customButtons[0].layout.centerX = 0.8
        landscape.customButtons[0].layout.centerY = 0.25
        var rawProfile = try encodedObject(GamepadConfigurationProfile(
            id: profileID,
            name: "Primary Source",
            customization: landscape,
            updatedAt: 1
        ))
        var rawCustomization = try XCTUnwrap(rawProfile["customization"] as? [String: Any])
        rawCustomization["futureCustomization"] = ["kept": true, "futureStableID": "safe-future"]
        rawProfile["customization"] = rawCustomization
        let request = try decodeRequest(
            profileObjects: [rawProfile],
            operation: [
                "type": "orientation.copy",
                "profileID": profileID.uuidString,
                "source": "landscape",
                "destination": "portrait",
                "automaticallyArrange": true
            ]
        )
        let response = try ThumbleConfigurationBridge.transform(request)
        let result = try object(from: response.document.profiles[0])
        let primary = try XCTUnwrap(result["customization"] as? [String: Any])
        let savedLandscape = try XCTUnwrap(result["landscapeCustomization"] as? [String: Any])
        let savedPortrait = try XCTUnwrap(result["portraitCustomization"] as? [String: Any])
        XCTAssertEqual(
            try XCTUnwrap((savedLandscape["futureCustomization"] as? [String: Any])?["futureStableID"] as? String),
            "safe-future"
        )
        XCTAssertEqual(
            try XCTUnwrap((savedPortrait["futureCustomization"] as? [String: Any])?["futureStableID"] as? String),
            "safe-future"
        )
        XCTAssertEqual(primary as NSDictionary, savedPortrait as NSDictionary)
        XCTAssertEqual(
            try XCTUnwrap((savedPortrait["deviceCanvas"] as? [String: Any])?["frameID"] as? String),
            "iphone-17-pro-portrait"
        )
        let buttons = try XCTUnwrap(savedPortrait["customButtons"] as? [[String: Any]])
        let copied = try XCTUnwrap(buttons.first(where: {
            ($0["id"] as? String)?.lowercased() == customID.uuidString.lowercased()
        }))
        let layout = try XCTUnwrap(copied["layout"] as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(layout["centerX"] as? Double), 0.25, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(layout["centerY"] as? Double), 0.2, accuracy: 0.000_001)
    }

    func testMissingOrientationAndNoOpNudgeDoNotChangeDocument() throws {
        let rawProfile = try encodedObject(GamepadConfigurationProfile(
            id: profileID,
            name: "Elements",
            primaryCustomization: .defaultValue,
            updatedAt: 1
        ))
        let missing = try decodeRequest(
            profileObjects: [rawProfile],
            operation: [
                "type": "orientation.copy",
                "profileID": profileID.uuidString,
                "source": "portrait",
                "destination": "landscape",
                "automaticallyArrange": true
            ]
        )
        XCTAssertThrowsError(try ThumbleConfigurationBridge.transform(missing)) { error in
            XCTAssertEqual(error as? ThumbleConfigurationBridgeError, .missingOrientation)
        }

        let customization = try XCTUnwrap(rawProfile["customization"] as? [String: Any])
        let elements = try XCTUnwrap(customization["elements"] as? [[String: Any]])
        let elementID = try XCTUnwrap(elements.first?["id"] as? String)
        let noOp = try decodeRequest(
            profileObjects: [rawProfile],
            operation: [
                "type": "element.nudge",
                "profileID": profileID.uuidString,
                "variant": "primary",
                "elementIDs": [elementID],
                "deltaX": 0,
                "deltaY": 0
            ]
        )
        let response = try ThumbleConfigurationBridge.transform(noOp)
        XCTAssertFalse(response.changed)
        XCTAssertTrue(response.changedPaths.isEmpty)
    }

    func testElementNudgeAcceptsPreviewElementUUIDAndUsesCanonicalLayoutOperation() throws {
        let rawProfile = try encodedObject(GamepadConfigurationProfile(
            id: profileID,
            name: "Elements",
            primaryCustomization: .defaultValue,
            updatedAt: 1
        ))
        let customization = try XCTUnwrap(rawProfile["customization"] as? [String: Any])
        let elements = try XCTUnwrap(customization["elements"] as? [[String: Any]])
        let elementID = try XCTUnwrap(elements.first?["id"] as? String)
        let request = try decodeRequest(
            profileObjects: [rawProfile],
            operation: [
                "type": "element.nudge",
                "profileID": profileID.uuidString,
                "variant": "primary",
                "elementIDs": [elementID],
                "deltaX": 8,
                "deltaY": -3
            ]
        )
        let response = try ThumbleConfigurationBridge.transform(request)
        XCTAssertTrue(response.changed)
        XCTAssertEqual(response.document.profiles.count, 1)
    }

    func testProfileAndCustomizationResetMatchStandaloneSemantics() throws {
        var primary = GamepadCustomization.blankCanvas
        primary.showsButtonLabels = false
        var profile = GamepadConfigurationProfile(
            id: profileID,
            name: "Reset",
            primaryCustomization: primary,
            updatedAt: 1
        )
        profile.setCustomization(.blankCanvas, for: .landscape)
        profile.setCustomization(.blankCanvas, for: .portrait)
        var rawProfile = try encodedObject(profile)
        rawProfile["futureProfileField"] = ["kept": true]

        let profileReset = try decodeRequest(
            profileObjects: [rawProfile],
            operation: ["type": "profile.reset", "profileID": profileID.uuidString]
        )
        let profileResponse = try ThumbleConfigurationBridge.transform(profileReset)
        let resetProfile: GamepadConfigurationProfile = try decoded(profileResponse.document.profiles[0])
        XCTAssertEqual(resetProfile.customization, GamepadCustomization.defaultValue.normalized)
        XCTAssertNil(resetProfile.landscapeCustomization)
        XCTAssertNil(resetProfile.portraitCustomization)
        XCTAssertEqual(resetProfile.updatedAt, 1_234)
        let resetRaw = try object(from: profileResponse.document.profiles[0])
        XCTAssertEqual((resetRaw["futureProfileField"] as? [String: Bool])?["kept"], true)

        let customizationReset = try decodeRequest(
            profileObjects: [rawProfile],
            operation: [
                "type": "customization.reset",
                "profileID": profileID.uuidString,
                "variant": "landscape"
            ]
        )
        let customizationResponse = try ThumbleConfigurationBridge.transform(customizationReset)
        let customizationProfile: GamepadConfigurationProfile = try decoded(customizationResponse.document.profiles[0])
        var expectedProfile = profile
        expectedProfile.setCustomization(.defaultValue, for: .landscape)
        XCTAssertEqual(
            customizationProfile.landscapeCustomization,
            expectedProfile.normalized.landscapeCustomization
        )
        XCTAssertNotNil(customizationProfile.portraitCustomization)
    }

    func testControlBarResetsMatchSharedStandaloneOperations() throws {
        var customization = GamepadCustomization.defaultValue
        customization.controlBarItems = [.home, .settings]
        customization.setControlBarItemCustomization(
            GamepadButtonCustomization(widthScale: 2, heightScale: 1.5, isHidden: true),
            for: .settings
        )
        let profile = GamepadConfigurationProfile(
            id: profileID,
            name: "Control Bar",
            primaryCustomization: customization,
            updatedAt: 1
        )

        let itemReset = try decodeRequest(
            profileObjects: [try encodedObject(profile)],
            operation: [
                "type": "control-bar.item.reset",
                "profileID": profileID.uuidString,
                "variant": "primary",
                "item": "settings"
            ]
        )
        let itemResponse = try ThumbleConfigurationBridge.transform(itemReset)
        let itemProfile: GamepadConfigurationProfile = try decoded(itemResponse.document.profiles[0])
        XCTAssertEqual(itemProfile.customization.controlBarItems, [.home, .settings])
        XCTAssertEqual(
            itemProfile.customization.controlBarItemCustomization(for: .settings),
            .defaultValue
        )

        let barReset = try decodeRequest(
            profileObjects: [try encodedObject(profile)],
            operation: [
                "type": "control-bar.reset",
                "profileID": profileID.uuidString,
                "variant": "primary"
            ]
        )
        let barResponse = try ThumbleConfigurationBridge.transform(barReset)
        let barProfile: GamepadConfigurationProfile = try decoded(barResponse.document.profiles[0])
        XCTAssertEqual(barProfile.customization.controlBarItems, GamepadCustomization.defaultControlBarItems)
        XCTAssertTrue(barProfile.customization.controlBarItemCustomizations.isEmpty)
    }

    func testControlBarItemSetCoversRichNonFileAppearanceFillsIconAndHaptic() throws {
        var customization = GamepadCustomization.defaultValue
        let token = try XCTUnwrap(GamepadStyleToken(
            id: "existing-style",
            name: "Existing",
            visualStyle: .softWhitePlate()
        ).normalized)
        customization.upsertReusableStyle(token)
        let rawProfile = try encodedObject(GamepadConfigurationProfile(
            id: profileID,
            name: "Control Bar Appearance",
            primaryCustomization: customization,
            updatedAt: 1
        ))
        let request = try decodeRequest(
            profileObjects: [rawProfile],
            operation: [
                "type": "control-bar.item.set",
                "profileID": profileID.uuidString,
                "variant": "primary",
                "item": "settings",
                "changes": [
                    "widthScale": 1.6,
                    "heightScale": 1.25,
                    "isHidden": true,
                    "shape": "rounded_rectangle",
                    "accentStyle": "green",
                    "cornerRadii": [
                        "topLeading": 4.0, "topTrailing": 8.0,
                        "bottomTrailing": 12.0, "bottomLeading": 16.0
                    ],
                    "shadowStrength": 0.4,
                    "fill": [
                        "kind": "gradient", "type": "linear", "angleDegrees": -45.0,
                        "stops": [
                            ["offset": 1.0, "color": ["red": 0.8, "green": 0.7, "blue": 0.6, "alpha": 1.0]],
                            ["offset": 0.0, "color": ["red": 0.1, "green": 0.2, "blue": 0.3, "alpha": 1.0]]
                        ]
                    ],
                    "lightFill": [
                        "kind": "solid",
                        "color": ["red": 0.9, "green": 0.9, "blue": 0.9, "alpha": 1.0]
                    ],
                    "darkFill": [
                        "kind": "tile", "pattern": "dots",
                        "foregroundColor": ["red": 1.0, "green": 1.0, "blue": 1.0, "alpha": 1.0],
                        "backgroundColor": ["red": 0.0, "green": 0.0, "blue": 0.0, "alpha": 1.0],
                        "scale": 1.25, "spacingX": 0.2, "spacingY": 0.3,
                        "alignment": "center", "opacity": 0.8
                    ],
                    "lightFillOpacity": 0.65,
                    "darkFillOpacity": 0.55,
                    "styleID": "existing-style",
                    "appearance": [
                        "materialPreset": "soft-white-raised",
                        "strokeWidth": 2.0,
                        "pressedScale": 0.9
                    ],
                    "icon": ["source": "sf_symbol", "value": "slider.horizontal.3"],
                    "haptic": [
                        "style": "rigid", "pattern": "double",
                        "intensity": 0.7, "sharpness": 0.8, "duration": 0.09
                    ]
                ]
            ]
        )
        let response = try ThumbleConfigurationBridge.transform(request)
        let profile: GamepadConfigurationProfile = try decoded(response.document.profiles[0])
        let appearance = profile.customization.controlBarItemCustomization(for: .settings)
        XCTAssertEqual(appearance.widthScale, 1.6)
        XCTAssertEqual(appearance.heightScale, 1.25)
        XCTAssertTrue(appearance.isHidden)
        XCTAssertEqual(appearance.shape, .roundedRectangle)
        XCTAssertEqual(appearance.accentStyle, .green)
        XCTAssertEqual(appearance.cornerRadii?.topLeading, 4)
        XCTAssertEqual(appearance.cornerRadii?.bottomLeading, 16)
        XCTAssertEqual(appearance.shadowStrength, 0.4)
        XCTAssertNil(appearance.fillStyle)
        XCTAssertEqual(appearance.lightFillColor?.alpha, 0.65)
        if case .tile(let tile)? = appearance.darkFillStyle {
            XCTAssertEqual(tile.opacity, 0.55)
        } else {
            XCTFail("Expected dark tile fill")
        }
        XCTAssertEqual(appearance.styleID, "existing-style")
        XCTAssertNotNil(appearance.visualStyle)
        XCTAssertEqual(appearance.icon?.source, .sfSymbol)
        XCTAssertEqual(appearance.icon?.value, "slider.horizontal.3")
        XCTAssertEqual(appearance.hapticFeedback?.style, .rigid)
        XCTAssertEqual(appearance.hapticFeedback?.pattern, .double)
        XCTAssertEqual(profile.landscapeCustomization?.controlBarItemCustomization(for: .settings), appearance)
        XCTAssertNil(profile.portraitCustomization)
    }

    func testControlBarItemSetStyleDetachExplicitVariantNoOpAndMembership() throws {
        var customization = GamepadCustomization.defaultValue
        customization.controlBarItems = [.home, .settings]
        let token = try XCTUnwrap(GamepadStyleToken(
            id: "existing-style",
            name: "Existing",
            visualStyle: .softWhitePlate()
        ).normalized)
        customization.upsertReusableStyle(token)
        var styled = customization.controlBarItemCustomization(for: .settings)
        styled.styleID = "existing-style"
        customization.setControlBarItemCustomization(styled, for: .settings)
        let profile = GamepadConfigurationProfile(
            id: profileID,
            name: "Variants",
            customization: customization,
            portraitCustomization: customization,
            updatedAt: 1
        )
        let rawProfile = try encodedObject(profile)
        let detached = try ThumbleConfigurationBridge.transform(decodeRequest(
            profileObjects: [rawProfile],
            operation: [
                "type": "control-bar.item.set", "profileID": profileID.uuidString,
                "variant": "portrait", "item": "settings", "changes": ["clearStyle": true]
            ]
        ))
        let detachedProfile: GamepadConfigurationProfile = try decoded(detached.document.profiles[0])
        XCTAssertNil(detachedProfile.customization.controlBarItemCustomization(for: .settings).styleID)
        XCTAssertNil(detachedProfile.portraitCustomization?.controlBarItemCustomization(for: .settings).styleID)
        XCTAssertEqual(
            detachedProfile.landscapeCustomization?.controlBarItemCustomization(for: .settings).styleID,
            "existing-style"
        )

        let noOpProfile = GamepadConfigurationProfile(
            id: profileID,
            name: "No-op",
            customization: customization,
            landscapeCustomization: customization,
            updatedAt: 1
        )
        let noOp = try ThumbleConfigurationBridge.transform(decodeRequest(
            profileObjects: [try encodedObject(noOpProfile)],
            operation: [
                "type": "control-bar.item.set", "profileID": profileID.uuidString,
                "variant": "primary", "item": "home", "changes": ["isHidden": false]
            ]
        ))
        XCTAssertFalse(noOp.changed)
        XCTAssertTrue(noOp.changedPaths.isEmpty)

        XCTAssertThrowsError(try ThumbleConfigurationBridge.transform(decodeRequest(
            profileObjects: [rawProfile],
            operation: [
                "type": "control-bar.item.set", "profileID": profileID.uuidString,
                "variant": "primary", "item": "connection", "changes": ["isHidden": true]
            ]
        ))) { error in
            XCTAssertEqual(error as? ThumbleConfigurationBridgeError, .invalidControlBar)
        }
        XCTAssertThrowsError(try ThumbleConfigurationBridge.transform(decodeRequest(
            profileObjects: [rawProfile],
            operation: [
                "type": "control-bar.item.set", "profileID": profileID.uuidString,
                "variant": "primary", "item": "settings", "changes": ["styleID": "missing"]
            ]
        ))) { error in
            XCTAssertEqual(error as? ThumbleConfigurationBridgeError, .invalidStyle)
        }
    }

    func testControlBarItemSetSpacerRestrictionsAndStrictDeferredFieldRejection() throws {
        var customization = GamepadCustomization.defaultValue
        customization.controlBarItems = [.spacer, .settings]
        let rawProfile = try encodedObject(GamepadConfigurationProfile(
            id: profileID,
            name: "Spacer",
            primaryCustomization: customization,
            updatedAt: 1
        ))
        let allowed = try ThumbleConfigurationBridge.transform(decodeRequest(
            profileObjects: [rawProfile],
            operation: [
                "type": "control-bar.item.set", "profileID": profileID.uuidString,
                "variant": "primary", "item": "spacer",
                "changes": ["widthScale": 2.5, "isHidden": true]
            ]
        ))
        let allowedProfile: GamepadConfigurationProfile = try decoded(allowed.document.profiles[0])
        let spacer = allowedProfile.customization.controlBarItemCustomization(for: .spacer)
        XCTAssertEqual(spacer.widthScale, 2.5)
        XCTAssertTrue(spacer.isHidden)
        XCTAssertEqual(spacer.heightScale, 1)

        for changes: [String: Any] in [
            ["heightScale": 1.2],
            ["fill": ["kind": "solid", "color": ["red": 1.0, "green": 0.0, "blue": 0.0, "alpha": 1.0]]],
            [:]
        ] {
            XCTAssertThrowsError(try ThumbleConfigurationBridge.transform(decodeRequest(
                profileObjects: [rawProfile],
                operation: [
                    "type": "control-bar.item.set", "profileID": profileID.uuidString,
                    "variant": "primary", "item": "spacer", "changes": changes
                ]
            )))
        }

        for (field, value): (String, Any) in [
            ("fillImage", ["path": "/tmp/secret.png"]), ("path", "/tmp/secret"),
            ("assetID", "secret-asset"), ("raw", ["isHidden": true]),
            ("centerX", 0.5), ("rotationDegrees", 1.0), ("zIndex", 4),
            ("isLocationLocked", true), ("hitInsets", ["top": 1, "leading": 1, "bottom": 1, "trailing": 1]),
            ("showsIntegratedLabel", false), ("launchTarget", ["argv": ["--secret"]]),
            ("keyCode", 49)
        ] {
            XCTAssertThrowsError(try ThumbleConfigurationBridge.transform(decodeRequest(
                profileObjects: [rawProfile],
                operation: [
                    "type": "control-bar.item.set", "profileID": profileID.uuidString,
                    "variant": "primary", "item": "settings", "changes": [field: value]
                ]
            ))) { error in
                XCTAssertEqual(error as? ThumbleConfigurationBridgeError, .unexpectedField)
            }
        }
    }

    func testControlBarItemSetPreservesUnknownFieldsByStableItemIdentity() throws {
        var customization = GamepadCustomization.defaultValue
        customization.controlBarItems = [.home, .settings]
        customization.setControlBarItemCustomization(
            GamepadButtonCustomization(widthScale: 1.2),
            for: .home
        )
        customization.setControlBarItemCustomization(
            GamepadButtonCustomization(widthScale: 1.3),
            for: .settings
        )
        var rawProfile = try encodedObject(GamepadConfigurationProfile(
            id: profileID,
            name: "Unknowns",
            primaryCustomization: customization,
            updatedAt: 1
        ))
        var rawCustomization = try XCTUnwrap(rawProfile["customization"] as? [String: Any])
        var entries = try XCTUnwrap(rawCustomization["controlBarItemCustomizations"] as? [[String: Any]])
        entries.reverse()
        for index in entries.indices {
            let item = try XCTUnwrap(entries[index]["item"] as? String)
            entries[index]["futureEntry"] = ["item": item]
            var appearance = try XCTUnwrap(entries[index]["appearance"] as? [String: Any])
            appearance["futureAppearance"] = ["item": item]
            entries[index]["appearance"] = appearance
        }
        rawCustomization["controlBarItemCustomizations"] = entries
        rawProfile["customization"] = rawCustomization

        let response = try ThumbleConfigurationBridge.transform(decodeRequest(
            profileObjects: [rawProfile],
            operation: [
                "type": "control-bar.item.set", "profileID": profileID.uuidString,
                "variant": "primary", "item": "settings", "changes": ["widthScale": 1.8]
            ]
        ))
        let result = try object(from: response.document.profiles[0])
        let resultCustomization = try XCTUnwrap(result["customization"] as? [String: Any])
        let resultEntries = try XCTUnwrap(resultCustomization["controlBarItemCustomizations"] as? [[String: Any]])
        XCTAssertEqual(resultEntries.compactMap { $0["item"] as? String }, ["home", "settings"])
        for entry in resultEntries {
            let item = try XCTUnwrap(entry["item"] as? String)
            XCTAssertEqual((entry["futureEntry"] as? [String: String])?["item"], item)
            let appearance = try XCTUnwrap(entry["appearance"] as? [String: Any])
            XCTAssertEqual((appearance["futureAppearance"] as? [String: String])?["item"], item)
        }
    }

    func testSafeCustomizationSetMatchesStandaloneScalarSemantics() throws {
        var rawProfile = try encodedObject(GamepadConfigurationProfile(
            id: profileID,
            name: "Customization",
            primaryCustomization: .defaultValue,
            updatedAt: 1
        ))
        var rawCustomization = try XCTUnwrap(rawProfile["customization"] as? [String: Any])
        rawCustomization["futureScalarField"] = ["kept": true]
        rawProfile["customization"] = rawCustomization
        let request = try decodeRequest(
            profileObjects: [rawProfile],
            operation: [
                "type": "customization.set",
                "profileID": profileID.uuidString,
                "variant": "primary",
                "changes": [
                    "layoutMode": "southpaw",
                    "controlScale": "large",
                    "colorScheme": "dark",
                    "accentStyle": "purple",
                    "showsButtonLabels": false,
                    "backgroundEdit": [
                        "action": "set",
                        "scope": "all",
                        "color": ["red": 0.1, "green": 0.2, "blue": 0.3, "alpha": 0.8]
                    ]
                ]
            ]
        )
        let first = try ThumbleConfigurationBridge.transform(request)
        XCTAssertEqual(first, try ThumbleConfigurationBridge.transform(request))
        let profile: GamepadConfigurationProfile = try decoded(first.document.profiles[0])
        XCTAssertEqual(profile.customization.layoutMode, .southpaw)
        XCTAssertEqual(profile.customization.controlScale, .large)
        XCTAssertEqual(profile.customization.colorSchemePreference, .dark)
        XCTAssertEqual(profile.customization.accentStyle, .purple)
        XCTAssertFalse(profile.customization.showsButtonLabels)
        XCTAssertEqual(profile.customization.backgroundLightColor, GamepadRGBAColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.8))
        XCTAssertEqual(profile.customization.backgroundDarkColor, profile.customization.backgroundLightColor)
        XCTAssertNil(profile.customization.backgroundFillStyle)
        let result = try object(from: first.document.profiles[0])
        let resultCustomization = try XCTUnwrap(result["customization"] as? [String: Any])
        XCTAssertEqual((resultCustomization["futureScalarField"] as? [String: Bool])?["kept"], true)

        let empty = try decodeRequest(
            profileObjects: [rawProfile],
            operation: [
                "type": "customization.set",
                "profileID": profileID.uuidString,
                "variant": "primary",
                "changes": ["backgroundEdit": ["action": "keep"]]
            ]
        )
        XCTAssertThrowsError(try ThumbleConfigurationBridge.transform(empty)) { error in
            XCTAssertEqual(error as? ThumbleConfigurationBridgeError, .invalidCustomizationChanges)
        }
    }

    func testDeviceSetMirrorsRawMetadataFromTheSelectedCanvasNotStalePrimarySources() throws {
        let id = "81C296ED-309D-4F05-BB11-F5A2E2027801"
        func canvas(_ marker: String, frame: String, populated: Bool = true) -> [String: Any] {
            ["deviceCanvas": ["frameID": frame], "futureCustomization": marker,
             "elements": populated ? [["id": id, "kind": "button", "label": marker,
                "output": ["gamepadButtons": []], "defaultOutput": ["gamepadButtons": []], "futureElement": marker]] : []]
        }
        let primary = canvas("Primary", frame: "iphone-17-pro-landscape")
        for variant in ["primary", "landscape", "portrait"] {
            let landscape = canvas("Landscape", frame: "iphone-15-pro-landscape", populated: variant != "primary")
            let portrait = canvas("Portrait", frame: "iphone-15-pro-portrait")
            let raw: [String: Any] = ["id": profileID.uuidString, "name": "Sources", "customization": primary,
                "landscapeCustomization": landscape, "portraitCustomization": portrait]
            let frame = variant == "portrait" ? "iphone-17-pro-portrait" : "iphone-17-pro-landscape"
            let response = try ThumbleConfigurationBridge.transform(decodeRequest(profileObjects: [raw], operation: [
                "type": "device.set", "profileID": profileID.uuidString, "variant": variant, "frameID": frame]))
            let result = try object(from: response.document.profiles[0])
            let selected = try XCTUnwrap(result["customization"] as? [String: Any])
            let expected = variant == "primary" ? "Primary" : variant.capitalized
            XCTAssertEqual(selected["futureCustomization"] as? String, expected)
            let element = try XCTUnwrap((selected["elements"] as? [[String: Any]])?.first)
            XCTAssertEqual(element["futureElement"] as? String, expected)
            let targetKey = variant == "portrait" ? "portraitCustomization" : "landscapeCustomization"
            let target = try XCTUnwrap(result[targetKey] as? [String: Any])
            XCTAssertTrue(NSDictionary(dictionary: target).isEqual(to: selected))
            let untouched = variant == "portrait" ? "landscapeCustomization" : "portraitCustomization"
            XCTAssertTrue(NSDictionary(dictionary: try XCTUnwrap(result[untouched] as? [String: Any])).isEqual(to: try XCTUnwrap(raw[untouched] as? [String: Any])))
        }
    }

    func testDeviceSetNullOrientationSourcesResolveFromPrimaryMetadata() throws {
        let primary: [String: Any] = ["futureCustomization": ["source": "Primary"], "elements": [[
            "id": UUID().uuidString, "kind": "button", "label": "Owned", "futureElement": ["source": "Primary"], "output": ["gamepadButtons": []]]]]
        for variant in ["landscape", "portrait"] {
            let raw: [String: Any] = ["id": profileID.uuidString, "name": "Null", "customization": primary,
                "landscapeCustomization": NSNull(), "portraitCustomization": NSNull()]
            let response = try ThumbleConfigurationBridge.transform(decodeRequest(profileObjects: [raw], operation: [
                "type": "device.set", "profileID": profileID.uuidString, "variant": variant,
                "frameID": variant == "landscape" ? "iphone-17-pro-landscape" : "iphone-17-pro-portrait"]))
            let result = try object(from: response.document.profiles[0])
            let selected = try XCTUnwrap(result["customization"] as? [String: Any])
            XCTAssertEqual(selected["futureCustomization"] as? [String: String], ["source": "Primary"])
            XCTAssertEqual((selected["elements"] as? [[String: Any]])?.first?["futureElement"] as? [String: String], ["source": "Primary"])
            let target = try XCTUnwrap(result[variant + "Customization"] as? [String: Any])
            XCTAssertTrue(NSDictionary(dictionary: target).isEqual(to: selected))
        }
    }

    func testOrientationAndCatalogOnlyDeviceSetAreTyped() throws {
        let rawProfile = try encodedObject(GamepadConfigurationProfile(
            id: profileID,
            name: "Device",
            primaryCustomization: .defaultValue,
            updatedAt: 1
        ))
        let orientation = try decodeRequest(
            profileObjects: [rawProfile],
            operation: [
                "type": "orientation.set",
                "profileID": profileID.uuidString,
                "preference": "portrait"
            ]
        )
        let orientationResult = try ThumbleConfigurationBridge.transform(orientation)
        let oriented: GamepadConfigurationProfile = try decoded(orientationResult.document.profiles[0])
        XCTAssertEqual(oriented.orientationPreference, .portrait)

        let device = try decodeRequest(
            profileObjects: [rawProfile],
            operation: [
                "type": "device.set",
                "profileID": profileID.uuidString,
                "variant": "primary",
                "frameID": "iphone-16-pro-landscape"
            ]
        )
        let deviceResult = try ThumbleConfigurationBridge.transform(device)
        let selected: GamepadConfigurationProfile = try decoded(deviceResult.document.profiles[0])
        XCTAssertEqual(selected.customization.deviceCanvas.frameID, "iphone-16-pro-landscape")

        let custom = try decodeRequest(
            profileObjects: [rawProfile],
            operation: [
                "type": "device.set",
                "profileID": profileID.uuidString,
                "variant": "primary",
                "frameID": "custom-844x390-landscape"
            ]
        )
        XCTAssertThrowsError(try ThumbleConfigurationBridge.transform(custom)) { error in
            XCTAssertEqual(error as? ThumbleConfigurationBridgeError, .invalidDeviceFrame)
        }
    }

    func testTypedControlBarCollectionOperationsMatchStandaloneHelpers() throws {
        var customization = GamepadCustomization.defaultValue
        customization.controlBarItems = [.connectionStatus, .profileMenu, .settings]
        customization.setControlBarItemCustomization(
            GamepadButtonCustomization(widthScale: 1.4),
            for: .settings
        )
        let rawProfile = try encodedObject(GamepadConfigurationProfile(
            id: profileID,
            name: "Control Bar",
            primaryCustomization: customization,
            updatedAt: 1
        ))

        func transformed(_ operation: [String: Any]) throws -> GamepadConfigurationProfile {
            let request = try decodeRequest(profileObjects: [rawProfile], operation: operation)
            let response = try ThumbleConfigurationBridge.transform(request)
            return try decoded(response.document.profiles[0])
        }

        let common: [String: Any] = [
            "profileID": profileID.uuidString,
            "variant": "primary"
        ]
        var set = common
        set["type"] = "control-bar.set"
        set["items"] = ["home", "settings", "connection"]
        XCTAssertEqual(try transformed(set).customization.controlBarItems, [.home, .settings, .connectionAction])

        var add = common
        add["type"] = "control-bar.add"
        add["item"] = "home"
        XCTAssertEqual(
            try transformed(add).customization.controlBarItems,
            [.connectionStatus, .profileMenu, .settings, .home]
        )

        var remove = common
        remove["type"] = "control-bar.remove"
        remove["item"] = "settings"
        let removed = try transformed(remove)
        XCTAssertEqual(removed.customization.controlBarItems, [.connectionStatus, .profileMenu])
        XCTAssertEqual(removed.customization.controlBarItemCustomization(for: .settings), .defaultValue)

        var move = common
        move["type"] = "control-bar.move"
        move["item"] = "settings"
        move["direction"] = "up"
        XCTAssertEqual(
            try transformed(move).customization.controlBarItems,
            [.connectionStatus, .settings, .profileMenu]
        )
    }

    func testSparsePrimaryControlBarMutationCompactsNewOrientationMirror() throws {
        let canonical = try encodedObject(GamepadConfigurationProfile(
            id: profileID,
            name: "Sparse Control Bar",
            primaryCustomization: .defaultValue,
            updatedAt: 1
        ))
        var sparse = canonical
        let canonicalCustomization = try XCTUnwrap(canonical["customization"] as? [String: Any])
        sparse["customization"] = [
            "elements": try XCTUnwrap(canonicalCustomization["elements"])
        ]
        sparse.removeValue(forKey: "landscapeCustomization")
        sparse.removeValue(forKey: "portraitCustomization")
        let request = try decodeRequest(
            profileObjects: [sparse],
            operation: [
                "type": "control-bar.set",
                "profileID": profileID.uuidString,
                "variant": "primary",
                "items": ["status", "settings"]
            ]
        )
        let response = try ThumbleConfigurationBridge.transform(request)
        let result = try object(from: response.document.profiles[0])
        let primary = try XCTUnwrap(result["customization"] as? [String: Any])
        let landscape = try XCTUnwrap(result["landscapeCustomization"] as? [String: Any])
        XCTAssertEqual(primary["controlBarItems"] as? [String], ["status", "settings"])
        XCTAssertEqual(
            try JSONSerialization.data(withJSONObject: primary, options: [.sortedKeys]),
            try JSONSerialization.data(withJSONObject: landscape, options: [.sortedKeys])
        )
        XCTAssertNil(result["portraitCustomization"])
    }

    func testTypedLayerOperationsMatchStandaloneOrderingAndPreserveIdentityFields() throws {
        var customization = GamepadCustomization.defaultValue
        customization.moveLayer(.builtin(.preset(5)), to: 0)
        var rawProfile = try encodedObject(GamepadConfigurationProfile(
            id: profileID,
            name: "Layers",
            primaryCustomization: customization,
            updatedAt: 1
        ))
        var rawCustomization = try XCTUnwrap(rawProfile["customization"] as? [String: Any])
        var metadata = try XCTUnwrap(rawCustomization["designMetadata"] as? [String: Any])
        var layerOrder = try XCTUnwrap(metadata["layerOrder"] as? [[String: Any]])
        let jumpIndex = try XCTUnwrap(layerOrder.firstIndex { ($0["button"] as? String) == KeypadElementID.preset(5).rawValue })
        layerOrder[jumpIndex]["futureIdentityField"] = ["kept": true]
        metadata["layerOrder"] = layerOrder
        rawCustomization["designMetadata"] = metadata
        rawProfile["customization"] = rawCustomization

        func transformed(_ type: String, extra: [String: Any] = [:]) throws -> GamepadConfigurationProfile {
            var operation: [String: Any] = [
                "type": type,
                "profileID": profileID.uuidString,
                "variant": "primary",
                "elementID": KeypadElement.builtInID(for: .preset(5)).uuidString
            ]
            for (key, value) in extra { operation[key] = value }
            let request = try decodeRequest(profileObjects: [rawProfile], operation: operation)
            let response = try ThumbleConfigurationBridge.transform(request)
            return try decoded(response.document.profiles[0])
        }

        let front = try transformed("layer.front")
        XCTAssertEqual(front.customization.orderedControlIdentitiesForDesign.last, .builtin(.preset(5)))
        let backward = try transformed("layer.backward")
        XCTAssertEqual(backward.customization.orderedControlIdentitiesForDesign.first, .builtin(.preset(5)))
        let back = try transformed("layer.back")
        XCTAssertEqual(back.customization.orderedControlIdentitiesForDesign.first, .builtin(.preset(5)))
        let forward = try transformed("layer.forward")
        XCTAssertEqual(forward.customization.orderedControlIdentitiesForDesign.first, .system(.topBarActivation))
        XCTAssertEqual(forward.customization.orderedControlIdentitiesForDesign[1], .builtin(.preset(5)))

        let moved = try transformed("layer.move", extra: [
            "destination": [
                "action": "after",
                "elementID": KeypadElement.builtInID(for: .preset(6)).uuidString
            ]
        ])
        let movedOrder = moved.customization.orderedControlIdentitiesForDesign
        XCTAssertGreaterThan(
            try XCTUnwrap(movedOrder.firstIndex(of: .builtin(.preset(5)))),
            try XCTUnwrap(movedOrder.firstIndex(of: .builtin(.preset(6))))
        )

        var frontOperation: [String: Any] = [
            "type": "layer.front",
            "profileID": profileID.uuidString,
            "variant": "primary",
            "elementID": KeypadElement.builtInID(for: .preset(5)).uuidString
        ]
        let rawResult = try ThumbleConfigurationBridge.transform(
            decodeRequest(profileObjects: [rawProfile], operation: frontOperation)
        )
        let resultObject = try object(from: rawResult.document.profiles[0])
        let resultCustomization = try XCTUnwrap(resultObject["customization"] as? [String: Any])
        let resultMetadata = try XCTUnwrap(resultCustomization["designMetadata"] as? [String: Any])
        let resultOrder = try XCTUnwrap(resultMetadata["layerOrder"] as? [[String: Any]])
        let resultJump = try XCTUnwrap(resultOrder.first { ($0["button"] as? String) == KeypadElementID.preset(5).rawValue })
        XCTAssertEqual((resultJump["futureIdentityField"] as? [String: Bool])?["kept"], true)

        let restoreDefault = try ThumbleConfigurationBridge.transform(decodeRequest(
            profileObjects: [rawProfile],
            operation: [
                "type": "layer.move",
                "profileID": profileID.uuidString,
                "variant": "primary",
                "elementID": KeypadElement.builtInID(for: .preset(5)).uuidString,
                "destination": ["action": "index", "index": 5]
            ]
        ))
        let defaultObject = try object(from: restoreDefault.document.profiles[0])
        let defaultCustomization = try XCTUnwrap(defaultObject["customization"] as? [String: Any])
        let defaultMetadata = try XCTUnwrap(defaultCustomization["designMetadata"] as? [String: Any])
        let defaultOrder = try XCTUnwrap(defaultMetadata["layerOrder"] as? [[String: Any]])
        let defaultJump = try XCTUnwrap(defaultOrder.first { ($0["button"] as? String) == KeypadElementID.preset(5).rawValue })
        XCTAssertEqual((defaultJump["futureIdentityField"] as? [String: Bool])?["kept"], true)
        let restored: GamepadConfigurationProfile = try decoded(restoreDefault.document.profiles[0])
        XCTAssertEqual(restored.customization.orderedControlIdentitiesForDesign, GamepadCustomization.defaultValue.orderedControlIdentitiesForDesign)

        frontOperation["destination"] = ["action": "index", "index": 0]
        XCTAssertThrowsError(try decodeRequest(profileObjects: [rawProfile], operation: frontOperation))
    }

    func testTypedGroupCreateRenameReorderAndUngroupUseSharedSemantics() throws {
        let groupID = UUID(uuidString: "00000000-0000-0000-0000-0000000003A1")!
        let profile = GamepadConfigurationProfile(
            id: profileID,
            name: "Groups",
            primaryCustomization: .defaultValue,
            updatedAt: 1
        )
        let create = try decodeRequest(
            profileObjects: [try encodedObject(profile)],
            operation: [
                "type": "group.create",
                "profileID": profileID.uuidString,
                "variant": "primary",
                "groupID": groupID.uuidString,
                "name": " Actions ",
                "elementIDs": [
                    KeypadElement.builtInID(for: .preset(5)).uuidString,
                    KeypadElement.builtInID(for: .preset(6)).uuidString
                ]
            ]
        )
        let createdResponse = try ThumbleConfigurationBridge.transform(create)
        let created: GamepadConfigurationProfile = try decoded(createdResponse.document.profiles[0])
        let group = try XCTUnwrap(created.customization.designMetadata?.groups.first)
        XCTAssertEqual(group.id, groupID)
        XCTAssertEqual(group.name, "Actions")
        XCTAssertEqual(group.children, [.builtin(.preset(5)), .builtin(.preset(6))])
        let createdOrder = created.customization.orderedControlIdentitiesForDesign
        XCTAssertEqual(
            createdOrder.distance(
                from: try XCTUnwrap(createdOrder.firstIndex(of: .builtin(.preset(5)))),
                to: try XCTUnwrap(createdOrder.firstIndex(of: .builtin(.preset(6))))
            ),
            1
        )

        var rawCreated = try object(from: createdResponse.document.profiles[0])
        var rawCustomization = try XCTUnwrap(rawCreated["customization"] as? [String: Any])
        var metadata = try XCTUnwrap(rawCustomization["designMetadata"] as? [String: Any])
        var groups = try XCTUnwrap(metadata["groups"] as? [[String: Any]])
        groups[0]["futureGroupField"] = ["kept": true]
        metadata["groups"] = groups
        rawCustomization["designMetadata"] = metadata
        rawCreated["customization"] = rawCustomization

        func transformed(_ type: String) throws -> ThumbleConfigurationBridgeResponse {
            try ThumbleConfigurationBridge.transform(decodeRequest(
                profileObjects: [rawCreated],
                operation: [
                    "type": type,
                    "profileID": profileID.uuidString,
                    "variant": "primary",
                    "groupID": groupID.uuidString
                ]
            ))
        }

        let renamedResponse = try ThumbleConfigurationBridge.transform(decodeRequest(
            profileObjects: [rawCreated],
            operation: [
                "type": "group.rename",
                "profileID": profileID.uuidString,
                "variant": "primary",
                "groupID": groupID.uuidString,
                "name": "Primary Actions"
            ]
        ))
        let renamed: GamepadConfigurationProfile = try decoded(renamedResponse.document.profiles[0])
        XCTAssertEqual(renamed.customization.designMetadata?.groups.first?.name, "Primary Actions")
        let renamedRaw = try object(from: renamedResponse.document.profiles[0])
        let renamedCustomization = try XCTUnwrap(renamedRaw["customization"] as? [String: Any])
        let renamedMetadata = try XCTUnwrap(renamedCustomization["designMetadata"] as? [String: Any])
        let renamedGroups = try XCTUnwrap(renamedMetadata["groups"] as? [[String: Any]])
        XCTAssertEqual((renamedGroups[0]["futureGroupField"] as? [String: Bool])?["kept"], true)

        let duplicateGroupID = UUID(uuidString: "00000000-0000-0000-0000-0000000003A2")!
        let duplicateElementIDs = [
            UUID(uuidString: "00000000-0000-0000-0000-0000000003B1")!,
            UUID(uuidString: "00000000-0000-0000-0000-0000000003B2")!
        ]
        let duplicateRequest = try decodeRequest(
            profileObjects: [rawCreated],
            operation: [
                "type": "group.duplicate",
                "profileID": profileID.uuidString,
                "variant": "primary",
                "groupID": groupID.uuidString,
                "newGroupID": duplicateGroupID.uuidString,
                "name": "Actions Copy",
                "newElementIDs": duplicateElementIDs.map(\.uuidString),
                "offsetX": 0.025,
                "offsetY": 0.025
            ]
        )
        let duplicatedResponse = try ThumbleConfigurationBridge.transform(duplicateRequest)
        XCTAssertEqual(duplicatedResponse, try ThumbleConfigurationBridge.transform(duplicateRequest))
        let duplicated: GamepadConfigurationProfile = try decoded(duplicatedResponse.document.profiles[0])
        let duplicateGroup = try XCTUnwrap(duplicated.customization.designMetadata?.groups.first { $0.id == duplicateGroupID })
        XCTAssertEqual(duplicateGroup.children, duplicateElementIDs.map(GamepadControlIdentity.custom))
        XCTAssertEqual(
            duplicated.customization.customButtons.suffix(2).map(\.id),
            duplicateElementIDs
        )
        let duplicatedRaw = try object(from: duplicatedResponse.document.profiles[0])
        let duplicateCustomization = try XCTUnwrap(duplicatedRaw["customization"] as? [String: Any])
        let duplicateMetadata = try XCTUnwrap(duplicateCustomization["designMetadata"] as? [String: Any])
        let duplicateGroups = try XCTUnwrap(duplicateMetadata["groups"] as? [[String: Any]])
        let preservedSource = try XCTUnwrap(duplicateGroups.first { ($0["id"] as? String)?.lowercased() == groupID.uuidString.lowercased() })
        XCTAssertEqual((preservedSource["futureGroupField"] as? [String: Bool])?["kept"], true)
        XCTAssertThrowsError(try ThumbleConfigurationBridge.transform(decodeRequest(
            profileObjects: [rawCreated],
            operation: [
                "type": "group.duplicate",
                "profileID": profileID.uuidString,
                "variant": "primary",
                "groupID": groupID.uuidString,
                "newGroupID": duplicateGroupID.uuidString,
                "newElementIDs": [duplicateElementIDs[0].uuidString],
                "offsetX": 0.025,
                "offsetY": 0.025
            ]
        )))

        let nudgeResponse = try ThumbleConfigurationBridge.transform(decodeRequest(
            profileObjects: [rawCreated],
            operation: [
                "type": "group.nudge",
                "profileID": profileID.uuidString,
                "variant": "primary",
                "groupID": groupID.uuidString,
                "canvasFrameID": "iphone-17-pro-portrait",
                "deltaX": 10,
                "deltaY": -5
            ]
        ))
        let nudged: GamepadConfigurationProfile = try decoded(nudgeResponse.document.profiles[0])
        let canvasSize = try XCTUnwrap(GamepadEditorDeviceCatalog.frames.first { $0.id == "iphone-17-pro-portrait" }).screenRect.size
        let starts = Dictionary(uniqueKeysWithValues: created.customization.resolvedControls(in: canvasSize).map { ($0.id, $0.center) })
        for identity in [GamepadControlIdentity.builtin(.preset(5)), .builtin(.preset(6))] {
            let start = try XCTUnwrap(starts[identity])
            let layout = try XCTUnwrap(nudged.customization.element(for: identity)?.layout)
            XCTAssertEqual(try XCTUnwrap(layout.centerX), (start.x + 10) / canvasSize.width, accuracy: 0.000_000_001)
            XCTAssertEqual(try XCTUnwrap(layout.centerY), (start.y - 5) / canvasSize.height, accuracy: 0.000_000_001)
        }
        let nudgedRaw = try object(from: nudgeResponse.document.profiles[0])
        let nudgedCustomization = try XCTUnwrap(nudgedRaw["customization"] as? [String: Any])
        let nudgedMetadata = try XCTUnwrap(nudgedCustomization["designMetadata"] as? [String: Any])
        let nudgedGroups = try XCTUnwrap(nudgedMetadata["groups"] as? [[String: Any]])
        XCTAssertEqual((nudgedGroups[0]["futureGroupField"] as? [String: Bool])?["kept"], true)
        XCTAssertThrowsError(try ThumbleConfigurationBridge.transform(decodeRequest(
            profileObjects: [rawCreated],
            operation: [
                "type": "group.nudge",
                "profileID": profileID.uuidString,
                "variant": "primary",
                "groupID": groupID.uuidString,
                "canvasFrameID": "custom-402x874-portrait",
                "deltaX": 10,
                "deltaY": 0
            ]
        )))

        let hiddenResponse = try transformed("group.hide")
        let hidden: GamepadConfigurationProfile = try decoded(hiddenResponse.document.profiles[0])
        XCTAssertEqual(hidden.customization.designMetadata?.groups.first?.isHidden, true)
        XCTAssertTrue(hidden.customization.buttonCustomization(for: .preset(5)).isHidden)
        XCTAssertTrue(hidden.customization.buttonCustomization(for: .preset(6)).isHidden)
        let hiddenElement = try XCTUnwrap(hidden.customization.elements.first { $0.inputID == .preset(5) })
        XCTAssertTrue(hiddenElement.layout.isHidden)
        XCTAssertEqual(hiddenElement.output, created.customization.element(for: .builtin(.preset(5)))?.output)
        let hiddenRaw = try object(from: hiddenResponse.document.profiles[0])
        let hiddenCustomization = try XCTUnwrap(hiddenRaw["customization"] as? [String: Any])
        let hiddenMetadata = try XCTUnwrap(hiddenCustomization["designMetadata"] as? [String: Any])
        let hiddenGroups = try XCTUnwrap(hiddenMetadata["groups"] as? [[String: Any]])
        XCTAssertEqual((hiddenGroups[0]["futureGroupField"] as? [String: Bool])?["kept"], true)

        let shownResponse = try ThumbleConfigurationBridge.transform(decodeRequest(
            profileObjects: [hiddenRaw],
            operation: [
                "type": "group.show",
                "profileID": profileID.uuidString,
                "variant": "primary",
                "groupID": groupID.uuidString
            ]
        ))
        let shown: GamepadConfigurationProfile = try decoded(shownResponse.document.profiles[0])
        XCTAssertEqual(shown.customization.designMetadata?.groups.first?.isHidden, false)
        XCTAssertFalse(shown.customization.buttonCustomization(for: .preset(5)).isHidden)
        XCTAssertNotNil(shown.customization.elements.first { $0.defaultControlID == .preset(5) })

        let lockedResponse = try transformed("group.lock")
        let locked: GamepadConfigurationProfile = try decoded(lockedResponse.document.profiles[0])
        XCTAssertEqual(locked.customization.designMetadata?.groups.first?.isLocked, true)
        XCTAssertTrue(locked.customization.buttonCustomization(for: .preset(5)).isLocationLocked)
        XCTAssertTrue(locked.customization.buttonCustomization(for: .preset(6)).isLocationLocked)
        let lockedRaw = try object(from: lockedResponse.document.profiles[0])
        let lockedNudge = try ThumbleConfigurationBridge.transform(decodeRequest(
            profileObjects: [lockedRaw],
            operation: [
                "type": "group.nudge",
                "profileID": profileID.uuidString,
                "variant": "primary",
                "groupID": groupID.uuidString,
                "deltaX": 10,
                "deltaY": 0
            ]
        ))
        XCTAssertFalse(lockedNudge.changed)
        let unlockedRaw = lockedRaw
        let unlockedResponse = try ThumbleConfigurationBridge.transform(decodeRequest(
            profileObjects: [unlockedRaw],
            operation: [
                "type": "group.unlock",
                "profileID": profileID.uuidString,
                "variant": "primary",
                "groupID": groupID.uuidString
            ]
        ))
        let unlocked: GamepadConfigurationProfile = try decoded(unlockedResponse.document.profiles[0])
        XCTAssertEqual(unlocked.customization.designMetadata?.groups.first?.isLocked, false)
        XCTAssertFalse(unlocked.customization.buttonCustomization(for: .preset(5)).isLocationLocked)

        let front: GamepadConfigurationProfile = try decoded(transformed("group.front").document.profiles[0])
        XCTAssertEqual(Array(front.customization.orderedControlIdentitiesForDesign.suffix(2)), [.builtin(.preset(5)), .builtin(.preset(6))])
        let back: GamepadConfigurationProfile = try decoded(transformed("group.back").document.profiles[0])
        XCTAssertEqual(Array(back.customization.orderedControlIdentitiesForDesign.prefix(2)), [.builtin(.preset(5)), .builtin(.preset(6))])
        _ = try transformed("group.forward")
        _ = try transformed("group.backward")

        let ungrouped: GamepadConfigurationProfile = try decoded(transformed("group.ungroup").document.profiles[0])
        XCTAssertTrue(ungrouped.customization.designMetadata?.groups.isEmpty ?? true)
    }

    func testElementResetUsesSharedTypeSpecificDefaults() throws {
        let elementID = UUID(uuidString: "00000000-0000-0000-0000-0000000002E1")!
        var customization = GamepadCustomization.blankCanvas
        customization.customButtons = [GamepadCustomButton(
            id: elementID,
            label: "Future Button",
            layout: GamepadButtonCustomization(
                centerX: 0.91,
                centerY: 0.12,
                widthScale: 2,
                heightScale: 2,
                shape: .star,
                isHidden: true
            ),
            controlKind: .button
        )]
        let profile = GamepadConfigurationProfile(
            id: profileID,
            name: "Element Reset",
            primaryCustomization: customization,
            updatedAt: 1
        )
        let request = try decodeRequest(
            profileObjects: [try encodedObject(profile)],
            operation: [
                "type": "element.reset",
                "profileID": profileID.uuidString,
                "variant": "primary",
                "elementID": elementID.uuidString
            ]
        )
        let response = try ThumbleConfigurationBridge.transform(request)
        let result: GamepadConfigurationProfile = try decoded(response.document.profiles[0])
        let button = try XCTUnwrap(result.customization.customButtons.first { $0.id == elementID })
        XCTAssertEqual(button.label, GamepadCustomControlKind.button.defaultElementLabel)
        XCTAssertEqual(button.layout.centerX, 0.5)
        XCTAssertEqual(button.layout.centerY, 0.5)
        XCTAssertEqual(button.layout.widthScale, 1)
        XCTAssertEqual(button.layout.heightScale, 1)
        XCTAssertEqual(button.layout.shape, .roundedRectangle)
        XCTAssertFalse(button.layout.isHidden)
    }

    func testGenerationGenerateUsesCallerIDsAndInstallsExactBindings() throws {
        let rawProfile = try encodedObject(GamepadConfigurationProfile(
            id: profileID,
            name: "Existing",
            primaryCustomization: .defaultValue,
            updatedAt: 1
        ))
        let generatedProfileID = "00000000-0000-0000-0000-000000000301"
        let customIDs = (1 ... 4).map { String(format: "00000000-0000-0000-0000-00000000031%01d", $0) }
        let request = try decodeRequest(
            profileObjects: [rawProfile],
            operation: [
                "type": "generation.generate",
                "preset": "hollow-knight",
                "presetRevision": 2,
                "destination": ["action": "create", "newProfileID": generatedProfileID],
                "newElementIDs": customIDs,
                "select": true,
                "makeDefault": true
            ]
        )
        let first = try ThumbleConfigurationBridge.transform(request)
        XCTAssertEqual(first, try ThumbleConfigurationBridge.transform(request))
        XCTAssertEqual(first.document.profiles.count, 2)
        XCTAssertEqual(first.document.activeProfileID, generatedProfileID)
        XCTAssertEqual(first.document.defaultProfileID, generatedProfileID)
        let generated: GamepadConfigurationProfile = try decoded(first.document.profiles[1])
        XCTAssertEqual(generated.id.uuidString.lowercased(), generatedProfileID)
        XCTAssertEqual(generated.name, "Hollow Knight")
        XCTAssertEqual(generated.updatedAt, 1_234)
        XCTAssertEqual(generated.customization.updatedAt, 1_234)
        XCTAssertEqual(
            generated.customization.customButtons.map { $0.id.uuidString.lowercased() },
            customIDs
        )
        let keys: [String: MacKeyBinding] = try decoded(XCTUnwrap(
            first.document.profileKeyBindings[generatedProfileID]
        ))
        XCTAssertEqual(Set(keys.keys), Set(generated.customization.elements.compactMap { $0.output?.keyboard == nil ? nil : $0.inputID.rawValue }))
        XCTAssertEqual(keys[KeypadElementID.preset(1).rawValue]?.keyCode, MacVirtualKey.upArrow)
        XCTAssertEqual(keys[KeypadElementID.preset(5).rawValue]?.keyCode, MacVirtualKey.z)
        XCTAssertEqual(keys[UUID(uuidString: customIDs[3])!.uuidString]?.keyCode, 34)
        for element in generated.customization.elements {
            XCTAssertEqual(element.defaultOutput, element.output)
            XCTAssertEqual(generated.recommendedMacOutputBindings[element.inputID]?.keyboard, keys[element.inputID.rawValue])
        }
        XCTAssertEqual(
            first.document.keyBindings,
            first.document.profileKeyBindings[generatedProfileID]
        )
    }

    func testGeneratedElementIDsCannotCollideWithRetainedControls() throws {
        let rawProfile = try encodedObject(GamepadConfigurationProfile(id: profileID, name: "Existing", primaryCustomization: .defaultValue))
        for operation in [
            ["type": "generation.generate", "preset": "hollow-knight", "presetRevision": 2, "newElementIDs": [KeypadElementID.preset(1).rawValue, UUID().uuidString, UUID().uuidString, UUID().uuidString]],
            ["type": "template.install", "template": "snes", "templateRevision": 2, "newElementIDs": [KeypadElementID.preset(5).rawValue, UUID().uuidString]]
        ] as [[String: Any]] {
            let request = try decodeRequest(profileObjects: [rawProfile], operation: operation.merging([
                "destination": ["action": "create", "newProfileID": UUID().uuidString], "select": true, "makeDefault": false
            ]) { _, new in new })
            XCTAssertThrowsError(try ThumbleConfigurationBridge.transform(request)) { error in
                XCTAssertEqual(error as? ThumbleConfigurationBridgeError, .invalidGeneratedElementIDs)
            }
        }
    }

    func testTemplateInstallSupportsRevisionedSNESAndInactiveMaps() throws {
        let rawProfile = try encodedObject(GamepadConfigurationProfile(
            id: profileID,
            name: "Existing",
            primaryCustomization: .defaultValue,
            updatedAt: 1
        ))
        let templateProfileID = "00000000-0000-0000-0000-000000000401"
        let customIDs = [
            "00000000-0000-0000-0000-000000000411",
            "00000000-0000-0000-0000-000000000412"
        ]
        let request = try decodeRequest(
            profileObjects: [rawProfile],
            operation: [
                "type": "template.install",
                "template": "snes",
                "templateRevision": 2,
                "destination": ["action": "create", "newProfileID": templateProfileID],
                "newElementIDs": customIDs,
                "select": false,
                "makeDefault": false
            ]
        )
        let response = try ThumbleConfigurationBridge.transform(request)
        XCTAssertEqual(response.document.activeProfileID, profileID.uuidString.lowercased())
        XCTAssertEqual(response.document.keyBindings, .object([:]))
        XCTAssertEqual(response.document.outputBindings, .object([:]))
        let installed: GamepadConfigurationProfile = try decoded(response.document.profiles[1])
        XCTAssertEqual(installed.customization.designMetadata?.sourceTemplateID, "snes")
        XCTAssertEqual(installed.customization.designMetadata?.sourceTemplateRevision, 2)
        XCTAssertEqual(
            installed.customization.customButtons.map { $0.id.uuidString.lowercased() },
            customIDs
        )
        let outputs: [String: MacControlOutputBinding] = try decoded(XCTUnwrap(
            response.document.profileOutputBindings[templateProfileID]
        ))
        XCTAssertEqual(Set(outputs.keys), Set(installed.customization.elements.map { $0.inputID.rawValue }))
        XCTAssertEqual(outputs[KeypadElementID.preset(5).rawValue]?.keyboard?.keyCode, MacVirtualKey.space)
    }

    func testEveryTemplateInstallRetainsAllOwnedPrimaryOutputsIncludingClears() throws {
        let existing = try encodedObject(GamepadConfigurationProfile(id: profileID, name: "Existing", primaryCustomization: .defaultValue))
        for template in ThumbleBridgeControllerTemplate.allCases {
            let newProfileID = UUID().uuidString.lowercased()
            let request = try decodeRequest(profileObjects: [existing], operation: [
                "type": "template.install", "template": template.rawValue, "templateRevision": template.revision,
                "destination": ["action": "create", "newProfileID": newProfileID],
                "newElementIDs": (0..<template.customElementIDCount).map { _ in UUID().uuidString.lowercased() },
                "select": true, "makeDefault": false
            ])
            let response = try ThumbleConfigurationBridge.transform(request)
            let installed: GamepadConfigurationProfile = try decoded(response.document.profiles[1])
            let raw: [String: MacControlOutputBinding] = try decoded(XCTUnwrap(response.document.profileOutputBindings[newProfileID]))
            let outputs = try XCTUnwrap(MacConfigurationBindings.decodedOutputs(raw))
            XCTAssertEqual(outputs, installed.configuredMacOutputBindings, template.rawValue)
            let controls = [installed.customization, installed.landscapeCustomization, installed.portraitCustomization].compactMap { $0 }.flatMap(\.elements)
            let interactive = Set(controls.filter { $0.kind != .text && $0.kind != .decoration }.map(\.inputID))
            XCTAssertEqual(Set(outputs.keys), interactive, template.rawValue)
            if template == .nintendo64 { XCTAssertTrue(outputs.values.contains { $0.isEmpty }) }
        }
    }

    func testTemplateInstallRemapsSoftWhiteLayerReferences() throws {
        let rawProfile = try encodedObject(GamepadConfigurationProfile(
            id: profileID,
            name: "Existing",
            primaryCustomization: .defaultValue,
            updatedAt: 1
        ))
        let templateProfileID = "00000000-0000-0000-0000-000000000501"
        let customIDs = (1 ... 15).map { String(format: "00000000-0000-0000-0000-0000000005%02d", $0 + 1) }
        let request = try decodeRequest(
            profileObjects: [rawProfile],
            operation: [
                "type": "template.install",
                "template": "softWhite",
                "templateRevision": 1,
                "destination": ["action": "create", "newProfileID": templateProfileID],
                "newElementIDs": customIDs,
                "select": false,
                "makeDefault": false
            ]
        )
        let response = try ThumbleConfigurationBridge.transform(request)
        let installed: GamepadConfigurationProfile = try decoded(response.document.profiles[1])
        XCTAssertEqual(
            installed.customization.customButtons.map { $0.id.uuidString.lowercased() },
            customIDs
        )
        let orderedCustomIDs: Set<String> = Set((installed.customization.designMetadata?.layerOrder ?? []).compactMap {
            guard case .custom(let id) = $0 else { return nil }
            return id.uuidString.lowercased()
        })
        XCTAssertTrue(Set(customIDs).isSubset(of: orderedCustomIDs))
    }

    func testTemplateReplacementPreservesUnknownProfileFields() throws {
        var rawProfile = try encodedObject(GamepadConfigurationProfile(
            id: profileID,
            name: "Super Nintendo",
            primaryCustomization: .defaultValue,
            updatedAt: 1
        ))
        rawProfile["futureProfileField"] = ["kept": true]
        let request = try decodeRequest(
            profileObjects: [rawProfile],
            operation: [
                "type": "template.install",
                "template": "snes",
                "templateRevision": 2,
                "destination": ["action": "replace", "profileID": profileID.uuidString],
                "newElementIDs": [
                    "00000000-0000-0000-0000-000000000611",
                    "00000000-0000-0000-0000-000000000612"
                ],
                "select": false,
                "makeDefault": false
            ]
        )
        let response = try ThumbleConfigurationBridge.transform(request)
        XCTAssertEqual(response.document.profiles.count, 1)
        let result = try object(from: response.document.profiles[0])
        XCTAssertEqual((result["futureProfileField"] as? [String: Bool])?["kept"], true)
    }

    func testGeneratedOperationsRejectWrongRevisionIDCountAndStaleDestination() throws {
        let rawProfile = try encodedObject(GamepadConfigurationProfile(
            id: profileID,
            name: "Not SNES",
            primaryCustomization: .defaultValue,
            updatedAt: 1
        ))
        let wrongRevision = try decodeRequest(
            profileObjects: [rawProfile],
            operation: [
                "type": "template.install", "template": "snes", "templateRevision": 1,
                "destination": ["action": "create", "newProfileID": "00000000-0000-0000-0000-000000000701"],
                "newElementIDs": [], "select": false, "makeDefault": false
            ]
        )
        XCTAssertThrowsError(try ThumbleConfigurationBridge.transform(wrongRevision)) { error in
            XCTAssertEqual(error as? ThumbleConfigurationBridgeError, .revisionMismatch)
        }

        let wrongCount = try decodeRequest(
            profileObjects: [rawProfile],
            operation: [
                "type": "generation.generate", "preset": "hollow-knight", "presetRevision": 2,
                "destination": ["action": "create", "newProfileID": "00000000-0000-0000-0000-000000000702"],
                "newElementIDs": [], "select": false, "makeDefault": false
            ]
        )
        XCTAssertThrowsError(try ThumbleConfigurationBridge.transform(wrongCount)) { error in
            XCTAssertEqual(error as? ThumbleConfigurationBridgeError, .invalidGeneratedElementIDs)
        }

        let stale = try decodeRequest(
            profileObjects: [rawProfile],
            operation: [
                "type": "template.install", "template": "snes", "templateRevision": 2,
                "destination": ["action": "replace", "profileID": profileID.uuidString],
                "newElementIDs": [
                    "00000000-0000-0000-0000-000000000711",
                    "00000000-0000-0000-0000-000000000712"
                ],
                "select": false, "makeDefault": false
            ]
        )
        XCTAssertThrowsError(try ThumbleConfigurationBridge.transform(stale)) { error in
            XCTAssertEqual(error as? ThumbleConfigurationBridgeError, .staleDestination)
        }
    }

    func testCheckedInTemplateCatalogMatchesSwiftTemplates() throws {
        struct Manifest: Decodable {
            struct Entry: Decodable {
                let id: String
                let name: String
                let description: String
                let revision: Int
                let customElementIDCount: Int
            }
            let schema: String
            let version: Int
            let templates: [Entry]
        }
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: repositoryRoot
            .appendingPathComponent("docs/mcp/controller-templates-v1.json"))
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        XCTAssertEqual(manifest.schema, "com.codybontecou.thumble.controller-templates")
        XCTAssertEqual(manifest.version, 1)
        XCTAssertEqual(manifest.templates.map(\.id), GamepadControllerTemplate.allCases.map(\.rawValue))
        XCTAssertEqual(manifest.templates.map(\.id), ThumbleBridgeControllerTemplate.allCases.map(\.rawValue))
        for ((entry, template), bridgeTemplate) in zip(
            zip(manifest.templates, GamepadControllerTemplate.allCases),
            ThumbleBridgeControllerTemplate.allCases
        ) {
            XCTAssertEqual(entry.name, template.displayName)
            XCTAssertEqual(entry.description, template.description)
            XCTAssertEqual(entry.revision, template.templateRevision)
            XCTAssertEqual(entry.revision, bridgeTemplate.revision)
            XCTAssertEqual(entry.customElementIDCount, bridgeTemplate.customElementIDCount)
            let profile = template.makeProfile()
            var seen = Set<UUID>()
            for customization in [
                Optional(profile.customization),
                profile.landscapeCustomization,
                profile.portraitCustomization
            ].compactMap({ $0 }) {
                seen.formUnion(customization.customButtons.map(\.id))
            }
            XCTAssertEqual(entry.customElementIDCount, seen.count, template.rawValue)
        }
    }

    func testCheckedInDeviceCatalogMatchesSwiftFrames() throws {
        struct Manifest: Decodable {
            struct Entry: Decodable {
                let id: String
                let device: String
                let orientation: String
                let width: Double
                let height: Double
                let frameStyle: String
            }
            let schema: String
            let version: Int
            let frames: [Entry]
        }
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: repositoryRoot
            .appendingPathComponent("docs/mcp/device-frames-v1.json"))
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        XCTAssertEqual(manifest.schema, "com.codybontecou.thumble.device-frames")
        XCTAssertEqual(manifest.version, 1)
        XCTAssertEqual(manifest.frames.map(\.id), GamepadEditorDeviceCatalog.frames.map(\.id))
        for (entry, frame) in zip(manifest.frames, GamepadEditorDeviceCatalog.frames) {
            XCTAssertEqual(entry.device, frame.spec.displayName)
            XCTAssertEqual(entry.orientation, frame.orientation.rawValue)
            XCTAssertEqual(entry.width, Double(frame.screenRect.width))
            XCTAssertEqual(entry.height, Double(frame.screenRect.height))
            XCTAssertEqual(entry.frameStyle, frame.frameStyle.rawValue)
        }
    }

    func testTypedStyleOperationsCoverRichAppearanceVariantsAndReferences() throws {
        let existing = GamepadStyleToken(
            id: "agent-style",
            name: "Old",
            visualStyle: GamepadControlVisualStyle(
                normal: GamepadControlStateStyle(
                    fillStyle: .solid(GamepadRGBAColor(red: 0.9, green: 0.8, blue: 0.7, alpha: 1))
                )
            )
        )
        var primary = GamepadCustomization.defaultValue
        primary.styleLibrary = GamepadStyleLibrary(styles: [existing])
        var landscape = primary
        landscape.deviceCanvas = GamepadDeviceCanvas(frameID: "iphone-17-pro-landscape")
        var portrait = primary
        portrait.deviceCanvas = GamepadDeviceCanvas(frameID: "iphone-17-pro-portrait")
        let profile = GamepadConfigurationProfile(
            id: profileID,
            name: "Styles",
            customization: primary,
            landscapeCustomization: landscape,
            portraitCustomization: portrait,
            updatedAt: 1
        )
        var rawProfile = try encodedObject(profile)
        var rawCustomization = try XCTUnwrap(rawProfile["customization"] as? [String: Any])
        var rawLibrary = try XCTUnwrap(rawCustomization["styleLibrary"] as? [String: Any])
        var rawStyles = try XCTUnwrap(rawLibrary["styles"] as? [[String: Any]])
        rawStyles[0]["futureStyleField"] = ["kept": true]
        var rawVisual = try XCTUnwrap(rawStyles[0]["visualStyle"] as? [String: Any])
        var rawNormal = try XCTUnwrap(rawVisual["normal"] as? [String: Any])
        rawNormal["futureNormalField"] = "kept"
        rawVisual["normal"] = rawNormal
        rawStyles[0]["visualStyle"] = rawVisual
        rawLibrary["styles"] = rawStyles
        rawCustomization["styleLibrary"] = rawLibrary
        rawProfile["customization"] = rawCustomization

        let color: (Double, Double, Double, Double) -> [String: Double] = {
            ["red": $0, "green": $1, "blue": $2, "alpha": $3]
        }
        let appearance: [String: Any] = [
            "materialPreset": "soft-white-raised",
            "fillColor": color(0.1, 0.2, 0.3, 0.4),
            "foregroundColor": color(0.2, 0.3, 0.4, 0.5),
            "strokeColor": color(0.3, 0.4, 0.5, 0.6), "strokeWidth": 2.0,
            "glowColor": color(0.4, 0.5, 0.6, 0.7), "glowRadius": 3.0,
            "innerShadowColor": color(0.5, 0.6, 0.7, 0.8),
            "innerShadowRadius": 4.0, "innerShadowX": -2.0, "innerShadowY": 2.0,
            "highlightColor": color(0.6, 0.7, 0.8, 0.9),
            "highlightRadius": 5.0, "highlightX": -3.0, "highlightY": 3.0,
            "highlightOpacity": 0.65,
            "bevelHighlightColor": color(0.7, 0.8, 0.9, 1),
            "bevelShadowColor": color(0.1, 0.2, 0.3, 0.4),
            "bevelWidth": 1.5, "opacity": 0.8,
            "shadows": [[
                "color": color(0.2, 0.3, 0.4, 0.5),
                "radius": 6.0, "x": 2.0, "y": 3.0, "opacity": 0.4
            ]],
            "pressedFillColor": color(0.8, 0.7, 0.6, 0.5), "pressedScale": 0.9,
            "icon": ["source": "sf_symbol", "value": "star.fill"],
            "haptic": [
                "style": "rigid", "pattern": "double", "intensity": 0.7,
                "sharpness": 0.8, "duration": 0.1
            ]
        ]
        let createdResponse = try ThumbleConfigurationBridge.transform(decodeRequest(
            profileObjects: [rawProfile],
            operation: [
                "type": "style.create", "profileID": profileID.uuidString,
                "styleID": "agent-style", "name": "Agent Style", "appearance": appearance
            ]
        ))
        let created: GamepadConfigurationProfile = try decoded(createdResponse.document.profiles[0])
        for customization in [
            Optional(created.customization), created.landscapeCustomization, created.portraitCustomization
        ].compactMap({ $0 }) {
            let token = try XCTUnwrap(customization.styleLibrary.style(id: "agent-style"))
            XCTAssertEqual(token.name, "Agent Style")
            XCTAssertEqual(token.visualStyle.normal.strokeWidth, 2)
            XCTAssertEqual(token.visualStyle.pressed?.scale, 0.9)
            XCTAssertEqual(token.visualStyle.icon?.source, .sfSymbol)
            XCTAssertEqual(token.visualStyle.hapticFeedback?.pattern, .double)
        }
        let createdRaw = try object(from: createdResponse.document.profiles[0])
        let createdCustomization = try XCTUnwrap(createdRaw["customization"] as? [String: Any])
        let createdLibrary = try XCTUnwrap(createdCustomization["styleLibrary"] as? [String: Any])
        let createdStyles = try XCTUnwrap(createdLibrary["styles"] as? [[String: Any]])
        XCTAssertEqual((createdStyles[0]["futureStyleField"] as? [String: Bool])?["kept"], true)
        let createdVisual = try XCTUnwrap(createdStyles[0]["visualStyle"] as? [String: Any])
        let createdNormal = try XCTUnwrap(createdVisual["normal"] as? [String: Any])
        XCTAssertEqual(createdNormal["futureNormalField"] as? String, "kept")

        let appliedResponse = try ThumbleConfigurationBridge.transform(decodeRequest(
            profileObjects: [createdRaw],
            operation: [
                "type": "style.apply", "profileID": profileID.uuidString,
                "variant": "primary", "styleID": "agent-style", "elementID": KeypadElementID.preset(5).rawValue
            ]
        ))
        let applied: GamepadConfigurationProfile = try decoded(appliedResponse.document.profiles[0])
        XCTAssertEqual(applied.customization.buttonCustomization(for: .preset(5)).styleID, "agent-style")
        XCTAssertEqual(applied.landscapeCustomization?.buttonCustomization(for: .preset(5)).styleID, "agent-style")
        XCTAssertNil(applied.portraitCustomization?.buttonCustomization(for: .preset(5)).styleID)

        let detachedResponse = try ThumbleConfigurationBridge.transform(decodeRequest(
            profileObjects: [try object(from: appliedResponse.document.profiles[0])],
            operation: [
                "type": "style.detach", "profileID": profileID.uuidString,
                "variant": "primary", "elementID": KeypadElementID.preset(5).rawValue
            ]
        ))
        let renamedResponse = try ThumbleConfigurationBridge.transform(decodeRequest(
            profileObjects: [try object(from: detachedResponse.document.profiles[0])],
            operation: [
                "type": "style.rename", "profileID": profileID.uuidString,
                "styleID": "agent-style", "name": "Renamed"
            ]
        ))
        let renamed: GamepadConfigurationProfile = try decoded(renamedResponse.document.profiles[0])
        XCTAssertTrue([
            Optional(renamed.customization), renamed.landscapeCustomization, renamed.portraitCustomization
        ].compactMap({ $0 }).allSatisfy {
            $0.styleLibrary.style(id: "agent-style")?.name == "Renamed"
        })
        let deletedResponse = try ThumbleConfigurationBridge.transform(decodeRequest(
            profileObjects: [try object(from: renamedResponse.document.profiles[0])],
            operation: [
                "type": "style.delete", "profileID": profileID.uuidString,
                "styleID": "agent-style"
            ]
        ))
        let deleted: GamepadConfigurationProfile = try decoded(deletedResponse.document.profiles[0])
        XCTAssertTrue([
            Optional(deleted.customization), deleted.landscapeCustomization, deleted.portraitCustomization
        ].compactMap({ $0 }).allSatisfy {
            $0.styleLibrary.style(id: "agent-style") == nil
                && $0.buttonCustomization(for: .preset(5)).styleID == nil
        })
    }

    func testElementAddUsesCallerUUIDAndSixKindStandaloneDefaults() throws {
        let rawProfile = try encodedObject(GamepadConfigurationProfile(
            id: profileID,
            name: "Add Elements",
            primaryCustomization: .defaultValue,
            updatedAt: 1
        ))
        let expectations: [(GamepadCustomControlKind, KeypadElementID, String, CGFloat, CGFloat, GamepadButtonShapeStyle)] = [
            (.button, .preset(11), "Shape", 1, 1, .roundedRectangle),
            (.joystick, .preset(1), "Joystick", 1.35, 1.35, .circle),
            (.trigger, .preset(11), "LT", 1.08, 0.42, .capsule),
            (.trackpad, .preset(11), "Trackpad", 1.25, 1, .roundedRectangle),
            (.text, .preset(18), "Text", 1.4, 0.7, .rectangle),
            (.decoration, .preset(18), "Decoration", 2.2, 1.2, .roundedRectangle)
        ]
        for (index, expectation) in expectations.enumerated() {
            let id = String(format: "00000000-0000-0000-0000-0000000008%02d", index + 1)
            let request = try decodeRequest(
                profileObjects: [rawProfile],
                operation: [
                    "type": "element.add", "profileID": profileID.uuidString,
                    "variant": "primary", "elementID": id,
                    "kind": expectation.0.rawValue, "changes": [:]
                ]
            )
            let response = try ThumbleConfigurationBridge.transform(request)
            XCTAssertEqual(response, try ThumbleConfigurationBridge.transform(request))
            let result: GamepadConfigurationProfile = try decoded(response.document.profiles[0])
            let control = try XCTUnwrap(result.customization.customButtons.first { $0.id.uuidString.lowercased() == id })
            XCTAssertEqual(control.controlKind, expectation.0)
            XCTAssertEqual(control.inputID.uuid.uuidString.lowercased(), id)
            XCTAssertEqual(control.label, expectation.2)
            XCTAssertEqual(control.layout.widthScale, expectation.3)
            XCTAssertEqual(control.layout.heightScale, expectation.4)
            XCTAssertEqual(control.layout.shape, expectation.5)
            let mirror = try XCTUnwrap(result.customization.elements.first { $0.id == control.id })
            XCTAssertEqual(mirror.kind, control.controlKind)
            XCTAssertEqual(mirror.layout, control.layout)
            XCTAssertEqual(mirror.label, control.label)
        }
    }

    func testElementSetCoversSafeAppearanceBehaviorAndSemanticPartOutput() throws {
        let elementID = UUID(uuidString: "00000000-0000-0000-0000-0000000008A1")!
        var customization = GamepadCustomization.defaultValue
        try customization.addStandaloneCustomControl(GamepadCustomButton(
            id: elementID,
            label: "Stick",
            controlKind: .joystick,
            joystickMapping: .movement,
            joystickOutputSettings: .defaultValue
        ))
        var rawProfile = try encodedObject(GamepadConfigurationProfile(
            id: profileID,
            name: "Set Element",
            primaryCustomization: customization,
            updatedAt: 1
        ))
        var rawCustomization = try XCTUnwrap(rawProfile["customization"] as? [String: Any])
        rawCustomization["futureCustomization"] = ["kept": true]
        var rawButtons = try XCTUnwrap(rawCustomization["customButtons"] as? [[String: Any]])
        rawButtons[0]["futureControl"] = "kept"
        rawCustomization["customButtons"] = rawButtons
        rawProfile["customization"] = rawCustomization
        let color: [String: Double] = ["red": 0.1, "green": 0.2, "blue": 0.3, "alpha": 0.8]
        let request = try decodeRequest(
            profileObjects: [rawProfile],
            operation: [
                "type": "element.set", "profileID": profileID.uuidString,
                "variant": "primary", "elementID": elementID.uuidString,
                "changes": [
                    "label": "Right Stick", "visualRole": "joystick",
                    "centerX": 0.72, "centerY": 0.66, "widthScale": 1.2, "heightScale": 1.1,
                    "rotationDegrees": 15.0, "zIndex": 10, "isLocationLocked": true,
                    "showsIntegratedLabel": false,
                    "hitInsets": ["top": 10.0, "leading": 12.0, "bottom": 14.0, "trailing": 16.0],
                    "cornerRadii": ["topLeading": 3.0, "topTrailing": 4.0, "bottomTrailing": 5.0, "bottomLeading": 6.0],
                    "shadowStrength": 1.5,
                    "fill": [
                        "kind": "gradient", "type": "linear", "angleDegrees": 45.0,
                        "stops": [["offset": 0.0, "color": color], ["offset": 1.0, "color": ["red": 0.8, "green": 0.7, "blue": 0.6, "alpha": 1.0]]]
                    ],
                    "lightThumbFill": color, "darkThumbOpacity": 0.4,
                    "joystickVisualStyle": "thumbstick",
                    "appearance": ["strokeColor": color, "strokeWidth": 2.0, "pressedScale": 0.9],
                    "icon": ["source": "sf_symbol", "value": "circle.fill"],
                    "haptic": ["style": "rigid", "pattern": "double", "intensity": 0.7, "sharpness": 0.8, "duration": 0.1],
                    "joystickMapping": [
                        "up": ["keyboard": ["keyCode": MacVirtualKey.upArrow, "modifiersRawValue": 0], "gamepadButtons": []],
                        "down": ["keyboard": ["keyCode": MacVirtualKey.downArrow, "modifiersRawValue": 0], "gamepadButtons": []],
                        "left": ["keyboard": ["keyCode": MacVirtualKey.leftArrow, "modifiersRawValue": 0], "gamepadButtons": []],
                        "right": ["keyboard": ["keyCode": MacVirtualKey.rightArrow, "modifiersRawValue": 0], "gamepadButtons": []]
                    ],
                    "joystickSettings": ["analogTarget": "right_stick", "sendsDigitalDirections": false, "deadZone": 0.2, "sensitivity": 1.4, "invertX": true, "invertY": false, "snapToCardinal": true],
                    "output": [
                        "part": "joystick_up",
                        "keyboardEdit": ["action": "set", "sequence": [["key": "W", "modifiers": ["shift"]]]],
                        "gamepadEdit": ["action": "set", "button": "dpadUp"]
                    ]
                ]
            ]
        )
        let response = try ThumbleConfigurationBridge.transform(request)
        let result: GamepadConfigurationProfile = try decoded(response.document.profiles[0])
        let control = try XCTUnwrap(result.customization.customButtons.first { $0.id == elementID })
        XCTAssertEqual(control.label, "Right Stick")
        XCTAssertEqual(control.inputID.uuid, elementID)
        XCTAssertEqual(control.visualRole, .joystick)
        XCTAssertEqual(control.layout.centerX, 0.72)
        XCTAssertEqual(control.layout.fillStyle?.displayName, "Linear")
        XCTAssertEqual(control.layout.lightJoystickKnobColor?.alpha, 0.8)
        XCTAssertEqual(control.layout.darkJoystickKnobColor?.alpha, 0.4)
        XCTAssertEqual(control.layout.visualStyle?.normal.strokeWidth, 2)
        XCTAssertEqual(control.layout.icon?.source, .sfSymbol)
        XCTAssertEqual(control.layout.hapticFeedback?.pattern, .double)
        XCTAssertEqual(control.joystickOutputSettings?.analogTarget, .rightStick)
        XCTAssertEqual(control.joystickOutputSettings?.invertX, true)
        let mirror = try XCTUnwrap(result.customization.elements.first { $0.id == elementID })
        XCTAssertEqual(mirror.layout, control.layout)
        XCTAssertEqual(mirror.joystickMapping, control.joystickMapping)
        XCTAssertEqual(mirror.outputBinding(for: .joystickUp)?.gamepadButtons, [.dpadUp])
        XCTAssertEqual(mirror.outputBinding(for: .joystickUp)?.keyboard?.strokes.first?.keyCode, MacVirtualKey.w)
        let raw = try object(from: response.document.profiles[0])
        let resultCustomization = try XCTUnwrap(raw["customization"] as? [String: Any])
        XCTAssertEqual((resultCustomization["futureCustomization"] as? [String: Bool])?["kept"], true)
        let resultButtons = try XCTUnwrap(resultCustomization["customButtons"] as? [[String: Any]])
        XCTAssertEqual(resultButtons[0]["futureControl"] as? String, "kept")
    }

    func testElementOperationsRejectPassiveOutputCollisionsAndDeferredContent() throws {
        let id = "00000000-0000-0000-0000-0000000008F1"
        let rawProfile = try encodedObject(GamepadConfigurationProfile(
            id: profileID,
            name: "Reject Element",
            primaryCustomization: .defaultValue,
            updatedAt: 1
        ))
        let passive = try decodeRequest(profileObjects: [rawProfile], operation: [
            "type": "element.add", "profileID": profileID.uuidString, "variant": "primary",
            "elementID": id, "kind": "text", "changes": [
                "output": ["part": "primary", "keyboardEdit": ["action": "clear"], "gamepadEdit": ["action": "keep"]]
            ]
        ])
        XCTAssertThrowsError(try ThumbleConfigurationBridge.transform(passive))

        var customization = GamepadCustomization.defaultValue
        try customization.addStandaloneCustomControl(GamepadCustomButton(id: UUID(uuidString: id)!))
        let collisionProfile = try encodedObject(GamepadConfigurationProfile(
            id: profileID, name: "Collision", primaryCustomization: customization, updatedAt: 1
        ))
        XCTAssertThrowsError(try ThumbleConfigurationBridge.transform(decodeRequest(
            profileObjects: [collisionProfile],
            operation: ["type": "element.add", "profileID": profileID.uuidString, "variant": "primary", "elementID": id, "kind": "button", "changes": [:]]
        )))

        for forbidden in [
            ["fillImage": "/tmp/private.png"], ["assetID": "private"],
            ["keyCode": 49], ["path": "/tmp/state"], ["rawJSON": "{}"],
            ["inputID": "custom2"], ["inputID": NSNull()],
            ["joystickMapping": ["up": "up", "down": "down", "left": "left", "right": "right"]]
        ] as [[String: Any]] {
            XCTAssertThrowsError(try decodeRequest(
                profileObjects: [rawProfile],
                operation: ["type": "element.add", "profileID": profileID.uuidString, "variant": "primary", "elementID": id, "kind": "button", "changes": forbidden]
            ))
        }
    }

    func testStyleAppearanceRejectsRawAssetsPathsAndInvalidBounds() throws {
        let rawProfile = try encodedObject(GamepadConfigurationProfile(
            id: profileID,
            name: "Styles",
            primaryCustomization: .defaultValue,
            updatedAt: 1
        ))
        for appearance in [
            ["assetID": "private-image"],
            ["path": "/tmp/private.png"],
            ["icon": ["source": "asset", "value": "private"]],
            ["strokeWidth": 13.0],
            ["haptic": [String: Any]()]
        ] as [[String: Any]] {
            XCTAssertThrowsError(try ThumbleConfigurationBridge.transform(decodeRequest(
                profileObjects: [rawProfile],
                operation: [
                    "type": "style.create", "profileID": profileID.uuidString,
                    "styleID": "invalid-style", "name": "Invalid", "appearance": appearance
                ]
            )))
        }
    }

    func testOperationAndEnvelopeRejectUnknownFields() throws {
        let rawProfile = try encodedObject(GamepadConfigurationProfile(
            id: profileID,
            name: "Bridge",
            primaryCustomization: .defaultValue,
            updatedAt: 1
        ))
        var operationEnvelope = try requestEnvelope(
            profileObjects: [rawProfile],
            operation: ["type": "profile.select", "profileID": profileID.uuidString, "path": "/tmp/state"]
        )
        var data = try JSONSerialization.data(withJSONObject: operationEnvelope, options: [.sortedKeys])
        XCTAssertThrowsError(try JSONDecoder().decode(ThumbleConfigurationBridgeRequest.self, from: data))

        operationEnvelope = try requestEnvelope(
            profileObjects: [rawProfile],
            operation: ["type": "profile.select", "profileID": profileID.uuidString]
        )
        operationEnvelope["shell"] = "echo unsafe"
        data = try JSONSerialization.data(withJSONObject: operationEnvelope, options: [.sortedKeys])
        XCTAssertThrowsError(try JSONDecoder().decode(ThumbleConfigurationBridgeRequest.self, from: data))
    }

    func testProfileDuplicationWithoutMapsDerivesSourceOwnershipNotGlobalMirrors() throws {
        let id = "B6FD297D-7508-4FF4-AFF7-97B3831F6AD0"
        let raw: [String: Any] = ["id": profileID.uuidString, "name": "Owned", "outputMode": "custom",
            "customization": ["elements": [["id": id, "kind": "button", "label": "Owned",
                "output": ["keyboard": ["keyCode": 49, "modifiersRawValue": 8], "gamepadButtons": ["south"]]]]]]
        var envelope = try requestEnvelope(profileObjects: [raw], operation: [
            "type": "profile.duplicate", "profileID": profileID.uuidString,
            "newProfileID": "F5A5CB2B-A218-49D3-A3B4-3158B18B99CC", "name": "Copy"])
        var document = try XCTUnwrap(envelope["document"] as? [String: Any])
        document["keyBindings"] = [id: ["keyCode": 12, "modifiers": 0]]
        document["outputBindings"] = [id: ["keyboard": ["keyCode": 12, "modifiers": 0], "gamepadButtons": ["north"]]]
        envelope["document"] = document
        let request = try JSONDecoder().decode(ThumbleConfigurationBridgeRequest.self, from: JSONSerialization.data(withJSONObject: envelope))
        let response = try ThumbleConfigurationBridge.transform(request)
        let keys = try object(from: response.document.keyBindings)
        let binding = try XCTUnwrap(keys[id] as? [String: Any])
        XCTAssertEqual(binding["keyCode"] as? Int, 49)
        let outputs = try object(from: response.document.outputBindings)
        XCTAssertEqual((outputs[id] as? [String: Any])?["gamepadButtons"] as? [String], ["south"])
    }

    func testBindingReferencesRejectBeforeAnyBridgeMutation() throws {
        let own = "B6FD297D-7508-4FF4-AFF7-97B3831F6AD0"
        let otherProfile = "B16C0A67-B9EA-42CA-966B-9F23A09CDE8B"
        let otherInput = "82782DD6-D823-44AD-B9FC-9655E16160B1"
        let raw: [[String: Any]] = [
            ["id": profileID.uuidString, "name": "Owned", "customization": ["elements": [["id": own, "kind": "button"]]]],
            ["id": otherProfile, "name": "Other", "customization": ["elements": [["id": otherInput, "kind": "button"]]]]
        ]
        let operation: [String: Any] = ["type": "profile.default", "profileID": otherProfile]
        let base = try requestEnvelope(profileObjects: raw, operation: operation)
        for field in ["keyBindings", "outputBindings", "profileKeyBindings", "profileOutputBindings"] {
            var envelope = base
            var document = try XCTUnwrap(envelope["document"] as? [String: Any])
            let value: [String: Any] = field.lowercased().contains("key") ? ["keyCode": 49, "modifiers": 0] : ["gamepadButtons": []]
            document[field] = field.hasPrefix("profile") ? [profileID.uuidString: [otherInput: value]] : [otherInput: value]
            envelope["document"] = document
            let request = try JSONDecoder().decode(ThumbleConfigurationBridgeRequest.self, from: JSONSerialization.data(withJSONObject: envelope))
            XCTAssertThrowsError(try ThumbleConfigurationBridge.transform(request), "accepted foreign owner in \(field)")
        }
        for field in ["keyBindings", "outputBindings", "profileKeyBindings", "profileOutputBindings"] {
            var envelope = base
            var document = try XCTUnwrap(envelope["document"] as? [String: Any])
            let invalid: [String: Any] = [own: "obsolete-binding"]
            document[field] = field.hasPrefix("profile") ? [profileID.uuidString: invalid] : invalid
            envelope["document"] = document
            let request = try JSONDecoder().decode(ThumbleConfigurationBridgeRequest.self, from: JSONSerialization.data(withJSONObject: envelope))
            XCTAssertThrowsError(try ThumbleConfigurationBridge.transform(request), "accepted malformed value in \(field)")
        }
        for field in ["profileKeyBindings", "profileOutputBindings"] {
            for maps: [String: Any] in [
                ["4B6B62C7-367D-44C7-BA78-2AC30E6E22F4": [:]],
                [otherProfile: [:], otherProfile.lowercased(): [:]]
            ] {
                var envelope = base
                var document = try XCTUnwrap(envelope["document"] as? [String: Any])
                document[field] = maps
                envelope["document"] = document
                let request = try JSONDecoder().decode(ThumbleConfigurationBridgeRequest.self, from: JSONSerialization.data(withJSONObject: envelope))
                XCTAssertThrowsError(try ThumbleConfigurationBridge.transform(request), "accepted invalid profile maps")
            }
        }
    }

    private func decodeRequest(
        profileObjects: [[String: Any]],
        operation: [String: Any]
    ) throws -> ThumbleConfigurationBridgeRequest {
        let envelope = try requestEnvelope(profileObjects: profileObjects, operation: operation)
        let data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        return try JSONDecoder().decode(ThumbleConfigurationBridgeRequest.self, from: data)
    }

    private func requestEnvelope(
        profileObjects: [[String: Any]],
        operation: [String: Any]
    ) throws -> [String: Any] {
        [
            "schemaVersion": 1,
            "nowMillis": 1_234,
            "document": [
                "profiles": profileObjects,
                "activeProfileID": profileID.uuidString.lowercased(),
                "defaultProfileID": profileID.uuidString.lowercased(),
                "keyBindings": [:],
                "outputBindings": [:],
                "profileKeyBindings": [:],
                "profileOutputBindings": [:]
            ],
            "operation": operation
        ]
    }

    private func requestWithBindings(
        profile: GamepadConfigurationProfile,
        keys: [KeypadElementID: MacKeyBinding],
        outputs: [KeypadElementID: MacControlOutputBinding],
        operation: [String: Any]
    ) throws -> ThumbleConfigurationBridgeRequest {
        var envelope = try requestEnvelope(
            profileObjects: [try encodedObject(profile)],
            operation: operation
        )
        var document = try XCTUnwrap(envelope["document"] as? [String: Any])
        let rawKeys = try jsonObject(MacConfigurationBindings.rawKeyBindings(keys))
        let rawOutputs = try jsonObject(MacConfigurationBindings.rawOutputs(outputs))
        let id = profile.id.uuidString.lowercased()
        document["keyBindings"] = rawKeys
        document["outputBindings"] = rawOutputs
        document["profileKeyBindings"] = [id: rawKeys]
        document["profileOutputBindings"] = [id: rawOutputs]
        envelope["document"] = document
        return try JSONDecoder().decode(
            ThumbleConfigurationBridgeRequest.self,
            from: JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        )
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }

    private func decoded<T: Decodable>(_ value: ThumbleBridgeJSONValue) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    private func encodedObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func object(from value: ThumbleBridgeJSONValue) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

extension ThumbleConfigurationBridgeTests {
    func testReviewedDesignApplicationPreservesOutputsDefaultsUnknownFieldsAndRejectsStaleTarget() throws {
        var profile = GamepadControllerTemplate.xbox.makeProfile()
        profile.id = profileID
        let originalID = try XCTUnwrap(profile.customization.elements.first?.id)
        let output = KeypadElementOutputBinding(keyboard: KeypadKeyboardBinding(keyCode: 49))
        var customization = profile.customization
        customization.elements[0].output = output
        profile.customization = customization
        var raw = try encodedObject(profile)
        raw["futureProfile"] = ["kept": true]
        var rawCustomization = try XCTUnwrap(raw["customization"] as? [String: Any])
        var elements = try XCTUnwrap(rawCustomization["elements"] as? [[String: Any]])
        elements[0]["futureControl"] = ["kept": true]
        rawCustomization["elements"] = elements
        raw["customization"] = rawCustomization
        let frozen = try JSONDecoder().decode(GamepadConfigurationProfile.self, from: JSONSerialization.data(withJSONObject: raw))
        let content = GamepadControlContentStyle(fontSize: 22, fontWeight: .medium, trackpadFrameVisible: false)
        let style = GamepadControlVisualStyle(normal: .init(content: content))
        let package = ThumbleSkinPackage(manifest: .init(identifier: "com.example.reviewed-design", version: "1.0.0",
            name: "Reviewed Design", author: .init(name: "Test")),
            skin: .init(base: .init(defaultControl: .init(visualStyle: style))))
        let data = try ThumbleSkinPackageCodec.encode(package)
        let operation: [String: Any] = ["type": "design.apply", "profileID": profileID.uuidString,
            "packageBase64": data.base64EncodedString(), "packageSHA256": data.thumbleSHA256,
            "profileSHA256": try ControllerDesignWorkspace.digest(frozen), "evidenceSHA256": String(repeating: "a", count: 64)]
        let request = try decodeRequest(profileObjects: [raw], operation: operation)
        let response = try ThumbleConfigurationBridge.transform(request)
        XCTAssertTrue(response.changed)
        XCTAssertEqual(response.document.activeProfileID, request.document.activeProfileID)
        XCTAssertEqual(response.document.defaultProfileID, request.document.defaultProfileID)
        XCTAssertEqual(response.document.keyBindings, request.document.keyBindings)
        XCTAssertEqual(response.document.outputBindings, request.document.outputBindings)
        let updated: GamepadConfigurationProfile = try decoded(response.document.profiles[0])
        XCTAssertEqual(updated.customization.elements.first?.id, originalID)
        XCTAssertEqual(updated.customization.elements.first?.output, output)
        XCTAssertEqual(updated.skinReference?.identifier, package.manifest.identifier)
        let updatedRaw = try object(from: response.document.profiles[0])
        XCTAssertEqual((updatedRaw["futureProfile"] as? [String: Bool])?["kept"], true)
        let updatedElements = try XCTUnwrap((updatedRaw["customization"] as? [String: Any])?["elements"] as? [[String: Any]])
        XCTAssertEqual((updatedElements[0]["futureControl"] as? [String: Bool])?["kept"], true)
        var stale = operation
        stale["profileSHA256"] = String(repeating: "b", count: 64)
        XCTAssertThrowsError(try ThumbleConfigurationBridge.transform(decodeRequest(profileObjects: [raw], operation: stale)))
        stale = operation
        stale["packageSHA256"] = String(repeating: "b", count: 64)
        XCTAssertThrowsError(try ThumbleConfigurationBridge.transform(decodeRequest(profileObjects: [raw], operation: stale)))
    }
}

extension ThumbleConfigurationBridgeTests {
    func testNativePresentationElementEditPreservesRoutingAndClearsExactly() throws {
        let id = "B6FD297D-7508-4FF4-AFF7-97B3831F6AD0"
        let output: [String: Any] = ["keyboard": ["keyCode": 49, "modifiersRawValue": 0], "gamepadButtons": ["south"]]
        let raw: [String: Any] = ["id": profileID.uuidString, "name": "Presentation", "customization": ["elements": [[
            "id": id, "label": "Legacy", "kind": "button", "layout": ["centerX": 0.5, "centerY": 0.5],
            "output": output, "defaultOutput": output, "futureControl": ["kept": true]
        ]]]]
        let metadata: [String: Any] = ["actionID": "ability.q", "purposeID": "primary", "groupIDs": ["abilities"],
            "legend": "Q", "caption": "Light Binding", "accessibilityName": "Cast Light Binding"]
        let response = try ThumbleConfigurationBridge.transform(decodeRequest(profileObjects: [raw], operation: [
            "type": "element.set", "profileID": profileID.uuidString, "variant": "primary", "elementID": id,
            "changes": ["presentation": metadata]]))
        let edited = try object(from: response.document.profiles[0])
        var rawExpected = raw
        var expectedCustomization = try XCTUnwrap(rawExpected["customization"] as? [String: Any])
        var expectedElements = try XCTUnwrap(expectedCustomization["elements"] as? [[String: Any]])
        var canonicalMetadata = metadata; canonicalMetadata["schemaVersion"] = 1
        expectedElements[0]["presentation"] = canonicalMetadata
        expectedCustomization["elements"] = expectedElements
        rawExpected["customization"] = expectedCustomization
        rawExpected["updatedAt"] = edited["updatedAt"]
        XCTAssertTrue(NSDictionary(dictionary: edited).isEqual(to: rawExpected))
        let decoded = try JSONDecoder().decode(GamepadConfigurationProfile.self, from: JSONSerialization.data(withJSONObject: edited))
        let element = try XCTUnwrap(decoded.customization.elements.first)
        XCTAssertEqual(element.presentation?.legend, "Q")
        XCTAssertEqual(element.label, "Legacy")
        XCTAssertEqual(element.presentation?.actionID, "ability.q")
        XCTAssertEqual(element.presentation?.accessibilityName, "Cast Light Binding")
        let editedCustomization = try XCTUnwrap(edited["customization"] as? [String: Any])
        let editedElements = try XCTUnwrap(editedCustomization["elements"] as? [[String: Any]])
        XCTAssertTrue(NSDictionary(dictionary: try XCTUnwrap(editedElements[0]["output"] as? [String: Any])).isEqual(to: output))
        let copyID = "B6FD297D-7508-4FF4-AFF7-97B3831F6AD1"
        let duplicated = try ThumbleConfigurationBridge.transform(decodeRequest(profileObjects: [edited], operation: [
            "type": "element.duplicate", "profileID": profileID.uuidString, "variant": "primary", "elementIDs": [id],
            "newElementIDs": [copyID], "offsetX": 0.01, "offsetY": 0.01]))
        let copiedProfile = try JSONDecoder().decode(GamepadConfigurationProfile.self,
            from: JSONSerialization.data(withJSONObject: object(from: duplicated.document.profiles[0])))
        XCTAssertEqual(copiedProfile.customization.elements.first { $0.id.uuidString == copyID }?.presentation, element.presentation)
        let cleared = try ThumbleConfigurationBridge.transform(decodeRequest(profileObjects: [edited], operation: [
            "type": "element.set", "profileID": profileID.uuidString, "variant": "primary", "elementID": id,
            "changes": ["clearPresentation": true]]))
        let clearProfile = try JSONDecoder().decode(GamepadConfigurationProfile.self,
            from: JSONSerialization.data(withJSONObject: object(from: cleared.document.profiles[0])))
        XCTAssertNil(clearProfile.customization.elements.first?.presentation)
        XCTAssertEqual(clearProfile.customization.elements.first?.output, element.output)
        XCTAssertEqual(clearProfile.customization.elements.first?.defaultOutput, element.defaultOutput)
        XCTAssertEqual(clearProfile.customization.elements.first?.layout, element.layout)
    }

    func testNativePresentationRejectsUnknownFieldsInvalidTagsTextAndConflictingClear() throws {
        let raw = try encodedObject(GamepadControllerTemplate.xbox.makeProfile())
        let customization = try XCTUnwrap(raw["customization"] as? [String: Any])
        let id = try XCTUnwrap((customization["elements"] as? [[String: Any]])?.first?["id"] as? String)
        let profile = try XCTUnwrap(raw["id"] as? String)
        for metadata: [String: Any] in [["schemaVersion": 2], ["actionID": "Q"], ["groupIDs": ["a", "a"]],
            ["legend": String(repeating: "x", count: 65)], ["caption": "line\nbreak"],
            ["accessibilityName": " "], ["legend": "Q", "output": [:]]] {
            XCTAssertThrowsError(try ThumbleConfigurationBridge.transform(decodeRequest(profileObjects: [raw], operation: [
                "type": "element.set", "profileID": profile, "variant": "primary", "elementID": id,
                "changes": ["presentation": metadata]])))
        }
        XCTAssertThrowsError(try ThumbleConfigurationBridge.transform(decodeRequest(profileObjects: [raw], operation: [
            "type": "element.set", "profileID": profile, "variant": "primary", "elementID": id,
            "changes": ["presentation": ["legend": "Q"], "clearPresentation": true]])))
    }
}
