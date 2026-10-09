import Foundation

/// Shared setup copy keeps the desktop slides and the CLI guide in sync.
enum ThumbleMacSetupGuide {
    // TODO: Replace nil with the real App Store URL once the iOS app launches.
    // Keep the placeholder non-navigable rather than sending users to a fake listing.
    static let iOSAppStoreURL: URL? = nil
    static let iOSAppStorePlaceholder = "App Store link coming soon. Already have a test build? Open it to continue."
    static let localNetworkAvailabilityNote = "macOS 14 has no Local Network switch. On newer macOS versions, Thumble may appear only after its first connection attempt."

    static func localNetworkSettingsURL(
        macOSMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    ) -> URL {
        let pane = macOSMajorVersion >= 15 ? "Privacy_LocalNetwork" : "Privacy"
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }

    static var text: String {
        var sections = MacOnboardingStep.allCases.map { step in
            var lines = ["\(step.tag) — \(step.headline)", step.subtitle]
            lines += step.instructions.map { "- \($0.title): \($0.text)" }
            switch step {
            case .iPhoneApp:
                lines.append(iOSAppStoreURL.map { "App Store: \($0.absoluteString)" } ?? iOSAppStorePlaceholder)
                lines.append("CLI: thumble app ios-app")
            case .localNetwork:
                lines.append(localNetworkAvailabilityNote)
                lines.append("CLI: thumble app local-network-settings")
            case .permissions:
                lines.append("CLI: thumble accessibility prompt | thumble accessibility open")
            case .connect:
                lines.append("CLI: thumble pairing code | thumble pairing payload")
            case .welcome, .editor:
                break
            }
            return lines.joined(separator: "\n")
        }
        sections.append("Reopen the slides from Setup Guide in the Mac toolbar, or run thumble app replay-onboarding.")
        return sections.joined(separator: "\n\n")
    }
}

enum MacOnboardingStep: String, CaseIterable, Identifiable, Hashable {
    case welcome
    case iPhoneApp
    case localNetwork
    case permissions
    case connect
    case editor

    var id: Self { self }

    var title: String {
        switch self {
        case .welcome: "Welcome"
        case .iPhoneApp: "Install iPhone App"
        case .localNetwork: "Local Network"
        case .permissions: "Accessibility"
        case .connect: "Connect iPhone"
        case .editor: "Keypad Editor"
        }
    }

    var headline: String {
        switch self {
        case .welcome: "Your shortcuts, exactly where you need them."
        case .iPhoneApp: "Install Thumble on iPhone."
        case .localNetwork: "Allow Local Network access."
        case .permissions: "Let Thumble send your shortcuts."
        case .connect: "Connect the iPhone."
        case .editor: "Make the keypad yours."
        }
    }

    var subtitle: String {
        switch self {
        case .welcome:
            "Thumble turns iPhone presses into keyboard shortcuts, pointer actions, or controller input for the focused Mac app."
        case .iPhoneApp:
            "The iPhone app is your keypad. Install the companion app before pairing with this Mac."
        case .localNetwork:
            "Allow Local Network access on both devices so Thumble can discover your Mac and pair."
        case .permissions:
            "Accessibility lets Thumble send keyboard and pointer events to the focused Mac app. Shortcuts will not fire until it is allowed."
        case .connect:
            "Open Thumble on iPhone and scan this code, or use Smart Connect on the same network."
        case .editor:
            "A short spotlight tour walks you through the editor when you arrive."
        }
    }

    var tag: String {
        let index = Self.allCases.firstIndex(of: self) ?? 0
        let label: String
        switch self {
        case .welcome: label = "WELCOME"
        case .iPhoneApp: label = "IPHONE APP"
        case .localNetwork: label = "LOCAL NETWORK"
        case .permissions: label = "ACCESSIBILITY"
        case .connect: label = "CONNECT"
        case .editor: label = "EDITOR"
        }
        return String(format: "%02d / %@", index + 1, label)
    }

    var instructions: [MacOnboardingInstruction] {
        switch self {
        case .welcome:
            []
        case .iPhoneApp:
            [
                .init(systemImage: "iphone.gen3", title: "Get the companion app", text: "Install Thumble for iPhone from the App Store, then open it."),
                .init(systemImage: "macbook.and.iphone", title: "Keep both apps open", text: "Leave Thumble Mac running while you set up your iPhone. The Mac helper receives the actions you send from your keypad.")
            ]
        case .localNetwork:
            [
                .init(systemImage: "laptopcomputer", title: "On your Mac", text: "System Settings → Privacy & Security → Local Network → enable Thumble Mac (macOS 15 or later)."),
                .init(systemImage: "iphone.gen3", title: "On your iPhone", text: "Settings → Privacy & Security → Local Network → enable Thumble."),
                .init(systemImage: "network", title: "Choose Allow when prompted", text: "Allow Thumble to find devices on your local network. If you previously chose Don’t Allow, turn access back on in the settings above.")
            ]
        case .permissions:
            [
                .init(systemImage: "checkmark.shield.fill", title: "Accessibility", text: "Open System Settings → Privacy & Security → Accessibility, then enable Thumble Mac.")
            ]
        case .connect:
            [
                .init(systemImage: "wifi", title: "Use the same Wi-Fi network", text: "Keep Wi-Fi enabled on both devices. For nearby pairing without a router, also enable Bluetooth."),
                .init(systemImage: "qrcode.viewfinder", title: "Pair from the iPhone app", text: "Tap Scan Mac QR Code and scan the Mac’s pairing code, or choose Smart Connect. For manual pairing, enter the six-digit code shown on your Mac.")
            ]
        case .editor:
            [
                .init(systemImage: "wand.and.rulers", title: "Build on the canvas", text: "Drag controls, add joysticks and trackpads, or draw your own keys."),
                .init(systemImage: "iphone.gen3", title: "Match your iPhone", text: "Pick the connected device frame so controls land where your thumbs expect."),
                .init(systemImage: "keyboard", title: "Record shortcuts", text: "Press any Mac shortcut onto a control — it saves automatically.")
            ]
        }
    }
}

struct MacOnboardingInstruction: Identifiable, Hashable {
    let systemImage: String
    let title: String
    let text: String

    var id: String { title }
}
