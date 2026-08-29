import Foundation
import XCTest

final class IOSPendingBuilderArtifactStoreTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        var date: Date
        init(_ date: Date) { self.date = date }
    }

    private func fixtureData() throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Host/fixtures/profile-artifact/v1.json"))
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Thumble-Pending-Artifact-Tests-\(UUID().uuidString)", isDirectory: true)
    }

    func testSaveListLoadStateDeletePreservesExactBytesAndMetadataIsSanitized() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifact = try PortableProfileArtifact(validating: fixtureData())
        let store = try IOSPendingBuilderArtifactStore(rootURL: root)

        let record = try await store.save(artifact)
        XCTAssertEqual(record.bytes, artifact.rawData.count)
        XCTAssertEqual(record.contentHash, artifact.contentHash.value)
        XCTAssertEqual(record.rawSHA256.count, 64)
        let listed = try await store.list()
        let loadedRawData = try await store.loadRawData(id: record.id)
        let loadedArtifact = try await store.load(id: record.id)
        XCTAssertEqual(listed, [record])
        XCTAssertEqual(loadedRawData, artifact.rawData)
        XCTAssertEqual(loadedArtifact.rawData, artifact.rawData)

        let operationID = UUID()
        let adopting = try await store.updateState(id: record.id, state: .adopting, operationID: operationID)
        XCTAssertEqual(adopting.state, .adopting)
        XCTAssertEqual(adopting.operationID, operationID)
        let failed = try await store.updateState(id: record.id, state: .failed, lastSafeErrorCode: "host_unavailable")
        XCTAssertEqual(failed.lastSafeErrorCode, "host_unavailable")
        await XCTAssertThrowsAsync(try await store.updateState(id: record.id, state: .failed, lastSafeErrorCode: "https://secret.invalid")) {
            XCTAssertEqual($0 as? IOSPendingBuilderArtifactStoreError, .invalidStateMetadata)
        }

        let metadataURL = root.appendingPathComponent("\(record.id.uuidString.lowercased()).metadata.json")
        let metadata = try Data(contentsOf: metadataURL)
        XCTAssertLessThanOrEqual(metadata.count, IOSPendingBuilderArtifactStore.maximumMetadataBytes)
        let metadataText = String(decoding: metadata, as: UTF8.self).lowercased()
        XCTAssertFalse(metadataText.contains("token"))
        XCTAssertFalse(metadataText.contains("shareurl"))
        XCTAssertFalse(metadataText.contains("rawjson"))
        XCTAssertFalse(metadataText.contains("futuretoplevel"))

        let values = try metadataURL.resourceValues(forKeys: [.isExcludedFromBackupKey, .isRegularFileKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
        XCTAssertEqual(values.isRegularFile, true)
        let metadataAttributes = try FileManager.default.attributesOfItem(atPath: metadataURL.path)
        let rootAttributes = try FileManager.default.attributesOfItem(atPath: root.path)
        XCTAssertEqual((metadataAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((rootAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)

        try await store.delete(id: record.id)
        let recordsAfterDelete = try await store.list()
        XCTAssertTrue(recordsAfterDelete.isEmpty)
    }

    func testExpiryReconciliationOrphansTempsAndDigestMismatchAreRemoved() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = Clock(Date(timeIntervalSince1970: 1_000))
        let artifact = try PortableProfileArtifact(validating: fixtureData())
        var store: IOSPendingBuilderArtifactStore? = try IOSPendingBuilderArtifactStore(rootURL: root, now: { clock.date })
        let expired = try await store!.save(artifact, lifetime: 1)
        let digest = try await store!.save(artifact)
        let digestURL = root.appendingPathComponent("\(digest.id.uuidString.lowercased()).artifact.json")
        var bytes = try Data(contentsOf: digestURL)
        let original = String(decoding: bytes, as: UTF8.self)
        let changed = original.replacingOccurrences(of: "\"exportedAt\": 1787900000000", with: "\"exportedAt\": 1787900000001")
        XCTAssertNotEqual(changed, original)
        bytes = Data(changed.utf8)
        try bytes.write(to: digestURL)

        let orphanID = UUID().uuidString.lowercased()
        try Data("orphan".utf8).write(to: root.appendingPathComponent("\(orphanID).artifact.json"))
        try Data("temp".utf8).write(to: root.appendingPathComponent(".\(UUID().uuidString.lowercased()).tmp"))
        store = nil
        clock.date.addTimeInterval(2)
        let reconciled = try IOSPendingBuilderArtifactStore(rootURL: root, now: { clock.date })
        let records = try await reconciled.list()
        XCTAssertFalse(records.contains(where: { $0.id == expired.id }))
        XCTAssertFalse(records.contains(where: { $0.id == digest.id }))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testSymlinkAndNonregularFilesAreRejectedDuringReconciliation() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = UUID().uuidString.lowercased()
        let external = root.deletingLastPathComponent().appendingPathComponent("external-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: external) }
        try Data("external".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("\(id).artifact.json"),
            withDestinationURL: external
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("\(id).metadata.json"),
            withIntermediateDirectories: false
        )

        let store = try IOSPendingBuilderArtifactStore(rootURL: root)
        let records = try await store.list()
        XCTAssertTrue(records.isEmpty)
        XCTAssertEqual(try Data(contentsOf: external), Data("external".utf8))
    }

    func testRecordQuotaEvictsOldestButNeverAdopting() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = Clock(Date(timeIntervalSince1970: 10_000))
        let artifact = try PortableProfileArtifact(validating: fixtureData())
        let store = try IOSPendingBuilderArtifactStore(rootURL: root, now: { clock.date })
        let protected = try await store.save(artifact)
        _ = try await store.updateState(id: protected.id, state: .adopting)
        for _ in 1..<IOSPendingBuilderArtifactStore.maximumRecords {
            clock.date.addTimeInterval(1)
            _ = try await store.save(artifact)
        }
        clock.date.addTimeInterval(1)
        _ = try await store.save(artifact)
        let records = try await store.list()
        XCTAssertEqual(records.count, IOSPendingBuilderArtifactStore.maximumRecords)
        XCTAssertTrue(records.contains(where: { $0.id == protected.id && $0.state == .adopting }))
    }

    func testArtifactsAreNotStoredInUserDefaults() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "Thumble.PendingArtifact.Tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let before = defaults.dictionaryRepresentation()
        let store = try IOSPendingBuilderArtifactStore(rootURL: root)
        _ = try await store.save(PortableProfileArtifact(validating: fixtureData()))
        XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before as NSDictionary)
    }

    private func XCTAssertThrowsAsync(
        _ operation: @autoclosure () async throws -> Any,
        handler: (Error) -> Void
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected async operation to throw")
        } catch {
            handler(error)
        }
    }
}
