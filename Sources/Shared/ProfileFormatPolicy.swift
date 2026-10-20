import Foundation

/// Profile compatibility is independent of real-time input protocol v3. Keep the
/// advertised set at v4 until v5 codecs, bounds and migration are fully enabled.
public enum ProfileFormatPolicy {
    public static let legacyVersion = 4
    public static let ownedAppearanceVersion = 5
    public static let supportedFormats = [4]
    public static let updateMessage = "Update Thumble on both devices to use this keypad format. Your saved setups and edits have been kept."

    public enum Failure: Error, LocalizedError, Equatable, Sendable {
        case invalidOffer, updateRequired
        public var errorDescription: String? { ProfileFormatPolicy.updateMessage }
    }
    /// Reject an explicit future stored-profile contract before startup can
    /// normalize or rewrite it. Unmarked owned banks remain migration staging.
    static func validateStoredProfileHeader(_ decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: StoredKeys.self)
        if let version = try fields.decodeIfPresent(Int.self, forKey: .profileFormatVersion), version != legacyVersion { throw Failure.updateRequired }
    }
    private enum StoredKeys: String, CodingKey { case profileFormatVersion }
    public static func negotiate(required: Int, offered: [Int]?) throws -> Int {
        let offered = offered ?? [legacyVersion]
        guard offered.count <= 8, Set(offered).count == offered.count,
              offered.allSatisfy({ (1...65_535).contains($0) }) else { throw Failure.invalidOffer }
        guard [legacyVersion, ownedAppearanceVersion].contains(required), offered.contains(required) else { throw Failure.updateRequired }
        return required
    }
    public static func requiredVersion(profiles: [GamepadConfigurationProfile]) -> Int {
        profiles.contains { $0.appearanceBank != nil } ? ownedAppearanceVersion : legacyVersion
    }
    /// Inspect only the format header before a future profile can fail typed
    /// decoding or be flattened into an older snapshot. Compact input is unchanged.
    public static func validateIncoming(_ data: Data) throws {
        guard data.count <= ControllerWireCodec.maximumInboundPayloadSize else { throw Failure.updateRequired }
        if data.count >= 2, data[data.startIndex] == 80, data[data.startIndex + 1] == 80 { return }
        let header = try JSONDecoder().decodeUnique(Header.self, from: data)
        guard header.hasProfiles else { return }
        _ = try negotiate(required: header.required, offered: supportedFormats)
    }
    private struct Header: Decodable {
        let hasProfiles: Bool
        let required: Int
        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: Keys.self)
            hasProfiles = fields.contains(.gamepadProfiles) || fields.contains(.gamepadCustomization)
            var version = try fields.decodeIfPresent(Int.self, forKey: .profileFormatVersion) ?? legacyVersion
            guard [legacyVersion, ownedAppearanceVersion].contains(version) else { throw Failure.updateRequired }
            if fields.contains(.gamepadProfiles), !(try fields.decodeNil(forKey: .gamepadProfiles)) {
                var profiles = try fields.nestedUnkeyedContainer(forKey: .gamepadProfiles)
                var count = 0
                while !profiles.isAtEnd {
                    guard count < 256 else { throw Failure.updateRequired }
                    version = max(version, try profiles.decode(ProfileHeader.self).required)
                    count += 1
                }
            }
            required = version
        }
        enum Keys: String, CodingKey { case gamepadProfiles, gamepadCustomization, profileFormatVersion }
    }
    private struct ProfileHeader: Decodable {
        let required: Int
        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: Keys.self)
            let bank: Bool
            if fields.contains(.appearanceBank) { bank = !(try fields.decodeNil(forKey: .appearanceBank)) } else { bank = false }
            let resources = fields.contains(.appearanceResources) || fields.contains(.appearanceResourceVersion)
            let explicit = try fields.decodeIfPresent(Int.self, forKey: .profileFormatVersion) ?? legacyVersion
            guard [legacyVersion, ownedAppearanceVersion].contains(explicit) else { throw Failure.updateRequired }
            required = max(explicit, bank || resources ? ownedAppearanceVersion : legacyVersion)
        }
        enum Keys: String, CodingKey { case appearanceBank, appearanceResources, appearanceResourceVersion, profileFormatVersion }
    }
}
