import Foundation
import CoreGraphics
import SwiftUI

#if os(macOS)
import AppKit
#endif

enum GamepadLayoutIssueSeverity: String, Codable, CaseIterable {
    case info
    case warning
    case error
}

enum GamepadLayoutRepairKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case showDefaultControls = "show-default-controls"
    case moveInsideSafeArea = "move-inside-safe-area"
    case minimumTouchTarget = "minimum-touch-target"
    case resolveOverlap = "resolve-overlap"
    case autoArrange = "auto-arrange"
    case separateExpandedHitTargets = "separate-expanded-hit-targets"
    case ergonomicAutoArrange = "ergonomic-auto-arrange"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .showDefaultControls: "Show Default Controls"
        case .moveInsideSafeArea: "Move Inside Safe Area"
        case .minimumTouchTarget: "Make at Least 44 pt"
        case .resolveOverlap: "Separate Overlapping Controls"
        case .autoArrange: "Auto-arrange Layout"
        case .separateExpandedHitTargets: "Separate Touch Targets"
        case .ergonomicAutoArrange: "Arrange for Thumb Reach"
        }
    }

    var systemImage: String {
        switch self {
        case .showDefaultControls: "square.grid.3x3"
        case .moveInsideSafeArea: "arrow.down.right.and.arrow.up.left"
        case .minimumTouchTarget: "arrow.up.left.and.arrow.down.right"
        case .resolveOverlap: "square.2.layers.3d"
        case .autoArrange: "wand.and.stars"
        case .separateExpandedHitTargets: "arrow.left.and.right"
        case .ergonomicAutoArrange: "hand.point.up.left"
        }
    }
}

struct GamepadLayoutIssue: Codable, Equatable, Identifiable {
    var severity: GamepadLayoutIssueSeverity
    var code: String
    var message: String
    var controls: [String]
    var metric: Double?

    var id: String {
        ([code] + controls.sorted()).joined(separator: "|")
    }

    var suggestedRepairs: [GamepadLayoutRepairKind] {
        switch code {
        case "no-visible-controls":
            [.showDefaultControls]
        case "control-overlap":
            [.resolveOverlap, .autoArrange]
        case "expanded-hit-overlap", "hit-region-z-order-ambiguous", "hit-region-z-order-mismatch":
            [.separateExpandedHitTargets]
        case "layout-displacement", "edge-hugging-control":
            [.moveInsideSafeArea]
        case "small-control":
            [.minimumTouchTarget]
        case "primary-control-too-high", "primary-control-too-central", "primary-control-out-of-reach", "portrait-primary-action-distribution", "portrait-dead-space":
            [.ergonomicAutoArrange]
        case "underused-bottom-space", "low-vertical-coverage", "low-horizontal-coverage":
            [.autoArrange]
        default:
            []
        }
    }
}

struct GamepadLayoutRectSummary: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(_ rect: CGRect) {
        x = Double(rect.minX)
        y = Double(rect.minY)
        width = Double(rect.width)
        height = Double(rect.height)
    }
}

struct GamepadLayoutCanvasSummary: Codable, Equatable {
    var width: Double
    var height: Double

    init(_ size: CGSize) {
        width = Double(size.width)
        height = Double(size.height)
    }
}

struct GamepadLayoutControlSummary: Codable, Equatable {
    var id: String
    var inputID: KeypadElementID?
    var kind: String
    var label: String
    var shape: GamepadButtonShapeStyle
    var requestedFrame: GamepadLayoutRectSummary
    var resolvedFrame: GamepadLayoutRectSummary
    /// The actual runtime touch frame used on iPhone, including expanded thumbstick range.
    var expandedHitFrame: GamepadLayoutRectSummary?
    var displacement: Double
    var widthRatio: Double
    var heightRatio: Double

    init(requested: GamepadResolvedControl, resolved: GamepadResolvedControl, canvasSize: CGSize) {
        id = requested.id.id
        inputID = requested.inputID
        if requested.isDecoration {
            kind = "decoration"
        } else if requested.isJoystick {
            kind = "joystick"
        } else if requested.isTrackpad {
            kind = "trackpad"
        } else {
            kind = "button"
        }
        label = requested.label
        shape = requested.shape
        requestedFrame = GamepadLayoutRectSummary(requested.frame)
        resolvedFrame = GamepadLayoutRectSummary(resolved.frame)
        expandedHitFrame = GamepadLayoutRectSummary(GamepadLayoutQualityReport.runtimeHitFrame(for: resolved))
        displacement = Double(hypot(resolved.center.x - requested.center.x, resolved.center.y - requested.center.y))
        widthRatio = Double(resolved.frame.width / max(canvasSize.width, 1))
        heightRatio = Double(resolved.frame.height / max(canvasSize.height, 1))
    }
}

struct GamepadLayoutQualitySummary: Codable, Equatable {
    var controlCount: Int
    var errorCount: Int
    var warningCount: Int
    var largestDisplacement: Double
    var largestWidthRatio: Double
    var largestHeightRatio: Double
    var layoutWidthCoverage: Double
    var layoutHeightCoverage: Double
    var bottomUnusedRatio: Double
}

enum GamepadLayoutReachMode: Equatable {
    case twoHanded
    case oneHandedLeft
    case oneHandedRight
}

enum GamepadLayoutErgonomicRole {
    case movement
    case action
    case utility
    case exempt

    static func role(for control: GamepadResolvedControl) -> GamepadLayoutErgonomicRole {
        guard !control.isDecoration, !control.isJoystick, !control.isTrackpad, !control.isTrigger else { return .exempt }
        switch control.visualRole {
        case .movement: return .movement
        case .utility, .menu: return .utility
        case .decoration, .system, .joystick, .trackpad, .trigger: return .exempt
        case .primaryAction, .secondaryAction: return .action
        case .custom: return .exempt
        }
    }
}

struct GamepadLayoutQualityReport: Codable, Equatable {
    static let runtimeHitOutset: CGFloat = 10

    /// The region where a new touch can initially activate the control.
    /// Thumbsticks intentionally use only their visible center nub here; their
    /// much larger drag range applies after ownership has already been acquired.
    static func runtimeHitFrame(for control: GamepadResolvedControl) -> CGRect {
        if control.layoutCustomization.hitInsets != nil {
            return control.hitFrame
        }
        if control.isJoystick {
            let visualSide = min(control.size.width, control.size.height)
            let style = control.layoutCustomization.joystickVisualStyle ?? .pad
            let hitSide = style == .thumbstick
                ? max(44, visualSide)
                : max(visualSide + runtimeHitOutset * 2, visualSide)
            return CGRect(
                x: control.center.x - hitSide / 2,
                y: control.center.y - hitSide / 2,
                width: hitSide,
                height: hitSide
            )
        }
        return control.frame.insetBy(dx: -runtimeHitOutset, dy: -runtimeHitOutset)
    }

    /// The post-activation travel/retention area used by compact thumbsticks.
    /// It is exposed separately so diagnostics do not mistake travel space for
    /// a region that can steal a neighboring control's initial touch.
    static func runtimeRetentionFrame(for control: GamepadResolvedControl) -> CGRect? {
        guard control.isJoystick,
              (control.layoutCustomization.joystickVisualStyle ?? .pad) == .thumbstick
        else { return nil }
        let visualSide = min(control.size.width, control.size.height)
        let travelSide = max(visualSide * 2.55, 104)
        return CGRect(
            x: control.center.x - travelSide / 2,
            y: control.center.y - travelSide / 2,
            width: travelSide,
            height: travelSide
        )
    }

    var profileName: String?
    var canvas: GamepadLayoutCanvasSummary
    var controls: [GamepadLayoutControlSummary]
    var issues: [GamepadLayoutIssue]
    var summary: GamepadLayoutQualitySummary

    var hasErrors: Bool {
        issues.contains { $0.severity == .error }
    }

    var hasWarnings: Bool {
        issues.contains { $0.severity == .warning }
    }

    var statusText: String {
        hasErrors ? "failed" : (hasWarnings ? "passed with warnings" : "passed")
    }
}

extension GamepadCustomization {
    var layoutReachMode: GamepadLayoutReachMode {
        let tags = Set((designMetadata?.tags ?? []).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        if tags.contains("left-hand") || tags.contains("one-handed-left") { return .oneHandedLeft }
        if tags.contains("right-hand") || tags.contains("one-handed-right") { return .oneHandedRight }
        return .twoHanded
    }

    func layoutQualityReport(
        profileName: String? = nil,
        canvasSize: CGSize? = nil
    ) -> GamepadLayoutQualityReport {
        let canvasSize = canvasSize ?? deviceCanvas.editorDeviceFrame.screenRect.size
        let requestedControls = GamepadLayoutResolver.preferredControls(for: self, in: canvasSize)
        let resolvedControls = resolvedControls(in: canvasSize)
        return GamepadLayoutQualityReport.make(
            profileName: profileName,
            canvasSize: canvasSize,
            requestedControls: requestedControls,
            resolvedControls: resolvedControls,
            validatesFreeformLayout: usesFreeformLayout,
            reachMode: layoutReachMode
        )
    }
}

private extension GamepadLayoutQualityReport {
    static func make(
        profileName: String?,
        canvasSize: CGSize,
        requestedControls: [GamepadResolvedControl],
        resolvedControls: [GamepadResolvedControl],
        validatesFreeformLayout: Bool,
        reachMode: GamepadLayoutReachMode
    ) -> GamepadLayoutQualityReport {
        let resolvedByID = Dictionary(uniqueKeysWithValues: resolvedControls.map { ($0.id, $0) })
        let controlSummaries = requestedControls.compactMap { requested -> GamepadLayoutControlSummary? in
            guard let resolved = resolvedByID[requested.id] else { return nil }
            return GamepadLayoutControlSummary(requested: requested, resolved: resolved, canvasSize: canvasSize)
        }

        var issues: [GamepadLayoutIssue] = []
        let interactiveRequestedControls = requestedControls.filter { !$0.isDecoration }
        let interactiveResolvedControls = resolvedControls.filter { !$0.isDecoration }
        let interactiveSummaries = controlSummaries.filter { $0.kind != "decoration" }

        if interactiveRequestedControls.isEmpty {
            issues.append(
                GamepadLayoutIssue(
                    severity: .error,
                    code: "no-visible-controls",
                    message: "The keypad has no visible interactive controls.",
                    controls: [],
                    metric: nil
                )
            )
        }

        if validatesFreeformLayout {
            issues.append(contentsOf: overlapIssues(controls: interactiveResolvedControls))
            issues.append(contentsOf: displacementIssues(interactiveSummaries, canvasSize: canvasSize))
            issues.append(contentsOf: sizeIssues(interactiveSummaries))
            issues.append(contentsOf: edgeIssues(interactiveSummaries, canvasSize: canvasSize))
            issues.append(contentsOf: utilizationIssues(interactiveSummaries, canvasSize: canvasSize))
            issues.append(contentsOf: ergonomicIssues(
                controls: interactiveResolvedControls,
                canvasSize: canvasSize,
                reachMode: reachMode
            ))
            if canvasSize.height > canvasSize.width {
                issues.append(contentsOf: portraitIssues(
                    controls: interactiveResolvedControls,
                    canvasSize: canvasSize,
                    reachMode: reachMode
                ))
            }
        }

        issues.sort(by: issueSort)
        let usedFrame = usedLayoutFrame(interactiveSummaries.isEmpty ? controlSummaries : interactiveSummaries)
        let summary = GamepadLayoutQualitySummary(
            controlCount: controlSummaries.count,
            errorCount: issues.filter { $0.severity == .error }.count,
            warningCount: issues.filter { $0.severity == .warning }.count,
            largestDisplacement: interactiveSummaries.map(\.displacement).max() ?? 0,
            largestWidthRatio: interactiveSummaries.map(\.widthRatio).max() ?? 0,
            largestHeightRatio: interactiveSummaries.map(\.heightRatio).max() ?? 0,
            layoutWidthCoverage: Double(usedFrame.width / max(canvasSize.width, 1)),
            layoutHeightCoverage: Double(usedFrame.height / max(canvasSize.height, 1)),
            bottomUnusedRatio: Double(max(0, canvasSize.height - usedFrame.maxY) / max(canvasSize.height, 1))
        )

        return GamepadLayoutQualityReport(
            profileName: profileName,
            canvas: GamepadLayoutCanvasSummary(canvasSize),
            controls: controlSummaries,
            issues: issues,
            summary: summary
        )
    }

    static func overlapIssues(controls: [GamepadResolvedControl]) -> [GamepadLayoutIssue] {
        var issues: [GamepadLayoutIssue] = []
        for backIndex in controls.indices {
            for frontIndex in controls.indices where frontIndex > backIndex {
                let back = controls[backIndex]
                let front = controls[frontIndex]
                let visualIntersection = positiveIntersection(back.frame, front.frame)
                let backHitFrame = expandedHitFrame(for: back)
                let frontHitFrame = expandedHitFrame(for: front)
                guard let hitIntersection = positiveIntersection(backHitFrame, frontHitFrame) else { continue }

                let hitRatio = overlapRatio(hitIntersection, backHitFrame, frontHitFrame)
                let controlIDs = [back.id.id, front.id.id]
                if let visualIntersection {
                    let visualRatio = overlapRatio(visualIntersection, back.frame, front.frame)
                    if visualRatio > 0.015 {
                        let percent = Int((visualRatio * 100).rounded())
                        issues.append(
                            GamepadLayoutIssue(
                                severity: .warning,
                                code: "control-overlap",
                                message: "\(back.label) and \(front.label) visually overlap by about \(percent)% of the smaller control.",
                                controls: controlIDs,
                                metric: Double(visualRatio)
                            )
                        )
                    }
                } else {
                    let overlapPoints = min(hitIntersection.width, hitIntersection.height)
                    issues.append(
                        GamepadLayoutIssue(
                            severity: .warning,
                            code: "expanded-hit-overlap",
                            message: "\(back.label) and \(front.label) look separate, but their actual iPhone hit regions overlap by \(Int(overlapPoints.rounded()))pt.",
                            controls: controlIDs,
                            metric: Double(hitRatio)
                        )
                    )
                }

                let frontWinsRuntime = runtimeTouchPriority(front) < runtimeTouchPriority(back)
                    || (runtimeTouchPriority(front) == runtimeTouchPriority(back) && rectArea(frontHitFrame) < rectArea(backHitFrame) - 0.5)
                let equalRuntimePriority = runtimeTouchPriority(front) == runtimeTouchPriority(back)
                    && abs(rectArea(frontHitFrame) - rectArea(backHitFrame)) <= 0.5
                if equalRuntimePriority {
                    issues.append(
                        GamepadLayoutIssue(
                            severity: .warning,
                            code: "hit-region-z-order-ambiguous",
                            message: "\(front.label) is visually above \(back.label), but equal-priority overlapping hit regions do not have a deterministic frontmost touch target.",
                            controls: controlIDs,
                            metric: Double(hitRatio)
                        )
                    )
                } else if !frontWinsRuntime {
                    issues.append(
                        GamepadLayoutIssue(
                            severity: .warning,
                            code: "hit-region-z-order-mismatch",
                            message: "\(front.label) is visually above \(back.label), but iPhone touch routing would choose \(back.label) in their overlapping hit region.",
                            controls: controlIDs,
                            metric: Double(hitRatio)
                        )
                    )
                }
            }
        }
        return issues
    }

    static func expandedHitFrame(for control: GamepadResolvedControl) -> CGRect {
        runtimeHitFrame(for: control)
    }

    static func positiveIntersection(_ lhs: CGRect, _ rhs: CGRect) -> CGRect? {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, intersection.width > 0.5, intersection.height > 0.5 else { return nil }
        return intersection
    }

    static func overlapRatio(_ intersection: CGRect, _ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        rectArea(intersection) / max(1, min(rectArea(lhs), rectArea(rhs)))
    }

    static func rectArea(_ rect: CGRect) -> CGFloat {
        rect.width * rect.height
    }

    static func runtimeTouchPriority(_ control: GamepadResolvedControl) -> Int {
        if control.isTrigger { return 0 }
        if control.isJoystick { return 1 }
        if control.isTrackpad { return 3 }
        return 2
    }

    static func displacementIssues(
        _ controls: [GamepadLayoutControlSummary],
        canvasSize: CGSize
    ) -> [GamepadLayoutIssue] {
        let shortestSide = min(canvasSize.width, canvasSize.height)
        let warningThreshold = max(12, shortestSide * 0.035)
        let errorThreshold = max(28, shortestSide * 0.075)

        return controls.compactMap { control in
            guard control.displacement > Double(warningThreshold) else { return nil }
            let severity: GamepadLayoutIssueSeverity = control.displacement > Double(errorThreshold) ? .error : .warning
            return GamepadLayoutIssue(
                severity: severity,
                code: "layout-displacement",
                message: "\(control.label) had to be moved \(Int(control.displacement.rounded()))pt from its requested position to fit the layout.",
                controls: [control.id],
                metric: control.displacement
            )
        }
    }

    static func sizeIssues(_ controls: [GamepadLayoutControlSummary]) -> [GamepadLayoutIssue] {
        controls.compactMap { control in
            let minDimension = min(control.resolvedFrame.width, control.resolvedFrame.height)
            guard minDimension < 44 else { return nil }
            return GamepadLayoutIssue(
                severity: .warning,
                code: "small-control",
                message: "\(control.label) renders at only \(Int(minDimension.rounded()))pt on its shortest side; aim for at least 44pt visual size.",
                controls: [control.id],
                metric: minDimension
            )
        }
    }

    static func edgeIssues(
        _ controls: [GamepadLayoutControlSummary],
        canvasSize: CGSize
    ) -> [GamepadLayoutIssue] {
        let margin = max(2, min(canvasSize.width, canvasSize.height) * 0.006)
        return controls.compactMap { control in
            let frame = resolvedCGRect(for: control)
            guard frame.minX < margin
                || frame.minY < margin
                || frame.maxX > Double(canvasSize.width - margin)
                || frame.maxY > Double(canvasSize.height - margin)
            else { return nil }

            return GamepadLayoutIssue(
                severity: .warning,
                code: "edge-hugging-control",
                message: "\(control.label) is tight against the device edge; leave a little margin for touch comfort.",
                controls: [control.id],
                metric: nil
            )
        }
    }

    static func utilizationIssues(
        _ controls: [GamepadLayoutControlSummary],
        canvasSize: CGSize
    ) -> [GamepadLayoutIssue] {
        guard controls.count >= 8 else { return [] }
        let usedFrame = usedLayoutFrame(controls)
        guard usedFrame.width > 1, usedFrame.height > 1 else { return [] }

        let widthCoverage = usedFrame.width / max(canvasSize.width, 1)
        let heightCoverage = usedFrame.height / max(canvasSize.height, 1)
        let bottomUnusedRatio = max(0, canvasSize.height - usedFrame.maxY) / max(canvasSize.height, 1)

        var issues: [GamepadLayoutIssue] = []
        if bottomUnusedRatio > 0.18 {
            let percent = Int((bottomUnusedRatio * 100).rounded())
            issues.append(
                GamepadLayoutIssue(
                    severity: .warning,
                    code: "underused-bottom-space",
                    message: "The bottom \(percent)% of the keypad has no visible controls; move primary actions or utility buttons lower to use the full touch area.",
                    controls: controls.map(\.id),
                    metric: Double(bottomUnusedRatio)
                )
            )
        }

        if heightCoverage < 0.70 {
            let percent = Int((heightCoverage * 100).rounded())
            issues.append(
                GamepadLayoutIssue(
                    severity: .warning,
                    code: "low-vertical-coverage",
                    message: "Controls occupy only \(percent)% of the keypad height; distribute controls from top to bottom for a more efficient two-thumb layout.",
                    controls: controls.map(\.id),
                    metric: Double(heightCoverage)
                )
            )
        }

        if widthCoverage < 0.55 {
            let percent = Int((widthCoverage * 100).rounded())
            issues.append(
                GamepadLayoutIssue(
                    severity: .warning,
                    code: "low-horizontal-coverage",
                    message: "Controls occupy only \(percent)% of the keypad width; spread movement and action clusters toward both sides of the screen.",
                    controls: controls.map(\.id),
                    metric: Double(widthCoverage)
                )
            )
        }

        return issues
    }

    static func ergonomicIssues(
        controls: [GamepadResolvedControl],
        canvasSize: CGSize,
        reachMode: GamepadLayoutReachMode
    ) -> [GamepadLayoutIssue] {
        let portrait = canvasSize.height > canvasSize.width
        return controls.compactMap { control in
            let role = GamepadLayoutErgonomicRole.role(for: control)
            guard role == .movement || role == .action else { return nil }
            let x = control.center.x / max(canvasSize.width, 1)
            let y = control.center.y / max(canvasSize.height, 1)
            let sideAnchorX: CGFloat
            let expectedSide: String
            switch reachMode {
            case .twoHanded:
                sideAnchorX = role == .movement
                    ? (portrait ? 0.27 : 0.18)
                    : (portrait ? 0.73 : 0.82)
                expectedSide = role == .movement ? "left" : "right"
            case .oneHandedLeft:
                sideAnchorX = portrait ? 0.27 : 0.25
                expectedSide = "left"
            case .oneHandedRight:
                sideAnchorX = portrait ? 0.73 : 0.75
                expectedSide = "right"
            }
            let anchorY: CGFloat = portrait ? 0.76 : 0.68
            let horizontalReach: CGFloat = reachMode == .twoHanded
                ? (portrait ? 0.36 : 0.34)
                : (portrait ? 0.48 : 0.50)
            let verticalReach: CGFloat = portrait ? 0.38 : 0.43
            let reach = hypot((x - sideAnchorX) / horizontalReach, (y - anchorY) / verticalReach)
            let orientationName = portrait ? "portrait" : "landscape"

            if y < (portrait ? 0.24 : 0.20) {
                return GamepadLayoutIssue(
                    severity: .warning,
                    code: "primary-control-too-high",
                    message: "\(control.label) is in the extreme top of the \(orientationName) keypad, outside the comfortable lower thumb arc.",
                    controls: [control.id.id],
                    metric: Double(y)
                )
            }

            if reachMode == .twoHanded, x >= 0.40, x <= 0.60, y < (portrait ? 0.78 : 0.74) {
                let centrality = 0.5 - abs(x - 0.5)
                return GamepadLayoutIssue(
                    severity: .warning,
                    code: "primary-control-too-central",
                    message: "\(control.label) is too central for reliable one-thumb use in \(orientationName); place primary controls toward a lower side thumb arc.",
                    controls: [control.id.id],
                    metric: Double(centrality)
                )
            }

            guard reach > 1.25 else { return nil }
            return GamepadLayoutIssue(
                severity: .warning,
                code: "primary-control-out-of-reach",
                message: "\(control.label) is outside the expected \(expectedSide) lower-thumb reach zone in \(orientationName).",
                controls: [control.id.id],
                metric: Double(reach)
            )
        }
    }

    static func portraitIssues(
        controls: [GamepadResolvedControl],
        canvasSize: CGSize,
        reachMode: GamepadLayoutReachMode
    ) -> [GamepadLayoutIssue] {
        var issues: [GamepadLayoutIssue] = []
        let primary = controls.filter {
            let role = GamepadLayoutErgonomicRole.role(for: $0)
            return role == .movement || role == .action
        }

        if reachMode == .twoHanded, primary.count >= 4 {
            let lowerLeft = primary.filter { $0.center.x < canvasSize.width * 0.48 && $0.center.y > canvasSize.height * 0.52 }.count
            let lowerRight = primary.filter { $0.center.x > canvasSize.width * 0.52 && $0.center.y > canvasSize.height * 0.52 }.count
            if lowerLeft == 0 || lowerRight == 0 {
                let imbalance = CGFloat(abs(lowerLeft - lowerRight)) / CGFloat(max(primary.count, 1))
                issues.append(
                    GamepadLayoutIssue(
                        severity: .warning,
                        code: "portrait-primary-action-distribution",
                        message: "Portrait primary controls are not distributed across both lower thumb zones (\(lowerLeft) left, \(lowerRight) right).",
                        controls: primary.map { $0.id.id }.sorted(),
                        metric: Double(imbalance)
                    )
                )
            }
        }

        if controls.count >= 6, let largestGap = largestInternalVerticalGap(controls: controls, canvasHeight: canvasSize.height), largestGap > 0.30 {
            let percent = Int((largestGap * 100).rounded())
            issues.append(
                GamepadLayoutIssue(
                    severity: .warning,
                    code: "portrait-dead-space",
                    message: "A \(percent)% tall band of the portrait keypad has no controls; use that space or consolidate controls around the lower thumb zones.",
                    controls: controls.map { $0.id.id }.sorted(),
                    metric: Double(largestGap)
                )
            )
        }
        return issues
    }

    static func largestInternalVerticalGap(controls: [GamepadResolvedControl], canvasHeight: CGFloat) -> CGFloat? {
        var intervals: [(start: CGFloat, end: CGFloat)] = []
        for control in controls {
            let start = max(CGFloat.zero, control.frame.minY)
            let end = min(canvasHeight, control.frame.maxY)
            if end > start { intervals.append((start: start, end: end)) }
        }
        intervals.sort { lhs, rhs in
            lhs.start == rhs.start ? lhs.end < rhs.end : lhs.start < rhs.start
        }
        guard var active = intervals.first else { return nil }
        var largest: CGFloat = 0
        for interval in intervals.dropFirst() {
            if interval.start > active.end {
                largest = max(largest, interval.start - active.end)
                active = interval
            } else {
                active.end = max(active.end, interval.end)
            }
        }
        return largest / max(canvasHeight, 1)
    }

    static func issueSort(_ lhs: GamepadLayoutIssue, _ rhs: GamepadLayoutIssue) -> Bool {
        let severityRank: [GamepadLayoutIssueSeverity: Int] = [.error: 0, .warning: 1, .info: 2]
        if severityRank[lhs.severity] != severityRank[rhs.severity] {
            return (severityRank[lhs.severity] ?? 3) < (severityRank[rhs.severity] ?? 3)
        }
        if lhs.code != rhs.code { return lhs.code < rhs.code }
        if lhs.controls != rhs.controls { return lhs.controls.lexicographicallyPrecedes(rhs.controls) }
        return lhs.message < rhs.message
    }

    static func usedLayoutFrame(_ controls: [GamepadLayoutControlSummary]) -> CGRect {
        guard let first = controls.first else { return .zero }
        let firstFrame = resolvedCGRect(for: first)
        return controls.dropFirst().map(resolvedCGRect(for:)).reduce(firstFrame) { partialResult, frame in
            partialResult.union(frame)
        }
    }

    static func resolvedCGRect(for control: GamepadLayoutControlSummary) -> CGRect {
        CGRect(
            x: CGFloat(control.resolvedFrame.x),
            y: CGFloat(control.resolvedFrame.y),
            width: CGFloat(control.resolvedFrame.width),
            height: CGFloat(control.resolvedFrame.height)
        )
    }
}

#if os(macOS)
enum GamepadLayoutPreviewRenderer {
    static func writePNG(
        customization: GamepadCustomization,
        profileName: String? = nil,
        canvasSize: CGSize? = nil,
        outputURL: URL,
        scale: CGFloat = 2,
        annotateIssues: Bool = true
    ) throws {
        let canvasSize = canvasSize ?? customization.deviceCanvas.editorDeviceFrame.screenRect.size
        let safeScale = max(1, min(scale, 4))
        let pixelWidth = max(1, Int((canvasSize.width * safeScale).rounded()))
        let pixelHeight = max(1, Int((canvasSize.height * safeScale).rounded()))

        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: representation)?.cgContext else {
            throw CocoaError(.fileWriteUnknown)
        }

        representation.size = canvasSize
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }

        context.scaleBy(x: safeScale, y: safeScale)
        context.translateBy(x: 0, y: canvasSize.height)
        context.scaleBy(x: 1, y: -1)

        let report = customization.layoutQualityReport(profileName: profileName, canvasSize: canvasSize)
        let requestedByID = Dictionary(uniqueKeysWithValues: GamepadLayoutResolver.preferredControls(for: customization, in: canvasSize).map { ($0.id.id, $0) })
        let problemIDs = Set(report.issues.flatMap(\.controls))

        drawBackground(in: context, customization: customization, canvasSize: canvasSize)
        drawGrid(in: context, canvasSize: canvasSize)

        if annotateIssues {
            for control in report.controls where control.displacement > 1 {
                guard let requested = requestedByID[control.id] else { continue }
                drawFrameOutline(requested.frame, in: context, color: NSColor.systemGray.withAlphaComponent(0.74), dashed: true, lineWidth: 1.5)
            }
        }

        for control in customization.resolvedControls(in: canvasSize) {
            draw(control: control, customization: customization, problemIDs: problemIDs, in: context, annotateIssues: annotateIssues)
        }

        drawBorder(in: context, canvasSize: canvasSize, report: report)

        guard let pngData = representation.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try pngData.write(to: outputURL, options: .atomic)
    }

    private static func drawBackground(in context: CGContext, customization: GamepadCustomization, canvasSize: CGSize) {
        drawFillStyle(
            customization.keypadBackgroundFillStyle(scheme: .dark),
            in: CGRect(origin: .zero, size: canvasSize),
            context: context
        )
    }

    private static func drawFillStyle(_ fillStyle: GamepadFillStyle, in rect: CGRect, context: CGContext) {
        switch fillStyle.normalized {
        case .solid(let color):
            context.setFillColor(cgColor(color))
            context.fill(rect)
        case .gradient(let gradient):
            drawGradient(gradient, in: rect, context: context)
        case .tile(let tile):
            context.setFillColor(cgColor(tile.representativeColor))
            context.fill(rect)
        case .image(let image):
            context.setFillColor(cgColor(image.representativeColor))
            context.fill(rect)
        }
    }

    private static func drawGradient(_ gradient: GamepadGradientFill, in rect: CGRect, context: CGContext) {
        let normalized = gradient.normalized
        let colors = normalized.stops.map { cgColor($0.color) as CGColor } as CFArray
        let locations = normalized.stops.map { CGFloat($0.offset) }
        guard let cgGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: locations) else {
            context.setFillColor(cgColor(normalized.representativeColor))
            context.fill(rect)
            return
        }

        context.saveGState()
        context.clip(to: rect)
        switch normalized.type {
        case .linear:
            let points = gradientEndpoints(angleDegrees: normalized.angleDegrees, rect: rect)
            context.drawLinearGradient(cgGradient, start: points.start, end: points.end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        case .radial:
            let radius = hypot(rect.width, rect.height) / 2
            context.drawRadialGradient(
                cgGradient,
                startCenter: CGPoint(x: rect.midX, y: rect.midY),
                startRadius: 0,
                endCenter: CGPoint(x: rect.midX, y: rect.midY),
                endRadius: radius,
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }
        context.restoreGState()
    }

    private static func gradientEndpoints(angleDegrees: CGFloat, rect: CGRect) -> (start: CGPoint, end: CGPoint) {
        let radians = angleDegrees * CGFloat.pi / 180
        let direction = CGVector(dx: cos(radians), dy: sin(radians))
        let halfLength = hypot(rect.width, rect.height) / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return (
            CGPoint(x: center.x - direction.dx * halfLength, y: center.y - direction.dy * halfLength),
            CGPoint(x: center.x + direction.dx * halfLength, y: center.y + direction.dy * halfLength)
        )
    }

    private static func drawGrid(in context: CGContext, canvasSize: CGSize) {
        context.saveGState()
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.08).cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: canvasSize.width / 2, y: 0))
        context.addLine(to: CGPoint(x: canvasSize.width / 2, y: canvasSize.height))
        context.move(to: CGPoint(x: 0, y: canvasSize.height / 2))
        context.addLine(to: CGPoint(x: canvasSize.width, y: canvasSize.height / 2))
        context.strokePath()
        context.restoreGState()
    }

    private static func drawBorder(in context: CGContext, canvasSize: CGSize, report: GamepadLayoutQualityReport) {
        context.saveGState()
        let color: NSColor = report.hasErrors ? .systemRed : (report.hasWarnings ? .systemGray : .systemGreen)
        context.setStrokeColor(color.withAlphaComponent(0.60).cgColor)
        context.setLineWidth(2)
        context.stroke(CGRect(origin: .zero, size: canvasSize).insetBy(dx: 1, dy: 1))
        context.restoreGState()
    }

    private static func draw(
        control: GamepadResolvedControl,
        customization: GamepadCustomization,
        problemIDs: Set<String>,
        in context: CGContext,
        annotateIssues: Bool
    ) {
        let presentation = customization.resolvedPresentation(for: control, state: .normal, scheme: .dark)
        let fill = presentation.fillStyle.representativeColor
        let foreground = presentation.foregroundColor

        drawOuterShadows(for: control, presentation: presentation, fill: fill, in: context)

        context.saveGState()
        context.setFillColor(cgColor(fill, alphaMultiplier: presentation.opacity))
        context.setStrokeColor(cgColor(presentation.strokeColor))
        context.setLineWidth(presentation.strokeWidth)

        addPath(for: control, in: context)
        context.drawPath(using: .fillStroke)

        drawMaterialEffects(for: control, presentation: presentation, in: context)

        if control.isJoystick {
            drawJoystickDetails(control: control, foreground: foreground, in: context)
        } else if control.isTrackpad {
            drawTrackpadDetails(control: control, foreground: foreground, in: context)
        }

        if annotateIssues, problemIDs.contains(control.id.id) {
            drawFrameOutline(control.frame.insetBy(dx: -2, dy: -2), in: context, color: .systemRed, dashed: false, lineWidth: 2)
        }

        let icon = presentation.icon
        if let icon {
            drawIcon(icon, in: control.frame, foreground: foreground, context: context)
        }

        if customization.showsButtonLabels,
           !control.isJoystick,
           !control.isDecoration,
           shouldDrawLabel(control.label, with: icon) {
            drawLabel(
                control.label,
                in: control.frame,
                foreground: foreground,
                context: context,
                isJoystick: control.isJoystick,
                isTrackpad: control.isTrackpad,
                iconPlacement: icon?.placement
            )
        }

        context.restoreGState()
    }

    private static func drawOuterShadows(
        for control: GamepadResolvedControl,
        presentation: GamepadResolvedControlPresentation,
        fill: GamepadRGBAColor,
        in context: CGContext
    ) {
        let shadows: [GamepadControlShadowStyle]
        if presentation.shadows.isEmpty {
            guard presentation.shadowRadius > 0 || abs(presentation.shadowX) > 0.001 || abs(presentation.shadowY) > 0.001 else { return }
            shadows = [GamepadControlShadowStyle(color: presentation.shadowColor, radius: presentation.shadowRadius, x: presentation.shadowX, y: presentation.shadowY)]
        } else {
            shadows = presentation.shadows
        }

        for shadow in shadows {
            let normalized = shadow.normalized
            guard normalized.radius > 0 || abs(normalized.x) > 0.001 || abs(normalized.y) > 0.001 else { continue }
            context.saveGState()
            context.setShadow(offset: CGSize(width: normalized.x, height: normalized.y), blur: normalized.radius, color: cgColor(normalized.color))
            context.setFillColor(cgColor(fill, alphaMultiplier: presentation.opacity))
            addPath(for: control, in: context)
            context.fillPath()
            context.restoreGState()
        }
    }

    private static func drawMaterialEffects(
        for control: GamepadResolvedControl,
        presentation: GamepadResolvedControlPresentation,
        in context: CGContext
    ) {
        if presentation.highlightOpacity > 0 {
            let color = presentation.highlightColor ?? GamepadRGBAColor(red: 1, green: 1, blue: 1, alpha: 1)
            context.saveGState()
            addPath(for: control, in: context)
            context.clip()
            context.translateBy(x: presentation.highlightX, y: presentation.highlightY)
            if presentation.highlightRadius > 0 {
                context.setShadow(
                    offset: .zero,
                    blur: presentation.highlightRadius,
                    color: cgColor(color, alphaMultiplier: presentation.highlightOpacity)
                )
            }
            context.setFillColor(cgColor(color, alphaMultiplier: presentation.highlightOpacity))
            addPath(for: control, in: context)
            context.fillPath()
            context.restoreGState()
        }

        if presentation.bevelWidth > 0 {
            drawOffsetStroke(
                for: control,
                color: presentation.bevelHighlightColor ?? GamepadRGBAColor(red: 1, green: 1, blue: 1, alpha: 0.62),
                lineWidth: presentation.bevelWidth,
                offset: CGSize(width: -presentation.bevelWidth * 0.35, height: -presentation.bevelWidth * 0.35),
                context: context
            )
            drawOffsetStroke(
                for: control,
                color: presentation.bevelShadowColor ?? GamepadRGBAColor(red: 0, green: 0, blue: 0, alpha: 0.24),
                lineWidth: max(0.5, presentation.bevelWidth * 0.70),
                offset: CGSize(width: presentation.bevelWidth * 0.35, height: presentation.bevelWidth * 0.35),
                context: context
            )
        }

        if presentation.innerShadowRadius > 0 || presentation.innerShadowColor != nil {
            let color = presentation.innerShadowColor ?? GamepadRGBAColor(red: 0, green: 0, blue: 0, alpha: 0.22)
            context.saveGState()
            addPath(for: control, in: context)
            context.clip()
            context.translateBy(x: presentation.innerShadowX, y: presentation.innerShadowY)
            context.setShadow(offset: .zero, blur: max(0, presentation.innerShadowRadius), color: cgColor(color))
            context.setStrokeColor(cgColor(color))
            context.setLineWidth(max(1, presentation.innerShadowRadius * 2))
            addPath(for: control, in: context)
            context.strokePath()
            context.restoreGState()
        }
    }

    private static func drawOffsetStroke(
        for control: GamepadResolvedControl,
        color: GamepadRGBAColor,
        lineWidth: CGFloat,
        offset: CGSize,
        context: CGContext
    ) {
        context.saveGState()
        addPath(for: control, in: context)
        context.clip()
        context.translateBy(x: offset.width, y: offset.height)
        context.setStrokeColor(cgColor(color))
        context.setLineWidth(lineWidth)
        addPath(for: control, in: context)
        context.strokePath()
        context.restoreGState()
    }

    private static func drawJoystickDetails(control: GamepadResolvedControl, foreground: GamepadRGBAColor, in context: CGContext) {
        let side = min(control.frame.width, control.frame.height)
        let center = control.center
        let isThumbstick = control.layoutCustomization.joystickVisualStyle == .thumbstick
        let knobRatio: CGFloat = isThumbstick ? 0.72 : 0.36
        let knobSide = side * knobRatio
        let knobRect = CGRect(x: center.x - knobSide / 2, y: center.y - knobSide / 2, width: knobSide, height: knobSide)
        context.saveGState()
        context.setStrokeColor(cgColor(foreground, alphaMultiplier: 0.38))
        context.setLineWidth(1)
        if !isThumbstick {
            let ringRect = CGRect(x: center.x - side * 0.35, y: center.y - side * 0.35, width: side * 0.70, height: side * 0.70)
            context.strokeEllipse(in: ringRect)
        }
        context.setFillColor(cgColor(foreground, alphaMultiplier: isThumbstick ? 0.28 : 0.20))
        context.fillEllipse(in: knobRect)
        context.setStrokeColor(cgColor(foreground, alphaMultiplier: 0.34))
        context.strokeEllipse(in: knobRect)
        context.restoreGState()
    }

    private static func drawTrackpadDetails(control: GamepadResolvedControl, foreground: GamepadRGBAColor, in context: CGContext) {
        let inset = max(6, min(control.frame.width, control.frame.height) * 0.08)
        let inner = control.frame.insetBy(dx: inset, dy: inset)
        let radius = max(6, min(inner.width, inner.height) * 0.08)
        context.saveGState()
        context.setStrokeColor(cgColor(foreground, alphaMultiplier: 0.22))
        context.setLineWidth(1)
        context.addPath(CGPath(roundedRect: inner, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.strokePath()

        let pillWidth = inner.width * 0.34
        let pillHeight = max(3, inner.height * 0.045)
        let pillY = control.frame.maxY - inset - pillHeight * 2
        context.setFillColor(cgColor(foreground, alphaMultiplier: 0.28))
        context.addPath(CGPath(roundedRect: CGRect(x: control.center.x - pillWidth / 2, y: pillY, width: pillWidth, height: pillHeight), cornerWidth: pillHeight / 2, cornerHeight: pillHeight / 2, transform: nil))
        context.fillPath()
        context.restoreGState()
    }

    private static func drawIcon(_ icon: GamepadControlIcon, in frame: CGRect, foreground: GamepadRGBAColor, context: CGContext) {
        let text: String
        switch icon.source {
        case .sfSymbol:
            text = previewGlyph(for: icon.value)
        case .text:
            text = icon.value
        case .asset:
            text = "▧"
        }
        let color = icon.tintColor ?? foreground
        let fontSize = max(10, min(frame.width, frame.height) * 0.34 * icon.scale)
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: nsColor(color)
            ]
        )
        let size = attributed.size()
        let offset: CGPoint = switch icon.placement {
        case .leading: CGPoint(x: -frame.width * 0.20, y: 0)
        case .trailing: CGPoint(x: frame.width * 0.20, y: 0)
        case .top: CGPoint(x: 0, y: -frame.height * 0.18)
        case .bottom: CGPoint(x: 0, y: frame.height * 0.18)
        case .center, .background: .zero
        }
        let rect = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
        context.saveGState()
        context.translateBy(x: frame.midX + offset.x, y: frame.midY + offset.y)
        context.scaleBy(x: 1, y: -1)
        attributed.draw(in: rect)
        context.restoreGState()
    }

    private static func shouldDrawLabel(_ label: String, with icon: GamepadControlIcon?) -> Bool {
        guard let icon else { return true }
        if icon.placement == .center, label.count > 2 { return false }
        if icon.placement == .background { return true }
        return true
    }

    private static func previewGlyph(for sfSymbolName: String) -> String {
        let normalized = sfSymbolName.lowercased()
        if normalized.contains("sparkle") { return "✦" }
        if normalized.contains("wind") { return "≋" }
        if normalized.contains("slash") { return "⟋" }
        if normalized.contains("arrow.up") || normalized.contains("chevron.up") { return "↑" }
        if normalized.contains("arrow.down") || normalized.contains("chevron.down") { return "↓" }
        if normalized.contains("arrow.left") || normalized.contains("chevron.left") { return "←" }
        if normalized.contains("arrow.right") || normalized.contains("chevron.right") { return "→" }
        if normalized.contains("map") { return "◇" }
        if normalized.contains("pause") { return "Ⅱ" }
        if normalized.contains("moon") { return "☾" }
        if normalized.contains("forward") { return "»" }
        if normalized.contains("bag") { return "▣" }
        return "•"
    }

    private static func drawLabel(
        _ label: String,
        in frame: CGRect,
        foreground: GamepadRGBAColor,
        context: CGContext,
        isJoystick: Bool,
        isTrackpad: Bool,
        iconPlacement: GamepadControlIconPlacement? = nil
    ) {
        let maxFontSize = isJoystick || isTrackpad ? CGFloat(14) : CGFloat(label.count <= 2 ? 28 : 16)
        let reservesHorizontalIconSpace = iconPlacement == .leading || iconPlacement == .trailing
        let reservesVerticalIconSpace = iconPlacement == .top || iconPlacement == .bottom
        let availableWidth = max(1, frame.width - 8 - (reservesHorizontalIconSpace ? frame.width * 0.26 : 0))
        let availableHeight = max(1, frame.height - 6 - (reservesVerticalIconSpace ? frame.height * 0.24 : 0))
        var fontSize = max(8, min(maxFontSize, frame.height * 0.36))
        var attributed = NSAttributedString(
            string: label,
            attributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: nsColor(foreground)
            ]
        )
        while fontSize > 7.5 {
            let measured = attributed.size()
            if measured.width <= availableWidth && measured.height <= availableHeight { break }
            fontSize -= 0.5
            attributed = NSAttributedString(
                string: label,
                attributes: [
                    .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                    .foregroundColor: nsColor(foreground)
                ]
            )
        }
        let textSize = attributed.size()
        let textRect = CGRect(
            x: -min(textSize.width, availableWidth) / 2,
            y: -min(textSize.height, availableHeight) / 2,
            width: min(textSize.width, availableWidth),
            height: min(textSize.height, availableHeight)
        )

        let baseYOffset = isJoystick ? frame.height * 0.28 : (isTrackpad ? frame.height * 0.18 : 0)
        let labelOffset: CGPoint = switch iconPlacement {
        case .leading: CGPoint(x: frame.width * 0.11, y: 0)
        case .trailing: CGPoint(x: -frame.width * 0.11, y: 0)
        case .top: CGPoint(x: 0, y: frame.height * 0.15)
        case .bottom: CGPoint(x: 0, y: -frame.height * 0.15)
        case .center, .background, nil: .zero
        }

        context.saveGState()
        context.translateBy(x: frame.midX + labelOffset.x, y: frame.midY + baseYOffset + labelOffset.y)
        context.scaleBy(x: 1, y: -1)
        attributed.draw(in: textRect)
        context.restoreGState()
    }

    private static func drawFrameOutline(_ frame: CGRect, in context: CGContext, color: NSColor, dashed: Bool, lineWidth: CGFloat) {
        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(lineWidth)
        if dashed { context.setLineDash(phase: 0, lengths: [5, 4]) }
        context.stroke(frame)
        context.restoreGState()
    }

    private static func addPath(for control: GamepadResolvedControl, in context: CGContext) {
        let frame = control.frame
        switch control.shape {
        case .circle, .ellipse:
            context.addEllipse(in: frame)
        case .capsule:
            context.addPath(CGPath(roundedRect: frame, cornerWidth: min(frame.width, frame.height) / 2, cornerHeight: min(frame.width, frame.height) / 2, transform: nil))
        case .roundedRectangle:
            let radius = control.layoutCustomization.resolvedCornerRadii(defaultRadius: 12).averageRadius
            context.addPath(CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil))
        case .rectangle:
            context.addRect(frame)
        case .polygon:
            context.addPath(polygonPath(in: frame, sides: 6))
        case .star:
            context.addPath(starPath(in: frame))
        }
    }

    private static func polygonPath(in frame: CGRect, sides: Int) -> CGPath {
        let path = CGMutablePath()
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let radius = min(frame.width, frame.height) / 2
        for index in 0..<max(3, sides) {
            let angle = (-CGFloat.pi / 2) + CGFloat(index) * (2 * CGFloat.pi / CGFloat(max(3, sides)))
            let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }

    private static func starPath(in frame: CGRect) -> CGPath {
        let path = CGMutablePath()
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let outer = min(frame.width, frame.height) / 2
        let inner = outer * 0.48
        for index in 0..<10 {
            let radius = index.isMultiple(of: 2) ? outer : inner
            let angle = (-CGFloat.pi / 2) + CGFloat(index) * (CGFloat.pi / 5)
            let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }

    private static func cgColor(_ color: GamepadRGBAColor, alphaMultiplier: CGFloat = 1) -> CGColor {
        let normalized = color.normalized
        return CGColor(
            red: normalized.red,
            green: normalized.green,
            blue: normalized.blue,
            alpha: min(max(normalized.alpha * alphaMultiplier, 0), 1)
        )
    }

    private static func nsColor(_ color: GamepadRGBAColor) -> NSColor {
        let normalized = color.normalized
        return NSColor(
            calibratedRed: normalized.red,
            green: normalized.green,
            blue: normalized.blue,
            alpha: normalized.alpha
        )
    }
}
#endif
