import CoreGraphics
import Darwin
import SwiftUI
import XCTest

final class ThumbleCLISmokeTestSuite: XCTestCase {
    func testRenamePreservesCompatibilityIdentifiers() {
        XCTAssertEqual(ThumbleMacIPC.appDefaultsDomain, "com.codybontecou.PocketPadMac")
        XCTAssertEqual(ThumbleMacIPC.commandNotificationName, "com.codybontecou.PocketPadMac.cliCommand")
        XCTAssertEqual(PairingPayload.payloadType, "pocketpad-pair")
        XCTAssertEqual(PairingPayload.defaultServiceType, "_pocketpad._tcp")
        XCTAssertEqual(ThumbleKeypadConfigurationExport.schemaIdentifier, "com.codybontecou.pocketpad.keypad-configuration")
        XCTAssertEqual(ThumbleMacIPC.captureLogPath, "/tmp/thumble-capture.jsonl")
        XCTAssertEqual(ThumbleMacIPC.legacyThumbConsoleCaptureLogPath, "/tmp/thumbconsole-capture.jsonl")
        XCTAssertEqual(ThumbleMacIPC.legacyThumbleCaptureLogPath, "/tmp/pocketpad-capture.jsonl")
    }

    func testKeypadConfigurationExportSchemaRoundTrip() throws {
        var customization = GamepadCustomization.defaultValue
        customization.accentStyle = .blue
        customization.labelOverrides[.preset(5)] = "Fire"
        let profile = GamepadConfigurationProfile(name: "Arcade Test", customization: customization)
        let export = ThumbleKeypadConfigurationExport(
            exportedAt: 123_456,
            profiles: [profile],
            activeProfileID: profile.id,
            defaultProfileID: profile.id
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(export)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"schema\":\"\(ThumbleKeypadConfigurationExport.schemaIdentifier)\""))
        XCTAssertTrue(json.contains("\"version\":\(ThumbleKeypadConfigurationExport.currentVersion)"))

        let decoded = try JSONDecoder().decode(ThumbleKeypadConfigurationExport.self, from: data)
        XCTAssertEqual(decoded.schema, ThumbleKeypadConfigurationExport.schemaIdentifier)
        XCTAssertEqual(decoded.version, ThumbleKeypadConfigurationExport.currentVersion)
        XCTAssertEqual(decoded.exportedAt, 123_456)
        XCTAssertEqual(decoded.profiles.map(\.normalized), [profile.normalized])
        XCTAssertEqual(decoded.activeProfileID, profile.id)
        XCTAssertEqual(decoded.defaultProfileID, profile.id)
    }

    func testControlsOwnUUIDsWithoutRoutingSlots() throws {
        var customization = GamepadCustomization.blankCanvas
        customization.addCustomButton()
        customization.addJoystick()
        customization.addTrigger()
        customization.addTrackpad()
        let elements = customization.normalized.elements
        XCTAssertEqual(elements.count, 4)
        XCTAssertEqual(Set(elements.map(\.id)).count, 4)
        for element in elements {
            XCTAssertEqual(element.inputID.uuid, element.id)
            XCTAssertFalse(DefaultKeypadElements.ids.contains(element.inputID))
        }
        let json = String(decoding: try JSONEncoder().encode(customization), as: UTF8.self)
        for field in ["legacySlot", "mappedButton", "builtInButton"] {
            XCTAssertFalse(json.contains("\"\(field)\""))
        }
    }

    func testElementOnlySetupsNeverSynthesizeStarterControls() throws {
        let first = KeypadElement(label: "Same label", output: KeypadElementOutputBinding(), defaultOutput: KeypadElementOutputBinding(keyboard: KeypadKeyboardBinding(keyCode: 49)))
        let second = KeypadElement(label: "Same label", output: KeypadElementOutputBinding(keyboard: KeypadKeyboardBinding(keyCode: 0)))
        let customization = GamepadCustomization(elements: [first, second]).normalized
        XCTAssertEqual(Set(customization.elements.map(\.id)), [first.id, second.id])
        let decoded = try JSONDecoder().decode(GamepadCustomization.self, from: JSONEncoder().encode(customization)).normalized
        XCTAssertEqual(Set(decoded.elements.map(\.id)), [first.id, second.id])
        XCTAssertTrue(try XCTUnwrap(decoded.elements.first { $0.id == first.id }?.output).isEmpty)
        XCTAssertEqual(Set(decoded.resolvedControls(in: CGSize(width: 852, height: 393)).compactMap(\.elementID)), [first.id, second.id])
        let empty = try JSONDecoder().decode(GamepadCustomization.self, from: Data("{\"elements\":[]}".utf8)).normalized
        XCTAssertTrue(empty.elements.isEmpty)
        XCTAssertTrue(try JSONDecoder().decode(GamepadCustomization.self, from: JSONEncoder().encode(empty)).elements.isEmpty)
        XCTAssertThrowsError(try JSONDecoder().decode(GamepadCustomization.self, from: Data("{}".utf8)))
        let rawElement = try JSONSerialization.jsonObject(with: JSONEncoder().encode(first))
        let duplicate = try JSONSerialization.data(withJSONObject: ["elements": [rawElement, rawElement]])
        XCTAssertThrowsError(try JSONDecoder().decode(GamepadCustomization.self, from: duplicate))
        let unboundStick = KeypadElement(label: "Unbound stick", kind: .joystick)
        let stickSetup = GamepadCustomization(elements: [unboundStick]).normalized
        XCTAssertNil(stickSetup.elements.first?.joystickMapping)
        XCTAssertTrue(try XCTUnwrap(stickSetup.elements.first).partOutputs.isEmpty)
    }

    func testElementPartEncodingHasDeterministicCanonicalOrder() throws {
        let id = UUID()
        var first = KeypadElement(id: id, label: "Stick", kind: .joystick)
        for direction in GamepadJoystickDirection.allCases {
            first.partOutputs[KeypadElementInputPart(direction: direction)] = GamepadJoystickMapping.movement[direction]
        }
        var second = KeypadElement(id: id, label: "Stick", kind: .joystick)
        for direction in GamepadJoystickDirection.allCases.reversed() {
            second.partOutputs[KeypadElementInputPart(direction: direction)] = GamepadJoystickMapping.movement[direction]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(first)
        XCTAssertEqual(data, try encoder.encode(second))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let parts = try XCTUnwrap(object["partOutputs"] as? [Any])
        XCTAssertEqual(stride(from: 0, to: parts.count, by: 2).compactMap { parts[$0] as? String }, ["joystick_down", "joystick_left", "joystick_right", "joystick_up"])
    }

    func testClearedStarterOutputSurvivesHideAndShow() throws {
        var customization = GamepadCustomization()
        let id = KeypadElementID.preset(5)
        let index = try XCTUnwrap(customization.elements.firstIndex { $0.inputID == id })
        customization.elements[index].setOutputBinding(nil)
        var layout = customization.buttonCustomization(for: id)
        layout.isHidden = true
        customization.setButtonCustomization(layout, for: id)
        customization = customization.normalized
        layout.isHidden = false
        customization.setButtonCustomization(layout, for: id)
        customization = customization.normalized
        XCTAssertTrue(try XCTUnwrap(customization.elements.first { $0.inputID == id }?.output).isEmpty)
    }

    func testNamedInputsAndRoutingFieldsAreRejectedOnImport() throws {
        for name in ["jump", "attack", "dash", "focus", "custom1", "up"] {
            XCTAssertThrowsError(try JSONDecoder().decode(KeypadElementID.self, from: JSONEncoder().encode(name)))
        }
        let element = KeypadElement(label: "Jump")
        let encoded = try JSONEncoder().encode(element)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for field in ["legacySlot", "mappedButton", "builtInButton", "inputID"] {
            var invalid = object
            invalid[field] = NSNull()
            XCTAssertThrowsError(try JSONDecoder().decode(KeypadElement.self, from: JSONSerialization.data(withJSONObject: invalid)))
        }
        let profile = GamepadConfigurationProfile(name: "Current", customization: GamepadCustomization(elements: [element]))
        let export = ThumbleKeypadConfigurationExport(profiles: [profile], activeProfileID: profile.id, defaultProfileID: profile.id)
        var exportObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(export)) as? [String: Any])
        for version in 1..<ThumbleKeypadConfigurationExport.currentVersion {
            exportObject["version"] = version
            XCTAssertThrowsError(try JSONDecoder().decode(ThumbleKeypadConfigurationExport.self, from: JSONSerialization.data(withJSONObject: exportObject)))
        }
    }

    func testNativeFileImportRejectsObsoleteEnvelopeAndWholeDomainBeforeMutation() throws {
        let owner = UUID(uuidString: "81C296ED-309D-4F05-BB11-F5A2E2027801")!
        let profile = GamepadConfigurationProfile(name: "Owned", customization: GamepadCustomization(elements: [
            KeypadElement(id: owner, label: "Same", output: KeypadElementOutputBinding(keyboard: KeypadKeyboardBinding(keyCode: 49), gamepadButtons: [.south]))
        ]))
        let envelope = MacConfigurationBindings.KeypadExportEnvelope(profiles: [profile], activeProfileID: profile.id, defaultProfileID: nil, profileKeyBindings: [:], profileOutputBindings: [:])
        let baseline = try JSONEncoder().encode(envelope)
        XCTAssertEqual(try MacConfigurationBindings.decodeKeypadImport(data: baseline, sourceName: "owned").profiles.map(\.id), [profile.id])
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: baseline) as? [String: Any])
        var invalids: [(String, [String: Any])] = []
        for version in [1, 2, 3] {
            var invalid = root; invalid["version"] = version
            invalids.append(("obsolete version \(version)", invalid))
        }
        for key in ["schema", "version", "activeProfileID"] {
            var invalid = root; invalid.removeValue(forKey: key)
            invalids.append(("missing \(key)", invalid))
        }
        var duplicate = root; duplicate["profiles"] = (root["profiles"] as! [Any]) + (root["profiles"] as! [Any])
        invalids.append(("duplicate profiles", duplicate))
        for key in ["activeProfileID", "defaultProfileID"] {
            var invalid = root; invalid[key] = UUID().uuidString
            invalids.append(("dangling \(key)", invalid))
        }
        let binding: [String: Any] = ["keyCode": 49, "modifiers": 0]
        let output: [String: Any] = ["keyboard": binding, "gamepadButtons": []]
        for (field, value) in [("profileKeyBindings", binding), ("profileOutputBindings", output)] {
            for id in ["jump", UUID().uuidString] {
                var invalid = root; invalid[field] = [profile.id.uuidString: [id: value]]
                invalids.append(("\(field) unowned \(id)", invalid))
            }
            var invalid = root; invalid[field] = [UUID().uuidString: [owner.uuidString: value]]
            invalids.append(("\(field) orphan profile", invalid))
            invalid[field] = [profile.id.uuidString: [:], profile.id.uuidString.lowercased(): [:]]
            invalids.append(("\(field) duplicate profile case", invalid))
        }
        for (label, invalid) in invalids {
            let data = try JSONSerialization.data(withJSONObject: invalid)
            XCTAssertThrowsError(try MacConfigurationBindings.decodeKeypadImport(data: data, sourceName: "invalid"), label)
        }
        // Failed envelope parsing must not retry a plausible raw-profile subset.
        var mixed = root
        mixed["version"] = 3
        let rawProfile = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        mixed.merge(rawProfile, uniquingKeysWith: { _, profileValue in profileValue })
        XCTAssertThrowsError(try MacConfigurationBindings.decodeKeypadImport(data: JSONSerialization.data(withJSONObject: mixed), sourceName: "mixed"))
        var generated = GeneratedGameKeypadProfile(requestedGameName: "Owned", resolvedGameName: "Owned", profile: profile, keyBindings: [KeypadElementID(UUID()): GeneratedKeyBindingSpec(key: "Space")], source: "test", confidence: .high)
        XCTAssertThrowsError(try MacConfigurationBindings.decodeKeypadImport(data: JSONEncoder().encode(generated), sourceName: "generated orphan"))
        generated.keyBindings = [:]
        XCTAssertEqual(try MacConfigurationBindings.decodeKeypadImport(data: JSONEncoder().encode(generated), sourceName: "generated").profiles.map(\.id), [profile.id])
    }

    func testNativeResetAllRestoresOwnedDefaultsOnEveryExecutableCanvas() throws {
        let controls = [
            KeypadElement(label: "Same", output: KeypadElementOutputBinding(keyboard: KeypadKeyboardBinding(keyCode: 49), gamepadButtons: [.south]), defaultOutput: KeypadElementOutputBinding(keyboard: KeypadKeyboardBinding(keyCode: 12), gamepadButtons: [.west])),
            KeypadElement(label: "Same", output: KeypadElementOutputBinding(keyboard: KeypadKeyboardBinding(keyCode: 48), gamepadButtons: [.east]), defaultOutput: KeypadElementOutputBinding(keyboard: KeypadKeyboardBinding(keyCode: 13), gamepadButtons: [.north])),
            KeypadElement(label: "Same", output: KeypadElementOutputBinding(keyboard: KeypadKeyboardBinding(keyCode: 0), gamepadButtons: [.west]), defaultOutput: KeypadElementOutputBinding())
        ]
        var original = GamepadConfigurationProfile(name: "Three canvases", customization: GamepadCustomization(elements: [controls[0]]))
        original.landscapeCustomization = GamepadCustomization(elements: [controls[1]])
        original.portraitCustomization = GamepadCustomization(elements: [controls[2]])
        for orientation in [GamepadEditorDeviceOrientation.landscape, .portrait] {
            var profile = original
            profile.customization.deviceCanvas = GamepadDeviceCanvas(frameID: GamepadEditorDeviceFrame(spec: profile.customization.deviceCanvas.editorDeviceFrame.spec, orientation: orientation).id)
            let outputs = MacConfigurationBindings.resetAllOutputs(in: &profile)
            XCTAssertEqual(Set(outputs.keys), Set(controls.map(\.inputID)))
            for customization in [profile.customization, try XCTUnwrap(profile.landscapeCustomization), try XCTUnwrap(profile.portraitCustomization)] {
                let element = try XCTUnwrap(customization.elements.first)
                XCTAssertEqual(element.output, element.defaultOutput, "reset must include off-canvas UUIDs")
            }
            XCTAssertEqual(profile.outputMode, .keyboard)
            XCTAssertEqual(original.customization.elements[0].output, controls[0].output, "reset must preserve value semantics")
        }
    }

    func testNativeTargetMapsNeverMergePreviousProfileOrResurrectClears() {
        let sourceID = UUID()
        let targetID = UUID()
        let sourceInput = KeypadElementID()
        let targetInput = KeypadElementID()
        let sourceKey = MacKeyBinding(keyCode: 49, modifiers: [])
        let targetKey = MacKeyBinding(keyCode: 48, modifiers: [])
        let sourceOutput = MacControlOutputBinding(keyboard: sourceKey, gamepadButtons: [.south])
        let targetOutput = MacControlOutputBinding(keyboard: targetKey, gamepadButtons: [.east])
        let keys = [sourceID: [sourceInput: sourceKey], targetID: [targetInput: targetKey]]
        let outputs = [sourceID: [sourceInput: sourceOutput], targetID: [targetInput: targetOutput]]
        XCTAssertEqual(MacConfigurationBindings.resolvedKeyBindings(for: targetID, in: keys, fallback: [sourceInput: sourceKey]), [targetInput: targetKey])
        XCTAssertEqual(MacConfigurationBindings.resolvedOutputBindings(for: targetID, in: outputs, fallback: [sourceInput: sourceOutput]), [targetInput: targetOutput])
        XCTAssertTrue(MacConfigurationBindings.resolvedKeyBindings(for: targetID, in: [targetID: [:]], fallback: [targetInput: targetKey]).isEmpty)
        XCTAssertTrue(MacConfigurationBindings.resolvedOutputBindings(for: targetID, in: [targetID: [:]], fallback: [targetInput: targetOutput]).isEmpty)
        let clear = MacControlOutputBinding()
        XCTAssertEqual(MacConfigurationBindings.resolvedOutputBindings(for: targetID, in: [targetID: [targetInput: clear]], fallback: [sourceInput: sourceOutput]), [targetInput: clear])
    }

    func testNativeFileImportDoesNotDiscardArtifactIntegrity() throws {
        let rootURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try Data(contentsOf: rootURL.appendingPathComponent("Host/fixtures/profile-artifact/v1.json"))
        XCTAssertNoThrow(try MacConfigurationBindings.decodeKeypadImport(data: fixture, sourceName: "valid artifact"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture) as? [String: Any])
        for field in ["artifactVersion", "contentHash", "catalogRevision"] {
            var invalid = root
            invalid[field] = field == "artifactVersion" ? 2 : NSNull()
            XCTAssertThrowsError(try MacConfigurationBindings.decodeKeypadImport(data: JSONSerialization.data(withJSONObject: invalid), sourceName: field))
        }
        var tampered = root
        var profiles = root["profiles"] as! [[String: Any]]
        profiles[0]["name"] = "Tampered name"
        tampered["profiles"] = profiles
        XCTAssertThrowsError(try MacConfigurationBindings.decodeKeypadImport(data: JSONSerialization.data(withJSONObject: tampered), sourceName: "tampered"))
    }

    func testSharedExportDecodeNeverRepairsProfileReferences() throws {
        let profile = GamepadConfigurationProfile(name: "Empty", customization: .blankCanvas)
        let value = ThumbleKeypadConfigurationExport(profiles: [profile], activeProfileID: profile.id, defaultProfileID: nil)
        let data = try JSONEncoder().encode(value)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var duplicate = root; duplicate["profiles"] = (root["profiles"] as! [Any]) + (root["profiles"] as! [Any])
        XCTAssertThrowsError(try JSONDecoder().decodeUnique(ThumbleKeypadConfigurationExport.self, from: JSONSerialization.data(withJSONObject: duplicate)))
        for key in ["activeProfileID", "defaultProfileID"] {
            var invalid = root; invalid[key] = UUID().uuidString
            XCTAssertThrowsError(try JSONDecoder().decodeUnique(ThumbleKeypadConfigurationExport.self, from: JSONSerialization.data(withJSONObject: invalid)))
        }
        var missing = root; missing.removeValue(forKey: "activeProfileID")
        XCTAssertThrowsError(try JSONDecoder().decodeUnique(ThumbleKeypadConfigurationExport.self, from: JSONSerialization.data(withJSONObject: missing)))
    }

    func testControlBarItemsNormalizeAndRoundTrip() throws {
        var customization = GamepadCustomization.defaultValue
        customization.controlBarItems = [.home, .settings, .home, .connectionAction]

        XCTAssertEqual(customization.normalized.controlBarItems, [.home, .settings, .connectionAction])

        let data = try JSONEncoder().encode(customization)
        let decoded = try JSONDecoder().decode(GamepadCustomization.self, from: data)
        XCTAssertEqual(decoded.normalized.controlBarItems, [.home, .settings, .connectionAction])
    }

    func testControlBarItemAppearancesNormalizeAndRoundTrip() throws {
        var customization = GamepadCustomization.defaultValue
        var settingsAppearance = GamepadButtonCustomization(
            centerX: 0.2,
            centerY: 0.8,
            widthScale: 1.35,
            heightScale: 1.2,
            shape: .capsule,
            fillColor: GamepadRGBAColor(hexString: "#112233"),
            icon: .sfSymbol("slider.horizontal.3"),
            cornerRadius: 14,
            isLocationLocked: true
        )
        settingsAppearance.hapticStyle = .medium
        customization.setControlBarItemCustomization(settingsAppearance, for: .settings)

        let normalizedAppearance = customization.normalized.controlBarItemCustomization(for: .settings)
        XCTAssertNil(normalizedAppearance.centerX)
        XCTAssertNil(normalizedAppearance.centerY)
        XCTAssertFalse(normalizedAppearance.isLocationLocked)
        XCTAssertEqual(normalizedAppearance.widthScale, 1.35, accuracy: 0.001)
        XCTAssertEqual(normalizedAppearance.heightScale, 1.2, accuracy: 0.001)
        XCTAssertEqual(normalizedAppearance.icon?.value, "slider.horizontal.3")
        XCTAssertEqual(normalizedAppearance.hapticStyle, .medium)

        let data = try JSONEncoder().encode(customization)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("controlBarItemCustomizations"))

        let wireDecoded = try JSONDecoder().decode(GamepadCustomization.self, from: data)
        let wireAppearance = wireDecoded.controlBarItemCustomization(for: .settings)
        XCTAssertNil(wireAppearance.centerX)
        XCTAssertNil(wireAppearance.centerY)
        XCTAssertFalse(wireAppearance.isLocationLocked)

        let decoded = wireDecoded.normalized
        XCTAssertEqual(decoded.controlBarItemCustomization(for: .settings), normalizedAppearance)
        XCTAssertFalse(GamepadCustomization.defaultValue.hasSamePresentation(as: decoded))

        var reordered = decoded
        reordered.moveControlBarItem(.settings, to: 0)
        XCTAssertEqual(reordered.normalized.controlBarItems.first, .settings)
        XCTAssertEqual(reordered.controlBarItemCustomization(for: .settings), normalizedAppearance)

        reordered.removeControlBarItem(.settings)
        XCTAssertFalse(reordered.normalized.controlBarItems.contains(.settings))
        XCTAssertTrue(reordered.normalized.controlBarItemCustomizations.isEmpty)
    }

    func testControlBarItemIdentityRoundTrips() throws {
        let identity = GamepadControlIdentity.controlBarItem(.connectionAction)
        let data = try JSONEncoder().encode(identity)
        XCTAssertEqual(try JSONDecoder().decode(GamepadControlIdentity.self, from: data), identity)
    }

    func testStyledProfilePayloadEncodesOnNetworkQueue() throws {
        var customization = GamepadCustomization.defaultValue.normalized
        let visualStyle = GamepadControlVisualStyle(
            normal: GamepadControlStateStyle(
                fillStyle: .solid(GamepadRGBAColor(hexString: "#F7F4F8") ?? .defaultValue),
                foregroundColor: GamepadRGBAColor(hexString: "#7C61A8") ?? .defaultValue,
                strokeColor: GamepadRGBAColor(hexString: "#FFFFFF") ?? .defaultValue,
                strokeWidth: 1,
                shadowColor: GamepadRGBAColor(hexString: "#00000066") ?? .defaultValue,
                shadowRadius: 8
            ),
            pressed: GamepadControlStateStyle(opacity: 0.86, scale: 0.94)
        )

        for button in DefaultKeypadElements.ids {
            var layout = customization.buttonCustomization(for: button)
            layout.visualStyle = visualStyle
            customization.setButtonCustomization(layout, for: button)
        }

        let profile = GamepadConfigurationProfile(name: "Styled Network Payload", customization: customization)
        let message = ControllerMessage(
            type: .gamepadProfiles,
            gamepadCustomization: customization,
            gamepadProfiles: [profile],
            gamepadProfileID: profile.id,
            defaultGamepadProfileID: profile.id
        )
        let queue = DispatchQueue(label: "Thumble.Tests.NetworkStack")
        let data = try queue.sync {
            try ControllerWireCodec.encode(message, using: JSONEncoder())
        }

        XCTAssertFalse(data.isEmpty)
        let decoded = try ControllerWireCodec.decode(data, using: JSONDecoder())
        XCTAssertEqual(decoded.gamepadProfiles?.first?.customization.normalized.buttonCustomizations.count, DefaultKeypadElements.ids.count)
    }

    func testAddedJoystickDefaultsToKeyboardDigitalDirections() throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-00000000D1D1")!
        var customization = GamepadCustomization.blankCanvas
        customization.addJoystick(id: id)

        let joystick = try XCTUnwrap(customization.normalized.customButtons.first(where: { $0.id == id })?.normalized)
        XCTAssertEqual(joystick.label, "Arrow Keys")
        XCTAssertEqual(joystick.inputID.uuid, joystick.id)
        XCTAssertEqual(joystick.joystickMapping, .movement)
        XCTAssertEqual(joystick.joystickOutputSettings, Optional(GamepadJoystickOutputSettings.defaultValue.normalized))

        let element = try XCTUnwrap(customization.normalized.elements.first { $0.id == id && $0.kind == .joystick })
        XCTAssertEqual(element.joystickMapping, .movement)
        XCTAssertEqual(element.joystickOutputSettings, Optional(GamepadJoystickOutputSettings.defaultValue.normalized))
    }

    func testCaptureEventRoundTripsThroughJSONCodec() throws {
        let event = ThumbleCaptureEvent(
            sequence: 42,
            recordedAt: 123_456,
            uptimeNanoseconds: 789,
            kind: "button",
            source: "iPhone UDP",
            messageType: .button,
            button: .preset(5),
            state: .down,
            binding: "Space",
            inputSequence: 7,
            pressIdentifier: 99,
            latencyMS: 4,
            processingToCompletionMS: 0.75,
            bindingLookupMS: 0.025,
            outputInjectionMS: 0.5,
            postInjectionMS: 0.125,
            outputDeferred: false,
            pressedButtons: [.preset(5)],
            detail: "smoke"
        )

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(ThumbleCaptureEvent.self, from: data)
        XCTAssertEqual(decoded.sequence, 42)
        XCTAssertEqual(decoded.kind, "button")
        XCTAssertEqual(decoded.source, "iPhone UDP")
        XCTAssertEqual(decoded.messageType, .button)
        XCTAssertEqual(decoded.button, .preset(5))
        XCTAssertEqual(decoded.state, .down)
        XCTAssertEqual(decoded.binding, "Space")
        XCTAssertEqual(decoded.inputSequence, 7)
        XCTAssertEqual(decoded.pressIdentifier, 99)
        XCTAssertEqual(decoded.latencyMS, 4)
        XCTAssertEqual(decoded.processingToCompletionMS, 0.75)
        XCTAssertEqual(decoded.bindingLookupMS, 0.025)
        XCTAssertEqual(decoded.outputInjectionMS, 0.5)
        XCTAssertEqual(decoded.postInjectionMS, 0.125)
        XCTAssertEqual(decoded.outputDeferred, false)
        XCTAssertEqual(decoded.pressedButtons, [.preset(5)])
        XCTAssertEqual(decoded.detail, "smoke")
    }

    func testRuntimeStatusOutputStageTelemetryRoundTrips() throws {
        let profileID = UUID(uuidString: "00000000-0000-0000-0000-00000000A111")!
        let status = ThumbleMacRuntimeStatus(
            updatedAt: 123,
            statusText: "Connected",
            isRunning: true,
            isClientConnected: true,
            localURLs: ["ws://127.0.0.1:8765"],
            pairingCode: "123456",
            isPairingPending: false,
            pendingPairingClientName: nil,
            clientName: "iPhone",
            lastHeartbeatMilliseconds: 100,
            lastReceivedEvent: "jump down",
            estimatedLatencyMS: 8,
            inputPipelineP50MS: 0.5,
            inputPipelineP95MS: 2.0,
            inputPipelineP99MS: 4.0,
            inputProcessingP95MS: 1.5,
            bindingLookupP95MS: 0.05,
            outputInjectionP50MS: 0.25,
            outputInjectionP95MS: 0.75,
            outputInjectionP99MS: 1.25,
            postInjectionP95MS: 0.2,
            pressedButtons: [.preset(5)],
            missedButtonFrames: 0,
            ignoredButtonEdges: 0,
            recoveredButtonEdges: 0,
            accessibilityTrusted: true,
            port: 8765,
            activeGamepadProfileID: profileID,
            defaultGamepadProfileID: profileID
        )

        let data = try JSONEncoder().encode(status)
        let decoded = try JSONDecoder().decode(ThumbleMacRuntimeStatus.self, from: data)
        XCTAssertEqual(decoded.inputProcessingP95MS, 1.5)
        XCTAssertEqual(decoded.bindingLookupP95MS, 0.05)
        XCTAssertEqual(decoded.outputInjectionP50MS, 0.25)
        XCTAssertEqual(decoded.outputInjectionP95MS, 0.75)
        XCTAssertEqual(decoded.outputInjectionP99MS, 1.25)
        XCTAssertEqual(decoded.postInjectionP95MS, 0.2)
    }

    func testElementRuntimeCommandPayloadRoundTripsAndRejectsNamedInputs() throws {
        let input = KeypadElementInputID(
            elementID: UUID(uuidString: "00000000-0000-0000-0000-00000000E2E2")!,
            part: .joystickRight
        )
        let payload = ThumbleMacCLICommandPayload(
            command: .testDown,
            elementInput: input,
            reason: "Editor test"
        )

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(ThumbleMacCLICommandPayload.self, from: data)
        XCTAssertEqual(decoded.command, .testDown)
        XCTAssertEqual(decoded.elementInput, input)
        XCTAssertNil(decoded.button)
        XCTAssertEqual(decoded.reason, "Editor test")

        let legacyData = Data(#"{"command":"testUp","button":"jump","reason":"Legacy test"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ThumbleMacCLICommandPayload.self, from: legacyData))
    }

    func testElementInputStorageKeyRejectsUnknownExplicitPart() throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-00000000E2E3")!
        XCTAssertEqual(KeypadElementInputID(storageKey: id.uuidString), KeypadElementInputID(elementID: id))
        XCTAssertEqual(
            KeypadElementInputID(storageKey: "\(id.uuidString)#joystick_right"),
            KeypadElementInputID(elementID: id, part: .joystickRight)
        )
        XCTAssertNil(KeypadElementInputID(storageKey: "\(id.uuidString)#joystik_right"))
        XCTAssertNil(KeypadElementInputID(storageKey: "\(id.uuidString)#"))
    }

    func testRuntimeStatusElementAndEditorDeliveryFieldsRoundTripBackwardCompatibly() throws {
        let profileID = UUID(uuidString: "00000000-0000-0000-0000-00000000A222")!
        let input = KeypadElementInputID(
            elementID: UUID(uuidString: "00000000-0000-0000-0000-00000000E3E3")!,
            part: .triggerDigital
        )
        let status = ThumbleMacRuntimeStatus(
            updatedAt: 456,
            statusText: "Connected",
            isRunning: true,
            isClientConnected: true,
            localURLs: [],
            pairingCode: "654321",
            isPairingPending: false,
            pendingPairingClientName: nil,
            clientName: "iPhone",
            lastHeartbeatMilliseconds: nil,
            lastReceivedEvent: "element down",
            estimatedLatencyMS: nil,
            pressedButtons: [],
            pressedElementInputs: [input],
            editorDeliveryState: .sent,
            editorDeliveryDetail: "Keypad layout sent to the connected iPhone",
            editorDeliveryUpdatedAt: 455,
            missedButtonFrames: 0,
            ignoredButtonEdges: 0,
            recoveredButtonEdges: 0,
            accessibilityTrusted: true,
            port: 8765,
            activeGamepadProfileID: profileID,
            defaultGamepadProfileID: profileID
        )

        let data = try JSONEncoder().encode(status)
        let decoded = try JSONDecoder().decode(ThumbleMacRuntimeStatus.self, from: data)
        XCTAssertEqual(decoded.pressedElementInputs, [input])
        XCTAssertEqual(decoded.editorDeliveryState, .sent)
        XCTAssertEqual(decoded.editorDeliveryDetail, "Keypad layout sent to the connected iPhone")
        XCTAssertEqual(decoded.editorDeliveryUpdatedAt, 455)

        var legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacyObject["pressedElementInputs"] = nil
        legacyObject["editorDeliveryState"] = nil
        legacyObject["editorDeliveryDetail"] = nil
        legacyObject["editorDeliveryUpdatedAt"] = nil
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacyDecoded = try JSONDecoder().decode(ThumbleMacRuntimeStatus.self, from: legacyData)
        XCTAssertNil(legacyDecoded.pressedElementInputs)
        XCTAssertNil(legacyDecoded.editorDeliveryState)
        XCTAssertNil(legacyDecoded.editorDeliveryDetail)
        XCTAssertNil(legacyDecoded.editorDeliveryUpdatedAt)
    }

    func testEditorDeliveryStatesRoundTrip() throws {
        for state in [ThumbleEditorDeliveryState.localSave, .sending, .sent, .offline, .failure] {
            let data = try JSONEncoder().encode(state)
            XCTAssertEqual(try JSONDecoder().decode(ThumbleEditorDeliveryState.self, from: data), state)
        }
    }

    func testElementInputMessageRoundTrips() throws {
        let elementID = UUID(uuidString: "00000000-0000-0000-0000-00000000E1E1")!
        let message = ControllerMessage(
            type: .elementInput,
            elementID: elementID,
            elementPart: .primary,
            state: .down,
            timestamp: ControllerWireCodec.inputSequenceTimestamp(for: 42, pressIdentifier: 7),
            sentAt: 123_456
        )
        let data = try ControllerWireCodec.encode(message, using: JSONEncoder())
        let decoded = try ControllerWireCodec.decode(data, using: JSONDecoder())
        XCTAssertEqual(decoded.type, .elementInput)
        XCTAssertEqual(decoded.elementID, elementID)
        XCTAssertEqual(decoded.elementPart, .primary)
        XCTAssertEqual(decoded.state, .down)
        XCTAssertEqual(decoded.sentAt, 123_456)
        XCTAssertEqual(ControllerWireCodec.inputSequenceNumber(from: decoded), 42)
        XCTAssertEqual(ControllerWireCodec.inputPressIdentifier(from: decoded), 7)
    }

    func testKeypadProfileOutputModeDefaultsToKeyboardForDeclaredControls() throws {
        let newProfile = GamepadConfigurationProfile(name: "Keyboard Setup", customization: .defaultValue)
        XCTAssertEqual(newProfile.outputMode, .keyboard)

        let legacyJSON = """
        {
          "id": "00000000-0000-0000-0000-00000000ABCD",
          "name": "Declared Setup",
          "customization": {"elements": []}
        }
        """
        let legacyProfile = try JSONDecoder().decode(GamepadConfigurationProfile.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(legacyProfile.outputMode, .keyboard)
        XCTAssertTrue(legacyProfile.customization.elements.isEmpty)
    }

    func testCommandClickedProfileSelectionExcludesActiveByDefault() {
        let activeID = UUID(uuidString: "00000000-0000-0000-0000-00000000A001")!
        let firstClickedID = UUID(uuidString: "00000000-0000-0000-0000-00000000B001")!
        let secondClickedID = UUID(uuidString: "00000000-0000-0000-0000-00000000C001")!
        let orderedIDs = [activeID, firstClickedID, secondClickedID]

        var explicitSelection = GamepadProfileSelectionLogic.toggledExplicitSelection(
            firstClickedID,
            currentExplicitSelection: [],
            orderedProfileIDs: orderedIDs
        )
        explicitSelection = GamepadProfileSelectionLogic.toggledExplicitSelection(
            secondClickedID,
            currentExplicitSelection: explicitSelection,
            orderedProfileIDs: orderedIDs
        )

        XCTAssertEqual(explicitSelection, [firstClickedID, secondClickedID])
        XCTAssertEqual(
            GamepadProfileSelectionLogic.actionIDs(
                explicitSelection: explicitSelection,
                activeID: activeID,
                orderedProfileIDs: orderedIDs
            ),
            [firstClickedID, secondClickedID]
        )
    }

    func testProfileActionsFallBackToActiveWhenNothingIsCommandSelected() {
        let activeID = UUID(uuidString: "00000000-0000-0000-0000-00000000A002")!
        let otherID = UUID(uuidString: "00000000-0000-0000-0000-00000000B002")!

        XCTAssertEqual(
            GamepadProfileSelectionLogic.actionIDs(
                explicitSelection: [],
                activeID: activeID,
                orderedProfileIDs: [activeID, otherID]
            ),
            [activeID]
        )
    }

    func testActiveProfileMustBeExplicitlyCommandSelectedForBulkActions() {
        let activeID = UUID(uuidString: "00000000-0000-0000-0000-00000000A003")!
        let otherID = UUID(uuidString: "00000000-0000-0000-0000-00000000B003")!
        let orderedIDs = [activeID, otherID]

        var explicitSelection = GamepadProfileSelectionLogic.toggledExplicitSelection(
            activeID,
            currentExplicitSelection: [],
            orderedProfileIDs: orderedIDs
        )
        explicitSelection = GamepadProfileSelectionLogic.toggledExplicitSelection(
            otherID,
            currentExplicitSelection: explicitSelection,
            orderedProfileIDs: orderedIDs
        )

        XCTAssertEqual(
            GamepadProfileSelectionLogic.actionIDs(
                explicitSelection: explicitSelection,
                activeID: activeID,
                orderedProfileIDs: orderedIDs
            ),
            [activeID, otherID]
        )
    }

    func testKeypadProfileLaunchTargetRoundTrips() throws {
        let iconData = Data([0x89, 0x50, 0x4E, 0x47])
        let target = GamepadProfileLaunchTarget(
            displayName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            filePath: "/Applications/Safari.app",
            iconPNGData: iconData,
            attachedAt: 123_456
        )
        let profile = GamepadConfigurationProfile(
            name: "Browser Setup",
            customization: .defaultValue,
            launchTarget: target
        )

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(GamepadConfigurationProfile.self, from: data)
        XCTAssertEqual(decoded.launchTarget?.displayName, "Safari")
        XCTAssertEqual(decoded.launchTarget?.bundleIdentifier, "com.apple.Safari")
        XCTAssertEqual(decoded.launchTarget?.filePath, "/Applications/Safari.app")
        XCTAssertEqual(decoded.launchTarget?.iconPNGData, iconData)
        XCTAssertEqual(decoded.launchTarget?.attachedAt, 123_456)
    }

    func testKeypadConfigurationExportFilenameSanitizesProfileNames() {
        XCTAssertEqual(
            ThumbleKeypadConfigurationExport.suggestedFilename(activeProfileName: "My Arcade / Setup"),
            "Thumble-My-Arcade-Setup.json"
        )
    }

    func testKeypadConfigurationExportRejectsEmptyProfileLists() {
        let json = """
        {
          "schema": "\(ThumbleKeypadConfigurationExport.schemaIdentifier)",
          "version": 1,
          "profiles": []
        }
        """
        XCTAssertThrowsError(try JSONDecoder().decode(ThumbleKeypadConfigurationExport.self, from: Data(json.utf8)))
    }

    func testCornerRadiiPreserveValuesBeyondRenderedBounds() {
        let largeRadius: CGFloat = 999
        let uniform = GamepadButtonCustomization(
            shape: .roundedRectangle,
            cornerRadius: largeRadius
        ).normalized
        XCTAssertEqual(uniform.cornerRadius, Optional(largeRadius))

        let uneven = GamepadButtonCustomization(
            shape: .roundedRectangle,
            cornerRadii: GamepadCornerRadii(
                topLeading: largeRadius,
                topTrailing: 320,
                bottomTrailing: 128,
                bottomLeading: 512
            )
        ).normalized
        XCTAssertEqual(uneven.cornerRadii?.topLeading, Optional(largeRadius))
        XCTAssertEqual(uneven.cornerRadii?.topTrailing, Optional(CGFloat(320)))
        XCTAssertEqual(uneven.cornerRadii?.bottomTrailing, Optional(CGFloat(128)))
        XCTAssertEqual(uneven.cornerRadii?.bottomLeading, Optional(CGFloat(512)))
    }

    func testCornerRadiiStillClampNegativeAndNonFiniteValues() {
        let negative = GamepadButtonCustomization(
            shape: .roundedRectangle,
            cornerRadius: -20
        ).normalized
        XCTAssertEqual(negative.cornerRadius, Optional(CGFloat(0)))

        let invalid = GamepadButtonCustomization(
            shape: .roundedRectangle,
            cornerRadii: GamepadCornerRadii(
                topLeading: .nan,
                topTrailing: .infinity,
                bottomTrailing: -.infinity,
                bottomLeading: -4
            )
        ).normalized
        XCTAssertEqual(invalid.cornerRadii?.topLeading, Optional(CGFloat(0)))
        XCTAssertEqual(invalid.cornerRadii?.topTrailing, Optional(CGFloat(0)))
        XCTAssertEqual(invalid.cornerRadii?.bottomTrailing, Optional(CGFloat(0)))
        XCTAssertEqual(invalid.cornerRadii?.bottomLeading, Optional(CGFloat(0)))
    }

    func testTrackpadCustomizationRoundTrips() throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-00000000A11D")!
        var customization = GamepadCustomization.blankCanvas
        customization.addTrackpad(id: id)
        guard let trackpad = customization.normalized.customButtons.first(where: { $0.id == id }) else {
            XCTFail("trackpad should be present")
            return
        }
        XCTAssertTrue(trackpad.isTrackpad)
        XCTAssertEqual(trackpad.label, "Trackpad")
        XCTAssertEqual(trackpad.trackpadSettings, Optional(GamepadTrackpadSettings.defaultValue.normalized))

        let data = try JSONEncoder().encode(customization.normalized)
        let decoded = try JSONDecoder().decode(GamepadCustomization.self, from: data).normalized
        XCTAssertEqual(decoded.customButtons.first(where: { $0.id == id })?.controlKind, .trackpad)
        XCTAssertEqual(decoded.customButtons.first(where: { $0.id == id })?.trackpadSettings, Optional(GamepadTrackpadSettings.defaultValue.normalized))

        let controls = decoded.resolvedControls(in: CGSize(width: 874, height: 402))
        XCTAssertTrue(controls.contains { $0.id == .custom(id) && $0.isTrackpad })
    }

    func testTextElementRoundTripsAsPassiveLayer() throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-00000000A11E")!
        var customization = GamepadCustomization.blankCanvas
        customization.addText(
            id: id,
            text: "Z",
            centerX: 0.72,
            centerY: 0.66,
            widthScale: 1.2,
            heightScale: 0.8
        )

        var normalized = customization.normalized
        let elementIndex = try XCTUnwrap(normalized.elements.firstIndex(where: { $0.id == id }))
        normalized.elements[elementIndex].output = KeypadElementOutputBinding(
            keyboard: KeypadKeyboardBinding(keyCode: 6)
        )
        normalized = normalized.normalized

        let text = try XCTUnwrap(normalized.customButtons.first(where: { $0.id == id })?.normalized)
        XCTAssertTrue(text.isText)
        XCTAssertTrue(text.isDecoration)
        XCTAssertEqual(text.label, "Z")
        XCTAssertFalse(text.layout.showsIntegratedLabel)
        XCTAssertEqual(text.layout.shadowStrength, 0)
        XCTAssertNil(normalized.elements.first(where: { $0.id == id })?.output)

        let control = try XCTUnwrap(
            normalized.resolvedControls(in: CGSize(width: 874, height: 402)).first { $0.id == .custom(id) }
        )
        XCTAssertTrue(control.isText)
        XCTAssertTrue(control.isDecoration)

        let data = try JSONEncoder().encode(normalized)
        let decoded = try JSONDecoder().decode(GamepadCustomization.self, from: data).normalized
        XCTAssertEqual(decoded.customButtons.first(where: { $0.id == id })?.controlKind, .text)
        XCTAssertEqual(decoded.customButtons.first(where: { $0.id == id })?.label, "Z")
    }

    func testIntegratedLabelVisibilityRoundTripsWithoutChangingLegacyDecodeDefault() throws {
        let hidden = GamepadButtonCustomization(showsIntegratedLabel: false)
        let roundTripped = try JSONDecoder().decode(
            GamepadButtonCustomization.self,
            from: JSONEncoder().encode(hidden)
        )
        XCTAssertFalse(roundTripped.showsIntegratedLabel)

        let legacy = Data(#"{"widthScale":1,"heightScale":1,"shadowStrength":1,"isLocationLocked":false,"isHidden":false}"#.utf8)
        let decoded = try JSONDecoder().decode(GamepadButtonCustomization.self, from: legacy)
        XCTAssertTrue(decoded.showsIntegratedLabel)
    }

    func testJoystickThumbColorCustomizationRoundTrips() throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-00000000BEEF")!
        var customization = GamepadCustomization.blankCanvas
        customization.addJoystick(id: id)
        guard let index = customization.customButtons.firstIndex(where: { $0.id == id }) else {
            XCTFail("joystick should be present")
            return
        }

        let thumbColor = GamepadRGBAColor(hexString: "#F8FAFC")!
        customization.customButtons[index].layout.joystickKnobColor = thumbColor
        customization.customButtons[index].layout.joystickVisualStyle = .thumbstick

        let data = try JSONEncoder().encode(customization.normalized)
        let decoded = try JSONDecoder().decode(GamepadCustomization.self, from: data).normalized
        let joystick = decoded.customButtons.first(where: { $0.id == id })?.normalized

        XCTAssertEqual(joystick?.controlKind, .joystick)
        XCTAssertEqual(joystick?.layout.joystickKnobColor, thumbColor.normalized)
        XCTAssertEqual(joystick?.layout.joystickKnobColor(for: .light), thumbColor.normalized)
        XCTAssertEqual(joystick?.layout.joystickVisualStyle, .thumbstick)
    }

    func testImportRejectsUndeclaredCustomMirrorsInsteadOfSynthesizingControls() throws {
        let data = Data(#"{"elements":[],"customButtons":[{"id":"6B39FBA0-5BB8-4CD7-9E8E-4B780D29391F","label":"Undeclared","controlKind":"button","layout":{}}]}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(GamepadCustomization.self, from: data))
    }

    func testDirectGenerationAuthorsOwnedOutputsAndResetDefaultsWithoutInstallation() throws {
        let first = UUID(uuidString: "68CF7BC8-C78E-48E5-9F8E-2D75D694E98D")!
        let second = UUID(uuidString: "FDAD6EB1-33FB-49EA-9355-04A047DEB744")!
        let generated = GameKeypadGenerator.generate(from: AgentKeypadSpec(gameName: "Owned", controls: [
            AgentKeypadControlSpec(id: first.uuidString, label: "Same", key: "Space", modifiers: ["Control"]),
            AgentKeypadControlSpec(id: second.uuidString, label: "Same", key: "C", modifiers: ["Shift"])
        ]))
        XCTAssertEqual(Set(generated.profile.customization.elements.map(\.id)), [first, second])
        let expected = [first: KeypadKeyboardBinding(keyCode: 49, modifiersRawValue: 8), second: KeypadKeyboardBinding(keyCode: 8, modifiersRawValue: 2)]
        for element in generated.profile.customization.elements {
            XCTAssertEqual(element.output?.keyboard, expected[element.id])
            XCTAssertEqual(element.defaultOutput?.keyboard, expected[element.id])
        }
        let roundTrip = try JSONDecoder().decode(GamepadConfigurationProfile.self, from: JSONEncoder().encode(generated.profile))
        for element in roundTrip.customization.elements {
            XCTAssertEqual(element.output?.keyboard, expected[element.id])
            XCTAssertEqual(element.defaultOutput?.keyboard, expected[element.id])
        }
    }

    func testGenerationNeverInheritsOutputsFromStarterAppearanceUUIDs() throws {
        let generated = GameKeypadGenerator.generate(from: AgentKeypadSpec(gameName: "Appearance IDs", controls: [
            AgentKeypadControlSpec(id: KeypadElementID.preset(5).rawValue, label: "Same", key: "Tab"),
            AgentKeypadControlSpec(id: KeypadElementID.preset(6).rawValue, label: "Same", key: ""),
            AgentKeypadControlSpec(id: KeypadElementID.preset(7).rawValue, label: "Same", key: "Space", controlKind: .text)
        ]))
        let elements = generated.profile.customization.elements
        let first = try XCTUnwrap(elements.first { $0.inputID == .preset(5) })
        let second = try XCTUnwrap(elements.first { $0.inputID == .preset(6) })
        let passive = try XCTUnwrap(elements.first { $0.inputID == .preset(7) })
        XCTAssertEqual(first.output, KeypadElementOutputBinding(keyboard: KeypadKeyboardBinding(keyCode: 48)))
        XCTAssertEqual(first.defaultOutput, first.output)
        XCTAssertEqual(second.output, KeypadElementOutputBinding())
        XCTAssertEqual(second.defaultOutput, second.output)
        XCTAssertNil(passive.output)
        XCTAssertNil(passive.defaultOutput)
        XCTAssertEqual(Set(generated.keyBindings.keys), [.preset(5)])
    }

    func testDirectGeneratedDefaultsRemainIndependentOfConfiguredOutputAndMode() throws {
        let id = UUID(uuidString: "C720BBAB-FF9B-413F-8991-AD0C3B71FA8C")!
        var profile = GameKeypadGenerator.generate(from: AgentKeypadSpec(gameName: "Owned", controls: [
            AgentKeypadControlSpec(id: id.uuidString, label: "Control", key: "Space", modifiers: ["Control"])
        ])).profile
        let expected = KeypadElementOutputBinding(keyboard: KeypadKeyboardBinding(keyCode: 49, modifiersRawValue: 8))
        profile.customization.elements[0].setOutputBinding(
            KeypadElementOutputBinding(keyboard: KeypadKeyboardBinding(keyCode: 48), gamepadButtons: [.south]), for: .primary
        )
        for mode in GamepadProfileOutputMode.allCases {
            profile.outputMode = mode
            XCTAssertEqual(profile.customization.elements[0].defaultOutput, expected)
            XCTAssertEqual(profile.recommendedMacOutputBindings[KeypadElementID(id)]?.sharedBinding, expected)
            XCTAssertEqual(profile.configuredMacOutputBindings[KeypadElementID(id)]?.keyboard?.keyCode, 48)
        }
        let copyID = UUID(uuidString: "F5A5CB2B-A218-49D3-A3B4-3158B18B99CC")!
        _ = try profile.customization.duplicateControls([.custom(id)], normalizedOffset: CGSize(width: 0.03, height: 0.04), canvasSize: CGSize(width: 874, height: 402), newElementIDs: [copyID])
        let copy = try XCTUnwrap(profile.customization.elements.first { $0.id == copyID })
        XCTAssertEqual(copy.output, profile.customization.elements.first { $0.id == id }?.output)
        XCTAssertEqual(copy.defaultOutput, expected)
        profile.customization.elements[0].output = KeypadElementOutputBinding()
        XCTAssertEqual(profile.customization.elements.first { $0.id == copyID }?.output, copy.output)
    }

    func testDirectAuthoringRetainsRepeatedRequestedUUIDControlsWithAnExplicitNotice() throws {
        let firstID = UUID(uuidString: "68CF7BC8-C78E-48E5-9F8E-2D75D694E98D")!
        let laterID = UUID(uuidString: "E8197FBC-7085-4DEC-8257-EA2B5276BF71")!
        let data = Data("""
        {"gameName":"Explicit Authoring","controls":[
          {"id":"68cf7bc8-c78e-48e5-9f8e-2d75d694e98d","label":"First","key":"Space"},
          {"id":"68CF7BC8-C78E-48E5-9F8E-2D75D694E98D","label":"Second","key":"C"},
          {"id":"E8197FBC-7085-4DEC-8257-EA2B5276BF71","label":"Later","key":"W"}
        ]}
        """.utf8)
        let spec = try JSONDecoder().decodeUnique(AgentKeypadSpec.self, from: data)
        for candidate in [spec, AgentKeypadSpec(gameName: spec.gameName, controls: spec.controls)] {
            let generated = GameKeypadGenerator.generate(from: candidate)
            let elements = generated.profile.customization.elements
            XCTAssertEqual(elements.count, 3)
            XCTAssertEqual(Set(elements.map(\.id)).count, 3)
            XCTAssertEqual(elements.first?.id, firstID)
            XCTAssertEqual(elements.last?.id, laterID)
            guard let second = elements.first(where: { $0.label == "Second" }) else {
                XCTFail("Explicit authoring silently discarded a requested control")
                continue
            }
            XCTAssertNotEqual(second.id, firstID)
            XCTAssertNotEqual(second.id, laterID)
            XCTAssertEqual(second.output?.keyboard?.keyCode, 8)
            XCTAssertEqual(second.defaultOutput, second.output)
            XCTAssertEqual(generated.keyBindings[KeypadElementID(second.id)]?.key, "C")
            XCTAssertTrue(generated.notes.contains(where: { $0.contains("duplicate") && $0.contains("fresh UUID") }))
            var invalidSaved = try XCTUnwrap(JSONSerialization.jsonObject(
                with: JSONEncoder().encode(generated.profile)
            ) as? [String: Any])
            var rawCustomization = try XCTUnwrap(invalidSaved["customization"] as? [String: Any])
            var rawElements = try XCTUnwrap(rawCustomization["elements"] as? [[String: Any]])
            rawElements[1]["id"] = firstID.uuidString
            rawCustomization["elements"] = rawElements
            invalidSaved["customization"] = rawCustomization
            XCTAssertThrowsError(try JSONDecoder().decodeUnique(
                GamepadConfigurationProfile.self, from: JSONSerialization.data(withJSONObject: invalidSaved)
            ))
        }
    }

    func testDirectSpecializedGenerationReportsDropsAndKeepsOnlyDeclaredBindingOwners() throws {
        let capacities: [(GamepadCustomControlKind, Int)] = [
            (.button, GamepadCustomization.maximumCustomButtons),
            (.joystick, GamepadCustomization.maximumJoysticks),
            (.trigger, GamepadCustomization.maximumTriggers),
            (.trackpad, GamepadCustomization.maximumTrackpads)
        ]
        for (kind, capacity) in capacities {
            let controls = (0...capacity).map { ordinal in
                AgentKeypadControlSpec(
                    id: UUID().uuidString,
                    label: "Control \(ordinal)",
                    key: "Space",
                    controlKind: kind
                )
            }
            let baseline = GameKeypadGenerator.generate(from: AgentKeypadSpec(
                gameName: "Within Capacity", controls: Array(controls.prefix(capacity))
            ))
            XCTAssertNoThrow(try MacConfigurationBindings.decodeKeypadImport(
                data: JSONEncoder().encode(baseline), sourceName: "Within Capacity"
            ))
            let generated = GameKeypadGenerator.generate(from: AgentKeypadSpec(
                gameName: "Capacity \(kind.rawValue)", controls: controls
            ))
            let owners = Set(generated.profile.customization.elements.map(\.id))
            XCTAssertEqual(owners.count, capacity, kind.rawValue)
            XCTAssertEqual(Set(generated.keyBindings.keys.map(\.uuid)), owners, kind.rawValue)
            XCTAssertTrue(generated.notes.contains(where: {
                $0.contains("dropped") && (kind == .button || $0.contains(kind.rawValue)) && $0.contains("capacity")
            }), "Missing explicit \(kind.rawValue) capacity notice")
            if kind == .button {
                XCTAssertThrowsError(try JSONDecoder().decodeUnique(
                    AgentKeypadSpec.self,
                    from: JSONEncoder().encode(AgentKeypadSpec(gameName: "Invalid Input", controls: controls))
                ))
            }
            let data = try JSONEncoder().encode(generated)
            do {
                let imported = try MacConfigurationBindings.decodeKeypadImport(data: data, sourceName: "Capacity")
                XCTAssertEqual(Set(imported.profiles[0].customization.elements.map(\.id)), owners)
                let keys = try XCTUnwrap(imported.profileKeyBindings[imported.profiles[0].id.uuidString])
                XCTAssertEqual(Set(keys.keys.compactMap(UUID.init(uuidString:))), owners)
            } catch {
                XCTFail("Generated \(kind.rawValue) artifact is not importable: \(error.localizedDescription)")
            }
        }
    }

    func testAgentGenerationKeeps128IndependentDeclaredControls() throws {
        let controls: [[String: Any]] = (0..<128).map { ordinal in
            ["id": String(format: "43A49CCA-9165-448F-8DF1-%012X", ordinal), "label": "Same", "key": "Space"]
        }
        let data = try JSONSerialization.data(withJSONObject: ["gameName": "Dense", "controls": controls])
        let spec = try JSONDecoder().decode(AgentKeypadSpec.self, from: data)
        let generated = GameKeypadGenerator.generate(from: spec)
        XCTAssertEqual(generated.profile.customization.elements.count, 128)
        XCTAssertEqual(Set(generated.profile.customization.elements.map(\.id)).count, 128)
        XCTAssertEqual(generated.keyBindings.count, 128)
        let declared = Set(generated.profile.customization.elements.map(\.inputID))
        XCTAssertEqual(declared, Set(generated.keyBindings.keys))
        let overLimit = try JSONSerialization.data(withJSONObject: ["gameName": "Dense", "controls": controls + [controls[0]]])
        XCTAssertThrowsError(try JSONDecoder().decode(AgentKeypadSpec.self, from: overLimit))
    }

    func testAgentJoystickThumbColorSpecGeneratesCustomJoystick() throws {
        let json = """
        {
          "gameName": "Joystick Color Test",
          "controls": [
            {
              "label": "Move",
              "key": "W",
              "kind": "joystick",
              "fill": "#111827",
              "thumbFill": "#F8FAFC",
              "joystickStyle": "thumbstick",
              "joystickMapping": {
                "up": {"keyboard": {"keyCode": 13, "modifiersRawValue": 0}, "gamepadButtons": []},
                "down": {"keyboard": {"keyCode": 1, "modifiersRawValue": 0}, "gamepadButtons": []},
                "left": {"keyboard": {"keyCode": 0, "modifiersRawValue": 0}, "gamepadButtons": []},
                "right": {"keyboard": {"keyCode": 2, "modifiersRawValue": 0}, "gamepadButtons": []}
              }
            }
          ]
        }
        """

        let spec = try JSONDecoder().decode(AgentKeypadSpec.self, from: Data(json.utf8))
        let generated = GameKeypadGenerator.generate(from: spec)
        guard let joystick = generated.profile.customization.customButtons.first?.normalized else {
            XCTFail("generated profile should include a custom joystick")
            return
        }

        XCTAssertTrue(joystick.isJoystick)
        XCTAssertEqual(joystick.layout.fillColor, GamepadRGBAColor(hexString: "#111827")!.normalized)
        XCTAssertEqual(joystick.layout.joystickKnobColor, GamepadRGBAColor(hexString: "#F8FAFC")!.normalized)
        XCTAssertEqual(joystick.layout.joystickVisualStyle, .thumbstick)
        XCTAssertEqual(joystick.layout.widthScale, 0.58, accuracy: 0.001)
    }

    func testAgentTrackpadSensitivitySpecGeneratesCustomTrackpad() throws {
        let json = """
        {
          "gameName": "Trackpad Sensitivity Test",
          "controls": [
            {
              "label": "Aim Pad",
              "key": "Space",
              "kind": "trackpad",
              "sensitivity": 2.5,
              "scrollSensitivity": 1.75,
              "tapToClick": false,
              "twoFingerScroll": true,
              "naturalScroll": false
            }
          ]
        }
        """

        let spec = try JSONDecoder().decode(AgentKeypadSpec.self, from: Data(json.utf8))
        let generated = GameKeypadGenerator.generate(from: spec)
        guard let trackpad = generated.profile.customization.customButtons.first?.normalized else {
            XCTFail("generated profile should include a custom trackpad")
            return
        }

        XCTAssertTrue(trackpad.isTrackpad)
        XCTAssertEqual(trackpad.label, "Aim Pad")
        XCTAssertEqual(trackpad.layout.centerX, Optional(CGFloat(0.50)))
        XCTAssertEqual(trackpad.layout.centerY, Optional(CGFloat(0.58)))
        XCTAssertEqual(trackpad.layout.widthScale, CGFloat(1.25))
        XCTAssertEqual(trackpad.layout.cornerRadius, Optional(CGFloat(18)))
        XCTAssertEqual(trackpad.trackpadSettings?.sensitivity, CGFloat(2.5))
        XCTAssertEqual(trackpad.trackpadSettings?.scrollSensitivity, CGFloat(1.75))
        XCTAssertEqual(trackpad.trackpadSettings?.tapToClick, false)
        XCTAssertEqual(trackpad.trackpadSettings?.twoFingerScroll, true)
        XCTAssertEqual(trackpad.trackpadSettings?.naturalScrolling, false)
        XCTAssertEqual(generated.keyBindings[trackpad.inputID]?.key, "Space")
    }

    func testDesignMetadataLayerOrderControlsResolvedZOrder() throws {
        var customization = GamepadCustomization.defaultValue
        customization.addCustomButton(id: UUID(uuidString: "00000000-0000-0000-0000-00000000CAFE")!)
        customization.designMetadata = GamepadDesignMetadata(
            layerOrder: [.custom(UUID(uuidString: "00000000-0000-0000-0000-00000000CAFE")!), .builtin(.preset(5))]
        )

        let controls = customization.normalized.resolvedControls(in: CGSize(width: 874, height: 402))
        let jumpIndex = controls.firstIndex { $0.id == .builtin(.preset(5)) }
        let customIndex = controls.firstIndex { $0.id == .custom(UUID(uuidString: "00000000-0000-0000-0000-00000000CAFE")!) }
        XCTAssertNotNil(jumpIndex)
        XCTAssertNotNil(customIndex)
        XCTAssertLessThan(customIndex!, jumpIndex!)
    }

    func testControlZIndexOverridesLayerOrderForResolvedZOrder() throws {
        let backID = UUID(uuidString: "00000000-0000-0000-0000-00000000D111")!
        let frontID = UUID(uuidString: "00000000-0000-0000-0000-00000000D222")!
        var customization = GamepadCustomization.blankCanvas
        customization.addCustomButton(id: backID)
        customization.addCustomButton(id: frontID)
        customization.customButtons[0].layout.zIndex = 50
        customization.customButtons[1].layout.zIndex = -10
        customization.designMetadata = GamepadDesignMetadata(layerOrder: [.custom(backID), .custom(frontID)])

        let controls = customization.normalized.resolvedControls(in: CGSize(width: 874, height: 402))
        let backIndex = controls.firstIndex { $0.id == .custom(backID) }
        let frontIndex = controls.firstIndex { $0.id == .custom(frontID) }
        XCTAssertNotNil(backIndex)
        XCTAssertNotNil(frontIndex)
        XCTAssertLessThan(frontIndex!, backIndex!)
        XCTAssertEqual(GamepadButtonCustomization(zIndex: 250).zIndex, 100)
        XCTAssertEqual(GamepadButtonCustomization(zIndex: -250).zIndex, -100)
    }

    func testGroupedLayerOperationsMoveChildrenAsBlock() throws {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-00000000A111")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-00000000B222")!
        let thirdID = UUID(uuidString: "5D84EBB4-F748-4981-85D2-A99C4262292D")!
        var customization = GamepadCustomization.blankCanvas
        customization.addCustomButton(id: firstID)
        customization.addCustomButton(id: secondID)
        customization.addCustomButton(id: thirdID)
        customization.designMetadata = GamepadDesignMetadata(
            layerOrder: [.custom(firstID), .custom(secondID), .custom(thirdID)],
            groups: [GamepadLayerGroup(name: "Pair", children: [.custom(firstID), .custom(secondID)])]
        )

        customization.bringLayersForward([.custom(firstID), .custom(secondID)])
        XCTAssertEqual(
            Array(customization.orderedControlIdentitiesForDesign.prefix(3)),
            [.custom(thirdID), .custom(firstID), .custom(secondID)]
        )

        customization.sendLayersToBack([.custom(firstID), .custom(secondID)])
        XCTAssertEqual(
            Array(customization.orderedControlIdentitiesForDesign.prefix(2)),
            [.custom(firstID), .custom(secondID)]
        )
    }

    func testStyleTokenPresentationOverridesLegacyAppearance() throws {
        let style = GamepadStyleToken(
            id: "soul-orb",
            name: "Soul Orb",
            visualStyle: GamepadControlVisualStyle(
                normal: GamepadControlStateStyle(
                    fillStyle: .solid(GamepadRGBAColor(hexString: "#F8FAFC")!),
                    foregroundColor: GamepadRGBAColor(hexString: "#7C61A8")!,
                    strokeColor: GamepadRGBAColor(hexString: "#38BDF8")!,
                    strokeWidth: 3,
                    shadowColor: GamepadRGBAColor(hexString: "#000000", alpha: 0.12)!,
                    shadowRadius: 6,
                    shadowX: 1,
                    shadowY: 2,
                    shadows: [
                        GamepadControlShadowStyle(color: GamepadRGBAColor(hexString: "#FFFFFF", alpha: 0.9)!, radius: 12, x: -6, y: -6),
                        GamepadControlShadowStyle(color: GamepadRGBAColor(hexString: "#9B91AA", alpha: 0.24)!, radius: 20, x: 8, y: 9)
                    ],
                    glowColor: GamepadRGBAColor(hexString: "#0EA5E9")!,
                    glowRadius: 12,
                    innerShadowColor: GamepadRGBAColor(hexString: "#B8B2C2")!,
                    innerShadowRadius: 5,
                    innerShadowX: 1,
                    innerShadowY: 2,
                    highlightColor: GamepadRGBAColor(hexString: "#FFFFFF")!,
                    highlightRadius: 8,
                    highlightX: -4,
                    highlightY: -4,
                    highlightOpacity: 0.45,
                    bevelHighlightColor: GamepadRGBAColor(hexString: "#FFFFFF")!,
                    bevelShadowColor: GamepadRGBAColor(hexString: "#C7C0CC")!,
                    bevelWidth: 1.5
                ),
                pressed: GamepadControlStateStyle(fillStyle: .solid(GamepadRGBAColor(hexString: "#0EA5E9")!)),
                icon: .sfSymbol("circle.hexagongrid.fill"),
                hapticStyle: .medium
            )
        )
        var layout = GamepadButtonCustomization(fillColor: GamepadRGBAColor(hexString: "#111827")!, styleID: "soul-orb")
        var customization = GamepadCustomization.defaultValue
        customization.styleLibrary = GamepadStyleLibrary(styles: [style])
        customization.setButtonCustomization(layout, for: .preset(8))

        let control = customization.resolvedControls(in: CGSize(width: 874, height: 402)).first { $0.id == .builtin(.preset(8)) }!
        let normal = customization.resolvedPresentation(for: control, state: .normal, scheme: .dark)
        XCTAssertEqual(normal.fillStyle.representativeColor, GamepadRGBAColor(hexString: "#F8FAFC")!.normalized)
        XCTAssertEqual(normal.foregroundColor, GamepadRGBAColor(hexString: "#7C61A8")!.normalized)
        XCTAssertEqual(normal.strokeColor, GamepadRGBAColor(hexString: "#38BDF8")!.normalized)
        XCTAssertEqual(normal.strokeWidth, CGFloat(3))
        XCTAssertEqual(normal.shadowRadius, CGFloat(6))
        XCTAssertEqual(normal.shadowX, CGFloat(1))
        XCTAssertEqual(normal.shadowY, CGFloat(2))
        XCTAssertEqual(normal.shadows.count, 2)
        XCTAssertEqual(normal.shadows.first?.radius, CGFloat(12))
        XCTAssertEqual(normal.innerShadowColor, GamepadRGBAColor(hexString: "#B8B2C2")!.normalized)
        XCTAssertEqual(normal.innerShadowRadius, CGFloat(5))
        XCTAssertEqual(normal.innerShadowX, CGFloat(1))
        XCTAssertEqual(normal.innerShadowY, CGFloat(2))
        XCTAssertEqual(normal.highlightColor, GamepadRGBAColor(hexString: "#FFFFFF")!.normalized)
        XCTAssertEqual(normal.highlightRadius, CGFloat(8))
        XCTAssertEqual(normal.highlightX, CGFloat(-4))
        XCTAssertEqual(normal.highlightY, CGFloat(-4))
        XCTAssertEqual(normal.highlightOpacity, CGFloat(0.45))
        XCTAssertEqual(normal.bevelHighlightColor, GamepadRGBAColor(hexString: "#FFFFFF")!.normalized)
        XCTAssertEqual(normal.bevelShadowColor, GamepadRGBAColor(hexString: "#C7C0CC")!.normalized)
        XCTAssertEqual(normal.bevelWidth, CGFloat(1.5))
        XCTAssertEqual(normal.icon?.value, "circle.hexagongrid.fill")
        XCTAssertEqual(normal.hapticStyle, .medium)
        XCTAssertEqual(normal.hapticFeedback.style, .medium)
        XCTAssertEqual(normal.hapticFeedback.pattern, .single)

        let pressed = customization.resolvedPresentation(for: control, state: .pressed, scheme: .dark)
        XCTAssertEqual(pressed.fillStyle.representativeColor, GamepadRGBAColor(hexString: "#0EA5E9")!.normalized)

        let data = try JSONEncoder().encode(customization.normalized)
        let decoded = try JSONDecoder().decode(GamepadCustomization.self, from: data).normalized
        XCTAssertEqual(decoded.styleLibrary.styles.first?.id, "soul-orb")
        layout = decoded.buttonCustomization(for: .preset(8))
        XCTAssertEqual(layout.styleID, "soul-orb")
    }

    func testAgentRichStyleSpecGeneratesIconAndPressedFill() throws {
        let json = """
        {
          "gameName": "Rich Style Test",
          "controls": [
            {
              "label": "Focus",
              "key": "F",
              "id": "BC770D48-78F4-45B6-BBF4-96C10B551E5F",
              "fill": "#111827",
              "pressedFill": "#38BDF8",
              "stroke": "#F8FAFC",
              "strokeWidth": 2,
              "foreground": "#7C61A8",
              "shadows": [
                { "color": { "red": 1, "green": 1, "blue": 1, "alpha": 0.9 }, "radius": 12, "x": -6, "y": -6 },
                { "color": { "red": 0.61, "green": 0.57, "blue": 0.67, "alpha": 0.24 }, "radius": 20, "x": 8, "y": 9 }
              ],
              "innerShadow": "#B8B2C2",
              "innerShadowRadius": 5,
              "highlight": "#FFFFFF",
              "highlightOpacity": 0.45,
              "highlightX": -4,
              "highlightY": -4,
              "bevelHighlight": "#FFFFFF",
              "bevelShadow": "#C7C0CC",
              "bevelWidth": 1.5,
              "sfSymbol": "sparkles",
              "hapticStyle": "heavy",
              "hapticPattern": "double",
              "hapticIntensity": 0.73,
              "hapticSharpness": 0.88,
              "hapticDurationMS": 90
            }
          ]
        }
        """

        let spec = try JSONDecoder().decode(AgentKeypadSpec.self, from: Data(json.utf8))
        let generated = GameKeypadGenerator.generate(from: spec)
        let layout = try XCTUnwrap(generated.profile.customization.elements.first { $0.id == UUID(uuidString: "BC770D48-78F4-45B6-BBF4-96C10B551E5F") }?.layout)
        XCTAssertEqual(layout.icon?.value, "sparkles")
        XCTAssertEqual(layout.hapticStyle, .heavy)
        XCTAssertEqual(layout.hapticFeedback?.pattern, .double)
        XCTAssertEqual(layout.hapticFeedback?.intensity ?? 0, CGFloat(0.73), accuracy: 0.0001)
        XCTAssertEqual(layout.hapticFeedback?.sharpness ?? 0, CGFloat(0.88), accuracy: 0.0001)
        XCTAssertEqual(layout.hapticFeedback?.duration ?? 0, CGFloat(0.09), accuracy: 0.0001)
        XCTAssertEqual(layout.visualStyle?.normal.strokeWidth, Optional(CGFloat(2)))
        XCTAssertEqual(layout.visualStyle?.normal.shadows?.count, 2)
        XCTAssertEqual(layout.visualStyle?.normal.shadows?.first?.radius, Optional(CGFloat(12)))
        XCTAssertEqual(layout.visualStyle?.normal.foregroundColor, Optional(GamepadRGBAColor(hexString: "#7C61A8")!.normalized))
        XCTAssertEqual(layout.visualStyle?.normal.innerShadowColor, Optional(GamepadRGBAColor(hexString: "#B8B2C2")!.normalized))
        XCTAssertEqual(layout.visualStyle?.normal.innerShadowRadius, Optional(CGFloat(5)))
        XCTAssertEqual(layout.visualStyle?.normal.highlightColor, Optional(GamepadRGBAColor(hexString: "#FFFFFF")!.normalized))
        XCTAssertEqual(layout.visualStyle?.normal.highlightOpacity, Optional(CGFloat(0.45)))
        XCTAssertEqual(layout.visualStyle?.normal.highlightX, Optional(CGFloat(-4)))
        XCTAssertEqual(layout.visualStyle?.normal.highlightY, Optional(CGFloat(-4)))
        XCTAssertEqual(layout.visualStyle?.normal.bevelHighlightColor, Optional(GamepadRGBAColor(hexString: "#FFFFFF")!.normalized))
        XCTAssertEqual(layout.visualStyle?.normal.bevelShadowColor, Optional(GamepadRGBAColor(hexString: "#C7C0CC")!.normalized))
        XCTAssertEqual(layout.visualStyle?.normal.bevelWidth, Optional(CGFloat(1.5)))
        XCTAssertEqual(layout.visualStyle?.pressed?.fillStyle?.representativeColor, GamepadRGBAColor(hexString: "#38BDF8")!.normalized)
    }

    func testRustGeneratedFixturesDecodeWithSwiftSemanticParity() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Host/fixtures/generation-spec/v1/generated", isDirectory: true)
        let decoder = JSONDecoder()

        func fixture(_ name: String) throws -> GeneratedGameKeypadProfile {
            let data = try Data(contentsOf: root.appendingPathComponent("\(name).json"))
            return try decoder.decode(GeneratedGameKeypadProfile.self, from: data)
        }

        let aliases = try fixture("aliases-basic")
        XCTAssertEqual(aliases.profile.id.uuidString.lowercased(), "76ee5047-12b2-5c28-b1d0-37391d988fd7")
        XCTAssertEqual(aliases.profile, aliases.profile.normalized)
        XCTAssertEqual(aliases.profile.outputMode, .keyboard)
        let moveID = KeypadElementID(UUID(uuidString: "D673535A-975B-4D72-93BE-FDF87C93001A")!)
        let jumpID = KeypadElementID(UUID(uuidString: "F3AE856B-4F4D-46E4-898F-6F97DA70002A")!)
        XCTAssertEqual(aliases.profile.customization.elements.first { $0.inputID == moveID }?.label, "Move Up")
        XCTAssertEqual(aliases.profile.customization.elements.first { $0.inputID == jumpID }?.label, "Jump")
        XCTAssertEqual(aliases.keyBindings[moveID], .init(key: "up arrow"))
        XCTAssertEqual(aliases.keyBindings[jumpID], .init(key: "space-bar", modifiers: ["shift"]))
        XCTAssertEqual(Set(aliases.keyBindings.keys), [moveID, jumpID])

        let specialized = try fixture("specialized-capacity")
        XCTAssertEqual(specialized.profile.id.uuidString.lowercased(), "0772045b-0d1e-57c1-8523-0ea4b4602463")
        XCTAssertEqual(specialized.profile, specialized.profile.normalized)
        XCTAssertEqual(specialized.profile.outputMode, .keyboard)
        let specializedControls = specialized.profile.customization.customButtons.map(\.normalized)
        XCTAssertEqual(specializedControls.filter(\.isJoystick).count, 2)
        XCTAssertEqual(specializedControls.filter(\.isTrigger).count, 2)
        XCTAssertEqual(specializedControls.filter(\.isTrackpad).count, 1)
        XCTAssertEqual(Set(specializedControls.map { $0.id.uuidString.lowercased() }), Set([
            "fc6d4ea4-3619-5bd3-84cc-7609d5f64e07",
            "28d6a0ad-5cf7-5a27-9a63-e0364bc887f2",
            "1ff04475-6d1e-57d5-8a41-4d454d78c7ee",
            "7b6afa3f-81e3-5b0b-930d-d82a3ec9529e",
            "1a539c00-8d79-55cb-a9ac-45372b6e737d"
        ]))
        XCTAssertEqual(specializedControls.first(where: \.isJoystick)?.joystickMapping, .movement)
        XCTAssertEqual(
            specializedControls.first(where: \.isTrackpad)?.trackpadSettings,
            GamepadTrackpadSettings(
                sensitivity: 1.2,
                scrollSensitivity: 0.85,
                tapToClick: true,
                twoFingerScroll: true,
                naturalScrolling: true
            ).normalized
        )
        XCTAssertEqual(Set(specialized.keyBindings.keys), Set(specializedControls.map(\.inputID)))

        let trigger = try fixture("trigger-defaults")
        XCTAssertEqual(trigger.profile.id.uuidString.lowercased(), "bfc8f93f-b9d0-5cd3-8e1f-d93d75690610")
        let triggerControl = try XCTUnwrap(trigger.profile.customization.customButtons.first?.normalized)
        XCTAssertEqual(triggerControl.id.uuidString.lowercased(), "4525b55a-eff3-57fc-9266-e297196cb863")
        XCTAssertEqual(triggerControl.label, "Right Trigge")
        XCTAssertEqual(triggerControl.label.count, GamepadCustomization.maximumLabelLength)
        XCTAssertEqual(triggerControl.triggerSettings, .defaultValue)
        XCTAssertEqual(triggerControl.layout.shape, .ellipse)
        XCTAssertEqual(trigger.keyBindings, [triggerControl.inputID: .init(key: "R")])
        XCTAssertEqual(trigger.profile.outputMode, .keyboard)

        let rich = try fixture("rich-appearance")
        XCTAssertEqual(rich.profile.id.uuidString.lowercased(), "3ac50975-b9fb-5875-b78f-6f3fa806e61a")
        XCTAssertEqual(rich.profile, rich.profile.normalized)
        XCTAssertEqual(rich.profile.outputMode, .keyboard)
        let richID = KeypadElementID(UUID(uuidString: "0295D44A-4F4F-5E2C-B32D-8237ADCF2050")!)
        XCTAssertEqual(rich.keyBindings, [richID: .init(key: "F")])
        let richLayout = try XCTUnwrap(rich.profile.customization.elements.first { $0.inputID == richID }?.layout)
        XCTAssertEqual(richLayout.icon?.value, "sparkles")
        XCTAssertEqual(richLayout.icon?.source, .sfSymbol)
        XCTAssertEqual(richLayout.hapticStyle, .heavy)
        XCTAssertEqual(richLayout.hapticFeedback?.pattern, .double)
        XCTAssertEqual(richLayout.hapticFeedback?.intensity ?? 0, 0.73, accuracy: 0.0001)
        XCTAssertEqual(richLayout.visualStyle?.normal.shadows?.count, 2)
        XCTAssertEqual(richLayout.visualStyle?.normal.bevelWidth, 1.5)
        XCTAssertEqual(
            richLayout.visualStyle?.pressed?.fillStyle?.representativeColor,
            GamepadRGBAColor(hexString: "#38BDF8")!.normalized
        )
    }

    func testProductivityTemplatesAreFirstClassAndKeepGamingTemplatesAvailable() {
        XCTAssertEqual(Array(GamepadControllerTemplate.allCases.prefix(3)), [
            .productivityStarter,
            .productivityOneHandedLeft,
            .productivityOneHandedRight
        ])
        XCTAssertTrue(GamepadControllerTemplate.allCases.contains(.nes))
        XCTAssertTrue(GamepadControllerTemplate.allCases.contains(.xbox))
        XCTAssertTrue(GamepadControllerTemplate.allCases.contains(.softWhite))
    }

    func testProductivityStarterKeepsFriendlyLabelsSeparateFromBindings() {
        let expectedLabels: [KeypadElementID: String] = [
            .preset(3): "Left",
            .preset(4): "Right",
            .preset(1): "Up",
            .preset(2): "Down",
            .preset(5): "Return",
            .preset(6): "Tab",
            .preset(7): "Command",
            .preset(8): "Prefix",
            .preset(9): "Palette",
            .preset(10): "Escape"
        ]
        let profile = GamepadControllerTemplate.productivityStarter.makeProfile()

        for orientation in GamepadEditorDeviceOrientation.allCases {
            let customization = profile.customization(for: orientation)
            for (button, expectedLabel) in expectedLabels {
                XCTAssertEqual(customization.visualLabel(for: button), expectedLabel, "\(orientation.displayName) \(button.rawValue)")
            }
        }
    }

    func testAppearanceThemesNeverDeclareOrBindMissingControls() throws {
        for theme in GamepadThemePreset.allCases {
            var empty = GamepadCustomization.blankCanvas
            theme.apply(to: &empty)
            XCTAssertTrue(empty.elements.isEmpty, theme.rawValue)
            XCTAssertTrue(empty.customButtons.isEmpty, theme.rawValue)
            let id = KeypadElementID(UUID())
            let owned = KeypadElement(id: id.uuid, label: "Owned", output: .init(), defaultOutput: .init(keyboard: .init(keyCode: 49)))
            var one = GamepadCustomization(elements: [owned])
            theme.apply(to: &one)
            XCTAssertEqual(one.elements.map(\.inputID), [id], theme.rawValue)
            XCTAssertEqual(one.elements.first?.output, owned.output)
            XCTAssertEqual(one.elements.first?.defaultOutput, owned.defaultOutput)
            XCTAssertEqual(one.elements.first?.partOutputs, owned.partOutputs)
        }
    }

    func testExtraControllerTemplateButtonsHaveExplicitConfiguredAndDefaultOutputs() throws {
        for (template, label) in [(GamepadControllerTemplate.nintendo64, "Z"), (.gameCube, "Z"), (.genesisSixButton, "C"), (.genesisSixButton, "Z"), (.genesisSixButton, "Mode"), (.saturn, "C"), (.saturn, "Z")] {
            let element = try XCTUnwrap(template.makeProfile().customization.elements.first { $0.label == label }, "\(template.rawValue) \(label)")
            let output = try XCTUnwrap(element.output, "\(template.rawValue) \(label)")
            XCTAssertFalse(output.gamepadButtons.isEmpty, "\(template.rawValue) \(label)")
            XCTAssertNotNil(output.keyboard, "\(template.rawValue) \(label)")
            XCTAssertEqual(element.defaultOutput, output, "\(template.rawValue) \(label)")
        }
    }

    func testDreamcastTriggerLegendsDeclareTriggersNotShoulders() throws {
        let profile = GamepadControllerTemplate.dreamcast.makeProfile()
        let left = try XCTUnwrap(profile.customization.elements.first { $0.label == "L" })
        let right = try XCTUnwrap(profile.customization.elements.first { $0.label == "R" })
        XCTAssertNotEqual(left.inputID, right.inputID)
        for (element, expected, key) in [(left, VirtualGamepadButton.leftTriggerButton, UInt16(12)), (right, .rightTriggerButton, UInt16(14))] {
            XCTAssertEqual(element.output?.gamepadButtons, [expected], element.label)
            XCTAssertEqual(element.defaultOutput?.gamepadButtons, [expected], element.label)
            XCTAssertEqual(element.output?.keyboard?.keyCode, key, element.label)
            XCTAssertEqual(element.defaultOutput?.keyboard?.keyCode, key, element.label)
            XCTAssertEqual(profile.initialMacOutputBindings[element.inputID]?.gamepadButtons, [expected], element.label)
        }
    }

    func testTemplatesSeedCompleteBindingsWithoutInheritingTheActiveProfile() throws {
        for template in GamepadControllerTemplate.allCases {
            let profile = template.makeProfile()
            let bindings = profile.initialMacOutputBindings
            for orientation in GamepadEditorDeviceOrientation.allCases {
                for element in profile.customization(for: orientation).normalized.elements {
                    guard let output = element.output ?? element.defaultOutput else { continue }
                    XCTAssertEqual(bindings[element.inputID], MacControlOutputBinding(shared: output), template.displayName)
                }
            }
            let ids = Set(profile.customization.normalized.elements.map(\.inputID))
            XCTAssertTrue(Set(bindings.keys).isSubset(of: ids), template.displayName)
        }

        let productivity = GamepadControllerTemplate.productivityStarter.makeProfile().initialMacOutputBindings
        XCTAssertEqual(productivity[.preset(7)]?.keyboard?.displayName, "⌘K")
        XCTAssertEqual(productivity[.preset(8)]?.keyboard?.displayName, "⌃B")
        XCTAssertEqual(productivity[.preset(9)]?.keyboard?.displayName, "⇧⌘P")

        let xbox = GamepadControllerTemplate.xbox.makeProfile().customization.normalized
        let expected: [String: VirtualGamepadButton] = ["A": .south, "B": .east, "X": .west, "Y": .north, "RT": .rightTriggerButton]
        for (label, button) in expected {
            let element = try XCTUnwrap(xbox.elements.first { $0.label == label })
            XCTAssertEqual(element.output?.gamepadButtons, [button], label)
            XCTAssertEqual(element.defaultOutput?.gamepadButtons, [button], label)
        }
    }

    func testProductivityStarterHasSeparatelyDesignedOrientationVariants() throws {
        let profile = GamepadControllerTemplate.productivityStarter.makeProfile()
        let landscape = try XCTUnwrap(profile.landscapeCustomization)
        let portrait = try XCTUnwrap(profile.portraitCustomization)

        XCTAssertEqual(landscape.deviceCanvas.editorDeviceFrame.orientation, .landscape)
        XCTAssertEqual(portrait.deviceCanvas.editorDeviceFrame.orientation, .portrait)
        XCTAssertFalse(landscape.hasSamePresentation(as: portrait))
        XCTAssertNotEqual(
            landscape.buttonCustomization(for: .preset(5)).centerX,
            portrait.buttonCustomization(for: .preset(5)).centerX
        )

        for customization in [landscape, portrait] {
            let canvasSize = customization.deviceCanvas.editorDeviceFrame.screenRect.size
            let controls = customization.resolvedControls(in: canvasSize).filter { !$0.isDecoration }
            XCTAssertTrue(controls.allSatisfy { min($0.size.width, $0.size.height) >= 44 })
            let report = customization.layoutQualityReport(profileName: "Productivity Starter", canvasSize: canvasSize)
            XCTAssertFalse(report.hasErrors, "\(customization.deviceCanvas.frameID): \(report.issues)")
            XCTAssertFalse(report.issues.contains { $0.code == "small-control" })
            XCTAssertFalse(report.issues.contains { $0.code == "control-overlap" })
        }
    }

    func testProductivityTemplatesUseDistinctNonColorActionCues() {
        for template in [
            GamepadControllerTemplate.productivityStarter,
            .productivityOneHandedLeft,
            .productivityOneHandedRight
        ] {
            let customization = template.makeProfile().customization(for: .portrait)
            for button in DefaultKeypadElements.ids {
                XCTAssertNotNil(customization.buttonCustomization(for: button).icon, "\(template.displayName) \(button.rawValue) icon")
            }

            XCTAssertEqual(customization.buttonCustomization(for: .preset(1)).shape, .roundedRectangle)
            XCTAssertEqual(customization.buttonCustomization(for: .preset(5)).shape, .capsule)
            XCTAssertEqual(customization.buttonCustomization(for: .preset(7)).shape, .rectangle)
            XCTAssertEqual(customization.buttonCustomization(for: .preset(10)).shape, .circle)
            XCTAssertEqual(customization.buttonCustomization(for: .preset(1)).resolvedHapticFeedback.pattern, .single)
            XCTAssertEqual(customization.buttonCustomization(for: .preset(5)).resolvedHapticFeedback.pattern, .double)
            XCTAssertEqual(customization.buttonCustomization(for: .preset(7)).resolvedHapticFeedback.pattern, .pulse)
            XCTAssertEqual(customization.buttonCustomization(for: .preset(10)).resolvedHapticFeedback.pattern, .buzz)
        }
    }

    func testOneHandedProductivityLayoutsStayInReachAndMeetTouchTargetMinimums() {
        let templates: [(GamepadControllerTemplate, ClosedRange<CGFloat>)] = [
            (.productivityOneHandedLeft, 0...0.60),
            (.productivityOneHandedRight, 0.40...1)
        ]

        for (template, horizontalZone) in templates {
            let profile = template.makeProfile()
            for orientation in GamepadEditorDeviceOrientation.allCases {
                let customization = profile.customization(for: orientation)
                let canvasSize = customization.deviceCanvas.editorDeviceFrame.screenRect.size
                let controls = customization.resolvedControls(in: canvasSize).filter { !$0.isDecoration }
                XCTAssertEqual(controls.count, 10)
                XCTAssertTrue(controls.allSatisfy { horizontalZone.contains($0.normalizedCenter.x) }, "\(template.displayName) \(orientation.displayName) horizontal reach")
                XCTAssertTrue(controls.allSatisfy { $0.normalizedCenter.y >= 0.47 }, "\(template.displayName) \(orientation.displayName) lower thumb zone")
                XCTAssertTrue(controls.allSatisfy { min($0.size.width, $0.size.height) >= 44 }, "\(template.displayName) \(orientation.displayName) 44pt targets")

                let report = customization.layoutQualityReport(profileName: template.displayName, canvasSize: canvasSize)
                XCTAssertFalse(report.hasErrors, "\(template.displayName) \(orientation.displayName): \(report.issues)")
                XCTAssertFalse(report.issues.contains { $0.code == "small-control" })
                XCTAssertFalse(report.issues.contains { $0.code == "control-overlap" })
            }
        }
    }

    func testNewProfileStateUsesProductivityStarterWithoutMigratingExistingProfiles() {
        let newUserState = GamepadConfigurationProfilePersistence.normalizedState(
            profiles: [],
            activeProfileID: nil,
            defaultProfileID: nil,
            fallbackCustomization: .defaultValue
        )
        XCTAssertEqual(newUserState.profiles.map(\.name), ["Productivity Starter"])
        XCTAssertNotNil(newUserState.activeProfile?.landscapeCustomization)
        XCTAssertNotNil(newUserState.activeProfile?.portraitCustomization)

        let blankID = UUID(uuidString: "00000000-0000-0000-0000-00000000E001")!
        let existingBlank = GamepadConfigurationProfile(id: blankID, name: "Existing Blank", customization: .blankCanvas)
        let blankState = GamepadConfigurationProfilePersistence.normalizedState(
            profiles: [existingBlank],
            activeProfileID: blankID,
            defaultProfileID: blankID
        )
        XCTAssertEqual(blankState.profiles, [existingBlank.normalized])

        let legacyID = UUID(uuidString: "00000000-0000-0000-0000-00000000E002")!
        var legacyCustomization = GamepadCustomization.blankCanvas
        legacyCustomization.addCustomButton(id: UUID(uuidString: "00000000-0000-0000-0000-00000000E003")!)
        legacyCustomization.customButtons[0].label = "Legacy"
        let legacyProfile = GamepadConfigurationProfile(
            id: legacyID,
            name: "Legacy Custom",
            customization: legacyCustomization,
            outputMode: .custom
        )
        let legacyState = GamepadConfigurationProfilePersistence.normalizedState(
            profiles: [legacyProfile],
            activeProfileID: legacyID,
            defaultProfileID: legacyID,
            fallbackCustomization: .defaultValue
        )
        XCTAssertEqual(legacyState.profiles, [legacyProfile.normalized])
        XCTAssertEqual(legacyState.activeProfileID, legacyID)
        XCTAssertEqual(legacyState.defaultProfileID, legacyID)
    }

    func testSavedConfigurationLoadRejectsInvalidDataWithoutChangingIt() throws {
        let suite = "ThumbleTests.saved-rejection.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keys = [GamepadCustomizationPersistence.defaultsKey, GamepadConfigurationProfilePersistence.defaultsKey]
        for data in [Data("{\"buttonCustomizations\":{\"jump\":{}}}".utf8), Data("not JSON".utf8)] {
            defaults.set(data, forKey: keys[0])
            XCTAssertThrowsError(try GamepadCustomizationPersistence.load(defaults: defaults))
            XCTAssertEqual(defaults.data(forKey: keys[0]), data)
        }
        defaults.set("invalid storage type", forKey: keys[0])
        XCTAssertThrowsError(try GamepadCustomizationPersistence.load(defaults: defaults))
        XCTAssertEqual(defaults.string(forKey: keys[0]), "invalid storage type")

        let profile = GamepadConfigurationProfile(name: "Owned", primaryCustomization: .blankCanvas)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        let invalidStates: [[String: Any]] = [
            ["profiles": [[:]], "activeProfileID": profile.id.uuidString, "defaultProfileID": profile.id.uuidString],
            ["profiles": [object, object], "activeProfileID": profile.id.uuidString, "defaultProfileID": profile.id.uuidString],
            ["profiles": [object], "activeProfileID": UUID().uuidString, "defaultProfileID": profile.id.uuidString],
            ["profiles": [object], "activeProfileID": profile.id.uuidString, "defaultProfileID": UUID().uuidString],
            ["profiles": [object]],
            ["profiles": [], "activeProfileID": profile.id.uuidString, "defaultProfileID": profile.id.uuidString]
        ]
        for state in invalidStates {
            let data = try JSONSerialization.data(withJSONObject: state, options: .sortedKeys)
            defaults.set(data, forKey: keys[1])
            XCTAssertThrowsError(try GamepadConfigurationProfilePersistence.load(activeCustomization: .blankCanvas, defaults: defaults))
            XCTAssertEqual(defaults.data(forKey: keys[1]), data)
        }
        defaults.set("invalid storage type", forKey: keys[1])
        XCTAssertThrowsError(try GamepadConfigurationProfilePersistence.load(activeCustomization: .blankCanvas, defaults: defaults))
        XCTAssertEqual(defaults.string(forKey: keys[1]), "invalid storage type")
    }

    func testImportedDeclarationsEnforceTotalAndSpecializedCapacitiesBeforeNormalization() throws {
        func data(kind: String, count: Int) throws -> Data {
            let elements: [[String: Any]] = (1...count).map { ordinal in
                ["id": String(format: "1A939AE0-3E1E-440B-9162-%012X", ordinal), "label": "Same", "kind": kind, "layout": [:]]
            }
            return try JSONSerialization.data(withJSONObject: ["elements": elements])
        }
        XCTAssertEqual(try JSONDecoder().decode(GamepadCustomization.self, from: data(kind: "button", count: 128)).elements.count, 128)
        for (kind, count) in [("button", 129), ("joystick", GamepadCustomization.maximumJoysticks + 1), ("trigger", GamepadCustomization.maximumTriggers + 1), ("trackpad", GamepadCustomization.maximumTrackpads + 1)] {
            XCTAssertThrowsError(try JSONDecoder().decode(GamepadCustomization.self, from: data(kind: kind, count: count)), kind)
        }
    }

    func testImportsRejectDanglingAppearanceAndDesignReferencesBeforeNormalization() throws {
        let id = UUID(uuidString: "E423FA5F-D7F4-4750-8E5B-8F2775440ADB")!
        let orphan = UUID(uuidString: "483B28C9-43F3-4E7C-A35B-80E33C61D6F0")!
        var customization = GamepadCustomization.blankCanvas
        customization.elements = [KeypadElement(id: id, label: "Owned", layout: .defaultValue)]
        customization.designMetadata = GamepadDesignMetadata(
            layerOrder: [.custom(id), .system(.topBarActivation)],
            groups: [GamepadLayerGroup(name: "Owned", children: [.custom(id)])]
        )
        let source = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(customization)) as? [String: Any])
        let metadata = try XCTUnwrap(source["designMetadata"] as? [String: Any])
        let group = try XCTUnwrap((metadata["groups"] as? [[String: Any]])?.first)
        let invalidIdentity: [String: Any] = ["kind": "custom", "id": orphan.uuidString]
        var invalid: [[String: Any]] = []
        for field in ["labelOverrides", "buttonCustomizations"] {
            let value: Any = field == "labelOverrides" ? "Orphan" : [String: Any]()
            var candidate = source
            candidate[field] = [orphan.uuidString, value]
            invalid.append(candidate)
            candidate[field] = [id.uuidString, value, id.uuidString.lowercased(), value]
            invalid.append(candidate)
        }
        let orders: [[Any]] = [[invalidIdentity], ["builtin.jump"], try XCTUnwrap(metadata["layerOrder"] as? [Any]) + [["kind": "custom", "id": id.uuidString]]]
        for order in orders {
            var candidate = source
            var design = metadata
            design["layerOrder"] = order
            candidate["designMetadata"] = design
            invalid.append(candidate)
        }
        for children in [[invalidIdentity], [["kind": "custom", "id": id.uuidString], ["kind": "custom", "id": id.uuidString.lowercased()]]] {
            var candidate = source
            var design = metadata
            var invalidGroup = group
            invalidGroup["children"] = children
            design["groups"] = [invalidGroup]
            candidate["designMetadata"] = design
            invalid.append(candidate)
        }
        var duplicateGroups = source
        var design = metadata
        design["groups"] = [group, group]
        duplicateGroups["designMetadata"] = design
        invalid.append(duplicateGroups)
        var wrongKind = source
        wrongKind["customButtons"] = [["id": id.uuidString, "label": "Mirror", "controlKind": "joystick", "layout": [:]]]
        invalid.append(wrongKind)
        for (index, candidate) in invalid.enumerated() {
            XCTAssertThrowsError(try JSONDecoder().decode(GamepadCustomization.self, from: JSONSerialization.data(withJSONObject: candidate)), "case \(index)")
        }
        let valid = try JSONDecoder().decode(GamepadCustomization.self, from: JSONSerialization.data(withJSONObject: source))
        XCTAssertEqual(valid.normalized.elements.map(\.id), [id])
        XCTAssertEqual(valid.normalized.designMetadata?.groups.first?.children, [.custom(id)])
    }

    func testImportedMirrorsNeverDeclareOrOverrideExecutableSettings() throws {
        let id = UUID(uuidString: "B5BD5966-973D-4284-9FF2-B65789C91141")!
        func encoded<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
        let cases: [(GamepadCustomControlKind, String, Any?, Any)] = [
            (.joystick, "joystickMapping", nil, try encoded(GamepadJoystickMapping.movement)),
            (.joystick, "joystickMapping", try encoded(GamepadJoystickMapping.movement), try encoded(GamepadJoystickMapping(up: .init(keyboard: .init(keyCode: 13))))),
            (.joystick, "joystickOutputSettings", try encoded(GamepadJoystickOutputSettings.analogRightStick), try encoded(GamepadJoystickOutputSettings.analogLeftStick)),
            (.trigger, "triggerSettings", try encoded(GamepadTriggerSettings(target: .left)), try encoded(GamepadTriggerSettings(target: .right))),
            (.trackpad, "trackpadSettings", try encoded(GamepadTrackpadSettings(tapToClick: false)), try encoded(GamepadTrackpadSettings(tapToClick: true)))
        ]
        for (kind, field, owned, injected) in cases {
            var element: [String: Any] = ["id": id.uuidString, "kind": kind.rawValue, "label": "Owned", "layout": [:]]
            element[field] = owned
            let mirror: [String: Any] = ["id": id.uuidString, "controlKind": kind.rawValue, "label": "Appearance", "layout": [:]]
            var candidate: [String: Any] = ["elements": [element], "customButtons": [mirror.merging([field: injected]) { _, value in value }]]
            XCTAssertThrowsError(try JSONDecoder().decode(GamepadCustomization.self, from: JSONSerialization.data(withJSONObject: candidate)), field)
            candidate["customButtons"] = [mirror]
            let decoded = try JSONDecoder().decode(GamepadCustomization.self, from: JSONSerialization.data(withJSONObject: candidate)).normalized
            let declaration = try JSONDecoder().decode(KeypadElement.self, from: JSONSerialization.data(withJSONObject: element)).normalized
            XCTAssertEqual(decoded.elements[0].joystickMapping, declaration.joystickMapping)
            XCTAssertEqual(decoded.elements[0].joystickOutputSettings, declaration.joystickOutputSettings)
            XCTAssertEqual(decoded.elements[0].triggerSettings, declaration.triggerSettings)
            XCTAssertEqual(decoded.elements[0].trackpadSettings, declaration.trackpadSettings)
            XCTAssertEqual(decoded.elements[0].partOutputs, declaration.partOutputs)
        }
    }

    func testSavedCustomizationRejectsLiteralAndEscapedDuplicateKeysBeforeDecoding() throws {
        let id = "B6FD297D-7508-4FF4-AFF7-97B3831F6AD0"
        let declarations = "[{\"id\":\"\(id)\",\"kind\":\"button\"}]"
        let cases = [
            "{\"elements\":[],\"elements\":\(declarations)}",
            "{\"elements\":[{\"id\":\"\(id)\",\"\\u0069d\":\"\(id)\",\"kind\":\"button\"}]}",
            "{\"elements\":[{\"id\":\"\(id)\",\"kind\":\"button\",\"output\":{},\"output\":{\"keyboard\":{\"keyCode\":49}}}]}"
        ]
        let suite = "ThumbleLiteralDuplicateTest.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for raw in cases {
            let data = Data(raw.utf8)
            defaults.set(data, forKey: GamepadCustomizationPersistence.defaultsKey)
            XCTAssertThrowsError(try GamepadCustomizationPersistence.load(defaults: defaults), raw)
            XCTAssertEqual(defaults.data(forKey: GamepadCustomizationPersistence.defaultsKey), data)
            XCTAssertNil(defaults.object(forKey: GamepadConfigurationProfilePersistence.defaultsKey))
        }
    }

    func testLocalLifecycleRemovesOnlyDeletedOwnersAcrossExecutableCanvases() throws {
        let removedID = KeypadElementID(UUID())
        let retainedID = KeypadElementID(UUID())
        var primary = GamepadCustomization.blankCanvas
        primary.elements = [KeypadElement(id: removedID.uuid, label: "Removed", layout: .defaultValue), KeypadElement(id: retainedID.uuid, label: "Retained", layout: .defaultValue)]
        var portrait = GamepadCustomization.blankCanvas
        portrait.elements = [primary.elements[1]]
        var previous = GamepadConfigurationProfile(name: "Owned", primaryCustomization: primary)
        previous.portraitCustomization = portrait
        var current = previous
        current.customization = .blankCanvas
        current.landscapeCustomization = .blankCanvas
        let key = MacKeyBinding(keyCode: 49, modifiers: [])
        var keys = [removedID.rawValue.lowercased(): key, retainedID.rawValue: key, "jump": key]
        var outputs = [removedID.rawValue: MacControlOutputBinding(keyboard: key), retainedID.rawValue.lowercased(): MacControlOutputBinding(), "jump": MacControlOutputBinding()]
        MacConfigurationBindings.removeDeletedOwnerReferences(previous: previous, current: current, keys: &keys, outputs: &outputs)
        XCTAssertNil(keys[removedID.rawValue.lowercased()])
        XCTAssertNil(outputs[removedID.rawValue])
        XCTAssertEqual(keys[retainedID.rawValue], key)
        XCTAssertNotNil(outputs[retainedID.rawValue.lowercased()])
        XCTAssertNotNil(keys["jump"], "Invalid existing keys must not be filtered into apparent validity")
        XCTAssertNotNil(outputs["jump"])
        XCTAssertEqual(previous.customization.elements.count, 2)
    }

    func testNativeFileImportRoundTripPreservesIncomingProfileMetadata() throws {
        let profile = GamepadControllerTemplate.xbox.makeProfile()
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        raw["futureProfile"] = ["source": "Incoming"]
        var customization = try XCTUnwrap(raw["customization"] as? [String: Any])
        customization["futureCustomization"] = ["source": "Incoming"]
        var elements = try XCTUnwrap(customization["elements"] as? [[String: Any]])
        elements[0]["futureElement"] = ["source": "Incoming"]
        customization["elements"] = elements; raw["customization"] = customization
        let envelope: [String: Any] = [
            "schema": ThumbleKeypadConfigurationExport.schemaIdentifier, "version": 4,
            "profiles": [raw], "activeProfileID": profile.id.uuidString,
            "defaultProfileID": profile.id.uuidString, "profileKeyBindings": [String: Any](),
            "profileOutputBindings": [String: Any]()
        ]
        let generated = GeneratedGameKeypadProfile(requestedGameName: "Owned", resolvedGameName: "Owned", profile: profile, keyBindings: [:], source: "test", confidence: .high)
        var generatedValue = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(generated)) as? [String: Any])
        generatedValue["profile"] = raw
        let shapes: [Any] = [envelope, raw, [raw], generatedValue, customization]
        for (index, shape) in shapes.enumerated() {
            let imported = try MacConfigurationBindings.decodeKeypadImport(data: JSONSerialization.data(withJSONObject: shape), sourceName: "incoming")
            let exported = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(imported)) as? [String: Any])
            let saved = try XCTUnwrap((exported["profiles"] as? [[String: Any]])?.first)
            XCTAssertNil(exported["profileSources"], "private source cache must not become an envelope field")
            if index < 4 { XCTAssertEqual(saved["futureProfile"] as? [String: String], ["source": "Incoming"]) }
            let savedCustomization = try XCTUnwrap(saved["customization"] as? [String: Any])
            XCTAssertEqual(savedCustomization["futureCustomization"] as? [String: String], ["source": "Incoming"])
            let savedElement = try XCTUnwrap((savedCustomization["elements"] as? [[String: Any]])?.first)
            XCTAssertEqual(savedElement["futureElement"] as? [String: String], ["source": "Incoming"])
            XCTAssertEqual(imported.profiles.first?.customization.elements.first?.output, profile.customization.elements.first?.output)
        }
    }

    func testNativeUndoRestoresItsOwnSourcesAndExportChecksTheWholeDomainBeforeFiltering() throws {
        let profile = GamepadControllerTemplate.xbox.makeProfile()
        let raw = try JSONDecoder().decodeUnique(ThumbleBridgeJSONValue.self, from: JSONEncoder().encode(profile))
        guard case .object(var fields) = raw else { return XCTFail("Expected profile object") }
        fields["futureProfile"] = .string("Alpha")
        let alphaSources = [profile.id: ThumbleBridgeJSONValue.object(fields)]
        let bindings = profile.initialMacOutputBindings
        let snapshot = MacConfigurationBindings.EditorUndoSnapshot(keyBindings: bindings.keyboardBindings, outputBindings: bindings,
            gamepadCustomization: profile.customization, gamepadProfiles: [profile], activeGamepadProfileID: profile.id,
            defaultGamepadProfileID: profile.id, profileKeyBindings: [profile.id: bindings.keyboardBindings],
            profileOutputBindings: [profile.id: bindings], profileSources: alphaSources)
        var redo = snapshot
        guard case .object(var changed) = try XCTUnwrap(redo.profileSources[profile.id]) else { return XCTFail("Expected profile object") }
        changed["futureProfile"] = .string("Beta")
        redo.profileSources[profile.id] = .object(changed)
        redo.gamepadProfiles[0].name = "Beta edited"
        for (saved, expected) in [(snapshot, "Alpha"), (redo, "Beta"), (snapshot, "Alpha")] {
            let update = try MacConfigurationBindings.checkedEditorUndoUpdate(saved)
            let data = try MacConfigurationBindings.keypadExportData(profiles: update.state.profiles,
                activeProfileID: update.state.activeProfileID, defaultProfileID: update.state.defaultProfileID,
                exportingProfileID: profile.id, bindings: update.bindings, preserving: update.profileSources)
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let exported = try XCTUnwrap((root["profiles"] as? [[String: Any]])?.first)
            XCTAssertEqual(exported["futureProfile"] as? String, expected)
            XCTAssertEqual(exported["name"] as? String, saved.gamepadProfiles[0].name)
            XCTAssertEqual(update.bindings.profileOutputs[profile.id], bindings)
        }
        var invalid = snapshot
        let orphan = KeypadElementID(UUID())
        invalid.profileOutputBindings[profile.id]?[orphan] = .init()
        XCTAssertThrowsError(try MacConfigurationBindings.checkedEditorUndoUpdate(invalid))
        let other = GamepadConfigurationProfile(name: "Other", primaryCustomization: .blankCanvas)
        let invalidBindings = MacConfigurationBindings.SavedBindings(profileKeys: snapshot.profileKeyBindings,
            profileOutputs: [profile.id: bindings, other.id: [orphan: .init()]])
        XCTAssertThrowsError(try MacConfigurationBindings.keypadExportData(profiles: [profile, other], activeProfileID: profile.id,
            defaultProfileID: profile.id, exportingProfileID: profile.id, bindings: invalidBindings, preserving: alphaSources))
        guard case .object(var customization) = fields["customization"],
              case .array(var elements) = customization["elements"],
              case .object(var element) = elements[0] else { return XCTFail("Expected declaration") }
        element["mappedButton"] = .null
        elements[0] = .object(element); customization["elements"] = .array(elements)
        fields["customization"] = .object(customization)
        XCTAssertThrowsError(try MacConfigurationBindings.keypadExportData(profiles: [profile], activeProfileID: profile.id,
            defaultProfileID: profile.id, exportingProfileID: nil, bindings: .init(profileKeys: snapshot.profileKeyBindings,
                profileOutputs: snapshot.profileOutputBindings), preserving: [profile.id: .object(fields)]))
        XCTAssertEqual(snapshot.profileSources, alphaSources)
    }

    func testNativeProfileSourcesReplaceSameIDMetadataAndPreserveItThroughKnownEdits() throws {
        let profile = GamepadControllerTemplate.xbox.makeProfile()
        let canonical = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        var previousSources: [UUID: ThumbleBridgeJSONValue] = [:]
        for marker in ["Alpha", "Beta", "Gamma"] {
            var raw = canonical
            raw["futureProfile"] = ["source": marker]
            var customization = try XCTUnwrap(raw["customization"] as? [String: Any])
            customization["futureCustomization"] = ["source": marker]
            var elements = try XCTUnwrap(customization["elements"] as? [[String: Any]])
            elements[0]["futureElement"] = ["source": marker]
            customization["elements"] = elements; raw["customization"] = customization
            let catalog = try JSONSerialization.data(withJSONObject: ["profiles": [raw], "activeProfileID": profile.id.uuidString, "defaultProfileID": profile.id.uuidString])
            let update = try MacConfigurationBindings.decodeProfileUpdate(profileState: catalog, activeCustomization: nil, bindingDomain: [:])
            if !previousSources.isEmpty { XCTAssertNotEqual(update.profileSources, previousSources) }
            previousSources = update.profileSources
            var edited = update.state.profiles
            edited[0].name = "Edited"
            edited[0].customization.setLabel("Changed", for: edited[0].customization.elements[0].inputID)
            let encoded = try MacConfigurationBindings.encodedProfileState(edited, activeProfileID: profile.id, defaultProfileID: profile.id, preserving: update.profileSources)
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            let saved = try XCTUnwrap((root["profiles"] as? [[String: Any]])?.first)
            XCTAssertEqual(saved["futureProfile"] as? [String: String], ["source": marker])
            XCTAssertEqual(saved["name"] as? String, "Edited")
            let savedCustomization = try XCTUnwrap(saved["customization"] as? [String: Any])
            XCTAssertEqual(savedCustomization["futureCustomization"] as? [String: String], ["source": marker])
            let savedElement = try XCTUnwrap((savedCustomization["elements"] as? [[String: Any]])?.first)
            XCTAssertEqual(savedElement["futureElement"] as? [String: String], ["source": marker])
            XCTAssertEqual(savedElement["label"] as? String, "Changed")
            XCTAssertEqual(try GamepadConfigurationProfilePersistence.decodeSavedState(encoded).profiles[0].customization.elements[0].output, update.state.profiles[0].customization.elements[0].output)
            XCTAssertThrowsError(try MacConfigurationBindings.encodedProfileState(edited + edited, activeProfileID: profile.id, defaultProfileID: profile.id, preserving: update.profileSources))
        }
    }

    func testExternalProfileUpdatesValidateWholeIncomingDomainWithoutRecovery() throws {
        var profile = GamepadControllerTemplate.xbox.makeProfile()
        let elementID = try XCTUnwrap(profile.customization.elements.first).inputID
        profile.customization.elements[0].output = .init(keyboard: .init(keyCode: 49), gamepadButtons: [.south])
        let profileValue = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        let validCatalog: [String: Any] = [
            "profiles": [profileValue], "activeProfileID": profile.id.uuidString, "defaultProfileID": profile.id.uuidString
        ]
        let catalogData = try JSONSerialization.data(withJSONObject: validCatalog)
        let decoded = try MacConfigurationBindings.decodeProfileUpdate(profileState: catalogData, activeCustomization: nil, bindingDomain: [:])
        XCTAssertEqual(decoded.state.profiles.map(\.id), [profile.id])
        XCTAssertEqual(decoded.bindings.profileOutputs[profile.id]?[elementID]?.keyboard?.keyCode, 49)
        XCTAssertEqual(decoded.bindings.profileOutputs[profile.id]?[elementID]?.gamepadButtons, [.south])

        for replacement in [[String: Any](), ["activeProfileID": UUID().uuidString], ["profiles": []], ["profiles": [profileValue, profileValue]]] {
            var invalid = validCatalog
            if replacement.isEmpty { invalid.removeValue(forKey: "defaultProfileID") }
            else { invalid.merge(replacement, uniquingKeysWith: { _, new in new }) }
            let raw = try JSONSerialization.data(withJSONObject: invalid)
            XCTAssertThrowsError(try MacConfigurationBindings.decodeProfileUpdate(profileState: raw, activeCustomization: nil, bindingDomain: [:]))
        }
        let orphan = UUID().uuidString
        let invalidDomains: [[String: Any]] = [
            ["PocketPadMac.keyBindings.v2": Data("{\"\(orphan)\":{\"keyCode\":48,\"modifiers\":0}}".utf8)],
            ["PocketPadMac.profileOutputBindings.v1": Data("{\"\(orphan)\":{}}".utf8)],
            ["PocketPadMac.outputBindings.v1": Data("{\"\(elementID.rawValue)\":{},\"\(elementID.rawValue)\":{}}".utf8)],
            ["PocketPadMac.keyBindings.v2": "not JSON data"]
        ]
        for domain in invalidDomains {
            XCTAssertThrowsError(try MacConfigurationBindings.decodeProfileUpdate(profileState: catalogData, activeCustomization: nil, bindingDomain: domain))
        }
        XCTAssertThrowsError(try MacConfigurationBindings.decodeProfileUpdate(profileState: catalogData, activeCustomization: Data("{}".utf8), bindingDomain: [:]))
        XCTAssertEqual(try MacConfigurationBindings.decodeProfileUpdate(profileState: catalogData, activeCustomization: nil, bindingDomain: [:]).state, decoded.state)
    }

    func testSavedMapsRejectLiteralElementAndProfileDuplicatesBeforeCollection() throws {
        let profile = GamepadControllerTemplate.xbox.makeProfile()
        let id = try XCTUnwrap(profile.customization.elements.first).inputID.rawValue
        let state = GamepadConfigurationProfilePersistence.normalizedState(profiles: [profile], activeProfileID: profile.id, defaultProfileID: profile.id)
        let key = "{\"keyCode\":49,\"modifiers\":{\"rawValue\":0}}"
        let duplicateKeys = "{\"\(id)\":\(key),\"\(id)\":\(key)}"
        let duplicateOutputs = "{\"\(id)\":{\"gamepadButtons\":[]},\"\(id)\":{\"gamepadButtons\":[]}}"
        let cases = [
            ("PocketPadMac.keyBindings.v2", duplicateKeys),
            ("PocketPadMac.outputBindings.v1", duplicateOutputs),
            ("PocketPadMac.profileKeyBindings.v1", "{\"\(profile.id)\":\(duplicateKeys)}"),
            ("PocketPadMac.profileOutputBindings.v1", "{\"\(profile.id)\":{},\"\(profile.id)\":{}}")
        ]
        for (field, raw) in cases {
            XCTAssertThrowsError(try MacConfigurationBindings.loadSavedBindings(from: [field: Data(raw.utf8)], state: state), field)
        }
    }

    func testSavedCatalogRejectsLiteralDuplicateSelectionBeforeRecoveryOrWrites() throws {
        let profile = GamepadConfigurationProfile(name: "Independent", primaryCustomization: .blankCanvas)
        let profileJSON = String(decoding: try JSONEncoder().encode(profile), as: UTF8.self)
        let data = Data("{\"profiles\":[\(profileJSON)],\"activeProfileID\":\"\(profile.id)\",\"activeProfileID\":\"\(profile.id)\",\"defaultProfileID\":\"\(profile.id)\"}".utf8)
        let suite = "ThumbleCatalogDuplicateTest.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(data, forKey: GamepadConfigurationProfilePersistence.defaultsKey)
        XCTAssertThrowsError(try GamepadConfigurationProfilePersistence.load(activeCustomization: .defaultValue, defaults: defaults))
        XCTAssertEqual(defaults.data(forKey: GamepadConfigurationProfilePersistence.defaultsKey), data)
        XCTAssertNil(defaults.object(forKey: GamepadCustomizationPersistence.defaultsKey))
    }

    func testElementPartOutputsRejectRepeatedPartsBeforeDictionaryDecoding() throws {
        let raw = "{\"id\":\"B6FD297D-7508-4FF4-AFF7-97B3831F6AD0\",\"kind\":\"joystick\",\"partOutputs\":[\"joystick_up\",{\"keyboard\":{\"keyCode\":49,\"modifiersRawValue\":0},\"gamepadButtons\":[]},\"joystick_up\",{\"keyboard\":{\"keyCode\":48,\"modifiersRawValue\":0},\"gamepadButtons\":[]}]}"
        let single = raw.replacingOccurrences(of: ",\"joystick_up\",{\"keyboard\":{\"keyCode\":48,\"modifiersRawValue\":0},\"gamepadButtons\":[]}", with: "")
        XCTAssertNoThrow(try JSONDecoder().decode(KeypadElement.self, from: Data(single.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(KeypadElement.self, from: Data(raw.utf8)))
        XCTAssertThrowsError(try GamepadCustomizationPersistence.decodeSavedCustomization(Data("{\"elements\":[\(raw)]}".utf8)))
    }

    func testSavedStandaloneEmptyDeclarationsStayEmptyAndObsoleteStandaloneRejects() throws {
        let suite = "ThumbleSavedDeclarationTest.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fresh = try GamepadConfigurationProfilePersistence.load(activeCustomization: .defaultValue, defaults: defaults)
        XCTAssertEqual(fresh.profiles.count, 1)
        XCTAssertEqual(fresh.activeProfile?.name, GamepadControllerTemplate.productivityStarter.displayName)
        let empty = try JSONEncoder().encode(GamepadCustomization.blankCanvas)
        defaults.set(empty, forKey: GamepadCustomizationPersistence.defaultsKey)
        let loaded = try GamepadConfigurationProfilePersistence.load(activeCustomization: .defaultValue, defaults: defaults)
        XCTAssertEqual(loaded.profiles.count, 1)
        XCTAssertEqual(loaded.activeProfile?.customization.elements, [])
        XCTAssertTrue(loaded.activeProfile?.initialMacOutputBindings.isEmpty == true)
        XCTAssertNil(defaults.object(forKey: GamepadConfigurationProfilePersistence.defaultsKey))
        let obsolete = Data("{\"buttonCustomizations\":{\"jump\":{}}}".utf8)
        defaults.set(obsolete, forKey: GamepadCustomizationPersistence.defaultsKey)
        XCTAssertThrowsError(try GamepadConfigurationProfilePersistence.load(activeCustomization: .defaultValue, defaults: defaults))
        XCTAssertEqual(defaults.data(forKey: GamepadCustomizationPersistence.defaultsKey), obsolete)
        XCTAssertNil(defaults.object(forKey: GamepadConfigurationProfilePersistence.defaultsKey))
    }

    func testSavedBindingMapsRejectEveryInvalidIdentityAndReconcileOwnedOutputs() throws {
        let firstID = UUID(uuidString: "EA17636C-54D9-4BB9-91C3-4446938A2801")!
        let clearID = UUID(uuidString: "BA0C059D-2158-45F3-A3AC-76792B2A94DC")!
        let otherID = UUID(uuidString: "06D820AC-1068-43B8-B789-EE97733E42A7")!
        var firstCustomization = GamepadCustomization.blankCanvas
        firstCustomization.elements = [
            KeypadElement(id: firstID, label: "Same", layout: .defaultValue, output: .init(keyboard: .init(keyCode: 49), gamepadButtons: [.south])),
            KeypadElement(id: clearID, label: "Same", layout: .defaultValue, output: .init())
        ]
        var otherCustomization = GamepadCustomization.blankCanvas
        otherCustomization.elements = [KeypadElement(id: otherID, label: "Same", layout: .defaultValue, output: .init(keyboard: .init(keyCode: 48), gamepadButtons: [.north]))]
        let first = GamepadConfigurationProfile(name: "First", primaryCustomization: firstCustomization)
        let other = GamepadConfigurationProfile(name: "Other", primaryCustomization: otherCustomization)
        let state = GamepadConfigurationProfilePersistence.normalizedState(profiles: [first, other], activeProfileID: first.id, defaultProfileID: other.id)
        func encoded<T: Encodable>(_ value: T) throws -> Data { try JSONEncoder().encode(value) }
        let staleKeys = [first.id.uuidString: [firstID.uuidString: MacKeyBinding(keyCode: 12), clearID.uuidString: MacKeyBinding(keyCode: 13)]]
        let staleOutputs = [first.id.uuidString: [firstID.uuidString: MacControlOutputBinding(), clearID.uuidString: MacControlOutputBinding.keyboard(.init(keyCode: 13))]]
        let valid: [String: Any] = ["PocketPadMac.profileKeyBindings.v1": try encoded(staleKeys), "PocketPadMac.profileOutputBindings.v1": try encoded(staleOutputs)]
        let resolved = try MacConfigurationBindings.loadSavedBindings(from: valid, state: state)
        XCTAssertEqual(resolved.profileKeys[first.id]?[KeypadElementID(firstID)]?.keyCode, 49)
        XCTAssertNil(resolved.profileKeys[first.id]?[KeypadElementID(clearID)])
        XCTAssertEqual(resolved.profileOutputs[first.id]?[KeypadElementID(firstID)]?.gamepadButtons, [.south])
        XCTAssertEqual(resolved.profileOutputs[first.id]?[KeypadElementID(clearID)], MacControlOutputBinding())
        XCTAssertEqual(resolved.profileKeys[other.id]?[KeypadElementID(otherID)]?.keyCode, 48)
        XCTAssertEqual(resolved.profileOutputs[other.id]?[KeypadElementID(otherID)]?.gamepadButtons, [.north])
        let invalid: [[String: Any]] = [
            ["PocketPadMac.keyBindings.v1": Data("{}".utf8)],
            ["PocketPadMac.keyBindings.v2": "wrong storage type"],
            ["PocketPadMac.profileKeyBindings.v1": Data("not JSON".utf8)],
            ["PocketPadMac.keyBindings.v2": try encoded(["jump": MacKeyBinding(keyCode: 49)])],
            ["PocketPadMac.keyBindings.v2": try encoded([otherID.uuidString: MacKeyBinding(keyCode: 49)])],
            ["PocketPadMac.outputBindings.v1": try encoded([otherID.uuidString: MacControlOutputBinding()])],
            ["PocketPadMac.profileKeyBindings.v1": try encoded([UUID().uuidString: [String: MacKeyBinding]()])],
            ["PocketPadMac.profileOutputBindings.v1": try encoded([first.id.uuidString: [otherID.uuidString: MacControlOutputBinding()]])],
            ["PocketPadMac.profileKeyBindings.v1": try encoded([first.id.uuidString: [firstID.uuidString: MacKeyBinding(keyCode: 49), firstID.uuidString.lowercased(): MacKeyBinding(keyCode: 49)]])],
            ["PocketPadMac.profileOutputBindings.v1": try encoded([first.id.uuidString: [String: MacControlOutputBinding](), first.id.uuidString.lowercased(): [String: MacControlOutputBinding]()])]
        ]
        for domain in invalid { XCTAssertThrowsError(try MacConfigurationBindings.loadSavedBindings(from: domain, state: state)) }
    }

    func testSavedUUIDProfilesNeverMigrateBasedOnNamesOrStandaloneMirror() throws {
        let suite = "ThumbleTests.saved-profile-names.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = GamepadConfigurationProfilePersistence.defaultsKey
        let names = ["Current Setup", "NES", "Super Nintendo", "Nintendo 64", "GameCube", "Game Boy", "Game Boy Advance", "Genesis 6-Button", "Sega Saturn", "Dreamcast", "Arcade Stick", "PSP", "PlayStation", "Xbox", "Soft White Pro", "Navigation Left", "Actions Left", "Dual Stick Shooter", "Large Blue", "Compact Minimal"]
        let profiles = names.map { GamepadConfigurationProfile(name: $0, primaryCustomization: .blankCanvas) }
        let profileObjects = try profiles.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }
        let saved = try JSONSerialization.data(withJSONObject: [
            "profiles": profileObjects, "activeProfileID": profiles[0].id.uuidString, "defaultProfileID": profiles[1].id.uuidString
        ], options: .sortedKeys)
        defaults.set(saved, forKey: key)
        let before = defaults.data(forKey: key)
        let loaded = try GamepadConfigurationProfilePersistence.load(activeCustomization: .defaultValue, defaults: defaults)
        XCTAssertEqual(loaded.profiles, profiles.map(\.normalized))
        XCTAssertEqual(loaded.activeProfileID, profiles[0].id)
        XCTAssertEqual(loaded.defaultProfileID, profiles[1].id)
        XCTAssertEqual(defaults.data(forKey: key), before)
    }

    func testProfilePersistenceDoesNotReplaceSavedProfileWithStaleLegacyMirror() throws {
        let defaults = UserDefaults.standard
        let originalData = defaults.data(forKey: GamepadConfigurationProfilePersistence.defaultsKey)
        defer {
            if let originalData {
                defaults.set(originalData, forKey: GamepadConfigurationProfilePersistence.defaultsKey)
            } else {
                defaults.removeObject(forKey: GamepadConfigurationProfilePersistence.defaultsKey)
            }
        }

        var profile = GamepadControllerTemplate.xbox.makeProfile()
        var savedCustomization = profile.customization
        savedCustomization.setLabel("Saved", for: .preset(5))
        savedCustomization.updatedAt = 200
        profile.customization = savedCustomization
        profile.updatedAt = 200
        GamepadConfigurationProfilePersistence.save(
            [profile],
            activeProfileID: profile.id,
            defaultProfileID: profile.id
        )

        var staleMirror = savedCustomization
        staleMirror.setLabel("Stale", for: .preset(5))
        staleMirror.updatedAt = 100
        let loaded = try GamepadConfigurationProfilePersistence.load(activeCustomization: staleMirror)

        XCTAssertEqual(loaded.activeProfile?.customization.visualLabel(for: .preset(5)), "Saved")
        XCTAssertEqual(loaded.activeProfile?.customization.updatedAt, 200)
    }

    func testSoftWhiteThemeAndTemplateSupportDecorationLayers() throws {
        var customization = GamepadCustomization.defaultValue
        GamepadThemePreset.softWhiteController.apply(to: &customization)
        let themed = customization.normalized
        XCTAssertEqual(themed.colorSchemePreference, .light)
        XCTAssertTrue(themed.styleLibrary.style(id: "soft-white-raised") != nil)
        XCTAssertEqual(themed.buttonCustomization(for: .preset(5)).styleID, "soft-white-lavender")
        let jump = themed.resolvedControls(in: CGSize(width: 874, height: 402)).first { $0.id == .builtin(.preset(5)) }!
        XCTAssertGreaterThan(themed.resolvedPresentation(for: jump, state: .normal, scheme: .light).shadows.count, 1)

        let template = GamepadControllerTemplate.softWhite.makeProfile().customization.normalized
        let decorations = template.customButtons.filter { $0.normalized.isDecoration }
        XCTAssertGreaterThanOrEqual(decorations.count, 5)
        XCTAssertTrue(template.resolvedControls(in: CGSize(width: 874, height: 402)).contains { $0.isDecoration })
        XCTAssertEqual(template.orderedControlIdentitiesForDesign.first, .custom(decorations.first!.id))

        let report = template.layoutQualityReport(profileName: "Soft White Pro", canvasSize: CGSize(width: 874, height: 402))
        XCTAssertFalse(report.hasErrors)
        XCTAssertTrue(report.issues.contains { $0.code == "expanded-hit-overlap" })
        XCTAssertFalse(report.issues.contains { $0.code.hasPrefix("primary-control-") })
        XCTAssertTrue(report.controls.contains { $0.kind == "decoration" })
    }

    func testLayoutQualityAllowsIntentionallyLargeControls() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-00000000F001")!
        var customization = GamepadCustomization.blankCanvas
        customization.customButtons = [
            GamepadCustomButton(
                id: id,
                label: "Large Action",
                layout: GamepadButtonCustomization(
                    centerX: 0.5,
                    centerY: 0.5,
                    widthScale: 5,
                    heightScale: 5,
                    shape: .circle
                )
            )
        ]

        let report = customization.layoutQualityReport(canvasSize: CGSize(width: 874, height: 402))
        XCTAssertFalse(report.issues.contains { $0.code == "large-control" || $0.code == "oversized-control" })
    }

    func testDecorationAgentSpecDoesNotCreateKeyBinding() throws {
        let json = """
        {
          "gameName": "Decor Spec",
          "controls": [
            {
              "label": "Shell",
              "kind": "decoration",
              "material": "soft-white-plate",
              "x": 0.5,
              "y": 0.5,
              "width": 3.2,
              "height": 1.5,
              "shape": "rounded_rectangle"
            }
          ]
        }
        """
        let spec = try JSONDecoder().decode(AgentKeypadSpec.self, from: Data(json.utf8))
        let generated = GameKeypadGenerator.generate(from: spec)
        let decoration = try XCTUnwrap(generated.profile.customization.customButtons.first?.normalized)
        XCTAssertTrue(decoration.isDecoration)
        XCTAssertTrue(generated.keyBindings.isEmpty)
        XCTAssertEqual(decoration.layout.visualStyle?.normal.shadows?.count, 2)
    }

    func testThemePresetAppliesCavernGlowDesignSystem() throws {
        var customization = GamepadCustomization.defaultValue
        GamepadThemePreset.cavernGlow.apply(to: &customization)
        let normalized = customization.normalized

        XCTAssertEqual(normalized.colorSchemePreference, .dark)
        XCTAssertEqual(normalized.backgroundDarkFillStyle?.displayName, "Linear")
        XCTAssertEqual(normalized.styleLibrary.styles.map(\.id).sorted(), [
            "cavern-dash",
            "cavern-jump",
            "cavern-nail",
            "cavern-parchment",
            "cavern-rune",
            "cavern-soul",
            "cavern-stone"
        ])
        XCTAssertEqual(normalized.buttonCustomization(for: .preset(8)).styleID, "cavern-soul")
        XCTAssertEqual(normalized.buttonCustomization(for: .preset(6)).styleID, "cavern-nail")
        XCTAssertEqual(normalized.buttonCustomization(for: .preset(7)).styleID, "cavern-dash")
        XCTAssertTrue(normalized.designMetadata?.tags.contains("marketable") == true)

        let focus = normalized.resolvedControls(in: CGSize(width: 874, height: 402)).first { $0.id == .builtin(.preset(8)) }!
        let normal = normalized.resolvedPresentation(for: focus, state: .normal, scheme: .dark)
        let pressed = normalized.resolvedPresentation(for: focus, state: .pressed, scheme: .dark)
        XCTAssertEqual(normal.icon?.value, "sparkles")
        XCTAssertEqual(normal.hapticFeedback.pattern, .pulse)
        XCTAssertNotNil(normal.glowColor)
        XCTAssertNotEqual(normal.fillStyle.representativeColor, pressed.fillStyle.representativeColor)
    }

    func testHollowKnightAuthorsItsOwnKeyboardAndGamepadDefaults() throws {
        let generated = try XCTUnwrap(GameKeypadGenerator.generate(for: "Hollow Knight"))
        for element in generated.profile.customization.elements where element.kind == .button {
            let specification = try XCTUnwrap(generated.keyBindings[element.inputID])
            let keyboard = try XCTUnwrap(KeypadKeyboardBinding(keyName: specification.key, modifierNames: specification.modifiers))
            XCTAssertEqual(element.output?.keyboard, keyboard)
            XCTAssertEqual(element.defaultOutput, element.output)
        }
        let elements = generated.profile.customization.elements
        XCTAssertEqual(elements.first { $0.inputID == .preset(6) }?.output?.gamepadButtons, [.west])
        XCTAssertEqual(elements.first { $0.inputID == .preset(7) }?.output?.gamepadButtons, [.east])
    }

    func testHollowKnightBuiltInUsesMarketableCavernGlowTheme() throws {
        let generated = try XCTUnwrap(GameKeypadGenerator.generate(for: "Hollow Knight"))
        let customization = generated.profile.customization.normalized

        XCTAssertEqual(generated.source, "Built-in Hollow Knight default keyboard template with Thumble's Cavern Glow showcase theme")
        XCTAssertEqual(customization.colorSchemePreference, .dark)
        XCTAssertEqual(customization.buttonCustomization(for: .preset(8)).styleID, "cavern-soul")
        XCTAssertEqual(customization.buttonCustomization(for: .preset(6)).styleID, "cavern-nail")
        XCTAssertEqual(customization.buttonCustomization(for: .preset(9)).styleID, "cavern-parchment")
        XCTAssertTrue(customization.styleLibrary.style(id: "cavern-soul") != nil)
        XCTAssertTrue(customization.hasCustomBackgroundFill(for: .dark))
        XCTAssertTrue(customization.designMetadata?.tags.contains("showcase") == true)
        XCTAssertTrue(generated.notes.contains { $0.contains("dark cave gradient") })
    }

    func testPointerMessageRoundTripsThroughJSONCodec() throws {
        let message = ControllerMessage(
            type: .pointer,
            state: .down,
            timestamp: 123,
            pointerEvent: .button,
            pointerButton: .right,
            deltaX: 1.5,
            deltaY: -2.25
        )
        let data = try ControllerWireCodec.encode(message, using: JSONEncoder())
        XCTAssertNotEqual(data.count, 14)
        let decoded = try ControllerWireCodec.decode(data, using: JSONDecoder())
        XCTAssertEqual(decoded.type, .pointer)
        XCTAssertEqual(decoded.pointerEvent, .button)
        XCTAssertEqual(decoded.pointerButton, .right)
        XCTAssertEqual(decoded.state, .down)
        XCTAssertEqual(decoded.deltaX, 1.5)
        XCTAssertEqual(decoded.deltaY, -2.25)
    }

    func testAnalogGamepadMessageRoundTripsThroughJSONCodec() throws {
        let message = ControllerMessage(
            type: .gamepadAnalog,
            timestamp: 456,
            analogStick: .left,
            analogX: -0.35,
            analogY: 0.75,
            analogSequence: 42
        )
        let data = try ControllerWireCodec.encode(message, using: JSONEncoder())
        XCTAssertNotEqual(data.count, 14)
        let decoded = try ControllerWireCodec.decode(data, using: JSONDecoder())
        XCTAssertEqual(decoded.type, .gamepadAnalog)
        XCTAssertEqual(decoded.analogStick, .left)
        XCTAssertEqual(decoded.analogX, -0.35)
        XCTAssertEqual(decoded.analogY, 0.75)
        XCTAssertEqual(decoded.analogSequence, 42)
    }

    func testBackgroundFillStyleRoundTripsAndSupportsSchemeOverrides() throws {
        let base = GamepadRGBAColor(red: 0.06, green: 0.07, blue: 0.12, alpha: 1)
        let gradient = GamepadFillStyle.gradient(GamepadGradientFill.defaultValue(baseColor: base).normalized)
        var customization = GamepadCustomization.defaultValue
        customization.backgroundFillStyle = gradient

        XCTAssertEqual(customization.keypadBackgroundFillStyle(scheme: .light), gradient.normalized)
        XCTAssertEqual(customization.keypadBackgroundFillStyle(scheme: .dark), gradient.normalized)
        XCTAssertTrue(customization.hasCustomBackgroundFill(for: .light))
        XCTAssertTrue(customization.hasCustomBackgroundFill(for: .dark))

        let lightColor = GamepadRGBAColor(red: 1, green: 0.9, blue: 0.7, alpha: 0.5)
        customization.setBackgroundColor(lightColor, for: .light)

        XCTAssertNil(customization.backgroundFillStyle)
        XCTAssertEqual(customization.backgroundLightColor, lightColor.normalized)
        XCTAssertEqual(customization.backgroundDarkFillStyle, gradient.normalized)
        XCTAssertEqual(customization.keypadBackgroundFillStyle(scheme: .light), .solid(lightColor.normalized))
        XCTAssertEqual(customization.keypadBackgroundFillStyle(scheme: .dark), gradient.normalized)

        let data = try JSONEncoder().encode(customization.normalized)
        let decoded = try JSONDecoder().decode(GamepadCustomization.self, from: data).normalized
        XCTAssertTrue(decoded.hasSamePresentation(as: customization.normalized))
    }

    func testControllerLayoutRoutingSelectsStandardAndFreeformPresentations() {
        XCTAssertEqual(
            GamepadControllerPresentationRouting.layoutRoute(
                orientation: .portrait,
                isEditingLayout: false,
                usesFreeformLayout: false
            ),
            .standard(.portrait)
        )
        XCTAssertEqual(
            GamepadControllerPresentationRouting.layoutRoute(
                orientation: .landscape,
                isEditingLayout: false,
                usesFreeformLayout: false
            ),
            .standard(.landscape)
        )

        for orientation in GamepadEditorDeviceOrientation.allCases {
            XCTAssertEqual(
                GamepadControllerPresentationRouting.layoutRoute(
                    orientation: orientation,
                    isEditingLayout: true,
                    usesFreeformLayout: false
                ),
                .freeform(orientation)
            )
            XCTAssertEqual(
                GamepadControllerPresentationRouting.layoutRoute(
                    orientation: orientation,
                    isEditingLayout: false,
                    usesFreeformLayout: true
                ),
                .freeform(orientation)
            )
        }
    }

    func testControllerOrientationRoutingMatchesRuntimeGeometryRule() {
        XCTAssertEqual(
            GamepadControllerPresentationRouting.orientation(for: CGSize(width: 430, height: 932)),
            .portrait
        )
        XCTAssertEqual(
            GamepadControllerPresentationRouting.orientation(for: CGSize(width: 932, height: 430)),
            .landscape
        )
        XCTAssertEqual(
            GamepadControllerPresentationRouting.orientation(for: CGSize(width: 430, height: 430)),
            .landscape
        )
    }

    func testStandardControllerSlotsPreserveLayoutOrderWithoutBuilderBranches() {
        XCTAssertEqual(
            GamepadControllerPresentationRouting.standardSlots(
                orientation: .landscape,
                layoutMode: .standard
            ),
            [
                .control(.dPad),
                .flexibleSpace(0),
                .control(.utilityButtons),
                .flexibleSpace(1),
                .control(.actionButtons)
            ]
        )
        XCTAssertEqual(
            GamepadControllerPresentationRouting.standardSlots(
                orientation: .landscape,
                layoutMode: .southpaw
            ),
            [
                .control(.actionButtons),
                .flexibleSpace(0),
                .control(.utilityButtons),
                .flexibleSpace(1),
                .control(.dPad)
            ]
        )
        XCTAssertEqual(
            GamepadControllerPresentationRouting.standardSlots(
                orientation: .portrait,
                layoutMode: .standard
            ),
            [
                .flexibleSpace(0),
                .control(.dPad),
                .control(.utilityButtons),
                .control(.actionButtons),
                .flexibleSpace(1)
            ]
        )
        XCTAssertEqual(
            GamepadControllerPresentationRouting.standardSlots(
                orientation: .portrait,
                layoutMode: .southpaw
            ),
            [
                .flexibleSpace(0),
                .control(.actionButtons),
                .control(.utilityButtons),
                .control(.dPad),
                .flexibleSpace(1)
            ]
        )
    }

    func testControlBarRoutingFiltersUnavailableAndHiddenItemsInStableOrder() {
        let items: [GamepadControlBarItem] = [
            .profileMenu,
            .home,
            .profileMenu,
            .launchTarget,
            .settings,
            .connectionStatus
        ]

        XCTAssertEqual(
            GamepadControllerPresentationRouting.visibleControlBarItems(
                items,
                hiddenItems: [.settings],
                hasProfiles: false,
                hasLaunchTarget: false
            ),
            [.home, .connectionStatus]
        )
        XCTAssertEqual(
            GamepadControllerPresentationRouting.visibleControlBarItems(
                items,
                hiddenItems: [],
                hasProfiles: true,
                hasLaunchTarget: true
            ),
            [.profileMenu, .home, .launchTarget, .settings, .connectionStatus]
        )
    }

    func testResolvedControlRoutingPreservesSpecializedFallbacks() {
        XCTAssertEqual(
            GamepadControllerPresentationRouting.resolvedControlRoute(
                kind: .decoration,
                hasJoystickMapping: false,
                hasTriggerSettings: false
            ),
            .decoration
        )
        XCTAssertEqual(
            GamepadControllerPresentationRouting.resolvedControlRoute(
                kind: .text,
                hasJoystickMapping: false,
                hasTriggerSettings: false
            ),
            .decoration
        )
        XCTAssertEqual(
            GamepadControllerPresentationRouting.resolvedControlRoute(
                kind: .joystick,
                hasJoystickMapping: true,
                hasTriggerSettings: false
            ),
            .joystick
        )
        XCTAssertEqual(
            GamepadControllerPresentationRouting.resolvedControlRoute(
                kind: .joystick,
                hasJoystickMapping: false,
                hasTriggerSettings: false
            ),
            .button
        )
        XCTAssertEqual(
            GamepadControllerPresentationRouting.resolvedControlRoute(
                kind: .trigger,
                hasJoystickMapping: false,
                hasTriggerSettings: true
            ),
            .trigger
        )
        XCTAssertEqual(
            GamepadControllerPresentationRouting.resolvedControlRoute(
                kind: .trigger,
                hasJoystickMapping: false,
                hasTriggerSettings: false
            ),
            .button
        )
        XCTAssertEqual(
            GamepadControllerPresentationRouting.resolvedControlRoute(
                kind: .trackpad,
                hasJoystickMapping: false,
                hasTriggerSettings: false
            ),
            .trackpad
        )
        XCTAssertEqual(
            GamepadControllerPresentationRouting.resolvedControlRoute(
                kind: .button,
                hasJoystickMapping: false,
                hasTriggerSettings: false
            ),
            .button
        )
    }

    func testButtonPulseSequencerSmokeSuite() {
        ButtonPulseSequencerSmokeTests.main()
    }

    func testControllerActiveInputStateSmokeSuite() {
        ControllerActiveInputStateSmokeTests.main()
    }

    func testInputLatencySimulationSmokeSuite() {
        InputLatencySimulationSmokeTests.main()
    }

    func testGamepadLayoutResolverSmokeSuite() {
        GamepadLayoutResolverSmokeTests.main()
    }

    func testBuiltInJSONInstallIsOneDocumentAndStillUsesAuthority() throws {
        let routed = try makeGenerationRoutedCLI(
            generatedJSON: try generationFixtureText("aliases-basic")
        )
        defer { try? FileManager.default.removeItem(at: routed.root) }
        let invocationID = "AAAAAAAA-BBBB-5CCC-8DDD-EEEEEEEEEEEE"

        let result = try runRoutedCLI(
            routed,
            arguments: ["generate", "Hollow Knight", "--json", "--invocation-id", invocationID]
        )
        XCTAssertEqual(result.status, 0, result.stderr)
        let document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        XCTAssertEqual(document["resolvedGameName"] as? String, "Hollow Knight")
        XCTAssertFalse(result.stdout.contains("Generated, installed"))
        XCTAssertEqual(result.stderr, "Invocation ID: \(invocationID)\n")
        let requests = try recordedGenerationRequests(in: routed)
        XCTAssertEqual(requests.count, 1)
        let command = try XCTUnwrap(requests[0]["command"] as? [String: Any])
        XCTAssertEqual(command["type"] as? String, "generation.generate")
        XCTAssertEqual(command["select"] as? Bool, true)
        XCTAssertEqual(command["makeDefault"] as? Bool, true)
    }

    func testSpecGenerationDryRunJSONRoutesRawSpecAndWritesExactRustBytesWithoutImport() throws {
        let generatedJSON = try generationFixtureText("aliases-basic")
        let routed = try makeGenerationRoutedCLI(generatedJSON: generatedJSON)
        defer { try? FileManager.default.removeItem(at: routed.root) }
        let invocationID = "AAAAAAAA-BBBB-5CCC-8DDD-EEEEEEEEEEEE"
        let specJSON = "{\n  \"gameName\": \"Original\",\n  \"controls\": []\n}"
        let input = routed.root.appendingPathComponent("spec.json")
        try Data(specJSON.utf8).write(to: input)

        let result = try runRoutedCLI(
            routed,
            arguments: [
                "generate", "Requested Override", "--spec", input.path, "--json", "--dry-run",
                "--skip-layout-validation", "--invocation-id", invocationID
            ]
        )
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(Data(result.stdout.utf8), Data(generatedJSON.utf8))
        XCTAssertEqual(result.stderr, "")
        let requests = try recordedGenerationRequests(in: routed)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0]["invocationID"] as? String, invocationID)
        let command = try XCTUnwrap(requests[0]["command"] as? [String: Any])
        XCTAssertEqual(command["type"] as? String, "generation.plan-spec")
        XCTAssertEqual(command["specJSON"] as? String, specJSON)
        XCTAssertEqual(command["requestedGameName"] as? String, "Requested Override")
    }

    func testSpecGenerationInstallUsesPlanRevisionInvocationArtifactAndFlags() throws {
        let generatedJSON = try generationFixtureText("aliases-basic")
        let artifactJSON = "{\"schema\":\"future-artifact\",\"preserve\":[1,2,3]}"
        let routed = try makeGenerationRoutedCLI(
            generatedJSON: generatedJSON,
            artifactJSON: artifactJSON
        )
        defer { try? FileManager.default.removeItem(at: routed.root) }
        let invocationID = "AAAAAAAA-BBBB-5CCC-8DDD-EEEEEEEEEEEE"
        let input = routed.root.appendingPathComponent("spec.json")
        try Data("{\"controls\":[]}".utf8).write(to: input)

        let result = try runRoutedCLI(
            routed,
            arguments: [
                "install-spec", input.path, "--json", "--no-select", "--default",
                "--skip-layout-validation", "--invocation-id", invocationID
            ]
        )
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(Data(result.stdout.utf8), Data(generatedJSON.utf8))
        XCTAssertEqual(result.stderr, "Invocation ID: \(invocationID)\n")
        let requests = try recordedGenerationRequests(in: routed)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map { $0["invocationID"] as? String }, [invocationID, invocationID])
        XCTAssertNil(requests[0]["expectedConfigurationRevision"])
        XCTAssertEqual(requests[1]["expectedConfigurationRevision"] as? Int, 41)
        let importCommand = try XCTUnwrap(requests[1]["command"] as? [String: Any])
        XCTAssertEqual(importCommand["type"] as? String, "profile.import")
        XCTAssertEqual(importCommand["artifactJSON"] as? String, artifactJSON)
        XCTAssertEqual(importCommand["appendAsCopies"] as? Bool, false)
        XCTAssertEqual(importCommand["select"] as? Bool, false)
        XCTAssertEqual(importCommand["makeDefault"] as? Bool, true)
    }

    func testSpecGenerationReportsWarningsDeterministicallyAndKeepsJSONStdoutClean() throws {
        let generatedJSON = try generationFixtureText("aliases-basic")
        let warnings: [[String: Any]] = [
            ["code": "zeta", "sourceOrdinal": 3, "message": "Later warning"],
            ["code": "slot-exhaustion", "sourceOrdinal": 0, "message": "Control dropped because every slot is assigned"]
        ]
        let routed = try makeGenerationRoutedCLI(
            generatedJSON: generatedJSON,
            warnings: warnings
        )
        defer { try? FileManager.default.removeItem(at: routed.root) }
        let input = routed.root.appendingPathComponent("spec.json")
        try Data("{}".utf8).write(to: input)

        let result = try runRoutedCLI(
            routed,
            arguments: ["generate", "--spec", input.path, "--dry-run", "--skip-layout-validation"]
        )
        XCTAssertEqual(result.status, 0, result.stderr)
        let firstWarning = "- control 1 [slot-exhaustion]: Control dropped because every slot is assigned"
        let laterWarning = "- control 4 [zeta]: Later warning"
        XCTAssertTrue(result.stdout.contains("Generation warnings (2):"))
        XCTAssertLessThan(
            try XCTUnwrap(result.stdout.range(of: firstWarning)?.lowerBound),
            try XCTUnwrap(result.stdout.range(of: laterWarning)?.lowerBound)
        )
        XCTAssertEqual(result.stdout.components(separatedBy: "Generated \"Alias Arcade\"").count - 1, 1)
        XCTAssertTrue(result.stdout.contains("Bindings:"))

        let jsonResult = try runRoutedCLI(
            routed,
            arguments: [
                "generate", "--spec", input.path, "--json", "--dry-run",
                "--skip-layout-validation"
            ]
        )
        XCTAssertEqual(jsonResult.status, 0, jsonResult.stderr)
        XCTAssertEqual(Data(jsonResult.stdout.utf8), Data(generatedJSON.utf8))
        XCTAssertTrue(jsonResult.stderr.contains("Generation warnings (2):"))
        XCTAssertTrue(jsonResult.stderr.contains(firstWarning))
        XCTAssertTrue(jsonResult.stderr.contains("dropped"))
        XCTAssertLessThan(
            try XCTUnwrap(jsonResult.stderr.range(of: firstWarning)?.lowerBound),
            try XCTUnwrap(jsonResult.stderr.range(of: laterWarning)?.lowerBound)
        )
        XCTAssertEqual(try recordedGenerationRequests(in: routed).count, 2)
    }

    func testSpecGenerationStrictJSONModeReportsWarningsBeforeFailureWithoutStdout() throws {
        let routed = try makeGenerationRoutedCLI(
            generatedJSON: try generationFixtureText("aliases-basic"),
            warnings: [["code": "fallback", "sourceOrdinal": 0, "message": "Used fallback"]]
        )
        defer { try? FileManager.default.removeItem(at: routed.root) }
        let input = routed.root.appendingPathComponent("spec.json")
        try Data("{}".utf8).write(to: input)

        let result = try runRoutedCLI(
            routed,
            arguments: [
                "generate", "--spec", input.path, "--json", "--strict-layout",
                "--skip-layout-validation"
            ]
        )
        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(result.stdout, "")
        XCTAssertTrue(result.stderr.contains("- control 1 [fallback]: Used fallback"))
        XCTAssertTrue(result.stderr.contains("Rust generation reported warnings in strict layout mode."))
        XCTAssertEqual(try recordedGenerationRequests(in: routed).count, 1)
    }

    func testSpecGenerationRejectsUnsafeOversizedAndInvalidInputsBeforeBackend() throws {
        let routed = try makeGenerationRoutedCLI(
            generatedJSON: try generationFixtureText("aliases-basic")
        )
        defer { try? FileManager.default.removeItem(at: routed.root) }
        let oversized = routed.root.appendingPathComponent("oversized.json")
        try Data(count: 256 * 1024 + 1).write(to: oversized)
        let invalidUTF8 = routed.root.appendingPathComponent("invalid.json")
        try Data([0x7B, 0xFF, 0x7D]).write(to: invalidUTF8)
        let valid = routed.root.appendingPathComponent("valid.json")
        try Data("{}".utf8).write(to: valid)
        let symlink = routed.root.appendingPathComponent("symlink.json")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: valid)

        for input in [oversized, invalidUTF8, symlink] {
            try? FileManager.default.removeItem(at: routed.record)
            let result = try runRoutedCLI(
                routed,
                arguments: [
                    "generate", "--spec", input.path, "--json", "--dry-run",
                    "--skip-layout-validation"
                ]
            )
            XCTAssertEqual(result.status, 1, input.lastPathComponent)
            XCTAssertEqual(result.stdout, "", input.lastPathComponent)
            XCTAssertFalse(FileManager.default.fileExists(atPath: routed.record.path))
        }

        let exactLimit = Data(repeating: 0x20, count: 256 * 1024)
        var result = try runRoutedCLI(
            routed,
            arguments: ["generate", "--stdin", "--json", "--dry-run", "--skip-layout-validation"],
            standardInput: exactLimit
        )
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(try recordedGenerationRequests(in: routed).count, 1)

        try? FileManager.default.removeItem(at: routed.record)
        result = try runRoutedCLI(
            routed,
            arguments: ["generate", "--stdin", "--json", "--dry-run", "--skip-layout-validation"],
            standardInput: Data(repeating: 0x20, count: 256 * 1024 + 1)
        )
        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(result.stdout, "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: routed.record.path))
    }

    func testSpecGenerationPreviewUsesPlannedSwiftProfile() throws {
        let routed = try makeGenerationRoutedCLI(
            generatedJSON: try generationFixtureText("aliases-basic")
        )
        defer { try? FileManager.default.removeItem(at: routed.root) }
        let input = routed.root.appendingPathComponent("spec.json")
        let preview = routed.root.appendingPathComponent("preview.png")
        try Data("{}".utf8).write(to: input)

        let result = try runRoutedCLI(
            routed,
            arguments: [
                "generate", "--spec", input.path, "--dry-run", "--skip-layout-validation",
                "--layout-preview", preview.path
            ]
        )
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("Wrote layout preview to \(preview.path)."))
        let previewData = try Data(contentsOf: preview)
        XCTAssertTrue(previewData.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        XCTAssertEqual(try recordedGenerationRequests(in: routed).count, 1)
    }

    func testSpecGenerationRejectsDuplicateOrMissingSourcePreviewAndInvocationValues() throws {
        let routed = try makeGenerationRoutedCLI(
            generatedJSON: try generationFixtureText("aliases-basic")
        )
        defer { try? FileManager.default.removeItem(at: routed.root) }
        let cases: [[String]] = [
            ["generate", "--stdin", "--spec", "other.json"],
            ["generate", "--spec", "--json"],
            ["generate", "--stdin", "--layout-preview", "one.png", "--preview-output", "two.png"],
            ["generate", "--stdin", "--layout-preview", "--json"],
            ["generate", "--stdin", "--invocation-id", UUID().uuidString, "--invocation-id", UUID().uuidString],
            ["generate", "--stdin", "--invocation-id", "--json"]
        ]
        for arguments in cases {
            try? FileManager.default.removeItem(at: routed.record)
            let result = try runRoutedCLI(routed, arguments: arguments, standardInput: Data("{}".utf8))
            XCTAssertEqual(result.status, 1, arguments.joined(separator: " "))
            XCTAssertFalse(FileManager.default.fileExists(atPath: routed.record.path))
        }
    }

    func testProfileExportRoutesRawArtifactBytesWithoutContaminatingStandardOutput() throws {
        let artifactJSON = "{\n  \"schema\": \"com.example.future\",\n  \"unknown\": [1, 2, 3]\n}"
        let routed = try makeRoutedCLI(exportArtifactJSON: artifactJSON)
        defer { try? FileManager.default.removeItem(at: routed.root) }
        let invocationID = "AAAAAAAA-BBBB-5CCC-8DDD-EEEEEEEEEEEE"

        var result = try runRoutedCLI(
            routed,
            arguments: ["profile", "export", "--all", "--invocation-id", invocationID]
        )
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, artifactJSON + "\n")
        var command = try recordedCommand(in: routed)
        XCTAssertEqual(command["type"] as? String, "profile.export")
        XCTAssertNil(command["target"])
        XCTAssertEqual(try recordedRequest(in: routed)["invocationID"] as? String, invocationID)

        let output = routed.root.appendingPathComponent("profile.json")
        result = try runRoutedCLI(
            routed,
            arguments: ["profile", "export", "Arcade", "-o", output.path]
        )
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(try Data(contentsOf: output), Data(artifactJSON.utf8))
        command = try recordedCommand(in: routed)
        let target = try XCTUnwrap(command["target"] as? [String: Any])
        XCTAssertEqual(target["kind"] as? String, "name")
        XCTAssertEqual(target["name"] as? String, "Arcade")
    }

    func testProfileImportPreservesExplicitCurrentArtifactFlagsAndPrintsInvocationToStderr() throws {
        let routed = try makeRoutedCLI(importedProfileNames: ["One", "Two"])
        defer { try? FileManager.default.removeItem(at: routed.root) }
        let invocationID = "AAAAAAAA-BBBB-5CCC-8DDD-EEEEEEEEEEEE"
        let artifactJSON = "{\n  \"schema\": \"\(ThumbleKeypadConfigurationExport.schemaIdentifier)\",\n  \"version\": 4,\n  \"artifactVersion\": 1,\n  \"future\": true\n}"
        let input = routed.root.appendingPathComponent("current.json")
        try Data(artifactJSON.utf8).write(to: input)

        let result = try runRoutedCLI(
            routed,
            arguments: [
                "profile", "import", input.path, "--append", "--no-select", "--default",
                "--invocation-id", invocationID
            ]
        )
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "Imported 2 profiles as copies.\n")
        XCTAssertEqual(result.stderr, "Invocation ID: \(invocationID)\n")
        let command = try recordedCommand(in: routed)
        XCTAssertEqual(command["type"] as? String, "profile.import")
        XCTAssertEqual(command["artifactJSON"] as? String, artifactJSON)
        XCTAssertEqual(command["appendAsCopies"] as? Bool, true)
        XCTAssertEqual(command["select"] as? Bool, false)
        XCTAssertEqual(command["makeDefault"] as? Bool, true)
    }

    func testCheckedInRustProfileArtifactFixtureRoutesUnchangedThroughSiblingImport() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixtureURL = repositoryRoot
            .appendingPathComponent("Host/fixtures/profile-artifact/v1.json")
        let fixtureBytes = try Data(contentsOf: fixtureURL)
        let fixture = try XCTUnwrap(
            JSONSerialization.jsonObject(with: fixtureBytes) as? [String: Any]
        )

        XCTAssertEqual(
            fixture["schema"] as? String,
            ThumbleKeypadConfigurationExport.schemaIdentifier
        )
        XCTAssertEqual(fixture["version"] as? Int, 4)
        XCTAssertEqual(fixture["artifactVersion"] as? Int, 1)
        let hash = try XCTUnwrap(fixture["contentHash"] as? [String: Any])
        XCTAssertEqual(hash["algorithm"] as? String, "sha256")
        XCTAssertEqual(hash["canonicalization"] as? String, "rfc8785")
        XCTAssertEqual(
            hash["value"] as? String,
            "c2a7a65503c80d94648642ae57c1721181fd8ad2274113846bc32d3d6670507b"
        )

        let profile = try XCTUnwrap((fixture["profiles"] as? [[String: Any]])?.first)
        let futureProfile = try XCTUnwrap(profile["futureProfileField"] as? [String: Any])
        XCTAssertEqual((futureProfile["nested"] as? [Any])?[2] as? Double, 3.5)
        let profileID = "00000000-0000-0000-0000-000000000201"
        let keyMaps = try XCTUnwrap(fixture["profileKeyBindings"] as? [String: Any])
        let keyBindings = try XCTUnwrap(keyMaps[profileID] as? [String: Any])
        let futureButton = try XCTUnwrap(keyBindings["81C296ED-309D-4F05-BB11-F5A2E2027801"] as? [String: Any])
        let futureBinding = try XCTUnwrap(futureButton["futureBindingField"] as? [String: Any])
        XCTAssertEqual(futureBinding["label"] as? String, "保持")
        let outputMaps = try XCTUnwrap(fixture["profileOutputBindings"] as? [String: Any])
        let outputBindings = try XCTUnwrap(outputMaps[profileID] as? [String: Any])
        let futureOutputButton = try XCTUnwrap(outputBindings["81C296ED-309D-4F05-BB11-F5A2E2027801"] as? [String: Any])
        let futureOutput = try XCTUnwrap(futureOutputButton["futureOutputField"] as? [String: Any])
        XCTAssertEqual(futureOutput["mode"] as? String, "next")

        let routed = try makeRoutedCLI()
        defer { try? FileManager.default.removeItem(at: routed.root) }
        let result = try runRoutedCLI(
            routed,
            arguments: ["profile", "import", fixtureURL.path]
        )
        XCTAssertEqual(result.status, 0, result.stderr)
        let command = try recordedCommand(in: routed)
        XCTAssertEqual(command["type"] as? String, "profile.import")
        let routedArtifact = try XCTUnwrap(command["artifactJSON"] as? String)
        XCTAssertEqual(Data(routedArtifact.utf8), fixtureBytes)
    }

    func testProfileImportFakeAuthorityRejectsUnsupportedSchemaAndVersion() throws {
        let routed = try makeRoutedCLI()
        defer { try? FileManager.default.removeItem(at: routed.root) }
        let invocationID = "AAAAAAAA-BBBB-5CCC-8DDD-EEEEEEEEEEEE"
        let cases = [
            (
                "{\"schema\":\"com.example.unsupported\",\"version\":4,\"profiles\":[]}",
                "profile import artifact schema is unsupported [unsupported_profile_artifact_schema]"
            ),
            (
                "{\"schema\":\"\(ThumbleKeypadConfigurationExport.schemaIdentifier)\",\"version\":999,\"profiles\":[]}",
                "profile import artifact schema version is unsupported [unsupported_profile_artifact_schema_version]"
            )
        ]
        for (index, testCase) in cases.enumerated() {
            let input = routed.root.appendingPathComponent("unsupported-\(index).json")
            try Data(testCase.0.utf8).write(to: input)
            let result = try runRoutedCLI(
                routed,
                arguments: ["profile", "import", input.path, "--invocation-id", invocationID]
            )
            XCTAssertEqual(result.status, 1)
            XCTAssertEqual(result.stdout, "")
            XCTAssertEqual(
                result.stderr,
                "thumble: \(testCase.1) Invocation ID: \(invocationID)\nRun `thumble --help` for usage.\n"
            )
        }
    }

    func testProfileImportRejectsSchemaLessEnvelopesBeforeDispatch() throws {
        struct SchemaLessEnvelope: Codable {
            var exportedAt: Int64
            var profiles: [GamepadConfigurationProfile]
            var activeProfileID: UUID
            var defaultProfileID: UUID
            var profileKeyBindings: [String: [String: MacKeyBinding]]
            var profileOutputBindings: [String: [String: MacControlOutputBinding]]
        }

        let routed = try makeRoutedCLI(importedProfileNames: ["One", "Two"])
        defer { try? FileManager.default.removeItem(at: routed.root) }
        let first = GamepadConfigurationProfile(name: "First", customization: .defaultValue)
        let second = GamepadConfigurationProfile(name: "Second", customization: .defaultValue)
        let keyBindings = [first.id.uuidString: [KeypadElementID.preset(5).rawValue: MacKeyBinding(keyCode: MacVirtualKey.space)]]
        let outputBindings = [
            second.id.uuidString: [KeypadElementID.preset(6).rawValue: MacControlOutputBinding(gamepadButtons: [.south])]
        ]
        let inputEnvelope = SchemaLessEnvelope(
            exportedAt: 123_456,
            profiles: [first, second],
            activeProfileID: second.id,
            defaultProfileID: first.id,
            profileKeyBindings: keyBindings,
            profileOutputBindings: outputBindings
        )
        let input = routed.root.appendingPathComponent("schema-less-envelope.json")
        let originalInput = try JSONEncoder().encode(inputEnvelope)
        try originalInput.write(to: input)

        let result = try runRoutedCLI(routed, arguments: ["profile", "import", input.path])
        XCTAssertNotEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stderr.contains("Unsupported profile import JSON"), result.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: routed.record.path))
        XCTAssertEqual(try Data(contentsOf: input), originalInput)
    }

    func testCurrentImportAdaptersPreserveFutureProfileAndCustomizationMetadata() throws {
        let routed = try makeRoutedCLI()
        defer { try? FileManager.default.removeItem(at: routed.root) }
        let profile = GamepadConfigurationProfile(name: "Metadata", customization: .defaultValue)
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        raw["futureProfile"] = ["source": "Incoming"]
        var customization = try XCTUnwrap(raw["customization"] as? [String: Any])
        customization["futureCustomization"] = ["source": "Incoming"]
        var elements = try XCTUnwrap(customization["elements"] as? [[String: Any]])
        elements[0]["futureElement"] = ["source": "Incoming"]
        customization["elements"] = elements
        raw["customization"] = customization
        let current: [String: Any] = ["schema": ThumbleKeypadConfigurationExport.schemaIdentifier, "version": 4,
            "profiles": [raw], "activeProfileID": profile.id.uuidString, "profileKeyBindings": [:], "profileOutputBindings": [:]]
        let generated = GeneratedGameKeypadProfile(requestedGameName: "Metadata", resolvedGameName: "Metadata",
            profile: profile, keyBindings: [.preset(5): .init(key: "Space", modifiers: ["Shift"])], source: "test", confidence: .high)
        var generatedRaw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(generated)) as? [String: Any])
        generatedRaw["profile"] = raw
        let shapes: [(String, Any)] = [("profile", raw), ("envelope", current), ("profiles", [raw]),
            ("generated", generatedRaw), ("customization", customization)]
        for (name, value) in shapes {
            let input = routed.root.appendingPathComponent(name + ".json")
            try JSONSerialization.data(withJSONObject: value).write(to: input)
            let result = try runRoutedCLI(routed, arguments: ["profile", "import", input.path])
            XCTAssertEqual(result.status, 0, result.stderr)
            let json = try XCTUnwrap(try recordedCommand(in: routed)["artifactJSON"] as? String)
            let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            let imported = try XCTUnwrap((envelope["profiles"] as? [[String: Any]])?.first)
            if name != "customization" {
                XCTAssertEqual(imported["futureProfile"] as? [String: String], ["source": "Incoming"], name)
            }
            let importedCustomization = try XCTUnwrap(imported["customization"] as? [String: Any])
            XCTAssertEqual(importedCustomization["futureCustomization"] as? [String: String], ["source": "Incoming"], name)
            XCTAssertEqual((importedCustomization["elements"] as? [[String: Any]])?.first?["futureElement"] as? [String: String], ["source": "Incoming"], name)
            let checked = try MacConfigurationBindings.decodeKeypadImport(data: Data(json.utf8), sourceName: name)
            if name == "generated" {
                let binding = checked.profiles[0].initialMacOutputBindings[.preset(5)]
                XCTAssertEqual(binding?.keyboard?.strokes.first?.keyCode, 49)
                XCTAssertEqual(binding?.keyboard?.strokes.first?.modifiers, [.shift])
                XCTAssertEqual(binding?.gamepadButtons, [.south])
            }
        }
    }

    func testCurrentRawProfileAdaptersProduceVersionFourEnvelopes() throws {
        let routed = try makeRoutedCLI()
        defer { try? FileManager.default.removeItem(at: routed.root) }
        let profile = GamepadConfigurationProfile(name: "Adapter Profile", customization: .defaultValue)
        let generated = GeneratedGameKeypadProfile(
            requestedGameName: "Adapter Game",
            resolvedGameName: "Adapter Game",
            profile: profile,
            keyBindings: [.preset(5): .init(key: "Space")],
            source: "test",
            confidence: .high
        )
        let encoder = JSONEncoder()
        let adapters: [(String, Data, Int)] = [
            ("generated", try encoder.encode(generated), 1),
            ("profile", try encoder.encode(profile), 1),
            ("profiles", try encoder.encode([
                profile,
                GamepadConfigurationProfile(name: "Second", primaryCustomization: .defaultValue)
            ]), 2),
            ("customization", try encoder.encode(GamepadCustomization.defaultValue), 1)
        ]

        for (name, data, expectedCount) in adapters {
            let input = routed.root.appendingPathComponent("\(name).json")
            try data.write(to: input)
            let result = try runRoutedCLI(routed, arguments: ["profile", "import", input.path])
            XCTAssertEqual(result.status, 0, "\(name): \(result.stderr)")
            let artifactJSON = try XCTUnwrap(try recordedCommand(in: routed)["artifactJSON"] as? String)
            let envelope = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(artifactJSON.utf8)) as? [String: Any]
            )
            XCTAssertEqual(envelope["schema"] as? String, ThumbleKeypadConfigurationExport.schemaIdentifier, name)
            XCTAssertEqual(envelope["version"] as? Int, 4, name)
            XCTAssertEqual((envelope["profiles"] as? [Any])?.count, expectedCount, name)
            if name == "customization" {
                XCTAssertEqual((envelope["profiles"] as? [[String: Any]])?.first?["name"] as? String, name)
            }
        }
    }

    func testProfileImportRejectsNonRegularOversizedAndInvalidUTF8BeforeBackend() throws {
        let routed = try makeRoutedCLI()
        defer { try? FileManager.default.removeItem(at: routed.root) }
        let directory = routed.root.appendingPathComponent("directory", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let oversized = routed.root.appendingPathComponent("oversized.json")
        try Data(count: 8 * 1024 * 1024 + 1).write(to: oversized)
        let invalidUTF8 = routed.root.appendingPathComponent("invalid.json")
        try Data([0x7B, 0x22, 0x78, 0x22, 0x3A, 0xFF, 0x7D]).write(to: invalidUTF8)
        let validFile = routed.root.appendingPathComponent("valid.json")
        try Data("{}".utf8).write(to: validFile)
        let symlink = routed.root.appendingPathComponent("symlink.json")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: validFile)
        let fifo = routed.root.appendingPathComponent("fifo.json")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)

        for input in [directory, symlink, fifo, oversized, invalidUTF8] {
            try? FileManager.default.removeItem(at: routed.record)
            let result = try runRoutedCLI(routed, arguments: ["profile", "import", input.path])
            XCTAssertNotEqual(result.status, 0, input.lastPathComponent)
            XCTAssertFalse(FileManager.default.fileExists(atPath: routed.record.path), input.lastPathComponent)
        }
    }

    func testProfileTransferRejectsAmbiguousAndUnknownArgumentsBeforeBackend() throws {
        let routed = try makeRoutedCLI()
        defer { try? FileManager.default.removeItem(at: routed.root) }
        let input = routed.root.appendingPathComponent("input.json")
        try Data("{}".utf8).write(to: input)
        let cases: [([String], String)] = [
            (["profile", "export", "--all", "Arcade"], "Profile export cannot combine --all with a target"),
            (["profile", "export", "Arcade", "Second"], "Profile export accepts only one target"),
            (["profile", "export", "--output"], "Missing path after --output"),
            (["profile", "export", "--future"], "Unknown profile export option: --future"),
            (["profile", "import", input.path, "second.json"], "Profile import accepts only one path"),
            (["profile", "import", input.path, "--name"], "Missing value after --name"),
            (["profile", "import", input.path, "--future"], "Unknown profile import option: --future")
        ]
        for (arguments, message) in cases {
            try? FileManager.default.removeItem(at: routed.record)
            let result = try runRoutedCLI(routed, arguments: arguments)
            XCTAssertEqual(result.status, 1, arguments.joined(separator: " "))
            XCTAssertEqual(result.stderr, "thumble: \(message)\nRun `thumble --help` for usage.\n")
            XCTAssertFalse(FileManager.default.fileExists(atPath: routed.record.path))
        }
    }

    func testProfileInvocationIDRejectsDuplicateMissingAndInvalidValuesExactly() throws {
        let routed = try makeRoutedCLI()
        defer { try? FileManager.default.removeItem(at: routed.root) }
        let cases: [([String], String)] = [
            (
                ["profile", "export", "--invocation-id", UUID().uuidString, "--invocation-id", UUID().uuidString],
                "--invocation-id may be provided only once"
            ),
            (["profile", "export", "--invocation-id"], "Missing UUID after --invocation-id"),
            (["profile", "export", "--invocation-id", "--all"], "Missing UUID after --invocation-id"),
            (["profile", "export", "--invocation-id", "not-a-uuid"], "--invocation-id must be an exact UUID")
        ]
        for (arguments, message) in cases {
            try? FileManager.default.removeItem(at: routed.record)
            let result = try runRoutedCLI(routed, arguments: arguments)
            XCTAssertEqual(result.status, 1)
            XCTAssertEqual(result.stderr, "thumble: \(message)\nRun `thumble --help` for usage.\n")
            XCTAssertFalse(FileManager.default.fileExists(atPath: routed.record.path))
        }
    }

    func testProfileTransferHelpDocumentsImportAndInvocationFlags() throws {
        let routed = try makeRoutedCLI()
        defer { try? FileManager.default.removeItem(at: routed.root) }
        let result = try runRoutedCLI(routed, arguments: ["--help"])
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("profile export [NAME|UUID|--all] [-o file.json] [--invocation-id UUID]"))
        XCTAssertTrue(result.stdout.contains("profile import file.json [--append] [--no-select] [--default] [--name NAME] [--invocation-id UUID]"))
    }

    private struct RoutedCLI {
        var root: URL
        var executable: URL
        var record: URL
    }

    private struct RoutedCLIResult {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    private func generationFixtureText(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(
            contentsOf: root.appendingPathComponent(
                "Host/fixtures/generation-spec/v1/generated/\(name).json"
            )
        )
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return text
    }

    private func makeGenerationRoutedCLI(
        generatedJSON: String,
        artifactJSON: String = "{\"artifact\":true}",
        warnings: [[String: Any]] = []
    ) throws -> RoutedCLI {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("thumble-generation-routing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let executable = root.appendingPathComponent("thumble")
        let builtExecutable = Bundle(for: ThumbleCLISmokeTestSuite.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("thumble")
        try FileManager.default.copyItem(at: builtExecutable, to: executable)

        let record = root.appendingPathComponent("requests.jsonl")
        let generatedBase64 = Data(generatedJSON.utf8).base64EncodedString()
        let artifactBase64 = Data(artifactJSON.utf8).base64EncodedString()
        let warningsBase64 = try JSONSerialization.data(withJSONObject: warnings).base64EncodedString()
        let recordBase64 = Data(record.path.utf8).base64EncodedString()
        let bridge = root.appendingPathComponent("thumble-cli-bridge")
        let script = """
        #!/usr/bin/python3
        import base64
        import json
        import sys
        request_text = sys.stdin.readline()
        record = base64.b64decode("\(recordBase64)").decode("utf-8")
        with open(record, "a", encoding="utf-8") as output:
            output.write(request_text)
        request = json.loads(request_text)
        command = request["command"]
        response = {
            "schemaVersion": 8,
            "ok": True,
            "invocationID": request["invocationID"],
            "authorityMode": "offline"
        }
        if command["type"] == "generation.plan-spec":
            response["generationPlan"] = {
                "configurationRevision": 41,
                "schemaVersion": 1,
                "catalogRevision": 1,
                "plannerRevision": 1,
                "descriptorDigest": "b" * 64,
                "generatedJSON": base64.b64decode("\(generatedBase64)").decode("utf-8"),
                "artifactJSON": base64.b64decode("\(artifactBase64)").decode("utf-8"),
                "contentHash": {
                    "algorithm": "sha256",
                    "canonicalization": "rfc8785",
                    "value": "c" * 64
                },
                "warnings": json.loads(base64.b64decode("\(warningsBase64)")),
                "omittedWarningCount": 0,
                "assignedControls": [],
                "droppedControls": [],
                "layoutQuality": {
                    "issueCount": 0,
                    "errorCount": 0,
                    "warningCount": 0,
                    "issues": [],
                    "omittedIssueCount": 0
                }
            }
        elif command["type"] in ["profile.import", "generation.generate"]:
            is_builtin = command["type"] == "generation.generate"
            response["outcome"] = {
                "operation": command["type"],
                "profileNames": ["Hollow Knight" if is_builtin else "Alias Arcade"],
                "removedEveryProfile": False,
                "changed": True,
                "configurationRevision": 42,
                "draftID": "AAAAAAAA-BBBB-5CCC-8DDD-EEEEEEEEEEE1",
                "commitID": "AAAAAAAA-BBBB-5CCC-8DDD-EEEEEEEEEEE2",
                "idempotentReplay": False
            }
        else:
            response["ok"] = False
            response["error"] = {
                "code": "unexpected_command",
                "message": "unexpected command"
            }
        print(json.dumps(response, separators=(",", ":")))
        """
        try script.write(to: bridge, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(bridge.path, 0o700), 0)
        return RoutedCLI(root: root, executable: executable, record: record)
    }

    private func recordedGenerationRequests(in routed: RoutedCLI) throws -> [[String: Any]] {
        let text = try String(contentsOf: routed.record, encoding: .utf8)
        return try text.split(separator: "\n").map { line in
            try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            )
        }
    }

    private func makeRoutedCLI(
        exportArtifactJSON: String = "{}",
        importedProfileNames: [String] = ["Imported"]
    ) throws -> RoutedCLI {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("thumble-cli-routing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let executable = root.appendingPathComponent("thumble")
        let builtExecutable = Bundle(for: ThumbleCLISmokeTestSuite.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("thumble")
        try FileManager.default.copyItem(at: builtExecutable, to: executable)

        let record = root.appendingPathComponent("request.json")
        let artifactBase64 = Data(exportArtifactJSON.utf8).base64EncodedString()
        let namesBase64 = try JSONEncoder().encode(importedProfileNames).base64EncodedString()
        let recordBase64 = Data(record.path.utf8).base64EncodedString()
        let bridge = root.appendingPathComponent("thumble-cli-bridge")
        let script = """
        #!/usr/bin/python3
        import base64
        import json
        import sys
        request_text = sys.stdin.readline()
        record = base64.b64decode("\(recordBase64)").decode("utf-8")
        with open(record, "w", encoding="utf-8") as output:
            output.write(request_text)
        request = json.loads(request_text)
        command = request["command"]
        response = {
            "schemaVersion": 8,
            "ok": True,
            "invocationID": request["invocationID"],
            "authorityMode": "offline"
        }
        if command["type"] == "profile.export":
            response["artifact"] = {
                "configurationRevision": 21,
                "artifactJSON": base64.b64decode("\(artifactBase64)").decode("utf-8"),
                "contentHash": {
                    "algorithm": "sha256",
                    "canonicalization": "rfc8785",
                    "value": "a" * 64
                }
            }
        else:
            artifact = json.loads(command["artifactJSON"])
            expected_schema = "com.codybontecou.pocketpad.keypad-configuration"
            if artifact.get("schema") != expected_schema:
                response["ok"] = False
                response["error"] = {
                    "code": "unsupported_profile_artifact_schema",
                    "message": "profile import artifact schema is unsupported"
                }
            elif artifact.get("version") != 4:
                response["ok"] = False
                response["error"] = {
                    "code": "unsupported_profile_artifact_schema_version",
                    "message": "profile import artifact schema version is unsupported"
                }
            elif "artifactVersion" in artifact and artifact["artifactVersion"] != 1:
                response["ok"] = False
                response["error"] = {
                    "code": "unsupported_profile_artifact_version",
                    "message": "profile import artifact version is unsupported"
                }
            else:
                response["outcome"] = {
                    "operation": "profile.import",
                    "profileNames": json.loads(base64.b64decode("\(namesBase64)")),
                    "removedEveryProfile": False,
                    "changed": True,
                    "configurationRevision": 22,
                    "draftID": "AAAAAAAA-BBBB-5CCC-8DDD-EEEEEEEEEEE1",
                    "commitID": "AAAAAAAA-BBBB-5CCC-8DDD-EEEEEEEEEEE2",
                    "idempotentReplay": False
                }
        print(json.dumps(response, separators=(",", ":")))
        """
        try script.write(to: bridge, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(bridge.path, 0o700), 0)
        return RoutedCLI(root: root, executable: executable, record: record)
    }

    private func runRoutedCLI(
        _ routed: RoutedCLI,
        arguments: [String],
        standardInput: Data? = nil
    ) throws -> RoutedCLIResult {
        let process = Process()
        // Generated profiles can exceed pipe capacity. File-backed capture keeps
        // the child from blocking while the synchronous harness waits for exit.
        let token = UUID().uuidString
        let stdoutURL = routed.root.appendingPathComponent("stdout-\(token)")
        let stderrURL = routed.root.appendingPathComponent("stderr-\(token)")
        try Data().write(to: stdoutURL)
        try Data().write(to: stderrURL)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdout.close()
            try? stderr.close()
            try? FileManager.default.removeItem(at: stdoutURL)
            try? FileManager.default.removeItem(at: stderrURL)
        }
        let stdin = standardInput.map { _ in Pipe() }
        process.executableURL = routed.executable
        process.arguments = arguments
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        if let standardInput, let stdin {
            try? stdin.fileHandleForWriting.write(contentsOf: standardInput)
            try? stdin.fileHandleForWriting.close()
        }
        process.waitUntilExit()
        return RoutedCLIResult(
            status: process.terminationStatus,
            stdout: String(decoding: try Data(contentsOf: stdoutURL), as: UTF8.self),
            stderr: String(decoding: try Data(contentsOf: stderrURL), as: UTF8.self)
        )
    }

    private func recordedRequest(in routed: RoutedCLI) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: routed.record)) as? [String: Any]
        )
    }

    private func recordedCommand(in routed: RoutedCLI) throws -> [String: Any] {
        try XCTUnwrap(try recordedRequest(in: routed)["command"] as? [String: Any])
    }
}
