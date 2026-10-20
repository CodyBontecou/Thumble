import SwiftUI
import XCTest

final class ThumbleSkinResolverTests: XCTestCase {
    @MainActor
    func testEditorPreviewReusesResolutionAndInvalidatesChangedInputs() throws {
        let package = makeSkinPackage()
        var profile = GamepadConfigurationProfile(name: "Preview", customization: .defaultValue)
        profile.applySkin(package)
        let cache = ThumbleSkinEditorPreviewCache()
        var loads = 0
        func resolve(_ orientation: GamepadEditorDeviceOrientation = .landscape,
                     _ scheme: ThumbleSkinColorScheme = .dark) -> GamepadCustomization {
            cache.resolve(profile: profile, orientation: orientation, colorScheme: scheme) {
                loads += 1
                return package
            }
        }
        let first = resolve()
        XCTAssertEqual(resolve(), first)
        XCTAssertEqual(loads, 1, "A redraw must not reload and resolve an unchanged skin")
        _ = resolve(.portrait)
        _ = resolve(.landscape, .light)
        XCTAssertEqual(loads, 3, "Orientation and appearance require independent previews")
        profile.name = "Edited"
        _ = resolve()
        XCTAssertEqual(loads, 4, "Profile edits invalidate the previous preview")
        cache.removeAll()
        _ = resolve()
        XCTAssertEqual(loads, 5, "Skin replacement notifications must invalidate cached resolution")
    }


    func testActionSetMirrorHandlesChordsTouchOwnersAndReset() {
        var inputs = ThumbleActionSetInputState()
        XCTAssertEqual(inputs.actionSet, .base)
        inputs.record(input: "lt", pressed: true, pressIdentifier: 1, buttons: [.leftTriggerButton])
        inputs.record(input: "lt", pressed: true, pressIdentifier: 2, buttons: [.leftTriggerButton])
        inputs.record(input: "rt", pressed: true, pressIdentifier: 3, buttons: [.rightTriggerButton])
        XCTAssertEqual(inputs.actionSet, .bothTriggers)
        // A refresh with a changed binding does not change ownership established on down.
        inputs.record(input: "lt", pressed: true, pressIdentifier: 1, buttons: [.rightTriggerButton])
        inputs.record(input: "lt", pressed: false, pressIdentifier: 1, buttons: [])
        XCTAssertEqual(inputs.actionSet, .bothTriggers)
        inputs.record(input: "rt", pressed: false, pressIdentifier: 3, buttons: [])
        XCTAssertEqual(inputs.actionSet, .leftTrigger)
        inputs.record(input: "lt", pressed: false, pressIdentifier: 2, buttons: [])
        XCTAssertEqual(inputs.actionSet, .base)
        inputs.record(input: "attack", pressed: true, buttons: [.south])
        inputs.record(input: "attack", pressed: true, buttons: [.leftTriggerButton])
        XCTAssertEqual(inputs.actionSet, .base, "Refreshes preserve the original non-trigger binding too")
        inputs.record(input: "attack", pressed: false, buttons: [])
        inputs.record(trigger: .left, value: 0.8)
        inputs.record(input: "lt", pressed: true, buttons: [.leftTriggerButton])
        inputs.record(trigger: .left, value: 0)
        XCTAssertEqual(inputs.actionSet, .leftTrigger, "Digital and analog sources cannot release each other")
        inputs.record(input: "lt", pressed: false, buttons: [])
        inputs.record(trigger: .right, value: 0.8)
        XCTAssertEqual(inputs.actionSet, .rightTrigger)
        inputs.record(trigger: .right, value: .nan)
        XCTAssertEqual(inputs.actionSet, .base)
        inputs.record(input: "chord", pressed: true, buttons: [.leftTriggerButton, .rightTriggerButton])
        inputs.reset()
        XCTAssertEqual(inputs.actionSet, .base)
    }

    func testActionSetVariantsRoundTripAndPreserveInputAndGeometry() throws {
        var package = makeSkinPackage()
        let button = KeypadElementID.preset(5)
        let variants = ThumbleActionSet.allCases.map { actionSet in
            ThumbleSkinVariant(id: actionSet.rawValue,
                appearance: ThumbleSkinAppearance(buttonRules: [
                    ThumbleSkinButtonRule(button: button,
                        appearance: ThumbleSkinControlAppearance(icon: .text(actionSet.rawValue)))
                ]), actionSet: actionSet)
        }
        package.skin = ThumbleSkin(base: package.skin!.base, variants: variants)
        let decoded = try JSONDecoder().decode(ThumbleSkin.self, from: JSONEncoder().encode(package.skin!))
        XCTAssertEqual(decoded, package.skin)
        let original = declaredActionCustomization().normalized
        var profile = GamepadConfigurationProfile(name: "Layered", customization: original)
        profile.applySkin(package)
        for actionSet in ThumbleActionSet.allCases {
            let rendered = profile.resolvedCustomization(for: .landscape, colorScheme: .dark,
                skinPackage: package, actionSet: actionSet)
            XCTAssertEqual(rendered.buttonCustomization(for: button).icon, .text(actionSet.rawValue))
            XCTAssertEqual(rendered.elements.map(\.output), original.elements.map(\.output))
            XCTAssertEqual(rendered.elements.map(\.partOutputs), original.elements.map(\.partOutputs))
            XCTAssertEqual(rendered.elements.map(\.id), original.elements.map(\.id))
            XCTAssertEqual(rendered.elements.map { $0.layout.centerX }, original.elements.map { $0.layout.centerX })
        }
        XCTAssertEqual(profile.resolvedCustomization(for: .landscape, colorScheme: .dark,
            skinPackage: package).buttonCustomization(for: button).icon, .text("base"))
        let legacy = try JSONDecoder().decode(ThumbleSkinVariant.self,
            from: JSONEncoder().encode(ThumbleSkinVariant(id: "legacy", appearance: .empty)))
        XCTAssertNil(legacy.actionSet)
    }

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

    func testMaterialOnlySkinRetainsNativeImageLabelsAndExplicitStyleIconsReplaceThem() throws {
        var customization = declaredActionCustomization()
        let nativeIcon = GamepadControlIcon(source: .asset, value: "ability", scale: 2.4, renderingMode: .original)
        var jump = customization.buttonCustomization(for: .preset(5))
        jump.icon = nativeIcon
        jump.showsIntegratedLabel = false
        customization.setButtonCustomization(jump, for: .preset(5))
        customization.addCustomButton()
        let index = try XCTUnwrap(customization.customButtons.indices.last)
        let customID = customization.customButtons[index].id
        customization.customButtons[index].layout.icon = nativeIcon
        customization.customButtons[index].visualRole = .primaryAction
        let material = GamepadStyleToken(id: "material", name: "Material", visualStyle: .init(normal: .init(fillStyle: .solid(color("#123456")))))
        var skin = ThumbleSkin(base: ThumbleSkinAppearance(
            roleRules: [.init(role: .primaryAction, appearance: .init(styleID: material.id))],
            styleLibrary: .init(styles: [material])))
        func package(_ skin: ThumbleSkin) -> ThumbleSkinPackage {
            .init(manifest: .init(identifier: "com.example.material", version: "1.0.0", name: "Material", author: .init(name: "Tests")), skin: skin)
        }
        for options in [ThumbleSkinApplicationOptions.replacingAppearance, .preservingUserOverrides] {
            let resolved = customization.applying(skinPackage: package(skin), orientation: .landscape, colorScheme: .dark, options: options)
            XCTAssertEqual(resolved.buttonCustomization(for: .preset(5)).icon, nativeIcon)
            XCTAssertEqual(resolved.customButtons.first { $0.id == customID }?.layout.icon, nativeIcon)
            XCTAssertFalse(resolved.buttonCustomization(for: .preset(5)).showsIntegratedLabel)
        }
        var explicitStyle = material
        explicitStyle.visualStyle.icon = .sfSymbol("sparkles")
        skin.base.styleLibrary = .init(styles: [explicitStyle])
        let replaced = customization.applying(skinPackage: package(skin), orientation: .landscape, colorScheme: .dark, options: .replacingAppearance)
        XCTAssertEqual(replaced.buttonCustomization(for: .preset(5)).icon, .sfSymbol("sparkles"))
        XCTAssertEqual(replaced.customButtons.first { $0.id == customID }?.layout.icon, .sfSymbol("sparkles"))
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

    /// Emits an ignored artifact for the Android cross-language fixture workflow.
    func testEmitAndroidSkinAppearanceOracle() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func json<T: Encodable>(_ value: T) throws -> Any {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
        }
        var synthetic = makeSkinPackage()
        var model = try XCTUnwrap(synthetic.skin)
        model.base.defaultControl = ThumbleSkinControlAppearance(cornerRadius: 11, shadowStrength: 0.75)
        model.variants = [
            ThumbleSkinVariant(id: "a-portrait", orientation: .portrait,
                appearance: ThumbleSkinAppearance(accentStyle: .green, defaultControl: ThumbleSkinControlAppearance(cornerRadius: 19))),
            ThumbleSkinVariant(id: "b-portrait", orientation: .portrait,
                appearance: ThumbleSkinAppearance(defaultControl: ThumbleSkinControlAppearance(icon: .text("PORTRAIT")))),
            ThumbleSkinVariant(id: "dark", colorScheme: .dark,
                appearance: ThumbleSkinAppearance(showsButtonLabels: true, roleRules: [
                    ThumbleSkinRoleRule(role: .primaryAction, appearance: ThumbleSkinControlAppearance(shadowStrength: 1.7))
                ])),
            ThumbleSkinVariant(id: "portrait-dark", orientation: .portrait, colorScheme: .dark,
                appearance: ThumbleSkinAppearance(accentStyle: .amber))
        ] + ThumbleActionSet.allCases.map { bank in
            ThumbleSkinVariant(id: "bank-" + bank.rawValue,
                appearance: ThumbleSkinAppearance(buttonRules: [ThumbleSkinButtonRule(button: .preset(5),
                    appearance: ThumbleSkinControlAppearance(icon: .text(bank.rawValue)))]), actionSet: bank)
        }
        synthetic.skin = model.normalized
        synthetic.manifest.compatibility = ThumbleSkinCompatibility(requiredFeatures: [.actionSetLayers])
        var packages = [("synthetic", synthetic)]
        let sources = root.appendingPathComponent("Host/fixtures/legacy-skin-packages")
        for name in ["solar-sumi-1.0.0-edbecde5b708.pocketpad", "foldline-relay-1.0.0-d04c121e9b0a.pocketpad", "indigo-pocket-1.0.0-72fdbb32d789.pocketpad", "tideglass-field-1.0.0-77927e956d14.pocketpad"] {
            packages.append((name, try ThumbleSkinPackageCodec.read(from: sources.appendingPathComponent(name))))
        }
        var packageInputs: [String: Any] = [:]
        var expectedAppearances: [String: Any] = [:]
        var appearances: [[String: Any]] = []
        var layouts: [[String: Any]] = []
        for (name, package) in packages {
            let skin = try XCTUnwrap(package.skin)
            packageInputs[name] = ["skin": try json(skin), "manifest": try json(package.manifest),
                "assetPayloads": name == "synthetic" ? package.assets.mapValues { $0.base64EncodedString() } : [:]]
            for orientation in ThumbleSkinOrientation.allCases {
                for scheme in ThumbleSkinColorScheme.allCases {
                    for bank in ThumbleActionSet.allCases {
                        let appearance = skin.appearance(orientation: orientation, colorScheme: scheme, actionSet: bank)
                        var controls: [[String: Any]] = []
                        for kind in GamepadCustomControlKind.allCases {
                            let id = kind == .button ? KeypadElementID.preset(5) : KeypadElementID(UUID(uuidString: "88888888-1111-4222-8333-444444444444")!)
                            controls.append(["id": id.rawValue, "kind": kind.rawValue,
                                "expected": try json(appearance.controlAppearance(for: id, controlKind: kind))])
                        }
                        controls.append(["id": KeypadElementID.preset(5).rawValue, "kind": "button", "role": "primary_action",
                            "expected": try json(appearance.controlAppearance(for: .preset(5), controlKind: .button, visualRole: .primaryAction))])
                        let expected = try json(appearance)
                        let expectedKey = try JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys]).thumbleSHA256
                        expectedAppearances[expectedKey] = expected
                        appearances.append(["source": name, "orientation": orientation.rawValue,
                            "scheme": scheme.rawValue, "actionSet": bank.rawValue, "expectedKey": expectedKey, "controls": controls])
                        if name != "synthetic" { continue }
                        for mode in ["defaults", "local", "baseline", "clear-baseline", "replace"] {
                            var local = declaredActionCustomization().normalized
                            let original = local
                            var baseline: GamepadCustomization?
                            if mode == "local" || mode == "baseline" {
                                var layout = local.buttonCustomization(for: .preset(5))
                                layout.icon = .text("LOCAL")
                                layout.cornerRadius = 29
                                layout.shadowStrength = 1.25
                                layout.centerX = 0.73
                                layout.rotationDegrees = 17
                                local.setButtonCustomization(layout, for: .preset(5))
                                local = local.normalized
                            }
                            if mode == "baseline" { baseline = original }
                            if mode == "clear-baseline" {
                                var saved = original
                                var layout = saved.buttonCustomization(for: .preset(5))
                                layout.icon = .text("REMOVED")
                                layout.cornerRadius = 29
                                layout.shadowStrength = 1.25
                                saved.setButtonCustomization(layout, for: .preset(5))
                                baseline = saved.normalized
                            }
                            let result = local.applying(skinPackage: package, orientation: orientation, colorScheme: scheme,
                                options: mode == "replace" ? .replacingAppearance : .preservingUserOverrides,
                                overrideBaseline: baseline, actionSet: bank)
                            var row: [String: Any] = ["mode": mode, "orientation": orientation.rawValue, "scheme": scheme.rawValue,
                                "actionSet": bank.rawValue, "source": name,
                                "local": try json(local.buttonCustomization(for: .preset(5))),
                                "localStyles": try json(local.styleLibrary), "localAssets": try json(local.assetLibrary),
                                "expected": try json(result.buttonCustomization(for: .preset(5))),
                                "expectedStyles": try json(result.styleLibrary), "expectedAssets": try json(result.assetLibrary)]
                            if let baseline {
                                row["baseline"] = try json(baseline.buttonCustomization(for: .preset(5)))
                                row["baselineStyles"] = try json(baseline.styleLibrary)
                                row["baselineAssets"] = try json(baseline.assetLibrary)
                            }
                            layouts.append(row)
                        }
                    }
                }
            }
        }
        XCTAssertEqual(appearances.count, 80)
        XCTAssertEqual(layouts.count, 80)
        // Exercise normalization after the cascade, including native silhouette
        // defaults and local corner edits that differ from the saved baseline.
        var controlEdges: [[String: Any]] = []
        let shapes: [GamepadButtonShapeStyle?] = [nil] + GamepadButtonShapeStyle.allCases.map { Optional($0) }
        for shape in shapes {
            for geometry in 0..<8 {
                var appearance = ThumbleSkinControlAppearance(shape: shape, shadowStrength: geometry % 2 == 0 ? -1 : 3)
                switch geometry {
                case 0: appearance.cornerRadius = -3
                case 1: appearance.cornerRadius = 0
                case 2: appearance.cornerRadius = 6
                case 3: appearance.cornerRadius = 6.0005
                case 4: appearance.cornerRadius = 160
                case 5: appearance.cornerRadii = .uniform(6)
                case 6: appearance.cornerRadii = .uniform(-3)
                default:
                    appearance.cornerRadius = 45
                    appearance.cornerRadii = GamepadCornerRadii(topLeading: -4, topTrailing: 6, bottomTrailing: 200, bottomLeading: 0)
                }
                var edgePackage = synthetic
                var edgeSkin = try XCTUnwrap(edgePackage.skin)
                edgeSkin.base = ThumbleSkinAppearance(defaultControl: appearance)
                edgeSkin.variants = []
                edgePackage.skin = edgeSkin
                for mode in ["replace", "local", "baseline"] {
                    var local = declaredActionCustomization().normalized
                    let original = local
                    if mode != "replace" {
                        var layout = local.buttonCustomization(for: .preset(5))
                        layout.shape = .rectangle
                        layout.cornerRadius = 27
                        local.setButtonCustomization(layout, for: .preset(5))
                        local = local.normalized
                    }
                    let baseline = mode == "baseline" ? original : nil
                    let result = local.applying(skinPackage: edgePackage, orientation: .portrait, colorScheme: .light,
                        options: mode == "replace" ? .replacingAppearance : .preservingUserOverrides,
                        overrideBaseline: baseline)
                    var row: [String: Any] = ["mode": mode, "appearance": try json(appearance),
                        "local": try json(local.buttonCustomization(for: .preset(5))),
                        "expected": try json(result.buttonCustomization(for: .preset(5)))]
                    if let baseline { row["baseline"] = try json(baseline.buttonCustomization(for: .preset(5))) }
                    controlEdges.append(row)
                }
            }
        }
        XCTAssertEqual(controlEdges.count, 192)
        let output = root.appendingPathComponent("build/AndroidSkinResolver/native-oracle.json")
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["fixtureVersion": 1, "packages": packageInputs, "expectedAppearances": expectedAppearances, "appearanceCases": appearances, "layoutCases": layouts, "controlEdgeCases": controlEdges], options: [.sortedKeys])
            .write(to: output, options: .atomic)
    }

    func testEmitAndroidSkinLifecycleOracle() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func object<T: Encodable>(_ value: T) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        }
        func profileObject(_ profile: GamepadConfigurationProfile) throws -> [String: Any] {
            var result = try object(profile)
            result["updatedAt"] = 0
            return result
        }
        let first = makeSkinPackage()
        var second = makeSkinPackage()
        second.manifest.identifier = "com.example.second-skin"
        second.manifest.version = "2.0.0"
        second.skin?.base.accentStyle = .pink
        second.skin?.base.showsButtonLabels = true
        second.skin?.base.backgroundFillStyle = .solid(color("#997755"))
        var inputs: [String: GamepadConfigurationProfile] = [:]
        let basic = GamepadConfigurationProfile(id: UUID(uuidString: "10101010-1111-4222-8333-000000000001")!, name: "Lifecycle", customization: declaredActionCustomization())
        inputs["basic"] = basic
        var variants = basic
        for (name, orientation) in [("nes", GamepadEditorDeviceOrientation.portrait), ("arcadeStick", .landscape)] {
            let url = root.appendingPathComponent("Host/fixtures/controller-templates/v1/\(name).json")
            let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            let profile = try JSONDecoder().decode(GamepadConfigurationProfile.self,
                from: JSONSerialization.data(withJSONObject: XCTUnwrap(fixture["profile"])))
            variants.setCustomizationVariant(profile.customization, for: orientation)
        }
        inputs["variants"] = variants
        var cases: [[String: Any]] = []
        func record(_ name: String, _ input: GamepadConfigurationProfile, _ output: GamepadConfigurationProfile,
                    operation: String, package: String?, scheme: ThumbleSkinColorScheme) throws {
            var row: [String: Any] = ["name": name, "operation": operation, "scheme": scheme.rawValue,
                "input": try profileObject(input), "expected": try profileObject(output)]
            if let package { row["package"] = package }
            cases.append(row)
        }
        for (name, original) in inputs.sorted(by: { $0.key < $1.key }) {
            for scheme in ThumbleSkinColorScheme.allCases {
                var applied = original
                applied.applySkin(first, colorScheme: scheme)
                try record("\(name)-apply-\(scheme.rawValue)", original, applied, operation: "apply", package: "first", scheme: scheme)
                var edited = applied
                var layout = edited.customization
                layout.backgroundDarkColor = color("#AABBCC")
                layout.accentStyle = .green
                layout.showsButtonLabels = true
                layout.assetLibrary = .init(assets: [.init(id: "skin-image", name: "Local image", contentType: "image/png", data: Data("local".utf8))])
                edited.customization = layout
                for (label, source) in [("applied", applied), ("edited", edited)] {
                    for (packageName, package) in [("first", first), ("second", second)] {
                        var reapplied = source
                        reapplied.applySkin(package, colorScheme: scheme)
                        try record("\(name)-\(label)-apply-\(packageName)-\(scheme.rawValue)", source, reapplied,
                            operation: "apply", package: packageName, scheme: scheme)
                        var detached = source
                        detached.detachSkin(resolving: package, colorScheme: scheme)
                        try record("\(name)-\(label)-detach-\(packageName)-\(scheme.rawValue)", source, detached,
                            operation: "detach", package: packageName, scheme: scheme)
                    }
                    var missing = source
                    missing.detachSkin()
                    try record("\(name)-\(label)-detach-missing-\(scheme.rawValue)", source, missing,
                        operation: "detach", package: nil, scheme: scheme)
                }
            }
        }
        var packages: [String: Any] = [:]
        for (name, package) in [("first", first), ("second", second)] {
            packages[name] = ["manifest": try object(package.manifest), "skin": try object(XCTUnwrap(package.skin)),
                "assetPayloads": package.assets.mapValues { $0.base64EncodedString() }]
        }
        let directory = root.appendingPathComponent("build/AndroidSkinResolver")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ["fixtureVersion": 1, "packages": packages, "cases": cases], options: [.sortedKeys])
        try data.write(to: directory.appendingPathComponent("native-lifecycle-oracle.json"))
        XCTAssertEqual(cases.count, 44)
    }

    func testEmitAndroidSkinProfileOracle() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func json<T: Encodable>(_ value: T) throws -> Any {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
        }
        var package = makeSkinPackage()
        var skin = try XCTUnwrap(package.skin)
        skin.base.defaultControl = ThumbleSkinControlAppearance(hapticFeedback: .defaultValue, cornerRadius: 6, shadowStrength: 0.65, joystickVisualStyle: .pad)
        skin.base.artworkLayers = [ThumbleSkinArtworkLayer(id: "test-underlay", fillStyle: .solid(color("#223344")))]
        package.skin = skin
        var profiles: [String: GamepadCustomization] = ["default": declaredActionCustomization().normalized]
        let directory = root.appendingPathComponent("Host/fixtures/controller-templates/v1")
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "json" && $0.lastPathComponent != "manifest.json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            let profileData = try JSONSerialization.data(withJSONObject: XCTUnwrap(object["profile"]))
            let profile = try JSONDecoder().decode(GamepadConfigurationProfile.self, from: profileData)
            profiles[url.deletingPathExtension().lastPathComponent] = profile.customization.normalized
        }
        var mixed = declaredActionCustomization().normalized
        for (index, kind) in GamepadCustomControlKind.allCases.enumerated() {
            let id = UUID(uuidString: String(format: "12121212-1111-4222-8333-%012d", index + 1))!
            mixed.elements.append(KeypadElement(id: id, label: kind.rawValue, kind: kind,
                layout: GamepadButtonCustomization(centerX: 0.25 + CGFloat(index) * 0.07, centerY: 0.65, rotationDegrees: 15),
                visualRole: kind == .button ? .utility : nil))
        }
        profiles["mixed"] = mixed.normalized
        var future = try XCTUnwrap(try json(profiles["default"]!) as? [String: Any])
        var futureElements = try XCTUnwrap(future["elements"] as? [[String: Any]])
        futureElements[0]["futureAppearance"] = ["kind": "image", "image": ["assetID": "skin-image"]]
        future["elements"] = futureElements
        profiles["future-metadata"] = try JSONDecoder().decode(GamepadCustomization.self,
            from: JSONSerialization.data(withJSONObject: future)).normalized
        var cases: [[String: Any]] = []
        for (id, original) in profiles.sorted(by: { $0.key < $1.key }) {
            for scheme in ThumbleSkinColorScheme.allCases {
                for preserve in [true, false] {
                    let result = original.applying(skinPackage: package, orientation: .landscape, colorScheme: scheme,
                        options: preserve ? .preservingUserOverrides : .replacingAppearance)
                    cases.append(["profile": id, "scheme": scheme.rawValue, "orientation": "landscape", "preserve": preserve,
                        "expected": try json(result)])
                }
            }
        }
        var local = try XCTUnwrap(profiles["default"])
        let baseline = local
        local.backgroundDarkColor = color("#AABBCC")
        local.accentStyle = .green
        local.showsButtonLabels = false
        local.assetLibrary = .init(assets: [.init(id: "skin-image", name: "Local image", contentType: "image/png", data: Data("local".utf8))])
        local.styleLibrary = .init(styles: [.init(id: "skin-primary", name: "Local token", visualStyle: .init(normal: .init(opacity: 0.75)))])
        profiles["baseline-local"] = local.normalized
        for scheme in ThumbleSkinColorScheme.allCases {
            let result = local.applying(skinPackage: package, orientation: .landscape, colorScheme: scheme,
                options: .preservingUserOverrides, overrideBaseline: baseline)
            cases.append(["profile": "baseline-local", "baseline": "default", "scheme": scheme.rawValue,
                "orientation": "landscape", "preserve": true, "expected": try json(result)])
        }
        var evaluations: [[String: Any]] = []
        func record(_ name: String, _ compatibility: ThumbleSkinCompatibility?, _ customization: GamepadCustomization) throws {
            var candidate = package
            candidate.manifest.compatibility = compatibility
            let expected = ThumbleSkinCompatibilityEvaluator.evaluate(compatibility, customization: customization, orientation: .landscape)
            var row: [String: Any] = ["name": name, "local": try json(customization), "orientation": "landscape",
                "expected": try json(expected), "expectedResolved": try json(customization.applying(skinPackage: candidate,
                    orientation: .landscape, colorScheme: .dark, options: .replacingAppearance))]
            if let compatibility { row["compatibility"] = try json(compatibility) }
            evaluations.append(row)
        }
        try record("none", nil, baseline)
        try record("orientation", .init(orientations: [.portrait]), baseline)
        try record("small-aspect", .init(minimumAspectRatio: 4), baseline)
        try record("large-aspect", .init(maximumAspectRatio: 0.25), baseline)
        try record("missing-roles", .init(requiredRoles: [.movement, .custom, .trackpad]), baseline)
        try record("unknown-template", .init(mode: .templateAligned), baseline)
        try record("unknown-template-incompatible", .init(mode: .templateAligned, orientations: [.portrait]), baseline)
        let nes = try XCTUnwrap(profiles["nes"])
        try record("template-match", .init(mode: .templateAligned, templates: [.init(templateID: " NES ")]), nes)
        try record("template-wrong", .init(mode: .templateAligned, templates: [.init(templateID: "snes")]), nes)
        try record("template-revision", .init(mode: .templateAligned, templates: [.init(templateID: "nes", minimumRevision: 4, maximumRevision: 1)]), nes)
        try record("template-large-revision", .init(mode: .templateAligned, templates: [.init(templateID: "nes", minimumRevision: 3_000_000_000)]), nes)
        var canonicalTemplate = nes
        canonicalTemplate.designMetadata?.sourceTemplateID = "e\u{301}"
        try record("template-canonical-identity", .init(mode: .templateAligned, templates: [.init(templateID: "é")]), canonicalTemplate.normalized)
        let canvas = baseline.deviceCanvas.editorDeviceFrame.screenRect.size
        let controls = baseline.resolvedControls(in: canvas).filter { !$0.layoutCustomization.isHidden }.map { control in
            ThumbleSkinArtboardControl(id: control.id.id, label: control.label, kind: control.controlKind, visualRole: control.visualRole,
                inputID: control.inputID, frame: .init(x: control.frame.minX / canvas.width, y: control.frame.minY / canvas.height,
                    width: control.frame.width / canvas.width, height: control.frame.height / canvas.height), rotationDegrees: control.rotationDegrees)
        }
        let variant = ThumbleSkinArtboardVariant(id: "capture", orientation: .landscape, canvasWidth: canvas.width, canvasHeight: canvas.height,
            safeAreaInsets: .init(top: 0, leading: 0, bottom: 0, trailing: 0), controls: controls)
        try record("captured-match", .init(mode: .capturedController, capturedGeometry: .init(variants: [variant])), baseline)
        for mode in ["size", "frame", "rotation", "missing-control", "duplicate-control", "inset", "no-variant", "invalid-presentation"] {
            var changed = variant
            switch mode {
            case "size": changed.canvasWidth += 1
            case "frame": changed.controls[0].frame.x += 0.001
            case "rotation": changed.controls[0].rotationDegrees = 1
            case "missing-control": changed.controls.removeLast()
            case "duplicate-control": changed.controls.append(changed.controls[0])
            case "inset": changed.safeAreaInsets.top = 0.46
            case "no-variant": changed.orientation = .portrait
            default: changed.controls[0].presentation = GamepadControlPresentation(legend: "bad\u{01}")
            }
            try record("captured-" + mode, .init(mode: .capturedController, capturedGeometry: .init(variants: [changed])), baseline)
        }
        var hidden = baseline
        hidden.topBarActivationRegion.isHidden = true
        try record("captured-hidden-system", .init(mode: .capturedController, capturedGeometry: .init(variants: [variant])), hidden.normalized)
        let canvases: [[String: Any]] = GamepadEditorDeviceCatalog.frames.map { ["id": $0.id, "width": $0.screenSize.width, "height": $0.screenSize.height] }
        let geometries: [[String: Any]] = profiles.sorted(by: { $0.key < $1.key }).map { id, customization in
            let size = customization.deviceCanvas.editorDeviceFrame.screenRect.size
            let controls: [[String: Any]] = customization.resolvedControls(in: size).filter { !$0.layoutCustomization.isHidden }.map {
                ["id": $0.id.id, "kind": $0.controlKind.rawValue, "role": $0.visualRole.rawValue,
                 "rotation": $0.rotationDegrees, "frame": ["x": $0.frame.minX / size.width, "y": $0.frame.minY / size.height,
                    "width": $0.frame.width / size.width, "height": $0.frame.height / size.height]]
            }
            return ["profile": id, "controls": controls]
        }
        let output: [String: Any] = ["fixtureVersion": 1, "skin": try json(skin), "manifest": try json(package.manifest),
            "assetPayloads": package.assets.mapValues { $0.base64EncodedString() }, "profiles": try profiles.mapValues { try json($0) },
            "cases": cases, "compatibilityCases": evaluations, "canvases": canvases, "geometries": geometries,
            "defaultLayout": try json(GamepadButtonCustomization.defaultValue), "defaultTopBar": try json(GamepadCustomization.defaultTopBarActivationRegion)]
        let url = root.appendingPathComponent("build/AndroidSkinResolver/native-profile-oracle.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]).write(to: url, options: .atomic)
    }

    func testEmitAndroidSkinModelOracle() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func object<T: Encodable>(_ value: T) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        }
        var rows: [[String: Any]] = []
        func record(_ kind: String, _ input: [String: Any], repeatImageBytes: Int? = nil, rawJSON: String? = nil) throws {
            var decodedInput = input
            if let count = repeatImageBytes {
                var image = try XCTUnwrap(input["image"] as? [String: Any])
                image["data"] = Data(repeating: 7, count: count).base64EncodedString()
                decodedInput["image"] = image
            }
            let data = try rawJSON.map { Data($0.utf8) } ?? JSONSerialization.data(withJSONObject: decodedInput, options: [.sortedKeys])
            let decoder = JSONDecoder()
            var row: [String: Any] = ["kind": kind, "input": input]
            if let count = repeatImageBytes { row["repeatImageDataBytes"] = count }
            if let rawJSON { row["rawJSON"] = rawJSON }
            func expected<T: Encodable>(_ value: T) throws {
                row["accepted"] = true
                func compact(_ json: Any) -> Any {
                    if let dictionary = json as? [String: Any] {
                        return dictionary.mapValues { entry -> Any in
                            if let encoded = entry as? String, encoded.count > 1024, let bytes = Data(base64Encoded: encoded) {
                                return "@base64-sha256:" + bytes.thumbleSHA256
                            }
                            return compact(entry)
                        }
                    }
                    if let array = json as? [Any] { return array.map(compact) }
                    return json
                }
                row["expected"] = compact(try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed]))
            }
            do {
                switch kind {
                case "color": try expected(decoder.decode(GamepadRGBAColor.self, from: data).normalized)
                case "icon": try expected(decoder.decode(GamepadControlIcon.self, from: data).normalized)
                case "haptic": try expected(decoder.decode(GamepadHapticFeedback.self, from: data).normalized)
                case "fill": try expected(decoder.decode(GamepadFillStyle.self, from: data).normalized)
                case "content": try expected(decoder.decode(GamepadControlContentStyle.self, from: data).normalized)
                case "state": try expected(decoder.decode(GamepadControlStateStyle.self, from: data).normalized)
                case "visual": try expected(decoder.decode(GamepadControlVisualStyle.self, from: data).normalized)
                case "control": try expected(decoder.decode(ThumbleSkinControlAppearance.self, from: data).normalized)
                case "styleLibrary": try expected(decoder.decode(GamepadStyleLibrary.self, from: data).normalized)
                case "artwork": try expected(decoder.decode(ThumbleSkinArtworkLayer.self, from: data).normalized)
                case "appearance": try expected(decoder.decode(ThumbleSkinAppearance.self, from: data).normalized)
                case "skin": try expected(decoder.decode(ThumbleSkin.self, from: data).normalized)
                default: XCTFail("Unknown model oracle type")
                }
            } catch { row["accepted"] = false }
            rows.append(row)
        }
        let baseColor: [String: Any] = ["red": 0.2, "green": 0.4, "blue": 0.6, "alpha": 0.5]
        let icon = try object(GamepadControlIcon.text(" X "))
        let haptic = try object(GamepadHapticFeedback())
        let image = try object(GamepadFillStyle.image(GamepadImageFill(assetID: " image ")))
        let tile = try object(GamepadFillStyle.tile(GamepadTileFill()))
        let gradient = try object(GamepadFillStyle.gradient(GamepadGradientFill(stops: [])))
        let state: [String: Any] = ["opacity": 0.75]
        let visual: [String: Any] = ["normal": state]
        let token: [String: Any] = ["id": " token ", "name": " Token ", "visualStyle": visual]
        let appearance: [String: Any] = ["roleRules": [], "buttonRules": [], "styleLibrary": ["styles": []]]
        let artwork = try object(ThumbleSkinArtworkLayer(id: " layer "))
        let bases: [(String, [String: Any])] = [("color",baseColor),("icon",icon),("haptic",haptic),("fill",image),
            ("content",["legend": "Legend"]),("state",state),("visual",visual),("control",["icon":icon]),
            ("styleLibrary",["styles":[token]]),("artwork",artwork),("appearance",appearance),("skin",["base":appearance,"variants":[]])]
        // Every known field is also mutated to null, a wrong type and absence.
        for (kind, input) in bases {
            try record(kind,input)
            var unknown = input; unknown["futureField"] = ["kind": "image"]; try record(kind,unknown)
            for key in input.keys.sorted() {
                for replacement in [NSNull(), "wrong", false, ["unexpected": 1], [1]] as [Any] {
                    var changed = input; changed[key] = replacement; try record(kind,changed)
                }
                var changed = input; changed.removeValue(forKey: key); try record(kind,changed)
            }
        }
        for scalar in [-1000.0, 0, 0.5, 1000] {
            try record("color", ["red":scalar,"green":scalar,"blue":scalar,"alpha":scalar])
            var i=icon;i["scale"]=scalar;try record("icon",i)
            var h=haptic;for key in ["intensity","sharpness","duration"] { h[key]=scalar };try record("haptic",h)
            try record("control",["cornerRadius":scalar,"shadowStrength":scalar,
                "cornerRadii":["topLeading":scalar,"topTrailing":scalar,"bottomTrailing":scalar,"bottomLeading":scalar],"joystickKnobColor":baseColor])
            let limits = ["strokeWidth","shadowRadius","shadowX","shadowY","glowRadius","innerShadowRadius","innerShadowX","innerShadowY",
                "highlightRadius","highlightX","highlightY","highlightOpacity","bevelWidth","indexWidth","opacity","scale","blurRadius"]
            var st: [String: Any] = [:];for key in limits { st[key]=scalar };try record("state",st)
            try record("content",["fontSize":scalar,"tracking":scalar,"labelPadding":scalar,"joystickKnobRatio":scalar,"joystickKnobStrokeWidth":scalar,
                "pointing":["trackpadFrameStrokeWidth":scalar,"joystickRingStrokeWidth":scalar]])
            var t=tile;var tp=try XCTUnwrap(t["tile"] as? [String:Any]);for key in ["scale","spacingX","spacingY","opacity"] { tp[key]=scalar };t["tile"]=tp;try record("fill",t)
            var im=image;var ip=try XCTUnwrap(im["image"] as? [String:Any]);for key in ["opacity","exposure","contrast","saturation","temperature","tint","highlights","shadows"] { ip[key]=scalar };im["image"]=ip;try record("fill",im)
            var a=artwork;a["opacity"]=scalar;a["rotationDegrees"]=scalar;a["zIndex"]=scalar
            a["frame"]=["x":scalar,"y":scalar,"width":scalar,"height":scalar];try record("artwork",a)
        }
        for hex in ["FFF6DE","FFF4CF","FFF1C1","FFDC73","FFC543","FFA600","FFAE00","FF9300","AA4D00","561900","2A1700","361900","502800","5B3000","703E00","ED9A00","FFF3D5","FDE68A","D97706","78350F","FCD34D","F59E0B","451A03","FACC15","F97316","EAB308"] {
            try record("color",object(GamepadRGBAColor(hexString: hex, alpha: 0.3)!))
        }
        for text in ["", " \n ", String(repeating:"e\u{301}",count:90), String(repeating:"👨‍👩‍👧‍👦",count:90), String(repeating:"🇵🇷",count:90), String(repeating:"🫱🏽‍🫲🏻",count:90), "A\u{01}B\u{85}C\u{200D}D\u{FEFF}E"] {
            var i=icon;i["value"]=text;try record("icon",i)
            try record("content",["legend":text])
            var t=token;t["name"]=text;t["id"]="A\u{301}中Ⅷ²";try record("styleLibrary",["styles":[t]])
        }
        var disabled=haptic;disabled["style"]="none";disabled["pattern"]="buzz";try record("haptic",disabled)
        for line in [-9,0,1,4,99,3_000_000_000] { try record("content",["lineLimit":line]) }
        for key in ["fontWeight","fontDesign","alignment","labelPlacement"] { try record("content",[key:"invalid"]) }
        for key in ["foregroundColor","strokeColor","shadowColor","glowColor","innerShadowColor","highlightColor","bevelHighlightColor","bevelShadowColor","indexColor"] {
            try record("state",[key:baseColor]);try record("state",[key:["red":1]])
        }
        for count in [0,1,8,9] {
            let shadow: [String:Any] = ["color":baseColor,"radius":120,"x":-120,"y":120,"opacity":0.5]
            try record("state",["shadows":Array(repeating:shadow,count:count)])
        }
        try record("state",["shadows":Array(repeating:["color":baseColor],count:8)+[["color":"bad"]]])
        try record("state",["opacity":0.75,"content":["icon":icon.merging(["value":" "]) { _,b in b }]])
        try record("visual",["normal":[:],"pressed":[:]])
        try record("visual",["normal":["content":["pointing":[:]]]])
        try record("visual",["normal":[:],"hapticStyle":"none"])
        for count in [0,1,3] {
            var g=gradient;var gp=try XCTUnwrap(g["gradient"] as? [String:Any]);gp["angleDegrees"] = -721
            gp["stops"]=(0..<count).map { ["offset": 2 - $0,"color":baseColor] as [String:Any] };g["gradient"]=gp;try record("fill",g)
        }
        for data in ["", "AA==", "AB==", "AQI=", "AQ", "AA==\n", "?", "====", "=", "==", "===", "=====", "========", "A===", "AAAA", "AAAA====", "AA======", "AAA=====", "A=======", "=AAA", "AA=A", "A=AA", "====AAAA", "AAAA=AAA", "AAA===", "AA====", "AAAA\n", "AA== "] {
            var f=image;var i=try XCTUnwrap(f["image"] as? [String:Any]);i["data"]=data;f["image"]=i;try record("fill",f)
        }
        try record("fill",image,repeatImageBytes:2_500_000)
        try record("fill",image,repeatImageBytes:2_500_001)
        for inset in [0.2,0.49,1.0,-1.0] {
            var f=image;var i=try XCTUnwrap(f["image"] as? [String:Any]);i["resizingMode"]="nine_slice_stretch"
            i["nineSliceInsets"]=["top":inset,"leading":inset,"bottom":inset,"trailing":inset];f["image"]=i;try record("fill",f)
        }
        for applies in [[],["button"],["trackpad","button","button"],["invalid"]] as [[String]] {
            var t=token;t["appliesTo"]=applies;try record("styleLibrary",["styles":[t]])
        }
        var invalidToken=token;invalidToken["visualStyle"]="bad"
        try record("styleLibrary",["styles":[token,invalidToken]])
        var empty=token;empty["visualStyle"]=["normal":[:]];try record("styleLibrary",["styles":[empty,token]])
        var a=appearance;a["roleRules"]=[["role":"utility","appearance":["cornerRadius":3]],["role":"utility","appearance":[:]]];try record("appearance",a)
        a["buttonRules"]=[["button":"1-1-1-1-1","appearance":[:]]];try record("appearance",a)
        a=appearance;a["artworkLayers"]=[artwork,artwork.merging(["opacity":0.4]) { _,b in b }];try record("appearance",a)
        for duplicate in ["same"," "] {
            try record("skin",["base":appearance,"variants":[["id":duplicate,"appearance":appearance],["id":duplicate,"appearance":["roleRules":"invalid"]]]])
        }
        let rawIcon = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: icon.merging(["value":"TOKEN"]) { _,b in b }), encoding: .utf8))
        for escaped in [#"\uD800"#, #"\uDC00"#, #"\uD83D\uDE00"#] {
            try record("icon", icon, rawJSON: rawIcon.replacingOccurrences(of: "TOKEN", with: escaped))
        }
        let output=root.appendingPathComponent("build/AndroidSkinResolver/native-model-oracle.json")
        try FileManager.default.createDirectory(at:output.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONSerialization.data(withJSONObject:["fixtureVersion":1,"cases":rows],options:[.sortedKeys]).write(to:output,options:.atomic)
    }

    func testEmitAndroidSkinTextOracle() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        var cases: [[String: Any]] = []
        var datasets: [String: Any] = [:]
        for version in ["16.0.0", "17.0.0"] {
            let testURL = root.appendingPathComponent("Host/fixtures/unicode/" + version + "/GraphemeBreakTest.txt")
            let data = try Data(contentsOf: testURL)
            let source = try XCTUnwrap(String(data: data, encoding: .utf8))
            var disagreements = 0
            var count = 0
            for line in source.components(separatedBy: .newlines) {
                let tokens = line.components(separatedBy: "#")[0].split(whereSeparator: { $0.isWhitespace })
                guard !tokens.isEmpty else { continue }
                var clusters: [String] = []
                var current = ""
                for token in tokens {
                    if token == "÷" { if !current.isEmpty { clusters.append(current);current = "" } }
                    else if token != "×", let scalar = UInt32(token, radix: 16).flatMap(UnicodeScalar.init) { current.unicodeScalars.append(scalar) }
                }
                if !current.isEmpty { clusters.append(current) }
                let text = clusters.joined()
                let native = text.map { String($0) }
                if native != clusters { disagreements += 1 }
                cases.append(["text": text, "expected": native, "dataset": version])
                count += 1
            }
            datasets[version] = ["sourceSHA256": data.thumbleSHA256, "cases": count, "nativeDisagreements": disagreements]
            XCTAssertEqual(disagreements, version == "16.0.0" ? 1 : 8, "Native behavior changed; review and regenerate the compatibility tables")
        }
        var properties: [String: Any] = [:]
        for (name, set) in [("alphanumeric",CharacterSet.alphanumerics),("control",.controlCharacters),("whitespace",.whitespacesAndNewlines)] {
            var ranges: [[UInt32]] = []
            var start: UInt32?
            var bits = Data(repeating: 0, count: 0x110000 / 8)
            for scalar in UInt32(0)...0x10FFFF {
                let member = UnicodeScalar(scalar).map { set.contains($0) } ?? false
                if member {
                    bits[Int(scalar) >> 3] |= UInt8(1 << (scalar & 7))
                    if start == nil { start = scalar }
                } else if let first = start { ranges.append([first, scalar - 1]);start = nil }
            }
            if let first = start { ranges.append([first,0x10FFFF]) }
            properties[name] = ["ranges": ranges, "membershipSHA256": bits.thumbleSHA256]
        }
        // Classify scalars through String's actual extended-grapheme behavior.
        // The probes separate controls, extending/spacing marks, prepends, emoji
        // joins and Indic conjunct classes. Hangul/RI/ZWJ have fixed scalar ranges.
        func transition(_ value: Int, scalar: UInt32, last: inout Int, start: inout UInt32, ranges: inout [[UInt32]]) {
            if value != last {
                if last != 0 { ranges.append([start, scalar - 1, UInt32(last)]) }
                start = scalar;last = value
            }
        }
        var graphemeRanges: [[UInt32]] = [], emojiRanges: [[UInt32]] = [], indicRanges: [[UInt32]] = []
        var previousGrapheme = 0, previousEmoji = 0, previousIndic = 0
        var graphemeStart: UInt32 = 0, emojiStart: UInt32 = 0, indicStart: UInt32 = 0
        for scalar in UInt32(0)...0x10FFFF {
            var grapheme = 0, emoji = 0, indic = 0
            if let unicode = UnicodeScalar(scalar) {
                let text = String(unicode)
                switch scalar {
                case 0x0D: grapheme = 1
                case 0x0A: grapheme = 2
                case 0x200D: grapheme = 5
                case 0x1F1E6...0x1F1FF: grapheme = 6
                case 0x1100...0x115F, 0xA960...0xA97C: grapheme = 9
                case 0x1160...0x11A7, 0xD7B0...0xD7C6: grapheme = 10
                case 0x11A8...0x11FF, 0xD7CB...0xD7FB: grapheme = 11
                case 0xAC00...0xD7A3: grapheme = (scalar - 0xAC00) % 28 == 0 ? 12 : 13
                default:
                    if (text + "\u{0308}").count > 1 { grapheme = 3 }
                    else if ("A" + text).count == 1 { grapheme = ("😀" + text + "‍😀").count == 1 ? 4 : 8 }
                    else if (text + "A").count == 1 { grapheme = 7 }
                }
                if grapheme == 0, ("😀‍" + text).count == 1 { emoji = 1 }
                if [4,5,8].contains(grapheme) {
                    if ("क" + text + "क").count == 1 { indic = 3 }
                    else if ("क्" + text + "क").count == 1 { indic = 2 }
                } else if grapheme == 0, CharacterSet.alphanumerics.contains(unicode), ("क्" + text).count == 1 { indic = 1 }
            }
            transition(grapheme, scalar: scalar, last: &previousGrapheme, start: &graphemeStart, ranges: &graphemeRanges)
            transition(emoji, scalar: scalar, last: &previousEmoji, start: &emojiStart, ranges: &emojiRanges)
            transition(indic, scalar: scalar, last: &previousIndic, start: &indicStart, ranges: &indicRanges)
        }
        transition(0, scalar: 0x110000, last: &previousGrapheme, start: &graphemeStart, ranges: &graphemeRanges)
        transition(0, scalar: 0x110000, last: &previousEmoji, start: &emojiStart, ranges: &emojiRanges)
        transition(0, scalar: 0x110000, last: &previousIndic, start: &indicStart, ranges: &indicRanges)
        let output = root.appendingPathComponent("build/AndroidSkinResolver/native-text-oracle.json")
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["fixtureVersion": 1, "datasets": datasets, "cases": cases, "properties": properties,
            "segmentation": ["grapheme": graphemeRanges, "pictographic": emojiRanges, "indic": indicRanges]], options: [.sortedKeys]).write(to: output, options: .atomic)
    }

    func testEmitAndroidSkinContractOracle() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func object<T: Encodable>(_ value: T) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        }
        let original = declaredActionCustomization().normalized
        let canvas = original.deviceCanvas.editorDeviceFrame.screenRect.size
        let resolved = try XCTUnwrap(original.resolvedControls(in: canvas).first)
        let control = ThumbleSkinArtboardControl(id: resolved.id.id, label: resolved.label, kind: resolved.controlKind, visualRole: resolved.visualRole,
            inputID: resolved.inputID, frame: .init(x: 0.2, y: 0.3, width: 0.1, height: 0.1), rotationDegrees: 0,
            presentation: .init(actionID: "jump", groupIDs: ["actions"], legend: "Jump", accessibilityName: "Jump"))
        var variant = ThumbleSkinArtboardVariant(id: "landscape", orientation: .landscape, canvasWidth: canvas.width, canvasHeight: canvas.height,
            safeAreaInsets: .init(top: 0, leading: 0, bottom: 0, trailing: 0), controls: [control])
        let bare = try object(ThumbleSkinCompatibility(minimumAspectRatio: 0.4, maximumAspectRatio: 3))
        let captured = try object(ThumbleSkinCompatibility(mode: .capturedController, orientations: [.landscape], capturedGeometry: .init(variants: [variant])))
        variant.controls[0].nativeGeometry = .init(hitFrame: .init(x: 0.1, y: 0.2, width: 0.3, height: 0.4))
        variant.controls[0].nativeSurfaces = .init(control: resolved, customization: original)
        variant.nativeChrome = .init(customization: original, orientation: .landscape, canvasSize: canvas,
            safeAreaInsets: variant.safeAreaInsets, hasLaunchTarget: true)
        let requested = GamepadButtonCustomization(hitInsets: .init(top: 4, leading: 4, bottom: 4, trailing: 4), fillColor: color("#223344"),
            visualStyle: .init(normal: .init(strokeWidth: 1, shadows: [.outer("#112233", radius: 2)],
                content: .init(icon: .text("Paint"), fontSize: 12, pointing: .init(trackpadFrameStrokeWidth: 1)))), hapticFeedback: .defaultValue)
        var resolvedPaint = GamepadResolvedControlPresentation(fillStyle: .solid(color("#112233")), foregroundColor: color("#334455"),
            strokeColor: color("#556677"), strokeWidth: 1, shadowColor: color("#000000"), shadowRadius: 2, shadowY: 1,
            shadows: [.outer("#000000", radius: 2)], icon: .text("Paint"))
        resolvedPaint.content = .init(fontSize: 12, pointing: .init(joystickRingStrokeWidth: 1))
        let item = GamepadNativeBarItemEvidence(item: .settings, state: .normal, requested: requested,
            resolved: resolvedPaint, foreground: color("#334455"), background: color("#667788"), border: color("#112233"), borderWidth: 1,
            cornerRadius: 6, height: 36, padding: 4, rendererShape: "rounded_rectangle", cornerRadii: .uniform(6))
        let icon = GamepadNativeBarIconEvidence(item: .settings, requested: .text("Settings"), source: "text", value: "Settings", fontSize: 14, frameWidth: nil, fallbacks: [])
        let paint = GamepadNativeBarPaintEvidence(items: [item.surfaceID:item], icons: [icon.surfaceID:icon])
        let layout = ThumbleSkinArtboardNativeLayout(rendererSHA256: "fixture",
            controls: [.init(controlID: resolved.id.id, colorScheme: .light, state: .normal, flowFrames: ["legend": .init(x: 1, y: 2, width: 3, height: 4)])],
            chrome: [.init(paint: paint, kind: "bar", colorScheme: .light, isConnected: true, isEditing: false,
                requestedVisibility: true, resolvedVisibility: true, frames: ["bar":.init(x: 0, y: 0, width: 100, height: 44)], viewport: .init(x: 0, y: 0, width: 874, height: 402))])
        var rich = try object(ThumbleSkinCompatibility(mode: .capturedController, orientations: [.landscape], capturedGeometry: .init(variants: [variant])))
        // CapturedGeometry's authoring initializer omits layout matrices; inject a
        // typed matrix to exercise the archive decoder's complete metadata path.
        var geometry = try XCTUnwrap(rich["capturedGeometry"] as? [String:Any])
        var variants = try XCTUnwrap(geometry["variants"] as? [[String:Any]])
        variants[0]["nativeLayout"] = try object(layout)
        geometry["variants"] = variants;rich["capturedGeometry"] = geometry
        let bases: [String:[String:Any]] = ["bare":bare,"captured":captured,"rich":rich]
        var cases: [[String:Any]] = []
        func patch(_ value: Any, path: ArraySlice<Any>, replacement: Any?, remove: Bool) throws -> Any {
            guard let first = path.first else { return replacement ?? NSNull() }
            if let key = first as? String {
                var object = try XCTUnwrap(value as? [String:Any])
                if path.count == 1 && remove { object.removeValue(forKey: key) }
                else { object[key] = try patch(object[key] ?? NSNull(), path: path.dropFirst(), replacement: replacement, remove: remove) }
                return object
            }
            var array = try XCTUnwrap(value as? [Any]);let index = try XCTUnwrap(first as? Int)
            array[index] = try patch(array[index], path: path.dropFirst(), replacement: replacement, remove: remove)
            return array
        }
        func record(_ base: String, _ path: [Any] = [], _ replacement: Any? = nil, remove: Bool = false) throws {
            let input = path.isEmpty ? bases[base]! : try XCTUnwrap(patch(bases[base]!, path: path[...], replacement: replacement, remove: remove) as? [String:Any])
            var row: [String:Any] = ["base":base,"path":path,"remove":remove]
            if let replacement { row["replacement"] = replacement }
            do {
                let decoded = try JSONDecoder().decode(ThumbleSkinCompatibility.self, from: JSONSerialization.data(withJSONObject: input)).normalized
                row["accepted"] = true;row["expected"] = try object(decoded)
                var package = makeSkinPackage()
                package.manifest.compatibility = decoded
                package.manifest.assets[0].sha256 = package.assets["skin-image"]!.thumbleSHA256
                let report = ThumbleSkinPackageValidator.validate(package)
                row["validPackage"] = report.isValid
                row["packageErrors"] = report.errors.map(\.code)
            } catch { row["accepted"] = false }
            cases.append(row)
        }
        for base in bases.keys.sorted() { try record(base) }
        let replacements: [Any] = [NSNull(),"wrong",true,3.5,[],[:]]
        for key in bare.keys.sorted() {
            for value in replacements { try record("bare",[key],value) }
            try record("bare",[key],remove:true)
        }
        try record("bare",["mode"],"template_aligned")
        for templates in [
            [["templateID":" NES ","minimumRevision":0,"maximumRevision":-1]],
            [["templateID":" ","minimumRevision":1]],
            [["templateID":"nes","minimumRevision":1],["templateID":"nes","minimumRevision":1]],
            [["templateID":"nes","minimumRevision":1],["templateID":"nes","minimumRevision":2]],
            [["templateID":"nes","minimumRevision":3_000_000_000]]
        ] { try record("bare",["templates"],templates) }
        try record("bare",["minimumAspectRatio"],0.1)
        try record("bare",["maximumAspectRatio"],0.1)
        try record("bare",["orientations"],["portrait","portrait","landscape"])
        let variantPath: [Any] = ["capturedGeometry","variants",0]
        for key in ["id","orientation","canvasWidth","canvasHeight","safeAreaInsets","controls"] {
            for value in replacements { try record("captured",variantPath+[key],value) }
            try record("captured",variantPath+[key],remove:true)
        }
        let controlPath = variantPath+["controls",0]
        for key in ["id","label","kind","visualRole","inputID","frame","rotationDegrees","presentation"] {
            for value in replacements { try record("captured",controlPath+[key],value) }
            try record("captured",controlPath+[key],remove:true)
        }
        for field in ["x","y","width","height"] { try record("captured",controlPath+["frame",field],"0.5") }
        try record("captured",controlPath+["presentation","unknown"],"field")
        try record("captured",controlPath+["presentation","legend"],String(repeating:"👨‍👩‍👧‍👦",count:12))
        try record("captured",controlPath+["presentation","accessibilityName"]," ")
        try record("captured",controlPath+["inputID"],"1-1-1-1-1")
        let richPaths: [[Any]] = [
            variantPath+["nativeChrome","canvasFrame"],variantPath+["nativeChrome","canvasFills","light"],
            variantPath+["nativeChrome","containerPresentation","light","fillColor","red"],
            variantPath+["nativeChrome","drawerVisibility",0,"isConnected"],variantPath+["nativeChrome","visibleBarItems"],
            controlPath+["nativeGeometry","scope"],controlPath+["nativeSurfaces","samples",0,"localFrames","face"],
            controlPath+["nativeSurfaces","samples",0,"effectiveFaceScale"],
            variantPath+["nativeLayout","controlSamples",0,"flowFrames","legend"],
            variantPath+["nativeLayout","chromeSamples",0,"paint","items",item.surfaceID,"requested","widthScale"],
            variantPath+["nativeLayout","chromeSamples",0,"paint","icons",icon.surfaceID,"requested","scale"],
            variantPath+["nativeLayout","chromeSamples",0,"paint","items",item.surfaceID,"resolvedOverride","strokeWidth"],
            variantPath+["nativeLayout","chromeSamples",0,"paint","items",item.surfaceID,"resolvedOverride","content","pointing","joystickRingStrokeWidth"],
            variantPath+["nativeLayout","chromeSamples",0,"paint","items",item.surfaceID,"resolvedOverride","hapticFeedback","duration"],
            variantPath+["nativeLayout","chromeSamples",0,"paint","items",item.surfaceID,"requested","visualStyle","normal","content","fontSize"],
            variantPath+["nativeLayout","chromeSamples",0,"paint","items",item.surfaceID,"requested","visualStyle","normal","shadows",0,"color","alpha"]]
        for path in richPaths { try record("rich",path,"wrong");try record("rich",path,remove:true) }
        try record("rich",variantPath+["nativeLayout","chromeSamples",0,"paint","items",item.surfaceID,"requested","widthScale"],99)
        try record("rich",variantPath+["nativeChrome","containerPresentation","light","fillColor","red"],2)
        try record("rich",variantPath+["nativeLayout","chromeSamples",0,"paint","items",item.surfaceID,"requested","visualStyle","normal","strokeWidth"],99)
        try record("rich",variantPath+["nativeLayout","chromeSamples",0,"paint","items",item.surfaceID,"requested","hitInsets","top"],999)
        var first = try object(control);var second = first
        first["id"] = "é";second["id"] = "e\u{301}"
        try record("captured",variantPath+["controls"],[first,second])
        try record("bare",["templates"],[["templateID":"é","minimumRevision":1],["templateID":"e\u{301}","minimumRevision":1]])
        try record("bare",["templates"],[["templateID":"é","minimumRevision":1],["templateID":"e\u{301}","minimumRevision":2]])
        var duplicateJSON: [[String:Any]] = []
        for raw in [#"{"é":1,"e\u0301":2}"#, #"{"id":1,"\u0069d":2}"#, #"{"id":1,"ID":2}"#] {
            let accepted = (try? JSONDecoder().decodeUnique([String:Int].self,from:Data(raw.utf8))) != nil
            duplicateJSON.append(["rawJSON":raw,"accepted":accepted])
        }
        for frame in [
            [[0,0],[1,1]], [[0,0,9],[1,1]], [[0,0],[1,1,9]], [[0,0],[1,1],[9,9]],
            [], [[0,0]], [[0],[1,1]], [[0,0],[-1,-2]], [[0,0],[0,0]]
        ] as [[[Int]]] {
            try record("rich",variantPath+["nativeChrome","canvasFrame"],frame)
        }
        try record("rich",variantPath+["nativeChrome","canvasFrame"],[["0",0],[1,1]])
        try record("rich",variantPath+["nativeChrome","canvasFrame"],["origin":["x":0,"y":0],"size":["width":1,"height":1]])
        let output=root.appendingPathComponent("build/AndroidSkinResolver/native-contract-oracle.json")
        try FileManager.default.createDirectory(at:output.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONSerialization.data(withJSONObject:["fixtureVersion":1,"bases":bases,"cases":cases,"duplicateJSON":duplicateJSON],options:[.sortedKeys]).write(to:output,options:.atomic)
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
