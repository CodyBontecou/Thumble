import Foundation

#if !XCODEBUILD_TEST
@main
#endif
struct GamepadLayoutResolverSmokeTests {
    static func main() {
        testAdjacentControlsCanTouchWithoutBeingSeparated()
        testOverlappingControlsResolveAtRequestedPositions()
        testNudgeMovesSingleControlByPixels()
        testNudgeMovesMultipleControlsTogether()
        testNudgeSkipsLockedControls()
        testNudgeAllowsOverlaps()
        testOnePixelInspectorSizedControlsResolveAtRequestedSize()
        testZIndexSortsResolvedControls()
        testResolvedControlCacheKeyIgnoresPresentationChanges()
        testResolvedControlCacheRefreshesPresentationAndGeometry()
        testLayoutQualityPassesDefaultController()
        testLayoutQualityWarnsAboutAllowedOverlaps()
        testLayoutQualityDetectsUnderusedBottomSpace()
        print("GamepadLayoutResolver smoke tests passed")
    }

    private static func testAdjacentControlsCanTouchWithoutBeingSeparated() {
        let canvasSize = CGSize(width: 400, height: 200)
        let leftID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        let rightID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
        let initialLayout = GamepadButtonCustomization(
            centerX: 0.5,
            centerY: 0.5,
            widthScale: 2.0,
            heightScale: 1.0,
            shape: .rectangle
        )

        var customization = GamepadCustomization.blankCanvas
        customization.customButtons = [
            GamepadCustomButton(id: leftID, label: "Left", layout: initialLayout),
            GamepadCustomButton(id: rightID, label: "Right", layout: initialLayout)
        ]

        let preliminaryControls = customization.resolvedControls(in: canvasSize)
        guard let preliminaryLeft = preliminaryControls.first(where: { $0.id == .custom(leftID) }) else {
            fail("could not resolve preliminary left custom control")
        }

        let buttonWidth = preliminaryLeft.frame.width
        let joinX = canvasSize.width / 2
        customization.customButtons[0].layout.centerX = (joinX - buttonWidth / 2) / canvasSize.width
        customization.customButtons[1].layout.centerX = (joinX + buttonWidth / 2) / canvasSize.width

        let controls = customization.resolvedControls(in: canvasSize)
        guard let left = controls.first(where: { $0.id == .custom(leftID) }),
              let right = controls.first(where: { $0.id == .custom(rightID) })
        else {
            fail("could not resolve adjacent custom controls")
        }

        expectAlmostEqual(
            left.frame.maxX,
            right.frame.minX,
            "adjacent controls should be allowed to touch exactly without a forced gap"
        )
        expect(
            !framesOverlap(left.frame, right.frame),
            "touching controls should not overlap"
        )
    }

    private static func testOverlappingControlsResolveAtRequestedPositions() {
        let canvasSize = CGSize(width: 400, height: 200)
        let backID = UUID(uuidString: "00000000-0000-0000-0000-000000000111")!
        let frontID = UUID(uuidString: "00000000-0000-0000-0000-000000000112")!
        let requestedCenter = CGPoint(x: 0.5, y: 0.5)
        var customization = GamepadCustomization.blankCanvas
        customization.customButtons = [
            customButton(id: backID, center: requestedCenter),
            customButton(id: frontID, center: requestedCenter)
        ]

        let controls = controlsByID(customization.resolvedControls(in: canvasSize))
        guard let back = controls[.custom(backID)], let front = controls[.custom(frontID)] else {
            fail("could not resolve overlapping controls")
        }

        expectAlmostEqual(back.center.x, canvasSize.width / 2, "back control should keep its requested x position")
        expectAlmostEqual(back.center.y, canvasSize.height / 2, "back control should keep its requested y position")
        expectAlmostEqual(front.center.x, back.center.x, "front control should share the requested x position")
        expectAlmostEqual(front.center.y, back.center.y, "front control should share the requested y position")
        expect(framesOverlap(back.frame, front.frame), "resolved controls should be allowed to overlap")
    }

    private static func testNudgeMovesSingleControlByPixels() {
        let canvasSize = CGSize(width: 400, height: 200)
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000201")!
        var customization = GamepadCustomization.blankCanvas
        customization.customButtons = [customButton(id: id, center: CGPoint(x: 0.5, y: 0.5))]

        guard let before = customization.resolvedControls(in: canvasSize).first(where: { $0.id == .custom(id) }) else {
            fail("could not resolve control before single nudge")
        }
        expect(customization.nudgeControls([.custom(id)], by: CGSize(width: 1, height: 0), in: canvasSize), "single nudge should move")
        guard let after = customization.resolvedControls(in: canvasSize).first(where: { $0.id == .custom(id) }) else {
            fail("could not resolve control after single nudge")
        }

        expectAlmostEqual(after.center.x, before.center.x + 1, "single nudge should move right by one pixel")
        expectAlmostEqual(after.center.y, before.center.y, "single nudge should not change y")
    }

    private static func testNudgeMovesMultipleControlsTogether() {
        let canvasSize = CGSize(width: 400, height: 200)
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000301")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000302")!
        var customization = GamepadCustomization.blankCanvas
        customization.customButtons = [
            customButton(id: firstID, center: CGPoint(x: 0.30, y: 0.55)),
            customButton(id: secondID, center: CGPoint(x: 0.70, y: 0.55))
        ]

        let before = controlsByID(customization.resolvedControls(in: canvasSize))
        expect(customization.nudgeControls([.custom(firstID), .custom(secondID)], by: CGSize(width: 0, height: -10), in: canvasSize), "group nudge should move")
        let after = controlsByID(customization.resolvedControls(in: canvasSize))

        expectAlmostEqual(after[.custom(firstID)]?.center.y ?? -1, (before[.custom(firstID)]?.center.y ?? 0) - 10, "first control should move up by ten pixels")
        expectAlmostEqual(after[.custom(secondID)]?.center.y ?? -1, (before[.custom(secondID)]?.center.y ?? 0) - 10, "second control should move up by ten pixels")
    }

    private static func testNudgeSkipsLockedControls() {
        let canvasSize = CGSize(width: 400, height: 200)
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000401")!
        var locked = customButton(id: id, center: CGPoint(x: 0.5, y: 0.5))
        locked.layout.isLocationLocked = true
        var customization = GamepadCustomization.blankCanvas
        customization.customButtons = [locked]

        expect(!customization.nudgeControls([.custom(id)], by: CGSize(width: 10, height: 0), in: canvasSize), "locked nudge should not move")
    }

    private static func testNudgeAllowsOverlaps() {
        let canvasSize = CGSize(width: 400, height: 200)
        let leftID = UUID(uuidString: "00000000-0000-0000-0000-000000000501")!
        let rightID = UUID(uuidString: "00000000-0000-0000-0000-000000000502")!
        var customization = GamepadCustomization.blankCanvas
        customization.customButtons = [
            customButton(id: leftID, center: CGPoint(x: 0.5, y: 0.5)),
            customButton(id: rightID, center: CGPoint(x: 0.5, y: 0.5))
        ]

        let preliminaryControls = customization.resolvedControls(in: canvasSize)
        guard let preliminaryLeft = preliminaryControls.first(where: { $0.id == .custom(leftID) }) else {
            fail("could not resolve preliminary left control for nudge overlap test")
        }
        let buttonWidth = preliminaryLeft.frame.width
        let joinX = canvasSize.width / 2
        customization.customButtons[0].layout.centerX = (joinX - buttonWidth / 2) / canvasSize.width
        customization.customButtons[1].layout.centerX = (joinX + buttonWidth / 2) / canvasSize.width

        let before = controlsByID(customization.resolvedControls(in: canvasSize))
        expect(customization.nudgeControls([.custom(leftID)], by: CGSize(width: 1, height: 0), in: canvasSize), "nudge should move into an overlapping frame")
        let after = controlsByID(customization.resolvedControls(in: canvasSize))
        expectAlmostEqual(after[.custom(leftID)]?.center.x ?? -1, (before[.custom(leftID)]?.center.x ?? 0) + 1, "nudge should preserve the requested movement")
        guard let left = after[.custom(leftID)], let right = after[.custom(rightID)] else {
            fail("could not resolve controls after overlapping nudge")
        }
        expect(framesOverlap(left.frame, right.frame), "nudged controls should be allowed to overlap")
    }

    private static func testOnePixelInspectorSizedControlsResolveAtRequestedSize() {
        let canvasSize = CGSize(width: 874, height: 402)
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000501")!
        let targetSize: CGFloat = 1
        var customization = GamepadCustomization.blankCanvas
        customization.customButtons = [customButton(id: id, center: CGPoint(x: 0.5, y: 0.5))]

        guard let baseControl = customization.resolvedControls(in: canvasSize).first(where: { $0.id == .custom(id) }) else {
            fail("could not resolve custom control before resizing")
        }

        customization.customButtons[0].layout.widthScale = targetSize / baseControl.size.width
        customization.customButtons[0].layout.heightScale = targetSize / baseControl.size.height

        guard let resizedControl = customization.resolvedControls(in: canvasSize).first(where: { $0.id == .custom(id) }) else {
            fail("could not resolve custom control after resizing")
        }

        expectAlmostEqual(resizedControl.size.width, targetSize, "1 pt inspector width should be preserved")
        expectAlmostEqual(resizedControl.size.height, targetSize, "1 pt inspector height should be preserved")
    }

    private static func testZIndexSortsResolvedControls() {
        let canvasSize = CGSize(width: 400, height: 200)
        let backID = UUID(uuidString: "00000000-0000-0000-0000-000000000701")!
        let frontID = UUID(uuidString: "00000000-0000-0000-0000-000000000702")!
        var back = customButton(id: backID, center: CGPoint(x: 0.5, y: 0.5))
        var front = customButton(id: frontID, center: CGPoint(x: 0.5, y: 0.5))
        back.layout.zIndex = 50
        front.layout.zIndex = -10

        var customization = GamepadCustomization.blankCanvas
        customization.customButtons = [back, front]
        customization.designMetadata = GamepadDesignMetadata(layerOrder: [.custom(backID), .custom(frontID)])

        let controls = customization.resolvedControls(in: canvasSize)
        let backIndex = controls.firstIndex { $0.id == .custom(backID) }
        let frontIndex = controls.firstIndex { $0.id == .custom(frontID) }
        expect(backIndex != nil && frontIndex != nil, "z-index test controls should resolve")
        expect(frontIndex! < backIndex!, "lower z-index should render behind higher z-index regardless of layer order")
        expect(GamepadButtonCustomization(zIndex: 250).zIndex == 100, "z-index should clamp to the front limit")
        expect(GamepadButtonCustomization(zIndex: -250).zIndex == -100, "z-index should clamp to the back limit")
    }

    private static func testResolvedControlCacheKeyIgnoresPresentationChanges() {
        var customization = GamepadCustomization.defaultValue
        let baselineKey = GamepadResolvedControlsLayoutCacheKey(customization: customization)

        var jump = customization.buttonCustomization(for: .preset(5))
        jump.fillColor = GamepadRGBAColor(hexString: "#FF00AA")
        jump.shadowStrength = 1.75
        jump.hapticStyle = .heavy
        jump.visualStyle = GamepadControlVisualStyle(
            normal: GamepadControlStateStyle(glowRadius: 18, opacity: 0.42)
        )
        customization.setButtonCustomization(jump, for: .preset(5))
        customization.backgroundFillStyle = .solid(GamepadRGBAColor(hexString: "#102030") ?? .defaultValue)

        expect(
            GamepadResolvedControlsLayoutCacheKey(customization: customization) == baselineKey,
            "presentation-only changes should reuse resolved control geometry"
        )

        jump.widthScale = 1.4
        customization.setButtonCustomization(jump, for: .preset(5))
        expect(
            GamepadResolvedControlsLayoutCacheKey(customization: customization) != baselineKey,
            "size changes should invalidate resolved control geometry"
        )
    }

    private static func testResolvedControlCacheRefreshesPresentationAndGeometry() {
        let canvasSize = CGSize(width: 874, height: 402)
        var customization = GamepadCustomization.defaultValue
        let cache = GamepadResolvedControlsCache()
        let initial = cache.controls(for: customization, in: canvasSize, defaultLabelProvider: nil)
        expect(cache.resolutionCount == 1, "initial cache lookup should resolve geometry once")
        guard let initialJump = initial.first(where: { $0.id == .builtin(.preset(5)) }) else {
            fail("resolved-control cache did not return jump")
        }

        var jump = customization.buttonCustomization(for: .preset(5))
        jump.fillColor = GamepadRGBAColor(hexString: "#22CC88")
        jump.shadowStrength = 0.25
        customization.setButtonCustomization(jump, for: .preset(5))
        let presentationRefresh = cache.controls(for: customization, in: canvasSize, defaultLabelProvider: nil)
        expect(cache.resolutionCount == 1, "presentation refresh should not resolve geometry again")
        guard let refreshedJump = presentationRefresh.first(where: { $0.id == .builtin(.preset(5)) }) else {
            fail("resolved-control cache lost jump after presentation refresh")
        }
        expectAlmostEqual(refreshedJump.center.x, initialJump.center.x, "presentation refresh should preserve cached geometry")
        expectAlmostEqual(refreshedJump.size.width, initialJump.size.width, "presentation refresh should preserve cached size")
        expectAlmostEqual(refreshedJump.layoutCustomization.shadowStrength, 0.25, "presentation refresh should expose the current style")

        jump.widthScale = 1.5
        customization.setButtonCustomization(jump, for: .preset(5))
        let geometryRefresh = cache.controls(for: customization, in: canvasSize, defaultLabelProvider: nil)
        expect(cache.resolutionCount == 2, "geometry refresh should run the resolver again")
        guard let resizedJump = geometryRefresh.first(where: { $0.id == .builtin(.preset(5)) }) else {
            fail("resolved-control cache lost jump after geometry refresh")
        }
        expect(resizedJump.size.width > initialJump.size.width, "geometry changes should recompute resolved control size")
    }

    private static func testLayoutQualityPassesDefaultController() {
        let report = GamepadCustomization.defaultValue.layoutQualityReport(
            profileName: "Default",
            canvasSize: CGSize(width: 874, height: 402)
        )
        expect(!report.hasErrors, "default controller layout should not have blocking layout errors")
    }

    private static func testLayoutQualityWarnsAboutAllowedOverlaps() {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000601")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000602")!
        var customization = GamepadCustomization.blankCanvas
        let badLayout = GamepadButtonCustomization(
            centerX: 0.5,
            centerY: 0.5,
            widthScale: 1.0,
            heightScale: 1.0,
            shape: .circle
        )
        customization.customButtons = [
            GamepadCustomButton(id: firstID, label: "One", layout: badLayout),
            GamepadCustomButton(id: secondID, label: "Two", layout: badLayout)
        ]

        let report = customization.layoutQualityReport(
            profileName: "Bad",
            canvasSize: CGSize(width: 874, height: 402)
        )
        expect(!report.hasErrors, "intentional control overlap should not fail layout quality validation")
        expect(report.hasWarnings, "overlapping controls should still produce an advisory warning")
        expect(report.issues.contains { $0.code == "control-overlap" }, "layout quality should report overlapping controls")
    }

    private static func testLayoutQualityDetectsUnderusedBottomSpace() {
        var customization = GamepadCustomization.blankCanvas
        customization.customButtons = (11...18).map(KeypadElementID.preset).enumerated().map { index, button in
            let row = index / 4
            let column = index % 4
            let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", 0x700 + index))!
            let layout = GamepadButtonCustomization(
                centerX: 0.18 + CGFloat(column) * 0.21,
                centerY: row == 0 ? 0.14 : 0.34,
                widthScale: 0.55,
                heightScale: 0.55,
                shape: .roundedRectangle
            )
            return GamepadCustomButton(id: id, label: "Button \(index + 1)", layout: layout)
        }

        let report = customization.layoutQualityReport(
            profileName: "Top Heavy",
            canvasSize: CGSize(width: 874, height: 402)
        )
        expect(report.issues.contains { $0.code == "underused-bottom-space" }, "top-heavy layouts should warn about unused bottom space")
    }

    private static func customButton(id: UUID, center: CGPoint) -> GamepadCustomButton {
        GamepadCustomButton(
            id: id,
            label: "Key",
            layout: GamepadButtonCustomization(
                centerX: center.x,
                centerY: center.y,
                widthScale: 1.0,
                heightScale: 1.0,
                shape: .rectangle
            )
        )
    }

    private static func controlsByID(_ controls: [GamepadResolvedControl]) -> [GamepadControlIdentity: GamepadResolvedControl] {
        Dictionary(uniqueKeysWithValues: controls.map { ($0.id, $0) })
    }

    private static func framesOverlap(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        lhs.minX < rhs.maxX
            && lhs.maxX > rhs.minX
            && lhs.minY < rhs.maxY
            && lhs.maxY > rhs.minY
    }

    private static func expect(_ condition: Bool, _ message: String) {
        guard condition else { fail(message) }
    }

    private static func expectAlmostEqual(_ actual: CGFloat, _ expected: CGFloat, _ message: String, tolerance: CGFloat = 0.001) {
        guard abs(actual - expected) <= tolerance else {
            fail("\(message). Expected \(expected), got \(actual)")
        }
    }

    private static func fail(_ message: String) -> Never {
        fputs("GamepadLayoutResolverSmokeTests failed: \(message)\n", stderr)
        exit(1)
    }
}
