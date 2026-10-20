import Foundation
import SwiftUI

/// Typed three-way merge for profile-owned appearance states. Only edits relative
/// to the saved light/Base reference override another state's appearance. No JSON
/// encoding, decoding, package lookup, geometry or output mutation happens here.
enum GamepadAppearanceEditMerge {
    static func value<T: Equatable>(_ edited: T, _ baseline: T, _ target: T) -> T {
        edited == baseline ? target : edited
    }

    static func control(_ edited: GamepadButtonCustomization, _ baseline: GamepadButtonCustomization,
                        _ target: GamepadButtonCustomization, scheme: ThumbleSkinColorScheme?,
                        fallbackAccent: GamepadAccentStyle) -> GamepadButtonCustomization {
        ControlWorkspace(edited, baseline, target, scheme: scheme, fallbackAccent: fallbackAccent).merge()
    }

    private final class ControlWorkspace {
        let edited: GamepadButtonCustomization
        let baseline: GamepadButtonCustomization
        var result: GamepadButtonCustomization
        let scheme: ThumbleSkinColorScheme?
        let fallbackAccent: GamepadAccentStyle
        init(_ edited: GamepadButtonCustomization, _ baseline: GamepadButtonCustomization, _ target: GamepadButtonCustomization,
             scheme: ThumbleSkinColorScheme?, fallbackAccent: GamepadAccentStyle) {
            self.edited = edited; self.baseline = baseline; result = target
            self.scheme = scheme; self.fallbackAccent = fallbackAccent
        }
        func merge() -> GamepadButtonCustomization {
            apply(\.shape)
            apply(\.accentStyle)
            apply(\.fillColor)
            apply(\.lightFillColor)
            apply(\.darkFillColor)
            apply(\.fillStyle)
            apply(\.lightFillStyle)
            apply(\.darkFillStyle)
            apply(\.joystickKnobColor)
            apply(\.lightJoystickKnobColor)
            apply(\.darkJoystickKnobColor)
            apply(\.joystickVisualStyle)
            apply(\.styleID)
            apply(\.icon)
            apply(\.hapticStyle)
            apply(\.hapticFeedback)
            apply(\.cornerRadius)
            apply(\.cornerRadii)
            apply(\.shadowStrength)
            apply(\.showsIntegratedLabel)
            // Selecting a different reusable style also replaces obsolete inline
            // visual overrides; inherited bank paint must not mask that choice.
            if edited.styleID != baseline.styleID {
                result.visualStyle = visual(edited.visualStyle, baseline.visualStyle, nil)
            } else {
                result.visualStyle = visual(edited.visualStyle, baseline.visualStyle, result.visualStyle)
            }
            promoteDirectFillEdit()
            promoteDirectIconEdit()
            return result
        }
        private func promoteDirectFillEdit() {
            guard let scheme else { return }
            let changed = edited.fillColor != baseline.fillColor || edited.fillStyle != baseline.fillStyle
                || (scheme == .light && (edited.lightFillColor != baseline.lightFillColor || edited.lightFillStyle != baseline.lightFillStyle))
                || (scheme == .dark && (edited.darkFillColor != baseline.darkFillColor || edited.darkFillStyle != baseline.darkFillStyle))
            guard changed else { return }
            let colorScheme: ColorScheme = scheme == .dark ? .dark : .light
            let fill = edited.buttonFillStyle(accentStyle: edited.accentStyle ?? fallbackAccent, isPressed: false, scheme: colorScheme)
            let original = baseline.buttonFillStyle(accentStyle: baseline.accentStyle ?? fallbackAccent, isPressed: false, scheme: colorScheme)
            // Moving a global fill into light/dark storage is bookkeeping, not
            // an edit to the other scheme's material.
            guard fill != original else { return }
            var style = result.visualStyle ?? .init()
            style.normal.fillStyle = fill
            result.visualStyle = style
        }
        private func promoteDirectIconEdit() {
            guard edited.icon != baseline.icon, let icon = edited.icon else { return }
            var style = result.visualStyle ?? .init()
            promoteNormalIcon(icon, in: &style)
            promotePressedIcon(icon, in: &style)
            promoteActiveIcon(icon, in: &style)
            promoteDisabledIcon(icon, in: &style)
            result.visualStyle = style
        }
        private func promoteNormalIcon(_ icon: GamepadControlIcon, in style: inout GamepadControlVisualStyle) {
            style.normal = replacingIcon(icon, in: style.normal)
        }
        private func promotePressedIcon(_ icon: GamepadControlIcon, in style: inout GamepadControlVisualStyle) {
            style.pressed = replacingIcon(icon, in: style.pressed ?? .empty)
        }
        private func promoteActiveIcon(_ icon: GamepadControlIcon, in style: inout GamepadControlVisualStyle) {
            style.active = replacingIcon(icon, in: style.active ?? .empty)
        }
        private func promoteDisabledIcon(_ icon: GamepadControlIcon, in style: inout GamepadControlVisualStyle) {
            style.disabled = replacingIcon(icon, in: style.disabled ?? .empty)
        }
        private func replacingIcon(_ icon: GamepadControlIcon, in state: GamepadControlStateStyle) -> GamepadControlStateStyle {
            var state = state
            state.content = content(.init(icon: icon), .init(), state.content)
            return state
        }
        private func apply<T: Equatable>(_ path: WritableKeyPath<GamepadButtonCustomization, T>) {
            result[keyPath: path] = value(edited[keyPath: path], baseline[keyPath: path], result[keyPath: path])
        }
    }

    static func visual(_ edited: GamepadControlVisualStyle?, _ baseline: GamepadControlVisualStyle?,
                       _ target: GamepadControlVisualStyle?) -> GamepadControlVisualStyle? {
        if edited == baseline { return target }
        guard let edited else { return nil }
        return VisualWorkspace(edited, baseline ?? .init(), target ?? .init()).merge()
    }

    private final class VisualWorkspace {
        let edited: GamepadControlVisualStyle
        let baseline: GamepadControlVisualStyle
        var result: GamepadControlVisualStyle
        init(_ edited: GamepadControlVisualStyle, _ baseline: GamepadControlVisualStyle, _ target: GamepadControlVisualStyle) {
            self.edited = edited; self.baseline = baseline; result = target
        }
        func merge() -> GamepadControlVisualStyle {
            mergeNormal()
            mergePressed()
            mergeActive()
            mergeDisabled()
            result.icon = value(edited.icon, baseline.icon, result.icon)
            result.hapticStyle = value(edited.hapticStyle, baseline.hapticStyle, result.hapticStyle)
            result.hapticFeedback = value(edited.hapticFeedback, baseline.hapticFeedback, result.hapticFeedback)
            return result
        }
        private func mergeNormal() { result.normal = StateWorkspace(edited.normal, baseline.normal, result.normal).merge() }
        private func mergePressed() { result.pressed = state(edited.pressed, baseline.pressed, result.pressed) }
        private func mergeActive() { result.active = state(edited.active, baseline.active, result.active) }
        private func mergeDisabled() { result.disabled = state(edited.disabled, baseline.disabled, result.disabled) }
    }

    private static func state(_ edited: GamepadControlStateStyle?, _ baseline: GamepadControlStateStyle?,
                              _ target: GamepadControlStateStyle?) -> GamepadControlStateStyle? {
        if edited == baseline { return target }
        guard let edited else { return nil }
        return StateWorkspace(edited, baseline ?? .empty, target ?? .empty).merge()
    }

    private final class StateWorkspace {
        let edited: GamepadControlStateStyle
        let baseline: GamepadControlStateStyle
        var result: GamepadControlStateStyle
        init(_ edited: GamepadControlStateStyle, _ baseline: GamepadControlStateStyle, _ target: GamepadControlStateStyle) {
            self.edited = edited; self.baseline = baseline; result = target
        }
        func merge() -> GamepadControlStateStyle {
            apply(\.fillStyle)
            apply(\.foregroundColor)
            apply(\.strokeColor)
            apply(\.strokeWidth)
            apply(\.shadowColor)
            apply(\.shadowRadius)
            apply(\.shadowX)
            apply(\.shadowY)
            apply(\.shadows)
            apply(\.glowColor)
            apply(\.glowRadius)
            apply(\.innerShadowColor)
            apply(\.innerShadowRadius)
            apply(\.innerShadowX)
            apply(\.innerShadowY)
            apply(\.highlightColor)
            apply(\.highlightRadius)
            apply(\.highlightX)
            apply(\.highlightY)
            apply(\.highlightOpacity)
            apply(\.bevelHighlightColor)
            apply(\.bevelShadowColor)
            apply(\.bevelWidth)
            apply(\.indexColor)
            apply(\.indexWidth)
            apply(\.opacity)
            apply(\.scale)
            apply(\.blurRadius)
            result.content = content(edited.content, baseline.content, result.content)
            return result
        }
        private func apply<T: Equatable>(_ path: WritableKeyPath<GamepadControlStateStyle, T>) {
            result[keyPath: path] = value(edited[keyPath: path], baseline[keyPath: path], result[keyPath: path])
        }
    }

    private static func content(_ edited: GamepadControlContentStyle?, _ baseline: GamepadControlContentStyle?,
                                _ target: GamepadControlContentStyle?) -> GamepadControlContentStyle? {
        if edited == baseline { return target }
        guard let edited else { return nil }
        return GamepadControlContentStyle(
            icon: value(edited.icon, baseline?.icon, target?.icon),
            legend: value(edited.legend, baseline?.legend, target?.legend),
            fontSize: value(edited.fontSize, baseline?.fontSize, target?.fontSize),
            fontWeight: value(edited.fontWeight, baseline?.fontWeight, target?.fontWeight),
            fontDesign: value(edited.fontDesign, baseline?.fontDesign, target?.fontDesign),
            tracking: value(edited.tracking, baseline?.tracking, target?.tracking),
            lineLimit: value(edited.lineLimit, baseline?.lineLimit, target?.lineLimit),
            alignment: value(edited.alignment, baseline?.alignment, target?.alignment),
            labelPadding: value(edited.labelPadding, baseline?.labelPadding, target?.labelPadding),
            labelPlacement: value(edited.labelPlacement, baseline?.labelPlacement, target?.labelPlacement),
            trackpadFrameVisible: value(edited.trackpadFrameVisible, baseline?.trackpadFrameVisible, target?.trackpadFrameVisible),
            trackpadCursorVisible: value(edited.trackpadCursorVisible, baseline?.trackpadCursorVisible, target?.trackpadCursorVisible),
            trackpadIndicatorsVisible: value(edited.trackpadIndicatorsVisible, baseline?.trackpadIndicatorsVisible, target?.trackpadIndicatorsVisible),
            joystickRingVisible: value(edited.joystickRingVisible, baseline?.joystickRingVisible, target?.joystickRingVisible),
            joystickKnobRatio: value(edited.joystickKnobRatio, baseline?.joystickKnobRatio, target?.joystickKnobRatio),
            joystickKnobStrokeWidth: value(edited.joystickKnobStrokeWidth, baseline?.joystickKnobStrokeWidth, target?.joystickKnobStrokeWidth),
            pointing: pointing(edited.pointing, baseline?.pointing, target?.pointing)
        )
    }

    private static func pointing(_ edited: GamepadPointingPaint?, _ baseline: GamepadPointingPaint?,
                                 _ target: GamepadPointingPaint?) -> GamepadPointingPaint? {
        if edited == baseline { return target }
        guard let edited else { return nil }
        return GamepadPointingPaint(
            trackpadFrameColor: value(edited.trackpadFrameColor, baseline?.trackpadFrameColor, target?.trackpadFrameColor),
            trackpadCursorColor: value(edited.trackpadCursorColor, baseline?.trackpadCursorColor, target?.trackpadCursorColor),
            trackpadIndicatorColor: value(edited.trackpadIndicatorColor, baseline?.trackpadIndicatorColor, target?.trackpadIndicatorColor),
            trackpadSecondaryIndicatorColor: value(edited.trackpadSecondaryIndicatorColor, baseline?.trackpadSecondaryIndicatorColor, target?.trackpadSecondaryIndicatorColor),
            joystickRingColor: value(edited.joystickRingColor, baseline?.joystickRingColor, target?.joystickRingColor),
            joystickKnobFillColor: value(edited.joystickKnobFillColor, baseline?.joystickKnobFillColor, target?.joystickKnobFillColor),
            joystickKnobStrokeColor: value(edited.joystickKnobStrokeColor, baseline?.joystickKnobStrokeColor, target?.joystickKnobStrokeColor),
            trackpadFrameStrokeWidth: value(edited.trackpadFrameStrokeWidth, baseline?.trackpadFrameStrokeWidth, target?.trackpadFrameStrokeWidth),
            joystickRingStrokeWidth: value(edited.joystickRingStrokeWidth, baseline?.joystickRingStrokeWidth, target?.joystickRingStrokeWidth))
    }

    /// Keep state-specific entries/order unless the user changed the corresponding
    /// ID. Adds/deletes are matched by identity, never by an array index.
    static func collection<T: Equatable, ID: Hashable>(
        _ edited: [T], _ baseline: [T], _ target: [T], id: KeyPath<T, ID>,
        merge: (T, T, T) -> T
    ) -> [T] {
        if edited == baseline { return target }
        if target == baseline { return edited }
        if edited.isEmpty { return [] }
        let editedByID = Dictionary(uniqueKeysWithValues: edited.map { ($0[keyPath: id], $0) })
        let baselineByID = Dictionary(uniqueKeysWithValues: baseline.map { ($0[keyPath: id], $0) })
        var result: [T] = []
        var seen = Set<ID>()
        for item in target {
            let key = item[keyPath: id]
            guard seen.insert(key).inserted else { continue }
            if let original = baselineByID[key] {
                guard let current = editedByID[key] else { continue }
                result.append(merge(current, original, item))
            } else {
                result.append(editedByID[key] ?? item)
            }
        }
        for item in edited where seen.insert(item[keyPath: id]).inserted {
            // An entry absent from this bank is added only when it is new or
            // edited. Do not resurrect unchanged light-only artwork in dark mode.
            if baselineByID[item[keyPath: id]] != item { result.append(item) }
        }
        // An explicit reorder applies to common IDs, leaving variant-only IDs in
        // their own slots. Unchanged collection order keeps target ordering.
        let common = Set(baselineByID.keys).intersection(editedByID.keys)
        let oldOrder = baseline.map { $0[keyPath: id] }.filter(common.contains)
        let newOrder = edited.map { $0[keyPath: id] }.filter(common.contains)
        if oldOrder != newOrder || !Set(editedByID.keys).isSubset(of: baselineByID.keys) {
            let byID = Dictionary(uniqueKeysWithValues: result.map { ($0[keyPath: id], $0) })
            var reordered = edited.compactMap { byID[$0[keyPath: id]] }.makeIterator()
            result = result.map { editedByID[$0[keyPath: id]] != nil ? (reordered.next() ?? $0) : $0 }
        }
        return result
    }

    static func token(_ edited: GamepadStyleToken, _ baseline: GamepadStyleToken, _ target: GamepadStyleToken) -> GamepadStyleToken {
        var result = target
        result.name = value(edited.name, baseline.name, target.name)
        result.appliesTo = value(edited.appliesTo, baseline.appliesTo, target.appliesTo)
        result.visualStyle = visual(edited.visualStyle, baseline.visualStyle, target.visualStyle) ?? .init()
        return result
    }
}
