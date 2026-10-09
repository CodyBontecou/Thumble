import Foundation

/// Pure binding/output transformations shared by the standalone CLI and the
/// constrained configuration bridge. Persistence, revisions, and timestamps
/// remain the caller's responsibility.
enum MacConfigurationBindings {
    struct SavedBindings {
        var profileKeys: [UUID: [KeypadElementID: MacKeyBinding]]
        var profileOutputs: [UUID: [KeypadElementID: MacControlOutputBinding]]
    }

    struct EditorUndoSnapshot: Equatable {
        var keyBindings: [KeypadElementID: MacKeyBinding]
        var outputBindings: [KeypadElementID: MacControlOutputBinding]
        var gamepadCustomization: GamepadCustomization
        var gamepadProfiles: [GamepadConfigurationProfile]
        var activeGamepadProfileID: UUID
        var defaultGamepadProfileID: UUID
        var profileKeyBindings: [UUID: [KeypadElementID: MacKeyBinding]]
        var profileOutputBindings: [UUID: [KeypadElementID: MacControlOutputBinding]]
        var profileSources: [UUID: ThumbleBridgeJSONValue]
    }

    static func checkedEditorUndoUpdate(_ snapshot: EditorUndoSnapshot) throws -> ProfileUpdate {
        let encoder = JSONEncoder()
        let catalog = try encodedProfileState(snapshot.gamepadProfiles, activeProfileID: snapshot.activeGamepadProfileID,
            defaultProfileID: snapshot.defaultGamepadProfileID, preserving: snapshot.profileSources)
        return try decodeProfileUpdate(profileState: catalog, activeCustomization: encoder.encode(snapshot.gamepadCustomization), bindingDomain: [
            "PocketPadMac.keyBindings.v2": try encoder.encode(rawKeyBindings(snapshot.keyBindings)),
            "PocketPadMac.outputBindings.v1": try encoder.encode(rawOutputs(snapshot.outputBindings)),
            "PocketPadMac.profileKeyBindings.v1": try encoder.encode(Dictionary(uniqueKeysWithValues: snapshot.profileKeyBindings.map { ($0.key.uuidString, rawKeyBindings($0.value)) })),
            "PocketPadMac.profileOutputBindings.v1": try encoder.encode(Dictionary(uniqueKeysWithValues: snapshot.profileOutputBindings.map { ($0.key.uuidString, rawOutputs($0.value)) }))
        ])
    }

    struct ProfileUpdate {
        let state: GamepadConfigurationProfilePersistence.LoadedState
        let bindings: SavedBindings
        let profileSources: [UUID: ThumbleBridgeJSONValue]
    }

    struct KeypadExportEnvelope: Codable {
        var schema = ThumbleKeypadConfigurationExport.schemaIdentifier
        var version = ThumbleKeypadConfigurationExport.currentVersion
        var exportedAt = Date.currentMilliseconds
        var profiles: [GamepadConfigurationProfile]
        var activeProfileID: UUID?
        var defaultProfileID: UUID?
        var profileKeyBindings: [String: [String: MacKeyBinding]]
        var profileOutputBindings: [String: [String: MacControlOutputBinding]]
        var profileSources: [UUID: ThumbleBridgeJSONValue] = [:]

        init(
            profiles: [GamepadConfigurationProfile],
            activeProfileID: UUID?,
            defaultProfileID: UUID?,
            profileKeyBindings: [String: [String: MacKeyBinding]],
            profileOutputBindings: [String: [String: MacControlOutputBinding]],
            preserving profileSources: [UUID: ThumbleBridgeJSONValue] = [:]
        ) {
            self.profiles = profiles
            self.activeProfileID = activeProfileID
            self.defaultProfileID = defaultProfileID
            self.profileKeyBindings = profileKeyBindings
            self.profileOutputBindings = profileOutputBindings
            self.profileSources = profileSources
        }

        init(from decoder: Decoder) throws {
            let shared = try ThumbleKeypadConfigurationExport(from: decoder)
            schema = shared.schema
            version = shared.version
            exportedAt = shared.exportedAt
            profiles = shared.profiles
            activeProfileID = shared.activeProfileID
            defaultProfileID = shared.defaultProfileID
            let container = try decoder.container(keyedBy: CodingKeys.self)
            profileKeyBindings = container.contains(.profileKeyBindings) ? try container.decode([String: [String: MacKeyBinding]].self, forKey: .profileKeyBindings) : [:]
            profileOutputBindings = container.contains(.profileOutputBindings) ? try container.decode([String: [String: MacControlOutputBinding]].self, forKey: .profileOutputBindings) : [:]
            profileSources = try MacConfigurationBindings.profileSources(container.decode([ThumbleBridgeJSONValue].self, forKey: .profiles), matching: profiles)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(schema, forKey: .schema)
            try container.encode(version, forKey: .version)
            try container.encode(exportedAt, forKey: .exportedAt)
            try container.encode(MacConfigurationBindings.profileValues(profiles, preserving: profileSources), forKey: .profiles)
            try container.encodeIfPresent(activeProfileID, forKey: .activeProfileID)
            try container.encodeIfPresent(defaultProfileID, forKey: .defaultProfileID)
            try container.encode(profileKeyBindings, forKey: .profileKeyBindings)
            try container.encode(profileOutputBindings, forKey: .profileOutputBindings)
        }

        private enum CodingKeys: String, CodingKey {
            case schema, version, exportedAt, profiles, activeProfileID, defaultProfileID, profileKeyBindings, profileOutputBindings
        }
    }

    /// Parse completely before the app changes maps, releases holds or saves.
    static func decodeKeypadImport(data: Data, sourceName: String) throws -> KeypadExportEnvelope {
        do { return try decodeValidatedKeypadImport(data: data, sourceName: sourceName) }
        catch {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "Unsupported or obsolete Thumble configuration. Recreate the setup with element UUIDs and explicit bindings. \(GamepadSavedConfigurationError.diagnostic(error))"])
        }
    }

    private static func decodeValidatedKeypadImport(data: Data, sourceName: String) throws -> KeypadExportEnvelope {
        let hasEnvelope = try ThumbleKeypadConfigurationExport.validateImportBoundary(data)
        let decoder = JSONDecoder()
        let raw = try decoder.decodeUnique(ThumbleBridgeJSONValue.self, from: data)
        var imported: KeypadExportEnvelope
        if hasEnvelope {
            imported = try decoder.decode(KeypadExportEnvelope.self, from: data)
        } else if let generated = try? decoder.decode(GeneratedGameKeypadProfile.self, from: data) {
            var generatedBindings = generated.profile.initialMacOutputBindings.keyboardBindings
            for (id, spec) in generated.keyBindings {
                guard let binding = MacKeyBinding(generatedSpec: spec) else {
                    let rawBinding = (spec.modifiers + [spec.key]).joined(separator: "+")
                    throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "Unsupported generated binding for \(id.displayName): \(rawBinding)"])
                }
                generatedBindings[id] = binding
            }
            guard case .object(let fields) = raw, let source = fields["profile"] else { throw CocoaError(.fileReadCorruptFile) }
            imported = KeypadExportEnvelope(
                profiles: [generated.profile.normalized],
                activeProfileID: generated.profile.id,
                defaultProfileID: nil,
                profileKeyBindings: [generated.profile.id.uuidString: rawKeyBindings(generatedBindings)],
                profileOutputBindings: [generated.profile.id.uuidString: rawOutputs(applyingKeyboardBindings(generatedBindings, to: generated.profile.initialMacOutputBindings))],
                preserving: try profileSources([source], matching: [generated.profile])
            )
        } else if let profile = try? decoder.decode(GamepadConfigurationProfile.self, from: data) {
            imported = KeypadExportEnvelope(profiles: [profile.normalized], activeProfileID: profile.id, defaultProfileID: nil, profileKeyBindings: [:], profileOutputBindings: [:], preserving: try profileSources([raw], matching: [profile]))
        } else if let profiles = try? decoder.decode([GamepadConfigurationProfile].self, from: data), !profiles.isEmpty {
            guard case .array(let sources) = raw else { throw CocoaError(.fileReadCorruptFile) }
            imported = KeypadExportEnvelope(profiles: profiles.map(\.normalized), activeProfileID: profiles[0].id, defaultProfileID: nil, profileKeyBindings: [:], profileOutputBindings: [:], preserving: try profileSources(sources, matching: profiles))
        } else if let customization = try? decoder.decode(GamepadCustomization.self, from: data) {
            let trimmedName = sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
            let profile = GamepadConfigurationProfile(name: trimmedName.isEmpty ? "Imported Setup" : trimmedName, primaryCustomization: customization.normalized)
            guard case .object(var fields) = try decoder.decodeUnique(ThumbleBridgeJSONValue.self, from: JSONEncoder().encode(profile)) else { throw CocoaError(.fileReadCorruptFile) }
            fields["customization"] = raw
            imported = KeypadExportEnvelope(profiles: [profile], activeProfileID: profile.id, defaultProfileID: nil, profileKeyBindings: [:], profileOutputBindings: [:], preserving: try profileSources([.object(fields)], matching: [profile]))
        } else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "This file is not a supported Thumble setup, configuration, or customization JSON file."])
        }
        try ThumbleKeypadConfigurationExport.validateProfileReferences(profiles: imported.profiles, activeProfileID: imported.activeProfileID, defaultProfileID: imported.defaultProfileID)
        guard let activeID = imported.activeProfileID else { throw CocoaError(.fileReadCorruptFile) }
        let state = GamepadConfigurationProfilePersistence.LoadedState(profiles: imported.profiles, activeProfileID: activeID, defaultProfileID: imported.defaultProfileID ?? activeID)
        let domain: [String: Any] = [
            "PocketPadMac.profileKeyBindings.v1": try JSONEncoder().encode(imported.profileKeyBindings),
            "PocketPadMac.profileOutputBindings.v1": try JSONEncoder().encode(imported.profileOutputBindings)
        ]
        let bindings = try loadSavedBindings(from: domain, state: state)
        var checked = imported
        checked.profileKeyBindings = Dictionary(uniqueKeysWithValues: bindings.profileKeys.map { ($0.key.uuidString, rawKeyBindings($0.value)) })
        checked.profileOutputBindings = Dictionary(uniqueKeysWithValues: bindings.profileOutputs.map { ($0.key.uuidString, rawOutputs($0.value)) })
        return checked
    }

    /// Validate the complete catalog and maps before selecting an export subset.
    /// Safe future fields follow the current source, never a same-ID predecessor.
    static func keypadExportData(profiles: [GamepadConfigurationProfile], activeProfileID: UUID, defaultProfileID: UUID,
        exportingProfileID: UUID?, bindings: SavedBindings, preserving sources: [UUID: ThumbleBridgeJSONValue]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var envelope = KeypadExportEnvelope(profiles: profiles, activeProfileID: activeProfileID, defaultProfileID: defaultProfileID,
            profileKeyBindings: Dictionary(uniqueKeysWithValues: bindings.profileKeys.map { ($0.key.uuidString, rawKeyBindings($0.value)) }),
            profileOutputBindings: Dictionary(uniqueKeysWithValues: bindings.profileOutputs.map { ($0.key.uuidString, rawOutputs($0.value)) }), preserving: sources)
        let complete = try encoder.encode(envelope)
        _ = try decodeKeypadImport(data: complete, sourceName: "export")
        guard let exportingProfileID else { return complete }
        guard let profile = profiles.first(where: { $0.id == exportingProfileID }) else { throw CocoaError(.fileNoSuchFile) }
        envelope.profiles = [profile]
        envelope.activeProfileID = profile.id
        envelope.defaultProfileID = defaultProfileID == profile.id ? profile.id : nil
        envelope.profileKeyBindings = envelope.profileKeyBindings.filter { UUID(uuidString: $0.key) == profile.id }
        envelope.profileOutputBindings = envelope.profileOutputBindings.filter { UUID(uuidString: $0.key) == profile.id }
        return try encoder.encode(envelope)
    }

    /// External updates obey the same complete-domain contract as saved data.
    /// Nothing from the previous active setup may repair an invalid update.
    static func decodeProfileUpdate(
        profileState: Data,
        activeCustomization: Data?,
        bindingDomain: [String: Any]
    ) throws -> ProfileUpdate {
        let state = try GamepadConfigurationProfilePersistence.decodeSavedState(profileState)
        if let activeCustomization {
            _ = try GamepadCustomizationPersistence.decodeSavedCustomization(activeCustomization)
        }
        let bindings = try loadSavedBindings(from: bindingDomain, state: state)
        let sources = try decodedProfileSources(profileState, matching: state)
        return ProfileUpdate(state: state, bindings: bindings, profileSources: sources)
    }

    /// Sources belong to this complete, checked incoming catalog, never to a
    /// previous profile which happens to have the same UUID.
    static func decodedProfileSources(_ data: Data, matching state: GamepadConfigurationProfilePersistence.LoadedState) throws -> [UUID: ThumbleBridgeJSONValue] {
        let value = try JSONDecoder().decodeUnique(ThumbleBridgeJSONValue.self, from: data)
        guard case .object(let fields) = value, case .array(let profiles) = fields["profiles"], profiles.count == state.profiles.count else {
            throw GamepadSavedConfigurationError.invalid("profile sources must match the validated catalog")
        }
        return try profileSources(profiles, matching: state.profiles)
    }

    static func profileSources(_ values: [ThumbleBridgeJSONValue], matching profiles: [GamepadConfigurationProfile]) throws -> [UUID: ThumbleBridgeJSONValue] {
        let declared = Set(profiles.map(\.id))
        guard values.count == profiles.count, declared.count == profiles.count else {
            throw GamepadSavedConfigurationError.invalid("profile sources must match the validated catalog")
        }
        var sources: [UUID: ThumbleBridgeJSONValue] = [:]
        for raw in values {
            guard case .object(let fields) = raw, case .string(let value) = fields["id"], let id = UUID(uuidString: value), declared.contains(id), sources[id] == nil else {
                throw GamepadSavedConfigurationError.invalid("profile sources must contain unique declared profile UUIDs")
            }
            sources[id] = raw
        }
        return sources
    }

    static func profileValues(_ profiles: [GamepadConfigurationProfile], preserving sources: [UUID: ThumbleBridgeJSONValue]) throws -> [ThumbleBridgeJSONValue] {
        try profiles.map { profile in
            if let source = sources[profile.id] {
                return try ThumbleConfigurationBridge.preservingProfileMetadata(source, after: profile)
            }
            return try JSONDecoder().decodeUnique(ThumbleBridgeJSONValue.self, from: JSONEncoder().encode(profile))
        }
    }

    static func encodedProfileState(_ profiles: [GamepadConfigurationProfile], activeProfileID: UUID, defaultProfileID: UUID, preserving sources: [UUID: ThumbleBridgeJSONValue]) throws -> Data {
        let raw = ThumbleBridgeJSONValue.object([
            "profiles": .array(try profileValues(profiles, preserving: sources)),
            "activeProfileID": .string(activeProfileID.uuidString), "defaultProfileID": .string(defaultProfileID.uuidString)])
        let data = try JSONEncoder().encode(raw)
        // Authoring may change known fields, but must not bypass the saved-domain
        // validation or silently normalize duplicate/dangling declarations.
        _ = try GamepadConfigurationProfilePersistence.decodeSavedState(data)
        return data
    }

    /// Local lifecycle operations may remove previously validated owners. Remove
    /// only those deleted UUIDs; an owner retained by another executable canvas
    /// keeps its maps, and malformed/unrelated keys are left for strict rejection.
    static func removeDeletedOwnerReferences(previous: GamepadConfigurationProfile, current: GamepadConfigurationProfile,
        keys: inout [String: MacKeyBinding], outputs: inout [String: MacControlOutputBinding]) {
        guard previous.id == current.id else { return }
        func owners(_ profile: GamepadConfigurationProfile) -> Set<KeypadElementID> {
            var ids = Set(profile.customization.elements.map(\.inputID))
            if let landscape = profile.landscapeCustomization { ids.formUnion(landscape.elements.map(\.inputID)) }
            if let portrait = profile.portraitCustomization { ids.formUnion(portrait.elements.map(\.inputID)) }
            return ids
        }
        let removed = owners(previous).subtracting(owners(current))
        for key in Array(keys.keys) where KeypadElementID(rawValue: key).map(removed.contains) == true { keys.removeValue(forKey: key) }
        for key in Array(outputs.keys) where KeypadElementID(rawValue: key).map(removed.contains) == true { outputs.removeValue(forKey: key) }
    }

    /// Validate the entire saved domain before filtering or deriving any maps.
    /// Missing maps may derive from their own profile; invalid maps never do.
    static func loadSavedBindings(
        from domain: [String: Any],
        state: GamepadConfigurationProfilePersistence.LoadedState
    ) throws -> SavedBindings {
        if domain["PocketPadMac.keyBindings.v1"] != nil {
            throw GamepadSavedConfigurationError.invalid("obsolete v1 binding storage is not supported")
        }
        let declared = Dictionary(uniqueKeysWithValues: state.profiles.map { profile in
            var ids = Set(profile.customization.elements.map(\.inputID))
            if let landscape = profile.landscapeCustomization { ids.formUnion(landscape.elements.map(\.inputID)) }
            if let portrait = profile.portraitCustomization { ids.formUnion(portrait.elements.map(\.inputID)) }
            return (profile.id, ids)
        })
        func decode<T: Decodable>(_ key: String, as type: T.Type) throws -> T? {
            guard let value = domain[key] else { return nil }
            guard let data = value as? Data else { throw GamepadSavedConfigurationError.invalid("\(key) must contain JSON data") }
            do { return try JSONDecoder().decodeUnique(type, from: data) }
            catch { throw GamepadSavedConfigurationError.invalid("\(key): \(GamepadSavedConfigurationError.diagnostic(error))") }
        }
        func validated<T>(_ raw: [String: T], profileID: UUID) throws -> [KeypadElementID: T] {
            guard let ids = declared[profileID] else { throw GamepadSavedConfigurationError.invalid("binding map references an undeclared profile UUID") }
            var result: [KeypadElementID: T] = [:]
            for (key, value) in raw {
                guard let id = KeypadElementID(rawValue: key), ids.contains(id), result[id] == nil else {
                    throw GamepadSavedConfigurationError.invalid("binding maps must reference unique declared element UUIDs; named input slots are not supported")
                }
                result[id] = value
            }
            return result
        }
        func validatedProfiles<T>(_ raw: [String: [String: T]]) throws -> [UUID: [KeypadElementID: T]] {
            var result: [UUID: [KeypadElementID: T]] = [:]
            for (key, values) in raw {
                guard let id = UUID(uuidString: key), result[id] == nil else {
                    throw GamepadSavedConfigurationError.invalid("binding maps must reference unique profile UUIDs")
                }
                result[id] = try validated(values, profileID: id)
            }
            return result
        }
        var keys = try validatedProfiles(decode("PocketPadMac.profileKeyBindings.v1", as: [String: [String: MacKeyBinding]].self) ?? [:])
        var outputs = try validatedProfiles(decode("PocketPadMac.profileOutputBindings.v1", as: [String: [String: MacControlOutputBinding]].self) ?? [:])
        if let raw = try decode("PocketPadMac.keyBindings.v2", as: [String: MacKeyBinding].self) {
            _ = try validated(raw, profileID: state.activeProfileID)
        }
        if let raw = try decode("PocketPadMac.outputBindings.v1", as: [String: MacControlOutputBinding].self) {
            _ = try validated(raw, profileID: state.activeProfileID)
        }
        for profile in state.profiles {
            var ownedOutputs = effectiveOutputs(
                for: profile.outputMode,
                keyBindings: keys[profile.id] ?? [:],
                customOutputs: outputs[profile.id] ?? profile.initialMacOutputBindings
            )
            ownedOutputs.merge(profile.configuredMacOutputBindings, uniquingKeysWith: { _, owned in owned })
            outputs[profile.id] = ownedOutputs
            keys[profile.id] = ownedOutputs.keyboardBindings
        }
        return SavedBindings(profileKeys: keys, profileOutputs: outputs)
    }

    static func resolvedKeyBindings(
        for profileID: UUID,
        in profileKeyBindings: [UUID: [KeypadElementID: MacKeyBinding]],
        fallback: [KeypadElementID: MacKeyBinding]
    ) -> [KeypadElementID: MacKeyBinding] {
        profileKeyBindings[profileID] ?? fallback
    }

    static func resolvedOutputBindings(
        for profileID: UUID,
        in profileOutputBindings: [UUID: [KeypadElementID: MacControlOutputBinding]],
        fallback: [KeypadElementID: MacControlOutputBinding]
    ) -> [KeypadElementID: MacControlOutputBinding] {
        profileOutputBindings[profileID] ?? fallback
    }

    static func decodedKeyBindings(
        _ raw: [String: MacKeyBinding]?
    ) -> [KeypadElementID: MacKeyBinding]? {
        guard let raw else { return nil }
        var bindings: [KeypadElementID: MacKeyBinding] = [:]
        for (key, binding) in raw {
            guard let id = KeypadElementID(rawValue: key), bindings[id] == nil else { return nil }
            bindings[id] = binding
        }
        return bindings
    }

    static func rawKeyBindings(
        _ bindings: [KeypadElementID: MacKeyBinding]
    ) -> [String: MacKeyBinding] {
        Dictionary(uniqueKeysWithValues: bindings.map { button, binding in
            (button.rawValue, binding)
        })
    }

    static func keyboardOutputs(
        from keyBindings: [KeypadElementID: MacKeyBinding]
    ) -> [KeypadElementID: MacControlOutputBinding] {
        Dictionary(uniqueKeysWithValues: keyBindings.map { button, binding in
            (button, MacControlOutputBinding.keyboard(binding))
        })
    }

    static func applyingKeyboardBindings(
        _ bindings: [KeypadElementID: MacKeyBinding],
        to ownedOutputs: [KeypadElementID: MacControlOutputBinding]
    ) -> [KeypadElementID: MacControlOutputBinding] {
        var outputs = ownedOutputs
        for (id, keyboard) in bindings {
            var output = outputs[id] ?? MacControlOutputBinding()
            output.keyboard = keyboard
            outputs[id] = output
        }
        return outputs
    }

    static func effectiveOutputs(
        for mode: GamepadProfileOutputMode,
        keyBindings: [KeypadElementID: MacKeyBinding],
        customOutputs: [KeypadElementID: MacControlOutputBinding]
    ) -> [KeypadElementID: MacControlOutputBinding] {
        // Output mode filters at press time; it must not replace a control's
        // configured bindings with a global controller mapping.
        var outputs = customOutputs
        for (id, keyboard) in keyBindings where outputs[id] == nil {
            outputs[id] = .keyboard(keyboard)
        }
        return outputs
    }

    static func decodedOutputs(
        _ raw: [String: MacControlOutputBinding]?
    ) -> [KeypadElementID: MacControlOutputBinding]? {
        guard let raw else { return nil }
        var bindings: [KeypadElementID: MacControlOutputBinding] = [:]
        for (key, binding) in raw {
            guard let id = KeypadElementID(rawValue: key), bindings[id] == nil else { return nil }
            bindings[id] = binding
        }
        return bindings
    }

    static func rawOutputs(
        _ bindings: [KeypadElementID: MacControlOutputBinding]
    ) -> [String: MacControlOutputBinding] {
        Dictionary(uniqueKeysWithValues: bindings.map { button, binding in
            (button.rawValue, binding)
        })
    }

    static func resetAllOutputs(
        in profile: inout GamepadConfigurationProfile
    ) -> [KeypadElementID: MacControlOutputBinding] {
        let outputs = profile.recommendedMacOutputBindings
        synchronizeElementOutputs(in: &profile, outputs: outputs)
        profile.outputMode = .keyboard
        profile.updatedAt = Date.currentMilliseconds
        return outputs
    }

    static func synchronizeElementOutputs(
        in profile: inout GamepadConfigurationProfile,
        outputs: [KeypadElementID: MacControlOutputBinding]
    ) {
        func update(_ customization: inout GamepadCustomization) {
            var normalizedCustomization = customization.normalized
            for index in normalizedCustomization.elements.indices {
                let id = normalizedCustomization.elements[index].inputID
                normalizedCustomization.elements[index].setOutputBinding(
                    outputs[id]?.sharedBinding,
                    for: .primary
                )
            }
            customization = normalizedCustomization.normalized
        }

        update(&profile.customization)
        if var landscape = profile.landscapeCustomization {
            update(&landscape)
            profile.landscapeCustomization = landscape
        }
        if var portrait = profile.portraitCustomization {
            update(&portrait)
            profile.portraitCustomization = portrait
        }
    }
}
