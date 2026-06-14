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
    private var logStreamObserver: LogStreamObserver?

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
        TMEjectUpdater.shared.checkForUpdatesInBackgroundAfterLaunchSettle()

        // Step 13 wake-latency optimization. Per locked Decision #1, polling stays primary;
        // the log-stream observer just nudges the poller to run sooner than its 30s/5s
        // cadence when backupd/TimeMachine activity is detected.
        let observer = LogStreamObserver(onWake: { [weak self] in
            await MainActor.run { self?.coordinator.requestPokeNow() }
        })
        self.logStreamObserver = observer
        Task { await observer.start() }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.coordinator.refreshFDAState()
                self?.coordinator.refreshDrivePresence()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        TMEjectLog.app.info("applicationWillTerminate")
        let logStream = logStreamObserver
        Task {
            await coordinator.dispatch(.appWillTerminate)
            await coordinator.stop()
            await logStream?.stop()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        for win in NSApp.windows where win.identifier == .tmejectSetupWindow {
            win.makeKeyAndOrderFront(nil)
            win.surfaceAtLaunch()
        }
        return true
    }

    // MARK: - Launch UX

    func dismissLaunchHUDIfNeeded() {
        guard launchHUD.isShowing else { return }
        launchHUD.dismiss()
        UserDefaults.standard.set(true, forKey: SettingsKey.hasSeenLaunchHUD)
        NSApp.setActivationPolicy(.accessory)
    }

    /// Default flow is **Onboarding A** (HUD-only). The modal explainer is only shown when
    /// the user explicitly resets onboarding from Settings → Troubleshooting (which sets
    /// `forceOnboardingModal=true`).
    private func presentLaunchSurfacesIfNeeded() {
        let defaults = UserDefaults.standard
        let didOnboarding = defaults.bool(forKey: SettingsKey.hasCompletedOnboarding)
        let didHUD       = defaults.bool(forKey: SettingsKey.hasSeenLaunchHUD)
        let forceModal   = defaults.bool(forKey: SettingsKey.forceOnboardingModal)

        if forceModal {
            UIActionLogger.onboardingStep("force modal requested — opening modal")
            defaults.set(false, forKey: SettingsKey.forceOnboardingModal)
            onboarding.show(coordinator: coordinator) { [weak self] in
                defaults.set(true, forKey: SettingsKey.hasCompletedOnboarding)
                self?.presentLaunchHUDIfNeeded()
            }
            return
        }

        if !didOnboarding {
            // Onboarding A — set the flag immediately, just show the HUD. The HUD is
            // self-explanatory and dismisses on first popover open.
            UIActionLogger.onboardingStep("first launch — HUD only (Onboarding A)")
            defaults.set(true, forKey: SettingsKey.hasCompletedOnboarding)
        }

        if !didHUD {
            presentLaunchHUDIfNeeded()
        } else {
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
                defaults.set(true, forKey: SettingsKey.hasSeenLaunchHUD)
                NSApp.setActivationPolicy(.accessory)
                self?.launchHUD.showCantFindAlert()
            }
        )
    }
}
