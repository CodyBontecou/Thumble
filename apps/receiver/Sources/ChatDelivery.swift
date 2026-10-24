import AppKit
import ApplicationServices

// Keyboard events target WoW's PID, never whichever application happens to gain focus.
@MainActor
enum ChatDelivery {
    static let channels = ["say": "/s ", "party": "/p ", "raid": "/raid ", "guild": "/g ", "instance": "/i "]

    static func validate(text: String, channel: String) -> Bool {
        channels[channel] != nil && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= 240 &&
        !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }
    }
    static func send(text: String, channel: String) async -> String? {
        guard validate(text: text, channel: channel), let prefix = channels[channel] else { return "Use a single message of up to 240 UTF-8 bytes." }
        guard !Task.isCancelled else { return "Delivery cancelled." }
        guard let app = NSWorkspace.shared.frontmostApplication,
              ["com.blizzard.worldofwarcraft", "com.blizzard.worldofwarcraftclassic", "com.blizzard.worldofwarcraftclassicera"].contains(app.bundleIdentifier?.lowercased() ?? "") else {
            return "Bring World of Warcraft to the front on your Mac, then try again."
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else { return "Allow Thumble Receiver in Mac System Settings → Privacy & Security → Accessibility, then try again." }
        let pid = app.processIdentifier
        func focused() -> Bool { !Task.isCancelled && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid && !app.isTerminated }
        func key(_ code: CGKeyCode) {
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
                event?.flags = []; event?.postToPid(pid)
            }
        }
        // Clear a previous edit box, then open a fresh one. No slash command comes from the transcript.
        key(53)
        try? await Task.sleep(for: .milliseconds(80))
        guard focused() else { return "WoW lost focus. Nothing was sent; try again with WoW in front." }
        key(36)
        try? await Task.sleep(for: .milliseconds(120))
        guard focused() else { return "WoW lost focus. Nothing was sent; try again with WoW in front." }
        var chunk: [UniChar] = []
        func typeChunk() {
            guard !chunk.isEmpty else { return }
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
            event?.flags = []
            chunk.withUnsafeBufferPointer { event?.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
            event?.postToPid(pid)
            let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            up?.flags = []; up?.postToPid(pid)
            chunk.removeAll(keepingCapacity: true)
        }
        for scalar in (prefix + text).unicodeScalars {
            let units = Array(String(scalar).utf16)
            if chunk.count + units.count > 16 { typeChunk() }
            chunk += units
        }
        typeChunk()
        try? await Task.sleep(for: .milliseconds(100))
        guard focused() else { return "WoW lost focus. Your draft may be in its chat box; check it before trying again." }
        key(36)
        // This confirms local delivery only; WoW provides no server acknowledgement here.
        return nil
    }
}
