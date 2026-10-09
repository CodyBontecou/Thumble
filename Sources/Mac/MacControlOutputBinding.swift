import CoreGraphics
import Foundation

struct MacControlOutputBinding: Codable, Equatable, Hashable, Sendable {
    var keyboard: MacKeyBinding?
    var gamepadButtons: Set<VirtualGamepadButton>

    init(keyboard: MacKeyBinding? = nil, gamepadButtons: Set<VirtualGamepadButton> = []) {
        self.keyboard = keyboard
        self.gamepadButtons = gamepadButtons
    }

    var isEmpty: Bool {
        keyboard == nil && gamepadButtons.isEmpty
    }

    var displayName: String {
        KeypadBindingFormatter.format(sharedBinding)?.compactText ?? "Unmapped"
    }

    var accessibleDisplayName: String {
        KeypadBindingFormatter.format(sharedBinding)?.accessibilityText ?? "Unmapped"
    }

    /// Filter before press-time capture, including direct element/part outputs.
    /// Release still uses the captured binding even if the mode later changes.
    func filtered(for mode: GamepadProfileOutputMode) -> MacControlOutputBinding {
        switch mode {
        case .keyboard: return MacControlOutputBinding(keyboard: keyboard)
        case .controller: return MacControlOutputBinding(gamepadButtons: gamepadButtons)
        case .custom: return self
        }
    }

    func withAdditionalModifiers(_ modifiers: MacKeyModifiers) -> MacControlOutputBinding {
        guard let keyboard else { return self }
        var copy = self
        copy.keyboard = keyboard.withAdditionalModifiers(modifiers)
        return copy
    }

    mutating func setKeyboard(_ binding: MacKeyBinding?) {
        keyboard = binding
    }

    mutating func setGamepadButton(_ button: VirtualGamepadButton?) {
        gamepadButtons = button.map { Set([$0]) } ?? []
    }

    static func keyboard(_ binding: MacKeyBinding) -> MacControlOutputBinding {
        MacControlOutputBinding(keyboard: binding)
    }

    init(shared binding: KeypadElementOutputBinding) {
        self.keyboard = binding.keyboard.map(MacKeyBinding.init(shared:))
        self.gamepadButtons = binding.gamepadButtons
    }

    var sharedBinding: KeypadElementOutputBinding {
        KeypadElementOutputBinding(
            keyboard: keyboard?.sharedBinding,
            gamepadButtons: gamepadButtons
        )
    }

    static func gamepadButton(_ button: VirtualGamepadButton) -> MacControlOutputBinding {
        MacControlOutputBinding(gamepadButtons: [button])
    }
}

extension MacKeyStroke {
    init(shared stroke: KeypadKeyboardStrokeBinding) {
        self.init(keyCode: CGKeyCode(stroke.keyCode), modifiers: MacKeyModifiers(rawValue: stroke.modifiersRawValue))
    }

    var sharedBinding: KeypadKeyboardStrokeBinding {
        KeypadKeyboardStrokeBinding(keyCode: UInt16(keyCode), modifiersRawValue: modifiers.rawValue)
    }
}

extension MacKeyBinding {
    init(shared binding: KeypadKeyboardBinding) {
        self.init(strokes: binding.strokes.map(MacKeyStroke.init(shared:)))
    }

    var sharedBinding: KeypadKeyboardBinding {
        let sharedStrokes = strokes.map(\.sharedBinding)
        if sharedStrokes.count > 1 {
            return KeypadKeyboardBinding(
                keyCode: sharedStrokes[0].keyCode,
                modifiersRawValue: sharedStrokes[0].modifiersRawValue,
                sequence: sharedStrokes
            )
        }
        return KeypadKeyboardBinding(keyCode: UInt16(keyCode), modifiersRawValue: modifiers.rawValue)
    }
}

extension Dictionary where Key == KeypadElementID, Value == MacControlOutputBinding {
    var keyboardBindings: [KeypadElementID: MacKeyBinding] {
        reduce(into: [:]) { partial, entry in
            if let keyboard = entry.value.keyboard {
                partial[entry.key] = keyboard
            }
        }
    }
}

extension Set where Element == VirtualGamepadButton {
    var sortedForDisplay: [VirtualGamepadButton] {
        sorted { lhs, rhs in
            let lhsIndex = VirtualGamepadButton.allCases.firstIndex(of: lhs) ?? VirtualGamepadButton.allCases.endIndex
            let rhsIndex = VirtualGamepadButton.allCases.firstIndex(of: rhs) ?? VirtualGamepadButton.allCases.endIndex
            return lhsIndex < rhsIndex
        }
    }
}

extension GamepadConfigurationProfile {
    /// Defaults are owned by the actual controls, not inherited from a shared
    /// action table or from the currently selected profile.
    var recommendedMacOutputBindings: [KeypadElementID: MacControlOutputBinding] {
        macElementBindings(useDefaults: true)
    }

    var configuredMacOutputBindings: [KeypadElementID: MacControlOutputBinding] {
        macElementBindings(useDefaults: false)
    }

    var initialMacOutputBindings: [KeypadElementID: MacControlOutputBinding] {
        recommendedMacOutputBindings.merging(configuredMacOutputBindings) { _, configured in configured }
    }

    private func macElementBindings(useDefaults: Bool) -> [KeypadElementID: MacControlOutputBinding] {
        var bindings: [KeypadElementID: MacControlOutputBinding] = [:]
        for customization in [self.customization, landscapeCustomization, portraitCustomization].compactMap({ $0 }) {
            for element in customization.normalized.elements {
                let output = useDefaults ? element.defaultOutput : element.output
                if bindings[element.inputID] == nil, let output {
                    bindings[element.inputID] = MacControlOutputBinding(shared: output)
                }
            }
        }
        return bindings
    }
}

enum DefaultMacControlOutputMap {
    static let defaultBindings: [KeypadElementID: MacControlOutputBinding] = Dictionary(
        uniqueKeysWithValues: DefaultKeypadElements.ids.compactMap { id in
            DefaultKeypadElements.initialBinding(for: id).map { (id, MacControlOutputBinding(shared: $0)) }
        }
    )

    static func defaultBinding(for id: KeypadElementID) -> MacControlOutputBinding? {
        defaultBindings[id]
    }
}
