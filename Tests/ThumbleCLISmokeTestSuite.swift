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
        customization.labelOverrides[.jump] = "Fire"
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

    func testKeypadConfigurationNormalizesLegacyButtonsIntoElements() throws {
        var customization = GamepadCustomization.defaultValue.normalized
        XCTAssertFalse(customization.elements.isEmpty)
        XCTAssertNotNil(customization.elements.first { $0.builtInButton == .pause })
        XCTAssertEqual(customization.elements.first { $0.builtInButton == .pause }?.legacySlot, .pause)

        customization.addCustomButton()
        var added = try XCTUnwrap(customization.normalized.elements.first { $0.builtInButton == nil && $0.kind == .button })
        XCTAssertNil(added.legacySlot)

        customization = GamepadCustomization.blankCanvas
        customization.addJoystick()
        added = try XCTUnwrap(customization.normalized.elements.first { $0.kind == .joystick })
        XCTAssertNil(added.legacySlot)

        customization = GamepadCustomization.blankCanvas
        customization.addTrigger()
        added = try XCTUnwrap(customization.normalized.elements.first { $0.kind == .trigger })
        XCTAssertNil(added.legacySlot)

        customization = GamepadCustomization.blankCanvas
        customization.addTrackpad()
        added = try XCTUnwrap(customization.normalized.elements.first { $0.kind == .trackpad })
        XCTAssertNil(added.legacySlot)
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

        for button in GameButton.builtInControls {
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
        XCTAssertEqual(decoded.gamepadProfiles?.first?.customization.normalized.buttonCustomizations.count, GameButton.builtInControls.count)
    }

    func testAddedJoystickDefaultsToKeyboardDigitalDirections() throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-00000000D1D1")!
        var customization = GamepadCustomization.blankCanvas
        customization.addJoystick(id: id)

        let joystick = try XCTUnwrap(customization.normalized.customButtons.first(where: { $0.id == id })?.normalized)
        XCTAssertEqual(joystick.label, "Arrow Keys")
        XCTAssertEqual(joystick.mappedButton, .up)
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
            button: .jump,
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
            pressedButtons: [.jump],
            detail: "smoke"
        )

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(ThumbleCaptureEvent.self, from: data)
        XCTAssertEqual(decoded.sequence, 42)
        XCTAssertEqual(decoded.kind, "button")
        XCTAssertEqual(decoded.source, "iPhone UDP")
        XCTAssertEqual(decoded.messageType, .button)
        XCTAssertEqual(decoded.button, .jump)
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
        XCTAssertEqual(decoded.pressedButtons, [.jump])
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
            pressedButtons: [.jump],
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

    func testElementRuntimeCommandPayloadRoundTripsAndLegacyPayloadStillDecodes() throws {
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
        let legacy = try JSONDecoder().decode(ThumbleMacCLICommandPayload.self, from: legacyData)
        XCTAssertEqual(legacy.command, .testUp)
        XCTAssertEqual(legacy.button, .jump)
        XCTAssertNil(legacy.elementInput)
        XCTAssertEqual(legacy.reason, "Legacy test")
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

    func testKeypadProfileOutputModeDefaultsToKeyboardAndPreservesLegacyBindings() throws {
        let newProfile = GamepadConfigurationProfile(name: "Keyboard Setup", customization: .defaultValue)
        XCTAssertEqual(newProfile.outputMode, .keyboard)

        let legacyJSON = """
        {
          "id": "00000000-0000-0000-0000-00000000ABCD",
          "name": "Legacy Mixed Setup",
          "customization": {}
        }
        """
        let legacyProfile = try JSONDecoder().decode(GamepadConfigurationProfile.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(legacyProfile.outputMode, .custom)
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
              "up": "up",
              "down": "down",
              "left": "left",
              "right": "right"
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
        XCTAssertEqual(generated.keyBindings[trackpad.mappedButton]?.key, "Space")
    }

    func testDesignMetadataLayerOrderControlsResolvedZOrder() throws {
        var customization = GamepadCustomization.defaultValue
        customization.addCustomButton(id: UUID(uuidString: "00000000-0000-0000-0000-00000000CAFE")!, mappedTo: .custom1)
        customization.designMetadata = GamepadDesignMetadata(
            layerOrder: [.custom(UUID(uuidString: "00000000-0000-0000-0000-00000000CAFE")!), .builtin(.jump)]
        )

        let controls = customization.normalized.resolvedControls(in: CGSize(width: 874, height: 402))
        let jumpIndex = controls.firstIndex { $0.id == .builtin(.jump) }
        let customIndex = controls.firstIndex { $0.id == .custom(UUID(uuidString: "00000000-0000-0000-0000-00000000CAFE")!) }
        XCTAssertNotNil(jumpIndex)
        XCTAssertNotNil(customIndex)
        XCTAssertLessThan(customIndex!, jumpIndex!)
    }

    func testControlZIndexOverridesLayerOrderForResolvedZOrder() throws {
        let backID = UUID(uuidString: "00000000-0000-0000-0000-00000000D111")!
        let frontID = UUID(uuidString: "00000000-0000-0000-0000-00000000D222")!
        var customization = GamepadCustomization.blankCanvas
        customization.addCustomButton(id: backID, mappedTo: .custom1)
        customization.addCustomButton(id: frontID, mappedTo: .custom2)
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
        var customization = GamepadCustomization.blankCanvas
        customization.addCustomButton(id: firstID, mappedTo: .custom1)
        customization.addCustomButton(id: secondID, mappedTo: .custom2)
        customization.designMetadata = GamepadDesignMetadata(
            layerOrder: [.custom(firstID), .custom(secondID), .builtin(.jump)],
            groups: [GamepadLayerGroup(name: "Pair", children: [.custom(firstID), .custom(secondID)])]
        )

        customization.bringLayersForward([.custom(firstID), .custom(secondID)])
        XCTAssertEqual(
            Array(customization.orderedControlIdentitiesForDesign.prefix(3)),
            [.builtin(.jump), .custom(firstID), .custom(secondID)]
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
        customization.setButtonCustomization(layout, for: .focus)

        let control = customization.resolvedControls(in: CGSize(width: 874, height: 402)).first { $0.id == .builtin(.focus) }!
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
        layout = decoded.buttonCustomization(for: .focus)
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
              "button": "focus",
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
        let layout = generated.profile.customization.buttonCustomization(for: .focus)
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
        XCTAssertEqual(aliases.profile.id.uuidString.lowercased(), "b6e5fb93-be66-5a82-9801-88da1dbb4c49")
        XCTAssertEqual(aliases.profile, aliases.profile.normalized)
        XCTAssertEqual(aliases.profile.outputMode, .keyboard)
        XCTAssertEqual(aliases.profile.customization.visualLabel(for: .up), "Move Up")
        XCTAssertEqual(aliases.profile.customization.visualLabel(for: .jump), "Jump")
        XCTAssertEqual(aliases.keyBindings[.up], .init(key: "up arrow"))
        XCTAssertEqual(aliases.keyBindings[.jump], .init(key: "space-bar", modifiers: ["shift"]))

        let specialized = try fixture("specialized-capacity")
        XCTAssertEqual(specialized.profile.id.uuidString.lowercased(), "64542b15-5a6f-5c8d-ba94-99cd24da68f7")
        XCTAssertEqual(specialized.profile, specialized.profile.normalized)
        XCTAssertEqual(specialized.profile.outputMode, .keyboard)
        let specializedControls = specialized.profile.customization.customButtons.map(\.normalized)
        XCTAssertEqual(specializedControls.filter(\.isJoystick).count, 2)
        XCTAssertEqual(specializedControls.filter(\.isTrigger).count, 2)
        XCTAssertEqual(specializedControls.filter(\.isTrackpad).count, 1)
        XCTAssertEqual(Set(specializedControls.map { $0.id.uuidString.lowercased() }), Set([
            "95e98733-8394-53b3-9a63-95f364da5cad",
            "e31e8da3-f034-538f-8e47-cdac8de728a3",
            "d1f85e97-c08b-5757-b400-50f8cfd4eefa",
            "cd604c20-d5a4-5bc2-a4a5-b300a32f1138",
            "213a5b40-5a29-5437-b1e6-b2cdf42ee0a1"
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
        XCTAssertEqual(Set(specialized.keyBindings.keys), Set([.custom1, .custom2, .custom4, .custom5, .custom7]))

        let trigger = try fixture("trigger-defaults")
        XCTAssertEqual(trigger.profile.id.uuidString.lowercased(), "2c6d329f-e7c2-5895-aa29-a290e42032d5")
        let triggerControl = try XCTUnwrap(trigger.profile.customization.customButtons.first?.normalized)
        XCTAssertEqual(triggerControl.id.uuidString.lowercased(), "1938d035-4098-5bfc-9c99-baa58e176420")
        XCTAssertEqual(triggerControl.label, "Right Trigge")
        XCTAssertEqual(triggerControl.label.count, GamepadCustomization.maximumLabelLength)
        XCTAssertEqual(triggerControl.triggerSettings, .defaultValue)
        XCTAssertEqual(triggerControl.layout.shape, .ellipse)
        XCTAssertEqual(trigger.keyBindings, [.custom1: .init(key: "R")])
        XCTAssertEqual(trigger.profile.outputMode, .keyboard)

        let rich = try fixture("rich-appearance")
        XCTAssertEqual(rich.profile.id.uuidString.lowercased(), "5dbf90ec-609d-5a93-b547-9104e3966d6b")
        XCTAssertEqual(rich.profile, rich.profile.normalized)
        XCTAssertEqual(rich.profile.outputMode, .keyboard)
        XCTAssertEqual(rich.keyBindings, [.focus: .init(key: "F")])
        let richLayout = rich.profile.customization.buttonCustomization(for: .focus)
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
        let expectedLabels: [GameButton: String] = [
            .left: "Left",
            .right: "Right",
            .up: "Up",
            .down: "Down",
            .jump: "Return",
            .attack: "Tab",
            .dash: "Command",
            .focus: "Prefix",
            .map: "Palette",
            .pause: "Escape"
        ]
        let profile = GamepadControllerTemplate.productivityStarter.makeProfile()

        for orientation in GamepadEditorDeviceOrientation.allCases {
            let customization = profile.customization(for: orientation)
            for (button, expectedLabel) in expectedLabels {
                XCTAssertEqual(customization.visualLabel(for: button), expectedLabel, "\(orientation.displayName) \(button.rawValue)")
            }
        }
    }

    func testTemplatesSeedCompleteBindingsWithoutInheritingTheActiveProfile() throws {
        for template in [
            GamepadControllerTemplate.productivityStarter,
            .productivityOneHandedLeft,
            .productivityOneHandedRight
        ] {
            let recommended = try XCTUnwrap(template.recommendedMacOutputBindings)
            XCTAssertEqual(recommended, DefaultMacControlOutputMap.defaultBindings)
            XCTAssertEqual(recommended[.dash]?.displayName, "⌘K")
            XCTAssertEqual(recommended[.focus]?.displayName, "⌃B")
            XCTAssertEqual(recommended[.map]?.displayName, "⇧⌘P")
        }

        for template in GamepadControllerTemplate.allCases.dropFirst(3) {
            let recommended = try XCTUnwrap(template.recommendedMacOutputBindings)
            XCTAssertEqual(recommended, DefaultMacControlOutputMap.gamingKeyboardBindings)
            XCTAssertEqual(template.makeProfile().recommendedMacOutputBindings, recommended, template.displayName)
        }

        let xbox = try XCTUnwrap(GamepadControllerTemplate.xbox.recommendedMacOutputBindings)
        XCTAssertEqual(xbox.count, GameButton.allCases.count)
        XCTAssertEqual(xbox[.up]?.displayName, "W")
        XCTAssertEqual(xbox[.down]?.displayName, "S")
        XCTAssertEqual(xbox[.left]?.displayName, "A")
        XCTAssertEqual(xbox[.right]?.displayName, "D")
        XCTAssertEqual(xbox[.jump]?.displayName, "Space")
        XCTAssertEqual(xbox[.pause]?.displayName, "Esc")
        for button in [GameButton.custom1, .custom2, .custom3, .custom4, .custom5, .custom6, .custom7, .custom8] {
            XCTAssertNotNil(xbox[button], button.rawValue)
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
            landscape.buttonCustomization(for: .jump).centerX,
            portrait.buttonCustomization(for: .jump).centerX
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
            for button in GameButton.builtInControls {
                XCTAssertNotNil(customization.buttonCustomization(for: button).icon, "\(template.displayName) \(button.rawValue) icon")
            }

            XCTAssertEqual(customization.buttonCustomization(for: .up).shape, .roundedRectangle)
            XCTAssertEqual(customization.buttonCustomization(for: .jump).shape, .capsule)
            XCTAssertEqual(customization.buttonCustomization(for: .dash).shape, .rectangle)
            XCTAssertEqual(customization.buttonCustomization(for: .pause).shape, .circle)
            XCTAssertEqual(customization.buttonCustomization(for: .up).resolvedHapticFeedback.pattern, .single)
            XCTAssertEqual(customization.buttonCustomization(for: .jump).resolvedHapticFeedback.pattern, .double)
            XCTAssertEqual(customization.buttonCustomization(for: .dash).resolvedHapticFeedback.pattern, .pulse)
            XCTAssertEqual(customization.buttonCustomization(for: .pause).resolvedHapticFeedback.pattern, .buzz)
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
        legacyCustomization.addCustomButton(id: UUID(uuidString: "00000000-0000-0000-0000-00000000E003")!, mappedTo: .custom1)
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

    func testProfilePersistenceDoesNotReplaceSavedProfileWithStaleLegacyMirror() {
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
        savedCustomization.setLabel("Saved", for: .jump)
        savedCustomization.updatedAt = 200
        profile.customization = savedCustomization
        profile.updatedAt = 200
        GamepadConfigurationProfilePersistence.save(
            [profile],
            activeProfileID: profile.id,
            defaultProfileID: profile.id
        )

        var staleMirror = savedCustomization
        staleMirror.setLabel("Stale", for: .jump)
        staleMirror.updatedAt = 100
        let loaded = GamepadConfigurationProfilePersistence.load(activeCustomization: staleMirror)

        XCTAssertEqual(loaded.activeProfile?.customization.visualLabel(for: .jump), "Saved")
        XCTAssertEqual(loaded.activeProfile?.customization.updatedAt, 200)
    }

    func testSoftWhiteThemeAndTemplateSupportDecorationLayers() throws {
        var customization = GamepadCustomization.defaultValue
        GamepadThemePreset.softWhiteController.apply(to: &customization)
        let themed = customization.normalized
        XCTAssertEqual(themed.colorSchemePreference, .light)
        XCTAssertTrue(themed.styleLibrary.style(id: "soft-white-raised") != nil)
        XCTAssertEqual(themed.buttonCustomization(for: .jump).styleID, "soft-white-lavender")
        let jump = themed.resolvedControls(in: CGSize(width: 874, height: 402)).first { $0.id == .builtin(.jump) }!
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
                mappedButton: .custom1,
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
        XCTAssertEqual(normalized.buttonCustomization(for: .focus).styleID, "cavern-soul")
        XCTAssertEqual(normalized.buttonCustomization(for: .attack).styleID, "cavern-nail")
        XCTAssertEqual(normalized.buttonCustomization(for: .dash).styleID, "cavern-dash")
        XCTAssertTrue(normalized.designMetadata?.tags.contains("marketable") == true)

        let focus = normalized.resolvedControls(in: CGSize(width: 874, height: 402)).first { $0.id == .builtin(.focus) }!
        let normal = normalized.resolvedPresentation(for: focus, state: .normal, scheme: .dark)
        let pressed = normalized.resolvedPresentation(for: focus, state: .pressed, scheme: .dark)
        XCTAssertEqual(normal.icon?.value, "sparkles")
        XCTAssertEqual(normal.hapticFeedback.pattern, .pulse)
        XCTAssertNotNil(normal.glowColor)
        XCTAssertNotEqual(normal.fillStyle.representativeColor, pressed.fillStyle.representativeColor)
    }

    func testHollowKnightBuiltInUsesMarketableCavernGlowTheme() throws {
        let generated = try XCTUnwrap(GameKeypadGenerator.generate(for: "Hollow Knight"))
        let customization = generated.profile.customization.normalized

        XCTAssertEqual(generated.source, "Built-in Hollow Knight default keyboard template with Thumble's Cavern Glow showcase theme")
        XCTAssertEqual(customization.colorSchemePreference, .dark)
        XCTAssertEqual(customization.buttonCustomization(for: .focus).styleID, "cavern-soul")
        XCTAssertEqual(customization.buttonCustomization(for: .attack).styleID, "cavern-nail")
        XCTAssertEqual(customization.buttonCustomization(for: .map).styleID, "cavern-parchment")
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
            "71bb1a2c4832391a93df43ff42cc970b2ff90e8e85bc4041eebbfaa6d2cee3ff"
        )

        let profile = try XCTUnwrap((fixture["profiles"] as? [[String: Any]])?.first)
        let futureProfile = try XCTUnwrap(profile["futureProfileField"] as? [String: Any])
        XCTAssertEqual((futureProfile["nested"] as? [Any])?[2] as? Double, 3.5)
        let profileID = "00000000-0000-0000-0000-000000000201"
        let keyMaps = try XCTUnwrap(fixture["profileKeyBindings"] as? [String: Any])
        let keyBindings = try XCTUnwrap(keyMaps[profileID] as? [String: Any])
        let futureButton = try XCTUnwrap(keyBindings["futureButton"] as? [String: Any])
        let futureBinding = try XCTUnwrap(futureButton["futureBindingField"] as? [String: Any])
        XCTAssertEqual(futureBinding["label"] as? String, "保持")
        let outputMaps = try XCTUnwrap(fixture["profileOutputBindings"] as? [String: Any])
        let outputBindings = try XCTUnwrap(outputMaps[profileID] as? [String: Any])
        let futureOutputButton = try XCTUnwrap(outputBindings["futureButton"] as? [String: Any])
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

    func testProfileImportSchemaLessEnvelopeAdapterRunsFirstAndPreservesCatalogMetadata() throws {
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
        let keyBindings = [first.id.uuidString: ["jump": MacKeyBinding(keyCode: MacVirtualKey.space)]]
        let outputBindings = [
            second.id.uuidString: ["attack": MacControlOutputBinding(gamepadButtons: [.south])]
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
        try JSONEncoder().encode(inputEnvelope).write(to: input)

        let result = try runRoutedCLI(routed, arguments: ["profile", "import", input.path])
        XCTAssertEqual(result.status, 0, result.stderr)
        let artifactJSON = try XCTUnwrap(try recordedCommand(in: routed)["artifactJSON"] as? String)
        let adapted = try JSONDecoder().decode(SchemaLessEnvelope.self, from: Data(artifactJSON.utf8))
        XCTAssertEqual(adapted.exportedAt, 123_456)
        XCTAssertEqual(adapted.profiles.map(\.id), [first.id, second.id])
        XCTAssertEqual(adapted.activeProfileID, second.id)
        XCTAssertEqual(adapted.defaultProfileID, first.id)
        XCTAssertEqual(adapted.profileKeyBindings, keyBindings)
        XCTAssertEqual(adapted.profileOutputBindings, outputBindings)
    }

    func testProfileImportLegacyAdaptersProduceVersionFourEnvelopes() throws {
        let routed = try makeRoutedCLI()
        defer { try? FileManager.default.removeItem(at: routed.root) }
        let profile = GamepadConfigurationProfile(name: "Adapter Profile", customization: .defaultValue)
        let generated = GeneratedGameKeypadProfile(
            requestedGameName: "Adapter Game",
            resolvedGameName: "Adapter Game",
            profile: profile,
            keyBindings: [.jump: .init(key: "Space")],
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
            elif artifact.get("version") not in range(1, 5):
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
        let stdout = Pipe()
        let stderr = Pipe()
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
            stdout: String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            stderr: String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
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
