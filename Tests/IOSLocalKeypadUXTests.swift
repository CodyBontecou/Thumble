import CoreGraphics
import XCTest

final class IOSLocalKeypadUXTests: XCTestCase {
    func testRetiredReachCleanupPreservesHapticsProfilesAndOfflineEdits() throws {
        let suite = "IOSLocalKeypadUXTests.cleanup.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let trace = "PocketPad.iOS.thumbPlacementCalibration.v1.profile.device.display.landscape"
        defaults.set(Data([1, 2, 3]), forKey: trace)
        defaults.set(0.5, forKey: IOSKeypadPreferenceKeys.hapticIntensity)
        defaults.set(Data([4, 5]), forKey: PendingKeypadLayoutPersistence.defaultsKey)
        defaults.set("keep", forKey: "PocketPad.iOS.thumbPlacementCalibration.v10.future")
        IOSRetiredPreferenceCleanup.removeCalibration(defaults: defaults)
        IOSRetiredPreferenceCleanup.removeCalibration(defaults: defaults)
        XCTAssertNil(defaults.object(forKey: trace))
        XCTAssertEqual(defaults.double(forKey: IOSKeypadPreferenceKeys.hapticIntensity), 0.5)
        XCTAssertEqual(defaults.data(forKey: PendingKeypadLayoutPersistence.defaultsKey), Data([4, 5]))
        XCTAssertEqual(defaults.string(forKey: "PocketPad.iOS.thumbPlacementCalibration.v10.future"), "keep")
    }

    func testPracticeModeSuppressesEveryInputPath() {
        for path in ControllerInputPath.allCases {
            XCTAssertTrue(
                ControllerInputSuppressionPolicy.permitsOutgoingInput(
                    path,
                    isConnected: true,
                    isPracticeModeEnabled: false
                ),
                "Expected live \(path.rawValue) to be permitted"
            )
            XCTAssertFalse(
                ControllerInputSuppressionPolicy.permitsOutgoingInput(
                    path,
                    isConnected: true,
                    isPracticeModeEnabled: true
                ),
                "Expected Practice Mode to suppress \(path.rawValue)"
            )
            XCTAssertFalse(
                ControllerInputSuppressionPolicy.permitsOutgoingInput(
                    path,
                    isConnected: false,
                    isPracticeModeEnabled: false
                ),
                "Expected offline \(path.rawValue) to be suppressed"
            )
        }
    }

    func testGlobalHapticScalingClampsAndPreservesRelativeStrength() {
        XCTAssertEqual(KeypadHapticIntensityPolicy.scaledIntensity(0.8, globalIntensity: 0.5), 0.4, accuracy: 0.0001)
        XCTAssertEqual(KeypadHapticIntensityPolicy.scaledIntensity(0.4, globalIntensity: 0.5), 0.2, accuracy: 0.0001)
        XCTAssertEqual(KeypadHapticIntensityPolicy.scaledIntensity(2, globalIntensity: 2), 1, accuracy: 0.0001)
        XCTAssertEqual(KeypadHapticIntensityPolicy.scaledIntensity(0.8, globalIntensity: -1), 0, accuracy: 0.0001)
        XCTAssertEqual(KeypadHapticIntensityPolicy.normalized(.nan), 1)
    }

    func testPendingLayoutReconciliationPreservesOfflineEditUntilMacAcknowledges() throws {
        let profileID = UUID()
        var remote = GamepadCustomization.defaultValue
        remote.setLabel("Remote", for: .preset(5))
        var local = remote
        local.setLabel("Offline Edit", for: .preset(5))
        let profile = GamepadConfigurationProfile(
            id: profileID,
            name: "Work",
            customization: remote,
            landscapeCustomization: remote
        )
        let pending = PendingKeypadLayoutEdit(
            profileID: profileID,
            orientation: .landscape,
            customization: local,
            serverID: "trusted-mac",
            updatedAt: 42
        )

        let first = PendingKeypadLayoutReconciler.reconcile(
            incomingProfiles: [profile],
            pendingEdits: [pending],
            authoritativeServerID: "trusted-mac"
        )
        XCTAssertEqual(first.remainingEdits, [pending])
        XCTAssertEqual(first.editsToUpload, [pending])
        XCTAssertEqual(
            try XCTUnwrap(first.profiles.first).customization(for: .landscape).visualLabel(for: .preset(5)),
            "Offline Edit"
        )

        var acknowledgedProfile = profile
        acknowledgedProfile.setCustomization(local, for: .landscape)
        let acknowledged = PendingKeypadLayoutReconciler.reconcile(
            incomingProfiles: [acknowledgedProfile],
            pendingEdits: [pending],
            authoritativeServerID: "trusted-mac"
        )
        XCTAssertTrue(acknowledged.remainingEdits.isEmpty)
        XCTAssertTrue(acknowledged.editsToUpload.isEmpty)
        XCTAssertEqual(acknowledged.acknowledgedEditIDs, [pending.id])
    }

    func testPendingLayoutReconciliationRestoresProfileRemovedWhileOffline() throws {
        let profileID = UUID()
        var customization = GamepadCustomization.defaultValue
        customization.setLabel("Recovered", for: .preset(5))
        let pending = PendingKeypadLayoutEdit(
            profileID: profileID,
            orientation: .portrait,
            customization: customization,
            serverID: "trusted-mac",
            updatedAt: 99
        )

        let result = PendingKeypadLayoutReconciler.reconcile(
            incomingProfiles: [GamepadControllerTemplate.nes.makeProfile()],
            pendingEdits: [pending],
            authoritativeServerID: "trusted-mac"
        )
        let recovered = try XCTUnwrap(result.profiles.first(where: { $0.id == profileID }))
        XCTAssertEqual(recovered.name, "Recovered iPhone Layout")
        XCTAssertEqual(recovered.customization(for: .portrait).visualLabel(for: .preset(5)), "Recovered")
        XCTAssertEqual(result.remainingEdits, [pending])
        XCTAssertEqual(result.editsToUpload, [pending])
    }

    func testPendingLayoutReconciliationNeverUploadsToDifferentMac() {
        let profile = GamepadControllerTemplate.productivityStarter.makeProfile()
        let pending = PendingKeypadLayoutEdit(
            profileID: profile.id,
            orientation: .portrait,
            customization: profile.customization(for: .portrait),
            serverID: "original-mac"
        )
        let result = PendingKeypadLayoutReconciler.reconcile(
            incomingProfiles: [profile],
            pendingEdits: [pending],
            authoritativeServerID: "different-mac"
        )
        XCTAssertEqual(result.remainingEdits, [pending])
        XCTAssertTrue(result.editsToUpload.isEmpty)
    }

    func testPendingLayoutPersistenceRoundTripAndDeduplication() throws {
        let suiteName = "IOSLocalKeypadPendingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = GamepadControllerTemplate.productivityStarter.makeProfile()
        let older = PendingKeypadLayoutEdit(
            profileID: profile.id,
            orientation: .portrait,
            customization: profile.customization(for: .portrait),
            serverID: "trusted-mac",
            updatedAt: 1
        )
        var changed = profile.customization(for: .portrait)
        changed.setLabel("Changed", for: .preset(5))
        let newer = PendingKeypadLayoutEdit(
            profileID: profile.id,
            orientation: .portrait,
            customization: changed,
            serverID: "trusted-mac",
            updatedAt: 2
        )
        let recorded = PendingKeypadLayoutReconciler.recording(newer, in: [older])
        XCTAssertEqual(recorded, [newer])
        PendingKeypadLayoutPersistence.save(recorded, defaults: defaults)
        XCTAssertEqual(try PendingKeypadLayoutPersistence.load(defaults: defaults), [newer])
        PendingKeypadLayoutPersistence.save([], defaults: defaults)
        XCTAssertTrue(try PendingKeypadLayoutPersistence.load(defaults: defaults).isEmpty)
    }

    func testPendingExecutableLayoutsRejectAmbiguityWithoutReplacingSavedBytes() throws {
        let suite = "ThumblePendingStrict.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profileID = UUID().uuidString
        let owner = UUID().uuidString
        let prefix = "[{\"profileID\":\"\(profileID)\",\"orientation\":\"landscape\",\"serverID\":\"trusted\",\"updatedAt\":1,\"customization\":{\"elements\":["
        let suffix = "]}}]"
        let valid = Data((prefix + "{\"id\":\"\(owner)\",\"kind\":\"button\",\"output\":{\"gamepadButtons\":[]}}" + suffix).utf8)
        defaults.set(valid, forKey: PendingKeypadLayoutPersistence.defaultsKey)
        let edit = try XCTUnwrap(PendingKeypadLayoutPersistence.load(defaults: defaults).first)
        PendingKeypadLayoutPersistence.save([edit, edit], defaults: defaults)
        XCTAssertEqual(defaults.data(forKey: PendingKeypadLayoutPersistence.defaultsKey), valid)
        var duplicate = edit
        duplicate.customization.elements.append(try XCTUnwrap(duplicate.customization.elements.first))
        PendingKeypadLayoutPersistence.save([duplicate], defaults: defaults)
        XCTAssertEqual(defaults.data(forKey: PendingKeypadLayoutPersistence.defaultsKey), valid)
        let invalids = [
            prefix + "{\"id\":\"\(owner)\",\"kind\":\"button\",\"output\":{},\"output\":{}}" + suffix,
            prefix + "{\"id\":\"\(owner)\",\"\\u0069d\":\"\(owner)\",\"kind\":\"button\"}" + suffix,
            prefix + "{\"id\":\"jump\",\"kind\":\"button\"}" + suffix
        ]
        for text in invalids {
            let bytes = Data(text.utf8); defaults.set(bytes, forKey: PendingKeypadLayoutPersistence.defaultsKey)
            XCTAssertThrowsError(try PendingKeypadLayoutPersistence.load(defaults: defaults))
            PendingKeypadLayoutPersistence.save([], defaults: defaults)
            XCTAssertEqual(defaults.data(forKey: PendingKeypadLayoutPersistence.defaultsKey), bytes)
        }
    }

}
