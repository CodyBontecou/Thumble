import Foundation
import SwiftUI

public enum GamepadControlPresentationState: String, Codable, CaseIterable, Identifiable, Sendable {
    case normal
    case pressed
    case active
    case disabled

    public var id: String { rawValue }

    var usesPressedFallback: Bool {
        switch self {
        case .pressed, .active: true
        case .normal, .disabled: false
        }
    }
}

public enum GamepadControlIconSource: String, Codable, Sendable {
    case sfSymbol = "sf_symbol"
    case text
    case asset
}

public enum GamepadControlIconPlacement: String, Codable, CaseIterable, Identifiable, Sendable {
    case leading
    case trailing
    case top
    case bottom
    case center
    case background

    public var id: String { rawValue }
}

public enum GamepadControlIconRenderingMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case template
    case multicolor
    case original

    public var id: String { rawValue }
}

public struct GamepadControlIcon: Codable, Equatable, Sendable {
    public var source: GamepadControlIconSource
    public var value: String
    public var placement: GamepadControlIconPlacement
    public var scale: CGFloat
    public var tintColor: GamepadRGBAColor?
    public var renderingMode: GamepadControlIconRenderingMode

    public init(
        source: GamepadControlIconSource,
        value: String,
        placement: GamepadControlIconPlacement = .center,
        scale: CGFloat = 1,
        tintColor: GamepadRGBAColor? = nil,
        renderingMode: GamepadControlIconRenderingMode = .template
    ) {
        self.source = source
        self.value = value
        self.placement = placement
        self.scale = scale
        self.tintColor = tintColor
        self.renderingMode = renderingMode
    }

    public static func sfSymbol(_ name: String, placement: GamepadControlIconPlacement = .center) -> GamepadControlIcon {
        GamepadControlIcon(source: .sfSymbol, value: name, placement: placement)
    }

    public static func text(_ value: String, placement: GamepadControlIconPlacement = .center) -> GamepadControlIcon {
        GamepadControlIcon(source: .text, value: value, placement: placement)
    }

    var normalized: GamepadControlIcon? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return GamepadControlIcon(
            source: source,
            value: String(trimmed.prefix(80)),
            placement: placement,
            scale: Self.clamp(scale, lower: 0.2, upper: 3),
            tintColor: tintColor?.normalized,
            renderingMode: renderingMode
        )
    }

    private static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        guard value.isFinite else { return lower }
        return min(max(value, lower), upper)
    }
}

public enum GamepadHapticStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case light
    case medium
    case heavy
    case soft
    case rigid

    public var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: "None"
        case .light: "Light"
        case .medium: "Medium"
        case .heavy: "Heavy"
        case .soft: "Soft"
        case .rigid: "Rigid"
        }
    }

    var defaultIntensity: CGFloat {
        switch self {
        case .none: 0
        case .light: 0.45
        case .medium: 0.62
        case .heavy: 0.82
        case .soft: 0.38
        case .rigid: 0.70
        }
    }

    var defaultSharpness: CGFloat {
        switch self {
        case .none: 0
        case .light: 0.48
        case .medium: 0.56
        case .heavy: 0.66
        case .soft: 0.24
        case .rigid: 0.92
        }
    }
}

public enum GamepadHapticPattern: String, Codable, CaseIterable, Identifiable, Sendable {
    case single
    case double
    case pulse
    case buzz

    public var id: String { rawValue }

    var displayName: String {
        switch self {
        case .single: "Single Tap"
        case .double: "Double Tap"
        case .pulse: "Pulse"
        case .buzz: "Buzz"
        }
    }
}

public struct GamepadHapticFeedback: Codable, Equatable, Sendable {
    public static let minimumIntensity: CGFloat = 0
    public static let maximumIntensity: CGFloat = 1
    public static let minimumSharpness: CGFloat = 0
    public static let maximumSharpness: CGFloat = 1
    public static let minimumDuration: CGFloat = 0.02
    public static let maximumDuration: CGFloat = 0.30
    public static let defaultDuration: CGFloat = 0.06
    public static let defaultValue = GamepadHapticFeedback()

    public var style: GamepadHapticStyle
    public var pattern: GamepadHapticPattern
    public var intensity: CGFloat
    public var sharpness: CGFloat
    public var duration: CGFloat

    public init(
        style: GamepadHapticStyle = .light,
        pattern: GamepadHapticPattern = .single,
        intensity: CGFloat? = nil,
        sharpness: CGFloat? = nil,
        duration: CGFloat = GamepadHapticFeedback.defaultDuration
    ) {
        self.style = style
        self.pattern = pattern
        self.intensity = intensity ?? style.defaultIntensity
        self.sharpness = sharpness ?? style.defaultSharpness
        self.duration = duration
    }

    var normalized: GamepadHapticFeedback {
        var copy = self
        copy.intensity = Self.clamp(copy.intensity, lower: Self.minimumIntensity, upper: Self.maximumIntensity)
        copy.sharpness = Self.clamp(copy.sharpness, lower: Self.minimumSharpness, upper: Self.maximumSharpness)
        copy.duration = Self.clamp(copy.duration, lower: Self.minimumDuration, upper: Self.maximumDuration)
        if copy.style == .none {
            copy.pattern = .single
            copy.intensity = 0
            copy.sharpness = 0
        }
        return copy
    }

    var isDefault: Bool {
        let normalized = normalized
        return normalized.style == Self.defaultValue.style
            && normalized.pattern == Self.defaultValue.pattern
            && abs(normalized.intensity - Self.defaultValue.intensity) < 0.001
            && abs(normalized.sharpness - Self.defaultValue.sharpness) < 0.001
            && abs(normalized.duration - Self.defaultValue.duration) < 0.001
    }

    private static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        guard value.isFinite else { return lower }
        return min(max(value, lower), upper)
    }
}

public struct GamepadControlShadowStyle: Codable, Equatable, Sendable {
    public var color: GamepadRGBAColor
    public var radius: CGFloat
    public var x: CGFloat
    public var y: CGFloat
    public var opacity: CGFloat

    public init(
        color: GamepadRGBAColor,
        radius: CGFloat,
        x: CGFloat = 0,
        y: CGFloat = 0,
        opacity: CGFloat = 1
    ) {
        self.color = color
        self.radius = radius
        self.x = x
        self.y = y
        self.opacity = opacity
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        color = try container.decode(GamepadRGBAColor.self, forKey: .color)
        radius = try container.decodeIfPresent(CGFloat.self, forKey: .radius) ?? 0
        x = try container.decodeIfPresent(CGFloat.self, forKey: .x) ?? 0
        y = try container.decodeIfPresent(CGFloat.self, forKey: .y) ?? 0
        opacity = try container.decodeIfPresent(CGFloat.self, forKey: .opacity) ?? 1
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(color.normalized, forKey: .color)
        try container.encode(radius, forKey: .radius)
        try container.encode(x, forKey: .x)
        try container.encode(y, forKey: .y)
        if abs(opacity - 1) > 0.001 { try container.encode(opacity, forKey: .opacity) }
    }

    public static func outer(
        _ hex: String,
        alpha: CGFloat = 1,
        radius: CGFloat,
        x: CGFloat = 0,
        y: CGFloat = 0,
        opacity: CGFloat = 1
    ) -> GamepadControlShadowStyle {
        GamepadControlShadowStyle(
            color: GamepadRGBAColor(hexString: hex, alpha: alpha) ?? .defaultValue,
            radius: radius,
            x: x,
            y: y,
            opacity: opacity
        )
    }

    var normalized: GamepadControlShadowStyle {
        let normalizedColor = color.normalized
        return GamepadControlShadowStyle(
            color: GamepadRGBAColor(
                red: normalizedColor.red,
                green: normalizedColor.green,
                blue: normalizedColor.blue,
                alpha: normalizedColor.alpha * Self.clamp(opacity, lower: 0, upper: 1)
            ).normalized,
            radius: Self.clamp(radius, lower: 0, upper: 96),
            x: Self.clamp(x, lower: -96, upper: 96),
            y: Self.clamp(y, lower: -96, upper: 96),
            opacity: 1
        )
    }

    public var swiftUIColor: Color { normalized.color.swiftUIColor }

    private static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        guard value.isFinite else { return lower }
        return min(max(value, lower), upper)
    }

    private enum CodingKeys: String, CodingKey {
        case color
        case radius
        case x
        case y
        case opacity
    }
}

/// Bounded per-state paint for native pointing interiors. Immutable storage keeps
/// appearance aggregates small and preserves value semantics across profile copies.
public final class GamepadPointingPaint: Codable, Equatable, Sendable {
    public let trackpadFrameColor: GamepadRGBAColor?
    public let trackpadCursorColor: GamepadRGBAColor?
    public let trackpadIndicatorColor: GamepadRGBAColor?
    public let trackpadSecondaryIndicatorColor: GamepadRGBAColor?
    public let joystickRingColor: GamepadRGBAColor?
    public let joystickKnobFillColor: GamepadRGBAColor?
    public let joystickKnobStrokeColor: GamepadRGBAColor?
    public let trackpadFrameStrokeWidth: CGFloat?
    public let joystickRingStrokeWidth: CGFloat?
    public init(
        trackpadFrameColor: GamepadRGBAColor? = nil,
        trackpadCursorColor: GamepadRGBAColor? = nil,
        trackpadIndicatorColor: GamepadRGBAColor? = nil,
        trackpadSecondaryIndicatorColor: GamepadRGBAColor? = nil,
        joystickRingColor: GamepadRGBAColor? = nil,
        joystickKnobFillColor: GamepadRGBAColor? = nil,
        joystickKnobStrokeColor: GamepadRGBAColor? = nil,
        trackpadFrameStrokeWidth: CGFloat? = nil,
        joystickRingStrokeWidth: CGFloat? = nil
    ) {
        self.trackpadFrameColor = trackpadFrameColor
        self.trackpadCursorColor = trackpadCursorColor
        self.trackpadIndicatorColor = trackpadIndicatorColor
        self.trackpadSecondaryIndicatorColor = trackpadSecondaryIndicatorColor
        self.joystickRingColor = joystickRingColor
        self.joystickKnobFillColor = joystickKnobFillColor
        self.joystickKnobStrokeColor = joystickKnobStrokeColor
        self.trackpadFrameStrokeWidth = trackpadFrameStrokeWidth
        self.joystickRingStrokeWidth = joystickRingStrokeWidth
    }
    public static func == (lhs: GamepadPointingPaint, rhs: GamepadPointingPaint) -> Bool {
        lhs.trackpadFrameColor == rhs.trackpadFrameColor
            && lhs.trackpadCursorColor == rhs.trackpadCursorColor
            && lhs.trackpadIndicatorColor == rhs.trackpadIndicatorColor
            && lhs.trackpadSecondaryIndicatorColor == rhs.trackpadSecondaryIndicatorColor
            && lhs.joystickRingColor == rhs.joystickRingColor
            && lhs.joystickKnobFillColor == rhs.joystickKnobFillColor
            && lhs.joystickKnobStrokeColor == rhs.joystickKnobStrokeColor
            && lhs.trackpadFrameStrokeWidth == rhs.trackpadFrameStrokeWidth
            && lhs.joystickRingStrokeWidth == rhs.joystickRingStrokeWidth
    }
    var isEmpty: Bool { trackpadFrameColor == nil && trackpadCursorColor == nil && trackpadIndicatorColor == nil && trackpadSecondaryIndicatorColor == nil && joystickRingColor == nil && joystickKnobFillColor == nil && joystickKnobStrokeColor == nil && trackpadFrameStrokeWidth == nil && joystickRingStrokeWidth == nil }
    var normalized: GamepadPointingPaint {
        GamepadPointingPaint(
            trackpadFrameColor: trackpadFrameColor?.normalized,
            trackpadCursorColor: trackpadCursorColor?.normalized,
            trackpadIndicatorColor: trackpadIndicatorColor?.normalized,
            trackpadSecondaryIndicatorColor: trackpadSecondaryIndicatorColor?.normalized,
            joystickRingColor: joystickRingColor?.normalized,
            joystickKnobFillColor: joystickKnobFillColor?.normalized,
            joystickKnobStrokeColor: joystickKnobStrokeColor?.normalized,
            trackpadFrameStrokeWidth: trackpadFrameStrokeWidth.map { $0.isFinite ? min(max($0, 0), 12) : 0 },
            joystickRingStrokeWidth: joystickRingStrokeWidth.map { $0.isFinite ? min(max($0, 0), 12) : 0 }
        )
    }
    func merged(over base: GamepadPointingPaint?) -> GamepadPointingPaint {
        GamepadPointingPaint(
            trackpadFrameColor: trackpadFrameColor ?? base?.trackpadFrameColor,
            trackpadCursorColor: trackpadCursorColor ?? base?.trackpadCursorColor,
            trackpadIndicatorColor: trackpadIndicatorColor ?? base?.trackpadIndicatorColor,
            trackpadSecondaryIndicatorColor: trackpadSecondaryIndicatorColor ?? base?.trackpadSecondaryIndicatorColor,
            joystickRingColor: joystickRingColor ?? base?.joystickRingColor,
            joystickKnobFillColor: joystickKnobFillColor ?? base?.joystickKnobFillColor,
            joystickKnobStrokeColor: joystickKnobStrokeColor ?? base?.joystickKnobStrokeColor,
            trackpadFrameStrokeWidth: trackpadFrameStrokeWidth ?? base?.trackpadFrameStrokeWidth,
            joystickRingStrokeWidth: joystickRingStrokeWidth ?? base?.joystickRingStrokeWidth
        ).normalized
    }
}

/// Bounded native content presentation. Immutable reference storage keeps typography and
/// pointing-surface chrome out of the inline stack footprint of every control state.
public final class GamepadControlContentStyle: Codable, Equatable, Sendable {
    public enum Weight: String, Codable, Sendable { case regular, medium, semibold, bold }
    public enum Design: String, Codable, Sendable { case system, rounded, serif, monospaced }
    public enum Alignment: String, Codable, Sendable { case leading, center, trailing }
    public enum Placement: String, Codable, Sendable { case center, top, bottom, leading, trailing }
    /// Presentation-only legend; routing and accessibility keep the profile label.
    public let pointing: GamepadPointingPaint?
    public let icon: GamepadControlIcon?
    public let legend: String?
    public let fontSize: CGFloat?
    public let fontWeight: Weight?
    public let fontDesign: Design?
    public let tracking: CGFloat?
    public let lineLimit: Int?
    public let alignment: Alignment?
    public let labelPadding: CGFloat?
    public let labelPlacement: Placement?
    public let trackpadFrameVisible: Bool?
    public let trackpadCursorVisible: Bool?
    public let trackpadIndicatorsVisible: Bool?
    public let joystickRingVisible: Bool?
    public let joystickKnobRatio: CGFloat?
    public let joystickKnobStrokeWidth: CGFloat?
    public init(
        icon: GamepadControlIcon? = nil,
        legend: String? = nil,
        fontSize: CGFloat? = nil,
        fontWeight: Weight? = nil,
        fontDesign: Design? = nil,
        tracking: CGFloat? = nil,
        lineLimit: Int? = nil,
        alignment: Alignment? = nil,
        labelPadding: CGFloat? = nil,
        labelPlacement: Placement? = nil,
        trackpadFrameVisible: Bool? = nil,
        trackpadCursorVisible: Bool? = nil,
        trackpadIndicatorsVisible: Bool? = nil,
        joystickRingVisible: Bool? = nil,
        joystickKnobRatio: CGFloat? = nil,
        joystickKnobStrokeWidth: CGFloat? = nil,
        pointing: GamepadPointingPaint? = nil
    ) {
        self.pointing = pointing
        self.icon = icon
        self.legend = legend
        self.fontSize = fontSize
        self.fontWeight = fontWeight
        self.fontDesign = fontDesign
        self.tracking = tracking
        self.lineLimit = lineLimit
        self.alignment = alignment
        self.labelPadding = labelPadding
        self.labelPlacement = labelPlacement
        self.trackpadFrameVisible = trackpadFrameVisible
        self.trackpadCursorVisible = trackpadCursorVisible
        self.trackpadIndicatorsVisible = trackpadIndicatorsVisible
        self.joystickRingVisible = joystickRingVisible
        self.joystickKnobRatio = joystickKnobRatio
        self.joystickKnobStrokeWidth = joystickKnobStrokeWidth
    }
    public static func == (lhs: GamepadControlContentStyle, rhs: GamepadControlContentStyle) -> Bool {
        lhs.pointing == rhs.pointing
            && lhs.icon == rhs.icon
            && lhs.legend == rhs.legend
            && lhs.fontSize == rhs.fontSize
            && lhs.fontWeight == rhs.fontWeight
            && lhs.fontDesign == rhs.fontDesign
            && lhs.tracking == rhs.tracking
            && lhs.lineLimit == rhs.lineLimit
            && lhs.alignment == rhs.alignment
            && lhs.labelPadding == rhs.labelPadding
            && lhs.labelPlacement == rhs.labelPlacement
            && lhs.trackpadFrameVisible == rhs.trackpadFrameVisible
            && lhs.trackpadCursorVisible == rhs.trackpadCursorVisible
            && lhs.trackpadIndicatorsVisible == rhs.trackpadIndicatorsVisible
            && lhs.joystickRingVisible == rhs.joystickRingVisible
            && lhs.joystickKnobRatio == rhs.joystickKnobRatio
            && lhs.joystickKnobStrokeWidth == rhs.joystickKnobStrokeWidth
    }
    var isEmpty: Bool { (pointing?.isEmpty ?? true) && icon == nil && legend == nil && fontSize == nil && fontWeight == nil && fontDesign == nil && tracking == nil && lineLimit == nil && alignment == nil && labelPadding == nil && labelPlacement == nil && trackpadFrameVisible == nil && trackpadCursorVisible == nil && trackpadIndicatorsVisible == nil && joystickRingVisible == nil && joystickKnobRatio == nil && joystickKnobStrokeWidth == nil }
    var hasTypography: Bool { legend != nil || fontSize != nil || fontWeight != nil || fontDesign != nil || tracking != nil || lineLimit != nil || alignment != nil || labelPadding != nil || labelPlacement != nil }
    var normalized: GamepadControlContentStyle {
        GamepadControlContentStyle(
            icon: icon?.normalized,
            legend: legend.map { String(String($0.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }).prefix(64)) },
            fontSize: fontSize.map { $0.isFinite ? min(max($0, 8), 72) : 8 },
            fontWeight: fontWeight,
            fontDesign: fontDesign,
            tracking: tracking.map { $0.isFinite ? min(max($0, -4), 12) : -4 },
            lineLimit: lineLimit.map { min(max($0, 1), 4) },
            alignment: alignment,
            labelPadding: labelPadding.map { $0.isFinite ? min(max($0, 0), 32) : 0 },
            labelPlacement: labelPlacement,
            trackpadFrameVisible: trackpadFrameVisible,
            trackpadCursorVisible: trackpadCursorVisible,
            trackpadIndicatorsVisible: trackpadIndicatorsVisible,
            joystickRingVisible: joystickRingVisible,
            joystickKnobRatio: joystickKnobRatio.map { $0.isFinite ? min(max($0, 0.2), 0.9) : 0.2 },
            joystickKnobStrokeWidth: joystickKnobStrokeWidth.map { $0.isFinite ? min(max($0, 0), 12) : 0 },
            pointing: pointing?.normalized
        )
    }
    func merged(over base: GamepadControlContentStyle?) -> GamepadControlContentStyle {
        GamepadControlContentStyle(
            icon: icon ?? base?.icon,
            legend: legend ?? base?.legend,
            fontSize: fontSize ?? base?.fontSize,
            fontWeight: fontWeight ?? base?.fontWeight,
            fontDesign: fontDesign ?? base?.fontDesign,
            tracking: tracking ?? base?.tracking,
            lineLimit: lineLimit ?? base?.lineLimit,
            alignment: alignment ?? base?.alignment,
            labelPadding: labelPadding ?? base?.labelPadding,
            labelPlacement: labelPlacement ?? base?.labelPlacement,
            trackpadFrameVisible: trackpadFrameVisible ?? base?.trackpadFrameVisible,
            trackpadCursorVisible: trackpadCursorVisible ?? base?.trackpadCursorVisible,
            trackpadIndicatorsVisible: trackpadIndicatorsVisible ?? base?.trackpadIndicatorsVisible,
            joystickRingVisible: joystickRingVisible ?? base?.joystickRingVisible,
            joystickKnobRatio: joystickKnobRatio ?? base?.joystickKnobRatio,
            joystickKnobStrokeWidth: joystickKnobStrokeWidth ?? base?.joystickKnobStrokeWidth,
            pointing: pointing?.merged(over: base?.pointing) ?? base?.pointing
        ).normalized
    }
}

/// Native per-surface paint bounds measured from transparent masks. Samples include
/// viewport clipping and state transforms, before sibling/artwork occlusion.
/// Immutable native drawer placement inputs and resolved padding, in canvas points.
public final class GamepadTopBarDrawerLayout: Codable, Sendable {
    public let isLandscape: Bool
    public let effectiveTopInset: CGFloat
    public let effectiveLeadingInset: CGFloat
    public let effectiveBottomInset: CGFloat
    public let effectiveTrailingInset: CGFloat
    public let minimumPortraitTopInset: CGFloat
    public let topPadding: CGFloat
    public let leadingPadding: CGFloat
    public let trailingPadding: CGFloat
    init(safeAreaInsets: EdgeInsets, isLandscape: Bool, minimumPortraitTopInset: CGFloat) {
        func finiteInset(_ value: CGFloat) -> CGFloat { value.isFinite ? max(0, value) : 0 }
        self.isLandscape = isLandscape
        effectiveTopInset = finiteInset(safeAreaInsets.top)
        effectiveLeadingInset = finiteInset(safeAreaInsets.leading)
        effectiveBottomInset = finiteInset(safeAreaInsets.bottom)
        effectiveTrailingInset = finiteInset(safeAreaInsets.trailing)
        self.minimumPortraitTopInset = isLandscape ? 0 : finiteInset(minimumPortraitTopInset)
        let topInset = max(effectiveTopInset, self.minimumPortraitTopInset)
        topPadding = max(isLandscape ? Geist.Spacing.s3 : Geist.Spacing.s2, topInset + (isLandscape ? Geist.Spacing.s2 : 0))
        leadingPadding = max(isLandscape ? Geist.Spacing.s6 : Geist.Spacing.s4, effectiveLeadingInset + Geist.Spacing.s3)
        trailingPadding = max(isLandscape ? Geist.Spacing.s6 : Geist.Spacing.s4, effectiveTrailingInset + Geist.Spacing.s3)
    }
}

/// Fixed native bar/container paint used by runtime and exact review evidence.
public final class GamepadNativeBarContainerPresentation: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let shape: String
    public let cornerRadius: CGFloat?
    public let fillColor: GamepadRGBAColor
    public let strokeColor: GamepadRGBAColor
    public let strokeWidth: CGFloat
    public let spacing: CGFloat
    public let padding: CGFloat
    public let shadowColor: GamepadRGBAColor
    public let shadowRadius: CGFloat
    public let shadowY: CGFloat
    init(isLandscape: Bool, colorScheme: ColorScheme) {
        schemaVersion = 1
        shape = isLandscape ? "capsule" : "roundedRectangle"
        cornerRadius = isLandscape ? nil : Geist.Radius.lg
        fillColor = Geist.rgba(.background100, scheme: colorScheme)
        strokeColor = Geist.rgba(.grayAlpha400, scheme: colorScheme)
        strokeWidth = 1
        spacing = isLandscape ? Geist.Spacing.s3 : Geist.Spacing.s2
        padding = Geist.Spacing.s2
        shadowColor = GamepadRGBAColor(red: 0, green: 0, blue: 0, alpha: colorScheme == .dark ? 0.22 : 0.08)
        shadowRadius = 10; shadowY = 4
    }
    public static func == (lhs: GamepadNativeBarContainerPresentation, rhs: GamepadNativeBarContainerPresentation) -> Bool {
        lhs.schemaVersion == rhs.schemaVersion && lhs.shape == rhs.shape && lhs.cornerRadius == rhs.cornerRadius
            && lhs.fillColor == rhs.fillColor && lhs.strokeColor == rhs.strokeColor && lhs.strokeWidth == rhs.strokeWidth
            && lhs.spacing == rhs.spacing && lhs.padding == rhs.padding && lhs.shadowColor == rhs.shadowColor
            && lhs.shadowRadius == rhs.shadowRadius && lhs.shadowY == rhs.shadowY
    }
}

/// Paint captured at the native item surface seam, with no routing identity.
public final class GamepadNativeBarItemEvidence: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let surfaceID: String
    public let state: GamepadControlPresentationState
    public let requested: GamepadButtonCustomization
    public let resolvedOverride: GamepadResolvedControlPresentation?
    public let fallbackForeground: GamepadRGBAColor
    public let fallbackBackground: GamepadRGBAColor
    public let fallbackBorder: GamepadRGBAColor
    public let fallbackBorderWidth: CGFloat
    public let fallbackCornerRadius: CGFloat
    public let rendererShape: String
    public let cornerRadii: GamepadCornerRadii?
    public let height: CGFloat
    public let horizontalPadding: CGFloat
    public let fallbacks: [String]
    init(item: GamepadControlBarItem, state: GamepadControlPresentationState, requested: GamepadButtonCustomization,
         resolved: GamepadResolvedControlPresentation?, foreground: GamepadRGBAColor, background: GamepadRGBAColor,
         border: GamepadRGBAColor, borderWidth: CGFloat, cornerRadius: CGFloat, height: CGFloat, padding: CGFloat, rendererShape: String, cornerRadii: GamepadCornerRadii?, reasons: [String] = []) {
        schemaVersion = 1; surfaceID = "native-control-bar/" + item.rawValue; self.state = state
        self.requested = requested; resolvedOverride = resolved
        fallbackForeground = foreground; fallbackBackground = background; fallbackBorder = border
        fallbackBorderWidth = borderWidth; fallbackCornerRadius = cornerRadius
        self.height = height; horizontalPadding = padding
        self.rendererShape = rendererShape; self.cornerRadii = cornerRadii
        fallbacks = (resolved == nil ? ["no authored surface overrides; native item fallback paint"] : []) + reasons
    }
    public static func == (lhs: GamepadNativeBarItemEvidence, rhs: GamepadNativeBarItemEvidence) -> Bool {
        lhs.schemaVersion == rhs.schemaVersion && lhs.surfaceID == rhs.surfaceID && lhs.state == rhs.state && lhs.requested == rhs.requested
            && lhs.resolvedOverride == rhs.resolvedOverride && lhs.fallbackForeground == rhs.fallbackForeground
            && lhs.fallbackBackground == rhs.fallbackBackground && lhs.fallbackBorder == rhs.fallbackBorder
            && lhs.fallbackBorderWidth == rhs.fallbackBorderWidth && lhs.fallbackCornerRadius == rhs.fallbackCornerRadius
            && lhs.rendererShape == rhs.rendererShape && lhs.cornerRadii == rhs.cornerRadii && lhs.height == rhs.height && lhs.horizontalPadding == rhs.horizontalPadding && lhs.fallbacks == rhs.fallbacks
    }
}

public final class GamepadNativeBarIconEvidence: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let surfaceID: String
    public let requested: GamepadControlIcon?
    public let resolvedSource: String
    public let resolvedValue: String
    public let assetSHA256: String?
    public let resolvedRenderingMode: String
    public let tintColor: GamepadRGBAColor?
    public let fontSize: CGFloat
    public let frameWidth: CGFloat?
    public let fallbacks: [String]
    init(item: GamepadControlBarItem, requested: GamepadControlIcon?, source: String, value: String,
         fontSize: CGFloat, frameWidth: CGFloat?, fallbacks: [String], renderingMode: String = "monochrome", tintColor: GamepadRGBAColor? = nil, assetSHA256: String? = nil) {
        schemaVersion = 1; surfaceID = "native-control-bar/" + item.rawValue + "/icon"
        self.requested = requested; resolvedSource = source; resolvedValue = value
        self.fontSize = fontSize; self.frameWidth = frameWidth; self.fallbacks = fallbacks
        resolvedRenderingMode = renderingMode; self.tintColor = tintColor; self.assetSHA256 = assetSHA256
    }
    public static func == (lhs: GamepadNativeBarIconEvidence, rhs: GamepadNativeBarIconEvidence) -> Bool {
        lhs.schemaVersion == rhs.schemaVersion && lhs.surfaceID == rhs.surfaceID && lhs.requested == rhs.requested
            && lhs.resolvedSource == rhs.resolvedSource && lhs.resolvedValue == rhs.resolvedValue
            && lhs.assetSHA256 == rhs.assetSHA256 && lhs.resolvedRenderingMode == rhs.resolvedRenderingMode && lhs.tintColor == rhs.tintColor
            && lhs.fontSize == rhs.fontSize && lhs.frameWidth == rhs.frameWidth && lhs.fallbacks == rhs.fallbacks
    }
}

public final class GamepadNativeBarPaintEvidence: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let items: [String: GamepadNativeBarItemEvidence]
    public let icons: [String: GamepadNativeBarIconEvidence]
    public let foregroundBySurfaceID: [String: GamepadRGBAColor]
    public let scope: String
    init(items: [String: GamepadNativeBarItemEvidence], icons: [String: GamepadNativeBarIconEvidence], surfaceIDs: Set<String> = []) {
        schemaVersion = 1; self.items = items; self.icons = icons
        var foregrounds: [String: GamepadRGBAColor] = [:]
        for (id, item) in items {
            let color = item.resolvedOverride?.foregroundColor ?? item.fallbackForeground
            foregrounds[id] = color
            if surfaceIDs.contains(id + "/legend") { foregrounds[id + "/legend"] = color }
        }
        for (id, icon) in icons where icon.resolvedRenderingMode != "original" && icon.resolvedRenderingMode != "none" {
            let parent = String(id.dropLast("/icon".count))
            foregrounds[id] = icon.tintColor ?? foregrounds[parent]
        }
        foregroundBySurfaceID = foregrounds
        scope = "paint recorded by native SwiftUI item surfaces for the actual enabled/pressed context; fallback colors are sRGB; resolvedOverride is used only when surface overrides exist; glyph ink, selected fonts, and hit geometry remain separate"
    }
    public static func == (lhs: GamepadNativeBarPaintEvidence, rhs: GamepadNativeBarPaintEvidence) -> Bool {
        lhs.schemaVersion == rhs.schemaVersion && lhs.items == rhs.items && lhs.icons == rhs.icons && lhs.foregroundBySurfaceID == rhs.foregroundBySurfaceID && lhs.scope == rhs.scope
    }
}

public final class GamepadNativeBarLayoutEvidence: Codable, Sendable {
    public let paint: GamepadNativeBarPaintEvidence?
    public let frames: [String: CGRect]
    public let viewport: CGRect
    public let clippedFrames: [String: CGRect]
    public let outOfViewportIDs: [String]
    public let scope: String
    init(frames: [String: CGRect], viewport: CGRect, coordinateDescription: String = "bar-image", paint: GamepadNativeBarPaintEvidence? = nil) {
        self.paint = paint; self.frames = frames; self.viewport = viewport
        clippedFrames = frames.mapValues { frame in
            let clipped = frame.intersection(viewport)
            return clipped.isNull ? .zero : clipped
        }
        outOfViewportIDs = frames.filter { !viewport.insetBy(dx: -0.001, dy: -0.001).contains($0.value) }.map(\.key).sorted()
        scope = "native SwiftUI bar/item and legend/icon leaf layout bounds in \(coordinateDescription) point coordinates; spacers are layout only; leaf frames include ancestor paint transforms, but selected fonts, glyph ink, shadows and hit geometry are separate; text-sized frames can vary with raster scale; clippedFrames intersect the raster viewport"
    }
}

/// Native leaf layout at the surface opacity seam; separate from painted ink.
public final class GamepadNativeSurfaceLayoutEvidence: Codable, Sendable {
    public let canvasBounds: CGRect
    public let clippedCanvasBounds: CGRect
    public let scope: String
    init(canvasBounds: CGRect, viewport: CGRect) {
        self.canvasBounds = canvasBounds
        let clipped = canvasBounds.intersection(viewport)
        clippedCanvasBounds = clipped.isNull ? .zero : clipped
        scope = "native SwiftUI leaf layout bounds at the surface opacity seam in canvas points, including ancestor scale/rotation; viewport intersection separate; excludes outer padding, shadow, ink and selected font; text-sized bounds can vary with raster scale"
    }
}

public final class GamepadNativeSurfaceInkEvidence: Codable, Sendable {
    public struct Sample: Codable, Sendable {
        public let pixelBounds: CGRect?
        public let canvasPointBounds: CGRect?
        public let rgbaSHA256: String
        public var nativeLayout: GamepadNativeSurfaceLayoutEvidence? = nil
    }
    public let samples: [String: Sample]
    public let rasterWidth: Int
    public let rasterHeight: Int
    public let pixelScale: CGFloat
    public let alphaThreshold: UInt8
    public let scope: String
    init(samples: [String: Sample], width: Int, height: Int, scale: CGFloat) {
        self.samples = samples; rasterWidth = width; rasterHeight = height
        pixelScale = scale; alphaThreshold = 1
        scope = "native surface masks in canvas coordinates after rotation/state scale and viewport clipping, before inter-layer occlusion; RGBA8 premultiplied sRGB; alpha > 1"
    }
}

/// Immutable native layout facts shared by the control face and review evidence. Frames
/// are local layout bounds before the parent's rotation/scale, never glyph ink bounds.
public final class GamepadNativeContentPresentation: Codable, Sendable {
    public let caption: String?
    public let effectiveFaceScale: CGFloat?
    public let triggerValue: CGFloat?
    public let triggerOrientation: GamepadTriggerOrientation?
    public let pointingPaint: GamepadPointingPaint?
    public let resolvedPointingPaint: GamepadPointingPaint?
    public let bindingHint: String?
    public let trackpadFrameStrokeWidth: CGFloat?
    public let joystickRingStrokeWidth: CGFloat?
    public let legend: String
    public let legendVisible: Bool
    public let legendHiddenReasons: [String]
    public let typographyMode: String
    public let fontSize: CGFloat?
    public let fontCandidates: [CGFloat]
    public let lineLimit: Int
    public let minimumScaleFactor: CGFloat
    public let labelPadding: CGFloat
    public let labelOffset: CGSize
    public let iconSize: CGFloat?
    public let iconOffset: CGSize?
    public let trackpadFrameVisible: Bool?
    public let trackpadCursorVisible: Bool?
    public let trackpadIndicatorsVisible: Bool?
    public let trackpadFrameInset: CGFloat?
    public let trackpadCursorFontSize: CGFloat?
    public let joystickRingVisible: Bool?
    public let joystickKnobRatio: CGFloat?
    public let joystickKnobStrokeWidth: CGFloat?
    public let localSurfaceFrames: [String: CGRect]
    public let visibleSurfaceIDs: [String]
    public let nativeFlowSurfaceIDs: [String]
    public let fixedProperties: [String: CGFloat]
    public let fallbacks: [String]

    /// Settled native input feedback composes with the authored state scale.
    /// System chrome does not inherit the input-button press contraction.
    static func stateScaleMultiplier(control: GamepadResolvedControl, state: GamepadControlPresentationState) -> CGFloat {
        if control.controlKind == .button && control.inputID != nil && state == .pressed { return 0.94 }
        if control.isTrackpad && state == .active { return 0.97 }
        return 1
    }

    init(control: GamepadResolvedControl, showsButtonLabels: Bool,
         content: GamepadControlContentStyle?, icon: GamepadControlIcon?,
         state: GamepadControlPresentationState = .normal, scheme: ColorScheme = .dark,
         triggerValue requestedTriggerValue: CGFloat? = nil, authoredScale: CGFloat = 1,
         foregroundColor: GamepadRGBAColor? = nil, profileAccentStyle: GamepadAccentStyle = .monochrome,
         trackpadTouchCount: Int = 0, secondaryBindingText: String? = nil) {
        effectiveFaceScale = authoredScale * Self.stateScaleMultiplier(control: control, state: state)
        let value = requestedTriggerValue ?? (state.usesPressedFallback ? 1 : 0)
        triggerValue = control.isTrigger ? (value.isFinite ? min(1, max(0, value)) : 0) : nil
        triggerOrientation = control.isTrigger ? control.triggerSettings?.normalized.orientation ?? .vertical : nil
        pointingPaint = content?.pointing
        trackpadFrameStrokeWidth = control.isTrackpad ? content?.pointing?.trackpadFrameStrokeWidth ?? 1 : nil
        joystickRingStrokeWidth = control.isJoystick ? content?.pointing?.joystickRingStrokeWidth ?? 1 : nil
        let accent = control.layoutCustomization.accentStyle ?? profileAccentStyle
        let foreground = foregroundColor?.normalized ?? GamepadRGBAColor(color:
            control.layoutCustomization.buttonForeground(accentStyle: accent, isPressed: state.usesPressedFallback, scheme: scheme)).normalized
        func tint(_ opacity: CGFloat) -> GamepadRGBAColor {
            GamepadRGBAColor(red: foreground.red, green: foreground.green, blue: foreground.blue,
                alpha: foreground.alpha * opacity).normalized
        }
        if control.isJoystick {
            resolvedPointingPaint = GamepadPointingPaint(
                joystickRingColor: content?.pointing?.joystickRingColor ?? GamepadRGBAColor(color: Geist.color(.grayAlpha400, scheme: scheme)),
                joystickKnobFillColor: content?.pointing?.joystickKnobFillColor ?? GamepadRGBAColor(color:
                    control.layoutCustomization.joystickKnobFill(accentStyle: accent, isPressed: state.usesPressedFallback, scheme: scheme)),
                joystickKnobStrokeColor: content?.pointing?.joystickKnobStrokeColor ?? GamepadRGBAColor(color:
                    control.layoutCustomization.joystickKnobStroke(accentStyle: accent, isPressed: state.usesPressedFallback, scheme: scheme)),
                joystickRingStrokeWidth: joystickRingStrokeWidth).normalized
        } else if control.isTrackpad {
            resolvedPointingPaint = GamepadPointingPaint(
                trackpadFrameColor: content?.pointing?.trackpadFrameColor ?? tint(0.24),
                trackpadCursorColor: content?.pointing?.trackpadCursorColor ?? tint(0.82),
                trackpadIndicatorColor: content?.pointing?.trackpadIndicatorColor ?? tint(0.34),
                trackpadSecondaryIndicatorColor: content?.pointing?.trackpadSecondaryIndicatorColor ?? tint(trackpadTouchCount >= 2 ? 0.42 : 0.18),
                trackpadFrameStrokeWidth: trackpadFrameStrokeWidth).normalized
        } else {
            resolvedPointingPaint = nil
        }
        let size = control.size
        let side = min(size.width, size.height)
        let thumbstick = control.layoutCustomization.joystickVisualStyle == .thumbstick
        legend = content?.legend ?? control.visualLegend
        caption = control.presentationMetadata?.caption
        let labels = showsButtonLabels && control.layoutCustomization.showsIntegratedLabel
        legendVisible = control.isText || (!control.isDecoration && labels
            && (!control.isJoystick || !thumbstick)
            && (control.isJoystick || control.isTrackpad || icon?.placement != .center || legend.count <= 2))
        var hidden: [String] = []
        if !control.isText {
            if control.isDecoration { hidden.append("non-text-decoration") }
            if !showsButtonLabels { hidden.append("profile-labels-disabled") }
            if !control.layoutCustomization.showsIntegratedLabel { hidden.append("external-label-policy") }
            if control.isJoystick && thumbstick { hidden.append("thumbstick-has-no-integrated-legend") }
            if !control.isJoystick && !control.isTrackpad && icon?.placement == .center && legend.count > 2 {
                hidden.append("centered-icon-with-long-legend")
            }
        }
        legendHiddenReasons = hidden
        bindingHint = legendVisible && !control.isText
            ? KeypadBindingPresentationBuilder.visibleHint(secondaryBindingText, label: control.label, icon: icon) : nil
        let fallbackSize: CGFloat = control.isText ? max(10, size.height * 0.72)
            : control.isJoystick ? (side <= 88 ? 12 : 14)
            : control.isTrackpad ? (size.width <= 96 ? 12 : 14)
            : control.isTrigger ? (size.height <= 44 ? 12 : 14)
            : (legend.count <= 2 ? 32 : 14)
        let authored = content?.hasTypography == true
        let nativeFit = !authored && !control.isText && !control.isJoystick && !control.isTrackpad && !control.isTrigger && legend.count > 2
        typographyMode = authored ? "authored-system" : nativeFit ? "native-geist-fit" : control.isText ? "native-system" : "native-geist"
        fontSize = nativeFit ? nil : content?.fontSize ?? fallbackSize
        fontCandidates = nativeFit ? [16, 14, 14] : [content?.fontSize ?? fallbackSize]
        lineLimit = authored ? content?.lineLimit ?? 1 : 1
        minimumScaleFactor = authored ? (content?.fontSize == nil ? 0.48 : 1)
            : control.isText ? 0.12 : control.isTrigger ? 0.5 : nativeFit ? 1 : (control.isJoystick || control.isTrackpad ? 0.48 : 0.55)
        labelPadding = content?.labelPadding ?? (control.isText ? 2 : control.isTrackpad ? 0 : control.isTrigger ? 8 : 4)
        if let placement = content?.labelPlacement {
            switch placement {
            case .top: labelOffset = .init(width: 0, height: -size.height * 0.32 + labelPadding)
            case .bottom: labelOffset = .init(width: 0, height: size.height * 0.32 - labelPadding)
            case .leading: labelOffset = .init(width: -size.width * 0.28 + labelPadding, height: 0)
            case .trailing: labelOffset = .init(width: size.width * 0.28 - labelPadding, height: 0)
            case .center: labelOffset = .zero
            }
        } else if control.isJoystick {
            labelOffset = .init(width: 0, height: size.height * 0.34)
        } else if control.isTrackpad || control.isText {
            labelOffset = .zero
        } else {
            switch icon?.placement {
            case .leading: labelOffset = .init(width: size.width * 0.11, height: 0)
            case .trailing: labelOffset = .init(width: -size.width * 0.11, height: 0)
            case .top: labelOffset = .init(width: 0, height: size.height * 0.15)
            case .bottom: labelOffset = .init(width: 0, height: -size.height * 0.15)
            case .center, .background, nil: labelOffset = .zero
            }
        }
        iconSize = icon.map { max(12, side * 0.34 * $0.scale) }
        iconOffset = icon.map { icon in
            switch icon.placement {
            case .leading: CGSize(width: -size.width * 0.20, height: 0)
            case .trailing: CGSize(width: size.width * 0.20, height: 0)
            case .top: CGSize(width: 0, height: -size.height * 0.18)
            case .bottom: CGSize(width: 0, height: size.height * 0.18)
            case .center, .background: CGSize.zero
            }
        }
        trackpadFrameVisible = control.isTrackpad ? content?.trackpadFrameVisible ?? true : nil
        trackpadCursorVisible = control.isTrackpad ? content?.trackpadCursorVisible ?? true : nil
        trackpadIndicatorsVisible = control.isTrackpad ? content?.trackpadIndicatorsVisible ?? true : nil
        trackpadFrameInset = control.isTrackpad ? max(5, side * 0.08) : nil
        trackpadCursorFontSize = control.isTrackpad ? max(12, side * 0.18) : nil
        joystickRingVisible = control.isJoystick ? content?.joystickRingVisible ?? !thumbstick : nil
        joystickKnobRatio = control.isJoystick ? content?.joystickKnobRatio ?? (thumbstick ? 0.72 : 0.34) : nil
        joystickKnobStrokeWidth = control.isJoystick ? content?.joystickKnobStrokeWidth ?? 1 : nil
        var frames: [String: CGRect] = [:]
        if control.isJoystick {
            let knob = side * (joystickKnobRatio ?? 0.34)
            frames["joystick-puck"] = CGRect(x: (size.width - knob) / 2, y: (size.height - knob) / 2, width: knob, height: knob)
            if joystickRingVisible == true {
                let ring = side * 0.70
                frames["joystick-well-ring"] = CGRect(x: (size.width - ring) / 2, y: (size.height - ring) / 2, width: ring, height: ring)
            }
        }
        if control.isTrackpad {
            if trackpadFrameVisible == true { frames["trackpad-frame"] = CGRect(origin: .zero, size: size).insetBy(dx: trackpadFrameInset ?? 5, dy: trackpadFrameInset ?? 5) }
            if trackpadIndicatorsVisible == true {
                frames["trackpad-indicators"] = CGRect(x: size.width * 0.33, y: size.height * 0.86 - 2.5, width: size.width * 0.34, height: 5)
            }
        }
        if control.isTrigger {
            let fraction = triggerValue ?? 0
            if triggerOrientation == .vertical {
                let height = min(size.height, max(4, size.height * fraction))
                frames["trigger-fill"] = CGRect(x: 0, y: size.height - height, width: size.width, height: height)
            } else {
                frames["trigger-fill"] = CGRect(x: 0, y: 0, width: min(size.width, max(4, size.width * fraction)), height: size.height)
            }
        }
        localSurfaceFrames = frames
        var surfaces = control.isText ? [String]() : ["face"]
        if legendVisible { surfaces.append("legend") }
        if legendVisible && caption?.isEmpty == false { surfaces.append("caption") }
        if bindingHint != nil { surfaces.append("binding-hint") }
        if icon != nil && !control.isText && !control.isJoystick && !control.isTrackpad { surfaces.append("icon") }
        if control.isTrigger { surfaces.append("trigger-fill") }
        if control.isJoystick {
            surfaces.append("joystick-puck")
            if joystickRingVisible == true { surfaces.append("joystick-well-ring") }
        }
        if control.isTrackpad {
            if trackpadFrameVisible == true { surfaces.append("trackpad-frame") }
            if trackpadCursorVisible == true { surfaces.append("trackpad-cursor") }
            if trackpadIndicatorsVisible == true { surfaces.append("trackpad-indicators") }
        }
        visibleSurfaceIDs = surfaces
        nativeFlowSurfaceIDs = surfaces.filter { ["legend", "caption", "binding-hint", "icon", "trackpad-cursor"].contains($0) }
        var fixed: [String: CGFloat] = control.isTrackpad ? ["legendOpacity": 0.82,
            "cursorLegendSpacing": 9, "indicatorSpacing": 7] : control.isJoystick ? ["ringDiameterRatio": 0.70] : [:]
        if control.isTrackpad {
            if content?.pointing?.trackpadFrameColor == nil { fixed["fallbackFrameTintOpacity"] = 0.24 }
            if content?.pointing?.trackpadCursorColor == nil { fixed["fallbackCursorOpacity"] = 0.82 }
            if content?.pointing?.trackpadIndicatorColor == nil { fixed["fallbackFirstIndicatorOpacity"] = 0.34 }
            if content?.pointing?.trackpadSecondaryIndicatorColor == nil { fixed["fallbackSecondIndicatorOpacity"] = 0.18 }
        }
        if legendVisible && caption?.isEmpty == false {
            fixed["captionFontSize"] = 10; fixed["captionOpacity"] = 0.76; fixed["captionMinimumScaleFactor"] = 0.5
            fixed["captionWidthRatio"] = 0.88
        }
        if bindingHint != nil {
            fixed["bindingHintFontSize"] = 10; fixed["bindingHintOpacity"] = 0.76
            fixed["bindingHintMinimumScaleFactor"] = 0.5; fixed["bindingHintWidthRatio"] = 0.88
        }
        if control.isTrigger {
            fixed["triggerMinimumFillDimension"] = 4
            fixed["triggerFillOpacity"] = scheme == .dark ? 0.24 : 0.18
        }
        fixed["nativeStateScaleMultiplier"] = Self.stateScaleMultiplier(control: control, state: state)
        fixedProperties = fixed
        var defaults: [String] = []
        if icon != nil && control.isText { defaults.append("native-text-icon-not-rendered") }
        if content?.legend == nil { defaults.append(control.presentationMetadata?.legend == nil ? "profile-label" : "native-model-legend") }
        if content?.fontSize == nil { defaults.append("native-font-size") }
        if nativeFit { defaults.append("native-font-fit-selection") }
        if control.isTrackpad {
            if content?.trackpadFrameVisible == nil { defaults.append("native-trackpad-frame") }
            if content?.pointing?.trackpadFrameColor == nil { defaults.append("native-trackpad-frame-color") }
            if content?.pointing?.trackpadFrameStrokeWidth == nil { defaults.append("native-trackpad-frame-stroke-width") }
            if content?.pointing?.trackpadCursorColor == nil { defaults.append("native-trackpad-cursor-color") }
            if content?.pointing?.trackpadIndicatorColor == nil { defaults.append("native-trackpad-indicator-color") }
            if content?.pointing?.trackpadSecondaryIndicatorColor == nil { defaults.append("native-trackpad-secondary-indicator-color") }
            if content?.trackpadCursorVisible == nil { defaults.append("native-trackpad-cursor") }
            if content?.trackpadIndicatorsVisible == nil { defaults.append("native-trackpad-indicators") }
        }
        if control.isJoystick {
            if content?.joystickRingVisible == nil { defaults.append("native-joystick-ring") }
            if content?.pointing?.joystickRingColor == nil { defaults.append("native-joystick-ring-color") }
            if content?.pointing?.joystickRingStrokeWidth == nil { defaults.append("native-joystick-ring-stroke-width") }
            if content?.pointing?.joystickKnobFillColor == nil { defaults.append("native-joystick-puck-fill") }
            if content?.pointing?.joystickKnobStrokeColor == nil { defaults.append("native-joystick-puck-stroke") }
            if content?.joystickKnobRatio == nil { defaults.append("native-joystick-puck-ratio") }
            if content?.joystickKnobStrokeWidth == nil { defaults.append("native-joystick-puck-stroke-width") }
        }
        if control.isTrigger { defaults.append("native-trigger-fill-foreground-tint") }
        fallbacks = defaults
    }
}

public struct GamepadControlStateStyle: Codable, Equatable, Sendable {
    public var content: GamepadControlContentStyle?
    public var fillStyle: GamepadFillStyle?
    public var foregroundColor: GamepadRGBAColor?
    public var strokeColor: GamepadRGBAColor?
    public var strokeWidth: CGFloat?
    public var shadowColor: GamepadRGBAColor?
    public var shadowRadius: CGFloat?
    public var shadowX: CGFloat?
    public var shadowY: CGFloat?
    public var shadows: [GamepadControlShadowStyle]?
    public var glowColor: GamepadRGBAColor?
    public var glowRadius: CGFloat?
    public var innerShadowColor: GamepadRGBAColor?
    public var innerShadowRadius: CGFloat?
    public var innerShadowX: CGFloat?
    public var innerShadowY: CGFloat?
    public var highlightColor: GamepadRGBAColor?
    public var highlightRadius: CGFloat?
    public var highlightX: CGFloat?
    public var highlightY: CGFloat?
    public var highlightOpacity: CGFloat?
    public var bevelHighlightColor: GamepadRGBAColor?
    public var bevelShadowColor: GamepadRGBAColor?
    public var bevelWidth: CGFloat?
    /// Optional short, non-enclosing state index rendered at the control's top edge.
    public var indexColor: GamepadRGBAColor?
    public var indexWidth: CGFloat?
    public var opacity: CGFloat?
    public var scale: CGFloat?
    public var blurRadius: CGFloat?

    public init(
        fillStyle: GamepadFillStyle? = nil,
        foregroundColor: GamepadRGBAColor? = nil,
        strokeColor: GamepadRGBAColor? = nil,
        strokeWidth: CGFloat? = nil,
        shadowColor: GamepadRGBAColor? = nil,
        shadowRadius: CGFloat? = nil,
        shadowX: CGFloat? = nil,
        shadowY: CGFloat? = nil,
        shadows: [GamepadControlShadowStyle]? = nil,
        glowColor: GamepadRGBAColor? = nil,
        glowRadius: CGFloat? = nil,
        innerShadowColor: GamepadRGBAColor? = nil,
        innerShadowRadius: CGFloat? = nil,
        innerShadowX: CGFloat? = nil,
        innerShadowY: CGFloat? = nil,
        highlightColor: GamepadRGBAColor? = nil,
        highlightRadius: CGFloat? = nil,
        highlightX: CGFloat? = nil,
        highlightY: CGFloat? = nil,
        highlightOpacity: CGFloat? = nil,
        bevelHighlightColor: GamepadRGBAColor? = nil,
        bevelShadowColor: GamepadRGBAColor? = nil,
        bevelWidth: CGFloat? = nil,
        indexColor: GamepadRGBAColor? = nil,
        indexWidth: CGFloat? = nil,
        opacity: CGFloat? = nil,
        scale: CGFloat? = nil,
        blurRadius: CGFloat? = nil,
        content: GamepadControlContentStyle? = nil
    ) {
        self.content = content
        self.fillStyle = fillStyle
        self.foregroundColor = foregroundColor
        self.strokeColor = strokeColor
        self.strokeWidth = strokeWidth
        self.shadowColor = shadowColor
        self.shadowRadius = shadowRadius
        self.shadowX = shadowX
        self.shadowY = shadowY
        self.shadows = shadows
        self.glowColor = glowColor
        self.glowRadius = glowRadius
        self.innerShadowColor = innerShadowColor
        self.innerShadowRadius = innerShadowRadius
        self.innerShadowX = innerShadowX
        self.innerShadowY = innerShadowY
        self.highlightColor = highlightColor
        self.highlightRadius = highlightRadius
        self.highlightX = highlightX
        self.highlightY = highlightY
        self.highlightOpacity = highlightOpacity
        self.bevelHighlightColor = bevelHighlightColor
        self.bevelShadowColor = bevelShadowColor
        self.bevelWidth = bevelWidth
        self.indexColor = indexColor
        self.indexWidth = indexWidth
        self.opacity = opacity
        self.scale = scale
        self.blurRadius = blurRadius
    }

    public static let empty = GamepadControlStateStyle()

    var normalized: GamepadControlStateStyle {
        GamepadControlStateStyle(
            fillStyle: fillStyle?.normalized,
            foregroundColor: foregroundColor?.normalized,
            strokeColor: strokeColor?.normalized,
            strokeWidth: strokeWidth.map { Self.clamp($0, lower: 0, upper: 12) },
            shadowColor: shadowColor?.normalized,
            shadowRadius: shadowRadius.map { Self.clamp($0, lower: 0, upper: 48) },
            shadowX: shadowX.map { Self.clamp($0, lower: -64, upper: 64) },
            shadowY: shadowY.map { Self.clamp($0, lower: -64, upper: 64) },
            shadows: shadows.map { Array($0.prefix(8)).map(\.normalized) },
            glowColor: glowColor?.normalized,
            glowRadius: glowRadius.map { Self.clamp($0, lower: 0, upper: 64) },
            innerShadowColor: innerShadowColor?.normalized,
            innerShadowRadius: innerShadowRadius.map { Self.clamp($0, lower: 0, upper: 64) },
            innerShadowX: innerShadowX.map { Self.clamp($0, lower: -64, upper: 64) },
            innerShadowY: innerShadowY.map { Self.clamp($0, lower: -64, upper: 64) },
            highlightColor: highlightColor?.normalized,
            highlightRadius: highlightRadius.map { Self.clamp($0, lower: 0, upper: 64) },
            highlightX: highlightX.map { Self.clamp($0, lower: -64, upper: 64) },
            highlightY: highlightY.map { Self.clamp($0, lower: -64, upper: 64) },
            highlightOpacity: highlightOpacity.map { Self.clamp($0, lower: 0, upper: 1) },
            bevelHighlightColor: bevelHighlightColor?.normalized,
            bevelShadowColor: bevelShadowColor?.normalized,
            bevelWidth: bevelWidth.map { Self.clamp($0, lower: 0, upper: 24) },
            indexColor: indexColor?.normalized,
            indexWidth: indexWidth.map { Self.clamp($0, lower: 0, upper: 12) },
            opacity: opacity.map { Self.clamp($0, lower: 0, upper: 1) },
            scale: scale.map { Self.clamp($0, lower: 0.5, upper: 1.5) },
            blurRadius: blurRadius.map { Self.clamp($0, lower: 0, upper: 24) },
            content: content?.isEmpty == false ? content?.normalized : nil
        )
    }

    var isEmpty: Bool {
        (content?.isEmpty ?? true)
            && fillStyle == nil
            && foregroundColor == nil
            && strokeColor == nil
            && strokeWidth == nil
            && shadowColor == nil
            && shadowRadius == nil
            && shadowX == nil
            && shadowY == nil
            && shadows == nil
            && glowColor == nil
            && glowRadius == nil
            && innerShadowColor == nil
            && innerShadowRadius == nil
            && innerShadowX == nil
            && innerShadowY == nil
            && highlightColor == nil
            && highlightRadius == nil
            && highlightX == nil
            && highlightY == nil
            && highlightOpacity == nil
            && bevelHighlightColor == nil
            && bevelShadowColor == nil
            && bevelWidth == nil
            && indexColor == nil
            && indexWidth == nil
            && opacity == nil
            && scale == nil
            && blurRadius == nil
    }

    func merged(over base: GamepadControlStateStyle) -> GamepadControlStateStyle {
        GamepadControlStateStyle(
            fillStyle: fillStyle ?? base.fillStyle,
            foregroundColor: foregroundColor ?? base.foregroundColor,
            strokeColor: strokeColor ?? base.strokeColor,
            strokeWidth: strokeWidth ?? base.strokeWidth,
            shadowColor: shadowColor ?? base.shadowColor,
            shadowRadius: shadowRadius ?? base.shadowRadius,
            shadowX: shadowX ?? base.shadowX,
            shadowY: shadowY ?? base.shadowY,
            shadows: shadows ?? base.shadows,
            glowColor: glowColor ?? base.glowColor,
            glowRadius: glowRadius ?? base.glowRadius,
            innerShadowColor: innerShadowColor ?? base.innerShadowColor,
            innerShadowRadius: innerShadowRadius ?? base.innerShadowRadius,
            innerShadowX: innerShadowX ?? base.innerShadowX,
            innerShadowY: innerShadowY ?? base.innerShadowY,
            highlightColor: highlightColor ?? base.highlightColor,
            highlightRadius: highlightRadius ?? base.highlightRadius,
            highlightX: highlightX ?? base.highlightX,
            highlightY: highlightY ?? base.highlightY,
            highlightOpacity: highlightOpacity ?? base.highlightOpacity,
            bevelHighlightColor: bevelHighlightColor ?? base.bevelHighlightColor,
            bevelShadowColor: bevelShadowColor ?? base.bevelShadowColor,
            bevelWidth: bevelWidth ?? base.bevelWidth,
            indexColor: indexColor ?? base.indexColor,
            indexWidth: indexWidth ?? base.indexWidth,
            opacity: opacity ?? base.opacity,
            scale: scale ?? base.scale,
            blurRadius: blurRadius ?? base.blurRadius,
            content: content?.merged(over: base.content) ?? base.content
        ).normalized
    }

    private static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        guard value.isFinite else { return lower }
        return min(max(value, lower), upper)
    }
}

private final class GamepadControlVisualStyleStorage: @unchecked Sendable {
    var normal: GamepadControlStateStyle
    var pressed: GamepadControlStateStyle?
    var active: GamepadControlStateStyle?
    var disabled: GamepadControlStateStyle?
    var icon: GamepadControlIcon?
    var hapticStyle: GamepadHapticStyle?
    var hapticFeedback: GamepadHapticFeedback?

    init(normal: GamepadControlStateStyle) {
        self.normal = normal
        self.pressed = nil
        self.active = nil
        self.disabled = nil
        self.icon = nil
        self.hapticStyle = nil
        self.hapticFeedback = nil
    }

    init(
        normal: GamepadControlStateStyle,
        pressed: GamepadControlStateStyle?,
        active: GamepadControlStateStyle?,
        disabled: GamepadControlStateStyle?,
        icon: GamepadControlIcon?,
        hapticStyle: GamepadHapticStyle?,
        hapticFeedback: GamepadHapticFeedback?
    ) {
        self.normal = normal
        self.pressed = pressed
        self.active = active
        self.disabled = disabled
        self.icon = icon
        self.hapticStyle = hapticStyle
        self.hapticFeedback = hapticFeedback
    }

    func copy() -> GamepadControlVisualStyleStorage {
        GamepadControlVisualStyleStorage(
            normal: normal,
            pressed: pressed,
            active: active,
            disabled: disabled,
            icon: icon,
            hapticStyle: hapticStyle,
            hapticFeedback: hapticFeedback
        )
    }
}

/// Copy-on-write storage prevents every button, style token, and skin rule from
/// embedding four large state-style values while preserving struct value semantics.
public struct GamepadControlVisualStyle: Codable, Equatable, Sendable {
    private var storage: GamepadControlVisualStyleStorage

    public var normal: GamepadControlStateStyle {
        get { storage.normal }
        set {
            ensureUniqueStorage()
            storage.normal = newValue
        }
    }

    public var pressed: GamepadControlStateStyle? {
        get { storage.pressed }
        set {
            ensureUniqueStorage()
            storage.pressed = newValue
        }
    }

    public var active: GamepadControlStateStyle? {
        get { storage.active }
        set {
            ensureUniqueStorage()
            storage.active = newValue
        }
    }

    public var disabled: GamepadControlStateStyle? {
        get { storage.disabled }
        set {
            ensureUniqueStorage()
            storage.disabled = newValue
        }
    }

    public var icon: GamepadControlIcon? {
        get { storage.icon }
        set {
            ensureUniqueStorage()
            storage.icon = newValue
        }
    }

    public var hapticStyle: GamepadHapticStyle? {
        get { storage.hapticStyle }
        set {
            ensureUniqueStorage()
            storage.hapticStyle = newValue
        }
    }

    public var hapticFeedback: GamepadHapticFeedback? {
        get { storage.hapticFeedback }
        set {
            ensureUniqueStorage()
            storage.hapticFeedback = newValue
        }
    }

    public init(
        normal: GamepadControlStateStyle = .empty,
        pressed: GamepadControlStateStyle? = nil,
        active: GamepadControlStateStyle? = nil,
        disabled: GamepadControlStateStyle? = nil,
        icon: GamepadControlIcon? = nil,
        hapticStyle: GamepadHapticStyle? = nil,
        hapticFeedback: GamepadHapticFeedback? = nil
    ) {
        storage = GamepadControlVisualStyleStorage(
            normal: normal,
            pressed: pressed,
            active: active,
            disabled: disabled,
            icon: icon,
            hapticStyle: hapticStyle,
            hapticFeedback: hapticFeedback
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        storage = GamepadControlVisualStyleStorage(
            normal: try container.decode(GamepadControlStateStyle.self, forKey: .normal)
        )
        storage.pressed = try container.decodeIfPresent(GamepadControlStateStyle.self, forKey: .pressed)
        storage.active = try container.decodeIfPresent(GamepadControlStateStyle.self, forKey: .active)
        storage.disabled = try container.decodeIfPresent(GamepadControlStateStyle.self, forKey: .disabled)
        storage.icon = try container.decodeIfPresent(GamepadControlIcon.self, forKey: .icon)
        storage.hapticStyle = try container.decodeIfPresent(GamepadHapticStyle.self, forKey: .hapticStyle)
        storage.hapticFeedback = try container.decodeIfPresent(GamepadHapticFeedback.self, forKey: .hapticFeedback)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(storage.normal, forKey: .normal)
        try container.encodeIfPresent(storage.pressed, forKey: .pressed)
        try container.encodeIfPresent(storage.active, forKey: .active)
        try container.encodeIfPresent(storage.disabled, forKey: .disabled)
        try container.encodeIfPresent(storage.icon, forKey: .icon)
        try container.encodeIfPresent(storage.hapticStyle, forKey: .hapticStyle)
        try container.encodeIfPresent(storage.hapticFeedback, forKey: .hapticFeedback)
    }

    public static func == (
        lhs: GamepadControlVisualStyle,
        rhs: GamepadControlVisualStyle
    ) -> Bool {
        if lhs.storage === rhs.storage { return true }
        if lhs.storage.normal != rhs.storage.normal { return false }
        if lhs.storage.pressed != rhs.storage.pressed { return false }
        if lhs.storage.active != rhs.storage.active { return false }
        if lhs.storage.disabled != rhs.storage.disabled { return false }
        if lhs.storage.icon != rhs.storage.icon { return false }
        if lhs.storage.hapticStyle != rhs.storage.hapticStyle { return false }
        return lhs.storage.hapticFeedback == rhs.storage.hapticFeedback
    }

    public static let empty = GamepadControlVisualStyle()

    var normalized: GamepadControlVisualStyle? {
        var copy = self
        copy.normalizeInPlace()
        return copy.isEmpty ? nil : copy
    }

    mutating func normalizeInPlace() {
        ensureUniqueStorage()
        normalizeStateStylesInPlace()
        normalizeFeedbackInPlace()
    }

    private mutating func normalizeStateStylesInPlace() {
        storage.normal = storage.normal.normalized
        storage.pressed = storage.pressed?.normalized
        storage.active = storage.active?.normalized
        storage.disabled = storage.disabled?.normalized
    }

    private mutating func normalizeFeedbackInPlace() {
        storage.icon = storage.icon?.normalized
        storage.hapticFeedback = storage.hapticFeedback?.normalized
    }

    var isEmpty: Bool {
        if !storage.normal.isEmpty { return false }
        if storage.pressed?.isEmpty == false { return false }
        if storage.active?.isEmpty == false { return false }
        if storage.disabled?.isEmpty == false { return false }
        if storage.icon != nil { return false }
        if storage.hapticStyle != nil { return false }
        return storage.hapticFeedback == nil
    }

    func stateStyle(for state: GamepadControlPresentationState) -> GamepadControlStateStyle {
        let override: GamepadControlStateStyle?
        switch state {
        case .normal:
            override = nil
        case .pressed:
            override = storage.pressed
        case .active:
            override = storage.active ?? storage.pressed
        case .disabled:
            override = storage.disabled
        }
        return (override ?? .empty).merged(over: storage.normal).normalized
    }

    private mutating func ensureUniqueStorage() {
        if !isKnownUniquelyReferenced(&storage) {
            storage = storage.copy()
        }
    }

    private enum CodingKeys: String, CodingKey {
        case normal
        case pressed
        case active
        case disabled
        case icon
        case hapticStyle
        case hapticFeedback
    }
}

public extension GamepadControlVisualStyle {
    static func softWhiteRaised(
        fill: GamepadRGBAColor = GamepadRGBAColor(hexString: "#F7F4F8") ?? .defaultValue,
        foreground: GamepadRGBAColor = GamepadRGBAColor(hexString: "#7C61A8") ?? .defaultValue
    ) -> GamepadControlVisualStyle {
        GamepadControlVisualStyle(
            normal: GamepadControlStateStyle(
                fillStyle: .solid(fill),
                foregroundColor: foreground,
                strokeColor: GamepadRGBAColor(hexString: "#FFFFFF", alpha: 0.68),
                strokeWidth: 1,
                shadows: [
                    .outer("#FFFFFF", alpha: 0.96, radius: 14, x: -7, y: -7),
                    .outer("#9B91AA", alpha: 0.24, radius: 20, x: 8, y: 9)
                ],
                highlightColor: GamepadRGBAColor(hexString: "#FFFFFF"),
                highlightRadius: 10,
                highlightX: -5,
                highlightY: -5,
                highlightOpacity: 0.34,
                bevelHighlightColor: GamepadRGBAColor(hexString: "#FFFFFF", alpha: 0.70),
                bevelShadowColor: GamepadRGBAColor(hexString: "#C8C0D2", alpha: 0.50),
                bevelWidth: 1.25
            ),
            pressed: GamepadControlStateStyle(
                fillStyle: .solid(GamepadRGBAColor(hexString: "#EDE8F1") ?? fill),
                shadows: [
                    .outer("#A89DB7", alpha: 0.18, radius: 8, x: 3, y: 3),
                    .outer("#FFFFFF", alpha: 0.74, radius: 8, x: -2, y: -2)
                ],
                innerShadowColor: GamepadRGBAColor(hexString: "#B5AFC1", alpha: 0.36),
                innerShadowRadius: 6,
                innerShadowX: 2,
                innerShadowY: 2,
                highlightOpacity: 0.10,
                bevelWidth: 0.6,
                scale: 0.975
            ),
            hapticFeedback: GamepadHapticFeedback(style: .soft, pattern: .single, intensity: 0.42, sharpness: 0.22)
        )
    }

    static func softWhiteInset(
        fill: GamepadRGBAColor = GamepadRGBAColor(hexString: "#EFEAF2") ?? .defaultValue,
        foreground: GamepadRGBAColor = GamepadRGBAColor(hexString: "#8067A7") ?? .defaultValue
    ) -> GamepadControlVisualStyle {
        GamepadControlVisualStyle(
            normal: GamepadControlStateStyle(
                fillStyle: .solid(fill),
                foregroundColor: foreground,
                strokeColor: GamepadRGBAColor(hexString: "#FFFFFF", alpha: 0.42),
                strokeWidth: 1,
                shadows: [
                    .outer("#FFFFFF", alpha: 0.62, radius: 10, x: -3, y: -3),
                    .outer("#B0A7BC", alpha: 0.20, radius: 12, x: 4, y: 5)
                ],
                innerShadowColor: GamepadRGBAColor(hexString: "#AFA7BB", alpha: 0.30),
                innerShadowRadius: 8,
                innerShadowX: 3,
                innerShadowY: 3,
                highlightColor: GamepadRGBAColor(hexString: "#FFFFFF"),
                highlightRadius: 8,
                highlightX: -4,
                highlightY: -4,
                highlightOpacity: 0.22,
                bevelHighlightColor: GamepadRGBAColor(hexString: "#FFFFFF", alpha: 0.58),
                bevelShadowColor: GamepadRGBAColor(hexString: "#B7AEC4", alpha: 0.42),
                bevelWidth: 1
            ),
            pressed: GamepadControlStateStyle(
                innerShadowRadius: 10,
                innerShadowX: 4,
                innerShadowY: 4,
                scale: 0.985
            ),
            hapticFeedback: GamepadHapticFeedback(style: .soft, pattern: .single, intensity: 0.34, sharpness: 0.18)
        )
    }

    static func softWhitePlate(
        fill: GamepadRGBAColor = GamepadRGBAColor(hexString: "#F2EEF5") ?? .defaultValue
    ) -> GamepadControlVisualStyle {
        GamepadControlVisualStyle(
            normal: GamepadControlStateStyle(
                fillStyle: .solid(fill),
                foregroundColor: GamepadRGBAColor(hexString: "#8169A7"),
                strokeColor: GamepadRGBAColor(hexString: "#FFFFFF", alpha: 0.48),
                strokeWidth: 1,
                shadows: [
                    .outer("#FFFFFF", alpha: 0.92, radius: 26, x: -12, y: -12),
                    .outer("#998DAA", alpha: 0.22, radius: 34, x: 14, y: 16)
                ],
                highlightColor: GamepadRGBAColor(hexString: "#FFFFFF"),
                highlightRadius: 22,
                highlightX: -10,
                highlightY: -10,
                highlightOpacity: 0.26,
                bevelHighlightColor: GamepadRGBAColor(hexString: "#FFFFFF", alpha: 0.64),
                bevelShadowColor: GamepadRGBAColor(hexString: "#C8C0D2", alpha: 0.42),
                bevelWidth: 1.4
            )
        )
    }
}

/// Immutable indirection keeps style-library elements cheap to copy and compare in collections.
private final class GamepadVisualStyleBox: @unchecked Sendable {
    let value: GamepadControlVisualStyle

    init(_ value: GamepadControlVisualStyle) {
        self.value = value
    }
}

public struct GamepadStyleToken: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var appliesTo: [GamepadCustomControlKind]
    private var storedVisualStyle: GamepadVisualStyleBox

    public var visualStyle: GamepadControlVisualStyle {
        get { storedVisualStyle.value }
        set { storedVisualStyle = GamepadVisualStyleBox(newValue) }
    }

    public init(
        id: String = UUID().uuidString,
        name: String,
        appliesTo: [GamepadCustomControlKind] = GamepadCustomControlKind.allCases,
        visualStyle: GamepadControlVisualStyle
    ) {
        self.id = id
        self.name = name
        self.appliesTo = appliesTo
        self.storedVisualStyle = GamepadVisualStyleBox(visualStyle)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        appliesTo = try container.decodeIfPresent(
            [GamepadCustomControlKind].self,
            forKey: .appliesTo
        ) ?? GamepadCustomControlKind.allCases
        storedVisualStyle = GamepadVisualStyleBox(
            try container.decode(GamepadControlVisualStyle.self, forKey: .visualStyle)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(appliesTo, forKey: .appliesTo)
        try container.encode(storedVisualStyle.value, forKey: .visualStyle)
    }

    public static func == (lhs: GamepadStyleToken, rhs: GamepadStyleToken) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.appliesTo == rhs.appliesTo
            && lhs.storedVisualStyle.value == rhs.storedVisualStyle.value
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case appliesTo
        case visualStyle
    }

    var normalized: GamepadStyleToken? {
        let normalizedID = Self.normalizedIdentifier(id)
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty, !normalizedName.isEmpty, let style = visualStyle.normalized else { return nil }
        let kinds = appliesTo.isEmpty ? GamepadCustomControlKind.allCases : Array(Set(appliesTo)).sorted { $0.rawValue < $1.rawValue }
        return GamepadStyleToken(
            id: normalizedID,
            name: String(normalizedName.prefix(48)),
            appliesTo: kinds,
            visualStyle: style
        )
    }

    static func normalizedIdentifier(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let allowedPunctuation = CharacterSet(charactersIn: "-_.")
        let scalars = trimmed.unicodeScalars.map { scalar -> UnicodeScalar in
            if CharacterSet.alphanumerics.contains(scalar) || allowedPunctuation.contains(scalar) {
                return scalar
            }
            return UnicodeScalar("-")
        }
        return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
    }
}

public struct GamepadStyleLibrary: Codable, Equatable, Sendable {
    public var styles: [GamepadStyleToken]

    public init(styles: [GamepadStyleToken] = []) {
        self.styles = styles
    }

    public static let empty = GamepadStyleLibrary()

    func style(id: String?) -> GamepadStyleToken? {
        guard let id else { return nil }
        return normalized.styles.first { $0.id == id }
    }

    var normalized: GamepadStyleLibrary {
        var seen = Set<String>()
        let normalizedStyles = styles.compactMap { style -> GamepadStyleToken? in
            guard let normalized = style.normalized, seen.insert(normalized.id).inserted else { return nil }
            return normalized
        }
        return GamepadStyleLibrary(styles: normalizedStyles)
    }

    var isEmpty: Bool { normalized.styles.isEmpty }
}

public enum GamepadAssetRole: String, Codable, CaseIterable, Identifiable, Sendable {
    case background
    case icon
    case texture
    case reference

    public var id: String { rawValue }
}

public struct GamepadAsset: Codable, Equatable, Identifiable, Sendable {
    public static let maximumStoredBytes = GamepadImageFill.maximumStoredBytes

    public var id: String
    public var name: String
    public var fileName: String?
    public var contentType: String
    public var data: Data?
    public var byteCount: Int
    public var hash: String?
    public var role: GamepadAssetRole

    public init(
        id: String = UUID().uuidString,
        name: String,
        fileName: String? = nil,
        contentType: String = "application/octet-stream",
        data: Data? = nil,
        byteCount: Int? = nil,
        hash: String? = nil,
        role: GamepadAssetRole = .reference
    ) {
        self.id = id
        self.name = name
        self.fileName = fileName
        self.contentType = contentType
        self.data = data
        self.byteCount = byteCount ?? data?.count ?? 0
        self.hash = hash
        self.role = role
    }

    var normalized: GamepadAsset? {
        let normalizedID = GamepadStyleToken.normalizedIdentifier(id)
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty, !normalizedName.isEmpty else { return nil }
        let storedData = (data?.count ?? 0) <= Self.maximumStoredBytes ? data : nil
        let type = contentType.trimmingCharacters(in: .whitespacesAndNewlines)
        return GamepadAsset(
            id: normalizedID,
            name: String(normalizedName.prefix(64)),
            fileName: fileName?.trimmingCharacters(in: .whitespacesAndNewlines),
            contentType: type.isEmpty ? "application/octet-stream" : String(type.prefix(80)),
            data: storedData,
            byteCount: storedData?.count ?? max(0, byteCount),
            hash: hash?.trimmingCharacters(in: .whitespacesAndNewlines),
            role: role
        )
    }
}

public struct GamepadAssetLibrary: Codable, Equatable, Sendable {
    public var assets: [GamepadAsset]

    public init(assets: [GamepadAsset] = []) {
        self.assets = assets
    }

    public static let empty = GamepadAssetLibrary()

    public func asset(id: String?) -> GamepadAsset? {
        guard let id else { return nil }
        return normalized.assets.first { $0.id == id }
    }

    var normalized: GamepadAssetLibrary {
        var seen = Set<String>()
        let normalizedAssets = assets.compactMap { asset -> GamepadAsset? in
            guard let normalized = asset.normalized, seen.insert(normalized.id).inserted else { return nil }
            return normalized
        }
        return GamepadAssetLibrary(assets: normalizedAssets)
    }

    var isEmpty: Bool { normalized.assets.isEmpty }
}

public struct GamepadEditorGridSettings: Codable, Equatable, Sendable {
    public var showsGrid: Bool
    public var snapToGrid: Bool
    public var snapToObjects: Bool
    public var gridSize: CGFloat
    public var snapTolerance: CGFloat

    public init(
        showsGrid: Bool = false,
        snapToGrid: Bool = false,
        snapToObjects: Bool = true,
        gridSize: CGFloat = 16,
        snapTolerance: CGFloat = 6
    ) {
        self.showsGrid = showsGrid
        self.snapToGrid = snapToGrid
        self.snapToObjects = snapToObjects
        self.gridSize = gridSize
        self.snapTolerance = snapTolerance
    }

    public static let defaultValue = GamepadEditorGridSettings()

    var normalized: GamepadEditorGridSettings {
        GamepadEditorGridSettings(
            showsGrid: showsGrid,
            snapToGrid: snapToGrid,
            snapToObjects: snapToObjects,
            gridSize: Self.clamp(gridSize, lower: 4, upper: 128),
            snapTolerance: Self.clamp(snapTolerance, lower: 0, upper: 32)
        )
    }

    var isDefault: Bool { normalized == Self.defaultValue }

    private static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        guard value.isFinite else { return lower }
        return min(max(value, lower), upper)
    }
}

public enum GamepadEditorGuideOrientation: String, Codable, CaseIterable, Identifiable, Sendable {
    case horizontal
    case vertical

    public var id: String { rawValue }
}

public struct GamepadEditorGuide: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var orientation: GamepadEditorGuideOrientation
    public var position: CGFloat

    public init(id: UUID = UUID(), orientation: GamepadEditorGuideOrientation, position: CGFloat) {
        self.id = id
        self.orientation = orientation
        self.position = position
    }

    var normalized: GamepadEditorGuide {
        GamepadEditorGuide(
            id: id,
            orientation: orientation,
            position: position.isFinite ? position : 0
        )
    }
}

public struct GamepadLayerGroup: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var children: [GamepadControlIdentity]
    public var isLocked: Bool
    public var isHidden: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        children: [GamepadControlIdentity] = [],
        isLocked: Bool = false,
        isHidden: Bool = false
    ) {
        self.id = id
        self.name = name
        self.children = children
        self.isLocked = isLocked
        self.isHidden = isHidden
    }

    func normalized(availableControls: Set<GamepadControlIdentity>) -> GamepadLayerGroup? {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<GamepadControlIdentity>()
        let normalizedChildren = children.filter { availableControls.contains($0) && seen.insert($0).inserted }
        guard !normalizedChildren.isEmpty else { return nil }
        return GamepadLayerGroup(
            id: id,
            name: String((normalizedName.isEmpty ? "Group" : normalizedName).prefix(48)),
            children: normalizedChildren,
            isLocked: isLocked,
            isHidden: isHidden
        )
    }
}

/// Persistent descriptive intent. Output routing remains owned by the element's bindings.
/// Immutable storage keeps native presentation metadata small in aggregate values.
public final class GamepadControlPresentation: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let actionID: String?
    public let purposeID: String?
    public let groupIDs: [String]
    public let legend: String?
    public let caption: String?
    public let accessibilityName: String?

    public init(schemaVersion: Int = 1, actionID: String? = nil, purposeID: String? = nil,
                groupIDs: [String] = [], legend: String? = nil, caption: String? = nil,
                accessibilityName: String? = nil) {
        self.schemaVersion = schemaVersion; self.actionID = actionID; self.purposeID = purposeID
        self.groupIDs = groupIDs; self.legend = legend; self.caption = caption; self.accessibilityName = accessibilityName
    }
    public var isValid: Bool {
        func tag(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.count <= 64 && value.unicodeScalars.allSatisfy {
                (97...122).contains($0.value) || (48...57).contains($0.value) || [45, 46, 95].contains($0.value)
            }
        }
        func text(_ value: String?, limit: Int) -> Bool {
            value.map { $0.unicodeScalars.count <= limit && !$0.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }) } ?? true
        }
        return schemaVersion == 1 && [actionID, purposeID].compactMap { $0 }.allSatisfy(tag)
            && groupIDs.count <= 16 && Set(groupIDs).count == groupIDs.count && groupIDs.allSatisfy(tag)
            && text(legend, limit: 64) && text(caption, limit: 128) && text(accessibilityName, limit: 128)
            && (accessibilityName.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? true)
    }
    public static func == (lhs: GamepadControlPresentation, rhs: GamepadControlPresentation) -> Bool {
        lhs.schemaVersion == rhs.schemaVersion && lhs.actionID == rhs.actionID && lhs.purposeID == rhs.purposeID
            && lhs.groupIDs == rhs.groupIDs && lhs.legend == rhs.legend && lhs.caption == rhs.caption
            && lhs.accessibilityName == rhs.accessibilityName
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, actionID, purposeID, groupIDs, legend, caption, accessibilityName
    }
    private struct Key: CodingKey {
        let stringValue: String; let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    public convenience init(from decoder: Decoder) throws {
        let all = try decoder.container(keyedBy: Key.self)
        guard Set(all.allKeys.map(\.stringValue)).isSubset(of: Set(CodingKeys.allCases.map(\.rawValue))) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unsupported native presentation field."))
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(schemaVersion: try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1,
            actionID: try c.decodeIfPresent(String.self, forKey: .actionID),
            purposeID: try c.decodeIfPresent(String.self, forKey: .purposeID),
            groupIDs: try c.decodeIfPresent([String].self, forKey: .groupIDs) ?? [],
            legend: try c.decodeIfPresent(String.self, forKey: .legend),
            caption: try c.decodeIfPresent(String.self, forKey: .caption),
            accessibilityName: try c.decodeIfPresent(String.self, forKey: .accessibilityName))
        guard isValid else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Native presentation exceeds its versioned text/tag bounds."))
        }
    }
}

public struct GamepadDesignMetadata: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var layerOrder: [GamepadControlIdentity]
    public var groups: [GamepadLayerGroup]
    public var grid: GamepadEditorGridSettings
    public var guides: [GamepadEditorGuide]
    public var notes: String?
    public var tags: [String]
    /// Stable origin used by skin compatibility. Display names and tags are intentionally not contracts.
    public var sourceTemplateID: String?
    public var sourceTemplateRevision: Int?

    public init(
        schemaVersion: Int = 1,
        layerOrder: [GamepadControlIdentity] = [],
        groups: [GamepadLayerGroup] = [],
        grid: GamepadEditorGridSettings = .defaultValue,
        guides: [GamepadEditorGuide] = [],
        notes: String? = nil,
        tags: [String] = [],
        sourceTemplateID: String? = nil,
        sourceTemplateRevision: Int? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.layerOrder = layerOrder
        self.groups = groups
        self.grid = grid
        self.guides = guides
        self.notes = notes
        self.tags = tags
        self.sourceTemplateID = sourceTemplateID
        self.sourceTemplateRevision = sourceTemplateRevision
    }

    public static let empty = GamepadDesignMetadata()

    func normalized(availableControls: [GamepadControlIdentity]) -> GamepadDesignMetadata? {
        let availableSet = Set(availableControls)
        var seen = Set<GamepadControlIdentity>()
        var normalizedLayerOrder = layerOrder.filter { availableSet.contains($0) && seen.insert($0).inserted }
        for identity in availableControls where !seen.contains(identity) {
            normalizedLayerOrder.append(identity)
            seen.insert(identity)
        }
        let normalizedGroups = groups.compactMap { $0.normalized(availableControls: availableSet) }
        let normalizedGuides = guides.map(\.normalized)
        let normalizedTags = Array(Set(tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
        let normalizedNotes = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTemplateID = sourceTemplateID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let copy = GamepadDesignMetadata(
            schemaVersion: max(1, schemaVersion),
            layerOrder: normalizedLayerOrder,
            groups: normalizedGroups,
            grid: grid.normalized,
            guides: normalizedGuides,
            notes: normalizedNotes?.isEmpty == false ? String(normalizedNotes!.prefix(500)) : nil,
            tags: normalizedTags.map { String($0.prefix(32)) },
            sourceTemplateID: normalizedTemplateID?.isEmpty == false ? String(normalizedTemplateID!.prefix(80)) : nil,
            sourceTemplateRevision: sourceTemplateRevision.map { max(1, $0) }
        )
        return copy.isDefault(availableControls: availableControls) ? nil : copy
    }

    func isDefault(availableControls: [GamepadControlIdentity]) -> Bool {
        let implicitOrder = availableControls
        let explicitOrderMatches = layerOrder.isEmpty || layerOrder == implicitOrder
        return schemaVersion <= 1
            && explicitOrderMatches
            && groups.isEmpty
            && grid.normalized.isDefault
            && guides.isEmpty
            && (notes?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            && tags.isEmpty
            && (sourceTemplateID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            && sourceTemplateRevision == nil
    }
}

extension GamepadControlIdentity: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case button
        case id
        case system
        case controlBarItem
    }

    private enum Kind: String, Codable {
        case builtin
        case custom
        case system
        case controlBarItem
    }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let raw = try? single.decode(String.self) {
            if raw.hasPrefix("builtin.") {
                let buttonRaw = String(raw.dropFirst("builtin.".count))
                if let button = KeypadElementID(rawValue: buttonRaw) {
                    self = .builtin(button)
                    return
                }
            } else if raw.hasPrefix("custom.") {
                let idRaw = String(raw.dropFirst("custom.".count))
                if let id = UUID(uuidString: idRaw) {
                    self = .custom(id)
                    return
                }
            } else if raw.hasPrefix("system.") {
                let systemRaw = String(raw.dropFirst("system.".count))
                if let control = GamepadSystemControl(rawValue: systemRaw) {
                    self = .system(control)
                    return
                }
            } else if raw.hasPrefix("control_bar_item.") {
                let itemRaw = String(raw.dropFirst("control_bar_item.".count))
                if let item = GamepadControlBarItem(rawValue: itemRaw) {
                    self = .controlBarItem(item)
                    return
                }
            } else if let control = GamepadSystemControl(rawValue: raw) {
                self = .system(control)
                return
            } else if let button = KeypadElementID(rawValue: raw) {
                self = .builtin(button)
                return
            } else if let id = UUID(uuidString: raw) {
                self = .custom(id)
                return
            }
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .builtin:
            self = .builtin(try container.decode(KeypadElementID.self, forKey: .button))
        case .custom:
            self = .custom(try container.decode(UUID.self, forKey: .id))
        case .system:
            if let control = try container.decodeIfPresent(GamepadSystemControl.self, forKey: .system) {
                self = .system(control)
            } else {
                self = .system(try container.decode(GamepadSystemControl.self, forKey: .id))
            }
        case .controlBarItem:
            self = .controlBarItem(try container.decode(GamepadControlBarItem.self, forKey: .controlBarItem))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .builtin(let button):
            try container.encode(Kind.builtin, forKey: .kind)
            try container.encode(button, forKey: .button)
        case .custom(let id):
            try container.encode(Kind.custom, forKey: .kind)
            try container.encode(id, forKey: .id)
        case .system(let control):
            try container.encode(Kind.system, forKey: .kind)
            try container.encode(control, forKey: .system)
        case .controlBarItem(let item):
            try container.encode(Kind.controlBarItem, forKey: .kind)
            try container.encode(item, forKey: .controlBarItem)
        }
    }
}

public struct GamepadResolvedControlPresentation: Codable, Equatable, Sendable {
    public var content: GamepadControlContentStyle? = nil
    public var fillStyle: GamepadFillStyle
    public var foregroundColor: GamepadRGBAColor
    public var strokeColor: GamepadRGBAColor
    public var strokeWidth: CGFloat
    public var shadowColor: GamepadRGBAColor
    public var shadowRadius: CGFloat
    public var shadowX: CGFloat
    public var shadowY: CGFloat
    public var shadows: [GamepadControlShadowStyle]
    public var glowColor: GamepadRGBAColor?
    public var glowRadius: CGFloat
    public var innerShadowColor: GamepadRGBAColor?
    public var innerShadowRadius: CGFloat
    public var innerShadowX: CGFloat
    public var innerShadowY: CGFloat
    public var highlightColor: GamepadRGBAColor?
    public var highlightRadius: CGFloat
    public var highlightX: CGFloat
    public var highlightY: CGFloat
    public var highlightOpacity: CGFloat
    public var bevelHighlightColor: GamepadRGBAColor?
    public var bevelShadowColor: GamepadRGBAColor?
    public var bevelWidth: CGFloat
    public var indexColor: GamepadRGBAColor?
    public var indexWidth: CGFloat
    public var opacity: CGFloat
    public var scale: CGFloat
    public var blurRadius: CGFloat
    public var icon: GamepadControlIcon?
    public var hapticStyle: GamepadHapticStyle
    public var hapticFeedback: GamepadHapticFeedback

    public init(
        fillStyle: GamepadFillStyle,
        foregroundColor: GamepadRGBAColor,
        strokeColor: GamepadRGBAColor,
        strokeWidth: CGFloat,
        shadowColor: GamepadRGBAColor,
        shadowRadius: CGFloat,
        shadowX: CGFloat = 0,
        shadowY: CGFloat,
        shadows: [GamepadControlShadowStyle] = [],
        glowColor: GamepadRGBAColor? = nil,
        glowRadius: CGFloat = 0,
        innerShadowColor: GamepadRGBAColor? = nil,
        innerShadowRadius: CGFloat = 0,
        innerShadowX: CGFloat = 0,
        innerShadowY: CGFloat = 0,
        highlightColor: GamepadRGBAColor? = nil,
        highlightRadius: CGFloat = 0,
        highlightX: CGFloat = 0,
        highlightY: CGFloat = 0,
        highlightOpacity: CGFloat = 0,
        bevelHighlightColor: GamepadRGBAColor? = nil,
        bevelShadowColor: GamepadRGBAColor? = nil,
        bevelWidth: CGFloat = 0,
        indexColor: GamepadRGBAColor? = nil,
        indexWidth: CGFloat = 0,
        opacity: CGFloat = 1,
        scale: CGFloat = 1,
        blurRadius: CGFloat = 0,
        icon: GamepadControlIcon? = nil,
        hapticStyle: GamepadHapticStyle = .light,
        hapticFeedback: GamepadHapticFeedback? = nil
    ) {
        self.fillStyle = fillStyle.normalized
        self.foregroundColor = foregroundColor.normalized
        self.strokeColor = strokeColor.normalized
        self.strokeWidth = Self.clamp(strokeWidth, lower: 0, upper: 12)
        self.shadowColor = shadowColor.normalized
        self.shadowRadius = Self.clamp(shadowRadius, lower: 0, upper: 64)
        self.shadowX = Self.clamp(shadowX, lower: -64, upper: 64)
        self.shadowY = Self.clamp(shadowY, lower: -64, upper: 64)
        self.shadows = Array(shadows.prefix(8)).map(\.normalized)
        self.glowColor = glowColor?.normalized
        self.glowRadius = Self.clamp(glowRadius, lower: 0, upper: 64)
        self.innerShadowColor = innerShadowColor?.normalized
        self.innerShadowRadius = Self.clamp(innerShadowRadius, lower: 0, upper: 64)
        self.innerShadowX = Self.clamp(innerShadowX, lower: -64, upper: 64)
        self.innerShadowY = Self.clamp(innerShadowY, lower: -64, upper: 64)
        self.highlightColor = highlightColor?.normalized
        self.highlightRadius = Self.clamp(highlightRadius, lower: 0, upper: 64)
        self.highlightX = Self.clamp(highlightX, lower: -64, upper: 64)
        self.highlightY = Self.clamp(highlightY, lower: -64, upper: 64)
        self.highlightOpacity = Self.clamp(highlightOpacity, lower: 0, upper: 1)
        self.bevelHighlightColor = bevelHighlightColor?.normalized
        self.bevelShadowColor = bevelShadowColor?.normalized
        self.bevelWidth = Self.clamp(bevelWidth, lower: 0, upper: 24)
        self.indexColor = indexColor?.normalized
        self.indexWidth = Self.clamp(indexWidth, lower: 0, upper: 12)
        self.opacity = Self.clamp(opacity, lower: 0, upper: 1)
        self.scale = Self.clamp(scale, lower: 0.5, upper: 1.5)
        self.blurRadius = Self.clamp(blurRadius, lower: 0, upper: 24)
        self.icon = icon?.normalized
        let resolvedHapticFeedback = (hapticFeedback ?? GamepadHapticFeedback(style: hapticStyle)).normalized
        self.hapticFeedback = resolvedHapticFeedback
        self.hapticStyle = resolvedHapticFeedback.style
    }

    public var foregroundSwiftUIColor: Color { foregroundColor.swiftUIColor }
    public var strokeSwiftUIColor: Color { strokeColor.swiftUIColor }
    public var shadowSwiftUIColor: Color { shadowColor.swiftUIColor }
    public var glowSwiftUIColor: Color? { glowColor?.swiftUIColor }
    public var innerShadowSwiftUIColor: Color? { innerShadowColor?.swiftUIColor }
    public var highlightSwiftUIColor: Color? { highlightColor?.swiftUIColor }
    public var bevelHighlightSwiftUIColor: Color? { bevelHighlightColor?.swiftUIColor }
    public var bevelShadowSwiftUIColor: Color? { bevelShadowColor?.swiftUIColor }
    public var indexSwiftUIColor: Color? { indexColor?.swiftUIColor }

    private static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        guard value.isFinite else { return lower }
        return min(max(value, lower), upper)
    }
}

extension GamepadButtonCustomization {
    var hasRichDesignOverrides: Bool {
        styleID != nil || visualStyle != nil || icon != nil || hapticStyle != nil || hapticFeedback != nil
    }

    var styleSnapshot: GamepadButtonCustomization {
        GamepadButtonCustomization(
            shape: shape,
            accentStyle: accentStyle,
            fillColor: fillColor,
            lightFillColor: lightFillColor,
            darkFillColor: darkFillColor,
            fillStyle: fillStyle,
            lightFillStyle: lightFillStyle,
            darkFillStyle: darkFillStyle,
            joystickKnobColor: joystickKnobColor,
            lightJoystickKnobColor: lightJoystickKnobColor,
            darkJoystickKnobColor: darkJoystickKnobColor,
            styleID: styleID,
            visualStyle: visualStyle,
            icon: icon,
            hapticStyle: hapticStyle,
            hapticFeedback: hapticFeedback,
            cornerRadius: cornerRadius,
            cornerRadii: cornerRadii,
            shadowStrength: shadowStrength
        ).normalized
    }

    mutating func applyStyleSnapshot(_ snapshot: GamepadButtonCustomization) {
        shape = snapshot.shape
        accentStyle = snapshot.accentStyle
        fillColor = snapshot.fillColor
        lightFillColor = snapshot.lightFillColor
        darkFillColor = snapshot.darkFillColor
        fillStyle = snapshot.fillStyle
        lightFillStyle = snapshot.lightFillStyle
        darkFillStyle = snapshot.darkFillStyle
        joystickKnobColor = snapshot.joystickKnobColor
        lightJoystickKnobColor = snapshot.lightJoystickKnobColor
        darkJoystickKnobColor = snapshot.darkJoystickKnobColor
        styleID = snapshot.styleID
        visualStyle = snapshot.visualStyle
        icon = snapshot.icon
        hapticStyle = snapshot.hapticStyle
        hapticFeedback = snapshot.hapticFeedback
        cornerRadius = snapshot.cornerRadius
        cornerRadii = snapshot.cornerRadii
        shadowStrength = snapshot.shadowStrength
    }
}

public enum GamepadThemePreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case cavernGlow = "cavern-glow"
    case softWhiteController = "soft-white-controller"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .cavernGlow: "Cavern Glow"
        case .softWhiteController: "Soft White Controller"
        }
    }

    public var description: String {
        switch self {
        case .cavernGlow:
            "A marketable dark-fantasy action theme with misty cave gradients, pale glyph buttons, cyan soul glows, slate utility controls, pressed states, icons, and tactile haptics."
        case .softWhiteController:
            "A near-reference soft/neumorphic white gamepad material with lavender typography, layered white highlights, low purple shadows, inset pressed states, and tactile haptics."
        }
    }

    public static func resolve(_ value: String) -> GamepadThemePreset? {
        let normalized = normalizedLookup(value)
        return allCases.first { preset in
            normalized == normalizedLookup(preset.rawValue)
                || normalized == normalizedLookup(preset.displayName)
                || preset.aliases.contains(normalized)
        }
    }

    public func apply(to customization: inout GamepadCustomization) {
        // Materialize appearance mirrors only from installed declarations. A
        // theme is not an instruction to construct absent starter controls.
        customization.normalizeInPlace()
        switch self {
        case .cavernGlow:
            Self.applyCavernGlow(to: &customization)
        case .softWhiteController:
            Self.applySoftWhiteController(to: &customization)
        }
    }

    public func applying(to customization: GamepadCustomization) -> GamepadCustomization {
        var copy = customization
        apply(to: &copy)
        return copy.normalized
    }

    private var aliases: Set<String> {
        switch self {
        case .cavernGlow:
            [
                "cavernglow",
                "cavernknight",
                "darkfantasy",
                "bugknight",
                "hollowknight",
                "hollowknightinspired",
                "hallownest",
                "hallownestglow"
            ]
        case .softWhiteController:
            [
                "softwhite",
                "softcontroller",
                "neumorphic",
                "neumorphism",
                "whitecontroller",
                "lavendercontroller",
                "referencegamepad",
                "premiumwhite"
            ]
        }
    }

    private static func applyCavernGlow(to customization: inout GamepadCustomization) {
        customization.colorSchemePreference = .dark
        customization.accentStyle = .purple
        customization.showsButtonLabels = true
        customization.backgroundLightFillStyle = .gradient(
            gradient(
                angle: 145,
                stops: [
                    (0.00, "#E5EDF2", 1.0),
                    (0.42, "#94A3B8", 1.0),
                    (1.00, "#1E293B", 1.0)
                ]
            )
        )
        customization.backgroundDarkFillStyle = .gradient(
            gradient(
                angle: 132,
                stops: [
                    (0.00, "#04070D", 1.0),
                    (0.38, "#0B1324", 1.0),
                    (0.74, "#111827", 1.0),
                    (1.00, "#1E1B4B", 1.0)
                ]
            )
        )
        customization.backgroundFillStyle = nil
        customization.backgroundLightColor = nil
        customization.backgroundDarkColor = nil
        customization.styleLibrary = cavernGlowStyleLibrary

        for button in customization.elements.filter({ $0.kind == .button && DefaultKeypadElements.ids.contains($0.inputID) }).map(\.inputID) {
            var layout = customization.buttonCustomization(for: button)
            applyCavernGlowRole(to: &layout, button: button, label: customization.visualLabel(for: button), controlKind: .button)
            customization.setButtonCustomization(layout, for: button)
        }

        for index in customization.customButtons.indices {
            var layout = customization.customButtons[index].layout
            let custom = customization.customButtons[index]
            applyCavernGlowRole(
                to: &layout,
                button: custom.inputID,
                label: custom.label,
                controlKind: custom.controlKind
            )
            customization.customButtons[index].layout = layout.normalized
        }

        var metadata = customization.designMetadata ?? .empty
        var tags = Set(metadata.tags)
        tags.insert("showcase")
        tags.insert("dark-fantasy")
        tags.insert("marketable")
        metadata.tags = Array(tags).sorted()
        metadata.notes = metadata.notes ?? "Styled with Thumble's Cavern Glow showcase theme for streamable, shareable, marketable game keypads."
        customization.designMetadata = metadata.normalized(availableControls: customization.allControlIdentitiesForDesign)
        customization.updatedAt = Date.currentMilliseconds
        customization = customization.normalized
    }

    private static func applySoftWhiteController(to customization: inout GamepadCustomization) {
        customization.colorSchemePreference = .light
        customization.accentStyle = .purple
        customization.showsButtonLabels = true
        customization.backgroundLightFillStyle = .gradient(
            gradient(
                angle: 135,
                stops: [
                    (0.00, "#FFFFFF", 1.0),
                    (0.42, "#F4F0F7", 1.0),
                    (1.00, "#E7E0EC", 1.0)
                ]
            )
        )
        customization.backgroundDarkFillStyle = .gradient(
            gradient(
                angle: 135,
                stops: [
                    (0.00, "#F9F6FB", 1.0),
                    (1.00, "#D9D0E4", 1.0)
                ]
            )
        )
        customization.backgroundFillStyle = nil
        customization.backgroundLightColor = nil
        customization.backgroundDarkColor = nil
        customization.styleLibrary = softWhiteStyleLibrary

        for button in customization.elements.filter({ $0.kind == .button && DefaultKeypadElements.ids.contains($0.inputID) }).map(\.inputID) {
            var layout = customization.buttonCustomization(for: button)
            applySoftWhiteRole(to: &layout, button: button, controlKind: .button)
            customization.setButtonCustomization(layout, for: button)
        }

        for index in customization.customButtons.indices {
            var layout = customization.customButtons[index].layout
            let custom = customization.customButtons[index]
            applySoftWhiteRole(to: &layout, button: custom.inputID, controlKind: custom.controlKind)
            customization.customButtons[index].layout = layout.normalized
        }

        var metadata = customization.designMetadata ?? .empty
        var tags = Set(metadata.tags)
        tags.insert("showcase")
        tags.insert("soft-white")
        tags.insert("neumorphic")
        metadata.tags = Array(tags).sorted()
        metadata.notes = metadata.notes ?? "Styled with Thumble's Soft White Controller material for layered neumorphic pads inspired by premium white game controllers."
        customization.designMetadata = metadata.normalized(availableControls: customization.allControlIdentitiesForDesign)
        customization.updatedAt = Date.currentMilliseconds
        customization = customization.normalized
    }

    private static var softWhiteStyleLibrary: GamepadStyleLibrary {
        GamepadStyleLibrary(styles: [
            GamepadStyleToken(id: "soft-white-raised", name: "Soft White Raised", visualStyle: .softWhiteRaised()),
            GamepadStyleToken(id: "soft-white-inset", name: "Soft White Inset", visualStyle: .softWhiteInset()),
            GamepadStyleToken(id: "soft-white-plate", name: "Soft White Plate", appliesTo: GamepadCustomControlKind.allCases, visualStyle: .softWhitePlate()),
            GamepadStyleToken(
                id: "soft-white-lavender",
                name: "Lavender Face Button",
                visualStyle: .softWhiteRaised(
                    fill: color("#F9F6FA"),
                    foreground: color("#7F61AA")
                )
            )
        ].compactMap { $0.normalized }).normalized
    }

    private static func applySoftWhiteRole(
        to layout: inout GamepadButtonCustomization,
        button: KeypadElementID,
        controlKind: GamepadCustomControlKind
    ) {
        layout.shadowStrength = 0
        layout.visualStyle = nil
        switch controlKind {
        case .joystick:
            layout.styleID = "soft-white-inset"
            layout.shape = .circle
            layout.joystickKnobColor = color("#F9F7FA")
            layout.joystickVisualStyle = layout.joystickVisualStyle ?? .pad
        case .trigger, .trackpad:
            layout.styleID = "soft-white-raised"
            if controlKind == .trigger { layout.shape = .capsule }
            if controlKind == .trackpad { layout.shape = .roundedRectangle }
        case .text:
            layout.styleID = "soft-white-lavender"
        case .decoration:
            layout.styleID = "soft-white-plate"
        case .button:
            if [.preset(5), .preset(6), .preset(7), .preset(8)].contains(button) {
                layout.styleID = "soft-white-lavender"
            } else {
                layout.styleID = "soft-white-raised"
            }
        }
    }

    private static var cavernGlowStyleLibrary: GamepadStyleLibrary {
        GamepadStyleLibrary(styles: [
            styleToken(
                id: "cavern-stone",
                name: "Cavern Stone",
                fill: .gradient(gradient(angle: 160, stops: [(0, "#0B1120", 1), (0.52, "#172033", 1), (1, "#020617", 1)])),
                foreground: "#E0F2FE",
                stroke: "#64748B",
                strokeWidth: 1.5,
                pressedFill: .gradient(gradient(angle: 160, stops: [(0, "#101827", 1), (1, "#334155", 1)])),
                shadow: "#000000",
                shadowAlpha: 0.42,
                shadowRadius: 12,
                shadowY: 7,
                glow: "#38BDF8",
                glowAlpha: 0.22,
                glowRadius: 6,
                haptic: GamepadHapticFeedback(style: .light, pattern: .single, intensity: 0.42, sharpness: 0.34, duration: 0.045)
            ),
            styleToken(
                id: "cavern-nail",
                name: "Nail Slash",
                fill: .gradient(gradient(angle: 22, stops: [(0, "#111827", 1), (0.55, "#334155", 1), (1, "#E2E8F0", 0.92)])),
                foreground: "#F8FAFC",
                stroke: "#E0F2FE",
                strokeWidth: 2.2,
                pressedFill: .solid(color("#F8FAFC")),
                pressedForeground: "#020617",
                shadow: "#000000",
                shadowAlpha: 0.48,
                shadowRadius: 16,
                shadowY: 9,
                glow: "#F8FAFC",
                glowAlpha: 0.34,
                glowRadius: 12,
                haptic: GamepadHapticFeedback(style: .rigid, pattern: .single, intensity: 0.72, sharpness: 0.95, duration: 0.045)
            ),
            styleToken(
                id: "cavern-soul",
                name: "Soul Orb",
                fill: .gradient(gradient(angle: 35, stops: [(0, "#F8FAFC", 1), (0.52, "#BAE6FD", 1), (1, "#0EA5E9", 0.92)])),
                foreground: "#020617",
                stroke: "#E0F2FE",
                strokeWidth: 2.5,
                pressedFill: .gradient(gradient(angle: 35, stops: [(0, "#7DD3FC", 1), (1, "#0369A1", 1)])),
                pressedForeground: "#FFFFFF",
                shadow: "#075985",
                shadowAlpha: 0.44,
                shadowRadius: 18,
                shadowY: 8,
                glow: "#38BDF8",
                glowAlpha: 0.70,
                glowRadius: 18,
                haptic: GamepadHapticFeedback(style: .soft, pattern: .pulse, intensity: 0.58, sharpness: 0.28, duration: 0.12)
            ),
            styleToken(
                id: "cavern-dash",
                name: "Dash Streak",
                fill: .gradient(gradient(angle: 0, stops: [(0, "#0F172A", 1), (0.42, "#0284C7", 1), (1, "#7DD3FC", 0.96)])),
                foreground: "#F8FAFC",
                stroke: "#BAE6FD",
                strokeWidth: 2,
                pressedFill: .gradient(gradient(angle: 0, stops: [(0, "#0369A1", 1), (1, "#E0F2FE", 1)])),
                shadow: "#082F49",
                shadowAlpha: 0.50,
                shadowRadius: 18,
                shadowY: 8,
                glow: "#0EA5E9",
                glowAlpha: 0.58,
                glowRadius: 16,
                haptic: GamepadHapticFeedback(style: .medium, pattern: .single, intensity: 0.64, sharpness: 0.72, duration: 0.055)
            ),
            styleToken(
                id: "cavern-jump",
                name: "Pale Jump",
                fill: .gradient(gradient(angle: 120, stops: [(0, "#E0F2FE", 1), (0.55, "#94A3B8", 1), (1, "#475569", 1)])),
                foreground: "#020617",
                stroke: "#F8FAFC",
                strokeWidth: 2,
                pressedFill: .solid(color("#CBD5E1")),
                shadow: "#000000",
                shadowAlpha: 0.38,
                shadowRadius: 14,
                shadowY: 7,
                glow: "#E0F2FE",
                glowAlpha: 0.32,
                glowRadius: 10,
                haptic: GamepadHapticFeedback(style: .light, pattern: .single, intensity: 0.50, sharpness: 0.42, duration: 0.05)
            ),
            styleToken(
                id: "cavern-parchment",
                name: "Slate Utility",
                fill: .gradient(gradient(angle: 18, stops: [(0, "#E5E7EB", 1), (0.58, "#9CA3AF", 1), (1, "#374151", 1)])),
                foreground: "#111827",
                stroke: "#F3F4F6",
                strokeWidth: 1.6,
                pressedFill: .solid(color("#D1D5DB")),
                shadow: "#111827",
                shadowAlpha: 0.42,
                shadowRadius: 12,
                shadowY: 7,
                glow: "#D1D5DB",
                glowAlpha: 0.32,
                glowRadius: 10,
                haptic: GamepadHapticFeedback(style: .light, pattern: .double, intensity: 0.40, sharpness: 0.36, duration: 0.05)
            ),
            styleToken(
                id: "cavern-rune",
                name: "Small Rune",
                fill: .gradient(gradient(angle: 90, stops: [(0, "#1E1B4B", 1), (0.62, "#312E81", 1), (1, "#111827", 1)])),
                foreground: "#EDE9FE",
                stroke: "#818CF8",
                strokeWidth: 1.4,
                pressedFill: .solid(color("#4338CA")),
                shadow: "#000000",
                shadowAlpha: 0.36,
                shadowRadius: 10,
                shadowY: 6,
                glow: "#818CF8",
                glowAlpha: 0.28,
                glowRadius: 9,
                haptic: GamepadHapticFeedback(style: .light, pattern: .single, intensity: 0.36, sharpness: 0.30, duration: 0.045)
            )
        ]).normalized
    }

    private static func applyCavernGlowRole(
        to layout: inout GamepadButtonCustomization,
        button: KeypadElementID,
        label: String,
        controlKind: GamepadCustomControlKind
    ) {
        if controlKind == .joystick {
            layout.styleID = "cavern-stone"
            layout.shape = .circle
            layout.joystickKnobColor = color("#E0F2FE")
            layout.shadowStrength = max(layout.shadowStrength, 1.25)
            layout.visualStyle = nil
            return
        }

        if controlKind == .trigger || controlKind == .trackpad {
            layout.styleID = "cavern-rune"
            layout.shadowStrength = max(layout.shadowStrength, 1.10)
            layout.visualStyle = nil
            return
        }

        let normalizedLabel = normalizedLookup(label)
        switch button {
        case .preset(1), .preset(2), .preset(3), .preset(4):
            layout.styleID = "cavern-stone"
            layout.shape = .roundedRectangle
            layout.cornerRadius = layout.cornerRadius ?? 10
            layout.icon = movementIcon(for: button)
        case .preset(6):
            layout.styleID = "cavern-nail"
            layout.shape = .circle
            layout.icon = GamepadControlIcon(source: .sfSymbol, value: "slash.circle.fill", placement: .top, scale: 0.88)
        case .preset(8):
            layout.styleID = "cavern-soul"
            layout.shape = .circle
            layout.icon = GamepadControlIcon(source: .sfSymbol, value: "sparkles", placement: .top, scale: 0.92)
        case .preset(7):
            layout.styleID = "cavern-dash"
            layout.shape = .circle
            layout.icon = GamepadControlIcon(source: .sfSymbol, value: "wind", placement: .top, scale: 0.88)
        case .preset(5):
            layout.styleID = "cavern-jump"
            layout.shape = .circle
            layout.icon = GamepadControlIcon(source: .sfSymbol, value: "arrow.up.circle.fill", placement: .top, scale: 0.88)
        case .preset(9):
            layout.styleID = "cavern-parchment"
            layout.shape = .capsule
            layout.icon = GamepadControlIcon(source: .sfSymbol, value: "map.fill", placement: .leading, scale: 0.70)
        case .preset(10):
            layout.styleID = "cavern-rune"
            layout.shape = .capsule
            layout.icon = GamepadControlIcon(source: .sfSymbol, value: "pause.fill", placement: .leading, scale: 0.70)
        default:
            layout.icon = nil
            if normalizedLabel.contains("cast") || normalizedLabel.contains("soul") || normalizedLabel.contains("focus") {
                layout.styleID = "cavern-soul"
            } else if normalizedLabel.contains("dream") || normalizedLabel.contains("nail") {
                layout.styleID = "cavern-nail"
            } else if normalizedLabel.contains("dash") || normalizedLabel.contains("super") {
                layout.styleID = "cavern-dash"
            } else if normalizedLabel.contains("inventory") || normalizedLabel.contains("charm") || normalizedLabel.contains("map") {
                layout.styleID = "cavern-parchment"
            } else {
                layout.styleID = "cavern-rune"
            }
            if layout.shape == nil || layout.shape == .roundedRectangle { layout.shape = .capsule }
        }

        if layout.shadowStrength < 1.15 { layout.shadowStrength = 1.15 }
        layout.visualStyle = nil
        layout.hapticStyle = nil
        layout.hapticFeedback = nil
    }

    private static func movementIcon(for button: KeypadElementID) -> GamepadControlIcon? {
        switch button {
        case .preset(1): GamepadControlIcon.sfSymbol("chevron.up", placement: .center)
        case .preset(2): GamepadControlIcon.sfSymbol("chevron.down", placement: .center)
        case .preset(3): GamepadControlIcon.sfSymbol("chevron.left", placement: .center)
        case .preset(4): GamepadControlIcon.sfSymbol("chevron.right", placement: .center)
        default: nil
        }
    }

    private static func styleToken(
        id: String,
        name: String,
        fill: GamepadFillStyle,
        foreground: String,
        stroke: String,
        strokeWidth: CGFloat,
        pressedFill: GamepadFillStyle,
        pressedForeground: String? = nil,
        shadow: String,
        shadowAlpha: CGFloat,
        shadowRadius: CGFloat,
        shadowY: CGFloat,
        glow: String? = nil,
        glowAlpha: CGFloat = 0,
        glowRadius: CGFloat = 0,
        icon: GamepadControlIcon? = nil,
        haptic: GamepadHapticFeedback
    ) -> GamepadStyleToken {
        GamepadStyleToken(
            id: id,
            name: name,
            visualStyle: GamepadControlVisualStyle(
                normal: GamepadControlStateStyle(
                    fillStyle: fill,
                    foregroundColor: color(foreground),
                    strokeColor: color(stroke),
                    strokeWidth: strokeWidth,
                    shadowColor: color(shadow, alpha: shadowAlpha),
                    shadowRadius: shadowRadius,
                    shadowY: shadowY,
                    glowColor: glow.map { color($0, alpha: glowAlpha) },
                    glowRadius: glow == nil ? nil : glowRadius,
                    scale: 1
                ),
                pressed: GamepadControlStateStyle(
                    fillStyle: pressedFill,
                    foregroundColor: pressedForeground.map { color($0) },
                    shadowRadius: max(2, shadowRadius * 0.62),
                    shadowY: max(1, shadowY * 0.42),
                    glowRadius: glow == nil ? nil : glowRadius * 1.25,
                    scale: 0.94
                ),
                icon: icon,
                hapticFeedback: haptic
            )
        )
    }

    private static func gradient(angle: CGFloat, stops: [(CGFloat, String, CGFloat)]) -> GamepadGradientFill {
        GamepadGradientFill(
            type: .linear,
            angleDegrees: angle,
            stops: stops.map { GamepadGradientStop(offset: $0.0, color: color($0.1, alpha: $0.2)) }
        ).normalized
    }

    private static func color(_ hex: String, alpha: CGFloat? = nil) -> GamepadRGBAColor {
        var color = GamepadRGBAColor(hexString: hex) ?? .defaultValue
        if let alpha { color.alpha = alpha }
        return color.normalized
    }

    private static func normalizedLookup(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

extension GamepadCustomization {
    var allControlIdentitiesForDesign: [GamepadControlIdentity] {
        GamepadSystemControl.allCases.map { .system($0) }
            + elements.map { element in
                (element.kind == .button ? element.defaultControlID : nil).map { .builtin($0) } ?? .custom(element.id)
            }
    }

    var orderedControlIdentitiesForDesign: [GamepadControlIdentity] {
        let controls = allControlIdentitiesForDesign
        if let metadata = designMetadata?.normalized(availableControls: controls) {
            return metadata.layerOrder
        }
        return controls
    }

    var zOrderedControlIdentitiesForDesign: [GamepadControlIdentity] {
        let controls = allControlIdentitiesForDesign
        let baseOrder = designMetadata?.normalized(availableControls: controls)?.layerOrder ?? controls
        let orderLookup = Dictionary(uniqueKeysWithValues: baseOrder.enumerated().map { ($0.element, $0.offset) })
        var zIndexLookup: [GamepadControlIdentity: Int] = [:]
        zIndexLookup.reserveCapacity(controls.count)
        for button in DefaultKeypadElements.ids {
            zIndexLookup[.builtin(button)] = buttonCustomization(for: button).zIndex
        }
        for control in GamepadSystemControl.allCases {
            switch control {
            case .topBarActivation:
                zIndexLookup[.system(control)] = topBarActivationRegion.normalized.zIndex
            }
        }
        for customButton in customButtons {
            let normalizedButton = customButton.normalized
            zIndexLookup[.custom(normalizedButton.id)] = normalizedButton.layout.zIndex
        }
        return baseOrder.sorted { lhs, rhs in
            let lhsZIndex = zIndexLookup[lhs] ?? 0
            let rhsZIndex = zIndexLookup[rhs] ?? 0
            if lhsZIndex == rhsZIndex {
                let lhsIndex = orderLookup[lhs] ?? Int.max
                let rhsIndex = orderLookup[rhs] ?? Int.max
                if lhsIndex == rhsIndex { return lhs.id < rhs.id }
                return lhsIndex < rhsIndex
            }
            return lhsZIndex < rhsZIndex
        }
    }

    func zIndex(for identity: GamepadControlIdentity) -> Int {
        switch identity {
        case .builtin(let button):
            return buttonCustomization(for: button).zIndex
        case .custom(let id):
            return customButtons.first { $0.id == id }?.normalized.layout.zIndex ?? 0
        case .system(.topBarActivation):
            return topBarActivationRegion.normalized.zIndex
        case .controlBarItem:
            return 0
        }
    }

    func resolvedPresentation(
        for control: GamepadResolvedControl,
        state: GamepadControlPresentationState = .normal,
        scheme: ColorScheme
    ) -> GamepadResolvedControlPresentation {
        resolvedPresentation(
            for: control.layoutCustomization,
            fallbackAccentStyle: control.layoutCustomization.accentStyle ?? accentStyle,
            controlKind: control.controlKind,
            state: state,
            scheme: scheme
        )
    }

    func resolvedPresentation(
        for layout: GamepadButtonCustomization,
        fallbackAccentStyle: GamepadAccentStyle? = nil,
        controlKind: GamepadCustomControlKind = .button,
        state: GamepadControlPresentationState = .normal,
        scheme: ColorScheme
    ) -> GamepadResolvedControlPresentation {
        let isPressed = state.usesPressedFallback
        let accent = layout.accentStyle ?? fallbackAccentStyle ?? accentStyle
        let baselineFill = layout.buttonFillStyle(accentStyle: accent, isPressed: isPressed, scheme: scheme)
        let baselineForeground = GamepadRGBAColor(
            color: layout.buttonForeground(accentStyle: accent, isPressed: isPressed, scheme: scheme),
            fallback: baselineFill.representativeColor.contrastingForegroundRGBAColor()
        )
        let baselineStroke = GamepadRGBAColor(
            color: layout.buttonStroke(accentStyle: accent, isPressed: isPressed, scheme: scheme),
            fallback: baselineFill.representativeColor.strokeRGBAColor()
        )
        var presentation = GamepadResolvedControlPresentation(
            fillStyle: baselineFill,
            foregroundColor: baselineForeground,
            strokeColor: baselineStroke,
            strokeWidth: isPressed ? 2 : 1,
            shadowColor: GamepadRGBAColor(red: 0, green: 0, blue: 0, alpha: (isPressed ? 0.16 : 0.04) * layout.shadowStrength),
            shadowRadius: (isPressed ? 2 : 1) * max(0.25, layout.shadowStrength),
            shadowY: (isPressed ? 1 : 2) * layout.shadowStrength,
            opacity: state == .disabled ? 0.45 : 1,
            scale: isPressed ? 0.96 : 1,
            icon: layout.icon,
            hapticStyle: layout.hapticStyle ?? .light,
            hapticFeedback: layout.resolvedHapticFeedback
        )

        if let token = styleLibrary.style(id: layout.styleID), token.appliesTo.contains(controlKind) {
            presentation.apply(style: token.visualStyle, state: state)
        }
        if let inline = layout.visualStyle {
            presentation.apply(style: inline, state: state)
        }
        if let icon = layout.icon?.normalized { presentation.icon = icon }
        if let icon = presentation.content?.icon?.normalized { presentation.icon = icon }
        if let hapticFeedback = layout.hapticFeedback?.normalized {
            presentation.hapticFeedback = hapticFeedback
            presentation.hapticStyle = hapticFeedback.style
        } else if let hapticStyle = layout.hapticStyle {
            presentation.hapticFeedback = GamepadHapticFeedback(style: hapticStyle).normalized
            presentation.hapticStyle = hapticStyle
        }

        presentation.fillStyle = presentation.fillStyle.resolvingAssets(in: assetLibrary)
        return presentation
    }

    mutating func ensureLayerOrderContainsAllControls() {
        let controls = allControlIdentitiesForDesign
        var metadata = designMetadata ?? .empty
        metadata.layerOrder = (metadata.normalized(availableControls: controls)?.layerOrder ?? controls)
        designMetadata = metadata.normalized(availableControls: controls)
    }

    mutating func moveLayer(_ identity: GamepadControlIdentity, to index: Int) {
        moveLayers([identity], to: index)
    }

    mutating func moveLayers(_ identities: Set<GamepadControlIdentity>, to index: Int) {
        let controls = allControlIdentitiesForDesign
        let validIdentities = Set(identities.filter { controls.contains($0) })
        guard !validIdentities.isEmpty else { return }

        let currentOrder = designMetadata?.normalized(availableControls: controls)?.layerOrder ?? controls
        let moving = currentOrder.filter { validIdentities.contains($0) }
        guard !moving.isEmpty else { return }

        var remaining = currentOrder.filter { !validIdentities.contains($0) }
        let clampedIndex = min(max(0, index), remaining.count)
        remaining.insert(contentsOf: moving, at: clampedIndex)
        setLayerOrder(remaining)
    }

    mutating func bringLayerForward(_ identity: GamepadControlIdentity) {
        bringLayersForward([identity])
    }

    mutating func bringLayersForward(_ identities: Set<GamepadControlIdentity>) {
        let controls = allControlIdentitiesForDesign
        let validIdentities = Set(identities.filter { controls.contains($0) })
        guard !validIdentities.isEmpty else { return }

        let currentOrder = orderedControlIdentitiesForDesign
        guard let lastSelectedIndex = currentOrder.indices.last(where: { validIdentities.contains(currentOrder[$0]) }),
              let nextUnselectedIndex = currentOrder.indices.first(where: { $0 > lastSelectedIndex && !validIdentities.contains(currentOrder[$0]) })
        else { return }

        let moving = currentOrder.filter { validIdentities.contains($0) }
        var remaining = currentOrder.filter { !validIdentities.contains($0) }
        guard let nextIdentityIndex = remaining.firstIndex(of: currentOrder[nextUnselectedIndex]) else { return }
        remaining.insert(contentsOf: moving, at: min(nextIdentityIndex + 1, remaining.count))
        setLayerOrder(remaining)
    }

    mutating func sendLayerBackward(_ identity: GamepadControlIdentity) {
        sendLayersBackward([identity])
    }

    mutating func sendLayersBackward(_ identities: Set<GamepadControlIdentity>) {
        let controls = allControlIdentitiesForDesign
        let validIdentities = Set(identities.filter { controls.contains($0) })
        guard !validIdentities.isEmpty else { return }

        let currentOrder = orderedControlIdentitiesForDesign
        guard let firstSelectedIndex = currentOrder.indices.first(where: { validIdentities.contains(currentOrder[$0]) }),
              let previousUnselectedIndex = currentOrder.indices.reversed().first(where: { $0 < firstSelectedIndex && !validIdentities.contains(currentOrder[$0]) })
        else { return }

        let moving = currentOrder.filter { validIdentities.contains($0) }
        var remaining = currentOrder.filter { !validIdentities.contains($0) }
        guard let previousIdentityIndex = remaining.firstIndex(of: currentOrder[previousUnselectedIndex]) else { return }
        remaining.insert(contentsOf: moving, at: previousIdentityIndex)
        setLayerOrder(remaining)
    }

    mutating func bringLayerToFront(_ identity: GamepadControlIdentity) {
        bringLayersToFront([identity])
    }

    mutating func bringLayersToFront(_ identities: Set<GamepadControlIdentity>) {
        let controls = allControlIdentitiesForDesign
        let validIdentities = Set(identities.filter { controls.contains($0) })
        guard !validIdentities.isEmpty else { return }
        let currentOrder = orderedControlIdentitiesForDesign
        let moving = currentOrder.filter { validIdentities.contains($0) }
        guard !moving.isEmpty else { return }
        let remaining = currentOrder.filter { !validIdentities.contains($0) }
        setLayerOrder(remaining + moving)
    }

    mutating func sendLayerToBack(_ identity: GamepadControlIdentity) {
        sendLayersToBack([identity])
    }

    mutating func sendLayersToBack(_ identities: Set<GamepadControlIdentity>) {
        let controls = allControlIdentitiesForDesign
        let validIdentities = Set(identities.filter { controls.contains($0) })
        guard !validIdentities.isEmpty else { return }
        let currentOrder = orderedControlIdentitiesForDesign
        let moving = currentOrder.filter { validIdentities.contains($0) }
        guard !moving.isEmpty else { return }
        let remaining = currentOrder.filter { !validIdentities.contains($0) }
        setLayerOrder(moving + remaining)
    }

    private mutating func setLayerOrder(_ order: [GamepadControlIdentity]) {
        var metadata = designMetadata ?? .empty
        metadata.layerOrder = order
        designMetadata = metadata.normalized(availableControls: allControlIdentitiesForDesign)
    }
}

private extension GamepadResolvedControlPresentation {
    mutating func apply(style: GamepadControlVisualStyle, state: GamepadControlPresentationState) {
        let normalizedStyle = style.normalized ?? .empty
        let stateStyle = normalizedStyle.stateStyle(for: state).normalized
        if let content = stateStyle.content { self.content = content.merged(over: self.content) }
        if let fillStyle = stateStyle.fillStyle { self.fillStyle = fillStyle.normalized }
        if let foregroundColor = stateStyle.foregroundColor { self.foregroundColor = foregroundColor.normalized }
        if let strokeColor = stateStyle.strokeColor { self.strokeColor = strokeColor.normalized }
        if let strokeWidth = stateStyle.strokeWidth { self.strokeWidth = strokeWidth }
        if let shadowColor = stateStyle.shadowColor { self.shadowColor = shadowColor.normalized }
        if let shadowRadius = stateStyle.shadowRadius { self.shadowRadius = shadowRadius }
        if let shadowX = stateStyle.shadowX { self.shadowX = shadowX }
        if let shadowY = stateStyle.shadowY { self.shadowY = shadowY }
        if let shadows = stateStyle.shadows { self.shadows = Array(shadows.prefix(8)).map(\.normalized) }
        if let glowColor = stateStyle.glowColor { self.glowColor = glowColor.normalized }
        if let glowRadius = stateStyle.glowRadius { self.glowRadius = glowRadius }
        if let innerShadowColor = stateStyle.innerShadowColor {
            self.innerShadowColor = innerShadowColor.normalized
            if self.innerShadowRadius <= 0 { self.innerShadowRadius = 4 }
        }
        if let innerShadowRadius = stateStyle.innerShadowRadius { self.innerShadowRadius = innerShadowRadius }
        if let innerShadowX = stateStyle.innerShadowX { self.innerShadowX = innerShadowX }
        if let innerShadowY = stateStyle.innerShadowY { self.innerShadowY = innerShadowY }
        if let highlightColor = stateStyle.highlightColor {
            self.highlightColor = highlightColor.normalized
            if self.highlightOpacity <= 0 { self.highlightOpacity = 0.42 }
            if self.highlightRadius <= 0 { self.highlightRadius = 8 }
        }
        if let highlightRadius = stateStyle.highlightRadius { self.highlightRadius = highlightRadius }
        if let highlightX = stateStyle.highlightX { self.highlightX = highlightX }
        if let highlightY = stateStyle.highlightY { self.highlightY = highlightY }
        if let highlightOpacity = stateStyle.highlightOpacity { self.highlightOpacity = highlightOpacity }
        if let bevelHighlightColor = stateStyle.bevelHighlightColor {
            self.bevelHighlightColor = bevelHighlightColor.normalized
            if self.bevelWidth <= 0 { self.bevelWidth = 1 }
        }
        if let bevelShadowColor = stateStyle.bevelShadowColor {
            self.bevelShadowColor = bevelShadowColor.normalized
            if self.bevelWidth <= 0 { self.bevelWidth = 1 }
        }
        if let bevelWidth = stateStyle.bevelWidth { self.bevelWidth = bevelWidth }
        if let indexColor = stateStyle.indexColor { self.indexColor = indexColor.normalized }
        if let indexWidth = stateStyle.indexWidth { self.indexWidth = indexWidth }
        if let opacity = stateStyle.opacity { self.opacity = opacity }
        if let scale = stateStyle.scale { self.scale = scale }
        if let blurRadius = stateStyle.blurRadius { self.blurRadius = blurRadius }
        if let icon = normalizedStyle.icon?.normalized { self.icon = icon }
        if let hapticFeedback = normalizedStyle.hapticFeedback?.normalized {
            self.hapticFeedback = hapticFeedback
            self.hapticStyle = hapticFeedback.style
        } else if let hapticStyle = normalizedStyle.hapticStyle {
            self.hapticFeedback = GamepadHapticFeedback(style: hapticStyle).normalized
            self.hapticStyle = hapticStyle
        }
    }
}

extension GamepadRGBAColor {
    func contrastingForegroundRGBAColor(alpha: CGFloat = 1) -> GamepadRGBAColor {
        let normalized = normalized
        let luminance = 0.299 * normalized.red + 0.587 * normalized.green + 0.114 * normalized.blue
        if luminance > 0.56 {
            return GamepadRGBAColor(red: 0, green: 0, blue: 0, alpha: alpha).normalized
        }
        return GamepadRGBAColor(red: 1, green: 1, blue: 1, alpha: alpha).normalized
    }

    func strokeRGBAColor() -> GamepadRGBAColor {
        let normalized = normalized
        return GamepadRGBAColor(
            red: min(1, normalized.red * 0.76),
            green: min(1, normalized.green * 0.76),
            blue: min(1, normalized.blue * 0.76),
            alpha: min(1, max(0.32, normalized.alpha + 0.14))
        ).normalized
    }
}
