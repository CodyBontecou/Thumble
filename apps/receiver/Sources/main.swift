import AppKit
import Combine
import SwiftUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let statusDot = NSView()
    private let popover = NSPopover()
    private let receiver = Receiver()
    private let cloudPairing = CloudPairing()
    private let model = ReceiverUIModel()
    private let settingsSelection = SettingsSelection()
    private var waitingForControllerAccess = false
    private var ticker: Timer?
    private var ticks = 0
    private var observation: AnyCancellable?
    private lazy var settings = HostedWindow(title: "Thumble Settings", size: NSSize(width: 640, height: 440), resizable: true, autosave: "ThumbleSettings") {
        SettingsView(model: model, selection: settingsSelection)
    }
    private lazy var layouts = HostedWindow(title: "Layouts", size: NSSize(width: 460, height: 400), resizable: true, autosave: "ThumbleLayouts") {
        LayoutsView(model: model)
    }
    private lazy var diagnostics = HostedWindow(title: "Diagnostics", size: NSSize(width: 460, height: 560), resizable: true, autosave: "ThumbleDiagnostics") {
        DiagnosticsView(model: model)
    }
    private var tour: NSPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "gamecontroller", accessibilityDescription: "Thumble Wi-Fi controller")
            image?.isTemplate = true
            button.image = image
            button.target = self; button.action = #selector(togglePopover)
            statusDot.wantsLayer = true
            statusDot.layer?.cornerRadius = 3.5
            statusDot.isHidden = true
            statusDot.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(statusDot)
            NSLayoutConstraint.activate([statusDot.widthAnchor.constraint(equalToConstant: 7), statusDot.heightAnchor.constraint(equalToConstant: 7),
                                         statusDot.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -2),
                                         statusDot.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -3)])
        }
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: StatusPopoverView(model: model))
        wireModel()
        receiver.onStatus = { [weak self] message in DispatchQueue.main.async { self?.model.statusMessage = message; self?.refresh() } }
        receiver.onConsolePortSyncStatus = { [weak self] message in DispatchQueue.main.async { self?.model.consolePortStatus = message; self?.model.reloadLayouts() } }
        receiver.onInvitation = { [weak self] value in DispatchQueue.main.async { self?.updateInvitation(value) } }
        receiver.onPairingUnavailable = { [weak self] in DispatchQueue.main.async {
            self?.model.clearInvitation(); self?.cloudPairing.receiverUnavailable()
        } }
        cloudPairing.onStatus = { [weak self] message in self?.model.statusMessage = message }
        cloudPairing.onSharing = { [weak self] sharing in self?.model.sharing = sharing }
        observation = model.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.updateStatusDot(); self?.reanchorPopover() } }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sleep), name: NSWorkspace.willSleepNotification, object: nil)
        startReceiver()
        let ticker = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(ticker, forMode: .common); self.ticker = ticker
        model.reloadLayouts(); refresh()
        if !SetupTourState.completed { showTour() }
        // Agents can display the code in chat; the menu bar still opens the popover on demand.
        else if ProcessInfo.processInfo.arguments.contains("--show-pairing") || waitingForControllerAccess { showPopoverSoon() }
    }

    private func wireModel() {
        model.enableControllerAccess = { [weak self] in self?.enableControllerAccess() }
        model.retryControllerAccess = { [weak self] in self?.retryControllerAccess() }
        model.newCode = { [weak self] in self?.receiver.refreshInvitation() }
        model.forgetPhone = { [weak self] in self?.reset() }
        model.confirmForgetPhone = { [weak self] in self?.confirmForget() }
        model.pairThroughChatGPT = { [weak self] in self?.sharePairing() }
        model.stopChatGPTPairing = { [weak self] in self?.stopSharing() }
        model.chooseWoWFolder = { [weak self] in self?.chooseWoWFolder() }
        model.openLayouts = { [weak self] in self?.popover.performClose(nil); self?.model.reloadLayouts(); self?.layouts.show() }
        model.openDiagnostics = { [weak self] in self?.popover.performClose(nil); self?.diagnostics.show() }
        model.openSettings = { [weak self] in self?.openSettings(nil) }
        model.replayTour = { [weak self] in self?.showTour() }
        model.showPopover = { [weak self] in self?.showPopover() }
        model.quit = { [weak self] in self?.quit() }
    }

    private func installMainMenu() {
        // Accessory apps show no menu bar, but key equivalents still route through the main menu.
        let main = NSMenu(), appItem = NSMenuItem(), app = NSMenu()
        app.addItem(withTitle: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        app.addItem(withTitle: "Quit Thumble Receiver", action: #selector(quit), keyEquivalent: "q").target = self
        appItem.submenu = app; main.addItem(appItem)
        let editItem = NSMenuItem(), edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit; main.addItem(editItem)
        NSApp.mainMenu = main
    }

    private func tick() {
        ticks += 1
        model.now = Date()
        refresh()
        if ticks % 5 == 0 { model.reloadLayouts() }
    }
    private func refresh() {
        receiver.snapshot { [weak self] snapshot in
            guard let self else { return }
            let wasConnected = self.model.receiver?.connected ?? false
            self.model.receiver = snapshot
            if snapshot.connected { self.model.showCodeWhileWaiting = false }
            if wasConnected != snapshot.connected { self.model.reloadLayouts() }
        }
    }
    private func updateStatusDot() {
        guard let color = model.statusDot else { statusDot.isHidden = true; return }
        statusDot.layer?.backgroundColor = color.cgColor
        statusDot.isHidden = false
    }

    // MARK: Popover and windows
    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil) } else { showPopover() }
    }
    private func showPopover() {
        guard let button = statusItem.button, button.window != nil else { openSettings(nil); return }
        refresh(); model.reloadLayouts()
        NSApp.activate(ignoringOtherApps: true)
        // Size the popover to the current content before showing it; otherwise it opens at
        // its last size and SwiftUI grows it upward past the menu bar.
        if let view = popover.contentViewController?.view {
            view.layoutSubtreeIfNeeded()
            let height = view.fittingSize.height
            if height > 0 { popover.contentSize = NSSize(width: popover.contentSize.width, height: height) }
            lastPopoverHeight = height
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        // refresh()/reloadLayouts() can land a frame later; re-check once the content settles.
        for delay in [0.05, 0.3] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.reanchorPopover() } }
    }
    /// AppKit grows a shown popover upward from its bottom edge, which pushes the
    /// header past the menu bar when a state change adds rows. Re-anchor it under the icon.
    private var lastPopoverHeight: CGFloat = 0
    private func reanchorPopover() {
        guard popover.isShown, let button = statusItem.button, let view = popover.contentViewController?.view else { return }
        let height = view.fittingSize.height
        let barBottom = button.window?.frame.minY ?? .greatestFiniteMagnitude
        let poking = (view.window?.frame.maxY ?? 0) > barBottom + 1
        guard poking || abs(height - lastPopoverHeight) > 0.5 else { return }
        lastPopoverHeight = height
        popover.contentSize = NSSize(width: popover.contentSize.width, height: height)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
    private func showPopoverSoon() {
        // The status item is laid out on the next run-loop pass.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.showPopover() }
    }
    func popoverDidClose(_ notification: Notification) { model.showCodeWhileWaiting = false }
    @objc private func openSettings(_ sender: Any?) {
        popover.performClose(nil)
        settings.show()
    }
    private func showTour() {
        popover.performClose(nil)
        if let tour { NSApp.activate(ignoringOtherApps: true); tour.makeKeyAndOrderFront(nil); return }
        let state = SetupTourState()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 460), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "Set up Thumble"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: SetupTourView(model: model, tour: state))
        panel.center()
        state.onClose = { [weak self, weak panel] in panel?.close(); self?.tour = nil }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in
            // Closing the window counts as skipping; it can be replayed from Settings.
            UserDefaults.standard.set(true, forKey: SetupTourState.completedKey)
            MainActor.assumeIsolated { self?.tour = nil }
        }
        tour = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: Receiver lifecycle (unchanged behavior)
    private func startReceiver() {
        do {
            try receiver.start()
            waitingForControllerAccess = false
            model.controllerAccess = .ready
        } catch ReceiverError.virtualGamepadUnavailable {
            waitingForControllerAccess = true
            if !CGPreflightPostEventAccess() {
                model.statusMessage = "Open controller access settings and enable Thumble Receiver so macOS can create your controller. Then return here. If it is already enabled, remove the old entry and add this app again."
                model.controllerAccess = .needsPermission
            } else {
                model.statusMessage = "macOS could not create your controller. Quit other Thumble receivers and try again. If this continues, reinstall the latest receiver."
                model.controllerAccess = .unavailable
            }
        } catch {
            if case ReceiverError.message(let message) = error { model.statusMessage = message }
            else { model.statusMessage = "Receiver could not start: \(error.localizedDescription)" }
            model.controllerAccess = .failed(model.statusMessage)
            showPopoverSoon()
        }
    }
    private func enableControllerAccess() {
        _ = CGRequestPostEventAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }
    private func retryControllerAccess() {
        guard waitingForControllerAccess else { return }
        startReceiver()
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        if waitingForControllerAccess && CGPreflightPostEventAccess() { startReceiver() }
        model.refreshLoginItem()
    }
    private func updateInvitation(_ value: String) {
        model.setInvitation(value)
        cloudPairing.updateInvitation(value)
        refresh()
        // Opt-in local QA export. Contains a temporary pairing secret; never log it.
        if !value.isEmpty, let path = ProcessInfo.processInfo.environment["TAPPING_INVITATION_FILE"] { FileManager.default.createFile(atPath: path, contents: Data(value.utf8), attributes: [.posixPermissions: 0o600]) }
    }
    private func sharePairing() {
        // The settings window anchors the sign-in sheet and shows sharing status.
        popover.performClose(nil)
        settingsSelection.pane = .phone
        settings.show()
        cloudPairing.start(window: settings.window)
    }
    private func stopSharing() { cloudPairing.stop() }
    private func reset() { receiver.resetPairing(); refresh() }
    private func confirmForget() {
        popover.performClose(nil)
        let alert = NSAlert()
        alert.messageText = "Forget this phone?"
        alert.informativeText = "The phone will stop reconnecting automatically. Scan a new pairing code to connect again."
        alert.addButton(withTitle: "Forget Phone"); alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { reset() }
    }
    @objc private func sleep() { receiver.suspend() }
    private func chooseWoWFolder() {
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.message = "Choose World of Warcraft or the client folder containing WTF. ConsolePort changes sync after /reload or logout."
        if panel.runModal() == .OK, let url = panel.url {
            UserDefaults.standard.set(url.path, forKey: "consolePortWoWFolder")
            model.wowFolderChanged()
            model.consolePortStatus = "ConsolePort: reload WoW to sync"
        }
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { cloudPairing.stop(); receiver.stop() }
}
// Exercise the real signed HID backend without opening a listener or reading user data.
if ProcessInfo.processInfo.arguments.contains("--self-test-hid") {
    guard let device = tapping_gamepad_create() else {
        fputs("HID self-test failed: the signed app could not create its virtual gamepad.\n", stderr)
        exit(1)
    }
    var report = [UInt8](repeating: 0, count: 20)
    report[1] = 20
    let result = report.withUnsafeBufferPointer { tapping_gamepad_send(device, $0.baseAddress!) }
    tapping_gamepad_destroy(device)
    guard result == 0 else {
        fputs("HID self-test failed: neutral report returned \(result).\n", stderr)
        exit(1)
    }
    print("HID self-test passed: virtual gamepad created and neutral report accepted.")
    exit(0)
}
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate(); app.delegate = delegate; app.setActivationPolicy(.accessory); app.run()
}
