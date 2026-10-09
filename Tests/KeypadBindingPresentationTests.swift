import XCTest

final class KeypadBindingPresentationTests: XCTestCase {
    func testKeyboardAuthoringVocabularyMatchesNativeAdaptersAndRejectsUnknownKeys() throws {
        for code: UInt16 in 0...127 {
            let name = KeypadKeyboardKeyCatalog.displayName(for: code)
            if name.hasPrefix("Key ") { continue }
            XCTAssertEqual(KeypadKeyboardKeyCatalog.keyCode(named: name), code)
            XCTAssertEqual(MacVirtualKey.displayName(for: code), name)
            let shared = try XCTUnwrap(KeypadKeyboardBinding(keyName: name, modifierNames: ["CTRL", "Alt", "Shift", "Meta", "ctrl"]))
            let native = try XCTUnwrap(MacKeyBinding(generatedSpec: GeneratedKeyBindingSpec(key: name, modifiers: ["CTRL", "Alt", "Shift", "Meta", "ctrl"])))
            XCTAssertEqual(native.sharedBinding, shared)
            XCTAssertEqual(shared.modifiersRawValue, 15)
        }
        for name in ["left-arrow", "arrow left", "LeftArrow", "←"] {
            XCTAssertEqual(KeypadKeyboardKeyCatalog.keyCode(named: name), 123)
        }
        for name in ["!", "💡", "not-a-key", "10", "65535", ""] {
            XCTAssertNil(KeypadKeyboardBinding(keyName: name), name)
            XCTAssertNil(MacKeyBinding(generatedSpec: GeneratedKeyBindingSpec(key: name)), name)
        }
        XCTAssertNil(KeypadKeyboardBinding(keyName: "Space", modifierNames: ["unknown"]))
    }

    func testControllerMessageWithoutPresentationsRemainsDecodable() throws {
        let oldPayload = Data(#"{"type":"gamepad_profiles","timestamp":0,"gamepadProfiles":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(ControllerMessage.self, from: oldPayload)
        XCTAssertEqual(decoded.type, .gamepadProfiles)
        XCTAssertNil(decoded.bindingPresentations)
    }

    func testControllerMessagePresentationRoundTrip() throws {
        let profileID = UUID(uuidString: "00000000-0000-0000-0000-00000000B001")!
        let input = KeypadElementInputID(elementID: UUID(uuidString: "00000000-0000-0000-0000-00000000E001")!)
        let presentations = [
            GamepadProfileBindingPresentations(
                profileID: profileID,
                entries: [KeypadBindingPresentation(input: input, compactText: "⌘K", accessibilityText: "Command K")]
            )
        ]
        let message = ControllerMessage(type: .gamepadProfiles, bindingPresentations: presentations)
        let decoded = try JSONDecoder().decode(ControllerMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(decoded.bindingPresentations, presentations)
    }

    func testCompactAndAccessibilityFormatting() throws {
        let palette = try XCTUnwrap(KeypadBindingFormatter.format(
            KeypadKeyboardBinding(keyCode: 35, modifiersRawValue: (1 << 0) | (1 << 1))
        ))
        XCTAssertEqual(palette.compactText, "⇧⌘P")
        XCTAssertEqual(palette.accessibilityText, "Shift Command P")

        let escape = try XCTUnwrap(KeypadBindingFormatter.format(KeypadKeyboardBinding(keyCode: 53)))
        XCTAssertEqual(escape.compactText, "Esc")
        XCTAssertEqual(escape.accessibilityText, "Escape")

        let space = try XCTUnwrap(KeypadBindingFormatter.format(KeypadKeyboardBinding(keyCode: 49)))
        XCTAssertEqual(space.compactText, "Space")
        XCTAssertEqual(space.accessibilityText, "Space")

        let sequence = try XCTUnwrap(KeypadBindingFormatter.format(
            KeypadKeyboardBinding(
                keyCode: 11,
                modifiersRawValue: 1 << 3,
                sequence: [
                    KeypadKeyboardStrokeBinding(keyCode: 11, modifiersRawValue: 1 << 3),
                    KeypadKeyboardStrokeBinding(keyCode: 4)
                ]
            )
        ))
        XCTAssertEqual(sequence.compactText, "⌃B › H")
        XCTAssertEqual(sequence.accessibilityText, "Control B, then H")
    }

    func testPerProfilePresentationsAreIsolated() throws {
        var firstCustomization = GamepadCustomization.defaultValue
        try firstCustomization.setStandaloneElementOutput(KeypadElementOutputBinding(keyboard: KeypadKeyboardBinding(keyCode: 49)), for: .builtin(.preset(5)), part: .primary)
        var secondCustomization = GamepadCustomization.defaultValue
        try secondCustomization.setStandaloneElementOutput(KeypadElementOutputBinding(keyboard: KeypadKeyboardBinding(keyCode: 36)), for: .builtin(.preset(5)), part: .primary)
        let first = GamepadConfigurationProfile(name: "First", customization: firstCustomization)
        let second = GamepadConfigurationProfile(name: "Second", customization: secondCustomization)
        let firstOutputs: [KeypadElementID: KeypadElementOutputBinding] = [
            .preset(5): KeypadElementOutputBinding(keyboard: KeypadKeyboardBinding(keyCode: 49))
        ]
        let secondOutputs: [KeypadElementID: KeypadElementOutputBinding] = [
            .preset(5): KeypadElementOutputBinding(keyboard: KeypadKeyboardBinding(keyCode: 36))
        ]

        let all = KeypadBindingPresentationBuilder.presentations(for: first, elementOutputs: firstOutputs)
            + KeypadBindingPresentationBuilder.presentations(for: second, elementOutputs: secondOutputs)
        let jumpInput = KeypadElementInputID(elementID: KeypadElement.builtInID(for: .preset(5)))
        XCTAssertEqual(
            all.bindingPresentation(profileID: first.id, orientation: .landscape, input: jumpInput)?.compactText,
            "Space"
        )
        XCTAssertEqual(
            all.bindingPresentation(profileID: second.id, orientation: .landscape, input: jumpInput)?.compactText,
            "Return"
        )
    }

    func testOwnedOutputsOverrideStaleSidecars() throws {
        var customization = GamepadCustomization.defaultValue.normalized
        let jumpID = KeypadElement.builtInID(for: .preset(5))
        let pauseID = KeypadElement.builtInID(for: .preset(10))
        let jumpIndex = try XCTUnwrap(customization.elements.firstIndex { $0.id == jumpID })
        customization.elements[jumpIndex].setOutputBinding(
            KeypadElementOutputBinding(keyboard: KeypadKeyboardBinding(keyCode: 53))
        )
        let profile = GamepadConfigurationProfile(name: "Mixed", customization: customization)
        let staleSidecar: [KeypadElementID: KeypadElementOutputBinding] = [
            .preset(5): KeypadElementOutputBinding(keyboard: KeypadKeyboardBinding(keyCode: 49)),
            .preset(10): KeypadElementOutputBinding(keyboard: KeypadKeyboardBinding(keyCode: 49))
        ]
        let presentations = KeypadBindingPresentationBuilder.presentations(for: profile, elementOutputs: staleSidecar)

        XCTAssertEqual(
            presentations.bindingPresentation(
                profileID: profile.id,
                orientation: .landscape,
                input: KeypadElementInputID(elementID: jumpID)
            )?.compactText,
            "Esc",
            "Owned output must override a stale sidecar"
        )
        XCTAssertEqual(
            presentations.bindingPresentation(
                profileID: profile.id,
                orientation: .landscape,
                input: KeypadElementInputID(elementID: pauseID)
            )?.compactText,
            "Esc",
            "The declared control's owned output must not be replaced by a sidecar"
        )
    }

    func testPresentationsFilterOutputModeWithoutChangingOwnedBindings() throws {
        let element = KeypadElement(label: "Same label", output: KeypadElementOutputBinding(keyboard: KeypadKeyboardBinding(keyCode: 53), gamepadButtons: [.south]))
        var profile = GamepadConfigurationProfile(name: "Modes", customization: GamepadCustomization(elements: [element]))
        let input = KeypadElementInputID(elementID: element.id)
        for (mode, expected) in [(GamepadProfileOutputMode.keyboard, "Esc"), (.controller, "A"), (.custom, "Esc + A")] {
            profile.outputMode = mode
            let presentations = KeypadBindingPresentationBuilder.presentations(for: profile, elementOutputs: [:])
            XCTAssertEqual(presentations.bindingPresentation(profileID: profile.id, orientation: .landscape, input: input)?.compactText, expected)
            XCTAssertEqual(profile.customization.elements.first?.output, element.output)
        }
    }

    func testOfflinePresentationPersistenceReplacesSnapshot() throws {
        let suiteName = "KeypadBindingPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profileID = UUID()
        let first = [GamepadProfileBindingPresentations(profileID: profileID, entries: [])]
        KeypadBindingPresentationPersistence.save(first, to: defaults)
        XCTAssertEqual(KeypadBindingPresentationPersistence.load(from: defaults), first)

        let replacement = [
            GamepadProfileBindingPresentations(
                profileID: profileID,
                orientation: .portrait,
                entries: [
                    KeypadBindingPresentation(
                        input: KeypadElementInputID(elementID: UUID()),
                        compactText: "Esc",
                        accessibilityText: "Escape"
                    )
                ]
            )
        ]
        KeypadBindingPresentationPersistence.save(replacement, to: defaults)
        XCTAssertEqual(KeypadBindingPresentationPersistence.load(from: defaults), replacement)
    }
}
