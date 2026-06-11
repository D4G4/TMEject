import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let coordinator: AppCoordinator
    private let toastOverlay = ToastOverlay()
    private var hotkeyMonitor: HotkeyMonitor?

    override init() {
        // ToastOverlay must outlive the coordinator's lifetime; hand it in at construction
        // so the coordinator can present toasts without re-checking optionality each time.
        let overlay = self.toastOverlay
        self.coordinator = AppCoordinator(toastPresenter: overlay)
        super.init()
    }

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
