import Foundation
import XCTest

final class MacSharedKeypadImportTests: XCTestCase {
    private func fixtureData() throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Host/fixtures/profile-artifact/v1.json"))
    }

    func testValidateProducesTokenFreeReview() throws {
        let fixture = try fixtureData()
        let review = try MacSharedKeypadImportFlow.validate(data: fixture, sourceName: "host")
        XCTAssertEqual(review.sourceName, "host")
        XCTAssertEqual(review.profileNames, ["未来 Pad 🎛️"])
        XCTAssertEqual(review.byteCount, fixture.count)
        XCTAssertEqual(review.hashPrefix.count, 12)
        XCTAssertThrowsError(
            try MacSharedKeypadImportFlow.validate(data: Data("{}".utf8), sourceName: "host")
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
    func testModelImportLifecycleAndFileLoad() async throws {
        let fixture = try fixtureData()
        let model = MacSharedKeypadImportModel()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Thumble-Mac-Model-File-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("builder-artifact.json")
        try fixture.write(to: fileURL)
        model.loadFile(url: fileURL)
        await waitUntil { model.phase == .reviewing }
        XCTAssertEqual(model.review?.sourceName, "builder-artifact")
        XCTAssertEqual(model.review?.artifact.rawData, fixture)
        model.beginImport()
        XCTAssertEqual(model.phase, .importing)
        model.finishImport(summaryMessage: "Imported 1 setup")
        XCTAssertEqual(model.phase, .succeeded("Imported 1 setup"))
        model.reset()
        model.loadFile(url: directory.appendingPathComponent("missing.json"))
        await waitUntil { if case .failed = model.phase { return true }; return false }
        model.reset()
        model.loadFile(url: fileURL)
        model.reset()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.review)
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
