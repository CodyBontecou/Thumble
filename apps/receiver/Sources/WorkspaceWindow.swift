import AppKit
import WebKit
import ServiceManagement

/// One locally bundled UI; the bridge never loads a remote page with authority.
@MainActor final class WorkspaceWindow: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private(set) var window: NSWindow!
    private var web: WKWebView!
    private var entry: URL!
    private let io = DispatchQueue(label: "thumble.workspace.storage", qos: .utility)
    let directory: URL
    var receiverState: () -> [String: Any] = { [:] }
    var action: (String, [String: Any]) throws -> Void = { _, _ in }
    init(directory: URL) {
        self.directory = directory
        super.init()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(self, name: "workspace")
        web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.isInspectable = ProcessInfo.processInfo.environment["THUMBLE_WORKSPACE_INSPECT"] == "1"
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1360, height: 860), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Thumble Studio"; window.minSize = NSSize(width: 960, height: 650)
        window.contentView = web; window.center(); window.isReleasedWhenClosed = false
        entry = Bundle.main.resourceURL?.appendingPathComponent("Workspace/index.html")
        if let entry, FileManager.default.fileExists(atPath: entry.path) {
            web.loadFileURL(entry, allowingReadAccessTo: entry.deletingLastPathComponent())
        } else {
            let error = NSTextField(wrappingLabelWithString: "Desktop workspace assets are missing. Reinstall Thumble Receiver.")
            error.frame = NSRect(x: 28, y: 28, width: 600, height: 70); window.contentView = error
        }
    }
    func show() { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.standardizedFileURL == entry?.standardizedFileURL && navigationAction.targetFrame != nil ? .allow : .cancel)
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, web.url?.standardizedFileURL == entry?.standardizedFileURL,
              let value = message.body as? [String: Any], let id = value["id"] as? String, id.utf8.count <= 80,
              let operation = value["operation"] as? String, let payload = value["payload"] as? [String: Any],
              let bytes = try? JSONSerialization.data(withJSONObject: value), bytes.count <= 100000 else { return }
        var extra = receiverState()
        do {
            switch operation {
            case "snapshot", "save", "activate", "delete": break
            case "export":
                guard let profile = payload["profile"] as? [String: Any] else { throw ProfileCatalog.Failure.invalid }
                try CloudProfile.validate(profile)
                let panel = NSSavePanel(); panel.nameFieldStringValue = "controller.json"; panel.canCreateDirectories = true
                if panel.runModal() == .OK, let url = panel.url { try JSONSerialization.data(withJSONObject: profile, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic) }
            case "settings":
                guard Set(payload.keys).isSubset(of: ["syncEnabled", "startAtLogin"]), payload.values.allSatisfy({ CloudProfile.boolean($0) }) else { throw ProfileCatalog.Failure.invalid }
                if let enabled = payload["syncEnabled"] as? Bool { UserDefaults.standard.set(!enabled, forKey: "consolePortSyncDisabled") }
                if let enabled = payload["startAtLogin"] as? Bool {
                    if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                }
                extra = receiverState()
            case "disconnect", "forget", "retry", "setup-driver", "copy-pairing", "choose-wow-folder":
                try action(operation, payload); extra = receiverState()
            default: throw ProfileCatalog.Failure.invalid
            }
        } catch { reply(id, result: nil, error: error.localizedDescription); return }
        let directory = self.directory
        io.async { [weak self] in
            do {
                switch operation {
                case "save":
                    guard let profile = payload["profile"] as? [String: Any], let expected = ProfileCatalog.revision(payload["expectedProfileRevision"]), let viewport = payload["viewport"] as? [String: Any] else { throw ProfileCatalog.Failure.invalid }
                    try WorkspaceProfiles.save(directory, profile: profile, expected: expected, viewport: viewport)
                case "delete":
                    guard let profileID = payload["profileId"] as? String, let expected = ProfileCatalog.revision(payload["expectedProfileRevision"]), let activation = ProfileCatalog.revision(payload["expectedActivationRevision"]) else { throw ProfileCatalog.Failure.invalid }
                    try WorkspaceProfiles.remove(directory, id: profileID, expected: expected, activation: activation)
                case "activate":
                    guard let profileID = payload["profileId"] as? String, let revision = ProfileCatalog.revision(payload["profileRevision"]), let activation = ProfileCatalog.revision(payload["expectedActivationRevision"]), let viewport = payload["viewport"] as? [String: Any],
                          let entries = try ProfileCatalog.read(directory)["profiles"] as? [[String: Any]], let found = entries.first(where: { ($0["profile"] as? [String: Any])?["id"] as? String == profileID }), let profile = found["profile"] as? [String: Any] else { throw ProfileCatalog.Failure.invalid }
                    try WorkspaceProfiles.validateLayout(profile, viewport: viewport)
                    _ = try ProfileCatalog.activate(directory, id: profileID, profileRevision: revision, expectedActivationRevision: activation)
                default: break
                }
                var result = try WorkspaceProfiles.snapshot(directory)
                for (key, value) in extra { result[key] = value }
                // Only the fresh file emitted by the input queue can establish
                // layout acknowledgement; a write to disk cannot imply delivery.
                let statusFile = directory.appendingPathComponent("receiver-status.json")
                if let data = try? Data(contentsOf: statusFile), data.count <= 16384,
                   let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let at = status["updatedAt"] as? Double, (0..<5000).contains(Date().timeIntervalSince1970*1000-at),
                   (result["receiver"] as? [String: Any])?["running"] as? Bool == true {
                    var receiver = result["receiver"] as? [String: Any] ?? [:]
                    for key in ["connected", "ready", "layoutAcknowledged", "revision", "running"] { receiver[key] = status[key] }
                    if ProfileCatalog.revision(status["revision"]) != ProfileCatalog.revision(result["activationRevision"]) { receiver["ready"] = false; receiver["layoutAcknowledged"] = false }
                    result["receiver"] = receiver
                }
                DispatchQueue.main.async { self?.reply(id, result: result, error: nil) }
            } catch { DispatchQueue.main.async { self?.reply(id, result: nil, error: error.localizedDescription) } }
        }
    }
    private func reply(_ id: String, result: [String: Any]?, error: String?) {
        let value: [String: Any] = ["id": id, "result": result as Any? ?? NSNull(), "error": error as Any? ?? NSNull()]
        web.callAsyncJavaScript("window.thumbleResponse(reply)", arguments: ["reply": value], in: nil, in: .page, completionHandler: nil)
    }
}
