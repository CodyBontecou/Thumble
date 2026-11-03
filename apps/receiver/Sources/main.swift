import AppKit
import CoreImage

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var window: NSWindow!
    private let receiver = Receiver()
    private let cloudPairing = CloudPairing()
    private var shareItem: NSMenuItem!
    private var stopShareItem: NSMenuItem!
    private var syncItem: NSMenuItem!
    private var syncStatusItem: NSMenuItem!
    private let label = NSTextField(wrappingLabelWithString: "Starting receiver…")
    private let accessButton = NSButton(title: "Enable controller access…", target: nil, action: nil)
    private let retryButton = NSButton(title: "Try again", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy pairing link", target: nil, action: nil)
    private var waitingForControllerAccess = false
    private let qr = NSImageView()
    private let code = NSTextField(wrappingLabelWithString: "")
    private var invitation = ""
    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "gamecontroller", accessibilityDescription: "Thumble Wi-Fi controller")
        let menu = NSMenu();
#if THUMBLE_LOCAL_TESTING
        let testing = menu.addItem(withTitle: "Local testing · unlimited controller time", action: nil, keyEquivalent: "")
        testing.isEnabled = false
        menu.addItem(.separator())
#endif
        menu.addItem(withTitle: "Pair phone…", action: #selector(showPairing), keyEquivalent: "")
        shareItem = menu.addItem(withTitle: "Pair through ChatGPT…", action: #selector(sharePairing), keyEquivalent: "")
        stopShareItem = menu.addItem(withTitle: "Stop ChatGPT pairing", action: #selector(stopSharing), keyEquivalent: "")
        stopShareItem.isHidden = true
        menu.addItem(withTitle: "Disconnect and pair again", action: #selector(reset), keyEquivalent: "")
        menu.addItem(.separator())
        syncStatusItem = menu.addItem(withTitle: "ConsolePort: waiting for /reload", action: nil, keyEquivalent: "")
        syncItem = menu.addItem(withTitle: "Automatically sync ConsolePort", action: #selector(toggleConsolePortSync), keyEquivalent: "")
        syncItem.state = UserDefaults.standard.bool(forKey: "consolePortSyncDisabled") ? .off : .on
        menu.addItem(withTitle: "Choose WoW folder…", action: #selector(chooseWoWFolder), keyEquivalent: "")
        menu.addItem(.separator()); menu.addItem(withTitle: "Quit Thumble Receiver", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }; statusItem.menu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 470), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Thumble · Pair your phone"; window.isReleasedWhenClosed = false; window.center()
        let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 14; stack.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "Your phone. Your controller."); title.font = .boldSystemFont(ofSize: 22)
        let detail = NSTextField(wrappingLabelWithString: "Connect your phone and Mac to the same Wi-Fi. In Thumble, tap Connect Mac and scan this code.")
        detail.alignment = .center
        qr.imageScaling = .scaleProportionallyUpOrDown
        qr.widthAnchor.constraint(equalToConstant: 260).isActive = true; qr.heightAnchor.constraint(equalToConstant: 260).isActive = true
        label.alignment = .center; label.font = .systemFont(ofSize: 13)
        accessButton.target = self; accessButton.action = #selector(enableControllerAccess)
        retryButton.target = self; retryButton.action = #selector(retryControllerAccess)
        copyButton.target = self; copyButton.action = #selector(copyLink); copyButton.isEnabled = false
        accessButton.isHidden = true; retryButton.isHidden = true
        [title, detail, qr, label, accessButton, retryButton, copyButton].forEach { stack.addArrangedSubview($0) }
        label.widthAnchor.constraint(lessThanOrEqualToConstant: 372).isActive = true
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)])
        receiver.onStatus = { [weak self] message in DispatchQueue.main.async { self?.label.stringValue = message } }
        receiver.onConsolePortSyncStatus = { [weak self] message in DispatchQueue.main.async { self?.syncStatusItem.title = message } }
        receiver.onInvitation = { [weak self] value in DispatchQueue.main.async { self?.updateInvitation(value) } }
        receiver.onPairingUnavailable = { [weak self] in DispatchQueue.main.async {
            self?.invitation = ""; self?.qr.image = nil; self?.cloudPairing.receiverUnavailable()
        } }
        cloudPairing.onStatus = { [weak self] message in self?.label.stringValue = message }
        cloudPairing.onSharing = { [weak self] sharing in self?.shareItem.isHidden = sharing; self?.stopShareItem.isHidden = !sharing }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sleep), name: NSWorkspace.willSleepNotification, object: nil)
        startReceiver()
        // Agents can display the code in chat; the menu still opens this window on demand.
        if ProcessInfo.processInfo.arguments.contains("--show-pairing") { showPairing() }
    }
    private func startReceiver() {
        do {
            try receiver.start()
            waitingForControllerAccess = false
            accessButton.isHidden = true; retryButton.isHidden = true; qr.isHidden = false
        } catch ReceiverError.virtualGamepadUnavailable {
            waitingForControllerAccess = true
            qr.isHidden = true
            if !CGPreflightPostEventAccess() {
                label.stringValue = "Open controller access settings and enable Thumble Receiver so macOS can create your controller. Then return here. If it is already enabled, remove the old entry and add this app again."
                accessButton.isHidden = false
            } else {
                label.stringValue = "macOS could not create your controller. Quit other Thumble receivers and try again. If this continues, reinstall the latest receiver."
                accessButton.isHidden = true
            }
            retryButton.isHidden = false
            showPairing()
        } catch {
            if case ReceiverError.message(let message) = error { label.stringValue = message }
            else { label.stringValue = "Receiver could not start: \(error.localizedDescription)" }
            showPairing()
        }
    }
    @objc private func enableControllerAccess() {
        _ = CGRequestPostEventAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }
    @objc private func retryControllerAccess() {
        guard waitingForControllerAccess else { return }
        startReceiver()
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        if waitingForControllerAccess && CGPreflightPostEventAccess() { startReceiver() }
    }
    private func updateInvitation(_ value: String) {
        invitation = value
        copyButton.isEnabled = !value.isEmpty
        cloudPairing.updateInvitation(value)
        guard !value.isEmpty else { qr.image = NSImage(systemSymbolName: "checkmark.shield.fill", accessibilityDescription: "Phone paired securely"); return }
        let filter = CIFilter(name: "CIQRCodeGenerator", parameters: ["inputMessage": Data(value.utf8), "inputCorrectionLevel": "M"])
        if let image = filter?.outputImage?.transformed(by: CGAffineTransform(scaleX: 6, y: 6)), let cg = CIContext().createCGImage(image, from: image.extent) { qr.image = NSImage(cgImage: cg, size: .zero) }
        // Opt-in local QA export. Contains a temporary pairing secret; never log it.
        if let path = ProcessInfo.processInfo.environment["TAPPING_INVITATION_FILE"] { FileManager.default.createFile(atPath: path, contents: Data(value.utf8), attributes: [.posixPermissions: 0o600]) }
    }
    @objc private func showPairing() { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
    @objc private func sharePairing() { cloudPairing.start(window: window) }
    @objc private func stopSharing() { cloudPairing.stop() }
    @objc private func copyLink() { guard !invitation.isEmpty else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(invitation, forType: .string) }
    @objc private func reset() { receiver.resetPairing() }
    @objc private func sleep() { receiver.suspend() }
    @objc private func toggleConsolePortSync() {
        let disabled = !UserDefaults.standard.bool(forKey: "consolePortSyncDisabled")
        UserDefaults.standard.set(disabled, forKey: "consolePortSyncDisabled")
        syncItem.state = disabled ? .off : .on
    }
    @objc private func chooseWoWFolder() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.message = "Choose World of Warcraft or the client folder containing WTF. ConsolePort changes sync after /reload or logout."
        if panel.runModal() == .OK, let url = panel.url {
            UserDefaults.standard.set(url.path, forKey: "consolePortWoWFolder")
            syncStatusItem.title = "ConsolePort: reload WoW to sync"
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
