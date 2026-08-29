import CryptoKit
import Foundation
import JavaScriptCore

/// A validated, byte-preserving portable profile artifact. Large values live in immutable
/// reference storage so copies of this wrapper remain within the shared inline-size budget.
public struct PortableProfileArtifact: Sendable {
    public static let maximumBytes = 8 * 1024 * 1024
    public static let maximumProfiles = 256

    public struct CatalogRevision: Codable, Equatable, Sendable {
        public let controllerTemplates: Int
        public let deviceFrames: Int
        public let generationSpec: Int
    }

    public struct ContentHash: Codable, Equatable, Sendable {
        public let algorithm: String
        public let canonicalization: String
        public let value: String
    }

    public struct ProfileSummary: Codable, Equatable, Sendable {
        public let id: UUID
        public let name: String
    }

    private final class Storage: @unchecked Sendable {
        let rawData: Data
        let profiles: [GamepadConfigurationProfile]
        let summaries: [ProfileSummary]
        let activeProfileID: UUID
        let defaultProfileID: UUID?
        let exportedAt: Int64
        let catalogRevision: CatalogRevision
        let contentHash: ContentHash
        let canonicalContent: Data

        init(
            rawData: Data,
            profiles: [GamepadConfigurationProfile],
            summaries: [ProfileSummary],
            activeProfileID: UUID,
            defaultProfileID: UUID?,
            exportedAt: Int64,
            catalogRevision: CatalogRevision,
            contentHash: ContentHash,
            canonicalContent: Data
        ) {
            self.rawData = rawData
            self.profiles = profiles
            self.summaries = summaries
            self.activeProfileID = activeProfileID
            self.defaultProfileID = defaultProfileID
            self.exportedAt = exportedAt
            self.catalogRevision = catalogRevision
            self.contentHash = contentHash
            self.canonicalContent = canonicalContent
        }
    }

    private let storage: Storage

    public var rawData: Data { storage.rawData }
    public var profiles: [GamepadConfigurationProfile] { storage.profiles }
    public var profileSummaries: [ProfileSummary] { storage.summaries }
    public var activeProfileID: UUID { storage.activeProfileID }
    public var defaultProfileID: UUID? { storage.defaultProfileID }
    public var exportedAt: Int64 { storage.exportedAt }
    public var catalogRevision: CatalogRevision { storage.catalogRevision }
    public var contentHash: ContentHash { storage.contentHash }
    public var canonicalContent: Data { storage.canonicalContent }

    public init(validating data: Data) throws {
        guard data.count <= Self.maximumBytes else {
            throw PortableProfileArtifactError.tooLarge
        }
        try PortableJSONScanner(data: data).scan()

        let rootValue: Any
        do {
            rootValue = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw PortableProfileArtifactError.invalidJSON
        }
        guard let root = rootValue as? [String: Any] else {
            throw PortableProfileArtifactError.invalidEnvelope
        }

        let validated = try Self.validateEnvelope(root)
        let canonical = try PortableArtifactCanonicalizer.canonicalize(data)
        let digest = SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
        guard validated.contentHash.value == digest else {
            throw PortableProfileArtifactError.contentHashMismatch
        }

        // Typed decoding deliberately follows integrity validation. Unknown fields remain in
        // rawData, while consumers receive only the current typed profile subset.
        var typedProfiles: [GamepadConfigurationProfile] = []
        typedProfiles.reserveCapacity(validated.rawProfiles.count)
        let decoder = JSONDecoder()
        for (index, rawProfile) in validated.rawProfiles.enumerated() {
            let encoded: Data
            do {
                encoded = try JSONSerialization.data(withJSONObject: rawProfile, options: [])
            } catch {
                throw PortableProfileArtifactError.typedProfileInvalid
            }
            let profile: GamepadConfigurationProfile
            do {
                profile = try decoder.decode(GamepadConfigurationProfile.self, from: encoded)
            } catch {
                throw PortableProfileArtifactError.typedProfileInvalid
            }
            let summary = validated.summaries[index]
            guard profile.id == summary.id, profile.name == summary.name else {
                throw PortableProfileArtifactError.typedProfileMismatch
            }
            typedProfiles.append(profile)
        }

        storage = Storage(
            rawData: data,
            profiles: typedProfiles,
            summaries: validated.summaries,
            activeProfileID: validated.activeProfileID,
            defaultProfileID: validated.defaultProfileID,
            exportedAt: validated.exportedAt,
            catalogRevision: validated.catalogRevision,
            contentHash: validated.contentHash,
            canonicalContent: canonical
        )
    }

    private struct ValidatedEnvelope {
        let rawProfiles: [[String: Any]]
        let summaries: [ProfileSummary]
        let activeProfileID: UUID
        let defaultProfileID: UUID?
        let exportedAt: Int64
        let catalogRevision: CatalogRevision
        let contentHash: ContentHash
    }

    private static func validateEnvelope(_ root: [String: Any]) throws -> ValidatedEnvelope {
        guard root["schema"] as? String == "com.codybontecou.pocketpad.keypad-configuration" else {
            throw PortableProfileArtifactError.unsupportedSchema
        }
        guard exactInteger(root["version"]) == 4 else {
            throw PortableProfileArtifactError.unsupportedSchemaVersion
        }
        guard exactInteger(root["artifactVersion"]) == 1 else {
            throw PortableProfileArtifactError.unsupportedArtifactVersion
        }
        guard let exportedAt = exactInteger(root["exportedAt"]) else {
            throw PortableProfileArtifactError.invalidEnvelope
        }
        guard let rawProfiles = root["profiles"] as? [[String: Any]],
              !rawProfiles.isEmpty,
              rawProfiles.count <= maximumProfiles
        else {
            throw PortableProfileArtifactError.invalidProfileCount
        }
        guard let activeString = root["activeProfileID"] as? String else {
            throw PortableProfileArtifactError.activeProfileMissing
        }
        let defaultString: String?
        if root["defaultProfileID"] == nil || root["defaultProfileID"] is NSNull {
            defaultString = nil
        } else if let value = root["defaultProfileID"] as? String {
            defaultString = value
        } else {
            throw PortableProfileArtifactError.defaultProfileMissing
        }
        let keyMaps: [String: Any]
        if let rawKeyMaps = root["profileKeyBindings"] {
            guard let maps = rawKeyMaps as? [String: Any] else {
                throw PortableProfileArtifactError.invalidBindingMap
            }
            keyMaps = maps
        } else {
            keyMaps = [:]
        }
        let outputMaps: [String: Any]
        if let rawOutputMaps = root["profileOutputBindings"] {
            guard let maps = rawOutputMaps as? [String: Any] else {
                throw PortableProfileArtifactError.invalidBindingMap
            }
            outputMaps = maps
        } else {
            outputMaps = [:]
        }
        guard let catalog = root["catalogRevision"] as? [String: Any],
              catalog.count == 3,
              exactInteger(catalog["controllerTemplates"]) == 1,
              exactInteger(catalog["deviceFrames"]) == 1,
              exactInteger(catalog["generationSpec"]) == 1
        else {
            throw PortableProfileArtifactError.unsupportedCatalogRevision
        }
        guard let hash = root["contentHash"] as? [String: Any],
              hash.count == 3,
              let algorithm = hash["algorithm"] as? String,
              let canonicalization = hash["canonicalization"] as? String,
              let hashValue = hash["value"] as? String,
              algorithm == "sha256",
              canonicalization == "rfc8785",
              hashValue.count == 64,
              hashValue.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 || $0 >= 97 && $0 <= 102 })
        else {
            throw PortableProfileArtifactError.invalidContentHash
        }

        let knownFields: Set<String> = [
            "schema", "version", "artifactVersion", "exportedAt", "profiles",
            "activeProfileID", "defaultProfileID", "profileKeyBindings",
            "profileOutputBindings", "catalogRevision", "contentHash",
        ]
        let reservedNormalized: Set<String> = [
            "schema", "version", "artifactversion", "exportedat", "profiles",
            "activeprofileid", "defaultprofileid", "profilekeybindings",
            "profileoutputbindings", "catalogrevision", "contenthash",
            "keybindings", "outputbindings",
        ]
        for key in root.keys where !knownFields.contains(key) {
            if reservedNormalized.contains(normalizedFieldName(key)) {
                throw PortableProfileArtifactError.reservedExtensionField
            }
        }
        if root.keys.contains(where: { normalizedFieldName($0) == "keybindings" || normalizedFieldName($0) == "outputbindings" }) {
            throw PortableProfileArtifactError.globalBindingMapForbidden
        }

        try validatePortableValues(root)

        var summaries: [ProfileSummary] = []
        summaries.reserveCapacity(rawProfiles.count)
        var idsByLowercase: [String: UUID] = [:]
        for profile in rawProfiles {
            guard !profile.keys.contains("launchTarget") else {
                throw PortableProfileArtifactError.launchTargetForbidden
            }
            guard let idString = profile["id"] as? String,
                  let id = canonicalUUID(idString),
                  let name = profile["name"] as? String,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  name.unicodeScalars.count <= 256,
                  profile["customization"] is [String: Any]
            else {
                throw PortableProfileArtifactError.malformedProfile
            }
            let normalizedID = idString.lowercased()
            guard idsByLowercase.updateValue(id, forKey: normalizedID) == nil else {
                throw PortableProfileArtifactError.duplicateProfileID
            }
            summaries.append(ProfileSummary(id: id, name: name))
        }
        guard let active = idsByLowercase[activeString.lowercased()] else {
            throw PortableProfileArtifactError.activeProfileMissing
        }
        let defaultID: UUID?
        if let defaultString {
            guard let found = idsByLowercase[defaultString.lowercased()] else {
                throw PortableProfileArtifactError.defaultProfileMissing
            }
            defaultID = found
        } else {
            defaultID = nil
        }

        try validateBindingMaps(keyMaps, profileIDs: Set(idsByLowercase.keys), output: false)
        try validateBindingMaps(outputMaps, profileIDs: Set(idsByLowercase.keys), output: true)

        return ValidatedEnvelope(
            rawProfiles: rawProfiles,
            summaries: summaries,
            activeProfileID: active,
            defaultProfileID: defaultID,
            exportedAt: exportedAt,
            catalogRevision: CatalogRevision(controllerTemplates: 1, deviceFrames: 1, generationSpec: 1),
            contentHash: ContentHash(algorithm: algorithm, canonicalization: canonicalization, value: hashValue)
        )
    }

    private static func validateBindingMaps(
        _ maps: [String: Any],
        profileIDs: Set<String>,
        output: Bool
    ) throws {
        var normalizedKeys = Set<String>()
        for (profileID, rawBindings) in maps {
            let normalized = profileID.lowercased()
            guard canonicalUUID(profileID) != nil, normalizedKeys.insert(normalized).inserted else {
                throw PortableProfileArtifactError.duplicateBindingProfileID
            }
            guard profileIDs.contains(normalized) else {
                throw PortableProfileArtifactError.bindingProfileMissing
            }
            guard let bindings = rawBindings as? [String: Any], bindings.count <= 128 else {
                throw PortableProfileArtifactError.invalidBindingMap
            }
            for value in bindings.values {
                guard let binding = value as? [String: Any] else {
                    throw PortableProfileArtifactError.invalidBindingMap
                }
                if output {
                    try validateOutputBinding(binding)
                } else {
                    try validateKeyBinding(binding)
                }
            }
        }
    }

    private static func validateKeyBinding(_ binding: [String: Any]) throws {
        guard unsignedInteger(binding["keyCode"], maximum: UInt64(UInt16.max)) != nil else {
            throw PortableProfileArtifactError.invalidBindingMap
        }
        try validateModifiers(in: binding)
        if let rawSequence = binding["sequence"], !(rawSequence is NSNull) {
            guard let sequence = rawSequence as? [[String: Any]], sequence.count <= 32 else {
                throw PortableProfileArtifactError.invalidBindingMap
            }
            for stroke in sequence {
                guard unsignedInteger(stroke["keyCode"], maximum: UInt64(UInt16.max)) != nil else {
                    throw PortableProfileArtifactError.invalidBindingMap
                }
                try validateModifiers(in: stroke)
            }
        }
    }

    private static func validateModifiers(in binding: [String: Any]) throws {
        if binding["modifiers"] != nil, binding["modifiersRawValue"] != nil {
            throw PortableProfileArtifactError.invalidBindingMap
        }
        if let modifiers = binding["modifiers"] ?? binding["modifiersRawValue"],
           unsignedInteger(modifiers, maximum: UInt64(UInt8.max)) == nil {
            throw PortableProfileArtifactError.invalidBindingMap
        }
    }

    private static func validateOutputBinding(_ binding: [String: Any]) throws {
        if let keyboard = binding["keyboard"], !(keyboard is NSNull) {
            guard let object = keyboard as? [String: Any] else {
                throw PortableProfileArtifactError.invalidBindingMap
            }
            try validateKeyBinding(object)
        }
        if let gamepadButtons = binding["gamepadButtons"] {
            guard let values = gamepadButtons as? [String], values.count <= 32 else {
                throw PortableProfileArtifactError.invalidBindingMap
            }
        }
    }

    private static func validatePortableValues(_ root: [String: Any]) throws {
        var pending: [Any] = []
        pending.reserveCapacity(64)
        for (key, value) in root {
            // Known envelope metadata is still traversed, but portability checks concern keys.
            if isForbiddenFieldName(key), !(value is NSNull) {
                throw PortableProfileArtifactError.forbiddenField
            }
            pending.append(value)
        }
        while let value = pending.popLast() {
            if let object = value as? [String: Any] {
                for (key, child) in object {
                    if isForbiddenFieldName(key), !(child is NSNull) {
                        throw PortableProfileArtifactError.forbiddenField
                    }
                    pending.append(child)
                }
            } else if let array = value as? [Any] {
                pending.append(contentsOf: array)
            }
        }
    }

    private static func canonicalUUID(_ string: String) -> UUID? {
        guard string.utf8.count == 36, let uuid = UUID(uuidString: string),
              uuid.uuidString.lowercased() == string.lowercased()
        else { return nil }
        return uuid
    }

    private static func exactInteger(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, !isBoolean(number) else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded(.towardZero) == double,
              double >= Double(Int64.min), double <= Double(Int64.max)
        else { return nil }
        return number.int64Value
    }

    private static func unsignedInteger(_ value: Any?, maximum: UInt64) -> UInt64? {
        guard let integer = exactInteger(value), integer >= 0, UInt64(integer) <= maximum else { return nil }
        return UInt64(integer)
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func normalizedFieldName(_ value: String) -> String {
        String(value.unicodeScalars.filter { scalar in
            scalar.value < 128 && (CharacterSet.alphanumerics.contains(scalar))
        }).lowercased()
    }

    private static func isForbiddenFieldName(_ value: String) -> Bool {
        let normalized = normalizedFieldName(value)
        let forbidden: Set<String> = [
            "accountid", "apikey", "authorization", "bookmarkdata", "clientid",
            "clientsecret", "cookie", "credential", "credentials", "data", "deviceid",
            "deviceidentifier", "devicename", "filepath", "hostname", "iconpngdata",
            "launchtarget", "pairingcode", "password", "path", "process", "processid",
            "processidentifier", "privatekey", "secret", "serveraddress", "serverid",
            "sessionkey", "thumbnaildata", "trustedclient", "trustedclients",
        ]
        return forbidden.contains(normalized)
            || normalized.hasSuffix("token")
            || normalized.hasSuffix("secret")
            || normalized.hasSuffix("password")
            || normalized.hasSuffix("privatekey")
            || normalized.hasSuffix("filepath")
            || normalized.hasSuffix("url")
            || normalized.contains("authorization")
            || normalized.hasSuffix("bookmarkdata")
            || normalized.hasSuffix("iconpngdata")
            || normalized.hasSuffix("imagedata")
            || normalized.hasSuffix("thumbnaildata")
            || normalized.hasSuffix("binarydata")
    }
}

public enum PortableProfileArtifactError: Error, Equatable, Sendable, LocalizedError {
    case tooLarge
    case invalidUTF8
    case byteOrderMarkForbidden
    case invalidJSON
    case trailingGarbage(offset: Int)
    case depthExceeded(offset: Int)
    case containerTooLarge(offset: Int)
    case keyTooLarge(offset: Int)
    case stringTooLarge(offset: Int)
    case duplicateObjectKey(offset: Int)
    case malformedEscape(offset: Int)
    case loneSurrogate(offset: Int)
    case unescapedControlCharacter(offset: Int)
    case integerOutOfRange(offset: Int)
    case invalidNumber(offset: Int)
    case invalidEnvelope
    case unsupportedSchema
    case unsupportedSchemaVersion
    case unsupportedArtifactVersion
    case unsupportedCatalogRevision
    case invalidContentHash
    case contentHashMismatch
    case invalidProfileCount
    case malformedProfile
    case duplicateProfileID
    case activeProfileMissing
    case defaultProfileMissing
    case bindingProfileMissing
    case duplicateBindingProfileID
    case invalidBindingMap
    case globalBindingMapForbidden
    case reservedExtensionField
    case forbiddenField
    case launchTargetForbidden
    case canonicalizationFailed
    case typedProfileInvalid
    case typedProfileMismatch

    public var errorDescription: String? {
        switch self {
        case .tooLarge: "The portable profile artifact exceeds the size limit."
        case .invalidUTF8: "The portable profile artifact is not strict UTF-8."
        case .byteOrderMarkForbidden: "A byte-order mark is not permitted."
        case .invalidJSON: "The portable profile artifact contains invalid JSON."
        case .trailingGarbage: "The portable profile artifact has trailing content."
        case .depthExceeded: "The portable profile artifact is nested too deeply."
        case .containerTooLarge: "A portable profile artifact container has too many entries."
        case .keyTooLarge: "A portable profile artifact object key is too large."
        case .stringTooLarge: "A portable profile artifact string is too large."
        case .duplicateObjectKey: "A portable profile artifact object contains a duplicate key."
        case .malformedEscape: "A portable profile artifact string contains an invalid escape."
        case .loneSurrogate: "A portable profile artifact string contains an unpaired surrogate."
        case .unescapedControlCharacter: "A portable profile artifact string contains an unescaped control character."
        case .integerOutOfRange: "A portable profile artifact integer exceeds I-JSON bounds."
        case .invalidNumber: "A portable profile artifact number is invalid."
        case .unsupportedSchema: "The portable profile artifact schema is unsupported."
        case .unsupportedSchemaVersion: "The portable profile artifact schema version is unsupported."
        case .unsupportedArtifactVersion: "The portable profile artifact version is unsupported."
        case .unsupportedCatalogRevision: "The portable profile artifact catalog revision is unsupported."
        case .invalidContentHash: "The portable profile artifact hash metadata is invalid."
        case .contentHashMismatch: "The portable profile artifact content hash does not match."
        case .invalidProfileCount: "The portable profile artifact has an invalid profile count."
        case .malformedProfile: "The portable profile artifact contains a malformed profile."
        case .duplicateProfileID: "The portable profile artifact contains duplicate profile IDs."
        case .activeProfileMissing: "The portable profile artifact active profile is missing."
        case .defaultProfileMissing: "The portable profile artifact default profile is missing."
        case .bindingProfileMissing: "A portable profile artifact binding map references a missing profile."
        case .duplicateBindingProfileID: "Portable profile artifact binding maps contain duplicate profile IDs."
        case .invalidBindingMap: "The portable profile artifact contains an invalid binding map."
        case .globalBindingMapForbidden: "Authority-global binding maps are not portable."
        case .reservedExtensionField: "The portable profile artifact contains a reserved extension field."
        case .forbiddenField: "The portable profile artifact contains a nonportable field."
        case .launchTargetForbidden: "Portable profile artifacts cannot contain launch targets."
        case .canonicalizationFailed: "The portable profile artifact could not be canonicalized."
        case .typedProfileInvalid: "A portable profile could not be decoded."
        case .typedProfileMismatch: "A decoded portable profile does not match its raw identity."
        case .invalidEnvelope: "The portable profile artifact envelope is invalid."
        }
    }
}

private enum PortableArtifactCanonicalizer {
    // Audited fixed routine: JSON.parse is applied only to the scanned data string; no artifact
    // bytes are evaluated as source. Array order is retained, object keys use JavaScript's UTF-16
    // lexical order, and JSON.stringify supplies ECMAScript number/string serialization (RFC 8785).
    private static let source = """
    (function () {
      function canonicalize(value) {
        if (Array.isArray(value)) {
          return '[' + value.map(canonicalize).join(',') + ']';
        }
        if (value !== null && typeof value === 'object') {
          return '{' + Object.keys(value).sort().map(function (key) {
            return JSON.stringify(key) + ':' + canonicalize(value[key]);
          }).join(',') + '}';
        }
        return JSON.stringify(value);
      }
      return function canonicalizePortableArtifact(text) {
        var root = JSON.parse(text);
        delete root.exportedAt;
        delete root.contentHash;
        return canonicalize(root);
      };
    })()
    """

    static func canonicalize(_ data: Data) throws -> Data {
        guard let text = String(data: data, encoding: .utf8), let context = JSContext() else {
            throw PortableProfileArtifactError.canonicalizationFailed
        }
        var exception = false
        context.exceptionHandler = { _, _ in exception = true }
        guard let function = context.evaluateScript(source), !exception,
              let result = function.call(withArguments: [text]), !exception,
              let canonical = result.toString()
        else {
            throw PortableProfileArtifactError.canonicalizationFailed
        }
        return Data(canonical.utf8)
    }
}

/// Iterative lexical/structural validation avoids recursive decoder work at the trust boundary.
private final class PortableJSONScanner {
    private enum Kind { case object, array }
    private enum State { case objectKeyOrEnd, objectColon, objectValue, objectCommaOrEnd, arrayValueOrEnd, arrayCommaOrEnd }
    private struct Frame {
        var kind: Kind
        var state: State
        var count: Int
        var keys: Set<String>
    }

    private let bytes: [UInt8]
    private var index = 0
    private var frames: [Frame] = []
    private var rootComplete = false

    init(data: Data) {
        bytes = Array(data)
    }

    func scan() throws {
        guard String(bytes: bytes, encoding: .utf8) != nil else {
            throw PortableProfileArtifactError.invalidUTF8
        }
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            throw PortableProfileArtifactError.byteOrderMarkForbidden
        }
        skipWhitespace()
        guard index < bytes.count else { throw PortableProfileArtifactError.invalidJSON }
        try consumeValue()
        while !rootComplete {
            guard let frame = frames.last else { throw PortableProfileArtifactError.invalidJSON }
            switch frame.state {
            case .objectKeyOrEnd:
                skipWhitespace()
                if consumeIf(0x7D) {
                    guard frame.count == 0 else { throw PortableProfileArtifactError.invalidJSON }
                    try closeContainer(expected: .object)
                    continue
                }
                guard peek() == 0x22 else { throw PortableProfileArtifactError.invalidJSON }
                let offset = index
                let key = try consumeString(returnDecoded: true)
                guard key.utf8.count <= 256 else { throw PortableProfileArtifactError.keyTooLarge(offset: bounded(offset)) }
                guard frames[frames.count - 1].keys.insert(key).inserted else {
                    throw PortableProfileArtifactError.duplicateObjectKey(offset: bounded(offset))
                }
                frames[frames.count - 1].state = .objectColon
            case .objectColon:
                skipWhitespace()
                guard consumeIf(0x3A) else { throw PortableProfileArtifactError.invalidJSON }
                frames[frames.count - 1].state = .objectValue
            case .objectValue:
                skipWhitespace()
                try consumeValue()
            case .objectCommaOrEnd:
                skipWhitespace()
                if consumeIf(0x7D) { try closeContainer(expected: .object) }
                else if consumeIf(0x2C) { frames[frames.count - 1].state = .objectKeyOrEnd }
                else { throw PortableProfileArtifactError.invalidJSON }
            case .arrayValueOrEnd:
                skipWhitespace()
                if consumeIf(0x5D) {
                    guard frame.count == 0 else { throw PortableProfileArtifactError.invalidJSON }
                    try closeContainer(expected: .array)
                } else {
                    try consumeValue()
                }
            case .arrayCommaOrEnd:
                skipWhitespace()
                if consumeIf(0x5D) { try closeContainer(expected: .array) }
                else if consumeIf(0x2C) { frames[frames.count - 1].state = .arrayValueOrEnd }
                else { throw PortableProfileArtifactError.invalidJSON }
            }
        }
        skipWhitespace()
        guard index == bytes.count else {
            throw PortableProfileArtifactError.trailingGarbage(offset: bounded(index))
        }
    }

    private func consumeValue() throws {
        guard index < bytes.count else { throw PortableProfileArtifactError.invalidJSON }
        switch bytes[index] {
        case 0x7B:
            try beginContainer(kind: .object, state: .objectKeyOrEnd)
        case 0x5B:
            try beginContainer(kind: .array, state: .arrayValueOrEnd)
        case 0x22:
            let offset = index
            _ = try consumeString(returnDecoded: false)
            if index - offset > 256 * 1024 + 2 {
                // Escapes can make the source larger than decoded output, so consumeString owns
                // the authoritative decoded-byte check. This branch is intentionally only fast-path.
            }
            try completeValue()
        case 0x74:
            try consumeLiteral("true")
            try completeValue()
        case 0x66:
            try consumeLiteral("false")
            try completeValue()
        case 0x6E:
            try consumeLiteral("null")
            try completeValue()
        case 0x2D, 0x30...0x39:
            try consumeNumber()
            try completeValue()
        default:
            throw PortableProfileArtifactError.invalidJSON
        }
    }

    private func beginContainer(kind: Kind, state: State) throws {
        let offset = index
        index += 1
        guard frames.count < 64 else {
            throw PortableProfileArtifactError.depthExceeded(offset: bounded(offset))
        }
        frames.append(Frame(kind: kind, state: state, count: 0, keys: []))
    }

    private func closeContainer(expected: Kind) throws {
        guard let frame = frames.popLast(), frame.kind == expected else {
            throw PortableProfileArtifactError.invalidJSON
        }
        try completeValue()
    }

    private func completeValue() throws {
        guard !frames.isEmpty else {
            rootComplete = true
            return
        }
        let last = frames.count - 1
        switch frames[last].state {
        case .objectValue:
            frames[last].count += 1
            guard frames[last].count <= 4_096 else {
                throw PortableProfileArtifactError.containerTooLarge(offset: bounded(index))
            }
            frames[last].state = .objectCommaOrEnd
        case .arrayValueOrEnd:
            frames[last].count += 1
            guard frames[last].count <= 4_096 else {
                throw PortableProfileArtifactError.containerTooLarge(offset: bounded(index))
            }
            frames[last].state = .arrayCommaOrEnd
        default:
            throw PortableProfileArtifactError.invalidJSON
        }
    }

    private func consumeString(returnDecoded: Bool) throws -> String {
        let start = index
        guard consumeIf(0x22) else { throw PortableProfileArtifactError.invalidJSON }
        var decodedBytes = 0
        var output = Data()
        if returnDecoded { output.reserveCapacity(64) }
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x22 {
                index += 1
                guard decodedBytes <= 256 * 1024 else {
                    throw PortableProfileArtifactError.stringTooLarge(offset: bounded(start))
                }
                return returnDecoded ? String(decoding: output, as: UTF8.self) : ""
            }
            if byte < 0x20 {
                throw PortableProfileArtifactError.unescapedControlCharacter(offset: bounded(index))
            }
            if byte == 0x5C {
                let escapeOffset = index
                index += 1
                guard index < bytes.count else {
                    throw PortableProfileArtifactError.malformedEscape(offset: bounded(escapeOffset))
                }
                let escaped = bytes[index]
                index += 1
                switch escaped {
                case 0x22, 0x5C, 0x2F:
                    decodedBytes += 1
                    if returnDecoded { output.append(escaped) }
                case 0x62:
                    decodedBytes += 1; if returnDecoded { output.append(0x08) }
                case 0x66:
                    decodedBytes += 1; if returnDecoded { output.append(0x0C) }
                case 0x6E:
                    decodedBytes += 1; if returnDecoded { output.append(0x0A) }
                case 0x72:
                    decodedBytes += 1; if returnDecoded { output.append(0x0D) }
                case 0x74:
                    decodedBytes += 1; if returnDecoded { output.append(0x09) }
                case 0x75:
                    let first = try consumeHexScalar(offset: escapeOffset)
                    let scalarValue: UInt32
                    if (0xD800...0xDBFF).contains(first) {
                        guard index + 2 <= bytes.count, bytes[index] == 0x5C, bytes[index + 1] == 0x75 else {
                            throw PortableProfileArtifactError.loneSurrogate(offset: bounded(escapeOffset))
                        }
                        index += 2
                        let second = try consumeHexScalar(offset: escapeOffset)
                        guard (0xDC00...0xDFFF).contains(second) else {
                            throw PortableProfileArtifactError.loneSurrogate(offset: bounded(escapeOffset))
                        }
                        scalarValue = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                    } else if (0xDC00...0xDFFF).contains(first) {
                        throw PortableProfileArtifactError.loneSurrogate(offset: bounded(escapeOffset))
                    } else {
                        scalarValue = first
                    }
                    guard let scalar = Unicode.Scalar(scalarValue) else {
                        throw PortableProfileArtifactError.malformedEscape(offset: bounded(escapeOffset))
                    }
                    let encoded = String(scalar).utf8
                    decodedBytes += encoded.count
                    if returnDecoded { output.append(contentsOf: encoded) }
                default:
                    throw PortableProfileArtifactError.malformedEscape(offset: bounded(escapeOffset))
                }
            } else {
                let length = utf8ScalarLength(byte)
                guard length > 0, index + length <= bytes.count else {
                    throw PortableProfileArtifactError.invalidUTF8
                }
                decodedBytes += length
                if returnDecoded { output.append(contentsOf: bytes[index..<(index + length)]) }
                index += length
            }
            guard decodedBytes <= 256 * 1024 else {
                throw PortableProfileArtifactError.stringTooLarge(offset: bounded(start))
            }
        }
        throw PortableProfileArtifactError.invalidJSON
    }

    private func consumeHexScalar(offset: Int) throws -> UInt32 {
        guard index + 4 <= bytes.count else {
            throw PortableProfileArtifactError.malformedEscape(offset: bounded(offset))
        }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let byte = bytes[index]
            index += 1
            let digit: UInt32
            switch byte {
            case 0x30...0x39: digit = UInt32(byte - 0x30)
            case 0x41...0x46: digit = UInt32(byte - 0x41 + 10)
            case 0x61...0x66: digit = UInt32(byte - 0x61 + 10)
            default: throw PortableProfileArtifactError.malformedEscape(offset: bounded(offset))
            }
            value = value * 16 + digit
        }
        return value
    }

    private func consumeNumber() throws {
        let start = index
        if consumeIf(0x2D), index >= bytes.count { throw PortableProfileArtifactError.invalidNumber(offset: bounded(start)) }
        if consumeIf(0x30) {
            if let next = peek(), (0x30...0x39).contains(next) {
                throw PortableProfileArtifactError.invalidNumber(offset: bounded(start))
            }
        } else {
            guard let first = peek(), (0x31...0x39).contains(first) else {
                throw PortableProfileArtifactError.invalidNumber(offset: bounded(start))
            }
            while let next = peek(), (0x30...0x39).contains(next) { index += 1 }
        }
        var isInteger = true
        if consumeIf(0x2E) {
            isInteger = false
            guard let next = peek(), (0x30...0x39).contains(next) else {
                throw PortableProfileArtifactError.invalidNumber(offset: bounded(start))
            }
            while let next = peek(), (0x30...0x39).contains(next) { index += 1 }
        }
        if let next = peek(), next == 0x65 || next == 0x45 {
            isInteger = false
            index += 1
            if let sign = peek(), sign == 0x2B || sign == 0x2D { index += 1 }
            guard let digit = peek(), (0x30...0x39).contains(digit) else {
                throw PortableProfileArtifactError.invalidNumber(offset: bounded(start))
            }
            while let digit = peek(), (0x30...0x39).contains(digit) { index += 1 }
        }
        let token = String(decoding: bytes[start..<index], as: UTF8.self)
        guard let value = Double(token), value.isFinite else {
            throw PortableProfileArtifactError.invalidNumber(offset: bounded(start))
        }
        if isInteger {
            let magnitude = token.first == "-" ? String(token.dropFirst()) : token
            let trimmed = String(magnitude.drop(while: { $0 == "0" }))
            if trimmed.count > 16 || (trimmed.count == 16 && trimmed > "9007199254740991") {
                throw PortableProfileArtifactError.integerOutOfRange(offset: bounded(start))
            }
        }
    }

    private func consumeLiteral(_ literal: StaticString) throws {
        let text = String(describing: literal)
        let target = Array(text.utf8)
        guard index + target.count <= bytes.count,
              Array(bytes[index..<(index + target.count)]) == target
        else { throw PortableProfileArtifactError.invalidJSON }
        index += target.count
    }

    private func skipWhitespace() {
        while index < bytes.count && (bytes[index] == 0x20 || bytes[index] == 0x09 || bytes[index] == 0x0A || bytes[index] == 0x0D) {
            index += 1
        }
    }

    private func consumeIf(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private func peek() -> UInt8? { index < bytes.count ? bytes[index] : nil }

    private func utf8ScalarLength(_ first: UInt8) -> Int {
        if first < 0x80 { return 1 }
        if first >= 0xC2 && first <= 0xDF { return 2 }
        if first >= 0xE0 && first <= 0xEF { return 3 }
        if first >= 0xF0 && first <= 0xF4 { return 4 }
        return 0
    }

    private func bounded(_ offset: Int) -> Int { min(max(offset, 0), PortableProfileArtifact.maximumBytes) }
}
