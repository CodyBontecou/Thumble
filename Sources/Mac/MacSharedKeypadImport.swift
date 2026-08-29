import Combine
import Foundation

/// Token-free review of a validated portable artifact for the Mac import sheet.
/// It deliberately retains no share reference, URL, or authorization token.
struct MacSharedKeypadReview: Sendable {
    let sourceHost: String
    let profileNames: [String]
    let byteCount: Int
    let hashPrefix: String
    let artifact: PortableProfileArtifact

    init(artifact: PortableProfileArtifact, sourceHost: String) {
        self.sourceHost = sourceHost
        profileNames = artifact.profileSummaries.map { MacSharedKeypadReview.sanitizedName($0.name) }
        byteCount = artifact.rawData.count
        hashPrefix = String(artifact.contentHash.value.prefix(12))
        self.artifact = artifact
    }

    init(artifact: PortableProfileArtifact, sourceName: String) {
        sourceHost = sourceName
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
    case fetching
    case readingFile
    case reviewing
    case importing
    case succeeded(String)
    case failed(String)
}

enum MacSharedKeypadImportError: Error, Equatable {
    case emptyLink
    case invalidShareLink
    case fileReadFailed
    case fileTooLarge

    var safeMessage: String {
        switch self {
        case .emptyLink: "Paste a Thumble shared-build link first."
        case .invalidShareLink: "That link is not a valid Thumble shared build. Copy the full link and try again."
        case .fileReadFailed: "The file could not be read."
        case .fileTooLarge: "The file exceeds the 8 MB shared-build size limit."
        }
    }

    static func safeMessage(for error: Error) -> String {
        if let error = error as? MacSharedKeypadImportError { return error.safeMessage }
        if let error = error as? BuilderArtifactFetchError { return error.localizedDescription }
        if error is PortableProfileArtifactError {
            return "The shared build failed Thumble’s safety or integrity checks."
        }
        return "The shared build could not be opened."
    }
}

/// Pure flow used by both the sheet and unit tests. It never retains a share
/// reference or token beyond the returned fetch closure boundary.
enum MacSharedKeypadImportFlow {
    /// Parses a pasted share link under the production-only policy and returns a
    /// transient reference. The caller must not persist the reference or text.
    static func parseShareLink(_ text: String) -> Result<BuilderArtifactShareReference, MacSharedKeypadImportError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.emptyLink) }
        guard let reference = try? BuilderArtifactShareReference(parsing: trimmed, policy: .production) else {
            return .failure(.invalidShareLink)
        }
        return .success(reference)
    }

    /// Validates downloaded/read bytes into a token-free review.
    static func validate(data: Data, sourceHost: String) throws -> MacSharedKeypadReview {
        let artifact = try PortableProfileArtifact(validating: data)
        return MacSharedKeypadReview(artifact: artifact, sourceHost: sourceHost)
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

/// Observable state machine for the "Import Shared Keypad…" sheet. The pasted
/// URL text is cleared the moment parsing succeeds so the token cannot linger
/// in view state; no URL or reference is ever persisted.
@MainActor
final class MacSharedKeypadImportModel: ObservableObject {
    @Published private(set) var phase: MacSharedKeypadImportPhase = .idle
    @Published var shareURLText = ""
    @Published private(set) var review: MacSharedKeypadReview?

    private let fetcher: any BuilderArtifactFetching
    private var fetchTask: Task<Void, Never>?

    init(fetcher: any BuilderArtifactFetching = URLSessionBuilderArtifactFetcher()) {
        self.fetcher = fetcher
    }

    deinit { fetchTask?.cancel() }

    var isBusy: Bool {
        switch phase {
        case .fetching, .readingFile, .importing: true
        case .idle, .reviewing, .succeeded, .failed: false
        }
    }

    func startFromShareURL() {
        guard !isBusy else { return }
        switch MacSharedKeypadImportFlow.parseShareLink(shareURLText) {
        case .failure(let error):
            phase = .failed(error.safeMessage)
            return
        case .success(let reference):
            // Clear the token-bearing text immediately after a successful parse.
            shareURLText = ""
            phase = .fetching
            let sourceHost = reference.sourceHost
            fetchTask = Task { [weak self, fetcher] in
                do {
                    let data = try await fetcher.fetch(reference)
                    try Task.checkCancellation()
                    let review = try MacSharedKeypadImportFlow.validate(data: data, sourceHost: sourceHost)
                    guard let self else { return }
                    self.review = review
                    self.phase = .reviewing
                } catch is CancellationError {
                    guard let self else { return }
                    self.phase = .idle
                } catch {
                    guard let self else { return }
                    self.phase = .failed(MacSharedKeypadImportError.safeMessage(for: error))
                }
            }
        }
    }

    func loadFile(url: URL) {
        guard !isBusy else { return }
        phase = .readingFile
        Task { [weak self] in
            do {
                let loaded = try MacSharedKeypadImportFlow.readArtifactFile(at: url)
                let review = try MacSharedKeypadImportFlow.validate(
                    data: loaded.data,
                    sourceHost: loaded.sourceName
                )
                guard let self else { return }
                self.review = review
                self.phase = .reviewing
            } catch {
                guard let self else { return }
                self.phase = .failed(MacSharedKeypadImportError.safeMessage(for: error))
            }
        }
    }

    /// Called by the sheet once the user confirms an import mode; the view layer
    /// owns the server call because it depends on MacControllerServer.
    func beginImport() {
        guard phase == .reviewing else { return }
        phase = .importing
    }

    func finishImport(summaryMessage: String) {
        guard phase == .importing else { return }
        phase = .succeeded(summaryMessage)
    }

    func failImport(safeMessage: String) {
        phase = .failed(safeMessage)
    }

    func cancelFetch() {
        fetchTask?.cancel()
        fetchTask = nil
        if phase == .fetching { phase = .idle }
    }

    func reset() {
        fetchTask?.cancel()
        fetchTask = nil
        shareURLText = ""
        review = nil
        phase = .idle
    }
}
