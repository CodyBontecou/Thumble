import Combine
import Foundation

/// Immutable review data. It intentionally retains no share reference or authorization token.
public struct IOSBuilderArtifactReview: Identifiable, Sendable {
    public let id: UUID
    public let artifactID: String
    public let sourceHost: String
    public let profileNames: [String]
    public let byteCount: Int
    public let hashPrefix: String
    let artifact: PortableProfileArtifact

    init(reference: BuilderArtifactShareReference, artifact: PortableProfileArtifact) {
        id = UUID()
        artifactID = reference.artifactID
        sourceHost = reference.sourceHost
        profileNames = artifact.profileSummaries.map { Self.sanitizedName($0.name) }
        byteCount = artifact.rawData.count
        hashPrefix = String(artifact.contentHash.value.prefix(12))
        self.artifact = artifact
    }

    private static func sanitizedName(_ value: String) -> String {
        let scalars = value.unicodeScalars.map { scalar -> Unicode.Scalar in
            CharacterSet.controlCharacters.contains(scalar) ? Unicode.Scalar(0x20)! : scalar
        }
        let result = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "Untitled Profile" : result
    }
}

@MainActor
final class IOSBuilderArtifactPickupCoordinator: ObservableObject {
    enum RouteResult: Equatable {
        case notAShare
        case handled
    }

    @Published private(set) var pendingReview: IOSBuilderArtifactReview?
    @Published private(set) var pendingRecords: [IOSPendingBuilderArtifactRecord] = []
    @Published private(set) var isFetching = false
    @Published private(set) var isKeepingReview = false
    @Published var safeErrorMessage: String?

    private let fetcher: any BuilderArtifactFetching
    private let store: IOSPendingBuilderArtifactStore?
    private var pickupTask: Task<Void, Never>?
    private var activeArtifactID: String?
    private var didRecoverInterruptedAdoptions = false

    init() {
        fetcher = URLSessionBuilderArtifactFetcher()
        store = try? IOSPendingBuilderArtifactStore()
    }

    init(
        fetcher: any BuilderArtifactFetching,
        store: IOSPendingBuilderArtifactStore?
    ) {
        self.fetcher = fetcher
        self.store = store
    }

    deinit { pickupTask?.cancel() }

    @discardableResult
    func route(
        _ value: String,
        policy: BuilderArtifactShareReference.Policy = .production
    ) -> RouteResult {
        let reference: BuilderArtifactShareReference
        do {
            reference = try BuilderArtifactShareReference(parsing: value, policy: policy)
        } catch {
            guard BuilderArtifactShareReference.resemblesHostedShare(value) else { return .notAShare }
            safeErrorMessage = (error as? BuilderArtifactShareError)?.localizedDescription
                ?? "This is not a valid Thumble shared-build link."
            return .handled
        }
        startPickup(reference)
        return .handled
    }

    @discardableResult
    func route(
        _ url: URL,
        policy: BuilderArtifactShareReference.Policy = .production
    ) -> RouteResult {
        route(url.absoluteString, policy: policy)
    }

    func cancelReview() {
        pendingReview = nil
    }

    func refreshRecords() async {
        guard let store else { pendingRecords = []; return }
        do {
            var records = try await store.list()
            if !didRecoverInterruptedAdoptions {
                didRecoverInterruptedAdoptions = true
                for record in records where record.state == .adopting {
                    _ = try await store.updateState(
                        id: record.id,
                        state: .failed,
                        operationID: record.operationID,
                        lastSafeErrorCode: ProfileArtifactAdoptionErrorCode.disconnected.rawValue
                    )
                }
                records = try await store.list()
            }
            pendingRecords = records
        } catch {
            pendingRecords = []
            safeErrorMessage = "Pending shared builds could not be loaded."
        }
    }

    func previewAndKeep(_ review: IOSBuilderArtifactReview) async throws -> (IOSPendingBuilderArtifactRecord, PortableProfileArtifact) {
        guard !isKeepingReview, pendingReview?.id == review.id, let store else {
            throw IOSPendingBuilderArtifactStoreError.fileOperationFailed
        }
        isKeepingReview = true
        defer { isKeepingReview = false }
        let record = try await store.save(review.artifact)
        pendingReview = nil
        await refreshRecords()
        return (record, review.artifact)
    }

    func loadForPreview(id: UUID) async throws -> (IOSPendingBuilderArtifactRecord, PortableProfileArtifact) {
        guard let store,
              let record = pendingRecords.first(where: { $0.id == id })
        else { throw IOSPendingBuilderArtifactStoreError.recordNotFound }
        return (record, try await store.load(id: id))
    }

    func prepareAdoption(
        id: UUID,
        intendedServerID: String
    ) async throws -> (IOSPendingBuilderArtifactRecord, PortableProfileArtifact, UUID) {
        guard let store,
              ProfileArtifactAdoptionMetadata.isValidServerID(intendedServerID),
              let current = pendingRecords.first(where: { $0.id == id }),
              current.state != .adopting,
              current.state != .adopted
        else { throw IOSPendingBuilderArtifactStoreError.invalidStateMetadata }
        let artifact = try await store.load(id: id)
        let operationID: UUID
        if current.intendedServerID == intendedServerID,
           let existing = current.operationID {
            operationID = existing
        } else {
            operationID = UUID()
        }
        let updated = try await store.updateState(
            id: id,
            state: .adopting,
            operationID: operationID,
            intendedServerID: intendedServerID,
            lastSafeErrorCode: nil
        )
        await refreshRecordsPreservingActiveAdoption()
        return (updated, artifact, operationID)
    }

    func applyAdoptionState(_ state: IOSBuilderArtifactAdoptionState) async {
        guard let store,
              pendingRecords.contains(where: { $0.id == state.metadata.recordID })
        else { return }
        do {
            switch state.phase {
            case .uploading, .awaitingAuthoritativeSnapshot:
                break
            case .failed(let code):
                _ = try await store.updateState(
                    id: state.metadata.recordID,
                    state: .failed,
                    operationID: state.metadata.operationID,
                    intendedServerID: state.metadata.intendedServerID,
                    lastSafeErrorCode: code.rawValue
                )
                await refreshRecords()
            case .succeeded:
                _ = try await store.updateState(
                    id: state.metadata.recordID,
                    state: .adopted,
                    operationID: state.metadata.operationID,
                    lastSafeErrorCode: nil
                )
                try await store.delete(id: state.metadata.recordID)
                await refreshRecords()
            }
        } catch {
            safeErrorMessage = "The shared build adoption state could not be saved."
        }
    }

    func markAdoptionStartFailed(recordID: UUID, operationID: UUID) async {
        guard let store else { return }
        do {
            _ = try await store.updateState(
                id: recordID,
                state: .failed,
                operationID: operationID,
                lastSafeErrorCode: ProfileArtifactAdoptionErrorCode.unsupported.rawValue
            )
            await refreshRecords()
        } catch {
            safeErrorMessage = "The shared build could not be prepared for adoption."
        }
    }

    func delete(id: UUID) async {
        guard let store else { return }
        do {
            try await store.delete(id: id)
            await refreshRecords()
        } catch {
            safeErrorMessage = "The pending shared build could not be deleted."
        }
    }

    private func refreshRecordsPreservingActiveAdoption() async {
        guard let store else { return }
        do { pendingRecords = try await store.list() }
        catch { safeErrorMessage = "Pending shared builds could not be loaded." }
    }

    private func startPickup(_ reference: BuilderArtifactShareReference) {
        if activeArtifactID == reference.artifactID || pendingReview?.artifactID == reference.artifactID {
            return
        }
        pickupTask?.cancel()
        activeArtifactID = reference.artifactID
        isFetching = true
        safeErrorMessage = nil
        pickupTask = Task { [weak self, fetcher] in
            do {
                let data = try await fetcher.fetch(reference)
                try Task.checkCancellation()
                let artifact = try PortableProfileArtifact(validating: data)
                try Task.checkCancellation()
                guard let self, self.activeArtifactID == reference.artifactID else { return }
                self.pendingReview = IOSBuilderArtifactReview(reference: reference, artifact: artifact)
                self.isFetching = false
                self.activeArtifactID = nil
            } catch is CancellationError {
                guard let self, self.activeArtifactID == reference.artifactID else { return }
                self.isFetching = false
                self.activeArtifactID = nil
            } catch {
                guard let self, self.activeArtifactID == reference.artifactID else { return }
                self.isFetching = false
                self.activeArtifactID = nil
                self.safeErrorMessage = Self.safeMessage(for: error)
            }
        }
    }

    private static func safeMessage(for error: Error) -> String {
        if let error = error as? BuilderArtifactFetchError {
            return error.localizedDescription
        }
        if error is PortableProfileArtifactError {
            return "The shared build failed Thumble’s safety or integrity checks."
        }
        return "The shared build could not be opened."
    }

}
