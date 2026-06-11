import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let coordinator = AppCoordinator()
    private var hotkeyMonitor: HotkeyMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        TMEjectLog.app.info("applicationDidFinishLaunching — starting coordinator")
        coordinator.start()
        let monitor = HotkeyMonitor(coordinator: coordinator)
        monitor.register()
        hotkeyMonitor = monitor
    }

    func applicationWillTerminate(_ notification: Notification) {
        TMEjectLog.app.info("applicationWillTerminate")
        Task { await coordinator.stop() }
    }
}
