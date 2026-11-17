import SwiftUI
import UIKit

/// Receives the system's wake-up when a background upload (the original video) finishes while the
/// app was suspended or terminated, and hands it to the upload session.
final class PocketWorldAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundUploadSender.identifier else { completionHandler(); return }
        BackgroundUploadSender.shared.handleEvents(completion: completionHandler)
    }
}

@main
struct PocketWorldApp: App {
    @UIApplicationDelegateAdaptor(PocketWorldAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Must be registered before launch finishes.
        ReconstructionSync.registerBackgroundTask()
        // Reconnect to uploads that kept running while the app was not.
        BackgroundUploadSender.shared.activate()
        OnDeviceTrainingStore.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .tint(Theme.accent)
                .preferredColorScheme(.dark)
                .onAppear { ReconstructionSync.shared.activate() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { OnDeviceTrainingStore.shared.appDidBecomeActive() }
            else { OnDeviceTrainingStore.shared.appWillResignActive() }
            if phase == .background { ReconstructionSync.shared.scheduleBackgroundRefreshIfNeeded() }
        }
    }
}
