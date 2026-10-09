import AppKit
import CoreGraphics
import XCTest

final class GamepadSharedOperationsSmokeTests: XCTestCase {
    private func jsonSemanticallyEqual(_ lhs: Any, _ rhs: Any, tolerance: Double = 1e-12) -> Bool {
        if lhs is NSNull || rhs is NSNull {
            return lhs is NSNull && rhs is NSNull
        }
        if let lhs = lhs as? NSNumber, let rhs = rhs as? NSNumber {
            let left = lhs.doubleValue
            let right = rhs.doubleValue
            return left == right || abs(left - right) <= tolerance
        }
        if let lhs = lhs as? String, let rhs = rhs as? String {
            if let leftUUID = UUID(uuidString: lhs), let rightUUID = UUID(uuidString: rhs) {
                return leftUUID == rightUUID
            }
            return lhs == rhs
        }
        if let lhs = lhs as? [Any], let rhs = rhs as? [Any] {
            return lhs.count == rhs.count
                && zip(lhs, rhs).allSatisfy { jsonSemanticallyEqual($0, $1, tolerance: tolerance) }
        }
        if let lhs = lhs as? [String: Any], let rhs = rhs as? [String: Any] {
            return lhs.keys == rhs.keys
                && lhs.allSatisfy { key, value in
                    rhs[key].map { jsonSemanticallyEqual(value, $0, tolerance: tolerance) } == true
                }
        }
        return false
    }

    func testElementOnlyGeometryEditsKeepDeclaredUUIDsAndOwnedOutputs() throws {
        let first = UUID(uuidString: "BB6FB706-B969-4DB2-9E2B-03A21F3C9786")!
        let second = UUID(uuidString: "D3FA995B-2C9E-46EF-8D1E-AB1F6AEEFA84")!
        let json = """
        {"elements":[
          {"id":"\(first)","label":"Same","kind":"button","layout":{"centerX":0.2,"centerY":0.2},"output":{"keyboard":{"keyCode":49,"modifiersRawValue":0},"gamepadButtons":[]}},
          {"id":"\(second)","label":"Same","kind":"button","layout":{"centerX":0.8,"centerY":0.8},"output":{"keyboard":{"keyCode":48,"modifiersRawValue":0},"gamepadButtons":[]}}
        ]}
        """
        let source = try JSONDecoder().decode(GamepadCustomization.self, from: Data(json.utf8))
        XCTAssertTrue(source.customButtons.isEmpty)
        var moved = source
        moved.setPosition(CGPoint(x: 0.3, y: 0.4), for: .custom(first))
        moved = moved.normalized
        XCTAssertEqual(moved.elements.first(where: { $0.id == first })?.layout.centerX, 0.3)
        XCTAssertEqual(moved.elements.first(where: { $0.id == first })?.layout.centerY, 0.4)
        var aligned = source
        XCTAssertTrue(try aligned.alignControls([.custom(first), .custom(second)], alignment: .verticalCenters, in: CGSize(width: 874, height: 402)))
        let layouts = aligned.elements.map(\.layout)
        XCTAssertEqual(layouts[0].centerY, layouts[1].centerY)
        for customization in [moved, aligned] {
            XCTAssertEqual(Set(customization.elements.map(\.id)), [first, second])
            for original in source.elements {
                XCTAssertEqual(customization.elements.first(where: { $0.id == original.id })?.output, original.output)
            }
        }
    }

    func testStyleDeletionNeverInstallsUndeclaredStarterControls() {
        var customization = GamepadCustomization.blankCanvas
        var layout = GamepadButtonCustomization.defaultValue
        layout.styleID = "removed"
        customization.buttonCustomizations[.preset(5)] = layout
        customization.deleteReusableStyle(id: "removed")
        XCTAssertTrue(customization.elements.isEmpty)
    }

    func testStarterAppearanceUUIDMirrorsNeverRenderAsAdditionalControls() {
        let input = KeypadElementID.preset(5)
        var customization = GamepadCustomization.blankCanvas
        customization.buttonCustomizations.removeAll()
        customization.elements = [KeypadElement(id: input.uuid, label: "Owned", layout: .defaultValue)]
        customization.customButtons = [GamepadCustomButton(id: input.uuid, label: "Owned", layout: .defaultValue)]
        let controls = customization.normalized.resolvedControls(in: CGSize(width: 874, height: 402)).filter { $0.elementID == input.uuid }
        XCTAssertEqual(controls.count, 1)
        XCTAssertEqual(controls.first?.id, .builtin(input))
    }

    func testLifecycleCapacityUsesDeclarationsIncludingBuiltinAndColdSpecializedControls() throws {
        var dense = GamepadCustomization.blankCanvas
        dense.elements = [KeypadElement(id: KeypadElementID.preset(5).uuid, label: "Same", layout: .defaultValue)]
        dense.elements += (1..<128).map { ordinal in
            KeypadElement(id: UUID(uuidString: String(format: "407FAE83-287E-4DA2-934F-%012X", ordinal))!, label: "Same", layout: .defaultValue)
        }
        let originalIDs = dense.elements.map(\.id)
        XCTAssertThrowsError(try dense.duplicateControls([.builtin(.preset(5))]))
        XCTAssertEqual(dense.elements.map(\.id), originalIDs)
        XCTAssertThrowsError(try dense.addStandaloneCustomControl(GamepadCustomButton(label: "Too many", layout: .defaultValue)))
        XCTAssertEqual(dense.elements.map(\.id), originalIDs)

        var cold = GamepadCustomization.blankCanvas
        let trackpadID = UUID(uuidString: "60571208-0300-4210-A92F-1CC91F0F8043")!
        cold.elements = [KeypadElement(id: trackpadID, label: "Same", kind: .trackpad, layout: .defaultValue)]
        XCTAssertTrue(cold.customButtons.isEmpty)
        XCTAssertThrowsError(try cold.addStandaloneCustomControl(GamepadCustomButton(label: "Second", layout: .defaultValue, controlKind: .trackpad)))
        XCTAssertEqual(cold.elements.map(\.id), [trackpadID])
    }

    func testDirectAuthoringCountsDeclaredControlsAndNeverReusesUUIDs() throws {
        typealias AddControl = (inout GamepadCustomization, UUID) -> Void
        let authors: [(GamepadCustomControlKind, AddControl)] = [
            (.button, { $0.addCustomButton(id: $1) }),
            (.joystick, { $0.addJoystick(id: $1) }),
            (.trigger, { $0.addTrigger(id: $1) }),
            (.trackpad, { $0.addTrackpad(id: $1) }),
            (.text, { $0.addText(id: $1) }),
            (.decoration, { $0.addDecoration(id: $1) })
        ]
        let freshID = UUID(uuidString: "5FDD8C01-A9C7-4A86-A52E-105B606FA1F8")!
        var dense = GamepadCustomization.blankCanvas
        dense.elements = (0..<128).map { ordinal in
            KeypadElement(id: UUID(uuidString: String(format: "5861D929-21DB-48AD-931D-%012X", ordinal))!, label: "Same", layout: .defaultValue)
        }
        XCTAssertTrue(dense.customButtons.isEmpty)
        for (kind, author) in authors {
            var candidate = dense
            author(&candidate, freshID)
            XCTAssertEqual(candidate, dense, kind.rawValue)
        }
        var defaults = dense
        defaults.installDefaultControls()
        XCTAssertEqual(defaults, dense)
        defaults.setButtonCustomization(.defaultValue, for: .preset(5))
        XCTAssertEqual(defaults, dense)
        let normalizedDense = dense.normalized
        var repaired = normalizedDense
        XCTAssertFalse(repaired.applyLayoutRepair(.showDefaultControls).didChange)
        XCTAssertEqual(repaired, normalizedDense)

        for (kind, limit) in [(GamepadCustomControlKind.joystick, 2), (.trigger, 2), (.trackpad, 1)] {
            var cold = GamepadCustomization.blankCanvas
            cold.elements = dense.elements.prefix(limit).map { element in
                var element = element
                element.kind = kind
                return element
            }
            let author = try XCTUnwrap(authors.first(where: { $0.0 == kind })?.1)
            var candidate = cold
            author(&candidate, freshID)
            XCTAssertEqual(candidate, cold, kind.rawValue)
        }

        var owned = GamepadCustomization.blankCanvas
        owned.elements = [KeypadElement(
            id: freshID, label: "Owned", layout: .defaultValue,
            output: KeypadElementOutputBinding(keyboard: KeypadKeyboardBinding(keyCode: 49, modifiersRawValue: 8), gamepadButtons: [.south]),
            defaultOutput: KeypadElementOutputBinding(keyboard: KeypadKeyboardBinding(keyCode: 48, modifiersRawValue: 0), gamepadButtons: [.east])
        )]
        for (kind, author) in authors {
            var candidate = owned
            author(&candidate, freshID)
            XCTAssertEqual(candidate, owned, kind.rawValue)
        }

        // The same appearance mirror and declaration count once, not twice.
        var almostFull = dense
        almostFull.elements.removeLast()
        almostFull.customButtons = [GamepadCustomButton(id: almostFull.elements[0].id, label: "Same", layout: .defaultValue)]
        almostFull.addCustomButton(id: freshID)
        XCTAssertEqual(almostFull.elements.count, 128)
        XCTAssertNotNil(almostFull.elements.first(where: { $0.id == freshID }))
        XCTAssertNoThrow(try JSONDecoder().decode(GamepadCustomization.self, from: JSONEncoder().encode(almostFull)))
    }

    func testNonButtonStarterUUIDsStayCustomInDesignOrderAndDuplication() throws {
        let sourceID = KeypadElementID.preset(5).uuid
        let siblingID = UUID(uuidString: "035BB3C9-50F7-41A7-A688-767241AC45A9")!
        let copyID = UUID(uuidString: "CB9B11BE-7149-43F7-BAA1-EBB44D491697")!
        for kind in GamepadCustomControlKind.allCases where kind != .button {
            var customization = GamepadCustomization.blankCanvas
            customization.elements = [
                KeypadElement(id: sourceID, label: "Same", kind: kind, layout: .defaultValue),
                KeypadElement(id: siblingID, label: "Same", layout: .defaultValue)
            ]
            customization = customization.normalized
            XCTAssertTrue(customization.allControlIdentitiesForDesign.contains(.custom(sourceID)), kind.rawValue)
            XCTAssertFalse(customization.allControlIdentitiesForDesign.contains(.builtin(.preset(5))), kind.rawValue)
            if kind == .trackpad { continue } // The one-trackpad capacity bound is intentional.
            _ = try customization.duplicateControls([.custom(sourceID)], newElementIDs: [copyID])
            let order = customization.orderedControlIdentitiesForDesign
            let sourceIndex = try XCTUnwrap(order.firstIndex(of: .custom(sourceID)), kind.rawValue)
            XCTAssertEqual(order[sourceIndex + 1], .custom(copyID), kind.rawValue)
            XCTAssertEqual(customization.elements.first(where: { $0.id == copyID })?.kind, kind)
        }
    }

    func testOptionArrowNudgeRoutesWhileTextFieldHasFocus() {
        let expectedDirections: [(UInt16, GamepadEditorNudgeDirection)] = [
            (123, .left),
            (124, .right),
            (125, .down),
            (126, .up)
        ]

        for (keyCode, expectedDirection) in expectedDirections {
            XCTAssertEqual(
                GamepadEditorKeyboardShortcutRouting.nudgeDirection(
                    keyCode: keyCode,
                    modifierFlags: .option
                ),
                expectedDirection
            )
            XCTAssertTrue(
                GamepadEditorKeyboardShortcutRouting.routesNudgeDuringTextEditing(
                    keyCode: keyCode,
                    modifierFlags: .option
                )
            )
            XCTAssertTrue(
                GamepadEditorKeyboardShortcutRouting.routesNudgeDuringTextEditing(
                    keyCode: keyCode,
                    modifierFlags: [.option, .shift]
                )
            )
        }
    }

    func testTextEditingOnlyYieldsOptionArrowToElementNudging() {
        XCTAssertFalse(
            GamepadEditorKeyboardShortcutRouting.routesNudgeDuringTextEditing(
                keyCode: 123,
                modifierFlags: []
            )
        )
        XCTAssertFalse(
            GamepadEditorKeyboardShortcutRouting.routesNudgeDuringTextEditing(
                keyCode: 123,
                modifierFlags: [.option, .command]
            )
        )
        XCTAssertFalse(
            GamepadEditorKeyboardShortcutRouting.routesNudgeDuringTextEditing(
                keyCode: 0,
                modifierFlags: .option
            )
        )
    }

    func testCommandBExclusivelyRoutesQuickBind() {
        XCTAssertTrue(
            GamepadEditorKeyboardShortcutRouting.isQuickBindShortcut(
                charactersIgnoringModifiers: "b",
                modifierFlags: .command,
                isRepeat: false
            )
        )
        XCTAssertFalse(
            GamepadEditorKeyboardShortcutRouting.isQuickBindShortcut(
                charactersIgnoringModifiers: "b",
                modifierFlags: [.command, .shift],
                isRepeat: false
            )
        )
        XCTAssertFalse(
            GamepadEditorKeyboardShortcutRouting.isQuickBindShortcut(
                charactersIgnoringModifiers: "b",
                modifierFlags: .command,
                isRepeat: true
            )
        )
        XCTAssertFalse(
            GamepadEditorKeyboardShortcutRouting.isQuickBindShortcut(
                charactersIgnoringModifiers: "d",
                modifierFlags: .command,
                isRepeat: false
            )
        )
    }

    func testSharedControlBarAppearancePatchRequiresMembershipAndUsesCanonicalNormalization() throws {
        var customization = GamepadCustomization.defaultValue
        customization.controlBarItems = [.settings, .spacer]
        var patch = GamepadControlBarAppearancePatch(
            existing: customization.controlBarItemCustomization(for: .settings)
        )
        patch.appearance.widthScale = 1.5
        patch.appearance.heightScale = 1.2
        patch.appearance.centerX = 0.7
        patch.appearance.rotationDegrees = 45
        patch.appearance.zIndex = 10
        patch.appearance.isLocationLocked = true
        patch.appearance.icon = .text("S")
        try customization.applyControlBarAppearancePatch(patch, for: .settings)
        let result = customization.controlBarItemCustomization(for: .settings)
        XCTAssertEqual(result.widthScale, 1.5)
        XCTAssertEqual(result.heightScale, 1.2)
        XCTAssertNil(result.centerX)
        XCTAssertEqual(result.rotationDegrees, 0)
        XCTAssertEqual(result.zIndex, 0)
        XCTAssertFalse(result.isLocationLocked)
        XCTAssertEqual(result.icon?.value, "S")

        var spacerPatch = GamepadControlBarAppearancePatch(
            existing: customization.controlBarItemCustomization(for: .spacer)
        )
        spacerPatch.appearance.widthScale = 2
        spacerPatch.appearance.heightScale = 3
        spacerPatch.appearance.shape = .circle
        spacerPatch.appearance.isHidden = true
        try customization.applyControlBarAppearancePatch(spacerPatch, for: .spacer)
        let spacer = customization.controlBarItemCustomization(for: .spacer)
        XCTAssertEqual(spacer.widthScale, 2)
        XCTAssertEqual(spacer.heightScale, 1)
        XCTAssertNil(spacer.shape)
        XCTAssertTrue(spacer.isHidden)

        XCTAssertThrowsError(try customization.applyControlBarAppearancePatch(patch, for: .home)) { error in
            XCTAssertEqual(error as? GamepadControlBarAppearancePatchError, .itemNotPresent)
        }
    }

    func testStableControlIdentityParsesEveryExistingIDShape() {
        let customID = UUID(uuidString: "00000000-0000-0000-0000-00000000CAFE")!
        let identities: [GamepadControlIdentity] = [
            .builtin(.preset(5)),
            .custom(customID),
            .system(.topBarActivation),
            .controlBarItem(.settings)
        ]

        for identity in identities {
            XCTAssertEqual(GamepadControlIdentity(stableID: identity.id), identity)
        }
        XCTAssertNil(GamepadControlIdentity(stableID: "jump"))
        XCTAssertEqual(GamepadControlIdentity(stableID: KeypadElementID.preset(5).rawValue), .builtin(.preset(5)))
        XCTAssertEqual(GamepadControlIdentity(stableID: customID.uuidString), .custom(customID))
        XCTAssertNil(GamepadControlIdentity(stableID: "custom.not-a-uuid"))
    }

    func testDuplicateBuiltInCreatesEquivalentCustomControlWithClonedOutput() throws {
        var customization = GamepadCustomization.defaultValue.normalized
        var jumpLayout = customization.buttonCustomization(for: .preset(5))
        jumpLayout.centerX = 0.72
        jumpLayout.centerY = 0.66
        jumpLayout.fillColor = GamepadRGBAColor(hexString: "#112233")
        customization.setButtonCustomization(jumpLayout, for: .preset(5))

        let sourceID = try XCTUnwrap(customization.elementID(for: .builtin(.preset(5))))
        let sourceIndex = try XCTUnwrap(customization.elements.firstIndex(where: { $0.id == sourceID }))
        let primary = KeypadElementOutputBinding(
            keyboard: KeypadKeyboardBinding(keyCode: 49),
            gamepadButtons: [.south]
        )
        let alternate = KeypadElementOutputBinding(keyboard: KeypadKeyboardBinding(keyCode: 36))
        customization.elements[sourceIndex].setOutputBinding(primary)
        customization.elements[sourceIndex].setOutputBinding(alternate, for: .joystickUp)

        let result = try customization.duplicateControls(
            [.builtin(.preset(5))],
            normalizedOffset: CGSize(width: 0.04, height: -0.03),
            canvasSize: CGSize(width: 874, height: 402)
        )
        let duplicateIdentity = try XCTUnwrap(result.identityMap[.builtin(.preset(5))])
        guard case .custom(let duplicateID) = duplicateIdentity else {
            return XCTFail("built-in duplicate should be custom")
        }
        let duplicate = try XCTUnwrap(customization.customButtons.first(where: { $0.id == duplicateID }))
        XCTAssertEqual(duplicate.inputID, KeypadElementID(duplicateID))
        XCTAssertNotEqual(duplicate.inputID, .preset(5))
        XCTAssertEqual(duplicate.label, customization.visualLabel(for: .preset(5)))
        XCTAssertEqual(try XCTUnwrap(duplicate.layout.centerX), CGFloat(0.76), accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(duplicate.layout.centerY), CGFloat(0.63), accuracy: 0.001)
        XCTAssertEqual(duplicate.layout.fillColor, GamepadRGBAColor(hexString: "#112233")?.normalized)

        let duplicateElement = try XCTUnwrap(customization.element(for: duplicateIdentity))
        XCTAssertEqual(duplicateElement.outputBinding(), primary)
        XCTAssertEqual(duplicateElement.outputBinding(for: .joystickUp), alternate)
    }

    func testDuplicateCustomPreservesSpecializedSettingsAndLayerPlacement() throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-00000000A001")!
        var customization = GamepadCustomization.blankCanvas
        customization.addJoystick(
            id: id,
            label: "Aim",
            mapping: .secondary,
            outputSettings: .analogRightStick
        )
        customization.designMetadata = GamepadDesignMetadata(layerOrder: [.custom(id)])

        let result = try customization.duplicateControls([.custom(id)])
        guard case .custom(let duplicateID) = try XCTUnwrap(result.identityMap[.custom(id)]) else {
            return XCTFail("custom duplicate should remain custom")
        }
        let duplicate = try XCTUnwrap(customization.customButtons.first(where: { $0.id == duplicateID }))
        XCTAssertEqual(duplicate.controlKind, .joystick)
        XCTAssertEqual(duplicate.joystickMapping, .secondary)
        XCTAssertEqual(duplicate.joystickOutputSettings, .analogRightStick.normalized)
        let order = customization.orderedControlIdentitiesForDesign
        XCTAssertEqual(order.firstIndex(of: .custom(duplicateID)), (order.firstIndex(of: .custom(id)) ?? -2) + 1)
    }

    func testOrientationCopyPreservesBothVariantsAndNonLayoutProfileData() throws {
        let launchTarget = GamepadProfileLaunchTarget(
            displayName: "Example",
            bundleIdentifier: "com.example.game"
        )
        var landscape = GamepadCustomization.blankCanvas
        landscape.colorSchemePreference = .dark
        landscape.accentStyle = .purple
        landscape.styleLibrary = GamepadStyleLibrary(styles: [
            GamepadStyleToken(
                id: "shared",
                name: "Shared",
                visualStyle: GamepadControlVisualStyle(normal: GamepadControlStateStyle(opacity: 0.8))
            )
        ])
        landscape.addCustomButton(id: UUID(uuidString: "00000000-0000-0000-0000-00000000B001")!)
        landscape.customButtons[0].layout.centerX = 0.8
        landscape.customButtons[0].layout.centerY = 0.25
        landscape.deviceCanvas = GamepadDeviceCanvas(frameID: "iphone-17-pro-landscape")

        var profile = GamepadConfigurationProfile(
            name: "Variants",
            customization: landscape,
            outputMode: .controller,
            launchTarget: launchTarget
        )
        profile.copyLayoutVariant(from: .landscape, to: .portrait)

        let savedLandscape = try XCTUnwrap(profile.landscapeCustomization)
        let savedPortrait = try XCTUnwrap(profile.portraitCustomization)
        XCTAssertEqual(savedLandscape.deviceCanvas.editorDeviceFrame.orientation, .landscape)
        XCTAssertEqual(savedPortrait.deviceCanvas.editorDeviceFrame.orientation, .portrait)
        XCTAssertEqual(try XCTUnwrap(savedLandscape.customButtons[0].layout.centerX), CGFloat(0.8), accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(savedLandscape.customButtons[0].layout.centerY), CGFloat(0.25), accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(savedPortrait.customButtons[0].layout.centerX), CGFloat(0.25), accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(savedPortrait.customButtons[0].layout.centerY), CGFloat(0.2), accuracy: 0.001)
        XCTAssertEqual(savedPortrait.accentStyle, .purple)
        XCTAssertEqual(savedPortrait.styleLibrary, savedLandscape.styleLibrary)
        XCTAssertEqual(profile.outputMode, .controller)
        XCTAssertEqual(profile.launchTarget?.bundleIdentifier, "com.example.game")
    }

    func testOrientationCopyIgnoresMissingSourceVariant() {
        var landscape = GamepadCustomization.blankCanvas
        landscape.deviceCanvas = GamepadDeviceCanvas(frameID: "iphone-17-pro-landscape")
        var profile = GamepadConfigurationProfile(name: "Landscape Only", customization: landscape)
        let original = profile

        profile.copyLayoutVariant(from: .portrait, to: .landscape)

        XCTAssertEqual(profile, original)
        XCTAssertNil(profile.portraitCustomization)
    }

    func testSetCustomizationCorrectsVariantFrameOrientation() {
        var profile = GamepadConfigurationProfile(name: "Variants", customization: .blankCanvas)
        var landscapeFramedCustomization = GamepadCustomization.blankCanvas
        landscapeFramedCustomization.deviceCanvas = GamepadDeviceCanvas(frameID: "iphone-17-pro-landscape")

        profile.setCustomization(landscapeFramedCustomization, for: .portrait)

        XCTAssertEqual(profile.portraitCustomization?.deviceCanvas.editorDeviceFrame.orientation, .portrait)
        XCTAssertEqual(profile.portraitCustomization?.deviceCanvas.editorDeviceFrame.spec.id, "iphone-17-pro")
    }

    func testSharedAlignAndDistributeOperationsUseExplicitModes() throws {
        let ids = (1...3).map { index in
            UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", 0xC000 + index))!
        }
        var customization = GamepadCustomization.blankCanvas
        customization.customButtons = zip(ids, [0.2, 0.45, 0.8]).map { id, x in
            GamepadCustomButton(
                id: id,
                label: "Key",
                layout: GamepadButtonCustomization(centerX: x, centerY: 0.2 + x / 2, shape: .rectangle)
            )
        }
        let canvas = CGSize(width: 600, height: 300)
        let identities = Set(ids.map(GamepadControlIdentity.custom))

        XCTAssertTrue(try customization.alignControls(identities, alignment: .topEdges, in: canvas))
        let aligned = customization.resolvedControls(in: canvas).filter { identities.contains($0.id) }
        XCTAssertEqual(Set(aligned.map { Int($0.frame.minY.rounded()) }).count, 1)

        customization.customButtons[1].layout.centerX = 0.3
        XCTAssertTrue(try customization.distributeControls(identities, distribution: .horizontalCenters, in: canvas))
        let distributed = customization.resolvedControls(in: canvas)
            .filter { identities.contains($0.id) }
            .sorted { $0.center.x < $1.center.x }
        XCTAssertEqual(distributed[1].center.x - distributed[0].center.x, distributed[2].center.x - distributed[1].center.x, accuracy: 0.001)
    }

    func testMinimumTouchTargetRepairGrowsOnlyAffectedUnlockedControls() throws {
        let smallID = UUID(uuidString: "00000000-0000-0000-0000-00000000E001")!
        let lockedID = UUID(uuidString: "00000000-0000-0000-0000-00000000E002")!
        var customization = GamepadCustomization.blankCanvas
        customization.addCustomButton(id: smallID)
        customization.addCustomButton(id: lockedID)
        customization.customButtons[0].layout.widthScale = 0.2
        customization.customButtons[0].layout.heightScale = 0.2
        customization.customButtons[1].layout.widthScale = 0.2
        customization.customButtons[1].layout.heightScale = 0.2
        customization.customButtons[1].layout.isLocationLocked = true
        let canvas = CGSize(width: 600, height: 300)
        let issue = GamepadLayoutIssue(
            severity: .warning,
            code: "small-control",
            message: "Small controls",
            controls: [GamepadControlIdentity.custom(smallID).id, GamepadControlIdentity.custom(lockedID).id],
            metric: 20
        )

        let result = customization.applyLayoutRepair(.minimumTouchTarget, issue: issue, canvasSize: canvas)
        let repaired = try XCTUnwrap(customization.resolvedControls(in: canvas).first { $0.id == .custom(smallID) })
        let locked = try XCTUnwrap(customization.resolvedControls(in: canvas).first { $0.id == .custom(lockedID) })

        XCTAssertGreaterThanOrEqual(repaired.size.width, 43.9)
        XCTAssertGreaterThanOrEqual(repaired.size.height, 43.9)
        XCTAssertLessThan(locked.size.width, 44)
        XCTAssertTrue(result.changedControlIDs.contains(GamepadControlIdentity.custom(smallID).id))
        XCTAssertTrue(result.skippedLockedControlIDs.contains(GamepadControlIdentity.custom(lockedID).id))
    }

    func testEdgeRepairMovesControlToComfortableInset() throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-00000000E003")!
        var customization = GamepadCustomization.blankCanvas
        customization.addCustomButton(id: id)
        customization.customButtons[0].layout.centerX = 0
        customization.customButtons[0].layout.centerY = 0
        let canvas = CGSize(width: 600, height: 300)
        let issue = GamepadLayoutIssue(
            severity: .warning,
            code: "edge-hugging-control",
            message: "Edge",
            controls: [GamepadControlIdentity.custom(id).id],
            metric: nil
        )

        let result = customization.applyLayoutRepair(.moveInsideSafeArea, issue: issue, canvasSize: canvas)
        let repaired = try XCTUnwrap(customization.resolvedControls(in: canvas).first { $0.id == .custom(id) })

        XCTAssertGreaterThan(repaired.frame.minX, 1)
        XCTAssertGreaterThan(repaired.frame.minY, 1)
        XCTAssertTrue(result.didChange)
    }

    func testOverlapRepairSeparatesSecondControl() throws {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-00000000E004")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-00000000E005")!
        var customization = GamepadCustomization.blankCanvas
        customization.addCustomButton(id: firstID)
        customization.addCustomButton(id: secondID)
        customization.customButtons[0].layout.centerX = 0.5
        customization.customButtons[0].layout.centerY = 0.5
        customization.customButtons[1].layout.centerX = 0.5
        customization.customButtons[1].layout.centerY = 0.5
        let canvas = CGSize(width: 600, height: 300)
        let issue = GamepadLayoutIssue(
            severity: .warning,
            code: "control-overlap",
            message: "Overlap",
            controls: [GamepadControlIdentity.custom(firstID).id, GamepadControlIdentity.custom(secondID).id],
            metric: 1
        )

        let result = customization.applyLayoutRepair(.resolveOverlap, issue: issue, canvasSize: canvas)
        let controls = customization.resolvedControls(in: canvas).filter { $0.id == .custom(firstID) || $0.id == .custom(secondID) }

        XCTAssertEqual(controls.count, 2)
        XCTAssertFalse(controls[0].frame.intersects(controls[1].frame))
        XCTAssertTrue(result.changedControlIDs.contains(GamepadControlIdentity.custom(secondID).id))
    }

    func testOverlapRepairMovesUnlockedControlAroundLockedPeer() throws {
        let unlockedID = UUID(uuidString: "00000000-0000-0000-0000-00000000E006")!
        let lockedID = UUID(uuidString: "00000000-0000-0000-0000-00000000E007")!
        var customization = GamepadCustomization.blankCanvas
        customization.addCustomButton(id: unlockedID)
        customization.addCustomButton(id: lockedID)
        customization.customButtons[0].layout.centerX = 0.5
        customization.customButtons[0].layout.centerY = 0.5
        customization.customButtons[1].layout.centerX = 0.5
        customization.customButtons[1].layout.centerY = 0.5
        customization.customButtons[1].layout.isLocationLocked = true
        let canvas = CGSize(width: 600, height: 300)
        let issue = GamepadLayoutIssue(
            severity: .warning,
            code: "control-overlap",
            message: "Overlap",
            controls: [GamepadControlIdentity.custom(unlockedID).id, GamepadControlIdentity.custom(lockedID).id],
            metric: 1
        )

        let result = customization.applyLayoutRepair(.resolveOverlap, issue: issue, canvasSize: canvas)
        let unlocked = try XCTUnwrap(customization.resolvedControls(in: canvas).first { $0.id == .custom(unlockedID) })
        let locked = try XCTUnwrap(customization.resolvedControls(in: canvas).first { $0.id == .custom(lockedID) })

        XCTAssertFalse(unlocked.frame.intersects(locked.frame))
        XCTAssertTrue(result.changedControlIDs.contains(GamepadControlIdentity.custom(unlockedID).id))
        XCTAssertTrue(result.skippedLockedControlIDs.contains(GamepadControlIdentity.custom(lockedID).id))
    }

    func testCustomizationFixSharedAPIMatchesCheckedInSwiftGoldens() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../Host/crates/thumble-host/tests/fixtures/customization-fix-v1.json")
            .standardizedFileURL
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any]
        )
        XCTAssertEqual(root["schema"] as? String, "com.codybontecou.thumble.customization-fix-goldens")
        let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 12)

        for fixture in cases {
            let name = fixture["name"] as? String ?? "unnamed"
            let beforeData = try JSONSerialization.data(withJSONObject: try XCTUnwrap(fixture["before"]))
            var customization = try JSONDecoder().decode(GamepadCustomization.self, from: beforeData)
            let targetObject = try XCTUnwrap(fixture["target"] as? [String: Any])
            let target: GamepadLayoutRepairTarget
            if targetObject["kind"] as? String == "all" {
                target = .all
            } else {
                let rawRepair = try XCTUnwrap(targetObject["repair"] as? String)
                target = .repair(try XCTUnwrap(GamepadLayoutRepairKind(rawValue: rawRepair)))
            }
            let canvasObject = try XCTUnwrap(fixture["canvas"] as? [String: Any])
            let canvasSize: CGSize?
            switch canvasObject["source"] as? String {
            case "stored":
                canvasSize = nil
            case "frame":
                let frameID = try XCTUnwrap(canvasObject["frameID"] as? String)
                canvasSize = try XCTUnwrap(GamepadEditorDeviceCatalog.frames.first { $0.id == frameID }).screenRect.size
            case "size":
                canvasSize = CGSize(
                    width: try XCTUnwrap(canvasObject["width"] as? Double),
                    height: try XCTUnwrap(canvasObject["height"] as? Double)
                )
            default:
                return XCTFail("Unknown canvas in \(name)")
            }
            let includeLocked = try XCTUnwrap(fixture["includeLocked"] as? Bool)
            _ = customization.applyLayoutRepairs(
                target: target,
                canvasSize: canvasSize,
                respectingLocks: !includeLocked
            )

            let actual = try JSONSerialization.jsonObject(with: JSONEncoder().encode(customization.normalized))
            let expected = try XCTUnwrap(fixture["after"])
            XCTAssertTrue(
                jsonSemanticallyEqual(actual, expected),
                "Swift golden mismatch beyond numeric tolerance: \(name)"
            )
        }
    }

    func testGroupRenameAndDuplicateCloneChildrenAndOutputs() throws {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-00000000D001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-00000000D002")!
        let groupID = UUID(uuidString: "00000000-0000-0000-0000-00000000D100")!
        var customization = GamepadCustomization.blankCanvas
        customization.addCustomButton(id: firstID)
        customization.addCustomButton(id: secondID)
        customization = customization.normalized
        let elementIndex = try XCTUnwrap(customization.elements.firstIndex(where: { $0.id == firstID }))
        customization.elements[elementIndex].setOutputBinding(
            KeypadElementOutputBinding(keyboard: KeypadKeyboardBinding(keyCode: 49))
        )
        customization.designMetadata = GamepadDesignMetadata(
            layerOrder: [.custom(firstID), .custom(secondID)],
            groups: [GamepadLayerGroup(id: groupID, name: "Old", children: [.custom(firstID), .custom(secondID)])]
        )

        let renamed = try customization.renameLayerGroup(id: groupID, to: "Actions")
        XCTAssertEqual(renamed.name, "Actions")
        let duplicate = try customization.duplicateLayerGroup(id: groupID, name: "Actions Copy")
        XCTAssertEqual(duplicate.group.name, "Actions Copy")
        XCTAssertEqual(duplicate.group.children.count, 2)
        XCTAssertEqual(customization.designMetadata?.groups.count, 2)

        let duplicatedFirst = try XCTUnwrap(duplicate.elements.identityMap[.custom(firstID)])
        XCTAssertEqual(
            customization.element(for: duplicatedFirst)?.outputBinding(),
            KeypadElementOutputBinding(keyboard: KeypadKeyboardBinding(keyCode: 49))
        )
    }
}
