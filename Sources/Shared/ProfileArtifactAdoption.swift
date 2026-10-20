import CryptoKit
import Foundation

// Reserved legacy wire data, retained for decoding old peers and local artifact hashes.
// Upload assembly, durable adoption and receipt replay are retired.
public enum ProfileArtifactAdoptionConstants {
    public static let maximumArtifactBytes = 8 * 1024 * 1024
    public static let chunkBytes = 256 * 1024
    public static let maximumChunkCount = maximumArtifactBytes / chunkBytes
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

/// Legacy wire shapes remain decodable so old clients receive an explicit retirement error.
/// No upload bytes, receipt ledger or profile mutation is retained.
public enum RetiredProfileArtifactAdoption {
    public static func response(to message: ControllerMessage, isPaired: Bool) -> ControllerMessage? {
        guard isPaired else { return nil }
        switch message.type {
        case .profileArtifactAdoptionBegin, .profileArtifactAdoptionChunk,
             .profileArtifactAdoptionCommit, .profileArtifactAdoptionCancel:
            return ControllerMessage(type: .error, message: "Hosted shared builds are retired. Export the saved file and import it locally.")
        default:
            return nil
        }
    }
}
