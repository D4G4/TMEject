import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let coordinator = AppCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        TMEjectLog.app.info("applicationDidFinishLaunching — starting coordinator")
        coordinator.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        TMEjectLog.app.info("applicationWillTerminate")
        Task { await coordinator.stop() }
    }
}
