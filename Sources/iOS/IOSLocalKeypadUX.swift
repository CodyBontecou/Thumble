import CoreGraphics
import Foundation
import SwiftUI

/// Stable local-only keys. These preferences are intentionally not part of the
/// controller protocol or profile payloads.
enum IOSKeypadPreferenceKeys {
    static let practiceMode = "PocketPad.iOS.practiceMode.v1"
    static let hapticIntensity = "PocketPad.iOS.keypadHapticIntensity.v1"
    static let legacyHapticsEnabled = "PocketPad.iOS.keypadHapticsEnabled.v1"
    static let showBindingGlyphs = "PocketPad.iOS.showBindingGlyphs.v1"

    static let defaultHapticIntensity = 1.0
    static let defaultShowBindingGlyphs = true
}

enum IOSRetiredPreferenceCleanup {
    /// Reach samples are separate from accepted layout changes and all keypad preferences.
    static func removeCalibration(defaults: UserDefaults = .standard) {
        let prefix = "PocketPad.iOS.thumbPlacementCalibration.v1."
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
    }
}

enum ControllerInputPath: String, CaseIterable, Sendable {
    case defaultControlID
    case elementButton
    case analogStick
    case analogTrigger
    case pointerMove
    case pointerScroll
    case pointerButton
}

enum ControllerInputSuppressionPolicy {
    static func permitsOutgoingInput(
        _ path: ControllerInputPath,
        isConnected: Bool,
        isPracticeModeEnabled: Bool
    ) -> Bool {
        _ = path // Keeping the path explicit makes new input routes auditable and testable.
        return isConnected && !isPracticeModeEnabled
    }
}

/// Immutable storage keeps the retained eight-state appearance and binary data
/// out of pending-edit inline frames. This is local recovery data, never a wire payload.
final class PendingKeypadLayoutProfileSnapshot: Codable, Equatable {
    let profile: GamepadConfigurationProfile
    init(_ profile: GamepadConfigurationProfile) { self.profile = profile }
    init(from decoder: Decoder) throws { profile = try GamepadConfigurationProfile(from: decoder) }
    func encode(to encoder: Encoder) throws { try profile.encode(to: encoder) }
    static func == (lhs: PendingKeypadLayoutProfileSnapshot, rhs: PendingKeypadLayoutProfileSnapshot) -> Bool {
        lhs === rhs || lhs.profile == rhs.profile
    }
}

struct PendingKeypadLayoutEdit: Codable, Equatable, Identifiable {
    var profileID: UUID
    var orientation: GamepadEditorDeviceOrientation
    var customization: GamepadCustomization
    /// The trusted Mac identity that owned the profile when it was edited.
    /// A nil identity is retained locally but is never uploaded automatically.
    var serverID: String?
    var updatedAt: Int64
    private(set) var recoveryProfile: PendingKeypadLayoutProfileSnapshot?

    init(
        profileID: UUID,
        orientation: GamepadEditorDeviceOrientation,
        customization: GamepadCustomization,
        serverID: String?,
        updatedAt: Int64 = Date.currentMilliseconds,
        recoveryProfile: GamepadConfigurationProfile? = nil
    ) {
        self.profileID = profileID
        self.orientation = orientation
        self.customization = customization.normalized
        self.serverID = serverID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.updatedAt = updatedAt
        self.recoveryProfile = recoveryProfile.flatMap {
            $0.id == profileID && $0.appearanceBank != nil ? PendingKeypadLayoutProfileSnapshot($0) : nil
        }
    }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        profileID = try fields.decode(UUID.self, forKey: .profileID)
        orientation = try fields.decode(GamepadEditorDeviceOrientation.self, forKey: .orientation)
        customization = try fields.decode(GamepadCustomization.self, forKey: .customization)
        serverID = try fields.decodeIfPresent(String.self, forKey: .serverID)
        updatedAt = try fields.decode(Int64.self, forKey: .updatedAt)
        recoveryProfile = try fields.decodeIfPresent(PendingKeypadLayoutProfileSnapshot.self, forKey: .recoveryProfile)
        if let saved = recoveryProfile?.profile {
            guard saved.id == profileID, saved.appearanceBank != nil else {
                throw DecodingError.dataCorruptedError(forKey: .recoveryProfile, in: fields,
                    debugDescription: "Pending layout recovery profile does not match its owner.")
            }
        }
    }
    private enum CodingKeys: String, CodingKey {
        case profileID, orientation, customization, serverID, updatedAt, recoveryProfile
    }

    var id: String { "\(serverID ?? "untrusted"):\(profileID.uuidString):\(orientation.rawValue)" }
}

struct PendingKeypadLayoutReconciliation: Equatable {
    var profiles: [GamepadConfigurationProfile]
    var remainingEdits: [PendingKeypadLayoutEdit]
    var editsToUpload: [PendingKeypadLayoutEdit]
    var acknowledgedEditIDs: [String]
}

enum PendingKeypadLayoutReconciler {
    static func reconcile(
        incomingProfiles: [GamepadConfigurationProfile],
        pendingEdits: [PendingKeypadLayoutEdit],
        authoritativeServerID: String?
    ) -> PendingKeypadLayoutReconciliation {
        ReconciliationWorkspace(
            incomingProfiles: incomingProfiles,
            pendingEdits: pendingEdits,
            authoritativeServerID: authoritativeServerID
        ).resolve()
    }

    private final class ReconciliationWorkspace {
        private let incomingProfiles: [GamepadConfigurationProfile]
        private let pendingEdits: [PendingKeypadLayoutEdit]
        private let serverID: String?
        private var profiles: [GamepadConfigurationProfile] = []
        private var remaining: [PendingKeypadLayoutEdit] = []
        private var uploads: [PendingKeypadLayoutEdit] = []
        private var acknowledged: [String] = []

        init(
            incomingProfiles: [GamepadConfigurationProfile],
            pendingEdits: [PendingKeypadLayoutEdit],
            authoritativeServerID: String?
        ) {
            self.incomingProfiles = incomingProfiles
            self.pendingEdits = pendingEdits
            serverID = authoritativeServerID?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
        }

        func resolve() -> PendingKeypadLayoutReconciliation {
            normalizeIncomingProfiles()
            reconcilePendingEdits()
            return makeResult()
        }

        private func normalizeIncomingProfiles() {
            profiles = incomingProfiles.map(\.normalized)
        }

        private func reconcilePendingEdits() {
            for edit in pendingEdits {
                reconcile(edit)
            }
        }

        private func reconcile(_ edit: PendingKeypadLayoutEdit) {
            guard isTrusted(edit) else {
                remaining.append(edit)
                return
            }
            guard let profileIndex = profiles.firstIndex(where: { $0.id == edit.profileID }) else {
                recoverMissingProfile(for: edit)
                return
            }
            if remoteProfileAcknowledges(edit, profileIndex: profileIndex) {
                acknowledged.append(edit.id)
                return
            }
            applyLocalEdit(edit, profileIndex: profileIndex)
        }

        private func isTrusted(_ edit: PendingKeypadLayoutEdit) -> Bool {
            guard let editServerID = edit.serverID, let serverID else { return false }
            return editServerID == serverID
        }

        private func recoverMissingProfile(for edit: PendingKeypadLayoutEdit) {
            // The profile was removed while the iPhone was offline. Restore
            // the edited layout as an explicit recovered copy instead of
            // retaining an invisible, permanently unsynchronizable record.
            let recovered = makeRecoveredProfile(for: edit)
            let oriented = applyRecoveredCustomization(edit, to: recovered)
            profiles.append(normalizeRecoveredProfile(oriented))
            remaining.append(edit)
            uploads.append(edit)
        }

        private func makeRecoveredProfile(
            for edit: PendingKeypadLayoutEdit
        ) -> GamepadConfigurationProfile {
            if let saved = edit.recoveryProfile?.profile { return saved }
            return GamepadConfigurationProfile(
                id: edit.profileID,
                name: "Recovered iPhone Layout",
                primaryCustomization: edit.customization,
                updatedAt: edit.updatedAt
            )
        }

        private func applyRecoveredCustomization(
            _ edit: PendingKeypadLayoutEdit,
            to profile: GamepadConfigurationProfile
        ) -> GamepadConfigurationProfile {
            var profile = profile
            profile.setCustomization(edit.customization, for: edit.orientation)
            profile.updatedAt = max(profile.updatedAt, edit.updatedAt)
            return profile
        }

        private func normalizeRecoveredProfile(
            _ profile: GamepadConfigurationProfile
        ) -> GamepadConfigurationProfile {
            profile.normalized
        }

        private func remoteProfileAcknowledges(
            _ edit: PendingKeypadLayoutEdit,
            profileIndex: Int
        ) -> Bool {
            let remoteCustomization = profiles[profileIndex]
                .customization(for: edit.orientation)
                .normalized
            return remoteCustomization.hasSamePresentation(as: edit.customization.normalized)
        }

        private func applyLocalEdit(
            _ edit: PendingKeypadLayoutEdit,
            profileIndex: Int
        ) {
            // Local pending edits win until the Mac echoes them. This prevents
            // the first reconnect snapshot from silently discarding offline work.
            profiles[profileIndex].setCustomization(edit.customization, for: edit.orientation)
            profiles[profileIndex].updatedAt = max(profiles[profileIndex].updatedAt, edit.updatedAt)
            remaining.append(edit)
            uploads.append(edit)
        }

        private func makeResult() -> PendingKeypadLayoutReconciliation {
            PendingKeypadLayoutReconciliation(
                profiles: profiles,
                remainingEdits: PendingKeypadLayoutReconciler.deduplicated(remaining),
                editsToUpload: PendingKeypadLayoutReconciler.deduplicated(uploads),
                acknowledgedEditIDs: acknowledged.sorted()
            )
        }
    }

    static func recording(
        _ edit: PendingKeypadLayoutEdit,
        in existing: [PendingKeypadLayoutEdit]
    ) -> [PendingKeypadLayoutEdit] {
        deduplicated(existing.filter { $0.id != edit.id } + [edit])
    }

    private static func deduplicated(_ edits: [PendingKeypadLayoutEdit]) -> [PendingKeypadLayoutEdit] {
        var latestByID: [String: PendingKeypadLayoutEdit] = [:]
        for edit in edits {
            if let current = latestByID[edit.id], current.updatedAt > edit.updatedAt { continue }
            latestByID[edit.id] = edit
        }
        return latestByID.values.sorted {
            if $0.updatedAt == $1.updatedAt { return $0.id < $1.id }
            return $0.updatedAt < $1.updatedAt
        }
    }
}

enum PendingKeypadLayoutPersistence {
    static let defaultsKey = "PocketPad.iOS.pendingKeypadLayoutEdits.v1"

    static func load(defaults: UserDefaults = .standard) throws -> [PendingKeypadLayoutEdit] {
        guard let stored = defaults.object(forKey: defaultsKey) else { return [] }
        guard let data = stored as? Data else { throw GamepadSavedConfigurationError.invalid("\(defaultsKey) must contain JSON data") }
        do {
            let edits = try JSONDecoder().decodeUnique([PendingKeypadLayoutEdit].self, from: data)
            guard Set(edits.map(\.id)).count == edits.count else {
                throw GamepadSavedConfigurationError.invalid("pending layouts must contain unique profile/orientation/server owners")
            }
            return edits
        } catch {
            throw GamepadSavedConfigurationError.invalid("\(defaultsKey): \(GamepadSavedConfigurationError.diagnostic(error))")
        }
    }

    static func save(_ edits: [PendingKeypadLayoutEdit], defaults: UserDefaults = .standard) {
        // A failed read is not an empty queue and cannot authorize a replacement.
        guard (try? load(defaults: defaults)) != nil,
              Set(edits.map(\.id)).count == edits.count,
              edits.allSatisfy({ Set($0.customization.elements.map(\.id)).count == $0.customization.elements.count }) else { return }
        if edits.isEmpty {
            defaults.removeObject(forKey: defaultsKey)
            return
        }
        guard let data = try? JSONEncoder().encode(edits),
              let checked = try? JSONDecoder().decodeUnique([PendingKeypadLayoutEdit].self, from: data),
              Set(checked.map(\.id)).count == checked.count else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}

/// One-time restoration for a previous app version killed during hosted practice preview.
enum IOSRetiredBuildPracticeRecovery {
    private static let forcedDefaultsKey = "PocketPad.iOS.builderPreview.forcedPractice.v1"
    private static let priorValueDefaultsKey = "PocketPad.iOS.builderPreview.priorPractice.v1"

    static func recoverPracticeModeValue(
        storedValue: Bool,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let wasForced = defaults.bool(forKey: forcedDefaultsKey)
        let restored = wasForced ? defaults.bool(forKey: priorValueDefaultsKey) : storedValue
        if wasForced { defaults.set(restored, forKey: IOSKeypadPreferenceKeys.practiceMode) }
        clear(defaults: defaults)
        return restored
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: forcedDefaultsKey)
        defaults.removeObject(forKey: priorValueDefaultsKey)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

enum KeypadHapticIntensityPolicy {
    static let supportedLevels: [Double] = [0, 0.25, 0.50, 0.75, 1]

    static func normalized(_ value: Double) -> Double {
        guard value.isFinite else { return IOSKeypadPreferenceKeys.defaultHapticIntensity }
        return min(max(value, 0), 1)
    }

    static func scaledIntensity(_ controlIntensity: CGFloat, globalIntensity: Double) -> CGFloat {
        let control = controlIntensity.isFinite ? min(max(controlIntensity, 0), 1) : 0
        return min(max(control * CGFloat(normalized(globalIntensity)), 0), 1)
    }

    static func label(for value: Double) -> String {
        let normalized = normalized(value)
        return normalized == 0 ? "Off" : "\(Int((normalized * 100).rounded()))%"
    }
}

private struct KeypadHapticIntensityEnvironmentKey: EnvironmentKey {
    static let defaultValue = IOSKeypadPreferenceKeys.defaultHapticIntensity
}

private struct KeypadShowBindingGlyphsEnvironmentKey: EnvironmentKey {
    static let defaultValue = IOSKeypadPreferenceKeys.defaultShowBindingGlyphs
}

extension EnvironmentValues {
    /// Global multiplier applied after a control's own haptic pattern/intensity.
    var keypadHapticIntensity: Double {
        get { self[KeypadHapticIntensityEnvironmentKey.self] }
        set { self[KeypadHapticIntensityEnvironmentKey.self] = KeypadHapticIntensityPolicy.normalized(newValue) }
    }

    /// Local presentation preference consumed by binding-glyph UI. It does not
    /// imply or invent any binding metadata on the wire.
    var keypadShowsBindingGlyphs: Bool {
        get { self[KeypadShowBindingGlyphsEnvironmentKey.self] }
        set { self[KeypadShowBindingGlyphsEnvironmentKey.self] = newValue }
    }
}
