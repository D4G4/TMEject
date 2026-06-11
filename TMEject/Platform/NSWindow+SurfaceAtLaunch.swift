import AppKit

extension NSUserInterfaceItemIdentifier {
    static let tmejectSetupWindow = NSUserInterfaceItemIdentifier("TMEjectSetupWindow")
}

extension NSWindow {
    /// Standard chrome (titlebar + close button) for setup/preferences windows. Deliberately
    /// NOT fullSizeContentView — that combination triggers the SwiftUI safe-area oscillation
    /// that floods the run loop with window-update notifications and blocks foregrounding.
    static func makeSetupWindow(contentRect: NSRect, title: String) -> NSWindow {
        let win = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = title
        win.isReleasedWhenClosed = false
        win.identifier = .tmejectSetupWindow
        return win
    }

    /// One-shot launch-race elevation. Lift to `.floating` long enough to win the focus race
    /// against whatever app is frontmost, then drop back to the resting level so the window
    /// behaves like any other afterwards. macOS 14+ deprecated/ignores
    /// `NSApp.activate(ignoringOtherApps:)` for most apps, which is why this dance is needed.
    func surfaceAtLaunch() {
        collectionBehavior.insert(.moveToActiveSpace)
        let restingLevel = level
        level = .floating
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()
        NSApp.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.level = restingLevel
        }
    }
}
