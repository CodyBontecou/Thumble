import Foundation
import XCTest

private final class BuilderArtifactURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub {
        var responseURL: URL?
        var status: Int
        var headers: [String: String]
        var chunks: [Data]
        var redirectURL: URL?
        var delay: TimeInterval = 0
    }

    private static let lock = NSLock()
    private static var stub = Stub(responseURL: nil, status: 200, headers: ["Content-Type": "application/json"], chunks: [], redirectURL: nil)
    private static var requests: [URLRequest] = []

    static func configure(_ next: Stub) {
        lock.lock(); stub = next; requests = []; lock.unlock()
    }

    static func capturedRequests() -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }; return requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let stub = Self.stub
        Self.lock.unlock()
        let deliver = { [weak self] in
            guard let self else { return }
            if let redirectURL = stub.redirectURL {
                let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil, headerFields: ["Location": redirectURL.absoluteString])!
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: redirectURL), redirectResponse: response)
                return
            }
            let response = HTTPURLResponse(
                url: stub.responseURL ?? request.url!,
                statusCode: stub.status,
                httpVersion: nil,
                headerFields: stub.headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in stub.chunks { client?.urlProtocol(self, didLoad: chunk) }
            client?.urlProtocolDidFinishLoading(self)
        }
        if stub.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + stub.delay, execute: deliver)
        } else {
            deliver()
        }
    }

    override func stopLoading() {}
}

private struct BuilderArtifactFailingFetcher: BuilderArtifactFetching {
    func fetch(_ reference: BuilderArtifactShareReference) async throws -> Data {
        throw BuilderArtifactFetchError.requestFailed
    }
}

private actor BuilderArtifactFakeFetcher: BuilderArtifactFetching {
    private let data: Data
    private let delayNanoseconds: UInt64
    private(set) var callCount = 0

    init(data: Data, delayNanoseconds: UInt64 = 0) {
        self.data = data
        self.delayNanoseconds = delayNanoseconds
    }

    func fetch(_ reference: BuilderArtifactShareReference) async throws -> Data {
        callCount += 1
        if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
        return data
    }
}

final class IOSBuilderArtifactPickupTests: XCTestCase {
    private let artifactID = "bar_" + String(repeating: "a", count: 64)
    private let token = String(repeating: "b", count: 64)

    private var shareURL: String {
        "https://thumble-mcp-gateway.fly.dev/share/\(artifactID)#token=\(token)"
    }

    private func fixtureData() throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Host/fixtures/profile-artifact/v1.json"))
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Thumble-Pickup-Tests-\(UUID().uuidString)", isDirectory: true)
    }

    func testFetcherUsesHeaderWithoutTokenInURLAndAcceptsBoundedJSON() async throws {
        let fixture = try fixtureData()
        BuilderArtifactURLProtocol.configure(.init(
            responseURL: nil,
            status: 200,
            headers: ["Content-Type": "application/json", "Content-Length": "\(fixture.count)"],
            chunks: [fixture.prefix(fixture.count / 2), fixture.suffix(fixture.count - fixture.count / 2)],
            redirectURL: nil
        ))
        let reference = try BuilderArtifactShareReference(parsing: shareURL)
        let fetcher = URLSessionBuilderArtifactFetcher(protocolClasses: [BuilderArtifactURLProtocol.self])
        let fetched = try await fetcher.fetch(reference)
        XCTAssertEqual(fetched, fixture)
        let request = try XCTUnwrap(BuilderArtifactURLProtocol.capturedRequests().first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "ThumbleShare \(token)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertFalse(request.url!.absoluteString.contains(token))
        XCTAssertNil(request.url?.fragment)
    }

    func testFetcherRejectsRedirectStatusMIMECrossOriginAndBothSizePaths() async throws {
        let reference = try BuilderArtifactShareReference(parsing: shareURL)
        let fetcher = URLSessionBuilderArtifactFetcher(protocolClasses: [BuilderArtifactURLProtocol.self])
        let cases: [(BuilderArtifactURLProtocol.Stub, BuilderArtifactFetchError)] = [
            (.init(responseURL: nil, status: 200, headers: ["Content-Type": "application/json"], chunks: [], redirectURL: URL(string: "https://evil.example/x")!), .redirectForbidden),
            (.init(responseURL: nil, status: 404, headers: ["Content-Type": "application/json"], chunks: [], redirectURL: nil), .unexpectedStatus),
            (.init(responseURL: nil, status: 200, headers: ["Content-Type": "text/plain"], chunks: [], redirectURL: nil), .invalidContentType),
            (.init(responseURL: URL(string: "https://evil.example/share/\(artifactID)"), status: 200, headers: ["Content-Type": "application/json"], chunks: [], redirectURL: nil), .crossOriginResponse),
            (.init(responseURL: nil, status: 200, headers: ["Content-Type": "application/json", "Content-Length": "\(PortableProfileArtifact.maximumBytes + 1)"], chunks: [], redirectURL: nil), .artifactTooLarge),
            (.init(responseURL: nil, status: 200, headers: ["Content-Type": "application/json"], chunks: [Data(count: PortableProfileArtifact.maximumBytes), Data([0])], redirectURL: nil), .artifactTooLarge),
            (.init(responseURL: nil, status: 200, headers: ["Content-Type": "application/json"], chunks: [Data(count: PortableProfileArtifact.maximumBytes + 1)], redirectURL: nil), .artifactTooLarge),
        ]
        for (stub, expected) in cases {
            BuilderArtifactURLProtocol.configure(stub)
            do {
                _ = try await fetcher.fetch(reference)
                XCTFail("Expected \(expected)")
            } catch {
                XCTAssertEqual(error as? BuilderArtifactFetchError, expected)
            }
        }
    }

    func testFetcherCancellationStopsRequestWithStableError() async throws {
        BuilderArtifactURLProtocol.configure(.init(
            responseURL: nil,
            status: 200,
            headers: ["Content-Type": "application/json"],
            chunks: [try fixtureData()],
            redirectURL: nil,
            delay: 1
        ))
        let reference = try BuilderArtifactShareReference(parsing: shareURL)
        let fetcher = URLSessionBuilderArtifactFetcher(protocolClasses: [BuilderArtifactURLProtocol.self])
        let task = Task { try await fetcher.fetch(reference) }
        try await Task.sleep(nanoseconds: 10_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? BuilderArtifactFetchError, .cancelled)
        }
    }

    @MainActor
    func testCoordinatorReviewCancelSaveRestartPreviewDeleteAndDedupe() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try IOSPendingBuilderArtifactStore(rootURL: root)
        let fetcher = BuilderArtifactFakeFetcher(data: try fixtureData(), delayNanoseconds: 30_000_000)
        let coordinator = IOSBuilderArtifactPickupCoordinator(fetcher: fetcher, store: store)

        XCTAssertEqual(coordinator.route(shareURL), .handled)
        XCTAssertEqual(coordinator.route(shareURL), .handled)
        try await waitUntil { coordinator.pendingReview != nil }
        let fetchCount = await fetcher.callCount
        XCTAssertEqual(fetchCount, 1)
        let firstReview = try XCTUnwrap(coordinator.pendingReview)
        XCTAssertEqual(coordinator.route(shareURL), .handled)
        try await Task.sleep(nanoseconds: 20_000_000)
        let fetchCountWithReviewPending = await fetcher.callCount
        XCTAssertEqual(fetchCountWithReviewPending, 1)
        XCTAssertEqual(firstReview.sourceHost, BuilderArtifactShareReference.productionHost)
        XCTAssertEqual(firstReview.profileNames, ["未来 Pad 🎛️"])
        XCTAssertEqual(firstReview.hashPrefix.count, 12)
        XCTAssertFalse(firstReview.sourceHost.contains(token))
        coordinator.cancelReview()
        let recordsAfterCancel = try await store.list()
        XCTAssertTrue(recordsAfterCancel.isEmpty)

        XCTAssertEqual(coordinator.route(shareURL), .handled)
        try await waitUntil { coordinator.pendingReview != nil }
        let review = try XCTUnwrap(coordinator.pendingReview)
        let (record, artifact) = try await coordinator.previewAndKeep(review)
        XCTAssertEqual(record.contentHash, artifact.contentHash.value)
        XCTAssertEqual(coordinator.pendingRecords.map(\.id), [record.id])

        let restartedStore = try IOSPendingBuilderArtifactStore(rootURL: root)
        let restarted = IOSBuilderArtifactPickupCoordinator(fetcher: fetcher, store: restartedStore)
        await restarted.refreshRecords()
        XCTAssertEqual(restarted.pendingRecords.map(\.id), [record.id])
        let loaded = try await restarted.loadForPreview(id: record.id)
        XCTAssertEqual(loaded.1.rawData, artifact.rawData)
        await restarted.delete(id: record.id)
        XCTAssertTrue(restarted.pendingRecords.isEmpty)
    }

    @MainActor
    func testCoordinatorPersistsOperationPerIntendedAuthorityAcrossFailures() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try IOSPendingBuilderArtifactStore(rootURL: root)
        let fetcher = BuilderArtifactFakeFetcher(data: try fixtureData())
        let coordinator = IOSBuilderArtifactPickupCoordinator(fetcher: fetcher, store: store)
        XCTAssertEqual(coordinator.route(shareURL), .handled)
        try await waitUntil { coordinator.pendingReview != nil }
        let review = try XCTUnwrap(coordinator.pendingReview)
        let (record, _) = try await coordinator.previewAndKeep(review)

        let first = try await coordinator.prepareAdoption(id: record.id, intendedServerID: "server-a")
        XCTAssertEqual(first.0.intendedServerID, "server-a")
        var failed = IOSBuilderArtifactAdoptionState(
            metadata: ProfileArtifactAdoptionMetadata(
                operationID: first.2,
                recordID: record.id,
                intendedServerID: "server-a",
                contentHash: first.0.contentHash,
                rawSHA256: first.0.rawSHA256,
                byteCount: first.0.bytes,
                chunkCount: ProfileArtifactAdoptionMetadata.chunkCount(forByteCount: first.0.bytes)
            ),
            phase: .failed(.importFailed)
        )
        await coordinator.applyAdoptionState(failed)
        let sameAuthority = try await coordinator.prepareAdoption(id: record.id, intendedServerID: "server-a")
        XCTAssertEqual(sameAuthority.2, first.2)
        failed.phase = .failed(.disconnected)
        await coordinator.applyAdoptionState(failed)
        let otherAuthority = try await coordinator.prepareAdoption(id: record.id, intendedServerID: "server-b")
        XCTAssertNotEqual(otherAuthority.2, first.2)
        XCTAssertEqual(otherAuthority.0.intendedServerID, "server-b")
        await coordinator.applyAdoptionState(IOSBuilderArtifactAdoptionState(
            metadata: ProfileArtifactAdoptionMetadata(
                operationID: otherAuthority.2,
                recordID: record.id,
                intendedServerID: "server-b",
                contentHash: otherAuthority.0.contentHash,
                rawSHA256: otherAuthority.0.rawSHA256,
                byteCount: otherAuthority.0.bytes,
                chunkCount: ProfileArtifactAdoptionMetadata.chunkCount(forByteCount: otherAuthority.0.bytes)
            ),
            phase: .failed(.disconnected)
        ))

        do {
            _ = try await coordinator.prepareAdoption(id: record.id, intendedServerID: "bad\nserver")
            XCTFail("Expected invalid server identity")
        } catch {
            XCTAssertEqual(error as? IOSPendingBuilderArtifactStoreError, .invalidStateMetadata)
        }

        let metadataB = ProfileArtifactAdoptionMetadata(
            operationID: otherAuthority.2,
            recordID: record.id,
            intendedServerID: "server-b",
            contentHash: otherAuthority.0.contentHash,
            rawSHA256: otherAuthority.0.rawSHA256,
            byteCount: otherAuthority.0.bytes,
            chunkCount: ProfileArtifactAdoptionMetadata.chunkCount(forByteCount: otherAuthority.0.bytes)
        )
        await coordinator.applyAdoptionState(.init(
            metadata: metadataB,
            phase: .awaitingAuthoritativeSnapshot
        ))
        let retainedIDs = try await store.list().map(\.id)
        XCTAssertEqual(retainedIDs, [record.id])
        await coordinator.applyAdoptionState(.init(
            metadata: metadataB,
            phase: .succeeded(destinationProfileIDs: [UUID()], replayed: false)
        ))
        let remainingRecords = try await store.list()
        XCTAssertTrue(remainingRecords.isEmpty)
    }

    @MainActor
    func testCoordinatorMalformedOrInvalidArtifactNeverStores() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try IOSPendingBuilderArtifactStore(rootURL: root)
        let fetcher = BuilderArtifactFakeFetcher(data: Data("{}".utf8))
        let coordinator = IOSBuilderArtifactPickupCoordinator(fetcher: fetcher, store: store)

        XCTAssertEqual(coordinator.route("pairing payload"), .notAShare)
        XCTAssertEqual(coordinator.route("https://evil.example/share/nope#token=bad"), .handled)
        XCTAssertNotNil(coordinator.safeErrorMessage)
        XCTAssertNil(coordinator.pendingReview)
        let recordsAfterMalformedLink = try await store.list()
        XCTAssertTrue(recordsAfterMalformedLink.isEmpty)

        XCTAssertEqual(coordinator.route(shareURL), .handled)
        try await waitUntil { !coordinator.isFetching }
        XCTAssertNil(coordinator.pendingReview)
        XCTAssertNotNil(coordinator.safeErrorMessage)
        let recordsAfterInvalidArtifact = try await store.list()
        XCTAssertTrue(recordsAfterInvalidArtifact.isEmpty)

        let failedFetch = IOSBuilderArtifactPickupCoordinator(
            fetcher: BuilderArtifactFailingFetcher(),
            store: store
        )
        XCTAssertEqual(failedFetch.route(shareURL), .handled)
        try await waitUntil { !failedFetch.isFetching }
        XCTAssertNil(failedFetch.pendingReview)
        XCTAssertEqual(failedFetch.safeErrorMessage, BuilderArtifactFetchError.requestFailed.localizedDescription)
        let recordsAfterFailedFetch = try await store.list()
        XCTAssertTrue(recordsAfterFailedFetch.isEmpty)
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 2,
        _ predicate: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() >= deadline { throw NSError(domain: "PickupTests", code: 1) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
