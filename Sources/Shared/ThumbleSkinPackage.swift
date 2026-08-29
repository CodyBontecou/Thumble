import CryptoKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import ZIPFoundation

public extension UTType {
    static let thumbleSkinPackage = UTType(
        exportedAs: "com.codybontecou.pocketpad.skin-package",
        conformingTo: .zip
    )
}

public enum ThumblePackageKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case skin
    case layout
    case pack

    public var id: String { rawValue }
}

public struct ThumbleSkinAuthor: Codable, Equatable, Sendable {
    public var name: String
    public var url: URL?

    public init(name: String, url: URL? = nil) {
        self.name = name
        self.url = url
    }

    public var normalized: ThumbleSkinAuthor {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return ThumbleSkinAuthor(name: String((trimmed.isEmpty ? "Unknown Creator" : trimmed).prefix(80)), url: url)
    }
}

public struct ThumbleSkinResourceDescriptor: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var path: String
    public var contentType: String
    public var role: GamepadAssetRole
    public var byteCount: Int
    public var sha256: String

    public init(
        id: String,
        path: String,
        contentType: String,
        role: GamepadAssetRole,
        byteCount: Int,
        sha256: String
    ) {
        self.id = id
        self.path = path
        self.contentType = contentType
        self.role = role
        self.byteCount = byteCount
        self.sha256 = sha256
    }

    public var normalized: ThumbleSkinResourceDescriptor {
        ThumbleSkinResourceDescriptor(
            id: GamepadStyleToken.normalizedIdentifier(id),
            path: path.trimmingCharacters(in: .whitespacesAndNewlines),
            contentType: String(contentType.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100)),
            role: role,
            byteCount: max(0, byteCount),
            sha256: sha256.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

public struct ThumbleSkinPreviewDescriptor: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var path: String
    public var orientation: ThumbleSkinOrientation
    public var colorScheme: ThumbleSkinColorScheme?
    public var byteCount: Int
    public var sha256: String

    public init(
        id: String,
        path: String,
        orientation: ThumbleSkinOrientation,
        colorScheme: ThumbleSkinColorScheme? = nil,
        byteCount: Int,
        sha256: String
    ) {
        self.id = id
        self.path = path
        self.orientation = orientation
        self.colorScheme = colorScheme
        self.byteCount = byteCount
        self.sha256 = sha256
    }

    public var normalized: ThumbleSkinPreviewDescriptor {
        ThumbleSkinPreviewDescriptor(
            id: GamepadStyleToken.normalizedIdentifier(id),
            path: path.trimmingCharacters(in: .whitespacesAndNewlines),
            orientation: orientation,
            colorScheme: colorScheme,
            byteCount: max(0, byteCount),
            sha256: sha256.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

public struct ThumbleSkinManifest: Codable, Equatable, Sendable {
    public static let schemaIdentifier = "com.codybontecou.pocketpad.skin-package"
    public static let currentSchemaVersion = 2

    public var schema: String
    public var schemaVersion: Int
    public var identifier: String
    public var version: String
    public var kind: ThumblePackageKind
    public var name: String
    public var author: ThumbleSkinAuthor
    public var summary: String
    public var license: String
    public var homepage: URL?
    public var minimumAppVersion: String?
    public var tags: [String]
    public var skinPath: String?
    public var skinSHA256: String?
    public var profilePath: String?
    public var profileSHA256: String?
    public var assets: [ThumbleSkinResourceDescriptor]
    public var previews: [ThumbleSkinPreviewDescriptor]
    public var compatibility: ThumbleSkinCompatibility?

    public init(
        schema: String = Self.schemaIdentifier,
        schemaVersion: Int = Self.currentSchemaVersion,
        identifier: String,
        version: String,
        kind: ThumblePackageKind = .skin,
        name: String,
        author: ThumbleSkinAuthor,
        summary: String = "",
        license: String = "All Rights Reserved",
        homepage: URL? = nil,
        minimumAppVersion: String? = nil,
        tags: [String] = [],
        skinPath: String? = "skin.json",
        skinSHA256: String? = nil,
        profilePath: String? = nil,
        profileSHA256: String? = nil,
        assets: [ThumbleSkinResourceDescriptor] = [],
        previews: [ThumbleSkinPreviewDescriptor] = [],
        compatibility: ThumbleSkinCompatibility? = nil
    ) {
        self.schema = schema
        self.schemaVersion = schemaVersion
        self.identifier = identifier
        self.version = version
        self.kind = kind
        self.name = name
        self.author = author
        self.summary = summary
        self.license = license
        self.homepage = homepage
        self.minimumAppVersion = minimumAppVersion
        self.tags = tags
        self.skinPath = skinPath
        self.skinSHA256 = skinSHA256
        self.profilePath = profilePath
        self.profileSHA256 = profileSHA256
        self.assets = assets
        self.previews = previews
        self.compatibility = compatibility
    }

    public var normalized: ThumbleSkinManifest {
        let normalizedTags = Array(Set(tags.compactMap { tag -> String? in
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : String(trimmed.prefix(40))
        })).sorted()
        return ThumbleSkinManifest(
            schema: schema.trimmingCharacters(in: .whitespacesAndNewlines),
            schemaVersion: schemaVersion,
            identifier: identifier.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
            version: version.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: kind,
            name: String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100)),
            author: author.normalized,
            summary: String(summary.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500)),
            license: String(license.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100)),
            homepage: homepage,
            minimumAppVersion: minimumAppVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
            tags: normalizedTags,
            skinPath: skinPath?.trimmingCharacters(in: .whitespacesAndNewlines),
            skinSHA256: skinSHA256?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
            profilePath: profilePath?.trimmingCharacters(in: .whitespacesAndNewlines),
            profileSHA256: profileSHA256?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
            assets: assets.map(\.normalized),
            previews: previews.map(\.normalized),
            compatibility: compatibility?.normalized
        )
    }
}

public struct ThumbleSemanticVersion: Comparable, CustomStringConvertible, Equatable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: String?

    public init?(_ value: String) {
        let buildSplit = value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        let releaseSplit = buildSplit[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = releaseSplit[0].split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3,
              let major = Int(core[0]), major >= 0,
              let minor = Int(core[1]), minor >= 0,
              let patch = Int(core[2]), patch >= 0
        else { return nil }
        let prerelease = releaseSplit.count == 2 ? String(releaseSplit[1]) : nil
        if let prerelease, prerelease.isEmpty { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.map { "-\($0)" } ?? "")
    }

    public static func < (lhs: ThumbleSemanticVersion, rhs: ThumbleSemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil): return false
        case (nil, .some): return false
        case (.some, nil): return true
        case let (.some(lhs), .some(rhs)): return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }
}

private final class ThumbleSkinPackageValueBox<Value: Equatable & Sendable>: @unchecked Sendable, Equatable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }

    static func == (
        lhs: ThumbleSkinPackageValueBox<Value>,
        rhs: ThumbleSkinPackageValueBox<Value>
    ) -> Bool {
        lhs.value == rhs.value
    }
}

public struct ThumbleSkinPackage: Equatable, Sendable {
    public var manifest: ThumbleSkinManifest
    private var storedSkin: ThumbleSkinPackageValueBox<ThumbleSkin>?
    private var storedProfile: ThumbleSkinPackageValueBox<GamepadConfigurationProfile>?
    /// Resource data keyed by manifest asset ID.
    public var assets: [String: Data]
    /// Preview data keyed by manifest preview ID.
    public var previews: [String: Data]

    public var skin: ThumbleSkin? {
        get { storedSkin?.value }
        set { storedSkin = newValue.map(ThumbleSkinPackageValueBox.init) }
    }

    public var profile: GamepadConfigurationProfile? {
        get { storedProfile?.value }
        set { storedProfile = newValue.map(ThumbleSkinPackageValueBox.init) }
    }

    fileprivate var containsSkin: Bool { storedSkin != nil }
    fileprivate var containsProfile: Bool { storedProfile != nil }

    public init(
        manifest: ThumbleSkinManifest,
        skin: ThumbleSkin? = nil,
        profile: GamepadConfigurationProfile? = nil,
        assets: [String: Data] = [:],
        previews: [String: Data] = [:]
    ) {
        self.manifest = manifest
        storedSkin = skin.map(ThumbleSkinPackageValueBox.init)
        storedProfile = profile.map(ThumbleSkinPackageValueBox.init)
        self.assets = assets
        self.previews = previews
    }
}

public enum ThumbleSkinValidationSeverity: String, Codable, Sendable {
    case warning
    case error
}

public struct ThumbleSkinValidationIssue: Codable, Equatable, Identifiable, Sendable {
    public var severity: ThumbleSkinValidationSeverity
    public var code: String
    public var message: String
    public var path: String?

    public init(severity: ThumbleSkinValidationSeverity, code: String, message: String, path: String? = nil) {
        self.severity = severity
        self.code = code
        self.message = message
        self.path = path
    }

    public var id: String { [severity.rawValue, code, path ?? "", message].joined(separator: ":") }
}

public struct ThumbleSkinValidationReport: Codable, Equatable, Sendable {
    public var issues: [ThumbleSkinValidationIssue]

    public init(issues: [ThumbleSkinValidationIssue] = []) {
        self.issues = issues
    }

    public var errors: [ThumbleSkinValidationIssue] { issues.filter { $0.severity == .error } }
    public var warnings: [ThumbleSkinValidationIssue] { issues.filter { $0.severity == .warning } }
    public var isValid: Bool { errors.isEmpty }
}

public enum ThumbleSkinPackageValidator {
    public static func validate(_ package: ThumbleSkinPackage) -> ThumbleSkinValidationReport {
        ValidationWorkspace(package: package).validate()
    }

    /// Package values contain large, deeply nested appearance and profile structs. Keeping the
    /// validation phases on a heap-backed workspace prevents Swift's Debug build from reserving
    /// every phase's generic scratch storage in one main-thread stack frame during app launch.
    private final class ValidationWorkspace {
        private let package: ThumbleSkinPackage
        private let manifest: ThumbleSkinManifest
        private var issues: [ThumbleSkinValidationIssue] = []

        init(package: ThumbleSkinPackage) {
            self.package = package
            manifest = package.manifest.normalized
        }

        func validate() -> ThumbleSkinValidationReport {
            validateManifestIdentity()
            validateCompatibility()
            validatePackageContents()
            validateResourcePayloads()
            validateSkinContents()
            return ThumbleSkinValidationReport(issues: issues)
        }

        private func error(_ code: String, _ message: String, path: String? = nil) {
            issues.append(ThumbleSkinValidationIssue(severity: .error, code: code, message: message, path: path))
        }

        private func warning(_ code: String, _ message: String, path: String? = nil) {
            issues.append(ThumbleSkinValidationIssue(severity: .warning, code: code, message: message, path: path))
        }

        private func validateManifestIdentity() {
            if manifest.schema != ThumbleSkinManifest.schemaIdentifier {
                error("unsupported-schema", "Unsupported package schema \(manifest.schema).", path: "manifest.json")
            }
            if manifest.schemaVersion < 1 || manifest.schemaVersion > ThumbleSkinManifest.currentSchemaVersion {
                error("unsupported-schema-version", "Unsupported schema version \(manifest.schemaVersion).", path: "manifest.json")
            }
            if !ThumbleSkinPackageValidator.isValidReverseDNSIdentifier(manifest.identifier) {
                error("invalid-identifier", "Identifier must use reverse-DNS form, for example com.creator.skin-name.", path: "manifest.identifier")
            }
            if ThumbleSemanticVersion(manifest.version) == nil {
                error("invalid-version", "Package version must be semantic versioning in major.minor.patch form.", path: "manifest.version")
            }
            if manifest.name.isEmpty {
                error("missing-name", "Package name cannot be empty.", path: "manifest.name")
            }
            if manifest.author.name.isEmpty {
                error("missing-author", "Package author cannot be empty.", path: "manifest.author.name")
            }
            if manifest.license.isEmpty {
                warning("missing-license", "Add a license so community members know how the skin may be shared.", path: "manifest.license")
            }
        }

        private func validateCompatibility() {
            guard let rawCompatibility = package.manifest.compatibility else { return }
            let compatibility = rawCompatibility.normalized
            if manifest.schemaVersion < 2 {
                error("compatibility-requires-v2", "Compatibility declarations require package schema version 2.", path: "manifest.compatibility")
            }
            if compatibility.mode == .templateAligned, compatibility.templates.isEmpty {
                error("missing-template-requirement", "Template-aligned skins must name at least one canonical template.", path: "manifest.compatibility.templates")
            }
            if compatibility.orientations.isEmpty {
                error("missing-compatible-orientation", "Compatibility must declare at least one orientation.", path: "manifest.compatibility.orientations")
            }
            let minimumAspect = rawCompatibility.minimumAspectRatio
            let maximumAspect = rawCompatibility.maximumAspectRatio
            let hasInvalidAspect = minimumAspect.map { !$0.isFinite || !(0.25...4).contains($0) } == true
                || maximumAspect.map { !$0.isFinite || !(0.25...4).contains($0) } == true
                || (minimumAspect != nil && maximumAspect != nil && minimumAspect! > maximumAspect!)
            if hasInvalidAspect {
                error("invalid-aspect-range", "Aspect ratios must be finite values from 0.25 through 4, and minimum cannot exceed maximum.", path: "manifest.compatibility")
            }
            validateTemplateRequirements(rawCompatibility.templates)
        }

        private func validateTemplateRequirements(_ requirements: [ThumbleSkinTemplateRequirement]) {
            var templateIDs = Set<String>()
            for (index, requirement) in requirements.enumerated() {
                let templateID = requirement.templateID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if templateID.isEmpty {
                    error("invalid-template-requirement", "Template IDs cannot be empty.", path: "manifest.compatibility.templates[\(index)]")
                }
                if requirement.minimumRevision < 1
                    || requirement.maximumRevision.map({ $0 < requirement.minimumRevision }) == true {
                    error("invalid-template-revision-range", "Template revision ranges must begin at 1 or later and maximum cannot precede minimum.", path: "manifest.compatibility.templates[\(index)]")
                }
                if !templateID.isEmpty, !templateIDs.insert(templateID).inserted {
                    error("duplicate-template-requirement", "Each canonical template may appear only once.", path: "manifest.compatibility.templates[\(index)]")
                }
            }
        }

        private func validatePackageContents() {
            switch manifest.kind {
            case .skin:
                requireSkin("Skin packages must contain skin.json.")
                rejectProfile("Appearance-only skins cannot contain keypad profiles or executable bindings.")
            case .layout:
                requireProfile("Layout packages must contain profile.json.")
            case .pack:
                requireSkin("Full packs must contain skin.json.")
                requireProfile("Full packs must contain profile.json.")
            }

            if manifest.previews.isEmpty, !manifest.tags.contains("css") {
                warning("missing-preview", "Add portrait or landscape previews to make the skin discoverable.", path: "manifest.previews")
            }
        }

        private func requireSkin(_ message: String) {
            if !package.containsSkin { error("missing-skin", message, path: manifest.skinPath) }
        }

        private func requireProfile(_ message: String) {
            if !package.containsProfile { error("missing-profile", message, path: manifest.profilePath) }
        }

        private func rejectProfile(_ message: String) {
            if package.containsProfile { error("unexpected-profile", message, path: manifest.profilePath) }
        }

        private func validateResourcePayloads() {
            ThumbleSkinPackageValidator.validateResources(
                manifest.assets,
                data: package.assets,
                root: "assets",
                issues: &issues
            )
            ThumbleSkinPackageValidator.validatePreviews(
                manifest.previews,
                data: package.previews,
                issues: &issues
            )
        }

        private func validateSkinContents() {
            guard let skin = package.skin else { return }
            let normalizedSkin = skin.normalized
            let referencedAssets = ThumbleSkinPackageValidator.referencedAssetIDs(in: normalizedSkin)
            let declaredAssets = Set(manifest.assets.map(\.id))
            for assetID in referencedAssets.subtracting(declaredAssets).sorted() {
                error("missing-asset-reference", "Skin references undeclared asset \(assetID).", path: "skin.json")
            }
            for assetID in declaredAssets.subtracting(referencedAssets).sorted() {
                warning("unused-asset", "Asset \(assetID) is not referenced by this skin.", path: "manifest.assets")
            }
            ThumbleSkinPackageValidator.validateStyleReferences(in: normalizedSkin, issues: &issues)
        }
    }

    public static func isValidReverseDNSIdentifier(_ value: String) -> Bool {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 3 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return components.allSatisfy { component in
            !component.isEmpty
                && component.unicodeScalars.allSatisfy { allowed.contains($0) }
                && component.unicodeScalars.first.map { CharacterSet.letters.contains($0) } == true
        }
    }

    private static func validateResources(
        _ descriptors: [ThumbleSkinResourceDescriptor],
        data: [String: Data],
        root: String,
        issues: inout [ThumbleSkinValidationIssue]
    ) {
        var ids = Set<String>()
        var paths = Set<String>()
        for descriptor in descriptors.map(\.normalized) {
            if descriptor.id.isEmpty || !ids.insert(descriptor.id).inserted {
                issues.append(.init(severity: .error, code: "duplicate-asset-id", message: "Asset IDs must be non-empty and unique.", path: descriptor.path))
            }
            if !paths.insert(descriptor.path).inserted {
                issues.append(.init(severity: .error, code: "duplicate-asset-path", message: "Asset paths must be unique.", path: descriptor.path))
            }
            if !ThumbleSkinPackageCodec.isSafePackagePath(descriptor.path, requiredRoot: root) {
                issues.append(.init(severity: .error, code: "unsafe-asset-path", message: "Asset path must stay inside \(root)/.", path: descriptor.path))
            }
            if !isAllowedVisualResource(path: descriptor.path, contentType: descriptor.contentType) {
                issues.append(.init(severity: .error, code: "executable-asset", message: "Skin assets must be non-executable visual media.", path: descriptor.path))
            }
            guard let payload = data[descriptor.id] else {
                issues.append(.init(severity: .error, code: "missing-asset-data", message: "Missing data for asset \(descriptor.id).", path: descriptor.path))
                continue
            }
            if descriptor.byteCount != payload.count {
                issues.append(.init(severity: .error, code: "asset-size-mismatch", message: "Asset byte count does not match its manifest entry.", path: descriptor.path))
            }
            if descriptor.sha256 != payload.thumbleSHA256 {
                issues.append(.init(severity: .error, code: "asset-hash-mismatch", message: "Asset hash does not match its manifest entry.", path: descriptor.path))
            }
        }
        for extraID in Set(data.keys).subtracting(ids).sorted() {
            issues.append(.init(severity: .error, code: "undeclared-asset-data", message: "Asset data \(extraID) is not declared in the manifest."))
        }
    }

    private static func validatePreviews(
        _ descriptors: [ThumbleSkinPreviewDescriptor],
        data: [String: Data],
        issues: inout [ThumbleSkinValidationIssue]
    ) {
        var ids = Set<String>()
        var paths = Set<String>()
        for descriptor in descriptors.map(\.normalized) {
            if descriptor.id.isEmpty || !ids.insert(descriptor.id).inserted {
                issues.append(.init(severity: .error, code: "duplicate-preview-id", message: "Preview IDs must be non-empty and unique.", path: descriptor.path))
            }
            if !paths.insert(descriptor.path).inserted {
                issues.append(.init(severity: .error, code: "duplicate-preview-path", message: "Preview paths must be unique.", path: descriptor.path))
            }
            if !ThumbleSkinPackageCodec.isSafePackagePath(descriptor.path, requiredRoot: "previews") {
                issues.append(.init(severity: .error, code: "unsafe-preview-path", message: "Preview path must stay inside previews/.", path: descriptor.path))
            }
            if !isAllowedPreviewPath(descriptor.path) {
                issues.append(.init(severity: .error, code: "invalid-preview-content", message: "Preview files must use a supported image extension.", path: descriptor.path))
            }
            guard let payload = data[descriptor.id] else {
                issues.append(.init(severity: .error, code: "missing-preview-data", message: "Missing data for preview \(descriptor.id).", path: descriptor.path))
                continue
            }
            if descriptor.byteCount != payload.count || descriptor.sha256 != payload.thumbleSHA256 {
                issues.append(.init(severity: .error, code: "preview-integrity-mismatch", message: "Preview size or hash does not match its manifest entry.", path: descriptor.path))
            }
        }
        for extraID in Set(data.keys).subtracting(ids).sorted() {
            issues.append(.init(severity: .error, code: "undeclared-preview-data", message: "Preview data \(extraID) is not declared in the manifest."))
        }
    }

    private static func isAllowedVisualResource(path: String, contentType: String) -> Bool {
        let contentType = contentType.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard contentType.hasPrefix("image/") || contentType == "application/pdf" else { return false }
        let forbiddenExtensions: Set<String> = [
            "app", "appex", "bundle", "command", "dylib", "exe", "js", "mach-o", "node",
            "o", "out", "plugin", "py", "sh", "so", "swift"
        ]
        return !forbiddenExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    private static func isAllowedPreviewPath(_ path: String) -> Bool {
        let allowedExtensions: Set<String> = ["avif", "gif", "heic", "heif", "jpeg", "jpg", "png", "tif", "tiff", "webp"]
        return allowedExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    private static func validateStyleReferences(
        in skin: ThumbleSkin,
        issues: inout [ThumbleSkinValidationIssue]
    ) {
        let combinations: [(ThumbleSkinOrientation, ThumbleSkinColorScheme)] = [
            (.portrait, .light), (.portrait, .dark), (.landscape, .light), (.landscape, .dark)
        ]
        for (orientation, scheme) in combinations {
            let appearance = skin.appearance(orientation: orientation, colorScheme: scheme)
            let styleIDs = Set(appearance.styleLibrary.styles.map(\.id))
            let controlAppearances = [appearance.defaultControl].compactMap { $0 }
                + appearance.roleRules.map(\.appearance)
                + appearance.buttonRules.map(\.appearance)
            for control in controlAppearances {
                if let styleID = control.styleID, !styleIDs.contains(styleID) {
                    issues.append(.init(
                        severity: .error,
                        code: "missing-style-reference",
                        message: "Control references missing style \(styleID) for \(orientation.rawValue)/\(scheme.rawValue).",
                        path: "skin.json"
                    ))
                }
            }
        }
    }

    private static func referencedAssetIDs(in skin: ThumbleSkin) -> Set<String> {
        var ids = Set<String>()
        let appearances = [skin.base] + skin.variants.map(\.appearance)
        for appearance in appearances {
            collectAssets(from: appearance.backgroundFillStyle, into: &ids)
            for layer in appearance.artworkLayers ?? [] {
                collectAssets(from: layer.fillStyle, into: &ids)
            }
            let controls = [appearance.defaultControl].compactMap { $0 }
                + appearance.roleRules.map(\.appearance)
                + appearance.buttonRules.map(\.appearance)
            for control in controls {
                collectAssets(from: control.icon, into: &ids)
                collectAssets(from: control.visualStyle, into: &ids)
            }
            for style in appearance.styleLibrary.styles {
                collectAssets(from: style.visualStyle, into: &ids)
            }
        }
        return ids
    }

    private static func collectAssets(from visualStyle: GamepadControlVisualStyle?, into ids: inout Set<String>) {
        guard let visualStyle else { return }
        collectAssets(from: visualStyle.icon, into: &ids)
        collectAssets(from: visualStyle.normal.fillStyle, into: &ids)
        collectAssets(from: visualStyle.pressed?.fillStyle, into: &ids)
        collectAssets(from: visualStyle.active?.fillStyle, into: &ids)
        collectAssets(from: visualStyle.disabled?.fillStyle, into: &ids)
    }

    private static func collectAssets(from icon: GamepadControlIcon?, into ids: inout Set<String>) {
        guard let icon, icon.source == .asset else { return }
        let id = GamepadStyleToken.normalizedIdentifier(icon.value)
        if !id.isEmpty { ids.insert(id) }
    }

    private static func collectAssets(from fillStyle: GamepadFillStyle?, into ids: inout Set<String>) {
        guard let fillStyle, case .image(let image) = fillStyle.normalized, let assetID = image.assetID else { return }
        ids.insert(assetID)
    }
}

public enum ThumbleSkinPackageCodecError: LocalizedError, Equatable {
    case archiveTooLarge
    case invalidArchive
    case unsafeEntry(String)
    case duplicateEntry(String)
    case unsupportedEntry(String)
    case tooManyEntries
    case entryTooLarge(String)
    case compressionRatioTooHigh(String)
    case missingEntry(String)
    case unexpectedEntry(String)
    case corruptEntry(String)
    case invalidPackage([ThumbleSkinValidationIssue])

    public var errorDescription: String? {
        switch self {
        case .archiveTooLarge: "Thumble skin package exceeds the compressed size limit."
        case .invalidArchive: "The file is not a readable Thumble skin package."
        case .unsafeEntry(let path): "Package contains an unsafe path: \(path)."
        case .duplicateEntry(let path): "Package contains a duplicate entry: \(path)."
        case .unsupportedEntry(let path): "Package contains an unsupported entry type: \(path)."
        case .tooManyEntries: "Package contains too many files."
        case .entryTooLarge(let path): "Package entry is too large: \(path)."
        case .compressionRatioTooHigh(let path): "Package entry has an unsafe compression ratio: \(path)."
        case .missingEntry(let path): "Package is missing required entry: \(path)."
        case .unexpectedEntry(let path): "Package contains an undeclared entry: \(path)."
        case .corruptEntry(let path): "Package entry failed integrity validation: \(path)."
        case .invalidPackage(let issues): issues.first?.message ?? "Thumble skin package is invalid."
        }
    }
}

public enum ThumbleSkinPackageCodec {
    public static let maximumArchiveBytes = 40 * 1024 * 1024
    public static let maximumEntryCount = 256
    public static let maximumEntryBytes = 10 * 1024 * 1024
    public static let maximumTotalUncompressedBytes = 50 * 1024 * 1024
    public static let maximumCompressionRatio: UInt64 = 200

    public static func encode(_ package: ThumbleSkinPackage) throws -> Data {
        try EncodingWorkspace(package: package).encode()
    }

    /// Encoding normalizes large value types, validates them, then writes their payloads. Phase
    /// isolation keeps those temporary values from occupying one cumulative Debug stack frame.
    private final class EncodingWorkspace {
        private let encoder: JSONEncoder
        private let originalCompatibility: ThumbleSkinCompatibility?
        private var prepared: ThumbleSkinPackage
        private var manifest: ThumbleSkinManifest
        private var skinData: Data?
        private var profileData: Data?

        init(package: ThumbleSkinPackage) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            self.encoder = encoder
            originalCompatibility = package.manifest.compatibility
            prepared = package
            manifest = package.manifest.normalized
        }

        func encode() throws -> Data {
            normalizeSkin()
            normalizeProfile()
            try encodeSkinPayload()
            try encodeProfilePayload()
            updateManifestPayloadMetadata()
            updateManifestResourceMetadata()
            try validatePreparedPackage()
            return try makeArchive()
        }

        private func normalizeSkin() {
            prepared.skin = prepared.skin?.normalized
        }

        private func normalizeProfile() {
            prepared.profile = prepared.profile?.normalized
        }

        private func encodeSkinPayload() throws {
            skinData = try prepared.skin.map { try encoder.encode($0) }
        }

        private func encodeProfilePayload() throws {
            profileData = try prepared.profile.map { try encoder.encode($0) }
        }

        private func updateManifestPayloadMetadata() {
            if let skinData {
                manifest.skinPath = manifest.skinPath ?? "skin.json"
                manifest.skinSHA256 = skinData.thumbleSHA256
            } else {
                manifest.skinPath = nil
                manifest.skinSHA256 = nil
            }
            if let profileData {
                manifest.profilePath = manifest.profilePath ?? "profile.json"
                manifest.profileSHA256 = profileData.thumbleSHA256
            } else {
                manifest.profilePath = nil
                manifest.profileSHA256 = nil
            }
        }

        private func updateManifestResourceMetadata() {
            manifest.assets = manifest.assets.map { descriptor in
                var descriptor = descriptor.normalized
                if let data = prepared.assets[descriptor.id] {
                    descriptor.byteCount = data.count
                    descriptor.sha256 = data.thumbleSHA256
                }
                return descriptor
            }
            manifest.previews = manifest.previews.map { descriptor in
                var descriptor = descriptor.normalized
                if let data = prepared.previews[descriptor.id] {
                    descriptor.byteCount = data.count
                    descriptor.sha256 = data.thumbleSHA256
                }
                return descriptor
            }
        }

        private func validatePreparedPackage() throws {
            // Validate compatibility before its normalizer can repair malformed author input
            // (for example a reversed aspect or template-revision range). Other manifest
            // fields stay prepared so canonical hashes and byte counts are validated.
            let normalizedCompatibility = manifest.compatibility
            prepared.manifest = manifest
            prepared.manifest.compatibility = originalCompatibility
            let report = ThumbleSkinPackageValidator.validate(prepared)
            guard report.isValid else { throw ThumbleSkinPackageCodecError.invalidPackage(report.errors) }
            manifest.compatibility = normalizedCompatibility
            prepared.manifest = manifest
        }

        private func makeArchive() throws -> Data {
            let archive: Archive
            do {
                archive = try Archive(accessMode: .create)
            } catch {
                throw ThumbleSkinPackageCodecError.invalidArchive
            }

            try ThumbleSkinPackageCodec.add(
                try encoder.encode(manifest),
                path: "manifest.json",
                to: archive
            )
            if let skinData, let path = manifest.skinPath {
                try ThumbleSkinPackageCodec.add(skinData, path: path, to: archive)
            }
            if let profileData, let path = manifest.profilePath {
                try ThumbleSkinPackageCodec.add(profileData, path: path, to: archive)
            }
            for descriptor in manifest.assets {
                guard let data = prepared.assets[descriptor.id] else {
                    throw ThumbleSkinPackageCodecError.missingEntry(descriptor.path)
                }
                try ThumbleSkinPackageCodec.add(data, path: descriptor.path, to: archive)
            }
            for descriptor in manifest.previews {
                guard let data = prepared.previews[descriptor.id] else {
                    throw ThumbleSkinPackageCodecError.missingEntry(descriptor.path)
                }
                try ThumbleSkinPackageCodec.add(data, path: descriptor.path, to: archive)
            }
            guard let data = archive.data else { throw ThumbleSkinPackageCodecError.invalidArchive }
            guard data.count <= ThumbleSkinPackageCodec.maximumArchiveBytes else {
                throw ThumbleSkinPackageCodecError.archiveTooLarge
            }
            return data
        }
    }

    public static func decode(_ data: Data) throws -> ThumbleSkinPackage {
        try DecodingWorkspace(data: data).decode()
    }

    /// Decoding profiles can require substantial temporary storage in Debug builds. Keeping each
    /// archive phase in a separate method releases that storage before package validation begins.
    private final class DecodingWorkspace {
        private let archive: Archive
        private let decoder = JSONDecoder()
        private var entries: [String: Entry] = [:]
        private var manifest: ThumbleSkinManifest?
        private var skin: ThumbleSkin?
        private var profile: GamepadConfigurationProfile?
        private var assets: [String: Data] = [:]
        private var previews: [String: Data] = [:]

        init(data: Data) throws {
            guard data.count <= ThumbleSkinPackageCodec.maximumArchiveBytes else {
                throw ThumbleSkinPackageCodecError.archiveTooLarge
            }
            do {
                archive = try Archive(data: data, accessMode: .read)
            } catch {
                throw ThumbleSkinPackageCodecError.invalidArchive
            }
        }

        func decode() throws -> ThumbleSkinPackage {
            try indexEntries()
            try decodeManifest()
            try validateAllowedPaths()
            try decodeSkin()
            try decodeProfile()
            try decodeAssets()
            try decodePreviews()
            return try validatedPackage()
        }

        private func indexEntries() throws {
            var totalUncompressed: UInt64 = 0
            for entry in archive {
                guard entries.count < ThumbleSkinPackageCodec.maximumEntryCount else {
                    throw ThumbleSkinPackageCodecError.tooManyEntries
                }
                let path = entry.path
                guard ThumbleSkinPackageCodec.isSafePackagePath(path) else {
                    throw ThumbleSkinPackageCodecError.unsafeEntry(path)
                }
                guard entries[path] == nil else {
                    throw ThumbleSkinPackageCodecError.duplicateEntry(path)
                }
                switch entry.type {
                case .file:
                    guard entry.uncompressedSize <= UInt64(ThumbleSkinPackageCodec.maximumEntryBytes) else {
                        throw ThumbleSkinPackageCodecError.entryTooLarge(path)
                    }
                    totalUncompressed += entry.uncompressedSize
                    guard totalUncompressed <= UInt64(ThumbleSkinPackageCodec.maximumTotalUncompressedBytes) else {
                        throw ThumbleSkinPackageCodecError.archiveTooLarge
                    }
                    if entry.compressedSize > 0,
                       entry.uncompressedSize / entry.compressedSize > ThumbleSkinPackageCodec.maximumCompressionRatio {
                        throw ThumbleSkinPackageCodecError.compressionRatioTooHigh(path)
                    }
                    entries[path] = entry
                case .directory:
                    continue
                case .symlink:
                    throw ThumbleSkinPackageCodecError.unsupportedEntry(path)
                }
            }
        }

        private func decodeManifest() throws {
            guard let entry = entries["manifest.json"] else {
                throw ThumbleSkinPackageCodecError.missingEntry("manifest.json")
            }
            let data = try ThumbleSkinPackageCodec.extract(
                entry,
                from: archive,
                maximumBytes: 1_000_000
            )
            do {
                manifest = try decoder.decode(ThumbleSkinManifest.self, from: data).normalized
            } catch {
                throw ThumbleSkinPackageCodecError.corruptEntry("manifest.json")
            }
        }

        private func validateAllowedPaths() throws {
            guard let manifest else { throw ThumbleSkinPackageCodecError.invalidArchive }
            var allowedPaths: Set<String> = ["manifest.json", "README.md", "LICENSE", "LICENSE.txt"]
            if let path = manifest.skinPath { allowedPaths.insert(path) }
            if let path = manifest.profilePath { allowedPaths.insert(path) }
            allowedPaths.formUnion(manifest.assets.map(\.path))
            allowedPaths.formUnion(manifest.previews.map(\.path))
            for path in entries.keys where !allowedPaths.contains(path) {
                throw ThumbleSkinPackageCodecError.unexpectedEntry(path)
            }
        }

        private func decodeSkin() throws {
            guard let manifest else { throw ThumbleSkinPackageCodecError.invalidArchive }
            guard let path = manifest.skinPath else {
                skin = nil
                return
            }
            guard let entry = entries[path] else {
                throw ThumbleSkinPackageCodecError.missingEntry(path)
            }
            let payload = try ThumbleSkinPackageCodec.extract(
                entry,
                from: archive,
                maximumBytes: 4_000_000
            )
            guard manifest.skinSHA256 == payload.thumbleSHA256 else {
                throw ThumbleSkinPackageCodecError.corruptEntry(path)
            }
            do {
                skin = try decoder.decode(ThumbleSkin.self, from: payload).normalized
            } catch {
                throw ThumbleSkinPackageCodecError.corruptEntry(path)
            }
        }

        private func decodeProfile() throws {
            guard let manifest else { throw ThumbleSkinPackageCodecError.invalidArchive }
            guard let path = manifest.profilePath else {
                profile = nil
                return
            }
            guard let entry = entries[path] else {
                throw ThumbleSkinPackageCodecError.missingEntry(path)
            }
            let payload = try ThumbleSkinPackageCodec.extract(
                entry,
                from: archive,
                maximumBytes: 8_000_000
            )
            guard manifest.profileSHA256 == payload.thumbleSHA256 else {
                throw ThumbleSkinPackageCodecError.corruptEntry(path)
            }
            do {
                profile = try decoder.decode(GamepadConfigurationProfile.self, from: payload).normalized
            } catch {
                throw ThumbleSkinPackageCodecError.corruptEntry(path)
            }
        }

        private func decodeAssets() throws {
            guard let manifest else { throw ThumbleSkinPackageCodecError.invalidArchive }
            for descriptor in manifest.assets {
                guard let entry = entries[descriptor.path] else {
                    throw ThumbleSkinPackageCodecError.missingEntry(descriptor.path)
                }
                let payload = try ThumbleSkinPackageCodec.extract(
                    entry,
                    from: archive,
                    maximumBytes: ThumbleSkinPackageCodec.maximumEntryBytes
                )
                guard payload.count == descriptor.byteCount,
                      payload.thumbleSHA256 == descriptor.sha256
                else {
                    throw ThumbleSkinPackageCodecError.corruptEntry(descriptor.path)
                }
                assets[descriptor.id] = payload
            }
        }

        private func decodePreviews() throws {
            guard let manifest else { throw ThumbleSkinPackageCodecError.invalidArchive }
            for descriptor in manifest.previews {
                guard let entry = entries[descriptor.path] else {
                    throw ThumbleSkinPackageCodecError.missingEntry(descriptor.path)
                }
                let payload = try ThumbleSkinPackageCodec.extract(
                    entry,
                    from: archive,
                    maximumBytes: ThumbleSkinPackageCodec.maximumEntryBytes
                )
                guard payload.count == descriptor.byteCount,
                      payload.thumbleSHA256 == descriptor.sha256
                else {
                    throw ThumbleSkinPackageCodecError.corruptEntry(descriptor.path)
                }
                previews[descriptor.id] = payload
            }
        }

        private func validatedPackage() throws -> ThumbleSkinPackage {
            guard let manifest else { throw ThumbleSkinPackageCodecError.invalidArchive }
            let package = ThumbleSkinPackage(
                manifest: manifest,
                skin: skin,
                profile: profile,
                assets: assets,
                previews: previews
            )
            let report = ThumbleSkinPackageValidator.validate(package)
            guard report.isValid else {
                throw ThumbleSkinPackageCodecError.invalidPackage(report.errors)
            }
            return package
        }
    }

    public static func read(from url: URL) throws -> ThumbleSkinPackage {
        try decode(Data(contentsOf: url, options: [.mappedIfSafe]))
    }

    public static func write(_ package: ThumbleSkinPackage, to url: URL) throws {
        let data = try encode(package)
        try data.write(to: url, options: .atomic)
    }

    public static func isSafePackagePath(_ path: String, requiredRoot: String? = nil) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.hasPrefix("~"),
              !path.contains("\\"),
              !path.unicodeScalars.contains(where: { $0.value == 0 })
        else { return false }
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { return false }
        if let requiredRoot {
            guard components.first == Substring(requiredRoot), components.count >= 2 else { return false }
        }
        return true
    }

    private static func add(_ data: Data, path: String, to archive: Archive) throws {
        guard isSafePackagePath(path) else { throw ThumbleSkinPackageCodecError.unsafeEntry(path) }
        guard data.count <= maximumEntryBytes else { throw ThumbleSkinPackageCodecError.entryTooLarge(path) }
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            modificationDate: Date(timeIntervalSince1970: 315_532_800),
            permissions: 0o644,
            compressionMethod: .deflate
        ) { position, size in
            let start = Int(position)
            return data.subdata(in: start..<(start + size))
        }
    }

    private static func extract(_ entry: Entry, from archive: Archive, maximumBytes: Int) throws -> Data {
        guard entry.uncompressedSize <= UInt64(maximumBytes) else { throw ThumbleSkinPackageCodecError.entryTooLarge(entry.path) }
        var data = Data()
        data.reserveCapacity(Int(entry.uncompressedSize))
        do {
            _ = try archive.extract(entry) { chunk in
                guard data.count + chunk.count <= maximumBytes else {
                    throw ThumbleSkinPackageCodecError.entryTooLarge(entry.path)
                }
                data.append(chunk)
            }
        } catch let error as ThumbleSkinPackageCodecError {
            throw error
        } catch {
            throw ThumbleSkinPackageCodecError.corruptEntry(entry.path)
        }
        return data
    }
}

public struct ThumbleSkinPackageDocument: FileDocument {
    public static var readableContentTypes: [UTType] { [.thumbleSkinPackage] }
    public static var writableContentTypes: [UTType] { [.thumbleSkinPackage] }

    public var package: ThumbleSkinPackage

    public init(package: ThumbleSkinPackage) {
        self.package = package
    }

    public init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        package = try ThumbleSkinPackageCodec.decode(data)
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try ThumbleSkinPackageCodec.encode(package))
    }
}

extension Data {
    var thumbleSHA256: String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}
