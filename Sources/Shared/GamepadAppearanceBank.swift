import Foundation

/// All retained scheme/held-trigger appearances owned by a profile. The light/Base
/// variant is the reference against which subsequent ordinary edits are compared.
public struct GamepadAppearanceBank: Codable, Equatable, Sendable {
    public struct Variant: Codable, Equatable, Sendable {
        public let colorScheme: ThumbleSkinColorScheme
        public let actionSet: ThumbleActionSet
        public let appearance: GamepadAppearanceSnapshot

        public init(colorScheme: ThumbleSkinColorScheme, actionSet: ThumbleActionSet, appearance: GamepadAppearanceSnapshot) {
            self.colorScheme = colorScheme; self.actionSet = actionSet; self.appearance = appearance
        }
    }

    public enum ValidationError: Error, Equatable {
        case incompleteOrDuplicateStates
        case inconsistentControlIDs
        case missingResources([String])
    }

    private final class Storage: Sendable {
        let variants: [Variant]
        let reference: GamepadAppearanceSnapshot
        init(variants: [Variant], reference: GamepadAppearanceSnapshot) {
            self.variants = variants; self.reference = reference
        }
    }
    private let storage: Storage

    public var variants: [Variant] { storage.variants }

    public init(variants: [Variant]) throws {
        let expectedCount = ThumbleSkinColorScheme.allCases.count * ThumbleActionSet.allCases.count
        let keys = Set(variants.map { Self.key($0.colorScheme, $0.actionSet) })
        guard variants.count == expectedCount, keys.count == expectedCount,
              let reference = variants.first(where: { $0.colorScheme == .light && $0.actionSet == .base })?.appearance else {
            throw ValidationError.incompleteOrDuplicateStates
        }
        for variant in variants {
            guard variant.appearance.controlIDs == reference.controlIDs else { throw ValidationError.inconsistentControlIDs }
            let missing = try variant.appearance.missingResourceIDs()
            guard missing.isEmpty else { throw ValidationError.missingResources(missing) }
        }
        storage = Storage(variants: variants.sorted { Self.key($0.colorScheme, $0.actionSet) < Self.key($1.colorScheme, $1.actionSet) },
            reference: reference)
    }

    /// Typed resolution only; package lookup and JSON codecs never run here.
    public func resolve(_ customization: GamepadCustomization, colorScheme: ThumbleSkinColorScheme,
                        actionSet: ThumbleActionSet = .base) -> GamepadCustomization {
        // Construction/decoding requires the complete finite state set.
        let target = storage.variants.first { $0.colorScheme == colorScheme && $0.actionSet == actionSet }!
        return target.appearance.applying(to: customization, preservingEditsFrom: storage.reference, colorScheme: colorScheme)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.storage === rhs.storage || lhs.storage.variants == rhs.storage.variants
    }

    private static func key(_ scheme: ThumbleSkinColorScheme, _ action: ThumbleActionSet) -> String {
        scheme.rawValue + "/" + action.rawValue
    }

    public init(from decoder: Decoder) throws {
        let all = try decoder.container(keyedBy: BankCodingKey.self)
        guard all.allKeys.allSatisfy({ ["schemaVersion", "variants"].contains($0.stringValue) }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unexpected appearance-bank field."))
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .schemaVersion) == 1 else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: container, debugDescription: "Unsupported appearance-bank version.")
        }
        try self.init(variants: container.decode([Variant].self, forKey: .variants))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(1, forKey: .schemaVersion)
        try container.encode(storage.variants, forKey: .variants)
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, variants }
    private struct BankCodingKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}
