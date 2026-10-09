import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Vercel Geist tokens from https://vercel.com/design.md and
/// https://vercel.com/design.dark.md. Keep app styling grounded in these values.
enum Geist {
    enum ColorToken: Hashable {
        case primary, secondary, tertiary, neutral, background100, background200
        case gray100, gray200, gray300, gray400, gray500, gray600, gray700, gray800, gray900, gray1000
        case grayAlpha100, grayAlpha200, grayAlpha300, grayAlpha400, grayAlpha500, grayAlpha600, grayAlpha700, grayAlpha800, grayAlpha900, grayAlpha1000
        case blue100, blue200, blue300, blue400, blue500, blue600, blue700, blue800, blue900, blue1000
        case red100, red200, red300, red400, red500, red600, red700, red800, red900, red1000
        case amber100, amber200, amber300, amber400, amber500, amber600, amber700, amber800, amber900, amber1000
        case green100, green200, green300, green400, green500, green600, green700, green800, green900, green1000
        case teal100, teal200, teal300, teal400, teal500, teal600, teal700, teal800, teal900, teal1000
        case purple100, purple200, purple300, purple400, purple500, purple600, purple700, purple800, purple900, purple1000
        case pink100, pink200, pink300, pink400, pink500, pink600, pink700, pink800, pink900, pink1000
    }

    enum TypographyToken {
        case heading72, heading64, heading56, heading48, heading40, heading32, heading24, heading20, heading16, heading14
        case button16, button14, button12
        case label20, label18, label16, label14, label14Mono, label13, label13Mono, label12, label12Mono
        case copy24, copy20, copy18, copy16, copy14, copy14Mono, copy13, copy13Mono
    }

    enum ButtonVariant {
        case primary, secondary, tertiary, error
    }

    enum ControlSize {
        case small, medium, large

        var height: CGFloat {
            switch self {
            case .small: Spacing.s8
            case .medium: Spacing.s10
            case .large: 48
            }
        }

        var horizontalPadding: CGFloat {
            switch self {
            case .small: 6
            case .medium: 10
            case .large: 14
            }
        }

        var buttonTypography: TypographyToken {
            switch self {
            case .large: .button16
            case .small, .medium: .button14
            }
        }

        var inputTypography: TypographyToken {
            switch self {
            case .large: .label16
            case .small, .medium: .label14
            }
        }
    }

    enum Spacing {
        static let s1: CGFloat = 4
        static let s2: CGFloat = 8
        static let s3: CGFloat = 12
        static let s4: CGFloat = 16
        static let s6: CGFloat = 24
        static let s8: CGFloat = 32
        static let s10: CGFloat = 40
        static let s16: CGFloat = 64
        static let s24: CGFloat = 96
        static let base: CGFloat = 4
    }

    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let full: CGFloat = 9999
    }

    struct TextStyle {
        enum Family: String {
            case sans = "Geist Sans"
            case mono = "Geist Mono"
        }

        let family: Family
        let fontSize: CGFloat
        let weight: Font.Weight
        let lineHeight: CGFloat
        let letterSpacing: CGFloat

        var font: Font {
            #if os(macOS)
            if NSFont(name: family.rawValue, size: fontSize) != nil {
                return Font.custom(family.rawValue, size: fontSize, relativeTo: relativeTextStyle)
                    .weight(weight)
            }
            #elseif os(iOS)
            if UIFont(name: family.rawValue, size: fontSize) != nil {
                return Font.custom(family.rawValue, size: fontSize, relativeTo: relativeTextStyle)
                    .weight(weight)
            }
            #endif
            return Font.system(
                size: fontSize,
                weight: weight,
                design: family == .mono ? .monospaced : .default
            )
        }

        private var relativeTextStyle: Font.TextStyle {
            switch fontSize {
            case 40...:
                return .largeTitle
            case 28..<40:
                return .title
            case 22..<28:
                return .title2
            case 18..<22:
                return .title3
            case 16..<18:
                return .body
            case 14..<16:
                return .callout
            case 13..<14:
                return .footnote
            default:
                return .caption
            }
        }

        var lineSpacing: CGFloat {
            max(0, lineHeight - fontSize)
        }
    }

    static func rgba(_ token: ColorToken, scheme: ColorScheme) -> GamepadRGBAColor {
        GamepadRGBAColor(hexString: hex(for: token, scheme: scheme)) ?? .defaultValue
    }

    static func color(_ token: ColorToken, scheme: ColorScheme) -> Color {
        Color(geistHex: hex(for: token, scheme: scheme))
    }

    static func typography(_ token: TypographyToken) -> TextStyle {
        switch token {
        case .heading72: TextStyle(family: .sans, fontSize: 72, weight: .semibold, lineHeight: 72, letterSpacing: -4.32)
        case .heading64: TextStyle(family: .sans, fontSize: 64, weight: .semibold, lineHeight: 64, letterSpacing: -3.84)
        case .heading56: TextStyle(family: .sans, fontSize: 56, weight: .semibold, lineHeight: 56, letterSpacing: -3.36)
        case .heading48: TextStyle(family: .sans, fontSize: 48, weight: .semibold, lineHeight: 56, letterSpacing: -2.88)
        case .heading40: TextStyle(family: .sans, fontSize: 40, weight: .semibold, lineHeight: 48, letterSpacing: -2.4)
        case .heading32: TextStyle(family: .sans, fontSize: 32, weight: .semibold, lineHeight: 40, letterSpacing: -1.28)
        case .heading24: TextStyle(family: .sans, fontSize: 24, weight: .semibold, lineHeight: 32, letterSpacing: -0.96)
        case .heading20: TextStyle(family: .sans, fontSize: 20, weight: .semibold, lineHeight: 26, letterSpacing: -0.4)
        case .heading16: TextStyle(family: .sans, fontSize: 16, weight: .semibold, lineHeight: 24, letterSpacing: -0.32)
        case .heading14: TextStyle(family: .sans, fontSize: 14, weight: .semibold, lineHeight: 20, letterSpacing: -0.28)
        case .button16: TextStyle(family: .sans, fontSize: 16, weight: .medium, lineHeight: 20, letterSpacing: 0)
        case .button14: TextStyle(family: .sans, fontSize: 14, weight: .medium, lineHeight: 20, letterSpacing: 0)
        case .button12: TextStyle(family: .sans, fontSize: 12, weight: .medium, lineHeight: 16, letterSpacing: 0)
        case .label20: TextStyle(family: .sans, fontSize: 20, weight: .regular, lineHeight: 32, letterSpacing: 0)
        case .label18: TextStyle(family: .sans, fontSize: 18, weight: .regular, lineHeight: 20, letterSpacing: 0)
        case .label16: TextStyle(family: .sans, fontSize: 16, weight: .regular, lineHeight: 20, letterSpacing: 0)
        case .label14: TextStyle(family: .sans, fontSize: 14, weight: .regular, lineHeight: 20, letterSpacing: 0)
        case .label14Mono: TextStyle(family: .mono, fontSize: 14, weight: .regular, lineHeight: 20, letterSpacing: 0)
        case .label13: TextStyle(family: .sans, fontSize: 13, weight: .regular, lineHeight: 16, letterSpacing: 0)
        case .label13Mono: TextStyle(family: .mono, fontSize: 13, weight: .regular, lineHeight: 20, letterSpacing: 0)
        case .label12: TextStyle(family: .sans, fontSize: 12, weight: .regular, lineHeight: 16, letterSpacing: 0)
        case .label12Mono: TextStyle(family: .mono, fontSize: 12, weight: .regular, lineHeight: 16, letterSpacing: 0)
        case .copy24: TextStyle(family: .sans, fontSize: 24, weight: .regular, lineHeight: 36, letterSpacing: 0)
        case .copy20: TextStyle(family: .sans, fontSize: 20, weight: .regular, lineHeight: 36, letterSpacing: 0)
        case .copy18: TextStyle(family: .sans, fontSize: 18, weight: .regular, lineHeight: 28, letterSpacing: 0)
        case .copy16: TextStyle(family: .sans, fontSize: 16, weight: .regular, lineHeight: 24, letterSpacing: 0)
        case .copy14: TextStyle(family: .sans, fontSize: 14, weight: .regular, lineHeight: 20, letterSpacing: 0)
        case .copy14Mono: TextStyle(family: .mono, fontSize: 14, weight: .regular, lineHeight: 20, letterSpacing: 0)
        case .copy13: TextStyle(family: .sans, fontSize: 13, weight: .regular, lineHeight: 18, letterSpacing: 0)
        case .copy13Mono: TextStyle(family: .mono, fontSize: 13, weight: .regular, lineHeight: 18, letterSpacing: 0)
        }
    }

    private static func hex(for token: ColorToken, scheme: ColorScheme) -> String {
        switch scheme {
        case .dark:
            darkColors[token] ?? "#ededed"
        default:
            lightColors[token] ?? "#171717"
        }
    }

    private static let lightColors: [ColorToken: String] = [
        .primary: "#171717", .secondary: "#4d4d4d", .tertiary: "#006bff", .neutral: "#f2f2f2", .background100: "#ffffff", .background200: "#fafafa",
        .gray100: "#f2f2f2", .gray200: "#ebebeb", .gray300: "#e6e6e6", .gray400: "#eaeaea", .gray500: "#c9c9c9", .gray600: "#a8a8a8", .gray700: "#8f8f8f", .gray800: "#7d7d7d", .gray900: "#4d4d4d", .gray1000: "#171717",
        .grayAlpha100: "#0000000d", .grayAlpha200: "#00000015", .grayAlpha300: "#0000001a", .grayAlpha400: "#00000014", .grayAlpha500: "#00000036", .grayAlpha600: "#0000003d", .grayAlpha700: "#00000070", .grayAlpha800: "#00000082", .grayAlpha900: "#000000b3", .grayAlpha1000: "#000000e8",
        .blue100: "#f0f7ff", .blue200: "#e9f4ff", .blue300: "#dfefff", .blue400: "#cae7ff", .blue500: "#94ccff", .blue600: "#48aeff", .blue700: "#006bff", .blue800: "#0059ec", .blue900: "#005ff2", .blue1000: "#002359",
        .red100: "#ffeeef", .red200: "#ffe8ea", .red300: "#ffe3e4", .red400: "#ffd7d6", .red500: "#ffb1b3", .red600: "#ff676d", .red700: "#fc0035", .red800: "#ea001d", .red900: "#d8001b", .red1000: "#47000c",
        .amber100: "#fff6de", .amber200: "#fff4cf", .amber300: "#fff1c1", .amber400: "#ffdc73", .amber500: "#ffc543", .amber600: "#ffa600", .amber700: "#ffae00", .amber800: "#ff9300", .amber900: "#aa4d00", .amber1000: "#561900",
        .green100: "#ecfdec", .green200: "#e5fce7", .green300: "#d3fad1", .green400: "#b9f5bc", .green500: "#82eb8d", .green600: "#4ce15e", .green700: "#28a948", .green800: "#279141", .green900: "#107d32", .green1000: "#003a00",
        .teal100: "#defffb", .teal200: "#ddfef6", .teal300: "#ccf9f1", .teal400: "#b1f7ec", .teal500: "#52f0db", .teal600: "#00e3c4", .teal700: "#00ac96", .teal800: "#00927f", .teal900: "#007f70", .teal1000: "#003f34",
        .purple100: "#faf0ff", .purple200: "#f9f0ff", .purple300: "#f6e8ff", .purple400: "#f2d9ff", .purple500: "#dfa7ff", .purple600: "#c979ff", .purple700: "#a000f8", .purple800: "#8500d1", .purple900: "#7d00cc", .purple1000: "#2f004e",
        .pink100: "#ffe8f6", .pink200: "#ffe8f3", .pink300: "#ffdfeb", .pink400: "#ffd3e1", .pink500: "#fdb3cc", .pink600: "#f97ea7", .pink700: "#f22782", .pink800: "#e4106e", .pink900: "#c41562", .pink1000: "#460523"
    ]

    private static let darkColors: [ColorToken: String] = [
        .primary: "#ededed", .secondary: "#a0a0a0", .tertiary: "#006efe", .neutral: "#1a1a1a", .background100: "#000000", .background200: "#000000",
        .gray100: "#1a1a1a", .gray200: "#1f1f1f", .gray300: "#292929", .gray400: "#2e2e2e", .gray500: "#454545", .gray600: "#878787", .gray700: "#8f8f8f", .gray800: "#7d7d7d", .gray900: "#a0a0a0", .gray1000: "#ededed",
        .grayAlpha100: "#ffffff12", .grayAlpha200: "#ffffff17", .grayAlpha300: "#ffffff21", .grayAlpha400: "#ffffff24", .grayAlpha500: "#ffffff3d", .grayAlpha600: "#ffffff82", .grayAlpha700: "#ffffff8a", .grayAlpha800: "#ffffff78", .grayAlpha900: "#ffffff9c", .grayAlpha1000: "#ffffffeb",
        .blue100: "#06193a", .blue200: "#022248", .blue300: "#002f62", .blue400: "#003674", .blue500: "#00418b", .blue600: "#0090ff", .blue700: "#006efe", .blue800: "#005be7", .blue900: "#47a8ff", .blue1000: "#eaf6ff",
        .red100: "#330a11", .red200: "#440d13", .red300: "#5d0e17", .red400: "#6f101b", .red500: "#88151f", .red600: "#f32e40", .red700: "#f13242", .red800: "#e2162a", .red900: "#ff565f", .red1000: "#ffe9ed",
        .amber100: "#2a1700", .amber200: "#361900", .amber300: "#502800", .amber400: "#5b3000", .amber500: "#703e00", .amber600: "#ed9a00", .amber700: "#ffae00", .amber800: "#ff9300", .amber900: "#ff9300", .amber1000: "#fff3d5",
        .green100: "#002608", .green200: "#00320b", .green300: "#003a0e", .green400: "#004615", .green500: "#006717", .green600: "#00952d", .green700: "#00ac3a", .green800: "#009432", .green900: "#00ca50", .green1000: "#d8ffe4",
        .teal100: "#00231b", .teal200: "#002b22", .teal300: "#003d34", .teal400: "#004035", .teal500: "#006354", .teal600: "#009e86", .teal700: "#00aa95", .teal800: "#00927f", .teal900: "#00cfb7", .teal1000: "#cbfff5",
        .purple100: "#290c33", .purple200: "#341142", .purple300: "#47185e", .purple400: "#541a76", .purple500: "#642290", .purple600: "#9440d5", .purple700: "#9440d5", .purple800: "#7d2bba", .purple900: "#c472fb", .purple1000: "#fbecff",
        .pink100: "#310d1e", .pink200: "#420c25", .pink300: "#571032", .pink400: "#5d0c34", .pink500: "#76063f", .pink600: "#ba0056", .pink700: "#f12b82", .pink800: "#e7006d", .pink900: "#ff4d8d", .pink1000: "#ffe9f4"
    ]
}

enum GeistInterfaceTone {
    case neutral
    case success
    case warning
    case error
    case accent

    func foreground(scheme: ColorScheme) -> Color { foregroundRGBA(scheme: scheme).swiftUIColor }

    func foregroundRGBA(scheme: ColorScheme) -> GamepadRGBAColor {
        switch self {
        case .neutral: Geist.rgba(.gray900, scheme: scheme)
        case .success: Geist.rgba(.blue900, scheme: scheme)
        case .warning: Geist.rgba(.gray1000, scheme: scheme)
        case .error: Geist.rgba(.red900, scheme: scheme)
        case .accent: Geist.rgba(.blue900, scheme: scheme)
        }
    }

    func background(scheme: ColorScheme) -> Color { backgroundRGBA(scheme: scheme).swiftUIColor }

    func backgroundRGBA(scheme: ColorScheme) -> GamepadRGBAColor {
        switch self {
        case .neutral: Geist.rgba(.gray100, scheme: scheme)
        case .success: Geist.rgba(.blue100, scheme: scheme)
        case .warning: Geist.rgba(.gray100, scheme: scheme)
        case .error: Geist.rgba(.red100, scheme: scheme)
        case .accent: Geist.rgba(.blue100, scheme: scheme)
        }
    }

    func border(scheme: ColorScheme) -> Color { borderRGBA(scheme: scheme).swiftUIColor }

    func borderRGBA(scheme: ColorScheme) -> GamepadRGBAColor {
        switch self {
        case .neutral: Geist.rgba(.grayAlpha400, scheme: scheme)
        case .success: Geist.rgba(.blue400, scheme: scheme)
        case .warning: Geist.rgba(.grayAlpha600, scheme: scheme)
        case .error: Geist.rgba(.red400, scheme: scheme)
        case .accent: Geist.rgba(.blue400, scheme: scheme)
        }
    }
}

struct StatusPill: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let systemImage: String
    let tone: GeistInterfaceTone

    var body: some View {
        Label(title, systemImage: systemImage)
            .geistTypography(.label13)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .foregroundStyle(tone.foreground(scheme: colorScheme))
            .padding(.horizontal, Geist.Spacing.s3)
            .padding(.vertical, Geist.Spacing.s2)
            .background(tone.background(scheme: colorScheme), in: Capsule())
            .overlay(Capsule().stroke(tone.border(scheme: colorScheme), lineWidth: 1))
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
    }
}

struct GeistTypographyModifier: ViewModifier {
    let token: Geist.TypographyToken

    func body(content: Content) -> some View {
        let style = Geist.typography(token)
        content
            .font(style.font)
            .tracking(style.letterSpacing)
            .lineSpacing(style.lineSpacing)
    }
}

struct GeistButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    var variant: Geist.ButtonVariant = .primary
    var size: Geist.ControlSize = .medium

    func makeBody(configuration: Configuration) -> some View {
        let background = backgroundColor(isPressed: configuration.isPressed)
        let foreground = foregroundColor
        let border = borderColor(isPressed: configuration.isPressed)

        configuration.label
            .geistTypography(size.buttonTypography)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .foregroundStyle(foreground)
            .padding(.horizontal, size.horizontalPadding)
            .frame(minHeight: size.height)
            .background(
                RoundedRectangle(cornerRadius: Geist.Radius.sm, style: .continuous)
                    .fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Geist.Radius.sm, style: .continuous)
                    .stroke(border, lineWidth: borderWidth)
            )
            .contentShape(RoundedRectangle(cornerRadius: Geist.Radius.sm, style: .continuous))
            .geistButtonHapticFeedback(isPressed: configuration.isPressed)
    }

    private var foregroundColor: Color {
        guard isEnabled else { return Geist.color(.gray700, scheme: colorScheme) }

        switch variant {
        case .primary:
            return Geist.color(.background100, scheme: colorScheme)
        case .secondary, .tertiary:
            return Geist.color(.gray1000, scheme: colorScheme)
        case .error:
            return Color.white
        }
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        guard isEnabled else { return Geist.color(.gray100, scheme: colorScheme) }

        switch variant {
        case .primary:
            return isPressed ? Geist.color(.gray900, scheme: colorScheme) : Geist.color(.gray1000, scheme: colorScheme)
        case .secondary:
            return isPressed ? Geist.color(.grayAlpha200, scheme: colorScheme) : Geist.color(.background100, scheme: colorScheme)
        case .tertiary:
            return isPressed ? Geist.color(.grayAlpha200, scheme: colorScheme) : Color.clear
        case .error:
            return isPressed ? Geist.color(.red900, scheme: colorScheme) : Geist.color(.red800, scheme: colorScheme)
        }
    }

    private var borderWidth: CGFloat {
        switch variant {
        case .secondary:
            return 1
        case .primary, .tertiary, .error:
            return isEnabled ? 0 : 1
        }
    }

    private func borderColor(isPressed: Bool) -> Color {
        guard isEnabled else { return Geist.color(.grayAlpha400, scheme: colorScheme) }

        switch variant {
        case .secondary:
            return isPressed ? Geist.color(.grayAlpha600, scheme: colorScheme) : Geist.color(.grayAlpha400, scheme: colorScheme)
        case .primary, .tertiary, .error:
            return Color.clear
        }
    }
}

#if os(iOS)
private struct GeistButtonHapticFeedbackModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @State private var feedbackGenerator = UIImpactFeedbackGenerator(style: .light)

    let isPressed: Bool

    func body(content: Content) -> some View {
        content
            .onAppear {
                prepareIfNeeded()
            }
            .onChange(of: isEnabled) { _, newValue in
                if newValue {
                    prepareIfNeeded()
                }
            }
            .onChange(of: isPressed) { _, newValue in
                guard isEnabled else { return }

                if newValue {
                    feedbackGenerator.impactOccurred(intensity: 0.35)
                }
                prepareIfNeeded()
            }
    }

    private func prepareIfNeeded() {
        guard isEnabled else { return }
        feedbackGenerator.prepare()
    }
}
#endif

struct GeistInputModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var size: Geist.ControlSize = .medium

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .geistTypography(size.inputTypography)
            .foregroundStyle(Geist.color(.gray1000, scheme: colorScheme))
            .padding(.horizontal, 12)
            .frame(minHeight: size.height)
            .background(
                RoundedRectangle(cornerRadius: Geist.Radius.sm, style: .continuous)
                    .fill(Geist.color(.background100, scheme: colorScheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Geist.Radius.sm, style: .continuous)
                    .stroke(Geist.color(.grayAlpha400, scheme: colorScheme), lineWidth: 1)
            )
    }
}

struct GeistPanelModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var padding: CGFloat = Geist.Spacing.s6
    var radius: CGFloat = Geist.Radius.sm
    var raised: Bool = true

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Geist.color(.background100, scheme: colorScheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Geist.color(.grayAlpha400, scheme: colorScheme), lineWidth: 1)
            )
            .shadow(
                color: raised ? cardShadowColor : .clear,
                radius: raised ? cardShadowRadius : 0,
                x: 0,
                y: raised ? cardShadowY : 0
            )
    }

    private var cardShadowColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.16) : Color.black.opacity(0.04)
    }

    private var cardShadowRadius: CGFloat {
        colorScheme == .dark ? 2 : 2
    }

    private var cardShadowY: CGFloat {
        colorScheme == .dark ? 1 : 2
    }
}

struct GeistScreenBackgroundModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(Geist.color(.background100, scheme: colorScheme).ignoresSafeArea())
            .foregroundStyle(Geist.color(.gray1000, scheme: colorScheme))
    }
}

private extension View {
    @ViewBuilder
    func geistButtonHapticFeedback(isPressed: Bool) -> some View {
        #if os(iOS)
        modifier(GeistButtonHapticFeedbackModifier(isPressed: isPressed))
        #else
        self
        #endif
    }
}

extension View {
    func geistTypography(_ token: Geist.TypographyToken) -> some View {
        modifier(GeistTypographyModifier(token: token))
    }

    func geistButtonStyle(_ variant: Geist.ButtonVariant = .primary, size: Geist.ControlSize = .medium) -> some View {
        buttonStyle(GeistButtonStyle(variant: variant, size: size))
    }

    func geistInput(size: Geist.ControlSize = .medium) -> some View {
        modifier(GeistInputModifier(size: size))
    }

    func geistPanel(padding: CGFloat = Geist.Spacing.s6, radius: CGFloat = Geist.Radius.sm, raised: Bool = true) -> some View {
        modifier(GeistPanelModifier(padding: padding, radius: radius, raised: raised))
    }

    func geistScreenBackground() -> some View {
        modifier(GeistScreenBackgroundModifier())
    }
}

private extension Color {
    init(geistHex hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)

        let red: UInt64
        let green: UInt64
        let blue: UInt64
        let alpha: UInt64

        switch cleaned.count {
        case 8:
            red = (value >> 24) & 0xff
            green = (value >> 16) & 0xff
            blue = (value >> 8) & 0xff
            alpha = value & 0xff
        case 6:
            red = (value >> 16) & 0xff
            green = (value >> 8) & 0xff
            blue = value & 0xff
            alpha = 0xff
        default:
            red = 0
            green = 0
            blue = 0
            alpha = 0xff
        }

        self.init(
            .sRGB,
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255,
            opacity: Double(alpha) / 255
        )
    }
}
