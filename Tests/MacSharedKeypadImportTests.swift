import Foundation
import XCTest

final class MacSharedKeypadImportTests: XCTestCase {
    private let artifactID = "bar_" + String(repeating: "a", count: 64)
    private let token = String(repeating: "b", count: 64)

    private func fixtureData() throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Host/fixtures/profile-artifact/v1.json"))
    }

    private var shareURL: String {
        "https://thumble-mcp-gateway.fly.dev/share/\(artifactID)#token=\(token)"
    }

    func testParseShareLinkAcceptsProductionOnlyAndTrimsWhitespace() throws {
        let reference = try XCTUnwrap(
            try MacSharedKeypadImportFlow.parseShareLink("  \(shareURL)  \n").get()
        )
        XCTAssertEqual(reference.sourceHost, BuilderArtifactShareReference.productionHost)
        XCTAssertEqual(
            MacSharedKeypadImportFlow.parseShareLink("   ").failureValue,
            .emptyLink
        )
        XCTAssertEqual(
            MacSharedKeypadImportFlow.parseShareLink("https://evil.example/share/nope#token=bad").failureValue,
            .invalidShareLink
        )
        XCTAssertEqual(
            MacSharedKeypadImportFlow.parseShareLink("http://localhost:8080/share/\(artifactID)#token=\(token)").failureValue,
            .invalidShareLink
        )
    }

    func testValidateProducesTokenFreeReview() throws {
        let fixture = try fixtureData()
        let review = try MacSharedKeypadImportFlow.validate(data: fixture, sourceHost: "host")
        XCTAssertEqual(review.sourceHost, "host")
        XCTAssertEqual(review.profileNames, ["未来 Pad 🎛️"])
        XCTAssertEqual(review.byteCount, fixture.count)
        XCTAssertEqual(review.hashPrefix.count, 12)
        XCTAssertThrowsError(
            try MacSharedKeypadImportFlow.validate(data: Data("{}".utf8), sourceHost: "host")
        ) { error in
            XCTAssertTrue(error is PortableProfileArtifactError)
        }
    }

    func testReadArtifactFileBoundedAndRejectsSymlinks() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Thumble-Mac-Shared-Import-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let fixture = try fixtureData()
        let artifactURL = directory.appendingPathComponent("shared-setup.json")
        try fixture.write(to: artifactURL)
        let loaded = try MacSharedKeypadImportFlow.readArtifactFile(at: artifactURL)
        XCTAssertEqual(loaded.data, fixture)
        XCTAssertEqual(loaded.sourceName, "shared-setup")

        let oversizeURL = directory.appendingPathComponent("oversize.json")
        try Data(repeating: 0x20, count: PortableProfileArtifact.maximumBytes + 1).write(to: oversizeURL)
        XCTAssertThrowsError(try MacSharedKeypadImportFlow.readArtifactFile(at: oversizeURL)) { error in
            XCTAssertEqual(error as? MacSharedKeypadImportError, .fileTooLarge)
        }

        let target = directory.appendingPathComponent("target.json")
        try fixture.write(to: target)
        let linkURL = directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: target)
        XCTAssertThrowsError(try MacSharedKeypadImportFlow.readArtifactFile(at: linkURL)) { error in
            XCTAssertEqual(error as? MacSharedKeypadImportError, .fileReadFailed)
        }
    }

    @MainActor
    func testModelClearsURLOnParseAndMapsSafeErrors() async throws {
        final class FailingFetcher: BuilderArtifactFetching, @unchecked Sendable {
            func fetch(_ reference: BuilderArtifactShareReference) async throws -> Data {
                throw BuilderArtifactFetchError.requestFailed
            }
        }
        final class GoodFetcher: BuilderArtifactFetching, @unchecked Sendable {
            func fetch(_ reference: BuilderArtifactShareReference) async throws -> Data {
                Data("{}".utf8)
            }
        }

        let failing = MacSharedKeypadImportModel(fetcher: FailingFetcher())
        failing.shareURLText = shareURL
        failing.startFromShareURL()
        XCTAssertEqual(failing.shareURLText, "", "token-bearing text must clear immediately after parse")
        await waitUntil { failing.phase != .fetching }
        guard case .failed(let message) = failing.phase else {
            return XCTFail("expected failure")
        }
        XCTAssertFalse(message.contains(token))
        XCTAssertFalse(message.contains(artifactID))

        let good = MacSharedKeypadImportModel(fetcher: GoodFetcher())
        good.shareURLText = shareURL
        good.startFromShareURL()
        XCTAssertEqual(good.shareURLText, "")
        await waitUntil { good.phase != .fetching }
        guard case .failed(let invalidMessage) = good.phase else {
            return XCTFail("expected invalid-artifact failure")
        }
        XCTAssertFalse(invalidMessage.contains(token))
        good.reset()
        XCTAssertEqual(good.phase, .idle)
        XCTAssertNil(good.review)
    }

    @MainActor
    func testModelImportLifecycleAndFileLoad() async throws {
        final class FixtureFetcher: BuilderArtifactFetching, @unchecked Sendable {
            let data: Data
            init(data: Data) { self.data = data }
            func fetch(_ reference: BuilderArtifactShareReference) async throws -> Data { data }
        }
        let fixture = try fixtureData()
        let model = MacSharedKeypadImportModel(fetcher: FixtureFetcher(data: fixture))
        model.shareURLText = shareURL
        model.startFromShareURL()
        await waitUntil { model.phase == .reviewing }
        let review = try XCTUnwrap(model.review)
        XCTAssertEqual(review.profileNames.first, "未来 Pad 🎛️")

        model.beginImport()
        XCTAssertEqual(model.phase, .importing)
        model.finishImport(summaryMessage: "Imported 1 setup")
        XCTAssertEqual(model.phase, .succeeded("Imported 1 setup"))
        model.reset()

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Thumble-Mac-Model-File-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("builder-artifact.json")
        try fixture.write(to: fileURL)
        model.loadFile(url: fileURL)
        await waitUntil { model.phase == .reviewing }
        XCTAssertEqual(model.review?.sourceHost, "builder-artifact")
        model.reset()
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 2,
        _ predicate: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() >= deadline { return XCTFail("condition not met before timeout") }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private extension Result {
    var failureValue: Failure? {
        guard case .failure(let failure) = self else { return nil }
        return failure
    }
}
