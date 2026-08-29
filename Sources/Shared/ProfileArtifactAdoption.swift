import CryptoKit
import Foundation

public enum ProfileArtifactAdoptionConstants {
    public static let maximumArtifactBytes = 8 * 1024 * 1024
    public static let chunkBytes = 256 * 1024
    public static let maximumChunkCount = maximumArtifactBytes / chunkBytes
    public static let uploadLifetimeMilliseconds: Int64 = 30_000
    public static let ledgerLifetimeMilliseconds: Int64 = 7 * 24 * 60 * 60 * 1_000
    public static let maximumLedgerEntries = 64
}

public enum ProfileArtifactAdoptionConflictPolicy: String, Codable, Sendable {
    case appendAsCopies = "append_as_copies"
}

public enum ProfileArtifactAdoptionStatus: String, Codable, Sendable {
    case accepted
    case succeeded
    case failed
    case replayed
}

public enum ProfileArtifactAdoptionErrorCode: String, Codable, Sendable, CaseIterable {
    case unsupported
    case unauthenticated
    case invalidEnvelope = "invalid_envelope"
    case wrongServer = "wrong_server"
    case invalidHash = "invalid_hash"
    case invalidSize = "invalid_size"
    case invalidChunk = "invalid_chunk"
    case outOfOrder = "out_of_order"
    case uploadBusy = "upload_busy"
    case uploadExpired = "upload_expired"
    case operationConflict = "operation_conflict"
    case operationMissing = "operation_missing"
    case artifactInvalid = "artifact_invalid"
    case importFailed = "import_failed"
    case disconnected
}

public struct ProfileArtifactAdoptionMetadata: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let recordID: UUID
    public let intendedServerID: String
    public let contentHash: String
    public let rawSHA256: String
    public let byteCount: Int
    public let chunkCount: Int
    public let conflictPolicy: ProfileArtifactAdoptionConflictPolicy

    public init(
        operationID: UUID,
        recordID: UUID,
        intendedServerID: String,
        contentHash: String,
        rawSHA256: String,
        byteCount: Int,
        chunkCount: Int,
        conflictPolicy: ProfileArtifactAdoptionConflictPolicy = .appendAsCopies
    ) {
        self.operationID = operationID
        self.recordID = recordID
        self.intendedServerID = intendedServerID
        self.contentHash = contentHash
        self.rawSHA256 = rawSHA256
        self.byteCount = byteCount
        self.chunkCount = chunkCount
        self.conflictPolicy = conflictPolicy
    }

    public static func chunkCount(forByteCount byteCount: Int) -> Int {
        guard byteCount > 0 else { return 0 }
        return (byteCount + ProfileArtifactAdoptionConstants.chunkBytes - 1)
            / ProfileArtifactAdoptionConstants.chunkBytes
    }

    public static func isValidServerID(_ value: String) -> Bool {
        guard !value.isEmpty, value.unicodeScalars.count <= 128 else { return false }
        return value.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0)
        }
    }

    public func validate(expectedServerID: String) -> ProfileArtifactAdoptionErrorCode? {
        guard Self.isValidServerID(intendedServerID) else { return .invalidEnvelope }
        guard intendedServerID == expectedServerID else { return .wrongServer }
        guard Self.isLowercaseSHA256(contentHash), Self.isLowercaseSHA256(rawSHA256) else {
            return .invalidHash
        }
        guard byteCount > 0,
              byteCount <= ProfileArtifactAdoptionConstants.maximumArtifactBytes,
              chunkCount == Self.chunkCount(forByteCount: byteCount),
              chunkCount > 0,
              chunkCount <= ProfileArtifactAdoptionConstants.maximumChunkCount
        else { return .invalidSize }
        guard conflictPolicy == .appendAsCopies else { return .invalidEnvelope }
        return nil
    }

    public func expectedChunkBytes(at index: Int) -> Int? {
        guard index >= 0, index < chunkCount else { return nil }
        if index < chunkCount - 1 { return ProfileArtifactAdoptionConstants.chunkBytes }
        return byteCount - ProfileArtifactAdoptionConstants.chunkBytes * (chunkCount - 1)
    }

    public static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct ProfileArtifactAdoptionResult: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let recordID: UUID
    public let serverID: String
    public let contentHash: String
    public let rawSHA256: String
    public let status: ProfileArtifactAdoptionStatus
    public let errorCode: ProfileArtifactAdoptionErrorCode?
    public let destinationProfileIDs: [UUID]

    public init(
        metadata: ProfileArtifactAdoptionMetadata,
        serverID: String,
        status: ProfileArtifactAdoptionStatus,
        errorCode: ProfileArtifactAdoptionErrorCode? = nil,
        destinationProfileIDs: [UUID] = []
    ) {
        operationID = metadata.operationID
        recordID = metadata.recordID
        self.serverID = serverID
        contentHash = metadata.contentHash
        rawSHA256 = metadata.rawSHA256
        self.status = status
        self.errorCode = errorCode
        self.destinationProfileIDs = destinationProfileIDs
    }

    public func validates(against metadata: ProfileArtifactAdoptionMetadata) -> Bool {
        guard metadata.validate(expectedServerID: metadata.intendedServerID) == nil,
              ProfileArtifactAdoptionMetadata.isValidServerID(serverID),
              operationID == metadata.operationID,
              recordID == metadata.recordID,
              serverID == metadata.intendedServerID,
              contentHash == metadata.contentHash,
              rawSHA256 == metadata.rawSHA256
        else { return false }
        switch status {
        case .accepted:
            return errorCode == nil && destinationProfileIDs.isEmpty
        case .succeeded, .replayed:
            return errorCode == nil
                && (1...256).contains(destinationProfileIDs.count)
                && Set(destinationProfileIDs).count == destinationProfileIDs.count
        case .failed:
            return errorCode != nil && destinationProfileIDs.isEmpty
        }
    }
}

public enum ProfileArtifactAdoptionEnvelopeValidator {
    public static func validate(_ message: ControllerMessage) -> ProfileArtifactAdoptionErrorCode? {
        guard !hasUnrelatedPayload(message) else { return .invalidEnvelope }
        switch message.type {
        case .profileArtifactAdoptionBegin:
            guard message.profileArtifactAdoptionMetadata != nil,
                  message.profileArtifactAdoptionOperationID == nil,
                  message.profileArtifactAdoptionChunkIndex == nil,
                  message.profileArtifactAdoptionChunkData == nil,
                  message.profileArtifactAdoptionResult == nil
            else { return .invalidEnvelope }
        case .profileArtifactAdoptionChunk:
            guard message.profileArtifactAdoptionMetadata == nil,
                  message.profileArtifactAdoptionOperationID != nil,
                  message.profileArtifactAdoptionChunkIndex != nil,
                  message.profileArtifactAdoptionChunkData != nil,
                  message.profileArtifactAdoptionResult == nil
            else { return .invalidEnvelope }
        case .profileArtifactAdoptionCommit, .profileArtifactAdoptionCancel:
            guard message.profileArtifactAdoptionMetadata == nil,
                  message.profileArtifactAdoptionOperationID != nil,
                  message.profileArtifactAdoptionChunkIndex == nil,
                  message.profileArtifactAdoptionChunkData == nil,
                  message.profileArtifactAdoptionResult == nil
            else { return .invalidEnvelope }
        case .profileArtifactAdoptionResult:
            guard message.profileArtifactAdoptionMetadata == nil,
                  message.profileArtifactAdoptionOperationID == nil,
                  message.profileArtifactAdoptionChunkIndex == nil,
                  message.profileArtifactAdoptionChunkData == nil,
                  message.profileArtifactAdoptionResult != nil
            else { return .invalidEnvelope }
        default:
            return .invalidEnvelope
        }
        return nil
    }

    private static func hasUnrelatedPayload(_ message: ControllerMessage) -> Bool {
        message.button != nil || message.elementID != nil || message.elementPart != nil
            || message.state != nil || message.sentAt != nil || message.pairingCode != nil
            || message.clientName != nil || message.message != nil || message.realtimeToken != nil
            || message.authToken != nil || message.serverID != nil
            || message.gamepadCustomization != nil || message.gamepadProfiles != nil
            || message.skinPackages != nil || message.skinReference != nil
            || message.bindingPresentations != nil || message.gamepadProfileID != nil
            || message.defaultGamepadProfileID != nil || message.capabilities != nil
            || message.gamepadProfileOrientationPreferenceMutation != nil
            || message.clientDeviceInfo != nil || message.pointerEvent != nil
            || message.pointerButton != nil || message.deltaX != nil || message.deltaY != nil
            || message.analogStick != nil || message.analogTrigger != nil
            || message.analogX != nil || message.analogY != nil || message.analogValue != nil
            || message.analogSequence != nil || message.inputProtocolVersion != nil
            || message.inputGeneration != nil || message.inputSequence != nil
            || message.pressIdentifier != nil
    }
}

public struct CompletedProfileArtifactAdoptionUpload: Sendable {
    public let metadata: ProfileArtifactAdoptionMetadata
    public let data: Data
}

public enum ProfileArtifactAdoptionAssemblerEvent: Equatable, Sendable {
    case accepted
    case chunkAccepted(Int)
    case completed
    case cancelled
    case rejected(ProfileArtifactAdoptionErrorCode)
}

/// One-upload, ordered, reference-backed assembler. Call only from one serialized queue.
public final class ProfileArtifactAdoptionAssembler: @unchecked Sendable {
    private final class Upload: @unchecked Sendable {
        let metadata: ProfileArtifactAdoptionMetadata
        let expiresAt: Int64
        var nextChunkIndex = 0
        var data = Data()

        init(metadata: ProfileArtifactAdoptionMetadata, expiresAt: Int64) {
            self.metadata = metadata
            self.expiresAt = expiresAt
            data.reserveCapacity(metadata.byteCount)
        }
    }

    private var active: Upload?
    private var completed: CompletedProfileArtifactAdoptionUpload?

    public init() {}

    public var activeOperationID: UUID? { active?.metadata.operationID }
    public var activeMetadata: ProfileArtifactAdoptionMetadata? { active?.metadata }

    @discardableResult
    public func begin(
        _ metadata: ProfileArtifactAdoptionMetadata,
        expectedServerID: String,
        nowMilliseconds: Int64
    ) -> ProfileArtifactAdoptionAssemblerEvent {
        expireIfNeeded(nowMilliseconds: nowMilliseconds)
        if let error = metadata.validate(expectedServerID: expectedServerID) {
            return .rejected(error)
        }
        if let active {
            if active.metadata.operationID == metadata.operationID {
                guard active.metadata == metadata else { return .rejected(.operationConflict) }
                completed = nil
                self.active = Upload(
                    metadata: metadata,
                    expiresAt: nowMilliseconds + ProfileArtifactAdoptionConstants.uploadLifetimeMilliseconds
                )
                return .accepted
            }
            return .rejected(.uploadBusy)
        }
        completed = nil
        active = Upload(
            metadata: metadata,
            expiresAt: nowMilliseconds + ProfileArtifactAdoptionConstants.uploadLifetimeMilliseconds
        )
        return .accepted
    }

    @discardableResult
    public func append(
        operationID: UUID,
        index: Int,
        data: Data,
        nowMilliseconds: Int64
    ) -> ProfileArtifactAdoptionAssemblerEvent {
        guard !expireIfNeeded(nowMilliseconds: nowMilliseconds) else {
            return .rejected(.uploadExpired)
        }
        guard let active else { return .rejected(.operationMissing) }
        guard active.metadata.operationID == operationID else {
            return .rejected(.operationConflict)
        }
        guard index == active.nextChunkIndex else { return .rejected(.outOfOrder) }
        guard active.metadata.expectedChunkBytes(at: index) == data.count,
              active.data.count <= active.metadata.byteCount - data.count
        else { return .rejected(.invalidChunk) }
        active.data.append(data)
        active.nextChunkIndex += 1
        return .chunkAccepted(index)
    }

    @discardableResult
    public func commit(
        operationID: UUID,
        nowMilliseconds: Int64
    ) -> ProfileArtifactAdoptionAssemblerEvent {
        guard !expireIfNeeded(nowMilliseconds: nowMilliseconds) else {
            return .rejected(.uploadExpired)
        }
        guard let active else { return .rejected(.operationMissing) }
        guard active.metadata.operationID == operationID else {
            return .rejected(.operationConflict)
        }
        guard active.nextChunkIndex == active.metadata.chunkCount,
              active.data.count == active.metadata.byteCount
        else { return .rejected(.outOfOrder) }
        guard ProfileArtifactAdoptionMetadata.sha256(active.data) == active.metadata.rawSHA256 else {
            self.active = nil
            return .rejected(.invalidHash)
        }
        completed = CompletedProfileArtifactAdoptionUpload(
            metadata: active.metadata,
            data: active.data
        )
        self.active = nil
        return .completed
    }

    public func takeCompleted() -> CompletedProfileArtifactAdoptionUpload? {
        defer { completed = nil }
        return completed
    }

    @discardableResult
    public func cancel(operationID: UUID?) -> ProfileArtifactAdoptionAssemblerEvent {
        guard let active else { return .cancelled }
        if let operationID, operationID != active.metadata.operationID {
            return .rejected(.operationConflict)
        }
        self.active = nil
        completed = nil
        return .cancelled
    }

    public func reset() {
        active = nil
        completed = nil
    }

    @discardableResult
    public func expire(nowMilliseconds: Int64) -> Bool {
        expireIfNeeded(nowMilliseconds: nowMilliseconds)
    }

    @discardableResult
    private func expireIfNeeded(nowMilliseconds: Int64) -> Bool {
        guard let active, nowMilliseconds >= active.expiresAt else { return false }
        self.active = nil
        completed = nil
        return true
    }
}

public enum ProfileArtifactAdoptionCommitDecision: Equatable, Sendable {
    case proceed
    case inProgress
    case busy
    case conflict
}

/// Serialized decision state preventing a completed upload from being imported twice
/// while its first import is still crossing onto the authority queue.
public struct ProfileArtifactAdoptionCommitGate: Sendable {
    public private(set) var metadata: ProfileArtifactAdoptionMetadata?

    public init(metadata: ProfileArtifactAdoptionMetadata? = nil) {
        self.metadata = metadata
    }

    public func decision(for candidate: ProfileArtifactAdoptionMetadata) -> ProfileArtifactAdoptionCommitDecision {
        guard let metadata else { return .proceed }
        if metadata.operationID == candidate.operationID {
            return metadata == candidate ? .inProgress : .conflict
        }
        return .busy
    }

    @discardableResult
    public mutating func begin(_ candidate: ProfileArtifactAdoptionMetadata) -> Bool {
        guard decision(for: candidate) == .proceed else { return false }
        metadata = candidate
        return true
    }

    public mutating func finish(operationID: UUID) {
        guard metadata?.operationID == operationID else { return }
        metadata = nil
    }
}

public struct ProfileArtifactAdoptionLedgerEntry: Codable, Equatable, Sendable {
    public let metadata: ProfileArtifactAdoptionMetadata
    public let status: ProfileArtifactAdoptionStatus
    public let errorCode: ProfileArtifactAdoptionErrorCode?
    public let destinationProfileIDs: [UUID]
    public let completedAtMilliseconds: Int64

    public init(
        metadata: ProfileArtifactAdoptionMetadata,
        status: ProfileArtifactAdoptionStatus,
        errorCode: ProfileArtifactAdoptionErrorCode?,
        destinationProfileIDs: [UUID],
        completedAtMilliseconds: Int64
    ) {
        self.metadata = metadata
        self.status = status
        self.errorCode = errorCode
        self.destinationProfileIDs = destinationProfileIDs
        self.completedAtMilliseconds = completedAtMilliseconds
    }

    public func result(serverID: String, replayed: Bool) -> ProfileArtifactAdoptionResult {
        ProfileArtifactAdoptionResult(
            metadata: metadata,
            serverID: serverID,
            status: replayed && status == .succeeded ? .replayed : status,
            errorCode: errorCode,
            destinationProfileIDs: destinationProfileIDs
        )
    }
}

public enum ProfileArtifactAdoptionLedgerLookup: Equatable, Sendable {
    case none
    case replay(ProfileArtifactAdoptionLedgerEntry)
    case conflict
}

public struct ProfileArtifactAdoptionLedger: Codable, Equatable, Sendable {
    private var entries: [ProfileArtifactAdoptionLedgerEntry]

    public init(entries: [ProfileArtifactAdoptionLedgerEntry] = []) {
        self.entries = entries
    }

    public mutating func lookup(
        _ metadata: ProfileArtifactAdoptionMetadata,
        nowMilliseconds: Int64
    ) -> ProfileArtifactAdoptionLedgerLookup {
        prune(nowMilliseconds: nowMilliseconds)
        guard let entry = entries.first(where: { $0.metadata.operationID == metadata.operationID }) else {
            return .none
        }
        return entry.metadata == metadata ? .replay(entry) : .conflict
    }

    public mutating func record(_ entry: ProfileArtifactAdoptionLedgerEntry, nowMilliseconds: Int64) {
        prune(nowMilliseconds: nowMilliseconds)
        entries.removeAll { $0.metadata.operationID == entry.metadata.operationID }
        entries.append(entry)
        entries.sort {
            if $0.completedAtMilliseconds == $1.completedAtMilliseconds {
                return $0.metadata.operationID.uuidString < $1.metadata.operationID.uuidString
            }
            return $0.completedAtMilliseconds < $1.completedAtMilliseconds
        }
        if entries.count > ProfileArtifactAdoptionConstants.maximumLedgerEntries {
            entries.removeFirst(entries.count - ProfileArtifactAdoptionConstants.maximumLedgerEntries)
        }
    }

    public mutating func prune(nowMilliseconds: Int64) {
        let cutoff = nowMilliseconds - ProfileArtifactAdoptionConstants.ledgerLifetimeMilliseconds
        entries.removeAll { $0.completedAtMilliseconds < cutoff }
        if entries.count > ProfileArtifactAdoptionConstants.maximumLedgerEntries {
            entries.removeFirst(entries.count - ProfileArtifactAdoptionConstants.maximumLedgerEntries)
        }
    }

    public var allEntries: [ProfileArtifactAdoptionLedgerEntry] { entries }
}
