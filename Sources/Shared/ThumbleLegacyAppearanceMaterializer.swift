import Foundation

/// Migration-only bridge from the retired package cascade to ordinary design data.
/// It does not mutate a profile or claim that an authority transaction has committed.
public enum ThumbleLegacyAppearanceMaterializer {
    public enum RecoveryRequired: Error, Equatable {
        case missingPackage
        case mismatchedPackage
        case invalidPackage([String])
        case missingResources([String])
    }

    public struct Variant: Codable, Equatable, Sendable {
        public let colorScheme: ThumbleSkinColorScheme
        public let actionSet: ThumbleActionSet
        public let appearance: GamepadAppearanceSnapshot
    }

    /// Enumerate every state before removing the only installed copy of a package.
    /// A caller must back up the source, validate resources, reconcile pending edits,
    /// and atomically persist the final profile before dropping legacy references.
    public static func materialize(
        _ profile: GamepadConfigurationProfile,
        orientation: GamepadEditorDeviceOrientation,
        package: ThumbleSkinPackage?
    ) throws -> [Variant] {
        try validatePackage(for: profile, package: package)
        let workspace = Workspace(profile: profile, orientation: orientation, package: package)
        return try workspace.materialize()
    }

    private static func validatePackage(for profile: GamepadConfigurationProfile, package: ThumbleSkinPackage?) throws {
        guard let reference = profile.skinReference else { return }
        guard let package else { throw RecoveryRequired.missingPackage }
        guard reference.identifier == package.manifest.identifier,
              reference.version == package.manifest.version else { throw RecoveryRequired.mismatchedPackage }
        guard package.skin != nil else { throw RecoveryRequired.invalidPackage(["missing-skin"]) }
        let report = ThumbleSkinPackageValidator.validate(package)
        guard report.isValid else { throw RecoveryRequired.invalidPackage(report.errors.map(\.code).sorted()) }
    }

    private final class Workspace {
        let profile: GamepadConfigurationProfile
        let orientation: GamepadEditorDeviceOrientation
        let package: ThumbleSkinPackage?
        var variants: [Variant] = []

        init(profile: GamepadConfigurationProfile, orientation: GamepadEditorDeviceOrientation, package: ThumbleSkinPackage?) {
            self.profile = profile
            self.orientation = orientation
            self.package = package
        }

        func materialize() throws -> [Variant] {
            for scheme in ThumbleSkinColorScheme.allCases {
                for actionSet in ThumbleActionSet.allCases { try append(scheme: scheme, actionSet: actionSet) }
            }
            return variants
        }

        private func append(scheme: ThumbleSkinColorScheme, actionSet: ThumbleActionSet) throws {
            let resolved = profile.resolvedCustomization(for: orientation, colorScheme: scheme,
                skinPackage: package, actionSet: actionSet)
            let appearance = GamepadAppearanceSnapshot(resolved)
            let missing = try appearance.missingResourceIDs()
            guard missing.isEmpty else { throw RecoveryRequired.missingResources(missing) }
            variants.append(Variant(colorScheme: scheme, actionSet: actionSet, appearance: appearance))
        }
    }
}
