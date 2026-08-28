import AppKit
import CoreGraphics
import Foundation
import SwiftUI

@main
struct ThumbleCLI {
    private static let appDefaultsDomain = ThumbleMacIPC.appDefaultsDomain
    private static let keyBindingsDefaultsKey = "PocketPadMac.keyBindings.v2"
    private static let profileKeyBindingsDefaultsKey = "PocketPadMac.profileKeyBindings.v1"
    private static let outputBindingsDefaultsKey = "PocketPadMac.outputBindings.v1"
    private static let profileOutputBindingsDefaultsKey = "PocketPadMac.profileOutputBindings.v1"
    private static let profileStoreChangedNotificationName = Notification.Name("com.codybontecou.PocketPadMac.profileStoreChanged")
    private static let skinStoreChangedNotificationName = Notification.Name("com.codybontecou.PocketPadMac.skinStoreChanged")
    private static let notificationProfileStateDataKey = "profileStateData"
    private static let notificationActiveCustomizationDataKey = "activeCustomizationData"
    private static let notificationKeyBindingsDataKey = "keyBindingsData"
    private static let notificationProfileKeyBindingsDataKey = "profileKeyBindingsData"
    private static let notificationOutputBindingsDataKey = "outputBindingsData"
    private static let notificationProfileOutputBindingsDataKey = "profileOutputBindingsData"
    private static let defaultEditorCanvasSize = GamepadEditorDeviceCatalog.defaultFrame.screenRect.size
    private static let portraitEditorCanvasSize = GamepadEditorDeviceFrame(spec: GamepadEditorDeviceCatalog.specs[0], orientation: .portrait).screenRect.size
    private static let trackpadOptionNames = [
        "--sensitivity", "--cursor-sensitivity", "--pointer-sensitivity",
        "--scroll-sensitivity", "--tap-to-click", "--two-finger-scroll",
        "--natural-scrolling", "--natural-scroll"
    ]
    private static let triggerOptionNames = [
        "--target", "--trigger", "--orientation", "--dead-zone", "--deadzone",
        "--digital", "--digital-button", "--digital-threshold"
    ]
    private static let joystickOptionNames = [
        "--up", "--down", "--left", "--right", "--analog", "--analog-stick", "--stick",
        "--digital-directions", "--send-digital-directions", "--sends-digital-directions",
        "--no-digital-directions", "--invert-x", "--invert-y", "--snap-to-cardinal", "--snap-cardinal",
        "--joystick-style", "--stick-style", "--thumbstick", "--classic-joystick"
    ]
    private static let elementOutputOptionNames = [
        "--keyboard", "--key", "--sequence", "--gamepad-button", "--gamepad",
        "--clear-output", "--clear-keyboard", "--clear-gamepad"
    ]

    private struct StoredProfileState: Codable {
        var profiles: [GamepadConfigurationProfile]
        var activeProfileID: UUID?
        var defaultProfileID: UUID?
    }

    private struct ProfileStore {
        var profiles: [GamepadConfigurationProfile]
        var activeProfileID: UUID
        var defaultProfileID: UUID
        var profileKeyBindings: [String: [String: MacKeyBinding]]
        var profileOutputBindings: [String: [String: MacControlOutputBinding]]
    }

    private struct GenerateOptions {
        var gameName: String?
        var specPath: String?
        var install = true
        var select = true
        var makeDefault = true
        var printJSON = false
        var validateLayout = true
        var strictLayoutValidation = false
        var previewOutputPath: String?
        var invocationID: UUID?
    }

    private struct InstallOptions {
        var select = true
        var makeDefault = true
    }

    private struct MonitorOptions {
        var jsonLines = false
        var clear = false
        var follow = true
        var fromStart = false
        var duration: TimeInterval?
        var pathOverride: String?
        var printPath = false
        var pollInterval: TimeInterval = 0.05
    }

    private struct AppWindowDescriptor {
        var id: CGWindowID
        var title: String?
        var frame: CGRect
    }

    private struct AppScreenshotResult: Encodable {
        var bundleIdentifier: String
        var path: String
        var pixelWidth: Int
        var pixelHeight: Int
        var windowID: CGWindowID
        var windowTitle: String?
    }

    private struct ProfileExportEnvelope: Codable {
        var schema: String = ThumbleKeypadConfigurationExport.schemaIdentifier
        var version: Int = ThumbleKeypadConfigurationExport.currentVersion
        var exportedAt: Int64 = Date.currentMilliseconds
        var profiles: [GamepadConfigurationProfile]
        var activeProfileID: UUID?
        var defaultProfileID: UUID?
        var profileKeyBindings: [String: [String: MacKeyBinding]]
        var profileOutputBindings: [String: [String: MacControlOutputBinding]]
        var bindingPresentations: [GamepadProfileBindingPresentations]?

        init(
            profiles: [GamepadConfigurationProfile],
            activeProfileID: UUID?,
            defaultProfileID: UUID?,
            profileKeyBindings: [String: [String: MacKeyBinding]] = [:],
            profileOutputBindings: [String: [String: MacControlOutputBinding]] = [:],
            bindingPresentations: [GamepadProfileBindingPresentations]? = nil
        ) {
            let state = GamepadConfigurationProfilePersistence.normalizedState(
                profiles: profiles,
                activeProfileID: activeProfileID,
                defaultProfileID: defaultProfileID
            )
            self.profiles = state.profiles
            self.activeProfileID = state.activeProfileID
            self.defaultProfileID = state.defaultProfileID
            self.profileKeyBindings = profileKeyBindings
            self.profileOutputBindings = profileOutputBindings
            self.bindingPresentations = bindingPresentations
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schema = try container.decodeIfPresent(String.self, forKey: .schema) ?? ThumbleKeypadConfigurationExport.schemaIdentifier
            version = try container.decodeIfPresent(Int.self, forKey: .version) ?? ThumbleKeypadConfigurationExport.currentVersion
            guard schema == ThumbleKeypadConfigurationExport.schemaIdentifier else {
                throw DecodingError.dataCorruptedError(
                    forKey: .schema,
                    in: container,
                    debugDescription: "Unsupported Thumble keypad configuration schema: \(schema)"
                )
            }
            guard version >= 1 && version <= ThumbleKeypadConfigurationExport.currentVersion else {
                throw DecodingError.dataCorruptedError(
                    forKey: .version,
                    in: container,
                    debugDescription: "Unsupported Thumble keypad configuration version: \(version)"
                )
            }

            exportedAt = try container.decodeIfPresent(Int64.self, forKey: .exportedAt) ?? Date.currentMilliseconds
            let decodedProfiles = try container.decode([GamepadConfigurationProfile].self, forKey: .profiles)
            guard !decodedProfiles.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .profiles,
                    in: container,
                    debugDescription: "Thumble keypad configuration export must contain at least one profile."
                )
            }
            let decodedActiveID = try container.decodeIfPresent(UUID.self, forKey: .activeProfileID)
            let decodedDefaultID = try container.decodeIfPresent(UUID.self, forKey: .defaultProfileID)
            let state = GamepadConfigurationProfilePersistence.normalizedState(
                profiles: decodedProfiles,
                activeProfileID: decodedActiveID,
                defaultProfileID: decodedDefaultID
            )
            profiles = state.profiles
            activeProfileID = state.activeProfileID
            defaultProfileID = state.defaultProfileID
            profileKeyBindings = try container.decodeIfPresent([String: [String: MacKeyBinding]].self, forKey: .profileKeyBindings) ?? [:]
            profileOutputBindings = try container.decodeIfPresent([String: [String: MacControlOutputBinding]].self, forKey: .profileOutputBindings) ?? [:]
            bindingPresentations = try container.decodeIfPresent([GamepadProfileBindingPresentations].self, forKey: .bindingPresentations)
        }
    }

    private struct ThemeSummary: Codable {
        var id: String
        var name: String
        var description: String
    }

    private struct SkinListSummary: Codable {
        var identifier: String
        var version: String
        var name: String
        var author: String
        var license: String
        var kind: ThumblePackageKind
        var isBundled: Bool
        var path: String
    }

    private struct SkinInspectionSummary: Codable {
        var manifest: ThumbleSkinManifest
        var validation: ThumbleSkinValidationReport
        var variantIDs: [String]
        var assetIDs: [String]
        var previewIDs: [String]
    }

    private struct OrientationPreferenceSummary: Codable {
        var configurationRevision: UInt64
        var profileID: UUID
        var profileName: String
        var orientation: ThumbleCLIProfileBackend.OrientationPreference
    }

    private struct ElementSummary: Codable {
        var id: String
        var kind: String
        var mappedButton: GameButton?
        var label: String
        var visualRole: GamepadVisualRole?
        var isHidden: Bool
        var isLocationLocked: Bool
        var layout: GamepadButtonCustomization
        var joystickMapping: GamepadJoystickMapping?
        var joystickOutputSettings: GamepadJoystickOutputSettings?
        var triggerSettings: GamepadTriggerSettings?
        var trackpadSettings: GamepadTrackpadSettings?
    }

    private struct DeviceFrameSummary: Codable {
        var id: String
        var device: String
        var orientation: String
        var screenPoints: String
        var nativePixels: String
        var scale: Double
        var nativeScale: Double
        var frameStyle: String
        var modelIdentifiers: [String]
    }

    private struct ControlBarItemSummary: Codable {
        var configurationRevision: UInt64
        var profileID: UUID
        var profileName: String
        var variant: ThumbleCLIProfileBackend.ConfigurationVariant
        var order: Int
        var id: String
        var title: String
        var description: String
        var systemImage: String
        var appearance: ThumbleCLIProfileBackend.SafeControlBarItemAppearance
    }

    private enum ElementTarget: Equatable {
        case builtin(GameButton)
        case custom(UUID)
        case system(GamepadSystemControl)
    }

    static func main() {
        do {
            try run(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch CLIError.helpRequested {
            printHelp()
        } catch CLIError.validationFailed(let message) {
            fputs("thumble: \(message)\n", stderr)
            exit(1)
        } catch {
            fputs("thumble: \(error.localizedDescription)\n", stderr)
            let environment = ProcessInfo.processInfo.environment
            if environment["THUMBLE_DEBUG_ERRORS"] == "1" || environment["THUMBCONSOLE_DEBUG_ERRORS"] == "1" {
                fputs("Debug: \(String(reflecting: error))\n", stderr)
            }
            fputs("Run `thumble --help` for usage.\n", stderr)
            exit(1)
        }
    }

    private static func run(arguments: [String]) throws {
        guard let first = arguments.first else {
            throw CLIError.helpRequested
        }

        let rest = Array(arguments.dropFirst())
        switch first {
        case "--help", "-h", "help":
            throw CLIError.helpRequested
        case "generate":
            try generate(arguments: rest)
        case "install-spec", "import":
            guard let path = rest.first else { throw CLIError.message("Missing spec path") }
            try generate(arguments: ["--spec", path] + Array(rest.dropFirst()))
        case "profile", "profiles":
            try profile(arguments: rest)
        case "template", "templates":
            try template(arguments: rest)
        case "theme", "themes":
            try theme(arguments: rest)
        case "skin", "skins":
            try skin(arguments: rest)
        case "binding", "bindings", "shortcut", "shortcuts":
            try binding(arguments: rest)
        case "output", "outputs":
            try output(arguments: rest)
        case "customization", "customize", "layout":
            try customization(arguments: rest)
        case "orientation", "orientations":
            try orientation(arguments: rest)
        case "device", "devices", "frame", "frames":
            try device(arguments: rest)
        case "element", "control", "controls":
            try element(arguments: rest)
        case "control-bar", "controlbar", "top-bar", "topbar":
            try controlBar(arguments: rest)
        case "style", "styles":
            try style(arguments: rest)
        case "layer", "layers":
            try layer(arguments: rest)
        case "group", "groups":
            try group(arguments: rest)
        case "asset", "assets":
            try asset(arguments: rest)
        case "status", "diagnostics":
            try printRuntimeStatus(json: rest.contains("--json"))
        case "monitor", "capture":
            try monitor(arguments: rest)
        case "latency":
            try latency(arguments: rest)
        case "server":
            try server(arguments: rest)
        case "relay":
            try relay(arguments: rest)
        case "pairing":
            try pairing(arguments: rest)
        case "accessibility":
            try accessibility(arguments: rest)
        case "release-all":
            postRuntimeCommand(.releaseAll, reason: "Release all from CLI")
            print("Sent release-all to Thumble Mac.")
        case "test":
            try test(arguments: rest)
        case "app":
            try app(arguments: rest)
        default:
            try generate(arguments: arguments)
        }
    }

    // MARK: - Generate / install

    private static func generate(arguments: [String]) throws {
        let options = try parseGenerateOptions(arguments)
        let generated: GeneratedGameKeypadProfile
        if let specPath = options.specPath {
            let spec = try loadAgentSpec(path: specPath)
            generated = GameKeypadGenerator.generate(from: spec, requestedGameName: options.gameName)
        } else if let gameName = options.gameName, let builtInProfile = GameKeypadGenerator.generate(for: gameName) {
            generated = builtInProfile
        } else if let gameName = options.gameName {
            throw CLIError.message("No built-in template for \"\(gameName)\". Have your agent write a JSON keypad spec and run `thumble generate --spec <file>`.")
        } else {
            throw CLIError.message("Missing game name or --spec <file>")
        }
        let macBindings = try resolvedMacBindings(for: generated)
        let layoutReport = generated.profile.customization.layoutQualityReport(profileName: generated.resolvedGameName)
        if options.validateLayout {
            try enforceLayoutQuality(layoutReport, strict: options.strictLayoutValidation, quiet: options.printJSON)
        }
        if let previewOutputPath = options.previewOutputPath {
#if os(macOS)
            try GamepadLayoutPreviewRenderer.writePNG(
                customization: generated.profile.customization,
                profileName: generated.resolvedGameName,
                outputURL: URL(fileURLWithPath: previewOutputPath)
            )
            if !options.printJSON {
                print("Wrote layout preview to \(previewOutputPath).")
            }
#endif
        }

        if options.printJSON {
            try printJSON(generated)
        }

        if options.install {
            if options.specPath != nil {
                try requireExplicitUnmigratedProfileAccess(
                    operation: "generation spec install",
                    artifactRequired: true
                )
                try install(
                    profile: generated.profile,
                    macBindings: macBindings,
                    select: options.select,
                    makeDefault: options.makeDefault
                )
                printSummary(
                    generated: generated,
                    macBindings: macBindings,
                    installed: true,
                    selected: options.select
                )
            } else {
                let response = try profileBackend().perform(
                    .generationGenerate(
                        select: options.select,
                        makeDefault: options.makeDefault
                    ),
                    invocationID: options.invocationID
                )
                guard response.outcome?.profileNames.first == "Hollow Knight" else {
                    throw CLIError.message("Rust profile authority returned no generated-profile outcome")
                }
                printSummary(
                    generated: generated,
                    macBindings: macBindings,
                    installed: true,
                    selected: options.select
                )
                printProfileInvocation(response)
            }
        } else if !options.printJSON {
            printSummary(generated: generated, macBindings: macBindings, installed: false, selected: false)
        }
    }

    private static func parseGenerateOptions(_ arguments: [String]) throws -> GenerateOptions {
        var gameNameParts: [String] = []
        var options = GenerateOptions()

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--dry-run", "--no-install":
                options.install = false
            case "--spec", "--from-spec":
                index += 1
                guard index < arguments.count else { throw CLIError.message("Missing path after \(argument)") }
                options.specPath = arguments[index]
            case "--stdin":
                options.specPath = "-"
            case "--select":
                options.select = true
            case "--no-select":
                options.select = false
                options.makeDefault = false
            case "--default":
                options.makeDefault = true
            case "--no-default":
                options.makeDefault = false
            case "--json":
                options.printJSON = true
            case "--skip-layout-validation", "--no-layout-validation":
                options.validateLayout = false
            case "--strict-layout", "--strict-layout-validation":
                options.strictLayoutValidation = true
            case "--layout-preview", "--preview-output":
                index += 1
                guard index < arguments.count else { throw CLIError.message("Missing path after \(argument)") }
                options.previewOutputPath = arguments[index]
            case "--invocation-id":
                index += 1
                guard index < arguments.count,
                      let invocationID = UUID(uuidString: arguments[index])
                else { throw CLIError.message("--invocation-id must be an exact UUID") }
                options.invocationID = invocationID
            case "--help", "-h":
                throw CLIError.helpRequested
            default:
                if argument.hasPrefix("-") { throw CLIError.message("Unknown option: \(argument)") }
                gameNameParts.append(argument)
            }
            index += 1
        }

        let gameName = gameNameParts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if !gameName.isEmpty { options.gameName = gameName }
        if options.gameName == nil && options.specPath == nil {
            throw CLIError.message("Missing game name or --spec <file>")
        }
        return options
    }

    private static func loadAgentSpec(path: String) throws -> AgentKeypadSpec {
        let data: Data
        if path == "-" {
            data = FileHandle.standardInput.readDataToEndOfFile()
        } else {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        }
        return try JSONDecoder().decode(AgentKeypadSpec.self, from: data)
    }

    private static func install(
        profile inputProfile: GamepadConfigurationProfile,
        macBindings: [GameButton: MacKeyBinding],
        select: Bool,
        makeDefault: Bool
    ) throws {
        var store = loadStore()
        var profile = inputProfile.normalized

        if let existingIndex = store.profiles.firstIndex(where: { sameProfileName($0.name, profile.name) }) {
            profile.id = store.profiles[existingIndex].id
            profile.updatedAt = Date.currentMilliseconds
            store.profiles[existingIndex] = profile
        } else {
            store.profiles.append(profile)
        }

        if select { store.activeProfileID = profile.id }
        if makeDefault { store.defaultProfileID = profile.id }
        store.profileKeyBindings[profile.id.uuidString] = rawBindings(macBindings)
        store.profileOutputBindings[profile.id.uuidString] = rawOutputBindings(
            outputBindings(from: macBindings)
        )
        try persistStore(store)
    }

    // MARK: - Profiles

    private static func profileBackend() throws -> ThumbleCLIProfileBackend {
        try ThumbleCLIProfileBackend()
    }

    private static func profileInvocationID(in arguments: [String]) throws -> UUID? {
        guard let value = optionValue("--invocation-id", in: arguments) else { return nil }
        guard let id = UUID(uuidString: value) else {
            throw CLIError.message("--invocation-id must be an exact UUID")
        }
        return id
    }

    private static func removingProfileInvocationID(from arguments: [String]) throws -> [String] {
        var result = arguments
        let indexes = result.indices.filter { result[$0] == "--invocation-id" }
        guard indexes.count <= 1 else {
            throw CLIError.message("--invocation-id may be provided only once")
        }
        guard let index = indexes.first else { return result }
        guard index + 1 < result.count else {
            throw CLIError.message("Missing UUID after --invocation-id")
        }
        result.removeSubrange(index ... index + 1)
        return result
    }

    private static func printProfileInvocation(_ response: ThumbleCLIProfileBackend.Response) {
        fputs("Invocation ID: \(response.invocationID.uuidString)\n", stderr)
    }

    private static func requireExplicitUnmigratedProfileAccess(
        operation: String,
        artifactRequired: Bool = false
    ) throws {
        do {
            try profileBackend().requireLegacyPersistenceAllowed(operation: operation)
        } catch ThumbleCLIProfileBackend.BackendError.remote(let failure, let invocationID)
            where artifactRequired && failure.code == "operation_not_migrated" {
            throw ThumbleCLIProfileBackend.BackendError.remote(
                .init(
                    code: "artifact_required",
                    message: "\(operation) requires a future bounded artifact transaction and is not available while Rust authority artifacts exist.",
                    expectedRevision: failure.expectedRevision,
                    actualRevision: failure.actualRevision,
                    draftID: failure.draftID,
                    draftRevision: failure.draftRevision,
                    conflictPaths: failure.conflictPaths
                ),
                invocationID
            )
        }
    }

    private static func profile(arguments: [String]) throws {
        guard let subcommand = arguments.first else { throw CLIError.message("Missing profile subcommand") }
        let rest = Array(arguments.dropFirst())

        switch subcommand {
        case "list", "ls":
            let json = rest.contains("--json")
            let showIDs = rest.contains("--ids") || json
            let response = try profileBackend().perform(
                .list,
                invocationID: try profileInvocationID(in: rest)
            )
            guard let catalog = response.catalog else {
                throw CLIError.message("Rust profile authority returned no revision-tagged catalog")
            }
            if json {
                try printJSON(catalog)
            } else {
                for profile in catalog.profiles {
                    let activeMarker = profile.active ? "*" : " "
                    let defaultMarker = profile.default ? " default" : ""
                    let idText = showIDs ? " [\(profile.profileID.uuidString)]" : ""
                    print("\(activeMarker) \(profile.name)\(defaultMarker)\(idText)")
                }
            }

        case "show":
            try requireExplicitUnmigratedProfileAccess(operation: "profile show", artifactRequired: true)
            let json = rest.contains("--json")
            let target = firstPositional(in: rest)
            let store = loadStore()
            let profile = try resolveProfile(target, in: store)
            if json {
                let bindings = store.profileKeyBindings[profile.id.uuidString] ?? rawBindings(DefaultKeypadKeyMap.defaultBindings)
                let keyboardBindings = decodedBindings(bindings) ?? DefaultKeypadKeyMap.defaultBindings
                let storedOutputs = decodedOutputBindings(store.profileOutputBindings[profile.id.uuidString]) ?? outputBindings(from: keyboardBindings)
                let outputs = effectiveOutputBindings(for: profile.outputMode, keyBindings: keyboardBindings, customOutputBindings: storedOutputs)
                try printJSON(ProfileExportEnvelope(
                    profiles: [profile],
                    activeProfileID: profile.id,
                    defaultProfileID: store.defaultProfileID == profile.id ? profile.id : nil,
                    profileKeyBindings: [profile.id.uuidString: bindings],
                    profileOutputBindings: [profile.id.uuidString: rawOutputBindings(outputs)],
                    bindingPresentations: bindingPresentations(for: profile, store: store)
                ))
            } else {
                printProfile(profile, store: store)
            }

        case "select", "use":
            guard let target = firstPositional(in: rest) else { throw CLIError.message("Missing profile name or id") }
            let response = try profileBackend().perform(
                .select(.init(target)),
                invocationID: try profileInvocationID(in: rest)
            )
            guard let outcome = response.outcome, let profileName = outcome.profileNames.first else {
                throw CLIError.message("Rust profile authority returned no selection outcome")
            }
            print("Selected profile \"\(profileName)\".")
            printProfileInvocation(response)

        case "default", "set-default":
            guard let target = firstPositional(in: rest) else { throw CLIError.message("Missing profile name or id") }
            let response = try profileBackend().perform(
                .setDefault(.init(target)),
                invocationID: try profileInvocationID(in: rest)
            )
            guard let outcome = response.outcome, let profileName = outcome.profileNames.first else {
                throw CLIError.message("Rust profile authority returned no default-profile outcome")
            }
            print("Made \"\(profileName)\" the default profile.")
            printProfileInvocation(response)

        case "rename":
            let values = positionals(in: rest)
            guard values.count >= 2 else { throw CLIError.message("Usage: thumble profile rename <profile> <new name>") }
            let target = values[0]
            let newName = values.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newName.isEmpty else { throw CLIError.message("New profile name cannot be empty") }
            let response = try profileBackend().perform(
                .rename(.init(target), newName),
                invocationID: try profileInvocationID(in: rest)
            )
            print("Renamed profile to \"\(newName)\".")
            printProfileInvocation(response)

        case "duplicate", "copy":
            let values = positionals(in: rest)
            let target = values.first
            let positionalName = values.count > 1 ? values.dropFirst().joined(separator: " ") : nil
            let requestedName = optionValue("--name", in: rest) ?? positionalName
            let response = try profileBackend().perform(
                .duplicate(target.map(ThumbleCLIProfileBackend.ProfileSelector.init), requestedName),
                invocationID: try profileInvocationID(in: rest)
            )
            guard let names = response.outcome?.profileNames, names.count >= 2 else {
                throw CLIError.message("Rust profile authority returned no duplicate outcome")
            }
            print("Duplicated \"\(names[0])\" as \"\(names[1])\".")
            printProfileInvocation(response)

        case "delete", "rm":
            let targets = positionals(in: rest)
            guard !targets.isEmpty else { throw CLIError.message("Missing profile name or id") }
            let response = try profileBackend().perform(
                .delete(targets.map(ThumbleCLIProfileBackend.ProfileSelector.init)),
                invocationID: try profileInvocationID(in: rest)
            )
            guard let outcome = response.outcome else {
                throw CLIError.message("Rust profile authority returned no delete outcome")
            }
            let suffix = outcome.removedEveryProfile ? " Created a new blank setup." : ""
            if outcome.profileNames.count == 1, let removed = outcome.profileNames.first {
                print("Deleted profile \"\(removed)\".\(suffix)")
            } else {
                print("Deleted \(outcome.profileNames.count) profiles: \(outcome.profileNames.joined(separator: ", ")).\(suffix)")
            }
            printProfileInvocation(response)

        case "move", "reorder":
            try moveProfiles(arguments: rest)

        case "reset":
            let target = firstPositional(in: rest)
            let response = try profileBackend().perform(
                .reset(target.map(ThumbleCLIProfileBackend.ProfileSelector.init)),
                invocationID: try profileInvocationID(in: rest)
            )
            guard let name = response.outcome?.profileNames.first else {
                throw CLIError.message("Rust profile authority returned no reset outcome")
            }
            print("Reset profile \"\(name)\" to the default keypad layout.")
            printProfileInvocation(response)

        case "new", "create":
            if let templateName = optionValue("--template", in: rest) {
                let template = try resolveTemplate(templateName)
                guard let authorityTemplate = ThumbleCLIProfileBackend.ControllerTemplate(
                    rawValue: template.rawValue
                ) else {
                    throw CLIError.message("Template is unavailable through Rust profile authority")
                }
                let requestedName = positionals(in: rest)
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let response = try profileBackend().perform(
                    .templateInstall(
                        authorityTemplate,
                        name: requestedName.isEmpty ? nil : requestedName,
                        select: !rest.contains("--no-select"),
                        makeDefault: rest.contains("--default") && !rest.contains("--no-default")
                    ),
                    invocationID: try profileInvocationID(in: rest)
                )
                guard let installedName = response.outcome?.profileNames.first else {
                    throw CLIError.message("Rust profile authority returned no template-install outcome")
                }
                print("Created profile \"\(installedName)\".")
                printProfileInvocation(response)
            } else {
                try requireExplicitUnmigratedProfileAccess(operation: "profile create")
                try createProfile(arguments: rest)
            }

        case "export":
            try requireExplicitUnmigratedProfileAccess(operation: "profile export", artifactRequired: true)
            try exportProfiles(arguments: rest)

        case "import":
            try requireExplicitUnmigratedProfileAccess(operation: "profile import", artifactRequired: true)
            try importProfiles(arguments: rest)

        case "attach-app", "attach-application", "app", "application":
            try requireExplicitUnmigratedProfileAccess(operation: "profile attach-app", artifactRequired: true)
            try attachApplicationToProfile(arguments: rest)

        case "detach-app", "detach-application", "clear-app", "remove-app":
            try requireExplicitUnmigratedProfileAccess(operation: "profile detach-app", artifactRequired: true)
            try detachApplicationFromProfile(arguments: rest)

        case "launch", "open-app":
            try requireExplicitUnmigratedProfileAccess(operation: "profile launch", artifactRequired: true)
            try launchAttachedApplication(arguments: rest)

        default:
            throw CLIError.message("Unknown profile subcommand: \(subcommand)")
        }
    }

    private static func moveProfiles(arguments: [String]) throws {
        let targets = positionals(in: arguments)
        guard !targets.isEmpty else {
            throw CLIError.message("Usage: thumble profile move <profile> [profile...] --to INDEX|--before PROFILE|--after PROFILE")
        }

        let toText = optionValue("--to", in: arguments)
        let beforeText = optionValue("--before", in: arguments)
        let afterText = optionValue("--after", in: arguments)
        let destinationCount = [toText, beforeText, afterText].compactMap { $0 }.count
        guard destinationCount == 1 else {
            throw CLIError.message("profile move needs exactly one of --to, --before, or --after")
        }

        let destination: ThumbleCLIProfileBackend.MoveDestination
        if let toText {
            let toIndex = try parseInteger(toText)
            guard toIndex >= 0 else {
                throw CLIError.message("Profile move index must be zero or greater")
            }
            destination = .index(toIndex)
        } else if let beforeText {
            destination = .before(.init(beforeText))
        } else if let afterText {
            destination = .after(.init(afterText))
        } else {
            throw CLIError.message("profile move needs --to, --before, or --after")
        }
        let response = try profileBackend().perform(
            .move(targets.map(ThumbleCLIProfileBackend.ProfileSelector.init), destination),
            invocationID: try profileInvocationID(in: arguments)
        )
        guard let outcome = response.outcome, let destinationDescription = outcome.destination else {
            throw CLIError.message("Rust profile authority returned no move outcome")
        }
        if outcome.profileNames.count == 1, let moved = outcome.profileNames.first {
            print("Moved profile \"\(moved)\" \(destinationDescription).")
        } else {
            print("Moved \(outcome.profileNames.count) profiles \(destinationDescription): \(outcome.profileNames.joined(separator: ", ")).")
        }
        printProfileInvocation(response)
    }

    private static func createProfile(arguments: [String]) throws {
        var nameParts: [String] = []
        var templateName: String?
        var fromProfile: String?
        var select = true
        var makeDefault = false
        var blank = false

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--template":
                index += 1
                guard index < arguments.count else { throw CLIError.message("Missing template name") }
                templateName = arguments[index]
            case "--from":
                index += 1
                guard index < arguments.count else { throw CLIError.message("Missing source profile") }
                fromProfile = arguments[index]
            case "--blank":
                blank = true
            case "--select":
                select = true
            case "--no-select":
                select = false
            case "--default":
                makeDefault = true
            case "--no-default":
                makeDefault = false
            default:
                if argument.hasPrefix("-") { throw CLIError.message("Unknown option: \(argument)") }
                nameParts.append(argument)
            }
            index += 1
        }

        var store = loadStore()
        let requestedName = nameParts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let baseCustomization: GamepadCustomization
        let baseOutputMode: GamepadProfileOutputMode
        let defaultName: String
        var baseLandscapeCustomization: GamepadCustomization? = nil
        var basePortraitCustomization: GamepadCustomization? = nil
        var baseOrientationPreference: GamepadProfileOrientationPreference = .automatic
        var baseBindings = decodedBindings(store.profileKeyBindings[store.activeProfileID.uuidString]) ?? DefaultKeypadKeyMap.defaultBindings
        var baseOutputBindings: [String: MacControlOutputBinding]?

        if let templateName {
            let template = try resolveTemplate(templateName)
            let profile = template.makeProfile()
            baseCustomization = profile.customization
            baseOutputMode = profile.outputMode
            baseLandscapeCustomization = profile.landscapeCustomization
            basePortraitCustomization = profile.portraitCustomization
            baseOrientationPreference = profile.orientationPreference
            defaultName = profile.name
            if let recommendedBindings = template.recommendedMacOutputBindings {
                baseBindings = recommendedBindings.keyboardBindings
                baseOutputBindings = rawOutputBindings(recommendedBindings)
            }
        } else if let fromProfile {
            let profile = try resolveProfile(fromProfile, in: store)
            baseCustomization = profile.customization
            baseOutputMode = profile.outputMode
            baseLandscapeCustomization = profile.landscapeCustomization
            basePortraitCustomization = profile.portraitCustomization
            baseOrientationPreference = profile.orientationPreference
            defaultName = "\(profile.name) Copy"
            baseBindings = decodedBindings(store.profileKeyBindings[profile.id.uuidString]) ?? baseBindings
            baseOutputBindings = store.profileOutputBindings[profile.id.uuidString]
        } else if blank {
            baseCustomization = .blankCanvas
            baseOutputMode = .keyboard
            defaultName = "Blank Setup"
        } else {
            baseCustomization = .defaultValue
            baseOutputMode = .keyboard
            defaultName = "Setup \(store.profiles.count + 1)"
        }

        var profile = GamepadConfigurationProfile(
            name: requestedName.isEmpty ? defaultName : requestedName,
            primaryCustomization: baseCustomization,
            orientationPreference: baseOrientationPreference,
            outputMode: baseOutputMode
        )
        if let baseLandscapeCustomization {
            profile.setCustomizationVariant(baseLandscapeCustomization, for: .landscape)
        }
        if let basePortraitCustomization {
            profile.setCustomizationVariant(basePortraitCustomization, for: .portrait)
        }
        store.profiles.append(profile)
        store.profileKeyBindings[profile.id.uuidString] = rawBindings(baseBindings)
        if let baseOutputBindings {
            store.profileOutputBindings[profile.id.uuidString] = baseOutputBindings
        }
        if select { store.activeProfileID = profile.id }
        if makeDefault { store.defaultProfileID = profile.id }
        try persistStore(store)
        print("Created profile \"\(profile.name)\".")
    }

    private static func exportProfiles(arguments: [String]) throws {
        let store = loadStore()
        let outputPath = optionValue("--output", in: arguments) ?? optionValue("-o", in: arguments)
        let exportAll = arguments.contains("--all")
        let target = firstPositional(in: arguments)

        let profiles: [GamepadConfigurationProfile]
        let activeID: UUID?
        let defaultID: UUID?
        if exportAll || target == nil {
            profiles = store.profiles
            activeID = store.activeProfileID
            defaultID = store.defaultProfileID
        } else {
            let profile = try resolveProfile(target, in: store)
            profiles = [profile]
            activeID = profile.id
            defaultID = store.defaultProfileID == profile.id ? profile.id : nil
        }
        let validIDs = Set(profiles.map { $0.id.uuidString })
        let bindings = store.profileKeyBindings.filter { validIDs.contains($0.key) }
        let envelope = ProfileExportEnvelope(profiles: profiles, activeProfileID: activeID, defaultProfileID: defaultID, profileKeyBindings: bindings, profileOutputBindings: store.profileOutputBindings.filter { validIDs.contains($0.key) })
        try writeJSON(envelope, to: outputPath)
    }

    private static func importProfiles(arguments: [String]) throws {
        guard let path = firstPositional(in: arguments) else { throw CLIError.message("Missing import path") }
        let select = !arguments.contains("--no-select")
        let makeDefault = arguments.contains("--default")
        let appendAsCopies = arguments.contains("--append")
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let decoder = JSONDecoder()
        var importedProfiles: [GamepadConfigurationProfile] = []
        var importedBindings: [String: [String: MacKeyBinding]] = [:]
        var importedOutputBindings: [String: [String: MacControlOutputBinding]] = [:]
        var importedActiveID: UUID?
        var importedDefaultID: UUID?

        if let envelope = try? decoder.decode(ProfileExportEnvelope.self, from: data) {
            importedProfiles = envelope.profiles.map(\.normalized)
            importedBindings = envelope.profileKeyBindings
            importedOutputBindings = envelope.profileOutputBindings
            importedActiveID = envelope.activeProfileID
            importedDefaultID = envelope.defaultProfileID
        } else if let generated = try? decoder.decode(GeneratedGameKeypadProfile.self, from: data) {
            importedProfiles = [generated.profile.normalized]
            let generatedBindings = try resolvedMacBindings(for: generated)
            importedBindings[generated.profile.id.uuidString] = rawBindings(generatedBindings)
            importedOutputBindings[generated.profile.id.uuidString] = rawOutputBindings(outputBindings(from: generatedBindings))
            importedActiveID = generated.profile.id
        } else if let profile = try? decoder.decode(GamepadConfigurationProfile.self, from: data) {
            importedProfiles = [profile.normalized]
            importedActiveID = profile.id
        } else if let profiles = try? decoder.decode([GamepadConfigurationProfile].self, from: data), !profiles.isEmpty {
            importedProfiles = profiles.map(\.normalized)
            importedActiveID = profiles.first?.id
        } else if let customization = try? decoder.decode(GamepadCustomization.self, from: data) {
            let name = optionValue("--name", in: arguments) ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            let profile = GamepadConfigurationProfile(name: name, primaryCustomization: customization)
            importedProfiles = [profile]
            importedActiveID = profile.id
        } else {
            throw CLIError.message("Unsupported profile import JSON")
        }

        guard !importedProfiles.isEmpty else { throw CLIError.message("Import did not contain any profiles") }
        var store = loadStore()
        var importedIDMap: [UUID: UUID] = [:]
        var destinationIDs: [UUID] = []
        var claimedDestinationIDs = Set<UUID>()

        func uniqueName(_ requestedName: String, excluding profileID: UUID? = nil) -> String {
            let base = requestedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Imported Setup" : requestedName
            let names = Set(store.profiles.filter { $0.id != profileID }.map { $0.name.lowercased() })
            guard names.contains(base.lowercased()) else { return base }
            var suffix = 2
            while names.contains("\(base) \(suffix)".lowercased()) { suffix += 1 }
            return "\(base) \(suffix)"
        }

        for imported in importedProfiles {
            var profile = imported.normalized
            if appendAsCopies {
                profile.id = UUID()
                profile.name = uniqueName(profile.name)
                profile.updatedAt = Date.currentMilliseconds
                store.profiles.append(profile)
            } else if let existingIndex = store.profiles.firstIndex(where: { candidate in
                guard !claimedDestinationIDs.contains(candidate.id) else { return false }
                return candidate.id == imported.id || sameProfileName(candidate.name, profile.name)
            }) {
                profile.id = store.profiles[existingIndex].id
                profile.updatedAt = Date.currentMilliseconds
                store.profiles[existingIndex] = profile
            } else {
                profile.name = uniqueName(profile.name)
                store.profiles.append(profile)
            }

            claimedDestinationIDs.insert(profile.id)
            importedIDMap[imported.id] = profile.id
            destinationIDs.append(profile.id)

            if let raw = importedBindings[imported.id.uuidString] {
                store.profileKeyBindings[profile.id.uuidString] = raw
            } else if store.profileKeyBindings[profile.id.uuidString] == nil {
                store.profileKeyBindings[profile.id.uuidString] = rawBindings(DefaultKeypadKeyMap.defaultBindings)
            }
            if let rawOutput = importedOutputBindings[imported.id.uuidString] {
                store.profileOutputBindings[profile.id.uuidString] = rawOutput
            } else if store.profileOutputBindings[profile.id.uuidString] == nil {
                let keys = decodedBindings(store.profileKeyBindings[profile.id.uuidString]) ?? DefaultKeypadKeyMap.defaultBindings
                store.profileOutputBindings[profile.id.uuidString] = rawOutputBindings(outputBindings(from: keys))
            }
        }

        guard let firstDestinationID = destinationIDs.first else { throw CLIError.message("Import did not contain any usable profiles") }
        let importedSelectedID = importedActiveID.flatMap { importedIDMap[$0] } ?? firstDestinationID
        if select {
            store.activeProfileID = importedSelectedID
        }
        if makeDefault {
            store.defaultProfileID = importedDefaultID.flatMap { importedIDMap[$0] } ?? importedSelectedID
        }
        try persistStore(store)
        print("Imported \(importedProfiles.count) profile\(importedProfiles.count == 1 ? "" : "s")\(appendAsCopies ? " as copies" : "").")
    }

    private static func attachApplicationToProfile(arguments: [String]) throws {
        let profileTarget = optionValue("--profile", in: arguments) ?? firstPositional(in: arguments)
        let path = optionValue("--path", in: arguments)
            ?? optionValue("--app", in: arguments)
            ?? optionValue("--application", in: arguments)
        let bundleIdentifier = optionValue("--bundle-id", in: arguments)
            ?? optionValue("--bundle", in: arguments)
        let applicationURL = try resolveApplicationURL(path: path, bundleIdentifier: bundleIdentifier)
        let launchTarget = GamepadProfileLaunchTarget.application(url: applicationURL)

        var store = loadStore()
        let index = try resolveProfileIndex(profileTarget, in: store)
        store.profiles[index].launchTarget = launchTarget
        store.profiles[index].updatedAt = Date.currentMilliseconds
        let profileName = store.profiles[index].name
        try persistStore(store)
        print("Attached \"\(launchTarget.displayName)\" to profile \"\(profileName)\".")
    }

    private static func detachApplicationFromProfile(arguments: [String]) throws {
        let profileTarget = optionValue("--profile", in: arguments) ?? firstPositional(in: arguments)
        var store = loadStore()
        let index = try resolveProfileIndex(profileTarget, in: store)
        let removedName = store.profiles[index].launchTarget?.displayName
        store.profiles[index].launchTarget = nil
        store.profiles[index].updatedAt = Date.currentMilliseconds
        let profileName = store.profiles[index].name
        try persistStore(store)
        if let removedName {
            print("Removed \"\(removedName)\" from profile \"\(profileName)\".")
        } else {
            print("Profile \"\(profileName)\" did not have an attached application.")
        }
    }

    private static func launchAttachedApplication(arguments: [String]) throws {
        let profileTarget = optionValue("--profile", in: arguments) ?? firstPositional(in: arguments)
        let store = loadStore()
        let profile = try resolveProfile(profileTarget, in: store)
        guard let launchTarget = profile.launchTarget else {
            throw CLIError.message("Profile \"\(profile.name)\" does not have an attached application.")
        }
        try openLaunchTarget(launchTarget)
        print("Launched \"\(launchTarget.displayName)\" from profile \"\(profile.name)\".")
    }

    private static func resolveApplicationURL(path: String?, bundleIdentifier: String?) throws -> URL {
        if let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            let expandedPath = (path as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expandedPath).standardizedFileURL
            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                throw CLIError.message("Application not found at path: \(path)")
            }
            guard url.pathExtension.lowercased() == "app" || Bundle(url: url)?.bundleIdentifier != nil else {
                throw CLIError.message("Path must point to a macOS .app bundle: \(path)")
            }
            return url
        }

        if let bundleIdentifier = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines), !bundleIdentifier.isEmpty {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
                throw CLIError.message("No installed application found for bundle id: \(bundleIdentifier)")
            }
            return url.standardizedFileURL
        }

        throw CLIError.message("Usage: thumble profile attach-app [PROFILE|--profile PROFILE] --path /Applications/App.app or --bundle-id com.example.App")
    }

    private static func openLaunchTarget(_ launchTarget: GamepadProfileLaunchTarget) throws {
        if let applicationURL = launchTarget.resolvedApplicationURL() {
            try runProcess("/usr/bin/open", arguments: [applicationURL.path])
            return
        }

        if let bundleIdentifier = launchTarget.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines), !bundleIdentifier.isEmpty {
            try runProcess("/usr/bin/open", arguments: ["-b", bundleIdentifier])
            return
        }

        throw CLIError.message("Could not resolve attached application \"\(launchTarget.displayName)\". Reattach it with `thumble profile attach-app`.")
    }

    // MARK: - Templates

    private static func template(arguments: [String]) throws {
        guard let subcommand = arguments.first else { throw CLIError.message("Missing template subcommand") }
        let rest = Array(arguments.dropFirst())
        switch subcommand {
        case "list", "ls":
            if rest.contains("--json") {
                let rows = GamepadControllerTemplate.allCases.map { ["id": $0.rawValue, "name": $0.displayName, "description": $0.description] }
                try printJSON(rows)
            } else {
                for template in GamepadControllerTemplate.allCases {
                    print("\(template.rawValue)\t\(template.displayName) — \(template.description)")
                }
            }
        case "install", "create", "add":
            guard let name = firstPositional(in: rest) else { throw CLIError.message("Missing template name") }
            let template = try resolveTemplate(name)
            guard let authorityTemplate = ThumbleCLIProfileBackend.ControllerTemplate(
                rawValue: template.rawValue
            ) else {
                throw CLIError.message("Template is unavailable through Rust profile authority")
            }
            let customName = optionValue("--name", in: rest)
            let select = !rest.contains("--no-select")
            let makeDefault = rest.contains("--default") && !rest.contains("--no-default")
            let response = try profileBackend().perform(
                .templateInstall(
                    authorityTemplate,
                    name: customName,
                    select: select,
                    makeDefault: makeDefault
                ),
                invocationID: try profileInvocationID(in: rest)
            )
            guard let installedName = response.outcome?.profileNames.first else {
                throw CLIError.message("Rust profile authority returned no template-install outcome")
            }
            print("Installed template \"\(installedName)\".")
            printProfileInvocation(response)
        case "show":
            guard let name = firstPositional(in: rest) else { throw CLIError.message("Missing template name") }
            let template = try resolveTemplate(name)
            try printJSON(template.makeProfile())
        default:
            throw CLIError.message("Unknown template subcommand: \(subcommand)")
        }
    }

    // MARK: - Themes

    private static func theme(arguments: [String]) throws {
        guard let subcommand = arguments.first else { throw CLIError.message("Missing theme subcommand") }
        let rest = Array(arguments.dropFirst())
        switch subcommand {
        case "list", "ls":
            let summaries = GamepadThemePreset.allCases.map { themeSummary(for: $0) }
            if rest.contains("--json") {
                try printJSON(summaries)
            } else {
                for summary in summaries {
                    print("\(summary.id)\t\(summary.name) — \(summary.description)")
                }
            }
        case "show":
            guard let name = firstPositional(in: rest) else { throw CLIError.message("Usage: thumble theme show <theme-id>") }
            let preset = try resolveThemePreset(name)
            try printJSON(themeSummary(for: preset))
        case "apply", "set":
            try requireExplicitUnmigratedProfileAccess(operation: "theme apply")
            guard let name = firstPositional(in: rest) else { throw CLIError.message("Usage: thumble theme apply <theme-id> [--profile PROFILE]") }
            let preset = try resolveThemePreset(name)
            try mutateCustomization(profileTarget: optionValue("--profile", in: rest)) { customization in
                preset.apply(to: &customization)
            }
            print("Applied theme \"\(preset.displayName)\".")
        default:
            throw CLIError.message("Unknown theme subcommand: \(subcommand)")
        }
    }

    private static func resolveThemePreset(_ value: String) throws -> GamepadThemePreset {
        guard let preset = GamepadThemePreset.resolve(value) else {
            let ids = GamepadThemePreset.allCases.map(\.rawValue).joined(separator: ", ")
            throw CLIError.message("Unknown theme: \(value). Available themes: \(ids)")
        }
        return preset
    }

    private static func themeSummary(for preset: GamepadThemePreset) -> ThemeSummary {
        ThemeSummary(id: preset.rawValue, name: preset.displayName, description: preset.description)
    }

    // MARK: - Shareable skins

    private static func skin(arguments: [String]) throws {
        guard let subcommand = arguments.first else {
            throw CLIError.message("Missing skin subcommand. Use artboard, scaffold, compile, preview, quality, list, inspect, validate, import, apply, detach, export, pack, or unpack.")
        }
        let rest = Array(arguments.dropFirst())
        switch subcommand {
        case "artboard", "artboards":
            guard let action = rest.first else {
                throw CLIError.message("Usage: thumble skin artboard list|show|export")
            }
            let artboardArguments = Array(rest.dropFirst())
            switch action {
            case "list", "ls":
                let artboards = ThumbleSkinArtboardCatalog.all
                if artboardArguments.contains("--json") {
                    try printJSON(artboards)
                } else {
                    for artboard in artboards {
                        let orientations = artboard.variants.map(\.orientation.rawValue).joined(separator: ",")
                        print("\(artboard.id)\t\(artboard.name) [\(orientations)]")
                    }
                }
            case "show", "inspect":
                guard let value = firstPositional(in: artboardArguments),
                      let artboard = ThumbleSkinArtboardCatalog.resolve(value)
                else { throw CLIError.message("Usage: thumble skin artboard show ARTBOARD [--json]") }
                if artboardArguments.contains("--json") {
                    try printJSON(artboard)
                } else {
                    print("Name: \(artboard.name)")
                    print("ID: \(artboard.id)")
                    print("Template: \(artboard.templateID) revision \(artboard.revision)")
                    print("Summary: \(artboard.summary)")
                    print("Orientations: \(artboard.variants.map(\.orientation.rawValue).joined(separator: ", "))")
                    print("Roles: \(artboard.expectedRoles.map(\.rawValue).joined(separator: ", "))")
                }
            case "export":
                guard let value = firstPositional(in: artboardArguments),
                      let profile = ThumbleSkinArtboardCatalog.profile(for: value)
                else { throw CLIError.message("Usage: thumble skin artboard export ARTBOARD -o profile.json") }
                guard let output = optionValue("--output", in: artboardArguments) ?? optionValue("-o", in: artboardArguments) else {
                    throw CLIError.message("skin artboard export requires -o <profile.json>")
                }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                try encoder.encode(profile).write(to: URL(fileURLWithPath: output), options: .atomic)
                print("Exported canonical \(value) artboard profile to \(output).")
            default:
                throw CLIError.message("Unknown skin artboard subcommand: \(action)")
            }

        case "scaffold", "new":
            guard let name = firstPositional(in: rest) else {
                throw CLIError.message("Usage: thumble skin scaffold NAME --identifier REVERSE.DNS.ID [-o DIRECTORY] [--artboard ARTBOARD] [--force]")
            }
            guard let identifier = optionValue("--identifier", in: rest) else {
                throw CLIError.message("skin scaffold requires --identifier <reverse.dns.id>")
            }
            let artboardID = optionValue("--artboard", in: rest) ?? ThumbleSkinArtboardCatalog.defaultID
            let output = optionValue("--output", in: rest) ?? optionValue("-o", in: rest)
                ?? name.replacingOccurrences(of: " ", with: "-")
            _ = try ThumbleSkinScaffolder.write(
                name: name,
                identifier: identifier,
                artboardID: artboardID,
                to: URL(fileURLWithPath: output),
                force: rest.contains("--force")
            )
            print("Created editable skin workspace at \(output).")

        case "compile", "build":
            guard let input = firstPositional(in: rest) else {
                throw CLIError.message("Usage: thumble skin compile SOURCE [-o skin.pocketpad] [--build-directory DIRECTORY] [--clean] [--strict] [--json]")
            }
            let buildDirectory = optionValue("--build-directory", in: rest).map { URL(fileURLWithPath: $0) }
            let output = (optionValue("--output", in: rest) ?? optionValue("-o", in: rest)).map { URL(fileURLWithPath: $0) }
            let result = try MainActor.assumeIsolated {
                try ThumbleSkinCompiler.compile(
                    source: URL(fileURLWithPath: input),
                    buildDirectory: buildDirectory,
                    packageOutputURL: output,
                    clean: rest.contains("--clean"),
                    strict: rest.contains("--strict")
                )
            }
            if rest.contains("--json") {
                try printJSON(result.sourceReport)
            } else {
                print("Compiled \(result.workspace.name) to \(result.packageURL.path).")
                if !result.sourceReport.warnings.isEmpty {
                    for issue in result.sourceReport.warnings {
                        print("- WARNING \(issue.code): \(issue.message)")
                    }
                }
            }

        case "list", "ls":
            let store = try ThumbleSkinStore()
            try store.installBundledSkinsIfNeeded()
            let rows = try store.installedSkins().map { installed in
                SkinListSummary(
                    identifier: installed.reference.identifier,
                    version: installed.reference.version,
                    name: installed.manifest.name,
                    author: installed.manifest.author.name,
                    license: installed.manifest.license,
                    kind: installed.manifest.kind,
                    isBundled: installed.isBundled,
                    path: installed.fileURL.path
                )
            }
            if rest.contains("--json") {
                try printJSON(rows)
            } else if rows.isEmpty {
                print("No Thumble skins are installed.")
            } else {
                for row in rows {
                    let badge = row.isBundled ? "built-in" : "installed"
                    print("\(row.identifier)@\(row.version)\t\(row.name) — \(row.author) [\(badge)]")
                }
            }

        case "inspect", "show":
            guard let target = firstPositional(in: rest) else {
                throw CLIError.message("Usage: thumble skin inspect <package-path|identifier[@version]>")
            }
            let package = try resolveSkinPackage(target).package
            let summary = skinInspectionSummary(package)
            if rest.contains("--json") {
                try printJSON(summary)
            } else {
                printSkinInspection(summary)
            }

        case "validate", "check":
            guard let target = firstPositional(in: rest) else {
                throw CLIError.message("Usage: thumble skin validate <package-path|directory> [--strict] [--json]")
            }
            let package = try resolveSkinPackage(target).package
            let report = ThumbleSkinPackageValidator.validate(package)
            if rest.contains("--json") {
                try printJSON(report)
            } else {
                printValidationReport(report)
            }
            if !report.isValid {
                throw CLIError.validationFailed("Skin validation failed with \(report.errors.count) error(s).")
            }
            if rest.contains("--strict"), !report.warnings.isEmpty {
                throw CLIError.validationFailed("Strict skin validation failed with \(report.warnings.count) warning(s).")
            }

        case "quality", "qa":
            guard let target = firstPositional(in: rest) else {
                throw CLIError.message("Usage: thumble skin quality SOURCE|PACKAGE [--artboard ARTBOARD] [--strict] [--json]")
            }
            let targetURL = URL(fileURLWithPath: target)
            let workspace: ThumbleSkinWorkspace?
            let package: ThumbleSkinPackage
            if ThumbleSkinCompiler.containsWorkspace(at: targetURL) {
                let loaded = try ThumbleSkinCompiler.loadWorkspace(from: targetURL)
                workspace = loaded.workspace
                let temporary = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ThumbleSkinQuality-\(UUID().uuidString)", isDirectory: true)
                defer { try? FileManager.default.removeItem(at: temporary) }
                let compiled = try MainActor.assumeIsolated {
                    try ThumbleSkinCompiler.compile(
                        source: targetURL,
                        buildDirectory: temporary.appendingPathComponent("build", isDirectory: true),
                        packageOutputURL: temporary.appendingPathComponent("quality.pocketpad"),
                        clean: true,
                        strict: false
                    )
                }
                package = compiled.package
            } else {
                workspace = nil
                package = try resolveSkinPackage(target).package
            }
            let report = ThumbleSkinQualityEvaluator.evaluate(
                package: package,
                workspace: workspace,
                artboardID: optionValue("--artboard", in: rest)
            )
            if rest.contains("--json") {
                try printJSON(report)
            } else {
                printSkinQualityReport(report)
            }
            if !report.isPassing {
                throw CLIError.validationFailed("Skin quality failed with \(report.errors.count) error(s).")
            }
            if rest.contains("--strict"), !report.warnings.isEmpty {
                throw CLIError.validationFailed("Strict skin quality failed with \(report.warnings.count) warning(s).")
            }

        case "import", "install":
            guard let target = firstPositional(in: rest) else {
                throw CLIError.message("Usage: thumble skin import <package-path|directory> [--replace|--allow-downgrade]")
            }
            let resolved = try resolveSkinPackage(target, requiresInstalledLookup: false)
            let packageData = try resolved.data ?? ThumbleSkinPackageCodec.encode(resolved.package)
            let store = try ThumbleSkinStore()
            try store.installBundledSkinsIfNeeded()
            let policy: ThumbleSkinInstallPolicy = rest.contains("--allow-downgrade")
                ? .allowDowngrade
                : (rest.contains("--replace") ? .replaceSameVersion : .newerOnly)
            let result = try store.install(data: packageData, policy: policy)
            notifySkinStoreChanged()
            print("Installed \(result.reference.identifier)@\(result.reference.version).")

        case "apply", "set":
            guard let target = firstPositional(in: rest) else {
                throw CLIError.message("Usage: thumble skin apply <package-path|identifier[@version]> [--profile PROFILE] [--appearance light|dark]")
            }
            let resolved = try resolveSkinPackage(target)
            let skinStore = try ThumbleSkinStore()
            let reference = ThumbleSkinReference(
                identifier: resolved.package.manifest.identifier,
                version: resolved.package.manifest.version
            )
            let packageData = try resolved.data ?? ThumbleSkinPackageCodec.encode(resolved.package)
            let installedData = try? skinStore.packageData(for: reference)
            if installedData != packageData {
                _ = try skinStore.install(
                    data: packageData,
                    policy: rest.contains("--allow-downgrade") ? .allowDowngrade : .replaceSameVersion
                )
                notifySkinStoreChanged()
            }
            var profileStore = loadStore()
            let profileIndex = try resolveProfileIndex(optionValue("--profile", in: rest), in: profileStore)
            let scheme = try parseSkinColorScheme(optionValue("--appearance", in: rest) ?? optionValue("--scheme", in: rest) ?? "light")
            profileStore.profiles[profileIndex].applySkin(resolved.package, colorScheme: scheme)
            let profileName = profileStore.profiles[profileIndex].name
            try persistStore(profileStore)
            print("Applied \(resolved.package.manifest.name) to \(profileName).")

        case "detach", "fork":
            var profileStore = loadStore()
            let profileIndex = try resolveProfileIndex(optionValue("--profile", in: rest) ?? firstPositional(in: rest), in: profileStore)
            guard let reference = profileStore.profiles[profileIndex].skinReference else {
                print("\(profileStore.profiles[profileIndex].name) already uses local appearance.")
                return
            }
            let scheme = try parseSkinColorScheme(optionValue("--appearance", in: rest) ?? "light")
            if let package = try? ThumbleSkinStore().package(for: reference) {
                profileStore.profiles[profileIndex].detachSkin(resolving: package, colorScheme: scheme)
            } else {
                profileStore.profiles[profileIndex].detachSkin()
            }
            let profileName = profileStore.profiles[profileIndex].name
            try persistStore(profileStore)
            print("Forked the current appearance for \(profileName).")

        case "remove", "delete", "rm":
            guard let target = firstPositional(in: rest) else {
                throw CLIError.message("Usage: thumble skin remove <identifier[@version]>")
            }
            let resolved = try resolveSkinPackage(target)
            let reference = ThumbleSkinReference(
                identifier: resolved.package.manifest.identifier,
                version: resolved.package.manifest.version
            )
            let store = try ThumbleSkinStore()
            if (try store.installedSkins().first(where: { $0.reference == reference }))?.isBundled == true {
                throw CLIError.message("Built-in skins cannot be removed.")
            }
            if let profile = loadStore().profiles.first(where: { $0.skinReference == reference }) {
                throw CLIError.message("Skin is still used by profile \"\(profile.name)\". Run `thumble skin detach --profile \"\(profile.name)\"` first.")
            }
            try store.remove(reference)
            notifySkinStoreChanged()
            print("Removed \(reference.identifier)@\(reference.version).")

        case "export", "share":
            guard let target = firstPositional(in: rest) else {
                throw CLIError.message("Usage: thumble skin export <identifier[@version]> -o skin.pocketpad")
            }
            let resolved = try resolveSkinPackage(target)
            let output = optionValue("--output", in: rest) ?? optionValue("-o", in: rest)
                ?? suggestedSkinFilename(manifest: resolved.package.manifest)
            let data = try resolved.data ?? ThumbleSkinPackageCodec.encode(resolved.package)
            try data.write(to: URL(fileURLWithPath: output), options: [.atomic])
            print("Exported \(resolved.package.manifest.name) to \(output).")

        case "pack":
            guard let input = firstPositional(in: rest) else {
                throw CLIError.message("Usage: thumble skin pack <directory|manifest.json> -o skin.pocketpad")
            }
            guard let output = optionValue("--output", in: rest) ?? optionValue("-o", in: rest) else {
                throw CLIError.message("skin pack requires -o <file.pocketpad>")
            }
            let inputURL = URL(fileURLWithPath: input)
            let sourceCandidate = ThumbleSkinCompiler.sourceURL(for: inputURL)
            if sourceCandidate.lastPathComponent == ThumbleSkinScaffolder.sourceFileName,
               FileManager.default.fileExists(atPath: sourceCandidate.path) {
                throw CLIError.message("Editable skin sources must be compiled first. Run `thumble skin compile \(input) -o \(output)`.")
            }
            let package = try loadSkinPackageDirectory(at: inputURL)
            let data = try ThumbleSkinPackageCodec.encode(package)
            try data.write(to: URL(fileURLWithPath: output), options: [.atomic])
            print("Packed \(package.manifest.name) to \(output).")

        case "unpack":
            guard let input = firstPositional(in: rest) else {
                throw CLIError.message("Usage: thumble skin unpack <skin.pocketpad> -o <directory> [--force]")
            }
            guard let output = optionValue("--output", in: rest) ?? optionValue("-o", in: rest) else {
                throw CLIError.message("skin unpack requires -o <directory>")
            }
            let data = try Data(contentsOf: URL(fileURLWithPath: input), options: [.mappedIfSafe])
            let package = try ThumbleSkinPackageCodec.decode(data)
            try writeSkinPackageDirectory(package, to: URL(fileURLWithPath: output), force: rest.contains("--force"))
            print("Unpacked \(package.manifest.name) to \(output).")

        case "render", "preview":
            try renderSkinPreview(command: subcommand, arguments: rest)

        default:
            throw CLIError.message("Unknown skin subcommand: \(subcommand)")
        }
    }

    private static func renderSkinPreview(command: String, arguments: [String]) throws {
        guard let target = firstPositional(in: arguments) else {
            throw CLIError.message("Usage: thumble skin preview SOURCE|PACKAGE -o OUTPUT [--all-variants] [--all-states] [--contact-sheet]")
        }
        guard let output = optionValue("--output", in: arguments) ?? optionValue("-o", in: arguments) else {
            throw CLIError.message("skin \(command) requires -o <preview.png|frames-directory>")
        }

        let targetURL = URL(fileURLWithPath: target)
        let workspace: ThumbleSkinWorkspace?
        let package: ThumbleSkinPackage
        if ThumbleSkinCompiler.containsWorkspace(at: targetURL) {
            let loaded = try ThumbleSkinCompiler.loadWorkspace(from: targetURL)
            workspace = loaded.workspace
            let temporary = FileManager.default.temporaryDirectory
                .appendingPathComponent("ThumbleSkinPreview-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let result = try MainActor.assumeIsolated {
                try ThumbleSkinCompiler.compile(
                    source: targetURL,
                    buildDirectory: temporary.appendingPathComponent("build", isDirectory: true),
                    packageOutputURL: temporary.appendingPathComponent("preview.pocketpad"),
                    clean: true,
                    strict: arguments.contains("--strict")
                )
            }
            package = result.package
        } else {
            workspace = nil
            package = try resolveSkinPackage(target).package
        }

        let profileStore = loadStore()
        let profile: GamepadConfigurationProfile
        if let requested = optionValue("--profile", in: arguments) {
            profile = try resolveProfile(requested, in: profileStore)
        } else if let requestedArtboard = optionValue("--artboard", in: arguments),
                  let canonical = ThumbleSkinArtboardCatalog.profile(for: requestedArtboard) {
            profile = canonical
        } else if let workspace,
                  let canonical = ThumbleSkinArtboardCatalog.profile(for: workspace.artboardID) {
            profile = canonical
        } else if let templateID = package.manifest.compatibility?.templates.first?.templateID,
                  let canonical = ThumbleSkinArtboardCatalog.profile(for: templateID) {
            profile = canonical
        } else if let canonical = ThumbleSkinArtboardCatalog.profile(for: ThumbleSkinArtboardCatalog.defaultID) {
            profile = canonical
        } else {
            profile = try resolveProfile(nil, in: profileStore)
        }

        let requestsAllVariants = arguments.contains("--all-variants")
        let requestsAllStates = arguments.contains("--all-states")
        let orientationValue = optionValue("--orientation", in: arguments)
            ?? optionValue("--variant", in: arguments)
        let appearanceValue = optionValue("--appearance", in: arguments)
            ?? optionValue("--scheme", in: arguments)
        let stateValue = optionValue("--state", in: arguments)
        let compatibleOrientations = package.manifest.compatibility?.normalized.orientations ?? []
        let orientations: [ThumbleSkinOrientation]
        if requestsAllVariants || orientationValue?.lowercased() == "all" {
            orientations = compatibleOrientations.isEmpty ? ThumbleSkinOrientation.allCases : compatibleOrientations
        } else if let orientationValue {
            let parsed = try parseDeviceOrientation(orientationValue)
            orientations = [parsed == .portrait ? .portrait : .landscape]
        } else {
            orientations = [profile.customization.deviceCanvas.editorDeviceFrame.orientation == .portrait ? .portrait : .landscape]
        }
        let schemes: [ThumbleSkinColorScheme]
        if requestsAllVariants || appearanceValue?.lowercased() == "all" {
            schemes = ThumbleSkinColorScheme.allCases
        } else {
            schemes = [try parseSkinColorScheme(appearanceValue ?? "light")]
        }
        let states: [GamepadControlPresentationState]
        if requestsAllStates || stateValue?.lowercased() == "all" {
            states = GamepadControlPresentationState.allCases
        } else if let stateValue,
                  let state = GamepadControlPresentationState(rawValue: stateValue.lowercased()) {
            states = [state]
        } else if stateValue != nil {
            throw CLIError.message("Invalid skin state. Use normal, pressed, active, disabled, or all.")
        } else {
            states = [.normal]
        }
        let scaleText = optionValue("--render-scale", in: arguments)
            ?? optionValue("--image-scale", in: arguments)
            ?? optionValue("--scale", in: arguments)
            ?? (arguments.contains("--contact-sheet") ? "1" : "2")
        guard let scale = Double(scaleText), scale.isFinite else {
            throw CLIError.message("Preview scale must be a number between 0.5 and 4.")
        }

        let preserveOverrides = arguments.contains("--preserve-overrides")
        var items: [ThumbleNativeSkinPreviewItem] = []
        for orientation in orientations {
            let deviceOrientation: GamepadEditorDeviceOrientation = orientation == .portrait ? .portrait : .landscape
            let source = profile.customization(for: deviceOrientation)
            for scheme in schemes {
                let rendered = source.applying(
                    skinPackage: package,
                    orientation: orientation,
                    colorScheme: scheme,
                    options: preserveOverrides ? .preservingUserOverrides : .replacingAppearance,
                    overrideBaseline: preserveOverrides ? profile.skinBaseline(for: deviceOrientation) : nil
                )
                for state in states {
                    items.append(ThumbleNativeSkinPreviewItem(
                        title: "\(orientation.rawValue) · \(scheme.rawValue) · \(state.rawValue)",
                        customization: rendered,
                        colorScheme: scheme,
                        state: state
                    ))
                }
            }
        }

        let outputURL = URL(fileURLWithPath: output)
        let contactSheet = arguments.contains("--contact-sheet")
        if contactSheet {
            let columns = Int(optionValue("--columns", in: arguments) ?? "4") ?? 4
            try MainActor.assumeIsolated {
                try ThumbleNativeSkinPreviewRenderer.writeContactSheet(
                    items: items,
                    skinName: package.manifest.name,
                    outputURL: outputURL,
                    columns: columns,
                    scale: CGFloat(scale)
                )
            }
            print("Rendered \(items.count)-panel native contact sheet to \(output).")
        } else if items.count == 1, let item = items.first {
            try MainActor.assumeIsolated {
                try ThumbleNativeSkinPreviewRenderer.writePNG(
                    item: item,
                    outputURL: outputURL,
                    scale: CGFloat(scale)
                )
            }
            print("Rendered \(package.manifest.name) with the native renderer to \(output).")
        } else {
            let framesDirectory = outputURL.pathExtension.isEmpty
                ? outputURL
                : outputURL.deletingPathExtension().appendingPathExtension("frames")
            try FileManager.default.createDirectory(at: framesDirectory, withIntermediateDirectories: true)
            for item in items {
                let filename = item.title
                    .replacingOccurrences(of: " · ", with: "-")
                    .replacingOccurrences(of: " ", with: "-")
                    .lowercased() + ".png"
                try MainActor.assumeIsolated {
                    try ThumbleNativeSkinPreviewRenderer.writePNG(
                        item: item,
                        outputURL: framesDirectory.appendingPathComponent(filename),
                        scale: CGFloat(scale)
                    )
                }
            }
            print("Rendered \(items.count) native preview frames to \(framesDirectory.path).")
        }
    }

    private static func skinInspectionSummary(_ package: ThumbleSkinPackage) -> SkinInspectionSummary {
        SkinInspectionSummary(
            manifest: package.manifest,
            validation: ThumbleSkinPackageValidator.validate(package),
            variantIDs: package.skin?.normalized.variants.map(\.id) ?? [],
            assetIDs: package.manifest.assets.map(\.id),
            previewIDs: package.manifest.previews.map(\.id)
        )
    }

    private static func printSkinInspection(_ summary: SkinInspectionSummary) {
        let manifest = summary.manifest
        print("Name: \(manifest.name)")
        print("Identifier: \(manifest.identifier)")
        print("Version: \(manifest.version)")
        print("Kind: \(manifest.kind.rawValue)")
        print("Author: \(manifest.author.name)")
        print("License: \(manifest.license)")
        if !manifest.summary.isEmpty { print("Summary: \(manifest.summary)") }
        print("Variants: \(summary.variantIDs.isEmpty ? "base only" : summary.variantIDs.joined(separator: ", "))")
        print("Assets: \(summary.assetIDs.count)")
        print("Previews: \(summary.previewIDs.count)")
        printValidationReport(summary.validation)
    }

    private static func printSkinQualityReport(_ report: ThumbleSkinQualityReport) {
        let gate = report.isStrictlyPassing ? "publication-ready" : (report.isPassing ? "review required" : "blocked")
        print("Quality: \(gate) · score \(report.score)/100 · \(report.errors.count) error(s), \(report.warnings.count) warning(s)")
        if let artboard = report.checkedArtboardID { print("Artboard: \(artboard)") }
        for issue in report.issues {
            let path = issue.path.map { " [\($0)]" } ?? ""
            print("- \(issue.severity.rawValue.uppercased()) \(issue.code)\(path): \(issue.message)")
        }
    }

    private static func printValidationReport(_ report: ThumbleSkinValidationReport) {
        if report.issues.isEmpty {
            print("Validation: valid with no warnings")
            return
        }
        print("Validation: \(report.errors.count) error(s), \(report.warnings.count) warning(s)")
        for issue in report.issues {
            let path = issue.path.map { " [\($0)]" } ?? ""
            print("- \(issue.severity.rawValue.uppercased()) \(issue.code)\(path): \(issue.message)")
        }
    }

    private static func resolveSkinPackage(
        _ target: String,
        requiresInstalledLookup: Bool = true
    ) throws -> (package: ThumbleSkinPackage, data: Data?) {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: target, isDirectory: &isDirectory) {
            let url = URL(fileURLWithPath: target)
            if isDirectory.boolValue || url.lastPathComponent == "manifest.json" {
                let package = try loadSkinPackageDirectory(at: url)
                return (package, try ThumbleSkinPackageCodec.encode(package))
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            return (try ThumbleSkinPackageCodec.decode(data), data)
        }
        guard requiresInstalledLookup else {
            throw CLIError.message("Skin package not found: \(target)")
        }

        let (identifierOrName, requestedVersion) = splitSkinReference(target)
        let store = try ThumbleSkinStore()
        try store.installBundledSkinsIfNeeded()
        let candidates = try store.installedSkins().filter { installed in
            (installed.reference.identifier.caseInsensitiveCompare(identifierOrName) == .orderedSame
                || installed.manifest.name.caseInsensitiveCompare(identifierOrName) == .orderedSame)
                && (requestedVersion == nil || installed.reference.version == requestedVersion)
        }
        guard !candidates.isEmpty else { throw CLIError.message("Installed skin not found: \(target)") }
        let selected = candidates.max { lhs, rhs in
            (ThumbleSemanticVersion(lhs.reference.version) ?? ThumbleSemanticVersion("0.0.0")!)
                < (ThumbleSemanticVersion(rhs.reference.version) ?? ThumbleSemanticVersion("0.0.0")!)
        }!
        let data = try store.packageData(for: selected.reference)
        return (try ThumbleSkinPackageCodec.decode(data), data)
    }

    private static func splitSkinReference(_ target: String) -> (String, String?) {
        guard let separator = target.lastIndex(of: "@"), separator != target.startIndex else { return (target, nil) }
        let identifier = String(target[..<separator])
        let version = String(target[target.index(after: separator)...])
        guard ThumbleSemanticVersion(version) != nil else { return (target, nil) }
        return (identifier, version)
    }

    private static func loadSkinPackageDirectory(at inputURL: URL) throws -> ThumbleSkinPackage {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: inputURL.path, isDirectory: &isDirectory)
        guard exists else { throw CLIError.message("Skin package source not found: \(inputURL.path)") }
        let root = isDirectory.boolValue ? inputURL : inputURL.deletingLastPathComponent()
        let manifestURL = inputURL.lastPathComponent == "manifest.json" ? inputURL : root.appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode(ThumbleSkinManifest.self, from: Data(contentsOf: manifestURL)).normalized
        let skin = try manifest.skinPath.map { path in
            try JSONDecoder().decode(ThumbleSkin.self, from: Data(contentsOf: try safePackageFileURL(path, root: root)))
        }
        let profile = try manifest.profilePath.map { path in
            try JSONDecoder().decode(GamepadConfigurationProfile.self, from: Data(contentsOf: try safePackageFileURL(path, root: root)))
        }
        var assets: [String: Data] = [:]
        for descriptor in manifest.assets {
            guard assets[descriptor.id] == nil else { throw CLIError.message("Duplicate asset ID: \(descriptor.id)") }
            assets[descriptor.id] = try Data(
                contentsOf: safePackageFileURL(descriptor.path, root: root),
                options: [.mappedIfSafe]
            )
        }
        var previews: [String: Data] = [:]
        for descriptor in manifest.previews {
            guard previews[descriptor.id] == nil else { throw CLIError.message("Duplicate preview ID: \(descriptor.id)") }
            previews[descriptor.id] = try Data(
                contentsOf: safePackageFileURL(descriptor.path, root: root),
                options: [.mappedIfSafe]
            )
        }
        return ThumbleSkinPackage(
            manifest: manifest,
            skin: skin,
            profile: profile,
            assets: assets,
            previews: previews
        )
    }

    private static func safePackageFileURL(_ path: String, root: URL) throws -> URL {
        guard ThumbleSkinPackageCodec.isSafePackagePath(path) else {
            throw CLIError.message("Unsafe package path: \(path)")
        }
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(resolvedRoot.path + "/") else {
            throw CLIError.message("Package path escapes the source directory: \(path)")
        }
        return candidate
    }

    private static func writeSkinPackageDirectory(
        _ package: ThumbleSkinPackage,
        to root: URL,
        force: Bool
    ) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: root.path) {
            let contents = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
            guard contents.isEmpty || force else {
                throw CLIError.message("Output directory is not empty. Pass --force to replace it.")
            }
            if force { try fileManager.removeItem(at: root) }
        }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(package.manifest).write(to: root.appendingPathComponent("manifest.json"), options: [.atomic])
        if let skin = package.skin, let path = package.manifest.skinPath {
            try writePackageDirectoryFile(try encoder.encode(skin), path: path, root: root)
        }
        if let profile = package.profile, let path = package.manifest.profilePath {
            try writePackageDirectoryFile(try encoder.encode(profile), path: path, root: root)
        }
        for descriptor in package.manifest.assets {
            guard let data = package.assets[descriptor.id] else { continue }
            try writePackageDirectoryFile(data, path: descriptor.path, root: root)
        }
        for descriptor in package.manifest.previews {
            guard let data = package.previews[descriptor.id] else { continue }
            try writePackageDirectoryFile(data, path: descriptor.path, root: root)
        }
    }

    private static func writePackageDirectoryFile(_ data: Data, path: String, root: URL) throws {
        let url = try safePackageFileURL(path, root: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }

    private static func parseSkinColorScheme(_ value: String) throws -> ThumbleSkinColorScheme {
        switch value.lowercased() {
        case "light": .light
        case "dark": .dark
        default: throw CLIError.message("Unknown skin appearance: \(value). Use light or dark.")
        }
    }

    private static func suggestedSkinFilename(manifest: ThumbleSkinManifest) -> String {
        let base = manifest.name.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "\(base.isEmpty ? "thumble-skin" : base)-\(manifest.version).pocketpad"
    }

    private static func notifySkinStoreChanged() {
        DistributedNotificationCenter.default().post(name: skinStoreChangedNotificationName, object: nil)
    }

    // MARK: - Bindings

    private static func binding(arguments: [String]) throws {
        guard let subcommand = arguments.first else { throw CLIError.message("Missing binding subcommand") }
        let rest = Array(arguments.dropFirst())
        let target = ThumbleCLIProfileBackend.ProfileSelector(optionValue("--profile", in: rest))
        let invocationID = try profileInvocationID(in: rest)
        switch subcommand {
        case "display":
            let response = try profileBackend().perform(.bindingDisplay(target), invocationID: invocationID)
            guard let projection = response.projection,
                  projection.kind == .bindingDisplay
            else { throw CLIError.message("Rust profile authority returned no binding-display projection") }
            let presentations = try authorityBindingPresentations(projection)
            if rest.contains("--json") {
                try printJSON(presentations)
            } else {
                print("Binding display for \"\(projection.profileName)\":")
                for group in presentations {
                    let orientation = group.orientation?.rawValue.capitalized ?? "All orientations"
                    print("\(orientation):")
                    for entry in group.entries {
                        print("- \(entry.input.storageKey): \(entry.compactText) (\(entry.accessibilityText))")
                    }
                }
            }

        case "list", "ls":
            let response = try profileBackend().perform(.bindingList(target), invocationID: invocationID)
            guard let projection = response.projection,
                  projection.kind == .bindingList,
                  let rows = projection.rows
            else { throw CLIError.message("Rust profile authority returned no binding projection") }
            if rest.contains("--json") {
                try printJSON(projection)
            } else {
                print("Bindings for \"\(projection.profileName)\":")
                for row in rows {
                    print("- \(row.button.rawValue): \(try authorityOutput(row.output).displayName)")
                }
            }

        case "set":
            try setBinding(arguments: rest)

        case "reset", "clear", "unset":
            guard let buttonText = firstPositional(in: rest) else { throw CLIError.message("Missing button") }
            let button = try parseButton(buttonText)
            let command: ThumbleCLIProfileBackend.Command = subcommand == "reset"
                ? .bindingReset(target, button)
                : .bindingClear(target, button)
            let response = try profileBackend().perform(command, invocationID: invocationID)
            guard response.outcome != nil else { throw CLIError.message("Rust profile authority returned no binding outcome") }
            print(subcommand == "reset" ? "Reset binding for \(button.displayName)." : "Cleared binding for \(button.displayName).")
            printProfileInvocation(response)

        case "reset-all":
            let response = try profileBackend().perform(.bindingResetAll(target), invocationID: invocationID)
            guard response.outcome != nil else { throw CLIError.message("Rust profile authority returned no binding outcome") }
            print("Reset all bindings to setup defaults.")
            printProfileInvocation(response)

        default:
            throw CLIError.message("Unknown binding subcommand: \(subcommand)")
        }
    }

    private static func setBinding(arguments: [String]) throws {
        guard let buttonText = firstPositional(in: arguments) else { throw CLIError.message("Missing button") }
        let button = try parseButton(buttonText)
        let sequenceText = optionValue("--sequence", in: arguments)
        let keyText = optionValue("--key", in: arguments)
        let modifiersText = optionValue("--modifiers", in: arguments) ?? optionValue("--mods", in: arguments)
        let positional = positionals(in: arguments)
        let fallbackBindingText = positional.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)

        let binding: MacKeyBinding
        if let sequenceText {
            binding = try parseKeyBindingSequence(sequenceText)
        } else if let keyText {
            let modifiers = try parseModifiers(modifiersText)
            guard let keyCode = MacVirtualKey.keyCode(named: keyText) else { throw CLIError.message("Unsupported key: \(keyText)") }
            binding = MacKeyBinding(keyCode: keyCode, modifiers: modifiers)
        } else if !fallbackBindingText.isEmpty {
            binding = try parseKeyBindingSequence(fallbackBindingText)
        } else {
            throw CLIError.message("Missing binding. Use `binding set <button> <key>` or `--sequence Control+B,H`.")
        }

        let response = try profileBackend().perform(
            .bindingSet(
                .init(optionValue("--profile", in: arguments)),
                button,
                try authoritySemanticSequence(binding)
            ),
            invocationID: try profileInvocationID(in: arguments)
        )
        guard response.outcome != nil else {
            throw CLIError.message("Rust profile authority returned no binding outcome")
        }
        print("Mapped \(button.displayName) to \(binding.displayName).")
        printProfileInvocation(response)
    }

    // MARK: - Outputs

    private static func output(arguments: [String]) throws {
        guard let subcommand = arguments.first else { throw CLIError.message("Missing output subcommand") }
        let rest = Array(arguments.dropFirst())
        let target = ThumbleCLIProfileBackend.ProfileSelector(optionValue("--profile", in: rest))
        let invocationID = try profileInvocationID(in: rest)
        switch subcommand {
        case "list", "ls":
            let response = try profileBackend().perform(.outputList(target), invocationID: invocationID)
            guard let projection = response.projection,
                  projection.kind == .outputList,
                  let rows = projection.rows,
                  let mode = projection.outputMode
            else { throw CLIError.message("Rust profile authority returned no output projection") }
            if rest.contains("--json") {
                try printJSON(projection)
            } else {
                print("Outputs for \"\(projection.profileName)\":")
                print("Mode: \(authorityOutputModeName(mode))")
                for row in rows {
                    print("- \(row.button.rawValue): \(try authorityOutput(row.output).displayName)")
                }
            }
        case "mode", "preset":
            try outputMode(arguments: rest)
        case "set":
            try setOutput(arguments: rest)
        case "reset":
            guard let buttonText = firstPositional(in: rest) else { throw CLIError.message("Missing button") }
            let button = try parseButton(buttonText)
            let response = try profileBackend().perform(.outputReset(target, button), invocationID: invocationID)
            guard response.outcome != nil else { throw CLIError.message("Rust profile authority returned no output outcome") }
            print("Reset output for \(button.displayName).")
            printProfileInvocation(response)
        case "reset-all":
            let response = try profileBackend().perform(.outputResetAll(target), invocationID: invocationID)
            guard response.outcome != nil else { throw CLIError.message("Rust profile authority returned no output outcome") }
            print("Reset all outputs to setup keyboard defaults.")
            printProfileInvocation(response)
        default:
            throw CLIError.message("Unknown output subcommand: \(subcommand)")
        }
    }

    private static func outputMode(arguments: [String]) throws {
        let target = ThumbleCLIProfileBackend.ProfileSelector(optionValue("--profile", in: arguments))
        let modeText = firstPositional(in: arguments)
        if let modeText {
            let mode = try parseOutputMode(modeText)
            guard let typedMode = ThumbleCLIProfileBackend.OutputMode(rawValue: mode.rawValue) else {
                throw CLIError.message("Unsupported output mode")
            }
            let response = try profileBackend().perform(
                .outputMode(target, typedMode),
                invocationID: try profileInvocationID(in: arguments)
            )
            guard let profileName = response.outcome?.profileNames.first else {
                throw CLIError.message("Rust profile authority returned no output-mode outcome")
            }
            print("Set \"\(profileName)\" output mode to \(mode.displayName).")
            printProfileInvocation(response)
            return
        }
        let response = try profileBackend().perform(
            .outputModeGet(target),
            invocationID: try profileInvocationID(in: arguments)
        )
        guard let projection = response.projection,
              projection.kind == .outputMode,
              let mode = projection.outputMode
        else { throw CLIError.message("Rust profile authority returned no output-mode projection") }
        print("\(projection.profileName): \(authorityOutputModeName(mode))")
        print(authorityOutputModeDescription(mode))
    }

    private static func setOutput(arguments: [String]) throws {
        guard let buttonText = firstPositional(in: arguments) else { throw CLIError.message("Missing button") }
        let button = try parseButton(buttonText)
        let keyboardText = optionValue("--keyboard", in: arguments) ?? optionValue("--key", in: arguments)
        let sequenceText = optionValue("--sequence", in: arguments)
        let gamepadButtonText = optionValue("--gamepad-button", in: arguments) ?? optionValue("--gamepad", in: arguments)
        let clearKeyboard = arguments.contains("--clear-keyboard")
        let clearGamepad = arguments.contains("--clear-gamepad")

        let keyboardEdit: ThumbleCLIProfileBackend.KeyboardEdit
        if clearKeyboard {
            keyboardEdit = .clear
        } else if let sequenceText {
            keyboardEdit = .set(try authoritySemanticSequence(parseKeyBindingSequence(sequenceText)))
        } else if let keyboardText {
            keyboardEdit = .set(try authoritySemanticSequence(parseKeyBindingSequence(keyboardText)))
        } else {
            keyboardEdit = .keep
        }
        let gamepadEdit: ThumbleCLIProfileBackend.GamepadEdit
        if clearGamepad {
            gamepadEdit = .clear
        } else if let gamepadButtonText {
            let normalized = gamepadButtonText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized == "none" || normalized == "clear" || normalized == "off" {
                gamepadEdit = .clear
            } else {
                gamepadEdit = .set(try parseVirtualGamepadButton(gamepadButtonText))
            }
        } else {
            gamepadEdit = .keep
        }
        guard keyboardEdit != .keep || gamepadEdit != .keep else {
            throw CLIError.message("No output changes requested")
        }
        let response = try profileBackend().perform(
            .outputSet(
                .init(optionValue("--profile", in: arguments)),
                button,
                keyboardEdit,
                gamepadEdit
            ),
            invocationID: try profileInvocationID(in: arguments)
        )
        guard response.outcome != nil else {
            throw CLIError.message("Rust profile authority returned no output outcome")
        }
        print("Updated output for \(button.displayName).")
        printProfileInvocation(response)
    }

    private static func authoritySemanticSequence(
        _ binding: MacKeyBinding
    ) throws -> [ThumbleCLIProfileBackend.SemanticKeyStroke] {
        try binding.strokes.map { stroke in
            let key = MacVirtualKey.displayName(for: stroke.keyCode)
            guard MacVirtualKey.keyCode(named: key) == stroke.keyCode else {
                throw CLIError.message("Binding contains an unsupported semantic key")
            }
            var modifiers: [ThumbleCLIProfileBackend.SemanticModifier] = []
            if stroke.modifiers.contains(.command) { modifiers.append(.command) }
            if stroke.modifiers.contains(.shift) { modifiers.append(.shift) }
            if stroke.modifiers.contains(.option) { modifiers.append(.option) }
            if stroke.modifiers.contains(.control) { modifiers.append(.control) }
            return .init(key: key, modifiers: modifiers)
        }
    }

    private static func authorityOutput(
        _ output: ThumbleCLIProfileBackend.SemanticOutput?
    ) throws -> MacControlOutputBinding {
        guard let output else { return MacControlOutputBinding() }
        return MacControlOutputBinding(shared: try authoritySharedOutput(output))
    }

    private static func authoritySharedOutput(
        _ output: ThumbleCLIProfileBackend.SemanticOutput
    ) throws -> KeypadElementOutputBinding {
        let strokes = try output.keyboard.map { stroke -> KeypadKeyboardStrokeBinding in
            guard let keyCode = MacVirtualKey.keyCode(named: stroke.key) else {
                throw CLIError.message("Rust profile authority returned an unsupported semantic key")
            }
            var modifiers: MacKeyModifiers = []
            for modifier in stroke.modifiers {
                switch modifier {
                case .command: modifiers.insert(.command)
                case .shift: modifiers.insert(.shift)
                case .option: modifiers.insert(.option)
                case .control: modifiers.insert(.control)
                }
            }
            return KeypadKeyboardStrokeBinding(
                keyCode: UInt16(keyCode),
                modifiersRawValue: modifiers.rawValue
            )
        }
        let keyboard = strokes.first.map { first in
            KeypadKeyboardBinding(
                keyCode: first.keyCode,
                modifiersRawValue: first.modifiersRawValue,
                sequence: strokes.count > 1 ? strokes : nil
            )
        }
        return KeypadElementOutputBinding(
            keyboard: keyboard,
            gamepadButtons: Set(output.gamepadButtons)
        )
    }

    private static func authorityBindingPresentations(
        _ projection: ThumbleCLIProfileBackend.BindingOutputProjection
    ) throws -> [GamepadProfileBindingPresentations] {
        try (projection.displayGroups ?? []).map { group in
            let orientation = group.orientation.flatMap {
                GamepadEditorDeviceOrientation(rawValue: $0.rawValue)
            }
            let entries = try group.entries.compactMap { entry -> KeypadBindingPresentation? in
                guard let part = KeypadElementInputPart(rawValue: entry.part.rawValue) else {
                    throw CLIError.message("Rust profile authority returned an unsupported element input part")
                }
                guard let formatted = KeypadBindingFormatter.format(try authoritySharedOutput(entry.output)) else {
                    return nil
                }
                return KeypadBindingPresentation(
                    input: KeypadElementInputID(elementID: entry.elementID, part: part),
                    compactText: formatted.compactText,
                    accessibilityText: formatted.accessibilityText
                )
            }
            return GamepadProfileBindingPresentations(
                profileID: projection.profileID,
                orientation: orientation,
                entries: entries.sorted { $0.input.storageKey < $1.input.storageKey }
            )
        }
    }

    private static func authorityOutputModeName(
        _ mode: ThumbleCLIProfileBackend.OutputMode
    ) -> String {
        switch mode {
        case .keyboard: "Keyboard"
        case .controller: "Controller"
        case .custom: "Custom"
        }
    }

    private static func authorityOutputModeDescription(
        _ mode: ThumbleCLIProfileBackend.OutputMode
    ) -> String {
        switch mode {
        case .keyboard: "Send this keypad as Mac keyboard shortcuts. Virtual controller output stays off for this setup."
        case .controller: "Send this keypad as a virtual Xbox-style controller using Thumble’s default controller map."
        case .custom: "Use per-element output bindings. This can mix keyboard shortcuts and virtual controller buttons."
        }
    }

    // MARK: - Customization

    private static func customization(arguments: [String]) throws {
        guard let subcommand = arguments.first else { throw CLIError.message("Missing customization subcommand") }
        let rest = Array(arguments.dropFirst())
        switch subcommand {
        case "show":
            let store = loadStore()
            let profile = try resolveProfile(optionValue("--profile", in: rest), in: store)
            try printJSON(customization(for: profile, arguments: rest))
        case "export":
            let outputPath = optionValue("--output", in: rest) ?? optionValue("-o", in: rest)
            let store = loadStore()
            let profile = try resolveProfile(optionValue("--profile", in: rest), in: store)
            try writeJSON(customization(for: profile, arguments: rest), to: outputPath)
        case "import":
            try requireExplicitUnmigratedProfileAccess(
                operation: "customization import",
                artifactRequired: true
            )
            guard let path = firstPositional(in: rest) else { throw CLIError.message("Missing customization JSON path") }
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let customization = try JSONDecoder().decode(GamepadCustomization.self, from: data)
            try mutateCustomization(profileTarget: optionValue("--profile", in: rest), variant: try customizationVariant(in: rest)) { $0 = customization }
            print("Imported customization.")
        case "validate", "check", "lint":
            try validateLayout(arguments: rest)
        case "fix", "repair", "autofix", "auto-fix":
            try repairLayout(arguments: rest)
        case "preview", "render":
            try previewLayout(arguments: rest)
        case "set":
            try setCustomization(arguments: rest)
        case "reset":
            try requireExplicitUnmigratedProfileAccess(operation: "customization reset")
            try mutateCustomization(
                profileTarget: optionValue("--profile", in: rest),
                variant: try customizationVariant(in: rest)
            ) { $0 = .defaultValue }
            print("Reset customization.")
        default:
            throw CLIError.message("Unknown customization subcommand: \(subcommand)")
        }
    }

    private static func setCustomization(arguments: [String]) throws {
        let richBackgroundOptions = [
            "--background-gradient", "--bg-gradient", "--background-tile", "--bg-tile",
            "--light-background-gradient", "--background-light-gradient",
            "--dark-background-gradient", "--background-dark-gradient",
            "--light-background-tile", "--background-light-tile",
            "--dark-background-tile", "--background-dark-tile"
        ]
        let imageBackgroundOptions = [
            "--background-image", "--bg-image", "--light-background-image",
            "--background-light-image", "--dark-background-image", "--background-dark-image"
        ]
        let customDeviceOptions = [
            "--device-size", "--size", "--device-width", "--device-height"
        ]
        let deviceTarget = optionValue("--device", in: arguments)
            ?? optionValue("--frame", in: arguments)
            ?? optionValue("--canvas", in: arguments)
        let requestsCustomDevice = deviceTarget.map { normalizedLookup($0) == "custom" } ?? false
        if hasAnyOption(richBackgroundOptions, in: arguments)
            || hasAnyOption(imageBackgroundOptions, in: arguments)
            || hasAnyOption(customDeviceOptions, in: arguments)
            || requestsCustomDevice
        {
            try requireExplicitUnmigratedProfileAccess(
                operation: "customization rich background or custom device",
                artifactRequired: hasAnyOption(imageBackgroundOptions, in: arguments)
            )
            try setCustomizationUsingLegacyStore(arguments: arguments)
            print("Updated customization.")
            return
        }

        var scalar = ThumbleCLIProfileBackend.CustomizationChanges()
        if let value = optionValue("--layout", in: arguments) {
            let parsed = try parseLayoutMode(value)
            scalar.layoutMode = .init(rawValue: parsed.rawValue)
        }
        if let value = optionValue("--scale", in: arguments)
            ?? optionValue("--control-scale", in: arguments)
        {
            let parsed = try parseControlScale(value)
            scalar.controlScale = .init(rawValue: parsed.rawValue)
        }
        if let value = optionValue("--appearance", in: arguments)
            ?? optionValue("--color-scheme", in: arguments)
            ?? optionValue("--scheme", in: arguments)
        {
            let parsed = try parseColorSchemePreference(value)
            scalar.colorScheme = .init(rawValue: parsed.rawValue)
        }
        if let value = optionValue("--accent", in: arguments)
            ?? optionValue("--color", in: arguments)
        {
            let parsed = try parseAccentStyle(value)
            scalar.accentStyle = .init(rawValue: parsed.rawValue)
        }
        if arguments.contains("--show-labels") { scalar.showsButtonLabels = true }
        if arguments.contains("--hide-labels") { scalar.showsButtonLabels = false }
        if let value = optionValue("--labels", in: arguments) {
            scalar.showsButtonLabels = try parseBool(value)
        }

        var changes: [ThumbleCLIProfileBackend.CustomizationChanges] = []
        if !scalar.isEmpty { changes.append(scalar) }
        for (scope, value) in [
            (ThumbleCLIProfileBackend.CustomizationBackgroundScope.all,
             optionValue("--background", in: arguments) ?? optionValue("--bg", in: arguments)),
            (.light,
             optionValue("--light-background", in: arguments)
                ?? optionValue("--background-light", in: arguments)),
            (.dark,
             optionValue("--dark-background", in: arguments)
                ?? optionValue("--background-dark", in: arguments))
        ] {
            guard let value else { continue }
            var background = ThumbleCLIProfileBackend.CustomizationChanges()
            background.backgroundEdit = .set(
                scope,
                ThumbleCLIProfileBackend.AuthorityColor(try parseRGBAColor(value))
            )
            changes.append(background)
        }
        if arguments.contains("--reset-background") {
            var clear = ThumbleCLIProfileBackend.CustomizationChanges()
            clear.backgroundEdit = .clear
            changes.append(clear)
        }

        let frameID: String?
        if let deviceTarget {
            let orientation = try (
                optionValue("--orientation", in: arguments)
                    ?? optionValue("--device-orientation", in: arguments)
            ).map(parseDeviceOrientation)
            frameID = try resolveDeviceFrameTarget(
                deviceTarget,
                arguments: arguments,
                preferredOrientation: orientation
            ).id
        } else {
            frameID = nil
        }
        guard !changes.isEmpty || frameID != nil else {
            throw CLIError.message("No customization changes requested")
        }
        let response = try profileBackend().perform(
            .customizationSet(
                .init(optionValue("--profile", in: arguments)),
                try authorityConfigurationVariant(in: arguments),
                changes,
                frameID: frameID
            ),
            invocationID: try profileInvocationID(in: arguments)
        )
        guard response.outcome != nil else {
            throw CLIError.message("Rust profile authority returned no customization outcome")
        }
        print("Updated customization.")
        printProfileInvocation(response)
    }

    private static func setCustomizationUsingLegacyStore(arguments: [String]) throws {
        try mutateCustomization(
            profileTarget: optionValue("--profile", in: arguments),
            variant: try customizationVariant(in: arguments)
        ) { customization in
            if let layout = optionValue("--layout", in: arguments) {
                customization.layoutMode = try parseLayoutMode(layout)
            }
            if let scale = optionValue("--scale", in: arguments)
                ?? optionValue("--control-scale", in: arguments)
            {
                customization.controlScale = try parseControlScale(scale)
            }
            if let appearance = optionValue("--appearance", in: arguments)
                ?? optionValue("--color-scheme", in: arguments)
                ?? optionValue("--scheme", in: arguments)
            {
                customization.colorSchemePreference = try parseColorSchemePreference(appearance)
            }
            if let device = optionValue("--device", in: arguments)
                ?? optionValue("--frame", in: arguments)
                ?? optionValue("--canvas", in: arguments)
            {
                let orientation = try (
                    optionValue("--orientation", in: arguments)
                        ?? optionValue("--device-orientation", in: arguments)
                ).map(parseDeviceOrientation)
                customization.deviceCanvas = GamepadDeviceCanvas(
                    frameID: try resolveDeviceFrameTarget(
                        device,
                        arguments: arguments,
                        preferredOrientation: orientation
                    ).id
                )
            }
            if let deviceSize = optionValue("--device-size", in: arguments)
                ?? optionValue("--size", in: arguments)
            {
                let orientation = try (
                    optionValue("--orientation", in: arguments)
                        ?? optionValue("--device-orientation", in: arguments)
                ).map(parseDeviceOrientation)
                customization.deviceCanvas = GamepadDeviceCanvas(
                    frameID: try resolveCustomDeviceFrame(
                        sizeText: deviceSize,
                        preferredOrientation: orientation
                    ).id
                )
            }
            if let background = optionValue("--background", in: arguments)
                ?? optionValue("--bg", in: arguments)
            {
                setBackgroundFillColor(try parseRGBAColor(background), in: &customization)
            }
            if let light = optionValue("--light-background", in: arguments)
                ?? optionValue("--background-light", in: arguments)
            {
                setBackgroundFillColor(
                    try parseRGBAColor(light), isDark: false, in: &customization
                )
            }
            if let dark = optionValue("--dark-background", in: arguments)
                ?? optionValue("--background-dark", in: arguments)
            {
                setBackgroundFillColor(
                    try parseRGBAColor(dark), isDark: true, in: &customization
                )
            }
            if let value = optionValue("--background-gradient", in: arguments)
                ?? optionValue("--bg-gradient", in: arguments)
            {
                setBackgroundFillStyle(
                    try parseGradientFill(value, arguments: arguments), in: &customization
                )
            }
            if let value = optionValue("--background-tile", in: arguments)
                ?? optionValue("--bg-tile", in: arguments)
            {
                setBackgroundFillStyle(
                    try parseTileFill(value, arguments: arguments), in: &customization
                )
            }
            if let value = optionValue("--background-image", in: arguments)
                ?? optionValue("--bg-image", in: arguments)
            {
                setBackgroundFillStyle(
                    try parseImageFill(value, arguments: arguments), in: &customization
                )
            }
            if let value = optionValue("--light-background-gradient", in: arguments)
                ?? optionValue("--background-light-gradient", in: arguments)
            {
                setBackgroundFillStyle(
                    try parseGradientFill(value, arguments: arguments),
                    isDark: false,
                    in: &customization
                )
            }
            if let value = optionValue("--dark-background-gradient", in: arguments)
                ?? optionValue("--background-dark-gradient", in: arguments)
            {
                setBackgroundFillStyle(
                    try parseGradientFill(value, arguments: arguments),
                    isDark: true,
                    in: &customization
                )
            }
            if let value = optionValue("--light-background-tile", in: arguments)
                ?? optionValue("--background-light-tile", in: arguments)
            {
                setBackgroundFillStyle(
                    try parseTileFill(value, arguments: arguments),
                    isDark: false,
                    in: &customization
                )
            }
            if let value = optionValue("--dark-background-tile", in: arguments)
                ?? optionValue("--background-dark-tile", in: arguments)
            {
                setBackgroundFillStyle(
                    try parseTileFill(value, arguments: arguments),
                    isDark: true,
                    in: &customization
                )
            }
            if let value = optionValue("--light-background-image", in: arguments)
                ?? optionValue("--background-light-image", in: arguments)
            {
                setBackgroundFillStyle(
                    try parseImageFill(value, arguments: arguments),
                    isDark: false,
                    in: &customization
                )
            }
            if let value = optionValue("--dark-background-image", in: arguments)
                ?? optionValue("--background-dark-image", in: arguments)
            {
                setBackgroundFillStyle(
                    try parseImageFill(value, arguments: arguments),
                    isDark: true,
                    in: &customization
                )
            }
            if arguments.contains("--reset-background") {
                clearBackgroundFill(in: &customization)
            }
            if let accent = optionValue("--accent", in: arguments)
                ?? optionValue("--color", in: arguments)
            {
                customization.accentStyle = try parseAccentStyle(accent)
            }
            if arguments.contains("--show-labels") { customization.showsButtonLabels = true }
            if arguments.contains("--hide-labels") { customization.showsButtonLabels = false }
            if let labels = optionValue("--labels", in: arguments) {
                customization.showsButtonLabels = try parseBool(labels)
            }
        }
    }

    private static func orientation(arguments: [String]) throws {
        guard let subcommand = arguments.first else { throw CLIError.message("Missing orientation subcommand") }
        if subcommand == "get" || subcommand == "show" || subcommand == "set" {
            switch try GamepadProfileOrientationCLIParser.parse(
                removingProfileInvocationID(from: arguments)
            ) {
            case .get(let profileTarget, let json):
                let response = try profileBackend().perform(
                    .orientationGet(.init(profileTarget)),
                    invocationID: try profileInvocationID(in: arguments)
                )
                guard let remote = response.orientation else {
                    throw CLIError.message("Rust profile authority returned no revision-tagged orientation summary")
                }
                let summary = OrientationPreferenceSummary(
                    configurationRevision: remote.configurationRevision,
                    profileID: remote.profileID,
                    profileName: remote.profileName,
                    orientation: remote.orientation
                )
                if json {
                    try printJSON(summary)
                } else {
                    print(remote.orientation.rawValue)
                }
            case .set(let preference, let profileTarget):
                guard let typedPreference = ThumbleCLIProfileBackend.OrientationPreference(rawValue: preference.rawValue) else {
                    throw CLIError.message("Unsupported orientation preference")
                }
                let response = try profileBackend().perform(
                    .orientationSet(.init(profileTarget), typedPreference),
                    invocationID: try profileInvocationID(in: arguments)
                )
                guard let profileName = response.outcome?.profileNames.first else {
                    throw CLIError.message("Rust profile authority returned no orientation outcome")
                }
                print("Set iPhone rotation for \"\(profileName)\" to \(preference.rawValue).")
                printProfileInvocation(response)
            }
            return
        }

        let rest = Array(arguments.dropFirst())
        guard subcommand == "copy" || subcommand == "arrange" else {
            throw CLIError.message("Unknown orientation subcommand: \(subcommand)")
        }

        let positional = positionals(in: rest)
        let destinationText = optionValue("--to", in: rest)
            ?? optionValue("--variant", in: rest)
            ?? optionValue("--layout-variant", in: rest)
            ?? (subcommand == "arrange" ? positional.first : positional.dropFirst().first)
        guard let destinationText else {
            let usage = subcommand == "arrange"
                ? "thumble orientation arrange <destination> [--from source] [--profile PROFILE]"
                : "thumble orientation copy <source> <destination> [--profile PROFILE]"
            throw CLIError.message("Usage: \(usage)")
        }
        let destination = try parseProfileLayoutVariant(destinationText)
        let sourceText = optionValue("--from", in: rest)
            ?? (subcommand == "copy" ? positional.first : nil)
        let source = try sourceText.map(parseProfileLayoutVariant)
            ?? (destination == .portrait ? .landscape : .portrait)
        guard source != destination else { throw CLIError.message("Source and destination orientation must be different") }

        guard let typedSource = ThumbleCLIProfileBackend.LayoutOrientation(rawValue: source.rawValue),
              let typedDestination = ThumbleCLIProfileBackend.LayoutOrientation(rawValue: destination.rawValue)
        else { throw CLIError.message("Unsupported layout orientation") }
        let automaticallyArrange = !rest.contains("--no-arrange")
        let response = try profileBackend().perform(
            .orientationCopy(
                .init(optionValue("--profile", in: rest)),
                typedSource,
                typedDestination,
                automaticallyArrange
            ),
            invocationID: try profileInvocationID(in: rest)
        )
        guard let profileName = response.outcome?.profileNames.first else {
            throw CLIError.message("Rust profile authority returned no orientation-copy outcome")
        }
        let action = automaticallyArrange ? "Copied and arranged" : "Copied"
        print("\(action) \(source.rawValue) as \(destination.rawValue) for \"\(profileName)\".")
        printProfileInvocation(response)
    }

    private static func parseProfileLayoutVariant(_ value: String) throws -> GamepadProfileLayoutVariant {
        switch normalizedLookup(value) {
        case "landscape", "horizontal": return .landscape
        case "portrait", "vertical": return .portrait
        default: throw CLIError.message("Unknown layout orientation: \(value). Use portrait or landscape.")
        }
    }

    private static func validateLayout(arguments: [String]) throws {
        let store = loadStore()
        let profile = try resolveProfile(layoutProfileTarget(in: arguments), in: store)
        let resolvedCustomization = try customization(for: profile, arguments: arguments)
        let canvasSize = try parseLayoutCanvasSize(arguments, fallback: resolvedCustomization.deviceCanvas.editorDeviceFrame.screenRect.size)
        let report = resolvedCustomization.layoutQualityReport(profileName: profile.name, canvasSize: canvasSize)

        if arguments.contains("--json") {
            try printJSON(report)
        } else {
            printLayoutReport(report)
        }

        try enforceLayoutQuality(
            report,
            strict: arguments.contains("--strict"),
            quiet: true
        )
    }

    private static func repairLayout(arguments: [String]) throws {
        let target = (optionValue("--repair", in: arguments) ?? firstPositional(in: arguments)).map(normalizedLookup) ?? "all"
        let authorityTarget: ThumbleCLIProfileBackend.LayoutRepairTarget?
        if target == "all" || target == "suggested" {
            authorityTarget = .all
        } else if let repair = parseLayoutRepairKind(target),
                  let typedRepair = ThumbleCLIProfileBackend.LayoutRepairKind(rawValue: repair.rawValue) {
            authorityTarget = .repair(typedRepair)
        } else {
            authorityTarget = nil
        }
        if let authorityTarget {
            let response = try profileBackend().perform(
                .customizationFix(
                    .init(optionValue("--profile", in: arguments)),
                    try authorityConfigurationVariant(in: arguments),
                    authorityTarget,
                    try authorityLayoutRepairCanvas(in: arguments),
                    includeLocked: arguments.contains("--unlock") || arguments.contains("--include-locked")
                ),
                invocationID: try profileInvocationID(in: arguments)
            )
            guard let outcome = response.outcome else {
                throw CLIError.message("Rust profile authority returned no layout-repair outcome")
            }
            if arguments.contains("--json") {
                try printJSON(outcome)
            } else if outcome.changed {
                print("Repaired layout.")
            } else {
                print("Layout did not need this repair.")
            }
            printProfileInvocation(response)
            return
        }

        try requireExplicitUnmigratedProfileAccess(operation: "customization issue-specific repair")
        let variant = try customizationVariant(in: arguments)
        let profileTarget = optionValue("--profile", in: arguments)
        let respectsLocks = !arguments.contains("--unlock") && !arguments.contains("--include-locked")
        var results: [GamepadLayoutRepairResult] = []

        try mutateCustomization(profileTarget: profileTarget, variant: variant) { customization in
            let canvasSize = try parseLayoutCanvasSize(
                arguments,
                fallback: customization.deviceCanvas.editorDeviceFrame.screenRect.size
            )
            let report = customization.layoutQualityReport(canvasSize: canvasSize)

            if target == "all" || target == "suggested" {
                results.append(contentsOf: customization.applyLayoutRepairs(
                    target: .all,
                    canvasSize: canvasSize,
                    respectingLocks: respectsLocks
                ))
            } else if let repair = parseLayoutRepairKind(target) {
                results.append(contentsOf: customization.applyLayoutRepairs(
                    target: .repair(repair),
                    canvasSize: canvasSize,
                    respectingLocks: respectsLocks
                ))
            } else {
                let matchingIssues = report.issues.filter { normalizedLookup($0.code) == target }
                guard !matchingIssues.isEmpty else {
                    throw CLIError.message("No layout issue or repair named \"\(target)\". Use all, small-control, control-overlap, expanded-hit-overlap, edge-hugging-control, thumb-reach, coverage, minimum-touch-target, move-inside-safe-area, resolve-overlap, separate-expanded-hit-targets, ergonomic-auto-arrange, or auto-arrange.")
                }
                for issue in matchingIssues {
                    guard let repair = issue.suggestedRepairs.first else { continue }
                    results.append(
                        customization.applyLayoutRepair(
                            repair,
                            issue: issue,
                            canvasSize: canvasSize,
                            respectingLocks: respectsLocks
                        )
                    )
                }
            }
        }

        if arguments.contains("--json") {
            try printJSON(results)
        } else {
            let changed = Set(results.flatMap(\.changedControlIDs)).count
            let skipped = Set(results.flatMap(\.skippedLockedControlIDs)).count
            let remaining = results.last?.issueCountAfter ?? 0
            print("Repaired layout: \(changed) control\(changed == 1 ? "" : "s") changed, \(remaining) issue\(remaining == 1 ? "" : "s") remaining.")
            if skipped > 0 {
                print("Skipped \(skipped) locked control\(skipped == 1 ? "" : "s"). Re-run with --unlock to include them.")
            }
        }
    }

    private static func parseLayoutRepairKind(_ value: String) -> GamepadLayoutRepairKind? {
        switch normalizedLookup(value) {
        case "showdefaultcontrols", "showdefaults": .showDefaultControls
        case "moveinsidesafearea", "moveinside": .moveInsideSafeArea
        case "minimumtouchtarget", "minimumsize": .minimumTouchTarget
        case "resolveoverlap", "separate": .resolveOverlap
        case "autoarrange", "arrange", "coverage": .autoArrange
        case "hits", "hittargets", "targets", "separateexpandedhittargets": .separateExpandedHitTargets
        case "ergonomic", "ergonomics", "thumbreach", "ergonomicautoarrange": .ergonomicAutoArrange
        default: nil
        }
    }

    private static func previewLayout(arguments: [String]) throws {
        let store = loadStore()
        let profile = try resolveProfile(layoutProfileTarget(in: arguments), in: store)
        let resolvedCustomization = try customization(for: profile, arguments: arguments)
        let canvasSize = try parseLayoutCanvasSize(arguments, fallback: resolvedCustomization.deviceCanvas.editorDeviceFrame.screenRect.size)
        let outputPath = optionValue("--output", in: arguments) ?? optionValue("-o", in: arguments) ?? optionValue("--path", in: arguments) ?? "thumble-layout-preview.png"
        let scale = try parsePreviewScale(arguments)

#if os(macOS)
        try GamepadLayoutPreviewRenderer.writePNG(
            customization: resolvedCustomization,
            profileName: profile.name,
            canvasSize: canvasSize,
            outputURL: URL(fileURLWithPath: outputPath),
            scale: scale,
            annotateIssues: !arguments.contains("--no-annotations")
        )
        let report = resolvedCustomization.layoutQualityReport(profileName: profile.name, canvasSize: canvasSize)
        if arguments.contains("--json") {
            try printJSON(report)
        } else {
            print("Wrote layout preview to \(outputPath).")
            print("Layout quality: \(report.statusText) (\(report.summary.errorCount) errors, \(report.summary.warningCount) warnings).")
        }
#else
        throw CLIError.message("Layout preview rendering is only available on macOS.")
#endif
    }

    private static func layoutProfileTarget(in arguments: [String]) -> String? {
        optionValue("--profile", in: arguments) ?? firstPositional(in: arguments)
    }

    private static func parseLayoutCanvasSize(_ arguments: [String], fallback: CGSize) throws -> CGSize {
        var canvasSize = fallback
        if let canvas = optionValue("--canvas", in: arguments) ?? optionValue("--device", in: arguments) ?? optionValue("--frame", in: arguments) {
            let normalized = normalizedLookup(canvas)
            if normalized == "landscape" {
                canvasSize = defaultEditorCanvasSize
            } else if normalized == "portrait" {
                canvasSize = portraitEditorCanvasSize
            } else if let parsed = parseCanvasSizeLiteral(canvas) {
                canvasSize = parsed
            } else {
                canvasSize = try resolveDeviceFrame(canvas, preferredOrientation: nil).screenRect.size
            }
        }
        if let size = optionValue("--size", in: arguments) ?? optionValue("--device-size", in: arguments) {
            guard let parsed = parseCanvasSizeLiteral(size) else { throw CLIError.message("Invalid canvas size: \(size). Use WIDTHxHEIGHT.") }
            canvasSize = parsed
        }
        let explicitWidth = optionValue("--canvas-width", in: arguments)
        let explicitHeight = optionValue("--canvas-height", in: arguments)
        if explicitWidth != nil || explicitHeight != nil {
            guard let explicitWidth, let explicitHeight else { throw CLIError.message("Use --canvas-width and --canvas-height together") }
            canvasSize = CGSize(width: try parsePixels(explicitWidth), height: try parsePixels(explicitHeight))
        }
        guard canvasSize.width > 1, canvasSize.height > 1 else { throw CLIError.message("Canvas size must be greater than 1×1") }
        return canvasSize
    }

    private static func authorityLayoutRepairCanvas(
        in arguments: [String]
    ) throws -> ThumbleCLIProfileBackend.LayoutRepairCanvas {
        var canvas: ThumbleCLIProfileBackend.LayoutRepairCanvas = .stored
        if let value = optionValue("--canvas", in: arguments)
            ?? optionValue("--device", in: arguments)
            ?? optionValue("--frame", in: arguments)
        {
            switch normalizedLookup(value) {
            case "landscape":
                canvas = try authorityLayoutRepairSize(defaultEditorCanvasSize)
            case "portrait":
                canvas = try authorityLayoutRepairSize(portraitEditorCanvasSize)
            default:
                if let size = parseCanvasSizeLiteral(value) {
                    canvas = try authorityLayoutRepairSize(size)
                } else {
                    canvas = .frame(try resolveDeviceFrame(value, preferredOrientation: nil).id)
                }
            }
        }
        if let value = optionValue("--size", in: arguments)
            ?? optionValue("--device-size", in: arguments)
        {
            guard let size = parseCanvasSizeLiteral(value) else {
                throw CLIError.message("Invalid canvas size: \(value). Use WIDTHxHEIGHT.")
            }
            canvas = try authorityLayoutRepairSize(size)
        }
        let width = optionValue("--canvas-width", in: arguments)
        let height = optionValue("--canvas-height", in: arguments)
        if width != nil || height != nil {
            guard let width, let height else {
                throw CLIError.message("Use --canvas-width and --canvas-height together")
            }
            canvas = try authorityLayoutRepairSize(
                CGSize(width: try parsePixels(width), height: try parsePixels(height))
            )
        }
        return canvas
    }

    private static func authorityLayoutRepairSize(
        _ size: CGSize
    ) throws -> ThumbleCLIProfileBackend.LayoutRepairCanvas {
        let width = Double(size.width)
        let height = Double(size.height)
        guard width.isFinite, height.isFinite,
              (240 ... 1_800).contains(width), (240 ... 1_800).contains(height)
        else {
            throw CLIError.message("Layout repair canvas must be between 240×240 and 1800×1800 points")
        }
        return .size(width: width, height: height)
    }

    private static func parsePreviewScale(_ arguments: [String]) throws -> CGFloat {
        guard let value = optionValue("--image-scale", in: arguments) ?? optionValue("--render-scale", in: arguments) ?? optionValue("--scale", in: arguments) else {
            return 2
        }
        let parsed = try parsePixels(value)
        guard parsed > 0 else { throw CLIError.message("Preview scale must be greater than zero") }
        return parsed
    }

    private static func printLayoutReport(_ report: GamepadLayoutQualityReport) {
        let profileName = report.profileName ?? "active"
        print("Layout validation for \"\(profileName)\": \(report.statusText)")
        print("Canvas: \(formatPixels(CGFloat(report.canvas.width)))×\(formatPixels(CGFloat(report.canvas.height))) pt")
        print("Elements: \(report.summary.controlCount), errors: \(report.summary.errorCount), warnings: \(report.summary.warningCount)")
        print("Usage: width \(formatPercentage(report.summary.layoutWidthCoverage)), height \(formatPercentage(report.summary.layoutHeightCoverage)), bottom unused \(formatPercentage(report.summary.bottomUnusedRatio))")
        if report.issues.isEmpty {
            print("No layout issues found.")
            return
        }
        for issue in report.issues {
            let prefix = switch issue.severity {
            case .info: "info"
            case .warning: "warning"
            case .error: "error"
            }
            print("- \(prefix) [\(issue.code)]: \(issue.message)")
        }
    }

    private static func enforceLayoutQuality(_ report: GamepadLayoutQualityReport, strict: Bool, quiet: Bool) throws {
        let shouldFail = report.hasErrors || (strict && report.hasWarnings)
        if !quiet {
            if report.issues.isEmpty {
                print("Layout quality: passed.")
            } else {
                print("Layout quality: \(report.statusText) (\(report.summary.errorCount) errors, \(report.summary.warningCount) warnings).")
                for issue in report.issues.prefix(6) {
                    print("- \(issue.severity.rawValue) [\(issue.code)]: \(issue.message)")
                }
                if report.issues.count > 6 {
                    print("- …and \(report.issues.count - 6) more layout issues")
                }
            }
        }
        guard !shouldFail else {
            throw CLIError.validationFailed("Layout validation failed for \"\(report.profileName ?? "profile")\". Run `thumble layout validate --profile \"\(report.profileName ?? "active")\"` or `thumble layout preview -o preview.png` for details.")
        }
    }

    private static func customizationVariant(in arguments: [String]) throws -> GamepadEditorDeviceOrientation? {
        guard let value = optionValue("--variant", in: arguments) ?? optionValue("--layout-variant", in: arguments) else { return nil }
        return try parseDeviceOrientation(value)
    }

    private static func customization(for profile: GamepadConfigurationProfile, arguments: [String]) throws -> GamepadCustomization {
        if let variant = try customizationVariant(in: arguments) {
            return profile.customization(for: variant)
        }
        return profile.customization
    }

    private static func mutateCustomization(profileTarget: String?, variant: GamepadEditorDeviceOrientation? = nil, mutate: (inout GamepadCustomization) throws -> Void) throws {
        var store = loadStore()
        let index = try resolveProfileIndex(profileTarget, in: store)
        var customization = variant.map { store.profiles[index].customization(for: $0) } ?? store.profiles[index].customization
        try mutate(&customization)
        let normalizedCustomization = customization.normalized
        if let variant {
            store.profiles[index].setCustomization(normalizedCustomization, for: variant)
        } else {
            store.profiles[index].setCustomization(
                normalizedCustomization,
                for: normalizedCustomization.deviceCanvas.editorDeviceFrame.orientation
            )
        }
        store.profiles[index].updatedAt = Date.currentMilliseconds
        try persistStore(store)
    }

    private static func mutateProfileResources(
        profileTarget: String?,
        mutate: (inout GamepadCustomization) throws -> Void
    ) throws {
        var store = loadStore()
        let index = try resolveProfileIndex(profileTarget, in: store)
        var profile = store.profiles[index]

        try mutate(&profile.customization)
        profile.customization = profile.customization.normalized
        if var landscape = profile.landscapeCustomization {
            try mutate(&landscape)
            profile.landscapeCustomization = landscape.normalized
        }
        if var portrait = profile.portraitCustomization {
            try mutate(&portrait)
            profile.portraitCustomization = portrait.normalized
        }

        profile.updatedAt = Date.currentMilliseconds
        store.profiles[index] = profile.normalized
        try persistStore(store)
    }

    // MARK: - Styles / layers / groups / assets

    private static func style(arguments: [String]) throws {
        guard let subcommand = arguments.first else { throw CLIError.message("Missing style subcommand") }
        let rest = Array(arguments.dropFirst())
        switch subcommand {
        case "list", "ls":
            let response = try profileBackend().perform(
                .styleList(.init(optionValue("--profile", in: rest))),
                invocationID: try profileInvocationID(in: rest)
            )
            guard let projection = response.styles else {
                throw CLIError.message("Rust profile authority returned no sanitized style projection")
            }
            if rest.contains("--json") {
                try printJSON(projection.styles)
            } else if projection.styles.isEmpty {
                print("No styles saved for \"\(projection.profileName)\".")
            } else {
                for style in projection.styles { print("\(style.id)\t\(style.name)") }
            }
        case "show":
            guard let id = firstPositional(in: rest) else { throw CLIError.message("Usage: thumble style show <style-id>") }
            let response = try profileBackend().perform(
                .styleShow(.init(optionValue("--profile", in: rest)), styleID: id),
                invocationID: try profileInvocationID(in: rest)
            )
            guard let style = response.styles?.styles.first else {
                throw CLIError.message("Rust profile authority returned no sanitized style definition")
            }
            try printJSON(style)
        case "create", "new", "set":
            guard let name = firstPositional(in: rest) else { throw CLIError.message("Usage: thumble style create <name> [--id ID] [--fill #RRGGBB]") }
            let id = optionValue("--id", in: rest) ?? slug(name)
            let token = try makeStyleToken(id: id, name: name, arguments: rest)
            let response = try profileBackend().perform(
                .styleCreate(
                    .init(optionValue("--profile", in: rest)),
                    styleID: token.id,
                    name: token.name,
                    appearance: try authorityStyleAppearance(from: token)
                ),
                invocationID: try profileInvocationID(in: rest)
            )
            guard response.outcome != nil else {
                throw CLIError.message("Rust profile authority returned no style-create outcome")
            }
            print("Saved style \"\(token.name)\" (\(token.id)).")
            printProfileInvocation(response)
        case "rename":
            let positional = positionals(in: rest)
            guard positional.count >= 2 else { throw CLIError.message("Usage: thumble style rename <style-id> <new name>") }
            let id = positional[0]
            let newName = positional.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newName.isEmpty else { throw CLIError.message("Style name cannot be empty") }
            let response = try profileBackend().perform(
                .styleRename(
                    .init(optionValue("--profile", in: rest)),
                    styleID: id,
                    name: newName
                ),
                invocationID: try profileInvocationID(in: rest)
            )
            guard response.outcome != nil else {
                throw CLIError.message("Rust profile authority returned no style-rename outcome")
            }
            print("Renamed style \"\(id)\" to \"\(newName)\".")
            printProfileInvocation(response)
        case "apply":
            let positional = positionals(in: rest)
            guard positional.count >= 2 else { throw CLIError.message("Usage: thumble style apply <style-id> <element>") }
            let styleID = positional[0]
            let targetText = positional[1]
            let response = try profileBackend().perform(
                .styleApply(
                    .init(optionValue("--profile", in: rest)),
                    .primary,
                    styleID: styleID,
                    elementID: targetText
                ),
                invocationID: try profileInvocationID(in: rest)
            )
            guard response.outcome != nil else {
                throw CLIError.message("Rust profile authority returned no style-apply outcome")
            }
            print("Applied style \"\(styleID)\" to \"\(targetText)\".")
            printProfileInvocation(response)
        case "detach", "clear":
            guard let targetText = firstPositional(in: rest) else { throw CLIError.message("Usage: thumble style detach <element>") }
            let response = try profileBackend().perform(
                .styleDetach(
                    .init(optionValue("--profile", in: rest)),
                    .primary,
                    elementID: targetText
                ),
                invocationID: try profileInvocationID(in: rest)
            )
            guard response.outcome != nil else {
                throw CLIError.message("Rust profile authority returned no style-detach outcome")
            }
            print("Detached style from \"\(targetText)\".")
            printProfileInvocation(response)
        case "delete", "rm":
            guard let id = firstPositional(in: rest) else { throw CLIError.message("Usage: thumble style delete <style-id>") }
            let response = try profileBackend().perform(
                .styleDelete(
                    .init(optionValue("--profile", in: rest)),
                    styleID: id
                ),
                invocationID: try profileInvocationID(in: rest)
            )
            guard response.outcome != nil else {
                throw CLIError.message("Rust profile authority returned no style-delete outcome")
            }
            print("Deleted style \"\(id)\".")
            printProfileInvocation(response)
        case "export":
            try requireExplicitUnmigratedProfileAccess(
                operation: "style export",
                artifactRequired: true
            )
            let store = loadStore()
            let profile = try resolveProfile(optionValue("--profile", in: rest), in: store)
            try writeJSON(profile.customization.styleLibrary.normalized, to: optionValue("--output", in: rest) ?? optionValue("-o", in: rest))
        case "import":
            try requireExplicitUnmigratedProfileAccess(
                operation: "style import",
                artifactRequired: true
            )
            guard let path = firstPositional(in: rest) else { throw CLIError.message("Usage: thumble style import <style-library.json> [--merge]") }
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let library = try JSONDecoder().decode(GamepadStyleLibrary.self, from: data).normalized
            try mutateProfileResources(profileTarget: optionValue("--profile", in: rest)) { customization in
                if rest.contains("--merge") {
                    var merged = customization.styleLibrary.normalized.styles
                    for style in library.styles {
                        if let index = merged.firstIndex(where: { $0.id == style.id }) {
                            merged[index] = style
                        } else {
                            merged.append(style)
                        }
                    }
                    customization.styleLibrary = GamepadStyleLibrary(styles: merged).normalized
                } else {
                    customization.styleLibrary = library
                }
            }
            print("Imported \(library.styles.count) style\(library.styles.count == 1 ? "" : "s")\(rest.contains("--merge") ? " and merged them" : "").")
        default:
            throw CLIError.message("Unknown style subcommand: \(subcommand)")
        }
    }

    private static func layer(arguments: [String]) throws {
        guard let subcommand = arguments.first else { throw CLIError.message("Missing layer subcommand") }
        let rest = Array(arguments.dropFirst())
        switch subcommand {
        case "list", "ls":
            let response = try profileBackend().perform(
                .layerList(
                    .init(optionValue("--profile", in: rest)),
                    .primary
                ),
                invocationID: try profileInvocationID(in: rest)
            )
            guard let projection = response.layers else {
                throw CLIError.message("Rust profile authority returned no sanitized layer projection")
            }
            let summaries = projection.layers.map {
                LayerSummary(
                    id: $0.stableID,
                    kind: $0.kind,
                    label: $0.label,
                    zIndex: $0.zIndex,
                    isHidden: $0.isHidden,
                    isLocked: $0.isLocationLocked
                )
            }
            if rest.contains("--json") {
                try printJSON(summaries)
            } else {
                for (index, summary) in summaries.enumerated() {
                    print("\(index)\t\(summary.id)\t\(summary.label)\t\(summary.kind)\tz:\(summary.zIndex)")
                }
            }
        case "move":
            let positional = positionals(in: rest)
            guard let targetText = positional.first else { throw CLIError.message("Usage: thumble layer move <element> --to INDEX") }
            let toIndex = try optionValue("--to", in: rest).map(parseInteger)
            let beforeText = optionValue("--before", in: rest)
            let afterText = optionValue("--after", in: rest)
            let destination: ThumbleCLIProfileBackend.LayerMoveDestination
            if let toIndex {
                guard (0 ... Int(Int32.max)).contains(toIndex) else {
                    throw CLIError.message("Layer index must be between 0 and \(Int32.max)")
                }
                destination = .index(toIndex)
            } else if let beforeText {
                destination = .before(beforeText)
            } else if let afterText {
                destination = .after(afterText)
            } else {
                throw CLIError.message("layer move needs --to, --before, or --after")
            }
            let response = try profileBackend().perform(
                .layerMove(
                    .init(optionValue("--profile", in: rest)),
                    elementID: targetText,
                    destination: destination
                ),
                invocationID: try profileInvocationID(in: rest)
            )
            try requireLayerOutcome(response)
            print("Moved layer \"\(targetText)\".")
            printProfileInvocation(response)
        case "bring-forward", "forward":
            try mutateLayerThroughAuthority(rest, command: .forward)
        case "send-backward", "backward":
            try mutateLayerThroughAuthority(rest, command: .backward)
        case "front", "bring-front":
            try mutateLayerThroughAuthority(rest, command: .front)
        case "back", "send-back":
            try mutateLayerThroughAuthority(rest, command: .back)
        default:
            throw CLIError.message("Unknown layer subcommand: \(subcommand)")
        }
    }

    private static func group(arguments: [String]) throws {
        guard let subcommand = arguments.first else { throw CLIError.message("Missing group subcommand") }
        let rest = Array(arguments.dropFirst())
        let target = ThumbleCLIProfileBackend.ProfileSelector(optionValue("--profile", in: rest))
        let variant = try authorityConfigurationVariant(in: rest)
        switch subcommand {
        case "list", "ls":
            let response = try profileBackend().perform(
                .groupList(target, variant),
                invocationID: try profileInvocationID(in: rest)
            )
            guard let projection = response.groups else {
                throw CLIError.message("Rust profile authority returned no sanitized group projection")
            }
            if rest.contains("--json") {
                try printJSON(projection.groups)
            } else {
                for group in projection.groups {
                    print("\(group.id)\t\(group.name)\t\(group.childTargetIDs.count) elements")
                    if rest.contains("--tree") {
                        for (index, child) in group.childTargetIDs.enumerated() {
                            let stableID = group.childStableIDs.indices.contains(index)
                                ? group.childStableIDs[index]
                                : child
                            print("  └─ \(stableID)\t\(child)")
                        }
                    }
                }
            }
        case "create", "new":
            let positional = positionals(in: rest)
            guard let name = positional.first, positional.count >= 2 else {
                throw CLIError.message("Usage: thumble group create <name> <element>...")
            }
            let response = try profileBackend().perform(
                .groupCreate(target, variant, name: name, elementIDs: Array(positional.dropFirst())),
                invocationID: try profileInvocationID(in: rest)
            )
            try requireGroupOutcome(response)
            print("Created group \"\(name)\".")
            printProfileInvocation(response)
        case "rename":
            let positional = positionals(in: rest)
            guard positional.count >= 2 else {
                throw CLIError.message("Usage: thumble group rename <group-name-or-id> <new name>")
            }
            let group = positional[0]
            let newName = positional.dropFirst().joined(separator: " ")
            let response = try profileBackend().perform(
                .groupRename(target, variant, group: group, name: newName),
                invocationID: try profileInvocationID(in: rest)
            )
            try requireGroupOutcome(response)
            print("Renamed group \"\(group)\" to \"\(newName)\".")
            printProfileInvocation(response)
        case "duplicate", "copy":
            guard let group = firstPositional(in: rest) else {
                throw CLIError.message("Usage: thumble group duplicate <group-name-or-id> [--name NAME] [--offset 0.025]")
            }
            try rejectAuthorityGroupCanvasOverrides(rest, operation: "group duplicate")
            let offset = try parseDuplicateOffset(rest)
            let requestedName = optionValue("--name", in: rest)
            let response = try profileBackend().perform(
                .groupDuplicate(
                    target,
                    variant,
                    group: group,
                    name: requestedName,
                    offsetX: Double(offset.width),
                    offsetY: Double(offset.height)
                ),
                invocationID: try profileInvocationID(in: rest)
            )
            try requireGroupOutcome(response)
            print("Duplicated group \"\(group)\" as \"\(requestedName ?? "Copy")\".")
            printProfileInvocation(response)
        case "ungroup", "delete", "rm":
            guard let group = firstPositional(in: rest) else {
                throw CLIError.message("Usage: thumble group ungroup <group-name-or-id>")
            }
            let response = try profileBackend().perform(
                .groupUngroup(target, variant, group: group),
                invocationID: try profileInvocationID(in: rest)
            )
            try requireGroupOutcome(response)
            print("Removed group \"\(group)\".")
            printProfileInvocation(response)
        case "hide", "show", "lock", "unlock":
            guard let group = firstPositional(in: rest) else {
                throw CLIError.message("Usage: thumble group \(subcommand) <group-name-or-id>")
            }
            let command: ThumbleCLIProfileBackend.Command = switch subcommand {
            case "hide": .groupHide(target, variant, group: group)
            case "show": .groupShow(target, variant, group: group)
            case "lock": .groupLock(target, variant, group: group)
            default: .groupUnlock(target, variant, group: group)
            }
            let response = try profileBackend().perform(
                command,
                invocationID: try profileInvocationID(in: rest)
            )
            try requireGroupOutcome(response)
            print("Updated group \"\(group)\".")
            printProfileInvocation(response)
        case "nudge", "move":
            try nudgeGroupThroughAuthority(arguments: rest, target: target, variant: variant)
        case "bring-forward", "forward", "send-backward", "backward", "front", "bring-front", "back", "send-back":
            guard let group = firstPositional(in: rest) else {
                throw CLIError.message("Usage: thumble group \(subcommand) <group-name-or-id>")
            }
            let command: ThumbleCLIProfileBackend.Command
            let description: String
            switch subcommand {
            case "bring-forward", "forward":
                command = .groupForward(target, variant, group: group)
                description = "Brought group forward"
            case "send-backward", "backward":
                command = .groupBackward(target, variant, group: group)
                description = "Sent group backward"
            case "front", "bring-front":
                command = .groupFront(target, variant, group: group)
                description = "Brought group to front"
            default:
                command = .groupBack(target, variant, group: group)
                description = "Sent group to back"
            }
            let response = try profileBackend().perform(
                command,
                invocationID: try profileInvocationID(in: rest)
            )
            try requireGroupOutcome(response)
            print("\(description) \"\(group)\".")
            printProfileInvocation(response)
        default:
            throw CLIError.message("Unknown group subcommand: \(subcommand)")
        }
    }

    private static func asset(arguments: [String]) throws {
        guard let subcommand = arguments.first else { throw CLIError.message("Missing asset subcommand") }
        let rest = Array(arguments.dropFirst())
        switch subcommand {
        case "list", "ls":
            let store = loadStore()
            let profile = try resolveProfile(optionValue("--profile", in: rest), in: store)
            let assets = profile.customization.assetLibrary.normalized.assets
            if rest.contains("--json") { try printJSON(assets) } else { assets.forEach { print("\($0.id)\t\($0.name)\t\($0.role.rawValue)\t\($0.byteCount) bytes") } }
        case "show":
            guard let id = firstPositional(in: rest) else { throw CLIError.message("Usage: thumble asset show <asset-id>") }
            let store = loadStore()
            let profile = try resolveProfile(optionValue("--profile", in: rest), in: store)
            guard let asset = profile.customization.assetLibrary.asset(id: id) else { throw CLIError.message("Asset not found: \(id)") }
            try printJSON(asset)
        case "import":
            guard let path = firstPositional(in: rest) else { throw CLIError.message("Usage: thumble asset import <path> [--name NAME] [--role background|icon|texture]") }
            let url = URL(fileURLWithPath: path)
            let data = try Data(contentsOf: url)
            guard data.count <= GamepadAsset.maximumStoredBytes else { throw CLIError.message("Assets must be under \(GamepadAsset.maximumStoredBytes) bytes") }
            let name = (optionValue("--name", in: rest) ?? url.deletingPathExtension().lastPathComponent).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw CLIError.message("Asset name cannot be empty") }
            let role = try optionValue("--role", in: rest).map(parseAssetRole) ?? .reference
            let asset = GamepadAsset(name: name, fileName: url.lastPathComponent, contentType: contentType(for: url), data: data, role: role)
            try mutateProfileResources(profileTarget: optionValue("--profile", in: rest)) { customization in
                var library = customization.assetLibrary.normalized
                library.assets.append(asset)
                customization.assetLibrary = library.normalized
            }
            print("Imported asset \"\(name)\".")
        case "set", "edit", "rename":
            let positional = positionals(in: rest)
            guard let id = positional.first else { throw CLIError.message("Usage: thumble asset set <asset-id> [--name NAME] [--role ROLE]") }
            let positionalName = subcommand == "rename" ? positional.dropFirst().joined(separator: " ") : ""
            let requestedName = (optionValue("--name", in: rest) ?? (positionalName.isEmpty ? nil : positionalName))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let requestedRole = try optionValue("--role", in: rest).map(parseAssetRole)
            guard requestedName != nil || requestedRole != nil else { throw CLIError.message("asset set needs --name or --role") }
            if let requestedName, requestedName.isEmpty { throw CLIError.message("Asset name cannot be empty") }
            let assetStore = loadStore()
            let assetProfile = try resolveProfile(optionValue("--profile", in: rest), in: assetStore)
            guard assetProfile.customization.assetLibrary.asset(id: id) != nil else { throw CLIError.message("Asset not found: \(id)") }
            try mutateProfileResources(profileTarget: optionValue("--profile", in: rest)) { customization in
                if let index = customization.assetLibrary.assets.firstIndex(where: { $0.id == id }) {
                    if let requestedName { customization.assetLibrary.assets[index].name = requestedName }
                    if let requestedRole { customization.assetLibrary.assets[index].role = requestedRole }
                }
            }
            print("Updated asset \"\(id)\".")
        case "remove", "delete", "rm":
            guard let id = firstPositional(in: rest) else { throw CLIError.message("Usage: thumble asset remove <asset-id>") }
            try mutateProfileResources(profileTarget: optionValue("--profile", in: rest)) { customization in
                customization.assetLibrary.assets.removeAll { $0.id == id }
            }
            print("Removed asset \"\(id)\".")
        default:
            throw CLIError.message("Unknown asset subcommand: \(subcommand)")
        }
    }

    private struct LayerSummary: Codable {
        var id: String
        var kind: String
        var label: String
        var zIndex: Int
        var isHidden: Bool
        var isLocked: Bool
    }

    private static func layerSummary(identity: GamepadControlIdentity, customization: GamepadCustomization) -> LayerSummary {
        switch identity {
        case .builtin(let button):
            let layout = customization.buttonCustomization(for: button)
            return LayerSummary(id: identity.id, kind: "button", label: customization.visualLabel(for: button), zIndex: layout.zIndex, isHidden: layout.isHidden, isLocked: layout.isLocationLocked)
        case .custom(let id):
            let custom = customization.customButtons.first { $0.id == id }?.normalized
            return LayerSummary(id: identity.id, kind: custom?.controlKind.rawValue ?? "custom", label: custom?.label ?? id.uuidString, zIndex: custom?.layout.zIndex ?? 0, isHidden: custom?.layout.isHidden ?? false, isLocked: custom?.layout.isLocationLocked ?? false)
        case .system(.topBarActivation):
            let layout = customization.topBarActivationRegion.normalized
            return LayerSummary(id: identity.id, kind: "system", label: GamepadSystemControl.topBarActivation.displayName, zIndex: layout.zIndex, isHidden: layout.isHidden, isLocked: layout.isLocationLocked)
        case .controlBarItem(let item):
            let layout = customization.controlBarItemCustomization(for: item)
            return LayerSummary(id: identity.id, kind: "control_bar_item", label: item.displayName, zIndex: 0, isHidden: layout.isHidden, isLocked: true)
        }
    }

    private static func makeStyleToken(id: String, name: String, arguments: [String]) throws -> GamepadStyleToken {
        var layout = GamepadButtonCustomization.defaultValue
        try applyRichVisualOptions(arguments, to: &layout)
        if let fill = optionValue("--fill", in: arguments) ?? optionValue("--color", in: arguments) {
            var style = layout.visualStyle ?? .empty
            var normal = style.normal
            normal.fillStyle = .solid(try parseRGBAColor(fill))
            style.normal = normal
            layout.visualStyle = style
        }
        let icon = try parseIconOption(arguments)
        let haptic = try parseHapticFeedbackOptions(arguments, existing: nil)
        var visualStyle = layout.visualStyle ?? .empty
        if let icon { visualStyle.icon = icon }
        if let haptic {
            visualStyle.hapticStyle = haptic.style
            visualStyle.hapticFeedback = haptic
        }
        guard let token = GamepadStyleToken(id: id, name: name, visualStyle: visualStyle).normalized else { throw CLIError.message("Style needs at least one visual property") }
        return token
    }

    private static func authorityStyleAppearance(
        from token: GamepadStyleToken
    ) throws -> ThumbleCLIProfileBackend.AuthorityStyleAppearance {
        guard let style = token.visualStyle.normalized else {
            throw CLIError.message("Style needs at least one visual property")
        }
        let normal = style.normal
        var appearance = ThumbleCLIProfileBackend.AuthorityStyleAppearance()
        if let fill = normal.fillStyle {
            guard case .solid(let color) = fill.normalized else {
                throw CLIError.message("Reusable style creation accepts only a solid non-file fill")
            }
            appearance.fillColor = .init(color)
        }
        appearance.foregroundColor = normal.foregroundColor.map(
            ThumbleCLIProfileBackend.AuthorityColor.init
        )
        appearance.strokeColor = normal.strokeColor.map(
            ThumbleCLIProfileBackend.AuthorityColor.init
        )
        appearance.strokeWidth = normal.strokeWidth.map(Double.init)
        appearance.glowColor = normal.glowColor.map(
            ThumbleCLIProfileBackend.AuthorityColor.init
        )
        appearance.glowRadius = normal.glowRadius.map(Double.init)
        appearance.innerShadowColor = normal.innerShadowColor.map(
            ThumbleCLIProfileBackend.AuthorityColor.init
        )
        appearance.innerShadowRadius = normal.innerShadowRadius.map(Double.init)
        appearance.innerShadowX = normal.innerShadowX.map(Double.init)
        appearance.innerShadowY = normal.innerShadowY.map(Double.init)
        appearance.highlightColor = normal.highlightColor.map(
            ThumbleCLIProfileBackend.AuthorityColor.init
        )
        appearance.highlightRadius = normal.highlightRadius.map(Double.init)
        appearance.highlightX = normal.highlightX.map(Double.init)
        appearance.highlightY = normal.highlightY.map(Double.init)
        appearance.highlightOpacity = normal.highlightOpacity.map(Double.init)
        appearance.bevelHighlightColor = normal.bevelHighlightColor.map(
            ThumbleCLIProfileBackend.AuthorityColor.init
        )
        appearance.bevelShadowColor = normal.bevelShadowColor.map(
            ThumbleCLIProfileBackend.AuthorityColor.init
        )
        appearance.bevelWidth = normal.bevelWidth.map(Double.init)
        appearance.opacity = normal.opacity.map(Double.init)
        if let shadows = normal.shadows {
            var safeShadows: [ThumbleCLIProfileBackend.AuthorityShadow] = []
            safeShadows.reserveCapacity(shadows.count)
            for shadow in shadows {
                safeShadows.append(.init(
                    color: .init(shadow.color),
                    radius: Double(shadow.radius),
                    x: Double(shadow.x),
                    y: Double(shadow.y),
                    opacity: Double(shadow.opacity)
                ))
            }
            appearance.shadows = safeShadows
        }
        if let pressed = style.pressed {
            if let fill = pressed.fillStyle {
                guard case .solid(let color) = fill.normalized else {
                    throw CLIError.message("Reusable pressed styles accept only a solid non-file fill")
                }
                appearance.pressedFillColor = .init(color)
            }
            appearance.pressedScale = pressed.scale.map(Double.init)
        }
        if let icon = style.icon {
            switch icon.source {
            case .sfSymbol:
                appearance.icon = .init(source: .sfSymbol, value: icon.value)
            case .text:
                appearance.icon = .init(source: .text, value: icon.value)
            case .asset:
                throw CLIError.message("Reusable style asset icons require a future bounded artifact transaction")
            }
        }
        if let feedback = style.hapticFeedback {
            appearance.haptic = .init(
                style: feedback.style,
                pattern: feedback.pattern,
                intensity: Double(feedback.intensity),
                sharpness: Double(feedback.sharpness),
                duration: Double(feedback.duration)
            )
        } else if let hapticStyle = style.hapticStyle {
            appearance.haptic = .init(
                style: hapticStyle,
                pattern: nil,
                intensity: nil,
                sharpness: nil,
                duration: nil
            )
        }
        guard !appearance.isEmpty else {
            throw CLIError.message("Style needs at least one visual property")
        }
        return appearance
    }

    private static func applyRichVisualOptions(_ arguments: [String], to layout: inout GamepadButtonCustomization) throws {
        var style = if let material = optionValue("--material", in: arguments) ?? optionValue("--material-preset", in: arguments) {
            try parseMaterialVisualStyle(material)
        } else {
            layout.visualStyle ?? .empty
        }
        var normal = style.normal
        if let stroke = optionValue("--stroke", in: arguments) ?? optionValue("--stroke-color", in: arguments) { normal.strokeColor = try parseRGBAColor(stroke) }
        if let foreground = optionValue("--foreground", in: arguments) ?? optionValue("--foreground-color", in: arguments) ?? optionValue("--text-color", in: arguments) { normal.foregroundColor = try parseRGBAColor(foreground) }
        if let value = optionValue("--stroke-width", in: arguments), let width = Double(value) { normal.strokeWidth = CGFloat(width) }
        if let glow = optionValue("--glow", in: arguments) ?? optionValue("--glow-color", in: arguments) { normal.glowColor = try parseRGBAColor(glow) }
        if let value = optionValue("--glow-radius", in: arguments), let radius = Double(value) { normal.glowRadius = CGFloat(radius) }
        if let innerShadow = optionValue("--inner-shadow", in: arguments) ?? optionValue("--inner-shadow-color", in: arguments) { normal.innerShadowColor = try parseRGBAColor(innerShadow) }
        if let value = optionValue("--inner-shadow-radius", in: arguments), let radius = Double(value) { normal.innerShadowRadius = CGFloat(radius) }
        if let value = optionValue("--inner-shadow-x", in: arguments), let x = Double(value) { normal.innerShadowX = CGFloat(x) }
        if let value = optionValue("--inner-shadow-y", in: arguments), let y = Double(value) { normal.innerShadowY = CGFloat(y) }
        if let highlight = optionValue("--highlight", in: arguments) ?? optionValue("--highlight-color", in: arguments) { normal.highlightColor = try parseRGBAColor(highlight) }
        if let value = optionValue("--highlight-radius", in: arguments), let radius = Double(value) { normal.highlightRadius = CGFloat(radius) }
        if let value = optionValue("--highlight-x", in: arguments), let x = Double(value) { normal.highlightX = CGFloat(x) }
        if let value = optionValue("--highlight-y", in: arguments), let y = Double(value) { normal.highlightY = CGFloat(y) }
        if let value = optionValue("--highlight-opacity", in: arguments), let opacity = parseOpacityIfPresent(value) { normal.highlightOpacity = opacity }
        if let bevelHighlight = optionValue("--bevel-highlight", in: arguments) { normal.bevelHighlightColor = try parseRGBAColor(bevelHighlight) }
        if let bevelShadow = optionValue("--bevel-shadow", in: arguments) { normal.bevelShadowColor = try parseRGBAColor(bevelShadow) }
        if let value = optionValue("--bevel-width", in: arguments) ?? optionValue("--bevel", in: arguments), let width = Double(value) { normal.bevelWidth = CGFloat(width) }
        if let value = optionValue("--opacity", in: arguments), let opacity = parseOpacityIfPresent(value) { normal.opacity = opacity }
        if let shadows = optionValue("--shadow-layers", in: arguments) ?? optionValue("--shadows", in: arguments) {
            normal.shadows = try parseShadowLayers(shadows)
        }
        if let value = optionValue("--press-scale", in: arguments) ?? optionValue("--scale-on-press", in: arguments), let scale = Double(value) {
            var pressed = style.pressed ?? .empty
            pressed.scale = CGFloat(scale)
            style.pressed = pressed
        }
        if let fill = optionValue("--pressed-fill", in: arguments) ?? optionValue("--pressed-color", in: arguments) {
            var pressed = style.pressed ?? .empty
            pressed.fillStyle = .solid(try parseRGBAColor(fill))
            style.pressed = pressed
        }
        if normal != style.normal { style.normal = normal }
        layout.visualStyle = style.normalized
    }

    private enum LayerAuthorityMutation {
        case forward
        case backward
        case front
        case back
    }

    private static func mutateLayerThroughAuthority(
        _ arguments: [String],
        command: LayerAuthorityMutation
    ) throws {
        guard let targetText = firstPositional(in: arguments) else {
            throw CLIError.message("Missing layer element")
        }
        let target = ThumbleCLIProfileBackend.ProfileSelector(
            optionValue("--profile", in: arguments)
        )
        let authorityCommand: ThumbleCLIProfileBackend.Command = switch command {
        case .forward: .layerForward(target, elementID: targetText)
        case .backward: .layerBackward(target, elementID: targetText)
        case .front: .layerFront(target, elementID: targetText)
        case .back: .layerBack(target, elementID: targetText)
        }
        let response = try profileBackend().perform(
            authorityCommand,
            invocationID: try profileInvocationID(in: arguments)
        )
        try requireLayerOutcome(response)
        print("Updated layer \"\(targetText)\".")
        printProfileInvocation(response)
    }

    private static func requireLayerOutcome(
        _ response: ThumbleCLIProfileBackend.Response
    ) throws {
        guard response.outcome != nil else {
            throw CLIError.message("Rust profile authority returned no layer outcome")
        }
    }

    private static func requireGroupOutcome(
        _ response: ThumbleCLIProfileBackend.Response
    ) throws {
        guard response.outcome != nil else {
            throw CLIError.message("Rust profile authority returned no group outcome")
        }
    }

    private static func rejectAuthorityGroupCanvasOverrides(
        _ arguments: [String],
        operation: String
    ) throws {
        if optionValue("--canvas", in: arguments) != nil
            || optionValue("--canvas-width", in: arguments) != nil
            || optionValue("--canvas-height", in: arguments) != nil {
            throw CLIError.message("\(operation) uses the saved device canvas; custom canvas overrides are not available through Rust authority")
        }
    }

    private static func authorityGroupCanvasFrameID(_ arguments: [String]) throws -> String {
        if optionValue("--canvas-width", in: arguments) != nil
            || optionValue("--canvas-height", in: arguments) != nil {
            throw CLIError.message("group nudge accepts only checked-in device frames through Rust authority")
        }
        guard let canvas = optionValue("--canvas", in: arguments) else {
            return GamepadEditorDeviceCatalog.defaultFrameID
        }
        switch normalizedLookup(canvas) {
        case "landscape":
            return GamepadEditorDeviceCatalog.defaultFrameID
        case "portrait":
            return GamepadEditorDeviceFrame(
                spec: GamepadEditorDeviceCatalog.specs[0],
                orientation: .portrait
            ).id
        default:
            guard let frame = GamepadEditorDeviceCatalog.frame(
                matching: canvas,
                preferredOrientation: nil
            ), GamepadEditorDeviceCatalog.frames.contains(where: { $0.id == frame.id }) else {
                throw CLIError.message("group nudge accepts a checked-in device frame id, landscape, or portrait")
            }
            return frame.id
        }
    }

    private static func nudgeGroupThroughAuthority(
        arguments: [String],
        target: ThumbleCLIProfileBackend.ProfileSelector,
        variant: ThumbleCLIProfileBackend.ConfigurationVariant
    ) throws {
        let positional = positionals(in: arguments)
        guard let group = positional.first else {
            throw CLIError.message("Usage: thumble group nudge <group-name-or-id> <left|right|up|down> [--step 1|10]")
        }
        let translation = try parseNudgeTranslation(
            arguments: arguments,
            directionText: positional.dropFirst().first
        )
        let response = try profileBackend().perform(
            .groupNudge(
                target,
                variant,
                group: group,
                canvasFrameID: try authorityGroupCanvasFrameID(arguments),
                deltaX: Double(translation.width),
                deltaY: Double(translation.height)
            ),
            invocationID: try profileInvocationID(in: arguments)
        )
        try requireGroupOutcome(response)
        if response.outcome?.changed == true {
            print("Nudged group \"\(group)\" by \(formatPixels(translation.width))px, \(formatPixels(translation.height))px.")
        } else {
            print("Group \"\(group)\" could not move.")
        }
        printProfileInvocation(response)
    }

    private static func mutateLayout(for target: ElementTarget, in customization: inout GamepadCustomization, mutate: (inout GamepadButtonCustomization) throws -> Void) throws {
        switch target {
        case .builtin(let button):
            var layout = customization.buttonCustomization(for: button)
            try mutate(&layout)
            customization.setButtonCustomization(layout, for: button)
        case .custom(let id):
            guard let index = customization.customButtons.firstIndex(where: { $0.id == id }) else { throw CLIError.message("Custom element not found") }
            try mutate(&customization.customButtons[index].layout)
        case .system(.topBarActivation):
            try mutate(&customization.topBarActivationRegion)
        }
    }

    private static func identity(for target: ElementTarget) -> GamepadControlIdentity {
        switch target {
        case .builtin(let button): .builtin(button)
        case .custom(let id): .custom(id)
        case .system(let control): .system(control)
        }
    }

    private static func groupMatches(_ group: GamepadLayerGroup, target: String) -> Bool {
        group.id.uuidString.lowercased() == target.lowercased() || normalizedLookup(group.name) == normalizedLookup(target)
    }

    private static func parseInteger(_ value: String) throws -> Int {
        guard let integer = Int(value) else { throw CLIError.message("Expected integer, got \(value)") }
        return integer
    }

    private static func slug(_ value: String) -> String {
        let scalars = value.lowercased().unicodeScalars.map { scalar -> UnicodeScalar in
            if CharacterSet.alphanumerics.contains(scalar) { return scalar }
            return UnicodeScalar("-")
        }
        let collapsed = String(String.UnicodeScalarView(scalars)).replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
        return GamepadStyleToken.normalizedIdentifier(collapsed).isEmpty ? UUID().uuidString : GamepadStyleToken.normalizedIdentifier(collapsed)
    }

    private static func parseHapticStyle(_ value: String) throws -> GamepadHapticStyle {
        let normalized = normalizedLookup(value)
        guard let style = GamepadHapticStyle.allCases.first(where: { normalizedLookup($0.rawValue) == normalized || normalizedLookup($0.displayName) == normalized }) else {
            throw CLIError.message("Unknown haptic style: \(value)")
        }
        return style
    }

    private static func parseHapticPattern(_ value: String) throws -> GamepadHapticPattern {
        let normalized = normalizedLookup(value)
        guard let pattern = GamepadHapticPattern.allCases.first(where: { normalizedLookup($0.rawValue) == normalized || normalizedLookup($0.displayName) == normalized }) else {
            throw CLIError.message("Unknown haptic pattern: \(value)")
        }
        return pattern
    }

    private static func parseHapticFeedbackOptions(_ arguments: [String], existing: GamepadHapticFeedback?) throws -> GamepadHapticFeedback? {
        let style = try optionValue("--haptic", in: arguments).map(parseHapticStyle)
        let pattern = try (optionValue("--haptic-pattern", in: arguments) ?? optionValue("--haptic-rhythm", in: arguments)).map(parseHapticPattern)
        let intensity = try (optionValue("--haptic-intensity", in: arguments) ?? optionValue("--haptic-strength", in: arguments)).map { try parseHapticUnitInterval($0, option: "--haptic-intensity") }
        let sharpness = try optionValue("--haptic-sharpness", in: arguments).map { try parseHapticUnitInterval($0, option: "--haptic-sharpness") }
        let duration = try (optionValue("--haptic-duration", in: arguments) ?? optionValue("--haptic-duration-ms", in: arguments)).map(parseHapticDuration)

        guard style != nil || pattern != nil || intensity != nil || sharpness != nil || duration != nil else { return nil }

        var feedback = existing ?? GamepadHapticFeedback(style: style ?? .light)
        if let style {
            let hadAdvancedOverrides = existing != nil
            feedback.style = style
            if !hadAdvancedOverrides && intensity == nil { feedback.intensity = style.defaultIntensity }
            if !hadAdvancedOverrides && sharpness == nil { feedback.sharpness = style.defaultSharpness }
        }
        if let pattern { feedback.pattern = pattern }
        if let intensity { feedback.intensity = intensity }
        if let sharpness { feedback.sharpness = sharpness }
        if let duration { feedback.duration = duration }
        return feedback.normalized
    }

    private static func setHapticFeedback(_ feedback: GamepadHapticFeedback, in layout: inout GamepadButtonCustomization) {
        let normalized = feedback.normalized
        if normalized.isDefault {
            layout.hapticStyle = nil
            layout.hapticFeedback = nil
        } else {
            layout.hapticStyle = normalized.style
            layout.hapticFeedback = normalized
        }
    }

    private static func parseHapticUnitInterval(_ value: String, option: String) throws -> CGFloat {
        guard let parsed = parseOpacityIfPresent(value) else { throw CLIError.message("Invalid \(option): \(value)") }
        return parsed
    }

    private static func parseHapticDuration(_ value: String) throws -> CGFloat {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let seconds: Double?
        if trimmed.hasSuffix("ms") {
            seconds = Double(trimmed.dropLast(2)).map { $0 / 1_000 }
        } else if trimmed.hasSuffix("s") {
            seconds = Double(trimmed.dropLast())
        } else if let raw = Double(trimmed) {
            seconds = raw > 1 ? raw / 1_000 : raw
        } else {
            seconds = nil
        }
        guard let seconds, seconds.isFinite else { throw CLIError.message("Invalid --haptic-duration: \(value)") }
        return CGFloat(seconds)
    }

    private static func parseIconOption(_ arguments: [String]) throws -> GamepadControlIcon? {
        guard let value = optionValue("--icon", in: arguments) ?? optionValue("--sf-symbol", in: arguments) ?? optionValue("--icon-text", in: arguments) else { return nil }
        if value.hasPrefix("text:") { return GamepadControlIcon.text(String(value.dropFirst(5))).normalized }
        if value.hasPrefix("sf:") { return GamepadControlIcon.sfSymbol(String(value.dropFirst(3))).normalized }
        if arguments.contains("--icon-text") { return GamepadControlIcon.text(value).normalized }
        return GamepadControlIcon.sfSymbol(value).normalized
    }

    private static func parseAssetRole(_ value: String) throws -> GamepadAssetRole {
        guard let role = GamepadAssetRole(rawValue: normalizedLookup(value)) else { throw CLIError.message("Unknown asset role: \(value)") }
        return role
    }

    private static func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "svg": "image/svg+xml"
        default: "application/octet-stream"
        }
    }

    // MARK: - Device frames

    private static func device(arguments: [String]) throws {
        let subcommand = arguments.first?.hasPrefix("-") == true ? "list" : (arguments.first ?? "list")
        let rest = subcommand == "list" && arguments.first?.hasPrefix("-") == true ? arguments : Array(arguments.dropFirst())
        switch subcommand {
        case "list", "ls":
            let summaries = GamepadEditorDeviceCatalog.frames.map(deviceFrameSummary)
            if arguments.contains("--json") || rest.contains("--json") {
                try printJSON(summaries)
            } else {
                for summary in summaries {
                    print("\(summary.id)\t\(summary.device)\t\(summary.orientation)\t\(summary.screenPoints)pt\t\(summary.frameStyle)")
                }
            }
        case "show", "current":
            let response = try profileBackend().perform(
                .deviceGet(
                    .init(optionValue("--profile", in: rest)),
                    try authorityConfigurationVariant(in: rest)
                ),
                invocationID: try profileInvocationID(in: rest)
            )
            guard let projection = response.device else {
                throw CLIError.message("Rust profile authority returned no bounded device projection")
            }
            let frame: GamepadEditorDeviceFrame?
            if let frameID = projection.frameID {
                frame = GamepadEditorDeviceCatalog.frames.first(where: { $0.id == frameID })
            } else if let width = projection.customWidth, let height = projection.customHeight {
                frame = GamepadEditorDeviceCatalog.customFrame(
                    width: CGFloat(width),
                    height: CGFloat(height),
                    preferredOrientation: projection.frameOrientation == .landscape ? .landscape : .portrait
                )
            } else {
                frame = nil
            }
            guard let frame else {
                throw CLIError.message("Rust profile authority returned an invalid bounded device projection")
            }
            if rest.contains("--json") {
                try printJSON(deviceFrameSummary(frame))
            } else {
                print("Profile: \(projection.profileName)")
                print("Device frame: \(frame.displayName)")
                print("ID: \(frame.id)")
                print("Screen: \(formatSize(frame.screenRect.size)) pt")
                print("Native: \(formatSize(frame.spec.nativePixels)) px @\(formatScale(frame.spec.nativeScale))")
                print("Frame style: \(frame.frameStyle.displayName)")
            }
        case "set", "select", "use":
            guard let target = firstPositional(in: rest) else { throw CLIError.message("Usage: thumble device set <device-or-frame-id|custom|WIDTHxHEIGHT> [--orientation landscape|portrait] [--profile PROFILE]") }
            let orientationText = optionValue("--orientation", in: rest) ?? optionValue("--device-orientation", in: rest)
            let orientation = try orientationText.map(parseDeviceOrientation)
            let frame = try resolveDeviceFrameTarget(target, arguments: rest, preferredOrientation: orientation)
            try setAuthoritativeDeviceFrame(frame, arguments: rest)
        default:
            let orientationText = optionValue("--orientation", in: rest) ?? optionValue("--device-orientation", in: rest)
            let orientation = try orientationText.map(parseDeviceOrientation)
            if let frame = GamepadEditorDeviceCatalog.frame(matching: subcommand, preferredOrientation: orientation) {
                try setAuthoritativeDeviceFrame(frame, arguments: rest)
            } else {
                throw CLIError.message("Unknown device subcommand: \(subcommand)")
            }
        }
    }

    private static func setAuthoritativeDeviceFrame(
        _ frame: GamepadEditorDeviceFrame,
        arguments: [String]
    ) throws {
        guard GamepadEditorDeviceCatalog.frames.contains(where: { $0.id == frame.id }) else {
            throw CLIError.message("Custom device dimensions require a future bounded configuration transaction. Choose a frame from `thumble device list`.")
        }
        let response = try profileBackend().perform(
            .deviceSet(
                .init(optionValue("--profile", in: arguments)),
                try authorityConfigurationVariant(in: arguments),
                frame.id
            ),
            invocationID: try profileInvocationID(in: arguments)
        )
        guard response.outcome != nil else {
            throw CLIError.message("Rust profile authority returned no device outcome")
        }
        print("Selected device frame for profile: \(frame.displayName) (\(formatSize(frame.screenRect.size)) pt)")
        printProfileInvocation(response)
    }

    private static func resolveDeviceFrame(_ target: String, preferredOrientation: GamepadEditorDeviceOrientation?) throws -> GamepadEditorDeviceFrame {
        guard let frame = GamepadEditorDeviceCatalog.frame(matching: target, preferredOrientation: preferredOrientation) else {
            throw CLIError.message("Unknown iPhone device frame: \(target). Run `thumble device list` to see supported frames or use WIDTHxHEIGHT for a custom canvas.")
        }
        return frame
    }

    private static func resolveDeviceFrameTarget(_ target: String, arguments: [String], preferredOrientation: GamepadEditorDeviceOrientation?) throws -> GamepadEditorDeviceFrame {
        if normalizedLookup(target) == "custom" {
            if let sizeText = optionValue("--size", in: arguments) ?? optionValue("--device-size", in: arguments) {
                return try resolveCustomDeviceFrame(sizeText: sizeText, preferredOrientation: preferredOrientation)
            }
            let widthText = optionValue("--width", in: arguments) ?? optionValue("--device-width", in: arguments)
            let heightText = optionValue("--height", in: arguments) ?? optionValue("--device-height", in: arguments)
            guard let widthText, let heightText else {
                throw CLIError.message("Custom device frames need --size WIDTHxHEIGHT or --width W --height H.")
            }
            guard let frame = GamepadEditorDeviceCatalog.customFrame(width: try parsePixels(widthText), height: try parsePixels(heightText), preferredOrientation: preferredOrientation) else {
                throw CLIError.message("Invalid custom device size.")
            }
            return frame
        }

        if let sizeText = optionValue("--size", in: arguments) ?? optionValue("--device-size", in: arguments) {
            return try resolveCustomDeviceFrame(sizeText: sizeText, preferredOrientation: preferredOrientation)
        }

        return try resolveDeviceFrame(target, preferredOrientation: preferredOrientation)
    }

    private static func resolveCustomDeviceFrame(sizeText: String, preferredOrientation: GamepadEditorDeviceOrientation?) throws -> GamepadEditorDeviceFrame {
        guard let size = parseCanvasSizeLiteral(sizeText),
              let frame = GamepadEditorDeviceCatalog.customFrame(width: size.width, height: size.height, preferredOrientation: preferredOrientation)
        else {
            throw CLIError.message("Invalid custom device size: \(sizeText). Use WIDTHxHEIGHT, such as 844x390.")
        }
        return frame
    }

    private static func parseDeviceOrientation(_ text: String) throws -> GamepadEditorDeviceOrientation {
        switch normalizedLookup(text) {
        case "landscape", "horizontal":
            return .landscape
        case "portrait", "vertical":
            return .portrait
        default:
            throw CLIError.message("Unknown device orientation: \(text). Use landscape or portrait.")
        }
    }

    private static func deviceFrameSummary(_ frame: GamepadEditorDeviceFrame) -> DeviceFrameSummary {
        DeviceFrameSummary(
            id: frame.id,
            device: frame.spec.displayName,
            orientation: frame.orientation.rawValue,
            screenPoints: formatSize(frame.screenRect.size),
            nativePixels: formatSize(frame.spec.nativePixels),
            scale: Double(frame.spec.scale),
            nativeScale: Double(frame.spec.nativeScale),
            frameStyle: frame.frameStyle.rawValue,
            modelIdentifiers: frame.spec.modelIdentifiers
        )
    }

    // MARK: - Control bar

    private static func controlBar(arguments: [String]) throws {
        guard let subcommand = arguments.first else { throw CLIError.message("Missing control-bar subcommand") }
        let rest = Array(arguments.dropFirst())
        let target = ThumbleCLIProfileBackend.ProfileSelector(optionValue("--profile", in: rest))
        let variant = try authorityConfigurationVariant(in: rest)
        let invocationID = try profileInvocationID(in: rest)
        switch subcommand {
        case "list", "ls", "show":
            let response = try profileBackend().perform(
                .controlBarList(target, variant),
                invocationID: invocationID
            )
            guard let projection = response.controlBar else {
                throw CLIError.message("Rust profile authority returned no control-bar projection")
            }
            if rest.contains("--json") {
                try printJSON(projection)
            } else if projection.items.isEmpty {
                print("No controls are pinned to the iPhone control bar for \"\(projection.profileName)\".")
            } else {
                for summary in projection.items {
                    print("\(summary.order).\t\(summary.item.rawValue)\t\(summary.item.displayName)")
                }
            }
        case "set":
            let items = try parseControlBarItems(from: rest)
            let response = try profileBackend().perform(
                .controlBarSet(target, variant, items),
                invocationID: invocationID
            )
            try requireControlBarOutcome(response)
            print("Updated control bar controls.")
            printProfileInvocation(response)
        case "add", "append":
            guard let itemText = firstPositional(in: rest) else { throw CLIError.message("Usage: thumble control-bar add <item>") }
            let item = try parseControlBarItem(itemText)
            let response = try profileBackend().perform(
                .controlBarAdd(target, variant, item),
                invocationID: invocationID
            )
            try requireControlBarOutcome(response)
            print("Added \(item.displayName) to the control bar.")
            printProfileInvocation(response)
        case "remove", "rm", "delete", "hide":
            guard let itemText = firstPositional(in: rest) else { throw CLIError.message("Usage: thumble control-bar remove <item>") }
            let item = try parseControlBarItem(itemText)
            let response = try profileBackend().perform(
                .controlBarRemove(target, variant, item),
                invocationID: invocationID
            )
            try requireControlBarOutcome(response)
            print("Removed \(item.displayName) from the control bar.")
            printProfileInvocation(response)
        case "move":
            let positional = positionals(in: rest)
            guard positional.count >= 2 else { throw CLIError.message("Usage: thumble control-bar move <item> <up|down>") }
            let item = try parseControlBarItem(positional[0])
            let direction: ThumbleCLIProfileBackend.ControlBarMoveDirection
            switch normalizedLookup(positional[1]) {
            case "up", "left", "back", "backward", "earlier": direction = .up
            case "down", "right", "forward", "later": direction = .down
            default: throw CLIError.message("Unknown move direction: \(positional[1]). Use up or down.")
            }
            let response = try profileBackend().perform(
                .controlBarMove(target, variant, item, direction),
                invocationID: invocationID
            )
            try requireControlBarOutcome(response)
            print("Moved \(item.displayName) \(positional[1]).")
            printProfileInvocation(response)
        case "item":
            try controlBarItem(arguments: rest)
        case "reset":
            let response = try profileBackend().perform(
                .controlBarReset(target, variant),
                invocationID: invocationID
            )
            try requireControlBarOutcome(response)
            print("Reset control bar controls and item appearances.")
            printProfileInvocation(response)
        default:
            throw CLIError.message("Unknown control-bar subcommand: \(subcommand)")
        }
    }

    private static func authorityConfigurationVariant(
        in arguments: [String]
    ) throws -> ThumbleCLIProfileBackend.ConfigurationVariant {
        switch try customizationVariant(in: arguments) {
        case .landscape: .landscape
        case .portrait: .portrait
        case nil: .primary
        }
    }

    private static func requireControlBarOutcome(
        _ response: ThumbleCLIProfileBackend.Response
    ) throws {
        guard response.outcome != nil else {
            throw CLIError.message("Rust profile authority returned no control-bar outcome")
        }
    }

    private static func controlBarItem(arguments: [String]) throws {
        let positional = positionals(in: arguments)
        guard positional.count >= 2 else {
            throw CLIError.message("Usage: thumble control-bar item <show|set|reset> <item> [appearance options]")
        }
        let action = normalizedLookup(positional[0])
        let item = try parseControlBarItem(positional[1])
        let target = ThumbleCLIProfileBackend.ProfileSelector(optionValue("--profile", in: arguments))
        let variant = try authorityConfigurationVariant(in: arguments)

        switch action {
        case "show", "get", "inspect":
            let response = try profileBackend().perform(
                .controlBarItemShow(target, variant, item),
                invocationID: try profileInvocationID(in: arguments)
            )
            guard let projection = response.controlBarItem else {
                throw CLIError.message("Rust profile authority returned no control-bar item projection")
            }
            let summary = ControlBarItemSummary(
                configurationRevision: projection.configurationRevision,
                profileID: projection.profileID,
                profileName: projection.profileName,
                variant: projection.variant,
                order: projection.order,
                id: item.rawValue,
                title: item.displayName,
                description: item.subtitle,
                systemImage: item.systemImage,
                appearance: projection.appearance
            )
            if arguments.contains("--json") {
                try printJSON(summary)
            } else {
                print("\(summary.title) (#\(summary.order))")
                print("  icon: \(summary.appearance.icon?.value ?? summary.systemImage)")
                print("  size: \(summary.appearance.widthScale)x\(summary.appearance.heightScale)")
                print("  hidden: \(summary.appearance.isHidden)")
                if summary.appearance.unsupportedContentOmitted {
                    print("  unsupported content: omitted")
                }
            }
        case "set", "edit", "style":
            let read = try profileBackend().perform(.controlBarItemShow(target, variant, item))
            guard let projection = read.controlBarItem else {
                throw CLIError.message("Rust profile authority returned no control-bar item projection")
            }
            let changes = try authorityControlBarItemChanges(
                arguments,
                current: projection.appearance
            )
            guard !changes.isEmpty else { throw CLIError.message("No control-bar appearance changes requested") }
            let response = try profileBackend().perform(
                .controlBarItemSet(target, variant, item, changes),
                invocationID: try profileInvocationID(in: arguments),
                expectedConfigurationRevision: projection.configurationRevision
            )
            try requireControlBarOutcome(response)
            print("Updated \(item.displayName) appearance.")
            printProfileInvocation(response)
        case "reset":
            let response = try profileBackend().perform(
                .controlBarItemReset(target, variant, item),
                invocationID: try profileInvocationID(in: arguments)
            )
            try requireControlBarOutcome(response)
            print("Reset \(item.displayName) appearance.")
            printProfileInvocation(response)
        default:
            throw CLIError.message("Unknown control-bar item action: \(positional[0]). Use show, set, or reset.")
        }
    }

    private static func authorityControlBarItemChanges(
        _ arguments: [String],
        current: ThumbleCLIProfileBackend.SafeControlBarItemAppearance
    ) throws -> ThumbleCLIProfileBackend.ControlBarItemChanges {
        typealias Backend = ThumbleCLIProfileBackend
        let changes = Backend.ControlBarItemChanges()

        func finite(_ value: String, option: String) throws -> Double {
            guard let parsed = Double(value), parsed.isFinite else {
                throw CLIError.message("Invalid \(option): \(value)")
            }
            return parsed
        }
        func opacity(_ value: String, option: String) throws -> Double {
            guard let parsed = parseOpacityIfPresent(value) else {
                throw CLIError.message("Invalid \(option): \(value)")
            }
            return Double(parsed)
        }

        if let value = optionValue("--width", in: arguments) ?? optionValue("--width-scale", in: arguments) {
            changes.widthScale = try finite(value, option: "--width")
        }
        if let value = optionValue("--height", in: arguments) ?? optionValue("--height-scale", in: arguments) {
            changes.heightScale = try finite(value, option: "--height")
        }
        if let value = optionValue("--shape", in: arguments) {
            guard let shape = parseShapeStyleIfPresent(value) else {
                throw CLIError.message("Unknown shape: \(value)")
            }
            changes.shape = shape
        }
        if let value = optionValue("--accent", in: arguments) {
            changes.accentStyle = try parseAccentStyle(value)
        }

        if let value = optionValue("--fill", in: arguments) ?? optionValue("--color", in: arguments) {
            changes.fill = try Backend.AuthorityFill(.solid(parseRGBAColor(value)))
        }
        if arguments.contains("--clear-fill") || arguments.contains("--clear-color") {
            changes.fill = nil
            changes.clearFill = true
        }
        if let value = optionValue("--fill-gradient", in: arguments) ?? optionValue("--gradient", in: arguments) {
            changes.fill = try Backend.AuthorityFill(parseGradientFill(value, arguments: arguments))
            changes.clearFill = false
        }
        if let value = optionValue("--fill-tile", in: arguments) ?? optionValue("--tile", in: arguments) {
            changes.fill = try Backend.AuthorityFill(parseTileFill(value, arguments: arguments))
            changes.clearFill = false
        }
        if optionValue("--fill-image", in: arguments) != nil || optionValue("--image", in: arguments) != nil {
            throw CLIError.message("Control-bar image fills require a future bounded artifact transaction.")
        }
        if arguments.contains("--clear-fill-style") {
            changes.fill = nil
            changes.clearFill = true
        }

        if let value = optionValue("--light-fill", in: arguments)
            ?? optionValue("--fill-light", in: arguments)
            ?? optionValue("--light-color", in: arguments) {
            changes.lightFill = try Backend.AuthorityFill(.solid(parseRGBAColor(value)))
        }
        if let value = optionValue("--light-fill-gradient", in: arguments)
            ?? optionValue("--gradient-light", in: arguments) {
            changes.lightFill = try Backend.AuthorityFill(parseGradientFill(value, arguments: arguments))
        }
        if let value = optionValue("--light-fill-tile", in: arguments)
            ?? optionValue("--tile-light", in: arguments) {
            changes.lightFill = try Backend.AuthorityFill(parseTileFill(value, arguments: arguments))
        }
        if arguments.contains("--clear-light-fill") || arguments.contains("--clear-light-color") {
            changes.lightFill = nil
            changes.clearLightFill = true
        }
        if let value = optionValue("--dark-fill", in: arguments)
            ?? optionValue("--fill-dark", in: arguments)
            ?? optionValue("--dark-color", in: arguments) {
            changes.darkFill = try Backend.AuthorityFill(.solid(parseRGBAColor(value)))
        }
        if let value = optionValue("--dark-fill-gradient", in: arguments)
            ?? optionValue("--gradient-dark", in: arguments) {
            changes.darkFill = try Backend.AuthorityFill(parseGradientFill(value, arguments: arguments))
        }
        if let value = optionValue("--dark-fill-tile", in: arguments)
            ?? optionValue("--tile-dark", in: arguments) {
            changes.darkFill = try Backend.AuthorityFill(parseTileFill(value, arguments: arguments))
        }
        if arguments.contains("--clear-dark-fill") || arguments.contains("--clear-dark-color") {
            changes.darkFill = nil
            changes.clearDarkFill = true
        }
        if let value = optionValue("--opacity", in: arguments) {
            changes.fillOpacity = try opacity(value, option: "--opacity")
        }
        if let value = optionValue("--light-opacity", in: arguments) {
            changes.lightFillOpacity = try opacity(value, option: "--light-opacity")
        }
        if let value = optionValue("--dark-opacity", in: arguments) {
            changes.darkFillOpacity = try opacity(value, option: "--dark-opacity")
        }

        if let styleID = optionValue("--style", in: arguments) ?? optionValue("--style-id", in: arguments) {
            changes.styleID = styleID
        }
        if arguments.contains("--clear-style") || arguments.contains("--detach-style") {
            changes.styleID = nil
            changes.clearStyle = true
        }

        if let icon = try parseIconOption(arguments) {
            switch icon.source {
            case .sfSymbol:
                changes.icon = Backend.AuthorityIcon(source: .sfSymbol, value: icon.value)
            case .text:
                changes.icon = Backend.AuthorityIcon(source: .text, value: icon.value)
            case .asset:
                throw CLIError.message("Control-bar asset icons require a future bounded artifact transaction.")
            }
        }
        if arguments.contains("--clear-icon") {
            changes.icon = nil
            changes.clearIcon = true
        }

        let hapticStyle = try optionValue("--haptic", in: arguments).map(parseHapticStyle)
        let hapticPattern = try (
            optionValue("--haptic-pattern", in: arguments)
                ?? optionValue("--haptic-rhythm", in: arguments)
        ).map(parseHapticPattern)
        let hapticIntensity = try (
            optionValue("--haptic-intensity", in: arguments)
                ?? optionValue("--haptic-strength", in: arguments)
        ).map { Double(try parseHapticUnitInterval($0, option: "--haptic-intensity")) }
        let hapticSharpness = try optionValue("--haptic-sharpness", in: arguments)
            .map { Double(try parseHapticUnitInterval($0, option: "--haptic-sharpness")) }
        let hapticDuration = try (
            optionValue("--haptic-duration", in: arguments)
                ?? optionValue("--haptic-duration-ms", in: arguments)
        ).map { Double(try parseHapticDuration($0)) }
        if hapticStyle != nil || hapticPattern != nil || hapticIntensity != nil
            || hapticSharpness != nil || hapticDuration != nil {
            changes.haptic = Backend.AuthorityHaptic(
                style: hapticStyle,
                pattern: hapticPattern,
                intensity: hapticIntensity,
                sharpness: hapticSharpness,
                duration: hapticDuration
            )
        }
        if arguments.contains("--clear-haptic") {
            changes.haptic = nil
            changes.clearHaptic = true
        }

        var appearance = Backend.AuthorityStyleAppearance()
        if let material = optionValue("--material", in: arguments)
            ?? optionValue("--material-preset", in: arguments) {
            switch normalizedLookup(material) {
            case "softwhite", "softwhiteraised", "raised", "neumorphic", "neumorphicraised":
                appearance.materialPreset = .softWhiteRaised
            case "softwhiteinset", "inset", "recessed", "well":
                appearance.materialPreset = .softWhiteInset
            case "softwhiteplate", "plate", "panel", "shell":
                appearance.materialPreset = .softWhitePlate
            default:
                throw CLIError.message("Unknown material preset: \(material). Use soft-white, soft-white-inset, or soft-white-plate.")
            }
        }
        if let value = optionValue("--stroke", in: arguments) ?? optionValue("--stroke-color", in: arguments) {
            appearance.strokeColor = Backend.AuthorityColor(try parseRGBAColor(value))
        }
        if let value = optionValue("--foreground", in: arguments)
            ?? optionValue("--foreground-color", in: arguments)
            ?? optionValue("--text-color", in: arguments) {
            appearance.foregroundColor = Backend.AuthorityColor(try parseRGBAColor(value))
        }
        if let value = optionValue("--stroke-width", in: arguments) {
            appearance.strokeWidth = try finite(value, option: "--stroke-width")
        }
        if let value = optionValue("--glow", in: arguments) ?? optionValue("--glow-color", in: arguments) {
            appearance.glowColor = Backend.AuthorityColor(try parseRGBAColor(value))
        }
        if let value = optionValue("--glow-radius", in: arguments) {
            appearance.glowRadius = try finite(value, option: "--glow-radius")
        }
        if let value = optionValue("--inner-shadow", in: arguments)
            ?? optionValue("--inner-shadow-color", in: arguments) {
            appearance.innerShadowColor = Backend.AuthorityColor(try parseRGBAColor(value))
        }
        if let value = optionValue("--inner-shadow-radius", in: arguments) {
            appearance.innerShadowRadius = try finite(value, option: "--inner-shadow-radius")
        }
        if let value = optionValue("--inner-shadow-x", in: arguments) {
            appearance.innerShadowX = try finite(value, option: "--inner-shadow-x")
        }
        if let value = optionValue("--inner-shadow-y", in: arguments) {
            appearance.innerShadowY = try finite(value, option: "--inner-shadow-y")
        }
        if let value = optionValue("--highlight", in: arguments)
            ?? optionValue("--highlight-color", in: arguments) {
            appearance.highlightColor = Backend.AuthorityColor(try parseRGBAColor(value))
        }
        if let value = optionValue("--highlight-radius", in: arguments) {
            appearance.highlightRadius = try finite(value, option: "--highlight-radius")
        }
        if let value = optionValue("--highlight-x", in: arguments) {
            appearance.highlightX = try finite(value, option: "--highlight-x")
        }
        if let value = optionValue("--highlight-y", in: arguments) {
            appearance.highlightY = try finite(value, option: "--highlight-y")
        }
        if let value = optionValue("--highlight-opacity", in: arguments) {
            appearance.highlightOpacity = try opacity(value, option: "--highlight-opacity")
        }
        if let value = optionValue("--bevel-highlight", in: arguments) {
            appearance.bevelHighlightColor = Backend.AuthorityColor(try parseRGBAColor(value))
        }
        if let value = optionValue("--bevel-shadow", in: arguments) {
            appearance.bevelShadowColor = Backend.AuthorityColor(try parseRGBAColor(value))
        }
        if let value = optionValue("--bevel-width", in: arguments) ?? optionValue("--bevel", in: arguments) {
            appearance.bevelWidth = try finite(value, option: "--bevel-width")
        }
        if let value = optionValue("--opacity", in: arguments) {
            appearance.opacity = try opacity(value, option: "--opacity")
        }
        if let value = optionValue("--shadow-layers", in: arguments) ?? optionValue("--shadows", in: arguments) {
            appearance.shadows = try parseShadowLayers(value).map {
                Backend.AuthorityShadow(
                    color: Backend.AuthorityColor($0.color),
                    radius: Double($0.radius),
                    x: Double($0.x),
                    y: Double($0.y),
                    opacity: Double($0.opacity)
                )
            }
        }
        if let value = optionValue("--press-scale", in: arguments)
            ?? optionValue("--scale-on-press", in: arguments) {
            appearance.pressedScale = try finite(value, option: "--press-scale")
        }
        if let value = optionValue("--pressed-fill", in: arguments)
            ?? optionValue("--pressed-color", in: arguments) {
            appearance.pressedFillColor = Backend.AuthorityColor(try parseRGBAColor(value))
        }
        if !appearance.isEmpty { changes.appearance = appearance }

        if let value = optionValue("--corner", in: arguments) ?? optionValue("--radius", in: arguments) {
            changes.cornerRadius = try finite(value, option: "--corner")
            changes.cornerRadii = nil
        }
        let cornerOptions: [(
            String,
            WritableKeyPath<ThumbleCLIProfileBackend.AuthorityCornerRadii, Double>
        )] = [
            ("--corner-tl", \.topLeading),
            ("--corner-tr", \.topTrailing),
            ("--corner-br", \.bottomTrailing),
            ("--corner-bl", \.bottomLeading)
        ]
        if cornerOptions.contains(where: { optionValue($0.0, in: arguments) != nil }) {
            let base = current.cornerRadii ?? Backend.AuthorityCornerRadii(
                topLeading: current.cornerRadius ?? 0,
                topTrailing: current.cornerRadius ?? 0,
                bottomTrailing: current.cornerRadius ?? 0,
                bottomLeading: current.cornerRadius ?? 0
            )
            var radii = base
            for (option, keyPath) in cornerOptions {
                if let value = optionValue(option, in: arguments) {
                    radii[keyPath: keyPath] = try finite(value, option: option)
                }
            }
            changes.cornerRadius = nil
            changes.cornerRadii = radii
        }
        if let value = optionValue("--shadow", in: arguments)
            ?? optionValue("--shadow-strength", in: arguments) {
            changes.shadowStrength = try finite(value, option: "--shadow")
        }
        if arguments.contains("--hide") || arguments.contains("--hidden") {
            changes.isHidden = true
        }
        if arguments.contains("--show") || arguments.contains("--visible") {
            changes.isHidden = false
        }
        return changes
    }

    private static func parseControlBarItems(from arguments: [String]) throws -> [GamepadControlBarItem] {
        let itemText = optionValue("--items", in: arguments) ?? optionValue("--controls", in: arguments) ?? positionals(in: arguments).joined(separator: ",")
        let parts = itemText
            .split { $0 == "," || $0 == ";" || $0.isWhitespace }
            .map(String.init)
        guard !parts.isEmpty else { throw CLIError.message("Usage: thumble control-bar set status,profiles,spacer,edit,settings,home,connection") }
        return GamepadCustomization.normalizedControlBarItems(try parts.map(parseControlBarItem))
    }

    private static func parseControlBarItem(_ text: String) throws -> GamepadControlBarItem {
        switch normalizedLookup(text) {
        case "status", "connectionstatus", "indicator", "pill":
            return .connectionStatus
        case "profile", "profiles", "profilemenu", "profilepicker", "keypad", "keypads", "setup", "setups":
            return .profileMenu
        case "launch", "launcher", "launchtarget", "app", "application", "launchapp", "target":
            return .launchTarget
        case "spacer", "space", "flex", "flexiblespace", "gap":
            return .spacer
        case "edit", "editlayout", "layout", "lock", "unlock":
            return .editLayout
        case "settings", "setting", "gear", "keypadsettings":
            return .settings
        case "home", "connectionpage", "start":
            return .home
        case "connection", "connect", "disconnect", "connectdisconnect", "connectmac", "mac":
            return .connectionAction
        default:
            throw CLIError.message("Unknown control bar item: \(text). Use status, profiles, launch, spacer, edit, settings, home, or connection.")
        }
    }

    // MARK: - Elements

    private static func element(arguments: [String]) throws {
        guard let subcommand = arguments.first else { throw CLIError.message("Missing element subcommand") }
        let rest = Array(arguments.dropFirst())
        switch subcommand {
        case "list", "ls":
            let response = try profileBackend().perform(
                .layerList(
                    .init(optionValue("--profile", in: rest)),
                    try authorityConfigurationVariant(in: rest)
                ),
                invocationID: try profileInvocationID(in: rest)
            )
            guard let projection = response.layers else {
                throw CLIError.message("Rust profile authority returned no sanitized element projection")
            }
            if rest.contains("--json") {
                try printJSON(projection.layers)
            } else {
                for item in projection.layers {
                    print("\(item.targetID)\t\(item.kind)\t\(item.label)\t\(item.isHidden ? "hidden" : "visible")\(item.isLocationLocked ? " locked" : "")")
                }
            }
        case "add":
            try addElement(arguments: rest)
        case "duplicate", "copy":
            try duplicateElements(arguments: rest)
        case "set":
            try setElement(arguments: rest)
        case "align":
            try alignElements(arguments: rest)
        case "distribute":
            try distributeElements(arguments: rest)
        case "nudge", "move":
            try nudgeElement(arguments: rest)
        case "delete", "rm":
            try deleteElement(arguments: rest)
        case "reset":
            try resetElement(arguments: rest)
        default:
            throw CLIError.message("Unknown element subcommand: \(subcommand)")
        }
    }

    private static func duplicateElements(arguments: [String]) throws {
        try requireExplicitUnmigratedProfileAccess(operation: "element duplicate")
        let targetTexts = positionals(in: arguments)
        guard !targetTexts.isEmpty else {
            throw CLIError.message("Usage: thumble element duplicate <element> [element...] [--offset 0.025]")
        }
        let offset = try parseDuplicateOffset(arguments)
        var result: GamepadElementDuplicationResult?
        try mutateCustomization(profileTarget: optionValue("--profile", in: arguments), variant: try customizationVariant(in: arguments)) { customization in
            let identities = try targetTexts.map { identity(for: try resolveElementTarget($0, in: customization)) }
            let canvasSize = try parseLayoutCanvasSize(arguments, fallback: customization.deviceCanvas.editorDeviceFrame.screenRect.size)
            result = try customization.duplicateControls(identities, normalizedOffset: offset, canvasSize: canvasSize)
        }
        let ids = result?.duplicatedIdentities.map(\.id).joined(separator: ", ") ?? ""
        print("Duplicated \(targetTexts.count) element\(targetTexts.count == 1 ? "" : "s"): \(ids)")
    }

    private static func alignElements(arguments: [String]) throws {
        try requireExplicitUnmigratedProfileAccess(operation: "element align")
        let positional = positionals(in: arguments)
        guard positional.count >= 3 else {
            throw CLIError.message("Usage: thumble element align <left|horizontal-centers|right|top|vertical-centers|bottom> <element> <element>...")
        }
        let alignment = try parseControlAlignment(positional[0])
        let targetTexts = Array(positional.dropFirst())
        try mutateCustomization(profileTarget: optionValue("--profile", in: arguments), variant: try customizationVariant(in: arguments)) { customization in
            let identities = try Set(targetTexts.map { identity(for: try resolveElementTarget($0, in: customization)) })
            let canvasSize = try parseLayoutCanvasSize(arguments, fallback: customization.deviceCanvas.editorDeviceFrame.screenRect.size)
            _ = try customization.alignControls(identities, alignment: alignment, in: canvasSize)
        }
        print("Aligned \(targetTexts.count) elements by \(alignment.rawValue).")
    }

    private static func distributeElements(arguments: [String]) throws {
        try requireExplicitUnmigratedProfileAccess(operation: "element distribute")
        let positional = positionals(in: arguments)
        guard positional.count >= 4 else {
            throw CLIError.message("Usage: thumble element distribute <horizontal-centers|vertical-centers|horizontal-spacing|vertical-spacing> <element> <element> <element>...")
        }
        let distribution = try parseControlDistribution(positional[0])
        let targetTexts = Array(positional.dropFirst())
        try mutateCustomization(profileTarget: optionValue("--profile", in: arguments), variant: try customizationVariant(in: arguments)) { customization in
            let identities = try Set(targetTexts.map { identity(for: try resolveElementTarget($0, in: customization)) })
            let canvasSize = try parseLayoutCanvasSize(arguments, fallback: customization.deviceCanvas.editorDeviceFrame.screenRect.size)
            _ = try customization.distributeControls(identities, distribution: distribution, in: canvasSize)
        }
        print("Distributed \(targetTexts.count) elements by \(distribution.rawValue).")
    }

    private static func parseControlAlignment(_ value: String) throws -> GamepadControlAlignment {
        switch normalizedLookup(value) {
        case "left", "leftedges": return .leftEdges
        case "horizontalcenter", "horizontalcenters", "hcenter", "centerx": return .horizontalCenters
        case "right", "rightedges": return .rightEdges
        case "top", "topedges": return .topEdges
        case "verticalcenter", "verticalcenters", "vcenter", "centery": return .verticalCenters
        case "bottom", "bottomedges": return .bottomEdges
        default: throw CLIError.message("Unknown alignment: \(value)")
        }
    }

    private static func parseControlDistribution(_ value: String) throws -> GamepadControlDistribution {
        switch normalizedLookup(value) {
        case "horizontalcenter", "horizontalcenters", "hcenters": return .horizontalCenters
        case "verticalcenter", "verticalcenters", "vcenters": return .verticalCenters
        case "horizontalspacing", "hspacing", "horizontalgaps": return .horizontalSpacing
        case "verticalspacing", "vspacing", "verticalgaps": return .verticalSpacing
        default: throw CLIError.message("Unknown distribution: \(value)")
        }
    }

    private static func parseDuplicateOffset(_ arguments: [String]) throws -> CGSize {
        let shared = try optionValue("--offset", in: arguments).map(parseNormalizedOffset)
        let x = try optionValue("--offset-x", in: arguments).map(parseNormalizedOffset) ?? shared ?? 0.025
        let y = try optionValue("--offset-y", in: arguments).map(parseNormalizedOffset) ?? shared ?? 0.025
        return CGSize(width: x, height: y)
    }

    private static func parseNormalizedOffset(_ value: String) throws -> CGFloat {
        guard let parsed = Double(value), parsed.isFinite else { throw CLIError.message("Invalid normalized offset: \(value)") }
        guard abs(parsed) <= 1 else { throw CLIError.message("Normalized offset must be between -1 and 1") }
        return CGFloat(parsed)
    }

    private static func addElement(arguments: [String]) throws {
        try requireExplicitUnmigratedProfileAccess(operation: "element add")
        guard let kindText = firstPositional(in: arguments) else { throw CLIError.message("Usage: thumble element add <button|joystick|trigger|trackpad|text|decoration> [options]") }
        let kind = try parseCustomControlKind(kindText)
        try mutateCustomization(profileTarget: optionValue("--profile", in: arguments), variant: try customizationVariant(in: arguments)) { customization in
            guard customization.customButtons.count < GamepadCustomization.maximumCustomButtons else { throw CLIError.message("Maximum custom element count reached") }
            if kind == .joystick && customization.customButtons.filter({ $0.normalized.isJoystick }).count >= GamepadCustomization.maximumJoysticks {
                throw CLIError.message("Maximum joystick count reached")
            }
            if kind == .trigger && customization.customButtons.filter({ $0.normalized.isTrigger }).count >= GamepadCustomization.maximumTriggers {
                throw CLIError.message("Maximum trigger count reached")
            }
            if kind == .trackpad && customization.customButtons.filter({ $0.normalized.isTrackpad }).count >= GamepadCustomization.maximumTrackpads {
                throw CLIError.message("Maximum trackpad count reached")
            }

            let id = UUID()
            let triggerCount = customization.customButtons.filter { $0.normalized.isTrigger }.count
            let defaultTriggerTarget: VirtualGamepadTrigger = triggerCount == 0 ? .left : .right
            let isPassiveLayer = kind == .text || kind == .decoration
            let mapped = try optionValue("--maps-to", in: arguments).map(parseButton) ?? (kind == .joystick ? .up : (isPassiveLayer ? .custom8 : firstAvailableCustomSlot(in: customization) ?? .custom1))
            var customButton = GamepadCustomButton(
                id: id,
                mappedButton: mapped,
                label: optionValue("--text", in: arguments) ?? optionValue("--label", in: arguments) ?? (kind == .trigger ? defaultTriggerTarget.shortName : defaultLabel(for: kind)),
                controlKind: kind,
                visualRole: try (optionValue("--visual-role", in: arguments) ?? optionValue("--skin-role", in: arguments)).map(parseVisualRole),
                joystickMapping: kind == .joystick ? try joystickMapping(from: arguments) : nil,
                joystickOutputSettings: kind == .joystick ? try joystickOutputSettings(from: arguments) : nil,
                triggerSettings: kind == .trigger ? try triggerSettings(from: arguments, fallback: GamepadTriggerSettings(target: defaultTriggerTarget, orientation: .horizontal)) : nil,
                trackpadSettings: kind == .trackpad ? .defaultValue : nil
            )
            try applyLayoutOptions(arguments, to: &customButton.layout)
            if kind == .button {
                customButton.layout.showsIntegratedLabel = false
            }
            if kind == .joystick {
                customButton.layout.shape = .circle
                let defaultScale: CGFloat = customButton.layout.joystickVisualStyle == .thumbstick ? 0.58 : 1.35
                customButton.layout.widthScale = customButton.layout.widthScale == 1.0 ? defaultScale : customButton.layout.widthScale
                customButton.layout.heightScale = customButton.layout.heightScale == 1.0 ? defaultScale : customButton.layout.heightScale
                customButton.joystickMapping = try joystickMapping(from: arguments)
                customButton.joystickOutputSettings = try joystickOutputSettings(from: arguments, fallback: customButton.joystickOutputSettings ?? .defaultValue)
                customButton.triggerSettings = nil
            } else if kind == .trigger {
                let settings = try triggerSettings(from: arguments, fallback: customButton.triggerSettings ?? .defaultValue)
                customButton.layout.shape = .capsule
                customButton.layout.widthScale = customButton.layout.widthScale == 1.0 ? 1.08 : customButton.layout.widthScale
                customButton.layout.heightScale = customButton.layout.heightScale == 1.0 ? 0.42 : customButton.layout.heightScale
                if optionValue("--x", in: arguments) == nil && optionValue("--center-x", in: arguments) == nil {
                    customButton.layout.centerX = settings.target == .left ? 0.20 : 0.80
                }
                if optionValue("--y", in: arguments) == nil && optionValue("--center-y", in: arguments) == nil {
                    customButton.layout.centerY = 0.14
                }
                customButton.joystickMapping = nil
                customButton.triggerSettings = settings
                customButton.trackpadSettings = nil
            } else if kind == .trackpad {
                customButton.layout.shape = customButton.layout.shape ?? .roundedRectangle
                customButton.layout.widthScale = customButton.layout.widthScale == 1.0 ? 1.25 : customButton.layout.widthScale
                customButton.layout.heightScale = customButton.layout.heightScale == 1.0 ? 1.0 : customButton.layout.heightScale
                if optionValue("--y", in: arguments) == nil && optionValue("--center-y", in: arguments) == nil {
                    customButton.layout.centerY = 0.58
                }
                if optionValue("--corner", in: arguments) == nil && optionValue("--radius", in: arguments) == nil {
                    customButton.layout.cornerRadius = customButton.layout.cornerRadius ?? 18
                }
                customButton.triggerSettings = nil
                customButton.trackpadSettings = try trackpadSettings(from: arguments)
            } else if kind == .text {
                customButton.layout.shape = .rectangle
                customButton.layout.widthScale = customButton.layout.widthScale == 1.0 ? 1.4 : customButton.layout.widthScale
                customButton.layout.heightScale = customButton.layout.heightScale == 1.0 ? 0.7 : customButton.layout.heightScale
                customButton.layout.shadowStrength = 0
                customButton.layout.showsIntegratedLabel = false
                customButton.joystickMapping = nil
                customButton.joystickOutputSettings = nil
                customButton.triggerSettings = nil
                customButton.trackpadSettings = nil
            } else if kind == .decoration {
                customButton.layout.shape = customButton.layout.shape ?? .roundedRectangle
                customButton.layout.widthScale = customButton.layout.widthScale == 1.0 ? 2.2 : customButton.layout.widthScale
                customButton.layout.heightScale = customButton.layout.heightScale == 1.0 ? 1.2 : customButton.layout.heightScale
                customButton.layout.shadowStrength = 0
                customButton.layout.visualStyle = customButton.layout.visualStyle ?? .softWhitePlate()
                if optionValue("--corner", in: arguments) == nil && optionValue("--radius", in: arguments) == nil {
                    customButton.layout.cornerRadius = customButton.layout.cornerRadius ?? 28
                }
                customButton.joystickMapping = nil
                customButton.triggerSettings = nil
                customButton.trackpadSettings = nil
            }
            try customization.addStandaloneCustomControl(customButton)
            if !isPassiveLayer && hasAnyOption(elementOutputOptionNames, in: arguments) {
                try applyElementOutputOptions(arguments, target: .custom(id), to: &customization)
            }
        }
        print("Added \(kind.displayName.lowercased()).")
    }

    private static func setElement(arguments: [String]) throws {
        try requireExplicitUnmigratedProfileAccess(operation: "element set")
        guard let targetText = firstPositional(in: arguments) else { throw CLIError.message("Missing element id, button, or label") }
        try mutateCustomization(profileTarget: optionValue("--profile", in: arguments), variant: try customizationVariant(in: arguments)) { customization in
            let target = try resolveElementTarget(targetText, in: customization)
            switch target {
            case .builtin(let button):
                if arguments.contains("--clear-label") {
                    customization.setLabel("", for: button)
                } else if let label = optionValue("--label", in: arguments) {
                    customization.setLabel(label, for: button)
                }
                if arguments.contains("--clear-visual-role") || arguments.contains("--clear-skin-role") {
                    if let index = customization.elements.firstIndex(where: { $0.builtInButton == button }) {
                        customization.elements[index].visualRole = nil
                    }
                } else if let role = try (optionValue("--visual-role", in: arguments) ?? optionValue("--skin-role", in: arguments)).map(parseVisualRole),
                          let index = customization.elements.firstIndex(where: { $0.builtInButton == button }) {
                    customization.elements[index].visualRole = role
                }
                var layout = customization.buttonCustomization(for: button)
                try applyLayoutOptions(arguments, to: &layout)
                customization.setButtonCustomization(layout, for: button)
            case .custom(let id):
                guard let index = customization.customButtons.firstIndex(where: { $0.id == id }) else { throw CLIError.message("Custom element not found") }
                if arguments.contains("--clear-label") {
                    customization.customButtons[index].label = customization.customButtons[index].controlKind == .text
                        ? "Text"
                        : customization.visualLabel(for: customization.customButtons[index].mappedButton)
                } else if let label = optionValue("--text", in: arguments) ?? optionValue("--label", in: arguments) {
                    customization.customButtons[index].label = normalizedLabel(label)
                }
                if let mapped = optionValue("--maps-to", in: arguments) { customization.customButtons[index].mappedButton = try parseButton(mapped) }
                if let kind = optionValue("--kind", in: arguments) { customization.customButtons[index].controlKind = try parseCustomControlKind(kind) }
                if arguments.contains("--clear-visual-role") || arguments.contains("--clear-skin-role") {
                    customization.customButtons[index].visualRole = nil
                } else if let role = try (optionValue("--visual-role", in: arguments) ?? optionValue("--skin-role", in: arguments)).map(parseVisualRole) {
                    customization.customButtons[index].visualRole = role
                }
                let currentKind = customization.customButtons[index].controlKind
                let hasJoystickOptions = hasAnyOption(joystickOptionNames, in: arguments)
                    || (currentKind == .joystick && hasAnyOption(["--target", "--dead-zone", "--deadzone", "--sensitivity"], in: arguments))
                let hasTriggerOptions = hasAnyOption(triggerOptionNames, in: arguments)
                let hasTrackpadOptions = hasAnyOption(trackpadOptionNames, in: arguments)
                if customization.customButtons[index].controlKind == .joystick || hasJoystickOptions {
                    customization.customButtons[index].controlKind = .joystick
                    customization.customButtons[index].joystickMapping = try joystickMapping(from: arguments, fallback: customization.customButtons[index].joystickMapping ?? .movement)
                    customization.customButtons[index].joystickOutputSettings = try joystickOutputSettings(from: arguments, fallback: customization.customButtons[index].joystickOutputSettings ?? .defaultValue)
                    customization.customButtons[index].triggerSettings = nil
                    customization.customButtons[index].trackpadSettings = nil
                    customization.customButtons[index].layout.shape = .circle
                } else if customization.customButtons[index].controlKind == .trigger || hasTriggerOptions {
                    customization.customButtons[index].controlKind = .trigger
                    customization.customButtons[index].joystickMapping = nil
                    customization.customButtons[index].joystickOutputSettings = nil
                    customization.customButtons[index].triggerSettings = try triggerSettings(from: arguments, fallback: customization.customButtons[index].triggerSettings ?? .defaultValue)
                    customization.customButtons[index].trackpadSettings = nil
                    customization.customButtons[index].layout.shape = .capsule
                } else if customization.customButtons[index].controlKind == .trackpad || hasTrackpadOptions {
                    customization.customButtons[index].controlKind = .trackpad
                    customization.customButtons[index].joystickMapping = nil
                    customization.customButtons[index].joystickOutputSettings = nil
                    customization.customButtons[index].triggerSettings = nil
                    customization.customButtons[index].layout.shape = customization.customButtons[index].layout.shape ?? .roundedRectangle
                    customization.customButtons[index].trackpadSettings = try trackpadSettings(from: arguments, fallback: customization.customButtons[index].trackpadSettings ?? .defaultValue)
                } else if customization.customButtons[index].controlKind == .text {
                    customization.customButtons[index].joystickMapping = nil
                    customization.customButtons[index].joystickOutputSettings = nil
                    customization.customButtons[index].triggerSettings = nil
                    customization.customButtons[index].trackpadSettings = nil
                    customization.customButtons[index].layout.shape = .rectangle
                    customization.customButtons[index].layout.shadowStrength = 0
                    customization.customButtons[index].layout.showsIntegratedLabel = false
                } else if customization.customButtons[index].controlKind == .decoration {
                    customization.customButtons[index].joystickMapping = nil
                    customization.customButtons[index].joystickOutputSettings = nil
                    customization.customButtons[index].triggerSettings = nil
                    customization.customButtons[index].trackpadSettings = nil
                    customization.customButtons[index].layout.shape = customization.customButtons[index].layout.shape ?? .roundedRectangle
                    customization.customButtons[index].layout.shadowStrength = 0
                } else if customization.customButtons[index].controlKind == .button {
                    customization.customButtons[index].joystickMapping = nil
                    customization.customButtons[index].joystickOutputSettings = nil
                    customization.customButtons[index].triggerSettings = nil
                    customization.customButtons[index].trackpadSettings = nil
                }
                try applyLayoutOptions(arguments, to: &customization.customButtons[index].layout)
            case .system(.topBarActivation):
                if arguments.contains("--clear-label") || optionValue("--label", in: arguments) != nil || optionValue("--maps-to", in: arguments) != nil || optionValue("--kind", in: arguments) != nil {
                    throw CLIError.message("The control bar hotspot only supports layout options")
                }
                try applyLayoutOptions(arguments, to: &customization.topBarActivationRegion)
            }

            if hasAnyOption(elementOutputOptionNames, in: arguments) {
                if case .custom(let id) = target,
                   customization.customButtons.first(where: { $0.id == id })?.normalized.isDecoration == true {
                    throw CLIError.message("Decoration elements do not send output")
                }
                try applyElementOutputOptions(arguments, target: target, to: &customization)
            }
        }
        print("Updated element \"\(targetText)\".")
    }

    private static func applyElementOutputOptions(_ arguments: [String], target: ElementTarget, to customization: inout GamepadCustomization) throws {
        let part = try parseElementInputPart(optionValue("--part", in: arguments) ?? optionValue("--input", in: arguments))
        let keyboardText = optionValue("--keyboard", in: arguments) ?? optionValue("--key", in: arguments)
        let sequenceText = optionValue("--sequence", in: arguments)
        let gamepadButtonText = optionValue("--gamepad-button", in: arguments) ?? optionValue("--gamepad", in: arguments)
        let clearOutput = arguments.contains("--clear-output")
        let clearKeyboard = arguments.contains("--clear-keyboard")
        let clearGamepad = arguments.contains("--clear-gamepad")

        var normalizedCustomization = customization.normalized
        let identity: GamepadControlIdentity = switch target {
        case .builtin(let button): .builtin(button)
        case .custom(let id): .custom(id)
        case .system:
            throw CLIError.message("The control bar hotspot does not send output")
        }
        guard let elementID = normalizedCustomization.elementID(for: identity),
              let index = normalizedCustomization.elements.firstIndex(where: { $0.id == elementID })
        else {
            throw CLIError.message("Element is not visible in this layout variant")
        }

        var output = normalizedCustomization.elements[index]
            .outputBinding(for: part)
            .map(MacControlOutputBinding.init(shared:)) ?? MacControlOutputBinding()
        if clearOutput {
            output = MacControlOutputBinding()
        }
        if clearKeyboard {
            output.keyboard = nil
        }
        if let sequenceText {
            output.keyboard = try parseKeyBindingSequence(sequenceText)
        } else if let keyboardText {
            output.keyboard = try parseKeyBindingSequence(keyboardText)
        }
        if clearGamepad {
            output.gamepadButtons.removeAll()
        }
        if let gamepadButtonText {
            let normalized = gamepadButtonText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized == "none" || normalized == "clear" || normalized == "off" {
                output.gamepadButtons.removeAll()
            } else {
                output.setGamepadButton(try parseVirtualGamepadButton(gamepadButtonText))
            }
        }

        normalizedCustomization.elements[index].setOutputBinding(output.isEmpty ? nil : output.sharedBinding, for: part)
        customization = normalizedCustomization.normalized
    }

    private static func parseElementInputPart(_ text: String?) throws -> KeypadElementInputPart {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .primary }
        let normalized = normalizedLookup(text)
        switch normalized {
        case "primary", "press", "button", "tap":
            return .primary
        case "up", "joystickup", "stickup":
            return .joystickUp
        case "down", "joystickdown", "stickdown":
            return .joystickDown
        case "left", "joystickleft", "stickleft":
            return .joystickLeft
        case "right", "joystickright", "stickright":
            return .joystickRight
        case "trigger", "triggerdigital", "digitaltrigger", "digital":
            return .triggerDigital
        default:
            if let part = KeypadElementInputPart(rawValue: text) { return part }
            throw CLIError.message("Unknown element output part: \(text)")
        }
    }

    private static func nudgeElement(arguments: [String]) throws {
        try requireExplicitUnmigratedProfileAccess(operation: "element nudge")
        let positional = positionals(in: arguments)
        guard let targetText = positional.first else {
            throw CLIError.message("Usage: thumble element nudge <element> <left|right|up|down> [--step 1|10]")
        }
        let directionText = positional.dropFirst().first
        let translation = try parseNudgeTranslation(arguments: arguments, directionText: directionText)
        let canvasSize = try parseNudgeCanvasSize(arguments)

        var store = loadStore()
        let profileIndex = try resolveProfileIndex(optionValue("--profile", in: arguments), in: store)
        let variant = try customizationVariant(in: arguments)
        let sourceCustomization = variant.map { store.profiles[profileIndex].customization(for: $0) } ?? store.profiles[profileIndex].customization
        let target = try resolveElementTarget(targetText, in: sourceCustomization)
        let identity: GamepadControlIdentity = switch target {
        case .builtin(let button): .builtin(button)
        case .custom(let id): .custom(id)
        case .system(let control): .system(control)
        }

        guard let nudgedCustomization = sourceCustomization.nudgedControls([identity], by: translation, in: canvasSize) else {
            print("Element \"\(targetText)\" could not move.")
            return
        }

        let normalizedNudgedCustomization = nudgedCustomization.normalized
        if let variant {
            store.profiles[profileIndex].setCustomization(normalizedNudgedCustomization, for: variant)
        } else {
            store.profiles[profileIndex].setCustomization(
                normalizedNudgedCustomization,
                for: normalizedNudgedCustomization.deviceCanvas.editorDeviceFrame.orientation
            )
        }
        store.profiles[profileIndex].updatedAt = Date.currentMilliseconds
        try persistStore(store)
        print("Nudged element \"\(targetText)\" by \(formatPixels(translation.width))px, \(formatPixels(translation.height))px.")
    }

    private static func deleteElement(arguments: [String]) throws {
        try requireExplicitUnmigratedProfileAccess(operation: "element delete")
        guard let targetText = firstPositional(in: arguments) else { throw CLIError.message("Missing element id, button, or label") }
        try mutateCustomization(profileTarget: optionValue("--profile", in: arguments), variant: try customizationVariant(in: arguments)) { customization in
            let target = try resolveElementTarget(targetText, in: customization)
            switch target {
            case .builtin(let button):
                var layout = customization.buttonCustomization(for: button)
                layout.isHidden = true
                customization.setButtonCustomization(layout, for: button)
            case .custom(let id):
                customization.removeCustomButton(id: id)
            case .system(.topBarActivation):
                customization.topBarActivationRegion.isHidden = true
            }
        }
        print("Deleted/hidden element \"\(targetText)\".")
    }

    private static func resetElement(arguments: [String]) throws {
        try requireExplicitUnmigratedProfileAccess(operation: "element reset")
        guard let targetText = firstPositional(in: arguments) else { throw CLIError.message("Missing element id, button, or label") }
        try mutateCustomization(profileTarget: optionValue("--profile", in: arguments), variant: try customizationVariant(in: arguments)) { customization in
            let identity = switch try resolveElementTarget(targetText, in: customization) {
            case .builtin(let button): GamepadControlIdentity.builtin(button)
            case .custom(let id): GamepadControlIdentity.custom(id)
            case .system(let control): GamepadControlIdentity.system(control)
            }
            try customization.resetControl(identity)
        }
        print("Reset element \"\(targetText)\".")
    }

    private static func applyLayoutOptions(_ arguments: [String], to layout: inout GamepadButtonCustomization) throws {
        if arguments.contains("--clear-hit-insets") || arguments.contains("--default-hit-insets") {
            layout.hitInsets = nil
        } else if let value = optionValue("--hit-insets", in: arguments) {
            layout.hitInsets = try parseHitInsets(value)
        } else if hasAnyOption(["--hit-top", "--hit-leading", "--hit-bottom", "--hit-trailing"], in: arguments) {
            var insets = layout.hitInsets ?? .runtimeDefault
            if let value = optionValue("--hit-top", in: arguments) { insets.top = try parsePixels(value) }
            if let value = optionValue("--hit-leading", in: arguments) { insets.leading = try parsePixels(value) }
            if let value = optionValue("--hit-bottom", in: arguments) { insets.bottom = try parsePixels(value) }
            if let value = optionValue("--hit-trailing", in: arguments) { insets.trailing = try parsePixels(value) }
            layout.hitInsets = insets.normalized
        }
        if let value = optionValue("--x", in: arguments) ?? optionValue("--center-x", in: arguments), let number = Double(value) { layout.centerX = CGFloat(number) }
        if let value = optionValue("--y", in: arguments) ?? optionValue("--center-y", in: arguments), let number = Double(value) { layout.centerY = CGFloat(number) }
        if let value = optionValue("--width", in: arguments) ?? optionValue("--width-scale", in: arguments), let number = Double(value) { layout.widthScale = CGFloat(number) }
        if let value = optionValue("--height", in: arguments) ?? optionValue("--height-scale", in: arguments), let number = Double(value) { layout.heightScale = CGFloat(number) }
        if arguments.contains("--show-integrated-label") { layout.showsIntegratedLabel = true }
        if arguments.contains("--hide-integrated-label") { layout.showsIntegratedLabel = false }
        if let value = optionValue("--integrated-label", in: arguments) {
            layout.showsIntegratedLabel = try parseBool(value)
        }
        if let value = optionValue("--z-index", in: arguments) ?? optionValue("--z", in: arguments) ?? optionValue("--zindex", in: arguments) {
            layout.zIndex = GamepadButtonCustomization.normalizedZIndex(try parseInteger(value))
        }
        if let value = optionValue("--shape", in: arguments), let shape = parseShapeStyleIfPresent(value) { layout.shape = shape }
        if let value = optionValue("--joystick-style", in: arguments) ?? optionValue("--stick-style", in: arguments) {
            layout.joystickVisualStyle = try parseJoystickVisualStyle(value)
        }
        if arguments.contains("--thumbstick") {
            layout.joystickVisualStyle = .thumbstick
        }
        if arguments.contains("--classic-joystick") || arguments.contains("--full-joystick") {
            layout.joystickVisualStyle = nil
        }
        if let value = optionValue("--accent", in: arguments), let accent = parseAccentStyleIfPresent(value) {
            layout.accentStyle = accent
            layout.fillColor = nil
            layout.lightFillColor = nil
            layout.darkFillColor = nil
            layout.fillStyle = nil
            layout.lightFillStyle = nil
            layout.darkFillStyle = nil
        }
        if let value = optionValue("--fill", in: arguments) ?? optionValue("--color", in: arguments) {
            layout.fillColor = try parseRGBAColor(value)
            layout.lightFillColor = nil
            layout.darkFillColor = nil
            layout.fillStyle = nil
            layout.lightFillStyle = nil
            layout.darkFillStyle = nil
        }
        if arguments.contains("--clear-fill") || arguments.contains("--clear-color") {
            layout.fillColor = nil
            layout.lightFillColor = nil
            layout.darkFillColor = nil
            layout.fillStyle = nil
            layout.lightFillStyle = nil
            layout.darkFillStyle = nil
        }
        if let value = optionValue("--fill-gradient", in: arguments) ?? optionValue("--gradient", in: arguments) {
            setLayoutFillStyle(try parseGradientFill(value, arguments: arguments), in: &layout)
        }
        if let value = optionValue("--fill-tile", in: arguments) ?? optionValue("--tile", in: arguments) {
            setLayoutFillStyle(try parseTileFill(value, arguments: arguments), in: &layout)
        }
        if let value = optionValue("--fill-image", in: arguments) ?? optionValue("--image", in: arguments) {
            setLayoutFillStyle(try parseImageFill(value, arguments: arguments), in: &layout)
        }
        if arguments.contains("--clear-fill-style") {
            layout.fillStyle = nil
            layout.lightFillStyle = nil
            layout.darkFillStyle = nil
        }
        if let value = optionValue("--light-fill", in: arguments) ?? optionValue("--fill-light", in: arguments) ?? optionValue("--light-color", in: arguments) {
            setLayoutFillColor(try parseRGBAColor(value), isDark: false, in: &layout)
        }
        if let value = optionValue("--dark-fill", in: arguments) ?? optionValue("--fill-dark", in: arguments) ?? optionValue("--dark-color", in: arguments) {
            setLayoutFillColor(try parseRGBAColor(value), isDark: true, in: &layout)
        }
        if let value = optionValue("--light-fill-gradient", in: arguments) ?? optionValue("--gradient-light", in: arguments) {
            setLayoutFillStyle(try parseGradientFill(value, arguments: arguments), isDark: false, in: &layout)
        }
        if let value = optionValue("--dark-fill-gradient", in: arguments) ?? optionValue("--gradient-dark", in: arguments) {
            setLayoutFillStyle(try parseGradientFill(value, arguments: arguments), isDark: true, in: &layout)
        }
        if let value = optionValue("--light-fill-tile", in: arguments) ?? optionValue("--tile-light", in: arguments) {
            setLayoutFillStyle(try parseTileFill(value, arguments: arguments), isDark: false, in: &layout)
        }
        if let value = optionValue("--dark-fill-tile", in: arguments) ?? optionValue("--tile-dark", in: arguments) {
            setLayoutFillStyle(try parseTileFill(value, arguments: arguments), isDark: true, in: &layout)
        }
        if arguments.contains("--clear-light-fill") || arguments.contains("--clear-light-color") {
            clearLayoutFillColor(isDark: false, in: &layout)
        }
        if arguments.contains("--clear-dark-fill") || arguments.contains("--clear-dark-color") {
            clearLayoutFillColor(isDark: true, in: &layout)
        }
        if let value = optionValue("--thumb-fill", in: arguments) ?? optionValue("--thumb-color", in: arguments) ?? optionValue("--joystick-thumb-fill", in: arguments) ?? optionValue("--joystick-knob-fill", in: arguments) {
            layout.joystickKnobColor = try parseRGBAColor(value)
            layout.lightJoystickKnobColor = nil
            layout.darkJoystickKnobColor = nil
        }
        if arguments.contains("--clear-thumb-fill") || arguments.contains("--clear-thumb-color") || arguments.contains("--clear-joystick-thumb-fill") || arguments.contains("--clear-joystick-knob-fill") {
            layout.joystickKnobColor = nil
            layout.lightJoystickKnobColor = nil
            layout.darkJoystickKnobColor = nil
        }
        if let value = optionValue("--light-thumb-fill", in: arguments) ?? optionValue("--thumb-light", in: arguments) ?? optionValue("--light-thumb-color", in: arguments) {
            setLayoutJoystickKnobColor(try parseRGBAColor(value), isDark: false, in: &layout)
        }
        if let value = optionValue("--dark-thumb-fill", in: arguments) ?? optionValue("--thumb-dark", in: arguments) ?? optionValue("--dark-thumb-color", in: arguments) {
            setLayoutJoystickKnobColor(try parseRGBAColor(value), isDark: true, in: &layout)
        }
        if arguments.contains("--clear-light-thumb-fill") || arguments.contains("--clear-light-thumb-color") {
            clearLayoutJoystickKnobColor(isDark: false, in: &layout)
        }
        if arguments.contains("--clear-dark-thumb-fill") || arguments.contains("--clear-dark-thumb-color") {
            clearLayoutJoystickKnobColor(isDark: true, in: &layout)
        }
        if let value = optionValue("--thumb-opacity", in: arguments), let opacity = parseOpacityIfPresent(value) {
            var color = layout.joystickKnobColor ?? .defaultValue
            color.alpha = opacity
            layout.joystickKnobColor = color
        }
        if let value = optionValue("--light-thumb-opacity", in: arguments), let opacity = parseOpacityIfPresent(value) {
            var color = layoutJoystickKnobColor(isDark: false, in: layout) ?? .defaultValue
            color.alpha = opacity
            setLayoutJoystickKnobColor(color, isDark: false, in: &layout)
        }
        if let value = optionValue("--dark-thumb-opacity", in: arguments), let opacity = parseOpacityIfPresent(value) {
            var color = layoutJoystickKnobColor(isDark: true, in: layout) ?? .defaultValue
            color.alpha = opacity
            setLayoutJoystickKnobColor(color, isDark: true, in: &layout)
        }
        if let value = optionValue("--opacity", in: arguments), let opacity = parseOpacityIfPresent(value) {
            var color = layout.fillColor ?? .defaultValue
            color.alpha = opacity
            layout.fillColor = color
        }
        if let value = optionValue("--light-opacity", in: arguments), let opacity = parseOpacityIfPresent(value) {
            var color = layoutFillColor(isDark: false, in: layout) ?? .defaultValue
            color.alpha = opacity
            setLayoutFillColor(color, isDark: false, in: &layout)
        }
        if let value = optionValue("--dark-opacity", in: arguments), let opacity = parseOpacityIfPresent(value) {
            var color = layoutFillColor(isDark: true, in: layout) ?? .defaultValue
            color.alpha = opacity
            setLayoutFillColor(color, isDark: true, in: &layout)
        }
        if let styleID = optionValue("--style", in: arguments) ?? optionValue("--style-id", in: arguments) {
            layout.styleID = styleID
        }
        if arguments.contains("--clear-style") || arguments.contains("--detach-style") {
            layout.styleID = nil
        }
        if let icon = try parseIconOption(arguments) {
            layout.icon = icon
        }
        if arguments.contains("--clear-icon") {
            layout.icon = nil
        }
        let existingHapticFeedback = layout.hapticFeedback ?? layout.hapticStyle.map { GamepadHapticFeedback(style: $0) }
        if let haptic = try parseHapticFeedbackOptions(arguments, existing: existingHapticFeedback) {
            setHapticFeedback(haptic, in: &layout)
        }
        if arguments.contains("--clear-haptic") {
            layout.hapticStyle = nil
            layout.hapticFeedback = nil
        }
        try applyRichVisualOptions(arguments, to: &layout)
        if let value = optionValue("--corner", in: arguments) ?? optionValue("--radius", in: arguments), let radius = Double(value) {
            layout.shape = .roundedRectangle
            layout.cornerRadius = CGFloat(radius)
            layout.cornerRadii = nil
        }
        var radii = layout.resolvedCornerRadii()
        var changedRadii = false
        for (option, corner) in [("--corner-tl", GamepadCorner.topLeading), ("--corner-tr", .topTrailing), ("--corner-br", .bottomTrailing), ("--corner-bl", .bottomLeading)] {
            if let value = optionValue(option, in: arguments), let radius = Double(value) {
                radii[corner] = CGFloat(radius)
                changedRadii = true
            }
        }
        if changedRadii {
            layout.shape = .roundedRectangle
            layout.cornerRadius = nil
            layout.cornerRadii = radii
        }
        if let value = optionValue("--shadow", in: arguments) ?? optionValue("--shadow-strength", in: arguments), let shadow = Double(value) { layout.shadowStrength = CGFloat(shadow) }
        if arguments.contains("--hide") || arguments.contains("--hidden") { layout.isHidden = true }
        if arguments.contains("--show") || arguments.contains("--visible") { layout.isHidden = false }
        if arguments.contains("--lock") || arguments.contains("--locked") { layout.isLocationLocked = true }
        if arguments.contains("--unlock") || arguments.contains("--unlocked") { layout.isLocationLocked = false }
    }

    private static func layoutFillColor(isDark: Bool, in layout: GamepadButtonCustomization) -> GamepadRGBAColor? {
        isDark ? (layout.darkFillColor ?? layout.fillColor) : (layout.lightFillColor ?? layout.fillColor)
    }

    private static func setLayoutFillColor(_ color: GamepadRGBAColor, isDark: Bool, in layout: inout GamepadButtonCustomization) {
        prepareSchemeSpecificFillStorage(in: &layout)
        if isDark {
            layout.darkFillColor = color.normalized
            layout.darkFillStyle = nil
        } else {
            layout.lightFillColor = color.normalized
            layout.lightFillStyle = nil
        }
    }

    private static func setLayoutFillStyle(_ style: GamepadFillStyle, in layout: inout GamepadButtonCustomization) {
        layout.fillStyle = style.normalized
        layout.fillColor = nil
        layout.lightFillColor = nil
        layout.darkFillColor = nil
        layout.lightFillStyle = nil
        layout.darkFillStyle = nil
    }

    private static func setLayoutFillStyle(_ style: GamepadFillStyle, isDark: Bool, in layout: inout GamepadButtonCustomization) {
        prepareSchemeSpecificFillStorage(in: &layout)
        if isDark {
            layout.darkFillStyle = style.normalized
            layout.darkFillColor = nil
        } else {
            layout.lightFillStyle = style.normalized
            layout.lightFillColor = nil
        }
    }

    private static func clearLayoutFillColor(isDark: Bool, in layout: inout GamepadButtonCustomization) {
        prepareSchemeSpecificFillStorage(in: &layout)
        if isDark {
            layout.darkFillColor = nil
            layout.darkFillStyle = nil
        } else {
            layout.lightFillColor = nil
            layout.lightFillStyle = nil
        }
    }

    private static func layoutJoystickKnobColor(isDark: Bool, in layout: GamepadButtonCustomization) -> GamepadRGBAColor? {
        isDark ? (layout.darkJoystickKnobColor ?? layout.joystickKnobColor) : (layout.lightJoystickKnobColor ?? layout.joystickKnobColor)
    }

    private static func setLayoutJoystickKnobColor(_ color: GamepadRGBAColor, isDark: Bool, in layout: inout GamepadButtonCustomization) {
        prepareSchemeSpecificJoystickKnobColorStorage(in: &layout)
        if isDark {
            layout.darkJoystickKnobColor = color.normalized
        } else {
            layout.lightJoystickKnobColor = color.normalized
        }
    }

    private static func clearLayoutJoystickKnobColor(isDark: Bool, in layout: inout GamepadButtonCustomization) {
        prepareSchemeSpecificJoystickKnobColorStorage(in: &layout)
        if isDark {
            layout.darkJoystickKnobColor = nil
        } else {
            layout.lightJoystickKnobColor = nil
        }
    }

    private static func prepareSchemeSpecificJoystickKnobColorStorage(in layout: inout GamepadButtonCustomization) {
        if let legacyColor = layout.joystickKnobColor?.normalized {
            if layout.lightJoystickKnobColor == nil {
                layout.lightJoystickKnobColor = legacyColor
            }
            if layout.darkJoystickKnobColor == nil {
                layout.darkJoystickKnobColor = legacyColor
            }
        }
        layout.joystickKnobColor = nil
    }

    private static func prepareSchemeSpecificFillStorage(in layout: inout GamepadButtonCustomization) {
        if let legacyFillColor = layout.fillColor?.normalized {
            if layout.lightFillColor == nil {
                layout.lightFillColor = legacyFillColor
            }
            if layout.darkFillColor == nil {
                layout.darkFillColor = legacyFillColor
            }
        }
        if let legacyFillStyle = layout.fillStyle?.normalized {
            if layout.lightFillStyle == nil {
                layout.lightFillStyle = legacyFillStyle
            }
            if layout.darkFillStyle == nil {
                layout.darkFillStyle = legacyFillStyle
            }
        }
        layout.fillColor = nil
        layout.fillStyle = nil
    }

    private static func setBackgroundFillColor(_ color: GamepadRGBAColor, in customization: inout GamepadCustomization) {
        customization.backgroundLightColor = color.normalized
        customization.backgroundDarkColor = color.normalized
        customization.backgroundFillStyle = nil
        customization.backgroundLightFillStyle = nil
        customization.backgroundDarkFillStyle = nil
    }

    private static func setBackgroundFillColor(_ color: GamepadRGBAColor, isDark: Bool, in customization: inout GamepadCustomization) {
        customization.prepareSchemeSpecificBackgroundFillStorage()
        if isDark {
            customization.backgroundDarkColor = color.normalized
            customization.backgroundDarkFillStyle = nil
        } else {
            customization.backgroundLightColor = color.normalized
            customization.backgroundLightFillStyle = nil
        }
    }

    private static func setBackgroundFillStyle(_ style: GamepadFillStyle, in customization: inout GamepadCustomization) {
        customization.backgroundFillStyle = style.normalized
        customization.backgroundLightColor = nil
        customization.backgroundDarkColor = nil
        customization.backgroundLightFillStyle = nil
        customization.backgroundDarkFillStyle = nil
    }

    private static func setBackgroundFillStyle(_ style: GamepadFillStyle, isDark: Bool, in customization: inout GamepadCustomization) {
        customization.prepareSchemeSpecificBackgroundFillStorage()
        if isDark {
            customization.backgroundDarkFillStyle = style.normalized
            customization.backgroundDarkColor = nil
        } else {
            customization.backgroundLightFillStyle = style.normalized
            customization.backgroundLightColor = nil
        }
    }

    private static func clearBackgroundFill(in customization: inout GamepadCustomization) {
        customization.backgroundLightColor = nil
        customization.backgroundDarkColor = nil
        customization.backgroundFillStyle = nil
        customization.backgroundLightFillStyle = nil
        customization.backgroundDarkFillStyle = nil
    }

    // MARK: - Runtime commands

    private static func server(arguments: [String]) throws {
        guard let subcommand = arguments.first else { throw CLIError.message("Missing server subcommand") }
        switch subcommand {
        case "start":
            try openApp()
            postRuntimeCommand(.start)
            print("Requested server start.")
        case "stop":
            postRuntimeCommand(.stop)
            print("Requested server stop.")
        case "restart":
            try openApp()
            postRuntimeCommand(.restart)
            print("Requested server restart.")
        case "status":
            try printRuntimeStatus(json: arguments.contains("--json"))
        case "addresses", "urls":
            let status = try readFreshRuntimeStatus()
            for url in status.localURLs { print(url) }
        default:
            throw CLIError.message("Unknown server subcommand: \(subcommand)")
        }
    }

    private static func pairing(arguments: [String]) throws {
        guard let subcommand = arguments.first else { throw CLIError.message("Missing pairing subcommand") }
        switch subcommand {
        case "code":
            print(try readFreshRuntimeStatus().pairingCode)
        case "payload":
            let status = try readFreshRuntimeStatus()
            let payload = PairingPayload(
                urls: status.localURLs,
                pairingCode: status.pairingCode,
                serviceName: status.bonjourServiceName,
                serviceType: status.bonjourServiceType,
                serviceDomain: status.bonjourServiceDomain,
                serverID: status.serverID
            )
            try printJSON(payload)
        case "cancel":
            postRuntimeCommand(.cancelPairing)
            print("Requested pairing cancel.")
        default:
            throw CLIError.message("Unknown pairing subcommand: \(subcommand)")
        }
    }

    private static func accessibility(arguments: [String]) throws {
        guard let subcommand = arguments.first else { throw CLIError.message("Missing accessibility subcommand") }
        switch subcommand {
        case "status":
            postRuntimeCommand(.refreshAccessibility)
            let status = try readFreshRuntimeStatus()
            print(status.accessibilityTrusted ? "granted" : "required")
        case "prompt", "request":
            postRuntimeCommand(.promptAccessibility)
            print("Requested Accessibility permission prompt.")
        case "open", "settings":
            postRuntimeCommand(.openAccessibilitySettings)
            print("Opened Accessibility settings.")
        case "refresh":
            postRuntimeCommand(.refreshAccessibility)
            print("Requested Accessibility status refresh.")
        default:
            throw CLIError.message("Unknown accessibility subcommand: \(subcommand)")
        }
    }

    private static func test(arguments: [String]) throws {
        guard let subcommand = arguments.first else { throw CLIError.message("Missing test subcommand") }
        let rest = Array(arguments.dropFirst())
        let elementInput = try optionValue("--element", in: rest).map(parseElementInput)
        switch subcommand {
        case "down":
            if let elementInput {
                postRuntimeCommand(.testDown, elementInput: elementInput)
                print("Sent element test down for \(elementInput.storageKey).")
            } else {
                let button = try parseButton(firstPositional(in: rest) ?? "jump")
                postRuntimeCommand(.testDown, button: button)
                print("Sent test down for \(button.displayName).")
            }
        case "up":
            if let elementInput {
                postRuntimeCommand(.testUp, elementInput: elementInput)
                print("Sent element test up for \(elementInput.storageKey).")
            } else {
                let button = try parseButton(firstPositional(in: rest) ?? "jump")
                postRuntimeCommand(.testUp, button: button)
                print("Sent test up for \(button.displayName).")
            }
        case "tap":
            let holdMS = Int(optionValue("--hold-ms", in: rest) ?? "120") ?? 120
            if let elementInput {
                postRuntimeCommand(.testDown, elementInput: elementInput)
                Thread.sleep(forTimeInterval: Double(min(max(holdMS, 0), 5_000)) / 1000.0)
                postRuntimeCommand(.testUp, elementInput: elementInput)
                print("Tapped element \(elementInput.storageKey).")
            } else {
                let button = try parseButton(firstPositional(in: rest) ?? "jump")
                postRuntimeCommand(.testDown, button: button)
                Thread.sleep(forTimeInterval: Double(min(max(holdMS, 0), 5_000)) / 1000.0)
                postRuntimeCommand(.testUp, button: button)
                print("Tapped \(button.displayName).")
            }
        default:
            throw CLIError.message("Unknown test subcommand: \(subcommand)")
        }
    }

    private static func latency(arguments: [String]) throws {
        if arguments.first == "verify" {
            try verifyLatency(arguments: Array(arguments.dropFirst()))
            return
        }

        let rest = arguments.first == "simulate" ? Array(arguments.dropFirst()) : arguments
        let options = try parseLatencyOptions(rest)
        let modes: [ThumbleLatencySimulationMode]
        if let mode = options.mode {
            modes = [mode]
        } else {
            modes = [.current, .legacyMainActor]
        }
        let reports = modes.map {
            ThumbleInputLatencySimulator.run(pattern: options.pattern, mode: $0)
        }

        if let logPath = options.logPath {
            try writeJSON(reports, to: logPath)
        }

        if options.printJSON {
            try printJSON(reports)
        } else {
            printLatencyReports(reports, logPath: options.logPath)
        }
    }

    private static func verifyLatency(arguments: [String]) throws {
        let options = try parseLatencyVerificationOptions(arguments)
        let report = ThumbleInputLatencySimulator.verifyCurrentPath(
            maxAllowedMilliseconds: options.maxAllowedMilliseconds,
            p95AllowedMilliseconds: options.p95AllowedMilliseconds
        )

        if let logPath = options.logPath {
            try writeJSON(report, to: logPath)
        }

        if options.printJSON {
            try printJSON(report)
        } else {
            printLatencyVerificationReport(report, logPath: options.logPath)
        }

        guard report.passed else {
            throw CLIError.message("Latency verification failed")
        }
    }

    private struct LatencyOptions {
        var pattern: ThumbleLatencySimulationPattern = .hollowKnight
        var mode: ThumbleLatencySimulationMode?
        var printJSON = false
        var logPath: String?
    }

    private struct LatencyVerificationOptions {
        var maxAllowedMilliseconds = 4.0
        var p95AllowedMilliseconds = 4.0
        var printJSON = false
        var logPath: String?
    }

    private static func parseLatencyOptions(_ arguments: [String]) throws -> LatencyOptions {
        var options = LatencyOptions()
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--json":
                options.printJSON = true

            case "--pattern":
                index += 1
                guard index < arguments.count else { throw CLIError.message("Missing value for --pattern") }
                guard let pattern = ThumbleLatencySimulationPattern(rawValue: arguments[index]) else {
                    throw CLIError.message("Unsupported latency pattern: \(arguments[index])")
                }
                options.pattern = pattern

            case "--mode":
                index += 1
                guard index < arguments.count else { throw CLIError.message("Missing value for --mode") }
                let value = arguments[index]
                if value == "compare" {
                    options.mode = nil
                } else if let mode = ThumbleLatencySimulationMode(rawValue: value) {
                    options.mode = mode
                } else {
                    throw CLIError.message("Unsupported latency mode: \(value)")
                }

            case "--log":
                index += 1
                guard index < arguments.count else { throw CLIError.message("Missing value for --log") }
                options.logPath = arguments[index]

            case "--help", "-h", "help":
                throw CLIError.message("Usage: thumble latency simulate [--pattern hollow-knight|same-button-burst|udp-recovery|udp-recovery-burst|held-direction-heartbeat-recovery] [--mode current|legacy-main-actor|compare] [--json] [--log file.json]")

            default:
                throw CLIError.message("Unknown latency option: \(argument)")
            }

            index += 1
        }

        return options
    }

    private static func parseLatencyVerificationOptions(_ arguments: [String]) throws -> LatencyVerificationOptions {
        var options = LatencyVerificationOptions()
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--json":
                options.printJSON = true

            case "--max-ms":
                index += 1
                guard index < arguments.count,
                      let value = Double(arguments[index])
                else {
                    throw CLIError.message("Missing numeric value for --max-ms")
                }
                options.maxAllowedMilliseconds = value

            case "--p95-ms":
                index += 1
                guard index < arguments.count,
                      let value = Double(arguments[index])
                else {
                    throw CLIError.message("Missing numeric value for --p95-ms")
                }
                options.p95AllowedMilliseconds = value

            case "--log":
                index += 1
                guard index < arguments.count else { throw CLIError.message("Missing value for --log") }
                options.logPath = arguments[index]

            case "--help", "-h", "help":
                throw CLIError.message("Usage: thumble latency verify [--max-ms 4] [--p95-ms 4] [--json] [--log file.json]")

            default:
                throw CLIError.message("Unknown latency verify option: \(argument)")
            }

            index += 1
        }

        return options
    }

    private static func printLatencyVerificationReport(
        _ report: ThumbleLatencyVerificationReport,
        logPath: String?
    ) {
        print(report.passed ? "Synthetic latency-model verification passed" : "Synthetic latency-model verification failed")
        print("Budget: max <= \(formatMilliseconds(report.maxAllowedMilliseconds)) ms, p95 <= \(formatMilliseconds(report.p95AllowedMilliseconds)) ms")

        for simulation in report.reports {
            let summary = simulation.summary
            print(
                "- \(simulation.pattern.rawValue): p95 \(formatMilliseconds(summary.p95Milliseconds)) ms, " +
                "max \(formatMilliseconds(summary.maxMilliseconds)) ms, over16 \(summary.overSixteenMilliseconds), " +
                "heartbeat re-sync \(simulation.heartbeatResyncFrames)"
            )
        }

        if !report.failures.isEmpty {
            print("Failures:")
            for failure in report.failures {
                print("- \(failure)")
            }
        }

        if let logPath {
            print("Wrote detailed report: \(logPath)")
        }
    }

    private static func printLatencyReports(
        _ reports: [ThumbleLatencySimulationReport],
        logPath: String?
    ) {
        guard let first = reports.first else { return }
        print("Synthetic latency model: \(first.pattern.displayName)")
        print("Pattern: \(first.pattern.rawValue)")

        for report in reports {
            let summary = report.summary
            print("")
            print(report.mode.displayName)
            print("  p50: \(formatMilliseconds(summary.p50Milliseconds)) ms")
            print("  p95: \(formatMilliseconds(summary.p95Milliseconds)) ms")
            print("  max: \(formatMilliseconds(summary.maxMilliseconds)) ms")
            print("  over 8 ms: \(summary.overEightMilliseconds)/\(summary.sampleCount)")
            print("  over 16 ms: \(summary.overSixteenMilliseconds)/\(summary.sampleCount)")
            print("  recovered by TCP mirror: \(report.recoveredByMirrorFrames)")
            print("  buffered frames: \(report.bufferedFrames)")
            print("  heartbeat re-sync frames: \(report.heartbeatResyncFrames)")

            let worstSamples = report.samples
                .filter { $0.latencyMilliseconds != nil }
                .sorted { ($0.latencyMilliseconds ?? 0) > ($1.latencyMilliseconds ?? 0) }
                .prefix(3)
            for sample in worstSamples {
                print(
                    "  worst seq \(sample.sequenceNumber): \(sample.button.rawValue) \(sample.state.rawValue) " +
                    "\(formatMilliseconds(sample.latencyMilliseconds ?? 0)) ms via \(sample.source ?? "unknown")"
                )
            }
        }

        if reports.count == 2,
           let current = reports.first(where: { $0.mode == .current }),
           let legacy = reports.first(where: { $0.mode == .legacyMainActor })
        {
            let delta = legacy.summary.p95Milliseconds - current.summary.p95Milliseconds
            print("")
            print("p95 improvement vs legacy model: \(formatMilliseconds(delta)) ms")
        }

        if let logPath {
            print("")
            print("Wrote detailed report: \(logPath)")
        }
    }

    private static func formatMilliseconds(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private static func app(arguments: [String]) throws {
        guard let subcommand = arguments.first else { throw CLIError.message("Missing app subcommand") }
        let rest = Array(arguments.dropFirst())
        switch subcommand {
        case "open", "launch":
            try openApp()
            print("Opened Thumble Mac.")
        case "quit":
            try quitApp()
            print("Requested Thumble Mac quit.")
        case "screenshot", "capture-window":
            try captureAppScreenshot(arguments: rest)
        case "replay-onboarding", "onboarding", "reset-onboarding":
            try replayOnboarding()
            print("Reset onboarding and opened Thumble Mac.")
        default:
            throw CLIError.message("Unknown app subcommand: \(subcommand)")
        }
    }

    private static func captureAppScreenshot(arguments: [String]) throws {
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: appDefaultsDomain)
            .filter { !$0.isTerminated }
        guard !runningApps.isEmpty else {
            throw CLIError.message("Thumble Mac is not running. Ask the user to open it, or run `thumble app open` only with their permission, then retry.")
        }
        guard CGPreflightScreenCaptureAccess() else {
            throw CLIError.message(
                "Screen Recording access is not available. Grant it to the terminal or agent host in System Settings > Privacy & Security > Screen & System Audio Recording, then retry. This command does not activate Thumble or send input events."
            )
        }

        let requestedTitle = optionValue("--window-title", in: arguments)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let processIDs = Set(runningApps.map(\.processIdentifier))
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            throw CLIError.message("Could not enumerate Thumble Mac windows.")
        }

        let windows = windowInfo.compactMap { info -> AppWindowDescriptor? in
            guard
                let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                processIDs.contains(ownerPID),
                (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                ((info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0,
                let windowNumber = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                let frame = CGRect(dictionaryRepresentation: boundsDictionary)
            else { return nil }
            guard frame.width >= 160, frame.height >= 120 else { return nil }
            let title = (info[kCGWindowName as String] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return AppWindowDescriptor(
                id: windowNumber,
                title: title?.isEmpty == false ? title : nil,
                frame: frame
            )
        }

        let matchingWindows: [AppWindowDescriptor]
        if let requestedTitle, !requestedTitle.isEmpty {
            matchingWindows = windows.filter {
                $0.title?.range(of: requestedTitle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        } else {
            matchingWindows = windows
        }
        guard let target = matchingWindows.max(by: { lhs, rhs in
            lhs.frame.width * lhs.frame.height < rhs.frame.width * rhs.frame.height
        }) else {
            if let requestedTitle, !requestedTitle.isEmpty {
                let availableTitles = windows.compactMap(\.title).sorted().joined(separator: ", ")
                let suffix = availableTitles.isEmpty ? "" : " Available window titles: \(availableTitles)."
                throw CLIError.message("No visible Thumble Mac window matched \"\(requestedTitle)\".\(suffix)")
            }
            throw CLIError.message("No visible Thumble Mac window was found. Restore its window and retry.")
        }

        let rawOutputPath = optionValue("--output", in: arguments)
            ?? optionValue("-o", in: arguments)
            ?? "thumble-app-screenshot.png"
        let expandedOutputPath = (rawOutputPath as NSString).expandingTildeInPath
        let outputURL = URL(fileURLWithPath: expandedOutputPath).standardizedFileURL
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try runProcess(
            "/usr/sbin/screencapture",
            arguments: ["-x", "-o", "-t", "png", "-l", String(target.id), outputURL.path]
        )

        guard
            let imageData = try? Data(contentsOf: outputURL),
            !imageData.isEmpty,
            let representation = NSBitmapImageRep(data: imageData)
        else {
            throw CLIError.message("Thumble window capture did not produce a readable PNG at \(outputURL.path).")
        }

        let result = AppScreenshotResult(
            bundleIdentifier: appDefaultsDomain,
            path: outputURL.path,
            pixelWidth: representation.pixelsWide,
            pixelHeight: representation.pixelsHigh,
            windowID: target.id,
            windowTitle: target.title
        )
        if arguments.contains("--json") {
            try printJSON(result)
        } else {
            let title = target.title.map { " \"\($0)\"" } ?? ""
            print("Captured Thumble Mac\(title) to \(outputURL.path) (\(result.pixelWidth)x\(result.pixelHeight)).")
        }
    }

    private static func monitor(arguments: [String]) throws {
        let options = try parseMonitorOptions(arguments)
        let logPath: String
        if let pathOverride = options.pathOverride {
            logPath = pathOverride
        } else if let status = try? readFreshRuntimeStatus(), let path = status.captureLogPath, !path.isEmpty {
            logPath = path
        } else if FileManager.default.fileExists(atPath: ThumbleMacIPC.captureLogPath) {
            logPath = ThumbleMacIPC.captureLogPath
        } else if FileManager.default.fileExists(atPath: ThumbleMacIPC.legacyThumbConsoleCaptureLogPath) {
            logPath = ThumbleMacIPC.legacyThumbConsoleCaptureLogPath
        } else if FileManager.default.fileExists(atPath: ThumbleMacIPC.legacyThumbleCaptureLogPath) {
            logPath = ThumbleMacIPC.legacyThumbleCaptureLogPath
        } else {
            logPath = ThumbleMacIPC.captureLogPath
        }

        if options.printPath {
            print(logPath)
            return
        }

        let url = URL(fileURLWithPath: logPath)
        if options.clear {
            try? FileManager.default.removeItem(at: url)
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }

        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }

        var offset = options.fromStart ? UInt64(0) : fileSize(at: url)
        var pending = Data()
        let startedAt = Date()

        if !options.jsonLines {
            fputs("Streaming Thumble capture from \(logPath)\n", stderr)
            fputs("Press Ctrl-C to stop. Use --jsonl for raw JSON lines.\n", stderr)
        }

        while true {
            if let duration = options.duration, Date().timeIntervalSince(startedAt) >= duration {
                break
            }

            let currentSize = fileSize(at: url)
            if currentSize < offset {
                offset = 0
                pending.removeAll(keepingCapacity: true)
            }

            if currentSize > offset {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                try handle.seek(toOffset: offset)
                let chunk = try handle.readToEnd() ?? Data()
                offset += UInt64(chunk.count)
                pending.append(chunk)
                try printCompleteCaptureLines(from: &pending, jsonLines: options.jsonLines)
            }

            if !options.follow {
                break
            }
            Thread.sleep(forTimeInterval: options.pollInterval)
        }
    }

    private static func parseMonitorOptions(_ arguments: [String]) throws -> MonitorOptions {
        var options = MonitorOptions()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--jsonl", "--json-lines", "--json":
                options.jsonLines = true
            case "--clear", "--reset":
                options.clear = true
                options.fromStart = true
            case "--from-start", "--all":
                options.fromStart = true
            case "--no-follow", "--snapshot":
                options.follow = false
                options.fromStart = true
            case "--path":
                options.printPath = true
            case "--file", "--log":
                index += 1
                guard index < arguments.count else { throw CLIError.message("Missing value for \(argument)") }
                options.pathOverride = arguments[index]
            case "--duration", "--seconds":
                index += 1
                guard index < arguments.count, let value = TimeInterval(arguments[index]), value >= 0 else {
                    throw CLIError.message("Missing or invalid value for \(argument)")
                }
                options.duration = value
            case "--interval":
                index += 1
                guard index < arguments.count, let value = TimeInterval(arguments[index]), value > 0 else {
                    throw CLIError.message("Missing or invalid value for --interval")
                }
                options.pollInterval = value
            case "--help", "-h":
                throw CLIError.message("Usage: thumble monitor [--jsonl] [--clear] [--from-start] [--duration seconds] [--file capture.jsonl] [--path]")
            default:
                throw CLIError.message("Unknown monitor option: \(argument)")
            }
            index += 1
        }
        return options
    }

    private static func fileSize(at url: URL) -> UInt64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber
        else { return 0 }
        return size.uint64Value
    }

    private static func printCompleteCaptureLines(from pending: inout Data, jsonLines: Bool) throws {
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[..<newline]
            pending.removeSubrange(pending.startIndex...newline)
            guard !line.isEmpty else { continue }
            if jsonLines {
                if let text = String(data: line, encoding: .utf8) {
                    print(text)
                }
            } else {
                let event = try JSONDecoder().decode(ThumbleCaptureEvent.self, from: Data(line))
                print(formatCaptureEvent(event))
            }
            fflush(stdout)
        }
    }

    private static func formatCaptureEvent(_ event: ThumbleCaptureEvent) -> String {
        let sequence = event.sequence.map { "#\($0)" } ?? "#?"
        let timestamp = formatCaptureTimestamp(event.recordedAt)
        let latency = event.latencyMS.map { " latency=\($0)ms" } ?? ""
        let pressed = formatCapturePressed(event.pressedButtons)
        let detail = event.detail.map { " detail=\($0)" } ?? ""

        switch event.kind {
        case "button":
            let button = event.button?.rawValue ?? "?"
            let state = event.state?.rawValue ?? "?"
            let binding = event.binding.map { " binding=\($0)" } ?? ""
            return "\(timestamp) \(sequence) button \(button) \(state)\(binding)\(latency)\(pressed)\(detail)"
        case "element_input":
            let label = event.elementLabel ?? event.elementInput?.storageKey ?? "?"
            let state = event.state?.rawValue ?? "?"
            let binding = event.binding.map { " binding=\($0)" } ?? ""
            return "\(timestamp) \(sequence) element \(label) \(state)\(binding)\(latency)\(pressed)\(detail)"
        case "gamepad_analog":
            if let stick = event.analogStick {
                return "\(timestamp) \(sequence) analog stick=\(stick.rawValue) x=\(formatDouble(event.analogX)) y=\(formatDouble(event.analogY))\(latency)\(pressed)\(detail)"
            }
            if let trigger = event.analogTrigger {
                return "\(timestamp) \(sequence) analog trigger=\(trigger.rawValue) value=\(formatDouble(event.analogValue))\(latency)\(pressed)\(detail)"
            }
            return "\(timestamp) \(sequence) analog\(latency)\(pressed)\(detail)"
        case "pointer":
            let pointerEvent = event.pointerEvent?.rawValue ?? "?"
            let button = event.pointerButton.map { " button=\($0.rawValue)" } ?? ""
            let state = event.state.map { " state=\($0.rawValue)" } ?? ""
            let dx = event.deltaX.map { " dx=\(String(format: "%.2f", $0))" } ?? ""
            let dy = event.deltaY.map { " dy=\(String(format: "%.2f", $0))" } ?? ""
            return "\(timestamp) \(sequence) pointer \(pointerEvent)\(button)\(state)\(dx)\(dy)\(latency)\(pressed)\(detail)"
        case "input_pipeline":
            let type = event.messageType?.rawValue ?? "?"
            let generation = event.inputGeneration.map { " generation=\($0)" } ?? ""
            let inputSequence = event.inputSequence.map { " input=#\($0)" } ?? ""
            let decode = event.decodeLatencyMS.map { " decode=\(String(format: "%.3f", $0))ms" } ?? ""
            let reorder = event.reorderWaitMS.map { " reorder=\(String(format: "%.3f", $0))ms" } ?? ""
            let processing = event.processingToCompletionMS.map { " processing=\(String(format: "%.3f", $0))ms" } ?? ""
            let lookup = event.bindingLookupMS.map { " lookup=\(String(format: "%.3f", $0))ms" } ?? ""
            let injection = event.outputInjectionMS.map { " injection=\(String(format: "%.3f", $0))ms" } ?? ""
            let postInjection = event.postInjectionMS.map { " post-injection=\(String(format: "%.3f", $0))ms" } ?? ""
            let deferred = event.outputDeferred.map { " output-deferred=\($0 ? "yes" : "no")" } ?? ""
            let pipeline = event.receiveToProcessedMS.map { " receive-to-processed=\(String(format: "%.3f", $0))ms" } ?? ""
            return "\(timestamp) \(sequence) input_pipeline type=\(type)\(generation)\(inputSequence)\(decode)\(reorder)\(processing)\(lookup)\(injection)\(postInjection)\(deferred)\(pipeline)\(detail)"
        case "ignored_button_edge", "recovered_button_edge":
            let button = event.button?.rawValue ?? "?"
            let state = event.state?.rawValue ?? "?"
            return "\(timestamp) \(sequence) \(event.kind) \(button) \(state)\(latency)\(pressed)\(detail)"
        case "ignored_element_input_edge":
            let label = event.elementLabel ?? event.elementInput?.storageKey ?? "?"
            let state = event.state?.rawValue ?? "?"
            return "\(timestamp) \(sequence) \(event.kind) \(label) \(state)\(latency)\(pressed)\(detail)"
        default:
            return "\(timestamp) \(sequence) \(event.kind)\(latency)\(pressed)\(detail)"
        }
    }

    private static func formatCaptureTimestamp(_ milliseconds: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func formatCapturePressed(_ buttons: [GameButton]?) -> String {
        guard let buttons else { return "" }
        if buttons.isEmpty { return " pressed=[]" }
        return " pressed=[\(buttons.map(\.rawValue).joined(separator: ","))]"
    }

    private static func formatDouble(_ value: Double?) -> String {
        String(format: "%.3f", value ?? 0)
    }

    private static func postRuntimeCommand(
        _ command: ThumbleMacCLICommand,
        button: GameButton? = nil,
        elementInput: KeypadElementInputID? = nil,
        reason: String? = nil
    ) {
        let payload = ThumbleMacCLICommandPayload(
            command: command,
            button: button,
            elementInput: elementInput,
            reason: reason
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(ThumbleMacIPC.commandNotificationName),
            object: nil,
            userInfo: [ThumbleMacIPC.commandDataKey: data],
            deliverImmediately: true
        )
    }

    private static func readFreshRuntimeStatus() throws -> ThumbleMacRuntimeStatus {
        postRuntimeCommand(.publishStatus)
        Thread.sleep(forTimeInterval: 0.12)
        guard let data = dataValue(loadAppDomain()[ThumbleMacIPC.runtimeStatusDefaultsKey]),
              let status = try? JSONDecoder().decode(ThumbleMacRuntimeStatus.self, from: data)
        else {
            throw CLIError.message("No runtime status found. Open Thumble Mac first with `thumble app open`.")
        }
        return status
    }

    private static func printRuntimeStatus(json: Bool) throws {
        let status = try readFreshRuntimeStatus()
        if json {
            try printJSON(status)
        } else {
            print("Status: \(status.statusText)")
            print("Running: \(status.isRunning ? "yes" : "no")")
            print("Client: \(status.clientName)\(status.isClientConnected ? " (connected)" : "")")
            if let clientDeviceInfo = status.clientDeviceInfo {
                if let frame = GamepadEditorDeviceCatalog.suggestedFrame(for: clientDeviceInfo) {
                    print("Client Device: \(frame.spec.displayName) (\(formatSize(frame.screenRect.size)) pt \(frame.orientation.rawValue))")
                } else {
                    let model = clientDeviceInfo.modelIdentifier.map { " \($0)" } ?? ""
                    print("Client Device: \(clientDeviceInfo.deviceName)\(model)")
                }
            }
            print("Port: \(status.port)")
            print("Pairing Code: \(status.pairingCode)")
            print("Accessibility: \(status.accessibilityTrusted ? "granted" : "required")")
            if let preference = status.activeGamepadProfileOrientationPreference {
                print("iPhone Rotation: \(preference.rawValue)")
            }
            if let serviceName = status.bonjourServiceName, !serviceName.isEmpty {
                let serviceType = status.bonjourServiceType ?? PairingPayload.defaultServiceType
                print("Nearby Service: \(serviceName) (\(serviceType))")
            }
            if !status.localURLs.isEmpty {
                print("Addresses:")
                for url in status.localURLs { print("- \(url)") }
            }
            print("Last Event: \(status.lastReceivedEvent)")
            if let roundTripLatencyMS = status.roundTripLatencyMS ?? status.estimatedLatencyMS {
                print("Round-trip Latency: \(roundTripLatencyMS) ms")
            }
            if let p50 = status.inputPipelineP50MS,
               let p95 = status.inputPipelineP95MS,
               let p99 = status.inputPipelineP99MS {
                print(String(format: "Mac Input Pipeline: p50 %.3f ms, p95 %.3f ms, p99 %.3f ms", p50, p95, p99))
            }
            if let processingP95 = status.inputProcessingP95MS {
                print(String(format: "Mac Input Processing: p95 %.3f ms", processingP95))
            }
            if let lookupP95 = status.bindingLookupP95MS {
                print(String(format: "Binding Lookup: p95 %.3f ms", lookupP95))
            }
            if let injectionP50 = status.outputInjectionP50MS,
               let injectionP95 = status.outputInjectionP95MS,
               let injectionP99 = status.outputInjectionP99MS {
                print(String(format: "Output Injection: p50 %.3f ms, p95 %.3f ms, p99 %.3f ms", injectionP50, injectionP95, injectionP99))
            }
            if let postInjectionP95 = status.postInjectionP95MS {
                print(String(format: "Post-injection Processing: p95 %.3f ms", postInjectionP95))
            }
            if let protocolVersion = status.inputProtocolVersion {
                let generation = status.activeInputGeneration.map(String.init) ?? "legacy"
                print("Input Protocol: v\(protocolVersion), generation \(generation), stale drops \(status.staleInputGenerationDrops ?? 0)")
            }
            print("Pressed: \(status.pressedButtons.map(\.rawValue).sorted().joined(separator: ", "))")
            if let pressedElementInputs = status.pressedElementInputs {
                print("Pressed Elements: \(pressedElementInputs.map(\.storageKey).sorted().joined(separator: ", "))")
            }
            if let deliveryState = status.editorDeliveryState {
                let detail = status.editorDeliveryDetail.map { " — \($0)" } ?? ""
                print("Editor Delivery: \(deliveryState.rawValue)\(detail)")
            }
            if status.virtualGamepadActive != nil || status.virtualGamepadAvailable != nil || status.virtualGamepadLastError != nil {
                let active = status.virtualGamepadActive == true ? "active" : "inactive"
                let availability = status.virtualGamepadAvailable == false ? "unavailable" : "available"
                print("Virtual Gamepad: \(active), \(availability)")
                if let error = status.virtualGamepadLastError, !error.isEmpty {
                    print("Virtual Gamepad Error: \(error)")
                }
                if let pressed = status.virtualGamepadPressedButtons, !pressed.isEmpty {
                    print("Virtual Gamepad Pressed: \(pressed.map(\.shortName).joined(separator: ", "))")
                }
            }
            if let captureLogPath = status.captureLogPath, !captureLogPath.isEmpty {
                print("Capture Log: \(captureLogPath)")
            }
            print("Frames: missing=\(status.missedButtonFrames) ignored=\(status.ignoredButtonEdges) recovered=\(status.recoveredButtonEdges)")
        }
    }

    // MARK: - Persistence

    private static func loadStore() -> ProfileStore {
        let domain = loadAppDomain()
        let state = loadProfileState(from: domain)
        var profileBindings = loadProfileBindings(from: domain)
        if profileBindings[state.activeProfileID.uuidString] == nil {
            profileBindings[state.activeProfileID.uuidString] = rawBindings(loadActiveKeyBindings(from: domain))
        }
        var profileOutputBindings = loadProfileOutputBindings(from: domain, fallbackProfileKeyBindings: profileBindings)
        if profileOutputBindings[state.activeProfileID.uuidString] == nil {
            let activeBindings = decodedBindings(profileBindings[state.activeProfileID.uuidString]) ?? DefaultKeypadKeyMap.defaultBindings
            let activeProfile = state.activeProfile ?? state.profiles[0]
            profileOutputBindings[state.activeProfileID.uuidString] = rawOutputBindings(
                effectiveOutputBindings(
                    for: activeProfile.outputMode,
                    keyBindings: activeBindings,
                    customOutputBindings: outputBindings(from: activeBindings)
                )
            )
        }
        return ProfileStore(
            profiles: state.profiles,
            activeProfileID: state.activeProfileID,
            defaultProfileID: state.defaultProfileID,
            profileKeyBindings: profileBindings,
            profileOutputBindings: profileOutputBindings
        )
    }

    private static func persistStore(_ inputStore: ProfileStore) throws {
        try profileBackend().requireLegacyPersistenceAllowed(operation: "legacy configuration write")
        var store = inputStore
        let state = GamepadConfigurationProfilePersistence.normalizedState(
            profiles: store.profiles,
            activeProfileID: store.activeProfileID,
            defaultProfileID: store.defaultProfileID,
            fallbackCustomization: store.profiles.first?.customization ?? .defaultValue
        )
        store.profiles = state.profiles
        store.activeProfileID = state.activeProfileID
        store.defaultProfileID = state.defaultProfileID

        let validIDs = Set(store.profiles.map { $0.id.uuidString })
        store.profileKeyBindings = store.profileKeyBindings.filter { validIDs.contains($0.key) }
        store.profileOutputBindings = store.profileOutputBindings.filter { validIDs.contains($0.key) }
        let activeProfile = state.activeProfile ?? state.profiles[0]
        let activeBindings = decodedBindings(store.profileKeyBindings[activeProfile.id.uuidString]) ?? DefaultKeypadKeyMap.defaultBindings
        store.profileKeyBindings[activeProfile.id.uuidString] = rawBindings(activeBindings)
        let storedActiveOutputBindings = decodedOutputBindings(store.profileOutputBindings[activeProfile.id.uuidString]) ?? outputBindings(from: activeBindings)
        let activeOutputBindings = effectiveOutputBindings(
            for: activeProfile.outputMode,
            keyBindings: activeBindings,
            customOutputBindings: storedActiveOutputBindings
        )
        store.profileOutputBindings[activeProfile.id.uuidString] = rawOutputBindings(activeOutputBindings)

        var domain = loadAppDomain()
        let stateData = try JSONEncoder().encode(
            StoredProfileState(
                profiles: state.profiles,
                activeProfileID: state.activeProfileID,
                defaultProfileID: state.defaultProfileID
            )
        )
        let activeCustomizationData = try JSONEncoder().encode(activeProfile.customization.normalized)
        let keyBindingsData = try JSONEncoder().encode(rawBindings(activeBindings))
        let profileKeyBindingsData = try JSONEncoder().encode(store.profileKeyBindings)
        let outputBindingsData = try JSONEncoder().encode(rawOutputBindings(activeOutputBindings))
        let profileOutputBindingsData = try JSONEncoder().encode(store.profileOutputBindings)

        domain[GamepadConfigurationProfilePersistence.defaultsKey] = stateData
        domain[GamepadCustomizationPersistence.defaultsKey] = activeCustomizationData
        domain[keyBindingsDefaultsKey] = keyBindingsData
        domain[profileKeyBindingsDefaultsKey] = profileKeyBindingsData
        domain[outputBindingsDefaultsKey] = outputBindingsData
        domain[profileOutputBindingsDefaultsKey] = profileOutputBindingsData

        UserDefaults.standard.setPersistentDomain(domain, forName: appDefaultsDomain)
        UserDefaults.standard.synchronize()
        notifyRunningMacHelper(
            profileStateData: stateData,
            activeCustomizationData: activeCustomizationData,
            keyBindingsData: keyBindingsData,
            profileKeyBindingsData: profileKeyBindingsData,
            outputBindingsData: outputBindingsData,
            profileOutputBindingsData: profileOutputBindingsData
        )
    }

    private static func loadAppDomain() -> [String: Any] {
        UserDefaults.standard.persistentDomain(forName: appDefaultsDomain) ?? [:]
    }

    private static func loadProfileState(from domain: [String: Any]) -> GamepadConfigurationProfilePersistence.LoadedState {
        let activeCustomization: GamepadCustomization
        if let data = dataValue(domain[GamepadCustomizationPersistence.defaultsKey]),
           let decoded = try? JSONDecoder().decode(GamepadCustomization.self, from: data) {
            activeCustomization = decoded.normalized
        } else {
            activeCustomization = .defaultValue
        }

        if let data = dataValue(domain[GamepadConfigurationProfilePersistence.defaultsKey]),
           let stored = try? JSONDecoder().decode(StoredProfileState.self, from: data) {
            return GamepadConfigurationProfilePersistence.normalizedState(
                profiles: stored.profiles,
                activeProfileID: stored.activeProfileID,
                defaultProfileID: stored.defaultProfileID,
                fallbackCustomization: activeCustomization
            )
        }

        return GamepadConfigurationProfilePersistence.normalizedState(
            profiles: [],
            activeProfileID: nil,
            defaultProfileID: nil,
            fallbackCustomization: activeCustomization
        )
    }

    private static func loadProfileBindings(from domain: [String: Any]) -> [String: [String: MacKeyBinding]] {
        guard let data = dataValue(domain[profileKeyBindingsDefaultsKey]),
              let decoded = try? JSONDecoder().decode([String: [String: MacKeyBinding]].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func loadActiveKeyBindings(from domain: [String: Any]) -> [GameButton: MacKeyBinding] {
        guard let data = dataValue(domain[keyBindingsDefaultsKey]),
              let raw = try? JSONDecoder().decode([String: MacKeyBinding].self, from: data),
              let decoded = decodedBindings(raw)
        else { return DefaultKeypadKeyMap.defaultBindings }
        return decoded
    }

    private static func decodedBindings(_ raw: [String: MacKeyBinding]?) -> [GameButton: MacKeyBinding]? {
        MacConfigurationBindings.decodedKeyBindings(raw)
    }

    private static func rawBindings(_ bindings: [GameButton: MacKeyBinding]) -> [String: MacKeyBinding] {
        MacConfigurationBindings.rawKeyBindings(bindings)
    }

    private static func outputBindings(from keyBindings: [GameButton: MacKeyBinding]) -> [GameButton: MacControlOutputBinding] {
        MacConfigurationBindings.keyboardOutputs(from: keyBindings)
    }

    private static func effectiveOutputBindings(
        for mode: GamepadProfileOutputMode,
        keyBindings: [GameButton: MacKeyBinding],
        customOutputBindings: [GameButton: MacControlOutputBinding]
    ) -> [GameButton: MacControlOutputBinding] {
        MacConfigurationBindings.effectiveOutputs(
            for: mode,
            keyBindings: keyBindings,
            customOutputs: customOutputBindings
        )
    }

    private static func bindingPresentations(
        for profile: GamepadConfigurationProfile,
        store: ProfileStore
    ) -> [GamepadProfileBindingPresentations] {
        let profileID = profile.id.uuidString
        let keys = decodedBindings(store.profileKeyBindings[profileID]) ?? DefaultKeypadKeyMap.defaultBindings
        let storedOutputs = decodedOutputBindings(store.profileOutputBindings[profileID]) ?? outputBindings(from: keys)
        let outputs = effectiveOutputBindings(
            for: profile.outputMode,
            keyBindings: keys,
            customOutputBindings: storedOutputs
        )
        return KeypadBindingPresentationBuilder.presentations(
            for: profile,
            effectiveLegacyOutputs: outputs.compactMapValues { $0.isEmpty ? nil : $0.sharedBinding }
        )
    }

    private static func rawOutputBindings(_ bindings: [GameButton: MacControlOutputBinding]) -> [String: MacControlOutputBinding] {
        MacConfigurationBindings.rawOutputs(bindings)
    }

    private static func decodedOutputBindings(_ raw: [String: MacControlOutputBinding]?) -> [GameButton: MacControlOutputBinding]? {
        MacConfigurationBindings.decodedOutputs(raw)
    }

    private static func loadProfileOutputBindings(
        from domain: [String: Any],
        fallbackProfileKeyBindings: [String: [String: MacKeyBinding]]
    ) -> [String: [String: MacControlOutputBinding]] {
        var resolvedOutputBindings = Dictionary(uniqueKeysWithValues: fallbackProfileKeyBindings.map { profileID, rawBindings in
            (profileID, rawOutputBindings(outputBindings(from: decodedBindings(rawBindings) ?? DefaultKeypadKeyMap.defaultBindings)))
        })
        guard let data = dataValue(domain[profileOutputBindingsDefaultsKey]),
              let decoded = try? JSONDecoder().decode([String: [String: MacControlOutputBinding]].self, from: data)
        else { return resolvedOutputBindings }
        for (profileID, bindings) in decoded {
            resolvedOutputBindings[profileID] = bindings
        }
        return resolvedOutputBindings
    }

    private static func dataValue(_ value: Any?) -> Data? {
        if let data = value as? Data { return data }
        if let data = value as? NSData { return data as Data }
        return nil
    }

    private static func notifyRunningMacHelper(
        profileStateData: Data,
        activeCustomizationData: Data?,
        keyBindingsData: Data?,
        profileKeyBindingsData: Data,
        outputBindingsData: Data?,
        profileOutputBindingsData: Data
    ) {
        var userInfo: [String: Any] = [
            notificationProfileStateDataKey: profileStateData,
            notificationProfileKeyBindingsDataKey: profileKeyBindingsData,
            notificationProfileOutputBindingsDataKey: profileOutputBindingsData
        ]
        if let activeCustomizationData { userInfo[notificationActiveCustomizationDataKey] = activeCustomizationData }
        if let keyBindingsData { userInfo[notificationKeyBindingsDataKey] = keyBindingsData }
        if let outputBindingsData { userInfo[notificationOutputBindingsDataKey] = outputBindingsData }

        DistributedNotificationCenter.default().postNotificationName(
            profileStoreChangedNotificationName,
            object: nil,
            userInfo: userInfo,
            deliverImmediately: true
        )
    }

    // MARK: - Resolution / parsing helpers

    private static func resolveProfile(_ target: String?, in store: ProfileStore) throws -> GamepadConfigurationProfile {
        store.profiles[try resolveProfileIndex(target, in: store)]
    }

    private static func resolveProfileIndex(_ target: String?, in store: ProfileStore) throws -> Int {
        let trimmed = target?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty, trimmed.lowercased() != "active" else {
            guard let index = store.profiles.firstIndex(where: { $0.id == store.activeProfileID }) else { throw CLIError.message("Active profile not found") }
            return index
        }
        if trimmed.lowercased() == "default" {
            guard let index = store.profiles.firstIndex(where: { $0.id == store.defaultProfileID }) else { throw CLIError.message("Default profile not found") }
            return index
        }
        if let uuid = UUID(uuidString: trimmed), let index = store.profiles.firstIndex(where: { $0.id == uuid }) { return index }
        if let index = store.profiles.firstIndex(where: { sameProfileName($0.name, trimmed) }) { return index }
        let normalized = normalizedLookup(trimmed)
        let matches = store.profiles.indices.filter { normalizedLookup(store.profiles[$0].name).contains(normalized) }
        if matches.count == 1 { return matches[0] }
        if matches.count > 1 { throw CLIError.message("Profile name is ambiguous: \(trimmed)") }
        throw CLIError.message("Profile not found: \(trimmed)")
    }

    private static func resolveProfileIndexes(_ targets: [String], in store: ProfileStore) throws -> [Int] {
        var indexes: [Int] = []
        var seenIndexes = Set<Int>()
        for target in targets {
            let index = try resolveProfileIndex(target, in: store)
            if seenIndexes.insert(index).inserted {
                indexes.append(index)
            }
        }
        return indexes.sorted()
    }

    private static func validProfileID(_ id: UUID, in profiles: [GamepadConfigurationProfile]) -> UUID? {
        profiles.contains(where: { $0.id == id }) ? id : nil
    }

    private static func resolveTemplate(_ text: String) throws -> GamepadControllerTemplate {
        let normalized = normalizedLookup(text)
        if let template = GamepadControllerTemplate.allCases.first(where: { normalizedLookup($0.rawValue) == normalized || normalizedLookup($0.displayName) == normalized }) {
            return template
        }
        let matches = GamepadControllerTemplate.allCases.filter { normalizedLookup($0.displayName).contains(normalized) || normalizedLookup($0.rawValue).contains(normalized) }
        if matches.count == 1 { return matches[0] }
        if matches.count > 1 { throw CLIError.message("Template name is ambiguous: \(text)") }
        throw CLIError.message("Template not found: \(text)")
    }

    private static func parseButton(_ text: String) throws -> GameButton {
        let normalized = normalizedLookup(text)
        if let button = GameButton(rawValue: text) { return button }
        if let button = GameButton.allCases.first(where: { normalizedLookup($0.rawValue) == normalized || normalizedLookup($0.displayName) == normalized }) {
            return button
        }
        throw CLIError.message("Unknown button: \(text)")
    }

    private static func parseElementInput(_ text: String) throws -> KeypadElementInputID {
        guard let input = KeypadElementInputID(storageKey: text) else {
            throw CLIError.message("Invalid element input id: \(text). Use UUID or UUID#part.")
        }
        return input
    }

    private static func parseOutputMode(_ text: String) throws -> GamepadProfileOutputMode {
        if let mode = GamepadProfileOutputMode(rawValue: text.lowercased()) { return mode }
        switch normalizedLookup(text) {
        case "key", "keys", "keyboard", "shortcut", "shortcuts":
            return .keyboard
        case "controller", "gamepad", "pad", "xbox":
            return .controller
        case "custom", "mixed", "hybrid", "both":
            return .custom
        default:
            throw CLIError.message("Unknown output mode: \(text). Use keyboard, controller, or custom.")
        }
    }

    private static func parseVirtualGamepadButton(_ text: String) throws -> VirtualGamepadButton {
        let normalized = normalizedLookup(text)
        if let button = VirtualGamepadButton(rawValue: text) { return button }
        if let button = VirtualGamepadButton.allCases.first(where: {
            normalizedLookup($0.rawValue) == normalized
                || normalizedLookup($0.displayName) == normalized
                || normalizedLookup($0.shortName) == normalized
        }) {
            return button
        }
        throw CLIError.message("Unknown gamepad button: \(text)")
    }

    private static func parseVirtualGamepadTrigger(_ text: String) throws -> VirtualGamepadTrigger {
        let normalized = normalizedLookup(text)
        if let trigger = VirtualGamepadTrigger(rawValue: text) { return trigger }
        if normalized == "lt" || normalized == "l2" || normalized == "lefttrigger" { return .left }
        if normalized == "rt" || normalized == "r2" || normalized == "righttrigger" { return .right }
        if let trigger = VirtualGamepadTrigger.allCases.first(where: {
            normalizedLookup($0.rawValue) == normalized
                || normalizedLookup($0.displayName) == normalized
                || normalizedLookup($0.shortName) == normalized
        }) {
            return trigger
        }
        throw CLIError.message("Unknown gamepad trigger: \(text)")
    }

    private static func parseTriggerOrientation(_ text: String) throws -> GamepadTriggerOrientation {
        if let orientation = GamepadTriggerOrientation(rawValue: text.lowercased()) { return orientation }
        throw CLIError.message("Unknown trigger orientation: \(text). Use vertical or horizontal.")
    }

    private static func parseKeyBindingSequence(_ text: String) throws -> MacKeyBinding {
        let separators = CharacterSet(charactersIn: ",")
        let parts = text.components(separatedBy: separators).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let strokeTexts = parts.isEmpty ? [text] : parts
        let strokes = try strokeTexts.map(parseKeyStroke)
        return MacKeyBinding(strokes: strokes)
    }

    private static func parseKeyStroke(_ text: String) throws -> MacKeyStroke {
        let parts = text.split(separator: "+").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard let keyName = parts.last else { throw CLIError.message("Empty key stroke") }
        let modifierNames = Array(parts.dropLast())
        let modifiers = try parseModifiers(modifierNames.joined(separator: ","))
        guard let keyCode = MacVirtualKey.keyCode(named: keyName) else { throw CLIError.message("Unsupported key: \(keyName)") }
        return MacKeyStroke(keyCode: keyCode, modifiers: modifiers)
    }

    private static func parseModifiers(_ text: String?) throws -> MacKeyModifiers {
        let names = text?.split { $0 == "," || $0 == "+" || $0 == " " }.map(String.init) ?? []
        guard let modifiers = MacKeyModifiers(generatedModifierNames: names) else { throw CLIError.message("Unsupported modifiers: \(text ?? "")") }
        return modifiers
    }

    private static func parseLayoutMode(_ text: String) throws -> GamepadLayoutMode {
        if let value = GamepadLayoutMode(rawValue: text) { return value }
        let normalized = normalizedLookup(text)
        if normalized == "navleft" { return .standard }
        if normalized == "actionsleft" { return .southpaw }
        throw CLIError.message("Unknown layout mode: \(text)")
    }

    private static func parseControlScale(_ text: String) throws -> GamepadControlScale {
        if let value = GamepadControlScale(rawValue: text) { return value }
        throw CLIError.message("Unknown control scale: \(text)")
    }

    private static func parseColorSchemePreference(_ text: String) throws -> GamepadColorSchemePreference {
        if let value = GamepadColorSchemePreference(rawValue: text.lowercased()) { return value }
        switch normalizedLookup(text) {
        case "system", "auto", "device", "followdevice", "followsdevice", "followssystem":
            return .system
        case "light", "lightmode", "alwayslight":
            return .light
        case "dark", "darkmode", "alwaysdark":
            return .dark
        default:
            throw CLIError.message("Unknown appearance: \(text)")
        }
    }

    private static func parseAccentStyle(_ text: String) throws -> GamepadAccentStyle {
        if let value = parseAccentStyleIfPresent(text) { return value }
        throw CLIError.message("Unknown accent style: \(text)")
    }

    private static func parseAccentStyleIfPresent(_ text: String) -> GamepadAccentStyle? {
        GamepadAccentStyle(rawValue: text) ?? GamepadAccentStyle.allCases.first { normalizedLookup($0.displayName) == normalizedLookup(text) }
    }

    private static func parseRGBAColor(_ text: String) throws -> GamepadRGBAColor {
        guard let color = GamepadRGBAColor(hexString: text) else {
            throw CLIError.message("Invalid color: \(text). Use #RRGGBB or #RRGGBBAA.")
        }
        return color
    }

    private static func parseGradientFill(_ text: String, arguments: [String]) throws -> GamepadFillStyle {
        let colors = text
            .split { $0 == "," || $0 == ";" || $0 == " " }
            .map(String.init)
            .filter { !$0.isEmpty }
        guard colors.count >= 2 else {
            throw CLIError.message("Gradient fill expects at least two colors, e.g. --fill-gradient '#FF0000,#0000FF'")
        }
        let stops = try colors.enumerated().map { index, colorText in
            let denominator = max(colors.count - 1, 1)
            return GamepadGradientStop(offset: CGFloat(index) / CGFloat(denominator), color: try parseRGBAColor(colorText))
        }
        let type = try optionValue("--gradient-type", in: arguments).map(parseGradientType) ?? .linear
        let angle = optionValue("--gradient-angle", in: arguments).flatMap(Double.init).map { CGFloat($0) } ?? 0
        return .gradient(GamepadGradientFill(type: type, angleDegrees: angle, stops: stops).normalized)
    }

    private static func parseGradientType(_ text: String) throws -> GamepadGradientType {
        if let type = GamepadGradientType(rawValue: text.lowercased()) { return type }
        throw CLIError.message("Unknown gradient type: \(text). Use linear or radial.")
    }

    private static func parseTileFill(_ text: String, arguments: [String]) throws -> GamepadFillStyle {
        let pattern = try parseTilePattern(text)
        let foreground = try optionValue("--tile-foreground", in: arguments).map(parseRGBAColor) ?? GamepadRGBAColor(red: 1, green: 1, blue: 1, alpha: 0.78)
        let background = try optionValue("--tile-background", in: arguments).map(parseRGBAColor) ?? .defaultValue
        let scale = optionValue("--tile-scale", in: arguments).flatMap(Double.init).map { CGFloat($0) } ?? 1
        let spacingX = optionValue("--tile-spacing-x", in: arguments).flatMap(Double.init).map { CGFloat($0) } ?? 0
        let spacingY = optionValue("--tile-spacing-y", in: arguments).flatMap(Double.init).map { CGFloat($0) } ?? 0
        let tile = GamepadTileFill(pattern: pattern, foregroundColor: foreground, backgroundColor: background, scale: scale, spacingX: spacingX, spacingY: spacingY)
        return .tile(tile.normalized)
    }

    private static func parseTilePattern(_ text: String) throws -> GamepadTilePattern {
        if let pattern = GamepadTilePattern(rawValue: text.lowercased()) { return pattern }
        let normalized = normalizedLookup(text)
        if let pattern = GamepadTilePattern.allCases.first(where: { normalizedLookup($0.displayName) == normalized }) { return pattern }
        throw CLIError.message("Unknown tile pattern: \(text). Use dots, grid, checker, or diagonal.")
    }

    private static func parseImageFill(_ path: String, arguments: [String]) throws -> GamepadFillStyle {
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        let data = try Data(contentsOf: url)
        guard data.count <= GamepadImageFill.maximumStoredBytes else {
            throw CLIError.message("Image fill must be under 2.5 MB")
        }
        let mode = try optionValue("--image-mode", in: arguments).map(parseImageContentMode) ?? .fill
        return .image(GamepadImageFill(data: data, fileName: url.lastPathComponent, contentMode: mode).normalized)
    }

    private static func parseImageContentMode(_ text: String) throws -> GamepadImageContentMode {
        if let mode = GamepadImageContentMode(rawValue: text.lowercased()) { return mode }
        throw CLIError.message("Unknown image mode: \(text). Use fill, fit, or tile.")
    }

    private static func parseShapeStyleIfPresent(_ text: String) -> GamepadButtonShapeStyle? {
        GamepadButtonShapeStyle(rawValue: text) ?? GamepadButtonShapeStyle.allCases.first { normalizedLookup($0.displayName) == normalizedLookup(text) }
    }

    private static func parseJoystickVisualStyle(_ text: String) throws -> GamepadJoystickVisualStyle {
        if let style = GamepadJoystickVisualStyle(rawValue: text) { return style }
        switch normalizedLookup(text) {
        case "pad", "fullpad", "classic", "joystick": return .pad
        case "thumbstick", "thumb", "nub", "stickball", "ball": return .thumbstick
        default: throw CLIError.message("Unknown joystick style: \(text). Use pad or thumbstick.")
        }
    }

    private static func parseCustomControlKind(_ text: String) throws -> GamepadCustomControlKind {
        if let value = GamepadCustomControlKind(rawValue: text) { return value }
        let normalized = normalizedLookup(text)
        if normalized == "shape" { return .button }
        if normalized == "stick" { return .joystick }
        if normalized == "trigger" || normalized == "slider" { return .trigger }
        if normalized == "touchpad" || normalized == "trackpad" || normalized == "cursorpad" { return .trackpad }
        if normalized == "text" || normalized == "label" || normalized == "caption" || normalized == "letter" { return .text }
        if normalized == "decoration" || normalized == "decor" || normalized == "visual" || normalized == "plate" || normalized == "panel" || normalized == "ring" { return .decoration }
        throw CLIError.message("Unknown element kind: \(text)")
    }

    private static func parseVisualRole(_ text: String) throws -> GamepadVisualRole {
        if let role = GamepadVisualRole(rawValue: text) { return role }
        switch normalizedLookup(text) {
        case "movement", "move", "dpad", "direction": return .movement
        case "primary", "primaryaction", "action": return .primaryAction
        case "secondary", "secondaryaction": return .secondaryAction
        case "utility", "tool": return .utility
        case "menu", "pause": return .menu
        case "custom", "customaction": return .custom
        case "joystick", "stick": return .joystick
        case "trigger", "shoulder": return .trigger
        case "trackpad", "touchpad", "pointer": return .trackpad
        case "decoration", "decor", "art": return .decoration
        case "system", "chrome": return .system
        default:
            throw CLIError.message("Unknown visual role: \(text). Use movement, primary-action, secondary-action, utility, menu, custom, joystick, trigger, trackpad, decoration, or system.")
        }
    }

    private static func parseHitInsets(_ text: String) throws -> GamepadHitInsets {
        let values = try text
            .split { $0 == "," || $0 == ";" || $0.isWhitespace }
            .map { try parsePixels(String($0)) }
        switch values.count {
        case 1:
            return .all(values[0]).normalized
        case 2:
            return GamepadHitInsets(
                top: values[0],
                leading: values[1],
                bottom: values[0],
                trailing: values[1]
            ).normalized
        case 4:
            return GamepadHitInsets(
                top: values[0],
                leading: values[1],
                bottom: values[2],
                trailing: values[3]
            ).normalized
        default:
            throw CLIError.message("Invalid hit insets: \(text). Use ALL, VERTICAL,HORIZONTAL, or TOP,LEADING,BOTTOM,TRAILING.")
        }
    }

    private static func parseMaterialVisualStyle(_ text: String) throws -> GamepadControlVisualStyle {
        switch normalizedLookup(text) {
        case "softwhite", "softwhiteraised", "raised", "neumorphic", "neumorphicraised":
            return .softWhiteRaised()
        case "softwhiteinset", "inset", "recessed", "well":
            return .softWhiteInset()
        case "softwhiteplate", "plate", "panel", "shell":
            return .softWhitePlate()
        default:
            throw CLIError.message("Unknown material preset: \(text). Use soft-white, soft-white-inset, or soft-white-plate.")
        }
    }

    private static func parseShadowLayers(_ text: String) throws -> [GamepadControlShadowStyle] {
        let parts = text.split(separator: ";").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return [] }
        return try parts.map { part in
            let fields = part.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            guard fields.count >= 4 else {
                throw CLIError.message("Invalid shadow layer \"\(part)\". Use color,radius,x,y[,opacity]; separate layers with semicolons.")
            }
            let color = try parseRGBAColor(fields[0])
            guard let radius = Double(fields[1]), let x = Double(fields[2]), let y = Double(fields[3]) else {
                throw CLIError.message("Invalid shadow layer numbers in \"\(part)\".")
            }
            let opacity = fields.count >= 5 ? (parseOpacityIfPresent(fields[4]) ?? 1) : 1
            return GamepadControlShadowStyle(color: color, radius: CGFloat(radius), x: CGFloat(x), y: CGFloat(y), opacity: opacity)
        }
    }

    private static func defaultLabel(for kind: GamepadCustomControlKind) -> String {
        kind.defaultElementLabel
    }

    private static func triggerSettings(
        from arguments: [String],
        fallback: GamepadTriggerSettings = .defaultValue
    ) throws -> GamepadTriggerSettings {
        var settings = fallback.normalized
        if let value = optionValue("--target", in: arguments) ?? optionValue("--trigger", in: arguments) {
            settings.target = try parseVirtualGamepadTrigger(value)
        }
        if let value = optionValue("--orientation", in: arguments) {
            settings.orientation = try parseTriggerOrientation(value)
        }
        if let value = optionValue("--dead-zone", in: arguments) ?? optionValue("--deadzone", in: arguments) {
            settings.deadZone = try parseUnitInterval(value, option: "trigger dead zone")
        }
        if let value = optionValue("--sensitivity", in: arguments) {
            settings.sensitivity = try parseTrackpadScale(value, option: "trigger sensitivity")
        }
        if let value = optionValue("--digital", in: arguments) ?? optionValue("--digital-button", in: arguments) {
            settings.sendsDigitalButton = try parseBool(value)
        }
        if let value = optionValue("--digital-threshold", in: arguments) {
            settings.digitalThreshold = try parseUnitInterval(value, option: "trigger digital threshold")
        }
        return settings.normalized
    }

    private static func trackpadSettings(
        from arguments: [String],
        fallback: GamepadTrackpadSettings = .defaultValue
    ) throws -> GamepadTrackpadSettings {
        var settings = fallback.normalized
        if let value = optionValue("--sensitivity", in: arguments) ?? optionValue("--cursor-sensitivity", in: arguments) ?? optionValue("--pointer-sensitivity", in: arguments) {
            settings.sensitivity = try parseTrackpadScale(value, option: "sensitivity")
        }
        if let value = optionValue("--scroll-sensitivity", in: arguments) {
            settings.scrollSensitivity = try parseTrackpadScale(value, option: "scroll sensitivity")
        }
        if let value = optionValue("--tap-to-click", in: arguments) {
            settings.tapToClick = try parseBool(value)
        }
        if let value = optionValue("--two-finger-scroll", in: arguments) {
            settings.twoFingerScroll = try parseBool(value)
        }
        if let value = optionValue("--natural-scrolling", in: arguments) ?? optionValue("--natural-scroll", in: arguments) {
            settings.naturalScrolling = try parseBool(value)
        }
        return settings.normalized
    }

    private static func parseTrackpadScale(_ text: String, option: String) throws -> CGFloat {
        guard let value = Double(text), value.isFinite else {
            throw CLIError.message("Invalid \(option): \(text)")
        }
        return CGFloat(value)
    }

    private static func parseUnitInterval(_ text: String, option: String) throws -> CGFloat {
        guard let value = Double(text), value.isFinite else {
            throw CLIError.message("Invalid \(option): \(text)")
        }
        return CGFloat(value)
    }

    private static func parseBool(_ text: String) throws -> Bool {
        switch normalizedLookup(text) {
        case "true", "yes", "y", "1", "on": return true
        case "false", "no", "n", "0", "off": return false
        default: throw CLIError.message("Expected boolean, got: \(text)")
        }
    }

    private static func parseOpacityIfPresent(_ text: String) -> CGFloat? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("%"), let value = Double(trimmed.dropLast()) { return CGFloat(min(max(value / 100, 0), 1)) }
        guard let value = Double(trimmed) else { return nil }
        return CGFloat(min(max(value > 1 ? value / 100 : value, 0), 1))
    }

    private static func parseNudgeTranslation(arguments: [String], directionText: String?) throws -> CGSize {
        let dxText = optionValue("--dx", in: arguments)
        let dyText = optionValue("--dy", in: arguments)
        if dxText != nil || dyText != nil {
            guard directionText == nil else { throw CLIError.message("Use either a direction or --dx/--dy, not both") }
            let dx = try dxText.map(parsePixels) ?? 0
            let dy = try dyText.map(parsePixels) ?? 0
            guard abs(dx) > 0.001 || abs(dy) > 0.001 else { throw CLIError.message("Nudge delta cannot be zero") }
            return CGSize(width: dx, height: dy)
        }

        guard let directionText else { throw CLIError.message("Missing nudge direction: left, right, up, or down") }
        let step = try parseNudgeStep(arguments)
        switch normalizedLookup(directionText) {
        case "left", "arrowleft":
            return CGSize(width: -step, height: 0)
        case "right", "arrowright":
            return CGSize(width: step, height: 0)
        case "up", "arrowup":
            return CGSize(width: 0, height: -step)
        case "down", "arrowdown":
            return CGSize(width: 0, height: step)
        default:
            throw CLIError.message("Unknown nudge direction: \(directionText)")
        }
    }

    private static func parseNudgeStep(_ arguments: [String]) throws -> CGFloat {
        if let value = optionValue("--step", in: arguments) ?? optionValue("--pixels", in: arguments) ?? optionValue("--by", in: arguments) {
            let step = try parsePixels(value)
            guard step > 0 else { throw CLIError.message("Nudge step must be greater than zero") }
            return step
        }
        return (arguments.contains("--large") || arguments.contains("--shift")) ? 10 : 1
    }

    private static func parseNudgeCanvasSize(_ arguments: [String]) throws -> CGSize {
        var canvasSize = defaultEditorCanvasSize
        if let canvas = optionValue("--canvas", in: arguments) {
            let normalized = normalizedLookup(canvas)
            if normalized == "landscape" {
                canvasSize = defaultEditorCanvasSize
            } else if normalized == "portrait" {
                canvasSize = portraitEditorCanvasSize
            } else if let frame = GamepadEditorDeviceCatalog.frame(matching: canvas, preferredOrientation: nil) {
                canvasSize = frame.screenRect.size
            } else if let parsed = parseCanvasSizeLiteral(canvas) {
                canvasSize = parsed
            } else {
                throw CLIError.message("Invalid canvas size: \(canvas). Use landscape, portrait, a device frame id, or WIDTHxHEIGHT.")
            }
        }

        let explicitWidth = optionValue("--canvas-width", in: arguments)
        let explicitHeight = optionValue("--canvas-height", in: arguments)
        if explicitWidth != nil || explicitHeight != nil {
            guard let explicitWidth, let explicitHeight else { throw CLIError.message("Use --canvas-width and --canvas-height together") }
            canvasSize = CGSize(width: try parsePixels(explicitWidth), height: try parsePixels(explicitHeight))
        }

        guard canvasSize.width > 1, canvasSize.height > 1 else { throw CLIError.message("Canvas size must be greater than 1×1") }
        return canvasSize
    }

    private static func parseCanvasSizeLiteral(_ text: String) -> CGSize? {
        let separators = CharacterSet(charactersIn: "xX,:")
        let parts = text.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard parts.count == 2,
              let width = Double(parts[0]),
              let height = Double(parts[1])
        else { return nil }
        return CGSize(width: CGFloat(width), height: CGFloat(height))
    }

    private static func parsePixels(_ text: String) throws -> CGFloat {
        guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw CLIError.message("Expected a numeric pixel value, got: \(text)")
        }
        return CGFloat(value)
    }

    private static func formatPixels(_ value: CGFloat) -> String {
        let doubleValue = Double(value)
        if doubleValue.rounded() == doubleValue {
            return String(Int(doubleValue))
        }
        return String(format: "%.2f", doubleValue)
    }

    private static func formatSize(_ size: CGSize) -> String {
        "\(formatPixels(size.width))×\(formatPixels(size.height))"
    }

    private static func formatPercentage(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private static func formatScale(_ value: CGFloat) -> String {
        let doubleValue = Double(value)
        if doubleValue.rounded() == doubleValue {
            return String(Int(doubleValue))
        }
        return String(format: "%.2f", doubleValue)
    }

    private static func joystickMapping(from arguments: [String], fallback: GamepadJoystickMapping = .movement) throws -> GamepadJoystickMapping {
        var mapping = fallback
        if let value = optionValue("--up", in: arguments) { mapping.up = try parseButton(value) }
        if let value = optionValue("--down", in: arguments) { mapping.down = try parseButton(value) }
        if let value = optionValue("--left", in: arguments) { mapping.left = try parseButton(value) }
        if let value = optionValue("--right", in: arguments) { mapping.right = try parseButton(value) }
        return mapping
    }

    private static func joystickOutputSettings(
        from arguments: [String],
        fallback: GamepadJoystickOutputSettings = .defaultValue
    ) throws -> GamepadJoystickOutputSettings {
        var settings = fallback.normalized
        if let value = optionValue("--analog", in: arguments)
            ?? optionValue("--analog-stick", in: arguments)
            ?? optionValue("--stick", in: arguments)
            ?? optionValue("--target", in: arguments) {
            settings.analogTarget = try parseJoystickAnalogTarget(value)
        }
        if arguments.contains("--digital-directions") || arguments.contains("--send-digital-directions") || arguments.contains("--sends-digital-directions") {
            settings.sendsDigitalDirections = true
        }
        if let value = optionValue("--sends-digital-directions", in: arguments) {
            settings.sendsDigitalDirections = try parseBool(value)
        }
        if arguments.contains("--no-digital-directions") {
            settings.sendsDigitalDirections = false
        }
        if let value = optionValue("--dead-zone", in: arguments) ?? optionValue("--deadzone", in: arguments) {
            settings.deadZone = try parseUnitInterval(value, option: "joystick dead zone")
        }
        if let value = optionValue("--sensitivity", in: arguments) {
            settings.sensitivity = try parseTrackpadScale(value, option: "joystick sensitivity")
        }
        if arguments.contains("--invert-x") {
            settings.invertX = true
        }
        if arguments.contains("--invert-y") {
            settings.invertY = true
        }
        if arguments.contains("--snap-to-cardinal") || arguments.contains("--snap-cardinal") {
            settings.snapToCardinal = true
        }
        return settings.normalized
    }

    private static func parseJoystickAnalogTarget(_ text: String) throws -> GamepadJoystickAnalogTarget {
        if let target = GamepadJoystickAnalogTarget(rawValue: text) { return target }
        switch normalizedLookup(text) {
        case "none", "digital", "digitaldirections", "off": return .none
        case "left", "leftstick", "lstick", "ls": return .leftStick
        case "right", "rightstick", "rstick", "rs": return .rightStick
        default: throw CLIError.message("Unknown joystick analog target: \(text). Use none, left-stick, or right-stick.")
        }
    }

    private static func resolveElementTarget(_ text: String, in customization: GamepadCustomization) throws -> ElementTarget {
        let normalized = normalizedLookup(text)
        if let stableIdentity = GamepadControlIdentity(stableID: text) {
            switch stableIdentity {
            case .builtin(let button) where GameButton.builtInControls.contains(button):
                return .builtin(button)
            case .custom(let id) where customization.customButtons.contains(where: { $0.id == id }):
                return .custom(id)
            case .system(let control):
                return .system(control)
            case .controlBarItem:
                throw CLIError.message("Control bar items are managed with `thumble control-bar item`")
            default:
                break
            }
        }
        if normalized == "controlbar" || normalized == "topbar" || normalized == "iosbar" || normalized == "controlbarhotspot" || normalized == "topbaractivation" {
            return .system(.topBarActivation)
        }
        if let uuid = UUID(uuidString: text), customization.customButtons.contains(where: { $0.id == uuid }) { return .custom(uuid) }
        if let button = try? parseButton(text) {
            if GameButton.builtInControls.contains(button) { return .builtin(button) }
            let matches = customization.customButtons.filter { $0.mappedButton == button }
            if matches.count == 1 { return .custom(matches[0].id) }
        }
        let matches = customization.customButtons.filter { normalizedLookup($0.visualLabel(fallback: $0.mappedButton.displayName)) == normalized || normalizedLookup($0.label) == normalized }
        if matches.count == 1 { return .custom(matches[0].id) }
        if matches.count > 1 { throw CLIError.message("Element is ambiguous: \(text)") }
        throw CLIError.message("Element not found: \(text)")
    }

    private static func elementSummaries(for customization: GamepadCustomization) -> [ElementSummary] {
        var summaries: [ElementSummary] = GameButton.builtInControls.map { button in
            let layout = customization.buttonCustomization(for: button)
            return ElementSummary(
                id: button.rawValue,
                kind: "builtin",
                mappedButton: button,
                label: customization.visualLabel(for: button, defaultLabel: button.displayName),
                visualRole: customization.elements.first(where: { $0.builtInButton == button })?.visualRole,
                isHidden: layout.isHidden,
                isLocationLocked: layout.isLocationLocked,
                layout: layout,
                joystickMapping: nil,
                joystickOutputSettings: nil,
                triggerSettings: nil,
                trackpadSettings: nil
            )
        }
        summaries += customization.customButtons.map { custom in
            let normalized = custom.normalized
            let kind = normalized.isJoystick ? "joystick" : (normalized.isTrigger ? "trigger" : (normalized.isTrackpad ? "trackpad" : (normalized.isDecoration ? "decoration" : "button")))
            let fallbackLabel = normalized.isDecoration ? "Decoration" : (normalized.isTrigger ? (normalized.triggerSettings ?? .defaultValue).normalized.target.shortName : (normalized.isTrackpad ? "Trackpad" : "Button"))
            return ElementSummary(
                id: normalized.id.uuidString,
                kind: kind,
                mappedButton: normalized.mappedButton,
                label: normalized.visualLabel(fallback: fallbackLabel),
                visualRole: normalized.visualRole,
                isHidden: normalized.layout.isHidden,
                isLocationLocked: normalized.layout.isLocationLocked,
                layout: normalized.layout,
                joystickMapping: normalized.joystickMapping,
                joystickOutputSettings: normalized.joystickOutputSettings,
                triggerSettings: normalized.triggerSettings,
                trackpadSettings: normalized.trackpadSettings
            )
        }
        let topBarLayout = customization.topBarActivationRegion.normalized
        summaries.append(
            ElementSummary(
                id: GamepadControlIdentity.system(.topBarActivation).id,
                kind: "system",
                mappedButton: nil,
                label: GamepadSystemControl.topBarActivation.displayName,
                visualRole: .system,
                isHidden: topBarLayout.isHidden,
                isLocationLocked: topBarLayout.isLocationLocked,
                layout: topBarLayout,
                joystickMapping: nil,
                joystickOutputSettings: nil,
                triggerSettings: nil,
                trackpadSettings: nil
            )
        )
        return summaries
    }

    private static func firstAvailableCustomSlot(in customization: GamepadCustomization) -> GameButton? {
        GameButton.customSlots.first { slot in !customization.customButtons.contains { $0.mappedButton == slot } }
    }

    private static func resolvedMacBindings(for generated: GeneratedGameKeypadProfile) throws -> [GameButton: MacKeyBinding] {
        var bindings = DefaultKeypadKeyMap.defaultBindings
        for (button, spec) in generated.keyBindings {
            guard let binding = MacKeyBinding(generatedSpec: spec) else {
                let rawBinding = (spec.modifiers + [spec.key]).joined(separator: "+")
                throw CLIError.message("Unsupported key binding for \(button.displayName): \(rawBinding)")
            }
            bindings[button] = binding
        }
        return bindings
    }

    private static func sameProfileName(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(rhs.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }

    private static func normalizedLookup(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func normalizedLabel(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > GamepadCustomization.maximumLabelLength else { return trimmed }
        return String(trimmed.prefix(GamepadCustomization.maximumLabelLength))
    }

    private static func optionValue(_ option: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private static func hasAnyOption(_ options: [String], in arguments: [String]) -> Bool {
        options.contains { arguments.contains($0) }
    }

    private static func firstPositional(in arguments: [String]) -> String? {
        positionals(in: arguments).first
    }

    private static func positionals(in arguments: [String]) -> [String] {
        var values: [String] = []
        var skipNext = false
        let optionsWithValues: Set<String> = [
            "--spec", "--from-spec", "--output", "-o", "--window-title", "--profile", "--name", "--template", "--from", "--identifier", "--artboard", "--build-directory", "--state", "--columns",
            "--layout-preview", "--preview-output", "--path", "--app", "--application", "--bundle-id", "--bundle", "--image-scale", "--render-scale",
            "--sequence", "--keyboard", "--key", "--gamepad-button", "--gamepad", "--part", "--input", "--modifiers", "--mods", "--layout", "--scale", "--control-scale",
            "--appearance", "--color-scheme", "--scheme", "--accent", "--color", "--labels", "--label", "--maps-to", "--x", "--center-x", "--y", "--center-y",
            "--background", "--bg", "--light-background", "--background-light", "--dark-background", "--background-dark",
            "--background-gradient", "--bg-gradient", "--background-tile", "--bg-tile", "--background-image", "--bg-image",
            "--light-background-gradient", "--background-light-gradient", "--dark-background-gradient", "--background-dark-gradient",
            "--light-background-tile", "--background-light-tile", "--dark-background-tile", "--background-dark-tile",
            "--light-background-image", "--background-light-image", "--dark-background-image", "--background-dark-image",
            "--width", "--width-scale", "--device-width", "--height", "--height-scale", "--device-height", "--z-index", "--z", "--zindex", "--shape", "--fill", "--light-fill", "--fill-light",
            "--light-color", "--dark-fill", "--fill-dark", "--dark-color", "--opacity", "--light-opacity", "--dark-opacity",
            "--thumb-fill", "--thumb-color", "--joystick-thumb-fill", "--joystick-knob-fill", "--light-thumb-fill", "--thumb-light", "--light-thumb-color",
            "--dark-thumb-fill", "--thumb-dark", "--dark-thumb-color", "--thumb-opacity", "--light-thumb-opacity", "--dark-thumb-opacity",
            "--fill-gradient", "--gradient", "--gradient-type", "--gradient-angle", "--light-fill-gradient", "--dark-fill-gradient", "--gradient-light", "--gradient-dark",
            "--fill-tile", "--tile", "--tile-foreground", "--tile-background", "--tile-scale", "--tile-spacing-x", "--tile-spacing-y", "--light-fill-tile", "--dark-fill-tile", "--tile-light", "--tile-dark",
            "--fill-image", "--image", "--image-mode",
            "--corner", "--radius", "--corner-tl", "--corner-tr", "--corner-br", "--corner-bl", "--shadow",
            "--shadow-strength", "--kind", "--up", "--down", "--left", "--right", "--target", "--trigger", "--dead-zone", "--deadzone", "--sensitivity",
            "--analog", "--analog-stick", "--stick", "--sends-digital-directions", "--joystick-style", "--stick-style",
            "--cursor-sensitivity", "--pointer-sensitivity", "--scroll-sensitivity", "--tap-to-click",
            "--two-finger-scroll", "--natural-scrolling", "--natural-scroll", "--digital", "--digital-button", "--digital-threshold", "--hold-ms",
            "--step", "--pixels", "--by", "--dx", "--dy", "--canvas", "--canvas-width", "--canvas-height",
            "--device", "--frame", "--size", "--device-size", "--orientation", "--device-orientation", "--variant", "--layout-variant",
            "--id", "--style", "--style-id", "--icon", "--sf-symbol", "--icon-text", "--haptic",
            "--haptic-pattern", "--haptic-rhythm", "--haptic-intensity", "--haptic-strength", "--haptic-sharpness", "--haptic-duration", "--haptic-duration-ms",
            "--stroke", "--stroke-color", "--stroke-width", "--foreground", "--foreground-color", "--text-color",
            "--glow", "--glow-color", "--glow-radius", "--inner-shadow", "--inner-shadow-color", "--inner-shadow-radius", "--inner-shadow-x", "--inner-shadow-y",
            "--highlight", "--highlight-color", "--highlight-radius", "--highlight-x", "--highlight-y", "--highlight-opacity",
            "--bevel", "--bevel-highlight", "--bevel-shadow", "--bevel-width", "--pressed-fill", "--pressed-color", "--press-scale", "--scale-on-press",
            "--material", "--material-preset", "--shadow-layers", "--shadows",
            "--to", "--before", "--after", "--invocation-id", "--role", "--visual-role", "--skin-role", "--hit-insets", "--hit-top", "--hit-leading", "--hit-bottom", "--hit-trailing",
            "--items", "--controls", "--offset", "--offset-x", "--offset-y", "--repair"
        ]
        for argument in arguments {
            if skipNext {
                skipNext = false
                continue
            }
            if optionsWithValues.contains(argument) {
                skipNext = true
                continue
            }
            if argument.hasPrefix("-") { continue }
            values.append(argument)
        }
        return values
    }

    // MARK: - Output / process helpers

    private static func printProfile(_ profile: GamepadConfigurationProfile, store: ProfileStore) {
        print("Name: \(profile.name)")
        print("ID: \(profile.id.uuidString)")
        print("Active: \(profile.id == store.activeProfileID ? "yes" : "no")")
        print("Default: \(profile.id == store.defaultProfileID ? "yes" : "no")")
        print("Output: \(profile.outputMode.displayName)")
        print("iPhone Rotation: \(profile.orientationPreference.rawValue)")
        if let launchTarget = profile.launchTarget {
            print("Attached Application: \(launchTarget.displayName) (\(launchTarget.detailText))")
        } else {
            print("Attached Application: none")
        }
        print("Layout: \(profile.customization.layoutMode.rawValue)")
        print("Scale: \(profile.customization.controlScale.rawValue)")
        let deviceFrame = profile.customization.deviceCanvas.editorDeviceFrame
        print("Appearance: \(profile.customization.colorSchemePreference.rawValue)")
        print("Device: \(deviceFrame.displayName) (\(formatSize(deviceFrame.screenRect.size)) pt)")
        let variants = [
            profile.landscapeCustomization == nil ? nil : "landscape",
            profile.portraitCustomization == nil ? nil : "portrait"
        ].compactMap { $0 }.joined(separator: ", ")
        print("Orientation variants: \(variants.isEmpty ? "none" : variants)")
        let lightBackground = profile.customization.keypadBackgroundFillStyle(scheme: .light)
        let darkBackground = profile.customization.keypadBackgroundFillStyle(scheme: .dark)
        print("Background: light \(lightBackground.displayName) \(lightBackground.representativeColor.hexString), dark \(darkBackground.displayName) \(darkBackground.representativeColor.hexString)")
        print("Accent: \(profile.customization.accentStyle.displayName)")
        print("Labels: \(profile.customization.showsButtonLabels ? "shown" : "hidden")")
        let controlBar = profile.customization.normalized.controlBarItems.map(\.shortName).joined(separator: ", ")
        print("Control Bar: \(controlBar.isEmpty ? "none" : controlBar)")
        print("Custom elements: \(profile.customization.customButtons.count)")
    }

    private static func printSummary(
        generated: GeneratedGameKeypadProfile,
        macBindings: [GameButton: MacKeyBinding],
        installed: Bool,
        selected: Bool
    ) {
        let action = installed ? (selected ? "Generated, installed, and selected" : "Generated and installed") : "Generated"
        print("\(action) \"\(generated.resolvedGameName)\"")
        print("Source: \(generated.source)")
        print("Confidence: \(generated.confidence.rawValue)")
        for note in generated.notes { print("- \(note)") }
        print("\nBindings:")
        for button in GameButton.allCases {
            guard let binding = macBindings[button], generated.keyBindings[button] != nil else { continue }
            let label = generatedLabel(for: button, in: generated.profile.customization)
            print("- \(label): \(binding.displayName)")
        }
        printControlSizes(for: generated.profile.customization)
    }

    /// Agents cannot judge "small" from scale multipliers alone, so surface the
    /// real rendered point size of every control on the reference editor canvas.
    /// Anything under 66pt on its shortest side gets an explicit grow hint.
    private static func printControlSizes(for customization: GamepadCustomization) {
        let canvas = customization.deviceCanvas.editorDeviceFrame.screenRect.size
        guard canvas.width > 1, canvas.height > 1 else { return }
        let controls = customization.resolvedControls(in: canvas).filter { !$0.isDecoration }
        guard !controls.isEmpty else { return }

        let comfortableMinimum: CGFloat = 66
        var smallControls: [String] = []
        print("\nControl sizes (\(Int(canvas.width.rounded()))×\(Int(canvas.height.rounded()))pt reference canvas, controlScale \(customization.controlScale.rawValue)):")
        for control in controls {
            let line = "- \(control.label): \(Int(control.size.width.rounded()))×\(Int(control.size.height.rounded()))pt"
            if min(control.size.width, control.size.height) < comfortableMinimum {
                smallControls.append(control.label)
                print("\(line)  ⚠ small — raise widthScale/heightScale to ≥1.2 for thumb-sized input")
            } else {
                print(line)
            }
        }
        if !smallControls.isEmpty {
            print("Controls under \(Int(comfortableMinimum))pt: \(smallControls.joined(separator: ", ")). Aim for ≥66pt on the shortest side; primary actions ≥90pt.")
        }
    }

    private static func generatedLabel(for button: GameButton, in customization: GamepadCustomization) -> String {
        if let customButton = customization.customButtons.first(where: { $0.mappedButton == button }) {
            return customButton.visualLabel(fallback: button.displayName)
        }
        return customization.visualLabel(for: button, defaultLabel: button.displayName)
    }

    private static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        print(String(decoding: data, as: UTF8.self))
    }

    private static func writeJSON<T: Encodable>(_ value: T, to path: String?) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        if let path, path != "-" {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } else {
            print(String(decoding: data, as: UTF8.self))
        }
    }

    private static func replayOnboarding() throws {
        resetOnboardingDefaults()
        terminateRunningAppIfNeeded()
        try openApp()
    }

    private static func resetOnboardingDefaults() {
        var domain = loadAppDomain()
        domain[ThumbleMacIPC.onboardingCompletedDefaultsKey] = false
        domain[ThumbleMacIPC.editorFirstKeypadOnboardingCompletedDefaultsKey] = false
        domain[ThumbleMacIPC.editorFirstKeypadOnboardingReplayRequestedDefaultsKey] = true
        UserDefaults.standard.setPersistentDomain(domain, forName: appDefaultsDomain)
        UserDefaults.standard.synchronize()
    }

    private static func terminateRunningAppIfNeeded() {
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: appDefaultsDomain)
        guard !runningApps.isEmpty else { return }
        for app in runningApps {
            app.terminate()
        }

        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline, runningApps.contains(where: { !$0.isTerminated }) {
            Thread.sleep(forTimeInterval: 0.05)
        }

        for app in runningApps where !app.isTerminated {
            app.forceTerminate()
        }
    }

    private static func openApp() throws {
        try runProcess("/usr/bin/open", arguments: ["-b", appDefaultsDomain])
        Thread.sleep(forTimeInterval: 0.35)
    }

    private static func quitApp() throws {
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: appDefaultsDomain)
            .filter { !$0.isTerminated }
        for runningApp in runningApps where !runningApp.terminate() {
            throw CLIError.message("Could not request Thumble Mac to quit.")
        }
    }

    private struct RelayStatus: Encodable {
        var linked: Bool
        var tokenFile: String
        var relayURL: String
        var online: Bool?
        var manifestPublished: Bool?
    }

    private struct RelayDeviceStatus: Decodable {
        var online: Bool
        var manifestPublished: Bool?
        var deviceName: String?
    }

    private final class RelayStatusBox: @unchecked Sendable {
        var online: Bool?
        var manifestPublished: Bool?
        var deviceName: String?
    }

    private struct RelayDoctorCheck: Decodable {
        var id: String
        var label: String
        var status: String
        var detail: String
        var fix: String?
    }

    private struct RelayDoctorReport: Decodable {
        var ready: Bool
        var checks: [RelayDoctorCheck]
    }

    private struct RelayCLIOptions {
        var url = ProcessInfo.processInfo.environment["THUMBLE_MCP_RELAY_URL"] ?? "wss://thumble-mcp-gateway.fly.dev/tunnel"
        var tokenFile: String?
        var deviceName: String?
        var binary: String?
        var allowConfigurationWrite = false
        var allowInput = false
        var json = false
    }

    private static func relay(arguments: [String]) throws {
        guard let command = arguments.first else {
            throw CLIError.message("Usage: thumble relay connect|link|rotate|status|doctor|install|uninstall|revoke [--url wss://thumble-mcp-gateway.fly.dev/tunnel]")
        }
        var options = RelayCLIOptions()
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--url":
                index += 1
                guard index < arguments.count else { throw CLIError.message("--url requires a value") }
                options.url = arguments[index]
            case "--token-file":
                index += 1
                guard index < arguments.count else { throw CLIError.message("--token-file requires a path") }
                options.tokenFile = arguments[index]
            case "--device-name":
                index += 1
                guard index < arguments.count else { throw CLIError.message("--device-name requires a value") }
                options.deviceName = arguments[index]
            case "--binary":
                index += 1
                guard index < arguments.count else { throw CLIError.message("--binary requires a path") }
                options.binary = arguments[index]
            case "--allow-config-write":
                options.allowConfigurationWrite = true
            case "--allow-input":
                options.allowInput = true
            case "--json":
                options.json = true
            default:
                throw CLIError.message("Unknown relay option: \(arguments[index])")
            }
            index += 1
        }

        switch command {
        case "connect", "start":
            var relayArguments = ["--relay", options.url]
            if let tokenFile = options.tokenFile {
                relayArguments += ["--relay-token-file", tokenFile]
            }
            relayArguments += ["--relay-device-name", options.deviceName ?? defaultRelayDeviceName()]
            if options.allowConfigurationWrite {
                relayArguments.append("--allow-config-write")
            }
            if options.allowInput {
                relayArguments.append("--allow-input")
            }
            try runThumbleMCP(arguments: relayArguments)
        case "link", "rotate":
            var relayArguments = [command == "rotate" ? "--relay-relink" : "--relay-link", options.url]
            if let tokenFile = options.tokenFile {
                relayArguments += ["--relay-token-file", tokenFile]
            }
            relayArguments += ["--relay-device-name", options.deviceName ?? defaultRelayDeviceName()]
            if options.allowConfigurationWrite {
                relayArguments.append("--allow-config-write")
            }
            if options.allowInput {
                relayArguments.append("--allow-input")
            }
            try runThumbleMCP(arguments: relayArguments)
        case "revoke":
            var relayArguments = ["--relay-revoke", options.url]
            if let tokenFile = options.tokenFile {
                relayArguments += ["--relay-token-file", tokenFile]
            }
            try runThumbleMCP(arguments: relayArguments)
        case "status":
            let tokenFile = options.tokenFile ?? defaultRelayTokenPath()
            let linked = FileManager.default.fileExists(atPath: tokenFile)
            let remoteStatus = linked ? remoteRelayStatus(relayURL: options.url, tokenFile: tokenFile) : nil
            let online = linked ? remoteStatus?.online ?? false : false
            if options.json {
                try writeJSON(
                    RelayStatus(
                        linked: linked,
                        tokenFile: tokenFile,
                        relayURL: options.url,
                        online: linked ? remoteStatus?.online : false,
                        manifestPublished: linked ? remoteStatus?.manifestPublished : false
                    ),
                    to: nil
                )
            } else {
                print(linked ? "Relay linked (token present)." : "Relay not linked.")
                print("Token: \(tokenFile)")
                print("Gateway: \(options.url)")
                print("Online: \(online ? "yes" : "no")")
                if let manifestPublished = remoteStatus?.manifestPublished {
                    print("MCP manifest: \(manifestPublished ? "published" : "not published")")
                } else {
                    print("MCP manifest: unknown")
                }
            }
        case "doctor":
            try relayDoctor(options: options)
        case "install":
            try relayInstall(options: options)
        case "uninstall":
            try relayUninstall()
        default:
            throw CLIError.message("Usage: thumble relay connect|link|rotate|status|doctor|install|uninstall|revoke [--url URL] [--token-file PATH]")
        }
    }

    private static func remoteRelayStatus(relayURL: String, tokenFile: String) -> (online: Bool, manifestPublished: Bool?, deviceName: String?)? {
        guard
            let tokenData = FileManager.default.contents(atPath: tokenFile),
            let token = String(data: tokenData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !token.isEmpty,
            var components = URLComponents(string: relayURL)
        else { return nil }
        switch components.scheme {
        case "wss": components.scheme = "https"
        case "ws": components.scheme = "http"
        default: return nil
        }
        let basePath = components.path.hasSuffix("/tunnel")
            ? String(components.path.dropLast("/tunnel".count))
            : components.path
        components.path = basePath + "/device/status"
        components.query = nil
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let result = RelayStatusBox()
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard
                let response = response as? HTTPURLResponse,
                response.statusCode == 200,
                let data,
                let status = try? JSONDecoder().decode(RelayDeviceStatus.self, from: data)
            else { return }
            result.online = status.online
            result.manifestPublished = status.manifestPublished
            result.deviceName = status.deviceName
        }.resume()
        guard semaphore.wait(timeout: .now() + 11) == .success,
              let online = result.online
        else { return nil }
        return (online, result.manifestPublished, result.deviceName)
    }

    private static func defaultRelayTokenPath() -> String {
        if let configured = ProcessInfo.processInfo.environment["THUMBLE_HOST_STATE_DIR"], !configured.isEmpty {
            return URL(fileURLWithPath: configured).appendingPathComponent("relay-token").path
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ThumbleHost/relay-token")
            .path
    }

    /// Friendly default device name for gateway link pages: the Mac's
    /// hostname without the .local suffix, so multi-device users can tell
    /// their machines apart without passing --device-name manually.
    private static func defaultRelayDeviceName() -> String {
        let hostName = ProcessInfo.processInfo.hostName
        let trimmed = hostName.hasSuffix(".local") ? String(hostName.dropLast(".local".count)) : hostName
        return trimmed.isEmpty ? "Mac" : trimmed
    }

    private static let relayLaunchAgentLabel = "com.codybontecou.thumble.mcp-relay"

    private static func relayLaunchAgentPlistURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(relayLaunchAgentLabel).plist")
    }

    /// Merge the Rust-side local doctor report with gateway-side device
    /// status into one readiness report; non-zero exit when not ready.
    private static func relayDoctor(options: RelayCLIOptions) throws {
        var arguments = ["--relay-doctor", options.url, "--json"]
        if let tokenFile = options.tokenFile {
            arguments += ["--relay-token-file", tokenFile]
        }
        arguments += ["--relay-device-name", options.deviceName ?? defaultRelayDeviceName()]
        let captured = try runThumbleMCPCaptured(
            arguments: arguments,
            explicitBinary: options.binary
        )
        guard let data = captured.stdout.data(using: .utf8),
              let report = try? JSONDecoder().decode(RelayDoctorReport.self, from: data)
        else {
            throw CLIError.message("could not read the local relay doctor report: \(captured.stdout)")
        }

        let tokenFile = options.tokenFile ?? defaultRelayTokenPath()
        let linked = FileManager.default.fileExists(atPath: tokenFile)
        let remote = linked ? remoteRelayStatus(relayURL: options.url, tokenFile: tokenFile) : nil

        var checks = report.checks
        if let remote {
            checks.append(RelayDoctorCheck(
                id: "gateway",
                label: "Gateway device",
                status: remote.online ? "ok" : "fail",
                detail: remote.online
                    ? "device \(remote.deviceName ?? "Mac") is online at the gateway"
                    : "the device is not online at the gateway",
                fix: remote.online ? nil : "start the relay with `thumble relay connect`, or install the background service with `thumble relay install`"
            ))
            checks.append(RelayDoctorCheck(
                id: "manifest",
                label: "MCP manifest",
                status: (remote.manifestPublished ?? false) ? "ok" : "fail",
                detail: (remote.manifestPublished ?? false)
                    ? "published for connector validation"
                    : "not published yet",
                fix: (remote.manifestPublished ?? false) ? nil : "the relay publishes it automatically once connected; re-run `thumble relay doctor` after a few seconds"
            ))
        } else {
            checks.append(RelayDoctorCheck(
                id: "gateway",
                label: "Gateway device",
                status: "fail",
                detail: "could not reach the gateway device status endpoint",
                fix: "link the relay first (`thumble relay link`), then check the gateway URL and network"
            ))
        }

        let ready = checks.allSatisfy { $0.status != "fail" }
        if options.json {
            struct EncodableReport: Encodable {
                struct EncodableCheck: Encodable {
                    var id: String
                    var label: String
                    var status: String
                    var detail: String
                    var fix: String?
                }
                var ready: Bool
                var checks: [EncodableCheck]
            }
            try writeJSON(
                EncodableReport(
                    ready: ready,
                    checks: checks.map {
                        EncodableReport.EncodableCheck(
                            id: $0.id, label: $0.label, status: $0.status, detail: $0.detail, fix: $0.fix
                        )
                    }
                ),
                to: nil
            )
        } else {
            print("thumble relay doctor")
            for check in checks {
                let marker: String
                switch check.status {
                case "ok": marker = " ok"
                case "warn": marker = " !!"
                case "fail": marker = " XX"
                default: marker = " --"
                }
                print("  [\(marker)] \(check.label): \(check.detail)")
                if let fix = check.fix {
                    print("        fix: \(fix)")
                }
            }
            print("overall: \(ready ? "ready" : "not ready")")
        }
        if !ready {
            exit(1)
        }
    }

    /// Install (or update) the launch agent that keeps the relay running in
    /// the background, then start it immediately.
    private static func relayInstall(options: RelayCLIOptions) throws {
        let binary = try thumbleMCPExecutablePath(explicit: options.binary)
        let plistURL = relayLaunchAgentPlistURL()
        let logsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Thumble")
        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)

        var programArguments = [binary, "--relay", options.url]
        if let tokenFile = options.tokenFile {
            programArguments += ["--relay-token-file", tokenFile]
        }
        programArguments += ["--relay-device-name", options.deviceName ?? defaultRelayDeviceName()]
        if options.allowConfigurationWrite {
            programArguments.append("--allow-config-write")
        }
        if options.allowInput {
            programArguments.append("--allow-input")
        }
        let payload: [String: Any] = [
            "Label": relayLaunchAgentLabel,
            "ProgramArguments": programArguments,
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 10,
            "ProcessType": "Background",
            "StandardOutPath": logsDirectory.appendingPathComponent("mcp-relay.log").path,
            "StandardErrorPath": logsDirectory.appendingPathComponent("mcp-relay-error.log").path,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
        try data.write(to: plistURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plistURL.path)

        let uid = getuid()
        _ = try? runProcessForStatus("/bin/launchctl", arguments: ["bootout", "gui/\(uid)/\(relayLaunchAgentLabel)"])
        try runProcess("/bin/launchctl", arguments: ["bootstrap", "gui/\(uid)", plistURL.path])
        try runProcess("/bin/launchctl", arguments: ["kickstart", "-k", "gui/\(uid)/\(relayLaunchAgentLabel)"])
        print("Installed and started \(relayLaunchAgentLabel)")
        print("Logs: \(logsDirectory.path)")
        print("Status: launchctl print gui/\(uid)/\(relayLaunchAgentLabel)")
        print("Next: thumble relay doctor")
    }

    private static func relayUninstall() throws {
        let plistURL = relayLaunchAgentPlistURL()
        let uid = getuid()
        _ = try? runProcessForStatus("/bin/launchctl", arguments: ["bootout", "gui/\(uid)/\(relayLaunchAgentLabel)"])
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
        print("Removed \(relayLaunchAgentLabel)")
    }

    private static func thumbleMCPExecutablePath(explicit: String?) throws -> String {
        if let explicit {
            guard FileManager.default.isExecutableFile(atPath: explicit) else {
                throw CLIError.message("thumble-mcp is not executable: \(explicit)")
            }
            return explicit
        }
        let invokedCLI = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let sibling = invokedCLI.deletingLastPathComponent().appendingPathComponent("thumble-mcp").path
        if FileManager.default.isExecutableFile(atPath: sibling) {
            return sibling
        }
        let packaged = "/Applications/Thumble Host.app/Contents/MacOS/thumble-mcp"
        if FileManager.default.isExecutableFile(atPath: packaged) {
            return packaged
        }
        throw CLIError.message("thumble-mcp was not found next to the CLI or in /Applications/Thumble Host.app; pass --binary PATH")
    }

    @discardableResult
    private static func runThumbleMCPCaptured(arguments: [String], explicitBinary: String? = nil) throws -> (exitCode: Int32, stdout: String) {
        if let explicitBinary {
            guard FileManager.default.isExecutableFile(atPath: explicitBinary) else {
                throw CLIError.message("thumble-mcp is not executable: \(explicitBinary)")
            }
            return try runProcessCaptured(explicitBinary, arguments: arguments)
        }
        let invokedCLI = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let sibling = invokedCLI.deletingLastPathComponent().appendingPathComponent("thumble-mcp").path
        if FileManager.default.isExecutableFile(atPath: sibling) {
            return try runProcessCaptured(sibling, arguments: arguments)
        }
        let packaged = "/Applications/Thumble Host.app/Contents/MacOS/thumble-mcp"
        if FileManager.default.isExecutableFile(atPath: packaged) {
            return try runProcessCaptured(packaged, arguments: arguments)
        }
        return try runProcessCaptured("/usr/bin/env", arguments: ["thumble-mcp"] + arguments)
    }

    @discardableResult
    private static func runProcessCaptured(_ executable: String, arguments: [String]) throws -> (exitCode: Int32, stdout: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    @discardableResult
    private static func runProcessForStatus(_ executable: String, arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private static func runThumbleMCP(arguments: [String]) throws {
        let invokedCLI = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let sibling = invokedCLI.deletingLastPathComponent().appendingPathComponent("thumble-mcp").path
        if FileManager.default.isExecutableFile(atPath: sibling) {
            try runProcess(sibling, arguments: arguments)
            return
        }
        let packaged = "/Applications/Thumble Host.app/Contents/MacOS/thumble-mcp"
        if FileManager.default.isExecutableFile(atPath: packaged) {
            try runProcess(packaged, arguments: arguments)
            return
        }
        try runProcess("/usr/bin/env", arguments: ["thumble-mcp"] + arguments)
    }

    private static func runProcess(_ executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CLIError.message("Command failed: \(executable) \(arguments.joined(separator: " "))") }
    }

    private static func printHelp() {
        print("""
        thumble — configure and control Thumble Mac from the command line

        Remote connector relay:
          thumble relay connect [--allow-config-write] [--token-file PATH]
          thumble relay link [--url wss://thumble-mcp-gateway.fly.dev/tunnel]
          thumble relay rotate [--url wss://thumble-mcp-gateway.fly.dev/tunnel]
          thumble relay status [--json]
          thumble relay doctor [--json] [--binary PATH]
          thumble relay install [--allow-config-write] [--binary PATH]
          thumble relay uninstall
          thumble relay revoke [--url URL] [--token-file PATH]

          Primary linking flow: click Connect for Thumble in ChatGPT, then
          click Allow on this Mac. The displayed code is only a headless fallback.

        Generation:
          thumble generate "Hollow Knight" [--json] [--dry-run]
          thumble generate --spec agent-keypad.json [--layout-preview preview.png]
          thumble install-spec agent-keypad.json

        Profiles:
          thumble profile list [--ids|--json]
          thumble profile show [active|default|NAME|UUID] [--json]
          thumble profile create NAME [--blank|--template TEMPLATE|--from PROFILE]
          thumble profile select NAME|UUID
          thumble profile default NAME|UUID
          thumble profile rename NAME|UUID NEW_NAME
          thumble profile duplicate [NAME|UUID] [NEW_NAME]
          thumble profile delete NAME|UUID [NAME|UUID ...]
          thumble profile move NAME|UUID [NAME|UUID ...] --to INDEX|--before PROFILE|--after PROFILE
          thumble profile reset [NAME|UUID]
          thumble profile attach-app [NAME|UUID|--profile PROFILE] --path /Applications/App.app
          thumble profile attach-app [NAME|UUID|--profile PROFILE] --bundle-id com.example.App
          thumble profile detach-app [NAME|UUID|--profile PROFILE]
          thumble profile launch [NAME|UUID|--profile PROFILE]
          thumble profile export [NAME|UUID|--all] [-o file.json]
          thumble profile import file.json [--default] [--append]

        Templates:
          thumble template list
          thumble template install nes [--name "My NES"] [--default]
          thumble template install softWhite [--name "Soft Pad"]

        Themes:
          thumble theme list
          thumble theme show cavern-glow
          thumble theme apply cavern-glow [--profile PROFILE]
          thumble theme apply soft-white-controller [--profile PROFILE]

        Shareable skins and authoring (.pocketpad):
          thumble skin artboard list [--json]
          thumble skin artboard show ARTBOARD [--json]
          thumble skin artboard export ARTBOARD -o profile.json
          thumble skin scaffold NAME --identifier REVERSE.DNS.ID [--artboard ARTBOARD] [-o DIRECTORY] [--force]
          thumble skin compile SOURCE [-o skin.pocketpad] [--build-directory DIRECTORY] [--clean] [--strict] [--json]
          thumble skin preview SOURCE|PACKAGE -o OUTPUT [--artboard ARTBOARD] [--all-variants] [--all-states] [--orientation all|portrait|landscape] [--appearance all|light|dark] [--state all|normal|pressed|active|disabled] [--native-renderer] [--contact-sheet] [--columns N] [--render-scale 0.5...4]
          thumble skin quality SOURCE|PACKAGE [--artboard ARTBOARD] [--strict] [--json]
          thumble skin list [--json]
          thumble skin inspect PACKAGE|IDENTIFIER[@VERSION] [--json]
          thumble skin validate PACKAGE|DIRECTORY [--strict] [--json]
          thumble skin import PACKAGE|DIRECTORY [--replace|--allow-downgrade]
          thumble skin apply PACKAGE|IDENTIFIER[@VERSION] [--profile PROFILE] [--appearance light|dark]
          thumble skin detach [PROFILE|--profile PROFILE]
          thumble skin remove IDENTIFIER[@VERSION]
          thumble skin export IDENTIFIER[@VERSION] -o skin.pocketpad
          thumble skin pack DIRECTORY -o skin.pocketpad
          thumble skin unpack skin.pocketpad -o DIRECTORY [--force]
          thumble skin render SOURCE|PACKAGE -o OUTPUT [same options as skin preview]

        Bindings:
          thumble binding list [--profile PROFILE]
          thumble binding display [--profile PROFILE] [--json]
          thumble binding set jump Return
          thumble binding set focus --sequence 'Control+B,H'
          thumble binding reset jump
          thumble binding reset-all
          thumble output list [--profile PROFILE]
          thumble output mode keyboard|controller|custom [--profile PROFILE]
          thumble output set jump --keyboard Space --gamepad south
          thumble output set custom5 --clear-keyboard --gamepad leftTriggerButton

        Customization:
          thumble customization set --appearance dark --device iphone-17-pro --background '#101014'
          thumble customization set --background-gradient '#101014,#4338CA' --gradient-angle 45
          thumble customization set --device iphone-17-pro --orientation landscape
          thumble customization set --variant portrait --device iphone-17-pro --orientation portrait
          thumble customization export -o customization.json [--variant portrait|landscape]
          thumble orientation get [--profile PROFILE] [--json]
          thumble orientation set automatic|portrait|landscape [--profile PROFILE]
          thumble orientation copy landscape portrait [--profile PROFILE] [--no-arrange]
          thumble orientation arrange portrait [--from landscape] [--profile PROFILE]
          thumble layout validate [PROFILE|--profile PROFILE] [--variant portrait|landscape] [--json|--strict]
          thumble layout fix|repair|autofix [all|small-control|control-overlap|expanded-hit-overlap|edge-hugging-control|thumb-reach|coverage] [--repair hit-targets|ergonomic] [--profile PROFILE] [--variant portrait|landscape] [--unlock] [--json]
          thumble layout preview [PROFILE|--profile PROFILE] -o preview.png [--variant portrait|landscape] [--canvas iphone-17-pro-landscape]
          thumble device list
          thumble device set iphone-17-pro --orientation landscape
          thumble device set custom --size 844x390
          thumble control-bar list
          thumble control-bar set status,profiles,spacer,edit,settings,home,connection
          thumble control-bar remove home
          thumble control-bar item set settings --icon sf:slider.horizontal.3 --fill '#111827' --corner 12
          thumble control-bar item set connection --width 1.25 --height 1.1
          thumble control-bar item reset settings
          thumble element list
          thumble element add button --label Fire --keyboard Space --gamepad south --x 0.5 --y 0.8 --light-fill '#6B7280' --dark-fill '#374151'
          thumble element add joystick --label "Right Stick" --fill '#111827' --thumb-fill '#F8FAFC' --part up --keyboard W
          thumble element add joystick --label Nub --thumbstick --target right-stick --no-digital-directions --x 0.5 --y 0.58
          thumble element add trigger --target left --orientation horizontal --sensitivity 1.2
          thumble element add trackpad --label Trackpad --x 0.5 --y 0.58 --width 1.4 --sensitivity 1.2 --tap-to-click true
          thumble element add text --text Z --x 0.5 --y 0.5 --width 1.2 --height 0.8 --text-color '#FFFFFF'
          thumble element add decoration --label Shell --material soft-white-plate --x 0.5 --y 0.5 --width 3.2 --height 1.5 --shape rounded_rectangle
          thumble element set jump --keyboard Space --gamepad south --hide-integrated-label
          thumble element set "Text" --text Jump --text-color '#FFFFFF'
          thumble element set jump --clear-label
          thumble element set jump --skin-role primary-action --hit-insets 16
          thumble element set "Menu" --visual-role menu --hit-insets 10,18,14,18
          thumble element set jump --clear-visual-role --clear-hit-insets
          thumble element set jump --variant portrait --label A --light-fill '#7C3AED' --dark-fill '#C4B5FD' --shape circle --width 1.2 --height 1.2 --z-index 10
          thumble element set "Right Stick" --thumb-fill '#22C55E'
          thumble element set jump --fill-gradient '#000000,#666666' --gradient-angle 0
          thumble element set jump --fill-tile dots --tile-foreground '#FFFFFF' --tile-background '#111111'
          thumble element set jump --fill-image ./button-texture.png --image-mode fill
          thumble element set focus --icon sf:sparkles --haptic medium --haptic-pattern double --haptic-intensity 75% --haptic-duration 70ms --stroke '#38BDF8' --pressed-fill '#0EA5E9' --glow '#0EA5E9'
          thumble element set jump --text-color '#7C61A8' --inner-shadow '#B8B2C2' --inner-shadow-radius 5 --highlight '#FFFFFF' --highlight-opacity 45% --highlight-x -4 --highlight-y -4 --bevel-width 1.5
          thumble element set jump --material soft-white --shadow-layers '#FFFFFF,14,-7,-7,96%;#9B91AA,20,8,9,24%'
          thumble element set control-bar --x 0.2 --y 0.08 --width 1.4 --height 1.1
          thumble element duplicate builtin.jump [--offset 0.025] [--profile PROFILE] [--variant portrait]
          thumble element align top jump attack dash
          thumble element distribute horizontal-spacing jump attack dash focus
          thumble element nudge jump right --step 10 --canvas iphone-17-pro-landscape
          thumble style create SoftWhite --material soft-white --fill '#F8F6F7' --text-color '#7C61A8'
          thumble style create Soul --fill '#F8FAFC' --stroke '#38BDF8' --pressed-fill '#0EA5E9' --icon sf:sparkles
          thumble style rename soul "Soul Button"
          thumble style import styles.json --merge
          thumble style apply soul focus
          thumble layer list
          thumble layer front focus
          thumble group create Actions jump attack dash focus
          thumble group list --tree
          thumble group rename Actions "Face Buttons" [--profile PROFILE] [--variant landscape]
          thumble group duplicate Actions --name "Actions Copy" --offset 0.025
          thumble group nudge Actions right --step 10 --canvas iphone-17-pro-landscape
          thumble group front Actions
          thumble asset import ./icon.png --role icon --name SoulOrb
          thumble asset show ASSET_ID
          thumble asset set ASSET_ID --name "Soul Orb" --role texture

        Runtime:
          thumble app open|quit|replay-onboarding
          thumble app screenshot [-o thumble.png] [--window-title TITLE] [--json]
          thumble status [--json]
          thumble monitor [--jsonl] [--clear] [--from-start] [--duration seconds]
          thumble latency simulate [--pattern hollow-knight] [--mode compare] [--log report.json]
          thumble latency verify [--max-ms 4] [--p95-ms 4] [--log report.json]
          thumble server start|stop|restart|addresses
          thumble pairing code|payload|cancel
          thumble accessibility status|prompt|open|refresh
          thumble test tap jump
          thumble test tap --element UUID[#part] [--hold-ms 120]
          thumble release-all
        """)
    }
}

private enum CLIError: LocalizedError {
    case helpRequested
    case message(String)
    case validationFailed(String)

    var errorDescription: String? {
        switch self {
        case .helpRequested:
            "Help requested"
        case .message(let message), .validationFailed(let message):
            message
        }
    }
}
