import AppKit
import SwiftUI

/// time.md-style slide scaffold: mono tag, title, subtitle, one focused content area.
struct MacOnboardingSlide<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let step: MacOnboardingStep
    private let content: Content

    init(step: MacOnboardingStep, @ViewBuilder content: () -> Content) {
        self.step = step
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: Geist.Spacing.s4) {
                Text(step.tag)
                    .geistTypography(.label12Mono)
                    .foregroundStyle(Geist.color(.gray800, scheme: colorScheme))

                Text(step.headline)
                    .geistTypography(.heading32)
                    .foregroundStyle(Geist.color(.gray1000, scheme: colorScheme))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                Text(step.subtitle)
                    .geistTypography(.copy16)
                    .foregroundStyle(Geist.color(.gray900, scheme: colorScheme))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 520)
            }

            content
                .padding(.top, Geist.Spacing.s6)
                .frame(maxWidth: 640)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Geist.Spacing.s8)
        .padding(.vertical, Geist.Spacing.s4)
        .frame(maxWidth: 720)
    }
}

/// These prerequisites have no runtime permission status: macOS does not expose
/// a reliable Local Network grant check, and a listening server is not proof of one.
struct MacOnboardingSetupStepView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var settingsOpenFailed = false
    let step: MacOnboardingStep

    var body: some View {
        MacOnboardingSlide(step: step) {
            VStack(alignment: .leading, spacing: Geist.Spacing.s4) {
                ForEach(step.instructions) { instruction in
                    MacOnboardingFeatureRow(instruction: instruction)
                }

                if step == .iPhoneApp {
                    iPhoneAppLink
                } else if step == .localNetwork {
                    localNetworkSettings
                }
            }
        }
        .alert("Couldn’t Open System Settings", isPresented: $settingsOpenFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Open System Settings → Privacy & Security → Local Network, then enable Thumble Mac.")
        }
    }

    private var iPhoneAppLink: some View {
        VStack(alignment: .leading, spacing: Geist.Spacing.s2) {
            if let url = ThumbleMacSetupGuide.iOSAppStoreURL {
                Link("Get Thumble for iPhone", destination: url)
                    .geistButtonStyle(.secondary, size: .small)
            } else {
                Button("Get Thumble for iPhone — Coming Soon") {}
                    .geistButtonStyle(.secondary, size: .small)
                    .disabled(true)
                    .accessibilityHint("The App Store link will be available after launch.")

                Text(ThumbleMacSetupGuide.iOSAppStorePlaceholder)
                    .geistTypography(.copy13)
                    .foregroundStyle(Geist.color(.gray900, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var localNetworkSettings: some View {
        VStack(alignment: .leading, spacing: Geist.Spacing.s2) {
            Button(localNetworkSettingsTitle) {
                settingsOpenFailed = !NSWorkspace.shared.open(ThumbleMacSetupGuide.localNetworkSettingsURL())
            }
            .geistButtonStyle(.secondary, size: .small)
            .help("Opens the Mac settings pane. Check the iPhone permission separately.")

            Text(ThumbleMacSetupGuide.localNetworkAvailabilityNote)
                .geistTypography(.copy13)
                .foregroundStyle(Geist.color(.gray900, scheme: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var localNetworkSettingsTitle: String {
        if #available(macOS 15, *) {
            "Open Local Network Settings"
        } else {
            "Open Privacy & Security Settings"
        }
    }
}

struct MacOnboardingFeatureRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let instruction: MacOnboardingInstruction

    var body: some View {
        HStack(alignment: .top, spacing: Geist.Spacing.s3) {
            Image(systemName: instruction.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Geist.color(.blue900, scheme: colorScheme))
                .frame(width: 30, height: 30)
                .background(Geist.color(.blue100, scheme: colorScheme), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Geist.Spacing.s1) {
                Text(instruction.title)
                    .geistTypography(.heading14)
                    .foregroundStyle(Geist.color(.gray1000, scheme: colorScheme))
                Text(instruction.text)
                    .geistTypography(.copy13)
                    .foregroundStyle(Geist.color(.gray900, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
