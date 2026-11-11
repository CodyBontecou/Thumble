import AppKit
import CoreImage
import ApplicationServices
import Foundation
struct IsolatedReceiverSecrets: ReceiverSecretStore {
    let directory: URL
    init() {
        directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TAPPING_PROFILE_DIR"]!).appendingPathComponent("test-secrets")
    }
    func load(_ account: String) throws -> Data? {
        let path = directory.appendingPathComponent(account)
        return FileManager.default.fileExists(atPath: path.path) ? try Data(contentsOf: path) : nil
    }
    func save(_ data: Data, account: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent(account)
        try data.write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
    func remove(_ account: String) throws {
        let path = directory.appendingPathComponent(account)
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }
}

enum QAInput {
    static func capture(_ event: CGEvent) {
        guard let path = ProcessInfo.processInfo.environment["THUMBLE_QA_EVENTS"] else { fatalError("Missing capture path") }
        let value: [String: Any] = ["at": Date().timeIntervalSince1970, "type": event.type.rawValue, "code": event.getIntegerValueField(.keyboardEventKeycode), "flags": event.flags.rawValue, "x": event.location.x, "y": event.location.y, "scrollY": event.getIntegerValueField(.scrollWheelEventDeltaAxis1), "scrollX": event.getIntegerValueField(.scrollWheelEventDeltaAxis2)]
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) + Data([10])
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        let file = try! FileHandle(forWritingTo: URL(fileURLWithPath: path)); defer { try? file.close() }
        try! file.seekToEnd(); try! file.write(contentsOf: data)
    }
}
@MainActor final class HardwareQA: NSObject, NSApplicationDelegate {
    var receiver: Receiver!, studio: WorkspaceWindow!
    var invitation = "", detail = "Starting isolated hardware QA receiver"
    var directory: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["TAPPING_PROFILE_DIR"]!) }
    func applicationDidFinishLaunching(_ notification: Notification) {
        receiver = Receiver(secrets: IsolatedReceiverSecrets())
        receiver.onInvitation = { [weak self] value in DispatchQueue.main.async {
            self?.invitation = value
            if !value.isEmpty, let path = ProcessInfo.processInfo.environment["TAPPING_TEST_INVITATION"] { try? Data(value.utf8).write(to: URL(fileURLWithPath: path), options: .atomic) }
        } }
        receiver.onStatus = { [weak self] text in DispatchQueue.main.async { self?.detail = text } }
        do {
            try receiver.start()
            if let fixture = Bundle.main.url(forResource: "Fixture", withExtension: "json"), let profile = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any], !(try WorkspaceProfiles.snapshot(directory)["profiles"] as! [[String: Any]]).contains(where: { ($0["profile"] as? [String: Any])?["id"] as? String == profile["id"] as? String }) {
                try WorkspaceProfiles.save(directory, profile: profile, expected: 0, viewport: ["width":844,"height":390])
            }
        } catch { fatalError("QA receiver failed: \(error)") }
        studio = WorkspaceWindow(directory: directory)
        studio.window.title = "Thumble Hardware QA — captured input only"
        studio.receiverState = { [weak self] in
            guard let self else { return [:] }
            var value: [String: Any] = ["platform":"macOS · hardware QA · input capture", "receiver":["running":true,"connected":false,"detail":self.detail], "settings":["syncEnabled":false,"startAtLogin":false,"wowPaths":[]]]
            if !self.invitation.isEmpty, let filter = CIFilter(name:"CIQRCodeGenerator") {
                filter.setValue(Data(self.invitation.utf8),forKey:"inputMessage")
                if let image = filter.outputImage?.transformed(by:CGAffineTransform(scaleX:8,y:8)), let cg = CIContext().createCGImage(image,from:image.extent), let png = NSBitmapImageRep(cgImage:cg).representation(using:.png,properties:[:]) { value["pairing"] = ["png":png.base64EncodedString()] }
            }
            return value
        }
        studio.action = { [weak self] operation, _ in
            guard let self else { return }
            switch operation {
            case "disconnect": self.receiver.workspaceDisconnect()
            case "forget": self.receiver.resetPairing()
            case "copy-pairing": NSPasteboard.general.clearContents(); NSPasteboard.general.setString(self.invitation,forType:.string)
            default: break
            }
        }
        studio.show()
    }
    func applicationWillTerminate(_ notification: Notification) { receiver.stop() }
}
MainActor.assumeIsolated {
    let app = NSApplication.shared; let delegate = HardwareQA(); app.delegate = delegate
    app.setActivationPolicy(.regular); app.run()
}
