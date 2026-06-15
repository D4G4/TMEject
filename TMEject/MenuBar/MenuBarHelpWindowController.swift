import AppKit
import SwiftUI

/// Opens the "Where's the TMEject icon?" help dialog as a standalone window. Shown when
/// the user taps "Can't find it" on the Launch HUD. Mirrors Blink's
/// `MenuBarHelpWindowController` — standalone 540×620 titled window, drops back to
/// `.accessory` on close so the Dock icon disappears when no window is open.
@MainActor
final class MenuBarHelpWindowController {
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    /// `onOpenPreferences` is the guaranteed fallback entry point — even if the user never
    /// recovers the menu bar icon, this keeps TMEject reachable via the Settings window.
    func show(onOpenPreferences: @escaping () -> Void) {
        if let win = window, win.isVisible {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let view = MenuBarHelpView(
            onOpenPreferences: { onOpenPreferences() },
            onDismiss: { [weak self] in self?.dismiss() }
        )

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 620),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Find TMEject"
        win.contentView = NSHostingView(rootView: view)
        win.center()
        win.isReleasedWhenClosed = false
        win.identifier = .tmejectSetupWindow

        NSApp.setActivationPolicy(.regular)
        win.makeKeyAndOrderFront(nil)
        win.surfaceAtLaunch()
        UIActionLogger.windowOpened("MenuBarHelp")

        if let existing = closeObserver {
            NotificationCenter.default.removeObserver(existing)
        }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: win,
            queue: .main
        ) { [weak self] _ in
            UIActionLogger.windowClosed("MenuBarHelp")
            self?.window = nil
            NSApp.setActivationPolicy(.accessory)
        }

        self.window = win
    }

    private func dismiss() {
        window?.close()
        window = nil
        NSApp.setActivationPolicy(.accessory)
    }
}
