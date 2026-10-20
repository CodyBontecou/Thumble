#if DEBUG
import ScrawlKit
#endif
import SwiftUI

@main
struct ThumbleiOSApp: App {
    @UIApplicationDelegateAdaptor(ThumbleApplicationDelegate.self) private var applicationDelegate
    @StateObject private var startup = IOSClientStartup()
    @StateObject private var orientationCoordinator = GamepadOrientationCoordinator()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if let client = startup.client {
                    IOSContentView()
                        .environmentObject(client)
                        .onAppear {
                            applySelectedProfileOrientation()
                        }
                        .onChange(of: client.selectedGamepadProfileID) { _, _ in
                            applySelectedProfileOrientation()
                        }
                        .onChange(of: client.gamepadProfiles) { _, _ in
                            applySelectedProfileOrientation()
                        }
                        .onChange(of: scenePhase) { _, newPhase in
                            switch newPhase {
                            case .inactive:
                                TouchCaptureUIView.deactivateAllRegisteredTouches()
                                client.appWillBecomeInactive()
                            case .background:
                                TouchCaptureUIView.deactivateAllRegisteredTouches()
                                client.appDidEnterBackground()
                            case .active:
                                client.appDidBecomeActive()
                                applySelectedProfileOrientation()
                            default:
                                break
                            }
                        }
                } else {
                    ContentUnavailableView("Configuration Unavailable", systemImage: "exclamationmark.triangle", description: Text(startup.failure ?? "Saved data could not be loaded. Saved data was not changed."))
                }
            }
            #if DEBUG
            .scrawl()
            #endif
        }
    }

    private func applySelectedProfileOrientation() {
        guard let client = startup.client else { return }
        orientationCoordinator.apply(client.selectedGamepadProfileOrientationPreference) {
            TouchCaptureUIView.deactivateAllRegisteredTouches()
            client.releaseAll()
        }
    }
}

@MainActor
private final class IOSClientStartup: ObservableObject {
    let client: ControllerClient?
    let failure: String?

    init() {
        do {
            client = try ControllerClient()
            IOSRetiredPreferenceCleanup.removeCalibration()
            failure = nil
        } catch {
            client = nil
            failure = error.localizedDescription
        }
    }
}
