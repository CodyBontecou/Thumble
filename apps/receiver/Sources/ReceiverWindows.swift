import AppKit
import SwiftUI

/// Reusable titled window hosting a SwiftUI view. Windows are kept, not released, on close.
@MainActor final class HostedWindow {
    let window: NSWindow
    init<Content: View>(title: String, size: NSSize, resizable: Bool = false, autosave: String, @ViewBuilder content: () -> Content) {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: true)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content())
        window.setContentSize(size)
        window.center()
        window.setFrameAutosaveName(autosave)
    }
    func show() { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
}

// MARK: Settings

enum SettingsPane: String, CaseIterable, Identifiable {
    case general = "General", phone = "Phone", wow = "World of Warcraft", advanced = "Advanced"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .phone: return "iphone"
        case .wow: return "shield.lefthalf.filled"
        case .advanced: return "slider.horizontal.3"
        }
    }
}

@MainActor final class SettingsSelection: ObservableObject { @Published var pane: SettingsPane? = .general }

struct SettingsView: View {
    @ObservedObject var model: ReceiverUIModel
    @ObservedObject var selection: SettingsSelection
    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $selection.pane) { pane in
                Label(pane.rawValue, systemImage: pane.symbol).tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 180, max: 220)
        } detail: {
            Form { detail }
                .formStyle(.grouped)
                .navigationTitle(selection.pane?.rawValue ?? "Settings")
        }
        .tint(.thumbleAccent)
        .onAppear { model.refreshLoginItem(); model.reloadLayouts() }
    }

    @ViewBuilder private var detail: some View {
        switch selection.pane ?? .general {
        case .general: general
        case .phone: phone
        case .wow: wow
        case .advanced: advanced
        }
    }

    @ViewBuilder private var general: some View {
        Section {
            if model.loginItemSupported {
                Toggle("Open at login", isOn: Binding(get: { model.opensAtLogin }, set: { model.setOpensAtLogin($0) }))
                if let error = model.loginItemError { Text(error).font(.caption).foregroundStyle(.secondary) }
            }
            LabeledContent("Controller access") {
                HStack(spacing: 6) {
                    StatusDot(color: model.controllerAccess == .ready ? .green : .orange)
                    Text(model.controllerAccessText)
                }
            }
            if model.controllerAccess == .needsPermission {
                Button("Enable controller access…") { model.enableControllerAccess() }
            }
        }
        Section {
            Button("Replay setup tour") { model.replayTour() }
        }
        Section {
            LabeledContent("Version", value: ReceiverUIModel.version)
            if ReceiverUIModel.localTesting { LabeledContent("Build", value: "Local testing · unlimited controller time") }
        }
    }

    @ViewBuilder private var phone: some View {
        Section("Paired phone") {
            LabeledContent("Status", value: phoneStatus)
            if let plan = model.planText { LabeledContent("Plan", value: plan) }
        }
        Section {
            Button("Show pairing code") { model.showCodeWhileWaiting = true; model.showPopover() }
            if model.sharing { Button("Stop ChatGPT pairing") { model.stopChatGPTPairing() } }
            else { Button("Pair through ChatGPT…") { model.pairThroughChatGPT() } }
            Button("Forget this phone…", role: .destructive) { model.confirmForgetPhone() }
                .disabled(model.receiver?.rememberedPhone != true)
        } footer: {
            Text(model.statusMessage).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var phoneStatus: String {
        guard let receiver = model.receiver else { return "Starting…" }
        if receiver.connected { return receiver.paused ? "Connected · paused" : "Connected" }
        return receiver.rememberedPhone ? "Remembered · waiting to reconnect" : "Not paired"
    }

    @ViewBuilder private var wow: some View {
        Section {
            LabeledContent("World of Warcraft folder") {
                Text(model.wowFolder).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            Button("Choose…") { model.chooseWoWFolder() }
        } footer: {
            Text("Choose World of Warcraft or the client folder containing WTF.").font(.caption).foregroundStyle(.secondary)
        }
        Section {
            Toggle("Sync ConsolePort automatically", isOn: Binding(get: { model.syncEnabled }, set: { model.setSyncEnabled($0) }))
            LabeledContent("Last sync", value: lastSync)
            LabeledContent("Status", value: model.consolePortStatus)
        } footer: {
            Text("Spell names show up on your phone after a /reload. Bindings still live in ConsolePort.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var lastSync: String {
        guard let sync = model.consolePortSync else { return "Not yet" }
        return "\(sync.character) · \(sync.exportedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    @ViewBuilder private var advanced: some View {
        Section("Network") {
            LabeledContent("Listening address", value: localIPv4() ?? ProcessInfo.processInfo.hostName)
            LabeledContent("Port", value: (model.receiver?.port ?? 0) > 0 ? String(model.receiver!.port) : "Not listening")
        }
        Section {
            Button("Open Diagnostics…") { model.openDiagnostics() }
        }
    }
}

// MARK: Layouts

struct LayoutsView: View {
    @ObservedObject var model: ReceiverUIModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(model.layouts) { layout in
                HStack(spacing: 10) {
                    Image(systemName: layout.active ? "checkmark.circle.fill" : "gamecontroller")
                        .foregroundStyle(layout.active ? Color.thumbleAccent : .secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(layout.name).font(.system(size: 13, weight: layout.active ? .semibold : .regular))
                        Text([layout.origin ?? "Built in", "rev \(layout.revision)"].joined(separator: " · "))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if layout.active { Badge(text: "Active", color: .thumbleAccent) }
                    else {
                        Button("Use on phone") { model.activate(layout) }
                            .controlSize(.small).disabled(model.layoutBusy)
                            .help("Activates this layout through the same profile store the phone uses. A connected phone switches after it acknowledges the layout.")
                    }
                }
                .padding(.vertical, 3)
            }
            Divider()
            HStack {
                Text(model.layoutError ?? "Layouts you make on your phone are saved here.")
                    .font(.system(size: 11)).foregroundStyle(model.layoutError == nil ? .secondary : Color.red)
                Spacer()
                Button("Refresh") { model.reloadLayouts() }.controlSize(.small)
            }
            .padding(10)
        }
        .frame(minWidth: 420, minHeight: 320)
        .onAppear { model.reloadLayouts() }
    }
}

// MARK: Diagnostics (read-only)

struct DiagnosticsView: View {
    @ObservedObject var model: ReceiverUIModel
    var body: some View {
        Form {
            Section("Receiver") {
                LabeledContent("Status", value: model.statusMessage)
                LabeledContent("Controller access", value: model.controllerAccessText)
                LabeledContent("Listening port", value: (model.receiver?.port ?? 0) > 0 ? String(model.receiver!.port) : "Not listening")
            }
            Section("Phone link") {
                LabeledContent("Connected", value: model.receiver?.connected == true ? "Yes" : "No")
                LabeledContent("Transport", value: model.receiver?.transport ?? "—")
                LabeledContent("Input state", value: inputState)
                LabeledContent("Last input", value: model.receiver?.lastInputAge.map { String(format: "%.0f ms ago", $0 * 1000) } ?? "—")
                LabeledContent("Input sequence", value: (model.receiver?.inputSequence ?? -1) >= 0 ? String(model.receiver!.inputSequence) : "—")
                LabeledContent("Layout activation", value: String(model.receiver?.profileRevision ?? 0))
            }
            Section("Safety timing") {
                LabeledContent("Release after silence", value: "\(Int(InputTiming.watchdogSeconds * 1000)) ms")
                LabeledContent("Input lease", value: "\(Int(InputTiming.leaseSeconds * 1000)) ms")
            }
            Section {
                LabeledContent("Latency export", value: model.receiver?.latencyExport == true ? "On (TAPPING_LATENCY_FILE)" : "Off")
                LabeledContent("Input audit", value: model.receiver?.inputAudit == true ? "On (TAPPING_INPUT_AUDIT_FILE)" : "Off")
            } header: { Text("QA exports") } footer: {
                Text("Latency percentiles are measured by the phone and written only to the opt-in QA export; this window does not estimate them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 460)
    }
    private var inputState: String {
        guard let receiver = model.receiver, receiver.connected else { return "Released" }
        if receiver.layoutPending { return "Waiting for layout acknowledgement" }
        if receiver.paused { return "Paused · controls released" }
        return receiver.playRequested ? "Live" : "Connected · not playing"
    }
}
