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
        assertInlineSize(ThumbleSkin.self, atMost: 1024)
        assertInlineSize(ThumbleSkinPackage.self, atMost: 1024)
        assertInlineSize(ThumbleSkinAppearance.self, atMost: 1024)
        assertInlineSize(ThumbleSkinControlAppearance.self, atMost: 2 * 1024)
        assertInlineSize(GamepadControlStateStyle.self, atMost: 2 * 1024)
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

        changed.customization.setLabel("Changed Primary", for: .jump)
        changed.landscapeCustomization?.setLabel("Changed Landscape", for: .attack)
        changed.skinBaselineCustomization?.setLabel("Changed Baseline", for: .dash)

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
            let customization = GamepadCustomizationPersistence.load()
            let state = GamepadConfigurationProfilePersistence.load(
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
            changed.setLabel("Pending Change", for: .jump)
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
            var jump = profile.customization.buttonCustomization(for: .jump)
            jump.shape = .rectangle
            profile.customization.setButtonCustomization(jump, for: .jump)
        }

        private func applyUpdatedPackage() {
            profile.applySkin(updatedPackage)
        }

        private func validateResult() throws {
            guard profile.skinReference?.version == "2.0.0" else {
                throw StackTestError.skinApplicationFailed
            }
            guard profile.customization.buttonCustomization(for: .jump).shape == .rectangle else {
                throw StackTestError.skinApplicationFailed
            }
            guard profile.customization.buttonCustomization(for: .attack).shape == .circle else {
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
            changed.setLabel("Changed", for: .jump)
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
        for button in GameButton.builtInControls {
            var layout = customization.buttonCustomization(for: button)
            layout.visualStyle = visualStyle
            layout.hapticStyle = .medium
            customization.setButtonCustomization(layout, for: button)
        }
        var settingsAppearance = GamepadButtonCustomization.defaultValue
        settingsAppearance.visualStyle = visualStyle
        settingsAppearance.icon = .sfSymbol("slider.horizontal.3")
        customization.setControlBarItemCustomization(settingsAppearance, for: .settings)
        customization.setLabel("Primary Action", for: .jump)
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
