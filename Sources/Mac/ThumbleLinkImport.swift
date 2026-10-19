import Foundation

/// Shared by the Mac sheet and CLI. Builds an ordinary authority import; never writes state itself.
enum ThumbleLinkImport {
    struct Row: Identifiable, Sendable {
        let command: String
        let label: String
        let key: String?
        let issue: String?
        var note: String? = nil
        var id: String { command }
    }

    struct Plan: Sendable {
        let snapshot: ThumbleLinkSnapshot
        let profileName: String
        let isRefresh: Bool
        let rows: [Row]
        let warnings: [String]
        let configurationData: Data
        let baseConfiguration: Data

        func requireUnchangedConfiguration(_ data: Data) throws {
            let before = try MacConfigurationBindings.decodeKeypadImport(data: baseConfiguration, sourceName: "Before")
            let after = try MacConfigurationBindings.decodeKeypadImport(data: data, sourceName: "After")
            guard before.profiles == after.profiles, before.profileSources == after.profileSources,
                  before.profileKeyBindings == after.profileKeyBindings,
                  before.profileOutputBindings == after.profileOutputBindings else {
                throw ThumbleLinkError("Your setups changed after review. Review this export again before importing.")
            }
        }
    }

    private struct LinkMetadata: Codable {
        let snapshot: ThumbleLinkSnapshot
        /// Retain past commands so deleted phone controls stay deleted across refreshes.
        let managedLabels: [String: String]
        let importedAt: Int64
    }

    static func prepare(text: String, currentConfiguration: Data, name: String? = nil) throws -> Plan {
        let snapshot = try ThumbleLinkSnapshot.parse(text)
        let current = try MacConfigurationBindings.decodeKeypadImport(data: currentConfiguration, sourceName: "Current Setups")
        let existing = current.profiles.first { $0.id == snapshot.profileID }
        let previous = try metadata(for: existing, sources: current.profileSources)
        if let previous, previous.snapshot.character.id != snapshot.character.id {
            throw ThumbleLinkError("This setup belongs to a different WoW character.")
        }
        let profileName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? existing?.name ?? snapshot.suggestedName
        guard !profileName.isEmpty, profileName.count <= 128,
              !profileName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !current.profiles.contains(where: { $0.id != snapshot.profileID && $0.name.caseInsensitiveCompare(profileName) == .orderedSame }) else {
            throw ThumbleLinkError("Choose a unique setup name of 1–128 characters. An unrelated setup already using this name will not be replaced.")
        }
        let rows = snapshot.actions.map(resolve)
        guard existing != nil || rows.contains(where: { $0.key != nil }) else {
            throw ThumbleLinkError("No supported keyboard bindings were found. Bind an action to a keyboard key in WoW, then export again.")
        }
        var profile = existing ?? GamepadConfigurationProfile(id: snapshot.profileID, name: profileName,
            customization: GamepadCustomization(elements: []))
        if existing != nil {
            let raw = current.profileOutputBindings[profile.id.uuidString] ?? [:]
            let outputs = Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in
                KeypadElementID(rawValue: key).map { ($0, value) }
            })
            MacConfigurationBindings.synchronizeElementOutputs(in: &profile, outputs: outputs)
        }
        profile.name = profileName
        profile.outputMode = .keyboard
        let oldLabels = previous?.managedLabels ?? [:]
        var warnings = snapshot.warnings
        warnings.append("Snapshot only: re-export after changing WoW bindings, bars, forms, or characters. Ability pictures and cooldowns are not synchronized in version 1.")
        warnings.append("Keyboard output uses Mac physical key positions based on a US layout. Test punctuation on your keyboard layout.")
        if existing != nil { warnings.append("Refresh preserves positions, styling, deleted controls, and manually edited labels or outputs. Unchanged imported outputs are refreshed; missing bindings are cleared.") }
        try update(&profile.customization, snapshot: snapshot, rows: rows, previousLabels: oldLabels, portrait: false)
        if var landscape = profile.landscapeCustomization {
            try update(&landscape, snapshot: snapshot, rows: rows, previousLabels: oldLabels, portrait: false)
            profile.landscapeCustomization = landscape
        }
        if var portrait = profile.portraitCustomization {
            try update(&portrait, snapshot: snapshot, rows: rows, previousLabels: oldLabels, portrait: true)
            profile.portraitCustomization = portrait
        } else if existing == nil {
            var portrait = GamepadCustomization(deviceCanvas: GamepadDeviceCanvas(frameID: "iphone-17-pro-portrait"), elements: [])
            try update(&portrait, snapshot: snapshot, rows: rows, previousLabels: oldLabels, portrait: true)
            profile.portraitCustomization = portrait
        }
        profile.updatedAt = Date.currentMilliseconds
        var labels = oldLabels
        let boundCommands = Set(rows.filter { $0.key != nil }.map(\.command))
        for action in snapshot.actions where boundCommands.contains(action.command) || oldLabels[action.command] != nil {
            labels[action.command] = action.label
        }
        var source: ThumbleBridgeJSONValue
        if let existingSource = current.profileSources[profile.id] { source = existingSource }
        else { source = try JSONDecoder().decode(ThumbleBridgeJSONValue.self, from: JSONEncoder().encode(profile)) }
        guard case .object(var fields) = source else { throw ThumbleLinkError("The existing setup metadata could not be read.") }
        fields["thumbleLink"] = try JSONDecoder().decode(ThumbleBridgeJSONValue.self,
            from: JSONEncoder().encode(LinkMetadata(snapshot: snapshot, managedLabels: labels, importedAt: Date.currentMilliseconds)))
        source = .object(fields)
        let outputs = profile.initialMacOutputBindings
        let envelope = MacConfigurationBindings.KeypadExportEnvelope(profiles: [profile], activeProfileID: profile.id,
            defaultProfileID: nil,
            profileKeyBindings: [profile.id.uuidString: MacConfigurationBindings.rawKeyBindings(outputs.keyboardBindings)],
            profileOutputBindings: [profile.id.uuidString: MacConfigurationBindings.rawOutputs(outputs)],
            preserving: [profile.id: source])
        let data = try JSONEncoder().encode(envelope)
        // Run the same import boundary before either caller can mutate authority state.
        _ = try MacConfigurationBindings.decodeKeypadImport(data: data, sourceName: profileName)
        var reviewedRows = rows
        for index in reviewedRows.indices {
            let row = reviewedRows[index]
            let id = snapshot.elementID(for: row.command)
            if let element = profile.customization.elements.first(where: { $0.id == id }) {
                if element.output != element.defaultOutput {
                    let actual = element.output.flatMap(KeypadBindingFormatter.format)?.compactText ?? "Unmapped"
                    reviewedRows[index].note = "Keeping your phone output: \(actual)"
                }
            } else if oldLabels[row.command] != nil {
                reviewedRows[index].note = "Keeping this phone control deleted"
            }
        }
        return Plan(snapshot: snapshot, profileName: profileName, isRefresh: existing != nil,
                    rows: reviewedRows, warnings: warnings, configurationData: data, baseConfiguration: currentConfiguration)
    }

    private static func metadata(for profile: GamepadConfigurationProfile?, sources: [UUID: ThumbleBridgeJSONValue]) throws -> LinkMetadata? {
        guard let profile else { return nil }
        guard case .object(let fields) = sources[profile.id], let value = fields["thumbleLink"],
              let metadata = try? JSONDecoder().decode(LinkMetadata.self, from: JSONEncoder().encode(value)),
              metadata.snapshot.profileID == profile.id else {
            throw ThumbleLinkError("The matching setup has no valid Thumble Link metadata. It will not be overwritten.")
        }
        return metadata
    }

    private static func resolve(_ action: ThumbleLinkSnapshot.Action) -> Row {
        if let reason = action.unavailableReason { return Row(command: action.command, label: action.label, key: nil, issue: reason) }
        if let key = action.keys.first(where: { ThumbleLinkKeyBinding.resolve($0) != nil }) {
            return Row(command: action.command, label: action.label, key: key, issue: nil)
        }
        return Row(command: action.command, label: action.label, key: nil,
                   issue: action.keys.isEmpty ? "Unbound in WoW" : "Unsupported keys: \(action.keys.joined(separator: ", "))")
    }

    private static func update(_ customization: inout GamepadCustomization, snapshot: ThumbleLinkSnapshot,
                               rows: [Row], previousLabels: [String: String], portrait: Bool) throws {
        var result = customization.normalized
        let actions = Dictionary(uniqueKeysWithValues: snapshot.actions.map { ($0.command, $0) })
        let resolved = Dictionary(uniqueKeysWithValues: rows.map { ($0.command, $0) })
        let managed = Set(previousLabels.keys).union(actions.keys)
        let commandsByID = Dictionary(uniqueKeysWithValues: managed.map { (snapshot.elementID(for: $0), $0) })
        var present = Set<UUID>()
        for index in result.elements.indices {
            let id = result.elements[index].id
            present.insert(id)
            guard let command = commandsByID[id] else { continue }
            let row = resolved[command]
            let output = KeypadElementOutputBinding(keyboard: row?.key.flatMap(ThumbleLinkKeyBinding.resolve))
            // The default is the last imported baseline, so explicit user edits win.
            if result.elements[index].output == result.elements[index].defaultOutput {
                result.elements[index].output = output
            }
            result.elements[index].defaultOutput = output
            if let old = previousLabels[command],
               result.elements[index].label == String(old.trimmingCharacters(in: .whitespacesAndNewlines).prefix(GamepadCustomization.maximumLabelLength)),
               let label = row?.label {
                result.elements[index].label = label
                result.elements[index].presentation = GamepadControlPresentation(actionID: "wow.\(command.lowercased())",
                    caption: label, accessibilityName: label)
            }
        }
        let additions = rows.filter { $0.key != nil && !present.contains(snapshot.elementID(for: $0.command)) && previousLabels[$0.command] == nil }
        guard result.elements.count + additions.count <= GamepadCustomization.maximumCustomButtons else {
            throw ThumbleLinkError("This refresh would exceed the setup’s 128-control limit. Export fewer action bars.")
        }
        let total = max(1, result.elements.count + additions.count)
        let columns = portrait ? min(4, total) : min(8, total)
        let rowCount = (total + columns - 1) / columns
        for row in additions {
            let index = result.elements.count
            let output = KeypadElementOutputBinding(keyboard: row.key.flatMap(ThumbleLinkKeyBinding.resolve))
            let layout = GamepadButtonCustomization(centerX: 0.08 + 0.84 * (CGFloat(index % columns) + 0.5) / CGFloat(columns),
                centerY: 0.16 + 0.76 * (CGFloat(index / columns) + 0.5) / CGFloat(rowCount),
                widthScale: portrait ? 0.9 : 1.0, heightScale: 0.8, shape: .roundedRectangle)
            result.elements.append(KeypadElement(id: snapshot.elementID(for: row.command), label: row.label,
                layout: layout, output: output, defaultOutput: output,
                presentation: GamepadControlPresentation(actionID: "wow.\(row.command.lowercased())",
                    caption: row.label, accessibilityName: row.label)))
        }
        // Sync legacy appearance mirrors from canonical elements, preserving unrelated controls.
        let importedIDs = Set(commandsByID.keys)
        result.customButtons.removeAll { importedIDs.contains($0.id) }
        for id in importedIDs { result.labelOverrides.removeValue(forKey: KeypadElementID(id)); result.buttonCustomizations.removeValue(forKey: KeypadElementID(id)) }
        result.updatedAt = Date.currentMilliseconds
        customization = result.normalized
    }
}
