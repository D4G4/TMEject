import AppKit
import SwiftUI

@MainActor
final class LaunchHUDWindowController {
    private var window: NSPanel?

    func show(onDismiss: @escaping () -> Void) {
        guard let screen = NSScreen.main else { return }
        if window != nil { return }

        let width: CGFloat = 252
        let height: CGFloat = 142
        let visible = screen.visibleFrame
        let x = visible.maxX - width - 80
        let y = visible.maxY - height - 56

        let view = LaunchHUDView(onDismiss: { [weak self] in
            self?.dismiss()
            onDismiss()
        })

        let panel = NSPanel(
            contentRect: NSRect(x: x, y: y, width: width, height: height + 50),
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
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height + 50)
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
}
