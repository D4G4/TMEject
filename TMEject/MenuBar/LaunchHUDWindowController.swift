import AppKit
import SwiftUI

@MainActor
final class LaunchHUDWindowController {
    private var window: NSPanel?

    func show(onFound: @escaping () -> Void, onCantFind: @escaping () -> Void) {
        guard let screen = NSScreen.main else { return }
        if window != nil { return }

        let width: CGFloat = 340
        let visible = screen.visibleFrame

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

        // Size the panel to the SwiftUI view's intrinsic height — previously we hard-coded
        // 140pt, but the view's content (two text rows + buttons + 14pt vertical padding)
        // sizes to ~110pt, leaving the SwiftUI content centered in the taller hosting view
        // with ~15pt of clear panel showing above and below the rounded HUD surface.
        let hosting = NSHostingView(rootView: view)
        let fitting = hosting.fittingSize
        let height = max(fitting.height, 100)
        let x = visible.maxX - width - 20
        let y = visible.maxY - height - 12

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
}
