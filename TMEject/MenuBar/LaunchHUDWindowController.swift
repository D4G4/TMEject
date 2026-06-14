import AppKit
import SwiftUI

@MainActor
final class LaunchHUDWindowController {
    private var window: NSPanel?

    func show(onFound: @escaping () -> Void, onCantFind: @escaping () -> Void) {
        guard let screen = NSScreen.main else { return }
        if window != nil { return }

        let width: CGFloat = 340
        let height: CGFloat = 140
        let visible = screen.visibleFrame
        let x = visible.maxX - width - 20
        let y = visible.maxY - height - 12

        let view = LaunchHUDView(
            onFound: { [weak self] in
                self?.dismiss()
                onFound()
            },
            onCantFind: { [weak self] in
                self?.dismiss()
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
            ctx.duration = 0.3
            panel.animator().alphaValue = 1
        }
        self.window = panel
    }

    func dismiss() {
        guard let panel = window else { return }
        UIActionLogger.windowClosed("LaunchHUD")
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            panel.orderOut(nil)
            self?.window = nil
        })
    }

    var isShowing: Bool { window != nil }

    func showCantFindAlert() {
        let alert = NSAlert()
        alert.messageText = "Looking for TMEject"
        alert.informativeText = "TMEject's icon usually appears on the right side of your menu bar. If it's hidden, check Control Center or a third-party menu bar manager like Bartender or iBar."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        _ = alert.runModal()
    }
}
