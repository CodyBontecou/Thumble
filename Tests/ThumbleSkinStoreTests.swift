import XCTest

final class ThumbleSkinStoreTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThumbleSkinStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testInstallLookupVersionConflictsAndRemoval() throws {
        let store = try ThumbleSkinStore(rootURL: temporaryDirectory)
        let one = makePackage(version: "1.0.0", shape: .rectangle)
        let oneData = try ThumbleSkinPackageCodec.encode(one)
        let reference = ThumbleSkinReference(identifier: one.manifest.identifier, version: "1.0.0")

        XCTAssertEqual(try store.install(data: oneData), .installed(reference))
        XCTAssertEqual(try store.install(data: oneData), .unchanged(reference))
        XCTAssertEqual(try store.package(for: reference).skin, one.skin?.normalized)

        let changedSameVersion = makePackage(version: "1.0.0", shape: .circle, summary: "Different bytes")
        XCTAssertThrowsError(try store.install(package: changedSameVersion)) { error in
            XCTAssertEqual(error as? ThumbleSkinStoreError, .versionAlreadyInstalled(reference))
        }
        XCTAssertEqual(try store.install(package: changedSameVersion, policy: .replaceSameVersion), .replaced(reference))

        let two = makePackage(version: "2.0.0", shape: .capsule)
        let twoReference = ThumbleSkinReference(identifier: two.manifest.identifier, version: "2.0.0")
        XCTAssertEqual(
            try store.install(package: two),
            .updated(twoReference, previousVersion: "1.0.0")
        )

        let old = makePackage(version: "0.9.0", shape: .roundedRectangle)
        XCTAssertThrowsError(try store.install(package: old)) { error in
            XCTAssertEqual(
                error as? ThumbleSkinStoreError,
                .newerVersionInstalled(identifier: old.manifest.identifier, installedVersion: "2.0.0")
            )
        }

        XCTAssertEqual(try store.installedSkins().count, 2)
        try store.remove(reference)
        XCTAssertThrowsError(try store.package(for: reference))
        XCTAssertEqual(try store.installedSkins().map(\.reference), [twoReference])

        let traversal = ThumbleSkinReference(identifier: "../../outside", version: "../1.0.0")
        XCTAssertThrowsError(try store.packageData(for: traversal)) { error in
            XCTAssertEqual(error as? ThumbleSkinStoreError, .invalidIdentity)
        }
        XCTAssertThrowsError(try store.remove(traversal)) { error in
            XCTAssertEqual(error as? ThumbleSkinStoreError, .invalidIdentity)
        }

        let outside = temporaryDirectory.deletingLastPathComponent()
            .appendingPathComponent("ThumbleSkinStoreOutside-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let symlink = temporaryDirectory.appendingPathComponent("com.example.symlink")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
        var symlinkPackage = makePackage(version: "1.0.0", shape: .circle)
        symlinkPackage.manifest.identifier = "com.example.symlink"
        XCTAssertThrowsError(try store.install(package: symlinkPackage)) { error in
            XCTAssertEqual(error as? ThumbleSkinStoreError, .invalidIdentity)
        }
    }

    func testInstallIntoPrivateTmpAliasUsesCanonicalContainment() throws {
        let alias = URL(fileURLWithPath: "/private/tmp/ThumbleSkinStoreAlias-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: alias) }
        let store = try ThumbleSkinStore(rootURL: alias)
        let package = makePackage(version: "1.0.0", shape: .circle)
        let reference = ThumbleSkinReference(identifier: package.manifest.identifier, version: "1.0.0")
        XCTAssertEqual(try store.install(package: package), .installed(reference))
        XCTAssertEqual(try store.package(for: reference).skin, package.skin?.normalized)
    }

    func testBundledThemesUseThePackageStore() throws {
        let store = try ThumbleSkinStore(rootURL: temporaryDirectory)
        try store.installBundledSkinsIfNeeded()

        let installed = try store.installedSkins()
        XCTAssertEqual(Set(installed.map(\.reference.identifier)), ThumbleBundledSkins.identifiers)
        XCTAssertTrue(installed.allSatisfy(\.isBundled))
        XCTAssertTrue(installed.allSatisfy { (try? store.package(for: $0.reference).skin) != nil })
        for package in ThumbleBundledSkins.packages {
            XCTAssertTrue(ThumbleSkinPackageValidator.validate(package).isValid)
        }
    }

    func testProfileBaselinePreservesOnlyUserAppearanceOverrides() throws {
        let originalPackage = makePackage(version: "1.0.0", shape: .rectangle)
        var profile = GamepadConfigurationProfile(name: "Player One", customization: .defaultValue)
        let originalJumpCenterX = profile.customization.buttonCustomization(for: .preset(5)).centerX ?? 0
        profile.applySkin(originalPackage)

        XCTAssertEqual(profile.skinReference?.version, "1.0.0")
        XCTAssertEqual(profile.customization.buttonCustomization(for: .preset(6)).shape, .rectangle)

        var jump = profile.customization.buttonCustomization(for: .preset(5))
        jump.shape = .circle
        jump.centerX = 0.82
        profile.customization.setButtonCustomization(jump, for: .preset(5))

        // A package update changes the inherited shape. Only the explicit jump override survives.
        var updatedPackage = makePackage(version: "1.0.0", shape: .capsule)
        updatedPackage.manifest.summary = "Updated skin contents"
        let rendered = profile.resolvedCustomization(
            for: .landscape,
            colorScheme: .light,
            skinPackage: updatedPackage
        )

        XCTAssertEqual(rendered.buttonCustomization(for: .preset(5)).shape, .circle)
        XCTAssertEqual(rendered.buttonCustomization(for: .preset(6)).shape, .capsule)
        XCTAssertEqual(rendered.buttonCustomization(for: .preset(5)).centerX ?? 0, 0.82, accuracy: 0.001)
        XCTAssertNotEqual(rendered.buttonCustomization(for: .preset(5)).centerX ?? 0, originalJumpCenterX)

        updatedPackage.manifest.version = "2.0.0"
        profile.applySkin(updatedPackage)
        XCTAssertEqual(profile.skinReference?.version, "2.0.0")
        XCTAssertEqual(profile.customization.buttonCustomization(for: .preset(5)).shape, .circle)
        XCTAssertEqual(profile.customization.buttonCustomization(for: .preset(6)).shape, .capsule)
        XCTAssertEqual(profile.skinBaselineCustomization?.buttonCustomization(for: .preset(5)).shape, .capsule)

        profile.detachSkin()
        XCTAssertNil(profile.skinReference)
        XCTAssertNil(profile.skinBaselineCustomization)
        XCTAssertEqual(profile.customization.buttonCustomization(for: .preset(5)).shape, .circle)
    }

    func testProfileStoresPackageAssetReferencesWithoutDuplicatingBinaryData() throws {
        let data = Data("package-only-image".utf8)
        let assetID = "package-image"
        let package = ThumbleSkinPackage(
            manifest: ThumbleSkinManifest(
                identifier: "com.example.external-assets",
                version: "1.0.0",
                name: "External Assets",
                author: ThumbleSkinAuthor(name: "Tests"),
                assets: [
                    ThumbleSkinResourceDescriptor(
                        id: assetID,
                        path: "assets/package-image.png",
                        contentType: "image/png",
                        role: .background,
                        byteCount: data.count,
                        sha256: ""
                    )
                ]
            ),
            skin: ThumbleSkin(
                base: ThumbleSkinAppearance(
                    backgroundFillStyle: .image(GamepadImageFill(assetID: assetID))
                )
            ),
            assets: [assetID: data]
        )
        let canonical = try ThumbleSkinPackageCodec.decode(ThumbleSkinPackageCodec.encode(package))
        var profile = GamepadConfigurationProfile(name: "External", customization: .defaultValue)
        profile.applySkin(canonical)

        XCTAssertNil(profile.customization.assetLibrary.asset(id: assetID)?.data)
        if case .image(let savedImage) = profile.customization.backgroundFillStyle {
            XCTAssertNil(savedImage.data)
            XCTAssertEqual(savedImage.assetID, assetID)
        } else {
            XCTFail("Expected saved image reference")
        }

        let encodedProfile = try JSONEncoder().encode(profile)
        XCTAssertFalse(String(decoding: encodedProfile, as: UTF8.self).contains(data.base64EncodedString()))

        let rendered = profile.resolvedCustomization(
            for: .landscape,
            colorScheme: .light,
            skinPackage: canonical
        )
        XCTAssertEqual(rendered.assetLibrary.asset(id: assetID)?.data, data)
        if case .image(let renderedImage) = rendered.backgroundFillStyle {
            XCTAssertEqual(renderedImage.data, data)
        } else {
            XCTFail("Expected hydrated image fill")
        }
    }

    func testDeclaredProfileDefaultsSkinFieldsAndWirePayloadCarriesPackages() throws {
        let legacyJSON = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "name": "Legacy",
          "customization": {"elements": []}
        }
        """.data(using: .utf8)!
        let legacy = try JSONDecoder().decode(GamepadConfigurationProfile.self, from: legacyJSON)
        XCTAssertNil(legacy.skinReference)
        XCTAssertNil(legacy.skinBaselineCustomization)

        let data = try ThumbleSkinPackageCodec.encode(makePackage(version: "1.0.0", shape: .circle))
        let message = ControllerMessage(type: .gamepadProfiles, skinPackages: [data])
        let encoded = try ControllerWireCodec.encode(message, using: JSONEncoder())
        let decoded = try ControllerWireCodec.decode(encoded, using: JSONDecoder())
        XCTAssertEqual(decoded.skinPackages, [data])

        let reference = ThumbleSkinReference(identifier: "com.example.store-test", version: "1.0.0")
        let apply = ControllerMessage(
            type: .gamepadProfileSkinSelection,
            skinReference: reference,
            gamepadProfileID: legacy.id,
            capabilities: [.skinPackages, .gamepadProfileSkinSelection]
        )
        let applyData = try ControllerWireCodec.encode(apply, using: JSONEncoder())
        let decodedApply = try ControllerWireCodec.decode(applyData, using: JSONDecoder())
        XCTAssertEqual(decodedApply.type, .gamepadProfileSkinSelection)
        XCTAssertEqual(decodedApply.skinReference, reference)
        XCTAssertEqual(decodedApply.gamepadProfileID, legacy.id)
        XCTAssertEqual(Set(decodedApply.capabilities ?? []), [.skinPackages, .gamepadProfileSkinSelection])

        let detach = ControllerMessage(type: .gamepadProfileSkinSelection, gamepadProfileID: legacy.id)
        let detachData = try ControllerWireCodec.encode(detach, using: JSONEncoder())
        let decodedDetach = try ControllerWireCodec.decode(detachData, using: JSONDecoder())
        XCTAssertNil(decodedDetach.skinReference)

        let removal = ControllerMessage(type: .skinPackageRemoval, skinReference: reference)
        let removalData = try ControllerWireCodec.encode(removal, using: JSONEncoder())
        let decodedRemoval = try ControllerWireCodec.decode(removalData, using: JSONDecoder())
        XCTAssertEqual(decodedRemoval.type, .skinPackageRemoval)
        XCTAssertEqual(decodedRemoval.skinReference, reference)
    }

    private func makePackage(
        version: String,
        shape: GamepadButtonShapeStyle,
        summary: String = "A test skin"
    ) -> ThumbleSkinPackage {
        ThumbleSkinPackage(
            manifest: ThumbleSkinManifest(
                identifier: "com.example.store-test",
                version: version,
                name: "Store Test",
                author: ThumbleSkinAuthor(name: "Tests"),
                summary: summary,
                license: "MIT"
            ),
            skin: ThumbleSkin(
                base: ThumbleSkinAppearance(
                    defaultControl: ThumbleSkinControlAppearance(shape: shape)
                )
            )
        )
    }
}
