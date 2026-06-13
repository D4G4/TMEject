import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let coordinator: AppCoordinator
    private let toastOverlay = ToastOverlay()
    private var hotkeyMonitor: HotkeyMonitor?
    lazy var preferencesController: PreferencesWindowController = {
        PreferencesWindowController(coordinator: coordinator)
    }()
    private let onboarding = OnboardingWindowController()
    private let launchHUD = LaunchHUDWindowController()

    override init() {
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
        presentLaunchSurfacesIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        TMEjectLog.app.info("applicationWillTerminate")
        // The `.appWillTerminate` state-machine event is what produces the .ejecting warning
        // surface (Decision #10 — `showQuitDuringEjectWarning`). Without delivering it here,
        // that warning is dead code in production.
        Task {
            await coordinator.dispatch(.appWillTerminate)
            await coordinator.stop()
        }
        // TODO(Step-15 polish): switch to `applicationShouldTerminate` returning .terminateLater
        // so the warning can render and the user can confirm before shutdown completes.
    }

    /// macOS routes Dock-icon clicks (and re-opens) through this. We use it to bring any
    /// surfaced setup window back to the front in case the user lost it behind something.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        for win in NSApp.windows where win.identifier == .tmejectSetupWindow {
            win.makeKeyAndOrderFront(nil)
            win.surfaceAtLaunch()
        }
        return true
    }

    // MARK: - Launch UX

    private func presentLaunchSurfacesIfNeeded() {
        let defaults = UserDefaults.standard
        let didOnboarding = defaults.bool(forKey: SettingsKey.hasCompletedOnboarding)
        let didHUD       = defaults.bool(forKey: SettingsKey.hasSeenLaunchHUD)

        if !didOnboarding {
            UIActionLogger.onboardingStep("not completed — opening onboarding")
            onboarding.show(coordinator: coordinator) { [weak self] in
                defaults.set(true, forKey: SettingsKey.hasCompletedOnboarding)
                self?.presentLaunchHUDIfNeeded()
            }
        } else if !didHUD {
            // Onboarding was completed (or skipped via Reset) but HUD never confirmed.
            presentLaunchHUDIfNeeded()
        } else {
            // Drop back to .accessory now that there's no foreground UI.
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func presentLaunchHUDIfNeeded() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: SettingsKey.hasSeenLaunchHUD) { return }
        launchHUD.show(
            onFound: { [weak self] in
                defaults.set(true, forKey: SettingsKey.hasSeenLaunchHUD)
                NSApp.setActivationPolicy(.accessory)
                self?.coordinator.requestPokeNow()
            },
            onCantFind: { [weak self] in
                self?.launchHUD.showCantFindHelp()
                // Counts as seen so we don't keep nagging — user has been pointed at the
                // System Settings remediation.
                defaults.set(true, forKey: SettingsKey.hasSeenLaunchHUD)
                NSApp.setActivationPolicy(.accessory)
            }
        )
    }
}
