import SwiftUI
import XCTest

final class ThumbleSkinCompatibilityTests: XCTestCase {
    func testTemplateCompatibilityDistinguishesExactUnknownAndWrongLayouts() {
        let declaration = ThumbleSkinCompatibility(
            mode: .templateAligned,
            templates: [ThumbleSkinTemplateRequirement(templateID: "showcase", minimumRevision: 1, maximumRevision: 1)],
            orientations: [.landscape],
            requiredRoles: [.movement, .primaryAction]
        )
        var exact = GamepadCustomization.defaultValue
        // Semantic roles are explicit; starter button positions do not imply them.
        exact.elements[0].visualRole = .movement
        exact.elements[1].visualRole = .primaryAction
        exact.designMetadata = GamepadDesignMetadata(sourceTemplateID: "showcase", sourceTemplateRevision: 1)

        let exactResult = ThumbleSkinCompatibilityEvaluator.evaluate(
            declaration,
            customization: exact,
            orientation: .landscape
        )
        XCTAssertEqual(exactResult.status, .compatible)
        XCTAssertTrue(exactResult.allowsTemplateArtwork)

        var unknown = exact
        unknown.designMetadata = nil
        let unknownResult = ThumbleSkinCompatibilityEvaluator.evaluate(
            declaration,
            customization: unknown,
            orientation: .landscape
        )
        XCTAssertEqual(unknownResult.status, .degraded)
        XCTAssertFalse(unknownResult.allowsTemplateArtwork)
        XCTAssertTrue(unknownResult.issues.contains { $0.code == "unknown-template" })

        var wrong = exact
        wrong.designMetadata = GamepadDesignMetadata(sourceTemplateID: "classic", sourceTemplateRevision: 1)
        let wrongResult = ThumbleSkinCompatibilityEvaluator.evaluate(
            declaration,
            customization: wrong,
            orientation: .landscape
        )
        XCTAssertEqual(wrongResult.status, .incompatible)
        XCTAssertTrue(wrongResult.issues.contains { $0.code == "template-mismatch" })
    }

    func testArtworkLayerCascadeReplacesByIDAndSortsDeterministically() {
        let baseLayer = ThumbleSkinArtworkLayer(
            id: "badge",
            plane: .underlay,
            fillStyle: .solid(color("#112233")),
            opacity: 0.4,
            zIndex: 4
        )
        let topLayer = ThumbleSkinArtworkLayer(
            id: "top",
            plane: .overlay,
            fillStyle: .solid(color("#445566")),
            zIndex: 2
        )
        let replacement = ThumbleSkinArtworkLayer(
            id: "badge",
            plane: .overlay,
            fillStyle: .solid(color("#778899")),
            opacity: 0.9,
            zIndex: 1
        )
        let skin = ThumbleSkin(
            base: ThumbleSkinAppearance(artworkLayers: [topLayer, baseLayer]),
            variants: [
                ThumbleSkinVariant(
                    id: "portrait-dark",
                    orientation: .portrait,
                    colorScheme: .dark,
                    appearance: ThumbleSkinAppearance(artworkLayers: [replacement])
                )
            ]
        )

        let appearance = skin.appearance(orientation: .portrait, colorScheme: .dark)
        XCTAssertEqual(appearance.artworkLayers?.map(\.id), ["badge", "top"])
        XCTAssertEqual(appearance.artworkLayers?.first?.plane, .overlay)
        XCTAssertEqual(appearance.artworkLayers?.first?.opacity, 0.9)
    }

    func testResolverHydratesLayersOnlyForCompatibleTemplate() throws {
        let data = Data("layer".utf8)
        let layer = ThumbleSkinArtworkLayer(
            id: "shell",
            fillStyle: .image(GamepadImageFill(
                assetID: "layer",
                resizingMode: .nineSliceStretch,
                nineSliceInsets: GamepadImageCapInsets(top: 0.2, leading: 0.15, bottom: 0.2, trailing: 0.15)
            ))
        )
        let package = ThumbleSkinPackage(
            manifest: ThumbleSkinManifest(
                identifier: "com.example.layers",
                version: "1.0.0",
                name: "Layers",
                author: ThumbleSkinAuthor(name: "Tests"),
                assets: [
                    ThumbleSkinResourceDescriptor(
                        id: "layer",
                        path: "assets/layer.png",
                        contentType: "image/png",
                        role: .texture,
                        byteCount: data.count,
                        sha256: data.thumbleSHA256
                    )
                ],
                compatibility: ThumbleSkinCompatibility(
                    mode: .templateAligned,
                    templates: [ThumbleSkinTemplateRequirement(templateID: "showcase")]
                )
            ),
            skin: ThumbleSkin(base: ThumbleSkinAppearance(artworkLayers: [layer])),
            assets: ["layer": data]
        )
        var customization = GamepadCustomization.defaultValue
        customization.designMetadata = GamepadDesignMetadata(sourceTemplateID: "showcase", sourceTemplateRevision: 1)

        let resolved = customization.applying(
            skinPackage: package,
            orientation: .landscape,
            colorScheme: .dark,
            options: .replacingAppearance
        )
        let resolvedLayer = try XCTUnwrap(resolved.artworkLayers.first)
        guard case .image(let image) = try XCTUnwrap(resolvedLayer.fillStyle) else {
            return XCTFail("Expected image artwork")
        }
        XCTAssertEqual(image.data, data)
        XCTAssertEqual(image.effectiveResizingMode, .nineSliceStretch)
        XCTAssertEqual(image.nineSliceInsets, GamepadImageCapInsets(top: 0.2, leading: 0.15, bottom: 0.2, trailing: 0.15))

        customization.designMetadata = GamepadDesignMetadata(sourceTemplateID: "classic", sourceTemplateRevision: 1)
        let mismatched = customization.applying(
            skinPackage: package,
            orientation: .landscape,
            colorScheme: .dark,
            options: .replacingAppearance
        )
        XCTAssertTrue(mismatched.artworkLayers.isEmpty)
    }

    func testManifestValidatorRejectsInvalidTemplateCompatibility() {
        let package = ThumbleSkinPackage(
            manifest: ThumbleSkinManifest(
                identifier: "com.example.invalid-compatibility",
                version: "1.0.0",
                name: "Invalid",
                author: ThumbleSkinAuthor(name: "Tests"),
                compatibility: ThumbleSkinCompatibility(
                    mode: .templateAligned,
                    templates: [],
                    orientations: []
                )
            ),
            skin: ThumbleSkin(base: ThumbleSkinAppearance())
        )
        let report = ThumbleSkinPackageValidator.validate(package)
        XCTAssertFalse(report.isValid)
        XCTAssertTrue(report.errors.contains { $0.code == "missing-template-requirement" })
        XCTAssertTrue(report.errors.contains { $0.code == "missing-compatible-orientation" })
    }

    private func color(_ hex: String) -> GamepadRGBAColor {
        GamepadRGBAColor(hexString: hex) ?? .defaultValue
    }
}
