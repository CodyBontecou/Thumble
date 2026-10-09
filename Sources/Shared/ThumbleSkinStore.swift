import Foundation
import SwiftUI

public struct ThumbleInstalledSkin: Equatable, Identifiable, Sendable {
    public var reference: ThumbleSkinReference
    public var manifest: ThumbleSkinManifest
    public var fileURL: URL
    public var installedAt: Date
    public var isBundled: Bool

    public init(
        reference: ThumbleSkinReference,
        manifest: ThumbleSkinManifest,
        fileURL: URL,
        installedAt: Date,
        isBundled: Bool = false
    ) {
        self.reference = reference
        self.manifest = manifest
        self.fileURL = fileURL
        self.installedAt = installedAt
        self.isBundled = isBundled
    }

    public var id: ThumbleSkinReference { reference }
}

public enum ThumbleSkinInstallPolicy: Sendable {
    /// Installs new versions, returns unchanged for byte-identical packages, and rejects replacement/downgrades.
    case newerOnly
    /// Replaces the exact version when its bytes differ, but still rejects a downgrade.
    case replaceSameVersion
    /// Allows installing any valid version and replacing an exact version.
    case allowDowngrade
}

public enum ThumbleSkinInstallResult: Equatable, Sendable {
    case installed(ThumbleSkinReference)
    case updated(ThumbleSkinReference, previousVersion: String)
    case replaced(ThumbleSkinReference)
    case unchanged(ThumbleSkinReference)

    public var reference: ThumbleSkinReference {
        switch self {
        case .installed(let reference), .replaced(let reference), .unchanged(let reference): reference
        case .updated(let reference, _): reference
        }
    }
}

public enum ThumbleSkinStoreError: LocalizedError, Equatable {
    case packageHasNoSkin
    case invalidIdentity
    case versionAlreadyInstalled(ThumbleSkinReference)
    case newerVersionInstalled(identifier: String, installedVersion: String)
    case skinNotInstalled(ThumbleSkinReference)
    case cannotCreateStore(String)
    case cannotWritePackage(String)
    case cannotRemovePackage(String)

    public var errorDescription: String? {
        switch self {
        case .packageHasNoSkin:
            "This package does not contain a skin."
        case .invalidIdentity:
            "The package does not have a valid skin identifier and semantic version."
        case .versionAlreadyInstalled(let reference):
            "\(reference.identifier) version \(reference.version) is already installed with different contents."
        case .newerVersionInstalled(let identifier, let installedVersion):
            "A newer version of \(identifier) (\(installedVersion)) is already installed."
        case .skinNotInstalled(let reference):
            "\(reference.identifier) version \(reference.version) is not installed."
        case .cannotCreateStore(let detail):
            "Could not create the Thumble skin library: \(detail)"
        case .cannotWritePackage(let detail):
            "Could not install the Thumble skin: \(detail)"
        case .cannotRemovePackage(let detail):
            "Could not remove the Thumble skin: \(detail)"
        }
    }
}

/// A file-backed, process-safe-enough skin library. Every package remains an independently
/// shareable `.pocketpad` archive; the directory scan is the source of truth, so a partial index
/// can never hide an installed package.
public final class ThumbleSkinStore {
    public static let packageExtension = "pocketpad"

    public let rootURL: URL
    private let fileManager: FileManager

    public init(rootURL: URL? = nil, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        if let rootURL {
            self.rootURL = rootURL
        } else {
            guard let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                throw ThumbleSkinStoreError.cannotCreateStore("Application Support is unavailable.")
            }
            self.rootURL = applicationSupport
                .appendingPathComponent("PocketPad", isDirectory: true)
                .appendingPathComponent("Skins", isDirectory: true)
        }
        do {
            try fileManager.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
        } catch {
            throw ThumbleSkinStoreError.cannotCreateStore(error.localizedDescription)
        }
    }

    public func installedSkins() throws -> [ThumbleInstalledSkin] {
        guard fileManager.fileExists(atPath: rootURL.path) else { return [] }
        let identifierURLs = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        var installed: [ThumbleInstalledSkin] = []
        for identifierURL in identifierURLs {
            let values = try? identifierURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
            let packageURLs = (try? fileManager.contentsOfDirectory(
                at: identifierURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for packageURL in packageURLs where packageURL.pathExtension.lowercased() == Self.packageExtension {
                guard let data = try? Data(contentsOf: packageURL, options: [.mappedIfSafe]),
                      let package = try? ThumbleSkinPackageCodec.decode(data),
                      let reference = Self.reference(for: package)
                else { continue }
                let values = try? packageURL.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard values?.isRegularFile != false, values?.isSymbolicLink != true else { continue }
                installed.append(ThumbleInstalledSkin(
                    reference: reference,
                    manifest: package.manifest,
                    fileURL: packageURL,
                    installedAt: values?.contentModificationDate ?? .distantPast,
                    isBundled: ThumbleBundledSkins.identifiers.contains(reference.identifier)
                ))
            }
        }
        return installed.sorted { lhs, rhs in
            if lhs.manifest.name != rhs.manifest.name {
                return lhs.manifest.name.localizedStandardCompare(rhs.manifest.name) == .orderedAscending
            }
            let left = ThumbleSemanticVersion(lhs.reference.version)
            let right = ThumbleSemanticVersion(rhs.reference.version)
            return (left ?? ThumbleSemanticVersion("0.0.0")!) > (right ?? ThumbleSemanticVersion("0.0.0")!)
        }
    }

    public func latestInstalledSkin(identifier: String) throws -> ThumbleInstalledSkin? {
        try installedSkins()
            .filter { $0.reference.identifier == identifier.lowercased() }
            .max { lhs, rhs in
                guard let left = ThumbleSemanticVersion(lhs.reference.version),
                      let right = ThumbleSemanticVersion(rhs.reference.version)
                else { return lhs.reference.version < rhs.reference.version }
                return left < right
            }
    }

    public func package(for reference: ThumbleSkinReference) throws -> ThumbleSkinPackage {
        try ThumbleSkinPackageCodec.decode(packageData(for: reference))
    }

    public func packageData(for reference: ThumbleSkinReference) throws -> Data {
        let url = try validatedPackageURL(for: reference)
        guard fileManager.fileExists(atPath: url.path) else {
            throw ThumbleSkinStoreError.skinNotInstalled(reference)
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    @discardableResult
    public func install(
        data: Data,
        policy: ThumbleSkinInstallPolicy = .newerOnly
    ) throws -> ThumbleSkinInstallResult {
        let package = try ThumbleSkinPackageCodec.decode(data)
        guard package.skin != nil else { throw ThumbleSkinStoreError.packageHasNoSkin }
        guard let reference = Self.reference(for: package),
              let incomingVersion = ThumbleSemanticVersion(reference.version)
        else { throw ThumbleSkinStoreError.invalidIdentity }

        let installedForIdentifier = try installedSkins().filter {
            $0.reference.identifier == reference.identifier
        }
        let latest = installedForIdentifier.max { lhs, rhs in
            guard let left = ThumbleSemanticVersion(lhs.reference.version),
                  let right = ThumbleSemanticVersion(rhs.reference.version)
            else { return lhs.reference.version < rhs.reference.version }
            return left < right
        }
        let destination = try validatedPackageURL(for: reference)
        if fileManager.fileExists(atPath: destination.path) {
            let existingData = try Data(contentsOf: destination, options: [.mappedIfSafe])
            if existingData == data { return .unchanged(reference) }
            guard policy != .newerOnly else {
                throw ThumbleSkinStoreError.versionAlreadyInstalled(reference)
            }
        } else if policy != .allowDowngrade,
                  let latest,
                  let latestVersion = ThumbleSemanticVersion(latest.reference.version),
                  incomingVersion < latestVersion {
            throw ThumbleSkinStoreError.newerVersionInstalled(
                identifier: reference.identifier,
                installedVersion: latest.reference.version
            )
        }

        let directory = destination.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: destination, options: [.atomic])
        } catch {
            throw ThumbleSkinStoreError.cannotWritePackage(error.localizedDescription)
        }

        if fileManager.fileExists(atPath: destination.path),
           installedForIdentifier.contains(where: { $0.reference == reference }) {
            return .replaced(reference)
        }
        if let latest, latest.reference.version != reference.version {
            return .updated(reference, previousVersion: latest.reference.version)
        }
        return .installed(reference)
    }

    @discardableResult
    public func install(
        package: ThumbleSkinPackage,
        policy: ThumbleSkinInstallPolicy = .newerOnly
    ) throws -> ThumbleSkinInstallResult {
        try install(data: ThumbleSkinPackageCodec.encode(package), policy: policy)
    }

    public func remove(_ reference: ThumbleSkinReference) throws {
        let url = try validatedPackageURL(for: reference)
        guard fileManager.fileExists(atPath: url.path) else {
            throw ThumbleSkinStoreError.skinNotInstalled(reference)
        }
        do {
            try fileManager.removeItem(at: url)
            let directory = url.deletingLastPathComponent()
            if (try? fileManager.contentsOfDirectory(atPath: directory.path).isEmpty) == true {
                try? fileManager.removeItem(at: directory)
            }
        } catch {
            throw ThumbleSkinStoreError.cannotRemovePackage(error.localizedDescription)
        }
    }

    /// Installs first-party presets through the same codec and store path used by community skins.
    public func installBundledSkinsIfNeeded() throws {
        for package in ThumbleBundledSkins.packages {
            _ = try install(package: package, policy: .replaceSameVersion)
        }
    }

    public func packageData(referencedBy profiles: [GamepadConfigurationProfile]) -> [Data] {
        let references = Set(profiles.compactMap(\.skinReference))
        return references.compactMap { try? packageData(for: $0) }
    }

    private func packageURL(for reference: ThumbleSkinReference) -> URL {
        rootURL
            .appendingPathComponent(reference.identifier, isDirectory: true)
            .appendingPathComponent("\(reference.version).\(Self.packageExtension)", isDirectory: false)
    }

    private func validatedPackageURL(for reference: ThumbleSkinReference) throws -> URL {
        guard reference.isValid else { throw ThumbleSkinStoreError.invalidIdentity }
        let identifierDirectory = rootURL.appendingPathComponent(reference.identifier, isDirectory: true)
        let rawPackage = packageURL(for: reference)
        for url in [identifierDirectory, rawPackage] where fileManager.fileExists(atPath: url.path) {
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values?.isSymbolicLink != true else { throw ThumbleSkinStoreError.invalidIdentity }
        }
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let package = root.appendingPathComponent(reference.identifier, isDirectory: true)
            .appendingPathComponent("\(reference.version).\(Self.packageExtension)")
            .standardizedFileURL.resolvingSymlinksInPath()
        guard package.path.hasPrefix(root.path + "/") else {
            throw ThumbleSkinStoreError.invalidIdentity
        }
        return package
    }

    private static func reference(for package: ThumbleSkinPackage) -> ThumbleSkinReference? {
        let manifest = package.manifest.normalized
        guard ThumbleSemanticVersion(manifest.version) != nil else { return nil }
        return ThumbleSkinReference(identifier: manifest.identifier, version: manifest.version)
    }
}

public enum ThumbleBundledSkins {
    public static let packages: [ThumbleSkinPackage] = GamepadThemePreset.allCases.map(makePackage)
    public static let identifiers: Set<String> = Set(packages.map { $0.manifest.identifier })

    private static func makePackage(for preset: GamepadThemePreset) -> ThumbleSkinPackage {
        let baseCustomization = GamepadCustomization.defaultValue.normalized
        let themed = preset.applying(to: baseCustomization)
        let lightBackground = themed.backgroundFillStyle(for: ColorScheme.light)
        let darkBackground = themed.backgroundFillStyle(for: ColorScheme.dark)
        let buttonRules = DefaultKeypadElements.ids.map { button in
            ThumbleSkinButtonRule(
                button: button,
                appearance: appearance(from: themed.buttonCustomization(for: button))
            )
        }
        let baseAppearance = ThumbleSkinAppearance(
            accentStyle: themed.accentStyle,
            showsButtonLabels: themed.showsButtonLabels,
            buttonRules: buttonRules,
            styleLibrary: themed.styleLibrary
        )
        let skin = ThumbleSkin(
            base: baseAppearance,
            variants: [
                ThumbleSkinVariant(
                    id: "light",
                    colorScheme: .light,
                    appearance: ThumbleSkinAppearance(backgroundFillStyle: lightBackground)
                ),
                ThumbleSkinVariant(
                    id: "dark",
                    colorScheme: .dark,
                    appearance: ThumbleSkinAppearance(backgroundFillStyle: darkBackground)
                )
            ]
        )
        let identifier = "com.codybontecou.pocketpad.skin.\(preset.rawValue)"
        return ThumbleSkinPackage(
            manifest: ThumbleSkinManifest(
                identifier: identifier,
                version: "1.0.0",
                name: preset.displayName,
                author: ThumbleSkinAuthor(name: "Thumble"),
                summary: preset.description,
                license: "All Rights Reserved",
                tags: ["bundled", "preset", preset.rawValue]
            ),
            skin: skin
        )
    }

    private static func appearance(from layout: GamepadButtonCustomization) -> ThumbleSkinControlAppearance {
        ThumbleSkinControlAppearance(
            styleID: layout.styleID,
            shape: layout.shape,
            accentStyle: layout.accentStyle,
            visualStyle: layout.visualStyle,
            icon: layout.icon,
            hapticFeedback: layout.hapticFeedback,
            cornerRadius: layout.cornerRadius,
            cornerRadii: layout.cornerRadii,
            shadowStrength: layout.shadowStrength
        )
    }
}
