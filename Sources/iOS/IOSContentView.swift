import SwiftUI
import UIKit
import CoreHaptics
import UniformTypeIdentifiers

struct IOSContentView: View {
    @EnvironmentObject private var client: ControllerClient
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @AppStorage("macHost") private var macHost = "192.168.0.113"
    @AppStorage("macPort") private var macPort = "8765"
    @AppStorage("pairingCode") private var pairingCode = ""
    @AppStorage("PocketPad.iOS.onboarding.completed.v1") private var hasCompletedOnboarding = false
    @AppStorage(IOSKeypadSettings.immersiveModeDefaultsKey) private var prefersImmersiveKeypad = true
    @State private var prefersConnectionView = true
    @State private var isShowingOnboarding = false
    @State private var bypassesOnboardingForSharedBuild = false
    @StateObject private var artifactPickup = IOSBuilderArtifactPickupCoordinator()
    @State private var pendingSharedSkinImport: IOSPendingSkinImport?
    @State private var sharedSkinImportError: String?

    private let defaultMacHost = "192.168.0.113"
    private let defaultMacPort = "8765"

    private var shouldShowControllerPad: Bool {
        if client.isBuilderArtifactPracticePreviewActive { return true }
        return ControllerRuntimeChromePolicy.shouldShowControllerPad(
            prefersConnectionView: prefersConnectionView,
            isConnected: client.isConnected,
            canViewSavedKeypadOffline: client.canViewSavedKeypadOffline
        )
    }

    private var shouldPresentOnboarding: Bool {
        (!hasCompletedOnboarding && !bypassesOnboardingForSharedBuild) || isShowingOnboarding
    }

    var body: some View {
        lifecycleContent
    }

    private var rootContent: some View {
        ZStack {
            if shouldPresentOnboarding {
                IOSOnboardingView(
                    onStartSmartConnect: { client.startSmartConnect() },
                    onComplete: { completeOnboarding() }
                )
                .transition(accessibilityReduceMotion ? .identity : .opacity)
            } else {
                applicationContent
                    .transition(accessibilityReduceMotion ? .identity : .opacity)
            }
        }
        .environmentObject(artifactPickup)
        .animation(accessibilityReduceMotion ? nil : .easeInOut(duration: 0.24), value: shouldPresentOnboarding)
    }

    private var presentationContent: some View {
        rootContent
            .sheet(item: Binding(
                get: { artifactPickup.pendingReview },
                set: { if $0 == nil { cancelBuilderArtifactReview() } }
            )) { review in
                IOSBuilderArtifactReviewSheet(
                    review: review,
                    isKeeping: artifactPickup.isKeepingReview,
                    onCancel: { cancelBuilderArtifactReview() },
                    onPreviewAndKeep: { keepBuilderArtifact(review) }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .sheet(item: $pendingSharedSkinImport) { pending in
                IOSSkinImportReviewSheet(
                    pending: pending,
                    previewCustomization: sharedSkinPreview(for: pending.package),
                    showsHitAreas: false,
                    onCancel: { pendingSharedSkinImport = nil },
                    onInstall: { shouldApply in
                        installSharedSkin(pending, shouldApply: shouldApply)
                    }
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .alert(
                "Couldn’t Import Skin",
                isPresented: Binding(
                    get: { sharedSkinImportError != nil },
                    set: { if !$0 { sharedSkinImportError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { sharedSkinImportError = nil }
            } message: {
                Text(sharedSkinImportError ?? "The .pocketpad file could not be imported.")
            }
            .alert(
                "Couldn’t Open Shared Build",
                isPresented: Binding(
                    get: { artifactPickup.safeErrorMessage != nil },
                    set: { if !$0 { artifactPickup.safeErrorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { artifactPickup.safeErrorMessage = nil }
            } message: {
                Text(artifactPickup.safeErrorMessage ?? "The shared build could not be opened.")
            }
            .overlay {
                if artifactPickup.isFetching {
                    ProgressView("Checking shared build…")
                        .geistPanel(padding: Geist.Spacing.s4, radius: Geist.Radius.md)
                }
            }
    }

    private var lifecycleContent: some View {
        presentationContent
            .onOpenURL(perform: routeIncomingURL)
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                if let url = activity.webpageURL { routeIncomingURL(url) }
            }
            .onChange(of: artifactPickup.pendingReview?.id) { _, reviewID in
                if reviewID != nil {
                    bypassesOnboardingForSharedBuild = true
                    isShowingOnboarding = false
                }
            }
            .onAppear(perform: handleAppear)
            .onChange(of: client.isConnected) { _, isConnected in
                if isConnected { prefersConnectionView = false }
            }
            .onChange(of: client.builderArtifactAdoptionState) { _, adoption in
                guard let adoption else { return }
                Task {
                    await artifactPickup.applyAdoptionState(adoption)
                    if case .succeeded = adoption.phase {
                        if client.builderArtifactPracticePreview?.recordID == adoption.metadata.recordID {
                            client.endBuilderArtifactPracticePreview()
                        }
                        client.clearTerminalProfileArtifactAdoption(recordID: adoption.metadata.recordID)
                    }
                }
            }
    }

    private func handleAppear() {
        Task { await artifactPickup.refreshRecords() }
        if macHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            macHost = defaultMacHost
        }
        if macPort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            macPort = defaultMacPort
        }
        pairingCode = ""
        Self.migrateLegacyHapticPreferenceIfNeeded()
        if hasCompletedOnboarding { client.startSmartConnect() }
    }

    @ViewBuilder
    private var applicationContent: some View {
        let isShowingControllerPad = shouldShowControllerPad
        let hidesSystemOverlays = ControllerRuntimeChromePolicy.shouldHideSystemOverlays(
            isShowingController: isShowingControllerPad,
            userPrefersImmersiveMode: prefersImmersiveKeypad
        )

        ZStack {
            if isShowingControllerPad {
                ControllerPadView(
                    onShowConnectionPage: {
                        prefersConnectionView = true
                    },
                    onShowOnboarding: {
                        isShowingOnboarding = true
                    }
                )
                .ignoresSafeArea()
            } else {
                ConnectionView(
                    macHost: $macHost,
                    macPort: $macPort,
                    pairingCode: $pairingCode,
                    onShowSavedKeypad: {
                        prefersConnectionView = false
                    },
                    onShowOnboarding: {
                        isShowingOnboarding = true
                    }
                )
            }
        }
        .geistScreenBackground()
        .statusBarHidden(hidesSystemOverlays)
        .persistentSystemOverlays(hidesSystemOverlays ? .hidden : .automatic)
    }

    private func routeIncomingURL(_ url: URL) {
        if artifactPickup.route(url) == .handled { return }
        openSharedSkinURL(url)
    }

    private func cancelBuilderArtifactReview() {
        artifactPickup.cancelReview()
        if !hasCompletedOnboarding {
            bypassesOnboardingForSharedBuild = false
        }
    }

    private func keepBuilderArtifact(_ review: IOSBuilderArtifactReview) {
        Task {
            do {
                let (record, artifact) = try await artifactPickup.previewAndKeep(review)
                client.beginBuilderArtifactPracticePreview(recordID: record.id, artifact: artifact)
                bypassesOnboardingForSharedBuild = true
                isShowingOnboarding = false
                prefersConnectionView = false
            } catch {
                artifactPickup.safeErrorMessage = "The shared build could not be kept on this iPhone."
            }
        }
    }

    private func openSharedSkinURL(_ url: URL) {
        guard url.isFileURL,
              [ThumbleSkinStore.packageExtension, "zip"].contains(url.pathExtension.lowercased())
        else { return }
        do {
            pendingSharedSkinImport = try IOSPendingSkinImport.load(from: url)
            isShowingOnboarding = false
        } catch {
            sharedSkinImportError = error.localizedDescription
        }
    }

    private func sharedSkinPreview(for package: ThumbleSkinPackage) -> GamepadCustomization {
        let source = client.selectedGamepadProfile?.customization ?? client.gamepadCustomization
        let orientation = source.deviceCanvas.editorDeviceFrame.orientation
        return source.applying(
            skinPackage: package,
            orientation: orientation == .portrait ? .portrait : .landscape,
            colorScheme: colorSchemeForSharedImport,
            options: .replacingAppearance
        )
    }

    private var colorSchemeForSharedImport: ThumbleSkinColorScheme {
        colorScheme == .dark ? .dark : .light
    }

    private func installSharedSkin(_ pending: IOSPendingSkinImport, shouldApply: Bool) {
        do {
            let result = try client.installSkinPackage(data: pending.data, policy: .replaceSameVersion)
            pendingSharedSkinImport = nil
            if shouldApply {
                try client.applySkinToSelectedProfile(result.reference, colorScheme: colorSchemeForSharedImport)
                prefersConnectionView = false
            }
        } catch {
            pendingSharedSkinImport = nil
            sharedSkinImportError = error.localizedDescription
        }
    }

    private func completeOnboarding() {
        hasCompletedOnboarding = true
        isShowingOnboarding = false
        client.startSmartConnect()
    }

    private static func migrateLegacyHapticPreferenceIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: IOSKeypadPreferenceKeys.hapticIntensity) == nil else { return }
        if defaults.object(forKey: IOSKeypadPreferenceKeys.legacyHapticsEnabled) != nil,
           !defaults.bool(forKey: IOSKeypadPreferenceKeys.legacyHapticsEnabled) {
            defaults.set(0.0, forKey: IOSKeypadPreferenceKeys.hapticIntensity)
        } else {
            defaults.set(IOSKeypadPreferenceKeys.defaultHapticIntensity, forKey: IOSKeypadPreferenceKeys.hapticIntensity)
        }
    }
}

private struct IOSBuilderArtifactReviewSheet: View {
    let review: IOSBuilderArtifactReview
    let isKeeping: Bool
    let onCancel: () -> Void
    let onPreviewAndKeep: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Shared Build") {
                    LabeledContent("From", value: review.sourceHost)
                    LabeledContent("Profiles", value: "\(review.profileNames.count)")
                    LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: Int64(review.byteCount), countStyle: .file))
                    LabeledContent("Integrity", value: review.hashPrefix)
                }
                Section("Controller Profiles") {
                    ForEach(Array(review.profileNames.enumerated()), id: \.offset) { _, name in
                        Label(name, systemImage: "rectangle.grid.2x2")
                    }
                }
                Section {
                    Text("Preview runs only in Practice Mode. It will not send input or change profiles on your Mac.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Preview Shared Build")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: Geist.Spacing.s2) {
                    Button(isKeeping ? "Keeping…" : "Preview & Keep", action: onPreviewAndKeep)
                        .geistButtonStyle(.primary, size: .large)
                        .disabled(isKeeping)
                    Button("Cancel", role: .cancel, action: onCancel)
                        .disabled(isKeeping)
                        .geistButtonStyle(.tertiary, size: .medium)
                }
                .padding()
                .background(.ultraThinMaterial)
            }
        }
    }
}

private struct IOSPendingBuilderArtifactsPanel: View {
    @EnvironmentObject private var client: ControllerClient
    @EnvironmentObject private var artifactPickup: IOSBuilderArtifactPickupCoordinator
    @State private var adoptionConfirmationRecord: IOSPendingBuilderArtifactRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: Geist.Spacing.s3) {
            VStack(alignment: .leading, spacing: Geist.Spacing.s1) {
                Text("Pending Shared Builds")
                    .geistTypography(.heading20)
                Text("Kept only on this iPhone for Practice Mode. Nothing is installed on your Mac.")
                    .geistTypography(.copy14)
                    .foregroundStyle(.secondary)
            }
            ForEach(artifactPickup.pendingRecords) { record in
                VStack(alignment: .leading, spacing: Geist.Spacing.s2) {
                    Text(record.profiles.first?.name ?? "Shared Controller")
                        .geistTypography(.copy16)
                        .lineLimit(1)
                    Text("\(record.profiles.count) profile\(record.profiles.count == 1 ? "" : "s") • \(ByteCountFormatter.string(fromByteCount: Int64(record.bytes), countStyle: .file))")
                        .geistTypography(.copy14)
                        .foregroundStyle(.secondary)
                    if let status = adoptionStatus(for: record) {
                        Text(status)
                            .geistTypography(.copy14)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: Geist.Spacing.s2) {
                        Button("Preview") { preview(record) }
                            .geistButtonStyle(.secondary, size: .medium)
                        if client.supportsProfileArtifactAdoptionV1 {
                            Button(record.state == .failed ? "Retry on Mac" : "Adopt on Paired Mac") {
                                adoptionConfirmationRecord = record
                            }
                            .geistButtonStyle(.primary, size: .medium)
                            .disabled(isAnotherAdoptionActive(recordID: record.id))
                        }
                        Button("Delete", role: .destructive) { delete(record) }
                            .geistButtonStyle(.tertiary, size: .medium)
                            .disabled(record.state == .adopting)
                    }
                    if client.isConnected && !client.supportsProfileArtifactAdoptionV1 {
                        Text("Update Thumble Mac to adopt this shared build.")
                            .geistTypography(.copy14)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(Geist.Spacing.s3)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: Geist.Radius.sm))
            }
        }
        .geistPanel(padding: Geist.Spacing.s4, radius: Geist.Radius.md)
        .confirmationDialog(
            "Adopt Shared Build?",
            isPresented: Binding(
                get: { adoptionConfirmationRecord != nil },
                set: { if !$0 { adoptionConfirmationRecord = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Append Profiles and Select on Mac") {
                if let record = adoptionConfirmationRecord { adopt(record) }
                adoptionConfirmationRecord = nil
            }
            Button("Cancel", role: .cancel) { adoptionConfirmationRecord = nil }
        } message: {
            Text("The paired Mac will validate the artifact, append new profile copies, and select the imported active profile. Existing profiles and the default profile are not replaced.")
        }
    }

    private func adoptionStatus(for record: IOSPendingBuilderArtifactRecord) -> String? {
        guard let state = client.builderArtifactAdoptionState,
              state.metadata.recordID == record.id
        else {
            return record.state == .failed ? "Previous adoption did not finish. The artifact is still on this iPhone." : nil
        }
        switch state.phase {
        case .uploading(let sent, let total): return "Uploading \(sent) of \(total)…"
        case .awaitingAuthoritativeSnapshot: return "Imported; waiting for the Mac’s authoritative profile update…"
        case .succeeded: return "Adopted by the paired Mac."
        case .failed(let code): return "Adoption failed (\(code.rawValue)). The artifact was kept."
        }
    }

    private func isAnotherAdoptionActive(recordID _: UUID) -> Bool {
        guard let state = client.builderArtifactAdoptionState else { return false }
        switch state.phase {
        case .uploading, .awaitingAuthoritativeSnapshot:
            return true
        case .succeeded, .failed:
            return false
        }
    }

    private func adopt(_ record: IOSPendingBuilderArtifactRecord) {
        guard let serverID = client.pairedProfileArtifactAdoptionServerID else { return }
        Task {
            do {
                let (updated, artifact, operationID) = try await artifactPickup.prepareAdoption(
                    id: record.id,
                    intendedServerID: serverID
                )
                guard client.pairedProfileArtifactAdoptionServerID == serverID,
                      client.beginProfileArtifactAdoption(
                        record: updated,
                        artifact: artifact,
                        operationID: operationID
                      )
                else {
                    await artifactPickup.markAdoptionStartFailed(
                        recordID: record.id,
                        operationID: operationID
                    )
                    return
                }
            } catch {
                artifactPickup.safeErrorMessage = "The shared build could not be uploaded to the paired Mac."
            }
        }
    }

    private func preview(_ record: IOSPendingBuilderArtifactRecord) {
        Task {
            do {
                let (_, artifact) = try await artifactPickup.loadForPreview(id: record.id)
                client.beginBuilderArtifactPracticePreview(recordID: record.id, artifact: artifact)
            } catch {
                artifactPickup.safeErrorMessage = "The pending shared build could not be opened."
            }
        }
    }

    private func delete(_ record: IOSPendingBuilderArtifactRecord) {
        if client.builderArtifactPracticePreview?.recordID == record.id {
            client.endBuilderArtifactPracticePreview()
        }
        Task { await artifactPickup.delete(id: record.id) }
    }
}

private enum IOSKeypadSettings {
    static let immersiveModeDefaultsKey = "PocketPad.iOS.immersiveKeypad.v1"
}

private enum ThumbleSupportLinks {
    static let discord = URL(string: "https://discord.gg/RaQYS4t6gn")!
    static let newGitHubIssue = URL(string: "https://github.com/CodyBontecou/Thumble/issues/new")!
    static let discordPromoDismissedDefaultsKey = "PocketPad.iOS.discordPromoDismissed.v1"
}

private struct ConnectionView: View {
    @EnvironmentObject private var client: ControllerClient
    @EnvironmentObject private var artifactPickup: IOSBuilderArtifactPickupCoordinator
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Binding var macHost: String
    @Binding var macPort: String
    @Binding var pairingCode: String
    @AppStorage(IOSKeypadPreferenceKeys.hapticIntensity) private var keypadHapticIntensity = IOSKeypadPreferenceKeys.defaultHapticIntensity
    @AppStorage(IOSKeypadPreferenceKeys.showBindingGlyphs) private var showsBindingGlyphs = IOSKeypadPreferenceKeys.defaultShowBindingGlyphs
    @AppStorage(IOSKeypadSettings.immersiveModeDefaultsKey) private var prefersImmersiveKeypad = true
    @AppStorage(ThumbleSupportLinks.discordPromoDismissedDefaultsKey) private var isDiscordPromoDismissed = false
    let onShowSavedKeypad: () -> Void
    let onShowOnboarding: () -> Void

    @State private var isShowingScanner = false
    @State private var qrScanError: String?
    @State private var pendingPairingCode = ""

    private var keypadColorSchemePreferenceBinding: Binding<GamepadColorSchemePreference> {
        Binding(
            get: { client.gamepadCustomization.colorSchemePreference },
            set: { client.setKeypadColorSchemePreference($0) }
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let isWide = proxy.size.width > proxy.size.height && proxy.size.width >= 760

            ScrollView(.vertical) {
                Group {
                    if isWide {
                        HStack(alignment: .center, spacing: Geist.Spacing.s8) {
                            header
                                .frame(maxWidth: 380, alignment: .leading)
                            activePairingContent
                                .frame(maxWidth: 460)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: Geist.Spacing.s8) {
                            header
                            activePairingContent
                        }
                        .frame(maxWidth: 540)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, isWide ? Geist.Spacing.s10 : Geist.Spacing.s6)
                .padding(.vertical, isWide ? Geist.Spacing.s6 : Geist.Spacing.s8)
                .frame(minHeight: proxy.size.height, alignment: isWide ? .center : .top)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !isDiscordPromoDismissed {
                DiscordCommunityBanner {
                    withAnimation(accessibilityReduceMotion ? nil : .easeOut(duration: 0.2)) {
                        isDiscordPromoDismissed = true
                    }
                }
                .padding(.horizontal, Geist.Spacing.s4)
                .padding(.vertical, Geist.Spacing.s2)
                .transition(accessibilityReduceMotion ? .identity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .onChange(of: client.state) { _, newState in
            if newState == .pairingCodeRequired {
                pendingPairingCode = ""
            }
        }
        .sheet(isPresented: $isShowingScanner) {
            NavigationStack {
                QRCodeScannerView { scannedText in
                    handleScannedPairingCode(scannedText)
                }
                .ignoresSafeArea()
                .navigationTitle("Scan Thumble QR Code")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Close Scanner") {
                            isShowingScanner = false
                        }
                    }
                }
            }
        }
    }

    private var activePairingContent: some View {
        VStack(spacing: Geist.Spacing.s4) {
            if client.isAwaitingPairingCode {
                pairingCodePrompt
            } else {
                form
            }
            if !artifactPickup.pendingRecords.isEmpty {
                IOSPendingBuilderArtifactsPanel()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Geist.Spacing.s4) {
            Text("Thumble")
                .geistTypography(.heading40)
                .foregroundStyle(Geist.color(.gray1000, scheme: colorScheme))
                .lineLimit(1)
                .minimumScaleFactor(0.55)

            Text("Use this iPhone as a programmable shortcut keypad for your Mac.")
                .geistTypography(.copy16)
                .foregroundStyle(Geist.color(.gray900, scheme: colorScheme))
                .fixedSize(horizontal: false, vertical: true)

            StatusPill(title: client.state.label, systemImage: statusSystemImage, tone: statusTone)

            if let smartConnectStatus = client.smartConnectStatus {
                MessageBanner(text: smartConnectStatus, tone: .accent)
            }
            if let error = client.lastError {
                MessageBanner(text: error, tone: .warning)
            }
            if let qrScanError {
                MessageBanner(text: qrScanError, tone: .warning)
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: Geist.Spacing.s4) {
            VStack(alignment: .leading, spacing: Geist.Spacing.s2) {
                Text("Pair With Mac")
                    .geistTypography(.heading20)
                    .foregroundStyle(Geist.color(.gray1000, scheme: colorScheme))
                Text("Scan a Thumble Mac pairing code or a shared controller build, or request a secure six-digit pairing code.")
                    .geistTypography(.copy14)
                    .foregroundStyle(Geist.color(.gray900, scheme: colorScheme))
            }

            Button {
                onShowOnboarding()
            } label: {
                Label("Setup Guide", systemImage: "questionmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .geistButtonStyle(.tertiary, size: .medium)

            if client.isConnected {
                MessageBanner(
                    text: "The Mac remains connected. Return to the keypad or disconnect explicitly.",
                    tone: .accent
                )

                Button {
                    onShowSavedKeypad()
                } label: {
                    Label("Return to Keypad", systemImage: "rectangle.grid.2x2.fill")
                        .frame(maxWidth: .infinity)
                }
                .geistButtonStyle(.primary, size: .large)

                Button {
                    client.disconnect()
                } label: {
                    Label("Disconnect from Mac", systemImage: "wifi.slash")
                        .frame(maxWidth: .infinity)
                }
                .geistButtonStyle(.secondary, size: .medium)
            } else {
                Button {
                    client.startSmartConnect()
                } label: {
                    Label("Smart Connect", systemImage: "bolt.horizontal.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .geistButtonStyle(.primary, size: .large)

                if client.canViewSavedKeypadOffline {
                    Button {
                        onShowSavedKeypad()
                    } label: {
                        Label("View Saved Keypad", systemImage: "rectangle.grid.2x2")
                            .frame(maxWidth: .infinity)
                    }
                    .geistButtonStyle(.secondary, size: .large)
                }

                Button {
                    qrScanError = nil
                    isShowingScanner = true
                } label: {
                    Label("Scan Mac QR Code", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .geistButtonStyle(.secondary, size: .large)

                DividerLabel("Manual Connection")

                LabeledInput(title: "Mac Host") {
                    TextField("Mac IP, e.g. 192.168.1.24", text: $macHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)
                        .geistInput()
                }

                LabeledInput(title: "Port") {
                    TextField("8765", text: $macPort)
                        .keyboardType(.numberPad)
                        .geistInput()
                }

                Button {
                    pairingCode = ""
                    client.connect(hostField: macHost, port: macPort, pairingCode: "")
                } label: {
                    Text(client.state == .connecting ? "Requesting…" : "Request Pairing")
                        .frame(maxWidth: .infinity)
                }
                .geistButtonStyle(.primary, size: .medium)
                .disabled(macHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            DividerLabel("iPhone Settings")

            KeypadAppearancePickerRow(selection: keypadColorSchemePreferenceBinding)
            KeypadHapticIntensityRow(intensity: $keypadHapticIntensity)
            KeypadBindingGlyphsToggleRow(isEnabled: $showsBindingGlyphs)
            KeypadImmersiveModeToggleRow(isEnabled: $prefersImmersiveKeypad)
        }
        .geistPanel(padding: Geist.Spacing.s6, radius: Geist.Radius.sm)
    }

    private var pairingCodePrompt: some View {
        VStack(alignment: .center, spacing: Geist.Spacing.s6) {
            Image(systemName: "macbook.and.iphone")
                .font(.system(size: 54, weight: .semibold))
                .foregroundStyle(Geist.color(.blue900, scheme: colorScheme))
                .symbolRenderingMode(.hierarchical)

            VStack(spacing: Geist.Spacing.s2) {
                Text("Pairing request accepted")
                    .geistTypography(.heading24)
                    .foregroundStyle(Geist.color(.gray1000, scheme: colorScheme))
                    .multilineTextAlignment(.center)

                Text("Enter the code shown on Thumble Mac.")
                    .geistTypography(.copy14)
                    .foregroundStyle(Geist.color(.gray900, scheme: colorScheme))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            PairingCodeInput(code: $pendingPairingCode)

            VStack(spacing: Geist.Spacing.s3) {
                Button {
                    pairingCode = pendingPairingCode
                    client.submitPairingCode(pendingPairingCode)
                } label: {
                    Text("Pair")
                        .frame(maxWidth: .infinity)
                }
                .geistButtonStyle(.primary, size: .large)
                .disabled(pendingPairingCode.count < 6)

                Button("Cancel Pairing") {
                    pendingPairingCode = ""
                    client.disconnect(sendReleaseAll: false)
                }
                .geistButtonStyle(.tertiary, size: .medium)
            }
        }
        .geistPanel(padding: Geist.Spacing.s6, radius: Geist.Radius.md)
    }

    private func handleScannedPairingCode(_ text: String) {
        if artifactPickup.route(text) == .handled {
            qrScanError = nil
            isShowingScanner = false
            return
        }
        guard let payload = PairingPayload.decode(from: text) else {
            qrScanError = "QR code not recognized. Scan a Thumble pairing or shared-build code."
            isShowingScanner = false
            return
        }

        pairingCode = payload.pairingCode ?? ""
        if let urlString = payload.urls.first {
            applyConnectionFields(from: urlString)
        }
        isShowingScanner = false
        client.connect(pairingPayload: payload)
    }

    private func applyConnectionFields(from urlString: String) {
        guard let components = URLComponents(string: urlString),
              let host = components.host
        else {
            macHost = urlString
            macPort = "8765"
            return
        }

        macHost = host
        macPort = components.port.map(String.init) ?? "8765"
    }

    private var statusTone: GeistInterfaceTone {
        switch client.state {
        case .connected: .success
        case .connecting, .pairingCodeRequired: .warning
        case .failed: .error
        case .disconnected: .neutral
        }
    }

    private var statusSystemImage: String {
        switch client.state {
        case .connected: "checkmark.circle.fill"
        case .connecting: "arrow.triangle.2.circlepath"
        case .pairingCodeRequired: "key.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .disconnected: "circle"
        }
    }
}

private enum IOSOnboardingStep: String, CaseIterable, Identifiable, Hashable {
    case welcome
    case permissions
    case connect
    case keypad

    var id: Self { self }

    var title: String {
        switch self {
        case .welcome: "Welcome"
        case .permissions: "Permissions"
        case .connect: "Connect"
        case .keypad: "Use Keypads"
        }
    }

    var systemImage: String {
        switch self {
        case .welcome: "iphone.gen3"
        case .permissions: "checkmark.shield.fill"
        case .connect: "macbook.and.iphone"
        case .keypad: "rectangle.grid.2x2"
        }
    }
}

private struct IOSOnboardingView: View {
    @EnvironmentObject private var client: ControllerClient
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var selectedStep: IOSOnboardingStep = .welcome
    @State private var navigationDirection = 1

    let onStartSmartConnect: () -> Void
    let onComplete: () -> Void

    private var steps: [IOSOnboardingStep] { IOSOnboardingStep.allCases }
    private var selectedIndex: Int { steps.firstIndex(of: selectedStep) ?? 0 }
    private var isFirstStep: Bool { selectedIndex == 0 }
    private var isLastStep: Bool { selectedIndex == steps.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollViewReader { scrollProxy in
                ScrollView(.vertical, showsIndicators: false) {
                    Color.clear
                        .frame(height: 0)
                        .id("onboarding-top")

                    stepContent
                        .id(selectedStep)
                        .transition(stepTransition)
                        .padding(.horizontal, Geist.Spacing.s6)
                        .padding(.vertical, Geist.Spacing.s8)
                        .frame(maxWidth: 720, alignment: .topLeading)
                        .frame(maxWidth: .infinity, alignment: .top)
                }
                .onChange(of: selectedStep) { _, _ in
                    scrollProxy.scrollTo("onboarding-top", anchor: .top)
                }
            }

            footer
        }
        .background {
            Geist.color(.background200, scheme: colorScheme)
                .overlay(alignment: .topTrailing) {
                    Circle()
                        .fill(Geist.color(.blue200, scheme: colorScheme).opacity(0.55))
                        .frame(width: 260, height: 260)
                        .blur(radius: 72)
                        .offset(x: 110, y: -100)
                }
                .overlay(alignment: .bottomLeading) {
                    Circle()
                        .fill(Geist.color(.purple200, scheme: colorScheme).opacity(0.32))
                        .frame(width: 220, height: 220)
                        .blur(radius: 80)
                        .offset(x: -100, y: 100)
                }
                .ignoresSafeArea()
                .accessibilityHidden(true)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Geist.Spacing.s3) {
            HStack(alignment: .center, spacing: Geist.Spacing.s3) {
                Image(systemName: "rectangle.grid.2x2.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Geist.color(.background100, scheme: colorScheme))
                    .frame(width: 44, height: 44)
                    .background(Geist.color(.gray1000, scheme: colorScheme), in: RoundedRectangle(cornerRadius: Geist.Radius.md, style: .continuous))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 0) {
                    Text("Thumble")
                        .geistTypography(.heading20)
                        .foregroundStyle(Geist.color(.gray1000, scheme: colorScheme))
                    Text("Quick setup")
                        .geistTypography(.label13)
                        .foregroundStyle(Geist.color(.gray900, scheme: colorScheme))
                }

                Spacer(minLength: Geist.Spacing.s3)

                VStack(alignment: .trailing, spacing: 0) {
                    Text("STEP \(selectedIndex + 1) OF \(steps.count)")
                        .geistTypography(.label12Mono)
                        .foregroundStyle(Geist.color(.gray800, scheme: colorScheme))
                    Text(selectedStep.title)
                        .geistTypography(.heading14)
                        .foregroundStyle(Geist.color(.gray1000, scheme: colorScheme))
                        .contentTransition(.numericText())
                }
            }

            ProgressView(value: Double(selectedIndex + 1), total: Double(steps.count))
                .tint(Geist.color(.blue700, scheme: colorScheme))
                .accessibilityLabel("Setup progress")
                .accessibilityValue("Step \(selectedIndex + 1) of \(steps.count), \(selectedStep.title)")
        }
        .padding(.horizontal, Geist.Spacing.s6)
        .padding(.vertical, Geist.Spacing.s4)
        .background(Geist.color(.background100, scheme: colorScheme).opacity(0.96))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Geist.color(.grayAlpha400, scheme: colorScheme))
                .frame(height: 1)
        }
    }

    private var stepTransition: AnyTransition {
        guard !accessibilityReduceMotion else { return .identity }
        let incomingEdge: Edge = navigationDirection > 0 ? .trailing : .leading
        let outgoingEdge: Edge = navigationDirection > 0 ? .leading : .trailing
        return .asymmetric(
            insertion: .move(edge: incomingEdge).combined(with: .opacity),
            removal: .move(edge: outgoingEdge).combined(with: .opacity)
        )
    }

    @ViewBuilder
    private var stepContent: some View {
        switch selectedStep {
        case .welcome:
            welcomeStep
        case .permissions:
            permissionsStep
        case .connect:
            connectStep
        case .keypad:
            keypadStep
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: Geist.Spacing.s6) {
            VStack(alignment: .leading, spacing: Geist.Spacing.s3) {
                Text("Your Mac shortcuts, right under your thumbs.")
                    .geistTypography(.heading32)
                    .foregroundStyle(Geist.color(.gray1000, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                Text("Thumble turns this iPhone into a programmable control surface for shortcuts, pointer actions, and virtual gamepad input on your Mac.")
                    .geistTypography(.copy16)
                    .foregroundStyle(Geist.color(.gray900, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }

            IOSOnboardingConnectionPreview()

            IOSOnboardingCallout(
                title: "Install Thumble on both devices",
                text: "The Mac app handles permissions, secure pairing, and keypad editing. This iPhone displays your synced controls and sends every press.",
                systemImage: "macbook"
            )

            VStack(alignment: .leading, spacing: Geist.Spacing.s3) {
                IOSOnboardingInstructionCard(step: "1", title: "Open Thumble Mac", text: "Leave the helper running while you use the phone keypad.")
                IOSOnboardingInstructionCard(step: "2", title: "Pair securely", text: "Use Smart Connect, scan the QR code, or type the local address and pairing code.")
                IOSOnboardingInstructionCard(step: "3", title: "Control the focused Mac app", text: "After pairing, focus Terminal, Cursor, a browser, or a game and press controls on this iPhone.")
            }
        }
    }

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: Geist.Spacing.s6) {
            VStack(alignment: .leading, spacing: Geist.Spacing.s2) {
                Text("Allow two focused permissions.")
                    .geistTypography(.heading32)
                    .foregroundStyle(Geist.color(.gray1000, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text("Thumble only needs local device discovery and QR scanning. Keyboard permissions are granted on the Mac, not on the iPhone.")
                    .geistTypography(.copy16)
                    .foregroundStyle(Geist.color(.gray900, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: Geist.Spacing.s3) {
                IOSOnboardingPermissionCard(
                    title: "Local Network",
                    text: "Allow this so Smart Connect can discover Thumble Mac over Wi‑Fi or nearby peer-to-peer, and so manual WebSocket pairing works on your network.",
                    systemImage: "wifi"
                )
                IOSOnboardingPermissionCard(
                    title: "Camera",
                    text: "Allow camera access when you tap Scan Mac QR Code. Thumble only uses the camera to read the pairing QR code.",
                    systemImage: "camera.viewfinder"
                )
            }

            Button {
                onStartSmartConnect()
            } label: {
                Label("Start Smart Connect", systemImage: "bolt.horizontal.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .geistButtonStyle(.primary, size: .large)

            IOSOnboardingCallout(
                title: "Mac permissions happen on the Mac",
                text: "If shortcuts do not fire, open Thumble Mac and enable Accessibility in System Settings → Privacy & Security → Accessibility.",
                systemImage: "checkmark.shield.fill"
            )
        }
    }

    private var connectStep: some View {
        VStack(alignment: .leading, spacing: Geist.Spacing.s6) {
            VStack(alignment: .leading, spacing: Geist.Spacing.s2) {
                Text("Pair with Thumble Mac.")
                    .geistTypography(.heading32)
                    .foregroundStyle(Geist.color(.gray1000, scheme: colorScheme))
                    .accessibilityAddTraits(.isHeader)
                Text("Smart Connect is fastest after the first pair. QR and manual pairing are available any time from the connection screen.")
                    .geistTypography(.copy16)
                    .foregroundStyle(Geist.color(.gray900, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }

            IOSOnboardingConnectionStatusCard(
                status: client.state.label,
                detail: client.isConnected
                    ? "This iPhone is paired and ready to receive its keypad."
                    : (client.smartConnectStatus ?? client.lastError ?? "Open Thumble Mac, then let Smart Connect find it nearby."),
                isConnected: client.isConnected
            )

            VStack(alignment: .leading, spacing: Geist.Spacing.s3) {
                IOSOnboardingInstructionCard(step: "1", title: "Tap Smart Connect", text: "Thumble looks for the Mac helper advertised on your local or nearby peer-to-peer network.")
                IOSOnboardingInstructionCard(step: "2", title: "If needed, scan the QR", text: "On the Mac Home screen, scan the QR card shown under Connect From iPhone.")
                IOSOnboardingInstructionCard(step: "3", title: "Enter the six-digit code", text: "Manual pairing asks you to type the code shown on Thumble Mac. Smart Connect will remember this Mac after pairing.")
            }

            Button {
                onStartSmartConnect()
            } label: {
                Label("Try Smart Connect Now", systemImage: "bolt.horizontal.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .geistButtonStyle(.primary, size: .large)
        }
    }

    private var keypadStep: some View {
        VStack(alignment: .leading, spacing: Geist.Spacing.s6) {
            VStack(alignment: .leading, spacing: Geist.Spacing.s2) {
                Text("Your keypad is ready when you are.")
                    .geistTypography(.heading32)
                    .foregroundStyle(Geist.color(.gray1000, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text("The full keypad editor is on the Mac. This iPhone receives the saved setups, lets you switch between them, and can make small layout edits for freeform controls.")
                    .geistTypography(.copy16)
                    .foregroundStyle(Geist.color(.gray900, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }

            IOSOnboardingKeypadPreview()

            VStack(alignment: .leading, spacing: Geist.Spacing.s3) {
                IOSOnboardingInstructionCard(step: "1", title: "Edit on Mac", text: "Open the Keypad section on Thumble Mac to add controls, style them, and record shortcuts.")
                IOSOnboardingInstructionCard(step: "2", title: "Open the top bar", text: "Swipe down from the top edge if the keypad controls are hidden.")
                IOSOnboardingInstructionCard(step: "3", title: "Switch setups", text: "Use the Keypad setup menu to choose another synced setup, mark it as default, or export keypads as JSON.")
                IOSOnboardingInstructionCard(step: "4", title: "Adjust a freeform layout", text: "Tap the lock icon to unlock controls, then move, resize, rotate, or delete elements before locking again.")
            }

            IOSOnboardingCallout(
                title: client.isConnected ? "Connected and ready" : "You can pair any time",
                text: client.isConnected
                    ? "Finish setup to open your synced keypad."
                    : "Finish setup to open the connection screen, where Smart Connect, QR scanning, and manual pairing are always available.",
                systemImage: client.isConnected ? "checkmark.circle.fill" : "bolt.horizontal.circle.fill"
            )
        }
    }

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Geist.Spacing.s3) {
                if !isLastStep {
                    Button("Set Up Later") { onComplete() }
                        .geistButtonStyle(.tertiary, size: .large)
                        .accessibilityHint("Closes the guide. You can reopen it from the connection screen.")
                }

                Spacer(minLength: Geist.Spacing.s3)

                if !isFirstStep {
                    Button("Back") { moveSelection(by: -1) }
                        .geistButtonStyle(.secondary, size: .large)
                }

                continueButton
                    .frame(minWidth: 132)
            }

            VStack(spacing: Geist.Spacing.s2) {
                continueButton
                    .frame(maxWidth: .infinity)

                HStack(spacing: Geist.Spacing.s2) {
                    if !isFirstStep {
                        Button("Back") { moveSelection(by: -1) }
                            .geistButtonStyle(.secondary)
                    }
                    if !isLastStep {
                        Button("Set Up Later") { onComplete() }
                            .geistButtonStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.horizontal, Geist.Spacing.s4)
        .padding(.vertical, Geist.Spacing.s3)
        .background(Geist.color(.background100, scheme: colorScheme).opacity(0.98))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Geist.color(.grayAlpha400, scheme: colorScheme))
                .frame(height: 1)
        }
    }

    private var continueButton: some View {
        Button(isLastStep ? "Open Thumble" : (isFirstStep ? "Get Started" : "Continue")) {
            if isLastStep {
                onComplete()
            } else {
                moveSelection(by: 1)
            }
        }
        .geistButtonStyle(.primary, size: .large)
        .accessibilityHint(isLastStep ? "Finishes setup and opens Thumble." : "Advances to the next setup step.")
    }

    private func moveSelection(by offset: Int) {
        let nextIndex = min(max(selectedIndex + offset, 0), steps.count - 1)
        guard nextIndex != selectedIndex else { return }
        navigationDirection = offset >= 0 ? 1 : -1
        let update = { selectedStep = steps[nextIndex] }
        if accessibilityReduceMotion {
            update()
        } else {
            withAnimation(.easeInOut(duration: 0.28)) {
                update()
            }
        }
    }
}

private struct IOSOnboardingConnectionPreview: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: Geist.Spacing.s2) {
            device(
                title: "Mac",
                subtitle: "Build shortcuts",
                systemImage: "macbook"
            )

            VStack(spacing: Geist.Spacing.s1) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Geist.color(.blue900, scheme: colorScheme))
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in
                        Capsule()
                            .fill(Geist.color(.blue600, scheme: colorScheme))
                            .frame(width: 8, height: 3)
                    }
                }
                Text("Secure")
                    .geistTypography(.label12)
                    .foregroundStyle(Geist.color(.gray900, scheme: colorScheme))
            }
            .frame(width: 54)
            .accessibilityHidden(true)

            device(
                title: "iPhone",
                subtitle: "Tap your keypad",
                systemImage: "iphone.gen3"
            )
        }
        .padding(Geist.Spacing.s4)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [
                    Geist.color(.blue100, scheme: colorScheme),
                    Geist.color(.background100, scheme: colorScheme)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: Geist.Radius.lg, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Geist.Radius.lg, style: .continuous)
                .stroke(Geist.color(.blue400, scheme: colorScheme), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Thumble connection")
        .accessibilityValue("Build shortcuts on the Mac, then use the securely connected keypad on this iPhone.")
    }

    private func device(title: String, subtitle: String, systemImage: String) -> some View {
        VStack(spacing: Geist.Spacing.s2) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Geist.color(.gray1000, scheme: colorScheme))
                .frame(height: 34)

            VStack(spacing: 1) {
                Text(title)
                    .geistTypography(.heading14)
                    .foregroundStyle(Geist.color(.gray1000, scheme: colorScheme))
                Text(subtitle)
                    .geistTypography(.label12)
                    .foregroundStyle(Geist.color(.gray900, scheme: colorScheme))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, Geist.Spacing.s3)
        .frame(maxWidth: .infinity)
        .background(Geist.color(.background100, scheme: colorScheme).opacity(0.82), in: RoundedRectangle(cornerRadius: Geist.Radius.md, style: .continuous))
    }
}

private struct IOSOnboardingConnectionStatusCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let status: String
    let detail: String
    let isConnected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Geist.Spacing.s3) {
            Image(systemName: isConnected ? "checkmark.circle.fill" : "dot.radiowaves.left.and.right")
                .font(.system(size: 22, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isConnected ? Geist.color(.green900, scheme: colorScheme) : Geist.color(.blue900, scheme: colorScheme))
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: Geist.Spacing.s1) {
                Text(isConnected ? "Mac connected" : "Live connection status")
                    .geistTypography(.heading16)
                    .foregroundStyle(Geist.color(.gray1000, scheme: colorScheme))
                Text(status)
                    .geistTypography(.label13Mono)
                    .foregroundStyle(Geist.color(.blue900, scheme: colorScheme))
                Text(detail)
                    .geistTypography(.copy14)
                    .foregroundStyle(Geist.color(.gray900, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Geist.Spacing.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Geist.color(isConnected ? .green100 : .blue100, scheme: colorScheme), in: RoundedRectangle(cornerRadius: Geist.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Geist.Radius.md, style: .continuous)
                .stroke(Geist.color(isConnected ? .green400 : .blue400, scheme: colorScheme), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}

private struct IOSOnboardingKeypadPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Geist.Spacing.s3) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("My Mac Shortcuts")
                        .geistTypography(.heading14)
                        .foregroundStyle(Geist.color(.gray1000, scheme: .dark))
                    Text("Synced from Thumble Mac")
                        .geistTypography(.label12)
                        .foregroundStyle(Geist.color(.gray900, scheme: .dark))
                }

                Spacer()

                Label("Ready", systemImage: "checkmark.circle.fill")
                    .geistTypography(.label12)
                    .foregroundStyle(Geist.color(.green900, scheme: .dark))
            }

            HStack(spacing: Geist.Spacing.s2) {
                keypadButton(title: "Copy", systemImage: "doc.on.doc")
                keypadButton(title: "Paste", systemImage: "clipboard")
                keypadButton(title: "Search", systemImage: "magnifyingglass")
            }

            HStack(spacing: Geist.Spacing.s2) {
                keypadButton(title: "Undo", systemImage: "arrow.uturn.backward")
                keypadButton(title: "Run", systemImage: "play.fill")
                keypadButton(title: "Mute", systemImage: "speaker.slash.fill")
            }
        }
        .padding(Geist.Spacing.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Geist.color(.background100, scheme: .dark), in: RoundedRectangle(cornerRadius: Geist.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Geist.Radius.lg, style: .continuous)
                .stroke(Geist.color(.grayAlpha600, scheme: .dark), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Example synced keypad")
        .accessibilityValue("Shortcut controls for Copy, Paste, Search, Undo, Run, and Mute.")
    }

    private func keypadButton(title: String, systemImage: String) -> some View {
        VStack(spacing: Geist.Spacing.s2) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
            Text(title)
                .geistTypography(.label12)
        }
        .foregroundStyle(Geist.color(.gray1000, scheme: .dark))
        .frame(maxWidth: .infinity)
        .frame(height: 64)
        .background(Geist.color(.gray200, scheme: .dark), in: RoundedRectangle(cornerRadius: Geist.Radius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Geist.Radius.sm, style: .continuous)
                .stroke(Geist.color(.grayAlpha400, scheme: .dark), lineWidth: 1)
        )
    }
}

private struct IOSOnboardingInstructionCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let step: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: Geist.Spacing.s3) {
            Text(step)
                .geistTypography(.heading14)
                .foregroundStyle(Geist.color(.background100, scheme: colorScheme))
                .frame(width: 28, height: 28)
                .background(Geist.color(.gray1000, scheme: colorScheme), in: Circle())

            VStack(alignment: .leading, spacing: Geist.Spacing.s1) {
                Text(title)
                    .geistTypography(.heading16)
                    .foregroundStyle(Geist.color(.gray1000, scheme: colorScheme))
                Text(text)
                    .geistTypography(.copy14)
                    .foregroundStyle(Geist.color(.gray900, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Geist.Spacing.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Geist.color(.gray100, scheme: colorScheme), in: RoundedRectangle(cornerRadius: Geist.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Geist.Radius.md, style: .continuous)
                .stroke(Geist.color(.grayAlpha400, scheme: colorScheme), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}

private struct IOSOnboardingPermissionCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let text: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: Geist.Spacing.s3) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Geist.color(.blue900, scheme: colorScheme))
                .frame(width: 32, height: 32)
                .background(Geist.color(.blue100, scheme: colorScheme), in: RoundedRectangle(cornerRadius: Geist.Radius.sm, style: .continuous))

            VStack(alignment: .leading, spacing: Geist.Spacing.s1) {
                Text(title)
                    .geistTypography(.heading16)
                    .foregroundStyle(Geist.color(.gray1000, scheme: colorScheme))
                Text(text)
                    .geistTypography(.copy14)
                    .foregroundStyle(Geist.color(.gray900, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Geist.Spacing.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Geist.color(.gray100, scheme: colorScheme), in: RoundedRectangle(cornerRadius: Geist.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Geist.Radius.md, style: .continuous)
                .stroke(Geist.color(.grayAlpha400, scheme: colorScheme), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}

private struct IOSOnboardingCallout: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let text: String
    let systemImage: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: Geist.Spacing.s1) {
                Text(title)
                    .geistTypography(.heading14)
                    .foregroundStyle(Geist.color(.gray1000, scheme: colorScheme))
                Text(text)
                    .geistTypography(.copy13)
                    .foregroundStyle(Geist.color(.gray900, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Geist.color(.blue900, scheme: colorScheme))
        }
        .padding(Geist.Spacing.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Geist.color(.blue100, scheme: colorScheme), in: RoundedRectangle(cornerRadius: Geist.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Geist.Radius.md, style: .continuous)
                .stroke(Geist.color(.blue400, scheme: colorScheme), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}

private struct PairingCodeInput: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var code: String
    @FocusState private var isFocused: Bool

    private let digitCount = 6

    var body: some View {
        ZStack {
            HStack(spacing: Geist.Spacing.s2) {
                ForEach(0..<digitCount, id: \.self) { index in
                    digitBox(at: index)
                }
            }

            TextField("Pairing code", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($isFocused)
                .foregroundStyle(.clear)
                .tint(.clear)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .accessibilityLabel("Pairing code")
        }
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isFocused = true
            }
        }
        .onChange(of: code) { _, newValue in
            let filtered = String(newValue.filter(\.isNumber).prefix(digitCount))
            if filtered != newValue {
                code = filtered
            }
        }
    }

    private func digitBox(at index: Int) -> some View {
        let digits = Array(code)
        let digit = index < digits.count ? String(digits[index]) : ""
        let isActive = index == min(code.count, digitCount - 1)

        return Text(digit)
            .geistTypography(.heading24)
            .monospacedDigit()
            .foregroundStyle(Geist.color(.gray1000, scheme: colorScheme))
            .frame(width: 44, height: 52)
            .background(Geist.color(.gray100, scheme: colorScheme), in: RoundedRectangle(cornerRadius: Geist.Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Geist.Radius.md, style: .continuous)
                    .stroke(isActive ? Geist.color(.blue700, scheme: colorScheme) : Geist.color(.grayAlpha400, scheme: colorScheme), lineWidth: isActive ? 2 : 1)
            )
    }
}

private struct MessageBanner: View {
    @Environment(\.colorScheme) private var colorScheme
    let text: String
    let tone: GeistInterfaceTone

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .geistTypography(.copy13)
            .foregroundStyle(tone.foreground(scheme: colorScheme))
            .padding(.horizontal, Geist.Spacing.s3)
            .padding(.vertical, Geist.Spacing.s2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tone.background(scheme: colorScheme), in: RoundedRectangle(cornerRadius: Geist.Radius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Geist.Radius.sm, style: .continuous)
                    .stroke(tone.border(scheme: colorScheme), lineWidth: 1)
            )
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct DiscordCommunityBanner: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let onDismiss: () -> Void

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Geist.Spacing.s2) {
                    message
                    HStack(spacing: Geist.Spacing.s2) {
                        joinLink
                        dismissButton
                    }
                }
            } else {
                HStack(spacing: Geist.Spacing.s2) {
                    message
                    Spacer(minLength: Geist.Spacing.s2)
                    joinLink
                    dismissButton
                }
            }
        }
        .padding(.horizontal, Geist.Spacing.s3)
        .padding(.vertical, 10)
        .background(
            Geist.color(.background100, scheme: colorScheme),
            in: RoundedRectangle(cornerRadius: Geist.Radius.md, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Geist.Radius.md, style: .continuous)
                .stroke(Geist.color(.grayAlpha400, scheme: colorScheme), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.3 : 0.08), radius: 8, y: 3)
    }

    private var message: some View {
        HStack(spacing: Geist.Spacing.s2) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Geist.color(.blue900, scheme: colorScheme))
                .frame(width: 28, height: 28)
                .background(Geist.color(.blue100, scheme: colorScheme), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("Join the community")
                    .geistTypography(.heading14)
                    .foregroundStyle(Geist.color(.gray1000, scheme: colorScheme))
                Text("Chat with us on Discord")
                    .geistTypography(.label12)
                    .foregroundStyle(Geist.color(.gray900, scheme: colorScheme))
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var joinLink: some View {
        Link(destination: ThumbleSupportLinks.discord) {
            Text("Join")
                .geistTypography(.button12)
                .foregroundStyle(Geist.color(.blue900, scheme: colorScheme))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Geist.color(.blue100, scheme: colorScheme), in: Capsule())
        }
        .accessibilityLabel("Join the Thumble Discord")
        .accessibilityHint("Opens Discord")
    }

    private var dismissButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Geist.color(.gray900, scheme: colorScheme))
                .frame(width: 28, height: 28)
                .background(Geist.color(.gray100, scheme: colorScheme), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss Discord invitation")
    }
}

private struct DividerLabel: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        HStack(spacing: Geist.Spacing.s3) {
            Rectangle()
                .fill(Geist.color(.grayAlpha400, scheme: colorScheme))
                .frame(height: 1)
            Text(title)
                .geistTypography(.label12)
                .foregroundStyle(Geist.color(.gray900, scheme: colorScheme))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Rectangle()
                .fill(Geist.color(.grayAlpha400, scheme: colorScheme))
                .frame(height: 1)
        }
        .padding(.vertical, Geist.Spacing.s1)
    }
}

private struct LabeledInput<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    var helper: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Geist.Spacing.s2) {
            HStack(spacing: Geist.Spacing.s2) {
                Text(title)
                    .geistTypography(.heading14)
                    .foregroundStyle(Geist.color(.gray1000, scheme: colorScheme))
                if let helper {
                    Text(helper)
                        .geistTypography(.label12)
                        .foregroundStyle(Geist.color(.gray900, scheme: colorScheme))
                }
            }
            content
        }
    }
}

private struct KeypadAppearancePickerRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var selection: GamepadColorSchemePreference

    var body: some View {
        VStack(alignment: .leading, spacing: Geist.Spacing.s3) {
            VStack(alignment: .leading, spacing: Geist.Spacing.s1) {
                Text("Keypad Appearance")
                    .geistTypography(.heading14)
                    .foregroundStyle(Geist.color(.gray1000, scheme: colorScheme))

                Text("Choose whether the keypad uses light mode, dark mode, or follows iOS.")
                    .geistTypography(.copy13)
                    .foregroundStyle(Geist.color(.gray900, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker("Keypad Appearance", selection: $selection) {
                ForEach(GamepadColorSchemePreference.allCases) { preference in
                    Text(preference.displayName).tag(preference)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal, Geist.Spacing.s3)
        .padding(.vertical, Geist.Spacing.s3)
        .background(
            RoundedRectangle(cornerRadius: Geist.Radius.sm, style: .continuous)
                .fill(Geist.color(.gray100, scheme: colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Geist.Radius.sm, style: .continuous)
                .stroke(Geist.color(.grayAlpha400, scheme: colorScheme), lineWidth: 1)
        )
        .accessibilityHint("Controls whether the keypad follows iOS appearance or is forced light or dark.")
    }
}

private struct KeypadHapticIntensityRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var intensity: Double

    var body: some View {
        VStack(alignment: .leading, spacing: Geist.Spacing.s3) {
            VStack(alignment: .leading, spacing: Geist.Spacing.s1) {
                Text("Haptic Intensity")
                    .geistTypography(.heading14)
                    .foregroundStyle(Geist.color(.gray1000, scheme: colorScheme))
                Text("Scales every keypad haptic while preserving each control’s relative pattern strength.")
                    .geistTypography(.copy13)
                    .foregroundStyle(Geist.color(.gray900, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Picker("Haptic Intensity", selection: $intensity) {
                ForEach(KeypadHapticIntensityPolicy.supportedLevels, id: \.self) { level in
                    Text(KeypadHapticIntensityPolicy.label(for: level)).tag(level)
                }
            }
            .pickerStyle(.segmented)
            Button("Test Haptic") {
                KeypadHapticPlayer.shared.play(.init(style: .medium, pattern: .double, intensity: 0.72), intensityScale: intensity)
            }
            .geistButtonStyle(.secondary, size: .small)
            .disabled(intensity <= 0)
        }
        .padding(.horizontal, Geist.Spacing.s3)
        .padding(.vertical, Geist.Spacing.s3)
        .background(RoundedRectangle(cornerRadius: Geist.Radius.sm).fill(Geist.color(.gray100, scheme: colorScheme)))
        .overlay(RoundedRectangle(cornerRadius: Geist.Radius.sm).stroke(Geist.color(.grayAlpha400, scheme: colorScheme)))
    }
}

private struct KeypadBindingGlyphsToggleRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var isEnabled: Bool

    var body: some View {
        Toggle(isOn: $isEnabled) {
            VStack(alignment: .leading, spacing: Geist.Spacing.s1) {
                Text("Show Binding Glyphs")
                    .geistTypography(.heading14)
                    .foregroundStyle(Geist.color(.gray1000, scheme: colorScheme))
                Text("Show binding hints when local binding presentation is available.")
                    .geistTypography(.copy13)
                    .foregroundStyle(Geist.color(.gray900, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .tint(Geist.color(.blue700, scheme: colorScheme))
        .padding(.horizontal, Geist.Spacing.s3)
        .padding(.vertical, Geist.Spacing.s3)
        .background(RoundedRectangle(cornerRadius: Geist.Radius.sm).fill(Geist.color(.gray100, scheme: colorScheme)))
        .overlay(RoundedRectangle(cornerRadius: Geist.Radius.sm).stroke(Geist.color(.grayAlpha400, scheme: colorScheme)))
        .accessibilityHint("Controls local binding glyph presentation without changing keypad metadata.")
    }
}

private struct KeypadImmersiveModeToggleRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var isEnabled: Bool

    var body: some View {
        Toggle(isOn: $isEnabled) {
            VStack(alignment: .leading, spacing: Geist.Spacing.s1) {
                Text("Immersive Keypad")
                    .geistTypography(.heading14)
                    .foregroundStyle(Geist.color(.gray1000, scheme: colorScheme))

                Text("Hide the status bar and Home indicator while the keypad is open.")
                    .geistTypography(.copy13)
                    .foregroundStyle(Geist.color(.gray900, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .tint(Geist.color(.blue700, scheme: colorScheme))
        .padding(.horizontal, Geist.Spacing.s3)
        .padding(.vertical, Geist.Spacing.s3)
        .background(
            RoundedRectangle(cornerRadius: Geist.Radius.sm, style: .continuous)
                .fill(Geist.color(.gray100, scheme: colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Geist.Radius.sm, style: .continuous)
                .stroke(Geist.color(.grayAlpha400, scheme: colorScheme), lineWidth: 1)
        )
        .accessibilityHint("When off, iOS system status and navigation affordances remain available over the keypad.")
    }
}

private struct KeypadSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var hapticIntensity: Double
    @Binding var showsBindingGlyphs: Bool
    @Binding var prefersImmersiveMode: Bool
    @Binding var colorSchemePreference: GamepadColorSchemePreference
    @Binding var orientationPreference: GamepadProfileOrientationPreference
    @Binding var isPracticeModeEnabled: Bool
    let supportsOrientationPreferenceMutation: Bool
    let onShowGuide: (() -> Void)?
    let onShowSkins: () -> Void
    let onStartCalibration: () -> Void
    let onReleaseAllInputs: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: $isPracticeModeEnabled) {
                        Label("Practice Mode", systemImage: "hand.tap.fill")
                    }
                } header: {
                    Text("Input Safety")
                } footer: {
                    Text("Practice Mode keeps controls, pressed states, and haptics active without sending input to the Mac.")
                }

                Section("Feedback") {
                    Picker("Haptic Intensity", selection: $hapticIntensity) {
                        ForEach(KeypadHapticIntensityPolicy.supportedLevels, id: \.self) { level in
                            Text(KeypadHapticIntensityPolicy.label(for: level)).tag(level)
                        }
                    }

                    Button {
                        KeypadHapticPlayer.shared.play(
                            .init(style: .medium, pattern: .double, intensity: 0.72),
                            intensityScale: hapticIntensity
                        )
                    } label: {
                        Label("Test Haptic", systemImage: "waveform.path.ecg")
                    }
                    .disabled(hapticIntensity <= 0)
                }

                Section("Display") {
                    Picker("Appearance", selection: $colorSchemePreference) {
                        ForEach(GamepadColorSchemePreference.allCases) { preference in
                            Text(preference.displayName).tag(preference)
                        }
                    }

                    Toggle(isOn: $showsBindingGlyphs) {
                        Label("Show Binding Glyphs", systemImage: "command")
                    }

                    Toggle(isOn: $prefersImmersiveMode) {
                        Label("Immersive Keypad", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                }

                Section {
                    if supportsOrientationPreferenceMutation {
                        Picker("iPhone Rotation", selection: $orientationPreference) {
                            ForEach(GamepadProfileOrientationPreference.allCases) { preference in
                                Text(preference.displayName).tag(preference)
                            }
                        }
                    } else {
                        Label {
                            Text("Update the Mac app to set this keypad’s iPhone rotation preference.")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle")
                        }
                        .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Current Keypad")
                }

                Section("Skins") {
                    Button {
                        dismissThenRun(onShowSkins)
                    } label: {
                        Label("Browse Installed Skins", systemImage: "paintpalette.fill")
                    }
                }

                Section("Ergonomics") {
                    Button {
                        dismissThenRun(onStartCalibration)
                    } label: {
                        Label("Calibrate Thumb Placement", systemImage: "hand.draw.fill")
                    }
                }

                if let onShowGuide {
                    Section {
                        Button {
                            dismissThenRun(onShowGuide)
                        } label: {
                            Label("Setup Guide", systemImage: "questionmark.circle")
                        }
                    }
                }

                Section("Community & Support") {
                    Link(destination: ThumbleSupportLinks.discord) {
                        Label("Join Our Discord", systemImage: "bubble.left.and.bubble.right.fill")
                    }
                    .accessibilityHint("Opens the Thumble Discord community")

                    Link(destination: ThumbleSupportLinks.newGitHubIssue) {
                        Label("Submit an Issue on GitHub", systemImage: "ladybug.fill")
                    }
                    .accessibilityHint("Opens a new GitHub issue")
                }

                Section {
                    Button(role: .destructive) {
                        onReleaseAllInputs()
                    } label: {
                        Label("Release All Keys", systemImage: "keyboard.chevron.compact.down")
                    }
                } footer: {
                    Text("Immediately releases every active key, pointer button, trigger, and joystick direction.")
                }
            }
            .navigationTitle("Keypad Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func dismissThenRun(_ action: @escaping () -> Void) {
        dismiss()
        DispatchQueue.main.async(execute: action)
    }
}

@MainActor
private final class IOSKeypadEditRuntime: ObservableObject {
    @Published private(set) var isEditing = false
    @Published private(set) var canUndo = false
    @Published private(set) var hasChanges = false
    @Published private(set) var feedback = ""
    private var session: GamepadLayoutEditSession?

    func begin(with customization: GamepadCustomization, client: ControllerClient) {
        releaseInputs(client: client)
        session = GamepadLayoutEditSession(entrySnapshot: customization)
        feedback = client.isConnected ? "Changes save and sync to Mac" : "Changes save on this iPhone"
        refreshSessionState()
        isEditing = true
        announce("Editing keypad layout. Done, Undo, and Cancel are available.")
    }

    func finish(client: ControllerClient) {
        releaseInputs(client: client)
        isEditing = false
        session = nil
        canUndo = false
        hasChanges = false
        feedback = ""
        announce("Layout editing finished")
    }

    func undo(client: ControllerClient) {
        releaseInputs(client: client)
        guard session?.undo(apply: { previous in
            client.updateSelectedKeypadLayout(
                previous,
                orientation: previous.deviceCanvas.editorDeviceFrame.orientation,
                sendsToMac: true
            )
        }) == true else { return }
        feedback = client.isConnected ? "Undo saved and synced" : "Undo saved on this iPhone"
        refreshSessionState()
        announce(feedback)
    }

    func cancel(client: ControllerClient) {
        guard let session else {
            finish(client: client)
            return
        }
        releaseInputs(client: client)
        session.resetToEntry { entrySnapshot in
            client.updateSelectedKeypadLayout(
                entrySnapshot,
                orientation: entrySnapshot.deviceCanvas.editorDeviceFrame.orientation,
                sendsToMac: true
            )
        }
        isEditing = false
        self.session = nil
        canUndo = false
        hasChanges = false
        feedback = ""
        announce("Layout changes canceled and the starting layout restored")
    }

    func apply(
        _ customization: GamepadCustomization,
        orientation: GamepadEditorDeviceOrientation,
        isFinal: Bool,
        client: ControllerClient
    ) {
        if isFinal {
            _ = session?.commit(customization)
        }
        client.updateSelectedKeypadLayout(customization, orientation: orientation, sendsToMac: isFinal)
        if isFinal {
            feedback = client.isConnected
                ? "Saved — awaiting Mac confirmation"
                : "Saved on this iPhone — sync pending"
            refreshSessionState()
            announce(feedback)
        }
    }

    func releaseInputs(client: ControllerClient) {
        TouchCaptureUIView.deactivateAllRegisteredTouches()
        client.releaseAll()
    }

    private func refreshSessionState() {
        canUndo = session?.canUndo == true
        hasChanges = session?.hasChanges == true
    }

    private func announce(_ message: String) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}

private struct ControllerPadView: View {
    @EnvironmentObject private var client: ControllerClient
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(IOSKeypadPreferenceKeys.hapticIntensity) private var keypadHapticIntensity = IOSKeypadPreferenceKeys.defaultHapticIntensity
    @AppStorage(IOSKeypadPreferenceKeys.showBindingGlyphs) private var showsBindingGlyphs = IOSKeypadPreferenceKeys.defaultShowBindingGlyphs
    @AppStorage(IOSKeypadSettings.immersiveModeDefaultsKey) private var prefersImmersiveKeypad = true
    @State private var isTopBarVisible = false
    @State private var isExportingKeypadConfiguration = false
    @State private var isShowingKeypadSettings = false
    @State private var isShowingSkinLibrary = false
    @State private var practiceModeBeforeCalibration: Bool?
    @StateObject private var editRuntime = IOSKeypadEditRuntime()
    @StateObject private var calibrationRuntime = ThumbPlacementCalibrationRuntime()

    let onShowConnectionPage: (() -> Void)?
    let onShowOnboarding: (() -> Void)?

    init(
        onShowConnectionPage: (() -> Void)? = nil,
        onShowOnboarding: (() -> Void)? = nil
    ) {
        self.onShowConnectionPage = onShowConnectionPage
        self.onShowOnboarding = onShowOnboarding
    }

    var body: some View {
        GeometryReader { proxy in
            let orientation = GamepadControllerPresentationRouting.orientation(for: proxy.size)
            let safeAreaInsets = resolvedControllerSafeAreaInsets(proxy.safeAreaInsets)
            let context = ControllerPadRenderContext(
                size: proxy.size,
                safeAreaInsets: safeAreaInsets,
                client: client,
                orientation: orientation,
                isEditingLayout: editRuntime.isEditing,
                systemColorScheme: colorScheme
            )

            ControllerPadGeometryScene(
                context: context,
                isTopBarVisible: $isTopBarVisible,
                isExportingKeypadConfiguration: $isExportingKeypadConfiguration,
                editRuntime: editRuntime,
                calibrationRuntime: calibrationRuntime,
                onShowSettings: showKeypadSettings,
                onShowConnectionPage: showConnectionPage,
                onShowOnboarding: onShowOnboarding
            )
            // The physical keypad has fixed hit geometry. Cap only the canvas and
            // chrome so their visual labels cannot crop fixed controls. The settings
            // sheet is presented outside this cap and receives full Dynamic Type.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .sheet(isPresented: $isShowingKeypadSettings) {
                KeypadSettingsSheet(
                    hapticIntensity: $keypadHapticIntensity,
                    showsBindingGlyphs: $showsBindingGlyphs,
                    prefersImmersiveMode: $prefersImmersiveKeypad,
                    colorSchemePreference: keypadColorSchemePreferenceBinding,
                    orientationPreference: keypadOrientationPreferenceBinding,
                    isPracticeModeEnabled: practiceModeBinding,
                    supportsOrientationPreferenceMutation: client.supportsGamepadProfileOrientationPreferenceMutation,
                    onShowGuide: onShowOnboarding,
                    onShowSkins: { isShowingSkinLibrary = true },
                    onStartCalibration: { startCalibration(in: context) },
                    onReleaseAllInputs: releaseActiveInputs
                )
            }
            .sheet(isPresented: $isShowingSkinLibrary) {
                IOSSkinLibraryView()
                    .environmentObject(client)
            }
        }
        .environment(\.keypadHapticIntensity, keypadHapticIntensity)
        .environment(\.keypadShowsBindingGlyphs, showsBindingGlyphs)
        .onAppear {
            applyInitialTopBarVisibility()
        }
        .onDisappear {
            calibrationRuntime.cancel()
            restorePracticeModeAfterCalibration()
            releaseActiveInputs()
        }
        .onChange(of: client.state) { _, newState in
            releaseActiveInputs()
            isTopBarVisible = ControllerRuntimeChromePolicy.shouldPinTopBar(
                isConnected: newState == .connected,
                isEditingLayout: editRuntime.isEditing
            )
            announce("Connection status: \(newState.label)")
        }
        .onChange(of: editRuntime.isEditing) { _, isEditing in
            releaseActiveInputs()
            isTopBarVisible = isEditing || !client.isConnected
        }
        .onChange(of: client.selectedGamepadProfileID) { _, _ in
            calibrationRuntime.cancel()
            if editRuntime.isEditing {
                editRuntime.finish(client: client)
            }
            releaseActiveInputs()
            announce("Keypad changed to \(client.selectedGamepadProfileName)")
        }
        .onChange(of: client.isPracticeModeEnabled) { _, enabled in
            announce(enabled ? "Practice Mode enabled. Input will not be sent." : "Practice Mode disabled. Live input enabled when connected.")
        }
        .onChange(of: client.builderArtifactPracticePreview?.selectedProfileID) { _, _ in
            calibrationRuntime.cancel()
            if editRuntime.isEditing { editRuntime.cancel(client: client) }
            releaseActiveInputs()
            if client.isBuilderArtifactPracticePreviewActive {
                announce("Shared Preview. Not saved. \(client.renderedGamepadProfileName). Input is off.")
            }
        }
        .onChange(of: calibrationRuntime.isActive) { wasActive, isActive in
            if wasActive && !isActive {
                restorePracticeModeAfterCalibration()
            }
        }
        .onChange(of: client.gamepadCustomization) { _, _ in
            guard !editRuntime.isEditing else { return }
            releaseActiveInputs()
        }
        .onChange(of: client.gamepadProfiles) { _, _ in
            guard !editRuntime.isEditing else { return }
            releaseActiveInputs()
        }
        .fileExporter(
            isPresented: $isExportingKeypadConfiguration,
            document: keypadExportDocument,
            contentType: .json,
            defaultFilename: keypadExportFilename
        ) { _ in }
    }

    private func resolvedControllerSafeAreaInsets(_ geometryInsets: EdgeInsets) -> EdgeInsets {
        if geometryInsets.top > 0 || geometryInsets.bottom > 0 || geometryInsets.leading > 0 || geometryInsets.trailing > 0 {
            return geometryInsets
        }
        guard let windowInsets = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .safeAreaInsets
        else {
            return geometryInsets
        }
        return EdgeInsets(
            top: windowInsets.top,
            leading: windowInsets.left,
            bottom: windowInsets.bottom,
            trailing: windowInsets.right
        )
    }

    private func applyInitialTopBarVisibility() {
        // Keep a live keypad visually clean. Offline and editing states still pin
        // the controls open because their status and recovery actions are critical.
        isTopBarVisible = ControllerRuntimeChromePolicy.resolvedTopBarVisibility(
            requestedVisibility: false,
            isConnected: client.isConnected,
            isEditingLayout: editRuntime.isEditing
        )
    }

    private func showKeypadSettings() {
        releaseActiveInputs()
        isShowingKeypadSettings = true
    }

    private func startCalibration(in context: ControllerPadRenderContext) {
        guard !client.isBuilderArtifactPracticePreviewActive else { return }
        releaseActiveInputs()
        practiceModeBeforeCalibration = client.isPracticeModeEnabled
        if !client.isPracticeModeEnabled {
            client.setPracticeModeEnabled(true)
        }
        calibrationRuntime.begin(
            profileID: client.selectedGamepadProfileID,
            customization: context.customization,
            orientation: context.orientation,
            canvasSize: context.size,
            safeAreaInsets: context.safeAreaInsets
        )
    }

    private func restorePracticeModeAfterCalibration() {
        guard let previousValue = practiceModeBeforeCalibration else { return }
        practiceModeBeforeCalibration = nil
        if client.isPracticeModeEnabled != previousValue {
            client.setPracticeModeEnabled(previousValue)
        }
    }

    private var practiceModeBinding: Binding<Bool> {
        Binding(
            get: { client.isPracticeModeEnabled },
            set: { client.setPracticeModeEnabled($0) }
        )
    }

    private var keypadColorSchemePreferenceBinding: Binding<GamepadColorSchemePreference> {
        Binding(
            get: { client.gamepadCustomization.colorSchemePreference },
            set: { client.setKeypadColorSchemePreference($0) }
        )
    }

    private var keypadOrientationPreferenceBinding: Binding<GamepadProfileOrientationPreference> {
        Binding(
            get: { client.selectedGamepadProfileOrientationPreference },
            set: { _ = client.setSelectedGamepadProfileOrientationPreference($0) }
        )
    }

    private func showConnectionPage() {
        releaseActiveInputs()
        onShowConnectionPage?()
    }

    private func releaseActiveInputs() {
        editRuntime.releaseInputs(client: client)
    }

    private func announce(_ message: String) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    private var keypadExportDocument: ThumbleKeypadConfigurationJSONDocument {
        ThumbleKeypadConfigurationJSONDocument(
            export: ThumbleKeypadConfigurationExport(
                profiles: client.gamepadProfiles,
                activeProfileID: client.selectedGamepadProfileID,
                defaultProfileID: client.defaultGamepadProfileID
            )
        )
    }

    private var keypadExportFilename: String {
        ThumbleKeypadConfigurationExport.suggestedFilename(activeProfileName: client.selectedGamepadProfileName)
    }
}

@MainActor
private final class ControllerPadCustomizationSnapshot {
    let value: GamepadCustomization

    init(
        client: ControllerClient,
        orientation: GamepadEditorDeviceOrientation,
        systemColorScheme: ColorScheme
    ) {
        if let selectedProfile = client.renderedGamepadProfile {
            let local = selectedProfile.customization(for: orientation)
            let resolvedScheme = local.resolvedColorScheme(system: systemColorScheme)
            value = selectedProfile.resolvedCustomization(
                for: orientation,
                colorScheme: resolvedScheme == .dark ? .dark : .light,
                skinPackage: client.skinPackage(for: selectedProfile.skinReference)
            )
        } else {
            value = client.gamepadCustomization
        }
    }
}

/// Immutable per-render snapshot. Child views carry this reference instead of
/// copying the large `GamepadCustomization` value through every routing layer.
@MainActor
private final class ControllerPadRenderContext {
    let size: CGSize
    let safeAreaInsets: EdgeInsets
    let orientation: GamepadEditorDeviceOrientation
    let colorScheme: ColorScheme
    let layoutRoute: GamepadControllerLayoutRoute
    private let customizationSnapshot: ControllerPadCustomizationSnapshot

    var customization: GamepadCustomization { customizationSnapshot.value }

    var isLandscape: Bool { orientation == .landscape }

    init(
        size: CGSize,
        safeAreaInsets: EdgeInsets,
        client: ControllerClient,
        orientation: GamepadEditorDeviceOrientation,
        isEditingLayout: Bool,
        systemColorScheme: ColorScheme
    ) {
        let customizationSnapshot = ControllerPadCustomizationSnapshot(
            client: client,
            orientation: orientation,
            systemColorScheme: systemColorScheme
        )
        self.size = size
        self.safeAreaInsets = safeAreaInsets
        self.orientation = orientation
        self.customizationSnapshot = customizationSnapshot
        self.colorScheme = customizationSnapshot.value.resolvedColorScheme(system: systemColorScheme)
        self.layoutRoute = GamepadControllerPresentationRouting.layoutRoute(
            orientation: orientation,
            isEditingLayout: isEditingLayout,
            usesFreeformLayout: customizationSnapshot.value.usesFreeformLayout
        )
    }
}

/// A nominal boundary around the controller's geometry-dependent scene.
private struct ControllerPadGeometryScene: View {
    @EnvironmentObject private var client: ControllerClient
    let context: ControllerPadRenderContext
    @Binding var isTopBarVisible: Bool
    @Binding var isExportingKeypadConfiguration: Bool
    @ObservedObject var editRuntime: IOSKeypadEditRuntime
    @ObservedObject var calibrationRuntime: ThumbPlacementCalibrationRuntime
    let onShowSettings: () -> Void
    let onShowConnectionPage: (() -> Void)?
    let onShowOnboarding: (() -> Void)?

    var body: some View {
        ZStack(alignment: .top) {
            GamepadArtworkLayersView(
                layers: context.customization.artworkLayers,
                plane: .underlay
            )
            ControllerPadRuntimeSurface(context: context, editRuntime: editRuntime)
            GamepadArtworkLayersView(
                layers: context.customization.artworkLayers,
                plane: .overlay
            )
            ControllerPadTopChrome(
                context: context,
                isTopBarVisible: $isTopBarVisible,
                isExportingKeypadConfiguration: $isExportingKeypadConfiguration,
                editRuntime: editRuntime,
                onShowSettings: onShowSettings,
                onShowConnectionPage: onShowConnectionPage,
                onShowOnboarding: onShowOnboarding
            )

        }
        .allowsHitTesting(!calibrationRuntime.isActive)
        .accessibilityHidden(calibrationRuntime.isActive)
        .overlay {
            if calibrationRuntime.isActive {
                ThumbPlacementCalibrationOverlay(
                    runtime: calibrationRuntime,
                    canvasSize: context.size,
                    safeAreaInsets: context.safeAreaInsets,
                    onAcceptSuggestion: acceptCalibrationSuggestion
                )
            }
        }
        .overlay(alignment: .bottom) {
            ControllerPadRuntimeBottomChrome(
                context: context,
                editRuntime: editRuntime,
                onShowConnectionPage: onShowConnectionPage
            )
        }
        .background { ControllerPadBackground(context: context) }
        .environment(\.colorScheme, context.colorScheme)
        .frame(width: context.size.width, height: context.size.height)
        .onChange(of: context.orientation) { _, _ in
            calibrationRuntime.cancel()
            editRuntime.releaseInputs(client: client)
            if editRuntime.isEditing {
                editRuntime.finish(client: client)
            }
        }
    }

    private func acceptCalibrationSuggestion(_ suggestion: ThumbPlacementSuggestionKind) {
        guard let next = calibrationRuntime.customization(byApplying: suggestion, to: context.customization) else {
            calibrationRuntime.complete()
            return
        }
        if !editRuntime.isEditing {
            editRuntime.begin(with: context.customization, client: client)
        }
        editRuntime.apply(next, orientation: context.orientation, isFinal: true, client: client)
        calibrationRuntime.complete()
    }
}

private struct ControllerPadRuntimeSurface: View {
    @EnvironmentObject private var client: ControllerClient
    let context: ControllerPadRenderContext
    @ObservedObject var editRuntime: IOSKeypadEditRuntime

    var body: some View {
        ControllerPadLayoutRouter(
            context: context,
            isEditingLayout: editRuntime.isEditing,
            onCustomizationChanged: applyCustomization
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(isKeypadInteractionActive)
        .accessibilityHidden(!isKeypadInteractionActive)
        .saturation(isKeypadInteractionActive ? 1 : 0.35)
        .opacity(isKeypadInteractionActive ? 1 : 0.78)
    }

    private var isKeypadInteractionActive: Bool {
        ControllerRuntimeChromePolicy.isKeypadInteractionActive(
            isConnected: client.isConnected,
            isPracticeModeEnabled: client.isPracticeModeEnabled,
            isEditingLayout: editRuntime.isEditing
        )
    }

    private func applyCustomization(_ customization: GamepadCustomization, isFinal: Bool) {
        editRuntime.apply(
            customization,
            orientation: context.orientation,
            isFinal: isFinal,
            client: client
        )
    }
}

private struct ControllerPadTopChrome: View {
    @EnvironmentObject private var client: ControllerClient
    let context: ControllerPadRenderContext
    @Binding var isTopBarVisible: Bool
    @Binding var isExportingKeypadConfiguration: Bool
    @ObservedObject var editRuntime: IOSKeypadEditRuntime
    let onShowSettings: () -> Void
    let onShowConnectionPage: (() -> Void)?
    let onShowOnboarding: (() -> Void)?

    private var pinsTopBar: Bool {
        ControllerRuntimeChromePolicy.shouldPinTopBar(
            isConnected: client.isConnected,
            isEditingLayout: editRuntime.isEditing
        )
    }

    var body: some View {
        ControllerTopBarDrawer(
            isVisible: $isTopBarVisible,
            isPinned: pinsTopBar,
            safeAreaInsets: context.safeAreaInsets,
            isLandscape: context.isLandscape,
            activationFrame: context.customization.topBarActivationFrame(in: context.size),
            collapsedTitle: client.isPracticeModeEnabled
                ? "Practice • Input Off"
                : (client.isConnected ? "Connected" : "Saved keypad")
        ) {
            ControllerPadTopBar(
                context: context,
                isEditingLayout: editRuntime.isEditing,
                isExportingKeypadConfiguration: $isExportingKeypadConfiguration,
                onToggleEditing: toggleEditing,
                onShowSettings: onShowSettings,
                onShowConnectionPage: onShowConnectionPage,
                onShowOnboarding: onShowOnboarding
            )
        }
        .onChange(of: pinsTopBar) { _, isPinned in
            if isPinned { isTopBarVisible = true }
        }
    }

    private func toggleEditing() {
        guard !client.isBuilderArtifactPracticePreviewActive else { return }
        if editRuntime.isEditing {
            editRuntime.finish(client: client)
        } else {
            editRuntime.begin(with: context.customization, client: client)
        }
    }
}

private struct ControllerPadRuntimeBottomChrome: View {
    @EnvironmentObject private var client: ControllerClient
    let context: ControllerPadRenderContext
    @ObservedObject var editRuntime: IOSKeypadEditRuntime
    let onShowConnectionPage: (() -> Void)?

    var body: some View {
        VStack(spacing: Geist.Spacing.s2) {
            if editRuntime.isEditing {
                ControllerPadEditingCommandStrip(
                    canUndo: editRuntime.canUndo,
                    hasChanges: editRuntime.hasChanges,
                    feedback: editRuntime.feedback,
                    onDone: { editRuntime.finish(client: client) },
                    onUndo: { editRuntime.undo(client: client) },
                    onCancel: { editRuntime.cancel(client: client) }
                )
            }

            if let preview = client.builderArtifactPracticePreview, !editRuntime.isEditing {
                IOSBuilderArtifactPracticeBanner(preview: preview)
            } else if !client.isConnected && !client.isPracticeModeEnabled && !editRuntime.isEditing {
                ControllerPadOfflineBanner(
                    onReconnect: reconnect,
                    onPractice: { client.setPracticeModeEnabled(!client.isPracticeModeEnabled) },
                    onHome: onShowConnectionPage
                )
            }
        }
        .padding(.horizontal, max(Geist.Spacing.s3, context.safeAreaInsets.leading + Geist.Spacing.s2))
        .padding(.bottom, max(Geist.Spacing.s2, context.safeAreaInsets.bottom + Geist.Spacing.s1))
    }

    private func reconnect() {
        editRuntime.releaseInputs(client: client)
        client.startSmartConnect()
    }
}

private struct IOSBuilderArtifactPracticeBanner: View {
    @EnvironmentObject private var client: ControllerClient
    let preview: IOSBuilderArtifactPracticePreview

    var body: some View {
        HStack(spacing: Geist.Spacing.s3) {
            Image(systemName: "hand.tap.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Shared Preview • Not Saved")
                    .font(.caption.weight(.semibold))
                Text(preview.selectedProfile?.name ?? "Shared Controller")
                    .font(.caption2)
                    .lineLimit(1)
            }
            Spacer(minLength: Geist.Spacing.s2)
            if preview.profiles.count > 1 {
                Menu("Profiles") {
                    ForEach(preview.profiles) { profile in
                        Button {
                            client.selectBuilderArtifactPracticeProfile(profile.id)
                        } label: {
                            Label(
                                profile.name,
                                systemImage: profile.id == preview.selectedProfileID ? "checkmark.circle.fill" : "rectangle.grid.2x2"
                            )
                        }
                    }
                }
                .buttonStyle(.bordered)
            }
            Button("Close") {
                client.endBuilderArtifactPracticePreview()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, Geist.Spacing.s4)
        .padding(.vertical, Geist.Spacing.s3)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Geist.Radius.md))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Shared Preview. Not saved. \(preview.selectedProfile?.name ?? "Shared Controller"). Input is off.")
    }
}

private struct ControllerPadBackground: View {
    let context: ControllerPadRenderContext

    var body: some View {
        GamepadFillShapeLayer(
            shape: Rectangle(),
            fillStyle: context.customization.keypadBackgroundFillStyle(scheme: context.colorScheme)
        )
        .ignoresSafeArea()
    }
}

/// The only orientation/style type-erasure boundary in the controller canvas.
private struct ControllerPadLayoutRouter: View {
    let context: ControllerPadRenderContext
    let isEditingLayout: Bool
    let onCustomizationChanged: (GamepadCustomization, Bool) -> Void

    var body: AnyView {
        switch context.layoutRoute {
        case .standard(.landscape):
            return AnyView(ControllerPadStandardLandscapeLayout(context: context))
        case .standard(.portrait):
            return AnyView(ControllerPadStandardPortraitLayout(context: context))
        case .freeform:
            return AnyView(
                ControllerPadFreeformLayout(
                    context: context,
                    isEditingLayout: isEditingLayout,
                    onCustomizationChanged: onCustomizationChanged
                )
            )
        }
    }
}

private struct ControllerPadFreeformLayout: View {
    let context: ControllerPadRenderContext
    let isEditingLayout: Bool
    let onCustomizationChanged: (GamepadCustomization, Bool) -> Void

    var body: some View {
        GamepadFreeformControllerCanvas(
            context: context,
            isEditingLayout: isEditingLayout,
            onCustomizationChanged: onCustomizationChanged
        )
        // Freeform coordinates are authored against the editor's full device
        // canvas, which already shows the Dynamic Island/notch. Insetting this
        // view a second time changes both normalized positions and responsive
        // control sizes, so the iPhone no longer matches the Mac preview.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if !isEditingLayout {
                TouchRoutingView()
            }
        }
    }
}

private struct ControllerPadStandardLandscapeLayout: View {
    let context: ControllerPadRenderContext

    var body: some View {
        let metrics = LandscapeControllerMetrics(
            size: context.size,
            safeAreaInsets: context.safeAreaInsets,
            controlScale: context.customization.controlScale
        )
        let slots = GamepadControllerPresentationRouting.standardSlots(
            orientation: .landscape,
            layoutMode: context.customization.layoutMode
        )

        HStack(alignment: .center, spacing: metrics.controlSpacing) {
            ForEach(slots) { slot in
                ControllerPadLandscapeSlotRouter(
                    context: context,
                    metrics: metrics,
                    slot: slot
                )
            }
        }
        .padding(.leading, metrics.leadingPadding)
        .padding(.trailing, metrics.trailingPadding)
        .padding(.bottom, metrics.bottomPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            TouchRoutingView()
        }
    }
}

private struct ControllerPadLandscapeSlotRouter: View {
    let context: ControllerPadRenderContext
    let metrics: LandscapeControllerMetrics
    let slot: GamepadStandardLayoutSlot

    var body: AnyView {
        switch slot {
        case .control(.dPad):
            return AnyView(ControllerPadLandscapeDPad(context: context, metrics: metrics))
        case .control(.utilityButtons):
            return AnyView(ControllerPadLandscapeUtilityButtons(context: context, metrics: metrics))
        case .control(.actionButtons):
            return AnyView(ControllerPadLandscapeActionButtons(context: context, metrics: metrics))
        case .flexibleSpace:
            return AnyView(Spacer(minLength: metrics.spacerMinLength))
        }
    }
}

private struct ControllerPadLandscapeDPad: View {
    let context: ControllerPadRenderContext
    let metrics: LandscapeControllerMetrics

    var body: some View {
        DPadView(buttonSize: metrics.dPadButtonSize, customization: context.customization)
            .frame(width: metrics.dPadHitSize.width * 3, height: metrics.dPadHitSize.height * 3)
            .fixedSize()
    }
}

private struct ControllerPadLandscapeActionButtons: View {
    let context: ControllerPadRenderContext
    let metrics: LandscapeControllerMetrics

    var body: some View {
        ActionButtonsView(buttonSize: metrics.actionButtonSize, customization: context.customization)
            .frame(width: metrics.actionHitSize.width * 2, height: metrics.actionHitSize.height * 2)
            .fixedSize()
    }
}

private struct ControllerPadLandscapeUtilityButtons: View {
    let context: ControllerPadRenderContext
    let metrics: LandscapeControllerMetrics

    var body: some View {
        ControllerPadUtilityButtons(
            context: context,
            mapButtonSize: metrics.mapButtonSize,
            pauseButtonSize: metrics.pauseButtonSize,
            spacing: metrics.utilitySpacing
        )
        .frame(width: metrics.utilityHitWidth, height: metrics.utilityHitHeight)
        .fixedSize()
        .layoutPriority(1)
    }
}

private struct ControllerPadStandardPortraitLayout: View {
    let context: ControllerPadRenderContext

    var body: some View {
        let metrics = PortraitControllerMetrics(
            size: context.size,
            safeAreaInsets: context.safeAreaInsets,
            controlScale: context.customization.controlScale
        )
        let slots = GamepadControllerPresentationRouting.standardSlots(
            orientation: .portrait,
            layoutMode: context.customization.layoutMode
        )

        VStack(spacing: Geist.Spacing.s4) {
            ForEach(slots) { slot in
                ControllerPadPortraitSlotRouter(
                    context: context,
                    metrics: metrics,
                    slot: slot
                )
            }
        }
        .padding(.leading, metrics.leadingPadding)
        .padding(.trailing, metrics.trailingPadding)
        .padding(.bottom, metrics.bottomPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            TouchRoutingView()
        }
    }
}

private struct ControllerPadPortraitSlotRouter: View {
    let context: ControllerPadRenderContext
    let metrics: PortraitControllerMetrics
    let slot: GamepadStandardLayoutSlot

    var body: AnyView {
        switch slot {
        case .control(.dPad):
            return AnyView(ControllerPadPortraitDPad(context: context, metrics: metrics))
        case .control(.utilityButtons):
            return AnyView(ControllerPadPortraitUtilityButtons(context: context, metrics: metrics))
        case .control(.actionButtons):
            return AnyView(ControllerPadPortraitActionButtons(context: context, metrics: metrics))
        case .flexibleSpace:
            return AnyView(Spacer(minLength: Geist.Spacing.s2))
        }
    }
}

private struct ControllerPadPortraitDPad: View {
    let context: ControllerPadRenderContext
    let metrics: PortraitControllerMetrics

    var body: some View {
        DPadView(buttonSize: metrics.dPadButtonSize, customization: context.customization)
            .frame(width: metrics.dPadHitSize.width * 3, height: metrics.dPadHitSize.height * 3)
    }
}

private struct ControllerPadPortraitActionButtons: View {
    let context: ControllerPadRenderContext
    let metrics: PortraitControllerMetrics

    var body: some View {
        ActionButtonsView(buttonSize: metrics.actionButtonSize, customization: context.customization)
            .frame(width: metrics.actionHitSize.width * 2, height: metrics.actionHitSize.height * 2)
    }
}

private struct ControllerPadPortraitUtilityButtons: View {
    let context: ControllerPadRenderContext
    let metrics: PortraitControllerMetrics

    var body: some View {
        ControllerPadUtilityButtons(
            context: context,
            mapButtonSize: metrics.mapButtonSize,
            pauseButtonSize: metrics.pauseButtonSize,
            spacing: Geist.Spacing.s4
        )
    }
}

private struct ControllerPadUtilityButtons: View {
    let context: ControllerPadRenderContext
    let mapButtonSize: CGSize
    let pauseButtonSize: CGSize
    let spacing: CGFloat

    var body: some View {
        HStack(spacing: spacing) {
            GamepadButton(
                button: .map,
                size: mapButtonSize,
                shape: .capsule,
                customization: context.customization
            )
            GamepadButton(
                button: .pause,
                size: pauseButtonSize,
                shape: .capsule,
                customization: context.customization
            )
        }
    }
}

private struct ControllerPadTopBar: View {
    @EnvironmentObject private var client: ControllerClient
    let context: ControllerPadRenderContext
    let isEditingLayout: Bool
    @Binding var isExportingKeypadConfiguration: Bool
    let onToggleEditing: () -> Void
    let onShowSettings: () -> Void
    let onShowConnectionPage: (() -> Void)?
    let onShowOnboarding: (() -> Void)?

    var body: some View {
        GamepadControlBarLayout(
            items: visibleItems,
            isLandscape: context.isLandscape
        ) { item, isCompact in
            ControllerPadTopBarItemRouter(
                context: context,
                item: item,
                isCompact: isCompact,
                isEditingLayout: isEditingLayout,
                isExportingKeypadConfiguration: $isExportingKeypadConfiguration,
                onToggleEditing: onToggleEditing,
                onShowSettings: onShowSettings,
                onShowConnectionPage: onShowConnectionPage,
                onShowOnboarding: onShowOnboarding
            )
        }
    }

    private var visibleItems: [GamepadControlBarItem] {
        let items = context.customization.normalized.controlBarItems
        let hiddenItems = Set(items.filter {
            context.customization.controlBarItemCustomization(for: $0).isHidden
        })
        return GamepadControllerPresentationRouting.visibleControlBarItems(
            items,
            hiddenItems: hiddenItems,
            hasProfiles: !client.gamepadProfiles.isEmpty,
            hasLaunchTarget: client.selectedGamepadProfile?.launchTarget != nil
        )
    }
}

/// Closed leaf router: each branch constructs one nominal item view.
private struct ControllerPadTopBarItemRouter: View {
    let context: ControllerPadRenderContext
    let item: GamepadControlBarItem
    let isCompact: Bool
    let isEditingLayout: Bool
    @Binding var isExportingKeypadConfiguration: Bool
    let onToggleEditing: () -> Void
    let onShowSettings: () -> Void
    let onShowConnectionPage: (() -> Void)?
    let onShowOnboarding: (() -> Void)?

    var body: AnyView {
        switch item {
        case .connectionStatus:
            return AnyView(ControllerPadStatusItem(context: context))
        case .profileMenu:
            return AnyView(
                ControllerPadProfileMenuItem(
                    context: context,
                    isCompact: isCompact,
                    isEditingLayout: isEditingLayout,
                    isExportingKeypadConfiguration: $isExportingKeypadConfiguration
                )
            )
        case .launchTarget:
            return AnyView(ControllerPadLaunchTargetItem(context: context, isCompact: isCompact))
        case .spacer:
            return AnyView(ControllerPadSpacerItem(context: context, isCompact: isCompact))
        case .editLayout:
            return AnyView(
                ControllerPadEditLayoutItem(
                    context: context,
                    isCompact: isCompact,
                    isEditingLayout: isEditingLayout,
                    onToggleEditing: onToggleEditing
                )
            )
        case .settings:
            return AnyView(
                ControllerPadSettingsItem(
                    context: context,
                    onShowSettings: onShowSettings
                )
            )
        case .home:
            return AnyView(
                ControllerPadHomeItem(
                    context: context,
                    onShowConnectionPage: onShowConnectionPage
                )
            )
        case .connectionAction:
            return AnyView(
                ControllerPadConnectionItem(
                    context: context,
                    isCompact: isCompact,
                    onShowConnectionPage: onShowConnectionPage
                )
            )
        }
    }
}

private struct ControllerPadStatusItem: View {
    @EnvironmentObject private var client: ControllerClient
    let context: ControllerPadRenderContext

    var body: some View {
        GamepadControlBarStatusPill(
            customization: context.customization,
            title: title,
            systemImage: systemImage,
            tone: tone
        )
        .accessibilityLabel(client.isPracticeModeEnabled ? "Practice Mode. Outgoing input is off." : title)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var title: String {
        if client.isPracticeModeEnabled { return "Practice" }
        return switch client.state {
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .pairingCodeRequired: "Pairing Needed"
        case .failed, .disconnected: "Saved Keypad"
        }
    }

    private var systemImage: String {
        if client.isPracticeModeEnabled { return "hand.tap.fill" }
        return switch client.state {
        case .connected: "wifi"
        case .connecting: "arrow.triangle.2.circlepath"
        case .pairingCodeRequired: "key.fill"
        case .failed, .disconnected: "rectangle.grid.2x2"
        }
    }

    private var tone: GeistInterfaceTone {
        if client.isPracticeModeEnabled { return .warning }
        return switch client.state {
        case .connected: .success
        case .connecting, .pairingCodeRequired: .warning
        case .failed, .disconnected: .neutral
        }
    }
}

private struct ControllerPadProfileMenuItem: View {
    @EnvironmentObject private var client: ControllerClient
    let context: ControllerPadRenderContext
    let isCompact: Bool
    let isEditingLayout: Bool
    @Binding var isExportingKeypadConfiguration: Bool

    var body: some View {
        Menu {
            ForEach(client.gamepadProfiles) { profile in
                Button {
                    client.selectGamepadProfile(profile.id)
                } label: {
                    Label(profile.name, systemImage: profileSystemImage(profile))
                }
            }

            Divider()

            Button {
                client.setDefaultGamepadProfile(client.selectedGamepadProfileID)
            } label: {
                Label(
                    client.isSelectedGamepadProfileDefault ? "Current Is Default" : "Make Current Default",
                    systemImage: client.isSelectedGamepadProfileDefault ? "star.fill" : "star"
                )
            }
            .disabled(client.isSelectedGamepadProfileDefault)

            Button {
                isExportingKeypadConfiguration = true
            } label: {
                Label("Export Keypads as JSON", systemImage: "square.and.arrow.up")
            }
        } label: {
            ControllerPadProfileMenuLabelRouter(context: context, isCompact: isCompact)
        }
        .gamepadControlBarButtonStyle(customization: context.customization, item: .profileMenu)
        .disabled(isEditingLayout || client.isBuilderArtifactPracticePreviewActive)
        .accessibilityLabel(isCompact ? "Keypad setup: \(client.selectedGamepadProfileName)" : "Keypad setup")
        .accessibilityHint(isEditingLayout ? "Finish editing before switching keypad setups." : "Switches, defaults, or exports keypad setups.")
    }

    private func profileSystemImage(_ profile: GamepadConfigurationProfile) -> String {
        if profile.id == client.selectedGamepadProfileID { return "checkmark.circle.fill" }
        if profile.id == client.defaultGamepadProfileID { return "star.fill" }
        return profile.launchTarget != nil ? "app.badge.fill" : "rectangle.grid.2x2"
    }
}

private struct ControllerPadProfileMenuLabelRouter: View {
    let context: ControllerPadRenderContext
    let isCompact: Bool

    var body: AnyView {
        if isCompact {
            return AnyView(ControllerPadCompactProfileMenuLabel(context: context))
        }
        return AnyView(ControllerPadExpandedProfileMenuLabel(context: context))
    }
}

private struct ControllerPadCompactProfileMenuLabel: View {
    @EnvironmentObject private var client: ControllerClient
    let context: ControllerPadRenderContext

    var body: some View {
        GamepadControlBarItemIcon(
            customization: context.customization,
            item: .profileMenu,
            defaultSystemImage: client.isSelectedGamepadProfileDefault ? "star.fill" : "rectangle.grid.2x2",
            fontSize: 13,
            frameWidth: 28
        )
    }
}

private struct ControllerPadExpandedProfileMenuLabel: View {
    @EnvironmentObject private var client: ControllerClient
    let context: ControllerPadRenderContext

    var body: some View {
        HStack(spacing: Geist.Spacing.s1) {
            GamepadControlBarItemIcon(
                customization: context.customization,
                item: .profileMenu,
                defaultSystemImage: client.isSelectedGamepadProfileDefault ? "star.fill" : "rectangle.grid.2x2",
                fontSize: 11
            )
            Text(client.selectedGamepadProfileName)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: 160)
    }
}

private struct ControllerPadLaunchTargetItem: View {
    @EnvironmentObject private var client: ControllerClient
    let context: ControllerPadRenderContext
    let isCompact: Bool

    var body: some View {
        Button {
            client.launchSelectedProfileTarget()
        } label: {
            ControllerPadLaunchTargetLabelRouter(context: context, isCompact: isCompact)
        }
        .gamepadControlBarButtonStyle(customization: context.customization, item: .launchTarget)
        .disabled(!client.isConnected || client.isBuilderArtifactPracticePreviewActive)
        .accessibilityLabel("Launch \(client.selectedGamepadProfile?.launchTarget?.displayName ?? "attached application")")
        .accessibilityHint("Asks the paired Mac to open the application attached to this keypad setup.")
    }
}

private struct ControllerPadLaunchTargetLabelRouter: View {
    @EnvironmentObject private var client: ControllerClient
    let context: ControllerPadRenderContext
    let isCompact: Bool

    var body: AnyView {
        let size: CGFloat = isCompact ? 18 : 20
        if context.customization.controlBarItemCustomization(for: .launchTarget).icon != nil {
            return AnyView(
                ControllerPadConfiguredLaunchTargetLabel(context: context, size: size)
            )
        }
        if let launchTarget = client.selectedGamepadProfile?.launchTarget {
            return AnyView(
                ControllerPadApplicationLaunchTargetLabel(launchTarget: launchTarget, size: size)
            )
        }
        return AnyView(ControllerPadFallbackLaunchTargetLabel(context: context))
    }
}

private struct ControllerPadConfiguredLaunchTargetLabel: View {
    let context: ControllerPadRenderContext
    let size: CGFloat

    var body: some View {
        GamepadControlBarItemIcon(
            customization: context.customization,
            item: .launchTarget,
            defaultSystemImage: "app.badge.fill",
            fontSize: size,
            frameWidth: 28
        )
    }
}

private struct ControllerPadFallbackLaunchTargetLabel: View {
    let context: ControllerPadRenderContext

    var body: some View {
        GamepadControlBarItemIcon(
            customization: context.customization,
            item: .launchTarget,
            defaultSystemImage: "app.badge.fill",
            fontSize: 13,
            frameWidth: 28
        )
    }
}

private struct ControllerPadApplicationLaunchTargetLabel: View {
    let launchTarget: GamepadProfileLaunchTarget
    let size: CGFloat

    var body: some View {
        ControllerPadLaunchTargetIconRouter(launchTarget: launchTarget, size: size)
            .frame(width: 28, height: 28)
    }
}

private struct ControllerPadLaunchTargetIconRouter: View {
    let launchTarget: GamepadProfileLaunchTarget
    let size: CGFloat

    var body: AnyView {
        if let data = launchTarget.iconPNGData, let image = UIImage(data: data) {
            return AnyView(ControllerPadLaunchTargetImage(image: image, size: size))
        }
        return AnyView(ControllerPadLaunchTargetSystemImage(size: size))
    }
}

private struct ControllerPadLaunchTargetImage: View {
    let image: UIImage
    let size: CGFloat

    var body: some View {
        Image(uiImage: image)
            .renderingMode(.original)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: max(4, size * 0.22), style: .continuous))
    }
}

private struct ControllerPadLaunchTargetSystemImage: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: "app.badge.fill")
            .font(.system(size: size, weight: .semibold))
            .frame(width: size, height: size)
    }
}

private struct ControllerPadSpacerItem: View {
    let context: ControllerPadRenderContext
    let isCompact: Bool

    var body: some View {
        Spacer(
            minLength: (isCompact ? 2 : Geist.Spacing.s2)
                * context.customization.controlBarItemCustomization(for: .spacer).widthScale
        )
    }
}

private struct ControllerPadEditLayoutItem: View {
    @EnvironmentObject private var client: ControllerClient
    let context: ControllerPadRenderContext
    let isCompact: Bool
    let isEditingLayout: Bool
    let onToggleEditing: () -> Void

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
                onToggleEditing()
            }
        } label: {
            HStack(spacing: Geist.Spacing.s1) {
                GamepadControlBarItemIcon(
                    customization: context.customization,
                    item: .editLayout,
                    defaultSystemImage: isEditingLayout ? "checkmark" : "slider.horizontal.3",
                    fontSize: 13
                )
                if !isCompact {
                    Text(isEditingLayout ? "Done" : "Edit")
                        .lineLimit(1)
                }
            }
        }
        .gamepadControlBarButtonStyle(
            customization: context.customization,
            item: .editLayout,
            variant: isEditingLayout ? .primary : .secondary
        )
        .disabled(client.isBuilderArtifactPracticePreviewActive)
        .accessibilityLabel(isEditingLayout ? "Done editing layout" : "Edit Layout")
        .accessibilityHint(isEditingLayout ? "Finishes editing and keeps the saved layout." : "Lets you move, resize, rotate, or delete keypad elements.")
    }
}

private struct ControllerPadSettingsItem: View {
    @EnvironmentObject private var client: ControllerClient
    let context: ControllerPadRenderContext
    let onShowSettings: () -> Void

    var body: some View {
        Button(action: onShowSettings) {
            GamepadControlBarItemIcon(
                customization: context.customization,
                item: .settings,
                defaultSystemImage: "gearshape.fill",
                fontSize: 13,
                frameWidth: 28
            )
        }
        .gamepadControlBarButtonStyle(customization: context.customization, item: .settings)
        .disabled(client.isBuilderArtifactPracticePreviewActive)
        .accessibilityLabel("Keypad settings")
        .accessibilityHint("Opens keypad practice, haptic, binding glyph, calibration, appearance, and input reset settings.")
    }
}

private struct ControllerPadHomeItem: View {
    @EnvironmentObject private var client: ControllerClient
    let context: ControllerPadRenderContext
    let onShowConnectionPage: (() -> Void)?

    var body: some View {
        Button {
            TouchCaptureUIView.deactivateAllRegisteredTouches()
            client.releaseAll()
            onShowConnectionPage?()
        } label: {
            GamepadControlBarItemIcon(
                customization: context.customization,
                item: .home,
                defaultSystemImage: "house.fill",
                fontSize: 13,
                frameWidth: 28
            )
        }
        .gamepadControlBarButtonStyle(customization: context.customization, item: .home)
        .disabled(onShowConnectionPage == nil)
        .accessibilityLabel("Home")
        .accessibilityHint("Returns to the connection page without disconnecting from the Mac.")
    }
}

private enum ControllerPadConnectionPresentation {
    case connect
    case disconnect

    var title: String {
        switch self {
        case .connect: "Connect Mac"
        case .disconnect: "Disconnect"
        }
    }

    var systemImage: String {
        switch self {
        case .connect: "link"
        case .disconnect: "wifi.slash"
        }
    }
}

private struct ControllerPadConnectionItem: View {
    @EnvironmentObject private var client: ControllerClient
    let context: ControllerPadRenderContext
    let isCompact: Bool
    let onShowConnectionPage: (() -> Void)?

    var body: AnyView {
        if client.isConnected {
            return AnyView(
                ControllerPadDisconnectItem(context: context, isCompact: isCompact)
            )
        }
        return AnyView(
            ControllerPadConnectItem(
                context: context,
                isCompact: isCompact,
                onShowConnectionPage: onShowConnectionPage
            )
        )
    }
}

private struct ControllerPadDisconnectItem: View {
    @EnvironmentObject private var client: ControllerClient
    let context: ControllerPadRenderContext
    let isCompact: Bool

    var body: some View {
        Button {
            client.disconnect(sendReleaseAll: true)
        } label: {
            ControllerPadConnectionLabelRouter(
                context: context,
                presentation: .disconnect,
                isCompact: isCompact
            )
        }
        .gamepadControlBarButtonStyle(
            customization: context.customization,
            item: .connectionAction,
            variant: .error
        )
        .accessibilityLabel("Disconnect")
    }
}

private struct ControllerPadConnectItem: View {
    let context: ControllerPadRenderContext
    let isCompact: Bool
    let onShowConnectionPage: (() -> Void)?

    var body: some View {
        Button {
            onShowConnectionPage?()
        } label: {
            ControllerPadConnectionLabelRouter(
                context: context,
                presentation: .connect,
                isCompact: isCompact
            )
        }
        .gamepadControlBarButtonStyle(customization: context.customization, item: .connectionAction)
        .disabled(onShowConnectionPage == nil)
        .accessibilityLabel("Connect Mac")
    }
}

private struct ControllerPadConnectionLabelRouter: View {
    let context: ControllerPadRenderContext
    let presentation: ControllerPadConnectionPresentation
    let isCompact: Bool

    var body: AnyView {
        if isCompact {
            return AnyView(
                ControllerPadCompactConnectionLabel(
                    context: context,
                    presentation: presentation
                )
            )
        }
        if context.customization.controlBarItemCustomization(for: .connectionAction).icon != nil {
            return AnyView(
                ControllerPadExpandedConnectionLabel(
                    context: context,
                    presentation: presentation
                )
            )
        }
        return AnyView(ControllerPadTextConnectionLabel(title: presentation.title))
    }
}

private struct ControllerPadCompactConnectionLabel: View {
    let context: ControllerPadRenderContext
    let presentation: ControllerPadConnectionPresentation

    var body: some View {
        GamepadControlBarItemIcon(
            customization: context.customization,
            item: .connectionAction,
            defaultSystemImage: presentation.systemImage,
            fontSize: 13,
            frameWidth: 28
        )
    }
}

private struct ControllerPadExpandedConnectionLabel: View {
    let context: ControllerPadRenderContext
    let presentation: ControllerPadConnectionPresentation

    var body: some View {
        HStack(spacing: Geist.Spacing.s1) {
            GamepadControlBarItemIcon(
                customization: context.customization,
                item: .connectionAction,
                defaultSystemImage: presentation.systemImage,
                fontSize: 13
            )
            Text(presentation.title)
        }
    }
}

private struct ControllerPadTextConnectionLabel: View {
    let title: String

    var body: some View {
        Text(title)
    }
}

private struct ControllerPadEditingCommandStrip: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let canUndo: Bool
    let hasChanges: Bool
    let feedback: String
    let onDone: () -> Void
    let onUndo: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: Geist.Spacing.s2) {
            Button(action: onCancel) {
                if usesCompactCommands {
                    Image(systemName: "xmark")
                } else {
                    Label("Cancel", systemImage: "xmark")
                }
            }
            .geistButtonStyle(.secondary, size: .small)
            .disabled(!hasChanges)
            .accessibilityLabel("Cancel editing")
            .accessibilityHint("Restores the layout from when editing began, then exits editing.")

            Button(action: onUndo) {
                if usesCompactCommands {
                    Image(systemName: "arrow.uturn.backward")
                } else {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
            }
            .geistButtonStyle(.secondary, size: .small)
            .disabled(!canUndo)
            .accessibilityLabel("Undo layout change")

            Spacer(minLength: Geist.Spacing.s1)

            if !feedback.isEmpty {
                Group {
                    if usesCompactCommands {
                        Image(systemName: "checkmark.circle.fill")
                    } else {
                        Label(feedback, systemImage: "checkmark.circle.fill")
                            .lineLimit(2)
                            .minimumScaleFactor(0.75)
                    }
                }
                .geistTypography(.label12)
                .foregroundStyle(Geist.color(.gray900, scheme: colorScheme))
                .accessibilityLabel(feedback)
                .accessibilityAddTraits(.updatesFrequently)
            }

            Button(action: onDone) {
                Label("Done", systemImage: "checkmark")
            }
            .geistButtonStyle(.primary, size: .small)
        }
        .padding(Geist.Spacing.s2)
        .frame(maxWidth: 720)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Geist.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Geist.Radius.md, style: .continuous)
                .stroke(Geist.color(.grayAlpha400, scheme: colorScheme), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.14), radius: 8, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Layout editing commands")
    }

    private var usesCompactCommands: Bool {
        horizontalSizeClass == .compact
    }
}

private struct ControllerPadOfflineBanner: View {
    @EnvironmentObject private var client: ControllerClient
    @Environment(\.colorScheme) private var colorScheme
    let onReconnect: () -> Void
    let onPractice: () -> Void
    let onHome: (() -> Void)?

    private var isReconnecting: Bool {
        client.state == .connecting || client.state == .pairingCodeRequired
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Geist.Spacing.s2) {
                compactStatusContent
                Spacer(minLength: Geist.Spacing.s1)
                actionButtons
            }
            VStack(alignment: .leading, spacing: Geist.Spacing.s2) {
                statusContent
                actionButtons
            }
        }
        .padding(.horizontal, Geist.Spacing.s3)
        .padding(.vertical, Geist.Spacing.s2)
        .frame(maxWidth: 720)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Geist.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Geist.Radius.md, style: .continuous)
                .stroke(Geist.color(.amber700, scheme: colorScheme).opacity(0.65), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 8, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityStatus)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var compactStatusContent: some View {
        Label(isReconnecting ? "Connecting…" : "Offline", systemImage: isReconnecting ? "arrow.triangle.2.circlepath" : "wifi.slash")
            .geistTypography(.heading14)
            .foregroundStyle(Geist.color(.gray1000, scheme: colorScheme))
            .lineLimit(1)
    }

    private var statusContent: some View {
        HStack(spacing: Geist.Spacing.s2) {
            Image(systemName: client.isPracticeModeEnabled ? "hand.tap.fill" : (isReconnecting ? "arrow.triangle.2.circlepath" : "wifi.slash"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Geist.color(.amber900, scheme: colorScheme))
            VStack(alignment: .leading, spacing: 1) {
                Text(statusTitle)
                    .geistTypography(.heading14)
                    .foregroundStyle(Geist.color(.gray1000, scheme: colorScheme))
                Text(statusDetail)
                    .geistTypography(.label12)
                    .foregroundStyle(Geist.color(.gray900, scheme: colorScheme))
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)
            }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: Geist.Spacing.s2) {
            Button(client.isPracticeModeEnabled ? "End Practice" : "Practice", action: onPractice)
                .geistButtonStyle(.secondary, size: .small)
            Button("Reconnect", action: onReconnect)
                .geistButtonStyle(.primary, size: .small)
                .disabled(isReconnecting)
            Button("Home") { onHome?() }
                .geistButtonStyle(.secondary, size: .small)
                .disabled(onHome == nil)
        }
    }

    private var statusTitle: String {
        if client.isPracticeModeEnabled { return "Practice Mode — offline" }
        return isReconnecting ? "Reconnecting to Mac…" : "Saved keypad — offline"
    }

    private var statusDetail: String {
        client.isPracticeModeEnabled
            ? "Controls stay interactive with haptics, but input is not sent."
            : "Use Practice Mode to try controls safely, or reconnect for live input."
    }

    private var accessibilityStatus: String {
        if client.isPracticeModeEnabled { return "Practice Mode offline. Controls work locally and will not send input." }
        return isReconnecting ? "Reconnecting to Mac" : "Saved keypad offline. Enable Practice Mode to use controls without sending input."
    }
}

private struct ControllerTopBarDrawer<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Binding var isVisible: Bool
    @State private var collapsedChromeOpacity = 1.0
    let isPinned: Bool
    let safeAreaInsets: EdgeInsets
    let isLandscape: Bool
    let activationFrame: CGRect
    let collapsedTitle: String
    let content: Content

    init(
        isVisible: Binding<Bool>,
        isPinned: Bool = false,
        safeAreaInsets: EdgeInsets,
        isLandscape: Bool,
        activationFrame: CGRect = .null,
        collapsedTitle: String = "Controls",
        @ViewBuilder content: () -> Content
    ) {
        self._isVisible = isVisible
        self.isPinned = isPinned
        self.safeAreaInsets = safeAreaInsets
        self.isLandscape = isLandscape
        self.activationFrame = activationFrame
        self.collapsedTitle = collapsedTitle
        self.content = content()
    }

    var body: some View {
        VStack(spacing: Geist.Spacing.s1) {
            if isVisible {
                content
                    .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.08), radius: 10, y: 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            revealHandle
        }
        .padding(.top, topPadding)
        .padding(.leading, leadingPadding)
        .padding(.trailing, trailingPadding)
        // Leave the empty width around the drawer transparent to touches. The
        // visible bar and compact reveal handle install their own drag gestures.
        .frame(maxWidth: .infinity, alignment: .top)
        .background {
            ControllerTopBarSwipeBridge(
                isVisible: $isVisible,
                isPinned: isPinned,
                animation: drawerAnimation,
                activationFrame: activationFrame
            )
        }
        .animation(drawerAnimation, value: isVisible)
        .animation(drawerAnimation, value: activationFrame)
        .onAppear { enforcePinnedVisibility() }
        .onChange(of: isPinned) { _, _ in enforcePinnedVisibility() }
        .task(id: collapsedChromeTaskID) {
            collapsedChromeOpacity = 1
            guard !isVisible, !isPinned else { return }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled, !isVisible, !isPinned else { return }
            withAnimation(accessibilityReduceMotion ? nil : .easeOut(duration: 0.6)) {
                collapsedChromeOpacity = 0
            }
        }
        .zIndex(10)
    }

    private var revealHandle: some View {
        Button {
            setVisible(!isVisible)
        } label: {
            Group {
                if isVisible {
                    VStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(Geist.color(.grayAlpha700, scheme: colorScheme))
                            .frame(width: 36, height: 5)
                        Image(systemName: isPinned ? "pin.fill" : "chevron.up")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Geist.color(.gray900, scheme: colorScheme))
                    }
                } else {
                    VStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(Geist.color(.grayAlpha700, scheme: colorScheme))
                            .frame(width: 36, height: 5)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Geist.color(.gray900, scheme: colorScheme))
                    }
                }
            }
            .padding(.horizontal, Geist.Spacing.s3)
            .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.plain)
        .opacity(isVisible ? 1 : collapsedChromeOpacity)
        .simultaneousGesture(drawerDragGesture)
        .accessibilityLabel(isPinned ? "Connection bar pinned open" : (isVisible ? "Hide connection bar" : "Show connection bar, \(collapsedTitle)"))
        .accessibilityHint(isPinned ? "The connection bar stays available while offline or editing." : (isVisible ? "Swipe up or tap to hide the connection controls." : "Swipe down or tap to show the connection controls."))
    }

    private var drawerDragGesture: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .onEnded { value in
                let verticalMovement = dominantMovement(
                    current: value.translation.height,
                    predicted: value.predictedEndTranslation.height
                )
                let horizontalMovement = max(
                    abs(value.translation.width),
                    abs(value.predictedEndTranslation.width)
                )
                guard abs(verticalMovement) > max(18, horizontalMovement * 0.65) else { return }

                setVisible(verticalMovement > 0)
            }
    }

    private func dominantMovement(current: CGFloat, predicted: CGFloat) -> CGFloat {
        abs(predicted) > abs(current) ? predicted : current
    }

    private var topPadding: CGFloat {
        let topInset = max(effectiveSafeAreaInsets.top, minimumPortraitTopInset)
        let extraPadding = isLandscape ? Geist.Spacing.s2 : 0
        return max(isLandscape ? Geist.Spacing.s3 : Geist.Spacing.s2, topInset + extraPadding)
    }

    private var leadingPadding: CGFloat {
        max(isLandscape ? Geist.Spacing.s6 : Geist.Spacing.s4, effectiveSafeAreaInsets.leading + Geist.Spacing.s3)
    }

    private var trailingPadding: CGFloat {
        max(isLandscape ? Geist.Spacing.s6 : Geist.Spacing.s4, effectiveSafeAreaInsets.trailing + Geist.Spacing.s3)
    }

    private var effectiveSafeAreaInsets: EdgeInsets {
        #if os(iOS)
        let windowInsets = Self.currentWindowSafeAreaInsets()
        return EdgeInsets(
            top: max(safeAreaInsets.top, windowInsets.top),
            leading: max(safeAreaInsets.leading, windowInsets.left),
            bottom: max(safeAreaInsets.bottom, windowInsets.bottom),
            trailing: max(safeAreaInsets.trailing, windowInsets.right)
        )
        #else
        return safeAreaInsets
        #endif
    }

    private var minimumPortraitTopInset: CGFloat {
        #if os(iOS)
        return !isLandscape && UIDevice.current.userInterfaceIdiom == .phone ? 54 : 0
        #else
        return 0
        #endif
    }

    #if os(iOS)
    private static func currentWindowSafeAreaInsets() -> UIEdgeInsets {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .safeAreaInsets ?? .zero
    }
    #endif

    private var collapsedChromeTaskID: String {
        "\(isVisible)|\(isPinned)|\(collapsedTitle)"
    }

    private var drawerAnimation: Animation {
        .spring(response: 0.26, dampingFraction: 0.86)
    }

    private func enforcePinnedVisibility() {
        if isPinned && !isVisible {
            setVisible(true)
        }
    }

    private func setVisible(_ visible: Bool) {
        guard visible || !isPinned else { return }
        withAnimation(drawerAnimation) {
            isVisible = visible
        }
    }
}

private struct ControllerTopBarSwipeBridge: UIViewRepresentable {
    @Binding var isVisible: Bool
    let isPinned: Bool
    let animation: Animation
    let activationFrame: CGRect

    func makeCoordinator() -> Coordinator {
        Coordinator(isVisible: $isVisible, isPinned: isPinned, animation: animation, activationFrame: activationFrame)
    }

    func makeUIView(context: Context) -> ActivationView {
        let view = ActivationView()
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: ActivationView, context: Context) {
        context.coordinator.isVisible = $isVisible
        context.coordinator.isPinned = isPinned
        context.coordinator.animation = animation
        context.coordinator.configuredActivationFrame = activationFrame
        uiView.updateActivationFrame()
        uiView.scheduleActivationFrameUpdate()
    }

    final class ActivationView: UIView {
        weak var coordinator: Coordinator?

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            coordinator?.attach(to: window)
            updateActivationFrame()
            scheduleActivationFrameUpdate()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            updateActivationFrame()
            scheduleActivationFrameUpdate()
        }

        func updateActivationFrame() {
            guard let window else {
                coordinator?.activationFrame = .null
                return
            }

            coordinator?.activationFrame = convert(bounds, to: window)
        }

        func scheduleActivationFrameUpdate() {
            DispatchQueue.main.async { [weak self] in
                self?.updateActivationFrame()
            }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var isVisible: Binding<Bool>
        var isPinned: Bool
        var animation: Animation
        var configuredActivationFrame: CGRect
        fileprivate var activationFrame = CGRect.null
        private weak var window: UIWindow?
        private lazy var panRecognizer: UIPanGestureRecognizer = {
            let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.maximumNumberOfTouches = 1
            recognizer.delegate = self
            return recognizer
        }()

        init(isVisible: Binding<Bool>, isPinned: Bool, animation: Animation, activationFrame: CGRect) {
            self.isVisible = isVisible
            self.isPinned = isPinned
            self.animation = animation
            self.configuredActivationFrame = activationFrame
        }

        deinit {
            window?.removeGestureRecognizer(panRecognizer)
        }

        func attach(to newWindow: UIWindow?) {
            guard window !== newWindow else { return }

            window?.removeGestureRecognizer(panRecognizer)
            window = newWindow
            newWindow?.addGestureRecognizer(panRecognizer)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard gestureRecognizer === panRecognizer,
                  let hostView = gestureRecognizer.view
            else { return false }

            let location = touch.location(in: hostView)

            let targetFrame: CGRect
            if isVisible.wrappedValue {
                targetFrame = compactHandleFrame(in: activationFrame)
            } else {
                targetFrame = configuredActivationFrame
            }
            let paddedFrame = targetFrame.insetBy(dx: -12, dy: -12)
            if !paddedFrame.isNull, paddedFrame.width > 1, paddedFrame.height > 1 {
                return paddedFrame.contains(location)
            }

            // On a cold launch into the saved keypad, SwiftUI can install the
            // bridge before either activation frame is stable. Keep a compact
            // center target available instead of claiming the full top edge.
            return fallbackActivationFrame(in: hostView).contains(location)
        }

        private func compactHandleFrame(in drawerFrame: CGRect) -> CGRect {
            guard !drawerFrame.isNull, drawerFrame.width > 1, drawerFrame.height > 1 else { return .null }
            let width = min(60, drawerFrame.width)
            let height = min(44, drawerFrame.height)
            return CGRect(
                x: drawerFrame.midX - width / 2,
                y: drawerFrame.maxY - height,
                width: width,
                height: height
            )
        }

        private func fallbackActivationFrame(in hostView: UIView) -> CGRect {
            let width = min(60, hostView.bounds.width)
            let height: CGFloat = 44
            let topInset = hostView.safeAreaInsets.top
            let originY = max(0, topInset)
            return CGRect(
                x: hostView.bounds.midX - width / 2,
                y: originY,
                width: width,
                height: height
            ).insetBy(dx: -12, dy: -12)
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === panRecognizer,
                  let window = gestureRecognizer.view
            else { return false }

            let translation = panRecognizer.translation(in: window)
            let velocity = panRecognizer.velocity(in: window)
            let verticalIntent = max(abs(translation.y), abs(velocity.y) * 0.05)
            let horizontalIntent = max(abs(translation.x), abs(velocity.x) * 0.05)
            return verticalIntent > max(8, horizontalIntent * 0.65)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard recognizer.state == .ended,
                  let window = recognizer.view
            else { return }

            let translation = recognizer.translation(in: window)
            let velocity = recognizer.velocity(in: window)
            let projectedTranslation = CGPoint(
                x: translation.x + velocity.x * 0.12,
                y: translation.y + velocity.y * 0.12
            )
            let verticalMovement = abs(projectedTranslation.y) > abs(translation.y) ? projectedTranslation.y : translation.y
            let horizontalMovement = max(abs(translation.x), abs(projectedTranslation.x))
            guard abs(verticalMovement) > max(18, horizontalMovement * 0.65) else { return }

            setVisible(verticalMovement > 0)
        }

        private func setVisible(_ visible: Bool) {
            guard visible || !isPinned else { return }
            withAnimation(animation) {
                isVisible.wrappedValue = visible
            }
        }
    }
}

private struct PortraitControllerMetrics {
    let dPadButtonSize: CGSize
    let actionButtonSize: CGSize
    let mapButtonSize: CGSize
    let pauseButtonSize: CGSize
    let leadingPadding: CGFloat
    let trailingPadding: CGFloat
    let bottomPadding: CGFloat

    var dPadHitSize: CGSize {
        ControllerLayoutMetrics.hitSize(for: dPadButtonSize)
    }

    var actionHitSize: CGSize {
        ControllerLayoutMetrics.hitSize(for: actionButtonSize)
    }

    init(size: CGSize, safeAreaInsets: EdgeInsets, controlScale: GamepadControlScale) {
        let scale = controlScale.multiplier
        let usableWidth = max(300, size.width - Geist.Spacing.s8)
        let dPadButton = min(82 * scale, max(64 * scale, (usableWidth / 4.2) * scale))
        let actionButton = min(82 * scale, max(64 * scale, (usableWidth / 4.5) * scale))

        dPadButtonSize = CGSize(width: dPadButton, height: dPadButton)
        actionButtonSize = CGSize(width: actionButton, height: actionButton)
        mapButtonSize = CGSize(width: 94 * scale, height: 58 * scale)
        pauseButtonSize = CGSize(width: 108 * scale, height: 58 * scale)
        leadingPadding = max(Geist.Spacing.s4, safeAreaInsets.leading + Geist.Spacing.s3)
        trailingPadding = max(Geist.Spacing.s4, safeAreaInsets.trailing + Geist.Spacing.s3)
        bottomPadding = max(Geist.Spacing.s4, safeAreaInsets.bottom + Geist.Spacing.s2)
    }
}

private struct LandscapeControllerMetrics {
    let dPadButtonSize: CGSize
    let actionButtonSize: CGSize
    let mapButtonSize: CGSize
    let pauseButtonSize: CGSize
    let utilitySpacing: CGFloat
    let controlSpacing: CGFloat
    let spacerMinLength: CGFloat
    let leadingPadding: CGFloat
    let trailingPadding: CGFloat
    let bottomPadding: CGFloat

    var dPadHitSize: CGSize {
        ControllerLayoutMetrics.hitSize(for: dPadButtonSize)
    }

    var actionHitSize: CGSize {
        ControllerLayoutMetrics.hitSize(for: actionButtonSize)
    }

    var utilityHitWidth: CGFloat {
        ControllerLayoutMetrics.hitSize(for: mapButtonSize).width
        + ControllerLayoutMetrics.hitSize(for: pauseButtonSize).width
        + utilitySpacing
    }

    var utilityHitHeight: CGFloat {
        max(
            ControllerLayoutMetrics.hitSize(for: mapButtonSize).height,
            ControllerLayoutMetrics.hitSize(for: pauseButtonSize).height
        )
    }

    init(size: CGSize, safeAreaInsets: EdgeInsets, controlScale: GamepadControlScale) {
        let customizationScale = controlScale.multiplier
        let sideSafePadding = Geist.Spacing.s2
        leadingPadding = max(Geist.Spacing.s3, safeAreaInsets.leading + sideSafePadding)
        trailingPadding = max(Geist.Spacing.s3, safeAreaInsets.trailing + sideSafePadding)
        bottomPadding = max(Geist.Spacing.s4, safeAreaInsets.bottom + Geist.Spacing.s2)

        let availableHeight = max(220, size.height - bottomPadding)
        let contentWidth = max(320, size.width - leadingPadding - trailingPadding)
        utilitySpacing = contentWidth < 780 ? Geist.Spacing.s2 : Geist.Spacing.s4
        controlSpacing = contentWidth < 780 ? Geist.Spacing.s3 : max(Geist.Spacing.s4, min(Geist.Spacing.s6, contentWidth * 0.02))
        spacerMinLength = Geist.Spacing.s2

        let baseDPadButton = min(82 * customizationScale, max(64 * customizationScale, availableHeight * 0.24 * customizationScale), contentWidth * 0.12 * customizationScale)
        let baseActionButton = min(86 * customizationScale, max(64 * customizationScale, availableHeight * 0.25 * customizationScale), contentWidth * 0.13 * customizationScale)
        let baseMapWidth = min(92 * customizationScale, max(74 * customizationScale, contentWidth * 0.13 * customizationScale))
        let basePauseWidth = min(104 * customizationScale, max(84 * customizationScale, contentWidth * 0.145 * customizationScale))
        let baseUtilityHeight = min(64 * customizationScale, max(52 * customizationScale, availableHeight * 0.18 * customizationScale))

        // Landscape iPhones have a lot less horizontal room after the safe-area
        // notches are removed. Scale the visual controls as one group so the full
        // two-column action cluster stays inside the playable area instead of being
        // squeezed off the trailing edge by SwiftUI's HStack compression.
        let hitOutsetWidth = ControllerLayoutMetrics.buttonHitOutset * 2
        let hitOutsetBudget = hitOutsetWidth * 7 // D-pad columns + action columns + Map/Pause
        let layoutOverhead = hitOutsetBudget
            + utilitySpacing
            + controlSpacing * 4
            + spacerMinLength * 2
        let scalableWidth = baseDPadButton * 3
            + baseActionButton * 2
            + baseMapWidth
            + basePauseWidth
        let fittingScale = (contentWidth - layoutOverhead) / max(scalableWidth, 1)
        let scale = min(1, max(0.5, fittingScale))

        let dPadButton = max(50, floor(baseDPadButton * scale))
        let actionButton = max(52, floor(baseActionButton * scale))
        let mapWidth = max(58, floor(baseMapWidth * scale))
        let pauseWidth = max(68, floor(basePauseWidth * scale))
        let utilityHeight = max(46, floor(baseUtilityHeight * scale))

        dPadButtonSize = CGSize(width: dPadButton, height: dPadButton)
        actionButtonSize = CGSize(width: actionButton, height: actionButton)
        mapButtonSize = CGSize(width: mapWidth, height: utilityHeight)
        pauseButtonSize = CGSize(width: pauseWidth, height: utilityHeight)
    }
}

private enum ControllerLayoutMetrics {
    static let buttonHitOutset: CGFloat = 10

    static func hitInsets(for customization: GamepadButtonCustomization? = nil) -> GamepadHitInsets {
        customization?.hitInsets?.normalized ?? .runtimeDefault
    }

    static func hitSize(
        for visualSize: CGSize,
        customization: GamepadButtonCustomization? = nil
    ) -> CGSize {
        hitInsets(for: customization).hitSize(for: visualSize)
    }

    static func visualOffset(for customization: GamepadButtonCustomization? = nil) -> CGSize {
        hitInsets(for: customization).visualOffset
    }
}

private struct ControllerPadResolvedControlRouter: View {
    let context: ControllerPadRenderContext
    let control: GamepadResolvedControl

    var body: AnyView {
        let route = GamepadControllerPresentationRouting.resolvedControlRoute(
            kind: control.controlKind,
            hasJoystickMapping: control.joystickMapping != nil,
            hasTriggerSettings: control.triggerSettings != nil
        )

        switch route {
        case .decoration:
            return AnyView(ControllerPadResolvedDecoration(context: context, control: control))
        case .joystick:
            guard let mapping = control.joystickMapping else {
                return AnyView(ControllerPadResolvedButton(context: context, control: control))
            }
            return AnyView(
                ControllerPadResolvedJoystick(
                    context: context,
                    control: control,
                    mapping: mapping
                )
            )
        case .trigger:
            guard let settings = control.triggerSettings else {
                return AnyView(ControllerPadResolvedButton(context: context, control: control))
            }
            return AnyView(
                ControllerPadResolvedTrigger(
                    context: context,
                    control: control,
                    settings: settings
                )
            )
        case .trackpad:
            return AnyView(ControllerPadResolvedTrackpad(context: context, control: control))
        case .button:
            return AnyView(ControllerPadResolvedButton(context: context, control: control))
        }
    }
}

private struct ControllerPadResolvedDecoration: View {
    let context: ControllerPadRenderContext
    let control: GamepadResolvedControl

    var body: some View {
        GamepadRenderedControlFace(
            control: control,
            customization: context.customization,
            state: .normal
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct ControllerPadResolvedJoystick: View {
    let context: ControllerPadRenderContext
    let control: GamepadResolvedControl
    let mapping: GamepadJoystickMapping

    var body: some View {
        GamepadJoystick(
            elementID: control.elementID,
            mapping: mapping,
            outputSettings: control.joystickOutputSettings ?? .defaultValue,
            label: control.label,
            size: control.size,
            elementCustomization: control.layoutCustomization,
            customization: context.customization
        )
    }
}

private struct ControllerPadResolvedTrigger: View {
    let context: ControllerPadRenderContext
    let control: GamepadResolvedControl
    let settings: GamepadTriggerSettings

    var body: some View {
        GamepadTrigger(
            elementID: control.elementID,
            mappedButton: control.mappedButton,
            label: control.label,
            size: control.size,
            elementCustomization: control.layoutCustomization,
            settings: settings,
            customization: context.customization
        )
    }
}

private struct ControllerPadResolvedTrackpad: View {
    let context: ControllerPadRenderContext
    let control: GamepadResolvedControl

    var body: some View {
        GamepadTrackpad(
            elementID: control.elementID,
            label: control.label,
            size: control.size,
            elementCustomization: control.layoutCustomization,
            settings: control.trackpadSettings ?? .defaultValue,
            customization: context.customization
        )
    }
}

private struct ControllerPadResolvedButton: View {
    let context: ControllerPadRenderContext
    let control: GamepadResolvedControl

    var body: some View {
        GamepadButton(
            elementID: control.elementID,
            button: control.mappedButton,
            size: control.size,
            shape: control.shape,
            labelOverride: control.label,
            elementCustomization: control.layoutCustomization,
            customization: context.customization
        )
    }
}

private struct IOSKeypadEditAccessibilityModifier: ViewModifier {
    let label: String
    let value: String
    let hint: String
    let isLocked: Bool
    let onSelect: () -> Void
    let onNudge: (CGSize) -> Void
    let onResize: (CGFloat) -> Void
    let onRotate: (CGFloat) -> Void
    let onDelete: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        let base = content
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(label)
            .accessibilityValue(value)
            .accessibilityHint(hint)
            .accessibilityAction { onSelect() }
            .accessibilityAction(named: Text("Delete")) { onDelete() }

        if isLocked {
            base
        } else {
            base
                .accessibilityAction(named: Text("Move Left")) { onNudge(CGSize(width: -4, height: 0)) }
                .accessibilityAction(named: Text("Move Right")) { onNudge(CGSize(width: 4, height: 0)) }
                .accessibilityAction(named: Text("Move Up")) { onNudge(CGSize(width: 0, height: -4)) }
                .accessibilityAction(named: Text("Move Down")) { onNudge(CGSize(width: 0, height: 4)) }
                .accessibilityAction(named: Text("Rotate Counterclockwise")) { onRotate(-15) }
                .accessibilityAction(named: Text("Rotate Clockwise")) { onRotate(15) }
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: onResize(0.1)
                    case .decrement: onResize(-0.1)
                    @unknown default: break
                    }
                }
        }
    }
}

private struct GamepadFreeformControllerCanvas: View {
    @Environment(\.colorScheme) private var colorScheme
    let context: ControllerPadRenderContext
    var isEditingLayout = false
    var onCustomizationChanged: (GamepadCustomization, Bool) -> Void = { _, _ in }

    private var customization: GamepadCustomization { context.customization }

    @State private var activeDrag: IOSKeypadControlEditDragState?
    @State private var activeResize: IOSKeypadControlResizeState?
    @State private var activeRotation: IOSKeypadControlRotationState?
    @State private var selectedControlID: GamepadControlIdentity?
    @State private var pendingDeleteControl: IOSKeypadControlDeleteCandidate?

    var body: some View {
        GeometryReader { proxy in
            let controls = customization.resolvedControls(in: proxy.size).filter { $0.id != .system(.topBarActivation) }

            ZStack {
                if isEditingLayout {
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            clearEditSelection()
                        }
                }

                ForEach(controls) { control in
                    ControllerPadResolvedControlRouter(context: context, control: control)
                        .allowsHitTesting(!isEditingLayout && !control.isDecoration)
                        .accessibilityHidden(isEditingLayout)
                        .rotationEffect(.degrees(control.rotationDegrees))
                        .position(control.isDecoration ? control.center : control.hitCenter)
                        .zIndex(0)
                }

                if isEditingLayout {
                    ForEach(controls) { control in
                        editOverlay(
                            for: control,
                            canvasSize: proxy.size,
                            isSelected: selectedControlID == control.id
                        )
                        .zIndex(selectedControlID == control.id ? 200 : 100)
                    }
                }
            }
            .coordinateSpace(name: "iOSKeypadLayoutCanvas")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .confirmationDialog(
            "Delete element?",
            isPresented: deleteConfirmationBinding,
            presenting: pendingDeleteControl
        ) { candidate in
            Button("Delete \(candidate.label)", role: .destructive) {
                deleteControl(candidate.identity)
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteControl = nil
            }
        } message: { candidate in
            Text("Remove \(candidate.label) from this keypad setup.")
        }
        .onChange(of: isEditingLayout) { _, isEditing in
            if !isEditing {
                clearEditSelection()
            }
        }
        .onDisappear {
            clearEditSelection()
        }
    }

    private var deleteConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingDeleteControl != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDeleteControl = nil
                }
            }
        )
    }

    private func clearEditSelection() {
        activeDrag = nil
        activeResize = nil
        activeRotation = nil
        selectedControlID = nil
        pendingDeleteControl = nil
    }

    private func editOverlay(for control: GamepadResolvedControl, canvasSize: CGSize, isSelected: Bool) -> some View {
        let chromeOutset: CGFloat = isSelected ? 12 : 6
        let minimumTouchSize: CGFloat = isSelected ? 52 : 44
        let overlaySize = CGSize(
            width: max(minimumTouchSize, control.size.width + chromeOutset),
            height: max(minimumTouchSize, control.size.height + chromeOutset)
        )
        let handleOutset: CGFloat = isSelected ? 34 : 0
        let hitFrameSize = CGSize(
            width: overlaySize.width + handleOutset * 2,
            height: overlaySize.height + handleOutset * 2
        )
        let chromeCenter = CGPoint(x: hitFrameSize.width / 2, y: hitFrameSize.height / 2)
        let cornerRadius = min(16, max(8, min(overlaySize.width, overlaySize.height) * 0.12))
        let tint = control.isLocationLocked ? Geist.color(.gray900, scheme: colorScheme) : Geist.color(.blue900, scheme: colorScheme)
        let strokeStyle = StrokeStyle(
            lineWidth: isSelected && !control.isLocationLocked ? 1.75 : 1,
            dash: control.isLocationLocked ? [4, 4] : []
        )

        return ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.001))
                .frame(width: overlaySize.width, height: overlaySize.height)
                .position(chromeCenter)
                .zIndex(0)

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(tint.opacity(control.isLocationLocked ? 0.025 : (isSelected ? 0.055 : 0.018)))
                .frame(width: overlaySize.width, height: overlaySize.height)
                .position(chromeCenter)
                .zIndex(1)

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(tint.opacity(control.isLocationLocked ? 0.45 : (isSelected ? 0.95 : 0.38)), style: strokeStyle)
                .frame(width: overlaySize.width, height: overlaySize.height)
                .position(chromeCenter)
                .zIndex(2)

            if control.isLocationLocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(tint)
                    .padding(4)
                    .background(Geist.color(.background100, scheme: colorScheme).opacity(0.9), in: Circle())
                    .overlay(Circle().stroke(tint.opacity(0.2), lineWidth: 1))
                    .position(x: handleOutset + overlaySize.width, y: handleOutset)
                    .zIndex(6)
            }

            if isSelected {
                selectedEditHandles(
                    for: control,
                    overlaySize: overlaySize,
                    handleOutset: handleOutset,
                    canvasSize: canvasSize
                )
                .zIndex(10)
            }
        }
        .frame(width: hitFrameSize.width, height: hitFrameSize.height)
        .contentShape(Rectangle())
        .gesture(editDragGesture(for: control, canvasSize: canvasSize))
        .rotationEffect(.degrees(control.rotationDegrees))
        .position(control.center)
        .modifier(
            IOSKeypadEditAccessibilityModifier(
                label: control.isLocationLocked ? "\(control.label) locked" : "Edit \(control.label)",
                value: accessibilityLayoutValue(for: control),
                hint: control.isLocationLocked
                    ? "This control is locked in the Mac keypad editor. Use the Delete action to remove it."
                    : "Activate to select. Swipe up or down to resize, or use the Move, Rotate, and Delete accessibility actions.",
                isLocked: control.isLocationLocked,
                onSelect: { selectedControlID = control.id },
                onNudge: { accessibilityNudge(control, by: $0, in: canvasSize) },
                onResize: { accessibilityResize(control, scaleDelta: $0) },
                onRotate: { accessibilityRotate(control, by: $0) },
                onDelete: { requestDelete(control) }
            )
        )
    }

    private func accessibilityLayoutValue(for control: GamepadResolvedControl) -> String {
        let x = Int((control.normalizedCenter.x * 100).rounded())
        let y = Int((control.normalizedCenter.y * 100).rounded())
        let width = Int((control.layoutCustomization.widthScale * 100).rounded())
        let height = Int((control.layoutCustomization.heightScale * 100).rounded())
        let rotation = Int(control.layoutCustomization.rotationDegrees.rounded())
        return "Position \(x) percent across, \(y) percent down. Size \(width) by \(height) percent. Rotation \(rotation) degrees."
    }

    private func accessibilityNudge(
        _ control: GamepadResolvedControl,
        by translation: CGSize,
        in canvasSize: CGSize
    ) {
        selectedControlID = control.id
        guard !control.isLocationLocked,
              let next = customization.nudgedControls([control.id], by: translation, in: canvasSize)
        else { return }
        onCustomizationChanged(next, true)
        accessibilityAnnounce("Moved \(control.label)")
    }

    private func accessibilityResize(_ control: GamepadResolvedControl, scaleDelta: CGFloat) {
        selectedControlID = control.id
        guard !control.isLocationLocked else { return }
        guard let next = customization.iosUpdatingControlLayout(for: control.id, { layout in
            layout.widthScale = GamepadButtonCustomization.clamp(
                layout.widthScale + scaleDelta,
                lower: GamepadButtonCustomization.minimumScale,
                upper: GamepadButtonCustomization.maximumScale
            )
            layout.heightScale = GamepadButtonCustomization.clamp(
                layout.heightScale + scaleDelta,
                lower: GamepadButtonCustomization.minimumScale,
                upper: GamepadButtonCustomization.maximumScale
            )
        }) else { return }
        guard next.normalized != customization.normalized else { return }
        onCustomizationChanged(next, true)
        accessibilityAnnounce(scaleDelta > 0 ? "Enlarged \(control.label)" : "Reduced \(control.label)")
    }

    private func accessibilityRotate(_ control: GamepadResolvedControl, by delta: CGFloat) {
        selectedControlID = control.id
        guard !control.isLocationLocked else { return }
        guard let next = customization.iosUpdatingControlLayout(for: control.id, { layout in
            layout.rotationDegrees = GamepadButtonCustomization.normalizedRotationDegrees(
                layout.rotationDegrees + delta
            )
        }) else { return }
        guard next.normalized != customization.normalized else { return }
        onCustomizationChanged(next, true)
        accessibilityAnnounce(delta > 0 ? "Rotated \(control.label) clockwise" : "Rotated \(control.label) counterclockwise")
    }

    private func accessibilityAnnounce(_ message: String) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    private func selectedEditHandles(for control: GamepadResolvedControl, overlaySize: CGSize, handleOutset: CGFloat, canvasSize: CGSize) -> some View {
        let hitFrameSize = CGSize(
            width: overlaySize.width + handleOutset * 2,
            height: overlaySize.height + handleOutset * 2
        )
        let topTrailingHandlePosition = handlePosition(for: .topTrailing, in: overlaySize)
        let topTrailingPosition = CGPoint(
            x: handleOutset + topTrailingHandlePosition.x,
            y: handleOutset + topTrailingHandlePosition.y
        )
        let rotationHandleOffset: CGFloat = 16
        let rotationHandlePosition = CGPoint(
            x: handleOutset + overlaySize.width + rotationHandleOffset,
            y: handleOutset - rotationHandleOffset
        )

        return ZStack {
            if !control.isLocationLocked {
                Path { path in
                    path.move(to: topTrailingPosition)
                    path.addLine(to: rotationHandlePosition)
                }
                .stroke(
                    Geist.color(.blue700, scheme: colorScheme).opacity(0.45),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                )
                .zIndex(1)

                rotationHandle(for: control)
                    .position(rotationHandlePosition)
                    .zIndex(4)

                ForEach(IOSKeypadResizeHandleCorner.allCases) { corner in
                    let position = handlePosition(for: corner, in: overlaySize)
                    resizeHandle(corner, for: control, canvasSize: canvasSize)
                        .position(x: handleOutset + position.x, y: handleOutset + position.y)
                        .zIndex(3)
                }
            }

            deleteHandle(for: control, overlaySize: overlaySize, handleOutset: handleOutset, canvasSize: canvasSize)
                .zIndex(5)
        }
        .frame(width: hitFrameSize.width, height: hitFrameSize.height)
    }

    private func resizeHandle(_ corner: IOSKeypadResizeHandleCorner, for control: GamepadResolvedControl, canvasSize: CGSize) -> some View {
        ZStack {
            Circle()
                .fill(Geist.color(.blue700, scheme: colorScheme))
                .overlay(
                    Circle()
                        .stroke(Geist.color(.background100, scheme: colorScheme), lineWidth: 1.25)
                )
                .frame(width: 10, height: 10)
        }
        .frame(width: 34, height: 34)
        .contentShape(Rectangle())
        .highPriorityGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("iOSKeypadLayoutCanvas"))
                .onChanged { value in
                    updateResize(corner, value: value, control: control, canvasSize: canvasSize)
                }
                .onEnded { value in
                    finishResize(value, control: control, canvasSize: canvasSize)
                }
        )
        .accessibilityLabel(Text(corner.accessibilityLabel))
        .accessibilityHint(Text("Drag to resize this keypad control"))
    }

    private func rotationHandle(for control: GamepadResolvedControl) -> some View {
        Image(systemName: "arrow.clockwise")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(Geist.color(.blue700, scheme: colorScheme), in: Circle())
            .overlay(Circle().stroke(Geist.color(.background100, scheme: colorScheme), lineWidth: 1.25))
            .contentShape(Circle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("iOSKeypadLayoutCanvas"))
                    .onChanged { value in
                        updateRotation(value, control: control)
                    }
                    .onEnded { value in
                        finishRotation(value, control: control)
                    }
            )
            .accessibilityLabel(Text("Rotate \(control.label)"))
            .accessibilityHint(Text("Drag around the selected control to rotate it"))
    }

    private func deleteHandle(for control: GamepadResolvedControl, overlaySize: CGSize, handleOutset: CGFloat, canvasSize: CGSize) -> some View {
        let belowFits = control.center.y + overlaySize.height / 2 + handleOutset <= canvasSize.height
        let aboveFits = control.center.y - overlaySize.height / 2 - handleOutset >= 0
        let rightFits = control.center.x + overlaySize.width / 2 + handleOutset <= canvasSize.width
        let position: CGPoint
        if belowFits {
            position = CGPoint(x: handleOutset + overlaySize.width / 2, y: handleOutset + overlaySize.height + 15)
        } else if aboveFits {
            position = CGPoint(x: handleOutset + overlaySize.width / 2, y: handleOutset - 15)
        } else if rightFits {
            position = CGPoint(x: handleOutset + overlaySize.width + 15, y: handleOutset + overlaySize.height / 2)
        } else {
            position = CGPoint(x: handleOutset - 15, y: handleOutset + overlaySize.height / 2)
        }

        return ZStack {
            Circle()
                .fill(Geist.color(.red900, scheme: colorScheme))
                .overlay(Circle().stroke(Geist.color(.background100, scheme: colorScheme), lineWidth: 1.25))
                .shadow(color: Color.black.opacity(0.16), radius: 5, x: 0, y: 2)

            Image(systemName: "trash.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 30, height: 30)
        .contentShape(Circle())
        .position(position)
        .highPriorityGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("iOSKeypadLayoutCanvas"))
                .onEnded { _ in
                    requestDelete(control)
                }
        )
        .accessibilityLabel(Text("Delete \(control.label)"))
        .accessibilityHint(Text("Asks before removing this element from the current keypad setup"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            requestDelete(control)
        }
    }

    private func handlePosition(for corner: IOSKeypadResizeHandleCorner, in size: CGSize) -> CGPoint {
        let inset: CGFloat = 4
        switch corner {
        case .topLeading:
            return CGPoint(x: inset, y: inset)
        case .topTrailing:
            return CGPoint(x: size.width - inset, y: inset)
        case .bottomTrailing:
            return CGPoint(x: size.width - inset, y: size.height - inset)
        case .bottomLeading:
            return CGPoint(x: inset, y: size.height - inset)
        }
    }

    private func requestDelete(_ control: GamepadResolvedControl) {
        selectedControlID = control.id
        pendingDeleteControl = IOSKeypadControlDeleteCandidate(identity: control.id, label: control.label)
    }

    private func deleteControl(_ identity: GamepadControlIdentity) {
        guard let nextCustomization = customization.iosDeletingControl(identity) else {
            pendingDeleteControl = nil
            return
        }

        activeDrag = nil
        activeResize = nil
        activeRotation = nil
        selectedControlID = nil
        pendingDeleteControl = nil
        onCustomizationChanged(nextCustomization, true)
    }

    private func editDragGesture(for control: GamepadResolvedControl, canvasSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("iOSKeypadLayoutCanvas"))
            .onChanged { value in
                guard isEditingLayout else { return }
                selectedControlID = control.id
                guard !control.isLocationLocked else { return }

                if activeDrag?.identity != control.id {
                    activeResize = nil
                    activeRotation = nil
                    activeDrag = IOSKeypadControlEditDragState(
                        identity: control.id,
                        startCustomization: customization
                    )
                }

                guard var dragState = activeDrag,
                      dragState.identity == control.id,
                      let nextCustomization = dragState.startCustomization.nudgedControls(
                        [control.id],
                        by: value.translation,
                        in: canvasSize
                      )
                else { return }

                dragState.didMove = true
                activeDrag = dragState
                onCustomizationChanged(nextCustomization, false)
            }
            .onEnded { value in
                guard isEditingLayout,
                      let dragState = activeDrag,
                      dragState.identity == control.id
                else { return }

                defer { activeDrag = nil }

                if let finalCustomization = dragState.startCustomization.nudgedControls(
                    [control.id],
                    by: value.translation,
                    in: canvasSize
                ) {
                    onCustomizationChanged(finalCustomization, true)
                } else if dragState.didMove {
                    onCustomizationChanged(customization, true)
                }
            }
    }

    private func updateResize(
        _ corner: IOSKeypadResizeHandleCorner,
        value: DragGesture.Value,
        control: GamepadResolvedControl,
        canvasSize: CGSize
    ) {
        guard isEditingLayout else { return }
        selectedControlID = control.id
        guard !control.isLocationLocked else { return }

        if activeResize?.identity != control.id || activeResize?.corner != corner {
            activeDrag = nil
            activeRotation = nil
            activeResize = IOSKeypadControlResizeState(
                identity: control.id,
                corner: corner,
                startCustomization: customization,
                startCenter: control.center,
                startSize: control.size,
                startWidthScale: control.layoutCustomization.widthScale,
                startHeightScale: control.layoutCustomization.heightScale
            )
        }

        guard var resizeState = activeResize,
              resizeState.identity == control.id,
              resizeState.corner == corner,
              let nextCustomization = resizedCustomization(from: resizeState, translation: value.translation, in: canvasSize)
        else { return }

        resizeState.didResize = true
        activeResize = resizeState
        onCustomizationChanged(nextCustomization, false)
    }

    private func finishResize(_ value: DragGesture.Value, control: GamepadResolvedControl, canvasSize: CGSize) {
        guard let resizeState = activeResize,
              resizeState.identity == control.id
        else { return }

        defer { activeResize = nil }

        if let finalCustomization = resizedCustomization(from: resizeState, translation: value.translation, in: canvasSize) {
            onCustomizationChanged(finalCustomization, true)
        } else if resizeState.didResize {
            onCustomizationChanged(customization, true)
        }
    }

    private func resizedCustomization(
        from resizeState: IOSKeypadControlResizeState,
        translation: CGSize,
        in canvasSize: CGSize
    ) -> GamepadCustomization? {
        guard canvasSize.width > 1,
              canvasSize.height > 1,
              abs(translation.width) > 0.001 || abs(translation.height) > 0.001
        else { return nil }

        let baseWidth = max(1, resizeState.startSize.width / max(resizeState.startWidthScale, 0.001))
        let baseHeight = max(1, resizeState.startSize.height / max(resizeState.startHeightScale, 0.001))
        let minSize = CGSize(
            width: GamepadButtonCustomization.minimumDimension(forBaseDimension: baseWidth),
            height: GamepadButtonCustomization.minimumDimension(forBaseDimension: baseHeight)
        )
        let maxSize = CGSize(
            width: min(canvasSize.width, baseWidth * GamepadButtonCustomization.maximumScale),
            height: min(canvasSize.height, baseHeight * GamepadButtonCustomization.maximumScale)
        )
        let startRect = CGRect(
            x: resizeState.startCenter.x - resizeState.startSize.width / 2,
            y: resizeState.startCenter.y - resizeState.startSize.height / 2,
            width: resizeState.startSize.width,
            height: resizeState.startSize.height
        )
        let resizedRect = Self.resizedFrame(
            from: startRect,
            corner: resizeState.corner,
            translation: translation,
            minSize: minSize,
            maxSize: maxSize,
            canvasSize: canvasSize
        )
        guard Self.rectDidChange(from: startRect, to: resizedRect) else { return nil }

        let nextCenter = CGPoint(x: resizedRect.midX, y: resizedRect.midY)
        return resizeState.startCustomization.iosUpdatingControlLayout(for: resizeState.identity) { layout in
            layout.widthScale = resizedRect.width / baseWidth
            layout.heightScale = resizedRect.height / baseHeight
            layout.centerX = nextCenter.x / max(canvasSize.width, 1)
            layout.centerY = nextCenter.y / max(canvasSize.height, 1)
        }
    }

    private func updateRotation(_ value: DragGesture.Value, control: GamepadResolvedControl) {
        guard isEditingLayout else { return }
        selectedControlID = control.id
        guard !control.isLocationLocked else { return }

        let pointerAngle = Self.angleInDegrees(from: control.center, to: value.location)
        if activeRotation?.identity != control.id {
            activeDrag = nil
            activeResize = nil
            activeRotation = IOSKeypadControlRotationState(
                identity: control.id,
                startCustomization: customization,
                startCenter: control.center,
                startRotationDegrees: control.layoutCustomization.rotationDegrees,
                startPointerAngleDegrees: pointerAngle
            )
        }

        guard var rotationState = activeRotation,
              rotationState.identity == control.id,
              let nextCustomization = rotatedCustomization(from: rotationState, pointerLocation: value.location)
        else { return }

        rotationState.didRotate = true
        activeRotation = rotationState
        onCustomizationChanged(nextCustomization, false)
    }

    private func finishRotation(_ value: DragGesture.Value, control: GamepadResolvedControl) {
        guard let rotationState = activeRotation,
              rotationState.identity == control.id
        else { return }

        defer { activeRotation = nil }

        if let finalCustomization = rotatedCustomization(from: rotationState, pointerLocation: value.location) {
            onCustomizationChanged(finalCustomization, true)
        } else if rotationState.didRotate {
            onCustomizationChanged(customization, true)
        }
    }

    private func rotatedCustomization(
        from rotationState: IOSKeypadControlRotationState,
        pointerLocation: CGPoint
    ) -> GamepadCustomization? {
        let pointerAngle = Self.angleInDegrees(from: rotationState.startCenter, to: pointerLocation)
        let delta = GamepadButtonCustomization.normalizedRotationDegrees(pointerAngle - rotationState.startPointerAngleDegrees)
        let nextRotation = GamepadButtonCustomization.normalizedRotationDegrees(rotationState.startRotationDegrees + delta)

        return rotationState.startCustomization.iosUpdatingControlLayout(for: rotationState.identity) { layout in
            layout.rotationDegrees = nextRotation
        }
    }


    private static func resizedFrame(
        from rect: CGRect,
        corner: IOSKeypadResizeHandleCorner,
        translation: CGSize,
        minSize: CGSize,
        maxSize: CGSize,
        canvasSize: CGSize
    ) -> CGRect {
        var minX = rect.minX
        var maxX = rect.maxX
        var minY = rect.minY
        var maxY = rect.maxY

        switch corner {
        case .topLeading:
            minX += translation.width
            minY += translation.height
        case .topTrailing:
            maxX += translation.width
            minY += translation.height
        case .bottomTrailing:
            maxX += translation.width
            maxY += translation.height
        case .bottomLeading:
            minX += translation.width
            maxY += translation.height
        }

        if corner.movesLeadingEdge {
            minX = GamepadButtonCustomization.clamp(minX, lower: 0, upper: maxX - minSize.width)
            let width = GamepadButtonCustomization.clamp(maxX - minX, lower: minSize.width, upper: maxSize.width)
            minX = maxX - width
        } else {
            maxX = GamepadButtonCustomization.clamp(maxX, lower: minX + minSize.width, upper: canvasSize.width)
            let width = GamepadButtonCustomization.clamp(maxX - minX, lower: minSize.width, upper: maxSize.width)
            maxX = minX + width
        }

        if corner.movesTopEdge {
            minY = GamepadButtonCustomization.clamp(minY, lower: 0, upper: maxY - minSize.height)
            let height = GamepadButtonCustomization.clamp(maxY - minY, lower: minSize.height, upper: maxSize.height)
            minY = maxY - height
        } else {
            maxY = GamepadButtonCustomization.clamp(maxY, lower: minY + minSize.height, upper: canvasSize.height)
            let height = GamepadButtonCustomization.clamp(maxY - minY, lower: minSize.height, upper: maxSize.height)
            maxY = minY + height
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func rectDidChange(from original: CGRect, to updated: CGRect) -> Bool {
        abs(original.minX - updated.minX) > 0.1
            || abs(original.minY - updated.minY) > 0.1
            || abs(original.width - updated.width) > 0.1
            || abs(original.height - updated.height) > 0.1
    }

    private static func angleInDegrees(from center: CGPoint, to point: CGPoint) -> CGFloat {
        atan2(point.y - center.y, point.x - center.x) * 180 / .pi
    }
}

private struct IOSKeypadControlEditDragState {
    let identity: GamepadControlIdentity
    let startCustomization: GamepadCustomization
    var didMove = false
}

private struct IOSKeypadControlResizeState {
    let identity: GamepadControlIdentity
    let corner: IOSKeypadResizeHandleCorner
    let startCustomization: GamepadCustomization
    let startCenter: CGPoint
    let startSize: CGSize
    let startWidthScale: CGFloat
    let startHeightScale: CGFloat
    var didResize = false
}

private struct IOSKeypadControlRotationState {
    let identity: GamepadControlIdentity
    let startCustomization: GamepadCustomization
    let startCenter: CGPoint
    let startRotationDegrees: CGFloat
    let startPointerAngleDegrees: CGFloat
    var didRotate = false
}

private struct IOSKeypadControlDeleteCandidate: Identifiable {
    let identity: GamepadControlIdentity
    let label: String

    var id: String { identity.id }
}

private extension GamepadCustomization {
    func iosDeletingControl(_ identity: GamepadControlIdentity) -> GamepadCustomization? {
        var next = self

        switch identity {
        case .builtin(let button):
            var buttonCustomization = next.buttonCustomization(for: button)
            guard !buttonCustomization.isHidden else { return nil }
            buttonCustomization.isHidden = true
            next.setButtonCustomization(buttonCustomization, for: button)

        case .custom(let id):
            guard next.customButtons.contains(where: { $0.id == id }) else { return nil }
            next.removeCustomButton(id: id)

        case .system(.topBarActivation), .controlBarItem:
            return nil
        }

        let normalizedNext = next.normalized
        return normalizedNext == normalized ? nil : normalizedNext
    }
}

private enum IOSKeypadResizeHandleCorner: CaseIterable, Identifiable {
    case topLeading
    case topTrailing
    case bottomTrailing
    case bottomLeading

    var id: String {
        switch self {
        case .topLeading: "topLeading"
        case .topTrailing: "topTrailing"
        case .bottomTrailing: "bottomTrailing"
        case .bottomLeading: "bottomLeading"
        }
    }

    var movesLeadingEdge: Bool {
        switch self {
        case .topLeading, .bottomLeading: true
        case .topTrailing, .bottomTrailing: false
        }
    }

    var movesTopEdge: Bool {
        switch self {
        case .topLeading, .topTrailing: true
        case .bottomLeading, .bottomTrailing: false
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .topLeading: "Resize from top left"
        case .topTrailing: "Resize from top right"
        case .bottomTrailing: "Resize from bottom right"
        case .bottomLeading: "Resize from bottom left"
        }
    }
}

private extension GamepadCustomization {
    func iosUpdatingControlLayout(
        for identity: GamepadControlIdentity,
        _ mutate: (inout GamepadButtonCustomization) -> Void
    ) -> GamepadCustomization? {
        var next = self
        switch identity {
        case .builtin(let button):
            var layout = next.buttonCustomization(for: button)
            mutate(&layout)
            next.setButtonCustomization(layout, for: button)
        case .custom(let id):
            guard let index = next.customButtons.firstIndex(where: { $0.id == id }) else { return nil }
            mutate(&next.customButtons[index].layout)
        case .system(.topBarActivation):
            mutate(&next.topBarActivationRegion)
        case .controlBarItem:
            return nil
        }

        let normalizedNext = next.normalized
        return normalizedNext == normalized ? nil : normalizedNext
    }
}

private struct DPadView: View {
    @Environment(\.colorScheme) private var colorScheme
    var buttonSize = CGSize(width: 78, height: 78)
    let customization: GamepadCustomization

    var body: some View {
        let hitSize = ControllerLayoutMetrics.hitSize(for: buttonSize)

        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                Color.clear.frame(width: hitSize.width, height: hitSize.height)
                GamepadButton(button: .up, size: buttonSize, customization: customization)
                Color.clear.frame(width: hitSize.width, height: hitSize.height)
            }
            GridRow {
                GamepadButton(button: .left, size: buttonSize, customization: customization)
                RoundedRectangle(cornerRadius: Geist.Radius.sm, style: .continuous)
                    .fill(Geist.color(.gray100, scheme: colorScheme))
                    .overlay(
                        RoundedRectangle(cornerRadius: Geist.Radius.sm, style: .continuous)
                            .stroke(Geist.color(.grayAlpha400, scheme: colorScheme), lineWidth: 1)
                    )
                    .frame(width: buttonSize.width, height: buttonSize.height)
                    .frame(width: hitSize.width, height: hitSize.height)
                GamepadButton(button: .right, size: buttonSize, customization: customization)
            }
            GridRow {
                Color.clear.frame(width: hitSize.width, height: hitSize.height)
                GamepadButton(button: .down, size: buttonSize, customization: customization)
                Color.clear.frame(width: hitSize.width, height: hitSize.height)
            }
        }
    }
}

private struct ActionButtonsView: View {
    var buttonSize = CGSize(width: 82, height: 82)
    let customization: GamepadCustomization

    var body: some View {
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                GamepadButton(button: .focus, size: buttonSize, customization: customization)
                GamepadButton(button: .dash, size: buttonSize, customization: customization)
            }
            GridRow {
                GamepadButton(button: .attack, size: buttonSize, customization: customization)
                GamepadButton(button: .jump, size: buttonSize, customization: customization)
            }
        }
    }
}

private extension View {
    func gamepadOuterShadows(_ presentation: GamepadResolvedControlPresentation) -> some View {
        modifier(IOSGamepadOuterShadowModifier(presentation: presentation))
    }
}

private struct IOSGamepadOuterShadowModifier: ViewModifier {
    let presentation: GamepadResolvedControlPresentation

    func body(content: Content) -> some View {
        var view = AnyView(content)
        if presentation.shadows.isEmpty {
            view = AnyView(
                view.shadow(
                    color: presentation.shadowSwiftUIColor,
                    radius: presentation.shadowRadius,
                    x: presentation.shadowX,
                    y: presentation.shadowY
                )
            )
        } else {
            for shadow in presentation.shadows {
                let normalized = shadow.normalized
                view = AnyView(
                    view.shadow(
                        color: normalized.swiftUIColor,
                        radius: normalized.radius,
                        x: normalized.x,
                        y: normalized.y
                    )
                )
            }
        }
        return view
    }
}

private struct KeypadSecondaryBindingText: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let text: String
    let color: Color
    var maximumWidth: CGFloat

    var body: some View {
        Text(text)
            .font(.system(size: dynamicTypeSize.isAccessibilitySize ? 11 : 10, weight: .medium, design: .monospaced))
            .lineLimit(1)
            .minimumScaleFactor(0.55)
            .allowsTightening(true)
            .foregroundStyle(color.opacity(0.78))
            .frame(maxWidth: maximumWidth)
            .accessibilityHidden(true)
    }
}

private extension String {
    func isSameBindingDisplay(as other: String) -> Bool {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .filter { !$0.isWhitespace }
            == other.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .filter { !$0.isWhitespace }
    }
}

private struct GamepadJoystick: View {
    @EnvironmentObject private var client: ControllerClient
    @AppStorage(IOSKeypadPreferenceKeys.showBindingGlyphs) private var showsBindingGlyphs = IOSKeypadPreferenceKeys.defaultShowBindingGlyphs
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let elementID: UUID?
    let mapping: GamepadJoystickMapping
    let outputSettings: GamepadJoystickOutputSettings
    let label: String
    let size: CGSize
    let elementCustomization: GamepadButtonCustomization
    let customization: GamepadCustomization

    @State private var activeDirections: Set<GamepadJoystickDirection> = []
    @State private var normalizedOffset = CGSize.zero

    private var joystickVisualStyle: GamepadJoystickVisualStyle {
        elementCustomization.joystickVisualStyle ?? .pad
    }

    private var visualSide: CGFloat {
        min(size.width, size.height)
    }

    private var legacyHitSide: CGFloat {
        switch joystickVisualStyle {
        case .pad:
            max(visualSide + ControllerLayoutMetrics.buttonHitOutset * 2, visualSide)
        case .thumbstick:
            max(visualSide + ControllerLayoutMetrics.buttonHitOutset * 2, visualSide * 2.55, 104)
        }
    }

    private var interactionSize: CGSize {
        guard elementCustomization.hitInsets != nil else {
            return CGSize(width: legacyHitSide, height: legacyHitSide)
        }
        return ControllerLayoutMetrics.hitSize(for: size, customization: elementCustomization)
    }

    private var hitSide: CGFloat {
        max(interactionSize.width, interactionSize.height)
    }

    private var visualOffset: CGSize {
        ControllerLayoutMetrics.visualOffset(for: elementCustomization)
    }

    private var activationDiameter: CGFloat? {
        joystickVisualStyle == .thumbstick ? max(44, visualSide) : nil
    }

    private var knobSide: CGFloat {
        switch joystickVisualStyle {
        case .pad:
            max(34, visualSide * 0.36)
        case .thumbstick:
            max(32, visualSide * 0.72)
        }
    }

    private var knobTravelRadius: CGFloat {
        switch joystickVisualStyle {
        case .pad:
            max(0, (visualSide - knobSide) / 2 - 4)
        case .thumbstick:
            max(0, (hitSide - knobSide) / 2 - 6)
        }
    }

    private var accessibleLabel: String {
        KeypadAccessibility.label(visibleTitle: label, fallback: "Joystick")
    }

    private var bindingPresentationsForDirections: [(GamepadJoystickDirection, KeypadBindingPresentation)] {
        GamepadJoystickDirection.allCases.compactMap { direction in
            let input = elementID.map {
                KeypadElementInputID(elementID: $0, part: KeypadElementInputPart(direction: direction))
            } ?? KeypadElementInputID(elementID: KeypadElement.builtInID(for: mapping[direction]))
            return client.bindingPresentation(
                orientation: customization.deviceCanvas.editorDeviceFrame.orientation,
                input: input
            ).map { (direction, $0) }
        }
    }

    private var compactBindingText: String? {
        let text = bindingPresentationsForDirections
            .map { "\($0.0.shortLabel)\($0.1.compactText)" }
            .joined(separator: " ")
        guard showsBindingGlyphs, !text.isEmpty, !text.isSameBindingDisplay(as: label) else { return nil }
        return text
    }

    private var accessibleBindingText: String? {
        let text = bindingPresentationsForDirections
            .map { "\($0.0.displayName) \($0.1.accessibilityText)" }
            .joined(separator: ", ")
        return text.isEmpty ? nil : text
    }

    private var joystickAccessibility: CaptureAccessibilityMetadata {
        let bindingHint = accessibleBindingText.map { " Binding: \($0)." } ?? ""
        return CaptureAccessibilityMetadata(
            label: accessibleLabel,
            hint: KeypadAccessibility.joystickHint(outputSettings: outputSettings) + bindingHint,
            identifier: KeypadAccessibility.identifier(kind: "joystick", elementID: elementID, fallback: accessibleLabel),
            value: KeypadAccessibility.joystickValue(
                horizontal: normalizedOffset.width,
                vertical: normalizedOffset.height,
                activeDirections: activeDirections
            )
        )
    }

    private var visualLabelScale: CGFloat {
        KeypadAccessibility.visualLabelScale(isAccessibilitySize: dynamicTypeSize.isAccessibilitySize)
    }

    var body: some View {
        ZStack {
            joystickBase
                .frame(width: interactionSize.width, height: interactionSize.height)
                .offset(visualOffset)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            if client.isConnected || client.isPracticeModeEnabled {
                JoystickCaptureView(
                    activationDiameter: activationDiameter,
                    isEnabled: true,
                    accessibility: joystickAccessibility
                ) { direction, pressed, pressIdentifier in
                    handleDirectionEdge(direction, pressed: pressed, pressIdentifier: pressIdentifier)
                } onAccessibilityDirection: { direction in
                    handleAccessibilityDirection(direction)
                } onVectorChanged: { vector, directions in
                    normalizedOffset = CGSize(width: vector.dx, height: vector.dy)
                    activeDirections = directions
                    handleVectorChanged(vector)
                }
                .frame(width: interactionSize.width, height: interactionSize.height)
            }
        }
        .frame(width: interactionSize.width, height: interactionSize.height)
        .onDisappear {
            activeDirections.removeAll()
            normalizedOffset = .zero
        }
    }

    private var joystickBase: some View {
        let accentStyle = elementCustomization.accentStyle ?? customization.accentStyle
        let isActive = !activeDirections.isEmpty || abs(normalizedOffset.width) > 0.001 || abs(normalizedOffset.height) > 0.001
        let presentation = customization.resolvedPresentation(for: elementCustomization, fallbackAccentStyle: accentStyle, controlKind: .joystick, state: isActive ? .active : .normal, scheme: colorScheme)
        let fillStyle = presentation.fillStyle
        let strokeColor = presentation.strokeSwiftUIColor
        let foregroundColor = presentation.foregroundSwiftUIColor
        let strokeWidth = presentation.strokeWidth + (colorSchemeContrast == .increased ? 1.5 : 0)
        let knobFillColor = elementCustomization.joystickKnobFill(accentStyle: accentStyle, isPressed: isActive, scheme: colorScheme)
        let knobStrokeColor = elementCustomization.joystickKnobStroke(accentStyle: accentStyle, isPressed: isActive, scheme: colorScheme)
        let knobOffset = CGSize(width: normalizedOffset.width * knobTravelRadius, height: normalizedOffset.height * knobTravelRadius)
        let isThumbstick = joystickVisualStyle == .thumbstick

        return ZStack {
            if reduceTransparency {
                Circle()
                    .fill(Geist.color(.gray100, scheme: colorScheme))
                    .frame(width: visualSide, height: visualSide)
            }

            if isThumbstick && isActive {
                Circle()
                    .stroke(foregroundColor.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [5, 7]))
                    .frame(width: hitSide * 0.72, height: hitSide * 0.72)
                    .transition(.opacity)
            }

            GamepadFillShapeLayer(shape: Circle(), fillStyle: fillStyle)
                .overlay(Circle().stroke(strokeColor, lineWidth: strokeWidth))
                .overlay(GamepadControlEffectOverlay(shape: Circle(), presentation: presentation))
                .gamepadOuterShadows(presentation)
                .frame(width: visualSide, height: visualSide)

            if !isThumbstick {
                Circle()
                    .stroke(Geist.color(.grayAlpha400, scheme: colorScheme), lineWidth: 1)
                    .frame(width: visualSide * 0.70, height: visualSide * 0.70)

                directionLabels(foregroundColor: foregroundColor)
            }

            Circle()
                .fill(knobFillColor)
                .overlay(Circle().stroke(knobStrokeColor, lineWidth: colorSchemeContrast == .increased ? 2.5 : 1))
                .overlay {
                    if differentiateWithoutColor && isActive {
                        Circle().stroke(style: StrokeStyle(lineWidth: 2.5, dash: [3, 3]))
                    }
                }
                .frame(width: knobSide, height: knobSide)
                .offset(knobOffset)
                .animation(reduceMotion ? nil : .interactiveSpring(response: 0.16, dampingFraction: 0.82), value: normalizedOffset)

            if isActive {
                Circle()
                    .stroke(style: StrokeStyle(lineWidth: colorSchemeContrast == .increased ? 3 : 2, dash: [5, 4]))
                    .foregroundStyle(foregroundColor)
                    .frame(width: visualSide * 0.88, height: visualSide * 0.88)
                    .allowsHitTesting(false)
            }

            if customization.showsButtonLabels && elementCustomization.showsIntegratedLabel && !isThumbstick {
                VStack(spacing: 1) {
                    Text(label)
                        .geistTypography(visualSide <= 88 ? .button12 : .button14)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    if let compactBindingText {
                        KeypadSecondaryBindingText(
                            text: compactBindingText,
                            color: foregroundColor,
                            maximumWidth: visualSide * 0.92
                        )
                    }
                }
                .foregroundStyle(foregroundColor)
                .padding(.horizontal, 4)
                .scaleEffect(visualLabelScale)
                .offset(y: visualSide * 0.34)
            }
        }
    }

    private func directionLabels(foregroundColor: Color) -> some View {
        ZStack {
            ForEach(GamepadJoystickDirection.allCases) { direction in
                Text(direction.shortLabel)
                    .geistTypography(.label12)
                    .foregroundStyle(foregroundColor.opacity(activeDirections.contains(direction) ? 1 : 0.42))
                    .offset(labelOffset(for: direction))
            }
        }
        .allowsHitTesting(false)
    }

    private func labelOffset(for direction: GamepadJoystickDirection) -> CGSize {
        let radius = visualSide * 0.34
        switch direction {
        case .up: return CGSize(width: 0, height: -radius)
        case .down: return CGSize(width: 0, height: radius)
        case .left: return CGSize(width: -radius, height: 0)
        case .right: return CGSize(width: radius, height: 0)
        }
    }

    private func handleDirectionEdge(_ direction: GamepadJoystickDirection, pressed: Bool, pressIdentifier: UInt64) {
        guard outputSettings.normalized.sendsDigitalDirections else { return }
        if let elementID {
            client.setElementInput(
                KeypadElementInputID(elementID: elementID, part: KeypadElementInputPart(direction: direction)),
                pressed: pressed,
                pressIdentifier: pressIdentifier
            )
        } else {
            client.setButton(mapping[direction], pressed: pressed, pressIdentifier: pressIdentifier)
        }
    }

    private func handleAccessibilityDirection(_ direction: GamepadJoystickDirection) {
        let settings = outputSettings.normalized
        guard let stick = settings.analogTarget.stick else { return }
        let vector: CGVector
        switch direction {
        case .up: vector = CGVector(dx: 0, dy: -1)
        case .down: vector = CGVector(dx: 0, dy: 1)
        case .left: vector = CGVector(dx: -1, dy: 0)
        case .right: vector = CGVector(dx: 1, dy: 0)
        }
        let transformed = settings.transformedVector(x: vector.dx, y: vector.dy)
        client.setGamepadStick(stick, x: Double(transformed.dx), y: Double(transformed.dy), isFinal: false)
        client.setGamepadStick(stick, x: 0, y: 0, isFinal: true)
    }

    private func handleVectorChanged(_ vector: CGVector) {
        let settings = outputSettings.normalized
        guard let stick = settings.analogTarget.stick else { return }
        let transformed = settings.transformedVector(x: vector.dx, y: vector.dy)
        let isFinal = abs(vector.dx) < 0.001 && abs(vector.dy) < 0.001
        client.setGamepadStick(stick, x: Double(transformed.dx), y: Double(transformed.dy), isFinal: isFinal)
    }
}

private struct GamepadTrigger: View {
    @EnvironmentObject private var client: ControllerClient
    @AppStorage(IOSKeypadPreferenceKeys.showBindingGlyphs) private var showsBindingGlyphs = IOSKeypadPreferenceKeys.defaultShowBindingGlyphs
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let elementID: UUID?
    let mappedButton: GameButton
    let label: String
    let size: CGSize
    let elementCustomization: GamepadButtonCustomization
    let settings: GamepadTriggerSettings
    let customization: GamepadCustomization

    @State private var value: CGFloat = 0
    @State private var isDigitalPressed = false

    private var accessibleLabel: String {
        KeypadAccessibility.label(visibleTitle: label, fallback: "Trigger")
    }

    private var bindingPresentation: KeypadBindingPresentation? {
        let input = KeypadElementInputID(
            elementID: elementID ?? KeypadElement.builtInID(for: mappedButton),
            part: elementID == nil ? .primary : .triggerDigital
        )
        return client.bindingPresentation(
            orientation: customization.deviceCanvas.editorDeviceFrame.orientation,
            input: input
        )
    }

    private var compactBindingText: String? {
        guard showsBindingGlyphs,
              let text = bindingPresentation?.compactText,
              !text.isSameBindingDisplay(as: label)
        else { return nil }
        return text
    }

    private var triggerAccessibility: CaptureAccessibilityMetadata {
        let target = settings.normalized.target.displayName
        let bindingSuffix = bindingPresentation.map { " Digital binding: \($0.accessibilityText)." } ?? ""
        return CaptureAccessibilityMetadata(
            label: accessibleLabel,
            hint: "Swipe up or down to adjust \(target) from 0 to 100 percent.\(bindingSuffix)",
            identifier: KeypadAccessibility.identifier(kind: "trigger", elementID: elementID, fallback: accessibleLabel),
            value: KeypadAccessibility.percentValue(value)
        )
    }

    private var visualLabelScale: CGFloat {
        KeypadAccessibility.visualLabelScale(isAccessibilitySize: dynamicTypeSize.isAccessibilitySize)
    }

    var body: some View {
        let hitSize = ControllerLayoutMetrics.hitSize(for: size, customization: elementCustomization)
        let visualOffset = ControllerLayoutMetrics.visualOffset(for: elementCustomization)
        ZStack {
            triggerFace
                .frame(width: size.width, height: size.height)
                .offset(visualOffset)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            if client.isConnected || client.isPracticeModeEnabled {
                TriggerCaptureView(
                    orientation: settings.normalized.orientation,
                    isEnabled: true,
                    accessibility: triggerAccessibility,
                    accessibilityValue: value
                ) { rawValue, isActive in
                    handleValueChanged(rawValue, isActive: isActive)
                } onAccessibilityValueChanged: { adjustedValue in
                    handleTransformedValueChanged(adjustedValue, isActive: false)
                }
                .frame(width: hitSize.width, height: hitSize.height)
            }
        }
        .frame(width: hitSize.width, height: hitSize.height)
        .onDisappear {
            if value != 0 {
                handleValueChanged(0, isActive: false)
            }
        }
    }

    private var triggerFace: some View {
        let normalizedSettings = settings.normalized
        let accentStyle = elementCustomization.accentStyle ?? customization.accentStyle
        let isPressed = value > normalizedSettings.deadZone
        let presentation = customization.resolvedPresentation(for: elementCustomization, fallbackAccentStyle: accentStyle, controlKind: .trigger, state: isPressed ? .active : .normal, scheme: colorScheme)
        let fillStyle = presentation.fillStyle
        let strokeColor = presentation.strokeSwiftUIColor
        let foregroundColor = presentation.foregroundSwiftUIColor
        let fillFraction = max(0, min(1, value))
        let strokeWidth = presentation.strokeWidth + (colorSchemeContrast == .increased ? 1.5 : 0)

        return ZStack(alignment: normalizedSettings.orientation == .vertical ? .bottom : .leading) {
            if reduceTransparency {
                Capsule().fill(Geist.color(.gray100, scheme: colorScheme))
            }

            GamepadFillShapeLayer(shape: Capsule(), fillStyle: fillStyle)
                .overlay(Capsule().stroke(strokeColor, lineWidth: strokeWidth))
                .overlay(GamepadControlEffectOverlay(shape: Capsule(), presentation: presentation))
                .gamepadOuterShadows(presentation)

            Capsule()
                .fill(foregroundColor.opacity(reduceTransparency ? 0.62 : (colorScheme == .dark ? 0.24 : 0.18)))
                .frame(
                    width: normalizedSettings.orientation == .vertical ? size.width : max(4, size.width * fillFraction),
                    height: normalizedSettings.orientation == .vertical ? max(4, size.height * fillFraction) : size.height
                )
                .allowsHitTesting(false)

            if customization.showsButtonLabels && elementCustomization.showsIntegratedLabel {
                HStack(spacing: 5) {
                    Text(label)
                        .geistTypography(size.height <= 44 ? .button12 : .button14)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    if let compactBindingText, size.width >= 76 {
                        KeypadSecondaryBindingText(
                            text: compactBindingText,
                            color: foregroundColor,
                            maximumWidth: size.width * 0.46
                        )
                    }
                }
                .foregroundStyle(foregroundColor)
                .padding(.horizontal, 8)
                .scaleEffect(visualLabelScale)
            }

            if differentiateWithoutColor && fillFraction > 0.001 {
                Text(KeypadAccessibility.percentValue(fillFraction))
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(foregroundColor)
                    .padding(4)
                    .background(Geist.color(.gray100, scheme: colorScheme), in: Capsule())
                    .padding(4)
            }
        }
    }

    private func handleValueChanged(_ rawValue: CGFloat, isActive: Bool) {
        handleTransformedValueChanged(settings.normalized.transformedValue(rawValue), isActive: isActive)
    }

    private func handleTransformedValueChanged(_ transformedValue: CGFloat, isActive: Bool) {
        let normalizedSettings = settings.normalized
        let transformed = min(max(transformedValue, 0), 1)
        value = transformed
        client.setGamepadTrigger(normalizedSettings.target, value: Double(transformed), isFinal: !isActive || transformed <= 0.001)

        guard normalizedSettings.sendsDigitalButton else { return }
        let shouldPress = transformed >= normalizedSettings.digitalThreshold
        if shouldPress != isDigitalPressed {
            isDigitalPressed = shouldPress
            sendDigitalPress(shouldPress)
        }
        if !isActive, isDigitalPressed {
            isDigitalPressed = false
            sendDigitalPress(false)
        }
    }

    private func sendDigitalPress(_ pressed: Bool) {
        if let elementID {
            client.setElementInput(
                KeypadElementInputID(elementID: elementID, part: .triggerDigital),
                pressed: pressed
            )
        } else {
            client.setButton(mappedButton, pressed: pressed)
        }
    }
}

final class KeypadHapticPlayer {
    static let shared = KeypadHapticPlayer()

    private var engine: CHHapticEngine?
    private var fallbackGenerators: [GamepadHapticStyle: UIImpactFeedbackGenerator] = [:]

    private init() {}

    func prepare(
        _ feedback: GamepadHapticFeedback,
        intensityScale: Double = IOSKeypadPreferenceKeys.defaultHapticIntensity
    ) {
        let feedback = scaled(feedback, intensityScale: intensityScale)
        guard feedback.style != .none, feedback.intensity > 0 else { return }
        if CHHapticEngine.capabilitiesForHardware().supportsHaptics {
            try? startEngineIfNeeded()
        } else {
            fallbackGenerator(for: feedback.style).prepare()
        }
    }

    func play(
        _ feedback: GamepadHapticFeedback,
        intensityScale: Double = IOSKeypadPreferenceKeys.defaultHapticIntensity
    ) {
        let feedback = scaled(feedback, intensityScale: intensityScale)
        guard feedback.style != .none, feedback.intensity > 0 else { return }
        if CHHapticEngine.capabilitiesForHardware().supportsHaptics, playCoreHaptic(feedback) {
            return
        }
        playFallback(feedback)
    }

    private func scaled(_ feedback: GamepadHapticFeedback, intensityScale: Double) -> GamepadHapticFeedback {
        var scaled = feedback.normalized
        scaled.intensity = KeypadHapticIntensityPolicy.scaledIntensity(
            scaled.intensity,
            globalIntensity: intensityScale
        )
        return scaled
    }

    private func playCoreHaptic(_ feedback: GamepadHapticFeedback) -> Bool {
        do {
            try startEngineIfNeeded()
            let pattern = try CHHapticPattern(events: feedback.coreHapticEvents, parameters: [])
            let player = try engine?.makePlayer(with: pattern)
            try player?.start(atTime: CHHapticTimeImmediate)
            return true
        } catch {
            return false
        }
    }

    private func startEngineIfNeeded() throws {
        if engine == nil {
            let newEngine = try CHHapticEngine()
            newEngine.stoppedHandler = { [weak self] _ in
                self?.engine = nil
            }
            newEngine.resetHandler = { [weak self] in
                try? self?.engine?.start()
            }
            engine = newEngine
        }
        try engine?.start()
    }

    private func playFallback(_ feedback: GamepadHapticFeedback) {
        let generator = fallbackGenerator(for: feedback.style)
        for event in feedback.fallbackImpactSchedule {
            DispatchQueue.main.asyncAfter(deadline: .now() + event.delay) {
                generator.impactOccurred(intensity: event.intensity)
                generator.prepare()
            }
        }
    }

    private func fallbackGenerator(for style: GamepadHapticStyle) -> UIImpactFeedbackGenerator {
        if let generator = fallbackGenerators[style] { return generator }
        let generator = UIImpactFeedbackGenerator(style: style.impactFeedbackStyle)
        fallbackGenerators[style] = generator
        return generator
    }
}

private extension GamepadHapticStyle {
    var impactFeedbackStyle: UIImpactFeedbackGenerator.FeedbackStyle {
        switch self {
        case .none, .light: .light
        case .medium: .medium
        case .heavy: .heavy
        case .soft: .soft
        case .rigid: .rigid
        }
    }
}

private extension GamepadHapticFeedback {
    var coreHapticEvents: [CHHapticEvent] {
        let feedback = normalized
        let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(feedback.intensity))
        let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: Float(feedback.sharpness))
        let parameters = [intensity, sharpness]
        let duration = TimeInterval(feedback.duration)

        switch feedback.pattern {
        case .single:
            return [CHHapticEvent(eventType: .hapticTransient, parameters: parameters, relativeTime: 0)]
        case .double:
            let spacing = min(max(duration, 0.045), 0.18)
            return [
                CHHapticEvent(eventType: .hapticTransient, parameters: parameters, relativeTime: 0),
                CHHapticEvent(eventType: .hapticTransient, parameters: parameters, relativeTime: spacing)
            ]
        case .pulse:
            return [CHHapticEvent(eventType: .hapticContinuous, parameters: parameters, relativeTime: 0, duration: max(duration, 0.035))]
        case .buzz:
            let buzzDuration = max(duration, 0.08)
            let accentIntensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(min(1, feedback.intensity * 0.85)))
            return [
                CHHapticEvent(eventType: .hapticContinuous, parameters: parameters, relativeTime: 0, duration: buzzDuration),
                CHHapticEvent(eventType: .hapticTransient, parameters: [accentIntensity, sharpness], relativeTime: 0),
                CHHapticEvent(eventType: .hapticTransient, parameters: [accentIntensity, sharpness], relativeTime: buzzDuration * 0.55)
            ]
        }
    }

    var fallbackImpactSchedule: [(delay: TimeInterval, intensity: CGFloat)] {
        let feedback = normalized
        let duration = TimeInterval(feedback.duration)
        switch feedback.pattern {
        case .single, .pulse:
            return [(0, feedback.intensity)]
        case .double:
            return [(0, feedback.intensity), (min(max(duration, 0.045), 0.18), feedback.intensity * 0.85)]
        case .buzz:
            let step: TimeInterval = 0.045
            let count = max(2, min(6, Int(ceil(max(duration, 0.08) / step))))
            return (0..<count).map { index in
                (Double(index) * step, feedback.intensity * (index.isMultiple(of: 2) ? 0.92 : 0.68))
            }
        }
    }
}

private struct GamepadTrackpad: View {
    @EnvironmentObject private var client: ControllerClient
    @AppStorage(IOSKeypadPreferenceKeys.showBindingGlyphs) private var showsBindingGlyphs = IOSKeypadPreferenceKeys.defaultShowBindingGlyphs
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.keypadHapticIntensity) private var keypadHapticIntensity
    let elementID: UUID?
    let label: String
    let size: CGSize
    let elementCustomization: GamepadButtonCustomization
    let settings: GamepadTrackpadSettings
    let customization: GamepadCustomization

    @State private var isActive = false
    @State private var touchCount = 0

    private var normalizedSettings: GamepadTrackpadSettings {
        settings.normalized
    }

    private var accessibleLabel: String {
        KeypadAccessibility.label(visibleTitle: label, fallback: "Trackpad")
    }

    private var bindingPresentation: KeypadBindingPresentation? {
        guard let elementID else { return nil }
        return client.bindingPresentation(
            orientation: customization.deviceCanvas.editorDeviceFrame.orientation,
            input: KeypadElementInputID(elementID: elementID)
        )
    }

    private var compactBindingText: String? {
        guard showsBindingGlyphs,
              let text = bindingPresentation?.compactText,
              !text.isSameBindingDisplay(as: label)
        else { return nil }
        return text
    }

    private var trackpadAccessibility: CaptureAccessibilityMetadata {
        let scrollHint = normalizedSettings.twoFingerScroll ? " Two-finger direct touch scrolls." : ""
        let tapHint = normalizedSettings.tapToClick ? " A one-finger tap clicks." : ""
        let bindingHint = bindingPresentation.map { " Binding: \($0.accessibilityText)." } ?? ""
        return CaptureAccessibilityMetadata(
            label: accessibleLabel,
            hint: "Touch directly to move the pointer. Use the Click or Right Click actions.\(tapHint)\(scrollHint)\(bindingHint)",
            identifier: KeypadAccessibility.identifier(kind: "trackpad", elementID: elementID, fallback: accessibleLabel),
            value: isActive ? "\(touchCount) finger\(touchCount == 1 ? "" : "s") active" : "Idle"
        )
    }

    private var visualLabelScale: CGFloat {
        KeypadAccessibility.visualLabelScale(isAccessibilitySize: dynamicTypeSize.isAccessibilitySize)
    }

    var body: some View {
        let hitSize = ControllerLayoutMetrics.hitSize(for: size, customization: elementCustomization)
        let visualOffset = ControllerLayoutMetrics.visualOffset(for: elementCustomization)

        ZStack {
            trackpadSurface
                .frame(width: size.width, height: size.height)
                .offset(visualOffset)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            if client.isConnected || client.isPracticeModeEnabled {
                TrackpadCaptureView(
                    isTapToClickEnabled: normalizedSettings.tapToClick,
                    isTwoFingerScrollEnabled: normalizedSettings.twoFingerScroll,
                    isEnabled: true,
                    accessibility: trackpadAccessibility
                ) { delta in
                    handleMove(delta)
                } onScroll: { delta in
                    handleScroll(delta)
                } onTap: { fingerCount in
                    handleTap(fingerCount: fingerCount)
                } onActiveChanged: { active, count in
                    isActive = active
                    touchCount = count
                }
                .frame(width: hitSize.width, height: hitSize.height)
            }
        }
        .frame(width: hitSize.width, height: hitSize.height)
        .onAppear { prepareHapticIfNeeded() }
        .onChange(of: keypadHapticIntensity) { _, _ in
            prepareHapticIfNeeded()
        }
        .onDisappear {
            isActive = false
            touchCount = 0
        }
    }

    private var resolvedAccentStyle: GamepadAccentStyle {
        elementCustomization.accentStyle ?? customization.accentStyle
    }

    private var resolvedCornerRadii: GamepadCornerRadii {
        elementCustomization.resolvedCornerRadii(defaultRadius: GamepadButtonShapeStyle.roundedRectangle.defaultEditableCornerRadius(in: size))
    }

    private var trackpadSurface: some View {
        let presentation = customization.resolvedPresentation(for: elementCustomization, fallbackAccentStyle: resolvedAccentStyle, controlKind: .trackpad, state: isActive ? .active : .normal, scheme: colorScheme)
        let fillStyle = presentation.fillStyle
        let strokeColor = presentation.strokeSwiftUIColor
        let foregroundColor = presentation.foregroundSwiftUIColor
        let shape = UnevenRoundedRectangle(cornerRadii: resolvedCornerRadii.rectangleCornerRadii, style: .continuous)
        let strokeWidth = presentation.strokeWidth + (colorSchemeContrast == .increased ? 1.5 : 0)

        return ZStack {
            if reduceTransparency {
                shape.fill(Geist.color(.gray100, scheme: colorScheme))
            }

            GamepadFillShapeLayer(shape: shape, fillStyle: fillStyle)
                .overlay(shape.stroke(strokeColor, lineWidth: strokeWidth))
                .overlay(GamepadControlEffectOverlay(shape: shape, presentation: presentation))
                .gamepadOuterShadows(presentation)

            RoundedRectangle(cornerRadius: max(8, min(size.width, size.height) * 0.08), style: .continuous)
                .stroke(foregroundColor.opacity(isActive ? 0.28 : 0.18), lineWidth: 1)
                .padding(max(8, min(size.width, size.height) * 0.08))

            VStack(spacing: max(4, size.height * 0.06)) {
                Image(systemName: touchCount >= 2 ? "hand.draw" : "cursorarrow")
                    .font(.system(size: max(18, min(size.width, size.height) * 0.20), weight: .semibold))
                    .foregroundStyle(foregroundColor.opacity(isActive ? 0.95 : 0.70))

                if customization.showsButtonLabels && elementCustomization.showsIntegratedLabel {
                    VStack(spacing: 2) {
                        Text(label)
                            .geistTypography(size.width <= 112 ? .button12 : .button14)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                        if let compactBindingText {
                            KeypadSecondaryBindingText(
                                text: compactBindingText,
                                color: foregroundColor,
                                maximumWidth: size.width * 0.82
                            )
                        }
                    }
                    .foregroundStyle(foregroundColor.opacity(reduceTransparency ? 1 : 0.94))
                    .padding(.horizontal, 8)
                    .scaleEffect(visualLabelScale)
                }
            }

            HStack(spacing: 7) {
                Capsule().fill(foregroundColor.opacity(reduceTransparency ? 0.72 : (isActive ? 0.42 : 0.30)))
                Capsule().fill(foregroundColor.opacity(reduceTransparency ? (touchCount >= 2 ? 0.72 : 0.32) : (touchCount >= 2 ? 0.42 : 0.16)))
            }
            .frame(width: size.width * 0.32, height: max(4, size.height * 0.045))
            .offset(y: size.height * 0.37)

            if isActive {
                shape.stroke(
                    foregroundColor,
                    style: StrokeStyle(
                        lineWidth: colorSchemeContrast == .increased ? 3 : 2,
                        dash: differentiateWithoutColor ? [6, 4] : []
                    )
                )
                .padding(3)
            }
        }
        .scaleEffect(isActive ? 0.97 : 1)
        .animation(reduceMotion ? nil : .interactiveSpring(response: 0.14, dampingFraction: 0.82), value: isActive)
        .animation(reduceMotion ? nil : .interactiveSpring(response: 0.14, dampingFraction: 0.82), value: touchCount)
    }

    private func handleMove(_ delta: CGVector) {
        let settings = normalizedSettings
        client.sendPointerMove(
            deltaX: Double(delta.dx) * Double(settings.sensitivity),
            deltaY: Double(delta.dy) * Double(settings.sensitivity)
        )
    }

    private func handleScroll(_ delta: CGVector) {
        let settings = normalizedSettings
        let direction = settings.naturalScrolling ? 1.0 : -1.0
        client.sendPointerScroll(
            deltaX: Double(delta.dx) * Double(settings.scrollSensitivity) * direction,
            deltaY: Double(delta.dy) * Double(settings.scrollSensitivity) * direction
        )
    }

    private func handleTap(fingerCount: Int) {
        scheduleTapHaptic()
        client.sendPointerClick(fingerCount >= 2 ? .right : .left)
    }

    private func scheduleTapHaptic() {
        let feedback = customization.resolvedPresentation(for: elementCustomization, fallbackAccentStyle: resolvedAccentStyle, controlKind: .trackpad, state: .active, scheme: colorScheme).hapticFeedback
        let intensity = keypadHapticIntensity
        DispatchQueue.main.async {
            KeypadHapticPlayer.shared.play(feedback, intensityScale: intensity)
        }
    }

    private func prepareHapticIfNeeded() {
        let feedback = customization.resolvedPresentation(for: elementCustomization, fallbackAccentStyle: resolvedAccentStyle, controlKind: .trackpad, state: .normal, scheme: colorScheme).hapticFeedback
        KeypadHapticPlayer.shared.prepare(feedback, intensityScale: keypadHapticIntensity)
    }
}

private struct GamepadButton: View {
    @EnvironmentObject private var client: ControllerClient
    @AppStorage(IOSKeypadPreferenceKeys.showBindingGlyphs) private var showsBindingGlyphs = IOSKeypadPreferenceKeys.defaultShowBindingGlyphs
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.keypadHapticIntensity) private var keypadHapticIntensity
    var elementID: UUID? = nil
    let button: GameButton
    let size: CGSize
    var shape: GamepadButtonShapeStyle = .roundedRectangle
    var labelOverride: String? = nil
    var elementCustomization: GamepadButtonCustomization? = nil
    let customization: GamepadCustomization

    @State private var isPressed = false

    private var title: String {
        labelOverride ?? customization.visualLabel(for: button)
    }

    private var accessibleTitle: String {
        KeypadAccessibility.label(visibleTitle: title, fallback: button.displayName)
    }

    private var bindingPresentation: KeypadBindingPresentation? {
        client.bindingPresentation(
            orientation: customization.deviceCanvas.editorDeviceFrame.orientation,
            input: KeypadElementInputID(elementID: elementID ?? KeypadElement.builtInID(for: button))
        )
    }

    private var compactBindingText: String? {
        guard showsBindingGlyphs, let text = bindingPresentation?.compactText else { return nil }
        if text.isSameBindingDisplay(as: title) { return nil }
        if let icon = resolvedPresentation.icon,
           icon.source == .text,
           text.isSameBindingDisplay(as: icon.value) { return nil }
        return text
    }

    private var buttonAccessibility: CaptureAccessibilityMetadata {
        let output = bindingPresentation?.accessibilityText
        return CaptureAccessibilityMetadata(
            label: accessibleTitle,
            hint: KeypadAccessibility.buttonHint(outputDescription: output, fallbackOutputName: button.displayName),
            identifier: KeypadAccessibility.identifier(kind: "button", elementID: elementID, fallback: accessibleTitle),
            value: isPressed ? "Pressed" : nil
        )
    }

    private var visualLabelScale: CGFloat {
        KeypadAccessibility.visualLabelScale(isAccessibilitySize: dynamicTypeSize.isAccessibilitySize)
    }

    var body: some View {
        let hitSize = ControllerLayoutMetrics.hitSize(for: size, customization: resolvedButtonCustomization)
        let visualOffset = ControllerLayoutMetrics.visualOffset(for: resolvedButtonCustomization)
        let presentation = adaptivePresentation

        ZStack {
            ZStack {
                buttonBackground(presentation: presentation)
                    .gamepadOuterShadows(presentation)
                    .overlay {
                        if let glowColor = presentation.glowSwiftUIColor, presentation.glowRadius > 0 {
                            buttonBackground(presentation: presentation)
                                .blur(radius: presentation.glowRadius)
                                .foregroundStyle(glowColor)
                                .opacity(0.68)
                                .allowsHitTesting(false)
                        }
                    }

                buttonContent(presentation: presentation)

                if isPressed && differentiateWithoutColor {
                    Image(systemName: "checkmark")
                        .font(.caption2.bold())
                        .foregroundStyle(presentation.foregroundSwiftUIColor)
                        .padding(4)
                        .background(Geist.color(.gray100, scheme: colorScheme), in: Circle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(4)
                }
            }
            .opacity(reduceTransparency ? 1 : presentation.opacity)
            .blur(radius: reduceTransparency ? 0 : presentation.blurRadius)
            .scaleEffect(presentation.scale * (isPressed ? 0.94 : 1))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .frame(width: size.width, height: size.height)
            .offset(visualOffset)

            if client.isConnected || client.isPracticeModeEnabled {
                TouchCaptureView(
                    hitShape: resolvedShape,
                    isEnabled: true,
                    accessibility: buttonAccessibility
                ) { pressed, isActive, pressIdentifier in
                    handlePressEdge(pressed, isActive: isActive, pressIdentifier: pressIdentifier)
                }
                .frame(width: hitSize.width, height: hitSize.height)
            }
        }
        .frame(width: hitSize.width, height: hitSize.height)
        .onAppear {
            prepareHapticIfNeeded()
        }
        .onChange(of: keypadHapticIntensity) { _, _ in
            prepareHapticIfNeeded()
        }
        .onDisappear {
            isPressed = false
        }
    }

    private var resolvedButtonCustomization: GamepadButtonCustomization {
        elementCustomization ?? customization.buttonCustomization(for: button)
    }

    private var resolvedShape: GamepadButtonShapeStyle {
        resolvedButtonCustomization.resolvedShape(defaultShape: shape)
    }

    private var resolvedAccentStyle: GamepadAccentStyle {
        resolvedButtonCustomization.accentStyle ?? customization.accentStyle
    }

    private var resolvedCornerRadii: GamepadCornerRadii {
        resolvedButtonCustomization.resolvedCornerRadii(defaultRadius: resolvedShape.defaultEditableCornerRadius(in: size))
    }

    private var resolvedShadowStrength: CGFloat {
        resolvedButtonCustomization.shadowStrength
    }

    private var resolvedPresentation: GamepadResolvedControlPresentation {
        customization.resolvedPresentation(
            for: resolvedButtonCustomization,
            fallbackAccentStyle: resolvedAccentStyle,
            state: isPressed ? .pressed : .normal,
            scheme: colorScheme
        )
    }

    private var adaptivePresentation: GamepadResolvedControlPresentation {
        var presentation = resolvedPresentation
        if colorSchemeContrast == .increased {
            presentation.strokeWidth = max(2, presentation.strokeWidth + 1.5)
        }
        if reduceTransparency {
            presentation.opacity = 1
            presentation.blurRadius = 0
            presentation.glowColor = nil
            presentation.glowRadius = 0
            presentation.shadowRadius = 0
            presentation.shadows = []
            presentation.innerShadowColor = nil
            presentation.highlightColor = nil
        }
        return presentation
    }

    @ViewBuilder
    private func buttonBackground(presentation: GamepadResolvedControlPresentation) -> some View {
        let fillStyle = presentation.fillStyle
        let strokeColor = presentation.strokeSwiftUIColor
        let lineWidth: CGFloat = presentation.strokeWidth

        switch resolvedShape {
        case .roundedRectangle, .rectangle, .capsule, .circle, .ellipse:
            let shape = UnevenRoundedRectangle(cornerRadii: resolvedCornerRadii.rectangleCornerRadii, style: .continuous)
            GamepadFillShapeLayer(shape: shape, fillStyle: fillStyle)
                .overlay(shape.stroke(strokeColor, lineWidth: lineWidth))
                .overlay(GamepadControlEffectOverlay(shape: shape, presentation: presentation))
        case .polygon:
            let shape = GamepadRegularPolygonButtonShape(sides: 3)
            GamepadFillShapeLayer(shape: shape, fillStyle: fillStyle)
                .overlay(shape.stroke(strokeColor, lineWidth: lineWidth))
                .overlay(GamepadControlEffectOverlay(shape: shape, presentation: presentation))
        case .star:
            let shape = GamepadStarButtonShape(points: 5)
            GamepadFillShapeLayer(shape: shape, fillStyle: fillStyle)
                .overlay(shape.stroke(strokeColor, lineWidth: lineWidth))
                .overlay(GamepadControlEffectOverlay(shape: shape, presentation: presentation))
        }
    }

    @ViewBuilder
    private func buttonContent(presentation: GamepadResolvedControlPresentation) -> some View {
        if let icon = presentation.icon {
            controlIcon(icon, presentation: presentation)
                .padding(.horizontal, 4)
        }

        if customization.showsButtonLabels
            && (elementCustomization?.showsIntegratedLabel ?? true)
            && (presentation.icon?.placement != .center || title.count <= 2) {
            VStack(spacing: 1) {
                Text(title)
                    .geistTypography(title.count <= 2 ? .heading32 : .button16)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                if let compactBindingText {
                    KeypadSecondaryBindingText(
                        text: compactBindingText,
                        color: presentation.foregroundSwiftUIColor,
                        maximumWidth: size.width * 0.88
                    )
                }
            }
            .foregroundStyle(presentation.foregroundSwiftUIColor)
            .padding(.horizontal, 4)
            .scaleEffect(visualLabelScale)
            .offset(labelOffset(for: presentation.icon?.placement))
        }
    }

    @ViewBuilder
    private func controlIcon(_ icon: GamepadControlIcon, presentation: GamepadResolvedControlPresentation) -> some View {
        let tint = icon.tintColor?.swiftUIColor ?? presentation.foregroundSwiftUIColor
        let baseSize = max(12, min(size.width, size.height) * 0.34 * icon.scale)
        switch icon.source {
        case .sfSymbol:
            Image(systemName: icon.value)
                .font(.system(size: baseSize, weight: .semibold))
                .symbolRenderingMode(icon.renderingMode == .multicolor ? .multicolor : .monochrome)
                .foregroundStyle(tint)
                .offset(iconOffset(for: icon.placement))
        case .text:
            Text(icon.value)
                .font(.system(size: baseSize, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .offset(iconOffset(for: icon.placement))
        case .asset:
            if let data = customization.assetLibrary.asset(id: icon.value)?.data {
                GamepadAssetIconImage(data: data, renderingMode: icon.renderingMode)
                    .frame(width: baseSize, height: baseSize)
                    .foregroundStyle(tint)
                    .offset(iconOffset(for: icon.placement))
            } else {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.system(size: baseSize, weight: .semibold))
                    .foregroundStyle(tint.opacity(0.72))
                    .offset(iconOffset(for: icon.placement))
            }
        }
    }

    private func iconOffset(for placement: GamepadControlIconPlacement) -> CGSize {
        switch placement {
        case .leading: CGSize(width: -size.width * 0.20, height: 0)
        case .trailing: CGSize(width: size.width * 0.20, height: 0)
        case .top: CGSize(width: 0, height: -size.height * 0.18)
        case .bottom: CGSize(width: 0, height: size.height * 0.18)
        case .center, .background: .zero
        }
    }

    private func labelOffset(for placement: GamepadControlIconPlacement?) -> CGSize {
        switch placement {
        case .leading: CGSize(width: size.width * 0.11, height: 0)
        case .trailing: CGSize(width: -size.width * 0.11, height: 0)
        case .top: CGSize(width: 0, height: size.height * 0.15)
        case .bottom: CGSize(width: 0, height: -size.height * 0.15)
        case .center, .background, nil: .zero
        }
    }

    private func handlePressEdge(_ pressed: Bool, isActive: Bool, pressIdentifier: UInt64) {
        // The UIKit touch view is authoritative for press edges. Send every edge to
        // ControllerClient before consulting SwiftUI state so fast taps cannot lose a
        // release through a stale render closure.
        if let elementID {
            client.setElementInput(
                KeypadElementInputID(elementID: elementID, part: .primary),
                pressed: pressed,
                pressIdentifier: pressIdentifier
            )
        } else {
            client.setButton(button, pressed: pressed, pressIdentifier: pressIdentifier)
        }

        guard isActive != isPressed else { return }
        isPressed = isActive

        if pressed {
            schedulePressHaptic()
        }
    }

    private func schedulePressHaptic() {
        let feedback = resolvedPresentation.hapticFeedback
        let intensity = keypadHapticIntensity
        DispatchQueue.main.async {
            KeypadHapticPlayer.shared.play(feedback, intensityScale: intensity)
        }
    }

    private func prepareHapticIfNeeded() {
        KeypadHapticPlayer.shared.prepare(resolvedPresentation.hapticFeedback, intensityScale: keypadHapticIntensity)
    }
}
