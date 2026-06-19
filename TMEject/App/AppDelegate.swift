import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let coordinator: AppCoordinator
    private let toastOverlay = ToastOverlay()
    private var hotkeyMonitor: HotkeyMonitor?
    lazy var preferencesController: PreferencesWindowController = {
        PreferencesWindowController(coordinator: coordinator)
    }()
    private let onboardingFlow = OnboardingFlowWindowController()
    private let launchHUD = LaunchHUDWindowController()
    private let menuBarHelp = MenuBarHelpWindowController()
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

    /// Dismisses the currently visible Launch HUD if one is up. Called from the popover's
    /// `.onAppear` so the HUD doesn't sit on top of an opened popover — but does NOT
    /// suppress future launches. The HUD is a per-launch "where is my icon" helper, not a
    /// one-time onboarding step; users forget icon positions, menu-bar managers
    /// (Bartender, iBar) hide/reorder things, and a fresh login session can shuffle
    /// layout. So we show it every launch and only dismiss the in-flight one here.
    func dismissLaunchHUDIfNeeded() {
        guard launchHUD.isShowing else { return }
        launchHUD.dismiss()
        NSApp.setActivationPolicy(.accessory)
    }

    /// First-install flow + Launch HUD ordering:
    ///   1. If `hasCompletedOnboarding == false` OR Reset Onboarding was tapped
    ///      (`forceOnboardingModal == true`), show the three-step `OnboardingFlowView`
    ///      window FIRST. The HUD is suppressed while it's up.
    ///   2. When the flow finishes (or the user closes the window), show the Launch HUD
    ///      — the existing locator that runs every launch to point at the menu bar icon.
    ///
    /// Why the flow is gated and the HUD isn't: the flow asks for permissions (FDA +
    /// notifications) and explains the app, so it must only run once. The HUD is purely
    /// "here is the menu bar icon" and has to run every launch because menu bar managers
    /// (Bartender, iBar) and fresh login sessions reshuffle layout.
    private func presentLaunchSurfacesIfNeeded() {
        let defaults = UserDefaults.standard
        let didOnboarding = defaults.bool(forKey: SettingsKey.hasCompletedOnboarding)
        let forceModal   = defaults.bool(forKey: SettingsKey.forceOnboardingModal)

        if forceModal {
            defaults.set(false, forKey: SettingsKey.forceOnboardingModal)
        }

        if !didOnboarding || forceModal {
            // Granting FDA terminates the app process (macOS, not us). On relaunch
            // the user already accomplished the goal of the FDA step. If FDA reads
            // as granted, flip hasCompletedOnboarding=true and skip straight to HUD
            // — the user shouldn't have to see the intro again just to reach a
            // "done!" screen. Reset Onboarding (forceModal) overrides this so a
            // user can rewatch the intro deliberately.
            if !forceModal,
               coordinator.fdaState == .granted {
                UIActionLogger.onboardingStep(
                    "skipping onboarding flow — FDA already granted, auto-completing"
                )
                defaults.set(true, forKey: SettingsKey.hasCompletedOnboarding)
                presentLaunchHUD()
                return
            }

            UIActionLogger.onboardingStep(
                "showing onboarding flow (didOnboarding=\(didOnboarding), forceModal=\(forceModal))"
            )
            onboardingFlow.show(coordinator: coordinator) { [weak self] in
                self?.presentLaunchHUD()
            }
            return
        }

        presentLaunchHUD()
    }

    /// Unconditionally shows the Launch HUD (idempotent — `LaunchHUDWindowController.show`
    /// early-returns if a panel is already up).
    private func presentLaunchHUD() {
        launchHUD.show(
            onFound: { [weak self] in
                NSApp.setActivationPolicy(.accessory)
                self?.coordinator.requestPokeNow()
            },
            onCantFind: { [weak self] in
                guard let self else { return }
                // Drop to .accessory now; the help controller will bump back to .regular
                // when it opens its window, then back to .accessory on close.
                NSApp.setActivationPolicy(.accessory)
                self.menuBarHelp.show(onOpenPreferences: { [weak self] in
                    self?.preferencesController.show()
                })
            }
        )
    }
}
