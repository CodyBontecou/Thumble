import AppKit
import CoreImage

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var window: NSWindow!
    private let receiver = Receiver()
    private let label = NSTextField(labelWithString: "Starting receiver…")
    private let qr = NSImageView()
    private let code = NSTextField(wrappingLabelWithString: "")
    private var invitation = ""
    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "gamecontroller", accessibilityDescription: "Tapping Wi-Fi controller")
        let menu = NSMenu(); menu.addItem(withTitle: "Pair phone…", action: #selector(showPairing), keyEquivalent: "")
        menu.addItem(withTitle: "Disconnect and pair again", action: #selector(reset), keyEquivalent: "")
        menu.addItem(.separator()); menu.addItem(withTitle: "Quit Tapping Receiver", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }; statusItem.menu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 470), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Tapping · Pair your phone"; window.isReleasedWhenClosed = false; window.center()
        let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 14; stack.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "Your phone. Your controller."); title.font = .boldSystemFont(ofSize: 22)
        let detail = NSTextField(wrappingLabelWithString: "Connect your phone and Mac to the same Wi-Fi. In Tapping, tap Connect Mac and scan this code.")
        detail.alignment = .center
        qr.imageScaling = .scaleProportionallyUpOrDown
        qr.widthAnchor.constraint(equalToConstant: 260).isActive = true; qr.heightAnchor.constraint(equalToConstant: 260).isActive = true
        label.alignment = .center; label.font = .systemFont(ofSize: 13)
        let copy = NSButton(title: "Copy pairing link", target: self, action: #selector(copyLink))
        [title, detail, qr, label, copy].forEach { stack.addArrangedSubview($0) }
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)])
        receiver.onStatus = { [weak self] message in DispatchQueue.main.async { self?.label.stringValue = message } }
        receiver.onInvitation = { [weak self] value in DispatchQueue.main.async { self?.updateInvitation(value) } }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(reset), name: NSWorkspace.willSleepNotification, object: nil)
        do { try receiver.start() } catch { label.stringValue = "Receiver could not start: \(error)" }
        showPairing()
    }
    private func updateInvitation(_ value: String) {
        invitation = value
        guard !value.isEmpty else { qr.image = NSImage(systemSymbolName: "checkmark.shield.fill", accessibilityDescription: "Phone paired securely"); return }
        let filter = CIFilter(name: "CIQRCodeGenerator", parameters: ["inputMessage": Data(value.utf8), "inputCorrectionLevel": "M"])
        if let image = filter?.outputImage?.transformed(by: CGAffineTransform(scaleX: 6, y: 6)), let cg = CIContext().createCGImage(image, from: image.extent) { qr.image = NSImage(cgImage: cg, size: .zero) }
        // Opt-in local QA export. Contains a temporary pairing secret; never log it.
        if let path = ProcessInfo.processInfo.environment["TAPPING_INVITATION_FILE"] { FileManager.default.createFile(atPath: path, contents: Data(value.utf8), attributes: [.posixPermissions: 0o600]) }
    }
    @objc private func showPairing() { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
    @objc private func copyLink() { guard !invitation.isEmpty else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(invitation, forType: .string) }
    @objc private func reset() { receiver.resetPairing() }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { receiver.stop() }
}
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate(); app.delegate = delegate; app.setActivationPolicy(.accessory); app.run()
}
