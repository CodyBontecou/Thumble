import CoreGraphics

/// Pure presentation decisions shared by the runtime and its regression tests.
/// Keeping these branches out of SwiftUI builders prevents layout options from
/// multiplying the controller's concrete view type.
enum GamepadControllerLayoutRoute: Equatable, Sendable {
    case standard(GamepadEditorDeviceOrientation)
    case freeform(GamepadEditorDeviceOrientation)
}

enum GamepadStandardControlGroup: String, Hashable, Sendable {
    case dPad
    case utilityButtons
    case actionButtons
}

enum GamepadStandardLayoutSlot: Hashable, Identifiable, Sendable {
    case control(GamepadStandardControlGroup)
    case flexibleSpace(Int)

    var id: String {
        switch self {
        case .control(let group):
            "control.\(group.rawValue)"
        case .flexibleSpace(let position):
            "space.\(position)"
        }
    }
}

enum GamepadResolvedControlRoute: Equatable, Sendable {
    case decoration
    case joystick
    case trigger
    case trackpad
    case button
}

enum GamepadControllerPresentationRouting {
    /// Native bar leaf inventory follows the shared label branches, independent of
    /// label text, input bindings and selected colors. Spacers carry no paint.
    static func barLeafSurfaceIDs(items: [GamepadControlBarItem], isLandscape: Bool,
                                  customization: GamepadCustomization) -> [String] {
        items.flatMap { item -> [String] in
            let leaves: [String]
            switch item {
            case .spacer: leaves = []
            case .connectionStatus: leaves = ["legend", "icon"]
            case .profileMenu, .editLayout: leaves = isLandscape ? ["legend", "icon"] : ["icon"]
            case .launchTarget, .settings, .home: leaves = ["icon"]
            case .connectionAction:
                leaves = !isLandscape ? ["icon"] : customization.controlBarItemCustomization(for: item).icon != nil
                    ? ["legend", "icon"] : ["legend"]
            }
            return leaves.map { "native-control-bar/" + item.rawValue + "/" + $0 }
        }
    }

    static func orientation(for size: CGSize) -> GamepadEditorDeviceOrientation {
        size.width >= size.height ? .landscape : .portrait
    }

    static func layoutRoute(
        orientation: GamepadEditorDeviceOrientation,
        isEditingLayout: Bool,
        usesFreeformLayout: Bool
    ) -> GamepadControllerLayoutRoute {
        if isEditingLayout || usesFreeformLayout {
            return .freeform(orientation)
        }
        return .standard(orientation)
    }

    static func standardSlots(
        orientation: GamepadEditorDeviceOrientation,
        layoutMode: GamepadLayoutMode
    ) -> [GamepadStandardLayoutSlot] {
        let controls: [GamepadStandardControlGroup] = if layoutMode == .standard {
            [.dPad, .utilityButtons, .actionButtons]
        } else {
            [.actionButtons, .utilityButtons, .dPad]
        }

        switch orientation {
        case .landscape:
            return [
                .control(controls[0]),
                .flexibleSpace(0),
                .control(controls[1]),
                .flexibleSpace(1),
                .control(controls[2])
            ]
        case .portrait:
            return [
                .flexibleSpace(0),
                .control(controls[0]),
                .control(controls[1]),
                .control(controls[2]),
                .flexibleSpace(1)
            ]
        }
    }

    static func visibleControlBarItems(
        _ items: [GamepadControlBarItem],
        hiddenItems: Set<GamepadControlBarItem>,
        hasProfiles: Bool,
        hasLaunchTarget: Bool
    ) -> [GamepadControlBarItem] {
        var seen = Set<GamepadControlBarItem>()
        return items.filter { item in
            guard seen.insert(item).inserted,
                  !hiddenItems.contains(item)
            else { return false }

            switch item {
            case .profileMenu:
                return hasProfiles
            case .launchTarget:
                return hasLaunchTarget
            default:
                return true
            }
        }
    }

    static func resolvedControlRoute(
        kind: GamepadCustomControlKind,
        hasJoystickMapping: Bool,
        hasTriggerSettings: Bool
    ) -> GamepadResolvedControlRoute {
        switch kind {
        case .text, .decoration:
            return .decoration
        case .joystick where hasJoystickMapping:
            return .joystick
        case .trigger where hasTriggerSettings:
            return .trigger
        case .trackpad:
            return .trackpad
        case .button, .joystick, .trigger:
            return .button
        }
    }
}
