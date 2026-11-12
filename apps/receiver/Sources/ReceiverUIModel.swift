import AppKit
import CoreImage
import ServiceManagement
import SwiftUI

/// Main-actor view state for the menu-bar UI. Every value is sourced from the running
/// receiver, its profile store or UserDefaults; nothing here is invented for display.
@MainActor final class ReceiverUIModel: ObservableObject {
    enum ControllerAccess: Equatable { case starting, ready, needsPermission, unavailable, failed(String) }
    enum Phase: Equatable { case accessNeeded, starting, unavailable, readyToPair, waiting, connected, freeTimeEnded }
    struct Layout: Identifiable, Equatable {
        let id: String
        let name: String
        let revision: Int
        let origin: String?
        let active: Bool
    }
    struct ConsolePortSnapshot: Equatable { let character: String; let exportedAt: Date; let following: Bool }

    @Published var controllerAccess = ControllerAccess.starting
    @Published var statusMessage = "Starting receiver…"
    @Published var consolePortStatus = "ConsolePort: waiting for /reload"
    @Published private(set) var invitation = ""
    @Published private(set) var qrImage: NSImage?
    @Published private(set) var invitationExpiry: Date?
    @Published var receiver: ReceiverSnapshot?
    @Published var sharing = false
    @Published var syncEnabled = !UserDefaults.standard.bool(forKey: "consolePortSyncDisabled")
    @Published private(set) var wowFolder = ReceiverUIModel.currentWoWFolder()
    @Published private(set) var layouts: [Layout] = []
    @Published private(set) var activationRevision = 0
    @Published private(set) var consolePortSync: ConsolePortSnapshot?
    @Published private(set) var layoutError: String?
    @Published private(set) var layoutBusy = false
    @Published var showCodeWhileWaiting = false
    @Published private(set) var loginItem = SMAppService.mainApp.status
    @Published var now = Date()

    // Actions, wired by the app delegate to the existing receiver paths.
    var enableControllerAccess: () -> Void = {}
    var retryControllerAccess: () -> Void = {}
    var newCode: () -> Void = {}
    var forgetPhone: () -> Void = {}
    var confirmForgetPhone: () -> Void = {}
    var pairThroughChatGPT: () -> Void = {}
    var stopChatGPTPairing: () -> Void = {}
    var chooseWoWFolder: () -> Void = {}
    var openLayouts: () -> Void = {}
    var openDiagnostics: () -> Void = {}
    var openSettings: () -> Void = {}
    var replayTour: () -> Void = {}
    var showPopover: () -> Void = {}
    var quit: () -> Void = {}

    static var localTesting: Bool {
#if THUMBLE_LOCAL_TESTING
        return true
#else
        return false
#endif
    }
    static let profileDirectory: URL = {
        if let path = ProcessInfo.processInfo.environment["TAPPING_PROFILE_DIR"] { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Tapping/profiles", isDirectory: true)
    }()
    static func currentWoWFolder() -> String {
        ProcessInfo.processInfo.environment["TAPPING_WOW_CLIENT_DIR"] ?? UserDefaults.standard.string(forKey: "consolePortWoWFolder") ?? "/Applications/World of Warcraft"
    }
    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "development"
        if let build = info?["CFBundleVersion"] as? String { return "\(short) (\(build))" }
        return short
    }

    var phase: Phase {
        switch controllerAccess {
        case .needsPermission: return .accessNeeded
        case .unavailable, .failed: return .unavailable
        case .starting: return .starting
        case .ready: break
        }
        guard let receiver else { return .starting }
        if receiver.connected {
            if !receiver.pro, let remaining = receiver.remaining, remaining <= 0 { return .freeTimeEnded }
            return .connected
        }
        if receiver.rememberedPhone { return .waiting }
        return .readyToPair
    }
    /// Dot shown on the status item: green connected, orange waiting/lost/attention, none idle.
    var statusDot: NSColor? {
        switch phase {
        case .connected: return receiver?.paused == true ? .systemOrange : .systemGreen
        case .waiting, .accessNeeded, .freeTimeEnded, .unavailable: return .systemOrange
        case .readyToPair, .starting: return nil
        }
    }
    var expiryText: String? {
        guard let invitationExpiry else { return nil }
        let seconds = max(0, Int(invitationExpiry.timeIntervalSince(now).rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    var activeLayout: Layout? { layouts.first(where: \.active) }
    var freeTimeText: String? {
        if Self.localTesting { return "Local testing · unlimited" }
        guard let receiver, receiver.connected else { return nil }
        if receiver.pro { return "Pro · unlimited" }
        guard let remaining = receiver.remaining else { return nil }
        let seconds = max(0, Int(remaining.rounded(.down)))
        return String(format: "%d:%02d free time left", seconds / 60, seconds % 60) + (receiver.running ? "" : " · paused")
    }
    var controllerAccessText: String {
        switch controllerAccess {
        case .ready: return "Ready"
        case .starting: return "Starting…"
        case .needsPermission: return "Waiting for permission"
        case .unavailable: return "macOS could not create the controller"
        case .failed: return "Receiver could not start"
        }
    }

    func setInvitation(_ value: String) {
        invitation = value
        invitationExpiry = Self.expiry(of: value)
        guard !value.isEmpty else { qrImage = nil; return }
        let filter = CIFilter(name: "CIQRCodeGenerator", parameters: ["inputMessage": Data(value.utf8), "inputCorrectionLevel": "M"])
        if let image = filter?.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)), let cg = CIContext().createCGImage(image, from: image.extent) {
            qrImage = NSImage(cgImage: cg, size: .zero)
        } else { qrImage = nil }
    }
    func clearInvitation() { invitation = ""; invitationExpiry = nil; qrImage = nil }
    /// The invitation carries its own expiry; decode it rather than reaching into the receiver.
    static func expiry(of invitation: String) -> Date? {
        guard !invitation.isEmpty, let parts = URLComponents(string: invitation),
              let encoded = parts.queryItems?.first(where: { $0.name == "data" })?.value else { return nil }
        let base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4)),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let expires = payload["expires"] as? Int else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(expires))
    }
    func copyLink() {
        guard !invitation.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(invitation, forType: .string)
    }
    func setSyncEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(!enabled, forKey: "consolePortSyncDisabled")
        syncEnabled = enabled
    }
    func wowFolderChanged() { wowFolder = Self.currentWoWFolder() }

    // MARK: Layouts (same store and lock as the agent tools and phone profile-select)
    private let storeQueue = DispatchQueue(label: "thumble.receiver.ui.profiles", qos: .utility)
    func reloadLayouts() {
        let directory = Self.profileDirectory
        storeQueue.async { [weak self] in
            let result = Result { () throws -> ([Layout], Int, ConsolePortSnapshot?) in
                let store = try ProfileCatalog.read(directory)
                let summary = try ProfileCatalog.summary(store)
                let active = store["active"] as? [String: Any]
                let activeID = (active?["profile"] as? [String: Any])?["id"] as? String
                let activeRevision = ProfileCatalog.revision(active?["profileRevision"])
                let entries = store["profiles"] as? [[String: Any]] ?? []
                let layouts = entries.compactMap { entry -> Layout? in
                    guard let profile = entry["profile"] as? [String: Any], let id = profile["id"] as? String,
                          let name = profile["name"] as? String, let revision = ProfileCatalog.revision(entry["revision"]) else { return nil }
                    let origin = entry["phoneEdited"] as? Bool == true ? "Made on phone" : entry["cloudSource"] != nil ? "From Thumble cloud" : nil
                    return Layout(id: id, name: name, revision: revision, origin: origin, active: id == activeID && revision == activeRevision)
                }
                var sync: ConsolePortSnapshot?
                if let value = summary["consolePortSync"] as? [String: Any], let name = value["characterName"] as? String,
                   let exported = value["exportedAt"] as? NSNumber {
                    sync = ConsolePortSnapshot(character: name, exportedAt: Date(timeIntervalSince1970: exported.doubleValue), following: value["following"] as? Bool == true)
                }
                return (layouts, ProfileCatalog.revision(summary["activationRevision"]) ?? 0, sync)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let (layouts, activation, sync)):
                    if self.layouts != layouts { self.layouts = layouts }
                    self.activationRevision = activation; self.consolePortSync = sync; self.layoutError = nil
                case .failure(let error): self.layoutError = error.localizedDescription
                }
            }
        }
    }
    /// Writes the same activation record a phone profile-select writes; ProfileBridge then
    /// picks it up and pushes the layout through the existing acknowledged path.
    func activate(_ layout: Layout) {
        guard !layoutBusy else { return }
        layoutBusy = true
        let directory = Self.profileDirectory, expected = activationRevision
        storeQueue.async { [weak self] in
            let result = Result { try ProfileCatalog.activate(directory, id: layout.id, profileRevision: layout.revision, expectedActivationRevision: expected) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.layoutBusy = false
                if case .failure(let error) = result { self.layoutError = error.localizedDescription }
                self.reloadLayouts()
            }
        }
    }

    // MARK: Login item
    var loginItemSupported: Bool { loginItem != .notFound || Bundle.main.bundleURL.pathExtension == "app" }
    var opensAtLogin: Bool { loginItem == .enabled || loginItem == .requiresApproval }
    @Published private(set) var loginItemError: String?
    func setOpensAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginItemError = nil
        } catch { loginItemError = error.localizedDescription }
        loginItem = SMAppService.mainApp.status
        if loginItem == .requiresApproval { loginItemError = "Approve Thumble Receiver in System Settings › General › Login Items." }
    }
    func refreshLoginItem() { loginItem = SMAppService.mainApp.status }
}
