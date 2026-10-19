import Foundation
import CryptoKit

/// A user-exported configuration snapshot, never a gameplay telemetry channel.
struct ThumbleLinkSnapshot: Codable, Equatable, Sendable {
    static let schema = "thumble.wow-link"
    static let prefix = "THUMBLELINK1:"
    static let maximumBytes = 256 * 1024
    static let maximumActions = 128

    struct Client: Codable, Equatable, Sendable {
        let flavor: String
        let version: String
        let build: String
        let interface: Int
    }

    struct Character: Codable, Equatable, Sendable {
        let id: String
        let name: String
        let realm: String
        let classTag: String
    }

    struct Action: Codable, Equatable, Sendable {
        let command: String
        let label: String
        let keys: [String]
        let slot: Int?
        let kind: String
        let actionID: Int?
        let iconFileID: Int?
        let unavailableReason: String?
    }

    let schema: String
    let version: Int
    let client: Client
    let character: Character
    /// Unix seconds, as reported by the game at export time.
    let exportedAt: Int64
    let actions: [Action]
    let warnings: [String]

    static func parse(_ text: String) throws -> Self {
        guard text.utf8.count <= maximumBytes else { throw ThumbleLinkError("The export exceeds the 256 KiB limit.") }
        var json = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if json.hasPrefix(prefix) { json.removeFirst(prefix.count) }
        let snapshot: Self
        do { snapshot = try JSONDecoder().decodeUnique(Self.self, from: Data(json.utf8)) }
        catch { throw ThumbleLinkError("Paste a complete Thumble Link version 1 export from /thumble in WoW.") }
        try snapshot.validate()
        return snapshot
    }

    private func validate() throws {
        guard schema == Self.schema, version == 1, client.flavor == "forever",
              client.interface == 16001, exportedAt > 0,
              (1...Self.maximumActions).contains(actions.count), warnings.count <= 32,
              Self.text(client.version, limit: 32), Self.text(client.build, limit: 32),
              Self.text(character.id, limit: 96), Self.text(character.name, limit: 96),
              Self.text(character.realm, limit: 96), Self.text(character.classTag, limit: 32),
              warnings.allSatisfy({ Self.text($0, limit: 256) }) else {
            throw ThumbleLinkError("This export has an unsupported client, version, or invalid snapshot fields. Version 1 supports Forever interface 16001.")
        }
        var commands = Set<String>()
        for action in actions {
            guard Self.text(action.command, limit: 60),
                  action.command.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) || $0 == 95 }),
                  commands.insert(action.command).inserted,
                  Self.text(action.label, limit: 128), Self.text(action.kind, limit: 32),
                  action.keys.count <= 4, action.keys.allSatisfy({ Self.text($0, limit: 64) }),
                  action.slot.map({ (1...240).contains($0) }) ?? true,
                  action.actionID.map({ (1...Int(Int32.max)).contains($0) }) ?? true,
                  action.iconFileID.map({ (1...Int(Int32.max)).contains($0) }) ?? true,
                  action.unavailableReason.map({ Self.text($0, limit: 256) }) ?? true else {
                throw ThumbleLinkError("The export contains duplicate commands or invalid action data.")
            }
        }
    }

    private static func text(_ text: String, limit: Int) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= limit
            && !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    var profileID: UUID { Self.stableID("profile/\(client.flavor)/\(character.id)") }
    var suggestedName: String { "WoW \(character.name) – \(character.realm)" }

    func elementID(for command: String) -> UUID {
        Self.stableID("element/\(client.flavor)/\(character.id)/\(command)")
    }

    private static func stableID(_ key: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("thumble-link-v1/\(key)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

struct ThumbleLinkError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum ThumbleLinkKeyBinding {
    /// Parse WoW tokens explicitly: never interpret a multi-digit key as a raw Mac keycode.
    static func resolve(_ token: String) -> KeypadKeyboardBinding? {
        var key = token.uppercased()
        var modifiers: [String] = []
        let prefixes = [("SHIFT-", "shift"), ("CTRL-", "control"), ("ALT-", "option"), ("META-", "command")]
        while let prefix = prefixes.first(where: { key.hasPrefix($0.0) }) {
            guard !modifiers.contains(prefix.1) else { return nil }
            modifiers.append(prefix.1)
            key.removeFirst(prefix.0.count)
        }
        let aliases = ["BACKSPACE": "Backspace", "DELETE": "Forward Delete", "PAGEUP": "Page Up",
                       "PAGEDOWN": "Page Down", "NUMPADDECIMAL": "Keypad .", "NUMPADDIVIDE": "Keypad /",
                       "NUMPADMULTIPLY": "Keypad *", "NUMPADMINUS": "Keypad -", "NUMPADPLUS": "Keypad +",
                       "NUMPADENTER": "Keypad Enter", "NUMPADEQUALS": "Keypad ="]
        let name: String
        if let alias = aliases[key] { name = alias }
        else if key.hasPrefix("NUMPAD"), key.count == 7, let digit = key.last, digit.isASCII, digit.isNumber {
            name = "Keypad \(digit)"
        } else if key.count == 1, let ascii = key.utf8.first,
                  (65...90).contains(ascii) || (48...57).contains(ascii) || "`-=[]\\;',./".contains(key) {
            name = key
        } else if ["SPACE", "TAB", "ENTER", "ESCAPE", "UP", "DOWN", "LEFT", "RIGHT", "HOME", "END"].contains(key) {
            name = key
        } else if key.hasPrefix("F"), let number = Int(key.dropFirst()), (1...20).contains(number), key == "F\(number)" {
            name = key
        } else { return nil }
        return KeypadKeyboardBinding(keyName: name, modifierNames: modifiers)
    }
}
