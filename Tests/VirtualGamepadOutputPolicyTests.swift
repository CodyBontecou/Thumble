import XCTest

final class VirtualGamepadOutputPolicyTests: XCTestCase {
    func testKeyboardModeGatesDirectOutputsTriggersAndAnalogControls() {
        var customization = GamepadCustomization.defaultValue
        customization.elements.append(KeypadElement(output: .init(gamepadButtons: [.south])))
        customization.customButtons.append(GamepadCustomButton(controlKind: .trigger))
        customization.customButtons.append(GamepadCustomButton(
            controlKind: .joystick,
            joystickOutputSettings: .init(analogTarget: .leftStick)
        ))
        XCTAssertFalse(VirtualGamepadOutputPolicy.needsDevice(
            outputMode: .keyboard, hasMappedGamepadButtons: true, customization: customization
        ))
        XCTAssertTrue(VirtualGamepadOutputPolicy.needsDevice(
            outputMode: .custom, hasMappedGamepadButtons: false, customization: customization
        ))
    }

    func testKeyboardModeFiltersDirectMixedBindingsBeforeTheyAreCaptured() {
        let direct = MacControlOutputBinding(shared: .init(
            keyboard: .init(keyCode: 49), gamepadButtons: [.south, .leftTriggerButton]
        ))
        let keyboardOnly = direct.filtered(for: .keyboard)
        XCTAssertEqual(keyboardOnly.keyboard, direct.keyboard)
        XCTAssertTrue(keyboardOnly.gamepadButtons.isEmpty)
        XCTAssertTrue(MacControlOutputBinding.gamepadButton(.south).filtered(for: .keyboard).isEmpty)
        XCTAssertEqual(direct.filtered(for: .custom), direct)
    }

    func testControllerModeExplicitlyRequestsDeviceEvenWithoutBindings() {
        XCTAssertTrue(VirtualGamepadOutputPolicy.needsDevice(
            outputMode: .controller, hasMappedGamepadButtons: false, customization: .defaultValue
        ))
    }
}
