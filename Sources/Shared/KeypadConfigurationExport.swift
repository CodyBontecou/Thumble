import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Thumble's versioned JSON format for saving and sharing keypad setup layouts.
///
/// There is not a broadly adopted interchange format for Thumble-style multitouch
/// keypad layouts, so exports use this app-owned schema identifier and version.
/// The macOS CLI may add Mac-only shortcut binding data next to these fields, while
/// iOS exports include the layout/profile state that the phone can actually use.
public struct ThumbleKeypadConfigurationExport: Codable, Equatable, Sendable {
    public static let schemaIdentifier = "com.codybontecou.pocketpad.keypad-configuration"
    /// Version 4 adds installed-skin references and per-orientation appearance baselines.
    public static let currentVersion = 4

    public var schema: String
    public var version: Int
    public var exportedAt: Int64
    public var profiles: [GamepadConfigurationProfile]
    public var activeProfileID: UUID?
    public var defaultProfileID: UUID?

    public init(
        schema: String = Self.schemaIdentifier,
        version: Int = Self.currentVersion,
        exportedAt: Int64 = Date.currentMilliseconds,
        profiles: [GamepadConfigurationProfile],
        activeProfileID: UUID?,
        defaultProfileID: UUID?
    ) {
        let state = GamepadConfigurationProfilePersistence.normalizedState(
            profiles: profiles,
            activeProfileID: activeProfileID,
            defaultProfileID: defaultProfileID
        )
        self.schema = schema
        self.version = version
        self.exportedAt = exportedAt
        self.profiles = state.profiles
        self.activeProfileID = state.activeProfileID
        self.defaultProfileID = state.defaultProfileID
    }

    public init(from decoder: Decoder) throws {
        try KeypadElementSchema.requireUUIDBindingKeys(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(String.self, forKey: .schema)
        version = try container.decode(Int.self, forKey: .version)

        guard schema == Self.schemaIdentifier else {
            throw DecodingError.dataCorruptedError(
                forKey: .schema,
                in: container,
                debugDescription: "Unsupported Thumble keypad configuration schema: \(schema)"
            )
        }
        guard version == Self.currentVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "Unsupported Thumble keypad configuration version: \(version)"
            )
        }

        exportedAt = try container.decodeIfPresent(Int64.self, forKey: .exportedAt) ?? Date.currentMilliseconds
        let decodedProfiles = try container.decode([GamepadConfigurationProfile].self, forKey: .profiles)
        guard !decodedProfiles.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .profiles,
                in: container,
                debugDescription: "Thumble keypad configuration export must contain at least one profile."
            )
        }
        let decodedActiveID = try container.decodeIfPresent(UUID.self, forKey: .activeProfileID)
        let decodedDefaultID = try container.decodeIfPresent(UUID.self, forKey: .defaultProfileID)
        try Self.validateProfileReferences(profiles: decodedProfiles, activeProfileID: decodedActiveID, defaultProfileID: decodedDefaultID)
        try KeypadElementSchema.requireProfileBindingOwners(from: decoder, profiles: decodedProfiles)
        profiles = decodedProfiles.map(\.normalized)
        activeProfileID = decodedActiveID
        defaultProfileID = decodedDefaultID
    }

    /// Shared native/CLI byte boundary. A failed envelope or artifact is never
    /// reinterpreted as a raw profile just because its unknown fields disappear.
    static func validateImportBoundary(_ data: Data) throws -> Bool {
        guard data.count <= PortableProfileArtifact.maximumBytes else { throw PortableProfileArtifactError.tooLarge }
        try JSONDecoder.validateUniqueKeys(in: data)
        guard let shape = try? JSONDecoder().decode(ImportShape.self, from: data) else { return false }
        if shape.hasArtifact { _ = try PortableProfileArtifact(validating: data) }
        if shape.hasEnvelope { _ = try JSONDecoder().decode(Self.self, from: data) }
        return shape.hasEnvelope
    }

    static func validateProfileReferences(
        profiles: [GamepadConfigurationProfile],
        activeProfileID: UUID?,
        defaultProfileID: UUID?
    ) throws {
        let ids = Set(profiles.map(\.id))
        guard !profiles.isEmpty, ids.count == profiles.count,
              let activeProfileID, ids.contains(activeProfileID),
              defaultProfileID.map(ids.contains) ?? true else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "A configuration must contain unique profile UUIDs and declared active/default references; incompatible references are not repaired."))
        }
    }

    private struct ImportShape: Decodable {
        let hasArtifact: Bool
        let hasEnvelope: Bool

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Fields.self)
            hasArtifact = container.contains(.artifactVersion) || container.contains(.contentHash) || container.contains(.catalogRevision)
            hasEnvelope = !container.allKeys.isEmpty
        }

        private enum Fields: String, CodingKey {
            case schema, version, profiles, activeProfileID, defaultProfileID
            case profileKeyBindings, profileOutputBindings, artifactVersion, contentHash, catalogRevision
        }
    }

    func normalizedProfileState(
        fallbackCustomization: GamepadCustomization = .defaultValue
    ) -> GamepadConfigurationProfilePersistence.LoadedState {
        GamepadConfigurationProfilePersistence.normalizedState(
            profiles: profiles,
            activeProfileID: activeProfileID,
            defaultProfileID: defaultProfileID,
            fallbackCustomization: fallbackCustomization
        )
    }

    public static func suggestedFilename(activeProfileName: String? = nil) -> String {
        let name = activeProfileName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = name?.isEmpty == false ? name! : "keypads"
        let safeName = sanitizedFilenameComponent(baseName)
        return "Thumble-\(safeName).json"
    }

    private static func sanitizedFilenameComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).union(.whitespaces)
        let replacement = UnicodeScalar("-")
        let scalars = value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? scalar : replacement
        }
        let collapsedWhitespace = String(String.UnicodeScalarView(scalars))
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: "-")
        let collapsedDashes = collapsedWhitespace.replacingOccurrences(
            of: "-+",
            with: "-",
            options: String.CompareOptions.regularExpression
        )
        let trimmed = collapsedDashes.trimmingCharacters(in: CharacterSet(charactersIn: "-_. "))
        return trimmed.isEmpty ? "keypads" : trimmed
    }

    private enum CodingKeys: String, CodingKey {
        case schema
        case version
        case exportedAt
        case profiles
        case activeProfileID
        case defaultProfileID
    }
}

public struct ThumbleKeypadConfigurationJSONDocument: FileDocument {
    public static var readableContentTypes: [UTType] { [.json] }
    public static var writableContentTypes: [UTType] { [.json] }

    public var export: ThumbleKeypadConfigurationExport

    public init(export: ThumbleKeypadConfigurationExport) {
        self.export = export
    }

    public init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        _ = try ThumbleKeypadConfigurationExport.validateImportBoundary(data)
        export = try JSONDecoder().decodeUnique(ThumbleKeypadConfigurationExport.self, from: data)
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(export)
        return FileWrapper(regularFileWithContents: data)
    }
}
