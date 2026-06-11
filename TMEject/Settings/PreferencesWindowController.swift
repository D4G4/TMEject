import AppKit
import SwiftUI

@MainActor
final class PreferencesWindowController {
    private weak var coordinator: AppCoordinator?
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    func show(initialTab: SettingsTab = .general) {
        guard let coordinator else { return }
        TMEjectLog.ui.info("Preferences.show (initialTab=\(initialTab.label))")
        if let win = window, win.isVisible {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let view = SettingsView(coordinator: coordinator, initialTab: initialTab)
        let win = NSWindow.makeSetupWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
            title: "TMEject Settings"
        )
        win.contentView = NSHostingView(rootView: view)
        win.center()

        NSApp.setActivationPolicy(.regular)
        win.makeKeyAndOrderFront(nil)
        win.surfaceAtLaunch()
        UIActionLogger.windowOpened("Preferences")

        if let existing = closeObserver {
            NotificationCenter.default.removeObserver(existing)
        }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: win,
            queue: .main
        ) { [weak self] _ in
            UIActionLogger.windowClosed("Preferences")
            self?.window = nil
            // Drop back to accessory so we lose the Dock icon when no window is open.
            NSApp.setActivationPolicy(.accessory)
        }
        self.window = win
    }
}
