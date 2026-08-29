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
    static let calibrationPrefix = "PocketPad.iOS.thumbPlacementCalibration.v1"

    static let defaultHapticIntensity = 1.0
    static let defaultShowBindingGlyphs = true
}

enum ControllerInputPath: String, CaseIterable, Sendable {
    case builtInButton
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

struct PendingKeypadLayoutEdit: Codable, Equatable, Identifiable {
    var profileID: UUID
    var orientation: GamepadEditorDeviceOrientation
    var customization: GamepadCustomization
    /// The trusted Mac identity that owned the profile when it was edited.
    /// A nil identity is retained locally but is never uploaded automatically.
    var serverID: String?
    var updatedAt: Int64

    init(
        profileID: UUID,
        orientation: GamepadEditorDeviceOrientation,
        customization: GamepadCustomization,
        serverID: String?,
        updatedAt: Int64 = Date.currentMilliseconds
    ) {
        self.profileID = profileID
        self.orientation = orientation
        self.customization = customization.normalized
        self.serverID = serverID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.updatedAt = updatedAt
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
            GamepadConfigurationProfile(
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

    static func load(defaults: UserDefaults = .standard) -> [PendingKeypadLayoutEdit] {
        guard let data = defaults.data(forKey: defaultsKey),
              let edits = try? JSONDecoder().decode([PendingKeypadLayoutEdit].self, from: data)
        else { return [] }
        return edits
    }

    static func save(_ edits: [PendingKeypadLayoutEdit], defaults: UserDefaults = .standard) {
        if edits.isEmpty {
            defaults.removeObject(forKey: defaultsKey)
            return
        }
        guard let data = try? JSONEncoder().encode(edits) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}

enum IOSBuilderArtifactAdoptionPhase: Equatable, Sendable {
    case uploading(sentChunks: Int, totalChunks: Int)
    case awaitingAuthoritativeSnapshot
    case succeeded(destinationProfileIDs: [UUID], replayed: Bool)
    case failed(ProfileArtifactAdoptionErrorCode)
}

struct IOSBuilderArtifactAdoptionState: Equatable, Sendable {
    let metadata: ProfileArtifactAdoptionMetadata
    var phase: IOSBuilderArtifactAdoptionPhase
    var pendingDestinationProfileIDs: [UUID] = []
    var replayed = false

    mutating func acceptResult(_ result: ProfileArtifactAdoptionResult) -> Bool {
        guard result.validates(against: metadata) else { return false }
        switch result.status {
        case .accepted:
            return true
        case .failed:
            phase = .failed(result.errorCode ?? .invalidEnvelope)
            pendingDestinationProfileIDs = []
        case .succeeded, .replayed:
            pendingDestinationProfileIDs = result.destinationProfileIDs
            replayed = result.status == .replayed
            phase = .awaitingAuthoritativeSnapshot
        }
        return true
    }

    mutating func observeAuthoritativeProfiles(_ profileIDs: Set<UUID>) -> Bool {
        guard !pendingDestinationProfileIDs.isEmpty,
              pendingDestinationProfileIDs.allSatisfy(profileIDs.contains)
        else { return false }
        phase = .succeeded(
            destinationProfileIDs: pendingDestinationProfileIDs,
            replayed: replayed
        )
        return true
    }
}

enum IOSBuilderArtifactPracticePersistence {
    private static let forcedDefaultsKey = "PocketPad.iOS.builderPreview.forcedPractice.v1"
    private static let priorValueDefaultsKey = "PocketPad.iOS.builderPreview.priorPractice.v1"

    static func recoverPracticeModeValue(
        storedValue: Bool,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard defaults.bool(forKey: forcedDefaultsKey) else { return storedValue }
        let priorValue = defaults.bool(forKey: priorValueDefaultsKey)
        defaults.set(priorValue, forKey: IOSKeypadPreferenceKeys.practiceMode)
        clear(defaults: defaults)
        return priorValue
    }

    static func markForced(priorValue: Bool, defaults: UserDefaults = .standard) {
        defaults.set(priorValue, forKey: priorValueDefaultsKey)
        defaults.set(true, forKey: forcedDefaultsKey)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: forcedDefaultsKey)
        defaults.removeObject(forKey: priorValueDefaultsKey)
    }
}

/// Immutable, reference-backed projection used only by the local practice renderer.
/// It never participates in authoritative profile persistence or synchronization.
final class IOSBuilderArtifactPracticePreview: @unchecked Sendable {
    private final class Storage: @unchecked Sendable {
        let profiles: [GamepadConfigurationProfile]
        init(profiles: [GamepadConfigurationProfile]) { self.profiles = profiles }
    }

    let recordID: UUID
    let selectedProfileID: UUID
    let priorPracticeModeValue: Bool
    private let storage: Storage

    var profiles: [GamepadConfigurationProfile] { storage.profiles }
    var selectedProfile: GamepadConfigurationProfile? {
        storage.profiles.first(where: { $0.id == selectedProfileID })
    }

    init(
        recordID: UUID,
        profiles: [GamepadConfigurationProfile],
        selectedProfileID: UUID,
        priorPracticeModeValue: Bool
    ) {
        self.recordID = recordID
        storage = Storage(profiles: profiles)
        self.selectedProfileID = selectedProfileID
        self.priorPracticeModeValue = priorPracticeModeValue
    }

    private init(
        recordID: UUID,
        storage: Storage,
        selectedProfileID: UUID,
        priorPracticeModeValue: Bool
    ) {
        self.recordID = recordID
        self.storage = storage
        self.selectedProfileID = selectedProfileID
        self.priorPracticeModeValue = priorPracticeModeValue
    }

    func selecting(_ profileID: UUID) -> IOSBuilderArtifactPracticePreview? {
        guard storage.profiles.contains(where: { $0.id == profileID }) else { return nil }
        return IOSBuilderArtifactPracticePreview(
            recordID: recordID,
            storage: storage,
            selectedProfileID: profileID,
            priorPracticeModeValue: priorPracticeModeValue
        )
    }
}

enum IOSBuilderArtifactPracticeTransition {
    static func begin(
        recordID: UUID,
        artifact: PortableProfileArtifact,
        currentPreview: IOSBuilderArtifactPracticePreview?,
        currentPracticeModeValue: Bool
    ) -> IOSBuilderArtifactPracticePreview? {
        guard !artifact.profiles.isEmpty else { return nil }
        let selectedID = artifact.profiles.contains(where: { $0.id == artifact.activeProfileID })
            ? artifact.activeProfileID
            : artifact.profiles[0].id
        return IOSBuilderArtifactPracticePreview(
            recordID: recordID,
            profiles: artifact.profiles,
            selectedProfileID: selectedID,
            priorPracticeModeValue: currentPreview?.priorPracticeModeValue ?? currentPracticeModeValue
        )
    }

    static func restoredPracticeModeValue(
        after preview: IOSBuilderArtifactPracticePreview
    ) -> Bool {
        preview.priorPracticeModeValue
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

enum ThumbPlacementHand: String, Codable, CaseIterable, Identifiable, Sendable {
    case left
    case right

    var id: Self { self }
    var displayName: String { rawValue.capitalized }
}

struct ThumbPlacementNormalizedPoint: Codable, Equatable, Sendable {
    var x: CGFloat
    var y: CGFloat

    init(x: CGFloat, y: CGFloat) {
        self.x = Self.clamp(x)
        self.y = Self.clamp(y)
    }

    init(_ point: CGPoint, in size: CGSize) {
        self.init(
            x: point.x / max(size.width, 1),
            y: point.y / max(size.height, 1)
        )
    }

    var cgPoint: CGPoint { CGPoint(x: x, y: y) }

    private static func clamp(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0.5 }
        return min(max(value, 0), 1)
    }
}

struct ThumbPlacementReachZone: Codable, Equatable, Identifiable, Sendable {
    var hand: ThumbPlacementHand
    var center: ThumbPlacementNormalizedPoint
    var radiusX: CGFloat
    var radiusY: CGFloat

    var id: ThumbPlacementHand { hand }

    init(
        hand: ThumbPlacementHand,
        center: ThumbPlacementNormalizedPoint,
        radiusX: CGFloat,
        radiusY: CGFloat
    ) {
        self.hand = hand
        self.center = center
        self.radiusX = Self.clampRadius(radiusX)
        self.radiusY = Self.clampRadius(radiusY)
    }

    init?(hand: ThumbPlacementHand, samples: [ThumbPlacementNormalizedPoint]) {
        guard !samples.isEmpty else { return nil }
        let minX = samples.map(\.x).min() ?? 0.5
        let maxX = samples.map(\.x).max() ?? 0.5
        let minY = samples.map(\.y).min() ?? 0.5
        let maxY = samples.map(\.y).max() ?? 0.5
        let center = ThumbPlacementNormalizedPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
        self.init(
            hand: hand,
            center: center,
            radiusX: max(0.12, (maxX - minX) / 2 + 0.055),
            radiusY: max(0.14, (maxY - minY) / 2 + 0.055)
        )
    }

    func frame(in size: CGSize) -> CGRect {
        CGRect(
            x: (center.x - radiusX) * size.width,
            y: (center.y - radiusY) * size.height,
            width: radiusX * 2 * size.width,
            height: radiusY * 2 * size.height
        )
    }

    func normalizedDistance(to point: CGPoint) -> CGFloat {
        hypot(
            (point.x - center.x) / max(radiusX, 0.001),
            (point.y - center.y) / max(radiusY, 0.001)
        )
    }

    private static func clampRadius(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0.15 }
        return min(max(value, 0.06), 0.65)
    }
}

struct ThumbPlacementCalibrationKey: Codable, Equatable, Hashable, Sendable {
    var profileID: UUID
    var deviceIdentity: String
    var displayIdentity: String
    var orientation: GamepadEditorDeviceOrientation

    var storageKey: String {
        let components = [
            IOSKeypadPreferenceKeys.calibrationPrefix,
            profileID.uuidString.lowercased(),
            Self.escaped(deviceIdentity),
            Self.escaped(displayIdentity),
            orientation.rawValue
        ]
        return components.joined(separator: ".")
    }

    private static func escaped(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return value.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
    }
}

struct ThumbPlacementCalibration: Codable, Equatable, Sendable {
    var key: ThumbPlacementCalibrationKey
    var leftSamples: [ThumbPlacementNormalizedPoint]
    var rightSamples: [ThumbPlacementNormalizedPoint]
    var updatedAt: Int64

    init(
        key: ThumbPlacementCalibrationKey,
        leftSamples: [ThumbPlacementNormalizedPoint] = [],
        rightSamples: [ThumbPlacementNormalizedPoint] = [],
        updatedAt: Int64 = Date.currentMilliseconds
    ) {
        self.key = key
        self.leftSamples = leftSamples
        self.rightSamples = rightSamples
        self.updatedAt = updatedAt
    }

    var zones: [ThumbPlacementReachZone] {
        [
            ThumbPlacementReachZone(hand: .left, samples: leftSamples),
            ThumbPlacementReachZone(hand: .right, samples: rightSamples)
        ].compactMap { $0 }
    }

    func samples(for hand: ThumbPlacementHand) -> [ThumbPlacementNormalizedPoint] {
        hand == .left ? leftSamples : rightSamples
    }

    mutating func setSamples(_ samples: [ThumbPlacementNormalizedPoint], for hand: ThumbPlacementHand) {
        let normalized = Array(samples.prefix(256))
        if hand == .left { leftSamples = normalized }
        else { rightSamples = normalized }
        updatedAt = Date.currentMilliseconds
    }
}

struct ThumbPlacementCalibrationStore {
    var defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(for key: ThumbPlacementCalibrationKey) -> ThumbPlacementCalibration? {
        guard let data = defaults.data(forKey: key.storageKey),
              let calibration = try? JSONDecoder().decode(ThumbPlacementCalibration.self, from: data),
              calibration.key == key
        else { return nil }
        return calibration
    }

    func save(_ calibration: ThumbPlacementCalibration) {
        guard let data = try? JSONEncoder().encode(calibration) else { return }
        defaults.set(data, forKey: calibration.key.storageKey)
    }

    func remove(for key: ThumbPlacementCalibrationKey) {
        defaults.removeObject(forKey: key.storageKey)
    }
}

struct ThumbPlacementControlGeometry: Equatable, Identifiable, Sendable {
    var id: String
    var label: String
    var visualFrame: CGRect
    var runtimeHitFrame: CGRect

    init(id: String, label: String, visualFrame: CGRect, runtimeHitFrame: CGRect) {
        self.id = id
        self.label = label
        self.visualFrame = visualFrame
        self.runtimeHitFrame = runtimeHitFrame
    }
}

struct ThumbPlacementControlScore: Equatable, Identifiable, Sendable {
    var id: String { controlID }
    var controlID: String
    var label: String
    var score: Int
    var isReachable: Bool
    var isInsideSafeArea: Bool
    var meetsMinimumSize: Bool
    var runtimeOverlapRatio: CGFloat
}

enum ThumbPlacementSuggestionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case moveIntoReach = "move-into-reach"
    case moveInsideSafeArea = "move-inside-safe-area"
    case minimumTouchTarget = "minimum-touch-target"
    case separateRuntimeHitTargets = "separate-runtime-hit-targets"

    var id: Self { self }

    var title: String {
        switch self {
        case .moveIntoReach: "Move controls into thumb reach"
        case .moveInsideSafeArea: "Move controls inside safe areas"
        case .minimumTouchTarget: "Make controls at least 44 pt"
        case .separateRuntimeHitTargets: "Separate overlapping touch targets"
        }
    }

    var detail: String {
        switch self {
        case .moveIntoReach: "Repositions only out-of-zone controls around the calibrated thumb ellipses."
        case .moveInsideSafeArea: "Moves edge controls away from system gesture and cutout areas."
        case .minimumTouchTarget: "Enlarges undersized controls while preserving their relative styling."
        case .separateRuntimeHitTargets: "Separates the actual iPhone hit regions, including invisible hit expansion."
        }
    }
}

struct ThumbPlacementScoreReport: Equatable, Sendable {
    var overallScore: Int
    var controls: [ThumbPlacementControlScore]
    var suggestions: [ThumbPlacementSuggestionKind]
}

enum ThumbPlacementScorer {
    static func score(
        controls: [ThumbPlacementControlGeometry],
        zones: [ThumbPlacementReachZone],
        canvasSize: CGSize,
        safeArea: CGRect
    ) -> ThumbPlacementScoreReport {
        guard !controls.isEmpty else {
            return ThumbPlacementScoreReport(overallScore: 100, controls: [], suggestions: [])
        }

        let overlapByID = runtimeOverlapRatios(controls)
        let scores = controls.map { control -> ThumbPlacementControlScore in
            let normalizedCenter = CGPoint(
                x: control.runtimeHitFrame.midX / max(canvasSize.width, 1),
                y: control.runtimeHitFrame.midY / max(canvasSize.height, 1)
            )
            let isReachable = zones.isEmpty || zones.contains { zone in
                zone.normalizedDistance(to: normalizedCenter) <= 1
                    || zone.frame(in: canvasSize).intersects(control.runtimeHitFrame)
            }
            let isInsideSafeArea = safeArea.contains(control.visualFrame)
            let meetsMinimumSize = min(control.visualFrame.width, control.visualFrame.height) >= 44
            let overlap = overlapByID[control.id] ?? 0

            var score: CGFloat = 100
            if !isReachable { score -= 45 }
            if !isInsideSafeArea { score -= 20 }
            if !meetsMinimumSize {
                let fraction = min(control.visualFrame.width, control.visualFrame.height) / 44
                score -= 20 * (1 - min(max(fraction, 0), 1))
            }
            score -= min(15, overlap * 30)

            return ThumbPlacementControlScore(
                controlID: control.id,
                label: control.label,
                score: Int(min(max(score.rounded(), 0), 100)),
                isReachable: isReachable,
                isInsideSafeArea: isInsideSafeArea,
                meetsMinimumSize: meetsMinimumSize,
                runtimeOverlapRatio: overlap
            )
        }

        var suggestions: [ThumbPlacementSuggestionKind] = []
        if scores.contains(where: { !$0.isReachable }) { suggestions.append(.moveIntoReach) }
        if scores.contains(where: { !$0.isInsideSafeArea }) { suggestions.append(.moveInsideSafeArea) }
        if scores.contains(where: { !$0.meetsMinimumSize }) { suggestions.append(.minimumTouchTarget) }
        if scores.contains(where: { $0.runtimeOverlapRatio > 0.01 }) { suggestions.append(.separateRuntimeHitTargets) }
        let overall = Int((Double(scores.reduce(0) { $0 + $1.score }) / Double(scores.count)).rounded())
        return ThumbPlacementScoreReport(overallScore: overall, controls: scores, suggestions: suggestions)
    }

    private static func runtimeOverlapRatios(_ controls: [ThumbPlacementControlGeometry]) -> [String: CGFloat] {
        var result: [String: CGFloat] = [:]
        for leftIndex in controls.indices {
            for rightIndex in controls.indices where rightIndex > leftIndex {
                let lhs = controls[leftIndex]
                let rhs = controls[rightIndex]
                let intersection = lhs.runtimeHitFrame.intersection(rhs.runtimeHitFrame)
                guard !intersection.isNull, intersection.width > 0.5, intersection.height > 0.5 else { continue }
                let intersectionArea = intersection.width * intersection.height
                let smallerArea = max(1, min(
                    lhs.runtimeHitFrame.width * lhs.runtimeHitFrame.height,
                    rhs.runtimeHitFrame.width * rhs.runtimeHitFrame.height
                ))
                let ratio = intersectionArea / smallerArea
                result[lhs.id] = max(result[lhs.id] ?? 0, ratio)
                result[rhs.id] = max(result[rhs.id] ?? 0, ratio)
            }
        }
        return result
    }
}
