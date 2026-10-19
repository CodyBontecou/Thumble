import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MacSkinLibraryView: View {
    @EnvironmentObject private var server: MacControllerServer
    @Environment(\.colorScheme) private var colorScheme

    let onCustomizeProfile: (UUID) -> Void
    let onShareProfile: (UUID) -> Void

    @State private var previewActionSet: ThumbleActionSet = .base
    @State private var isImporting = false
    @State private var pendingImport: MacPendingSkinImport?
    @State private var libraryError: String?
    @State private var isExportingSkin = false
    @State private var exportDocument = ThumbleSkinPackageDocument(package: ThumbleBundledSkins.packages[0])
    @State private var exportFilename = "Thumble-Skin.pocketpad"

    private let grid = [GridItem(.adaptive(minimum: 300, maximum: 440), spacing: Geist.Spacing.s4)]

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: Geist.Spacing.s8) {
                header
                Picker("Preview action set", selection: $previewActionSet) {
                    ForEach(ThumbleActionSet.allCases) { actionSet in
                        Text(actionSet.displayName).tag(actionSet)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 400)
                .accessibilityHint("Preview the appearance shown while holding controller triggers.")
                myKeypadsSection
                installedSkinsSection
            }
            .padding(Geist.Spacing.s8)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .geistScreenBackground()
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.thumbleSkinPackage, .zip],
            allowsMultipleSelection: false,
            onCompletion: handleImportSelection
        )
        .fileExporter(
            isPresented: $isExportingSkin,
            document: exportDocument,
            contentType: .thumbleSkinPackage,
            defaultFilename: exportFilename
        ) { result in
            if case .failure(let error) = result,
               (error as? CocoaError)?.code != .userCancelled {
                libraryError = error.localizedDescription
            }
        }
        .sheet(item: $pendingImport) { pending in
            MacSkinImportReviewSheet(
                pending: pending,
                previewCustomization: previewCustomization(for: pending.package),
                onCancel: { pendingImport = nil },
                onInstall: { install(pending) }
            )
            .frame(minWidth: 680, idealWidth: 760, minHeight: 560, idealHeight: 660)
        }
        .alert(
            "Skin Library",
            isPresented: Binding(
                get: { libraryError != nil },
                set: { if !$0 { libraryError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { libraryError = nil }
        } message: {
            Text(libraryError ?? "The skin operation could not be completed.")
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Geist.Spacing.s6) {
                headerCopy
                Spacer(minLength: Geist.Spacing.s6)
                importButton
            }
            VStack(alignment: .leading, spacing: Geist.Spacing.s4) {
                headerCopy
                importButton
            }
        }
    }

    private var headerCopy: some View {
        VStack(alignment: .leading, spacing: Geist.Spacing.s2) {
            Label("Skins & Keypads", systemImage: "paintpalette.fill")
                .geistTypography(.heading32)
                .foregroundStyle(Geist.color(.gray1000, scheme: colorScheme))
            Text("Keep layouts and Mac bindings yours while swapping shareable visual styles. Every control stays native, accessible, and editable.")
                .geistTypography(.copy16)
                .foregroundStyle(Geist.color(.gray900, scheme: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var importButton: some View {
        Button {
            isImporting = true
        } label: {
            Label("Import .pocketpad", systemImage: "square.and.arrow.down")
        }
        .geistButtonStyle(.primary)
    }

    private var myKeypadsSection: some View {
        VStack(alignment: .leading, spacing: Geist.Spacing.s4) {
            sectionHeader(
                title: "My Keypads",
                subtitle: "Your geometry, labels, shortcuts, and controller mappings. Skins only layer appearance on top.",
                systemImage: "rectangle.grid.2x2.fill"
            )

            LazyVGrid(columns: grid, alignment: .leading, spacing: Geist.Spacing.s4) {
                ForEach(server.gamepadProfiles) { profile in
                    keypadCard(profile)
                }
            }
        }
    }

    private var installedSkinsSection: some View {
        VStack(alignment: .leading, spacing: Geist.Spacing.s4) {
            sectionHeader(
                title: "Installed Skins",
                subtitle: "Appearance-only packages stored in Application Support and synced to the connected iPhone.",
                systemImage: "swatchpalette.fill"
            )

            if server.installedSkins.isEmpty {
                ContentUnavailableView(
                    "No Skins Installed",
                    systemImage: "paintpalette",
                    description: Text("Import a .pocketpad file to start your visual library.")
                )
                .frame(maxWidth: .infinity, minHeight: 220)
                .geistPanel()
            } else {
                LazyVGrid(columns: grid, alignment: .leading, spacing: Geist.Spacing.s4) {
                    ForEach(server.installedSkins) { installed in
                        skinCard(installed)
                    }
                }
            }
        }
    }

    private func sectionHeader(title: String, subtitle: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: Geist.Spacing.s1) {
            Label(title, systemImage: systemImage)
                .geistTypography(.heading24)
                .foregroundStyle(Geist.color(.gray1000, scheme: colorScheme))
            Text(subtitle)
                .geistTypography(.copy14)
                .foregroundStyle(Geist.color(.gray900, scheme: colorScheme))
        }
    }

    private func keypadCard(_ profile: GamepadConfigurationProfile) -> some View {
        let skin = profile.skinReference.flatMap { reference in
            server.installedSkins.first { $0.reference == reference }
        }
        return VStack(alignment: .leading, spacing: Geist.Spacing.s3) {
            MacKeypadMiniPreview(
                customization: resolvedCustomization(for: profile),
                defaultLabelProvider: { server.recordedShortcutLabel(for: $0) }
            )
            .frame(height: 176)
            .background(Geist.color(.gray100, scheme: colorScheme), in: RoundedRectangle(cornerRadius: Geist.Radius.md, style: .continuous))

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: Geist.Spacing.s1) {
                    Text(profile.name)
                        .geistTypography(.heading20)
                        .foregroundStyle(Geist.color(.gray1000, scheme: colorScheme))
                        .lineLimit(1)
                    Text(skin.map { "Skin: \($0.manifest.name) \($0.reference.version)" } ?? "Local appearance")
                        .geistTypography(.copy13)
                        .foregroundStyle(Geist.color(.gray900, scheme: colorScheme))
                        .lineLimit(1)
                }
                Spacer()
                if profile.id == server.activeGamepadProfileID {
                    Text("ACTIVE")
                        .geistTypography(.label12)
                        .foregroundStyle(Geist.color(.blue900, scheme: colorScheme))
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: Geist.Spacing.s2) { keypadActions(profile) }
                VStack(alignment: .leading, spacing: Geist.Spacing.s2) { keypadActions(profile) }
            }
        }
        .padding(Geist.Spacing.s4)
        .geistPanel()
    }

    @ViewBuilder
    private func keypadActions(_ profile: GamepadConfigurationProfile) -> some View {
        Button {
            server.selectGamepadProfile(profile.id)
        } label: {
            Label(profile.id == server.activeGamepadProfileID ? "Active" : "Use", systemImage: profile.id == server.activeGamepadProfileID ? "checkmark.circle.fill" : "play.fill")
        }
        .geistButtonStyle(profile.id == server.activeGamepadProfileID ? .secondary : .primary)
        .disabled(profile.id == server.activeGamepadProfileID)

        Button {
            server.selectGamepadProfile(profile.id)
            onCustomizeProfile(profile.id)
        } label: {
            Label("Customize", systemImage: "slider.horizontal.3")
        }
        .geistButtonStyle(.secondary)

        Menu {
            Button {
                onShareProfile(profile.id)
            } label: {
                Label("Share Keypad Backup", systemImage: "square.and.arrow.up")
            }
            if profile.skinReference != nil {
                Button {
                    do { try server.detachSkin(from: profile.id) }
                    catch { libraryError = error.localizedDescription }
                } label: {
                    Label("Detach Skin", systemImage: "paintpalette.fill")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
    }

    private func skinCard(_ installed: ThumbleInstalledSkin) -> some View {
        let package = try? server.skinPackage(for: installed.reference)
        return VStack(alignment: .leading, spacing: Geist.Spacing.s3) {
            if let package {
                MacKeypadMiniPreview(
                    customization: previewCustomization(for: package),
                    defaultLabelProvider: { server.recordedShortcutLabel(for: $0) }
                )
                .frame(height: 176)
                .background(Geist.color(.gray100, scheme: colorScheme), in: RoundedRectangle(cornerRadius: Geist.Radius.md, style: .continuous))
            }

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: Geist.Spacing.s1) {
                    Text(installed.manifest.name)
                        .geistTypography(.heading20)
                        .foregroundStyle(Geist.color(.gray1000, scheme: colorScheme))
                    Text("by \(installed.manifest.author.name) · v\(installed.reference.version)")
                        .geistTypography(.copy13)
                        .foregroundStyle(Geist.color(.gray900, scheme: colorScheme))
                }
                Spacer()
                if installed.isBundled {
                    Text("BUILT IN")
                        .geistTypography(.label12)
                        .foregroundStyle(Geist.color(.blue900, scheme: colorScheme))
                }
            }

            if !installed.manifest.summary.isEmpty {
                Text(installed.manifest.summary)
                    .geistTypography(.copy13)
                    .foregroundStyle(Geist.color(.gray900, scheme: colorScheme))
                    .lineLimit(3)
            }

            HStack(spacing: Geist.Spacing.s2) {
                Label(installed.manifest.license, systemImage: "checkmark.seal")
                if !installed.manifest.tags.isEmpty {
                    Text(installed.manifest.tags.prefix(2).joined(separator: " · "))
                }
            }
            .geistTypography(.label12)
            .foregroundStyle(Geist.color(.gray800, scheme: colorScheme))
            .lineLimit(1)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: Geist.Spacing.s2) { skinActions(installed, package: package) }
                VStack(alignment: .leading, spacing: Geist.Spacing.s2) { skinActions(installed, package: package) }
            }
        }
        .padding(Geist.Spacing.s4)
        .geistPanel()
    }

    @ViewBuilder
    private func skinActions(_ installed: ThumbleInstalledSkin, package: ThumbleSkinPackage?) -> some View {
        Button {
            apply(installed.reference, customize: false)
        } label: {
            Label("Apply", systemImage: "paintbrush.fill")
        }
        .geistButtonStyle(.primary)

        Button {
            apply(installed.reference, customize: true)
        } label: {
            Label("Customize", systemImage: "slider.horizontal.3")
        }
        .geistButtonStyle(.secondary)

        Menu {
            Button {
                guard let package else { return }
                exportDocument = ThumbleSkinPackageDocument(package: package)
                exportFilename = suggestedFilename(for: installed.manifest)
                isExportingSkin = true
            } label: {
                Label("Share Skin", systemImage: "square.and.arrow.up")
            }
            .disabled(package == nil)

            if let homepage = installed.manifest.homepage {
                Link(destination: homepage) {
                    Label("Creator Website", systemImage: "safari")
                }
            }

            if !installed.isBundled {
                Divider()
                Button(role: .destructive) {
                    do { try server.removeSkin(installed.reference) }
                    catch { libraryError = error.localizedDescription }
                } label: {
                    Label("Remove Skin", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
    }

    private func resolvedCustomization(for profile: GamepadConfigurationProfile) -> GamepadCustomization {
        let local = profile.customization(for: .landscape)
        let scheme = local.resolvedColorScheme(system: colorScheme)
        return profile.resolvedCustomization(
            for: .landscape,
            colorScheme: scheme == .dark ? .dark : .light,
            skinPackage: profile.skinReference.flatMap { try? server.skinPackage(for: $0) },
            actionSet: previewActionSet
        )
    }

    private func previewCustomization(for package: ThumbleSkinPackage) -> GamepadCustomization {
        let source = server.gamepadProfiles
            .first(where: { $0.id == server.activeGamepadProfileID })?
            .customization(for: .landscape) ?? server.gamepadCustomization
        return source.applying(
            skinPackage: package,
            orientation: .landscape,
            colorScheme: colorScheme == .dark ? .dark : .light,
            options: .replacingAppearance,
            actionSet: previewActionSet
        )
    }

    private func apply(_ reference: ThumbleSkinReference, customize: Bool) {
        do {
            try server.applySkin(
                reference,
                to: server.activeGamepadProfileID,
                colorScheme: colorScheme == .dark ? .dark : .light
            )
            if customize { onCustomizeProfile(server.activeGamepadProfileID) }
        } catch {
            libraryError = error.localizedDescription
        }
    }

    private func handleImportSelection(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let package = try ThumbleSkinPackageCodec.decode(data)
            guard package.skin != nil else { throw ThumbleSkinStoreError.packageHasNoSkin }
            pendingImport = MacPendingSkinImport(
                data: data,
                package: package,
                report: ThumbleSkinPackageValidator.validate(package)
            )
        } catch let error as CocoaError where error.code == .userCancelled {
            return
        } catch {
            libraryError = error.localizedDescription
        }
    }

    private func install(_ pending: MacPendingSkinImport) {
        do {
            _ = try server.installSkinPackage(data: pending.data, policy: .replaceSameVersion)
            pendingImport = nil
        } catch {
            pendingImport = nil
            libraryError = error.localizedDescription
        }
    }

    private func suggestedFilename(for manifest: ThumbleSkinManifest) -> String {
        let base = manifest.name
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "\(base.isEmpty ? "thumble-skin" : base)-\(manifest.version).pocketpad"
    }
}

private struct MacPendingSkinImport: Identifiable {
    let id = UUID()
    let data: Data
    let package: ThumbleSkinPackage
    let report: ThumbleSkinValidationReport
}

private struct MacSkinImportReviewSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    let pending: MacPendingSkinImport
    let previewCustomization: GamepadCustomization
    let onCancel: () -> Void
    let onInstall: () -> Void

    private var compatibility: ThumbleSkinCompatibilityEvaluation {
        let orientation: ThumbleSkinOrientation = previewCustomization.deviceCanvas.editorDeviceFrame.orientation == .portrait
            ? .portrait
            : .landscape
        return ThumbleSkinCompatibilityEvaluator.evaluate(
            pending.package.manifest.compatibility,
            customization: previewCustomization,
            orientation: orientation
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Geist.Spacing.s6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: Geist.Spacing.s1) {
                    Text("Review Skin")
                        .geistTypography(.heading32)
                    Text("Confirm the creator, package identity, and visual contents before installing.")
                        .geistTypography(.copy14)
                        .foregroundStyle(Geist.color(.gray900, scheme: colorScheme))
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .geistButtonStyle(.secondary)
            }

            MacKeypadMiniPreview(customization: previewCustomization)
                .frame(height: 250)
                .background(Geist.color(.gray100, scheme: colorScheme), in: RoundedRectangle(cornerRadius: Geist.Radius.md, style: .continuous))

            VStack(alignment: .leading, spacing: Geist.Spacing.s3) {
                metadataRow("Name", pending.package.manifest.name)
                metadataRow("Creator", pending.package.manifest.author.name)
                metadataRow("Package", "\(pending.package.manifest.identifier) · v\(pending.package.manifest.version)")
                metadataRow("License", pending.package.manifest.license)
                if !pending.package.manifest.summary.isEmpty {
                    metadataRow("About", pending.package.manifest.summary)
                }
            }

            Label(
                "Appearance only: this install cannot replace your keyboard shortcuts, controller mappings, launch targets, geometry, labels, or accessibility controls.",
                systemImage: "checkmark.shield.fill"
            )
            .geistTypography(.copy13)
            .foregroundStyle(Geist.color(.blue900, scheme: colorScheme))
            .padding(Geist.Spacing.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Geist.color(.blue100, scheme: colorScheme), in: RoundedRectangle(cornerRadius: Geist.Radius.sm, style: .continuous))

            if compatibility.status != .compatible {
                VStack(alignment: .leading, spacing: Geist.Spacing.s1) {
                    Label(
                        compatibility.status == .incompatible ? "Artwork does not match this keypad" : "Exact layout could not be confirmed",
                        systemImage: "rectangle.on.rectangle.slash"
                    )
                    ForEach(Array(compatibility.issues.enumerated()), id: \.offset) { _, issue in
                        Text(issue.message)
                    }
                    Text("Semantic materials remain safe to apply; template-aligned artwork is hidden.")
                }
                .geistTypography(.label12)
                .foregroundStyle(Geist.color(.amber900, scheme: colorScheme))
                .padding(Geist.Spacing.s3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Geist.color(.amber100, scheme: colorScheme), in: RoundedRectangle(cornerRadius: Geist.Radius.sm, style: .continuous))
            }

            if !pending.report.warnings.isEmpty {
                VStack(alignment: .leading, spacing: Geist.Spacing.s1) {
                    ForEach(pending.report.warnings) { warning in
                        Label(warning.message, systemImage: "exclamationmark.triangle")
                    }
                }
                .geistTypography(.label12)
                .foregroundStyle(Geist.color(.gray900, scheme: colorScheme))
            }

            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button(action: onInstall) {
                    Label("Install Skin", systemImage: "square.and.arrow.down.fill")
                }
                .geistButtonStyle(.primary)
                .disabled(!pending.report.isValid)
            }
        }
        .padding(Geist.Spacing.s6)
        .geistScreenBackground()
    }

    private func metadataRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Geist.Spacing.s3) {
            Text(title)
                .geistTypography(.label13)
                .foregroundStyle(Geist.color(.gray800, scheme: colorScheme))
                .frame(width: 72, alignment: .leading)
            Text(value)
                .geistTypography(.copy13)
                .foregroundStyle(Geist.color(.gray1000, scheme: colorScheme))
                .textSelection(.enabled)
        }
    }
}
