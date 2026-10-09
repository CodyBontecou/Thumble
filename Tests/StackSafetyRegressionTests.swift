import Darwin
import Foundation
import XCTest

final class StackSafetyRegressionTests: XCTestCase {
    private enum StackTestError: Error {
        case emptyEncodedPayload
        case escapedProfileKeyWasNotDecoded
        case missingDecodedProfile
        case unexpectedDecodedState
        case skinApplicationFailed
        case bundledSkinInstallationFailed
        case profileCodableMismatch
        case templateResolutionFailed
        case persistenceStartupFailed
        case reconciliationFailed
        case generationPlanDecodeMismatch
    }

    func testCriticalValueTypeInlineSizesStayWithinBudgets() {
        assertInlineSize(GamepadCustomization.self, atMost: 4 * 1024)
        assertInlineSize(GamepadButtonCustomization.self, atMost: 2 * 1024)
        assertInlineSize(GamepadConfigurationProfile.self, atMost: 512)
        assertInlineSize(PendingKeypadLayoutEdit.self, atMost: 4 * 1024)
        assertInlineSize(ControllerMessage.self, atMost: 4 * 1024)
        assertInlineSize(VirtualGamepadStatus.self, atMost: 8)
        assertInlineSize(GamepadJoystickMapping.self, atMost: 8)
        assertInlineSize(ThumbleSkin.self, atMost: 1024)
        assertInlineSize(ThumbleSkinPackage.self, atMost: 1024)
        assertInlineSize(ThumbleSkinAppearance.self, atMost: 1024)
        assertInlineSize(ThumbleSkinControlAppearance.self, atMost: 2 * 1024)
        assertInlineSize(GamepadControlStateStyle.self, atMost: 2 * 1024)
        assertInlineSize(ThumbleSkinWorkspace.self, atMost: 1024)
        assertInlineSize(ControllerDesignSession.self, atMost: 512)
        assertInlineSize(ControllerDesignLayoutEdit.self, atMost: 160)
        assertInlineSize(GamepadControlContentStyle?.self, atMost: 8)
        assertInlineSize(GamepadPointingPaint?.self, atMost: 8)
        assertInlineSize(ThumbleSkinArtworkAnchor?.self, atMost: 8)
        assertInlineSize(ThumbleSkinCapturedGeometry?.self, atMost: 8)
        assertInlineSize(GamepadControlPresentation?.self, atMost: 8)
        assertInlineSize(GamepadNativeContentPresentation?.self, atMost: 8)
        assertInlineSize(GamepadControlBarLabelContent?.self, atMost: 8)
        assertInlineSize(ControllerDesignSession.ControlBarReview?.self, atMost: 8)
        assertInlineSize(ControllerDesignSession.DiagnosticReport?.self, atMost: 8)
        assertInlineSize(ThumbleSkinQualityTarget?.self, atMost: 8)
        assertInlineSize(ControllerDesignSession.DrawerReview?.self, atMost: 8)
        assertInlineSize(GamepadNativeBarLayoutEvidence?.self, atMost: 8)
        assertInlineSize(GamepadNativeBarPaintEvidence?.self, atMost: 8)
        assertInlineSize(GamepadNativeBarItemEvidence?.self, atMost: 8)
        assertInlineSize(GamepadNativeBarIconEvidence?.self, atMost: 8)
        assertInlineSize(GamepadNativeBarContainerPresentation?.self, atMost: 8)
        assertInlineSize(GamepadTopBarDrawerLayout?.self, atMost: 8)
        assertInlineSize(GamepadControlFaceAdaptation?.self, atMost: 8)
        assertInlineSize(GamepadRuntimeControlFaceTarget?.self, atMost: 8)
        assertInlineSize(GamepadPointingFaceInteraction?.self, atMost: 8)
        assertInlineSize(GamepadTriggerFaceInteraction?.self, atMost: 8)
        assertInlineSize(GamepadControlSurfaceMask?.self, atMost: 8)
        assertInlineSize(GamepadNativeSurfaceInkEvidence?.self, atMost: 8)
        assertInlineSize(GamepadNativeSurfaceLayoutEvidence?.self, atMost: 8)
        assertInlineSize(ThumbleSkinArtboardNativeGeometry?.self, atMost: 8)
        assertInlineSize(ThumbleSkinArtboardNativeSurfaces?.self, atMost: 8)
        assertInlineSize(ThumbleSkinArtboardNativeChrome?.self, atMost: 8)
        assertInlineSize(ThumbleSkinArtboardNativeLayout?.self, atMost: 8)
        assertInlineSize(ThumbleSkinArtboardVariant.self, atMost: 256)
        assertInlineSize(GamepadControlVisualStyle.self, atMost: 256)
        assertInlineSize(GamepadStyleToken.self, atMost: 256)
        assertInlineSize(ThumbleBridgeOperation.self, atMost: 512)
        assertInlineSize(ThumbleBridgeStyleAppearance.self, atMost: 64)
        assertInlineSize(ThumbleConfigurationBridgeRequest.self, atMost: 512)
        assertInlineSize(ThumbleCLIProfileBackend.Response.self, atMost: 4 * 1024)
        assertInlineSize(PortableProfileArtifact.self, atMost: 64)
        assertInlineSize(IOSBuilderArtifactPracticePreview.self, atMost: 64)
        assertInlineSize(IOSBuilderArtifactReview.self, atMost: 256)
    }

    private func assertInlineSize<Value>(
        _ type: Value.Type,
        atMost maximumBytes: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actualBytes = MemoryLayout<Value>.size
        print("stack-safety inline size: \(Value.self)=\(actualBytes) bytes")
        XCTAssertLessThanOrEqual(
            actualBytes,
            maximumBytes,
            "\(Value.self) uses \(actualBytes) inline bytes; keep it under \(maximumBytes) bytes or move large fields behind immutable/COW storage.",
            file: file,
            line: line
        )
    }

    func testStrictJSONScanAndDecodePreserveTransportBoundsOn512KiBStack() throws {
        struct Payload: Decodable { let counter: UInt64; let chunk: String }
        let chunk = String(repeating: "a", count: 300 * 1024)
        let data = Data("{\"counter\":18446744073709551615,\"chunk\":\"\(chunk)\"}".utf8)
        try runOnThread(stackSize: 512 * 1024) {
            let decoded = try JSONDecoder().decodeUnique(Payload.self, from: data)
            guard decoded.counter == UInt64.max, decoded.chunk == chunk else { throw StackTestError.unexpectedDecodedState }
            for raw in [
                "{\"counter\":1,\"\\u0063ounter\":2,\"chunk\":\"\"}",
                "{\"é\":1,\"e\\u0301\":2}",
                "{\"\\u00e9\":1,\"e\\u0301\":2}"
            ] {
                do {
                    try JSONDecoder.validateUniqueKeys(in: Data(raw.utf8))
                    throw StackTestError.unexpectedDecodedState
                } catch PortableProfileArtifactError.duplicateObjectKey {}
            }
        }
    }

    func testGamepadReadinessWireRoundTripOn512KiBStack() throws {
        let status = VirtualGamepadStatus(phase: .ready, entitlementGranted: true, reportCount: 3, pressedButtons: [.south])
        let message = ControllerMessage(type: .ping, timestamp: 42, virtualGamepadStatus: status)
        try runOnThread(stackSize: 512 * 1024) {
            let data = try ControllerWireCodec.encode(message, using: JSONEncoder())
            let decoded = try ControllerWireCodec.decode(data, using: JSONDecoder())
            guard decoded.type == .ping, decoded.virtualGamepadStatus == status else {
                throw StackTestError.unexpectedDecodedState
            }
        }
    }

    func testBoxedProfileCustomizationsPreserveValueSemantics() throws {
        let customization = makeRichCustomization()
        let original = GamepadConfigurationProfile(
            name: "Value Semantics",
            customization: customization,
            landscapeCustomization: customization,
            portraitCustomization: customization,
            skinBaselineCustomization: customization
        )
        var changed = original

        changed.customization.setLabel("Changed Primary", for: .preset(5))
        changed.landscapeCustomization?.setLabel("Changed Landscape", for: .preset(6))
        changed.skinBaselineCustomization?.setLabel("Changed Baseline", for: .preset(7))

        XCTAssertEqual(original.customization, customization)
        XCTAssertEqual(original.landscapeCustomization, customization)
        XCTAssertEqual(original.skinBaselineCustomization, customization)
        XCTAssertNotEqual(changed.customization, original.customization)
        XCTAssertNotEqual(changed.landscapeCustomization, original.landscapeCustomization)
        XCTAssertNotEqual(changed.skinBaselineCustomization, original.skinBaselineCustomization)

        let encoded = try JSONEncoder().encode(changed)
        let decoded = try JSONDecoder().decode(GamepadConfigurationProfile.self, from: encoded)
        XCTAssertEqual(decoded, changed)
    }

    func testCopyOnWriteVisualStylePreservesValueSemantics() throws {
        let original = GamepadControlVisualStyle(
            normal: GamepadControlStateStyle(opacity: 0.9),
            pressed: GamepadControlStateStyle(scale: 0.95)
        )
        var changed = original
        changed.normal.opacity = 0.5
        changed.pressed?.scale = 0.8

        XCTAssertEqual(original.normal.opacity, 0.9)
        XCTAssertEqual(original.pressed?.scale, 0.95)
        XCTAssertEqual(changed.normal.opacity, 0.5)
        XCTAssertEqual(changed.pressed?.scale, 0.8)
        XCTAssertNotEqual(changed, original)

        let encoded = try JSONEncoder().encode(changed)
        let decoded = try JSONDecoder().decode(GamepadControlVisualStyle.self, from: encoded)
        XCTAssertEqual(decoded, changed)
    }

    func testBoxedStyleTokenPreservesValueSemantics() throws {
        let original = GamepadStyleToken(
            id: "stack-style",
            name: "Stack Style",
            visualStyle: GamepadControlVisualStyle(
                normal: GamepadControlStateStyle(opacity: 0.9),
                pressed: GamepadControlStateStyle(scale: 0.95)
            )
        )
        var changed = original
        changed.visualStyle.normal.opacity = 0.5

        XCTAssertEqual(original.visualStyle.normal.opacity, 0.9)
        XCTAssertEqual(changed.visualStyle.normal.opacity, 0.5)
        XCTAssertNotEqual(changed, original)

        let encoded = try JSONEncoder().encode(changed)
        let decoded = try JSONDecoder().decode(GamepadStyleToken.self, from: encoded)
        XCTAssertEqual(decoded, changed)
    }

    private final class ProfileCodableJob: @unchecked Sendable {
        private let profile: GamepadConfigurationProfile
        private var encodedProfile = Data()
        private var encodedProfiles = Data()

        init(profile: GamepadConfigurationProfile) {
            self.profile = profile
        }

        func run() throws {
            try encodeProfile()
            try decodeProfile()
            try encodeProfileArray()
            try decodeProfileArray()
        }

        private func encodeProfile() throws {
            encodedProfile = try JSONEncoder().encode(profile)
            guard !encodedProfile.isEmpty else { throw StackTestError.emptyEncodedPayload }
        }

        private func decodeProfile() throws {
            let decoded = try JSONDecoder().decode(
                GamepadConfigurationProfile.self,
                from: encodedProfile
            )
            guard decoded == profile else { throw StackTestError.profileCodableMismatch }
        }

        private func encodeProfileArray() throws {
            encodedProfiles = try JSONEncoder().encode([profile, profile])
            guard !encodedProfiles.isEmpty else { throw StackTestError.emptyEncodedPayload }
        }

        private func decodeProfileArray() throws {
            let decoded = try JSONDecoder().decode(
                [GamepadConfigurationProfile].self,
                from: encodedProfiles
            )
            guard decoded == [profile, profile] else {
                throw StackTestError.profileCodableMismatch
            }
        }
    }

    private final class TemplateResolutionJob: @unchecked Sendable {
        private var template: GamepadControllerTemplate?
        private var profile: GamepadConfigurationProfile?
        private var decodedProfile: GamepadConfigurationProfile?
        private var encodedProfile = Data()
        private var primaryColorSchemePreference = GamepadColorSchemePreference.system

        func run() throws {
            for template in GamepadControllerTemplate.allCases {
                prepare(template)
                try validatePrimaryMetadata()
                try validateLandscapeMetadata()
                try validatePortraitMetadata()
                try validateResolvedCustomization(for: .landscape)
                try validateResolvedCustomization(for: .portrait)
                try encodeProfile()
                try decodeProfile()
                try validateRoundTrip()
                clearIteration()
            }
        }

        private func prepare(_ template: GamepadControllerTemplate) {
            self.template = template
            profile = template.makeProfile()
            primaryColorSchemePreference = profile?.customization.colorSchemePreference ?? .system
        }

        private func validatePrimaryMetadata() throws {
            guard let customization = profile?.customization else {
                throw StackTestError.templateResolutionFailed
            }
            try validateMetadata(in: customization)
        }

        private func validateLandscapeMetadata() throws {
            guard let customization = profile?.landscapeCustomization else { return }
            try validateMetadata(in: customization)
        }

        private func validatePortraitMetadata() throws {
            guard let customization = profile?.portraitCustomization else { return }
            try validateMetadata(in: customization)
        }

        private func validateMetadata(in customization: GamepadCustomization) throws {
            guard let template,
                  customization.designMetadata?.sourceTemplateID == template.rawValue.lowercased(),
                  customization.designMetadata?.sourceTemplateRevision == max(1, template.templateRevision)
            else {
                throw StackTestError.templateResolutionFailed
            }
        }

        private func validateResolvedCustomization(
            for orientation: GamepadEditorDeviceOrientation
        ) throws {
            guard let resolved = profile?.customization(for: orientation),
                  resolved.colorSchemePreference == primaryColorSchemePreference
            else {
                throw StackTestError.templateResolutionFailed
            }
        }

        private func encodeProfile() throws {
            guard let profile else { throw StackTestError.templateResolutionFailed }
            encodedProfile = try JSONEncoder().encode(profile)
            guard !encodedProfile.isEmpty else { throw StackTestError.emptyEncodedPayload }
        }

        private func decodeProfile() throws {
            decodedProfile = try JSONDecoder().decode(
                GamepadConfigurationProfile.self,
                from: encodedProfile
            )
        }

        private func validateRoundTrip() throws {
            guard decodedProfile == profile else {
                throw StackTestError.profileCodableMismatch
            }
        }

        private func clearIteration() {
            template = nil
            profile = nil
            decodedProfile = nil
            encodedProfile.removeAll(keepingCapacity: true)
        }
    }

    private final class ProfilePersistenceStartupJob: @unchecked Sendable {
        func run() throws {
            let customization = try GamepadCustomizationPersistence.load()
            let state = try GamepadConfigurationProfilePersistence.load(
                activeCustomization: customization
            )
            guard state.profiles.count == 1,
                  state.activeProfile?.name == GamepadControllerTemplate.productivityStarter.displayName,
                  state.activeProfile?.hasCustomizationVariant(for: .landscape) == true,
                  state.activeProfile?.hasCustomizationVariant(for: .portrait) == true
            else {
                throw StackTestError.persistenceStartupFailed
            }

            GamepadCustomizationPersistence.save(state.activeProfile?.customization ?? customization)
            GamepadConfigurationProfilePersistence.save(
                state.profiles,
                activeProfileID: state.activeProfileID,
                defaultProfileID: state.defaultProfileID
            )
            guard UserDefaults.standard.data(
                forKey: GamepadConfigurationProfilePersistence.defaultsKey
            ) != nil else {
                throw StackTestError.persistenceStartupFailed
            }
        }
    }

    private final class PendingReconciliationJob: @unchecked Sendable {
        private let profile: GamepadConfigurationProfile
        private let acknowledgedEdit: PendingKeypadLayoutEdit
        private let changedEdit: PendingKeypadLayoutEdit
        private let missingProfileEdit: PendingKeypadLayoutEdit
        private let serverID = "stack-safety-server"

        init(profile: GamepadConfigurationProfile) {
            self.profile = profile
            let customization = profile.customization(for: .landscape)
            acknowledgedEdit = PendingKeypadLayoutEdit(
                profileID: profile.id,
                orientation: .landscape,
                customization: customization,
                serverID: serverID,
                updatedAt: 10
            )
            var changed = customization
            changed.setLabel("Pending Change", for: .preset(5))
            changedEdit = PendingKeypadLayoutEdit(
                profileID: profile.id,
                orientation: .landscape,
                customization: changed,
                serverID: serverID,
                updatedAt: 20
            )
            missingProfileEdit = PendingKeypadLayoutEdit(
                profileID: UUID(),
                orientation: .portrait,
                customization: changed,
                serverID: serverID,
                updatedAt: 30
            )
        }

        func run() throws {
            try validateAcknowledgementBranch()
            try validateLocalEditBranch()
            try validateRecoveryBranch()
        }

        private func validateAcknowledgementBranch() throws {
            let result = PendingKeypadLayoutReconciler.reconcile(
                incomingProfiles: [profile],
                pendingEdits: [acknowledgedEdit],
                authoritativeServerID: serverID
            )
            guard result.acknowledgedEditIDs == [acknowledgedEdit.id],
                  result.remainingEdits.isEmpty,
                  result.editsToUpload.isEmpty
            else { throw StackTestError.reconciliationFailed }
        }

        private func validateLocalEditBranch() throws {
            let result = PendingKeypadLayoutReconciler.reconcile(
                incomingProfiles: [profile],
                pendingEdits: [changedEdit],
                authoritativeServerID: serverID
            )
            guard result.remainingEdits == [changedEdit],
                  result.editsToUpload == [changedEdit],
                  result.profiles.first?.customization(for: .landscape)
                    .hasSamePresentation(as: changedEdit.customization) == true
            else { throw StackTestError.reconciliationFailed }
        }

        private func validateRecoveryBranch() throws {
            let result = PendingKeypadLayoutReconciler.reconcile(
                incomingProfiles: [profile],
                pendingEdits: [missingProfileEdit],
                authoritativeServerID: serverID
            )
            guard result.remainingEdits == [missingProfileEdit],
                  result.editsToUpload == [missingProfileEdit],
                  result.profiles.contains(where: { $0.id == missingProfileEdit.profileID })
            else { throw StackTestError.reconciliationFailed }
        }
    }

    private final class ProfileSkinApplicationJob: @unchecked Sendable {
        private var profile: GamepadConfigurationProfile
        private let initialPackage: ThumbleSkinPackage
        private let updatedPackage: ThumbleSkinPackage

        init(
            profile: GamepadConfigurationProfile,
            initialPackage: ThumbleSkinPackage,
            updatedPackage: ThumbleSkinPackage
        ) {
            self.profile = profile
            self.initialPackage = initialPackage
            self.updatedPackage = updatedPackage
        }

        func run() throws {
            applyInitialPackage()
            overrideJumpShape()
            applyUpdatedPackage()
            try validateResult()
        }

        private func applyInitialPackage() {
            profile.applySkin(initialPackage)
        }

        private func overrideJumpShape() {
            var jump = profile.customization.buttonCustomization(for: .preset(5))
            jump.shape = .rectangle
            profile.customization.setButtonCustomization(jump, for: .preset(5))
        }

        private func applyUpdatedPackage() {
            profile.applySkin(updatedPackage)
        }

        private func validateResult() throws {
            guard profile.skinReference?.version == "2.0.0" else {
                throw StackTestError.skinApplicationFailed
            }
            guard profile.customization.buttonCustomization(for: .preset(5)).shape == .rectangle else {
                throw StackTestError.skinApplicationFailed
            }
            guard profile.customization.buttonCustomization(for: .preset(6)).shape == .circle else {
                throw StackTestError.skinApplicationFailed
            }
            guard profile.landscapeSkinBaselineCustomization != nil,
                  profile.portraitSkinBaselineCustomization != nil
            else {
                throw StackTestError.skinApplicationFailed
            }
        }
    }

    private final class GenerationPlanDecodingJob: @unchecked Sendable {
        private let payload: Data
        private let expectedGeneratedJSONBytes: Int
        private let expectedArtifactJSONBytes: Int

        init(
            payload: Data,
            expectedGeneratedJSONBytes: Int,
            expectedArtifactJSONBytes: Int
        ) {
            self.payload = payload
            self.expectedGeneratedJSONBytes = expectedGeneratedJSONBytes
            self.expectedArtifactJSONBytes = expectedArtifactJSONBytes
        }

        func run() throws {
            let response = try JSONDecoder().decode(
                ThumbleCLIProfileBackend.Response.self,
                from: payload
            )
            guard response.schemaVersion == ThumbleCLIProfileBackend.schemaVersion,
                  response.ok,
                  let plan = response.generationPlan,
                  plan.schemaVersion == 1,
                  plan.catalogRevision == 1,
                  plan.plannerRevision == 1,
                  plan.generatedJSON.utf8.count == expectedGeneratedJSONBytes,
                  plan.artifactJSON.utf8.count == expectedArtifactJSONBytes,
                  plan.warnings.count == 128,
                  plan.assignedControls.count == 128,
                  plan.droppedControls.count == 32,
                  plan.layoutQuality.issueCount == 128,
                  plan.layoutQuality.issues.count == 128,
                  plan.layoutQuality.issues.last?.controlIDs.count == 4,
                  plan.layoutQuality.issues.last?.suggestedRepairs.count == 3,
                  plan.generatedJSON.hasPrefix("{\"profile\":"),
                  plan.artifactJSON.hasPrefix("{\"schemaVersion\":1")
            else {
                throw StackTestError.generationPlanDecodeMismatch
            }
        }
    }

    private final class ThreadResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<Int, Error>?

        func store(_ result: Result<Int, Error>) {
            lock.lock()
            self.result = result
            lock.unlock()
        }

        func load() -> Result<Int, Error>? {
            lock.lock()
            defer { lock.unlock() }
            return result
        }
    }

    func testPortableProfileArtifactDecodesOn512KiBStack() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Host/fixtures/profile-artifact/v1.json"))

        try runOnThread(stackSize: 512 * 1024, timeout: 30) {
            let artifact = try PortableProfileArtifact(validating: data)
            guard artifact.rawData == data, artifact.profiles.count == 1 else {
                throw StackTestError.profileCodableMismatch
            }
        }
    }

    func testLargeGenerationPlanResponseDecodesOn512KiBStack() throws {
        let fixture = try makeLargeGenerationPlanResponsePayload()
        let job = GenerationPlanDecodingJob(
            payload: fixture.payload,
            expectedGeneratedJSONBytes: fixture.generatedJSONBytes,
            expectedArtifactJSONBytes: fixture.artifactJSONBytes
        )

        try runOnThread(stackSize: 512 * 1024, timeout: 30) {
            try job.run()
        }
    }

    func testDirectGeneratedOutputAuthoringAndCodableRunOn512KiBStack() throws {
        try runOnThread(stackSize: 512 * 1024, timeout: 30) {
            let controls = (1...128).map { ordinal in
                AgentKeypadControlSpec(
                    id: String(format: "368C1C47-7233-40C4-93E6-%012X", ordinal),
                    label: "Same", key: "Space", modifiers: ["Control"]
                )
            }
            let generated = GameKeypadGenerator.generate(from: AgentKeypadSpec(gameName: "Stack Authoring", controls: controls))
            let data = try JSONEncoder().encode(generated.profile)
            let profile = try JSONDecoder().decode(GamepadConfigurationProfile.self, from: data)
            let expected = KeypadKeyboardBinding(keyCode: 49, modifiersRawValue: 8)
            guard profile.customization.elements.count == 128,
                  Set(profile.customization.elements.map(\.id)).count == 128,
                  profile.customization.elements.allSatisfy({ $0.output?.keyboard == expected && $0.defaultOutput?.keyboard == expected })
            else { throw StackTestError.unexpectedDecodedState }
        }
    }

    func testDirectFullProfileCodableRunsOn512KiBStack() throws {
        let (_, profile) = makeFullProfileWireMessage()
        let job = ProfileCodableJob(profile: profile)

        try runOnThread(stackSize: 512 * 1024) {
            try job.run()
        }
    }

    func testTemplateConstructionAndResolutionRunOn512KiBStack() throws {
        let job = TemplateResolutionJob()

        try runOnThread(stackSize: 512 * 1024, timeout: 30) {
            try job.run()
        }
    }

    private final class SavedConfigurationValidationJob: @unchecked Sendable {
        func run() throws {
            let suite = "ThumbleConstrainedSavedState.\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suite) else { throw StackTestError.persistenceStartupFailed }
            defer { defaults.removePersistentDomain(forName: suite) }
            let profileData = try makeProfileData()
            defaults.set(profileData, forKey: GamepadConfigurationProfilePersistence.defaultsKey)
            let state = try GamepadConfigurationProfilePersistence.load(activeCustomization: .defaultValue, defaults: defaults)
            let bindings = try MacConfigurationBindings.loadSavedBindings(from: [:], state: state)
            guard let active = state.activeProfile, active.customization.elements.count == 128,
                  bindings.profileKeys[active.id]?.count == 128 else { throw StackTestError.persistenceStartupFailed }
            let envelope = MacConfigurationBindings.KeypadExportEnvelope(profiles: state.profiles, activeProfileID: state.activeProfileID, defaultProfileID: state.defaultProfileID,
                profileKeyBindings: [active.id.uuidString: MacConfigurationBindings.rawKeyBindings(bindings.profileKeys[active.id] ?? [:])],
                profileOutputBindings: [active.id.uuidString: MacConfigurationBindings.rawOutputs(bindings.profileOutputs[active.id] ?? [:])])
            let imported = try MacConfigurationBindings.decodeKeypadImport(data: JSONEncoder().encode(envelope), sourceName: "Constrained import")
            guard imported.profiles.first?.customization.elements.count == 128 else { throw StackTestError.persistenceStartupFailed }
            try verifyFileExportAndUndo(imported)
            try verifyNativeConfigurationSnapshot(active)
            var resetProfile = active
            let reset = MacConfigurationBindings.resetAllOutputs(in: &resetProfile)
            guard reset.isEmpty, resetProfile.customization.elements.count == 128,
                  resetProfile.customization.elements.allSatisfy({ $0.output == KeypadElementOutputBinding() }) else { throw StackTestError.persistenceStartupFailed }
            let named = Data("{\"jump\":{\"keyCode\":49,\"modifiersRawValue\":0}}".utf8)
            do {
                _ = try MacConfigurationBindings.loadSavedBindings(from: ["PocketPadMac.keyBindings.v2": named], state: state)
                throw StackTestError.persistenceStartupFailed
            } catch is GamepadSavedConfigurationError {}
            guard defaults.data(forKey: GamepadConfigurationProfilePersistence.defaultsKey) == profileData else {
                throw StackTestError.persistenceStartupFailed
            }
            let invalid = Data("{\"profiles\":[{}]}".utf8)
            defaults.set(invalid, forKey: GamepadConfigurationProfilePersistence.defaultsKey)
            do {
                _ = try GamepadConfigurationProfilePersistence.load(activeCustomization: .defaultValue, defaults: defaults)
                throw StackTestError.persistenceStartupFailed
            } catch is GamepadSavedConfigurationError {}
            guard defaults.data(forKey: GamepadConfigurationProfilePersistence.defaultsKey) == invalid else {
                throw StackTestError.persistenceStartupFailed
            }
        }

        private func verifyFileExportAndUndo(_ imported: MacConfigurationBindings.KeypadExportEnvelope) throws {
            guard let profile = imported.profiles.first else { throw StackTestError.persistenceStartupFailed }
            let outputs = profile.initialMacOutputBindings
            let snapshot = MacConfigurationBindings.EditorUndoSnapshot(keyBindings: outputs.keyboardBindings, outputBindings: outputs,
                gamepadCustomization: profile.customization, gamepadProfiles: imported.profiles, activeGamepadProfileID: profile.id,
                defaultGamepadProfileID: profile.id, profileKeyBindings: [profile.id: outputs.keyboardBindings],
                profileOutputBindings: [profile.id: outputs], profileSources: imported.profileSources)
            let update = try MacConfigurationBindings.checkedEditorUndoUpdate(snapshot)
            let data = try MacConfigurationBindings.keypadExportData(profiles: update.state.profiles, activeProfileID: profile.id,
                defaultProfileID: profile.id, exportingProfileID: profile.id, bindings: update.bindings, preserving: update.profileSources)
            guard try MacConfigurationBindings.decodeKeypadImport(data: data, sourceName: "Constrained undo export").profiles.first?.customization.elements.count == 128 else {
                throw StackTestError.persistenceStartupFailed
            }
        }

        private func verifyNativeConfigurationSnapshot(_ profile: GamepadConfigurationProfile) throws {
            let encoder = ThumbleNativeConfiguration.encoder()
            let raw = try JSONDecoder().decodeUnique(ThumbleBridgeJSONValue.self, from: encoder.encode(profile))
            let document = ThumbleBridgeConfigurationDocument(profiles: [raw], activeProfileID: profile.id.uuidString, defaultProfileID: profile.id.uuidString)
            let authority = ThumbleNativeConfigurationAuthority(read: { document }, write: { _ in throw StackTestError.persistenceStartupFailed })
            let request = ThumbleNativeConfiguration.Request(requestID: UUID(), action: "snapshot", invocationID: UUID(), requestDigest: String(repeating: "0", count: 64))
            let response = try JSONDecoder().decodeUnique(ThumbleNativeConfiguration.Response.self, from: authority.handle(encoder.encode(request)))
            guard response.error == nil, response.document?.profiles.count == 1 else { throw StackTestError.persistenceStartupFailed }
        }

        private func makeProfileData() throws -> Data {
            var customization = GamepadCustomization.blankCanvas
            customization.elements = (1...128).map { ordinal in
                KeypadElement(id: UUID(uuidString: String(format: "E932BB68-690C-4A01-8140-%012X", ordinal))!, label: "Same", layout: .defaultValue, output: .init(keyboard: .init(keyCode: 49)))
            }
            let profile = GamepadConfigurationProfile(name: "Owned", primaryCustomization: customization)
            let raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile))
            return try JSONSerialization.data(withJSONObject: ["profiles": [raw], "activeProfileID": profile.id.uuidString, "defaultProfileID": profile.id.uuidString])
        }
    }

    func testSavedConfigurationValidationAndRejectionRunOn512KiBStack() throws {
        let job = SavedConfigurationValidationJob()
        try runOnThread(stackSize: 512 * 1024) { try job.run() }
    }

    func testEmptyPersistenceStartupRunsOn512KiBStack() throws {
        let defaults = UserDefaults.standard
        let customizationKey = GamepadCustomizationPersistence.defaultsKey
        let profilesKey = GamepadConfigurationProfilePersistence.defaultsKey
        let savedCustomization = defaults.data(forKey: customizationKey)
        let savedProfiles = defaults.data(forKey: profilesKey)
        defaults.removeObject(forKey: customizationKey)
        defaults.removeObject(forKey: profilesKey)
        defer {
            if let savedCustomization {
                defaults.set(savedCustomization, forKey: customizationKey)
            } else {
                defaults.removeObject(forKey: customizationKey)
            }
            if let savedProfiles {
                defaults.set(savedProfiles, forKey: profilesKey)
            } else {
                defaults.removeObject(forKey: profilesKey)
            }
        }

        let job = ProfilePersistenceStartupJob()
        try runOnThread(stackSize: 512 * 1024) {
            try job.run()
        }
    }

    func testPendingReconciliationBranchesRunOn512KiBStack() throws {
        let profile = GamepadControllerTemplate.productivityStarter.makeProfile()
        let job = PendingReconciliationJob(profile: profile)

        try runOnThread(stackSize: 512 * 1024) {
            try job.run()
        }
    }

    func testFullProfileWireEncodingRunsFrom512KiBStack() throws {
        let (message, _) = makeFullProfileWireMessage()

        try runOnThread(stackSize: 512 * 1024) {
            let data = try ControllerWireCodec.encode(message, using: JSONEncoder())
            guard !data.isEmpty else { throw StackTestError.emptyEncodedPayload }
        }
    }

    func testFullProfileWireDecodingRunsFrom512KiBStack() throws {
        let (message, profile) = makeFullProfileWireMessage()
        let data = try ControllerWireCodec.encode(message, using: JSONEncoder())

        try runOnThread(stackSize: 512 * 1024) {
            let decoded = try ControllerWireCodec.decode(data, using: JSONDecoder())
            guard let decodedProfile = decoded.gamepadProfiles?.first else {
                throw StackTestError.missingDecodedProfile
            }
            guard decodedProfile.normalized == profile.normalized,
                  decoded.gamepadProfileID == profile.id,
                  decoded.defaultGamepadProfileID == profile.id
            else {
                throw StackTestError.unexpectedDecodedState
            }
        }
    }

    func testEscapedHeavyFieldNameUsesExpandedDecodeStack() throws {
        let canonical = try ControllerWireCodec.encode(
            ControllerMessage(type: .gamepadProfiles, gamepadProfiles: []),
            using: JSONEncoder()
        )
        let escapedJSON = String(decoding: canonical, as: UTF8.self).replacingOccurrences(
            of: "\"gamepadProfiles\"",
            with: "\"\\u0067amepadProfiles\""
        )
        let escaped = Data(escapedJSON.utf8)
        XCTAssertLessThan(escaped.count, 32 * 1024)
        XCTAssertTrue(ControllerWireCodec.requiresExpandedStackForDecoding(escaped))

        try runOnThread(stackSize: 512 * 1024) {
            let message = try ControllerWireCodec.decode(escaped, using: JSONDecoder())
            guard message.type == .gamepadProfiles, message.gamepadProfiles == [] else {
                throw StackTestError.escapedProfileKeyWasNotDecoded
            }
        }
    }

    func testWireDecoderRejectsOversizedPayloadBeforeParsing() {
        let data = Data(count: ControllerWireCodec.maximumInboundPayloadSize + 1)

        XCTAssertThrowsError(try ControllerWireCodec.decode(data, using: JSONDecoder())) { error in
            XCTAssertEqual(
                error as? ControllerWireCodecError,
                .inboundPayloadTooLarge(
                    actualBytes: data.count,
                    maximumBytes: ControllerWireCodec.maximumInboundPayloadSize
                )
            )
        }
    }

    func testPresentationComparisonRunsOn512KiBStack() throws {
        let lhs = makeRichCustomization()
        var updatedRHS = lhs
        updatedRHS.updatedAt = 999
        let rhs = updatedRHS

        try runOnThread(stackSize: 512 * 1024) {
            guard lhs.hasSamePresentation(as: rhs) else {
                throw StackTestError.unexpectedDecodedState
            }
            var changed = rhs
            changed.setLabel("Changed", for: .preset(5))
            guard !lhs.hasSamePresentation(as: changed) else {
                throw StackTestError.unexpectedDecodedState
            }
        }
    }

    func testProfileSkinApplicationRunsOn512KiBStack() throws {
        let package = makeSkinPackage(shape: .capsule, version: "1.0.0")
        let updatedPackage = makeSkinPackage(shape: .circle, version: "2.0.0")
        let customization = makeRichCustomization()
        let profile = GamepadConfigurationProfile(
            name: "Skin Stack",
            customization: customization,
            landscapeCustomization: customization,
            portraitCustomization: customization
        )

        let job = ProfileSkinApplicationJob(
            profile: profile,
            initialPackage: package,
            updatedPackage: updatedPackage
        )
        try runOnThread(stackSize: 512 * 1024) {
            try job.run()
        }
    }

    func testBundledSkinInstallationRunsOn512KiBStack() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Thumble-Bundled-Skin-Stack-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try runOnThread(stackSize: 512 * 1024) {
            let store = try ThumbleSkinStore(rootURL: rootURL)
            try store.installBundledSkinsIfNeeded()
            guard try store.installedSkins().count == ThumbleBundledSkins.packages.count else {
                throw StackTestError.bundledSkinInstallationFailed
            }
        }
    }

    /// The complete CSS pipeline — tokenize, parse, cascade, var() resolution, lowering,
    /// package encoding, and archive writes — must run on a constrained 512 KiB stack.
    func testExactDesignCaptureAndSourceUpdateRunOn512KiBStack() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Thumble-Design-Stack-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: root.deletingLastPathComponent().appendingPathComponent(".\(root.lastPathComponent).design-lock"))
        }
        var profile = GamepadControllerTemplate.xbox.makeProfile()
        profile.landscapeCustomization = nil
        profile.portraitCustomization = nil
        profile.customization.elements[0].presentation = GamepadControlPresentation(actionID: "ability.q", purposeID: "primary",
            groupIDs: ["abilities"], legend: "Q", caption: "Light Binding", accessibilityName: "Cast Light Binding")
        let frozenProfile = profile
        try runOnThread(stackSize: 512 * 1024, timeout: 30) {
            let session = try ControllerDesignWorkspace.begin(profile: frozenProfile, bindings: Data("{}".utf8),
                targetRevision: 17, safeAreas: [.landscape: .init()], name: "Stack Design",
                identifier: "com.example.stack-design", at: root)
            let captured = try ControllerDesignWorkspace.inspect(at: root).artboard
            guard captured.id == "captured-" + frozenProfile.id.uuidString.lowercased() else {
                throw StackTestError.unexpectedDecodedState
            }
            let result = try ControllerDesignWorkspace.update(at: root, expectedRevision: session.revision,
                edits: [.init(path: "styles/controller.css", data: Data("control { font-size: 22px; font-weight: bold; } joystick { -thumble-joystick-ring-color: #123456; -thumble-joystick-ring-stroke-width: 3px; } joystick:active { -thumble-joystick-knob-fill: #abcdef; }".utf8))])
            guard result.session.revision == 2, result.session.artboardSHA256 == session.artboardSHA256 else {
                throw StackTestError.unexpectedDecodedState
            }
            let loaded = try ThumbleSkinCompiler.loadWorkspace(from: root)
            guard let control = loaded.workspace.capturedArtboards.first?.variants.first?.controls.first(where: { $0.presentation != nil }) else {
                throw StackTestError.unexpectedDecodedState
            }
            let center = control.frame.x + control.frame.width / 2
            var anchored = loaded.workspace
            anchored.sourceAssets = [.init(id: "well", path: "sources/well.svg", purpose: .canvasArtwork,
                outputWidth: 128, outputHeight: 128, anchor: .init(group: "abilities"))]
            _ = try ControllerDesignWorkspace.update(at: root, expectedRevision: 2, edits: [
                .init(path: "skin-source.json", data: JSONEncoder().encode(anchored)),
                .init(path: "sources/well.svg", data: Data(##"<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128"><rect width="128" height="128" fill="#123456"/></svg>"##.utf8))])
            let moved = try ControllerDesignWorkspace.update(at: root, expectedRevision: 3, edits: [],
                layoutEdits: [.init(variant: .primary, controlID: control.id, centerX: center > 0.5 ? center - 0.01 : center + 0.01,
                    presentation: GamepadControlPresentation(actionID: "lux.light-binding", purposeID: "ability.q",
                        groupIDs: ["abilities"], legend: "Q", caption: "Updated Light Binding"), visualRole: .utility)])
            guard moved.session.revision == 4, moved.session.baseProfileSHA256 == session.profileSHA256,
                  moved.session.bindingSHA256 == session.bindingSHA256, moved.session.layoutPlanSHA256 != nil else {
                throw StackTestError.unexpectedDecodedState
            }
            let editedArtboard = try JSONDecoder().decodeUnique(ThumbleSkinArtboard.self,
                from: Data(contentsOf: root.appendingPathComponent("contract/artboard.json")))
            guard editedArtboard.variants.first?.controls.first(where: { $0.id == control.id })?.presentation?.actionID == "lux.light-binding" else {
                throw StackTestError.unexpectedDecodedState
            }
            guard editedArtboard.variants.first?.controls.first(where: { $0.id == control.id })?.visualRole == .utility else {
                throw StackTestError.unexpectedDecodedState
            }
            let diagnostics = try ControllerDesignDiagnosticBuilder.build(source: .init(issues: []),
                quality: .init(issues: [.init(severity: .warning, code: "fixture-global", message: "Global publication metadata")]),
                artboard: editedArtboard, frames: [], layouts: [])
            let decodedDiagnostics = try JSONDecoder().decode(ControllerDesignSession.DiagnosticReport.self,
                from: JSONEncoder().encode(diagnostics))
            guard decodedDiagnostics.issues.count == 1, decodedDiagnostics.issues[0].id.count == 64,
                  decodedDiagnostics.issues[0].targetResolution == "global" else { throw StackTestError.unexpectedDecodedState }
            let compilation = try ThumbleSkinCompiler.compile(source: root)
            let manifest = try JSONDecoder().decode(ThumbleSkinManifest.self, from: JSONEncoder().encode(compilation.package.manifest))
            guard manifest.compatibility?.capturedGeometry?.isValid == true,
                  compilation.package.skin?.appearance(orientation: .landscape, colorScheme: .light).artworkLayers?.first?.id == "well" else {
                throw StackTestError.unexpectedDecodedState
            }
        }
    }

    func testNativeContentResolutionAndEvidenceCodecRunOn512KiBStack() throws {
        var profile = GamepadControllerTemplate.xbox.makeProfile()
        profile.customization.elements.append(KeypadElement(label: "Trigger", kind: .trigger, triggerSettings: .defaultValue))
        let requestedPaint = profile.customization.controlBarItemCustomization(for: .settings)
        let paintItem = GamepadNativeBarItemEvidence(item: .settings, state: .normal, requested: requestedPaint,
            resolved: profile.customization.resolvedPresentation(for: requestedPaint, fallbackAccentStyle: .blue,
                controlKind: .button, state: .normal, scheme: .dark),
            foreground: .init(red: 1, green: 1, blue: 1), background: .init(red: 0, green: 0, blue: 0),
            border: .init(red: 0.5, green: 0.5, blue: 0.5), borderWidth: 1, cornerRadius: 8, height: 28,
            padding: 12, rendererShape: "roundedRectangle", cornerRadii: nil)
        let paintIcon = GamepadNativeBarIconEvidence(item: .settings, requested: nil, source: "sf_symbol", value: "gearshape",
            fontSize: 13, frameWidth: 28, fallbacks: ["native default symbol"])
        let barPaint = GamepadNativeBarPaintEvidence(items: [paintItem.surfaceID: paintItem], icons: [paintIcon.surfaceID: paintIcon])
        try runOnThread(stackSize: 512 * 1024) {
            let customization = profile.customization
            var artboard = try ThumbleSkinArtboard.capture(profile: profile, identifier: "stack-hit",
                safeAreas: [.landscape: .init(), .portrait: .init()])
            for index in artboard.variants.indices {
                let variant = artboard.variants[index]
                let controlSamples = variant.controls.flatMap { control in
                    ThumbleSkinColorScheme.allCases.flatMap { scheme in
                        GamepadControlPresentationState.allCases.map { state in
                            ThumbleSkinArtboardNativeLayout.ControlSample(controlID: control.id, colorScheme: scheme,
                                state: state, flowFrames: ["legend": CGRect(x: 10, y: 20, width: 32, height: 18)])
                        }
                    }
                }
                let chromeSamples = (0..<24).map { index in
                    ThumbleSkinArtboardNativeLayout.ChromeSample(paint: barPaint, kind: index < 8 ? "bar" : "drawer", colorScheme: .dark,
                        isConnected: index.isMultiple(of: 2), isEditing: index.isMultiple(of: 3), requestedVisibility: true,
                        resolvedVisibility: true, frames: ["native-control-bar": CGRect(x: 0, y: 0, width: variant.canvasWidth, height: 64)],
                        viewport: CGRect(x: 0, y: 0, width: variant.canvasWidth, height: variant.canvasHeight))
                }
                artboard.variants[index].nativeLayout = .init(rendererSHA256: String(repeating: "a", count: 64),
                    controls: controlSamples, chrome: chromeSamples)
            }
            let decodedArtboard = try JSONDecoder().decode(ThumbleSkinArtboard.self, from: JSONEncoder().encode(artboard))
            guard decodedArtboard == artboard,
                  decodedArtboard.variants.allSatisfy({ $0.nativeLayout?.chromeSamples.count == 24 && $0.nativeLayout?.chromeSamples.allSatisfy({ $0.paint == barPaint }) == true && $0.nativeLayout?.controlSamples.count == $0.controls.count * 8 && $0.nativeChrome != nil && $0.controls.allSatisfy { $0.nativeGeometry != nil && $0.nativeSurfaces?.samples.count == 8 } }) else {
                throw StackTestError.unexpectedDecodedState
            }
            let drawerLayout = GamepadTopBarDrawerLayout(safeAreaInsets: .init(top: 30, leading: 10, bottom: 0, trailing: 20),
                isLandscape: false, minimumPortraitTopInset: 54)
            let decodedDrawer = try JSONDecoder().decode(GamepadTopBarDrawerLayout.self,
                from: JSONEncoder().encode(drawerLayout))
            guard decodedDrawer.topPadding == 54, decodedDrawer.effectiveLeadingInset == 10 else {
                throw StackTestError.unexpectedDecodedState
            }
            let barLabel = GamepadControlBarLabelContent.profile(name: profile.name, isDefault: true, compact: false)
            let launchLabel = GamepadControlBarLabelContent.launch(target: profile.launchTarget, compact: true)
            guard barLabel.title == profile.name, barLabel.symbol == "star.fill",
                  launchLabel.item == .launchTarget else { throw StackTestError.unexpectedDecodedState }
            let barFrame = ControllerDesignSession.ControlBarReview.Frame(title: "bar-landscape-dark-connected-normal",
                orientation: .landscape, colorScheme: .dark, isConnected: true, isEditing: false,
                isDefaultProfile: false, profileName: profile.name, visibleItems: [.profileMenu, .settings],
                surfaceIDs: ["native-control-bar", "native-control-bar/profile_menu", "native-control-bar/settings"],
                viewportWidth: 874, viewportHeight: 64, renderScale: 1,
                image: .init(path: "reviews/review-1/bar.png", byteCount: 10, sha256: String(repeating: "b", count: 64)),
                nativeLayout: .init(frames: ["native-control-bar": CGRect(x: 0, y: 0, width: 874, height: 64)],
                    viewport: CGRect(x: 0, y: 0, width: 874, height: 64)), drawerLayoutInputs: drawerLayout)
            let barEvidence = ControllerDesignSession.ControlBarReview(frames: [barFrame],
                contactSheet: .init(path: "reviews/review-1/control-bar-contact-sheet.png", byteCount: 10, sha256: String(repeating: "a", count: 64)))
            let decodedBar = try JSONDecoder().decode(ControllerDesignSession.ControlBarReview.self,
                from: JSONEncoder().encode(barEvidence))
            guard decodedBar.scope == barEvidence.scope, decodedBar.frames.first?.surfaceIDs == barFrame.surfaceIDs,
                  decodedBar.frames.first?.viewportWidth == 874,
                  decodedBar.frames.first?.nativeLayout?.frames == barFrame.nativeLayout?.frames,
                  decodedBar.frames.first?.drawerLayoutInputs?.topPadding == 54,
                  decodedBar.contactSheet == barEvidence.contactSheet else { throw StackTestError.unexpectedDecodedState }
            let drawerFrame = ControllerDesignSession.DrawerReview.Frame(title: "drawer-portrait-dark-connected-normal-expanded",
                orientation: .portrait, colorScheme: .dark, isConnected: true, isEditing: false,
                requestedVisibility: true, resolvedVisibility: true, collapsedOpacity: 1,
                surfaceIDs: ["native-drawer/reveal"], nativeLayout: .init(frames: ["native-drawer/reveal": .init(x: 100, y: 54, width: 44, height: 44)],
                    viewport: .init(x: 0, y: 0, width: 402, height: 874), coordinateDescription: "drawer-scene image"),
                layoutInputs: drawerLayout, renderScale: 1, image: barFrame.image)
            let drawerEvidence = ControllerDesignSession.DrawerReview(frames: [drawerFrame], contactSheet: barEvidence.contactSheet)
            let decodedScenes = try JSONDecoder().decode(ControllerDesignSession.DrawerReview.self,
                from: JSONEncoder().encode(drawerEvidence))
            guard decodedScenes.frames.first?.nativeLayout.frames == drawerFrame.nativeLayout.frames,
                  decodedScenes.frames.first?.layoutInputs.topPadding == 54,
                  decodedScenes.contactSheet == drawerEvidence.contactSheet else { throw StackTestError.unexpectedDecodedState }
            let controls = customization.resolvedControls(in: customization.deviceCanvas.editorDeviceFrame.screenRect.size)
            let ink = GamepadNativeSurfaceInkEvidence(samples: ["legend": .init(
                pixelBounds: CGRect(x: 20, y: 30, width: 16, height: 20),
                canvasPointBounds: CGRect(x: 10, y: 15, width: 8, height: 10), rgbaSHA256: String(repeating: "a", count: 64),
                nativeLayout: .init(canvasBounds: .init(x: 10, y: 15, width: 12, height: 16),
                    viewport: .init(x: 0, y: 0, width: 500, height: 400)))],
                width: 1000, height: 800, scale: 2)
            let decodedInk = try JSONDecoder().decode(GamepadNativeSurfaceInkEvidence.self, from: JSONEncoder().encode(ink))
            guard decodedInk.samples["legend"]?.pixelBounds == ink.samples["legend"]?.pixelBounds,
                  decodedInk.samples["legend"]?.nativeLayout?.canvasBounds == ink.samples["legend"]?.nativeLayout?.canvasBounds,
                  decodedInk.pixelScale == 2 else { throw StackTestError.unexpectedDecodedState }
            for control in controls {
                let appearance = customization.resolvedPresentation(for: control, state: .active, scheme: .dark)
                let content = GamepadControlContentStyle(pointing: GamepadPointingPaint(
                    trackpadFrameColor: GamepadRGBAColor(red: 1, green: 0.2, blue: 0.3),
                    joystickRingColor: GamepadRGBAColor(red: 0.2, green: 0.3, blue: 1),
                    joystickKnobFillColor: GamepadRGBAColor(red: 0.4, green: 1, blue: 0.2),
                    trackpadFrameStrokeWidth: 3, joystickRingStrokeWidth: 2)).merged(over: appearance.content)
                let native = GamepadNativeContentPresentation(control: control, showsButtonLabels: customization.showsButtonLabels,
                                                            content: content, icon: appearance.icon, state: .active, scheme: .dark, triggerValue: 0.5, authoredScale: 0.7,
                                                            foregroundColor: appearance.foregroundColor, profileAccentStyle: customization.accentStyle,
                                                            secondaryBindingText: "⌘K")
                let data = try JSONEncoder().encode(native)
                let decoded = try JSONDecoder().decode(GamepadNativeContentPresentation.self, from: data)
                guard decoded.visibleSurfaceIDs == native.visibleSurfaceIDs,
                      decoded.localSurfaceFrames == native.localSurfaceFrames,
                      decoded.pointingPaint == native.pointingPaint,
                      decoded.resolvedPointingPaint == native.resolvedPointingPaint,
                      decoded.bindingHint == native.bindingHint,
                      decoded.triggerValue == native.triggerValue,
                      decoded.effectiveFaceScale == native.effectiveFaceScale,
                      !control.isTrigger || (decoded.triggerValue == 0.5 && decoded.visibleSurfaceIDs.contains("trigger-fill")) else {
                    throw StackTestError.unexpectedDecodedState
                }
            }
        }
    }

    func testCSSSkinCompilationRunsOn512KiBStack() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Thumble-CSS-Compile-Stack-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("styles"),
            withIntermediateDirectories: true
        )
        let stylesheet = """
        :root { --surface: #F2EEF5; --ink: #6E4F9E; }
        controller { background: linear-gradient(160deg, #E9E4F2, #C9C2D2); }
        control {
          color: var(--ink);
          background: var(--surface);
          border: 1px solid rgba(255, 255, 255, 0.6);
          border-radius: 14px;
          box-shadow: 0 2px 4px #101027, inset 1px 1px 2px #FFFFFF;
        }
        control:pressed { transform: scale(0.96); }
        control:disabled { opacity: 0.45; }
        control[role="primary_action"] { background: linear-gradient(135deg, #8A6FD0, #5B4497); color: #FFFFFF; }
        @media (prefers-color-scheme: dark) {
          :root { --surface: #211A46; --ink: #B8A0E8; }
          controller { background: #17143B; }
        }
        """
        try stylesheet.write(
            to: root.appendingPathComponent("styles/controller.css"),
            atomically: true,
            encoding: .utf8
        )
        let workspace = ThumbleSkinWorkspace.starterCSS(
            name: "CSS Stack Skin",
            identifier: "com.example.css-stack-skin",
            artboardID: "showcase-controller-v1"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(workspace).write(
            to: root.appendingPathComponent(ThumbleSkinScaffolder.sourceFileName),
            options: .atomic
        )

        let first = try ThumbleSkinCompiler.compile(
            source: root,
            buildDirectory: root.appendingPathComponent("build-a"),
            clean: true
        ).packageData
        let second = try runOnConstrainedStackReturning(stackSize: 512 * 1024) {
            try ThumbleSkinCompiler.compile(
                source: root,
                buildDirectory: root.appendingPathComponent("build-b"),
                clean: true
            ).packageData
        }
        XCTAssertEqual(first, second, "CSS compilation must stay byte-identical on a constrained stack")
    }

    private func runOnConstrainedStackReturning(
        stackSize: Int,
        timeout: TimeInterval = 60,
        operation: @escaping @Sendable () throws -> Data
    ) throws -> Data {
        let completed = expectation(description: "constrained-stack returning operation")
        final class Box: @unchecked Sendable {
            var data: Data?
            var error: Error?
        }
        let box = Box()
        let thread = Thread {
            do {
                box.data = try operation()
            } catch {
                box.error = error
            }
            completed.fulfill()
        }
        thread.stackSize = stackSize
        thread.start()
        wait(for: [completed], timeout: timeout)
        if let error = box.error { throw error }
        return try XCTUnwrap(box.data)
    }

    private func runOnThread(
        stackSize: Int,
        timeout: TimeInterval = 15,
        operation: @escaping @Sendable () throws -> Void
    ) throws {
        let completed = expectation(description: "constrained-stack operation")
        let resultBox = ThreadResultBox()
        let thread = Thread {
            do {
                let actualStackSize = pthread_get_stacksize_np(pthread_self())
                try operation()
                resultBox.store(.success(actualStackSize))
            } catch {
                resultBox.store(.failure(error))
            }
            completed.fulfill()
        }
        thread.stackSize = stackSize
        thread.start()
        wait(for: [completed], timeout: timeout)

        let result = try XCTUnwrap(resultBox.load())
        let actualStackSize = try result.get()
        XCTAssertGreaterThanOrEqual(actualStackSize, stackSize)
        XCTAssertLessThan(actualStackSize, stackSize + (64 * 1024))
    }

    private func makeLargeGenerationPlanResponsePayload() throws -> (
        payload: Data,
        generatedJSONBytes: Int,
        artifactJSONBytes: Int
    ) {
        let generatedJSON = "{\"profile\":{\"name\":\"Stack Generation\"},\"padding\":\""
            + String(repeating: "g", count: 512 * 1024)
            + "\"}"
        let artifactJSON = "{\"schemaVersion\":1,\"artifactVersion\":1,\"profiles\":[],\"padding\":\""
            + String(repeating: "a", count: 512 * 1024)
            + "\"}"
        let warnings: [[String: Any]] = (0..<128).map { index in
            [
                "code": "stack-warning-\(index)",
                "sourceOrdinal": index,
                "message": "Bounded generation warning \(index)",
            ]
        }
        let assignedControls: [[String: Any]] = (0..<128).map { index in
            [
                "sourceOrdinal": index,
                "button": "custom\((index % 8) + 1)",
                "elementID": String(format: "00000000-0000-5000-8000-%012d", index),
                "kind": index.isMultiple(of: 4) ? "joystick" : "button",
                "usedExplicitButton": index.isMultiple(of: 2),
            ]
        }
        let droppedControls: [[String: Any]] = (0..<32).map { index in
            [
                "sourceOrdinal": index + 96,
                "reason": "slot-exhaustion",
            ]
        }
        let layoutIssues: [[String: Any]] = (0..<128).map { index in
            [
                "code": "expanded-hit-target-overlap",
                "severity": index.isMultiple(of: 5) ? "error" : "warning",
                "controlIDs": (0..<4).map { "control-\(index)-\($0)" },
                "controlCount": 4,
                "metric": Double(index) / 128.0,
                "suggestedRepairs": [
                    "resolve-overlap",
                    "minimum-touch-target",
                    "ergonomic-auto-arrange",
                ],
            ]
        }
        let response: [String: Any] = [
            "schemaVersion": ThumbleCLIProfileBackend.schemaVersion,
            "ok": true,
            "invocationID": "11111111-2222-5333-8444-555555555555",
            "authorityMode": "offline",
            "authorityPresent": true,
            "generationPlan": [
                "configurationRevision": 42,
                "schemaVersion": 1,
                "catalogRevision": 1,
                "plannerRevision": 1,
                "descriptorDigest": String(repeating: "d", count: 64),
                "generatedJSON": generatedJSON,
                "artifactJSON": artifactJSON,
                "contentHash": [
                    "algorithm": "sha256",
                    "canonicalization": "rfc8785",
                    "value": String(repeating: "f", count: 64),
                ],
                "warnings": warnings,
                "omittedWarningCount": 7,
                "assignedControls": assignedControls,
                "droppedControls": droppedControls,
                "layoutQuality": [
                    "issueCount": 128,
                    "errorCount": 26,
                    "warningCount": 102,
                    "issues": layoutIssues,
                    "omittedIssueCount": 9,
                ],
            ],
        ]
        let payload = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
        return (payload, generatedJSON.utf8.count, artifactJSON.utf8.count)
    }

    private func makeFullProfileWireMessage() -> (ControllerMessage, GamepadConfigurationProfile) {
        let customization = makeRichCustomization()
        let profile = GamepadConfigurationProfile(
            name: "Stack-Safe Profile",
            customization: customization,
            landscapeCustomization: customization,
            portraitCustomization: customization,
            skinBaselineCustomization: customization,
            landscapeSkinBaselineCustomization: customization,
            portraitSkinBaselineCustomization: customization
        )
        let message = ControllerMessage(
            type: .gamepadProfiles,
            gamepadCustomization: customization,
            gamepadProfiles: [profile],
            gamepadProfileID: profile.id,
            defaultGamepadProfileID: profile.id
        )
        return (message, profile)
    }

    private func makeRichCustomization() -> GamepadCustomization {
        var customization = GamepadControllerTemplate.productivityStarter.makeProfile().customization.normalized
        let visualStyle = GamepadControlVisualStyle(
            normal: GamepadControlStateStyle(
                fillStyle: .solid(GamepadRGBAColor(hexString: "#302A42") ?? .defaultValue),
                foregroundColor: GamepadRGBAColor(hexString: "#F7F4FF") ?? .defaultValue,
                strokeColor: GamepadRGBAColor(hexString: "#9277C8") ?? .defaultValue,
                strokeWidth: 1.5,
                shadowColor: GamepadRGBAColor(hexString: "#00000066") ?? .defaultValue,
                shadowRadius: 8
            ),
            pressed: GamepadControlStateStyle(opacity: 0.82, scale: 0.94)
        )
        for button in DefaultKeypadElements.ids {
            var layout = customization.buttonCustomization(for: button)
            layout.visualStyle = visualStyle
            layout.hapticStyle = .medium
            customization.setButtonCustomization(layout, for: button)
        }
        var settingsAppearance = GamepadButtonCustomization.defaultValue
        settingsAppearance.visualStyle = visualStyle
        settingsAppearance.icon = .sfSymbol("slider.horizontal.3")
        customization.setControlBarItemCustomization(settingsAppearance, for: .settings)
        customization.setLabel("Primary Action", for: .preset(5))
        customization.updatedAt = 123
        return customization.normalized
    }

    private func makeSkinPackage(
        shape: GamepadButtonShapeStyle,
        version: String
    ) -> ThumbleSkinPackage {
        ThumbleSkinPackage(
            manifest: ThumbleSkinManifest(
                identifier: "com.example.stack-safety",
                version: version,
                name: "Stack Safety",
                author: ThumbleSkinAuthor(name: "Tests"),
                license: "MIT"
            ),
            skin: ThumbleSkin(
                base: ThumbleSkinAppearance(
                    defaultControl: ThumbleSkinControlAppearance(shape: shape)
                ),
                variants: [
                    ThumbleSkinVariant(
                        id: "portrait",
                        orientation: .portrait,
                        appearance: ThumbleSkinAppearance(
                            defaultControl: ThumbleSkinControlAppearance(shape: shape)
                        )
                    ),
                    ThumbleSkinVariant(
                        id: "landscape",
                        orientation: .landscape,
                        appearance: ThumbleSkinAppearance(
                            defaultControl: ThumbleSkinControlAppearance(shape: shape)
                        )
                    )
                ]
            )
        )
    }
}

extension StackSafetyRegressionTests {
    func testPresentationOnlyRawBridgeTransformRunsOn512KiBStack() throws {
        var profile = GamepadControllerTemplate.xbox.makeProfile()
        profile.landscapeCustomization = nil; profile.portraitCustomization = nil
        let elementID = profile.customization.elements[0].id.uuidString
        let raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile))
        let document: [String: Any] = ["profiles": [raw], "activeProfileID": profile.id.uuidString,
            "defaultProfileID": profile.id.uuidString, "keyBindings": [:], "outputBindings": [:],
            "profileKeyBindings": [:], "profileOutputBindings": [:]]
        let input = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "nowMillis": 2, "document": document,
            "operation": ["type": "element.set", "profileID": profile.id.uuidString, "variant": "primary", "elementID": elementID,
                "changes": ["presentation": ["actionID": "ability.q", "groupIDs": ["abilities"], "legend": "Q",
                    "caption": "Light Binding", "accessibilityName": "Cast Light Binding"]]]])
        try runOnThread(stackSize: 512 * 1024, timeout: 30) {
            let request = try JSONDecoder().decodeUnique(ThumbleConfigurationBridgeRequest.self, from: input)
            let response = try ThumbleConfigurationBridge.transform(request)
            let roundTrip = try JSONDecoder().decode(ThumbleConfigurationBridgeResponse.self, from: JSONEncoder().encode(response))
            guard roundTrip.changed, case .object(let profile) = roundTrip.document.profiles[0],
                  case .object(let customization) = profile["customization"],
                  case .array(let elements) = customization["elements"],
                  elements.contains(where: { element in
                      guard case .object(let value) = element, case .object(let metadata) = value["presentation"] else { return false }
                      return metadata["legend"] == .string("Q") && metadata["actionID"] == .string("ability.q")
                  }), profile["landscapeCustomization"] == nil else {
                throw StackTestError.unexpectedDecodedState
            }
        }
    }
}
