import AppKit

@MainActor final class Preview: NSObject, NSApplicationDelegate {
    var studio: WorkspaceWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        let path = ProcessInfo.processInfo.environment["THUMBLE_WORKSPACE_QA_DIR"]!
        studio = WorkspaceWindow(directory: URL(fileURLWithPath: path))
        studio.receiverState = { ["platform": "macOS · isolated native QA", "simulated": true,
            "receiver": ["running": true, "connected": false, "ready": false, "detail": "Isolated native workspace · real profile store, no input device"],
            "settings": ["syncEnabled": false, "startAtLogin": false, "wowPaths": []], "pairing": NSNull()] }
        studio.show()
    }
}
MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = Preview()
    application.delegate = delegate
    application.setActivationPolicy(.regular)
    application.run()
}
