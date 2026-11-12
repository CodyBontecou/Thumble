import AppKit
import SwiftUI

/// First-run guided setup. Completion is persisted; the whole tour can be deferred.
@MainActor final class SetupTourState: ObservableObject {
    nonisolated static let completedKey = "receiverSetupTourCompleted"
    static var completed: Bool { UserDefaults.standard.bool(forKey: completedKey) }
    @Published var step = 0
    @Published var openAtLogin = false
    var onClose: () -> Void = {}
    func finish() { UserDefaults.standard.set(true, forKey: Self.completedKey); onClose() }
}

/// Three steps that each do real work. Every check mark in the sidebar comes from
/// detected state (controller access, a connected phone, the WoW folder), never a
/// self-reported checkbox.
struct SetupTourView: View {
    @ObservedObject var model: ReceiverUIModel
    @ObservedObject var tour: SetupTourState
    @State private var didPickStart = false

    private enum Step: Int, CaseIterable { case access, pair, wow }

    private var accessDone: Bool { model.controllerAccess == .ready }
    private var phoneDone: Bool { model.receiver?.connected == true }
    private var wowFound: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: model.wowFolder, isDirectory: &isDirectory) && isDirectory.boolValue
    }
    private var current: Step { Step(rawValue: min(max(tour.step, 0), 2)) ?? .access }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 210)
            Divider()
            VStack(spacing: 0) {
                ScrollView { detail.padding(.horizontal, 32).padding(.top, 36).padding(.bottom, 16) }
                    .scrollBounceBehavior(.basedOnSize)
                controls.padding(.horizontal, 24).padding(.vertical, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 680, height: 460)
        .onChange(of: accessDone) { _, ready in
            if current == .access && ready { advance(after: 0.6) }
        }
        .onChange(of: phoneDone) { _, connected in
            if current == .pair && connected { advance(after: 0.9) }
        }
        .onAppear {
            tour.openAtLogin = model.loginItemSupported ? (model.opensAtLogin || !UserDefaults.standard.bool(forKey: SetupTourState.completedKey)) : false
            model.reloadLayouts()
            guard !didPickStart else { return }
            didPickStart = true
            // Start at the first step that still needs the person.
            tour.step = !accessDone ? 0 : !phoneDone ? 1 : 2
        }
    }

    private func advance(after delay: Double) {
        let from = tour.step
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if tour.step == from { withAnimation(.easeInOut(duration: 0.25)) { tour.step = from + 1 } }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Set up Thumble").font(.system(size: 13, weight: .semibold))
                    Text("About a minute").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 48).padding(.bottom, 22)

            VStack(alignment: .leading, spacing: 4) {
                row(.access, title: "Allow controller", status: accessStatus, done: accessDone)
                row(.pair, title: "Pair your phone", status: phoneStatus, done: phoneDone)
                row(.wow, title: "World of Warcraft", status: wowStatus, done: wowFound)
            }
            Spacer()
            Text("Change any of this later from the controller icon in the menu bar.")
                .font(.system(size: 11)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 18)
        }
        .padding(.horizontal, 14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(SidebarMaterial().ignoresSafeArea())
    }

    private var accessStatus: String {
        switch model.controllerAccess {
        case .ready: return "Allowed"
        case .starting: return "Checking…"
        case .needsPermission: return "Needs your OK"
        case .unavailable, .failed: return "Needs attention"
        }
    }
    private var phoneStatus: String {
        if phoneDone { return "Connected" }
        if model.receiver?.rememberedPhone == true { return "Waiting for phone" }
        return "Not paired"
    }
    private var wowStatus: String {
        if let sync = model.consolePortSync { return "Synced · \(sync.character)" }
        return wowFound ? "Folder found" : "Folder not found"
    }

    private func row(_ step: Step, title: String, status: String, done: Bool) -> some View {
        let selected = step == current
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { tour.step = step.rawValue }
        } label: {
            HStack(spacing: 10) {
                StepMark(number: step.rawValue + 1, done: done, selected: selected)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular)).foregroundStyle(.primary)
                    Text(status).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.primary.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(status)\(selected ? ", current step" : "")")
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        switch current {
        case .access: accessDetail
        case .pair: pairDetail
        case .wow: wowDetail
        }
    }

    private var accessDetail: some View {
        VStack(alignment: .leading, spacing: 18) {
            Header(eyebrow: "Step 1 of 3", title: accessDone ? "Thumble can be a controller" : "Let Thumble act as a game controller",
                   text: accessDone
                       ? "macOS allowed Thumble to create its controller. Games will see it as an Xbox controller."
                       : "Your phone becomes an Xbox controller that games already understand. macOS asks you to allow that once.")
            if accessDone {
                Confirmation(text: "Controller access is on")
            } else if model.controllerAccess == .starting {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking with macOS…").foregroundStyle(.secondary) }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Instruction(n: 1, text: "Click **Open System Settings**.")
                    Instruction(n: 2, text: "Turn on **Thumble Receiver** in the list.")
                    Instruction(n: 3, text: "Come back here. This step finishes by itself.")
                }
                HStack(spacing: 10) {
                    Button("Open System Settings") { model.enableControllerAccess() }
                        .buttonStyle(StepButton(prominent: true))
                    Button("Check again") { model.retryControllerAccess() }.buttonStyle(QuietButton(large: true))
                }
                if model.controllerAccess != .needsPermission {
                    Text(model.statusMessage).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pairDetail: some View {
        VStack(alignment: .leading, spacing: 18) {
            Header(eyebrow: "Step 2 of 3", title: phoneDone ? "Your phone is connected" : "Scan with your phone",
                   text: phoneDone
                       ? "It will reconnect by itself whenever both are on the same Wi-Fi."
                       : "Keep your phone on the same Wi-Fi as this Mac. Everything stays on your network.")
            if phoneDone {
                Confirmation(text: "Phone connected")
            } else if !accessDone && model.controllerAccess != .starting {
                // The receiver only listens once macOS allows the controller, so no code exists yet.
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your pairing code appears once controller access is allowed.").font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                        Button("Go to step 1") { withAnimation(.easeInOut(duration: 0.2)) { tour.step = 0 } }.buttonStyle(QuietButton())
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
            } else {
                HStack(alignment: .top, spacing: 22) {
                    PairingQR(model: model, size: 170).frame(width: 190).tint(Color.secondary)
                    VStack(alignment: .leading, spacing: 10) {
                        Instruction(n: 1, text: "Open **Thumble** on your phone.")
                        Instruction(n: 2, text: "Tap **Connect Mac**.")
                        Instruction(n: 3, text: "Point the camera at this code.")
                    }
                    .padding(.top, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var wowDetail: some View {
        VStack(alignment: .leading, spacing: 18) {
            Header(eyebrow: "Step 3 of 3", title: "Show your spells on your phone",
                   text: "With ConsolePort, Thumble reads your bindings so each button shows the spell it casts. Type /reload in game after setup. WoW: Forever has built-in gamepad support, so you can skip this step.")
            VStack(spacing: 0) {
                SettingRow(title: "WoW folder", detail: model.wowFolder, ok: wowFound) {
                    Button(wowFound ? "Change…" : "Choose…") { model.chooseWoWFolder() }.buttonStyle(QuietButton())
                }
                Divider().padding(.leading, 12)
                SettingRow(title: "Sync ConsolePort", detail: model.consolePortSync.map { "Last synced from \($0.character)" } ?? "Updates when you /reload", ok: nil) {
                    Toggle("", isOn: Binding(get: { model.syncEnabled }, set: { model.setSyncEnabled($0) }))
                        .toggleStyle(.switch).labelsHidden().controlSize(.small).tint(Color.thumbleAccent)
                }
                if model.loginItemSupported {
                    Divider().padding(.leading, 12)
                    SettingRow(title: "Open at login", detail: "So your phone can always find this Mac", ok: nil) {
                        Toggle("", isOn: $tour.openAtLogin).toggleStyle(.switch).labelsHidden().controlSize(.small).tint(Color.thumbleAccent)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
            Text("Not playing WoW? Leave this as is. Thumble works with any game that supports controllers.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 10) {
            Button("Set up later") { tour.finish() }.buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(.secondary)
            Spacer()
            if current != .access {
                Button("Back") { withAnimation(.easeInOut(duration: 0.2)) { tour.step -= 1 } }.buttonStyle(QuietButton(large: true))
            }
            switch current {
            case .access:
                Button(accessDone ? "Continue" : "Skip for now") { withAnimation(.easeInOut(duration: 0.2)) { tour.step = 1 } }
                    .buttonStyle(StepButton(prominent: accessDone)).keyboardShortcut(accessDone ? .defaultAction : nil)
            case .pair:
                Button(phoneDone ? "Continue" : "Skip for now") { withAnimation(.easeInOut(duration: 0.2)) { tour.step = 2 } }
                    .buttonStyle(StepButton(prominent: phoneDone)).keyboardShortcut(phoneDone ? .defaultAction : nil)
            case .wow:
                Button("Done") {
                    if model.loginItemSupported && tour.openAtLogin != model.opensAtLogin { model.setOpensAtLogin(tour.openAtLogin) }
                    tour.finish()
                    // Point at where Thumble lives from now on.
                    model.showPopover()
                }
                .buttonStyle(StepButton(prominent: true)).keyboardShortcut(.defaultAction)
            }
        }
    }
}

// MARK: Pieces

private struct StepMark: View {
    let number: Int
    let done: Bool
    let selected: Bool
    var body: some View {
        ZStack {
            if done {
                Circle().fill(Color.thumbleAccent)
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
            } else {
                Circle().strokeBorder(selected ? Color.thumbleAccent : Color.secondary.opacity(0.5), lineWidth: 1.5)
                Text("\(number)").font(.system(size: 11, weight: .semibold)).foregroundStyle(selected ? Color.thumbleAccent : .secondary)
            }
        }
        .frame(width: 22, height: 22)
        .animation(.easeInOut(duration: 0.25), value: done)
    }
}

private struct Header: View {
    let eyebrow: String
    let title: String
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(eyebrow.uppercased()).font(.system(size: 10, weight: .semibold)).kerning(0.6).foregroundStyle(.secondary)
            Text(title).font(.system(size: 22, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            Text(text).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct Instruction: View {
    let n: Int
    let text: LocalizedStringKey
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 18, height: 18).background(Circle().fill(Color.primary.opacity(0.08)))
            Text(text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct Confirmation: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.system(size: 13, weight: .medium)).foregroundStyle(Color.thumbleAccent)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.thumbleAccent.opacity(0.14)))
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }
}

private struct SettingRow<Accessory: View>: View {
    let title: String
    let detail: String
    let ok: Bool?
    @ViewBuilder var accessory: Accessory
    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(title).font(.system(size: 13))
                    if let ok {
                        Image(systemName: ok ? "checkmark.circle.fill" : "questionmark.circle")
                            .font(.system(size: 11)).foregroundStyle(ok ? Color.thumbleAccent : Color.secondary)
                            .accessibilityLabel(ok ? "Found" : "Not found")
                    }
                }
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            accessory
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }
}

/// One accent (Thumble blue) for the single primary action; every other button is neutral.
private struct StepButton: ButtonStyle {
    var prominent: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: prominent ? .semibold : .regular))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, 16).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 7).fill(prominent ? Color.thumbleAccent : Color.primary.opacity(0.1)))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

private struct QuietButton: ButtonStyle {
    var large = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 13 : 12))
            .foregroundStyle(Color.primary)
            .padding(.horizontal, large ? 16 : 10).frame(height: large ? 30 : 24)
            .background(RoundedRectangle(cornerRadius: large ? 7 : 6).fill(Color.primary.opacity(configuration.isPressed ? 0.16 : 0.1)))
    }
}

private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
