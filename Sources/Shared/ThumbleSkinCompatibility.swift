import Foundation

public enum ThumbleSkinCompatibilityMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case universal
    case templateAligned = "template_aligned"
    case capturedController = "captured_controller"

    public var id: String { rawValue }
}

public struct ThumbleSkinTemplateRequirement: Codable, Equatable, Sendable {
    public var templateID: String
    public var minimumRevision: Int
    public var maximumRevision: Int?

    public init(templateID: String, minimumRevision: Int = 1, maximumRevision: Int? = nil) {
        self.templateID = templateID
        self.minimumRevision = minimumRevision
        self.maximumRevision = maximumRevision
    }

    public var normalized: ThumbleSkinTemplateRequirement {
        let templateID = templateID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let minimum = max(1, minimumRevision)
        return ThumbleSkinTemplateRequirement(
            templateID: String(templateID.prefix(80)),
            minimumRevision: minimum,
            maximumRevision: maximumRevision.map { max(minimum, $0) }
        )
    }

    public func matches(templateID requestedID: String, revision: Int) -> Bool {
        let value = normalized
        guard value.templateID == requestedID.lowercased(), revision >= value.minimumRevision else { return false }
        return value.maximumRevision.map { revision <= $0 } ?? true
    }
}

public enum ThumbleSkinRenderingFeature: String, Codable, CaseIterable, Identifiable, Sendable {
    case artworkLayers = "artwork_layers"
    case nineSliceImages = "nine_slice_images"
    case bitmapControlStates = "bitmap_control_states"

    public var id: String { rawValue }
}

/// Exact captured appearance geometry, behind immutable storage. No output mappings,
/// profile names, credentials or binding digests enter a skin compatibility contract.
public final class ThumbleSkinCapturedGeometry: Codable, Equatable, Sendable {
    public let variants: [ThumbleSkinArtboardVariant]
    public init(variants: [ThumbleSkinArtboardVariant]) {
        // Native baseline matrices belong to the hashed workspace contract and
        // review evidence. Runtime compatibility consumes exact geometry only;
        // repeating those matrices in the pretty-printed package manifest can
        // exhaust its bounded entry size without adding a compatibility check.
        self.variants = variants.map { variant in
            var geometry = variant
            geometry.nativeLayout = nil
            return geometry
        }
    }
    public static func == (lhs: ThumbleSkinCapturedGeometry, rhs: ThumbleSkinCapturedGeometry) -> Bool { lhs.variants == rhs.variants }
    public var isValid: Bool {
        !variants.isEmpty && variants.count <= 2 && Set(variants.map(\.orientation)).count == variants.count && variants.allSatisfy { variant in
            variant.canvasWidth.isFinite && variant.canvasHeight.isFinite && (240...1800).contains(variant.canvasWidth)
                && (240...1800).contains(variant.canvasHeight) && variant.controls.count <= 256
                && Set(variant.controls.map(\.id)).count == variant.controls.count
                && [variant.safeAreaInsets.top, variant.safeAreaInsets.leading, variant.safeAreaInsets.bottom, variant.safeAreaInsets.trailing]
                    .allSatisfy { $0.isFinite && (0...0.45).contains($0) }
                && variant.controls.allSatisfy { control in
                    let f = control.frame
                    return !control.id.isEmpty && control.id.utf8.count <= 128
                        && [f.x, f.y, f.width, f.height].allSatisfy { $0.isFinite }
                        && f.x >= 0 && f.y >= 0 && f.width > 0 && f.height > 0
                        && f.x + f.width <= 1.000001 && f.y + f.height <= 1.000001
                        && (control.rotationDegrees.map { $0.isFinite && (-180...180).contains($0) } ?? true)
                        && (control.presentation?.isValid ?? true)
                }
        }
    }
    func matches(_ customization: GamepadCustomization, orientation: ThumbleSkinOrientation) -> Bool {
        guard isValid, let variant = variants.first(where: { $0.orientation == orientation }) else { return false }
        let size = customization.deviceCanvas.editorDeviceFrame.screenRect.size
        guard abs(size.width - variant.canvasWidth) < 0.001, abs(size.height - variant.canvasHeight) < 0.001 else { return false }
        let controls = customization.resolvedControls(in: size).filter { !$0.layoutCustomization.isHidden }
        guard Set(controls.map { $0.id.id }) == Set(variant.controls.map(\.id)) else { return false }
        for expected in variant.controls {
            guard let control = controls.first(where: { $0.id.id == expected.id }), control.controlKind == expected.kind,
                  abs(control.frame.minX / size.width - expected.frame.x) < 0.000001,
                  abs(control.frame.minY / size.height - expected.frame.y) < 0.000001,
                  abs(control.frame.width / size.width - expected.frame.width) < 0.000001,
                  abs(control.frame.height / size.height - expected.frame.height) < 0.000001,
                  expected.rotationDegrees.map({ abs(control.rotationDegrees - $0) < 0.000001 }) ?? true else { return false }
        }
        return true
    }
}

public struct ThumbleSkinCompatibility: Codable, Equatable, Sendable {
    public var capturedGeometry: ThumbleSkinCapturedGeometry?
    public var mode: ThumbleSkinCompatibilityMode
    public var templates: [ThumbleSkinTemplateRequirement]
    public var orientations: [ThumbleSkinOrientation]
    public var minimumAspectRatio: CGFloat?
    public var maximumAspectRatio: CGFloat?
    public var requiredRoles: [GamepadVisualRole]
    public var requiredFeatures: [ThumbleSkinRenderingFeature]

    public init(
        mode: ThumbleSkinCompatibilityMode = .universal,
        templates: [ThumbleSkinTemplateRequirement] = [],
        orientations: [ThumbleSkinOrientation] = ThumbleSkinOrientation.allCases,
        minimumAspectRatio: CGFloat? = nil,
        maximumAspectRatio: CGFloat? = nil,
        requiredRoles: [GamepadVisualRole] = [],
        requiredFeatures: [ThumbleSkinRenderingFeature] = [],
        capturedGeometry: ThumbleSkinCapturedGeometry? = nil
    ) {
        self.capturedGeometry = capturedGeometry
        self.mode = mode
        self.templates = templates
        self.orientations = orientations
        self.minimumAspectRatio = minimumAspectRatio
        self.maximumAspectRatio = maximumAspectRatio
        self.requiredRoles = requiredRoles
        self.requiredFeatures = requiredFeatures
    }

    public var normalized: ThumbleSkinCompatibility {
        var seenTemplates = Set<String>()
        let templates = templates.map(\.normalized).filter {
            !$0.templateID.isEmpty && seenTemplates.insert("\($0.templateID):\($0.minimumRevision):\($0.maximumRevision ?? Int.max)").inserted
        }
        let orientations = unique(self.orientations)
        let roles = unique(requiredRoles)
        let features = unique(requiredFeatures)
        let minimum = minimumAspectRatio.map { Self.clamp($0, lower: 0.25, upper: 4) }
        let maximum = maximumAspectRatio.map { Self.clamp($0, lower: minimum ?? 0.25, upper: 4) }
        return ThumbleSkinCompatibility(
            mode: mode,
            templates: templates,
            orientations: orientations,
            minimumAspectRatio: minimum,
            maximumAspectRatio: maximum,
            requiredRoles: roles,
            requiredFeatures: features,
            capturedGeometry: capturedGeometry
        )
    }

    private static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        guard value.isFinite else { return lower }
        return min(max(value, lower), upper)
    }

    private func unique<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }
}

public enum ThumbleSkinCompatibilityStatus: String, Codable, Equatable, Sendable {
    case compatible
    case degraded
    case incompatible
}

public struct ThumbleSkinCompatibilityIssue: Codable, Equatable, Sendable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct ThumbleSkinCompatibilityEvaluation: Codable, Equatable, Sendable {
    public var status: ThumbleSkinCompatibilityStatus
    public var issues: [ThumbleSkinCompatibilityIssue]

    public init(status: ThumbleSkinCompatibilityStatus, issues: [ThumbleSkinCompatibilityIssue] = []) {
        self.status = status
        self.issues = issues
    }

    public var allowsTemplateArtwork: Bool { status == .compatible }
}

public enum ThumbleSkinCompatibilityEvaluator {
    public static let supportedFeatures = Set(ThumbleSkinRenderingFeature.allCases)

    public static func evaluate(
        _ compatibility: ThumbleSkinCompatibility?,
        customization: GamepadCustomization,
        orientation: ThumbleSkinOrientation
    ) -> ThumbleSkinCompatibilityEvaluation {
        guard let compatibility else { return .init(status: .compatible) }
        let value = compatibility.normalized
        var issues: [ThumbleSkinCompatibilityIssue] = []
        var incompatible = false

        if !value.orientations.isEmpty, !value.orientations.contains(orientation) {
            issues.append(.init(code: "unsupported-orientation", message: "The skin does not provide \(orientation.rawValue) artwork."))
            incompatible = true
        }

        let size = customization.deviceCanvas.editorDeviceFrame.screenRect.size
        let aspect = max(size.width, 1) / max(size.height, 1)
        if let minimum = value.minimumAspectRatio, aspect < minimum {
            issues.append(.init(code: "aspect-ratio-too-small", message: "The keypad aspect ratio is below the skin's artwork range."))
            incompatible = true
        }
        if let maximum = value.maximumAspectRatio, aspect > maximum {
            issues.append(.init(code: "aspect-ratio-too-large", message: "The keypad aspect ratio is above the skin's artwork range."))
            incompatible = true
        }

        let controls = customization.resolvedControls(in: size).filter { !$0.layoutCustomization.isHidden }
        let roles = Set(controls.map(\.visualRole))
        for role in value.requiredRoles where !roles.contains(role) {
            issues.append(.init(code: "missing-role", message: "The keypad has no \(role.displayName.lowercased()) control required by the artwork."))
            incompatible = true
        }
        for feature in value.requiredFeatures where !supportedFeatures.contains(feature) {
            issues.append(.init(code: "missing-rendering-feature", message: "This app does not support \(feature.rawValue)."))
            incompatible = true
        }

        if value.mode == .capturedController {
            guard let captured = value.capturedGeometry, captured.matches(customization, orientation: orientation) else {
                issues.append(.init(code: "captured-geometry-mismatch", message: "The controller differs from the captured appearance contract; aligned artwork is hidden."))
                return .init(status: .incompatible, issues: issues)
            }
        }
        if value.mode == .templateAligned {
            let metadata = customization.designMetadata
            guard let templateID = metadata?.sourceTemplateID, let revision = metadata?.sourceTemplateRevision else {
                issues.append(.init(code: "unknown-template", message: "The keypad has no canonical template identity; semantic styling remains available but aligned artwork is hidden."))
                return .init(status: incompatible ? .incompatible : .degraded, issues: issues)
            }
            if !value.templates.isEmpty,
               !value.templates.contains(where: { $0.matches(templateID: templateID, revision: revision) }) {
                issues.append(.init(code: "template-mismatch", message: "The skin artwork targets a different canonical keypad template."))
                incompatible = true
            }
        }

        return .init(
            status: incompatible ? .incompatible : .compatible,
            issues: issues
        )
    }
}
