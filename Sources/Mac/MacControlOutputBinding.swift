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
        guard mode == .keyboard else { return self }
        return MacControlOutputBinding(keyboard: keyboard)
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

extension Dictionary where Key == GameButton, Value == MacControlOutputBinding {
    var keyboardBindings: [GameButton: MacKeyBinding] {
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

extension GamepadControllerTemplate {
    /// Templates install a complete, predictable keyboard map atomically with
    /// the profile rather than inheriting whichever profile happened to be active.
    var recommendedMacOutputBindings: [GameButton: MacControlOutputBinding]? {
        switch self {
        case .productivityStarter, .productivityOneHandedLeft, .productivityOneHandedRight:
            DefaultMacControlOutputMap.defaultBindings
        case .nes, .snes, .nintendo64, .gameCube, .gameBoy, .gameBoyAdvance,
             .genesisSixButton, .saturn, .dreamcast, .arcadeStick, .psp,
             .playStation, .xbox, .softWhite:
            DefaultMacControlOutputMap.gamingKeyboardBindings
        }
    }
}

extension GamepadConfigurationProfile {
    /// Restores defaults appropriate to the template that created this setup.
    /// Untagged/custom profiles retain the general-purpose keypad defaults.
    var recommendedMacOutputBindings: [GameButton: MacControlOutputBinding] {
        guard let templateID = customization.designMetadata?.sourceTemplateID,
              let template = GamepadControllerTemplate.allCases.first(where: {
                  $0.rawValue.caseInsensitiveCompare(templateID) == .orderedSame
              }),
              let bindings = template.recommendedMacOutputBindings
        else {
            return DefaultMacControlOutputMap.defaultBindings
        }
        return bindings
    }
}

enum DefaultMacControlOutputMap {
    static let defaultBindings: [GameButton: MacControlOutputBinding] = Dictionary(
        uniqueKeysWithValues: DefaultKeypadKeyMap.defaultBindings.map { button, binding in
            (button, MacControlOutputBinding.keyboard(binding))
        }
    )

    static func defaultBinding(for button: GameButton) -> MacControlOutputBinding? {
        defaultBindings[button]
    }

    /// A usable keyboard fallback for controller-shaped templates. Games vary,
    /// but this covers every legacy slot so a new setup works before tailoring.
    static let gamingKeyboardBindings: [GameButton: MacControlOutputBinding] = [
        .up: .keyboard(MacKeyBinding(keyCode: MacVirtualKey.w)),
        .down: .keyboard(MacKeyBinding(keyCode: MacVirtualKey.s)),
        .left: .keyboard(MacKeyBinding(keyCode: MacVirtualKey.a)),
        .right: .keyboard(MacKeyBinding(keyCode: MacVirtualKey.d)),
        .jump: .keyboard(MacKeyBinding(keyCode: MacVirtualKey.space)),
        .attack: .keyboard(MacKeyBinding(keyCode: MacVirtualKey.j)),
        .dash: .keyboard(.shiftKey),
        .focus: .keyboard(MacKeyBinding(keyCode: MacVirtualKey.e)),
        .map: .keyboard(MacKeyBinding(keyCode: MacVirtualKey.tab)),
        .pause: .keyboard(MacKeyBinding(keyCode: MacVirtualKey.escape)),
        .custom1: .keyboard(MacKeyBinding(keyCode: MacVirtualKey.upArrow)),
        .custom2: .keyboard(MacKeyBinding(keyCode: MacVirtualKey.downArrow)),
        .custom3: .keyboard(MacKeyBinding(keyCode: MacVirtualKey.leftArrow)),
        .custom4: .keyboard(MacKeyBinding(keyCode: MacVirtualKey.rightArrow)),
        .custom5: .keyboard(MacKeyBinding(keyCode: MacVirtualKey.q)),
        .custom6: .keyboard(MacKeyBinding(keyCode: MacVirtualKey.r)),
        .custom7: .keyboard(MacKeyBinding(keyCode: MacVirtualKey.z)),
        .custom8: .keyboard(MacKeyBinding(keyCode: MacVirtualKey.x))
    ]

    static let xboxStyleBindings: [GameButton: MacControlOutputBinding] = [
        .up: .gamepadButton(.dpadUp),
        .down: .gamepadButton(.dpadDown),
        .left: .gamepadButton(.dpadLeft),
        .right: .gamepadButton(.dpadRight),
        .jump: .gamepadButton(.south),
        .attack: .gamepadButton(.east),
        .dash: .gamepadButton(.west),
        .focus: .gamepadButton(.north),
        .map: .gamepadButton(.select),
        .pause: .gamepadButton(.start),
        .custom1: .gamepadButton(.leftShoulder),
        .custom2: .gamepadButton(.rightShoulder),
        .custom3: .gamepadButton(.leftStickPress),
        .custom4: .gamepadButton(.rightStickPress),
        .custom5: .gamepadButton(.leftTriggerButton),
        .custom6: .gamepadButton(.rightTriggerButton),
        .custom7: .gamepadButton(.home)
    ]
}
