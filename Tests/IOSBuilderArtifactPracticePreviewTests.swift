import Foundation
import XCTest

final class IOSBuilderArtifactPracticePreviewTests: XCTestCase {
    private func artifact() throws -> PortableProfileArtifact {
        try PortableProfileArtifact(validating: Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Host/fixtures/profile-artifact/v1.json")))
    }

    func testPreviewIsImmutableReferenceBackedAndSelectionStaysLocal() throws {
        let artifact = try artifact()
        var second = try XCTUnwrap(artifact.profiles.first)
        second.id = UUID()
        second.name = "Second Local Preview"
        let authorityProfiles = artifact.profiles
        let authoritySelectedID = UUID()
        let authorityDefaultID = UUID()
        let pendingEdits: [PendingKeypadLayoutEdit] = []
        let recordID = UUID()

        let preview = IOSBuilderArtifactPracticePreview(
            recordID: recordID,
            profiles: artifact.profiles + [second],
            selectedProfileID: artifact.activeProfileID,
            priorPracticeModeValue: false
        )
        let selected = try XCTUnwrap(preview.selecting(second.id))

        XCTAssertEqual(selected.recordID, recordID)
        XCTAssertEqual(selected.selectedProfileID, second.id)
        XCTAssertEqual(selected.selectedProfile?.name, "Second Local Preview")
        XCTAssertEqual(preview.selectedProfileID, artifact.activeProfileID)
        XCTAssertEqual(authorityProfiles, artifact.profiles)
        XCTAssertEqual(authoritySelectedID, authoritySelectedID)
        XCTAssertEqual(authorityDefaultID, authorityDefaultID)
        XCTAssertEqual(pendingEdits, [])
        XCTAssertNil(preview.selecting(UUID()))
        XCTAssertLessThanOrEqual(MemoryLayout<IOSBuilderArtifactPracticePreview>.size, 64)
    }

    func testForcedPracticeMarkerRestoresAfterInterruptedPreview() throws {
        let suite = "Thumble.BuilderPreview.Persistence.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(true, forKey: IOSKeypadPreferenceKeys.practiceMode)
        IOSBuilderArtifactPracticePersistence.markForced(priorValue: false, defaults: defaults)
        XCTAssertFalse(IOSBuilderArtifactPracticePersistence.recoverPracticeModeValue(
            storedValue: true,
            defaults: defaults
        ))
        XCTAssertFalse(defaults.bool(forKey: IOSKeypadPreferenceKeys.practiceMode))
        XCTAssertFalse(IOSBuilderArtifactPracticePersistence.recoverPracticeModeValue(
            storedValue: false,
            defaults: defaults
        ))

        IOSBuilderArtifactPracticePersistence.markForced(priorValue: true, defaults: defaults)
        XCTAssertTrue(IOSBuilderArtifactPracticePersistence.recoverPracticeModeValue(
            storedValue: false,
            defaults: defaults
        ))
    }

    func testPracticePreviewSuppressionCoversEveryTransportPathAndRestorationValue() throws {
        let artifact = try artifact()
        let preview = try XCTUnwrap(IOSBuilderArtifactPracticeTransition.begin(
            recordID: UUID(),
            artifact: artifact,
            currentPreview: nil,
            currentPracticeModeValue: false
        ))
        XCTAssertFalse(preview.priorPracticeModeValue)
        for path in ControllerInputPath.allCases {
            XCTAssertFalse(ControllerInputSuppressionPolicy.permitsOutgoingInput(
                path,
                isConnected: true,
                isPracticeModeEnabled: true
            ))
        }
        XCTAssertFalse(IOSBuilderArtifactPracticeTransition.restoredPracticeModeValue(after: preview))
        let alreadyPracticing = try XCTUnwrap(IOSBuilderArtifactPracticeTransition.begin(
            recordID: UUID(),
            artifact: artifact,
            currentPreview: nil,
            currentPracticeModeValue: true
        ))
        XCTAssertTrue(IOSBuilderArtifactPracticeTransition.restoredPracticeModeValue(after: alreadyPracticing))
        let replacement = try XCTUnwrap(IOSBuilderArtifactPracticeTransition.begin(
            recordID: UUID(),
            artifact: artifact,
            currentPreview: preview,
            currentPracticeModeValue: true
        ))
        XCTAssertFalse(replacement.priorPracticeModeValue, "Replacing a preview must preserve the original pre-preview setting")
    }
}
