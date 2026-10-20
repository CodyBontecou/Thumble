import Foundation
import XCTest
import ZIPFoundation

final class PendingProfileRecoveryTests: XCTestCase {
    private let id = UUID(uuidString: "b2100000-0000-0000-0000-000000000001")!
    private func fixture() throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Host/fixtures/profile-artifact/v1.json"))
    }
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Thumble-Recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func path(_ root: URL, _ artifact: Bool) -> URL {
        root.appendingPathComponent("\(id.uuidString.lowercased()).\(artifact ? "artifact" : "metadata").json")
    }
    private func snapshot(_ root: URL) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).map {
            ($0.lastPathComponent, try Data(contentsOf: $0))
        })
    }
    func testMissingDirectoryIsNotCreatedAndExpiredInterruptedMetadataIsUntouched() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let absent = root.appendingPathComponent("not-created")
        XCTAssertTrue(try PendingProfileRecovery(rootURL: absent).list().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path))
        let bytes = try fixture()
        try bytes.write(to: path(root, true))
        let metadata = Data(#"{"expiresAt":0,"state":"adopting","future":{"preserve":"exact"}}"#.utf8)
        try metadata.write(to: path(root, false))
        try Data([1, 2]).write(to: root.appendingPathComponent("unknown-file"))
        let before = try snapshot(root); let reader = PendingProfileRecovery(rootURL: root)
        let record = try XCTUnwrap(reader.list().first)
        XCTAssertTrue(record.isProfileFile)
        XCTAssertEqual(record.byteCount, bytes.count + metadata.count)
        let export = try reader.prepare(record)
        XCTAssertTrue(export.isProfileFile); XCTAssertTrue(export.filename.hasSuffix(".json"))
        XCTAssertEqual(export.data, bytes)
        XCTAssertEqual(try reader.list(), [record]); XCTAssertEqual(try snapshot(root), before)
        XCTAssertEqual(try PortableProfileArtifact(validating: export.data).rawData, bytes)
    }
    func testCorruptAndOrphanedRecordsExportOriginalPairsDeterministically() throws {
        for hasArtifact in [true, false] {
            let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
            let bytes = Data("incomplete original".utf8); let metadata = Data([0, 1, 2, 3])
            if hasArtifact { try bytes.write(to: path(root, true)) }
            try metadata.write(to: path(root, false))
            let before = try snapshot(root); let reader = PendingProfileRecovery(rootURL: root)
            let record = try XCTUnwrap(reader.list().first)
            XCTAssertFalse(record.isProfileFile)
            let export = try reader.prepare(record)
            XCTAssertEqual(export.data, try reader.prepare(record).data)
            XCTAssertTrue(export.filename.hasSuffix(".zip"))
            let archive = try Archive(data: export.data, accessMode: .read)
            var entries: [String: Data] = [:]
            for entry in archive {
                var data = Data(); _ = try archive.extract(entry) { data.append($0) }; entries[entry.path] = data
            }
            XCTAssertEqual(entries[path(root, false).lastPathComponent], metadata)
            XCTAssertEqual(entries[path(root, true).lastPathComponent], hasArtifact ? bytes : nil)
            let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(entries["recovery.json"])) as? [String: Any])
            XCTAssertEqual(receipt["status"] as? String, "manual-recovery-required")
            XCTAssertEqual(entries.count, hasArtifact ? 3 : 2)
            XCTAssertEqual(try snapshot(root), before)
        }
    }
    func testChangedOrRemovedSourceRequiresRefreshWithoutReturningMixedBytes() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        try fixture().write(to: path(root, true)); try Data("old".utf8).write(to: path(root, false))
        let reader = PendingProfileRecovery(rootURL: root); let record = try XCTUnwrap(reader.list().first)
        try Data("changed".utf8).write(to: path(root, false))
        XCTAssertThrowsError(try reader.prepare(record)) { XCTAssertEqual($0 as? PendingProfileRecovery.RecoveryError, .sourceChanged) }
        try FileManager.default.removeItem(at: path(root, false))
        XCTAssertThrowsError(try reader.prepare(record))
        XCTAssertEqual(try Data(contentsOf: path(root, true)), try fixture())
    }
    func testFailedDestinationDoesNotConsumeSourceAndExportCanBeRetried() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        try fixture().write(to: path(root, true)); let before = try snapshot(root)
        let reader = PendingProfileRecovery(rootURL: root); let record = try XCTUnwrap(reader.list().first)
        XCTAssertThrowsError(try reader.prepare(record).data.write(to: root.appendingPathComponent("missing-parent/output.json")))
        XCTAssertEqual(try reader.prepare(record).data, try fixture())
        XCTAssertEqual(try snapshot(root), before)
    }
    func testSymlinksNonregularFilesAndOversizedMetadataAreNotFollowedOrDeleted() throws {
        let root = try root(); let outside = try self.root()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let target = outside.appendingPathComponent("outside.json"); try fixture().write(to: target)
        try FileManager.default.createSymbolicLink(at: path(root, true), withDestinationURL: target)
        XCTAssertThrowsError(try PendingProfileRecovery(rootURL: root).list())
        XCTAssertTrue(try path(root, true).resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
        XCTAssertEqual(try Data(contentsOf: target), try fixture())
        try FileManager.default.removeItem(at: path(root, true))
        try Data(repeating: 1, count: 32 * 1024 + 1).write(to: path(root, false))
        XCTAssertThrowsError(try PendingProfileRecovery(rootURL: root).list())
        XCTAssertTrue(FileManager.default.fileExists(atPath: path(root, false).path))
        let linked = outside.appendingPathComponent("linked-directory")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: root)
        XCTAssertThrowsError(try PendingProfileRecovery(rootURL: linked).list())
    }
    @MainActor
    func testCoordinatorOnlyReadsSavedRecordsAndRetiredURLsCannotStartDownloads() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        try fixture().write(to: path(root, true)); let before = try snapshot(root)
        let coordinator = IOSBuildRecoveryCoordinator(rootURL: root)
        await coordinator.refresh()
        let record = try XCTUnwrap(coordinator.records.first)
        let export = await coordinator.prepare(record)
        XCTAssertEqual(export?.data, try fixture())
        XCTAssertTrue(coordinator.routeRetiredURL("https://thumble-mcp-gateway.fly.dev/share/old#token=fictional-secret"))
        XCTAssertTrue(coordinator.error?.contains("retired") == true)
        XCTAssertFalse(coordinator.error?.contains("fictional-secret") == true)
        XCTAssertFalse(coordinator.routeRetiredURL("file:///tmp/profile.json"))
        XCTAssertEqual(try snapshot(root), before)
    }
    func testLegacyForcedPracticeRecoveryPreservesUserPreferenceAndUnrelatedData() throws {
        for prior in [false, true] {
            let suite = "Thumble-Retired-Practice-\(UUID().uuidString)"; let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(prior, forKey: "PocketPad.iOS.builderPreview.priorPractice.v1")
            defaults.set(true, forKey: "PocketPad.iOS.builderPreview.forcedPractice.v1")
            defaults.set(Data([1, 2, 3]), forKey: "pending-profile-edit")
            XCTAssertEqual(IOSRetiredBuildPracticeRecovery.recoverPracticeModeValue(storedValue: true, defaults: defaults), prior)
            XCTAssertNil(defaults.object(forKey: "PocketPad.iOS.builderPreview.forcedPractice.v1"))
            XCTAssertNil(defaults.object(forKey: "PocketPad.iOS.builderPreview.priorPractice.v1"))
            XCTAssertEqual(defaults.data(forKey: "pending-profile-edit"), Data([1, 2, 3]))
            XCTAssertEqual(IOSRetiredBuildPracticeRecovery.recoverPracticeModeValue(storedValue: prior, defaults: defaults), prior)
        }
    }
}
