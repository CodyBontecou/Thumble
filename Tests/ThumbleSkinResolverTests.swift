import SwiftUI
import XCTest

final class ThumbleSkinResolverTests: XCTestCase {
    private func declaredActionCustomization() -> GamepadCustomization {
        var result = GamepadCustomization.defaultValue
        if let index = result.elements.firstIndex(where: { $0.defaultControlID == .preset(5) }) {
            result.elements[index].visualRole = .primaryAction
        }
        return result
    }

    func testArbitraryUUIDButtonRulesSurviveNormalizationAndResolveIndependently() throws {
        let first = KeypadElementID(UUID(uuidString: "81C296ED-309D-4F05-BB11-F5A2E2027801")!)
        let second = KeypadElementID(UUID(uuidString: "F5A5CB2B-A218-49D3-A3B4-3158B18B99CC")!)
        let red = ThumbleSkinControlAppearance(visualStyle: GamepadControlVisualStyle(normal: GamepadControlStateStyle(fillStyle: .solid(color("#FF0000")))))
        let blue = ThumbleSkinControlAppearance(visualStyle: GamepadControlVisualStyle(normal: GamepadControlStateStyle(fillStyle: .solid(color("#0000FF")))))
        let appearance = ThumbleSkinAppearance(buttonRules: [
            ThumbleSkinButtonRule(button: second, appearance: blue),
            ThumbleSkinButtonRule(button: first, appearance: red)
        ]).normalized
        XCTAssertEqual(appearance.buttonRules.map(\.button), [first, second])
        XCTAssertEqual(appearance.controlAppearance(for: first, controlKind: .button).visualStyle, red.visualStyle)
        XCTAssertEqual(appearance.controlAppearance(for: second, controlKind: .button).visualStyle, blue.visualStyle)
        let decoded = try JSONDecoder().decode(ThumbleSkinAppearance.self, from: JSONEncoder().encode(appearance)).normalized
        XCTAssertEqual(decoded, appearance)
    }

    func testApplyingSkinPreservesGeometryBindingsAndLocalOverrides() throws {
        var customization = declaredActionCustomization().normalized
        var jump = customization.buttonCustomization(for: .preset(5))
        jump.centerX = 0.73
        jump.centerY = 0.64
        jump.icon = .text("LOCAL")
        jump.hitInsets = GamepadHitInsets(top: 4, leading: 8, bottom: 12, trailing: 16)
        customization.setButtonCustomization(jump, for: .preset(5))
        customization = customization.normalized
        let jumpID = KeypadElement.builtInID(for: .preset(5))
        let jumpIndex = try XCTUnwrap(customization.elements.firstIndex { $0.id == jumpID })
        let binding = KeypadElementOutputBinding(keyboard: KeypadKeyboardBinding(keyCode: 49))
        customization.elements[jumpIndex].output = binding

        let package = makeSkinPackage()
        let resolved = customization.applying(
            skinPackage: package,
            orientation: .landscape,
            colorScheme: .dark
        )

        let resolvedJump = resolved.buttonCustomization(for: .preset(5))
        XCTAssertEqual(resolvedJump.centerX, 0.73)
        XCTAssertEqual(resolvedJump.centerY, 0.64)
        XCTAssertEqual(resolvedJump.icon, .text("LOCAL"))
        XCTAssertEqual(resolvedJump.styleID, "skin-primary")
        XCTAssertEqual(resolvedJump.hitInsets, GamepadHitInsets(top: 4, leading: 8, bottom: 12, trailing: 16))
        XCTAssertEqual(resolved.element(for: jumpID)?.output, binding)
        XCTAssertEqual(customization.buttonCustomization(for: .preset(5)).styleID, nil, "The saved customization must remain untouched")
    }

    func testReplacingAppearanceUsesSkinInsteadOfLocalAppearance() {
        var customization = declaredActionCustomization()
        var jump = customization.buttonCustomization(for: .preset(5))
        jump.icon = .text("LOCAL")
        jump.fillColor = color("#FF0000")
        jump.centerX = 0.77
        customization.setButtonCustomization(jump, for: .preset(5))

        let resolved = customization.applying(
            skinPackage: makeSkinPackage(),
            orientation: .landscape,
            colorScheme: .dark,
            options: .replacingAppearance
        )

        let resolvedJump = resolved.buttonCustomization(for: .preset(5))
        XCTAssertEqual(resolvedJump.centerX, 0.77, "Skin replacement must not replace geometry")
        XCTAssertEqual(resolvedJump.styleID, "skin-primary")
        XCTAssertEqual(resolvedJump.icon?.source, .asset)
        XCTAssertNil(resolvedJump.fillColor)
    }

    func testExplicitVisualRoleOverridesInferredRole() throws {
        var customization = GamepadCustomization.blankCanvas
        customization.addCustomButton()
        let index = try XCTUnwrap(customization.customButtons.indices.last)
        customization.customButtons[index].visualRole = .utility
        let id = customization.customButtons[index].id

        let resolved = customization.applying(
            skinPackage: makeSkinPackage(),
            orientation: .portrait,
            colorScheme: .light,
            options: .replacingAppearance
        )

        XCTAssertEqual(resolved.customButtons.first { $0.id == id }?.layout.styleID, "skin-utility")
        XCTAssertEqual(resolved.elements.first { $0.id == id }?.visualRole, .utility)
    }

    func testExternalAssetReferencesMaterializeForBackgroundAndControlIcons() throws {
        let package = makeSkinPackage()
        let resolved = declaredActionCustomization().applying(
            skinPackage: package,
            orientation: .portrait,
            colorScheme: .dark,
            options: .replacingAppearance
        )

        XCTAssertEqual(resolved.assetLibrary.asset(id: "skin-image")?.data, Data("skin-image".utf8))
        guard case .image(let image) = resolved.keypadBackgroundFillStyle(scheme: .dark) else {
            return XCTFail("Expected image-backed skin background")
        }
        XCTAssertEqual(image.assetID, "skin-image")
        XCTAssertEqual(image.data, Data("skin-image".utf8))
        XCTAssertEqual(resolved.buttonCustomization(for: .preset(5)).icon?.value, "skin-image")
    }

    func testAsymmetricHitInsetsExpandIndependentlyFromVisualFrame() throws {
        var customization = GamepadCustomization.blankCanvas
        customization.addCustomButton()
        let index = try XCTUnwrap(customization.customButtons.indices.last)
        customization.customButtons[index].layout.centerX = 0.5
        customization.customButtons[index].layout.centerY = 0.5
        customization.customButtons[index].layout.widthScale = 1
        customization.customButtons[index].layout.heightScale = 1
        customization.customButtons[index].layout.hitInsets = GamepadHitInsets(
            top: 4,
            leading: 8,
            bottom: 12,
            trailing: 16
        )

        let control = try XCTUnwrap(
            customization.resolvedControls(in: CGSize(width: 800, height: 400))
                .first { $0.id == .custom(customization.customButtons[index].id) }
        )
        XCTAssertEqual(control.hitFrame.minX, control.frame.minX - 8, accuracy: 0.001)
        XCTAssertEqual(control.hitFrame.maxX, control.frame.maxX + 16, accuracy: 0.001)
        XCTAssertEqual(control.hitFrame.minY, control.frame.minY - 4, accuracy: 0.001)
        XCTAssertEqual(control.hitFrame.maxY, control.frame.maxY + 12, accuracy: 0.001)
        XCTAssertEqual(control.hitCenter.x, control.center.x + 4, accuracy: 0.001)
        XCTAssertEqual(control.hitCenter.y, control.center.y + 4, accuracy: 0.001)
        XCTAssertTrue(customization.usesFreeformLayout)
        XCTAssertEqual(GamepadLayoutQualityReport.runtimeHitFrame(for: control), control.hitFrame)
    }

    func testSchemeVariantJoystickKnobColorAppliesToCustomJoystick() throws {
        var customization = GamepadCustomization.blankCanvas
        customization.addCustomButton()
        let index = try XCTUnwrap(customization.customButtons.indices.last)
        customization.customButtons[index].controlKind = .joystick
        customization.customButtons[index].visualRole = .joystick
        let id = customization.customButtons[index].id
        let style = GamepadStyleToken(
            id: "joystick-material",
            name: "Joystick",
            visualStyle: GamepadControlVisualStyle(
                normal: GamepadControlStateStyle(fillStyle: .solid(color("#111111")))
            )
        )
        let skin = ThumbleSkin(
            base: ThumbleSkinAppearance(
                roleRules: [
                    ThumbleSkinRoleRule(
                        role: .joystick,
                        appearance: ThumbleSkinControlAppearance(styleID: style.id)
                    )
                ],
                styleLibrary: GamepadStyleLibrary(styles: [style])
            ),
            variants: [
                ThumbleSkinVariant(
                    id: "light-knob",
                    colorScheme: .light,
                    appearance: ThumbleSkinAppearance(roleRules: [
                        ThumbleSkinRoleRule(
                            role: .joystick,
                            appearance: ThumbleSkinControlAppearance(joystickKnobColor: color("#224466"))
                        )
                    ])
                ),
                ThumbleSkinVariant(
                    id: "dark-knob",
                    colorScheme: .dark,
                    appearance: ThumbleSkinAppearance(roleRules: [
                        ThumbleSkinRoleRule(
                            role: .joystick,
                            appearance: ThumbleSkinControlAppearance(joystickKnobColor: color("#88AACC"))
                        )
                    ])
                )
            ]
        )
        let package = ThumbleSkinPackage(
            manifest: ThumbleSkinManifest(
                identifier: "com.example.joystick-skin",
                version: "1.0.0",
                name: "Joystick Skin",
                author: ThumbleSkinAuthor(name: "Tests")
            ),
            skin: skin
        )

        let light = customization.applying(
            skinPackage: package,
            orientation: .landscape,
            colorScheme: .light,
            options: .replacingAppearance
        )
        let dark = customization.applying(
            skinPackage: package,
            orientation: .landscape,
            colorScheme: .dark,
            options: .replacingAppearance
        )

        XCTAssertEqual(light.customButtons.first { $0.id == id }?.layout.joystickKnobColor?.hexString, "#224466")
        XCTAssertEqual(dark.customButtons.first { $0.id == id }?.layout.joystickKnobColor?.hexString, "#88AACC")
        XCTAssertEqual(light.customButtons.first { $0.id == id }?.layout.styleID, style.id)
        XCTAssertEqual(dark.customButtons.first { $0.id == id }?.layout.styleID, style.id)
    }

    func testVisualRoleAndHitInsetsRoundTripAndRejectObsoleteRouting() throws {
        let button = GamepadCustomButton(
            label: "Utility",
            layout: GamepadButtonCustomization(
                hitInsets: GamepadHitInsets(top: 1, leading: 2, bottom: 3, trailing: 4)
            ),
            visualRole: .utility
        )
        let data = try JSONEncoder().encode(button)
        let decoded = try JSONDecoder().decode(GamepadCustomButton.self, from: data)
        XCTAssertEqual(decoded.visualRole, .utility)
        XCTAssertEqual(decoded.layout.hitInsets, GamepadHitInsets(top: 1, leading: 2, bottom: 3, trailing: 4))

        let current = Data(#"{"id":"56D437DF-29F8-4338-88D0-F421E6BC3D3D","label":"Current","layout":{},"controlKind":"button"}"#.utf8)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: current) as? [String: Any])
        for field in ["inputID", "mappedButton"] {
            var obsolete = object
            obsolete[field] = "jump"
            let bytes = try JSONSerialization.data(withJSONObject: obsolete)
            XCTAssertThrowsError(try JSONDecoder().decode(GamepadCustomButton.self, from: bytes), field)
            obsolete[field] = NSNull()
            let nullBytes = try JSONSerialization.data(withJSONObject: obsolete)
            XCTAssertThrowsError(try JSONDecoder().decode(GamepadCustomButton.self, from: nullBytes), "\(field): null")
        }
        let currentDecoded = try JSONDecoder().decode(GamepadCustomButton.self, from: current)
        XCTAssertNil(currentDecoded.visualRole)
        XCTAssertNil(currentDecoded.layout.hitInsets)
    }

    private func makeSkinPackage() -> ThumbleSkinPackage {
        let primary = GamepadStyleToken(
            id: "skin-primary",
            name: "Skin Primary",
            visualStyle: GamepadControlVisualStyle(
                normal: GamepadControlStateStyle(fillStyle: .solid(color("#123456")))
            )
        )
        let utility = GamepadStyleToken(
            id: "skin-utility",
            name: "Skin Utility",
            visualStyle: GamepadControlVisualStyle(
                normal: GamepadControlStateStyle(fillStyle: .solid(color("#334455")))
            )
        )
        let skin = ThumbleSkin(
            base: ThumbleSkinAppearance(
                backgroundFillStyle: .image(GamepadImageFill(assetID: "skin-image")),
                accentStyle: .purple,
                showsButtonLabels: false,
                roleRules: [
                    ThumbleSkinRoleRule(
                        role: .primaryAction,
                        appearance: ThumbleSkinControlAppearance(
                            styleID: primary.id,
                            icon: GamepadControlIcon(
                                source: .asset,
                                value: "skin-image",
                                placement: .center,
                                renderingMode: .original
                            )
                        )
                    ),
                    ThumbleSkinRoleRule(
                        role: .utility,
                        appearance: ThumbleSkinControlAppearance(styleID: utility.id)
                    )
                ],
                styleLibrary: GamepadStyleLibrary(styles: [primary, utility])
            )
        )
        let data = Data("skin-image".utf8)
        return ThumbleSkinPackage(
            manifest: ThumbleSkinManifest(
                identifier: "com.example.resolver-skin",
                version: "1.0.0",
                name: "Resolver Skin",
                author: ThumbleSkinAuthor(name: "Tests"),
                assets: [
                    ThumbleSkinResourceDescriptor(
                        id: "skin-image",
                        path: "assets/skin-image.png",
                        contentType: "image/png",
                        role: .texture,
                        byteCount: data.count,
                        sha256: "not-needed-by-resolver"
                    )
                ]
            ),
            skin: skin,
            assets: ["skin-image": data]
        )
    }

    private func color(_ hex: String) -> GamepadRGBAColor {
        GamepadRGBAColor(hexString: hex) ?? .defaultValue
    }
}
