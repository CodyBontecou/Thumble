import CryptoKit
import Darwin
import Foundation
import ZIPFoundation

/// Read-only upgrade access. Never creates, repairs, expires or deletes the legacy directory.
public struct PendingProfileRecovery: Sendable {
    public struct Record: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let name: String
        public let byteCount: Int
        public let isProfileFile: Bool
        fileprivate let artifactHash: String?
        fileprivate let metadataHash: String?
    }
    public struct Export: Sendable {
        public let filename: String
        public let data: Data
        public let isProfileFile: Bool
    }
    public enum RecoveryError: Error, Equatable, Sendable {
        case unsafeSource, oversizedSource, tooManyRecords, sourceChanged, unavailable, invalidArchive
    }
    private let rootURL: URL

    public init(rootURL: URL) { self.rootURL = rootURL }
    public static func defaultRootURL() throws -> URL {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw RecoveryError.unavailable
        }
        return support.appendingPathComponent("Thumble/PendingBuilderArtifacts/v1", isDirectory: true)
    }
    public func list() throws -> [Record] {
        guard try directoryExists() else { return [] }
        guard let entries = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]) else { throw RecoveryError.unavailable }
        var ids = Set<UUID>(); var count = 0
        for case let url as URL in entries {
            count += 1
            guard count <= 1_024 else { throw RecoveryError.tooManyRecords }
            let name = url.lastPathComponent
            guard let suffix = [".artifact.json", ".metadata.json"].first(where: name.hasSuffix) else { continue }
            let raw = String(name.dropLast(suffix.count))
            guard let id = UUID(uuidString: raw), id.uuidString.lowercased() == raw else { continue }
            ids.insert(id)
            guard ids.count <= 256 else { throw RecoveryError.tooManyRecords }
        }
        return try ids.sorted { $0.uuidString < $1.uuidString }.map(record)
    }
    private func record(id: UUID) throws -> Record {
        let artifact = try read(id: id, artifact: true)
        let metadata = try read(id: id, artifact: false)
        let decoded = artifact.flatMap { try? PortableProfileArtifact(validating: $0) }
        let name = decoded?.profileSummaries.first?.name ?? ""
        let scalars = name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let displayName = String(String(String.UnicodeScalarView(scalars)).prefix(160))
        return Record(id: id, name: displayName.isEmpty ? "Saved build \(id.uuidString.prefix(8))" : displayName,
            byteCount: (artifact?.count ?? 0) + (metadata?.count ?? 0), isProfileFile: decoded != nil,
            artifactHash: artifact.map(Self.digest), metadataHash: metadata.map(Self.digest))
    }
    public func prepare(_ record: Record) throws -> Export {
        guard try directoryExists() else { throw RecoveryError.unavailable }
        let artifact = try read(id: record.id, artifact: true)
        let metadata = try read(id: record.id, artifact: false)
        guard artifact.map(Self.digest) == record.artifactHash, metadata.map(Self.digest) == record.metadataHash else {
            throw RecoveryError.sourceChanged
        }
        guard artifact != nil || metadata != nil else { throw RecoveryError.unavailable }
        let id = record.id.uuidString.lowercased()
        if record.isProfileFile, let artifact {
            let checked = try PortableProfileArtifact(validating: artifact)
            return Export(filename: "thumble-recovered-\(id).json", data: checked.rawData, isProfileFile: true)
        }
        let archive = try Archive(accessMode: .create)
        if let artifact { try Self.add(artifact, name: "\(id).artifact.json", to: archive) }
        if let metadata { try Self.add(metadata, name: "\(id).metadata.json", to: archive) }
        let receipt: [String: Any] = ["version": 1, "recordID": id, "status": "manual-recovery-required",
            "artifactSHA256": record.artifactHash as Any? ?? NSNull(), "metadataSHA256": record.metadataHash as Any? ?? NSNull()]
        try Self.add(JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]), name: "recovery.json", to: archive)
        guard let data = archive.data else { throw RecoveryError.invalidArchive }
        return Export(filename: "thumble-recovery-\(id).zip", data: data, isProfileFile: false)
    }
    private func directoryExists() throws -> Bool {
        var status = stat()
        guard lstat(rootURL.path, &status) == 0 else {
            if errno == ENOENT { return false }
            throw RecoveryError.unsafeSource
        }
        guard status.st_mode & S_IFMT == S_IFDIR else { throw RecoveryError.unsafeSource }
        return true
    }
    private func read(id: UUID, artifact: Bool) throws -> Data? {
        let path = rootURL.appendingPathComponent("\(id.uuidString.lowercased()).\(artifact ? "artifact" : "metadata").json").path
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw RecoveryError.unsafeSource
        }
        defer { close(fd) }
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_mode & S_IFMT == S_IFREG, status.st_size >= 0 else { throw RecoveryError.unsafeSource }
        let maximum = artifact ? PortableProfileArtifact.maximumBytes : 32 * 1024
        guard status.st_size <= maximum else { throw RecoveryError.oversizedSource }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count == 0 { break }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw RecoveryError.unsafeSource }
            guard data.count + count <= maximum else { throw RecoveryError.oversizedSource }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func add(_ data: Data, name: String, to archive: Archive) throws {
        try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(data.count),
            modificationDate: Date(timeIntervalSince1970: 315_532_800), permissions: 0o600, compressionMethod: .deflate) { position, count in
            data.subdata(in: Int(position)..<(Int(position) + count))
        }
    }
}
