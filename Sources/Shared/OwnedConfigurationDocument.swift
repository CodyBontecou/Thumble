import Foundation

/// Explicit v5 interchange reader. The original bytes are authoritative; native
/// profiles are display/edit preparation only and must not be re-exported as v4.
public struct ThumbleOwnedConfigurationDocument {
    public static let version = 5
    public static let maximumBytes = 8 * 1024 * 1024
    private let storage: Storage
    public var originalData: Data { storage.data }
    public var projectedProfiles: [GamepadConfigurationProfile] { storage.profiles }
    public var activeProfileID: UUID { storage.active }
    public var defaultProfileID: UUID? { storage.defaultID }

    public enum ReadError: Error { case invalidEnvelope, invalidProfile, tooLarge }
    private final class Storage {
        let data: Data
        let profiles: [GamepadConfigurationProfile]
        let active: UUID
        let defaultID: UUID?
        init(data: Data, profiles: [GamepadConfigurationProfile], active: UUID, defaultID: UUID?) {
            self.data = data; self.profiles = profiles; self.active = active; self.defaultID = defaultID
        }
    }
    public init(validating data: Data) throws {
        storage = try Workspace(data).decode()
    }
    private final class Workspace {
        let data: Data
        var root: [String: Any] = [:]
        var profiles: [GamepadConfigurationProfile] = []
        init(_ data: Data) { self.data = data }
        func decode() throws -> Storage {
            guard data.count <= maximumBytes else { throw ReadError.tooLarge }
            guard !data.starts(with: [0xef, 0xbb, 0xbf]) else { throw ReadError.invalidEnvelope }
            try JSONDecoder.validateUniqueKeys(in: data)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ReadError.invalidEnvelope }
            self.root = root
            try validateEnvelope()
            try decodeProfiles()
            guard let text = root["activeProfileID"] as? String, let active = PortableProfileArtifact.canonicalUUID(text),
                  root.keys.contains("defaultProfileID") else { throw ReadError.invalidEnvelope }
            let defaultID: UUID?
            if root["defaultProfileID"] is NSNull { defaultID = nil }
            else {
                guard let text = root["defaultProfileID"] as? String, let id = PortableProfileArtifact.canonicalUUID(text) else { throw ReadError.invalidEnvelope }
                defaultID = id
            }
            try ThumbleKeypadConfigurationExport.validateProfileReferences(profiles: profiles, activeProfileID: active, defaultProfileID: defaultID)
            try validateBindings(active: active)
            return Storage(data: data, profiles: profiles, active: active, defaultID: defaultID)
        }
        private func validateEnvelope() throws {
            guard root["schema"] as? String == ThumbleKeypadConfigurationExport.schemaIdentifier,
                  PortableProfileArtifact.exactInteger(root["version"]) == 5 else { throw ReadError.invalidEnvelope }
            let known = ["schema", "version", "exportedAt", "profiles", "activeProfileID", "defaultProfileID", "keyBindings", "outputBindings", "profileKeyBindings", "profileOutputBindings"]
            let forbidden = ["serverid", "trustedclients", "authtoken", "artifactversion", "contenthash", "catalogrevision"]
            for key in root.keys {
                guard !forbidden.contains(normalized(key)), !hasReservedAlias(key, known: known) else { throw ReadError.invalidEnvelope }
            }
            if let time = root["exportedAt"] {
                guard let time = PortableProfileArtifact.exactInteger(time), time >= 0 else { throw ReadError.invalidEnvelope }
            }
        }
        private func decodeProfiles() throws {
            guard let records = root["profiles"] as? [[String: Any]], (1...256).contains(records.count) else { throw ReadError.invalidEnvelope }
            var seen = Set<UUID>()
            for record in records {
                let profile = try decodeProfile(record)
                guard seen.insert(profile.id).inserted else { throw ReadError.invalidProfile }
                profiles.append(profile)
            }
        }
        private func decodeProfile(_ record: [String: Any]) throws -> GamepadConfigurationProfile {
            let retired = ["skinReference", "skinBaselineCustomization", "landscapeSkinBaselineCustomization", "portraitSkinBaselineCustomization", "landscapeCustomization", "portraitCustomization", "orientationPreference"].map(normalized)
            let known = ["id", "name", "updatedAt", "customization", "outputMode", "launchTarget", "appearanceBank", "appearanceResourceVersion", "appearanceResources", "profileFormatVersion"]
            guard PortableProfileArtifact.exactInteger(record["profileFormatVersion"]) == 5,
                  let idText = record["id"] as? String, PortableProfileArtifact.canonicalUUID(idText) != nil,
                  let name = record["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  name.unicodeScalars.count <= 256,
                  let time = PortableProfileArtifact.exactInteger(record["updatedAt"]), time >= 0,
                  let layout = record["customization"] as? [String: Any],
                  let canvas = layout["deviceCanvas"] as? [String: Any], let frameID = canvas["frameID"] as? String,
                  let frame = GamepadEditorDeviceCatalog.frame(forStoredID: frameID), frame.isLandscape, frame.id == frameID
            else { throw ReadError.invalidProfile }
            for key in record.keys {
                guard !retired.contains(normalized(key)), !hasReservedAlias(key, known: known) else { throw ReadError.invalidProfile }
            }
            // This transient native projection is never the interchange authority.
            // Remove only its already-validated format tag; the stored source stays v5.
            var projection = record
            projection.removeValue(forKey: "profileFormatVersion")
            projection["orientationPreference"] = "landscape"
            let bytes = try JSONSerialization.data(withJSONObject: projection)
            return try JSONDecoder().decodeUnique(GamepadConfigurationProfile.self, from: bytes)
        }
        private func validateBindings(active: UUID) throws {
            let declared = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id.uuidString.lowercased(), Set($0.customization.elements.map(\.id))) })
            for (field, output) in [("profileKeyBindings", false), ("profileOutputBindings", true)] {
                if let raw = root[field] {
                    guard let maps = raw as? [String: Any], maps.count <= 512 else { throw ReadError.invalidEnvelope }
                    try PortableProfileArtifact.validateBindingMaps(maps, declaredByProfile: declared, output: output)
                }
            }
            for (field, output) in [("keyBindings", false), ("outputBindings", true)] {
                if let raw = root[field] {
                    guard let map = raw as? [String: Any] else { throw ReadError.invalidEnvelope }
                    try PortableProfileArtifact.validateBindingMaps([active.uuidString: map], declaredByProfile: declared, output: output)
                }
            }
        }
        private func normalized(_ text: String) -> String {
            String(text.unicodeScalars.filter { (65...90).contains($0.value) || (97...122).contains($0.value) || (48...57).contains($0.value) }).lowercased()
        }
        private func hasReservedAlias(_ key: String, known: [String]) -> Bool {
            known.contains { $0 != key && normalized($0) == normalized(key) }
        }
    }
}
