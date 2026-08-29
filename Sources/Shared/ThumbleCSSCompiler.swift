import Foundation

/// CSS authoring support for Thumble skins (`thumble-css-core-1` profile).
///
/// The pipeline is: stylesheet text → tokenizer → parser → rule set, evaluated against a
/// virtual controller document derived from a canonical artboard, then lowered into the
/// existing native style model (`GamepadControlVisualStyle`, role/button/default rules,
/// orientation and color-scheme variants). No CSS reaches the runtime; packages contain
/// only the deterministic compiled result.
///
/// Supported language (profile `thumble-css-core-1`):
/// - Qualified rules with type (`controller`, `control`, `button`, `joystick`, `trigger`,
///   `trackpad`, `text`, `decoration`), ID (`#jump`), attribute (`[kind="button"]`,
///   `[role~="primary_action"]`, `[button="jump"]`), and `:root` selectors, plus the
///   descendant combinator.
/// - State pseudo-classes `:normal`, `:pressed`, `:active`, `:disabled`.
/// - Custom properties with inheritance from the controller root and `var()` fallbacks.
/// - `@media (prefers-color-scheme: …) and (orientation: …)` blocks.
/// - Paint properties: `background`, `background-color`, `background-image`,
///   `color`, `border`, `border-width`, `border-color`, `border-radius`,
///   `box-shadow` (including `inset`), `opacity`, `transform: scale()`,
///   `filter: blur()`, and the namespaced extensions `-thumble-glow-color`,
///   `-thumble-glow-radius`, `-thumble-knob-color`, and `-thumble-haptic-style`.
///
/// Everything else is a strict compile error rather than being silently ignored.
public enum ThumbleCSSProfile {
    public static let identifier = "thumble-css-core-1"

    public static let typeSelectors = [
        "controller", "control", "button", "joystick", "trigger", "trackpad", "text", "decoration"
    ]
    public static let statePseudoClasses = ["normal", "pressed", "active", "disabled"]
    public static let otherPseudoClasses = ["root"]
    public static let attributeNames = ["id", "kind", "role", "button"]
    public static let mediaFeatures = ["prefers-color-scheme", "orientation"]

    public static let properties = [
        "background", "background-color", "background-image", "color",
        "border", "border-width", "border-color", "border-radius",
        "box-shadow", "opacity", "transform", "filter",
        "-thumble-glow-color", "-thumble-glow-radius", "-thumble-knob-color", "-thumble-haptic-style"
    ]

    /// Hard resource limits keep stylesheets deterministic and compile-time bounded.
    public enum Limits {
        public static let maximumStylesheetBytes = 256 * 1024
        public static let maximumTokenCount = 60_000
        public static let maximumRuleCount = 2_048
        public static let maximumDeclarationCount = 128
        public static let maximumSelectorCount = 32
        public static let maximumCompoundParts = 8
        public static let maximumMediaDepth = 2
        public static let maximumCustomPropertyCount = 256
        public static let maximumVarSubstitutionDepth = 24
        public static let maximumGradientStops = 8
        public static let maximumShadowCount = 8
        public static let maximumStylesheetCount = 8
    }
}

// MARK: - Issues

public struct ThumbleCSSIssue: Codable, Equatable, Hashable, Sendable {
    public var severity: ThumbleSkinSourceIssueSeverity
    public var code: String
    public var message: String
    public var path: String?
    public var line: Int?
    public var column: Int?

    public init(
        severity: ThumbleSkinSourceIssueSeverity,
        code: String,
        message: String,
        path: String? = nil,
        line: Int? = nil,
        column: Int? = nil
    ) {
        self.severity = severity
        self.code = code
        self.message = message
        self.path = path
        self.line = line
        self.column = column
    }

    var sourceIssue: ThumbleSkinSourceIssue {
        ThumbleSkinSourceIssue(severity: severity, code: "css-\(code)", message: message, path: path)
    }
}

public struct ThumbleCSSReport: Codable, Equatable, Sendable {
    public var issues: [ThumbleCSSIssue]

    public init(issues: [ThumbleCSSIssue] = []) {
        self.issues = issues
    }

    public var errors: [ThumbleCSSIssue] { issues.filter { $0.severity == .error } }
    public var warnings: [ThumbleCSSIssue] { issues.filter { $0.severity == .warning } }
    public var isValid: Bool { errors.isEmpty }

    public var sourceReport: ThumbleSkinSourceValidationReport {
        ThumbleSkinSourceValidationReport(issues: issues.map(\.sourceIssue))
    }

    mutating func append(_ issue: ThumbleCSSIssue) { issues.append(issue) }
}

// MARK: - Tokenizer

struct ThumbleCSSToken: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case ident(String)
        case hash
        case number
        case dimension(unit: String)
        case percentage
        case function(String)
        case string(String)
        case delim(Character)
        case colon
        case semicolon
        case comma
        case lparen
        case rparen
        case lbracket
        case rbracket
        case lbrace
        case rbrace
        case atKeyword(String)
    }

    var kind: Kind
    var text: String
    var line: Int
    var column: Int

    var isEOF: Bool { text.isEmpty && kind == .delim("\0") }

    var description: String {
        switch kind {
        case .dimension(let unit): return "\(text)\(unit)"
        default: return text
        }
    }
}

struct ThumbleCSSTokenizeResult: Sendable {
    var tokens: [ThumbleCSSToken]
    var issues: [ThumbleCSSIssue]
}

enum ThumbleCSSTokenizer {
    static func tokenize(_ input: String, path: String?) -> ThumbleCSSTokenizeResult {
        var issues: [ThumbleCSSIssue] = []
        var tokens: [ThumbleCSSToken] = []
        tokens.reserveCapacity(min(input.count, ThumbleCSSProfile.Limits.maximumTokenCount))
        let scalars = Array(input.unicodeScalars)
        var index = 0
        var line = 1
        var column = 1

        func issue(_ code: String, _ message: String, at l: Int, _ c: Int) {
            issues.append(ThumbleCSSIssue(
                severity: .error,
                code: code,
                message: message,
                path: path,
                line: l,
                column: c
            ))
        }

        func advance() {
            if scalars[index] == "\n" {
                line += 1
                column = 1
            } else {
                column += 1
            }
            index += 1
        }

        func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
            scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" || scalar == "\u{c}"
        }

        func isIdentStart(_ scalar: Unicode.Scalar) -> Bool {
            CharacterSet.letters.contains(scalar) || scalar >= "\u{80}" || scalar == "_" || scalar == "-"
        }

        func isIdentScalar(_ scalar: Unicode.Scalar) -> Bool {
            isIdentStart(scalar) || CharacterSet.decimalDigits.contains(scalar)
        }

        func isDigit(_ scalar: Unicode.Scalar) -> Bool {
            CharacterSet.decimalDigits.contains(scalar)
        }

        while index < scalars.count {
            if tokens.count >= ThumbleCSSProfile.Limits.maximumTokenCount {
                issue("token-limit-exceeded", "Stylesheet exceeds the \(ThumbleCSSProfile.Limits.maximumTokenCount) token limit.", at: line, column)
                break
            }
            let scalar = scalars[index]
            if isWhitespace(scalar) {
                advance()
                continue
            }
            if scalar == "/" && index + 1 < scalars.count && scalars[index + 1] == "*" {
                let startLine = line
                let startColumn = column
                advance()
                advance()
                var terminated = false
                while index < scalars.count {
                    if scalars[index] == "*" && index + 1 < scalars.count && scalars[index + 1] == "/" {
                        advance()
                        advance()
                        terminated = true
                        break
                    }
                    advance()
                }
                if !terminated {
                    issue("unterminated-comment", "Unterminated CSS comment.", at: startLine, startColumn)
                }
                continue
            }
            if scalar == "\"" || scalar == "'" {
                let quote = scalar
                let startLine = line
                let startColumn = column
                advance()
                var value = ""
                var terminated = false
                while index < scalars.count {
                    let current = scalars[index]
                    if current == "\\" && index + 1 < scalars.count {
                        advance()
                        value.unicodeScalars.append(scalars[index])
                        advance()
                        continue
                    }
                    if current == quote {
                        advance()
                        terminated = true
                        break
                    }
                    if current == "\n" { break }
                    value.unicodeScalars.append(current)
                    advance()
                }
                if !terminated {
                    issue("unterminated-string", "Unterminated string literal.", at: startLine, startColumn)
                }
                tokens.append(ThumbleCSSToken(kind: .string(value), text: value, line: startLine, column: startColumn))
                continue
            }
            if scalar == "#" && index + 1 < scalars.count && isIdentScalar(scalars[index + 1]) {
                let startLine = line
                let startColumn = column
                advance()
                var value = "#"
                while index < scalars.count && isIdentScalar(scalars[index]) {
                    value.unicodeScalars.append(scalars[index])
                    advance()
                }
                tokens.append(ThumbleCSSToken(kind: .hash, text: value, line: startLine, column: startColumn))
                continue
            }
            if scalar == "@" && index + 1 < scalars.count && isIdentStart(scalars[index + 1]) {
                let startLine = line
                let startColumn = column
                advance()
                var value = "@"
                while index < scalars.count && isIdentScalar(scalars[index]) {
                    value.unicodeScalars.append(scalars[index])
                    advance()
                }
                tokens.append(ThumbleCSSToken(kind: .atKeyword(value), text: value, line: startLine, column: startColumn))
                continue
            }
            if isIdentStart(scalar) {
                let startLine = line
                let startColumn = column
                var value = ""
                while index < scalars.count && isIdentScalar(scalars[index]) {
                    value.unicodeScalars.append(scalars[index])
                    advance()
                }
                if index < scalars.count && scalars[index] == "(" {
                    advance()
                    tokens.append(ThumbleCSSToken(kind: .function(value), text: value, line: startLine, column: startColumn))
                } else {
                    tokens.append(ThumbleCSSToken(kind: .ident(value), text: value, line: startLine, column: startColumn))
                }
                continue
            }
            if isDigit(scalar) || (scalar == "." && index + 1 < scalars.count && isDigit(scalars[index + 1]))
                || ((scalar == "+" || scalar == "-")
                    && index + 1 < scalars.count
                    && (isDigit(scalars[index + 1])
                        || (scalars[index + 1] == "." && index + 2 < scalars.count && isDigit(scalars[index + 2])))) {
                let startLine = line
                let startColumn = column
                var value = ""
                var sawDigit = false
                var sawDot = false
                if scalar == "+" || scalar == "-" {
                    value.unicodeScalars.append(scalar)
                    advance()
                }
                while index < scalars.count {
                    let current = scalars[index]
                    if isDigit(current) {
                        sawDigit = true
                        value.unicodeScalars.append(current)
                        advance()
                    } else if current == "." && !sawDot {
                        sawDot = true
                        value.unicodeScalars.append(current)
                        advance()
                    } else if (current == "e" || current == "E"),
                              index + 1 < scalars.count,
                              (isDigit(scalars[index + 1])
                               || ((scalars[index + 1] == "+" || scalars[index + 1] == "-")
                                   && index + 2 < scalars.count
                                   && isDigit(scalars[index + 2]))) {
                        value.unicodeScalars.append(current)
                        advance()
                        if scalars[index] == "+" || scalars[index] == "-" {
                            value.unicodeScalars.append(scalars[index])
                            advance()
                        }
                    } else {
                        break
                    }
                }
                guard sawDigit else {
                    issue("invalid-number", "Malformed numeric value.", at: startLine, startColumn)
                    continue
                }
                if index < scalars.count && scalars[index] == "%" {
                    advance()
                    tokens.append(ThumbleCSSToken(kind: .percentage, text: value, line: startLine, column: startColumn))
                    continue
                }
                if index < scalars.count && isIdentStart(scalars[index]) {
                    var unit = ""
                    while index < scalars.count && isIdentScalar(scalars[index]) {
                        unit.unicodeScalars.append(scalars[index])
                        advance()
                    }
                    tokens.append(ThumbleCSSToken(kind: .dimension(unit: unit.lowercased()), text: value, line: startLine, column: startColumn))
                    continue
                }
                tokens.append(ThumbleCSSToken(kind: .number, text: value, line: startLine, column: startColumn))
                continue
            }
            let startLine = line
            let startColumn = column
            let kind: ThumbleCSSToken.Kind
            switch scalar {
            case ":": kind = .colon
            case ";": kind = .semicolon
            case ",": kind = .comma
            case "(": kind = .lparen
            case ")": kind = .rparen
            case "[": kind = .lbracket
            case "]": kind = .rbracket
            case "{": kind = .lbrace
            case "}": kind = .rbrace
            default: kind = .delim(Character(scalar))
            }
            advance()
            tokens.append(ThumbleCSSToken(kind: kind, text: String(Character(scalar)), line: startLine, column: startColumn))
        }
        return ThumbleCSSTokenizeResult(tokens: tokens, issues: issues)
    }
}

// MARK: - Selector and rule model

struct ThumbleCSSSimpleSelector: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case type(String)
        case id(String)
        case attribute(name: String, operation: String, value: String)
        case pseudoClass(String)
    }

    var kind: Kind
    var line: Int
    var column: Int
}

struct ThumbleCSSCompoundSelector: Sendable {
    var parts: [ThumbleCSSSimpleSelector]

    /// (ids, attribute/pseudo-class count, types)
    var specificity: (Int, Int, Int) {
        var ids = 0
        var attributes = 0
        var types = 0
        for part in parts {
            switch part.kind {
            case .id: ids += 1
            case .type: types += 1
            case .attribute, .pseudoClass: attributes += 1
            }
        }
        return (ids, attributes, types)
    }
}

struct ThumbleCSSComplexSelector: Sendable {
    /// Descendant chain; the last compound matches the element, earlier ones match ancestors.
    var compounds: [ThumbleCSSCompoundSelector]

    var specificity: (Int, Int, Int) {
        compounds.reduce((0, 0, 0)) { partial, compound in
            let specificity = compound.specificity
            return (partial.0 + specificity.0, partial.1 + specificity.1, partial.2 + specificity.2)
        }
    }
}

struct ThumbleCSSDeclaration: Sendable {
    var name: String
    var value: [ThumbleCSSToken]
    var important: Bool
    var line: Int
    var column: Int

    var valueText: String {
        var out = ""
        for token in value {
            let text: String
            let tight: Bool
            switch token.kind {
            case .function: text = "\(token.text)("; tight = false
            case .comma: text = ","; tight = true
            case .rparen, .rbracket, .rbrace: text = token.description; tight = true
            default: text = token.description; tight = false
            }
            if out.isEmpty {
                out = text
            } else if tight || out.hasSuffix("(") {
                out += text
            } else {
                out += " " + text
            }
        }
        return out
    }
}

struct ThumbleCSSQualifiedRule: Sendable {
    var selectors: [ThumbleCSSComplexSelector]
    var declarations: [ThumbleCSSDeclaration]
    var line: Int
    var column: Int
}

enum ThumbleCSSMediaFeature: Equatable, Sendable {
    case colorScheme(ThumbleSkinColorScheme)
    case orientation(ThumbleSkinOrientation)

    init?(name: String, value: String) {
        switch name {
        case "prefers-color-scheme":
            guard let scheme = ThumbleSkinColorScheme(rawValue: value.lowercased()) else { return nil }
            self = .colorScheme(scheme)
        case "orientation":
            guard let orientation = ThumbleSkinOrientation(rawValue: value.lowercased()) else { return nil }
            self = .orientation(orientation)
        default:
            return nil
        }
    }
}

struct ThumbleCSSMediaQuery: Sendable {
    var features: [ThumbleCSSMediaFeature]

    func matches(scheme: ThumbleSkinColorScheme?, orientation: ThumbleSkinOrientation?) -> Bool {
        for feature in features {
            switch feature {
            case .colorScheme(let required):
                guard let scheme, scheme == required else { return false }
            case .orientation(let required):
                guard let orientation, orientation == required else { return false }
            }
        }
        return true
    }
}

enum ThumbleCSSRule: Sendable {
    case qualified(ThumbleCSSQualifiedRule)
    case media(ThumbleCSSMediaQuery, [ThumbleCSSRule])
}

struct ThumbleCSSParsedStylesheet: Sendable {
    var rules: [ThumbleCSSRule]
}

// MARK: - Parser

final class ThumbleCSSParser {
    private let path: String?
    private var issues: [ThumbleCSSIssue] = []
    private var tokens: [ThumbleCSSToken] = []
    private var index = 0

    init(path: String?) {
        self.path = path
    }

    func parse(_ text: String) -> (stylesheet: ThumbleCSSParsedStylesheet, report: ThumbleCSSReport) {
        let bytes = text.utf8.count
        if bytes > ThumbleCSSProfile.Limits.maximumStylesheetBytes {
            issues.append(ThumbleCSSIssue(
                severity: .error,
                code: "stylesheet-too-large",
                message: "Stylesheet exceeds \(ThumbleCSSProfile.Limits.maximumStylesheetBytes) bytes.",
                path: path
            ))
            return (ThumbleCSSParsedStylesheet(rules: []), ThumbleCSSReport(issues: issues))
        }
        let tokenized = ThumbleCSSTokenizer.tokenize(text, path: path)
        issues.append(contentsOf: tokenized.issues)
        tokens = tokenized.tokens
        index = 0
        let rules = parseRules(mediaDepth: 0)
        if index < tokens.count {
            consumeBalancedJunk()
        }
        return (ThumbleCSSParsedStylesheet(rules: rules), ThumbleCSSReport(issues: issues))
    }

    // MARK: primitives

    private var current: ThumbleCSSToken? {
        index < tokens.count ? tokens[index] : nil
    }

    private func peek(ahead: Int) -> ThumbleCSSToken? {
        let target = index + ahead
        return target < tokens.count ? tokens[target] : nil
    }

    private func advance() -> ThumbleCSSToken? {
        guard let token = current else { return nil }
        index += 1
        return token
    }

    private func issue(_ severity: ThumbleSkinSourceIssueSeverity, _ code: String, _ message: String, _ token: ThumbleCSSToken?) {
        issues.append(ThumbleCSSIssue(
            severity: severity,
            code: code,
            message: message,
            path: path,
            line: token?.line,
            column: token?.column
        ))
    }

    private func consumeBalancedJunk() {
        var depth = 0
        while let token = current {
            switch token.kind {
            case .lbrace, .lparen, .lbracket: depth += 1
            case .rbrace, .rparen, .rbracket:
                depth -= 1
                if depth <= 0 {
                    _ = advance()
                    if depth == 0 { return }
                }
            default: break
            }
            _ = advance()
        }
    }

    // MARK: rules

    private func parseRules(mediaDepth: Int) -> [ThumbleCSSRule] {
        var rules: [ThumbleCSSRule] = []
        while let token = current {
            if rules.count >= ThumbleCSSProfile.Limits.maximumRuleCount {
                issue(.error, "rule-limit-exceeded", "Stylesheet exceeds \(ThumbleCSSProfile.Limits.maximumRuleCount) rules.", token)
                return rules
            }
            switch token.kind {
            case .rbrace:
                if mediaDepth > 0 { return rules }
                issue(.error, "unexpected-token", "Unexpected '}'.", token)
                _ = advance()
            case .atKeyword:
                rules.append(contentsOf: parseAtRule(mediaDepth: mediaDepth))
            default:
                if let rule = parseQualifiedRule() {
                    rules.append(.qualified(rule))
                }
            }
        }
        return rules
    }

    private func parseAtRule(mediaDepth: Int) -> [ThumbleCSSRule] {
        guard let atToken = advance() else { return [] }
        let name = atToken.text
        guard name == "@media" else {
            issue(.error, "unsupported-at-rule", "\(name) is not supported. Only @media is available.", atToken)
            skipAtRuleBody()
            return []
        }
        guard mediaDepth < ThumbleCSSProfile.Limits.maximumMediaDepth else {
            issue(.error, "media-nesting-limit", "@media nesting exceeds \(ThumbleCSSProfile.Limits.maximumMediaDepth) levels.", atToken)
            skipAtRuleBody()
            return []
        }
        var prelude: [ThumbleCSSToken] = []
        while let token = current, token.kind != .lbrace {
            if token.kind == .semicolon {
                issue(.error, "invalid-media", "@media requires a block.", token)
                _ = advance()
                return []
            }
            prelude.append(token)
            _ = advance()
        }
        guard let opening = current, opening.kind == .lbrace else {
            issue(.error, "invalid-media", "@media requires a block.", atToken)
            return []
        }
        _ = advance()
        guard let query = parseMediaQuery(prelude, start: atToken) else {
            skipBlockBody()
            return []
        }
        let nested = parseRules(mediaDepth: mediaDepth + 1)
        guard let closing = current, closing.kind == .rbrace else {
            issue(.error, "unterminated-block", "Unterminated @media block.", opening)
            return [.media(query, nested)]
        }
        _ = advance()
        return [.media(query, nested)]
    }

    private func parseMediaQuery(_ prelude: [ThumbleCSSToken], start: ThumbleCSSToken) -> ThumbleCSSMediaQuery? {
        guard !prelude.isEmpty else {
            issue(.error, "invalid-media", "@media requires at least one condition.", start)
            return nil
        }
        // Split the prelude into comma-separated queries; Thumble requires a single query.
        var commaCount = 0
        for token in prelude where token.kind == .comma { commaCount += 1 }
        if commaCount > 0 {
            issue(.error, "unsupported-media", "Comma-separated @media queries are not supported. Combine conditions with `and`.", prelude[0])
            return nil
        }
        var cursor = 0
        var features: [ThumbleCSSMediaFeature] = []
        func expectIdentifier() -> String? {
            guard cursor < prelude.count else { return nil }
            let token = prelude[cursor]
            if case .ident = token.kind {
                cursor += 1
                return token.text
            }
            return nil
        }
        var failed = false
        while cursor < prelude.count {
            let token = prelude[cursor]
            if case .ident("and") = token.kind {
                cursor += 1
                continue
            }
            if case .ident("only") = token.kind {
                cursor += 1
                continue
            }
            if case .ident("not") = token.kind {
                issue(.error, "unsupported-media", "`not` in @media is not supported.", token)
                failed = true
                break
            }
            guard case .lparen = token.kind else {
                issue(.error, "unsupported-media", "Unsupported @media syntax. Use (feature: value) conditions combined with `and`.", token)
                failed = true
                break
            }
            cursor += 1
            guard let name = expectIdentifier() else {
                issue(.error, "invalid-media", "Expected a media feature name.", token)
                failed = true
                break
            }
            guard cursor < prelude.count, prelude[cursor].kind == .colon else {
                issue(.error, "unsupported-media", "Range media features are not supported. Use (feature: value).", token)
                failed = true
                break
            }
            cursor += 1
            guard ThumbleCSSProfile.mediaFeatures.contains(name.lowercased()) else {
                issue(.error, "unsupported-media", "Media feature `\(name)` is not supported. Available: \(ThumbleCSSProfile.mediaFeatures.joined(separator: ", ")).", token)
                failed = true
                break
            }
            guard let value = expectIdentifier() else {
                issue(.error, "invalid-media", "Expected a media feature value.", token)
                failed = true
                break
            }
            guard cursor < prelude.count, prelude[cursor].kind == .rparen else {
                issue(.error, "invalid-media", "Unterminated media feature.", token)
                failed = true
                break
            }
            cursor += 1
            guard let feature = ThumbleCSSMediaFeature(name: name, value: value) else {
                issue(.error, "invalid-media", "Invalid value `\(value)` for media feature `\(name)`.", token)
                failed = true
                break
            }
            features.append(feature)
        }
        guard !failed, !features.isEmpty else { return nil }
        return ThumbleCSSMediaQuery(features: features)
    }

    private func skipAtRuleBody() {
        var depth = 0
        var sawBlock = false
        while let token = current {
            switch token.kind {
            case .semicolon where depth == 0 && !sawBlock:
                _ = advance()
                return
            case .lbrace:
                sawBlock = true
                depth += 1
            case .rbrace:
                depth -= 1
                if depth == 0 {
                    _ = advance()
                    return
                }
            default: break
            }
            _ = advance()
        }
    }

    private func skipBlockBody() {
        var depth = 1
        while let token = current {
            switch token.kind {
            case .lbrace, .lparen, .lbracket: depth += 1
            case .rbrace:
                depth -= 1
                if depth == 0 {
                    _ = advance()
                    return
                }
            case .rparen, .rbracket: depth = max(0, depth - 1)
            default: break
            }
            _ = advance()
        }
    }

    // MARK: qualified rules

    private func parseQualifiedRule() -> ThumbleCSSQualifiedRule? {
        let start = current
        var selectors: [ThumbleCSSComplexSelector] = []
        var malformed = false
        while let token = current, token.kind != .lbrace {
            if case .semicolon = token.kind {
                issue(.error, "unexpected-token", "Unexpected ';'.", token)
                _ = advance()
                return nil
            }
            guard let selector = parseComplexSelector() else {
                malformed = true
                break
            }
            selectors.append(selector)
            guard let next = current else { break }
            switch next.kind {
            case .comma:
                _ = advance()
            case .lbrace:
                continue
            default:
                continue
            }
        }
        if selectors.count > ThumbleCSSProfile.Limits.maximumSelectorCount {
            issue(.error, "selector-limit-exceeded", "Selector list exceeds \(ThumbleCSSProfile.Limits.maximumSelectorCount) selectors.", start)
            malformed = true
        }
        guard let opening = current, opening.kind == .lbrace else {
            issue(.error, "invalid-rule", "Expected '{' after selector.", start)
            if !malformed { skipAtRuleBody() }
            return nil
        }
        _ = advance()
        let declarations = parseDeclarations()
        guard let closing = current, closing.kind == .rbrace else {
            issue(.error, "unterminated-block", "Unterminated declaration block.", opening)
            return nil
        }
        _ = advance()
        guard !malformed, !selectors.isEmpty else { return nil }
        return ThumbleCSSQualifiedRule(
            selectors: selectors,
            declarations: declarations,
            line: opening.line,
            column: opening.column
        )
    }

    private func parseComplexSelector() -> ThumbleCSSComplexSelector? {
        var compounds: [ThumbleCSSCompoundSelector] = []
        while let token = current {
            switch token.kind {
            case .comma, .lbrace:
                guard !compounds.isEmpty else {
                    issue(.error, "invalid-selector", "Empty selector.", token)
                    skipSelector()
                    return nil
                }
                return ThumbleCSSComplexSelector(compounds: compounds)
            case .delim(">"), .delim("+"), .delim("~"):
                issue(.error, "unsupported-combinator", "Combinator `\(token.text)` is not supported. Only descendant selectors are available.", token)
                skipSelector()
                return nil
            case .delim("*"):
                issue(.error, "unsupported-selector", "Universal selectors are not supported.", token)
                skipSelector()
                return nil
            default:
                break
            }
            if compounds.count >= ThumbleCSSProfile.Limits.maximumCompoundParts {
                issue(.error, "selector-limit-exceeded", "Selector exceeds \(ThumbleCSSProfile.Limits.maximumCompoundParts) compound parts.", token)
                skipSelector()
                return nil
            }
            guard let compound = parseCompoundSelector() else {
                return nil
            }
            compounds.append(compound)
        }
        guard !compounds.isEmpty else { return nil }
        return ThumbleCSSComplexSelector(compounds: compounds)
    }

    private func skipSelector() {
        while let token = current {
            switch token.kind {
            case .comma, .lbrace: return
            default: _ = advance()
            }
        }
    }

    private func parseCompoundSelector() -> ThumbleCSSCompoundSelector? {
        var parts: [ThumbleCSSSimpleSelector] = []
        // A type selector must come first in a compound; a second ident starts a
        // descendant compound (whitespace was already dropped by the tokenizer).
        if let token = current, case .ident(let raw) = token.kind {
            let name = raw.lowercased()
            guard ThumbleCSSProfile.typeSelectors.contains(name) else {
                issue(.error, "unknown-type-selector", "Unknown type selector `\(raw)`. Available: \(ThumbleCSSProfile.typeSelectors.joined(separator: ", ")).", token)
                skipSelector()
                return nil
            }
            parts.append(ThumbleCSSSimpleSelector(kind: .type(name), line: token.line, column: token.column))
            _ = advance()
        }
        while let token = current {
            switch token.kind {
            case .ident:
                // Descendant boundary: the next compound begins here.
                return ThumbleCSSCompoundSelector(parts: parts)
            case .hash:
                parts.append(ThumbleCSSSimpleSelector(kind: .id(String(token.text.dropFirst())), line: token.line, column: token.column))
                _ = advance()
            case .delim("."):
                issue(.error, "unsupported-selector", "Class selectors are not supported; style controls with type, ID, or attribute selectors.", token)
                skipSelector()
                return nil
            case .colon:
                _ = advance()
                guard let pseudo = current else {
                    issue(.error, "invalid-selector", "Dangling ':'.", token)
                    return nil
                }
                if case .colon = pseudo.kind {
                    issue(.error, "unsupported-selector", "Pseudo-elements are not supported.", pseudo)
                    skipSelector()
                    return nil
                }
                guard case .ident(let name) = pseudo.kind else {
                    issue(.error, "invalid-selector", "Expected a pseudo-class name.", pseudo)
                    skipSelector()
                    return nil
                }
                let lowered = name.lowercased()
                let known = ThumbleCSSProfile.statePseudoClasses.contains(lowered)
                    || ThumbleCSSProfile.otherPseudoClasses.contains(lowered)
                guard known else {
                    issue(.error, "unsupported-pseudo-class", "Pseudo-class `:\(name)` is not supported. Available: \(ThumbleCSSProfile.statePseudoClasses.map { ":" + $0 }.joined(separator: ", ")) and :root.", pseudo)
                    skipSelector()
                    return nil
                }
                parts.append(ThumbleCSSSimpleSelector(kind: .pseudoClass(lowered), line: pseudo.line, column: pseudo.column))
                _ = advance()
            case .lbracket:
                guard let part = parseAttributeSelector() else { return nil }
                parts.append(part)
            case .function:
                issue(.error, "unsupported-selector", "Functional pseudo-classes are not supported.", token)
                skipSelector()
                return nil
            default:
                if parts.isEmpty {
                    issue(.error, "invalid-selector", "Unexpected `\(token.text)` in selector.", token)
                    skipSelector()
                    return nil
                }
                return ThumbleCSSCompoundSelector(parts: parts)
            }
        }
        guard !parts.isEmpty else {
            if let token = current, token.kind != .comma, token.kind != .lbrace {
                issue(.error, "invalid-selector", "Selector expected.", token)
            }
            return nil
        }
        return ThumbleCSSCompoundSelector(parts: parts)
    }

    private func parseAttributeSelector() -> ThumbleCSSSimpleSelector? {
        guard let opening = advance() else { return nil }
        guard let nameToken = current, case .ident(let rawName) = nameToken.kind else {
            issue(.error, "invalid-selector", "Expected an attribute name.", opening)
            skipSelector()
            return nil
        }
        _ = advance()
        let name = rawName.lowercased()
        guard ThumbleCSSProfile.attributeNames.contains(name) else {
            issue(.error, "unknown-attribute", "Attribute `\(rawName)` is not supported. Available: \(ThumbleCSSProfile.attributeNames.joined(separator: ", ")).", nameToken)
            skipSelector()
            return nil
        }
        guard let next = current else {
            issue(.error, "invalid-selector", "Unterminated attribute selector.", opening)
            return nil
        }
        if case .rbracket = next.kind {
            issue(.error, "invalid-selector", "Bare attribute selectors are not supported; use [\(name)=\"value\"].", next)
            skipSelector()
            return nil
        }
        guard case .delim(let operation) = next.kind,
              operation == "=" || operation == "~" else {
            issue(.error, "unsupported-attribute-operator", "Only `=` and `~=` attribute operators are supported.", next)
            skipSelector()
            return nil
        }
        _ = advance()
        guard let valueToken = current else {
            issue(.error, "invalid-selector", "Expected an attribute value.", opening)
            return nil
        }
        let value: String
        switch valueToken.kind {
        case .ident(let text): value = text
        case .string(let text): value = text
        default:
            issue(.error, "invalid-selector", "Attribute values must be identifiers or strings.", valueToken)
            skipSelector()
            return nil
        }
        _ = advance()
        guard let closing = current, closing.kind == .rbracket else {
            issue(.error, "invalid-selector", "Unterminated attribute selector.", opening)
            skipSelector()
            return nil
        }
        _ = advance()
        return ThumbleCSSSimpleSelector(
            kind: .attribute(name: name, operation: String(operation), value: value),
            line: opening.line,
            column: opening.column
        )
    }

    private func parseDeclarations() -> [ThumbleCSSDeclaration] {
        var declarations: [ThumbleCSSDeclaration] = []
        while let token = current {
            guard token.kind != .rbrace else { break }
            guard case .ident(let name) = token.kind else {
                issue(.error, "invalid-declaration", "Expected a property name.", token)
                skipDeclaration()
                continue
            }
            _ = advance()
            guard let colon = current, colon.kind == .colon else {
                issue(.error, "invalid-declaration", "Expected ':' after property `\(name)`.", token)
                skipDeclaration()
                continue
            }
            _ = advance()
            var value: [ThumbleCSSToken] = []
            var important = false
            var depth = 0
            valueLoop: while let valueToken = current {
                switch valueToken.kind {
                case .lparen, .lbracket:
                    depth += 1
                    value.append(valueToken)
                    _ = advance()
                case .rparen, .rbracket:
                    depth = max(0, depth - 1)
                    value.append(valueToken)
                    _ = advance()
                case .lbrace:
                    issue(.error, "invalid-declaration", "Unexpected '{' in value of `\(name)`.", valueToken)
                    return declarations
                case .semicolon where depth == 0:
                    _ = advance()
                    if important {
                        while case .delim("!")? = value.last?.kind { value.removeLast() }
                    }
                    appendDeclaration(&declarations, name: name, value: value, important: important, token: token)
                    break valueLoop
                case .rbrace where depth == 0:
                    if important {
                        while case .delim("!")? = value.last?.kind { value.removeLast() }
                    }
                    appendDeclaration(&declarations, name: name, value: value, important: important, token: token)
                    break valueLoop
                case .ident("important") where depth == 0
                    && value.last?.kind == .delim("!"):
                    important = true
                    _ = advance()
                default:
                    value.append(valueToken)
                    _ = advance()
                }
            }
        }
        return declarations
    }

    private func appendDeclaration(
        _ declarations: inout [ThumbleCSSDeclaration],
        name: String,
        value: [ThumbleCSSToken],
        important: Bool,
        token: ThumbleCSSToken
    ) {
        if declarations.count >= ThumbleCSSProfile.Limits.maximumDeclarationCount {
            issue(.error, "declaration-limit-exceeded", "Rule exceeds \(ThumbleCSSProfile.Limits.maximumDeclarationCount) declarations.", token)
            return
        }
        if important {
            issue(.error, "important-unsupported", "!important is not supported.", token)
        }
        let isCustomProperty = name.hasPrefix("--")
        if !isCustomProperty, !ThumbleCSSProfile.properties.contains(name.lowercased()) {
            issue(.error, "unsupported-property", "Property `\(name)` is not supported by profile \(ThumbleCSSProfile.identifier). Run `thumble skin css capabilities` for the supported set.", token)
        }
        declarations.append(ThumbleCSSDeclaration(
            name: isCustomProperty ? name : name.lowercased(),
            value: value,
            important: important,
            line: token.line,
            column: token.column
        ))
    }

    private func skipDeclaration() {
        var depth = 0
        while let token = current {
            switch token.kind {
            case .lparen, .lbracket, .lbrace: depth += 1
            case .rparen, .rbracket: depth = max(0, depth - 1)
            case .rbrace where depth == 0: return
            case .semicolon where depth == 0:
                _ = advance()
                return
            default: break
            }
            _ = advance()
        }
    }
}

// MARK: - Virtual controller document

public struct ThumbleCSSControlElement: Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var kind: GamepadCustomControlKind
    public var role: GamepadVisualRole
    public var button: GameButton

    public init(id: String, label: String, kind: GamepadCustomControlKind, role: GamepadVisualRole, button: GameButton) {
        self.id = id
        self.label = label
        self.kind = kind
        self.role = role
        self.button = button
    }

    /// Synthesized control used to compute role-level and default styles.
    public static func synthetic(kind: GamepadCustomControlKind?, role: GamepadVisualRole?, button: GameButton?) -> ThumbleCSSControlElement {
        ThumbleCSSControlElement(
            id: "",
            label: "",
            kind: kind ?? .button,
            role: role ?? .custom,
            button: button ?? .custom1
        )
    }

    var isSynthetic: Bool { id.isEmpty }
}

struct ThumbleCSSDocumentElement: Sendable {
    var control: ThumbleCSSControlElement?
    var isRoot: Bool { control == nil }
}

struct ThumbleCSSDocument: Sendable {
    var orientation: ThumbleSkinOrientation
    var controls: [ThumbleCSSControlElement]

    var elements: [ThumbleCSSDocumentElement] {
        [ThumbleCSSDocumentElement(control: nil)] + controls.map { ThumbleCSSDocumentElement(control: $0) }
    }
}

enum ThumbleCSSDocumentBuilder {
    /// Stable, CSS-friendly element IDs: `builtin.leftShoulder` → `builtin-left-shoulder`.
    static func kebabIdentifier(_ value: String) -> String {
        var result = ""
        var previousWasBoundary = true
        for character in value {
            if character.isUppercase {
                if !result.isEmpty, !previousWasBoundary { result.append("-") }
                result.append(Character(character.lowercased()))
                previousWasBoundary = false
            } else if character.isLetter || character.isNumber {
                result.append(character)
                previousWasBoundary = false
            } else {
                if !result.isEmpty, !previousWasBoundary { result.append("-") }
                previousWasBoundary = true
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    static func documents(for artboard: ThumbleSkinArtboard, orientations: [ThumbleSkinOrientation]) -> [ThumbleCSSDocument] {
        orientations.compactMap { orientation in
            guard let variant = artboard.variants.first(where: { $0.orientation == orientation }) else { return nil }
            let controls = variant.controls.map { control in
                ThumbleCSSControlElement(
                    id: kebabIdentifier(control.id),
                    label: control.label,
                    kind: control.kind,
                    role: control.visualRole,
                    button: control.mappedButton
                )
            }
            return ThumbleCSSDocument(orientation: orientation, controls: controls)
        }
    }
}

// MARK: - Selector matching

struct ThumbleCSSMatchingContext {
    var state: GamepadControlPresentationState
}

enum ThumbleCSSSelectorMatcher {
    static func matches(
        _ selector: ThumbleCSSComplexSelector,
        element: ThumbleCSSDocumentElement,
        document: ThumbleCSSDocument,
        context: ThumbleCSSMatchingContext
    ) -> Bool {
        guard matches(selector.compounds.last!, element: element, context: context) else { return false }
        guard selector.compounds.count > 1 else { return true }
        // Every ancestor in this two-level document is the controller root.
        let root = ThumbleCSSDocumentElement(control: nil)
        for compound in selector.compounds.dropLast() {
            guard matches(compound, element: root, context: context) else { return false }
        }
        _ = document
        return true
    }

    static func matches(
        _ compound: ThumbleCSSCompoundSelector,
        element: ThumbleCSSDocumentElement,
        context: ThumbleCSSMatchingContext
    ) -> Bool {
        for part in compound.parts {
            switch part.kind {
            case .type(let name):
                if name == "controller" {
                    guard element.isRoot else { return false }
                } else {
                    guard let control = element.control else { return false }
                    if name == "control" {
                        // matches every control
                    } else if control.kind.rawValue.lowercased() != name, kebab(control.kind.rawValue) != name {
                        return false
                    }
                }
            case .id(let identifier):
                guard let control = element.control, control.id == identifier.lowercased() else { return false }
            case .attribute(let name, let operation, let rawValue):
                let value = rawValue.lowercased()
                let actual: String
                switch name {
                case "id":
                    guard let control = element.control else { return false }
                    if control.isSynthetic { return false }
                    actual = control.id
                case "kind":
                    guard let control = element.control else { return false }
                    actual = control.kind.rawValue
                case "role":
                    if element.isRoot { return false }
                    actual = element.control?.role.rawValue ?? ""
                case "button":
                    guard let control = element.control else { return false }
                    actual = control.button.rawValue
                default:
                    return false
                }
                let normalizedActual = kebab(actual)
                let matchesValue: Bool
                switch operation {
                case "~":
                    matchesValue = actual.lowercased().split(separator: "_")
                        .map { kebab(String($0)) }
                        .contains(value)
                        || normalizedActual.split(separator: "-").map(String.init).contains(value)
                        || kebab(actual) == value
                        || actual.lowercased() == value
                default:
                    matchesValue = actual.lowercased() == value || normalizedActual == value
                }
                guard matchesValue else { return false }
            case .pseudoClass(let name):
                switch name {
                case "root":
                    guard element.isRoot else { return false }
                case "normal":
                    guard context.state == .normal else { return false }
                case "pressed":
                    guard context.state == .pressed else { return false }
                case "active":
                    guard context.state == .active else { return false }
                case "disabled":
                    guard context.state == .disabled else { return false }
                default:
                    return false
                }
            }
        }
        return true
    }

    private static func kebab(_ value: String) -> String {
        ThumbleCSSDocumentBuilder.kebabIdentifier(value)
    }
}

// MARK: - Cascade engine

struct ThumbleCSSCascadedDeclaration: Sendable {
    var name: String
    var value: [ThumbleCSSToken]
    var specificity: (Int, Int, Int)
    var order: Int
}

final class ThumbleCSSCascade {
    private let flattened: [(query: ThumbleCSSMediaQuery?, rule: ThumbleCSSQualifiedRule, order: Int)]
    private var issues: [ThumbleCSSIssue] = []

    init(rules: [ThumbleCSSRule]) {
        var flattened: [(ThumbleCSSMediaQuery?, ThumbleCSSQualifiedRule, Int)] = []
        var order = 0
        func walk(_ rules: [ThumbleCSSRule], query: ThumbleCSSMediaQuery?) {
            for rule in rules {
                switch rule {
                case .qualified(let qualified):
                    flattened.append((query, qualified, order))
                    order += 1
                case .media(let innerQuery, let nested):
                    let merged: ThumbleCSSMediaQuery
                    if let query {
                        merged = ThumbleCSSMediaQuery(features: query.features + innerQuery.features)
                    } else {
                        merged = innerQuery
                    }
                    walk(nested, query: merged)
                }
            }
        }
        walk(rules, query: nil)
        self.flattened = flattened
    }

    var report: ThumbleCSSReport { ThumbleCSSReport(issues: issues) }

    /// Selector-match diagnostics across every element and state.
    func reportUnmatchedSelectors(documents: [ThumbleCSSDocument]) {
        var matched = Set<String>()
        var seen = Set<String>()
        for (query, rule, order) in flattened {
            for selector in rule.selectors {
                let key = selector.key
                guard seen.insert(key).inserted else { continue }
                _ = query
                _ = order
                for document in documents {
                    let anyMatch = document.elements.contains { element in
                        GamepadControlPresentationState.allCases.contains { state in
                            ThumbleCSSSelectorMatcher.matches(
                                selector,
                                element: element,
                                document: document,
                                context: ThumbleCSSMatchingContext(state: state)
                            )
                        }
                    }
                    if anyMatch {
                        matched.insert(key)
                        break
                    }
                }
            }
        }
        for (query, rule, _) in flattened {
            guard let first = rule.selectors.first else { continue }
            for selector in rule.selectors where !matched.contains(selector.key) {
                _ = first
                _ = query
                issues.append(ThumbleCSSIssue(
                    severity: .warning,
                    code: "selector-matches-nothing",
                    message: "Selector `\(selector.text)` does not match any control on the artboard.",
                    line: rule.line,
                    column: rule.column
                ))
                break
            }
        }
    }



    /// Raw computed declarations (pre-lowering) including custom properties, for tooling.
    func resolvedDeclarations(
        element: ThumbleCSSDocumentElement,
        state: GamepadControlPresentationState,
        document: ThumbleCSSDocument,
        scheme: ThumbleSkinColorScheme?,
        orientation: ThumbleSkinOrientation?
    ) -> [ThumbleCSSDeclaration] {
        var rootCustom: [String: [ThumbleCSSToken]] = [:]
        var ownCustom: [String: [ThumbleCSSToken]] = [:]
        var applied: [String: ThumbleCSSCascadedDeclaration] = [:]
        let root = ThumbleCSSDocumentElement(control: nil)

        for (query, rule, order) in flattened {
            guard query?.matches(scheme: scheme, orientation: orientation) ?? true else { continue }
            for selector in rule.selectors {
                let matchesElement = ThumbleCSSSelectorMatcher.matches(
                    selector, element: element, document: document,
                    context: ThumbleCSSMatchingContext(state: state)
                )
                let matchesRoot = !element.isRoot && ThumbleCSSSelectorMatcher.matches(
                    selector, element: root, document: document,
                    context: ThumbleCSSMatchingContext(state: state)
                )
                guard matchesElement || matchesRoot else { continue }
                let specificity = selector.specificity
                for declaration in rule.declarations {
                    if declaration.name.hasPrefix("--") {
                        if matchesElement, !element.isRoot {
                            ownCustom[declaration.name] = declaration.value
                        } else {
                            rootCustom[declaration.name] = declaration.value
                        }
                    } else if matchesElement {
                        let candidate = ThumbleCSSCascadedDeclaration(
                            name: declaration.name,
                            value: declaration.value,
                            specificity: specificity,
                            order: order
                        )
                        if let existing = applied[declaration.name],
                           (candidate.specificity.0, candidate.specificity.1, candidate.specificity.2, candidate.order)
                            < (existing.specificity.0, existing.specificity.1, existing.specificity.2, existing.order) {
                            continue
                        }
                        applied[declaration.name] = candidate
                    } else if declaration.name == "color" {
                        // `color` is inherited from the controller root in CSS.
                        applied[declaration.name] = ThumbleCSSCascadedDeclaration(
                            name: declaration.name,
                            value: declaration.value,
                            specificity: specificity,
                            order: order
                        )
                    }
                }
            }
        }

        var environment = rootCustom
        for (name, value) in ownCustom { environment[name] = value }
        var declarations: [ThumbleCSSDeclaration] = []
        for name in environment.keys.sorted() {
            let resolved = resolveVarReferences(environment[name] ?? [], environment: environment, stack: [name])
            declarations.append(ThumbleCSSDeclaration(name: name, value: resolved, important: false, line: 0, column: 0))
        }
        for name in applied.keys.sorted() {
            let resolved = resolveVarReferences(applied[name]!.value, environment: environment, stack: [name])
            declarations.append(ThumbleCSSDeclaration(
                name: name,
                value: resolved,
                important: false,
                line: applied[name]!.order,
                column: 0
            ))
        }
        return declarations
    }

    private func resolveVarReferences(
        _ tokens: [ThumbleCSSToken],
        environment: [String: [ThumbleCSSToken]],
        stack: [String]
    ) -> [ThumbleCSSToken] {
        guard !tokens.isEmpty else { return tokens }
        var output: [ThumbleCSSToken] = []
        output.reserveCapacity(tokens.count)
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if case .function("var") = token.kind {
                var depth = 1
                var argument: [ThumbleCSSToken] = []
                var cursor = index + 1
                var closed = false
                while cursor < tokens.count {
                    let current = tokens[cursor]
                    switch current.kind {
                    case .function:
                        depth += 1
                        argument.append(current)
                    case .lparen:
                        depth += 1
                        argument.append(current)
                    case .rparen:
                        depth -= 1
                        if depth == 0 {
                            closed = true
                        } else {
                            argument.append(current)
                        }
                    case .comma where depth == 1:
                        argument.append(current)
                    default:
                        argument.append(current)
                    }
                    if closed { cursor += 1; break }
                    cursor += 1
                }
                index = cursor
                guard closed else {
                    issues.append(ThumbleCSSIssue(
                        severity: .error,
                        code: "invalid-var",
                        message: "Unterminated var() reference.",
                        line: token.line,
                        column: token.column
                    ))
                    continue
                }
                // Split name/fallback at the first top-level comma.
                var nameTokens: [ThumbleCSSToken] = []
                var fallbackTokens: [ThumbleCSSToken] = []
                var splitDepth = 0
                var pastComma = false
                for argumentToken in argument {
                    switch argumentToken.kind {
                    case .lparen, .lbracket, .lbrace: splitDepth += 1
                    case .rparen, .rbracket, .rbrace: splitDepth = max(0, splitDepth - 1)
                    case .comma where splitDepth == 0: pastComma = true
                    default: break
                    }
                    if pastComma, argumentToken.kind != .comma || splitDepth > 0 {
                        fallbackTokens.append(argumentToken)
                    } else if !pastComma {
                        nameTokens.append(argumentToken)
                    }
                }
                guard let nameToken = nameTokens.first, case .ident(let name) = nameToken.kind else {
                    issues.append(ThumbleCSSIssue(
                        severity: .error,
                        code: "invalid-var",
                        message: "var() requires a custom property name.",
                        line: token.line,
                        column: token.column
                    ))
                    continue
                }
                guard name.hasPrefix("--") else {
                    issues.append(ThumbleCSSIssue(
                        severity: .error,
                        code: "invalid-var",
                        message: "var() names must start with `--`.",
                        line: token.line,
                        column: token.column
                    ))
                    continue
                }
                if let value = environment[name] {
                    if stack.contains(name) {
                        issues.append(ThumbleCSSIssue(
                            severity: .error,
                            code: "custom-property-cycle",
                            message: "Custom property `\(name)` references itself.",
                            line: token.line,
                            column: token.column
                        ))
                        continue
                    }
                    if stack.count >= ThumbleCSSProfile.Limits.maximumVarSubstitutionDepth {
                        issues.append(ThumbleCSSIssue(
                            severity: .error,
                            code: "var-depth-limit",
                            message: "var() substitution exceeds \(ThumbleCSSProfile.Limits.maximumVarSubstitutionDepth) levels.",
                            line: token.line,
                            column: token.column
                        ))
                        continue
                    }
                    output.append(contentsOf: resolveVarReferences(value, environment: environment, stack: stack + [name]))
                } else if !fallbackTokens.isEmpty {
                    output.append(contentsOf: resolveVarReferences(fallbackTokens, environment: environment, stack: stack))
                } else {
                    issues.append(ThumbleCSSIssue(
                        severity: .error,
                        code: "undefined-custom-property",
                        message: "`\(name)` is not defined and no fallback was provided.",
                        line: token.line,
                        column: token.column
                    ))
                }
                continue
            }
            output.append(token)
            index += 1
        }
        return output
    }
}

extension ThumbleCSSComplexSelector {
    var key: String {
        compounds.map { compound in
            compound.parts.map { part in
                switch part.kind {
                case .type(let name): return name
                case .id(let value): return "#\(value)"
                case .attribute(let name, let operation, let value): return "[\(name)\(operation)\(value)]"
                case .pseudoClass(let name): return ":\(name)"
                }
            }.joined()
        }.joined(separator: " ")
    }

    var text: String { key }
}

// MARK: - Value parsing

struct ThumbleCSSParsedValues {
    var fillStyle: GamepadFillStyle?
    var foregroundColor: GamepadRGBAColor?
    var strokeColor: GamepadRGBAColor?
    var strokeWidth: CGFloat?
    var shadows: [GamepadControlShadowStyle]?
    var innerShadowColor: GamepadRGBAColor?
    var innerShadowRadius: CGFloat?
    var innerShadowX: CGFloat?
    var innerShadowY: CGFloat?
    var glowColor: GamepadRGBAColor?
    var glowRadius: CGFloat?
    var opacity: CGFloat?
    var scale: CGFloat?
    var blurRadius: CGFloat?
    var cornerRadius: CGFloat?
    var cornerRadii: GamepadCornerRadii?
    var knobColor: GamepadRGBAColor?
    var hapticStyle: GamepadHapticStyle?
}

enum ThumbleCSSValueParser {
    static func parse(
        declarations: [ThumbleCSSDeclaration],
        currentColor fallbackColor: GamepadRGBAColor?
    ) -> ThumbleCSSParsedValues {
        var values = ThumbleCSSParsedValues()
        var currentColor: GamepadRGBAColor? = fallbackColor
        // First pass captures `color` so later declarations can use currentColor.
        for declaration in declarations where declaration.name == "color" {
            if let color = parseColor(declaration.value) { currentColor = color }
        }
        for declaration in declarations {
            apply(declaration, into: &values, currentColor: currentColor)
        }
        return values
    }

    private static func apply(_ declaration: ThumbleCSSDeclaration, into values: inout ThumbleCSSParsedValues, currentColor: GamepadRGBAColor?) {
        let tokens = declaration.value
        func error(_ code: String, _ message: String) {
            // Value errors surface during lowering; store nothing for invalid declarations.
            _ = code
            _ = message
        }
        switch declaration.name {
        case "background", "background-color", "background-image":
            if let gradient = parseGradientFunction(tokens) {
                values.fillStyle = gradient
                return
            }
            if let image = parseImageFill(tokens) {
                values.fillStyle = .image(image)
                return
            }
            if let color = parseColor(tokens, currentColor: currentColor) {
                values.fillStyle = .solid(color)
                return
            }
            error("invalid-value", "\(declaration.name) requires a color, gradient, or url(#asset).")
        case "color":
            if let color = parseColor(tokens, currentColor: currentColor) { values.foregroundColor = color }
        case "border":
            if let (width, color) = parseBorderShorthand(tokens) {
                values.strokeWidth = width
                if let color { values.strokeColor = color }
            } else {
                error("invalid-value", "border requires a width and optional color, e.g. `border: 1px solid #fff`.")
            }
        case "border-width":
            if let length = parseSingleLength(tokens) { values.strokeWidth = length } else {
                error("invalid-value", "border-width requires a pixel length.")
            }
        case "border-color":
            if let color = parseColor(tokens, currentColor: currentColor) { values.strokeColor = color } else {
                error("invalid-value", "border-color requires a color.")
            }
        case "border-radius":
            if let radii = parseBorderRadius(tokens) {
                if radii.isUniform {
                    values.cornerRadius = radii.topLeading
                    values.cornerRadii = nil
                } else {
                    values.cornerRadii = radii
                    values.cornerRadius = nil
                }
            } else {
                error("invalid-value", "border-radius requires one to four pixel lengths.")
            }
        case "box-shadow":
            parseBoxShadow(tokens, into: &values, currentColor: currentColor)
        case "opacity":
            if let opacity = parseNumberOrPercent(tokens, range: 0...1) { values.opacity = opacity } else {
                error("invalid-value", "opacity requires a number between 0 and 1.")
            }
        case "transform":
            if let scale = parseScale(tokens) { values.scale = scale } else {
                error("invalid-value", "transform only supports scale(<number>) in this profile.")
            }
        case "filter":
            if let blur = parseBlur(tokens) { values.blurRadius = blur } else {
                error("invalid-value", "filter only supports blur(<length>) in this profile.")
            }
        case "-thumble-glow-color":
            if let color = parseColor(tokens, currentColor: currentColor) { values.glowColor = color } else {
                error("invalid-value", "-thumble-glow-color requires a color.")
            }
        case "-thumble-glow-radius":
            if let length = parseSingleLength(tokens) { values.glowRadius = length } else {
                error("invalid-value", "-thumble-glow-radius requires a pixel length.")
            }
        case "-thumble-knob-color":
            if let color = parseColor(tokens, currentColor: currentColor) { values.knobColor = color } else {
                error("invalid-value", "-thumble-knob-color requires a color.")
            }
        case "-thumble-haptic-style":
            if let token = tokens.first, case .ident(let name) = token.kind,
               let style = GamepadHapticStyle(rawValue: name.lowercased()) {
                values.hapticStyle = style
            } else {
                error("invalid-value", "-thumble-haptic-style requires one of \(GamepadHapticStyle.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
        default:
            break
        }
    }

    // MARK: colors

    static let keywordColors: [String: GamepadRGBAColor] = [
        "transparent": GamepadRGBAColor(red: 0, green: 0, blue: 0, alpha: 0),
        "black": GamepadRGBAColor(red: 0, green: 0, blue: 0, alpha: 1),
        "white": GamepadRGBAColor(red: 1, green: 1, blue: 1, alpha: 1),
        "red": GamepadRGBAColor(red: 1, green: 0, blue: 0, alpha: 1),
        "lime": GamepadRGBAColor(red: 0, green: 1, blue: 0, alpha: 1),
        "green": GamepadRGBAColor(red: 0, green: 0.5, blue: 0, alpha: 1),
        "blue": GamepadRGBAColor(red: 0, green: 0, blue: 1, alpha: 1),
        "yellow": GamepadRGBAColor(red: 1, green: 1, blue: 0, alpha: 1),
        "cyan": GamepadRGBAColor(red: 0, green: 1, blue: 1, alpha: 1),
        "magenta": GamepadRGBAColor(red: 1, green: 0, blue: 1, alpha: 1),
        "gray": GamepadRGBAColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1),
        "grey": GamepadRGBAColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1),
        "silver": GamepadRGBAColor(red: 0.75, green: 0.75, blue: 0.75, alpha: 1),
        "maroon": GamepadRGBAColor(red: 0.5, green: 0, blue: 0, alpha: 1),
        "navy": GamepadRGBAColor(red: 0, green: 0, blue: 0.5, alpha: 1),
        "olive": GamepadRGBAColor(red: 0.5, green: 0.5, blue: 0, alpha: 1),
        "purple": GamepadRGBAColor(red: 0.5, green: 0, blue: 0.5, alpha: 1),
        "teal": GamepadRGBAColor(red: 0, green: 0.5, blue: 0.5, alpha: 1),
        "orange": GamepadRGBAColor(red: 1, green: 0.65, blue: 0, alpha: 1),
        "pink": GamepadRGBAColor(red: 1, green: 0.75, blue: 0.8, alpha: 1)
    ]

    static func parseColor(_ tokens: [ThumbleCSSToken], currentColor: GamepadRGBAColor? = nil) -> GamepadRGBAColor? {
        guard let first = tokens.first else { return nil }
        switch first.kind {
        case .hash:
            guard tokens.count == 1 else { return nil }
            return GamepadRGBAColor(hexString: expandHex(first.text))
        case .ident(let name):
            guard tokens.count == 1 else { return nil }
            let lowered = name.lowercased()
            if lowered == "currentcolor" { return currentColor }
            return keywordColors[lowered]
        case .function(let name):
            let lowered = name.lowercased()
            guard lowered == "rgb" || lowered == "rgba" else { return nil }
            var depth = 1
            var arguments: [ThumbleCSSToken] = []
            var cursor = 1
            while cursor < tokens.count {
                let token = tokens[cursor]
                switch token.kind {
                case .function, .lparen: depth += 1
                case .rparen:
                    depth -= 1
                    if depth == 0 { cursor += 1; break }
                default: break
                }
                arguments.append(token)
                cursor += 1
            }
            return parseRGBFunction(arguments)
        default:
            return nil
        }
    }

    private static func expandHex(_ value: String) -> String {
        let hex = String(value.dropFirst())
        if hex.count == 3 {
            return "#" + hex.map { "\($0)\($0)" }.joined()
        }
        if hex.count == 4 {
            let expanded = hex.map { "\($0)\($0)" }.joined()
            return "#" + expanded
        }
        return value
    }

    private static func parseRGBFunction(_ arguments: [ThumbleCSSToken]) -> GamepadRGBAColor? {
        var components: [[ThumbleCSSToken]] = [[]]
        var depth = 0
        for token in arguments {
            switch token.kind {
            case .lparen, .lbracket: depth += 1
            case .rparen, .rbracket: depth = max(0, depth - 1)
            case .comma where depth == 0: components.append([])
            case .delim("/") where depth == 0: components.append([])
            default:
                components[components.count - 1].append(token)
            }
        }
        guard components.count == 3 || components.count == 4 else { return nil }
        func channel(_ tokens: [ThumbleCSSToken]) -> CGFloat? {
            guard let token = tokens.first else { return nil }
            switch token.kind {
            case .number:
                guard tokens.count == 1, let value = Double(token.text) else { return nil }
                return CGFloat(value)
            case .percentage:
                guard tokens.count == 1, let value = Double(token.text) else { return nil }
                return CGFloat(value) / 100
            default:
                return nil
            }
        }
        let one = CGFloat(1) / 255
        guard let red = channel(components[0]), let green = channel(components[1]), let blue = channel(components[2]) else {
            return nil
        }
        var alpha: CGFloat = 1
        if components.count == 4 {
            guard let value = channel(components[3]) else { return nil }
            alpha = value
        }
        func normalized(_ value: CGFloat, scale: CGFloat) -> CGFloat {
            value <= 1 && value > 0 && scale == 255 ? value : value
        }
        _ = normalized
        // rgb() channels are 0-255 (or percentages); alpha is 0-1 (or a percentage).
        let redValue = red > 1 ? red * one : red
        let greenValue = green > 1 ? green * one : green
        let blueValue = blue > 1 ? blue * one : blue
        return GamepadRGBAColor(
            red: min(max(redValue, 0), 1),
            green: min(max(greenValue, 0), 1),
            blue: min(max(blueValue, 0), 1),
            alpha: min(max(alpha, 0), 1)
        )
    }

    // MARK: lengths and numbers

    static func parseSingleLength(_ tokens: [ThumbleCSSToken]) -> CGFloat? {
        guard let token = tokens.first, tokens.count == 1 else { return nil }
        guard let value = Double(token.text) else { return nil }
        switch token.kind {
        case .number where value == 0:
            return 0
        case .dimension(let unit):
            guard unit == "px" else { return nil }
            return CGFloat(value)
        default:
            return nil
        }
    }

    static func parseNumberOrPercent(_ tokens: [ThumbleCSSToken], range: ClosedRange<CGFloat>) -> CGFloat? {
        guard let token = tokens.first, tokens.count == 1, let value = Double(token.text) else { return nil }
        let resolved: CGFloat
        switch token.kind {
        case .number: resolved = CGFloat(value)
        case .percentage: resolved = CGFloat(value) / 100
        default: return nil
        }
        guard range.contains(resolved) else { return nil }
        return resolved
    }

    static func parseBorderShorthand(_ tokens: [ThumbleCSSToken]) -> (CGFloat, GamepadRGBAColor?)? {
        var width: CGFloat?
        var color: GamepadRGBAColor?
        var cursor = 0
        var styleAccepted = false
        while cursor < tokens.count {
            let token = tokens[cursor]
            switch token.kind {
            case .dimension, .number:
                guard width == nil else { return nil }
                width = parseSingleLength([token])
                guard width != nil else { return nil }
            case .function:
                let slice = functionSlice(tokens, from: cursor)
                guard color == nil, let parsed = parseColor(slice) else { return nil }
                color = parsed
                cursor += slice.count
                continue
            case .hash:
                guard color == nil, let parsed = parseColor([token]) else { return nil }
                color = parsed
            case .ident(let name):
                let lowered = name.lowercased()
                if lowered == "solid" {
                    guard !styleAccepted else { return nil }
                    styleAccepted = true
                } else if lowered == "none" || lowered == "currentcolor" || ThumbleCSSValueParser.keywordColors[lowered] != nil {
                    guard color == nil else { return nil }
                    color = parseColor([token])
                    guard color != nil || lowered == "currentcolor" else { return nil }
                } else {
                    return nil
                }
            default:
                return nil
            }
            cursor += 1
        }
        guard width != nil else { return nil }
        return (width!, color)
    }

    private static func parseBorderRadius(_ tokens: [ThumbleCSSToken]) -> GamepadCornerRadii? {
        let lengths = tokens.compactMap { parseSingleLength([$0]) }
        guard lengths.count == tokens.count, (1...4).contains(tokens.count) else { return nil }
        switch lengths.count {
        case 1: return .uniform(lengths[0])
        case 2: return GamepadCornerRadii(topLeading: lengths[0], topTrailing: lengths[1], bottomTrailing: lengths[0], bottomLeading: lengths[1])
        case 3: return GamepadCornerRadii(topLeading: lengths[0], topTrailing: lengths[1], bottomTrailing: lengths[2], bottomLeading: lengths[1])
        default: return GamepadCornerRadii(topLeading: lengths[0], topTrailing: lengths[1], bottomTrailing: lengths[2], bottomLeading: lengths[3])
        }
    }

    static func parseScale(_ tokens: [ThumbleCSSToken]) -> CGFloat? {
        guard let first = tokens.first, tokens.count >= 1, case .function("scale") = first.kind else { return nil }
        let arguments = functionArguments(tokens, from: 0)
        guard arguments.count == 1,
              let token = arguments.first,
              case .number = token.kind,
              let value = Double(token.text) else { return nil }
        return CGFloat(value)
    }

    static func parseBlur(_ tokens: [ThumbleCSSToken]) -> CGFloat? {
        guard let first = tokens.first, tokens.count >= 1, case .function("blur") = first.kind else { return nil }
        let arguments = functionArguments(tokens, from: 0)
        guard arguments.count == 1 else { return nil }
        return parseSingleLength(arguments)
    }

    static func parseBoxShadow(
        _ tokens: [ThumbleCSSToken],
        into values: inout ThumbleCSSParsedValues,
        currentColor: GamepadRGBAColor?
    ) {
        if tokens.count == 1, case .ident(let name)? = tokens.first?.kind, name.lowercased() == "none" {
            values.shadows = []
            values.innerShadowColor = GamepadRGBAColor(red: 0, green: 0, blue: 0, alpha: 0)
            values.innerShadowRadius = 0
            values.innerShadowX = 0
            values.innerShadowY = 0
            return
        }
        var shadows: [GamepadControlShadowStyle] = []
        var innerShadow: (GamepadRGBAColor?, CGFloat, CGFloat, CGFloat)?
        for group in splitTopLevel(tokens, separator: .comma) {
            var lengths: [CGFloat] = []
            var color: GamepadRGBAColor?
            var inset = false
            var cursor = 0
            while cursor < group.count {
                let token = group[cursor]
                switch token.kind {
                case .ident(let name):
                    let lowered = name.lowercased()
                    if lowered == "inset" {
                        inset = true
                    } else if lowered == "solid" {
                        continue
                    } else {
                        guard color == nil else { break }
                        color = parseColor([token], currentColor: currentColor) ?? currentColor
                    }
                case .hash:
                    guard color == nil, let parsedColor = parseColor([token], currentColor: currentColor) else { return }
                    color = parsedColor
                case .function:
                    let slice = functionSlice(group, from: cursor)
                    guard color == nil, let parsed = parseColor(slice, currentColor: currentColor) else { return }
                    color = parsed
                    cursor += slice.count
                    continue
                case .number, .dimension:
                    guard let length = parseSingleLength([token]) else { return }
                    lengths.append(length)
                default:
                    return
                }
                cursor += 1
            }
            guard (2...3).contains(lengths.count) else { return }
            let resolvedColor = color ?? GamepadRGBAColor(red: 0, green: 0, blue: 0, alpha: 0.35)
            let radius = lengths.count == 3 ? lengths[2] : 0
            if inset {
                guard innerShadow == nil else { return }
                innerShadow = (resolvedColor, radius, lengths[0], lengths[1])
            } else {
                guard shadows.count < ThumbleCSSProfile.Limits.maximumShadowCount else { return }
                shadows.append(GamepadControlShadowStyle(
                    color: resolvedColor,
                    radius: radius,
                    x: lengths[0],
                    y: lengths[1]
                ))
            }
        }
        if !shadows.isEmpty { values.shadows = shadows }
        if let (color, radius, x, y) = innerShadow {
            values.innerShadowColor = color
            values.innerShadowRadius = radius
            values.innerShadowX = x
            values.innerShadowY = y
        }
    }

    // MARK: gradients

    static func parseImageFill(_ tokens: [ThumbleCSSToken]) -> GamepadImageFill? {
        guard let first = tokens.first, case .function("url") = first.kind, tokens.count >= 3 else { return nil }
        let arguments = functionArguments(tokens, from: 0)
        guard arguments.count == 1,
              let reference = arguments.first,
              case .hash = reference.kind
        else { return nil }
        let assetID = GamepadStyleToken.normalizedIdentifier(String(reference.text.dropFirst()))
        guard !assetID.isEmpty else { return nil }
        return GamepadImageFill(
            assetID: assetID,
            fileName: "\(assetID).png",
            contentMode: .fill
        )
    }

    static func parseGradientFunction(_ tokens: [ThumbleCSSToken]) -> GamepadFillStyle? {
        guard let first = tokens.first, case .function(let name) = first.kind else { return nil }
        let lowered = name.lowercased()
        guard lowered == "linear-gradient" || lowered == "radial-gradient" else { return nil }
        let inner = functionArguments(tokens, from: 0)
        let groups = splitTopLevel(inner, separator: .comma)
        guard !groups.isEmpty else { return nil }
        var cursor = 0
        var angle: CGFloat = 180
        var stopGroups = groups
        if lowered == "linear-gradient" {
            let first = groups[0]
            if let token = first.first, case .dimension(let unit) = token.kind, unit == "deg", first.count == 1,
               let value = Double(token.text) {
                angle = CGFloat(value)
                cursor = 1
            } else if case .ident("to")? = first.first?.kind {
                guard let direction = parseToDirection(first) else { return nil }
                angle = direction
                cursor = 1
            }
        } else {
            // radial-gradient: optional `at center` prefix is accepted and ignored.
            if let token = groups[0].first, case .ident(let name) = token.kind, name.lowercased() == "at" {
                cursor = 1
            }
        }
        stopGroups = Array(groups.dropFirst(cursor))
        guard !stopGroups.isEmpty else { return nil }
        var stops: [GamepadGradientStop] = []
        for group in stopGroups {
            guard let stop = parseGradientStop(group) else { return nil }
            stops.append(stop)
        }
        guard stops.count <= ThumbleCSSProfile.Limits.maximumGradientStops else { return nil }
        if stops.count == 1 {
            stops = [
                GamepadGradientStop(offset: 0, color: stops[0].color),
                GamepadGradientStop(offset: 1, color: stops[0].color)
            ]
        } else {
            stops = distributeMissingOffsets(stops)
        }
        let gradient = GamepadGradientFill(
            type: lowered == "linear-gradient" ? .linear : .radial,
            angleDegrees: angle,
            stops: stops
        )
        return .gradient(gradient.normalized)
    }

    private static func parseToDirection(_ tokens: [ThumbleCSSToken]) -> CGFloat? {
        let words = tokens.compactMap { token -> String? in
            guard case .ident(let name) = token.kind else { return nil }
            return name.lowercased()
        }
        guard words.first == "to", (1...3).contains(words.count - 1) else { return nil }
        let directions = Set(words.dropFirst())
        switch (directions.contains("top"), directions.contains("bottom"), directions.contains("left"), directions.contains("right")) {
        case (true, false, false, false): return 0
        case (false, true, false, false): return 180
        case (false, false, true, false): return 270
        case (false, false, false, true): return 90
        case (true, false, true, false): return 315
        case (true, false, false, true): return 45
        case (false, true, true, false): return 225
        case (false, true, false, true): return 135
        default: return nil
        }
    }

    private static func parseGradientStop(_ tokens: [ThumbleCSSToken]) -> GamepadGradientStop? {
        var colorTokens: [ThumbleCSSToken] = tokens
        var offset: CGFloat?
        if let last = tokens.last {
            switch last.kind {
            case .percentage where tokens.count >= 2:
                guard let value = Double(last.text) else { return nil }
                offset = CGFloat(value) / 100
                colorTokens = Array(tokens.dropLast())
            case .number where tokens.count >= 2:
                guard let value = Double(last.text), (0...1).contains(value) else { return nil }
                offset = CGFloat(value)
                colorTokens = Array(tokens.dropLast())
            default:
                break
            }
        }
        guard let color = parseColor(colorTokens) else { return nil }
        return GamepadGradientStop(offset: offset ?? -1, color: color)
    }

    private static func distributeMissingOffsets(_ stops: [GamepadGradientStop]) -> [GamepadGradientStop] {
        var result = stops
        if result.first?.offset ?? -1 < 0 { result[0] = GamepadGradientStop(offset: 0, color: result[0].color) }
        if result.last?.offset ?? 2 > 1 { result[result.count - 1] = GamepadGradientStop(offset: 1, color: result[result.count - 1].color) }
        var index = 1
        while index < result.count {
            if result[index].offset < 0 {
                var next = index + 1
                while next < result.count, result[next].offset < 0 { next += 1 }
                let previousOffset = result[index - 1].offset
                let nextOffset = next < result.count ? result[next].offset : 1
                let span = max(nextOffset - previousOffset, 0)
                let step = next > index ? span / CGFloat(next - index + 1) : 0
                var cursor = index
                while cursor < next {
                    result[cursor] = GamepadGradientStop(
                        offset: previousOffset + step * CGFloat(cursor - index + 1),
                        color: result[cursor].color
                    )
                    cursor += 1
                }
                index = next
            } else {
                index += 1
            }
        }
        return result
    }

    private static func splitTopLevel(_ tokens: [ThumbleCSSToken], separator: ThumbleCSSToken.Kind) -> [[ThumbleCSSToken]] {
        var groups: [[ThumbleCSSToken]] = [[]]
        var depth = 0
        for token in tokens {
            switch token.kind {
            case .function, .lparen, .lbracket, .lbrace: depth += 1
            case .rparen, .rbracket, .rbrace: depth = max(0, depth - 1)
            default: break
            }
            if depth == 0, token.kind == separator {
                groups.append([])
            } else {
                groups[groups.count - 1].append(token)
            }
        }
        return groups.filter { !$0.isEmpty }
    }

    private static func functionSlice(_ tokens: [ThumbleCSSToken], from: Int) -> [ThumbleCSSToken] {
        var depth = 0
        var cursor = from
        while cursor < tokens.count {
            switch tokens[cursor].kind {
            case .function, .lparen, .lbracket, .lbrace: depth += 1
            case .rparen, .rbracket, .rbrace:
                depth -= 1
                if depth == 0 { return Array(tokens[from...cursor]) }
            default: break
            }
            cursor += 1
        }
        return Array(tokens[from...])
    }

    private static func functionArguments(_ tokens: [ThumbleCSSToken], from: Int) -> [ThumbleCSSToken] {
        var depth = 1
        var arguments: [ThumbleCSSToken] = []
        var cursor = from + 1
        while cursor < tokens.count {
            let token = tokens[cursor]
            switch token.kind {
            case .function, .lparen:
                depth += 1
                arguments.append(token)
            case .rparen:
                depth -= 1
                if depth == 0 { return arguments }
                arguments.append(token)
            default:
                arguments.append(token)
            }
            cursor += 1
        }
        return arguments
    }
}

// MARK: - Lowering

struct ThumbleCSSComputedElementStyle: Sendable {
    var visualStyle: GamepadControlVisualStyle
    var cornerRadius: CGFloat?
    var cornerRadii: GamepadCornerRadii?
    var knobColor: GamepadRGBAColor?

    var isEmpty: Bool {
        visualStyle.isEmpty && cornerRadius == nil && cornerRadii == nil && knobColor == nil
    }
}

public enum ThumbleCSSCompilerError: Error, LocalizedError {
    case missingArtboard(String)
    case missingStylesheet(String)
    case unsafeStylesheetPath(String)
    case invalidCSS(ThumbleCSSReport)

    public var errorDescription: String? {
        switch self {
        case .missingArtboard(let id): "No canonical artboard exists for \(id)."
        case .missingStylesheet(let path): "Declared stylesheet is missing: \(path)."
        case .unsafeStylesheetPath(let path): "Stylesheet paths must stay below styles/: \(path)."
        case .invalidCSS(let report):
            report.errors.first.map { "CSS error: \($0.message)" } ?? "CSS compilation failed."
        }
    }
}

public struct ThumbleCSSLoweredAppearance: Sendable {
    public var orientation: ThumbleSkinOrientation?
    public var colorScheme: ThumbleSkinColorScheme?
    public var appearance: ThumbleSkinAppearance
}

public struct ThumbleCSSCompilation: Sendable {
    public var base: ThumbleSkinAppearance
    public var variants: [ThumbleCSSLoweredAppearance]
    public var report: ThumbleCSSReport
}

public enum ThumbleCSSCompiler {

    // MARK: entry points

    public static func compile(
        workspace: ThumbleSkinWorkspace,
        sourceRoot: URL,
        fileManager: FileManager = .default
    ) throws -> ThumbleCSSCompilation {
        guard let artboard = ThumbleSkinArtboardCatalog.resolve(workspace.artboardID) else {
            throw ThumbleCSSCompilerError.missingArtboard(workspace.artboardID)
        }
        guard !workspace.stylesheets.isEmpty else {
            throw ThumbleCSSCompilerError.missingStylesheet("The workspace declares no stylesheets.")
        }
        let texts = try loadStylesheets(workspace, sourceRoot: sourceRoot, fileManager: fileManager)
        let parsed = parseStylesheets(texts)
        let cascade = ThumbleCSSCascade(rules: parsed.stylesheet.rules)
        let documents = ThumbleCSSDocumentBuilder.documents(
            for: artboard,
            orientations: artboard.variants.map(\.orientation)
        )
        cascade.reportUnmatchedSelectors(documents: documents)
        var report = ThumbleCSSReport(issues: parsed.issues)
        report.issues.append(contentsOf: cascade.report.issues)
        guard report.isValid else {
            throw ThumbleCSSCompilerError.invalidCSS(report)
        }

        let base = lowerAppearance(
            artboard: artboard,
            cascade: cascade,
            documents: documents,
            scheme: nil,
            orientation: nil,
            issues: &report
        ).normalized
        guard report.isValid else {
            throw ThumbleCSSCompilerError.invalidCSS(report)
        }

        var variants: [ThumbleCSSLoweredAppearance] = []
        for orientation in unique(workspace.orientations) {
            for scheme in unique(workspace.colorSchemes) {
                let appearance = lowerAppearance(
                    artboard: artboard,
                    cascade: cascade,
                    documents: documents,
                    scheme: scheme,
                    orientation: orientation,
                    issues: &report
                ).normalized
                variants.append(ThumbleCSSLoweredAppearance(
                    orientation: orientation,
                    colorScheme: scheme,
                    appearance: appearance
                ))
            }
        }
        // url(#asset) references must resolve to declared sourceAssets that compile into the package.
        let declaredAssetIDs = Set(workspace.sourceAssets.map(\.id))
        for assetID in referencedAssetIDs(base: base, variants: variants).sorted() where !declaredAssetIDs.contains(assetID) {
            report.issues.append(ThumbleCSSIssue(
                severity: .error,
                code: "unknown-asset-reference",
                message: "url(#\(assetID)) does not match any sourceAssets entry in skin-source.json."
            ))
        }
        // Lowering can surface late cascade errors (for example undefined var() references);
        // merge anything appended after the early snapshot, then dedupe repeated occurrences.
        for issue in cascade.report.issues {
            report.issues.append(issue)
        }
        var seenIssues = Set<ThumbleCSSIssue>()
        report.issues.removeAll { !seenIssues.insert($0).inserted }
        guard report.isValid else {
            throw ThumbleCSSCompilerError.invalidCSS(report)
        }
        return ThumbleCSSCompilation(base: base, variants: variants, report: report)
    }

    public static func lint(
        workspace: ThumbleSkinWorkspace,
        sourceRoot: URL,
        fileManager: FileManager = .default
    ) -> ThumbleCSSReport {
        guard let artboard = ThumbleSkinArtboardCatalog.resolve(workspace.artboardID) else {
            return ThumbleCSSReport(issues: [
                ThumbleCSSIssue(severity: .error, code: "missing-artboard", message: "Unknown artboard \(workspace.artboardID).")
            ])
        }
        guard !workspace.stylesheets.isEmpty else {
            return ThumbleCSSReport(issues: [
                ThumbleCSSIssue(severity: .error, code: "missing-stylesheet", message: "The workspace declares no stylesheets under `stylesheets`.")
            ])
        }
        let texts: [(path: String, text: String)]
        do {
            texts = try loadStylesheets(workspace, sourceRoot: sourceRoot, fileManager: fileManager)
        } catch {
            let message: String
            switch error {
            case ThumbleCSSCompilerError.missingStylesheet(let path): message = "Declared stylesheet is missing: \(path)."
            case ThumbleCSSCompilerError.unsafeStylesheetPath(let path): message = "Stylesheet paths must stay below styles/: \(path)."
            default: message = error.localizedDescription
            }
            return ThumbleCSSReport(issues: [
                ThumbleCSSIssue(severity: .error, code: "stylesheet-load-failed", message: message)
            ])
        }
        let parsed = parseStylesheets(texts)
        let cascade = ThumbleCSSCascade(rules: parsed.stylesheet.rules)
        let documents = ThumbleCSSDocumentBuilder.documents(
            for: artboard,
            orientations: artboard.variants.map(\.orientation)
        )
        cascade.reportUnmatchedSelectors(documents: documents)
        // Resolve the full computed matrix so var() resolution errors surface during lint.
        var valueIssues: [ThumbleCSSIssue] = []
        for document in documents {
            for scheme in unique(workspace.colorSchemes) {
                for element in document.elements {
                    for state in GamepadControlPresentationState.allCases {
                        let declarations = cascade.resolvedDeclarations(
                            element: element,
                            state: state,
                            document: document,
                            scheme: scheme,
                            orientation: document.orientation
                        )
                        valueIssues.append(contentsOf: validationIssues(declarations: declarations))
                    }
                }
            }
        }
        var seen = Set<ThumbleCSSIssue>()
        let deduped = (parsed.issues + cascade.report.issues + valueIssues).filter { seen.insert($0).inserted }
        return ThumbleCSSReport(issues: deduped)
    }

    // MARK: computed-style inspection

    public struct ComputedElementStyles: Codable, Sendable {
        public struct StateDeclarations: Codable, Sendable {
            public var state: String
            public var declarations: [String: String]
        }
        public var id: String
        public var label: String
        public var kind: String
        public var role: String
        public var button: String
        public var states: [StateDeclarations]
    }

    public struct ComputedDocument: Codable, Sendable {
        public var orientation: String
        public var colorScheme: String
        public var controller: [ComputedElementStyles.StateDeclarations]
        public var elements: [ComputedElementStyles]
    }

    public static func computed(
        workspace: ThumbleSkinWorkspace,
        sourceRoot: URL,
        fileManager: FileManager = .default
    ) throws -> [ComputedDocument] {
        guard let artboard = ThumbleSkinArtboardCatalog.resolve(workspace.artboardID) else {
            throw ThumbleCSSCompilerError.missingArtboard(workspace.artboardID)
        }
        let texts = try loadStylesheets(workspace, sourceRoot: sourceRoot, fileManager: fileManager)
        let parsed = parseStylesheets(texts)
        let cascade = ThumbleCSSCascade(rules: parsed.stylesheet.rules)
        let documents = ThumbleCSSDocumentBuilder.documents(
            for: artboard,
            orientations: artboard.variants.map(\.orientation)
        )
        var results: [ComputedDocument] = []
        for document in documents {
            for scheme in unique(workspace.colorSchemes) {
                let root = ThumbleCSSDocumentElement(control: nil)
                let rootStates = GamepadControlPresentationState.allCases.map { state -> ComputedElementStyles.StateDeclarations in
                    let declarations = cascade.resolvedDeclarations(
                        element: root,
                        state: state,
                        document: document,
                        scheme: scheme,
                        orientation: document.orientation
                    )
                    var map: [String: String] = [:]
                    for declaration in declarations { map[declaration.name] = declaration.valueText }
                    return ComputedElementStyles.StateDeclarations(state: state.rawValue, declarations: map)
                }
                let elements = document.controls.map { control -> ComputedElementStyles in
                    let element = ThumbleCSSDocumentElement(control: control)
                    let states = GamepadControlPresentationState.allCases.map { state -> ComputedElementStyles.StateDeclarations in
                        let declarations = cascade.resolvedDeclarations(
                            element: element,
                            state: state,
                            document: document,
                            scheme: scheme,
                            orientation: document.orientation
                        )
                        var map: [String: String] = [:]
                        for declaration in declarations { map[declaration.name] = declaration.valueText }
                        return ComputedElementStyles.StateDeclarations(state: state.rawValue, declarations: map)
                    }
                    return ComputedElementStyles(
                        id: control.id,
                        label: control.label,
                        kind: control.kind.rawValue,
                        role: control.role.rawValue,
                        button: control.button.rawValue,
                        states: states
                    )
                }
                results.append(ComputedDocument(
                    orientation: document.orientation.rawValue,
                    colorScheme: scheme.rawValue,
                    controller: rootStates,
                    elements: elements
                ))
            }
        }
        return results
    }

    // MARK: stylesheet loading

    static func loadStylesheets(
        _ workspace: ThumbleSkinWorkspace,
        sourceRoot: URL,
        fileManager: FileManager
    ) throws -> [(path: String, text: String)] {
        guard workspace.stylesheets.count <= ThumbleCSSProfile.Limits.maximumStylesheetCount else {
            throw ThumbleCSSCompilerError.unsafeStylesheetPath("more than \(ThumbleCSSProfile.Limits.maximumStylesheetCount) stylesheets")
        }
        let root = sourceRoot.standardizedFileURL.resolvingSymlinksInPath()
        var results: [(String, String)] = []
        for path in workspace.stylesheets {
            guard ThumbleSkinPackageCodec.isSafePackagePath(path), path.hasPrefix("styles/") else {
                throw ThumbleCSSCompilerError.unsafeStylesheetPath(path)
            }
            let candidate = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
            guard candidate.path.hasPrefix(root.path + "/") else {
                throw ThumbleCSSCompilerError.unsafeStylesheetPath(path)
            }
            guard fileManager.fileExists(atPath: candidate.path) else {
                throw ThumbleCSSCompilerError.missingStylesheet(path)
            }
            let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else {
                throw ThumbleCSSCompilerError.unsafeStylesheetPath(path)
            }
            let data = try Data(contentsOf: candidate, options: [.mappedIfSafe])
            results.append((path, String(decoding: data, as: UTF8.self)))
        }
        return results
    }

    static func parseStylesheets(_ texts: [(path: String, text: String)]) -> (stylesheet: ThumbleCSSParsedStylesheet, issues: [ThumbleCSSIssue]) {
        var rules: [ThumbleCSSRule] = []
        var issues: [ThumbleCSSIssue] = []
        for (path, text) in texts {
            let parser = ThumbleCSSParser(path: path)
            let parsed = parser.parse(text)
            rules.append(contentsOf: parsed.stylesheet.rules)
            issues.append(contentsOf: parsed.report.issues)
        }
        return (ThumbleCSSParsedStylesheet(rules: rules), issues)
    }

    // MARK: appearance lowering

    private static func lowerAppearance(
        artboard: ThumbleSkinArtboard,
        cascade: ThumbleCSSCascade,
        documents: [ThumbleCSSDocument],
        scheme: ThumbleSkinColorScheme?,
        orientation: ThumbleSkinOrientation?,
        issues: inout ThumbleCSSReport
    ) -> ThumbleSkinAppearance {
        let relevantDocuments = documents.filter { document in
            guard let orientation else { return true }
            return document.orientation == orientation
        }
        let documentsToUse = relevantDocuments.isEmpty ? documents : relevantDocuments

        var styles: [GamepadStyleToken] = []
        var roleRules: [ThumbleSkinRoleRule] = []
        var buttonRules: [ThumbleSkinButtonRule] = []

        // Default control style: cascade for a synthetic control with no distinguishing attributes.
        let defaultElement = ThumbleCSSDocumentElement(
            control: ThumbleCSSControlElement.synthetic(kind: nil, role: nil, button: nil)
        )
        let defaultStyle = computeElementStyle(
            element: defaultElement,
            cascade: cascade,
            document: documentsToUse.first ?? ThumbleCSSDocument(orientation: .landscape, controls: []),
            scheme: scheme,
            orientation: orientation,
            issues: &issues
        )
        var defaultControl: ThumbleSkinControlAppearance?
        if !defaultStyle.isEmpty {
            let token = GamepadStyleToken(
                id: "css-default",
                name: "CSS Default",
                visualStyle: defaultStyle.visualStyle
            ).normalized
            if let token {
                styles.append(token)
                defaultControl = ThumbleSkinControlAppearance(
                    styleID: token.id,
                    cornerRadius: defaultStyle.cornerRadius,
                    cornerRadii: defaultStyle.cornerRadii
                )
            }
        }

        // Role styles: cascade for a synthetic control carrying only the role.
        let roles = Array(Set(documentsToUse.flatMap { $0.controls.map(\.role) }))
            .sorted { $0.rawValue < $1.rawValue }
        for role in roles {
            let dominantKind = dominantKind(for: role, in: documentsToUse)
            let element = ThumbleCSSDocumentElement(
                control: ThumbleCSSControlElement.synthetic(kind: dominantKind, role: role, button: nil)
            )
            let computed = computeElementStyle(
                element: element,
                cascade: cascade,
                document: documentsToUse.first ?? ThumbleCSSDocument(orientation: .landscape, controls: []),
                scheme: scheme,
                orientation: orientation,
                issues: &issues
            )
            guard !computed.isEmpty else { continue }
            let tokenID = "css-role-\(role.rawValue.replacingOccurrences(of: "_", with: "-"))"
            guard let token = GamepadStyleToken(
                id: tokenID,
                name: "CSS \(role.displayName)",
                visualStyle: computed.visualStyle
            ).normalized else { continue }
            styles.append(token)
            roleRules.append(ThumbleSkinRoleRule(
                role: role,
                appearance: ThumbleSkinControlAppearance(
                    styleID: token.id,
                    cornerRadius: computed.cornerRadius,
                    cornerRadii: computed.cornerRadii,
                    joystickKnobColor: role == .joystick ? computed.knobColor : nil
                )
            ))
            if role != .joystick, computed.knobColor != nil {
                issues.append(ThumbleCSSIssue(
                    severity: .warning,
                    code: "knob-color-ignored",
                    message: "-thumble-knob-color only applies to the joystick role."
                ))
            }
        }

        // Button styles: exact cascade per built-in face button on the artboard.
        var buttons = Set<GameButton>()
        for document in documentsToUse {
            for control in document.controls where control.kind == .button {
                buttons.insert(control.button)
            }
        }
        for button in buttons.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let document = documentsToUse.first(where: { document in
                document.controls.contains { $0.kind == .button && $0.button == button }
            }) else { continue }
            guard let control = document.controls.first(where: { $0.kind == .button && $0.button == button }) else { continue }
            let element = ThumbleCSSDocumentElement(control: control)
            let computed = computeElementStyle(
                element: element,
                cascade: cascade,
                document: document,
                scheme: scheme,
                orientation: orientation,
                issues: &issues
            )
            guard !computed.isEmpty else { continue }
            let tokenID = "css-button-\(ThumbleCSSDocumentBuilder.kebabIdentifier(button.rawValue))"
            guard let token = GamepadStyleToken(
                id: tokenID,
                name: "CSS \(control.label.isEmpty ? button.rawValue : control.label)",
                visualStyle: computed.visualStyle
            ).normalized else { continue }
            styles.append(token)
            buttonRules.append(ThumbleSkinButtonRule(
                button: button,
                appearance: ThumbleSkinControlAppearance(
                    styleID: token.id,
                    cornerRadius: computed.cornerRadius,
                    cornerRadii: computed.cornerRadii
                )
            ))
        }

        // Controller background.
        var background: GamepadFillStyle?
        if let document = documentsToUse.first {
            let root = ThumbleCSSDocumentElement(control: nil)
            let computed = computeElementStyle(
                element: root,
                cascade: cascade,
                document: document,
                scheme: scheme,
                orientation: orientation,
                issues: &issues
            )
            background = computed.visualStyle.normal.fillStyle
        }

        return ThumbleSkinAppearance(
            backgroundFillStyle: background,
            accentStyle: nil,
            showsButtonLabels: nil,
            defaultControl: defaultControl,
            roleRules: roleRules,
            buttonRules: buttonRules,
            styleLibrary: GamepadStyleLibrary(styles: dedupeStyles(styles)).normalized,
            artworkLayers: []
        )
    }

    private static func referencedAssetIDs(
        base: ThumbleSkinAppearance,
        variants: [ThumbleCSSLoweredAppearance]
    ) -> Set<String> {
        var ids = Set<String>()
        func collect(_ fillStyle: GamepadFillStyle?) {
            guard case .image(let image)? = fillStyle?.normalized, let assetID = image.assetID else { return }
            ids.insert(assetID)
        }
        func collectAppearance(_ appearance: ThumbleSkinAppearance) {
            collect(appearance.backgroundFillStyle)
            for style in appearance.styleLibrary.styles {
                collect(style.visualStyle.normal.fillStyle)
                collect(style.visualStyle.pressed?.fillStyle)
                collect(style.visualStyle.active?.fillStyle)
                collect(style.visualStyle.disabled?.fillStyle)
            }
        }
        collectAppearance(base)
        for variant in variants { collectAppearance(variant.appearance) }
        return ids
    }

    private static func dominantKind(
        for role: GamepadVisualRole,
        in documents: [ThumbleCSSDocument]
    ) -> GamepadCustomControlKind? {
        var counts: [GamepadCustomControlKind: Int] = [:]
        for document in documents {
            for control in document.controls where control.role == role {
                counts[control.kind, default: 0] += 1
            }
        }
        return counts.max { lhs, rhs in
            (lhs.value, lhs.key.rawValue) < (rhs.value, rhs.key.rawValue)
        }?.key
    }

    private static func computeElementStyle(
        element: ThumbleCSSDocumentElement,
        cascade: ThumbleCSSCascade,
        document: ThumbleCSSDocument,
        scheme: ThumbleSkinColorScheme?,
        orientation: ThumbleSkinOrientation?,
        issues: inout ThumbleCSSReport
    ) -> ThumbleCSSComputedElementStyle {
        var stateValues: [GamepadControlPresentationState: ThumbleCSSParsedValues] = [:]
        var currentColorFallback: GamepadRGBAColor?
        for state in GamepadControlPresentationState.allCases {
            let declarations = cascade.resolvedDeclarations(
                element: element,
                state: state,
                document: document,
                scheme: scheme,
                orientation: orientation
            )
            var valueIssues: [ThumbleCSSIssue] = []
            let values = validateAndParse(declarations: declarations, issues: &valueIssues)
            issues.issues.append(contentsOf: valueIssues)
            stateValues[state] = values
            if state == .normal, let color = values.foregroundColor { currentColorFallback = color }
        }
        // Re-resolve states that used currentColor before `color` was known.
        for state in GamepadControlPresentationState.allCases {
            let declarations = cascade.resolvedDeclarations(
                element: element,
                state: state,
                document: document,
                scheme: scheme,
                orientation: orientation
            )
            var ignored: [ThumbleCSSIssue] = []
            stateValues[state] = ThumbleCSSValueParser.parse(declarations: declarations, currentColor: currentColorFallback)
            _ = ignored
        }

        func stateStyle(_ state: GamepadControlPresentationState) -> GamepadControlStateStyle? {
            guard let values = stateValues[state] else { return nil }
            let style = GamepadControlStateStyle(
                fillStyle: values.fillStyle,
                foregroundColor: values.foregroundColor,
                strokeColor: values.strokeColor,
                strokeWidth: values.strokeWidth,
                shadows: values.shadows,
                glowColor: values.glowColor,
                glowRadius: values.glowRadius,
                innerShadowColor: values.innerShadowColor,
                innerShadowRadius: values.innerShadowRadius,
                innerShadowX: values.innerShadowX,
                innerShadowY: values.innerShadowY,
                opacity: values.opacity,
                scale: values.scale,
                blurRadius: values.blurRadius
            )
            return style.isEmpty ? nil : style
        }

        let normal = stateValues[.normal]
        let visualStyle = GamepadControlVisualStyle(
            normal: stateStyle(.normal) ?? .empty,
            pressed: stateStyle(.pressed),
            active: stateStyle(.active),
            disabled: stateStyle(.disabled),
            hapticStyle: normal?.hapticStyle
        )
        return ThumbleCSSComputedElementStyle(
            visualStyle: visualStyle,
            cornerRadius: normal?.cornerRadius,
            cornerRadii: normal?.cornerRadii,
            knobColor: normal?.knobColor
        )
    }

    /// Reports unsupported declaration values without lowering.
    static func validationIssues(
        declarations: [ThumbleCSSDeclaration],
        currentColor: GamepadRGBAColor? = nil
    ) -> [ThumbleCSSIssue] {
        var issues: [ThumbleCSSIssue] = []
        var resolvedCurrentColor = currentColor
        for declaration in declarations where declaration.name == "color" {
            if let color = ThumbleCSSValueParser.parseColor(declaration.value) { resolvedCurrentColor = color }
        }
        for declaration in declarations {
            guard !declaration.name.hasPrefix("--") else { continue }
            guard ThumbleCSSProfile.properties.contains(declaration.name) else { continue }
            issues.append(contentsOf: validateDeclaration(declaration, currentColor: resolvedCurrentColor))
        }
        return issues
    }

    /// Parses declarations while reporting unsupported values as issues.
    private static func validateAndParse(
        declarations: [ThumbleCSSDeclaration],
        issues: inout [ThumbleCSSIssue]
    ) -> ThumbleCSSParsedValues {
        // Duplicate a light validation pass: run per-declaration parse checks that can fail.
        var values = ThumbleCSSParsedValues()
        var currentColor: GamepadRGBAColor?
        for declaration in declarations where declaration.name == "color" {
            if let color = ThumbleCSSValueParser.parseColor(declaration.value) { currentColor = color }
        }
        for declaration in declarations {
            guard !declaration.name.hasPrefix("--") else { continue }
            guard ThumbleCSSProfile.properties.contains(declaration.name) else { continue }
            let validated = validateDeclaration(declaration, currentColor: currentColor)
            issues.append(contentsOf: validated)
        }
        values = ThumbleCSSValueParser.parse(declarations: declarations, currentColor: currentColor)
        return values
    }

    private static func validateDeclaration(
        _ declaration: ThumbleCSSDeclaration,
        currentColor: GamepadRGBAColor?
    ) -> [ThumbleCSSIssue] {
        let tokens = declaration.value
        func error(_ code: String, _ message: String) -> ThumbleCSSIssue {
            ThumbleCSSIssue(
                severity: .error,
                code: code,
                message: message,
                line: declaration.line,
                column: declaration.column
            )
        }
        switch declaration.name {
        case "background", "background-color":
            if ThumbleCSSValueParser.parseGradientFunction(tokens) == nil,
               ThumbleCSSValueParser.parseImageFill(tokens) == nil,
               ThumbleCSSValueParser.parseColor(tokens, currentColor: currentColor) == nil {
                return [error("invalid-value", "`\(declaration.name): \(declaration.valueText)` requires a color, gradient, or url(#asset).")]
            }
        case "background-image":
            if ThumbleCSSValueParser.parseGradientFunction(tokens) == nil,
               ThumbleCSSValueParser.parseImageFill(tokens) == nil {
                return [error("invalid-value", "`background-image: \(declaration.valueText)` requires linear-gradient(), radial-gradient(), or url(#asset).")]
            }
        case "color", "border-color", "-thumble-glow-color", "-thumble-knob-color":
            if ThumbleCSSValueParser.parseColor(tokens, currentColor: currentColor) == nil {
                return [error("invalid-value", "`\(declaration.name): \(declaration.valueText)` requires a color.")]
            }
        case "border-width", "-thumble-glow-radius":
            if ThumbleCSSValueParser.parseSingleLength(tokens) == nil {
                return [error("invalid-value", "`\(declaration.name): \(declaration.valueText)` requires a pixel length like `2px`.")]
            }
        case "border-radius":
            let lengths = tokens.compactMap { ThumbleCSSValueParser.parseSingleLength([$0]) }
            if lengths.count != tokens.count || !(1...4).contains(tokens.count) {
                return [error("invalid-value", "`border-radius: \(declaration.valueText)` requires one to four pixel lengths; percentages are not supported because control sizes vary.")]
            }
        case "opacity":
            if ThumbleCSSValueParser.parseNumberOrPercent(tokens, range: 0...1) == nil {
                return [error("invalid-value", "`opacity: \(declaration.valueText)` requires a number between 0 and 1.")]
            }
        case "transform":
            var accepted = false
            if let first = tokens.first, case .function("scale") = first.kind {
                let argumentTokens = tokens
                accepted = ThumbleCSSValueParser.parseScale(argumentTokens) != nil
            }
            if !accepted {
                return [error("invalid-value", "`transform: \(declaration.valueText)` only supports scale(<number>) in this profile.")]
            }
        case "filter":
            var accepted = false
            if let first = tokens.first, case .function("blur") = first.kind {
                accepted = ThumbleCSSValueParser.parseBlur(tokens) != nil
            }
            if !accepted {
                return [error("invalid-value", "`filter: \(declaration.valueText)` only supports blur(<length>) in this profile.")]
            }
        case "border":
            if ThumbleCSSValueParser.parseBorderShorthand(tokens) == nil {
                return [error("invalid-value", "`border: \(declaration.valueText)` accepts a width, `solid`, and a color only.")]
            }
        case "box-shadow":
            var probe = ThumbleCSSParsedValues()
            let before = probe
            ThumbleCSSValueParser.parseBoxShadow(tokens, into: &probe, currentColor: currentColor)
            if probe.shadows == nil && before.shadows == nil && probe.innerShadowRadius == nil {
                let isNone = tokens.count == 1 && {
                    if case .ident(let name)? = tokens.first?.kind { return name.lowercased() == "none" }
                    return false
                }()
                if !isNone {
                    return [error("invalid-value", "`box-shadow: \(declaration.valueText)` requires `none` or `inset? x y blur? color?` shadow lists.")]
                }
            }
        case "-thumble-haptic-style":
            var valid = false
            if let token = tokens.first, case .ident(let name) = token.kind, tokens.count == 1 {
                valid = GamepadHapticStyle(rawValue: name.lowercased()) != nil
            }
            if !valid {
                return [error("invalid-value", "`-thumble-haptic-style: \(declaration.valueText)` requires one of \(GamepadHapticStyle.allCases.map(\.rawValue).joined(separator: ", ")).")]
            }
        default:
            break
        }
        return []
    }

    private static func dedupeStyles(_ styles: [GamepadStyleToken]) -> [GamepadStyleToken] {
        var seen = Set<String>()
        var result: [GamepadStyleToken] = []
        for style in styles {
            guard seen.insert(style.id).inserted else { continue }
            result.append(style)
        }
        return result
    }

    private static func unique<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }
}

// MARK: - Capabilities payload

public struct ThumbleCSSCapabilities: Codable, Sendable {
    public struct PropertyCapability: Codable, Sendable {
        public var name: String
        public var syntax: String
        public var appliesTo: String
    }

    public var profile: String
    public var properties: [PropertyCapability]
    public var selectors: [String]
    public var pseudoClasses: [String]
    public var mediaFeatures: [String]
    public var states: [String]
    public var limits: [String: Int]

    public static let current = ThumbleCSSCapabilities(
        profile: ThumbleCSSProfile.identifier,
        properties: [
            PropertyCapability(name: "background", syntax: "<color> | <gradient> | url(#asset)", appliesTo: "controller, controls"),
            PropertyCapability(name: "background-color", syntax: "<color>", appliesTo: "controller, controls"),
            PropertyCapability(name: "background-image", syntax: "linear-gradient() | radial-gradient() | url(#asset)", appliesTo: "controller, controls"),
            PropertyCapability(name: "color", syntax: "<color>", appliesTo: "controls"),
            PropertyCapability(name: "border", syntax: "<length> solid? <color>?", appliesTo: "controls"),
            PropertyCapability(name: "border-width", syntax: "<length>", appliesTo: "controls"),
            PropertyCapability(name: "border-color", syntax: "<color>", appliesTo: "controls"),
            PropertyCapability(name: "border-radius", syntax: "<length>{1,4}", appliesTo: "controls"),
            PropertyCapability(name: "box-shadow", syntax: "none | [inset? <length>{2,3} <color>?]#", appliesTo: "controls"),
            PropertyCapability(name: "opacity", syntax: "<number> | <percentage>", appliesTo: "controls"),
            PropertyCapability(name: "transform", syntax: "scale(<number>)", appliesTo: "controls"),
            PropertyCapability(name: "filter", syntax: "blur(<length>)", appliesTo: "controls"),
            PropertyCapability(name: "-thumble-glow-color", syntax: "<color>", appliesTo: "controls"),
            PropertyCapability(name: "-thumble-glow-radius", syntax: "<length>", appliesTo: "controls"),
            PropertyCapability(name: "-thumble-knob-color", syntax: "<color>", appliesTo: "joystick role"),
            PropertyCapability(name: "-thumble-haptic-style", syntax: "none|light|medium|heavy|soft|rigid", appliesTo: "controls")
        ],
        selectors: [
            "controller", "control", "button", "joystick", "trigger", "trackpad", "text", "decoration",
            "#<element-id>", "[kind=…]", "[role=…]", "[role~=…]", "[button=…]", "descendant (space)"
        ],
        pseudoClasses: [":root", ":normal", ":pressed", ":active", ":disabled"],
        mediaFeatures: ["prefers-color-scheme: light|dark", "orientation: portrait|landscape"],
        states: GamepadControlPresentationState.allCases.map(\.rawValue),
        limits: [
            "maximumStylesheetBytes": ThumbleCSSProfile.Limits.maximumStylesheetBytes,
            "maximumStylesheetCount": ThumbleCSSProfile.Limits.maximumStylesheetCount,
            "maximumRuleCount": ThumbleCSSProfile.Limits.maximumRuleCount,
            "maximumDeclarationCount": ThumbleCSSProfile.Limits.maximumDeclarationCount,
            "maximumGradientStops": ThumbleCSSProfile.Limits.maximumGradientStops,
            "maximumShadowCount": ThumbleCSSProfile.Limits.maximumShadowCount
        ]
    )
}
