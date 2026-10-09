import CoreGraphics
import XCTest

final class GamepadLayoutQualityErgonomicsTests: XCTestCase {
    private let landscape = CGSize(width: 400, height: 200)
    private let portrait = CGSize(width: 300, height: 600)

    func testArbitraryUUIDsDoNotInheritObsoleteSlotArrangementPriority() throws {
        let firstID = uuid(32)
        let oldLookingID = KeypadElementID.preset(11).uuid
        var customization = makeCustomization([
            button(oldLookingID, .preset(5), x: 0.5, y: 0.5),
            button(firstID, .preset(5), x: 0.5, y: 0.5)
        ])
        XCTAssertTrue(customization.ergonomicallyAutoArrange(in: landscape))
        let controls = customization.resolvedControls(in: landscape)
        let first = try XCTUnwrap(controls.first { $0.elementID == firstID })
        let second = try XCTUnwrap(controls.first { $0.elementID == oldLookingID })
        XCTAssertGreaterThan(first.center.y, second.center.y, "Independent UUID ordering must place the first control in the first action position")
    }

    func testExpandedRuntimeHitOverlapIsDistinctFromVisualOverlapAndRepairable() throws {
        let firstID = uuid(1)
        let secondID = uuid(2)
        var customization = makeCustomization([
            button(firstID, .preset(11), x: 0.30, y: 0.72),
            button(secondID, .preset(12), x: 0.70, y: 0.72)
        ])
        let preliminary = customization.resolvedControls(in: landscape).sorted { $0.id.id < $1.id.id }
        let width = try XCTUnwrap(preliminary.first?.frame.width)
        let visualGap: CGFloat = 12
        let join = landscape.width / 2
        customization.customButtons[0].layout.centerX = (join - visualGap / 2 - width / 2) / landscape.width
        customization.customButtons[1].layout.centerX = (join + visualGap / 2 + width / 2) / landscape.width

        let report = customization.layoutQualityReport(canvasSize: landscape)
        let hitIssue = try XCTUnwrap(report.issues.first { $0.code == "expanded-hit-overlap" })
        XCTAssertFalse(report.issues.contains { $0.code == "control-overlap" })
        XCTAssertEqual(hitIssue.controls, ["custom.\(firstID.uuidString)", "custom.\(secondID.uuidString)"])
        XCTAssertGreaterThan(try XCTUnwrap(hitIssue.metric), 0)
        XCTAssertEqual(hitIssue.suggestedRepairs.first, .separateExpandedHitTargets)
        XCTAssertNotNil(report.controls.first?.expandedHitFrame)

        XCTAssertTrue(customization.separateExpandedHitTargets(in: landscape))
        XCTAssertFalse(customization.layoutQualityReport(canvasSize: landscape).issues.contains { $0.code == "expanded-hit-overlap" })
    }

    func testVisualOverlapKeepsExistingCodeAndReportsZOrderMismatch() {
        let backID = uuid(10)
        let frontID = uuid(11)
        var back = button(backID, .preset(11), x: 0.5, y: 0.6, scale: 0.65)
        var front = button(frontID, .preset(12), x: 0.5, y: 0.6, scale: 1.25)
        back.layout.zIndex = 0
        front.layout.zIndex = 20
        let customization = makeCustomization([back, front], order: [.custom(backID), .custom(frontID)])

        let report = customization.layoutQualityReport(canvasSize: landscape)
        XCTAssertTrue(report.issues.contains { $0.code == "control-overlap" })
        XCTAssertTrue(report.issues.contains { $0.code == "hit-region-z-order-mismatch" })
        XCTAssertFalse(report.issues.contains { $0.code == "expanded-hit-overlap" })
    }

    func testEqualAreaOverlappingTargetsReportDeterministicZOrderAmbiguity() {
        let backID = uuid(20)
        let frontID = uuid(21)
        var back = button(backID, .preset(11), x: 0.5, y: 0.7)
        var front = button(frontID, .preset(12), x: 0.5, y: 0.7)
        back.layout.zIndex = -1
        front.layout.zIndex = 1
        let customization = makeCustomization([back, front])

        let first = customization.layoutQualityReport(canvasSize: landscape)
        let second = customization.layoutQualityReport(canvasSize: landscape)
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.issues.contains { $0.code == "hit-region-z-order-ambiguous" })
        XCTAssertEqual(first.issues.map { "\($0.code):\($0.controls.joined(separator: ","))" }, first.issues.map { "\($0.code):\($0.controls.joined(separator: ","))" }.sorted())
    }

    func testUndeclaredButtonRolesDoNotAcquireImportanceFromLabels() {
        var button = button(uuid(29), .preset(5), x: 0.82, y: 0.10)
        button.visualRole = nil
        button.label = "Menu"
        let neutral = makeCustomization([button])
        let controls = neutral.normalized.resolvedControls(in: landscape)
        XCTAssertEqual(controls.first?.visualRole, .custom)
        XCTAssertFalse(neutral.layoutQualityReport(canvasSize: landscape).issues.contains { $0.code.hasPrefix("primary-control-") })
        button.label = "Strike"
        XCTAssertFalse(makeCustomization([button]).layoutQualityReport(canvasSize: landscape).issues.contains { $0.code.hasPrefix("primary-control-") })
        button.visualRole = .primaryAction
        XCTAssertTrue(makeCustomization([button]).layoutQualityReport(canvasSize: landscape).issues.contains { $0.code == "primary-control-too-high" })
    }

    func testLandscapeThumbReachFlagsTopCentralAndOppositeSidePrimaryControls() {
        let customization = makeCustomization([
            button(uuid(30), .preset(5), x: 0.82, y: 0.10),
            button(uuid(31), .preset(6), x: 0.50, y: 0.55),
            button(uuid(32), .preset(3), role: .movement, x: 0.92, y: 0.68)
        ])
        let report = customization.layoutQualityReport(canvasSize: landscape)

        XCTAssertTrue(report.issues.contains { $0.code == "primary-control-too-high" && $0.controls == ["custom.\(uuid(30).uuidString)"] })
        XCTAssertTrue(report.issues.contains { $0.code == "primary-control-too-central" && $0.controls == ["custom.\(uuid(31).uuidString)"] })
        XCTAssertTrue(report.issues.contains { $0.code == "primary-control-out-of-reach" && $0.controls == ["custom.\(uuid(32).uuidString)"] })
        XCTAssertTrue(report.issues.contains { $0.suggestedRepairs.contains(.ergonomicAutoArrange) })
    }

    func testPortraitDeadSpaceAndUnbalancedPrimaryDistributionAreReported() {
        let customization = makeCustomization([
            button(uuid(40), .preset(9), role: .utility, x: 0.25, y: 0.08, scale: 0.55),
            button(uuid(41), .preset(10), role: .menu, x: 0.75, y: 0.08, scale: 0.55),
            button(uuid(42), .preset(5), x: 0.70, y: 0.72, scale: 0.55),
            button(uuid(43), .preset(6), x: 0.84, y: 0.72, scale: 0.55),
            button(uuid(44), .preset(7), x: 0.70, y: 0.86, scale: 0.55),
            button(uuid(45), .preset(8), x: 0.84, y: 0.86, scale: 0.55)
        ])
        let report = customization.layoutQualityReport(canvasSize: portrait)

        XCTAssertTrue(report.issues.contains { $0.code == "portrait-dead-space" })
        XCTAssertTrue(report.issues.contains { $0.code == "portrait-primary-action-distribution" })
    }

    func testReasonableLayoutsAvoidErgonomicFalsePositivesIncludingSpecializedControls() {
        let simpleReasonableLayout = makeCustomization([
            button(uuid(48), .preset(3), role: .movement, x: 0.18, y: 0.68, scale: 0.90),
            button(uuid(49), .preset(5), x: 0.82, y: 0.68, scale: 0.90)
        ])
        let simpleReport = simpleReasonableLayout.layoutQualityReport(canvasSize: landscape)
        XCTAssertTrue(simpleReport.issues.isEmpty, "Reasonable two-thumb layout issues: \(simpleReport.issues)")

        var landscapeCustomization = makeCustomization([
            button(uuid(50), .preset(1), role: .movement, x: 0.18, y: 0.52, scale: 0.55),
            button(uuid(51), .preset(3), role: .movement, x: 0.11, y: 0.68, scale: 0.55),
            button(uuid(52), .preset(4), role: .movement, x: 0.25, y: 0.68, scale: 0.55),
            button(uuid(53), .preset(2), role: .movement, x: 0.18, y: 0.84, scale: 0.55),
            button(uuid(54), .preset(5), x: 0.82, y: 0.84, scale: 0.55),
            button(uuid(55), .preset(6), x: 0.75, y: 0.68, scale: 0.55),
            button(uuid(56), .preset(7), x: 0.89, y: 0.68, scale: 0.55),
            button(uuid(57), .preset(8), x: 0.82, y: 0.52, scale: 0.55),
            button(uuid(58), .preset(9), role: .utility, x: 0.5, y: 0.10, scale: 0.45)
        ])
        landscapeCustomization.addJoystick(id: uuid(59), label: "Stick", mapping: .movement)
        let joystickIndex = landscapeCustomization.customButtons.count - 1
        landscapeCustomization.customButtons[joystickIndex].layout.centerX = 0.5
        landscapeCustomization.customButtons[joystickIndex].layout.centerY = 0.12
        landscapeCustomization.addTrackpad(id: uuid(60))
        let trackpadIndex = landscapeCustomization.customButtons.count - 1
        landscapeCustomization.customButtons[trackpadIndex].layout.centerX = 0.5
        landscapeCustomization.customButtons[trackpadIndex].layout.centerY = 0.35

        let landscapeReport = landscapeCustomization.layoutQualityReport(canvasSize: landscape)
        XCTAssertFalse(landscapeReport.issues.contains { $0.code.hasPrefix("primary-control-") })

        let portraitCustomization = makeCustomization([
            button(uuid(61), .preset(1), role: .movement, x: 0.27, y: 0.62, scale: 0.45),
            button(uuid(62), .preset(2), role: .movement, x: 0.27, y: 0.84, scale: 0.45),
            button(uuid(63), .preset(5), x: 0.73, y: 0.84, scale: 0.45),
            button(uuid(64), .preset(6), x: 0.73, y: 0.62, scale: 0.45)
        ])
        let portraitReport = portraitCustomization.layoutQualityReport(canvasSize: portrait)
        XCTAssertFalse(portraitReport.issues.contains { $0.code.hasPrefix("primary-control-") || $0.code == "portrait-primary-action-distribution" })
    }

    func testErgonomicRepairMovesPrimaryControlsButLeavesUtilitiesAndJoysticksAlone() throws {
        let actionID = uuid(65)
        let utilityID = uuid(66)
        let joystickID = uuid(67)
        var customization = makeCustomization([
            button(actionID, .preset(5), x: 0.5, y: 0.12, scale: 0.5),
            button(utilityID, .preset(9), role: .utility, x: 0.10, y: 0.12, scale: 0.5)
        ])
        customization.addJoystick(id: joystickID, label: "Aim", mapping: .secondary)
        let joystickIndex = customization.customButtons.count - 1
        customization.customButtons[joystickIndex].layout.centerX = 0.5
        customization.customButtons[joystickIndex].layout.centerY = 0.35
        let before = Dictionary(uniqueKeysWithValues: customization.resolvedControls(in: portrait).map { ($0.id, $0.center) })

        XCTAssertTrue(customization.ergonomicallyAutoArrange(in: portrait))
        let after = Dictionary(uniqueKeysWithValues: customization.resolvedControls(in: portrait).map { ($0.id, $0.center) })
        XCTAssertNotEqual(try XCTUnwrap(after[.custom(actionID)]), try XCTUnwrap(before[.custom(actionID)]))
        XCTAssertEqual(try XCTUnwrap(after[.custom(utilityID)]), try XCTUnwrap(before[.custom(utilityID)]))
        XCTAssertEqual(try XCTUnwrap(after[.custom(joystickID)]), try XCTUnwrap(before[.custom(joystickID)]))
        XCTAssertFalse(customization.layoutQualityReport(canvasSize: portrait).issues.contains {
            $0.code.hasPrefix("primary-control-") && $0.controls.contains("custom.\(actionID.uuidString)")
        })
    }

    func testSmallControlsAreReportedAndLockedControlsAreNeverMovedByRepairs() throws {
        let lockedID = uuid(70)
        let movableID = uuid(71)
        var locked = button(lockedID, .preset(11), x: 0.45, y: 0.72, scale: 0.30)
        locked.layout.isLocationLocked = true
        let movable = button(movableID, .preset(12), x: 0.52, y: 0.72, scale: 0.30)
        var customization = makeCustomization([locked, movable])
        let before = try XCTUnwrap(customization.resolvedControls(in: landscape).first { $0.id == .custom(lockedID) }).center

        let report = customization.layoutQualityReport(canvasSize: landscape)
        XCTAssertTrue(report.issues.contains { $0.code == "small-control" })
        XCTAssertTrue(customization.separateExpandedHitTargets(in: landscape))
        let after = try XCTUnwrap(customization.resolvedControls(in: landscape).first { $0.id == .custom(lockedID) }).center
        XCTAssertEqual(after.x, before.x, accuracy: 0.001)
        XCTAssertEqual(after.y, before.y, accuracy: 0.001)

        var bothLocked = customization
        bothLocked.customButtons[1].layout.isLocationLocked = true
        bothLocked.customButtons[1].layout.centerX = bothLocked.customButtons[0].layout.centerX
        bothLocked.customButtons[1].layout.centerY = bothLocked.customButtons[0].layout.centerY
        let lockedReport = bothLocked.layoutQualityReport(canvasSize: landscape)
        XCTAssertTrue(lockedReport.issues.contains { $0.code == "control-overlap" })
        let lockedIssue = try XCTUnwrap(lockedReport.issues.first { $0.code == "control-overlap" })
        let lockedRepair = bothLocked.applyLayoutRepair(
            .separateExpandedHitTargets,
            issue: lockedIssue,
            canvasSize: landscape,
            respectingLocks: true
        )
        XCTAssertFalse(lockedRepair.didChange)
        XCTAssertEqual(Set(lockedRepair.skippedLockedControlIDs), Set(lockedIssue.controls))
    }

    func testThumbstickValidationUsesActivationAreaNotPostActivationTravelRange() throws {
        let joystickID = uuid(75)
        let buttonID = uuid(76)
        var customization = makeCustomization([
            button(buttonID, .preset(5), x: 0.70, y: 0.70, scale: 0.55)
        ])
        customization.addJoystick(id: joystickID, label: "Aim", mapping: .secondary)
        let joystickIndex = customization.customButtons.count - 1
        customization.customButtons[joystickIndex].layout.centerX = 0.30
        customization.customButtons[joystickIndex].layout.centerY = 0.70
        customization.customButtons[joystickIndex].layout.widthScale = 0.45
        customization.customButtons[joystickIndex].layout.heightScale = 0.45
        customization.customButtons[joystickIndex].layout.joystickVisualStyle = .thumbstick

        let preliminary = customization.resolvedControls(in: landscape)
        let joystick = try XCTUnwrap(preliminary.first { $0.id == .custom(joystickID) })
        let buttonControl = try XCTUnwrap(preliminary.first { $0.id == .custom(buttonID) })
        let joystickHitFrame = GamepadLayoutQualityReport.runtimeHitFrame(for: joystick)
        let joystickRetentionFrame = try XCTUnwrap(GamepadLayoutQualityReport.runtimeRetentionFrame(for: joystick))
        XCTAssertEqual(joystickHitFrame.width, max(44, min(joystick.size.width, joystick.size.height)), accuracy: 0.001)
        XCTAssertGreaterThan(joystickRetentionFrame.width, joystickHitFrame.width + 20)

        let visualGap: CGFloat = 14
        customization.customButtons[0].layout.centerX = (
            joystick.frame.maxX + visualGap + buttonControl.frame.width / 2
        ) / landscape.width
        let report = customization.layoutQualityReport(canvasSize: landscape)
        XCTAssertFalse(report.issues.contains { $0.code == "control-overlap" })
        XCTAssertFalse(report.issues.contains {
            $0.code == "expanded-hit-overlap"
                && Set($0.controls) == Set(["custom.\(joystickID.uuidString)", "custom.\(buttonID.uuidString)"])
        })
    }

    func testOneHandedTemplateMetadataSuppressesTwoHandedFalsePositives() {
        for template in [
            GamepadControllerTemplate.productivityOneHandedLeft,
            .productivityOneHandedRight
        ] {
            let profile = template.makeProfile()
            for orientation in GamepadEditorDeviceOrientation.allCases {
                let customization = profile.customization(for: orientation)
                let report = customization.layoutQualityReport(
                    profileName: profile.name,
                    canvasSize: customization.deviceCanvas.editorDeviceFrame.screenRect.size
                )
                XCTAssertFalse(report.issues.contains {
                    $0.code == "portrait-primary-action-distribution"
                        || $0.code == "primary-control-too-central"
                        || $0.code == "primary-control-out-of-reach"
                }, "\(template.displayName) \(orientation.displayName): \(report.issues)")
            }
        }
    }

    func testQualityReportDecodesWithoutNewRepairAndExpandedHitFields() throws {
        let report = makeCustomization([button(uuid(80), .preset(5), x: 0.8, y: 0.75)]).layoutQualityReport(canvasSize: landscape)
        let encoded = try JSONEncoder().encode(report)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        if var controls = object["controls"] as? [[String: Any]] {
            for index in controls.indices { controls[index].removeValue(forKey: "expandedHitFrame") }
            object["controls"] = controls
        }
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(GamepadLayoutQualityReport.self, from: legacyData)
        XCTAssertNil(decoded.controls.first?.expandedHitFrame)
    }

    private func makeCustomization(
        _ buttons: [GamepadCustomButton],
        order: [GamepadControlIdentity]? = nil
    ) -> GamepadCustomization {
        var customization = GamepadCustomization.blankCanvas
        customization.customButtons = buttons
        customization.designMetadata = GamepadDesignMetadata(layerOrder: order ?? buttons.map { .custom($0.id) })
        return customization
    }

    private func button(
        _ id: UUID,
        _ appearanceAnchor: KeypadElementID,
        role: GamepadVisualRole = .primaryAction,
        x: CGFloat,
        y: CGFloat,
        scale: CGFloat = 1
    ) -> GamepadCustomButton {
        GamepadCustomButton(
            id: id,
            label: appearanceAnchor.displayName,
            layout: GamepadButtonCustomization(
                centerX: x,
                centerY: y,
                widthScale: scale,
                heightScale: scale,
                shape: .rectangle
            ),
            visualRole: role
        )
    }

    private func uuid(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", suffix))!
    }
}
