// A focused AppKit responder: evidence of application delivery, without a global key logger.
import AppKit

@MainActor final class ProbeView: NSView {
    let logURL: URL
    var held = Set<UInt16>()
    let label = NSTextField(labelWithString: "Ready for Android keyboard input")
    init(logURL: URL) {
        self.logURL = logURL
        super.init(frame: NSRect(x: 0, y: 0, width: 620, height: 260))
        label.frame = NSRect(x: 28, y: 80, width: 560, height: 120)
        label.font = .systemFont(ofSize: 24)
        label.maximumNumberOfLines = 4
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    override var acceptsFirstResponder: Bool { true }
    func record(_ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value),
              let handle = try? FileHandle(forWritingTo: logURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data + Data([10]))
    }
    override func keyDown(with event: NSEvent) {
        held.insert(event.keyCode)
        record(["kind": "down", "keyCode": event.keyCode, "characters": event.charactersIgnoringModifiers ?? "", "held": held.sorted(), "repeat": event.isARepeat])
        label.stringValue = "Received: \(event.charactersIgnoringModifiers ?? "")\nHeld key codes: \(held.sorted())"
    }
    override func keyUp(with event: NSEvent) {
        held.remove(event.keyCode)
        record(["kind": "up", "keyCode": event.keyCode, "held": held.sorted()])
        label.stringValue = "Key released\nHeld key codes: \(held.sorted())"
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool { keyDown(with: event); return true }
}
@main struct KeyboardProbe {
    @MainActor static func main() {
let logURL = URL(fileURLWithPath: CommandLine.arguments[1])
FileManager.default.createFile(atPath: logURL.path, contents: Data())
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let view = ProbeView(logURL: logURL)
let window = NSWindow(contentRect: view.bounds, styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.title = "Thumble Android Keyboard Test"
window.contentView = view
window.center()
window.makeKeyAndOrderFront(nil)
window.makeFirstResponder(view)
app.activate(ignoringOtherApps: true)
_ = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
    MainActor.assumeIsolated {
        let focused = window.isKeyWindow && NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        view.record(["kind": "focus", "focused": focused])
    }
}
app.run()

    }
}
