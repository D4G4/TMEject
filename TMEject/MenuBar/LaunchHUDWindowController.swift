import AppKit
import SwiftUI

@MainActor
final class LaunchHUDWindowController {
    private var window: NSPanel?

    func show(onFound: @escaping () -> Void, onCantFind: @escaping () -> Void) {
        guard let screen = NSScreen.main else { return }
        if window != nil { return }

        let width: CGFloat = 340
        let height: CGFloat = 124
        let visible = screen.visibleFrame
        let x = visible.maxX - width - 20
        let y = visible.maxY - height - 12

        let view = LaunchHUDView(
            onFound: { [weak self] in
                self?.dismiss(animated: true)
                onFound()
            },
            onCantFind: { [weak self] in
                self?.dismiss(animated: true)
                onCantFind()
            }
        )

        let panel = NSPanel(
            contentRect: NSRect(x: x, y: y, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = NSApp.effectiveAppearance

        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        UIActionLogger.windowOpened("LaunchHUD")
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            panel.animator().alphaValue = 1
        }
        self.window = panel
    }

    func dismiss(animated: Bool) {
        guard let panel = window else { return }
        UIActionLogger.windowClosed("LaunchHUD")
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                panel.orderOut(nil)
                self?.window = nil
            })
        } else {
            panel.orderOut(nil)
            window = nil
        }
    }

    func showCantFindHelp() {
        let alert = NSAlert()
        alert.messageText = "Can't see the TMEject icon?"
        alert.informativeText = """
        macOS sometimes hides menu bar items behind the notch or in the Control Center overflow on smaller displays.

        1. Open System Settings → Control Center.
        2. Scroll to "Menu Bar Only" and pin TMEject if it isn't already.
        3. If you use a third-party tool like Bartender, check its hidden-items list.

        TMEject is still running in the background even if the icon isn't visible — the keyboard shortcut and notifications continue to work.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Got it")
        NSApp.activate(ignoringOtherApps: true)
        _ = alert.runModal()
    }
}
