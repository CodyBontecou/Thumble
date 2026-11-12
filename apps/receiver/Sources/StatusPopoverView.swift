import AppKit
import SwiftUI

extension Color {
    static let thumbleAccent = Color(red: 10 / 255, green: 100 / 255, blue: 216 / 255)
}

struct StatusDot: View {
    let color: Color
    var body: some View { Circle().fill(color).frame(width: 8, height: 8) }
}

/// One labelled status line with a colored state dot.
struct StatusRow: View {
    let title: String
    let value: String
    var color: Color = .secondary
    var body: some View {
        HStack(spacing: 8) {
            StatusDot(color: color)
            Text(title)
            Spacer(minLength: 8)
            Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing).lineLimit(2)
        }
        .font(.system(size: 12))
    }
}

struct Badge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.16)))
            .foregroundStyle(color)
    }
}

/// Menu-style footer row with hover highlight, matching NSMenu metrics.
struct MenuRow: View {
    let title: String
    var shortcut: String?
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let shortcut { Text(shortcut).foregroundStyle(hovering ? Color.white.opacity(0.8) : .secondary) }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .foregroundStyle(hovering ? Color.white : Color.primary)
            .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Color.thumbleAccent : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .quaternaryLabelColor).opacity(0.35)))
    }
}

struct PairingQR: View {
    @ObservedObject var model: ReceiverUIModel
    var size: CGFloat = 200
    var body: some View {
        VStack(spacing: 8) {
            Group {
                if let image = model.qrImage {
                    Image(nsImage: image).interpolation(.none).resizable().scaledToFit()
                        .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
                } else {
                    RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .quaternaryLabelColor).opacity(0.4))
                        .overlay(ProgressView().controlSize(.small))
                }
            }
            .frame(width: size, height: size)
            .accessibilityLabel("Pairing QR code")
            if let expiry = model.expiryText {
                Text("Same Wi-Fi · encrypted · new code in \(expiry)").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack {
                Button("Copy pairing link") { model.copyLink() }.disabled(model.invitation.isEmpty)
                Button("New code") { model.newCode() }.disabled(model.receiver?.port ?? 0 == 0)
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
    }
}

struct StatusPopoverView: View {
    @ObservedObject var model: ReceiverUIModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            content
            if model.statusMessage.isEmpty == false && model.phase != .accessNeeded && model.phase != .unavailable {
                Text(model.statusMessage).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "gamecontroller.fill").foregroundStyle(Color.thumbleAccent)
            Text("Thumble Receiver").font(.system(size: 13, weight: .semibold))
            Spacer()
            if ReceiverUIModel.localTesting { Badge(text: "Local testing", color: .purple) }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .accessNeeded: accessNeeded
        case .unavailable: unavailable
        case .starting:
            HStack { ProgressView().controlSize(.small); Text("Starting receiver…").foregroundStyle(.secondary) }
        case .readyToPair: readyToPair
        case .waiting: waiting
        case .connected: connected
        case .freeTimeEnded: freeTimeEnded
        }
    }

    private var accessNeeded: some View {
        VStack(alignment: .leading, spacing: 12) {
            Card {
                Text("Allow controller access").font(.system(size: 14, weight: .semibold))
                Text("macOS needs your permission before Thumble can create a game controller. Enable Thumble Receiver, then come back here.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Enable controller access…") { model.enableControllerAccess() }
                        .buttonStyle(.borderedProminent).tint(.thumbleAccent)
                    Button("Try again") { model.retryControllerAccess() }
                }
                Text("Already enabled? Remove the old entry and add this app again.").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            VStack(spacing: 6) {
                StatusRow(title: "Controller access", value: "Waiting", color: .orange)
                StatusRow(title: "Phone paired", value: "Next", color: .secondary)
                StatusRow(title: "WoW folder", value: "Optional", color: .secondary)
            }
        }
    }

    private var unavailable: some View {
        Card {
            Text(model.controllerAccess == .unavailable ? "Controller unavailable" : "Receiver could not start").font(.system(size: 14, weight: .semibold))
            Text(model.statusMessage).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.controllerAccess == .unavailable { Button("Try again") { model.retryControllerAccess() } }
        }
    }

    private var readyToPair: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Scan with Thumble on your phone").font(.system(size: 14, weight: .semibold))
            Text("In Thumble, tap Connect Mac and scan this code.").font(.system(size: 12)).foregroundStyle(.secondary)
            PairingQR(model: model)
            VStack(spacing: 6) {
                StatusRow(title: "Controller access", value: "Ready", color: .green)
                StatusRow(title: "Phone paired", value: "Waiting for scan", color: .orange)
            }
        }
    }

    private var waiting: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Your phone").font(.system(size: 14, weight: .semibold))
                Spacer()
                Badge(text: "Waiting", color: .orange)
            }
            VStack(spacing: 6) {
                StatusRow(title: "Gamepad", value: "Neutral, nothing held", color: .green)
                StatusRow(title: "Phone", value: "Remembered, auto-reconnect", color: .orange)
            }
            if model.showCodeWhileWaiting { PairingQR(model: model, size: 170) }
            HStack {
                Button(model.showCodeWhileWaiting ? "Hide pairing code" : "Show pairing code") { model.showCodeWhileWaiting.toggle() }
                Button("Forget this phone…") { model.confirmForgetPhone() }
            }
            .controlSize(.small)
        }
    }

    private var connected: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Your phone").font(.system(size: 14, weight: .semibold))
                Spacer()
                if model.receiver?.layoutPending == true { Badge(text: "Sending layout", color: .orange) }
                else if model.receiver?.paused == true { Badge(text: "Paused", color: .orange) }
                else { Badge(text: "Connected", color: .green) }
            }
            VStack(spacing: 6) {
                if let transport = model.receiver?.transport { StatusRow(title: "Connection", value: transport, color: .green) }
                StatusRow(title: "Layout", value: layoutText, color: model.activeLayout == nil ? .secondary : .green)
                StatusRow(title: "Spell labels", value: spellLabelText, color: model.consolePortSync == nil ? .secondary : .green)
                if let free = model.freeTimeText { StatusRow(title: "Plan", value: free, color: model.receiver?.pro == true || ReceiverUIModel.localTesting ? .green : .orange) }
                if let error = model.receiver?.accessError, !error.isEmpty { StatusRow(title: "Purchase", value: error, color: .red) }
            }
            Toggle("Sync ConsolePort automatically", isOn: Binding(get: { model.syncEnabled }, set: { model.setSyncEnabled($0) }))
                .toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
        }
    }

    private var freeTimeEnded: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Free time ended").font(.system(size: 14, weight: .semibold))
                Spacer()
                Badge(text: "Released", color: .orange)
            }
            Card {
                Text("All buttons were released and the controller is idle. Your phone stays paired.")
                    .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                Text("Plans are bought in Thumble on your phone. After you buy or restore, tap Resume there.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            StatusRow(title: "Gamepad", value: "Neutral, nothing held", color: .green)
        }
    }

    private var layoutText: String {
        guard let layout = model.activeLayout else { return model.activationRevision == 0 ? "Phone default" : "Custom" }
        return layout.revision > 1 ? "\(layout.name) · rev \(layout.revision)" : layout.name
    }
    private var spellLabelText: String {
        if !model.syncEnabled { return "Sync off" }
        guard let sync = model.consolePortSync else { return "Waiting for /reload" }
        return "\(sync.character) · \(sync.exportedAt.formatted(.relative(presentation: .named)))"
    }

    private var footer: some View {
        VStack(spacing: 0) {
            MenuRow(title: "Layouts…") { model.openLayouts() }
            MenuRow(title: "Diagnostics…") { model.openDiagnostics() }
            MenuRow(title: "Settings…", shortcut: "⌘,") { model.openSettings() }
            Divider().padding(.vertical, 4)
            if model.sharing { MenuRow(title: "Stop ChatGPT pairing") { model.stopChatGPTPairing() } }
            else { MenuRow(title: "Pair through ChatGPT…") { model.pairThroughChatGPT() } }
            MenuRow(title: "Disconnect and pair again") { model.forgetPhone() }
            Divider().padding(.vertical, 4)
            MenuRow(title: "Quit Thumble Receiver", shortcut: "⌘Q") { model.quit() }
        }
    }
}
