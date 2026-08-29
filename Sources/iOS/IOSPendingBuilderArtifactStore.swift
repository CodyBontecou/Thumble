import CryptoKit
import Darwin
import Foundation

public enum IOSPendingBuilderArtifactState: String, Codable, CaseIterable, Sendable {
    case previewed
    case awaitingHost
    case adopting
    case adopted
    case failed
}

public struct IOSPendingBuilderArtifactRecord: Codable, Equatable, Identifiable, Sendable {
    public static let store = "com.codybontecou.thumble.pending-builder-artifacts"
    public static let version = 1

    public let store: String
    public let version: Int
    public let id: UUID
    public let contentHash: String
    public let rawSHA256: String
    public let bytes: Int
    public let createdAtMilliseconds: Int64
    public let expiresAtMilliseconds: Int64
    public let state: IOSPendingBuilderArtifactState
    public let operationID: UUID?
    public let intendedServerID: String?
    public let profiles: [PortableProfileArtifact.ProfileSummary]
    public let lastSafeErrorCode: String?

    fileprivate init(
        id: UUID,
        contentHash: String,
        rawSHA256: String,
        bytes: Int,
        createdAtMilliseconds: Int64,
        expiresAtMilliseconds: Int64,
        state: IOSPendingBuilderArtifactState,
        operationID: UUID?,
        intendedServerID: String?,
        profiles: [PortableProfileArtifact.ProfileSummary],
        lastSafeErrorCode: String?
    ) {
        store = Self.store
        version = Self.version
        self.id = id
        self.contentHash = contentHash
        self.rawSHA256 = rawSHA256
        self.bytes = bytes
        self.createdAtMilliseconds = createdAtMilliseconds
        self.expiresAtMilliseconds = expiresAtMilliseconds
        self.state = state
        self.operationID = operationID
        self.intendedServerID = intendedServerID
        self.profiles = profiles
        self.lastSafeErrorCode = lastSafeErrorCode
    }
}

public enum IOSPendingBuilderArtifactStoreError: Error, Equatable, Sendable, LocalizedError {
    case invalidIdentifier
    case invalidMetadata
    case metadataTooLarge
    case artifactTooLarge
    case quotaExceeded
    case recordNotFound
    case unsafeFile
    case digestMismatch
    case invalidStateMetadata
    case fileOperationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier: "The pending artifact identifier is invalid."
        case .invalidMetadata: "Pending artifact metadata is invalid."
        case .metadataTooLarge: "Pending artifact metadata exceeds the size limit."
        case .artifactTooLarge: "The pending artifact exceeds the size limit."
        case .quotaExceeded: "The pending artifact quarantine is full."
        case .recordNotFound: "The pending artifact was not found."
        case .unsafeFile: "The pending artifact quarantine contains an unsafe file."
        case .digestMismatch: "The pending artifact digest does not match its metadata."
        case .invalidStateMetadata: "Pending artifact state metadata is invalid."
        case .fileOperationFailed: "The pending artifact could not be stored safely."
        }
    }
}

/// File-backed iOS quarantine for hosted-builder artifacts. The actor serializes every mutation;
/// artifact bytes are immutable, and metadata is committed only after the artifact rename.
public actor IOSPendingBuilderArtifactStore {
    public static let maximumRecords = 32
    public static let maximumArtifactBytes = 8 * 1024 * 1024
    public static let maximumAggregateBytes = 32 * 1024 * 1024
    public static let maximumMetadataBytes = 32 * 1024
    public static let defaultLifetime: TimeInterval = 7 * 24 * 60 * 60
    public static let hardMaximumLifetime: TimeInterval = 30 * 24 * 60 * 60

    private let rootURL: URL
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private var recordsByID: [UUID: IOSPendingBuilderArtifactRecord]

    public static func defaultRootURL(fileManager: FileManager = .default) throws -> URL {
        guard let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw IOSPendingBuilderArtifactStoreError.fileOperationFailed
        }
        return applicationSupport
            .appendingPathComponent("Thumble", isDirectory: true)
            .appendingPathComponent("PendingBuilderArtifacts", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
    }

    public init(
        rootURL: URL? = nil,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        self.fileManager = fileManager
        self.rootURL = try rootURL ?? Self.defaultRootURL(fileManager: fileManager)
        self.now = now
        recordsByID = [:]
        try fileManager.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
        try Self.rejectSymlinkOrNonDirectory(self.rootURL)
        guard chmod(self.rootURL.path, S_IRWXU) == 0 else {
            throw IOSPendingBuilderArtifactStoreError.fileOperationFailed
        }
        var rootValues = URLResourceValues()
        rootValues.isExcludedFromBackup = true
        var mutableRootURL = self.rootURL
        try mutableRootURL.setResourceValues(rootValues)
        recordsByID = try Self.reconcile(
            rootURL: self.rootURL,
            fileManager: fileManager,
            nowMilliseconds: Self.milliseconds(now())
        )
    }

    @discardableResult
    public func save(
        _ artifact: PortableProfileArtifact,
        id: UUID = UUID(),
        lifetime: TimeInterval = IOSPendingBuilderArtifactStore.defaultLifetime
    ) throws -> IOSPendingBuilderArtifactRecord {
        guard artifact.rawData.count <= Self.maximumArtifactBytes else {
            throw IOSPendingBuilderArtifactStoreError.artifactTooLarge
        }
        guard recordsByID[id] == nil else {
            throw IOSPendingBuilderArtifactStoreError.invalidIdentifier
        }
        let created = Self.milliseconds(now())
        let boundedLifetime = min(max(0, lifetime), Self.hardMaximumLifetime)
        let expires = created + Int64(boundedLifetime * 1_000)
        let record = IOSPendingBuilderArtifactRecord(
            id: id,
            contentHash: artifact.contentHash.value,
            rawSHA256: Self.sha256(artifact.rawData),
            bytes: artifact.rawData.count,
            createdAtMilliseconds: created,
            expiresAtMilliseconds: expires,
            state: .previewed,
            operationID: nil,
            intendedServerID: nil,
            profiles: Self.metadataProfileSummaries(artifact.profileSummaries),
            lastSafeErrorCode: nil
        )
        let metadata = try encodeMetadata(record)
        try pruneExpired(nowMilliseconds: created)
        try makeCapacity(forAdditionalBytes: artifact.rawData.count, additionalRecords: 1)

        let artifactURL = self.artifactURL(id)
        let metadataURL = self.metadataURL(id)
        do {
            try writeAtomicallyProtected(artifact.rawData, destination: artifactURL)
            do {
                try writeAtomicallyProtected(metadata, destination: metadataURL)
            } catch {
                try? fileManager.removeItem(at: artifactURL)
                throw error
            }
        } catch let error as IOSPendingBuilderArtifactStoreError {
            throw error
        } catch {
            throw IOSPendingBuilderArtifactStoreError.fileOperationFailed
        }
        recordsByID[id] = record
        return record
    }

    public func list() throws -> [IOSPendingBuilderArtifactRecord] {
        try pruneExpired(nowMilliseconds: Self.milliseconds(now()))
        return recordsByID.values.sorted {
            if $0.createdAtMilliseconds == $1.createdAtMilliseconds {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.createdAtMilliseconds < $1.createdAtMilliseconds
        }
    }

    public func loadRawData(id: UUID) throws -> Data {
        try pruneExpired(nowMilliseconds: Self.milliseconds(now()))
        guard let record = recordsByID[id] else {
            throw IOSPendingBuilderArtifactStoreError.recordNotFound
        }
        let url = artifactURL(id)
        try Self.rejectSymlinkOrNonRegular(url)
        let data = try Self.readRegularFile(url, maximumBytes: Self.maximumArtifactBytes)
        guard data.count == record.bytes,
              Self.sha256(data) == record.rawSHA256,
              let decoded = try? PortableProfileArtifact(validating: data),
              decoded.contentHash.value == record.contentHash,
              Self.metadataProfileSummaries(decoded.profileSummaries) == record.profiles
        else {
            try? removePair(id)
            recordsByID[id] = nil
            throw IOSPendingBuilderArtifactStoreError.digestMismatch
        }
        return data
    }

    public func load(id: UUID) throws -> PortableProfileArtifact {
        let data = try loadRawData(id: id)
        do { return try PortableProfileArtifact(validating: data) }
        catch {
            throw IOSPendingBuilderArtifactStoreError.digestMismatch
        }
    }

    @discardableResult
    public func updateState(
        id: UUID,
        state: IOSPendingBuilderArtifactState,
        operationID: UUID? = nil,
        intendedServerID: String? = nil,
        lastSafeErrorCode: String? = nil
    ) throws -> IOSPendingBuilderArtifactRecord {
        guard let existing = recordsByID[id] else {
            throw IOSPendingBuilderArtifactStoreError.recordNotFound
        }
        guard Self.isSafeErrorCode(lastSafeErrorCode),
              intendedServerID.map(ProfileArtifactAdoptionMetadata.isValidServerID) ?? true
        else {
            throw IOSPendingBuilderArtifactStoreError.invalidStateMetadata
        }
        let updated = IOSPendingBuilderArtifactRecord(
            id: existing.id,
            contentHash: existing.contentHash,
            rawSHA256: existing.rawSHA256,
            bytes: existing.bytes,
            createdAtMilliseconds: existing.createdAtMilliseconds,
            expiresAtMilliseconds: existing.expiresAtMilliseconds,
            state: state,
            operationID: operationID,
            intendedServerID: intendedServerID ?? existing.intendedServerID,
            profiles: existing.profiles,
            lastSafeErrorCode: lastSafeErrorCode
        )
        let metadata = try encodeMetadata(updated)
        try writeAtomicallyProtected(metadata, destination: metadataURL(id))
        recordsByID[id] = updated
        return updated
    }

    public func delete(id: UUID) throws {
        guard recordsByID[id] != nil else { return }
        try removePair(id)
        recordsByID[id] = nil
    }

    public func prune() throws {
        try pruneExpired(nowMilliseconds: Self.milliseconds(now()))
        try enforceExistingQuotas()
    }

    private func pruneExpired(nowMilliseconds: Int64) throws {
        let hardLifetime = Int64(Self.hardMaximumLifetime * 1_000)
        let expired = recordsByID.values.filter {
            nowMilliseconds >= min($0.expiresAtMilliseconds, $0.createdAtMilliseconds + hardLifetime)
                && $0.state != .adopting
        }
        for record in expired {
            try removePair(record.id)
            recordsByID[record.id] = nil
        }
    }

    private func makeCapacity(forAdditionalBytes bytes: Int, additionalRecords: Int) throws {
        while recordsByID.count + additionalRecords > Self.maximumRecords
            || recordsByID.values.reduce(0, { $0 + $1.bytes }) + bytes > Self.maximumAggregateBytes {
            guard let victim = recordsByID.values
                .filter({ $0.state != .adopting })
                .min(by: {
                    if $0.createdAtMilliseconds == $1.createdAtMilliseconds {
                        return $0.id.uuidString < $1.id.uuidString
                    }
                    return $0.createdAtMilliseconds < $1.createdAtMilliseconds
                })
            else { throw IOSPendingBuilderArtifactStoreError.quotaExceeded }
            try removePair(victim.id)
            recordsByID[victim.id] = nil
        }
    }

    private func enforceExistingQuotas() throws {
        try makeCapacity(forAdditionalBytes: 0, additionalRecords: 0)
    }

    private func encodeMetadata(_ record: IOSPendingBuilderArtifactRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do { data = try encoder.encode(record) }
        catch { throw IOSPendingBuilderArtifactStoreError.invalidMetadata }
        guard data.count <= Self.maximumMetadataBytes else {
            throw IOSPendingBuilderArtifactStoreError.metadataTooLarge
        }
        return data
    }

    private func writeAtomicallyProtected(_ data: Data, destination: URL) throws {
        let temporary = rootURL.appendingPathComponent(".\(UUID().uuidString.lowercased()).tmp", isDirectory: false)
        defer { try? fileManager.removeItem(at: temporary) }
        do {
            try data.write(to: temporary, options: [.completeFileProtectionUntilFirstUserAuthentication])
            guard chmod(temporary.path, S_IRUSR | S_IWUSR) == 0 else {
                throw IOSPendingBuilderArtifactStoreError.fileOperationFailed
            }
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableTemporary = temporary
            try mutableTemporary.setResourceValues(values)
            let fileDescriptor = open(temporary.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard fileDescriptor >= 0 else {
                throw IOSPendingBuilderArtifactStoreError.fileOperationFailed
            }
            defer { close(fileDescriptor) }
            guard fsync(fileDescriptor) == 0,
                  rename(temporary.path, destination.path) == 0
            else {
                throw IOSPendingBuilderArtifactStoreError.fileOperationFailed
            }
            let directoryDescriptor = open(rootURL.path, O_RDONLY | O_CLOEXEC)
            if directoryDescriptor >= 0 {
                _ = fsync(directoryDescriptor)
                close(directoryDescriptor)
            }
        } catch let error as IOSPendingBuilderArtifactStoreError {
            throw error
        } catch {
            throw IOSPendingBuilderArtifactStoreError.fileOperationFailed
        }
    }

    private func removePair(_ id: UUID) throws {
        do {
            for url in [artifactURL(id), metadataURL(id)] where fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        } catch {
            throw IOSPendingBuilderArtifactStoreError.fileOperationFailed
        }
    }

    private func artifactURL(_ id: UUID) -> URL {
        rootURL.appendingPathComponent("\(id.uuidString.lowercased()).artifact.json", isDirectory: false)
    }

    private func metadataURL(_ id: UUID) -> URL {
        rootURL.appendingPathComponent("\(id.uuidString.lowercased()).metadata.json", isDirectory: false)
    }

    private static func reconcile(
        rootURL: URL,
        fileManager: FileManager,
        nowMilliseconds: Int64
    ) throws -> [UUID: IOSPendingBuilderArtifactRecord] {
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: []
            )
        } catch {
            throw IOSPendingBuilderArtifactStoreError.fileOperationFailed
        }

        var artifactURLs: [UUID: URL] = [:]
        var metadataURLs: [UUID: URL] = [:]
        for url in urls {
            let name = url.lastPathComponent
            if name.hasSuffix(".tmp") {
                try? fileManager.removeItem(at: url)
                continue
            }
            if let id = identifier(from: name, suffix: ".artifact.json") {
                artifactURLs[id] = url
            } else if let id = identifier(from: name, suffix: ".metadata.json") {
                metadataURLs[id] = url
            } else {
                // The quarantine owns this versioned directory and permits UUID pair files only.
                try? fileManager.removeItem(at: url)
            }
        }

        var records: [UUID: IOSPendingBuilderArtifactRecord] = [:]
        let allIDs = Set(artifactURLs.keys).union(metadataURLs.keys)
        let decoder = JSONDecoder()
        let hardLifetime = Int64(hardMaximumLifetime * 1_000)
        for id in allIDs {
            guard let artifactURL = artifactURLs[id], let metadataURL = metadataURLs[id] else {
                if let orphanArtifactURL = artifactURLs[id] {
                    try? fileManager.removeItem(at: orphanArtifactURL)
                }
                if let orphanMetadataURL = metadataURLs[id] {
                    try? fileManager.removeItem(at: orphanMetadataURL)
                }
                continue
            }
            do {
                try rejectSymlinkOrNonRegular(artifactURL)
                try rejectSymlinkOrNonRegular(metadataURL)
                let metadataData = try readRegularFile(metadataURL, maximumBytes: maximumMetadataBytes)
                let record = try decoder.decode(IOSPendingBuilderArtifactRecord.self, from: metadataData)
                let artifactData = try readRegularFile(artifactURL, maximumBytes: maximumArtifactBytes)
                let artifact = try PortableProfileArtifact(validating: artifactData)
                guard record.store == IOSPendingBuilderArtifactRecord.store,
                      record.version == IOSPendingBuilderArtifactRecord.version,
                      record.id == id,
                      record.bytes == artifactData.count,
                      record.bytes <= maximumArtifactBytes,
                      record.contentHash == artifact.contentHash.value,
                      record.contentHash.count == 64,
                      record.rawSHA256 == sha256(artifactData),
                      record.rawSHA256.count == 64,
                      record.profiles == metadataProfileSummaries(artifact.profileSummaries),
                      isSafeErrorCode(record.lastSafeErrorCode),
                      record.intendedServerID.map(ProfileArtifactAdoptionMetadata.isValidServerID) ?? true,
                      record.expiresAtMilliseconds >= record.createdAtMilliseconds,
                      record.expiresAtMilliseconds <= record.createdAtMilliseconds + hardLifetime,
                      !(nowMilliseconds >= record.expiresAtMilliseconds && record.state != .adopting)
                else { throw IOSPendingBuilderArtifactStoreError.invalidMetadata }
                records[id] = record
            } catch {
                try? fileManager.removeItem(at: artifactURL)
                try? fileManager.removeItem(at: metadataURL)
            }
        }

        while records.count > maximumRecords || records.values.reduce(0, { $0 + $1.bytes }) > maximumAggregateBytes {
            guard let victim = records.values.filter({ $0.state != .adopting }).min(by: {
                if $0.createdAtMilliseconds == $1.createdAtMilliseconds {
                    return $0.id.uuidString < $1.id.uuidString
                }
                return $0.createdAtMilliseconds < $1.createdAtMilliseconds
            }) else {
                throw IOSPendingBuilderArtifactStoreError.quotaExceeded
            }
            try? fileManager.removeItem(at: artifactURLs[victim.id]!)
            try? fileManager.removeItem(at: metadataURLs[victim.id]!)
            records[victim.id] = nil
        }
        return records
    }

    private static func identifier(from filename: String, suffix: String) -> UUID? {
        guard filename.hasSuffix(suffix) else { return nil }
        let raw = String(filename.dropLast(suffix.count))
        guard raw.count == 36, raw == raw.lowercased(), let id = UUID(uuidString: raw),
              id.uuidString.lowercased() == raw
        else { return nil }
        return id
    }

    private static func rejectSymlinkOrNonDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw IOSPendingBuilderArtifactStoreError.unsafeFile
        }
    }

    private static func rejectSymlinkOrNonRegular(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw IOSPendingBuilderArtifactStoreError.unsafeFile
        }
    }

    private static func readRegularFile(_ url: URL, maximumBytes: Int) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw IOSPendingBuilderArtifactStoreError.unsafeFile
        }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_size >= 0,
              status.st_size <= maximumBytes
        else {
            throw IOSPendingBuilderArtifactStoreError.unsafeFile
        }
        var result = Data()
        result.reserveCapacity(Int(status.st_size))
        var buffer = [UInt8](repeating: 0, count: min(64 * 1024, maximumBytes + 1))
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count == 0 { break }
            guard count > 0, result.count + count <= maximumBytes else {
                throw IOSPendingBuilderArtifactStoreError.unsafeFile
            }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }

    private static func metadataProfileSummaries(
        _ summaries: [PortableProfileArtifact.ProfileSummary]
    ) -> [PortableProfileArtifact.ProfileSummary] {
        summaries.map { summary in
            let scalars = summary.name.unicodeScalars.map { scalar -> Unicode.Scalar in
                CharacterSet.controlCharacters.contains(scalar) ? Unicode.Scalar(0x20)! : scalar
            }
            let sanitized = String(String.UnicodeScalarView(scalars))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .init(id: summary.id, name: sanitized)
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded(.towardZero))
    }

    private static func isSafeErrorCode(_ code: String?) -> Bool {
        guard let code else { return true }
        guard !code.isEmpty, code.utf8.count <= 128 else { return false }
        return code.utf8.allSatisfy {
            ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 95 || $0 == 46
        }
    }
}
