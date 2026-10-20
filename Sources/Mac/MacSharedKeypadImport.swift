import Combine
import Foundation

/// A validated local profile file and its review metadata. Original bytes remain intact.
struct MacSharedKeypadReview: Sendable {
    let sourceName: String
    let profileNames: [String]
    let byteCount: Int
    let hashPrefix: String
    let artifact: PortableProfileArtifact

    init(artifact: PortableProfileArtifact, sourceName: String) {
        self.sourceName = sourceName
        profileNames = artifact.profileSummaries.map { MacSharedKeypadReview.sanitizedName($0.name) }
        byteCount = artifact.rawData.count
        hashPrefix = String(artifact.contentHash.value.prefix(12))
        self.artifact = artifact
    }

    static func sanitizedName(_ value: String) -> String {
        let scalars = value.unicodeScalars.map { scalar -> Unicode.Scalar in
            CharacterSet.controlCharacters.contains(scalar) ? Unicode.Scalar(0x20)! : scalar
        }
        let result = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "Untitled Setup" : result
    }
}

enum MacSharedKeypadImportPhase: Equatable {
    case idle
    case readingFile
    case reviewing
    case importing
    case succeeded(String)
    case failed(String)
}

enum MacSharedKeypadImportError: Error, Equatable {
    case fileReadFailed
    case fileTooLarge

    var safeMessage: String {
        switch self {
        case .fileReadFailed: "The file could not be read."
        case .fileTooLarge: "The file exceeds the 8 MB profile file size limit."
        }
    }

    static func safeMessage(for error: Error) -> String {
        if let error = error as? MacSharedKeypadImportError { return error.safeMessage }
        if error is PortableProfileArtifactError {
            return "The profile file failed Thumble’s safety or integrity checks."
        }
        return "The profile file could not be opened."
    }
}

/// Local portable-file validation shared by the sheet and regression tests.
enum MacSharedKeypadImportFlow {
    /// Validates local file bytes into a review without changing the source.
    static func validate(data: Data, sourceName: String) throws -> MacSharedKeypadReview {
        let artifact = try PortableProfileArtifact(validating: data)
        return MacSharedKeypadReview(artifact: artifact, sourceName: sourceName)
    }

    /// Bounded, security-scoped local artifact read (8 MiB cap) returning raw
    /// bytes plus a display-safe source name derived from the filename.
    static func readArtifactFile(at url: URL) throws -> (data: Data, sourceName: String) {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer { if didStartAccessing { url.stopAccessingSecurityScopedResource() } }

        let path = url.path
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw MacSharedKeypadImportError.fileReadFailed }
        defer { close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_size >= 0
        else { throw MacSharedKeypadImportError.fileReadFailed }
        guard status.st_size <= PortableProfileArtifact.maximumBytes else {
            throw MacSharedKeypadImportError.fileTooLarge
        }

        var data = Data()
        data.reserveCapacity(Int(status.st_size))
        var buffer = [UInt8](repeating: 0, count: min(64 * 1024, max(1, Int(status.st_size))))
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(descriptor, raw.baseAddress, raw.count)
            }
            if count == 0 { break }
            guard count > 0,
                  data.count + count <= PortableProfileArtifact.maximumBytes
            else { throw MacSharedKeypadImportError.fileTooLarge }
            data.append(contentsOf: buffer.prefix(count))
        }

        let sourceName = url.deletingPathExtension().lastPathComponent
        return (data, sourceName)
    }
}

/// Local file review/import. No hosted URL or network client is retained.
@MainActor
final class MacSharedKeypadImportModel: ObservableObject {
    @Published private(set) var phase: MacSharedKeypadImportPhase = .idle
    @Published private(set) var review: MacSharedKeypadReview?
    private var readTask: Task<Void, Never>?
    deinit { readTask?.cancel() }
    var isBusy: Bool {
        switch phase {
        case .readingFile, .importing: true
        case .idle, .reviewing, .succeeded, .failed: false
        }
    }
    func loadFile(url: URL) {
        guard !isBusy else { return }
        phase = .readingFile
        readTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                let loaded = try MacSharedKeypadImportFlow.readArtifactFile(at: url)
                return try MacSharedKeypadImportFlow.validate(data: loaded.data, sourceName: loaded.sourceName)
            }
            do {
                let review = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                guard let self else { return }
                self.review = review; self.phase = .reviewing
            } catch is CancellationError { }
            catch {
                guard let self, !Task.isCancelled else { return }
                self.phase = .failed(MacSharedKeypadImportError.safeMessage(for: error))
            }
        }
    }
    func beginImport() { guard phase == .reviewing else { return }; phase = .importing }
    func finishImport(summaryMessage: String) { guard phase == .importing else { return }; phase = .succeeded(summaryMessage) }
    func failImport(safeMessage: String) { phase = .failed(safeMessage) }
    func cancelRead() { readTask?.cancel(); readTask = nil; if phase == .readingFile { phase = .idle } }
    func reset() { cancelRead(); review = nil; phase = .idle }
}
