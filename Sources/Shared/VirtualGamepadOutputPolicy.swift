import Foundation

public enum VirtualGamepadOutputPolicy {
    public static func needsDevice(
        outputMode: GamepadProfileOutputMode,
        hasMappedGamepadButtons: Bool,
        customization: GamepadCustomization
    ) -> Bool {
        // Gate every output path before normalizing or examining controls.
        guard outputMode != .keyboard else { return false }
        if outputMode == .controller || hasMappedGamepadButtons { return true }
        let customization = customization.normalized
        if customization.elements.contains(where: { element in
            element.output?.gamepadButtons.isEmpty == false ||
            element.partOutputs.values.contains { !$0.gamepadButtons.isEmpty } ||
            element.kind == .trigger ||
            (element.kind == .joystick &&
             (element.joystickOutputSettings ?? .defaultValue).normalized.analogTarget.stick != nil)
        }) { return true }
        return customization.customButtons.contains { button in
            button.controlKind == .trigger ||
            (button.controlKind == .joystick &&
             (button.joystickOutputSettings ?? .defaultValue).normalized.analogTarget.stick != nil)
        }
    }
}
