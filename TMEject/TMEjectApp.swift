import SwiftUI
import KeyboardShortcuts

@main
struct TMEjectApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        TMEjectLog.pruneOldLogs()
        TMEjectLog.app.info("TMEject launched")
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopoverView(
                coordinator: delegate.coordinator,
                openPreferences: { delegate.preferencesController.show() }
            )
                .onAppear {
                    // Closing the launch HUD on first popover open: per design, the HUD
                    // self-dismisses once the user discovers the menu bar icon.
                    delegate.dismissLaunchHUDIfNeeded()
                }
        } label: {
            MenuBarIconView(state: delegate.coordinator.state,
                            ejectPct: delegate.coordinator.ejectPct)
        }
        .menuBarExtraStyle(.window)
    }
}
