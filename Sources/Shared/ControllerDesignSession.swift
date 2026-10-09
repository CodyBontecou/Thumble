import Foundation
import Darwin
import CoreGraphics

/// Durable authoring state only. Runtime authority is supplied by the caller and is never
/// replaced by UserDefaults or a synthesized template inside this service.
public struct ControllerDesignSession: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public let schemaVersion: Int
    public let id: UUID
    public var revision: UInt64
    public let profileID: UUID
    public let targetRevision: UInt64
    public let draftID: UUID?
    public let draftRevision: UInt64?
    public var artboardSHA256: String
    public var profileSHA256: String
    public let bindingSHA256: String
    public var sourceSHA256: String
    public var sourceFiles: [FileDigest]?
    public var latestReview: Int?
    public var baseProfileSHA256: String? = nil
    public var layoutPlanSHA256: String? = nil

    public struct FileDigest: Codable, Equatable, Sendable {
        public let path: String
        public let byteCount: Int
        public let sha256: String
    }

    public struct FileEdit: Codable, Sendable {
        public let path: String
        /// nil deletes a source file; contract and evidence files are never editable here.
        public let data: Data?
        public init(path: String, data: Data?) { self.path = path; self.data = data }
    }

    public struct UpdateReceipt: Codable, Sendable {
        public let session: ControllerDesignSession
        public let changedFiles: [String]
        public let staleReviews: [Int]
    }

    /// Agent-authored observations, bound to immutable native evidence. Recording a verdict
    /// is provenance, not an automatic aesthetic or human publication approval.
    public struct Critique: Codable, Sendable {
        public let id: UUID
        public let review: Int
        public let evidenceSHA256: String
        public let reviewer: String
        public let stage: Stage
        public let verdict: Verdict
        public let issues: [Issue]

        public enum Stage: String, Codable, Sendable { case criticOne, criticTwo, qa }
        public enum Verdict: String, Codable, Sendable { case revise, pass, fail }
        public struct Issue: Codable, Sendable {
            public let id: String
            public let severity: Severity
            public let controlID: String?
            public let layerID: String?
            public let action: String?
            public let frameTitles: [String]
            public let observation: String
            public let requestedCorrection: String
            public var surfaceID: String? = nil
            public enum Severity: String, Codable, Sendable { case blocker, major, minor, note }
        }
    }

    public struct ReviewReceipt: Codable, Sendable {
        public let evidence: Review
        public let evidenceSHA256: String
        public init(evidence: Review) throws {
            self.evidence = evidence
            self.evidenceSHA256 = try ControllerDesignWorkspace.digest(evidence)
        }
    }

    public struct ControlEvidence: Codable, Sendable {
        public var nativeInk: GamepadNativeSurfaceInkEvidence? = nil
        public let id: String
        public let accessibilityLabel: String
        public let visualLegend: String
        public let kind: GamepadCustomControlKind
        public let frame: CGRect
        public let hitFrame: CGRect
        public let rotationDegrees: CGFloat
        public let state: GamepadControlPresentationState
        public let requested: GamepadButtonCustomization
        public let resolved: GamepadResolvedControlPresentation
        public let fallbacks: [String]
        public var nativeContent: GamepadNativeContentPresentation? = nil
        public var presentationMetadata: GamepadControlPresentation? = nil
        public var visualRole: GamepadVisualRole? = nil
    }

    public struct ReviewFrame: Codable, Sendable {
        public let title: String
        public let orientation: ThumbleSkinOrientation
        public let colorScheme: ThumbleSkinColorScheme
        public let state: GamepadControlPresentationState
        public let statesByControlID: [String: GamepadControlPresentationState]
        public let viewportWidth: CGFloat
        public let viewportHeight: CGFloat
        public let safeAreaInsets: ThumbleNormalizedInsets
        public let renderScale: CGFloat?
        public let canvasFill: GamepadFillStyle
        public let artworkLayers: [ThumbleSkinArtworkLayer]
        public let controls: [ControlEvidence]
        public let image: FileDigest
        public var showsSafeAreaOverlay: Bool? = nil
        public var showsTouchTargets: Bool? = nil
        public var showsBindingHints: Bool? = nil
    }

    /// Separate immutable bar evidence; no synthetic control UUIDs or guessed drawer frames.
    public final class ControlBarReview: Codable, @unchecked Sendable {
        public struct Frame: Codable, Sendable {
            public let title: String
            public let orientation: ThumbleSkinOrientation
            public let colorScheme: ThumbleSkinColorScheme
            public let isConnected: Bool
            public let isEditing: Bool
            public let isDefaultProfile: Bool
            public let profileName: String
            public let visibleItems: [GamepadControlBarItem]
            public let surfaceIDs: [String]
            public let viewportWidth: CGFloat
            public let viewportHeight: CGFloat
            public let renderScale: CGFloat
            public let image: FileDigest
            public var nativeLayout: GamepadNativeBarLayoutEvidence? = nil
            public var drawerLayoutInputs: GamepadTopBarDrawerLayout? = nil
            public var containerPresentation: GamepadNativeBarContainerPresentation? = nil
        }
        public let frames: [Frame]
        public let contactSheet: FileDigest
        public let scope: String
        init(frames: [Frame], contactSheet: FileDigest) {
            self.frames = frames; self.contactSheet = contactSheet
            scope = "expanded native bar at authored canvas width; connected/offline and editing on/off; default-profile flag false; native bar/item and legend/icon leaf layout frames measured; no drawer position, menus, intermediate connection states, practice/builder mode or device accessibility adaptations; glyph ink, paint-effect extents and hit frames unmeasured"
        }
    }

    /// Full-canvas native drawer scenes, separate from static controller-face evidence.
    public final class DrawerReview: Codable, Sendable {
        public struct Frame: Codable, Sendable {
            public let title: String
            public let orientation: ThumbleSkinOrientation
            public let colorScheme: ThumbleSkinColorScheme
            public let isConnected: Bool
            public let isEditing: Bool
            public let requestedVisibility: Bool
            public let resolvedVisibility: Bool
            public let collapsedOpacity: CGFloat
            public let surfaceIDs: [String]
            public let nativeLayout: GamepadNativeBarLayoutEvidence
            public let layoutInputs: GamepadTopBarDrawerLayout
            public let renderScale: CGFloat
            public let image: FileDigest
        }
        public let frames: [Frame]
        public let contactSheet: FileDigest
        public let scope: String
        init(frames: [Frame], contactSheet: FileDigest) {
            self.frames = frames; self.contactSheet = contactSheet
            scope = "settled native drawer over normal controller faces with static reveal omitted; expanded connected/offline and editing on/off, collapsed and fully faded connected nonediting; exact canvas and frozen safe areas, default-profile false; measured native layout in scene points; paint, hit geometry, menus, animation and device accessibility adaptations remain separate"
        }
    }

    /// One versioned diagnostic stream. Exact targets are native identities, never label guesses.
    public final class DiagnosticReport: Codable, Sendable {
        public struct Target: Codable, Hashable, Sendable {
            public let controlID: String?
            public let action: String?
            public let layerID: String?
            public let surfaceID: String?
        }
        public struct Issue: Codable, Sendable {
            public var id: String
            public let origin: String
            public let severity: String
            public let code: String
            public let message: String
            public let sourcePath: String?
            public let targets: [Target]
            public let frameTitles: [String]
            public let targetResolution: String
            public let suggestedRepairs: [String]
            public let metric: Double?
        }
        public let schemaVersion: Int
        public let issues: [Issue]
        public let scope: String
        init(issues: [Issue]) {
            schemaVersion = 1; self.issues = issues
            scope = "source, package/style and native layout diagnostics; targets use exact control/action/layer identities and reviewed style bindings; frame titles identify affected binding contexts, not pixel-based aesthetic judgments; global issues have no element target; unresolved paths remain explicit; ergonomic importance requires declared native roles; diagnostics cannot grant visual approval"
        }
    }

    public struct Review: Codable, Sendable {
        public let schemaVersion: Int
        public let number: Int
        public let sessionID: UUID
        public let sessionRevision: UInt64
        public let profileID: UUID
        public let targetRevision: UInt64
        public let draftID: UUID?
        public let draftRevision: UInt64?
        public let artboardSHA256: String
        public let profileSHA256: String
        public let bindingSHA256: String
        public let sourceSHA256: String
        public let rendererSHA256: String
        public let package: FileDigest
        public let contactSheet: FileDigest
        public let sourceFiles: [FileDigest]
        public let frames: [ReviewFrame]
        public let sourceDiagnostics: ThumbleSkinSourceValidationReport
        public let qualityDiagnostics: ThumbleSkinQualityReport
        /// Native pixels require independent aesthetic critique. Diagnostics cannot grant it.
        public let visualApproval: String
        public var baseProfileSHA256: String? = nil
        public var layoutPlanSHA256: String? = nil
        public var controlBar: ControlBarReview? = nil
        public var drawer: DrawerReview? = nil
        public var diagnostics: DiagnosticReport? = nil
    }
}

/// A typed geometry/native-presentation patch. Routing, legacy labels, control kind,
/// visibility and interaction settings remain outside appearance authoring.
public struct ControllerDesignLayoutEdit: Codable, Equatable, Sendable {
    public enum Variant: String, Codable, Sendable { case primary, landscape, portrait }
    public let variant: Variant
    public let controlID: String
    public var centerX: CGFloat?
    public var centerY: CGFloat?
    public var widthScale: CGFloat?
    public var heightScale: CGFloat?
    public var rotationDegrees: CGFloat?
    public var presentation: GamepadControlPresentation?
    public var clearPresentation: Bool
    public var visualRole: GamepadVisualRole?
    public var clearVisualRole: Bool

    public init(variant: Variant, controlID: String, centerX: CGFloat? = nil, centerY: CGFloat? = nil,
                widthScale: CGFloat? = nil, heightScale: CGFloat? = nil, rotationDegrees: CGFloat? = nil,
                presentation: GamepadControlPresentation? = nil, clearPresentation: Bool = false,
                visualRole: GamepadVisualRole? = nil, clearVisualRole: Bool = false) {
        self.variant = variant; self.controlID = controlID
        self.centerX = centerX; self.centerY = centerY; self.widthScale = widthScale
        self.heightScale = heightScale; self.rotationDegrees = rotationDegrees
        self.presentation = presentation; self.clearPresentation = clearPresentation
        self.visualRole = visualRole; self.clearVisualRole = clearVisualRole
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        let allowed = Set(["variant", "controlID", "centerX", "centerY", "widthScale", "heightScale", "rotationDegrees", "presentation", "clearPresentation", "visualRole", "clearVisualRole"])
        guard container.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
            throw ControllerDesignError.invalid("layout edits contain unsupported fields")
        }
        variant = try container.decode(Variant.self, forKey: .init("variant"))
        controlID = try container.decode(String.self, forKey: .init("controlID"))
        centerX = try container.decodeIfPresent(CGFloat.self, forKey: .init("centerX"))
        centerY = try container.decodeIfPresent(CGFloat.self, forKey: .init("centerY"))
        widthScale = try container.decodeIfPresent(CGFloat.self, forKey: .init("widthScale"))
        heightScale = try container.decodeIfPresent(CGFloat.self, forKey: .init("heightScale"))
        rotationDegrees = try container.decodeIfPresent(CGFloat.self, forKey: .init("rotationDegrees"))
        presentation = try container.decodeIfPresent(GamepadControlPresentation.self, forKey: .init("presentation"))
        clearPresentation = try container.decodeIfPresent(Bool.self, forKey: .init("clearPresentation")) ?? false
        visualRole = try container.decodeIfPresent(GamepadVisualRole.self, forKey: .init("visualRole"))
        clearVisualRole = try container.decodeIfPresent(Bool.self, forKey: .init("clearVisualRole")) ?? false
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(variant, forKey: .init("variant")); try c.encode(controlID, forKey: .init("controlID"))
        try c.encodeIfPresent(centerX, forKey: .init("centerX")); try c.encodeIfPresent(centerY, forKey: .init("centerY"))
        try c.encodeIfPresent(widthScale, forKey: .init("widthScale")); try c.encodeIfPresent(heightScale, forKey: .init("heightScale"))
        try c.encodeIfPresent(rotationDegrees, forKey: .init("rotationDegrees"))
        try c.encodeIfPresent(presentation, forKey: .init("presentation"))
        if clearPresentation { try c.encode(true, forKey: .init("clearPresentation")) }
        try c.encodeIfPresent(visualRole, forKey: .init("visualRole"))
        if clearVisualRole { try c.encode(true, forKey: .init("clearVisualRole")) }
    }
    private struct Key: CodingKey {
        let stringValue: String; let intValue: Int? = nil
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.init(stringValue) }
        init?(intValue: Int) { return nil }
    }
    public func validate() throws {
        let values = [centerX, centerY, widthScale, heightScale, rotationDegrees].compactMap { $0 }
        guard !controlID.isEmpty, controlID.utf8.count <= 128, (!values.isEmpty || presentation != nil || clearPresentation || visualRole != nil || clearVisualRole),
              !(visualRole != nil && clearVisualRole),
              presentation?.isValid ?? true, !(presentation != nil && clearPresentation),
              !(controlID.hasPrefix("system.") && (presentation != nil || clearPresentation || visualRole != nil || clearVisualRole)),
              values.allSatisfy(\.isFinite),
              [centerX, centerY].compactMap({ $0 }).allSatisfy({ (0...1).contains($0) }),
              [widthScale, heightScale].compactMap({ $0 }).allSatisfy({ (0.1...8).contains($0) }),
              rotationDegrees.map({ (-180...180).contains($0) }) ?? true else {
            throw ControllerDesignError.invalid("layout patch identity or geometry exceeds bounds")
        }
    }
    func overlaying(_ prior: Self) -> Self {
        .init(variant: variant, controlID: controlID, centerX: centerX ?? prior.centerX, centerY: centerY ?? prior.centerY,
            widthScale: widthScale ?? prior.widthScale, heightScale: heightScale ?? prior.heightScale,
            rotationDegrees: rotationDegrees ?? prior.rotationDegrees,
            presentation: clearPresentation ? nil : (presentation ?? prior.presentation),
            clearPresentation: presentation != nil ? false : (clearPresentation || prior.clearPresentation),
            visualRole: clearVisualRole ? nil : (visualRole ?? prior.visualRole),
            clearVisualRole: visualRole != nil ? false : (clearVisualRole || prior.clearVisualRole))
    }
}

public enum ControllerDesignLayout {
    public static func applying(_ edits: [ControllerDesignLayoutEdit], to source: GamepadConfigurationProfile) throws -> GamepadConfigurationProfile {
        guard edits.count <= 256 else { throw ControllerDesignError.invalid("layout plan exceeds control budget") }
        var profile = source
        for edit in edits {
            try edit.validate()
            var customization: GamepadCustomization
            switch edit.variant {
            case .primary: customization = profile.customization
            case .landscape:
                guard let authored = profile.landscapeCustomization else { throw ControllerDesignError.invalid("landscape slot is not authored; use primary for its fallback canvas") }
                customization = authored
            case .portrait:
                guard let authored = profile.portraitCustomization else { throw ControllerDesignError.invalid("portrait slot is not authored; use primary for its fallback canvas") }
                customization = authored
            }
            let controls = customization.resolvedControls(in: customization.deviceCanvas.editorDeviceFrame.screenRect.size)
            guard let control = controls.first(where: { $0.id.id == edit.controlID }) else {
                throw ControllerDesignError.invalid("layout patch must target an exact existing native control")
            }
            func patch(_ layout: inout GamepadButtonCustomization) {
                if let value = edit.centerX { layout.centerX = value }
                if let value = edit.centerY { layout.centerY = value }
                if let value = edit.widthScale { layout.widthScale = value }
                if let value = edit.heightScale { layout.heightScale = value }
                if let value = edit.rotationDegrees { layout.rotationDegrees = value }
            }
            switch control.id {
            case .builtin(let id):
                var layout = customization.buttonCustomization(for: id); patch(&layout)
                customization.setButtonCustomization(layout, for: id)
            case .custom(let id):
                try customization.mutateStandaloneCustomControl(id: id) { patch(&$0.layout) }
            case .system(.topBarActivation): patch(&customization.topBarActivationRegion)
            case .controlBarItem: throw ControllerDesignError.invalid("runtime bar layout is outside this artboard")
            }
            if edit.visualRole != nil || edit.clearVisualRole {
                let role = edit.clearVisualRole ? nil : edit.visualRole
                if case .custom(let id) = control.id {
                    try customization.mutateStandaloneCustomControl(id: id) { $0.visualRole = role }
                } else {
                    guard let id = customization.elementID(for: control.id),
                          let index = customization.elements.firstIndex(where: { $0.id == id }) else {
                        throw ControllerDesignError.invalid("visual-role patch requires an exact owned native element")
                    }
                    customization.elements[index].visualRole = role
                }
            }
            if edit.presentation != nil || edit.clearPresentation {
                guard let id = customization.elementID(for: control.id),
                      let index = customization.elements.firstIndex(where: { $0.id == id }) else {
                    throw ControllerDesignError.invalid("presentation patch requires an exact owned native element")
                }
                customization.elements[index].presentation = edit.clearPresentation ? nil : edit.presentation
            }
            switch edit.variant {
            case .primary: profile.customization = customization.normalized
            case .landscape: profile.landscapeCustomization = customization.normalized
            case .portrait: profile.portraitCustomization = customization.normalized
            }
        }
        return profile
    }
}

/// Pure evidence adapter; layout reports are gathered once per exact authored canvas.
enum ControllerDesignDiagnosticBuilder {
    typealias Report = ControllerDesignSession.DiagnosticReport
    struct LayoutInput {
        let orientation: ThumbleSkinOrientation
        let issues: [GamepadLayoutIssue]
    }
    struct StyleUse {
        let styleID: String
        let orientation: ThumbleSkinOrientation
        let colorScheme: ThumbleSkinColorScheme
        let target: Report.Target
        let frameTitle: String
    }
    static func build(source: ThumbleSkinSourceValidationReport, quality: ThumbleSkinQualityReport,
                      artboard: ThumbleSkinArtboard, frames: [ControllerDesignSession.ReviewFrame],
                      layouts: [LayoutInput], barStyles: [StyleUse] = [], workspace: ThumbleSkinWorkspace? = nil, skin: ThumbleSkin? = nil) throws -> Report {
        var result: [Report.Issue] = []
        var issueIDs = Set<String>()
        func key(_ orientation: ThumbleSkinOrientation, _ scheme: ThumbleSkinColorScheme) -> String {
            orientation.rawValue + "/" + scheme.rawValue
        }
        var styleOrigins: [String: [String: String]] = [:]
        for variant in artboard.variants {
            for scheme in ThumbleSkinColorScheme.allCases {
                styleOrigins[key(variant.orientation, scheme)] = skin?.styleSources(orientation: variant.orientation, colorScheme: scheme)
            }
        }
        func controlTarget(_ control: ControllerDesignSession.ControlEvidence) -> Report.Target {
            .init(controlID: control.id, action: control.presentationMetadata?.actionID
                    ?? workspace?.controlSemantics.first(where: { $0.controlID == control.id })?.action, layerID: nil, surfaceID: nil)
        }
        func append(origin: String, severity: String, code: String, message: String, path: String?,
                    targets: [Report.Target] = [], titles: [String] = [], resolution: String = "global",
                    repairs: [String] = [], metric: Double? = nil) throws {
            let ordered = Array(Set(targets)).sorted {
                ($0.controlID ?? "", $0.layerID ?? "", $0.surfaceID ?? "", $0.action ?? "")
                    < ($1.controlID ?? "", $1.layerID ?? "", $1.surfaceID ?? "", $1.action ?? "")
            }
            var issue = Report.Issue(id: "", origin: origin, severity: severity, code: code, message: message,
                sourcePath: path, targets: ordered, frameTitles: Array(Set(titles)).sorted(),
                targetResolution: resolution, suggestedRepairs: Array(Set(repairs)).sorted(), metric: metric)
            issue.id = try ControllerDesignWorkspace.digest(issue)
            guard !issueIDs.contains(issue.id) else { return }
            guard result.count < 4096 else { throw ControllerDesignError.invalid("combined diagnostics exceed 4096 issues") }
            issueIDs.insert(issue.id); result.append(issue)
        }
        for issue in source.issues {
            try append(origin: "source", severity: issue.severity.rawValue, code: issue.code,
                       message: issue.message, path: issue.path)
        }
        for issue in quality.issues {
            // The quality evaluator includes source validation; retain a single normalized copy.
            if issue.code.hasPrefix("source-"), source.issues.contains(where: {
                "source-" + $0.code == issue.code && $0.path == issue.path && $0.message == issue.message
            }) { continue }
            var targets: [Report.Target] = []
            var titles: [String] = []
            var resolution = "global"
            var eligible = frames
            if let variant = artboard.variants.first(where: { "artboard." + $0.id == issue.path }) {
                eligible = frames.filter { $0.orientation == variant.orientation }
            }
            if let target = issue.target {
                resolution = "unresolved"
                if let styleID = target.styleID {
                    let origin = target.appearanceID.map { "variant." + $0 } ?? "base"
                    for frame in eligible where styleOrigins[key(frame.orientation, frame.colorScheme)]?[styleID] == origin {
                        for control in frame.controls where control.requested.styleID == styleID {
                            targets.append(controlTarget(control)); titles.append(frame.title)
                        }
                    }
                    for use in barStyles where use.styleID == styleID
                        && styleOrigins[key(use.orientation, use.colorScheme)]?[styleID] == origin {
                        targets.append(use.target); titles.append(use.frameTitle)
                    }
                }
                for frame in eligible {
                    if let id = target.controlID, let control = frame.controls.first(where: { $0.id == id }) {
                        targets.append(controlTarget(control)); titles.append(frame.title)
                    }
                    if let id = target.layerID, frame.artworkLayers.contains(where: { $0.id == id }) {
                        targets.append(.init(controlID: nil, action: nil, layerID: id, surfaceID: nil)); titles.append(frame.title)
                    }
                }
            } else if let path = issue.path,
                      let component = workspace?.components.first(where: { "skin-source.json.components." + $0.id == path }) {
                resolution = "unresolved"
                for variant in artboard.variants {
                    let ids = Set(variant.controls.filter {
                        component.role == nil ? (component.button != nil && component.button == $0.inputID) : component.role == $0.visualRole
                    }.map(\.id))
                    for frame in eligible where frame.orientation == variant.orientation {
                        for control in frame.controls where ids.contains(control.id) {
                            targets.append(controlTarget(control)); titles.append(frame.title)
                        }
                    }
                }
            } else if let path = issue.path, path.hasPrefix("skin.json.styleLibrary.") {
                resolution = "unresolved"
                let id = String(path.dropFirst("skin.json.styleLibrary.".count))
                for frame in eligible {
                    for control in frame.controls where control.requested.styleID == id {
                        targets.append(controlTarget(control)); titles.append(frame.title)
                    }
                }
                for use in barStyles where use.styleID == id { targets.append(use.target); titles.append(use.frameTitle) }
            }
            if !targets.isEmpty { resolution = "exact" }
            try append(origin: "quality", severity: issue.severity.rawValue, code: issue.code,
                       message: issue.message, path: issue.path, targets: targets, titles: titles, resolution: resolution)
        }
        for layout in layouts {
            let eligible = frames.filter { $0.orientation == layout.orientation }
            for issue in layout.issues {
                var targets: [Report.Target] = []
                var titles: [String] = []
                for frame in eligible {
                    for control in frame.controls where issue.controls.contains(control.id) {
                        targets.append(controlTarget(control)); titles.append(frame.title)
                    }
                }
                let resolution = issue.controls.isEmpty ? "global" : (targets.isEmpty ? "unresolved" : "exact")
                try append(origin: "layout", severity: issue.severity.rawValue, code: issue.code,
                    message: issue.message, path: "contract/artboard.json#" + layout.orientation.rawValue,
                    targets: targets, titles: titles, resolution: resolution,
                    repairs: issue.suggestedRepairs.map(\.rawValue), metric: issue.metric)
            }
        }
        return Report(issues: result.sorted {
            if $0.severity != $1.severity { return $0.severity == "error" }
            return ($0.origin, $0.code, $0.id) < ($1.origin, $1.code, $1.id)
        })
    }
}

public enum ControllerDesignError: LocalizedError {
    case invalid(String)
    case conflict(String)
    case unsafePath(String)
    case staleEvidence(String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let reason): "Invalid controller design: \(reason)"
        case .conflict(let reason): "Controller design revision conflict: \(reason)"
        case .unsafePath(let path): "Controller design path is not permitted: \(path)"
        case .staleEvidence(let reason): "Controller design evidence is stale: \(reason)"
        case .io(let reason): "Controller design workspace failed: \(reason)"
        }
    }
}

public enum ControllerDesignWorkspace {
    public static let maximumSourceBytes = 16 * 1024 * 1024
    public static let maximumEditRequestBytes = 24 * 1024 * 1024
    public static let maximumFileBytes = 8 * 1024 * 1024
    public static let maximumSourceFiles = 128
    public static let sessionFile = "design-session.json"

    /// `bindings` is the authoritative binding snapshot supplied with this profile. It is
    /// frozen separately and never enters the CSS/artboard identity or rendered legend.
    @discardableResult
    public static func begin(
        profile: GamepadConfigurationProfile, bindings: Data, targetRevision: UInt64,
        safeAreas: [ThumbleSkinOrientation: ThumbleNormalizedInsets],
        name: String, identifier: String, at root: URL,
        draftID: UUID? = nil, draftRevision: UInt64? = nil
    ) throws -> ControllerDesignSession {
        try create(profile: profile, bindings: bindings, targetRevision: targetRevision, safeAreas: safeAreas,
            name: name, identifier: identifier, at: root, draftID: draftID, draftRevision: draftRevision, nativeCapture: nil)
    }

    private static func create(profile: GamepadConfigurationProfile, bindings: Data, targetRevision: UInt64,
        safeAreas: [ThumbleSkinOrientation: ThumbleNormalizedInsets], name: String, identifier: String, at root: URL,
        draftID: UUID?, draftRevision: UInt64?, nativeCapture: ((ThumbleSkinArtboard, GamepadConfigurationProfile) throws -> ThumbleSkinArtboard)?) throws -> ControllerDesignSession {
        try withLock(root) {
            let fm = FileManager.default
            guard !fm.fileExists(atPath: root.path) else {
                throw ControllerDesignError.conflict("destination already exists")
            }
            guard ThumbleSkinPackageValidator.isValidReverseDNSIdentifier(identifier) else {
                throw ControllerDesignError.invalid("package identifier must use reverse DNS")
            }
            guard bindings.count <= maximumFileBytes else { throw ControllerDesignError.invalid("binding snapshot exceeds budget") }
            let canonicalBindings = try PortableArtifactCanonicalizer.canonicalizeJSON(bindings)
            let id = UUID()
            let geometry = try ThumbleSkinArtboard.capture(profile: profile,
                identifier: "captured-\(profile.id.uuidString.lowercased())", safeAreas: safeAreas)
            let artboard = try nativeCapture?(geometry, profile) ?? geometry
            let artboardData = try canonicalData(artboard)
            let profileData = try canonicalData(profile)
            guard artboardData.count <= maximumFileBytes else { throw ControllerDesignError.invalid("artboard exceeds file budget") }
            guard profileData.count <= maximumFileBytes else { throw ControllerDesignError.invalid("profile exceeds budget") }
            var workspace = ThumbleSkinWorkspace.starterCSS(name: name, identifier: identifier, artboardID: artboard.id)
            workspace.schemaVersion = 3
            workspace.capturedArtboards = [artboard]
            workspace.orientations = artboard.variants.map(\.orientation)
            workspace.previews = workspace.previews.filter { workspace.orientations.contains($0.orientation) }
            let validation = ThumbleSkinSourceValidator.validate(workspace)
            guard validation.isValid else { throw ThumbleSkinCompilerError.invalidSource(validation) }
            let staging = stagingURL(root)
            defer { try? fm.removeItem(at: staging) }
            for path in ["contract", "styles", "sources", "reviews"] {
                try fm.createDirectory(at: staging.appendingPathComponent(path), withIntermediateDirectories: true)
            }
            try artboardData.write(to: staging.appendingPathComponent("contract/artboard.json"))
            try profileData.write(to: staging.appendingPathComponent("contract/profile.json"))
            try canonicalBindings.write(to: staging.appendingPathComponent("contract/bindings.json"))
            let workspaceData = try canonicalData(workspace)
            guard workspaceData.count <= maximumFileBytes else { throw ControllerDesignError.invalid("workspace exceeds file budget") }
            try workspaceData.write(to: staging.appendingPathComponent("skin-source.json"))
            try Data("control { background: #EFEDE7; color: #272A30; border: 1px solid #777A80; }\n".utf8)
                .write(to: staging.appendingPathComponent("styles/controller.css"))
            let source = try sourceDigests(at: staging)
            let session = ControllerDesignSession(schemaVersion: 1, id: id, revision: 1, profileID: profile.id,
                targetRevision: targetRevision, draftID: draftID, draftRevision: draftRevision, artboardSHA256: artboardData.thumbleSHA256,
                profileSHA256: profileData.thumbleSHA256, bindingSHA256: canonicalBindings.thumbleSHA256,
                sourceSHA256: try digest(source), sourceFiles: source, latestReview: nil)
            try write(session, to: staging.appendingPathComponent(sessionFile))
            try fm.moveItem(at: staging, to: root)
            return session
        }
    }

    public struct Inspection: Codable, Sendable {
        public let session: ControllerDesignSession
        public let artboard: ThumbleSkinArtboard
        public let cssAliases: [String: String]
        public let controlSemantics: [ThumbleSkinControlSemantics]
        public let sourceFiles: [ControllerDesignSession.FileDigest]
        public let sourceSynchronized: Bool
        public let capabilities: ControllerDesignCapabilities
    }

    public static func inspect(at root: URL) throws -> Inspection {
        try withLock(root) {
            let session = try load(at: root)
            let workspace = try JSONDecoder().decodeUnique(ThumbleSkinWorkspace.self,
                from: boundedData(root.appendingPathComponent("skin-source.json"), root: root))
            let artboard = try JSONDecoder().decodeUnique(ThumbleSkinArtboard.self,
                from: boundedData(root.appendingPathComponent("contract/artboard.json"), root: root))
            let sources = try sourceDigests(at: root)
            let aliases = artboard.variants.flatMap { $0.controls }.reduce(into: [String: String]()) {
                $0[$1.id] = ThumbleCSSDocumentBuilder.kebabIdentifier($1.id)
            }
            return Inspection(session: session, artboard: artboard, cssAliases: aliases,
                controlSemantics: workspace.controlSemantics, sourceFiles: sources,
                sourceSynchronized: try digest(sources) == session.sourceSHA256, capabilities: .current)
        }
    }

    public static func load(at root: URL) throws -> ControllerDesignSession {
        let data = try boundedData(root.appendingPathComponent(sessionFile), root: root)
        let session = try JSONDecoder().decodeUnique(ControllerDesignSession.self, from: data)
        guard session.schemaVersion == ControllerDesignSession.schemaVersion else {
            throw ControllerDesignError.invalid("unsupported session schema")
        }
        for (path, expected) in [("contract/artboard.json", session.artboardSHA256),
                                 ("contract/profile.json", session.profileSHA256),
                                 ("contract/bindings.json", session.bindingSHA256)] {
            guard try boundedData(root.appendingPathComponent(path), root: root).thumbleSHA256 == expected else {
                throw ControllerDesignError.conflict("frozen contract changed: \(path)")
            }
        }
        if let base = session.baseProfileSHA256, let plan = session.layoutPlanSHA256 {
            guard try boundedData(root.appendingPathComponent("contract/base-profile.json"), root: root).thumbleSHA256 == base,
                  try boundedData(root.appendingPathComponent("contract/layout-edits.json"), root: root).thumbleSHA256 == plan else {
                throw ControllerDesignError.conflict("frozen base profile or layout plan changed")
            }
        } else if session.baseProfileSHA256 != nil || session.layoutPlanSHA256 != nil {
            throw ControllerDesignError.invalid("layout plan and base profile must be supplied together")
        }
        return session
    }

    /// Source edits are validated in a private copy then swapped in one filesystem operation.
    /// Direct editor changes are synchronized by calling update with an empty edits array.
    public static func update(at root: URL, expectedRevision: UInt64,
                              edits: [ControllerDesignSession.FileEdit], layoutEdits: [ControllerDesignLayoutEdit] = []) throws -> ControllerDesignSession.UpdateReceipt {
        try revise(at: root, expectedRevision: expectedRevision, edits: edits, layoutEdits: layoutEdits, nativeCapture: nil)
    }

    private static func revise(at root: URL, expectedRevision: UInt64,
        edits: [ControllerDesignSession.FileEdit], layoutEdits: [ControllerDesignLayoutEdit],
        nativeCapture: ((ThumbleSkinArtboard, GamepadConfigurationProfile) throws -> ThumbleSkinArtboard)?) throws -> ControllerDesignSession.UpdateReceipt {
        try withLock(root) {
            var session = try load(at: root)
            guard session.revision == expectedRevision else { throw ControllerDesignError.conflict("expected \(expectedRevision), found \(session.revision)") }
            guard session.revision < UInt64.max else { throw ControllerDesignError.invalid("revision exhausted") }
            guard layoutEdits.count <= 256 else { throw ControllerDesignError.invalid("layout update exceeds budget") }
            guard edits.count <= maximumSourceFiles, Set(edits.map(\.path)).count == edits.count else {
                throw ControllerDesignError.invalid("too many edits or duplicate paths")
            }
            for edit in edits {
                guard editablePath(edit.path), (edit.data?.count ?? 0) <= maximumFileBytes else {
                    throw ControllerDesignError.unsafePath(edit.path)
                }
            }
            let currentFiles = try sourceDigests(at: root)
            let before = session.sourceFiles ?? currentFiles
            let staging = stagingURL(root)
            let fm = FileManager.default
            defer { try? fm.removeItem(at: staging) }
            try rejectSymlinks(at: root)
            try fm.copyItem(at: root, to: staging)
            for edit in edits {
                let file = staging.appendingPathComponent(edit.path)
                if let data = edit.data {
                    try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: file, options: .atomic)
                } else if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
            }
            let previousLayoutHash = session.layoutPlanSHA256
            if !layoutEdits.isEmpty { try updateLayout(at: staging, session: &session, edits: layoutEdits, nativeCapture: nativeCapture) }
            let loaded = try ThumbleSkinCompiler.loadWorkspace(from: staging)
            let artboard = try JSONDecoder().decodeUnique(ThumbleSkinArtboard.self,
                from: boundedData(staging.appendingPathComponent("contract/artboard.json"), root: staging))
            guard loaded.workspace.capturedArtboards == [artboard], loaded.workspace.artboardID == artboard.id else {
                throw ControllerDesignError.conflict("source cannot replace the frozen artboard")
            }
            let report = ThumbleSkinSourceValidator.validate(loaded.workspace)
            guard report.isValid else { throw ThumbleSkinCompilerError.invalidSource(report) }
            if loaded.workspace.usesCSSAuthoring {
                _ = try ThumbleCSSCompiler.compile(workspace: loaded.workspace, sourceRoot: staging)
            }
            let after = try sourceDigests(at: staging)
            let nextDigest = try digest(after)
            let changed = Set(before.map(\.path)).union(after.map(\.path)).filter { path in
                before.first { $0.path == path } != after.first { $0.path == path }
            }.sorted()
            let contractChanged = previousLayoutHash != session.layoutPlanSHA256
            let stale = nextDigest == session.sourceSHA256 && !contractChanged ? [] : try reviewNumbers(at: staging)
            if nextDigest != session.sourceSHA256 || contractChanged {
                session.revision += 1
                session.sourceSHA256 = nextDigest
                session.sourceFiles = after
                session.latestReview = nil
            }
            try write(session, to: staging.appendingPathComponent(sessionFile))
            try swap(staging, root)
            return .init(session: session, changedFiles: changed + (contractChanged ? ["contract/artboard.json", "contract/profile.json", "contract/layout-edits.json"] : []), staleReviews: stale)
        }
    }

    private static func updateLayout(at root: URL, session: inout ControllerDesignSession, edits: [ControllerDesignLayoutEdit],
        nativeCapture: ((ThumbleSkinArtboard, GamepadConfigurationProfile) throws -> ThumbleSkinArtboard)?) throws {
        var plan: [ControllerDesignLayoutEdit] = []
        let profileURL = root.appendingPathComponent("contract/profile.json")
        let baseURL = root.appendingPathComponent("contract/base-profile.json")
        let planURL = root.appendingPathComponent("contract/layout-edits.json")
        let fm = FileManager.default
        let baseData: Data
        if session.baseProfileSHA256 != nil {
            baseData = try boundedData(baseURL, root: root)
            plan = try JSONDecoder().decodeUnique([ControllerDesignLayoutEdit].self, from: boundedData(planURL, root: root))
        } else { baseData = try boundedData(profileURL, root: root) }
        for edit in edits {
            try edit.validate()
            if let index = plan.firstIndex(where: { $0.variant == edit.variant && $0.controlID == edit.controlID }) {
                plan[index] = edit.overlaying(plan[index])
            } else { plan.append(edit) }
        }
        guard plan.count <= 256 else { throw ControllerDesignError.invalid("cumulative layout plan exceeds budget") }
        plan.sort { ($0.variant.rawValue, $0.controlID) < ($1.variant.rawValue, $1.controlID) }
        let base = try JSONDecoder().decodeUnique(GamepadConfigurationProfile.self, from: baseData)
        let profile = try ControllerDesignLayout.applying(plan, to: base)
        let oldArtboard = try JSONDecoder().decodeUnique(ThumbleSkinArtboard.self,
            from: boundedData(root.appendingPathComponent("contract/artboard.json"), root: root))
        let safeAreas = Dictionary(uniqueKeysWithValues: oldArtboard.variants.map { ($0.orientation, $0.safeAreaInsets) })
        guard nativeCapture != nil || oldArtboard.variants.allSatisfy({ $0.nativeLayout == nil }) else {
            throw ControllerDesignError.invalid("measured contracts require native layout recapture")
        }
        let geometry = try ThumbleSkinArtboard.capture(profile: profile, identifier: oldArtboard.id, safeAreas: safeAreas)
        let artboard = try nativeCapture?(geometry, profile) ?? geometry
        var workspace = try JSONDecoder().decodeUnique(ThumbleSkinWorkspace.self,
            from: boundedData(root.appendingPathComponent("skin-source.json"), root: root))
        guard workspace.capturedArtboards == [oldArtboard] else { throw ControllerDesignError.conflict("source cannot replace the captured artboard") }
        let history = root.appendingPathComponent("reviews/contracts/revision-\(session.revision)")
        if !fm.fileExists(atPath: history.path) {
            try fm.createDirectory(at: history, withIntermediateDirectories: true)
            try boundedData(profileURL, root: root).write(to: history.appendingPathComponent("profile.json"))
            try canonicalData(oldArtboard).write(to: history.appendingPathComponent("artboard.json"))
            try write(session, to: history.appendingPathComponent("session.json"))
        }
        let profileData = try canonicalData(profile)
        let artboardData = try canonicalData(artboard)
        let planData = try canonicalData(plan)
        guard profileData.count <= maximumFileBytes, artboardData.count <= maximumFileBytes else {
            throw ControllerDesignError.invalid("replacement contract exceeds file budget")
        }
        guard planData.count <= 64 * 1024 else { throw ControllerDesignError.invalid("layout plan exceeds byte budget") }
        try baseData.write(to: baseURL)
        try profileData.write(to: profileURL)
        try artboardData.write(to: root.appendingPathComponent("contract/artboard.json"))
        try planData.write(to: planURL)
        workspace.capturedArtboards = [artboard]
        let workspaceData = try canonicalData(workspace)
        guard workspaceData.count <= maximumFileBytes else { throw ControllerDesignError.invalid("replacement workspace exceeds file budget") }
        try workspaceData.write(to: root.appendingPathComponent("skin-source.json"))
        session.baseProfileSHA256 = baseData.thumbleSHA256
        session.layoutPlanSHA256 = planData.thumbleSHA256
        session.profileSHA256 = profileData.thumbleSHA256
        session.artboardSHA256 = artboardData.thumbleSHA256
    }

    public static func recordCritique(at root: URL, expectedRevision: UInt64,
                                     rendererSHA256: String, critique: ControllerDesignSession.Critique) throws -> String {
        // Perform the expensive evidence verification before taking the recording lock;
        // verify revision/source and manifest again under that lock before writing.
        let review = try reviewedCandidate(at: root, number: critique.review, expectedRevision: expectedRevision,
            rendererSHA256: rendererSHA256, evidenceSHA256: critique.evidenceSHA256)
        return try withLock(root) {
            let session = try load(at: root)
            guard session.revision == expectedRevision, try digest(sourceDigests(at: root)) == review.sourceSHA256,
                  try boundedData(root.appendingPathComponent("reviews/review-\(critique.review)/manifest.json"), root: root)
                    .count <= maximumFileBytes else { throw ControllerDesignError.staleEvidence("source changed during critique") }
            let current = try JSONDecoder().decodeUnique(ControllerDesignSession.Review.self,
                from: boundedData(root.appendingPathComponent("reviews/review-\(critique.review)/manifest.json"), root: root))
            guard try digest(current) == critique.evidenceSHA256 else { throw ControllerDesignError.staleEvidence("manifest changed during critique") }
            for file in [current.package, current.contactSheet] + current.frames.map(\.image)
                + (current.controlBar.map { [$0.contactSheet] + $0.frames.map(\.image) } ?? [])
                + (current.drawer.map { [$0.contactSheet] + $0.frames.map(\.image) } ?? []) {
                let bytes = try boundedData(root.appendingPathComponent(file.path), root: root)
                guard bytes.count == file.byteCount, bytes.thumbleSHA256 == file.sha256 else {
                    throw ControllerDesignError.staleEvidence("review pixels or package changed during critique")
                }
            }
            func validText(_ value: String, limit: Int) -> Bool {
                !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= limit
                    && !value.unicodeScalars.contains { $0.value < 32 && $0.value != 10 && $0.value != 9 }
            }
            guard validText(critique.reviewer, limit: 128), critique.issues.count <= 128,
                  Set(critique.issues.map(\.id)).count == critique.issues.count else {
                throw ControllerDesignError.invalid("critique reviewer or issue count/identities exceed bounds")
            }
            let controls = Set(review.frames.flatMap { $0.controls.map(\.id) })
            let layers = Set(review.frames.flatMap { $0.artworkLayers.map(\.id) }
                + (review.controlBar == nil ? [] : ["native-control-bar"])
                + (review.drawer == nil ? [] : ["native-drawer"]))
            let titles = Set(review.frames.map(\.title) + (review.controlBar?.frames.map(\.title) ?? [])
                + (review.drawer?.frames.map(\.title) ?? []))
            let workspace = try JSONDecoder().decodeUnique(ThumbleSkinWorkspace.self,
                from: boundedData(root.appendingPathComponent("skin-source.json"), root: root))
            let actions = Set(workspace.controlSemantics.compactMap(\.action)
                + review.frames.flatMap { $0.controls.compactMap { $0.presentationMetadata?.actionID } })
            for issue in critique.issues {
                guard validText(issue.id, limit: 64), validText(issue.observation, limit: 2048),
                      validText(issue.requestedCorrection, limit: 2048),
                      issue.controlID.map({ controls.contains($0) }) ?? true,
                      issue.layerID.map({ layers.contains($0) }) ?? true,
                      issue.action.map({ actions.contains($0) }) ?? true,
                      issue.frameTitles.count <= review.frames.count + (review.controlBar?.frames.count ?? 0) + (review.drawer?.frames.count ?? 0),
                      Set(issue.frameTitles).count == issue.frameTitles.count,
                      issue.frameTitles.allSatisfy({ titles.contains($0) }) else {
                    throw ControllerDesignError.invalid("critique issues require bounded text and exact review targets")
                }
                if let surface = issue.surfaceID {
                    let affected = review.frames.filter { issue.frameTitles.isEmpty || issue.frameTitles.contains($0.title) }
                    let affectedBars = review.controlBar?.frames.filter { issue.frameTitles.isEmpty || issue.frameTitles.contains($0.title) } ?? []
                    let affectedDrawers = review.drawer?.frames.filter { issue.frameTitles.isEmpty || issue.frameTitles.contains($0.title) } ?? []
                    guard issue.controlID.map({ surface.hasPrefix($0 + "/") }) ?? true,
                          affected.allSatisfy({ frame in
                              frame.controls.contains { control in
                                  control.nativeContent?.visibleSurfaceIDs.contains(where: { control.id + "/" + $0 == surface }) == true
                              }
                          }), affectedBars.allSatisfy({ $0.surfaceIDs.contains(surface) }),
                          affectedDrawers.allSatisfy({ $0.surfaceIDs.contains(surface) }) else {
                        throw ControllerDesignError.invalid("critique surface must be visible in every affected review frame")
                    }
                }
            }
            let directory = root.appendingPathComponent("reviews/critique-records")
            let fm = FileManager.default
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let prior = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
            guard prior.count < 128 else { throw ControllerDesignError.invalid("critique record budget exhausted") }
            let reports = try prior.map { try JSONDecoder().decodeUnique(ControllerDesignSession.Critique.self, from: boundedData($0, root: root)) }
            let earlierStages: [ControllerDesignSession.Critique.Stage] = switch critique.stage {
            case .criticOne: []
            case .criticTwo: [.criticOne]
            case .qa: [.criticOne, .criticTwo]
            }
            for stage in earlierStages {
                guard reports.contains(where: { $0.stage == stage && $0.reviewer != critique.reviewer }) else {
                    throw ControllerDesignError.invalid("\(critique.stage.rawValue) requires an earlier independent \(stage.rawValue) record")
                }
            }
            let path = "reviews/critique-records/\(critique.id.uuidString.lowercased()).json"
            let file = root.appendingPathComponent(path)
            let data = try canonicalData(critique)
            guard data.count <= 128 * 1024 else { throw ControllerDesignError.invalid("critique exceeds byte budget") }
            guard !fm.fileExists(atPath: file.path) else { throw ControllerDesignError.conflict("critique ID is immutable") }
            try data.write(to: file, options: .withoutOverwriting)
            return path
        }
    }

    public static func sourceDigests(at root: URL) throws -> [ControllerDesignSession.FileDigest] {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        var paths = ["skin-source.json"]
        let fm = FileManager.default
        for directory in ["styles", "sources"] {
            let base = root.appendingPathComponent(directory)
            if !fm.fileExists(atPath: base.path) { continue }
            guard let enumerator = fm.enumerator(at: base, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey]) else {
                throw ControllerDesignError.io("cannot enumerate \(directory)")
            }
            for case let file as URL in enumerator {
                let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
                guard values.isSymbolicLink != true else { throw ControllerDesignError.unsafePath(file.path) }
                if values.isRegularFile == true {
                    let path = String(file.standardizedFileURL.resolvingSymlinksInPath().path.dropFirst(root.path.count + 1))
                    guard editablePath(path) else { throw ControllerDesignError.unsafePath(path) }
                    paths.append(path)
                    guard paths.count <= maximumSourceFiles else { throw ControllerDesignError.invalid("source file count exceeds budget") }
                }
            }
        }
        var total = 0
        let files = try paths.sorted().map { path in
            let data = try boundedData(root.appendingPathComponent(path), root: root)
            total += data.count
            guard total <= maximumSourceBytes else { throw ControllerDesignError.invalid("source exceeds byte budget") }
            return ControllerDesignSession.FileDigest(path: path, byteCount: data.count, sha256: data.thumbleSHA256)
        }
        return files
    }

    /// Validate everything that identifies an exact reviewed candidate before a caller enters
    /// its authoritative compare-and-swap transaction. This never mutates runtime state.
    public static func reviewedCandidate(at root: URL, number: Int, expectedRevision: UInt64,
                                          rendererSHA256: String, evidenceSHA256: String) throws -> ControllerDesignSession.Review {
        try withLock(root) {
            let session = try load(at: root)
            guard session.revision == expectedRevision else { throw ControllerDesignError.conflict("session revision changed") }
            let path = "reviews/review-\(number)/manifest.json"
            let review = try JSONDecoder().decodeUnique(ControllerDesignSession.Review.self,
                from: boundedData(root.appendingPathComponent(path), root: root))
            guard try digest(review) == evidenceSHA256 else { throw ControllerDesignError.staleEvidence("evidence manifest changed") }
            guard review.schemaVersion == 1, review.number == number, review.sessionID == session.id,
                  review.sessionRevision == session.revision,
                  review.profileID == session.profileID, review.targetRevision == session.targetRevision,
                  review.draftID == session.draftID, review.draftRevision == session.draftRevision,
                  review.artboardSHA256 == session.artboardSHA256, review.profileSHA256 == session.profileSHA256,
                  review.bindingSHA256 == session.bindingSHA256,
                  review.baseProfileSHA256 == session.baseProfileSHA256, review.layoutPlanSHA256 == session.layoutPlanSHA256,
                  review.sourceSHA256 == session.sourceSHA256,
                  review.sourceSHA256 == (try digest(sourceDigests(at: root))),
                  review.rendererSHA256 == rendererSHA256 else {
                throw ControllerDesignError.staleEvidence("contract, source, revision, or renderer changed")
            }
            let barFiles = review.controlBar.map { [$0.contactSheet] + $0.frames.map(\.image) } ?? []
            let drawerFiles = review.drawer.map { [$0.contactSheet] + $0.frames.map(\.image) } ?? []
            for file in [review.package, review.contactSheet] + review.frames.map(\.image) + barFiles + drawerFiles {
                guard ThumbleSkinPackageCodec.isSafePackagePath(file.path), file.path.hasPrefix("reviews/review-\(number)/") else {
                    throw ControllerDesignError.unsafePath(file.path)
                }
                let data = try boundedData(root.appendingPathComponent(file.path), root: root)
                guard data.count == file.byteCount, data.thumbleSHA256 == file.sha256 else {
                    throw ControllerDesignError.staleEvidence("reviewed file changed: \(file.path)")
                }
            }
            return review
        }
    }

    static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        try PortableArtifactCanonicalizer.canonicalizeJSON(JSONEncoder().encode(value))
    }
    static func digest<T: Encodable>(_ value: T) throws -> String { try canonicalData(value).thumbleSHA256 }
    static func write<T: Encodable>(_ value: T, to file: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= maximumFileBytes else { throw ControllerDesignError.invalid("workspace JSON exceeds file byte budget") }
        try data.write(to: file, options: .atomic)
    }
    static func reviewNumbers(at root: URL) throws -> [Int] {
        try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("reviews").path)
            .compactMap { $0.hasPrefix("review-") ? Int($0.dropFirst(7)) : nil }.sorted()
    }
    static func boundedData(_ file: URL, root: URL) throws -> Data {
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedFile = file.standardizedFileURL.resolvingSymlinksInPath()
        guard resolvedFile.path.hasPrefix(resolvedRoot.path + "/"),
              resolvedFile.path == resolvedRoot.appendingPathComponent(String(file.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))).path else { throw ControllerDesignError.unsafePath(file.path) }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= maximumFileBytes else {
            throw ControllerDesignError.invalid("file exceeds budget or is not regular: \(file.lastPathComponent)")
        }
        let data = try Data(contentsOf: file)
        guard data.count <= maximumFileBytes else { throw ControllerDesignError.invalid("file changed beyond budget") }
        return data
    }
    private static func editablePath(_ path: String) -> Bool {
        guard ThumbleSkinPackageCodec.isSafePackagePath(path) else { return false }
        if path == "skin-source.json" { return true }
        if path.hasPrefix("styles/") { return path.hasSuffix(".css") }
        if path.hasPrefix("sources/") { return ["svg", "png", "json"].contains(URL(fileURLWithPath: path).pathExtension) }
        return false
    }
    private static func stagingURL(_ root: URL) -> URL {
        root.deletingLastPathComponent().appendingPathComponent(".\(root.lastPathComponent).staging-\(UUID().uuidString)")
    }
    private static func rejectSymlinks(at root: URL) throws {
        guard try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw ControllerDesignError.unsafePath(root.path) }
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { throw ControllerDesignError.io("cannot enumerate workspace") }
        for case let file as URL in files {
            if try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw ControllerDesignError.unsafePath(file.path) }
        }
    }
    private static func swap(_ staging: URL, _ root: URL) throws {
        guard renamex_np(staging.path, root.path, UInt32(RENAME_SWAP)) == 0 else { throw ControllerDesignError.io("atomic workspace replacement failed (\(errno))") }
    }
    static func withLock<T>(_ root: URL, _ action: () throws -> T) throws -> T {
        let parent = root.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let path = parent.appendingPathComponent(".\(root.lastPathComponent).design-lock").path
        let descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw ControllerDesignError.io("cannot open session lock") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw ControllerDesignError.io("cannot lock session") }
        defer { flock(descriptor, LOCK_UN) }
        return try action()
    }
}

#if os(macOS)
import SwiftUI
extension ControllerDesignWorkspace {
    @MainActor
    private static func controlEvidence(customization: GamepadCustomization, variant: ThumbleSkinArtboardVariant,
                                        scheme: ThumbleSkinColorScheme, state: GamepadControlPresentationState,
                                        overrides: [String: GamepadControlPresentationState], renderScale: CGFloat,
                                        secondaryBindingTexts: [String: String] = [:]) throws -> [ControllerDesignSession.ControlEvidence] {
        let rendered = customization.resolvingAssetReferences().normalized
        let size = CGSize(width: variant.canvasWidth, height: variant.canvasHeight)
        return try rendered.resolvedControls(in: size).map { control in
            let controlState = overrides[control.id.id] ?? state
            let appearance = rendered.resolvedPresentation(for: control, state: controlState,
                                                           scheme: scheme == .dark ? .dark : .light)
            var fallbacks: [String] = []
            let layout = control.layoutCustomization
            if layout.styleID == nil && layout.visualStyle == nil { fallbacks.append("native-baseline-appearance") }
            if let styleID = layout.styleID, rendered.styleLibrary.style(id: styleID) == nil {
                fallbacks.append("missing-style-token: " + styleID)
            }
            if let styleID = layout.styleID, let token = rendered.styleLibrary.style(id: styleID),
               !token.appliesTo.contains(control.controlKind) { fallbacks.append("incompatible-style-token: " + styleID) }
            let native = GamepadNativeContentPresentation(control: control, showsButtonLabels: rendered.showsButtonLabels,
                                                        content: appearance.content, icon: appearance.icon,
                                                        state: controlState, scheme: scheme == .dark ? .dark : .light,
                                                        authoredScale: appearance.scale, foregroundColor: appearance.foregroundColor,
                                                        profileAccentStyle: rendered.accentStyle, secondaryBindingText: secondaryBindingTexts[control.id.id])
            fallbacks.append(contentsOf: native.fallbacks)
            if let icon = appearance.icon, icon.source == .asset, rendered.assetLibrary.asset(id: icon.value) == nil {
                fallbacks.append("missing-icon-asset-placeholder: " + icon.value)
            }
            let ink = try ThumbleNativeSkinPreviewRenderer.surfaceInk(control: control, customization: rendered,
                state: controlState, scheme: scheme == .dark ? .dark : .light, canvasSize: size,
                scale: renderScale, surfaces: native.nativeFlowSurfaceIDs, secondaryBindingText: secondaryBindingTexts[control.id.id])
            var evidence = ControllerDesignSession.ControlEvidence(id: control.id.id, accessibilityLabel: control.accessibilityName,
                         visualLegend: appearance.content?.legend ?? control.visualLegend, kind: control.controlKind,
                         frame: control.frame, hitFrame: control.hitFrame, rotationDegrees: control.rotationDegrees,
                         state: controlState, requested: layout, resolved: appearance, fallbacks: fallbacks,
                         nativeContent: native, presentationMetadata: control.presentationMetadata)
            evidence.visualRole = control.visualRole
            evidence.nativeInk = ink
            return evidence
        }
    }

    /// Agent-facing capture includes native measurements. The pure snapshot/encoding path
    /// above remains available for constrained-thread geometry and compiler work.
    @MainActor
    public static func beginNative(profile: GamepadConfigurationProfile, bindings: Data, targetRevision: UInt64,
        safeAreas: [ThumbleSkinOrientation: ThumbleNormalizedInsets], name: String, identifier: String, at root: URL,
        draftID: UUID? = nil, draftRevision: UInt64? = nil, rendererSHA256: String) throws -> ControllerDesignSession {
        try create(profile: profile, bindings: bindings, targetRevision: targetRevision, safeAreas: safeAreas,
            name: name, identifier: identifier, at: root, draftID: draftID, draftRevision: draftRevision,
            nativeCapture: { board, profile in try MainActor.assumeIsolated {
                try captureNativeLayout(artboard: board, profile: profile, rendererSHA256: rendererSHA256)
            } })
    }

    @MainActor
    public static func updateNative(at root: URL, expectedRevision: UInt64, edits: [ControllerDesignSession.FileEdit],
        layoutEdits: [ControllerDesignLayoutEdit] = [], rendererSHA256: String) throws -> ControllerDesignSession.UpdateReceipt {
        try revise(at: root, expectedRevision: expectedRevision, edits: edits, layoutEdits: layoutEdits,
            nativeCapture: { board, profile in try MainActor.assumeIsolated {
                try captureNativeLayout(artboard: board, profile: profile, rendererSHA256: rendererSHA256)
            } })
    }

    @MainActor
    static func captureNativeLayout(artboard: ThumbleSkinArtboard, profile: GamepadConfigurationProfile,
                                    rendererSHA256: String) throws -> ThumbleSkinArtboard {
        guard rendererSHA256.count == 64, rendererSHA256.allSatisfy({ $0.isHexDigit }),
              artboard.variants.count <= 2, artboard.variants.allSatisfy({ $0.controls.count <= 128 }) else {
            throw ControllerDesignError.invalid("native baseline capture identity or control budget")
        }
        var result = artboard
        for index in result.variants.indices {
            let variant = result.variants[index]
            let orientation: GamepadEditorDeviceOrientation = variant.orientation == .portrait ? .portrait : .landscape
            let customization = profile.customization(for: orientation).resolvingAssetReferences().normalized
            let size = CGSize(width: variant.canvasWidth, height: variant.canvasHeight)
            let controls = customization.resolvedControls(in: size).filter { !$0.layoutCustomization.isHidden }
            guard Set(controls.map { $0.id.id }) == Set(variant.controls.map(\.id)) else {
                throw ControllerDesignError.invalid("native baseline inventory differs from exact capture")
            }
            var controlSamples: [ThumbleSkinArtboardNativeLayout.ControlSample] = []
            var chromeSamples: [ThumbleSkinArtboardNativeLayout.ChromeSample] = []
            for scheme in ThumbleSkinColorScheme.allCases {
                let nativeScheme: ColorScheme = scheme == .dark ? .dark : .light
                for state in GamepadControlPresentationState.allCases {
                    for control in controls {
                        let appearance = customization.resolvedPresentation(for: control, state: state, scheme: nativeScheme)
                        let content = GamepadNativeContentPresentation(control: control, showsButtonLabels: customization.showsButtonLabels,
                            content: appearance.content, icon: appearance.icon,
                            state: state, scheme: nativeScheme, authoredScale: appearance.scale,
                            foregroundColor: appearance.foregroundColor, profileAccentStyle: customization.accentStyle)
                        let ink = try ThumbleNativeSkinPreviewRenderer.surfaceInk(control: control, customization: customization,
                            state: state, scheme: nativeScheme, canvasSize: size, scale: 1, surfaces: content.nativeFlowSurfaceIDs)
                        guard ink?.samples.values.allSatisfy({ $0.nativeLayout != nil }) ?? content.nativeFlowSurfaceIDs.isEmpty else {
                            throw ControllerDesignError.invalid("native baseline flow layout absent")
                        }
                        let frames = ink?.samples.compactMapValues { $0.nativeLayout?.canvasBounds } ?? [:]
                        guard Set(frames.keys) == Set(content.nativeFlowSurfaceIDs) else {
                            throw ControllerDesignError.invalid("native baseline flow measurement incomplete")
                        }
                        controlSamples.append(.init(controlID: control.id.id, colorScheme: scheme, state: state, flowFrames: frames))
                    }
                }
                for connected in [false, true] {
                    for editing in [false, true] {
                        let bar = try ThumbleNativeSkinPreviewRenderer.renderControlBarSnapshot(profile: profile,
                            orientation: orientation, colorScheme: scheme, isConnected: connected, isDefault: false,
                            isEditing: editing, scale: 1, customizationOverride: customization)
                        chromeSamples.append(.init(kind: "bar", colorScheme: scheme, isConnected: connected, isEditing: editing,
                            requestedVisibility: nil, resolvedVisibility: nil, frames: bar.layout.frames, viewport: bar.layout.viewport))
                        chromeSamples[chromeSamples.count - 1].paint = bar.layout.paint
                        for requested in [false, true] {
                            let drawer = try ThumbleNativeSkinPreviewRenderer.renderDrawerSnapshot(profile: profile,
                                orientation: orientation, colorScheme: scheme, safeAreaInsets: variant.safeAreaInsets,
                                minimumPortraitTopInset: 0, requestedVisibility: requested, isConnected: connected,
                                isDefault: false, isEditing: editing, collapsedOpacity: 1, scale: 1,
                                customizationOverride: customization)
                            chromeSamples.append(.init(kind: "drawer", colorScheme: scheme, isConnected: connected, isEditing: editing,
                                requestedVisibility: requested, resolvedVisibility: drawer.isVisible,
                                frames: drawer.layout.frames, viewport: drawer.layout.viewport))
                            chromeSamples[chromeSamples.count - 1].paint = drawer.layout.paint
                        }
                    }
                }
            }
            result.variants[index].nativeLayout = .init(rendererSHA256: rendererSHA256, controls: controlSamples, chrome: chromeSamples)
        }
        return result
    }

    /// Complete native matrix for authored variants only, plus one mixed-state panel in each
    /// scheme. Evidence is committed under a new immutable number after every file is hashed.
    @MainActor
    public static func review(at root: URL, expectedRevision: UInt64,
                              rendererSHA256: String,
                              mixedStates: [String: GamepadControlPresentationState]? = nil,
                              renderScale: CGFloat = 1,
                              showsSafeAreaOverlay: Bool = false,
                              showsTouchTargets: Bool = false, showsBindingHints: Bool = false, includesControlBar: Bool = true, minimumPortraitTopInset: CGFloat = 0) throws -> ControllerDesignSession.Review {
        guard minimumPortraitTopInset.isFinite, (0...128).contains(minimumPortraitTopInset) else {
            throw ControllerDesignError.invalid("minimum portrait top inset must be between 0 and 128 points")
        }
        guard renderScale == 1 || renderScale == 2 else { throw ControllerDesignError.invalid("native review scale must be 1 or 2") }
        guard rendererSHA256.count == 64, rendererSHA256.allSatisfy({ $0.isHexDigit }) else {
            throw ControllerDesignError.invalid("renderer identity must be a SHA-256")
        }
        return try withLock(root) {
            var session = try load(at: root)
            guard session.revision == expectedRevision else { throw ControllerDesignError.conflict("session revision changed") }
            let sources = try sourceDigests(at: root)
            guard try digest(sources) == session.sourceSHA256 else {
                throw ControllerDesignError.conflict("source changed; synchronize with design update before review")
            }
            let profile = try JSONDecoder().decodeUnique(GamepadConfigurationProfile.self,
                from: boundedData(root.appendingPathComponent("contract/profile.json"), root: root))
            let loaded = try ThumbleSkinCompiler.loadWorkspace(from: root)
            guard let artboard = loaded.workspace.resolvedArtboard,
                  try digest(artboard) == session.artboardSHA256,
                  loaded.workspace.capturedArtboards.count == 1 else {
                throw ControllerDesignError.conflict("workspace does not target frozen artboard")
            }
            let number = (try reviewNumbers(at: root).last ?? 0) + 1
            let directory = root.appendingPathComponent("reviews/review-\(number)")
            let staging = root.appendingPathComponent("reviews/.review-\(number)-\(UUID().uuidString)")
            let fm = FileManager.default
            defer { try? fm.removeItem(at: staging) }
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            let compilation = try ThumbleSkinCompiler.compile(source: root,
                buildDirectory: staging.appendingPathComponent("compiled"), packageOutputURL: staging.appendingPathComponent("skin.pocketpad"))
            let quality = ThumbleSkinQualityEvaluator.evaluate(package: compilation.package,
                workspace: compilation.workspace, capturedProfile: profile)
            var items: [ThumbleNativeSkinPreviewItem] = []
            var frames: [ControllerDesignSession.ReviewFrame] = []
            var barFrames: [ControllerDesignSession.ControlBarReview.Frame] = []
            var barSnapshots: [(String, CGImage)] = []
            var drawerFrames: [ControllerDesignSession.DrawerReview.Frame] = []
            var drawerSnapshots: [(String, CGImage)] = []
            var layoutInputs: [ControllerDesignDiagnosticBuilder.LayoutInput] = []
            var barStyleUses: [ControllerDesignDiagnosticBuilder.StyleUse] = []
            for variant in artboard.variants {
                let deviceOrientation: GamepadEditorDeviceOrientation = variant.orientation == .portrait ? .portrait : .landscape
                let source = profile.customization(for: deviceOrientation)
                layoutInputs.append(.init(orientation: variant.orientation,
                    issues: source.layoutQualityReport(canvasSize: CGSize(width: variant.canvasWidth, height: variant.canvasHeight)).issues))
                let bindingEntries = showsBindingHints ? KeypadBindingPresentationBuilder.entries(
                    customization: source, elementOutputs: [:], outputMode: profile.outputMode) : []
                var mixed = mixedStates ?? [:]
                if mixedStates == nil {
                    if let button = variant.controls.first(where: { $0.kind == .button }) { mixed[button.id] = .pressed }
                    if let aim = variant.controls.first(where: { $0.kind == .trackpad || $0.kind == .joystick }) { mixed[aim.id] = .active }
                }
                guard Set(mixed.keys).isSubset(of: Set(variant.controls.map(\.id))) else {
                    throw ControllerDesignError.invalid("mixed-state target missing from \(variant.orientation.rawValue) artboard")
                }
                for scheme in ThumbleSkinColorScheme.allCases {
                    let rendered = source.applying(skinPackage: compilation.package, orientation: variant.orientation,
                        colorScheme: scheme, options: .replacingAppearance)
                    let resolvedControls = rendered.resolvedControls(in: CGSize(width: variant.canvasWidth, height: variant.canvasHeight))
                        .filter { !$0.layoutCustomization.isHidden }
                    guard Set(resolvedControls.map { $0.id.id }) == Set(variant.controls.map(\.id)) else {
                        throw ControllerDesignError.conflict("native render control inventory differs from frozen artboard")
                    }
                    for control in resolvedControls {
                        guard let captured = variant.controls.first(where: { $0.id == control.id.id }),
                              abs(control.frame.minX - captured.frame.x * variant.canvasWidth) < 0.001,
                              abs(control.frame.minY - captured.frame.y * variant.canvasHeight) < 0.001,
                              abs(control.frame.width - captured.frame.width * variant.canvasWidth) < 0.001,
                              abs(control.frame.height - captured.frame.height * variant.canvasHeight) < 0.001,
                              captured.rotationDegrees.map({ abs(control.rotationDegrees - $0) < 0.000001 }) ?? true else {
                            throw ControllerDesignError.conflict("native render geometry differs from frozen artboard")
                        }
                    }
                    for control in resolvedControls {
                        if let hit = variant.controls.first(where: { $0.id == control.id.id })?.nativeGeometry?.hitFrame {
                            guard abs(control.hitFrame.minX - hit.x * variant.canvasWidth) < 0.001,
                                  abs(control.hitFrame.minY - hit.y * variant.canvasHeight) < 0.001,
                                  abs(control.hitFrame.width - hit.width * variant.canvasWidth) < 0.001,
                                  abs(control.hitFrame.height - hit.height * variant.canvasHeight) < 0.001 else {
                                throw ControllerDesignError.conflict("native hit geometry differs from frozen artboard")
                            }
                        }
                    }
                    if includesControlBar {
                        for connected in [false, true] {
                            for editing in [false, true] {
                                let title = "bar-\(variant.orientation.rawValue)-\(scheme.rawValue)-\(connected ? "connected" : "offline")-\(editing ? "editing" : "normal")"
                                let snapshot = try ThumbleNativeSkinPreviewRenderer.renderControlBarSnapshot(profile: profile,
                                    orientation: deviceOrientation, colorScheme: scheme, isConnected: connected,
                                    isDefault: false, isEditing: editing, scale: renderScale, customizationOverride: rendered)
                                let image = snapshot.image
                                let png = try ThumbleNativeSkinPreviewRenderer.pngData(image)
                                guard png.count <= maximumFileBytes else { throw ControllerDesignError.invalid("bar image exceeds budget") }
                                try png.write(to: staging.appendingPathComponent(title + ".png"))
                                let visible = GamepadControllerPresentationRouting.visibleControlBarItems(rendered.controlBarItems,
                                    hiddenItems: Set(rendered.controlBarItems.filter { rendered.controlBarItemCustomization(for: $0).isHidden }),
                                    hasProfiles: true, hasLaunchTarget: profile.launchTarget != nil)
                                for item in visible where item != .spacer {
                                    if let styleID = rendered.controlBarItemCustomization(for: item).styleID {
                                        barStyleUses.append(.init(styleID: styleID, orientation: variant.orientation, colorScheme: scheme,
                                            target: .init(controlID: nil, action: nil, layerID: "native-control-bar",
                                                          surfaceID: "native-control-bar/" + item.rawValue), frameTitle: title))
                                    }
                                }
                                barFrames.append(.init(title: title, orientation: variant.orientation, colorScheme: scheme,
                                    isConnected: connected, isEditing: editing, isDefaultProfile: false, profileName: profile.name,
                                    visibleItems: visible, surfaceIDs: snapshot.layout.frames.keys.filter { !$0.hasSuffix("/spacer") }.sorted(),
                                    viewportWidth: CGFloat(image.width) / renderScale,
                                    viewportHeight: CGFloat(image.height) / renderScale, renderScale: renderScale,
                                    image: .init(path: "reviews/review-\(number)/\(title).png", byteCount: png.count, sha256: png.thumbleSHA256),
                                    nativeLayout: snapshot.layout,
                                    drawerLayoutInputs: .init(safeAreaInsets: EdgeInsets(
                                        top: variant.safeAreaInsets.top * variant.canvasHeight,
                                        leading: variant.safeAreaInsets.leading * variant.canvasWidth,
                                        bottom: variant.safeAreaInsets.bottom * variant.canvasHeight,
                                        trailing: variant.safeAreaInsets.trailing * variant.canvasWidth),
                                        isLandscape: deviceOrientation == .landscape, minimumPortraitTopInset: minimumPortraitTopInset)))
                                barFrames[barFrames.count - 1].containerPresentation = .init(isLandscape: deviceOrientation == .landscape,
                                    colorScheme: scheme == .dark ? .dark : .light)
                                barSnapshots.append((title, image))
                            }
                        }
                    }
                    let hints = Dictionary(uniqueKeysWithValues: resolvedControls.compactMap { control -> (String, String)? in
                        KeypadBindingPresentationBuilder.compactHint(for: control, entries: bindingEntries).map { (control.id.id, $0) }
                    })
                    if includesControlBar {
                        let controller = try ThumbleNativeSkinPreviewRenderer.render(item: .init(title: "drawer-underlay",
                            customization: rendered, colorScheme: scheme, state: .normal,
                            safeAreaInsets: variant.safeAreaInsets, showsSafeAreaOverlay: showsSafeAreaOverlay,
                            showsTouchTargets: showsTouchTargets, secondaryBindingTexts: hints, omitsRevealHandle: true), scale: renderScale)
                        let samples: [(Bool, Bool, Bool, CGFloat, String)] = [false, true].flatMap { connected in
                            [false, true].map { editing in (connected, editing, true, CGFloat(1), "expanded") }
                        } + [(true, false, false, 1, "collapsed"), (true, false, false, 0, "faded")]
                        for (connected, editing, requested, opacity, sample) in samples {
                            let title = "drawer-\(variant.orientation.rawValue)-\(scheme.rawValue)-\(connected ? "connected" : "offline")-\(editing ? "editing" : "normal")-\(sample)"
                            let snapshot = try ThumbleNativeSkinPreviewRenderer.renderDrawerSnapshot(profile: profile,
                                orientation: deviceOrientation, colorScheme: scheme, safeAreaInsets: variant.safeAreaInsets,
                                minimumPortraitTopInset: minimumPortraitTopInset, requestedVisibility: requested,
                                isConnected: connected, isDefault: false, isEditing: editing, collapsedOpacity: opacity,
                                scale: renderScale, customizationOverride: rendered)
                            let image = try ThumbleNativeSkinPreviewRenderer.composite(controller: controller, drawer: snapshot.image)
                            let png = try ThumbleNativeSkinPreviewRenderer.pngData(image)
                            guard png.count <= maximumFileBytes else { throw ControllerDesignError.invalid("drawer image exceeds budget") }
                            try png.write(to: staging.appendingPathComponent(title + ".png"))
                            let surfaces = snapshot.layout.frames.keys.filter {
                                !$0.hasSuffix("/spacer") && $0 != "native-drawer" && (snapshot.isVisible || opacity > 0)
                            }.sorted()
                            drawerFrames.append(.init(title: title, orientation: variant.orientation, colorScheme: scheme,
                                isConnected: connected, isEditing: editing, requestedVisibility: requested,
                                resolvedVisibility: snapshot.isVisible, collapsedOpacity: opacity, surfaceIDs: surfaces,
                                nativeLayout: snapshot.layout, layoutInputs: snapshot.inputs, renderScale: renderScale,
                                image: .init(path: "reviews/review-\(number)/\(title).png", byteCount: png.count, sha256: png.thumbleSHA256)))
                            drawerSnapshots.append((title, image))
                        }
                    }
                    let matrix = GamepadControlPresentationState.allCases.map { ($0.rawValue, $0, [String: GamepadControlPresentationState]()) }
                        + [("mixed", .normal, mixed)]
                    for (label, state, overrides) in matrix {
                        let title = "\(variant.orientation.rawValue)-\(scheme.rawValue)-\(label)"
                        let item = ThumbleNativeSkinPreviewItem(title: title, customization: rendered,
                            colorScheme: scheme, state: state, statesByControlID: overrides,
                            safeAreaInsets: variant.safeAreaInsets, showsSafeAreaOverlay: showsSafeAreaOverlay,
                            showsTouchTargets: showsTouchTargets, secondaryBindingTexts: hints)
                        let png = try ThumbleNativeSkinPreviewRenderer.pngData(item: item, scale: renderScale)
                        guard png.count <= maximumFileBytes else { throw ControllerDesignError.invalid("rendered image exceeds budget") }
                        try png.write(to: staging.appendingPathComponent(title + ".png"))
                        items.append(item)
                        frames.append(.init(title: title, orientation: variant.orientation, colorScheme: scheme,
                            state: state, statesByControlID: overrides, viewportWidth: variant.canvasWidth,
                            viewportHeight: variant.canvasHeight, safeAreaInsets: variant.safeAreaInsets,
                            renderScale: renderScale,
                            canvasFill: rendered.keypadBackgroundFillStyle(scheme: scheme == .dark ? .dark : .light),
                            artworkLayers: rendered.artworkLayers,
                            controls: try controlEvidence(customization: rendered, variant: variant, scheme: scheme,
                                                      state: state, overrides: overrides, renderScale: renderScale, secondaryBindingTexts: hints),
                            image: .init(path: "reviews/review-\(number)/\(title).png", byteCount: png.count, sha256: png.thumbleSHA256),
                            showsSafeAreaOverlay: showsSafeAreaOverlay, showsTouchTargets: showsTouchTargets, showsBindingHints: showsBindingHints))
                    }
                }
            }
            var barEvidence: ControllerDesignSession.ControlBarReview?
            if !barFrames.isEmpty {
                let barSheet = staging.appendingPathComponent("control-bar-contact-sheet.png")
                try ThumbleNativeSkinPreviewRenderer.writeRasterContactSheet(snapshots: barSnapshots,
                    skinName: compilation.workspace.name + " · Control bar", outputURL: barSheet, cellSize: CGSize(width: 520, height: 140))
                let bytes = try boundedData(barSheet, root: staging)
                barEvidence = .init(frames: barFrames, contactSheet: .init(path: "reviews/review-\(number)/control-bar-contact-sheet.png",
                    byteCount: bytes.count, sha256: bytes.thumbleSHA256))
            }
            var drawerEvidence: ControllerDesignSession.DrawerReview?
            if !drawerFrames.isEmpty {
                let sheet = staging.appendingPathComponent("drawer-contact-sheet.png")
                try ThumbleNativeSkinPreviewRenderer.writeRasterContactSheet(snapshots: drawerSnapshots,
                    skinName: compilation.workspace.name + " · Drawer scenes", outputURL: sheet)
                let bytes = try boundedData(sheet, root: staging)
                drawerEvidence = .init(frames: drawerFrames, contactSheet: .init(path: "reviews/review-\(number)/drawer-contact-sheet.png",
                    byteCount: bytes.count, sha256: bytes.thumbleSHA256))
            }
            let sheet = staging.appendingPathComponent("contact-sheet.png")
            try ThumbleNativeSkinPreviewRenderer.writeContactSheet(items: items, skinName: compilation.workspace.name,
                outputURL: sheet, columns: 4, scale: 1)
            let sheetData = try boundedData(sheet, root: staging)
            guard try sourceDigests(at: root) == sources else { throw ControllerDesignError.conflict("source changed while rendering") }
            _ = try load(at: root)
            var evidence = ControllerDesignSession.Review(schemaVersion: 1, number: number, sessionID: session.id,
                sessionRevision: session.revision, profileID: session.profileID, targetRevision: session.targetRevision,
                draftID: session.draftID, draftRevision: session.draftRevision, artboardSHA256: session.artboardSHA256,
                profileSHA256: session.profileSHA256, bindingSHA256: session.bindingSHA256,
                sourceSHA256: session.sourceSHA256, rendererSHA256: rendererSHA256,
                package: .init(path: "reviews/review-\(number)/skin.pocketpad", byteCount: compilation.packageData.count,
                               sha256: compilation.packageData.thumbleSHA256),
                contactSheet: .init(path: "reviews/review-\(number)/contact-sheet.png", byteCount: sheetData.count, sha256: sheetData.thumbleSHA256),
                sourceFiles: sources, frames: frames, sourceDiagnostics: compilation.sourceReport,
                qualityDiagnostics: quality, visualApproval: "pending-independent-critique",
                baseProfileSHA256: session.baseProfileSHA256, layoutPlanSHA256: session.layoutPlanSHA256, controlBar: barEvidence, drawer: drawerEvidence)
            evidence.diagnostics = try ControllerDesignDiagnosticBuilder.build(source: compilation.sourceReport, quality: quality,
                artboard: artboard, frames: frames, layouts: layoutInputs, barStyles: barStyleUses, workspace: compilation.workspace, skin: compilation.package.skin)
            try write(evidence, to: staging.appendingPathComponent("manifest.json"))
            try fm.moveItem(at: staging, to: directory)
            session.latestReview = number
            try write(session, to: root.appendingPathComponent(sessionFile))
            return evidence
        }
    }
}
#endif

public struct ControllerDesignCapabilities: Codable, Sendable {
    public let schemaVersion: Int
    public let css: ThumbleCSSCapabilities
    public let operations: [String]
    public let exactAuthoredOrientationsOnly: Bool
    public let nativeStates: [String]
    public let includesMixedStatePanels: Bool
    public let reviewOverlays: [String]
    public let safeAreaSource: String
    public let editableSourceExtensions: [String]
    public let iconProperties: [String]
    public let layoutFields: [String]
    public let artworkAnchorTargets: [String]
    public let artworkAnchorLimitations: [String]
    public let semanticSelectors: [String]
    public let nativePresentationFields: [String]
    public let nativePresentationEditOperation: String
    public let surfaceScope: String
    public let nativeSurfaceIDs: [String]
    public let nativeFlowSurfaces: [String]
    public let nativeRuntimeRules: [String: String]
    public let unsupported: [String]
    public let limits: [String: Int]

    public static let current = ControllerDesignCapabilities(schemaVersion: 1, css: .current,
        operations: ["begin", "update", "review", "critique", "apply", "inspect"], exactAuthoredOrientationsOnly: true,
        nativeStates: GamepadControlPresentationState.allCases.map(\.rawValue), includesMixedStatePanels: true,
        reviewOverlays: ["safe-area", "touch-targets"],
        safeAreaSource: "explicit caller viewport; hardware safe areas unavailable",
        editableSourceExtensions: ["css", "json", "svg", "png"],
        iconProperties: ["source", "value", "placement", "scale", "tintColor", "renderingMode"],
        layoutFields: ["centerX", "centerY", "widthScale", "heightScale", "rotationDegrees"],
        artworkAnchorTargets: ["controlID", "action", "group"],
        artworkAnchorLimitations: ["CSS schema 3 SVG canvas_artwork only", "compile-time captured frames", "axis-aligned layout bounds; no rotation or state scale", "in-canvas transforms only", "passive paint; no hit targets or labels"],
        semanticSelectors: ["action", "purpose", "group"],
        nativePresentationFields: ["schemaVersion", "actionID", "purposeID", "groupIDs", "legend", "caption", "accessibilityName"],
        nativePresentationEditOperation: "design update layoutEdits presentation/clearPresentation and visualRole/clearVisualRole edit owned native elements; undeclared roles use kind-only fallbacks; element.set/add also support authoring before begin",
        surfaceScope: "native canvas, passive artwork, controls, legends, pointing interiors and reveal handle; bar and settled drawer scenes separately reviewed; popovers remain unsupported",
        nativeSurfaceIDs: ["face", "legend", "caption", "binding-hint", "icon", "joystick-puck", "joystick-well-ring", "trackpad-frame", "trackpad-cursor", "trackpad-indicators", "trigger-fill"],
        nativeFlowSurfaces: ["legend", "caption", "binding-hint", "icon", "trackpad-cursor"],
        nativeRuntimeRules: ["buttonPressedScale": "0.94 for input buttons; system chrome excluded",
            "trackpadActiveScale": "0.97", "effectiveScale": "authored scale multiplied by native state scale; hit geometry unchanged",
            "drawerLayoutInputs": "shared native padding rules in canvas points; frozen normalized safe areas scaled by exact canvas; minimumPortraitTopInset defaults to 0 and accepts 0...128; live iPhone uses 54 and merges window insets; these are inputs, not measured drawer placement or composite pixels",
            "controlBarReview": "included by default: separate hashed sheet and 8 panels per authored orientation; connected/offline and editing on/off in light/dark; native bar/item and legend/icon leaf layout frames measured; drawer scenes separately measured; menus, glyph ink, paint-effect extents and hit geometry unmeasured; default-profile flag false; includesControlBar false omits bar and drawer evidence explicitly",
            "drawerScenes": "included with includesControlBar; settled expanded/collapsed/faded native composition over normal controller faces; native drawer, reveal and bar item layout measured in canvas points; static canvas reveal omitted only in scene underlay",
            "bindingHints": "optional showsBindingHints review input; exact frozen output formatter, separate binding-hint surface and native ink; disabled by default",
            "reviewFeedback": "centered joystick, zero-touch trackpad, trigger value zero for normal/disabled and one for pressed/active",
            "reviewTransitions": "settled native states; intermediate animation frames are not sampled",
            "reviewAccessibility": "default contrast, transparency and label scale; runtime accessibility adaptations are not sampled",
            "pointingPaint": "nativeContent.pointingPaint retains authored overrides; resolvedPointingPaint includes native RGBA defaults and stroke widths used by rendering; trackpad secondary indicator reflects sampled touch count",
            "frozenSurfaceInventory": "new captured controls include eight baseline samples, potential surface IDs, local primitive frames, effective scale, supported native properties and fixed limitations; CLI/MCP begin also adds immutable variant.nativeLayout with baseline control flow, bar legend/icon leaves and bar/drawer/item contexts at 1x before source authoring; typed edits recapture, source edits retain baseline; review measures the source-edited result and ink separately; legacy/geometry-only contracts may omit nativeLayout",
            "frozenHitGeometry": "new captured controls include normalized native resolver hit rectangles before separate rotation; layout updates recapture them and review rejects mismatches; legacy contracts may omit nativeGeometry",
            "nativeBarItemPaint": "immutable native item/legend/icon paint recorded at actual SwiftUI seams; requested appearance, resolved overrides or fallback RGBA, state, padding, height, renderer shape/corner inputs, inherited/explicit foreground, icon source/rendering/tint/scale/frame and payload hashes; baseline and review bar/drawer frames share capture; <=10 item and icon records; glyph ink/paint-effect extents/hit geometry and selected fonts remain separate",
            "nativeBarContainerPaint": "shared fixed numeric RGBA, shape, spacing, padding, border and shadow evidence on bar frames; per-item glyph/paint/hit details remain separate; container styling is fixed",
            "surfaceInk": "native mask ink bounds after state scale, rotation and canvas clipping; before sibling/artwork occlusion; RGBA8 sRGB alpha > 1/255; native flow leaf layout bounds measured at opacity seams; selected font remains unmeasured"],
        unsupported: ["icon-fit", "icon-mask", "icon-padding", "remote-fonts", "scripts", "CSS-hit-testing", "runtime-popovers-and-animated-drawer-placement", "hardware-safe-area-discovery"],
        limits: ["maximumSourceBytes": ControllerDesignWorkspace.maximumSourceBytes,
                 "maximumFileBytes": ControllerDesignWorkspace.maximumFileBytes,
                 "maximumEditRequestBytes": ControllerDesignWorkspace.maximumEditRequestBytes,
                 "maximumLocalMCPSourceUpdateRequestBytes": 24 * 1024 * 1024,
                 "maximumOrdinaryMCPRequestBytes": 256 * 1024,
                 "maximumMCPEvidenceReplyBytes": 12 * 1024 * 1024, "maximumMCPOrdinaryReplyBytes": 2 * 1024 * 1024,
                 "maximumRelayMCPRequestBytes": 256 * 1024,
                 "maximumSourceFiles": ControllerDesignWorkspace.maximumSourceFiles,
                 "maximumNativeBarLayoutFrames": 32,
                 "maximumNativeCaptureControlsPerOrientation": 128,
                 "nativeCaptureControlStatesPerScheme": 4, "nativeCaptureChromeSamplesPerOrientation": 24,
                 "maximumReviewPanels": 60, "maximumControllerReviewPanels": 20, "maximumControlBarReviewPanels": 16, "maximumDrawerReviewPanels": 24,
                 "maximumCombinedDiagnostics": 4096, "maximumLayoutEdits": 256, "maximumLayoutPlanBytes": 64 * 1024,
                 "maximumAnchoredAssets": 8, "maximumAnchorControls": 32])
}
