import AppKit
import SwiftUI

@main
struct ThumbleMacApp: App {
    @StateObject private var startup = MacServerStartup()

    var body: some Scene {
        WindowGroup {
            if let server = startup.server {
                MacContentView()
                    .environmentObject(server)
                    .frame(minWidth: 840, minHeight: 620)
                    .onAppear {
                        server.start()
                    }
                    .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                        NotificationCenter.default.post(name: .thumbleCommitPendingEditorChanges, object: nil)
                        NotificationCenter.default.post(name: .thumbleCommitPendingShortcutRecordings, object: nil)
                        server.prepareForTermination()
                    }
            } else if let failure = startup.failure {
                ContentUnavailableView("Configuration Unavailable", systemImage: "exclamationmark.triangle", description: Text(failure))
                    .frame(minWidth: 840, minHeight: 620)
            } else {
                RustAuthorityActiveView()
                    .frame(minWidth: 840, minHeight: 620)
            }
        }
        .defaultSize(width: 1120, height: 760)
        .windowResizability(.contentMinSize)
    }
}

private final class MacServerStartup: ObservableObject {
    let server: MacControllerServer?
    let failure: String?

    init() {
        do {
            let lease = try MacLegacyAuthorityLease.acquire()
            server = try MacControllerServer(legacyAuthorityLease: lease)
            failure = nil
        } catch MacLegacyAuthorityLease.LeaseError.activeRustControlSocket,
                MacLegacyAuthorityLease.LeaseError.authorityHeld {
            server = nil
            failure = nil
        } catch {
            server = nil
            failure = error.localizedDescription
        }
    }
}

private struct RustAuthorityActiveView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Rust Configuration Authority Is Active")
                .font(.title2.weight(.semibold))
            Text("The legacy editor is unavailable while Thumble Host owns configuration state. Use the revision-safe thumble CLI, or stop Thumble Host before opening the legacy editor.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 520)
            Text("To adopt a hosted-builder shared keypad while Rust authority is active, run: thumble profile import --append ARTIFACT.json")
                .multilineTextAlignment(.center)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .frame(maxWidth: 620)
        }
        .padding(40)
    }
}
