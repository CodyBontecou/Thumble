import Foundation
import UniformTypeIdentifiers
import XCTest
import ZIPFoundation

final class ThumbleSkinPackageTests: XCTestCase {
    func testSkinPackageRoundTripsManifestVariantsAndExternalAssets() throws {
        let assetData = Data("not-a-real-image-but-a-stable-package-resource".utf8)
        let package = makePackage(assetData: assetData)

        let encoded = try ThumbleSkinPackageCodec.encode(package)
        XCTAssertFalse(encoded.isEmpty)
        XCTAssertEqual(encoded, try ThumbleSkinPackageCodec.encode(package), "Package encoding should be reproducible for stable catalog hashes and sync deduplication")

        let decoded = try ThumbleSkinPackageCodec.decode(encoded)
        XCTAssertEqual(decoded.manifest.identifier, "com.example.neon-arcade")
        XCTAssertEqual(decoded.manifest.version, "1.2.3")
        XCTAssertEqual(decoded.assets["neon-texture"], assetData)
        XCTAssertEqual(decoded.manifest.assets.first?.byteCount, assetData.count)
        XCTAssertEqual(decoded.manifest.assets.first?.sha256.count, 64)

        let appearance = try XCTUnwrap(decoded.skin).appearance(orientation: .portrait, colorScheme: .dark)
        XCTAssertEqual(appearance.accentStyle, .purple)
        XCTAssertEqual(appearance.showsButtonLabels, false)
        XCTAssertEqual(
            appearance.controlAppearance(for: .preset(5), controlKind: .button, visualRole: .primaryAction).styleID,
            "neon-primary"
        )
    }

    func testVariantCascadeUsesBaseThenIncreasingSpecificity() throws {
        let baseStyle = GamepadStyleToken(
            id: "base",
            name: "Base",
            visualStyle: GamepadControlVisualStyle(
                normal: GamepadControlStateStyle(fillStyle: .solid(color("#111111")))
            )
        )
        let portraitStyle = GamepadStyleToken(
            id: "portrait",
            name: "Portrait",
            visualStyle: GamepadControlVisualStyle(
                normal: GamepadControlStateStyle(fillStyle: .solid(color("#222222")))
            )
        )
        let skin = ThumbleSkin(
            base: ThumbleSkinAppearance(
                accentStyle: .blue,
                showsButtonLabels: true,
                defaultControl: ThumbleSkinControlAppearance(styleID: "base"),
                styleLibrary: GamepadStyleLibrary(styles: [baseStyle])
            ),
            variants: [
                ThumbleSkinVariant(
                    id: "portrait",
                    orientation: .portrait,
                    appearance: ThumbleSkinAppearance(
                        defaultControl: ThumbleSkinControlAppearance(styleID: "portrait"),
                        styleLibrary: GamepadStyleLibrary(styles: [portraitStyle])
                    )
                ),
                ThumbleSkinVariant(
                    id: "portrait-dark",
                    orientation: .portrait,
                    colorScheme: .dark,
                    appearance: ThumbleSkinAppearance(showsButtonLabels: false)
                )
            ]
        )

        let portraitDark = skin.appearance(orientation: .portrait, colorScheme: .dark)
        XCTAssertEqual(portraitDark.accentStyle, .blue)
        XCTAssertEqual(portraitDark.showsButtonLabels, false)
        XCTAssertEqual(portraitDark.defaultControl?.styleID, "portrait")
        XCTAssertEqual(Set(portraitDark.styleLibrary.styles.map(\.id)), ["base", "portrait"])

        let landscapeLight = skin.appearance(orientation: .landscape, colorScheme: .light)
        XCTAssertEqual(landscapeLight.showsButtonLabels, true)
        XCTAssertEqual(landscapeLight.defaultControl?.styleID, "base")
    }

    func testUndeclaredVisualRolesDoNotDependOnHistoricalInputSlots() {
        XCTAssertEqual(GamepadVisualRole.inferred(for: .preset(1), controlKind: .button), .custom)
        XCTAssertEqual(GamepadVisualRole.inferred(for: .preset(5), controlKind: .button), .custom)
        XCTAssertEqual(GamepadVisualRole.inferred(for: .preset(10), controlKind: .button), .custom)
        XCTAssertEqual(GamepadVisualRole.inferred(for: .preset(18), controlKind: .button), .custom)
        XCTAssertEqual(GamepadVisualRole.inferred(for: .preset(5), controlKind: .joystick), .joystick)
        XCTAssertEqual(GamepadVisualRole.inferred(for: .preset(5), controlKind: .text), .decoration)
        XCTAssertEqual(GamepadVisualRole.inferred(for: .preset(5), controlKind: .decoration), .decoration)
    }

    func testValidatorRejectsBadIdentityVersionAndMissingStyle() {
        let skin = ThumbleSkin(
            base: ThumbleSkinAppearance(
                defaultControl: ThumbleSkinControlAppearance(styleID: "missing")
            )
        )
        let package = ThumbleSkinPackage(
            manifest: ThumbleSkinManifest(
                identifier: "bad",
                version: "one",
                name: "Broken",
                author: ThumbleSkinAuthor(name: "Tester")
            ),
            skin: skin
        )

        let report = ThumbleSkinPackageValidator.validate(package)
        XCTAssertFalse(report.isValid)
        let codes = Set(report.errors.map(\.code))
        XCTAssertTrue(codes.contains("invalid-identifier"))
        XCTAssertTrue(codes.contains("invalid-version"))
        XCTAssertTrue(codes.contains("missing-style-reference"))
    }

    func testValidatorRejectsInvalidCompatibilityDeclarationsBeforeNormalization() {
        let compatibility = ThumbleSkinCompatibility(
            mode: .templateAligned,
            templates: [
                ThumbleSkinTemplateRequirement(templateID: "", minimumRevision: 0, maximumRevision: -1),
                ThumbleSkinTemplateRequirement(templateID: "SNES", minimumRevision: 2, maximumRevision: 1),
                ThumbleSkinTemplateRequirement(templateID: "snes", minimumRevision: 1)
            ],
            orientations: [],
            minimumAspectRatio: 3,
            maximumAspectRatio: 1
        )
        let package = ThumbleSkinPackage(
            manifest: ThumbleSkinManifest(
                schemaVersion: 1,
                identifier: "com.example.invalid-compatibility",
                version: "1.0.0",
                name: "Invalid Compatibility",
                author: ThumbleSkinAuthor(name: "Tests"),
                compatibility: compatibility
            ),
            skin: ThumbleSkin(base: .empty)
        )

        let codes = Set(ThumbleSkinPackageValidator.validate(package).errors.map(\.code))
        XCTAssertTrue(codes.contains("compatibility-requires-v2"))
        XCTAssertTrue(codes.contains("missing-compatible-orientation"))
        XCTAssertTrue(codes.contains("invalid-aspect-range"))
        XCTAssertTrue(codes.contains("invalid-template-requirement"))
        XCTAssertTrue(codes.contains("invalid-template-revision-range"))
        XCTAssertTrue(codes.contains("duplicate-template-requirement"))
        XCTAssertThrowsError(try ThumbleSkinPackageCodec.encode(package))
    }

    func testValidatorRejectsUnsafeResourcePaths() {
        let package = ThumbleSkinPackage(
            manifest: ThumbleSkinManifest(
                identifier: "com.example.unsafe",
                version: "1.0.0",
                name: "Unsafe",
                author: ThumbleSkinAuthor(name: "Tester"),
                assets: [
                    ThumbleSkinResourceDescriptor(
                        id: "bad",
                        path: "assets/../escape.png",
                        contentType: "image/png",
                        role: .texture,
                        byteCount: 1,
                        sha256: String(repeating: "0", count: 64)
                    )
                ]
            ),
            skin: ThumbleSkin(base: .empty),
            assets: ["bad": Data([0])]
        )

        let report = ThumbleSkinPackageValidator.validate(package)
        XCTAssertTrue(report.errors.contains { $0.code == "unsafe-asset-path" })
        XCTAssertThrowsError(try ThumbleSkinPackageCodec.encode(package))
    }

    func testDecoderRejectsAmbiguousManifestBeforeUnknownFieldsDisappear() throws {
        let original = try ThumbleSkinPackageCodec.encode(makePackage(assetData: Data("asset".utf8)))
        XCTAssertNoThrow(try ThumbleSkinPackageCodec.decode(original))
        let archive = try Archive(data: original, accessMode: .update)
        let manifest = try XCTUnwrap(archive["manifest.json"])
        var bytes = Data()
        _ = try archive.extract(manifest) { bytes.append($0) }
        let raw = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(raw.hasPrefix("{"))
        let ambiguous = Data(("{\"futureMetadata\":0,\"futureMetadata\":1," + raw.dropFirst()).utf8)
        try archive.remove(manifest)
        try archive.addEntry(with: "manifest.json", type: .file, uncompressedSize: Int64(ambiguous.count), compressionMethod: .deflate) { position, size in
            let start = Int(position)
            return ambiguous.subdata(in: start..<(start + size))
        }
        XCTAssertThrowsError(try ThumbleSkinPackageCodec.decode(try XCTUnwrap(archive.data))) { error in
            XCTAssertEqual(error as? ThumbleSkinPackageCodecError, .corruptEntry("manifest.json"))
        }
    }

    func testDecoderRejectsUndeclaredArchiveEntries() throws {
        let original = try ThumbleSkinPackageCodec.encode(makePackage(assetData: Data("asset".utf8)))
        let archive = try Archive(data: original, accessMode: .update)
        let unexpected = Data("surprise".utf8)
        try archive.addEntry(
            with: "unexpected.txt",
            type: .file,
            uncompressedSize: Int64(unexpected.count),
            compressionMethod: .deflate
        ) { position, size in
            let start = Int(position)
            return unexpected.subdata(in: start..<(start + size))
        }
        let tampered = try XCTUnwrap(archive.data)

        XCTAssertThrowsError(try ThumbleSkinPackageCodec.decode(tampered)) { error in
            XCTAssertEqual(error as? ThumbleSkinPackageCodecError, .unexpectedEntry("unexpected.txt"))
        }
    }

    func testDecoderRejectsSymlinksCompressionBombsAndOversizedEntries() throws {
        let original = try ThumbleSkinPackageCodec.encode(makePackage(assetData: Data("asset".utf8)))

        let symlinkArchive = try Archive(data: original, accessMode: .update)
        let linkTarget = Data("../../outside".utf8)
        try symlinkArchive.addEntry(
            with: "assets/link.png",
            type: .symlink,
            uncompressedSize: Int64(linkTarget.count),
            compressionMethod: .none
        ) { position, size in
            let start = Int(position)
            return linkTarget.subdata(in: start..<(start + size))
        }
        XCTAssertThrowsError(try ThumbleSkinPackageCodec.decode(try XCTUnwrap(symlinkArchive.data))) { error in
            XCTAssertEqual(error as? ThumbleSkinPackageCodecError, .unsupportedEntry("assets/link.png"))
        }

        let bombArchive = try Archive(data: original, accessMode: .update)
        let compressible = Data(repeating: 0, count: 500_000)
        try bombArchive.addEntry(
            with: "assets/bomb.png",
            type: .file,
            uncompressedSize: Int64(compressible.count),
            compressionMethod: .deflate
        ) { position, size in
            let start = Int(position)
            return compressible.subdata(in: start..<(start + size))
        }
        XCTAssertThrowsError(try ThumbleSkinPackageCodec.decode(try XCTUnwrap(bombArchive.data))) { error in
            XCTAssertEqual(error as? ThumbleSkinPackageCodecError, .compressionRatioTooHigh("assets/bomb.png"))
        }

        let oversizedArchive = try Archive(data: original, accessMode: .update)
        let oversized = Data(repeating: 1, count: ThumbleSkinPackageCodec.maximumEntryBytes + 1)
        try oversizedArchive.addEntry(
            with: "assets/oversized.png",
            type: .file,
            uncompressedSize: Int64(oversized.count),
            compressionMethod: .none
        ) { position, size in
            let start = Int(position)
            return oversized.subdata(in: start..<(start + size))
        }
        XCTAssertThrowsError(try ThumbleSkinPackageCodec.decode(try XCTUnwrap(oversizedArchive.data))) { error in
            XCTAssertEqual(error as? ThumbleSkinPackageCodecError, .entryTooLarge("assets/oversized.png"))
        }
    }

    func testValidatorRejectsExecutableAssetsDuplicateIDsAndProfilesInSkins() {
        let payload = Data("#!/bin/sh".utf8)
        let descriptors = [
            ThumbleSkinResourceDescriptor(
                id: "script",
                path: "assets/run.sh",
                contentType: "application/x-sh",
                role: .reference,
                byteCount: payload.count,
                sha256: ""
            ),
            ThumbleSkinResourceDescriptor(
                id: "script",
                path: "assets/run-again.sh",
                contentType: "application/x-sh",
                role: .reference,
                byteCount: payload.count,
                sha256: ""
            )
        ]
        let package = ThumbleSkinPackage(
            manifest: ThumbleSkinManifest(
                identifier: "com.example.no-executables",
                version: "1.0.0",
                name: "No Executables",
                author: ThumbleSkinAuthor(name: "Tests"),
                assets: descriptors
            ),
            skin: ThumbleSkin(base: .empty),
            profile: GamepadConfigurationProfile(name: "Should Not Run", customization: .defaultValue),
            assets: ["script": payload]
        )

        let codes = Set(ThumbleSkinPackageValidator.validate(package).errors.map(\.code))
        XCTAssertTrue(codes.contains("executable-asset"))
        XCTAssertTrue(codes.contains("duplicate-asset-id"))
        XCTAssertTrue(codes.contains("unexpected-profile"))
        XCTAssertThrowsError(try ThumbleSkinPackageCodec.encode(package))
    }

    func testSemanticVersionOrdering() throws {
        let alpha = try XCTUnwrap(ThumbleSemanticVersion("1.0.0-alpha"))
        let release = try XCTUnwrap(ThumbleSemanticVersion("1.0.0"))
        let next = try XCTUnwrap(ThumbleSemanticVersion("1.1.0"))
        XCTAssertLessThan(alpha, release)
        XCTAssertLessThan(release, next)
        XCTAssertNil(ThumbleSemanticVersion("1.0"))
        XCTAssertNil(ThumbleSemanticVersion("latest"))
    }

    func testPackageDocumentAdvertisesCustomFileType() {
        XCTAssertEqual(ThumbleSkinPackageDocument.readableContentTypes, [.thumbleSkinPackage])
        XCTAssertEqual(ThumbleSkinPackageDocument.writableContentTypes, [.thumbleSkinPackage])
        XCTAssertEqual(UTType.thumbleSkinPackage.identifier, "com.codybontecou.pocketpad.skin-package")
    }

    private func makePackage(assetData: Data) -> ThumbleSkinPackage {
        let style = GamepadStyleToken(
            id: "neon-primary",
            name: "Neon Primary",
            visualStyle: GamepadControlVisualStyle(
                normal: GamepadControlStateStyle(
                    fillStyle: .image(GamepadImageFill(assetID: "neon-texture")),
                    foregroundColor: color("#FFFFFF"),
                    glowColor: color("#00D9FF"),
                    glowRadius: 12
                ),
                pressed: GamepadControlStateStyle(scale: 0.94),
                hapticFeedback: GamepadHapticFeedback(style: .rigid)
            )
        )
        let skin = ThumbleSkin(
            base: ThumbleSkinAppearance(
                accentStyle: .purple,
                showsButtonLabels: true,
                roleRules: [
                    ThumbleSkinRoleRule(
                        role: .primaryAction,
                        appearance: ThumbleSkinControlAppearance(styleID: style.id)
                    )
                ],
                styleLibrary: GamepadStyleLibrary(styles: [style])
            ),
            variants: [
                ThumbleSkinVariant(
                    id: "portrait-dark",
                    orientation: .portrait,
                    colorScheme: .dark,
                    appearance: ThumbleSkinAppearance(showsButtonLabels: false)
                )
            ]
        )
        let manifest = ThumbleSkinManifest(
            identifier: "com.example.neon-arcade",
            version: "1.2.3",
            name: "Neon Arcade",
            author: ThumbleSkinAuthor(name: "Example Creator", url: URL(string: "https://example.com")),
            summary: "A test skin.",
            license: "MIT",
            tags: ["arcade", "neon"],
            assets: [
                ThumbleSkinResourceDescriptor(
                    id: "neon-texture",
                    path: "assets/neon-texture.png",
                    contentType: "image/png",
                    role: .texture,
                    byteCount: 0,
                    sha256: ""
                )
            ]
        )
        return ThumbleSkinPackage(
            manifest: manifest,
            skin: skin,
            assets: ["neon-texture": assetData]
        )
    }

    private func color(_ hex: String) -> GamepadRGBAColor {
        GamepadRGBAColor(hexString: hex) ?? .defaultValue
    }
}
